import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class NoteHistoryBrowserTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var controller: NotesPageController!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "S7History")),
            saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
    }

    private func type(_ text: String) throws {
        let engine = try XCTUnwrap(controller.active?.engine)
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: text), name: "Typing")
    }

    private func history() async throws -> (NoteSession, UUID) {
        try type("Research\nEarlier paragraph")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let original = try XCTUnwrap(controller.active)
        XCTAssertTrue(store.recordVersion(noteID: original.noteID, reason: .pause))
        let id = try XCTUnwrap(store.versions(noteID: original.noteID).first?.id)
        try type("\nStudent pricing")
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        return (original, id)
    }

    func testNavigationIsReadOnlyNamesMissingTextAndKeepsLiveUndo() async throws {
        let (original, _) = try await history()
        let browser = try XCTUnwrap(controller.historyBrowser)
        XCTAssertTrue(try XCTUnwrap(browser.preview).engine.isReadOnly)
        XCTAssertEqual(browser.comparison.missing.map(\.text), ["Student pricing"])
        XCTAssertTrue(NoteTextExport.plainText(browser.comparison.document).contains("Not in this version: “Student pricing”"))
        let historyCount = original.engine.history.undoOps.count
        browser.showsCurrent = true
        controller.refreshHistoryPreview()
        XCTAssertTrue(try XCTUnwrap(browser.preview).engine.isReadOnly)
        controller.closeHistory()
        XCTAssertTrue(controller.active === original)
        XCTAssertEqual(original.engine.history.undoOps.count, historyCount)
        XCTAssertEqual(original.engine.document().blocks.last?.text, "Student pricing")
    }

    func testFailedRestoreStaysInPreviewRetryCommitsAndUndoRestoresOriginalSession() async throws {
        let (original, selectedID) = try await history()
        let browser = try XCTUnwrap(controller.historyBrowser)
        let before = store.versions(noteID: original.noteID).count
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.restoreHistoryVersionDurably())
        XCTAssertTrue(controller.historyBrowser === browser)
        XCTAssertNotNil(browser.failure)
        XCTAssertEqual(browser.selected?.id, selectedID)
        XCTAssertEqual(store.versions(noteID: original.noteID).count, before)
        XCTAssertEqual(store.note(withID: original.noteID)?.body, "Earlier paragraph\nStudent pricing")
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        XCTAssertNil(controller.historyBrowser)
        XCTAssertEqual(controller.active?.engine.document().blocks.last?.text, "Earlier paragraph")
        let ticket = controller.versionRestoreUndoID
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.undoVersionRestoreDurably(expectedID: ticket))
        XCTAssertEqual(controller.active?.engine.document().blocks.last?.text, "Earlier paragraph")
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.undoVersionRestoreDurably(expectedID: ticket))
        XCTAssertTrue(controller.active === original)
        XCTAssertEqual(store.note(withID: original.noteID)?.body, "Earlier paragraph\nStudent pricing")
    }

    func testRestoreRefusesExternalChangeAndUndoRefusesNewTyping() async throws {
        let (original, _) = try await history()
        let revision = try XCTUnwrap(store.note(withID: original.noteID)?.revisionID)
        guard case .success = store.saveDocument(noteID: original.noteID,
            document: NoteDocument(blocks: [.text("External")]), baseRevisionID: revision) else { return XCTFail() }
        await XCTAssertFalseAsync(await controller.restoreHistoryVersionDurably())
        XCTAssertNotNil(controller.historyBrowser?.failure)
        XCTAssertEqual(store.note(withID: original.noteID)?.title, "External")
        controller.closeHistory()
        controller.present()
        XCTAssertTrue(store.recordVersion(noteID: original.noteID, reason: .pause))
        try type("\nLatest")
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let ticket = controller.versionRestoreUndoID
        try type("\nDo not lose me")
        await XCTAssertFalseAsync(await controller.undoVersionRestoreDurably(expectedID: ticket))
        XCTAssertTrue(controller.active?.engine.document().blocks.last?.text.contains("Do not lose me") == true)
    }

    func testCopyVersionUsesOriginalStructuredContentWithoutComparisonLabels() async throws {
        let (_, _) = try await history()
        controller.copyHistoryVersion()
        let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(text.contains("Earlier paragraph"))
        XCTAssertFalse(text.contains("Not in this version"))
        XCTAssertFalse(text.contains("Student pricing"))
        let bytes = try XCTUnwrap(NSPasteboard.general.data(forType: NoteEditorEngine.fragmentType))
        XCTAssertTrue(NoteContentCodec.decode(bytes, context: .fragment).document?.blocks.contains { $0.text == "Earlier paragraph" } == true)
    }

    func testSteppingAndClosingDuringNavigationKeepsTheOriginalNote() async throws {
        let (original, _) = try await history()
        let browser = try XCTUnwrap(controller.historyBrowser)
        controller.selectHistoryVersion(-1)
        XCTAssertEqual(browser.selectedIndex, 0)
        controller.selectHistoryVersion(browser.entries.count)
        XCTAssertEqual(browser.selectedIndex, 0)
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        XCTAssertNil(controller.historyBrowser)
        XCTAssertNotEqual(controller.active?.noteID, original.noteID)
        XCTAssertEqual(store.note(withID: original.noteID)?.body, "Earlier paragraph\nStudent pricing")
    }

    func testNativeUndoCommandCanUndoRestoreAfterToastExpires() async throws {
        let (original, _) = try await history()
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let restored = try XCTUnwrap(controller.active)
        let (_, textView) = restored.engine.makeView()
        textView.undo(nil)
        await controller.versionHistoryCommandTask?.value
        XCTAssertTrue(controller.active === original)
        XCTAssertEqual(store.note(withID: original.noteID)?.body, "Earlier paragraph\nStudent pricing")
        await XCTAssertTrueAsync(await controller.redoVersionRestoreDurably())
        XCTAssertTrue(controller.active === restored)
        XCTAssertEqual(store.note(withID: original.noteID)?.body, "Earlier paragraph")
    }

    func testTypingThenNativeUndoCanStillUndoRestoreAndNewEditClearsRestoreRedo() async throws {
        let (original, _) = try await history()
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let restored = try XCTUnwrap(controller.active)
        try type(" More typing")
        XCTAssertTrue(restored.engine.undoCommand())
        XCTAssertTrue(restored.engine.undoCommand())
        await controller.versionHistoryCommandTask?.value
        XCTAssertTrue(controller.active === original)
        try type(" A new direction")
        await XCTAssertFalseAsync(await controller.redoVersionRestoreDurably())
        XCTAssertTrue(controller.active === original)
        XCTAssertTrue(original.engine.document().blocks.last?.text.contains("A new direction") == true)
    }

    func testAutosaveAfterTypingAndUndoKeepsRestoreUndoAndEarlierHistoryKeepsRestoreRedo() async throws {
        let (original, _) = try await history()
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let restored = try XCTUnwrap(controller.active)
        try type(" temporary")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertTrue(restored.engine.undoCommand())
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertTrue(restored.engine.undoCommand())
        await controller.versionHistoryCommandTask?.value
        XCTAssertTrue(controller.active === original)
        XCTAssertTrue(original.engine.undoCommand())
        XCTAssertTrue(original.engine.redoCommand())
        await XCTAssertTrueAsync(await controller.redoVersionRestoreDurably())
        XCTAssertTrue(controller.active === restored)
    }

    func testRedoTraversesEarlierTagUndoBeforeRedoingRestore() async throws {
        let (original, _) = try await history()
        controller.closeHistory()
        original.engine.setTagsFromPicker(["research"])
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        await XCTAssertTrueAsync(await controller.undoVersionRestoreDurably(expectedID: controller.versionRestoreUndoID))
        XCTAssertTrue(original.engine.undoCommand())
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(original.engine.tags, [])
        XCTAssertTrue(original.engine.redoCommand())
        await controller.versionHistoryCommandTask?.value
        XCTAssertTrue(controller.active === original)
        XCTAssertEqual(original.engine.tags, ["research"])
        await XCTAssertTrueAsync(await controller.redoVersionRestoreDurably())
    }

    func testNewEditDuringUndoDurabilityWaitIsKeptEvenWhenItAutosaves() async throws {
        let journal = SuspendedHistoryJournal(directory: ownedTemporaryDirectory(prefix: "S7UndoRace"))
        controller = NotesPageController(store: store, journal: journal,
            saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        let (original, _) = try await history()
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let restored = try XCTUnwrap(controller.active)
        try type(" temporary")
        XCTAssertTrue(restored.engine.undoCommand())
        let waiting = expectation(description: "Undo is waiting for retirement")
        var resume: CheckedContinuation<Void, Never>?
        journal.beforeRetire = {
            journal.beforeRetire = nil
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
        }
        let ticket = controller.versionRestoreUndoID
        let undo = Task { await controller.undoVersionRestoreDurably(expectedID: ticket) }
        await fulfillment(of: [waiting], timeout: 5)
        try type(" New work while waiting")
        XCTAssertTrue(controller.save(restored))
        resume?.resume()
        await XCTAssertFalseAsync(await undo.value)
        await controller.waitForRecoveryWork()
        XCTAssertTrue(controller.active === restored)
        XCTAssertTrue(restored.engine.document().blocks.last?.text.contains("New work while waiting") == true)
        XCTAssertTrue(store.note(withID: original.noteID)?.body.contains("New work while waiting") == true)
    }

    func testComparisonAndPreviewPreserveMonoTablesAndImages() throws {
        let image = NoteBlock.image(attachmentID: UUID())
        let table = NoteBlock.table(NoteTable(texts: [["Name", "Value"], ["Earlier", "42"]]))
        var old = NoteDocument(blocks: [.text("Note"), .text("code", style: "mono"), table, image])
        old.refreshRequiredCapabilities()
        let current = NoteDocument(blocks: [.text("Note"), .text("code", style: "mono")])
        let comparison = NoteHistoryComparison(shown: old, other: current, missingLabel: "Not in this version")
        XCTAssertEqual(comparison.differingCount, 2)
        XCTAssertEqual(comparison.document.blocks, old.blocks)
        XCTAssertEqual(comparison.changedBlocks, [2, 3])
        let inverse = NoteHistoryComparison(shown: current, other: old, missingLabel: "Not in Current")
        XCTAssertEqual(inverse.missing, [table, image])
        XCTAssertTrue(NoteTextExport.plainText(inverse.document).contains("Earlier"))
        let engine = NoteEditorEngine(noteID: UUID(), document: comparison.document, readOnly: true)
        XCTAssertEqual(engine.document(), old)
    }

    func testComparisonNamesMissingTextInPlaceAndDoesNotCallFormattingMissing() {
        let old = NoteDocument(blocks: [.text("Title"), .text("Earlier paragraph"), .text("Anchor")])
        let current = NoteDocument(blocks: [.text("Title"), .text("Current paragraph"), .text("Added"), .text("Anchor")])
        let comparison = NoteHistoryComparison(shown: old, other: current, missingLabel: "Not in this version")
        XCTAssertEqual(comparison.document.blocks[1].text, "Earlier paragraph")
        XCTAssertTrue(comparison.document.blocks[2].text.contains("Not in this version: “Current paragraph”"))
        var styled = old
        styled.blocks[1].style = "mono"
        let formatOnly = NoteHistoryComparison(shown: old, other: styled, missingLabel: "Not in this version")
        XCTAssertTrue(formatOnly.missing.isEmpty)
        XCTAssertEqual(formatOnly.changedBlocks, [1])
        XCTAssertEqual(formatOnly.differingCount, 1)
    }
}

@MainActor
private final class SuspendedHistoryJournal: NoteDraftJournaling {
    struct CacheUnavailable: Error {}
    let base: NoteDraftJournal
    var beforeRetire: (() async -> Void)?
    var requiresAsyncIO: Bool { true }
    init(directory: URL) { base = NoteDraftJournal(directory: directory) }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                      replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        await beforeRetire?()
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] {
        // An unavailable synchronous cache sends retirement through the
        // production asynchronous path, where this test controls the wait.
        if beforeRetire != nil { throw CacheUnavailable() }
        return try base.recoveryEntries()
    }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        try await base.discardOwnedDurably(noteID: noteID, claim: claim)
    }
}
