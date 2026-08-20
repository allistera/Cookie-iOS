import Foundation

enum MessagesAPIError: Error {
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

/// Talks to Cookie-Web's `cookie-web-messages` Cloudflare Worker — the same
/// per-message read/flag/archive endpoint the web app's Pinia `inbox` store
/// calls (see `stores/inbox.js`'s `updateMessage` and `archiveEmail`).
struct MessagesAPI {
    static let baseURL = URL(string: "https://messages-api.infinitywave.online")!

    /// Mirrors the backend's `PATCH /messages` body. Fields left `nil` are
    /// left unchanged server-side — `patchMessage` `COALESCE`s each flag
    /// against the row's current value, so an absent key is a no-op there.
    struct PatchMessageBody: Encodable {
        let id: String
        var isUnread: Bool?
        var isStarred: Bool?
        var isArchived: Bool?
        var isDeleted: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isUnread = "is_unread"
            case isStarred = "is_starred"
            case isArchived = "is_archived"
            case isDeleted = "is_deleted"
        }
    }

    /// Updates one or more flags on a message the caller owns.
    static func updateMessage(_ body: PatchMessageBody, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MessagesAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MessagesAPIError.unauthorized }
            throw MessagesAPIError.server(status: http.statusCode)
        }
    }

    /// Marks a message "Done" — archives it and clears its unread flag,
    /// mirroring Cookie-Web's `archiveEmail` (`{ is_archived: true, is_unread: false }`).
    static func markDone(id: String, accessToken: String) async throws {
        try await updateMessage(
            PatchMessageBody(id: id, isUnread: false, isArchived: true),
            accessToken: accessToken
        )
    }
}
