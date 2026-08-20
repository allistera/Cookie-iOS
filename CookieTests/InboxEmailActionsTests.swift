import XCTest
@testable import Cookie

final class InboxEmailActionsTests: XCTestCase {
    func testMarkingDoneRemovesOnlyTheSelectedEmail() {
        let emails = DummyEmail.sample
        let selectedEmail = emails[2]

        let result = InboxEmailActions.markingDone(emailID: selectedEmail.id, in: emails)

        XCTAssertEqual(result.count, emails.count - 1)
        XCTAssertFalse(result.contains { $0.id == selectedEmail.id })
        XCTAssertEqual(
            result.map(\.id),
            emails.filter { $0.id != selectedEmail.id }.map(\.id)
        )
    }
}
