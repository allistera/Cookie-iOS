import Foundation

enum SendAPIError: Error {
    case unauthorized
    case server(status: Int)
    case invalidResponse
}

/// Talks to the `cookie-web-send` Cloudflare Worker's `POST /send` endpoint.
/// It delivers through Resend and stores the sent copy in the same request.
struct SendAPI {
    /// Mirrors the backend's `POST /send` body. `replyToMessageId`
    /// threads the stored sent copy with the message being replied to.
    struct SendMailBody: Encodable {
        let to: String
        let subject: String
        let text: String
        var html: String?
        var replyToMessageId: String?
        var requestId: String = UUID().uuidString
    }

    @discardableResult
    static func sendMail(_ body: SendMailBody, accessToken: String) async throws {
        var request = URLRequest(url: CookieAPIEndpoints.send)
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
