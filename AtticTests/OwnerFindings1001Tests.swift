import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The owner's hands-on findings on Phase 1 (2026-10-01, on `c2b41d0`).
@MainActor
final class OwnerFindings1001Tests: XCTestCase {
    // MARK: - 1. Hover is a soft tint only

    /// The pointer's hover tints the row and nothing moves: the actions
    /// button (which pushed the date aside) is the keyboard's only.
    func testHoverIsATintOnlyAndMovesNothing() {
        XCTAssertFalse(AtticTaskRow.showsActionsButton(forced: nil, keyboardFocused: false), "at rest")
        XCTAssertFalse(AtticTaskRow.showsActionsButton(forced: .hover, keyboardFocused: false), "hovered: a tint only")
        XCTAssertTrue(AtticTaskRow.showsActionsButton(forced: nil, keyboardFocused: true), "the keyboard's row")
        XCTAssertTrue(AtticTaskRow.showsActionsButton(forced: .focused, keyboardFocused: false), "the gallery's focused state")
    }

    // MARK: - 2. One click activates the panel and acts

    private final class Recorder: NSView {
        var presses = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) { presses += 1 }
        override func rightMouseDown(with event: NSEvent) { presses += 1 }
    }

    /// A press on a panel that is not key reaches the control under it at
    /// once, even one that does not accept the first mouse (SwiftUI's own
    /// views in a list), and the panel becomes key without activating Attic.
    func testOneClickOnAnInactivePanelBothActivatesItAndActs() throws {
        try requireKeyWindowTests()
        let other = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 200, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let panel = AtticPanel(contentRect: CGRect(x: -5_000, y: -5_000, width: 300, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let recorder = Recorder(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        panel.contentView = recorder
        panel.orderFront(nil)
        other.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(panel.isKeyWindow, "the panel starts inactive")

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            other.makeKeyAndOrderFront(nil)
            let before = recorder.presses
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 150, y: 150), modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            panel.sendEvent(event)
            XCTAssertEqual(recorder.presses, before + 1, "\(type): the first click acts")
            XCTAssertTrue(panel.isKeyWindow, "\(type): and the panel is key")
        }
    }
}

// MARK: - O14-01: one click always registers

/// O14-01 guard: wherever a press reaches the panel before it is key, the
/// panel's AppKit views under it (text, scroll and table views) accept the
/// first mouse, on the Tasks and Notes pages. (SwiftUI's views are left to
/// `AtticPanel.sendEvent`, which makes the panel key before the press.)
@MainActor
final class O14FirstMouseTests: XCTestCase {
    private final class RefusingScrollView: NSScrollView {
        override dynamic func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    }

    func testNativeScrollFirstMousePolicyFollowsItsWindow() {
        let scroll = RefusingScrollView()
        let panel = AtticPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let ordinary = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        ordinary.isReleasedWhenClosed = false
        defer { panel.close(); ordinary.close() }
        ordinary.contentView = scroll
        XCTAssertFalse(scroll.acceptsFirstMouse(for: nil))
        AtticPanelFirstMouseHooks.install(on: scroll)
        XCTAssertFalse(scroll.acceptsFirstMouse(for: nil), "ordinary windows keep the native policy")
        panel.contentView = scroll
        XCTAssertTrue(scroll.acceptsFirstMouse(for: nil), "a panel's first press is accepted")
        AtticPanelFirstMouseHooks.install(on: scroll)
        ordinary.contentView = scroll
        XCTAssertFalse(scroll.acceptsFirstMouse(for: nil), "moving out restores the native answer, even after repeated hits")
    }

    /// Owner, 2026-10-31 ("one click makes the panel active"): every view a
    /// press can reach on the panel accepts the first press, on every page
    /// and state: Tasks (Now, Later, Done, a task's page), the Notes list,
    /// board and a note, the Calendar page, each page's open search, and the
    /// top row and bottom bar. Every class counts, SwiftUI's and AppKit's own
    /// included: any one that refuses spends the press on activation.
    func testEveryViewUnderAPressOnThePanelAcceptsTheFirstMouse() throws {
        let suite = "O14FirstMouse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        for title in ["Launch plan", "Groceries", "Reading list"] {
            _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text(title)]), tags: ["home"]).get()
        }
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let draft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft,
                                     chromeInteractionState: chrome, uiState: state, settings: settings,
                                     tasksPageState: tasksState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        defer { host.cancelActiveInteraction(reason: .lostWindow); state.releasePageContent(); panel.close() }
        let model = tasksState.model(for: store, toasts: nil)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func press(_ identifier: String) throws {
            let element = try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier },
                                        "\(identifier) is on the panel")
            XCTAssertTrue(element.accessibilityPerformPress?() ?? false, "\(identifier) presses")
            spin(0.8)
        }
        // A press every 6 pt over the whole panel, top row and bottom bar
        // included, as the window would deliver it.
        func assertEveryViewAccepts(_ name: String) {
            content.layoutSubtreeIfNeeded()
            var refusing: [String: Int] = [:]
            let bounds = content.bounds
            for x in stride(from: bounds.minX + 4, to: bounds.maxX - 4, by: 6) {
                for y in stride(from: bounds.minY + 4, to: bounds.maxY - 4, by: 6) {
                    let point = CGPoint(x: x, y: y)
                    guard let hit = content.hitTest(point) else { continue }
                    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: content.convert(point, to: nil), modifierFlags: [],
                                                   timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1)
                    if !hit.acceptsFirstMouse(for: event) { refusing[String(describing: type(of: hit)), default: 0] += 1 }
                }
            }
            XCTAssertEqual(refusing, [:], "\(name): views that would spend the first click on activation")
        }

        state.selectSection(.tasks)
        spin(1.5)
        for tab in TasksTab.allCases {
            model.tab = tab
            spin(0.8)
            assertEveryViewAccepts("Tasks \(tab)")
        }
        model.tab = .now
        spin(0.5)
        try press("tasks-find-button")
        assertEveryViewAccepts("Tasks search")
        host.cancelActiveInteraction(reason: .lostWindow)
        if let id = model.rows(for: .now).first?.model.id {
            model.openPage(id)
            spin(1.0)
            assertEveryViewAccepts("a task's page")
        } else {
            XCTFail("the demo has a task in Now")
        }

        // Notes opens on a note; Back shows the list.
        state.selectSection(.notes)
        spin(1.5)
        XCTAssertFalse(draft.pages.isLibraryPresented, "a note is open")
        assertEveryViewAccepts("a note")
        XCTAssertTrue(draft.pages.showLibrary())
        spin(1.0)
        assertEveryViewAccepts("Notes list")
        try press("notes-layout-board")
        assertEveryViewAccepts("Notes board")
        try press("notes-search-button")
        assertEveryViewAccepts("Notes search")

        state.selectSection(.calendar)
        spin(1.5)
        assertEveryViewAccepts("Calendar")
        try press("calendar-search-button")
        assertEveryViewAccepts("Calendar search")
    }
}

@MainActor
final class O14FirstClickKeyLookTests: XCTestCase {
    /// The cause of O14-01: on a Solid panel the corner buttons are flat
    /// while the panel is not key and glass once it is. The press that made
    /// the panel key redrew the pin it was pressing (flat to glass), so the
    /// press was lost and only a second click pinned. The key look now
    /// waits for the release; the click pins at once, and the look follows.
    func testOneClickOnTheSolidPanelsPinPinsItAndTheKeyLookFollowsTheRelease() throws {
        try requireKeyWindowTests()
        let suite = "O14KeyLook.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: persistence)
        let store = TaskStore(container: persistence)
        let notes = NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore())
        let settings = AppSettings(defaults: defaults)
        settings.panelSurfaceStyle = .solid
        let uiState = PanelUIState()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let other = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 200, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close(); panel.orderOut(nil); withExtendedLifetime(controller) {} }
        let size = CGSize(width: 340, height: 560)
        panel.setVisibleContentFrame(CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size), display: false)
        uiState.updatePanelSize(size)
        uiState.loadPageContent()
        uiState.selectSection(.tasks)
        panel.orderFront(nil)
        other.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(uiState.isPanelKey)
        XCTAssertFalse(uiState.isPanelPinned)

        // The pin's middle: the header's leading button, 18 pt in from the
        // surface's top-left corner and the chrome inset.
        let content = try XCTUnwrap(panel.contentView)
        let insets = PanelGeometry.chromeInsets(cornerSize: settings.panelCornerSize, panelSize: size)
        let surfacePoint = CGPoint(x: insets.leading + PanelHeaderLayout.pinSize.width / 2,
                                   y: insets.top + PanelHeaderLayout.height / 2)
        let surface = panel.visibleContentFrame
        let screenPoint = CGPoint(x: surface.minX + surfacePoint.x, y: surface.maxY - surfacePoint.y)
        let location = panel.convertPoint(fromScreen: screenPoint)
        XCTAssertNotNil(content.hitTest(content.superview?.convert(location, from: nil) ?? location))
        func press(_ type: NSEvent.EventType) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            panel.sendEvent(event)
        }
        try press(.leftMouseDown)
        XCTAssertTrue(panel.isKeyWindow, "the press makes the panel key")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(uiState.isPanelKey, "the key look waits while the button is down")
        try press(.leftMouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(uiState.isPanelPinned, "one click pins")
        XCTAssertTrue(uiState.isPanelKey, "and the panel shows as key after the release")
    }
}

/// O14-05 (owner, 2026-10-14): the pinned pin is filled, and under the
/// pointer it shows the unpin glyph; unpinned it stays the outline pin.
final class O14PinGlyphTests: XCTestCase {
    func testThePinsGlyphForEachState() {
        typealias M = AtticRaisedButtonMetrics
        let pinned = { (state: AtticControlState) in M.shownSymbol("pin", on: M.pinnedSymbol, onHover: M.unpinSymbol, state: state) }
        XCTAssertEqual(M.shownSymbol("pin", on: nil, onHover: nil, state: .rest), "pin", "unpinned")
        XCTAssertEqual(M.shownSymbol("pin", on: nil, onHover: nil, state: .hover), "pin", "unpinned, hovered")
        XCTAssertEqual(pinned(.rest), "pin.fill")
        XCTAssertEqual(pinned(.focused), "pin.fill")
        XCTAssertEqual(pinned(.hover), "pin.slash")
        XCTAssertEqual(pinned(.pressed), "pin.slash")
        for name in [M.pinnedSymbol, M.unpinSymbol] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }
}

// MARK: - 3. Thin overlay scrollers, hidden during page swipes

@MainActor
final class OwnerFindingsScrollerTests: XCTestCase {
    func testTwoFingersHideTheScrollersUntilTheGestureIsVertical() {
        typealias Rule = TasksScrollerRule
        XCTAssertEqual(Rule.change(phase: .mayBegin, momentum: false, axis: nil), .hide, "fingers down: nothing yet")
        XCTAssertEqual(Rule.change(phase: .began, momentum: false, axis: .undecided), .hide)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .horizontal), .hide, "a page swipe")
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .turned), .hide)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .vertical), .show, "a vertical scroll")
        XCTAssertEqual(Rule.change(phase: .changed, momentum: false, axis: .foreign), .show, "not over the pager")
        XCTAssertEqual(Rule.change(phase: .ended, momentum: false, axis: .horizontal), .showLater, "after the swipe's flash")
        XCTAssertEqual(Rule.change(phase: .ended, momentum: false, axis: .vertical), .keep)
        XCTAssertEqual(Rule.change(phase: .changed, momentum: true, axis: .horizontal), .keep, "momentum changes nothing")
        XCTAssertEqual(Rule.change(phase: .none, momentum: false, axis: nil), .show, "a mouse wheel scrolls vertically")
    }

    /// The lists keep thin overlay scrollers whatever the system setting,
    /// even when AppKit (a setting change) or SwiftUI sets them back.
    func testTheListsKeepThinOverlayScrollers() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        hosted.spin(1)
        let content = try XCTUnwrap(hosted.window.contentView)
        let lists = hosted.lists(in: content).filter { $0.verticalScroller != nil && $0.frame.height > 200 }
        XCTAssertFalse(lists.isEmpty)
        for list in lists {
            XCTAssertEqual(list.scrollerStyle, .overlay)
            XCTAssertEqual(list.verticalScroller?.controlSize, .small, "thin")
            list.scrollerStyle = .legacy
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            hosted.spin(0.5)
            XCTAssertEqual(list.scrollerStyle, .overlay, "set back when the system setting changes")
            list.scrollerStyle = .legacy
            list.contentView.scroll(to: CGPoint(x: 0, y: 40))
            list.reflectScrolledClipView(list.contentView)
            hosted.spin(0.2)
            XCTAssertEqual(list.scrollerStyle, .overlay, "and as the list scrolls")
        }
        let proxies = TasksListProxies()
        let list = try XCTUnwrap(lists.first)
        proxies.scrollViews = [.now: list]
        proxies.apply(.hide)
        XCTAssertEqual(list.verticalScroller?.isHidden, true, "hidden during a swipe")
        proxies.apply(.show)
        XCTAssertEqual(list.verticalScroller?.isHidden, false, "back for vertical scrolling")
        let note = NoteDocumentScrollView()
        note.scrollerStyle = .legacy
        XCTAssertEqual(note.scrollerStyle, .overlay, "the note editor too")
    }
}

// MARK: - 4. The lifted card: on top, opaque, steady

@MainActor
final class OwnerFindingsReorderTests: XCTestCase {
    func testTheLiftedCardIsOpaqueInEveryAppearance() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for surface in PanelSurfaceStyle.allCases {
                var design = AtticDesignContext(mode: mode)
                design.surface = surface
                XCTAssertEqual(AtticReorderLiftModifier.fill(design: design).alpha, 1, "\(mode) \(surface)")
            }
        }
    }

    /// The card lands in the gap the neighbours opened, less what the list
    /// scrolled under it.
    func testTheCardLandsInTheGap() {
        let ids = (0..<5).map { _ in UUID() }
        let heights: [UUID: CGFloat] = [ids[0]: 34, ids[1]: 48, ids[2]: 34, ids[3]: 34, ids[4]: 48]
        var drag = TasksDrag(id: ids[1], tab: .now, group: ids, startIndex: 1, targetIndex: 3)
        XCTAssertEqual(TasksLiftedCard.landing(of: drag, originY: 100, heights: { heights[$0] ?? 0 }), 100 + 34 + 34, "down two")
        drag.targetIndex = 0
        XCTAssertEqual(TasksLiftedCard.landing(of: drag, originY: 100, heights: { heights[$0] ?? 0 }), 100 - 34, "up one")
        drag.targetIndex = 1
        drag.scrolled = 20
        XCTAssertEqual(TasksLiftedCard.landing(of: drag, originY: 100, heights: { heights[$0] ?? 0 }), 80, "back home, scrolled")
    }

    /// A real drag: the card follows the pointer exactly (scrolling never
    /// moves it), the row's own place shows nothing meanwhile, and on
    /// release the move is made and the card goes.
    func testTheCardStaysUnderThePointerAndTheMoveLands() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        let rows = hosted.model.rows(for: .now).filter { $0.status == .todo }
        XCTAssertGreaterThanOrEqual(rows.count, 3)
        // The owner's panel design: a row moves within its date group, so
        // the dragged row is the first of a group with another below it.
        let first = try XCTUnwrap(rows.first { row in
            let group = hosted.model.shownGroup(of: row.id, status: .todo, on: .now)
            return group.count >= 2 && group.first == row.id
        })
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first.id)])
        let start = CGPoint(x: 200, y: frame.midY)
        let window = hosted.window
        func post(_ type: NSEvent.EventType, y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x, y: hosted.height - y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 3, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        var seen: [(card: CGFloat, pointer: CGFloat)] = []
        var hiddenRowSeen = false
        let steps: [CGFloat] = [6, 20, 40, 60, 75]
        post(.leftMouseDown, y: start.y)
        for step in steps { post(.leftMouseDragged, y: start.y + step) }
        // Read while the button is still down (a timer fires inside any
        // tracking loop), then release.
        let probe = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let lift = hosted.pointer.liftedCard.lift {
                    seen.append((lift.y, lift.origin.minY + (steps.last ?? 0)))
                }
                hiddenRowSeen = hosted.model.rows(for: .now).contains { $0.id == first.id }
                post(.leftMouseUp, y: start.y + (steps.last ?? 0))
            }
        }
        RunLoop.main.add(probe, forMode: .common)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, probe.isValid || NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: false) != nil {
            Hosted.pumpEvents(limit: 8)
            hosted.spin(0.05)
        }
        hosted.spin(1)
        let card = try XCTUnwrap(seen.first, "a card was lifted")
        XCTAssertEqual(card.card, card.pointer, accuracy: 0.5, "the card is exactly under the pointer")
        XCTAssertTrue(hiddenRowSeen)
        XCTAssertNil(hosted.pointer.liftedCard.lift, "the card goes once it has landed")
        let order = hosted.model.shownGroup(of: first.id, status: .todo, on: .now)
        XCTAssertNotEqual(order.first, first.id, "the row moved down")
    }
}

// MARK: - 5. Demo data, in preview builds only

@MainActor
final class OwnerFindingsDemoDataTests: XCTestCase {
    func testDemoDataNeverLoadsOutsideAPreviewIdentity() throws {
        XCTAssertFalse(AtticDemoData.isAllowed(bundleIdentifier: "com.taha.Attic"), "never the release identity")
        XCTAssertFalse(AtticDemoData.isAllowed(bundleIdentifier: nil))
        XCTAssertFalse(AtticDemoData.isAllowed(bundleIdentifier: "com.taha.Attic.preview."))
        XCTAssertFalse(AtticDemoData.isAllowed(bundleIdentifier: "com.taha.Attic.dira"))
        XCTAssertFalse(AtticDemoData.isAllowed(bundleIdentifier: "com.emanueledipietro.Attic"))
        XCTAssertTrue(AtticDemoData.isAllowed(bundleIdentifier: "com.taha.Attic.preview.main"))

        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        XCTAssertEqual(try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic"), 0)
        XCTAssertTrue(AtticDemoData.storeIsEmpty(container), "nothing was written under the release identity")
    }

    func testThePreviewDemoIsRealisticAndLoadsOnce() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let added = try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic.preview.main", now: now)
        XCTAssertGreaterThan(added, 30)
        XCTAssertEqual(try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic.preview.main", now: now), 0,
                       "loading again adds nothing twice")
        let context = ModelContext(container)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let top = tasks.filter { $0.parentID == nil }
        let today = DueDay(date: now, calendar: calendar)
        XCTAssertTrue(top.contains { $0.status == .inProgress }, "a task in progress")
        XCTAssertTrue(top.contains { $0.status == .backlog }, "Later")
        XCTAssertTrue(top.contains { ($0.dueDay.map { $0 < today }) == true && $0.status != .done }, "overdue")
        XCTAssertTrue(top.contains { $0.dueDay == today }, "today")
        XCTAssertTrue(top.contains { ($0.dueDay.map { $0 > today }) == true }, "future")
        for priority in [TaskPriority.low, .medium, .high] {
            XCTAssertTrue(top.contains { $0.priority == priority }, "\(priority)")
        }
        XCTAssertTrue(top.contains { !$0.tags.isEmpty }, "tags")
        XCTAssertTrue(tasks.contains { $0.parentID != nil }, "subtasks")
        let doneDays = Set(top.filter { $0.doneLoggedAt != nil }.compactMap { $0.completedAt.map { calendar.startOfDay(for: $0) } })
        XCTAssertGreaterThanOrEqual(doneDays.count, 3, "a few Done days")
        XCTAssertTrue(tasks.allSatisfy { AtticDemoData.isDemo($0.id) })
        let notes = try context.fetch(FetchDescriptor<NoteItem>())
        XCTAssertGreaterThanOrEqual(notes.count, 3)
        XCTAssertTrue(notes.contains { note in
            let blocks = note.content.flatMap { NoteContentCodec.decode($0).document }?.blocks ?? []
            return blocks.contains { $0.kind == .checklist } && blocks.contains { $0.marks.contains { $0.kind == .bold } }
        }, "formatting and a checklist")
    }

    func testTheDemoNoteGetsAnImageAndAFile() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic.preview.main")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDemoTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: root))
        await AtticDemoData.attachFiles(to: notes, bundleIdentifier: "com.taha.Attic.preview.main")
        let names = notes.attachments(for: AtticDemoData.attachmentsNoteID).map(\.originalFilename).sorted()
        XCTAssertEqual(names, ["Palette.png", "Type specimen.txt"])
        await AtticDemoData.attachFiles(to: notes, bundleIdentifier: "com.taha.Attic.preview.main")
        XCTAssertEqual(notes.attachments(for: AtticDemoData.attachmentsNoteID).count, 2, "never twice")
    }

    /// The sample notes are real formatted documents (owner, 2026-10-21:
    /// the preview showed `# Before launch`, `- [x] …`, `**FAQ**` as text).
    func testTheDemoNotesAreFormattedDocumentsWithoutMarkdownMarkers() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic.preview.main")
        let notes = try ModelContext(container).fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(notes.count, 3)
        for note in notes {
            let document = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document }, note.title)
            for block in document.blocks {
                for marker in ["# ", "- [", "[x]", "[ ]", "**", "*two", "- ", "1. ", "2. "] {
                    XCTAssertFalse(block.text.hasPrefix(marker) || (marker.count > 2 && block.text.contains(marker)),
                                   "\(note.title): literal \(marker) in \(block.text)")
                }
            }
            XCTAssertFalse(note.plainText.contains("**"), note.title)
        }
        let pricing = try XCTUnwrap(notes.first { $0.id == AtticDemoData.id(1_001) })
        let blocks = try XCTUnwrap(pricing.content.flatMap { NoteContentCodec.decode($0).document }).blocks
        XCTAssertEqual(blocks.first?.text, "Pricing page", "the title block")
        func block(_ text: String) throws -> NoteBlock { try XCTUnwrap(blocks.first { $0.text == text }, text) }
        XCTAssertEqual(try block("Before launch").style, "heading")
        XCTAssertEqual(try block("Before launch").level, 1)
        XCTAssertEqual(try block("Open questions").level, 2)
        XCTAssertEqual(try block("Final copy from Sam").kind, .checklist)
        XCTAssertTrue(try block("Final copy from Sam").checked)
        XCTAssertEqual(try block("One screenshot per plan").kind, .checklist)
        XCTAssertFalse(try block("One screenshot per plan").checked)
        XCTAssertEqual(try block("Talk to three customers").style, "number")
        let faq = try block("Draft the FAQ")
        XCTAssertEqual(faq.style, "number")
        XCTAssertEqual(faq.marks.map(\.kind), [.bold])
        XCTAssertEqual(faq.marks.first.map { (faq.text as NSString).substring(with: NSRange(location: $0.offset, length: $0.length)) }, "FAQ")
        let annual = try block("Annual plan: two months free?")
        XCTAssertEqual(annual.style, "bullet")
        XCTAssertEqual(annual.marks.map(\.kind), [.italic])
        XCTAssertEqual(annual.marks.first.map { (annual.text as NSString).substring(with: NSRange(location: $0.offset, length: $0.length)) }, "two months")
        XCTAssertEqual(try block("Student pricing").style, "bullet")
        XCTAssertEqual(try block("price = base * seats").style, "mono")
        XCTAssertNil(try block("Simple beats clever.").style, "a body paragraph")
        // The plain notes keep one paragraph per line, as typed.
        let weekend = try XCTUnwrap(notes.first { $0.id == AtticDemoData.id(1_003) })
        let weekendBlocks = try XCTUnwrap(weekend.content.flatMap { NoteContentCodec.decode($0).document }).blocks
        XCTAssertEqual(weekendBlocks.map(\.text), ["Weekend", "Farmers' market on Saturday morning.",
                                                   "Bike the river path if it's dry.", "Call Mum on Sunday."])
    }

    /// Load Demo Data replaces an older seed's untouched raw-Markdown copy
    /// with the formatted note, and leaves an edited one alone.
    func testLoadDemoDataFormatsOnlyAnUntouchedRawMarkdownSeed() throws {
        for edited in [false, true] {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let context = ModelContext(container)
            let legacy = NoteItem(id: AtticDemoData.id(1_001), title: "Pricing page", body: AtticDemoData.pricingNote)
            if edited { legacy.revisionID = UUID(); legacy.revision = 1 }
            context.insert(legacy)
            try context.save()
            let before = legacy.content
            try AtticDemoData.seed(into: container, bundleIdentifier: "com.taha.Attic.preview.main")
            let note = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteItem>())
                .first { $0.id == AtticDemoData.id(1_001) })
            if edited {
                XCTAssertEqual(note.content, before, "an edited note is never replaced")
            } else {
                XCTAssertFalse(note.plainText.contains("**"), "formatted")
                let blocks = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document }).blocks
                XCTAssertTrue(blocks.contains { $0.style == "heading" && $0.text == "Before launch" })
            }
        }
    }

    func testOnlyAPreviewBuildsMenuOffersLoadDemoData() {
        func titles(_ load: (() -> Void)?) -> [String] {
            MenuBarCommands.commands(advertisedNewTaskShortcut: nil, showPanel: {}, newTask: {}, newNote: {}, search: {},
                                     openSettings: {}, quit: {}, loadDemoData: load).map(\.title)
        }
        XCTAssertFalse(titles(nil).contains("Load Demo Data"))
        XCTAssertTrue(titles({}).contains("Load Demo Data"))
    }
}
