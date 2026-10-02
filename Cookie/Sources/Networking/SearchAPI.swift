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
        var queryItems = [URLQueryItem(name: "q", value: query)]
        if !semantic {
            queryItems.append(URLQueryItem(name: "mode", value: "keyword"))
        }
        // APIClient.url encodes "+" as %2B, so "c++" isn't read as "c  ".
        return try await APIClient.get(
            CookieAPIEndpoints.search,
            query: queryItems,
            accessToken: accessToken,
            decoding: EmailListResponse.self
        ).emails
    }
}
