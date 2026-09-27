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
    final class Op {
        fileprivate(set) var range: NSRange
        fileprivate var current: NSAttributedString
        fileprivate var other: NSAttributedString
        fileprivate(set) var name: String
        fileprivate(set) var isInert = false
        fileprivate let group: Int

        fileprivate init(range: NSRange, current: NSAttributedString, other: NSAttributedString, name: String, group: Int) {
            self.range = range
            self.current = current
            self.other = other
            self.name = name
            self.group = group
        }

        /// The text this step would restore (tests).
        var restores: String { other.string }
    }

    private struct Pending {
        var range: NSRange
        var old: NSAttributedString
        var newRange: NSRange
        var coalesceInto: Op?
        var pre: NSAttributedString?
        var post: NSAttributedString?
    }

    let storage: NSTextStorage
    /// Replays through the text view when one is attached, so its delegate,
    /// selection and layout see the change; nil edits the storage directly.
    weak var textView: NSTextView?
    var onReplay: ((NSRange) -> Void)?

    private(set) var undoOps: [Op] = []
    private(set) var redoOps: [Op] = []
    private(set) var log: [String] = []
    private(set) var isReplaying = false
    private var open: Op?
    private var pending: [Pending] = []
    private var expectedLength = 0
    private var nextGroup = 0
    private var groupDepth = 0
    private var groupID: Int?
    private var composition: (range: NSRange, old: NSAttributedString)?
    let limit: Int

    init(storage: NSTextStorage, limit: Int = 500) {
        self.storage = storage
        self.limit = limit
    }

    var canUndo: Bool { !undoOps.isEmpty }
    var canRedo: Bool { !redoOps.isEmpty }
    var undoActionName: String { undoOps.last?.name ?? "" }
    var redoActionName: String { redoOps.first?.name ?? "" }
    var isChangeInFlight: Bool { !pending.isEmpty }
    var openStep: Op? { open }

    func reset() {
        undoOps.removeAll()
        redoOps.removeAll()
        open = nil
        pending.removeAll()
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
        fileprivate let undo: [(Op, NSRange, NSAttributedString, NSAttributedString, Bool)]
        fileprivate let redo: [(Op, NSRange, NSAttributedString, NSAttributedString, Bool)]
    }

    func checkpoint() -> Checkpoint {
        open = nil
        func copy(_ ops: [Op]) -> [(Op, NSRange, NSAttributedString, NSAttributedString, Bool)] {
            ops.map { ($0, $0.range, $0.current, $0.other, $0.isInert) }
        }
        return Checkpoint(undo: copy(undoOps), redo: copy(redoOps))
    }

    /// Puts the history back to a checkpoint taken when the text was what it
    /// is now (the caller restored the text first).
    func rewind(to checkpoint: Checkpoint) {
        func restore(_ saved: [(Op, NSRange, NSAttributedString, NSAttributedString, Bool)]) -> [Op] {
            saved.map { op, range, current, other, inert in
                op.range = range
                op.current = current
                op.other = other
                op.isInert = inert
                return op
            }
        }
        undoOps = restore(checkpoint.undo)
        redoOps = restore(checkpoint.redo)
        open = nil
        pending.removeAll()
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
                                newRange: NSRange(location: range.location + delta, length: newLength))
            if ranges.count == 1, groupID == nil, let op = open, !op.isInert,
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
                let old = NSMutableAttributedString()
                if let pre = entry.pre { old.append(pre) }
                old.append(op.other)
                if let post = entry.post { old.append(post) }
                let start = min(entry.range.location, op.range.location)
                let endBefore = max(NSMaxRange(entry.range), NSMaxRange(op.range))
                let delta = entry.newRange.length - entry.range.length
                op.range = NSRange(location: start, length: endBefore + delta - start)
                op.other = old
                op.current = storage.attributedSubstring(from: op.range)
            } else {
                append(Op(range: entry.newRange, current: now, other: entry.old, name: name, group: groupID ?? nextOwnGroup()))
                open = (pending.count == 1 && groupID == nil) ? undoOps.last : nil
            }
        }
    }

    private func nextOwnGroup() -> Int {
        nextGroup += 1
        return nextGroup
    }

    private func append(_ op: Op) {
        undoOps.append(op)
        redoOps.removeAll()
        if undoOps.count > limit { undoOps.removeFirst(undoOps.count - limit) }
    }

    /// The text view announces a composition that starts by replacing
    /// `range` (a selection); the replaced text is captured before the
    /// storage changes.
    func beginComposition(replacing range: NSRange) {
        guard !isReplaying, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        composition = (range, storage.attributedSubstring(from: range))
        open = nil
    }

    /// A character edit that did not pass through `willChange` (marked text,
    /// a direct storage edit). `newRange` is in post-edit coordinates.
    func captureUnrecorded(newRange: NSRange, delta: Int) {
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
        if let captured = composition, captured.range == preRange {
            old = captured.old
            composition = nil
        } else if let op = open, !op.isInert, preRange.location >= op.range.location,
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
        pending = [Pending(range: preRange, old: old, newRange: newRange, coalesceInto: coalesce)]
        if let op = coalesce {
            // Inside the open step: its recorded old text already covers this.
            pending[0].pre = nil
            pending[0].post = nil
            let delta = newRange.length - preRange.length
            op.range = NSRange(location: op.range.location, length: op.range.length + delta)
            op.current = storage.attributedSubstring(from: op.range)
            pending.removeAll()
            return
        }
        expectedLength = storage.length
        didChange()
    }

    func renameLast(_ name: String) {
        undoOps.last?.name = name
    }

    /// Runs a storage change that must not become a step (a restore the
    /// history is being rewound to).
    func performUnrecorded(_ body: () -> Void) {
        let wasReplaying = isReplaying
        isReplaying = true
        body()
        isReplaying = wasReplaying
        pending.removeAll()
        composition = nil
        open = nil
    }

    // MARK: Undo and redo

    @discardableResult
    func undo() -> Bool {
        guard let last = undoOps.last else { return false }
        open = nil
        let group = last.group
        var changed = false
        while let op = undoOps.last, op.group == group {
            undoOps.removeLast()
            changed = flip(op) || changed
            redoOps.insert(op, at: 0)
        }
        return changed
    }

    @discardableResult
    func redo() -> Bool {
        guard let first = redoOps.first else { return false }
        open = nil
        let group = first.group
        var changed = false
        while let op = redoOps.first, op.group == group {
            redoOps.removeFirst()
            changed = flip(op) || changed
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
        textView?.setSelectedRange(NSRange(location: NSMaxRange(op.range), length: 0))
        onReplay?(op.range)
        return true
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
