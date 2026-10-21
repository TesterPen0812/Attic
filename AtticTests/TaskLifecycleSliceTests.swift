import AppKit
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
        tasks = TaskStore(container: container)
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
}
