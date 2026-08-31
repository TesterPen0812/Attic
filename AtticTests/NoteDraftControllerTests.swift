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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
    func testSwitchingToShorterNoteInvalidatesPreviousUndoAndRedoRanges() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let originalA = "This is note A with a deliberately long body"
        let noteA = try XCTUnwrap(store.create(title: "A", body: originalA))
        let noteB = try XCTUnwrap(store.create(title: "B", body: "B"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(noteA))
        let editorA = makeTestBodyEditor(draft: draft)
        let coordinator = editorA.makeCoordinator()
        let (textView, window) = makeUndoTextView(coordinator: coordinator)
        Self.retainedHarnessWindows.append(window)
        XCTAssertEqual(
            coordinator.synchronize(parent: editorA, textView: textView),
            .replacedText
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.setSelectedRange(NSRange(location: (originalA as NSString).length, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertEqual(draft.body, originalA + "!")
        XCTAssertEqual(window.firstResponder as? NSTextView, textView)
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        XCTAssertTrue(draft.beginEditing(noteB))
        let editorB = makeTestBodyEditor(draft: draft)
        XCTAssertEqual(
            coordinator.synchronize(parent: editorB, textView: textView),
            .replacedText
        )
        XCTAssertEqual(textView.string, "B")
        XCTAssertTrue(textView.undoManager?.isUndoRegistrationEnabled == true)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertFalse(textView.undoManager?.canRedo == true)

        textView.undoManager?.undo()
        textView.undoManager?.redo()

        XCTAssertEqual(textView.string, "B")
        XCTAssertEqual(draft.activeNoteID, noteB.id)
        XCTAssertEqual(draft.body, "B")
        XCTAssertEqual(
            store.notes.first(where: { $0.id == noteA.id })?.body,
            originalA + "!"
        )
        XCTAssertEqual(store.notes.first(where: { $0.id == noteB.id })?.body, "B")
        XCTAssertEqual(window.firstResponder as? NSTextView, textView)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("2", replacementRange: textView.selectedRange())
        XCTAssertEqual(draft.body, "B2")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "B")
        coordinator.textDidChange(Notification(
            name: NSText.didChangeNotification,
            object: textView
        ))
        XCTAssertEqual(draft.body, "B")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "B2")
        coordinator.textDidChange(Notification(
            name: NSText.didChangeNotification,
            object: textView
        ))
        XCTAssertEqual(draft.body, "B2")
        XCTAssertEqual(store.notes.first(where: { $0.id == noteA.id })?.body, originalA + "!")
    }

    @MainActor
    func testRapidSwitchRejectsStaleQueuedExternalReplacement() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let noteA = try XCTUnwrap(store.create(body: "Long note A"))
        let noteB = try XCTUnwrap(store.create(body: "B"))
        let noteC = try XCTUnwrap(store.create(body: "Current C"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(noteA))
        let sessionA = draft.editorSession
        let boxA = EditorTextBox("Long note A")
        let editorA = makeTestBodyEditor(text: boxA, session: sessionA)
        let coordinator = editorA.makeCoordinator()
        let (textView, window) = makeUndoTextView(coordinator: coordinator)
        Self.retainedHarnessWindows.append(window)
        XCTAssertEqual(
            coordinator.synchronize(parent: editorA, textView: textView),
            .replacedText
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        XCTAssertTrue(draft.beginEditing(noteB))
        let sessionB = draft.editorSession
        let boxB = EditorTextBox("B")
        let editorB = makeTestBodyEditor(text: boxB, session: sessionB)
        XCTAssertEqual(
            coordinator.synchronize(parent: editorB, textView: textView),
            .replacedText
        )

        XCTAssertTrue(draft.beginEditing(noteC))
        let sessionC = draft.editorSession
        let boxC = EditorTextBox("Current C")
        let editorC = makeTestBodyEditor(text: boxC, session: sessionC)
        XCTAssertEqual(
            coordinator.synchronize(parent: editorC, textView: textView),
            .replacedText
        )

        boxA.value = "Queued stale replacement from A"
        boxB.value = "Queued stale replacement from B"
        XCTAssertEqual(
            coordinator.synchronize(parent: editorA, textView: textView),
            .staleSession
        )
        XCTAssertEqual(
            coordinator.synchronize(parent: editorB, textView: textView),
            .staleSession
        )
        XCTAssertEqual(textView.string, "Current C")
        XCTAssertEqual(window.firstResponder as? NSTextView, textView)

        textView.setSelectedRange(NSRange(location: 9, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertEqual(boxC.value, "Current C!")
        XCTAssertEqual(boxA.value, "Queued stale replacement from A")
        XCTAssertEqual(boxB.value, "Queued stale replacement from B")
    }

    @MainActor
    func testEditorSessionIsStableWhileTypingAndAdvancesOnReplacement() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let noteA = try XCTUnwrap(store.create(body: "A"))
        let noteB = try XCTUnwrap(store.create(body: "B"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginEditing(noteA))
        let sessionA = draft.editorSession
        draft.body = "A typed"
        XCTAssertEqual(draft.editorSession, sessionA)

        XCTAssertTrue(draft.beginEditing(noteB))
        let sessionB = draft.editorSession
        XCTAssertEqual(sessionB.noteID, noteB.id)
        XCTAssertGreaterThan(sessionB.generation, sessionA.generation)

        XCTAssertTrue(draft.beginEditing(noteB))
        XCTAssertEqual(draft.editorSession, sessionB)
    }

    @MainActor
    func testSwitchingNotesFlushesThePreviousDraftToItsOwnRecord() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
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

@MainActor
private func makeTestBodyEditor(
    draft: NoteDraftController,
    isFocused: Bool = true
) -> AttachmentAwareTextEditor {
    AttachmentAwareTextEditor(
        text: Binding(
            get: { draft.body },
            set: { draft.body = $0 }
        ),
        isFileTargeted: .constant(false),
        isFocused: isFocused,
        session: draft.editorSession,
        onFocusChange: { _ in },
        onImportFiles: { _, _ in },
        onImportError: { _ in }
    )
}

@MainActor
private func makeTestBodyEditor(
    text: EditorTextBox,
    session: NoteEditorSession,
    isFocused: Bool = true
) -> AttachmentAwareTextEditor {
    AttachmentAwareTextEditor(
        text: Binding(
            get: { text.value },
            set: { text.value = $0 }
        ),
        isFileTargeted: .constant(false),
        isFocused: isFocused,
        session: session,
        onFocusChange: { _ in },
        onImportFiles: { _, _ in },
        onImportError: { _ in }
    )
}

@MainActor
private func makeUndoTextView(
    coordinator: AttachmentAwareTextEditor.Coordinator
) -> (NSTextView, NSWindow) {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    textView.delegate = coordinator
    textView.allowsUndo = true
    coordinator.textView = textView
    let window = NSWindow(
        contentRect: textView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = textView
    return (textView, window)
}

private final class EditorTextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}
