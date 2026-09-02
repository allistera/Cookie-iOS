import Foundation

/// A single label attached to a message, as returned by the inbox list endpoint.
struct EmailLabel: Decodable, Hashable {
    let name: String
    let color: String?
    let kind: String?
}

/// A message row from `GET /emails`, matching the shape the Cookie-Web inbox
/// consumes from `cookie-web-emails`.
struct EmailMessage: Decodable, Identifiable {
    let id: String
    let fromName: String?
    let fromAddress: String
    let subject: String?
    let snippet: String?
    let sentAt: String
    let isUnread: Bool
    let isStarred: Bool
    let isSent: Bool
    let hasHtml: Bool
    let hasAiSummary: Bool
    let hasAttachments: Bool
    let labels: [EmailLabel]

    enum CodingKeys: String, CodingKey {
        case id
        case fromName = "from_name"
        case fromAddress = "from_address"
        case subject
        case snippet
        case sentAt = "sent_at"
        case isUnread = "is_unread"
        case isStarred = "is_starred"
        case isSent = "is_sent"
        case hasHtml = "has_html"
        case hasAiSummary = "has_ai_summary"
        case hasAttachments = "has_attachments"
        case labels
    }
}

/// The response body of `GET /emails`.
struct EmailListResponse: Decodable {
    let emails: [EmailMessage]
    let nextCursor: String?
    let unreadCount: Int?
    let userId: String?
    let readReceiptsAvailable: Bool?
}

enum EmailsAPIError: Error {
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

/// Talks to the `cookie-web-emails` Cloudflare Worker — the same `/emails`
/// endpoint the web app's Pinia inbox store calls.
struct EmailsAPI {
    /// - Parameters:
    ///   - folder: One of `inbox`, `sent`, `spam`, `snoozed`, `done`, `starred`, `label`.
    ///   - before: Opaque `"<sentAt>|<id>"` cursor copied from a previous page's `nextCursor`.
    ///   - accessToken: A valid Auth0 access token for the `cookie-web` API audience.
    static func fetchEmails(
        folder: String = "inbox",
        limit: Int = 50,
        before: String? = nil,
        accessToken: String
    ) async throws -> EmailListResponse {
        guard
            var components = URLComponents(
                url: CookieAPIEndpoints.emails,
                resolvingAgainstBaseURL: false
            )
        else {
            throw EmailsAPIError.invalidResponse
        }

        var queryItems = [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw EmailsAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmailsAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw EmailsAPIError.unauthorized }
            throw EmailsAPIError.server(status: http.statusCode)
        }

        return try JSONDecoder().decode(EmailListResponse.self, from: data)
    }
}
