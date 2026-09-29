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
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws {
        if failNextWrite { failNextWrite = false; throw Failure() }
        try base.write(entry, staged: staged)
    }
    func remove(noteID: UUID) throws {
        if failNextRemove { failNextRemove = false; throw Failure() }
        try base.remove(noteID: noteID)
    }
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] { try base.entries() }
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

    func testFileFormatRoundTripAndCapabilityGate() throws {
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

    func testMixedBatchUsesOneUndoStepAndStableAnchor() {
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

    func testCancelledBatchChangesNeitherDocumentNorStaging() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("body")]))
        let before = engine.document()
        engine.beginImageImport()
        engine.cancelImageImport()
        XCTAssertFalse(engine.insertImportedObjects([NoteImportedObject(staged: staged(), pixelSize: nil)]))
        XCTAssertEqual(engine.document(), before)
    }

    func testUnsupportedImageBytesUseFileCardAndFailureCardSurvivesRoundTrip() throws {
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

    func testReservedImageSpaceAndFractionSurviveColumnChange() {
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

    func testStoreDerivedCountsAndRecentlyDeletedRetention() throws {
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

    func testOversizedStoredBatchDoesNotChangeDocumentOrCreateRows() throws {
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

    func testPrintViewHasObjectsAndMultiplePages() throws {
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

    func testAgentTextPreservesFilesAndRejectsObjectLoss() throws {
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

    func testAgentToolListsFilesAndKeepsThemThroughTextUpdate() throws {
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

    func testStagedBatchRecoversAfterRestart() throws {
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
        try journal.write(entry, staged: [item])
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
        restarted.start()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: noteID)?.content.document)
        XCTAssertEqual(recovered.blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(recovered.attachmentIDs, [item.id])
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
    }

    func testCancelledAndInterruptedStagingFilesAreCollected() throws {
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
        try journal.write(entry([item]), staged: [item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
        try journal.write(entry([]), staged: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path))
        try item.data.write(to: stagedFile)
        _ = try journal.recoveryEntries()
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
        XCTAssertTrue(controller.open(noteID: noteID))
        controller.importFiles([URL(fileURLWithPath: "/tmp/photo.png")])
        XCTAssertTrue(controller.active?.isImporting == true)
        XCTAssertTrue(controller.prepareToLeave(.hide))
        XCTAssertTrue(controller.active?.isImporting == true)
        XCTAssertNotNil(try NoteDraftJournal(directory: directory).entries().first?.0.pendingImport)
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
            imageLoader: { await loader.load($0) })
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
            acceptedText: "accepted", at: NSRange(location: 5, length: 0))
        XCTAssertEqual(try journal.entries().first?.0.pendingImport?.items.count, 0,
            "the first source is checkpointed before loading")
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: "\ntyped"), name: "Typing"))
        await controller.runDueSave(session)
        let checkpoint = try XCTUnwrap(journal.entries().first?.0)
        XCTAssertEqual(checkpoint.pendingImport?.items.count, 1)
        XCTAssertTrue(NoteTextExport.plainText(try XCTUnwrap(NoteContentCodec.decode(checkpoint.content).document)).contains("typed"))
        XCTAssertTrue(controller.preserveAll(), "background hide and quit include clean pending batches")
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        restarted.start()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
        XCTAssertEqual(recovered.blocks.filter { $0.kind == .image }.count, 1)
        await loader.release()
    }

    func testR1FailedCancellationKeepsPendingCheckpointAndBatch() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticR1Cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OnDemandFailingJournal(NoteDraftJournal(directory: directory))
        let loader = TwoSourceLoader(first: try stagedImage(), second: try stagedImage())
        let controller = NotesPageController(store: store, journal: journal, saveDelay: .seconds(60),
            imageLoader: { await loader.load($0) })
        controller.start()
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        journal.failNextRemove = true
        controller.cancelActiveImport()
        XCTAssertTrue(controller.active?.isImporting == true)
        XCTAssertNotNil(try journal.entries().first?.0.pendingImport)
        XCTAssertTrue(controller.active?.notice?.contains("could not be cancelled") == true)
        await loader.release()
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
        XCTAssertTrue(controller.open(noteID: id))
        controller.importFiles([URL(fileURLWithPath: "/tmp/first.png")], acceptedText: "accepted",
            at: NSRange(location: 4, length: 0))
        XCTAssertTrue(controller.prepareToLeave(.hide))
        let pending = try XCTUnwrap(journal.entries().first?.0.pendingImport)
        XCTAssertEqual(pending.remainingNames, ["first.png"])
        let restarted = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory))
        restarted.start()
        let recovered = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        XCTAssertTrue(NoteTextExport.plainText(recovered).contains("accepted"))
        XCTAssertTrue(recovered.blocks.contains { $0.importFailure?.contains("interrupted") == true })
        await loader.release()
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
        controller.start()
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "Draft"), name: "Typing"))
        controller.importFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")],
            acceptedText: "accepted", at: NSRange(location: 5, length: 0))
        try await waitFor { try journal.entries().first?.0.pendingImport?.items.count == 1 }
        journal.failNextWrite = true
        XCTAssertFalse(controller.preserveAll())
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
    }

    func testR3RecentlyDeletedRestoresInlinePlacementAcrossSaveAndLibraryHistory() throws {
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
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let objectID = try XCTUnwrap(original.blocks[1].id)
        let deleted = await session.engine.perform(.delete, objectID: objectID)
        XCTAssertTrue(deleted)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertTrue(session.engine.history.undo())
        XCTAssertEqual(session.engine.objectState(objectID), .ready)
        gate.shouldFail = true
        XCTAssertTrue(controller.preserveAll(), "the failed Undo save is checkpointed")
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
        XCTAssertTrue(controller.open(noteID: id))
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
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let deleted = await session.engine.perform(.delete, objectID: try XCTUnwrap(doc.blocks[1].id))
        XCTAssertTrue(deleted)
        XCTAssertTrue(controller.preserveAll())
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
        XCTAssertTrue(controller.open(noteID: id))
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
        XCTAssertTrue(controller.open(noteID: id))
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
        XCTAssertTrue(controller.open(noteID: id))
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
        try await waitFor { session.isImporting == false }
        XCTAssertEqual(session.engine.document().attachmentIDs.count, 19)
        XCTAssertEqual(session.engine.document().blocks.filter { $0.kind == .image }.count, 1)
    }

    func testR7CapturedPasteRangeAndDropBoundarySurviveTypingAndUndo() {
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
        controller.start()
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
        XCTAssertTrue(controller.open(noteID: id))
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

    func testR10TallImageFitsPrintablePageAndRenderedPDFPaginates() throws {
        // An opaque red PNG makes an actually rendered object observable in
        // the resulting PDF, including its page boundary.
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP8z4AdMOEQH6QSAM1BAQ/oQeJvAAAAAElFTkSuQmCC"))
        let imageID = UUID()
        let tall = NoteBlock.image(attachmentID: imageID, widthFraction: 1,
            pixelWidth: 1_000, pixelHeight: 20_000)
        let text = String(repeating: "Paragraph before image. ", count: 180)
        let doc = NoteDocument(blocks: [.text("Print"), .text(text), tall, .text("after image")])
        let thumbnail = try XCTUnwrap(NoteImageDecoder.thumbnail(of: imageData, maxPixel: 64))
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
        let pagesWithImage = (0..<pdf.pageCount).filter { index in
            guard let page = pdf.page(at: index)?.pageRef else { return false }
            let width = 612, height = 792
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            return pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.drawPDFPage(page)
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in stride(from: 0, to: height, by: 2) {
                    for x in stride(from: 0, to: width, by: 2) {
                        let offset = (y * width + x) * 4
                        if bytes[offset] > 200 && bytes[offset + 1] < 80 && bytes[offset + 2] < 80 {
                            return true
                        }
                    }
                }
                return false
            }
        }
        XCTAssertEqual(pagesWithImage.count, 1, "the tall image is rendered whole on one PDF page")
    }
}
