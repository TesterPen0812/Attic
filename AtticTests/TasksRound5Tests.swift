import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Round 5: the owner's items after the round 4 preview.
@MainActor
final class TasksRound5Tests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var gate: PersistenceGate!
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value }, persist: gate.save)
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { Calendar(identifier: .gregorian) },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
        gate = nil
    }

    // MARK: - An open picker is edit mode (the owner's item 2)

    func testEditModeHoldsThePanelUntilItClosesThenAShortGrace() async throws {
        var applied: [Bool] = []
        let hold = PanelEditHold(grace: .milliseconds(80)) { applied.append($0) }
        hold.set(true)
        hold.set(true)
        XCTAssertEqual(applied, [true], "one lock however many things are open")
        hold.set(false)
        XCTAssertTrue(hold.isHeld, "closing starts the grace; the panel is still held")
        XCTAssertEqual(applied, [true])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(applied, [true, false], "after the grace the hover rules resume")
        XCTAssertFalse(hold.isHeld)

        // Something opens again within the grace: the hold never lapses.
        hold.set(true)
        hold.set(false)
        try await Task.sleep(for: .milliseconds(20))
        hold.set(true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(applied, [true, false, true], "no release while a second picker is open")
        hold.end()
        XCTAssertEqual(applied, [true, false, true, false], "hiding ends it with no grace")

        // The page goes behind another page with an editor open: no hold
        // for that page; back in front, the open editor holds again.
        hold.set(true)
        XCTAssertEqual(applied.last, true)
        hold.setSuspended(true)
        XCTAssertEqual(applied.last, false, "released at once, no grace")
        hold.set(true)
        XCTAssertEqual(applied.last, false, "a suspended page holds nothing")
        hold.setSuspended(false)
        XCTAssertEqual(applied.last, true, "in front again, the editor still open holds the panel")
        hold.set(false)
        hold.setSuspended(true)
        hold.setSuspended(false)
        XCTAssertEqual(applied.last, false, "nothing open: nothing held on return")
    }

    func testTheEditingLockNeverLapsesLikeTypingFocus() {
        // Typing focus alone lapses once the pointer is out and the
        // keyboard idle; edit mode (a picker, an editor) does not.
        XCTAssertFalse(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.quickEntryFocus], pointerInside: false, secondsSinceKeyboardInput: 60))
        XCTAssertTrue(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.taskEditing], pointerInside: false, secondsSinceKeyboardInput: 60))
        XCTAssertTrue(MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: [.quickEntryFocus, .taskEditing], pointerInside: false, secondsSinceKeyboardInput: 60))
    }

    // MARK: - One swipe, one page (the owner's item 4)

    func testASwipeMovesAtMostOnePage() {
        let width: CGFloat = 320
        func land(_ x: CGFloat, from current: Int) -> Int {
            TasksPagerBehavior.page(proposed: x, width: width, current: current, count: 3)
        }
        XCTAssertEqual(land(2 * width, from: 0), 1, "a hard swipe from Now stops at Later")
        XCTAssertEqual(land(10 * width, from: 0), 1, "however far the momentum would carry it")
        XCTAssertEqual(land(0, from: 2), 1, "from Done, back to Later, not Now")
        XCTAssertEqual(land(-5 * width, from: 1), 0)
        XCTAssertEqual(land(width * 0.4, from: 0), 0, "a short drag settles back")
        XCTAssertEqual(land(width * 0.6, from: 0), 1, "past halfway it turns the page")
        XCTAssertEqual(land(3 * width, from: 2), 2, "never past the last page")
        XCTAssertEqual(land(-width, from: 0), 0, "nor before the first")
        XCTAssertEqual(TasksPagerBehavior.page(proposed: 500, width: 0, current: 1, count: 3), 1, "no width yet: stay")
    }

    // MARK: - F4: a drag's eligibility is decided at the press

    func testATitlePressStaysADragAsTheRowMovesPastItsControls() {
        let session = TasksDragSession()
        let row = UUID()
        // The checklist, in the row's own space (Astra's geometry).
        session.controlFrames[row] = [CGRect(x: 56, y: 26, width: 40, height: 16)]
        var origin = CGPoint(x: 12, y: 200)
        var decisions = 0
        let decide: (CGPoint) -> Bool = { point in
            decisions += 1
            return !session.isOnControl(row, at: point, rowOrigin: origin)
        }
        let press = CGPoint(x: 80, y: 210)   // on the title line, above the checklist
        XCTAssertTrue(session.allows(row, start: press, decide: decide), "a title press drags")
        // The row lifts and travels up (and the list scrolls): measured
        // now, the same press point would fall on the checklist.
        origin = CGPoint(x: 12, y: 180)
        XCTAssertTrue(session.isOnControl(row, at: press, rowOrigin: origin), "the geometry that used to stop the drag")
        for _ in 0..<5 { XCTAssertTrue(session.allows(row, start: press, decide: decide), "updates keep the press's answer") }
        XCTAssertTrue(session.allows(row, start: press, decide: decide), "and so does the release")
        XCTAssertEqual(decisions, 1, "decided once, at the press")
        session.end()

        // The next press is decided afresh: with the row now at y 180,
        // this one is on the checklist.
        XCTAssertEqual(origin, CGPoint(x: 12, y: 180))
        XCTAssertFalse(session.allows(row, start: CGPoint(x: 80, y: 214), decide: decide), "a press on a control never drags")
        origin = CGPoint(x: 12, y: 230)
        XCTAssertFalse(session.allows(row, start: CGPoint(x: 80, y: 214), decide: decide), "however the row moves after")
        XCTAssertEqual(decisions, 2)
        // That press never dragged, so no gesture ended it; the next mouse
        // down at the same point, the row now elsewhere, decides afresh.
        session.newPress()
        XCTAssertTrue(session.allows(row, start: CGPoint(x: 80, y: 214), decide: decide), "a new press is not the old one")
        XCTAssertEqual(decisions, 3)
        session.end()
    }

    // MARK: - F5: every caller reports its outcome

    private var page: TasksPage {
        TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 344, height: 520)),
                  addBarFocused: .constant(false))
    }

    func testShiftSpaceAndCommandBShowTheRowsFailureWithRetry() throws {
        let task = try XCTUnwrap(store.create(title: "Pay rent"))
        let actions = page.actions(for: task.id, in: .now)

        gate.shouldFail = true
        actions.toggleWorking?()
        XCTAssertEqual(model.rowFailure?.id, task.id, "⇧Space's failure shows under its row")
        XCTAssertEqual(store.task(withID: task.id)?.status, .todo)
        gate.shouldFail = false
        model.retryRowFailure()
        XCTAssertNil(model.rowFailure)
        XCTAssertEqual(store.task(withID: task.id)?.status, .inProgress, "Retry started it")

        gate.shouldFail = true
        actions.moveToBacklog?()
        XCTAssertEqual(model.rowFailure?.id, task.id, "⌘B's failure shows under its row")
        gate.shouldFail = false
        model.retryRowFailure()
        XCTAssertEqual(store.task(withID: task.id)?.status, .backlog, "Retry moved it to Later")
    }

    func testARetriedNewTagFinishesThePickersTypedEntry() throws {
        let task = try XCTUnwrap(store.create(title: "Pay rent"))
        var cleared = 0
        gate.shouldFail = true
        let saved = model.pickerChange(on: task.id, onSaved: { cleared += 1 }) { self.model.toggleTag("garden", for: [task.id]) }
        XCTAssertFalse(saved, "the create did not save: the typed name stays")
        XCTAssertEqual(cleared, 0)
        XCTAssertNotNil(model.pickerFailure)
        // Retry fails again: still pending.
        XCTAssertFalse(model.retryPickerChange())
        XCTAssertEqual(cleared, 0)
        gate.shouldFail = false
        XCTAssertTrue(model.retryPickerChange())
        XCTAssertEqual(cleared, 1, "the saved tag's name is cleared, so Return can't toggle it off")
        XCTAssertTrue(store.task(withID: task.id)?.tags.contains("garden") == true)
        XCTAssertNil(model.pickerFailure)
        // A toggle's retry finishes nothing of the entry.
        gate.shouldFail = true
        model.pickerChange(on: task.id) { self.model.toggleTag("garden", for: [task.id]) }
        gate.shouldFail = false
        XCTAssertTrue(model.retryPickerChange())
        XCTAssertEqual(cleared, 1)
    }

    // MARK: - An open pop-over keeps its keys (the class of the owner's blocker)

    func testAnAtticPopoversWindowOwnsItsKeys() {
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 200, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        XCTAssertFalse(AtticTextInput.isPopover(window), "a window that shows no pop-over")
        // The marker `atticPopover` puts behind a pop-over's content.
        window.contentView?.addSubview(AtticPopoverWindowMarker.Marker(frame: .zero))
        XCTAssertTrue(AtticTextInput.isPopover(window), "a pop-over's window: its keys are its own")
        XCTAssertFalse(AtticTextInput.isPopoverOpen, "not on screen yet")
        // On screen, key or not (AppKit may leave the keys with the window
        // that presented it), no row or page command answers a key.
        // Ordered in only on CI (ATTIC_KEY_WINDOW_TESTS): off screen, but a
        // window all the same, and a person's Mac is left alone.
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else { return }
        window.orderFront(nil)
        XCTAssertTrue(AtticTextInput.isPopoverOpen)
        XCTAssertTrue(AtticTextInput.hasKeyboard, "an open pop-over has the keyboard, a field or not")
        window.orderOut(nil)
        XCTAssertFalse(AtticTextInput.isPopoverOpen, "closed, the rows answer again")
    }

    // MARK: - One highlight per list; the pointer moves it

    func testThePointerMovesTheListsOneHighlight() throws {
        // Entering a row takes the highlight there, from the keyboard's row.
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: true, current: 0), 3)
        // Leaving a row for a neighbour, whichever event comes first.
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: false, current: 4), 4, "the neighbour's entry came first")
        XCTAssertNil(AtticListHighlight.hovered(3, inside: false, current: 3), "off the list: nothing lit")
        // A row sliding under a resting pointer as the keyboard scrolls is
        // not the pointer moving.
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                 isARepeat: false, keyCode: 125))
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        XCTAssertFalse(AtticListHighlight.isPointerMove(key))
        XCTAssertFalse(AtticListHighlight.isPointerMove(nil))
        XCTAssertTrue(AtticListHighlight.isPointerMove(moved))
    }

    func testTheDatePickerLightsOneThingAtATime() throws {
        let choices = TaskDateChoices(parser: TaskTextParser(calendar: Calendar(identifier: .gregorian),
                                                             locale: Locale(identifier: "en_GB"), now: { [clock] in clock.value }))
        let today = choices.today
        var highlight = TaskDatePickerHighlight(cursor: TaskDateCursor(start: today))
        XCTAssertFalse(highlight.cursor.isKeyboardActive, "nothing lit when it opens")
        // The keyboard lights a day.
        highlight.moveByKeyboard { $0.move(days: 1, in: choices) }
        XCTAssertTrue(highlight.cursor.isKeyboardActive)
        let keyboardDay = highlight.cursor.active
        // The pointer on a quick day's row takes the highlight from it.
        highlight.hoverRow("tomorrow", inside: true)
        XCTAssertEqual(highlight.row, "tomorrow")
        XCTAssertFalse(highlight.cursor.isKeyboardActive, "the day is no longer lit")
        XCTAssertEqual(highlight.cursor.active, keyboardDay, "the cursor stays put for the next arrow")
        // An arrow brings it back to the grid, off the row.
        highlight.moveByKeyboard { $0.move(days: 1, in: choices) }
        XCTAssertNil(highlight.row)
        XCTAssertTrue(highlight.cursor.isKeyboardActive)
        // The pointer on a day of the month shown moves the cursor there.
        let pointed = choices.day(today, movedBy: 5)
        highlight.hoverDay(pointed, inside: true, inShownMonth: true)
        XCTAssertEqual(highlight.cursor.active, pointed)
        XCTAssertTrue(highlight.cursor.isKeyboardActive)
        // Off it, nothing is lit.
        highlight.hoverDay(pointed, inside: false, inShownMonth: true)
        XCTAssertFalse(highlight.cursor.isKeyboardActive)
        // A neighbouring month's day never turns the page under the pointer.
        let month = highlight.cursor.month(in: choices)
        highlight.hoverDay(choices.day(pointed, movedByMonths: 1), inside: true, inShownMonth: false)
        XCTAssertEqual(highlight.cursor.month(in: choices), month)
        XCTAssertFalse(highlight.cursor.isKeyboardActive)
    }

    // MARK: - A row lit only while the keyboard drives (the owner's Done row)

    func testRingsNeedTheKeyboardAndAnyClickOrRestartClearsThem() {
        let tracker = AtticKeyboardFocusTracker()
        tracker.observe(.keyDown, keyCode: 125, inField: true)
        XCTAssertFalse(tracker.isKeyboardDriving, "an arrow in a field moves the insertion point, not focus")
        tracker.observe(.keyDown, keyCode: 48, inField: true)
        XCTAssertTrue(tracker.isKeyboardDriving, "Tab moves on from a field")
        tracker.observe(.leftMouseDown, keyCode: nil)
        XCTAssertFalse(tracker.isKeyboardDriving, "a click clears it")
        // A tracker that was off screen saw no clicks: it never starts, or
        // stops, with a ring left on.
        tracker.noteKeyboardNavigation()
        tracker.stop()
        XCTAssertFalse(tracker.isKeyboardDriving)
        tracker.noteKeyboardNavigation()
        tracker.start()
        XCTAssertFalse(tracker.isKeyboardDriving)
        tracker.stop()
    }

    func testAPlainClickOnTheListsSpaceIsNoRowsClick() throws {
        // Not deferred: its events need a window number to find it.
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 300, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let page = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView?.addSubview(page)
        let pointer = TasksPointer()
        pointer.view = page
        let row = UUID()
        pointer.frames = [row: CGRect(x: 0, y: 100, width: 300, height: 34)]
        func click(at y: CGFloat, _ type: NSEvent.EventType = .leftMouseDown, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: page.convert(NSPoint(x: 50, y: y), to: nil), modifierFlags: flags,
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func outside(_ event: NSEvent) -> Bool { pointer.isPlainPressOutsideRows(event, top: 80, bottomInset: 60) }
        XCTAssertTrue(outside(click(at: 200)), "the space under the rows (or Done's search, a day heading)")
        XCTAssertFalse(outside(click(at: 110)), "a row's own click selects it")
        XCTAssertFalse(outside(click(at: 40)), "the tabs and header are not the list")
        XCTAssertFalse(outside(click(at: 370)), "the add bar and selection bar are not the list")
        XCTAssertFalse(outside(click(at: 200, flags: .command)), "⌘-click keeps the selection, as in Finder")
        XCTAssertFalse(outside(click(at: 200, .rightMouseDown)), "a right-click is a menu's")
    }
}
