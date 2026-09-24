import CoreData
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// The Phase 0 schema and migration gate.
///
/// Decision: lightweight migration, no `VersionedSchema`. Everything Phase 0
/// adds is additive (optional or defaulted attributes on `TaskItem`,
/// `NoteItem` and `CanvasBoardItem`, and the new `ItemLink` entity), which
/// Core Data maps in place with an inferred model. These tests prove it on a
/// store written by the models exactly as they were before Phase 0.
@MainActor
final class SchemaMigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticSchemaMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Registration

    func testBothContainersRegisterEveryModelIncludingPhase0Additions() throws {
        let normal = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let uiTest = try PersistenceController.makeCanvasUITestContainer(reset: true, baseDirectory: root)
        for container in [normal, uiTest] {
            let entities = Dictionary(uniqueKeysWithValues: container.schema.entities.map { ($0.name, $0) })
            XCTAssertEqual(Set(entities.keys), [
                "TaskItem", "NoteItem", "NoteAttachment", "CanvasBoardItem", "CanvasStrokeItem",
                "CanvasImageItem", "CanvasSemanticObjectItem", "ItemLink"
            ])
            let taskAttributes = Set(entities["TaskItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(taskAttributes.isSuperset(of: ["deletedAt", "deletionRootID", "doneLoggedAt", "tagsRaw", "dueDayRaw"]))
            let noteAttributes = Set(entities["NoteItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(noteAttributes.isSuperset(of: ["deletedAt", "tagsRaw"]))
            let boardAttributes = Set(entities["CanvasBoardItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(boardAttributes.isSuperset(of: ["tagsRaw", "purgedAt", "recentlyDeletedAt"]))
        }
    }

    /// CloudKit-compatible: every attribute of every model is optional or has
    /// a default, and nothing is declared unique.
    func testEveryModelIsCloudKitCompatible() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        for entity in container.schema.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty, "\(entity.name) declares a uniqueness constraint")
            for attribute in entity.attributes {
                XCTAssertFalse(attribute.options.contains(.unique), "\(entity.name).\(attribute.name) is unique")
                XCTAssertTrue(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "\(entity.name).\(attribute.name) needs a default or must be optional"
                )
            }
        }
    }

    // MARK: - Migration of a pre-Phase 0 store

    func testCopiedPrePhase0StoreMigratesInPlaceWithoutLosingOrDeletingAnything() async throws {
        let fixture = try await makePrePhase0Fixture()
        // Only copies are ever opened; the fixture itself stays untouched.

        // 1. The UI-test container, through PersistenceController's own path.
        let uiTestBase = root.appendingPathComponent("ui-test-copy", isDirectory: true)
        let bundleComponent = (Bundle.main.bundleIdentifier ?? "unknown-bundle").replacingOccurrences(of: "/", with: "-")
        let uiTestDirectory = uiTestBase
            .appendingPathComponent("AtticCanvasUITests", isDirectory: true)
            .appendingPathComponent(bundleComponent, isDirectory: true)
        try copyStoreFamily(from: fixture.storeURL, to: uiTestDirectory.appendingPathComponent("canvas.store"))
        let migratedUITest = try PersistenceController.makeCanvasUITestContainer(reset: false, baseDirectory: uiTestBase)
        try await assertNothingLost(in: migratedUITest, fixture: fixture)

        // 2. A plain local configuration with the app's schema, as the normal
        // container opens its default store.
        let plainURL = root.appendingPathComponent("plain-copy/default.store")
        try copyStoreFamily(from: fixture.storeURL, to: plainURL)
        let plain = try ModelContainer(
            for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: plainURL, cloudKitDatabase: .none)
        )
        try await assertNothingLost(in: plain, fixture: fixture)

        // The fixture keeps the pre-Phase 0 model: it was never migrated. (Its
        // bytes are not compared: SQLite may checkpoint the writer's WAL into
        // the main file whenever that container is released.)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: fixture.storeURL
        )
        let entityHashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Any])
        XCTAssertNil(entityHashes["ItemLink"], "the original fixture was not migrated")
        XCTAssertNotNil(entityHashes["TaskItem"])
    }

    func testMigratedStoreSurvivesPhase0CleanupAndDeletesWithoutLosingRows() async throws {
        let fixture = try await makePrePhase0Fixture()
        let url = root.appendingPathComponent("cleanup-copy/default.store")
        try copyStoreFamily(from: fixture.storeURL, to: url)
        let container = try ModelContainer(
            for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        let rowsBefore = try rowCounts(in: container)
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: fixture.taskFilesRoot))
        let notes = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: fixture.noteFilesRoot))
        let canvases = CanvasStore(container: container)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let cleanup = DailyCleanupService(
            store: tasks,
            now: { Date() },
            calendar: { Calendar(identifier: .gregorian) },
            purgeRecentlyDeleted: { now, calendar in library.purgeExpired(now: now, calendar: calendar) }
        )

        // The long-finished task moves to the Done log; nothing is deleted.
        XCTAssertEqual(cleanup.performCleanup(), 1)
        XCTAssertEqual(cleanup.performCleanup(), 0)
        XCTAssertEqual(try rowCounts(in: container), rowsBefore)
        XCTAssertEqual(tasks.doneLog().map(\.id), [fixture.oldDoneTaskID])
        XCTAssertTrue(library.recentlyDeleted().contains { $0.ref == AtticItemRef(.canvas, fixture.legacyDeletedCanvasID) })
        // The first cleanup gives it its 30 days (it removes nothing yet).
        XCTAssertNotNil(library.recentlyDeleted().first { $0.ref.id == fixture.legacyDeletedCanvasID }?.retentionStart)

        // Deleting and restoring migrated items keeps every row too.
        XCTAssertTrue(library.delete(AtticItemRef(.task, fixture.parentTaskID)))
        XCTAssertTrue(library.delete(AtticItemRef(.note, fixture.noteID)))
        XCTAssertEqual(try rowCounts(in: container), rowsBefore)
        XCTAssertTrue(library.restore(AtticItemRef(.task, fixture.parentTaskID)))
        XCTAssertTrue(library.restore(AtticItemRef(.note, fixture.noteID)))
        XCTAssertEqual(Set(tasks.subtasks(of: fixture.parentTaskID).map(\.id)), Set(fixture.childTaskIDs))
        XCTAssertEqual(notes.attachments(for: fixture.noteID).count, 2)
        XCTAssertEqual(try rowCounts(in: container), rowsBefore)
    }

    // MARK: - Fixture

    private struct Fixture {
        let storeURL: URL
        let taskFilesRoot: URL
        let noteFilesRoot: URL
        let duplicateTaskID: UUID
        let parentTaskID: UUID
        let childTaskIDs: [UUID]
        let oldDoneTaskID: UUID
        let taskWithFileID: UUID
        let taskFile: TaskImageReference
        let noteID: UUID
        let notePayloads: [UUID: Data]
        let canvasID: UUID
        let legacyDeletedCanvasID: UUID
        let strokeIDs: [UUID]
        let imageID: UUID
        let semanticID: UUID
        let taskTitlesByRow: [String]
        let rowCounts: [String: Int]
    }

    /// Writes a store with the models exactly as they were before Phase 0:
    /// duplicate UUID replicas, a family with subtasks, a long-finished task,
    /// a task file on disk, a note with two attachments (bytes in the store
    /// and files on disk), a live canvas with ink, an image and an object,
    /// and a canvas deleted with the old code.
    private func makePrePhase0Fixture() async throws -> Fixture {
        let storeURL = root.appendingPathComponent("fixture/pre-phase0.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let taskFilesRoot = root.appendingPathComponent("task-files", isDirectory: true)
        let noteFilesRoot = root.appendingPathComponent("note-files", isDirectory: true)

        let source = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let taskSource = source.appendingPathComponent("plan.txt")
        try Data("task file".utf8).write(to: taskSource)
        let noteSources = [source.appendingPathComponent("one.txt"), source.appendingPathComponent("two.txt")]
        try Data("first attachment".utf8).write(to: noteSources[0])
        try Data("second attachment".utf8).write(to: noteSources[1])

        let importedTaskFiles = try await TaskImageFiles(rootURL: taskFilesRoot).importAttachments([taskSource], existing: [])
        let taskFile = try XCTUnwrap(importedTaskFiles.first)
        let importedNoteFiles = try await AttachmentFileStore(rootURL: noteFilesRoot)
            .importFiles(noteSources, baseSortIndex: 0, existingCount: 0, existingBytes: 0)

        let schema = Schema([
            PrePhase0.TaskItem.self, PrePhase0.NoteItem.self, NoteAttachment.self, PrePhase0.CanvasBoardItem.self,
            CanvasStrokeItem.self, CanvasImageItem.self, CanvasSemanticObjectItem.self
        ])
        let duplicateTaskID = UUID(), parentTaskID = UUID(), oldDoneTaskID = UUID(), taskWithFileID = UUID()
        let childTaskIDs = [UUID(), UUID()]
        let noteID = UUID(), canvasID = UUID(), legacyDeletedCanvasID = UUID()
        let strokeIDs = [UUID(), UUID()], imageID = UUID(), semanticID = UUID()
        var notePayloads: [UUID: Data] = [:]
        let old = Date(timeIntervalSince1970: 1_700_000_000)

        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("fixture", schema: schema, url: storeURL, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            context.autosaveEnabled = false
            func task(_ id: UUID, _ title: String, status: String = "todo", parent: UUID? = nil,
                      updatedAt: Date = old, completedAt: Date? = nil) -> PrePhase0.TaskItem {
                let task = PrePhase0.TaskItem()
                task.id = id
                task.title = title
                task.statusRaw = status
                task.createdAt = old
                task.updatedAt = updatedAt
                task.completedAt = completedAt
                task.parentID = parent
                task.manualOrder = 1_024
                return task
            }
            context.insert(task(duplicateTaskID, "Replica A"))
            context.insert(task(duplicateTaskID, "Replica B", updatedAt: old.addingTimeInterval(60)))
            context.insert(task(parentTaskID, "Plan the trip", status: "inProgress"))
            context.insert(task(childTaskIDs[0], "Book flights", parent: parentTaskID))
            context.insert(task(childTaskIDs[1], "Pack", status: "done", parent: parentTaskID, completedAt: old))
            context.insert(task(oldDoneTaskID, "Finished long ago", status: "done", completedAt: old))
            let withFile = task(taskWithFileID, "Read the plan")
            withFile.imageReferencesData = try JSONEncoder().encode([taskFile])
            context.insert(withFile)

            let note = PrePhase0.NoteItem()
            note.id = noteID
            note.title = "Trip notes"
            note.body = "Bring the passport."
            note.createdAt = old
            note.updatedAt = old
            context.insert(note)
            let olderReplica = PrePhase0.NoteItem()
            olderReplica.id = noteID
            olderReplica.title = "Trip notes"
            olderReplica.body = "Bring the passport."
            olderReplica.createdAt = old
            olderReplica.updatedAt = old
            context.insert(olderReplica)
            for (index, imported) in importedNoteFiles.enumerated() {
                context.insert(NoteAttachment(
                    id: imported.id, noteID: noteID, originalFilename: imported.filename,
                    contentTypeIdentifier: imported.contentTypeIdentifier, byteCount: imported.byteCount,
                    sortIndex: Int64(index), contentDigest: imported.digest, createdAt: old,
                    payload: imported.payload
                ))
                notePayloads[imported.id] = imported.payload
            }

            let board = PrePhase0.CanvasBoardItem()
            board.id = canvasID
            board.name = "Sketches"
            board.sortIndex = 1
            context.insert(board)
            let deletedBoard = PrePhase0.CanvasBoardItem()
            deletedBoard.id = legacyDeletedCanvasID
            deletedBoard.name = "Old board"
            deletedBoard.sortIndex = 2
            deletedBoard.tombstoned = true
            deletedBoard.deletedAt = old
            context.insert(deletedBoard)
            let ink = try CanvasStrokeCodec.encode(color: .red, width: 3, points: [.zero, CanvasPoint(x: 4, y: 8)])
            context.insert(CanvasStrokeItem(id: strokeIDs[0], canvasID: canvasID, payload: ink))
            context.insert(CanvasStrokeItem(id: strokeIDs[0], canvasID: canvasID, payload: ink))
            context.insert(CanvasStrokeItem(id: strokeIDs[1], canvasID: canvasID, payload: ink, tombstoned: true, deletedAt: old))
            context.insert(CanvasStrokeItem(canvasID: legacyDeletedCanvasID, payload: ink, tombstoned: true, deletedAt: old))
            context.insert(CanvasImageItem(id: imageID, canvasID: canvasID, encodedData: Data([1, 2, 3, 4]),
                                           pixelWidth: 2, pixelHeight: 2, width: 48, height: 48))
            let object = CanvasSemanticObjectItem(id: semanticID, canvasID: canvasID)
            object.payload = try JSONEncoder().encode(CanvasSemanticContent(text: "Label", color: .ink, strokeWidth: 3))
            context.insert(object)
            try context.save()
        }

        let fixture = Fixture(
            storeURL: storeURL, taskFilesRoot: taskFilesRoot, noteFilesRoot: noteFilesRoot,
            duplicateTaskID: duplicateTaskID, parentTaskID: parentTaskID, childTaskIDs: childTaskIDs,
            oldDoneTaskID: oldDoneTaskID, taskWithFileID: taskWithFileID, taskFile: taskFile,
            noteID: noteID, notePayloads: notePayloads, canvasID: canvasID,
            legacyDeletedCanvasID: legacyDeletedCanvasID, strokeIDs: strokeIDs, imageID: imageID,
            semanticID: semanticID,
            taskTitlesByRow: ["Replica A", "Replica B", "Plan the trip", "Book flights", "Pack",
                              "Finished long ago", "Read the plan"].sorted(),
            rowCounts: [
                "TaskItem": 7, "NoteItem": 2, "NoteAttachment": 2, "CanvasBoardItem": 2,
                "CanvasStrokeItem": 4, "CanvasImageItem": 1, "CanvasSemanticObjectItem": 1, "ItemLink": 0
            ]
        )
        return fixture
    }

    private func assertNothingLost(in container: ModelContainer, fixture: Fixture) async throws {
        XCTAssertEqual(try rowCounts(in: container), fixture.rowCounts)
        let context = ModelContext(container)

        let taskRows = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(taskRows.map(\.title).sorted(), fixture.taskTitlesByRow)
        XCTAssertTrue(taskRows.allSatisfy {
            $0.deletedAt == nil && $0.deletionRootID == nil && $0.doneLoggedAt == nil && $0.tagsRaw.isEmpty && $0.dueDayRaw == nil
        }, "new fields take their defaults")
        XCTAssertEqual(taskRows.filter { $0.id == fixture.duplicateTaskID }.count, 2)
        XCTAssertEqual(Set(taskRows.filter { $0.parentID == fixture.parentTaskID }.map(\.id)), Set(fixture.childTaskIDs))
        XCTAssertEqual(taskRows.first { $0.id == fixture.taskWithFileID }?.attachments, [fixture.taskFile])
        XCTAssertTrue(taskRows.allSatisfy { $0.manualOrder == 1_024 })

        let noteRows = try context.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(noteRows.count, 2)
        XCTAssertTrue(noteRows.allSatisfy { $0.id == fixture.noteID && $0.body == "Bring the passport." && $0.deletedAt == nil })
        let attachments = try context.fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0.payload) }),
                       fixture.notePayloads.mapValues { Optional($0) })

        let boards = try context.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(Set(boards.map(\.name)), ["Sketches", "Old board"])
        XCTAssertTrue(boards.allSatisfy { $0.tagsRaw.isEmpty && $0.purgedAt == nil && $0.recentlyDeletedAt == nil })
        let strokes = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(strokes.filter { $0.id == fixture.strokeIDs[0] }.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasImageItem>()).first?.encodedData, Data([1, 2, 3, 4]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first?.id, fixture.semanticID)

        // The stores present the same content as before.
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: fixture.taskFilesRoot))
        XCTAssertEqual(tasks.tasks.count, 6, "one row per logical task")
        XCTAssertEqual(tasks.task(withID: fixture.duplicateTaskID)?.title, "Replica B")
        XCTAssertEqual(Set(tasks.subtasks(of: fixture.parentTaskID).map(\.id)), Set(fixture.childTaskIDs))
        let fileURL = try await tasks.taskImageFiles.verifiedURL(for: fixture.taskFile)
        XCTAssertNotNil(fileURL, "task files on disk are untouched")

        let notes = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: fixture.noteFilesRoot))
        XCTAssertEqual(notes.notes.map(\.id), [fixture.noteID])
        XCTAssertEqual(notes.attachments(for: fixture.noteID).count, 2)

        let canvases = CanvasStore(container: container)
        XCTAssertTrue(canvases.canvases.contains { $0.id == fixture.canvasID })
        XCTAssertFalse(canvases.canvases.contains { $0.id == fixture.legacyDeletedCanvasID })
        XCTAssertTrue(canvases.selectCanvas(fixture.canvasID))
        XCTAssertEqual(canvases.strokes.map(\.id), [fixture.strokeIDs[0]])
        XCTAssertEqual(canvases.images.map(\.id), [fixture.imageID])
        XCTAssertEqual(canvases.semanticObjects.map(\.id), [fixture.semanticID])
        XCTAssertEqual(try rowCounts(in: container), fixture.rowCounts, "opening the stores wrote no rows away")
    }

    private func rowCounts(in container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        return [
            "TaskItem": try context.fetchCount(FetchDescriptor<TaskItem>()),
            "NoteItem": try context.fetchCount(FetchDescriptor<NoteItem>()),
            "NoteAttachment": try context.fetchCount(FetchDescriptor<NoteAttachment>()),
            "CanvasBoardItem": try context.fetchCount(FetchDescriptor<CanvasBoardItem>()),
            "CanvasStrokeItem": try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
            "CanvasImageItem": try context.fetchCount(FetchDescriptor<CanvasImageItem>()),
            "CanvasSemanticObjectItem": try context.fetchCount(FetchDescriptor<CanvasSemanticObjectItem>()),
            "ItemLink": try context.fetchCount(FetchDescriptor<ItemLink>())
        ]
    }

    private func copyStoreFamily(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: destination.path + suffix))
        }
        // External-storage payloads live beside the store.
        let support = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
        if FileManager.default.fileExists(atPath: support.path) {
            try FileManager.default.copyItem(
                at: support,
                to: destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
            )
        }
    }
}

/// The three models Phase 0 changes, exactly as they were stored before it
/// (stored attributes only). Everything else is unchanged and used as is.
private enum PrePhase0 {
    @Model final class TaskItem {
        var id: UUID = UUID()
        var title: String = ""
        var statusRaw: String = "todo"
        var priorityRaw: String = "none"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        var parentID: UUID? = nil
        var imageReferencesData: Data? = nil
        init() {}
    }

    @Model final class NoteItem {
        var id: UUID = UUID()
        var title: String = ""
        var body: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        init() {}
    }

    @Model final class CanvasBoardItem {
        var id: UUID = UUID()
        var name: String = "Canvas"
        var sortIndex: Int64 = 0
        var formatVersion: Int = 1
        var clearGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }
}
