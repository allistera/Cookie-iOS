import SwiftUI

@main
struct CookieApp: App {
    @State private var auth = AuthenticationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task {
                    await auth.restoreSession()
                }
        }
    }
}
