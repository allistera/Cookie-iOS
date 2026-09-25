import Foundation
import Auth0
import Observation
import SimpleKeychain

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

    private let credentialsManager: CredentialsManager

    init(credentialsManager: CredentialsManager = CredentialsManager(authentication: Auth0.authentication())) {
        self.credentialsManager = credentialsManager
    }

    /// Restores a previously authenticated session, if one exists, without presenting any UI.
    /// The profile comes from the stored ID token, so an offline launch still lands signed in;
    /// only a credentials failure (no stored session, rejected refresh token) signs the user out.
    func restoreSession() async {
        APIClient.onUnauthorized = { [weak self] in
            Task { await self?.handleUnauthorized() }
        }

        guard credentialsManager.canRenew() || credentialsManager.hasValid() else {
            state = .unauthenticated
            return
        }

        let generation = sessionGeneration
        do {
            _ = try await credentialsManager.credentials()
        } catch let error where Self.requiresSignIn(error) {
            signOutLocally()
            return
        } catch {
            // Renewal failed for a transient reason (offline, Auth0 5xx); keep
            // the stored session and let the next API call try again.
        }
        guard !discardIfSignedOut(since: generation) else { return }

        if let profile = storedProfile() {
            state = .authenticated(profile)
        } else {
            signOutLocally()
        }
    }

    func login() async {
        errorMessage = nil

        do {
            _ = try await Auth0
                .webAuth()
                .scope("openid profile email offline_access")
                .audience(Self.apiAudience)
                .useCredentialsManager(credentialsManager)
                .start()
            if let profile = storedProfile() {
                state = .authenticated(profile)
            } else {
                errorMessage = "Signed in, but your profile could not be read. Please try again."
            }
        } catch WebAuthError.userCancelled {
            // The user dismissed the login screen; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Always signs out on this device. Clearing the Auth0 web session is best
    /// effort: if the user cancels that sheet or it fails, the local session
    /// is still gone.
    func logout() async {
        errorMessage = nil
        try? await Auth0.webAuth().logout()
        signOutLocally()
    }

    /// A valid access token for calling Cookie-Web's API, renewing it first if it has expired.
    /// Signs the user out when the stored session can no longer be renewed.
    func validAccessToken() async throws -> String {
        let generation = sessionGeneration
        let credentials: Credentials
        do {
            credentials = try await credentialsManager.credentials()
        } catch {
            if Self.requiresSignIn(error) { signOutLocally() }
            throw error
        }
        if discardIfSignedOut(since: generation) { throw CredentialsManagerError.noCredentials }
        return credentials.accessToken
    }

    /// An API answered 401 to a token that looked valid locally. Force one
    /// renewal: success means the next request carries a fresh token, while a
    /// rejected refresh token means the session is over.
    func handleUnauthorized() async {
        guard !isRenewingAfterUnauthorized, state != .unauthenticated else { return }
        isRenewingAfterUnauthorized = true
        defer { isRenewingAfterUnauthorized = false }

        let generation = sessionGeneration
        do {
            _ = try await credentialsManager.renew()
            discardIfSignedOut(since: generation)
        } catch let error where Self.requiresSignIn(error) {
            signOutLocally()
        } catch {
            // Transient failure; leave the session for the next call to retry.
        }
    }

    /// Whether a credentials failure means the stored session is unusable and
    /// the user has to sign in again. Network, rate-limit, Auth0 5xx and
    /// keychain failures other than a missing item (for example
    /// `interactionNotAllowed` before first unlock) are transient and keep the
    /// stored session.
    nonisolated static func requiresSignIn(_ error: Error) -> Bool {
        guard let error = error as? CredentialsManagerError else { return false }
        switch error {
        case .noCredentials, .noRefreshToken, .sessionExpired:
            return true
        case .renewFailed, .storeFailed:
            return causeRequiresSignIn(error.cause)
        default:
            return false
        }
    }

    /// Classifies the underlying cause of a failed renewal or store: only a
    /// rejected refresh token (Auth0 4xx other than 429) or a session missing
    /// from the keychain ends the session.
    nonisolated static func causeRequiresSignIn(_ cause: Error?) -> Bool {
        switch cause {
        case let cause as AuthenticationError:
            return (400..<500).contains(cause.statusCode) && cause.statusCode != 429
        case let cause as SimpleKeychainError:
            return cause == .itemNotFound
        default:
            return false
        }
    }

    @ObservationIgnored private var isRenewingAfterUnauthorized = false
    /// Bumped on every local sign-out, so an in-flight renewal can tell that
    /// the session it refreshed was signed out while it was on the network.
    @ObservationIgnored private var sessionGeneration = 0

    private func signOutLocally() {
        sessionGeneration += 1
        try? credentialsManager.clear()
        state = .unauthenticated
    }

    /// Auth0 stores renewed credentials even if the user signed out while the
    /// renewal was in flight. Clears them again in that case so the next
    /// launch does not quietly restore a session the user ended.
    @discardableResult
    private func discardIfSignedOut(since generation: Int) -> Bool {
        guard generation != sessionGeneration else { return false }
        try? credentialsManager.clear()
        return true
    }

    /// The signed-in user, read from the stored ID token's claims — no network.
    private func storedProfile() -> Profile? {
        guard let user = try? credentialsManager.userProfile() else { return nil }
        return Profile(name: user.name ?? user.nickname ?? "there", email: user.email, picture: user.picture)
    }
}
