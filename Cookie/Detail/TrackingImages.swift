import Foundation

/// Removes tracking images (open pixels) from a message body before it is
/// rendered, whatever the image setting, as Cookie-Web's `trackingImages.js` does.
///
/// An `img` is a tracker when its `src` is remote (http or https; a cid: or
/// data: image makes no request) and either every size it declares (width or
/// height attributes, inline width, height, max-width or max-height) is at
/// most one pixel, with at least one declared, or its address carries one of
/// the open-tracking paths the common mail platforms use.
///
/// This is a small tag scanner, not an HTML parser. It only deletes a whole
/// `<img …>` tag that it read to its closing `>`, and leaves anything it cannot
/// read (a tag or quoted value that never closes) as it was. The body is
/// sender-controlled HTML with no other sanitiser on iOS, so a deletion cannot
/// produce markup the sender could not have written directly.
enum TrackingImages {
    /// Open-tracking endpoints, matched against the lower-cased src. Kept in
    /// step with `TRACKER_URL_PATTERNS` in Cookie-Web.
    private static let trackerURLPatterns = [
        "/track/open",  // Mailchimp, Mandrill and others
        "/wf/open",  // SendGrid, Klaviyo
        "track.hubspot.com/__ptq.gif",
        "mailtrack.io/trace/",
        "t.yesware.com/t/",
        "app.mixmax.com/api/track/",
        "mailfoogae.appspot.com/t?",  // Streak
        "r.superhuman.com/",
        "pstmrk.it/open",  // Postmark
        "getresponse.com/open.html",
        "rs6.net/on.jsp",  // Constant Contact
        "open.convertkit-mail",
        "awstrack.me/i0/",  // Amazon SES
        "sendibm.com/tr/op/",  // Brevo
        "/open.aspx",  // Salesforce Marketing Cloud
        "google-analytics.com/collect",
    ]

    /// The HTML without its tracking images; the input itself when there are none.
    static func removingTrackers(from html: String) -> String {
        let bytes = Array(html.utf8)
        var kept: [UInt8] = []
        var copiedUpTo = 0
        var searchFrom = 0
        while let start = imgTagStart(in: bytes, from: searchFrom) {
            var scanner = TagScanner(bytes: bytes, index: start + 4)
            guard let attributes = scanner.readAttributes() else { break }
            // The scanner stops on the tag's closing ">".
            let end = scanner.index + 1
            if isTracker(attributes) {
                kept += bytes[copiedUpTo..<start]
                copiedUpTo = end
            }
            searchFrom = end
        }
        guard copiedUpTo > 0 else { return html }
        kept += bytes[copiedUpTo...]
        // Removed ranges start at "<" and end after ">", so no UTF-8 sequence is split.
        return String(bytes: kept, encoding: .utf8) ?? html
    }

    /// The offset of the next `<img` start tag, matched without regard to case.
    private static func imgTagStart(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 4 < bytes.count {
            if bytes[index] == UInt8(ascii: "<"), isIMGName(bytes, at: index + 1) { return index }
            index += 1
        }
        return nil
    }

    /// "img" in any case, followed by what ends a tag name. Needs four bytes from `index`.
    private static func isIMGName(_ bytes: [UInt8], at index: Int) -> Bool {
        let name = bytes[index..<(index + 3)].map { $0 | 0x20 }
        return name == Array("img".utf8) && isTagNameEnd(bytes[index + 3])
    }

    private static func isTracker(_ attributes: [String: String]) -> Bool {
        let source = (attributes["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else { return false }
        let style = styleDeclarations(attributes["style"] ?? "")
        let attributeSizes = [attributes["width"], attributes["height"]].compactMap { $0 }
        let styleSizes = ["width", "height", "max-width", "max-height"].compactMap { style[$0] }
        let sizes = (attributeSizes + styleSizes).compactMap { pixels($0) }
        if !sizes.isEmpty, sizes.allSatisfy({ $0 <= 1 }) { return true }
        return trackerURLPatterns.contains { source.contains($0) }
    }

    /// Inline declarations by lower-cased property name; a later one wins, as in CSS.
    private static func styleDeclarations(_ style: String) -> [String: String] {
        var declarations: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasSuffix("!important") {
                value = String(value.dropLast("!important".count))
            }
            declarations[name] = value
        }
        return declarations
    }

    /// A declared length in pixels, or nil for anything else (percentages,
    /// keywords, nothing). Attributes take a bare number; inline styles end in px.
    private static func pixels(_ value: String) -> Double? {
        var number = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if number.hasSuffix("px") {
            number = String(number.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ isDigits($0) }) else { return nil }
        return Double(number)
    }

    private static func isDigits(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func isTagNameEnd(_ byte: UInt8) -> Bool {
        isHTMLSpace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">")
    }
}

/// The HTML tokenizer's whitespace: tab, line feed, form feed, carriage return and space.
private func isHTMLSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
}

/// Reads one start tag's attributes the way the HTML tokenizer splits them.
private struct TagScanner {
    let bytes: [UInt8]
    var index: Int

    /// The attributes up to the tag's closing ">", where it leaves `index`, or
    /// nil when the tag or a quoted value never closes. A repeated name keeps
    /// its first value, as in HTML.
    mutating func readAttributes() -> [String: String]? {
        var attributes: [String: String] = [:]
        while true {
            skip { isHTMLSpace($0) || $0 == UInt8(ascii: "/") }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ">") { return attributes }
            let name = readName()
            guard let value = readValue() else { return nil }
            if attributes[name] == nil { attributes[name] = value }
        }
    }

    private mutating func skip(while predicate: (UInt8) -> Bool) {
        while index < bytes.count, predicate(bytes[index]) { index += 1 }
    }

    private mutating func readName() -> String {
        let start = index
        // The first byte always belongs to the name, even a stray "=".
        index += 1
        skip { !isHTMLSpace($0) && !"/>=".utf8.contains($0) }
        return (String(bytes: bytes[start..<index], encoding: .utf8) ?? "").lowercased()
    }

    /// The value after an "=", "" for a bare attribute, or nil when a quote never closes.
    private mutating func readValue() -> String? {
        skip(while: isHTMLSpace)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return "" }
        index += 1
        skip(while: isHTMLSpace)
        guard index < bytes.count else { return nil }
        let quote = bytes[index]
        guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
            let start = index
            skip { !isHTMLSpace($0) && $0 != UInt8(ascii: ">") }
            return String(bytes: bytes[start..<index], encoding: .utf8) ?? ""
        }
        guard let close = bytes[(index + 1)...].firstIndex(of: quote) else { return nil }
        let value = String(bytes: bytes[(index + 1)..<close], encoding: .utf8) ?? ""
        index = close + 1
        return value
    }
}
