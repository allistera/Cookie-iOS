import UIKit
import XCTest
@testable import Cookie

final class RichTextTests: XCTestCase {
    private let range = NSRange(location: 0, length: 5)

    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        )
    }

    private func isBold(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        RichText.styles(in: text, range: range).contains(.bold)
    }

    private func isItalic(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        RichText.styles(in: text, range: range).contains(.italic)
    }

    private func isUnderlined(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        RichText.styles(in: text, range: range).contains(.underline)
    }

    // MARK: Bold / italic

    func testBoldToggleAppliesAndRemovesTrait() {
        let bolded = RichText.setStyle(.bold, active: true, in: plain("Hello"), range: range)
        XCTAssertTrue(isBold(bolded, range))

        let unbolded = RichText.setStyle(.bold, active: false, in: bolded, range: range)
        XCTAssertFalse(isBold(unbolded, range))
    }

    func testItalicToggleAppliesAndRemovesTrait() {
        let italic = RichText.setStyle(.italic, active: true, in: plain("Hello"), range: range)
        XCTAssertTrue(isItalic(italic, range))
        XCTAssertFalse(isBold(italic, range))

        let plainAgain = RichText.setStyle(.italic, active: false, in: italic, range: range)
        XCTAssertFalse(isItalic(plainAgain, range))
    }

    func testBoldPreservesPointSizeAndOtherTraits() {
        let italicBase = RichText.setStyle(.italic, active: true, in: plain("Hello"), range: range)
        let both = RichText.setStyle(.bold, active: true, in: italicBase, range: range)

        XCTAssertTrue(isBold(both, range))
        XCTAssertTrue(isItalic(both, range))
        XCTAssertEqual(
            (both.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize,
            16
        )
    }

    func testStyleOnlyAffectsSelectedRange() {
        let bolded = RichText.setStyle(.bold, active: true, in: plain("Hello world"), range: range)
        XCTAssertTrue(isBold(bolded, NSRange(location: 0, length: 5)))
        XCTAssertFalse(isBold(bolded, NSRange(location: 6, length: 5)))
    }

    // MARK: Underline

    func testUnderlineToggle() {
        let underlined = RichText.setStyle(.underline, active: true, in: plain("Hello"), range: range)
        XCTAssertTrue(isUnderlined(underlined, range))

        let cleared = RichText.setStyle(.underline, active: false, in: underlined, range: range)
        XCTAssertFalse(isUnderlined(cleared, range))
    }

    // MARK: Typing attributes (empty selection)

    func testUpdatingTypingAttributesFlipsBold() {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16)]
        let bold = RichText.updatingTypingAttributes(attrs, style: .bold, active: true)

        let font = bold[.font] as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)

        let unbold = RichText.updatingTypingAttributes(bold, style: .bold, active: false)
        let unboldFont = unbold[.font] as? UIFont
        XCTAssertFalse(unboldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? true)
    }

    // MARK: Bullet lists

    func testBulletToggleAddsAndRemovesMarker() {
        let listed = RichText.toggleBulletList(in: plain("Hello"), range: range).text
        XCTAssertEqual(listed.string, "• Hello")

        let unlisted = RichText.toggleBulletList(in: listed, range: range).text
        XCTAssertEqual(unlisted.string, "Hello")
    }

    func testBulletToggleShiftsSelectionToTrackMarker() {
        let (listed, selection) = RichText.toggleBulletList(in: plain("Hello"), range: range)
        XCTAssertEqual(listed.string, "• Hello")
        XCTAssertEqual(selection.location, 2)

        let (_, restored) = RichText.toggleBulletList(in: listed, range: selection)
        XCTAssertEqual(restored.location, 0)
    }

    func testBulletAppliesToEverySelectedParagraph() {
        let (listed, selection) = RichText.toggleBulletList(
            in: plain("One\nTwo\nThree"),
            range: NSRange(location: 0, length: 11)
        )
        XCTAssertEqual(listed.string, "• One\n• Two\n• Three")
        // Start moves past the leading marker; the two markers inserted
        // inside the selection widen it.
        XCTAssertEqual(selection.location, 2)
        XCTAssertEqual(selection.length, 15)
    }

    func testCollapsedCaretBulletsItsParagraph() {
        let text = plain("One\nTwo")
        // Caret inside "Two".
        let (listed, selection) = RichText.toggleBulletList(
            in: text,
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(listed.string, "One\n• Two")
        XCTAssertEqual(selection.location, 7)
    }

    func testMixedListSelectionUnbulletsEverything() {
        let listed = RichText.toggleBulletList(
            in: plain("One\nTwo"),
            range: NSRange(location: 0, length: 7)
        ).text
        XCTAssertEqual(listed.string, "• One\n• Two")

        // Selection strictly inside "Two"'s paragraph decides the direction…
        let second = RichText.toggleBulletList(
            in: listed,
            range: NSRange(location: 8, length: 3)
        ).text
        XCTAssertEqual(second.string, "• One\nTwo")
    }

    // MARK: HTML export

    func testBodyContentStripsDocumentBoilerplate() {
        let document = """
        <html><head><meta charset="utf-8"><style>body { font: 12px; }</style></head>\
        <body><p>Hello <b>world</b></p></body></html>
        """
        XCTAssertEqual(RichText.bodyContent(of: document), "<p>Hello <b>world</b></p>")
    }

    func testBodyContentFallsBackToWholeInput() {
        XCTAssertEqual(RichText.bodyContent(of: "<p>no wrapper</p>"), "<p>no wrapper</p>")
    }

    @MainActor
    func testHtmlExportContainsBodyTextWithoutBoilerplate() throws {
        let styled = RichText.setStyle(.bold, active: true, in: plain("Hello"), range: range)
        let html = try RichText.html(from: styled)

        XCTAssertTrue(html.contains("Hello"))
        XCTAssertFalse(html.contains("<head>"))
        XCTAssertFalse(html.contains("<style"))
    }

    // MARK: Style detection

    func testStylesDetectsAllFourStates() {
        var text = RichText.setStyle(.bold, active: true, in: plain("Hello"), range: range)
        text = RichText.setStyle(.italic, active: true, in: text, range: range)
        text = RichText.setStyle(.underline, active: true, in: text, range: range)
        text = RichText.toggleBulletList(in: text, range: range).text

        let styles = RichText.styles(
            in: text,
            range: NSRange(location: 0, length: text.length)
        )
        XCTAssertEqual(
            styles,
            [.bold, .italic, .underline, .bulletList]
        )
    }
}
