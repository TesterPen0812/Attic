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
    case legacyFormat
    case newerFormat(Int)
    case requiresCapabilities([String])
    case unsupportedContent
    case unreadable(String)

    var message: String {
        switch self {
        case .legacyFormat:
            "This note uses the original format. Convert to edit it in this editor."
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
    enum EncodingError: Error { case invalidStructure }
    enum Context { case document, fragment }
    static func decode(_ data: Data, context: Context = .document) -> NoteContent {
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
        if context == .document, let first = document.blocks.first, first.kind == .text,
           first.style != nil || first.level != nil || first.indent != nil {
            return .readOnly(original: data, reason: .unsupportedContent, preview: document)
        }
        return .editable(document)
    }

    static func encode(_ document: NoteDocument, context: Context = .document) throws -> Data {
        var document = document
        document.refreshRequiredCapabilities()
        if context == .document, let first = document.blocks.first, first.kind == .text,
           first.style != nil || first.level != nil || first.indent != nil {
            throw EncodingError.invalidStructure
        }
        guard document.blocks.allSatisfy(validForEncoding) else { throw EncodingError.invalidStructure }
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

    private static func validForEncoding(_ block: NoteBlock) -> Bool {
        if block.kind == .file {
            guard block.id != nil, block.filename?.isEmpty == false,
                  block.contentTypeIdentifier?.isEmpty == false,
                  let bytes = block.byteCount, bytes >= 0,
                  (block.attachmentID != nil) != (block.importFailure != nil),
                  block.importFailure == nil || block.importFailure?.isEmpty == false else { return false }
        }
        if block.kind == .table {
            guard block.id != nil, let table = block.table, table.isRectangular, table.isWithinLimits else { return false }
            return table.rows.allSatisfy { row in row.cells.allSatisfy { cell in
                validMarks(cell.marks, in: cell.text) && !cell.text.contains(NoteDocument.objectCharacter) == cell.inlines.isEmpty
                    && cell.text.filter { $0 == NoteDocument.objectCharacter }.count == cell.inlines.count
            } }
        }
        guard block.level == nil || (block.style == "heading" && block.level! > 0),
              block.indent == nil || ((0...2).contains(block.indent!) &&
                  (block.kind == .checklist || ["bullet", "number", "quote"].contains(block.style ?? ""))) else { return false }
        return validMarks(block.marks, in: block.text)
    }

    private static func validMarks(_ marks: [NoteMark], in text: String) -> Bool {
        // Ordinary paragraphs (and empty table cells) have no mark ranges
        // to validate. Avoid allocating their UTF-16 buffers on every save.
        guard !marks.isEmpty else { return true }
        let units = Array(text.utf16)
        return marks.allSatisfy { mark in
            mark.offset >= 0 && mark.length > 0 && mark.offset <= units.count &&
                mark.length <= units.count - mark.offset &&
                isScalarBoundary(mark.offset, in: units) &&
                isScalarBoundary(mark.offset + mark.length, in: units) &&
                !units[mark.offset..<(mark.offset + mark.length)].contains(NoteDocument.objectUnit) &&
                (mark.kind == .link) == (mark.url != nil)
        }
    }

    // MARK: Blocks

    static func decodeBlock(_ value: NoteJSON) -> NoteBlock {
        guard let object = value.objectValue, let kind = object["kind"]?.stringValue else {
            return .opaque(value)
        }
        var block: NoteBlock?
        switch kind {
        case "text":
            block = decodeTextual(object, kind: .text, known: ["kind", "text", "id", "style", "level", "indent", "marks", "inline"])
        case "checklist":
            block = decodeTextual(object, kind: .checklist, known: ["kind", "text", "id", "checked", "indent", "marks", "inline"])
        case "image":
            block = decodeImage(object)
        case "file":
            block = decodeFile(object)
        case "table":
            block = decodeTable(object)
        case "divider":
            guard let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { break }
            block = .divider(id: id)
            block?.extras = object.filter { !["kind", "id"].contains($0.key) }
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
            guard let value = style.stringValue,
                  ["body", "heading", "bullet", "number", "quote", "mono"].contains(value) else { return nil }
            block.style = value
        }
        if let rawLevel = object["level"] {
            guard kind == .text, block.style == "heading", let level = rawLevel.intValue, level > 0 else { return nil }
            block.level = level
        }
        if block.style == "heading" && block.level == nil { return nil }
        if let rawIndent = object["indent"] {
            guard kind == .checklist || ["bullet", "number", "quote"].contains(block.style ?? ""),
                  let indent = rawIndent.intValue, (0...2).contains(indent) else { return nil }
            block.indent = indent
        }
        if let rawMarks = object["marks"] {
            guard let values = rawMarks.arrayValue, let marks = decodeMarks(values, in: text) else { return nil }
            block.marks = marks
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

    private static func decodeMarks(_ values: [NoteJSON], in text: String) -> [NoteMark]? {
        let units = Array(text.utf16)
        var marks: [NoteMark] = []
        for value in values {
            guard let object = value.objectValue,
                  let name = object["kind"]?.stringValue,
                  let kind = NoteMark.Kind(rawValue: name),
                  let offset = object["offset"]?.intValue,
                  let length = object["length"]?.intValue,
                  offset >= 0, length > 0, offset <= units.count,
                  length <= units.count - offset,
                  isScalarBoundary(offset, in: units),
                  isScalarBoundary(offset + length, in: units),
                  !units[offset..<(offset + length)].contains(NoteDocument.objectUnit) else { return nil }
            let url = object["url"]?.stringValue
            guard (kind == .link) == (url != nil),
                  Set(object.keys).isSubset(of: ["kind", "offset", "length", "url"]),
                  !marks.contains(where: { $0.kind == kind && $0.offset < offset + length && offset < $0.offset + $0.length }) else { return nil }
            marks.append(NoteMark(kind, offset: offset, length: length, url: url))
        }
        return marks
    }

    private static func isScalarBoundary(_ offset: Int, in units: [UInt16]) -> Bool {
        guard offset > 0, offset < units.count else { return true }
        return !(0xD800...0xDBFF).contains(units[offset - 1]) ||
            !(0xDC00...0xDFFF).contains(units[offset])
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

    /// A table must be rectangular, within the limits, with a UUID for the
    /// table, every column and every row; a cell is text with marks and
    /// inline objects, as a text block. Anything else keeps the block opaque.
    private static func decodeTable(_ object: [String: NoteJSON]) -> NoteBlock? {
        func uuid(_ value: NoteJSON?) -> UUID? { value?.stringValue.flatMap(UUID.init(uuidString:)) }
        guard let id = uuid(object["id"]),
              let rawColumns = object["columns"]?.arrayValue, !rawColumns.isEmpty,
              let rawRows = object["rows"]?.arrayValue, !rawRows.isEmpty else { return nil }
        var headerRow = true
        if let raw = object["headerRow"] {
            guard let value = raw.boolValue else { return nil }
            headerRow = value
        }
        var columns: [NoteTable.Column] = []
        for raw in rawColumns {
            guard let column = raw.objectValue, let columnID = uuid(column["id"]) else { return nil }
            var width: Double?
            if let rawWidth = column["width"], rawWidth != .null {
                guard let value = rawWidth.numberValue, value.isFinite, value > 0 else { return nil }
                width = value
            }
            var align = NoteTable.Alignment.left
            if let rawAlign = column["align"] {
                guard let value = rawAlign.stringValue.flatMap(NoteTable.Alignment.init(rawValue:)) else { return nil }
                align = value
            }
            columns.append(NoteTable.Column(id: columnID, width: width, align: align,
                                            extras: column.filter { !["id", "width", "align"].contains($0.key) }))
        }
        var rows: [NoteTable.Row] = []
        for raw in rawRows {
            guard let row = raw.objectValue, let rowID = uuid(row["id"]),
                  let rawCells = row["cells"]?.arrayValue, rawCells.count == columns.count else { return nil }
            var cells: [NoteTable.Cell] = []
            for rawCell in rawCells {
                guard let cell = rawCell.objectValue, let text = cell["text"]?.stringValue else { return nil }
                var value = NoteTable.Cell(text)
                if let rawMarks = cell["marks"] {
                    guard let values = rawMarks.arrayValue, let marks = decodeMarks(values, in: text) else { return nil }
                    value.marks = marks
                }
                if let rawInlines = cell["inline"] {
                    guard let values = rawInlines.arrayValue, let inlines = decodeInlines(values, in: text),
                          inlines.allSatisfy({ if case .date = $0.kind { return true } else { return false } }) else { return nil }
                    value.inlines = inlines
                } else if text.contains(NoteDocument.objectCharacter) {
                    return nil
                }
                value.extras = cell.filter { !["text", "marks", "inline"].contains($0.key) }
                cells.append(value)
            }
            rows.append(NoteTable.Row(id: rowID, cells: cells, extras: row.filter { !["id", "cells"].contains($0.key) }))
        }
        let table = NoteTable(headerRow: headerRow, columns: columns, rows: rows,
                              extras: object.filter { !["kind", "id", "headerRow", "columns", "rows"].contains($0.key) })
        guard table.isWithinLimits else { return nil }
        return .table(table, id: id)
    }

    private static func decodeFile(_ object: [String: NoteJSON]) -> NoteBlock? {
        guard let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let name = object["name"]?.stringValue, !name.isEmpty,
              let type = object["contentType"]?.stringValue, !type.isEmpty,
              let byteCount = object["byteCount"]?.intValue, byteCount >= 0 else { return nil }
        let attachmentID: UUID?
        if let raw = object["attachmentID"] {
            guard let parsed = raw.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            attachmentID = parsed
        } else { attachmentID = nil }
        let failure = object["importFailure"]?.stringValue
        guard (attachmentID != nil) != (failure != nil),
              object["importFailure"] == nil || failure?.isEmpty == false else { return nil }
        var block = NoteBlock.file(id: id, attachmentID: attachmentID, filename: name,
                                   contentTypeIdentifier: type, byteCount: Int64(byteCount),
                                   importFailure: failure)
        block.extras = object.filter {
            !["kind", "id", "attachmentID", "name", "contentType", "byteCount", "importFailure"].contains($0.key)
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
            object["level"] = block.level.map { .int(Int64($0)) }
            object["indent"] = block.indent.map { .int(Int64($0)) }
            object["marks"] = block.marks.isEmpty ? nil : .array(block.marks.map { mark in
                var fields: [String: NoteJSON] = ["kind": .string(mark.kind.rawValue),
                                                  "offset": .int(Int64(mark.offset)),
                                                  "length": .int(Int64(mark.length))]
                fields["url"] = mark.url.map(NoteJSON.string)
                return .object(fields)
            })
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
        case .table:
            guard let table = block.table else { return .null }
            var object = table.extras
            object["kind"] = .string("table")
            object["id"] = block.id.map { .string($0.uuidString) }
            object["headerRow"] = .bool(table.headerRow)
            object["columns"] = .array(table.columns.map { column in
                var fields = column.extras
                fields["id"] = .string(column.id.uuidString)
                fields["width"] = column.width.map(NoteJSON.double)
                fields["align"] = .string(column.align.rawValue)
                return .object(fields)
            })
            object["rows"] = .array(table.rows.map { row in
                var fields = row.extras
                fields["id"] = .string(row.id.uuidString)
                fields["cells"] = .array(row.cells.map(encodeCell))
                return .object(fields)
            })
            return .object(object)
        case .divider:
            var object = block.extras
            object["kind"] = .string("divider")
            object["id"] = block.id.map { .string($0.uuidString) }
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
        case .file:
            var object = block.extras
            object["kind"] = .string("file")
            object["id"] = block.id.map { .string($0.uuidString) }
            object["attachmentID"] = block.attachmentID.map { .string($0.uuidString) }
            object["name"] = block.filename.map(NoteJSON.string)
            object["contentType"] = block.contentTypeIdentifier.map(NoteJSON.string)
            object["byteCount"] = block.byteCount.map(NoteJSON.int)
            object["importFailure"] = block.importFailure.map(NoteJSON.string)
            return .object(object)
        }
    }

    private static func encodeCell(_ cell: NoteTable.Cell) -> NoteJSON {
        var object = cell.extras
        object["text"] = .string(cell.text)
        object["marks"] = cell.marks.isEmpty ? nil : .array(cell.marks.map(encodeMark))
        if !cell.inlines.isEmpty {
            let units = Array(cell.text.utf16)
            let offsets = units.indices.filter { units[$0] == NoteDocument.objectUnit }
            object["inline"] = .array(zip(cell.inlines, offsets).map { inline, offset in encodeInline(inline, offset: offset) })
        }
        return .object(object)
    }

    private static func encodeMark(_ mark: NoteMark) -> NoteJSON {
        var fields: [String: NoteJSON] = ["kind": .string(mark.kind.rawValue),
                                          "offset": .int(Int64(mark.offset)),
                                          "length": .int(Int64(mark.length))]
        fields["url"] = mark.url.map(NoteJSON.string)
        return .object(fields)
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
