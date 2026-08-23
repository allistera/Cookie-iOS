import XCTest
@testable import Cookie

final class MessagesAPITests: XCTestCase {
    private func encodedDoneBody(id: String) throws -> [String: Any] {
        let data = try JSONEncoder().encode(MessagesAPI.PatchMessageBody.done(id: id))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testDonePatchArchivesAndClearsUnread() throws {
        let json = try encodedDoneBody(id: "0b6d7c2e-0000-4000-8000-000000000001")

        XCTAssertEqual(json["id"] as? String, "0b6d7c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(json["is_archived"] as? Bool, true)
        XCTAssertEqual(json["is_unread"] as? Bool, false)
    }

    /// Absent keys are no-ops server-side (`COALESCE`), so Done must not
    /// send star/delete flags and silently unstar or undelete a message.
    func testDonePatchOmitsUntouchedFlags() throws {
        let json = try encodedDoneBody(id: "abc")

        XCTAssertNil(json["is_starred"])
        XCTAssertNil(json["is_deleted"])
    }
}
