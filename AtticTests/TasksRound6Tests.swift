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

    /// ⌘F on Done, with the add bar holding the keyboard (as the panel
    /// opens): the search takes the tabs' line with the keyboard in it
    /// (CI run 1: the field showed without it).
    func testCommandFOnDoneGivesTheSearchTheKeyboard() throws {
        // The apps' Edit menu has Find on ⌘F, sent to the text view with
        // the keyboard (CI run 3: it took ⌘F from the page).
        let saved = NSApp.mainMenu
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.submenu?.addItem(find)
        menu.addItem(edit)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = saved }
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        XCTAssertTrue(hosted.window.firstResponder is AtticTokenTextView, "the add bar has the keyboard")
        hosted.go(to: .done)
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(hosted.searchHasKeyboard, "⌘F puts the keyboard in the search: \(String(describing: hosted.window.firstResponder))")
        hosted.press("i", keyCode: 34)
        hosted.press("n", keyCode: 45)
        XCTAssertEqual(hosted.model.doneSearch, "in", "typing goes into the search, the first letter kept")
        hosted.press("\u{1B}", keyCode: 53)
        XCTAssertEqual(hosted.model.doneSearch, "", "Esc ends the search")
        XCTAssertFalse(hosted.searchHasKeyboard)
        // Right after Esc, ⌘F opens it again.
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(hosted.searchHasKeyboard, "⌘F again after Esc: \(String(describing: hosted.window.firstResponder))")
        hosted.press("\u{1B}", keyCode: 53)
        // Not on Now: ⌘F there is the menu's.
        hosted.go(to: .now)
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertFalse(hosted.searchHasKeyboard, "⌘F is Done's")
    }

    /// A click on Done's magnifier, with the add bar holding the keyboard:
    /// the field takes the tabs' line and the keyboard (CI run 1).
    func testTheMagnifierGivesTheSearchTheKeyboard() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let y = layout.headerBottom + AtticLayout.pageTabsTop + AtticLayout.pageTabsHeight / 2
        // A click on the Done tab, as a person arrives there (the tabs take
        // the keyboard's focus, and they leave when the field comes).
        var tabX: CGFloat = 60
        while tabX < 200, hosted.model.tab != .done {
            hosted.click(y: y, x: tabX)
            tabX += 6
        }
        XCTAssertEqual(hosted.model.tab, .done)
        hosted.spin(1)
        var x = AtticLayout.panelSize.width - 12
        while x > AtticLayout.panelSize.width - 80, !hosted.searchFieldShown {
            hosted.click(y: y, x: x)
            x -= 4
        }
        XCTAssertTrue(hosted.searchFieldShown, "the magnifier opens the search")
        XCTAssertNotNil(hosted.window.contentView.flatMap { AtticTabsSearchField.searchField(in: $0, placeholder: "Search done tasks") },
                        "the field's own text field is found by its prompt (the keyboard's fallback)")
        hosted.spin(0.4)
        XCTAssertTrue(hosted.searchHasKeyboard, "with the keyboard in it: \(String(describing: hosted.window.firstResponder))")
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
final class Hosted {
    let store: TaskStore
    let model: TasksPageModel
    let page: TasksPage
    let window: NSPanel
    let height: CGFloat
    /// The page's live pointer (round 12): its rows' frames.
    let pointer = TasksPointer()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// The add bar's focus, as the panel holds it (the preview opens with
    /// the bar focused).
    final class Focus { var addBar = false }
    let focus = Focus()

    init(height: CGFloat, addBarFocused: Bool = false, long: Bool = false) throws {
        focus.addBar = addBarFocused
        self.height = height
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: long)
        store = TaskStore(container: container)
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let size = CGSize(width: AtticLayout.panelSize.width, height: height)
        let focus = focus
        page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                         addBarFocused: Binding(get: { focus.addBar }, set: { focus.addBar = $0 }),
                         pointer: pointer)
        window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        spin(1)
    }

    func close() { window.close() }

    /// Delivers what is queued through the app, as a real event comes; a
    /// bounded number, so a source that keeps posting can never hang the
    /// run (round 7's CI hang).
    static func pumpEvents(limit: Int = 64) {
        var count = 0
        while count < limit, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
            count += 1
        }
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Selects a tab the way a tab click does (with its slide) and waits
    /// for the pager to settle.
    func go(to tab: TasksTab) {
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { model.select(tab: tab) }
        spin(1.2)
    }

    /// The page the pager shows (round 9: its position, once it has
    /// settled on a whole page), and only if exactly one list is drawn in
    /// the window (the others lie beside it, off the page).
    func shownPage() -> Int? {
        let position = model.pagerSwipe.motion.position
        guard position == position.rounded(), let content = window.contentView else { return nil }
        // AppKit views take their SwiftUI place on the next layout pass,
        // which an off-screen test window does not always run by itself.
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let onPage = lists(in: content).filter { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        }
        return onPage.count == 1 ? Int(position) : nil
    }

    /// The vertical lists (each page's scroll view).
    func lists(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { lists(in: $0) }
    }

    /// A key press through the app's queue (key equivalents included).
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            NSApp.postEvent(event, atStart: false)
            Hosted.pumpEvents()
        }
        spin(0.4)
    }

    /// Key presses queued together and delivered at once, as fast typing
    /// arrives (no pause for the search field to take the keyboard).
    func typeQuickly(_ text: String, keyCodes: [Character: UInt16]) {
        for character in text {
            let characters = String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCodes[character] ?? 0)!
                NSApp.postEvent(event, atStart: false)
            }
        }
        Hosted.pumpEvents()
        spin(0.6)
    }

    /// The keyboard is in a plain text field (the search), not the add bar.
    var searchHasKeyboard: Bool {
        (window.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    /// A plain text field (the search) is in the page.
    var searchFieldShown: Bool {
        func find(_ view: NSView) -> Bool {
            if view is NSTextField, (view as? NSTextField)?.isEditable == true { return true }
            return view.subviews.contains(where: find)
        }
        return window.contentView.map(find) ?? false
    }

    func click(y: CGFloat, x: CGFloat = 110, modifiers: NSEvent.ModifierFlags = []) {
        let point = CGPoint(x: x, y: height - y)
        // Through the app's queue, as a real click comes (the page reads
        // the click's modifiers from `NSApp.currentEvent`), the press and
        // the release queued together: a view that tracks the mouse from its
        // press (a text field) reads the release from the queue itself, so
        // it must be there already (round 7's CI hang: a click into the
        // search field waited for a release that was never posted).
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        Hosted.pumpEvents()
        spin(0.09)
    }

    /// A real secondary click (press and release) at `y` from the top, through
    /// the app's queue as `click` posts a primary one.
    func rightClick(y: CGFloat, x: CGFloat = 110) {
        let point = CGPoint(x: x, y: height - y)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 2, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        Hosted.pumpEvents()
        spin(0.09)
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

    /// A date or priority typed after a pick replaces it (the latest wins).
    func testATypedPieceAfterAPickReplacesIt() {
        draft("Pay rent")
        model.pickDate(day("2026-10-01"), editor: editor)
        model.pickPriority(.high, editor: editor)
        var text = model.addBar
        text.text = "Pay rent fri ! "
        XCTAssertTrue(text.typedReplacesPicks(parser: model.parser, caret: 15))
        XCTAssertNil(text.picked.day)
        XCTAssertNil(text.picked.priority)
        XCTAssertEqual(text.parts(parser: model.parser).priority, .medium)
        XCTAssertFalse(text.typedReplacesPicks(parser: model.parser, caret: 15), "nothing left to replace")
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
