import XCTest
@testable import Cookie

final class CookieAPIEndpointsTests: XCTestCase {
    func testProductionRoutesMatchCurrentWorkerContracts() {
        XCTAssertEqual(
            CookieAPIEndpoints.emails.absoluteString,
            "https://emails-api.infinitywave.online/emails"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.messages.absoluteString,
            "https://messages-api.infinitywave.online/messages"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.contacts.absoluteString,
            "https://messages-api.infinitywave.online/messages/contacts"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.search.absoluteString,
            "https://search-api.infinitywave.online/search"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.send.absoluteString,
            "https://send-api.infinitywave.online/send"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.calendarEvents.absoluteString,
            "https://calendar-api.infinitywave.online/calendar-events"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.calendars.absoluteString,
            "https://calendar-api.infinitywave.online/calendars"
        )
        XCTAssertEqual(
            CookieAPIEndpoints.documents.absoluteString,
            "https://tasks-api.infinitywave.online/documents"
        )
    }
}
