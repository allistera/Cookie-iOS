import Foundation

/// Authenticated JSON requests to Cookie's Worker APIs.
struct APIClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Ephemeral and without a URLCache, so mail JSON is not cached on disk or
    /// in memory where it could outlive a sign-out.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private let tokens: TokenProvider
    private let transport: Transport

    init(
        tokens: TokenProvider,
        transport: @escaping Transport = { try await APIClient.session.data(for: $0) }
    ) {
        self.tokens = tokens
        self.transport = transport
    }

    func get<Response: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> Response {
        try await request(endpoint, method: "GET", body: nil)
    }

    /// Posts `body` as JSON. The default encoder writes snake_case keys;
    /// pass `JSONEncoder()` for routes that read camelCase.
    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ endpoint: Endpoint, body: Body, encoder: JSONEncoder = .cookieAPI()
    ) async throws -> Response {
        try await request(endpoint, method: "POST", body: try encoder.encode(body))
    }

    func patch<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ endpoint: Endpoint, body: Body, encoder: JSONEncoder = .cookieAPI()
    ) async throws -> Response {
        try await request(endpoint, method: "PATCH", body: try encoder.encode(body))
    }

    /// A 401 forces one token renewal and one retry; a second 401
    /// invalidates the session.
    private func request<Response: Decodable & Sendable>(
        _ endpoint: Endpoint, method: String, body: Data?
    ) async throws -> Response {
        guard endpoint.url != nil else { throw APIError.invalidRequest }

        let requestGeneration = await tokens.generation()
        let currentToken = try await tokens.current()
        try await ensureCurrentGeneration(requestGeneration)
        var (data, status) = try await send(
            endpoint,
            method: method,
            body: body,
            token: currentToken
        )
        try await ensureCurrentGeneration(requestGeneration)
        if status == 401 {
            let renewedToken = try await tokens.renewed()
            try await ensureCurrentGeneration(requestGeneration)
            (data, status) = try await send(
                endpoint,
                method: method,
                body: body,
                token: renewedToken
            )
            try await ensureCurrentGeneration(requestGeneration)
            if status == 401 {
                await tokens.invalidateIfCurrent(requestGeneration)
                throw APIError.unauthorised
            }
        }
        guard (200..<300).contains(status) else { throw APIError.server(status: status) }

        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try JSONDecoder.cookieAPI().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func send(_ endpoint: Endpoint, method: String, body: Data?, token: String) async throws -> (Data, Int) {
        guard let url = endpoint.url else { throw APIError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = endpoint.timeoutInterval
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport }
            return (data, http.statusCode)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport
        }
    }

    private func ensureCurrentGeneration(_ expected: UInt64) async throws {
        try Task.checkCancellation()
        guard await tokens.generation() == expected else { throw CancellationError() }
    }
}

/// For routes whose response body the app does not read.
struct EmptyResponse: Decodable, Equatable, Sendable {}
