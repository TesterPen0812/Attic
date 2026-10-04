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
        let first = try XCTUnwrap(rows.first)
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
        let order = hosted.model.rows(for: .now).filter { $0.status == .todo }.map(\.id)
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
        XCTAssertTrue(notes.contains { $0.body.contains("- [ ]") && $0.body.contains("**") }, "formatting and a checklist")
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

    func testOnlyAPreviewBuildsMenuOffersLoadDemoData() {
        func titles(_ load: (() -> Void)?) -> [String] {
            MenuBarCommands.commands(advertisedNewTaskShortcut: nil, showPanel: {}, newTask: {}, newNote: {}, search: {},
                                     openSettings: {}, quit: {}, loadDemoData: load).map(\.title)
        }
        XCTAssertFalse(titles(nil).contains("Load Demo Data"))
        XCTAssertTrue(titles({}).contains("Load Demo Data"))
    }
}
