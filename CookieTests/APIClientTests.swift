import XCTest
@testable import Cookie

final class APIClientTests: XCTestCase {
    func testSuccessStatusesMapToNoError() {
        XCTAssertNil(APIClient.error(forStatus: 200))
        XCTAssertNil(APIClient.error(forStatus: 204))
        XCTAssertNil(APIClient.error(forStatus: 299))
    }

    /// Every Worker shares one mapping, so a 409 or 429 surfaces the same
    /// way whichever API returned it.
    func testErrorStatusesMapToSharedAPIErrors() {
        XCTAssertEqual(APIClient.error(forStatus: 401), .unauthorized)
        XCTAssertEqual(APIClient.error(forStatus: 409), .conflict)
        XCTAssertEqual(APIClient.error(forStatus: 429), .rateLimited)
        XCTAssertEqual(APIClient.error(forStatus: 403), .server(status: 403))
        XCTAssertEqual(APIClient.error(forStatus: 500), .server(status: 500))
        XCTAssertEqual(APIClient.error(forStatus: 302), .server(status: 302))
    }

    func testRequestAttachesBearerTokenAndJSONBody() throws {
        let body = Data(#"{"id":"abc"}"#.utf8)
        let request = APIClient.request(
            CookieAPIEndpoints.messages,
            method: "PATCH",
            accessToken: "token-123",
            jsonBody: body
        )

        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, body)
    }

    func testRequestWithoutBodyIsAPlainGet() {
        let request = APIClient.request(CookieAPIEndpoints.contacts, accessToken: "token-123")

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(request.httpBody)
    }

    func testURLAppendsQueryItems() throws {
        let url = try APIClient.url(
            CookieAPIEndpoints.documents,
            query: [URLQueryItem(name: "id", value: "doc 1")]
        )

        XCTAssertEqual(url.absoluteString, "https://tasks-api.infinitywave.online/documents?id=doc%201")
    }

    /// The Workers parse queries with URLSearchParams, which reads a literal
    /// "+" as a space — search terms and timestamp cursors need %2B.
    func testURLEncodesPlusSigns() throws {
        let url = try APIClient.url(
            CookieAPIEndpoints.search,
            query: [URLQueryItem(name: "q", value: "c++ notes")]
        )

        XCTAssertEqual(url.query(percentEncoded: true), "q=c%2B%2B%20notes")
    }
}

@MainActor
final class APIClientUnauthorizedRetryTests: XCTestCase {
    /// Answers 401 to `stale-token` and 200 to anything else, recording the
    /// Authorization header of every request it sees.
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var seenTokens: [String] = []

        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.seenTokens.append(token)
            let status = token == "Bearer stale-token" ? 401 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        StubProtocol.seenTokens = []
        URLProtocol.registerClass(StubProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
        // XCTest runs a @MainActor test case's tearDown on the main thread,
        // but the override itself is nonisolated.
        MainActor.assumeIsolated { APIClient.onUnauthorized = nil }
        super.tearDown()
    }

    func testA401IsRetriedOnceWithTheRenewedToken() async throws {
        var renewals = 0
        APIClient.onUnauthorized = {
            renewals += 1
            return "fresh-token"
        }

        try await APIClient.send(APIClient.request(CookieAPIEndpoints.messages, accessToken: "stale-token"))

        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(StubProtocol.seenTokens, ["Bearer stale-token", "Bearer fresh-token"])
    }

    func testA401AfterRenewalIsNotRetriedAgain() async {
        var renewals = 0
        APIClient.onUnauthorized = {
            renewals += 1
            return "stale-token"
        }

        do {
            try await APIClient.send(APIClient.request(CookieAPIEndpoints.messages, accessToken: "stale-token"))
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(StubProtocol.seenTokens.count, 2)
    }

    func testFailedRenewalSurfacesTheOriginal401() async {
        APIClient.onUnauthorized = { nil }

        do {
            try await APIClient.send(APIClient.request(CookieAPIEndpoints.messages, accessToken: "stale-token"))
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertEqual(StubProtocol.seenTokens, ["Bearer stale-token"])
    }
}
