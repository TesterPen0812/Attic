import AppKit
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
        XCTAssertNil(tomorrow.model.due, "under a day header a row shows no date (Attic's tasks have no time)")
        XCTAssertEqual(model.rows(for: .now).first?.model.due?.tone, .overdue)
        try add("Idea", due: 5, tab: .backlog)
        try add("Someday", due: nil, tab: .backlog)
        XCTAssertEqual(headers(.backlog).last, "No date")
        XCTAssertEqual(headers(.backlog).count, 2)
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
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: false).title, "Nothing scheduled")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .done, query: "", filtered: false),
                       .init(title: "Nothing completed yet", body: "Tasks you check off show up here.", canClear: false))
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
        XCTAssertEqual(model.tagFilter, "home")
        XCTAssertEqual(Set(titles(.now)), ["Pay rent", "Pay gym"])
        XCTAssertTrue(model.narrows(.now), "a tag narrows the list (reorders move among what is shown)")
        var view = model.viewOptions(for: .now)
        view.priority = .highOnly
        model.setViewOptions(view, for: .now)
        XCTAssertEqual(titles(.now), ["Pay gym"], "the tag and the View options both match")
        model.showAll(on: .now)
        model.setSearchQuery("rent", for: .now)
        XCTAssertEqual(titles(.now), ["Pay rent"], "the tag and the search both match")
        model.setSearchQuery("flights", for: .now)
        XCTAssertEqual(titles(.now), [], "the search alone would show Book flights")
        model.setSearchQuery("", for: .now)
        model.chooseTagChip("travel")
        XCTAssertEqual(titles(.now), ["Book flights"], "one tag at a time")
        model.chooseTagChip("travel")
        XCTAssertNil(model.tagFilter, "the chosen tag again clears it")
        model.chooseTagChip("home")
        model.chooseTagChip(nil)
        XCTAssertNil(model.tagFilter, "All clears it")
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
        XCTAssertEqual(model.tagFilter, "house", "a rename follows")
        model.pruneTagFilter()
        XCTAssertEqual(model.tagFilter, "house")
        XCTAssertEqual(titles(.now), ["Pay rent"])
        XCTAssertTrue(library.deleteTag("house"))
        model.pruneTagFilter()
        XCTAssertNil(model.tagFilter, "a deleted tag clears it")
        XCTAssertEqual(titles(.now).count, 2)
        model.chooseTagChip("travel")
        XCTAssertTrue(library.mergeTags(["travel"], into: "trips"))
        XCTAssertEqual(model.tagFilter, "trips", "a merge follows too")
        tag(b, "trips") // its only task loses it
        let settled = expectation(description: "the change has been seen")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 2)
        XCTAssertNil(model.tagFilter, "the last task losing the tag clears it on its own")
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
        XCTAssertEqual(open, shut, accuracy: 1, "no chip row opens under the top row")
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

    func testTheTagEmptyStateUsesTheDesignsWording() {
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "", filtered: false, tag: "home"),
                       .init(title: "No results", body: "No tasks in #home in this view.", canClear: true))
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "milk", filtered: false, tag: "home").body,
                       "No tasks match “milk”.", "the search's wording first")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: true, tag: nil).body, "Nothing in this view.")
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
        XCTAssertEqual(TasksTopTabsMetrics.markerOffset(index: 0), 0)
        XCTAssertEqual(TasksTopTabsMetrics.markerOffset(index: 2), 2 * (42 + 1), "the marker slides under the words")
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
        XCTAssertEqual(TasksRowDesign.height(twoLine: false, tiles: false), 29, "7 + 15 + 7")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: false), 45.5, "with the meta line")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: true), 78.5, "with a line of 28 pt tiles")
        XCTAssertEqual(TasksRowDesign.radius, 12)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.size, 12)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.weight, .medium)
        XCTAssertEqual(AtticTextStyle.taskDate.spec.size, 10)
        XCTAssertTrue(AtticTextStyle.taskDate.spec.monospacedDigits)
        XCTAssertEqual(AtticTextStyle.priorityMark.spec.weight, .bold)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: false), 0.8)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: true), 2, "Increase Contrast keeps its ring")
        XCTAssertEqual(TasksTopTabsMetrics.width, 134, "Now · Later · Done: 3 + 3 × 42 + 2 + 3")
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
