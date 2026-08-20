import Foundation

enum SendAPIError: Error {
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

/// Talks to Cookie-Web's `POST /api/send` on the Vercel deployment — the
/// same endpoint the web app's Pinia `inbox` store calls from `sendMail`.
/// Sending stays on Vercel rather than the `cookie-web-messages` Cloudflare
/// Worker (unlike per-message read/flag updates) because it talks to Resend
/// and writes the sent copy in the same request.
struct SendAPI {
    static let baseURL = URL(string: "https://mail.infinitywave.online")!

    /// Mirrors the backend's `POST /api/send` body. `replyToMessageId`
    /// threads the stored sent copy with the message being replied to.
    struct SendMailBody: Encodable {
        let to: String
        let subject: String
        let text: String
        var html: String?
        var replyToMessageId: String?
    }

    @discardableResult
    static func sendMail(_ body: SendMailBody, accessToken: String) async throws -> Void {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/send"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw SendAPIError.unauthorized }
            throw SendAPIError.server(status: http.statusCode)
        }
    }
}
