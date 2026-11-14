import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The owner's own panel design (Claude Design, 2026-10-27), built on the
/// branch's model: date groups per page (and at midnight), Done's day
/// headers and folds, a finished task leaving Now, the tag pill's colours,
/// the footer's turn, the empty states, the filter chips and the design's
/// sizes (drawn at 2×, px ÷ 2 = pt).
@MainActor
final class TasksPanelDesignTests: XCTestCase {
    /// The strip over the hosted add bar is hidden from VoiceOver (and UI
    /// tests) while the bar is empty: only its buttons' look is kept built.
    func testTheEmptyBarsStripIsHiddenFromAccessibility() throws {
        try assertTheEmptyBarsStripIsHidden(reduceMotion: false)
    }

    /// The same under Reduce Motion, as on GitHub's runners: the strip's
    /// hide takes the fade path there (no rise, no scale), and it must stay
    /// out of the tree too.
    func testTheEmptyBarsStripIsHiddenFromAccessibilityUnderReduceMotion() throws {
        try assertTheEmptyBarsStripIsHidden(reduceMotion: true)
    }

    private func assertTheEmptyBarsStripIsHidden(reduceMotion: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        AtticMotionPreference.systemReduceMotionOverride = reduceMotion
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        // As under VoiceOver or a UI test: SwiftUI builds its full tree.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        // The rig's stated Reduce Motion, and the context the panel derives
        // from it (`AtticSystemDesignModifier`).
        var design = AtticDesignContext(mode: .light)
        design.reduceMotion = reduceMotion
        let hosted = try Hosted(height: 520, design: design)
        defer { hosted.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var chain: [String] = []
        func find(_ element: AnyObject, depth: Int, path: [String]) -> Bool {
            guard depth < 40 else { return false }
            let id = (element.accessibilityIdentifier?() ?? nil) ?? ""
            let here = path + ["\(type(of: element)) \((element.accessibilityRole?() ?? nil)?.rawValue ?? "") \(id)"]
            if id == "composer-date" { chain = here; return true }
            return ((element.accessibilityChildren?() ?? nil) ?? []).contains { find($0 as AnyObject, depth: depth + 1, path: here) }
        }
        let found = find(try XCTUnwrap(hosted.window.contentView), depth: 0, path: [])
        if found { print("STRIPCHAIN\n" + chain.suffix(8).joined(separator: "\n")) }
        XCTAssertFalse(found, "no strip in the accessibility tree while the bar is empty (Reduce Motion \(reduceMotion))",
                       file: file, line: line)
    }

    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value }, calendar: { calendar }, locale: locale, doneHold: .seconds(3_600)))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: clock.value)!, calendar: calendar)
    }

    @discardableResult
    private func add(_ title: String, due offset: Int?, tab: TasksTab = .now) throws -> UUID {
        model.select(tab: tab)
        model.addBar.text = title
        let id = try XCTUnwrap(model.submitAddBar())
        if let offset { XCTAssertTrue(model.setDueDay(day(offset), for: [id]).isApplied) }
        return id
    }

    private func titles(_ tab: TasksTab) -> [String] { model.rows(for: tab).map(\.model.title) }
    private func headers(_ tab: TasksTab) -> [String] { model.sections(for: tab).groups.map(\.title) }

    // MARK: - Date groups

    func testGroupsAreOverdueTodayEachLaterDayThenNoDate() {
        let today = day(0)
        let ids = (0..<6).map { _ in UUID() }
        let rows: [(id: UUID, due: DueDay?)] = [(ids[0], nil), (ids[1], day(3)), (ids[2], day(-2)), (ids[3], today),
                                                 (ids[4], day(1)), (ids[5], day(-1))]
        let groups = TasksPanelDesign.groups(rows, today: today, calendar: calendar, locale: locale)
        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(groups.map(\.title).filter { !$0.hasPrefix("Thu 24 Sep") }, ["Overdue", "Today", "Tomorrow", "No date"])
        XCTAssertTrue(groups[3].title.hasPrefix("Thu 24 Sep"), "a later day's header: \(groups[3].title)")
        XCTAssertEqual(groups[0].ids, [ids[2], ids[5]], "the list's own order inside a group")
        XCTAssertEqual(groups.map(\.rowsShowDate), [true, true, false, false, true], "a day header carries the date")
        XCTAssertTrue(groups[0].isOverdue)
    }

    func testNowAndLaterListRowsInGroupOrderAndDayHeadersHideTheRowDate() throws {
        try add("Undated", due: nil)
        try add("Next", due: 1)
        try add("Late", due: -3)
        try add("Current", due: 0)
        XCTAssertEqual(headers(.now), ["Overdue", "Today", "Tomorrow", "No date"])
        XCTAssertEqual(titles(.now), ["Late", "Current", "Next", "Undated"], "the keyboard walks the groups' order")
        let tomorrow = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Next" })
        XCTAssertNil(tomorrow.model.trailingDue, "under a day header a row shows no date (Attic's tasks have no time)")
        XCTAssertEqual(model.rows(for: .now).first?.model.due?.tone, .overdue)
        // Backlog displays retained dates, with undated rows under No date.
        let idea = try add("Idea", due: 5)
        XCTAssertTrue(model.moveToBacklog([idea]).isApplied)
        try add("Someday", due: nil, tab: .backlog)
        XCTAssertEqual(model.sections(for: .backlog).groups.map(\.kind), [.backlog, .noDate])
        XCTAssertEqual(titles(.backlog), ["Idea", "Someday"])
        XCTAssertFalse(titles(.now).contains("Idea"))
        XCTAssertNotNil(model.rows(for: .backlog).first { $0.model.title == "Idea" }?.model.trailingDue)
    }

    func testAHeaderFoldsItsGroupAndTheFoldIsPerPage() throws {
        try add("Late", due: -1)
        try add("Plain", due: nil)
        let overdue = try XCTUnwrap(model.sections(for: .now).groups.first)
        model.toggleGroup(overdue.key, on: .now)
        XCTAssertEqual(titles(.now), ["Plain"], "a folded group's rows leave the list")
        XCTAssertEqual(model.sections(for: .now).groups.map(\.title), ["Overdue", "No date"], "its header stays")
        XCTAssertEqual(model.sections(for: .now).groups.first?.ids.count, 1, "the count it shows while folded")
        XCTAssertTrue(model.folded(on: .backlog).isEmpty)
        model.toggleGroup(overdue.key, on: .now)
        XCTAssertEqual(titles(.now), ["Late", "Plain"])
    }

    func testBG2DuplicatingACompletedTaskReopensItsFoldedDestinationDay() throws {
        let original = try add("Booked today", due: 0)
        let anchor = try add("Already today", due: 0)
        XCTAssertTrue(library.completeTask(original).isApplied)
        XCTAssertGreaterThan(store.moveCompletedToDoneLog(before: clock.value.addingTimeInterval(60)), 0)
        let todayKey = try XCTUnwrap(model.groupKey(of: anchor, on: .now))
        model.toggleGroup(todayKey, on: .now)
        XCTAssertTrue(model.folded(on: .now).contains(todayKey))
        model.select(tab: .done)
        XCTAssertTrue(model.duplicate([original]).isApplied)
        let copied = try XCTUnwrap(model.selection.first)
        XCTAssertEqual(model.tab, .now)
        XCTAssertFalse(model.folded(on: .now).contains(todayKey), "BG-2: the destination day opens for a new copy")
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == copied })
        XCTAssertEqual(model.addedRequest?.id, copied)
    }

    func testBG6InterruptedFoldCompletesOnItsOriginalTab() throws {
        let now = try add("Now without date", due: nil)
        let later = try add("Backlog without date", due: nil, tab: .backlog)
        let nowKey = try XCTUnwrap(model.groupKey(of: now, on: .now))
        let laterKey = try XCTUnwrap(model.groupKey(of: later, on: .backlog))
        XCTAssertNotEqual(nowKey, laterKey, "Now and Backlog use their own date-group identities")
        // The first close is halfway through its animation when another
        // tab's group gets clicked; settle both against their own model tab.
        model.foldTurn = TasksFoldTurn(tab: .now, key: nowKey, closing: true,
                                       headerFolded: true, progress: 0.5, generation: 1)
        TasksFold.turn(laterKey, on: .backlog, folded: false, animation: nil, generation: 2,
                       state: Binding(get: { self.model.foldTurn }, set: { self.model.foldTurn = $0 })) { tab, key in
            self.model.toggleGroup(key, on: tab)
        }
        XCTAssertTrue(model.folded(on: .now).contains(nowKey), "interrupted Now close must finish on Now")
        XCTAssertTrue(model.folded(on: .backlog).contains(laterKey), "Backlog click must fold Backlog once")
        XCTAssertNil(model.foldTurn)
    }

    // MARK: - pro-bugs-tasks-r1 fix 1: what BG-2 left

    /// Opus R-4 = Dot R-6: a header click starts a closing turn that folds the
    /// model only when it ends. A task added in that window must not be
    /// folded away by the pending completion.
    func testBG2AddingIntoAGroupThatIsStillClosingKeepsItOpen() throws {
        let anchor = try add("Today anchor", due: 0)
        let key = try XCTUnwrap(model.groupKey(of: anchor, on: .now))
        model.foldTurn = TasksFoldTurn(tab: .now, key: key, closing: true, headerFolded: true, progress: 0.5, generation: 7)
        model.addBar.text = "Added while Today closes"
        model.addBar.picked.day = day(0)
        let created = try XCTUnwrap(model.submitAddBar())
        XCTAssertEqual(model.groupKey(of: created, on: .now), key)
        XCTAssertFalse(model.folded(on: .now).contains(key))
        // The turn's completion (TasksFold.turn) folds only its own turn.
        if let turn = model.foldTurn, turn.generation == 7, turn.closing { model.toggleGroup(turn.key, on: turn.tab) }
        XCTAssertFalse(model.folded(on: .now).contains(key), "BG-2: a closing group must not fold over the new task")
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == created })
    }

    /// Opus R-5: every pasted task's group opens, not only the first's.
    func testBG2PasteOpensTheFoldedGroupOfEveryCreatedTask() throws {
        let today = try add("Seed today", due: 0)
        let tomorrow = try add("Seed tomorrow", due: 1)
        let friday = try add("Seed friday", due: 4)
        let keys = try [today, tomorrow, friday].map { try XCTUnwrap(model.groupKey(of: $0, on: .now)) }
        XCTAssertEqual(Set(keys).count, 3)
        model.foldAllGroups(keys, folded: true, on: .now)
        model.pasteOffer = try XCTUnwrap(TaskPasteOffer("a today\nb tomorrow\nc friday"))
        model.acceptPaste(asOne: false)
        let created = store.tasks.filter { ["a", "b", "c"].contains($0.title.prefix(1)) && $0.title.count <= 3 }
        XCTAssertEqual(created.count, 3, "the paste made three tasks: \(store.tasks.map(\.title))")
        let destinations = Set(created.compactMap { model.groupKey(of: $0.id, on: .now) })
        XCTAssertEqual(destinations.count, 3, "the lines land in three different groups")
        for key in destinations {
            XCTAssertFalse(model.folded(on: .now).contains(key), "BG-2: every created task's group opens")
        }
        let shown = Set(model.rows(for: .now).map(\.id))
        XCTAssertTrue(created.allSatisfy { shown.contains($0.id) }, "every pasted task is drawn")
    }

    /// Dot R-3: copies of two Done tasks land in two folded Now groups. Both
    /// open, so no selected copy is hidden from the bulk actions.
    func testBG2DuplicatingDoneTasksIntoTwoFoldedGroupsOpensBoth() throws {
        let first = try add("Booked today", due: 0)
        let second = try add("Booked tomorrow", due: 1)
        let anchorToday = try add("Today anchor", due: 0)
        let anchorTomorrow = try add("Tomorrow anchor", due: 1)
        for id in [first, second] { XCTAssertTrue(library.completeTask(id).isApplied) }
        XCTAssertGreaterThan(store.moveCompletedToDoneLog(before: clock.value.addingTimeInterval(60)), 0)
        let keys = try [anchorToday, anchorTomorrow].map { try XCTUnwrap(model.groupKey(of: $0, on: .now)) }
        model.foldAllGroups(keys, folded: true, on: .now)
        model.select(tab: .done)
        XCTAssertTrue(model.duplicate([first, second]).isApplied)
        XCTAssertEqual(model.tab, .now)
        for key in keys { XCTAssertFalse(model.folded(on: .now).contains(key), "BG-2: both destination groups open") }
        let shown = Set(model.rows(for: .now).map(\.id))
        XCTAssertFalse(model.selection.isEmpty)
        XCTAssertTrue(model.selection.isSubset(of: shown), "no selected copy is hidden in a folded group")
    }

    // MARK: - pro-bugs-tasks-r1 fix 2

    /// Opus R-11: a `show` that targets a task in a group still closing opens
    /// it, as an add does: the turn goes back, the model never folds, and the
    /// selection `show` made is not pruned by the pending fold.
    func testShowOpensAGroupThatIsStillClosing() throws {
        _ = try add("Today anchor", due: 0)
        let target = try add("Today target", due: 0)
        let key = try XCTUnwrap(model.groupKey(of: target, on: .now))
        model.foldTurn = TasksFoldTurn(tab: .now, key: key, closing: true, headerFolded: true, progress: 0.4, generation: 7)
        XCTAssertEqual(model.show(target), .shown)
        // The closing turn's completion (TasksFold.turn) folds only its own turn.
        if let turn = model.foldTurn, turn.generation == 7, turn.closing { model.toggleGroup(turn.key, on: turn.tab) }
        XCTAssertFalse(model.folded(on: .now).contains(key), "R-11: show must not leave the group folded over the task")
        XCTAssertEqual(model.selection, [target], "the selection show made survives")
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == target })
    }

    /// The same for a Done day (`unfoldDoneDay`).
    func testShowOpensADoneDayThatIsStillClosing() throws {
        let id = try add("Finished today", due: nil)
        XCTAssertTrue(model.toggleDone(id).isApplied)
        model.releaseHold(id)
        let key = try XCTUnwrap(model.doneDays().first?.key)
        model.foldTurn = TasksFoldTurn(tab: .done, key: key, closing: true, headerFolded: true, progress: 0.4, generation: 7)
        XCTAssertEqual(model.show(id), .shown)
        if let turn = model.foldTurn, turn.generation == 7, turn.closing { model.toggleGroup(turn.key, on: turn.tab) }
        XCTAssertFalse(model.folded(on: .done).contains(key), "R-11: show must not leave the day folded over the task")
        XCTAssertEqual(model.selection, [id])
    }

    /// Dot R-4: adding into a group that is closing turns the fold back from
    /// where it is (the reversal a second click runs), not a snap open: the
    /// turn is handed an opening state of its own generation (the closing
    /// turn's completion no longer matches it) before it ends, and the model
    /// never folds. (Off screen no view animates the turn, so it also ends at
    /// once; what it was handed is what the publisher saw.)
    func testAddingIntoAClosingGroupTurnsTheFoldBackInsteadOfSnappingOpen() throws {
        let anchor = try add("Today anchor", due: 0)
        let key = try XCTUnwrap(model.groupKey(of: anchor, on: .now))
        model.foldTurn = TasksFoldTurn(tab: .now, key: key, closing: true, headerFolded: true, progress: 0.5, generation: 7)
        var seen: [TasksFoldTurn?] = []
        let watch = model.$foldTurn.sink { seen.append($0) }
        defer { watch.cancel() }
        model.addBar.text = "Added while Today closes"
        model.addBar.picked.day = day(0)
        _ = try XCTUnwrap(model.submitAddBar())
        let reversed = try XCTUnwrap(seen.compactMap { $0 }.first { !$0.closing }, "R-4: an opening turn was handed over; the closing one was not just dropped")
        XCTAssertEqual(reversed.progress, 1, "it opens, from wherever the closing turn was")
        XCTAssertNotEqual(reversed.generation, 7, "the closing turn's completion no longer matches it")
        XCTAssertFalse(model.folded(on: .now).contains(key))
    }

    /// Dot R-3: a batch finds and opens its groups with work that grows with
    /// the batch: member ids looked at, and row lists built, for N and 2N
    /// tasks in N and 2N folded days.
    func testOpeningTheGroupsOfABatchGrowsLinearlyWithTheBatch() throws {
        func measure(_ count: Int) throws -> (visits: Int, builds: Int) {
            let store = try makeTestStore(now: { [clock] in clock.value })
            let library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
            let calendar = self.calendar
            let model = TasksPageModel(library: library, services: TasksPageServices(
                now: { [clock] in clock.value }, calendar: { calendar }, locale: locale, doneHold: .seconds(3_600)))
            let drafts = (0..<count).map { TaskDraft(title: "Batch \($0)", dueDay: day(2 + $0)) }
            let created = try XCTUnwrap(library.createTasks(drafts))
            let keys = created.map { TasksPanelDesign.GroupKind.day($0.dueDay!).key }
            XCTAssertEqual(Set(keys).count, count)
            model.foldAllGroups(keys, folded: true, on: .now)
            XCTAssertEqual(model.rows(for: .now).count, 0, "every group is folded")
            let visits = model.groupMembershipVisits, builds = model.rowsBuildCount
            model.unfoldAddedTasks(created)
            XCTAssertEqual(model.rows(for: .now).count, count, "every group opened")
            return (model.groupMembershipVisits - visits, model.rowsBuildCount - builds)
        }
        let small = try measure(40), large = try measure(80)
        XCTAssertLessThanOrEqual(large.visits, small.visits * 2 + 8, "membership work is linear (\(small.visits) for 40, \(large.visits) for 80)")
        XCTAssertLessThanOrEqual(large.builds, small.builds + 1, "one fold update: the row list is rebuilt once, not per group (\(small.builds), \(large.builds))")
        XCTAssertLessThanOrEqual(small.builds, 2)
    }

    /// Dot R-3, the other half: N copies into ONE group are found with one
    /// pass, not a scan of the group per copy.
    func testOpeningOneGroupForABatchOfTasksIsOnePass() throws {
        func visits(_ count: Int) throws -> Int {
            let store = try makeTestStore(now: { [clock] in clock.value })
            let library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
            let calendar = self.calendar
            let model = TasksPageModel(library: library, services: TasksPageServices(
                now: { [clock] in clock.value }, calendar: { calendar }, locale: locale, doneHold: .seconds(3_600)))
            let created = try XCTUnwrap(library.createTasks((0..<count).map { TaskDraft(title: "Same day \($0)", dueDay: day(3)) }))
            let key = try XCTUnwrap(model.groupKey(of: created[0].id, on: .now))
            model.foldAllGroups([key], folded: true, on: .now)
            let before = model.groupMembershipVisits
            model.unfoldAddedTasks(created)
            XCTAssertFalse(model.folded(on: .now).contains(key))
            return model.groupMembershipVisits - before
        }
        let small = try visits(60), large = try visits(120)
        XCTAssertLessThanOrEqual(large, small * 2 + 4, "one pass: \(small) for 60, \(large) for 120")
    }

    func testGroupsMoveOnAtMidnight() throws {
        try add("Soon", due: 1)
        XCTAssertEqual(headers(.now), ["Tomorrow"])
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        XCTAssertEqual(headers(.now), ["Today"], "the rows cache is keyed by the day")
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        XCTAssertEqual(headers(.now), ["Overdue"])
    }

    func testAKeyboardMoveStaysInsideItsDateGroup() throws {
        let a = try add("A", due: nil)
        let b = try add("B", due: -1)
        let c = try add("C", due: nil)
        XCTAssertEqual(Set(model.shownGroup(of: a, status: .todo, on: .now)), [a, c])
        XCTAssertEqual(model.shownGroup(of: b, status: .todo, on: .now), [b])
        XCTAssertNotEqual(model.groupKey(of: a, on: .now), model.groupKey(of: b, on: .now))
    }

    // MARK: - Done

    func testDoneDaysUseTheDesignsHeadersAndFold() throws {
        let id = try add("Finished", due: nil)
        XCTAssertTrue(model.toggleDone(id).isApplied)
        model.releaseHold(id)
        let days = model.doneDays()
        XCTAssertEqual(days.first?.title.hasPrefix("Mon 21 Sep"), true, "today's header is its date too: \(days.first?.title ?? "")")
        let key = try XCTUnwrap(days.first?.key)
        model.toggleGroup(key, on: .done)
        XCTAssertEqual(model.doneDays().first?.rows.count, 0)
        XCTAssertEqual(model.doneDays().first?.total, 1)
        XCTAssertEqual(model.doneDays().first?.folded, true)
    }

    func testDoneOffersToCollapseAndExpandItsDays() throws {
        let id = try add("Finished", due: nil)
        XCTAssertTrue(model.toggleDone(id).isApplied)
        model.releaseHold(id)
        var commands = model.doneCommands()
        XCTAssertEqual(commands.map(\.title), ["Collapse All Days", "Expand All Days"])
        XCTAssertEqual(commands.map(\.isDisabled), [false, true])
        commands[0].action()
        XCTAssertEqual(model.doneDays().first?.folded, true)
        commands = model.doneCommands()
        XCTAssertEqual(commands.map(\.isDisabled), [true, false])
        commands[1].action()
        XCTAssertEqual(model.doneDays().first?.folded, false)
    }

    func testAFinishedTaskLeavesNowAfterItsHoldAndUndoBringsItBack() throws {
        try add("First", due: nil)
        let done = try add("Second", due: nil)
        try add("Third", due: nil)
        let before = titles(.now)
        XCTAssertTrue(model.toggleDone(done).isApplied)
        XCTAssertEqual(titles(.now), before, "it holds its place while the ring plays")
        model.releaseHold(done)
        XCTAssertFalse(titles(.now).contains("Second"), "then it leaves Now")
        XCTAssertTrue(model.sections(for: .now).done.isEmpty, "Now has no Completed today")
        XCTAssertEqual(model.completedTodayCount, 0)
        XCTAssertTrue(model.doneDays().flatMap(\.rows).contains { $0.id == done }, "it lives in Done")
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(titles(.now), before, "undo brings it back to the same place")
    }

    // MARK: - Pure rules

    /// Tags are coloured text, no pill (owner's changelog, 27 Oct):
    /// `oklch(0.5 0.14 h)` in the tag's own hue (the branch's colours).
    func testTagsAreTheChangelogsColouredTextInTheTagsOwnHue() {
        func rgb(_ c: AtticRGBA) -> [Int] { [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) } }
        let blue = TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: .blue), dark: false)
        XCTAssertEqual(blue.text, TasksPanelDesign.oklch(0.5, 0.14, 250))
        XCTAssertEqual(rgb(blue.text), [4, 101, 175], "oklch(0.5 0.14 250)")
        XCTAssertEqual(TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: .pink), dark: false).text, TasksPanelDesign.oklch(0.5, 0.14, 340))
        XCTAssertNil(TasksPanelDesign.oklchHue(for: .grey))
        XCTAssertEqual(TasksPanelDesign.oklchHue(for: .indigo), 250, "a legacy colour shows as its clear hue")
        let dark = TasksPanelDesign.tagColours(hue: 250, dark: true)
        XCTAssertGreaterThan(dark.text.relativeLuminance, dark.fill.relativeLuminance, "dark mode: light text on a deep fill")
    }

    /// Row hover and selection on Glass (Accepted 2026-11-09, `hover-drafts.html`):
    /// the selected row is a raised glass chip, the hover is doubled from
    /// today (7 % / 8 %), and nothing else moves.
    @MainActor
    func testRowHighlightOnGlassIsChipAndDoubledHover() {
        let light = AtticDesignContext(mode: .light, surface: .glass).tokens
        let dark = AtticDesignContext(mode: .dark, surface: .glass).tokens
        XCTAssertEqual(light.rowHighlight(selected: false, hovered: true), .fill(.black(0.07)))
        XCTAssertEqual(dark.rowHighlight(selected: false, hovered: true), .fill(.white(0.08)))
        for tokens in [light, dark] {
            XCTAssertEqual(tokens.rowHighlight(selected: true, hovered: false), .raisedChip)
            XCTAssertEqual(tokens.rowHighlight(selected: true, hovered: true), .raisedChip, "selection wins over hover")
            XCTAssertNil(tokens.rowHighlight(selected: false, hovered: false))
        }
        // One or more touching rows share a single raised glass backing.
        for run in [AtticSelectionRun.first, .middle, .last] {
            XCTAssertEqual(light.rowHighlight(selected: true, hovered: false, run: run), .raisedChip)
            XCTAssertEqual(dark.rowHighlight(selected: true, hovered: false, run: run), .raisedChip)
        }
        // The shared tokens that menus, Settings and tags use do not move.
        XCTAssertEqual(light.hover, .black(0.035))
        XCTAssertEqual(dark.hover, .white(0.04))
        XCTAssertEqual(light.selected, .black(0.075))
        XCTAssertEqual(dark.selected, .white(0.09))
    }

    /// Joined glass spans the entire contiguous run, even with tall rows.
    @MainActor
    func testJoinedSelectedRowsAreOneChipEvenWithMixedHeightsAndSeparatedGroups() {
        let ids = (0..<5).map { _ in UUID() }
        let pieces: [AtticJoinedSelectedRuns.Piece] = [
            .init(id: ids[0], frame: CGRect(x: 8, y: 0, width: 220, height: 32), run: .first),
            .init(id: ids[1], frame: CGRect(x: 8, y: 32, width: 220, height: 48), run: .middle),
            .init(id: ids[2], frame: CGRect(x: 8, y: 80, width: 220, height: 32), run: .last),
            .init(id: ids[3], frame: CGRect(x: 8, y: 144, width: 220, height: 32), run: .first),
            .init(id: ids[4], frame: CGRect(x: 8, y: 176, width: 220, height: 32), run: .last)
        ]
        let joined = AtticJoinedSelectedRuns.joined(Array(pieces.reversed()))
        XCTAssertEqual(joined.count, 2)
        XCTAssertEqual(joined.map(\.frame), [CGRect(x: 8, y: 0, width: 220, height: 112),
                                              CGRect(x: 8, y: 144, width: 220, height: 64)])
        // A date header, hidden row or expanded detail separates the glass.
        let broken = AtticJoinedSelectedRuns.joined([
            .init(id: ids[0], frame: CGRect(x: 8, y: 0, width: 220, height: 32), run: .first),
            .init(id: ids[1], frame: CGRect(x: 8, y: 48, width: 220, height: 32), run: .last)
        ])
        XCTAssertEqual(broken.count, 2)
    }

    /// The other surfaces keep the shared fills.
    @MainActor
    func testRowHighlightOffGlassKeepsSharedFills() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for increaseContrast in [false, true] {
                for surface in [PanelSurfaceStyle.solid, .frosted, .glass] {
                    let tokens = AtticDesignContext(mode: mode, surface: surface, increaseContrast: increaseContrast).tokens
                    XCTAssertEqual(tokens.rowHighlight(selected: false, hovered: true), .fill(tokens.rowHover), "\(mode) \(surface) IC=\(increaseContrast)")
                    let selected = surface == .glass ? AtticRowHighlightStyle.raisedChip : .fill(tokens.selected)
                    XCTAssertEqual(tokens.rowHighlight(selected: true, hovered: false), selected, "\(mode) \(surface) IC=\(increaseContrast)")
                    XCTAssertEqual(tokens.rowHighlight(selected: true, hovered: false, run: .middle), selected, "\(mode) \(surface) IC=\(increaseContrast)")
                }
            }
        }
    }

    /// A row's text stays readable on the stronger fills.
    @MainActor
    func testRowHighlightFillsKeepRowTextLegible() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let tokens = AtticDesignContext(mode: mode, surface: .glass).tokens
            let base = tokens.panel.base.withAlpha(1)
            let run: AtticRGBA = mode == .dark ? .white(0.16) : .black(0.14)
            for fill in [tokens.rowHover, run] {
                let surface = fill.over(base)
                XCTAssertGreaterThanOrEqual(tokens.ink(.heading).contrast(on: surface), 4.5, "\(mode) heading")
                XCTAssertGreaterThanOrEqual(tokens.ink(.body).contrast(on: surface), 4.5, "\(mode) body")
            }
        }
    }

    /// The row's `#name`: the changelog colour on Solid (Light), today's
    /// clean colour on glass; readable everywhere; never a pill at rest,
    /// only the hover fill.
    @MainActor
    func testTagLabelIsColouredTextWithNoPill() {
        for context in AtticAppearanceCheck.allContexts() {
            let tokens = context.tokens
            let base = tokens.panel.base
            for hue in AtticTagHue.palette + [.grey] {
                let ink = TasksPanelDesign.tagInk(hue, tokens: tokens)
                if TasksPanelDesign.seeThrough(tokens) {
                    XCTAssertEqual(ink, TasksPanelDesign.vivid(tokens.ink(hue.ink), tokens: tokens), "glass keeps its treatment · \(context.caption)")
                } else if context.mode == .light && !context.increaseContrast {
                    XCTAssertEqual(ink, TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: hue), dark: false).text, context.caption)
                }
                XCTAssertGreaterThanOrEqual(ink.contrast(on: base), 4.5, "\(hue) · \(context.caption)")
            }
            XCTAssertEqual(AtticTagLabel.fill(hovered: false, disabled: false, tokens: tokens), .clear, "no pill · \(context.caption)")
            XCTAssertNotEqual(AtticTagLabel.fill(hovered: true, disabled: false, tokens: tokens), .clear, "the hover fill · \(context.caption)")
            XCTAssertEqual(AtticTagLabel.fill(hovered: true, disabled: true, tokens: tokens), .clear)
        }
    }

    func testTheFooterTurnsWhileTheAddFieldIsUsed() {
        XCTAssertFalse(TasksPanelDesign.footerFolded(addFocused: false, hasDraft: false))
        XCTAssertTrue(TasksPanelDesign.footerFolded(addFocused: true, hasDraft: false))
        XCTAssertTrue(TasksPanelDesign.footerFolded(addFocused: false, hasDraft: true), "a kept draft keeps the field wide")
    }

    func testEmptyStatesUseTheDesignsCopy() {
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "", filtered: false).title, "Nothing to do right now")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: false).title, "Nothing in Backlog")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .done, query: "", filtered: false),
                       .init(title: "Nothing completed yet", body: "", canClear: false))
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: " milk ", filtered: false),
                       .init(title: "No results", body: "No tasks match “milk”.", canClear: true))
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: true).canClear, true)
    }

    // MARK: - Tag chips (owner, 2026-10-28)

    private func tag(_ id: UUID, _ tags: String...) {
        for tag in tags { XCTAssertTrue(model.toggleTag(tag, for: [id]).isApplied) }
    }

    /// The chips are All, then one per tag on the tasks that exist (Now and
    /// Later), in the library's tag order; a tag no task carries has none.
    func testTagChipsAreAllThenTheTagsInUseInTheBranchOrder() throws {
        let a = try add("Pay rent", due: nil)
        let b = try add("Book flights", due: nil)
        let c = try add("Read paper", due: nil, tab: .backlog)
        tag(a, "home", "money")
        tag(b, "travel", "money")
        tag(c, "uni", "money", "travel")
        let order = library.tags.names.filter { ["home", "money", "travel", "uni"].contains($0) }
        XCTAssertEqual(model.tagChips(), order, "the branch's tag order")
        XCTAssertEqual(Set(model.tagChips()), ["home", "money", "travel", "uni"])
        XCTAssertEqual(model.tagChips().first, "money", "most used first")
        XCTAssertEqual(TasksPanelDesign.tagChipTitle("money"), "#money", "the row pills' wording")
        tag(a, "home") // removed from its only task
        XCTAssertFalse(model.tagChips().contains("home"), "a tag no task carries has no chip")
    }

    /// One tag at a time: a tag shows only its tasks; the chosen tag again,
    /// or All, clears it. It combines with the View options and the search.
    func testATagChipFiltersAndCombinesWithTheViewAndTheSearch() throws {
        let a = try add("Pay rent", due: nil)
        let b = try add("Pay gym", due: nil)
        let c = try add("Book flights", due: nil)
        tag(a, "home")
        tag(b, "home")
        tag(c, "travel")
        XCTAssertTrue(model.setPriority(.high, for: [b]).isApplied)
        model.select(tab: .now)
        model.chooseTagChip("home")
        XCTAssertEqual(model.tagPicks, TagPicks(["home"]))
        XCTAssertEqual(Set(titles(.now)), ["Pay rent", "Pay gym"])
        XCTAssertTrue(model.narrows(.now), "a tag narrows the list (reorders move among what is shown)")
        var view = model.viewOptions(for: .now)
        view.priority = .highOnly
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(.now), ["Pay gym"], "the tag and the View options both match")
        view.priority = .any
        model.setViewOptions(view, for: .now)
        model.setSearchQuery("rent", for: .now)
        XCTAssertEqual(titles(.now), ["Pay rent"], "the tag and the search both match")
        model.setSearchQuery("flights", for: .now)
        XCTAssertEqual(titles(.now), [], "the search alone would show Book flights")
        model.setSearchQuery("", for: .now)
        // Several tags (Accepted 2026-11-13, 2B): a click adds a tag; Any
        // shows a task with either, All only one with both.
        model.chooseTagChip("travel")
        XCTAssertEqual(model.tagPicks, TagPicks(["home", "travel"]))
        XCTAssertEqual(Set(titles(.now)), ["Pay rent", "Pay gym", "Book flights"], "Any: either tag")
        model.setTagMatch(.all)
        XCTAssertEqual(titles(.now), [], "All: no task has both")
        model.chooseTagChip("travel")
        XCTAssertEqual(model.tagPicks, TagPicks(["home"]), "a picked tag again leaves the pick")
        XCTAssertEqual(model.tagPicks.match, .any, "one tag left: the switch goes, back to Any")
        model.chooseTagChip("home")
        XCTAssertTrue(model.tagPicks.isEmpty, "the last picked tag again clears it")
        model.chooseTagChip("home")
        model.chooseTagChip("travel")
        model.chooseTagChip(nil)
        XCTAssertTrue(model.tagPicks.isEmpty, "All clears every pick")
        XCTAssertEqual(titles(.now).count, 3)
    }

    /// Deleting the chosen tag clears the filter; renaming it follows the
    /// new name. The list is never left on a tag that no longer exists.
    func testDeletingOrRenamingTheChosenTagClearsOrFollowsIt() throws {
        let a = try add("Pay rent", due: nil)
        let b = try add("Book flights", due: nil)
        tag(a, "home")
        tag(b, "travel")
        model.chooseTagChip("home")
        XCTAssertTrue(library.renameTag("home", to: "house"))
        XCTAssertEqual(model.tagPicks, TagPicks(["house"]), "a rename follows")
        model.pruneTagPicks()
        XCTAssertEqual(model.tagPicks, TagPicks(["house"]))
        XCTAssertEqual(titles(.now), ["Pay rent"])
        XCTAssertTrue(library.deleteTag("house"))
        model.pruneTagPicks()
        XCTAssertTrue(model.tagPicks.isEmpty, "a deleted tag clears it")
        XCTAssertEqual(titles(.now).count, 2)
        model.chooseTagChip("travel")
        XCTAssertTrue(library.mergeTags(["travel"], into: "trips"))
        XCTAssertEqual(model.tagPicks, TagPicks(["trips"]), "a merge follows too")
        tag(b, "trips") // its only task loses it
        let settled = expectation(description: "the change has been seen")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(model.tagPicks.isEmpty, "the last task losing the tag clears it on its own")
    }

    /// Changing the shared tag while Now is visible must not invalidate
    /// retained, offscreen Later and Done page trees. They refresh from the
    /// current filter when brought on screen, rather than paying for three
    /// list diffs during the tag-chip click.
    func testTagFilterKeepsOffscreenTaskPagesFrozenUntilShown() throws {
        let now = try add("Write outline", due: nil, tab: .now)
        let later = try add("Edit outline", due: nil, tab: .backlog)
        tag(now, "writing")
        tag(later, "writing")
        model.select(tab: .now)

        let visibleBefore = model.pageToken(.now)
        let laterBefore = model.pageToken(.backlog)
        let doneBefore = model.pageToken(.done)
        var doneInvalidations = 0
        let doneObserver = model.doneResults.objectWillChange.sink { doneInvalidations += 1 }
        defer { doneObserver.cancel() }
        model.chooseTagChip("writing")

        XCTAssertNotEqual(model.pageToken(.now), visibleBefore, "the active page must update")
        XCTAssertEqual(model.pageToken(.backlog), laterBefore, "a hidden Later list must not diff during the click")
        XCTAssertEqual(model.pageToken(.done), doneBefore, "a hidden Done list must not diff during the click")
        XCTAssertEqual(doneInvalidations, 0, "the offscreen Done results must not publish")

        model.select(tab: .backlog)
        XCTAssertNotEqual(model.pageToken(.backlog), laterBefore, "Later must refresh on opening")
        XCTAssertEqual(model.rows(for: .backlog).map(\.id), [later], "the newly shown page must use the chosen tag")
        model.chooseTagChip(nil)
        XCTAssertEqual(model.rows(for: .backlog).map(\.id), [later], "clearing the filter restores the full list")
        model.select(tab: .done)
        let beforeDoneClick = doneInvalidations
        model.chooseTagChip("writing")
        XCTAssertGreaterThan(doneInvalidations, beforeDoneClick, "a visible Done page must still respond to a tag change")
    }

    /// Accepted 2026-10-30 ("Top row and bottom bar"): the search has no
    /// list chips; the tag bar at the bottom filters, and choosing a tag
    /// never moves the list under the top row.
    func testATagFilterLeavesTheListInPlace() throws {
        for title in ["Late one", "Due today", "Undated"] {
            let id = try add(title, due: title == "Late one" ? -1 : (title == "Due today" ? 0 : nil))
            tag(id, "home")
        }
        model.select(tab: .now)
        let first = try XCTUnwrap(model.rows(for: .now).first?.id)
        let pointer = TasksPointer()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let page = TasksPage(model: model, store: store, layout: layout, addBarFocused: .constant(false), pointer: pointer)
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.6)); window.contentView?.layoutSubtreeIfNeeded() }
        spin()
        func top() -> CGFloat? { pointer.frames[TasksRowID(tab: .now, id: first)]?.minY }
        let shut = try XCTUnwrap(top())
        model.chooseTagChip("home") // a filter hides nothing here, but the row stays up while it is on
        spin()
        XCTAssertEqual(model.rows(for: .now).count, 3)
        let open = try XCTUnwrap(top())
        // Accepted 2026-11-13: the view line names the picked tags too, so a
        // tag filter adds that one line; still no chip row under the top row.
        XCTAssertEqual(open, shut + AtticLayout.rowPitch, accuracy: 1, "only the view line, no chip row")
        model.chooseTagChip(nil)
        spin()
        let closed = try XCTUnwrap(top())
        XCTAssertEqual(closed, shut, accuracy: 1)
    }

    /// Mid-scroll the list moves with the row too, within what can scroll.
    func testTheChipRowsShiftStaysInTheScrollableRange() {
        XCTAssertEqual(TasksViewport.originAfterTopChange(originY: -60, delta: 41, newTopInset: 101, maxY: 900), -101,
                       "at the top: the first row rests below the chips")
        XCTAssertEqual(TasksViewport.originAfterTopChange(originY: 300, delta: 41, newTopInset: 101, maxY: 900), 259,
                       "mid-scroll: what was shown moves down with the row")
        XCTAssertEqual(TasksViewport.originAfterTopChange(originY: -101, delta: -41, newTopInset: 60, maxY: 900), -60,
                       "closing at the top: back to the top")
        XCTAssertEqual(TasksViewport.originAfterTopChange(originY: 880, delta: -41, newTopInset: 60, maxY: 900), 900,
                       "closing near the end: never past the end")
    }

    /// Accepted 2026-11-13: the empty state names the filter and lists the rest.
    func testTheTagEmptyStateUsesTheDesignsWording() {
        let home = TagPicks(["home"])
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "", view: TasksViewOptions(), picks: home).title,
                       "Nothing in #home")
        XCTAssertTrue(TasksPanelDesign.empty(tab: .now, query: "", view: TasksViewOptions(), picks: home).canClear)
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "milk", view: TasksViewOptions(), picks: home).body,
                       "No tasks match “milk”.", "the search's wording first")
        let both = TasksPanelDesign.empty(tab: .now, query: "",
                                          view: TasksViewOptions(status: .inProgress, show: .overdueOnly),
                                          picks: TagPicks(["work", "home"], match: .all))
        XCTAssertEqual(both.title, "Nothing in progress")
        XCTAssertEqual(both.body, "in #work and #home, overdue")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "", view: TasksViewOptions(status: .toDo), picks: .none).title,
                       "Nothing to do")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", view: TasksViewOptions(show: .overdueOnly), picks: .none).title,
                       "No overdue tasks")
    }

    // MARK: - Fidelity (spec audit, 2026-10-28)

    /// The page as drawn, its text probes collected (ink, colour, frame).
    private func drawnText(_ context: AtticDesignContext) throws -> [AtticProbe] {
        let collector = AtticProbeCollector()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: .constant(false), pointer: TasksPointer())
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: page.atticDesign(context)
            .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: .desktop(.midGrey)))
            .coordinateSpace(name: AtticCaptureContext.coordinateSpace)
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return collector.all
    }

    private func probe(_ probes: [AtticProbe], _ string: String, _ style: AtticTextStyle) throws -> AtticProbe {
        try XCTUnwrap(probes.last { if case .text(style, string) = $0.kind { $0.frame != .null } else { false } },
                      "no drawn \(string) in \(probes.compactMap { if case let .text(_, s) = $0.kind { "\(s)@\($0.frame.minX)" } else { nil } })")
    }

    /// The group header reads a step lighter than the titles (design: 72
    /// against 29), dates lighter again, on Solid and on Glass; the title
    /// column sits 24 after the header (design: 19 and 43 from the edge).
    func testHeaderAndDateSitBelowTheTitleAndTheTitleColumnIsTheDesigns() throws {
        try add("Pay rent", due: 0)
        try add("Undated", due: nil)
        model.select(tab: .now)
        for surface in [PanelSurfaceStyle.solid, .glass] {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                var context = AtticDesignContext(mode: mode)
                context.surface = surface
                let reference = AtticColorTokens.resolve(context).panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
                let probes = try drawnText(context)
                let title = try probe(probes, "Pay rent", .taskTitle), header = try probe(probes, "Today", .groupHeader)
                let date = try probe(probes, "Today", .taskDate)
                func contrast(_ p: AtticProbe) throws -> Double { try XCTUnwrap(p.foreground).contrast(on: reference) }
                let label = "\(surface) \(mode)"
                // On a see-through panel the greys sit half the design's step under the
                // title (the owner's stronger greys, 10-29): a smaller, still clear step.
                let step = surface == .solid ? 1.3 : 1.25
                XCTAssertGreaterThanOrEqual(try contrast(title) / contrast(header), step, "\(label): the header a step under the title")
                XCTAssertGreaterThanOrEqual(try contrast(header), try contrast(date), "\(label): the date no stronger than the header")
                XCTAssertEqual(header.frame.minX, 19, accuracy: 0.25, "\(label): the header on the rows' padding (design 19)")
                XCTAssertEqual(title.frame.minX, 43, accuracy: 0.25, "\(label): the title column (design 43)")
            }
        }
    }

    /// The design's greys on every look: each keeps its readability floor
    /// on every background it is judged on, sits in the design's order
    /// (header, then date, then meta), never above the title, and with
    /// standard contrast the header stays a clear step under the title.
    func testTheDesignGreysKeepTheirFloorsAndTheDesignsOrderOnEveryLook() {
        var contexts = AtticAppearanceCheck.allContexts()
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                var context = AtticDesignContext(mode: mode)
                context.surface = surface
                context.reduceTransparency = true
                contexts.append(context)
            }
        }
        for context in contexts {
            let tokens = AtticColorTokens.resolve(context)
            let base = TasksPanelDesign.reference(tokens)
            let title = tokens.ink(.heading).contrast(on: base)
            var previous = title
            for tone in TasksDesignTone.allCases {
                let value = TasksPanelDesign.tone(tone, tokens: tokens)
                let worst = TasksPanelDesign.toneBackgrounds(tone, tokens: tokens).map { value.contrast(on: $0) }.min() ?? 0
                XCTAssertGreaterThanOrEqual(worst, TasksPanelDesign.toneFloor(tokens) - 0.01, "\(context.caption) \(tone): floor")
                XCTAssertLessThanOrEqual(value.contrast(on: base), previous + 0.01, "\(context.caption) \(tone): design order")
                previous = value.contrast(on: base)
            }
            if !context.increaseContrast {
                let header = TasksPanelDesign.tone(.groupHeader, tokens: tokens).contrast(on: base)
                let step = TasksPanelDesign.seeThrough(tokens) ? 1.25 : 1.3
                XCTAssertGreaterThanOrEqual(title / header, step, "\(context.caption): the header a step under the title")
            }
        }
        // On white the design's own colours come back.
        let white = AtticRGBA.white(1)
        XCTAssertEqual(pow(TasksDesignTone.designTitle.contrast(on: white), TasksDesignTone.date.designFraction),
                       TasksDesignTone.date.designColour.contrast(on: white), accuracy: 0.001)
    }

    /// One selection marker (Accepted 2026-10-30): the current tab sits on
    /// the flat grey chip every switch uses, not a raised white thumb.
    func testTheCurrentTabIsTheFlatGreyMarker() {
        let tokens = AtticColorTokens.resolve(AtticDesignContext(mode: .light))
        XCTAssertEqual(AtticSelectionMarker.fill(tokens).alpha, 0.06, accuracy: 0.001)
        // The crossfade in place: the old thumb's 160 ms ease-out.
        XCTAssertEqual(AtticSelectionMarker.animation(reduceMotion: false), .easeOut(duration: 0.16))
        XCTAssertNil(AtticSelectionMarker.animation(reduceMotion: true))
    }

    func testTheSubtaskCountIsTheDesigns() {
        XCTAssertEqual(AtticSubtaskChecklistMetrics.iconSize, 9, "18 px glyph")
        XCTAssertEqual(AtticSubtaskChecklistMetrics.iconGap, 3, "6 px gap")
        XCTAssertEqual(AtticTextStyle.taskMeta.spec.size, 11, "22 px text")
    }

    // MARK: - The design's sizes (px ÷ 2)

    func testTheDesignsSizes() {
        XCTAssertEqual(AtticControlSize.headerControl, 27, "54 px header controls")
        XCTAssertEqual(AtticControlSize.addBarHeight, 27, "one size: the bottom bar is 54 px")
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: false, count: 3), 36, "72 px shut")
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: true, count: 3), 75, "150 px open")
        XCTAssertEqual(TasksRowDesign.height(twoLine: false, tiles: false), 31, "8 + 15 + 8")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: false), 47.5, "with the meta line")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: true), 80.5, "with a line of 28 pt tiles")
        // Corners C, Accepted 2026-11-13, measured fix: the sheet's C row
        // (28 pt, its corner in a 14 pt box) is 9.5 pt continuous, at any height.
        XCTAssertEqual(TasksRowDesign.radius, 9.5)
        XCTAssertEqual(AtticRadius.taskRow, 9.5)
        // The circle stays where it was: square in the one-line row's end,
        // as far from the highlight's leading edge as from its top.
        XCTAssertEqual(AtticLayout.circleX + AtticControlSize.statusCircle / 2 - AtticLayout.rowHighlightInset, 15.5)
        XCTAssertEqual(TasksRowDesign.paddingY + TasksRowDesign.line / 2, 15.5)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.size, 12)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.weight, .medium)
        XCTAssertEqual(AtticTextStyle.taskDate.spec.size, 10)
        XCTAssertTrue(AtticTextStyle.taskDate.spec.monospacedDigits)
        XCTAssertEqual(AtticTextStyle.priorityMark.spec.weight, .bold)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: false), 0.8)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: true), 2, "Increase Contrast keeps its ring")
        XCTAssertEqual(TasksTopTabsMetrics.cell.height, 21, "Now · Backlog · Done: the top row's chips")
        XCTAssertEqual(TasksPanelDesign.tileLabel("Last invoice.pdf"), "PDF")
    }

    /// Fix round 2 (the Air, 28 Oct): the fold's turn never reached the
    /// list (kept in the page's state, then read only inside the list's
    /// content closure, which is redrawn only when what it captures
    /// changes), so the fold jumped closed and an unfold stayed closed. A turn published on the model reaches the drawn list: half
    /// way through closing, the group's rows take half their room, so the
    /// next group's first row rises by that much, and its header reads
    /// folded at once.
    func testAFoldTurnOnTheModelReachesTheDrawnList() throws {
        try add("Late one", due: -2)
        try add("Late two", due: -1)
        let today = try add("Due today", due: 0)
        model.select(tab: .now)
        let overdue = try XCTUnwrap(model.sections(for: .now).groups.first)
        XCTAssertTrue(overdue.isOverdue)
        let pointer = TasksPointer()
        let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: .constant(false), pointer: pointer)
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)); window.contentView?.layoutSubtreeIfNeeded() }
        spin()
        func top(_ id: UUID) -> CGFloat? { pointer.frames[TasksRowID(tab: .now, id: id)]?.minY }
        let lateRows = overdue.ids.compactMap { pointer.frames[TasksRowID(tab: .now, id: $0)]?.height }
        XCTAssertEqual(lateRows.count, 2, "the overdue rows are drawn")
        let open = try XCTUnwrap(top(today))
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            model.foldTurn = TasksFoldTurn(tab: .now, key: overdue.key, closing: true, headerFolded: true, progress: 0.5, generation: 1)
        }
        spin()
        let half = try XCTUnwrap(top(today))
        XCTAssertEqual(open - half, lateRows.reduce(0, +) / 2, accuracy: 1.5, "the next group rises with the closing body")
        withTransaction(quiet) {
            model.toggleGroup(overdue.key, on: .now)
            model.foldTurn = nil
        }
        spin()
        let closed = try XCTUnwrap(top(today))
        XCTAssertEqual(open - closed, lateRows.reduce(0, +), accuracy: 1.5, "folded, the rows take no room")
    }

    // MARK: - The list hang (2026-10-28)

    /// A reveal's move: the row's top to the list's top, or its bottom to
    /// the clear part's bottom (where `.bottom`'s anchor puts it).
    func testRevealDeltaLinesTheRowUpWithTheClearPart() throws {
        let viewport: CGFloat = 520, listTop: CGFloat = 45, margin: CGFloat = 42.5, clearance: CGFloat = 70.5
        let below = CGRect(x: 0, y: 480, width: 300, height: 52)
        let reveal = TasksViewport.reveal(frame: below, height: 52, viewport: viewport, listTop: listTop,
                                          bottomMargin: margin, bottomClearance: clearance)
        guard case let .bottom(fraction) = reveal else { return XCTFail("\(reveal)") }
        let delta = try XCTUnwrap(TasksViewport.revealDelta(reveal, frame: below, viewport: viewport, listTop: listTop,
                                                            bottomClearance: clearance))
        XCTAssertEqual(below.maxY - delta, viewport - clearance, accuracy: 0.001)
        // The same place `scrollTo` with the anchor would give.
        let visible = viewport - margin - listTop
        XCTAssertEqual(below.minY - delta, listTop + fraction * (visible - 52), accuracy: 0.001)
        let above = CGRect(x: 0, y: 10, width: 300, height: 32)
        XCTAssertEqual(TasksViewport.revealDelta(.minimal, frame: above, viewport: viewport, listTop: listTop,
                                                 bottomClearance: clearance), 10 - listTop)
        XCTAssertNil(TasksViewport.revealDelta(.none, frame: above, viewport: viewport, listTop: listTop,
                                               bottomClearance: clearance))
    }

    /// The reveal glides by the clip view, never by an animated
    /// `scrollTo`: it ends where it was sent (clamped to the content), and
    /// a scroll gesture moving the list takes over at once.
    func testRevealGlideMovesTheClipAndYieldsToTheGesture() {
        func makeScroll() -> NSScrollView {
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 2_000))
            scroll.documentView = document
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
            return scroll
        }
        let spring = Spring(duration: 0.4, bounce: 0)
        let scroll = makeScroll()
        let glide = TasksScrollGlide()
        glide.run(by: 300, in: scroll, spring: spring)
        XCTAssertTrue(glide.isRunning)
        glide.advance(to: 0.1)
        let midway = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(midway, 100)
        XCTAssertLessThan(midway, 400)
        glide.advance(to: spring.settlingDuration)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 400, accuracy: 0.5)
        XCTAssertFalse(glide.isRunning)

        // Clamped to the content's end.
        glide.run(by: 5_000, in: scroll, spring: spring)
        glide.advance(to: spring.settlingDuration)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1_600, accuracy: 0.5)

        // A gesture moves the list mid-glide: the glide lets go.
        let other = makeScroll()
        glide.run(by: 600, in: other, spring: spring)
        glide.advance(to: 0.05)
        other.contentView.scroll(to: CGPoint(x: 0, y: 20))
        glide.advance(to: 0.1)
        XCTAssertFalse(glide.isRunning)
        XCTAssertEqual(other.contentView.bounds.origin.y, 20, accuracy: 0.5)
    }

}
