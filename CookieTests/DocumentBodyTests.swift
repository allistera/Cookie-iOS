import XCTest
@testable import Cookie

final class DocumentBodyTests: XCTestCase {
    private func blocks(_ json: String) throws -> [DocumentBlock] {
        try JSONDecoder().decode([DocumentBlock].self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    private func encoded(_ blocks: [DocumentBlock]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try XCTUnwrap(String(data: try encoder.encode(blocks), encoding: .utf8))
    }

    /// JSON objects are unordered, and a decode/encode round trip shuffles
    /// their keys — so the expected side is re-rendered key-sorted too, by
    /// JSONSerialization rather than by the code under test. Values (types,
    /// precision, nulls) still have to match exactly.
    private func canonical(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8)))
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func texts(_ rows: [DocumentBodyRow]) -> [String] {
        rows.map { row in
            switch row {
            case .editable(let field): field.text
            case .unsupported(_, let type): "<\(type)>"
            }
        }
    }

    // MARK: - Reading

    func testReadsTextBlocksAndStripsInlineMarkup() throws {
        let rows = DocumentBody.rows(in: try blocks("""
        [{"type": "header", "data": {"text": "Plans", "level": 2}},
         {"type": "paragraph", "data": {"text": "Call <b>Sam</b>&nbsp;today"}},
         {"type": "code", "data": {"code": "let x = 1"}}]
        """))

        XCTAssertEqual(texts(rows), ["Plans", "Call Sam today", "let x = 1"])
    }

    func testReadsNestedListItemsWithTheirMarkers() throws {
        let rows = DocumentBody.rows(in: try blocks("""
        [{"type": "list", "data": {"style": "ordered", "items": [
            {"content": "Buy paint", "items": [{"content": "Matte", "items": []}]},
            {"content": "Book crew", "items": []}]}}]
        """))

        XCTAssertEqual(texts(rows), ["Buy paint", "Matte", "Book crew"])
        guard case .editable(let nested) = rows[1], case .listItem(let depth, let marker) = nested.style else {
            return XCTFail("expected a nested list item")
        }
        XCTAssertEqual(depth, 1)
        XCTAssertEqual(marker, "1.")
        XCTAssertEqual(nested.path.itemPath, [0, 0])
    }

    /// Documents written before `@editorjs/list` v2 store items as bare
    /// strings rather than objects.
    func testReadsLegacyStringListItems() throws {
        let rows = DocumentBody.rows(in: try blocks(
            #"[{"type": "list", "data": {"style": "unordered", "items": ["Bay window", "Framing"]}}]"#
        ))

        XCTAssertEqual(texts(rows), ["Bay window", "Framing"])
    }

    func testBlockTypesThisEditorCannotEditAreListedNotDropped() throws {
        let rows = DocumentBody.rows(in: try blocks("""
        [{"type": "paragraph", "data": {"text": "Before"}},
         {"type": "table", "data": {"workbook": {"sheets": {}}}},
         {"type": "paragraph", "data": {"text": "After"}}]
        """))

        XCTAssertEqual(texts(rows), ["Before", "<table>", "After"])
    }

    /// Typing rebuilds only the edited block's lines; the result must match a
    /// full rebuild, including a block whose line count differs.
    func testReplacingOneBlocksRowsMatchesAFullRebuild() throws {
        let original = try blocks("""
        [{"type": "paragraph", "data": {"text": "Intro"}},
         {"type": "list", "data": {"style": "ordered", "items": [
            {"content": "One", "items": [{"content": "Nested", "items": []}]},
            {"content": "Two", "items": []}]}},
         {"type": "table", "data": {}},
         {"type": "paragraph", "data": {"text": "Outro"}}]
        """)
        let before = DocumentBody.rows(in: original)
        let updated = DocumentBody.setting(
            "Nested edit",
            at: .init(blockIndex: 1, itemPath: [0, 0]),
            in: original
        )

        let patched = DocumentBody.rows(before, replacingBlockAt: 1, in: updated)

        XCTAssertEqual(patched, DocumentBody.rows(in: updated))
        XCTAssertEqual(texts(patched), ["Intro", "One", "Nested edit", "Two", "<table>", "Outro"])
    }

    func testReplacingTheLastBlocksRowsMatchesAFullRebuild() throws {
        let original = try blocks("""
        [{"type": "paragraph", "data": {"text": "First"}},
         {"type": "paragraph", "data": {"text": "Last"}}]
        """)
        let updated = DocumentBody.setting("Last edit", at: .init(blockIndex: 1), in: original)

        let patched = DocumentBody.rows(DocumentBody.rows(in: original), replacingBlockAt: 1, in: updated)

        XCTAssertEqual(patched, DocumentBody.rows(in: updated))
    }

    // MARK: - Writing

    func testEditingOneBlockLeavesTheOthersByteForByteIntact() throws {
        let original = try blocks("""
        [{"type": "paragraph", "data": {"text": "Keep <b>this</b> bold"}},
         {"type": "paragraph", "data": {"text": "Change me"}}]
        """)

        let updated = DocumentBody.setting(
            "Changed",
            at: .init(blockIndex: 1),
            in: original
        )

        XCTAssertEqual(updated[0], original[0])
        XCTAssertEqual(updated[1].data?["text"]?.stringValue, "Changed")
    }

    /// Every keystroke re-runs this; a no-op edit must not rewrite the block
    /// and strip its formatting down to the plain text shown on screen.
    func testWritingBackUnchangedTextIsANoOp() throws {
        let original = try blocks(#"[{"type": "paragraph", "data": {"text": "Call <b>Sam</b>"}}]"#)

        let updated = DocumentBody.setting("Call Sam", at: .init(blockIndex: 0), in: original)

        XCTAssertEqual(updated, original)
    }

    func testEditedTextIsEscapedAndNewlinesBecomeBreaks() throws {
        let original = try blocks(#"[{"type": "paragraph", "data": {"text": ""}}]"#)

        let updated = DocumentBody.setting("a < b & c\nnext", at: .init(blockIndex: 0), in: original)

        XCTAssertEqual(updated[0].data?["text"]?.stringValue, "a &lt; b &amp; c<br>next")
    }

    func testEditingANestedListItemKeepsItsSiblingsAndMetadata() throws {
        let original = try blocks("""
        [{"type": "list", "data": {"style": "checklist", "items": [
            {"content": "Outer", "meta": {"checked": true},
             "items": [{"content": "Inner", "meta": {"checked": false}, "items": []}]},
            {"content": "Second", "meta": {"checked": false}, "items": []}]}}]
        """)

        let updated = DocumentBody.setting(
            "Inner edited",
            at: .init(blockIndex: 0, itemPath: [0, 0]),
            in: original
        )

        let items = try XCTUnwrap(updated[0].data?["items"])
        XCTAssertEqual(items[0]?["items"]?[0]?["content"]?.stringValue, "Inner edited")
        XCTAssertEqual(items[0]?["items"]?[0]?["meta"]?["checked"]?.boolValue, false)
        XCTAssertEqual(items[0]?["content"]?.stringValue, "Outer")
        XCTAssertEqual(items[0]?["meta"]?["checked"]?.boolValue, true)
        XCTAssertEqual(items[1]?["content"]?.stringValue, "Second")
    }

    func testALegacyStringListItemStaysAString() throws {
        let original = try blocks(
            #"[{"type": "list", "data": {"style": "unordered", "items": ["One", "Two"]}}]"#
        )

        let updated = DocumentBody.setting(
            "One edited",
            at: .init(blockIndex: 0, itemPath: [0]),
            in: original
        )

        XCTAssertEqual(updated[0].data?["items"]?[0]?.stringValue, "One edited")
        XCTAssertEqual(updated[0].data?["items"]?[1]?.stringValue, "Two")
    }

    func testAppendedParagraphIsAnEmptyEditableBlock() throws {
        let updated = DocumentBody.appendingParagraph(to: try blocks("[]"))

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].type, "paragraph")
        XCTAssertEqual(updated[0].data?["text"]?.stringValue, "")
        XCTAssertEqual(updated[0].value["id"]?.stringValue?.count, 10)
    }

    func testRemovingAnOutOfRangeBlockLeavesTheDocumentAlone() throws {
        let original = try blocks(#"[{"type": "paragraph", "data": {"text": "Only"}}]"#)

        XCTAssertEqual(DocumentBody.removingBlock(at: 4, from: original), original)
        XCTAssertEqual(DocumentBody.removingBlock(at: 0, from: original), [])
    }

    // MARK: - Round-tripping unknown JSON

    /// A save PATCHes the whole block array back. Anything this app doesn't
    /// model — table workbooks, kanban lanes, image metadata — has to survive
    /// decode/encode untouched or editing a note on the phone would destroy it.
    func testUnknownBlockContentSurvivesADecodeEncodeRoundTrip() throws {
        let json = """
        [{"id":"abc","type":"kanban","data":{"lanes":[{"title":"Doing","tasks":[{"id":1,\
        "title":"Ship","done":false,"weight":1.5,"labels":["a","b"],"assignee":null}]}]}}]
        """

        XCTAssertEqual(try encoded(try blocks(json)), try canonical(json))
    }

    func testWholeNumbersDoNotBecomeFloatsOnSave() throws {
        let encoded = try encoded(try blocks(#"[{"type":"header","data":{"text":"Hi","level":2}}]"#))

        XCTAssertTrue(encoded.contains(#""level":2"#), encoded)
        XCTAssertFalse(encoded.contains("2.0"), encoded)
    }

    // MARK: - Save payload

    /// The server applies only the keys present in the body (`Object.hasOwn`),
    /// so a nil field must be omitted, not sent as null — sending
    /// `"blocks": null` would be rejected as an invalid blocks array.
    func testSaveBodyOmitsFieldsItIsNotChanging() throws {
        let body = DocumentsAPI.SaveDocumentBody(id: "d1", title: "Renamed")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(body)) as? [String: Any]
        )

        XCTAssertEqual(json["id"] as? String, "d1")
        XCTAssertEqual(json["title"] as? String, "Renamed")
        XCTAssertNil(json.index(forKey: "blocks"))
        XCTAssertNil(json.index(forKey: "updatedAt"))
    }
}
