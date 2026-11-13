import AppKit
import XCTest
@testable import Attic

/// The tag bar collapsed to "#", several tags with Any · All, and the
/// Status and Date filters in Tasks ••• (Accepted 2026-11-13, "Tag bar
/// collapsed, several tags, status filters"; the owner took every
/// recommended option).
@MainActor
final class TasksFiltersTests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
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
            now: { [clock] in clock.value }, calendar: { calendar }, locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    @discardableResult
    private func add(_ title: String, tags: [String] = [], tab: TasksTab = .now) throws -> UUID {
        model.select(tab: tab)
        model.addBar.text = title
        let id = try XCTUnwrap(model.submitAddBar())
        for tag in tags { XCTAssertTrue(model.toggleTag(tag, for: [id]).isApplied) }
        return id
    }

    private func titles(_ tab: TasksTab) -> [String] { model.rows(for: tab).map(\.model.title).sorted() }

    // MARK: - Picks

    func testAnyNeedsOneTagAndAllNeedsEvery() {
        let picks = TagPicks(["work", "home"])
        XCTAssertTrue(picks.matches(["home"]))
        XCTAssertFalse(picks.matches(["money"]))
        XCTAssertFalse(picks.matching(.all).matches(["home"]))
        XCTAssertTrue(picks.matching(.all).matches(["home", "work", "money"]))
        XCTAssertTrue(TagPicks.none.matches([]), "nothing picked shows everything")
    }

    func testPickingTogglesAndTheSwitchFallsBackToAnyUnderTwoTags() {
        let all = TagPicks(["work", "home"], match: .all)
        XCTAssertTrue(all.showsMatch)
        let one = all.toggling("home")
        XCTAssertEqual(one.tags, ["work"])
        XCTAssertEqual(one.match, .any, "one tag left: the switch hides and Any comes back")
        XCTAssertFalse(one.showsMatch)
        XCTAssertEqual(one.toggling("money").tags, ["work", "money"], "a new tag joins, in the order picked")
        XCTAssertEqual(all.toggling(nil), .none, "All clears every pick")
    }

    func testThePhraseReadsLikeTheDrawing() {
        XCTAssertEqual(TagPicks(["work", "home"]).phrase, "#work or #home")
        XCTAssertEqual(TagPicks(["work", "home"], match: .all).phrase, "#work and #home")
        XCTAssertEqual(TagPicks(["a", "b", "c"]).phrase, "#a, #b or #c")
        XCTAssertEqual(TagPicks(["work", "home"]).spokenPhrase, "work or home")
    }

    func testRenamesAndGoneTagsKeepThePickHonest() {
        let picks = TagPicks(["work", "home"], match: .all)
        XCTAssertEqual(picks.renaming(["home"], to: "house").tags, ["work", "house"])
        XCTAssertEqual(picks.renaming(["home"], to: "work").tags, ["work"], "a merge leaves one")
        XCTAssertEqual(picks.keeping(["work"]).tags, ["work"])
        XCTAssertEqual(picks.keeping([]), .none)
    }

    // MARK: - View options

    func testAViewSavedBeforeStatusStillLoads() throws {
        let saved = try JSONEncoder().encode(TasksViewOptions(show: .overdueOnly, sort: .dueDate))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        object["status"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TasksViewOptions.self, from: legacy)
        XCTAssertEqual(decoded, TasksViewOptions(status: .any, show: .overdueOnly, sort: .dueDate))
    }

    func testStatusIsANowFilterOnly() {
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .backlog)
        XCTAssertEqual(model.viewOptions(for: .backlog).status, .any, "Backlog holds only backlog tasks")
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        XCTAssertEqual(model.viewOptions(for: .now).status, .inProgress)
        XCTAssertTrue(model.filtered(on: .now))
    }

    func testStatusFiltersNow() throws {
        let started = try add("Started")
        try add("Waiting")
        XCTAssertTrue(model.setStatus(.inProgress, for: [started]).isApplied)
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        XCTAssertEqual(titles(.now), ["Started"])
        model.setViewOptions(TasksViewOptions(status: .toDo), for: .now)
        XCTAssertEqual(titles(.now), ["Waiting"])
    }

    func testShowAllKeepsTheOrderAndResetViewClearsEverything() throws {
        try add("Pay rent", tags: ["home"])
        model.setViewOptions(TasksViewOptions(status: .toDo, show: .overdueOnly, sort: .dueDate), for: .now)
        model.chooseTagChip("home")
        model.showAll(on: .now)
        XCTAssertEqual(model.viewOptions(for: .now), TasksViewOptions(sort: .dueDate))
        XCTAssertTrue(model.tagPicks.isEmpty)
        model.setViewOptions(TasksViewOptions(status: .toDo, sort: .dueDate), for: .now)
        model.chooseTagChip("home")
        model.resetView(on: .now)
        XCTAssertEqual(model.viewOptions(for: .now), TasksViewOptions())
        XCTAssertTrue(model.tagPicks.isEmpty, "Reset View clears the picked tags too")
    }

    func testTheSpokenViewNamesStatusAndTags() throws {
        try add("Pay rent", tags: ["work", "home"])
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        model.chooseTagChip("work")
        model.chooseTagChip("home")
        XCTAssertEqual(model.spokenView(on: .now), "Showing in-progress tasks in work or home")
        model.resetView(on: .now)
        XCTAssertEqual(model.spokenView(on: .now), "Showing all tasks")
    }

    // MARK: - Tags on the list

    func testSeveralTagsFilterWithAnyOrAll() throws {
        try add("Both", tags: ["work", "home"])
        try add("Work", tags: ["work"])
        try add("Home", tags: ["home"])
        try add("Neither")
        model.select(tab: .now)
        model.chooseTagChip("work")
        model.chooseTagChip("home")
        model.releaseFilterStay()
        XCTAssertEqual(titles(.now), ["Both", "Home", "Work"])
        model.setTagMatch(.all)
        model.releaseFilterStay()
        XCTAssertEqual(titles(.now), ["Both"])
        XCTAssertEqual(model.filterHiddenCount(for: .now), 3)
    }

    func testTheViewLineListsEveryFilterAndTheHiddenCount() {
        let line = TasksPanelDesign.viewLine(view: TasksViewOptions(status: .inProgress, sort: .dueDate),
                                             picks: TagPicks(["work", "home"]), hidden: 9)
        XCTAssertEqual(line.map(\.plain).joined(), "In progress · #work or #home · by due date · 9 hidden")
        XCTAssertEqual(TasksPanelDesign.viewLine(view: TasksViewOptions(), picks: TagPicks(["home"]), hidden: 0)
            .map(\.plain).joined(), "#home")
    }

    func testATaskThatStopsMatchingStaysUntilTheViewChanges() throws {
        let task = try add("Started")
        model.setViewOptions(TasksViewOptions(status: .toDo), for: .now)
        XCTAssertEqual(titles(.now), ["Started"])
        XCTAssertTrue(model.setStatus(.inProgress, for: [task]).isApplied)
        XCTAssertEqual(titles(.now), ["Started"], "it doesn't vanish under the pointer")
        model.releaseFilterStay()
        XCTAssertEqual(titles(.now), [], "the panel hid or the page changed: the filter applies")
    }

    // MARK: - "+" under a filter

    func testPlusUnderInProgressMakesAnInProgressTask() throws {
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        let id = try add("New")
        XCTAssertEqual(store.task(withID: id)?.status, .inProgress)
        XCTAssertEqual(titles(.now), ["New"])
        model.setViewOptions(TasksViewOptions(status: .toDo), for: .now)
        XCTAssertEqual(model.newOpenStatus(from: .now), .todo)
    }

    func testPlusUnderTagsStartsWithThem() throws {
        try add("Pay rent", tags: ["work", "home"])
        model.chooseTagChip("work")
        model.chooseTagChip("home")
        model.startDraftFromFilter()
        XCTAssertEqual(model.addBar.picked.tags, ["work", "home"])
        model.addBar.text = "Call"
        let id = try XCTUnwrap(model.submitAddBar())
        XCTAssertEqual(Set(store.task(withID: id)?.tags ?? []), ["work", "home"])
        XCTAssertEqual(model.addBar.picked.tags, ["work", "home"], "the next draft starts with them again")
    }

    // MARK: - Keys and Tab order

    private func action(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                        open: Bool, keyboard: Bool = true, cursor: Bool = true) -> PanelTagBarKeys.Action {
        PanelTagBarKeys.action(keyCode: keyCode, characters: characters, modifiers: modifiers,
                               isOpen: open, hasKeyboard: keyboard, hasCursor: cursor)
    }

    func testTheTagBarsKeys() {
        XCTAssertEqual(action(17, "t", [.command, .option], open: false, keyboard: false), .toggle, "⌥⌘T from anywhere")
        XCTAssertEqual(action(17, "t", [.command, .option], open: true), .toggle)
        XCTAssertEqual(action(53, "\u{1b}", open: true, keyboard: false), .close, "Esc closes the open bar first")
        XCTAssertEqual(action(53, "\u{1b}", open: false), .none, "a closed bar leaves Esc to the page")
        XCTAssertEqual(action(124, "", open: true), .move(1))
        XCTAssertEqual(action(123, "", open: true), .move(-1))
        XCTAssertEqual(action(124, "", open: true, keyboard: false), .none, "arrows stay the list's")
        XCTAssertEqual(action(49, " ", open: true), .activate)
        XCTAssertEqual(action(49, " ", open: false, cursor: false), .openOnFirst, "Space on \"#\" opens it")
        XCTAssertEqual(action(36, "\r", open: true), .close)
        XCTAssertEqual(action(17, "t", open: true), .none, "plain T types")
    }

    func testTheBarsStopsAndTheTabOrder() {
        XCTAssertEqual(PanelTagBarStop.stops(tags: ["work", "home"], picks: TagPicks(["work"])),
                       [.all, .tag("work"), .tag("home")])
        XCTAssertEqual(PanelTagBarStop.stops(tags: ["work", "home"], picks: TagPicks(["work", "home"])),
                       [.all, .tag("work"), .tag("home"), .match(.any), .match(.all)])
        XCTAssertEqual(PanelTagBarStop.first(tags: ["work"]), .tag("work"))
        XCTAssertEqual(PanelTagBarStop.first(tags: []), .all)
        let row = UUID()
        XCTAssertEqual(TasksTabOrder.stops(find: false, rows: [(row, [])], strip: false, plus: true, tagKey: true, tagMatch: true),
                       [.row(row), .tagKey, .tagMatch, .plus], "\"#\" and Any · All come before \"+\"")
    }
}
