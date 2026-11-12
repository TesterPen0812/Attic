import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The Tasks page's model: what each list shows and in what order, what
/// every action does (always one undoable step), the add bar's chips and
/// shorthand, the Done log, and how rows read.
@MainActor
final class TasksPageModelTests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func titles(_ tab: TasksTab) -> [String] { model.rows(for: tab).map(\.model.title) }

    @discardableResult
    private func add(_ text: String, tab: TasksTab = .now) -> UUID? {
        model.select(tab: tab)
        model.addBar.text = text
        return model.submitAddBar()
    }

    func testDatesHuntTypedDaysTrackAnInjectedTimeZoneChangeInARetainedPage() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var tokyo = utc
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        // The same instant is Thursday in UTC and Friday in Tokyo.
        let instant = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 11, day: 12,
                                                                 hour: 23, minute: 30)))
        final class CalendarSource { var value: Calendar; init(_ value: Calendar) { self.value = value } }
        let source = CalendarSource(utc)
        let localStore = try makeTestStore(now: { instant })
        let localLibrary = AtticLibrary(tasks: localStore, now: { instant })
        let page = TasksPageModel(library: localLibrary, services: TasksPageServices(
            now: { instant }, calendar: { source.value }, locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))

        page.addBar.text = "Before today"
        let beforeID = try XCTUnwrap(page.submitAddBar())
        XCTAssertEqual(localStore.task(withID: beforeID)?.dueDay?.rawValue, "2026-11-12")

        source.value = tokyo
        XCTAssertEqual(page.dateChoices.today.rawValue, "2026-11-13")
        page.addBar.text = "After today"
        let afterID = try XCTUnwrap(page.submitAddBar())
        XCTAssertEqual(localStore.task(withID: afterID)?.dueDay?.rawValue, "2026-11-13",
                       "the typed date must use the same day as the current date card and grouping")
        page.addBar.text = "Next tomorrow"
        let tomorrowID = try XCTUnwrap(page.submitAddBar())
        XCTAssertEqual(localStore.task(withID: tomorrowID)?.dueDay?.rawValue, "2026-11-14")
    }

    func testDatesHuntTasksPublishClockCorrectionForLiveDateLabels() async throws {
        var published = 0
        model.dateEnvironmentDidPublish = { notification in
            if notification.name == .NSSystemClockDidChange { published += 1 }
        }
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(published, 1, "row groups and due labels must refresh after a manual clock change")
    }

    func testDatesHuntSeededHostedTaskDateActionsPreserveGroupingAcrossZones() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let choices: [(Int, Int, Int, Int, Int)] = [
            (2026, 3, 8, 6, 59), (2026, 3, 8, 7, 1),
            (2026, 3, 8, 9, 59), (2026, 3, 8, 10, 1),
            (2026, 3, 29, 0, 59), (2026, 3, 29, 1, 1),
            (2026, 10, 25, 0, 30), (2026, 10, 25, 1, 30),
            (2026, 11, 1, 5, 30), (2026, 11, 1, 6, 30),
            (2026, 11, 1, 8, 30), (2026, 11, 1, 9, 30),
            (2026, 12, 31, 23, 59), (2027, 1, 1, 0, 1),
            (2028, 2, 28, 23, 59), (2028, 2, 29, 0, 1)
        ]
        let instants = try choices.map { y, m, d, h, minute in
            try XCTUnwrap(utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute)))
        }
        let zones = ["Europe/London", "America/New_York", "America/Los_Angeles", "UTC", "Asia/Tokyo"]
        final class CalendarSource { var value: Calendar; init(_ value: Calendar) { self.value = value } }
        let phrases = ["Call today", "Plan tomorrow", "Meet next fri 3pm",
                       "Renew in 2 weeks", "Launch 15 nov 2026 3pm", "Leap 2028-02-29", "Invalid 31/13"]

        for seed in [UInt64(0xDA7E_A101), 0xDA7E_A102] {
            var state = seed
            func draw(_ upper: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(upper))
            }
            let clock = MutableNow(instants[0])
            let source = CalendarSource(utc)
            let localStore = try makeTestStore(now: { clock.value })
            let localLibrary = AtticLibrary(tasks: localStore, now: { clock.value })
            let page = TasksPageModel(library: localLibrary, services: TasksPageServices(
                now: { clock.value }, calendar: { source.value }, locale: Locale(identifier: "en_GB"),
                doneHold: .seconds(3_600)
            ))
            var identifiers: [UUID] = []

            for step in 0..<330 {
                let label = "seed=\(seed) step=\(step) zone=\(source.value.timeZone.identifier)"
                let before = Dictionary(uniqueKeysWithValues: identifiers.compactMap { id in
                    localStore.task(withID: id).map { (id, $0.dueDayRaw) }
                })
                let action = draw(10)
                var changedDate = false
                switch action {
                case 0: clock.value = instants[draw(instants.count)]
                case 1: source.value.timeZone = try XCTUnwrap(TimeZone(identifier: zones[draw(zones.count)]))
                case 2 where identifiers.count < 35:
                    let text = phrases[draw(phrases.count)]
                    let expected = TaskTextParser(calendar: source.value, locale: Locale(identifier: "en_GB"),
                                                  now: { clock.value }).parse(text).dueDay
                    page.select(tab: .now)
                    page.addBar.text = text
                    let id = try XCTUnwrap(page.submitAddBar(), label)
                    identifiers.append(id)
                    XCTAssertEqual(localStore.task(withID: id)?.dueDay, expected, "typed day: \(label)")
                case 3 where !identifiers.isEmpty:
                    let id = identifiers[draw(identifiers.count)]
                    let date = page.parser.parseDueDay("tomorrow")
                    XCTAssertTrue(page.setDueDay(date, for: [id]).isApplied, label)
                    XCTAssertEqual(localStore.task(withID: id)?.dueDay, date, label)
                    changedDate = true
                case 4 where !identifiers.isEmpty:
                    let id = identifiers[draw(identifiers.count)]
                    XCTAssertTrue(page.setDueDay(nil, for: [id]).isApplied, label)
                    XCTAssertNil(localStore.task(withID: id)?.dueDay, label)
                    changedDate = true
                case 5 where !identifiers.isEmpty:
                    XCTAssertTrue(page.moveToBacklog([identifiers[draw(identifiers.count)]]).isApplied, label)
                case 6 where !identifiers.isEmpty:
                    XCTAssertTrue(page.moveToNow([identifiers[draw(identifiers.count)]]).isApplied, label)
                case 7:
                    var options = page.viewOptions(for: .now)
                    options.show = [.all, .dueOrOverdue, .overdueOnly][draw(3)]
                    page.setViewOptions(options, for: .now)
                case 8:
                    var options = page.viewOptions(for: .now)
                    options.sort = [.manual, .dueDate, .priority][draw(3)]
                    page.setViewOptions(options, for: .now)
                default: page.select(tab: draw(2) == 0 ? .now : .backlog)
                }

                if !changedDate { // Clock, zone, display, order and placement never rewrite a due day.
                    for (id, raw) in before {
                        XCTAssertEqual(localStore.task(withID: id)?.dueDayRaw, raw, label)
                    }
                }
                let today = DueDay(date: clock.value, calendar: source.value)
                XCTAssertEqual(page.dateChoices.today, today, label)
                let all = identifiers.compactMap(localStore.task(withID:))
                let nowTasks = all.filter { $0.listedStatus != .backlog }
                let backlogTasks = all.filter { $0.listedStatus == .backlog }
                let view = page.viewOptions(for: .now)
                let expectedNow = Set(nowTasks.filter { view.includes($0, today: today) }.map(\.id))
                XCTAssertEqual(Set(page.rows(for: .now).map(\.id)), expectedNow, label)
                XCTAssertEqual(Set(page.rows(for: .backlog).map(\.id)), Set(backlogTasks.map(\.id)), label)
                let grouping = page.sections(for: .now).groups
                for task in nowTasks where expectedNow.contains(task.id) {
                    let expectedKind: TasksPanelDesign.GroupKind = task.dueDay.map { date in
                        if date < today { return .overdue }
                        if date == today { return .today }
                        return .day(date)
                    } ?? .noDate
                    XCTAssertEqual(grouping.first(where: { $0.ids.contains(task.id) })?.kind, expectedKind, label)
                }
            }
            print("DATES_HUNT_HOSTED_TASKS seed=\(seed) steps=330")
        }
    }

    func testAR08TabAndShiftTabPreserveExtendedSelectionButReturnUsesNewFocus() throws {
        let a = try XCTUnwrap(add("A")), b = try XCTUnwrap(add("B")), c = try XCTUnwrap(add("C"))
        let visible = [a, b, c]
        model.selectOnly(a)
        model.extendSelection(to: b, visible: visible)
        XCTAssertEqual(model.selection, [a, b])
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: c), keyboardDriving: true)
        XCTAssertEqual(model.selection, [a, b], "Tab preserves the extended selection")
        XCTAssertEqual(model.keyboardRow(focused: c, visible: visible), c, "the later key uses the visible focus")
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: b), keyboardDriving: true)
        XCTAssertEqual(model.selection, [a, b], "Shift-Tab preserves it too")
        XCTAssertEqual(model.keyboardRow(focused: b, visible: visible), b)
        model.selectOnly(a)
        XCTAssertEqual(model.keyboardRow(focused: b, visible: visible), a, "a later menu selection supersedes old focus")
    }

    // MARK: - Lists

    func testE02ListSnapshotReusesRowIDsStatusGroupsAndSelectionRuns() throws {
        let a = try XCTUnwrap(add("A")), b = try XCTUnwrap(add("B")), c = try XCTUnwrap(add("C"))
        let initial = model.listSnapshot(for: .now)
        XCTAssertEqual(Set(initial.ids), Set([a, b, c]))
        XCTAssertEqual(initial.idsByStatus[.todo], initial.ids)
        XCTAssertEqual(initial.selectionRuns.count, 0)
        #if DEBUG
        let firstBuilds = model.selectionRunRebuildCount
        #endif
        for _ in 0..<10 { _ = model.listSnapshot(for: .now) }
        #if DEBUG
        XCTAssertEqual(model.selectionRunRebuildCount, firstBuilds, "unchanged evaluations reuse the selection runs")
        #endif

        model.selectCopies(Array(initial.ids.prefix(2)))
        let selected = model.listSnapshot(for: .now)
        XCTAssertEqual(selected.selectionRuns[initial.ids[0]], .first)
        XCTAssertEqual(selected.selectionRuns[initial.ids[1]], .last)
        #if DEBUG
        XCTAssertEqual(model.selectionRunRebuildCount, firstBuilds + 1)
        #endif

        model.toggleExpanded(initial.ids[0])
        let expanded = model.listSnapshot(for: .now)
        XCTAssertEqual(expanded.selectionRuns[initial.ids[0]], .single)
        XCTAssertEqual(expanded.selectionRuns[initial.ids[1]], .single)
        #if DEBUG
        XCTAssertEqual(model.selectionRunRebuildCount, firstBuilds + 2)
        #endif

        let added = try XCTUnwrap(add("D"))
        let changed = model.listSnapshot(for: .now)
        XCTAssertTrue(changed.ids.contains(added))
        XCTAssertEqual(changed.idsByStatus[.todo], changed.ids)
        XCTAssertEqual(model.eligibleRowIDs(for: .now), Set(changed.ids))
    }

    func testE02MeasureUnchangedListEvaluations() throws {
        for number in 0..<100 { _ = try XCTUnwrap(add("Item \(number)")) }
        let ids = model.listSnapshot(for: .now).ids
        model.selectCopies(Array(ids.prefix(20)))
        _ = model.listSnapshot(for: .now)
        func ms(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let count = 500
        let previous = ms {
            for _ in 0..<count {
                let rows = model.rows(for: .now)
                _ = TasksSelectionRuns.make(ids: rows.map(\.id), selected: model.selection, expanded: model.expanded)
                _ = Dictionary(grouping: rows, by: \.status).mapValues { $0.map(\.id) }
            }
        }
        let cached = ms {
            for _ in 0..<count { _ = model.listSnapshot(for: .now) }
        }
        print("E02_SNAPSHOT rows=\(ids.count) evaluations=\(count) old_derived_ms=\(previous) new_cached_ms=\(cached)")
    }

    func testNowIsInProgressThenToDoThenDoneAndBacklogIsItsOwnList() throws {
        let a = try XCTUnwrap(add("A"))
        _ = try XCTUnwrap(add("B"))
        let c = try XCTUnwrap(add("C"))
        _ = try XCTUnwrap(add("Idea", tab: .backlog))
        model.select(tab: .now)
        model.toggleWorking([a])    // to do → in progress (⇧Space, the menu)
        model.toggleDone(c)         // done (held in place for now)
        XCTAssertEqual(titles(.now), ["A", "C", "B"], "a finished row holds its place")
        XCTAssertEqual(model.completedTodayCount, 0, "it joins Completed today once it moves")
        model.releaseHold(c)
        // The owner's panel design (2026-10-27): a finished task leaves Now
        // once its hold ends and lives in Done; Now has no Completed today.
        XCTAssertEqual(titles(.now), ["A", "B"], "done rows leave Now")
        XCTAssertTrue(model.sections(for: .now).done.isEmpty)
        XCTAssertEqual(model.completedTodayCount, 0)
        model.toggleCompletedToday()
        XCTAssertEqual(titles(.now), ["A", "B"], "nothing to open")
        XCTAssertEqual(model.rows(for: .now).map(\.model.state), [.inProgress, .todo])
        model.resetForReveal()
        XCTAssertTrue(model.completedTodayExpanded, "Completed today stays open for the session")
        XCTAssertEqual(titles(.backlog), ["Idea"])
        XCTAssertEqual(model.nowCount, 2)
        XCTAssertEqual(model.backlogCount, 1)
        XCTAssertTrue(model.hasDoneToday)
    }

    func testH12CompletionHoldReleaseClearsInvisibleSelectionAndKeyboardFocus() throws {
        let id = try XCTUnwrap(add("Finish the selected row"))
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: true)

        XCTAssertTrue(model.toggleDone(id).isApplied)
        XCTAssertEqual(model.selection, [id], "the row remains selectable during its completion hold")
        model.releaseHold(id)

        XCTAssertFalse(model.rows(for: .now).contains { $0.id == id })
        XCTAssertTrue(model.selection.isEmpty, "a finished row must not remain selected after it leaves Now")
        XCTAssertNil(model.keyboardFocus, "keyboard focus must not refer to the departed row")
        XCTAssertTrue(model.doneDays().flatMap(\.rows).contains { $0.id == id })
    }

    func testH12FoldingSelectedDateGroupClearsInvisibleSelectionAndFocus() throws {
        let id = try XCTUnwrap(add("Dated selected row"))
        let day = try XCTUnwrap(DueDay(year: 2026, month: 9, day: 24))
        XCTAssertTrue(model.setDueDay(day, for: [id]).isApplied)
        let key = try XCTUnwrap(model.groupKey(of: id, on: .now))
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: true)

        model.foldAllGroups([key], folded: true, on: .now)

        XCTAssertFalse(model.rows(for: .now).contains { $0.id == id })
        XCTAssertTrue(model.selection.isEmpty, "folding a date group must not leave invisible selection")
        XCTAssertNil(model.keyboardFocus, "folded rows must no longer hold keyboard focus")
        model.foldAllGroups([key], folded: false, on: .now)
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == id })
    }

    func testH12UndoingCompletionFromDoneReleasesDepartedSelectionAndFocus() throws {
        let id = try XCTUnwrap(add("Restore me through Undo"))
        XCTAssertTrue(model.toggleDone(id).isApplied)
        model.releaseHold(id)
        model.select(tab: .done)
        XCTAssertTrue(model.doneDays().flatMap(\.rows).contains { $0.id == id })
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.done.rawValue, id: id), keyboardDriving: true)

        XCTAssertTrue(model.undo().isApplied)
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == id })
        XCTAssertTrue(model.doneDays().flatMap(\.rows).allSatisfy { $0.id != id })
        XCTAssertTrue(model.selection.isEmpty, "Undo must not leave selection on a departed Done row")
        XCTAssertNil(model.keyboardFocus, "Undo must release focus on a row now shown on another tab")
    }

    func testH12ViewFilterEvictsFocusWithTheHiddenRow() throws {
        let id = try XCTUnwrap(add("No due date"))
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: true)

        model.setViewOptions(TasksViewOptions(show: .dueOrOverdue), for: .now)

        XCTAssertTrue(model.rows(for: .now).isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.keyboardFocus, "filtering the row out must not leave keyboard focus on it")
    }

    func testH12TagFilterEvictsFocusWithTheHiddenRow() throws {
        let id = try XCTUnwrap(add("Untagged row"))
        let taggedID = try XCTUnwrap(add("Tagged row"))
        XCTAssertTrue(model.toggleTag("h12-filter", for: [taggedID]).isApplied)
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: true)

        model.chooseTagChip("h12-filter")

        XCTAssertEqual(model.rows(for: .now).map(\.id), [taggedID])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.keyboardFocus, "tagging away the focused row must release its keyboard focus")
    }

    func testH12RemovingSelectedTasksTagWhileFilteringReleasesItsFocus() throws {
        let departing = try XCTUnwrap(add("Remove tag"))
        let staying = try XCTUnwrap(add("Keep tag"))
        XCTAssertTrue(model.toggleTag("h12-tag-mutate", for: [departing, staying]).isApplied)
        model.chooseTagChip("h12-tag-mutate")
        model.selectOnly(departing)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: departing), keyboardDriving: true)

        XCTAssertTrue(model.toggleTag("h12-tag-mutate", for: [departing]).isApplied)

        XCTAssertEqual(model.rows(for: .now).map(\.id), [staying])
        XCTAssertTrue(model.selection.isEmpty, "tag editing removed the row from the active filter")
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12ChangingPriorityOfSelectedRowOutsideViewFilterReleasesFocus() throws {
        let departing = try XCTUnwrap(add("Lower priority"))
        let staying = try XCTUnwrap(add("High priority"))
        XCTAssertTrue(model.setPriority(.high, for: [departing, staying]).isApplied)
        model.setViewOptions(TasksViewOptions(priority: .highOnly), for: .now)
        model.selectOnly(departing)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: departing), keyboardDriving: true)

        XCTAssertTrue(model.setPriority(.none, for: [departing]).isApplied)

        XCTAssertEqual(model.rows(for: .now).map(\.id), [staying])
        XCTAssertTrue(model.selection.isEmpty, "editing priority removed the row from the active view")
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12ChangingSelectedTasksDateIntoFoldedGroupReleasesFocus() throws {
        let departing = try XCTUnwrap(add("Move into closed day"))
        let staying = try XCTUnwrap(add("Closed day owner"))
        let destination = DueDay(year: 2026, month: 9, day: 23)
        XCTAssertTrue(model.setDueDay(DueDay(year: 2026, month: 9, day: 22), for: [departing]).isApplied)
        XCTAssertTrue(model.setDueDay(destination, for: [staying]).isApplied)
        let key = try XCTUnwrap(model.groupKey(of: staying, on: .now))
        model.foldAllGroups([key], folded: true, on: .now)
        model.selectOnly(departing)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: departing), keyboardDriving: true)

        XCTAssertTrue(model.setDueDay(destination, for: [departing]).isApplied)

        XCTAssertFalse(model.rows(for: .now).contains { $0.id == departing })
        XCTAssertTrue(model.selection.isEmpty, "date card moved the selected task into a closed group")
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12DroppingSelectedTaskIntoFoldedDateReleasesFocus() throws {
        let departing = try XCTUnwrap(add("Drop into closed day"))
        let staying = try XCTUnwrap(add("Existing closed day"))
        let destination = try XCTUnwrap(DueDay(year: 2026, month: 9, day: 24))
        XCTAssertTrue(model.setDueDay(destination, for: [staying]).isApplied)
        let key = try XCTUnwrap(model.groupKey(of: staying, on: .now))
        model.foldAllGroups([key], folded: true, on: .now)
        model.selectOnly(departing)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: departing), keyboardDriving: true)

        let drop = TasksDayDrop(key: key, change: .day(destination), index: 0,
                                before: nil, after: nil, lineY: 0)
        XCTAssertTrue(model.moveToDay(departing, drop).isApplied)

        XCTAssertFalse(model.rows(for: .now).contains { $0.id == departing })
        XCTAssertTrue(model.selection.isEmpty, "cross-day drag left the focused row in a folded group")
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12BatchCompletionMovesAllSelectedRowsToDoneWithoutHiddenFocus() throws {
        let first = try XCTUnwrap(add("Batch one"))
        let second = try XCTUnwrap(add("Batch two"))
        model.selectCopies([first, second])
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: first), keyboardDriving: true)

        XCTAssertTrue(model.toggleDone([first, second]).isApplied)

        XCTAssertEqual(model.rows(for: .now).count, 0)
        XCTAssertEqual(Set(model.doneDays().flatMap { $0.rows.map(\.id) }), [first, second])
        XCTAssertTrue(model.selection.isEmpty, "multi-select completion has no hold and rows leave Now at once")
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12StatusMenuBatchCompletionEvictsHiddenFocus() throws {
        let first = try XCTUnwrap(add("Status one"))
        let second = try XCTUnwrap(add("Status two"))
        model.selectCopies([first, second])
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: first), keyboardDriving: true)

        XCTAssertTrue(model.setStatus(.done, for: [first, second]).isApplied)

        XCTAssertTrue(model.rows(for: .now).isEmpty)
        XCTAssertEqual(Set(model.doneDays().flatMap { $0.rows.map(\.id) }), [first, second])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.keyboardFocus)
    }

    func testH12BatchReopeningArchivedDoneTasksRemovesStaleDoneRowsAndFocus() throws {
        let first = try XCTUnwrap(add("Archived one"))
        let second = try XCTUnwrap(add("Archived two"))
        XCTAssertTrue(model.complete(first).isApplied)
        XCTAssertTrue(model.complete(second).isApplied)
        model.releaseHold(first)
        model.releaseHold(second)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), 2)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(Set(model.doneDays().flatMap { $0.rows.map(\.id) }), [first, second])
        model.selectCopies([first, second])
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.done.rawValue, id: first), keyboardDriving: true)

        XCTAssertTrue(model.toggleDone([first, second]).isApplied)

        XCTAssertEqual(Set(model.rows(for: .now).map(\.id)), [first, second])
        XCTAssertTrue(model.doneDays().flatMap(\.rows).isEmpty, "restored rows must leave the loaded Done log immediately")
        XCTAssertTrue(model.selection.isEmpty, "both restored rows left the Done page")
        XCTAssertNil(model.keyboardFocus)
        XCTAssertTrue([first, second].allSatisfy { store.task(withID: $0)?.status == .todo })
    }

    func testH12UndoRedoOfArchivedReopenRefreshesLoadedDoneDays() throws {
        let id = try XCTUnwrap(add("Archived undo round trip"))
        XCTAssertTrue(model.complete(id).isApplied)
        model.releaseHold(id)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), 1)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap { $0.rows.map(\.id) }, [id])

        XCTAssertTrue(model.reopen(id).isApplied)
        XCTAssertTrue(model.doneDays().flatMap(\.rows).isEmpty)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(store.task(withID: id), "Undo restored the archived physical state")
        XCTAssertEqual(model.doneDays().flatMap { $0.rows.map(\.id) }, [id],
                       "the loaded Done page must reflect Undo without reopening the page")

        XCTAssertTrue(model.redo().isApplied)
        XCTAssertEqual(model.rows(for: .now).map(\.id), [id])
        XCTAssertTrue(model.doneDays().flatMap(\.rows).isEmpty)
    }

    func testH12RestoreToNowReleasesDepartedDoneKeyboardFocus() throws {
        let id = try XCTUnwrap(add("Restore focused Done row"))
        XCTAssertTrue(model.complete(id).isApplied)
        model.releaseHold(id)
        model.select(tab: .done)
        model.selectOnly(id)
        model.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.done.rawValue, id: id), keyboardDriving: true)

        XCTAssertTrue(model.restoreToNow([id]).isApplied)

        XCTAssertEqual(model.rows(for: .now).map(\.id), [id])
        XCTAssertTrue(model.doneDays().flatMap(\.rows).isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.keyboardFocus, "the restored row is no longer on the focused Done page")
    }

    func testH12RenamingSelectedTaskOutOfFindResultsPrunesSelection() throws {
        let id = try XCTUnwrap(add("Needle in list"))
        model.setSearchQuery("needle", for: .now)
        model.selectOnly(id)
        model.beginEditingTitle(id)
        model.editingTitle = "Unmatched title"

        XCTAssertTrue(model.commitTitle())

        XCTAssertTrue(model.rows(for: .now).isEmpty)
        XCTAssertTrue(model.selection.isEmpty, "committing the title removed the selected row from Find")
    }

    /// The model's side of the circle (Direction A: one click completes,
    /// another puts the task back as it was; ⇧Space starts and stops).
    func testTheCircleCompletesInOneClickAndRestoresThePreviousState() throws {
        let id = try XCTUnwrap(add("Task"))
        _ = try XCTUnwrap(add("Other"))
        XCTAssertEqual(titles(.now), ["Other", "Task"])
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .done, "one click completes")
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .todo, "a second click puts it back")
        XCTAssertEqual(titles(.now), ["Other", "Task"], "right after finishing, it keeps its place")

        model.toggleWorking([id])
        XCTAssertEqual(store.task(withID: id)?.status, .inProgress)
        model.toggleWorking([id])
        XCTAssertEqual(store.task(withID: id)?.status, .todo, "⇧Space again stops working")
        model.toggleWorking([id])
        model.toggleDone(id)
        model.releaseHold(id)
        _ = try XCTUnwrap(add("Later step"))   // the completion is no longer the latest step
        model.toggleDone(id)
        XCTAssertEqual(store.task(withID: id)?.status, .inProgress, "a finished task goes back to what it was")

        let idea = try XCTUnwrap(add("Idea", tab: .backlog))
        model.toggleDone(idea)
        XCTAssertEqual(store.task(withID: idea)?.status, .done, "Later's circle completes too")
        XCTAssertEqual(titles(.backlog), ["Idea"], "and the row holds its place on Later")
        model.releaseHold(idea)
        XCTAssertEqual(titles(.backlog), [])
        model.select(tab: .now)
        model.toggleDone(idea)
        XCTAssertEqual(store.task(withID: idea)?.status, .backlog, "back to Later, where it was")
    }

    /// The right-click menu on several tasks: all done, then all back.
    func testCompletingSeveralTasksFromTheMenu() throws {
        let a = try XCTUnwrap(add("A"))
        let b = try XCTUnwrap(add("B"))
        model.toggleWorking([a])
        model.toggleDone([a, b])
        XCTAssertEqual(store.task(withID: a)?.status, .done)
        XCTAssertEqual(store.task(withID: b)?.status, .done)
        model.toggleDone([a, b])
        XCTAssertEqual(store.task(withID: a)?.status, .inProgress)
        XCTAssertEqual(store.task(withID: b)?.status, .todo)
    }

    /// Direction A's empty states: Now says why it is empty; Later has its own.
    func testEmptyListsSayWhyTheyAreEmpty() throws {
        XCTAssertEqual(model.emptyMessage[.now], "Add your first task.")
        XCTAssertEqual(model.emptyMessage[.backlog], "Nothing in Backlog.")
        _ = try XCTUnwrap(add("Idea", tab: .backlog))
        XCTAssertEqual(model.emptyMessage[.now], "Nothing active.")
        XCTAssertTrue(model.offersLater, "with \"Choose from Backlog\" under it")
        let done = try XCTUnwrap(add("Water plants"))
        model.complete(done)
        XCTAssertEqual(model.emptyMessage[.now], "You’re caught up.")
    }

    func testMovesAndDeletesShowAnUndoToastAndUndoPutsThemBack() throws {
        let a = try XCTUnwrap(add("A"))
        let b = try XCTUnwrap(add("B"))
        model.moveToBacklog([a])
        XCTAssertEqual(model.toasts.current?.message, "Moved to Backlog")
        XCTAssertEqual(titles(.backlog), ["A"])
        model.undo()
        XCTAssertNil(model.toasts.current)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)

        model.click(a, modifiers: [], visible: [b, a])
        model.click(b, modifiers: .command, visible: [b, a])
        XCTAssertEqual(model.selection, [a, b])
        XCTAssertEqual(Set(model.targets(for: a)), [a, b])
        model.delete(model.targets(for: a))
        // 2026-10-23 whole-item decision: the count leads the Delete toast.
        XCTAssertEqual(model.toasts.current?.message, "2 tasks deleted")
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        model.undo()
        XCTAssertEqual(Set(store.tasks.map(\.id)), [a, b])
    }

    func testClickSelectionTogglesAndExtends() throws {
        let ids = (0..<4).map { _ in UUID() }
        model.click(ids[1], modifiers: [], visible: ids)
        model.click(ids[3], modifiers: .shift, visible: ids)
        XCTAssertEqual(model.selection, Set(ids[1...3]))
        model.click(ids[2], modifiers: .command, visible: ids)
        XCTAssertEqual(model.selection, [ids[1], ids[3]])
        model.click(ids[0], modifiers: [], visible: ids)
        XCTAssertEqual(model.selection, [ids[0]])
    }

    /// ⌘↑ ⌘↓ and the drop a drag ends in (the drag gesture itself is driven
    /// in `TasksPageUITests`).
    func testReorderMovesAreOneUndoableStepEach() throws {
        let a = try XCTUnwrap(add("A"))
        _ = try XCTUnwrap(add("B"))
        _ = try XCTUnwrap(add("C"))
        XCTAssertEqual(titles(.now), ["C", "B", "A"])
        model.moveBy(a, offset: -1)
        XCTAssertEqual(titles(.now), ["C", "A", "B"])
        model.move(a, toGroupIndex: 0)
        XCTAssertEqual(titles(.now), ["A", "C", "B"])
        model.undo()
        XCTAssertEqual(titles(.now), ["C", "A", "B"])
    }

    func testTitleEditingAndSubtasksInTheQuickLook() throws {
        let id = try XCTUnwrap(add("Plan trip"))
        model.beginEditingTitle(id)
        XCTAssertEqual(model.editingTitle, "Plan trip")
        model.editingTitle = "Plan the trip"
        model.commitTitle()
        XCTAssertEqual(store.task(withID: id)?.title, "Plan the trip")
        XCTAssertNil(model.editingTitleID)

        model.beginAddingSubtask(to: id)
        XCTAssertTrue(model.expanded.contains(id))
        model.newSubtaskTitle = "Book flights #travel"
        model.commitNewSubtask()
        XCTAssertEqual(model.newSubtaskParentID, id, "the field stays for the next subtask")
        XCTAssertEqual(model.newSubtaskTitle, "")
        let subtask = try XCTUnwrap(store.subtasks(of: id).first)
        XCTAssertEqual(subtask.title, "Book flights")
        XCTAssertEqual(subtask.tags, ["travel"])
        XCTAssertEqual(model.rows(for: .now).first?.subtasks.map(\.title), ["Book flights"])
        XCTAssertEqual(model.rows(for: .now).first?.model.subtasks?.total, 1)

        model.toggleSubtask(subtask.id)
        XCTAssertEqual(store.task(withID: subtask.id)?.status, .done)
        model.complete(id)
        XCTAssertEqual(store.task(withID: id)?.status, .done)
        model.toggleExpanded(id)
        XCTAssertFalse(model.expanded.contains(id))
    }

    // MARK: - Add bar

    func testTheAddBarUnderstandsShorthandAndFollowsThePage() throws {
        let id = try XCTUnwrap(add("Call mom fri #family !!"))
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Call mom")
        XCTAssertEqual(task.tags, ["family"])
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.dueDay, DueDay(year: 2026, month: 9, day: 25))
        XCTAssertEqual(model.addBar.text, "", "the bar clears and keeps focus for the next one")
        XCTAssertEqual(model.addPlaceholder, "Add a task")

        let idea = try XCTUnwrap(add("Paint the fence", tab: .backlog))
        XCTAssertEqual(store.task(withID: idea)?.status, .backlog)
        XCTAssertEqual(model.addPlaceholder, "Add to Backlog")
        XCTAssertNil(add("   "), "blank text adds nothing")

        model.select(tab: .now)
        model.addBar.text = "Ship it"
        let opened = try XCTUnwrap(model.submitAddBar(openingPage: true))
        XCTAssertEqual(store.task(withID: opened)?.title, "Ship it", "⌘Return adds the task (its files list is gone)")

        // On Done the bar still adds, to Now, and says so.
        model.select(tab: .done)
        XCTAssertEqual(model.addPlaceholder, "Add a task")
        model.addBar.text = "From Done"
        let fromDone = try XCTUnwrap(model.submitAddBar())
        XCTAssertEqual(store.task(withID: fromDone)?.status, .todo)
        XCTAssertEqual(model.toasts.current?.message, "Added to Now")
    }

    func testAlternateSubmissionRevealsItsOwningTabAndClearsOnlyItsNarrowingView() throws {
        for source in [TasksTab.done, .now, .backlog] {
            let target: TasksTab = source == .backlog ? .backlog : .now
            model.setSearchQuery("Keep this Done query", for: .done)
            var options = model.viewOptions(for: target)
            options.priority = .highOnly
            model.setViewOptions(options, for: target)
            model.setSearchQuery("Hides the new task", for: target)
            model.select(tab: source)
            model.addBar.text = "Alternate submission"
            let id = try XCTUnwrap(model.submitAddBar(openingPage: true))
            XCTAssertEqual(store.task(withID: id)?.status, source == .backlog ? .backlog : .todo)
            XCTAssertEqual(model.tab, target)
            XCTAssertTrue(model.rows(for: target).contains { $0.id == id }, "the new task is visible")
            XCTAssertEqual(model.scrollRequest?.id, id)
            XCTAssertEqual(model.scrollRequest?.tab, target)
            XCTAssertNil(model.toasts.current, "successful reveal needs no out-of-view toast")
            XCTAssertEqual(model.searchQuery(for: .done), "Keep this Done query", "navigation preserves the other tab's query")
        }
    }

    func testChipsFormOnceAWordIsFinishedAndBackspaceTurnsOneBackIntoText() throws {
        var bar = TaskAddBarText(text: "Call fri #home")
        let parser = model.parser
        let fri = NSRange(location: 5, length: 3)
        let home = NSRange(location: 9, length: 5)
        XCTAssertEqual(bar.chips(parser: parser, caret: 14), [fri], "the tag being typed is not a chip yet")
        XCTAssertEqual(bar.chips(parser: parser, caret: nil), [fri, home])
        bar.dismiss(fri)
        XCTAssertEqual(bar.chips(parser: parser, caret: nil), [home])
        let draft = try XCTUnwrap(bar.draft(parser: parser, status: .todo))
        XCTAssertEqual(draft.title, "Call fri", "a dismissed piece stays as text")
        XCTAssertNil(draft.dueDay)
        XCTAssertEqual(draft.tags, ["home"])

        // Typing before it moves it; typing a space after it keeps it; typing
        // straight on from its end joins the word and forgets it.
        bar.text = "Now call fri #home"
        bar.edited(NSRange(location: 0, length: 0), replacement: "Now ")
        XCTAssertEqual(bar.dismissed, [NSRange(location: 9, length: 3)])
        bar.edited(NSRange(location: 12, length: 0), replacement: " ")
        XCTAssertEqual(bar.dismissed, [NSRange(location: 9, length: 3)])
        bar.edited(NSRange(location: 12, length: 0), replacement: "day")
        XCTAssertTrue(bar.dismissed.isEmpty)

        XCTAssertEqual(TaskAddBarText(text: "#home").draft(parser: parser, status: .todo)?.title, "#home",
                       "a line that is only pieces keeps its text")
        XCTAssertEqual(TaskAddBarText(text: "Call mom!").draft(parser: parser, status: .todo)?.priority, TaskPriority.none,
                       "a ! inside a word stays text")
    }

    func testPastedLinesOfferManyTasksOrOne() throws {
        XCTAssertNil(TaskPasteOffer("one line"))
        let offer = try XCTUnwrap(TaskPasteOffer("- Milk\n- Eggs #shop\n\n- Bread"))
        XCTAssertEqual(offer.lineCount, 3)
        model.pasteOffer = offer
        model.acceptPaste(asOne: false)
        XCTAssertNil(model.pasteOffer)
        XCTAssertEqual(titles(.now), ["Milk", "Eggs", "Bread"])
        XCTAssertEqual(store.tasks.first { $0.title == "Eggs" }?.tags, ["shop"])
        model.undo()
        XCTAssertTrue(store.tasks.isEmpty, "the batch is one step")
        model.pasteOffer = offer
        model.acceptPaste(asOne: true)
        XCTAssertEqual(titles(.now), ["Milk Eggs Bread"])
    }

    // MARK: - Done log

    func testTheDoneLogGroupsByDaySearchesAndRestoresToNow() throws {
        let old = try XCTUnwrap(add("Invoice"))
        model.complete(old)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)   // Wed 23 Sep
        XCTAssertEqual(store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value)), 1)
        let today = try XCTUnwrap(add("Water plants"))
        model.complete(today)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let days = model.doneDays()
        // The owner's panel design: today's header is its date ("Wed 23 Sep").
        XCTAssertTrue(days.first?.title.hasPrefix("Wed 23 Sep") == true, days.first?.title ?? "")
        XCTAssertTrue(days.last?.title.hasPrefix("Mon 21 Sep") == true, days.last?.title ?? "")
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map { $0.rows.map(\.model.title) }, [["Water plants"], ["Invoice"]])

        model.doneSearch = "voice"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap { $0.rows.map(\.model.title) }, ["Invoice"])

        model.restoreToNow(old)
        XCTAssertEqual(model.toasts.current?.message, "Restored to Now")
        XCTAssertEqual(store.task(withID: old)?.status, .todo)
        XCTAssertTrue(model.doneDays().isEmpty)
        model.undo()
        XCTAssertNil(store.task(withID: old), "undo returns it to the Done log")
    }

    // MARK: - How rows read

    func testSharedDateTemplatesKeepDistinctLocaleAndTimeZoneCacheEntries() {
        let instant = Date(timeIntervalSince1970: 1_798_766_100)
        for zone in ["UTC", "Pacific/Auckland", "America/Los_Angeles"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for language in ["en_GB", "fr_FR", "ja_JP"] {
                let locale = Locale(identifier: language)
                for template in ["jmm", "EEEEdMMM", "LLLL"] {
                    let expected = DateFormatter()
                    expected.calendar = calendar
                    expected.timeZone = calendar.timeZone
                    expected.locale = locale
                    expected.setLocalizedDateFormatFromTemplate(template)
                    let label = "\(zone) / \(language) / \(template)"
                    XCTAssertEqual(AtticDateFormatting.template(instant, template: template, calendar: calendar, locale: locale),
                                   expected.string(from: instant), label)
                    // Repeat in another access order to exercise the shared cache.
                    XCTAssertEqual(AtticDateFormatting.template(instant, template: template, calendar: calendar, locale: locale),
                                   expected.string(from: instant), label)
                }
            }
        }
    }

    func testDueDatesReadAsTheSpecSays() {
        let today = DueDay(year: 2026, month: 9, day: 21)!
        let locale = Locale(identifier: "en_GB")
        func due(_ day: Int, month: Int = 9, year: Int = 2026) -> AtticTaskRowModel.Due {
            TaskRowPresentation.due(DueDay(year: year, month: month, day: day)!, today: today, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(due(21).text, "Today")
        XCTAssertEqual(due(21).tone, .today, "today reads in the body colour, not red")
        XCTAssertEqual(due(20).text, "Yesterday")
        XCTAssertEqual(due(20).tone, .overdue)
        XCTAssertTrue(due(14).text.hasPrefix("14 Sep"), due(14).text)
        XCTAssertEqual(due(14).tone, .overdue, "only overdue is red")
        XCTAssertEqual(due(22).text, "Tomorrow")
        XCTAssertEqual(due(22).tone, .quiet)
        XCTAssertEqual(due(25).text, "Fri")
        XCTAssertEqual(due(27).text, "Sun")
        XCTAssertTrue(due(28).text.hasPrefix("28 Sep"), "a week or more away is a short date")
        XCTAssertEqual(due(5, month: 1, year: 2027).text, "5 Jan 2027")
    }

    func testKeyboardFocusRingsShowOnlyWhileTheKeyboardDrives() {
        let tracker = AtticKeyboardFocusTracker()
        tracker.observe(.keyDown, keyCode: 0) // typing "a"
        XCTAssertFalse(tracker.isKeyboardDriving, "typing is not navigating")
        tracker.observe(.keyDown, keyCode: 48) // Tab
        XCTAssertTrue(tracker.isKeyboardDriving)
        tracker.observe(.leftMouseDown, keyCode: nil)
        XCTAssertFalse(tracker.isKeyboardDriving, "a click hides the rings")
        tracker.observe(.keyDown, keyCode: 125) // ↓
        XCTAssertTrue(tracker.isKeyboardDriving)
    }

    func testThePanelKeepsOnePageModelOverTheAppsCommandLayer() {
        let state = TasksPageState()
        let toasts = PanelToastCenter()
        let first = state.model(for: store, toasts: toasts)
        XCTAssertTrue(first.library === library, "the page records its steps in the app's undo history")
        XCTAssertTrue(state.model(for: store, toasts: toasts) === first, "the page's state survives page switches")
        XCTAssertTrue(first.toasts === toasts, "the page posts to the shell's one toast host")
    }

    /// One Undo toast: the page posts to the shell's host, whose button
    /// undoes the step; ⌘Z (the page's undo) takes the page's own toast
    /// away but never another page's.
    func testThePagesUndoToastIsTheShellsToast() throws {
        let toasts = PanelToastCenter()
        let page = TasksPageModel(library: library, toasts: toasts)
        let a = try XCTUnwrap(add("A"))
        page.moveToBacklog([a])
        XCTAssertEqual(toasts.current?.message, "Moved to Backlog")
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")
        toasts.performAction()
        XCTAssertNil(toasts.current)
        XCTAssertEqual(store.task(withID: a)?.status, .todo, "the toast's Undo puts the task back")

        toasts.show("Note deleted") {}
        page.undo()
        XCTAssertEqual(toasts.current?.message, "Note deleted", "⌘Z on Tasks leaves another page's toast")
    }

    func testTabsResetToNowWhenThePageOpens() {
        model.select(tab: .done)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)
    }

    /// Search (the menu-bar item) opens the Done page's search field (the
    /// add bar keeps adding); the reveal that follows keeps it there until
    /// the panel hides, and the next reveal opens on Now again.
    func testSearchOpensTheDonePageUntilThePanelHides() {
        model.beginSearch()
        XCTAssertEqual(model.tab, .done)
        XCTAssertTrue(model.pendingSearchFocus, "the keyboard goes to the search field")
        XCTAssertEqual(model.searchPlaceholder, "Search done tasks")
        XCTAssertEqual(model.addPlaceholder, "Add a task")
        model.resetForReveal()
        XCTAssertEqual(model.tab, .done, "the reveal that Search caused keeps the search")
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)

        model.beginSearch()
        model.select(tab: .backlog)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now, "moving away ends the search")
    }

    /// An agent's `show` of a task: the tab that lists it, the row alone
    /// selected and scrolled into view; a subtask shows in its parent's
    /// quick look.
    func testShowingATaskSelectsItOnItsTab() throws {
        let parked = try XCTUnwrap(add("Parked", tab: .backlog))
        XCTAssertEqual(model.show(parked), .shown)
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.selection, [parked])
        XCTAssertEqual(model.scrollRequest?.id, parked)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.selection, [parked], "the reveal keeps what show selected")

        let parent = try XCTUnwrap(add("Plan"))
        let child = try XCTUnwrap(store.create(title: "Step", parentID: parent)?.id)
        XCTAssertEqual(model.show(child), .shown)
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(model.selection, [parent])
        XCTAssertTrue(model.expanded.contains(parent))
        XCTAssertEqual(model.show(UUID()), .missing)
    }

    /// Generated, reproducible sessions use the same model commands as row
    /// clicks, the date and tag cards, the pager, the quick look and Undo.
    /// Fresh SwiftData reads after *every* action catch a transient list
    /// projection that disagrees with the committed store.
    func testH12SeededTaskSessionsRoundTripEveryStepAndUndoToCheckpoint() throws {
        struct Generator {
            var state: UInt64
            mutating func choose(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 32) % UInt64(max(1, bound)))
            }
        }
        struct LiveTask: Equatable {
            let id: UUID
            let content: TaskContentSnapshot
        }
        func liveState() -> [LiveTask] {
            store.tasks.map { LiveTask(id: $0.id, content: TaskContentSnapshot($0)) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }

        for seed in [UInt64(2026111201), 2026111202, 2026111203] {
            store = try makeTestStore(now: { [clock] in clock.value })
            library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
            let calendar = self.calendar
            model = TasksPageModel(library: library, services: TasksPageServices(
                now: { [clock] in clock.value }, calendar: { calendar },
                locale: Locale(identifier: "en_GB"), doneHold: .seconds(3_600)
            ))
            model.toasts.holdDuration = 3_600
            XCTAssertEqual(library.createTasks((0..<12).map { TaskDraft(title: "Seed root \($0)") })?.count, 12)
            var rng = Generator(state: seed)
            let steps = 360
            // UndoRoute deliberately retains at most 100 steps. Exercise six
            // continuous 60-action epochs, checking a complete Undo/Redo
            // round-trip at each checkpoint instead of falsely demanding
            // that 360 actions fit in a 100-step history.
            let epochSize = 60
            var epochStart = liveState()
            // The actual TasksPage releases its @FocusState whenever the
            // selected tab changes. Model-only generated sessions must
            // deliver that view callback; otherwise a row from the old
            // tab can appear to receive keys after switching away and back.
            func selectTab(_ destination: TasksTab) {
                let previous = model.tab
                model.select(tab: destination)
                if model.tab != previous { model.receiveKeyboardFocus(nil, keyboardDriving: false) }
            }

            for step in 0..<steps {
                if step.isMultiple(of: epochSize) {
                    library.undo.clear(.tasks)
                    epochStart = liveState()
                }
                let roots = store.tasks.filter { $0.parentID == nil }
                let id = roots.isEmpty ? nil : roots[rng.choose(roots.count)].id
                let action = rng.choose(16)
                let label = "seed=\(seed) step=\(step) action=\(action)"
                switch action {
                case 0: // Create in Now or Backlog.
                    if roots.count < 65 {
                        selectTab(rng.choose(2) == 0 ? .now : .backlog)
                        model.addBar.text = "Seed \(seed) item \(step)"
                        XCTAssertNotNil(model.submitAddBar(), label)
                    }
                case 1: // Rename through the row title editor.
                    if let id, let task = store.task(withID: id) {
                        selectTab(task.status == .backlog ? .backlog : task.status == .done ? .done : .now)
                        model.beginEditingTitle(id)
                        if model.editingTitleID == id {
                            model.editingTitle = task.title + " edit \(step)"
                            XCTAssertTrue(model.commitTitle(), label)
                        }
                    }
                case 2: // Tick or untick (including restoring Backlog state).
                    if let id { XCTAssertTrue(model.toggleDone(id).isApplied, label) }
                case 3: // Move between Now and Backlog.
                    if let id, let task = store.task(withID: id), task.status != .done {
                        let outcome = task.status == .backlog ? model.moveToNow([id]) : model.moveToBacklog([id])
                        XCTAssertTrue(outcome.isApplied, label)
                    }
                case 4: // Drag/keyboard reorder in the state group.
                    if let id, let task = store.task(withID: id), task.status != .done {
                        XCTAssertTrue(model.moveBy(id, offset: rng.choose(2) == 0 ? -1 : 1).isApplied, label)
                    }
                case 5: // Priority card.
                    if let id {
                        let priorities: [TaskPriority] = [.none, .low, .medium, .high]
                        XCTAssertTrue(model.setPriority(priorities[rng.choose(priorities.count)], for: [id]).isApplied, label)
                    }
                case 6: // Date card, including clearing a date.
                    if let id {
                        let day = rng.choose(4) == 0 ? nil : DueDay(year: 2026, month: 9, day: 22 + rng.choose(4))
                        XCTAssertTrue(model.setDueDay(day, for: [id]).isApplied, label)
                    }
                case 7: // Tags card.
                    if let id { XCTAssertTrue(model.toggleTag("h12", for: [id]).isApplied, label) }
                case 8: // Create a child in its parent's quick look.
                    if let id, let task = store.task(withID: id), task.status != .done,
                       store.subtasks(of: id).count < 5 {
                        selectTab(task.status == .backlog ? .backlog : .now)
                        model.beginAddingSubtask(to: id)
                        if model.newSubtaskParentID == id {
                            model.newSubtaskTitle = "Child \(step)"
                            XCTAssertTrue(model.commitNewSubtask(), label)
                            model.cancelEditing()
                        }
                    }
                case 9: // Tick an existing subtask.
                    if let id, let task = store.task(withID: id), task.status != .done,
                       let child = store.subtasks(of: id).first {
                        XCTAssertTrue(model.toggleSubtask(child.id).isApplied, label)
                    }
                case 10: // Pager and keyboard Tab focus.
                    let tabs: [TasksTab] = [.now, .backlog, .done]
                    selectTab(tabs[rng.choose(tabs.count)])
                    model.receiveKeyboardFocus(nil, keyboardDriving: false)
                    if model.tab != .done, let first = model.rows(for: model.tab).first?.id {
                        model.selectOnly(first)
                        model.receiveKeyboardFocus(AtticRowFocusID(page: model.tab.rawValue, id: first), keyboardDriving: true)
                    }
                case 11: // Fold and reopen a date group while a row is selected.
                    let tab: TasksTab = rng.choose(2) == 0 ? .now : .backlog
                    selectTab(tab)
                    if let row = model.rows(for: tab).first,
                       let key = model.groupKey(of: row.id, on: tab) {
                        model.selectOnly(row.id)
                        model.receiveKeyboardFocus(AtticRowFocusID(page: tab.rawValue, id: row.id), keyboardDriving: true)
                        model.foldAllGroups([key], folded: true, on: tab)
                        XCTAssertTrue(model.selection.isEmpty, label + " folded selection")
                        model.foldAllGroups([key], folded: false, on: tab)
                    }
                case 12: // Find, then clear the query.
                    let tab: TasksTab = rng.choose(2) == 0 ? .now : .backlog
                    selectTab(tab)
                    model.clearSelection() // Search taking focus does this in the real view.
                    model.receiveKeyboardFocus(nil, keyboardDriving: false)
                    model.setSearchQuery("no-match-H12", for: tab)
                    XCTAssertTrue(model.rows(for: tab).isEmpty, label + " search")
                    model.setSearchQuery("", for: tab)
                case 13: // Panel hides and returns while a title edit is unsaved.
                    if let id, let task = store.task(withID: id) {
                        selectTab(task.status == .backlog ? .backlog : task.status == .done ? .done : .now)
                        model.beginEditingTitle(id)
                        if model.editingTitleID == id {
                            model.editingTitle = task.title + " hidden \(step)"
                            model.pageDidHide()
                            model.pageDidReturn()
                            XCTAssertEqual(model.editingTitleID, id, label + " pending edit")
                            XCTAssertTrue(model.finishEditing(), label + " save on return")
                        }
                    }
                case 14: // Undo/Redo interleaved with later edits.
                    if rng.choose(3) == 0, library.undo.canRedo(in: .tasks) {
                        XCTAssertTrue(model.redo().isApplied, label)
                    } else if library.undo.canUndo(in: .tasks) {
                        XCTAssertTrue(model.undo().isApplied, label)
                    }
                default: // Delete moves a full family to Recently Deleted.
                    if let id { XCTAssertTrue(model.delete([id]).isApplied, label) }
                }

                // Release completion holds explicitly, as after their one
                // second animation. No test has to sleep or render an app.
                for held in Array(model.held.keys) { model.releaseHold(held) }
                let shownNow = model.rows(for: .now).map(\.id)
                let shownBacklog = model.rows(for: .backlog).map(\.id)
                let shownDone = model.doneDays().flatMap { $0.rows.map(\.id) }
                let openIDs = store.snapshot(for: .tasks).sections
                    .filter { $0.status != .done }.flatMap { $0.tasks.map(\.id) }
                let backlogIDs = store.snapshot(for: .backlog).sections.flatMap { $0.tasks.map(\.id) }
                let doneIDs = store.doneTodayTasks().map(\.id)
                XCTAssertEqual(Set(shownNow), Set(openIDs), label + " Now membership")
                XCTAssertEqual(Set(shownBacklog), Set(backlogIDs), label + " Backlog membership")
                XCTAssertEqual(Set(shownDone), Set(doneIDs), label + " Done membership")
                let allShown = shownNow + shownBacklog + shownDone
                XCTAssertEqual(Set(allShown).count, allShown.count, label + " no double rows")
                XCTAssertEqual(Set(allShown), Set(store.tasks.filter { $0.parentID == nil }.map(\.id)), label + " no lost roots")

                let focusIDs = Set(model.tab == .done ? shownDone : model.tab == .now ? shownNow : shownBacklog)
                XCTAssertTrue(model.selection.isSubset(of: focusIDs), label + " selected rows must be visible")
                if let focus = model.keyboardFocus, focus.page == model.tab.rawValue {
                    XCTAssertTrue(focusIDs.contains(focus.id), label + " focused row must be visible")
                }

                // Independently rehydrate from the durable store *every step*.
                let physical = try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>())
                let physicalCurrent = physical.filter { $0.deletedAt == nil && $0.doneLoggedAt == nil }
                let idsBeforeReload = store.tasks.map(\.id)
                XCTAssertEqual(Set(physicalCurrent.map(\.id)), Set(idsBeforeReload), label + " physical ids")
                for row in physicalCurrent {
                    let inMemory = try XCTUnwrap(store.task(withID: row.id), label)
                    XCTAssertEqual(inMemory.title, row.title, label + " persisted title")
                    XCTAssertEqual(inMemory.statusRaw, row.statusRaw, label + " persisted status")
                    XCTAssertEqual(inMemory.parentID, row.parentID, label + " persisted parent")
                    XCTAssertEqual(inMemory.dueDayRaw, row.dueDayRaw, label + " persisted day")
                    XCTAssertEqual(inMemory.tagsRaw, row.tagsRaw, label + " persisted tags")
                    XCTAssertEqual(inMemory.manualOrder, row.manualOrder, label + " persisted order")
                }
                store.refresh()
                XCTAssertEqual(Set(store.tasks.map(\.id)), Set(idsBeforeReload), label + " reload ids")
                XCTAssertEqual(model.rows(for: .now).map(\.id), shownNow, label + " reload Now order")
                XCTAssertEqual(model.rows(for: .backlog).map(\.id), shownBacklog, label + " reload Backlog order")

                if (step + 1).isMultiple(of: epochSize) {
                    let epochEnd = liveState()
                    var undos = 0
                    while library.undo.canUndo(in: .tasks), undos < epochSize + 1 {
                        let result = model.undo()
                        guard result.isApplied else {
                            XCTFail(label + " Undo step \(undos) was not applied")
                            break
                        }
                        undos += 1
                    }
                    XCTAssertFalse(library.undo.canUndo(in: .tasks), label + " Undo exhausted")
                    store.refresh()
                    XCTAssertEqual(liveState(), epochStart, label + " exact Undo checkpoint")

                    // Only redo the steps we just reversed: an interleaved
                    // user Undo may have left an older redo branch at the
                    // checkpoint, and replaying that is a different action.
                    for index in 0..<undos {
                        guard model.redo().isApplied else {
                            XCTFail(label + " Redo step \(index) was not applied")
                            break
                        }
                    }
                    store.refresh()
                    XCTAssertEqual(liveState(), epochEnd, label + " exact Redo checkpoint")
                    print("TASKS_HUNT12_EPOCH seed=\(seed) end=\(step) undo=\(undos)")
                }
            }

            print("TASKS_HUNT12_SEED seed=\(seed) steps=\(steps) checkpoints=\(steps / epochSize)")
        }
    }
}
