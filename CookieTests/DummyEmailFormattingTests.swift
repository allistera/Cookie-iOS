import XCTest
@testable import Cookie

final class DummyEmailFormattingTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ iso8601: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(iso8601)
    }

    func testTodaysMailShowsTimeOfDay() throws {
        let now = try date("2026-10-02T18:00:00Z")
        let sent = try date("2026-10-02T15:03:00Z")

        let text = DummyEmail.listTimestamp(for: sent, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(text.contains("3:03"), text)
        XCTAssertFalse(text.contains("Oct"), text)
    }

    func testEarlierMailThisYearShowsDayAndMonth() throws {
        let now = try date("2026-10-02T18:00:00Z")
        let sent = try date("2026-09-12T15:03:00Z")

        let text = DummyEmail.listTimestamp(for: sent, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(text.contains("Sep"), text)
        XCTAssertTrue(text.contains("12"), text)
        XCTAssertFalse(text.contains("2026"), text)
        XCTAssertFalse(text.contains("3:03"), text)
    }

    func testMailFromAnotherYearIncludesTheYear() throws {
        let now = try date("2026-10-02T18:00:00Z")
        let sent = try date("2025-12-30T15:03:00Z")

        let text = DummyEmail.listTimestamp(for: sent, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(text.contains("Dec"), text)
        XCTAssertTrue(text.contains("2025"), text)
    }

    func testReplyQuoteUsesTheFullDateAndTime() throws {
        let message = EmailMessage(id: UUID().uuidString, fromName: "Ada", fromAddress: "ada@example.com",
                                   subject: "Mail", snippet: "Hello", sentAt: "2025-03-04T12:00:00Z",
                                   isUnread: true, isStarred: false, isSent: false, hasHtml: false,
                                   hasAiSummary: false, hasAttachments: false, labels: [])
        let email = try XCTUnwrap(DummyEmail(message: message))
        let sentAt = try XCTUnwrap(email.sentAt)

        let quote = DummyEmail.quotedReplyBody(for: email)

        XCTAssertTrue(quote.contains("On \(sentAt.formatted(date: .abbreviated, time: .shortened)), Ada wrote:"), quote)
        XCTAssertTrue(quote.contains("2025"), quote)
    }

    /// `String.hashValue` is reseeded every launch; the avatar colour must
    /// not be. These indices are FNV-1a of the UTF-8 bytes, mod 5.
    func testAvatarColourIsStableAcrossLaunches() {
        XCTAssertEqual(DummyEmail.avatarPaletteIndex(for: "GitHub"), 4)
        XCTAssertEqual(DummyEmail.avatarPaletteIndex(for: "Ada Lovelace"), 1)
        XCTAssertEqual(DummyEmail.avatarPaletteIndex(for: ""), 0)
    }
}
