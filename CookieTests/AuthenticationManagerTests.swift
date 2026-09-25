import Auth0
import SimpleKeychain
import XCTest
@testable import Cookie

@MainActor
final class AuthenticationManagerTests: XCTestCase {
    /// Keychain stand-in so each test starts from a known stored session. It
    /// throws the same errors as SimpleKeychain so failures classify as on device.
    private final class InMemoryStorage: CredentialsStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Data] = [:]
        private var _readError: SimpleKeychainError?

        var isEmpty: Bool { lock.withLock { entries.isEmpty } }

        /// When set, every read fails with this error, as the keychain does
        /// while protected data is unavailable.
        var readError: SimpleKeychainError? {
            get { lock.withLock { _readError } }
            set { lock.withLock { _readError = newValue } }
        }

        func getEntry(forKey key: String) throws -> Data {
            if let readError { throw readError }
            guard let data = lock.withLock({ entries[key] }) else { throw SimpleKeychainError.itemNotFound }
            return data
        }

        func setEntry(_ data: Data, forKey key: String) throws {
            lock.withLock { entries[key] = data }
        }

        func deleteEntry(forKey key: String) throws {
            _ = lock.withLock { entries.removeValue(forKey: key) }
        }

        func deleteAllEntries() throws {
            lock.withLock { entries.removeAll() }
        }
    }

    private let storage = InMemoryStorage()

    /// The authentication client points at an unreachable domain: none of
    /// these paths may touch the network.
    private func makeManager(storing credentials: Credentials? = nil) throws -> AuthenticationManager {
        let credentialsManager = CredentialsManager(
            authentication: Auth0.authentication(clientId: "test-client", domain: "cookie-tests.invalid"),
            storage: storage
        )
        if let credentials {
            try credentialsManager.store(credentials: credentials)
        }
        return AuthenticationManager(credentialsManager: credentialsManager)
    }

    private func idToken(claims: [String: Any]) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let payload = base64URL(try JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).signature"
    }

    func testRestoreWithoutStoredSessionSignsOut() async throws {
        let auth = try makeManager()

        await auth.restoreSession()

        XCTAssertEqual(auth.state, .unauthenticated)
    }

    /// The profile comes from the stored ID token, so a launch with no
    /// connectivity still lands signed in.
    func testRestoreBuildsProfileFromStoredIDTokenWithoutNetwork() async throws {
        let token = try idToken(claims: ["sub": "auth0|ada", "name": "Ada Lovelace", "email": "ada@example.com"])
        let auth = try makeManager(storing: Credentials(
            accessToken: "access",
            tokenType: "Bearer",
            idToken: token,
            expiresAt: Date().addingTimeInterval(3600)
        ))

        await auth.restoreSession()

        XCTAssertEqual(
            auth.state,
            .authenticated(.init(name: "Ada Lovelace", email: "ada@example.com", picture: nil))
        )
    }

    /// An expired session with no refresh token can never renew: asking for
    /// a token must clear it and send the user back to sign in rather than
    /// leaving every screen failing.
    func testValidAccessTokenSignsOutWhenSessionCannotRenew() async throws {
        let token = try idToken(claims: ["sub": "auth0|ada", "name": "Ada Lovelace"])
        let auth = try makeManager(storing: Credentials(
            accessToken: "access",
            tokenType: "Bearer",
            idToken: token,
            expiresAt: Date().addingTimeInterval(-60)
        ))

        do {
            _ = try await auth.validAccessToken()
            XCTFail("An unrenewable session must not return a token")
        } catch {
            XCTAssertTrue(AuthenticationManager.requiresSignIn(error))
        }

        XCTAssertEqual(auth.state, .unauthenticated)
        XCTAssertTrue(storage.isEmpty)
    }

    func testOnlyCredentialFailuresRequireSignIn() {
        XCTAssertTrue(AuthenticationManager.requiresSignIn(CredentialsManagerError.noCredentials))
        XCTAssertTrue(AuthenticationManager.requiresSignIn(CredentialsManagerError.noRefreshToken))
        XCTAssertTrue(AuthenticationManager.requiresSignIn(CredentialsManagerError.sessionExpired))
        XCTAssertFalse(AuthenticationManager.requiresSignIn(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AuthenticationManager.requiresSignIn(APIError.unauthorized))
    }

    /// A locked keychain (a background or prewarm launch before first unlock)
    /// is temporary: the stored refresh token must survive it.
    func testValidAccessTokenKeepsSessionWhenKeychainIsLocked() async throws {
        let token = try idToken(claims: ["sub": "auth0|ada", "name": "Ada Lovelace"])
        let auth = try makeManager(storing: Credentials(
            accessToken: "access",
            tokenType: "Bearer",
            idToken: token,
            expiresAt: Date().addingTimeInterval(3600)
        ))
        storage.readError = .interactionNotAllowed

        do {
            _ = try await auth.validAccessToken()
            XCTFail("A locked keychain must not return a token")
        } catch {
            XCTAssertFalse(AuthenticationManager.requiresSignIn(error))
        }

        XCTAssertNotEqual(auth.state, .unauthenticated)
        storage.readError = nil
        XCTAssertFalse(storage.isEmpty)
    }

    /// A session missing from the keychain surfaces as renewFailed with an
    /// itemNotFound cause, and must send the user back to sign in.
    func testValidAccessTokenSignsOutWhenKeychainHasNoSession() async throws {
        let auth = try makeManager()

        do {
            _ = try await auth.validAccessToken()
            XCTFail("A missing session must not return a token")
        } catch {
            XCTAssertTrue(AuthenticationManager.requiresSignIn(error))
        }

        XCTAssertEqual(auth.state, .unauthenticated)
    }

    func testOnlyRejectedRefreshOrMissingSessionCausesRequireSignIn() {
        struct OtherError: Error {}
        XCTAssertTrue(AuthenticationManager.causeRequiresSignIn(AuthenticationError(info: [:], statusCode: 403)))
        XCTAssertTrue(AuthenticationManager.causeRequiresSignIn(SimpleKeychainError.itemNotFound))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(AuthenticationError(info: [:], statusCode: 429)))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(AuthenticationError(info: [:], statusCode: 503)))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(SimpleKeychainError.interactionNotAllowed))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(OtherError()))
        XCTAssertFalse(AuthenticationManager.causeRequiresSignIn(nil))
    }
}
