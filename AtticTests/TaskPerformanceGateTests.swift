import Darwin
import SwiftData
import XCTest
@testable import Attic

private struct PF5CountedID: Hashable {
    let value: Int
    nonisolated(unsafe) static var comparisons = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        comparisons += 1
        return lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) { hasher.combine(value / 2) }
}

/// Scaling costs compare three interleaved runs with the same-job reference
/// in macos-ci.yml. Functional invariants and paired memoization gates stay.
@MainActor
final class TaskPerformanceGateTests: XCTestCase {

    func testPF8TagTotalsDoNotEvictActiveDoneSearchBetweenPages() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        for index in 0..<120 {
            let task = TaskItem(title: index.isMultiple(of: 3) ? "alpha \(index)" : "other \(index)", status: .done)
            task.doneLoggedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            task.tags = [index.isMultiple(of: 2) ? "work" : "home"]
            seed.insert(task)
        }
        try seed.save()
        let store = TaskStore(container: container)
        let work = TagPicks(["work"])
        let home = TagPicks(["home"])
        #if DEBUG
        store.resetDoneSearchFullScanVisits()
        #endif

        let first = store.indexedDoneLogPage(limit: 5, matching: "alpha", tags: work)
        XCTAssertNil(first.failure)
        XCTAssertEqual(first.tasks.count, 5)
        XCTAssertEqual(store.indexedDoneLogCount(matching: "alpha", tags: work), 20)
        XCTAssertEqual(store.indexedDoneLogCount(tags: work), 60)
        let second = store.indexedDoneLogPage(from: first.next, limit: 5, matching: "alpha", tags: work)
        XCTAssertNil(second.failure)
        XCTAssertEqual(second.tasks.count, 5)
        XCTAssertTrue(Set(first.tasks.map(\.id)).isDisjoint(with: second.tasks.map(\.id)))
        #if DEBUG
        XCTAssertEqual(store.doneSearchFullScanVisits, 240,
            "One search and one tag-total scan; the next matching page must reuse the first scan")
        print("PF8_COUNTS first_page_count_second_page_visits=\(store.doneSearchFullScanVisits)")
        #endif

        // The no-tag total is already O(1), and must not evict a query.
        #if DEBUG
        store.resetDoneSearchFullScanVisits()
        #endif
        let noTagFirst = store.indexedDoneLogPage(limit: 5, matching: "alpha", tags: .none)
        XCTAssertEqual(store.indexedDoneLogCount(), 120)
        _ = store.indexedDoneLogPage(from: noTagFirst.next, limit: 5, matching: "alpha", tags: .none)
        #if DEBUG
        XCTAssertEqual(store.doneSearchFullScanVisits, 120)
        #endif

        // Tag changes change the cache key; a repeated count for that tag is free.
        #if DEBUG
        store.resetDoneSearchFullScanVisits()
        #endif
        XCTAssertEqual(store.indexedDoneLogCount(tags: home), 60)
        XCTAssertEqual(store.indexedDoneLogCount(tags: home), 60)
        #if DEBUG
        XCTAssertEqual(store.doneSearchFullScanVisits, 120)
        store.doneSearchLocaleOverrideForTesting = "perf-test-locale-1"
        XCTAssertEqual(store.indexedDoneLogCount(tags: home), 60)
        XCTAssertEqual(store.doneSearchFullScanVisits, 240, "Locale changes invalidate cached comparisons")
        store.doneSearchLocaleOverrideForTesting = nil
        #endif

        // A change imported from another context invalidates both entries.
        let external = ModelContext(container)
        let imported = TaskItem(title: "alpha new", status: .done)
        imported.doneLoggedAt = Date(timeIntervalSince1970: 1_700_001_000)
        imported.tags = ["work"]
        external.insert(imported)
        try external.save()
        store.refresh()
        #if DEBUG
        store.resetDoneSearchFullScanVisits()
        #endif
        XCTAssertEqual(store.indexedDoneLogCount(matching: "alpha", tags: work), 21)
        XCTAssertEqual(store.indexedDoneLogCount(tags: work), 61)
        #if DEBUG
        XCTAssertEqual(store.doneSearchFullScanVisits, 242,
            "A changed archived tag invalidates both search and total entries")
        #endif
    }

    func testPF5BulkDeleteFocusIsLinearAndKeepsSelectionBoundaries() {
        let ids = (0..<120).map { PF5CountedID(value: $0) }
        PF5CountedID.comparisons = 0
        let chosen = TaskDeletionFocus.next(visible: ids, deleting: ids.filter { $0.value.isMultiple(of: 2) || $0.value == 119 })
        XCTAssertEqual(chosen?.value, 117)
        XCTAssertLessThanOrEqual(PF5CountedID.comparisons, 120 * 8,
                                 "Deleting many selected rows must not perform nested linear searches")
        print("PF5_COUNTS comparisons=\(PF5CountedID.comparisons)")

        XCTAssertEqual(TaskDeletionFocus.next(visible: [0, 1, 2, 3], deleting: [1]), 2)
        XCTAssertEqual(TaskDeletionFocus.next(visible: [0, 1, 2], deleting: [0, 2]), 1)
        XCTAssertEqual(TaskDeletionFocus.next(visible: [0, 1, 2], deleting: [999]), 1)
        XCTAssertNil(TaskDeletionFocus.next(visible: [0, 1, 2], deleting: [0, 1, 2]))
        XCTAssertNil(TaskDeletionFocus.next(visible: [0], deleting: [0]))
    }


    func testR04BulkAcknowledgementsRollBackEveryReplicaAndPreserveOneUndoStep() async throws {
        struct Rejected: Error {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R04BulkAck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("tasks.store"), cloudKitDatabase: .none))
        let seed = ModelContext(container)
        let first = UUID(), second = UUID()
        seed.insert(TaskItem(id: first, title: "Older", updatedAt: .distantPast))
        seed.insert(TaskItem(id: first, title: "Shown", updatedAt: .now))
        seed.insert(TaskItem(id: second, title: "Second"))
        try seed.save()
        var fail = false
        var writes = 0
        let store = TaskStore(container: container, persist: { context in
            writes += 1
            if fail { throw Rejected() }
            try context.save()
        })
        let library = AtticLibrary(tasks: store)
        let page = TasksPageModel(library: library)
        _ = page.sections(for: .now)
        writes = 0

        fail = true
        var settled: CommandOutcome?
        page.setPriorityAcknowledged(.high, for: [first, second]) { settled = $0 }
        XCTAssertEqual(page.rows(for: .now).first { $0.id == first }?.model.priority, .high)
        XCTAssertEqual(page.rows(for: .now).first { $0.id == second }?.model.priority, .high)
        XCTAssertEqual(store.task(withID: first)?.priority, .some(.none))
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { next.resume() }
        }
        XCTAssertEqual(writes, 0, "Paint both rows before entering the writer")
        XCTAssertNil(settled)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(settled?.isApplied, false)
        XCTAssertEqual(page.rows(for: .now).first { $0.id == first }?.model.priority, .some(.none))
        XCTAssertEqual(page.rows(for: .now).first { $0.id == second }?.model.priority, .some(.none))
        let failedReplicas = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(failedReplicas.filter { $0.id == first }.count, 2)
        XCTAssertTrue(failedReplicas.allSatisfy { $0.priority == .none })
        XCTAssertFalse(library.undo.canUndo(in: .tasks), "A rejected transaction adds no Undo step")

        fail = false
        settled = nil
        page.setPriorityAcknowledged(.high, for: [first, second]) { settled = $0 }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(settled?.isApplied == true)
        let savedReplicas = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(savedReplicas.allSatisfy { $0.priority == .high }, "Every physical UUID replica is edited")
        XCTAssertTrue(page.undo().isApplied, "One Undo returns both logical rows to the original priority")
        let undone = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(undone.allSatisfy { $0.priority == .none })

        fail = true
        settled = nil
        page.deleteAcknowledged([first, second]) { settled = $0 }
        XCTAssertFalse(page.rows(for: .now).contains { $0.id == first || $0.id == second })
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(settled?.isApplied ?? true)
        XCTAssertTrue(page.rows(for: .now).contains { $0.id == first })
        XCTAssertTrue(page.rows(for: .now).contains { $0.id == second })
        let afterFailedDelete = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(afterFailedDelete.allSatisfy { $0.deletedAt == nil })
    }

    func testR04TitleDateTagAndComposerAcknowledgeWithFailedWrites() async throws {
        struct Rejected: Error {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R04DraftAck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("tasks.store"), cloudKitDatabase: .none))
        let seed = ModelContext(container)
        let original = TaskItem(title: "Existing")
        seed.insert(original)
        try seed.save()
        var fail = false
        let store = TaskStore(container: container, persist: { context in
            if fail { throw Rejected() }
            try context.save()
        })
        let page = TasksPageModel(library: AtticLibrary(tasks: store))
        let composer = ComposerModel(tasks: page)
        _ = page.sections(for: .now)
        fail = true

        page.beginEditingTitle(original.id)
        page.titleEdit = TaskAddBarText(text: "Renamed")
        var titleSettled: Bool?
        XCTAssertTrue(page.commitTitleAcknowledged { titleSettled = $0 })
        XCTAssertNil(page.editingTitleID)
        XCTAssertEqual(page.rows(for: .now).first { $0.id == original.id }?.model.title, "Renamed")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(titleSettled, false)
        XCTAssertEqual(page.editingTitleID, original.id)
        XCTAssertEqual(page.editingTitle, "Renamed")
        XCTAssertEqual(page.failedSave, .title(original.id))
        XCTAssertEqual(store.task(withID: original.id)?.title, "Existing")
        page.cancelEditing()

        let day = DueDay(date: Date(), calendar: .current)
        var fieldResult: CommandOutcome?
        page.setDueDayAcknowledged(day, for: [original.id]) { fieldResult = $0 }
        XCTAssertEqual(page.rows(for: .now).first { $0.id == original.id }?.due, day)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(fieldResult?.isApplied ?? true)
        XCTAssertNil(store.task(withID: original.id)?.dueDay)

        fieldResult = nil
        page.toggleTagAcknowledged("home", for: [original.id]) { fieldResult = $0 }
        XCTAssertEqual(page.rows(for: .now).first { $0.id == original.id }?.model.tags, ["home"])
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(fieldResult?.isApplied ?? true)
        XCTAssertEqual(store.task(withID: original.id)?.tags, [])

        composer.open(on: .tasks(.now))
        page.addBar = TaskAddBarText(text: "Create me #home")
        composer.submit()
        XCTAssertTrue(page.rows(for: .now).contains { $0.model.title == "Create me" })
        XCTAssertEqual(page.addBar.text, "")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(composer.isCreating)
        XCTAssertTrue(composer.failed)
        XCTAssertFalse(page.rows(for: .now).contains { $0.model.title == "Create me" })
        XCTAssertEqual(page.addBar.text, "Create me #home", "Failed creation returns the exact typed draft")
        XCTAssertEqual(store.tasks.filter { $0.title == "Create me" }.count, 0)

        fail = false
        composer.submit()
        XCTAssertEqual(page.addBar.text, "")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(composer.failed)
        XCTAssertEqual(store.tasks.filter { $0.title == "Create me" }.count, 1)
        XCTAssertTrue(page.undo().isApplied, "Creation stays a single undoable command")
        XCTAssertFalse(store.tasks.contains { $0.title == "Create me" })
    }

    func testR04TwoPendingTicksUndoInInputOrder() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let first = TaskItem(title: "First tick")
        let second = TaskItem(title: "Second tick")
        context.insert(first)
        context.insert(second)
        try context.save()
        let store = TaskStore(container: container)
        let page = TasksPageModel(library: AtticLibrary(tasks: store))
        var settled: [UUID] = []
        page.completeAcknowledged(first.id) { if $0.isApplied { settled.append(first.id) } }
        page.completeAcknowledged(second.id) { if $0.isApplied { settled.append(second.id) } }
        XCTAssertTrue(page.undo().isApplied)
        XCTAssertEqual(settled, [first.id, second.id])
        XCTAssertEqual(store.task(withID: first.id)?.status, .done)
        XCTAssertEqual(store.task(withID: second.id)?.status, .todo)
        XCTAssertNil(page.held[second.id])
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(settled.count, 2, "Queued writes must not run twice")
        XCTAssertTrue(page.redo().isApplied)
        XCTAssertEqual(store.task(withID: second.id)?.status, .done)
    }

    func testR04FollowingPriorityChangeKeepsUndoOrder() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let ticking = TaskItem(title: "First click")
        let priority = TaskItem(title: "Second click")
        context.insert(ticking)
        context.insert(priority)
        try context.save()
        let store = TaskStore(container: container)
        let page = TasksPageModel(library: AtticLibrary(tasks: store))
        var completed = 0
        page.completeAcknowledged(ticking.id) { if $0.isApplied { completed += 1 } }
        XCTAssertTrue(page.setPriority(.high, for: [priority.id]).isApplied)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .done)
        XCTAssertTrue(page.undo().isApplied)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .done, "Priority is newer than the pending tick")
        XCTAssertEqual(store.task(withID: priority.id)?.priority, TaskPriority.none)
        XCTAssertTrue(page.undo().isApplied)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .todo)
    }

    func testR04FailedPendingTickUndoCannotReachOlderEdit() async throws {
        struct Rejected: Error {}
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let old = TaskItem(title: "Earlier edit")
        let ticking = TaskItem(title: "Failed tick")
        context.insert(old)
        context.insert(ticking)
        try context.save()
        var fail = false
        let store = TaskStore(container: container, persist: { context in
            if fail { throw Rejected() }
            try context.save()
        })
        let library = AtticLibrary(tasks: store)
        let page = TasksPageModel(library: library)
        XCTAssertTrue(library.updateTask(old.id, priority: .high).isApplied)
        fail = true
        var result: CommandOutcome?
        page.completeAcknowledged(ticking.id) { result = $0 }
        XCTAssertTrue(page.undo().isApplied)
        XCTAssertFalse(result?.isApplied ?? true)
        XCTAssertEqual(store.task(withID: old.id)?.priority, .high)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .todo)
        XCTAssertNil(page.held[ticking.id])
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(store.task(withID: old.id)?.priority, .high)
    }

    func testR04ImmediateUndoReversesAcknowledgedTickBeforeAnEarlierEdit() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let previous = TaskItem(title: "Earlier edit")
        let ticking = TaskItem(title: "New tick")
        context.insert(previous)
        context.insert(ticking)
        try context.save()
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let page = TasksPageModel(library: library)
        XCTAssertTrue(library.updateTask(previous.id, priority: .high).isApplied)
        page.noteTextEdit() // The previous history step is already known to the draft.
        var completionCount = 0
        page.completeAcknowledged(ticking.id) { outcome in
            XCTAssertTrue(outcome.isApplied)
            completionCount += 1
        }
        XCTAssertTrue(page.taskChangeOwnsUndo, "The pending tick must win over draft Undo")
        XCTAssertTrue(page.undo().isApplied)
        XCTAssertEqual(store.task(withID: previous.id)?.priority, .high, "Undo must not touch an older edit")
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .todo)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(completionCount, 1, "The deferred save must not complete again after Undo")
        XCTAssertEqual(store.task(withID: previous.id)?.priority, .high)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .todo)
        XCTAssertTrue(page.redo().isApplied)
        XCTAssertEqual(store.task(withID: ticking.id)?.status, .done)
    }

    func testR04VisualTickPrecedesWriteAndFailedWriteRollsItBack() throws {
        struct Rejected: Error {}
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seeded = ModelContext(container)
        let parent = TaskItem(title: "Failure must untick")
        seeded.insert(parent)
        seeded.insert(TaskItem(title: "Child", parentID: parent.id))
        try seeded.save()
        var fail = true
        var observedTickInWriter = false
        var observedHoldInWriter = false
        var model: TasksPageModel?
        let store = TaskStore(container: container, persist: { context in
            if let model {
                observedHoldInWriter = model.held[parent.id] != nil
                observedTickInWriter = model.rows(for: .now).first { $0.id == parent.id }?.model.state == .done
            }
            if fail { throw Rejected() }
            try context.save()
        })
        var services = TasksPageServices()
        services.doneHold = .seconds(30)
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let page = try XCTUnwrap(model)
        _ = page.sections(for: .now)

        XCTAssertFalse(page.complete(parent.id).isApplied)
        XCTAssertTrue(observedHoldInWriter, "Start the hold before asking the store to write")
        XCTAssertTrue(observedTickInWriter, "Present a checked row before asking the store to write")
        XCTAssertNil(page.held[parent.id], "Failed write must cancel the visual hold")
        XCTAssertEqual(page.rows(for: .now).first { $0.id == parent.id }?.model.state, .todo)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo)
        XCTAssertEqual(store.subtasks(of: parent.id).first?.status, .todo)

        fail = false
        XCTAssertTrue(page.complete(parent.id).isApplied)
        XCTAssertNotNil(page.held[parent.id])
        XCTAssertEqual(page.rows(for: .now).first { $0.id == parent.id }?.model.state, .done)
        XCTAssertEqual(store.subtasks(of: parent.id).first?.status, .done)
    }

    func testR04AcknowledgementGetsAFrameBeforeAFailedFamilySave() async throws {
        struct Rejected: Error {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R04Fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("tasks.store"), cloudKitDatabase: .none))
        let seed = ModelContext(container)
        let parent = TaskItem(title: "Failure must restore tick")
        seed.insert(parent)
        seed.insert(TaskItem(title: "Child", parentID: parent.id))
        try seed.save()
        var fail = true
        var writerReached = false
        let store = TaskStore(container: container, persist: { context in
            writerReached = true
            if fail { throw Rejected() }
            try context.save()
        })
        var services = TasksPageServices()
        services.doneHold = .seconds(30)
        let page = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        _ = page.sections(for: .now)
        // TaskStore can persist its initial housekeeping during setup. Only
        // count writes caused by the completion input below.
        writerReached = false
        var settled: CommandOutcome?
        page.completeAcknowledged(parent.id) { settled = $0 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNotNil(page.held[parent.id])
        XCTAssertEqual(page.rows(for: .now).first { $0.id == parent.id }?.model.state, .done)
        XCTAssertFalse(writerReached, "The first frame opportunity precedes the store write")
        XCTAssertNil(settled)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertTrue(writerReached)
        XCTAssertFalse(settled?.isApplied ?? true)
        XCTAssertNil(page.held[parent.id])
        XCTAssertEqual(page.rows(for: .now).first { $0.id == parent.id }?.model.state, .todo)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo)
        XCTAssertEqual(store.subtasks(of: parent.id).first?.status, .todo)

        fail = false
        writerReached = false
        settled = nil
        page.completeAcknowledged(parent.id) { settled = $0 }
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertTrue(writerReached)
        XCTAssertTrue(settled?.isApplied == true)
        XCTAssertNotNil(page.held[parent.id])
        XCTAssertEqual(store.task(withID: parent.id)?.status, .done)
        XCTAssertEqual(store.subtasks(of: parent.id).first?.status, .done)
    }

    /// Hosted approximation of the first drawable frame: the next main-queue
    /// handoff after a row's completion input. No window or pointer needed.
    func testR04WriteDelayToFrameCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R04Frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("tasks.store"), cloudKitDatabase: .none))
        let seed = ModelContext(container)
        var ids: [UUID] = []
        for index in 0..<12 {
            let parent = TaskItem(title: "Ack \(index)")
            ids.append(parent.id)
            seed.insert(parent)
            seed.insert(TaskItem(title: "Child \(index)", parentID: parent.id))
        }
        try seed.save()
        var delayMS = 0
        let store = TaskStore(container: container, persist: { context in
            #if ATTIC_OPERATION_CRASH_TESTS
            if delayMS > 0 { Thread.sleep(forTimeInterval: Double(delayMS) / 1_000) }
            #endif
            try context.save()
        })
        var services = TasksPageServices()
        services.doneHold = .seconds(30)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        _ = model.sections(for: .now)
        var results: [Int: Double] = [:]
        for (index, delay) in [0, 20, 100].enumerated() {
            delayMS = delay
            var samples: [Double] = []
            for id in ids[(index * 3)..<(index * 3 + 3)] {
                let started = DispatchTime.now().uptimeNanoseconds
                var saved: CommandOutcome?
                model.completeAcknowledged(id) { saved = $0 }
                let frame = await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
                    DispatchQueue.main.async { continuation.resume(returning: DispatchTime.now().uptimeNanoseconds) }
                }
                XCTAssertNotNil(model.held[id])
                XCTAssertNil(saved, "No durable write at the first frame candidate")
                samples.append(Double(frame - started) / 1_000_000)
                try await Task.sleep(for: .milliseconds(220))
                XCTAssertTrue(saved?.isApplied == true)
            }
            results[delay] = samples.sorted()[1]
            print("ACK_R04 delay_ms=\(delay) frame_candidate_ms=\(samples) median_ms=\(samples.sorted()[1])")
        }
        let baseline = results[0]!
        for delay in [0, 20, 100] {
            let measured = results[delay]!
            let missedFrames = max(0, Int(((measured - baseline) / (1_000.0 / 60.0)).rounded(.down)))
            print("ACK_R04_SUMMARY delay_ms=\(delay) input_to_candidate_ms=\(measured) extra_frames_60hz=\(missedFrames)")
        }
    }

    /// Disk-backed command-to-next-main-queue measurements. Each path gets
    /// fresh targets and three samples at each injected save delay.
    func testR04RemainingPathsWriteDelayToFrameCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("R04Paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("tasks.store"), cloudKitDatabase: .none))
        let seed = ModelContext(container)
        let ids = (0..<180).map { index -> UUID in
            let task = TaskItem(title: "Ack path \(index)")
            seed.insert(task)
            return task.id
        }
        try seed.save()
        var delayMS = 0
        let store = TaskStore(container: container, persist: { context in
            #if ATTIC_OPERATION_CRASH_TESTS
            if delayMS > 0 { Thread.sleep(forTimeInterval: Double(delayMS) / 1_000) }
            #endif
            try context.save()
        })
        let library = AtticLibrary(tasks: store)
        let page = TasksPageModel(library: library)
        let composer = ComposerModel(tasks: page)
        _ = page.sections(for: .now)

        let paths = ["bulk-status", "bulk-priority", "bulk-delete", "title-edit", "date-edit", "tag-edit", "composer-create"]
        for (pathIndex, path) in paths.enumerated() {
            var results: [Int: Double] = [:]
            for (delayIndex, delay) in [0, 20, 100].enumerated() {
                delayMS = delay
                var samples: [Double] = []
                for sample in 0..<3 {
                    let offset = pathIndex * 24 + delayIndex * 6 + sample * 2
                    let a = ids[offset], b = ids[offset + 1]
                    if path == "title-edit" {
                        page.beginEditingTitle(a)
                        page.titleEdit = TaskAddBarText(text: "Edited \(offset)")
                    }
                    if path == "composer-create" {
                        composer.open(on: .tasks(.now))
                        page.addBar = TaskAddBarText(text: "New \(offset)")
                    }
                    let started = DispatchTime.now().uptimeNanoseconds
                    var settled: CommandOutcome?
                    switch path {
                    case "bulk-status": page.setStatusAcknowledged(.inProgress, for: [a, b]) { settled = $0 }
                    case "bulk-priority": page.setPriorityAcknowledged(.high, for: [a, b]) { settled = $0 }
                    case "bulk-delete": page.deleteAcknowledged([a, b]) { settled = $0 }
                    case "title-edit": XCTAssertTrue(page.commitTitleAcknowledged { settled = $0 ? .applied : .failed(.taskGone) })
                    case "date-edit": page.setDueDayAcknowledged(DueDay(date: Date(), calendar: .current), for: [a, b]) { settled = $0 }
                    case "tag-edit": page.toggleTagAcknowledged("ack", for: [a, b]) { settled = $0 }
                    case "composer-create": composer.submit()
                    default: XCTFail("Unexpected path")
                    }
                    let frame = await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
                        DispatchQueue.main.async { continuation.resume(returning: DispatchTime.now().uptimeNanoseconds) }
                    }
                    samples.append(Double(frame - started) / 1_000_000)
                    XCTAssertNil(settled, "The first frame candidate must precede persistence for \(path)")
                    if path == "composer-create" { XCTAssertTrue(composer.isCreating) }
                    for _ in 0..<60 {
                        if path == "composer-create" ? !composer.isCreating : settled != nil { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    if path == "composer-create" { XCTAssertFalse(composer.isCreating) }
                    else { XCTAssertEqual(settled?.isApplied, true, "Every \(path) edit reaches disk") }
                }
                let median = samples.sorted()[1]
                results[delay] = median
                print("ACK_R04_PATH path=\(path) delay_ms=\(delay) samples_ms=\(samples) median_ms=\(median)")
            }
            let base = results[0]!
            for delay in [0, 20, 100] {
                let measured = results[delay]!
                let missed = max(0, Int(((measured - base) / (1_000.0 / 60.0)).rounded(.down)))
                print("ACK_R04_PATH_SUMMARY path=\(path) delay_ms=\(delay) input_to_candidate_ms=\(measured) extra_frames_60hz=\(missed)")
            }
        }
    }

    /// R-04: time the complete command through the page model, including
    /// its synchronous durable family save *before* the visual hold starts.
    func testR04CompletionToVisualHoldOnRealisticStore() throws {
        let store = try seedStore(parents: 250, childrenPerParent: 2)
        var services = TasksPageServices()
        services.doneHold = .seconds(30)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let parents = Array(store.tasks.filter { $0.parentID == nil }.prefix(12))
        XCTAssertEqual(parents.count, 12)
        _ = model.sections(for: .now)
        var samples: [Double] = []
        for parent in parents {
            let start = ContinuousClock.now
            let outcome = model.complete(parent.id)
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            XCTAssertTrue(outcome.isApplied)
            XCTAssertNotNil(model.held[parent.id], "A successful save must enter visual hold")
            XCTAssertEqual(store.task(withID: parent.id)?.status, .done)
        }
        let ordered = samples.sorted()
        print("GAP_R04 total_tasks=750 samples_ms=\(samples) median_ms=\(ordered[ordered.count / 2]) max_ms=\(ordered.last!)")
    }

    private func seedStore(parents: Int, childrenPerParent: Int, attachmentsPerTask: Int = 0) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let references = (0..<attachmentsPerTask).map { index in
            TaskImageReference(id: UUID(), filename: "file-\(index).png", digest: String(repeating: "a", count: 64),
                               contentTypeIdentifier: "public.png", byteCount: 1_024)
        }
        let payload = attachmentsPerTask > 0 ? try JSONEncoder().encode(references) : nil
        for parentIndex in 0..<parents {
            let parent = TaskItem(title: "Parent \(parentIndex)", manualOrder: Int64(parentIndex))
            parent.imageReferencesData = payload
            context.insert(parent)
            for childIndex in 0..<childrenPerParent {
                let child = TaskItem(title: "Child \(childIndex)", manualOrder: Int64(childIndex), parentID: parent.id)
                context.insert(child)
            }
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func medianMilliseconds(iterations: Int = 9, metric: String? = nil, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            body()
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        if let metric { print("ATTIC_COST_SAMPLES metric=\(metric) raw_ms=\(samples)") }
        return samples.sorted()[iterations / 2]
    }

    /// The real Phase 2 TaskStore mutation entry points, with durable saves.
    func testMeasuredTaskCRUDSavePaths() throws {
        let store = try seedStore(parents: 200, childrenPerParent: 0)
        let task = try XCTUnwrap(store.tasks.first)
        var tick: [Double] = [], rename: [Double] = [], add: [Double] = [], reorder: [Double] = [], delete: [Double] = []
        func ms(_ action: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            action()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        for index in 0..<8 {
            tick.append(ms { XCTAssertTrue(store.setStatus(index % 2 == 0 ? .done : .todo, for: task)) })
            rename.append(ms { XCTAssertTrue(store.update(task, title: "Renamed \(index)")) })
            var added: TaskItem?
            add.append(ms { added = store.create(title: "Added \(index)") })
            let row = try XCTUnwrap(added)
            reorder.append(ms { XCTAssertTrue(store.move(taskID: row.id, toIndex: 1)) })
            delete.append(ms { XCTAssertTrue(store.delete(row)) })
        }
        for (name, samples) in [("TICK", tick), ("RENAME", rename), ("ADD", add), ("REORDER", reorder), ("DELETE", delete)] {
            print("TASK_\(name)_MS_MEDIAN=\(samples.sorted()[samples.count / 2]) MAX=\(samples.max()!)")
        }
    }

    /// The audit's family-summary shape: three children evaluations per
    /// parent across 1,000 parents / 6,000 tasks measured 357 ms with the
    /// scan-based lookup. The index answers each in O(1).
    func testFamilySummaryPassAtSixThousandTasksIsMilliseconds() throws {
        let store = try seedStore(parents: 1_000, childrenPerParent: 5)
        let parents = store.tasks.filter { $0.parentID == nil }
        XCTAssertEqual(parents.count, 1_000)
        var checksum = 0
        let median = medianMilliseconds(metric: "family-summary") {
            for parent in parents {
                guard store.hasSubtasks(parent.id) else { continue }
                checksum += store.subtasks(of: parent.id).reduce(0) { $0 + ($1.status == .done ? 1 : 0) }
                checksum += store.subtasks(of: parent.id).count
            }
        }
        XCTAssertEqual(checksum, 5_000 * 9)
        print("ATTIC_INTEGRATION_COST family-summary median_ms=\(median)")
        measure(metrics: [XCTClockMetric()]) {
            for parent in parents { _ = store.subtasks(of: parent.id).count }
        }
    }

    /// A mutation invalidates the index once; the rebuild is one linear pass
    /// and the sections snapshot stays memoized between mutations.
    func testStatusToggleAtSixThousandTasksStaysBounded() throws {
        let store = try seedStore(parents: 1_000, childrenPerParent: 5)
        let library = AtticLibrary(tasks: store)
        let children = store.tasks.filter { $0.parentID != nil }
        var index = 0
        var toggle = 0.0, snapshot = 0.0, lookup = 0.0
        #if ATTIC_OPERATION_CRASH_TESTS
        var phases: [String: Double] = [:]
        store.onSaveTiming = { phase, duration in
            let d = duration.components
            phases[phase, default: 0] += Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        #endif
        func ms(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let d = start.duration(to: .now).components
            return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        let median = medianMilliseconds(iterations: 7, metric: "status-toggle") {
            let child = children[index]
            index += 1
            toggle += ms { XCTAssertEqual(library.updateTask(child.id, status: .done), .applied) }
            snapshot += ms { _ = store.snapshot(for: .tasks) }
            lookup += ms { _ = store.subtasks(of: child.parentID!) }
        }
        print("PERFGATE toggle=\(toggle / 7) snapshot=\(snapshot / 7) lookup=\(lookup / 7)")
        #if ATTIC_OPERATION_CRASH_TESTS
        let writer = (phases["writer"] ?? 0) / 7
        let presentation = (phases["presentation"] ?? 0) / 7
        print("PERFGATE writer=\(writer) presentation=\(presentation)")
        #endif
        CostBudget.assertLessThan(median, 120, "a single toggle must not rescan or refetch the whole store (median \(median) ms)")
        print("ATTIC_INTEGRATION_COST status-toggle median_ms=\(median)")
    }

    /// A Now/Later tag edit must touch the edited root, not the 5,000
    /// unrelated Done entries or every indexed task. Exercise the real
    /// durable save 120 times on the Tasks scale fixture.
    func testScaleTagEditsOnlyVisitChangedSearchRoots() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        XCTAssertEqual(store.indexedDoneLogCount(), 5_000)
        let targets = Array(store.tasks.filter { $0.tags.contains("work") }.prefix(120))
        XCTAssertEqual(targets.count, 120)
        #if DEBUG
        store.resetSearchIndexVisitCounters()
        #endif
        var milliseconds: [Double] = []
        for task in targets {
            let start = ContinuousClock.now
            XCTAssertTrue(store.update(task, tags: ["home", "stress"]))
            let duration = start.duration(to: .now).components
            milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
            XCTAssertTrue(store.matchesItemSearch(task, query: "#stress"))
        }
        let sorted = milliseconds.sorted()
        let first = milliseconds.prefix(20).reduce(0, +) / 20
        let last = milliseconds.suffix(20).reduce(0, +) / 20
        print("PERF_TASKS_SCALE_EDIT n=\(milliseconds.count) median_ms=\(sorted[60]) p95_ms=\(sorted[114]) max_ms=\(sorted.last!) first20_mean_ms=\(first) last20_mean_ms=\(last)")
        #if DEBUG
        print("PERF_TASKS_SCALE_INDEX part_visits=\(store.itemSearchIndexPartVisits) done_membership_visits=\(store.doneSearchMembershipVisits)")
        XCTAssertLessThanOrEqual(store.itemSearchIndexPartVisits, targets.count * 3,
                                 "A single tag edit must not visit unrelated task search parts")
        XCTAssertLessThanOrEqual(store.doneSearchMembershipVisits, targets.count,
                                 "An open-task edit must not scan the Done search index")
        #endif
        XCTAssertEqual(store.indexedDoneLogCount(), 5_000)
    }

    /// The audit measured 12.8 ms per 300-row × 6-read pass with a fresh
    /// JSON decode on every read. Compare the memoized path against that same
    /// decode-heavy work on the current runner instead of using a sub-3 ms
    /// absolute wall-clock threshold, which is too sensitive to hosted load.
    func testRepeatedAttachmentReadsAreMemoizedPerPayload() throws {
        let store = try seedStore(parents: 300, childrenPerParent: 0, attachmentsPerTask: 4)
        let rows = store.tasks
        XCTAssertEqual(rows.count, 300)
        let originalPayload = try XCTUnwrap(rows.first?.imageReferencesData)
        let originalReferences = try JSONDecoder().decode([TaskImageReference].self, from: originalPayload)
        let alternateReferences = originalReferences.enumerated().map { index, reference in
            index == 0
                ? TaskImageReference(
                    id: reference.id,
                    filename: "alternate.png",
                    digest: reference.digest,
                    contentTypeIdentifier: reference.contentTypeIdentifier,
                    byteCount: reference.byteCount
                )
                : reference
        }
        let alternatePayload = try JSONEncoder().encode(alternateReferences)

        // Prime each payload once so the timed block measures the contract in
        // this test's name: repeated reads should reuse the memoized decode.
        for row in rows { _ = row.attachments.count }
        var total = 0
        let memoizedMedian = medianMilliseconds {
            for row in rows {
                for _ in 0..<6 { total += row.attachments.count }
            }
        }
        XCTAssertEqual(total % 1_200, 0)

        // Toggle the stored bytes before every read so the cache key changes
        // and each access must decode. The ratio is the invariant we care
        // about and remains meaningful across differently loaded CI runners.
        let decodingMedian = medianMilliseconds(iterations: 7) {
            for row in rows {
                for index in 0..<6 {
                    row.imageReferencesData = index.isMultiple(of: 2) ? alternatePayload : originalPayload
                    total += row.attachments.count
                }
            }
        }
        XCTAssertLessThan(
            memoizedMedian * 2,
            decodingMedian,
            "memoized repeat reads must remain at least twice as fast as forced decodes "
                + "(memoized \(memoizedMedian) ms, decoding \(decodingMedian) ms)"
        )
        measure(metrics: [XCTClockMetric()]) {
            for row in rows { _ = row.attachments.count }
        }
    }

    /// Writing a new payload invalidates the memo: the decoded list follows
    /// the stored bytes, never a stale copy.
    func testAttachmentMemoFollowsThePayload() throws {
        let task = TaskItem(title: "Memo")
        XCTAssertTrue(task.attachments.isEmpty)
        let one = TaskImageReference(id: UUID(), filename: "a.png", digest: "d", contentTypeIdentifier: "public.png", byteCount: 1)
        task.imageReferencesData = try JSONEncoder().encode([one])
        XCTAssertEqual(task.attachments.map(\.id), [one.id])
        let two = TaskImageReference(id: UUID(), filename: "b.png", digest: "e", contentTypeIdentifier: "public.png", byteCount: 2)
        task.imageReferencesData = try JSONEncoder().encode([one, two])
        XCTAssertEqual(task.attachments.map(\.id), [one.id, two.id])
        task.imageReferencesData = nil
        XCTAssertTrue(task.attachments.isEmpty)
    }
}

// The pinned integration reference predates these candidate-only PF fixtures.
// Its integration measurements above remain compiled and unchanged.
#if !ATTIC_COST_REFERENCE_HOST
// Each open uses the same clean loop baseline, so retained allocations raise
// later samples. Absolute peaks remain visible in the non-blocking diagnostic.
private final class PFFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: Double
    private var peak = 0.0
    private var readFailed = false
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    static func footprint() -> (megabytes: Double, succeeded: Bool) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (Double(info.phys_footprint) / 1_048_576, status == KERN_SUCCESS)
    }

    static func cleanBaseline() -> Double {
        malloc_zone_pressure_relief(nil, 0)
        let reading = footprint()
        XCTAssertTrue(reading.succeeded, "PF3 loop baseline sampling must succeed")
        return reading.megabytes
    }

    init(baseline: Double) {
        self.baseline = baseline
        malloc_zone_pressure_relief(nil, 0)
        sample()
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.resume()
    }

    private func sample() {
        let reading = Self.footprint()
        lock.lock(); defer { lock.unlock() }
        readFailed = readFailed || !reading.succeeded
        peak = max(peak, reading.megabytes)
    }

    func finish() -> (growth: Double, absolutePeak: Double) {
        timer.cancel()
        sample()
        lock.lock(); defer { lock.unlock() }
        XCTAssertFalse(readFailed, "PF3 footprint sampling must succeed")
        return (peak - baseline, peak)
    }
    deinit { timer.cancel() }
}

extension TaskPerformanceGateTests {
    func testOpenFootprintSamplerDetectsDirtyAllocationAndRelease() throws {
        let baseline = PFFootprintSampler.cleanBaseline()
        let sampler = PFFootprintSampler(baseline: baseline)
        let bytes = 32 * 1_048_576
        // malloc can reuse dirty pages retained by its large-allocation cache:
        // even pressure relief need not return them, so F0 already counts them.
        // A fresh VM mapping makes the positive control add new dirty pages.
        let allocation = try XCTUnwrap(mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        XCTAssertNotEqual(allocation, MAP_FAILED)
        guard allocation != MAP_FAILED else { return }
        memset(allocation, 0xA5, bytes)
        let held = sampler.finish()
        XCTAssertEqual(allocation.load(as: UInt8.self), 0xA5)
        XCTAssertEqual(munmap(allocation, bytes), 0)
        XCTAssertGreaterThanOrEqual(held.growth, 30)
        let released = PFFootprintSampler(baseline: baseline).finish()
        XCTAssertLessThan(released.growth, 30, "the next sample must not keep the freed 32 MiB allocation")
    }

    func testOpenFootprintSamplerDetectsAllocationRetainedAcrossSamples() throws {
        let baseline = PFFootprintSampler.cleanBaseline()
        let first = PFFootprintSampler(baseline: baseline)
        let bytes = 32 * 1_048_576
        let allocation = try XCTUnwrap(mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        XCTAssertNotEqual(allocation, MAP_FAILED)
        guard allocation != MAP_FAILED else { return }
        defer { XCTAssertEqual(munmap(allocation, bytes), 0) }
        memset(allocation, 0xA5, bytes)
        XCTAssertGreaterThanOrEqual(first.finish().growth, 30)
        let second = PFFootprintSampler(baseline: baseline).finish()
        XCTAssertGreaterThanOrEqual(second.growth, 30, "unchanged F0 must expose memory retained from the first window")
        XCTAssertEqual(allocation.load(as: UInt8.self), 0xA5)
    }
}

// Diagnostic observers are installed only by the paired probe. Both archives
// run the same callbacks; validation and the paired tolerance stay unchanged.
@MainActor
private final class PFSaveDiagnostic {
    private let container: ModelContainer
    private var observers: [NSObjectProtocol] = []
    private var saveStart: UInt64?
    private(set) var saveMilliseconds: Double = 0
    init(_ container: ModelContainer) {
        self.container = container
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? ModelContext)?.container === self.container else { return }
                self.saveStart = DispatchTime.now().uptimeNanoseconds
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? ModelContext)?.container === self.container, let start = self.saveStart else { return }
                self.saveMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                self.saveStart = nil
            }
        })
    }
    func reset() { saveStart = nil; saveMilliseconds = 0 }
    func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
}

// BEGIN PAIRED PHASE 2 PERF PROBE
// This probe also runs from an archive of d77ec80 on the SAME runner. The
// workflow copies this file into that archive; it never touches phase-2's
// worktree/branch. Limits use that run's observed sample spread, not guesses.
extension TaskPerformanceGateTests {
    private struct PFSamples: Codable {
        var values: [Double]
        var median: Double { values.sorted()[values.count / 2] }
        var maximum: Double { values.max()! }
        var minimum: Double { values.min()! }
        var spread: Double { maximum - minimum }
    }
    private func pfMilliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    private func seedPFOpenStore(root: URL, populated: Bool, headID: UUID, noteID: UUID,
                                 document: NoteDocument, revision: UUID, timestamp: Date) throws {
        try autoreleasepool {
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container)
            let head = TaskItem(id: headID, title: "Measured head", manualOrder: 0)
            seed.insert(head)
            // Keep the active task fixture identical in both size cases.
            for i in 1..<200 { seed.insert(TaskItem(title: "Task \(i)", manualOrder: Int64(i) * 1_024)) }
            let prepared = try PreparedNoteDocument(document)
            let note = NoteItem(id: noteID)
            note.content = prepared.content; note.contentFormat = 1
            note.title = prepared.title; note.body = prepared.body; note.plainText = prepared.plainText
            note.revisionID = revision
            seed.insert(note)
            if populated {
                let unrelated = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let other = NoteItem(title: "Unrelated \(i)", body: unrelated.body)
                    other.content = unrelated.content; other.contentFormat = 1
                    other.plainText = unrelated.plainText; other.revisionID = UUID()
                    seed.insert(other)
                    seed.insert(NoteVersion(noteID: other.id, createdAt: timestamp, reason: .leave,
                        content: unrelated.content, contentFormat: 1, title: other.title, body: other.body,
                        attachmentIDs: [], sourceRevisionID: other.revisionID))
                    seed.insert(NotePendingEdit(noteID: other.id, baseRevisionToken: other.revisionToken,
                        proposedContent: unrelated.content, agentName: "PF seed", createdAt: timestamp))
                    let bytes = Data(repeating: UInt8(i % 255), count: 128 * 1_024)
                    seed.insert(NoteAttachment(noteID: other.id, originalFilename: "seed-\(i).bin", byteCount: Int64(bytes.count),
                        sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes))
                }
            }
            try seed.save()
        }
    }

    /// OD-10: exactly one populated open in a new test-host process. The CI
    /// fallback collects seven independent processes per build/role, with the
    /// same fixture and sampler as the original open loop.
    func testPFPopulatedOpenGrowthFreshProcessSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPFFreshOpen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
        try seedPFOpenStore(root: root, populated: true, headID: UUID(), noteID: UUID(),
            document: document, revision: UUID(), timestamp: Date())
        let baseline = PFFootprintSampler.cleanBaseline()
        let sampler = PFFootprintSampler(baseline: baseline)
        let opened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let tasks = TaskStore(container: opened)
        let notes = NoteStore(container: opened, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes)
        XCTAssertEqual(tasks.tasks.count, 200)
        XCTAssertEqual(library.tasks.tasks.count, 200)
        await notes.waitForAttachmentReconciliation()
        let sample = sampler.finish()
        let record: [String: Double] = ["growth": sample.growth, "pid": Double(ProcessInfo.processInfo.processIdentifier),
            "baseline": baseline, "absolutePeak": sample.absolutePeak]
        print("PF_FRESH_OPEN_SAMPLE_JSON=" + String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
        fflush(stdout)
    }

    /// PF2 is measured THROUGH AtticLibrary, including its authoritative undo
    /// and before/after reads. PF3 compares the identical writes with 240
    /// unrelated notes, versions, proposals and attachments (over 60 MiB).
    func testPFFoundationSizeAndProductionPaths() async throws {
        var results: [String: PFSamples] = [:]
        let largeTasks = try seedStore(parents: 1_000, childrenPerParent: 5)
        let largeLibrary = AtticLibrary(tasks: largeTasks)
        let children = largeTasks.tasks.filter { $0.parentID != nil }
        results["SIX_THOUSAND_TOGGLE_MS"] = PFSamples(values: (0..<7).map { i in
            pfMilliseconds { XCTAssertEqual(largeLibrary.updateTask(children[i].id, status: .done), .applied) }.1
        })
        CostBudget.assertLessThanOrEqual(results["SIX_THOUSAND_TOGGLE_MS"]!.maximum, 120)
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let headID = UUID(), noteID = UUID(), revision = UUID(), timestamp = Date()
            let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            try seedPFOpenStore(root: root, populated: populated, headID: headID, noteID: noteID,
                document: document, revision: revision, timestamp: timestamp)
            let baseline = PFFootprintSampler.cleanBaseline()
            let label = populated ? "POPULATED" : "EMPTY"
            var opens: [Double] = [], footprints: [Double] = [], absolutePeaks: [Double] = []
            for _ in 0..<7 {
                let sampler = PFFootprintSampler(baseline: baseline)
                let ((tasks, notes, library), duration) = try pfMilliseconds {
                    let opened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                    let tasks = TaskStore(container: opened)
                    let notes = NoteStore(container: opened, attachmentFileStore: makeTestAttachmentFileStore())
                    return (tasks, notes, AtticLibrary(tasks: tasks, notes: notes))
                }
                opens.append(duration)
                XCTAssertEqual(tasks.tasks.count, 200)
                XCTAssertEqual(library.tasks.tasks.count, 200)
                await notes.waitForAttachmentReconciliation()
                let sample = sampler.finish()
                footprints.append(sample.growth)
                absolutePeaks.append(sample.absolutePeak)
            }
            results["\(label)_OPEN_MS"] = PFSamples(values: opens)
            results["\(label)_OPEN_GROWTH_MB"] = PFSamples(values: footprints)
            let diagnostic = ["\(label)_F0_MB": [baseline], "\(label)_ABSOLUTE_PEAK_MB": absolutePeaks]
            try FileHandle.standardOutput.write(contentsOf: Data(("PF_DIAG_OPEN_FOOTPRINT=" + String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self) + "\n").utf8))
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let tasks = TaskStore(container: container)
            let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
            let library = AtticLibrary(tasks: tasks, notes: notes)
            await notes.waitForAttachmentReconciliation()
            // Match autosave of an already-open note; both bases perform the
            // same capability preflight outside the timed commit.
            _ = try notes.noteMutationPreflight(noteID, format: .document)
            let source = AtticItemRef(.task, headID), target = AtticItemRef(.note, noteID)
            let link = try XCTUnwrap(library.links.link(source, to: target, kind: .reference))
            var toggles: [Double] = [], links: [Double] = [], saves: [Double] = []
            var baseRevision = revision
            for i in 0..<9 {
                toggles.append(pfMilliseconds {
                    XCTAssertEqual(library.updateTask(headID, status: i.isMultiple(of: 2) ? .done : .todo), .applied)
                }.1)
                links.append(pfMilliseconds {
                    XCTAssertTrue(i.isMultiple(of: 2) ? library.links.unlink(link.id) : library.links.restoreLink(link.id))
                }.1)
                var candidate = document
                candidate.blocks[0] = .text("Saved \(i)")
                let projection = try PreparedNoteDocument(candidate)
                let (result, duration) = pfMilliseconds {
                    notes.saveDocument(noteID: noteID, document: candidate, baseRevisionID: baseRevision, staged: [], prepared: projection)
                }
                guard case let .success(next) = result else { return XCTFail("PF autosave failed: \(result)") }
                baseRevision = next
                saves.append(duration)
            }
            results["\(label)_TOGGLE_MS"] = PFSamples(values: toggles)
            results["\(label)_LINK_MS"] = PFSamples(values: links)
            results["\(label)_SAVE_MS"] = PFSamples(values: saves)
            var coldToggles: [Double] = [], coldLinks: [Double] = [], coldSaves: [Double] = []
            for i in 0..<7 {
                let opened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let coldTasks = TaskStore(container: opened)
                let coldNotes = NoteStore(container: opened, attachmentFileStore: makeTestAttachmentFileStore())
                let coldLibrary = AtticLibrary(tasks: coldTasks, notes: coldNotes)
                await coldNotes.waitForAttachmentReconciliation()
                _ = try coldNotes.noteMutationPreflight(noteID, format: .document)
                coldToggles.append(pfMilliseconds {
                    XCTAssertEqual(coldLibrary.updateTask(headID, status: i.isMultiple(of: 2) ? .todo : .done), .applied)
                }.1)
                coldLinks.append(pfMilliseconds {
                    XCTAssertTrue(i.isMultiple(of: 2) ? coldLibrary.links.unlink(link.id) : coldLibrary.links.restoreLink(link.id))
                }.1)
                var candidate = document
                candidate.blocks[0] = .text("Cold saved \(i)")
                let projection = try PreparedNoteDocument(candidate)
                let (result, duration) = pfMilliseconds {
                    coldNotes.saveDocument(noteID: noteID, document: candidate, baseRevisionID: baseRevision, staged: [], prepared: projection)
                }
                guard case let .success(next) = result else { return XCTFail("PF cold autosave failed: \(result)") }
                baseRevision = next
                coldSaves.append(duration)
            }
            results["\(label)_COLD_TOGGLE_MS"] = PFSamples(values: coldToggles)
            results["\(label)_COLD_LINK_MS"] = PFSamples(values: coldLinks)
            results["\(label)_COLD_SAVE_MS"] = PFSamples(values: coldSaves)
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF_\(key)_MEDIAN=\(sample.median) MIN=\(sample.minimum) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(results), as: UTF8.self) + "\n").utf8))
        CostBudget.assertLessThanOrEqual(results["POPULATED_TOGGLE_MS"]!.maximum, 120)
    }
    /// The base archive runs this identical 200-iteration session in one
    /// process. Export matching quintiles and raw samples for the paired
    /// median and stall-rate gate; maxima remain diagnostic.
    func testPF5InterleavedSessionSoakAgainstPairedBase() async throws {
        var results: [String: PFSamples] = [:]
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF5-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container), head = TaskItem(title: "Measured head", manualOrder: 0)
            seed.insert(head)
            for i in 1..<200 { seed.insert(TaskItem(title: "Task \(i)", manualOrder: Int64(i) * 1_024)) }
            let small = NoteDocument(blocks: [.text("Small")])
            let big = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            let smallNote = NoteItem(), bigNote = NoteItem()
            for (row, document) in [(smallNote, small), (bigNote, big)] {
                let prepared = try PreparedNoteDocument(document)
                row.content = prepared.content; row.contentFormat = 1
                row.title = prepared.title; row.body = prepared.body; row.plainText = prepared.plainText; row.revisionID = UUID()
                seed.insert(row)
            }
            if populated {
                let prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let row = NoteItem(title: "Unrelated \(i)", body: prepared.body)
                    row.content = prepared.content; row.contentFormat = 1; row.plainText = prepared.plainText; row.revisionID = UUID()
                    seed.insert(row)
                    seed.insert(NoteVersion(noteID: row.id, createdAt: Date(), reason: .leave, content: prepared.content,
                        contentFormat: 1, title: row.title, body: row.body, attachmentIDs: [], sourceRevisionID: row.revisionID))
                    let bytes = Data(repeating: UInt8(i % 255), count: 128 * 1_024)
                    seed.insert(NoteAttachment(noteID: row.id, originalFilename: "seed-\(i).bin", byteCount: Int64(bytes.count),
                        sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes))
                }
            }
            try seed.save()
            let tasks = TaskStore(container: container), notes = NoteStore(container: container,
                attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            let library = AtticLibrary(tasks: tasks, notes: notes)
            await notes.waitForAttachmentReconciliation()
            _ = try notes.noteMutationPreflight(smallNote.id, format: .document)
            _ = try notes.noteMutationPreflight(bigNote.id, format: .document)
            let link = try XCTUnwrap(library.links.link(.init(.task, head.id), to: .init(.note, bigNote.id), kind: .reference))
            var samples: [String: [Double]] = [:]
            var diagnostics: [String: [(Date, Double)]] = [:]
            let saveDiagnostic = PFSaveDiagnostic(container)
            defer { saveDiagnostic.stop() }
            func measured(_ operation: String, _ body: () throws -> Void) rethrows -> Double {
                let timestamp = Date()
                saveDiagnostic.reset()
                let duration = try pfMilliseconds(body).1
                diagnostics[operation, default: []].append((timestamp, saveDiagnostic.saveMilliseconds))
                return duration
            }
            var smallRevision = smallNote.revisionID!, bigRevision = bigNote.revisionID!
            for i in 0..<200 {
                samples["TOGGLE", default: []].append(measured("TOGGLE") {
                    XCTAssertEqual(library.updateTask(head.id, status: i.isMultiple(of: 2) ? .done : .todo), .applied)
                })
                samples["RENAME", default: []].append(measured("RENAME") {
                    XCTAssertEqual(library.updateTask(head.id, title: "Renamed \(i)"), .applied)
                })
                samples["LINK_PAIR", default: []].append(measured("LINK_PAIR") {
                    XCTAssertTrue(library.links.unlink(link.id)); XCTAssertTrue(library.links.restoreLink(link.id))
                })
                var smallNext = small; smallNext.blocks[0] = .text("Small \(i)")
                let smallPrepared = try PreparedNoteDocument(smallNext)
                samples["SMALL_AUTOSAVE", default: []].append(try measured("SMALL_AUTOSAVE") {
                    smallRevision = try notes.saveDocument(noteID: smallNote.id, document: smallNext,
                        baseRevisionID: smallRevision, staged: [], prepared: smallPrepared).get()
                })
                var bigNext = big; bigNext.blocks[0] = .text("Big \(i)")
                let bigPrepared = try PreparedNoteDocument(bigNext)
                samples["BIG_AUTOSAVE", default: []].append(try measured("BIG_AUTOSAVE") {
                    bigRevision = try notes.saveDocument(noteID: bigNote.id, document: bigNext,
                        baseRevisionID: bigRevision, staged: [], prepared: bigPrepared).get()
                })
            }
            for (operation, values) in samples {
                XCTAssertEqual(values.count, 200)
                for q in 0..<5 {
                    let key = "\(populated ? "POPULATED" : "EMPTY")_\(operation)_Q\(q + 1)_MS"
                    let quintile = Array(values[q * 40..<(q + 1) * 40])
                    results[key] = PFSamples(values: quintile)
                    let index = q * 40 + quintile.firstIndex(of: quintile.max()!)!
                    let diagnostic = diagnostics[operation]![index]
                    print("PF5_MAX_DIAGNOSTIC key=\(key) iteration=\(index) utc=\(diagnostic.0.ISO8601Format()) utc_epoch_ms=\(Int64(diagnostic.0.timeIntervalSince1970 * 1_000)) total_ms=\(values[index]) save_ms=\(diagnostic.1)")
                }
            }
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF5_\(key)_MEDIAN=\(sample.median) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        // Export exact sufficient statistics in a short atomic log line;
        // raw quintile samples remain separately readable below PIPE_BUF.
        for key in results.keys.sorted() {
            print("PF5_SAMPLES_\(key)=" + results[key]!.values.map { String($0) }.joined(separator: ","))
        }
        let summary = results.mapValues { PFSamples(values: [$0.minimum, $0.median, $0.maximum]) }
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF5_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(summary), as: UTF8.self) + "\n").utf8))
    }

    /// Same-runner attribution for both Phase 2 PF1 production entry points.
    /// NotesPageControllerTests retain absolute constants outside this lane.
    func testPF1LargeAutosaveAndPreparedCommitAgainstPairedBase() async throws {
        var results: [String: PFSamples] = [:]
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF1-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container)
            if populated {
                let prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let note = NoteItem(title: "Unrelated \(i)", body: prepared.body)
                    note.content = prepared.content; note.contentFormat = 1; note.plainText = prepared.plainText; note.revisionID = UUID()
                    seed.insert(note)
                    seed.insert(NoteVersion(noteID: note.id, createdAt: Date(), reason: .leave, content: prepared.content,
                        contentFormat: 1, title: note.title, body: note.body, attachmentIDs: [], sourceRevisionID: note.revisionID))
                }
            }
            try seed.save()
            let store = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            await store.waitForAttachmentReconciliation()
            let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            let (id, _) = try store.createDocumentNote(id: UUID(), document: document).get()
            let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root.appendingPathComponent("Drafts")),
                saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
            await controller.startAndWait()
            let opened = await controller.openDurably(noteID: id)
            XCTAssertTrue(opened)
            let session = try XCTUnwrap(controller.active)
            var autosaves: [Double] = [], commits: [Double] = []
            for _ in 0..<8 {
                session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                    with: NSAttributedString(string: "x"), name: "Typing")
                autosaves.append(pfMilliseconds { XCTAssertTrue(controller.save(session)) }.1)
                session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                    with: NSAttributedString(string: "y"), name: "Typing")
                let snapshot = session.engine.document(), prepared = try PreparedNoteDocument(snapshot)
                commits.append(pfMilliseconds {
                    XCTAssertTrue(controller.save(session, snapshot: snapshot, stagedSnapshot: [], prepared: prepared))
                }.1)
            }
            await controller.waitForRecoveryWork()
            let label = populated ? "POPULATED" : "EMPTY"
            results["\(label)_AUTOSAVE_5000_MS"] = PFSamples(values: autosaves)
            results["\(label)_PREPARED_COMMIT_5000_MS"] = PFSamples(values: commits)
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF1_\(key)_MEDIAN=\(sample.median) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF1_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(results), as: UTF8.self) + "\n").utf8))
    }

}
// END PAIRED PHASE 2 PERF PROBE
#endif
