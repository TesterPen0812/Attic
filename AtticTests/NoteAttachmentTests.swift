import Foundation
import SwiftData
import XCTest
@testable import Attic

final class NoteAttachmentTests: XCTestCase {
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

    @MainActor
    func testAttachmentOnlyNotePersistsAndOrdersAttachments() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceA = try write(Data("A".utf8), named: "a.txt", in: directory)
        let sourceB = try write(Data("B".utf8), named: "b.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let store = try makeTestNoteStore(attachmentFileStore: fileStore)

        let noteID = await store.importAttachments(from: [sourceA, sourceB])
        let noteIDValue = try XCTUnwrap(noteID)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.id, noteIDValue)
        XCTAssertEqual(store.attachments(for: noteIDValue).map(\.originalFilename), ["a.txt", "b.txt"])
        XCTAssertEqual(store.notes.first?.body, "")
    }

    @MainActor
    func testAttachmentsSurviveStoreRecreationAndMaterializeAgain() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try write(Data("relaunch".utf8), named: "relaunch.txt", in: directory)
        let fileStore = AttachmentFileStore(rootURL: directory.appendingPathComponent("owned"))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let firstStore = NoteStore(container: container, attachmentFileStore: fileStore)

        let importedNoteID = await firstStore.importAttachments(from: [source])
        let noteID = try XCTUnwrap(importedNoteID)
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

        let importedNoteID = await store.importAttachments(from: [source])
        XCTAssertNil(importedNoteID)
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
        let store = NoteStore(container: container)
        let visible = try XCTUnwrap(store.attachments(for: noteID).first)

        XCTAssertTrue(store.removeAttachment(visible))
        let remaining = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertTrue(remaining.isEmpty)
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
        let store = NoteStore(container: container)
        let note = try XCTUnwrap(store.notes.first)

        XCTAssertTrue(store.delete(note))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
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
