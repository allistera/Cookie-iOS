import XCTest
@testable import Cookie

final class InboxDeepLinkTests: XCTestCase {
    private let messageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testParsesTheEmailLinkNtfyNotificationsCarry() throws {
        let url = try XCTUnwrap(URL(string: "com.cookie.ios://inbox?open=11111111-1111-1111-1111-111111111111"))

        XCTAssertEqual(InboxDeepLink.parse(url), .email(id: messageID))
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "COM.COOKIE.IOS://Inbox?open=11111111-1111-1111-1111-111111111111"))

        XCTAssertEqual(InboxDeepLink.parse(url), .email(id: messageID))
    }

    func testIgnoresLinksForOtherAppsAndOtherHosts() throws {
        XCTAssertNil(InboxDeepLink.parse(try XCTUnwrap(URL(string: "https://mail.infinitywave.online/inbox?open=11111111-1111-1111-1111-111111111111"))))
        XCTAssertNil(InboxDeepLink.parse(try XCTUnwrap(URL(string: "com.cookie.ios://notes?open=11111111-1111-1111-1111-111111111111"))))
    }

    func testIgnoresTheAuth0CallbackOnTheSameScheme() throws {
        let callback = try XCTUnwrap(URL(string: "com.cookie.ios://dev-tenant.us.auth0.com/ios/com.cookie.ios/callback?code=abc"))

        XCTAssertNil(InboxDeepLink.parse(callback))
    }

    func testIgnoresMissingOrMalformedMessageIDs() throws {
        XCTAssertNil(InboxDeepLink.parse(try XCTUnwrap(URL(string: "com.cookie.ios://inbox"))))
        XCTAssertNil(InboxDeepLink.parse(try XCTUnwrap(URL(string: "com.cookie.ios://inbox?open="))))
        XCTAssertNil(InboxDeepLink.parse(try XCTUnwrap(URL(string: "com.cookie.ios://inbox?open=test-notification"))))
    }
}
