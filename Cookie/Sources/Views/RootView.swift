import SwiftUI

struct RootView: View {
    @Environment(AuthenticationManager.self) private var auth
    /// A link that arrives before the inbox is on screen (cold launch, the
    /// session still restoring) waits here until InboxView can act on it.
    @State private var deepLink: InboxDeepLink?

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                ProgressView()
            case .unauthenticated:
                LoginView()
            case .authenticated(let profile):
                InboxView(profile: profile, deepLink: $deepLink)
            }
        }
        .onOpenURL { url in
            if let link = InboxDeepLink.parse(url) { deepLink = link }
        }
    }
}
