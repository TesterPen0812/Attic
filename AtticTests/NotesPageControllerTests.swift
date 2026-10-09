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
        directory = ownedTemporaryDirectory(prefix: "AtticNoteDrafts")
    }

    override func tearDown() async throws {

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

    func testANewDraftIsSavedOnlyOnceItHasContent() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertFalse(session.isPersisted)
        await XCTAssertTrueAsync(await controller.newNoteDurably(), "an untouched draft stays")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertTrue(store.notes.isEmpty, "an empty draft is never saved")
        type("Groceries", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.notes.map(\.title), ["Groceries"])
        XCTAssertTrue(session.isPersisted)
    }

    #if !ATTIC_COST_REFERENCE_HOST
    /// Notes v2 tables: a cell edit (no character of the note changes) is
    /// an edit like any other: saved, journaled, and recovered after a
    /// failed save and a restart.
    func testATablesCellEditIsSavedJournaledAndRecovered() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Plan\n", into: session)
        let engine = session.engine
        XCTAssertTrue(engine.insertTable(NoteTable(texts: [["Pillar", "What happened"], ["Integrity", ""]]),
                                         replacing: NSRange(location: engine.textStorage.length, length: 0),
                                         name: "Insert Table", entering: false))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let table = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
        XCTAssertTrue(engine.changeTable(table, name: "Typing") { $0[NoteTable.Position(row: 1, column: 1)] = NoteTable.Cell("Encrypted") })
        if case .dirty = session.state {} else { XCTFail("a cell edit marks the note as changed") }
        gate.shouldFail = true
        // The store refuses; the edit is kept in the recovery journal instead.
        _ = await controller.preserveAllDurably()
        XCTAssertFalse(try journal.entries().isEmpty, "the cell edit is in the recovery journal")
        gate.shouldFail = false
        let restarted = makeController(journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        let recovered = try XCTUnwrap(restarted.active)
        XCTAssertEqual(recovered.noteID, session.noteID)
        XCTAssertEqual(recovered.engine.document().blocks.first { $0.kind == .table }?.table?[NoteTable.Position(row: 1, column: 1)].text,
                       "Encrypted")
    }
    #endif

    func testInvalidCheckpointNeverWritesEmptyBytesOrClaimsRecoveryAfterRestart() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Title\nBody", into: session)
        let body = (session.engine.textStorage.string as NSString).range(of: "Body")
        session.engine.textStorage.addAttribute(.noteBlockIndent, value: 2, range: body)
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.preserveAllDurably())
        if case .onlyInMemory = session.state {} else { XCTFail("encoding failure must remain only in memory") }
        XCTAssertTrue(try journal.entries().isEmpty)
        let restarted = makeController(journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        XCTAssertNotEqual(restarted.active?.noteID, session.noteID)
    }

    func testIndentedChecklistRemovalRecoversAfterFailedSaveAndRestart() async throws {
        var item = NoteBlock.checklist("Keep marks")
        item.indent = 2
        item.marks = [NoteMark(.bold, offset: 0, length: 4)]
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("T"), item])) else {
            return XCTFail("fixture")
        }
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let (_, view) = session.engine.makeView()
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(session.engine.document().blocks[1].kind, .text)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let checkpoint = try XCTUnwrap(journal.entries().first?.0)
        XCTAssertFalse(checkpoint.content.isEmpty)
        let restarted = makeController(journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        await XCTAssertTrueAsync(await restarted.openDurably(noteID: id))
        let recovered = try XCTUnwrap(restarted.active?.engine.document().blocks[1])
        XCTAssertEqual(recovered.kind, .text)
        XCTAssertEqual(recovered.text, "Keep marks")
        XCTAssertEqual(recovered.marks, item.marks)
        XCTAssertNil(recovered.indent)
    }

    func testTagPickerUndoPreservesExternalTagAfterSessionRefresh() async throws {
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("T"), .text("Body")])) else {
            return XCTFail("fixture")
        }
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.setTagsFromPicker(["picker"])
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertTrue(store.setTags(["picker", "external"], for: try XCTUnwrap(store.note(withID: id))))
        controller.present()
        XCTAssertEqual(Set(session.engine.tags), ["picker", "external"])
        XCTAssertTrue(session.engine.history.undo())
        XCTAssertEqual(Set(session.engine.tags), ["external"])
        XCTAssertTrue(session.engine.history.redo())
        XCTAssertEqual(Set(session.engine.tags), ["picker", "external"])
    }

    private func waitForDeadlineWrite(_ journal: CountingDeadlineJournal, count: Int = 1) async throws {
        for _ in 0..<200 {
            if journal.writeCount >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The durability deadline did not checkpoint")
    }

    func testIdleFailedStoreDoesNotRearmItsDurabilityDeadline() async throws {
        var attempts = 0
        let failingStore = try makeTestNoteStore(persist: { _ in
            attempts += 1
            throw PersistenceGate.Failure()
        }, attachmentFileStore: makeTestAttachmentFileStore())
        let journal = CountingDeadlineJournal(directory: directory)
        let controller = NotesPageController(store: failingStore, journal: journal,
            saveDelay: .seconds(60), durabilityDelay: .milliseconds(40))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("One edit", into: session)
        try await waitForDeadlineWrite(journal)
        await controller.waitForRecoveryWork()
        let firstAttempts = attempts, firstWrites = journal.writeCount
        XCTAssertGreaterThan(firstAttempts, 0)
        XCTAssertEqual(firstWrites, 1)
        try await Task.sleep(for: .milliseconds(240))
        await controller.waitForRecoveryWork()
        XCTAssertLessThanOrEqual(attempts - firstAttempts, 1)
        XCTAssertEqual(journal.writeCount, firstWrites)
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state))
        // A later keystroke must still arm a new deadline.
        type(" again", into: session)
        try await waitForDeadlineWrite(journal, count: firstWrites + 1)
        await controller.waitForRecoveryWork()
        XCTAssertGreaterThan(attempts, firstAttempts)
        XCTAssertEqual(journal.writeCount, firstWrites + 1)
    }

    func testIdleConflictDoesNotRearmItsDurabilityDeadline() async throws {
        let journal = CountingDeadlineJournal(directory: directory)
        let controller = NotesPageController(store: store, journal: journal,
            saveDelay: .seconds(60), durabilityDelay: .milliseconds(40))
        let id = UUID()
        guard case let .success((_, revision)) = store.createDocumentNote(id: id,
            document: NoteDocument(blocks: [.text("Original")])) else { return XCTFail("fixture") }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type("One edit", into: session)
        guard case .success = store.saveDocument(noteID: id,
            document: NoteDocument(blocks: [.text("External")]), baseRevisionID: revision) else { return XCTFail("fixture") }
        XCTAssertFalse(controller.save(session))
        XCTAssertEqual(session.state, .conflict(.changed))
        try await waitForDeadlineWrite(journal)
        await controller.waitForRecoveryWork()
        let firstWrites = journal.writeCount
        XCTAssertEqual(firstWrites, 1)
        let saves = gate.saveCount
        try await Task.sleep(for: .milliseconds(240))
        await controller.waitForRecoveryWork()
        XCTAssertLessThanOrEqual(journal.writeCount - firstWrites, 1)
        XCTAssertEqual(gate.saveCount, saves)
        XCTAssertEqual(session.state, .conflict(.changed))
    }

    func testContinuousTypingReachesTheProductionDiskJournalWithoutAPause() async throws {
        let preparer = ControlledDeadlinePreparer()
        let journal = CountingDeadlineJournal(directory: directory)
        let writeBarrier = DeadlineWriteBarrier()
        journal.beforeWrite = { await writeBarrier.pauseFirstWrite() }
        let controller = NotesPageController(store: store, journal: journal,
            saveDelay: .seconds(60), durabilityDelay: .milliseconds(20),
            prepareDocument: { document in await preparer.prepare(document) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        gate.shouldFail = true
        // The injected deadline fires independently of the coalescing timer.
        // Keep typing at both suspension boundaries; no real five-second wait
        // or scheduler-dependent character-count threshold is involved.
        for _ in 0..<60 { type("x", into: session) }
        try await waitForPreparations(preparer, count: 1)
        type("y", into: session)
        await preparer.release(0)
        try await waitForDeadlineWrite(journal)
        type("z", into: session)
        await writeBarrier.release()
        await controller.waitForRecoveryWork()
        let entries = try await NoteDraftJournal(directory: directory).entriesDurably()
        let saved = try XCTUnwrap(entries.first)
        let checkpoint = try XCTUnwrap(NoteContentCodec.decode(saved.0.content).document)
        XCTAssertEqual(checkpoint.title, String(repeating: "x", count: 60) + "y")
        XCTAssertEqual(session.engine.document().title, checkpoint.title + "z")
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state))
        // A second deadline, if it starts, is suspended by the preparer while
        // a new controller recovers the exact durable snapshot without a flush.
        let reopened = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                          saveDelay: .seconds(60))
        await reopened.startAndWait()
        XCTAssertEqual(reopened.active?.engine.document(), checkpoint)
        await preparer.release(1)
    }

    func testDeadlineRetainingNewerEditsReschedulesTheCoalescedSave() async throws {
        let preparer = ControlledDeadlinePreparer()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            prepareDocument: { document in await preparer.prepare(document) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("First", into: session)
        let deadline = Task { await controller.runDurabilityDeadline(session) }
        try await waitForPreparations(preparer, count: 1)
        type(" second", into: session)
        // Both prepares captured the old base revision. Complete the deadline
        // first: it must schedule a replacement for the stale coalesced save.
        try await waitForPreparations(preparer, count: 2)
        await preparer.release(0)
        await deadline.value
        XCTAssertEqual(store.notes.first?.title, "First")
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state))
        await preparer.release(1)
        // Await the scheduled 300 ms save, without firing another deadline.
        try await waitForPreparations(preparer, count: 3)
        for _ in 0..<200 {
            if !NoteSessionPolicy.hasPendingWork(session.state) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await controller.waitForRecoveryWork()
        XCTAssertEqual(store.notes.first?.title, "First second")
        XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state))
    }

    private func waitForPreparations(_ preparer: ControlledDeadlinePreparer, count: Int) async throws {
        for _ in 0..<200 {
            if await preparer.started >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected document preparation did not start")
    }

    func testDeadlineCommitsItsPreparedSnapshotAndLeavesNewerTextAndTagsDirty() async throws {
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), prepareDocument: { document in
                try? await Task.sleep(for: .milliseconds(100))
                return try? PreparedNoteDocument(document)
            })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("First", into: session)
        session.engine.setTags(["first"])
        let deadline = Task { await controller.runDurabilityDeadline(session) }
        try await Task.sleep(for: .milliseconds(30))
        type(" second", into: session)
        session.engine.setTags(["second"])
        await deadline.value
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "First")
        XCTAssertEqual(store.note(withID: session.noteID)?.tags, ["first"])
        XCTAssertEqual(session.engine.document().title, "First second")
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state))
        await controller.runDueSave(session)
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "First second")
        XCTAssertEqual(store.note(withID: session.noteID)?.tags, ["second"])
        XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state))
    }

    func testDeadlineWithAnEmptyFirstSnapshotKeepsNewerTypingDirty() async throws {
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), prepareDocument: { document in
                try? await Task.sleep(for: .milliseconds(100))
                return try? PreparedNoteDocument(document)
            })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Erase", into: session)
        _ = session.engine.performEdit(NSRange(location: 0, length: session.engine.textStorage.length),
                                       with: NSAttributedString(), name: "Delete")
        let deadline = Task { await controller.runDurabilityDeadline(session) }
        try await Task.sleep(for: .milliseconds(30))
        type("New text", into: session)
        await deadline.value
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state))
        XCTAssertTrue(store.notes.isEmpty)
        await controller.runDueSave(session)
        XCTAssertEqual(store.notes.first?.title, "New text")
        XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state))
    }

    func testTypingIsSavedWithinTheCoalescingDelay() async throws {
        let controller = makeController(delay: .milliseconds(50))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Quick", into: session)
        XCTAssertTrue(store.notes.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.notes.first?.title, "Quick")
        XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state))
    }

    func testTypingDuringOffActorAutosaveRejectsTheStaleProjection() async throws {
        let preparer = DelayedDocumentPreparer()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .milliseconds(10),
                                             prepareDocument: { document in await preparer.prepare(document) })
        await controller.startAndWait()
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
        XCTAssertFalse(NoteSessionPolicy.hasPendingWork(session.state))
    }

    func testMeasuredMainActorSaveOnFiveThousandLineNote() async throws {
        assertSaveBaseline(try await measureMainActorSave())
    }

    func testCheckpointRetirementKeepsMainActorWithinSaveTolerance() async throws {
        let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: document) else { return XCTFail("fixture") }
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let (_, view) = session.engine.makeView()
        var control: [Double] = [], checkpoint: [Double] = [], retireElapsed: [Double] = []
        // Warm both paths, then alternate their order. The probe measures the
        // longest main-actor blockage across save and retirement, excluding
        // off-actor decode and journal I/O time.
        for pair in -1..<8 {
            for hasCheckpoint in pair.isMultiple(of: 2) ? [false, true] : [true, false] {
                if hasCheckpoint {
                    type("b", into: session)
                    view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
                    XCTAssertTrue(controller.preserveAll(allowQueued: true))
                    await controller.waitForRecoveryWork()
                    XCTAssertFalse(try journal.entries().isEmpty)
                    view.unmarkText()
                }
                type("c", into: session)
                // Match production autosave's snapshot/preparation boundary.
                // Extraction and encoding precede its main-actor commit;
                // the checkpoint must not add a whole-body decode afterward.
                let snapshot = session.engine.document()
                let prepared = try await Task.detached { try PreparedNoteDocument(snapshot) }.value
                let probe = Task { @MainActor in
                    var worst = 0.0
                    while !Task.isCancelled {
                        let start = DispatchTime.now().uptimeNanoseconds
                        do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
                        worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 - 1)
                    }
                    return worst
                }
                // Arm the probe before the synchronous save and queued retire.
                try await Task.sleep(for: .milliseconds(2))
                let start = DispatchTime.now().uptimeNanoseconds
                XCTAssertTrue(controller.save(session, snapshot: snapshot, stagedSnapshot: [], prepared: prepared))
                let saveMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let retireStart = DispatchTime.now().uptimeNanoseconds
                await controller.waitForRecoveryWork()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - retireStart) / 1_000_000
                // Let a probe delayed by the last actor segment report it.
                try await Task.sleep(for: .milliseconds(2))
                probe.cancel()
                let occupancy = max(saveMS, await probe.value)
                XCTAssertTrue(try journal.entries().isEmpty)
                if pair >= 0 {
                    if hasCheckpoint { checkpoint.append(occupancy); retireElapsed.append(elapsed) }
                    else { control.append(occupancy) }
                }
            }
        }
        let baseline = control.sorted()[4], recovered = checkpoint.sorted()[4]
        print("NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=\(baseline) CHECKPOINT_MS_MEDIAN=\(recovered) RETIRE_ELAPSED_MS_MEDIAN=\(retireElapsed.sorted()[4]) MAX=\(retireElapsed.max()!)")
        print("ATTIC_INTEGRATION_COST recovery-main-actor median_ms=\(recovered)")
        print("ATTIC_COST_SAMPLES metric=recovery-main-actor raw_ms=\(checkpoint)")
        let overheadSamples = zip(checkpoint, control).map { $0 - $1 }
        print("ATTIC_COST_SAMPLES metric=recovery-overhead raw_ms=\(overheadSamples)")
        // OD-6: reference runs collect timings, never gate on their own timing
        // comparison. CI compares this paired overhead with the reference
        // build's overhead medians/range, alongside the total recovered cost.
        print("ATTIC_INTEGRATION_COST recovery-overhead median_ms=\(recovered - baseline)")
    }

    func testRecoveryRetirementKeepsCheckpointOnFailedOrStaleDecode() async throws {
        for failure in ["decode", "bytes", "revision", "tags"] {
            let id = UUID()
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else {
                return XCTFail("fixture")
            }
            let decoder = SuspendedRecoveryDecoder()
            let journal = NoteDraftJournal(directory: directory.appendingPathComponent(failure))
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
                decodeRecoveryDocument: { bytes in await decoder.decode(bytes) })
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            let session = try XCTUnwrap(controller.active)
            let (_, view) = session.engine.makeView()
            type("b", into: session)
            view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            await XCTAssertTrueAsync(await controller.preserveAllDurably())
            let original = try XCTUnwrap(journal.entries().first?.0)
            view.unmarkText()
            type("c", into: session)
            XCTAssertTrue(controller.save(session))
            await decoder.waitUntilStarted()
            let note = try XCTUnwrap(store.note(withID: id))
            switch failure {
            case "bytes": note.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Changed")]))
            case "revision": note.revisionID = UUID()
            case "tags": note.tagsRaw = AtticTag.encode(["changed"])
            default: break
            }
            await decoder.resume(fail: failure == "decode")
            await controller.waitForRecoveryWork()
            XCTAssertEqual(try journal.entries().first?.0, original, failure)
            XCTAssertTrue(session.notice?.contains("kept") == true, failure)
        }
    }

    // Historical fixed limits are replaced by three interleaved reference /
    // candidate runs in macos-ci.yml. Both sides use this exact fixture.
    private func assertSaveBaseline(_ sample: (save: Double, prepared: Double),
                                    label: String = "note-5000") {
        print("ATTIC_INTEGRATION_COST \(label)-save median_ms=\(sample.save)")
        print("ATTIC_INTEGRATION_COST \(label)-prepared median_ms=\(sample.prepared)")
    }

    func testMeasuredMainActorSaveIsIndependentOfUnrelatedStoreContents() async throws {
        let empty = try await makeSavePerformanceFixture()
        let emptyAttachment = try await makeSavePerformanceFixture(withAttachment: true)
        // Independent containers keep the empty fixture empty throughout pairing.
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                     attachmentFileStore: makeTestAttachmentFileStore())
        try await populatePerformanceStore()
        let populated = try await makeSavePerformanceFixture()
        let populatedAttachment = try await makeSavePerformanceFixture(withAttachment: true)
        let fixtures = [empty, populated, emptyAttachment, populatedAttachment]
        let labels = ["EMPTY", "POPULATED", "EMPTY_ATTACHMENT", "POPULATED_ATTACHMENT"]
        var saves = Array(repeating: [Double](), count: fixtures.count)
        var prepared = Array(repeating: [Double](), count: fixtures.count)
        // Discard a warm-up of every fixture before alternating each pair's
        // order. Neither runtime warm-up nor per-store warm-up can hide slope.
        for fixture in fixtures {
            _ = try await measureMainActorSave(fixture: fixture, samples: 1, report: false)
        }
        for pair in 0..<8 {
            for index in pair.isMultiple(of: 2) ? [0, 1, 2, 3] : [1, 0, 3, 2] {
                let sample = try await measureMainActorSave(fixture: fixtures[index], samples: 1, report: false)
                saves[index].append(sample.save)
                prepared[index].append(sample.prepared)
            }
        }
        let medians = fixtures.indices.map { (save: saves[$0].sorted()[4], prepared: prepared[$0].sorted()[4]) }
        for index in fixtures.indices {
            let sample = medians[index]
            print("NOTE_\(labels[index])_SAVE_MS_MEDIAN=\(sample.save) PREPARED_MS_MEDIAN=\(sample.prepared) SAVE_MAX=\(saves[index].max()!) PREPARED_MAX=\(prepared[index].max()!)")
            assertSaveBaseline(sample, label: "note-" + labels[index].lowercased())
            print("ATTIC_COST_SAMPLES metric=note-\(labels[index].lowercased())-save raw_ms=\(saves[index])")
            print("ATTIC_COST_SAMPLES metric=note-\(labels[index].lowercased())-prepared raw_ms=\(prepared[index])")
        }
        for (small, large, label) in [(0, 1, "TEXT"), (2, 3, "ATTACHMENT")] {
            let empty = medians[small], populated = medians[large]
            print("NOTE_STORE_SCALING_\(label)_SAVE_DIFFERENCE_MS=\(populated.save - empty.save) PREPARED_DIFFERENCE_MS=\(populated.prepared - empty.prepared)")
            print("ATTIC_INTEGRATION_COST scaling-\(label.lowercased())-prepared median_ms=\(populated.prepared - empty.prepared)")
            print("ATTIC_INTEGRATION_COST scaling-\(label.lowercased())-save median_ms=\(populated.save - empty.save)")
            let saveDifferences = zip(saves[large], saves[small]).map { $0 - $1 }
            let preparedDifferences = zip(prepared[large], prepared[small]).map { $0 - $1 }
            print("ATTIC_COST_SAMPLES metric=scaling-\(label.lowercased())-save raw_ms=\(saveDifferences)")
            print("ATTIC_COST_SAMPLES metric=scaling-\(label.lowercased())-prepared raw_ms=\(preparedDifferences)")
        }
    }

    func testMeasuredColdOpenAndLaunchWithFiveThousandLineNote() async throws {
        let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail("large note fixture")
        }
        let suite = "AtticNoteLaunchPerf.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var opens: [Double] = [], hydration: [Double] = [], launches: [Double] = [], initializations: [Double] = []
        func ms(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        for _ in 0..<8 {
            let controller = makeController()
            await controller.startAndWait()
            let openStart = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(controller.open(noteID: id))
            opens.append(ms(since: openStart))
            let hydrateStart = DispatchTime.now().uptimeNanoseconds
            let extractionCount = try XCTUnwrap(controller.active).engine.documentExtractionCount
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            hydration.append(ms(since: hydrateStart))
            XCTAssertEqual(controller.active?.engine.documentExtractionCount, extractionCount,
                           "Opening text-only notes must not serialize their entire body for byte hydration")
            defaults.set(id.uuidString, forKey: "notes.lastViewedNote.v2")
            let launchStart = DispatchTime.now().uptimeNanoseconds
            let launched = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                               defaults: defaults, saveDelay: .seconds(60))
            await launched.startAndWait()
            launches.append(ms(since: launchStart))
            XCTAssertEqual(launched.active?.noteID, id)
            let initStart = DispatchTime.now().uptimeNanoseconds
            let reopened = trackAttachmentReconciliation(of: NoteStore(container: store.container, attachmentFileStore: makeTestAttachmentFileStore()))
            initializations.append(ms(since: initStart))
            XCTAssertEqual(reopened.notes.count, 1)
            await reopened.waitForAttachmentReconciliation()
        }
        for (name, samples) in [("COLD_OPEN_5000_LINES", opens), ("OPEN_HYDRATION_5000_LINES", hydration),
                                 ("LAUNCH_LAST_NOTE_5000_LINES", launches), ("STORE_INIT", initializations)] {
            print("NOTE_\(name)_MS_MEDIAN=\(samples.sorted()[samples.count / 2]) MAX=\(samples.max()!)")
        }
    }

    private func populatePerformanceStore() async throws {
        let context = store.modelContext
        let document = NoteDocument(blocks: (0..<1_000).map { .text("Unrelated line \($0)") })
        let projection = try PreparedNoteDocument(document)
        let timestamp = Date()
        for index in 0..<200 {
            let note = NoteItem(title: "Unrelated \(index)", body: projection.body)
            note.content = projection.content
            note.contentFormat = 1
            note.plainText = projection.plainText
            note.revisionID = UUID()
            context.insert(note)
            context.insert(NoteVersion(noteID: note.id, createdAt: timestamp, reason: .leave,
                content: projection.content, contentFormat: 1, title: note.title, body: projection.body,
                attachmentIDs: [], sourceRevisionID: note.revisionID))
            if index < 20 {
                context.insert(NotePendingEdit(noteID: note.id, baseRevisionToken: note.revisionToken,
                    proposedContent: projection.content, agentName: "Perf fixture", createdAt: timestamp))
            }
            if index < 4 {
                let bytes = Data(repeating: UInt8(index), count: 1_024 * 1_024)
                context.insert(NoteAttachment(noteID: note.id, originalFilename: "fixture-\(index).bin",
                    byteCount: Int64(bytes.count), sortIndex: 0,
                    contentDigest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), payload: bytes))
            }
        }
        for index in 0..<2_000 {
            let task = TaskItem(title: "Done \(index)")
            task.status = .done
            task.completedAt = timestamp
            task.doneLoggedAt = timestamp
            context.insert(task)
        }
        try context.save()
        let started = DispatchTime.now().uptimeNanoseconds
        store = trackAttachmentReconciliation(of: NoteStore(container: store.container, persist: { [gate] in try gate!.save($0) },
                          attachmentFileStore: makeTestAttachmentFileStore()))
        print("NOTE_POPULATED_STORE_INIT_MS=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        await store.waitForAttachmentReconciliation()
    }

    private typealias SavePerformanceFixture = (controller: NotesPageController, session: NoteSession)

    private func makeSavePerformanceFixture(withAttachment: Bool = false) async throws -> SavePerformanceFixture {
        var document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
        let staged = withAttachment ? [try realImage()] : []
        if let image = staged.first {
            // Keep the same trailing text edit as the text-only baseline;
            // attachments exercise admission/visibility, not object editing.
            document.blocks.insert(.image(attachmentID: image.id, pixelWidth: 2, pixelHeight: 2), at: 2_500)
        }
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: document, staged: staged) else {
            XCTFail("large note fixture")
            throw NoteDocumentStoreError.invalidDocument("large note fixture")
        }
        let controller = makeController()
        let launchStart = DispatchTime.now().uptimeNanoseconds
        await controller.startAndWait()
        print("NOTE_CONTROLLER_START_MS=\(Double(DispatchTime.now().uptimeNanoseconds - launchStart) / 1_000_000)")
        let openStart = DispatchTime.now().uptimeNanoseconds
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        print("NOTE_OPEN_5000_LINES_MS=\(Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1_000_000)")
        return (controller, try XCTUnwrap(controller.active))
    }

    private func measureMainActorSave(label: String? = nil, fixture: SavePerformanceFixture? = nil,
                                      samples: Int = 8, report: Bool = true) async throws -> (save: Double, prepared: Double) {
        let target: SavePerformanceFixture
        if let fixture { target = fixture } else { target = try await makeSavePerformanceFixture() }
        let (controller, session) = target
        var milliseconds: [Double] = []
        var extractionMilliseconds: [Double] = []
        var preparedCommitMilliseconds: [Double] = []
        var combinedMilliseconds: [Double] = []
        for _ in 0..<samples {
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
            combinedMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - extractionStart) / 1_000_000)
        }
        await controller.waitForRecoveryWork()
        let sorted = milliseconds.sorted()
        let extractionSorted = extractionMilliseconds.sorted()
        let preparedSorted = preparedCommitMilliseconds.sorted()
        let combinedSorted = combinedMilliseconds.sorted()
        if report {
            print("ATTIC_COST_SAMPLES metric=note-5000-save raw_ms=\(milliseconds)")
            print("ATTIC_COST_SAMPLES metric=note-5000-prepared raw_ms=\(preparedCommitMilliseconds)")
            print("NOTE_SAVE_5000_LINES_MS_MEDIAN=\(sorted[sorted.count / 2])")
            print("NOTE_SAVE_5000_LINES_MS_MAX=\(sorted.last ?? 0)")
            print("NOTE_EXTRACT_5000_LINES_MS_MEDIAN=\(extractionSorted[extractionSorted.count / 2])")
            print("NOTE_EXTRACT_5000_LINES_MS_MAX=\(extractionSorted.last ?? 0)")
            print("NOTE_PREPARED_COMMIT_5000_LINES_MS_MEDIAN=\(preparedSorted[preparedSorted.count / 2])")
            print("NOTE_PREPARED_COMMIT_5000_LINES_MS_MAX=\(preparedSorted.last ?? 0)")
            print("NOTE_EXTRACT_PREPARE_COMMIT_5000_LINES_MS_MEDIAN=\(combinedSorted[combinedSorted.count / 2])")
            print("NOTE_EXTRACT_PREPARE_COMMIT_5000_LINES_MS_MAX=\(combinedSorted.last ?? 0)")
        }
        XCTAssertTrue(controller.store.versions(noteID: session.noteID).isEmpty)
        let result = (save: sorted[sorted.count / 2], prepared: preparedSorted[preparedSorted.count / 2])
        if let label {
            print("NOTE_\(label)_SAVE_MS_MEDIAN=\(result.save) PREPARED_MS_MEDIAN=\(result.prepared)")
        }
        return result
    }

    func testFailedSaveIsCheckpointedBeforeNavigationAndRetrySavesIt() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let first = try XCTUnwrap(controller.active)
        type("Draft one", into: first)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.newNoteDurably(), "a checkpoint lets navigation go on")
        guard case .notSaved = first.state else { return XCTFail("slot says Not saved") }
        XCTAssertTrue(store.notes.isEmpty)
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
        XCTAssertTrue(controller.failedDrafts.contains { $0 === first })
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(controller.openFailedDraft(sessionID: first.id))
        XCTAssertTrue(controller.active === first)

        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.preserveDurably(first), "Retry")
        XCTAssertFalse(NoteSessionPolicy.needsAttention(first.state))
        XCTAssertEqual(store.notes.map(\.title), ["Draft one"])
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty, "the checkpoint goes once saved")
    }

    func testWhenStoreAndCheckpointBothFailTheDraftStaysAndNavigationIsRefused() async throws {
        let journal = FailingJournal()
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Precious", into: session)
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.newNoteDurably())
        XCTAssertTrue(controller.active === session, "the session is never replaced")
        guard case .onlyInMemory = session.state else { return XCTFail("slot says Only in memory") }
        await XCTAssertFalseAsync(await controller.preserveAllDurably(), "hide and quit are refused")
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.hide))
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.quit))
        XCTAssertFalse(NoteSessionPolicy.canEvict(session.state, activity: session.engine.activity,
            hasBatch: session.isImporting, presence: .background))
        XCTAssertTrue(session.engine.plainText.contains("Precious"))
        gate.shouldFail = false
        controller.retry()
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        await XCTAssertTrueAsync(await controller.newNoteDurably())
    }

    func testRealShellPageSwitchRefusesToLeaveAnUnrecoverableNativeDraft() async throws {
        let suite = "AtticNotesNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let taskStore = TaskStore(container: container)
        let noteStore = trackAttachmentReconciliation(of: NoteStore(container: container, persist: { [gate] in try gate!.save($0) },
                                  attachmentFileStore: makeTestAttachmentFileStore()))
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
        await noteDraft.pages.startAndWait()
        let draft = try XCTUnwrap(noteDraft.pages.active)
        type("Only in memory", into: draft)
        gate.shouldFail = true
        view.selectSection(.tasks)
        XCTAssertEqual(state.selectedSection, .notes)
        XCTAssertTrue(noteDraft.pages.active === draft)
        guard case .onlyInMemory = draft.state else { return XCTFail("both saves failed") }
        XCTAssertEqual(draft.engine.document().title, "Only in memory")
    }

    func testNavigationRefusesAnActiveNativeComposition() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        let (_, textView) = session.engine.makeView()
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        await XCTAssertTrueAsync(await controller.preserveAllDurably(), "a flush checkpoints without ending composition")
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.pageSwitch))
        XCTAssertNotNil(session.notice)
        textView.unmarkText()
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.pageSwitch))
    }

    func testCancelledNativeCompositionSelfHealsOnLeaveHideAndQuit() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        for reason in [NotesPageController.LeaveReason.pageSwitch, .hide, .quit] {
            textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(textView.hasMarkedText())
            // The no-window test view needs its delegate notification for the begin.
            session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertEqual(session.engine.activity, .composing)
            // Simulate an IME cancelling the marked text without delivering a
            // final delegate text-change notification.
            textView.delegate = nil
            textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.unmarkText()
            textView.delegate = session.engine
            XCTAssertFalse(textView.hasMarkedText())
            XCTAssertEqual(session.engine.textStorage.string, "Before")
            XCTAssertEqual(session.engine.activity, .composing,
                "ending marked text did not send a text-change callback")
            await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(reason))
            XCTAssertEqual(session.engine.activity, .idle)
            XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
            controller.present()
        }
    }

    func testRecoveredDraftOpensFirstAndIsSaved() async throws {
        let existing = makeController()
        await existing.startAndWait()
        let session = try XCTUnwrap(existing.active)
        type("Saved text", into: session)
        await XCTAssertTrueAsync(await existing.preserveAllDurably())
        let noteID = session.noteID
        type(" and more", into: session)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await existing.preserveAllDurably())   // checkpointed
        gate.shouldFail = false

        // Relaunch.
        let relaunched = makeController()
        await relaunched.startAndWait()
        let recovered = try XCTUnwrap(relaunched.active)
        XCTAssertEqual(recovered.noteID, noteID)
        XCTAssertEqual(recovered.notice, "Restored unsaved text.")
        XCTAssertFalse(NoteSessionPolicy.needsAttention(recovered.state))
        XCTAssertEqual(store.note(withID: noteID)?.title, "Saved text and more")
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testLeavingANoteKeepsAVersionAndAppliesAWaitingAgentEdit() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Plan", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        XCTAssertEqual(store.agentWriteDisposition(id), .proposal)
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                         document: NoteDocument(blocks: [.text("Agent plan")]),
                                                         agentName: "Claude", disposition: store.agentWriteDisposition(id)) else {
            return XCTFail()
        }
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plan")
        XCTAssertTrue(store.versions(noteID: id).contains { $0.title == "Plan" },
                      "the state before the pending edit is retained")
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertEqual(controller.active?.engine.document().title, "Agent plan", "the reopened note shows the applied edit")
    }

    func testAgentWriteWhileHiddenFlushesDirtyDraftAndRejectsStaleToken() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        type(" draft", into: session)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        gate.shouldFail = false
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        XCTAssertEqual(store.agentWriteDisposition(id), .direct)
        guard case .failure(.staleRevision) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Mine draft")
        controller.present()
        type(" and mine", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: id)?.title, "Mine draft and mine")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        XCTAssertEqual(controller.active?.engine.document().title, "Mine draft and mine")
    }

    func testPendingAgentEditAppliedOnLeaveReloadsTheRetainedSession() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        XCTAssertTrue(controller.showLibrary())
        controller.dismissLibrary()
        XCTAssertEqual(controller.active?.engine.document().title, "Agent")
        let reloaded = try XCTUnwrap(controller.active)
        type(" plus mine", into: reloaded)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plus mine")
    }

    func testRefusedHideKeepsOnScreenProposalAndCurrentBase() async throws {
        let controller = makeController(journal: FailingJournal())
        await controller.startAndWait()
        let onScreen = try XCTUnwrap(controller.active)
        type("On screen", into: onScreen)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = onScreen.noteID
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        let background = try XCTUnwrap(controller.active)
        type("Background", into: background)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail("proposal fixture") }
        gate.shouldFail = true
        type(" unsaved", into: background)
        await XCTAssertFalseAsync(await controller.preserveDurably(background))
        guard case .onlyInMemory = background.state else { return XCTFail("background must be in memory") }
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.hide))
        XCTAssertTrue(controller.active === onScreen)
        XCTAssertEqual(store.note(withID: id)?.title, "On screen")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
        XCTAssertEqual(store.agentWriteDisposition(id), .proposal)
        gate.shouldFail = false
        type(" typed", into: onScreen)
        await XCTAssertTrueAsync(await controller.preserveDurably(onScreen))
        XCTAssertEqual(onScreen.state, .clean)
        XCTAssertEqual(store.note(withID: id)?.title, "On screen typed")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testAgentWriteInLibraryCannotStaleSaveOnReopen() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        XCTAssertTrue(controller.showLibrary())
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        controller.dismissLibrary()
        XCTAssertEqual(controller.active?.engine.document().title, "Agent")
        type(" and mine", into: try XCTUnwrap(controller.active))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent and mine")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
    }

    func testTwoAgentWritesToHiddenCleanNoteApplyAndReloadOnReturn() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Original", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        XCTAssertFalse(store.agentWriteDisposition(id) == .proposal)
        for line in ["First", "Second"] {
            let token = try XCTUnwrap(store.note(withID: id)).revisionToken
            var document = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
            document.blocks.append(.text(line))
            guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: document, agentName: "Claude",
                disposition: store.agentWriteDisposition(id)) else { return XCTFail(line) }
        }
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        controller.present()
        XCTAssertEqual(controller.active?.engine.document().blocks.map(\.text), ["Original", "First", "Second"])
        type(" plus mine", into: try XCTUnwrap(controller.active))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks.map(\.text),
                       ["Original", "First", "Second plus mine"])
    }

    func testCleanCachedBackgroundNoteTakesAgentWriteDirectly() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let first = try XCTUnwrap(controller.active)
        type("First", into: first)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = first.noteID
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        type("Second", into: try XCTUnwrap(controller.active))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertFalse(store.agentWriteDisposition(id) == .proposal)
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent first")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertEqual(controller.active?.engine.document().title, "Agent first")
    }

    func testVisibleDirtyNoteProposesAgentEditAndKeepsTyping() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Original", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        type(" draft", into: session)
        let token = try XCTUnwrap(store.note(withID: session.noteID)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: session.noteID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(session.noteID)) else { return XCTFail() }
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "Original draft")
        XCTAssertEqual(controller.proposalAgent(for: session), "Claude")
    }

    func testRecoveryRunsBeforeAgentWriteAndMakesOldTokenStale() async throws {
        guard case let .success((id, base)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Stored")])) else { return XCTFail() }
        let journal = NoteDraftJournal(directory: directory)
        let entry = NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: base,
            content: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Recovery")])),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        try await journal.writeDurably(entry, staged: [])
        let controller = makeController(journal: journal)
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        await controller.recoverAtLaunchAndWait()
        XCTAssertEqual(store.agentWriteDisposition(id), .direct)
        guard case .failure(.staleRevision) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        await controller.startAndWait()
        XCTAssertEqual(store.note(withID: id)?.title, "Recovery")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
    }

    func testRecoveredStaleDraftShowsConflictAndKeepAsNewPreservesBothNotes() async throws {
        guard case let .success((id, base)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Stored")])) else { return XCTFail() }
        let journal = NoteDraftJournal(directory: directory)
        try await journal.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: base,
            content: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Person")])) ,
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude", disposition: .direct) else {
            return XCTFail()
        }
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertEqual(session.state, .conflict(.changed))
        XCTAssertEqual(controller.statusItems(for: session).first, .changedElsewhere)
        XCTAssertEqual(controller.conflictComparison(for: session)?.current, "Agent")
        XCTAssertEqual(controller.conflictComparison(for: session)?.proposed, "Person")
        let saves = gate.saveCount
        controller.retry()
        XCTAssertEqual(gate.saveCount, saves, "a stale retry must not attempt the same impossible save")
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(session.noteID, id)
        XCTAssertEqual(store.note(withID: id)?.title, "Agent")
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "Person")
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        XCTAssertTrue(try journal.entries().isEmpty)
    }

    func testConflictWithPendingImportRefusesKeepUntilPayloadCompletes() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let oldID = draft.noteID
        type(" local", into: draft)
        let token = try XCTUnwrap(store.note(withID: oldID)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: oldID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Agent", disposition: .direct) else {
            return XCTFail()
        }
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(draft.state, .conflict(.changed))
        controller.importImages([URL(fileURLWithPath: "/tmp/pending.png")])
        await waitForImageRequests(loader, count: 1)
        await XCTAssertFalseAsync(await controller.keepAsNewNoteDurably())
        XCTAssertEqual(draft.noteID, oldID)
        XCTAssertEqual(store.note(withID: oldID)?.title, "Agent")
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
        XCTAssertTrue(try store.attachmentRows(forNoteID: oldID).isEmpty)
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if !draft.isImporting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(draft.isImporting)
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(draft.noteID, oldID)
        XCTAssertEqual(store.note(withID: oldID)?.title, "Agent")
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Original local")
        let rows = try store.attachmentRows(forNoteID: draft.noteID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.payload, image.data)
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testConflictWithBlockedWritingToolsRefusesKeepAndNeverCopiesBypass() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let oldID = draft.noteID
        type(" local", into: draft)
        let token = try XCTUnwrap(store.note(withID: oldID)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: oldID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Agent", disposition: .direct) else {
            return XCTFail()
        }
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        draft.engine.writingToolsWillBegin()
        draft.engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 8), with: "Unapproved")
        await XCTAssertFalseAsync(await controller.keepAsNewNoteDurably())
        let recovery = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
        XCTAssertEqual(NoteContentCodec.decode(recovery.content).document?.title, "Original local")
        draft.engine.writingToolsDidEnd()
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(draft.noteID, oldID)
        XCTAssertEqual(store.note(withID: oldID)?.title, "Agent")
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Original local")
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testConflictKeepRejectsMarkedTextAndInvalidImagePayload() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let oldID = draft.noteID
        type(" local", into: draft)
        let token = try XCTUnwrap(store.note(withID: oldID)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: oldID, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Agent", disposition: .direct) else {
            return XCTFail()
        }
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = draft.engine.makeView()
        textView.setSelectedRange(NSRange(location: draft.engine.textStorage.length, length: 0))
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        await XCTAssertFalseAsync(await controller.keepAsNewNoteDurably())
        textView.unmarkText()
        let empty = Data()
        let image = StagedNoteAttachment(id: UUID(), filename: "invalid.png", contentTypeIdentifier: "public.png",
            byteCount: 0, digest: SHA256.hash(data: empty).map { String(format: "%02x", $0) }.joined(), data: empty)
        XCTAssertFalse(draft.engine.insertImage(image, pixelSize: nil), "new invalid payloads are rejected before insertion")
        // Reproduce an already damaged recovered object to exercise the
        // independent Keep-as-new save guard as well as the insertion guard.
        let admission = draft.engine.onFragmentAdmission
        draft.engine.onFragmentAdmission = nil
        XCTAssertTrue(draft.engine.insertImage(image, pixelSize: nil))
        draft.engine.onFragmentAdmission = admission
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        await XCTAssertFalseAsync(await controller.keepAsNewNoteDurably())
        XCTAssertEqual(draft.noteID, oldID)
        XCTAssertEqual(store.note(withID: oldID)?.title, "Agent")
        XCTAssertTrue(try store.attachmentRows(forNoteID: oldID).isEmpty)
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
    }

    func testEqualCheckpointDropsBeforeDirectAgentWrite() async throws {
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container1 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let firstStore = trackAttachmentReconciliation(of: NoteStore(container: container1, attachmentFileStore: makeTestAttachmentFileStore()))
        let document = NoteDocument(blocks: [.text("Committed")])
        guard case let .success((id, _)) = firstStore.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail()
        }
        let journal = NoteDraftJournal(directory: journalDirectory)
        try await journal.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: false, baseRevisionID: nil,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [], savedAt: Date()), staged: [])
        let container2 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let secondStore = trackAttachmentReconciliation(of: NoteStore(container: container2, attachmentFileStore: makeTestAttachmentFileStore()))
        let controller = NotesPageController(store: secondStore, journal: journal)
        await controller.recoverAtLaunchAndWait()
        XCTAssertEqual(secondStore.agentWriteDisposition(id), .direct)
        let token = try XCTUnwrap(secondStore.note(withID: id)).revisionToken
        guard case .success(.applied) = secondStore.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Agent",
            disposition: secondStore.agentWriteDisposition(id)) else { return XCTFail() }
        await controller.startAndWait()
        XCTAssertEqual(secondStore.note(withID: id)?.title, "Agent")
        XCTAssertTrue(secondStore.pendingEdits(noteID: id).isEmpty)
        XCTAssertTrue(try journal.entries().isEmpty)
        XCTAssertFalse(controller.active.map { NoteSessionPolicy.needsAttention($0.state) } ?? true)
    }

    func testRecoveredFirstSaveCheckpointConflictsWithAlreadyCommittedAgentWrite() async throws {
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container1 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let firstStore = trackAttachmentReconciliation(of: NoteStore(container: container1, attachmentFileStore: makeTestAttachmentFileStore()))
        guard case let .success((id, _)) = firstStore.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Committed")])) else { return XCTFail() }
        let journal = NoteDraftJournal(directory: directory.appendingPathComponent("journal"))
        try await journal.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: false, baseRevisionID: nil,
            content: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Person")])),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        let container2 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let secondStore = trackAttachmentReconciliation(of: NoteStore(container: container2, attachmentFileStore: makeTestAttachmentFileStore()))
        let token = try XCTUnwrap(secondStore.note(withID: id)).revisionToken
        guard case .success(.applied) = secondStore.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Agent", disposition: .direct) else {
            return XCTFail()
        }
        let controller = NotesPageController(store: secondStore, journal: journal)
        await controller.startAndWait()
        XCTAssertEqual(secondStore.note(withID: id)?.title, "Agent")
        XCTAssertEqual(controller.active?.state, .conflict(.changed))
        XCTAssertEqual(controller.active?.engine.document().title, "Person")
        XCTAssertEqual(try journal.entries().count, 1)
    }

    func testSuccessfulSaveClearsLeftoverRecoveryCopyOnRelaunch() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Saved", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        let previous = try XCTUnwrap(store.note(withID: id)?.revisionID)
        type(" again", into: session)
        let document = session.engine.document()
        try await journal.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: previous,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [], savedAt: Date()), staged: [])
        XCTAssertTrue(controller.save(session))
        await controller.waitForRecoveryWork()
        // Simulate a remove failure by putting the old checkpoint back.
        try await journal.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: previous,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [], savedAt: Date()), staged: [])
        let relaunched = makeController(journal: journal)
        await relaunched.startAndWait()
        XCTAssertFalse(relaunched.active.map { NoteSessionPolicy.needsAttention($0.state) } ?? true)
        XCTAssertEqual(store.note(withID: id)?.title, "Saved again")
        XCTAssertTrue(try journal.entries().isEmpty)
    }

    func testFailedJournalRemovalIsReplacedByARetiredMarker() async throws {
        let journal = RemoveFailingJournal(directory: directory)
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Person", into: session)
        // A copy the session never claimed, which the save makes redundant.
        try await journal.base.writeDurably(NoteDraftJournalEntry(noteID: session.noteID, isPersisted: false,
            baseRevisionID: nil, content: try NoteContentCodec.encode(session.engine.document()),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        journal.failNextRemove = true
        XCTAssertTrue(controller.save(session))
        await controller.waitForRecoveryWork()
        let file = directory.appendingPathComponent("\(session.noteID.uuidString).json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["retired"] as? Bool, true, "an unremovable copy becomes a retired marker")
        XCTAssertTrue(try journal.entries().isEmpty)
        let relaunched = makeController(journal: NoteDraftJournal(directory: directory))
        await relaunched.startAndWait()
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "Person")
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyRetiredMarkerIsIgnoredWithoutReplayingBlankText() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let id = UUID()
        let entry = NoteDraftJournalEntry(noteID: id, isPersisted: false, baseRevisionID: nil,
            content: try NoteContentCodec.encode(.blank), selectionLocation: 0,
            selectionLength: 0, staged: [], savedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any])
        object["retired"] = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        await XCTAssertTrueAsync(try await journal.readRecoveryEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testProposalStatusOnLongNoteDoesNotFetchOrExtractOnTyping() async throws {
        let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0)") })
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail()
        }
        let controller = makeController()
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: NoteDocument(blocks: [.text("Proposal")]), agentName: "Claude",
            disposition: store.agentWriteDisposition(id)) else { return XCTFail() }
        XCTAssertEqual(controller.statusItems(for: session).first, .proposal("Claude"))
        let fetches = store.pendingEditFetchCount
        let extractions = session.engine.documentExtractionCount
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {
            type("x", into: session)
            XCTAssertEqual(controller.statusItems(for: session).first, .proposal("Claude"))
        }
        print("NOTE_5000_PROPOSAL_100_KEYS_MS=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
        XCTAssertEqual(store.pendingEditFetchCount, fetches)
        XCTAssertEqual(session.engine.documentExtractionCount, extractions)
        guard case let .success((baselineID, _)) = store.createDocumentNote(id: UUID(), document: document) else {
            return XCTFail("baseline fixture")
        }
        let baseline = makeController()
        await baseline.startAndWait()
        await XCTAssertTrueAsync(await baseline.openDurably(noteID: baselineID))
        let baselineSession = try XCTUnwrap(baseline.active)
        XCTAssertTrue(baseline.statusItems(for: baselineSession).isEmpty)
        let baselineFetches = store.pendingEditFetchCount
        let baselineExtractions = baselineSession.engine.documentExtractionCount
        let baselineStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 {
            type("x", into: baselineSession)
            XCTAssertTrue(baseline.statusItems(for: baselineSession).isEmpty)
        }
        print("NOTE_5000_NO_PROPOSAL_100_KEYS_MS=\(Double(DispatchTime.now().uptimeNanoseconds - baselineStart) / 1_000_000)")
        XCTAssertEqual(store.pendingEditFetchCount, baselineFetches)
        XCTAssertEqual(baselineSession.engine.documentExtractionCount, baselineExtractions)
        session.notice = "Finish composing text before leaving this note."
        XCTAssertEqual(controller.statusItems(for: session).map(\.label),
                       ["Claude has changes", "Finish composing text before leaving this note."])
    }

    func testStagedImageIsCommittedWithTheSaveThatShowsIt() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Pics", into: session)
        let bytes = Data([1, 2, 3])
        let item = StagedNoteAttachment(id: UUID(), filename: "a.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(bytes.count),
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), data: bytes)
        session.engine.insertImage(item, pixelSize: CGSize(width: 10, height: 10))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(try store.attachmentRows(forNoteID: session.noteID).map(\.id), [item.id])
        XCTAssertTrue(session.engine.staged.isEmpty)
    }

    func testSavedImageDecodesAfterDiscardingSessionAndReopening() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Image", into: session)
        let image = try realImage()
        session.engine.insertImage(image, pixelSize: CGSize(width: 1, height: 1))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID

        let reopened = makeController()
        await XCTAssertTrueAsync(await reopened.openDurably(noteID: id))
        let reopenedEngine = try XCTUnwrap(reopened.active?.engine)
        for _ in 0..<30 {
            if reopenedEngine.objects().compactMap({ $0.0 as? NoteImageAttachment }).first?.renderedImage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let loaded = try XCTUnwrap(reopenedEngine.objects().compactMap({ $0.0 as? NoteImageAttachment }).first)
        XCTAssertFalse(loaded.isMissing)
        XCTAssertNotNil(loaded.renderedImage)
    }

    func testCrossNotePasteCopiesImageFromFailedSourceDraft() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let source = try XCTUnwrap(controller.active)
        type("Source", into: source)
        let image = try realImage()
        source.engine.insertImage(image, pixelSize: CGSize(width: 2, height: 2))
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveAllDurably(), "the failed source stays in recovery")
        let savesBeforeCopy = gate.saveCount
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-failed-source-\(UUID().uuidString)"))
        XCTAssertTrue(source.engine.writeSelection(NSRange(location: 0, length: source.engine.textStorage.length),
                                                   to: pasteboard, types: [NoteEditorEngine.fragmentType]))
        XCTAssertEqual(gate.saveCount, savesBeforeCopy, "copy does not save the source")
        let fragment = try XCTUnwrap(pasteboard.data(forType: NoteEditorEngine.fragmentType))
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        let destination = try XCTUnwrap(controller.active)
        XCTAssertTrue(destination.engine.paste(fragmentData: fragment, at: NSRange(location: 0, length: 0)))
        let newImageID = try XCTUnwrap(destination.engine.document().attachmentIDs.first)
        XCTAssertNotEqual(newImageID, image.id)
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(try store.attachmentRows(forNoteID: destination.noteID).first?.id, newImageID)
    }

    func testDelayedImageBatchLoadsFirstAndCommitsTogether() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .milliseconds(10),
                                             imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Start", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        controller.importImages([URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")])
        XCTAssertTrue(draft.engine.document().attachmentIDs.isEmpty, "loading never edits the document")
        type(" while loading", into: draft)
        await waitForImageRequests(loader, count: 1)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertFalse(NoteSessionPolicy.needsAttention(draft.state))
        await loader.releaseNext(success: true)
        await waitForImageRequests(loader, count: 2)
        XCTAssertTrue(try store.attachmentRows(forNoteID: draft.noteID).isEmpty)
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if (try? store.attachmentRows(forNoteID: draft.noteID).count) == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stored = try XCTUnwrap(store.loadDocument(noteID: draft.noteID)?.content.document)
        XCTAssertEqual(stored.attachmentIDs.count, 2)
        XCTAssertEqual(stored.title, "Start while loading")
        XCTAssertEqual(try store.attachmentRows(forNoteID: draft.noteID).count, 2)
        XCTAssertTrue(draft.engine.history.undo(), "both images are one Undo step")
        XCTAssertTrue(draft.engine.document().attachmentIDs.isEmpty)
    }

    func testImageBatchNavigationKeepsBackgroundBatchAndTypedText() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/delayed.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        XCTAssertTrue(draft.isImporting)
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if (try? store.attachmentRows(forNoteID: id).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try store.attachmentRows(forNoteID: id).count, 1)
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.title, "Before after")
        XCTAssertFalse(draft.isImporting)
    }


    func testStatusCancelBatchKeepsTypedTextAndIgnoresLateImage() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        controller.importImages([URL(fileURLWithPath: "/tmp/cancel.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(controller.statusItems(for: draft).contains(.importing))
        controller.cancelActiveImport()
        await controller.waitForRecoveryWork()
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertFalse(controller.statusItems(for: draft).contains(.importing))
        XCTAssertTrue(draft.notice?.contains("cancelled") == true)
        await loader.releaseNext(success: true)
        XCTAssertEqual(store.loadDocument(noteID: draft.noteID)?.content.document?.attachmentIDs, [])
        XCTAssertTrue(store.loadDocument(noteID: draft.noteID)?.content.document?.blocks
            .contains(where: { $0.text.contains("after") }) == true)
    }

    func testHiddenImportContinuesAndCommitsToItsOriginalNote() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/hidden.png")])
        await waitForImageRequests(loader, count: 1)
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        XCTAssertFalse(NoteSessionPolicy.needsAttention(draft.state))
        await loader.releaseNext(success: true)
        for _ in 0..<60 {
            if (try? store.attachmentRows(forNoteID: id).count) == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.present()
        XCTAssertEqual(try store.attachmentRows(forNoteID: id).count, 1)
        XCTAssertEqual(controller.active?.engine.document().attachmentIDs.count, 1)
    }


    func testImageBatchDeletedDestinationStaysInRecoveryWithoutResurrection() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Before", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = draft.noteID
        controller.importImages([URL(fileURLWithPath: "/tmp/delayed.png")])
        type(" after", into: draft)
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        await loader.releaseNext(success: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(draft.noteID, id)
        XCTAssertEqual(draft.state, .conflict(.deleted))
        XCTAssertTrue(controller.failedDrafts.contains { $0 === draft })
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
    }

    func testLateImageImportOnCleanDeletedNoteDoesNotCreateRecoveryConflict() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Saved", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        controller.importImages([URL(fileURLWithPath: "/tmp/late.png")])
        await waitForImageRequests(loader, count: 1)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: session.noteID))))
        await loader.releaseNext(success: true)
        await controller.waitForImportWork()
        XCTAssertFalse(session.isImporting)
        XCTAssertEqual(session.state, .clean)
        XCTAssertFalse(controller.failedDrafts.contains { $0 === session })
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testImageBatchFailureKeepsSuccessfulObjectAndShowsFailureCard() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60),
                                             imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Text", into: draft)
        controller.importImages([URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")])
        await waitForImageRequests(loader, count: 1)
        await loader.releaseNext(success: true)
        await waitForImageRequests(loader, count: 2)
        await loader.releaseNext(success: false)
        await controller.waitForImportWork()
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let document = draft.engine.document()
        XCTAssertEqual(document.attachmentIDs.count, 1)
        XCTAssertEqual(document.blocks.filter { $0.kind == .file && $0.importFailure != nil }.count, 1)
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Text")
        XCTAssertEqual(try store.attachmentRows(forNoteID: draft.noteID).count, 1)
    }

    func testImportCompletionWaitsForWritingToolsToEnd() async throws {
        let image = try realImage()
        let loader = DelayedImageLoader()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), imageLoader: { url in await loader.load(url, template: image) })
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Title", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        controller.importImages([URL(fileURLWithPath: "/tmp/deferred.png")])
        await waitForImageRequests(loader, count: 1)
        draft.engine.writingToolsWillBegin()
        XCTAssertEqual(draft.engine.activity, .writingToolsSafe)
        await loader.releaseNext(success: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(draft.isImporting)
        XCTAssertTrue(draft.engine.document().attachmentIDs.isEmpty)
        XCTAssertTrue(try store.attachmentRows(forNoteID: draft.noteID).isEmpty)
        draft.engine.writingToolsDidEnd()
        XCTAssertFalse(draft.isImporting)
        XCTAssertEqual(try store.attachmentRows(forNoteID: draft.noteID).count, 1)
    }

    func testWritingToolsRefusesRewriteWhenVersionCannotCommit() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original prose", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        XCTAssertFalse(draft.engine.allowsChange(ranges: [NSRange(location: 0, length: 1)]))
        XCTAssertTrue(draft.notice?.contains("safety copy") == true)
        draft.engine.writingToolsDidEnd()
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Original prose")
    }

    func testRefusedWritingToolsSessionFreezesCommandsAndCheckpointsSnapshot() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        gate.shouldFail = false
        XCTAssertEqual(draft.engine.activity, .writingToolsRefused)
        let before = draft.engine.document()
        draft.engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertEqual(draft.engine.document(), before)
        draft.engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 8), with: "Rewrite")
        await XCTAssertTrueAsync(await controller.preserveDurably(draft))
        let entry = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
        XCTAssertEqual(NoteContentCodec.decode(entry.content).document, before)
        draft.engine.writingToolsDidEnd()
        XCTAssertEqual(draft.engine.document(), before)
        XCTAssertFalse(NoteSessionPolicy.needsAttention(draft.state))
    }

    func testImportStartIsRefusedDuringWritingTools() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Title", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        gate.shouldFail = false
        controller.importImages([URL(fileURLWithPath: "/tmp/blocked.png")])
        XCTAssertFalse(draft.isImporting)
        XCTAssertTrue(draft.engine.document().attachmentIDs.isEmpty)
        draft.engine.writingToolsDidEnd()
        XCTAssertTrue(draft.engine.document().attachmentIDs.isEmpty)
    }

    func testRefusedWritingToolsBypassRestoresTextAndDoesNotAutosave() async throws {
        let controller = makeController(delay: .milliseconds(20))
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original prose", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
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

    func testBlockedWritingToolsCheckpointsButCannotCommitFromCopyOrExplicitSave() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original\nBody", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let revision = store.note(withID: draft.noteID)?.revisionID
        gate.shouldFail = true
        draft.engine.writingToolsWillBegin()
        gate.shouldFail = false
        draft.engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 8), with: "Unapproved")
        draft.engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertFalse(controller.save(draft))
        await XCTAssertTrueAsync(await controller.preserveDurably(draft))
        XCTAssertTrue(draft.engine.writeSelection(NSRange(location: 0, length: 8),
                                                    to: NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)),
                                                    types: [.string]))
        XCTAssertEqual(store.note(withID: draft.noteID)?.revisionID, revision)
        XCTAssertFalse(NoteSessionPolicy.needsAttention(draft.state))
        let recovery = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
        XCTAssertEqual(NoteContentCodec.decode(recovery.content).document?.title, "Original")
        XCTAssertEqual(NoteContentCodec.decode(recovery.content).document?.blocks.flatMap(\.inlines).count, 0)
        draft.engine.writingToolsDidEnd()
        XCTAssertTrue(controller.save(draft))
        await controller.waitForRecoveryWork()
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testUnreadableDocumentOpensAnExplanatoryReadOnlySession() async throws {
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Before")])) else { return XCTFail() }
        for row in try store.modelContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
            row.content = Data("broken bytes".utf8)
        }
        try store.modelContext.save()
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertTrue(controller.active?.isReadOnly == true)
        guard case .unreadable = controller.active?.readOnlyReason else {
            return XCTFail("the status slot must explain the unreadable document")
        }
        XCTAssertEqual(controller.active?.engine.document().title, "")
    }

    func testSuccessfulSessionRestoresSelectionAndScrollState() async throws {
        let suite = "AtticNoteViewState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             defaults: defaults, saveDelay: .seconds(60))
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Title\n" + String(repeating: "A long line of text\n", count: 100), into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = draft.noteID
        let (scroll, _) = draft.engine.makeView()
        draft.engine.onSelectionChange?(NSRange(location: 5, length: 3))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 120))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())

        let reopened = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                           defaults: defaults)
        await XCTAssertTrueAsync(await reopened.openDurably(noteID: id))
        XCTAssertEqual(reopened.active?.selection, NSRange(location: 5, length: 3))
        XCTAssertEqual(reopened.active?.scrollOffset ?? -1, 120, accuracy: 0.5)
    }

    func testStartPrunesOnlyObsoletePerNoteViewState() async throws {
        let suite = "AtticNoteViewState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        let stale = "notes.viewState.\(UUID().uuidString)"
        let current = "notes.viewState.\(id.uuidString)"
        defaults.set(["location": 2], forKey: stale)
        defaults.set(["location": 1], forKey: current)
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             defaults: defaults)
        await controller.startAndWait()
        XCTAssertNil(defaults.object(forKey: stale))
        XCTAssertNotNil(defaults.object(forKey: current))
    }

    private func waitForImageRequests(_ loader: DelayedImageLoader, count: Int) async {
        for _ in 0..<100 {
            if await loader.started >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("image loader did not start \(count) requests")
    }

    func testRecoveryReadsValidEntriesBesideCorruptAndMissingImageEntries() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let bytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Valid")]))
        let valid = NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil, content: bytes,
                                          selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        try await journal.writeDurably(valid, staged: [])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        let image = try realImage()
        let incomplete = NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil, content: bytes,
                                               selectionLocation: 0, selectionLength: 0,
                                               staged: [.init(id: image.id, filename: image.filename,
                                                              contentTypeIdentifier: image.contentTypeIdentifier,
                                                              byteCount: image.byteCount, digest: image.digest)], savedAt: Date())
        try await journal.writeDurably(incomplete, staged: [image])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("staged/\(image.id.uuidString)"))
        let results = try await journal.readRecoveryEntries()
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.filter { if case .valid = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(results.filter { if case .damaged = $0 { return true }; return false }.count, 2)
        let controller = makeController()
        await controller.startAndWait()
        XCTAssertEqual(controller.active?.engine.document().title, "Valid")
        XCTAssertEqual(controller.recoveryWarnings.count, 2)
    }

    func testDamagedRecoveryIsVisibleWhenLastViewedNoteOpens() async throws {
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
        await controller.startAndWait()
        XCTAssertEqual(controller.active?.noteID, created.noteID)
        XCTAssertEqual(controller.recoveryWarnings.count, 1)
        XCTAssertNotNil(controller.active?.notice)
    }

    func testDamagedRecoveryBlockingPurgeShowsAWarning() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Saved", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let row = NoteAttachment(noteID: draft.noteID, originalFilename: "old.bin", byteCount: 1,
                                 sortIndex: 0, contentDigest: String(repeating: "a", count: 64), payload: Data([1]))
        store.modelContext.insert(row)
        try store.modelContext.save()
        XCTAssertTrue(store.removeAttachment(row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
        _ = try await controller.journal?.readRecoveryEntries()
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0)
        XCTAssertTrue(controller.recoveryWarnings.contains { $0.contains("keeping removed images") })
        XCTAssertTrue(draft.notice?.contains("keeping removed images") == true)
    }

    func testBothAttachmentPurgeRoutesRespectRecoveryReferences() async throws {
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        // This fixture tests journal-only ownership. Finish startup before
        // writing its checkpoint, so it cannot also open a live recovery session.
        await controller.recoverAtLaunchAndWait()
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
        let claim = try await journal.writeDurably(entry, staged: [])
        XCTAssertEqual(store.purgeRemovedAttachments(before: Date()), 0)
        try await journal.discardOwnedDurably(noteID: draftID, claim: claim)
        XCTAssertEqual(store.purgeRemovedAttachments(before: Date()), 1)

        let secondImage = try realImage()
        guard case let .success((id, _)) = store.createDocumentNote(
            id: UUID(), document: NoteDocument(blocks: [.text("Deleted"), .image(attachmentID: secondImage.id)]),
            staged: [secondImage]) else { return XCTFail() }
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        let otherDraftID = UUID()
        let otherBytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Recovered"),
                                                                     .image(attachmentID: secondImage.id)]))
        let otherClaim = try await journal.writeDurably(NoteDraftJournalEntry(noteID: otherDraftID, isPersisted: false,
                                                baseRevisionID: nil, content: otherBytes, selectionLocation: 0,
                                                selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        XCTAssertFalse(store.purgeDeleted(before: .distantFuture).contains(id))
        try await journal.discardOwnedDurably(noteID: otherDraftID, claim: otherClaim)
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
        let firstStore = trackAttachmentReconciliation(of: NoteStore(container: container1, persist: { try persistence.save($0) },
                                   attachmentFileStore: files))
        let first = NotesPageController(store: firstStore, journal: NoteDraftJournal(directory: journalDirectory),
                                        saveDelay: .seconds(60))
        await first.startAndWait()
        let draft = try XCTUnwrap(first.active)
        type("Original", into: draft)
        let image = try realImage()
        draft.engine.insertImage(image, pixelSize: CGSize(width: 1, height: 1))
        await XCTAssertTrueAsync(await first.preserveAllDurably())
        let oldID = draft.noteID
        XCTAssertTrue(firstStore.delete(try XCTUnwrap(firstStore.note(withID: oldID))))
        type(" later", into: draft)
        persistence.shouldFail = true
        await XCTAssertTrueAsync(await first.preserveAllDurably(), "failed store save must retain recovery")
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: journalDirectory).entriesDurably().count, 1)

        let container2 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let secondStore = trackAttachmentReconciliation(of: NoteStore(container: container2, persist: { try persistence.save($0) },
                                    attachmentFileStore: files))
        let second = NotesPageController(store: secondStore, journal: NoteDraftJournal(directory: journalDirectory),
                                         saveDelay: .seconds(60))
        await second.startAndWait()
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: journalDirectory).entriesDurably().count, 1,
                       "a second failed save must not retire the original checkpoint")
        XCTAssertEqual(second.active?.noteID, oldID)
        XCTAssertTrue(second.failedDrafts.contains { $0.id == second.active?.id })
        persistence.shouldFail = false
        second.retry()
        XCTAssertEqual(second.active?.state, .conflict(.deleted))
        XCTAssertEqual(second.active?.noteID, oldID, "Retry cannot silently assign a new ID")
        await XCTAssertTrueAsync(await second.keepAsNewNoteDurably())
        let newID = try XCTUnwrap(second.active?.noteID)
        XCTAssertNotEqual(newID, oldID)
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: journalDirectory).entriesDurably().isEmpty)
        XCTAssertEqual(try secondStore.attachmentRows(forNoteID: newID).count, 1)
        XCTAssertTrue(secondStore.purgeDeleted(before: .distantFuture).contains(oldID))

        let container3 = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                  storeDirectory: storeDirectory)
        let thirdStore = trackAttachmentReconciliation(of: NoteStore(container: container3, attachmentFileStore: files))
        let third = NotesPageController(store: thirdStore, journal: NoteDraftJournal(directory: journalDirectory))
        await XCTAssertTrueAsync(await third.openDurably(noteID: newID))
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

    func testDueSaveDuringWritingToolsCheckpointsSilentlyThenSavesOnce() async throws {
        let controller = makeController(delay: .milliseconds(20))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let revision = store.note(withID: session.noteID)?.revisionID
        session.engine.writingToolsWillBegin()
        XCTAssertEqual(session.engine.activity, .writingToolsSafe)
        session.engine.textStorage.replaceCharacters(in: NSRange(location: session.engine.textStorage.length, length: 0),
                                                     with: " after")
        session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        XCTAssertEqual(store.note(withID: session.noteID)?.revisionID, revision)
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
        session.engine.writingToolsDidEnd()
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        XCTAssertNotEqual(store.note(withID: session.noteID)?.revisionID, revision)
        await controller.waitForRecoveryWork()
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty)
    }

    func testDueSaveDuringIMECompositionHasNoFalseNotSavedStatus() async throws {
        let controller = makeController(delay: .milliseconds(20))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let revision = store.note(withID: session.noteID)?.revisionID
        let (_, textView) = session.engine.makeView()
        textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        XCTAssertEqual(store.note(withID: session.noteID)?.revisionID, revision)
        textView.unmarkText()
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
    }

    func testBackgroundPreserveDoesNotCancelAnotherSessionAutosave() async throws {
        let controller = makeController(delay: .milliseconds(80))
        await controller.startAndWait()
        let first = try XCTUnwrap(controller.active)
        type("First", into: first)
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        let second = try XCTUnwrap(controller.active)
        type("Second", into: second)
        type(" edited", into: first)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(first))
        gate.shouldFail = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.note(withID: second.noteID)?.title, "Second")
        XCTAssertFalse(NoteSessionPolicy.needsAttention(second.state))
    }

    func testHideAndQuitRefuseActiveWritingToolsWithAccurateNotice() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        session.engine.writingToolsWillBegin()
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.hide))
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.quit))
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.pageSwitch))
        XCTAssertEqual(session.notice, "Finish Writing Tools first.")
        XCTAssertFalse(NoteSessionPolicy.needsAttention(session.state))
        session.engine.writingToolsDidEnd()
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
    }

    func testFlushDoesNotEndRunningWritingTools() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        session.engine.textViewWritingToolsWillBegin(textView)
        XCTAssertEqual(session.engine.activity, .writingToolsSafe)
        session.engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
        session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(session.engine.activity, .writingToolsSafe)
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
        session.engine.writingToolsDidEnd()
    }

    func testWritingToolsAvailabilityDoesNotChangeInsideStartCallback() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        let original = try XCTUnwrap(session.engine.onWritingToolsWillBegin)
        gate.shouldFail = true
        session.engine.onWritingToolsWillBegin = {
            let availableBefore = textView.writingToolsBehavior
            let result = original()
            XCTAssertEqual(textView.writingToolsBehavior, availableBefore)
            return result
        }
        session.engine.writingToolsWillBegin()
        XCTAssertEqual(session.engine.activity, .writingToolsRefused)
        session.engine.writingToolsDidEnd()
        gate.shouldFail = false
        XCTAssertEqual(textView.writingToolsBehavior, .none)
    }

    func testRefusedWritingToolsSelfHealsWhenTheViewEndsBeforeNextEdit() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        gate.shouldFail = true
        session.engine.textViewWritingToolsWillBegin(textView)
        gate.shouldFail = false
        XCTAssertEqual(session.engine.activity, .writingToolsRefused)
        XCTAssertFalse(textView.isWritingToolsActive)
        textView.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
        textView.insertText(" after", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(session.engine.activity, .idle)
        XCTAssertEqual(session.engine.document().title, "Before after")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: session.noteID)?.title, "Before after")
    }

    func testWritingToolsReturnsAfterTheNextSuccessfulStoreSave() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        gate.shouldFail = true
        session.engine.writingToolsWillBegin()
        XCTAssertEqual(session.engine.activity, .writingToolsRefused)
        session.engine.writingToolsDidEnd()
        gate.shouldFail = false
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        type(" after", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(textView.writingToolsBehavior, .complete)
    }

    func testLeaveSelfHealsWhenWritingToolsViewAlreadyEnded() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Before", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let (_, textView) = session.engine.makeView()
        session.engine.textViewWritingToolsWillBegin(textView)
        XCTAssertEqual(session.engine.activity, .writingToolsSafe)
        XCTAssertFalse(textView.isWritingToolsActive)
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        XCTAssertEqual(session.engine.activity, .idle)
    }

    func testDeletedNoteKeepsItsIDAndDraftUntilExplicitKeep() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Original", into: draft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let oldID = draft.noteID
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: oldID))))
        type(" later", into: draft)
        await XCTAssertTrueAsync(await controller.preserveDurably(draft))
        XCTAssertEqual(draft.state, .conflict(.deleted))
        XCTAssertEqual(draft.noteID, oldID)
        XCTAssertEqual(controller.statusItems(for: draft).first, .deletedElsewhere)
        XCTAssertTrue(controller.failedDrafts.contains { $0 === draft })
        controller.retry()
        XCTAssertEqual(draft.noteID, oldID)
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(draft.noteID, oldID)
        XCTAssertEqual(store.note(withID: draft.noteID)?.title, "Original later")
    }

    func testPresentRechecksConflictKindAfterDeleteAndRestore() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Mine", into: session)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        let id = session.noteID
        type(" later", into: session)
        let note = try XCTUnwrap(store.note(withID: id))
        guard case .success = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
            document: NoteDocument(blocks: [.text("Agent")]), agentName: "Claude", disposition: .direct)
        else { return XCTFail("external change fixture") }
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        XCTAssertEqual(session.state, .conflict(.changed))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        controller.present()
        XCTAssertEqual(session.state, .conflict(.deleted))
        XCTAssertTrue(store.restoreDeleted(noteID: id))
        controller.present()
        XCTAssertEqual(session.state, .conflict(.changed))
        XCTAssertEqual(session.engine.document().title, "Mine later")
    }
}

@MainActor
private final class FailingJournal: NoteDraftJournaling {
    struct Failure: Error {}
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) throws -> NoteRecoveryClaim { throw Failure() }
    func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws {}
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { [] }
}

@MainActor
private final class RemoveFailingJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    private let fileManager = UnlinkFailingFileManager()
    /// The next checkpoint unlink fails; the journal's own marker fallback runs.
    var failNextRemove: Bool {
        get { fileManager.failNextCheckpointRemoval }
        set { fileManager.failNextCheckpointRemoval = newValue }
    }

    init(directory: URL) { base = NoteDraftJournal(directory: directory, fileManagerFactory: { [fileManager] in fileManager }) }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }

    var requiresAsyncIO: Bool { true }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws { try await base.discardOwnedDurably(noteID: noteID, claim: claim) }
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

@MainActor
final class NoteSessionPolicyTests: XCTestCase {
    func testEveryGateInputCombination() async {
        let states: [NoteSession.State] = [
            .untouched, .clean, .dirty, .notSaved("failed"), .onlyInMemory("failed"),
            .conflict(.changed), .conflict(.deleted), .readOnly
        ]
        let activities: [NoteEditorEngine.Activity] = [
            .idle, .composing, .writingToolsSafe, .writingToolsRefused
        ]
        for state in states {
            for activity in activities {
                let idle = activity == .idle
                let conflict: Bool = if case .conflict = state { true } else { false }
                let readOnly: Bool = if case .readOnly = state { true } else { false }
                for marked in [false, true] {
                    XCTAssertEqual(NoteSessionPolicy.canWriteStore(state, activity: activity, hasMarkedText: marked),
                                   idle && !marked && !conflict && !readOnly)
                    XCTAssertEqual(NoteSessionPolicy.dueSaveAction(state, activity: activity, hasMarkedText: marked),
                                   idle && !marked && !conflict ? .preserve : .checkpointOnly)
                    XCTAssertEqual(NoteSessionPolicy.canLeave(activity, hasMarkedText: marked), idle && !marked)
                    XCTAssertEqual(NoteSessionPolicy.commandAllowed(activity, hasMarkedText: marked), idle && !marked)
                    for refused in [false, true] {
                        let available = idle && !marked && !refused && (state == .clean || state == .dirty)
                        XCTAssertEqual(NoteSessionPolicy.writingToolsAvailable(state, activity: activity,
                            refusedSinceLastStoreSave: refused, hasMarkedText: marked), available)
                    }
                    for hasBatch in [false, true] {
                        for presence in [NoteSessionPolicy.Presence.onScreen, .background, .released] {
                            let evictable = state == .untouched || state == .clean || state == .readOnly
                            XCTAssertEqual(NoteSessionPolicy.canEvict(state, activity: activity,
                                                                     hasBatch: hasBatch, presence: presence),
                                           idle && !hasBatch && presence != .onScreen && evictable)
                            let disposition: NoteSessionPolicy.AgentDisposition = presence == .onScreen ? .proposal
                                : hasBatch ? .refuseImport : (state == .clean || state == .readOnly ? .direct : .flush)
                            XCTAssertEqual(NoteSessionPolicy.agentDisposition(presence, state: state, hasBatch: hasBatch),
                                           disposition)
                        }
                        XCTAssertEqual(NoteSessionPolicy.keepAsNewAllowed(state, activity: activity,
                            hasBatch: hasBatch, hasMarkedText: marked), idle && !marked && !hasBatch && conflict)
                    }
                }
                let completion: NoteSessionPolicy.ImportCompletion = !idle ? .deferUntilIdle
                    : (state == .conflict(.deleted) || readOnly ? .drop : .insert)
                XCTAssertEqual(NoteSessionPolicy.importCompletion(state, activity: activity), completion)
            }
        }
        XCTAssertEqual(NoteSessionPolicy.agentDisposition(.released, state: nil, hasBatch: false), .direct)
    }
}

/// One fresh, real controller/engine/store fixture per transition. The table
/// covers every column and event in session-lifecycle.md §1.6; the focused
/// tests above assert the detailed text and version outcomes of each route.
@MainActor
final class NoteSessionMatrixTests: XCTestCase {
    private enum Column: String, CaseIterable {
        case u, c, d, n, m, x, r, k, w, z, b, bp, cBatch, bBatch
        var isBackground: Bool { self == .b || self == .bp || self == .bBatch }
        var hasBatch: Bool { self == .cBatch || self == .bBatch }
    }

    private enum Event: String, CaseIterable {
        case edit, command, timerOK, timerStoreFails, timerBothFail
        case leaveOK, leaveBothFail, present, agentWrite
        case importStart, importComplete, importFail
        case writingToolsBeginOK, writingToolsBeginFails, writingToolsBypass, writingToolsEnd
        case compositionBegin, compositionEnd, externalChange, externalDelete
        case retry, keepAsNew, launchRecovery, evict
        // Slice 2: Delete Note, its Undo, leaving and reopening the note,
        // and the title's hashtag shorthand.
        case deleteNote, restoreDeleted, reopenLast, titleTag
    }

    /// A = handled, R = refused, N = not applicable, P = proposal,
    /// D = direct, J = journal checkpoint, S = store path.
    /// Each row is in Column.allCases order, including both batch variants.
    private let expected: [(Event, String)] = [
        (.edit,                    "AAAAAARAARNNAN"),
        // Matrix fixtures contain only a title; Date correctly refuses that
        // range. Body-targeted command acceptance is covered by engine tests.
        (.command,                 "RRRRRRRRRRNNRN"),
        (.timerOK,                 "NNSSSJ N JJJNNNN"),
        (.timerStoreFails,         "NNSSSJ N JJJNNNN"),
        (.timerBothFail,           "NNSSSJ N JJJNNNN"),
        (.leaveOK,                 "AAAAAAARRRAAAA"),
        // A visible pending batch needs a checkpoint before it can leave.
        (.leaveBothFail,           "AARRRRARRRARRR"),
        (.present,                 "AAAAAAAAAAAAAA"),
        (.agentWrite,              "RPPPPPRPPPD DP R"),
        (.importStart,             "AAAAAARRRRNNRN"),
        (.importComplete,          "NNNNNNNNNNNNAA"),
        (.importFail,              "NNNNNNNNNNNNAA"),
        (.writingToolsBeginOK,     "RAARRRRRNNNNAN"),
        (.writingToolsBeginFails,  "RRRRRRRRNNNNRN"),
        (.writingToolsBypass,      "NNNNNNNN AANNNN"),
        (.writingToolsEnd,         "NNNNNNNN AANNNN"),
        (.compositionBegin,        "AAAAAARNNNNNAN"),
        (.compositionEnd,          "NNNNNNNANNNNNN"),
        (.externalChange,          "NAAAAARAAAAAAA"),
        (.externalDelete,          "NAAAAAAAAAAAAA"),
        (.retry,                   "NNAAARNNNNNNNN"),
        (.keepAsNew,               "NNNNNANNNNNNNN"),
        (.launchRecovery,          "NNNANANNNNNAAA"),
        (.evict,                   "NNNNNNNNNNANNN"),
        (.deleteNote,              "RAAAARARRRAARR"),
        (.restoreDeleted,          "NAAAANANNNAANN"),
        (.reopenLast,              "AAAAAAARRRNNAN"),
        (.titleTag,                "AAAAAARNNNNNAN")
    ]

    func testEveryStateEventPair() async throws {
        XCTAssertEqual(expected.map(\.0), Event.allCases)
        XCTAssertEqual(Column.allCases.count, 14)
        for (event, row) in expected {
            let cells = Array(row.filter { !$0.isWhitespace })
            XCTAssertEqual(cells.count, Column.allCases.count, "\(event)")
            guard cells.count == Column.allCases.count else { continue }
            for (column, cell) in zip(Column.allCases, cells) {
                let fixture = try await MatrixFixture.make(column, owner: self)
                defer { fixture.cleanup() }
                let initialState = fixture.session.state
                let initialActivity = fixture.session.engine.activity
                let priorCommits = fixture.committedPairs.count
                let priorAttempts = fixture.attemptPairs.count
                let priorJournalWrites = fixture.journal.writeCount
                let priorProposals = fixture.store.pendingEdits(noteID: fixture.session.noteID).count
                if column == .z && event == .writingToolsEnd {
                    let bypass = try await fixture.perform(.writingToolsBypass)
                    XCTAssertEqual(bypass, "A")
                    XCTAssertNotEqual(fixture.session.engine.document(), fixture.startingText)
                }
                let observed = try await fixture.perform(event)
                XCTAssertEqual(observed, cell, "\(column.rawValue) × \(event.rawValue)")
                try fixture.assertInvariants(after: event, decision: observed,
                    initialState: initialState, initialActivity: initialActivity,
                    priorCommits: priorCommits, priorAttempts: priorAttempts,
                    priorJournalWrites: priorJournalWrites,
                    priorProposals: priorProposals)
            }
        }
    }

    func testStaleBaseNeverCommitsAcrossExternalEvents() async throws {
        for column in [Column.d, .n, .m] {
            for event in [Event.externalChange, .externalDelete] {
                let fixture = try await MatrixFixture.make(column, owner: self)
                defer { fixture.cleanup() }
                let decision = try await fixture.perform(event)
                XCTAssertEqual(decision, "A")
                let committed = fixture.committedPairs.count
                _ = await fixture.controller.preserveDurably(fixture.session)
                XCTAssertEqual(fixture.committedPairs.count, committed, "\(column) × \(event)")
                XCTAssertEqual(fixture.session.state,
                    event == .externalDelete ? .conflict(.deleted) : .conflict(.changed))
            }
        }
    }

    @MainActor
    private final class MatrixJournal: NoteDraftJournaling {
        struct Failure: Error {}
        let base: NoteDraftJournal
        var failWrites = false
        private(set) var writeCount = 0
        init(directory: URL) { base = NoteDraftJournal(directory: directory) }
        func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                   replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
            if failWrites { throw Failure() }
            let result = try await base.writeDurably(entry, staged: staged, replacing: claim)
            writeCount += 1
            return result
        }
        func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
            try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
        }
        func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }

    var requiresAsyncIO: Bool { true }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws { try await base.discardOwnedDurably(noteID: noteID, claim: claim) }
}

    @MainActor
    private final class MatrixFixture {
        let column: Column
        let directory: URL
        let gate: PersistenceGate
        let journal: MatrixJournal
        let store: NoteStore
        let controller: NotesPageController
        let loader: DelayedImageLoader
        let session: NoteSession
        let window: NSWindow
        let textView: NoteEditorTextView
        let startingText: NoteDocument
        let startingCanUndo: Bool
        var visible: Bool
        var attemptPairs: [(UUID?, UUID?)] = []
        var committedPairs: [(UUID?, UUID?)] = []

        private init(column: Column, directory: URL, gate: PersistenceGate, journal: MatrixJournal,
                     store: NoteStore, controller: NotesPageController, loader: DelayedImageLoader,
                     session: NoteSession, window: NSWindow, textView: NoteEditorTextView) {
            self.column = column
            self.directory = directory
            self.gate = gate
            self.journal = journal
            self.store = store
            self.controller = controller
            self.loader = loader
            self.session = session
            self.window = window
            self.textView = textView
            self.startingText = session.engine.document()
            self.startingCanUndo = !session.engine.history.undoOps.isEmpty
            self.visible = !column.isBackground
            store.documentSaveAttempt = { [weak self] base, presented in
                self?.attemptPairs.append((base, presented))
            }
            store.documentSaveCommitted = { [weak self] base, presented in
                self?.committedPairs.append((base, presented))
            }
        }

        static func make(_ column: Column, owner: XCTestCase) async throws -> MatrixFixture {
            let directory = owner.ownedTemporaryDirectory(prefix: "AtticMatrix")
            let gate = PersistenceGate()
            let store = try owner.makeTestNoteStore(persist: { try gate.save($0) },
                                              attachmentFileStore: owner.makeTestAttachmentFileStore())
            let journal = MatrixJournal(directory: directory)
            let loader = DelayedImageLoader()
            let image = try pixel()
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(600),
                pauseVersionDelay: .seconds(600), imageLoader: { url in await loader.load(url, template: image) })
            await controller.startAndWait()
            var session = try XCTUnwrap(controller.active)
            if column != .u {
                type("Start", in: session)
                await XCTAssertTrueAsync(await controller.preserveAllDurably())
            }
            switch column {
            case .d, .n, .m, .x, .bp:
                if column == .x, let note = store.note(withID: session.noteID) {
                    _ = store.agentWrite(noteID: session.noteID, baseRevisionToken: note.revisionToken,
                        document: NoteDocument(blocks: [.text("Elsewhere")]), agentName: "Matrix", disposition: .direct)
                }
                type(" draft", in: session)
                if column == .n || column == .m || column == .bp { gate.shouldFail = true }
                if column == .m { journal.failWrites = true }
                if column != .d { _ = await controller.preserveDurably(session) }
                journal.failWrites = false
                if column == .bp {
                    await XCTAssertTrueAsync(await controller.newNoteDurably())
                }
                gate.shouldFail = false
            case .r:
                guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
                    document: NoteDocument(blocks: [.text("Read only")])) else { throw MatrixJournal.Failure() }
                for row in try store.modelContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })) {
                    row.content = Data("broken bytes".utf8)
                }
                try store.modelContext.save()
                await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
                session = try XCTUnwrap(controller.active)
            case .b, .bBatch:
                break
            default: break
            }
            let (scroll, textView) = session.engine.makeView()
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            switch column {
            case .k:
                textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
            case .w:
                session.engine.writingToolsWillBegin()
            case .z:
                gate.shouldFail = true
                session.engine.writingToolsWillBegin()
                gate.shouldFail = false
            case .cBatch, .bBatch:
                controller.importImages([URL(fileURLWithPath: "/tmp/matrix.png")])
                for _ in 0..<100 where await loader.started == 0 { try await Task.sleep(for: .milliseconds(2)) }
                XCTAssertTrue(session.isImporting)
            default: break
            }
            if column == .b || column == .bBatch { await XCTAssertTrueAsync(await controller.newNoteDurably()) }
            return MatrixFixture(column: column, directory: directory, gate: gate, journal: journal,
                                 store: store, controller: controller, loader: loader,
                                 session: session, window: window, textView: textView)
        }

        private static func pixel() throws -> StagedNoteAttachment {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.setColor(.red, atX: 0, y: 0)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            return StagedNoteAttachment(id: UUID(), filename: "matrix.png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                data: data)
        }

        private static func type(_ value: String, in session: NoteSession) {
            session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                with: NSAttributedString(string: value), name: "Typing")
        }

        func cleanup() {
            window.contentView = nil
            window.close()

        }

        func perform(_ event: Event) async throws -> Character {
            let onScreen = visible && controller.active === session && !controller.isLibraryPresented
            switch event {
            case .edit, .command:
                guard onScreen else { return "N" }
                if session.isReadOnly { return "R" }
                let before = session.engine.document()
                if event == .edit {
                    if session.engine.activity == .composing {
                        textView.setMarkedText("中!", selectedRange: NSRange(location: 2, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else {
                        textView.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
                        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                }
                else { session.engine.insertDate(NoteDay(year: 2026, month: 10, day: 1)!) }
                return session.engine.document() == before ? "R" : "A"
            case .timerOK, .timerStoreFails, .timerBothFail:
                guard onScreen else { return "N" }
                let state = session.state
                let checkpoint = NoteSessionPolicy.dueSaveAction(state, activity: session.engine.activity,
                    hasMarkedText: textView.hasMarkedText()) == .checkpointOnly
                gate.shouldFail = event != .timerOK
                journal.failWrites = event == .timerBothFail
                await controller.runDueSave(session)
        await controller.waitForRecoveryWork()
                gate.shouldFail = false
                journal.failWrites = false
                if checkpoint { return "J" }
                switch state {
                case .dirty, .notSaved, .onlyInMemory: return "S"
                default: return "N"
                }
            case .leaveOK, .leaveBothFail:
                gate.shouldFail = event == .leaveBothFail
                journal.failWrites = event == .leaveBothFail
                let accepted = await controller.prepareToLeaveDurably(.hide)
                if accepted { visible = false }
                gate.shouldFail = false
                journal.failWrites = false
                return accepted ? "A" : "R"
            case .present:
                if column.isBackground {
                    guard await controller.openDurably(noteID: session.noteID) else { return "R" }
                } else { controller.present() }
                visible = true
                return "A"
            case .agentWrite:
                guard let note = store.note(withID: session.noteID) else { return "R" }
                let token = note.revisionToken
                let disposition = store.agentWriteDisposition(session.noteID)
                if case .refuse = disposition { return "R" }
                let result = store.agentWrite(noteID: session.noteID, baseRevisionToken: token,
                    document: NoteDocument(blocks: [.text("Agent")]), agentName: "Matrix", disposition: disposition)
                switch result {
                case .success(.pending): return "P"
                case .success(.applied): return "D"
                case .failure(.staleRevision): return "D" // flush succeeded; the agent must re-read
                case .failure: return "R"
                }
            case .importStart:
                guard onScreen else { return "N" }
                let before = session.isImporting
                controller.importImages([URL(fileURLWithPath: "/tmp/another-matrix.png")])
                if !before {
                    for _ in 0..<100 where await loader.started == 0 { try await Task.sleep(for: .milliseconds(2)) }
                }
                await controller.waitForRecoveryWork()
                return !before && session.isImporting ? "A" : "R"
            case .importComplete, .importFail:
                guard column.hasBatch else { return "N" }
                await loader.releaseNext(success: event == .importComplete)
                await controller.waitForImportWork()
                return session.isImporting ? "R" : "A"
            case .writingToolsBeginOK, .writingToolsBeginFails:
                guard onScreen else { return "N" }
                guard session.engine.activity != .writingToolsSafe && session.engine.activity != .writingToolsRefused else { return "N" }
                gate.shouldFail = event == .writingToolsBeginFails
                session.engine.writingToolsWillBegin()
                gate.shouldFail = false
                return session.engine.activity == .writingToolsSafe ? "A" : "R"
            case .writingToolsBypass:
                guard session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused else { return "N" }
                session.engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
                session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
                return "A"
            case .writingToolsEnd:
                guard session.engine.activity == .writingToolsSafe || session.engine.activity == .writingToolsRefused else { return "N" }
                session.engine.writingToolsDidEnd()
                return "A"
            case .compositionBegin:
                guard onScreen else { return "N" }
                guard session.engine.activity == .idle else { return "N" }
                guard !session.isReadOnly else { return "R" }
                textView.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
                return session.engine.activity == .composing ? "A" : "R"
            case .compositionEnd:
                guard session.engine.activity == .composing else { return "N" }
                textView.unmarkText()
                session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
                return "A"
            case .externalChange:
                guard let note = store.note(withID: session.noteID) else { return "N" }
                let result = store.agentWrite(noteID: session.noteID, baseRevisionToken: note.revisionToken,
                    document: NoteDocument(blocks: [.text("Elsewhere again")]), agentName: "Matrix", disposition: .direct)
                if case .success = result { return "A" }
                return "R"
            case .externalDelete:
                guard let note = store.note(withID: session.noteID) else { return "N" }
                return store.delete(note) ? "A" : "R"
            case .retry:
                guard onScreen else { return "N" }
                guard session.engine.activity == .idle else { return "N" }
                guard NoteSessionPolicy.hasPendingWork(session.state) else { return "N" }
                if session.isConflict { return "R" }
                controller.retry()
                return "A"
            case .keepAsNew:
                guard onScreen, session.isConflict else { return "N" }
                return await controller.keepAsNewNoteDurably() ? "A" : "R"
            case .launchRecovery:
                guard !(try journal.entries()).isEmpty else { return "N" }
                let recovered = NotesPageController(store: store, journal: journal, saveDelay: .seconds(600))
                await recovered.recoverAtLaunchAndWait()
                return "A"
            case .evict:
                let presence: NoteSessionPolicy.Presence = onScreen ? .onScreen : .background
                return NoteSessionPolicy.canEvict(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, presence: presence) ? "A" : "N"
            case .deleteNote:
                textBeforeDelete = session.engine.document()
                return await controller.deleteNoteDurably(noteID: session.noteID) ? "A" : "R"
            case .restoreDeleted:
                textBeforeDelete = session.engine.document()
                guard await controller.deleteNoteDurably(noteID: session.noteID) else { return "N" }
                return controller.restoreDeletedNote(noteID: session.noteID, reopen: true) ? "A" : "R"
            case .reopenLast:
                guard controller.active === session else { return "N" }
                textBeforeDelete = session.engine.document()
                guard await controller.prepareToLeaveDurably(.pageSwitch) else { return "R" }
                controller.present()
                return controller.active === session ? "A" : "R"
            case .titleTag:
                guard onScreen, session.engine.activity == .idle else { return "N" }
                let title = session.engine.titleParagraphRange
                textView.setSelectedRange(NSRange(location: NSMaxRange(title), length: 0))
                textView.insertText(" #matrix", replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
                return session.engine.tags.contains("matrix") ? "A" : "R"
            }
        }

        /// The note's text before a delete or a leave (checked after).
        var textBeforeDelete: NoteDocument?

        func assertInvariants(after event: Event, decision: Character,
                              initialState: NoteSession.State, initialActivity: NoteEditorEngine.Activity,
                              priorCommits: Int, priorAttempts: Int,
                              priorJournalWrites: Int, priorProposals: Int) throws {
            let context = "\(column) × \(event)"
            let committed = committedPairs.count - priorCommits
            let checkpoints = journal.writeCount - priorJournalWrites
            let proposals = store.pendingEdits(noteID: session.noteID).count - priorProposals
            if event == .agentWrite {
                XCTAssertEqual(proposals, decision == "P" ? 1 : 0, context)
                if decision == "P" { XCTAssertEqual(committed, 0, context) }
            }
            if event == .timerOK || event == .timerStoreFails || event == .timerBothFail {
                let onScreen = !column.isBackground
                let checkpointOnly = NoteSessionPolicy.dueSaveAction(initialState, activity: initialActivity,
                    hasMarkedText: column == .k) == .checkpointOnly
                if onScreen && checkpointOnly {
                    XCTAssertEqual(committed, 0, context)
                    XCTAssertEqual(checkpoints, event == .timerBothFail ? 0 : 1, context)
                    if event == .timerBothFail {
                        if case .onlyInMemory = session.state {} else { XCTFail(context + ": checkpoint failure must be visible") }
                    } else {
                        XCTAssertEqual(session.state, initialState, context)
                    }
                } else if onScreen && initialState.needsStoreSave {
                    XCTAssertEqual(committed, event == .timerOK ? 1 : 0, context)
                    XCTAssertEqual(checkpoints, event == .timerStoreFails ? 1 : 0, context)
                    switch event {
                    case .timerOK: XCTAssertEqual(session.state, .clean, context)
                    case .timerStoreFails:
                        if case .notSaved = session.state {} else { XCTFail(context + ": failed store needs a checkpoint") }
                    case .timerBothFail:
                        if case .onlyInMemory = session.state {} else { XCTFail(context + ": both failures must remain visible") }
                    default: break
                    }
                }
            }
            if event == .agentWrite && decision == "P" {
                XCTAssertEqual(session.state, initialState, context)
            }
            if event == .importStart && decision == "A" {
                XCTAssertTrue(session.isImporting, context)
                XCTAssertEqual(session.state, initialState, context)
                XCTAssertEqual(committed, 0, context)
                XCTAssertEqual(checkpoints, 1, context + ": a pending import must be checkpointed before loading")
            }
            if (event == .importComplete || event == .importFail) && decision == "A" {
                XCTAssertFalse(session.isImporting, context)
                if event == .importComplete { XCTAssertEqual(session.state, .clean, context) }
                else { XCTAssertEqual(session.state, initialState, context) }
            }
            if event == .writingToolsBeginOK && decision == "A" {
                XCTAssertEqual(session.engine.activity, .writingToolsSafe, context)
            }
            if event == .writingToolsBeginFails && decision == "R", initialActivity == .idle,
               !column.isBackground {
                XCTAssertEqual(session.engine.activity, .writingToolsRefused, context)
            }
            if event == .writingToolsEnd && decision == "A" {
                XCTAssertEqual(session.engine.activity, .idle, context)
            }
            if event == .compositionBegin && decision == "A" {
                XCTAssertEqual(session.engine.activity, .composing, context)
            }
            if event == .compositionEnd && decision == "A" {
                XCTAssertEqual(session.engine.activity, .idle, context)
            }
            if event == .keepAsNew && decision == "A" {
                XCTAssertEqual(session.state, .clean, context)
            }
            if event == .retry && decision == "A" { XCTAssertEqual(session.state, .clean, context) }
            if (event == .externalChange || event == .externalDelete) && decision == "A" {
                XCTAssertEqual(session.state, initialState, context)
            }
            if event == .leaveOK && decision == "A" && initialState.needsStoreSave {
                XCTAssertEqual(session.state, .clean, context)
            }
            if event == .leaveBothFail && decision == "R" && initialState.needsStoreSave
                && initialActivity == .idle {
                if case .onlyInMemory = session.state {} else { XCTFail(context + ": leave lost its recovery path") }
            }
            // I1: a persisted clean session at its base has the stored text.
            if case .clean = session.state, session.engine.activity == .idle,
               !textView.hasMarkedText(),
               let loaded = store.loadDocument(noteID: session.noteID),
               loaded.revisionID == session.baseRevisionID,
               controller.active === session, visible {
                XCTAssertEqual(session.engine.document(), loaded.content.document, context)
            }
            if session.engine.activity == .idle,
               (session.state.isJournalProblem),
               event != .edit && event != .command && event != .compositionBegin && event != .titleTag,
               let entry = try journal.entries().first(where: { $0.0.noteID == session.noteID })?.0 {
                XCTAssertEqual(NoteContentCodec.decode(entry.content).document,
                               session.engine.checkpointDocument(), context)
            }
            if case .onlyInMemory = session.state {
                XCTAssertEqual(controller.statusItems(for: session).first?.label, "Only in memory")
                XCTAssertFalse(NoteSessionPolicy.canEvict(session.state, activity: session.engine.activity,
                    hasBatch: session.isImporting, presence: .background))
            }
            // Slice 2: a deleted note leaves no session, no recovery copy and
            // no store row; its latest text is what Restore brings back.
            if event == .deleteNote && decision == "A" {
                XCTAssertNil(store.note(withID: session.noteID), context)
                XCTAssertEqual(store.agentWriteDisposition(session.noteID), .direct, context)
                XCTAssertFalse(try journal.entries().contains { $0.0.noteID == session.noteID }, context)
                XCTAssertTrue(store.recentlyDeletedNotes().contains { $0.ref.id == session.noteID }, context)
                XCTAssertFalse(controller.failedDrafts.contains { $0.noteID == session.noteID }, context)
            }
            if event == .restoreDeleted && decision == "A" {
                let restored = try XCTUnwrap(controller.active, context)
                XCTAssertEqual(restored.noteID, session.noteID, context)
                XCTAssertEqual(restored.state, session.isReadOnly ? .readOnly : .clean, context)
                if !session.isReadOnly {
                    XCTAssertEqual(store.loadDocument(noteID: session.noteID)?.content.document, textBeforeDelete, context)
                }
                XCTAssertEqual(store.agentWriteDisposition(session.noteID), .proposal, context)
            }
            if event == .reopenLast && decision == "A" {
                XCTAssertEqual(session.engine.document(), textBeforeDelete, context)
                XCTAssertFalse(session.state == .dirty, context)
            }
            if event == .titleTag && decision == "A" {
                XCTAssertFalse(session.engine.titleParagraphRange.length > 0
                    && session.engine.lineText(at: 0).contains("#matrix"), context)
                XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state), context)
                // One Undo brings the text back and takes the tag away.
                XCTAssertTrue(session.engine.history.undo(), context)
                XCTAssertTrue(session.engine.lineText(at: 0).contains("#matrix"), context)
                XCTAssertFalse(session.engine.tags.contains("matrix"), context)
                XCTAssertTrue(session.engine.history.redo(), context)
                XCTAssertTrue(session.engine.tags.contains("matrix"), context)
            }
            // I2: every committed editor save used the revision it saw.
            XCTAssertLessThanOrEqual(committedPairs.count, attemptPairs.count, context)
            for (base, presented) in committedPairs { XCTAssertEqual(base, presented, context) }
            // I2/I6: conflicts, read-only notes and active text services never reach the store writer.
            if initialState.isConflictOrReadOnly || initialActivity != .idle,
               event != .writingToolsEnd && event != .compositionEnd {
                XCTAssertEqual(attemptPairs.count, priorAttempts, context)
            }
            // I4: the refused Writing Tools end rewinds text and Undo.
            if column == .z && event == .writingToolsEnd {
                XCTAssertEqual(session.engine.document(), startingText)
                XCTAssertEqual(session.engine.history.canUndo, startingCanUndo)
            }
            // I5: an on-screen stored note is always offered as a proposal.
            if event != .launchRecovery, visible && controller.active === session && !controller.isLibraryPresented,
               store.note(withID: session.noteID) != nil {
                XCTAssertEqual(store.agentWriteDisposition(session.noteID), .proposal, context)
            }
            // I7: neither durable location may reference missing image bytes.
            for note in store.notes {
                guard let document = store.loadDocument(noteID: note.id)?.content.document else { continue }
                let rows = try store.attachmentRows(forNoteID: note.id)
                for id in document.attachmentIDs { XCTAssertTrue(rows.contains { $0.id == id && $0.payload != nil }) }
            }
            for (entry, staged) in try journal.entries() {
                let ids = Set(staged.map(\.id))
                for id in entry.staged.map(\.id) { XCTAssertTrue(ids.contains(id)) }
            }
        }
    }
}

private extension NoteSession.State {
    var isConflictOrReadOnly: Bool {
        switch self {
        case .conflict, .readOnly: true
        default: false
        }
    }

    var needsStoreSave: Bool {
        switch self {
        case .dirty, .notSaved, .onlyInMemory: true
        default: false
        }
    }

    var isJournalProblem: Bool {
        switch self {
        case .notSaved, .conflict: true
        default: false
        }
    }
}

private actor SuspendedRecoveryDecoder {
    private var started = false
    private var continuation: CheckedContinuation<Bool, Never>?
    func decode(_ bytes: Data) async -> NoteDocument? {
        let fail = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
        return fail ? nil : NoteContentCodec.decode(bytes).document
    }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
    func resume(fail: Bool) { continuation?.resume(returning: fail); continuation = nil }
}

@MainActor
private final class CountingDeadlineJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    private(set) var writeCount = 0
    var beforeWrite: (() async -> Void)?
    init(directory: URL) { base = NoteDraftJournal(directory: directory) }
    var requiresAsyncIO: Bool { true }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                      replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        writeCount += 1
        await beforeWrite?()
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
}

private actor ControlledDeadlinePreparer {
    private(set) var started = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<Int>()
    func prepare(_ document: NoteDocument) async -> PreparedNoteDocument? {
        let index = started
        started += 1
        if index < 2, !released.contains(index) {
            await withCheckedContinuation { pending[index] = $0 }
        }
        return try? PreparedNoteDocument(document)
    }
    func release(_ index: Int) { released.insert(index); pending.removeValue(forKey: index)?.resume() }
}

private actor DeadlineWriteBarrier {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseFirstWrite() async {
        guard !paused else { return }
        paused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension NotesPageControllerTests {
    func testA38PasteTailAgreesLiveSavedReopenedAndExportedWithAttachments() async throws {
        let image = try realImage()
        var heading = NoteBlock.text("Prefix Tail \u{FFFC}", style: "heading")
        heading.level = 2
        heading.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 8)!))]
        let original = NoteDocument(blocks: [.text("Paste"), heading,
            .image(attachmentID: image.id, pixelWidth: 2, pixelHeight: 2), .text("Neighbor", style: "quote")])
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: original, staged: [image]) else { return XCTFail("fixture") }
        let controller = makeController()
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        _ = session.engine.makeView()
        let before = session.engine.document()
        XCTAssertTrue(session.engine.pastePlainText("one\ntwo\nthree", at: NSRange(location: 13, length: 0)))
        let live = session.engine.document()
        XCTAssertNil(live.blocks[3].style, "the old tail joins the last Body paragraph")
        XCTAssertEqual(live.blocks[3].inlines, heading.inlines)
        XCTAssertEqual(live.attachmentIDs, original.attachmentIDs)
        XCTAssertTrue(controller.save(session))
        let saved = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        XCTAssertEqual(saved, live)
        let second = makeController()
        await second.startAndWait()
        await XCTAssertTrueAsync(await second.openDurably(noteID: id))
        let reopened = try XCTUnwrap(second.active).engine.document()
        XCTAssertEqual(reopened, live)
        XCTAssertEqual(controller.markdown(noteID: id), second.markdown(noteID: id))
        XCTAssertEqual(NoteMarkdownExport.markdown(live), NoteMarkdownExport.markdown(saved))
        XCTAssertTrue(session.engine.history.undo())
        XCTAssertEqual(session.engine.document(), before)
    }
}
