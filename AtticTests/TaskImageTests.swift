import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

@MainActor
final class TaskImageTests: XCTestCase {
    private func imageFile(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let url = directory.appendingPathComponent("Picture.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImagesPersistAcrossContextsAndExportTextWithOriginalImageBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try imageFile(in: root)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: files)
        let task = try XCTUnwrap(store.create(title: "Plan trip"))
        await store.attachFiles([file], to: task.id)
        XCTAssertNil(store.lastErrorMessage)
        let fresh = TaskStore(container: container, taskImageFiles: files)
        let restored = try XCTUnwrap(fresh.tasks.first)
        let image = try XCTUnwrap(restored.attachments.first)
        let thumbnail = try await files.thumbnail(image)
        XCTAssertNotNil(thumbnail)
        let exported = try await files.export(title: restored.title, references: restored.attachments)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("Task.txt"), encoding: .utf8), "Plan trip")
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("1-Picture.png")), try Data(contentsOf: file))
        XCTAssertTrue(fresh.removeAttachment(image.id, from: restored.id))
        XCTAssertTrue(TaskStore(container: container, taskImageFiles: files).tasks[0].attachments.isEmpty)
    }

    func testFailedAttachmentSaveRollsBackReferencesAndLeavesTaskUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try imageFile(in: root)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var fail = false
        let store = TaskStore(container: container, persist: { context in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let task = try XCTUnwrap(store.create(title: "Preserve"))
        fail = true
        await store.attachFiles([file], to: task.id)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertTrue(store.tasks[0].attachments.isEmpty)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)
        XCTAssertEqual(store.tasks[0].title, "Preserve")
    }

    func testCorruptImageIsRejectedAndLegacyTaskPayloadStillDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Broken.png")
        try Data("not an image".utf8).write(to: url)
        do {
            _ = try await TaskImageFiles(rootURL: root.appendingPathComponent("storage")).importAttachments([url], existing: [])
            XCTFail("Corrupt image must not be accepted")
        } catch {}
        let old = Data("{\"title\":\"Legacy task\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TaskDragPayload.self, from: old).imageReferences)
    }

    func testTaskImportRejectsOverflowingPersistedByteCountsWithoutTrapping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try textFile(named: "New.txt", in: root)
        let existing = [
            TaskImageReference(
                id: UUID(),
                filename: "a.txt",
                digest: String(repeating: "0", count: 64),
                contentTypeIdentifier: UTType.plainText.identifier,
                byteCount: Int64.max
            ),
            TaskImageReference(
                id: UUID(),
                filename: "b.txt",
                digest: String(repeating: "1", count: 64),
                contentTypeIdentifier: UTType.plainText.identifier,
                byteCount: Int64.max
            )
        ]

        do {
            _ = try await TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
                .importAttachments([file], existing: existing)
            XCTFail("Malformed persisted byte totals must be rejected")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .noteTooLarge)
        }
    }

    func testFailedExportRemovesItsDisposableDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticTaskExports", isDirectory: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: exportRoot.path)) ?? [])
        let missing = TaskImageReference(
            id: UUID(),
            filename: "missing.txt",
            digest: String(repeating: "0", count: 64),
            contentTypeIdentifier: UTType.plainText.identifier,
            byteCount: 1
        )

        do {
            _ = try await TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
                .export(title: "Failed export", references: [missing])
            XCTFail("Missing private bytes must fail export")
        } catch {}

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: exportRoot.path)) ?? [])
        XCTAssertTrue(after.subtracting(before).isEmpty, "A failed export must remove its new disposable directory")
    }
    // MARK: - Batch 2: general files, parent ownership, compatibility

    private func textFile(named name: String, in directory: URL, contents: String = "Packing list") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func storedAttachmentDirectories(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { UUID(uuidString: $0) != nil }
    }

    func testImagesAndGeneralFilesAttachTogetherAndStayUsableAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try imageFile(in: root)
        let text = try textFile(named: "Packing List.txt", in: root)
        let storage = root.appendingPathComponent("storage")
        let files = TaskImageFiles(rootURL: storage)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: files)
        let task = try XCTUnwrap(store.create(title: "Plan weekend"))

        let attached = await store.attachFiles([image, text], to: task.id)
        XCTAssertTrue(attached)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)

        let restored = try XCTUnwrap(TaskStore(container: container, taskImageFiles: files).tasks.first)
        XCTAssertEqual(restored.attachments.map(\.filename), ["Picture.png", "Packing List.txt"])
        let (picture, list) = (restored.attachments[0], restored.attachments[1])
        XCTAssertTrue(picture.isImage)
        XCTAssertFalse(list.isImage)
        XCTAssertTrue(list.contentType.conforms(to: .plainText))
        XCTAssertEqual(list.byteCount, Int64("Packing list".utf8.count))
        let pictureThumbnail = try await files.thumbnail(picture)
        let listThumbnail = try await files.thumbnail(list)
        XCTAssertNotNil(pictureThumbnail)
        XCTAssertNil(listThumbnail, "files never pay for image decoding")

        // The private copy is verified, lives under the private root, and is
        // not the user's original.
        let verified = try await files.verifiedURL(for: list)
        let privateURL = try XCTUnwrap(verified)
        XCTAssertTrue(privateURL.standardizedFileURL.path.hasPrefix(storage.standardizedFileURL.path + "/"))
        XCTAssertNotEqual(privateURL.standardizedFileURL, text.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: privateURL), try Data(contentsOf: text))

        // A changed private copy is refused rather than handed out.
        try Data("tampered".utf8).write(to: privateURL)
        let tampered = try await files.verifiedURL(for: list)
        XCTAssertNil(tampered)

        // Drag-out export keeps the title with every attachment.
        try Data("Packing list".utf8).write(to: privateURL)
        let exported = try await files.export(title: restored.title, references: restored.attachments)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("2-Packing List.txt")), try Data(contentsOf: text))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "originals are never moved or removed")
    }

    func testSubtaskAttachmentsResolveToTheParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try textFile(named: "Itinerary.txt", in: root)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        XCTAssertEqual(store.attachmentOwnerID(for: child.id), parent.id)
        XCTAssertEqual(store.attachmentOwnerID(for: parent.id), parent.id)
        XCTAssertNil(store.attachmentOwnerID(for: UUID()))

        let attached = await store.attachFiles([text], to: child.id)
        XCTAssertTrue(attached)
        let fresh = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        XCTAssertEqual(fresh.tasks.first { $0.id == parent.id }?.attachments.map(\.filename), ["Itinerary.txt"])
        XCTAssertEqual(fresh.tasks.first { $0.id == child.id }?.attachments, [], "no nested attachment owner")
    }

    func testAttachAndRemoveApplyToEveryPhysicalDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try textFile(named: "Notes.txt", in: root)
        let image = try imageFile(in: root)
        let storage = root.appendingPathComponent("storage")
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let seed = ModelContext(container)
        let sharedID = UUID()
        seed.insert(TaskItem(id: sharedID, title: "Shared"))
        seed.insert(TaskItem(id: sharedID, title: "Shared", updatedAt: Date().addingTimeInterval(1)))
        try seed.save()
        let files = TaskImageFiles(rootURL: storage)
        let store = TaskStore(container: container, taskImageFiles: files)

        let attached = await store.attachFiles([text, image], to: sharedID)
        XCTAssertTrue(attached)
        var replicas = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.attachments.map(\.filename) == ["Notes.txt", "Picture.png"] })
        XCTAssertEqual(Set(replicas.map(\.imageReferencesData)).count, 1)

        let removed = try XCTUnwrap(store.tasks.first?.attachments.first)
        XCTAssertTrue(store.removeAttachment(removed.id, from: sharedID))
        replicas = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(replicas.allSatisfy { $0.attachments.map(\.filename) == ["Picture.png"] })
        // Each replica is written separately; equal lists must still be
        // byte-identical, or every replica comparison sees a divergence.
        XCTAssertEqual(Set(replicas.map(\.imageReferencesData)).count, 1)
        XCTAssertEqual(Set(replicas.map(\.removedAttachmentsData)).count, 1)
    }

    /// Plain `JSONEncoder` key order can differ between two encodes of one
    /// value depending on allocation; the replica encoder must not.
    func testReplicaAttachmentEncodingIsByteStableForEqualLists() throws {
        let references = (0..<3).map {
            TaskImageReference(id: UUID(), filename: "File \($0).txt", digest: String(repeating: "a", count: 64),
                               contentTypeIdentifier: "public.plain-text", byteCount: Int64($0 + 1))
        }
        var encodings = Set<Data>()
        var churn: [Any] = []
        for index in 0..<400 {
            // Vary what is allocated between encodes, as a real save does.
            churn.append([String: Int](uniqueKeysWithValues: (0..<(index % 37)).map { ("k\($0)", $0) }))
            churn.append([UInt8](repeating: UInt8(index % 255), count: index * 13 % 997))
            encodings.insert(try TaskStore.encodedAttachments(references))
        }
        XCTAssertEqual(encodings.count, 1)
        XCTAssertEqual(try JSONDecoder().decode([TaskImageReference].self, from: try XCTUnwrap(encodings.first)), references)
    }

    /// A crafted store where two logical tasks share one attachment identity:
    /// deleting, purging or removing on one side must leave the survivor's
    /// file in place. Only the launch sweep may reclaim true orphans.
    func testRemovingAnAttachmentKeepsFilesAnotherTaskStillReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try textFile(named: "Shared.txt", in: root)
        let storage = root.appendingPathComponent("storage")
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let files = TaskImageFiles(rootURL: storage)
        let store = TaskStore(container: container, taskImageFiles: files)
        let owner = try XCTUnwrap(store.create(title: "Owner"))
        let attached = await store.attachFiles([text], to: owner.id)
        XCTAssertTrue(attached)
        let reference = try XCTUnwrap(store.tasks.first { $0.id == owner.id }?.attachments.first)
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1)

        // Another task (and a hidden replica of a third) hold the same identity.
        let seed = ModelContext(container)
        let twin = TaskItem(title: "Twin")
        twin.imageReferencesData = try JSONEncoder().encode([reference])
        seed.insert(twin)
        try seed.save()
        store.refresh()

        XCTAssertTrue(store.removeAttachment(reference.id, from: owner.id))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1, "the twin still references the file")
        let survivingURL = try await files.verifiedURL(for: reference)
        XCTAssertNotNil(survivingURL)

        // Phase 0: a deleted task keeps its files in Recently Deleted; the
        // purge after 30 days releases the last reference.
        XCTAssertTrue(store.delete(store.task(withID: twin.id)!))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1, "a soft-deleted task keeps its file")
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [twin.id])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1, "the owner's removal is still restorable")
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 0, "the last reference releases the file")
    }

    func testFailedFileSaveRollsBackAndRemovesOnlyTheNewPrivateCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try textFile(named: "Keep.txt", in: root)
        let second = try textFile(named: "Rejected.pdf", in: root, contents: "%PDF-1.4")
        let storage = root.appendingPathComponent("storage")
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var fail = false
        let store = TaskStore(container: container, persist: { context in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }, taskImageFiles: TaskImageFiles(rootURL: storage))
        let task = try XCTUnwrap(store.create(title: "Preserve"))
        let kept = await store.attachFiles([first], to: task.id)
        XCTAssertTrue(kept)
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1)

        fail = true
        let failed = await store.attachFiles([second], to: task.id)
        XCTAssertFalse(failed)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.tasks[0].attachments.map(\.filename), ["Keep.txt"])
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)
        XCTAssertEqual(storedAttachmentDirectories(storage).count, 1, "the failed import leaves no private copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        let keptReference = try XCTUnwrap(store.tasks[0].attachments.first)
        XCTAssertFalse(store.removeAttachment(keptReference.id, from: task.id))
        XCTAssertEqual(store.tasks[0].attachments.map(\.filename), ["Keep.txt"], "a failed removal keeps the reference")
        let stillThere = try await TaskImageFiles(rootURL: storage).verifiedURL(for: keptReference)
        XCTAssertNotNil(stillThere, "a failed removal keeps the private copy")
    }

    func testTaskLimitErrorsUseTaskWording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0...AttachmentLimits.maxAttachmentsPerNote).map {
            try textFile(named: "File \($0).txt", in: root)
        }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let task = try XCTUnwrap(store.create(title: "Many"))
        let attached = await store.attachFiles(urls, to: task.id)
        XCTAssertFalse(attached)
        XCTAssertEqual(store.lastErrorMessage, "Couldn’t attach files. A task can hold at most 20 attachments.")
        XCTAssertTrue(store.tasks[0].attachments.isEmpty)
    }

    func testLegacyImageReferencesDecodeAsImageAttachments() throws {
        let id = UUID()
        let legacy = Data("""
        [{"id":"\(id.uuidString)","filename":"lake.jpg","digest":"\(String(repeating: "a", count: 64))",
          "contentTypeIdentifier":"public.jpeg","byteCount":2400000}]
        """.utf8)
        let task = TaskItem(title: "Legacy")
        task.imageReferencesData = legacy
        let reference = try XCTUnwrap(task.attachments.first)
        XCTAssertEqual(reference.id, id)
        XCTAssertTrue(reference.isImage)
        let payload = TaskDragPayload(taskID: task.id, title: task.title, imageReferences: task.attachments)
        let roundTrip = try JSONDecoder().decode(TaskDragPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(roundTrip.imageReferences, [reference])
    }

    // MARK: - Batch 2 review fixes

    func testTaskImportReadsNoPayloadAndRejectsABatchWithABrokenImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try imageFile(in: root)
        let text = try textFile(named: "Packing List.txt", in: root)
        let broken = root.appendingPathComponent("Broken.jpg")
        try Data(repeating: 7, count: 5_000).write(to: broken)

        // Notes keep payloads (they store them); task imports read nothing back.
        let fileStore = AttachmentFileStore(rootURL: root.appendingPathComponent("files"))
        let withPayload = try await fileStore.importFiles([text], baseSortIndex: 0, existingCount: 0, existingBytes: 0)
        XCTAssertEqual(withPayload.first?.payload, try Data(contentsOf: text))
        let withoutPayload = try await fileStore.importFiles([image, text], baseSortIndex: 0, existingCount: 0,
                                                             existingBytes: 0, includePayload: false)
        XCTAssertEqual(withoutPayload.count, 2)
        XCTAssertTrue(withoutPayload.allSatisfy { $0.payload == nil })

        // One broken image rolls back the whole batch, valid files included.
        let storage = root.appendingPathComponent("storage")
        do {
            _ = try await TaskImageFiles(rootURL: storage).importAttachments([image, text, broken], existing: [])
            XCTFail("A broken image must reject the batch")
        } catch {}
        XCTAssertEqual(storedAttachmentDirectories(storage), [], "no private copy survives a rejected batch")
        XCTAssertTrue([image, text, broken].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let accepted = try await TaskImageFiles(rootURL: storage).importAttachments([image, text], existing: [])
        XCTAssertEqual(accepted.map(\.isImage), [true, false])
    }

    func testAttachmentDragPromisesItsRecordedTypeAndHandsOutACopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try imageFile(in: root)
        let text = try textFile(named: "Packing List.txt", in: root)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let references = try await files.importAttachments([image, text], existing: [])
        let (picture, list) = (references[0], references[1])

        let imageProvider = TaskAttachmentDragItem(reference: picture, files: files).itemProvider()
        // The file first; the in-process card marker (batch 3) ranks below it.
        XCTAssertEqual(imageProvider.registeredTypeIdentifiers,
                       [UTType.png.identifier, TaskDropContent.attachmentCardType.identifier])
        // The provider adds the type's extension to the delivered copy itself,
        // so the suggestion omits it and the receiver still gets "Picture.png".
        XCTAssertEqual(imageProvider.suggestedName, "Picture")
        // A static public.data promise failed both of these image-only checks.
        XCTAssertTrue(imageProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        XCTAssertTrue(imageProvider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
        XCTAssertTrue(imageProvider.hasItemConformingToTypeIdentifier(UTType.data.identifier), "generic file receivers")

        let fileProvider = TaskAttachmentDragItem(reference: list, files: files).itemProvider()
        XCTAssertFalse(fileProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        XCTAssertTrue(fileProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertTrue(fileProvider.hasItemConformingToTypeIdentifier(UTType.data.identifier))

        let privateURL = try await files.verifiedURL(for: picture)
        let loaded = expectation(description: "file representation")
        _ = imageProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
            XCTAssertNil(error)
            XCTAssertNotNil(url)
            if let url {
                XCTAssertNotEqual(url.standardizedFileURL, privateURL?.standardizedFileURL, "receivers get a copy")
                XCTAssertEqual(url.lastPathComponent, "Picture.png", "not \"Picture\" or \"Picture.png.png\"")
                XCTAssertEqual(try? Data(contentsOf: url), try? Data(contentsOf: image))
            }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
    }

    func testOpenHandsOutADisposableReadOnlyCopyAndThePrivateCopyStaysVerified() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try textFile(named: "Packing List.txt", in: root)
        let storage = root.appendingPathComponent("storage")
        let files = TaskImageFiles(rootURL: storage)
        let imported = try await files.importAttachments([text], existing: [])
        let list = try XCTUnwrap(imported.first)

        let opened = try await files.openableCopy(for: list)
        let copy = try XCTUnwrap(opened)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertFalse(copy.standardizedFileURL.path.hasPrefix(storage.standardizedFileURL.path + "/"))
        XCTAssertEqual(copy.lastPathComponent, "Packing List.txt")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: text))
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: copy.path), "an editor sees the copy as read-only")
        XCTAssertThrowsError(try Data("edited".utf8).write(to: copy))

        let verified = try await files.verifiedURL(for: list)
        XCTAssertNotNil(verified, "opening never exposes the digest-checked private copy")
        let second = try await files.openableCopy(for: list)
        XCTAssertNotEqual(second, copy, "each open gets its own disposable copy")
        if let second { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        try Data("tampered".utf8).write(to: XCTUnwrap(verified))
        let refused = try await files.openableCopy(for: list)
        XCTAssertNil(refused, "a changed private copy is reported unavailable, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
    }

    func testOnlyOpenableFileTypesMayOpen() {
        XCTAssertTrue(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: UTType.pdf.identifier))
        XCTAssertTrue(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: UTType.jpeg.identifier))
        XCTAssertFalse(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: UTType.applicationBundle.identifier))
        XCTAssertFalse(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: UTType.shellScript.identifier))
        XCTAssertFalse(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: UTType.data.identifier))
        XCTAssertFalse(NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: ""))
    }
}
