import Foundation
import Testing

@testable import Cookie

/// Records what the client asked for, without shared global state.
private actor CallLog {
    private(set) var requests: [URLRequest] = []
    private(set) var renewals = 0
    private(set) var invalidations = 0

    func record(_ request: URLRequest) -> Int {
        requests.append(request)
        return requests.count
    }

    func recordRenewal() { renewals += 1 }
    func recordInvalidation() { invalidations += 1 }
}

private struct StubResponse: Sendable {
    let status: Int
    let body: String
}

private struct Payload: Decodable, Equatable, Sendable {
    let unreadCount: Int
}

private actor GenerationBox {
    private(set) var value: UInt64 = 0

    func read() -> UInt64 { value }
    func advance() { value &+= 1 }
}

struct APIClientTests {
    /// A client whose transport answers the nth request with the nth stub,
    /// repeating the last stub for any further requests.
    private func makeClient(_ stubs: [StubResponse], log: CallLog) -> APIClient {
        let tokens = TokenProvider(
            current: { "first-token" },
            renewed: {
                await log.recordRenewal()
                return "renewed-token"
            },
            invalidate: { await log.recordInvalidation() }
        )
        return APIClient(tokens: tokens) { request in
            let index = await log.record(request) - 1
            let stub = stubs[min(index, stubs.count - 1)]
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(stub.body.utf8), response)
        }
    }

    @Test func attachesBearerTokenAndDecodesSuccess() async throws {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: #"{"unreadCount":7}"#)], log: log)

        let state: Payload = try await client.get(CookieAPIEndpoints.categories)

        #expect(state == Payload(unreadCount: 7))
        let requests = await log.requests
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer first-token")
        #expect(requests.first?.url?.absoluteString == "https://labels-api.infinitywave.online/categories")
        #expect(requests.first?.timeoutInterval == 60)
    }

    @Test func refreshEndpointUsesBoundedLongTimeout() async throws {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "{}")], log: log)

        let _: EmptyResponse = try await client.post(CookieAPIEndpoints.tasksRefresh, body: EmptyBody())

        #expect(await log.requests.first?.timeoutInterval == 240)
    }

    @Test func renewsTokenAndRetriesOnceAfterUnauthorised() async throws {
        let log = CallLog()
        let client = makeClient(
            [StubResponse(status: 401, body: "{}"), StubResponse(status: 200, body: #"{"unreadCount":2}"#)],
            log: log
        )

        let state: Payload = try await client.get(CookieAPIEndpoints.categories)

        #expect(state == Payload(unreadCount: 2))
        let requests = await log.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-token")
        #expect(await log.renewals == 1)
        #expect(await log.invalidations == 0)
    }

    @Test func secondUnauthorisedInvalidatesSessionAndThrows() async {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 401, body: "{}")], log: log)

        await #expect(throws: APIError.unauthorised) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
        #expect(await log.requests.count == 2)
        #expect(await log.invalidations == 1)
    }

    @Test func staleResponseCannotInvalidateANewerAuthenticationContext() async {
        let log = CallLog()
        let generation = GenerationBox()
        let tokens = TokenProvider(
            current: { "token" },
            renewed: { "renewed-token" },
            invalidate: { await log.recordInvalidation() },
            generation: { await generation.read() },
            invalidateIfCurrent: { expected in
                guard await generation.read() == expected else { return }
                await log.recordInvalidation()
            }
        )
        let client = APIClient(tokens: tokens) { request in
            await generation.advance()
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data("{}".utf8), response)
        }

        await #expect(throws: CancellationError.self) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
        #expect(await log.invalidations == 0)
    }

    @Test func serverErrorIsNotRetried() async {
        let log = CallLog()
        let stub = StubResponse(status: 500, body: #"{"error":"Failed to load inbox state"}"#)
        let client = makeClient([stub], log: log)

        await #expect(throws: APIError.server(status: 500)) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
        #expect(await log.requests.count == 1)
    }

    @Test func malformedBodyThrowsDecoding() async {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "not json")], log: log)

        await #expect(throws: APIError.decoding) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
    }

    @Test func transportFailureThrowsTransport() async {
        let tokens = TokenProvider(current: { "token" }, renewed: { "token" }, invalidate: {})
        let client = APIClient(tokens: tokens) { _ in throw URLError(.notConnectedToInternet) }

        await #expect(throws: APIError.transport) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
    }

    @Test func cancelledRequestThrowsCancellationNotTransport() async {
        let tokens = TokenProvider(current: { "token" }, renewed: { "token" }, invalidate: {})
        let client = APIClient(tokens: tokens) { _ in throw URLError(.cancelled) }

        await #expect(throws: CancellationError.self) {
            let _: Payload = try await client.get(CookieAPIEndpoints.categories)
        }
    }

    @Test func endpointWithoutURLThrowsInvalidRequest() async {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "{}")], log: log)

        await #expect(throws: APIError.invalidRequest) {
            let _: Payload = try await client.get(Endpoint(host: "example.com", path: "no-slash"))
        }
        #expect(await log.requests.isEmpty)
    }

    @Test func postEncodesSnakeCaseBodyAndContentType() async throws {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "{}")], log: log)

        let _: EmptyResponse = try await client.post(
            CookieAPIEndpoints.messages, body: MarkReadRequest(id: "m1", isUnread: false))

        let request = try #require(await log.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(json?["id"] as? String == "m1")
        #expect(json?["is_unread"] as? Bool == false)
    }

    @Test func patchWithPlainEncoderKeepsCamelCase() async throws {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "{}")], log: log)
        let body = SendRequest(
            recipient: "a@example.com", subject: "Re: x", text: "hi", replyToMessageId: "m1", requestId: "r1")

        let _: EmptyResponse = try await client.patch(CookieAPIEndpoints.send, body: body, encoder: JSONEncoder())

        let request = try #require(await log.requests.first)
        #expect(request.httpMethod == "PATCH")
        let json = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(json?["replyToMessageId"] as? String == "m1")
        #expect(json?["requestId"] as? String == "r1")
    }

    @Test func emptyResponseIgnoresBody() async throws {
        let log = CallLog()
        let client = makeClient([StubResponse(status: 200, body: "not json")], log: log)
        let _: EmptyResponse = try await client.get(CookieAPIEndpoints.categories)
    }

    @Test func productionSessionKeepsNoResponseCache() {
        let configuration = APIClient.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
