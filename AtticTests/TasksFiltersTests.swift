import AppKit
import SwiftUI
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

    func testR1RemovingFocusedTagKeyReleasesKeyboardOwnership() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let state = PanelTagBarState()
        state.open(cursor: .tag("a"))
        func bar(_ picks: TagPicks) -> some View {
            NotesTagBar(tags: ["a"], picks: picks, state: state, onSelect: { _ in })
                .atticDesign(AtticDesignContext(mode: .light, reduceMotion: true)).frame(width: 360, height: 60)
        }
        let host = NSHostingView(rootView: bar(.none))
        let window = NSWindow(contentRect: CGRect(x: -8_000, y: -8_000, width: 360, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Stand in for the native focus callback, without taking the keyboard.
        state.noteKeyFocus(true)
        XCTAssertTrue(state.hasKeyboard)
        host.rootView = bar(TagPicks(["a"]))
        host.layoutSubtreeIfNeeded()
        state.close()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(state.keyFocused, "removing the focused # key releases its ownership")
        XCTAssertFalse(state.hasKeyboard)
        for (code, characters) in [(UInt16(49), " "), (UInt16(36), "\r")] {
            XCTAssertEqual(PanelTagBarKeys.action(keyCode: code, characters: characters, modifiers: [],
                isOpen: state.isOpen, hasKeyboard: state.hasKeyboard, hasCursor: state.cursor != nil), .none,
                "typing in Find or Notes must pass through after the focused key disappears")
        }
        try captureCatchupView(host, name: "tag-key")
        // Reopening a focused summary replaces that view too. Its removal
        // must not close the bar whose logical cursor just opened.
        state.noteKeyFocus(true)
        state.open(cursor: .tag("a"))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.cursor, .tag("a"))
        state.close()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(state.hasKeyboard)
    }

    func testR4SortStaysWithinStatusForFilteredSearchedAndAcknowledgedRows() throws {
        let started = try add("Started", tags: ["work"])
        let waiting = try add("Waiting", tags: ["work"])
        XCTAssertTrue(model.setStatus(.inProgress, for: [started]).isApplied)
        XCTAssertTrue(model.setPriority(.low, for: [started]).isApplied)
        XCTAssertTrue(model.setPriority(.high, for: [waiting]).isApplied)
        for sort: TasksViewOptions.Sort in [.priority, .dueDate] {
            model.setViewOptions(TasksViewOptions(sort: sort), for: .now)
            model.setTagPicks(TagPicks(["work"]))
            XCTAssertEqual(model.rows(for: .now).map(\.id), [started, waiting])
            model.setTagPicks(.none)
            model.setSearchQuery("t", for: .now)
            XCTAssertEqual(model.rows(for: .now).map(\.id), [started, waiting])
            model.setSearchQuery("", for: .now)
        }
        model.services.acknowledgementDelay = .seconds(3_600)
        model.setPriorityAcknowledged(.none, for: [started]) { XCTAssertTrue($0.isApplied) }
        XCTAssertEqual(model.rows(for: .now).map(\.id), [started, waiting])
        model.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(model.rows(for: .now).map(\.id), [started, waiting])
        model.setViewOptions(TasksViewOptions(sort: .priority), for: .now)
        XCTAssertEqual(model.rows(for: .now).map(\.id), [started, waiting])
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 360, height: 560)), addBarFocused: .constant(false))
        let host = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light, reduceMotion: true))
            .frame(width: 360, height: 560))
        let window = NSWindow(contentRect: CGRect(x: -8_000, y: -8_000, width: 360, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try captureCatchupView(host, name: "status-sort")
    }

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

    // MARK: - The optimistic first frame (ack-latency-2)

    private struct Shown: Equatable { let ids: [UUID]; let titles: [String]; let hidden: Int? }
    private func shown(_ tab: TasksTab) -> Shown {
        let rows = model.rows(for: tab)
        return Shown(ids: rows.map(\.id), titles: rows.map(\.model.title), hidden: model.filterHiddenCount(for: tab))
    }

    /// Runs an acknowledged command and returns the filtered tab's first
    /// frame and its settled frame.
    private func frames(_ tab: TasksTab, _ start: (@escaping () -> Void) -> Void) async throws -> (first: Shown, settled: Shown) {
        var done = false
        start { done = true }
        let first = shown(tab)
        for _ in 0..<50 where !done { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done, "the command settled")
        return (first, shown(tab))
    }

    /// A filtered tab's first frame after a create, a move or a delete
    /// shows exactly the rows its settled snapshot will: several tags with
    /// Any/All, status and date, and the just-changed stay rule.
    func testAFilteredTabsFirstFrameEqualsItsSettledSnapshot() async throws {
        let started = try add("Started", tags: ["work"])
        let parked = try add("Parked", tags: ["work"])
        let doomed = try add("Doomed", tags: ["work", "home"])
        try add("Elsewhere", tags: ["errands"])
        let later = try add("From Backlog", tags: ["home"], tab: .backlog)
        model.select(tab: .now)
        model.setViewOptions(TasksViewOptions(status: .toDo), for: .now)
        model.chooseTagChip("work")
        model.chooseTagChip("home")
        model.releaseFilterStay()
        XCTAssertEqual(titles(.now), ["Doomed", "Parked", "Started"])

        // A status change out of the filter: it stays, in both frames.
        var step = try await frames(.now) { end in self.model.setStatusAcknowledged(.inProgress, for: [started]) { _ in end() } }
        XCTAssertEqual(step.first, step.settled, "status change")
        XCTAssertTrue(step.settled.ids.contains(started))
        // Moved to Backlog: gone from Now in both.
        step = try await frames(.now) { end in self.model.moveToBacklogAcknowledged([parked]) { _ in end() } }
        XCTAssertEqual(step.first, step.settled, "move to Backlog")
        XCTAssertFalse(step.settled.ids.contains(parked))
        // Moved in from Backlog and matching: there in both.
        step = try await frames(.now) { end in self.model.moveToNowAcknowledged([later]) { _ in end() } }
        XCTAssertEqual(step.first, step.settled, "move to Now")
        XCTAssertTrue(step.settled.ids.contains(later))
        // Deleted: gone in both.
        step = try await frames(.now) { end in self.model.deleteAcknowledged([doomed]) { _ in end() } }
        XCTAssertEqual(step.first, step.settled, "delete")
        XCTAssertFalse(step.settled.ids.contains(doomed))
        // All instead of Any, then a create the filter would hide: "+"
        // keeps what it made in view, in both frames.
        model.setTagMatch(.all)
        model.releaseFilterStay()
        let library = self.library!
        step = try await frames(.now) { end in
            let draft = TaskDraft(title: "Made here", tags: ["errands"], status: self.model.newOpenStatus(from: .now))
            self.model.createAcknowledged(draft, save: { id in library.createTask(draft, writing: "", in: .tasks, id: id) }) { made in
                if let made { self.model.keepInView(made.id, on: .now) }
                end()
            }
        }
        XCTAssertEqual(step.first, step.settled, "create")
        XCTAssertTrue(step.settled.titles.contains("Made here"))
    }

    // MARK: - ••• dot

    /// The page's top row re-registers (a page rebuilt, the panel shown
    /// again) while the filter stays on: ••• keeps its dot.
    func testTheDotOutlivesTheTopRowsReRegistration() {
        let chrome = PanelSharedChrome()
        chrome.setFiltered(true, for: .tasks)
        chrome.removeTopRow(for: .tasks)
        chrome.setTopRowShown(true, for: .tasks)
        XCTAssertTrue(chrome.topRow(for: .tasks).filtered)
        chrome.setFiltered(false, for: .tasks)
        XCTAssertFalse(chrome.topRow(for: .tasks).filtered)
        XCTAssertFalse(chrome.topRow(for: .notes).filtered)
    }

    /// The dot is drawn on the shared ••• (not only told to VoiceOver).
    func testTheSharedMoreButtonDrawsItsDot() throws {
        func raster(_ filtered: Bool) throws -> Data {
            let view = PanelTopRowMoreButton(shared: true, page: .tasks, filtered: filtered) { [] }
                .padding(8)
                .atticDesign(AtticDesignContext(mode: .light))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let bytes = try XCTUnwrap(bitmap.bitmapData)
            return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        XCTAssertNotEqual(try raster(true), try raster(false), "filtered: the accent dot shows")
    }

    /// Drawing 4b: over the empty state the line under the tabs goes; the
    /// empty state names the filter and keeps Clear Filters.
    func testTheViewLineGivesWayToTheEmptyState() throws {
        try add("Pay rent", tags: ["home"])
        model.select(tab: .now)
        model.chooseTagChip("home")
        XCTAssertTrue(model.showsViewLine(on: .now))
        model.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        model.releaseFilterStay()
        XCTAssertEqual(titles(.now), [])
        XCTAssertFalse(model.showsViewLine(on: .now), "the empty state says it")
        XCTAssertTrue(TasksPanelDesign.empty(tab: .now, query: "", view: model.viewOptions(for: .now), picks: model.tagPicks).canClear)
        XCTAssertFalse(model.showsViewLine(on: .done), "Done with no matching finished tasks")
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
