import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Batch 3 (R4 drops, R5 composer attachments): routing, staging ownership,
/// store reservation and failure recovery, gallery-card copies, launch-time
/// storage cleanup, reveal policy and composer races.
/// Pointer drags, overlays and motion are live-only.
@MainActor
final class TaskAttachmentDropTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private var storage: URL { root.appendingPathComponent("storage") }

    private func pngFile(named name: String = "Picture.png") throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func textFile(named name: String, contents: String = "Packing list") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Content an app provides without a file URL (a file promise or an
    /// in-memory image), as the drop's item provider presents it.
    private func providedFile(_ url: URL, type: UTType, suggestedName: String?,
                              loads: (() -> Void)? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            loads?()
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    private func finderFile(_ url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    private func privateDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []).filter { UUID(uuidString: $0) != nil }
    }

    private func ownedDropDirectories() -> Set<String> {
        let dropRoot = FileManager.default.temporaryDirectory.appendingPathComponent(TaskAttachmentStaging.ownedRootName)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dropRoot.path)) ?? [])
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Suspends a stage closure until the test opens it.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private(set) var isWaiting = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0; isWaiting = true }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func makeStore(saves: Box<Int>? = nil, fail: Box<Bool>? = nil) throws -> (TaskStore, ModelContainer, TaskImageFiles) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let files = TaskImageFiles(rootURL: storage)
        let store = TaskStore(container: container, persist: { context in
            if fail?.value == true { throw CocoaError(.fileWriteOutOfSpace) }
            saves?.value += 1
            try context.save()
        }, taskImageFiles: files)
        return (store, container, files)
    }

    // MARK: - R4 routing

    func testDropContentSeparatesTaskRowsGalleryCardsFilesAndText() async throws {
        func classify(_ types: [UTType]) -> TaskDropContent {
            TaskDropContent.classify { wanted in types.contains { type in wanted.contains { type.conforms(to: $0) } } }
        }
        // A row with attachments also exports a folder and its title: still a task drag.
        XCTAssertEqual(classify([TaskDragPayload.internalTaskType, .folder, .fileURL, .utf8PlainText]), .task)
        XCTAssertEqual(classify([.fileURL]), .files, "Finder")
        XCTAssertEqual(classify([.png]), .files, "promised or in-memory image")
        XCTAssertEqual(classify([.jpeg, .url]), .files, "browser image")
        XCTAssertEqual(classify([.pdf]), .files)
        XCTAssertEqual(classify([.utf8PlainText, .html, .url]), .unsupported, "a text selection or link is not a file")

        // General promised documents are files; text, links, folders and
        // Attic's own in-app markers are not.
        for ext in ["docx", "doc", "pages", "eml", "epub", "ttf"] {
            XCTAssertEqual(classify([try XCTUnwrap(UTType(filenameExtension: ext))]), .files, ext)
        }
        for ext in ["txt", "rtf", "csv", "vcf", "ics", "md"] {
            XCTAssertEqual(classify([try XCTUnwrap(UTType(filenameExtension: ext))]), .unsupported, ext)
        }
        XCTAssertEqual(classify([.url]), .unsupported, "a link")
        XCTAssertEqual(classify([.folder]), .unsupported, "a promised folder")
        XCTAssertEqual(classify([UTType(exportedAs: NoteInlineCardsLayout.dragType.rawValue)]), .unsupported,
                       "a note card moving inside its note")
        XCTAssertEqual(classify([try XCTUnwrap(UTType(filenameExtension: "docx")), .utf8PlainText]), .unsupported,
                       "anything that also carries text stays unsupported")

        // Providers follow the same rule, and a promised document keeps its type.
        let docx = try XCTUnwrap(UTType(filenameExtension: "docx"))
        let report = providedFile(try textFile(named: "Report.docx"), type: docx, suggestedName: "Report")
        XCTAssertEqual(TaskDropContent.classify(report), .files)
        XCTAssertEqual(TaskDroppedFiles.fileContentType(of: report), docx)
        XCTAssertEqual(TaskDropContent.classify(NSItemProvider(object: "Just text" as NSString)), .unsupported)
        XCTAssertNil(TaskDroppedFiles.fileContentType(of: NSItemProvider(object: "Just text" as NSString)))
        XCTAssertEqual(TaskDropContent.classify(NSItemProvider(object: URL(string: "https://example.com")! as NSURL)),
                       .unsupported)

        // A real gallery card drag: its file type alone would read as files.
        let image = try pngFile()
        let files = TaskImageFiles(rootURL: storage)
        let reference = try await files.importAttachments([image], existing: []).first
        let card = TaskAttachmentDragItem(reference: try XCTUnwrap(reference), files: files).itemProvider()
        let cardTypes = card.registeredTypeIdentifiers.compactMap(UTType.init)
        XCTAssertEqual(classify(cardTypes), .attachmentCard, "releasing a card over its panel must not re-import it")
        XCTAssertEqual(classify(cardTypes.filter { $0 != TaskDropContent.attachmentCardType }), .files)
    }

    // MARK: - R4 staging

    func testStagingReadsFinderOriginalsInPlaceAndCopiesProvidedContentIntoItsOwnedDirectory() async throws {
        let original = try textFile(named: "Notes.txt")
        let photo = try pngFile(named: "IMG_0001.png")
        let other = try pngFile(named: "IMG_0002.png")
        let staging = try await TaskDroppedFiles.stage([
            finderFile(original),
            providedFile(photo, type: .png, suggestedName: "Photo"),
            providedFile(other, type: .png, suggestedName: "Photo")
        ])
        let owned = try XCTUnwrap(staging.ownedDirectory)
        XCTAssertEqual(staging.urls.count, 3)
        XCTAssertEqual(staging.urls[0].standardizedFileURL.path, original.standardizedFileURL.path, "originals are read in place")
        XCTAssertEqual(staging.urls[1].lastPathComponent, "Photo.png", "the extension matches the provided type")
        XCTAssertEqual(staging.urls[2].lastPathComponent, "Photo.png")
        XCTAssertNotEqual(staging.urls[1], staging.urls[2], "equal names never collide")
        XCTAssertTrue(staging.urls[1...].allSatisfy { $0.path.hasPrefix(owned.path + "/") })
        XCTAssertEqual(try Data(contentsOf: staging.urls[2]), try Data(contentsOf: other))

        staging.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        for url in [original, photo, other] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "discard never touches originals")
        }
    }

    func testPromisedGeneralDocumentsStageWithTheirTypeAndAttach() async throws {
        let (store, _, files) = try makeStore()
        let task = try XCTUnwrap(store.create(title: "Review"))
        let docx = try XCTUnwrap(UTType(filenameExtension: "docx"))
        let eml = try XCTUnwrap(UTType(filenameExtension: "eml"))
        let promisedDocx = try textFile(named: "promise-1", contents: "PK fake docx")
        let promisedMail = try textFile(named: "promise-2", contents: "From: someone")

        let ids = await store.attachStagedFiles(to: task.id) {
            try await TaskDroppedFiles.stage([providedFile(promisedDocx, type: docx, suggestedName: "Report"),
                                              providedFile(promisedMail, type: eml, suggestedName: "Thread")])
        }
        XCTAssertEqual(ids?.count, 2)
        let attached = try XCTUnwrap(store.tasks.first { $0.id == task.id }?.attachments)
        XCTAssertEqual(attached.map(\.filename), ["Report.docx", "Thread.eml"], "a staged copy keeps a real extension")
        XCTAssertEqual(attached.map(\.contentType), [docx, eml])
        for reference in attached {
            let verified = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(verified)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: promisedDocx.path), "originals are only read")
    }

    func testStagingRefusesTextOversizedAndTooManyItemsWithoutLeavingStagedFiles() async throws {
        let before = ownedDropDirectories()
        let photo = try pngFile()

        do {
            _ = try await TaskDroppedFiles.stage([providedFile(photo, type: .png, suggestedName: nil),
                                                  NSItemProvider(object: "Just text" as NSString)])
            XCTFail("text is not a file")
        } catch {
            XCTAssertTrue(error is TaskDropError)
        }

        let huge = root.appendingPathComponent("Huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(AttachmentLimits.maxBytesPerAttachment + 1))
        try handle.close()
        do {
            _ = try await TaskDroppedFiles.stage([providedFile(huge, type: .png, suggestedName: "Huge")])
            XCTFail("an oversized item must be refused before it is copied")
        } catch let error as AttachmentFileStoreError {
            guard case .attachmentTooLarge = error else { return XCTFail("\(error)") }
        }

        let loads = Box(0)
        let tooMany = (0...AttachmentLimits.maxAttachmentsPerNote).map { _ in
            providedFile(photo, type: .png, suggestedName: nil) { loads.value += 1 }
        }
        do {
            _ = try await TaskDroppedFiles.stage(tooMany)
            XCTFail("the batch limit applies before loading")
        } catch let error as AttachmentFileStoreError {
            XCTAssertEqual(error, .tooManyAttachments)
        }
        XCTAssertEqual(loads.value, 0)
        XCTAssertEqual(ownedDropDirectories(), before, "failed staging leaves nothing behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    // MARK: - R4 store import

    func testDroppedFilesAttachToTheParentAndDiscardOnlyTheirStaging() async throws {
        let (store, container, files) = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let child = try XCTUnwrap(store.create(title: "Book flights", parentID: parent.id))
        let original = try textFile(named: "Itinerary.txt")
        let photo = try pngFile()
        let staged = Box<URL?>(nil)

        let ids = await store.attachStagedFiles(to: child.id) {
            let staging = try await TaskDroppedFiles.stage([providedFile(photo, type: .png, suggestedName: "Beach"),
                                                            finderFile(original)])
            staged.value = staging.ownedDirectory
            return staging
        }

        let attached = try XCTUnwrap(ids)
        XCTAssertEqual(attached.count, 2)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)
        let relaunched = TaskStore(container: container, taskImageFiles: files)
        let restoredParent = try XCTUnwrap(relaunched.tasks.first { $0.id == parent.id })
        XCTAssertEqual(restoredParent.attachments.map(\.id), attached, "a child drop resolves to its parent")
        XCTAssertEqual(restoredParent.attachments.map(\.filename), ["Beach.png", "Itinerary.txt"])
        XCTAssertTrue(relaunched.tasks.first { $0.id == child.id }?.attachments.isEmpty == true, "no nested owner")
        for reference in restoredParent.attachments {
            let verified = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(verified)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged.value).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    func testFailedStagingImportOrSaveReportsCalmlyWithoutFalseSuccessOrLeftovers() async throws {
        let fail = Box(false)
        let (store, _, _) = try makeStore(fail: fail)
        let task = try XCTUnwrap(store.create(title: "Keep calm"))
        let original = try textFile(named: "Keep.txt")

        let unsupported = await store.attachStagedFiles(to: task.id) { throw TaskDropError.unsupported }
        XCTAssertNil(unsupported)
        XCTAssertEqual(store.lastErrorMessage, "Couldn’t attach files. Only files and images can be attached.")

        let brokenDirectory = Box<URL?>(nil)
        let broken = await store.attachStagedFiles(to: task.id) {
            var staging = TaskAttachmentStaging()
            let directory = try staging.makeOwnedDirectory()
            let url = directory.appendingPathComponent("Broken.png")
            try Data("not an image".utf8).write(to: url)
            staging.urls = [original, url]
            brokenDirectory.value = directory
            return staging
        }
        XCTAssertNil(broken)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(brokenDirectory.value).path))

        fail.value = true
        let unsaved = await store.attachStagedFiles(to: task.id) { TaskAttachmentStaging(urls: [original]) }
        XCTAssertNil(unsaved, "a failed save is never reported as attached")
        XCTAssertNotNil(store.lastErrorMessage)

        XCTAssertTrue(store.tasks[0].attachments.isEmpty)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)
        XCTAssertEqual(privateDirectories(), [], "every failure removes its private copies")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testOverlappingImportForTheSameOwnerIsRefusedWithAMessage() async throws {
        let (store, _, _) = try makeStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let child = try XCTUnwrap(store.create(title: "Pack", parentID: parent.id))
        let first = try textFile(named: "First.txt")
        let gate = Gate()

        let running = Task { @MainActor in
            await store.attachStagedFiles(to: parent.id) {
                await gate.wait()
                return TaskAttachmentStaging(urls: [first])
            }
        }
        await eventually { gate.isWaiting }
        XCTAssertTrue(store.importingAttachmentTaskIDs.contains(parent.id), "staging runs inside the reservation")
        XCTAssertFalse(TaskFileDrop.canAccept(child.id, store: store), "a child row refuses while its parent imports")

        let staged = Box(false)
        let refused = await store.attachStagedFiles(to: child.id) {
            staged.value = true
            return TaskAttachmentStaging(urls: [first])
        }
        XCTAssertNil(refused)
        XCTAssertFalse(staged.value, "a refused drop loads nothing")
        XCTAssertEqual(store.lastErrorMessage, "Attic is still attaching files to “Trip”. Try again when it finishes.")

        gate.open()
        let ids = await running.value
        XCTAssertEqual(ids?.count, 1)
        XCTAssertEqual(store.tasks.first { $0.id == parent.id }?.attachments.count, 1)
        XCTAssertTrue(TaskFileDrop.canAccept(child.id, store: store))
    }

    // MARK: - R4 gallery cards

    func testGalleryCardCopiesIntoAnotherTaskButNeverIntoItsOwnOwner() async throws {
        let (store, container, files) = try makeStore()
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        let pack = try XCTUnwrap(store.create(title: "Pack", parentID: trip.id))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let photo = try pngFile()
        _ = await store.attachStagedFiles(to: trip.id) { TaskAttachmentStaging(urls: [photo]) }
        let source = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments.first)

        // The card records its identity and owner when the drag begins.
        TaskAttachmentCardDrag.begin(source, store: store)
        XCTAssertEqual(TaskAttachmentCardDrag.current, TaskAttachmentSource(reference: source, ownerID: trip.id))
        XCTAssertFalse(TaskFileDrop.canAccept(.attachmentCard, onto: trip.id, store: store), "its own owner refuses it")
        XCTAssertFalse(TaskFileDrop.canAccept(.attachmentCard, onto: pack.id, store: store), "a child resolves to that owner")
        XCTAssertTrue(TaskFileDrop.canAccept(.attachmentCard, onto: other.id, store: store))
        XCTAssertTrue(TaskAttachmentCardDrag.canCopy(toOwner: nil), "the composer's new task may receive it")
        XCTAssertTrue(TaskFileDrop.canAccept(.files, onto: trip.id, store: store), "files still attach to the owner")

        // Dropped on another task: a verified, separately owned copy.
        let card = TaskAttachmentDragItem(reference: source, files: files).itemProvider()
        let expected = TaskAttachmentCardDrag.current
        let ids = await store.attachCopies(to: other.id) {
            try await TaskAttachmentCardDrag.sources(from: [card], expected: expected)
        }
        let copyID = try XCTUnwrap(ids?.first)
        XCTAssertNil(store.lastErrorMessage)
        let copy = try XCTUnwrap(store.tasks.first { $0.id == other.id }?.attachments.first)
        XCTAssertEqual(copy.id, copyID)
        XCTAssertNotEqual(copy.id, source.id, "the copy has its own identity")
        XCTAssertEqual(copy.digest, source.digest)
        XCTAssertEqual(copy.contentTypeIdentifier, source.contentTypeIdentifier)
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [source], "the source is unchanged")
        XCTAssertEqual(Set(privateDirectories()), [source.id.uuidString, copy.id.uuidString], "no shared storage")
        let relaunched = TaskStore(container: container, taskImageFiles: files)
        XCTAssertEqual(relaunched.tasks.first { $0.id == other.id }?.attachments, [copy])

        // Removing the copy never touches the source's bytes.
        // (Removal is soft until the purge; the purge releases the copy.)
        XCTAssertTrue(store.removeAttachment(copy.id, from: other.id))
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 1)
        await eventually { privateDirectories() == [source.id.uuidString] }
        let sourceStillVerified = try await files.verifiedURL(for: source)
        XCTAssertNotNil(sourceStillVerified)

        // Released over its own family anyway (a stale proposal): refused calmly.
        let before = privateDirectories()
        let own = await store.attachCopies(to: pack.id) {
            try await TaskAttachmentCardDrag.sources(from: [card], expected: expected)
        }
        XCTAssertNil(own)
        XCTAssertEqual(store.lastErrorMessage, "Couldn’t attach files. That attachment already belongs to this task.")
        XCTAssertEqual(privateDirectories(), before)
    }

    func testGalleryCardDropRevalidatesTheMarkerAndTheVerifiedSource() async throws {
        let (store, _, files) = try makeStore()
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        _ = await store.attachStagedFiles(to: trip.id) { [self] in
            TaskAttachmentStaging(urls: [try pngFile(), try textFile(named: "List.txt")])
        }
        let attachments = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments)
        let (photo, list) = (attachments[0], attachments[1])
        let unavailable = "Couldn’t attach files. The attachment is no longer available."

        // A marker that doesn't name the recorded card copies nothing.
        TaskAttachmentCardDrag.begin(list, store: store)
        let mismatched = await store.attachCopies(to: other.id) {
            try await TaskAttachmentCardDrag.sources(from: [TaskAttachmentDragItem(reference: photo, files: files).itemProvider()],
                                                     expected: TaskAttachmentCardDrag.current)
        }
        XCTAssertNil(mismatched)
        XCTAssertEqual(store.lastErrorMessage, unavailable)

        // A drag whose record no longer matches the store copies nothing.
        let stale = TaskAttachmentSource(reference: list, ownerID: other.id)
        XCTAssertThrowsError(try store.verifiedCopySources([stale], excludingOwner: nil))

        // A private copy that fails its digest check is never copied.
        let verifiedList = try await files.verifiedURL(for: list)
        let listURL = try XCTUnwrap(verifiedList)
        try Data("Tampered".utf8).write(to: listURL)
        let card = TaskAttachmentDragItem(reference: list, files: files).itemProvider()
        let tampered = await store.attachCopies(to: other.id) {
            try await TaskAttachmentCardDrag.sources(from: [card], expected: TaskAttachmentCardDrag.current)
        }
        XCTAssertNil(tampered)
        XCTAssertEqual(store.lastErrorMessage, unavailable)
        XCTAssertTrue(store.tasks.first { $0.id == other.id }?.attachments.isEmpty == true)
        XCTAssertEqual(privateDirectories().count, 2, "a refused copy leaves nothing behind")
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty)
    }

    func testGalleryCardDroppedOnTheComposerBecomesAPendingCopy() async throws {
        let (store, _, files) = try makeStore()
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        _ = await store.attachStagedFiles(to: trip.id) { [self] in TaskAttachmentStaging(urls: [try pngFile()]) }
        let source = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments.first)
        TaskAttachmentCardDrag.begin(source, store: store)
        let card = TaskAttachmentDragItem(reference: source, files: files).itemProvider()
        let expected = TaskAttachmentCardDrag.current

        let composer = TaskComposerAttachments()
        composer.add(count: 1, files: files, importing: { existing in
            let sources = try await TaskAttachmentCardDrag.sources(from: [card], expected: expected)
            return try await files.importCopies(of: store.verifiedCopySources(sources, excludingOwner: nil), existing: existing)
        }, reportFailure: { XCTFail("unexpected failure \($0)") })
        await composer.waitForImport()

        let pending = try XCTUnwrap(composer.pending.first)
        XCTAssertNotEqual(pending.id, source.id)
        XCTAssertEqual(pending.digest, source.digest)
        let task = try XCTUnwrap(store.create(title: "Copy", attachments: composer.pending))
        composer.didBind()
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.attachments, [pending])
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [source])
    }

    func testALegacySubtaskCardResolvesToItsParentAndAmbiguityRefuses() throws {
        let (store, _, _) = try makeStore()
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        let pack = try XCTUnwrap(store.create(title: "Pack", parentID: trip.id))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let legacy = TaskImageReference(id: UUID(), filename: "Old.png", digest: String(repeating: "a", count: 64),
                                        contentTypeIdentifier: UTType.png.identifier, byteCount: 1)
        pack.imageReferencesData = try JSONEncoder().encode([legacy])
        XCTAssertEqual(store.attachmentSource(for: legacy.id), TaskAttachmentSource(reference: legacy, ownerID: trip.id))

        other.imageReferencesData = try JSONEncoder().encode([legacy])
        XCTAssertNil(store.attachmentSource(for: legacy.id), "an attachment held by two tasks is refused")
        TaskAttachmentCardDrag.begin(legacy, store: store)
        XCTAssertFalse(TaskAttachmentCardDrag.canCopy(toOwner: other.id))
        XCTAssertFalse(TaskAttachmentCardDrag.canCopy(toOwner: nil))
    }

    func testEndingADropClearsEveryPanelHighlightSource() {
        let target = TaskFileDropTarget()
        target.setTargeted(true, source: "surface")
        target.setTargeted(true, source: "row-a")
        target.setTargeted(false, source: "row-a")
        XCTAssertTrue(target.isTargeted, "the surface never received its exit")
        target.end()
        XCTAssertFalse(target.isTargeted)
        target.setTargeted(true, source: "row-a")
        XCTAssertTrue(target.isTargeted, "a later drag highlights normally")
    }

    func testEveryRowDropEndsThePanelHighlightIncludingReorders() {
        let target = TaskFileDropTarget()
        target.canAccept = { _ in true }
        let began = Box(0)
        let attached = Box(0)
        target.perform = { _, _ in attached.value += 1 }
        let row = TaskRowDropDelegate(
            taskID: UUID(), panelTarget: target, canAcceptAttachment: { _ in true },
            setTaskTargeted: { _ in }, setFileTargeted: { _ in }, performTaskDrop: { _ in },
            beginTaskDrop: { began.value += 1 }, attach: { _, _ in XCTFail("a panel row forwards to the panel") }
        )
        func staleSurface() {
            // A destination the drag crossed whose exit never arrived.
            target.setTargeted(true, source: "surface")
            XCTAssertTrue(target.isTargeted)
        }

        staleSurface()
        XCTAssertTrue(row.perform(.task, taskProvider: { NSItemProvider() }, attachmentProviders: { _ in [] }))
        XCTAssertEqual(began.value, 1)
        XCTAssertFalse(target.isTargeted, "a reorder onto a child row ends the drag for the whole panel")

        staleSurface()
        XCTAssertFalse(row.perform(.task, taskProvider: { nil }, attachmentProviders: { _ in [] }))
        XCTAssertFalse(target.isTargeted, "a task drop without a payload still clears")

        staleSurface()
        XCTAssertFalse(row.perform(.unsupported, taskProvider: { nil }, attachmentProviders: { _ in [] }))
        XCTAssertFalse(target.isTargeted, "a refused drop still clears")

        staleSurface()
        XCTAssertTrue(row.perform(.files, taskProvider: { nil }, attachmentProviders: { _ in [NSItemProvider()] }))
        XCTAssertFalse(target.isTargeted)
        XCTAssertEqual(attached.value, 1)
    }

    // MARK: - R2/R3 storage lifecycle

    /// Dates a private copy (or any item) as if written `age` seconds ago.
    private func backdate(_ url: URL, by age: TimeInterval) throws {
        let date = Date().addingTimeInterval(-age)
        let items = [url] + ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? [])
            .map { url.appendingPathComponent($0) }
        for item in items.reversed() {
            try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: item.path)
        }
    }

    private func privateDirectory(_ reference: TaskImageReference) -> URL {
        storage.appendingPathComponent(reference.id.uuidString)
    }

    func testLaunchSweepRemovesOnlyOldUnreferencedCopiesAndKeepsEveryReplicasFiles() async throws {
        let (store, container, files) = try makeStore()
        let day: TimeInterval = 24 * 60 * 60
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        _ = await store.attachStagedFiles(to: trip.id) { [self] in TaskAttachmentStaging(urls: [try pngFile()]) }
        let bound = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments.first)

        // A physical duplicate of the task that references a different file.
        let replicaImport = try await files.importAttachments([try textFile(named: "Replica.txt")], existing: [])
        let replicaOnly = try XCTUnwrap(replicaImport.first)
        let other = ModelContext(container)
        let duplicate = TaskItem(title: "Trip", createdAt: trip.createdAt)
        duplicate.id = trip.id
        duplicate.updatedAt = trip.updatedAt.addingTimeInterval(-60)
        duplicate.imageReferencesData = try JSONEncoder().encode([replicaOnly])
        other.insert(duplicate)
        try other.save()
        store.refresh()
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [bound], "the visible replica differs")

        // An abandoned draft's copy, a draft copy from moments ago, and
        // something in the tree that isn't a materialization.
        let drafts = try await files.importAttachments([try textFile(named: "Draft.txt"), try textFile(named: "Now.txt")],
                                                       existing: [])
        let (abandoned, recent) = (drafts[0], drafts[1])
        let stray = storage.appendingPathComponent("Unknown")
        try FileManager.default.createDirectory(at: stray.appendingPathComponent(String(repeating: "b", count: 64)),
                                                withIntermediateDirectories: true)
        for url in [privateDirectory(bound), privateDirectory(replicaOnly), privateDirectory(abandoned), stray] {
            try backdate(url, by: 3 * day)
        }
        let dropRoot = root.appendingPathComponent("drops")
        let oldDrop = dropRoot.appendingPathComponent(UUID().uuidString)
        let liveDrop = dropRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: oldDrop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveDrop, withIntermediateDirectories: true)
        try backdate(oldDrop, by: 3 * day)

        let removed = await store.sweepUnreferencedAttachmentStorage(dropStagingRoot: dropRoot)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateDirectory(abandoned).path))
        for reference in [bound, replicaOnly, recent] {
            let kept = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(kept, "\(reference.filename) is referenced by a replica or too recent to judge")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "unknown entries are left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDrop.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDrop.path))

        try backdate(privateDirectory(recent), by: 3 * day)
        let again = await store.sweepUnreferencedAttachmentStorage(dropStagingRoot: dropRoot)
        XCTAssertNil(again, "once per launch")
        let stillThere = try await files.verifiedURL(for: recent)
        XCTAssertNotNil(stillThere)
    }

    func testRemovingAndRestoringAnAttachmentKeepsWhatOnlyADuplicateHoldsThroughTheLaunchSweep() async throws {
        let (store, container, files) = try makeStore()
        let day: TimeInterval = 24 * 60 * 60
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        _ = await store.attachStagedFiles(to: trip.id) { [self] in TaskAttachmentStaging(urls: [try pngFile()]) }
        let bound = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments.first)

        // A physical duplicate that holds the shown attachment and one more.
        let replicaImport = try await files.importAttachments([try textFile(named: "Replica.txt")], existing: [])
        let replicaOnly = try XCTUnwrap(replicaImport.first)
        let other = ModelContext(container)
        let duplicate = TaskItem(title: "Trip", createdAt: trip.createdAt)
        duplicate.id = trip.id
        duplicate.updatedAt = trip.updatedAt.addingTimeInterval(-60)
        duplicate.imageReferencesData = try JSONEncoder().encode([bound, replicaOnly])
        other.insert(duplicate)
        try other.save()
        store.refresh()
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [bound], "the visible replica differs")

        XCTAssertTrue(store.removeAttachment(bound.id, from: trip.id))
        XCTAssertTrue(store.restoreAttachment(bound.id))
        XCTAssertTrue(store.removeAttachment(bound.id, from: trip.id))
        store.refresh()
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [], "the shown copy is still the one shown")

        let tripID = trip.id
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tripID }))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { $0.attachments == [replicaOnly] }, "the duplicate keeps its own attachment")
        XCTAssertTrue(rows.allSatisfy { $0.removedAttachments.map(\.reference) == [bound] })

        // The next launch's sweep, with every copy old enough to judge.
        for url in [privateDirectory(bound), privateDirectory(replicaOnly)] {
            try backdate(url, by: 3 * day)
        }
        let removed = await store.sweepUnreferencedAttachmentStorage(dropStagingRoot: root.appendingPathComponent("drops"))
        XCTAssertEqual(removed, 0, "no file is lost")
        for reference in [bound, replicaOnly] {
            let kept = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(kept, "\(reference.filename) is still referenced by a replica")
        }
    }

    func testRenamingAndAttachingKeepWhatOnlyADuplicateHoldsThroughTheLaunchSweep() async throws {
        let (store, container, files) = try makeStore()
        let day: TimeInterval = 24 * 60 * 60
        let trip = try XCTUnwrap(store.create(title: "Trip"))
        _ = await store.attachStagedFiles(to: trip.id) { [self] in TaskAttachmentStaging(urls: [try pngFile()]) }
        let bound = try XCTUnwrap(store.tasks.first { $0.id == trip.id }?.attachments.first)

        // A physical duplicate that holds an attachment only it knows about.
        let replicaImport = try await files.importAttachments([try textFile(named: "Replica.txt")], existing: [])
        let replicaOnly = try XCTUnwrap(replicaImport.first)
        let other = ModelContext(container)
        let duplicate = TaskItem(title: "Trip", createdAt: trip.createdAt)
        duplicate.id = trip.id
        duplicate.updatedAt = trip.updatedAt.addingTimeInterval(-60)
        duplicate.imageReferencesData = try JSONEncoder().encode([replicaOnly])
        other.insert(duplicate)
        try other.save()
        store.refresh()
        XCTAssertEqual(store.tasks.first { $0.id == trip.id }?.attachments, [bound], "the visible replica differs")

        let visible = try XCTUnwrap(store.tasks.first { $0.id == trip.id })
        XCTAssertTrue(store.rename(visible, to: "Trip to Rome"))
        let attached = await store.attachStagedFiles(to: trip.id) { [self] in
            TaskAttachmentStaging(urls: [try textFile(named: "Tickets.txt")])
        }
        XCTAssertEqual(attached?.count, 1)
        store.refresh()
        let shown = try XCTUnwrap(store.tasks.first { $0.id == trip.id })
        XCTAssertEqual(shown.title, "Trip to Rome")
        XCTAssertEqual(shown.attachments.count, 2)
        XCTAssertEqual(shown.attachments.first, bound, "the shown copy is still the one shown")
        let tickets = try XCTUnwrap(shown.attachments.last)

        let tripID = trip.id
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tripID }))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.title == "Trip to Rome" }, "the rename reaches every replica")
        XCTAssertTrue(rows.contains { $0.attachments == [replicaOnly, tickets] },
                      "the duplicate keeps its own reference and gains the new file")

        // The next launch's sweep, with every copy old enough to judge.
        for reference in [bound, replicaOnly, tickets] {
            try backdate(privateDirectory(reference), by: 3 * day)
        }
        let removed = await store.sweepUnreferencedAttachmentStorage(dropStagingRoot: root.appendingPathComponent("drops"))
        XCTAssertEqual(removed, 0, "no file is lost")
        for reference in [bound, replicaOnly, tickets] {
            let kept = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(kept, "\(reference.filename) is still referenced by a replica")
        }
    }

    func testLaunchSweepDoesNothingWhenAReplicaIsUnreadableOrAnImportIsRunning() async throws {
        let (store, container, files) = try makeStore()
        let orphans = try await files.importAttachments([try textFile(named: "Draft.txt")], existing: [])
        let orphan = try XCTUnwrap(orphans.first)
        try backdate(privateDirectory(orphan), by: 3 * 24 * 60 * 60)
        let dropRoot = root.appendingPathComponent("drops")

        let task = try XCTUnwrap(store.create(title: "Trip"))
        let gate = Gate()
        let running = Task { @MainActor in
            await store.attachStagedFiles(to: task.id) {
                await gate.wait()
                return TaskAttachmentStaging()
            }
        }
        await eventually { gate.isWaiting }
        let whileImporting = await store.sweepUnreferencedAttachmentStorage(dropStagingRoot: dropRoot)
        XCTAssertNil(whileImporting)
        gate.open()
        _ = await running.value

        let context = ModelContext(container)
        let broken = TaskItem(title: "Broken")
        broken.imageReferencesData = Data("not references".utf8)
        context.insert(broken)
        try context.save()
        let relaunched = TaskStore(container: container, taskImageFiles: files)
        let unreadable = await relaunched.sweepUnreferencedAttachmentStorage(dropStagingRoot: dropRoot)
        XCTAssertNil(unreadable, "a replica whose references can't be read stops the sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateDirectory(orphan).path))
    }

    /// A link planted in an owned tree must never let cleanup remove what it
    /// points at, however old or materialization-shaped the destination is.
    func testOwnedFileCleanupNeverActsThroughSymbolicLinks() async throws {
        let fileManager = FileManager.default
        let outside = root.appendingPathComponent("outside")
        let victim = outside.appendingPathComponent(String(repeating: "e", count: 64))
        try fileManager.createDirectory(at: victim, withIntermediateDirectories: true)
        let userFile = victim.appendingPathComponent("keep.txt")
        try Data("not Attic's".utf8).write(to: userFile)

        let files = AttachmentFileStore(rootURL: storage)
        try await files.prepare()
        let linkedID = storage.appendingPathComponent(UUID().uuidString)
        try fileManager.createSymbolicLink(at: linkedID, withDestinationURL: outside)
        let realID = storage.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: realID, withIntermediateDirectories: true)
        let linkedDigest = realID.appendingPathComponent(String(repeating: "f", count: 64))
        try fileManager.createSymbolicLink(at: linkedDigest, withDestinationURL: victim)
        let staging = storage.appendingPathComponent(".staging")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let linkedBatch = staging.appendingPathComponent(UUID().uuidString)
        try fileManager.createSymbolicLink(at: linkedBatch, withDestinationURL: outside)
        let dropRoot = root.appendingPathComponent("drops")
        try fileManager.createDirectory(at: dropRoot, withIntermediateDirectories: true)
        let linkedDrop = dropRoot.appendingPathComponent(UUID().uuidString)
        try fileManager.createSymbolicLink(at: linkedDrop, withDestinationURL: outside)

        // A cutoff of now makes every entry old enough to remove.
        let removed = await files.removeUnreferencedMaterializations(keeping: [], modifiedBefore: Date(), limit: 10)
        XCTAssertEqual(removed, 0)
        try await files.reconcile([])
        XCTAssertEqual(TaskAttachmentStaging.removeAbandoned(modifiedBefore: Date(), in: dropRoot), 0)

        XCTAssertTrue(fileManager.fileExists(atPath: userFile.path), "the destination is untouched")
        for link in [linkedID, linkedDigest, linkedBatch, linkedDrop] {
            XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: link.path), "\(link.lastPathComponent) is skipped")
        }
    }

    // MARK: - R4 reveal after import

    func testImportedAttachmentsRevealOnlyWhereTheUserStillExpectsThem() throws {
        let suite = "TaskAttachmentDropTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let (store, _, _) = try makeStore()
        let uiState = PanelUIState()
        let controller = SubtaskPanelController(store: store, uiState: uiState, settings: AppSettings(defaults: defaults))
        controller.presentationEnabled = false
        controller.mainPanelVisibleForTesting = true
        controller.anchorsAreScreenCoordinatesForTesting = true
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: 400, width: 300, height: 42),
                                        other.id: CGRect(x: 300, y: 450, width: 300, height: 42)])
        controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 400, height: 800))
        let views = controller.panelViews
        let first = [UUID(), UUID()]

        // Presented on Subtasks: switches in place and the new cards enter.
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        let parentOpen = controller.revealContext
        controller.revealImportedAttachments(first, for: parent.id, since: parentOpen)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)
        XCTAssertEqual(views.freshAttachments(for: parent.id), Set(first))

        // Already on Attachments: the open gallery inserts; no second entrance.
        let second = [UUID()]
        controller.revealImportedAttachments(second, for: parent.id, since: parentOpen)
        XCTAssertEqual(views.freshAttachments(for: parent.id), Set(first))

        // Closed while importing: stays closed and forgets the marks.
        controller.dismissTransient()
        controller.revealImportedAttachments(second, for: parent.id, since: parentOpen)
        XCTAssertNil(controller.transientFamilyID)
        XCTAssertTrue(views.freshAttachmentIDs.isEmpty)

        // Another family opened since the drop: never stolen.
        let nothingOpen = controller.revealContext
        controller.openFamilyPanel(for: other.id, focusEntry: false)
        controller.revealImportedAttachments(second, for: parent.id, since: nothingOpen)
        XCTAssertEqual(controller.transientFamilyID, other.id)
        XCTAssertEqual(controller.panelView(for: other.id), .subtasks)
        XCTAssertTrue(views.freshAttachmentIDs.isEmpty)

        // Another family opened and closed again since the drop: nothing is
        // up, but the user moved on, so nothing opens.
        controller.dismissTransient()
        controller.revealImportedAttachments(second, for: parent.id, since: nothingOpen)
        XCTAssertNil(controller.transientFamilyID)
        XCTAssertTrue(views.freshAttachmentIDs.isEmpty)

        // Nothing changed since a main-row drop: the family opens on Attachments.
        let unchanged = controller.revealContext
        controller.revealImportedAttachments(second, for: parent.id, since: unchanged)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)
        XCTAssertEqual(views.freshAttachments(for: parent.id), Set(second))

        // A pinned family switches its own window whatever was transient.
        controller.pinFamily(parent.id)
        controller.showPanelView(.subtasks, for: parent.id)
        controller.revealImportedAttachments(first, for: parent.id, since: nothingOpen)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)

        // The marks expire once the entrance has played.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SubtaskPanelLayout.freshAttachmentLifetime + 0.2))
        XCTAssertTrue(views.freshAttachmentIDs.isEmpty)
    }

    // MARK: - R5 composer

    func testComposerAttachmentsBindToTheNewTaskInItsSingleSave() async throws {
        let saves = Box(0)
        let (store, container, files) = try makeStore(saves: saves)
        let composer = TaskComposerAttachments()
        let photo = try pngFile()
        let list = try textFile(named: "List.txt")

        composer.add(count: 2, files: files, stage: { TaskAttachmentStaging(urls: [photo, list]) },
                     reportFailure: { XCTFail("unexpected failure \($0)") })
        XCTAssertTrue(composer.isImporting)
        XCTAssertFalse(composer.canSubmit(title: "Trip"), "submit waits for the import")
        XCTAssertFalse(composer.canAdd, "one batch at a time")
        await composer.waitForImport()
        XCTAssertEqual(composer.pending.map(\.filename), ["Picture.png", "List.txt"])
        XCTAssertTrue(composer.canSubmit(title: "Trip"))
        XCTAssertFalse(composer.canSubmit(title: "  "))
        for reference in composer.pending {
            let preview = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(preview, "pending items preview before submit")
        }
        XCTAssertEqual(saves.value, 0, "nothing is saved before submit")

        let pending = composer.pending
        let task = try XCTUnwrap(store.create(title: "Trip", attachments: pending))
        composer.didBind()
        XCTAssertEqual(saves.value, 1, "the task and its attachments share one save")
        XCTAssertTrue(composer.isEmpty)

        let relaunched = TaskStore(container: container, taskImageFiles: files)
        XCTAssertEqual(relaunched.tasks.first { $0.id == task.id }?.attachments, pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: list.path))
    }

    func testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry() async throws {
        let fail = Box(false)
        let (store, container, files) = try makeStore(fail: fail)
        let composer = TaskComposerAttachments()
        composer.add(count: 1, files: files, stage: { [self] in TaskAttachmentStaging(urls: [try textFile(named: "Plan.txt")]) },
                     reportFailure: { XCTFail("unexpected failure \($0)") })
        await composer.waitForImport()
        let pending = composer.pending
        XCTAssertEqual(pending.count, 1)

        fail.value = true
        XCTAssertNil(store.create(title: "Plan", attachments: composer.pending))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(composer.pending, pending, "the view binds only after a successful create")
        let kept = try await files.verifiedURL(for: pending[0])
        XCTAssertNotNil(kept, "the private copy survives for the retry")

        fail.value = false
        let task = try XCTUnwrap(store.create(title: "Plan", attachments: composer.pending))
        composer.didBind()
        XCTAssertEqual(TaskStore(container: container, taskImageFiles: files).tasks.first { $0.id == task.id }?.attachments, pending)
    }

    func testRemovingOrCancellingDeletesOnlyTheComposersOwnCopies() async throws {
        let (_, _, files) = try makeStore()
        let composer = TaskComposerAttachments()
        let failures = Box(0)
        let keep = try textFile(named: "Keep.txt")
        let drop = try textFile(named: "Drop.txt")
        composer.add(count: 2, files: files, stage: { TaskAttachmentStaging(urls: [keep, drop]) },
                     reportFailure: { _ in failures.value += 1 })
        await composer.waitForImport()
        XCTAssertEqual(privateDirectories().count, 2)

        composer.remove(try XCTUnwrap(composer.pending.last).id, files: files)
        XCTAssertEqual(composer.pending.map(\.filename), ["Keep.txt"])
        await eventually { privateDirectories().count == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: drop.path), "removing never touches the original")

        // Cancel a dropped batch while it is still loading.
        let gate = Gate()
        let photo = try pngFile()
        let staged = Box<URL?>(nil)
        composer.add(count: 1, files: files, stage: {
            await gate.wait()
            var staging = TaskAttachmentStaging()
            let copy = try staging.makeOwnedDirectory().appendingPathComponent("Photo.png")
            try FileManager.default.copyItem(at: photo, to: copy)
            staging.urls = [copy]
            staged.value = staging.ownedDirectory
            return staging
        }, reportFailure: { _ in failures.value += 1 })
        await eventually { gate.isWaiting }
        composer.cancelImport()
        XCTAssertFalse(composer.isImporting)
        XCTAssertTrue(composer.canAdd)
        gate.open()
        await composer.waitForImport()

        XCTAssertEqual(composer.pending.map(\.filename), ["Keep.txt"])
        XCTAssertEqual(privateDirectories().count, 1, "a cancelled batch leaves no private copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged.value).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(failures.value, 0, "cancelling is not a failure")
    }

    func testComposerLimitsCountItemsAlreadyPending() async throws {
        let (store, _, files) = try makeStore()
        let composer = TaskComposerAttachments()
        composer.add(count: 1, files: files, stage: { [self] in TaskAttachmentStaging(urls: [try textFile(named: "One.txt")]) },
                     reportFailure: { XCTFail("unexpected failure \($0)") })
        await composer.waitForImport()

        let batch = try (0..<AttachmentLimits.maxAttachmentsPerNote).map { try textFile(named: "Item \($0).txt") }
        composer.add(count: batch.count, files: files, stage: { TaskAttachmentStaging(urls: batch) },
                     reportFailure: { store.reportAttachmentImportFailure($0) })
        await composer.waitForImport()
        XCTAssertEqual(composer.pending.count, 1, "a batch past the task limit adds nothing")
        XCTAssertEqual(store.lastErrorMessage,
                       "Couldn’t attach files. A task can hold at most \(AttachmentLimits.maxAttachmentsPerNote) attachments.")
        XCTAssertEqual(privateDirectories().count, 1)
        XCTAssertFalse(composer.isImporting)
    }
}
