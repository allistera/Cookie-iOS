import Foundation

/// Talks to Cookie-Web's `GET /api/search` on the Vercel deployment — the
/// same hybrid (keyword + semantic) mailbox search the web app's inbox store
/// calls from `searchEmails`. Result rows match `GET /api/emails`, so they
/// decode with the same `EmailMessage` model and response envelope.
struct SearchAPI {
    static let baseURL = EmailsAPI.baseURL

    /// - Parameters:
    ///   - query: Free text, optionally using the web app's structured
    ///     operators (`tag:`, `sender:`, `in:done`, …). The server rejects
    ///     queries over 500 characters.
    ///   - semantic: `true` for the hybrid relevance search an explicit
    ///     submit runs; `false` for the keyword-only type-ahead mode, which
    ///     skips the embedding round trip and never spends the shared
    ///     AI quota.
    static func searchEmails(query: String, semantic: Bool, accessToken: String) async throws -> [EmailMessage] {
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/search"),
                resolvingAgainstBaseURL: false
            )
        else {
            throw EmailsAPIError.invalidResponse
        }

        var queryItems = [URLQueryItem(name: "q", value: query)]
        if !semantic {
            queryItems.append(URLQueryItem(name: "mode", value: "keyword"))
        }
        components.queryItems = queryItems
        // URLComponents leaves "+" literal, but the server parses the query
        // with URLSearchParams, which reads "+" as a space — the web client's
        // encodeURIComponent sends %2B, so match it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

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

        return try JSONDecoder().decode(EmailListResponse.self, from: data).emails
    }
}
