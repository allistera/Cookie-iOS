import Foundation

/// One Editor.js block, held as raw JSON so anything this app doesn't
/// understand survives a save untouched.
struct DocumentBlock: Codable, Hashable, Sendable {
    var value: JSONValue

    init(value: JSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(JSONValue.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var type: String { value["type"]?.stringValue ?? "" }
    var data: JSONValue? { value["data"] }
}

/// Where an editable string lives inside the block array: a block's own text,
/// or an item nested somewhere in a list block.
struct BlockFieldPath: Hashable, Sendable {
    let blockIndex: Int
    /// Indices walked down a list block's nested `items`; empty for a block's
    /// own text.
    var itemPath: [Int] = []
}

/// One line of the editor: either an editable string or a block this app
/// can't edit but must keep.
enum DocumentBodyRow: Identifiable, Hashable, Sendable {
    case editable(EditableBlockField)
    case unsupported(blockIndex: Int, type: String)

    var id: String {
        switch self {
        case .editable(let field): "field-\(field.path)"
        case .unsupported(let index, _): "block-\(index)"
        }
    }

    var blockIndex: Int {
        switch self {
        case .editable(let field): field.path.blockIndex
        case .unsupported(let index, _): index
        }
    }
}

struct EditableBlockField: Hashable, Sendable {
    enum Style: Hashable, Sendable {
        case paragraph
        case header(level: Int)
        case quote
        case code
        case listItem(depth: Int, marker: String)
    }

    let path: BlockFieldPath
    let style: Style
    /// The block's text with inline HTML reduced to plain text.
    let text: String

    /// A list item is one line inside a block; the rest own their whole block,
    /// so only they can be deleted as a unit.
    var ownsWholeBlock: Bool {
        if case .listItem = style { return false }
        return true
    }
}

/// Reads and writes the text of the block types this app can edit.
///
/// Everything else — tables, images, kanban boards, drawings — is listed but
/// left alone, and a block whose text isn't edited keeps its original inline
/// HTML rather than being rewritten from the stripped-down plain text.
enum DocumentBody {
    /// Block types whose text this editor can change.
    static let editableTypes: Set<String> = ["paragraph", "header", "quote", "code", "list"]

    // MARK: - Reading

    static func rows(in blocks: [DocumentBlock]) -> [DocumentBodyRow] {
        blocks.indices.flatMap { rows(forBlockAt: $0, in: blocks) }
    }

    /// Returns `rows` with the lines of the block at `index` rebuilt from
    /// `blocks`, leaving every other block's lines as they were. Typing into
    /// one field only changes its own block, so this spares re-stripping the
    /// HTML of the whole document on every keystroke. Only valid when block
    /// indices haven't shifted since `rows` was built.
    static func rows(
        _ rows: [DocumentBodyRow],
        replacingBlockAt index: Int,
        in blocks: [DocumentBlock]
    ) -> [DocumentBodyRow] {
        guard let start = rows.firstIndex(where: { $0.blockIndex == index }) else {
            return self.rows(in: blocks)
        }
        let end = rows[start...].firstIndex(where: { $0.blockIndex != index }) ?? rows.endIndex
        var updated = rows
        updated.replaceSubrange(start..<end, with: self.rows(forBlockAt: index, in: blocks))
        return updated
    }

    static func rows(forBlockAt index: Int, in blocks: [DocumentBlock]) -> [DocumentBodyRow] {
        guard blocks.indices.contains(index) else { return [] }
        let block = blocks[index]
        var rows: [DocumentBodyRow] = []
        switch block.type {
        case "paragraph":
            rows.append(editableRow(index, .paragraph, html: block.data?["text"]))
        case "header":
            let level = block.data?["level"]?.intValue ?? 2
            rows.append(editableRow(index, .header(level: level), html: block.data?["text"]))
        case "quote":
            rows.append(editableRow(index, .quote, html: block.data?["text"]))
        case "code":
            let code = block.data?["code"]?.stringValue ?? ""
            rows.append(.editable(.init(
                path: .init(blockIndex: index),
                style: .code,
                text: code
            )))
        case "list":
            let items = block.data?["items"]?.arrayValue ?? []
            if items.isEmpty {
                rows.append(.unsupported(blockIndex: index, type: block.type))
            } else {
                appendListRows(
                    items,
                    blockIndex: index,
                    style: block.data?["style"]?.stringValue ?? "unordered",
                    parentPath: [],
                    into: &rows
                )
            }
        default:
            rows.append(.unsupported(blockIndex: index, type: block.type))
        }
        return rows
    }

    private static func editableRow(
        _ index: Int,
        _ style: EditableBlockField.Style,
        html: JSONValue?
    ) -> DocumentBodyRow {
        .editable(.init(
            path: .init(blockIndex: index),
            style: style,
            text: plainText(fromHTML: html?.stringValue ?? "")
        ))
    }

    /// `@editorjs/list` v2 items are objects with `content` and their own
    /// nested `items`; documents written by older versions still hold plain
    /// strings, so both shapes are read.
    private static func appendListRows(
        _ items: [JSONValue],
        blockIndex: Int,
        style: String,
        parentPath: [Int],
        into rows: inout [DocumentBodyRow]
    ) {
        for (offset, item) in items.enumerated() {
            let path = parentPath + [offset]
            let content = item.stringValue ?? item["content"]?.stringValue ?? ""
            rows.append(.editable(.init(
                path: .init(blockIndex: blockIndex, itemPath: path),
                style: .listItem(
                    depth: parentPath.count,
                    marker: marker(style: style, number: offset + 1, item: item)
                ),
                text: plainText(fromHTML: content)
            )))

            if let nested = item["items"]?.arrayValue, !nested.isEmpty {
                appendListRows(
                    nested,
                    blockIndex: blockIndex,
                    style: style,
                    parentPath: path,
                    into: &rows
                )
            }
        }
    }

    private static func marker(style: String, number: Int, item: JSONValue) -> String {
        switch style {
        case "ordered": "\(number)."
        case "checklist": (item["meta"]?["checked"]?.boolValue ?? false) ? "☑" : "☐"
        default: "•"
        }
    }

    // MARK: - Writing

    /// Returns `blocks` with the text at `path` replaced. A field whose plain
    /// text is unchanged is left exactly as it was, so opening a document and
    /// editing one paragraph can't strip the bold and links out of the others.
    static func setting(
        _ text: String,
        at path: BlockFieldPath,
        in blocks: [DocumentBlock]
    ) -> [DocumentBlock] {
        guard blocks.indices.contains(path.blockIndex) else { return blocks }
        var blocks = blocks
        var block = blocks[path.blockIndex]

        if path.itemPath.isEmpty {
            switch block.type {
            case "code":
                guard block.data?["code"]?.stringValue != text else { return blocks }
                block.value["data"]?["code"] = .string(text)
            case "paragraph", "header", "quote":
                let current = block.data?["text"]?.stringValue ?? ""
                guard plainText(fromHTML: current) != text else { return blocks }
                block.value["data"]?["text"] = .string(html(fromPlainText: text))
            default:
                return blocks
            }
        } else {
            guard var items = block.data?["items"] else { return blocks }
            guard setItemContent(text, at: path.itemPath[...], in: &items) else { return blocks }
            block.value["data"]?["items"] = items
        }

        blocks[path.blockIndex] = block
        return blocks
    }

    /// Walks a list block's nested `items` to the addressed item and rewrites
    /// it. Returns false when nothing changed, so callers can skip the write.
    private static func setItemContent(
        _ text: String,
        at path: ArraySlice<Int>,
        in items: inout JSONValue
    ) -> Bool {
        guard let index = path.first, var item = items[index] else { return false }

        if path.count > 1 {
            guard var nested = item["items"] else { return false }
            guard setItemContent(text, at: path.dropFirst(), in: &nested) else { return false }
            item["items"] = nested
            items[index] = item
            return true
        }

        // A string item stays a string; an object item keeps its meta and
        // nested items and only has `content` rewritten.
        if let current = item.stringValue {
            guard plainText(fromHTML: current) != text else { return false }
            items[index] = .string(html(fromPlainText: text))
        } else {
            let current = item["content"]?.stringValue ?? ""
            guard plainText(fromHTML: current) != text else { return false }
            item["content"] = .string(html(fromPlainText: text))
            items[index] = item
        }
        return true
    }

    static func appendingParagraph(to blocks: [DocumentBlock]) -> [DocumentBlock] {
        blocks + [DocumentBlock(value: .object([
            "id": .string(generatedBlockID()),
            "type": .string("paragraph"),
            "data": .object(["text": .string("")]),
        ]))]
    }

    static func removingBlock(at index: Int, from blocks: [DocumentBlock]) -> [DocumentBlock] {
        guard blocks.indices.contains(index) else { return blocks }
        var blocks = blocks
        blocks.remove(at: index)
        return blocks
    }

    /// Editor.js block ids are 10 characters from its own alphabet; matching
    /// the shape keeps documents written here indistinguishable from the
    /// web app's.
    private static func generatedBlockID() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        return String((0..<10).compactMap { _ in alphabet.randomElement() })
    }

    // MARK: - Inline HTML

    /// Editor.js stores paragraph/header/list text as HTML — the inline
    /// bold/italic/link markup its toolbar produces. This editor is plain
    /// text, so tags are stripped for display, mirroring the same reduction
    /// the server's `flattenBlocksToText` does for search.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        // Last: an escaped ampersand must not re-expand the entities above.
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The inverse, for text the user actually changed. Formatting inside an
    /// edited block is lost — that block's markup is replaced by what was
    /// typed — which is why untouched blocks are never routed through here.
    static func html(fromPlainText text: String) -> String {
        var html = text.replacingOccurrences(of: "&", with: "&amp;")
        html = html.replacingOccurrences(of: "<", with: "&lt;")
        html = html.replacingOccurrences(of: ">", with: "&gt;")
        return html.replacingOccurrences(of: "\n", with: "<br>")
    }

    /// A human-readable name for a block this editor can't change, shown in
    /// place of its content.
    static func displayName(forBlockType type: String) -> String {
        switch type {
        case "table": "Table"
        case "image": "Image"
        case "kanban": "Kanban board"
        case "excalidraw": "Drawing"
        case "delimiter": "Divider"
        case "list": "Empty list"
        case "": "Block"
        default: type.prefix(1).uppercased() + type.dropFirst()
        }
    }
}

/// A note's content exactly as it was loaded, so SwiftUI echoing the load
/// back through `onChange` is not mistaken for an edit and saved — which
/// would bump `updated_at` and can conflict with the web app.
struct NoteEditBaseline {
    private struct Content: Equatable {
        var title: String
        var blocks: [DocumentBlock]
    }

    private var unedited: Content?

    mutating func loaded(title: String, blocks: [DocumentBlock]) {
        unedited = Content(title: title, blocks: blocks)
    }

    /// Whether this content is a real edit. After the first one every change
    /// counts, so typing and then undoing back to the original still saves
    /// over the draft that went out in between.
    mutating func isEdit(title: String, blocks: [DocumentBlock]) -> Bool {
        if unedited == Content(title: title, blocks: blocks) { return false }
        unedited = nil
        return true
    }
}
