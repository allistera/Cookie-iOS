import XCTest
@testable import Cookie

final class MessageBodyTests: XCTestCase {
    func testDecodesSnakeCaseBodyFields() throws {
        let json = """
        {
          "id": "0b6d7c2e-0000-4000-8000-000000000001",
          "thread_id": "t-1",
          "body_html": "<p>Hello</p>",
          "body_text": "Hello",
          "summary": "Says hello",
          "unsubscribe": null,
          "thread": [],
          "attachments": []
        }
        """
        let body = try JSONDecoder().decode(MessageBody.self, from: Data(json.utf8))

        XCTAssertEqual(body.bodyHtml, "<p>Hello</p>")
        XCTAssertEqual(body.bodyText, "Hello")
    }

    func testDecodesNullBodies() throws {
        let json = """
        { "id": "x", "body_html": null, "body_text": "plain only" }
        """
        let body = try JSONDecoder().decode(MessageBody.self, from: Data(json.utf8))

        XCTAssertNil(body.bodyHtml)
        XCTAssertEqual(body.bodyText, "plain only")
    }

    func testWhitespaceOnlyHtmlFallsBackToPlainText() throws {
        let json = #"{ "body_html": "  \n", "body_text": "Plain-text message" }"#
        let body = try JSONDecoder().decode(MessageBody.self, from: Data(json.utf8))

        XCTAssertNil(body.renderableHtml)
        XCTAssertEqual(body.renderableText, "Plain-text message")
    }

    func testRemoteImageDetectionFlagsImgSrc() {
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<p>hi</p><img src=\"https://tracker.example.com/pixel.gif\" width=\"1\">"
            )
        )
    }

    func testRemoteImageDetectionFlagsCssBackgroundUrl() {
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<div style=\"background-image: url('https://cdn.example.com/bg.png')\">hi</div>"
            )
        )
    }

    func testRemoteImageDetectionFlagsBackgroundAttribute() {
        XCTAssertTrue(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<table background=\"https://cdn.example.com/bg.png\"><tr><td>hi</td></tr></table>"
            )
        )
    }

    func testRemoteImageDetectionIgnoresDataUrisAndPlainLinks() {
        XCTAssertFalse(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<img src=\"data:image/png;base64,iVBORw0KGgo=\">"
            )
        )
        XCTAssertFalse(
            EmailBodyWebView.hasBlockedRemoteImages(
                "<p>Read more at <a href=\"https://example.com\">example.com</a></p>"
            )
        )
        XCTAssertFalse(EmailBodyWebView.hasBlockedRemoteImages(""))
    }
}
