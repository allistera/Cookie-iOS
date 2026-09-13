import Foundation

/// The full body of a single message, from `GET /messages?id=<uuid>`. The
/// endpoint returns more fields (thread, attachments, unsubscribe, summary);
/// decoding ignores everything not declared here.
struct MessageBody: Decodable {
    /// Raw, sender-controlled HTML. Render only inside `EmailBodyWebView`'s
    /// locked-down WKWebView — never in a native text view.
    let bodyHtml: String?
    let bodyText: String?

    enum CodingKeys: String, CodingKey {
        case bodyHtml = "body_html"
        case bodyText = "body_text"
    }

    /// The API can return an empty or whitespace-only HTML field for a
    /// plain-text message. Treat that as absent so the reader does not swap
    /// its loading state for an empty web view.
    var renderableHtml: String? {
        Self.nonBlank(bodyHtml)
    }

    var renderableText: String? {
        Self.nonBlank(bodyText)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

enum MessagesAPIError: Error {
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

/// Talks to Cookie-Web's `cookie-web-messages` Cloudflare Worker — the same
/// per-message read/flag/archive endpoint the web app's Pinia `inbox` store
/// calls (see `stores/inbox.js`'s `updateMessage` and `archiveEmail`).
struct MessagesAPI {
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

        /// The flags Cookie-Web sets when an email is marked "Done":
        /// archived and no longer unread. Star/delete are left untouched so
        /// the server `COALESCE`s them to their current values.
        static func done(id: String) -> PatchMessageBody {
            PatchMessageBody(id: id, isUnread: false, isArchived: true)
        }
    }

    /// Updates one or more flags on a message the caller owns.
    static func updateMessage(_ body: PatchMessageBody, accessToken: String) async throws {
        var request = URLRequest(url: CookieAPIEndpoints.messages)
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
        try await updateMessage(.done(id: id), accessToken: accessToken)
    }

    /// Fetches one message's full body — the same `GET /messages?id=` call
    /// Cookie-Web's `fetchMessageBodyUncached` makes when its reader opens.
    /// The inbox list deliberately omits `body_html`, so this is the only
    /// source of the complete message text.
    static func fetchMessageBody(id: String, accessToken: String) async throws -> MessageBody {
        guard
            var components = URLComponents(
                url: CookieAPIEndpoints.messages,
                resolvingAgainstBaseURL: false
            )
        else {
            throw MessagesAPIError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "calendar", value: "deferred")]
        guard let url = components.url else {
            throw MessagesAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
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

        return try JSONDecoder().decode(MessageBody.self, from: data)
    }
}
