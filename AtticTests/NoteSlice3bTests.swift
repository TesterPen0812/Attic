import AppKit
import CryptoKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class NoteSlice3bTests: XCTestCase {
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
        guard case .failure(.invalidDocument) = store.saveDocument(noteID: noteID, document: updated,
            baseRevisionID: revision, staged: [invalid]) else { return XCTFail("must reject") }
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
}
