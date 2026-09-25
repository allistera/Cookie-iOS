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
}
