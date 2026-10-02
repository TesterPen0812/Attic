import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 follow-up part 2 (the owner's decisions of 2026-09-30): Low
/// priority returns with its grey ↓ and ⌥⌘0–3, the rarer task-menu
/// commands sit under More, and a Done task's details show what it still
/// carries. The model's rules are tested directly; the keys and menus on a
/// hosted page (`Hosted`).
@MainActor
final class TasksFollowup2Tests: XCTestCase {
    // MARK: - Low priority (option A)

    func testEveryPickerOffersAllFourPrioritiesWithTheirKeys() {
        XCTAssertEqual(TaskPriority.choices, [.none, .low, .medium, .high])
        XCTAssertEqual(TaskPriority.choices.map(\.shortcut), AtticTaskShortcut.priorities)
        XCTAssertEqual(AtticTaskShortcut.priorityNone, KeyboardShortcut("0", modifiers: [.command, .option]))
        XCTAssertEqual(AtticTaskShortcut.priorityHigh, KeyboardShortcut("3", modifiers: [.command, .option]))
        XCTAssertEqual(TaskPriority.low.pickerTitle, "↓  Low")
        XCTAssertEqual(TaskPriority.low.mark, "↓")
        XCTAssertEqual(TasksComposerValues.priority(.low)?.text, "↓", "the strip shows Low's mark")
    }

    /// ⌥⌘1 is ⌥⌘1 by its key, whatever ⌥ makes the digit type, and never
    /// without both modifiers.
    func testPriorityKeysMatchTheNumberRow() {
        let low = AtticTaskShortcut.priorityLow
        XCTAssertTrue(AtticTaskShortcut.matches(low, characters: "1", keyCode: 18, modifiers: [.command, .option]))
        XCTAssertTrue(AtticTaskShortcut.matches(low, characters: "¡", keyCode: 18, modifiers: [.command, .option]),
                      "a layout whose ⌥ changes the digit")
        XCTAssertFalse(AtticTaskShortcut.matches(low, characters: "1", keyCode: 18, modifiers: .command), "⌘1 is the shell's")
        XCTAssertFalse(AtticTaskShortcut.matches(low, characters: "2", keyCode: 19, modifiers: [.command, .option]))
    }

    /// The add bar still reads `!` and `!!`; nothing typed means Low.
    func testTheShorthandStillParsesMediumAndHighAndHasNoLow() {
        let parser = TaskTextParser(calendar: .autoupdatingCurrent, locale: Locale(identifier: "en_GB"), now: Date.init)
        XCTAssertEqual(parser.parse("Call the bank !").priority, .medium)
        XCTAssertEqual(parser.parse("Call the bank !!").priority, .high)
        XCTAssertNil(parser.parse("Call the bank ↓").priority)
        XCTAssertNil(parser.parse("Call the bank low").priority)
        XCTAssertNil(TaskPriority.low.shorthand)
    }

    /// ⌥⌘1 on the selected row sets Low (one step, with its toast), ⌥⌘0
    /// takes the priority away; the row menu shows the keys.
    func testPriorityKeysSetTheSelectedTasksPriority() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        hosted.spin(0.2)
        // Each key through the app's queue; the queue is pumped until the
        // change lands (a posted key can wait behind others in a test host).
        func press(_ digit: String, _ code: UInt16, expecting priority: TaskPriority) {
            hosted.press(digit, keyCode: code, modifiers: [.command, .option])
            let deadline = Date().addingTimeInterval(2)
            while hosted.store.task(withID: row.id)?.priority != priority, Date() < deadline {
                Hosted.pumpEvents()
                hosted.spin(0.05)
            }
            XCTAssertEqual(hosted.store.task(withID: row.id)?.priority, priority, "⌥⌘\(digit)")
        }
        press("1", 18, expecting: .low)
        press("3", 20, expecting: .high)
        press("0", 29, expecting: .none)

        let priority = try XCTUnwrap(hosted.page.taskCommands(row.id, tab: .now).first { $0.title == "Priority" })
        XCTAssertEqual(priority.children.map(\.title), TaskPriority.choices.map(\.menuTitle))
        XCTAssertEqual(priority.children.compactMap(\.menuShortcut), AtticTaskShortcut.priorities, "active menu keys")
    }

    // MARK: - L5: the rarer commands under More

    /// The top level keeps the common actions; Open Files…, Move Up and
    /// Move Down sit under More with their keys, and the keys still find
    /// them in the one list.
    func testTheRarerCommandsSitUnderMoreWithTheirKeys() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let commands = hosted.page.taskCommands(row.id, tab: .now)
        let top = commands.map(\.title)
        XCTAssertEqual(top, ["Complete", "Start Working", "Edit Title", "Date", "Tags", "Priority", "Move to Later",
                             "Add Subtask", "Copy", "Duplicate", "More", "Delete"])
        let more = try XCTUnwrap(commands.first { $0.title == "More" })
        XCTAssertEqual(more.children.map(\.title), ["Open Files…", "Move Up", "Move Down"])
        XCTAssertEqual(more.children.map(\.shortcut), [AtticTaskShortcut.openPage, AtticTaskShortcut.moveUp, AtticTaskShortcut.moveDown])
        // Call the plumber is the last to do: Move Down is off, Move Up runs.
        XCTAssertEqual(more.children.map(\.isDisabled), [false, false, true])
        XCTAssertEqual(AtticMenuCommand.command(for: AtticTaskShortcut.moveUp, in: commands)?.title, "Move Up")
        XCTAssertEqual(AtticMenuCommand.command(key: .upArrow, characters: "", modifiers: .command, in: commands)?.title, "Move Up")
        // The native menu keeps the sections inside More.
        let menu = AtticNativeMenu.make(commands)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu)
        XCTAssertEqual(submenu.items.map { $0.isSeparatorItem ? "—" : $0.title }, ["Open Files…", "—", "Move Up", "Move Down"])
    }

    // MARK: - L6: a Done task's details show its metadata

    func testDoneMetadataReadsDatePriorityAndTags() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let task = try XCTUnwrap(store.create(title: "Pay rent", priority: .high))
        XCTAssertNil(model.doneMetadata(for: try XCTUnwrap(store.create(title: "Plain"))), "nothing to show")
        let day = try XCTUnwrap(DueDay(rawValue: "2031-03-04"))
        XCTAssertTrue(model.library.updateTask(task.id, tags: ["home", "bills"], dueDay: .some(day)).isApplied)
        let metadata = try XCTUnwrap(model.doneMetadata(for: try XCTUnwrap(store.task(withID: task.id))))
        XCTAssertTrue(metadata.hasPrefix("Due "), metadata)
        XCTAssertTrue(metadata.contains("!! High"), metadata)
        XCTAssertTrue(metadata.contains("#home") && metadata.contains("#bills"), metadata)
    }

    /// ⌘Return (or Show Details) on a Done row finished today opens its
    /// details in place, as a Done log task's do; a date changed there
    /// shows in them.
    func testADoneTodayRowShowsItsDetailsWithTheEditedDate() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .done)
        let row = try XCTUnwrap(hosted.model.doneDays().flatMap(\.rows).first { $0.model.title == "Renew domain" })
        XCTAssertNotNil(hosted.store.task(withID: row.id), "still in Now's done group")
        let day = try XCTUnwrap(DueDay(rawValue: "2031-03-04"))
        XCTAssertTrue(hosted.model.setDueDay(day, for: [row.id]).isApplied)
        hosted.page.actions(for: row.id, in: .done).openPage()
        XCTAssertEqual(hosted.model.doneDetailID, row.id, "its details open")
        let detail = try XCTUnwrap(hosted.model.doneDetail(for: row.id))
        XCTAssertEqual(detail.metadata?.hasPrefix("Due "), true, "the edited date shows: \(String(describing: detail.metadata))")
        let titles = AtticMenuCommand.titles(in: hosted.page.taskCommands(row.id, tab: .done))
        XCTAssertTrue(titles.contains("Close Details"), "\(titles)")
        hosted.page.actions(for: row.id, in: .done).openPage()
        XCTAssertNil(hosted.model.doneDetailID, "⌘Return again closes them")
    }
}

/// Item 6 (option A): Find and View Options on Now and Later. The view's
/// rules on the model (filters, sorts, each page its own, the manual order
/// kept, reorders among what is shown), and the keys and menus on a hosted
/// page.
@MainActor
final class TasksViewOptionsTests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var store: TaskStore!
    private var model: TasksPageModel!
    private var today: DueDay { DueDay(date: clock.value, calendar: .autoupdatingCurrent) }

    override func setUp() async throws {
        let clock = clock
        store = try makeTestStore(now: { clock.value })
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices(now: { clock.value }))
    }

    override func tearDown() {
        model = nil
        store = nil
    }

    private func day(_ offset: Int) -> DueDay {
        DueDay(date: clock.value.addingTimeInterval(TimeInterval(offset) * 86_400), calendar: .autoupdatingCurrent)
    }

    @discardableResult
    private func make(_ title: String, _ priority: TaskPriority = .none, due: Int? = nil,
                      status: TaskStatus = .todo) throws -> TaskItem {
        let task = try XCTUnwrap(store.create(title: title, priority: priority, status: status))
        if let due { XCTAssertTrue(model.library.updateTask(task.id, dueDay: .some(day(due))).isApplied) }
        return task
    }

    private func titles(_ tab: TasksTab = .now) -> [String] {
        model.rows(for: tab).map(\.model.title)
    }

    /// Five tasks on Now (the mockup's): the filters show what they say,
    /// Now's view leaves Later alone, and the store's order never changes.
    func testFiltersAndSortsAreViewsOnly() throws {
        // New tasks go to the top: made last to first.
        try make("E high", .high)
        try make("D low next week", .low, due: 6)
        try make("C tomorrow", .high, due: 1)
        try make("B overdue", .medium, due: -2)
        try make("A plain")
        try make("Later one", status: .backlog)
        let manual = titles()
        XCTAssertEqual(manual, ["A plain", "B overdue", "C tomorrow", "D low next week", "E high"])
        var view = TasksViewOptions()
        view.show = .dueOrOverdue
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(), ["B overdue", "C tomorrow", "D low next week"])
        view.show = .overdueOnly
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(), ["B overdue"])
        view = TasksViewOptions(priority: .mediumAndHigh)
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(), ["B overdue", "C tomorrow", "E high"])
        view.priority = .highOnly
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(), ["C tomorrow", "E high"])
        XCTAssertTrue(model.viewOptions(for: .now).filters)
        XCTAssertEqual(titles(.backlog), ["Later one"], "Later keeps its own view")
        XCTAssertTrue(model.viewOptions(for: .backlog).isDefault)

        model.setViewOptions(TasksViewOptions(sort: .dueDate), for: .now)
        XCTAssertEqual(titles(), ["B overdue", "C tomorrow", "D low next week", "A plain", "E high"],
                       "earliest first, undated after, ties in manual order")
        model.setViewOptions(TasksViewOptions(sort: .priority), for: .now)
        XCTAssertEqual(titles(), ["C tomorrow", "E high", "B overdue", "D low next week", "A plain"])
        XCTAssertFalse(model.reorders(on: .now), "a sorted list does not reorder")
        model.setViewOptions(TasksViewOptions(), for: .now)
        XCTAssertEqual(titles(), manual, "Manual Order shows the order as it was")
        XCTAssertTrue(model.reorders(on: .now))
    }

    /// Sorting keeps the states apart: started tasks stay on top.
    func testSortingKeepsStartedTasksOnTop() throws {
        try make("Todo soon", due: 1)
        let started = try make("Started late", due: 9)
        XCTAssertTrue(model.library.updateTask(started.id, status: .inProgress).isApplied)
        model.setViewOptions(TasksViewOptions(sort: .dueDate), for: .now)
        XCTAssertEqual(titles(), ["Started late", "Todo soon"])
    }

    /// Now's "Completed today" is never filtered; rows the view hides leave
    /// the selection; Show All drops the filters and keeps the order.
    func testFiltersLeaveCompletedTodayAndPruneTheSelection() throws {
        let plain = try make("Plain")
        let dated = try make("Dated", due: 2)
        let done = try make("Finished")
        XCTAssertTrue(model.complete(done.id).isApplied)
        model.releaseHold(done.id)
        model.selectCopies([plain.id, dated.id])
        model.setViewOptions(TasksViewOptions(show: .dueOrOverdue, sort: .priority), for: .now)
        XCTAssertEqual(model.sections(for: .now).open.map(\.id), [dated.id])
        XCTAssertEqual(model.sections(for: .now).done.map(\.id), [done.id], "Completed today stays whole")
        XCTAssertEqual(model.selection, [dated.id], "a hidden row leaves the selection")
        model.showAll(on: .now)
        XCTAssertEqual(model.viewOptions(for: .now), TasksViewOptions(sort: .priority), "Show All keeps the order")
    }

    /// Find on Now: the open tasks whose title matches, marked, with the
    /// count; finished ones are Done's to find. Each page its own query.
    func testFindOnNowFiltersAndCounts() throws {
        try make("Book dentist")
        try make("Call the plumber")
        try make("Book flights", status: .backlog)
        let done = try make("Book club")
        XCTAssertTrue(model.complete(done.id).isApplied)
        model.releaseHold(done.id)
        model.setSearchQuery("book", for: .now)
        XCTAssertEqual(titles(), ["Book dentist"])
        XCTAssertEqual(model.rows(for: .now).first?.model.titleMatch, "book", "the match is marked")
        XCTAssertTrue(model.sections(for: .now).done.isEmpty, "finished tasks are Done's to find")
        XCTAssertEqual(model.listSearchCount(for: .now)?.matches, 1)
        XCTAssertEqual(model.listSearchCount(for: .now)?.total, 2)
        XCTAssertEqual(titles(.backlog), ["Book flights"], "Later's list is not searched")
        XCTAssertEqual(model.searchQuery(for: .backlog), "")
        XCTAssertTrue(model.narrows(.now))
        XCTAssertEqual(model.searchPlaceholder(for: .now), "Search Now")
        XCTAssertEqual(model.searchPlaceholder(for: .backlog), "Search Later")
    }

    /// In Manual Order with a filter, a move goes one place among the rows
    /// shown; the hidden ones keep their places.
    func testAReorderInAFilteredViewMovesAmongTheShownRows() throws {
        let third = try make("Third", .high)
        try make("Hidden")
        let first = try make("First", .high)
        model.setViewOptions(TasksViewOptions(priority: .highOnly), for: .now)
        let shown = model.rows(for: .now).map(\.id)
        XCTAssertEqual(shown, [first.id, third.id])
        XCTAssertTrue(model.moveVisible(third.id, toShownIndex: 0, in: shown).isApplied)
        model.setViewOptions(TasksViewOptions(), for: .now)
        XCTAssertEqual(titles(), ["Third", "First", "Hidden"], "Third went above First; Hidden stays below them")
        model.setViewOptions(TasksViewOptions(priority: .highOnly), for: .now)
        let again = model.rows(for: .now).map(\.id)
        XCTAssertTrue(model.moveVisible(third.id, toShownIndex: 1, in: again).isApplied)
        model.setViewOptions(TasksViewOptions(), for: .now)
        XCTAssertEqual(titles(), ["First", "Third", "Hidden"])
    }

    /// An agent's `show` of a task the view or Find hides: the filters and
    /// the query give way, the order stays.
    func testShowRevealsATaskTheViewHides() throws {
        try make("Dated", due: 1)
        let plain = try make("Plain")
        model.setViewOptions(TasksViewOptions(show: .dueOrOverdue, sort: .dueDate), for: .now)
        model.setSearchQuery("dat", for: .now)
        XCTAssertEqual(model.show(plain.id), .shown)
        XCTAssertEqual(model.searchQuery(for: .now), "")
        XCTAssertEqual(model.viewOptions(for: .now), TasksViewOptions(sort: .dueDate))
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == plain.id })
    }

    /// A page kept built redraws when its own view changes, not another's.
    func testTheKeptPagesTokenFollowsItsOwnView() throws {
        try make("One")
        let later = model.pageToken(.backlog)
        let now = model.pageToken(.now)
        model.setViewOptions(TasksViewOptions(sort: .priority), for: .now)
        XCTAssertEqual(model.pageToken(.backlog), later)
        XCTAssertNotEqual(model.pageToken(.now), now)
        model.setSearchQuery("o", for: .backlog)
        XCTAssertNotEqual(model.pageToken(.backlog), later)
    }

    /// The summary and VoiceOver value say what is shown.
    func testTheViewSaysWhatItShows() {
        XCTAssertEqual(TasksViewOptions(show: .dueOrOverdue, sort: .dueDate).summary, "Due or overdue · by due date")
        XCTAssertEqual(TasksViewOptions().spokenValue, "All tasks, manual order")
        XCTAssertEqual(TasksViewOptions(priority: .highOnly).summary, "High priority only")
        XCTAssertFalse(TasksViewOptions(sort: .priority).filters, "a sort hides nothing: no dot")
    }

    // MARK: - On the page

    /// The hosted window has the keyboard (a key's route checks it).
    private func makeKey(_ hosted: Hosted) {
        let deadline = Date().addingTimeInterval(2)
        while !hosted.window.isKeyWindow, Date() < deadline {
            NSApp.activate()
            hosted.window.makeKeyAndOrderFront(nil)
            hosted.spin(0.1)
        }
        XCTAssertTrue(hosted.window.isKeyWindow, "the test window is key")
    }

    /// The View Options menu: Show, the priority filter, Sort by, Reset
    /// View, the current choices ticked; a choice changes only that page.
    func testTheViewOptionsMenu() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let commands = hosted.page.viewCommands(for: .now)
        XCTAssertEqual(commands.map(\.title), ["Show", "All Tasks", "Due or Overdue", "Overdue Only",
                                               "Any Priority", "Medium and High", "High Only",
                                               "Sort by", "Manual Order", "Due Date", "Priority", "Reset View"])
        XCTAssertEqual(commands.filter { $0.state == .on }.map(\.title), ["All Tasks", "Any Priority", "Manual Order"])
        XCTAssertEqual(commands.last?.isDisabled, true, "nothing to reset")
        commands.first { $0.title == "Due Date" }?.action()
        XCTAssertEqual(hosted.model.viewOptions(for: .now).sort, .dueDate)
        XCTAssertTrue(hosted.model.viewOptions(for: .backlog).isDefault)
        let again = hosted.page.viewCommands(for: .now)
        XCTAssertEqual(again.filter { $0.state == .on }.map(\.title), ["All Tasks", "Any Priority", "Due Date"])
        again.last?.action()
        XCTAssertTrue(hosted.model.viewOptions(for: .now).isDefault, "Reset View")
    }

    /// ⌥⌘V is View Options' on Now and Later, never Done's; ⌘F is Find's
    /// on every page.
    func testTheKeysBelongToTheRightPages() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        func event(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        makeKey(hosted)
        let v = event("v", 9, [.command, .option])
        XCTAssertTrue(TasksPage.answersViewOptions(event: v, pageShown: true, tab: .now, pageWindow: hosted.window, popoverOpen: false))
        XCTAssertTrue(TasksPage.answersViewOptions(event: v, pageShown: true, tab: .backlog, pageWindow: hosted.window, popoverOpen: false))
        XCTAssertFalse(TasksPage.answersViewOptions(event: v, pageShown: true, tab: .done, pageWindow: hosted.window, popoverOpen: false))
        XCTAssertFalse(TasksPage.answersViewOptions(event: v, pageShown: false, tab: .now, pageWindow: hosted.window, popoverOpen: false))
        XCTAssertFalse(TasksPage.answersViewOptions(event: event("v", 9, .command), pageShown: true, tab: .now,
                                                    pageWindow: hosted.window, popoverOpen: false), "⌘V is Paste")
        let f = event("f", 3, .command)
        for tab in TasksTab.allCases {
            XCTAssertTrue(TasksPage.answersFind(event: f, pageShown: true, tab: tab, pageWindow: hosted.window, popoverOpen: false))
        }
    }

    /// ⌘F on Now, typing, the match shown with the count; ↓ gives the
    /// keyboard to the first match; Esc there ends the search.
    func testFindOnNowWithTheKeys() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        makeKey(hosted)
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(hosted.searchHasKeyboard, "⌘F opens Now's Find")
        hosted.press("b", keyCode: 11)
        hosted.press("o", keyCode: 31)
        XCTAssertEqual(hosted.model.searchQuery(for: .now), "bo")
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.model.title), ["Book dentist"])
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertFalse(hosted.searchHasKeyboard, "↓ leaves the field")
        XCTAssertEqual(hosted.model.selection.count, 1, "the first match is the keyboard's")
        hosted.press("\u{1B}", keyCode: 53)
        XCTAssertEqual(hosted.model.searchQuery(for: .now), "", "Esc ends the search")
    }

    /// A sorted view: ⌘↑ moves nothing (the hint says why), the menu's
    /// Move Up is off, VoiceOver has no Move up.
    func testASortedViewDoesNotReorder() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.model.setViewOptions(TasksViewOptions(sort: .priority), for: .now)
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        let before = hosted.store.snapshot(for: .tasks).sections.flatMap(\.tasks).map(\.id)
        hosted.model.selectOnly(row.id)
        makeKey(hosted)
        hosted.press("\u{F700}", keyCode: 126, modifiers: .command)
        XCTAssertEqual(hosted.store.snapshot(for: .tasks).sections.flatMap(\.tasks).map(\.id), before, "nothing moved")
        let more = try XCTUnwrap(hosted.page.taskCommands(row.id, tab: .now).first { $0.title == "More" })
        XCTAssertEqual(more.children.first { $0.title == "Move Up" }?.isDisabled, true)
        XCTAssertNil(hosted.page.actions(for: row.id, in: .now).moveUp)
    }
}

/// L7: the Tasks page remembers its page and each page's view across
/// relaunch (a new model over the same defaults), and a reveal opens on
/// the page last used.
@MainActor
final class TasksPageMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "com.taha.Attic.tests.tasks-memory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testThePageAndViewsSurviveARelaunch() throws {
        let store = try makeTestStore()
        let memory = TasksPageMemory(defaults: defaults)
        let first = TasksPageModel(library: AtticLibrary(tasks: store), memory: memory)
        XCTAssertEqual(first.tab, .now, "a first launch opens on Now")
        first.select(tab: .backlog)
        first.setViewOptions(TasksViewOptions(show: .dueOrOverdue, sort: .dueDate), for: .now)

        let relaunched = TasksPageModel(library: AtticLibrary(tasks: store), memory: TasksPageMemory(defaults: defaults))
        XCTAssertEqual(relaunched.tab, .backlog, "relaunched on Later")
        XCTAssertEqual(relaunched.viewOptions(for: .now), TasksViewOptions(show: .dueOrOverdue, sort: .dueDate))
        XCTAssertTrue(relaunched.viewOptions(for: .backlog).isDefault)
        relaunched.resetForReveal()
        XCTAssertEqual(relaunched.tab, .backlog, "a reveal opens on the page last used")

        relaunched.setViewOptions(TasksViewOptions(), for: .now)
        XCTAssertNil(defaults.data(forKey: "AtticTasksPanel.views"), "the default view stores nothing")
    }

    /// Search opens Done for that reveal; the next reveal is where the
    /// person left it, and without a memory it is Now as before.
    func testWithoutAMemoryARevealOpensOnNow() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .backlog)
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)
    }

    /// Nonsense in the defaults is ignored.
    func testUnreadableMemoryIsIgnored() {
        defaults.set(42, forKey: "AtticTasksPanel.page")
        defaults.set(Data("x".utf8), forKey: "AtticTasksPanel.views")
        let memory = TasksPageMemory(defaults: defaults)
        XCTAssertNil(memory.page)
        XCTAssertTrue(memory.viewOptions.isEmpty)
    }
}

/// L1–L4 (the owner's look decisions of 2026-09-30): the tab underline,
/// the keyboard row's 1 pt line, the flat corner buttons, and Dark Glass
/// and Frosted's one-step-firmer circles and icons.
@MainActor
final class TasksLookDecisionTests: XCTestCase {
    private func tokens(_ mode: AtticDesignContext.Mode, _ surface: PanelSurfaceStyle, ic: Bool = false) -> AtticColorTokens {
        var context = AtticDesignContext(mode: mode)
        context.surface = surface
        context.increaseContrast = ic
        return context.tokens
    }

    func testL4StepsOnlyDarkGlassAndFrosted() {
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            let dark = tokens(.dark, surface)
            XCTAssertEqual(dark.openRing().alpha, 0.46, accuracy: 0.001, "\(surface)")
            // The icons already render at #B2B2B2 (tuned to 3 : 1), lighter
            // than the approved #A8A8A8 step: they stay as they are.
            XCTAssertGreaterThanOrEqual(dark.ink(.icon).contrast(on: dark.panel.base),
                                        AtticRGBA(0xA8A8A8).contrast(on: dark.panel.base), "\(surface)")
            XCTAssertEqual(dark.ink(.chevron), dark.ink(.icon), "\(surface)")
        }
        let solid = tokens(.dark, .solid)
        XCTAssertEqual(solid.openRing().alpha, 0.28, accuracy: 0.001, "Dark Solid unchanged")
        let light = tokens(.light, .glass)
        XCTAssertEqual(light.openRing().alpha, 0.30, accuracy: 0.001, "Light unchanged")
    }

    func testL1ToL3Metrics() {
        XCTAssertEqual(AtticPageTabsMetrics.underlineHeight, 2)
        XCTAssertEqual(AtticRingMetrics.rowLineWidth, 1)
        XCTAssertEqual(AtticFlatSurfaceMetrics.hairline, 1)
    }
}

/// CI run 1: the UI test's tab sequence (every page from every other).
@MainActor
final class TasksTabSequenceTests: XCTestCase {
    func testEveryTabFromEveryOther() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        for (from, to) in [(TasksTab.now, TasksTab.backlog), (.now, .done), (.backlog, .now), (.backlog, .done), (.done, .now), (.done, .backlog)] {
            hosted.go(to: from)
            hosted.go(to: to)
            XCTAssertEqual(hosted.model.tab, to)
            XCTAssertEqual(hosted.shownPage(), TasksTab.allCases.firstIndex(of: to), "\(from) → \(to)")
        }
    }
}
