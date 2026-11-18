import SwiftData
import XCTest
@testable import Attic

/// Red-first count guard for create's Undo ownership read (18 Nov 2026,
/// `reports/perf-audit/tasks-actions.astra.md` TA-03): a plain create must
/// read the same number of records for its Undo step in a larger library.
/// It prints a `GUARD_` line with its count.
@MainActor
final class UndoOwnershipCountGuardTests: XCTestCase {
    /// Astra TA-03. A plain create (no writing, tags or files) through the
    /// card's path reads the same number of records for its Undo step in a
    /// library ten times larger, with ten times the unrelated tasks and notes.
    func testGuardCreateReadsNoMoreRecordsInALargerLibrary() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size, notes: size / 2)
            let library = AtticLibrary(tasks: store)
            var services = TasksPageServices()
            services.acknowledgementDelay = .seconds(25)
            let model = TasksPageModel(library: library, services: services)
            _ = model.rows(for: .now)
            let draft = TaskDraft(title: "Plain new task")
            let before = library.ownershipRecordsRead
            var created: TaskItem?
            _ = model.createAcknowledged(draft, save: { library.createTask(draft, writing: "", in: .tasks, id: $0) },
                                         settled: { created = $0 })
            model.settlePendingCompletionAcknowledgements()
            XCTAssertNotNil(created, "the create saved")
            let read = library.ownershipRecordsRead - before
            print("GUARD_CREATE tasks=\(size) notes=\(size / 2) ownership_records_read=\(read)")
            bySize[size] = read
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "TA-03: a plain create's Undo ownership read grew with the library")
    }

    // MARK: - Rig

    /// Open tasks on Now, tasks in Later, finished tasks in the Done log
    /// (finished before today) and unrelated notes.
    private func makeStore(open: Int, later: Int = 0, logged: Int = 0, notes: Int = 0, tagged: Bool = false) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        func insert(_ title: String, _ status: TaskStatus, completed: Date? = nil, tags: [String] = []) {
            order -= 1_024
            let item = TaskItem(title: title, status: status, createdAt: now, completedAt: completed, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if let completed { item.doneLoggedAt = completed }
            if !tags.isEmpty { item.tags = tags }
            context.insert(item)
        }
        for index in 0..<open { insert("Open task \(index)", .todo, tags: tagged ? ["open\(index % 5)"] : []) }
        for index in 0..<later { insert("Later task \(index)", .backlog) }
        for index in 0..<logged {
            insert("Finished task \(index)", .done, completed: now.addingTimeInterval(-86_400 - Double(index + 1) * 3_600),
                   tags: tagged ? ["done\(index % 7)"] : [])
        }
        for index in 0..<notes { context.insert(NoteItem(title: "Note \(index)", body: "Unrelated note \(index)")) }
        try context.save()
        return TaskStore(container: container)
    }
}
