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
        Task { @MainActor in
            await context.coordinator.load(
                html: html,
                blocksRemoteImages: blocksRemoteImages,
                into: webView
            )
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.needsReload(html: html, blocksRemoteImages: blocksRemoteImages) {
            Task { @MainActor in
                await context.coordinator.load(
                    html: html,
                    blocksRemoteImages: blocksRemoteImages,
                    into: webView
                )
            }
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

        private(set) var loadedHtml: String?
        private(set) var loadedBlocksRemoteImages: Bool?
        private var hasAllowedInitialNavigation = false
        private var observation: NSKeyValueObservation?

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
            guard height > 0, abs(height - contentHeight.wrappedValue) > 0.5 else { return }
            contentHeight.wrappedValue = height
        }

        func needsReload(html: String, blocksRemoteImages: Bool) -> Bool {
            html != loadedHtml || blocksRemoteImages != loadedBlocksRemoteImages
        }

        func load(html: String, blocksRemoteImages: Bool, into webView: WKWebView) async {
            loadedHtml = html
            loadedBlocksRemoteImages = blocksRemoteImages
            hasAllowedInitialNavigation = false

            webView.configuration.userContentController.removeAllContentRuleLists()
            if blocksRemoteImages,
               let ruleList = await Self.remoteImageBlockRuleList() {
                webView.configuration.userContentController.add(ruleList)
            }

            webView.loadHTMLString(Self.document(html: html), baseURL: nil)
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

            // Allow exactly one navigation per loadHTMLString call; every
            // other automatic navigation (meta refresh, form post, frame
            // load) is cancelled.
            if hasAllowedInitialNavigation { return .cancel }
            hasAllowedInitialNavigation = true
            return .allow
        }

        private static func isExternallyOpenable(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": return true
            default: return false
            }
        }
    }
}
