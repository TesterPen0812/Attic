import AppKit
import Foundation
import SwiftData

/// What Make Subtask (⌥⌘S, UX plan § 2.3.3) takes from the writing of a
/// task's note. Pure: built from the editor's text and selection, it never
/// edits anything.
///
/// | Selection | Becomes |
/// | --- | --- |
/// | a caret | the caret's whole paragraph, one subtask |
/// | part of one paragraph | the selected text; the rest stays; a paragraph left empty goes |
/// | several paragraphs | one subtask per non-empty paragraph touched, in order; partial ends give their selected part; empty paragraphs are skipped (removed when wholly selected) |
/// | a note checkbox | its text; a checked box gives a completed subtask |
///
/// Text that holds something a subtask cannot carry (a link, an inline
/// style or highlight, an attachment: an image, a file, a date, a card) is
/// "rich": it still makes a subtask (plain text), and its line stays in the
/// writing unchanged (Create Subtask and Keep Original).
struct TaskNoteSubtaskSelection: Equatable {
    struct Piece: Equatable {
        let title: String
        let isDone: Bool
        let isRich: Bool
        /// What leaves the writing (nil: the line stays, Keep Original).
        let removal: NSRange?
    }

    let pieces: [Piece]
    /// Wholly selected empty paragraphs, removed with the rest.
    let emptyRemovals: [NSRange]
    /// The caret's place before the command (Undo puts it back).
    let selection: NSRange

    var isEmpty: Bool { pieces.isEmpty }
    var richCount: Int { pieces.filter(\.isRich).count }
    var hasOpenSubtask: Bool { pieces.contains { !$0.isDone } }

    static func analyse(_ text: NSAttributedString, selection: NSRange) -> TaskNoteSubtaskSelection {
        let string = text.string as NSString
        let length = string.length
        let selected = NSRange(location: min(max(0, selection.location), length),
                               length: max(0, min(selection.length, length - min(max(0, selection.location), length))))
        let caret = selected.length == 0
        var paragraphs: [NSRange] = []
        if caret {
            paragraphs = [string.paragraphRange(for: NSRange(location: selected.location, length: 0))]
        } else {
            var location = selected.location
            let end = NSMaxRange(selected)
            repeat {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                paragraphs.append(paragraph)
                guard NSMaxRange(paragraph) > location else { break }
                location = NSMaxRange(paragraph)
            } while location < end && location < length
        }
        var pieces: [Piece] = []
        var empties: [NSRange] = []
        for paragraph in paragraphs {
            var content = paragraph
            if content.length > 0, Self.isBreak(string.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let box = content.length > 0 ? text.attribute(.attachment, at: content.location, effectiveRange: nil) as? NoteChecklistAttachment : nil
            let bodyStart = content.location + (box == nil ? 0 : 1)
            let body = NSRange(location: bodyStart, length: NSMaxRange(content) - bodyStart)
            let take: NSRange
            if caret {
                take = body
            } else {
                let overlap = NSIntersectionRange(body, selected)
                guard overlap.length > 0 else {
                    // None of its text is selected: an empty paragraph
                    // wholly inside the selection goes, any other stays.
                    if box == nil, paragraph.length > 0, Self.plainTitle(string.substring(with: body)).isEmpty,
                       NSIntersectionRange(paragraph, selected).length == paragraph.length {
                        empties.append(Self.paragraphRemoval(paragraph, in: string))
                    }
                    continue
                }
                take = overlap
            }
            let title = Self.plainTitle(string.substring(with: take))
            let rest = (string.substring(with: body) as NSString)
                .replacingCharacters(in: NSRange(location: take.location - body.location, length: take.length), with: "")
            let whole = caret || Self.plainTitle(rest).isEmpty
            if title.isEmpty {
                // Only whitespace selected: a paragraph left empty goes.
                if !caret, whole, box == nil, paragraph.length > 0 { empties.append(Self.paragraphRemoval(paragraph, in: string)) }
                continue
            }
            let rich = Self.isRich(text, in: take)
            let removal = rich ? nil : (whole ? Self.paragraphRemoval(paragraph, in: string) : take)
            pieces.append(Piece(title: title, isDone: box?.isChecked ?? false, isRich: rich, removal: removal))
        }
        return TaskNoteSubtaskSelection(pieces: pieces, emptyRemovals: empties, selection: selected)
    }

    /// The writing once the plain lines (and wholly selected empty ones)
    /// have left, and where the caret goes: where the text was.
    func candidate(from text: NSAttributedString) -> (text: NSAttributedString, caret: Int) {
        var ranges = (pieces.compactMap(\.removal) + emptyRemovals).sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return (text, selection.location) }
        // Merge touching or overlapping removals (a last paragraph removes
        // the break before it).
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges.reversed() where NSMaxRange(range) <= result.length {
            result.deleteCharacters(in: range)
        }
        let caret = min(ranges[0].location, result.length)
        return (result, caret)
    }

    private static func isBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }

    /// The paragraph and its break; the last paragraph takes the break
    /// before it instead, so no empty line is left behind.
    private static func paragraphRemoval(_ paragraph: NSRange, in string: NSString) -> NSRange {
        if paragraph.length > 0, isBreak(string.character(at: NSMaxRange(paragraph) - 1)) { return paragraph }
        if paragraph.location > 0 { return NSRange(location: paragraph.location - 1, length: paragraph.length + 1) }
        return paragraph
    }

    /// List markers and heading styles are paragraph attributes, so they
    /// are already gone; attachment characters and surrounding whitespace
    /// go too. Shorthand is never parsed.
    static func plainTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isRich(_ text: NSAttributedString, in range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var rich = false
        text.enumerateAttributes(in: range) { attributes, _, stop in
            for key in attributes.keys where key == .attachment || key == .link
                || key.rawValue.hasPrefix("com.taha.attic.note.mark.") {
                rich = true
                stop.pointee = true
                return
            }
        }
        return rich
    }
}

/// The page's workspace operations (S1, S11): each is one gated, journaled
/// commit through the operation coordinator, recorded as one entry in the
/// workspace's history, whose Undo and Redo replay through the same gate.
extension TaskNotePresenter {
    /// What happened (the toast and the slot read it).
    enum OperationResult: Equatable {
        case made(entryID: UUID, count: Int, kept: Int)
        case madeCheckbox(entryID: UUID, recovery: String?)
        case refused(String)
    }

    /// Why Make Subtask is unavailable here, or nil (§ 6: the disabled
    /// command consumes ⌥⌘S and says why).
    func makeSubtaskUnavailableReason(tasks: TaskStore) -> String? {
        guard let session, lease != nil else { return String(localized: "Subtasks are made in a task's note") }
        if tasks.task(withID: taskID) == nil { return String(localized: "The task is deleted") }
        if session.isReadOnly { return String(localized: "This note is read-only") }
        return nil
    }

    func subtaskSelection() -> TaskNoteSubtaskSelection? {
        guard let session, let textView = session.engine.textView else { return nil }
        return TaskNoteSubtaskSelection.analyse(session.engine.textStorage, selection: textView.selectedRange())
    }

    /// Make Subtask (§ 2.3.3): the subtasks and the writing change in one
    /// commit; the toast's and ⌘Z's Undo restore the exact source.
    func makeSubtasks(_ analysis: TaskNoteSubtaskSelection, tasks: TaskStore,
                      notes: NotesPageController) async -> OperationResult {
        if let reason = makeSubtaskUnavailableReason(tasks: tasks) { return .refused(reason) }
        guard !analysis.isEmpty, let session else { return .refused(String(localized: "There is no text to make a subtask from")) }
        let engine = session.engine
        guard engine.textView?.hasMarkedText() != true, engine.activity == .idle else {
            return .refused(String(localized: "Finish typing first"))
        }
        let source = NSAttributedString(attributedString: engine.textStorage)
        guard notes.settleForWorkspaceOperation(session), session.engine === engine,
              source.isEqual(to: engine.textStorage) else {
            return .refused(String(localized: "Couldn't save the note first"))
        }
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Couldn't make the subtask"))
        }
        let (candidate, caret) = analysis.candidate(from: source)
        let drafts = analysis.pieces.map { TaskDraft(title: $0.title, status: $0.isDone ? .done : .todo, parentID: taskID) }
        let ids = drafts.map { _ in UUID() }
        let titles = Dictionary(uniqueKeysWithValues: zip(ids, drafts.map(\.title)))
        let parent = taskID
        let before = analysis.selection
        let edit = TaskNoteTextEdit(engine: engine, session: session, notes: notes, tasks: tasks,
                                    coordinator: coordinator, history: page.history, noteID: session.noteID,
                                    parentID: taskID, selectionBefore: before, caretAfter: caret)
        let entry = UUID()
        let outcome = await edit.perform(name: String(localized: "Make Subtask"), candidate: candidate, entryID: entry,
            forwardWrites: Set(ids.map { WorkspaceOwner(entity: .task, id: $0) }),
            forward: { commit in
                _ = try TaskStore.stageCreation(in: commit, drafts: drafts, ids: ids, timestamp: Date())
            },
            inverse: { redo in
                // Undo removes exactly the subtasks it made, as made; a
                // subtask renamed, moved or deleted since refuses (S11).
                try TaskNoteTextEdit.TaskStep(writes: Set(ids.map { WorkspaceOwner(entity: .task, id: $0) }),
                    check: { context in
                        for id in ids {
                            let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
                            guard !rows.isEmpty, rows.allSatisfy({ ($0.deletedAt != nil) == redo && $0.parentID == parent
                                && $0.title == titles[id] }) else { throw WorkspaceFoundationError.conflict }
                        }
                    },
                    preservations: redo ? [:] : Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) }),
                    stage: { commit, preservations in
                        if redo {
                            try TaskStore.stageRestoreDeleted(in: commit, taskIDs: ids, timestamp: Date())
                        } else {
                            for id in ids { try TaskStore.stageSoftDeletion(in: commit, taskID: id, preservationID: preservations[id]!, timestamp: Date()) }
                        }
                    }, restores: redo ? Set(ids) : [])
            })
        switch outcome {
        case .committed, .publicationPending:
            if model.isFolded { model.setFolded(false) }
            return .made(entryID: entry, count: ids.count, kept: analysis.richCount)
        case .notCommitted, .conflict, .unknown:
            return .refused(String(localized: "Couldn't make the subtask"))
        }
    }
}

extension TaskNotePresenter {
    /// Make Note Checkbox (§ 2.3.3, the subtask's menu): the subtask's title
    /// goes to the top of the writing as a note checkbox (ticked as it
    /// was), creating the note when there is none, and the subtask is soft
    /// deleted in the same commit. Its complete record stays in the
    /// operation's recovery record and in Recently Deleted; Undo brings the
    /// same record back. Not an inverse of Make Subtask.
    func makeNoteCheckbox(subtaskID: UUID, tasks: TaskStore, notes: NotesPageController) async -> OperationResult {
        guard let session, lease != nil else { return .refused(String(localized: "Couldn't make the note checkbox")) }
        guard tasks.task(withID: taskID) != nil else { return .refused(String(localized: "The task is deleted")) }
        guard !session.isReadOnly else { return .refused(String(localized: "This note is read-only")) }
        guard let subtask = tasks.task(withID: subtaskID), subtask.parentID == taskID else {
            return .refused(String(localized: "The subtask is gone"))
        }
        let engine = session.engine
        guard engine.textView?.hasMarkedText() != true, engine.activity == .idle else {
            return .refused(String(localized: "Finish typing first"))
        }
        // An untouched draft becomes the note inside the operation; any
        // other writing is saved first, so the commit starts from it.
        let creates = !session.isPersisted && session.isUntouchedDraft
        if !creates {
            let source = NSAttributedString(attributedString: engine.textStorage)
            guard notes.settleForWorkspaceOperation(session), session.engine === engine,
                  source.isEqual(to: engine.textStorage) else {
                return .refused(String(localized: "Couldn't save the note first"))
            }
        }
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Couldn't make the note checkbox"))
        }
        let source = NSAttributedString(attributedString: engine.textStorage)
        let line = NSMutableAttributedString(attributedString: engine.bodyText(for: [.checklist(subtask.title, checked: subtask.status == .done)]))
        let candidate = NSMutableAttributedString(attributedString: line)
        if source.length > 0 {
            candidate.append(NSAttributedString(string: "\n", attributes: line.length > 0 ? line.attributes(at: line.length - 1, effectiveRange: nil) : [:]))
            candidate.append(source)
        }
        let selection = engine.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let shift = candidate.length - source.length
        // The caret stays with the text it was in.
        let caret = creates ? line.length : selection.location + shift
        var edit = TaskNoteTextEdit(engine: engine, session: session, notes: notes, tasks: tasks,
                                    coordinator: coordinator, history: page.history, noteID: session.noteID,
                                    parentID: taskID, selectionBefore: selection, caretAfter: caret)
        edit.createsNote = creates
        let preservation = UUID()
        let entry = UUID()
        let parent = taskID
        let outcome = await edit.perform(name: String(localized: "Make Note Checkbox"), candidate: candidate, entryID: entry,
            forwardWrites: [.init(entity: .task, id: subtaskID), .init(entity: .preservation, id: preservation)],
            forward: { commit in
                try TaskStore.stageSoftDeletion(in: commit, taskID: subtaskID, preservationID: preservation, timestamp: Date())
            },
            inverse: { redo in
                // Undo brings the same record back; Redo deletes it again.
                TaskNoteTextEdit.TaskStep(writes: [.init(entity: .task, id: subtaskID)],
                    check: { context in
                        let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == subtaskID }))
                        guard !rows.isEmpty, rows.allSatisfy({ ($0.deletedAt == nil) == redo && $0.parentID == parent }) else {
                            throw WorkspaceFoundationError.conflict
                        }
                    },
                    preservations: redo ? [subtaskID: UUID()] : [:],
                    stage: { commit, preservations in
                        if redo {
                            try TaskStore.stageSoftDeletion(in: commit, taskID: subtaskID, preservationID: preservations[subtaskID]!, timestamp: Date())
                        } else {
                            try TaskStore.stageRestoreDeleted(in: commit, taskIDs: [subtaskID], timestamp: Date())
                        }
                    }, restores: redo ? [] : [subtaskID])
            })
        switch outcome {
        case .committed, .publicationPending:
            return .madeCheckbox(entryID: entry, recovery: Self.recoveryDetail(subtask))
        case .notCommitted, .conflict, .unknown:
            return .refused(String(localized: "Couldn't make the note checkbox"))
        }
    }

    /// What the checkbox can't show and Recently Deleted keeps (§ 2.3.3:
    /// "its date and 1 tag are in Recently Deleted").
    static func recoveryDetail(_ subtask: TaskItem) -> String? {
        var parts: [String] = []
        if subtask.dueDay != nil { parts.append(String(localized: "its date")) }
        if subtask.priority != .none { parts.append(String(localized: "its priority")) }
        let tags = subtask.tags.count
        if tags == 1 { parts.append(String(localized: "1 tag")) } else if tags > 1 { parts.append(String(localized: "\(tags) tags")) }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " " + String(localized: "and") + " " + parts.last!
        // One thing that is singular reads "is"; anything else "are".
        let verb = parts.count == 1 && tags <= 1 ? String(localized: "is") : String(localized: "are")
        return list + " " + verb + " " + String(localized: "in Recently Deleted")
    }
}

extension TaskNotePresenter {
    /// S10 "Merge into This Note": the alternate note's writing joins the
    /// end of this one, and the alternate goes to Recently Deleted, in one
    /// commit (Undo brings both back). An alternate with files is kept
    /// apart: files move between notes only with slice 2's migration.
    func mergeAlternate(_ alternateID: UUID, tasks: TaskStore, notes: NotesPageController) async -> OperationResult {
        guard let session, lease != nil, !session.isReadOnly, session.isPersisted else {
            return .refused(String(localized: "Couldn't merge the notes"))
        }
        guard let loaded = notes.store.loadDocument(noteID: alternateID), let other = loaded.content.document,
              other.isWritableByThisBuild else {
            return .refused(String(localized: "That note can't be merged here"))
        }
        // Slice 2 (S10): the other note's files move with its writing, through
        // the transfer path (their rows change owner in the same commit). The
        // combined note must stay within the limits.
        let moving = Set(other.attachmentIDs)
        let ownShown = Set(notes.store.loadDocument(noteID: session.noteID)?.content.document?.attachmentIDs ?? [])
        if !moving.isEmpty {
            guard ownShown.union(moving).count <= AttachmentLimits.maxAttachmentsPerNote else {
                return .refused(String(localized: "The merged note would exceed 20 files: keep it as a separate note"))
            }
            var sizes: [UUID: Int64] = [:]
            for row in notes.store.attachments(for: alternateID) + notes.store.attachments(for: session.noteID)
            where moving.contains(row.id) || ownShown.contains(row.id) { sizes[row.id] = max(sizes[row.id] ?? 0, row.byteCount) }
            guard sizes.values.reduce(0, +) <= AttachmentLimits.maxBytesPerNote else {
                return .refused(String(localized: "The merged note would exceed 100 MB: keep it as a separate note"))
            }
        }
        let ownID = session.noteID
        let engine = session.engine
        guard engine.textView?.hasMarkedText() != true, engine.activity == .idle else {
            return .refused(String(localized: "Finish typing first"))
        }
        let source = NSAttributedString(attributedString: engine.textStorage)
        guard notes.settleForWorkspaceOperation(session), source.isEqual(to: engine.textStorage),
              let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else {
            return .refused(String(localized: "Couldn't save the note first"))
        }
        // Its body (block 0 is its title snapshot or title), after this
        // note's body. The whole body is encoded at once, so every line has
        // the spacing the editor gives it in place (a line after a file card
        // differs), and the step's Undo finds exactly what was installed.
        let body = Array(other.blocks.dropFirst())
        var own = Array(engine.document().blocks.dropFirst())
        if own.count == 1, own[0].kind == .text, own[0].text.isEmpty { own = [] }
        let candidate = NSMutableAttributedString(attributedString: engine.bodyText(for: own + body))
        let selection = engine.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let edit = TaskNoteTextEdit(engine: engine, session: session, notes: notes, tasks: tasks,
                                    coordinator: coordinator, history: page.history, noteID: session.noteID,
                                    parentID: taskID, selectionBefore: selection, caretAfter: selection.location)
        func stageDeleted(_ deleted: Bool, in commit: ModelContext) throws {
            let rows = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == alternateID }))
            guard !rows.isEmpty else { throw WorkspaceFoundationError.conflict }
            WorkspaceLegacyBridge.prepareMutations(rows, in: commit)
            let now = Date()
            for row in rows { row.deletedAt = deleted ? now : nil; row.deletedAttachmentIDsRaw = nil }
        }
        /// The transfer path: every physical replica of each moved file
        /// changes owner, shown in its new note; nothing is copied or deleted.
        let movingIDs = Array(moving)
        func transfer(into merged: Bool, in commit: ModelContext) throws {
            guard !movingIDs.isEmpty else { return }
            let rows = try commit.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { movingIDs.contains($0.id) }))
            let from = merged ? alternateID : ownID, to = merged ? ownID : alternateID
            guard Set(rows.map(\.id)) == moving, rows.allSatisfy({ $0.noteID == from }) else { throw WorkspaceFoundationError.conflict }
            WorkspaceLegacyBridge.prepareMutations(rows, in: commit)
            let now = Date()
            for row in rows { row.noteID = to; row.deletedAt = nil; row.updatedAt = now }
        }
        let entry = UUID()
        let owner = WorkspaceOwner(entity: .note, id: alternateID)
        let writes = Set([owner] + movingIDs.map { WorkspaceOwner(entity: .attachment, id: $0) })
        let outcome = await edit.perform(name: String(localized: "Merge Notes"), candidate: candidate, entryID: entry,
            forwardWrites: writes, forward: { try transfer(into: true, in: $0); try stageDeleted(true, in: $0) },
            inverse: { redo in
                TaskNoteTextEdit.TaskStep(writes: writes, check: { context in
                    let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == alternateID }))
                    guard !rows.isEmpty, rows.allSatisfy({ ($0.deletedAt == nil) == redo }) else { throw WorkspaceFoundationError.conflict }
                    let files = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { movingIDs.contains($0.id) }))
                    guard files.allSatisfy({ $0.noteID == (redo ? alternateID : ownID) }) else { throw WorkspaceFoundationError.conflict }
                }, preservations: [:], stage: { commit, _ in
                    try transfer(into: redo, in: commit)
                    try stageDeleted(redo, in: commit)
                })
            })
        switch outcome {
        case .committed, .publicationPending:
            notes.store.refresh()
            model.alternateNotes.removeAll { $0 == alternateID }
            return .made(entryID: entry, count: 0, kept: 0)
        case .notCommitted, .conflict, .unknown:
            return .refused(String(localized: "Couldn't merge the notes"))
        }
    }
}

/// One workspace operation that changes a task's note's writing together
/// with task rows (S1, S11). The forward commit and its replays share the
/// write gate, the journal, the session's adoption of the new revision and
/// the caret rules.
@MainActor
struct TaskNoteTextEdit {
    /// The task half of a replay: what it guards, writes and stages.
    struct TaskStep {
        let writes: Set<WorkspaceOwner>
        let check: (ModelContext) throws -> Void
        /// A soft deletion's new preservation records, by task.
        let preservations: [UUID: UUID]
        let stage: (ModelContext, [UUID: UUID]) throws -> Void
        /// Tasks this step restores from Recently Deleted: their open
        /// preservation records retire in the same commit.
        var restores: Set<UUID> = []
    }

    let engine: NoteEditorEngine
    let session: NoteSession
    let notes: NotesPageController
    let tasks: TaskStore
    let coordinator: WorkspaceOperationCoordinator
    let history: WorkspaceHistory
    let noteID: UUID
    let parentID: UUID
    let selectionBefore: NSRange
    let caretAfter: Int
    /// The note does not exist yet: the forward commit creates it (and its
    /// association) from the page's never-saved draft (§ 2.1).
    var createsNote = false

    func perform(name: String, candidate: NSAttributedString, entryID: UUID,
                 forwardWrites: Set<WorkspaceOwner>,
                 forward: @escaping (ModelContext) throws -> Void,
                 inverse: @escaping (_ redo: Bool) throws -> TaskStep) async -> WorkspaceOperationCoordinator.Outcome {
        let agent = AgentWorkspaceCall.current
        let adapter = engine.history
        let revision = UUID()
        let associationID = UUID()
        let binding = session.callbackStamp
        let noteID = noteID, parentID = parentID, selectionBefore = selectionBefore, caretAfter = caretAfter, createsNote = createsNote
        var group: WorkspaceHistory.TextGroup?
        let edit = self
        let outcome = await history.performCommand(using: coordinator) {
            guard let command = adapter.prepareCommand(candidate, name: name) else { throw WorkspaceFoundationError.conflict }
            group = WorkspaceHistory.TextGroup(adapter: adapter, payload: command.payload)
            let document = edit.engine.document(forCommand: command.candidate)
            let prepared = try PreparedNoteDocument(document)
            let context = edit.coordinator.freshContext()
            let id = edit.noteID
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
            guard edit.createsNote ? rows.isEmpty : !rows.isEmpty else { throw WorkspaceFoundationError.conflict }
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            var writes = forwardWrites.union([.init(entity: .note, id: id)]).union(versions.values.map { .init(entity: .version, id: $0) })
            if edit.createsNote { writes.formUnion([.init(entity: .association, id: associationID), .init(entity: .task, id: edit.parentID)]) }
            let baseEnvelope = try edit.coordinator.newEnvelope(intent: name, reads: edit.coordinator.capture(writes.union([.init(entity: .task, id: edit.parentID)])),
                writes: writes, afterDocuments: [id: prepared.content],
                historyEffect: WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: edit.history.id, entryID: entryID)))
            let envelope = try agent?.guarded(baseEnvelope, coordinator: edit.coordinator) ?? baseEnvelope
            return .init(entryID: entryID, envelope: envelope, sessionValid: { adapter.canInstallCommand(command) && (agent?.valid() ?? true) }, stage: { commit in
                try forward(commit)
                if edit.createsNote {
                    try edit.stageNoteCreation(in: commit, prepared: prepared, document: document, revision: revision, associationID: associationID)
                } else {
                    try NoteStore.stageDocument(in: commit, noteID: id, document: document, prepared: prepared,
                        revisionID: revision, versionIDs: versions, timestamp: Date())
                }
                try agent?.stageResolution(in: commit)
            }, record: { [weak notes, weak session, weak engine, weak tasks, weak coordinator, weak history] operation, entry in
                guard let group, let notes, let session, let engine, let tasks, let coordinator, let history else { return }
                let recording = TaskNoteTextEdit(engine: engine, session: session, notes: notes, tasks: tasks,
                    coordinator: coordinator, history: history, noteID: noteID, parentID: parentID,
                    selectionBefore: selectionBefore, caretAfter: caretAfter, createsNote: createsNote)
                recording.record(operation: operation, entry: entry, name: name, group: group,
                    taskOwners: forwardWrites.filter { $0.entity == .task || $0.entity == .note }, inverse: inverse)
            }, publication: .init(steps: [{ [weak notes, weak session, weak engine, weak tasks, weak history, weak adapter] _ in
                defer { tasks?.refresh() }
                guard let notes, let session, let engine, let history, let adapter,
                      session.hasSameBinding(binding), session.engine === engine,
                      !history.hasNewerPublicationDraft else { return }
                guard adapter.installCommand(command) else { throw WorkspaceFoundationError.conflict }
                engine.textView?.setSelectedRange(NSRange(location: min(caretAfter, engine.textStorage.length), length: 0))
                notes.adoptWorkspaceCommit(session, revisionID: revision, created: createsNote)
            }]))
        }
        agent?.observe(outcome)
        return outcome
    }

    /// A new own note from the page's draft, with its association, in the
    /// operation's one save (the store's lazy creation, staged).
    private func stageNoteCreation(in commit: ModelContext, prepared: PreparedNoteDocument, document: NoteDocument,
                                   revision: UUID, associationID: UUID) throws {
        guard let generation = NoteStore.taskOwnerGeneration(parentID, in: commit) else { throw WorkspaceFoundationError.conflict }
        let now = Date()
        let note = NoteItem(id: noteID, createdAt: now, updatedAt: now)
        NoteStore.stageDocumentContent(prepared, format: document.format, on: [note], timestamp: now, revision: 0, revisionID: revision)
        note.taskID = parentID
        commit.insert(note)
        let association = TaskNoteAssociation(id: associationID, taskID: parentID, noteID: noteID)
        association.taskGeneration = generation
        association.noteGeneration = note.associationGeneration
        commit.insert(association)
    }

    private func record(operation: UUID, entry: UUID, name: String, group: WorkspaceHistory.TextGroup, taskOwners: Set<WorkspaceOwner>,
                        inverse: @escaping (Bool) throws -> TaskStep) {
        let noteID = noteID, parentID = parentID, caretAfter = caretAfter, selectionBefore = selectionBefore
        var expected = try? coordinator.capture(taskOwners)
        let scopes = Set(taskOwners.filter { $0.entity == .task }.flatMap { [WorkspaceScope.children($0.id), .taskAssociations($0.id)] })
        var expectedScopes = try? WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext())
        let history = history
        history.recordOperation(id: operation, entryID: entry, name: name, coordinator: coordinator, textGroup: group) { [weak session, weak notes, weak tasks, weak coordinator, weak history] redo, effect in
            guard let notes, let tasks, let coordinator, let history,
                  let session = notes.workspaceSessionIfCached(noteID) ?? session,
                  let guards = expected, let scopeGuards = expectedScopes,
                  try WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext()) == scopeGuards else {
                throw WorkspaceFoundationError.conflict
            }
            let engine = session.engine
            let current = try coordinator.capture(taskOwners)
            // Task timestamps are refreshed by normal field Undo. Every
            // semantic field and every physical identity must still agree.
            func semantic(_ tokens: [WorkspaceModelToken]) -> [WorkspaceModelToken] {
                tokens.map { token in
                    .init(owner: token.owner, replicas: token.replicas.map { replica in
                        var fields = replica.fields
                        if token.owner.entity == .task { fields.removeValue(forKey: "updatedAt") }
                        return .init(physicalID: replica.physicalID, fields: fields)
                    })
                }
            }
            guard semantic(current) == semantic(guards) else { throw WorkspaceFoundationError.conflict }
            let adapter = group.adapter
            let step = try inverse(redo)
            let context = coordinator.freshContext()
            try step.check(context)
            guard let text = adapter.prepareReplay(redo ? group.payloads : group.payloads.reversed().map { $0 }) else {
                throw WorkspaceFoundationError.conflict
            }
            let document = text.document ?? engine.document(forCommand: text.candidate)
            let prepared = try PreparedNoteDocument(document)
            let id = noteID
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
            guard !rows.isEmpty else { throw WorkspaceFoundationError.conflict }
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            var writes = step.writes.union([.init(entity: .note, id: id)]).union(versions.values.map { .init(entity: .version, id: $0) })
            writes.formUnion(step.preservations.values.map { .init(entity: .preservation, id: $0) })
            if !step.restores.isEmpty {
                writes.formUnion(try context.fetch(FetchDescriptor<TaskDeletionPreservation>())
                    .filter { step.restores.contains($0.rootID) && $0.retiredAt == nil }
                    .map { .init(entity: .preservation, id: $0.id) })
            }
            let envelope = try coordinator.newEnvelope(intent: "Replay " + name,
                reads: coordinator.capture(writes.union([.init(entity: .task, id: parentID)])), writes: writes, inverseGuards: current, scopes: Array(scopeGuards.values),
                afterDocuments: [id: prepared.content], historyEffect: WorkspaceModelFields.encode(effect), replayOf: operation)
            let revision = UUID()
            let binding = session.callbackStamp
            return .init(envelope: envelope, text: (adapter, text), textDocument: (id, prepared.content), stage: { commit in
                try step.stage(commit, step.preservations)
                try NoteStore.stageDocument(in: commit, noteID: id, document: document, prepared: prepared,
                    revisionID: revision, versionIDs: versions, timestamp: Date())
            }, publication: .init(steps: [{ [weak notes, weak session, weak engine, weak tasks, weak coordinator, weak history] _ in
                // Undo puts the selection back as it was; Redo leaves the
                // caret where the text was.
                if let notes, let session, let engine, let history,
                   session.hasSameBinding(binding), session.engine === engine, !history.hasNewerPublicationDraft {
                    let length = engine.textStorage.length
                    let selection = redo ? NSRange(location: min(caretAfter, length), length: 0)
                        : NSRange(location: min(selectionBefore.location, length),
                                  length: max(0, min(selectionBefore.length, length - min(selectionBefore.location, length))))
                    engine.textView?.setSelectedRange(selection)
                    notes.adoptWorkspaceCommit(session, revisionID: revision)
                }
                tasks?.refresh()
                if let coordinator {
                    expected = try coordinator.capture(taskOwners)
                    expectedScopes = try WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext())
                }
            }]))
        }
    }
}
