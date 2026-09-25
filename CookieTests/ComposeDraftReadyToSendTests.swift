import XCTest
@testable import Cookie

final class ComposeDraftReadyToSendTests: XCTestCase {
    func testSendNeedsBothAValidRecipientAndABody() {
        XCTAssertFalse(ComposeDraft(recipient: "person@example.com").isReadyToSend)
        XCTAssertFalse(
            ComposeDraft(recipient: "person@example.com", body: NSAttributedString(string: " \n ")).isReadyToSend
        )
        XCTAssertFalse(ComposeDraft(recipient: "nope", body: NSAttributedString(string: "Hi")).isReadyToSend)
        XCTAssertTrue(
            ComposeDraft(recipient: "person@example.com", body: NSAttributedString(string: "Hi")).isReadyToSend
        )
    }
}
