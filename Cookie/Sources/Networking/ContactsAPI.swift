import Foundation

/// Talks to Cookie-Web's `cookie-web-messages` Cloudflare Worker
/// `GET /messages/contacts` — the same compose auto-suggest endpoint the web
/// app's Pinia `inbox` store calls in `loadContacts`. Returns the
/// authenticated user's contacts: addresses appearing in their mailbox
/// (received senders or sent recipients).
struct ContactsAPI {
    struct ContactsResponse: Decodable {
        let contacts: [Contact]
    }

    /// - Parameter accessToken: A valid Auth0 access token for the
    ///   `cookie-web` API audience.
    static func fetchContacts(accessToken: String) async throws -> [Contact] {
        let request = APIClient.request(CookieAPIEndpoints.contacts, accessToken: accessToken)
        return try await APIClient.send(request, decoding: ContactsResponse.self).contacts
    }
}
