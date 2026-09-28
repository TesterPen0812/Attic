import Foundation

/// A legacy note as Attic shows it today: title, plain body and attachment
/// rows with their inline anchors (the migration's input, read once).
struct LegacyNoteSnapshot: Equatable, Sendable {
    struct Attachment: Equatable, Sendable {
        let id: UUID
        let inlineOffset: Int?
        let sortIndex: Int64
        let createdAt: Date
        let isImage: Bool
        /// Actual payload, not only the stored digest (which may be stale).
        var payload: Data? = nil
    }

    let noteID: UUID
    let title: String
    let body: String
    /// Shown attachments only (not in Recently Deleted).
    let attachments: [Attachment]
    /// The revision the plan is made from; commit refuses if it moved.
    let revisionToken: String
}

/// Why a note stays on the legacy format. Every refusal has a reason a
/// person can read; nothing is converted on a guess.
enum LegacyMigrationRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateAttachmentIDs
    case titleHasLineBreak
    case bodyContainsObjectCharacter
    case fileAttachment(UUID)
    case replicasDisagree
    case projectionMismatch(String)
    case roundTripMismatch(String)
    case changedSincePlanned
    case alreadyMigrated
    case saveFailed(String)

    var description: String {
        switch self {
        case .duplicateAttachmentIDs: "Two attachments share an id, so which is which can't be kept."
        case .titleHasLineBreak: "The title has a line break."
        case .bodyContainsObjectCharacter: "The text contains an object-replacement character (U+FFFC)."
        case let .fileAttachment(id): "Attachment \(id.uuidString) is a file; files join the new editor in a later slice."
        case .replicasDisagree: "Copies of this note disagree."
        case let .projectionMismatch(detail): "The converted note would not show the same thing: \(detail)."
        case let .roundTripMismatch(detail): "The text system did not give the note back unchanged: \(detail)."
        case .changedSincePlanned: "The note changed after it was checked."
        case .alreadyMigrated: "The note is already in the new format."
        case let .saveFailed(message): "The converted note could not be saved: \(message)"
        }
    }
}

/// The migration gate (requirement 2, critique finding 4).
///
/// Two explicit steps:
/// 1. **Projection** (`plan`): today's display rules become blocks. An
///    attachment sits above the paragraph containing its anchor; an anchor
///    at or past the end of the body, or none, is today's tray, which the
///    new format places at the end of the note in tray order (the declared
///    tray-to-trailing-block transformation). Line endings are normalised
///    to LF with an offset map.
/// 2. **Verification** (`verify`): the inverse projection must rebuild the
///    title, the normalised body and every attachment's identity, order and
///    displayed placement (tray items verified as tray via the rows' kept
///    anchors), and the document must survive a TextKit 2 round trip
///    unchanged. The round trip is not optional: only `verify` makes a
///    `VerifiedLegacyMigration`, and only that can be committed. A dry run
///    (`plan` alone) can report but never commit.
enum LegacyNoteMigration {
    struct Plan: Equatable, Sendable {
        let snapshot: LegacyNoteSnapshot
        let document: NoteDocument
        let normalizedBody: String
        /// How many CR, CRLF or U+2029 breaks became LF.
        let normalizedLineBreaks: Int
        /// Attachments whose anchor was mid-paragraph (shown at its start today).
        let snappedAnchors: Int
    }

    static func plan(_ snapshot: LegacyNoteSnapshot) -> Result<Plan, LegacyMigrationRefusal> {
        let ids = snapshot.attachments.map(\.id)
        guard Set(ids).count == ids.count else { return .failure(.duplicateAttachmentIDs) }
        guard !snapshot.title.contains(where: \.isNewline) else { return .failure(.titleHasLineBreak) }
        if let file = snapshot.attachments.first(where: { !$0.isImage }) { return .failure(.fileAttachment(file.id)) }
        guard !snapshot.body.contains(NoteDocument.objectCharacter),
              !snapshot.title.contains(NoteDocument.objectCharacter) else {
            return .failure(.bodyContainsObjectCharacter)
        }

        let (body, map, breaks) = normalizeLineBreaks(snapshot.body)
        let length = (body as NSString).length
        let ordered = displayOrder(snapshot.attachments)
        var inline: [Int: [LegacyNoteSnapshot.Attachment]] = [:]
        var tray: [LegacyNoteSnapshot.Attachment] = []
        var snapped = 0
        let paragraphs = paragraphStarts(body)
        for attachment in ordered {
            guard let offset = attachment.inlineOffset else { tray.append(attachment); continue }
            let mapped = map(offset)
            guard mapped < length else { tray.append(attachment); continue }
            let start = NoteInlineAnchor.paragraphStart(mapped, in: body)
            if start != mapped { snapped += 1 }
            guard let index = paragraphs.firstIndex(of: start) else {
                return .failure(.projectionMismatch("an anchor has no paragraph"))
            }
            inline[index, default: []].append(attachment)
        }

        var blocks: [NoteBlock] = [.text(snapshot.title)]
        let lines = body.isEmpty ? [] : body.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            for attachment in inline[index] ?? [] {
                blocks.append(.image(id: attachment.id, attachmentID: attachment.id))
            }
            blocks.append(.text(line))
        }
        for attachment in tray {
            blocks.append(.image(id: attachment.id, attachmentID: attachment.id))
        }
        return .success(Plan(
            snapshot: snapshot,
            document: NoteDocument(blocks: blocks),
            normalizedBody: body,
            normalizedLineBreaks: breaks,
            snappedAnchors: snapped
        ))
    }

    /// Verifies a plan. `roundTrip` must put the document through the real
    /// text system and read it back (`NoteTextKitRoundTrip.document(afterRoundTrip:)`).
    static func verify(
        _ plan: Plan,
        roundTrip: (NoteDocument) -> NoteDocument
    ) -> Result<VerifiedLegacyMigration, LegacyMigrationRefusal> {
        if let mismatch = inverseMismatch(plan) { return .failure(.projectionMismatch(mismatch)) }
        let returned = roundTrip(plan.document)
        guard returned == plan.document else {
            return .failure(.roundTripMismatch(firstDifference(plan.document, returned)))
        }
        return .success(VerifiedLegacyMigration(plan: plan))
    }

    // MARK: Inverse projection

    private static func inverseMismatch(_ plan: Plan) -> String? {
        let document = plan.document
        guard let first = document.blocks.first, first.kind == .text, first.text == plan.snapshot.title else {
            return "title"
        }
        var lines: [String] = []
        var pending: [UUID] = []
        var placement: [UUID: Int] = [:]   // attachment → paragraph index it sits above
        var order: [UUID] = []
        for block in document.blocks.dropFirst() {
            switch block.kind {
            case .text:
                for id in pending { placement[id] = lines.count }
                pending.removeAll()
                lines.append(block.text)
            case .image:
                guard let id = block.attachmentID else { return "an image without an attachment" }
                pending.append(id)
                order.append(id)
            case .checklist, .divider, .opaque:
                return "an unexpected block"
            }
        }
        let rebuiltBody = lines.joined(separator: "\n")
        guard NoteTextReplacement.utf16Equal(rebuiltBody, plan.normalizedBody) else { return "body text" }
        let rebuiltStarts = paragraphStarts(rebuiltBody)
        let (_, map, _) = normalizeLineBreaks(plan.snapshot.body)
        let length = (plan.normalizedBody as NSString).length
        let expected = displayOrder(plan.snapshot.attachments)
        guard Set(order) == Set(expected.map(\.id)), order.count == expected.count else { return "attachment identity" }
        // Order: inline items by paragraph, then tray items, each in display order.
        for attachment in expected {
            let isTray = attachment.inlineOffset.map { map($0) >= length } ?? true
            if isTray {
                guard placement[attachment.id] == nil else { return "a tray attachment placed inline" }
            } else {
                guard let paragraph = placement[attachment.id], rebuiltStarts.indices.contains(paragraph) else {
                    return "an inline attachment moved to the end"
                }
                let shown = NoteInlineAnchor.paragraphStart(map(attachment.inlineOffset ?? 0), in: plan.normalizedBody)
                guard rebuiltStarts[paragraph] == shown else { return "attachment placement" }
            }
        }
        let inlineOrder = order.filter { placement[$0] != nil }
        let expectedInline = expected.filter { placement[$0.id] != nil }
            .sorted { (placement[$0.id] ?? 0) < (placement[$1.id] ?? 0) }.map(\.id)
        guard inlineOrder == expectedInline else { return "attachment order" }
        return nil
    }

    // MARK: Helpers

    /// Today's order: sortIndex, then createdAt, then id.
    static func displayOrder(_ attachments: [LegacyNoteSnapshot.Attachment]) -> [LegacyNoteSnapshot.Attachment] {
        attachments.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// CR, CRLF, U+2028 and U+2029 become LF; `map` sends an old UTF-16
    /// offset to its new one.
    static func normalizeLineBreaks(_ text: String) -> (String, (Int) -> Int, Int) {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var newOffsets = [Int](repeating: 0, count: units.count + 1)
        var breaks = 0
        var index = 0
        while index < units.count {
            newOffsets[index] = output.count
            let unit = units[index]
            if unit == 0x0D {
                output.append(0x0A)
                breaks += 1
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    newOffsets[index + 1] = output.count - 1
                    index += 2
                    continue
                }
            } else if unit == 0x2029 || unit == 0x2028 {
                output.append(0x0A)
                breaks += 1
            } else {
                output.append(unit)
            }
            index += 1
        }
        newOffsets[units.count] = output.count
        let normalized = String(utf16CodeUnits: output, count: output.count)
        let map: (Int) -> Int = { offset in newOffsets[min(max(0, offset), units.count)] }
        return (normalized, map, breaks)
    }

    static func paragraphStarts(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        return starts
    }

    private static func firstDifference(_ lhs: NoteDocument, _ rhs: NoteDocument) -> String {
        guard lhs.blocks.count == rhs.blocks.count else { return "\(lhs.blocks.count) blocks became \(rhs.blocks.count)" }
        for (index, pair) in zip(lhs.blocks, rhs.blocks).enumerated() where pair.0 != pair.1 {
            return "block \(index)"
        }
        return "document fields"
    }
}

/// A migration that passed the projection check and the TextKit round trip.
/// It can only be made by `LegacyNoteMigration.verify`.
struct VerifiedLegacyMigration: Equatable, Sendable {
    let plan: LegacyNoteMigration.Plan
    fileprivate init(plan: LegacyNoteMigration.Plan) { self.plan = plan }
}
