import Foundation

/// A lossless, mutable representation of arbitrary JSON.
///
/// Documents are Editor.js blocks, and a block's `data` can hold anything the
/// web app's tools put there — table workbooks, kanban lanes, image metadata.
/// The iOS editor only understands a handful of text block types, so every
/// save round-trips the untouched parts of the tree verbatim rather than
/// re-serializing them from a narrower model, which would quietly destroy
/// whatever it didn't model.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// Kept apart from `double` so whole numbers re-encode as `2`, not `2.0`.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Reads and writes a key on an object value; writing to a non-object is
    /// a no-op, so a malformed block can't crash a save.
    subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let fields) = self else { return nil }
            return fields[key]
        }
        set {
            guard case .object(var fields) = self else { return }
            fields[key] = newValue
            self = .object(fields)
        }
    }

    /// Reads and writes an element of an array value; out-of-range writes are
    /// a no-op for the same reason.
    subscript(index: Int) -> JSONValue? {
        get {
            guard case .array(let items) = self, items.indices.contains(index) else { return nil }
            return items[index]
        }
        set {
            guard case .array(var items) = self, items.indices.contains(index),
                  let newValue else { return }
            items[index] = newValue
            self = .array(items)
        }
    }
}
