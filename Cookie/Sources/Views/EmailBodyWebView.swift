import SwiftUI
import WebKit

/// Renders a message's sender-controlled `body_html` inside a locked-down
/// WKWebView — the iOS counterpart of Cookie-Web's sanitized, sandboxed
/// reader iframe (`sanitizeEmailHtml.js` + `EmailBody.vue`).
///
/// Defence-in-depth, mirroring the web reader:
/// - JavaScript is disabled, so no script in the email can execute.
/// - Remote http(s) images are blocked by a `WKContentRuleList` until the
///   user opts in, so tracking pixels don't fire on open.
/// - Link taps are handed to Safari (http/https/mailto only); nothing ever
///   navigates in place.
///
/// The webview reports its content height through KVO on the scroll view
/// (JS is off, so it can't measure itself), letting SwiftUI size the frame
/// inside the detail screen's own ScrollView.
struct EmailBodyWebView: UIViewRepresentable {
    let html: String
    /// When true, remote http(s) image loads are blocked by content rules.
    var blocksRemoteImages = true
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

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
        // SwiftUI always calls updateUIView right after makeUIView; that
        // call performs the initial load. Loading here as well would queue
        // two navigations for the same HTML.
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.needsReload(html: html, blocksRemoteImages: blocksRemoteImages) {
            context.coordinator.load(
                html: html,
                blocksRemoteImages: blocksRemoteImages,
                into: webView
            )
        } else {
            // SwiftUI gives the representable its final width after
            // makeUIView. Re-measure on the next run loop so WebKit can
            // reflow long lines and tables for that width.
            context.coordinator.measureContentHeightAfterLayout(of: webView)
        }
    }

    /// Whether the (untrusted) HTML references remote images — the same three
    /// patterns Cookie-Web's `hasBlockedRemoteImages` checks, narrowed to
    /// `<img src>` and CSS background URLs so a plain link doesn't trigger
    /// the "Show images" control.
    nonisolated static func hasBlockedRemoteImages(_ html: String) -> Bool {
        guard !html.isEmpty else { return false }
        if html.range(of: #"<img\b[^>]*\bsrc\s*=\s*["']?\s*https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if html.range(of: #"\burl\(\s*['"]?\s*https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if html.range(of: #"\bbackground\s*=\s*["']?\s*https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>

        /// Sender CSS controls the webview's contentSize, so the reported
        /// height is untrusted. Cap the SwiftUI frame; taller bodies scroll
        /// inside the webview instead of growing native layout without bound.
        private static let maxContentHeight: CGFloat = 12_000

        private(set) var loadedHtml: String?
        private(set) var loadedBlocksRemoteImages: Bool?
        private var observation: NSKeyValueObservation?
        private weak var observedWebView: WKWebView?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        /// Compiled once per app run; the default store also persists by
        /// identifier, but the rule text never changes so that's harmless.
        private static var cachedImageBlockRuleList: WKContentRuleList?
        private static let imageBlockRuleIdentifier = "cookie-block-remote-images"
        private static let imageBlockRuleJSON = """
        [{"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"block"}}]
        """

        private static func remoteImageBlockRuleList() async -> WKContentRuleList? {
            if let cached = cachedImageBlockRuleList { return cached }
            guard let store = WKContentRuleListStore.default() else { return nil }
            let list = try? await store.compileContentRuleList(
                forIdentifier: imageBlockRuleIdentifier,
                encodedContentRuleList: imageBlockRuleJSON
            )
            cachedImageBlockRuleList = list
            return list
        }

        func observeContentHeight(of webView: WKWebView) {
            guard observation == nil else { return }
            observedWebView = webView
            observation = webView.scrollView.observe(
                \.contentSize,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let size = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.reportContentHeight(size.height)
                }
            }
        }

        private func reportContentHeight(_ height: CGFloat) {
            guard height.isFinite, height > 0 else { return }
            let clamped = min(height, Self.maxContentHeight)
            // Beyond the cap the frame stops growing, so the webview must
            // scroll its own overflow.
            observedWebView?.scrollView.isScrollEnabled = height > Self.maxContentHeight
            guard abs(clamped - contentHeight.wrappedValue) > 0.5 else { return }
            contentHeight.wrappedValue = clamped
        }

        func measureContentHeightAfterLayout(of webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                await Task.yield()
                guard let self, let webView else { return }
                webView.setNeedsLayout()
                webView.layoutIfNeeded()
                reportContentHeight(webView.scrollView.contentSize.height)
            }
        }

        func needsReload(html: String, blocksRemoteImages: Bool) -> Bool {
            html != loadedHtml || blocksRemoteImages != loadedBlocksRemoteImages
        }

        func load(html: String, blocksRemoteImages: Bool, into webView: WKWebView) {
            // Marked synchronously so back-to-back SwiftUI updates can't
            // queue duplicate loads for the same HTML.
            loadedHtml = html
            loadedBlocksRemoteImages = blocksRemoteImages

            Task { @MainActor [weak webView] in
                guard let webView else { return }
                webView.configuration.userContentController.removeAllContentRuleLists()
                if blocksRemoteImages,
                   let ruleList = await Self.remoteImageBlockRuleList() {
                    webView.configuration.userContentController.add(ruleList)
                }

                webView.loadHTMLString(Self.document(html: html), baseURL: nil)
            }
        }

        /// Wraps the raw email HTML in a minimal document with mobile viewport
        /// and system typography. No sanitization happens here — safety comes
        /// from the disabled JavaScript, the navigation policy, and the
        /// content rules above.
        private static func document(html: String) -> String {
            """
            <!DOCTYPE html><html><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            <style>\
            :root { color-scheme: light dark; }\
            body { margin: 0; padding: 0; background: transparent;\
              font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.45;\
              word-wrap: break-word; overflow-wrap: break-word; }\
            img, video { max-width: 100%; height: auto; }\
            table { max-width: 100%; }\
            pre { white-space: pre-wrap; }\
            </style></head><body>\(html)</body></html>
            """
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            // KVO can see only the initial blank page on some layouts. A
            // completed-navigation measurement guarantees the rendered HTML
            // gets a real SwiftUI frame instead of remaining at 44 points.
            measureContentHeightAfterLayout(of: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Hand link taps to the system instead of navigating in place.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               Self.isExternallyOpenable(url) {
                await UIApplication.shared.open(url)
                return .cancel
            }

            // The only navigation this view starts itself is loadHTMLString
            // with a nil base URL, which WebKit reports as a main-frame
            // about:blank load. Allow that; every other automatic navigation
            // (meta refresh, form post, frame load) is cancelled. Matching on
            // the URL instead of counting navigations keeps a superseded
            // load's policy callback from cancelling the real one.
            if navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.request.url?.absoluteString == "about:blank" {
                return .allow
            }
            return .cancel
        }

        private static func isExternallyOpenable(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": return true
            default: return false
            }
        }
    }
}
