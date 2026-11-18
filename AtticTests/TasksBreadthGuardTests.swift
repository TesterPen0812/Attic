import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Tasks page's update breadth (design/tasks-breadth.md): a change runs
/// the row wrapper (`TasksReorderCell`) of the rows that changed, not of
/// every drawn row. "Changed" is read from data: the row the action is on,
/// plus rows whose cell first draws in the turn (a row scrolled in).
@MainActor
final class TasksBreadthGuardTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 520)
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - Slice 1a: the breadth proof

    /// The proof as a test (rig `speed/count-guards` 7ff3eb4b: 15/15/16
    /// wrappers against one leaf per tick turn, 15 against 1 for a priority
    /// edit). The save turn and a direct priority edit reach the rows only
    /// through the page's pass; press and release also reach them through
    /// the cell broadcast, which slice 1b removes.
    func testATickAndAPriorityEditRunOnlyTheWrappersOfTheRowsThatChanged() throws {
        let store = try makeStore(open: 40)
        var services = TasksPageServices()
        services.acknowledgementDelay = .seconds(25)
        services.doneHold = .seconds(25)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let rows = model.rows(for: .now)
        let drawn = drawnRows(pointer, rows.map(\.id))
        XCTAssertGreaterThan(drawn.count, 5, "the hosted page drew too few rows for the count to mean anything")

        let tick = rows[2].id
        let press = turn(hosting, pointer, rows.map(\.id), target: tick) { model.completeAcknowledged(tick) { _ in } }
        XCTExpectFailure("tasks-breadth-1b: the press still reaches every drawn wrapper through the cell broadcast") {
            assertOnlyChanged(press, "press")
        }
        let save = turn(hosting, pointer, rows.map(\.id), target: tick) {
            model.settlePendingCompletionAcknowledgements(through: tick)
        }
        assertOnlyChanged(save, "save")
        let release = turn(hosting, pointer, rows.map(\.id), target: tick) { model.releaseHold(tick) }
        XCTExpectFailure("tasks-breadth-1b: the release still reaches every drawn wrapper through the cell broadcast") {
            assertOnlyChanged(release, "release", delivered: false)
        }
        XCTAssertFalse(model.listSnapshot(for: .now).sections.open.contains { $0.id == tick }, "the released row left the open rows")

        let edited = rows[5].id
        let priority = turn(hosting, pointer, rows.map(\.id), target: edited) {
            XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        }
        assertOnlyChanged(priority, "priority")
    }

    /// The lead's condition 2 at the large seed: after the whole list has
    /// been scrolled through (so many cells were built), a reload that names
    /// no tasks and changes no row runs no wrapper, and never one of a row
    /// that is not drawn.
    func testAReloadWithoutIDsAfterScrollingTheWholeListRunsNoWrapper() throws {
        let store = try makeStore(open: 400)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let scroll = try XCTUnwrap(scrollViews(in: hosting).first { !$0.isHidden }, "Now's list")
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        var y: CGFloat = 0
        var scrolledPast = Set<UUID>()
        while y < documentHeight {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(hosting)
            scrolledPast.formUnion(drawnRows(pointer, ids))
            y += Self.size.height / 2
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(hosting)
        XCTAssertGreaterThan(scrolledPast.count, 200, "the scroll built most of the list")

        let reload = turn(hosting, pointer, ids, target: nil) { store.refresh() }
        print("BREADTH_RELOAD built=\(scrolledPast.count) drawn=\(reload.drawnAfter.count) wrappers=\(reload.wrappers.count)")
        XCTAssertTrue(reload.wrappers.isSubset(of: reload.drawnAfter.union(reload.drawnBefore)),
                      "a reload ran the wrapper of a row that is not drawn")
        XCTAssertEqual(reload.wrappers.subtracting(reload.mounted), [],
                       "a reload that changed no row ran wrappers: \(reload.wrappers.count)")
    }

    /// A wrapper that skips a page pass still starts a drag with its date
    /// group as it is now, not as it was when the wrapper last ran: a task
    /// added to the group, the dragged row itself unchanged.
    func testAWrapperStartsADragWithItsCurrentGroup() throws {
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let first = try XCTUnwrap(model.rows(for: .now).first).id
        let row = TasksRowID(tab: .now, id: first)
        XCTAssertEqual(TasksCellBodyCounts.dragGroups[row]?().count, 6)
        let added = try XCTUnwrap(store.create(title: "Joins the group"))
        settle(hosting)
        settle(hosting)
        let group = try XCTUnwrap(TasksCellBodyCounts.dragGroups[row]?(), "the row's wrapper was never built")
        XCTAssertEqual(Set(group), Set(model.rows(for: .now).map(\.id)), "the drag group is the one the wrapper last saw")
        XCTAssertTrue(group.contains(added.id))
    }

    // MARK: - Turns

    private struct Turn {
        let target: UUID?
        let wrappers: Set<UUID>
        let leaves: Set<UUID>
        let drawnBefore: Set<UUID>
        let drawnAfter: Set<UUID>
        var mounted: Set<UUID> { drawnAfter.subtracting(drawnBefore) }
        var changed: Set<UUID> { mounted.union(target.map { [$0] } ?? []) }
        var line: String {
            "wrappers=\(wrappers.count) leaves=\(leaves.count) mounted=\(mounted.count) "
                + "other_wrappers=\(wrappers.subtracting(changed).count) drawn=\(drawnAfter.count)"
        }
    }

    private func turn(_ hosting: NSView, _ pointer: TasksPointer, _ ids: [UUID], target: UUID?,
                      _ action: () -> Void) -> Turn {
        let wrappers = TasksCellBodyCounts.evaluations, leaves = AtticTaskRow.evaluations
        let before = drawnRows(pointer, ids)
        action()
        settle(hosting)
        settle(hosting)
        let ran = Set(TasksCellBodyCounts.evaluations.compactMap { row, count in
            row.tab == .now && count > wrappers[row, default: 0] ? row.id : nil
        })
        let leaf = Set(AtticTaskRow.evaluations.compactMap { id, count in count > leaves[id, default: 0] ? id : nil })
        return Turn(target: target, wrappers: ran, leaves: leaf, drawnBefore: before, drawnAfter: drawnRows(pointer, ids))
    }

    /// Only the changed rows' wrappers ran, and the change was delivered:
    /// the target's leaf ran (it shows the new state).
    private func assertOnlyChanged(_ turn: Turn, _ name: String, delivered: Bool = true,
                                   file: StaticString = #filePath, line: UInt = #line) {
        print("BREADTH_TURN \(name) \(turn.line)")
        XCTAssertEqual(turn.wrappers.subtracting(turn.changed), [],
                       "\(name): wrappers of unchanged rows ran (\(turn.line))", file: file, line: line)
        if delivered, let target = turn.target {
            XCTAssertTrue(turn.leaves.contains(target), "\(name): the changed row was not redrawn", file: file, line: line)
        }
    }

    // MARK: - Fixture

    private func drawnRows(_ pointer: TasksPointer, _ ids: [UUID]) -> Set<UUID> {
        Set(ids.filter { pointer.frame(for: TasksRowID(tab: .now, id: $0)) != nil })
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(scrollViews)
    }

    private func makeStore(open: Int) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<open {
            order -= 1_024
            let item = TaskItem(title: "Open task \(index)", status: .todo, createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore, pointer: TasksPointer) -> NSView {
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                             addBarFocused: .constant(false), pointer: pointer)
        let hosting = NSHostingView(rootView: page.frame(width: Self.size.width, height: Self.size.height).atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        settle(hosting)
        settle(hosting)
        return hosting
    }

    /// The main queue drains (an expectation, no fixed wait), then the page
    /// lays out and draws.
    private func settle(_ hosting: NSView) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }
}
