import SwiftUI

struct RootView: View {
    @Environment(AuthenticationManager.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .unauthenticated:
            LoginView()
        case .authenticated(let profile):
            InboxView(profile: profile)
        }
    }
}
