import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Red-first count guard for the tag bar's Done log walk (18 Nov 2026,
/// `reports/perf-audit/tasks-actions.astra.md` TA-05): an edit on Now must
/// not visit every Done log entry to list the tag chips. It runs the same
/// edit with a longer log and fails when the count grows with it, and
/// prints a `GUARD_` line with its count.
///
/// The page is the real `TasksPage`, hosted in a borderless window that is
/// never shown. A step is settled by letting the main queue drain (an
/// expectation, not a fixed wait) and then laying out and drawing, as a
/// frame would.
@MainActor
final class DoneLogTagsCountGuardTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// Astra TA-05. A priority edit on Now: the tag bar's chips visit the same
    /// number of Done log index entries with a Done log ten times longer.
    func testGuardPriorityEditVisitsNoMoreDoneLogEntriesForTheTagBar() throws {
        var bySize: [Int: Int] = [:]
        for logged in [50, 500] {
            let store = try makeStore(open: 20, logged: logged, tagged: true)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let hosting = page(model, store)
            let id = try XCTUnwrap(model.rows(for: .now).first?.id)
            let before = store.doneLogTagEntryVisits
            XCTAssertTrue(model.setPriority(.high, for: [id]).isApplied)
            settle(hosting)
            settle(hosting)
            let visits = store.doneLogTagEntryVisits - before
            print("GUARD_TAG_BAR open=20 done_log=\(logged) done_log_entries_visited=\(visits)")
            bySize[logged] = visits
        }
        XCTAssertEqual(bySize[50], bySize[500], "TA-05: a priority edit's tag bar walk grew with the Done log")
    }

    /// The fix's own check: the tags the index counts are the tags a walk
    /// of every Done log entry finds, through tagging and untagging logged
    /// tasks, a tag's last task leaving the log (delete, Restore to Now),
    /// Undo, a full reload and a task finishing on Now.
    func testDoneLogTagCountsMatchAWalkOfTheLog() throws {
        let store = try makeStore(open: 6, logged: 30, tagged: true)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let hosting = page(model, store)
        let logged = store.indexedDoneLogPage(limit: 30).tasks.map(\.id)
        XCTAssertEqual(logged.count, 30)
        func check(_ name: String, _ body: () -> Void) {
            body()
            settle(hosting)
            let counted = store.indexedDoneLogTags(), walked = store.walkedDoneLogTags()
            print("DONE_LOG_TAGS step=\"\(name)\" tags=\(counted.sorted())")
            XCTAssertEqual(counted, walked, name)
            XCTAssertTrue(counted.isSubset(of: Set(model.tagChips())), "\(name): the chips list the log's tags")
        }
        check("seeded") {}
        check("tag a logged task") { XCTAssertTrue(model.toggleTag("only-here", for: [logged[0]]).isApplied) }
        check("its tag again on another") { XCTAssertTrue(model.toggleTag("only-here", for: [logged[1]]).isApplied) }
        check("untag one of the two") { XCTAssertTrue(model.toggleTag("only-here", for: [logged[0]]).isApplied) }
        XCTAssertTrue(store.indexedDoneLogTags().contains("only-here"), "one logged task still carries it")
        check("delete the last task carrying it") { XCTAssertTrue(model.delete([logged[1]]).isApplied) }
        XCTAssertFalse(store.indexedDoneLogTags().contains("only-here"), "no logged task carries it")
        check("Undo the delete") { XCTAssertTrue(model.undo().isApplied) }
        XCTAssertTrue(store.indexedDoneLogTags().contains("only-here"), "Undo brought its task back to the log")
        check("Restore to Now") { XCTAssertTrue(model.restoreToNow([logged[1]]).isApplied) }
        XCTAssertFalse(store.indexedDoneLogTags().contains("only-here"), "its task left the log")
        check("a full reload") { store.refresh() }
        check("finish a task on Now") {
            if let open = model.rows(for: .now).first?.id { XCTAssertTrue(model.complete(open).isApplied) }
        }
        check("untag a seeded tag") { XCTAssertTrue(model.toggleTag("done3", for: [logged[3]]).isApplied) }
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
