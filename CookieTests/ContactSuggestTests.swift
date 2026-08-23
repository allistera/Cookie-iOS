import XCTest
@testable import Cookie

final class ContactSuggestTests: XCTestCase {
    private let contacts = [
        Contact(address: "ada@example.com", name: "Ada Lovelace"),
        Contact(address: "sam@cookie.dev", name: nil),
        Contact(address: "team@newsletter.example", name: "Cookie Weekly"),
    ]

    // MARK: filterContacts

    func testEmptyQuerySuggestsNothing() {
        XCTAssertTrue(ContactSuggest.filterContacts(contacts, query: "").isEmpty)
        XCTAssertTrue(ContactSuggest.filterContacts(contacts, query: "   ").isEmpty)
    }

    func testMatchesNameAndAddressCaseInsensitively() {
        let byName = ContactSuggest.filterContacts(contacts, query: "lovelace")
        XCTAssertEqual(byName.map(\.address), ["ada@example.com"])

        let byAddress = ContactSuggest.filterContacts(contacts, query: "ADA@EXAMPLE")
        XCTAssertEqual(byAddress.map(\.address), ["ada@example.com"])
    }

    func testPrefixRanksAboveSubstring() {
        let ranked = [
            Contact(address: "ann@example.com", name: "Joanna"),
            Contact(address: "jo@example.com", name: "Ann"),
        ]
        let results = ContactSuggest.filterContacts(ranked, query: "ann")
        XCTAssertEqual(results.map(\.address), ["jo@example.com", "ann@example.com"])
    }

    func testFullyTypedAddressIsDropped() {
        XCTAssertTrue(
            ContactSuggest.filterContacts(contacts, query: "sam@cookie.dev").isEmpty
        )
    }

    func testLimitCapsResults() {
        let many = (0..<10).map { Contact(address: "user\($0)@example.com", name: nil) }
        XCTAssertEqual(ContactSuggest.filterContacts(many, query: "user").count, 6)
    }

    // MARK: Recipient field parsing

    func testCurrentRecipientTokenIsTextAfterLastComma() {
        XCTAssertEqual(ContactSuggest.currentRecipientToken("a@x.com"), "a@x.com")
        XCTAssertEqual(ContactSuggest.currentRecipientToken("a@x.com, b"), "b")
        XCTAssertEqual(ContactSuggest.currentRecipientToken("a@x.com,"), "")
    }

    func testCompletedRecipientsExcludesCurrentToken() {
        XCTAssertEqual(
            ContactSuggest.completedRecipients("a@x.com, b@x.com"),
            ["a@x.com"]
        )
        XCTAssertTrue(ContactSuggest.completedRecipients("a@x.com").isEmpty)
    }

    func testAppendRecipientReplacesTokenAndReadiesNext() {
        XCTAssertEqual(
            ContactSuggest.appendRecipient("a@x.com, b", "c@x.com"),
            "a@x.com, c@x.com, "
        )
        XCTAssertEqual(ContactSuggest.appendRecipient("", "c@x.com"), "c@x.com, ")
    }

    func testRecipientsValidRequiresAtSignOnEveryAddress() {
        XCTAssertTrue(ContactSuggest.recipientsValid("a@x.com"))
        XCTAssertTrue(ContactSuggest.recipientsValid("a@x.com, b@y.org"))
        XCTAssertFalse(ContactSuggest.recipientsValid(""))
        XCTAssertFalse(ContactSuggest.recipientsValid("   "))
        XCTAssertFalse(ContactSuggest.recipientsValid("not-an-address"))
        XCTAssertFalse(ContactSuggest.recipientsValid("a@x.com, nope"))
    }
}
