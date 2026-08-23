import Foundation

/// Talks to Cookie-Web's `cookie-web-messages` Cloudflare Worker
/// `GET /messages/contacts` — the same compose auto-suggest endpoint the web
/// app's Pinia `inbox` store calls in `loadContacts`. Returns the
/// authenticated user's contacts: addresses appearing in their mailbox
/// (received senders or sent recipients).
struct ContactsAPI {
    static let baseURL = MessagesAPI.baseURL

    struct ContactsResponse: Decodable {
        let contacts: [Contact]
    }

    /// - Parameter accessToken: A valid Auth0 access token for the
    ///   `cookie-web` API audience.
    static func fetchContacts(accessToken: String) async throws -> [Contact] {
        var request = URLRequest(url: baseURL.appendingPathComponent("messages/contacts"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MessagesAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MessagesAPIError.unauthorized }
            throw MessagesAPIError.server(status: http.statusCode)
        }

        return try JSONDecoder().decode(ContactsResponse.self, from: data).contacts
    }
}
