import UIKit

/// The styles the composer's format bar can toggle.
enum RichTextStyle: CaseIterable {
    case bold
    case italic
    case underline
    case bulletList
}

/// Pure formatting logic behind the composer's WYSIWYG editor — bold,
/// italic, underline, and bullet lists over `NSAttributedString`, plus HTML
/// export for sending. Kept free of UITextView so it's unit-testable;
/// `RichTextEditor` supplies the UIKit glue.
enum RichText {
    /// Literal bullet marker prepended to listed paragraphs. Rendered as text
    /// (not `<ul>`) so the exported HTML stays simple and the reader shows
    /// it verbatim.
    static let bulletPrefix = "• "

    // MARK: Style inspection

    /// The styles active at `range`, decided by its first character — the
    /// standard editor convention, so a mixed selection normalizes to the
    /// state at the selection start rather than flipping each run.
    static func styles(in text: NSAttributedString, range: NSRange) -> Set<RichTextStyle> {
        guard text.length > 0 else { return [] }
        let index = min(max(range.location, 0), text.length - 1)

        var styles: Set<RichTextStyle> = []
        if let font = text.attribute(.font, at: index, effectiveRange: nil) as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { styles.insert(.bold) }
            if traits.contains(.traitItalic) { styles.insert(.italic) }
        }
        if let raw = (text.attribute(.underlineStyle, at: index, effectiveRange: nil) as? NSNumber)?.intValue,
           raw & NSUnderlineStyle.single.rawValue != 0 {
            styles.insert(.underline)
        }
        if paragraphContaining(index: index, in: text).hasPrefix(bulletPrefix) {
            styles.insert(.bulletList)
        }
        return styles
    }

    // MARK: Character styles

    /// Uniformly turns a character style on/off across `range`. No-op for an
    /// empty range (the editor flips `typingAttributes` for that case).
    static func setStyle(
        _ style: RichTextStyle,
        active: Bool,
        in text: NSAttributedString,
        range: NSRange
    ) -> NSAttributedString {
        guard range.length > 0, style != .bulletList else { return text }
        let mutable = NSMutableAttributedString(attributedString: text)

        switch style {
        case .bold, .italic:
            let trait: UIFontDescriptor.SymbolicTraits = style == .bold ? .traitBold : .traitItalic
            mutable.enumerateAttribute(.font, in: range) { value, subRange, _ in
                let font = (value as? UIFont) ?? .systemFont(ofSize: UIFont.labelFontSize)
                var traits = font.fontDescriptor.symbolicTraits
                if active { traits.insert(trait) } else { traits.remove(trait) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    mutable.addAttribute(
                        .font,
                        value: UIFont(descriptor: descriptor, size: font.pointSize),
                        range: subRange
                    )
                }
            }

        case .underline:
            mutable.addAttribute(
                .underlineStyle,
                value: active ? NSUnderlineStyle.single.rawValue : 0,
                range: range
            )

        case .bulletList:
            break
        }

        return mutable
    }

    /// Flips a character style in the attributes applied to newly typed text
    /// (the empty-selection case).
    static func updatingTypingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        style: RichTextStyle,
        active: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attrs = attributes

        switch style {
        case .bold, .italic:
            let font = (attrs[.font] as? UIFont) ?? .preferredFont(forTextStyle: .body)
            let trait: UIFontDescriptor.SymbolicTraits = style == .bold ? .traitBold : .traitItalic
            var traits = font.fontDescriptor.symbolicTraits
            if active { traits.insert(trait) } else { traits.remove(trait) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                attrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }

        case .underline:
            attrs[.underlineStyle] = active ? NSUnderlineStyle.single.rawValue : 0

        case .bulletList:
            break
        }

        return attrs
    }

    // MARK: Bullet lists

    /// Toggles bullet markers on every paragraph intersecting `range`. A
    /// collapsed caret bullets (or unbullets) its own paragraph, including a
    /// trailing empty one at the end of the document. Returns the updated
    /// text and a selection range shifted to track the inserted/removed
    /// markers, so the cursor stays where the user left it.
    static func toggleBulletList(
        in text: NSAttributedString,
        range: NSRange
    ) -> (text: NSAttributedString, selectedRange: NSRange) {
        let mutable = NSMutableAttributedString(attributedString: text)
        let length = mutable.length
        let markerLength = (bulletPrefix as NSString).length

        // A collapsed caret selects nothing — expand it to the character
        // under it so its paragraph counts as affected.
        var target = range
        if target.length == 0 {
            let location = min(target.location, length)
            target = NSRange(location: location, length: min(1, length - location))
        }

        var paragraphs: [NSRange] = []
        if length > 0 {
            // NSString enumeration; paragraph ranges map 1:1 onto the
            // attributed string's UTF-16 offsets.
            (mutable.string as NSString).enumerateSubstrings(
                in: NSRange(location: 0, length: length),
                options: [.byParagraphs]
            ) { _, paragraphRange, _, _ in
                paragraphs.append(paragraphRange)
            }
        }

        var affected = paragraphs.filter { NSIntersectionRange($0, target).length > 0 }
        if affected.isEmpty, let last = paragraphs.last,
           NSMaxRange(last) >= min(range.location, length) {
            // Caret sits on the (empty) final line — bullet that paragraph.
            affected = [last]
        }
        guard !affected.isEmpty else { return (mutable, range) }

        // Toggle direction comes from the first affected paragraph, so a
        // mixed selection unbullets everything.
        let firstIsListed: Bool
        if let first = affected.first {
            firstIsListed = substring(mutable, at: first.location, length: markerLength) == bulletPrefix
        } else {
            firstIsListed = false
        }

        var deltasByLocation: [Int: Int] = [:]
        // Last-to-first keeps earlier paragraph offsets valid while editing.
        for paragraph in affected.reversed() {
            if firstIsListed {
                if substring(mutable, at: paragraph.location, length: markerLength) == bulletPrefix {
                    mutable.deleteCharacters(
                        in: NSRange(location: paragraph.location, length: markerLength)
                    )
                    deltasByLocation[paragraph.location] = -markerLength
                }
            } else {
                let attributes = paragraph.length > 0
                    ? mutable.attributes(at: paragraph.location, effectiveRange: nil)
                    : [:]
                mutable.insert(
                    NSAttributedString(string: bulletPrefix, attributes: attributes),
                    at: paragraph.location
                )
                deltasByLocation[paragraph.location] = markerLength
            }
        }

        // Markers inserted/deleted at or before a position move that
        // position; `<=` matters for a caret sitting exactly where the
        // marker goes.
        func shifted(_ position: Int) -> Int {
            position + deltasByLocation
                .filter { $0.key <= position }
                .values
                .reduce(0, +)
        }

        let originalStart = min(range.location, length)
        let originalEnd = min(originalStart + max(range.length, 0), length)
        let newLocation = max(0, shifted(originalStart))
        let newEnd = min(max(newLocation, shifted(originalEnd)), mutable.length)
        return (mutable, NSRange(location: newLocation, length: newEnd - newLocation))
    }

    // MARK: HTML export

    /// Serializes the composed body to the `html` field of `POST /send`
    /// accepts — the body content only, without WebKit's `<html>/<head>`
    /// boilerplate. Must run on the main actor (the conversion goes through
    /// WebKit internally).
    @MainActor
    static func html(from text: NSAttributedString) throws -> String {
        let data = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )
        return bodyContent(of: String(decoding: data, as: UTF8.self))
    }

    /// The inner content of an HTML document's `<body>`, falling back to the
    /// whole input when no body element is present.
    static func bodyContent(of html: String) -> String {
        guard
            let bodyOpen = html.range(of: "<body", options: .caseInsensitive)?.upperBound,
            let contentStart = html[bodyOpen...].range(of: ">")?.upperBound,
            let bodyClose = html[contentStart...].range(of: "</body>", options: .caseInsensitive)
        else {
            return html
        }
        return String(html[contentStart..<bodyClose.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// The paragraph containing `index`, as a plain string.
    static func paragraphContaining(index: Int, in text: NSAttributedString) -> String {
        guard text.length > 0 else { return "" }
        let clamped = min(max(index, 0), text.length - 1)
        var result = ""
        (text.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byParagraphs]
        ) { substring, paragraphRange, _, stop in
            if NSLocationInRange(clamped, paragraphRange) {
                result = substring ?? ""
                stop.pointee = true
            }
        }
        return result
    }

    private static func substring(
        _ text: NSAttributedString,
        at location: Int,
        length: Int
    ) -> String {
        let range = NSRange(location: location, length: min(length, text.length - location))
        guard range.length > 0 else { return "" }
        return text.attributedSubstring(from: range).string
    }
}
