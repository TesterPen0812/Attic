import AppKit
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Attic

final class NoteAttachmentTests: XCTestCase {
    @MainActor
    func testEditorReadabilityChangesGlyphAttributesWithoutChangingTextOrSelection() {
        let textView = NSTextView()
        textView.string = "Draft body"
        textView.selectedRange = NSRange(location: 5, length: 0)

        AttachmentAwareTextEditor.applyReadability(
            to: textView,
            enabled: true,
            colorScheme: .dark
        )

        XCTAssertEqual(textView.string, "Draft body")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertNotNil(textView.textStorage?.attribute(
            .shadow,
            at: 0,
            effectiveRange: nil
        ))
        XCTAssertNotNil(textView.typingAttributes[.shadow])

        AttachmentAwareTextEditor.applyReadability(
            to: textView,
            enabled: false,
            colorScheme: .dark
        )

        XCTAssertEqual(textView.string, "Draft body")
        XCTAssertNil(textView.textStorage?.attribute(
            .shadow,
            at: 0,
            effectiveRange: nil
        ))
        XCTAssertNil(textView.typingAttributes[.shadow])
    }

    func testEditorReadabilitySkipsFullRangeWorkForUnchangedTypingState() {
        XCTAssertFalse(AttachmentAwareTextEditor.needsReadabilityApplication(
            lastEnabled: true,
            lastColorScheme: .dark,
            enabled: true,
            colorScheme: .dark,
            externalTextWasReplaced: false
        ))
        XCTAssertTrue(AttachmentAwareTextEditor.needsReadabilityApplication(
            lastEnabled: true,
            lastColorScheme: .dark,
            enabled: true,
            colorScheme: .dark,
            externalTextWasReplaced: true
        ))
        XCTAssertTrue(AttachmentAwareTextEditor.needsReadabilityApplication(
            lastEnabled: true,
            lastColorScheme: .dark,
            enabled: false,
            colorScheme: .dark,
            externalTextWasReplaced: false
        ))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeStoreImportRequest(
        from urls: [URL],
        noteID: UUID? = nil,
        blankNoteID: UUID = UUID(),
        generation: UInt64 = 1
    ) -> NoteAttachmentImportRequest {
        NoteAttachmentImportRequest(
            editorSession: NoteEditorSession(
                noteID: noteID,
                generation: generation
            ),
            origin: noteID.map(NoteAttachmentImportOrigin.note)
                ?? .blankDraft(blankNoteID),
            urls: urls
        )
    }

    private func importedNoteID(from outcome: NoteAttachmentImportOutcome) -> UUID? {
        guard case let .imported(noteID) = outcome else { return nil }
        return noteID
    }

    func testImportPreservesFinderOrderAndDuplicateFilenames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceA = try write(Data("first".utf8), named: "same.txt", in: directory)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let sourceB = try write(Data("second".utf8), named: "same.txt", in: secondDirectory)
        let root = directory.appendingPathComponent("owned", isDirectory: true)
        let fileStore = AttachmentFileStore(rootURL: root)

        let imported = try await fileStore.importFiles(
            [sourceA, sourceB],
            baseSortIndex: 7,
            existingCount: 0,
            existingBytes: 0
        )

        XCTAssertEqual(imported.map(\.filename), ["same.txt", "same.txt"])
        XCTAssertEqual(imported.map(\.sortIndex), [7, 8])
        XCTAssertNotEqual(imported[0].digest, imported[1].digest)
        for item in imported {
            let reference = AttachmentFileReference(
                id: item.id,
                digest: item.digest,
                filename: item.filename,
                payload: item.payload
            )
            let url = try await fileStore.materializedURL(for: reference)
            XCTAssertEqual(try Data(contentsOf: url), item.payload)
        }
    }

    func testImportReportsProgressAfterEveryCompletedFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try (0..<3).map { index in
            try write(Data("file-\(index)".utf8), named: "\(index).txt", in: directory)
        }
        let recorder = AttachmentProgressRecorder()
        let fileStore = AttachmentFileStore(
            rootURL: directory.appendingPathComponent("owned", isDirectory: true)
        )

        _ = try await fileStore.importFiles(
            sources,
            baseSortIndex: 0,
            existingCount: 0,
            existingBytes: 0
        ) { completed, total in
            await recorder.record(completed: completed, total: total)
        }

        let recordedProgress = await recorder.values
        XCTAssertEqual(
            recordedProgress,
            [
                AttachmentProgress(completed: 1, total: 3),
                AttachmentProgress(completed: 2, total: 3),
                AttachmentProgress(completed: 3, total: 3)
            ]
        )
    }

    func testImportRejectsDirectoriesAndSymbolicLinks() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try write(Data("safe".utf8), named: "safe.txt", in: directory)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))

        do {
            _ = try await fileStore.importFiles([folder], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
            XCTFail("A directory must be rejected")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .notAFile(folder.standardizedFileURL))
        }

        do {
            _ = try await fileStore.importFiles([link], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
            XCTFail("A symbolic link must be rejected")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .notAFile(link.standardizedFileURL))
        }
    }

    func testImportEnforcesPerFileAggregateAndCountLimits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let source = try write(Data("small".utf8), named: "small.txt", in: directory)

        do {
            _ = try await fileStore.importFiles(
                [source],
                baseSortIndex: 0,
                existingCount: AttachmentLimits.maxAttachmentsPerNote,
                existingBytes: 0
            )
            XCTFail("The count limit must be enforced")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .tooManyAttachments)
        }

        do {
            _ = try await fileStore.importFiles(
                [source],
                baseSortIndex: 0,
                existingCount: 0,
                existingBytes: AttachmentLimits.maxBytesPerNote
            )
            XCTFail("The aggregate limit must be enforced")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .noteTooLarge)
        }

        let oversized = try write(
            Data(repeating: 7, count: Int(AttachmentLimits.maxBytesPerAttachment + 1)),
            named: "oversized.bin",
            in: directory
        )
        do {
            _ = try await fileStore.importFiles([oversized], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
            XCTFail("The per-file limit must be enforced")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .attachmentTooLarge(oversized.standardizedFileURL, AttachmentLimits.maxBytesPerAttachment + 1))
        }
    }

    func testCancelledImportDoesNotCreateOwnedFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("cancelled".utf8), named: "cancelled.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let task = Task { try await fileStore.importFiles([source], baseSortIndex: 0, existingCount: 0, existingBytes: 0) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled import must not complete")
        } catch is CancellationError {
            // Expected: cancellation is checked before staging begins.
        }

        let rootContents = (try? await fileStore.rootURLContentsForTests()) ?? []
        XCTAssertEqual(rootContents.filter { ![".staging", "Thumbnails"].contains($0.lastPathComponent) }.count, 0)
    }

    func testMixedBatchFailureRollsBackEarlierMaterializations() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try write(Data("valid".utf8), named: "valid.txt", in: directory)
        let missing = directory.appendingPathComponent("missing.txt")
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))

        do {
            _ = try await fileStore.importFiles(
                [valid, missing],
                baseSortIndex: 0,
                existingCount: 0,
                existingBytes: 0
            )
            XCTFail("A mixed batch with an inaccessible file must fail")
        } catch let error as AttachmentFileStoreError {
            guard case .inaccessible = error else {
                return XCTFail("Expected an inaccessible-file error")
            }
        }

        let children = try await fileStore.rootURLContentsForTests()
        XCTAssertEqual(
            children.filter { ![".staging", "Thumbnails"].contains($0.lastPathComponent) }.count,
            0
        )
    }

    func testReconcileRemovesOnlyUnreferencedMaterializations() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("kept".utf8), named: "kept.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let imported = try await fileStore.importFiles(
            [source],
            baseSortIndex: 0,
            existingCount: 0,
            existingBytes: 0
        )
        let item = try XCTUnwrap(imported.first)
        let reference = AttachmentFileReference(
            id: item.id,
            digest: item.digest,
            filename: item.filename,
            byteCount: item.byteCount,
            payload: item.payload
        )
        let orphanID = UUID()
        let orphan = directory.appendingPathComponent("owned").appendingPathComponent(orphanID.uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try await fileStore.reconcile([reference])

        let materialized = try await fileStore.materializedURL(for: reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materialized.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testMetadataReconciliationDoesNotRequirePayloadForValidFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("already-valid".utf8), named: "valid.txt", in: directory)
        let fileStore = AttachmentFileStore(
            rootURL: directory.appendingPathComponent("owned", isDirectory: true)
        )
        let imported = try await fileStore.importFiles(
            [source],
            baseSortIndex: 0,
            existingCount: 0,
            existingBytes: 0
        )
        let item = try XCTUnwrap(imported.first)
        let metadata = AttachmentFileReference(
            id: item.id,
            digest: item.digest,
            filename: item.filename,
            byteCount: item.byteCount,
            payload: nil
        )

        let report = try await fileStore.reconcileMetadata([metadata])

        XCTAssertTrue(report.needsMaterialization.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testOnDemandAccessRepairsSameSizeContentCorruption() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("original".utf8)
        let source = try write(payload, named: "valid.txt", in: directory)
        let fileStore = AttachmentFileStore(
            rootURL: directory.appendingPathComponent("owned", isDirectory: true)
        )
        let imported = try await fileStore.importFiles(
            [source],
            baseSortIndex: 0,
            existingCount: 0,
            existingBytes: 0
        )
        let item = try XCTUnwrap(imported.first)
        let reference = AttachmentFileReference(
            id: item.id,
            digest: item.digest,
            filename: item.filename,
            byteCount: item.byteCount,
            payload: item.payload
        )
        let materialized = try await fileStore.materializedURL(for: reference)
        try Data("tampered".utf8).write(to: materialized)

        let repairedValue = try await fileStore.ensureMaterialized(reference)
        let repaired = try XCTUnwrap(repairedValue)

        XCTAssertEqual(try Data(contentsOf: repaired), payload)
    }

    func testMalformedReplicaDoesNotAbortValidRepairOrOrphanCleanup() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("owned", isDirectory: true)
        let fileStore = AttachmentFileStore(rootURL: root)
        let payload = Data("repair-me".utf8)
        let valid = AttachmentFileReference(
            id: UUID(),
            digest: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            filename: "repair.txt",
            byteCount: Int64(payload.count),
            payload: nil
        )
        let malformed = AttachmentFileReference(
            id: UUID(),
            digest: "not-a-digest",
            filename: "broken.txt",
            byteCount: 10,
            payload: nil
        )
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let report = try await fileStore.reconcileMetadata([malformed, valid])

        XCTAssertEqual(report.failures.map(\.attachmentID), [malformed.id])
        XCTAssertEqual(report.needsMaterialization.map(\.id), [valid.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        let repairFailures = await fileStore.repairMaterializations([
            AttachmentFileReference(
                id: valid.id,
                digest: valid.digest,
                filename: valid.filename,
                byteCount: valid.byteCount,
                payload: payload
            )
        ])
        XCTAssertTrue(repairFailures.isEmpty)
        let repairedURL = try await fileStore.materializedURL(for: valid)
        XCTAssertEqual(try Data(contentsOf: repairedURL), payload)
    }

    func testPromisedFileBatchTimesOutOnceAndRemovesTemporaryDirectory() async throws {
        let directory = try makeDirectory()
        let completion = expectation(description: "promise batch times out")
        let results = PromisedFileResultRecorder()
        let batch = PromisedFileBatch(
            expectedCount: 2,
            destination: directory,
            timeout: 0.05
        ) { result in
            results.record(result)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(results.completionCount, 1)
        guard case let .failure(message) = try XCTUnwrap(results.latest) else {
            return XCTFail("A timed-out promise batch must fail")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("timed out"))

        batch.record(index: 0, url: directory.appendingPathComponent("late.txt"), error: nil)
        XCTAssertEqual(results.completionCount, 1)
    }

    func testSourceCanDisappearAfterImportAndMissingMaterializationIsRebuilt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("independent".utf8), named: "note.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let imported = try await fileStore.importFiles([source], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
        let item = try XCTUnwrap(imported.first)
        let reference = AttachmentFileReference(
            id: item.id,
            digest: item.digest,
            filename: item.filename,
            byteCount: item.byteCount,
            payload: item.payload
        )
        let materialized = try await fileStore.materializedURL(for: reference)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: materialized.deletingLastPathComponent())

        let rebuiltOptional = try await fileStore.ensureMaterialized(reference)
        let rebuilt = try XCTUnwrap(rebuiltOptional)
        XCTAssertEqual(try Data(contentsOf: rebuilt), Data("independent".utf8))
    }

    func testMaterializedPathConfinesUntrustedFilenameToAttachmentDirectory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data("confined".utf8)
        let source = try write(payload, named: "source.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let imported = try await fileStore.importFiles(
            [source],
            baseSortIndex: 0,
            existingCount: 0,
            existingBytes: 0
        )
        let item = try XCTUnwrap(imported.first)
        let reference = AttachmentFileReference(
            id: item.id,
            digest: item.digest,
            filename: "../../outside.txt",
            byteCount: item.byteCount,
            payload: payload
        )

        let materialized = try await fileStore.materializedURL(for: reference)
        XCTAssertTrue(
            materialized.path.hasPrefix(
                directory.appendingPathComponent("owned").standardizedFileURL.path + "/"
            )
        )
        XCTAssertEqual(materialized.lastPathComponent, ".._.._outside.txt")
        let ensured = try await fileStore.ensureMaterialized(reference)
        XCTAssertEqual(ensured, materialized)
        XCTAssertEqual(try Data(contentsOf: materialized), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("outside.txt").path
            )
        )
    }

    func testPasteboardRouterAcceptsFileURLsButLeavesPlainPathsAsText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "AtticAttachmentPasteboard-\(UUID().uuidString)"
        ))
        try XCTUnwrap(pasteboard).clearContents()
        let pasteboardValue = try XCTUnwrap(pasteboard)

        pasteboardValue.setString(
            "/Users/example/notes.txt",
            forType: .string
        )
        XCTAssertTrue(NoteAttachmentPasteboardRouter.fileURLs(from: pasteboardValue).isEmpty)
        XCTAssertFalse(NoteAttachmentPasteboardRouter.prefersAttachments(pasteboardValue))

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("drop".utf8), named: "drop.txt", in: directory)
        pasteboardValue.clearContents()
        XCTAssertTrue(pasteboardValue.writeObjects([source as NSURL]))

        XCTAssertEqual(
            NoteAttachmentPasteboardRouter.fileURLs(from: pasteboardValue),
            [source.standardizedFileURL]
        )
        XCTAssertTrue(NoteAttachmentPasteboardRouter.prefersAttachments(pasteboardValue))
    }

    @MainActor
    func testAttachmentOnlyNotePersistsAndOrdersAttachments() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceA = try write(Data("A".utf8), named: "a.txt", in: directory)
        let sourceB = try write(Data("B".utf8), named: "b.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let store = try makeTestNoteStore(attachmentFileStore: fileStore)

        let outcome = await store.importAttachments(
            makeStoreImportRequest(from: [sourceA, sourceB])
        )
        let noteIDValue = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.id, noteIDValue)
        XCTAssertEqual(store.attachments(for: noteIDValue).map(\.originalFilename), ["a.txt", "b.txt"])
        XCTAssertEqual(store.notes.first?.body, "")
    }

    @MainActor
    func testDraftAdoptsAttachmentOnlyNoteWithoutLosingEditorSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("image-payload".utf8), named: "reference.png", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let store = try makeTestNoteStore(attachmentFileStore: fileStore)
        let draft = NoteDraftController(noteStore: store)

        XCTAssertTrue(draft.beginNew())
        let initiatingSession = draft.editorSession
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let outcome = await store.importAttachments(request)
        let noteID = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .adopted(noteID: noteID)
        )

        XCTAssertTrue(draft.isActive)
        XCTAssertEqual(draft.editorSession, initiatingSession)
        XCTAssertEqual(draft.activeNoteID, noteID)
        XCTAssertFalse(draft.isDirty)
        XCTAssertTrue(draft.canPersist)
        XCTAssertEqual(store.attachments(for: noteID).count, 1)

        draft.body = "Typed after attachment completion"
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, "Typed after attachment completion")
    }

    @MainActor
    func testBlankDraftAttachmentCompletionPreservesTypingMadeAfterImportInitiation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(
            Data("slow-import".utf8),
            named: "reference.txt",
            in: directory
        )
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            )
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let initiatingSession = draft.editorSession
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }

        draft.body = "Typing while the attachment is importing"
        let outcome = await importTask.value
        let importedNoteID = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(draft.editorSession, initiatingSession)

        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .adopted(noteID: importedNoteID)
        )

        XCTAssertEqual(draft.body, "Typing while the attachment is importing")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.activeNoteID, importedNoteID)
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, "Typing while the attachment is importing")
        XCTAssertEqual(store.attachments(for: importedNoteID).map(\.originalFilename), [
            "reference.txt"
        ])
    }

    @MainActor
    func testBlankDraftAttachmentCompletionUsesAutosavedOriginInsteadOfSplittingNote() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("attachment".utf8), named: "autosave.txt", in: directory)
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            )
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }

        draft.body = "Autosaved while importing"
        XCTAssertTrue(draft.flush())
        let autosavedNoteID = try XCTUnwrap(draft.activeNoteID)
        let outcome = await importTask.value
        let importedNoteID = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .adopted(noteID: importedNoteID)
        )

        XCTAssertEqual(importedNoteID, autosavedNoteID)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, "Autosaved while importing")
        XCTAssertEqual(store.attachments(for: autosavedNoteID).map(\.originalFilename), [
            "autosave.txt"
        ])
    }

    @MainActor
    func testAutosaveWhileBlankImportIsSuspendedUsesReservedOrigin() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("attachment".utf8), named: "autosave.txt", in: directory)
        let importer = ControlledNoteAttachmentImporter()
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            ),
            attachmentImporter: importer
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        guard case let .blankDraft(reservedNoteID) = request.origin else {
            return XCTFail("A blank import must reserve an immutable origin identity")
        }
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }
        _ = await importer.waitUntilStarted()

        draft.body = "Autosaved while the import is suspended"
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(draft.activeNoteID, reservedNoteID)
        XCTAssertEqual(store.notes.map(\.id), [reservedNoteID])

        await importer.succeed()
        let outcome = await importTask.value
        XCTAssertEqual(outcome, .imported(noteID: reservedNoteID))
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .adopted(noteID: reservedNoteID)
        )

        XCTAssertEqual(draft.body, "Autosaved while the import is suspended")
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, "Autosaved while the import is suspended")
        XCTAssertEqual(store.attachments(for: reservedNoteID).map(\.originalFilename), [
            "autosave.txt"
        ])
    }

    @MainActor
    func testAutosaveAfterBlankImportPersistsBeforeDraftCompletionReusesReservedOrigin() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("attachment".utf8), named: "completed.txt", in: directory)
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            )
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let outcome = await store.importAttachments(request)
        let reservedNoteID = request.origin.noteID
        XCTAssertEqual(outcome, .imported(noteID: reservedNoteID))
        XCTAssertNil(draft.activeNoteID)

        draft.body = "Autosaved after attachment persistence"
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(draft.activeNoteID, reservedNoteID)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.body, "Autosaved after attachment persistence")
        XCTAssertEqual(store.attachments(for: reservedNoteID).map(\.originalFilename), [
            "completed.txt"
        ])
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .adopted(noteID: reservedNoteID)
        )
    }

    @MainActor
    func testBlankDraftAttachmentCompletionCannotStealNewerBlankSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("attachment".utf8), named: "origin.txt", in: directory)
        let importer = ControlledNoteAttachmentImporter()
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            ),
            attachmentImporter: importer
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }
        _ = await importer.waitUntilStarted()

        XCTAssertTrue(draft.beginNew())
        let newerSession = draft.editorSession
        draft.body = "Newer blank draft"
        XCTAssertEqual(store.attachmentImportState(for: newerSession), .idle)
        XCTAssertEqual(
            store.attachmentImportState(for: request.editorSession),
            .importing(completed: 0, total: 1)
        )
        await importer.succeed()
        let outcome = await importTask.value
        let importedNoteID = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .persisted(noteID: importedNoteID)
        )

        XCTAssertEqual(draft.editorSession, newerSession)
        XCTAssertNil(draft.activeNoteID)
        XCTAssertEqual(draft.body, "Newer blank draft")
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.id, importedNoteID)
        XCTAssertEqual(store.attachments(for: importedNoteID).map(\.originalFilename), [
            "origin.txt"
        ])
    }

    @MainActor
    func testInFlightBlankImportPersistsToOriginAfterSwitchAndKeepsProgressSessionBound() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceA = try write(Data("first".utf8), named: "first.txt", in: directory)
        let sourceB = try write(Data("second".utf8), named: "second.txt", in: directory)
        let importer = ControlledNoteAttachmentImporter()
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            ),
            attachmentImporter: importer
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        let otherNote = try XCTUnwrap(store.create(body: "Other note"))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(
            draft.prepareAttachmentImport(from: [sourceA, sourceB])
        )
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }
        let invocation = await importer.waitUntilStarted()
        XCTAssertEqual(invocation.urls, [sourceA, sourceB])
        XCTAssertEqual(
            store.attachmentImportState(for: request.editorSession),
            .importing(completed: 0, total: 2)
        )

        XCTAssertTrue(draft.beginEditing(otherNote))
        let switchedSession = draft.editorSession
        await importer.reportProgress(completed: 1, total: 2)
        XCTAssertEqual(store.attachmentImportState(for: switchedSession), .idle)
        XCTAssertEqual(
            store.attachmentImportState(for: request.editorSession),
            .importing(completed: 1, total: 2)
        )

        await importer.succeed()
        let outcome = await importTask.value
        let originNoteID = try XCTUnwrap(importedNoteID(from: outcome))
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .persisted(noteID: originNoteID)
        )

        XCTAssertEqual(draft.editorSession, switchedSession)
        XCTAssertEqual(draft.activeNoteID, otherNote.id)
        XCTAssertEqual(draft.body, "Other note")
        XCTAssertEqual(store.notes.count, 2)
        XCTAssertTrue(store.attachments(for: otherNote.id).isEmpty)
        XCTAssertEqual(store.attachments(for: originNoteID).map(\.originalFilename), [
            "first.txt",
            "second.txt"
        ])
    }

    @MainActor
    func testDeletingOriginWhileImportIsInFlightReturnsOriginUnavailable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("deleted".utf8), named: "deleted.txt", in: directory)
        let importer = ControlledNoteAttachmentImporter()
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            ),
            attachmentImporter: importer
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        let origin = try XCTUnwrap(store.create(body: "Delete me"))

        XCTAssertTrue(draft.beginEditing(origin))
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }
        _ = await importer.waitUntilStarted()

        XCTAssertTrue(store.delete(origin))
        draft.discardDeletedNote(origin.id)
        await importer.succeed()
        let outcome = await importTask.value

        XCTAssertEqual(outcome, .originUnavailable)
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .originUnavailable
        )
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.attachmentsByNoteID.isEmpty)
        XCTAssertFalse(draft.isActive)
        XCTAssertEqual(store.attachmentImportState(for: draft.editorSession), .idle)
    }

    @MainActor
    func testCancellingInFlightBlankImportReturnsCancelledWithoutRows() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("cancel".utf8), named: "cancel.txt", in: directory)
        let importer = ControlledNoteAttachmentImporter()
        let store = try makeTestNoteStore(
            attachmentFileStore: AttachmentFileStore(
                rootURL: directory.appendingPathComponent("owned")
            ),
            attachmentImporter: importer
        )
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))

        XCTAssertTrue(draft.beginNew())
        let request = try XCTUnwrap(draft.prepareAttachmentImport(from: [source]))
        let importTask = Task { @MainActor in
            await store.importAttachments(request)
        }
        _ = await importer.waitUntilStarted()

        importTask.cancel()
        let outcome = await importTask.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(
            draft.completeAttachmentImport(outcome, for: request),
            .cancelled
        )
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.attachmentsByNoteID.isEmpty)
        XCTAssertEqual(store.attachmentImportState, .idle)
        XCTAssertTrue(draft.isActive)
        XCTAssertNil(draft.activeNoteID)
    }

    @MainActor
    func testAttachmentsSurviveStoreRecreationAndMaterializeAgain() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("relaunch".utf8), named: "relaunch.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let firstStore = NoteStore(container: container, attachmentFileStore: fileStore)

        let outcome = await firstStore.importAttachments(
            makeStoreImportRequest(from: [source])
        )
        let noteID = try XCTUnwrap(importedNoteID(from: outcome))
        let firstAttachment = try XCTUnwrap(firstStore.attachments(for: noteID).first)
        let firstURLValue = await firstStore.materializedURL(for: firstAttachment)
        let firstURL = try XCTUnwrap(firstURLValue)
        try FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())

        let relaunchedStore = NoteStore(container: container, attachmentFileStore: fileStore)
        let relaunchedAttachment = try XCTUnwrap(relaunchedStore.attachments(for: noteID).first)
        let rebuiltURLValue = await relaunchedStore.materializedURL(for: relaunchedAttachment)
        let rebuiltURL = try XCTUnwrap(rebuiltURLValue)
        XCTAssertEqual(try Data(contentsOf: rebuiltURL), Data("relaunch".utf8))
    }

    @MainActor
    func testFailedAttachmentSaveRollsBackNoteRowsAndOwnedFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("rollback".utf8), named: "rollback.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestNoteStore(persist: gate.save, attachmentFileStore: fileStore)

        let outcome = await store.importAttachments(
            makeStoreImportRequest(from: [source])
        )
        guard case .failed = outcome else {
            return XCTFail("A failed save must return a typed failure outcome")
        }
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.attachmentsByNoteID.isEmpty)
        let rootContents = try? await fileStore.rootURLContentsForTests()
        XCTAssertEqual(
            rootContents?.filter { ![".staging", "Thumbnails"].contains($0.lastPathComponent) }.count,
            0
        )
    }

    @MainActor
    func testRemovingDuplicateAttachmentReplicasDeletesEveryRowOnlyAfterSave() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let noteID = UUID()
        let attachmentID = UUID()
        let payload = Data("replica".utf8)
        context.insert(NoteItem(id: noteID, body: "Note"))
        context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "r.txt", byteCount: Int64(payload.count), sortIndex: 0, contentDigest: "0".repeated(64), payload: payload))
        context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "r.txt", byteCount: Int64(payload.count), sortIndex: 0, contentDigest: "0".repeated(64), payload: payload))
        try context.save()
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let visible = try XCTUnwrap(store.attachments(for: noteID).first)

        XCTAssertTrue(store.removeAttachment(visible))
        let remaining = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testRemovedAttachmentCannotBeRematerializedThroughStaleReference() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("removed".utf8), named: "removed.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let store = try makeTestNoteStore(attachmentFileStore: fileStore)

        let outcome = await store.importAttachments(
            makeStoreImportRequest(from: [source])
        )
        let noteID = try XCTUnwrap(importedNoteID(from: outcome))
        let attachment = try XCTUnwrap(store.attachments(for: noteID).first)
        let materializedValue = await store.materializedURL(for: attachment)
        let materialized = try XCTUnwrap(materializedValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materialized.path))

        XCTAssertTrue(store.removeAttachment(attachment))
        let rematerializedValue = await store.materializedURL(for: attachment)
        XCTAssertNil(rematerializedValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path))
    }

    @MainActor
    func testRemovingAttachmentClearsEveryVisibleNoteMapForDivergentReplicas() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let firstNoteID = UUID()
        let secondNoteID = UUID()
        let attachmentID = UUID()

        context.insert(NoteItem(id: firstNoteID, body: "First"))
        context.insert(NoteItem(id: secondNoteID, body: "Second"))
        context.insert(NoteAttachment(
            id: attachmentID,
            noteID: firstNoteID,
            originalFilename: "replica.txt",
            byteCount: 0,
            sortIndex: 0,
            contentDigest: "0".repeated(64)
        ))
        context.insert(NoteAttachment(
            id: attachmentID,
            noteID: secondNoteID,
            originalFilename: "replica.txt",
            byteCount: 0,
            sortIndex: 0,
            contentDigest: "0".repeated(64)
        ))
        try context.save()

        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let visible = try XCTUnwrap(
            store.attachmentsByNoteID.values.flatMap { $0 }.first
        )

        XCTAssertTrue(store.removeAttachment(visible))
        XCTAssertTrue(store.attachmentsByNoteID.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
    }

    @MainActor
    func testDeletingNoteDeletesAllAttachmentReplicas() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let noteID = UUID()
        context.insert(NoteItem(id: noteID, body: "Note"))
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "one.txt", byteCount: 0, sortIndex: 0, contentDigest: "0".repeated(64)))
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "two.txt", byteCount: 0, sortIndex: 1, contentDigest: "1".repeated(64)))
        try context.save()
        let store = NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.notes.first)

        XCTAssertTrue(store.delete(note))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
    }
}

private actor ControlledNoteAttachmentImporter: NoteAttachmentFileImporting {
    struct Invocation: Equatable, Sendable {
        let urls: [URL]
        let baseSortIndex: Int64
        let existingCount: Int
        let existingBytes: Int64
    }

    private var invocation: Invocation?
    private var progress: (@Sendable (Int, Int) async -> Void)?
    private var continuation: CheckedContinuation<[ImportedAttachment], Error>?
    private var startWaiters: [CheckedContinuation<Invocation, Never>] = []

    func importFiles(
        _ urls: [URL],
        baseSortIndex: Int64,
        existingCount: Int,
        existingBytes: Int64,
        progress: (@Sendable (Int, Int) async -> Void)?
    ) async throws -> [ImportedAttachment] {
        try Task.checkCancellation()
        let invocation = Invocation(
            urls: urls,
            baseSortIndex: baseSortIndex,
            existingCount: existingCount,
            existingBytes: existingBytes
        )
        self.invocation = invocation
        self.progress = progress
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(returning: invocation) }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingImport() }
        }
    }

    func waitUntilStarted() async -> Invocation {
        if let invocation { return invocation }
        return await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func reportProgress(completed: Int, total: Int) async {
        await progress?(completed, total)
    }

    func succeed() {
        guard let invocation, let continuation else { return }
        self.continuation = nil
        do {
            let attachments = try invocation.urls.enumerated().map { offset, url in
                let payload = try Data(contentsOf: url)
                return ImportedAttachment(
                    id: UUID(),
                    filename: url.lastPathComponent,
                    contentTypeIdentifier: "public.data",
                    byteCount: Int64(payload.count),
                    sortIndex: invocation.baseSortIndex + Int64(offset),
                    digest: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(offset + 1)),
                    payload: payload
                )
            }
            continuation.resume(returning: attachments)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func cancelPendingImport() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: CancellationError())
    }
}

private struct AttachmentProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
}

private actor AttachmentProgressRecorder {
    private(set) var values: [AttachmentProgress] = []

    func record(completed: Int, total: Int) {
        values.append(AttachmentProgress(completed: completed, total: total))
    }
}

private final class PromisedFileResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PromisedFileBatch.Result] = []

    var completionCount: Int {
        lock.withLock { results.count }
    }

    var latest: PromisedFileBatch.Result? {
        lock.withLock { results.last }
    }

    func record(_ result: PromisedFileBatch.Result) {
        lock.withLock { results.append(result) }
    }
}

private extension AttachmentFileStore {
    func rootURLContentsForTests() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
