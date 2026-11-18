import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Tasks page's update breadth (design/tasks-breadth.md): a change runs
/// the row wrapper (`TasksReorderCell`) of the rows that changed, not of
/// every drawn row. "Changed" is read from data: the row the action is on,
/// plus rows whose cell first draws in the turn (a row scrolled in). Wrappers
/// and leaves are counted per page and row (`TasksRowID`), Now's only.
@MainActor
final class TasksBreadthGuardTests: XCTestCase {
    private static let size = CGSize(width: 344, height: 520)
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        TasksCellBodyCounts.groupLookups = 0
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        TasksCellBodyCounts.recordsDragGroups = false
        TasksCellBodyCounts.dragGroups = [:]
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    // MARK: - Slice 1a: the breadth proof

    /// The proof as a test (rig `speed/count-guards` 7ff3eb4b: 15/15/16
    /// wrappers against one leaf per tick turn, 15 against 1 for a priority
    /// edit). The save turn and a direct priority edit reach the rows only
    /// through the page's pass; press and release also reach them through
    /// the cell broadcast, which slice 1b removes. Only the breadth is an
    /// expected failure: the tick is drawn on its own row in every turn.
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
        assertDelivered(press, "press")
        XCTExpectFailure("tasks-breadth-1b: the press still reaches every drawn wrapper through the cell broadcast") {
            assertOnlyChanged(press, "press")
        }
        let save = turn(hosting, pointer, rows.map(\.id), target: tick) {
            model.settlePendingCompletionAcknowledgements(through: tick)
        }
        assertOnlyChanged(save, "save")
        assertDelivered(save, "save")
        let release = turn(hosting, pointer, rows.map(\.id), target: tick) { model.releaseHold(tick) }
        XCTExpectFailure("tasks-breadth-1b: the release still reaches every drawn wrapper through the cell broadcast") {
            assertOnlyChanged(release, "release")
        }
        XCTAssertFalse(model.listSnapshot(for: .now).sections.open.contains { $0.id == tick }, "the released row left the open rows")

        let edited = rows[5].id
        let priority = turn(hosting, pointer, rows.map(\.id), target: edited) {
            XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        }
        assertOnlyChanged(priority, "priority")
        assertDelivered(priority, "priority")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[TasksRowID(tab: .now, id: edited)]?.priority, .high,
                       "the edited row drew its new priority")
    }

    /// The lead's condition 2 at the large seed: after every row of the
    /// list has been drawn once (so many cells were built), a full reload
    /// that names no tasks and changes no row runs no wrapper at all.
    func testAReloadWithoutIDsAfterScrollingTheWholeListRunsNoWrapper() throws {
        let store = try makeStore(open: 400)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let scroll = try XCTUnwrap(scrollViews(in: hosting).first { !$0.isHidden }, "Now's list")
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        var y: CGFloat = 0
        var visited = Set<UUID>()
        while y < documentHeight {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(hosting)
            visited.formUnion(drawnRows(pointer, ids))
            y += Self.size.height / 2
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(hosting)
        XCTAssertEqual(visited, Set(ids), "the scroll drew every row of the fixture")

        let revision = store.revision
        let reload = turn(hosting, pointer, ids, target: nil) { store.refresh() }
        print("BREADTH_RELOAD visited=\(visited.count) drawn=\(reload.drawnAfter.count) wrappers=\(reload.wrappers.count)")
        XCTAssertGreaterThan(store.revision, revision, "the reload published a new revision")
        XCTAssertNil(store.revisionChangedTaskIDs, "the reload named no tasks")
        XCTAssertEqual(reload.wrappers, [], "a reload that changed no row ran wrappers: \(reload.wrappers.count)")
    }

    /// A wrapper that skips a page pass still starts a drag with its date
    /// group as it is now, in order, through the callback it was built
    /// with: a task added to the group, the dragged row itself unchanged.
    func testAWrapperStartsADragWithItsCurrentGroup() throws {
        TasksCellBodyCounts.recordsDragGroups = true
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let first = try XCTUnwrap(model.rows(for: .now).first).id
        let row = TasksRowID(tab: .now, id: first)
        let original = try XCTUnwrap(TasksCellBodyCounts.dragGroups[row], "the row's wrapper was never built")
        XCTAssertEqual(original().count, 6)
        let added = try XCTUnwrap(store.create(title: "Joins the group"))
        settle(hosting)
        settle(hosting)
        let current = try XCTUnwrap(model.listSnapshot(for: .now).entries.first { $0.row?.id == first }).reorderIDs
        XCTAssertTrue(current.contains(added.id))
        XCTAssertEqual(original(), current, "the callback the wrapper was built with reads the group as it is now, in order")
    }

    // MARK: - Fix round 1: what the wrapper's key compares

    /// Astra R-1, Opus R-1: a row due 12 days ahead, then the clock jumps 15
    /// days. The date's text and day stay the same, its tone and whether it
    /// shows change: the row draws the new projection.
    func testADateJumpRedrawsARowWhoseDueTextStaysTheSame() throws {
        let start = Date()
        let calendar = TasksPageServices().calendar()
        let due = DueDay(date: try XCTUnwrap(calendar.date(byAdding: .day, value: 12, to: start)), calendar: calendar)
        let store = try makeStore(open: 6, due: due)
        let clock = Clock(now: start)
        var services = TasksPageServices()
        services.now = { clock.now }
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: services)
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let dated = try XCTUnwrap(model.rows(for: .now).first { $0.due == due }).id
        let row = TasksRowID(tab: .now, id: dated)
        XCTAssertNotNil(pointer.frame(for: row), "the dated row is drawn")
        let before = try XCTUnwrap(projected(model, dated))

        clock.now = try XCTUnwrap(calendar.date(byAdding: .day, value: 15, to: start))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        settle(hosting)
        settle(hosting)
        let after = try XCTUnwrap(projected(model, dated))
        XCTAssertEqual(after.due?.text, before.due?.text, "the case under test: the date's text is unchanged")
        XCTAssertNotEqual(after, before, "the case under test: the projection changed (tone or shown)")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[row], after, "the row still draws the date as it was before the jump")
    }

    /// Astra R-4: once a page pass has read a new palette, every drawn
    /// row's builder (whose page copy the row's menus read: the Tags
    /// submenu's swatches) reads it too, as on the trunk, where every pass
    /// rebuilt the wrappers.
    func testAPaletteChangeReachesTheRowBuilders() throws {
        // Alone only (tiny fix, board row tasks-env-stale-rows): once other
        // Tasks pages have been hosted in the process, a pass from the
        // palette alone stops short of the rows, on the trunk too. The
        // switch goes when that is named and fixed.
        guard ProcessInfo.processInfo.environment["ATTIC_ALONE_GUARDS"] == "1" else {
            throw XCTSkip("runs alone: TEST_RUNNER_ATTIC_ALONE_GUARDS=1 (tasks-env-stale-rows)")
        }
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let palette = PaletteBox()
        let hosting = page(model, store, pointer: pointer, palette: palette)
        let drawn = drawnRows(pointer, model.rows(for: .now).map(\.id)).map { TasksRowID(tab: .now, id: $0) }
        XCTAssertFalse(drawn.isEmpty)
        let recoloured = AtticTagPalette(hues: ["work": .green])
        palette.palette = recoloured
        settle(hosting)
        // The page's own pass: a palette change alone need not redraw the
        // page (it reads the palette only in its rows), its model does.
        model.objectWillChange.send()
        let passed = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                hosting.window?.displayIfNeeded()
                return drawn.allSatisfy { TasksCellBodyCounts.passPalettes[$0] == recoloured }
            }
        }, evaluatedWith: nil)
        wait(for: [passed], timeout: 5)
        settle(hosting)
        let stale = drawn.filter { TasksCellBodyCounts.builderPalettes[$0] != recoloured }
        print("BREADTH_PALETTE drawn=\(drawn.count) stale_builders=\(stale.count)")
        XCTAssertEqual(stale.count, 0, "rows whose menus read the old palette after a pass that read the new one")
    }

    /// Astra R-4, in the suite: the palette changes, then an edit to one
    /// row passes the page; every untouched drawn row's builder reads the
    /// new palette, as on the trunk. (The palette alone is the guard above,
    /// which runs alone.)
    func testAPaletteChangeReachesTheRowBuildersOnAnEdit() throws {
        let store = try makeStore(open: 6)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let palette = PaletteBox()
        let hosting = page(model, store, pointer: pointer, palette: palette)
        let ids = model.rows(for: .now).map(\.id)
        let drawn = drawnRows(pointer, ids).map { TasksRowID(tab: .now, id: $0) }
        XCTAssertGreaterThan(drawn.count, 1)
        let recoloured = AtticTagPalette(hues: ["work": .green])
        palette.palette = recoloured
        settle(hosting)
        XCTAssertTrue(model.setPriority(.high, for: [ids[0]]).isApplied)
        let passed = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                hosting.window?.displayIfNeeded()
                return drawn.allSatisfy { TasksCellBodyCounts.passPalettes[$0] == recoloured }
            }
        }, evaluatedWith: nil)
        wait(for: [passed], timeout: 5)
        settle(hosting)
        let untouched = drawn.filter { $0.id != ids[0] }
        let stale = untouched.filter { TasksCellBodyCounts.builderPalettes[$0] != recoloured }
        print("BREADTH_PALETTE_EDIT drawn=\(drawn.count) untouched=\(untouched.count) stale_builders=\(stale.count)")
        XCTAssertEqual(stale.count, 0, "rows whose menus read the old palette after a pass that read the new one")
    }

    // MARK: - Fix round 1: drags

    /// Astra R-2: in Backlog's Find, A and B match. A is lifted toward B;
    /// before the release B is renamed out of Find. The release lands A
    /// back: no order is written and no undo step added, as on the trunk,
    /// where the cell's group was the one shown.
    func testARowThatLeavesTheGroupMidDragMeansNoWriteAndNoUndoStep() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: [TaskDraft(title: "Match A", status: .backlog),
                                           TaskDraft(title: "Match B", status: .backlog),
                                           TaskDraft(title: "Other C", status: .backlog)])
        defer { host.close() }
        host.model.select(tab: .backlog)
        host.model.setSearchQuery("Match", for: .backlog)
        let shown = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let rows = host.model.rows(for: .backlog)
                return rows.count == 2 && rows.allSatisfy { host.pointer.frames[TasksRowID(tab: .backlog, id: $0.id)] != nil }
            }
        }, evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        let ids = host.model.rows(for: .backlog).map(\.id)
        let (lifted, leaving) = (ids[0], ids[1])
        let all = host.store.tasks.map(\.id)
        let orders = all.map { host.store.task(withID: $0)?.manualOrder }
        let step = host.model.library.undo.undoStepID(in: .tasks)
        var groupBeforeRelease: [UUID]?
        var stepBeforeRelease: UUID?
        try host.drag(lifted, in: .backlog, steps: [6, 20, 44], then: { _ in
            guard let task = host.store.task(withID: leaving) else { return }
            XCTAssertTrue(host.store.update(task, title: "Renamed B"))
        }, beforeRelease: {
            groupBeforeRelease = host.model.listSnapshot(for: .backlog).entries.first { $0.row?.id == lifted }?.reorderIDs
            stepBeforeRelease = host.model.library.undo.undoStepID(in: .tasks)
        })
        XCTAssertEqual(groupBeforeRelease, [lifted], "the case under test: B left Find before the release")
        XCTAssertEqual(stepBeforeRelease, step, "the case under test: the rename added no undo step")
        XCTAssertEqual(all.map { host.store.task(withID: $0)?.manualOrder }, orders, "the release wrote an order")
        XCTAssertEqual(host.model.library.undo.undoStepID(in: .tasks), step, "the release added an undo step")
        XCTAssertEqual(host.store.task(withID: lifted)?.status, .backlog)
        XCTAssertNil(host.store.task(withID: lifted)?.dueDay)
    }

    /// Astra R-8, Opus R-3: a press the row refuses (on the circle column)
    /// never works out a drag group, however far it moves; an accepted
    /// drag works it out once, when it lifts.
    func testADragWorksOutItsGroupOnlyOnceItLifts() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: (0..<4).map { TaskDraft(title: "Task \($0)") })
        defer { host.close() }
        let ids = host.model.rows(for: .now).map(\.id)
        TasksCellBodyCounts.groupLookups = 0
        try host.drag(ids[3], x: 12, steps: [6, 20, 40, 60], then: { post in post(30) }, beforeRelease: {})
        XCTAssertEqual(TasksCellBodyCounts.groupLookups, 0, "a refused press worked out the drag group")

        TasksCellBodyCounts.groupLookups = 0
        var whileLifted: Int?
        try host.drag(ids[0], steps: [6, 20, 40, 60], then: { _ in }, beforeRelease: {
            whileLifted = TasksCellBodyCounts.groupLookups
        })
        XCTAssertEqual(whileLifted, 1, "an accepted drag works out its group once, when it lifts")
    }

    /// Astra R-7: a real drag after a task joined the group moves among the
    /// group as it is now: dragged past every row, the lifted task lands
    /// last, after the one that joined.
    func testADragAfterATaskJoinsLandsAmongTheCurrentGroup() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        let host = try CrossDayHost(seed: (0..<3).map { TaskDraft(title: "Task \($0)") })
        defer { host.close() }
        let lifted = try XCTUnwrap(host.model.rows(for: .now).first).id
        let joined = try XCTUnwrap(host.store.create(title: "Joins the group")).id
        let shown = expectation(for: NSPredicate { _, _ in MainActor.assumeIsolated { host.model.rows(for: .now).count == 4 } },
                                evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        let order = host.model.rows(for: .now).map(\.id)
        XCTAssertEqual(order.count, 4)
        XCTAssertTrue(order.contains(joined))
        try host.drag(lifted, steps: [6, 20, 60, 100, 140, 180, 220], then: { _ in }, beforeRelease: {})
        XCTAssertEqual(host.model.rows(for: .now).map(\.id).last, lifted, "the lifted task lands after every row of the current group")
    }

    // MARK: - The page's lifetime

    /// The wrappers' closures hold copies of the page, and a wrapper a pass
    /// skips keeps them: a page that leaves its window should let its model
    /// go. It does not yet, on the trunk's page as well (Air, 2026-11-18,
    /// 19672e10's page): the model outlives a hosted page that leaves, a
    /// leak older than 1a and tracked on the board as
    /// `tasks-hosted-page-leak`. Strict, so its fix shows here.
    func testAHostedPageThatLeavesLetsItsModelGo() throws {
        weak var released: TasksPageModel?
        try autoreleasepool {
            let store = try makeStore(open: 12)
            let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
            released = model
            let pointer = TasksPointer()
            let hosting = page(model, store, pointer: pointer)
            XCTAssertFalse(drawnRows(pointer, model.rows(for: .now).map(\.id)).isEmpty)
            window?.contentView = nil
            window?.close()
            window = nil
            settle(hosting)
        }
        for _ in 0..<20 where released != nil { drain() }
        XCTExpectFailure("tasks-hosted-page-leak: a hosted Tasks page's model outlives the page (trunk too)") {
            XCTAssertNil(released, "the page's model outlived the page")
        }
    }

    /// A page that leaves its window and comes back draws every row and
    /// shows a change made while it was away (no wrapper is left empty).
    func testAPageThatLeavesAndComesBackDrawsItsRowsAndTheirChanges() throws {
        let store = try makeStore(open: 12)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let pointer = TasksPointer()
        let hosting = page(model, store, pointer: pointer)
        let ids = model.rows(for: .now).map(\.id)
        let before = drawnRows(pointer, ids)
        let window = try XCTUnwrap(window)
        window.contentView = NSView(frame: hosting.frame)
        drain()
        let edited = ids[1]
        XCTAssertTrue(model.setPriority(.high, for: [edited]).isApplied)
        drain()
        window.contentView = hosting
        settle(hosting)
        settle(hosting)
        XCTAssertEqual(drawnRows(pointer, ids), before, "a row came back undrawn")
        XCTAssertEqual(TasksCellBodyCounts.leafModels[TasksRowID(tab: .now, id: edited)]?.priority, .high,
                       "the changed row draws its new priority on return")
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
        let wrappers = TasksCellBodyCounts.evaluations, leaves = TasksCellBodyCounts.leaves
        let before = drawnRows(pointer, ids)
        action()
        settle(hosting)
        settle(hosting)
        func ran(_ counts: [TasksRowID: Int], _ base: [TasksRowID: Int]) -> Set<UUID> {
            Set(counts.compactMap { row, count in row.tab == .now && count > base[row, default: 0] ? row.id : nil })
        }
        return Turn(target: target, wrappers: ran(TasksCellBodyCounts.evaluations, wrappers),
                    leaves: ran(TasksCellBodyCounts.leaves, leaves), drawnBefore: before, drawnAfter: drawnRows(pointer, ids))
    }

    /// Only the changed rows' wrappers ran.
    private func assertOnlyChanged(_ turn: Turn, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        print("BREADTH_TURN \(name) \(turn.line)")
        XCTAssertEqual(turn.wrappers.subtracting(turn.changed), [],
                       "\(name): wrappers of unchanged rows ran (\(turn.line))", file: file, line: line)
    }

    /// The change was delivered: the target's leaf on Now ran.
    private func assertDelivered(_ turn: Turn, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let target = turn.target else { return }
        XCTAssertTrue(turn.leaves.contains(target), "\(name): the changed row was not redrawn", file: file, line: line)
    }

    // MARK: - Fixture

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    private final class PaletteBox: ObservableObject {
        @Published var palette = AtticTagPalette.empty
    }

    private struct PaletteRoot<Content: View>: View {
        @ObservedObject var box: PaletteBox
        let content: Content
        var body: some View { content.environment(\.atticTagColouring, AtticTagColouring(palette: box.palette)) }
    }

    private func projected(_ model: TasksPageModel, _ id: UUID) -> AtticTaskRowModel? {
        model.listSnapshot(for: .now).rows.first { $0.id == id }?.model
    }

    private func drawnRows(_ pointer: TasksPointer, _ ids: [UUID]) -> Set<UUID> {
        Set(ids.filter { pointer.frame(for: TasksRowID(tab: .now, id: $0)) != nil })
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(scrollViews)
    }

    private func makeStore(open: Int, due: DueDay? = nil) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        for index in 0..<open {
            order -= 1_024
            let item = TaskItem(title: "Open task \(index)", status: .todo, createdAt: now, manualOrder: order)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if index == 0 { item.dueDay = due }
            context.insert(item)
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func page(_ model: TasksPageModel, _ store: TaskStore, pointer: TasksPointer,
                      palette: PaletteBox = PaletteBox()) -> NSView {
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                             addBarFocused: .constant(false), pointer: pointer)
        let root = PaletteRoot(box: palette, content: page.frame(width: Self.size.width, height: Self.size.height))
        let hosting = NSHostingView(rootView: root.atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        settle(hosting)
        settle(hosting)
        return hosting
    }

    /// The main queue drains (an expectation, no fixed wait).
    private func drain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// The main queue drains, then the page lays out and draws.
    private func settle(_ hosting: NSView) {
        drain()
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }
}
