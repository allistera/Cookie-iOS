import XCTest
@testable import Cookie

final class CalendarEventsAPITests: XCTestCase {
    private let draftJSON = Data("""
    {
      "draft": {
        "title": "Dinner with Sam",
        "description": null,
        "location": null,
        "date": "2026-08-24",
        "start": "19:00",
        "duration": 120,
        "repeat": "none",
        "repeatUntil": null,
        "repeatDays": null
      },
      "model": "gpt-5.6-luna"
    }
    """.utf8)

    private func decodedDraft() throws -> CalendarEventsAPI.EventDraft {
        struct Envelope: Decodable { let draft: CalendarEventsAPI.EventDraft }
        return try JSONDecoder().decode(Envelope.self, from: draftJSON).draft
    }

    func testDraftDecodesFromInterpretResponse() throws {
        let draft = try decodedDraft()

        XCTAssertEqual(draft.title, "Dinner with Sam")
        XCTAssertNil(draft.description)
        XCTAssertEqual(draft.date, "2026-08-24")
        XCTAssertEqual(draft.start, "19:00")
        XCTAssertEqual(draft.duration, 120)
        XCTAssertEqual(draft.repeat, "none")
        XCTAssertNil(draft.repeatDays)
    }

    /// The create body must be the flat `{ ...draft, calendar, tone }` object
    /// the web client sends — draft fields and the two extras merged into one
    /// level, never a nested `draft` key.
    func testCreateBodySpreadsDraftFieldsFlat() throws {
        let body = CalendarEventsAPI.CreateEventBody(
            draft: try decodedDraft(),
            calendar: "0b6d7c2e-0000-4000-8000-000000000001",
            tone: "accepted"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )

        XCTAssertNil(json["draft"])
        XCTAssertEqual(json["title"] as? String, "Dinner with Sam")
        XCTAssertEqual(json["date"] as? String, "2026-08-24")
        XCTAssertEqual(json["start"] as? String, "19:00")
        XCTAssertEqual(json["duration"] as? Int, 120)
        XCTAssertEqual(json["repeat"] as? String, "none")
        XCTAssertEqual(json["calendar"] as? String, "0b6d7c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(json["tone"] as? String, "accepted")
    }
}
