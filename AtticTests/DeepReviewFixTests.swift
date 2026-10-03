import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1's deep review, the UI fix round: Find from far down a list
/// (P2-01), the soft edge's pockets over the whole control regions
/// (P2-02), one Open Files command for every route (P2-03), a visible
/// keyboard focus at every Tab stop (P2-04), the composer strip's values
/// in full (P3-01) and the pager's test-only settle (code review). Each is
/// driven the way a person drives it where the hosted page allows: real
/// key and mouse events through the app's queue, real menus.
@MainActor
final class DeepReviewFixTests: XCTestCase {
    private var savedEdge: AtticScrollEdgeStyle?

    override func tearDown() async throws {
        if let savedEdge { AtticScrollEdgeLab.shared.style = savedEdge }
        savedEdge = nil
        try await super.tearDown()
    }

    private func useSoftEdge() {
        if savedEdge == nil { savedEdge = AtticScrollEdgeLab.shared.style }
        AtticScrollEdgeLab.shared.style = .systemSoft
    }

    private func layout(_ hosted: Hosted) -> PanelPageLayout {
        PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: hosted.height))
    }

    private func shownList(_ hosted: Hosted) throws -> NSScrollView {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        return try XCTUnwrap(hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        })
    }

    /// Scrolls the list to the end of what it holds.
    private func scrollToEnd(_ list: NSScrollView, _ hosted: Hosted) {
        list.layoutSubtreeIfNeeded()
        let clip = list.contentView
        let end = (list.documentView?.frame.height ?? 0) - clip.bounds.height + clip.contentInsets.bottom
        clip.scroll(to: CGPoint(x: 0, y: max(end, 0)))
        list.reflectScrolledClipView(clip)
        hosted.spin(0.5)
    }

    // MARK: - P2-01: Find from far down a list

    /// Far down the long list, a query matching a task near the top: the
    /// list goes back to its top, where the match is, and the match is in
    /// the part of the list nothing covers (it showed an empty viewport and
    /// no count). The same for a view that hides most of the list.
    func testAQueryTypedFarDownTheListShowsItsMatch() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        scrollToEnd(list, hosted)
        let deep = list.contentView.bounds.origin.y
        XCTAssertGreaterThan(deep, 200, "the long list is scrolled far down (\(deep))")

        let ship = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" }?.id)
        hosted.model.setSearchQuery("Ship", for: .now)
        hosted.spin(0.6)
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), [ship], "Find narrows the list to its match")
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5,
                       "the list is back at its top, where its first row (the match) rests under the tabs")
        XCTAssertLessThan(list.documentView?.frame.height ?? .infinity, list.contentView.bounds.height,
                          "the match and its count fit in the viewport")
        XCTAssertEqual(hosted.model.listSearchCount(for: .now)?.matches, 1, "and the count says so")

        // Changing the query keeps the list at its top, and clearing it too.
        hosted.model.setSearchQuery("Shi", for: .now)
        hosted.spin(0.4)
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5)
        hosted.model.setSearchQuery("", for: .now)
        hosted.spin(0.4)

        // A view that hides most of the list, from far down.
        scrollToEnd(list, hosted)
        XCTAssertGreaterThan(list.contentView.bounds.origin.y, 200)
        var view = hosted.model.viewOptions(for: .now)
        view.priority = .highOnly
        hosted.model.setViewOptions(view, for: .now)
        hosted.spin(0.6)
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5,
                       "a view that narrows the list starts it at its top")
        XCTAssertFalse(hosted.model.rows(for: .now).isEmpty)
    }

    // MARK: - D1: viewport clears every visible control

    func testTheViewportTracksFindTheStripSelectionAndPasteOffer() throws {
        useSoftEdge()
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        scrollToEnd(list, hosted)
        let layout = layout(hosted)
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let idle = TasksViewport.bottomMargin(bottomInset: bottomInset)
        func frame() -> CGRect {
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            return list.convert(list.bounds, to: hosted.window.contentView)
        }
        let resting = frame()
        XCTAssertEqual(resting.minY, TasksViewport.controlsBottom(tabsTop: tabsTop), accuracy: 0.5)
        XCTAssertEqual(resting.maxY, hosted.height - idle, accuracy: 0.5)
        let pocketHeights = ScrollEdgeTests.pockets(in: list).map(\.frame.height).sorted()

        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertTrue(hosted.searchFieldShown)
        XCTAssertEqual(frame().minY, resting.minY, accuracy: 0.5, "Find has the same taller control boundary")
        hosted.press("\u{1B}", keyCode: 53)

        hosted.model.addBar = TaskAddBarText(text: "Pay rent tomorrow #home !!")
        hosted.spin(0.8)
        let strip = AtticPickerMetrics.stripToBar + AtticControlSize.smallHeight
        XCTAssertEqual(frame().maxY, resting.maxY - strip, accuracy: 0.5)
        XCTAssertEqual(ScrollEdgeTests.pockets(in: list).map(\.frame.height).sorted(), pocketHeights,
                       "the native fade stays small; the viewport moves above the strip")
        hosted.model.addBarState.clearDraft()
        hosted.spin(0.8)
        XCTAssertEqual(frame().maxY, resting.maxY, accuracy: 0.5)

        let ids = hosted.model.rows(for: .now).prefix(2).map(\.id)
        hosted.model.selectOnly(ids[0])
        hosted.model.selectCopies(ids)
        hosted.spin(0.8)
        XCTAssertLessThan(frame().maxY, resting.maxY - 20, "the selection bar is excluded too")
        hosted.model.clearSelection()
        hosted.spin(0.8)
        XCTAssertEqual(frame().maxY, resting.maxY, accuracy: 0.5)
        hosted.model.pasteOffer = TaskPasteOffer("Milk\nEggs\nBread")
        hosted.spin(0.8)
        XCTAssertLessThan(frame().maxY, resting.maxY - 20, "the paste offer is excluded too")
        hosted.model.dismissPasteOffer()
        hosted.spin(0.8)
        XCTAssertEqual(frame().maxY, resting.maxY, accuracy: 0.5)
        XCTAssertTrue(ScrollEdgeTests.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty)
    }

    // MARK: - P2-03: one Open Files command

    /// Open Files… from the row's right-click menu (the menu a secondary
    /// click on the row gets), from ⇧⌘I's menu (a real ⇧⌘I, the menu's own
    /// keys) and from ⌘Return: each opens the row's files, once.
    func testOpenFilesOpensFromTheRightClickMenuTheActionsMenuAndCommandReturn() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        var opened: [UUID] = []
        hosted.model.services.openPage = { opened.append($0) }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Book dentist" }?.id)
        // The right-click menu: the menu SwiftUI shows for a secondary click
        // on the row, its More › Open Files… chosen as AppKit chooses an
        // item. (Typing into a live context menu in the hosted window was
        // not dependable across macOS versions; `TasksPanelUITests` clicks
        // it in the real panel.)
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row)])
        let content = try XCTUnwrap(hosted.window.contentView)
        let point = CGPoint(x: frame.minX + 110, y: hosted.height - (frame.minY + 16))
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: hosted.window.windowNumber, context: nil,
                                                     eventNumber: 3, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(content.menu(for: press), "a secondary click on the row has the row's menu")
        menu.update()
        let more = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu, "with More")
        more.update()
        let open = try XCTUnwrap(more.items.firstIndex { $0.title.hasPrefix("Open Files") }, "holding Open Files…")
        more.performActionForItem(at: open)
        hosted.spin(0.5)
        XCTAssertEqual(opened, [row], "the right-click menu's Open Files… opens the row's files")

        // ⇧⌘I's menu: down to More (its eleventh item), into it, Return.
        opened = []
        try hosted.clickRow(row, tab: .now)
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let actionTimers = schedule(Array(repeating: down, count: 11) + [("\u{F703}", 124), ("\r", 36)], in: hosted)
        hosted.press("i", keyCode: 34, modifiers: [.command, .shift])
        hosted.spin(1)
        actionTimers.forEach { $0.invalidate() }
        XCTAssertEqual(opened, [row], "⇧⌘I's Open Files… opens them the same way")

        // ⌘Return on the selected row.
        opened = []
        try hosted.clickRow(row, tab: .now)
        hosted.press("\r", keyCode: 36, modifiers: .command)
        hosted.spin(0.3)
        XCTAssertEqual(opened, [row], "and ⌘Return")
        XCTAssertNil(hosted.model.editingTitleID, "⌘Return is not Return: no title is edited")
    }

    // MARK: - PR prep P2: a menu's choice is not a typing field's key

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                          type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                       characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    /// The rule: outside a menu choice, a key down while a field has the
    /// keyboard is the field's. A choice made in a menu is not, unless the
    /// key is that item's own key equivalent.
    func testOnlyAnItemsOwnKeyEquivalentBelongsToATypingField() throws {
        let plainReturn = try keyEvent("\r", keyCode: 36)
        let commandReturn = try keyEvent("\r", keyCode: 36, modifiers: .command)
        let openPage: KeyboardShortcut?? = .some(AtticTaskShortcut.openPage)
        XCTAssertTrue(AtticTextInput.owns(plainReturn, menuChoice: nil, hasKeyboard: { true }),
                      "a key outside any menu stays the typing field's")
        XCTAssertFalse(AtticTextInput.owns(plainReturn, menuChoice: openPage, hasKeyboard: { true }),
                       "the Return that chose Open Files… in its menu is the menu's")
        XCTAssertFalse(AtticTextInput.owns(commandReturn, menuChoice: .some(nil), hasKeyboard: { true }),
                       "an item without a key equivalent, chosen, is never a field's key")
        XCTAssertTrue(AtticTextInput.owns(commandReturn, menuChoice: openPage, hasKeyboard: { true }),
                      "the item's own ⌘Return while a field types stays the field's")
        XCTAssertFalse(AtticTextInput.owns(commandReturn, menuChoice: openPage, hasKeyboard: { false }))
        XCTAssertFalse(AtticTextInput.owns(try keyEvent("\r", keyCode: 36, type: .keyUp), menuChoice: nil, hasKeyboard: { true }))
        XCTAssertFalse(AtticTextInput.owns(nil, menuChoice: nil, hasKeyboard: { true }))
    }

    /// The on-screen failure (CU recheck 3): More › Open Files… chosen with
    /// Return in the right-click menu and in ⇧⌘I's menu, while something
    /// has the keyboard (on macOS 27 the context menu's own Ask Siri field;
    /// the composer under a menu), opened nothing, while ⌘Return did. Here
    /// the Return is the current event and an open pop-over has the
    /// keyboard; each menu's Open Files… must open the row's files, and a
    /// real ⌘Return key equivalent must still leave a typing field alone.
    func testOpenFilesChosenWithReturnOpensWhileSomethingHasTheKeyboard() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        var opened: [UUID] = []
        hosted.model.services.openPage = { opened.append($0) }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Book dentist" }?.id)

        let keyboardOwner = NSPanel(contentRect: CGRect(x: -6_000, y: -6_000, width: 40, height: 40),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        keyboardOwner.isReleasedWhenClosed = false
        keyboardOwner.orderFront(nil)
        AtticTextInput.notePopover(keyboardOwner)
        defer { keyboardOwner.orderOut(nil); keyboardOwner.close() }
        XCTAssertTrue(AtticTextInput.hasKeyboard, "an open pop-over has the keyboard")

        /// Makes `event` the app's current event without delivering it, as
        /// the key that chose a menu item is while the item's command runs.
        func makeCurrent(_ event: NSEvent) {
            NSApp.postEvent(event, atStart: true)
            _ = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
        }
        func chooseOpenFiles(in menu: NSMenu) throws {
            menu.update()
            let more = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu, "with More")
            more.update()
            more.performActionForItem(at: try XCTUnwrap(more.items.firstIndex { $0.title.hasPrefix("Open Files") }))
            hosted.spin(0.3)
        }

        // The right-click menu.
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row)])
        let point = CGPoint(x: frame.minX + 110, y: hosted.height - (frame.minY + 16))
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: hosted.window.windowNumber, context: nil,
                                                     eventNumber: 3, clickCount: 1, pressure: 1))
        let contextMenu = try XCTUnwrap(hosted.window.contentView?.menu(for: press))
        makeCurrent(try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(NSApp.currentEvent?.type, .keyDown, "the Return is the current event")
        try chooseOpenFiles(in: contextMenu)
        XCTAssertEqual(opened, [row], "the right-click menu's Open Files…, chosen with Return, opens the row's files")

        // ⇧⌘I's menu (the same commands as an NSMenu), on a Later row.
        opened = []
        hosted.go(to: .backlog)
        let later = try XCTUnwrap(hosted.model.rows(for: .backlog).first?.id, "Later lists a task")
        makeCurrent(try keyEvent("\r", keyCode: 36))
        try chooseOpenFiles(in: AtticNativeMenu.make(hosted.page.taskCommands(later, tab: .backlog)))
        XCTAssertEqual(opened, [later], "⇧⌘I's Open Files…, chosen with Return, opens them too")

        // The item's own ⌘Return while something types stays with it.
        opened = []
        makeCurrent(try keyEvent("\r", keyCode: 36, modifiers: .command))
        try chooseOpenFiles(in: AtticNativeMenu.make(hosted.page.taskCommands(later, tab: .backlog)))
        XCTAssertEqual(opened, [], "a typing field keeps its own ⌘Return")
    }

    func testOpenFilesPresentationWaitsForTheDefaultRunLoopMode() async throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first?.id)
        let command = try XCTUnwrap(AtticMenuCommand.command(for: AtticTaskShortcut.openPage,
                                                            in: hosted.page.taskCommands(row, tab: .now)))
        var openedMode: CFRunLoopMode?
        let opened = expectation(description: "Open Files is delivered")
        hosted.model.services.openPage = { _ in
            openedMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
            opened.fulfill()
        }
        // Enter the native tracking mode from a run-loop source, not from
        // a main-dispatch callback (which forbids nested queue servicing).
        let invoke = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                command.action()
                let endTracking = Timer(timeInterval: 0.1, repeats: false) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
                RunLoop.main.add(endTracking, forMode: .eventTracking)
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(2))
                endTracking.invalidate()
            }
        }
        RunLoop.main.add(invoke, forMode: .default)
        await fulfillment(of: [opened], timeout: 3)
        invoke.invalidate()
        XCTAssertEqual(openedMode, CFRunLoopMode.defaultMode, "presentation belongs to the default loop, after native menu tracking")
    }

    /// Posts key presses while a menu tracks: each from a timer in the
    /// common modes (menu tracking is not the default mode), with an Esc at
    /// the end so a menu that ignores them cannot hang the run.
    private func schedule(_ keys: [(characters: String, keyCode: UInt16)], in hosted: Hosted) -> [Timer] {
        let window = hosted.window
        func post(_ characters: String, _ keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
            }
        }
        var when: TimeInterval = 0.8
        var timers: [Timer] = []
        for key in keys {
            let timer = Timer(timeInterval: when, repeats: false) { _ in MainActor.assumeIsolated { post(key.characters, key.keyCode) } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            when += 0.2
        }
        let escape = Timer(timeInterval: when + 2, repeats: false) { _ in MainActor.assumeIsolated { post("\u{1B}", 53) } }
        RunLoop.main.add(escape, forMode: .common)
        timers.append(escape)
        return timers
    }

    // MARK: - P2-04: a visible keyboard focus at every Tab stop

    /// Tab through the page: every task row Tab reaches is drawn as the
    /// keyboard's row (its ring on the highlight's edge), and only rows of
    /// the page shown are reached. Neither held: a lazy list's cell read
    /// the page's focus state as it was when the list was built, so the row
    /// that had the keyboard drew no ring; and Tab went on into the rows of
    /// the pages kept built beside the shown one, which are hidden. (The
    /// window server draws the hosted list, which an in-process capture
    /// does not see change, so the cells' own record is read here; the
    /// pixels are `TasksPageUITests`'s.)
    ///
    /// The hosted page is alone in its window, so the window's key loop
    /// passes once through nothing (no view of the page has the keyboard,
    /// nothing is drawn as focused) before it wraps to the first row.
    func testEveryTabStopIsAVisibleRowOrAField() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        XCTAssertNotNil(hosted.model.pagerSwipe.span.warm, "the pages beside Now are kept built")
        let now = hosted.model.rows(for: .now).map(\.id)
        enum Stop: Equatable { case row(UUID), addBar, none }
        func stop() -> Stop {
            if let row = hosted.pointer.keyboardRow { return .row(row.id) }
            return hosted.focus.addBar ? .addBar : .none
        }
        func check(_ stop: Stop, _ stops: [Stop]) {
            guard case let .row(id) = stop else { return }
            XCTAssertEqual(hosted.pointer.keyboardRow?.tab, .now, "Tab stays on the page shown (\(stops))")
            XCTAssertEqual(hosted.pointer.drawnFocus.map(\.id), [id], "only the row Tab reached is drawn with the ring (\(stops))")
            XCTAssertTrue(hosted.model.selection.isEmpty, "Tab selects nothing: the ring alone shows the keyboard")
        }
        var forward: [Stop] = []
        for _ in 0..<(now.count + 3) {
            hosted.press("\t", keyCode: 48)
            hosted.spin(0.2)
            forward.append(stop())
            check(forward.last!, forward)
        }
        XCTAssertEqual(forward, now.map(Stop.row) + [.addBar, .none, .row(now[0])],
                       "Tab: Now's rows, the add bar, then round again (\(forward))")

        var backward: [Stop] = []
        for _ in 0..<4 {
            hosted.press("\u{19}", keyCode: 48, modifiers: .shift)
            hosted.spin(0.2)
            backward.append(stop())
            check(backward.last!, backward)
        }
        XCTAssertEqual(backward, [.none, .addBar, .row(now[now.count - 1]), .row(now[now.count - 2])],
                       "Shift-Tab retraces it, never into a hidden page (\(backward))")

        // Return edits the row that shows the keyboard.
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, now[now.count - 2], "Return edits the row that shows the keyboard")
    }

    // MARK: - P3-01: the strip's values in full

    /// "Tomorrow", "#qatest" and "!!" together, in the strip of the review's
    /// panel (276 pt): at the usual padding they did not fit ("Tomorr…",
    /// "#q…"); with the inner gaps closed up they do. On the default panel
    /// (300 pt) the usual padding stays.
    func testTheStripClosesUpBeforeItCutsCommonValuesShort() {
        typealias Strip = AtticComposerStrip<EmptyView, EmptyView, EmptyView>
        let faces: [(title: String, value: AtticStripValue?)] = [
            ("Date", AtticStripValue(text: "Tomorrow", spoken: "Tomorrow")),
            ("Tag", TasksComposerValues.tags(["qatest"])),
            ("Priority", TasksComposerValues.priority(.high)),
        ]
        let usual = Strip.usualWidth(faces)
        let saved = 3 * (AtticSmallControlMetrics.iconLabelGap - AtticPickerMetrics.stripCompactIconGap
            + AtticPickerMetrics.stripClearGap - AtticPickerMetrics.stripCompactClearGap
            + AtticPickerMetrics.stripValueTrailing - AtticPickerMetrics.stripCompactValueTrailing)
        XCTAssertTrue(Strip.needsCompactGaps(faces, available: 276), "the review's strip is short of room (\(usual))")
        XCTAssertLessThanOrEqual(usual - saved, 276, "closed up, all three values fit in full")
        XCTAssertFalse(Strip.needsCompactGaps(faces, available: 300), "the default panel keeps the usual padding")
        XCTAssertFalse(Strip.needsCompactGaps(faces, available: .infinity), "before it is laid out")
        XCTAssertEqual(TasksComposerValues.tags(["qatest", "work"])?.full, "#qatest #work", "the tooltip names every tag")
    }

    /// CU review P3 (combined app): "Tomorrow" and a short tag with
    /// Priority unset. The empty Priority button gave up nothing, so the
    /// tag was cut to "#c…". Now an unset button shows its icon alone
    /// (Priority first) before any value is cut short or closed up, and it
    /// keeps its name whenever the strip fits.
    func testAnUnsetButtonGivesUpItsNameBeforeAValueIsCutShort() throws {
        typealias Strip = AtticComposerStrip<EmptyView, EmptyView, EmptyView>
        let tomorrow = AtticStripValue(text: "Tomorrow", spoken: "Tomorrow")
        for tag in ["cuqa", "qatest"] {
            let faces: [(title: String, value: AtticStripValue?)] = [
                ("Date", tomorrow), ("Tag", TasksComposerValues.tags([tag])), ("Priority", nil),
            ]
            for available: CGFloat in [276, 300] {
                let full = Strip.usualWidth(faces)
                let iconOnly = Strip.iconOnlyButtons(faces, available: available)
                if full > available {
                    XCTAssertEqual(iconOnly, [2], "#\(tag) at \(available): Priority shows its icon alone (\(full))")
                    XCTAssertLessThanOrEqual(Strip.usualWidth(faces, iconOnly: iconOnly), available,
                                             "#\(tag) at \(available): then the values fit in full")
                    XCTAssertFalse(Strip.needsCompactGaps(faces, available: available, iconOnly: iconOnly))
                } else {
                    XCTAssertEqual(iconOnly, [], "it fits: every name stays")
                }
            }
        }
        // The capture's case does need it at the review's width.
        let capture: [(title: String, value: AtticStripValue?)] = [("Date", tomorrow), ("Tag", TasksComposerValues.tags(["cuqa"])), ("Priority", nil)]
        XCTAssertGreaterThan(Strip.usualWidth(capture), 276, "the names did not fit")
        // Unset buttons only, and only with a value to make room for.
        let empty: [(title: String, value: AtticStripValue?)] = [("Date", nil), ("Tag", nil), ("Priority", nil)]
        XCTAssertEqual(Strip.iconOnlyButtons(empty, available: 100), [])
        let set: [(title: String, value: AtticStripValue?)] = [("Date", tomorrow), ("Tag", TasksComposerValues.tags(["a-much-longer-tag"])),
                                                               ("Priority", TasksComposerValues.priority(.high))]
        XCTAssertEqual(Strip.iconOnlyButtons(set, available: 200), [], "a set button keeps its value")
        // Short of room still, Tag's empty name goes next, never Date's value.
        let tagless: [(title: String, value: AtticStripValue?)] = [("Date", AtticStripValue(text: "Wednesday, 15 October", spoken: "")), ("Tag", nil), ("Priority", nil)]
        XCTAssertEqual(Strip.iconOnlyButtons(tagless, available: 200), [1, 2])
    }

    // MARK: - Code review: the pager's test-only settle

    func testThePagerSettleOverrideNeedsAUITestPreviewAndASaneDuration() {
        func resolve(_ value: String, testing: Bool = true, identity: String? = "com.taha.Attic.preview.glass") -> Double? {
            var environment = ["ATTIC_UI_TEST_PAGER_SETTLE": value]
            if testing { environment["ATTIC_UI_TESTING"] = "1" }
            return TasksPagerMotion.resolveSettleOverride(environment: environment, bundleIdentifier: identity)
        }
        XCTAssertEqual(resolve("1.5"), 1.5, "a UI-tested preview may slow the settle")
        XCTAssertNil(resolve("1.5", testing: false), "not without UI testing")
        for identity in ["com.taha.Attic", "com.taha.Attic.preview.", "com.taha.AtticTests", "com.taha.Attic.UnitTestHost"] {
            XCTAssertNil(resolve("1.5", identity: identity), "\(identity) ignores it")
        }
        XCTAssertNil(resolve("1.5", identity: nil))
        for bad in ["nan", "inf", "-1", "0", "0.01", "60", "fast", ""] {
            XCTAssertNil(resolve(bad), "\(bad) is not a supported duration")
        }
        XCTAssertEqual(resolve("0.05"), 0.05)
        XCTAssertEqual(resolve("10"), 10)
    }
}
