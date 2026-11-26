import Foundation
import Testing

@testable import Cookie

struct EmailSummaryTests {
    private let recordedPage = """
        {"emails":[{"id":"6f1c","from_name":"Jordan Blake","from_address":"jordan@example.com",
        "subject":"Final terms","snippet":"We've outlined the final terms.","sent_at":"2026-10-05T09:48:12.345Z",
        "is_unread":true,"priority":"high","labels":[{"name":"Funding","color":"#327056","kind":"user"}],
        "category":{"id":"9a2b","name":"Finance","color":"#B3792A"},"has_ai_summary":true,"has_html":true},
        {"id":"7a2d","from_name":null,"from_address":"noreply@example.com","subject":null,"snippet":null,
        "sent_at":"2026-10-04T18:02:11Z","is_unread":false,"priority":null,"labels":[],"category":null}],
        "nextCursor":"2026-10-04T18:02:11.120000Z|7a2d","unreadCount":3,"spamCount":0}
        """

    @Test func decodesRecordedPage() throws {
        let page = try JSONDecoder.cookieAPI().decode(InboxPage.self, from: Data(recordedPage.utf8))

        #expect(page.nextCursor == "2026-10-04T18:02:11.120000Z|7a2d")
        #expect(page.unreadCount == 3)
        #expect(page.emails.count == 2)

        let first = try #require(page.emails.first)
        #expect(first.id == "6f1c")
        #expect(first.senderName == "Jordan Blake")
        #expect(first.sentAt == Date(timeIntervalSince1970: 1_791_193_692.345))
        #expect(first.isUnread)
        #expect(first.isImportant)
        #expect(first.labels == [EmailLabel(name: "Funding", color: "#327056")])
        #expect(first.category == EmailCategory(id: "9a2b", name: "Finance", color: "#B3792A"))

        let second = try #require(page.emails.last)
        #expect(second.senderName == "noreply@example.com")
        #expect(second.subject == nil)
        #expect(second.sentAt == Date(timeIntervalSince1970: 1_791_136_931))
        #expect(!second.isImportant)
        #expect(second.category == nil)
    }

    @Test func categoryNamedImportantIsImportant() throws {
        let json = """
            {"id":"1","from_address":"a@example.com","sent_at":"2026-10-05T09:48:12Z","is_unread":false,
            "labels":[],"category":{"id":"c","name":" Important ","color":null}}
            """
        let email = try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(json.utf8))
        #expect(email.isImportant)
    }

    @Test func decodesCategoryList() throws {
        let json = """
            {"categories":[{"id":"c1","name":"Finance","color":"#B3792A","description":null,
            "notifications_enabled":true,"message_count":4}]}
            """
        let list = try JSONDecoder.cookieAPI().decode(CategoryList.self, from: Data(json.utf8))
        #expect(list.categories == [EmailCategory(id: "c1", name: "Finance", color: "#B3792A")])
    }

    @Test func rejectsUnparseableDate() {
        let json = """
            {"id":"1","from_address":"a@example.com","sent_at":"yesterday","is_unread":false,"labels":[]}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(json.utf8))
        }
    }

    @Test func sentRowShowsRecipient() throws {
        let json = """
            {"id":"1","from_address":"me@example.com","from_name":"Me","sent_at":"2026-10-05T09:48:12Z",
            "is_unread":false,"labels":[],"is_sent":true,
            "recipients":{"to":[{"name":"Jordan Blake","address":"jordan@example.com"}],"cc":[]}}
            """
        let email = try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(json.utf8))
        #expect(email.isSent)
        #expect(email.displayName == "To: Jordan Blake")
    }

    @Test func sentRowWithoutNameUsesAddressAndMissingFieldsDefault() throws {
        let sent = """
            {"id":"1","from_address":"me@example.com","sent_at":"2026-10-05T09:48:12Z","is_unread":false,
            "labels":[],"is_sent":true,"recipients":{"to":[{"name":null,"address":"jordan@example.com"}]}}
            """
        let email = try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(sent.utf8))
        #expect(email.displayName == "To: jordan@example.com")

        let received = """
            {"id":"2","from_address":"a@example.com","sent_at":"2026-10-05T09:48:12Z","is_unread":false,"labels":[],
            "recipients":null}
            """
        let other = try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(received.utf8))
        #expect(!other.isSent)
        #expect(other.displayName == "a@example.com")
    }

    @Test func plainStringRecipientIsTheAddress() throws {
        let json = """
            {"id":"1","from_address":"me@example.com","sent_at":"2026-10-05T09:48:12Z","is_unread":false,
            "labels":[],"is_sent":true,"recipients":{"to":["jordan@example.com"]}}
            """
        let email = try JSONDecoder.cookieAPI().decode(EmailSummary.self, from: Data(json.utf8))
        #expect(email.recipients?.primary == [Recipient(name: nil, address: "jordan@example.com")])
        #expect(email.displayName == "To: jordan@example.com")
    }

    @Test func malformedRecipientsDoNotFailThePage() throws {
        let json = """
            {"emails":[{"id":"1","from_address":"me@example.com","sent_at":"2026-10-05T09:48:12Z",
            "is_unread":false,"labels":[],"is_sent":true,"recipients":{"to":[42]}},
            {"id":"2","from_address":"a@example.com","sent_at":"2026-10-04T09:48:12Z","is_unread":true,
            "labels":[],"recipients":"jordan@example.com"}],"nextCursor":null}
            """
        let page = try JSONDecoder.cookieAPI().decode(InboxPage.self, from: Data(json.utf8))
        #expect(page.emails.map(\.id) == ["1", "2"])
        #expect(page.emails.allSatisfy { $0.recipients == nil })
        #expect(page.emails.first?.displayName == "me@example.com")
    }
}
