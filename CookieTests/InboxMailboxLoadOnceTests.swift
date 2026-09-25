import XCTest
@testable import Cookie

@MainActor
final class InboxMailboxLoadOnceTests: XCTestCase {
    private func page(_ ids: [String], next: String? = nil) -> EmailListResponse {
        let emails = ids.map { id in
            EmailMessage(id: id, fromName: nil, fromAddress: "sender@example.com",
                         subject: "Mail", snippet: nil, sentAt: "2026-09-01T12:00:00Z",
                         isUnread: true, isStarred: false, isSent: false, hasHtml: false,
                         hasAiSummary: false, hasAttachments: false, labels: [])
        }
        return EmailListResponse(emails: emails, nextCursor: next, unreadCount: 1,
                                 userId: nil, readReceiptsAvailable: nil)
    }

    func testLoadIfNeededKeepsPaginatedListOnLaterAppearances() async {
        let mailbox = InboxMailbox()
        await mailbox.loadIfNeeded { _ in self.page([UUID().uuidString], next: "page-2") }
        await mailbox.load(refresh: false) { _ in self.page([UUID().uuidString]) }
        XCTAssertEqual(mailbox.emails.count, 2)

        var fetched = false
        await mailbox.loadIfNeeded { _ in
            fetched = true
            return self.page([UUID().uuidString])
        }
        XCTAssertFalse(fetched)
        XCTAssertEqual(mailbox.emails.count, 2)
    }

    func testCancelledLoadIsNotReportedAsAFailureAndRetriesOnNextAppearance() async {
        let mailbox = InboxMailbox()
        await mailbox.loadIfNeeded { _ in throw CancellationError() }
        XCTAssertNil(mailbox.errorMessage)
        XCTAssertFalse(mailbox.hasLoaded)

        await mailbox.loadIfNeeded { _ in throw URLError(.cancelled) }
        XCTAssertNil(mailbox.errorMessage)
        XCTAssertFalse(mailbox.hasLoaded)

        await mailbox.loadIfNeeded { _ in self.page([UUID().uuidString]) }
        XCTAssertEqual(mailbox.emails.count, 1)
        XCTAssertTrue(mailbox.hasLoaded)
    }

    func testRealFailureStillSurfacesAnError() async {
        let mailbox = InboxMailbox()
        await mailbox.loadIfNeeded { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertNotNil(mailbox.errorMessage)
        XCTAssertTrue(mailbox.hasLoaded)
    }
}
