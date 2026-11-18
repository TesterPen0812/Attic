import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guards for Done's loaded set (18 Nov 2026,
/// `reports/perf-audit/tasks-actions.opus.md` F4 and `tasks-actions.astra.md`
/// TA-04): an edit elsewhere, one more page and an archived task's edit must
/// not re-read or re-project every loaded Done log row. Each runs the same
/// action with more pages loaded and fails when the count grows with them.
/// Each prints a `GUARD_` line with its counts.
///
/// The page is the real `TasksPage`, hosted in a borderless window that is
/// never shown. A step is settled by letting the main queue drain (an
/// expectation, not a fixed wait) and then laying out and drawing, as a
/// frame would.
@MainActor
final class DoneLoadedSetCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// Opus F4. With Done drawn, an edit to a Now task re-reads and
    /// re-projects the same number of Done log rows with four pages loaded
    /// as with one.
    func testGuardUnrelatedEditReadsNoMoreOfALongerLoadedDoneLog() throws {
        var reads: [Int: Int] = [:], projections: [Int: Int] = [:]
        for pages in [1, 4] {
            let (model, store, hosting) = try doneDrawn(loadedPages: pages)
            let id = try XCTUnwrap(store.tasks.first { $0.status == .todo }?.id)
            let parents = store.doneFamilyParentReadCount, pageReads = store.donePageReadCount
            let built = model.rowProjectionBuildCount
            XCTAssertTrue(model.setPriority(.high, for: [id]).isApplied)
            settle(hosting)
            settle(hosting)
            let parentReads = store.doneFamilyParentReadCount - parents
            let projected = model.rowProjectionBuildCount - built
            print("GUARD_DONE_UNRELATED_EDIT pages=\(pages) loaded=\(model.doneLogTasks.count) "
                  + "done_parent_reads=\(parentReads) done_page_reads=\(store.donePageReadCount - pageReads) row_projections=\(projected)")
            reads[pages] = parentReads
            projections[pages] = projected
        }
        XCTAssertEqual(reads[1], reads[4], "F4: an unrelated edit re-read more Done log rows with more pages loaded")
        XCTAssertEqual(projections[1], projections[4], "F4: an unrelated edit re-projected more rows with more pages loaded")
    }

    /// Astra TA-04. With Done drawn, appending one page projects the same
    /// number of rows with three pages loaded as with one, and an edit to one
    /// loaded archived task re-reads the same number of rows.
    func testGuardDonePageAppendAndArchivedEditDoNotGrowWithTheLoadedLog() throws {
        var appended: [Int: Int] = [:], edited: [Int: Int] = [:]
        for pages in [1, 3] {
            let (model, store, hosting) = try doneDrawn(loadedPages: pages)
            let built = model.rowProjectionBuildCount, parents = store.doneFamilyParentReadCount
            model.loadMoreDoneLog()
            settle(hosting)
            settle(hosting)
            let appendProjections = model.rowProjectionBuildCount - built
            let appendReads = store.doneFamilyParentReadCount - parents
            let archived = try XCTUnwrap(model.doneLogTasks.first?.id)
            let editParents = store.doneFamilyParentReadCount
            XCTAssertTrue(model.setPriority(.high, for: [archived]).isApplied)
            settle(hosting)
            settle(hosting)
            let editReads = store.doneFamilyParentReadCount - editParents
            print("GUARD_DONE_APPEND pages_before=\(pages) loaded_after=\(model.doneLogTasks.count) "
                  + "append_row_projections=\(appendProjections) append_parent_reads=\(appendReads) archived_edit_parent_reads=\(editReads)")
            appended[pages] = appendProjections
            edited[pages] = editReads
        }
        XCTAssertEqual(appended[1], appended[3], "TA-04: one appended Done page projected more rows with more pages loaded")
        XCTAssertEqual(edited[1], edited[3], "TA-04: an archived task's edit re-read more rows with more pages loaded")
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

    /// The Tasks page with Done drawn and `loadedPages` pages of its log loaded.
    private func doneDrawn(loadedPages: Int) throws -> (TasksPageModel, TaskStore, NSView) {
        let store = try makeStore(open: 20, logged: 400)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let hosting = page(model, store)
        model.select(tab: .done)
        model.showPagerPage(animated: false)
        settle(hosting)
        model.loadDoneLogIfNeeded()
        while model.doneLogTasks.count < loadedPages * TasksPageModel.doneLogPageSize, model.doneLogHasMore {
            model.loadMoreDoneLog()
        }
        settle(hosting)
        settle(hosting)
        XCTAssertEqual(model.tab, .done)
        XCTAssertGreaterThanOrEqual(model.doneLogTasks.count, loadedPages * TasksPageModel.doneLogPageSize)
        return (model, store, hosting)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore) -> NSView {
        host(TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                       addBarFocused: .constant(false)))
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
