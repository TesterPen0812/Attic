import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guard for Opus F7 (`reports/perf-audit/tasks-actions.opus.md`,
/// lead's fix order item 3, reads that grow with the data): a store save
/// reaches the panel's revision observer, whose reconcile clears panel state
/// that names a task no longer live. It must read the same number of task
/// rows in a store ten times larger. The count is `reconciledTaskRowCount`:
/// one per ID asked, one per row read to build a set of live IDs, and one per
/// row of a store index the reconcile's own lookups built (taken inside the
/// observer, so the save's own index reads are not charged to it). Counts
/// work, never time; prints a `GUARD_` line. Only the observer reads the
/// store here (no Tasks page model, whose revision sink would build the
/// index first and hide a build the observer forces). It is hosted in a
/// borderless window that is never shown; a step lets the main queue drain
/// (an expectation, not a fixed wait), then lays out and draws.
@MainActor
final class PanelReconcileCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// The reconcile has work: an edit and a delete confirmation name live
    /// tasks. A plain save (a priority change) keeps both and must read the
    /// same rows at 100 and 1,000 tasks. A delete of the edited task clears
    /// it; that revision changes the visible list, so the store's index is
    /// built again once for the revision (as large as the list, as the save
    /// itself is), and the reconcile may build it at most once.
    /// (The bound allows one build plus the IDs asked; two builds exceed it.)
    func testGuardStoreSaveReadsNoMoreTaskRowsInThePanelReconcile() throws {
        var bySize: [Int: Int] = [:]
        for size in [100, 1_000] {
            let store = try makeStore(open: size)
            let uiState = PanelUIState()
            let hosting = host(PanelStoreRevisionObserver(store: store, uiState: uiState))
            XCTAssertEqual(store.tasks.count, size)
            let edited = store.tasks[0], confirming = store.tasks[1], changed = store.tasks[2]
            uiState.editingTaskID = edited.id
            uiState.confirmingTaskDeletionID = confirming.id
            settle(hosting)
            let before = uiState.reconciledTaskRowCount
            XCTAssertTrue(store.setPriority(.high, for: changed))
            settle(hosting)
            settle(hosting)
            let saveRows = uiState.reconciledTaskRowCount - before
            XCTAssertEqual(uiState.editingTaskID, edited.id, "a save keeps a live task's edit")
            XCTAssertEqual(uiState.confirmingTaskDeletionID, confirming.id)
            XCTAssertGreaterThanOrEqual(saveRows, 2, "the save reached the reconcile: it asks about both named IDs")

            let beforeDelete = uiState.reconciledTaskRowCount
            XCTAssertTrue(store.delete(edited))
            settle(hosting)
            settle(hosting)
            let deleteRows = uiState.reconciledTaskRowCount - beforeDelete
            XCTAssertNil(uiState.editingTaskID, "a deleted task's edit ends")
            XCTAssertEqual(uiState.confirmingTaskDeletionID, confirming.id)
            XCTAssertLessThan(deleteRows, 2 * store.tasks.count,
                              "a delete's reconcile builds the store's index at most once")
            print("GUARD_PANEL_OBSERVER tasks=\(size) save_rows_read=\(saveRows) delete_rows_read=\(deleteRows)")
            bySize[size] = saveRows
        }
        XCTAssertEqual(bySize[100], bySize[1_000], "F7: a save's panel reconcile read more task rows in a larger store")
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
