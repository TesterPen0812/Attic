import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guard for Opus F7 (`reports/perf-audit/tasks-actions.opus.md`,
/// lead's fix order item 3, reads that grow with the data): a store save
/// reaches the panel's revision observer, whose reconcile clears panel state
/// that names a task no longer live. It must examine the same number of task
/// IDs in a store ten times larger. Counts work, never time; prints a
/// `GUARD_` line. The observer is hosted in a borderless window that is never
/// shown; a step lets the main queue drain (an expectation, not a fixed wait),
/// then lays out and draws.
@MainActor
final class PanelReconcileCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// The reconcile has work: an edit and a delete confirmation name live
    /// tasks. A save keeps both; a delete of the edited task clears it.
    func testGuardStoreSaveHandsNoMoreTaskIDsToThePanelObserver() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let uiState = PanelUIState()
            let hosting = host(PanelStoreRevisionObserver(store: store, uiState: uiState))
            let rows = model.rows(for: .now).map(\.id)
            let edited = try XCTUnwrap(rows.first), confirming = rows[1], changed = rows[2]
            uiState.editingTaskID = edited
            uiState.confirmingTaskDeletionID = confirming
            settle(hosting)
            let before = uiState.reconciledTaskIDCount
            XCTAssertTrue(model.setPriority(.high, for: [changed]).isApplied)
            settle(hosting)
            settle(hosting)
            let handed = uiState.reconciledTaskIDCount - before
            XCTAssertEqual(uiState.editingTaskID, edited, "a save keeps a live task's edit")
            XCTAssertEqual(uiState.confirmingTaskDeletionID, confirming)
            XCTAssertTrue(model.delete([edited]).isApplied)
            settle(hosting)
            settle(hosting)
            XCTAssertNil(uiState.editingTaskID, "a deleted task's edit ends")
            XCTAssertEqual(uiState.confirmingTaskDeletionID, confirming)
            print("GUARD_PANEL_OBSERVER tasks=\(size) task_ids_handed=\(handed)")
            bySize[size] = handed
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "F7: a save's task-ID reconcile grew with the store")
    }

    // MARK: - Rig

    private static let size = CGSize(width: 344, height: 520)

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

    private func host<Content: View>(_ content: Content) -> NSView {
        let hosting = NSHostingView(rootView: content.frame(width: Self.size.width, height: Self.size.height).atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window?.close()
        self.window = window
        settle(hosting)
        return hosting
    }

    /// One update: the main queue drains, then the view lays out and draws.
    private func settle(_ hosting: NSView) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }
}
