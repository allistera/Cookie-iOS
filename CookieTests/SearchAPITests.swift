import XCTest
@testable import Cookie

final class SearchAPITests: XCTestCase {
    /// A `GET /search` row is the `GET /emails` shape plus a few
    /// search-only columns (`recipients`, `scheduled_for`, `spam_score`),
    /// which decoding must tolerate — the endpoint promises "response shape
    /// matches GET /emails" and the app reuses `EmailListResponse`.
    func testSearchRowsDecodeIntoEmailMessages() throws {
        let json = Data("""
        {
          "emails": [
            {
              "id": "0b6d7c2e-0000-4000-8000-000000000001",
              "from_name": "Ada Lovelace",
              "from_address": "ada@example.com",
              "recipients": {"to": [{"name": null, "address": "me@example.com"}]},
              "subject": "Engine notes",
              "snippet": "Sketches for the analytical engine…",
              "sent_at": "2026-08-23T14:03:00.000Z",
              "is_unread": true,
              "is_starred": false,
              "is_sent": false,
              "scheduled_for": null,
              "spam_score": null,
              "has_ai_summary": false,
              "has_html": true,
              "has_attachments": false,
              "labels": [{"name": "Work", "color": "#ff0000", "kind": null}]
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(EmailListResponse.self, from: json)

        XCTAssertEqual(response.emails.count, 1)
        let email = try XCTUnwrap(response.emails.first)
        XCTAssertEqual(email.id, "0b6d7c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(email.fromName, "Ada Lovelace")
        XCTAssertEqual(email.subject, "Engine notes")
        XCTAssertTrue(email.isUnread)
        XCTAssertEqual(email.labels.map(\.name), ["Work"])
        XCTAssertNil(response.nextCursor)
        XCTAssertNil(response.unreadCount)
    }
}
