import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

final class NoteDraftControllerTests: XCTestCase {
    // NSHostingView can still have focus reconciliation scheduled after the
    // assertion. Retain the harness window for the short life of the test
    // process so XCTest's autorelease checker does not tear its AppKit graph
    // down while those main-queue callbacks are draining.
    private static var retainedHarnessWindows: [NSWindow] = []

    @MainActor
    func testBodyEditorKeepsFirstResponderAcrossDraftUpdates() throws {
        let store = try makeTestNoteStore()
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        let uiState = PanelUIState()
        XCTAssertTrue(draft.beginNew())
        uiState.beginAdding()

        let host = NSHostingView(
            rootView: NoteComposerView(noteDraft: draft, uiState: uiState)
                .frame(width: 420, height: 560)
        )
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        Self.retainedHarnessWindows.append(window)

        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        let textView = try XCTUnwrap(
            firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" }
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.insertText("a", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertTrue(
            window.firstResponder === textView,
            "A draft publication must not make the body editor surrender first responder"
        )
        textView.insertText("b", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(textView.string, "ab")
        XCTAssertEqual(draft.body, "ab")
    }

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

@MainActor
private func firstTextView(
    in view: NSView,
    matching predicate: (NSTextView) -> Bool
) -> NSTextView? {
    if let textView = view as? NSTextView, predicate(textView) {
        return textView
    }
    for subview in view.subviews {
        if let match = firstTextView(in: subview, matching: predicate) {
            return match
        }
    }
    return nil
}
