import SwiftData
import XCTest
@testable import Attic

final class NoteDraftControllerTests: XCTestCase {
    @MainActor
    func testSwitchingNotesFlushesThePreviousDraftToItsOwnRecord() throws {
        let store = try makeTestNoteStore()
        let first = try XCTUnwrap(store.create(title: "First", body: "Original first"))
        let second = try XCTUnwrap(store.create(title: "Second", body: "Original second"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(first))
        draft.body = "Edited first"
        XCTAssertTrue(draft.beginEditing(second))

        XCTAssertEqual(store.notes.first(where: { $0.id == first.id })?.body, "Edited first")
        XCTAssertEqual(store.notes.first(where: { $0.id == second.id })?.body, "Original second")
        XCTAssertEqual(draft.activeNoteID, second.id)
        XCTAssertEqual(draft.body, "Original second")
    }

    @MainActor
    func testCancelledAutosaveCannotWriteThePreviousDraftIntoTheNewSelection() async throws {
        let store = try makeTestNoteStore()
        let first = try XCTUnwrap(store.create(title: "First", body: "One"))
        let second = try XCTUnwrap(store.create(title: "Second", body: "Two"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .milliseconds(40))

        XCTAssertTrue(draft.beginEditing(first))
        draft.body = "First changed"
        XCTAssertTrue(draft.beginEditing(second))
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(store.notes.first(where: { $0.id == first.id })?.body, "First changed")
        XCTAssertEqual(store.notes.first(where: { $0.id == second.id })?.body, "Two")
        XCTAssertEqual(draft.activeNoteID, second.id)
    }

    @MainActor
    func testRapidTypingCoalescesIntoOneAutosave() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save)
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .milliseconds(30))

        XCTAssertTrue(draft.beginNew())
        draft.body = "a"
        draft.body = "ab"
        draft.body = "abc"
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(gate.saveCount, 1)
        XCTAssertEqual(store.notes.map(\.body), ["abc"])
        XCTAssertFalse(draft.isDirty)
    }

    @MainActor
    func testFlushPreservesWhitespaceUnicodeAndLargeTextShape() throws {
        let store = try makeTestNoteStore()
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        let body = "\n  👩🏽‍💻 café\n" + String(repeating: "line  \n", count: 2_000)

        XCTAssertTrue(draft.beginNew())
        draft.title = "  Unicode   note "
        draft.body = body
        XCTAssertTrue(draft.flush())

        let note = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(note.title, "Unicode note")
        XCTAssertEqual(note.body, body)
    }

    @MainActor
    func testAutosaveDoesNotRewriteTheInProgressTitleFormatting() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(title: "Original", body: "Body"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(note))
        draft.title = "  Draft   title  "
        XCTAssertTrue(draft.flush())
        XCTAssertTrue(draft.reconcileWithStore())

        XCTAssertEqual(store.notes.first?.title, "Draft title")
        XCTAssertEqual(draft.title, "  Draft   title  ")
    }

    @MainActor
    func testBlankExistingDraftRevertsInsteadOfErasingTheNote() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(title: "Keep", body: "Important"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(note))
        draft.title = "  "
        draft.body = "\n  "
        XCTAssertTrue(draft.flush())

        XCTAssertEqual(store.notes.first?.title, "Keep")
        XCTAssertEqual(store.notes.first?.body, "Important")
        XCTAssertEqual(draft.title, "Keep")
        XCTAssertEqual(draft.body, "Important")
        XCTAssertFalse(draft.isDirty)
    }

    @MainActor
    func testBlankNewDraftClosesWithoutCreatingAnEmptyRecord() throws {
        let store = try makeTestNoteStore()
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        draft.title = "   "
        draft.body = "\n  "
        XCTAssertTrue(draft.close())

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(draft.isActive)
    }

    @MainActor
    func testFailedFlushKeepsDraftActiveAndPreventsSwitching() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save)
        let first = try XCTUnwrap(store.create(title: "First", body: "One"))
        let second = try XCTUnwrap(store.create(title: "Second", body: "Two"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(first))
        draft.body = "Unsaved"
        gate.shouldFail = true

        XCTAssertFalse(draft.beginEditing(second))
        XCTAssertEqual(draft.activeNoteID, first.id)
        XCTAssertEqual(draft.body, "Unsaved")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(store.notes.first(where: { $0.id == first.id })?.body, "One")
    }

    @MainActor
    func testRemoteDeletionPreservesDirtyDraftWithoutResurrectingTheNote() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container)
        let original = try XCTUnwrap(store.create(title: "Draft", body: "Before"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(original))
        draft.body = "Local unsaved work"

        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(externalContext.fetch(FetchDescriptor<NoteItem>()).first)
        externalContext.delete(externalNote)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(draft.reconcileWithStore())
        XCTAssertEqual(draft.conflict, .missingOriginal)
        XCTAssertFalse(draft.flush())
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(draft.body, "Local unsaved work")
    }

    @MainActor
    func testSaveAsNewRecoversDraftAfterRemoteDeletion() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container)
        let original = try XCTUnwrap(store.create(title: "Draft", body: "Before"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(original))
        draft.body = "Recovered content"

        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(externalContext.fetch(FetchDescriptor<NoteItem>()).first)
        externalContext.delete(externalNote)
        try externalContext.save()
        store.refresh()
        XCTAssertTrue(draft.reconcileWithStore())

        XCTAssertTrue(draft.saveAsNew())
        let recovered = try XCTUnwrap(store.notes.first)
        XCTAssertNotEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.body, "Recovered content")
        XCTAssertEqual(draft.activeNoteID, recovered.id)
        XCTAssertNil(draft.conflict)
    }

    @MainActor
    func testConcurrentRemoteEditBlocksSilentOverwrite() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container)
        let note = try XCTUnwrap(store.create(body: "Initial"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(note))
        draft.body = "Local draft"

        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(externalContext.fetch(FetchDescriptor<NoteItem>()).first)
        externalNote.body = "Remote edit"
        externalNote.updatedAt = Date().addingTimeInterval(60)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(draft.reconcileWithStore())
        XCTAssertEqual(draft.conflict, .remoteChange)
        XCTAssertFalse(draft.flush())
        XCTAssertEqual(store.notes.first?.body, "Remote edit")
        XCTAssertEqual(draft.body, "Local draft")
    }

    @MainActor
    func testConflictCanUseRemoteVersion() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(body: "Initial"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(note))
        draft.body = "Local"
        XCTAssertTrue(store.update(note, body: "Remote"))
        XCTAssertTrue(draft.reconcileWithStore())

        XCTAssertTrue(draft.useRemoteVersion())
        XCTAssertEqual(draft.body, "Remote")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    @MainActor
    func testConflictCanExplicitlyOverwriteRemoteVersion() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(body: "Initial"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(note))
        draft.body = "Local"
        XCTAssertTrue(store.update(note, body: "Remote"))
        XCTAssertTrue(draft.reconcileWithStore())

        XCTAssertTrue(draft.overwriteRemoteVersion())
        XCTAssertEqual(store.notes.first?.body, "Local")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.conflict)
    }

    @MainActor
    func testCleanRemoteChangeReplacesTheDraftSnapshot() throws {
        let store = try makeTestNoteStore()
        let note = try XCTUnwrap(store.create(title: "Remote", body: "Before"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(note))
        XCTAssertTrue(store.update(note, body: "After"))
        XCTAssertTrue(draft.reconcileWithStore())

        XCTAssertEqual(draft.body, "After")
        XCTAssertFalse(draft.isDirty)
    }

    @MainActor
    func testIncidentalFlushesPersistButNeverCloseTheEditor() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save)
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        draft.body = "Keep editing after focus, panel, or Settings changes"

        XCTAssertTrue(draft.flush())
        XCTAssertTrue(draft.flush())
        XCTAssertTrue(draft.flush())

        XCTAssertEqual(gate.saveCount, 1)
        XCTAssertTrue(draft.isActive)
        XCTAssertNotNil(draft.activeNoteID)
        XCTAssertEqual(draft.body, "Keep editing after focus, panel, or Settings changes")
        XCTAssertFalse(draft.isDirty)
    }

    @MainActor
    func testCloseFlushesThenClearsEditorState() throws {
        let store = try makeTestNoteStore()
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        draft.body = "Saved on close"
        XCTAssertTrue(draft.close())

        XCTAssertEqual(store.notes.map(\.body), ["Saved on close"])
        XCTAssertFalse(draft.isActive)
        XCTAssertNil(draft.activeNoteID)
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.body, "")
    }
}

final class PanelUIStateNotePresentationTests: XCTestCase {
    @MainActor
    func testEnteringNotesWithoutAnActiveSessionLeavesTheListVisible() {
        let state = PanelUIState()

        state.selectSection(.notes)

        XCTAssertEqual(state.noteEditorPresentation, .hidden)
        XCTAssertNil(state.editingNoteID)
        XCTAssertFalse(state.isComposerPresented)
    }

    @MainActor
    func testNewAndExistingNotesHaveDistinctPresentationStates() {
        let state = PanelUIState()
        let note = NoteItem(body: "Existing")
        state.selectSection(.notes)

        state.beginNewNote()
        XCTAssertEqual(state.noteEditorPresentation, .new)
        XCTAssertNil(state.editingNoteID)
        XCTAssertTrue(state.isComposerPresented)

        state.beginEditingNote(note)
        XCTAssertEqual(state.noteEditorPresentation, .editing(note.id))
        XCTAssertEqual(state.editingNoteID, note.id)
        XCTAssertTrue(state.isComposerPresented)
    }

    @MainActor
    func testSectionNavigationSuspendsAndRestoresTheSameNoteEditor() {
        let state = PanelUIState()
        let note = NoteItem(body: "Existing")
        state.selectSection(.notes)
        state.beginEditingNote(note)

        state.selectSection(.tasks)
        XCTAssertEqual(state.noteEditorPresentation, .editing(note.id))
        XCTAssertFalse(state.isComposerPresented)
        XCTAssertFalse(state.isInteractionLocked)

        state.selectSection(.notes)
        XCTAssertEqual(state.noteEditorPresentation, .editing(note.id))
        XCTAssertEqual(state.editingNoteID, note.id)
        XCTAssertTrue(state.isComposerPresented)
        XCTAssertTrue(state.isInteractionLocked)
    }

    @MainActor
    func testTaskComposerDoesNotDiscardASuspendedNoteSession() {
        let state = PanelUIState()
        state.selectSection(.notes)
        state.beginNewNote()
        state.selectSection(.backlog)

        state.beginAddingTask()
        XCTAssertTrue(state.isComposerPresented)
        state.endAdding()
        XCTAssertFalse(state.isComposerPresented)
        XCTAssertEqual(state.noteEditorPresentation, .new)

        state.selectSection(.notes)
        XCTAssertTrue(state.isComposerPresented)
        XCTAssertEqual(state.noteEditorPresentation, .new)
    }

    @MainActor
    func testFirstAutosavePromotesNewPresentationToEditing() {
        let state = PanelUIState()
        let noteID = UUID()
        state.selectSection(.notes)
        state.beginNewNote()

        state.reconcileNoteEditor(activeNoteID: noteID, isActive: true)

        XCTAssertEqual(state.noteEditorPresentation, .editing(noteID))
        XCTAssertEqual(state.editingNoteID, noteID)
        XCTAssertTrue(state.isComposerPresented)
    }
}
