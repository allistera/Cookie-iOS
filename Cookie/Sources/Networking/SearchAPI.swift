import Foundation

/// Talks to the `cookie-web-search` Cloudflare Worker's `GET /search` — the
/// same hybrid (keyword + semantic) mailbox search the web app's inbox store
/// calls from `searchEmails`. Result rows match `GET /emails`, so they
/// decode with the same `EmailMessage` model and response envelope.
struct SearchAPI {
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
                url: CookieAPIEndpoints.search,
                resolvingAgainstBaseURL: false
            )
        else {
            throw APIError.invalidResponse
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
            throw APIError.invalidResponse
        }

        let request = APIClient.request(url, accessToken: accessToken)
        return try await APIClient.send(request, decoding: EmailListResponse.self).emails
    }
}
