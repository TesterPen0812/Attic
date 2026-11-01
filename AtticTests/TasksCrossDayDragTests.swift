import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Accepted 2026-11-01 "Adaptive picks", "Drag a task into another day":
/// a row dropped under another day's header on Now takes that day as its
/// date (it keeps its time; under No date the date clears; Overdue takes no
/// drop), as one Undo step for its date and its place. While the drag is
/// live, Today and Tomorrow show as empty headers. Reduce Motion and Reduce
/// Transparency are stated (CI turns both on).
@MainActor
final class TasksCrossDayDragTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    private var calendar: Calendar { TasksPageServices().calendar() }
    private var today: DueDay { DueDay(date: Date(), calendar: calendar) }
    private var tomorrow: DueDay { TasksPanelDesign.tomorrow(after: today, calendar: calendar)! }
    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: Date())!, calendar: calendar)
    }

    // MARK: - Where a drop lands (pure)

    private func row(_ id: UUID, _ status: TaskStatus = .todo, time: Int? = nil, y: CGFloat?) -> TasksDayDropFinder.Row {
        .init(id: id, status: status, time: time, frame: y.map { CGRect(x: 0, y: $0, width: 300, height: 30) })
    }

    func testTheDayUnderThePointerTakesTheDropButNeverItsOwnDayOrOverdue() {
        let (late, mine, other, next) = (UUID(), UUID(), UUID(), UUID())
        let dragged = row(mine, y: 130)
        let days: [TasksDayDropFinder.Day] = [
            .init(key: "overdue", kind: .overdue, header: CGRect(x: 0, y: 0, width: 300, height: 30), rows: [row(late, y: 30)]),
            .init(key: "today", kind: .today, header: CGRect(x: 0, y: 60, width: 300, height: 30), rows: [row(other, y: 90)]),
            .init(key: "tomorrow", kind: .day(tomorrow), header: CGRect(x: 0, y: 150, width: 300, height: 30), rows: [row(next, y: 180)]),
            .init(key: "none", kind: .noDate, header: CGRect(x: 0, y: 210, width: 300, height: 30), rows: [])
        ]
        func target(_ y: CGFloat) -> TasksDayDrop? {
            TasksDayDropFinder.target(at: y, dragged: dragged, ownKey: "today", days: days, today: today)
        }
        XCTAssertNil(target(40), "Overdue takes no drop")
        XCTAssertNil(target(100), "its own day is a reorder")
        let underHeader = target(176)
        XCTAssertEqual(underHeader?.key, "tomorrow")
        XCTAssertEqual(underHeader?.change, .day(tomorrow))
        XCTAssertEqual(underHeader?.index, 0)
        XCTAssertEqual(underHeader?.before, next, "just before the day's first row")
        XCTAssertEqual(underHeader?.lineY, 180, "the drop line at that row's top")
        let afterLast = target(200)
        XCTAssertEqual(afterLast?.index, 1)
        XCTAssertEqual(afterLast?.after, next)
        XCTAssertEqual(afterLast?.lineY, 210)
        let noDate = target(230)
        XCTAssertEqual(noDate?.change, .clear, "a drop under No date clears the date")
        XCTAssertEqual(noDate?.lineY, 240, "under the header")
        XCTAssertNil(TasksDayDropFinder.change(for: .overdue, today: today))
    }

    func testStartedTasksStayTogetherAndATimedTaskTakesItsClockPlace() {
        let (started, nine, untimed, eleven) = (UUID(), UUID(), UUID(), UUID())
        let rows = [row(started, .inProgress, y: 30), row(nine, time: 540, y: 60), row(eleven, time: 660, y: 90), row(untimed, y: 120)]
        let days: [TasksDayDropFinder.Day] = [.init(key: "tomorrow", kind: .day(tomorrow), header: CGRect(x: 0, y: 0, width: 300, height: 30), rows: rows)]
        // A task to do, untimed, held over the started row: after the
        // started ones and after the timed ones.
        let todo = TasksDayDropFinder.target(at: 32, dragged: row(UUID(), y: nil), ownKey: "today", days: days, today: today)
        XCTAssertEqual(todo?.index, 3)
        XCTAssertEqual(todo?.before, untimed)
        // A timed one (10:00) lands between 09:00 and 11:00 wherever it is held.
        let timed = TasksDayDropFinder.target(at: 125, dragged: row(UUID(), time: 600, y: nil), ownKey: "today", days: days, today: today)
        XCTAssertEqual(timed?.index, 2)
        XCTAssertEqual(timed?.lineY, 90)
        // A started one stays with the started ones.
        let start = TasksDayDropFinder.target(at: 125, dragged: row(UUID(), .inProgress, y: nil), ownKey: "today", days: days, today: today)
        XCTAssertEqual(start?.index, 1)
        XCTAssertEqual(start?.after, started)
    }

    // MARK: - The model

    private func makeModel(persist: ((ModelContext) throws -> Void)? = nil) throws -> (TaskStore, TasksPageModel) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = persist.map { TaskStore(container: container, persist: $0) } ?? TaskStore(container: container)
        return (store, TasksPageModel(library: AtticLibrary(tasks: store)))
    }

    private func id(_ title: String, _ store: TaskStore) throws -> UUID {
        try XCTUnwrap(store.tasks.first { $0.title == title }?.id)
    }

    private func ids(_ model: TasksPageModel, in kind: TasksPanelDesign.GroupKind) -> [UUID]? {
        model.sections(for: .now).groups.first { $0.kind == kind }?.ids
    }

    private func drop(_ model: TasksPageModel, into kind: TasksPanelDesign.GroupKind, before: UUID? = nil, after: UUID? = nil) -> TasksDayDrop {
        let groups = model.sections(for: .now).groups
        let group = groups.first { $0.kind == kind }
        return TasksDayDrop(key: group?.key ?? "", change: TasksDayDropFinder.change(for: kind, today: today)!,
                            index: 0, before: before, after: after, lineY: 0)
    }

    func testACrossDayDropChangesTheDateKeepsTheTimeAndTakesItsPlace() throws {
        let (store, model) = try makeModel()
        _ = store.commit([TaskDraft(title: "Stand-up", dueDay: today, dueTimeMinutes: 600),
                          TaskDraft(title: "Water plants", dueDay: today),
                          TaskDraft(title: "Dentist", dueDay: tomorrow, dueTimeMinutes: 540),
                          TaskDraft(title: "Buy milk", dueDay: tomorrow),
                          TaskDraft(title: "Call mum", dueDay: tomorrow)])
        let standUp = try id("Stand-up", store), water = try id("Water plants", store)
        let tomorrows = try XCTUnwrap(ids(model, in: .day(tomorrow)))
        XCTAssertEqual(tomorrows.count, 3)

        XCTAssertTrue(model.moveToDay(standUp, drop(model, into: .day(tomorrow))).isApplied)
        let task = try XCTUnwrap(store.task(withID: standUp))
        XCTAssertEqual(task.dueDay, tomorrow, "the date becomes that day")
        XCTAssertEqual(task.dueTimeMinutes, 600, "it keeps its time")
        XCTAssertEqual(ids(model, in: .day(tomorrow))?.prefix(2).map { $0 }, [tomorrows[0], standUp], "in clock order: after 09:00")

        // An untimed one lands where it was dropped: between the two untimed.
        let last = tomorrows[2], middle = tomorrows[1]
        XCTAssertTrue(model.moveToDay(water, drop(model, into: .day(tomorrow), before: last)).isApplied)
        XCTAssertEqual(ids(model, in: .day(tomorrow)), [tomorrows[0], standUp, middle, water, last])
        XCTAssertNil(ids(model, in: .today), "Today is empty and folds away")
    }

    func testADropUnderNoDateClearsTheDate() throws {
        let (store, model) = try makeModel()
        _ = store.commit([TaskDraft(title: "Stand-up", dueDay: tomorrow, dueTimeMinutes: 600), TaskDraft(title: "Read a book")])
        let standUp = try id("Stand-up", store)
        XCTAssertTrue(model.moveToDay(standUp, drop(model, into: .noDate)).isApplied)
        let task = try XCTUnwrap(store.task(withID: standUp))
        XCTAssertNil(task.dueDay)
        XCTAssertNil(task.dueTimeMinutes, "a time needs a date (the date card clears both)")
        XCTAssertEqual(task.status, .todo, "it stays on Now")
        XCTAssertTrue(ids(model, in: .noDate)?.contains(standUp) ?? false)
    }

    func testOneUndoRestoresBothTheDateAndThePlace() throws {
        let (store, model) = try makeModel()
        _ = store.commit([TaskDraft(title: "Water plants", dueDay: today), TaskDraft(title: "Pay rent", dueDay: today),
                          TaskDraft(title: "Buy milk", dueDay: tomorrow), TaskDraft(title: "Call mum", dueDay: tomorrow)])
        let before = model.rows(for: .now).map(\.id)
        let water = try id("Water plants", store), firstTomorrow = try XCTUnwrap(ids(model, in: .day(tomorrow))?.first)
        // The task that moves is the first or second of Today; whichever,
        // it lands before Tomorrow's first row.
        XCTAssertTrue(model.moveToDay(water, drop(model, into: .day(tomorrow), before: firstTomorrow)).isApplied)
        XCTAssertEqual(ids(model, in: .day(tomorrow))?.first, water)
        XCTAssertNotEqual(model.rows(for: .now).map(\.id), before)

        XCTAssertTrue(model.library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: water)?.dueDay, today, "the date comes back")
        XCTAssertEqual(model.rows(for: .now).map(\.id), before, "and so does the order, in the same step")
        XCTAssertFalse(model.library.undo.canUndo(in: .tasks), "one drag was one step")
        XCTAssertTrue(model.library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: water)?.dueDay, tomorrow)
        XCTAssertEqual(ids(model, in: .day(tomorrow))?.first, water, "redo brings both back too")
    }

    func testAFailedSaveRollsBackBothTheDateAndThePlace() throws {
        let gate = PersistenceGate()
        let (store, model) = try makeModel(persist: gate.save)
        _ = store.commit([TaskDraft(title: "Water plants", dueDay: today), TaskDraft(title: "Buy milk", dueDay: tomorrow)])
        let water = try id("Water plants", store), milk = try id("Buy milk", store)
        let before = model.rows(for: .now).map(\.id)
        gate.shouldFail = true
        XCTAssertFalse(model.moveToDay(water, drop(model, into: .day(tomorrow), after: milk)).isApplied)
        gate.shouldFail = false
        XCTAssertEqual(store.task(withID: water)?.dueDay, today)
        XCTAssertEqual(model.rows(for: .now).map(\.id), before)
        XCTAssertFalse(model.library.undo.canUndo(in: .tasks), "a failed drop leaves no Undo step")
    }

    func testTodayAndTomorrowShowAsEmptyHeadersOnlyWhileADragIsLive() throws {
        let (store, model) = try makeModel()
        _ = store.commit([TaskDraft(title: "Pay rent", dueDay: day(3)), TaskDraft(title: "Read a book")])
        let kinds = { model.sections(for: .now).groups.map(\.kind) }
        XCTAssertEqual(kinds(), [.day(day(3)), .noDate])
        model.dayDragLive = true
        XCTAssertEqual(kinds(), [.today, .day(tomorrow), .day(day(3)), .noDate])
        XCTAssertEqual(model.sections(for: .now).groups.first?.ids, [], "an empty header")
        XCTAssertEqual(model.sections(for: .backlog).groups.map(\.kind).contains(.today), false, "Now only")
        model.dayDragLive = false
        XCTAssertEqual(kinds(), [.day(day(3)), .noDate], "they fold away after the drag")
    }

    // MARK: - Through the page's drag

    func testDraggingARowUnderTomorrowsEmptyHeaderGivesItTomorrow() throws {
        let host = try CrossDayHost(seed: [TaskDraft(title: "Plan the week", dueDay: today),
                                           TaskDraft(title: "Answer email", dueDay: today),
                                           TaskDraft(title: "Read a book")])
        defer { host.close() }
        let moved = try XCTUnwrap(host.model.rows(for: .now).first)
        let other = try XCTUnwrap(host.model.rows(for: .now).dropFirst().first)
        let tomorrowKey = TasksPanelDesign.GroupKind.day(tomorrow).key
        var liveHeader: CGRect?, liveDuring = false, target: TasksDayDrop?, changes = 0
        try host.drag(moved.id, steps: [6, 20], then: { post in
            liveDuring = host.model.dayDragLive
            liveHeader = host.pointer.headerFrames[tomorrowKey]
            guard let header = liveHeader else { return }
            // An empty day's header is its whole drop zone.
            for offset in [CGFloat(-2), 0, 2] { post(header.midY + offset) }
        }, beforeRelease: {
            target = host.pointer.dayDrop.target
            changes = host.pointer.dayDrop.changes
        })
        XCTAssertTrue(liveDuring, "the drag is live")
        XCTAssertNotNil(liveHeader, "Tomorrow shows as an empty header mid-drag")
        XCTAssertEqual(target?.key, tomorrowKey, "Tomorrow's header is marked as the target")
        XCTAssertLessThanOrEqual(changes, 2, "the target is written only when it changes")
        XCTAssertEqual(host.store.task(withID: moved.id)?.dueDay, tomorrow, "the release gives it Tomorrow")
        XCTAssertEqual(host.store.task(withID: other.id)?.dueDay, today)
        XCTAssertFalse(host.model.dayDragLive)
        XCTAssertNil(host.pointer.dayDrop.target, "the target mark goes")
        XCTAssertTrue(host.model.sections(for: .now).groups.allSatisfy { !$0.ids.isEmpty }, "no empty header stays")
    }

    func testEscapeCancelsACrossDayDragAndTheRowGoesBack() throws {
        let host = try CrossDayHost(seed: [TaskDraft(title: "Plan the week", dueDay: today),
                                           TaskDraft(title: "Answer email", dueDay: today),
                                           TaskDraft(title: "Read a book")])
        defer { host.close() }
        let before = host.model.rows(for: .now).map(\.id)
        let moved = try XCTUnwrap(before.first)
        let tomorrowKey = TasksPanelDesign.GroupKind.day(tomorrow).key
        try host.drag(moved, steps: [6, 20], then: { post in
            guard let header = host.pointer.headerFrames[tomorrowKey] else { return }
            post(header.midY)
        }, beforeRelease: {
            TasksDragCancellation.cancel(in: host.window)
        })
        XCTAssertEqual(host.store.task(withID: moved)?.dueDay, today, "nothing changed")
        XCTAssertEqual(host.model.rows(for: .now).map(\.id), before)
        XCTAssertFalse(host.model.dayDragLive)
        XCTAssertNil(host.pointer.dayDrop.target)
    }
}

/// The Tasks page with given tasks in a window off screen, driven with
/// real mouse events (as `Hosted`, seeded by the test).
@MainActor
private final class CrossDayHost {
    let store: TaskStore
    let model: TasksPageModel
    let window: NSPanel
    let height: CGFloat = 560
    let pointer = TasksPointer()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(seed: [TaskDraft]) throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        store = TaskStore(container: container)
        _ = store.commit(seed)
        model = TasksPageModel(library: AtticLibrary(tasks: store))
        let size = CGSize(width: AtticLayout.panelSize.width, height: height)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: .constant(false), chrome: TasksPageChrome(), pointer: pointer)
        window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        spin(1)
    }

    func close() { window.close() }

    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Presses the row, moves `steps` down, then (0.3 s on) runs `then`
    /// with a way to move the pointer to a page y; releases 0.4 s later,
    /// after `beforeRelease`, where the pointer was last.
    func drag(_ id: UUID, steps: [CGFloat], then: @escaping (_ post: (CGFloat) -> Void) -> Void,
              beforeRelease: @escaping () -> Void) throws {
        let frame = try XCTUnwrap(pointer.frames[TasksRowID(tab: .now, id: id)])
        var lastY = frame.midY
        let window = window, height = height
        func post(_ type: NSEvent.EventType, y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: height - y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 9, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
            lastY = y
        }
        post(.leftMouseDown, y: frame.midY)
        for step in steps { post(.leftMouseDragged, y: frame.midY + step) }
        let action = Timer(timeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { then { post(.leftMouseDragged, y: $0) } }
        }
        let release = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated {
                beforeRelease()
                post(.leftMouseUp, y: lastY)
            }
        }
        RunLoop.main.add(action, forMode: .common)
        RunLoop.main.add(release, forMode: .common)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, release.isValid || action.isValid || pointer.liftedCard.lift != nil {
            autoreleasepool {
                Hosted.pumpEvents(limit: 1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        Hosted.pumpEvents(limit: 8)
        spin(0.4)
    }
}
