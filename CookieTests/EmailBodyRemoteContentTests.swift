import XCTest
@testable import Cookie

final class EmailBodyRemoteContentTests: XCTestCase {
    func testBlockRuleCoversEveryRemoteSubresourceThatCanTrackAnOpen() throws {
        let json = Data(EmailBodyWebView.Coordinator.remoteBlockRuleJSON.utf8)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let trigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let types = Set(try XCTUnwrap(trigger["resource-type"] as? [String]))
        XCTAssertEqual(types, ["image", "style-sheet", "font", "media", "raw"])
        XCTAssertEqual(trigger["url-filter"] as? String, "^https?://")
    }

    func testShowImagesControlAppearsForRemoteStylesheetsAndMedia() {
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<link rel=\"stylesheet\" href=\"https://tracker.example.com/open.css\">"
            )
        )
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages("<style>@import 'https://tracker.example.com/a.css';</style>")
        )
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages("<video src=\"https://cdn.example.com/clip.mp4\"></video>")
        )
        XCTAssertFalse(
            EmailBodyWebView.hasBlockedRemoteImages("<p><a href=\"https://example.com\">example.com</a></p>")
        )
    }
}
