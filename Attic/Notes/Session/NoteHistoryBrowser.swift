import AppKit
import Combine

/// Value snapshots keep the browser independent of SwiftData rollback.
struct NoteHistoryEntry: Identifiable {
    let id: UUID
    let createdAt: Date
    let reason: NoteVersionReason?
    let document: NoteDocument
    let canRestore: Bool

    @MainActor init(_ version: NoteVersion) {
        id = version.id
        createdAt = version.createdAt
        reason = version.reason
        if let data = version.content {
            let decoded = NoteContentCodec.decode(data)
            document = decoded.document ?? NoteDocument(blocks: [.text(version.title), .text("This version’s content cannot be read by this Attic.")])
            canRestore = version.contentFormat == NoteDocument.currentFormat && decoded.isEditable
        } else {
            document = NoteDocument(blocks: [.text(version.title)] + version.body.components(separatedBy: "\n").map { .text($0) })
            canRestore = version.contentFormat == 0
        }
    }
}

extension NoteVersionReason {
    var historyLabel: String {
        switch self {
        case .pause: "Pause"
        case .leave: "On leaving"
        case .beforeAgentEdit: "Before agent edit"
        case .beforeRestore: "Before restore"
        case .beforeMigration: "Before migration"
        case .beforeWritingTools: "Before Writing Tools"
        case .replacedByDraft: "Before recovered draft"
        }
    }
}

/// Compare structure as well as prose. Missing content is named at its
/// original position, including images and every table cell. The annotated
/// document is only a preview; Copy and Restore always use original bytes.
struct NoteHistoryComparison {
    let document: NoteDocument
    let changedBlocks: Set<Int>
    let missing: [NoteBlock]
    let differingCount: Int

    init(shown: NoteDocument, other: NoteDocument, missingLabel: String) {
        // Match visible content first; a changed style or object geometry
        // gets a bar, without falsely saying its existing text is missing.
        let difference = other.blocks.map(Self.visibleKey).difference(from: shown.blocks.map(Self.visibleKey))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        missing = inserted.sorted().map { other.blocks[$0] }
        var formattingChanges = 0
        var blocks: [NoteBlock] = [], marked = Set<Int>()
        var left = 0, right = 0
        while left < shown.blocks.count || right < other.blocks.count {
            let removes = left < shown.blocks.count && removed.contains(left)
            let inserts = right < other.blocks.count && inserted.contains(right)
            if removes || inserts {
                if removes {
                    marked.insert(blocks.count)
                    blocks.append(shown.blocks[left])
                    left += 1
                }
                if inserts {
                    marked.insert(blocks.count)
                    let description = Self.description(other.blocks[right]).replacingOccurrences(of: "\n", with: " · ")
                    blocks.append(.text("\(missingLabel): “\(description)”"))
                    right += 1
                }
            } else if left < shown.blocks.count {
                if right < other.blocks.count, shown.blocks[left] != other.blocks[right] {
                    marked.insert(blocks.count)
                    formattingChanges += 1
                }
                blocks.append(shown.blocks[left])
                left += 1
                if right < other.blocks.count { right += 1 }
            } else { break }
        }
        var result = shown
        result.blocks = blocks
        document = result
        changedBlocks = marked
        differingCount = max(removed.count, inserted.count) + formattingChanges
    }

    private static func visibleKey(_ block: NoteBlock) -> String {
        let content: String
        switch block.kind {
        case .image: content = block.attachmentID?.uuidString ?? "Image"
        case .file: content = block.attachmentID?.uuidString ?? block.filename ?? "File"
        case .table: content = block.table.map { NoteTableText.markdown($0) } ?? "Table"
        default: content = block.displayText
        }
        return "\(block.kind.rawValue):\(content)"
    }

    private static func description(_ block: NoteBlock) -> String {
        switch block.kind {
        case .image: "Image"
        case .file: block.filename ?? "File"
        case .table: block.table.map { NoteTableText.markdown($0) } ?? "Table"
        case .divider: "Divider"
        default: block.displayText
        }
    }
}

@MainActor
final class NoteHistoryBrowser: ObservableObject {
    let noteID: UUID
    let current: NoteDocument
    let currentRevision: UUID?
    let entries: [NoteHistoryEntry]
    @Published var selectedIndex = 0
    @Published var showsCurrent = false
    @Published var failure: String?
    @Published var isRestoring = false
    @Published var preview: NoteSession?
    @Published private(set) var comparison: NoteHistoryComparison
    var scrollOffset: CGFloat = 0

    init(noteID: UUID, current: NoteDocument, currentRevision: UUID?, entries: [NoteHistoryEntry]) {
        self.noteID = noteID
        self.current = current
        self.currentRevision = currentRevision
        self.entries = entries
        comparison = NoteHistoryComparison(shown: entries.first?.document ?? current, other: current,
                                            missingLabel: "Not in this version")
    }

    var selected: NoteHistoryEntry? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }
    func updateComparison() {
        let version = selected?.document ?? current
        comparison = NoteHistoryComparison(shown: showsCurrent ? current : version,
            other: showsCurrent ? version : current,
            missingLabel: showsCurrent ? "Not in Current" : "Not in this version")
    }
}
