import XCTest
@testable import Cookie

final class ComposeDraftTests: XCTestCase {
    func testDraftRequiresARecipientBeforeSending() {
        XCTAssertFalse(ComposeDraft().canSend)
        XCTAssertFalse(ComposeDraft(recipient: "   ").canSend)
        XCTAssertTrue(ComposeDraft(recipient: "person@example.com").canSend)
    }

    func testDraftValidatesEveryCommaSeparatedRecipient() {
        XCTAssertTrue(ComposeDraft(recipient: "a@example.com, b@example.org").canSend)
        XCTAssertFalse(ComposeDraft(recipient: "not-an-address").canSend)
        XCTAssertFalse(ComposeDraft(recipient: "a@example.com, nope").canSend)
    }
}
