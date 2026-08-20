import Foundation
import Auth0
import Observation

@MainActor
@Observable
final class AuthenticationManager {
    enum State: Equatable {
        case loading
        case authenticated(Profile)
        case unauthenticated
    }

    struct Profile: Equatable {
        let name: String
        let email: String?
        let picture: URL?
    }

    /// Must match Cookie-Web's `VITE_AUTH0_AUDIENCE` so Auth0 issues a signed
    /// JWT access token that the backend's `verifyAccessToken` can validate,
    /// rather than an opaque token only good for the `/userinfo` endpoint.
    private static let apiAudience = "https://cookie-web/api"

    private(set) var state: State = .loading
    var errorMessage: String?

    private let credentialsManager = CredentialsManager(authentication: Auth0.authentication())

    /// Restores a previously authenticated session, if one exists, without presenting any UI.
    func restoreSession() async {
        guard credentialsManager.canRenew() || credentialsManager.hasValid() else {
            state = .unauthenticated
            return
        }

        do {
            let credentials = try await credentialsManager.credentials()
            state = .authenticated(try await fetchProfile(accessToken: credentials.accessToken))
        } catch {
            state = .unauthenticated
        }
    }

    func login() async {
        errorMessage = nil

        do {
            let credentials = try await Auth0
                .webAuth()
                .scope("openid profile email offline_access")
                .audience(Self.apiAudience)
                .useCredentialsManager(credentialsManager)
                .start()
            state = .authenticated(try await fetchProfile(accessToken: credentials.accessToken))
        } catch WebAuthError.userCancelled {
            // The user dismissed the login screen; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() async {
        errorMessage = nil

        do {
            try await Auth0
                .webAuth()
                .useCredentialsManager(credentialsManager)
                .logout()
            state = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A valid access token for calling Cookie-Web's API, renewing it first if it has expired.
    func validAccessToken() async throws -> String {
        try await credentialsManager.credentials().accessToken
    }

    private func fetchProfile(accessToken: String) async throws -> Profile {
        let user = try await Auth0
            .authentication()
            .userInfo(withAccessToken: accessToken)
            .start()
        return Profile(name: user.name ?? user.nickname ?? "there", email: user.email, picture: user.picture)
    }
}
