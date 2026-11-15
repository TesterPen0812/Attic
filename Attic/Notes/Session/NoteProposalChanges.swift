import Foundation

/// One change an agent's proposal makes (N5, Idea B): a run of the note's
/// blocks (`removed`, indices in the current note) that the proposal
/// replaces with its own (`added`, indices in the proposal). Either side
/// may be empty: a pure insertion or a pure removal.
struct NoteProposalChange: Identifiable, Equatable, Sendable {
    let id: Int
    let removed: Range<Int>
    let added: Range<Int>
}

/// How the review shows one block: part of a change, removed or added.
enum NoteProposalMark: Equatable, Sendable {
    case added(Int)
    case removed(Int)
}

/// The note as the review shows it: decided changes read as they will be
/// saved, undecided ones show their removed blocks (struck through) above
/// their added ones, each marked.
struct NoteProposalDisplay: Equatable {
    var document: NoteDocument
    /// One per display block.
    var marks: [NoteProposalMark?]
    /// Display block index → the change whose Accept and Reject sit on it
    /// (each undecided change's last block).
    var controls: [Int: Int]
}

/// The block-level comparison of a note with an agent's proposal. Pure
/// value: the review's decisions live with the controller, and the note is
/// written only through `merged(accepting:)`, in one transaction.
struct NoteProposalChangeSet: Equatable, Sendable {
    let current: NoteDocument
    let proposed: NoteDocument
    let changes: [NoteProposalChange]

    /// Above this many compared pairs the middle of the note is one change
    /// (the comparison stays bounded for very long notes).
    static let comparisonBudget = 250_000

    init(current: NoteDocument, proposed: NoteDocument) {
        self.current = current
        self.proposed = proposed
        changes = Self.compare(current.blocks.map(Self.comparable), proposed.blocks.map(Self.comparable))
    }

    /// The note built from the current text and the accepted changes only.
    func merged(accepting accepted: Set<Int>) -> NoteDocument {
        var blocks: [NoteBlock] = []
        var cursor = 0
        for change in changes {
            blocks += current.blocks[cursor..<change.removed.lowerBound]
            blocks += accepted.contains(change.id) ? proposed.blocks[change.added] : current.blocks[change.removed]
            cursor = change.removed.upperBound
        }
        blocks += current.blocks[cursor...]
        var document = current
        document.blocks = blocks.isEmpty ? [.text("")] : blocks
        document.refreshRequiredCapabilities()
        return document
    }

    /// What the review shows for `decisions` (change id → accepted).
    func display(decisions: [Int: Bool]) -> NoteProposalDisplay {
        var blocks: [NoteBlock] = []
        var marks: [NoteProposalMark?] = []
        var controls: [Int: Int] = [:]
        var cursor = 0
        func keep(_ slice: ArraySlice<NoteBlock>) {
            blocks += slice
            marks += Array(repeating: nil, count: slice.count)
        }
        for change in changes {
            keep(current.blocks[cursor..<change.removed.lowerBound])
            cursor = change.removed.upperBound
            switch decisions[change.id] {
            case true?: keep(proposed.blocks[change.added])
            case false?: keep(current.blocks[change.removed])
            case nil:
                for block in current.blocks[change.removed] {
                    blocks.append(Self.struck(block))
                    marks.append(.removed(change.id))
                }
                for block in proposed.blocks[change.added] {
                    blocks.append(block)
                    marks.append(.added(change.id))
                }
                if !blocks.isEmpty { controls[blocks.count - 1] = change.id }
            }
        }
        keep(current.blocks[cursor...])
        var document = current
        if blocks.isEmpty {
            blocks = [.text("")]
            marks = [nil]
        }
        document.blocks = blocks
        document.refreshRequiredCapabilities()
        return NoteProposalDisplay(document: document, marks: marks, controls: controls)
    }

    /// A change's identity across a refreshed comparison: the blocks it
    /// removes and adds (positions and ids aside).
    struct Key: Hashable {
        let removed: [String]
        let added: [String]
    }

    func key(for change: NoteProposalChange) -> Key {
        Key(removed: current.blocks[change.removed].map(Self.fingerprint),
            added: proposed.blocks[change.added].map(Self.fingerprint))
    }

    /// Neighbouring blocks anchor a repeated replacement without making its
    /// display index an identity. An ambiguous context must not inherit a
    /// different occurrence's choice when a comparison is refreshed.
    struct Context: Hashable {
        let previousCurrent: String?
        let nextCurrent: String?
        let previousProposed: String?
        let nextProposed: String?
    }

    func context(for change: NoteProposalChange) -> Context {
        func previous(_ blocks: [NoteBlock], _ range: Range<Int>) -> String? {
            range.lowerBound > 0 ? Self.fingerprint(blocks[range.lowerBound - 1]) : nil
        }
        func next(_ blocks: [NoteBlock], _ range: Range<Int>) -> String? {
            range.upperBound < blocks.count ? Self.fingerprint(blocks[range.upperBound]) : nil
        }
        return Context(previousCurrent: previous(current.blocks, change.removed),
                       nextCurrent: next(current.blocks, change.removed),
                       previousProposed: previous(proposed.blocks, change.added),
                       nextProposed: next(proposed.blocks, change.added))
    }

    // MARK: Comparison

    /// Blocks match on what they hold, not their object ids (an agent may
    /// write the same block back under a new id).
    private static func comparable(_ block: NoteBlock) -> NoteBlock {
        var copy = block
        copy.id = nil
        return copy
    }

    private static func fingerprint(_ block: NoteBlock) -> String {
        String(describing: comparable(block))
    }

    /// The removed copy shown above its replacement: struck through, and
    /// under a fresh object id so one engine never holds an id twice.
    private static func struck(_ block: NoteBlock) -> NoteBlock {
        var copy = block
        if copy.id != nil { copy.id = UUID() }
        if copy.kind == .text || copy.kind == .checklist, !copy.text.isEmpty,
           !copy.marks.contains(where: { $0.kind == .strikethrough && $0.offset == 0 && $0.length >= copy.text.utf16.count }) {
            copy.marks.append(NoteMark(.strikethrough, offset: 0, length: copy.text.utf16.count))
        }
        return copy
    }

    private static func compare(_ a: [NoteBlock], _ b: [NoteBlock]) -> [NoteProposalChange] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let aEnd = a.count - suffix, bEnd = b.count - suffix
        let n = aEnd - prefix, m = bEnd - prefix
        // Matched pairs inside the middle, in order.
        var matches: [(Int, Int)] = []
        if n > 0, m > 0, n * m <= comparisonBudget {
            // lengths[i][j]: the longest common run of a[prefix+i...] and b[prefix+j...].
            let width = m + 1
            var lengths = [Int32](repeating: 0, count: (n + 1) * width)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i * width + j] = a[prefix + i] == b[prefix + j]
                        ? lengths[(i + 1) * width + j + 1] + 1
                        : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if a[prefix + i] == b[prefix + j] {
                    matches.append((prefix + i, prefix + j))
                    i += 1; j += 1
                } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        var changes: [NoteProposalChange] = []
        func emit(_ removed: Range<Int>, _ added: Range<Int>) {
            guard !removed.isEmpty || !added.isEmpty else { return }
            // Block-for-block rewrites are a change each, so each can be
            // accepted or rejected on its own.
            if removed.count == added.count, removed.count > 1 {
                for offset in 0..<removed.count {
                    changes.append(NoteProposalChange(id: changes.count,
                        removed: (removed.lowerBound + offset)..<(removed.lowerBound + offset + 1),
                        added: (added.lowerBound + offset)..<(added.lowerBound + offset + 1)))
                }
            } else {
                changes.append(NoteProposalChange(id: changes.count, removed: removed, added: added))
            }
        }
        var ai = prefix, bi = prefix
        for (am, bm) in matches {
            emit(ai..<am, bi..<bm)
            ai = am + 1; bi = bm + 1
        }
        emit(ai..<aEnd, bi..<bEnd)
        return changes
    }
}

/// The review's decisions (change id → accepted), with their own Undo and
/// Redo. In memory only: nothing is written until every change is decided.
struct NoteProposalDecisions: Equatable {
    private(set) var accepted: [Int: Bool] = [:]
    private var undoSteps: [[Int: Bool]] = []
    private var redoSteps: [[Int: Bool]] = []

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    mutating func decide(_ ids: [Int], accept: Bool) {
        let fresh = ids.filter { accepted[$0] == nil }
        guard !fresh.isEmpty else { return }
        undoSteps.append(accepted)
        redoSteps = []
        fresh.forEach { accepted[$0] = accept }
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoSteps.popLast() else { return false }
        redoSteps.append(accepted)
        accepted = previous
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoSteps.popLast() else { return false }
        undoSteps.append(accepted)
        accepted = next
        return true
    }

    /// The step a failed write could not keep: gone, with no Redo.
    mutating func dropLast() {
        guard let previous = undoSteps.popLast() else { return }
        accepted = previous
        redoSteps = []
    }

    /// Carries decisions over to a refreshed comparison: a change keeps its
    /// decision when it still removes and adds the same blocks.
    func carried(from old: NoteProposalChangeSet, to new: NoteProposalChangeSet) -> NoteProposalDecisions {
        var result = NoteProposalDecisions()
        let oldGroups = Dictionary(grouping: old.changes, by: { old.key(for: $0) })
        let newGroups = Dictionary(grouping: new.changes, by: { new.key(for: $0) })
        for (key, refreshed) in newGroups {
            guard let original = oldGroups[key] else { continue }
            if original.count == 1, refreshed.count == 1 {
                result.accepted[refreshed[0].id] = accepted[original[0].id]
                continue
            }
            let oldContexts = Dictionary(grouping: original, by: { old.context(for: $0) })
            let newContexts = Dictionary(grouping: refreshed, by: { new.context(for: $0) })
            for (context, matches) in newContexts where matches.count == 1 {
                guard let previous = oldContexts[context], previous.count == 1,
                      let choice = accepted[previous[0].id] else { continue }
                result.accepted[matches[0].id] = choice
            }
        }
        return result
    }
}
