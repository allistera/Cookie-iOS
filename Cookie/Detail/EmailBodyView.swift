import OSLog
import SwiftUI
import WebKit

/// Renders a message's sender-controlled `body_html` inside a locked-down
/// WKWebView. This is the app's one UIKit bridge: SwiftUI has no HTML
/// renderer, and email HTML needs a real one.
///
/// Defence in depth, matching Cookie-Web's sandboxed reader:
/// - JavaScript is disabled, so nothing in the email can execute.
/// - Tracking images (open pixels) are removed from the HTML before it is
///   loaded, whatever the image setting (see `TrackingImages`).
/// - Remote http(s) subresources (images, stylesheets, fonts, media, raw
///   fetches) are blocked by a content rule list until the user opts in.
/// - A non-persistent data store keeps no cookies or cache between messages.
/// - Link taps go to the system (http, https, mailto only); nothing
///   navigates in place.
///
/// The web view reports its content height through KVO on its scroll view
/// (JavaScript is off, so it cannot measure itself), letting the detail
/// screen's own ScrollView size and scroll it.
struct EmailBodyView: UIViewRepresentable {
    let html: String
    /// When true, remote http(s) loads are blocked ("Show images" turns this off).
    var blocksRemoteContent = true
    /// The SwiftUI reader supplies a Dynamic Type-scaled base size.
    var baseFontSize: CGFloat = 17
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = Self.makeConfiguration()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The detail screen's ScrollView owns scrolling; the body just grows.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        context.coordinator.observeContentHeight(of: webView)
        // updateUIView always follows makeUIView and performs the first load.
        return webView
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.needsReload(
            html: html, blocksRemoteContent: blocksRemoteContent, baseFontSize: baseFontSize)
        {
            context.coordinator.load(
                html: html, blocksRemoteContent: blocksRemoteContent, baseFontSize: baseFontSize, into: webView)
        } else {
            context.coordinator.measureContentHeightAfterLayout(of: webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown(webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>

        /// Sender CSS controls the content size, so the reported height is
        /// untrusted. Beyond this cap the web view scrolls its own overflow.
        private static let maxContentHeight: CGFloat = 12_000
        private static let ruleIdentifier = "cookie-block-remote-content"
        /// Every remote subresource type that can report an open.
        private static let ruleJSON = """
            [
                {"trigger":{"url-filter":"^https?://","resource-type":[
                    "document","image","style-sheet","font","media","raw","svg-document"
                ]},"action":{"type":"block"}}
            ]
            """
        private static var cachedRuleList: WKContentRuleList?
        private static let logger = Logger(subsystem: "com.cookie.ios", category: "body")
        /// Relative font URLs in the wrapper document resolve against the bundle.
        private static let baseURL = Bundle.main.bundleURL

        private var loadedHTML: String?
        private var loadedBlocksRemoteContent: Bool?
        private var loadedBaseFontSize: CGFloat?
        private var loadTask: Task<Void, Never>?
        private var observation: NSKeyValueObservation?
        private weak var observedWebView: WKWebView?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        /// `nil` means the rule is unavailable and the caller must fail closed.
        private static func ruleList() async -> WKContentRuleList? {
            if let cachedRuleList { return cachedRuleList }
            guard let store = WKContentRuleListStore.default() else {
                logger.error("No content rule list store")
                return nil
            }
            do {
                let list = try await store.compileContentRuleList(
                    forIdentifier: ruleIdentifier, encodedContentRuleList: ruleJSON)
                cachedRuleList = list
                return list
            } catch {
                logger.error("Block rule failed to compile: \(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
        }

        func observeContentHeight(of webView: WKWebView) {
            guard observation == nil else { return }
            observedWebView = webView
            let scrollView = webView.scrollView
            observation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, change in
                guard let size = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.reportContentHeight(size.height)
                }
            }
        }

        private func reportContentHeight(_ height: CGFloat) {
            guard height.isFinite, height > 0 else { return }
            let clamped = min(height, Self.maxContentHeight)
            observedWebView?.scrollView.isScrollEnabled = height > Self.maxContentHeight
            guard abs(clamped - contentHeight.wrappedValue) > 0.5 else { return }
            contentHeight.wrappedValue = clamped
        }

        /// SwiftUI gives the view its final width after makeUIView; measure
        /// again on the next run loop so WebKit can reflow for that width.
        func measureContentHeightAfterLayout(of webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                await Task.yield()
                guard let self, let webView else { return }
                webView.setNeedsLayout()
                webView.layoutIfNeeded()
                reportContentHeight(webView.scrollView.contentSize.height)
            }
        }

        func needsReload(html: String, blocksRemoteContent: Bool, baseFontSize: CGFloat) -> Bool {
            html != loadedHTML || blocksRemoteContent != loadedBlocksRemoteContent
                || baseFontSize != loadedBaseFontSize
        }

        func load(html: String, blocksRemoteContent: Bool, baseFontSize: CGFloat, into webView: WKWebView) {
            loadedHTML = html
            loadedBlocksRemoteContent = blocksRemoteContent
            loadedBaseFontSize = baseFontSize
            loadTask?.cancel()
            loadTask = Task { @MainActor [weak webView] in
                var ruleList: WKContentRuleList?
                if blocksRemoteContent {
                    ruleList = await Self.ruleList()
                }
                guard !Task.isCancelled, let webView else { return }
                let controller = webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if let ruleList {
                    controller.add(ruleList)
                } else if blocksRemoteContent {
                    // Fail closed rather than let tracking pixels load.
                    let message = String(localized: "This message can't be shown safely right now.")
                    webView.loadHTMLString(
                        Self.document(
                            html: "<p>\(message)</p>", blocksRemoteContent: true, baseFontSize: baseFontSize),
                        baseURL: Self.baseURL)
                    return
                }
                let renderedHTML = TrackingImages.removingTrackers(from: html)
                webView.loadHTMLString(
                    Self.document(
                        html: renderedHTML, blocksRemoteContent: blocksRemoteContent, baseFontSize: baseFontSize),
                    baseURL: Self.baseURL)
            }
        }

        func teardown(_ webView: WKWebView) {
            loadTask?.cancel()
            loadTask = nil
            observation?.invalidate()
            observation = nil
            observedWebView = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeAllContentRuleLists()
        }

        /// Wraps the raw email HTML in a document with a mobile viewport and
        /// the app's typography. Safety comes from the disabled JavaScript,
        /// the navigation policy and the content rules, not from this wrapper.
        private static func document(html: String, blocksRemoteContent: Bool, baseFontSize: CGFloat) -> String {
            let clampedFontSize = baseFontSize.isFinite ? min(max(baseFontSize, 12), 72) : 17
            let contentSecurityPolicy =
                blocksRemoteContent
                ? "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
                    + "img-src data: cid:; style-src 'unsafe-inline'; font-src file: data:;\">"
                : ""
            return """
                <!DOCTYPE html><html><head><meta charset="utf-8">\
                <meta name="viewport" content="width=device-width, initial-scale=1">\
                \(contentSecurityPolicy)\
                <style>\
                @font-face { font-family: "Figtree"; font-weight: 400; font-display: swap;\
                src: url("Figtree-Regular.ttf"); }\
                @font-face { font-family: "Figtree"; font-weight: 600; font-display: swap;\
                src: url("Figtree-SemiBold.ttf"); }\
                @font-face { font-family: "Figtree"; font-weight: 700; font-display: swap;\
                src: url("Figtree-Bold.ttf"); }\
                :root { color-scheme: light dark; }\
                body { margin: 0; padding: 0; background: transparent;\
                font-family: "Figtree", -apple-system, sans-serif !important;\
                font-size: \(clampedFontSize)px !important;\
                  line-height: 1.55; -webkit-text-size-adjust: 100%;\
                  word-wrap: break-word; overflow-wrap: break-word; }\
                body [style*="font-size"] { font-size: max(\(clampedFontSize)px, 1em) !important; }\
                img, video { max-width: 100%; height: auto; }\
                table { max-width: 100%; }\
                pre { white-space: pre-wrap; }\
                </style></head><body>\(html)</body></html>
                """
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            loadTask = nil
            measureContentHeightAfterLayout(of: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            handleNavigationFailure(error, in: webView)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error
        ) {
            handleNavigationFailure(error, in: webView)
        }

        private func handleNavigationFailure(_ error: Error, in webView: WKWebView) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            Self.logger.error(
                "Message body navigation failed: \(String(describing: type(of: error)), privacy: .public)")
            reportContentHeight(webView.scrollView.contentSize.height)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
                Self.isExternallyOpenable(url)
            {
                await UIApplication.shared.open(url)
                return .cancel
            }
            // The only navigation this view starts is its own loadHTMLString,
            // which WebKit reports as a main-frame load of the base URL.
            if navigationAction.targetFrame?.isMainFrame == true,
                let url = navigationAction.request.url,
                url == Self.baseURL || url.absoluteString == "about:blank"
            {
                return .allow
            }
            return .cancel
        }

        private static func isExternallyOpenable(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": true
            default: false
            }
        }
    }
}
