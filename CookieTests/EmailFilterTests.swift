import Foundation
import XCTest
@testable import Cookie

final class EmailFilterTests: XCTestCase {
    func testBuiltInAndCustomCategoriesKeepTheirServerNames() {
        for name in ["Personal", "Shopping", "My custom category"] {
            let category = EmailCategory(id: UUID().uuidString, name: name, color: nil)
            XCTAssertEqual(EmailFilter(category: category).rawValue, name)
        }
    }

    func testMissingCategoryIsNotPersonal() {
        XCTAssertEqual(EmailFilter(category: nil), .uncategorised)
        XCTAssertNotEqual(EmailFilter(category: nil), .personal)
    }

    func testDecodesCategoryAndMapsLiveMessages() throws {
        for name in ["Shopping", "Work", "Custom"] {
            let data = Data("""
                {"id":"11111111-1111-4111-8111-111111111111", "from_address":"test@example.com",
                 "is_unread":true, "is_starred":false, "is_sent":false, "has_html":false,
                 "has_ai_summary":false, "has_attachments":false, "labels":[],
                 "sent_at":"2026-09-13T12:00:00Z", "category":{"id":"category", "name":"\(name)"}}
                """.utf8)
            let message = try JSONDecoder().decode(EmailMessage.self, from: data)
            let email = try XCTUnwrap(DummyEmail(message: message))
            XCTAssertEqual(email.filter.rawValue, name)
        }
    }
}
