import Foundation

/// The failures every Cookie API call can surface, whichever Worker it hits.
enum APIError: Error, Equatable {
    /// The Worker rejected the access token (401).
    case unauthorized
    /// The row changed elsewhere since it was loaded (409); the write was
    /// rejected rather than clobbering the newer copy.
    case conflict
    /// The per-user AI quota (10 requests/minute) was exhausted (429) —
    /// surfaced separately so the UI can show the same wait-a-moment message
    /// the web app does.
    case rateLimited
    case server(status: Int)
    case invalidResponse
}

/// Names call sites already match on (`catch CalendarEventsAPIError.rateLimited`,
/// `== DocumentsAPIError.conflict`); they are the shared `APIError`.
typealias CalendarEventsAPIError = APIError
typealias DocumentsAPIError = APIError

/// The one place Cookie API requests are built and their responses checked:
/// bearer token, JSON body, status mapping and decoding.
enum APIClient {
    /// Called when a Worker answers 401, so the session owner can try a token
    /// renewal and sign out if the refresh token itself is no longer valid.
    @MainActor static var onUnauthorized: (@MainActor () -> Void)?

    static func request(_ url: URL, method: String = "GET", accessToken: String, jsonBody: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return request
    }

    /// `base` with `query` as its query string.
    static func url(_ base: URL, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    /// The error a non-2xx status maps to, or `nil` for a success.
    static func error(forStatus status: Int) -> APIError? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 409: return .conflict
        case 429: return .rateLimited
        default: return .server(status: status)
        }
    }

    @discardableResult
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if let error = error(forStatus: http.statusCode) {
            if error == .unauthorized { await reportUnauthorized() }
            throw error
        }
        return data
    }

    static func send<Response: Decodable>(_ request: URLRequest, decoding type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: try await send(request))
    }

    @MainActor private static func reportUnauthorized() {
        onUnauthorized?()
    }
}
