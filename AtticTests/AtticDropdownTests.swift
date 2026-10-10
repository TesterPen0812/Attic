import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The E1 dropdown family (owner, 2026-10-02): one shared card, row and
/// width rule; one highlight; the `/` list below the caret; the presenter
/// in the panel's overlay layer; and its cost against the components it
/// replaced.
@MainActor
final class AtticDropdownTests: XCTestCase {
    // MARK: The width rule

    /// Tab's policy in a card with a field and a list (the race itself is
    /// covered through a real presenter below): the rows are a stop only
    /// under Full Keyboard Access and only when there are rows; from the
    /// rows Tab always returns to the field.
    func testDropdownTabPolicyKeepsTheFieldWithoutFullKeyboardAccessOrRows() {
        typealias Tab = AtticDropdownTabFocus
        XCTAssertEqual(Tab.next(from: .field, fullKeyboardAccess: true, listAvailable: true), .list)
        XCTAssertEqual(Tab.next(from: .list, fullKeyboardAccess: true, listAvailable: true), .field)
        XCTAssertEqual(Tab.next(from: .list, fullKeyboardAccess: false, listAvailable: false), .field)
        XCTAssertNil(Tab.next(from: .field, fullKeyboardAccess: false, listAvailable: true), "without FKA, Tab stays in the field")
        XCTAssertNil(Tab.next(from: .field, fullKeyboardAccess: true, listAvailable: false), "an empty list is no stop")
        XCTAssertFalse(AtticDropdownInitialFocus.shouldRequest(enabled: true, request: 0), "no request before the host has the keyboard")
        XCTAssertTrue(AtticDropdownInitialFocus.shouldRequest(enabled: true, request: nil), "outside a presented dropdown")
    }

    // MARK: H5-04: one focus owner per card (real presenter, unshown window)

    /// A window that is never ordered on screen and records whom AppKit is
    /// asked to give the keyboard.
    final class FocusRecordingWindow: NSWindow {
        var requests: [NSResponder?] = []
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            requests.append(responder)
            return super.makeFirstResponder(responder)
        }
    }

    private func makeUnshownWindow() -> FocusRecordingWindow {
        let window = FocusRecordingWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        return window
    }

    /// What a card's content sees of its presentation's focus request as it
    /// appears.
    struct FocusRequestProbe: View {
        let log: (Int?) -> Void
        @Environment(\.atticDropdownFocusRequest) private var request
        var body: some View { Color.clear.frame(width: 120, height: 28).onAppear { log(request) } }
    }

    /// AppKit gives the opening card's host the keyboard; the card's own
    /// SwiftUI focus alone puts it in the field. AppKit asked directly for
    /// the SwiftUI field before, so two owners raced for it (H5-04).
    func testH5_04OpeningGivesTheHostTheKeyboardAndOnlySwiftUIFocusesTheField() throws {
        for picker in ["tags", "move"] {
            let window = makeUnshownWindow()
            defer { window.close() }
            let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
            let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
            window.contentView?.addSubview(original)
            window.contentView?.addSubview(anchor)
            XCTAssertTrue(window.makeFirstResponder(original))
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            presenter.content = picker == "tags"
                ? AnyView(TaskTagPickerView(allTags: ["design", "home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
                : AnyView(TaskMovePickerView(choices: [.init(id: UUID(), title: "Alpha", detail: nil)], onChoose: { _ in }))
            window.requests = []
            presenter.present(from: anchor)
            spin(0.3)
            let host = try XCTUnwrap(presenter.host)
            let intoCard = window.requests.compactMap { $0 as? NSView }.filter { $0 === host || $0.isDescendant(of: host) }
            XCTAssertTrue(intoCard.first === host, "\(picker): AppKit gives the host the keyboard first, not the SwiftUI field (\(intoCard))")
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, picker)
            XCTAssertTrue(editor.isFieldEditor && (editor.delegate as? NSView)?.isDescendant(of: host) == true,
                          "\(picker): the card's field has the keyboard")
            presenter.dismiss()
            spin(0.1)
            XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "\(picker): Esc gives the keyboard back")
            presenter.close(restoreFocus: false, immediately: true)
            XCTAssertFalse(window.isVisible)
        }
    }

    /// One presenter (an anchor's coordinator) opens its card again: the
    /// new card appears before its host takes the keyboard, so it must see
    /// no request left from the last opening (R3-01), and Esc gives the
    /// keyboard back every time.
    func testH5_04AReusedPresenterOpensItsNextCardAsItOpenedTheFirst() throws {
        let window = makeUnshownWindow()
        defer { window.close() }
        let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
        let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        var seen: [Int?] = []
        presenter.content = AnyView(FocusRequestProbe { seen.append($0) })
        for round in 1...3 {
            XCTAssertTrue(window.makeFirstResponder(original))
            presenter.present(from: anchor)
            XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "round \(round): measuring takes no keyboard")
            spin(0.3)
            XCTAssertEqual(seen.count, round, "round \(round): the card appeared once")
            XCTAssertTrue(presenter.host.map { window.firstResponder === $0 } == true, "round \(round): the host has the keyboard")
            presenter.dismiss()
            spin(0.1)
            XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "round \(round): Esc gives the keyboard back")
            presenter.close(restoreFocus: false, immediately: true)
        }
        XCTAssertEqual(seen, [0, 0, 0], "every opening's card appears before its host takes the keyboard")
    }

    /// Under Full Keyboard Access (CI only), Tab hands the keyboard from the
    /// field to the rows and back, on one reused presenter, many times: the
    /// list's focus and AppKit's first responder must agree every time.
    func testH5_04TabHandsTheKeyboardBetweenFieldAndRowsOnAReusedPresenter() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_FULL_KEYBOARD_ACCESS_TESTS"] == "1" else {
            throw XCTSkip("CI enables Full Keyboard Access; local tests preserve the user's setting")
        }
        XCTAssertTrue(NSApp.isFullKeyboardAccessEnabled)
        let window = makeUnshownWindow()
        defer { window.close() }
        let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
        let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        var toggled: [String] = []
        presenter.content = AnyView(TaskTagPickerView(allTags: ["design", "home"], state: { _ in .off },
                                                      onToggle: { toggled.append($0) }, onCreate: { _, _ in true }))
        func fieldHasKeyboard() -> Bool {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let host = presenter.host else { return false }
            return (editor.delegate as? NSView)?.isDescendant(of: host) == true
        }
        for round in 1...10 {
            XCTAssertTrue(window.makeFirstResponder(original))
            presenter.present(from: anchor)
            spin(0.3)
            XCTAssertTrue(fieldHasKeyboard(), "round \(round): the field has the keyboard as the card opens")
            XCTAssertNil(presenter.handleKey(key("\t", code: 48, in: window)), "round \(round): the card takes Tab")
            spin(0.2)
            let responder = window.firstResponder as? NSView
            XCTAssertFalse(fieldHasKeyboard(), "round \(round): Tab left the field (\(String(describing: responder)))")
            XCTAssertTrue(responder.map { v in presenter.host.map { v.isDescendant(of: $0) } ?? false } == true,
                          "round \(round): the rows have the keyboard, inside the card")
            // Arriving highlights the first row, and Space presses it. (VoiceOver's
            // "selected" is read in the native test: off screen it is not kept.)
            let space = key(" ", code: 49, in: window)
            if presenter.handleKey(space) != nil { window.sendEvent(space) }
            spin(0.2)
            XCTAssertEqual(toggled, ["design"], "round \(round): Space pressed the row Tab reached")
            toggled = []
            XCTAssertNil(presenter.handleKey(key("\t", code: 48, flags: .shift, in: window)))
            spin(0.2)
            XCTAssertTrue(fieldHasKeyboard(), "round \(round): Shift-Tab returns to the field")
            XCTAssertNil(presenter.handleKey(key("\u{1b}", code: 53, in: window)))
            spin(0.1)
            XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "round \(round): Esc gives the keyboard back")
            presenter.close(restoreFocus: false, immediately: true)
        }
    }

    // MARK: H5-04 diagnosis (CI, Full Keyboard Access only; prints, asserts nothing)

    /// A key panel that records who asks AppKit for the first responder.
    final class RecordingKeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        var start = ProcessInfo.processInfo.systemUptime
        var log: [String] = []
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let frames = Thread.callStackSymbols.dropFirst(2).compactMap { line -> String? in
                guard line.contains("Attic") || line.contains("SwiftUI") || line.contains("AppKit") else { return nil }
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count > 3 else { return nil }
                return parts[1] + ":" + String(parts[3...].joined(separator: " ").prefix(90))
            }.prefix(9)
            let name: String
            if let t = responder as? NSTextView, t.isFieldEditor { name = "fieldEditor" } else { name = responder.map { String(describing: type(of: $0)) } ?? "nil" }
            let ok = super.makeFirstResponder(responder)
            log.append(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start) + " MFR \(name) ok=\(ok) <- " + frames.joined(separator: " < "))
            return ok
        }
    }

    func testZZDiagnoseNativeTagPickerTab() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_FULL_KEYBOARD_ACCESS_TESTS"] == "1" else { throw XCTSkip("CI only") }
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        var printed = 0, printedPass = 0
        for round in 1...12 {
            let window = RecordingKeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
            window.orderFront(nil)
            window.makeKey()
            let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
            window.contentView?.addSubview(original)
            let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
            window.contentView?.addSubview(anchor)
            window.makeFirstResponder(original)
            window.start = ProcessInfo.processInfo.systemUptime
            window.log = []
            var toggled: [String] = []
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            var subs: [AnyCancellable] = []
            func stamp(_ s: String) { window.log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - window.start) + s) }
            subs.append(presenter.stage.$height.dropFirst().sink { stamp("stage.height=\(String(describing: $0))") })
            subs.append(presenter.stage.$width.dropFirst().sink { stamp("stage.width=\(String(describing: $0))") })
            subs.append(presenter.stage.$focusRequest.dropFirst().sink { stamp("stage.focusRequest=\($0)") })
            presenter.content = AnyView(TaskTagPickerView(allTags: ["design", "home", "launch"], state: { $0 == "home" ? .on : .off },
                                                          onToggle: { toggled.append($0) }, onCreate: { _, _ in true }))
            presenter.present(from: anchor)
            spin(0.3)
            func deliver(_ events: [NSEvent]) {
                events.forEach { NSApp.postEvent($0, atStart: false) }
                var count = 0
                while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(next); count += 1
                }
                spin(0.2)
            }
            func press(_ c: String, _ code: UInt16) {
                stamp("press \(code)")
                deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: c,
                                     charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
                })
            }
            press("\t", 48)
            let afterTab = (window.firstResponder as? NSTextView)?.isFieldEditor == true ? "fieldEditor" : String(describing: window.firstResponder.map { type(of: $0) })
            press(" ", 49)
            let ok = toggled == ["design"]
            print("FKANATIVE round \(round) ok=\(ok) afterTab=\(afterTab) toggled=\(toggled)")
            if !ok ? printed < 3 : printedPass < 1 {
                if ok { printedPass += 1 } else { printed += 1 }
                window.log.forEach { print("FKANATIVE   r\(round) " + $0) }
            }
            subs.removeAll()
            presenter.close(restoreFocus: false, immediately: true)
            window.close()
            spin(0.1)
        }
    }

    // MARK: Focus sweep (H5-05 and on): the same two-owner pattern elsewhere

    /// H5-05: an explicit open on Tasks (the hotkey, the corner) asks the
    /// shell to put the keyboard in the add bar. The shell relayed it
    /// through a `@FocusState` no view was focused on, and SwiftUI drops a
    /// write to such a state, so the add bar never heard the request.
    func testH5_05AnExplicitOpenOnTasksPutsTheKeyboardInTheAddBar() throws {
        let suite = "AtticDropdownTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        state.updatePanelSize(CGSize(width: 340, height: 560))
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: NoteDraftController(noteStore: notes),
                chromeInteractionState: chrome, uiState: state, settings: settings,
                subtaskPanels: SubtaskPanelController(store: store, uiState: state, settings: settings),
                tasksPageState: TasksPageState()
            ),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        let window = makeUnshownWindow()
        window.contentView = host
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            window.contentView = nil
            window.close()
        }
        spin(1.5)
        state.selectSection(.tasks)
        spin(1.5)
        func addBarHasKeyboard() -> Bool {
            guard let view = window.firstResponder as? NSTextView else { return false }
            return view.isDescendant(of: host)
        }
        for round in 1...2 {
            window.makeFirstResponder(nil)
            spin(0.2)
            XCTAssertFalse(addBarHasKeyboard(), "round \(round): the keyboard is elsewhere")
            state.requestPrimaryInputFocus()
            spin(0.5)
            XCTAssertTrue(addBarHasKeyboard(), "round \(round): the request puts the keyboard in the add bar (\(String(describing: window.firstResponder)))")
        }
        XCTAssertFalse(window.isVisible)
    }


    func testTheWidthFitsItsContentNeverUnderTheMinimumNeverPastTheMargin() {
        let m = AtticDropdownMetrics.self
        let available: CGFloat = 320 - m.panelMargin * 2
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 90, available: available), 144, "never under 144 pt")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 165, available: available), 165, "fits its content")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 164.2, available: available), 165, "whole points")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 400, available: available), 296, "never past the 12 pt margin")
    }

    func testTheSlashListIsAsWideAsItsLongestNameAndShrinksToTheMinimum() {
        let all = NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) }
        let full = AtticDropdownLayout.listWidth(titles: all.map(\.title))
        // The Compact rows (13 pt names, 9 pt padding) measure 145 pt for the
        // nine (Numbered List); p2-24 D's 14 pt rows measured 165.
        XCTAssertEqual(full, 145, accuracy: 4, "the nine rows fit Numbered List")
        XCTAssertTrue(all.contains { $0.kind == .mono }, "Mono is in the list")
        let date = AtticDropdownLayout.listWidth(titles: ["Date"], match: "da")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: date, available: 296), 144, "“/da” leaves Date at the minimum")
    }

    func testTheTagListKeepsItsHeightWhileFiltering() {
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 0), 1, "room for No tags yet or New tag")
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 5), 5, "p2-24's five tags, no scrolling")
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 30), 7, "seven rows, then it scrolls")
    }

    // MARK: Where it opens

    func testItOpensBelowTheCaretWhenThereIsRoomWithItsLeftEdgeOnTheSlash() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let caret = CGRect(x: 28, y: 96, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 308), anchor: caret, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .below)
        XCTAssertEqual(placed.frame.minX, 28, "the left edge on the “/”")
        XCTAssertEqual(placed.frame.minY, caret.maxY + AtticDropdownMetrics.anchorGap)
    }

    func testItOpensAboveWhenThereIsNoRoomBelowAndAStripPickerOpensAbove() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let low = CGRect(x: 28, y: 420, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 200), anchor: low, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .above)
        XCTAssertEqual(placed.frame.maxY, low.minY - AtticDropdownMetrics.anchorGap)
        let strip = CGRect(x: 100, y: 440, width: 60, height: 28)
        let picker = AtticDropdownLayout.frame(size: CGSize(width: 185, height: 200), anchor: strip, bounds: bounds, prefer: .above)
        XCTAssertEqual(picker.side, .above)
        XCTAssertEqual(picker.frame.minX, 100, "the left edge on the strip button")
    }

    func testItMovesLeftOnlyAsFarAsTheMarginNeeds() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let anchor = CGRect(x: 250, y: 100, width: 40, height: 28)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 187, height: 136), anchor: anchor, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.frame.maxX, 308, "the right edge on the 12 pt margin")
        XCTAssertGreaterThanOrEqual(placed.frame.minX, 12)
    }

    func testCrampedPlacementUsesTheRoomierSideAndNeverCrossesTheMargin() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 216)
        let caret = CGRect(x: 28, y: 140, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 308), anchor: caret,
                                               bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .above)
        XCTAssertLessThan(placed.frame.height, 308)
        XCTAssertEqual(placed.frame.maxY, caret.minY - AtticDropdownMetrics.anchorGap)
        XCTAssertTrue(bounds.contains(placed.frame))
    }

    /// P3-B3: the one placement keeps an open card's side while it fits
    /// there, and flips only when that side can't hold it.
    func testAnOpenCardKeepsItsSideUntilThatSideCannotHoldIt() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        // 336 pt above the anchor, 120 below.
        let anchor = CGRect(x: 28, y: 354, width: 60, height: 28)
        let opened = AtticDropdownLayout.place(idealWidth: 200, height: 252, anchor: anchor, bounds: bounds, prefer: .below)
        XCTAssertEqual(opened.side, .above, "the full list fits only above")
        XCTAssertNil(opened.heightLimit)
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .below).side,
                       .below, "a fresh short card opens below")
        let filtered = AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .below,
                                                 current: opened.side)
        XCTAssertEqual(filtered.side, .above, "a filtered card keeps its side")
        XCTAssertEqual(filtered.frame.maxY, anchor.minY - AtticDropdownMetrics.anchorGap, "still hanging from the anchor")
        let below = AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .above,
                                              current: .below)
        XCTAssertEqual(below.side, .below, "a card below stays below while it fits there")
        let grown = AtticDropdownLayout.place(idealWidth: 200, height: 130, anchor: anchor, bounds: bounds, prefer: .below,
                                              current: .below)
        XCTAssertEqual(grown.side, .above, "it flips once its side can't hold it")
        let tooTall = AtticDropdownLayout.place(idealWidth: 200, height: 400, anchor: anchor, bounds: bounds, prefer: .below,
                                                current: .below)
        XCTAssertEqual(tooTall.side, .above, "the roomier side when neither holds it")
        XCTAssertEqual(tooTall.heightLimit, 336)
        // The width rule is the same one.
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 90, height: 88, anchor: anchor, bounds: bounds, prefer: .below).width, 144)
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 400, height: 88, anchor: anchor, bounds: bounds, prefer: .below).width, 296)
    }

    /// Inspect the actual accessibility representation, including its action.
    func testMenuItemRepresentationHasRoleSelectionPositionAndPress() {
        var pressed = 0
        let item = AtticDropdownMenuItem(label: "Mono", selected: true, position: 9, count: 9) { pressed += 1 }
        // NSViewRepresentable.Context cannot be constructed here; host the
        // representation so SwiftUI builds and updates the real AppKit view.
        let host = NSHostingView(rootView: item)
        host.frame = CGRect(x: 0, y: 0, width: 165, height: 32)
        host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> AtticDropdownMenuItem.ItemView? {
            if let item = root as? AtticDropdownMenuItem.ItemView { return item }
            return root.subviews.compactMap { find($0) }.first
        }
        guard let represented = find(host) else { return XCTFail("the AppKit menu item exists") }
        XCTAssertEqual(represented.accessibilityRole(), .menuItem)
        XCTAssertTrue(represented.isAccessibilitySelected())
        XCTAssertEqual(represented.accessibilityValue() as? String, "9 of 9")
        XCTAssertTrue(represented.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
        let disabled = NSHostingView(rootView: item.disabled(true))
        disabled.frame = host.frame
        disabled.layoutSubtreeIfNeeded()
        let disabledItem = try? XCTUnwrap(find(disabled))
        XCTAssertEqual(disabledItem?.isAccessibilityEnabled(), false)
        XCTAssertEqual(disabledItem?.accessibilityPerformPress(), false)
        XCTAssertEqual(pressed, 1, "a disabled menu item never runs its action")
        // A ticked row the highlight is not on: its mark, not "selected".
        let ticked = NSHostingView(rootView: AtticDropdownMenuItem(label: "High", selected: false, check: .on) {})
        ticked.frame = host.frame
        ticked.layoutSubtreeIfNeeded()
        let tickedItem = try? XCTUnwrap(find(ticked))
        XCTAssertEqual(tickedItem?.isAccessibilitySelected(), false, "a tick is not the highlight")
        XCTAssertEqual(tickedItem.map(Self.markChar), "✓")
        XCTAssertNil(Self.markChar(represented), "an unticked item has no mark")
    }

    /// What the accessibility server reads for a menu item's mark, by the
    /// same selectors (the NSAccessibility protocol has no accessor for it).
    private static func markChar(_ element: AnyObject) -> String? {
        guard let object = element as? NSObject,
              let names = object.perform(NSSelectorFromString("accessibilityAttributeNames"))?.takeUnretainedValue() as? [String],
              names.contains(AtticDropdownMenuItem.markCharAttribute.rawValue) else { return nil }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"),
                              with: AtticDropdownMenuItem.markCharAttribute.rawValue)?.takeUnretainedValue() as? String
    }

    /// The tag picker as Tasks shows it, with its rows' states and the
    /// list's one highlight given.
    struct TagList: View {
        let tags: [AtticTagPicker.Tag]
        let highlighted: Int?
        @FocusState private var focused: AtticDropdownFocusTarget?
        var body: some View {
            AtticTagPicker(query: .constant(""), tags: tags, highlighted: highlighted, onToggle: { _ in }, onCreate: { _ in },
                           focus: $focused)
                .frame(width: 200)
        }
    }

    /// P2-B1: VoiceOver tells the ticked rows from the highlighted one. Only
    /// the highlight is "selected"; ticks are the menu items' marks.
    func testOnlyTheHighlightIsSelectedAndTicksAreMenuItemMarks() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        // The priority picker on a High task, ↓ moved to Medium; the tag
        // picker with two ticked tags, one part-ticked, the highlight on
        // an unticked one.
        let tags = [AtticTagPicker.Tag(name: "design", state: .on), AtticTagPicker.Tag(name: "home", state: .off),
                    AtticTagPicker.Tag(name: "launch", state: .on), AtticTagPicker.Tag(name: "travel", state: .mixed)]
        let priorities = VStack(spacing: 0) {
            ForEach(Array(TaskPriority.choices.enumerated()), id: \.element) { index, priority in
                AtticDropdownRow(title: priority.choiceTitle, check: priority == .high ? .on : .off, isHighlighted: priority == .medium,
                                 onHover: { _ in }, position: index + 1, itemCount: 4) {}
            }
        }
        let root = VStack(spacing: 0) { priorities.frame(width: 200); TagList(tags: tags, highlighted: 1) }
        let host = NSHostingView(rootView: root.atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 0, y: 0, width: 220, height: 400)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        let items = accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        func item(_ label: String) throws -> AtticDropdownMenuItem.ItemView {
            try XCTUnwrap(items.first { $0.accessibilityLabel() == label }, label)
        }
        XCTAssertEqual(items.filter { $0.isAccessibilitySelected() }.map { $0.accessibilityLabel() ?? "" }, ["Medium", "#home"],
                       "one selected item per list: its highlight")
        XCTAssertEqual(Self.markChar(try item("High")), "✓", "the checked priority is marked, not selected")
        XCTAssertNil(Self.markChar(try item("Medium")))
        XCTAssertEqual(Self.markChar(try item("#design")), "✓")
        XCTAssertEqual(Self.markChar(try item("#launch")), "✓")
        XCTAssertEqual(Self.markChar(try item("#travel")), "-", "a part-ticked tag")
        XCTAssertEqual(try item("#travel").accessibilityValue() as? String, "some selected tasks, 4 of 4")
        XCTAssertNil(Self.markChar(try item("#home")))
    }

    func testRenderedRowsExposeMenuItemsAndKeepTheirIdentifiers() throws {
        // SwiftUI builds its virtual AX tree only when accessibility is
        // requested. Enable that mode in this test host, then restore it.
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        let model = NoteSlashListModel()
        model.show(NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) })
        let host = NSHostingView(rootView: NoteSlashListView(model: model).atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 340)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        func items(_ element: AnyObject) -> [AtticDropdownMenuItem.ItemView] {
            if let item = element as? AtticDropdownMenuItem.ItemView { return [item] }
            // SwiftUI's virtual children expose the ObjC accessibility
            // methods without declaring protocol conformance.
            let children = (element.accessibilityChildren?() ?? nil) ?? []
            return children.flatMap { items($0 as AnyObject) }
        }
        let rows = items(host)
        XCTAssertEqual(rows.count, model.items.count, "the rendered accessibility tree contains menu items")
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.accessibilityRole(), .menuItem)
        XCTAssertTrue(first.isAccessibilitySelected())
        XCTAssertEqual(first.accessibilityValue() as? String, "1 of 13")
        XCTAssertEqual(first.accessibilityIdentifier(), "notes-slash-checklist")
        XCTAssertGreaterThan(first.accessibilityFrame().width, 0)
        XCTAssertEqual(first.accessibilityFrame().height, AtticDropdownMetrics.rowHeight, accuracy: 1)
        // Thirteen rows: Notes v2's Table, and the Aa style list's Title,
        // Subheading and Body beside Heading (A39 F04).
        XCTAssertEqual(rows.last?.accessibilityValue() as? String, "13 of 13")
        XCTAssertEqual(rows.filter { $0.isAccessibilitySelected() }.count, 1, "only the highlight is selected")
    }

    func testCrampedSlashScrollKeepsTheKeyboardHighlightVisible() throws {
        let window = makeWindow()
        defer { window.close() }
        let model = NoteSlashListModel()
        model.viewportHeight = 116
        model.width = 165
        model.show(NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) })
        let host = NSHostingView(rootView: NoteSlashListView(model: model).atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 10, y: 10, width: 189, height: 140)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
        }
        let scroll = try XCTUnwrap(scrolls(host).first)
        XCTAssertTrue(ScrollEdgeTests.pockets(in: scroll).isEmpty, "E1 cards use Clean cut")
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
        let before = scroll.contentView.bounds.origin.y
        model.move(-1) // wraps from the first row to Mono
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before, "the keyboard scrolls to Mono")
        XCTAssertTrue(ScrollEdgeTests.pockets(in: scroll).isEmpty, "scrolling an E1 card cannot enable native edges")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.bounds.maxY - 1,
                                    "the last row is wholly visible")
        model.move(1) // wraps back to the first row
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, document.bounds.minY,
                                 "the first row starts within the viewport, allowing the native top inset")
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.bounds.minY + AtticDropdownMetrics.rowHeight,
                                    "the entire first row is visible")
    }

    // MARK: One highlight

    func testOneHighlightIsSharedByThePointerAndTheKeyboard() {
        // A list that owns its highlight: hover alone never lights a row.
        XCTAssertFalse(AtticDropdownRow.isLit(highlighted: false, hovered: true, listOwnsHighlight: true))
        XCTAssertTrue(AtticDropdownRow.isLit(highlighted: true, hovered: false, listOwnsHighlight: true))
        // The pointer moves the list's one highlight.
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: true, current: 1), 3)
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: false, current: 3), nil)
        XCTAssertEqual(AtticListHighlight.hovered(2, inside: false, current: 3), 3, "leaving a neighbour keeps it")
    }

    // MARK: The look's values

    func testTheCardTakesE1sValuesInBothModes() {
        let light = AtticDesignContext(mode: .light).tokens
        let dark = AtticDesignContext(mode: .dark).tokens
        XCTAssertEqual(light.popoverFill, AtticRGBA(0xFEFEFE))
        XCTAssertEqual(dark.popoverFill, AtticRGBA(0x363637))
        XCTAssertEqual(light.dropdownHighlight, AtticRGBA(0xF1F1F1))
        XCTAssertEqual(dark.dropdownHighlight, AtticRGBA(0x444445))
        XCTAssertEqual(light.popoverOuterRim, .black(0.11))
        XCTAssertEqual(dark.popoverOuterRim, .black(0.55))
        XCTAssertEqual(light.dropdownShadow, .black(0.12))
        XCTAssertEqual(dark.dropdownShadow, .black(0.42))
        XCTAssertEqual(light.dropdownContactShadow, .black(0.05))
        XCTAssertEqual(dark.dropdownContactShadow, .black(0.24))
        let m = AtticDropdownMetrics.self
        XCTAssertLessThan(m.highlightRadius, m.cornerRadius - m.inset + 1, "the pill sits inside the corner")
        XCTAssertEqual(m.rowHeight, 28, "the Compact size (p2-28)")
        XCTAssertEqual(AtticTextStyle.dropdownRow.spec.size, 13)
        // Increase Contrast steps the edge up (the existing rule).
        let contrast = AtticDesignContext(mode: .light, increaseContrast: true).tokens
        XCTAssertGreaterThan(contrast.popoverOuterRim.alpha, light.popoverOuterRim.alpha)
    }

    // MARK: The capture seam

    func testTheCaptureSeamIsForPreviewIdentitiesOnly() {
        let environment = ["ATTIC_UI_TESTING": "1", "ATTIC_UI_TEST_POPOVER": "slash-da"]
        XCTAssertEqual(AtticDropdownCaptureSeam.resolve(environment: environment, bundleIdentifier: "com.taha.Attic.preview.notes"), .slashDa)
        XCTAssertNil(AtticDropdownCaptureSeam.resolve(environment: environment, bundleIdentifier: "com.taha.Attic"))
        XCTAssertNil(AtticDropdownCaptureSeam.resolve(environment: ["ATTIC_UI_TEST_POPOVER": "tag"],
                                                      bundleIdentifier: "com.taha.Attic.preview.notes"), "needs ATTIC_UI_TESTING")
        XCTAssertEqual(AtticDropdownCaptureSeam.tag.page, "tasks")
        XCTAssertEqual(AtticDropdownCaptureSeam.date.notesScene, "date-lead")
    }

    // MARK: The presenter

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFrontRegardless()
        return window
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testDeferredCloseThenOpenInTheSameTurnKeepsTheCardInteractive() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 20, y: 40, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.takesKeyboard = false
        presenter.contentHeight = 52
        presenter.content = AnyView(AtticDropdownRow(title: "First") {})
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let host = try XCTUnwrap(presenter.host)
        var dismissals = 0
        presenter.onDismiss = { dismissals += 1 }

        presenter.closeAfterViewUpdate()
        XCTAssertFalse(host.isInteractive, "a requested close stops interaction immediately")
        // This is the open branch of updateNSView, before the queued close runs.
        presenter.content = AnyView(AtticDropdownRow(title: "Reopened") {})
        presenter.updateAfterViewUpdate()
        spin(0.1)
        XCTAssertTrue(presenter.isOpen, "the older close cannot cancel the newer presentation")
        XCTAssertIdentical(presenter.host, host, "reopening keeps the existing card")
        XCTAssertTrue(host.isInteractive, "reopening restores hit testing")
        XCTAssertEqual(dismissals, 0)

        // Another close in this turn must still work; cancellation must not
        // leave the presenter stuck ignoring later close requests.
        presenter.closeAfterViewUpdate()
        presenter.updateAfterViewUpdate()
        presenter.closeAfterViewUpdate()
        spin(0.1)
        XCTAssertFalse(presenter.isOpen)
        XCTAssertFalse(host.isInteractive)
    }

    final class Opener: ObservableObject {
        @Published var isOpen = false
        @Published var query = ""
    }

    final class Counter {
        var behind = 0
    }

    /// Stands for the note or the task list behind: counts its renders.
    struct Behind: View {
        let counter: Counter
        var body: some View {
            counter.behind += 1
            return Color.clear.frame(height: 300)
        }
    }

    /// The control that opens the dropdown: the only view that observes it.
    struct Opening: View {
        @ObservedObject var opener: Opener
        var takesKeyboard = true
        var hasKnownSize = false
        var body: some View {
            Color.clear.frame(width: 60, height: 28)
                .atticDropdown(isPresented: $opener.isOpen, label: "Tags", takesKeyboard: takesKeyboard,
                               contentHeight: hasKnownSize ? (opener.query.isEmpty ? 116 : 52) : nil,
                               contentWidth: hasKnownSize ? (opener.query.isEmpty ? 144 : 220) : nil) {
                    ForEach(["launch", "home", "work"].filter { opener.query.isEmpty || $0.contains(opener.query) }, id: \.self) { tag in
                        AtticDropdownRow(title: "#" + tag, check: .off) {}
                    }
                }
        }
    }

    func testOpeningFilteringAndClosingNeverReRenderThePageBehind() {
        let window = makeWindow()
        defer { window.close() }
        let opener = Opener()
        let counter = Counter()
        let root = VStack(alignment: .leading, spacing: 0) {
            Behind(counter: counter)
            Opening(opener: opener)
        }
        let host = NSHostingView(rootView: root.atticDesign(AtticDesignContext()))
        host.frame = window.contentView!.bounds
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin()
        let overlay = window.contentView?.superview
        let before = counter.behind
        opener.isOpen = true
        // Polled, as the close is: after a heavy suite the main queue can
        // run the opening turn late.
        let opening = Date().addingTimeInterval(3)
        repeat { spin(0.05) } while Date() < opening && !AtticDropdownPresenter.isAnyOpen
        spin(0.1)
        XCTAssertTrue(AtticDropdownPresenter.isAnyOpen, "it opened")
        XCTAssertTrue(AtticTextInput.isPopoverOpen, "the page's keys stand aside")
        let card = overlay?.subviews.compactMap { $0 as? AtticOverlayHostingView }.first
        XCTAssertNotNil(card, "the card is in the overlay layer")
        XCTAssertEqual(card?.accessibilityRole(), .menu, "VoiceOver hears a menu")
        if let card {
            let content = card.contentRect
            XCTAssertGreaterThanOrEqual(content.width, AtticDropdownMetrics.minWidth)
            let inWindow = card.convert(content, to: nil)
            XCTAssertGreaterThanOrEqual(inWindow.minX, AtticDropdownMetrics.panelMargin - 0.5)
            XCTAssertLessThanOrEqual(inWindow.maxX, 320 - AtticDropdownMetrics.panelMargin + 0.5)
        }
        opener.query = "ho"
        spin(0.1)
        opener.isOpen = false
        // The leave motion, then the card's host goes (polled: a busy
        // machine runs the cleanup late).
        let deadline = Date().addingTimeInterval(3)
        repeat { spin(0.1) } while Date() < deadline
            && !(overlay?.subviews.compactMap { $0 as? AtticOverlayHostingView }.isEmpty ?? true)
        XCTAssertFalse(AtticDropdownPresenter.isAnyOpen, "it closed")
        XCTAssertEqual(counter.behind, before, "the page behind was never re-rendered")
        XCTAssertTrue(overlay?.subviews.compactMap { $0 as? AtticOverlayHostingView }.isEmpty ?? false,
                      "the card left the overlay after its leave motion")
    }

    func testStandaloneHostingRootPresentsSuggestionsAsASibling() throws {
        let window = makeWindow()
        defer { window.close() }
        let opener = Opener()
        let counter = Counter()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Behind(counter: counter)
            Opening(opener: opener, takesKeyboard: false, hasKnownSize: true)
        }.atticDesign(AtticDesignContext()))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        let parent = try XCTUnwrap(host.superview)
        let before = counter.behind
        let diagnostics = captureErrorOutput {
            opener.isOpen = true
            let deadline = Date().addingTimeInterval(3)
            var card: AtticOverlayHostingView?
            repeat {
                spin()
                card = parent.subviews.compactMap { $0 as? AtticOverlayHostingView }.first
            } while card == nil && Date() < deadline
            guard let shown = card else { XCTFail("the suggestion did not open"); return }
            XCTAssertIdentical(shown.superview, parent)
            XCTAssertFalse(shown.isDescendant(of: host), "a suggestion must never join SwiftUI's managed hierarchy")
            let frame = host.convert(shown.contentRect, from: shown)
            XCTAssertGreaterThanOrEqual(frame.minX, AtticDropdownMetrics.panelMargin - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, host.bounds.width - AtticDropdownMetrics.panelMargin + 0.5)
            opener.query = "ho"
            spin(0.1)
            XCTAssertEqual(shown.contentRect.width, 220, accuracy: 1, "known-width suggestions still grow")
            XCTAssertEqual(counter.behind, before, "opening and filtering leave the page behind alone")
            opener.isOpen = false
            let closing = Date().addingTimeInterval(3)
            repeat { spin() } while shown.superview != nil && Date() < closing
            XCTAssertNil(shown.superview)
        }
        XCTAssertFalse(diagnostics.contains("as a subview of NSHostingView is not supported"), diagnostics)
        XCTAssertFalse(diagnostics.contains("Publishing changes from within view updates"), diagnostics)
        XCTAssertFalse(window.isKeyWindow, "this regression needs no key window")
    }

    /// What the test host writes to its error output while `body` runs
    /// (AppKit's and SwiftUI's runtime errors land there).
    private func captureErrorOutput(_ body: () -> Void) -> String {
        let pipe = Pipe()
        var captured = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); captured.append(chunk); lock.unlock()
        }
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        spin(0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    /// With accessibility on (as with VoiceOver or Full Keyboard Access),
    /// SwiftUI moves focus through key-view proxies. A card's content asked
    /// for focus as it appeared, while the presenter was measuring it
    /// outside the window, and AppKit refused the stale proxy by clearing
    /// the window's first responder: the card lost the keyboard (the Full
    /// Keyboard Access test's first failure on CI). The content now waits
    /// for the presenter's request.
    func testACardKeepsTheKeyboardWithAccessibilityOn() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        for (name, content) in [("date", AnyView(TaskDatePickerView(choices: TaskDateChoices(parser: TaskTextParser()), selected: nil, onPick: { _ in }))),
                                ("tags", AnyView(TaskTagPickerView(allTags: ["home", "launch"], state: { _ in .off },
                                                                   onToggle: { _ in }, onCreate: { _, _ in true }))),
                                ("priority", AnyView(TaskPriorityPickerView(current: .high, onPick: { _ in })))] {
            let window = makeWindow()
            defer { window.close() }
            let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
            window.contentView?.addSubview(original)
            window.makeFirstResponder(original)
            let anchor = NSView(frame: CGRect(x: 40, y: 300, width: 60, height: 28))
            window.contentView?.addSubview(anchor)
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            presenter.content = content
            // AppKit reports the refused proxy on the host's error output.
            let log = captureErrorOutput {
                presenter.present(from: anchor)
                spin(0.4)
            }
            defer { presenter.close(restoreFocus: false, immediately: true) }
            XCTAssertFalse(log.contains("KeyViewProxy"), "the \(name) card gave AppKit no stale key-view proxy: \(log)")
            let host = try XCTUnwrap(presenter.host)
            let responder = AtticDropdownPresenter.owner(of: window.firstResponder) as? NSView
            XCTAssertTrue(responder?.isDescendant(of: host) == true,
                          "the \(name) card has the keyboard (\(String(describing: window.firstResponder)))")
        }
    }

    func testEscClosesItAndGivesTheKeyboardBack() {
        let window = makeWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 400, width: 200, height: 22))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let previous = window.firstResponder
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        var dismissed = false
        presenter.onDismiss = { dismissed = true }
        presenter.content = AnyView(TaskPriorityPickerView(current: nil, onPick: { _ in }))
        presenter.present(from: anchor)
        spin(0.1)
        XCTAssertTrue(presenter.isOpen)
        let host = try? XCTUnwrap(presenter.host)
        XCTAssertTrue((window.firstResponder as? NSView).map { $0 === host || $0.isDescendant(of: host!) } ?? false,
                      "the card has the keyboard")
        presenter.dismiss()
        XCTAssertTrue(dismissed)
        XCTAssertFalse(presenter.isOpen)
        XCTAssertTrue(window.firstResponder === previous || window.firstResponder === field.currentEditor(),
                      "the keyboard went back where it was")
    }

    func testTheTagPickerCardShowsEveryTagItHasRoomFor() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 40, y: 60, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.prefer = .above
        presenter.content = AnyView(TaskTagPickerView(allTags: ["launch", "home", "work", "design", "travel"], state: { _ in .off },
                                                      onToggle: { _ in }, onCreate: { _, _ in true }, focusField: false))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let m = AtticDropdownMetrics.self
        let card = try? XCTUnwrap(presenter.host?.contentRect)
        // The field, its gap and the five rows, 10 pt in.
        XCTAssertEqual(card?.height ?? 0, m.inset * 2 + m.fieldHeight + m.fieldGap + 5 * m.rowHeight, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card?.width ?? 0, m.minWidth)
    }

    func testTypingSuggestionsKeepTheKeyboardAndResizeWhenRowsChange() throws {
        let window = makeWindow()
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 28, y: 50, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let previous = window.firstResponder
        let anchor = NSView(frame: CGRect(x: 28, y: 90, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.takesKeyboard = false
        presenter.contentHasCard = true
        presenter.contentHeight = 52
        presenter.content = AnyView(AtticSuggestionList(items: [.init(id: "first", title: "First")], highlighted: 0) { _ in })
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.1)
        XCTAssertIdentical(window.firstResponder, previous, "typing stays in the draft")
        XCTAssertEqual(presenter.stage.side, .below)
        presenter.content = AnyView(AtticSuggestionList(items: (0..<9).map { .init(id: "\($0)", title: "Row \($0)") }, highlighted: 0) { _ in })
        presenter.contentHeight = 308
        presenter.update()
        spin(0.1)
        XCTAssertEqual(presenter.stage.side, .above, "the full grown list fits above")
        XCTAssertEqual(try XCTUnwrap(presenter.host).contentRect.height, 308, accuracy: 1)
        XCTAssertIdentical(window.firstResponder, previous)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: anchor.convert(CGPoint(x: 30, y: 14), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertIdentical(try XCTUnwrap(presenter.handleClick(click)), click, "an editor/strip click still acts")
        XCTAssertFalse(presenter.isOpen, "the automatic suggestions close on that click")
    }

    /// CU review P3: the add bar's suggestions kept their opening width, so
    /// "#cuqa" then "Create #cuqaz" showed "Create #c…". A list whose rows
    /// change while it shows follows its known content width.
    func testTypingSuggestionsFollowTheirRowsWidth() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 28, y: 90, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.takesKeyboard = false
        presenter.contentHasCard = true
        func show(_ items: [AtticSuggestionList.Item]) {
            presenter.content = AnyView(AtticSuggestionList(items: items, highlighted: 0) { _ in })
            presenter.contentHeight = CGFloat(items.count) * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.inset * 2
            presenter.contentWidth = AtticSuggestionList.idealWidth(items)
        }
        show([.init(id: "cuqa", title: "#cuqa")])
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.1)
        let host = try XCTUnwrap(presenter.host)
        XCTAssertEqual(host.contentRect.width, AtticDropdownMetrics.minWidth, accuracy: 1, "a short tag: the minimum")
        let create: [AtticSuggestionList.Item] = [.init(id: "create-cuqaz", title: "Create #cuqazzzz", systemName: "plus")]
        show(create)
        presenter.update()
        spin(0.1)
        let wanted = AtticDropdownLayout.width(ideal: AtticSuggestionList.idealWidth(create), available: 296)
        XCTAssertGreaterThan(wanted, AtticDropdownMetrics.minWidth, "the create row needs more than the minimum")
        XCTAssertEqual(host.contentRect.width, wanted, accuracy: 1, "the card grew to its row")
        XCTAssertEqual(presenter.stage.width, wanted)
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testTagFieldEscPassesCompositionAndModifiersThenDismissesAndRestoresFocus() throws {
        let window = makeWindow()
        defer { window.close() }
        let original = NSTextField(frame: CGRect(x: 20, y: 400, width: 200, height: 24))
        window.contentView?.addSubview(original)
        window.makeFirstResponder(original)
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.content = AnyView(TaskTagPickerView(allTags: ["home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        XCTAssertTrue(field.isDescendant(of: try XCTUnwrap(presenter.host)), "the actual tag field is editing")
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let escape = key("\u{1b}", code: 53, in: window)
        XCTAssertIdentical(presenter.handleKey(escape), escape, "composition cancellation reaches the text input")
        XCTAssertTrue(presenter.isOpen)
        // AppKit's input client finishes cancellation; no candidate window
        // or system input-source switch is required in this headless test.
        editor.unmarkText()
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            let modified = key("\u{1b}", code: 53, flags: flags, in: window)
            XCTAssertIdentical(presenter.handleKey(modified), modified)
            XCTAssertTrue(presenter.isOpen)
        }
        XCTAssertNil(presenter.handleKey(escape))
        XCTAssertFalse(presenter.isOpen)
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original)
    }

    /// The rows are one keyboard stop only under Full Keyboard Access, like
    /// buttons. In the default mode Space typed in the tag field is part of
    /// the query, and a click on a row toggles it while the field keeps the
    /// keyboard (typing goes on in it). Real events through the app's queue
    /// to a key panel: on CI only (`ATTIC_KEY_WINDOW_TESTS`), as a key
    /// window would take the keyboard from whoever is at the Mac.
    func testInTheDefaultModeSpaceTypesAndARowClickLeavesTheFieldTheKeyboard() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("needs a key window: CI only")
        }
        XCTAssertFalse(NSApp.isFullKeyboardAccessEnabled, "the default keyboard mode")
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = KeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFront(nil)
        window.makeKey()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var toggled: [String] = []
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.content = AnyView(TaskTagPickerView(allTags: ["design", "home"], state: { _ in .off },
                                                      onToggle: { toggled.append($0) }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.3)
        let field = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField, "the tag field has the keyboard")
        func deliver(_ events: [NSEvent]) {
            events.forEach { NSApp.postEvent($0, atStart: false) }
            var count = 0
            while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                count += 1
            }
            spin(0.2)
        }
        deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: " ",
                             charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        })
        XCTAssertEqual(field.stringValue, " ", "Space typed in the field")
        XCTAssertEqual(toggled, [], "and pressed no row")
        let host = try XCTUnwrap(presenter.host)
        let row = try XCTUnwrap(accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }.first { $0.accessibilityLabel() == "#home" })
        // Where VoiceOver and the pointer find the row (screen points).
        let screen = row.accessibilityFrame()
        let point = window.convertPoint(fromScreen: CGPoint(x: screen.midX, y: screen.midY))
        XCTAssertTrue(host.convert(host.contentRect, to: nil).contains(point), "the row is inside the card: \(screen)")
        // Tab in the field keeps the caret there in this mode (the rows are
        // a stop only under Full Keyboard Access).
        deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "\t",
                             charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        })
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), field, "Tab keeps the keyboard in the field")
        deliver([NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        })
        XCTAssertEqual(toggled, ["home"], "the click toggled the row")
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), field, "the field keeps the keyboard")
    }

    /// Tab in a card's field stays in the card. Left to the window's
    /// key-view loop it gave the keyboard to the card's host view, which
    /// cleared SwiftUI's focus (so under Full Keyboard Access the rows were
    /// never reached and Space pressed nothing). In the default mode the
    /// field keeps the caret. The key goes to the field's editor as the
    /// window would deliver it.
    func testTabInATagFieldKeepsTheKeyboardInTheCard() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        for picker in ["tags", "move"] {
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            presenter.content = picker == "tags"
                ? AnyView(TaskTagPickerView(allTags: ["design", "home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
                : AnyView(TaskMovePickerView(choices: [.init(id: UUID(), title: "Alpha", detail: nil)], onChoose: { _ in }))
            presenter.present(from: anchor)
            spin(0.3)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, picker)
            let field = try XCTUnwrap(editor.delegate as? NSTextField)
            for flags: NSEvent.ModifierFlags in [[], .shift] {
                // As the app delivers it: the open card's key monitor, then
                // the first responder.
                let tab = key("\t", code: 48, flags: flags, in: window)
                if presenter.handleKey(tab) != nil { editor.keyDown(with: tab) }
                spin(0.2)
                XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), field,
                                   "\(picker): Tab \(flags) keeps the caret in the field (\(String(describing: window.firstResponder)))")
            }
            presenter.close(restoreFocus: false, immediately: true)
        }
    }

    /// A view that counts the clicks that reach it.
    final class ClickRecorder: NSView {
        var clicks = 0
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    /// A key panel that never activates the app (no keyboard taken from
    /// whoever is at the Mac).
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// P3-T1: the tag picker from the keyboard with Full Keyboard Access on,
    /// through real events in the app's queue: Tab moves from the field to
    /// the rows, one keyboard stop that highlights its first row, and Space
    /// presses it; ↓ moves the one highlight (VoiceOver's
    /// "selected"; ticks stay marks); Return toggles the highlighted tag;
    /// Esc closes the card and gives the keyboard back; a click outside
    /// closes it and goes through to what is under it.
    func testTheTagPickerWorksFromTheKeyboardWithFullKeyboardAccess() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_FULL_KEYBOARD_ACCESS_TESTS"] == "1" else {
            throw XCTSkip("CI enables Full Keyboard Access before launching the test host; local tests preserve the user's setting")
        }
        XCTAssertTrue(NSApp.isFullKeyboardAccessEnabled, "verify AppKit's actual mode, not just a preference value")
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = RecordingKeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFront(nil)
        window.makeKey()
        defer { window.close() }
        XCTAssertTrue(window.isKeyWindow)
        let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
        window.contentView?.addSubview(original)
        let recorder = ClickRecorder(frame: CGRect(x: 240, y: 20, width: 60, height: 40))
        window.contentView?.addSubview(recorder)
        let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var toggled: [String] = []
        var dismissals = 0
        func open() throws -> AtticDropdownPresenter {
            window.makeFirstResponder(original)
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            presenter.onDismiss = { dismissals += 1 }
            presenter.content = AnyView(TaskTagPickerView(allTags: ["design", "home", "launch"], state: { $0 == "home" ? .on : .off },
                                                          onToggle: { toggled.append($0) }, onCreate: { _, _ in true }))
            presenter.present(from: anchor)
            spin(0.3)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true, "the tag field has the keyboard")
            return presenter
        }
        func deliver(_ events: [NSEvent]) {
            events.forEach { NSApp.postEvent($0, atStart: false) }
            var count = 0
            while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                count += 1
            }
            spin(0.2)
        }
        func press(_ characters: String, _ code: UInt16) {
            deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            })
        }
        func items(_ host: NSView) -> [AtticDropdownMenuItem.ItemView] {
            accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        }
        func selected(_ host: NSView) -> [String] {
            items(host).filter { $0.isAccessibilitySelected() }.compactMap { $0.accessibilityLabel() }
        }

        window.start = ProcessInfo.processInfo.systemUptime
        window.log = ["app active=\(NSApp.isActive) key=\(window.isKeyWindow) keyWindow=\(String(describing: NSApp.keyWindow.map { type(of: $0) }))"]
        let presenter = try open()
        let host = try XCTUnwrap(presenter.host)
        window.log.append("before tab: active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        press("\t", 48)
        window.log.append("after tab: active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        if (window.firstResponder as? NSTextView)?.isFieldEditor == true { window.log.forEach { print("FKANATIVE-FAIL " + $0) } }
        let afterTab = window.firstResponder as? NSView
        XCTAssertFalse((afterTab as? NSTextView)?.isFieldEditor == true, "Tab left the field")
        XCTAssertTrue(afterTab?.isDescendant(of: host) == true, "the keyboard is still in the card")
        XCTAssertEqual(selected(host), ["#design"], "Tab reached the rows: the first is highlighted, and only it is selected"
                       + " (first responder \(String(describing: window.firstResponder)))")
        press(" ", 49)
        XCTAssertEqual(toggled, ["design"], "Space pressed the row Tab reached")
        XCTAssertTrue(presenter.isOpen, "toggling a tag keeps the card open")
        press("\u{F701}", 125)
        XCTAssertEqual(selected(host), ["#home"], "↓ moves the one highlight")
        XCTAssertEqual(items(host).first { $0.accessibilityLabel() == "#home" }.flatMap(Self.markChar), "✓", "its tick is its mark")
        press("\r", 36)
        XCTAssertEqual(toggled.dropFirst().first, "home", "Return toggles the highlighted tag")
        press("\u{1b}", 53)
        XCTAssertFalse(presenter.isOpen, "Esc closes the card")
        XCTAssertEqual(dismissals, 1)
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "the keyboard goes back")
        presenter.close(restoreFocus: false, immediately: true)

        // A click outside, with a row focused from the keyboard.
        let second = try open()
        // In the field, Space types: it presses no row.
        press(" ", 49)
        XCTAssertEqual((((window.firstResponder as? NSTextView)?.delegate) as? NSTextField)?.stringValue, " ", "Space typed in the tag field")
        XCTAssertEqual(toggled, ["design", "home"], "and pressed no row")
        press("\t", 48)
        XCTAssertFalse((window.firstResponder as? NSTextView)?.isFieldEditor == true, "Tab left the field")
        let point = recorder.convert(CGPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil)
        deliver([NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        })
        XCTAssertFalse(second.isOpen, "a click outside closes the card")
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(recorder.clicks, 1, "the click goes through to what is under it")
        second.close(restoreFocus: false, immediately: true)
    }

    func testOutsideClickDismissesAnEditingTagFieldAndPassesThrough() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.content = AnyView(TaskTagPickerView(allTags: ["home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 310, y: 510),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertIdentical(presenter.handleClick(click), click)
        XCTAssertFalse(presenter.isOpen)
    }

    func testPriorityChordsInvokeTheOpenPickersAction() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        var picked: [TaskPriority] = []
        presenter.contentHeight = AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4
        presenter.content = AnyView(TaskPriorityPickerView(current: nil) { picked.append($0) })
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let host = try XCTUnwrap(presenter.host)
        for (index, code) in [UInt16(29), 18, 19, 20].enumerated() {
            NSApp.sendEvent(key("\(index)", code: code, flags: [.option, .command], in: window))
            spin()
        }
        XCTAssertEqual(picked, TaskPriority.choices)
        XCTAssertFalse(host.performKeyEquivalent(with: key("1", code: 18, flags: .command, in: window)))
        XCTAssertEqual(picked, TaskPriority.choices)
        presenter.close(restoreFocus: false, immediately: true)
        NSApp.sendEvent(key("0", code: 29, flags: [.option, .command], in: window))
        spin()
        XCTAssertEqual(picked, TaskPriority.choices, "closed pickers no longer own the chords")
    }

    final class RetryContent: ObservableObject {
        @Published var failed = false
    }

    struct RetryingTagPicker: View {
        @ObservedObject var model: RetryContent
        var body: some View {
            VStack(spacing: 0) {
                TaskTagPickerView(allTags: (0..<7).map { "tag\($0)" }, state: { _ in .off },
                                  onToggle: { _ in }, onCreate: { _, _ in false })
                if model.failed { Text("Save failed; Retry").frame(height: 120) }
            }
            // The real row picker clears its failure only when it leaves.
            .onDisappear { model.failed = false }
        }
    }

    func testAHeightChangePreservesTheEditingTagQueryAndRetryState() throws {
        let window = makeWindow()
        window.setContentSize(CGSize(width: 320, height: 420))
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let model = RetryContent()
        let presenter = AtticDropdownPresenter()
        presenter.prefer = .above
        presenter.content = AnyView(RetryingTagPicker(model: model))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("tag0", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.1)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        XCTAssertEqual(field.stringValue, "tag0")
        XCTAssertNil(presenter.stage.height, "the initial card fits")
        model.failed = true
        spin(0.3)
        XCTAssertTrue(model.failed, "constraining the card must not run its dismissal cleanup")
        XCTAssertNotNil(presenter.stage.height, "the error grows beyond the available room")
        let current = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        XCTAssertEqual(current.stringValue, "tag0", "the typed query survives the scrolling threshold")
        model.failed = false
        spin(0.3)
        XCTAssertNil(presenter.stage.height, "clearing the error returns the card to its natural height")
        let restored = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        XCTAssertEqual(restored.stringValue, "tag0", "shrinking must preserve editing state too")
    }

    /// P3-B2: a tag picker taller than both sides of its anchor settles its
    /// height in one step as it opens (it flickered `nil → 178 → nil …`).
    func testATagPickerTallerThanBothSidesSettlesItsHeightInOneStep() throws {
        let window = makeWindow()
        window.setContentSize(CGSize(width: 320, height: 420))
        defer { window.close() }
        // Mid-panel: 162 pt above the anchor, 194 below; the card is 280.
        let anchor = NSView(frame: CGRect(x: 40, y: 212, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.prefer = .above
        var heights: [CGFloat?] = []
        let watch = presenter.stage.$height.dropFirst().sink { heights.append($0) }
        defer { watch.cancel() }
        presenter.content = AnyView(TaskTagPickerView(allTags: (0..<7).map { "tag\($0)" }, state: { _ in .off },
                                                      onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.6)
        let m = AtticDropdownMetrics.self
        let natural = m.inset * 2 + m.fieldHeight + m.fieldGap + 7 * m.rowHeight
        let limit = try XCTUnwrap(presenter.stage.height, "neither side holds the card")
        XCTAssertLessThan(limit, natural)
        XCTAssertEqual(presenter.stage.side, .below, "the roomier side")
        XCTAssertEqual(Array(heights.drop { $0 == nil }), [limit], "one step from nil to the limit, then it holds: \(heights)")
        XCTAssertEqual(try XCTUnwrap(presenter.host).contentRect.height, limit, accuracy: 1)
    }

    /// P3-B3: Move to Task… low in the panel opens above; typing a filter
    /// until the list would fit below leaves it above (it jumped across
    /// the row mid-typing).
    func testAFilteredCardKeepsItsSide() throws {
        let window = makeWindow()
        defer { window.close() }
        // 336 pt above the anchor, 120 below.
        let anchor = NSView(frame: CGRect(x: 40, y: 138, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]
        presenter.content = AnyView(TaskMovePickerView(choices: names.map { .init(id: UUID(), title: $0, detail: "Now") }, onChoose: { _ in }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.3)
        let host = try XCTUnwrap(presenter.host)
        XCTAssertEqual(presenter.stage.side, .above, "the full list fits only above")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("Alpha", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.3)
        let card = AtticDropdownLayout.topDown(host.convert(host.contentRect, to: window.contentView), in: window.contentView!)
        let anchorTop = 520 - anchor.frame.maxY
        XCTAssertLessThanOrEqual(card.height, 520 - 12 - (anchorTop + 28 + AtticDropdownMetrics.anchorGap),
                                 "the filtered card would fit below")
        XCTAssertEqual(presenter.stage.side, .above, "it keeps its side while filtering")
        XCTAssertEqual(card.maxY, anchorTop - AtticDropdownMetrics.anchorGap, accuracy: 1, "still hanging from the row")
    }

    private func accessibilityElements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { accessibilityElements($0 as AnyObject) }
    }

    func testCalendarHeightTracksFourFiveAndSixWeeksAndLastRowRemainsInteractive() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        // Room above the anchor for five weeks of the Compact card, not six.
        window.setContentSize(CGSize(width: 320, height: 295))
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2021, month: 2, day: 1)))
        let choices = TaskDateChoices(parser: TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { february }))
        var picked: DueDay?
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.prefer = .above
        presenter.content = AnyView(TaskDatePickerView(choices: choices, selected: nil, onPick: { picked = $0 }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let host = try XCTUnwrap(presenter.host)
        let four = host.contentRect.size
        XCTAssertNil(presenter.stage.height, "February 2021's four weeks fit")
        func nextMonth() throws {
            let next = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == "Next month" })
            XCTAssertTrue(next.accessibilityPerformPress?() == true)
            spin(0.2)
        }
        try nextMonth() // March: five weeks
        XCTAssertEqual(host.contentRect.width, four.width, accuracy: 1)
        XCTAssertEqual(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight, accuracy: 1)
        try nextMonth() // April: five weeks
        try nextMonth() // May: six weeks, constrained at this anchor
        XCTAssertEqual(host.contentRect.width, four.width, accuracy: 1)
        XCTAssertNotNil(presenter.stage.height)
        XCTAssertGreaterThan(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight)
        let inWindow = host.convert(host.contentRect, to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minY, 12)
        XCTAssertLessThanOrEqual(inWindow.maxY, 283)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
        }
        let scroll = try XCTUnwrap(scrolls(host).first)
        let document = try XCTUnwrap(scroll.documentView)
        document.scrollToVisible(CGRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
        spin(0.2)
        // The month shows no other month's days: 31 May is its last.
        let last = DueDay(rawValue: "2021-05-31")!
        let label = AtticDateCardFormat.spoken(try XCTUnwrap(last.startDate(in: calendar)), calendar: choices.cardCalendar)
        let day = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == label })
        let frame: NSRect = day.accessibilityFrame!()
        let local = host.convert(window.convertFromScreen(frame), from: nil)
        let center = CGPoint(x: local.midX, y: local.midY)
        XCTAssertTrue(host.contentRect.contains(center), "the last calendar row is inside the updated hit bounds after scrolling")
        XCTAssertNotNil(host.hitTest(host.convert(center, to: host.superview)))
        XCTAssertTrue(day.accessibilityPerformPress?() == true)
        XCTAssertEqual(picked, last, "the bottom day runs the real pick action")
        // Shrinking removes the viewport instead of retaining the old limit.
        let previousMonth = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == "Previous month" })
        XCTAssertTrue(previousMonth.accessibilityPerformPress?() == true)
        spin(0.2)
        XCTAssertNil(presenter.stage.height)
        XCTAssertEqual(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight, accuracy: 1)
    }

    /// The date card on screen (owner, 2026-10-05): no quick rows; the
    /// chosen day and today told apart to VoiceOver; typing shows the
    /// suggestions above the month and clearing removes them; Return picks
    /// the lit suggestion.
    func testTheDateCardMarksTodayAndTheChosenDayAndSuggestsWhatIsTyped() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 40, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
        let choices = TaskDateChoices(parser: TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { monday }))
        var picked: DueDay?
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.content = AnyView(TaskDatePickerView(choices: choices, selected: DueDay(rawValue: "2026-10-09"), forRow: true,
                                                       onPick: { picked = $0 }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let host = try XCTUnwrap(presenter.host)
        func element(_ label: String) -> AnyObject? {
            accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == label }
        }
        func value(_ label: String) -> String? {
            // SwiftUI's node answers the protocol's accessibilityValue().
            (element(label) as? NSObject)?.perform(Selector(("accessibilityValue")))?.takeUnretainedValue() as? String
        }
        XCTAssertNil(element("Tomorrow, Tue"), "no quick rows")
        XCTAssertEqual(value("Monday 5 October"), "today")
        XCTAssertEqual(value("Friday 9 October"), "chosen")
        XCTAssertNil(element("Thursday 1 November"), "no other month's days")
        XCTAssertNotNil(element("Remove date"), "a row's existing route to remove its date stays")
        let resting = host.contentRect.height

        func key(_ characters: String, _ keyCode: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            XCTAssertNil(presenter.handleKey(event), "the card takes \(characters.debugDescription)")
            spin(0.1)
        }
        key("t", 17)
        XCTAssertNotNil(element("Today, Mon"), "typing suggests")
        XCTAssertNotNil(element("Tomorrow, Tue"))
        XCTAssertEqual(host.contentRect.height, resting + 2 * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.fieldGap, accuracy: 1)
        key("\u{7f}", 51)
        XCTAssertNil(element("Today, Mon"), "cleared, the suggestions go")
        XCTAssertEqual(host.contentRect.height, resting, accuracy: 1, "and the card is draft 2 again")
        for (character, code) in [("t", UInt16(17)), ("o", 31), ("m", 46)] { key(character, code) }
        XCTAssertNotNil(element("Tomorrow, Tue"))
        key("\r", 36)
        XCTAssertEqual(picked, DueDay(rawValue: "2026-10-06"), "Return picks the lit suggestion")
    }

    // MARK: Timings (no regression against the components it replaced)

    private func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    /// Before E1: the `/` list was `AtticPopover` with 28 pt `AtticPopoverRow`s
    /// and a hint column, 256 wide.
    struct LegacySlashList: View {
        @ObservedObject var model: NoteSlashListModel
        var body: some View {
            ZStack(alignment: .topLeading) {
                if model.shown, !model.items.isEmpty {
                    AtticPopover(width: 256) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            AtticPopoverRow(systemName: NoteCommandCatalog.slashSymbol(item.kind), title: item.title,
                                            detail: NoteCommandCatalog.slashHint(item.kind),
                                            isHighlighted: index == model.highlighted) {}
                        }
                    }
                }
            }
            .padding(12)
            .fixedSize()
        }
    }

    /// Before E1: the tag picker's field and 28 pt choice rows on the
    /// picker surface, in a native pop-over.
    struct LegacyTagPicker: View {
        let tags: [String]
        @State private var query = ""
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextField("", text: $query, prompt: Text("Find or add a tag"))
                    .textFieldStyle(.plain)
                    .font(AtticTextStyle.menuRow.font)
                    .frame(height: 28)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tags, id: \.self) { tag in
                            AtticChoiceRow(title: "#" + tag, check: .off, isHighlighted: false, onHover: { _ in }) {}
                        }
                    }
                }
                .frame(maxHeight: 196)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200)
            .atticPickerSurface()
        }
    }

    /// What the gate times: each dropdown interaction against the component
    /// it replaced. The `/` list's filter keystroke is timed apart as it
    /// narrows (nine rows to four) and widens (back to nine): pooled, their
    /// two clusters made the median jump between runs.
    enum Measure: String, CaseIterable {
        case slashOpen, slashNarrow, slashWiden, tagOpen, priorityOpen
    }

    /// One round: each measure's median for the dropdown and for the
    /// component it replaced (the priority picker is held against the old
    /// tag pop-over, as before).
    struct Round {
        var new: [Measure: Double] = [:]
        var legacy: [Measure: Double] = [:]
        func ratio(_ measure: Measure) -> Double { new[measure, default: 0] / max(legacy[measure, default: 0], .ulpOfOne) }
    }

    /// Opens, filters and closes the dropdowns and the components they
    /// replaced, the same way, in `rounds` interleaved rounds. With
    /// `readAccessibility`, each sample also reads the shown list's
    /// accessibility tree, as VoiceOver does when a menu opens or changes
    /// (that is when SwiftUI builds each row's accessibility element).
    private func measureDropdownCosts(in window: NSWindow, rounds: Int, readAccessibility: Bool = false) -> [Round] {
        let design = AtticDesignContext()
        let all = NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) }
        let filtered = all.filter { $0.title.lowercased().contains("li") }

        func slashTimings<V: View>(_ make: (NoteSlashListModel) -> V) -> (open: [Double], narrow: [Double], widen: [Double]) {
            let model = NoteSlashListModel()
            let host = NSHostingView(rootView: make(model).atticDesign(design))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
            window.contentView?.addSubview(host)
            defer { host.removeFromSuperview() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var open: [Double] = [], narrow: [Double] = [], widen: [Double] = []
            func read() { if readAccessibility { _ = accessibilityElements(host) } }
            for _ in 0..<15 {
                model.hide(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read()
                open.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
                narrow.append(ms { model.show(filtered); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
                widen.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
            }
            return (open, narrow, widen)
        }

        let tags = (0..<12).map { "tag\($0)" }
        let anchor = NSView(frame: NSRect(x: 40, y: 60, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        defer { anchor.removeFromSuperview() }
        func pickerTimings() -> (legacyTag: [Double], tag: [Double], priority: [Double]) {
            var legacyTag: [Double] = [], tag: [Double] = [], priority: [Double] = []
            for round in 0..<16 {
                // Before E1 the Tasks pickers were native pop-overs.
                let popover = NSPopover()
                popover.animates = false
                popover.contentViewController = NSHostingController(rootView: LegacyTagPicker(tags: tags).atticDesign(design))
                let legacy = ms {
                    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                    popover.contentViewController?.view.window?.displayIfNeeded()
                    if readAccessibility, let view = popover.contentViewController?.view { _ = accessibilityElements(view) }
                }
                popover.close()
                if round > 0 { legacyTag.append(legacy) }
                let presenter = AtticDropdownPresenter()
                presenter.design = design
                presenter.prefer = .above
                presenter.content = AnyView(TaskTagPickerView(allTags: tags, state: { $0 == "tag2" ? .on : .off }, onToggle: { _ in },
                                                              onCreate: { _, _ in true }, focusField: false))
                let opened = ms {
                    presenter.present(from: anchor)
                    presenter.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if readAccessibility, let host = presenter.host { _ = accessibilityElements(host) }
                }
                if round > 0 { tag.append(opened) }
                presenter.close(restoreFocus: false, immediately: true)
                let prio = AtticDropdownPresenter()
                prio.design = design
                // The real composer strip supplies this fixed four-row height.
                prio.contentHeight = AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4
                prio.content = AnyView(TaskPriorityPickerView(current: .high, onPick: { _ in }))
                let prioOpened = ms {
                    prio.present(from: anchor)
                    prio.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if readAccessibility, let host = prio.host { _ = accessibilityElements(host) }
                }
                if round > 0 { priority.append(prioOpened) }
                prio.close(restoreFocus: false, immediately: true)
            }
            return (legacyTag, tag, priority)
        }

        // Warm both (first-use costs: fonts, symbols), then measure.
        _ = slashTimings { LegacySlashList(model: $0) }
        _ = slashTimings { NoteSlashListView(model: $0) }
        return (0..<rounds).map { _ in
            var round = Round()
            let legacy = slashTimings { LegacySlashList(model: $0) }
            let slash = slashTimings { NoteSlashListView(model: $0) }
            let pickers = pickerTimings()
            round.legacy[.slashOpen] = median(legacy.open); round.new[.slashOpen] = median(slash.open)
            round.legacy[.slashNarrow] = median(legacy.narrow); round.new[.slashNarrow] = median(slash.narrow)
            round.legacy[.slashWiden] = median(legacy.widen); round.new[.slashWiden] = median(slash.widen)
            round.legacy[.tagOpen] = median(pickers.legacyTag); round.new[.tagOpen] = median(pickers.tag)
            round.legacy[.priorityOpen] = median(pickers.legacyTag); round.new[.priorityOpen] = median(pickers.priority)
            return round
        }
    }

    /// The accepted cost of each measure, as the dropdown's median over the
    /// replaced component's in the same run (which cancels most of a
    /// machine's speed), and how far that ratio moved between the runs it
    /// was measured on (largest less smallest). Measured 2026-10-03 on this
    /// branch's code, locally and on CI (see
    /// phase0/runs/p2-review-fix-ui-report.md); a run fails only past the
    /// accepted ratio plus that spread. Re-derive both from the printed
    /// `DROPDOWN_RATIO` lines when a change is accepted.
    struct Accepted {
        let ratio: Double
        let spread: Double
        var limit: Double { ratio + spread }
    }

    // Accessibility off: four local runs (five rounds each, this Mac) and
    // CI runs 37113517492 (all five measures), 37107865236, 37107548347 and
    // 37082392931 (open measures; their pooled filter can't be split).
    static let acceptedRatios: [Measure: Accepted] = [
        .slashOpen: Accepted(ratio: 0.280, spread: 0.094),     // 0.236 … 0.330
        .slashNarrow: Accepted(ratio: 2.158, spread: 0.591),   // 1.610 … 2.201
        .slashWiden: Accepted(ratio: 1.335, spread: 0.281),    // 1.080 … 1.361
        .tagOpen: Accepted(ratio: 0.660, spread: 0.191),       // 0.579 … 0.770
        .priorityOpen: Accepted(ratio: 0.350, spread: 0.152),  // 0.268 … 0.420
    ]

    // Accessibility on: the same four local runs and CI run 37113517492.
    static let acceptedRatiosWithAccessibility: [Measure: Accepted] = [
        .slashOpen: Accepted(ratio: 0.360, spread: 0.088),     // 0.347 … 0.435
        .slashNarrow: Accepted(ratio: 3.290, spread: 0.360),   // 3.010 … 3.370
        .slashWiden: Accepted(ratio: 1.960, spread: 0.350),    // 1.680 … 2.030
        .tagOpen: Accepted(ratio: 0.727, spread: 0.205),       // 0.665 … 0.870
        .priorityOpen: Accepted(ratio: 0.333, spread: 0.168),  // 0.312 … 0.480
    ]

    private func gate(_ rounds: [Round], label: String, accepted: [Measure: Accepted]) {
        for measure in Measure.allCases {
            let ratios = rounds.map { $0.ratio(measure) }
            let ratio = median(ratios)
            let new = median(rounds.map { $0.new[measure, default: 0] })
            let legacy = median(rounds.map { $0.legacy[measure, default: 0] })
            print("DROPDOWN_RATIO\(label) \(measure.rawValue) ratio=\(ratio) rounds=\(ratios.map { ($0 * 1000).rounded() / 1000 })"
                  + " new_ms=\(new) legacy_ms=\(legacy)")
            guard let accepted = accepted[measure] else { continue }
            XCTAssertLessThanOrEqual(ratio, accepted.limit,
                                     "\(measure.rawValue)\(label): \(ratio) of the replaced component's cost, past the accepted"
                                     + " \(accepted.ratio) and its run-to-run spread \(accepted.spread)")
        }
    }

    func testOpenAndFilterCostNoMoreThanBefore() {
        let window = makeWindow()
        defer { window.close() }
        gate(measureDropdownCosts(in: window, rounds: 5), label: "", accepted: Self.acceptedRatios)
    }

    /// The same gate with accessibility on and the tree read (as VoiceOver
    /// reads a menu), so each row's accessibility element is built and paid
    /// for. The replaced components build and read theirs too.
    func testOpenAndFilterCostNoMoreThanBeforeWithAccessibilityOn() {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        gate(measureDropdownCosts(in: window, rounds: 5, readAccessibility: true), label: "_AX",
             accepted: Self.acceptedRatiosWithAccessibility)
    }
}

/// The date card's model (owner, 2026-10-05: p2-30 draft 2 on p2-29 draft
/// A): the quiet month, the one highlight and its keys, and what typing
/// suggests. Pure.
final class AtticDateCardTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Monday 5 October 2026, as in the drafts.
    private var today: Date { date(2026, 10, 5) }

    private func parse(_ text: String) -> Date? {
        NoteDateQuery.parse(text, today: today, calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    func testTheMonthShowsNoOtherMonthsDays() {
        let october = AtticDateMonth(containing: date(2026, 10, 9), calendar: calendar)
        XCTAssertEqual(october.weekdays, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(october.cells.prefix(3), [nil, nil, nil], "1 Oct is a Thursday: three blank cells lead")
        XCTAssertEqual(october.cells[3], date(2026, 10, 1))
        XCTAssertEqual(october.cells.compactMap { $0 }.count, 31)
        XCTAssertEqual(october.cells.count % 7, 0)
        XCTAssertEqual(october.weeks, 5)
        XCTAssertNil(october.cells.last ?? nil, "1 November is not shown")
        XCTAssertEqual(AtticDateCardFormat.monthTitle(october.start, calendar: calendar), "October 2026")
        XCTAssertEqual(AtticDateCardFormat.spoken(date(2026, 10, 9), calendar: calendar), "Friday 9 October")
        var sunday = calendar
        sunday.firstWeekday = 1
        let us = AtticDateMonth(containing: date(2026, 10, 1), calendar: sunday)
        XCTAssertEqual(us.weekdays.first, "S")
        XCTAssertEqual(us.cells.prefix(5).filter { $0 == nil }.count, 4)
    }

    func testArrowsLightTheCursorFirstThenMoveItAndTheMonthFollows() {
        var state = AtticDateCardState(start: today)
        XCTAssertNil(state.lit, "nothing is lit as the card opens")
        func press(_ key: AtticDateCardKey) -> AtticDateCardState.Outcome? {
            state.apply(key, calendar: calendar, suggestions: 0, typing: false, hasRemove: false)
        }
        XCTAssertEqual(press(.right), .nothing)
        XCTAssertEqual(state.lit, .day)
        XCTAssertEqual(state.cursor, today, "the first arrow lights the day, never skips it")
        _ = press(.right)
        _ = press(.down)
        XCTAssertEqual(state.cursor, date(2026, 10, 13))
        _ = press(.up)
        _ = press(.left)
        XCTAssertEqual(state.cursor, today)
        for _ in 0..<5 { _ = press(.down) }
        XCTAssertEqual(state.cursor, date(2026, 11, 9))
        XCTAssertEqual(state.month(calendar).start, date(2026, 11, 1), "the month shown is the cursor's")
        XCTAssertEqual(press(.pick), .pick(date(2026, 11, 9)), "Return picks the day lit")
    }

    func testCommandBracketsTurnTheMonthClampedToItsLength() {
        var state = AtticDateCardState(start: date(2027, 1, 31))
        _ = state.apply(.month(1), calendar: calendar, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.cursor, date(2027, 2, 28))
        XCTAssertNil(state.lit, "turning the month lights nothing")
        _ = state.apply(.month(-2), calendar: calendar, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.month(calendar).start, date(2026, 12, 1), "across the year")
        XCTAssertEqual(AtticDateCardKey(keyEvent("[", keyCode: 33, flags: .command)), .month(-1))
        XCTAssertEqual(AtticDateCardKey(keyEvent("]", keyCode: 30, flags: .command)), .month(1))
        XCTAssertEqual(AtticDateCardKey(keyEvent("†", keyCode: 17, flags: .option)), .today)
        XCTAssertEqual(AtticDateCardKey(keyEvent("\t", keyCode: 48, flags: [])), .tab(back: false))
        XCTAssertEqual(AtticDateCardKey(keyEvent("f", keyCode: 3, flags: [])), .text("f"))
        XCTAssertNil(AtticDateCardKey(keyEvent("\u{1b}", keyCode: 53, flags: [])), "Esc stays the presenter's")
    }

    func testTabReachesTodayAndRemoveAndReturnPicksThem() {
        var state = AtticDateCardState(start: today)
        func press(_ key: AtticDateCardKey, remove: Bool = true) -> AtticDateCardState.Outcome? {
            state.apply(key, calendar: calendar, suggestions: 0, typing: false, hasRemove: remove)
        }
        _ = press(.tab(back: false))
        XCTAssertEqual(state.lit, .today, "one Tab reaches Today")
        XCTAssertEqual(press(.pick), .today)
        _ = press(.tab(back: false))
        XCTAssertEqual(state.lit, .remove)
        XCTAssertEqual(press(.pick), .remove)
        _ = press(.tab(back: false))
        XCTAssertEqual(state.lit, .day, "Tab comes round to the grid")
        _ = press(.tab(back: true))
        XCTAssertEqual(state.lit, .remove, "Shift-Tab goes back")
        XCTAssertEqual(press(.today), .today, "⌥T picks today from anywhere")
        var fresh = AtticDateCardState(start: date(2026, 10, 9))
        XCTAssertEqual(fresh.apply(.pick, calendar: calendar, suggestions: 0, typing: false, hasRemove: false), .pick(date(2026, 10, 9)),
                       "Return with nothing lit picks the chosen day (today in a fresh card)")
    }

    func testThePointerMovesTheSameOneHighlight() {
        var state = AtticDateCardState(start: today)
        _ = state.apply(.down, calendar: calendar, suggestions: 0, typing: false, hasRemove: false)
        state.hover(.today, inside: true)
        XCTAssertEqual(state.lit, .today, "the pointer on Today takes the highlight from the day")
        XCTAssertFalse(state.isLit(today, calendar: calendar))
        state.hoverDay(date(2026, 10, 9), inside: true, calendar: calendar)
        XCTAssertTrue(state.isLit(date(2026, 10, 9), calendar: calendar))
        XCTAssertEqual(state.lit, .day)
        state.hover(.today, inside: false)
        XCTAssertEqual(state.lit, .day, "leaving Today after the pointer moved on clears nothing")
        state.hoverDay(date(2026, 10, 9), inside: false, calendar: calendar)
        XCTAssertNil(state.lit)
        XCTAssertEqual(state.cursor, date(2026, 10, 9), "the next arrow starts where the pointer was")
    }

    func testTypingSuggestsOneOrTwoDaysAndClearingRemovesThem() {
        func suggest(_ text: String) -> [AtticDateSuggestion] {
            AtticDateSuggestions.make(text, today: today, calendar: calendar, parse: parse)
        }
        XCTAssertEqual(suggest(""), [])
        XCTAssertEqual(suggest("  "), [])
        let t = suggest("t")
        XCTAssertEqual(t.map(\.title), ["Today", "Tomorrow"])
        XCTAssertEqual(t.map(\.detail), ["Mon", "Tue"])
        let fri = suggest("fri")
        XCTAssertEqual(fri.map(\.title), ["Friday"])
        XCTAssertEqual(fri.first?.detail, "9 Oct")
        XCTAssertEqual(fri.first?.date, date(2026, 10, 9))
        XCTAssertEqual(fri.first?.match, "fri", "the typed part is emboldened")
        XCTAssertEqual(suggest("tom").map(\.title), ["Tomorrow"])
        XCTAssertEqual(suggest("in 3 days").map(\.title), ["Thursday"])
        XCTAssertEqual(suggest("xyz"), [], "no match: none")

        var state = AtticDateCardState(start: today)
        state.typed(suggestions: fri)
        XCTAssertEqual(state.lit, .suggestion(0), "the first suggestion is lit")
        XCTAssertEqual(state.month(calendar).start, date(2026, 10, 1))
        XCTAssertEqual(state.apply(.pick, calendar: calendar, suggestions: 1, typing: true, hasRemove: false), .suggestion(0))
        _ = state.apply(.down, calendar: calendar, suggestions: 1, typing: true, hasRemove: false)
        XCTAssertEqual(state.lit, .day, "↓ past the last suggestion reaches the grid, on its day")
        XCTAssertTrue(state.isLit(date(2026, 10, 9), calendar: calendar))
        state.typed(suggestions: t)
        XCTAssertEqual(state.lit, .suggestion(0))
        _ = state.apply(.down, calendar: calendar, suggestions: 2, typing: true, hasRemove: false)
        XCTAssertEqual(state.lit, .suggestion(1))
        state.typed(suggestions: [])
        XCTAssertNil(state.lit, "cleared, the suggestions and their highlight go")
        XCTAssertEqual(state.apply(.pick, calendar: calendar, suggestions: 0, typing: true, hasRemove: false), .nothing,
                       "typed text that matches nothing picks nothing")
    }

    func testTheCompactSizeTokens() {
        let m = AtticDropdownMetrics.self
        XCTAssertEqual(m.rowHeight, 28)
        XCTAssertEqual(m.cornerRadius, 16)
        XCTAssertEqual(m.inset, 6)
        XCTAssertEqual(m.rowPadding, 9)
        XCTAssertEqual(m.highlightRadius, 8)
        XCTAssertEqual(m.cornerRadius - m.inset, m.highlightRadius + 2, "the pill sits inside the corner")
        XCTAssertEqual(m.fieldHeight, 26)
        XCTAssertEqual(m.minWidth, 144, "the width rule is unchanged")
        XCTAssertEqual(m.panelMargin, 12)
        XCTAssertEqual(AtticTextStyle.dropdownRow.spec.size, 13)
        XCTAssertEqual(AtticTextStyle.dropdownHeading.spec.size, 13)
        XCTAssertEqual(AtticTextStyle.dropdownDay.spec.size, 12.5)
        XCTAssertEqual(AtticTextStyle.dropdownWeekday.spec.size, 10)
        XCTAssertEqual(m.monthMark, 25)
        XCTAssertEqual(m.monthMarkRadius, 7)
        XCTAssertEqual(AtticPickerMetrics.tagListMaxHeight, 7 * m.rowHeight, "seven rows before the tag list scrolls")
        XCTAssertEqual(m.monthCellWidth * 7 + m.monthGridInset * 2 + m.inset * 2, 221, accuracy: 1, "draft 2's 222 pt card")
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}
