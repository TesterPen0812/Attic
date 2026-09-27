import AppKit
import SwiftData
import CryptoKit
import XCTest
@testable import Attic

/// Durable drafts per note (critique finding 1): saves within the coalescing
/// delay, save-or-checkpoint before navigation, "Only in memory" when both
/// fail, recovery first on reopen, versions on leave, pending agent edits
/// applied on leave.
@MainActor
final class NotesPageControllerTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticNoteDrafts-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(journal: NoteDraftJournaling? = nil, delay: Duration = .seconds(60)) -> NotesPageController {
        NotesPageController(store: store, journal: journal ?? NoteDraftJournal(directory: directory),
                            saveDelay: delay, pauseVersionDelay: .seconds(600))
    }

    private func type(_ text: String, into session: NoteSession) {
        let engine = session.engine
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: text), name: "Typing")
    }

    private func realImage() throws -> StagedNoteAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertNotNil(NoteImageDecoder.thumbnail(of: bytes, maxPixel: 32))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return StagedNoteAttachment(id: UUID(), filename: "pixel.png", contentTypeIdentifier: "public.png",
                                    byteCount: Int64(bytes.count), digest: digest, data: bytes)
    }

    func testANewDraftIsSavedOnlyOnceItHasContent() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        XCTAssertFalse(session.isPersisted)
        XCTAssertTrue(controller.newNote(), "an untouched draft stays")
        XCTAssertTrue(controller.preserveAll())
        XCTAssertTrue(store.notes.isEmpty, "an empty draft is never saved")
        type("Groceries", into: session)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.notes.map(\.title), ["Groceries"])
        XCTAssertTrue(session.isPersisted)
    }

    func testTypingIsSavedWithinTheCoalescingDelay() async throws {
        let controller = makeController(delay: .milliseconds(50))
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Quick", into: session)
        XCTAssertTrue(store.notes.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.notes.first?.title, "Quick")
        XCTAssertFalse(session.isDirty)
    }

    func testTypingDuringOffActorAutosaveRejectsTheStaleProjection() async throws {
        let preparer = DelayedDocumentPreparer()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .milliseconds(10),
                                             prepareDocument: { document in await preparer.prepare(document) })
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("First", into: session)
        for _ in 0..<100 {
            if await preparer.started > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let preparationsStarted = await preparer.started
        XCTAssertGreaterThan(preparationsStarted, 0)
        let started = DispatchTime.now().uptimeNanoseconds
        type(" second", into: session)
        let typingMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("NOTE_TYPING_OVERLAP_AUTOSAVE_MS=\(typingMilliseconds)")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.notes.first?.title, "First second")
        XCTAssertFalse(session.isDirty)
    }

    func testMeasuredMainActorSaveOnFiveThousandLineNote() throws {
        let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail("large note fixture")
        }
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        var milliseconds: [Double] = []
        var extractionMilliseconds: [Double] = []
        var preparedCommitMilliseconds: [Double] = []
        for _ in 0..<8 {
            type("x", into: session)
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(controller.save(session))
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)

            type("y", into: session)
            let extractionStart = DispatchTime.now().uptimeNanoseconds
            let snapshot = session.engine.document()
            extractionMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - extractionStart) / 1_000_000)
            let prepared = try PreparedNoteDocument(snapshot)
            let preparedStart = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(controller.save(session, snapshot: snapshot, stagedSnapshot: [], prepared: prepared))
            preparedCommitMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - preparedStart) / 1_000_000)
        }
        let sorted = milliseconds.sorted()
        let extractionSorted = extractionMilliseconds.sorted()
        let preparedSorted = preparedCommitMilliseconds.sorted()
        print("NOTE_SAVE_5000_LINES_MS_MEDIAN=\(sorted[sorted.count / 2])")
        print("NOTE_SAVE_5000_LINES_MS_MAX=\(sorted.last ?? 0)")
        print("NOTE_EXTRACT_5000_LINES_MS_MEDIAN=\(extractionSorted[extractionSorted.count / 2])")
        print("NOTE_EXTRACT_5000_LINES_MS_MAX=\(extractionSorted.last ?? 0)")
        print("NOTE_PREPARED_COMMIT_5000_LINES_MS_MEDIAN=\(preparedSorted[preparedSorted.count / 2])")
        print("NOTE_PREPARED_COMMIT_5000_LINES_MS_MAX=\(preparedSorted.last ?? 0)")
        XCTAssertTrue(store.versions(noteID: id).isEmpty)
    }

    func testFailedSaveIsCheckpointedBeforeNavigationAndRetrySavesIt() throws {
        let controller = makeController()
        controller.start()
        let first = try XCTUnwrap(controller.active)
        type("Draft one", into: first)
        gate.shouldFail = true
        XCTAssertTrue(controller.newNote(), "a checkpoint lets navigation go on")
        guard case .notSaved = first.problem else { return XCTFail("slot says Not saved") }
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(try NoteDraftJournal(directory: directory).entries().count, 1)
        XCTAssertTrue(controller.failedDrafts.contains { $0 === first })
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(controller.openFailedDraft(sessionID: first.id))
        XCTAssertTrue(controller.active === first)

        gate.shouldFail = false
        XCTAssertTrue(controller.preserve(first), "Retry")
        XCTAssertNil(first.problem)
        XCTAssertEqual(store.notes.map(\.title), ["Draft one"])
        XCTAssertTrue(try NoteDraftJournal(directory: directory).entries().isEmpty, "the checkpoint goes once saved")
    }

    func testWhenStoreAndCheckpointBothFailTheDraftStaysAndNavigationIsRefused() throws {
        let journal = FailingJournal()
        let controller = makeController(journal: journal)
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Precious", into: session)
        gate.shouldFail = true
        XCTAssertFalse(controller.newNote())
        XCTAssertTrue(controller.active === session, "the session is never replaced")
        guard case .onlyInMemory = session.problem else { return XCTFail("slot says Only in memory") }
        XCTAssertFalse(controller.preserveAll(), "hide and quit are refused")
        XCTAssertTrue(session.engine.plainText.contains("Precious"))
        gate.shouldFail = false
        controller.retry()
        XCTAssertNil(session.problem)
        XCTAssertTrue(controller.newNote())
    }

    func testRealShellPageSwitchRefusesToLeaveAnUnrecoverableNativeDraft() throws {
        let suite = "AtticNotesNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let taskStore = TaskStore(container: container)
        let noteStore = NoteStore(container: container, persist: { [gate] in try gate!.save($0) },
                                  attachmentFileStore: makeTestAttachmentFileStore())
        let noteDraft = NoteDraftController(noteStore: noteStore, sessionDefaults: defaults)
        let state = PanelUIState()
        state.selectSection(.notes)
        let settings = AppSettings(defaults: defaults)
        let view = AtticPanelView(store: taskStore, noteStore: noteStore,
                                  canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                  noteDraft: noteDraft, chromeInteractionState: PanelChromeInteractionState(),
                                  uiState: state, settings: settings,
                                  subtaskPanels: SubtaskPanelController(store: taskStore, uiState: state,
                                                                         settings: settings))
        noteDraft.pages.start()
        let draft = try XCTUnwrap(noteDraft.pages.active)
        type("Only in memory", into: draft)
        gate.shouldFail = true
        view.selectSection(.tasks)
        XCTAssertEqual(state.selectedSection, .notes)
        XCTAssertTrue(noteDraft.pages.active === draft)
        guard case .onlyInMemory = draft.problem else { return XCTFail("both saves failed") }
        XCTAssertEqual(draft.engine.document().title, "Only in memory")
    }

    func testNavigationRefusesAnActiveNativeComposition() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        let (_, textView) = session.engine.makeView()
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertFalse(controller.preserveAll())
        XCTAssertFalse(controller.leaveForNavigation())
        XCTAssertNotNil(session.notice)
        textView.unmarkText()
        XCTAssertTrue(controller.leaveForNavigation())
    }

    func testRecoveredDraftOpensFirstAndIsSaved() throws {
        let existing = makeController()
        existing.start()
        let session = try XCTUnwrap(existing.active)
        type("Saved text", into: session)
        XCTAssertTrue(existing.preserveAll())
        let noteID = session.noteID
        type(" and more", into: session)
        gate.shouldFail = true
        XCTAssertTrue(existing.preserveAll())   // checkpointed
        gate.shouldFail = false

        // Relaunch.
        let relaunched = makeController()
        relaunched.start()
        let recovered = try XCTUnwrap(relaunched.active)
        XCTAssertEqual(recovered.noteID, noteID)
        XCTAssertEqual(recovered.notice, "Restored unsaved text.")
        XCTAssertNil(recovered.problem)
        XCTAssertEqual(store.note(withID: noteID)?.title, "Saved text and more")
        XCTAssertTrue(try NoteDraftJournal(directory: directory).entries().isEmpty)
    }

    func testLeavingANoteKeepsAVersionAndAppliesAWaitingAgentEdit() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Plan", into: session)
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID
        XCTAssertEqual(store.openDocumentNoteIDs(), [id])
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                         document: NoteDocument(blocks: [.text("Agent plan")]),
                                                         agentName: "Claude", noteIsOpen: store.openDocumentNoteIDs().contains(id)) else {
            return XCTFail()
        }
        XCTAssertTrue(controller.newNote())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plan")
        XCTAssertTrue(store.versions(noteID: id).contains { $0.title == "Plan" },
                      "the state before the pending edit is retained")
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertEqual(controller.active?.engine.document().title, "Agent plan", "the reopened note shows the applied edit")
    }

    func testAgentWriteWhileHiddenBecomesAProposalAndCannotBeOverwrittenByTyping() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID
        XCTAssertTrue(controller.preserveForHide())
        XCTAssertTrue(store.openDocumentNoteIDs().contains(id))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            noteIsOpen: store.openDocumentNoteIDs().contains(id)) else { return XCTFail() }
        controller.panelDidShow()
        type(" and mine", into: session)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.note(withID: id)?.title, "Mine and mine")
        let comparison = try XCTUnwrap(controller.proposalComparison(for: session))
        XCTAssertEqual(comparison.current, "Mine and mine")
        XCTAssertEqual(comparison.proposed, "Agent")
        XCTAssertTrue(controller.showLibrary())
        let proposal = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        XCTAssertTrue(proposal.needsReview)
        XCTAssertEqual(proposal.proposedContent.flatMap { NoteContentCodec.decode($0).document?.title }, "Agent")
        controller.dismissLibrary()
        XCTAssertEqual(controller.active?.engine.document().title, "Mine and mine")
    }

    func testPendingAgentEditAppliedOnLeaveReloadsTheRetainedSession() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID
        XCTAssertTrue(controller.preserveForHide())
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            noteIsOpen: store.openDocumentNoteIDs().contains(id)) else { return XCTFail() }
        controller.panelDidShow()
        XCTAssertTrue(controller.showLibrary())
        controller.dismissLibrary()
        XCTAssertEqual(controller.active?.engine.document().title, "Agent")
        let reloaded = try XCTUnwrap(controller.active)
        type(" plus mine", into: reloaded)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plus mine")
    }

    func testAgentWriteInLibraryCannotStaleSaveOnReopen() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID
        XCTAssertTrue(controller.showLibrary())
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            noteIsOpen: store.openDocumentNoteIDs().contains(id)) else { return XCTFail() }
        XCTAssertTrue(controller.open(noteID: id))
        controller.dismissLibrary()
        type(" and mine", into: try XCTUnwrap(controller.active))
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testStagedImageIsCommittedWithTheSaveThatShowsIt() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Pics", into: session)
        let item = StagedNoteAttachment(id: UUID(), filename: "a.png", contentTypeIdentifier: "public.png", byteCount: 3,
                                        digest: String(repeating: "b", count: 64), data: Data([1, 2, 3]))
        session.engine.insertImage(item, pixelSize: CGSize(width: 10, height: 10))
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(try store.attachmentRows(forNoteID: session.noteID).map(\.id), [item.id])
        XCTAssertTrue(session.engine.staged.isEmpty)
    }

    func testSavedImageDecodesAfterDiscardingSessionAndReopening() async throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Image", into: session)
        let image = try realImage()
        session.engine.insertImage(image, pixelSize: CGSize(width: 1, height: 1))
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID

        let reopened = makeController()
        XCTAssertTrue(reopened.open(noteID: id))
        let reopenedEngine = try XCTUnwrap(reopened.active?.engine)
        for _ in 0..<30 {
            if reopenedEngine.objects().compactMap({ $0.0 as? NoteImageAttachment }).first?.renderedImage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let loaded = try XCTUnwrap(reopenedEngine.objects().compactMap({ $0.0 as? NoteImageAttachment }).first)
        XCTAssertFalse(loaded.isMissing)
        XCTAssertNotNil(loaded.renderedImage)
    }

    func testCrossNotePasteCopiesImageFromFailedSourceDraft() throws {
        let controller = makeController()
        controller.start()
        let source = try XCTUnwrap(controller.active)
        type("Source", into: source)
        let image = try realImage()
        source.engine.insertImage(image, pixelSize: CGSize(width: 2, height: 2))
        gate.shouldFail = true
        XCTAssertTrue(controller.preserveAll(), "the failed source stays in recovery")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-failed-source-\(UUID().uuidString)"))
        XCTAssertTrue(source.engine.writeSelection(NSRange(location: 0, length: source.engine.textStorage.length),
                                                   to: pasteboard, types: [NoteEditorEngine.fragmentType]))
        let fragment = try XCTUnwrap(pasteboard.data(forType: NoteEditorEngine.fragmentType))
        XCTAssertTrue(controller.newNote())
        let destination = try XCTUnwrap(controller.active)
        XCTAssertTrue(destination.engine.paste(fragmentData: fragment, at: NSRange(location: 0, length: 0)))
        let newImageID = try XCTUnwrap(destination.engine.document().attachmentIDs.first)
        XCTAssertNotEqual(newImageID, image.id)
        gate.shouldFail = false
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(try store.attachmentRows(forNoteID: destination.noteID).first?.id, newImageID)
    }

    func testDelayedImageBatchReservesOrderDuringTypingAndCommitsTogether() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .milliseconds(10),
                                             imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Start", into: draft)
        XCTAssertTrue(controller.preserveAll())
        controller.importImages([URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")])
        let reserved = draft.engine.document().attachmentIDs
        XCTAssertEqual(reserved.count, 2)
        type(" while loading", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertNil(draft.problem, "a normal import is waiting, not a failed save")
        await loader.releaseNext(success: true)
        await waitForImageRequests(loader, count: 2)
        XCTAssertTrue(try store.attachmentRows(forNoteID: draft.noteID).isEmpty,
                      "a partial batch must not commit")
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if (try? store.attachmentRows(forNoteID: draft.noteID).count) == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try store.attachmentRows(forNoteID: draft.noteID).count, 2)
        XCTAssertEqual(store.loadDocument(noteID: draft.noteID)?.content.document?.attachmentIDs, reserved)
        XCTAssertTrue(store.loadDocument(noteID: draft.noteID)?.content.document?.blocks.last?.text.contains("while loading") == true)
    }

    func testImageBatchNavigationCancelsLateResultsAndKeepsTypedText() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        XCTAssertTrue(controller.preserveAll())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/delayed.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(controller.newNote())
        XCTAssertTrue(draft.notice?.contains("cancelled") == true)
        await loader.releaseNext(success: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.attachmentIDs, [])
        XCTAssertTrue(store.loadDocument(noteID: id)?.content.document?.blocks.last?.text.contains("after") == true)
        XCTAssertTrue(try store.attachmentRows(forNoteID: id).isEmpty)
    }

    func testHiddenImportContinuesAndCommitsToItsOriginalNote() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        XCTAssertTrue(controller.preserveAll())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/hidden.png")])
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(controller.preserveForHide())
        XCTAssertNil(draft.problem)
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if (try? store.attachmentRows(forNoteID: id).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.panelDidShow()
        XCTAssertEqual(try store.attachmentRows(forNoteID: id).count, 1)
        XCTAssertEqual(controller.active?.engine.document().attachmentIDs.count, 1)
    }

    func testHideRefusedWhenRunningImportHasNoRecoveryJournal() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(60),
            imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        XCTAssertTrue(controller.preserveAll())
        controller.importImages([URL(fileURLWithPath: "/tmp/no-journal.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertFalse(controller.preserveForHide())
        guard case .onlyInMemory = draft.problem else { return XCTFail("the failed hide must be visible") }
        XCTAssertTrue(controller.active === draft)
        await loader.releaseNext(success: true)
    }

    func testImageBatchDeletedDestinationStaysInRecoveryWithoutResurrection() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        XCTAssertTrue(controller.preserveAll())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/delayed.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        await loader.releaseNext(success: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(draft.noteID, id)
        XCTAssertEqual(try NoteDraftJournal(directory: directory).entries().count, 1)
    }

    func testImageBatchFailureCancelsEveryReservation() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Text", into: draft)
        controller.importImages([URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")])
        await waitForImageRequests(loader, count: 1)
        await loader.releaseNext(success: true)
        await waitForImageRequests(loader, count: 2)
        await loader.releaseNext(success: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(draft.engine.document().attachmentIDs, [])
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Text")
        XCTAssertTrue(try store.attachmentRows(forNoteID: draft.noteID).isEmpty)
    }

    func testWritingToolsRefusesRewriteWhenVersionCannotCommit() throws {
        let controller = makeController()
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Original prose", into: draft)
        XCTAssertTrue(controller.preserveAll())
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        XCTAssertFalse(draft.engine.allowsChange(ranges: [NSRange(location: 0, length: 1)]))
        XCTAssertTrue(draft.notice?.contains("recovery version") == true)
        draft.engine.writingToolsDidEnd()
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Original prose")
    }

    func testRefusedWritingToolsBypassRestoresTextAndDoesNotAutosave() async throws {
        let controller = makeController(delay: .milliseconds(20))
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Original prose", into: draft)
        XCTAssertTrue(controller.preserveAll())
        let savedRevision = store.note(withID: draft.noteID)?.revisionID
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        let whole = NSRange(location: 0, length: draft.engine.textStorage.length)
        draft.engine.textStorage.replaceCharacters(in: whole, with: NSAttributedString(string: "Unrequested rewrite"))
        XCTAssertEqual(draft.engine.document().title, "Unrequested rewrite")
        draft.engine.writingToolsDidEnd()
        gate.shouldFail = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(draft.engine.document().title, "Original prose")
        XCTAssertEqual(store.note(withID: draft.noteID)?.revisionID, savedRevision)
    }

    func testUnreadableDocumentOpensAnExplanatoryReadOnlySession() throws {
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Before")])) else { return XCTFail() }
        for row in try store.modelContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
            row.content = Data("broken bytes".utf8)
        }
        try store.modelContext.save()
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertTrue(controller.active?.isReadOnly == true)
        guard case .unreadable = controller.active?.readOnlyReason else {
            return XCTFail("the status slot must explain the unreadable document")
        }
        XCTAssertEqual(controller.active?.engine.document().title, "")
    }

    func testSuccessfulSessionRestoresSelectionAndScrollState() throws {
        let suite = "AtticNoteViewState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             defaults: defaults, saveDelay: .seconds(60))
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Title\n" + String(repeating: "A long line of text\n", count: 100), into: draft)
        XCTAssertTrue(controller.preserveAll())
        let id = draft.noteID
        let (scroll, _) = draft.engine.makeView()
        draft.engine.onSelectionChange?(NSRange(location: 5, length: 3))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 120))
        XCTAssertTrue(controller.preserveAll())

        let reopened = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                           defaults: defaults)
        XCTAssertTrue(reopened.open(noteID: id))
        XCTAssertEqual(reopened.active?.selection, NSRange(location: 5, length: 3))
        XCTAssertEqual(reopened.active?.scrollOffset ?? -1, 120, accuracy: 0.5)
    }

    private func waitForImageRequests(_ loader: DelayedImageLoader, count: Int) async {
        for _ in 0..<100 {
            if await loader.started >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("image loader did not start \(count) requests")
    }

    func testRecoveryReadsValidEntriesBesideCorruptAndMissingImageEntries() throws {
        let journal = NoteDraftJournal(directory: directory)
        let bytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Valid")]))
        let valid = NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil, content: bytes,
                                          selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        try journal.write(valid, staged: [])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        let image = try realImage()
        let incomplete = NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil, content: bytes,
                                               selectionLocation: 0, selectionLength: 0,
                                               staged: [.init(id: image.id, filename: image.filename,
                                                              contentTypeIdentifier: image.contentTypeIdentifier,
                                                              byteCount: image.byteCount, digest: image.digest)], savedAt: Date())
        try journal.write(incomplete, staged: [image])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("staged/\(image.id.uuidString)"))
        let results = try journal.recoveryEntries()
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.filter { if case .valid = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(results.filter { if case .damaged = $0 { return true }; return false }.count, 2)
        let controller = makeController()
        controller.start()
        XCTAssertEqual(controller.active?.engine.document().title, "Valid")
        XCTAssertEqual(controller.recoveryWarnings.count, 2)
    }

    func testDamagedRecoveryIsVisibleWhenLastViewedNoteOpens() throws {
        guard case let .success(created) = store.createDocumentNote(id: UUID(),
                                                                     document: NoteDocument(blocks: [.text("Saved")])) else {
            return XCTFail("saved note fixture")
        }
        let suiteName = "AtticRecoveryTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(created.noteID.uuidString, forKey: "notes.lastViewedNote.v2")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("corrupt.json"))

        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             defaults: defaults)
        controller.start()
        XCTAssertEqual(controller.active?.noteID, created.noteID)
        XCTAssertEqual(controller.recoveryWarnings.count, 1)
        XCTAssertNotNil(controller.active?.notice)
    }

    func testDamagedRecoveryBlockingPurgeShowsAWarning() throws {
        let controller = makeController()
        controller.start()
        let draft = try XCTUnwrap(controller.active)
        type("Saved", into: draft)
        XCTAssertTrue(controller.preserveAll())
        let row = NoteAttachment(noteID: draft.noteID, originalFilename: "old.bin", byteCount: 1,
                                 sortIndex: 0, contentDigest: String(repeating: "a", count: 64), payload: Data([1]))
        store.modelContext.insert(row)
        try store.modelContext.save()
        XCTAssertTrue(store.removeAttachment(row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0)
        XCTAssertTrue(controller.recoveryWarnings.contains { $0.contains("keeping removed images") })
        XCTAssertTrue(draft.notice?.contains("keeping removed images") == true)
    }

    func testBothAttachmentPurgeRoutesRespectRecoveryReferences() throws {
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        _ = controller // installs the recovery reference provider on the store
        let image = try realImage()
        let legacy = try XCTUnwrap(store.create(title: "Legacy"))
        let removed = NoteAttachment(id: image.id, noteID: legacy.id, originalFilename: image.filename,
                                     contentTypeIdentifier: image.contentTypeIdentifier,
                                     byteCount: image.byteCount, sortIndex: 0,
                                     contentDigest: image.digest, payload: image.data)
        removed.deletedAt = .distantPast
        store.modelContext.insert(removed)
        try store.modelContext.save()
        let draftID = UUID()
        let bytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Recovered"),
                                                                .image(attachmentID: image.id)]))
        let entry = NoteDraftJournalEntry(noteID: draftID, isPersisted: false, baseRevisionID: nil,
                                          content: bytes, selectionLocation: 0, selectionLength: 0,
                                          staged: [], savedAt: Date())
        try journal.write(entry, staged: [])
        XCTAssertEqual(store.purgeRemovedAttachments(before: Date()), 0)
        try journal.remove(noteID: draftID)
        XCTAssertEqual(store.purgeRemovedAttachments(before: Date()), 1)

        let secondImage = try realImage()
        guard case let .success((id, _)) = store.createDocumentNote(
            id: UUID(), document: NoteDocument(blocks: [.text("Deleted"), .image(attachmentID: secondImage.id)]),
            staged: [secondImage]) else { return XCTFail() }
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        let otherDraftID = UUID()
        let otherBytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Recovered"),
                                                                     .image(attachmentID: secondImage.id)]))
        try journal.write(NoteDraftJournalEntry(noteID: otherDraftID, isPersisted: false, baseRevisionID: nil,
                                                content: otherBytes, selectionLocation: 0, selectionLength: 0,
                                                staged: [], savedAt: Date()), staged: [])
        XCTAssertFalse(store.purgeDeleted(before: .distantFuture).contains(id))
        try journal.remove(noteID: otherDraftID)
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).contains(id))
    }

    func testDeletedOriginalRecoveryFailureKeepsCheckpointThenNewNoteOwnsImages() async throws {
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container1 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let persistence = PersistenceGate()
        let files = makeTestAttachmentFileStore(rootURL: directory.appendingPathComponent("files"))
        let firstStore = NoteStore(container: container1, persist: { try persistence.save($0) },
                                   attachmentFileStore: files)
        let first = NotesPageController(store: firstStore, journal: NoteDraftJournal(directory: journalDirectory),
                                        saveDelay: .seconds(60))
        first.start()
        let draft = try XCTUnwrap(first.active)
        type("Original", into: draft)
        let image = try realImage()
        draft.engine.insertImage(image, pixelSize: CGSize(width: 1, height: 1))
        XCTAssertTrue(first.preserveAll())
        let oldID = draft.noteID
        XCTAssertTrue(firstStore.delete(try XCTUnwrap(firstStore.note(withID: oldID))))
        type(" later", into: draft)
        persistence.shouldFail = true
        XCTAssertTrue(first.preserveAll(), "failed store save must retain recovery")
        XCTAssertEqual(try NoteDraftJournal(directory: journalDirectory).entries().count, 1)

        let container2 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let secondStore = NoteStore(container: container2, persist: { try persistence.save($0) },
                                    attachmentFileStore: files)
        let second = NotesPageController(store: secondStore, journal: NoteDraftJournal(directory: journalDirectory),
                                         saveDelay: .seconds(60))
        second.start()
        XCTAssertEqual(try NoteDraftJournal(directory: journalDirectory).entries().count, 1,
                       "a second failed save must not retire the original checkpoint")
        persistence.shouldFail = false
        second.retry()
        let newID = try XCTUnwrap(second.active?.noteID)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertTrue(try NoteDraftJournal(directory: journalDirectory).entries().isEmpty)
        XCTAssertEqual(try secondStore.attachmentRows(forNoteID: newID).count, 1)
        XCTAssertTrue(secondStore.purgeDeleted(before: .distantFuture).contains(oldID))

        let container3 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let thirdStore = NoteStore(container: container3, attachmentFileStore: files)
        let third = NotesPageController(store: thirdStore, journal: NoteDraftJournal(directory: journalDirectory))
        XCTAssertTrue(third.open(noteID: newID))
        XCTAssertEqual(third.active?.engine.document().attachmentIDs.count, 1)
        XCTAssertNotNil(try thirdStore.attachmentRows(forNoteID: newID).first?.payload)
        let restoredImage = try XCTUnwrap(third.active?.engine.objects().compactMap { $0.0 as? NoteImageAttachment }.first)
        for _ in 0..<40 {
            if restoredImage.renderedImage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(restoredImage.isMissing)
        XCTAssertNotNil(restoredImage.renderedImage)
        await firstStore.waitForAttachmentReconciliation()
        await secondStore.waitForAttachmentReconciliation()
        await thirdStore.waitForAttachmentReconciliation()
    }
}

@MainActor
private final class FailingJournal: NoteDraftJournaling {
    struct Failure: Error {}
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws { throw Failure() }
    func remove(noteID: UUID) throws {}
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] { [] }
}

private actor DelayedDocumentPreparer {
    private(set) var started = 0

    func prepare(_ document: NoteDocument) async -> PreparedNoteDocument? {
        started += 1
        try? await Task.sleep(for: .milliseconds(200))
        return try? PreparedNoteDocument(document)
    }
}

private actor DelayedImageLoader {
    private(set) var started = 0
    private var pending: [CheckedContinuation<Bool, Never>] = []

    func load(_ url: URL, template: StagedNoteAttachment) async -> (StagedNoteAttachment, CGSize?)? {
        let success = await withCheckedContinuation { continuation in
            started += 1
            pending.append(continuation)
        }
        guard success else { return nil }
        return (template, CGSize(width: 2, height: 2))
    }

    func releaseNext(success: Bool) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: success)
    }
}
