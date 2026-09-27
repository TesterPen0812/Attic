import Foundation

/// What a note's stored bytes mean to this build.
enum NoteContent: Equatable, Sendable {
    /// A document this build can edit and write back.
    case editable(NoteDocument)
    /// Written by a newer Attic, or unreadable. `original` is what the store
    /// holds and is the only thing ever written back; `preview` is a best
    /// effort for display (unknown parts shown as placeholders), never saved.
    case readOnly(original: Data, reason: NoteReadOnlyReason, preview: NoteDocument?)

    var document: NoteDocument? {
        switch self {
        case let .editable(document): document
        case let .readOnly(_, _, preview): preview
        }
    }

    var isEditable: Bool {
        if case .editable = self { return true }
        return false
    }
}

enum NoteReadOnlyReason: Equatable, Sendable {
    case newerFormat(Int)
    case requiresCapabilities([String])
    case unsupportedContent
    case unreadable(String)

    var message: String {
        switch self {
        case .newerFormat, .requiresCapabilities, .unsupportedContent:
            "Some content needs a newer Attic, so this note is read-only here."
        case .unreadable:
            "This note’s content can’t be read, so it is kept exactly as it is."
        }
    }
}

/// Reads and writes `attic.note/1`. Encoding is deterministic (sorted keys),
/// so equal documents give equal bytes.
enum NoteContentCodec {
    static func decode(_ data: Data) -> NoteContent {
        let root: NoteJSON
        do {
            root = try JSONDecoder().decode(NoteJSON.self, from: data)
        } catch {
            return .readOnly(original: data, reason: .unreadable("not JSON"), preview: nil)
        }
        guard let object = root.objectValue,
              let format = object["format"]?.intValue,
              format >= 1,
              let rawBlocks = object["blocks"]?.arrayValue else {
            return .readOnly(original: data, reason: .unreadable("no format or blocks"), preview: nil)
        }
        var requires: [String] = []
        if let rawRequires = object["requires"] {
            guard let values = rawRequires.arrayValue,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                return .readOnly(original: data, reason: .unreadable("requires is not a list of names"), preview: nil)
            }
            requires = values.compactMap(\.stringValue)
        }
        var extras = object
        for key in ["format", "requires", "blocks"] { extras[key] = nil }
        var document = NoteDocument(blocks: rawBlocks.map(decodeBlock), requires: requires, extras: extras)
        document.format = format
        if document.blocks.isEmpty { document.blocks = [.text("")] }

        if format > NoteDocument.currentFormat {
            return .readOnly(original: data, reason: .newerFormat(format), preview: document)
        }
        let unknown = requires.filter { !NoteDocument.editableCapabilities.contains($0) }
        if !unknown.isEmpty {
            return .readOnly(original: data, reason: .requiresCapabilities(unknown), preview: document)
        }
        if document.blocks.contains(where: { block in
            if block.kind == .opaque { return true }
            return block.inlines.contains { inline in
                if case .opaque = inline.kind { return true }
                return false
            }
        }) {
            return .readOnly(original: data, reason: .unsupportedContent, preview: document)
        }
        return .editable(document)
    }

    static func encode(_ document: NoteDocument) throws -> Data {
        var object = document.extras
        object["format"] = .int(Int64(document.format))
        if !document.requires.isEmpty {
            object["requires"] = .array(document.requires.map(NoteJSON.string))
        } else {
            object["requires"] = nil
        }
        object["blocks"] = .array(document.blocks.map(encodeBlock))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(NoteJSON.object(object))
    }

    // MARK: Blocks

    static func decodeBlock(_ value: NoteJSON) -> NoteBlock {
        guard let object = value.objectValue, let kind = object["kind"]?.stringValue else {
            return .opaque(value)
        }
        var block: NoteBlock?
        switch kind {
        case "text":
            block = decodeTextual(object, kind: .text, known: ["kind", "text", "id", "style", "inline"])
        case "checklist":
            block = decodeTextual(object, kind: .checklist, known: ["kind", "text", "id", "checked", "inline"])
        case "image":
            block = decodeImage(object)
        default:
            block = nil
        }
        return block ?? .opaque(value)
    }

    private static func decodeTextual(
        _ object: [String: NoteJSON],
        kind: NoteBlockKind,
        known: Set<String>
    ) -> NoteBlock? {
        guard let text = object["text"]?.stringValue else { return nil }
        var block = NoteBlock(kind: kind, text: text)
        if let rawID = object["id"] {
            guard let id = rawID.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            block.id = id
        }
        if kind == .checklist {
            guard block.id != nil else { return nil }
            if let checked = object["checked"] {
                guard let value = checked.boolValue else { return nil }
                block.checked = value
            }
        }
        if kind == .text, let style = object["style"] {
            guard let value = style.stringValue else { return nil }
            block.style = value
        }
        if let rawInlines = object["inline"] {
            guard let values = rawInlines.arrayValue,
                  let inlines = decodeInlines(values, in: text) else { return nil }
            block.inlines = inlines
        } else if text.contains(NoteDocument.objectCharacter) {
            // An object character with nothing to show there.
            return nil
        }
        block.extras = object.filter { !known.contains($0.key) }
        return block
    }

    private static func decodeImage(_ object: [String: NoteJSON]) -> NoteBlock? {
        guard let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let attachmentID = object["attachmentID"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        var block = NoteBlock.image(id: id, attachmentID: attachmentID)
        if let rawWidth = object["width"] {
            guard let width = rawWidth.numberValue, width.isFinite, width > 0 else { return nil }
            block.width = width
        }
        if let rawFraction = object["widthFraction"] {
            guard let fraction = rawFraction.numberValue, fraction.isFinite,
                  fraction > 0, fraction <= 1 else { return nil }
            block.widthFraction = fraction
        }
        for (key, path) in [("pixelWidth", \NoteBlock.pixelWidth), ("pixelHeight", \NoteBlock.pixelHeight)] {
            guard let raw = object[key] else { continue }
            guard let value = raw.intValue, value > 0 else { return nil }
            block[keyPath: path] = value
        }
        block.extras = object.filter {
            !["kind", "id", "attachmentID", "width", "widthFraction", "pixelWidth", "pixelHeight"].contains($0.key)
        }
        return block
    }

    /// Inline objects must sit, in order, exactly on the text's U+FFFC
    /// characters (UTF-16 offsets), one each.
    private static func decodeInlines(_ values: [NoteJSON], in text: String) -> [NoteInline]? {
        let units = Array(text.utf16)
        let objectOffsets = units.indices.filter { units[$0] == NoteDocument.objectUnit }
        guard objectOffsets.count == values.count else { return nil }
        var inlines: [NoteInline] = []
        for (value, expectedOffset) in zip(values, objectOffsets) {
            guard let object = value.objectValue,
                  object["offset"]?.intValue == expectedOffset,
                  let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let kind = object["kind"]?.stringValue else { return nil }
            if kind == "date" {
                guard let day = object["date"]?.stringValue.flatMap(NoteDay.init(isoString:)) else { return nil }
                let extras = object.filter { !["kind", "id", "offset", "date"].contains($0.key) }
                inlines.append(NoteInline(id: id, kind: .date(day), extras: extras))
            } else {
                inlines.append(NoteInline(id: id, kind: .opaque(value)))
            }
        }
        return inlines
    }

    static func encodeBlock(_ block: NoteBlock) -> NoteJSON {
        switch block.kind {
        case .opaque:
            return block.opaque ?? .null
        case .text, .checklist:
            var object = block.extras
            object["kind"] = .string(block.kind.rawValue)
            object["text"] = .string(block.text)
            object["id"] = block.id.map { .string($0.uuidString) }
            if block.kind == .checklist {
                object["checked"] = .bool(block.checked)
            } else {
                object["style"] = block.style.map(NoteJSON.string)
            }
            if !block.inlines.isEmpty {
                let units = Array(block.text.utf16)
                let offsets = units.indices.filter { units[$0] == NoteDocument.objectUnit }
                object["inline"] = .array(zip(block.inlines, offsets).map { inline, offset in
                    encodeInline(inline, offset: offset)
                })
            } else {
                object["inline"] = nil
            }
            return .object(object)
        case .image:
            var object = block.extras
            object["kind"] = .string("image")
            object["id"] = block.id.map { .string($0.uuidString) }
            object["attachmentID"] = block.attachmentID.map { .string($0.uuidString) }
            object["width"] = block.width.map(NoteJSON.double)
            object["widthFraction"] = block.widthFraction.map(NoteJSON.double)
            object["pixelWidth"] = block.pixelWidth.map { .int(Int64($0)) }
            object["pixelHeight"] = block.pixelHeight.map { .int(Int64($0)) }
            return .object(object)
        }
    }

    private static func encodeInline(_ inline: NoteInline, offset: Int) -> NoteJSON {
        switch inline.kind {
        case let .date(day):
            var object = inline.extras
            object["kind"] = .string("date")
            object["id"] = .string(inline.id.uuidString)
            object["offset"] = .int(Int64(offset))
            object["date"] = .string(day.isoString)
            return .object(object)
        case let .opaque(raw):
            // Only its position is ours to update.
            guard var object = raw.objectValue else { return raw }
            object["offset"] = .int(Int64(offset))
            return .object(object)
        }
    }
}
