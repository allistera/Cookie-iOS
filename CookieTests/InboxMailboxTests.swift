import XCTest
@testable import Cookie

@MainActor
final class InboxMailboxTests: XCTestCase {
    private func page(_ ids: [String], next: String? = nil) -> EmailListResponse {
        let emails = ids.map { id in
            EmailMessage(id: id, fromName: nil, fromAddress: "sender@example.com",
                         subject: "Mail", snippet: nil, sentAt: "2026-09-01T12:00:00Z",
                         isUnread: true, isStarred: false, isSent: false, hasHtml: false,
                         hasAiSummary: false, hasAttachments: false, labels: [])
        }
        return EmailListResponse(emails: emails, nextCursor: next, unreadCount: 60,
                                 userId: nil, readReceiptsAvailable: nil)
    }

    func testLoadsBeyondFiftyMessagesAndDeduplicatesOverlappingPages() async {
        let mailbox = InboxMailbox()
        let ids = (0..<60).map { _ in UUID().uuidString }
        await mailbox.load(refresh: true) { cursor in
            XCTAssertNil(cursor)
            return self.page(Array(ids.prefix(50)), next: "page-2")
        }
        await mailbox.load(refresh: false) { cursor in
            XCTAssertEqual(cursor, "page-2")
            return self.page(Array(ids.suffix(11)))
        }
        XCTAssertEqual(mailbox.emails.count, 60)
        XCTAssertNil(mailbox.nextCursor)
        XCTAssertEqual(mailbox.unreadCount, 60)
    }

    func testFailedPageKeepsItsCursorAndCanBeRetried() async {
        let mailbox = InboxMailbox()
        await mailbox.load(refresh: true) { _ in self.page([UUID().uuidString], next: "next") }
        await mailbox.load(refresh: false) { _ in throw URLError(.timedOut) }
        XCTAssertEqual(mailbox.nextCursor, "next")
        XCTAssertNotNil(mailbox.errorMessage)
        XCTAssertFalse(mailbox.isLoading)
        await mailbox.load(refresh: false) { _ in self.page([UUID().uuidString]) }
        XCTAssertEqual(mailbox.emails.count, 2)
        XCTAssertNil(mailbox.errorMessage)
    }

    func testRefreshSupersedesAnOlderPageResponse() async {
        let mailbox = InboxMailbox()
        await mailbox.load(refresh: true) { _ in self.page([UUID().uuidString], next: "next") }
        var gate: CheckedContinuation<Void, Never>?
        let oldPage = Task {
            await mailbox.load(refresh: false) { _ in
                await withCheckedContinuation { gate = $0 }
                return self.page([UUID().uuidString], next: "stale")
            }
        }
        while gate == nil { await Task.yield() }
        let newest = UUID()
        await mailbox.load(refresh: true) { _ in self.page([newest.uuidString]) }
        gate?.resume()
        await oldPage.value
        XCTAssertEqual(mailbox.emails.map(\.id), [newest])
        XCTAssertNil(mailbox.nextCursor)
    }
}
