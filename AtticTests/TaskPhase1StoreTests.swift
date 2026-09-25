import SwiftData
import XCTest
@testable import Attic

/// Phase 1 store behaviour: one manual order per state group (priority no
/// longer sorts), the one-time order migration, replica-safe edits that
/// write only the edited fields, the Done log's pages and restoring to Now,
/// completing a family, and the selection bar's batch steps.
@MainActor
final class TaskPhase1StoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func rows(_ store: TaskStore, _ id: UUID) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    private func titles(_ store: TaskStore, _ status: TaskStatus) -> [String] {
        store.snapshot(for: status == .backlog ? .backlog : .tasks).sections
            .first { $0.status == status }?.tasks.map(\.title) ?? []
    }

    // MARK: - Ordering

    func testPriorityNoLongerSortsAndNewTasksGoOnTop() throws {
        let store = try makeTestStore()
        _ = try XCTUnwrap(store.create(title: "Low", priority: .low))
        _ = try XCTUnwrap(store.create(title: "High", priority: .high))
        _ = try XCTUnwrap(store.create(title: "None"))
        XCTAssertEqual(titles(store, .todo), ["None", "High", "Low"])
        XCTAssertTrue(store.tasks.allSatisfy { $0.manualOrder != nil && $0.listOrderVersion == 1 })
    }

    func testPriorityAndRenameDoNotMoveATask() throws {
        let store = try makeTestStore()
        let a = try XCTUnwrap(store.create(title: "A"))
        _ = try XCTUnwrap(store.create(title: "B"))
        _ = try XCTUnwrap(store.create(title: "C"))
        XCTAssertEqual(titles(store, .todo), ["C", "B", "A"])
        XCTAssertTrue(store.setPriority(.high, for: a))
        XCTAssertTrue(store.rename(a, to: "A renamed"))
        XCTAssertTrue(store.setTags(["home"], for: a))
        XCTAssertEqual(titles(store, .todo), ["C", "B", "A renamed"])
    }

    func testAStateChangePutsTheTaskOnTopOfItsNewGroup() throws {
        let store = try makeTestStore()
        let a = try XCTUnwrap(store.create(title: "A"))
        let b = try XCTUnwrap(store.create(title: "B"))
        XCTAssertTrue(store.setStatus(.inProgress, for: a))
        XCTAssertTrue(store.setStatus(.inProgress, for: b))
        XCTAssertEqual(titles(store, .inProgress), ["B", "A"])
        XCTAssertTrue(store.setStatus(.done, for: a))
        XCTAssertTrue(store.setStatus(.done, for: b))
        XCTAssertEqual(titles(store, .done), ["B", "A"], "the latest finished is on top of the done group")
    }

    func testMoveToAnIndexCrossesPriorities() throws {
        let store = try makeTestStore()
        let a = try XCTUnwrap(store.create(title: "A", priority: .high))
        _ = try XCTUnwrap(store.create(title: "B"))
        _ = try XCTUnwrap(store.create(title: "C", priority: .low))
        XCTAssertEqual(titles(store, .todo), ["C", "B", "A"])
        XCTAssertTrue(store.move(taskID: a.id, toIndex: 0))
        XCTAssertEqual(titles(store, .todo), ["A", "C", "B"])
        XCTAssertTrue(store.move(taskID: a.id, toIndex: 99), "clamped to the group")
        XCTAssertEqual(titles(store, .todo), ["C", "B", "A"])
        let c = try XCTUnwrap(store.tasks.first { $0.title == "C" })
        XCTAssertTrue(store.reorder(taskID: c.id, relativeTo: a.id))
        XCTAssertEqual(titles(store, .todo), ["B", "A", "C"])
    }

    func testMoveUndoesAsOneStep() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let a = try XCTUnwrap(store.create(title: "A"))
        _ = try XCTUnwrap(store.create(title: "B"))
        XCTAssertTrue(library.moveTask(a.id, toIndex: 0))
        XCTAssertEqual(titles(store, .todo), ["A", "B"])
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(titles(store, .todo), ["B", "A"])
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(titles(store, .todo), ["A", "B"])
    }

    // MARK: - Migration

    /// A store as Phase 0 left it: orders per (state, priority) group, rows
    /// without an order, a duplicate whose copies disagree, and rows in the
    /// Done log and in Recently Deleted. Opening it keeps every list's order,
    /// writes only the order and its version, and deletes nothing.
    func testLegacyOrderIsMigratedOnceKeepingWhatEachListShowed() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        func legacy(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none,
                    order: Int64?, updated: TimeInterval, id: UUID = UUID()) -> TaskItem {
            let item = TaskItem(id: id, title: title, status: status, priority: priority, createdAt: base,
                                updatedAt: base.addingTimeInterval(updated),
                                completedAt: status == .done ? base : nil, manualOrder: order)
            context.insert(item)
            return item
        }
        // Old order of To do: High (priority), then Medium group by order
        // (M2 above M1), then None with orders before None without (by time).
        _ = legacy("M1", .todo, .medium, order: 1_024, updated: 10)
        _ = legacy("N-unordered-new", .todo, .none, order: nil, updated: 50)
        _ = legacy("H", .todo, .high, order: 1_024, updated: 1)
        _ = legacy("M2", .todo, .medium, order: 2_048, updated: 5)
        _ = legacy("N-ordered", .todo, .none, order: 1_024, updated: 2)
        _ = legacy("N-unordered-old", .todo, .none, order: nil, updated: 20)
        // A duplicate whose copies disagree (title and priority): the shown
        // copy (newer) decides its place; both copies take the order.
        let duplicateID = UUID()
        let shownCopy = legacy("Dup shown", .todo, .low, order: 4_096, updated: 30, id: duplicateID)
        let hiddenCopy = legacy("Dup hidden", .todo, .high, order: 8, updated: 3, id: duplicateID)
        // Backlog, a subtask, the Done log and Recently Deleted.
        _ = legacy("B-low", .backlog, .low, order: 1_024, updated: 1)
        _ = legacy("B-high", .backlog, .high, order: 1_024, updated: 1)
        let logged = legacy("Logged", .done, .none, order: 77, updated: 1)
        logged.doneLoggedAt = base
        let deleted = legacy("Deleted", .todo, .high, order: 99, updated: 1)
        deleted.deletedAt = base
        deleted.deletionRootID = deleted.id
        deleted.deletionMembersRaw = deleted.id.uuidString
        let parentID = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first { $0.title == "H" }?.id)
        let child = TaskItem(title: "Child", createdAt: base, updatedAt: base, manualOrder: 5, parentID: parentID)
        context.insert(child)
        try context.save()
        let updatedBefore = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TaskItem>())
            .map { ($0.persistentModelID, $0.updatedAt) })
        let rowCount = try context.fetchCount(FetchDescriptor<TaskItem>())

        let store = TaskStore(container: container)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(titles(store, .todo),
                       ["H", "M2", "M1", "Dup shown", "N-ordered", "N-unordered-new", "N-unordered-old"])
        XCTAssertEqual(titles(store, .backlog), ["B-high", "B-low"])

        let after = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(after.count, rowCount, "nothing is deleted")
        XCTAssertTrue(after.allSatisfy { $0.listOrderVersion == TaskItem.currentListOrderVersion })
        XCTAssertTrue(after.allSatisfy { updatedBefore[$0.persistentModelID] == $0.updatedAt }, "no copy is restamped")
        let copies = after.filter { $0.id == duplicateID }
        XCTAssertEqual(Set(copies.map(\.title)), ["Dup shown", "Dup hidden"], "each copy keeps its own content")
        XCTAssertEqual(Set(copies.map(\.priorityRaw)), [TaskPriority.low.rawValue, TaskPriority.high.rawValue])
        XCTAssertEqual(Set(copies.map(\.manualOrder)).count, 1, "both copies take the shown copy's place")
        XCTAssertEqual(after.first { $0.title == "Logged" }?.manualOrder, 77, "rows outside the lists keep their order")
        XCTAssertEqual(after.first { $0.title == "Deleted" }?.manualOrder, 99)
        XCTAssertEqual(after.first { $0.title == "Child" }?.manualOrder, 5, "subtasks keep their order")
        _ = shownCopy; _ = hiddenCopy

        // A second open changes nothing.
        let orders = Dictionary(uniqueKeysWithValues: after.map { ($0.persistentModelID, $0.manualOrder) })
        let reopened = TaskStore(container: container)
        XCTAssertEqual(reopened.migrateListOrderIfNeeded(), 0)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            .allSatisfy { orders[$0.persistentModelID] == $0.manualOrder })
        XCTAssertEqual(titles(reopened, .todo).first, "H")
    }

    /// The real path: a store written by the Phase 0 model (no
    /// `listOrderVersion` column) is copied and opened through the app's own
    /// container code. Core Data adds the column in place (every row reads
    /// 0), the order migration runs once, every row survives, and the
    /// fixture itself is never opened by the app.
    /// The same migration on a store with files: a task holding attached
    /// files and one removed into Recently Deleted (with a duplicate copy
    /// that holds one more file). The order migration writes only the order
    /// fields, so every reference list and every file on disk survives, and
    /// the launch sweep of unreferenced files removes nothing.
    func testACopiedPhase0StoreWithFilesKeepsEveryAttachmentAndFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticPhase1MigrationFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesRoot = root.appendingPathComponent("task-files", isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let urls = ["plan.txt", "photo.txt", "old.txt", "extra.txt"].map { sources.appendingPathComponent($0) }
        for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
        let imported = try await TaskImageFiles(rootURL: filesRoot).importAttachments(urls, existing: [])
        XCTAssertEqual(imported.count, 4)
        let shownList = try TaskStore.encodedAttachments(Array(imported[0...1]))
        let duplicateList = try TaskStore.encodedAttachments(Array(imported[0...1]) + [imported[3]])
        let removedList = try TaskStore.encodedAttachments([RemovedTaskAttachment(reference: imported[2], removedAt: base)])

        let fixtureURL = root.appendingPathComponent("fixture/phase0.store")
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let withFiles = UUID()
        try autoreleasepool {
            let schema = Schema([Phase0Schema.TaskItem.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
                "fixture", schema: schema, url: fixtureURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            let shown = Phase0Schema.TaskItem(id: withFiles, title: "Read the plan", priority: .low, createdAt: base,
                                              updatedAt: base.addingTimeInterval(9), manualOrder: 5)
            shown.imageReferencesData = shownList
            shown.removedAttachmentsData = removedList
            let duplicate = Phase0Schema.TaskItem(id: withFiles, title: "Read the plan", priority: .low, createdAt: base,
                                                  updatedAt: base, manualOrder: 5)
            duplicate.imageReferencesData = duplicateList
            duplicate.removedAttachmentsData = removedList
            context.insert(shown)
            context.insert(duplicate)
            context.insert(Phase0Schema.TaskItem(title: "Urgent", priority: .high, createdAt: base, updatedAt: base, manualOrder: 1))
            try context.save()
        }
        let storeDirectory = root.appendingPathComponent("app-copy", isDirectory: true)
        let url = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: storeDirectory).url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: fixtureURL.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: url.path + suffix))
        }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: storeDirectory)
        let files = TaskImageFiles(rootURL: filesRoot)
        let store = TaskStore(container: container, taskImageFiles: files)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(titles(store, .todo), ["Urgent", "Read the plan"], "the old order (priority first) is kept")
        let copies = try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == withFiles }))
        XCTAssertEqual(Set(copies.map(\.imageReferencesData)), [shownList, duplicateList], "each copy keeps its own files")
        XCTAssertTrue(copies.allSatisfy { $0.removedAttachmentsData == removedList })
        XCTAssertEqual(store.task(withID: withFiles)?.attachments, Array(imported[0...1]))
        let swept = await store.sweepUnreferencedAttachmentStorage(minimumAge: 0)
        XCTAssertEqual(swept, 0, "every file is still referenced")
        for reference in imported {
            let exists = try await files.verifiedURL(for: reference)
            XCTAssertNotNil(exists, "\(reference.filename) is still on disk")
        }
    }

    func testACopiedPhase0StoreMigratesInPlaceKeepingOrderAndEveryRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticPhase1Migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = root.appendingPathComponent("fixture/phase0.store")
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let duplicateID = UUID(), parentID = UUID()
        try autoreleasepool {
            let schema = Schema([Phase0Schema.TaskItem.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
                "fixture", schema: schema, url: fixtureURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            func row(_ title: String, _ priority: TaskPriority, order: Int64?, updated: TimeInterval,
                     id: UUID = UUID(), status: TaskStatus = .todo, parent: UUID? = nil) {
                let item = Phase0Schema.TaskItem(id: id, title: title, status: status, priority: priority,
                                                 createdAt: base, updatedAt: base.addingTimeInterval(updated),
                                                 completedAt: status == .done ? base : nil,
                                                 manualOrder: order, parentID: parent)
                context.insert(item)
            }
            row("Low", .low, order: 9_000, updated: 1)
            row("High", .high, order: 1_024, updated: 1, id: parentID)
            row("Sub", .none, order: nil, updated: 1, parent: parentID)
            row("Dup new", .medium, order: 2_048, updated: 9, id: duplicateID)
            row("Dup old", .none, order: 2_048, updated: 1, id: duplicateID)
            row("Medium", .medium, order: 1_024, updated: 3)
            row("Done", .none, order: nil, updated: 2, status: .done)
            try context.save()
        }

        let storeDirectory = root.appendingPathComponent("app-copy", isDirectory: true)
        let url = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: storeDirectory).url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: fixtureURL.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: url.path + suffix))
        }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: storeDirectory)
        let before = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(before.count, 7)
        XCTAssertTrue(before.allSatisfy { $0.listOrderVersion == 0 }, "the new column reads its default")

        let store = TaskStore(container: container)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(titles(store, .todo), ["High", "Dup new", "Medium", "Low"])
        XCTAssertEqual(titles(store, .done), ["Done"])
        XCTAssertEqual(store.subtasks(of: parentID).map(\.title), ["Sub"])
        let after = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(after.count, 7, "nothing is deleted")
        XCTAssertEqual(Set(after.filter { $0.id == duplicateID }.map(\.title)), ["Dup new", "Dup old"])
        XCTAssertTrue(after.allSatisfy { $0.listOrderVersion == 1 })

        // Reopened (a relaunch): the same order, nothing left to migrate.
        let reopened = TaskStore(container: try PersistenceController.makeContainer(
            cloudSyncEnabled: false, storeDirectory: storeDirectory))
        XCTAssertEqual(titles(reopened, .todo), ["High", "Dup new", "Medium", "Low"])
        XCTAssertEqual(reopened.migrateListOrderIfNeeded(), 0)
    }

    func testAFailedMigrationChangesNothingAndIsRetried() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(TaskItem(title: "Low", priority: .low, createdAt: base, updatedAt: base, manualOrder: 1_024))
        context.insert(TaskItem(title: "High", priority: .high, createdAt: base, updatedAt: base, manualOrder: 1_024))
        try context.save()
        let gate = PersistenceGate()
        gate.shouldFail = true
        let failing = TaskStore(container: container, persist: gate.save)
        XCTAssertNotNil(failing.lastErrorMessage, "the failure is shown")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.listOrderVersion == 0 })
        let store = TaskStore(container: container)
        XCTAssertEqual(titles(store, .todo), ["High", "Low"])
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.listOrderVersion == 1 })
    }

    // MARK: - Replica-safe edits (deferred replica safety, Phase 1)

    /// Two copies of one task that disagree: a priority-only edit writes the
    /// priority on both and leaves each copy's title (and everything else it
    /// holds) alone; only the shown copy takes the new time.
    func testPriorityOnlyEditKeepsADivergentHiddenTitle() throws {
        let clock = MutableNow(base)
        let store = try makeTestStore(now: { clock.value })
        let id = UUID()
        let context = ModelContext(store.container)
        let shown = TaskItem(id: id, title: "Shown title", createdAt: base, updatedAt: base.addingTimeInterval(60), manualOrder: 1_024)
        let hidden = TaskItem(id: id, title: "Hidden title", createdAt: base, updatedAt: base, manualOrder: 2_048)
        hidden.tagsRaw = "elsewhere"
        hidden.dueDayRaw = "2026-12-01"
        context.insert(shown)
        context.insert(hidden)
        try context.save()
        store.refresh()
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Shown title")

        clock.value = base.addingTimeInterval(600)
        XCTAssertTrue(store.setPriority(.high, for: task))
        let copies = try rows(store, id)
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.allSatisfy { $0.priority == .high })
        let hiddenAfter = try XCTUnwrap(copies.first { $0.title == "Hidden title" })
        let shownAfter = try XCTUnwrap(copies.first { $0.title == "Shown title" })
        XCTAssertEqual(hiddenAfter.tagsRaw, "elsewhere")
        XCTAssertEqual(hiddenAfter.dueDayRaw, "2026-12-01")
        XCTAssertEqual(hiddenAfter.manualOrder, 2_048)
        XCTAssertEqual(hiddenAfter.updatedAt, base, "the divergent copy keeps its time")
        XCTAssertEqual(shownAfter.updatedAt, clock.value)
        XCTAssertEqual(store.task(withID: id)?.title, "Shown title")
    }

    func testAnEditNeitherRestoresNorOverwritesACopyDeletedElsewhere() throws {
        let store = try makeTestStore()
        let id = UUID()
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: id, title: "Task", createdAt: base, updatedAt: base.addingTimeInterval(60), manualOrder: 1_024))
        let gone = TaskItem(id: id, title: "Task", createdAt: base, updatedAt: base, manualOrder: 1_024)
        gone.deletedAt = base
        gone.deletionRootID = id
        gone.deletionMembersRaw = id.uuidString
        context.insert(gone)
        try context.save()
        store.refresh()
        XCTAssertTrue(store.rename(try XCTUnwrap(store.task(withID: id)), to: "Renamed"))
        let copies = try rows(store, id)
        XCTAssertTrue(copies.allSatisfy { $0.title == "Renamed" }, "the edited field reaches every copy")
        XCTAssertEqual(copies.filter { $0.deletedAt != nil }.count, 1, "the other copy's deletion is its own")
        XCTAssertEqual(store.task(withID: id)?.title, "Renamed")
    }

    func testAStateEditWritesOnlyTheStateFields() throws {
        let store = try makeTestStore()
        let id = UUID()
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: id, title: "Shown", priority: .low, createdAt: base,
                                updatedAt: base.addingTimeInterval(60), manualOrder: 1_024))
        context.insert(TaskItem(id: id, title: "Hidden", priority: .high, createdAt: base.addingTimeInterval(-5),
                                updatedAt: base, manualOrder: 1_024))
        try context.save()
        store.refresh()
        XCTAssertTrue(store.setStatus(.done, for: try XCTUnwrap(store.task(withID: id))))
        let copies = try rows(store, id)
        XCTAssertTrue(copies.allSatisfy { $0.status == .done && $0.completedAt != nil })
        let hidden = try XCTUnwrap(copies.first { $0.title == "Hidden" })
        XCTAssertEqual(hidden.priority, .high)
        XCTAssertEqual(hidden.createdAt, base.addingTimeInterval(-5))
    }

    // MARK: - Completing, restoring and batches

    func testCompletingAMainTaskCompletesItsOpenSubtasksAsOneStep() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let open = try XCTUnwrap(store.create(title: "Book", parentID: parent.id))
        let done = try XCTUnwrap(store.create(title: "Pack", parentID: parent.id))
        XCTAssertTrue(store.setStatus(.done, for: done))
        XCTAssertTrue(library.completeTask(parent.id))
        XCTAssertEqual(store.task(withID: parent.id)?.status, .done)
        XCTAssertEqual(store.task(withID: open.id)?.status, .done)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo)
        XCTAssertEqual(store.task(withID: open.id)?.status, .todo)
        XCTAssertEqual(store.task(withID: done.id)?.status, .done, "a subtask done before keeps its state")
    }

    func testDoneLogPagesSearchAndRestoreToNow() throws {
        let clock = MutableNow(base)
        let store = try makeTestStore(now: { clock.value })
        let library = AtticLibrary(tasks: store)
        var created: [TaskItem] = []
        for index in 0..<5 {
            clock.value = base.addingTimeInterval(TimeInterval(index))
            let task = try XCTUnwrap(store.create(title: "Finished \(index)"))
            if index == 4 {
                let child = try XCTUnwrap(store.create(title: "Step", parentID: task.id))
                XCTAssertTrue(store.setStatus(.done, for: child))
            }
            XCTAssertTrue(store.setStatus(.done, for: task))
            created.append(task)
        }
        clock.value = base.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: base.addingTimeInterval(2 * 86_400)), 6)
        XCTAssertEqual(store.doneLogCount(), 5)

        let first = store.doneLogPage(limit: 2)
        XCTAssertEqual(first.tasks.map(\.title), ["Finished 4", "Finished 3"])
        XCTAssertTrue(first.hasMore)
        let second = store.doneLogPage(from: first.next, limit: 2)
        let last = store.doneLogPage(from: second.next, limit: 2)
        XCTAssertEqual(last.tasks.map(\.title), ["Finished 0"])
        XCTAssertFalse(last.hasMore)
        XCTAssertEqual(store.doneLogPage(limit: 10, matching: "ished 2").tasks.map(\.title), ["Finished 2"])
        XCTAssertEqual(store.doneLogSubtasks(of: created[4].id).map(\.title), ["Step"])

        let loggedAt = try XCTUnwrap(store.listedTask(withID: created[4].id)?.doneLoggedAt)
        _ = try XCTUnwrap(store.create(title: "Today"))
        XCTAssertTrue(library.restoreToNow(created[4].id))
        XCTAssertEqual(titles(store, .todo), ["Finished 4", "Today"], "back on top of To do")
        XCTAssertEqual(store.subtasks(of: created[4].id).map(\.title), ["Step"], "its subtasks come back with it")
        XCTAssertEqual(store.doneLogCount(), 4)

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNil(store.task(withID: created[4].id), "undo puts it back in the Done log")
        XCTAssertEqual(store.listedTask(withID: created[4].id)?.doneLoggedAt, loggedAt)
        XCTAssertEqual(store.doneLogCount(), 5)
    }

    func testRestoringATaskStillInTodaysDoneGroupReopensIt() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Done today"))
        XCTAssertTrue(store.setStatus(.done, for: task))
        XCTAssertTrue(library.restoreToNow(task.id))
        XCTAssertEqual(store.task(withID: task.id)?.status, .todo)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(store.task(withID: task.id)?.status, .done)
    }

    func testBatchEditsAndDeletesAreOneStepEach() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let a = try XCTUnwrap(store.create(title: "A"))
        let b = try XCTUnwrap(store.create(title: "B"))
        XCTAssertTrue(library.updateTasks([a.id, b.id], priority: .high))
        XCTAssertTrue(library.updateTasks([a.id, b.id], addingTag: "launch"))
        XCTAssertTrue(library.updateTasks([a.id, b.id], status: .backlog))
        XCTAssertTrue(store.tasks.allSatisfy { $0.priority == .high && $0.tags == ["launch"] && $0.status == .backlog })
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertTrue(store.tasks.allSatisfy { $0.status == .todo && $0.tags == ["launch"] })
        XCTAssertTrue(library.deleteTasks([a.id, b.id]))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(Set(store.tasks.map(\.id)), [a.id, b.id])
    }
}
