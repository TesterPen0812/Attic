import Foundation

/// The stored note format, `attic.note/1`.
///
/// One JSON document per note: an ordered list of blocks that maps 1 : 1 to
/// the editor's paragraphs (split on "\n"). Block 0 is the title. Every
/// object (checklist line, image, inline date) carries a stable UUID; a
/// text paragraph may carry one (`id`, reserved for phase 6's paragraph
/// merge) but needs none.
///
/// ```jsonc
/// { "format": 1,
///   "requires": [],                       // capabilities an editor must know to edit
///   "blocks": [
///     { "kind": "text", "text": "Launch notes" },
///     { "kind": "text", "text": "Ship on \u{FFFC}.",
///       "inline": [{ "kind": "date", "id": "<uuid>", "offset": 8, "date": "2026-10-01" }] },
///     { "kind": "checklist", "id": "<uuid>", "text": "Buy cake", "checked": false },
///     { "kind": "image", "id": "<placement>", "attachmentID": "<NoteAttachment>", "width": 240 }
///   ] }
/// ```
///
/// Safety rules (requirement 1, critique finding 5):
/// - `format` greater than this build's, or a `requires` capability this
///   build does not know, makes the note **read-only**: the original bytes
///   are kept and written back unchanged (`NoteContent.readOnly`).
/// - A block this build cannot read (an unknown kind, a missing or
///   mistyped field such as a numeric `id`) is kept **opaquely**: its JSON is
///   written back verbatim and the editor shows it as one immovable object.
///   The same holds for an unknown inline object inside a text block.
/// - Unknown fields on the document, a block or an inline object are kept.
/// - A newer Attic that adds something an older editor could break by
///   editing around it must list it in `requires` (or raise `format`); a
///   self-contained addition may stay optional and is carried opaquely.
struct NoteDocument: Equatable, Sendable {
    static let currentFormat = 1
    /// What this build can edit. A document requiring anything else opens
    /// read-only.
    static let editableCapabilities: Set<String> = ["text", "checklist", "image", "date"]
    /// U+FFFC, the character an inline object occupies in a block's text.
    static let objectCharacter: Character = "\u{FFFC}"
    static let objectUnit: unichar = 0xFFFC

    var format: Int = NoteDocument.currentFormat
    var requires: [String] = []
    var blocks: [NoteBlock]
    /// Unknown document-level fields, written back as they were.
    var extras: [String: NoteJSON] = [:]

    init(blocks: [NoteBlock], requires: [String] = [], extras: [String: NoteJSON] = [:]) {
        self.blocks = blocks
        self.requires = requires
        self.extras = extras
    }

    /// A new note: an empty title.
    static var blank: NoteDocument { NoteDocument(blocks: [.text("")]) }

    /// The title is the first block's text when it is a text block; an
    /// object never forms the title.
    var title: String {
        guard let first = blocks.first, first.kind == .text else { return "" }
        return first.displayText
    }

    /// Every object's ID in document order (checklist lines, images, inline
    /// objects, opaque blocks that carried a readable `id`).
    var objectIDs: [UUID] {
        var ids: [UUID] = []
        for block in blocks {
            switch block.kind {
            case .checklist, .image:
                if let id = block.id { ids.append(id) }
            case .opaque:
                if let id = block.opaqueID { ids.append(id) }
            case .text:
                break
            }
            ids += block.inlines.map(\.id)
        }
        return ids
    }

    /// The NoteAttachment rows this document displays.
    var attachmentIDs: [UUID] {
        blocks.compactMap { $0.kind == .image ? $0.attachmentID : nil }
    }

    var isEmpty: Bool {
        blocks.allSatisfy { block in
            block.kind == .text && block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum NoteBlockKind: String, Sendable {
    case text
    case checklist
    case image
    /// A block this build cannot read; `NoteBlock.opaque` holds it verbatim.
    case opaque
}

struct NoteBlock: Equatable, Sendable {
    var kind: NoteBlockKind
    /// Required for checklist and image; optional paragraph identity on text.
    var id: UUID?
    /// Text and checklist: the line's text; U+FFFC marks each inline object.
    var text: String = ""
    /// Text blocks: a paragraph style (nil = body). Unknown values are kept
    /// and drawn as body.
    var style: String?
    var checked = false
    var attachmentID: UUID?
    var width: Double?
    /// Images: the pixel size, so layout reserves the space before any
    /// byte is read (optional; measured on import).
    var pixelWidth: Int?
    var pixelHeight: Int?
    var inlines: [NoteInline] = []
    /// Unknown fields on a readable block.
    var extras: [String: NoteJSON] = [:]
    /// The whole JSON value of an unreadable block.
    var opaque: NoteJSON?

    static func text(_ text: String, id: UUID? = nil, style: String? = nil) -> NoteBlock {
        NoteBlock(kind: .text, id: id, text: text, style: style)
    }

    static func checklist(_ text: String, id: UUID = UUID(), checked: Bool = false) -> NoteBlock {
        NoteBlock(kind: .checklist, id: id, text: text, checked: checked)
    }

    static func image(id: UUID = UUID(), attachmentID: UUID, width: Double? = nil,
                      pixelWidth: Int? = nil, pixelHeight: Int? = nil) -> NoteBlock {
        NoteBlock(kind: .image, id: id, attachmentID: attachmentID, width: width,
                  pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    static func opaque(_ value: NoteJSON) -> NoteBlock {
        NoteBlock(kind: .opaque, opaque: value)
    }

    /// An opaque block's `id`, when it is a readable UUID string.
    var opaqueID: UUID? {
        opaque?.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The text with each inline object replaced by its readable form.
    var displayText: String {
        guard !inlines.isEmpty else { return text }
        var result = ""
        var index = 0
        for character in text {
            if character == NoteDocument.objectCharacter, index < inlines.count {
                result += inlines[index].displayText
                index += 1
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// An object inside a line of text (today: a date).
struct NoteInline: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case date(NoteDay)
        /// An inline object this build cannot read, kept verbatim.
        case opaque(NoteJSON)
    }

    var id: UUID
    var kind: Kind
    var extras: [String: NoteJSON] = [:]

    var displayText: String {
        switch kind {
        case let .date(day): day.isoString
        case .opaque: "[…]"
        }
    }
}

/// A calendar day with no time or time zone, stored as ISO `yyyy-MM-dd`.
struct NoteDay: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        guard (1...9999).contains(year), components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        // A Date always has a valid day in the given calendar.
        self.year = components.year ?? 2000
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    static func < (lhs: NoteDay, rhs: NoteDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
