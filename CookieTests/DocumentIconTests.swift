import UIKit
import XCTest
@testable import Cookie

final class DocumentIconTests: XCTestCase {
    func testEmojiIsShownAsText() {
        XCTAssertEqual(DocumentIcon("💡"), .emoji("💡"))
        XCTAssertEqual(DocumentIcon(" 🔹 "), .emoji("🔹"))
    }

    func testMaterialSymbolMapsToSFSymbol() {
        XCTAssertEqual(DocumentIcon("ms:flight"), .systemImage("airplane"))
        XCTAssertEqual(DocumentIcon("ms:description"), .systemImage("doc.text"))
    }

    func testMissingUnknownOrMalformedIconsFallBackToADocumentSymbol() {
        let fallback = DocumentIcon.systemImage(DocumentIcon.fallbackSystemImage)
        XCTAssertEqual(DocumentIcon(nil), fallback)
        XCTAssertEqual(DocumentIcon(""), fallback)
        XCTAssertEqual(DocumentIcon("ms:not_a_real_icon"), fallback)
        XCTAssertEqual(DocumentIcon("ms:rocket_launch"), fallback)
        XCTAssertEqual(DocumentIcon("ms:"), fallback)
    }

    func testEveryMappedSFSymbolExists() {
        let names = [DocumentIcon.fallbackSystemImage] + Array(DocumentIcon.sfSymbols.values)
        let missing = Set(names).filter { UIImage(systemName: $0) == nil }
        XCTAssertEqual(missing, [])
    }
}
