import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 6: the owner's decided design changes and the two navigation bugs
/// found by hand (a hard swipe crossing pages, a click on Done landing on
/// Later), plus Done rows taking clicks.
@MainActor
final class TasksRound6Tests: XCTestCase {
    // MARK: - One swipe, one page, from where it started (the owner's item 21)

    private let width: CGFloat = 320

    /// The whole phase sequence of a hard swipe from Now: the gesture's
    /// page is taken when the pager leaves idle, every projected target is
    /// clamped to it, nothing changes the tab until the pager is idle, and
    /// then the tab is Later.
    func testAHardSwipeFromNowStopsAtLaterThroughEveryPhase() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 0, width: width)
        XCTAssertNil(swipe.phaseChanged(to: .interacting, shown: 0))
        XCTAssertEqual(swipe.origin, 0, "the swipe's page is taken as it starts")
        // The fingers carry the pager past halfway; it reports Later.
        swipe.geometry.offset = width * 0.7
        swipe.report(1)
        XCTAssertEqual(swipe.shownDuringSwipe, .backlog, "a redraw mid-swipe keeps the pager where the fingers are")
        // Released hard: the momentum projects far past Done.
        XCTAssertEqual(target(10 * width, swipe), 1, "the projected target is clamped to Later")
        XCTAssertNil(swipe.phaseChanged(to: .decelerating, shown: 0), "no tab changes while it moves")
        XCTAssertEqual(swipe.origin, 0, "the clamp does not move with the pager")
        swipe.geometry.offset = width * 1.6
        XCTAssertEqual(target(3 * width, swipe), 1, "asked again mid-momentum, still Later")
        XCTAssertNil(swipe.phaseChanged(to: .animating, shown: 0))
        swipe.geometry.offset = width
        XCTAssertEqual(swipe.phaseChanged(to: .idle, shown: 0), 1, "settled: the tab becomes Later")
        XCTAssertNil(swipe.origin)
        XCTAssertNil(swipe.shownDuringSwipe)
    }

    func testAHardSwipeFromDoneStopsAtLater() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 2 * width, width: width)
        XCTAssertNil(swipe.phaseChanged(to: .tracking, shown: 2))
        XCTAssertEqual(target(-8 * width, swipe), 1)
        swipe.geometry.offset = width
        XCTAssertEqual(swipe.phaseChanged(to: .idle, shown: 2), 1)
    }

    /// Even if a scroll went two pages (it should not), the tab it settles
    /// on is one page from the start, and the pager is brought back to it.
    func testASwipeThatOvershotSettlesOnePageAway() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 0, width: width)
        _ = swipe.phaseChanged(to: .interacting, shown: 0)
        swipe.geometry.offset = 2 * width
        XCTAssertEqual(swipe.phaseChanged(to: .idle, shown: 0), 1)
    }

    func testAShortOrGentleSwipeSettlesAsItShould() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 0, width: width)
        _ = swipe.phaseChanged(to: .interacting, shown: 1)
        XCTAssertEqual(target(width * 1.4, swipe), 1, "a short drag settles back")
        XCTAssertEqual(target(width * 0.4, swipe), 0, "past halfway it turns the page")
        swipe.geometry.offset = width
        XCTAssertEqual(swipe.phaseChanged(to: .idle, shown: 1), 1, "settled back where it began")
        XCTAssertEqual(TasksPagerSwipe.page(proposed: 500, width: 0, origin: 1, count: 3), 1, "no width yet: stay")
        XCTAssertEqual(TasksPagerSwipe.page(proposed: 3 * width, width: width, origin: 2, count: 3), 2, "never past the last page")
        XCTAssertEqual(TasksPagerSwipe.page(proposed: -width, width: width, origin: 0, count: 3), 0, "nor before the first")
    }

    // MARK: - A page chosen any other way is never clamped (the owner's item 22)

    /// A tab click, a key, `show` or Search scrolls the pager (`.animating`
    /// from `.idle`): no origin, so Done from Now lands on Done, and the
    /// pager's idle again selects nothing.
    func testATabClickIsNeverClampedToOnePage() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 0, width: width)
        XCTAssertNil(swipe.phaseChanged(to: .animating, shown: 2))
        XCTAssertNil(swipe.origin)
        XCTAssertEqual(target(2 * width, swipe), 2, "Done from Now lands on Done")
        swipe.geometry.offset = 2 * width
        XCTAssertNil(swipe.phaseChanged(to: .idle, shown: 2), "a scroll no one swiped selects nothing")
        XCTAssertNil(swipe.phaseChanged(to: .animating, shown: 0))
        XCTAssertEqual(target(0, swipe), 0, "Now from Done lands on Now")
        swipe.report(1)
        XCTAssertNil(swipe.shownDuringSwipe, "its reports never move the pager's binding")
    }

    func testAPageChosenDuringASwipeWins() {
        let swipe = TasksPagerSwipe(count: 3)
        swipe.geometry = .init(offset: 0, width: width)
        _ = swipe.phaseChanged(to: .interacting, shown: 0)
        swipe.cancel()
        XCTAssertEqual(target(2 * width, swipe), 2, "unclamped once another way chose the page")
        XCTAssertNil(swipe.phaseChanged(to: .idle, shown: 2))
    }

    private func target(_ x: CGFloat, _ swipe: TasksPagerSwipe) -> Int {
        TasksPagerSwipe.page(proposed: x, width: width, origin: swipe.origin, count: swipe.count)
    }

    // MARK: - The real pager: every tab from every other

    /// The page hosted in a window, as the panel hosts it: selecting a tab
    /// (as a click does, with its slide) scrolls the pager exactly there.
    func testEveryTabLandsOnItsOwnPageFromEveryOther() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let tabs = TasksTab.allCases
        for from in tabs {
            for to in tabs where to != from {
                hosted.go(to: from)
                XCTAssertEqual(hosted.shownPage(), tabs.firstIndex(of: from), "on \(from)")
                hosted.go(to: to)
                XCTAssertEqual(hosted.model.tab, to)
                XCTAssertEqual(hosted.shownPage(), tabs.firstIndex(of: to), "\(to) from \(from) lands on \(to)")
            }
        }
    }

    // MARK: - Done rows take clicks (the owner's item 23)

    /// The Done log's rows are selected by a click, ⇧-click extends and
    /// ⌘-click toggles, as on Now and Later, including the row resting just
    /// above the add bar (round 5's CI: "Pay rent" sat in the lists' bottom
    /// margin, where a scroll view takes no clicks). Restore on the
    /// selection is one step.
    func testDoneRowsAreClickSelectableAndRestoreTogether() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .done)
        let places = hosted.rowPlaces()
        for title in ["Send invoice", "Water the plants", "Call the bank", "Pay rent"] {
            XCTAssertNotNil(places[title], "a click selects \(title) (found \(places))")
        }
        let order = hosted.model.doneDays().flatMap(\.rows)
        let id = { (title: String) in order.first { $0.model.title == title }!.id }
        hosted.model.clearSelection()
        hosted.click(y: places["Water the plants"]!)
        XCTAssertEqual(hosted.model.selection, [id("Water the plants")])
        hosted.click(y: places["Pay rent"]!, modifiers: .shift)
        let from = order.firstIndex { $0.model.title == "Water the plants" }!
        let to = order.firstIndex { $0.model.title == "Pay rent" }!
        XCTAssertEqual(hosted.model.selection, Set(order[from...to].map(\.id)), "⇧-click extends")
        hosted.click(y: places["Call the bank"]!, modifiers: .command)
        XCTAssertFalse(hosted.model.selection.contains(id("Call the bank")), "⌘-click takes one out")
        let selected = hosted.model.orderedSelection()
        XCTAssertEqual(selected, order.map(\.id).filter(hosted.model.selection.contains), "in the log's order")

        hosted.page.actions(for: id("Pay rent"), in: .done).restoreToNow?()
        for task in selected {
            XCTAssertNotEqual(hosted.store.listedTask(withID: task)?.status, .done, "restored together")
        }
        hosted.model.undo()
        for task in selected {
            XCTAssertEqual(hosted.store.listedTask(withID: task)?.status, .done, "one undo puts every one back")
        }
    }

    func testTheClearPartOfTheListRunsToTheBottomStack() {
        let margin = TasksViewport.bottomMargin(bottomInset: 12)
        XCTAssertEqual(margin, AtticControlSize.addBarHeight + 12, "only the add bar's zone is margin")
        let clearance = TasksViewport.bottomClearance(stackHeight: TasksViewport.reservedStack, bottomInset: 12)
        let row = CGRect(x: 0, y: 200, width: 300, height: 34)
        func reveal(_ frame: CGRect?) -> TasksViewport.Reveal {
            TasksViewport.reveal(frame: frame, height: 34, viewport: 520, listTop: 100, bottomMargin: margin, bottomClearance: clearance)
        }
        XCTAssertEqual(reveal(row), .none, "in view: no scroll")
        XCTAssertEqual(reveal(row.offsetBy(dx: 0, dy: -150)), .minimal, "above: the least scroll")
        XCTAssertEqual(reveal(nil), .minimal, "not laid out yet")
        guard case let .bottom(fraction) = reveal(CGRect(x: 0, y: 520 - clearance, width: 300, height: 34)) else {
            return XCTFail("a row in the strip's room is brought above it")
        }
        // Its bottom lands on the clearance line: row top in the visible
        // part = fraction × (visible − height).
        let visible = 520 - margin - 100
        let bottom = 100 + fraction * (visible - 34) + 34
        XCTAssertEqual(bottom, 520 - clearance, accuracy: 0.5)
    }
}

/// The Tasks page with the demo tasks in a window off screen, as the panel
/// hosts it, driven with real mouse events.
@MainActor
private final class Hosted {
    let store: TaskStore
    let model: TasksPageModel
    let page: TasksPage
    let window: NSPanel
    let height: CGFloat

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init(height: CGFloat) throws {
        self.height = height
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        store = TaskStore(container: container)
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let size = CGSize(width: AtticLayout.panelSize.width, height: height)
        page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                         addBarFocused: .constant(false))
        window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        spin(1)
    }

    func close() { window.close() }

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Selects a tab the way a tab click does (with its slide) and waits
    /// for the pager to settle.
    func go(to tab: TasksTab) {
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { model.select(tab: tab) }
        spin(1.2)
    }

    /// The page the pager shows, from its scroll offset.
    func shownPage() -> Int? {
        guard let pager = pager(in: window.contentView) else { return nil }
        let clip = pager.contentView
        guard clip.bounds.width > 0 else { return nil }
        return Int((clip.bounds.origin.x / clip.bounds.width).rounded())
    }

    private func pager(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.frame.width > scroll.contentView.bounds.width * 1.5 {
            return scroll
        }
        for child in view.subviews {
            if let found = pager(in: child) { return found }
        }
        return nil
    }

    func click(y: CGFloat, modifiers: NSEvent.ModifierFlags = []) {
        let point = CGPoint(x: 110, y: height - y)
        // Through the app's queue, as a real click comes: the page reads
        // the click's modifiers from `NSApp.currentEvent`.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
            while let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
            spin(0.01)
        }
        spin(0.08)
    }

    /// Where a plain click selects each row: the first point (top down)
    /// that selects it, over the list's height above the add bar.
    func rowPlaces() -> [String: CGFloat] {
        var places: [String: CGFloat] = [:]
        let titles = Dictionary(model.doneDays().flatMap(\.rows).map { ($0.id, $0.model.title) }, uniquingKeysWith: { a, _ in a })
        var y: CGFloat = 60
        let bottom = height - TasksViewport.bottomMargin(bottomInset: AtticSpacing.panelMargin) - 4
        while y < bottom {
            model.clearSelection()
            spin(0.02)
            click(y: y)
            if model.selection.count == 1, let id = model.selection.first, let title = titles[id], places[title] == nil {
                places[title] = y + 4
            }
            y += 8
        }
        model.clearSelection()
        return places
    }
}

/// Round 6: the strip shows picked values (owner item 18), typed pieces
/// look like option H (item 15), Low leaves the menus (item 19).
@MainActor
final class TasksRound6ComposerTests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var store: TaskStore!
    private var model: TasksPageModel!
    /// Not live: the page's edits apply to the draft as typing would.
    private let editor = AtticTokenFieldEditor()

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        let library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { Calendar(identifier: .gregorian) },
            locale: Locale(identifier: "en_GB")
        ))
    }

    override func tearDown() {
        model = nil
        store = nil
    }

    private func day(_ raw: String) -> DueDay { DueDay(rawValue: raw)! }
    private var parts: TaskAddBarText.Parts { model.addBar.parts(parser: model.parser) }

    private func draft(_ text: String) {
        model.addBarState.clearDraft()
        model.addBar = TaskAddBarText(text: text)
        model.addBarCaret = (text as NSString).length
    }

    // MARK: Picks sit on the buttons

    func testAPickNeverTouchesTheTextAndPickingAgainReplacesIt() {
        draft("Pay rent")
        model.pickDate(day("2026-10-01"), editor: editor)
        XCTAssertEqual(model.addBar.text, "Pay rent", "picking never inserts text")
        XCTAssertEqual(parts.dueDay, day("2026-10-01"))
        model.pickDate(day("2026-10-05"), editor: editor)
        XCTAssertEqual(parts.dueDay, day("2026-10-05"), "picking again replaces the value")
        model.pickPriority(.high, editor: editor)
        model.pickPriority(.medium, editor: editor)
        XCTAssertEqual(parts.priority, .medium)
        model.pickPriority(.none, editor: editor)
        XCTAssertNil(parts.priority, "No Priority clears it")
        XCTAssertEqual(model.addBar.text, "Pay rent")
    }

    /// A pick while a typed date or priority exists replaces it: the typed
    /// words leave the text (with one space), as one undo step.
    func testAPickReplacesTheTypedPieceAsOneUndoStep() {
        draft("Pay rent tomorrow #home !")
        XCTAssertEqual(parts.priority, .medium)
        model.pickDate(day("2026-10-09"), editor: editor)
        XCTAssertEqual(model.addBar.text, "Pay rent #home !")
        XCTAssertEqual(parts.dueDay, day("2026-10-09"))
        model.pickPriority(.high, editor: editor)
        XCTAssertEqual(model.addBar.text, "Pay rent #home")
        XCTAssertEqual(parts.priority, .high)
        XCTAssertEqual(parts.tags, ["home"], "the other typed pieces stay")
        // One ⌘Z each: the priority pick (and its words), then the date's.
        XCTAssertEqual(model.addBarState.undoDraft()?.text, "Pay rent #home !")
        XCTAssertEqual(parts.priority, .medium)
        XCTAssertEqual(parts.dueDay, day("2026-10-09"))
        XCTAssertEqual(model.addBarState.undoDraft()?.text, "Pay rent tomorrow #home !")
        XCTAssertNotEqual(parts.dueDay, day("2026-10-09"), "the typed date is back")
        XCTAssertEqual(model.addBarState.redoDraft()?.text, "Pay rent #home !")
        XCTAssertEqual(parts.dueDay, day("2026-10-09"))
    }

    func testTagsTickAndUntickTypedOrPicked() {
        draft("Pay rent #home")
        XCTAssertEqual(model.composerTagState("home"), .on)
        XCTAssertEqual(model.composerTagChoices.first, "home", "the draft's tags first")
        model.toggleComposerTag("work", editor: editor)
        XCTAssertEqual(parts.tags, ["home", "work"])
        XCTAssertEqual(model.addBar.text, "Pay rent #home")
        XCTAssertEqual(TasksComposerValues.tags(parts.tags)?.text, "#home +1")
        XCTAssertEqual(TasksComposerValues.tags(parts.tags)?.spoken, "home and 1 more")
        model.toggleComposerTag("#HOME", editor: editor)
        XCTAssertEqual(model.addBar.text, "Pay rent", "a typed tag unticked leaves the text")
        XCTAssertEqual(parts.tags, ["work"])
        model.toggleComposerTag("work", editor: editor)
        XCTAssertEqual(parts.tags, [])
        XCTAssertNil(TasksComposerValues.tags([]))
    }

    /// × clears the button's value, typed pieces of its kind included.
    func testClearTakesTypedAndPickedValues() {
        draft("Call mom fri #family !! #home")
        model.toggleComposerTag("work", editor: editor)
        model.clearComposer(.tags, editor: editor)
        XCTAssertEqual(parts.tags, [])
        XCTAssertEqual(model.addBar.text, "Call mom fri !!")
        model.clearComposer(.priority, editor: editor)
        XCTAssertEqual(model.addBar.text, "Call mom fri")
        model.clearComposer(.date, editor: editor)
        XCTAssertEqual(model.addBar.text, "Call mom")
        XCTAssertNil(parts.dueDay)
        let steps = model.addBarState.history.undoStack.count
        model.clearComposer(.date, editor: editor)
        XCTAssertEqual(model.addBarState.history.undoStack.count, steps, "clearing nothing is no step")
    }

    /// The buttons show what the new task gets, and it gets it.
    func testTheTaskGetsWhatTheButtonsShow() throws {
        draft("Pay rent #home")
        model.pickDate(day("2026-10-01"), editor: editor)
        model.pickPriority(.high, editor: editor)
        model.toggleComposerTag("bills", editor: editor)
        XCTAssertEqual(model.dueText(day("2026-10-01")), "1 Oct", "the words a row shows for that day")
        XCTAssertEqual(TasksComposerValues.priority(parts.priority)?.text, "!!")
        XCTAssertEqual(TasksComposerValues.priority(parts.priority)?.ink, .priorityMark)
        XCTAssertEqual(TasksComposerValues.priority(.medium)?.ink, .helper)
        let id = try XCTUnwrap(model.submitAddBar())
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Pay rent")
        XCTAssertEqual(task.dueDay, day("2026-10-01"))
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(Set(task.tags), ["home", "bills"])
        XCTAssertEqual(model.addBar, TaskAddBarText(), "the draft and its picks are gone")
    }

    // MARK: Typed pieces (option H)

    func testTypedPiecesDrawByKind() {
        let text = TaskAddBarText(text: "Pay rent tomorrow #home ! and !!")
        let kinds = text.tokenChips(parser: model.parser, caret: nil).map(\.kind)
        XCTAssertEqual(kinds.first, .date)
        XCTAssertTrue(kinds.contains(.piece))
        let chips = text.tokenChips(parser: model.parser, caret: nil)
        XCTAssertEqual(chips.map(\.range), text.chips(parser: model.parser, caret: nil))
    }

    /// The field draws a date's icon in room kerned before it, fading in;
    /// the text stays exactly as typed, `!!` in High's orange.
    func testTheFieldKeepsRoomForADatesIcon() throws {
        let view = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        view.apply(style: .init(font: AtticTextStyle.listBody.nsFont, text: .black, piece: .gray, high: .orange,
                                caret: .black, reduceMotion: false))
        view.textView.string = "Pay rent fri !!"
        view.setChips([AtticTokenChip(range: NSRange(location: 9, length: 3), kind: .date),
                       AtticTokenChip(range: NSRange(location: 13, length: 2), kind: .high)])
        let storage = try XCTUnwrap(view.textView.textStorage)
        XCTAssertEqual(storage.string, "Pay rent fri !!", "no character is added")
        RunLoop.current.run(until: Date().addingTimeInterval(AtticTokenFieldMetrics.iconFade + 0.2))
        let kern = try XCTUnwrap(storage.attribute(.kern, at: 8, effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(kern, AtticChipLayoutManager.iconRoom, accuracy: 0.01, "the room is open once the fade ends")
        XCTAssertEqual(storage.attribute(.atticDateIcon, at: 9, effectiveRange: nil) as? CGFloat, 1)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 13, effectiveRange: nil) as? NSColor, .orange)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, .gray)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .black)
        // A date at the start opens its room with the line's indent.
        view.textView.string = "fri call"
        view.setChips([AtticTokenChip(range: NSRange(location: 0, length: 3), kind: .date)])
        let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(paragraph)
    }

    // MARK: Low priority (owner item 19)

    func testLowIsOfferedOnlyWhileATaskHasIt() {
        XCTAssertEqual(TaskPriority.choices(keeping: []), [.none, .medium, .high])
        XCTAssertEqual(TaskPriority.choices(keeping: [.high, .medium]), [.none, .medium, .high])
        XCTAssertEqual(TaskPriority.choices(keeping: [.low]), [.none, .low, .medium, .high], "ticked until changed")
        XCTAssertEqual(TaskPriority.none.pickerTitle, "No Priority")
    }
}

/// Round 6: the Done search on the tabs line (owner item 17).
@MainActor
final class TasksRound6SearchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func model(logging titles: [String], duplicate: String? = nil) throws -> (TaskStore, TasksPageModel) {
        let store = try makeTestStore(now: { [base] in base })
        let context = ModelContext(store.container)
        for (index, title) in titles.enumerated() {
            let id = UUID()
            let copies = title == duplicate ? 2 : 1
            for _ in 0..<copies {
                let item = TaskItem(id: id, title: title, status: .done, createdAt: base,
                                    updatedAt: base, completedAt: base.addingTimeInterval(-Double(index + 1) * 3_600))
                item.doneLoggedAt = base
                item.listOrderVersion = TaskItem.currentListOrderVersion
                context.insert(item)
            }
        }
        try context.save()
        store.refresh()
        let model = TasksPageModel(library: AtticLibrary(tasks: store, now: { [base] in base }), services: TasksPageServices(
            now: { [base] in base }, calendar: { Calendar(identifier: .gregorian) }, locale: Locale(identifier: "en_GB")))
        return (store, model)
    }

    /// "N of M done tasks": matches of all, each task once however many
    /// copies it has; nothing without a search.
    func testTheSearchCountsMatchesOfAllDoneTasksOnce() throws {
        let (_, model) = try model(logging: ["Send invoice", "Pay invoice", "Call the bank", "Renew passport"], duplicate: "Pay invoice")
        model.select(tab: .done)
        XCTAssertNil(model.doneSearchCount())
        model.doneSearch = "INVOICE"
        let count = try XCTUnwrap(model.doneSearchCount())
        XCTAssertEqual(count.matches, 2)
        XCTAssertEqual(count.total, 4)
        model.doneSearch = "zzz"
        XCTAssertEqual(model.doneSearchCount()?.matches, 0)
    }

    /// The results mark where the search matched.
    func testResultsHighlightTheMatch() throws {
        let (_, model) = try model(logging: ["Send invoice", "Invoice the café"])
        model.select(tab: .done)
        model.doneSearch = "invoice"
        model.loadDoneLogIfNeeded()
        let rows = model.doneDays().flatMap(\.rows)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.model.titleMatch, "invoice")
            let ranges = row.model.titleMatchRanges
            XCTAssertEqual(ranges.count, 1)
            XCTAssertEqual(row.model.title[ranges[0]].lowercased(), "invoice")
        }
        var model2 = AtticTaskRowModel(title: "Cafe café CAFÉ")
        model2.titleMatch = "cafe"
        XCTAssertEqual(model2.titleMatchRanges.count, 3, "case and accents ignored, as the search reads")
        model.doneSearch = ""
        XCTAssertTrue(model.doneDays().flatMap(\.rows).allSatisfy { $0.model.titleMatch == nil }, "no search, no marks")
    }

    /// Typing on the Done page starts a search with printable keys only:
    /// never Space (it completes), Return, Tab or the arrow keys.
    func testOnlyPrintableKeysStartASearch() {
        XCTAssertTrue(TasksPage.startsSearch("i"))
        XCTAssertTrue(TasksPage.startsSearch("I"))
        XCTAssertTrue(TasksPage.startsSearch("é"))
        XCTAssertTrue(TasksPage.startsSearch("#"))
        XCTAssertFalse(TasksPage.startsSearch(" "))
        XCTAssertFalse(TasksPage.startsSearch("\r"))
        XCTAssertFalse(TasksPage.startsSearch("\t"))
        XCTAssertFalse(TasksPage.startsSearch("\u{1B}"), "Esc")
        XCTAssertFalse(TasksPage.startsSearch("\u{7F}"), "Delete")
        XCTAssertFalse(TasksPage.startsSearch("\u{F700}"), "↑")
        XCTAssertFalse(TasksPage.startsSearch("ab"))
        XCTAssertFalse(TasksPage.startsSearch(""))
    }
}
