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
        root = ownedTemporaryDirectory(prefix: "AtticSchemaMigration")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {

    }

    // MARK: - Registration

    func testBothContainersRegisterEveryModelIncludingPhase0Additions() throws {
        let normal = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let uiTest = try PersistenceController.makeCanvasUITestContainer(reset: true, baseDirectory: root)
        for container in [normal, uiTest] {
            let entities = Dictionary(uniqueKeysWithValues: container.schema.entities.map { ($0.name, $0) })
            XCTAssertEqual(Set(entities.keys), [
                "TaskItem", "NoteItem", "NoteAttachment", "CanvasBoardItem", "CanvasStrokeItem",
                "CanvasImageItem", "CanvasSemanticObjectItem", "ItemLink", "NoteVersion", "NotePendingEdit", "StoreMaintenance",
                "TagColour",
                "OperationReceipt", "TaskNoteAssociation", "TaskDeletionPreservation", "TaskAttachmentMigrationRecord"
            ])
            let taskAttributes = Set(entities["TaskItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(taskAttributes.isSuperset(of: [
                "deletedAt", "deletionRootID", "deletionMembersRaw", "removedAttachmentsData",
                "doneLoggedAt", "tagsRaw", "dueDayRaw"
            ]))
            let attachmentAttributes = Set(entities["NoteAttachment"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(attachmentAttributes.contains("deletedAt"))
            let noteAttributes = Set(entities["NoteItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(noteAttributes.isSuperset(of: ["deletedAt", "deletedAttachmentIDsRaw", "tagsRaw"]))
            // Phase 2: the note format fields (all defaulted or optional).
            // The guarded getter uses the existing content column through
            // originalName. The copied pre-Phase-0 fixture below separately
            // verifies compatibility and attachment byte preservation.
            XCTAssertTrue(noteAttributes.isSuperset(of: ["contentStorage", "contentFingerprint", "contentFormat", "plainText", "taskID", "revision", "revisionID"]))
            let boardAttributes = Set(entities["CanvasBoardItem"]?.attributes.map(\.name) ?? [])
            XCTAssertTrue(boardAttributes.isSuperset(of: ["tagsRaw", "purgedAt", "recentlyDeletedAt", "deletedContentCount"]))
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

    func testDailyToRedesignDiffIsEntirelyAdditiveAndInfersAMapping() throws {
        let old = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: Self.prePhase0Types))
        let current = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes))
        for entity in old.entities {
            let destination = try XCTUnwrap(current.entitiesByName[try XCTUnwrap(entity.name)])
            XCTAssertEqual(destination.renamingIdentifier, entity.renamingIdentifier)
            XCTAssertEqual(destination.uniquenessConstraints.count, 0)
            XCTAssertTrue(entity.relationshipsByName.isEmpty)
            XCTAssertTrue(destination.relationshipsByName.isEmpty)
            for attribute in entity.attributesByName.values {
                let storageName = attribute.renamingIdentifier ?? attribute.name
                let retained = try XCTUnwrap(destination.attributesByName.values.first {
                    ($0.renamingIdentifier ?? $0.name) == storageName
                })
                XCTAssertEqual(retained.attributeType, attribute.attributeType)
                XCTAssertEqual(retained.isOptional, attribute.isOptional)
                XCTAssertEqual(retained.renamingIdentifier ?? retained.name, attribute.renamingIdentifier ?? attribute.name)
                XCTAssertEqual(retained.allowsExternalBinaryDataStorage, attribute.allowsExternalBinaryDataStorage)
            }
            for attribute in destination.attributesByName.values where entity.attributesByName[attribute.name] == nil {
                XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil,
                              "Added fields must be optional or defaulted")
            }
        }
        XCTAssertEqual(Set(current.entitiesByName.keys).subtracting(old.entitiesByName.keys),
                       ["ItemLink", "NoteVersion", "NotePendingEdit", "StoreMaintenance", "TagColour",
                        "OperationReceipt", "TaskNoteAssociation", "TaskDeletionPreservation", "TaskAttachmentMigrationRecord"])
        XCTAssertEqual(current.entitiesByName["NoteItem"]?.attributesByName["contentFormat"]?.defaultValue as? Int, 0)
        XCTAssertEqual(current.entitiesByName["TaskItem"]?.attributesByName["listOrderVersion"]?.defaultValue as? Int, 0)
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: current)
    }

    func testCopiedPrePhase0StorePurgesOldNotesAndPreservesOtherContent() async throws {
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
        try await assertOwnerApprovedUpgrade(in: migratedUITest, fixture: fixture)

        // 2. The normal app container, through PersistenceController's real
        // configuration code (local-only, as this build runs), relocated to a
        // copy of the fixture.
        let normal = try openThroughAppContainer(copyOf: fixture, in: "app-copy")
        try await assertOwnerApprovedUpgrade(in: normal, fixture: fixture)
        XCTAssertEqual(
            try storedEntityHashes(at: PersistenceController.makeConfiguration(
                cloudSyncEnabled: false, storeDirectory: root.appendingPathComponent("app-copy")
            ).url),
            Self.currentEntityHashes(),
            "the copy was migrated to the current schema"
        )

        // The fixture keeps the pre-Phase 0 schema: it was never migrated.
        // (Its bytes are not compared: SQLite may checkpoint the writer's WAL
        // into the main file whenever that container is released.)
        XCTAssertEqual(try storedEntityHashes(at: fixture.storeURL), Self.baseRevisionEntityHashes)
    }

    /// The fixture is written by the exact models of revision f2c737a: their
    /// entity hashes match the ones `Scripts/print_model_hashes.sh f2c737a`
    /// prints by compiling those classes straight from git.
    func testFixtureModelsAreExactlyThoseOfTheBaseRevision() throws {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: Self.prePhase0Types))
        XCTAssertEqual(model.entityVersionHashesByName.mapValues { $0.base64EncodedString() }, Self.baseRevisionEntityHashes)
        XCTAssertNotEqual(Self.currentEntityHashes()["TaskItem"], Self.baseRevisionEntityHashes["TaskItem"],
                          "the current schema did change, so the migration is exercised")
    }

    /// Output of `Scripts/print_model_hashes.sh f2c737a`.
    static let baseRevisionEntityHashes: [String: String] = [
        "CanvasBoardItem": "RQCdMDqmwSALjM3eesGzde95LGxgsjDp4Nz2b0M4f6U=",
        "CanvasImageItem": "v573ynq4BZiJW+mB2ROgcZY5PlW8EVoMMWULY4LXa+4=",
        "CanvasSemanticObjectItem": "JB95MNP0sEl8rziTevhdFLpkqJbzdnJ0lihVtKDUdDo=",
        "CanvasStrokeItem": "IuDxJ8Sb5cHNWGoGnLPfATf7Wn7SWYURafOn0STTY+k=",
        "NoteAttachment": "BXA9vdPGdxKTk58FvBDdb6685ZBKbVvvU8IxUL6CSSQ=",
        "NoteItem": "+HOd7ZYY6fFtZ5nNQvDL9AQfw0R0PxWLHtLhmzK57rI=",
        "TaskItem": "HWgF0cQXDAHDo8a3u6iOcFPvwPCHFl9ys8bODKqiLV0="
    ]

    static let prePhase0Types: [any PersistentModel.Type] = [
        PrePhase0.TaskItem.self, PrePhase0.NoteItem.self, PrePhase0.NoteAttachment.self,
        PrePhase0.CanvasBoardItem.self, PrePhase0.CanvasStrokeItem.self, PrePhase0.CanvasImageItem.self,
        PrePhase0.CanvasSemanticObjectItem.self
    ]

    static func currentEntityHashes() -> [String: String] {
        NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes)?
            .entityVersionHashesByName.mapValues { $0.base64EncodedString() } ?? [:]
    }

    private func storedEntityHashes(at url: URL) throws -> [String: String] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        let hashes = try XCTUnwrap(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        return hashes.mapValues { $0.base64EncodedString() }
    }

    /// Copies the fixture to where the app's own configuration puts its store
    /// (in `directory`) and opens it with `PersistenceController.makeContainer`.
    private func openThroughAppContainer(copyOf fixture: Fixture, in directory: String) throws -> ModelContainer {
        let storeDirectory = root.appendingPathComponent(directory, isDirectory: true)
        let url = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: storeDirectory).url
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, storeDirectory.standardizedFileURL)
        try copyStoreFamily(from: fixture.storeURL, to: url)
        return try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: storeDirectory)
    }

    func testMigratedStoreSurvivesPhase0CleanupAndDeletesWithoutLosingRows() async throws {
        let fixture = try await makePrePhase0Fixture()
        let container = try openThroughAppContainer(copyOf: fixture, in: "cleanup-copy")
        let rowsBefore = try rowCounts(in: container)
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: fixture.taskFilesRoot))
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: fixture.noteFilesRoot)))
        let canvases = CanvasStore(container: container)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let cleanup = DailyCleanupService(
            store: tasks,
            now: { Date() },
            calendar: { Calendar(identifier: .gregorian) },
            purgeRecentlyDeleted: { now, calendar in library.purgeExpired(now: now, calendar: calendar) }
        )

        // The long-finished task moves to the Done log; nothing is deleted.
        // The canvas deleted before Phase 0 gets its 30 days from now: the
        // first cleanup stamps it and removes nothing.
        XCTAssertEqual(cleanup.performCleanup(), 1)
        XCTAssertEqual(cleanup.performCleanup(), 0)
        XCTAssertEqual(try rowCounts(in: container), rowsBefore)
        XCTAssertEqual(tasks.doneLog().map(\.id), [fixture.oldDoneTaskID])
        XCTAssertTrue(library.recentlyDeleted().contains { $0.ref == AtticItemRef(.canvas, fixture.legacyDeletedCanvasID) })
        XCTAssertNotNil(library.recentlyDeleted().first { $0.ref.id == fixture.legacyDeletedCanvasID }?.retentionStart)

        // Deleting and restoring migrated items keeps every row too.
        XCTAssertTrue(library.delete(AtticItemRef(.task, fixture.parentTaskID)))
        XCTAssertFalse(library.delete(AtticItemRef(.note, fixture.noteID)), "the old family was purged once at store open")
        XCTAssertEqual(try rowCounts(in: container), rowsBefore)
        XCTAssertTrue(library.restore(AtticItemRef(.task, fixture.parentTaskID)))
        XCTAssertFalse(library.restore(AtticItemRef(.note, fixture.noteID)))
        XCTAssertEqual(Set(tasks.subtasks(of: fixture.parentTaskID).map(\.id)), Set(fixture.childTaskIDs))
        XCTAssertTrue(notes.attachments(for: fixture.noteID).isEmpty)
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

        let schema = Schema(Self.prePhase0Types)
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
            func task(_ id: UUID, _ title: String, status: TaskStatus = .todo, parent: UUID? = nil,
                      updatedAt: Date = old, completedAt: Date? = nil) -> PrePhase0.TaskItem {
                PrePhase0.TaskItem(id: id, title: title, status: status, createdAt: old, updatedAt: updatedAt,
                                   completedAt: completedAt, manualOrder: 1_024, parentID: parent)
            }
            context.insert(task(duplicateTaskID, "Replica A"))
            context.insert(task(duplicateTaskID, "Replica B", updatedAt: old.addingTimeInterval(60)))
            context.insert(task(parentTaskID, "Plan the trip", status: .inProgress))
            context.insert(task(childTaskIDs[0], "Book flights", parent: parentTaskID))
            context.insert(task(childTaskIDs[1], "Pack", status: .done, parent: parentTaskID, completedAt: old))
            context.insert(task(oldDoneTaskID, "Finished long ago", status: .done, completedAt: old))
            let withFile = task(taskWithFileID, "Read the plan")
            withFile.imageReferencesData = try JSONEncoder().encode([taskFile])
            context.insert(withFile)

            for _ in 0..<2 {
                context.insert(PrePhase0.NoteItem(id: noteID, title: "Trip notes", body: "Bring the passport.",
                                                  createdAt: old, updatedAt: old))
            }
            for (index, imported) in importedNoteFiles.enumerated() {
                context.insert(PrePhase0.NoteAttachment(
                    id: imported.id, noteID: noteID, originalFilename: imported.filename,
                    contentTypeIdentifier: imported.contentTypeIdentifier, byteCount: imported.byteCount,
                    sortIndex: Int64(index), contentDigest: imported.digest, createdAt: old,
                    payload: imported.payload
                ))
                notePayloads[imported.id] = imported.payload
            }

            // The default canvas keeps the old default identity.
            context.insert(PrePhase0.CanvasBoardItem(createdAt: old))
            context.insert(PrePhase0.CanvasBoardItem(id: canvasID, name: "Sketches", sortIndex: 1, createdAt: old))
            context.insert(PrePhase0.CanvasBoardItem(id: legacyDeletedCanvasID, name: "Old board", sortIndex: 2,
                                                     tombstoned: true, createdAt: old, deletedAt: old))
            let ink = try CanvasStrokeCodec.encode(color: .red, width: 3, points: [.zero, CanvasPoint(x: 4, y: 8)])
            context.insert(PrePhase0.CanvasStrokeItem(id: strokeIDs[0], canvasID: canvasID, payload: ink))
            context.insert(PrePhase0.CanvasStrokeItem(id: strokeIDs[0], canvasID: canvasID, payload: ink))
            context.insert(PrePhase0.CanvasStrokeItem(id: strokeIDs[1], canvasID: canvasID, payload: ink,
                                                      tombstoned: true, deletedAt: old))
            context.insert(PrePhase0.CanvasStrokeItem(canvasID: legacyDeletedCanvasID, payload: ink,
                                                      tombstoned: true, deletedAt: old))
            context.insert(PrePhase0.CanvasImageItem(id: imageID, canvasID: canvasID, encodedData: Data([1, 2, 3, 4]),
                                                     pixelWidth: 2, pixelHeight: 2, width: 48, height: 48))
            let object = PrePhase0.CanvasSemanticObjectItem(id: semanticID, canvasID: canvasID)
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
                "TaskItem": 7, "NoteItem": 2, "NoteAttachment": 2, "CanvasBoardItem": 3,
                "CanvasStrokeItem": 4, "CanvasImageItem": 1, "CanvasSemanticObjectItem": 1, "ItemLink": 0
            ]
        )
        return fixture
    }

    private func assertOwnerApprovedUpgrade(in container: ModelContainer, fixture: Fixture) async throws {
        // Owner decision 2026-10-09: old Notes are intentionally deleted;
        // every unrelated pre-Phase 0 invariant below still applies.
        var expected = fixture.rowCounts
        expected["NoteItem"] = 0; expected["NoteAttachment"] = 0
        XCTAssertEqual(try rowCounts(in: container), expected)
        let context = ModelContext(container)

        let taskRows = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(taskRows.map(\.title).sorted(), fixture.taskTitlesByRow)
        XCTAssertTrue(taskRows.allSatisfy {
            $0.deletedAt == nil && $0.deletionRootID == nil && $0.deletionMembersRaw.isEmpty
                && $0.removedAttachmentsData == nil && $0.doneLoggedAt == nil && $0.tagsRaw.isEmpty && $0.dueDayRaw == nil
        }, "new fields take their defaults")
        XCTAssertEqual(taskRows.filter { $0.id == fixture.duplicateTaskID }.count, 2)
        XCTAssertEqual(Set(taskRows.filter { $0.parentID == fixture.parentTaskID }.map(\.id)), Set(fixture.childTaskIDs))
        XCTAssertEqual(taskRows.first { $0.id == fixture.taskWithFileID }?.attachments, [fixture.taskFile])
        XCTAssertTrue(taskRows.allSatisfy { $0.manualOrder == 1_024 })

        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteItem>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteAttachment>()).isEmpty)
        let boards = try context.fetch(FetchDescriptor<CanvasBoardItem>())
        XCTAssertEqual(Set(boards.map(\.name)), ["Canvas", "Sketches", "Old board"])
        XCTAssertTrue(boards.contains { $0.id == CanvasBoardItem.logicalBoardID && $0.name == "Canvas" })
        XCTAssertTrue(boards.allSatisfy {
            $0.tagsRaw.isEmpty && $0.purgedAt == nil && $0.recentlyDeletedAt == nil && $0.deletedContentCount == nil
        })
        let strokes = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTAssertEqual(strokes.filter { $0.id == fixture.strokeIDs[0] }.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasImageItem>()).first?.encodedData, Data([1, 2, 3, 4]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first?.id, fixture.semanticID)

        // Live Tasks and Canvas still present the same content as before.
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: fixture.taskFilesRoot))
        XCTAssertEqual(tasks.tasks.count, 6, "one row per logical task")
        XCTAssertEqual(tasks.task(withID: fixture.duplicateTaskID)?.title, "Replica B")
        XCTAssertEqual(Set(tasks.subtasks(of: fixture.parentTaskID).map(\.id)), Set(fixture.childTaskIDs))
        let fileURL = try await tasks.taskImageFiles.verifiedURL(for: fixture.taskFile)
        XCTAssertNotNil(fileURL, "task files on disk are untouched")

        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: fixture.noteFilesRoot)))
        XCTAssertTrue(notes.notes.isEmpty)
        XCTAssertTrue(notes.attachments(for: fixture.noteID).isEmpty)

        let canvases = CanvasStore(container: container)
        XCTAssertEqual(Set(canvases.canvases.map(\.id)), [CanvasBoardItem.logicalBoardID, fixture.canvasID])
        XCTAssertFalse(canvases.canvases.contains { $0.id == fixture.legacyDeletedCanvasID })
        XCTAssertTrue(canvases.selectCanvas(fixture.canvasID))
        XCTAssertEqual(canvases.strokes.map(\.id), [fixture.strokeIDs[0]])
        XCTAssertEqual(canvases.images.map(\.id), [fixture.imageID])
        XCTAssertEqual(canvases.semanticObjects.map(\.id), [fixture.semanticID])
        XCTAssertEqual(try rowCounts(in: container), expected, "opening presentation stores makes no further deletions")
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

/// Frozen persisted TaskItem schema at 596c5b1d, before task time.
private enum BeforeTaskTime {
    @Model final class TaskItem {
        var id: UUID = UUID()
        var associationGeneration: Int64 = 0
        var title: String = ""
        var statusRaw: String = TaskStatus.todo.rawValue
        var priorityRaw: String = TaskPriority.none.rawValue
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        var parentID: UUID? = nil
        var imageReferencesData: Data? = nil
        var deletedAt: Date? = nil
        var deletionGroupID: UUID? = nil
        var deletionRootID: UUID? = nil
        var deletionMembersRaw: String = ""
        var removedAttachmentsData: Data? = nil
        var doneLoggedAt: Date? = nil
        var tagsRaw: String = ""
        var dueDayRaw: String? = nil
        var listOrderVersion: Int = 0
        var completedFromRaw: String? = nil
        var completedFromOrder: Int64? = nil
        init(title: String, dueDayRaw: String?) {
            self.title = title
            self.dueDayRaw = dueDayRaw
        }
    }
}

@MainActor
final class TaskTimeTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)
    private var today: DueDay { DueDay(year: 2026, month: 10, day: 30)! }
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))! }

    func testCurrentUnversionedStoreMigratesAndPreservesTasksAndDates() throws {
        let root = ownedTemporaryDirectory(prefix: "TaskTimeMigration")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.store")
        let oldTypes: [any PersistentModel.Type] = [BeforeTaskTime.TaskItem.self]
            + PersistenceController.appModelTypes.filter { $0 != TaskItem.self }
        let schema = Schema(oldTypes)
        let oldModel = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: oldTypes))
        let newModel = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes))
        let oldTask = try XCTUnwrap(oldModel.entitiesByName["TaskItem"])
        let newTask = try XCTUnwrap(newModel.entitiesByName["TaskItem"])
        // Compiled from git show 596c5b1d:Attic/Models/TaskItem.swift;
        // computed-property support types do not participate in this hash.
        XCTAssertEqual(oldTask.versionHash.base64EncodedString(), "H9E7jlZHVdrTGbDleGmsGH2CPik59C5H9Eve8rtuR5c=")
        XCTAssertEqual(Set(newTask.attributesByName.keys).subtracting(oldTask.attributesByName.keys), ["dueTimeMinutesRaw"])
        XCTAssertTrue(try XCTUnwrap(newTask.attributesByName["dueTimeMinutesRaw"]).isOptional)
        XCTAssertTrue(newTask.uniquenessConstraints.isEmpty)
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: oldModel, destinationModel: newModel)
        let ids: [UUID] = try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations:
                ModelConfiguration("fixture", schema: schema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let dated = BeforeTaskTime.TaskItem(title: "Keep date", dueDayRaw: today.rawValue)
            let undated = BeforeTaskTime.TaskItem(title: "Keep undated", dueDayRaw: nil)
            context.insert(dated); context.insert(undated)
            try context.save()
            return [dated.id, undated.id]
        }
        let current = Schema(PersistenceController.appModelTypes)
        let container = try ModelContainer(for: current, configurations:
            ModelConfiguration("fixture", schema: current, url: url, cloudKitDatabase: .none))
        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(rows.map(\.id)), Set(ids))
        XCTAssertEqual(rows.first { $0.id == ids[0] }?.title, "Keep date")
        XCTAssertEqual(rows.first { $0.id == ids[0] }?.dueDay, today)
        XCTAssertNil(rows.first { $0.id == ids[1] }?.dueDay)
        XCTAssertTrue(rows.allSatisfy { $0.dueTimeMinutes == nil })
    }

    func testSetChangeAndClearTimeUndoRedoAndReopen() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today)])?.first)
        for (before, after) in [(nil, 960), (960, 990), (990, nil)] as [(Int?, Int?)] {
            XCTAssertTrue(library.updateTask(task.id, dueTimeMinutes: .some(after)).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, after)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, before)
            XCTAssertTrue(library.redo(in: .tasks).isApplied)
            XCTAssertEqual(task.dueTimeMinutes, after)
        }
        XCTAssertTrue(library.updateListedTasks([task.id], dueTimeMinutes: .some(0)).isApplied)
        let reopened = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(reopened.dueTimeMinutes, 0)
        XCTAssertEqual(reopened.dueDay, today)
    }

    func testClearingDateAndMovingToLaterClearTimeAndUndoRestoresBoth() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 990)])?.first)
        XCTAssertTrue(library.updateTaskFields([task.id], dueDay: .some(nil)).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.dueDay, today); XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.updateTask(task.id, status: .backlog).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(task.dueDay, today); XCTAssertEqual(task.dueTimeMinutes, 990)
        task.dueDay = nil
        XCTAssertNil(task.dueTimeMinutes)
        task.dueTimeMinutes = 60
        XCTAssertNil(task.dueTimeMinutes, "a time cannot exist without a date")
    }

    func testTimeOnlyDraftInfersTodayAndPersistsThroughBothComposerBuilders() throws {
        let parser = TaskTextParser(calendar: calendar, now: { self.noon })
        let built = try XCTUnwrap(TaskDraftBuilder(parser: parser).draft(fromLine: "Call 4:30 pm"))
        let composed = try XCTUnwrap(TaskAddBarText(text: "Call 16.30").draft(parser: parser, status: .todo))
        XCTAssertEqual(built, composed)
        XCTAssertEqual(built.dueDay, today); XCTAssertEqual(built.dueTimeMinutes, 990)
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([built])?.first)
        XCTAssertEqual(task.dueTimeMinutes, 990)
    }

    func testTitleShorthandCommitsTimeThroughTasksAndTaskPageUndo() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Call"))
        let parser = TaskTextParser(calendar: calendar, now: { self.noon })
        let model = TasksPageModel(library: library, services: TasksPageServices(
            now: { self.noon }, calendar: { self.calendar }, locale: Locale(identifier: "en_GB")))
        model.beginEditingTitle(task.id)
        model.editingTitle = "Call tomorrow 4pm"
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(task.title, "Call"); XCTAssertEqual(task.dueTimeMinutes, 960)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        let history = WorkspaceHistory(route: library.undo, historyID: .tasks)
        let page = TaskNotePageModel(taskID: task.id, store: store, library: library, history: history,
                                    defaults: nil, parser: parser, calendar: calendar)
        page.beginEditingTitle()
        page.titleEdit.text = "Call tomorrow 4:30 pm"
        XCTAssertTrue(page.commitTitle())
        XCTAssertEqual(task.title, "Call"); XCTAssertEqual(task.dueTimeMinutes, 990)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
    }

    func testTasksWithinDaySortTimedFirstAndKeepUntimedAndEqualTimeOrder() throws {
        let store = try makeTestStore()
        let tasks = try XCTUnwrap(store.commit([
            TaskDraft(title: "Untimed A", dueDay: today),
            TaskDraft(title: "Late", dueDay: today, dueTimeMinutes: 990),
            TaskDraft(title: "Early A", dueDay: today, dueTimeMinutes: 60),
            TaskDraft(title: "Untimed B", dueDay: today),
            TaskDraft(title: "Early B", dueDay: today, dueTimeMinutes: 60),
        ]))
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices(
            now: { self.noon }, calendar: { self.calendar }, locale: Locale(identifier: "en_GB")))
        let before = store.snapshot(for: .tasks).sections.flatMap(\.tasks)
        let stableTimed = before.filter { [tasks[2].id, tasks[4].id].contains($0.id) }.map(\.id)
        let stableUntimed = before.filter { [tasks[0].id, tasks[3].id].contains($0.id) }.map(\.id)
        XCTAssertEqual(model.rows(for: .now).map(\.id), stableTimed + [tasks[1].id] + stableUntimed)
    }

    func testInvalidAndUndatedTimeWritesAreRefusedAndMovingDateKeepsTime() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Undated"))
        XCTAssertFalse(store.update(task, dueTimeMinutes: .some(60)))
        XCTAssertNil(task.dueDay); XCTAssertNil(task.dueTimeMinutes)
        XCTAssertTrue(store.update(task, dueDay: .some(today), dueTimeMinutes: .some(60)))
        for value in [-1, 1440] {
            XCTAssertFalse(store.update(task, dueTimeMinutes: .some(value)))
            XCTAssertEqual(task.dueTimeMinutes, 60)
        }
        let next = DueDay(year: 2026, month: 10, day: 31)!
        XCTAssertTrue(store.update(task, dueDay: .some(next)))
        XCTAssertEqual(task.dueDay, next); XCTAssertEqual(task.dueTimeMinutes, 60)
        let copy = try XCTUnwrap(store.duplicate(taskIDs: [task.id])?.first)
        XCTAssertEqual(copy.dueDay, next); XCTAssertEqual(copy.dueTimeMinutes, 60)
    }

    func testFailedTimeSaveRollsBackAndDoesNotRegisterUndo() throws {
        var fails = false
        let store = try makeTestStore(persist: { context in
            if fails { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        fails = true
        XCTAssertFalse(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        XCTAssertEqual(task.dueTimeMinutes, 60)
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
    }

    func testTimeMutationUpdatesReplicasAndUndoPreservesANewerSchedule() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let context = ModelContext(store.container)
        let duplicate = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt,
                                 updatedAt: task.updatedAt.addingTimeInterval(-60))
        duplicate.dueDay = today
        duplicate.dueTimeMinutes = 90
        context.insert(duplicate); try context.save(); store.refresh()
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTask(task.id, dueTimeMinutes: .some(120)).isApplied)
        let copies = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(copies.map(\.dueTimeMinutes), [120, 120])
        // A later date edit owns its paired time. Undo must preserve that schedule.
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(DueDay(year: 2026, month: 11, day: 1)!)))
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(copies.allSatisfy { $0.dueTimeMinutes == 120 })
    }

    func testAgendaOrdersFloatingClocksAcrossTheSpringDSTGap() {
        let day = DueDay(year: 2026, month: 3, day: 29)!
        let start = day.startDate(in: calendar)!
        let afterGap = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: start)!
        let event = CalendarEvent(id: "after-gap", title: "Event", start: afterGap,
            end: afterGap.addingTimeInterval(1800), isAllDay: false, calendarTitle: "Test",
            colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        let task = CalendarTaskEntry(id: UUID(), title: "Floating clock", due: day, isOpen: true, dueTimeMinutes: 90)
        let group = CalendarAgenda.groups(selected: day, clock: .init(today: today, now: noon),
            events: [event], tasks: [task], calendar: calendar)[0]
        XCTAssertEqual(group.items.map(\.id), ["task-" + task.id.uuidString, "event-after-gap"])
    }

    func testExplicitTimeWritesReconcileNoOpReplicasAndRefuseUndatedCopies() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.commit([TaskDraft(title: "Call", dueDay: today, dueTimeMinutes: 60)])?.first)
        let context = ModelContext(store.container)
        let copy = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt,
                            updatedAt: task.updatedAt.addingTimeInterval(-60))
        copy.dueDay = today; copy.dueTimeMinutes = 90
        context.insert(copy); try context.save(); store.refresh()
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueTimeMinutes: .some(60)))
        let changed = ModelContext(store.container)
        let copies = try changed.fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(copies.allSatisfy { $0.dueTimeMinutes == 60 })
        let replica = try XCTUnwrap(copies.first { $0.persistentModelID == copy.persistentModelID })
        replica.dueDay = nil; try changed.save(); store.refresh()
        XCTAssertFalse(store.update(try XCTUnwrap(store.task(withID: task.id)), dueTimeMinutes: .some(120)))
        let refused = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(refused.filter { $0.dueDay == today }.map(\.dueTimeMinutes), [60])
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(today), dueTimeMinutes: .some(120)))
        XCTAssertTrue(try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).allSatisfy {
            $0.dueDay == today && $0.dueTimeMinutes == 120
        })
    }

    func testMakingAChildOfLaterStandaloneClearsScheduleAndUndoRestoresIt() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Later parent", status: .backlog))
        let child = try XCTUnwrap(store.commit([TaskDraft(title: "Child", dueDay: today, dueTimeMinutes: 60,
                                                         parentID: parent.id)])?.first)
        XCTAssertTrue(library.moveSubtask(child.id, toTask: nil).isApplied)
        XCTAssertEqual(child.status, .backlog); XCTAssertNil(child.parentID)
        XCTAssertNil(child.dueDay); XCTAssertNil(child.dueTimeMinutes)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let restored = try XCTUnwrap(store.task(withID: child.id))
        XCTAssertEqual(restored.parentID, parent.id); XCTAssertEqual(restored.status, .todo)
        XCTAssertEqual(restored.dueDay, today); XCTAssertEqual(restored.dueTimeMinutes, 60)
    }

    func testDateClearRemovesAnOrphanRawClockAndUndoRestoresExactImportedRawValues() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Imported"))
        let context = ModelContext(store.container)
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        imported.dueTimeMinutesRaw = 90 // simulate an inconsistent import, never a normal app write
        try context.save(); store.refresh()
        XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: task.id)), dueDay: .some(nil)))
        XCTAssertNil(try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>()).first?.dueTimeMinutesRaw)

        let next = ModelContext(store.container)
        let invalid = try XCTUnwrap(next.fetch(FetchDescriptor<TaskItem>()).first)
        invalid.dueDayRaw = "legacy-invalid-day"; invalid.dueTimeMinutesRaw = 90
        try next.save(); store.refresh()
        let library = AtticLibrary(tasks: store)
        XCTAssertTrue(library.updateTaskFields([task.id], dueDay: .some(nil)).isApplied)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let restored = try XCTUnwrap(store.task(withID: task.id))
        XCTAssertEqual(restored.dueDayRaw, "legacy-invalid-day")
        XCTAssertEqual(restored.dueTimeMinutesRaw, 90)
        XCTAssertNil(restored.dueTimeMinutes, "invalid imported dates never expose a usable clock")
    }

    func testWorkspaceSnapshotsIncludeAndRoundTripTheTimeField() throws {
        let task = TaskItem(title: "Clock")
        task.dueDay = today; task.dueTimeMinutes = 90
        let snapshot = try WorkspaceModelFields.read(task)
        XCTAssertNotNil(snapshot["dueTimeMinutesRaw"])
        let copy = TaskItem(title: "Copy")
        try WorkspaceModelFields.apply(snapshot, to: copy)
        XCTAssertEqual(copy.dueDay, today); XCTAssertEqual(copy.dueTimeMinutes, 90)
        XCTAssertEqual(try WorkspaceModelFields.fingerprint(task), try WorkspaceModelFields.fingerprint(copy))
    }

    func testAgendaKeepsEventAndNowChronologyDuringTheRepeatedAutumnHour() {
        let day = DueDay(year: 2026, month: 10, day: 25)!
        let utc = ISO8601DateFormatter()
        func event(_ id: String, _ instant: String) -> CalendarEvent {
            let start = utc.date(from: instant)!
            return CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                isAllDay: false, calendarTitle: "Test", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        }
        let first = event("first", "2026-10-25T00:45:00Z") // 01:45 BST
        let second = event("second", "2026-10-25T01:15:00Z") // 01:15 GMT
        let task = CalendarTaskEntry(id: UUID(), title: "First 01:30", due: day, isOpen: true, dueTimeMinutes: 90)
        let groups = CalendarAgenda.groups(selected: day,
            clock: .init(today: day, now: utc.date(from: "2026-10-25T01:00:00Z")!),
            events: [second, first], tasks: [task], calendar: calendar)
        XCTAssertEqual(groups[0].items.map(\.id), ["task-" + task.id.uuidString, "event-first", "now", "event-second"])
    }

    func testAgendaInterleavesTimedTasksAndEventsUsingFakeSource() throws {
        let store = try makeTestStore()
        let tasks = try XCTUnwrap(store.commit([
            TaskDraft(title: "Match untimed", dueDay: today),
            TaskDraft(title: "Match timed", dueDay: today, dueTimeMinutes: 630),
        ]))
        func event(_ id: String, hour: Int, allDay: Bool = false) -> CalendarEvent {
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: noon)!
            return CalendarEvent(id: id, title: "Match event", start: start,
                end: start.addingTimeInterval(allDay ? 86400 : 3600), isAllDay: allDay,
                calendarTitle: "Test", colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        }
        let source = CalendarEventSourceStub(events: [event("late", hour: 13), event("early", hour: 9), event("all", hour: 0, allDay: true)])
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.noon })
        let expected = ["event-all", "event-early", "task-" + tasks[1].id.uuidString, "now", "event-late", "task-" + tasks[0].id.uuidString]
        XCTAssertEqual(model.snapshot.groups.first?.items.map(\.id), expected)
        model.setQuery("Match"); model.commitSearch()
        XCTAssertEqual(model.snapshot.groups.first?.items.map(\.id), expected.filter { $0 != "now" })
    }
}
