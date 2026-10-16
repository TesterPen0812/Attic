import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class NoteHistoryBrowserTests: XCTestCase {
    func testU17PermanentPurgeReleasesDisplacedVersionRestoreSession() async throws {
        weak var displaced: NoteSession?
        var noteID: UUID!
        do {
            let (original, _) = try await history()
            noteID = original.noteID
            displaced = original
            await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        }
        XCTAssertNotNil(displaced, "version-restore Undo owns the displaced session before purge")
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: noteID))
        gate.shouldFail = true
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty)
        XCTAssertNotNil(displaced, "failed purge must preserve the existing Undo snapshot")
        XCTAssertNotNil(controller.versionRestoreUndoID)
        gate.shouldFail = false
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).contains(noteID))
        await controller.waitForRecoveryWork()
        XCTAssertNil(displaced, "purged note snapshots must be released")
        XCTAssertNil(controller.versionRestoreUndoID)
    }

    func testU32OnlyTheShownVersionAndItsViewportRequestImages() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let items = (0..<20).map { _ in
            StagedNoteAttachment(id: UUID(), filename: "Earlier.png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        let images = items.map { NoteBlock.image(attachmentID: $0.id, pixelWidth: 160, pixelHeight: 64) }
        let earlier = NoteDocument(blocks: [.text("History"), images[0]]
            + (0..<100).map { .text("Body paragraph \($0)") } + Array(images.dropFirst()))
        guard case let .success(created) = store.createDocumentNote(id: UUID(), document: earlier, staged: items) else {
            return XCTFail("Could not create the image fixture")
        }
        XCTAssertTrue(store.recordVersion(noteID: created.noteID, reason: .pause))
        guard case .success = store.saveDocument(noteID: created.noteID,
            document: NoteDocument(blocks: [.text("History"), .text("Current paragraph")]),
            baseRevisionID: created.revisionID) else { return XCTFail("Could not save Current") }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: created.noteID))
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        let browser = try XCTUnwrap(controller.historyBrowser)
        let unseen = try XCTUnwrap(browser.preview?.engine)
        let provider = HistoryImageProvider(base: controller)
        unseen.imageProvider = provider
        browser.showsCurrent = true
        controller.refreshHistoryPreview()
        let size = CGSize(width: 320, height: 464)
        let host = NSHostingView(rootView: NoteHistoryPage(controller: controller, browser: browser,
            layout: PanelPageLayout(cornerSize: 52, panelSize: size)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { controller.closeHistory(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(provider.requests.isEmpty, "Current's comparison labels must not load an unseen version's images")
        browser.showsCurrent = false
        controller.refreshHistoryPreview()
        let shown = try XCTUnwrap(browser.preview?.engine)
        shown.imageProvider = provider
        let attachments = shown.objects().compactMap { $0.0 as? NoteImageAttachment }
        let first = try XCTUnwrap(attachments.first)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if first.renderedImage != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(first.renderedImage, "the shown version's viewport loads within two seconds")
        XCTAssertFalse(first.isMissing)
        XCTAssertEqual(provider.requests, [items[0].id], "offscreen images are never requested")
        XCTAssertTrue(attachments.dropFirst().allSatisfy { $0.renderedImage == nil })
        XCTAssertTrue(unseen.objects().compactMap { $0.0 as? NoteImageAttachment }.allSatisfy { $0.renderedImage == nil })
        XCTAssertEqual(shown.document(), browser.comparison.document)
        XCTAssertFalse(shown.history.canUndo, "preview completion must not edit the note or create undo")
    }

    func testR14VersionRestoreKeepsLineBreakAndRunFields() async throws {
        var number = NoteBlock.text("item", style: "number"); number.start = 12
        var code = NoteBlock.text("a\u{2028}b", style: "mono"); code.language = "swift"
        var callout = NoteBlock.text("Tip", style: "quote"); callout.callout = "💡"
        let document = NoteDocument(blocks: [.text("T"), number, code, callout])
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: document) else { return XCTFail() }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        try type(" latest")
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
        let restored = try XCTUnwrap(controller.active?.engine.document())
        XCTAssertEqual(restored.blocks, document.blocks)
        XCTAssertTrue(restored.blocks[2].text.contains("\u{2028}"))
        XCTAssertEqual(restored.blocks[1].start, 12)
        XCTAssertEqual(restored.blocks[2].language, "swift")
        XCTAssertEqual(restored.blocks[3].callout, "💡")
    }

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

    func testR12FoldingCaretAndFindKeepTimestampHistoryAndRestoreRedo() async throws {
        for route in ["toggle", "caret", "find"] {
            var heading = NoteBlock.text("Section", style: "heading")
            heading.level = 1
            guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
                document: NoteDocument(blocks: [.text("Title"), heading, .text("Needle")])) else { return XCTFail() }
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
            try type(" latest")
            await XCTAssertTrueAsync(await controller.openHistoryDurably())
            let original = try XCTUnwrap(controller.active)
            await XCTAssertTrueAsync(await controller.restoreHistoryVersionDurably())
            await XCTAssertTrueAsync(await controller.undoVersionRestoreDurably(expectedID: controller.versionRestoreUndoID))
            XCTAssertTrue(controller.active === original)
            let engine = original.engine
            let (_, text) = engine.makeView()
            let timestamp = try XCTUnwrap(store.note(withID: id)).updatedAt
            let undoCount = engine.history.undoOps.count, redoCount = engine.history.redoOps.count
            XCTAssertTrue(engine.toggleHeadingFold(at: 6))
            if route == "toggle" { XCTAssertTrue(engine.toggleHeadingFold(at: 6)) }
            else if route == "caret" { text.setSelectedRange(NSRange(location: 14, length: 0)) }
            else { engine.find.show(); engine.find.query = "Needle" }
            XCTAssertTrue(engine.foldedHeadingIDs.isEmpty, route)
            XCTAssertEqual(engine.history.undoOps.count, undoCount, route)
            XCTAssertEqual(engine.history.redoOps.count, redoCount, route)
            XCTAssertEqual(original.state, .clean, route)
            await XCTAssertTrueAsync(await controller.preserveAllDurably())
            XCTAssertEqual(store.note(withID: id)?.updatedAt, timestamp, route)
            await XCTAssertTrueAsync(await controller.redoVersionRestoreDurably())
            XCTAssertEqual(controller.active?.engine.document().blocks.last?.text, "Needle", route)
        }
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
private final class HistoryImageProvider: NoteImageProviding {
    let base: NoteImageProviding
    var requests: [UUID] = []
    init(base: NoteImageProviding) { self.base = base }
    func fileURL(forAttachment id: UUID) async -> URL? {
        requests.append(id)
        return await base.fileURL(forAttachment: id)
    }
    func filename(forAttachment id: UUID) -> String? { base.filename(forAttachment: id) }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? { base.imageBytes(forAttachment: id) }
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
