import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 3 slice 1, "the association and its lifecycle" (UX plan § 2.3.3,
/// § 2.6, § 2.7, § 2.10, § 5.9; S1, S10, S11): the producers, the delete
/// matrices and the restore rules, headless on in-memory stores.
@MainActor
final class TaskLifecycleSliceTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var library: AtticLibrary!
    private var notes: NotesPageController!
    private var coordinator: WorkspaceOperationCoordinator!
    private var windows: [NSWindow] = []
    private var presenters: [TaskNotePresenter] = []
    private let panel = NSSize(width: 320, height: 520)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
    }

    override func tearDown() async throws {
        for presenter in presenters where presenter.lease != nil { _ = await presenter.close() }
        presenters.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        notes = nil; library = nil; tasks = nil; coordinator = nil; container = nil
    }

    // MARK: Fixtures

    @discardableResult
    private func seed(_ scenario: TaskNotePreviewSeed.Scenario) throws -> UUID {
        let id = try TaskNotePreviewSeed.seed(scenario, in: container)
        makeStores()
        return id
    }

    private func makeStores() {
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("TaskLifecycle-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: files) }
        tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: files))
        library = AtticLibrary(tasks: tasks)
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
    }

    private func open(_ taskID: UUID) throws -> TaskNotePresenter {
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: notes,
                                              design: .default, columnInset: 28, defaults: nil)
        presenters.append(presenter)
        let host = presenter.host
        host.setContentInsets(top: 76, bottom: 60)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.scrollView.frame = NSRect(origin: .zero, size: panel)
        window.contentView = host.scrollView
        windows.append(window)
        host.restack()
        settle(host.textView)
        return presenter
    }

    private func close(_ presenter: TaskNotePresenter) async {
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        presenters.removeAll { $0 === presenter }
    }

    private func settle(_ textView: NSTextView) {
        textView.window?.contentView?.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.window?.displayIfNeeded()
        RunLoop.main.run(until: Date())
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.window?.makeFirstResponder(textView)
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(textView)
        }
    }

    private func rows(_ id: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
    }

    private func ownNotes(_ taskID: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).filter { $0.taskID == taskID }
    }

    private func associations(note noteID: UUID) throws -> [TaskNoteAssociation] {
        try ModelContext(container).fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.noteID == noteID }
    }

    private func storedDocument(_ id: UUID) throws -> NoteDocument {
        let row = try XCTUnwrap(rows(id).first)
        return try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
    }

    // MARK: The row's note glyph (p3-06, D11) and "note kept" (§ 2.7.1)

    func testARowShowsTheNoteGlyphOnlyWhileItsTaskHasALiveOwnNote() throws {
        let id = try seed(.boundary)
        let model = TasksPageModel(library: library)
        XCTAssertFalse(try XCTUnwrap(model.rows(for: .now).first { $0.id == id }).model.hasPage, "no owners known yet")
        model.setNoteOwners([id])
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == id })
        XCTAssertTrue(row.model.hasPage, "the doc.text glyph after the subtask count")
        XCTAssertTrue(row.model.hasDetails)
        XCTAssertTrue(row.model.accessibilityDescription.hasSuffix("has a note"))
        model.setNoteOwners([])
        XCTAssertFalse(try XCTUnwrap(model.rows(for: .now).first { $0.id == id }).model.hasPage, "the note left: so does the glyph")
    }

    func testDeletingATaskRowIsInstantAndItsToastSaysTheNoteIsKept() throws {
        let id = try seed(.boundary)
        let other = try XCTUnwrap(tasks.create(title: "No note here"))
        let model = TasksPageModel(library: library)
        model.setNoteOwners([id])
        XCTAssertTrue(model.delete([id]).isApplied, "⌫ on a row never asks (P5)")
        XCTAssertEqual(model.toasts.current?.message, "Deleted “Finalize launch checklist” · note kept")
        XCTAssertNil(tasks.task(withID: id))
        XCTAssertFalse(try ownNotes(id).isEmpty, "the note stays")
        XCTAssertTrue(try ownNotes(id).allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(model.delete([other.id]).isApplied)
        XCTAssertEqual(model.toasts.current?.message, "Deleted “No note here”", "a task without a note reads as before")
    }

    // MARK: A deleted task's note from All notes (§ 2.7.2 row 1)

    func testADeletedTasksPageOpensInTheQuietDeletedStateWithItsSubtasksAsTheyWere() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(library.deleteTasks([id]).isApplied)
        let presenter = try open(id)
        let model = presenter.model
        XCTAssertFalse(model.head.exists, "the head reads Task deleted · Restore")
        XCTAssertEqual(model.head.title, "Finalize launch checklist", "the title as it was")
        XCTAssertEqual(model.rows.map(\.title), ["Write release notes", "Freeze strings"], "open, then done, read only")
        XCTAssertEqual(model.head.subtasks.done, 1)
        XCTAssertFalse(presenter.host.engine.isReadOnly, "the writing stays editable")
        XCTAssertTrue(model.restoreTask())
        XCTAssertTrue(model.head.exists, "Restore brings the live head back")
        XCTAssertNotNil(tasks.task(withID: id))
    }

    // MARK: "Write a new note" and Restore Note (§ 2.7.2)

    func testWritingWhileTheNoteIsInRecentlyDeletedStartsANewSeparateOwnNote() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: oldID)
        XCTAssertTrue(deleted)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.deletedNote)
        XCTAssertEqual(presenter.host.engine.bodyPlaceholder, "Write a new note")
        XCTAssertFalse(presenter.host.engine.isReadOnly)
        type("A fresh start", into: presenter.host.textView)
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(notes.save(session), "the first save creates the new own note")
        XCTAssertNotEqual(session.noteID, oldID)
        let live = try ownNotes(id).filter { $0.deletedAt == nil }
        XCTAssertEqual(Set(live.map(\.id)), [session.noteID], "exactly one live own note")
        XCTAssertTrue(try rows(oldID).allSatisfy { $0.deletedAt != nil }, "the old note stays in Recently Deleted")
        XCTAssertFalse(presenter.model.deletedNote, "the Restore Note line goes once the new note exists")
    }

    func testRestoreNoteWhileTheTaskHasANewerNoteReturnsItAsAnOrdinaryNote() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: oldID)
        XCTAssertTrue(deleted)
        let presenter = try open(id)
        type("Newer", into: presenter.host.textView)
        let newID = try XCTUnwrap(presenter.session?.noteID)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        let restored = try XCTUnwrap(notes.restoreTaskNote(noteID: oldID))
        XCTAssertTrue(restored.separate, "toast: Note restored as a separate note")
        let old = try rows(oldID)
        XCTAssertTrue(old.allSatisfy { $0.deletedAt == nil && $0.taskID == nil }, "an ordinary note now")
        let document = try storedDocument(oldID)
        XCTAssertFalse(document.requires.contains("taskNote"), "materialized (§ 2.12)")
        XCTAssertEqual(document.title, "Finalize launch checklist", "block 0 carries the task's title")
        XCTAssertEqual(old.first?.tags, ["launch"], "the task's tags are copied")
        XCTAssertTrue(try associations(note: oldID).allSatisfy { $0.detachedAt != nil }, "its association is cleared")
        let reopened = try open(id)
        XCTAssertEqual(reopened.session?.noteID, newID, "the newer note stays the task's own note")
        XCTAssertFalse(reopened.model.deletedNote)
    }

    func testRestoreNoteIsItsOwnUndoStep() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: noteID)
        XCTAssertTrue(deleted)
        let restored = try XCTUnwrap(notes.restoreTaskNote(noteID: noteID))
        XCTAssertFalse(restored.separate, "the slot was free: it returns as the own note")
        XCTAssertEqual(restored.stepID, notes.undoRoute.undoStepID(in: .notesLibrary))
        XCTAssertEqual(notes.undoRoute.undoName(in: .notesLibrary), "Restore Note")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
        XCTAssertTrue(notes.undoRoute.undo(in: .notesLibrary), "Undo sends it back to Recently Deleted")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(notes.undoRoute.redo(in: .notesLibrary))
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
    }

    func testARestoredSeparateNoteCanBeDeletedAndRestoredAgain() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        _ = await notes.deleteNoteDurably(noteID: oldID)
        let presenter = try open(id)
        type("Newer", into: presenter.host.textView)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        XCTAssertEqual(notes.restoreTaskNote(noteID: oldID)?.separate, true)
        let again = await notes.deleteNoteDurably(noteID: oldID)
        XCTAssertTrue(again)
        XCTAssertTrue(notes.store.restoreDeleted(noteID: oldID), "an ordinary note restores as one")
        XCTAssertTrue(try rows(oldID).allSatisfy { $0.deletedAt == nil && $0.taskID == nil })
    }

    // MARK: Make Subtask ⌥⌘S (§ 2.3.3)

    private func attributed(_ paragraphs: [String]) -> NSMutableAttributedString {
        NSMutableAttributedString(string: paragraphs.joined(separator: "\n"))
    }

    func testTheSelectionTableForMakeSubtask() {
        let text = attributed(["Alpha line", "", "Bravo line", "Charlie line"])
        // A caret: the caret's whole paragraph.
        var analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Alpha line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "\nBravo line\nCharlie line")
        XCTAssertEqual(analysis.candidate(from: text).caret, 0, "the caret stays where the text was")
        // Part of one paragraph: the selected text only; the rest stays.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 6, length: 4))
        XCTAssertEqual(analysis.pieces.map(\.title), ["line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha \n\nBravo line\nCharlie line")
        // Several paragraphs: partial ends give their part; an empty
        // paragraph wholly selected goes; one subtask per paragraph, in order.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 6, length: 22))
        XCTAssertEqual(analysis.pieces.map(\.title), ["line", "Bravo line", "Charl"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha \nie line")
        // The last paragraph takes the break before it: no empty line left.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: text.length - 2, length: 0))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Charlie line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha line\n\nBravo line")
        // A caret on an empty paragraph makes nothing.
        XCTAssertTrue(TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 11, length: 0)).isEmpty)
    }

    func testANoteCheckboxGivesItsTextAndACheckedBoxACompletedSubtask() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: true)))
        text.append(NSAttributedString(string: "Shipped it\n"))
        text.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: false)))
        text.append(NSAttributedString(string: "Still to do"))
        let analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Shipped it", "Still to do"])
        XCTAssertEqual(analysis.pieces.map(\.isDone), [true, false])
        XCTAssertEqual(analysis.candidate(from: text).text.length, 0, "both lines leave the writing")
    }

    func testLinesWithLinksOrStylesAreAskedAboutAndKeptWhenMade() {
        let text = attributed(["Plain line", "Styled line"])
        text.addAttribute(.noteMark(.bold), value: true, range: NSRange(location: 11, length: 6))
        let analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Plain line", "Styled line"])
        XCTAssertEqual(analysis.richCount, 1, "the pop-over counts 1 line")
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Styled line", "Keep Original: the styled line stays unchanged")
        let linked = attributed(["See the doc"])
        linked.addAttribute(.noteMark(.link), value: "https://example.com", range: NSRange(location: 4, length: 3))
        XCTAssertEqual(TaskNoteSubtaskSelection.analyse(linked, selection: NSRange(location: 0, length: 0)).richCount, 1)
    }

    private func makeSubtaskFixture() throws -> (UUID, TaskNotePresenter, NoteSession) {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        return (id, presenter, session)
    }

    func testMakeSubtaskMovesTheCaretsParagraphIntoTheBlockInOneCommitAndUndoRestoresTheExactSource() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        let before = NSAttributedString(attributedString: textView.textStorage!)
        XCTAssertEqual(before.string, "Everything that has to be true before 1.0 goes out.\nSam owns the pricing page; I take the checklist.")
        textView.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case let .made(entryID, count, kept) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(count, 1); XCTAssertEqual(kept, 0)
        let subtasks = tasks.subtasks(of: id)
        XCTAssertEqual(subtasks.map(\.title), ["Write release notes", "Sam owns the pricing page; I take the checklist.", "Freeze strings"],
                       "a new open subtask joins the end of the open group")
        XCTAssertEqual(textView.string, "Everything that has to be true before 1.0 goes out.")
        XCTAssertEqual(textView.selectedRange().location, textView.string.utf16.count, "the caret stays where the text was")
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks.dropFirst().map(\.text), ["Everything that has to be true before 1.0 goes out."],
                       "the writing changed in the same commit")
        XCTAssertEqual(stored.blocks.first?.text, "Finalize launch checklist", "block 0 stays the compatibility title")
        XCTAssertEqual(session.state, .clean, "the session took the commit's revision as its base")
        XCTAssertEqual(presenter.page.history.undoName, "Make Subtask")
        XCTAssertEqual(presenter.model.rows.count, 3)
        // Undo: the exact attributed source, in place, with its selection.
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(textView.textStorage!.isEqual(to: before), "the exact attributed source returns")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 60, length: 0))
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "the subtask leaves (to Recently Deleted)")
        XCTAssertEqual(try storedDocument(session.noteID).blocks.dropFirst().count, 2)
        XCTAssertEqual(session.state, .clean)
        // Redo makes it again, the same record.
        let redone = await presenter.page.history.replay(redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertEqual(tasks.subtasks(of: id).count, 3)
        XCTAssertEqual(textView.string, "Everything that has to be true before 1.0 goes out.")
    }

    func testMakeSubtaskOfACheckedBoxMakesACompletedSubtask() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        // A checked note checkbox at the end of the writing.
        let storage = try XCTUnwrap(textView.textStorage)
        let box = NSMutableAttributedString(string: "\n", attributes: storage.attributes(at: 0, effectiveRange: nil))
        box.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: true)))
        box.append(NSAttributedString(string: "Book the venue", attributes: storage.attributes(at: 0, effectiveRange: nil)))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText(box, replacementRange: NSRange(location: storage.length, length: 0))
        XCTAssertTrue(notes.save(session))
        textView.setSelectedRange(NSRange(location: storage.length - 2, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        XCTAssertEqual(analysis.pieces.map(\.isDone), [true])
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case .made = result else { return XCTFail("\(result)") }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title == "Book the venue" })
        XCTAssertEqual(made.status, .done, "a checked box gives a completed subtask")
        XCTAssertFalse(textView.string.contains("Book the venue"))
    }

    func testMakeSubtaskRefusesInADeletedTaskAndOutsideATasksNote() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        XCTAssertNil(presenter.makeSubtaskUnavailableReason(tasks: tasks))
        XCTAssertTrue(library.deleteTasks([id]).isApplied)
        XCTAssertEqual(presenter.makeSubtaskUnavailableReason(tasks: tasks), "The task is deleted")
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        XCTAssertEqual(result, .refused("The task is deleted"))
        XCTAssertEqual(presenter.host.textView.string.components(separatedBy: "\n").count, 2, "nothing moved")
    }

    /// Failure injection (S1): a refused save leaves the writing, the
    /// subtasks, the stored note and the history untouched.
    func testAFailedMakeSubtaskSaveChangesNothing() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        let before = NSAttributedString(attributedString: textView.textStorage!)
        let storedBefore = try storedDocument(session.noteID)
        let historyBefore = presenter.page.history.undoName
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(result, .refused("Couldn't make the subtask"))
        XCTAssertTrue(textView.textStorage!.isEqual(to: before), "the writing is untouched")
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "no subtask was made")
        XCTAssertEqual(try storedDocument(session.noteID), storedBefore, "the stored note is untouched")
        XCTAssertEqual(presenter.page.history.undoName, historyBefore, "no history entry")
        XCTAssertEqual(session.state, .clean)
        // The same command then works.
        let retried = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case .made = retried else { return XCTFail("\(retried)") }
    }

    func testUndoOfMakeSubtaskRefusesOnceTheSubtaskWasRenamed() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        guard case let .made(entryID, _, _) = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title.hasPrefix("Everything") })
        // Renamed elsewhere (not through this page's history).
        XCTAssertTrue(tasks.rename(made, to: "Renamed"))
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .failed, "Can't undo: the subtask changed since")
        XCTAssertEqual(tasks.subtasks(of: id).first { $0.id == made.id }?.title, "Renamed", "nothing changed")
        XCTAssertFalse(presenter.host.textView.string.hasPrefix("Everything"))
    }

    // MARK: Make Note Checkbox (§ 2.3.3)

    func testMakeNoteCheckboxPutsTheTitleAtTheTopAndKeepsTheWholeRecordForUndo() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let subtask = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title == "Write release notes" })
        XCTAssertTrue(tasks.update(subtask, tags: ["copy"], dueDay: .some(DueDay(date: Date().addingTimeInterval(86_400 * 3), calendar: .current))))
        let subtaskID = subtask.id
        let before = NSAttributedString(attributedString: presenter.host.textView.textStorage!)
        let result = await presenter.makeNoteCheckbox(subtaskID: subtaskID, tasks: tasks, notes: notes)
        guard case let .madeCheckbox(entryID, recovery) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(recovery, "its date and 1 tag are in Recently Deleted")
        XCTAssertNil(tasks.task(withID: subtaskID), "the subtask went to Recently Deleted in the same commit")
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks[1].kind, .checklist, "a note checkbox at the top of the writing")
        XCTAssertEqual(stored.blocks[1].text, "Write release notes")
        XCTAssertEqual(stored.blocks[1].checked, false)
        let records = try ModelContext(container).fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.rootID == subtaskID }
        XCTAssertEqual(records.count, 1, "the complete record is in the operation's recovery record")
        XCTAssertEqual(session.state, .clean)
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        let back = try XCTUnwrap(tasks.task(withID: subtaskID), "Undo brings the same record back")
        XCTAssertEqual(back.title, "Write release notes")
        XCTAssertEqual(back.tags, ["copy"])
        XCTAssertNotNil(back.dueDay)
        XCTAssertTrue(presenter.host.textView.textStorage!.isEqual(to: before))
        let redone = await presenter.page.history.replay(redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertNil(tasks.task(withID: subtaskID))
    }

    func testMakeNoteCheckboxCreatesTheNoteWhenTheTaskHasNone() async throws {
        let id = try seed(.nonote)
        let subtask = try XCTUnwrap(tasks.create(title: "Call the venue", parentID: id))
        let presenter = try open(id)
        XCTAssertTrue(try ownNotes(id).isEmpty)
        let session = try XCTUnwrap(presenter.session)
        let result = await presenter.makeNoteCheckbox(subtaskID: subtask.id, tasks: tasks, notes: notes)
        guard case .madeCheckbox = result else { return XCTFail("\(result)") }
        let own = try ownNotes(id)
        XCTAssertEqual(own.map(\.id), [session.noteID], "the page's draft became the task's own note, in the commit")
        XCTAssertTrue(session.isPersisted)
        XCTAssertEqual(try associations(note: session.noteID).filter { $0.detachedAt == nil }.map(\.taskID), [id])
        XCTAssertEqual(try storedDocument(session.noteID).blocks.dropFirst().first?.text, "Call the venue")
        XCTAssertNil(tasks.task(withID: subtask.id))
        XCTAssertEqual(session.state, .clean)
    }

    func testAFailedMakeNoteCheckboxSaveChangesNothing() async throws {
        let id = try seed(.nonote)
        let subtask = try XCTUnwrap(tasks.create(title: "Call the venue", parentID: id))
        let presenter = try open(id)
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let result = await presenter.makeNoteCheckbox(subtaskID: subtask.id, tasks: tasks, notes: notes)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(result, .refused("Couldn't make the note checkbox"))
        XCTAssertNotNil(tasks.task(withID: subtask.id), "the subtask stays")
        XCTAssertTrue(try ownNotes(id).isEmpty, "no note was created")
        XCTAssertEqual(presenter.session?.isPersisted, false)
        XCTAssertEqual(presenter.host.textView.string, "", "the writing is untouched")
    }

    // MARK: S10: two notes claim one task

    /// A second live note claiming the task (as a replica merge could
    /// leave), made after the seeded one.
    private func addAlternate(to taskID: UUID, body: String = "Notes from the other Mac") throws -> UUID {
        let context = ModelContext(container)
        let id = UUID()
        let note = NoteItem(id: id, createdAt: Date().addingTimeInterval(3_600), updatedAt: Date().addingTimeInterval(3_600))
        note.taskID = taskID
        let document = try NoteDocument(blocks: [.text("Finalize launch checklist"), .text(body)]).taskSnapshot(title: "Finalize launch checklist")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note)
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: id))
        try context.save()
        return id
    }

    func testTwoNotesClaimingOneTaskOpenTheOlderAndOfferTheOtherForReview() async throws {
        let id = try seed(.boundary)
        let own = try XCTUnwrap(try ownNotes(id).first?.id)
        let alternate = try addAlternate(to: id)
        makeStores()
        let presenter = try open(id)
        XCTAssertEqual(presenter.session?.noteID, own, "(createdAt, UUID): the older note is the task's note")
        XCTAssertEqual(presenter.model.alternateNotes, [alternate], "Another note for this task · Review")
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == id }, "nothing merges by itself")
    }

    func testKeepAsSeparateNoteMakesTheAlternateAnOrdinaryNote() async throws {
        let id = try seed(.boundary)
        let alternate = try addAlternate(to: id)
        makeStores()
        XCTAssertTrue(notes.store.keepAsSeparateNote(noteID: alternate))
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == nil })
        XCTAssertFalse(try storedDocument(alternate).requires.contains("taskNote"))
        XCTAssertEqual(try storedDocument(alternate).blocks.last?.text, "Notes from the other Mac", "its writing is kept")
        XCTAssertTrue(try associations(note: alternate).allSatisfy { $0.detachedAt != nil })
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.alternateNotes.isEmpty)
        XCTAssertFalse(notes.store.keepAsSeparateNote(noteID: try XCTUnwrap(presenter.session?.noteID)),
                       "the task's only note is never separated")
    }

    func testMergeIntoThisNoteJoinsTheWritingInOneStepAndUndoSplitsThemAgain() async throws {
        let id = try seed(.boundary)
        let alternate = try addAlternate(to: id)
        makeStores()
        let presenter = try open(id)
        let before = NSAttributedString(attributedString: presenter.host.textView.textStorage!)
        let result = await presenter.mergeAlternate(alternate, tasks: tasks, notes: notes)
        guard case let .made(entryID, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(presenter.host.textView.string.hasSuffix("\nNotes from the other Mac"))
        XCTAssertEqual(try storedDocument(try XCTUnwrap(presenter.session?.noteID)).blocks.last?.text, "Notes from the other Mac")
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt != nil }, "the other note goes to Recently Deleted")
        XCTAssertTrue(presenter.model.alternateNotes.isEmpty)
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(presenter.host.textView.textStorage!.isEqual(to: before))
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
    }

    // MARK: Purge through an open session (§ 2.7.2)

    func testPurgingADeletedTaskMakesItsClosedNoteOrdinaryInOneTransaction() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(library.deleteTasks([id]).isApplied)
        XCTAssertTrue(tasks.purgeDeleted(before: .distantFuture).isEmpty, "the legacy collector leaves a family with a note")
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertEqual(report.materializedNoteIDs, [noteID])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })), 0)
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == nil && $0.deletedAt == nil })
        let document = try storedDocument(noteID)
        XCTAssertFalse(document.requires.contains("taskNote"))
        XCTAssertEqual(document.title, "Finalize launch checklist")
        XCTAssertEqual(document.blocks.dropFirst().first?.text, "Everything that has to be true before 1.0 goes out.")
    }

    func testPurgeWhileTheTasksPageIsOpenMergesItsUnsavedWritingAndTheNoteBecomesOrdinary() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(presenter.model.deleteTask())
        presenter.host.textView.setSelectedRange(NSRange(location: presenter.host.textView.string.utf16.count, length: 0))
        type(" Still writing.", into: presenter.host.textView)
        XCTAssertNotEqual(session.state, .clean, "unsaved writing")
        var materialized: [UUID] = []
        notes.taskNoteMaterialized = { patch, _ in materialized.append(patch.noteID) }
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertEqual(materialized, [session.noteID], "the page is told to leave")
        let document = try storedDocument(session.noteID)
        XCTAssertTrue(document.blocks.map(\.text).contains("Sam owns the pricing page; I take the checklist. Still writing."),
                      "the draft is merged, never replaced by stored content")
        XCTAssertFalse(document.requires.contains("taskNote"))
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == nil })
        XCTAssertEqual(session.state, .clean, "what the editor shows is what the purge saved")
        await close(presenter)
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == nil }, "leaving never writes the task note back")
        XCTAssertFalse(try storedDocument(session.noteID).requires.contains("taskNote"))
    }

    func testPurgeWaitsWhileTheOpenNoteIsComposing() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.deleteTask())
        let textView = presenter.host.textView
        textView.window?.makeFirstResponder(textView)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertEqual(report.deferredRootIDs, [id], "IME composition: the purge waits for a later cleanup")
        XCTAssertTrue(report.removedTaskIDs.isEmpty)
        XCTAssertTrue(try ownNotes(id).allSatisfy { $0.taskID == id }, "nothing was written")
        textView.unmarkText()
    }

    // MARK: The family contract (§ 2.6)

    func testCompletingTheTaskOnItsPageCompletesItsOpenSubtasksAndKeepsThePage() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        XCTAssertEqual(tasks.task(withID: id)?.status, .done)
        XCTAssertTrue(tasks.subtasks(of: id).allSatisfy { $0.status == .done }, "one family operation")
        presenter.model.refresh()
        XCTAssertEqual(presenter.model.head.state, .done)
        XCTAssertTrue(presenter.model.head.exists)
        XCTAssertNotNil(presenter.lease, "completing never navigates away")
        XCTAssertFalse(presenter.host.engine.isReadOnly, "the writing stays editable")
        XCTAssertEqual(TaskNotePage.completionMessage(subtasks: 1), "Task and 1 subtask completed")
    }

    func testDoneCleanupWithTheTaskPageOpenKeepsItsHeadSubtasksAndWriting() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        let cutoff = Date().addingTimeInterval(60)
        XCTAssertEqual(tasks.moveCompletedToDoneLog(before: cutoff), 3, "next-day cleanup moves the family to the Done log")
        presenter.model.refresh()
        XCTAssertTrue(presenter.model.head.exists, "a Done-log task still has its page")
        XCTAssertEqual(presenter.model.head.state, .done)
        XCTAssertEqual(presenter.model.rows.count, 2, "its subtasks stay on the page")
        XCTAssertFalse(try ownNotes(id).isEmpty)
        type(" More.", into: presenter.host.textView)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)), "the note stays editable")
    }

    func testADivergentDuplicateBlocksDoneCleanupWhileThePageIsOpen() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        // A second physical replica of the task that disagrees.
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        let replica = TaskItem(id: id, title: row.title + " (other Mac)", status: .done, createdAt: row.createdAt,
                               completedAt: row.completedAt, manualOrder: row.manualOrder)
        context.insert(replica)
        try context.save()
        tasks.refresh()
        XCTAssertEqual(tasks.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 0, "replicas must agree first")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).allSatisfy { $0.doneLoggedAt == nil })
        presenter.model.refresh()
        XCTAssertTrue(presenter.model.head.exists)
    }

    func testReopenTaskAndContinueUnticksASubtaskOfADoneTask() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        let sub = try XCTUnwrap(tasks.subtasks(of: id).first)
        XCTAssertTrue(presenter.model.needsReopen(toggling: sub.id), "unticking under a Done task asks first")
        XCTAssertTrue(presenter.model.reopenTask())
        XCTAssertNotEqual(tasks.task(withID: id)?.status, .done)
        XCTAssertTrue(presenter.model.toggle(sub.id))
        XCTAssertEqual(tasks.task(withID: sub.id)?.status, .todo)
        XCTAssertFalse(presenter.model.needsReopen(toggling: sub.id))
    }

    // MARK: Make Task from Note (§ 2.1)

    func testMakeTaskFromNoteMakesTheSameDocumentTheTasksOwnNoteAndUndoReturnsItAsItWas() async throws {
        makeStores()
        let noteID = UUID()
        let original = NoteDocument(blocks: [.text("Plan the offsite"), .text("Venue ideas"), .checklist("Ask Sam", checked: true)])
        guard case .success = notes.store.createDocumentNote(id: noteID, document: original, tags: ["team"]) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: noteID))
        let outcome = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks)
        guard case let .made(taskID) = outcome else { return XCTFail("\(outcome)") }
        let task = try XCTUnwrap(tasks.task(withID: taskID))
        XCTAssertEqual(task.title, "Plan the offsite")
        XCTAssertEqual(task.tags, ["team"], "the task takes the note's title and tags")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == taskID && $0.tags.isEmpty }, "same identity; its own tags go to the task")
        let stored = try storedDocument(noteID)
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(stored.blocks.dropFirst().map(\.kind), [.text, .checklist], "body checkboxes stay note checkboxes")
        XCTAssertEqual(try associations(note: noteID).filter { $0.detachedAt == nil }.map(\.taskID), [taskID])
        let presenter = try open(taskID)
        XCTAssertEqual(presenter.session?.noteID, noteID, "the same document is the task's page")
        await close(presenter)
        let undone = await notes.undoRoute.replay(in: .notesLibrary, redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertNil(tasks.task(withID: taskID), "Undo: the task goes to Recently Deleted")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == nil && $0.tags == ["team"] })
        XCTAssertEqual(try storedDocument(noteID), original, "the note returns exactly as it was")
        let redone = await notes.undoRoute.replay(in: .notesLibrary, redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertNotNil(tasks.task(withID: taskID), "Redo brings the same task back")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == taskID })
    }

    func testMakeTaskFromNoteRefusesATasksNoteAndAnUntitledNote() async throws {
        let id = try seed(.boundary)
        let own = try XCTUnwrap(try ownNotes(id).first?.id)
        let refused = await TaskNoteConversion.makeTask(fromNote: own, notes: notes, tasks: tasks)
        XCTAssertNotEqual(refused, .made(taskID: id), "a task's note never becomes a second task")
        XCTAssertTrue(try rows(own).allSatisfy { $0.taskID == id })
        let untitled = UUID()
        guard case .success = notes.store.createDocumentNote(id: untitled, document: NoteDocument(blocks: [.text(""), .text("body")])) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: untitled))
        let outcome = await TaskNoteConversion.makeTask(fromNote: untitled, notes: notes, tasks: tasks)
        XCTAssertEqual(outcome, .refused("Give the note a title first"))
        XCTAssertTrue(try rows(untitled).allSatisfy { $0.taskID == nil })
    }

    // MARK: Version History of a task's note (S4, § 2.10)

    func testVersionHistoryRestoresTheNoteOnlyNeverTheTaskOrItsSubtasks() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        guard case .made = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        XCTAssertEqual(tasks.subtasks(of: id).count, 3)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "Renamed launch checklist"))
        let opened = await notes.openHistoryDurably(workspace: session)
        XCTAssertTrue(opened)
        let browser = try XCTUnwrap(notes.historyBrowser)
        XCTAssertEqual(browser.noteID, session.noteID)
        let index = try XCTUnwrap(browser.entries.firstIndex { $0.document.blocks.contains { $0.text.hasPrefix("Everything that has") } })
        notes.selectHistoryVersion(index)
        XCTAssertEqual(notes.historyBrowser?.preview?.engine.isBodyOnly, true, "the preview shows the body, never block 0")
        let restored = await notes.restoreHistoryVersionDurably()
        XCTAssertTrue(restored)
        XCTAssertNil(notes.historyBrowser)
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks.dropFirst().first?.text, "Everything that has to be true before 1.0 goes out.", "the body returns")
        XCTAssertEqual(stored.title, "Renamed launch checklist", "block 0 is today's title, never the old snapshot")
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(tasks.subtasks(of: id).count, 3, "the subtasks are never rewound")
        XCTAssertEqual(tasks.task(withID: id)?.title, "Renamed launch checklist", "the task is never rewound")
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == id }, "the association stays")
        XCTAssertTrue(presenter.host.textView.string.hasPrefix("Everything that has"), "the page shows the restored text")
    }

    // MARK: Agents (§ 5.9): the workspace read and body-only note writes

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testGetTaskWorkspaceReadsTheTaskItsSubtasksAndItsBodyWithoutTheTitleInOneSnapshot() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let tools = AgentTaskTools(store: tasks, noteStore: notes.store, library: library)
        XCTAssertTrue(tools.definitions.contains { ($0["name"] as? String) == "get_task_workspace" })
        let payload = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        XCTAssertEqual((payload["task"] as? [String: Any])?["title"] as? String, "Finalize launch checklist")
        let subtasks = try XCTUnwrap(payload["subtasks"] as? [String: Any])
        XCTAssertEqual((subtasks["open"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Write release notes"])
        XCTAssertEqual((subtasks["done"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Freeze strings"])
        XCTAssertEqual(payload["own_note_id"] as? String, noteID.uuidString)
        let body = try XCTUnwrap(payload["body"] as? String)
        XCTAssertTrue(body.hasPrefix("Everything that has"), "the body without block 0")
        XCTAssertFalse(body.contains("Finalize launch checklist"))
        XCTAssertNotNil(payload["task_token"] as? String)
        XCTAssertNotNil(payload["note_revision"] as? String)
        // The token covers the family: a subtask change makes it stale.
        let first = payload["task_token"] as? String
        XCTAssertTrue(library.updateTask(try XCTUnwrap(tasks.subtasks(of: id).first).id, status: .done).isApplied)
        let again = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        XCTAssertNotEqual(again["task_token"] as? String, first)
    }

    func testAnAgentWritesATasksNoteBodyOnlyAndNeverItsTitle() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        // The agent server's own note store (no editor on screen here).
        let agentNotes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: agentNotes, library: library)
        let revision = try XCTUnwrap(agentNotes.note(withID: noteID)?.revisionToken)
        XCTAssertThrowsError(try tools.call(name: "update_note", arguments: ["id": noteID.uuidString, "title": "Hijack",
                                                                             "base_revision": revision]),
                             "a task's note has no title of its own")
        _ = try tools.call(name: "update_note", arguments: ["id": noteID.uuidString, "body": "Agent wrote this.",
                                                            "base_revision": revision])
        let stored = try storedDocument(noteID)
        XCTAssertEqual(stored.title, "Finalize launch checklist", "block 0 stays the live title snapshot")
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(stored.blocks.dropFirst().map(\.text), ["Agent wrote this."])
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "a body write never touches subtasks")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == id }, "nor the association")
    }

    // MARK: The "Attic Task Life" preview seed

    func testTheTaskLifePreviewSeedsEveryNewState() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container)
        makeStores()
        let deletedNote = try open(try XCTUnwrap(ids[.deletedNote]))
        XCTAssertTrue(deletedNote.model.deletedNote, "Write a new note · Restore Note")
        let deletedTask = try open(try XCTUnwrap(ids[.deletedTask]))
        XCTAssertFalse(deletedTask.model.head.exists, "Task deleted · Restore")
        XCTAssertEqual(deletedTask.model.rows.count, 1)
        let alternate = try open(try XCTUnwrap(ids[.alternateNote]))
        XCTAssertEqual(alternate.model.alternateNotes.count, 1, "Another note for this task · Review")
        let history = try XCTUnwrap(ids[.history])
        let noteID = try XCTUnwrap(try ownNotes(history).first?.id)
        XCTAssertEqual(notes.store.versions(noteID: noteID).count, 2)
        let logged = try open(try XCTUnwrap(ids[.doneLogged]))
        XCTAssertTrue(logged.model.head.exists)
        XCTAssertEqual(logged.model.head.state, .done)
        let demo = try open(try XCTUnwrap(ids[.makeSubtask]))
        XCTAssertTrue(demo.host.textView.string.contains("Record a backup video"))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskDeletionPreservation>())
            .contains { $0.rootID == ids[.deletedTask] }, "the deleted task has its preservation record")
    }

    /// The panel's Tasks page learns which tasks have notes from the note
    /// store, as the app wires it (the row glyph on screen).
    func testTheTasksPageHostFeedsTheNoteOwnersToItsRows() throws {
        let id = try seed(.boundary)
        let suite = "TaskLife.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = TasksPageState()
        let services = TaskNoteEntryServices(open: { _, _ in }, addFiles: { _, _ in },
            noteOwners: notes.store.$notes.map { Set($0.compactMap(\.taskID)) }.removeDuplicates().eraseToAnyPublisher())
        let host = TasksPageHost(store: tasks, uiState: PanelUIState(), settings: AppSettings(defaults: defaults), state: state,
            layout: PanelPageLayout(cornerSize: 24, panelSize: panel), chromeInteractionState: PanelChromeInteractionState(),
            primaryInputFocusRequest: 0, taskNotes: services)
        let hosting = NSHostingView(rootView: host)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        windows.append(window)
        for _ in 0..<20 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let model = state.model(for: tasks, toasts: nil)
        XCTAssertTrue(model.noteOwners.contains(id))
        XCTAssertEqual(model.rows(for: .now).first { $0.id == id }?.model.hasPage, true)
        // A list skips rows that compare equal: the glyph must count.
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == id })
        var without = row.model
        without.hasPage = false
        XCTAssertNotEqual(row, TasksListRow(id: row.id, model: without, status: row.status, subtasks: row.subtasks, files: row.files))
    }
}
