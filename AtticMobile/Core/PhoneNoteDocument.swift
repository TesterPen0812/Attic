import Foundation

/// A value snapshot of one native note. Only the transaction owner may install a changed
/// result, after comparing every live replica to the opening snapshot in that transaction.
struct PhoneNoteDocument {
    struct Snapshot: Equatable {
        var noteID: UUID
        var content: Data?
        var contentFormat: Int
        var contentFingerprint: String?
        var revision: Int64
        var revisionID: UUID?
        var taskID: UUID?
    }

    enum Edit {
        case text(block: Int, String)
        case checked(block: Int, Bool)
    }

    enum Save: Equatable {
        /// Do not invoke the content setter: it would populate a legacy nil fingerprint.
        case unchanged(Data?)
        case changed(Data)
    }

    enum Failure: Error, Equatable { case stale, readOnly, unsupportedEdit, revisionLimit }

    let source: Snapshot
    let blocks: [NoteBlock] // Display preview only. Never serialize it back to storage.
    let readOnlyReason: NoteReadOnlyReason?
    private let fields: [WireBlock]

    /// Admit format 1 and these semantics deliberately, even if a later shared codec admits more.
    private static let supportedRequirements: Set<String> = ["text", "checklist", "image", "date",
        "structure-v1", "inline-marks-v1", "file-v1", "table-v1"]

    init(_ source: Snapshot) {
        self.source = source
        let decoded = source.content.map { NoteContentCodec.decode($0) }
        blocks = decoded?.document?.blocks ?? []
        let reason: NoteReadOnlyReason?
        if source.contentFormat != 1 {
            reason = source.contentFormat > 1 ? .newerFormat(source.contentFormat) : .unsupportedContent
        } else if source.taskID != nil {
            reason = .requiresCapabilities(["taskNote"])
        } else {
            switch decoded {
            case let .editable(doc):
                let unknown = doc.requires.filter { !Self.supportedRequirements.contains($0) }
                if doc.format != 1 { reason = .newerFormat(doc.format) }
                else { reason = unknown.isEmpty ? nil : .requiresCapabilities(unknown) }
            case let .readOnly(_, why, _): reason = why
            case nil: reason = .unreadable("missing content")
            }
        }
        if reason == nil, let raw = source.content, let index = try? WireCursor.index(raw), index.count == blocks.count {
            fields = index
            readOnlyReason = nil
        } else {
            fields = []
            readOnlyReason = reason ?? .unsupportedContent
        }
    }

    func canEditText(at index: Int) -> Bool {
        guard readOnlyReason == nil, fields.indices.contains(index), fields[index].text != nil else { return false }
        let block = blocks[index]
        return (block.kind == .text || block.kind == .checklist) && block.marks.isEmpty && block.inlines.isEmpty
    }

    func canSetChecked(at index: Int) -> Bool {
        readOnlyReason == nil && fields.indices.contains(index) && blocks[index].kind == .checklist
    }

    /// Indices address the opening block order. Edits cannot insert, remove or reorder blocks.
    /// A batch is atomic; the last assignment to a field wins (including undo to its original value).
    func saving(_ edits: [Edit], against current: Snapshot) throws -> Save {
        guard current == source else { throw Failure.stale }
        guard !edits.isEmpty else { return .unchanged(source.content) }
        guard readOnlyReason == nil, let raw = source.content else { throw Failure.readOnly }
        var patches: [Range<Int>: Data] = [:]
        for edit in edits {
            switch edit {
            case let .text(index, text):
                guard canEditText(at: index), let range = fields[index].text else { throw Failure.unsupportedEdit }
                if blocks[index].text.utf8.elementsEqual(text.utf8) {
                    patches[range] = nil
                } else {
                    // The caller edits one paragraph. It cannot introduce an object or a paragraph boundary.
                    guard !text.unicodeScalars.contains(where: { $0.value == 0xFFFC || $0.value == 0x2029 ||
                        $0.value == 0x0A || $0.value == 0x0D }) else { throw Failure.unsupportedEdit }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .withoutEscapingSlashes
                    patches[range] = try encoder.encode(text)
                }
            case let .checked(index, value):
                guard canSetChecked(at: index) else { throw Failure.unsupportedEdit }
                let field = fields[index]
                let range = field.checked ?? (field.firstMember..<field.firstMember)
                if value == blocks[index].checked { patches[range] = nil }
                else if field.checked == nil { patches[range] = Data("\"checked\":true,".utf8) } // absent defaults to false
                else { patches[range] = Data((value ? "true" : "false").utf8) }
            }
        }
        guard !patches.isEmpty else { return .unchanged(raw) }
        guard source.revision < Int64.max else { throw Failure.revisionLimit }
        // Copy gaps from the original directly: preserve whitespace, UUID case, explicit defaults,
        // number precision, unknown fields and every byte of untouched blocks. No full re-encode.
        var result = Data(), cursor = raw.startIndex
        result.reserveCapacity(raw.count)
        for (range, replacement) in patches.sorted(by: { $0.key.lowerBound < $1.key.lowerBound }) {
            let start = raw.startIndex + range.lowerBound
            result.append(contentsOf: raw[cursor..<start]); result.append(replacement)
            cursor = raw.startIndex + range.upperBound
        }
        result.append(contentsOf: raw[cursor..<raw.endIndex])
        return .changed(result)
    }
}

extension PhoneNoteDocument.Snapshot {
    @MainActor init(_ row: NoteItem) {
        self.init(noteID: row.id, content: row.content, contentFormat: row.contentFormat,
                  contentFingerprint: row.contentFingerprint, revision: row.revision,
                  revisionID: row.revisionID, taskID: row.taskID)
    }
}

private struct WireBlock {
    let text: Range<Int>?
    let checked: Range<Int>?
    let firstMember: Int
}

/// The shared codec owns JSON validity and document semantics. This cursor only indexes byte
/// ranges of direct members in already-decoded UTF-8 JSON. Fail closed on ambiguous paths.
private struct WireCursor {
    private let bytes: [UInt8]
    private var i = 0
    private enum Invalid: Error { case structure }

    static func index(_ data: Data) throws -> [WireBlock] {
        var cursor = WireCursor(bytes: Array(data))
        let root = try cursor.members()
        cursor.space()
        guard cursor.i == cursor.bytes.count, let array = root["blocks"] else { throw Invalid.structure }
        cursor.i = array.lowerBound
        guard cursor.take(0x5B) else { throw Invalid.structure } // [
        var blocks: [WireBlock] = []
        if !cursor.take(0x5D) {
            repeat {
                cursor.space()
                let start = cursor.i
                let fields = try cursor.members()
                blocks.append(WireBlock(text: fields["text"], checked: fields["checked"], firstMember: start + 1))
            } while cursor.take(0x2C)
            guard cursor.take(0x5D) else { throw Invalid.structure }
        }
        guard cursor.i == array.upperBound else { throw Invalid.structure }
        return blocks
    }

    private mutating func space() {
        while i < bytes.count {
            switch bytes[i] { case 9, 10, 13, 32: i += 1; default: return }
        }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        space()
        guard i < bytes.count, bytes[i] == byte else { return false }
        i += 1
        return true
    }

    private mutating func members() throws -> [String: Range<Int>] {
        guard take(0x7B) else { throw Invalid.structure } // {
        var fields: [String: Range<Int>] = [:]
        if take(0x7D) { return fields }
        repeat {
            space()
            let start = i
            try skipString()
            let keyBytes = bytes[(start + 1)..<(i - 1)]
            let key: String
            if keyBytes.contains(0x5C) { key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<i])) }
            else { key = String(decoding: keyBytes, as: UTF8.self) }
            guard fields[key] == nil, take(0x3A) else { throw Invalid.structure } // :
            space()
            let valueStart = i
            try skipValue()
            fields[key] = valueStart..<i
        } while take(0x2C)
        guard take(0x7D) else { throw Invalid.structure }
        return fields
    }

    private mutating func skipString() throws {
        guard i < bytes.count, bytes[i] == 0x22 else { throw Invalid.structure }
        i += 1
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 0x22 { return }
            if b == 0x5C { i += 1 } // skip the escaped byte, including a quote or another backslash
        }
        throw Invalid.structure
    }

    private mutating func skipValue() throws {
        guard i < bytes.count else { throw Invalid.structure }
        switch bytes[i] {
        case 0x22: try skipString()
        case 0x7B, 0x5B:
            var depth = 0
            repeat {
                guard i < bytes.count else { throw Invalid.structure }
                switch bytes[i] {
                case 0x22: try skipString()
                case 0x7B, 0x5B: depth += 1; i += 1
                case 0x7D, 0x5D: depth -= 1; i += 1
                default: i += 1
                }
            } while depth > 0
        default:
            let start = i
            while i < bytes.count {
                switch bytes[i] {
                case 9, 10, 13, 32, 0x2C, 0x5D, 0x7D: break
                default: i += 1; continue
                }
                break
            }
            guard i > start else { throw Invalid.structure }
        }
    }
}
