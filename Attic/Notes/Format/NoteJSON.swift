import Foundation

/// A JSON value that keeps what it read: 64-bit integers stay integers
/// (never coerced to `Double`), so an unknown field a newer Attic wrote is
/// written back with the same value. Objects are unordered, as in JSON.
///
/// Used for everything the note format does not understand: unknown
/// document, block and inline fields, and whole unsupported blocks.
enum NoteJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([NoteJSON])
    case object([String: NoteJSON])

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// An integer that fits `Int`. A double, even a whole one, is not an
    /// integer here: `1.0` where `1` is expected is a type change.
    var intValue: Int? {
        switch self {
        case let .int(value): Int(exactly: value)
        case let .uint(value): Int(exactly: value)
        default: nil
        }
    }

    /// Any number, as a `Double` (display widths).
    var numberValue: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .uint(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }

    var objectValue: [String: NoteJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [NoteJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }
}

extension NoteJSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NoteJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: NoteJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .uint(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
