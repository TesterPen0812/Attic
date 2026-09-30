import AppKit
import CryptoKit
import PDFKit
import SwiftData
import XCTest
@testable import Attic

private actor TwoSourceLoader {
    let first: StagedNoteAttachment
    let second: StagedNoteAttachment
    private var calls = 0
    private var waiting: CheckedContinuation<Void, Never>?

    init(first: StagedNoteAttachment, second: StagedNoteAttachment) {
        self.first = first
        self.second = second
    }

    func load(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? {
        calls += 1
        if calls == 2 { await withCheckedContinuation { waiting = $0 } }
        return (calls == 1 ? first : second, CGSize(width: 8, height: 8))
    }

    func release() { waiting?.resume(); waiting = nil }
}

private actor ReadCounter {
    private(set) var count = 0
    func read(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? { count += 1; return nil }
}

private actor FirstSuspendedLoader {
    let item: StagedNoteAttachment
    private(set) var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(_ item: StagedNoteAttachment) { self.item = item }
    func load(_ url: URL) async -> (StagedNoteAttachment, CGSize?)? {
        started = true
        await withCheckedContinuation { waiting = $0 }
        return (item, CGSize(width: 8, height: 8))
    }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor
private final class OnDemandFailingJournal: NoteDraftJournaling {
    struct Failure: Error {}
    let base: NoteDraftJournal
    var failNextWrite = false
    var failNextRemove = false
    init(_ base: NoteDraftJournal) { self.base = base }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        if failNextWrite { failNextWrite = false; throw Failure() }
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        if failNextRemove { failNextRemove = false; throw Failure() }
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }

    var requiresAsyncIO: Bool { true }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        if failNextRemove { failNextRemove = false; throw Failure() }
        try await base.discardOwnedDurably(noteID: noteID, claim: claim)
    }
}

@MainActor
private final class StoredImageProvider: NoteImageProviding {
    let item: StagedNoteAttachment
    init(_ item: StagedNoteAttachment) { self.item = item }
    func fileURL(forAttachment id: UUID) async -> URL? { nil }
    func filename(forAttachment id: UUID) -> String? { id == item.id ? item.filename : nil }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? { id == item.id ? item : nil }
    func attachmentBytes(forAttachment id: UUID) -> StagedNoteAttachment? { imageBytes(forAttachment: id) }
    func hasAttachmentBytes(_ id: UUID) -> Bool { id == item.id }
    func locateAttachment(_ id: UUID, at url: URL) async -> Bool { false }
}

@MainActor
final class NoteSlice3bTests: XCTestCase {
    private func waitFor(_ condition: @MainActor () throws -> Bool) async throws {
        for _ in 0..<100 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for import state")
    }
    private func staged(_ name: String = "plan.pdf") -> StagedNoteAttachment {
        let data = Data("file bytes".utf8)
        return StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: "com.adobe.pdf",
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
    }

    private func stagedSized(_ name: String, bytes: Int) -> StagedNoteAttachment {
        let data = Data(repeating: 0x42, count: bytes)
        return StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: "com.adobe.pdf",
            byteCount: Int64(bytes), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
    }

    private func stagedImage() throws -> StagedNoteAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return StagedNoteAttachment(id: UUID(), filename: "photo.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
    }

    func testFileFormatRoundTripAndCapabilityGate() async throws {
        let item = staged()
        let file = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let document = NoteDocument(blocks: [.text("Plan"), file], requires: ["file-v1"])
        let bytes = try NoteContentCodec.encode(document)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("file-v1"))
        guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else { return XCTFail() }
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.attachmentIDs, [item.id])
        XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: document), document)
        let future = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "file-v1", with: "file-v2").utf8)
        guard case let .readOnly(original, .requiresCapabilities(names), _) = NoteContentCodec.decode(future) else {
            return XCTFail("an older capability set must preserve original bytes")
        }
        XCTAssertEqual(original, future)
        XCTAssertEqual(names, ["file-v2"])
    }

    func testMixedBatchUsesOneUndoStepAndStableAnchor() async {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("after")]))
        let item = staged()
        engine.beginImageImport(at: NSRange(location: 6, length: 0))
        XCTAssertTrue(engine.performEdit(NSRange(location: 6, length: 0), with: NSAttributedString(string: "typed "), name: "Typing"))
        let beforeBatch = engine.textStorage.string
        XCTAssertTrue(engine.insertImportedObjects([NoteImportedObject(staged: item, pixelSize: nil)], acceptedText: "accepted"))
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertTrue(engine.textStorage.string.contains("accepted"))
        engine.history.undo()
        XCTAssertEqual(engine.textStorage.string, beforeBatch)
        XCTAssertTrue(engine.stagedAttachments(for: engine.document()).isEmpty)
    }

    func testCancelledBatchChangesNeitherDocumentNorStaging() async {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("body")]))
        let before = engine.document()
        engine.beginImageImport()
        engine.cancelImageImport()
        XCTAssertFalse(engine.insertImportedObjects([NoteImportedObject(staged: staged(), pixelSize: nil)]))
        XCTAssertEqual(engine.document(), before)
    }

    func testUnsupportedImageBytesUseFileCardAndFailureCardSurvivesRoundTrip() async throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T")]))
        engine.beginImageImport()
        XCTAssertTrue(engine.insertImportedObjects([NoteImportedObject(staged: staged("unreadable.heic"), pixelSize: nil),
            NoteImportedObject(filename: "oversize.pdf", contentTypeIdentifier: "com.adobe.pdf",
                byteCount: 16 * 1024 * 1024, failure: "Too large")]))
        let document = engine.document()
        XCTAssertEqual(document.blocks.filter { $0.kind == .file }.count, 2)
        XCTAssertNotNil(document.blocks.first { $0.filename == "oversize.pdf" }?.importFailure)
        guard case let .editable(decoded) = NoteContentCodec.decode(try NoteContentCodec.encode(document)) else {
            return XCTFail()
        }
        XCTAssertEqual(decoded, document)
    }

    func testReservedImageSpaceAndFractionSurviveColumnChange() async {
        let image = NoteImageAttachment(attachmentID: UUID(), preferredWidthFraction: 0.5,
            pixelSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(image.displaySize(columnWidth: 200), CGSize(width: 100, height: 50))
        XCTAssertEqual(image.displaySize(columnWidth: 600), CGSize(width: 200, height: 100),
            "an image never grows past its 2x natural width")
        XCTAssertEqual(image.preferredWidthFraction, 0.5)
        let file = NoteFileAttachment(attachmentID: UUID(), filename: "plan.pdf",
            contentTypeIdentifier: "com.adobe.pdf", byteCount: 1024)
        XCTAssertEqual(NoteFileAttachment.cardHeight, 54)
        XCTAssertTrue(file.accessibilityDescription.contains("plan.pdf"))
    }

    func testFailureStatesAndCommandValidation() async {
        let failed = NoteBlock.file(filename: "too-big.pdf", contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 16 * 1024 * 1024, importFailure: "Too large")
        let missing = NoteBlock.file(attachmentID: UUID(), filename: "lost.pdf",
            contentTypeIdentifier: "com.adobe.pdf", byteCount: 8)
        let item = staged()
        let ready = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), failed, missing, ready]),
            stagedAttachments: [item])
        let failedID = try! XCTUnwrap(failed.id)
        let missingID = try! XCTUnwrap(missing.id)
        let readyID = try! XCTUnwrap(ready.id)
        XCTAssertEqual(engine.objectState(failedID), .importFailed("Too large"))
        XCTAssertTrue(engine.validate(.retry, objectID: failedID).enabled)
        XCTAssertFalse(engine.validate(.exportCopy(nil), objectID: failedID).enabled)
        XCTAssertEqual(engine.objectState(missingID), .originalMissing)
        XCTAssertTrue(engine.validate(.locate, objectID: missingID).enabled)
        XCTAssertFalse(engine.validate(.quickLook, objectID: missingID).enabled)
        XCTAssertEqual(engine.objectState(readyID), .ready)
        XCTAssertTrue(engine.validate(.exportCopy(nil), objectID: readyID).enabled)
        XCTAssertFalse(engine.validate(.copyImage, objectID: readyID).enabled)
        XCTAssertTrue(engine.validate(.copyFile, objectID: readyID).enabled)
        engine.markPreviewUnavailable(readyID)
        XCTAssertEqual(engine.objectState(readyID), .previewUnavailable)
        XCTAssertTrue(engine.validate(.retryPreview, objectID: readyID).enabled)
        XCTAssertTrue(engine.validate(.quickLook, objectID: readyID).enabled)
        XCTAssertTrue(engine.validate(.exportCopy(nil), objectID: readyID).enabled)
        let retriedFile = await engine.perform(.retryPreview, objectID: readyID)
        XCTAssertTrue(retriedFile)
        XCTAssertEqual(engine.objectState(readyID), .ready)
        let imageItem = staged("preview.png")
        let imageBlock = NoteBlock.image(attachmentID: imageItem.id, pixelWidth: 10, pixelHeight: 10)
        let imageEngine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), imageBlock]),
            stagedAttachments: [imageItem])
        let image = imageEngine.objectPlacement(try! XCTUnwrap(imageBlock.id))?.0 as? NoteImageAttachment
        image?.isMissing = true
        XCTAssertEqual(imageEngine.objectState(imageBlock.id!), .previewUnavailable)
        XCTAssertTrue(imageEngine.validate(.quickLook, objectID: imageBlock.id!).enabled)
        XCTAssertTrue(imageEngine.validate(.retryPreview, objectID: imageBlock.id!).enabled)
        let didDelete = await engine.perform(.delete, objectID: readyID)
        XCTAssertTrue(didDelete)
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .file }.count, 2)
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .file }.count, 3)
    }

    func testDraggedImageFractionIsUndoableAndDoesNotBecomePoints() async throws {
        let item = try stagedImage()
        let image = NoteBlock.image(attachmentID: item.id, widthFraction: 1, pixelWidth: 800, pixelHeight: 400)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), image]),
            stagedAttachments: [item])
        let id = image.id!
        let didResize = await engine.perform(.size(0.42), objectID: id)
        XCTAssertTrue(didResize)
        XCTAssertEqual(engine.document().blocks.first { $0.id == id }?.widthFraction, 0.42)
        XCTAssertNil(engine.document().blocks.first { $0.id == id }?.width)
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks.first { $0.id == id }?.widthFraction, 1)
    }

    func testStoreDerivedCountsAndRecentlyDeletedRetention() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let file = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let original = NoteDocument(blocks: [.text(""), file])
        let noteID = UUID()
        guard case let .success((_, revision)) = store.createDocumentNote(id: noteID, document: original, staged: [item]) else {
            return XCTFail("create")
        }
        let replica = NoteItem(id: noteID, title: "stale")
        store.modelContext.insert(replica)
        try store.modelContext.save()
        guard case let .success(next) = store.saveDocument(noteID: noteID, document: original, baseRevisionID: revision) else {
            return XCTFail("converge")
        }
        let rows = try store.modelContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.fileCount == 1 && $0.imageCount == 0 && $0.firstFileName == "plan.pdf" })
        guard case let .success(removedRevision) = store.saveDocument(noteID: noteID,
            document: NoteDocument(blocks: [.text("")]), baseRevisionID: next) else { return XCTFail("delete") }
        XCTAssertTrue(store.recentlyDeletedAttachments().contains { $0.attachmentID == item.id })
        XCTAssertTrue(store.versions(noteID: noteID).contains { $0.attachmentIDs.contains(item.id) })
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0, "a version still refers to its bytes")
        guard case .success = store.saveDocument(noteID: noteID, document: original,
            baseRevisionID: removedRevision) else { return XCTFail("Undo save") }
        XCTAssertFalse(store.recentlyDeletedAttachments().contains { $0.attachmentID == item.id })
        XCTAssertEqual(store.loadDocument(noteID: noteID)?.content.document?.attachmentIDs, [item.id])
    }

    func testOversizedStoredBatchDoesNotChangeDocumentOrCreateRows() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let noteID = UUID()
        guard case let .success((_, revision)) = store.createDocumentNote(id: noteID,
            document: NoteDocument(blocks: [.text("Plan")])) else { return XCTFail("create") }
        let small = staged()
        let invalid = StagedNoteAttachment(id: small.id, filename: small.filename,
            contentTypeIdentifier: small.contentTypeIdentifier,
            byteCount: AttachmentLimits.maxBytesPerAttachment + 1, digest: small.digest, data: small.data)
        let updated = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: invalid.id,
            filename: invalid.filename, contentTypeIdentifier: invalid.contentTypeIdentifier,
            byteCount: invalid.byteCount)])
        let presented = try XCTUnwrap(store.note(withID: noteID))
        let originalContent = presented.content
        let originalVersionCount = store.versions(noteID: noteID).count
        guard case .failure(.invalidDocument) = store.saveDocument(noteID: noteID, document: updated,
            baseRevisionID: revision, staged: [invalid]) else { return XCTFail("must reject") }
        XCTAssertEqual(presented.content, originalContent, "rejection must not mutate the presented replica")
        XCTAssertEqual(presented.revisionID, revision)
        XCTAssertEqual(store.versions(noteID: noteID).count, originalVersionCount)
        XCTAssertEqual(store.loadDocument(noteID: noteID)?.content.document?.blocks, [.text("Plan")])
        XCTAssertTrue(try store.attachmentRows(forNoteID: noteID).isEmpty)
    }

    func testPrintViewHasObjectsAndMultiplePages() async throws {
        let item = staged()
        let image = try stagedImage()
        let file = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let long = String(repeating: "A long paragraph with content to paginate. ", count: 400)
        let document = NoteDocument(blocks: [.text("Report"), .checklist("Print checklist"),
            .image(attachmentID: image.id, widthFraction: 0.5, pixelWidth: 8, pixelHeight: 8), file, .text(long)])
        let thumbnail = try XCTUnwrap(NoteImageDecoder.thumbnail(of: image.data, maxPixel: 64))
        let view = NotePrint.printView(document: document, thumbnails: [image.id: thumbnail])
        XCTAssertGreaterThan(NotePrint.pageCount(for: view), 1)
        var foundFile = false
        var foundImage = false
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) {
            value, _, _ in
            if value is NoteFileAttachment { foundFile = true }
            if let picture = value as? NoteImageAttachment { foundImage = picture.renderedImage != nil }
        }
        XCTAssertTrue(foundFile)
        XCTAssertTrue(foundImage)
        XCTAssertEqual(view.appearance?.name, .aqua)
    }

    func testAgentTextPreservesFilesAndRejectsObjectLoss() async throws {
        let item = staged()
        let file = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let base = NoteDocument(blocks: [.text("Plan"), .text("old prose"), file])
        let body = NoteTextExport.agentBody(base)
        XCTAssertTrue(body.contains("attic://file/"))
        let changed = try NoteAgentTextParser.document(title: "Plan", body: body.replacingOccurrences(of: "old prose", with: "new prose"), base: base)
        XCTAssertEqual(changed.attachmentIDs, [item.id])
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Plan", body: "new prose", base: base))
    }

    func testAgentToolListsFilesAndKeepsThemThroughTextUpdate() async throws {
        let notes = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let tasks = try makeTestStore()
        let item = staged()
        let noteID = UUID()
        let document = NoteDocument(blocks: [.text("Plan"), .text("old prose"),
            .file(attachmentID: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = notes.createDocumentNote(id: noteID, document: document, staged: [item]) else {
            return XCTFail("create")
        }
        let tools = AgentTaskTools(store: tasks, noteStore: notes)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tools.call(name: "list_notes",
            arguments: [:]).utf8)) as? [String: Any])
        let row = try XCTUnwrap((listed["notes"] as? [[String: Any]])?.first)
        let files = try XCTUnwrap(row["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["name"] as? String, "plan.pdf")
        XCTAssertEqual(files.first?["byte_count"] as? Int, Int(item.byteCount))
        let body = try XCTUnwrap(row["body"] as? String)
        XCTAssertTrue(body.contains("attic://file/"))
        let revision = try XCTUnwrap(row["revision"] as? String)
        _ = try tools.call(name: "update_note", arguments: ["id": noteID.uuidString,
            "base_revision": revision, "body": body.replacingOccurrences(of: "old prose", with: "new prose\nextra paragraph")])
        XCTAssertEqual(notes.loadDocument(noteID: noteID)?.content.document?.attachmentIDs, [item.id])
        XCTAssertTrue(notes.loadDocument(noteID: noteID)?.content.document?.blocks.contains { $0.text == "extra paragraph" } == true)
        let updatedRevision = try XCTUnwrap(notes.note(withID: noteID)?.revisionToken)
        XCTAssertThrowsError(try tools.call(name: "update_note", arguments: ["id": noteID.uuidString,
            "base_revision": updatedRevision, "body": "new prose"]))
        XCTAssertEqual(notes.loadDocument(noteID: noteID)?.content.document?.attachmentIDs, [item.id])
    }

    func testStagedBatchRecoversAfterRestart() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let original = NoteDocument(blocks: [.text("Plan"), .text("body")])
        let noteID = UUID()
        guard case let .success((_, revision)) = store.createDocumentNote(id: noteID, document: original) else {
            return XCTFail("create")
        }
        let item = staged()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Attic3bJournal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NoteDraftJournal(directory: directory)
        var entry = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: revision,
            content: try NoteContentCodec.encode(original), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                           byteCount: item.byteCount, digest: item.digest)], savedAt: Date())
        entry.pendingImport = .init(anchor: 5, acceptedText: "accepted",
            items: [.init(filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                          byteCount: item.byteCount, stagedID: item.id, pixelWidth: nil, pixelHeight: nil,
                          failure: nil)], remainingNames: [])
        try await journal.writeDurably(entry, staged: [item])
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
        await restarted.startAndWait()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: noteID)?.content.document)
        XCTAssertEqual(recovered.blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(recovered.attachmentIDs, [item.id])
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
    }

    func testCancelledAndInterruptedStagingFilesAreCollected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Attic3bCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NoteDraftJournal(directory: directory)
        let noteID = UUID()
        let item = staged()
        func entry(_ items: [StagedNoteAttachment]) throws -> NoteDraftJournalEntry {
            NoteDraftJournalEntry(noteID: noteID, isPersisted: false, baseRevisionID: nil,
                content: try NoteContentCodec.encode(.blank), selectionLocation: 0, selectionLength: 0,
                staged: items.map { .init(id: $0.id, filename: $0.filename,
                    contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount,
                    digest: $0.digest) }, savedAt: Date())
        }
        let stagedFile = directory.appendingPathComponent("staged/\(item.id.uuidString)")
        let claim = try await journal.writeDurably(entry([item]), staged: [item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
        try await journal.discardOwnedDurably(noteID: noteID, claim: claim)
        _ = try await journal.writeDurably(entry([]), staged: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
        try item.data.write(to: stagedFile)
        _ = try await journal.readRecoveryEntries()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path), "restart removes a payload never journaled")
    }

    func testHideKeepsBatchAndDeletedNoteRejectsLateCompletion() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let original = NoteDocument(blocks: [.text("Plan"), .text("body")])
        let noteID = UUID()
        guard case .success = store.createDocumentNote(id: noteID, document: original) else { return XCTFail("create") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Attic3bHide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = staged("photo.png")
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600), imageLoader: { _ in
                try? await Task.sleep(for: .milliseconds(250))
                return (image, CGSize(width: 8, height: 8))
            })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: noteID))
        controller.importFiles([URL(fileURLWithPath: "/tmp/photo.png")])
        XCTAssertTrue(controller.active?.isImporting == true)
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        XCTAssertTrue(controller.active?.isImporting == true)
        await XCTAssertNotNilAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0.pendingImport)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: noteID))))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(store.note(withID: noteID))
        XCTAssertFalse(controller.active?.isImporting ?? true)
        XCTAssertFalse(controller.active?.engine.document().attachmentIDs.contains(image.id) ?? true)
    }

    func testR1AutosaveCannotRetirePendingBatchCheckpoint() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan"), .text("body")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NoteDraftJournal(directory: directory)
        let loader = TwoSourceLoader(first: try stagedImage(), second: try stagedImage())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
            imageLoader: { url in
                if url.lastPathComponent == "a.png" {
                    try? await MainActor.run {
                        XCTAssertEqual(try journal.entries().first?.0.pendingImport?.items.count, 0,
                            "the first source is durably checkpointed before loading")
                    }
                }
                return await loader.load(url)
            })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
            acceptedText: "accepted", at: NSRange(location: 5, length: 0))
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\ntyped"), name: "Typing"))
        await controller.runDueSave(session)
        await controller.waitForRecoveryWork()
        let checkpoint = try XCTUnwrap(journal.entries().first?.0)
        XCTAssertEqual(checkpoint.pendingImport?.items.count, 1)
        XCTAssertTrue(NoteTextExport.plainText(try XCTUnwrap(NoteContentCodec.decode(checkpoint.content).document)).contains("typed"))
        await XCTAssertTrueAsync(await controller.preserveAllDurably(), "background hide and quit include clean pending batches")
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
        XCTAssertEqual(recovered.blocks.filter { $0.kind == .image }.count, 1)
        await loader.release()
        await controller.waitForImportWork()
    }

    func testR1FailedCancellationKeepsPendingCheckpointAndBatch() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR1Cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OnDemandFailingJournal(NoteDraftJournal(directory: directory))
        let loader = TwoSourceLoader(first: try stagedImage(), second: try stagedImage())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
            imageLoader: { await loader.load($0) })
        await controller.startAndWait()
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        journal.failNextRemove = true
        controller.cancelActiveImport()
        await controller.waitForRecoveryWork()
        XCTAssertTrue(controller.active?.isImporting == true)
        XCTAssertNotNil(try journal.entries().first?.0.pendingImport)
        XCTAssertTrue(controller.active?.notice?.contains("could not be cancelled") == true)
        await loader.release()
        await controller.waitForImportWork()
    }

    func testR1CrashAndHideBeforeFirstSourceKeepUnfinishedMetadata() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan")])) else {
            return XCTFail()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR1First-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NoteDraftJournal(directory: directory)
        let loader = FirstSuspendedLoader(try stagedImage())
        let controller = NotesPageController(store: store, journal: journal, imageLoader: { await loader.load($0) })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        controller.importFiles([URL(fileURLWithPath: "/tmp/first.png")], acceptedText: "accepted",
            at: NSRange(location: 4, length: 0))
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide))
        let pending = try XCTUnwrap(journal.entries().first?.0.pendingImport)
        XCTAssertEqual(pending.remainingNames, ["first.png"])
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
        XCTAssertTrue(recovered.blocks.contains { $0.importFailure?.contains("interrupted") == true })
        await loader.release()
        await controller.waitForImportWork()
    }

    func testF1UnreadableCheckpointAndUnownedStagedBytesSurviveSaveCleanupAndRestart() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Stored")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticF1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedDirectory = directory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let checkpoint = directory.appendingPathComponent("\(id.uuidString).json")
        let unknown = Data("unrecovered unique work".utf8)
        let payload = stagedDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{damaged checkpoint".utf8).write(to: checkpoint)
        try unknown.write(to: payload)

        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\nnew text"), name: "Typing"))
        XCTAssertTrue(controller.save(session), "a damaged old checkpoint must not block an ordinary note save")
        XCTAssertTrue(NoteTextExport.plainText(try XCTUnwrap(store.loadDocument(noteID: id)?.content.document))
            .contains("new text"))
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data("{damaged checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: payload), unknown)
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await restarted.startAndWait()
        XCTAssertFalse(restarted.recoveryWarnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data("{damaged checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: payload), unknown)
    }

    /// Recovery-ownership invariant: every public journal operation, given
    /// damaged or foreign checkpoint state, keeps that state and every byte
    /// it may own, and never blocks an ordinary note save.
    func testRecoveryOwnershipInvariantEveryOperationKeepsUnknownStateAndBytes() async throws {
        enum Kind: CaseIterable { case malformedEnvelope, unreadableContent, damagedStagedBytes, foreignValid, foreignPending }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // A claim the caller holds for some other checkpoint.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AtticForeignClaim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let foreignClaim = try await NoteDraftJournal(directory: scratch).writeDurably(NoteDraftJournalEntry(noteID: UUID(),
            isPersisted: false, baseRevisionID: nil, content: try NoteContentCodec.encode(.blank),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        for kind in Kind.allCases {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID(), item = staged()
            let stored = NoteDocument(blocks: [.text("Stored")])
            guard case .success = store.createDocumentNote(id: id, document: stored) else { return XCTFail("fixture") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOwnership-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let stagedDirectory = directory.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
            let checkpoint = directory.appendingPathComponent("\(id.uuidString).json")
            let payload = stagedDirectory.appendingPathComponent(item.id.uuidString)
            var entry = NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: nil,
                content: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Other draft")])),
                selectionLocation: 0, selectionLength: 0,
                staged: [.init(id: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                               byteCount: item.byteCount, digest: item.digest)], savedAt: Date())
            var bytes = item.data
            switch kind {
            case .malformedEnvelope:
                try Data("{damaged".utf8).write(to: checkpoint)
            case .unreadableContent:
                entry.content = Data("unreadable note content".utf8)
                try encoder.encode(entry).write(to: checkpoint)
            case .damagedStagedBytes:
                bytes = Data("changed bytes".utf8)
                try encoder.encode(entry).write(to: checkpoint)
            case .foreignValid:
                try encoder.encode(entry).write(to: checkpoint)
            case .foreignPending:
                entry.pendingImport = .init(anchor: 0, acceptedText: "", items: [.init(filename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount, stagedID: item.id,
                    pixelWidth: nil, pixelHeight: nil, failure: nil)], remainingNames: ["later.pdf"])
                try encoder.encode(entry).write(to: checkpoint)
            }
            try bytes.write(to: payload)
            let original = try Data(contentsOf: checkpoint)
            func assertKept(_ step: String) {
                XCTAssertEqual(try? Data(contentsOf: checkpoint), original, "\(kind) checkpoint after \(step)")
                XCTAssertEqual(try? Data(contentsOf: payload), bytes, "\(kind) staged bytes after \(step)")
            }
            let journal = NoteDraftJournal(directory: directory)
            let replacement = NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: nil,
                content: try NoteContentCodec.encode(stored), selectionLocation: 0, selectionLength: 0,
                staged: [], savedAt: Date())
            await XCTAssertThrowsErrorAsync(try await journal.writeDurably(replacement, staged: []), "\(kind) write")
            assertKept("write")
            await XCTAssertThrowsErrorAsync(try await journal.writeDurably(replacement, staged: [], replacing: foreignClaim), "\(kind) write with a foreign claim")
            assertKept("write with a foreign claim")
            await XCTAssertThrowsErrorAsync(try await journal.retireDurably(noteID: id, claim: nil, saved: { nil }), "\(kind) retire")
            assertKept("retire")
            await XCTAssertThrowsErrorAsync(try await journal.retireDurably(noteID: id, claim: foreignClaim,
                saved: { .init(document: stored, tags: []) }), "\(kind) retire against a different saved note")
            assertKept("retire against a different saved note")
            let recovered = try await journal.readRecoveryEntries()
            XCTAssertEqual(recovered.count, 1, "\(kind) startup still lists it")
            assertKept("recovery enumeration")
            // Staged-byte collection runs after another note's write and retire.
            let unrelatedID = UUID()
            let unrelatedClaim = try await journal.writeDurably(NoteDraftJournalEntry(noteID: unrelatedID, isPersisted: false,
                baseRevisionID: nil, content: try NoteContentCodec.encode(.blank), selectionLocation: 0,
                selectionLength: 0, staged: [], savedAt: Date()), staged: [])
            try await journal.discardOwnedDurably(noteID: unrelatedID, claim: unrelatedClaim)
            assertKept("collection")
            // An ordinary save of the stored note still succeeds. Damaged
            // state is never adopted; foreign state is exercised with the
            // store directly so launch recovery does not claim it.
            if kind != .foreignValid && kind != .foreignPending {
                let controller = NotesPageController(store: store, journal: journal)
                await controller.startAndWait()
                await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
                let session = try XCTUnwrap(controller.active)
                XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                    with: NSAttributedString(string: "\nordinary save"), name: "Typing"))
                XCTAssertTrue(controller.save(session), "\(kind) ordinary save")
                assertKept("ordinary save")
                await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id) == false, "\(kind) delete keeps the note while its copy is unknown")
                assertKept("delete")
            } else {
                let base = try XCTUnwrap(store.note(withID: id)?.revisionID)
                guard case .success = store.saveDocument(noteID: id,
                    document: NoteDocument(blocks: [.text("Stored"), .text("ordinary save")]), baseRevisionID: base) else {
                    return XCTFail("\(kind) ordinary save")
                }
                assertKept("ordinary save")
            }
        }
    }

    func testStepBackDamagedCheckpointSurvivesImportCheckpoint() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Stored")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticImportOwnership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("staged"),
            withIntermediateDirectories: true)
        let checkpoint = directory.appendingPathComponent("\(id.uuidString).json")
        let payload = directory.appendingPathComponent("staged/\(UUID().uuidString)")
        let unique = Data("unrecovered file".utf8)
        try Data("{damaged".utf8).write(to: checkpoint)
        try unique.write(to: payload)
        let loader = FirstSuspendedLoader(try stagedImage())
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            imageLoader: { await loader.load($0) })
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        controller.importFiles([URL(fileURLWithPath: "/tmp/stepback.png")])
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data("{damaged".utf8))
        XCTAssertEqual(try Data(contentsOf: payload), unique)
        for _ in 0..<100 {
            if await loader.started { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let didStart = await loader.started
        XCTAssertTrue(didStart)
        await loader.release()
        await controller.waitForImportWork()
        try await waitFor { controller.active?.isImporting == false }
        let restarted = NoteDraftJournal(directory: directory)
        await XCTAssertEqualAsync(try await restarted.readRecoveryEntries().count, 1)
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data("{damaged".utf8))
        XCTAssertEqual(try Data(contentsOf: payload), unique)
    }

    func testStepBackReadableEnvelopeWithUnreadableContentSurvivesOrdinarySave() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID(), item = staged()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Stored")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticUnreadableContent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("staged"),
            withIntermediateDirectories: true)
        let checkpoint = directory.appendingPathComponent("\(id.uuidString).json")
        let payload = directory.appendingPathComponent("staged/\(item.id.uuidString)")
        let entry = NoteDraftJournalEntry(noteID: id, isPersisted: true, baseRevisionID: nil,
            content: Data("unreadable note content".utf8), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                digest: item.digest)], savedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelope = try encoder.encode(entry)
        try envelope.write(to: checkpoint)
        try item.data.write(to: payload)
        let journal = NoteDraftJournal(directory: directory)
        await XCTAssertThrowsErrorAsync(try await journal.retireDurably(noteID: id, claim: nil,
            saved: { .init(document: NoteDocument(blocks: [.text("Stored")]), tags: []) }))
        let controller = NotesPageController(store: store, journal: journal)
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\nsaved"), name: "Typing"))
        XCTAssertTrue(controller.save(session))
        XCTAssertEqual(try Data(contentsOf: checkpoint), envelope)
        XCTAssertEqual(try Data(contentsOf: payload), item.data)
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).readRecoveryEntries().count, 1)
    }

    func testR2RecoveryCopyIncludesPendingAcceptedTextBytesAndUnfinishedSource() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OnDemandFailingJournal(NoteDraftJournal(directory: directory))
        let first = try stagedImage()
        let loader = TwoSourceLoader(first: first, second: try stagedImage())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
            imageLoader: { await loader.load($0) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "Draft"), name: "Typing"))
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
            acceptedText: "accepted", at: NSRange(location: 5, length: 0))
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " changed"), name: "Typing"))
        journal.failNextWrite = true
        await XCTAssertFalseAsync(await controller.preserveAllDurably())
        let destination = directory.appendingPathComponent("export")
        controller.recoveryCopyDestination = { _ in destination }
        let copied = await controller.saveRecoveryCopy(of: session)
        XCTAssertTrue(copied)
        let manifestData = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NoteRecoveryCopy.Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.pendingImport?.acceptedText, "accepted")
        XCTAssertEqual(manifest.pendingImport?.remainingNames, ["b.png"])
        XCTAssertNotNil(manifest.pendingImport?.items.first?.stagedID)
        let exported = try XCTUnwrap(manifest.images.first)
        XCTAssertEqual(exported.digest, first.digest)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(exported.file)), first.data)
        XCTAssertTrue(String(decoding: try Data(contentsOf: destination.appendingPathComponent("note.json")),
            as: UTF8.self).contains("Draft"))
        await loader.release()
        await controller.waitForImportWork()
    }

    func testR3RecentlyDeletedRestoresInlinePlacementAcrossSaveAndLibraryHistory() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let original = NoteDocument(blocks: [.text("Plan"), .text("before"),
            .file(attachmentID: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount), .text("after")])
        guard case let .success((_, revision)) = store.createDocumentNote(id: id, document: original, staged: [item]) else {
            return XCTFail("fixture")
        }
        var removed = original
        removed.blocks.remove(at: 2)
        guard case .success = store.saveDocument(noteID: id, document: removed, baseRevisionID: revision) else {
            return XCTFail("delete")
        }
        let library = AtticLibrary(tasks: try makeTestStore(), notes: store)
        let summary = try XCTUnwrap(library.recentlyDeletedAttachments().first { $0.attachmentID == item.id })
        XCTAssertTrue(library.restoreAttachment(summary))
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks[2].attachmentID, item.id)
        var edited = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        edited.blocks.append(.text("later edit"))
        guard case .success = store.saveDocument(noteID: id, document: edited,
            baseRevisionID: store.loadDocument(noteID: id)?.revisionID) else { return XCTFail("edit after restore") }
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertFalse(store.loadDocument(noteID: id)?.content.document?.attachmentIDs.contains(item.id) ?? true)
        XCTAssertTrue(library.undo.redo(in: .library))
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.attachmentIDs, [item.id])
    }

    func testR4UndoAndRecoveryResolveRetainedBytesAndVersionRefreshesPresentation() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) },
            attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let original = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: original, staged: [item]) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let objectID = try XCTUnwrap(original.blocks[1].id)
        let deleted = await session.engine.perform(.delete, objectID: objectID)
        XCTAssertTrue(deleted)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertTrue(session.engine.history.undo())
        XCTAssertEqual(session.engine.objectState(objectID), .ready)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveAllDurably(), "the failed Undo save is checkpointed")
        let destination = directory.appendingPathComponent("recovery")
        controller.recoveryCopyDestination = { _ in destination }
        let copied = await controller.saveRecoveryCopy(of: session)
        XCTAssertTrue(copied)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NoteRecoveryCopy.Manifest.self,
            from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.files?.first?.id, item.id)
        gate.shouldFail = false
        let version = try XCTUnwrap(store.versions(noteID: id).first { $0.attachmentIDs.contains(item.id) })
        guard case .success = store.restoreVersion(version.id, noteID: id) else { return XCTFail("restore") }
        XCTAssertEqual(store.attachments(for: id).map(\.id), [item.id])
    }

    func testR4VerifiedMaterializationRemainsAvailableWithoutRowPayload() async throws {
        let fileStore = makeTestAttachmentFileStore()
        let store = try makeTestNoteStore(attachmentFileStore: fileStore)
        let item = staged()
        let id = UUID()
        let doc = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: [item]) else { return XCTFail() }
        let row = try XCTUnwrap(store.attachmentRows(forNoteID: id).first)
        _ = await store.materializedURL(for: row)
        row.payload = nil
        try store.modelContext.save()
        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertTrue(controller.hasAttachmentBytes(item.id))
        let retainedURL = await controller.fileURL(forAttachment: item.id)
        XCTAssertNotNil(retainedURL)
    }

    func testR5PurgeKeepsLiveUndoBytesAfterVersionsExpireUntilHistoryIsReleased() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let store = try makeTestNoteStore(now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let doc = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: [item]) else { return XCTFail() }
        let controller = NotesPageController(store: store, journal: nil, now: { clock.value })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let deleted = await session.engine.perform(.delete, objectID: try XCTUnwrap(doc.blocks[1].id))
        XCTAssertTrue(deleted)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        clock.value += 31 * 86_400
        store.thinVersions(noteID: id)
        XCTAssertEqual(store.purgeRemovedAttachments(before: clock.value.addingTimeInterval(1)), 0)
        session.engine.history.reset()
        store.thinVersions(noteID: id)
        XCTAssertEqual(store.purgeRemovedAttachments(before: clock.value.addingTimeInterval(1)), 1)
    }

    func testR6AllEntryPointsRejectAtCountLimitBeforeReading() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let items = (0..<AttachmentLimits.maxAttachmentsPerNote).map { staged("\($0).pdf") }
        let id = UUID()
        let doc = NoteDocument(blocks: [.text("Plan")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename,
                contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        } + [.file(filename: "retry.pdf", contentTypeIdentifier: "com.adobe.pdf",
                   byteCount: 0, importFailure: "Failed")])
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: items) else { return XCTFail() }
        let reads = ReadCounter()
        let controller = NotesPageController(store: store, journal: nil, imageLoader: { await reads.read($0) })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let source = URL(fileURLWithPath: "/tmp/AtticR6-\(UUID().uuidString).png")
        controller.importFiles([source])
        try await waitFor { controller.active?.isImporting == false }
        let afterPaste = await reads.count
        XCTAssertEqual(afterPaste, 0)
        XCTAssertEqual(controller.active?.engine.document().blocks.filter { $0.importFailure != nil }.count, 2)
        controller.importSlashImage(source)
        let afterSlash = await reads.count
        XCTAssertEqual(afterSlash, 0)
        let retryID = try XCTUnwrap(doc.blocks.last?.id)
        let retryResult = await controller.retryFailedFile(retryID, with: source)
        XCTAssertFalse(retryResult)
        let afterRetry = await reads.count
        XCTAssertEqual(afterRetry, 0)
        XCTAssertFalse(try XCTUnwrap(controller.active).engine.replaceFailedFile(retryID,
            with: NoteImportedObject(staged: staged("replacement.pdf"), pixelSize: nil)))
        XCTAssertEqual(controller.active?.engine.objectState(retryID), .importFailed("Failed"))
    }

    func testR6AggregateLimitUsesLogicalDraftAndRetainedIDsWithoutStaging() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let items = (0..<7).map { staged("\($0).pdf") }
        let id = UUID()
        let doc = NoteDocument(blocks: [.text("Plan")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename,
                contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        } + [.file(filename: "retry.pdf", contentTypeIdentifier: "com.adobe.pdf",
                   byteCount: 0, importFailure: "Failed")])
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: items) else { return XCTFail() }
        for row in try store.attachmentRows(forNoteID: id) { row.byteCount = 14 * 1024 * 1024 }
        try store.modelContext.save()
        let reads = ReadCounter()
        let controller = NotesPageController(store: store, journal: nil,
            imageLoader: { await reads.read($0) })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let candidate = StagedNoteAttachment(id: UUID(), filename: "next.pdf", contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 3 * 1024 * 1024, digest: "", data: Data())
        XCTAssertNotNil(controller.importAdmissionFailure(candidate, in: try XCTUnwrap(controller.active)))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR6-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 3 * 1024 * 1024)
        try handle.close()
        XCTAssertNotNil(controller.sourceAdmissionFailure(source, in: try XCTUnwrap(controller.active)).1)
        controller.importFiles([source])
        try await waitFor { controller.active?.isImporting == false }
        controller.importSlashImage(source)
        let retryID = try XCTUnwrap(doc.blocks.last?.id)
        let retried = await controller.retryFailedFile(retryID, with: source)
        XCTAssertFalse(retried)
        let readCount = await reads.count
        XCTAssertEqual(readCount, 0, "no source is read after metadata rejects it")

        // A retained row can re-enter with no new staged payload. Final
        // document validation must still enforce limits.
        let extra = NoteAttachment(id: UUID(), noteID: id, originalFilename: "retained.pdf",
            byteCount: 3 * 1024 * 1024, sortIndex: 30,
            contentDigest: String(repeating: "a", count: 64), payload: nil)
        extra.deletedAt = Date()
        store.modelContext.insert(extra)
        try store.modelContext.save()
        var proposed = doc
        proposed.blocks.append(.file(attachmentID: extra.id, filename: extra.originalFilename,
            contentTypeIdentifier: extra.contentTypeIdentifier, byteCount: extra.byteCount))
        guard case .failure(.invalidDocument) = store.saveDocument(noteID: id, document: proposed,
            baseRevisionID: store.loadDocument(noteID: id)?.revisionID, staged: []) else {
            return XCTFail("retained-ID reinsertion must be checked with no staging")
        }
    }

    func testR6DeletingAnObjectDuringLoadingRevalidatesDraftCapacity() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let items = (0..<19).map { staged("\($0).pdf") }
        let doc = NoteDocument(blocks: [.text("Plan")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename,
                contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        })
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: items) else { return XCTFail() }
        let loader = FirstSuspendedLoader(try stagedImage())
        let controller = NotesPageController(store: store, journal: nil, imageLoader: { await loader.load($0) })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        controller.importFiles([URL(fileURLWithPath: "/tmp/new.png")])
        for _ in 0..<100 {
            if await loader.started { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let didStart = await loader.started
        XCTAssertTrue(didStart)
        let deleted = await session.engine.perform(.delete, objectID: try XCTUnwrap(doc.blocks[1].id))
        XCTAssertTrue(deleted)
        await loader.release()
        await controller.waitForImportWork()
        try await waitFor { session.isImporting == false }
        XCTAssertEqual(session.engine.document().attachmentIDs.count, 19)
        XCTAssertEqual(session.engine.document().blocks.filter { $0.kind == .image }.count, 1)
    }

    func testF4MissingOriginalSurvivesTextAndFormatSaveButInventedReferenceIsRejected() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let original = NoteDocument(blocks: [.text("Plan"), .text("body"),
            .file(attachmentID: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount),
            .file(attachmentID: item.id, filename: "Alias.pdf",
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: original, staged: [item]) else {
            return XCTFail("fixture")
        }
        for row in try store.attachmentRows(forNoteID: id) { store.modelContext.delete(row) }
        try store.modelContext.save()
        store.refresh()

        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let body = (session.engine.textStorage.string as NSString).range(of: "body")
        XCTAssertTrue(session.engine.performEdit(body, with: NSAttributedString(string: "revised"), name: "Typing"))
        XCTAssertTrue(session.engine.perform(.paragraph(.heading(2)),
            selection: NSRange(location: body.location, length: 7)))
        XCTAssertTrue(controller.save(session), "existing missing bytes must not make text saves impossible")

        let reopened = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await reopened.openDurably(noteID: id))
        let saved = try XCTUnwrap(reopened.active?.engine.document())
        XCTAssertEqual(saved.blocks[1].text, "revised")
        XCTAssertEqual(saved.blocks[1].style, "heading")
        XCTAssertEqual(saved.blocks.last?.attachmentID, item.id)
        XCTAssertEqual(saved.blocks.filter { $0.kind == .file }.map(\.filename), [item.filename, "Alias.pdf"])
        var invented = saved
        invented.blocks.append(.file(attachmentID: UUID(), filename: "invented.pdf",
            contentTypeIdentifier: "com.adobe.pdf", byteCount: 3))
        guard case .failure(.invalidDocument) = store.saveDocument(noteID: id, document: invented,
            baseRevisionID: store.loadDocument(noteID: id)?.revisionID, staged: []) else {
            return XCTFail("a new ID without bytes must still be refused")
        }
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, saved)
    }

    func testR7CapturedPasteRangeAndDropBoundarySurviveTypingAndUndo() async {
        let item = staged()
        let paste = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("hello world"), .text("next")]))
        let selected = (paste.textStorage.string as NSString).range(of: "world")
        paste.beginImageImport(at: selected)
        XCTAssertTrue(paste.insertImportedObjects([NoteImportedObject(staged: item, pixelSize: nil)],
            acceptedText: "there"))
        XCTAssertTrue(paste.textStorage.string.contains("hello there"))
        XCTAssertFalse(paste.textStorage.string.contains("world"))
        XCTAssertEqual(paste.document().blocks.firstIndex { $0.kind == .file }, 2)

        let drop = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("first"), .text("second")]))
        let boundary = (drop.textStorage.string as NSString).range(of: "second").location
        drop.beginImageImport(at: NSRange(location: boundary, length: 0))
        XCTAssertTrue(drop.performEdit(NSRange(location: 6, length: 0),
            with: NSAttributedString(string: "typed "), name: "Typing"))
        XCTAssertTrue(drop.history.undo())
        XCTAssertTrue(drop.insertImportedObjects([NoteImportedObject(staged: staged("drop.pdf"), pixelSize: nil)]))
        XCTAssertEqual(drop.document().blocks.map(\.kind), [.text, .text, .file, .text])
        XCTAssertEqual(drop.document().blocks.last?.text, "second")
    }

    func testF2SpanningEditAndWritingToolsRollbackKeepPendingBoundaryNonDestructive() async throws {
        let item = staged()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("abcdefghi"), .checklist("Keep")]))
        let body = (engine.textStorage.string as NSString).range(of: "abcdefghi")
        let boundary = body.location + 4
        engine.beginImageImport(at: NSRange(location: boundary, length: 0))
        XCTAssertTrue(engine.performEdit(NSRange(location: body.location + 1, length: 5),
            with: NSAttributedString(string: "XY"), name: "Replace"))
        XCTAssertEqual(engine.currentImportTarget?.replacementLength, 0)
        XCTAssertEqual(engine.currentImportTarget?.anchor, body.location + 3,
            "trailing affinity puts the boundary after XY")
        let beforeImport = engine.document()
        XCTAssertTrue(engine.insertImportedObjects([NoteImportedObject(staged: item, pixelSize: nil)]))
        let afterImport = engine.document()
        XCTAssertTrue(afterImport.blocks.filter { $0.kind == .text }.map(\.text).joined().contains("aXYghi"))
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document(), beforeImport)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document(), afterImport)

        let protected = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("body"), .checklist("Protected")]))
        let target = (protected.textStorage.string as NSString).range(of: "body").location + 2
        protected.beginImageImport(at: NSRange(location: target, length: 0))
        let original = protected.document()
        let originalTarget = try XCTUnwrap(protected.currentImportTarget)
        protected.onWritingToolsWillBegin = { false }
        protected.writingToolsWillBegin()
        protected.textStorage.replaceCharacters(in: NSRange(location: 0, length: protected.textStorage.length),
            with: NSAttributedString(string: "unapproved rewrite"))
        protected.writingToolsDidEnd()
        XCTAssertEqual(protected.document(), original)
        XCTAssertEqual(protected.currentImportTarget?.anchor, originalTarget.anchor)
        XCTAssertEqual(protected.currentImportTarget?.replacementLength, 0)
        XCTAssertTrue(protected.insertImportedObjects([NoteImportedObject(staged: staged("next.pdf"), pixelSize: nil)]))
        XCTAssertTrue(protected.document().blocks.contains { $0.kind == .checklist && $0.text == "Protected" })
        XCTAssertTrue(protected.document().blocks.filter { $0.kind == .text }.map(\.text).joined().contains("body"))
        XCTAssertTrue(protected.history.undo())
        XCTAssertEqual(protected.document(), original)
    }

    func testR8SelectedImageCopyPublishesPasteableFragmentAndRawImagePasteUsesBatch() async throws {
        let image = try stagedImage()
        let block = NoteBlock.image(attachmentID: image.id, pixelWidth: 8, pixelHeight: 8)
        let source = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Source"), block]),
            stagedAttachments: [image])
        let copied = await source.perform(.copyImage, objectID: try XCTUnwrap(block.id))
        XCTAssertTrue(copied)
        let board = NSPasteboard.general
        let fragment = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        XCTAssertEqual(board.data(forType: .png), image.data)
        XCTAssertTrue(source.paste(fragmentData: fragment,
            at: NSRange(location: source.textStorage.length, length: 0)))
        XCTAssertEqual(source.document().blocks.filter { $0.kind == .image }.count, 2)
        XCTAssertEqual(Set(source.document().attachmentIDs), Set([image.id]))

        let provider = StoredImageProvider(image)
        let destination = NoteEditorEngine(noteID: UUID(), document: .blank, imageProvider: provider)
        XCTAssertTrue(destination.paste(fragmentData: fragment, at: NSRange(location: 0, length: 0)))
        XCTAssertEqual(destination.document().blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertNotEqual(destination.document().attachmentIDs.first, image.id)

        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil)
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        let (_, view) = session.engine.makeView()
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let raw = NSPasteboard(name: NSPasteboard.Name("AtticRawR8-\(UUID().uuidString)"))
            raw.clearContents()
            let bytes: Data
            if type == .png { bytes = image.data }
            else {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.data))
                bytes = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
            }
            XCTAssertTrue(raw.setData(bytes, forType: type))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            XCTAssertTrue(view.readSelection(from: raw, type: type))
            let expected = type == .png ? 1 : 2
            try await waitFor { session.engine.document().blocks.filter { $0.kind == .image }.count == expected }
        }
    }

    func testF3PrivateMultiObjectFragmentChecksCountBeforeStorageStagingOrUndo() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let sourceFiles = (0..<2).map { staged("source-\($0).pdf") }
        let destinationFiles = (0..<AttachmentLimits.maxAttachmentsPerNote).map { staged("dest-\($0).pdf") }
        func document(_ title: String, _ items: [StagedNoteAttachment]) -> NoteDocument {
            NoteDocument(blocks: [.text(title)] + items.map {
                .file(attachmentID: $0.id, filename: $0.filename,
                    contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
            })
        }
        let sourceID = UUID(), destinationID = UUID()
        guard case .success = store.createDocumentNote(id: sourceID,
            document: document("Source", sourceFiles), staged: sourceFiles),
              case .success = store.createDocumentNote(id: destinationID,
            document: document("Destination", destinationFiles), staged: destinationFiles) else {
            return XCTFail("fixtures")
        }
        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: sourceID))
        let source = try XCTUnwrap(controller.active)
        let board = NSPasteboard(name: NSPasteboard.Name("AtticF3-\(UUID().uuidString)"))
        XCTAssertTrue(source.engine.writeSelection(NSRange(location: 0, length: source.engine.textStorage.length),
            to: board, types: [NoteEditorEngine.fragmentType]))
        let fragment = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: destinationID))
        let engine = try XCTUnwrap(controller.active?.engine)
        let beforeText = NSAttributedString(attributedString: engine.textStorage)
        let beforeStaged = engine.staged
        let beforeUndo = engine.history.undoOps.count
        XCTAssertFalse(engine.paste(fragmentData: fragment,
            at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertTrue(engine.textStorage.isEqual(to: beforeText))
        XCTAssertEqual(engine.staged, beforeStaged)
        XCTAssertEqual(engine.history.undoOps.count, beforeUndo)

        var objects: [NSRange] = []
        engine.textStorage.enumerateAttribute(.attachment,
            in: NSRange(location: 0, length: engine.textStorage.length)) { value, range, _ in
                if value is NoteFileAttachment { objects.append(range) }
            }
        let first = try XCTUnwrap(objects.first), second = objects[1]
        let replacement = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
        XCTAssertTrue(engine.paste(fragmentData: fragment, at: replacement),
            "the selected objects free logical attachment capacity")
        XCTAssertEqual(Set(engine.document().attachmentIDs).count, AttachmentLimits.maxAttachmentsPerNote)
        XCTAssertEqual(engine.history.undoOps.count, beforeUndo + 1)
        XCTAssertTrue(controller.save(try XCTUnwrap(controller.active)))
        XCTAssertEqual(Set(try XCTUnwrap(store.loadDocument(noteID: destinationID)?.content.document).attachmentIDs).count,
            AttachmentLimits.maxAttachmentsPerNote)
    }

    func testF3PrivateFragmentChecksAggregateBytesBeforeStorageOrUndo() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let sourceFiles = (0..<2).map { stagedSized("source-\($0).pdf", bytes: 2 * 1024 * 1024) }
        let destinationFiles = (0..<7).map { stagedSized("dest-\($0).pdf", bytes: 14 * 1024 * 1024) }
        func document(_ title: String, _ items: [StagedNoteAttachment]) -> NoteDocument {
            NoteDocument(blocks: [.text(title)] + items.map {
                .file(attachmentID: $0.id, filename: $0.filename,
                    contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
            })
        }
        let sourceID = UUID(), destinationID = UUID()
        guard case .success = store.createDocumentNote(id: sourceID,
            document: document("Source", sourceFiles), staged: sourceFiles),
              case .success = store.createDocumentNote(id: destinationID,
            document: document("Destination", destinationFiles), staged: destinationFiles) else {
            return XCTFail("fixtures")
        }
        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: sourceID))
        let source = try XCTUnwrap(controller.active)
        let board = NSPasteboard(name: NSPasteboard.Name("AtticF3Bytes-\(UUID().uuidString)"))
        XCTAssertTrue(source.engine.writeSelection(NSRange(location: 0, length: source.engine.textStorage.length),
            to: board, types: [NoteEditorEngine.fragmentType]))
        let fragment = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: destinationID))
        let engine = try XCTUnwrap(controller.active?.engine)
        let before = engine.document(), stagedBefore = engine.staged
        let undoBefore = engine.history.undoOps.count
        XCTAssertFalse(engine.paste(fragmentData: fragment,
            at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertEqual(engine.document(), before)
        XCTAssertEqual(engine.staged, stagedBefore)
        XCTAssertEqual(engine.history.undoOps.count, undoBefore)
    }

    func testStepBackSameNoteCopyOfMissingOriginalIsRejectedBeforeUndo() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let document = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: document, staged: [item]) else {
            return XCTFail("fixture")
        }
        for row in try store.attachmentRows(forNoteID: id) { store.modelContext.delete(row) }
        try store.modelContext.save()
        store.refresh()
        let controller = NotesPageController(store: store, journal: nil)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let engine = session.engine
        let board = NSPasteboard(name: NSPasteboard.Name("AtticMissingCopy-\(UUID().uuidString)"))
        let object = try XCTUnwrap(engine.objectPlacement(try XCTUnwrap(document.blocks[1].id)))
        XCTAssertTrue(engine.writeSelection(object.1, to: board, types: [NoteEditorEngine.fragmentType]))
        let fragment = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        let before = NSAttributedString(attributedString: engine.textStorage)
        let beforeStaged = engine.staged
        let undoCount = engine.history.undoOps.count
        XCTAssertFalse(engine.paste(fragmentData: fragment,
            at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertTrue(engine.textStorage.isEqual(to: before))
        XCTAssertEqual(engine.staged, beforeStaged)
        XCTAssertEqual(engine.history.undoOps.count, undoCount)
        XCTAssertTrue(engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\nprose"), name: "Typing"))
        XCTAssertTrue(controller.save(session), "a rejected paste must not make ordinary saves fail")
    }

    func testStepBackAdmissionMatchesFinalSaveForEveryCandidateKind() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged()
        let id = UUID()
        let original = NoteDocument(blocks: [.text("Plan"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: original, staged: [item]) else {
            return XCTFail("fixture")
        }
        for row in try store.attachmentRows(forNoteID: id) { store.modelContext.delete(row) }
        try store.modelContext.save()
        store.refresh()
        var prose = original
        prose.blocks.append(.text("safe edit"))
        var duplicateMissing = original
        duplicateMissing.blocks.append(.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount))
        var invented = original
        invented.blocks.append(.file(attachmentID: UUID(), filename: "invented.pdf",
            contentTypeIdentifier: "com.adobe.pdf", byteCount: 3))
        for (candidate, admitted) in [(prose, true), (duplicateMissing, false), (invented, false)] {
            XCTAssertEqual(store.attachmentAdmissionFailure(noteID: id, document: candidate, staged: []) == nil,
                admitted)
            let save = store.saveDocument(noteID: id, document: candidate,
                baseRevisionID: store.loadDocument(noteID: id)?.revisionID, staged: [])
            if admitted {
                guard case .success = save else { return XCTFail("admitted candidate must save") }
            } else {
                guard case .failure(.invalidDocument) = save else { return XCTFail("rejected candidate must not save") }
            }
        }
    }

    /// Admission invariant: the pre-edit gate and the final save agree on
    /// every candidate kind, a missing original or divergent file replicas
    /// never block an ordinary save, and a refusal deletes no bytes.
    func testAdmissionInvariantPreEditGateAgreesWithSaveAndKeepsBytes() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let missing = staged("missing.pdf"), split = staged("split.pdf"), present = staged("present.pdf")
        func block(_ item: StagedNoteAttachment) -> NoteBlock {
            .file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                  byteCount: item.byteCount)
        }
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan"),
            block(missing), block(split), block(present)]), staged: [missing, split, present]) else {
            return XCTFail("fixture")
        }
        // Unknown store state: one original lost, one file with divergent replicas.
        for row in try store.attachmentRows(forNoteID: id) where row.id == missing.id { store.modelContext.delete(row) }
        let other = Data("other bytes".utf8)
        store.modelContext.insert(NoteAttachment(id: split.id, noteID: id, originalFilename: split.filename,
            contentTypeIdentifier: split.contentTypeIdentifier, byteCount: Int64(other.count), sortIndex: 7,
            contentDigest: SHA256.hash(data: other).map { String(format: "%02x", $0) }.joined(), payload: other))
        try store.modelContext.save()
        store.refresh()
        func payloads() throws -> [Data?] {
            try store.attachmentRows(forNoteID: id).filter { $0.id != missing.id }
                .sorted { ($0.id.uuidString, $0.sortIndex) < ($1.id.uuidString, $1.sortIndex) }.map(\.payload)
        }
        let added = staged("added.pdf")
        var damaged = staged("damaged.pdf")
        damaged = StagedNoteAttachment(id: damaged.id, filename: damaged.filename,
            contentTypeIdentifier: damaged.contentTypeIdentifier, byteCount: damaged.byteCount,
            digest: String(repeating: "0", count: 64), data: damaged.data)
        let cases: [(String, (NoteDocument) -> NoteDocument, [StagedNoteAttachment], Bool)] = [
            ("prose", { var d = $0; d.blocks.append(.text("safe edit")); return d }, [], true),
            ("copy of a missing original", { var d = $0; d.blocks.append(block(missing)); return d }, [], false),
            ("invented reference", { var d = $0; d.blocks.append(.file(attachmentID: UUID(), filename: "x.pdf",
                contentTypeIdentifier: "com.adobe.pdf", byteCount: 3)); return d }, [], false),
            ("incomplete payload", { var d = $0; d.blocks.append(block(damaged)); return d }, [damaged], false),
            ("new file beside a missing original", { var d = $0; d.blocks.append(block(added)); return d }, [added], true),
            ("formatted text", { var d = $0; d.blocks.append(.text("quoted", style: "quote")); return d }, [], true),
            ("removing the unknown objects", { var d = $0; d.blocks.removeAll { [missing.id, split.id].contains($0.attachmentID) }
                return d }, [], true),
            ("new file", { var d = $0; d.blocks.append(block(added)); return d }, [added], true),
        ]
        for (name, transform, items, admitted) in cases {
            let base = try XCTUnwrap(store.loadDocument(noteID: id))
            let candidate = transform(try XCTUnwrap(base.content.document))
            let before = try payloads()
            XCTAssertEqual(store.attachmentAdmissionFailure(noteID: id, document: candidate, staged: items) == nil,
                admitted, "\(name): pre-edit admission")
            let save = store.saveDocument(noteID: id, document: candidate, baseRevisionID: base.revisionID, staged: items)
            switch (save, admitted) {
            case (.success, true): break
            case (.failure(.invalidDocument), false):
                XCTAssertEqual(try payloads(), before, "\(name): a refusal deletes no bytes")
            default: XCTFail("\(name): final save disagrees with admission: \(save)")
            }
        }
    }

    func testR9AccessibilityValidationStaysResponsiveWithStoredPayloadsAndActiveImport() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let data = Data(repeating: 0x42, count: 14 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let items = (0..<7).map { index in
            StagedNoteAttachment(id: UUID(), filename: "\(index).bin", contentTypeIdentifier: "public.data",
                byteCount: Int64(data.count), digest: digest, data: data)
        }
        let doc = NoteDocument(blocks: [.text("Large note")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename,
                contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        })
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: doc, staged: items) else { return XCTFail() }
        let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(60),
            imageLoader: { _ in try? await Task.sleep(for: .milliseconds(400)); return nil })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let (_, view) = session.engine.makeView()
        controller.importFiles([URL(fileURLWithPath: "/tmp/active.png")])
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<3 { XCTAssertEqual(session.engine.accessibilityElements(for: view).count, 7) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 2.0, "validation must not synchronously hash 98 MiB per traversal")
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\nmore"), name: "Typing"))
        XCTAssertLessThan(session.engine.lastUpkeepMilliseconds, 16.7)
        controller.cancelActiveImport()
    }

    func testR10TallImageFitsPrintablePageAndRenderedPDFPaginates() async throws {
        // Distinct end markers must both survive on the same page. A
        // single-color test could pass with a clipped middle of the image.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<400 {
            for x in 0..<20 {
                let pixel = try XCTUnwrap(bitmap.bitmapData).advanced(by: y * bitmap.bytesPerRow + x * 4)
                pixel[0] = y < 100 ? 255 : 0
                pixel[1] = y >= 100 && y < 300 ? 255 : 0
                pixel[2] = y >= 300 ? 255 : 0
                pixel[3] = 255
            }
        }
        let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imageID = UUID()
        let tall = NoteBlock.image(attachmentID: imageID, widthFraction: 1,
            pixelWidth: 1_000, pixelHeight: 20_000)
        let text = String(repeating: "Paragraph before image. ", count: 180)
        let doc = NoteDocument(blocks: [.text("Print"), .text(text), tall, .text("after image")])
        let thumbnail = try XCTUnwrap(NoteImageDecoder.thumbnail(of: imageData, maxPixel: 400))
        let view = NotePrint.printView(document: doc, thumbnails: [imageID: thumbnail])
        let attachment = try XCTUnwrap((0..<view.textStorage!.length).compactMap {
            view.textStorage?.attribute(.attachment, at: $0, effectiveRange: nil) as? NoteImageAttachment
        }.first)
        XCTAssertLessThanOrEqual(attachment.displaySize(columnWidth: NotePrint.columnWidth).height,
            NotePrint.pageHeight * 0.82 + 1)
        XCTAssertEqual(doc.blocks[2].widthFraction, 1, "print sizing never rewrites the note")
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR10-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let operation = NotePrint.operation(for: view)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdfURL
        XCTAssertTrue(operation.run())
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue((0..<pdf.pageCount).contains { pdf.page(at: $0)?.string?.contains("after image") == true })
        var topPages: [Int] = [], bottomPages: [Int] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.pageRef else { continue }
            let width = 612, height = 792
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let markers = pixels.withUnsafeMutableBytes { raw -> (Bool, Bool) in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (false, false) }
                context.drawPDFPage(page)
                let bytes = raw.bindMemory(to: UInt8.self)
                var top = false, bottom = false
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    if bytes[offset] > 200 && bytes[offset + 1] < 80 && bytes[offset + 2] < 80 { top = true }
                    if bytes[offset + 2] > 200 && bytes[offset] < 80 && bytes[offset + 1] < 80 { bottom = true }
                }
                return (top, bottom)
            }
            if markers.0 { topPages.append(index) }
            if markers.1 { bottomPages.append(index) }
        }
        XCTAssertEqual(topPages.count, 1, "top marker survives whole")
        XCTAssertEqual(bottomPages, topPages, "both ends survive on the same page")
    }

    // MARK: Step-back finish: checkpoint claims

    func testOwnCheckpointIsRetiredWhenALaterSaveHoldsNewerText() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { [gate] in try gate.save($0) },
            attachmentFileStore: makeTestAttachmentFileStore())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticProbeA-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft one"), name: "Typing")
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().count, 1)
        gate.shouldFail = false
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " more"), name: "Typing")
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).readRecoveryEntries().isEmpty, "the session's own older checkpoint is retired")
        let relaunched = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await relaunched.startAndWait()
        XCTAssertTrue(relaunched.failedDrafts.isEmpty, "no stale conflict after restart")
    }

    func testCompletedImportRetiresItsPendingCheckpoint() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Plan")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticProbeB-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try stagedImage()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            imageLoader: { _ in (image, CGSize(width: 8, height: 8)) })
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        controller.importFiles([URL(fileURLWithPath: "/tmp/probe.png")])
        try await waitFor { controller.active?.isImporting == false }
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.attachmentIDs.count, 1)
        await controller.waitForRecoveryWork()
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).readRecoveryEntries().isEmpty, "a completed batch retires its checkpoint")
        let relaunched = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await relaunched.startAndWait()
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.attachmentIDs.count, 1, "restart adds nothing again")
    }

    func testUnadoptedCheckpointSurvivesAnotherSessionsCheckpointAndSave() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { [gate] in try gate.save($0) },
            attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Stored")])) else {
            return XCTFail("fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticProbeC-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = NoteDocument(blocks: [.text("Unadopted draft"), .image(attachmentID: UUID())])
        try await NoteDraftJournal(directory: directory).writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: true,
            baseRevisionID: nil, content: try NoteContentCodec.encode(orphan), selectionLocation: 0,
            selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        await controller.startAndWait()
        XCTAssertFalse(controller.recoveryWarnings.isEmpty, "not adopted")
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\nnew"), name: "Typing")
        gate.shouldFail = true
        _ = await controller.preserveDurably(session)
        let texts = try await NoteDraftJournal(directory: directory).entriesDurably().compactMap {
            NoteContentCodec.decode($0.0.content).document.map(NoteTextExport.plainText)
        }
        XCTAssertTrue(texts.count == 1 && texts[0].hasPrefix("Unadopted draft"),
            "the unadopted checkpoint is neither overwritten nor joined: \(texts)")
        guard case .onlyInMemory = session.state else { return XCTFail("the refused checkpoint is reported") }
        gate.shouldFail = false
        XCTAssertTrue(controller.save(session), "an ordinary save still succeeds")
        await XCTAssertEqualAsync(try await NoteDraftJournal(directory: directory).entriesDurably().compactMap {
            NoteContentCodec.decode($0.0.content).document.map(NoteTextExport.plainText)
        }, texts, "a different saved note does not retire it")
    }
}

@MainActor
extension NoteSlice3bTests {
    func testMissingOriginalAcceptsNewFileWithoutChangingItsMissingState() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let missing = staged("missing.pdf"), added = staged("new.pdf"), id = UUID()
        let original = NoteBlock.file(attachmentID: missing.id, filename: missing.filename,
            contentTypeIdentifier: missing.contentTypeIdentifier, byteCount: missing.byteCount)
        guard case .success = store.createDocumentNote(id: id,
            document: NoteDocument(blocks: [.text("Files"), original]), staged: [missing]) else { return XCTFail() }
        for row in try store.attachmentRows(forNoteID: id) { store.modelContext.delete(row) }
        XCTAssertTrue(store.commitStagedChanges())
        store.refresh()
        let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(60))
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active), objectID = try XCTUnwrap(original.id)
        XCTAssertEqual(session.engine.objectState(objectID), .originalMissing)
        session.engine.beginImageImport()
        XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: added, pixelSize: nil)]), "pre-edit gate admits verified new bytes")
        XCTAssertTrue(controller.save(session), "the same admission rule permits final save")
        XCTAssertTrue(session.engine.document().blocks.contains(original))
        XCTAssertEqual(session.engine.objectState(objectID), .originalMissing)
        XCTAssertTrue(try store.attachmentFamily(missing.id).isEmpty, "adding a file does not invent a repair")
        await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(added.id), added)
    }

    func testMissingOriginalsStillCountTowardFileCountAndByteLimits() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let added = staged(), id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Limits")])) else { return XCTFail() }
        for (count, size) in [(20, Int64(1)), (7, AttachmentLimits.maxBytesPerAttachment)] {
            // Imported damaged documents can have placements without rows.
            // They must keep their budgets when admitting an additional file.
            let originals = (0..<count).map { _ in NoteBlock.file(attachmentID: UUID(), filename: "lost.pdf",
                contentTypeIdentifier: "com.adobe.pdf", byteCount: size) }
            let base = NoteDocument(blocks: [.text("Limits")] + originals)
            try XCTUnwrap(store.note(withID: id)).content = try NoteContentCodec.encode(base)
            XCTAssertTrue(store.commitStagedChanges())
            let loaded = try XCTUnwrap(store.loadDocument(noteID: id))
            var candidate = base
            candidate.blocks.append(.file(attachmentID: added.id, filename: added.filename,
                contentTypeIdentifier: added.contentTypeIdentifier, byteCount: added.byteCount))
            XCTAssertNotNil(store.attachmentAdmissionFailure(noteID: id, document: candidate, staged: [added]))
            guard case .failure(.invalidDocument) = store.saveDocument(noteID: id, document: candidate,
                baseRevisionID: loaded.revisionID, staged: [added]) else { return XCTFail("both gates enforce the limit") }
            XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, base)
            XCTAssertTrue(try store.attachmentRows(forNoteID: id).isEmpty)
        }
    }
}

// MARK: Fix round 4 invariant and reproducer tests

private final class RecoveryArchiveFailingFileManager: FileManager, @unchecked Sendable {
    private let failureLock = NSLock()
    private var archiveFailure = false
    var failArchive: Bool {
        get { failureLock.withLock { archiveFailure } }
        set { failureLock.withLock { archiveFailure = newValue } }
    }
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failArchive { throw CocoaError(.fileWriteOutOfSpace) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class PayloadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Bool, Int)] = []
    func record(_ main: Bool, _ bytes: Int) { lock.lock(); events.append((main, bytes)); lock.unlock() }
    var snapshot: [(Bool, Int)] { lock.lock(); defer { lock.unlock() }; return events }
}

@MainActor
extension NoteSlice3bTests {
    private func recoveryEntry(_ id: UUID, document: NoteDocument, item: StagedNoteAttachment,
                               revision: UUID?) throws -> NoteDraftJournalEntry {
        .init(noteID: id, isPersisted: true, baseRevisionID: revision,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                byteCount: item.byteCount, digest: item.digest)], savedAt: Date())
    }

    func testA1MatchingRecoveryNeverLosesUniqueBytesThroughStartupSaveCollectionAndRestart() async throws {
        enum Damage: CaseIterable { case absent, nilPayload, corrupt, different }
        for deleted in [false, true] {
            for damage in Damage.allCases {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("A1-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
                let id = UUID(), item = staged()
                let document = NoteDocument(blocks: [.text("Handoff"), .file(attachmentID: item.id,
                    filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
                guard case let .success((_, revision)) = store.createDocumentNote(id: id, document: document, staged: [item]) else { return XCTFail() }
                let journal = NoteDraftJournal(directory: root)
                _ = try await journal.writeDurably(recoveryEntry(id, document: document, item: item, revision: revision), staged: [item])
                if deleted { XCTAssertTrue(store.delete(store.note(withID: id)!)) }
                for row in try store.attachmentRows(forNoteID: id) {
                    switch damage {
                    case .absent: store.modelContext.delete(row)
                    case .nilPayload: row.payload = nil
                    case .corrupt: row.payload = Data("broken".utf8)
                    case .different: row.payload = Data(repeating: 0x78, count: item.data.count); row.contentDigest = String(repeating: "f", count: 64)
                    }
                }
                try store.modelContext.save(); store.refresh()
                let controller = NotesPageController(store: store, journal: journal)
                await controller.startAndWait()
                if let session = controller.active { _ = await controller.preserveDurably(session) }
                await controller.waitForRecoveryWork()
                _ = try await journal.readRecoveryEntries()
                let restarted = NoteDraftJournal(directory: root)
                let recovery = try await restarted.entriesDurably()
                let stillStaged = recovery.flatMap { $0.1 }.contains { $0.data == item.data && $0.id == item.id }
                let storedBytes = await store.verifiedAttachmentBytes(item.id)
                XCTAssertTrue(stillStaged || storedBytes?.data == item.data, "\(damage), deleted=\(deleted): at least one durable owner survives")
                if deleted || damage == .corrupt || damage == .different {
                    XCTAssertTrue(stillStaged, "unmatched bytes remain in recovery")
                } else { XCTAssertEqual(storedBytes?.data, item.data, "safe missing-byte repair commits with the document") }
            }
        }
    }

    func testA1ByteOwnershipInvariantEnumeratesJournalMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A1Invariant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), item = staged(), document = NoteDocument(blocks: [.text("Owner")])
        let journal = NoteDraftJournal(directory: root)
        let entry = try recoveryEntry(id, document: document, item: item, revision: nil)
        let claim = try await journal.writeDurably(entry, staged: [item])
        let unproven = NoteRecoverySavedState(document: document, tags: [])
        await XCTAssertThrowsErrorAsync(try await journal.retireDurably(noteID: id, claim: nil, saved: unproven))
        var replacement = entry; replacement.staged = []
        let replaced = try await journal.writeDurably(replacement, staged: [], replacing: claim)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("staged/\(item.id.uuidString)")), item.data)
        let afterRead = try await journal.entriesDurably()
        XCTAssertEqual(afterRead.first?.1, [item], "replacement and collection retain old byte ownership")
        await XCTAssertThrowsErrorAsync(try await journal.retireDurably(noteID: id, claim: nil, saved: unproven))
        // Production cannot prove removed bytes: the owner's saved state
        // supersedes them. Claimless retirement still needs every byte proof.
        try await journal.retireDurably(noteID: id, claim: replaced, saved: unproven)
        await XCTAssertTrueAsync(try await journal.readRecoveryEntries().isEmpty)
        // Explicit owned cancellation is the separate release operation.
        let cancelled = try await journal.writeDurably(entry, staged: [item])
        try await journal.discardOwnedDurably(noteID: id, claim: cancelled)
        await XCTAssertTrueAsync(try await journal.entriesDurably().isEmpty)
    }

    func testA2HistoryFamilyInvariantEveryDataFieldProtectsThinningAndExpiry() async throws {
        enum Difference: CaseIterable { case title, body, attachmentIDs, reason, unknownReason, content, format, revision, recoveryBase, owner, createdAt, proposalBase }
        for field in Difference.allCases {
            for expiry in [false, true] {
                let now = Date(), old = now.addingTimeInterval(-40 * 86_400)
                let store = try makeTestNoteStore(now: { now }, attachmentFileStore: makeTestAttachmentFileStore())
                let item = staged(), noteID = UUID(), versionID = UUID(), revision = UUID()
                let note = try XCTUnwrap(store.create(title: "Deleted", body: "body"))
                let ownerID = note.id
                let a = NoteVersion(id: versionID, noteID: ownerID, createdAt: old, reason: .leave,
                    content: nil, contentFormat: 0, title: "Legacy", body: "First", attachmentIDs: [item.id], sourceRevisionID: revision)
                let b = NoteVersion(id: versionID, noteID: ownerID, createdAt: old, reason: .leave,
                    content: nil, contentFormat: 0, title: "Legacy", body: "First", attachmentIDs: [item.id], sourceRevisionID: revision)
                switch field {
                case .title: b.title = "Other"
                case .body: b.body = "Second"
                case .attachmentIDs: b.attachmentIDsRaw = ""
                case .reason: b.reasonRaw = NoteVersionReason.pause.rawValue
                case .unknownReason: a.reasonRaw = "future"; b.reasonRaw = "future"
                case .content: b.content = Data("unknown".utf8)
                case .format: a.contentFormat = 20; b.contentFormat = 20
                case .revision: b.sourceRevisionID = noteID
                case .recoveryBase: store.recoveryProtectedRevisionIDs = { [revision] }
                case .owner: b.noteID = UUID()
                case .createdAt: b.createdAt = old.addingTimeInterval(1)
                case .proposalBase:
                    store.modelContext.insert(NotePendingEdit(noteID: UUID(), baseRevisionToken: "external",
                        proposedContent: try NoteContentCodec.encode(.blank), agentName: "agent", createdAt: now, baseVersionID: versionID))
                }
                store.modelContext.insert(a); store.modelContext.insert(b)
                let attachment = NoteAttachment(id: item.id, noteID: ownerID, originalFilename: item.filename,
                    byteCount: item.byteCount, sortIndex: 0, contentDigest: item.digest, createdAt: old, payload: item.data)
                store.modelContext.insert(attachment); try store.modelContext.save(); store.refresh()
                if expiry {
                    XCTAssertTrue(store.delete(note))
                    // Preserve the exact recorded attachment family and timestamps.
                    for row in try store.replicasIncludingDeleted(of: ownerID) { row.deletedAt = now.addingTimeInterval(-60) }
                    for row in try store.attachmentRows(forNoteID: ownerID) { row.deletedAt = old; row.updatedAt = old }
                    try store.modelContext.save()
                    XCTAssertTrue(store.purgeDeleted(before: now).isEmpty, "\(field) blocks enclosing expiry")
                } else { store.thinVersions(noteID: ownerID) }
                let kept = try store.modelContext.fetch(FetchDescriptor<NoteVersion>()).filter { $0.id == versionID }
                XCTAssertEqual(kept.count, 2, "\(field), expiry=\(expiry)")
                XCTAssertEqual(try store.attachmentRows(forNoteID: ownerID).first?.payload, item.data)
            }
        }
    }

    func testA2DivergentSameNoteProposalBlocksExpiryAndApplication() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Proposal", body: "base")), id = UUID()
        let a = NotePendingEdit(id: id, noteID: note.id, baseRevisionToken: note.revisionToken,
            proposedContent: try NoteContentCodec.encode(NoteDocument(blocks: [.text("A")])), agentName: "agent", createdAt: Date())
        let b = NotePendingEdit(id: id, noteID: note.id, baseRevisionToken: note.revisionToken,
            proposedContent: try NoteContentCodec.encode(NoteDocument(blocks: [.text("B")])), agentName: "agent", createdAt: a.createdAt)
        store.modelContext.insert(a); store.modelContext.insert(b); try store.modelContext.save()
        XCTAssertEqual(store.applyPendingEdits(noteID: note.id), 0)
        XCTAssertTrue(store.delete(note))
        XCTAssertTrue(store.purgeDeleted(before: Date().addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<NotePendingEdit>()).filter { $0.id == id }.count, 2)
    }

    func testA3CompletedBatchRevalidatesEarlierItemsAfterSuspendedDraftGrowth() async throws {
        for aggregate in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let initial = (0..<(aggregate ? 6 : 18)).map { staged("\($0).pdf") }
            let doc = NoteDocument(blocks: [.text("Growth")] + initial.map { .file(attachmentID: $0.id,
                filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount) })
            let id = UUID()
            guard case .success = store.createDocumentNote(id: id, document: doc, staged: initial) else { return XCTFail() }
            if aggregate {
                for row in try store.attachmentRows(forNoteID: id) { row.byteCount = 15 * 1024 * 1024 }
                try store.modelContext.save(); store.refresh()
            }
            let first = aggregate ? stagedSized("a.png", bytes: 8 * 1024 * 1024) : try stagedImage()
            let second = try stagedImage(), loader = TwoSourceLoader(first: first, second: second)
            let controller = NotesPageController(store: store, journal: nil, imageLoader: { await loader.load($0) })
            XCTAssertTrue(controller.open(noteID: id))
            let session = try XCTUnwrap(controller.active), engine = session.engine
            controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")], acceptedText: "accepted")
            try await waitFor { session.importProgress?.completed == 1 }
            // A private fragment grows the draft while the second loader waits.
            let extra = aggregate ? [stagedSized("growth.pdf", bytes: 3 * 1024 * 1024)] : [staged(), staged()]
            let sourceID = UUID()
            let fragment = NoteDocument(blocks: extra.map { .file(attachmentID: $0.id, filename: $0.filename,
                contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount) },
                extras: ["sourceNoteID": .string(sourceID.uuidString)])
            guard case .success = store.createDocumentNote(id: sourceID,
                document: NoteDocument(blocks: [.text("Source")] + fragment.blocks), staged: extra) else { return XCTFail() }
            XCTAssertTrue(engine.paste(fragmentData: try NoteContentCodec.encode(fragment, context: .fragment),
                at: NSRange(location: engine.textStorage.length, length: 0)))
            let before = engine.document(), staging = engine.staged, undo = engine.history.undoOps.count
            await loader.release()
        await controller.waitForImportWork()
            try await waitFor { session.importProgress?.completed == 2 }
            XCTAssertTrue(session.isImporting, "refused completed batch remains cancellable")
            XCTAssertEqual(engine.document(), before)
            XCTAssertEqual(engine.staged, staging)
            XCTAssertEqual(engine.history.undoOps.count, undo)
            controller.cancelActiveImport()
            XCTAssertFalse(session.isImporting)
        }
    }

    func testA4PlacementLocateReconstructsAbsentRowRejectsWrongBytesAndDivergentFamily() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil)
        controller.start()
        let session = try XCTUnwrap(controller.active), item = staged()
        session.engine.beginImageImport()
        XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: item, pixelSize: nil)]))
        XCTAssertTrue(controller.save(session))
        let block = try XCTUnwrap(session.engine.document().blocks.first { $0.attachmentID == item.id })
        XCTAssertEqual(block.extras["contentDigest"]?.stringValue, item.digest)
        for row in try store.attachmentRows(forNoteID: session.noteID) { store.modelContext.delete(row) }
        try store.modelContext.save(); store.refresh()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("A4-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("wrong original".utf8).write(to: source)
        let wrong = await session.engine.perform(.locateAt(source), objectID: block.id!)
        XCTAssertFalse(wrong); XCTAssertTrue(try store.attachmentRows(forNoteID: session.noteID).isEmpty)
        try item.data.write(to: source)
        XCTAssertEqual(store.loadDocument(noteID: session.noteID)?.content.document?.blocks.first { $0.id == block.id }, block)
        XCTAssertTrue(session.engine.validate(.locateAt(source), objectID: block.id!).enabled)
        let repaired = await session.engine.perform(.locateAt(source), objectID: block.id!)
        XCTAssertTrue(repaired, store.lastErrorMessage ?? "no store error")
        XCTAssertEqual(try store.attachmentRows(forNoteID: session.noteID).first?.payload, item.data)
        let split = NoteAttachment(id: item.id, noteID: session.noteID, originalFilename: item.filename,
            byteCount: item.byteCount, sortIndex: 0, contentDigest: String(repeating: "a", count: 64), payload: nil)
        store.modelContext.insert(split); try store.modelContext.save(); store.refresh()
        let refused = await controller.locatePlacement(block, noteID: session.noteID, at: source)
        XCTAssertFalse(refused)
        XCTAssertNil(split.payload)
        // Simulate ownership deletion/change while the asynchronous read runs.
        store.modelContext.delete(split); try store.modelContext.save(); store.refresh()
        let late = await store.locatePlacement(block, noteID: session.noteID, at: source) {
            _ = store.delete(store.note(withID: session.noteID)!)
            return false
        }
        XCTAssertFalse(late)
    }

    func testA4LegacyMissingPlacementHasExplicitReplacementWithNewUUID() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let item = staged(), id = UUID()
        let document = NoteDocument(blocks: [.text("Legacy"), .file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: document, staged: [item]) else { return XCTFail() }
        for row in try store.attachmentRows(forNoteID: id) { store.modelContext.delete(row) }
        try store.modelContext.save(); store.refresh()
        let controller = NotesPageController(store: store, journal: nil); XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active), source = FileManager.default.temporaryDirectory.appendingPathComponent("A4Legacy-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        try item.data.write(to: source)
        let locate = await session.engine.perform(.locateAt(source), objectID: document.blocks[1].id!)
        XCTAssertFalse(locate)
        let replacement = await session.engine.perform(.replaceMissingAt(source), objectID: document.blocks[1].id!)
        XCTAssertTrue(replacement)
        XCTAssertNotEqual(session.engine.document().blocks[1].attachmentID, item.id)
        XCTAssertTrue(controller.save(session))
    }

    func testA5ConfirmedQuarantinePreservesUnknownBytesAcrossFailureRestartAndNewCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A5-\(UUID())"), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staged"), withIntermediateDirectories: true)
        let raw = Data("{damaged".utf8), unknown = Data("unknown recovery original".utf8)
        try raw.write(to: root.appendingPathComponent("\(id.uuidString).json"))
        try unknown.write(to: root.appendingPathComponent("staged/unknown-name"))
        let fm = RecoveryArchiveFailingFileManager(), journal = NoteDraftJournal(directory: root, fileManagerFactory: { fm })
        let details = try await journal.damagedDetailsDurably(noteID: id)
        XCTAssertEqual(details.title, "Recovery data is damaged")
        fm.failArchive = true
        await XCTAssertThrowsErrorAsync(try await journal.archiveDamagedDurably(details.confirmation, to: nil, resolving: true))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(id.uuidString).json")), raw)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("staged/unknown-name")), unknown)
        fm.failArchive = false
        let copy = try await journal.archiveDamagedDurably(details.confirmation, to: root.appendingPathComponent("export"), resolving: false)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("\(id.uuidString).json")), raw)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: journal)
        let result = await controller.perform(.discardDamagedRecovery(details.confirmation))
        guard case let .archived(archive) = result else { return XCTFail("confirmed command must resolve") }
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("resolved-checkpoint.raw")), raw)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("staged/unknown-name")), unknown)
        let restarted = NoteDraftJournal(directory: root)
        await XCTAssertTrueAsync(try await restarted.readRecoveryEntries().isEmpty)
        let entry = NoteDraftJournalEntry(noteID: id, isPersisted: false, baseRevisionID: nil,
            content: try NoteContentCodec.encode(.blank), selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date())
        let claim = try await restarted.writeDurably(entry, staged: [])
        try await restarted.discardOwnedDurably(noteID: id, claim: claim)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("staged/unknown-name")), unknown)
        await controller.startAndWait()
        let note = try XCTUnwrap(store.create(title: "After resolution", body: "safe"))
        let deleted = await controller.deleteNoteDurably(noteID: note.id)
        XCTAssertTrue(deleted, "resolved recovery no longer blocks deletion")
    }

    func testA6PrintUsesProtectedCheckpointObjectsAndMarksDuringRefusedRewrite() async throws {
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP8z4AdMOEQH6QSAM1BAQ/oQeJvAAAAAElFTkSuQmCC"))
        let image = StagedNoteAttachment(id: UUID(), filename: "solid.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        let provider = StoredImageProvider(image)
        var text = NoteBlock.text("Protected bold")
        text.marks = [.init(.bold, offset: 0, length: 9)]
        let document = NoteDocument(blocks: [.text("Original"), text,
            .image(attachmentID: image.id, pixelWidth: 8, pixelHeight: 8), .checklist("kept")])
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        engine.imageProvider = provider; _ = engine.makeView()
        let expected = engine.document()
        engine.onWritingToolsWillBegin = { false }; engine.writingToolsWillBegin()
        engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: engine.textStorage.length), with: "Rewritten")
        XCTAssertEqual(engine.checkpointDocument(), expected)
        let view = await engine.preparedPrintView()
        XCTAssertTrue(view.string.contains("Protected bold")); XCTAssertFalse(view.string.contains("Rewritten"))
        XCTAssertTrue(view.textStorage!.attributes(at: 9, effectiveRange: nil).keys.contains(.noteMark(.bold)))
        let objects = (0..<view.textStorage!.length).compactMap { view.textStorage!.attribute(.attachment, at: $0, effectiveRange: nil) as? NoteObjectAttachment }
        XCTAssertTrue(objects.contains { $0 is NoteImageAttachment }); XCTAssertTrue(objects.contains { $0 is NoteChecklistAttachment })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("A6-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: path) }
        let op = NotePrint.operation(for: view); op.showsPrintPanel = false; op.showsProgressPanel = false
        op.printInfo.jobDisposition = .save; op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = path
        XCTAssertTrue(op.run())
        let pdf = try XCTUnwrap(PDFDocument(url: path))
        XCTAssertTrue(pdf.string?.contains("Protected bold") == true); XCTAssertFalse(pdf.string?.contains("Rewritten") == true)
        let page = try XCTUnwrap(pdf.page(at: 0)?.pageRef)
        var pixels = [UInt8](repeating: 255, count: 612 * 792 * 4)
        let renderedImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 612, height: 792, bitsPerComponent: 8,
                bytesPerRow: 612 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.drawPDFPage(page)
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 200 && bytes[$0+1] < 80 && bytes[$0+2] < 80 }
        }
        XCTAssertTrue(renderedImage, "protected image is actually rendered into the PDF")
        engine.writingToolsDidEnd()
    }

    func testA7ProductionControllerLargeImportRealJournalHashesOffMainWhileTyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("A7-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); NotePayloadDigest.observe(nil) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sources = (0..<3).map { root.appendingPathComponent("large\($0).pdf") }
        for source in sources { try Data(repeating: 0x42, count: 12 * 1024 * 1024).write(to: source) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")), saveDelay: .seconds(60))
        await controller.startAndWait()
        let engine = try XCTUnwrap(controller.active?.engine), recorder = PayloadThreadRecorder()
        NotePayloadDigest.observe { recorder.record($0, $1) }
        let began = CFAbsoluteTimeGetCurrent()
        controller.importFiles(sources)
        var typing: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertTrue(engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                with: NSAttributedString(string: "x"), name: "Typing"))
            typing.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await waitFor { controller.active?.isImporting == false }
        await controller.waitForRecoveryWork()
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        XCTAssertEqual(engine.document().attachmentIDs.count, 3)
        let hashes = recorder.snapshot.filter { $0.1 > 1_000_000 }
        XCTAssertFalse(hashes.isEmpty); XCTAssertFalse(hashes.contains { $0.0 }, "large production payload hashes never execute on main")
        let sorted = typing.sorted()
        print("A7 real import+journal: \(elapsed)s; typing median \(sorted[50])ms p95 \(sorted[95])ms max \(sorted.last!)ms; \(hashes.count) off-main large hashes")
        // Include byte retrieval, print preparation and another durable save in
        // the same thread invariant without presenting system UI.
        store.clearVerifiedAttachmentCache()
        for id in engine.document().attachmentIDs {
            let bytes = await store.verifiedAttachmentBytes(id)
            XCTAssertNotNil(bytes, "stored byte retrieval uses the background verifier")
        }
        _ = await engine.preparedPrintView()
        _ = await controller.preserveDurably(try XCTUnwrap(controller.active))
        XCTAssertFalse(recorder.snapshot.filter { $0.1 > 1_000_000 }.contains { $0.0 })
    }
}

@MainActor
extension NoteSlice3bTests {
    func testByteDeletionPrimitiveInvariantEnumeratesEveryCollectorAndOwner() async throws {
        enum Owner: CaseIterable { case recovery, draft, undo, pendingBatch, version, versionWithoutCachedIDs, unreadableVersion, proposal, unreadableProposal, recentlyDeleted, unreadableNote }
        enum Collector: CaseIterable { case explicitRemoval, metadataReconciliation, reconciliation, expiredSweep }
        for owner in Owner.allCases {
            for collector in Collector.allCases {
                let files = makeTestAttachmentFileStore(), store = try makeTestNoteStore(attachmentFileStore: files)
                let item = staged(), noteID = UUID()
                let block = NoteBlock.file(attachmentID: item.id, filename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
                let doc = NoteDocument(blocks: [.text("Owner"), block])
                let reference = AttachmentFileReference(id: item.id, digest: item.digest, filename: item.filename, payload: item.data)
                let url = try await files.ensureMaterialized(reference)
                XCTAssertNotNil(url)
                // Isolate exactly one owner; no attachment row supplies a second copy.
                switch owner {
                case .draft, .undo, .pendingBatch, .recovery:
                    store.recoveryReferencedAttachmentIDs = { [item.id] }
                case .version, .versionWithoutCachedIDs, .unreadableVersion:
                    store.modelContext.insert(NoteVersion(noteID: noteID, createdAt: Date(), reason: .leave,
                        content: owner == .unreadableVersion ? Data("future".utf8) : try NoteContentCodec.encode(doc),
                        contentFormat: owner == .unreadableVersion ? 20 : 1, title: "Owner", body: "",
                        attachmentIDs: owner == .version ? [item.id] : [], sourceRevisionID: nil))
                case .proposal, .unreadableProposal:
                    store.modelContext.insert(NotePendingEdit(noteID: noteID, baseRevisionToken: "base",
                        proposedContent: owner == .unreadableProposal ? Data("future".utf8) : try NoteContentCodec.encode(doc),
                        agentName: "agent", createdAt: Date()))
                case .recentlyDeleted, .unreadableNote:
                    let note = NoteItem(id: noteID, title: "Owner", body: "", createdAt: Date(), updatedAt: Date())
                    note.contentFormat = owner == .unreadableNote ? 20 : 1
                    note.content = owner == .unreadableNote ? Data("future".utf8) : try NoteContentCodec.encode(doc)
                    note.deletedAt = Date()
                    store.modelContext.insert(note)
                }
                try store.modelContext.save()
                switch collector {
                case .explicitRemoval: try await files.removeMaterializations([reference])
                case .metadataReconciliation: _ = try await files.reconcileMetadata([])
                case .reconciliation: try await files.reconcile([])
                case .expiredSweep: _ = await files.removeUnreferencedMaterializations(keeping: [], modifiedBefore: Date().addingTimeInterval(1), limit: 100)
                }
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), item.data, "\(owner) blocks \(collector) at the primitive")
            }
        }
    }
}


@MainActor
extension NoteSlice3bTests {
    func testDamagedRecoveryDiscoveryIncludesUnknownFilenamesAndRejectsStaleConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnknownRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: file)
        let journal = NoteDraftJournal(directory: root)
        let controller = NotesPageController(store: try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore()), journal: journal)
        await controller.startAndWait()
        guard case let .damagedList(list) = await controller.perform(.listDamagedRecovery), let details = list.first else { return XCTFail("owner must discover unknown filenames") }
        XCTAssertNil(details.confirmation.noteID)
        XCTAssertEqual(details.confirmation.checkpointFilename, "corrupt.json")
        try Data("changed".utf8).write(to: file)
        guard case .unavailable = await controller.perform(.discardDamagedRecovery(details.confirmation)) else { return XCTFail("stale confirmation must refuse") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let fresh = try await XCTUnwrapAsync(try await journal.listDamagedDurably().first)
        guard case let .archived(archive) = await controller.perform(.discardDamagedRecovery(fresh.confirmation)) else { return XCTFail("confirmed unknown file must resolve") }
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("resolved-checkpoint.raw")), Data("changed".utf8))
        XCTAssertTrue(controller.recoveryWarnings.isEmpty)
        await XCTAssertTrueAsync(try await journal.readRecoveryEntries().isEmpty)
    }

    func testAdmissionInvariantEnumeratesEveryObjectInsertionRoute() throws {
        enum Route: CaseIterable { case directEdit, image, batch, slash, retry, privatePaste }
        let item = staged()
        for route in Route.allCases {
            let failed = NoteBlock.file(filename: "failed.pdf", contentTypeIdentifier: "com.adobe.pdf", byteCount: 0, importFailure: "read failed")
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Latest"), failed]))
            var gates = 0
            engine.onFragmentAdmission = { document, _ in
                gates += 1
                XCTAssertEqual(document.title, "Latest")
                return "latest document refuses the payload"
            }
            if route == .slash {
                let (_, view) = engine.makeView()
                view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
                view.insertNewline(nil)
                for character in "/ima" { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
            }
            let before = engine.document(), undo = engine.history.canUndo
            let at = NSRange(location: engine.textStorage.length, length: 0)
            let imported = NoteImportedObject(staged: item, pixelSize: nil)
            let accepted: Bool
            switch route {
            case .directEdit:
                let object = NoteFileAttachment(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
                accepted = engine.performEdit(at, with: NoteTextCodec.attachmentString(object, attributes: [:]), name: "Direct")
            case .image: accepted = engine.insertImage(item, pixelSize: CGSize(width: 8, height: 8))
            case .batch: engine.beginImageImport(); accepted = engine.insertImportedObjects([imported])
            case .slash: accepted = engine.commitSlashObject(imported)
            case .retry: accepted = engine.replaceFailedFile(try XCTUnwrap(engine.objects().first?.0.objectID), with: imported)
            case .privatePaste:
                let block = NoteBlock.file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
                var fragment = NoteDocument(blocks: [block]); fragment.extras["sourceNoteID"] = .string(engine.noteID.uuidString)
                accepted = engine.paste(fragmentData: try NoteContentCodec.encode(fragment), at: at)
            }
            XCTAssertFalse(accepted, "\(route) must consult the same final candidate gate")
            XCTAssertGreaterThan(gates, 0, "\(route) must route through admission")
            XCTAssertEqual(engine.document(), before, "\(route) leaves the exact document intact")
            XCTAssertEqual(engine.history.canUndo, undo)
            XCTAssertTrue(engine.staged.isEmpty)
        }
    }

    func testAgentAvailabilityVerifiesCorruptPayloadAndRetainedMaterialization() async throws {
        let files = makeTestAttachmentFileStore(), store = try makeTestNoteStore(attachmentFileStore: files)
        let item = staged(), id = UUID()
        let block = NoteBlock.file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Bytes"), block]), staged: [item]) else { return XCTFail("fixture") }
        let tools = AgentTaskTools(store: try makeTestStore(), noteStore: store)
        func availability() throws -> Any? {
            let json = try tools.call(name: "list_notes", arguments: [:])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return ((object["notes"] as? [[String: Any]])?.first?["files"] as? [[String: Any]])?.first?["bytes_available"]
        }
        let row = try XCTUnwrap(store.attachmentFamily(item.id).first)
        row.payload = Data("corrupt".utf8); try store.modelContext.save(); store.refresh()
        XCTAssertTrue(try availability() is NSNull, "verification pending is explicit")
        try await waitFor { store.knownAttachmentAvailability(item.id) != nil }
        XCTAssertEqual(try availability() as? Bool, false)
        _ = try await files.ensureMaterialized(AttachmentFileReference(id: item.id, digest: item.digest, filename: item.filename, payload: item.data))
        try XCTUnwrap(store.attachmentFamily(item.id).first).payload = nil
        try store.modelContext.save(); store.refresh()
        XCTAssertTrue(try availability() is NSNull)
        try await waitFor { store.knownAttachmentAvailability(item.id) != nil }
        XCTAssertEqual(try availability() as? Bool, true, "verified retained bytes count even when payload is absent")
    }
}

@MainActor
private final class CancellationBarrierJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    var requiresAsyncIO: Bool { true }
    private(set) var cancellationStarted = false
    private var cancellation: CheckedContinuation<Void, Never>?
    init(directory: URL) { base = NoteDraftJournal(directory: directory) }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        try await base.writeDurably(entry, staged: staged, replacing: replacing)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        try await base.discardOwnedDurably(noteID: noteID, claim: claim)
    }
    func cancelPendingDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        cancellationStarted = true
        await withCheckedContinuation { cancellation = $0 }
        return try await base.cancelPendingDurably(entry, staged: staged, replacing: replacing)
    }
    func releaseCancellation() { cancellation?.resume(); cancellation = nil }
}

@MainActor
extension NoteSlice3bTests {
    func testCancelledLoaderCannotRecreatePendingRecoveryWhileCancellationIsCommitting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CancelFence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CancellationBarrierJournal(directory: root)
        let loader = FirstSuspendedLoader(try stagedImage())
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
            imageLoader: { await loader.load($0) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Keep typed text"), name: "Typing")
        controller.importFiles([URL(fileURLWithPath: "/tmp/cancel-fence.png")])
        for _ in 0..<100 where await loader.started == false { try await Task.sleep(for: .milliseconds(2)) }
        controller.cancelActiveImport()
        try await waitFor { journal.cancellationStarted }
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " while cancelling"), name: "Typing")
        XCTAssertFalse(controller.preserve(session))
        // The batch must remain owned until cancellation commits. A loader
        // which ignores Task cancellation can return during that interval.
        await loader.release()
        try await Task.sleep(for: .milliseconds(30))
        journal.releaseCancellation()
        await controller.waitForImportWork()
        XCTAssertFalse(session.isImporting)
        XCTAssertTrue(session.engine.document().attachmentIDs.isEmpty)
        let checkpoint = try await XCTUnwrapAsync(try await journal.base.entriesDurably().first?.0)
        XCTAssertNil(checkpoint.pendingImport, "a late cancelled callback must not resurrect pending metadata")
        XCTAssertTrue(checkpoint.staged.isEmpty, "the cancelled file is not checkpointed after the cancellation boundary")
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: root), saveDelay: .seconds(60))
        await restarted.startAndWait()
        XCTAssertTrue(restarted.active?.engine.document().attachmentIDs.isEmpty == true,
            "restart cannot insert a file the owner cancelled")
        XCTAssertEqual(restarted.active?.engine.document().title, "Keep typed text while cancelling")
    }
}

@MainActor
extension NoteSlice3bTests {
    func testRecoveryInventoryIsReadyForRecentlyDeletedBeforeNotesPageIsOpened() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionStartup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Meeting notes", body: "Agenda"))
        let id = note.id
        XCTAssertTrue(store.delete(note))
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root))
        await controller.waitForRecoveryWork()
        XCTAssertNil(controller.active, "startup ownership initialization must not present Notes")
        XCTAssertTrue(try store.recoveryReferencedAttachmentIDs().isEmpty)
        XCTAssertTrue(try store.recoveryProtectedRevisionIDs().isEmpty)
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [id],
            "an ordinary known-safe deleted note can be emptied without opening Notes first")
    }
}

// MARK: Fix round 5: superseded ownership and bounded user operations

@MainActor
private final class PendingWriteJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    private(set) var retirementRequests: [UUID] = []
    var afterRetirement: (() -> Void)?
    var failRetirement = false
    var blockWrites = false
    var failNextWrite = false
    var failRead = false
    var blockRead = false
    private(set) var readStarted = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private(set) var writeStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(directory: URL) { base = NoteDraftJournal(directory: directory) }
    var requiresAsyncIO: Bool { true }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        if blockRead { readStarted = true; await withCheckedContinuation { readContinuation = $0 } }
        return try await base.readRecoveryEntries()
    }
    func listDamagedDurably() async throws -> [NoteDamagedRecoveryDetails] { try await base.listDamagedDurably() }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment], replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        if blockWrites {
            writeStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        if failNextWrite { failNextWrite = false; throw CocoaError(.fileWriteOutOfSpace) }
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        retirementRequests.append(noteID)
        if failRetirement { throw CocoaError(.fileWriteNoPermission) }
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
        afterRetirement?()
    }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        try await base.discardOwnedDurably(noteID: noteID, claim: claim)
    }
    func release() { blockWrites = false; continuation?.resume(); continuation = nil }
    func releaseRead() { blockRead = false; readContinuation?.resume(); readContinuation = nil }
}

@MainActor
extension NoteSlice3bTests {
    func testReviewerRemovedStagedImageStrandsCheckpoint() async throws {
        for removalByUndo in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("M1Import-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID(), y = try stagedImage()
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
            let loader = FirstSuspendedLoader(try stagedImage()), journal = NoteDraftJournal(directory: root)
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60), imageLoader: { await loader.load($0) })
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            let session = try XCTUnwrap(controller.active)
            controller.importFiles([URL(fileURLWithPath: "/tmp/pending.png")])
            for _ in 0..<100 where await loader.started == false { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(session.engine.insertImage(y, pixelSize: CGSize(width: 8, height: 8)))
            await controller.runDueSave(session)
            if removalByUndo { XCTAssertTrue(session.engine.history.undo()) }
            else {
                let block = try XCTUnwrap(session.engine.document().blocks.first { $0.attachmentID == y.id })
                await XCTAssertTrueAsync(await session.engine.perform(.delete, objectID: try XCTUnwrap(block.id)))
            }
            await controller.runDueSave(session)
            await loader.release()
            await controller.waitForImportWork()
            await controller.runDueSave(session)
            XCTAssertEqual(session.state, .clean)
            await XCTAssertTrueAsync(try await journal.readRecoveryEntries().isEmpty, "checkpoint retires")
            XCTAssertEqual(session.engine.staged[y.id], y, "superseded bytes still serve Undo")
            XCTAssertNil(session.notice)
            await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id), "note can be deleted")
            let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: root))
            await restarted.startAndWait()
            XCTAssertTrue(restarted.failedDrafts.isEmpty, "nothing resurrects at restart")
        }
    }

    func testRemovedStagedImageAfterStoreFailureHasNoStuckState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M1Failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PersistenceGate(), id = UUID(), y = try stagedImage()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        let journal = NoteDraftJournal(directory: root), controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root), saveDelay: .seconds(60))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        gate.shouldFail = true
        XCTAssertTrue(session.engine.insertImage(y, pixelSize: CGSize(width: 8, height: 8)))
        await controller.runDueSave(session)
        let block = try XCTUnwrap(session.engine.document().blocks.first { $0.attachmentID == y.id })
        await XCTAssertTrueAsync(await session.engine.perform(.delete, objectID: try XCTUnwrap(block.id)))
        gate.shouldFail = false
        await controller.runDueSave(session)
        await XCTAssertTrueAsync(try await journal.readRecoveryEntries().isEmpty)
        XCTAssertEqual(session.engine.staged[y.id], y)
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: root))
        await restarted.startAndWait()
        XCTAssertTrue(restarted.failedDrafts.isEmpty)
    }

    func testReviewerDeletingAnUnopenedNoteLeavesNoFailureNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M2Delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root))
        await controller.startAndWait()
        let first = try XCTUnwrap(store.create(title: "First", body: "body"))
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: first.id))
        XCTAssertNil(controller.active?.notice)
        let second = try XCTUnwrap(store.create(title: "Second", body: "body"))
        XCTAssertTrue(controller.deleteNote(noteID: second.id), "first synchronous call succeeds without a checkpoint")
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertTrue(controller.redoLibrary(), "Delete redo works on the first press")
        XCTAssertNil(controller.active?.notice)
    }

    func testHideAndSwitchAcceptQueuedCheckpointAndQuitWaitsForWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M2Leave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root), loader = FirstSuspendedLoader(try stagedImage())
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60), imageLoader: { await loader.load($0) })
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Pending"), name: "Typing"))
        journal.blockWrites = true
        controller.importFiles([URL(fileURLWithPath: "/tmp/pending.png")])
        try await waitFor { journal.writeStarted }
        XCTAssertTrue(controller.prepareToLeave(.hide))
        XCTAssertTrue(controller.prepareToLeave(.pageSwitch))
        var quitResult: Bool?
        let quit = Task { @MainActor in quitResult = await controller.prepareToLeaveDurably(.quit) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(quitResult, "quit cannot terminate before the checkpoint write")
        journal.release()
        await quit.value
        XCTAssertEqual(quitResult, true)
        XCTAssertFalse(try journal.base.entries().isEmpty)
        await loader.release()
        await controller.waitForImportWork()
    }

    func testEveryUserOperationRespondsUnderPendingIOAndRetryHasNoStuckState() async throws {
        enum Operation: CaseIterable { case open, switchPage, hide, quit, delete, undo, redo, keepAsNew, save }
        for operation in Operation.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bounded-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
            let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID(), other = UUID()
            for noteID in [id, other] {
                guard case .success = store.createDocumentNote(id: noteID, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
            }
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
            controller.recoveryResponseTimeout = .milliseconds(60)
            await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            let session = try XCTUnwrap(controller.active)
            // Create real library Undo/Redo work, then suspend preservation of
            // the active draft so every operation encounters pending I/O.
            XCTAssertTrue(controller.deleteNote(noteID: other))
            if operation == .redo { XCTAssertTrue(controller.undoLibrary()) }
            XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Changed "), name: "Typing"))
            if operation == .keepAsNew {
                XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
                XCTAssertFalse(controller.save(session))
            }
            journal.blockWrites = true
            gate.shouldFail = true
            XCTAssertFalse(controller.preserve(session))
            try await waitFor { journal.writeStarted }
            func run() async -> Bool {
                switch operation {
                case .open: return await controller.openDurably(noteID: other)
                case .switchPage: return controller.prepareToLeave(.pageSwitch)
                case .hide: return controller.prepareToLeave(.hide)
                case .quit: return await controller.prepareToLeaveDurably(.quit)
                case .delete: return await controller.deleteNoteDurably(noteID: id)
                case .undo: return await controller.undoLibraryDurably()
                case .redo: return await controller.redoLibraryDurably()
                case .keepAsNew: return await controller.keepAsNewNoteDurably()
                case .save: return await controller.preserveDurably(session)
                }
            }
            let started = ContinuousClock.now
            let result = await run()
            XCTAssertLessThan(started.duration(to: .now), .seconds(1), "\(operation) responds within a bound")
            XCTAssertTrue(result || session.notice != nil, "\(operation) completes or asks with guidance")
            XCTAssertTrue(controller.active === session, "pending work never releases the live draft")
            journal.release()
            await controller.waitForRecoveryWork()
            gate.shouldFail = false
            // Re-open's target was intentionally deleted to create history.
            if operation == .open { XCTAssertTrue(controller.restoreDeletedNote(noteID: other, reopen: false)) }
            await XCTAssertTrueAsync(await run(), "\(operation) is not permanently refused after I/O completes")
            await controller.waitForRecoveryWork()
        }
    }

    func testDamagedRecoveryDetailsTolerateUnreadableEntriesAndPreserveOtherWarnings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Unreadable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        // A directory deterministically fails Data(contentsOf:) even when the
        // test runner has elevated permissions. It represents unreadable I/O.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(id.uuidString).json"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("staged/unreadable"), withIntermediateDirectories: true)
        try Data("readable".utf8).write(to: root.appendingPathComponent("staged/readable"))
        try Data("{damaged".utf8).write(to: root.appendingPathComponent("other.json"))
        let journal = NoteDraftJournal(directory: root)
        let details = try await journal.listDamagedDurably()
        XCTAssertEqual(details.count, 2, "one unreadable entry cannot abort discovery")
        let unreadable = try XCTUnwrap(details.first { $0.confirmation.noteID == id })
        XCTAssertFalse(unreadable.confirmation.canDiscard)
        XCTAssertTrue(unreadable.explanation.contains("Discard is unavailable"))
        XCTAssertTrue(unreadable.confirmation.unreadableItems.contains("staged/unreadable"))
        await XCTAssertThrowsErrorAsync(try await journal.archiveDamagedDurably(unreadable.confirmation, to: nil, resolving: true))
        let copy = try await journal.archiveDamagedDurably(unreadable.confirmation, to: root.appendingPathComponent("export"), resolving: false)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("staged/readable")), Data("readable".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id.uuidString).json").path))
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let failing = PendingWriteJournal(directory: root); failing.failRead = true
        let controller = NotesPageController(store: store, journal: failing)
        await controller.waitForRecoveryWork()
        let earlier = controller.recoveryWarnings
        XCTAssertFalse(earlier.isEmpty)
        await controller.refreshRecoveryWarningsAfterResolution()
        XCTAssertTrue(Set(earlier).isSubset(of: Set(controller.recoveryWarnings)))
    }

    func testVerifiedBytesCacheIsBoundedAndPayloadReadRunsOffMain() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        for i in 0..<80 { store.cacheVerifiedAttachment(stagedSized("\(i).bin", bytes: 600_000)) }
        XCTAssertLessThanOrEqual(store.verifiedAttachmentPayloads.count, NoteStore.verifiedPayloadCacheCountLimit)
        XCTAssertLessThanOrEqual(store.verifiedPayloadCacheBytes, NoteStore.verifiedPayloadCacheByteLimit)
        let item = staged(), id = UUID()
        let document = NoteDocument(blocks: [.text("File"), .file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: document, staged: [item]) else { return XCTFail() }
        store.clearVerifiedAttachmentCache()
        let recorder = PayloadThreadRecorder()
        NotePayloadDigest.observe { recorder.record($0, $1) }
        defer { NotePayloadDigest.observe(nil) }
        await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(item.id), item)
        XCTAssertFalse(recorder.snapshot.contains { $0.0 })
        let row = try XCTUnwrap(store.attachmentFamily(item.id).first)
        row.payload = Data("corrupt".utf8); try store.modelContext.save(); store.refresh()
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(item.id))
        await XCTAssertNilAsync(await store.verifiedAttachmentBytes(item.id))
    }
}

private final class LocateReadBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func observe(main: Bool, bytes: Int) {
        guard !main, bytes == 12_345 else { return }
        lock.lock(); let shouldWait = !entered; entered = true; lock.unlock()
        if shouldWait { _ = release.wait(timeout: .now() + 5) }
    }
    func resume() { release.signal() }
}

@MainActor
extension NoteSlice3bTests {
    func testLocateRejectsPlacementEditedDuringSuspendedByteVerification() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil)
        controller.start()
        let session = try XCTUnwrap(controller.active), item = stagedSized("locate.pdf", bytes: 12_345)
        session.engine.beginImageImport()
        XCTAssertTrue(session.engine.insertImportedObjects([.init(staged: item, pixelSize: nil)]))
        XCTAssertTrue(controller.save(session))
        let block = try XCTUnwrap(session.engine.document().blocks.first { $0.attachmentID == item.id })
        for row in try store.attachmentRows(forNoteID: session.noteID) { store.modelContext.delete(row) }
        try store.modelContext.save(); store.refresh()
        await store.waitForAttachmentReconciliation()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("StalePlacement-\(UUID()).pdf")
        try item.data.write(to: path)
        let barrier = LocateReadBarrier()
        defer { barrier.resume(); NotePayloadDigest.observe(nil); try? FileManager.default.removeItem(at: path) }
        NotePayloadDigest.observe { barrier.observe(main: $0, bytes: $1) }
        let locate = Task { @MainActor in await session.engine.perform(.locateAt(path), objectID: block.id!) }
        try await waitFor { barrier.started }
        await XCTAssertTrueAsync(await session.engine.perform(.delete, objectID: block.id!))
        let afterEdit = session.engine.document()
        barrier.resume()
        await XCTAssertFalseAsync(await locate.value)
        XCTAssertEqual(session.engine.document(), afterEdit)
        XCTAssertTrue(try store.attachmentRows(forNoteID: session.noteID).isEmpty, "a stale placement cannot reconstruct an attachment")
    }

    func testKeepAsNewSurfacesFailedRecoveryDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepNewDiscard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        let journal = OnDemandFailingJournal(NoteDraftJournal(directory: root))
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        XCTAssertFalse(controller.save(session))
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        journal.failNextRemove = true
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(session.noteID, id)
        XCTAssertEqual(session.notice, "Your text was saved, but its old recovery copy is being kept until it can be checked.")
        XCTAssertNotNil(store.note(withID: session.noteID))
        XCTAssertFalse(try journal.base.entries().isEmpty, "failed discard preserves recovery")
    }

    func testLiveCopyAndKeepAsNewSurviveVerifiedByteCacheEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LargeLiveCopy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let source = UUID(), dest = UUID(), items = (0..<3).map { stagedSized("\($0).pdf", bytes: 12 * 1_024 * 1_024) }
        let document = NoteDocument(blocks: [.text("Large live note")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        })
        guard case .success = store.createDocumentNote(id: source, document: document, staged: items),
              case .success = store.createDocumentNote(id: dest, document: NoteDocument(blocks: [.text("Destination")])) else { return XCTFail() }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root), saveDelay: .seconds(60))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: source))
        let session = try XCTUnwrap(controller.active)
        let fragment = try NoteContentCodec.encode(session.engine.fragment(for: NSRange(location: 0, length: session.engine.textStorage.length)), context: .fragment)
        store.clearVerifiedAttachmentCache()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: dest))
        let destination = try XCTUnwrap(controller.active)
        XCTAssertTrue(destination.engine.paste(fragmentData: fragment, at: NSRange(location: destination.engine.textStorage.length, length: 0)))
        XCTAssertEqual(destination.engine.document().attachmentIDs.count, 3, "bounded cache eviction cannot silently drop pasted objects")
        await XCTAssertTrueAsync(await controller.openDurably(noteID: source))
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: source))))
        XCTAssertFalse(controller.save(session))
        await XCTAssertTrueAsync(await controller.keepAsNewNoteDurably())
        XCTAssertNotEqual(session.noteID, source)
        XCTAssertEqual(store.loadDocument(noteID: session.noteID)?.content.document?.attachmentIDs.count, 3)
        XCTAssertLessThanOrEqual(store.verifiedPayloadCacheBytes, NoteStore.verifiedPayloadCacheByteLimit)
    }
}

@MainActor
extension NoteSlice3bTests {
    func testOpeningDuringPendingStartupIOGivesBoundedGuidanceAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendingStartup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root); journal.blockRead = true
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore()), id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Open me")])) else { return XCTFail() }
        let controller = NotesPageController(store: store, journal: journal)
        controller.recoveryResponseTimeout = .milliseconds(60)
        try await waitFor { journal.readStarted }
        let started = ContinuousClock.now
        await XCTAssertFalseAsync(await controller.openDurably(noteID: id))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertNil(controller.active)
        XCTAssertTrue(controller.recoveryWarnings.contains("Recovery data is still being saved. Try again when saving finishes."))
        journal.releaseRead()
        await controller.waitForRecoveryWork()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        XCTAssertEqual(controller.active?.noteID, id)
        XCTAssertFalse(controller.recoveryWarnings.contains("Recovery data is still being saved. Try again when saving finishes."))
    }
}

@MainActor
extension NoteSlice3bTests {
    func testDurableLeaveRefusesFailedQueuedCheckpointAndRetryCanSucceed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QueuedFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Retain me"), name: "Typing"))
        gate.shouldFail = true; journal.failNextWrite = true
        await XCTAssertFalseAsync(await controller.prepareToLeaveDurably(.hide), "queued acceptance is not a durable pass after write failure")
        XCTAssertTrue(controller.active === session)
        XCTAssertNotNil(session.notice)
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide), "retry succeeds once checkpoint I/O recovers")
        XCTAssertFalse(try journal.base.entries().isEmpty)
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.quit))
    }
}

// MARK: Fix round 6: per-note checkpoint retirement

@MainActor
extension NoteSlice3bTests {
    func testReviewerUnrelatedDamagedCheckpointDoesNotBlockDeletion() async throws {
        for damagedName in ["\(UUID().uuidString).json", "unknown.json"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("N1-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("damaged".utf8).write(to: root.appendingPathComponent(damagedName))
            let journal = NoteDraftJournal(directory: root)
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let note = try XCTUnwrap(store.create(title: "Delete me", body: "Saved"))
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
            await controller.startAndWait()
            await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: note.id), damagedName)
            XCTAssertNil(store.note(withID: note.id))
            await XCTAssertTrueAsync(await controller.undoLibraryDurably())
            await XCTAssertTrueAsync(await controller.redoLibraryDurably(), damagedName)
            XCTAssertNil(store.note(withID: note.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(damagedName).path))
        }
    }

    func testDamagedCheckpointForDeletedNoteRefusesWithExplanation() async throws {
        for unreadable in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("N1Own-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let note = try XCTUnwrap(store.create(title: "Keep me", body: "Saved"))
            let file = root.appendingPathComponent("\(note.id.uuidString).json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if unreadable { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
            else { try Data("damaged".utf8).write(to: file) }
            let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root), saveDelay: .seconds(60))
            await controller.startAndWait()
            await XCTAssertFalseAsync(await controller.deleteNoteDurably(noteID: note.id))
            XCTAssertNotNil(store.note(withID: note.id))
            XCTAssertTrue(controller.active?.notice?.contains("could not be handed off safely") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testRetirementProofExpiresWhenSameNoteWritesAnotherCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("N1Rewrite-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("unknown.json"))
        let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertEqual(journal.retirementRequests.filter { $0 == id }.count, 1)
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        XCTAssertTrue(try journal.base.entries().contains { $0.0.noteID == id })
        gate.shouldFail = false
        XCTAssertTrue(controller.save(session))
        await controller.waitForRecoveryWork()
        XCTAssertEqual(journal.retirementRequests.filter { $0 == id }.count, 2, "new checkpoint needs its own retirement")
        XCTAssertFalse(try journal.base.entries().contains { $0.0.noteID == id })
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
    }
}

// MARK: Fix round 6: attachment-family proofs

@MainActor
extension NoteSlice3bTests {
    func testProbe6SyncOpenCopyAfterPresentationReload() async throws {
        for (launchPresented, duplicate) in [(false, false), (false, true), (true, false), (true, true)] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let source = UUID(), dest = UUID(), item = staged()
            let document = NoteDocument(blocks: [.text("Source"), .file(attachmentID: item.id,
                filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
            guard case .success = store.createDocumentNote(id: source, document: document, staged: [item]),
                  case .success = store.createDocumentNote(id: dest, document: NoteDocument(blocks: [.text("Destination")])) else { return XCTFail() }
            let importOwner = try XCTUnwrap(store.create(title: "Panel import"))
            let suite = "R1-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("R1-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("import.txt")
            try Data("New file".utf8).write(to: url)
            defaults.set(source.uuidString, forKey: "notes.lastViewedNote.v2")
            let controller = NotesPageController(store: store, journal: nil, defaults: defaults, saveDelay: .seconds(60))
            if launchPresented { controller.start() } else { XCTAssertTrue(controller.open(noteID: source)) }
            let session = try XCTUnwrap(controller.active)
            await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(item.id), item)
            let fragment = try NoteContentCodec.encode(session.engine.fragment(for: NSRange(location: 0,
                length: session.engine.textStorage.length)), context: .fragment)
            XCTAssertTrue(controller.open(noteID: dest))
            let destination = try XCTUnwrap(controller.active)
            XCTAssertTrue(destination.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Edited "), name: "Typing"))
            XCTAssertTrue(controller.save(destination))
            let outcome = await store.importAttachments(.init(editorSession: .init(noteID: importOwner.id, generation: 1),
                origin: .note(importOwner.id), urls: [url]))
            guard case .imported = outcome else { return XCTFail("fixture import: \(outcome)") }
            XCTAssertNotNil(store.cachedVerifiedAttachmentBytes(item.id), "successful local reload preserves unrelated proof")
            if duplicate {
                XCTAssertTrue(controller.open(noteID: source))
                XCTAssertTrue(controller.duplicateNote(noteID: source))
                let copy = try XCTUnwrap(controller.active)
                let copiedID = try XCTUnwrap(copy.engine.document().attachmentIDs.first)
                XCTAssertNotEqual(copiedID, item.id)
                await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(copiedID)?.data, item.data)
            } else {
                XCTAssertTrue(destination.engine.paste(fragmentData: fragment, at: NSRange(location: destination.engine.textStorage.length, length: 0)))
                XCTAssertEqual(destination.engine.document().attachmentIDs.count, 1)
                XCTAssertNil(destination.notice)
            }
        }
    }

    func testLocateReloadPreservesOtherProofsButRollbackAndExternalRefreshClearThem() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID(), items = [staged("keep.pdf"), staged("locate.pdf")]
        let document = NoteDocument(blocks: [.text("Files")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        })
        guard case .success = store.createDocumentNote(id: id, document: document, staged: items) else { return XCTFail() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R1Locate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(items[1].filename)
        try items[1].data.write(to: url)
        for item in items { await XCTAssertNotNilAsync(await store.verifiedAttachmentBytes(item.id)) }
        await XCTAssertTrueAsync(await store.locateAttachment(try XCTUnwrap(store.attachmentFamily(items[1].id).first), at: url))
        XCTAssertNotNil(store.cachedVerifiedAttachmentBytes(items[0].id))
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[1].id), "Locate's payload write invalidates its own family")
        gate.shouldFail = true
        await XCTAssertFalseAsync(await store.locateAttachment(try XCTUnwrap(store.attachmentFamily(items[1].id).first), at: url))
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[0].id), "rollback keeps the full invalidation")
        gate.shouldFail = false
        await XCTAssertNotNilAsync(await store.verifiedAttachmentBytes(items[0].id))
        store.refresh()
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[0].id), "external refresh keeps the full invalidation")
    }

    func testReviewerSyncOpenCopyAfterUnrelatedSave() async throws {
        for (launchPresented, duplicate) in [(false, false), (false, true), (true, false), (true, true)] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let source = UUID(), dest = UUID(), item = staged()
            let document = NoteDocument(blocks: [.text("Source"), .file(attachmentID: item.id,
                filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
            guard case .success = store.createDocumentNote(id: source, document: document, staged: [item]),
                  case .success = store.createDocumentNote(id: dest, document: NoteDocument(blocks: [.text("Destination")])) else { return XCTFail() }
            let suite = "N2-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(source.uuidString, forKey: "notes.lastViewedNote.v2")
            let controller = NotesPageController(store: store, journal: nil, defaults: defaults, saveDelay: .seconds(60))
            if launchPresented { controller.start() } else { XCTAssertTrue(controller.open(noteID: source)) }
            let session = try XCTUnwrap(controller.active)
            XCTAssertEqual(session.noteID, source)
            await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(item.id), item)
            let fragment = try NoteContentCodec.encode(session.engine.fragment(for: NSRange(location: 0,
                length: session.engine.textStorage.length)), context: .fragment)
            XCTAssertTrue(controller.open(noteID: dest))
            let destination = try XCTUnwrap(controller.active)
            XCTAssertTrue(destination.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Edited "), name: "Typing"))
            XCTAssertTrue(controller.save(destination))
            XCTAssertNotNil(store.cachedVerifiedAttachmentBytes(item.id), "unrelated prose save preserves the family's proof")
            if duplicate {
                XCTAssertTrue(controller.open(noteID: source))
                XCTAssertTrue(controller.duplicateNote(noteID: source))
                let copy = try XCTUnwrap(controller.active)
                let copiedID = try XCTUnwrap(copy.engine.document().attachmentIDs.first)
                XCTAssertNotEqual(copiedID, item.id)
                await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(copiedID)?.data, item.data)
            } else {
                XCTAssertTrue(destination.engine.paste(fragmentData: fragment, at: NSRange(location: destination.engine.textStorage.length, length: 0)))
                XCTAssertEqual(destination.engine.document().attachmentIDs.count, 1)
            }
        }
    }

    func testAttachmentProofInvalidatesOnlyTouchedFamilyAndFreshPresentation() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let items = [staged(), staged()], id = UUID()
        let document = NoteDocument(blocks: [.text("Files")] + items.map {
            .file(attachmentID: $0.id, filename: $0.filename, contentTypeIdentifier: $0.contentTypeIdentifier, byteCount: $0.byteCount)
        })
        guard case .success = store.createDocumentNote(id: id, document: document, staged: items) else { return XCTFail() }
        for item in items { await XCTAssertNotNilAsync(await store.verifiedAttachmentBytes(item.id)) }
        let row = try XCTUnwrap(store.attachmentFamily(items[0].id).first)
        // Payload-only corruption deliberately keeps the old digest metadata.
        row.payload = Data("bad".utf8)
        XCTAssertTrue(store.commitStagedChanges())
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[0].id))
        XCTAssertNotNil(store.cachedVerifiedAttachmentBytes(items[1].id), "another family in the same note retains its proof")
        await XCTAssertNilAsync(await store.verifiedAttachmentBytes(items[0].id))
        row.payload = nil
        XCTAssertTrue(store.commitStagedChanges())
        guard case .success = store.saveDocument(noteID: id, document: document,
            baseRevisionID: store.loadDocument(noteID: id)?.revisionID, staged: [items[0]]) else { return XCTFail() }
        await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(items[0].id), items[0])
        store.refresh()
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[0].id), "fresh presentation requires new proof")
        await XCTAssertEqualAsync(await store.verifiedAttachmentBytes(items[0].id), items[0])
        await store.waitForAttachmentReconciliation()
        for replica in store.attachmentFamily(items[0].id) { store.modelContext.delete(replica) }
        XCTAssertTrue(store.commitStagedChanges())
        XCTAssertNil(store.cachedVerifiedAttachmentBytes(items[0].id))
        await XCTAssertNilAsync(await store.verifiedAttachmentBytes(items[0].id))
        store.refresh()
        await store.waitForAttachmentReconciliation()
    }

    func testAttachmentVerifierAcceptsUnrelatedSaveAndRejectsFamilyOrContextChange() async throws {
        enum Change: CaseIterable { case unrelated, payload, freshContext }
        for change in Change.allCases {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore()), item = stagedSized("proof.pdf", bytes: 12_345), id = UUID()
            let document = NoteDocument(blocks: [.text("Proof"), .file(attachmentID: item.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
            guard case .success = store.createDocumentNote(id: id, document: document, staged: [item]) else { return XCTFail() }
            await store.waitForAttachmentReconciliation()
            store.clearVerifiedAttachmentCache()
            let barrier = LocateReadBarrier()
            defer { barrier.resume(); NotePayloadDigest.observe(nil) }
            NotePayloadDigest.observe { barrier.observe(main: $0, bytes: $1) }
            let verification = Task { @MainActor in await store.verifiedAttachmentBytes(item.id) }
            try await waitFor { barrier.started }
            switch change {
            case .unrelated: XCTAssertNotNil(store.create(title: "Other", body: "Saved"))
            case .payload:
                try XCTUnwrap(store.attachmentFamily(item.id).first).payload = Data("bad".utf8)
                XCTAssertTrue(store.commitStagedChanges())
            case .freshContext: store.refresh()
            }
            barrier.resume()
            let result = await verification.value
            if change == .unrelated { XCTAssertEqual(result, item) }
            else { XCTAssertNil(result) }
            await store.waitForAttachmentReconciliation()
        }
    }
}

// MARK: Fix round 6: completed actions and bound Undo

@MainActor
extension NoteSlice3bTests {
    func testDurableDeleteReportsItsOwnOutcomeWhenUnrelatedQueuedRecoveryFails() async throws {
        for failure in ["unrelated", "retirement", "delete save"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("R3-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
            let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID(), other = UUID(), document = NoteDocument(blocks: [.text("Delete me")])
            guard case .success = store.createDocumentNote(id: id, document: document),
                  case .success = store.createDocumentNote(id: other, document: NoteDocument(blocks: [.text("Keep me")])) else { return XCTFail() }
            let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
            await XCTAssertTrueAsync(await controller.openDurably(noteID: other))
            let inactive = try XCTUnwrap(controller.active)
            XCTAssertTrue(inactive.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
            // An actual checkpoint forces Delete through its async retirement.
            _ = try journal.base.write(.init(noteID: id, isPersisted: true,
                baseRevisionID: store.note(withID: id)?.revisionID, content: try NoteContentCodec.encode(document),
                selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
            switch failure {
            case "unrelated":
                journal.afterRetirement = {
                    journal.afterRetirement = nil
                    gate.shouldFail = true; journal.failNextWrite = true
                    XCTAssertFalse(controller.preserve(inactive))
                    gate.shouldFail = false
                }
            case "retirement": journal.failRetirement = true
            default: gate.shouldFail = true
            }
            let deleted = await controller.deleteNoteDurably(noteID: id)
            XCTAssertEqual(deleted, failure == "unrelated", "report this delete's actual outcome")
            XCTAssertEqual(store.note(withID: id) == nil, deleted)
            XCTAssertNotNil(store.note(withID: other), "unrelated note is never deleted")
            if failure == "unrelated" {
                XCTAssertTrue(inactive.notice?.contains("Recovery could not be saved") == true, "the unrelated failure remains visible")
            }
            gate.shouldFail = false
            await controller.waitForRecoveryWork()
        }
    }

    func testSlowSuccessfulUndoDoesNotInviteRetryAndPendingWarningDrains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SlowSuccess-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root)
        var savesBeforeFailure: Int?
        let store = try makeTestNoteStore(persist: { context in
            if let remaining = savesBeforeFailure {
                if remaining == 0 { throw CocoaError(.fileWriteOutOfSpace) }
                savesBeforeFailure = remaining - 1
            }
            try context.save()
        }, attachmentFileStore: makeTestAttachmentFileStore())
        let first = UUID(), second = UUID()
        for id in [first, second] {
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        }
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        controller.recoveryResponseTimeout = .milliseconds(60)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: first))
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: first))
        await XCTAssertTrueAsync(await controller.openDurably(noteID: second))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
        // Restore commits, then its reopen must checkpoint the current draft.
        savesBeforeFailure = 1; journal.blockWrites = true
        await XCTAssertTrueAsync(await controller.undoLibraryDurably(), "the restore happened despite slow preservation")
        XCTAssertNotNil(store.note(withID: first))
        XCTAssertFalse(controller.recoveryWarnings.contains { $0.contains("Try again") })
        XCTAssertFalse(session.notice?.contains("Try again") == true)
        savesBeforeFailure = nil; journal.release()
        await controller.waitForRecoveryWork()
        XCTAssertFalse(controller.recoveryWarnings.contains { $0.contains("still being saved") })
        XCTAssertFalse(session.notice?.contains("still being saved") == true)
    }

    func testDeleteToastUndoRechecksItsStepAfterSuspendedWait() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToastStep-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Deleted", body: "Saved"))
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: note.id))
        let step = try XCTUnwrap(controller.libraryUndoStepID), session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft"), name: "Typing"))
        gate.shouldFail = true; journal.blockWrites = true
        XCTAssertFalse(controller.preserve(session))
        try await waitFor { journal.writeStarted }
        var result: Bool?
        let undo = Task { @MainActor in result = await controller.undoLibraryDurably(expectedStepID: step) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(result)
        gate.shouldFail = false
        let newer = try XCTUnwrap(store.create(title: "Newer", body: "Saved"))
        XCTAssertTrue(controller.setPinned(true, noteID: newer.id))
        let top = controller.libraryUndoStepID
        XCTAssertNotEqual(top, step)
        journal.release()
        await undo.value
        XCTAssertEqual(result, false)
        XCTAssertEqual(controller.libraryUndoStepID, top)
        XCTAssertNil(store.note(withID: note.id))
        XCTAssertTrue(try XCTUnwrap(store.note(withID: newer.id)).isPinned)
    }

    func testSavingWarningClearsWhenAnotherSessionsWriteFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WarningDrain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PendingWriteJournal(directory: root), gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let ids = [UUID(), UUID()]
        for id in ids {
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Saved")])) else { return XCTFail() }
        }
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60))
        controller.recoveryResponseTimeout = .milliseconds(60)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: ids[0]))
        let inactive = try XCTUnwrap(controller.active)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: ids[1]))
        let active = try XCTUnwrap(controller.active)
        XCTAssertTrue(inactive.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Draft "), name: "Typing"))
        gate.shouldFail = true; journal.blockWrites = true
        XCTAssertFalse(controller.preserve(inactive))
        try await waitFor { journal.writeStarted }
        await XCTAssertFalseAsync(await controller.deleteNoteDurably(noteID: ids[1]))
        XCTAssertTrue(active.notice?.contains("still being saved") == true)
        journal.release()
        await controller.waitForRecoveryWork()
        XCTAssertFalse(controller.recoveryWarnings.contains { $0.contains("still being saved") })
        XCTAssertFalse(active.notice?.contains("still being saved") == true)
        gate.shouldFail = false
    }

    func testSuccessfulOpenWithSlowHydrationDoesNotInviteRetry() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore()), item = stagedSized("slow.pdf", bytes: 12_345), id = UUID()
        let document = NoteDocument(blocks: [.text("Open"), .file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        guard case .success = store.createDocumentNote(id: id, document: document, staged: [item]) else { return XCTFail() }
        await store.waitForAttachmentReconciliation()
        store.clearVerifiedAttachmentCache()
        let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(60))
        controller.recoveryResponseTimeout = .milliseconds(60)
        let barrier = AllPayloadReadBarrier()
        defer { barrier.resume(); NotePayloadDigest.observe(nil) }
        NotePayloadDigest.observe { barrier.observe(main: $0, bytes: $1) }
        let open = Task { @MainActor in await controller.openDurably(noteID: id) }
        try await waitFor { barrier.started }
        await XCTAssertTrueAsync(await open.value)
        XCTAssertEqual(controller.active?.noteID, id)
        XCTAssertTrue(controller.recoveryWarnings.contains("Attachment data is still being read."))
        XCTAssertFalse(controller.recoveryWarnings.contains { $0.contains("Try again") })
        barrier.resume()
        try await waitFor { !controller.recoveryWarnings.contains("Attachment data is still being read.") }
        XCTAssertFalse(controller.active?.notice?.contains("still being read") == true)
    }
}

// MARK: Fix round 6: retention decoding

@MainActor
extension NoteSlice3bTests {
    func testRetentionRetriesAfterUnrelatedSaveAndFinishesTheRequestedCleanup() async throws {
        let files = makeTestAttachmentFileStore(), store = try makeTestNoteStore(attachmentFileStore: files), item = staged(), id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Owner")])) else { return XCTFail() }
        await store.waitForAttachmentReconciliation()
        let reference = AttachmentFileReference(id: item.id, digest: item.digest, filename: item.filename, payload: item.data)
        let url = try XCTUnwrap(try await files.ensureMaterialized(reference))
        let barrier = LocateReadBarrier(), recorder = PayloadThreadRecorder()
        defer { barrier.resume(); store.retentionDecodeObserver = nil }
        store.retentionDecodeObserver = {
            recorder.record(Thread.isMainThread, 1)
            barrier.observe(main: Thread.isMainThread, bytes: 12_345)
        }
        let removal = Task { try await files.removeMaterializations([reference]) }
        try await waitFor { barrier.started }
        XCTAssertNotNil(store.create(title: "Unrelated save"))
        barrier.resume()
        try await removal.value
        XCTAssertGreaterThanOrEqual(recorder.snapshot.count, 2, "the stale pass was retried")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "cleanup completes without a second sweep request")
    }

    func testRetentionProviderDecodesEveryDocumentOwnerOffMain() async throws {
        let files = makeTestAttachmentFileStore(), store = try makeTestNoteStore(attachmentFileStore: files), item = staged(), id = UUID()
        await store.waitForAttachmentReconciliation()
        let document = NoteDocument(blocks: [.text("Owner"), .file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        let data = try NoteContentCodec.encode(document)
        let note = NoteItem(id: id, title: "Owner", body: "", createdAt: Date(), updatedAt: Date())
        note.contentFormat = 1; note.content = data
        store.modelContext.insert(note)
        store.modelContext.insert(NoteVersion(noteID: id, createdAt: Date(), reason: .leave, content: data,
            contentFormat: 1, title: "Owner", body: "", attachmentIDs: [], sourceRevisionID: nil))
        store.modelContext.insert(NotePendingEdit(noteID: id, baseRevisionToken: "base", proposedContent: data, agentName: "Agent", createdAt: Date()))
        XCTAssertTrue(store.commitStagedChanges())
        let reference = AttachmentFileReference(id: item.id, digest: item.digest, filename: item.filename, payload: item.data)
        let materialized = try await files.ensureMaterialized(reference)
        let url = try XCTUnwrap(materialized)
        let recorder = PayloadThreadRecorder()
        store.retentionDecodeObserver = { recorder.record(Thread.isMainThread, 1) }
        try await files.removeMaterializations([reference])
        XCTAssertEqual(recorder.snapshot.count, 3, "note, version without cached IDs, and proposal")
        XCTAssertFalse(recorder.snapshot.contains { $0.0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.retentionDecodeObserver = nil
    }

    func testRetentionRefusesDestructionWhenStoreChangesDuringDecoding() async throws {
        let files = makeTestAttachmentFileStore(), store = try makeTestNoteStore(attachmentFileStore: files), item = staged(), id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Initial")])) else { return XCTFail() }
        await store.waitForAttachmentReconciliation()
        let reference = AttachmentFileReference(id: item.id, digest: item.digest, filename: item.filename, payload: item.data)
        let materialized = try await files.ensureMaterialized(reference), url = try XCTUnwrap(materialized)
        let barrier = LocateReadBarrier()
        defer { barrier.resume(); store.retentionDecodeObserver = nil }
        store.retentionDecodeObserver = { barrier.observe(main: Thread.isMainThread, bytes: 12_345) }
        let removal = Task { try await files.removeMaterializations([reference]) }
        try await waitFor { barrier.started }
        let document = NoteDocument(blocks: [.text("New owner"), .file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        store.modelContext.insert(NoteVersion(noteID: id, createdAt: Date(), reason: .leave,
            content: try NoteContentCodec.encode(document), contentFormat: 1, title: "New owner", body: "",
            attachmentIDs: [], sourceRevisionID: nil))
        XCTAssertTrue(store.commitStagedChanges())
        barrier.resume()
        try await removal.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "stale aggregate inventory cannot authorize removal")
        store.retentionDecodeObserver = nil
        try await files.removeMaterializations([reference])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the newly saved version owns these bytes")
    }
}

/// Hydration and availability may verify the same family concurrently. Hold
/// every matching reader so neither can warm the other's cache prematurely.
private final class AllPayloadReadBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func observe(main: Bool, bytes: Int) {
        guard !main, bytes == 12_345 else { return }
        condition.lock(); defer { condition.unlock() }
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while !released { if !condition.wait(until: deadline) { break } }
    }
    func resume() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}
