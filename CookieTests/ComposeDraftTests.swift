import XCTest
@testable import Cookie

final class ComposeDraftTests: XCTestCase {
    func testDraftRequiresARecipientBeforeSending() {
        XCTAssertFalse(ComposeDraft().canSend)
        XCTAssertFalse(ComposeDraft(recipient: "   ").canSend)
        XCTAssertTrue(ComposeDraft(recipient: "person@example.com").canSend)
    }
}
