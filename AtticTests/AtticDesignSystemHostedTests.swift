import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The design system hosted the way the app hosts it: real windows, real
/// AppKit controls (not the capture stand-ins), real keyboard events and
/// the real accessibility tree.
@MainActor
final class AtticDesignSystemHostedTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        try await super.tearDown()
    }

    // MARK: Hosting

    private func host<V: View>(_ view: V, size: CGSize, context: AtticDesignContext = .default, key: Bool = false) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            view
                .frame(width: size.width, height: size.height)
                .background(context.tokens.panel.base.color)
                .atticDesign(context)
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window: NSWindow = key
            ? KeyTestWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: context.mode == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        if key {
            // The unit-test host runs with a prohibited activation policy
            // and never becomes active, so AppKit never makes its windows
            // key. `KeyTestWindow` reports itself key, which is all
            // keyboard focus needs; events are delivered to it directly.
            window.makeKeyAndOrderFront(nil)
            (window as? KeyTestWindow)?.becomeKey()
        } else {
            window.orderFront(nil)
        }
        windows.append(window)
        spin()
        return (window, hosting)
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The hosting view as it is drawn on screen, at the window's scale.
    private func snapshot(_ view: NSView) throws -> (bitmap: AtticBitmap, scale: CGFloat) {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let bitmap = try XCTUnwrap(AtticBitmap(image: image))
        return (bitmap, CGFloat(image.width) / view.bounds.width)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func key(_ window: NSWindow, _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code
            )!
            window.sendEvent(event)
        }
        spin(0.1)
    }

    // MARK: Native controls

    /// The pieces the spec keeps native (text field, switch, slider, pop-up
    /// and title menus) are the system's own AppKit controls when hosted,
    /// and what they draw meets the same rule as Attic's own ink.
    func testNativeControlsAreHostedAsTheSystemsOwn() throws {
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark), AtticDesignContext(mode: .light, increaseContrast: true)] {
            var isOn = true
            var tint = 0.6
            var surface = "solid"
            let view = VStack(alignment: .leading, spacing: 12) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: {})
                AtticGroupCard {
                    AtticSwitchRow(title: "Haptics", isOn: Binding(get: { isOn }, set: { isOn = $0 }))
                    AtticGroupDivider()
                    AtticSliderRow(label: "Tint length", valueText: "60 %", value: Binding(get: { tint }, set: { tint = $0 }), range: 0.3...1)
                    AtticGroupDivider()
                    AtticPopUpRow(label: "Surface", choices: [("solid", "Solid"), ("glass", "Glass")], selection: Binding(get: { surface }, set: { surface = $0 }))
                }
                AtticTitleMenu(title: "Launch sync", commands: [
                    AtticMenuCommand("Duplicate", systemImage: "plus.square.on.square", shortcut: KeyboardShortcut("d", modifiers: .command)) {},
                    AtticMenuCommand("Delete", systemImage: "trash", isDestructive: true, startsSection: true) {}
                ])
            }
            .padding(12)
            let (_, hosting) = host(view, size: CGSize(width: 420, height: 330), context: context)
            let classes = descendants(of: hosting).map { String(describing: type(of: $0)) }
            let all = descendants(of: hosting)

            // The field and the switch are AppKit controls.
            XCTAssertTrue(all.contains { $0 is NSTextField }, "\(context.caption): no NSTextField in \(classes)")
            XCTAssertTrue(all.contains { $0 is NSSwitch || String(describing: type(of: $0)).contains("Switch") }, "\(context.caption): no native switch in \(classes)")

            // The slider is the system slider: VoiceOver sees a slider and
            // its increment moves the value.
            let items = accessibilityItems()
            let slider = try XCTUnwrap(items.first { $0.role == kAXSliderRole as String }, "\(context.caption): no slider in \(items.map(\.role))")
            let before = tint
            perform(kAXIncrementAction as String, on: slider.element)
            XCTAssertGreaterThan(tint, before, "\(context.caption): the slider's increment moves Tint length")

            // The title menu and the pop-up row are native menu buttons:
            // VoiceOver sees a menu button that can be pressed.
            let menus = items.filter { $0.role == kAXPopUpButtonRole as String || $0.role == kAXMenuButtonRole as String }
            XCTAssertGreaterThanOrEqual(menus.count, 2, "\(context.caption): menus are not menu buttons: \(items.map(\.role))")
            for menu in menus {
                XCTAssertTrue(menu.actions.contains(kAXPressAction as String) || menu.actions.contains("AXShowMenu"),
                              "\(context.caption): a menu button VoiceOver cannot press: \(menu.actions)")
            }
            // Whether they open depends on activation here: the unit-test
            // host can never be the active app, and on the macOS 26 CI
            // runner the menus did not open in it (they do on macOS 27).
            // So: press each one and wait (bounded) for the system
            // menu to begin tracking; when it does, its items must be
            // right. Opening a menu and choosing an item is proved in the
            // running, activated app by AtticNativeMenuUITests on every
            // supported macOS.
            let opened = openMenus(menus)
            // CI diagnostic: how many menus opened in this host on this OS.
            print("ATTIC_HOSTED_MENUS_OPENED \(opened.count)/\(menus.count) · \(context.caption) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
            if !opened.isEmpty {
                let titles = opened.flatMap { $0 }
                XCTAssertTrue(titles.contains("Duplicate") || titles.contains("Glass"), "\(context.caption): a menu opened without its items: \(opened)")
                if opened.count == menus.count {
                    XCTAssertTrue(titles.contains("Duplicate"), "\(context.caption): the title menu's commands: \(opened)")
                    XCTAssertTrue(titles.contains("Glass"), "\(context.caption): the pop-up row's choices: \(opened)")
                }
            } else {
                XCTContext.runActivity(named: "Menus did not open in the inactive unit-test host (\(ProcessInfo.processInfo.operatingSystemVersionString)); AtticNativeMenuUITests covers opening") { _ in }
            }

            // What the field draws: the placeholder meets the text rule on the bar.
            let (bitmap, scale) = try snapshot(hosting)
            let field = try XCTUnwrap(all.first { $0 is NSTextField })
            let frame = field.convert(field.bounds, to: hosting)
            let flipped = CGRect(x: frame.minX, y: hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            let tokens = context.tokens
            let face = tokens.raised.face.over(tokens.controlBase)
            let glyph = try XCTUnwrap(bitmap.glyphContrast(in: flipped, background: face, scale: scale), "The placeholder drew nothing")
            let floor = AtticSurfaceModel.floor(for: .placeholder, kind: context.effectiveSurface, increaseContrast: context.increaseContrast)
            XCTAssertGreaterThanOrEqual(glyph.ratio + AtticAppearanceCheck.glyphTolerance, floor, "\(context.caption): hosted placeholder \(glyph.ink) on \(face)")

            // The hosted add bar keeps its token height.
            XCTAssertEqual(NSHostingView(rootView: AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: {}).atticDesign(context)).fittingSize.height, AtticControlSize.addBarHeight, accuracy: 0.5)

            // One window at a time: the accessibility walk covers every window.
            for window in windows { window.orderOut(nil); window.close() }
            windows.removeAll()
        }
    }

    // MARK: Keyboard

    /// Tab moves keyboard focus from row to row; the focused row draws the
    /// 2 pt accent ring (and only it), and answers the task keys with
    /// distinct commands.
    func testTaskRowTakesKeyboardFocusAndAnswersTheTaskKeys() throws {
        var fired: [String] = []
        func actions(_ row: String) -> AtticTaskActions {
            AtticTaskActions(
                advance: { fired.append("\(row) advance") }, start: { fired.append("\(row) start") },
                complete: { fired.append("\(row) complete") }, openPage: { fired.append("\(row) open") },
                moveToBacklog: { fired.append("\(row) backlog") }, delete: { fired.append("\(row) delete") }
            )
        }
        // A palette with a coloured accent, so the ring is unmistakable.
        let context = AtticDesignContext(mode: .light, palette: .electricBlue)
        let rows = VStack(spacing: 0) {
            AtticTaskRow(model: .init(title: "Email beta testers", priority: .medium), actions: actions("A"), onToggleExpanded: {})
            AtticTaskRow(model: .init(title: "Book dentist"), actions: actions("B"), onToggleExpanded: {})
        }
        let (window, hosting) = host(rows.padding(.vertical, 8), size: CGSize(width: 320, height: 80), context: context, key: true)
        XCTAssertTrue(window.isKeyWindow, "Keyboard focus needs a key window")

        /// Whether row `index` shows the ring (read 3 pt outside its highlight).
        func ringShown(_ index: Int) throws -> Bool {
            let (bitmap, scale) = try snapshot(hosting)
            let x = AtticLayout.rowHighlightInset - AtticRingMetrics.gap - AtticRingMetrics.width / 2
            let y = 8 + CGFloat(index) * AtticLayout.rowPitch + 1 + AtticLayout.rowHighlightHeight / 2
            let pixel = try XCTUnwrap(bitmap.colour(atX: x, y: y, scale: scale))
            return pixel.themeColor.contrastRatio(with: context.tokens.ink(.accent).themeColor) < 1.25
        }
        // The rows are in the window's key-view loop: moving to the next key
        // view (what Tab does; for views that aren't text fields macOS
        // routes Tab there when Full Keyboard Access is on, which this test
        // must not change) moves focus row to row, and the ring moves with it.
        let start = try ringShown(0) ? 0 : 1
        XCTAssertNotEqual(try ringShown(0), try ringShown(1), "Exactly one row shows the ring")
        window.selectNextKeyView(nil)
        spin()
        XCTAssertTrue(try ringShown(1 - start), "The next key view is the next row, and it draws the ring")
        XCTAssertFalse(try ringShown(start), "The ring leaves the row that lost focus")
        if start == 1 {
            window.selectNextKeyView(nil)
            spin()
        }
        XCTAssertTrue(try ringShown(1))
        window.selectPreviousKeyView(nil)
        spin()
        XCTAssertTrue(try ringShown(0), "Shift-Tab's action moves focus back")
        window.selectNextKeyView(nil)
        spin()
        XCTAssertTrue(try ringShown(1))
        XCTAssertEqual(fired, [], "Moving focus fires nothing")

        // Real key events reach the focused row, and only it.
        key(window, " ", code: 49)
        key(window, "\u{A0}", code: 49, modifiers: .option, ignoring: " ")
        key(window, "\r", code: 36, modifiers: .command)
        key(window, "b", code: 11, modifiers: .command)
        key(window, "\u{7F}", code: 51)
        XCTAssertEqual(fired, ["B advance", "B complete", "B open", "B backlog", "B delete"])
    }

    /// A task card takes keyboard focus and draws the ring around its tile shape.
    func testTaskCardTakesKeyboardFocus() throws {
        var fired: [String] = []
        let actions = AtticTaskActions(
            advance: { fired.append("advance") }, start: {}, complete: { fired.append("complete") },
            openPage: { fired.append("open") }, moveToBacklog: {}, delete: {}
        )
        let context = AtticDesignContext(mode: .light, palette: .electricBlue)
        let card = AtticTaskCard(
            model: .init(title: "Go to the appointment", priority: .high), actions: actions,
            cardActions: .init(toggleExpanded: {}, toggleSubtask: { _ in }, addSubtask: {}, openInTasks: {})
        )
        let (window, hosting) = host(card.padding(12), size: CGSize(width: 320, height: 56), context: context, key: true)
        window.selectNextKeyView(nil)
        spin()
        let (bitmap, scale) = try snapshot(hosting)
        let pixel = try XCTUnwrap(bitmap.colour(atX: 12 - 3, y: 28, scale: scale))
        XCTAssertLessThan(pixel.themeColor.contrastRatio(with: context.tokens.ink(.accent).themeColor), 1.25, "Tab focuses the card and draws the ring")
        key(window, " ", code: 49)
        key(window, "\u{A0}", code: 49, modifiers: .option, ignoring: " ")
        key(window, "\r", code: 36, modifiers: .command)
        key(window, "\u{7F}", code: 51)
        XCTAssertEqual(fired, ["advance", "complete", "open"], "Cards take no list commands (Delete)")
    }

    // MARK: VoiceOver

    /// An element as an assistive app (VoiceOver) sees it, through the
    /// Accessibility API (the same calls VoiceOver makes; in-process they
    /// are answered synchronously on this, the main, thread).
    private struct AXItem {
        let element: AXUIElement
        let role: String
        let description: String
        let actions: [String]
    }

    private func accessibilityItems() -> [AXItem] {
        var items: [AXItem] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 16 else { return }
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            items.append(AXItem(element: element, role: role as? String ?? "", description: description as? String ?? "", actions: (actions as? [String]) ?? []))
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(AXUIElementCreateApplication(getpid()), depth: 0)
        return items
    }

    /// Custom actions reach clients as "Name:Start\nTarget:…"; the name is
    /// what VoiceOver reads.
    private func actionName(_ raw: String) -> String {
        guard raw.hasPrefix("Name:") else { return raw }
        return String(raw.dropFirst(5).prefix { $0 != "\n" })
    }

    /// Presses each menu button through the Accessibility API (AXPress, or
    /// AXShowMenu when that is what it offers) and waits on an expectation
    /// for the system menu to begin tracking, bounded, then closes it.
    /// Returns the items of every menu that opened.
    private func openMenus(_ menus: [AXItem]) -> [[String]] {
        var opened: [[String]] = []
        for menu in menus {
            let began = expectation(description: "menu began tracking")
            began.assertForOverFulfill = false
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard let tracked = note.object as? NSMenu else { return }
                opened.append(tracked.items.map(\.title))
                began.fulfill()
                DispatchQueue.main.async { tracked.cancelTracking() }
            }
            let action = menu.actions.contains("AXShowMenu") ? "AXShowMenu" : kAXPressAction as String
            AXUIElementPerformAction(menu.element, action as CFString)
            let result = XCTWaiter().wait(for: [began], timeout: 3)
            NotificationCenter.default.removeObserver(observer)
            if result != .completed { continue }
            spin(0.1)
        }
        return opened
    }

    private func perform(_ raw: String, on element: AXUIElement) {
        AXUIElementPerformAction(element, raw as CFString)
        spin(0.05)
    }

    func testTaskRowOffersTheSpecifiedVoiceOverActions() throws {
        var fired: [String] = []
        let actions = AtticTaskActions(
            advance: { fired.append("advance") }, start: { fired.append("start") },
            complete: { fired.append("complete") }, openPage: { fired.append("open") },
            moveToBacklog: { fired.append("backlog") }, delete: { fired.append("delete") }
        )
        let row = AtticTaskRow(
            model: .init(title: "Email beta testers", priority: .high, due: .init(text: "Friday", isUrgent: false), tags: ["launch"], subtasks: (1, 3)),
            actions: actions, onToggleExpanded: { fired.append("expand") }
        )
        _ = host(row, size: CGSize(width: 320, height: 44))
        let item = try XCTUnwrap(
            accessibilityItems().first { $0.description.hasPrefix("Email beta testers") },
            "The row is one VoiceOver element named by its task"
        )
        XCTAssertEqual(item.description, "Email beta testers, to do, high priority, due Friday, tagged launch, 1 of 3 subtasks")
        let names = item.actions.map(actionName)
        for name in ["Start", "Complete", "Open page", "Move to Backlog", "Delete", "Show subtasks"] {
            XCTAssertTrue(names.contains(name), "Missing VoiceOver action \(name): \(names)")
        }
        for (name, expected) in [("Start", "start"), ("Complete", "complete"), ("Open page", "open"), ("Move to Backlog", "backlog"), ("Delete", "delete"), ("Show subtasks", "expand")] {
            fired.removeAll()
            let raw = try XCTUnwrap(item.actions.first { actionName($0) == name })
            perform(raw, on: item.element)
            XCTAssertEqual(fired, [expected], "VoiceOver \(name) fires its own callback")
        }
    }

    func testTaskCardOffersExpandAndTheTaskActions() throws {
        var fired: [String] = []
        let actions = AtticTaskActions(
            advance: { fired.append("advance") }, start: { fired.append("start") },
            complete: { fired.append("complete") }, openPage: { fired.append("open") },
            moveToBacklog: { fired.append("backlog") }, delete: { fired.append("delete") }
        )
        let card = AtticTaskCard(
            model: .init(title: "Go to the appointment", priority: .high), container: "note Launch sync", actions: actions,
            cardActions: .init(toggleExpanded: { fired.append("expand") }, toggleSubtask: { _ in }, addSubtask: {}, openInTasks: { fired.append("tasks") })
        )
        _ = host(card.padding(12), size: CGSize(width: 320, height: 56))
        let item = try XCTUnwrap(accessibilityItems().first { $0.description.hasPrefix("Go to the appointment") })
        XCTAssertTrue(item.description.hasSuffix("card, in note Launch sync"), item.description)
        let names = item.actions.map(actionName)
        for name in ["Expand", "Start", "Complete", "Open page", "Open in Tasks"] {
            XCTAssertTrue(names.contains(name), "Missing VoiceOver action \(name): \(names)")
        }
        fired.removeAll()
        perform(try XCTUnwrap(item.actions.first { actionName($0) == "Expand" }), on: item.element)
        XCTAssertEqual(fired, ["expand"])
    }
}

/// A window that behaves as the key window although the test host is never
/// the active app (keyboard focus and Tab need a key window).
private final class KeyTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
