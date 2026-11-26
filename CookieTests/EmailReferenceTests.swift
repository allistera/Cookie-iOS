import Foundation
import Testing

@testable import Cookie

private actor PageResponses {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}

private actor URLLog {
    private(set) var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }
}

@MainActor
struct EmailReferenceTests {
    @Test func resolvesMetadataFromLaterInboxPageWithoutRefetchingBody() async throws {
        let responses = PageResponses([
            """
            {"emails":[{"id":"other","from_name":"Other","from_address":"other@example.com",
            "subject":"Other","sent_at":"2026-10-05T09:00:00Z","is_unread":false,"labels":[]}],
            "nextCursor":"cursor-1"}
            """,
            """
            {"emails":[{"id":"target","from_name":"Jordan Blake","from_address":"jordan@example.com",
            "subject":"Final terms","snippet":"Please review.","sent_at":"2026-10-05T09:48:12Z",
            "is_unread":true,"labels":[]}],"nextCursor":null}
            """,
        ])
        let log = URLLog()
        let tokens = TokenProvider(current: { "t" }, renewed: { "t" }, invalidate: {})
        let client = APIClient(tokens: tokens) { request in
            guard let url = request.url else { throw URLError(.badURL) }
            await log.append(url)
            let body = await responses.next()
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(body.utf8), response)
        }
        let mailbox = Mailbox(client: client)
        let body = try JSONDecoder.cookieAPI().decode(
            MessageBody.self,
            from: Data(#"{"id":"target","subject":"Final terms","body_text":"Please review."}"#.utf8))

        let resolution = try await EmailReference.resolve(
            for: "target", unread: true, from: body, mailbox: mailbox, client: client)

        guard case .found(let email, let resolvedBody, let isInboxMessage) = resolution else {
            Issue.record("expected a mailbox row from the second inbox page")
            return
        }
        #expect(email.id == "target")
        #expect(email.senderName == "Jordan Blake")
        #expect(email.subject == "Final terms")
        #expect(email.sentAt == Date(timeIntervalSince1970: 1_791_193_692))
        #expect(email.isUnread)
        #expect(resolvedBody == body)
        #expect(isInboxMessage == true)
        #expect((await log.urls).allSatisfy { $0.path == "/emails" })
        #expect((await log.urls).count == 2)
    }

    @Test func bodyWithoutMailboxMetadataIsDistinctFromMissingBody() async throws {
        let responses = PageResponses([
            #"{"emails":[],"nextCursor":null}"#,
            #"{"emails":[],"nextCursor":null}"#,
            #"{"emails":[],"nextCursor":null}"#,
            #"{"emails":[],"nextCursor":null}"#,
            #"{"emails":[],"nextCursor":null}"#,
            #"{"emails":[],"nextCursor":null}"#,
        ])
        let tokens = TokenProvider(current: { "t" }, renewed: { "t" }, invalidate: {})
        let client = APIClient(tokens: tokens) { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = await responses.next()
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(body.utf8), response)
        }
        let mailbox = Mailbox(client: client)
        let body = MessageBody(id: "target", subject: "Known body", bodyHtml: nil, bodyText: "Body")

        let resolution = try await EmailReference.resolve(
            for: "target", unread: true, from: body, mailbox: mailbox, client: client)

        #expect(resolution == .metadataUnavailable(body: body))
    }

    @Test func fallbackSearchStopsAfterAFewInboxAndScreeningPages() async throws {
        let log = URLLog()
        let tokens = TokenProvider(current: { "t" }, renewed: { "t" }, invalidate: {})
        let client = APIClient(tokens: tokens) { request in
            guard let url = request.url else { throw URLError(.badURL) }
            await log.append(url)
            let count = await log.urls.count
            // Every page points at another one, as a large folder would.
            let body = #"{"emails":[],"nextCursor":"cursor-\#(count)"}"#
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(body.utf8), response)
        }
        let mailbox = Mailbox(client: client)
        let body = MessageBody(id: "target", subject: "Known body", bodyHtml: nil, bodyText: "Body")

        let resolution = try await EmailReference.resolve(
            for: "target", unread: true, from: body, mailbox: mailbox, client: client)

        #expect(resolution == .metadataUnavailable(body: body))
        let urls = await log.urls
        let folders = urls.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "folder" })?.value
        }
        #expect(Set(folders) == ["inbox", "screening"])
        #expect(urls.count == 6)
    }

    @Test func threadOnlyReferenceIsTreatedAsInboxMail() async throws {
        let tokens = TokenProvider(current: { "t" }, renewed: { "t" }, invalidate: {})
        let client = APIClient(tokens: tokens) { request in
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(#"{"emails":[],"nextCursor":null}"#.utf8), response)
        }
        let mailbox = Mailbox(client: client)
        let row = ThreadMessage(
            id: "target", fromName: "Jordan Blake", fromAddress: "jordan@example.com", snippet: "Hi",
            sentAt: Date(timeIntervalSince1970: 1_791_193_692))
        let body = MessageBody(id: "target", subject: "Final terms", bodyHtml: nil, bodyText: "Hi", thread: [row])

        let resolution = try await EmailReference.resolve(
            for: "target", unread: true, from: body, mailbox: mailbox, client: client)

        guard case .found(_, _, let isInboxMessage) = resolution else {
            Issue.record("expected a thread-only reference to resolve")
            return
        }
        #expect(isInboxMessage == true)
    }
}
