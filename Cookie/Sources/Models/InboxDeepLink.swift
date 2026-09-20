import Foundation

/// A link into the app on its own URL scheme (the bundle id). ntfy
/// notifications from cookie-web-notifications carry
/// `com.cookie.ios://inbox?open=<message id>` as an "Open in Cookie app"
/// action, the counterpart of the web's `/inbox?open=<id>` route.
///
/// Anything else on the scheme — Auth0's sign-in callback shares it — is not
/// a deep link and parses as nil.
enum InboxDeepLink: Equatable {
    case email(id: UUID)

    static let scheme = "com.cookie.ios"

    static func parse(_ url: URL) -> InboxDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "inbox",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "open" })?.value,
              let id = UUID(uuidString: raw)
        else { return nil }
        return .email(id: id)
    }
}
