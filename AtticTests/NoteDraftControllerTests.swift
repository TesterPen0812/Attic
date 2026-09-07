import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

final class NoteDraftControllerTests: XCTestCase {
    @MainActor
    func testNativePreviewDemandTracksVisibleCardsWithoutPublishingEveryScrollSample() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1200))
        let first = NoteAttachmentVisibilityView(frame: NSRect(x: 0, y: 20, width: 400, height: 250))
        let last = NoteAttachmentVisibilityView(frame: NSRect(x: 0, y: 700, width: 400, height: 250))
        document.addSubview(first)
        document.addSubview(last)
        scrollView.documentView = document
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderBack(nil)
        defer { tearDownHarnessWindow(window) }
        var firstDemandChanges = 0
        first.onChange = { _ in firstDemandChanges += 1 }
        scrollView.contentView.scroll(to: .zero)
        first.refreshVisibility()
        last.refreshVisibility()
        drainMainRunLoop()
        XCTAssertTrue(first.demand.isVisible)
        XCTAssertFalse(last.demand.isVisible)
        let initialChanges = firstDemandChanges
        for y in 1...10 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            first.refreshVisibility()
        }
        drainMainRunLoop()
        XCTAssertEqual(firstDemandChanges, initialChanges, "Visible-to-visible scrolling must not republish demand")
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 680))
        first.refreshVisibility()
        last.refreshVisibility()
        drainMainRunLoop()
        XCTAssertFalse(first.demand.isVisible)
        XCTAssertTrue(last.demand.isVisible)
        XCTAssertEqual(firstDemandChanges, initialChanges + 1)
    }

    @MainActor
    func testNoteDocumentFillsTallWorkspaceAndResizesWithoutReplacingEditor() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginNew())
        let uiState = PanelUIState()
        uiState.beginAdding()
        let host = NSHostingView(rootView: NoteComposerView(noteDraft: draft, uiState: uiState))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { tearDownHarnessWindow(window) }
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" })
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertTrue(scrollView.documentView is NoteEditorDocumentView)
        XCTAssertNil(scrollView.enclosingScrollView, "Notes must not nest two vertical scroll owners")
        XCTAssertGreaterThan(textView.frame.height, 400, "The writing area must not retain its old 170-point cap")
        XCTAssertEqual(textView.frame.height, scrollView.contentSize.height, accuracy: 1)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText("Continuous draft", replacementRange: textView.selectedRange())
        drainMainRunLoop()
        let selection = textView.selectedRange()
        let previousHeight = textView.frame.height

        window.setContentSize(NSSize(width: 360, height: 800))
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" } === textView)
        XCTAssertGreaterThan(textView.frame.height, previousHeight + 200)
        XCTAssertEqual(textView.frame.height, scrollView.contentSize.height, accuracy: 1)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(draft.body, "Continuous draft")
    }

    @MainActor
    func testDocumentAccessoriesFollowTextAndShareItsScrollPosition() throws {
        let text = EditorTextBox("Short body")
        var editor = makeTestBodyEditor(text: text, session: NoteEditorSession(noteID: UUID(), generation: 1))
        editor.documentAccessories = AnyView(Text("Attachment fixture").frame(height: 120))
        editor.hasDocumentAccessories = true
        let (host, window) = makeDocumentHarness(editor: editor)
        defer { tearDownHarnessWindow(window) }
        drainMainRunLoop()
        let textView = try XCTUnwrap(firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" })
        let document = try XCTUnwrap(textView.superview as? NoteEditorDocumentView)
        let accessory = try XCTUnwrap(document.subviews.first { $0 !== textView })
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        document.layoutDocument(viewport: scrollView.contentSize)
        XCTAssertLessThan(textView.frame.height, 60)
        XCTAssertEqual(accessory.frame.minY, textView.frame.maxY + 12, accuracy: 1)
        let originalY = accessory.frame.minY

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText(String(repeating: "\nA long document line that wraps as the panel narrows.", count: 50),
                            replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        drainMainRunLoop()
        XCTAssertGreaterThan(accessory.frame.minY, originalY + 500)
        XCTAssertEqual(accessory.frame.minY, textView.frame.maxY + 12, accuracy: 1)
        XCTAssertGreaterThan(document.frame.height, scrollView.contentSize.height)
        XCTAssertTrue(accessory.enclosingScrollView === scrollView)
        scrollView.contentView.scroll(to: .zero)
        let textY = textView.convert(.zero, to: nil).y
        let accessoryY = accessory.convert(.zero, to: nil).y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 160))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let textMovement = textView.convert(.zero, to: nil).y - textY
        let accessoryMovement = accessory.convert(.zero, to: nil).y - accessoryY
        XCTAssertEqual(abs(textMovement), 160, accuracy: 1)
        XCTAssertEqual(accessoryMovement, textMovement, accuracy: 1)

        let wideHeight = textView.frame.height
        window.setContentSize(NSSize(width: 230, height: 400))
        drainMainRunLoop()
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(textView.frame.height, wideHeight, "Narrowing must reflow the full document, not clip it")
        XCTAssertEqual(accessory.frame.minY, textView.frame.maxY + 12, accuracy: 1)
    }

    @MainActor
    func testDocumentHeightIncludesTrailingEmptyLineAndShrinksAfterDeletion() throws {
        let text = EditorTextBox(String(repeating: "Line\n", count: 80))
        let editor = makeTestBodyEditor(text: text, session: NoteEditorSession(noteID: UUID(), generation: 1))
        let (host, window) = makeDocumentHarness(editor: editor)
        defer { tearDownHarnessWindow(window) }
        drainMainRunLoop()
        let textView = try XCTUnwrap(firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" })
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let extraLine = try XCTUnwrap(textView.layoutManager).extraLineFragmentRect
        XCTAssertGreaterThan(extraLine.height, 0)
        XCTAssertGreaterThanOrEqual(textView.frame.height, extraLine.maxY + textView.textContainerInset.height * 2)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText("Short again", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        drainMainRunLoop()
        XCTAssertEqual(textView.frame.height, scrollView.contentSize.height, accuracy: 1)
        XCTAssertEqual(scrollView.documentView?.frame.height ?? 0, scrollView.contentSize.height, accuracy: 1)
        XCTAssertEqual(text.value, "Short again")
    }

    @MainActor
    func testInaccessibleRecoveryDirectoryIsNotTreatedAsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticProtectedDraftTests-\(UUID().uuidString)")
        let protectedDirectory = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = protectedDirectory.appendingPathComponent("draft.json")
        let snapshot = NoteDraftRecoverySnapshot(
            noteID: nil, reservedNoteID: UUID(), title: "", body: "Protected recovery",
            persistedTitle: nil, persistedBody: nil
        )
        let journal = NoteDraftRecoveryFile(url: url)
        try await journal.checkpoint(snapshot, generation: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: protectedDirectory.path)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60), recoveryURL: url)

        let restored = await draft.restoreRecoveryIfNeeded()
        XCTAssertFalse(restored)
        XCTAssertNotNil(draft.recoveryErrorMessage)
        XCTAssertTrue(draft.beginNew())
        draft.body = "Independent saved note"
        XCTAssertTrue(draft.flush())
        await draft.waitForRecoveryCheckpoint()

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path)
        let preserved = try await journal.load()
        XCTAssertEqual(preserved, snapshot)
        await draft.retryRecovery()
        XCTAssertEqual(draft.body, snapshot.body)
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.recoveryErrorMessage)
        XCTAssertTrue(draft.flush())
        await draft.waitForRecoveryCheckpoint()
    }

    @MainActor
    func testUnreadableRecoveryRemainsVisibleAndUntouchedAcrossOpeningAndSavingNotes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticUnreadableDraftTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("draft.json")
        let unreadable = Data("incomplete recovery file".utf8)
        try unreadable.write(to: url)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "Saved note"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60), recoveryURL: url)

        let restored = await draft.restoreRecoveryIfNeeded()
        XCTAssertFalse(restored)
        let warning = try XCTUnwrap(draft.recoveryErrorMessage)
        XCTAssertTrue(draft.beginEditing(note))
        draft.body = "New saved edits"
        XCTAssertTrue(draft.flush())
        await draft.waitForRecoveryCheckpoint()
        XCTAssertEqual(draft.recoveryErrorMessage, warning)
        XCTAssertNil(draft.saveErrorMessage, "Saved text and an unread recovery copy have distinct status")
        XCTAssertEqual(try Data(contentsOf: url), unreadable)

        let failedRetrySession = await draft.retryRecovery()
        XCTAssertNil(failedRetrySession)
        XCTAssertNotNil(draft.recoveryErrorMessage)
        XCTAssertEqual(try Data(contentsOf: url), unreadable)
        XCTAssertEqual(draft.body, "New saved edits")
    }

    @MainActor
    func testRecoveryRetryPreservesCurrentDraftBeforeOpeningWaitingRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticWaitingDraftTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let snapshot = NoteDraftRecoverySnapshot(
            noteID: nil, reservedNoteID: UUID(), title: "", body: "Earlier unsaved draft",
            persistedTitle: nil, persistedBody: nil
        )
        let journal = NoteDraftRecoveryFile(url: url)
        try await journal.checkpoint(snapshot, generation: 1)
        let bytes = try Data(contentsOf: url)
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60), recoveryURL: url)
        XCTAssertTrue(draft.beginNew())
        draft.body = "Current startup draft"

        let restored = await draft.restoreRecoveryIfNeeded()
        XCTAssertFalse(restored)
        XCTAssertNotNil(draft.recoveryErrorMessage)
        gate.shouldFail = true
        await draft.retryRecovery()
        XCTAssertEqual(draft.body, "Current startup draft")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNotNil(draft.saveErrorMessage)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        gate.shouldFail = false
        let restoredSession = await draft.retryRecovery()
        XCTAssertEqual(restoredSession, draft.editorSession)
        XCTAssertEqual(store.notes.map(\.body), ["Current startup draft"])
        XCTAssertEqual(draft.body, "Earlier unsaved draft")
        XCTAssertTrue(draft.isDirty)
        XCTAssertNil(draft.recoveryErrorMessage)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(draft.flush())
        await draft.waitForRecoveryCheckpoint()
        XCTAssertEqual(Set(store.notes.map(\.body)), ["Current startup draft", "Earlier unsaved draft"])
    }

    @MainActor
    func testUsingSavedVersionClearsDiscardedRecoveryBeforeRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDiscardRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "Current saved version"))
        let journal = NoteDraftRecoveryFile(url: url)
        try await journal.checkpoint(NoteDraftRecoverySnapshot(
            noteID: note.id, reservedNoteID: note.id, title: "", body: "Discarded local version",
            persistedTitle: "", persistedBody: "Older saved version"
        ), generation: 1)
        let draft = NoteDraftController(noteStore: store, recoveryURL: url)
        let restored = await draft.restoreRecoveryIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(draft.conflict, .remoteChange)
        XCTAssertTrue(draft.useRemoteVersion())
        await draft.waitForRecoveryCheckpoint()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let relaunched = NoteDraftController(noteStore: store, recoveryURL: url)
        let restoredAgain = await relaunched.restoreRecoveryIfNeeded()
        XCTAssertFalse(restoredAgain)
    }

    @MainActor
    func testNeverSavedDraftSurvivesFailedSaveAndControllerRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDraftRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("draft.json")
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let first = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60), recoveryURL: recoveryURL)
        _ = await first.restoreRecoveryIfNeeded()
        XCTAssertTrue(first.beginNew())
        first.title = "Recovered title"
        first.body = "Never saved 👩🏽‍💻\n  preserve whitespace  "
        gate.shouldFail = true
        XCTAssertFalse(first.flush())
        await first.waitForRecoveryCheckpoint()
        XCTAssertTrue(store.notes.isEmpty)
        let restored = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60), recoveryURL: recoveryURL)
        let didRestore = await restored.restoreRecoveryIfNeeded()
        XCTAssertTrue(didRestore)
        XCTAssertTrue(restored.isDirty)
        XCTAssertNil(restored.activeNoteID)
        XCTAssertEqual(restored.title, first.title)
        XCTAssertEqual(restored.body, first.body)
        gate.shouldFail = false
        XCTAssertTrue(restored.flush())
        await restored.waitForRecoveryCheckpoint()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, first.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    @MainActor
    func testRecoveryDoesNotOverwriteNewerSavedNote() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDraftConflictTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "Newer saved body"))
        let journal = NoteDraftRecoveryFile(url: url)
        try await journal.checkpoint(NoteDraftRecoverySnapshot(
            noteID: note.id, reservedNoteID: note.id, title: "", body: "Recovered unsaved body",
            persistedTitle: "", persistedBody: "Older saved body"
        ), generation: 1)
        let draft = NoteDraftController(noteStore: store, recoveryURL: url)
        let didRestore = await draft.restoreRecoveryIfNeeded()
        XCTAssertTrue(didRestore)
        XCTAssertEqual(draft.conflict, .remoteChange)
        XCTAssertFalse(draft.flush())
        XCTAssertEqual(draft.body, "Recovered unsaved body")
        XCTAssertEqual(store.notes.first?.body, "Newer saved body")
        await draft.waitForRecoveryCheckpoint()
    }

    func testOlderRecoveryWriteCannotRecreateFileAfterSuccessfulSaveClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDraftOrderingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let journal = NoteDraftRecoveryFile(url: url)
        let snapshot = NoteDraftRecoverySnapshot(
            noteID: nil, reservedNoteID: UUID(), title: "", body: "Old draft", persistedTitle: nil, persistedBody: nil
        )
        try await journal.checkpoint(snapshot, generation: 2)
        try await journal.checkpoint(nil, generation: 3)
        try await journal.checkpoint(snapshot, generation: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testContinuousTypingHasBoundedDurabilityCheckpoint() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(
            noteStore: store,
            autosaveDelay: .seconds(60),
            maximumAutosaveDelay: .milliseconds(60)
        )
        XCTAssertTrue(draft.beginNew())
        for index in 0..<8 {
            draft.body = "Continuous typing \(index)"
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.notes.isEmpty, "Ongoing typing must not postpone durability indefinitely")
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(store.notes.first?.body, "Continuous typing 7")
    }

    @MainActor
    func testFailedSaveKeepsDraftAndExposesRetryUntilSuccess() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let draft = NoteDraftController(noteStore: store)
        XCTAssertTrue(draft.beginNew())
        draft.body = "Retain this draft"
        gate.shouldFail = true
        XCTAssertFalse(draft.close())
        XCTAssertTrue(draft.isActive)
        XCTAssertTrue(draft.isDirty)
        XCTAssertNotNil(draft.saveErrorMessage)
        XCTAssertEqual(draft.body, "Retain this draft")
        gate.shouldFail = false
        XCTAssertTrue(draft.flush())
        XCTAssertNil(draft.saveErrorMessage)
        XCTAssertEqual(store.notes.first?.body, "Retain this draft")
    }

    @MainActor
    func testSavedEditorSessionRestoresNoteSelectionAndScrollWithoutWritingNoteTextToDefaults() throws {
        let suite = "AtticNoteSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "Private note content"))
        let draft = NoteDraftController(noteStore: store, sessionDefaults: defaults)
        XCTAssertTrue(draft.beginEditing(note))
        let state = NoteEditorViewState(selectionLocation: 4, selectionLength: 3, scrollY: 140)
        draft.recordEditorViewState(state, for: draft.editorSession)
        XCTAssertTrue(draft.close())
        let restored = NoteDraftController(noteStore: store, sessionDefaults: defaults)
        XCTAssertTrue(restored.resumeLastSession())
        XCTAssertEqual(restored.activeNoteID, note.id)
        XCTAssertEqual(restored.editorViewState, state)
        let persisted = try XCTUnwrap(defaults.data(forKey: "notes.lastEditorSession.v1"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(note.body))
        restored.discardDeletedNote(note.id)
        XCTAssertNil(defaults.data(forKey: "notes.lastEditorSession.v1"))
    }

    @MainActor
    func testQueuedFocusRequestCannotOverrideNewerIntentInSameSession() throws {
        let box = EditorTextBox("Text")
        let session = NoteEditorSession(noteID: UUID(), generation: 1)
        var editor = makeTestBodyEditor(text: box, session: session, isFocused: false)
        let coordinator = editor.makeCoordinator()
        let (textView, window) = makeUndoTextView(coordinator: coordinator)
        defer { tearDownHarnessWindow(window) }
        _ = coordinator.synchronize(parent: editor, textView: textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        coordinator.requestFocus(false, for: session, textView: textView)
        // The newer render still wants editing. The earlier queued release
        // must not take first responder away after that render.
        editor = makeTestBodyEditor(text: box, session: session)
        _ = coordinator.synchronize(parent: editor, textView: textView)
        drainMainRunLoop()
        XCTAssertTrue(window.firstResponder === textView)
    }

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
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { tearDownHarnessWindow(window) }

        drainMainRunLoop()

        let textView = try XCTUnwrap(
            firstTextView(in: host) { $0.accessibilityIdentifier() == "note-body" }
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.insertText("a", replacementRange: textView.selectedRange())
        drainMainRunLoop()

        XCTAssertTrue(
            window.firstResponder === textView,
            "A draft publication must not make the body editor surrender first responder"
        )
        textView.insertText("b", replacementRange: textView.selectedRange())
        drainMainRunLoop()

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
        defer { tearDownHarnessWindow(window) }
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
        defer { tearDownHarnessWindow(window) }
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
private func makeDocumentHarness(editor: AttachmentAwareTextEditor) -> (NSHostingView<AttachmentAwareTextEditor>, NSWindow) {
    let host = NSHostingView(rootView: editor)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    return (host, window)
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
    window.isReleasedWhenClosed = false
    window.contentView = textView
    return (textView, window)
}

@MainActor
private func drainMainRunLoop(maximumPasses: Int = 16) {
    for _ in 0..<maximumPasses {
        let handledSource = RunLoop.main.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.001)
        )
        if !handledSource { break }
    }
}

@MainActor
private func tearDownHarnessWindow(_ window: NSWindow) {
    _ = window.makeFirstResponder(nil)
    if let contentView = window.contentView,
       let textView = firstTextView(in: contentView, matching: { _ in true }) {
        textView.delegate = nil
    }
    window.orderOut(nil)
    window.close()
    drainMainRunLoop()
}

private final class EditorTextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}
