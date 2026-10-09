import AppKit
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Attic


@MainActor
final class NoteAttachmentTests: XCTestCase {
    func testAttachmentLimitHelpersSaturateBytesAndRejectSortIndexOverflow() {
        XCTAssertEqual(
            AttachmentLimits.cappedByteCount([Int64.max, Int64.max]),
            AttachmentLimits.maxBytesPerNote
        )
        XCTAssertEqual(AttachmentLimits.nextSortIndex(after: Int64.max - 1, adding: 1), Int64.max)
        XCTAssertNil(AttachmentLimits.nextSortIndex(after: Int64.max, adding: 1))
        XCTAssertNil(AttachmentLimits.nextSortIndex(after: Int64.max - 1, adding: 2))
        XCTAssertTrue(AttachmentLimits.canAssignSortIndexes(startingAt: Int64.max, count: 1))
        XCTAssertFalse(AttachmentLimits.canAssignSortIndexes(startingAt: Int64.max, count: 2))
    }


    func testMissingAttachmentReportsRecoveryAndLocateRejectsDifferentContents() async throws {
        let directory = try makeDirectory()

        let source = try write(Data("original".utf8), named: "original.txt", in: directory)
        let other = try write(Data("different".utf8), named: "other.txt", in: directory)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = NoteItem(body: "Note")
        let original = Data("original".utf8)
        let attachment = NoteAttachment(
            noteID: note.id, originalFilename: "original.txt", byteCount: Int64(original.count), sortIndex: 0,
            contentDigest: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(), payload: nil
        )
        context.insert(note)
        context.insert(attachment)
        try context.save()
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let visible = try XCTUnwrap(store.attachments(for: note.id).first)
        let missing = await store.materializedURL(for: visible)
        XCTAssertNil(missing)
        XCTAssertNotNil(store.attachmentFailures[visible.id])
        let rejected = await store.locateAttachment(visible, at: other)
        XCTAssertFalse(rejected)
        XCTAssertNil(visible.payload)
        let restored = await store.locateAttachment(visible, at: source)
        XCTAssertTrue(restored)
        let restoredURL = await store.materializedURL(for: visible)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restoredURL)), original)
        XCTAssertNil(store.attachmentFailures[visible.id])
        XCTAssertEqual(store.attachments(for: note.id).count, 1)
        XCTAssertEqual(store.attachments(for: note.id).first?.id, attachment.id)
    }

    func testLocateRejectsChangedMetadataInFreshContextBeforeRestoringPayload() async throws {
        let directory = try makeDirectory()

        let original = Data("original".utf8)
        let source = try write(original, named: "original.txt", in: directory)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = NoteItem(body: "Note")
        let attachment = NoteAttachment(
            noteID: note.id, originalFilename: "original.txt", byteCount: Int64(original.count), sortIndex: 0,
            contentDigest: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(), payload: nil
        )
        context.insert(note)
        context.insert(attachment)
        try context.save()
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let stale = try XCTUnwrap(store.attachments(for: note.id).first)
        let previousDigest = stale.contentDigest

        let external = ModelContext(container)
        let changed = try XCTUnwrap(external.fetch(FetchDescriptor<NoteAttachment>()).first)
        let replacement = Data("replacement".utf8)
        let replacementDigest = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
        changed.contentDigest = replacementDigest
        changed.byteCount = Int64(replacement.count)
        try external.save()
        XCTAssertEqual(stale.contentDigest, previousDigest, "The visible context still holds the original metadata")

        let restored = await store.locateAttachment(stale, at: source)
        XCTAssertFalse(restored)
        XCTAssertNotNil(store.attachmentFailures[stale.id])
        XCTAssertEqual(store.attachments(for: note.id).first?.contentDigest, replacementDigest,
                       "Retry must use the current metadata after Locate detects a stale row")
        let verification = ModelContext(container)
        let saved = try XCTUnwrap(verification.fetch(FetchDescriptor<NoteAttachment>()).first)
        XCTAssertEqual(saved.contentDigest, replacementDigest)
        XCTAssertEqual(saved.byteCount, Int64(replacement.count))
        XCTAssertNil(saved.payload, "Locate must not put old bytes under newly saved metadata")
        let replacementURL = try write(replacement, named: "replacement.txt", in: directory)
        let current = try XCTUnwrap(store.attachments(for: note.id).first)
        let retried = await store.locateAttachment(current, at: replacementURL)
        XCTAssertTrue(retried)
        XCTAssertEqual(store.attachments(for: note.id).first?.payload, replacement)
    }

// MARK: - DATA-002: Open never exposes the private materialization

    // MARK: - DATA-003: rejected pastes and promised drops are reported




    private func makePNGData() throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func makeDirectory() throws -> URL {
        let url = ownedTemporaryDirectory(prefix: "AtticAttachmentTests")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Dropping a card on itself is not a reorder: it must stay where it is.
    /// The source is taken out of the working order before the target index is
    /// looked up, so a target equal to the source missed the lookup entirely
    /// and the card was appended to the end — A,B,C dropping A on A produced
    /// B,C,A.


    func testImportPreservesFinderOrderAndDuplicateFilenames() async throws {
        let directory = try makeDirectory()

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

        // Only file length is inspected before rejection. A sparse fixture
        // preserves the 15 MiB + 1 boundary without allocating that payload.
        let oversized = try write(Data(), named: "oversized.bin", in: directory)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        defer { try? oversizedHandle.close() }
        try oversizedHandle.truncate(atOffset: UInt64(AttachmentLimits.maxBytesPerAttachment + 1))
        do {
            _ = try await fileStore.importFiles([oversized], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
            XCTFail("The per-file limit must be enforced")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .attachmentTooLarge(oversized.standardizedFileURL, AttachmentLimits.maxBytesPerAttachment + 1))
        }
    }

    func testCancelledImportDoesNotCreateOwnedFiles() async throws {
        let directory = try makeDirectory()

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

    func testSourceCanDisappearAfterImportAndMissingMaterializationIsRebuilt() async throws {
        let directory = try makeDirectory()

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
















func testRemovingDuplicateAttachmentReplicasDeletesEveryRowOnlyAfterSave() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let noteID = UUID()
        let attachmentID = UUID()
        let payload = Data("replica".utf8)
        context.insert(NoteItem(id: noteID, body: "Note"))
        // Two copies of one attachment, as sync would produce them: every
        // stored field the same (the purge requires identical replicas).
        let created = Date(timeIntervalSince1970: 1_000)
        context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "r.txt", byteCount: Int64(payload.count), sortIndex: 0, contentDigest: "0".repeated(64), createdAt: created, payload: payload))
        context.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "r.txt", byteCount: Int64(payload.count), sortIndex: 0, contentDigest: "0".repeated(64), createdAt: created, payload: payload))
        try context.save()
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let visible = try XCTUnwrap(store.attachments(for: noteID).first)

        // Removal is soft: every replica is marked, and the purge after 30
        // days removes every replica.
        XCTAssertTrue(store.removeAttachment(visible))
        let remaining = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(store.attachments(for: noteID).isEmpty)
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 1)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
    }

    /// Re-review item 3: a row may keep no bytes of its own (`payload` is
    /// nil), so the file is the only copy. A stale request after removal must
    /// not delete it, and a restore must show it again.
    func testRemovedAttachmentWithoutStoredBytesSurvivesAStaleRequestAndComesBackDisplayable() async throws {
        let directory = try makeDirectory()

        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let bytes = Data("the only copy".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let noteID = UUID()
        let attachmentID = UUID()
        let seeded = try await fileStore.ensureMaterialized(AttachmentFileReference(
            id: attachmentID, digest: digest, filename: "only.txt", byteCount: Int64(bytes.count), payload: bytes
        ))
        let file = try XCTUnwrap(seeded)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        seed.insert(NoteItem(id: noteID, body: "Note"))
        seed.insert(NoteAttachment(id: attachmentID, noteID: noteID, originalFilename: "only.txt",
                                   byteCount: Int64(bytes.count), sortIndex: 0, contentDigest: digest, payload: nil))
        try seed.save()
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: fileStore))
        let attachment = try XCTUnwrap(store.attachments(for: noteID).first)
        let shown = await store.materializedURL(for: attachment)
        XCTAssertEqual(shown, file)

        XCTAssertTrue(store.removeAttachment(attachment))
        let stale = await store.materializedURL(for: attachment)
        XCTAssertNil(stale, "a removed attachment is not handed out")
        XCTAssertEqual(try Data(contentsOf: file), bytes, "its only copy stays")

        XCTAssertTrue(store.restoreAttachment(attachmentID))
        let restored = try XCTUnwrap(store.attachments(for: noteID).first)
        let restoredURLValue = await store.materializedURL(for: restored)
        let restoredURL = try XCTUnwrap(restoredURLValue, "the restored attachment opens again")
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
    }

    /// Removal and restore change what is shown, so the restore reconciles
    /// files in full and puts back a file that went missing meanwhile.
func testRemovingAnAttachmentWhoseCopiesClaimDifferentNotesIsRefused() throws {
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

        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let visible = try XCTUnwrap(
            store.attachmentsByNoteID.values.flatMap { $0 }.first
        )

        // Which note owns it is unresolved: removing it from one must not
        // hide it from the other, so nothing changes.
        XCTAssertFalse(store.removeAttachment(visible))
        XCTAssertEqual(store.lastErrorMessage,
                       "Copies of this attachment belong to different notes, so it can’t be removed safely. Refresh and try again.")
        XCTAssertEqual(store.attachmentsByNoteID.values.flatMap { $0 }.map(\.id), [attachmentID], "still shown")
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(rows.map(\.noteID)), [firstNoteID, secondNoteID])
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil }, "both copies stay live")
    }

    // Phase 0: deleting a note is soft. Its attachment replicas stay until
    // the note is purged from Recently Deleted, which removes them all.
    func testDeletingNoteKeepsAllAttachmentReplicasUntilItIsPurged() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let noteID = UUID()
        context.insert(NoteItem(id: noteID, body: "Note"))
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "one.txt", byteCount: 0, sortIndex: 0, contentDigest: "0".repeated(64)))
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "two.txt", byteCount: 0, sortIndex: 1, contentDigest: "1".repeated(64)))
        try context.save()
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let note = try XCTUnwrap(store.notes.first)

        XCTAssertTrue(store.delete(note))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.attachments(for: noteID).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).map(\.deletedAt).count, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NoteAttachment>()), 2)

        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [noteID])
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
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

@MainActor
private final class FreshNoteContextGate {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Injected fresh-context failure" }
    }

    private let container: ModelContainer
    private var successfulContextsRemainingBeforeFailure: Int?

    init(container: ModelContainer) {
        self.container = container
    }

    func failAfterSuccessfulContexts(_ count: Int) {
        successfulContextsRemainingBeforeFailure = max(count, 0)
    }

    func makeContext() throws -> ModelContext {
        if let remaining = successfulContextsRemainingBeforeFailure {
            guard remaining > 0 else { throw Failure() }
            successfulContextsRemainingBeforeFailure = remaining - 1
        }
        return ModelContext(container)
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
