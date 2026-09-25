import Foundation

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

    static func sendMail(_ body: SendMailBody, accessToken: String) async throws {
        let request = APIClient.request(
            CookieAPIEndpoints.send,
            method: "POST",
            accessToken: accessToken,
            jsonBody: try JSONEncoder().encode(body)
        )
        try await APIClient.send(request)
    }
}
