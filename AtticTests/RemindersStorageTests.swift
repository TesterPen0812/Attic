import CoreData
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class RemindersStorageTests: XCTestCase {
    func testSchemaHasDefaultedFlagAndOptionalURL() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let entity = try XCTUnwrap(container.schema.entities.first { $0.name == "TaskItem" })
        let flag = try XCTUnwrap(entity.attributes.first { $0.name == "isFlagged" })
        XCTAssertEqual(flag.defaultValue as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(entity.attributes.first { $0.name == "url" }).isOptional)
    }

    func testAgentReadsSetsAndClearsBothInOneUndoStep() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let tools = AgentTaskTools(store: store, library: library)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        let json = try tools.call(name: "update_task", arguments: ["id": task.id.uuidString,
            "is_flagged": true, "url": "  HTTPS://EXAMPLE.COM/review?q=one  "])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let row = try XCTUnwrap(payload["task"] as? [String: Any])
        XCTAssertEqual(row["is_flagged"] as? Bool, true)
        XCTAssertEqual(row["url"] as? String, "https://example.com/review?q=one")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let listed = try tools.call(name: "list_tasks", arguments: [:])
        XCTAssertTrue(listed.contains("is_flagged"))
        XCTAssertFalse(listed.contains("example.com"))
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        let cleared = try tools.call(name: "update_task", arguments: ["id": task.id.uuidString, "is_flagged": false, "url": NSNull()])
        XCTAssertFalse(cleared.contains("example.com"))
        for name in ["create_task", "update_task"] {
            let def = try XCTUnwrap(tools.definitions.first { $0["name"] as? String == name })
            let props = (def["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            XCTAssertNotNil(props?["is_flagged"]); XCTAssertNotNil(props?["url"])
        }
    }

    private func rows(_ store: TaskStore) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
    }

    func testSettersAreSeparateUndoStepsAndNoOpsDoNotAddSteps() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        let count = library.undo.undoCount(in: .tasks)
        XCTAssertTrue(store.setFlag(true, for: task))
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, true)
        XCTAssertEqual(library.undo.undoCount(in: .tasks), count + 1)
        XCTAssertTrue(store.setURL(" HTTPS://EXAMPLE.COM/a%20b?q=x#part \n", for: task))
        XCTAssertEqual(store.task(withID: task.id)?.url, "https://example.com/a%20b?q=x#part")
        XCTAssertEqual(library.undo.undoCount(in: .tasks), count + 2)
        XCTAssertTrue(store.setFlag(true, for: task))
        XCTAssertEqual(library.undo.undoCount(in: .tasks), count + 2)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: task.id)?.url)
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, true)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, false)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(try rows(store).first?.url, "https://example.com/a%20b?q=x#part")
        XCTAssertTrue(store.setURL(" \n ", for: task))
        XCTAssertNil(store.task(withID: task.id)?.url)
    }

    func testURLValidationIsAtomicAndNeverAdmitsOtherSchemes() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let tools = AgentTaskTools(store: store, library: library)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        for invalid in ["file:///tmp/private", "javascript:alert(1)", "mailto:x@example.com", "example.com/a", "https:///missing", "https://", "https://exa mple.com"] {
            let before = library.undo.undoCount(in: .tasks)
            XCTAssertFalse(store.setURL(invalid, for: task), invalid)
            XCTAssertTrue(store.lastErrorMessage?.localizedCaseInsensitiveContains("http") == true)
            XCTAssertThrowsError(try tools.call(name: "update_task", arguments: ["id": task.id.uuidString,
                "title": "Must not save", "is_flagged": true, "url": invalid]))
            XCTAssertEqual(store.task(withID: task.id)?.title, "Reference")
            XCTAssertEqual(store.task(withID: task.id)?.isFlagged, false)
            XCTAssertEqual(library.undo.undoCount(in: .tasks), before)
        }
        for invalidFlag: Any in ["yes", 1, NSNull()] {
            XCTAssertThrowsError(try tools.call(name: "update_task", arguments: ["id": task.id.uuidString, "is_flagged": invalidFlag]))
        }
    }

    func testReplicasSubtasksQueriesAndUnrelatedFields() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container), id = UUID(), childID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        for title in ["Older", "Shown"] {
            let row = TaskItem(id: id, title: title, createdAt: date, updatedAt: title == "Shown" ? date.addingTimeInterval(1) : date)
            row.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(row)
        }
        let child = TaskItem(id: childID, title: "Child", createdAt: date, parentID: id)
        child.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(child)
        try context.save()
        let store = TaskStore(container: container), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertTrue(store.setFlag(true, for: task))
        XCTAssertTrue(store.setURL("https://example.com/replicas", for: task))
        XCTAssertTrue(store.setFlag(true, for: try XCTUnwrap(store.task(withID: childID))))
        XCTAssertEqual(Set(store.flaggedTasks().map(\.id)), [id, childID])
        XCTAssertEqual(store.flaggedTaskCount, 2, "logical live, unfinished tasks, including children")
        let copies = try rows(store).filter { $0.id == id }
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.allSatisfy { $0.isFlagged && $0.url == "https://example.com/replicas" })
        XCTAssertEqual(Set(copies.map(\.title)), ["Older", "Shown"])
        XCTAssertTrue(library.updateTask(childID, status: .done).isApplied)
        XCTAssertEqual(store.flaggedTaskCount, 1)
        XCTAssertTrue(store.delete(task))
        XCTAssertEqual(store.flaggedTaskCount, 0)
    }

    func testFailedSavesLeaveEveryReplicaAndHistoryUntouched() throws {
        let gate = PersistenceGate(), store = try makeTestStore(persist: gate.save)
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        let before = try WorkspaceModelFields.read(try XCTUnwrap(rows(store).first))
        let count = library.undo.undoCount(in: .tasks)
        gate.shouldFail = true
        XCTAssertFalse(store.setFlag(true, for: task))
        XCTAssertFalse(store.setURL("https://example.com/new", for: task))
        XCTAssertEqual(try WorkspaceModelFields.read(try XCTUnwrap(rows(store).first)), before)
        XCTAssertEqual(library.undo.undoCount(in: .tasks), count)
        gate.shouldFail = false
        XCTAssertTrue(store.setURL("https://example.com/new", for: try XCTUnwrap(store.task(withID: task.id))))
        gate.shouldFail = true
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.url, "https://example.com/new")
        gate.shouldFail = false
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: task.id)?.url)
    }

    func testDuplicateCopiesRootAndChildFieldsAndDeleteRestorePreservesThem() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let root = try XCTUnwrap(store.create(title: "Root"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: root.id))
        // Seed directly so Duplicate is tested independently of the setters.
        let context = ModelContext(store.container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) {
            row.isFlagged = true; row.url = "https://example.com/" + row.title
        }
        try context.save(); store.refresh()
        let copy = try XCTUnwrap(library.duplicateTasks([root.id])?.first)
        XCTAssertTrue(copy.isFlagged); XCTAssertEqual(copy.url, "https://example.com/Root")
        let copiedChild = try XCTUnwrap(store.subtasks(of: copy.id).first)
        XCTAssertTrue(copiedChild.isFlagged); XCTAssertEqual(copiedChild.url, "https://example.com/Child")
        XCTAssertNotEqual(copiedChild.id, child.id)
        XCTAssertTrue(library.deleteTasks([copy.id]).isApplied)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: copy.id)?.url, "https://example.com/Root")
        XCTAssertEqual(store.task(withID: copiedChild.id)?.isFlagged, true)
    }

    func testURLSearchMatchesHostPathChildrenAndDoneLog() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Root"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: task.id))
        XCTAssertTrue(store.setURL("https://example.com/design/path", for: child))
        let tools = AgentTaskTools(store: store, library: library)
        let json = try tools.call(name: "list_tasks", arguments: ["text": "design/path"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((payload["tasks"] as? [[String: Any]])?.first?["id"] as? String, child.id.uuidString)
        XCTAssertTrue(store.matchesItemSearch(task, query: "EXAMPLE.COM"))
        XCTAssertTrue(store.matchesItemSearch(task, query: "design/path"))
        XCTAssertTrue(store.completeFamily(taskID: task.id))
        XCTAssertEqual(store.moveCompletedToDoneLog(before: .distantFuture), 2)
        XCTAssertEqual(store.indexedDoneLogCount(matching: "design/path"), 1)
        _ = library
    }

    func testWorkspaceTokensAndCleanupNoticeOnlyFlagOrURLDivergence() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container), id = UUID(), date = Date(timeIntervalSince1970: 100)
        for _ in 0..<2 {
            let task = TaskItem(id: id, title: "Same", status: .done, createdAt: date, completedAt: date)
            task.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(task)
        }
        try context.save()
        let store = TaskStore(container: container)
        let before = try WorkspaceModelToken.read(.init(entity: .task, id: id), in: ModelContext(container))
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first)
        row.isFlagged = true; try context.save()
        let flagged = try WorkspaceModelToken.read(.init(entity: .task, id: id), in: ModelContext(container))
        XCTAssertNotEqual(flagged, before)
        store.refresh(); XCTAssertEqual(store.moveCompletedToDoneLog(before: .distantFuture), 0)
        row.isFlagged = false; row.url = "https://example.com/divergent"; try context.save()
        XCTAssertNotEqual(try WorkspaceModelToken.read(.init(entity: .task, id: id), in: ModelContext(container)), before)
        store.refresh(); XCTAssertEqual(store.moveCompletedToDoneLog(before: .distantFuture), 0)
    }

    func testMarkdownAndPrintSnapshotIncludeRootAndChildURLs() throws {
        let store = try makeTestStore()
        let root = try XCTUnwrap(store.create(title: "Root"))
        _ = try XCTUnwrap(store.create(title: "Child", parentID: root.id))
        let context = ModelContext(store.container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) { row.url = "https://example.com/" + row.title }
        try context.save(); store.refresh()
        let snapshot = try XCTUnwrap(TaskNotePageSnapshot.capture(taskID: root.id, in: ModelContext(store.container)))
        let page = snapshot.document(writing: NoteDocument(blocks: [.text(""), .text("Writing")]))
        let text = page.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("https://example.com/Root"))
        XCTAssertTrue(text.contains("https://example.com/Child"))
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let export = try XCTUnwrap(model.export([root.id]))
        XCTAssertTrue(export.markdown.contains("https://example.com/Root"))
        XCTAssertTrue(export.markdown.contains("https://example.com/Child"))
    }


    func testPreRemindersSQLiteStoreMigratesTwiceWithoutChangingExistingData() throws {
        let current = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: PersistenceController.appModelTypes))
        let old = try XCTUnwrap(current.copy() as? NSManagedObjectModel)
        let taskEntity = try XCTUnwrap(old.entitiesByName["TaskItem"])
        taskEntity.properties.removeAll { ["isFlagged", "url"].contains($0.name) }
        XCTAssertEqual(Set(current.entitiesByName["TaskItem"]!.attributesByName.keys).subtracting(taskEntity.attributesByName.keys), ["isFlagged", "url"])
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: current)
        let directory = ownedTemporaryDirectory(prefix: "RemindersLegacyMigration")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("default.store"), id = UUID(), noteID = UUID()
        let date = Date(timeIntervalSince1970: 123456), payload = Data([0, 1, 255, 42])
        var expected: [[String: NSObject]] = []
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
            let disk = try coordinator.addPersistentStore(type: .sqlite, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            for title in ["Replica A", "Replica B"] {
                let row = NSManagedObject(entity: taskEntity, insertInto: context)
                for attribute in taskEntity.attributesByName.values {
                    if let value = attribute.defaultValue { row.setValue(value, forKey: attribute.name) }
                }
                for (key, value) in ["id": id as NSUUID, "title": title as NSString,
                    "statusRaw": "inProgress" as NSString, "priorityRaw": "high" as NSString,
                    "createdAt": date as NSDate, "updatedAt": date as NSDate,
                    "tagsRaw": "kept" as NSString, "dueDayRaw": "2026-11-12" as NSString,
                    "manualOrder": NSNumber(value: 42), "listOrderVersion": NSNumber(value: 1),
                    "imageReferencesData": payload as NSData] {
                    row.setValue(value, forKey: key)
                }
                expected.append(row.dictionaryWithValues(forKeys: Array(taskEntity.attributesByName.keys)).compactMapValues { $0 as? NSObject })
            }
            let note = NSManagedObject(entity: try XCTUnwrap(old.entitiesByName["NoteItem"]), insertInto: context)
            for attribute in note.entity.attributesByName.values {
                if let value = attribute.defaultValue { note.setValue(value, forKey: attribute.name) }
            }
            note.setValue(noteID, forKey: "id"); note.setValue("Retained note", forKey: "title")
            note.setValue(payload, forKey: "contentStorage")
            note.setValue(date, forKey: "createdAt"); note.setValue(date, forKey: "updatedAt")
            try context.save()
            try coordinator.remove(disk)
        }
        // Both opens use the actual app schema, no custom/manual migration.
        for _ in 0..<2 {
            let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations: config)
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<TaskItem>()).sorted { $0.title < $1.title }
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { !$0.isFlagged && $0.url == nil })
            for row in rows {
                XCTAssertEqual(row.id, id); XCTAssertEqual(row.createdAt, date); XCTAssertEqual(row.updatedAt, date)
                XCTAssertEqual(row.status, .inProgress); XCTAssertEqual(row.priority, .high)
                XCTAssertEqual(row.tagsRaw, "kept"); XCTAssertEqual(row.dueDayRaw, "2026-11-12")
                XCTAssertEqual(row.manualOrder, 42); XCTAssertEqual(row.imageReferencesData, payload)
            }
            XCTAssertEqual(rows.map(\.title), ["Replica A", "Replica B"])
            let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
            XCTAssertEqual(note.id, noteID); XCTAssertEqual(note.content, payload); XCTAssertEqual(note.title, "Retained note")
            // Inspect every legacy stored attribute, including nils, with Core Data.
            let inspector = NSPersistentStoreCoordinator(managedObjectModel: current)
            let disk = try inspector.addPersistentStore(type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true])
            let raw = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); raw.persistentStoreCoordinator = inspector
            let request = NSFetchRequest<NSManagedObject>(entityName: "TaskItem")
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            for (row, original) in zip(try raw.fetch(request), expected) {
                let actual = row.dictionaryWithValues(forKeys: Array(taskEntity.attributesByName.keys)).compactMapValues { $0 as? NSObject }
                XCTAssertEqual(actual, original, "every pre-existing attribute stays exact")
            }
            try inspector.remove(disk)
        }
    }


    func testReplicaOnlyEditsAreUndoableAndRestoreEachReplicasOwnValues() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container), id = UUID(), date = Date(timeIntervalSince1970: 100)
        for index in 0..<2 {
            let row = TaskItem(id: id, title: "Replica \(index)", createdAt: date, updatedAt: date.addingTimeInterval(Double(index)))
            row.listOrderVersion = TaskItem.currentListOrderVersion
            row.isFlagged = index == 1; row.url = "https://example.com/\(index)"
            context.insert(row)
        }
        try context.save()
        let store = TaskStore(container: container), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.task(withID: id))
        let before = try Dictionary(uniqueKeysWithValues: rows(store).map { ($0.persistentModelID, ($0.isFlagged, $0.url)) })
        XCTAssertTrue(store.setFlag(true, for: task), "shown value is already true; older copy still changes")
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        for row in try rows(store) { XCTAssertEqual(row.isFlagged, before[row.persistentModelID]?.0) }
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertTrue(store.setURL("https://example.com/1", for: task))
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 2)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        for row in try rows(store) { XCTAssertEqual(row.url, before[row.persistentModelID]?.1) }
    }

    func testAgentCreateAndHeldWriteRefusalsSharePeopleHistory() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let tools = AgentTaskTools(store: store, library: library)
        let json = try tools.call(name: "create_task", arguments: ["title": "New", "is_flagged": true, "url": " HTTP://EXAMPLE.COM/create "])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((payload["task"] as? [String: Any])?["url"] as? String, "http://example.com/create")
        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertTrue(task.isFlagged)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        let lease = try XCTUnwrap(coordinator.ownership.tryAcquire([task.id], kind: .collection))
        let count = library.undo.undoCount(in: .tasks)
        XCTAssertFalse(store.setFlag(false, for: task))
        XCTAssertFalse(store.setURL(nil, for: task))
        XCTAssertThrowsError(try tools.call(name: "update_task", arguments: ["id": task.id.uuidString, "is_flagged": false, "url": NSNull()]))
        XCTAssertEqual(library.undo.undoCount(in: .tasks), count)
        XCTAssertEqual(store.task(withID: task.id)?.url, "http://example.com/create")
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, true)
        lease.release()
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: task.id))
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.url, "http://example.com/create")
    }


    func testLegacyDeletionCapturesAcceptOnlyTheNewFieldsDefaults() throws {
        for shouldRestore in [true, false] {
            let store = try makeTestStore()
            let task = try XCTUnwrap(store.create(title: "Legacy deletion"))
            XCTAssertTrue(store.delete(task))
            let context = ModelContext(store.container)
            for record in try context.fetch(FetchDescriptor<TaskDeletionPreservation>()) {
                let snapshot = try JSONDecoder().decode(WorkspacePurge.Preservation.self, from: record.snapshot)
                let members = snapshot.members.map { member in
                    WorkspacePurge.Preservation.Member(id: member.id,
                        fields: member.fields.filter { !["isFlagged", "url"].contains($0.key) },
                        replicas: member.replicas?.map { $0.filter { !["isFlagged", "url"].contains($0.key) } })
                }
                record.snapshot = try WorkspaceModelFields.encode(WorkspacePurge.Preservation(rootID: snapshot.rootID,
                    title: snapshot.title, members: members, originals: snapshot.originals, dependencies: snapshot.dependencies))
            }
            try context.save()
            let reopened = TaskStore(container: store.container)
            if shouldRestore {
                XCTAssertTrue(reopened.restoreDeleted(taskID: task.id))
                XCTAssertEqual(reopened.task(withID: task.id)?.isFlagged, false)
                XCTAssertNil(reopened.task(withID: task.id)?.url)
            } else {
                XCTAssertTrue(reopened.purgeDeleted(before: .distantFuture).contains(task.id))
            }
        }
        let row = TaskItem(title: "Default")
        let fields = try WorkspaceModelFields.read(row)
        let old = fields.filter { !["isFlagged", "url"].contains($0.key) }
        XCTAssertTrue(WorkspacePurge.matchesTaskCapture(fields, old))
        row.isFlagged = true
        XCTAssertFalse(WorkspacePurge.matchesTaskCapture(try WorkspaceModelFields.read(row), old))
        row.isFlagged = false; row.url = "https://example.com/new"
        XCTAssertFalse(WorkspacePurge.matchesTaskCapture(try WorkspaceModelFields.read(row), old))
    }


    func testRemoveDropsFieldsAddStartsFreshAndUndoRestoresExactReplicas() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let id = try TaskNotePreviewSeed.seed(.boundary, in: container)
        let seed = ModelContext(container)
        let family = try seed.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id || $0.parentID == id }
        for row in family { row.isFlagged = true; row.url = "https://example.com/" + row.id.uuidString }
        try seed.save()
        let tasks = TaskStore(container: container), library = AtticLibrary(tasks: tasks)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let noteStore = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let notes = NotesPageController(store: noteStore, journal: coordinator.journal, defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo); await notes.startAndWait()
        let noteID = try XCTUnwrap(noteStore.notes.first { $0.taskID == id }?.id)
        let session = try XCTUnwrap(notes.workspaceSession(noteID: noteID))
        let history = library.undo.workspace(for: .taskWorkspace(id))
        history.attach(session.engine.history)
        let before = try Dictionary(uniqueKeysWithValues: rows(tasks).map { ($0.persistentModelID, try WorkspaceModelFields.read($0)) })
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: noteID))
        let ordinary = try XCTUnwrap(noteStore.note(withID: noteID)?.content.flatMap { NoteContentCodec.decode($0).document })
        XCTAssertFalse(ordinary.blocks.contains { $0.text.contains("example.com") || $0.text.contains("Flagged") })
        XCTAssertNil(tasks.task(withID: id))
        notes.openTaskPage = { _ in true }
        let undo = await history.replay(redo: false); XCTAssertEqual(undo, .applied)
        for row in try rows(tasks) where before[row.persistentModelID] != nil {
            XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID])
        }
        let redo = await history.replay(redo: true); XCTAssertEqual(redo, .applied)
        XCTAssertTrue(notes.open(noteID: noteID))
        let added = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks, workspaceSession: notes.active)
        guard case let .made(freshID) = added else { return XCTFail("\(added)") }
        XCTAssertNotEqual(freshID, id)
        XCTAssertEqual(tasks.task(withID: freshID)?.isFlagged, false)
        XCTAssertNil(tasks.task(withID: freshID)?.url)
        // Clear retained history before normal expiry collection.
        history.clear(); library.undo.clear(.tasks)
        let purge = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(purge.removedTaskIDs.contains(id), "\(purge)")
        XCTAssertEqual(tasks.task(withID: freshID)?.isFlagged, false)
        XCTAssertNotNil(noteStore.note(withID: noteID))
        await noteStore.waitForAttachmentReconciliation()
    }


    func testNotesSearchIncludesTaskAndSubtaskURLHostAndPath() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let id = try TaskNotePreviewSeed.seed(.boundary, in: container)
        let seed = ModelContext(container)
        for row in try seed.fetch(FetchDescriptor<TaskItem>()) where row.id == id || row.parentID == id {
            row.url = row.id == id ? "https://reference.example/root-path" : "https://child.example/subtask-path"
        }
        try seed.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let noteID = try XCTUnwrap(store.notes.first { $0.taskID == id }?.id)
        for query in ["reference.example", "root-path", "child.example", "subtask-path"] {
            let found = try await store.searchNoteIDs(matching: query)
            XCTAssertTrue(found.contains(noteID), query)
        }
        await store.waitForAttachmentReconciliation()
    }


    func testFailedPhysicalSnapshotRefusesEntireListedBatchBeforeSaving() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let first = try XCTUnwrap(store.create(title: "First")), second = try XCTUnwrap(store.create(title: "Second"))
        let before = try Dictionary(uniqueKeysWithValues: rows(store).map { ($0.persistentModelID, try WorkspaceModelFields.read($0)) })
        store.reminderSnapshotReadsToSkipBeforeFailing = 1
        XCTAssertFalse(library.updateListedTasks([first.id, second.id], isFlagged: true, url: .some("https://example.com/batch")).isApplied)
        for row in try rows(store) { XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID]) }
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 0)
    }


    func testConfirmedEditKeepsUndoEvidenceWhenAnotherSnapshotReadWouldFail() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        store.reminderSnapshotReadsToSkipBeforeFailing = 1
        XCTAssertTrue(store.setURL("https://example.com/saved", for: task))
        XCTAssertEqual(store.task(withID: task.id)?.url, "https://example.com/saved")
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: task.id)?.url)
    }

    func testWholeItemDeleteRestoreAndPurgeKeepReminderFieldsWithTheirFamily() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let id = try TaskNotePreviewSeed.seed(.boundary, in: container)
        let seed = ModelContext(container)
        for row in try seed.fetch(FetchDescriptor<TaskItem>()) where row.id == id || row.parentID == id {
            row.isFlagged = true; row.url = "https://example.com/" + row.id.uuidString
        }
        try seed.save()
        let tasks = TaskStore(container: container)
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: store)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let notes = NotesPageController(store: store, journal: coordinator.journal, defaults: nil)
        notes.attachUndoRoute(library.undo); await notes.startAndWait()
        let before = try rows(tasks).filter { $0.id == id || $0.parentID == id }
        let expected = Dictionary(uniqueKeysWithValues: before.map { ($0.persistentModelID, $0.url) })
        let noteIDs = Set(store.notes.filter { $0.taskID == id }.map(\.id))
        XCTAssertTrue(library.deleteTasks([id]).isApplied)
        XCTAssertNil(tasks.task(withID: id))
        let deleted = try rows(tasks).filter { expected.keys.contains($0.persistentModelID) }
        XCTAssertEqual(deleted.count, expected.count)
        XCTAssertTrue(deleted.allSatisfy { $0.isFlagged && $0.deletedAt != nil && $0.url == expected[$0.persistentModelID]! })
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        for row in try rows(tasks) where expected.keys.contains(row.persistentModelID) {
            XCTAssertTrue(row.isFlagged); XCTAssertEqual(row.url, expected[row.persistentModelID]!)
        }
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        library.undo.clear(.tasks)
        let purge = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(purge.removedTaskIDs.contains(id), "\(purge)")
        XCTAssertTrue(try rows(tasks).allSatisfy { !expected.keys.contains($0.persistentModelID) })
        let remainingNotes = try ModelContext(container).fetch(FetchDescriptor<NoteItem>())
        XCTAssertTrue(remainingNotes.allSatisfy { !noteIDs.contains($0.id) })
        await store.waitForAttachmentReconciliation()
    }


    func testDuplicateIDsInListedEditAreOneUndoStep() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Reference"))
        XCTAssertTrue(library.updateListedTasks([task.id, task.id], isFlagged: true, url: .some("https://example.com/duplicate-id")).isApplied)
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, true)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.isFlagged, false)
        XCTAssertNil(store.task(withID: task.id)?.url)
    }

}
