import AppKit

/// Editor-owned text undo for one note (requirement 4).
///
/// Why not NSTextView's undo: its recorded steps are private objects with
/// fixed ranges, so an edit made from outside the history (an agent's change
/// applied into an open note, a Writing Tools recovery) makes a later undo
/// change the wrong characters (proven in the technical test). This history
/// records every change as a swap of attributed text at a range, so it can
/// rebase steps through outside edits, drop a Writing Tools session's steps,
/// and never needs an `NSUndoManager`.
///
/// Recording: every user change reaches `willChange` (the text view's
/// multi-range delegate) and `didChange` (text did change). A change that
/// reaches the storage without the delegate (marked text: NSTextView sends
/// neither for composition updates) arrives in `captureUnrecorded` from
/// `processEditing`. A composition that starts by replacing selected text
/// is announced by the text view first (`beginComposition`), so the
/// replaced text is known (technical-test re-review finding D).
///
/// Coalescing follows NSTextView: consecutive typing, deleting and
/// composition inside or at the edge of the open step join it; a caret jump,
/// a paste, an object action or an undo ends it. Steps of one group (a drag
/// move) undo together.
@MainActor
final class NoteUndoHistory {
    struct ParagraphState: Equatable {
        var style: NoteParagraphStyle
        var indent: Int
        var block: NoteBlock? = nil
    }
    final class Op {
        fileprivate(set) var range: NSRange
        fileprivate var current: NSAttributedString
        fileprivate var other: NSAttributedString
        fileprivate(set) var name: String
        fileprivate(set) var isInert = false
        fileprivate let group: Int
        fileprivate var selectionBefore: NSRange?
        fileprivate var selectionAfter: NSRange?
        /// The title shorthand this step made: `adds` says what flipping the
        /// step does next time; `changesTags` is false when the note already
        /// had the tag (the step then only moves text, but its Undo still
        /// leaves the hashtag literal). The tag is a delta, so tags changed
        /// elsewhere since are never overwritten.
        fileprivate(set) var tagDelta: (tag: String, adds: Bool, changesTags: Bool)?
        fileprivate var tagPickerDelta: (adds: [String], removes: [String])?
        fileprivate var paragraphStyleSnapshot: (location: Int, before: ParagraphState, after: ParagraphState)?
        fileprivate var emptyParagraphSnapshot: (before: NoteBlock?, after: NoteBlock?)?
        fileprivate var typingMarkSnapshot: (kind: NoteMark.Kind, before: Bool, after: Bool)?
        /// Delimiter conversion restores the unmarked closing boundary on
        /// either replay, even when the caret sits just after marked text.
        fileprivate var boundaryTypingMarks: [NoteMark.Kind: Any]?
        /// A table's grid before and after (by the table's id, so it never
        /// depends on where the table sits in the text), and the cell and
        /// selection each side returns to. `cell` is the cell whose typing
        /// this step coalesces.
        fileprivate var tableSnapshot: TableSnapshot?
        fileprivate var externalChange: (undo: () -> Bool, redo: () -> Bool, undoNext: Bool)?

        /// Steps that change something other than characters at a range.
        fileprivate var isSnapshot: Bool {
            externalChange != nil || tagPickerDelta != nil || paragraphStyleSnapshot != nil || typingMarkSnapshot != nil || tableSnapshot != nil
        }

        fileprivate init(range: NSRange, current: NSAttributedString, other: NSAttributedString, name: String, group: Int) {
            self.range = range
            self.current = NSMutableAttributedString(attributedString: current)
            self.other = other
            self.name = name
            self.group = group
        }

        /// The text this step would restore (tests).
        var restores: String { other.string }
    }

    struct TableSnapshot {
        var id: UUID
        var before: NoteTable
        var after: NoteTable
        var focusBefore: NoteTableFocus?
        var focusAfter: NoteTableFocus?
        var cell: NoteTable.Position?
    }

    private struct Pending {
        var range: NSRange
        var old: NSAttributedString
        var newRange: NSRange
        var coalesceInto: Op?
        var pre: NSAttributedString?
        var post: NSAttributedString?
        var emptyParagraphBefore: NoteBlock? = nil
        var selectionBefore: NSRange? = nil
    }

    let storage: NSTextStorage
    /// Replays through the text view when one is attached, so its delegate,
    /// selection and layout see the change; nil edits the storage directly.
    weak var textView: NSTextView?
    /// A refused Writing Tools session freezes all history operations.
    var canReplay: (() -> Bool)?
    var onReplay: ((NSRange) -> Void)?
    /// A step carrying a tag delta was flipped: add (true) or remove the tag.
    /// The range is the step's text after the flip.
    var onTagFlip: ((_ tag: String, _ add: Bool, _ changesTags: Bool, _ range: NSRange) -> Void)?
    var onTagPickerDelta: ((_ adds: [String], _ removes: [String]) -> Void)?
    var onParagraphStyleSnapshot: ((Int, ParagraphState) -> Void)?
    var emptyParagraphState: (() -> NoteBlock?)?
    var onEmptyParagraphSnapshot: ((NoteBlock?) -> Void)?
    var onTypingMarkSnapshot: ((NoteMark.Kind, Bool) -> Void)?
    var onBoundaryTypingMarksSnapshot: (([NoteMark.Kind: Any]) -> Void)?
    /// Puts a table's grid back (Undo or Redo); false when the table is no
    /// longer in the note (the step is then skipped).
    var onTableSnapshot: ((UUID, NoteTable, NoteTableFocus?) -> Bool)?

    var outsideEditBarrier: String?
    var onOutsideEditBarrier: ((String) -> Void)?

    private(set) var undoOps: [Op] = []
    private(set) var redoOps: [Op] = []
    private(set) var log: [String] = []
    private(set) var isReplaying = false
    private(set) var isTraversing = false
    private var open: Op?
    private var pending: [Pending] = []
    private var selectionCompletion: Op?
    private(set) var recordingGeneration = 0
    private var expectedLength = 0
    private var nextGroup = 0
    private var groupDepth = 0
    private var groupID: Int?
    private var composition: (range: NSRange, old: NSAttributedString, selection: NSRange?)?
    let limit: Int

    init(storage: NSTextStorage, limit: Int = 500) {
        self.storage = storage
        self.limit = limit
    }

    var canUndo: Bool { !undoOps.isEmpty && (canReplay?() ?? true) }
    var canRedo: Bool { !redoOps.isEmpty && (canReplay?() ?? true) }
    var undoActionName: String { undoOps.last?.name ?? "" }
    var redoActionName: String { redoOps.first?.name ?? "" }
    var isChangeInFlight: Bool { !pending.isEmpty }
    var openStep: Op? { open }

    /// Bytes reachable by either side of Undo/Redo remain live until the
    /// history step is discarded. This is queried for purge, never per key.
    var referencedAttachmentIDs: Set<UUID> {
        var ids = Set<UUID>()
        for op in undoOps + redoOps {
            for text in [op.current, op.other] {
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let image = value as? NoteImageAttachment { ids.insert(image.attachmentID) }
                    if let file = value as? NoteFileAttachment, let id = file.attachmentID { ids.insert(id) }
                }
            }
        }
        return ids
    }

    func reset() {
        undoOps.removeAll()
        redoOps.removeAll()
        open = nil
        pending.removeAll()
        selectionCompletion = nil
        composition = nil
    }

    func breakCoalescing() { open = nil }

    /// Steps recorded between `beginGroup` and `endGroup` undo as one.
    func beginGroup() {
        if groupDepth == 0 {
            open = nil
            nextGroup += 1
            groupID = nextGroup
        }
        groupDepth += 1
    }

    func endGroup() {
        if let last = undoOps.last, last.group == groupID { last.selectionAfter = textView?.selectedRange() }
        completeSelection()
        groupDepth = max(0, groupDepth - 1)
        if groupDepth == 0 {
            groupID = nil
            open = nil
        }
    }

    // MARK: Checkpoints (Writing Tools)

    /// The whole history as it stands, copied (steps are rebased in place,
    /// so their fields are saved too).
    struct Checkpoint {
        fileprivate typealias Saved = (Op, NSRange, NSAttributedString, NSAttributedString, Bool,
                                       (tag: String, adds: Bool, changesTags: Bool)?,
                                       (adds: [String], removes: [String])?,
                                       (location: Int, before: ParagraphState, after: ParagraphState)?,
                                       (kind: NoteMark.Kind, before: Bool, after: Bool)?,
                                       (before: NoteBlock?, after: NoteBlock?)?,
                                       TableSnapshot?, NSRange?, NSRange?)
        fileprivate let undo: [Saved]
        fileprivate let redo: [Saved]
    }

    func checkpoint() -> Checkpoint {
        open = nil
        func copy(_ ops: [Op]) -> [Checkpoint.Saved] {
            ops.map { ($0, $0.range, $0.current, $0.other, $0.isInert, $0.tagDelta, $0.tagPickerDelta, $0.paragraphStyleSnapshot, $0.typingMarkSnapshot, $0.emptyParagraphSnapshot, $0.tableSnapshot, $0.selectionBefore, $0.selectionAfter) }
        }
        return Checkpoint(undo: copy(undoOps), redo: copy(redoOps))
    }

    /// Puts the history back to a checkpoint taken when the text was what it
    /// is now (the caller restored the text first).
    func rewind(to checkpoint: Checkpoint) {
        func restore(_ saved: [Checkpoint.Saved]) -> [Op] {
            saved.map { op, range, current, other, inert, tagDelta, tagPickerDelta, paragraphStyleSnapshot, typingMarkSnapshot, emptyParagraphSnapshot, tableSnapshot, selectionBefore, selectionAfter in
                op.range = range
                op.current = current
                op.other = other
                op.isInert = inert
                op.tagDelta = tagDelta
                op.tagPickerDelta = tagPickerDelta
                op.paragraphStyleSnapshot = paragraphStyleSnapshot
                op.typingMarkSnapshot = typingMarkSnapshot
                op.emptyParagraphSnapshot = emptyParagraphSnapshot
                op.tableSnapshot = tableSnapshot
                op.selectionBefore = selectionBefore
                op.selectionAfter = selectionAfter
                return op
            }
        }
        undoOps = restore(checkpoint.undo)
        redoOps = restore(checkpoint.redo)
        open = nil
        pending.removeAll()
        selectionCompletion = nil
        composition = nil
        log.append("rewound to a checkpoint")
    }

    // MARK: Markers

    /// Where the history stands now; `discardSteps(since:)` returns to it.
    func marker() -> Int {
        open = nil
        return undoOps.count
    }

    /// Drops every step recorded since `marker` and the redo list: the text
    /// has been put back to what it was at the marker, so no step can
    /// re-apply what was undone (a Writing Tools recovery can never be
    /// redone or undone back into object loss).
    func discardSteps(since marker: Int) {
        let keep = min(max(0, marker), undoOps.count)
        undoOps.removeSubrange(keep...)
        redoOps.removeAll()
        open = nil
        pending.removeAll()
        selectionCompletion = nil
        composition = nil
        log.append("discarded steps since \(keep)")
    }

    // MARK: Recording

    func willChange(ranges: [NSRange], strings: [String]?) {
        guard !isReplaying else { return }
        pending.removeAll()
        let sorted = ranges.enumerated().sorted { $0.element.location < $1.element.location }
        var delta = 0
        for (index, range) in sorted {
            let newLength = strings.map { ($0[index] as NSString).length } ?? range.length
            var entry = Pending(range: range, old: storage.attributedSubstring(from: range),
                                newRange: NSRange(location: range.location + delta, length: newLength),
                                emptyParagraphBefore: emptyParagraphState?(), selectionBefore: textView?.selectedRange())
            if ranges.count == 1, groupID == nil, let op = open, !op.isInert, !op.isSnapshot,
               range.location <= NSMaxRange(op.range), NSMaxRange(range) >= op.range.location {
                entry.coalesceInto = op
                if range.location < op.range.location {
                    entry.pre = storage.attributedSubstring(from: NSRange(location: range.location,
                                                                          length: op.range.location - range.location))
                }
                if NSMaxRange(range) > NSMaxRange(op.range) {
                    entry.post = storage.attributedSubstring(from: NSRange(location: NSMaxRange(op.range),
                                                                           length: NSMaxRange(range) - NSMaxRange(op.range)))
                }
            }
            pending.append(entry)
            delta += newLength - range.length
        }
        expectedLength = storage.length + delta
    }

    func didChange(name: String = "Typing") {
        guard !isReplaying else { return }
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return }
        guard storage.length == expectedLength else {
            log.append("discarded a change whose length did not match (\(storage.length) vs \(expectedLength))")
            open = nil
            return
        }
        if pending.count > 1 { open = nil }
        for entry in pending {
            let now = storage.attributedSubstring(from: entry.newRange)
            if let op = entry.coalesceInto {
                if entry.pre != nil || entry.post != nil {
                    let old = NSMutableAttributedString()
                    if let pre = entry.pre { old.append(pre) }
                    old.append(op.other)
                    if let post = entry.post { old.append(post) }
                    op.other = old
                }
                let start = min(entry.range.location, op.range.location)
                let endBefore = max(NSMaxRange(entry.range), NSMaxRange(op.range))
                let delta = entry.newRange.length - entry.range.length
                if let current = op.current as? NSMutableAttributedString,
                   entry.range.location >= op.range.location,
                   NSMaxRange(entry.range) <= NSMaxRange(op.range) {
                    let local = NSRange(location: entry.range.location - op.range.location,
                                        length: entry.range.length)
                    current.replaceCharacters(in: local, with: now)
                } else {
                    op.current = storage.attributedSubstring(from: NSRange(location: start,
                                                                           length: endBefore + delta - start))
                }
                op.range = NSRange(location: start, length: endBefore + delta - start)
                selectionCompletion = op
                recordingGeneration &+= 1
                op.selectionAfter = textView?.selectedRange()
                updateEmptyParagraphSnapshot(op, before: entry.emptyParagraphBefore)
            } else {
                let op = Op(range: entry.newRange, current: now, other: entry.old, name: name, group: groupID ?? nextOwnGroup())
                op.selectionBefore = entry.selectionBefore
                updateEmptyParagraphSnapshot(op, before: entry.emptyParagraphBefore)
                append(op)
                open = (pending.count == 1 && groupID == nil) ? undoOps.last : nil
            }
        }
    }

    private func updateEmptyParagraphSnapshot(_ op: Op, before captured: NoteBlock?) {
        let before: NoteBlock?
        if let snapshot = op.emptyParagraphSnapshot { before = snapshot.before }
        else { before = captured }
        let after = emptyParagraphState?()
        op.emptyParagraphSnapshot = before == after ? nil : (before, after)
    }

    private func nextOwnGroup() -> Int {
        nextGroup += 1
        return nextGroup
    }

    /// Capture the final selection after AppKit or a command finishes,
    /// never a later caret move and never a replay's intermediate selection.
    func completeSelection(since generation: Int? = nil) {
        guard !isReplaying, !isTraversing, pending.isEmpty else { return }
        let op = generation.map { $0 != recordingGeneration ? undoOps.last : nil } ?? selectionCompletion
        op?.selectionAfter = textView?.selectedRange()
        selectionCompletion = nil
    }

    private func append(_ op: Op) {
        // Snapshot operations do not change the root text selection. Their
        // cell focus lives in the snapshot, and groups capture their final
        // endpoint in endGroup. Never leave them open for a later arrow key.
        selectionCompletion = op.isSnapshot ? nil : op
        recordingGeneration &+= 1
        if op.selectionBefore == nil { op.selectionBefore = textView?.selectedRange() }
        op.selectionAfter = textView?.selectedRange()
        undoOps.append(op)
        redoOps.removeAll()
        if undoOps.count > limit { undoOps.removeFirst(undoOps.count - limit) }
    }

    /// The text view announces a composition that starts by replacing
    /// `range` (a selection); the replaced text is captured before the
    /// storage changes.
    func beginComposition(replacing range: NSRange) {
        guard !isReplaying, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        composition = (range, storage.attributedSubstring(from: range), textView?.selectedRange())
        open = nil
    }

    /// A character edit that did not pass through `willChange` (marked text,
    /// a direct storage edit). `newRange` is in post-edit coordinates.
    func captureUnrecorded(newRange: NSRange, delta: Int, emptyParagraphBefore: NoteBlock? = nil) {
        guard !isReplaying else { return }
        // A change announced through the delegate is final as soon as the
        // storage holds it: NSTextView sends no textDidChange for marked text.
        if !pending.isEmpty {
            if storage.length == expectedLength { didChange() }
            return
        }
        let oldLength = newRange.length - delta
        guard oldLength >= 0 else { return }
        let preRange = NSRange(location: newRange.location, length: oldLength)
        var old: NSAttributedString?
        var coalesce: Op?
        let selectionBefore = composition?.selection ?? textView?.selectedRange()
        if let captured = composition, captured.range == preRange {
            old = captured.old
            composition = nil
        } else if let op = open, !op.isInert, !op.isSnapshot, preRange.location >= op.range.location,
                  NSMaxRange(preRange) <= NSMaxRange(op.range) {
            old = op.current.attributedSubstring(from: NSRange(location: preRange.location - op.range.location,
                                                               length: oldLength))
            coalesce = op
        } else if oldLength == 0 {
            old = NSAttributedString()
        }
        composition = nil
        guard let old else {
            log.append("an edit bypassed the change delegate over unknown text; history rebased around it")
            open = nil
            rebase(editAt: preRange, newLength: newRange.length)
            return
        }
        pending = [Pending(range: preRange, old: old, newRange: newRange, coalesceInto: coalesce,
                           emptyParagraphBefore: emptyParagraphBefore, selectionBefore: selectionBefore)]
        if let op = coalesce {
            // Inside the open step: its recorded old text already covers this.
            pending[0].pre = nil
            pending[0].post = nil
            let delta = newRange.length - preRange.length
            if let current = op.current as? NSMutableAttributedString {
                let local = NSRange(location: preRange.location - op.range.location, length: preRange.length)
                current.replaceCharacters(in: local, with: storage.attributedSubstring(from: newRange))
            } else {
                op.current = storage.attributedSubstring(from: NSRange(location: op.range.location,
                                                                       length: op.range.length + delta))
            }
            op.range = NSRange(location: op.range.location, length: op.range.length + delta)
            selectionCompletion = op
            recordingGeneration &+= 1
            op.selectionAfter = textView?.selectedRange()
            updateEmptyParagraphSnapshot(op, before: emptyParagraphBefore)
            pending.removeAll()
            return
        }
        expectedLength = storage.length
        didChange()
    }

    func renameLast(_ name: String) {
        undoOps.last?.name = name
    }

    /// A conversion intercepting Return restores the literal Return input
    /// on its first Undo, including the newline that AppKit did not insert.
    func setLastRestoredText(_ text: NSAttributedString) {
        undoOps.last?.other = text
    }

    /// The last step was the title shorthand for `tag` (and added it to the
    /// note when `changesTags`): undo removes it, redo adds it back (one step
    /// for the text and the tag).
    func attachTagToLast(_ tag: String, changesTags: Bool = true) {
        undoOps.last?.tagDelta = (tag, false, changesTags)
    }

    /// A tag picker edit is metadata only, but shares the editor's Undo stack.
    /// Store-backed metadata belongs at this point in the editor's history.
    /// A refused save keeps the step and its direction for a later retry.
    func recordExternalChange(name: String, undo: @escaping () -> Bool, redo: @escaping () -> Bool) {
        open = nil
        let empty = NSAttributedString()
        let op = Op(range: NSRange(location: 0, length: 0), current: empty, other: empty,
                    name: name, group: nextOwnGroup())
        op.externalChange = (undo, redo, true)
        append(op)
    }

    func recordTagChange(before: [String], after: [String]) {
        guard before != after else { return }
        open = nil
        let empty = NSAttributedString()
        let op = Op(range: NSRange(location: 0, length: 0), current: empty, other: empty,
                    name: "Edit Tags", group: nextOwnGroup())
        let old = Set(before), new = Set(after)
        op.tagPickerDelta = (Array(old.subtracting(new)).sorted(), Array(new.subtracting(old)).sorted())
        append(op)
    }

    func recordParagraphStyleChange(location: Int, before: ParagraphState, after: ParagraphState) {
        guard before != after else { return }
        open = nil
        let empty = NSAttributedString()
        let op = Op(range: NSRange(location: location, length: 0), current: empty, other: empty,
                    name: "Format", group: groupID ?? nextOwnGroup())
        op.paragraphStyleSnapshot = (location, before, after)
        append(op)
    }

    func recordTypingMarkChange(_ kind: NoteMark.Kind, before: Bool, after: Bool) {
        guard before != after else { return }
        open = nil
        let empty = NSAttributedString()
        let op = Op(range: NSRange(location: 0, length: 0), current: empty, other: empty,
                    name: kind.rawValue.capitalized, group: groupID ?? nextOwnGroup())
        op.typingMarkSnapshot = (kind, before, after)
        append(op)
    }

    func setLastBoundaryTypingMarks(_ marks: [NoteMark.Kind: Any]) {
        undoOps.last?.boundaryTypingMarks = marks
    }

    /// A change to a table's grid. Typing in one cell coalesces like typing
    /// in the note (`cell`): consecutive edits of the same cell join the
    /// open step; any other step, a caret jump or another cell ends it.
    func recordTableChange(id: UUID, before: NoteTable, after: NoteTable, name: String,
                           focusBefore: NoteTableFocus?, focusAfter: NoteTableFocus?, cell: NoteTable.Position? = nil) {
        guard !isReplaying, before != after else { return }
        if let cell, groupID == nil, let op = open, !op.isInert, var snapshot = op.tableSnapshot,
           snapshot.id == id, snapshot.cell == cell {
            snapshot.after = after
            snapshot.focusAfter = focusAfter
            selectionCompletion = nil
            op.selectionAfter = textView?.selectedRange()
            recordingGeneration &+= 1
            op.tableSnapshot = snapshot
            redoOps.removeAll()
            return
        }
        open = nil
        let empty = NSAttributedString()
        let op = Op(range: NSRange(location: 0, length: 0), current: empty, other: empty,
                    name: name, group: groupID ?? nextOwnGroup())
        op.tableSnapshot = TableSnapshot(id: id, before: before, after: after, focusBefore: focusBefore,
                                         focusAfter: focusAfter, cell: cell)
        append(op)
        if cell != nil, groupID == nil { open = op }
    }

    /// The open step is typing in this table's cell.
    func isTypingInTable(_ id: UUID, cell: NoteTable.Position) -> Bool {
        guard let snapshot = open?.tableSnapshot else { return false }
        return snapshot.id == id && snapshot.cell == cell
    }

    /// Runs a storage change that must not become a step (a restore the
    /// history is being rewound to).
    func performUnrecorded(_ body: () -> Void) {
        let wasReplaying = isReplaying
        isReplaying = true
        body()
        isReplaying = wasReplaying
        pending.removeAll()
        selectionCompletion = nil
        composition = nil
        open = nil
    }

    // MARK: Undo and redo

    @discardableResult
    func undo() -> Bool {
        guard canReplay?() ?? true else { return false }
        guard let last = undoOps.last else {
            if let origin = outsideEditBarrier { onOutsideEditBarrier?(origin) }
            return false
        }
        isTraversing = true
        defer { isTraversing = false }
        open = nil
        let group = last.group
        var changed = false
        while let op = undoOps.last, op.group == group {
            undoOps.removeLast()
            let applied = flip(op)
            if !applied && !op.isInert { undoOps.append(op); break }
            changed = applied || changed
            redoOps.insert(op, at: 0)
        }
        return changed
    }

    @discardableResult
    func redo() -> Bool {
        guard canReplay?() ?? true else { return false }
        guard let first = redoOps.first else { return false }
        isTraversing = true
        defer { isTraversing = false }
        open = nil
        let group = first.group
        var changed = false
        while let op = redoOps.first, op.group == group {
            redoOps.removeFirst()
            let applied = flip(op)
            if !applied && !op.isInert { redoOps.insert(op, at: 0); break }
            changed = applied || changed
            undoOps.append(op)
        }
        return changed
    }

    /// Undo and redo are the same swap.
    private func flip(_ op: Op) -> Bool {
        guard !op.isInert else {
            log.append("skipped an inert step (\(op.name)): an outside edit overlapped it")
            return false
        }
        if var change = op.externalChange {
            guard (change.undoNext ? change.undo : change.redo)() else { return false }
            change.undoNext.toggle()
            op.externalChange = change
            return true
        }
        if let delta = op.tagPickerDelta {
            flipSelection(op)
            op.tagPickerDelta = (delta.removes, delta.adds)
            onTagPickerDelta?(delta.adds, delta.removes)
            return true
        }
        if let snapshot = op.paragraphStyleSnapshot {
            flipSelection(op)
            op.paragraphStyleSnapshot = (snapshot.location, snapshot.after, snapshot.before)
            onParagraphStyleSnapshot?(snapshot.location, snapshot.before)
            return true
        }
        if let snapshot = op.typingMarkSnapshot {
            flipSelection(op)
            op.typingMarkSnapshot = (snapshot.kind, snapshot.after, snapshot.before)
            onTypingMarkSnapshot?(snapshot.kind, snapshot.before)
            return true
        }
        if let snapshot = op.tableSnapshot {
            isReplaying = true
            defer { isReplaying = false }
            guard onTableSnapshot?(snapshot.id, snapshot.before, snapshot.focusBefore) == true else {
                log.append("could not replay \(op.name): its table is not in the note")
                op.isInert = true
                return false
            }
            flipSelection(op)
            op.tableSnapshot = TableSnapshot(id: snapshot.id, before: snapshot.after, after: snapshot.before,
                                             focusBefore: snapshot.focusAfter, focusAfter: snapshot.focusBefore,
                                             cell: snapshot.cell)
            return true
        }
        guard NSMaxRange(op.range) <= storage.length else {
            log.append("could not replay \(op.name)")
            return false
        }
        isReplaying = true
        defer { isReplaying = false }
        let replacement = op.other
        if let textView {
            guard textView.shouldChangeText(in: op.range, replacementString: replacement.string) else {
                log.append("could not replay \(op.name)")
                return false
            }
            storage.replaceCharacters(in: op.range, with: replacement)
            textView.didChangeText()
        } else {
            storage.replaceCharacters(in: op.range, with: replacement)
        }
        op.other = op.current
        op.current = replacement
        op.range = NSRange(location: op.range.location, length: replacement.length)
        flipSelection(op, fallback: NSRange(location: NSMaxRange(op.range), length: 0))
        if let delta = op.tagDelta {
            op.tagDelta = (delta.tag, !delta.adds, delta.changesTags)
            onTagFlip?(delta.tag, delta.adds, delta.changesTags, op.range)
        }
        if let snapshot = op.emptyParagraphSnapshot {
            op.emptyParagraphSnapshot = (snapshot.after, snapshot.before)
            onEmptyParagraphSnapshot?(snapshot.before)
        }
        onReplay?(op.range)
        if let marks = op.boundaryTypingMarks {
            onBoundaryTypingMarksSnapshot?(marks)
        }
        return true
    }

    private func flipSelection(_ op: Op, fallback: NSRange? = nil) {
        let selection = op.selectionBefore ?? fallback
        swap(&op.selectionBefore, &op.selectionAfter)
        if let selection, let textView {
            let location = min(max(0, selection.location), storage.length)
            let restored = NSRange(location: location, length: min(selection.length, storage.length - location))
            // Even setting the same caret makes AppKit rederive typing
            // attributes from the text, discarding pending inline marks.
            if textView.selectedRange() != restored { textView.setSelectedRange(restored) }
        }
    }

    // MARK: Rebasing through an outside edit

    /// `range` (current coordinates) was replaced by `newLength` characters
    /// outside this history. Steps before or after it shift; a step whose own
    /// text it overlapped becomes inert (does nothing, logged).
    func rebase(editAt range: NSRange, newLength: Int) {
        var edit = (location: range.location, old: range.length, new: newLength)
        var inert = 0
        for op in undoOps.reversed() {
            if !shift(op, by: edit) { inert += 1 }
            edit = map(edit, at: op.range.location, oldLength: op.current.length, newLength: op.other.length)
        }
        edit = (range.location, range.length, newLength)
        for op in redoOps {
            if !shift(op, by: edit) { inert += 1 }
            edit = map(edit, at: op.range.location, oldLength: op.other.length, newLength: op.current.length)
        }
        if inert > 0 { log.append("outside edit overlapped \(inert) step(s); they are now inert") }
    }

    private func shift(_ op: Op, by edit: (location: Int, old: Int, new: Int)) -> Bool {
        func moved(_ selection: NSRange?, by change: (location: Int, old: Int, new: Int)) -> NSRange? {
            guard let selection else { return nil }
            func position(_ value: Int) -> Int {
                if value <= change.location { return value }
                if value >= change.location + change.old { return value + change.new - change.old }
                return change.location + change.new
            }
            let start = position(selection.location), end = position(NSMaxRange(selection))
            return NSRange(location: start, length: max(0, end - start))
        }
        op.selectionAfter = moved(op.selectionAfter, by: edit)
        op.selectionBefore = moved(op.selectionBefore, by: map(edit, at: op.range.location,
            oldLength: op.current.length, newLength: op.other.length))
        if op.externalChange != nil || op.tagPickerDelta != nil || op.typingMarkSnapshot != nil || op.tableSnapshot != nil { return true }
        if var snapshot = op.paragraphStyleSnapshot {
            if edit.location + edit.old < snapshot.location {
                snapshot.location += edit.new - edit.old
                op.paragraphStyleSnapshot = snapshot
                op.range.location = snapshot.location
                return true
            }
            if edit.location > snapshot.location { return true }
            op.isInert = true
            return false
        }
        if edit.location + edit.old <= op.range.location {
            op.range.location += edit.new - edit.old
            return true
        }
        if edit.location >= NSMaxRange(op.range) { return true }
        op.isInert = true
        if op === open { open = nil }
        return false
    }

    private func map(_ edit: (location: Int, old: Int, new: Int), at location: Int, oldLength: Int,
                     newLength: Int) -> (location: Int, old: Int, new: Int) {
        func position(_ value: Int) -> Int {
            if value <= location { return value }
            if value >= location + oldLength { return value + newLength - oldLength }
            return location
        }
        let start = position(edit.location), end = position(edit.location + edit.old)
        return (start, max(0, end - start), edit.new)
    }
}
