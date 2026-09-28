import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 7: Astra's regression check of rounds 5–6 (R1–R6).
@MainActor
final class TasksRound7Tests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var store: TaskStore!
    private var model: TasksPageModel!

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

    // MARK: - R1: typing after a pick never wipes it on the way

    /// The add bar's real text view, wired to the page model's own edit and
    /// caret handlers (the ones `TasksAddBar` uses).
    private struct LiveBar {
        let window: NSWindow
        let view: AtticTokenFieldView
        let editor: AtticTokenFieldEditor
        let coordinator: AtticTokenField.Coordinator
    }

    private func liveBar() -> LiveBar {
        let state = model.addBarState
        let model = model!
        let actions = AtticTokenFieldActions(
            submit: { _ in }, dismissChip: { _ in }, multilinePaste: { _ in false }, escape: { false },
            edited: { model.addBarEdited($0, replacement: $1) },
            caretMoved: { model.addBarCaretMoved($0) },
            undoDraft: { state.undoDraft() },
            redoDraft: { state.redoDraft() },
            selectionMoved: { state.selection = $0 }
        )
        let field = AtticTokenField(
            text: Binding(get: { state.text.text }, set: { state.text.text = $0 }),
            chips: [], isFocused: .constant(true), accessibilityLabel: "Add a task", actions: actions
        )
        let coordinator = field.makeCoordinator()
        let view = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        view.textView.delegate = coordinator
        view.textView.owner = coordinator
        coordinator.view = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view.textView)
        let editor = AtticTokenFieldEditor()
        editor.textView = view.textView
        return LiveBar(window: window, view: view, editor: editor, coordinator: coordinator)
    }

    private func type(_ text: String, into bar: LiveBar, each: (String) -> Void = { _ in }) {
        for character in text {
            bar.view.textView.insertText(String(character), replacementRange: bar.view.textView.selectedRange())
            each(model.addBar.text)
        }
    }

    /// Astra's R1: `Call `, pick Tomorrow, then type `friend` a letter at a
    /// time. At `fri` the parser reads Friday, but a word still being typed
    /// never replaces the pick; at `friend` Tomorrow is still the date, and
    /// the task gets it. `money` (through `mon`) the same.
    func testTypingAWordThroughADatePrefixKeepsThePick() throws {
        let tomorrow = day("2026-09-22")
        for word in ["friend", "money", "sat", "tue"] {
            model.addBarState.clearDraft()
            let bar = liveBar()
            defer { bar.window.close() }
            type("Call ", into: bar)
            model.pickDate(tomorrow, editor: bar.editor)
            type(word, into: bar) { text in
                XCTAssertEqual(self.parts.dueDay, tomorrow, "“\(text)”: the pick holds while the word is typed")
                XCTAssertEqual(self.model.addBar.picked.day, tomorrow, "“\(text)”")
            }
            XCTAssertEqual(model.addBar.text, "Call \(word)")
        }
        // Submitted as typed: Call friend (not Friday), due Tomorrow.
        model.addBarState.clearDraft()
        let bar = liveBar()
        defer { bar.window.close() }
        type("Call ", into: bar)
        model.pickDate(tomorrow, editor: bar.editor)
        type("friend", into: bar)
        let id = try XCTUnwrap(model.submitAddBar())
        let task = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(task.title, "Call friend")
        XCTAssertEqual(task.dueDay, tomorrow)
    }

    /// A finished typed date (its word ended) replaces the pick, as one
    /// step with its typing: ⌘Z brings the pick back, ⇧⌘Z takes it again.
    func testAFinishedTypedDateReplacesThePickAndUndoRestoresIt() {
        let tomorrow = day("2026-09-22")
        let bar = liveBar()
        defer { bar.window.close() }
        type("Call ", into: bar)
        model.pickDate(tomorrow, editor: bar.editor)
        type("fri", into: bar)
        XCTAssertEqual(parts.dueDay, tomorrow, "still typing: the pick holds")
        type(" ", into: bar)
        XCTAssertNil(model.addBar.picked.day, "the word finished: Friday replaces the pick")
        XCTAssertNotEqual(parts.dueDay, tomorrow)
        let friday = parts.dueDay
        XCTAssertNotNil(friday)
        bar.view.textView.undo(nil)
        XCTAssertEqual(model.addBar.text, "Call fri")
        XCTAssertEqual(parts.dueDay, tomorrow, "⌘Z: the space undone, the pick back")
        bar.view.textView.redo(nil)
        XCTAssertEqual(model.addBar.text, "Call fri ")
        XCTAssertEqual(parts.dueDay, friday, "⇧⌘Z: Friday again")
        // Priority the same way: "!" at the caret is not yet a piece.
        model.pickPriority(.high, editor: bar.editor)
        type("!", into: bar)
        XCTAssertEqual(parts.priority, .high, "a mark still being typed keeps the pick")
        type(" ", into: bar)
        XCTAssertEqual(parts.priority, .medium, "finished, it replaces it")
    }

    // MARK: - R5: explicit navigation cancels a swipe, even to the same page

    /// A swipe from Now is moving; the person chooses Now (the tab, a key,
    /// `show`, Search or a reveal), through the model's own routes. The
    /// swipe's origin goes, a later `.decelerating` takes no new one, and
    /// idle selects nothing, so no delayed snap overrides the choice.
    func testChoosingTheSameTabDuringASwipeCancelsItUntilIdle() throws {
        let task = try XCTUnwrap(store.create(title: "Call the plumber"))
        let routes: [(String, () -> Void)] = [
            ("the Now tab", { self.model.select(tab: .now) }),
            ("show", { _ = self.model.show(task.id) }),
            ("a reveal", { self.model.resetForReveal() })
        ]
        for (name, route) in routes {
            XCTAssertEqual(model.tab, .now)
            let swipe = model.pagerSwipe
            swipe.geometry = .init(offset: 0, width: 320)
            XCTAssertNil(swipe.phaseChanged(to: .interacting, shown: 0))
            XCTAssertEqual(swipe.origin, 0)
            swipe.geometry.offset = 250
            route()
            XCTAssertNil(swipe.origin, "\(name) cancels the swipe")
            XCTAssertTrue(swipe.isCancelledUntilIdle, name)
            XCTAssertNil(swipe.phaseChanged(to: .decelerating, shown: 0))
            XCTAssertNil(swipe.origin, "\(name): no new origin before idle")
            swipe.geometry.offset = 320
            XCTAssertNil(swipe.phaseChanged(to: .idle, shown: 0), "\(name): idle selects nothing")
            XCTAssertFalse(swipe.isCancelledUntilIdle, "\(name): the next swipe is a swipe again")
            XCTAssertEqual(model.tab, .now)
            model.clearSelection()
        }
        // Search (to Done) mid-swipe: the same.
        let swipe = model.pagerSwipe
        _ = swipe.phaseChanged(to: .interacting, shown: 0)
        model.beginSearch()
        XCTAssertNil(swipe.origin)
        XCTAssertTrue(swipe.isCancelledUntilIdle)
        XCTAssertNil(swipe.phaseChanged(to: .idle, shown: 2))
        XCTAssertEqual(model.tab, .done)
    }

    /// A swipe's own settled choice cancels nothing, and a swipe that was
    /// not interrupted still settles.
    func testASwipesOwnSettleStillSelects() {
        let swipe = model.pagerSwipe
        swipe.geometry = .init(offset: 0, width: 320)
        _ = swipe.phaseChanged(to: .interacting, shown: 0)
        swipe.geometry.offset = 320
        XCTAssertEqual(swipe.phaseChanged(to: .idle, shown: 0), 1)
        model.select(tab: .backlog, bySwipe: true)
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertFalse(swipe.isCancelledUntilIdle)
        // A cancel while idle leaves nothing behind.
        model.select(tab: .now)
        XCTAssertFalse(swipe.isCancelledUntilIdle)
    }

    // MARK: - R6: mixed selections never offer Low

    func testLowIsNeverOfferedToAMixedSelection() {
        XCTAssertEqual(TaskPriority.choices(keeping: [.low, .high]), [.none, .medium, .high])
        XCTAssertEqual(TaskPriority.choices(keeping: [.low, .none]), [.none, .medium, .high])
        XCTAssertEqual(TaskPriority.choices(keeping: [.low]), [.none, .low, .medium, .high], "every target Low: ticked")
        XCTAssertEqual(TaskPriority.choices(keeping: [.low, .low]), [.none, .low, .medium, .high])
        XCTAssertEqual(TaskPriority.choices(keeping: []), [.none, .medium, .high])
    }

    // MARK: - R4: right-click binding stops at the bottom stack

    /// A secondary click on a row's frame binds its menu only in the list's
    /// visible part: under the bottom stack's band it binds nothing.
    func testASecondaryClickUnderTheBottomStackBindsNoRow() throws {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = Flipped(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.contentView = view
        let pointer = TasksPointer()
        pointer.view = view
        let row = UUID()
        // A tall row (its quick look open) that runs under the stack.
        pointer.frames[row] = CGRect(x: 0, y: 400, width: 320, height: 110)
        let band = TasksBottomBand.height(stack: TasksViewport.reservedStack, bottomInset: 12)
        func rightClick(atY y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(CGPoint(x: 100, y: y), to: nil), modifierFlags: [],
                               timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        var selected: [UUID] = []
        pointer.press(rightClick(atY: 480), below: 100, aboveBottom: band) { id in selected.append(id); return [id] }
        XCTAssertNil(pointer.binding(for: row), "under the stack: no menu binding")
        XCTAssertTrue(selected.isEmpty, "and nothing selected")
        pointer.press(rightClick(atY: 520 - band - 4), below: 100, aboveBottom: band) { id in selected.append(id); return [id] }
        XCTAssertNotNil(pointer.binding(for: row), "just above the stack the row is the row")
        XCTAssertEqual(selected, [row])
    }
}

/// Round 7 through the hosted page and the full panel shell.
@MainActor
final class TasksRound7HostedTests: XCTestCase {
    // MARK: - R4: the bottom stack owns its band

    /// Rows lie under the strip (a draft shows it) in a long list. Clicks on
    /// the strip's empty end, the gap between the strip and the bar, and the
    /// bar's margin select and complete nothing beneath; a row just above
    /// the band still takes its click.
    func testClicksOnTheBottomStackNeverReachARowBeneath() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        hosted.model.addBar = TaskAddBarText(text: "Pay")
        hosted.spin(0.6)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let band = TasksBottomBand.height(stack: TasksViewport.reservedStack, bottomInset: bottomInset)
        let barTop = 520 - bottomInset - AtticControlSize.addBarHeight
        let statuses = { hosted.store.snapshot(for: .tasks).sections.flatMap(\.tasks).map { "\($0.id)\($0.status)" }.sorted() }
        let before = statuses()
        var probes: [(x: CGFloat, y: CGFloat)] = []
        // The strip's line, past its buttons, and its gaps.
        for y in stride(from: 520 - band + 1, to: barTop - 1, by: 3) { probes.append((x: 300, y: y)) }
        // The gap between the strip and the bar, across the width.
        for x in stride(from: CGFloat(30), through: 300, by: 30) { probes.append((x: x, y: barTop - 3)) }
        // Under the bar, beside it (the bottom margin).
        probes.append((x: 150, y: 520 - bottomInset / 2))
        for probe in probes {
            hosted.model.clearSelection()
            hosted.click(y: probe.y, x: probe.x)
            XCTAssertTrue(hosted.model.selection.isEmpty, "a click at \(probe) reached a row beneath the stack")
        }
        XCTAssertEqual(statuses(), before, "nothing beneath was completed")
        // A row just above the band keeps its click.
        var took = false
        for y in stride(from: 520 - band - 2, to: 520 - band - 50, by: -4) where !took {
            hosted.model.clearSelection()
            hosted.click(y: y)
            took = !hosted.model.selection.isEmpty
        }
        XCTAssertTrue(took, "a row just above the stack takes its click")
    }

    // MARK: - R3: back into the search, nothing stays lit

    func testClickingBackIntoTheSearchClearsTheSelection() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .done)
        hosted.press("f", keyCode: 3, modifiers: .command)
        hosted.press("e", keyCode: 14)
        XCTAssertEqual(hosted.model.doneSearch, "e")
        // Click a result: the list's first rows, from under the tabs.
        let listTop = TasksViewport.listTop(tabsTop: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520)).headerBottom
            + AtticLayout.pageTabsTop)
        var y = listTop + 4
        while hosted.model.selection.isEmpty, y < listTop + 160 {
            hosted.click(y: y)
            y += 8
        }
        XCTAssertEqual(hosted.model.selection.count, 1, "a click selects a result")
        // Back into the search field on the tabs' line.
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        hosted.click(y: layout.headerBottom + AtticLayout.pageTabsTop + AtticLayout.pageTabsHeight / 2, x: 150)
        XCTAssertTrue(hosted.model.selection.isEmpty, "back in the search, no row stays lit")
        XCTAssertEqual(hosted.model.doneSearch, "e", "the query stays")
    }
}

/// Round 7 through the full panel shell (R2). Its own class, run after
/// the hosted page tests: the shell leaves more behind when it closes.
@MainActor
final class TasksRound7ShellTests: XCTestCase {
    // MARK: - R2: a hidden Tasks page never answers ⌘F

    /// The full panel shell: Tasks → Done search, then Notes (⌘2's page
    /// switch) with Tasks kept built behind it. ⌘F there leaves the hidden
    /// Done search closed and the keyboard where it was; back on Tasks, ⌘F
    /// opens it with the keyboard.
    func testAHiddenTasksPageNeverTakesCommandF() throws {
        let suite = "TasksRound7HostedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: NoteDraftController(noteStore: notes),
                chromeInteractionState: chrome, uiState: state, settings: settings,
                subtaskPanels: SubtaskPanelController(store: store, uiState: state, settings: settings)
            ),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        panel.makeKey()
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
                Hosted.pumpEvents()
            }
            spin(0.6)
        }
        func searchField() -> NSTextField? {
            AtticTabsSearchField.searchField(in: host, placeholder: "Search done tasks")
        }
        func searchHasKeyboard() -> Bool {
            guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor,
                  let owner = editor.delegate as? NSTextField else { return false }
            return owner === searchField()
        }
        spin(1.5)
        state.selectSection(.tasks)
        spin(0.5)
        // Search opens Done's search with the keyboard (the menu bar's route).
        state.requestSearch()
        spin(1)
        XCTAssertNotNil(searchField(), "Search opens the field on the tabs' line")
        XCTAssertTrue(searchHasKeyboard(), "with the keyboard")
        // To Notes with the search holding the keyboard: it lets it go.
        state.selectSection(.notes)
        spin(1)
        XCTAssertFalse(searchHasKeyboard(), "hidden, the Done search keeps no keyboard")
        // Back, Esc ends the search; then Notes, and ⌘F there.
        state.selectSection(.tasks)
        spin(1)
        press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(searchHasKeyboard(), "⌘F on Done, the search has the keyboard: \(String(describing: panel.firstResponder))")
        press("\u{1B}", keyCode: 53)
        XCTAssertNil(searchField(), "Esc ends the search: \(String(describing: panel.firstResponder))")
        state.selectSection(.notes)
        spin(1)
        press("f", keyCode: 3, modifiers: .command)
        XCTAssertNil(searchField(), "⌘F on Notes never opens the hidden Done search")
        XCTAssertFalse(searchHasKeyboard())
        // On Tasks (Done shown) it does. (⌘F on Notes went to Notes' own
        // Find, whose panel can take the key window: the panel is key
        // again first, as a click on it makes it.)
        state.selectSection(.tasks)
        for window in NSApp.windows where window !== panel && window.isVisible && window.className.contains("Find") { window.orderOut(nil) }
        panel.makeKey()
        spin(1)
        press("f", keyCode: 3, modifiers: .command)
        XCTAssertNotNil(searchField(), "⌘F on Done opens the search")
        XCTAssertTrue(searchHasKeyboard(), "with the keyboard")
    }
}
