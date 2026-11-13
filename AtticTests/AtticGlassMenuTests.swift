import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Draft C's glass menus and cards (owner, 2026-10-23: "the menus look
/// good"): native-menu parity for the custom glass menus (keyboard,
/// VoiceOver, submenus, placement) and the date card's new keys, field and
/// Clear Date.
@MainActor
final class AtticGlassMenuTests: XCTestCase {
    private var ran: [String] = []

    override func setUp() {
        super.setUp()
        ran = []
        AtticGlassMenu.ordersCardsFront = false
    }

    override func tearDown() {
        AtticGlassMenu.ordersCardsFront = true
        AtticGlassMenu.testDriver = nil
        super.tearDown()
    }

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// Complete · Disabled · Date ▸ (Today, Tomorrow) │ Tags ▸ │ Delete.
    private func commands() -> [AtticMenuCommand] {
        [
            AtticMenuCommand("Complete", systemImage: "checkmark.circle", shortcut: KeyboardShortcut("k", modifiers: .command)) { self.ran.append("Complete") },
            AtticMenuCommand("Disabled", systemImage: "nosign", isDisabled: true) { self.ran.append("Disabled") },
            .submenu("Date", systemImage: "calendar", [
                .header("Date"),
                AtticMenuCommand(verbatim: "Today", detail: "Fri") { self.ran.append("Today") },
                AtticMenuCommand(verbatim: "Tomorrow", detail: "Sat") { self.ran.append("Tomorrow") },
            ]),
            .submenu("Tags", systemImage: "tag", startsSection: true, [
                AtticMenuCommand(verbatim: "#home", state: .on) { self.ran.append("#home") },
            ]),
            AtticMenuCommand("Delete", systemImage: "trash", isDestructive: true, startsSection: true) { self.ran.append("Delete") },
        ]
    }

    private func open(_ commands: [AtticMenuCommand], at point: CGPoint = CGPoint(x: 400, y: 600)) -> AtticGlassMenu {
        let menu = AtticGlassMenu(commands, appearance: NSAppearance(named: .aqua), opener: nil)
        menu.open(.point(point), visible: screen, source: nil)
        return menu
    }

    /// Keep the card's logical screen coordinates aligned with its window's
    /// coordinates in the invisible test host. The host moves onscreen
    /// windows a million points away without changing the menu's card frame.
    /// A fully offscreen virtual screen avoids that remapping in either host.
    private func openForAccessibilityGeometry(_ commands: [AtticMenuCommand]) -> AtticGlassMenu {
        let testScreen = screen.offsetBy(dx: -2_000_000, dy: 0)
        let point = CGPoint(x: testScreen.minX + 400, y: testScreen.minY + 600)
        let menu = AtticGlassMenu(commands, appearance: NSAppearance(named: .aqua), opener: nil)
        menu.open(.point(point), visible: testScreen, source: nil)
        return menu
    }

    /// A page can replace its SwiftUI anchor in the same turn as the click
    /// (a first click after reveal or a menu switch). The deferred request
    /// belongs to the source window, even if that particular view leaves.
    func testDeferredOpenSurvivesTheAnchorBeingRebuilt() {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
        window.contentView = root
        let anchor = NSView(frame: NSRect(x: 210, y: 220, width: 32, height: 32))
        root.addSubview(anchor)
        var opened = 0
        AtticGlassMenu.testDriver = { _ in opened += 1 }
        AtticGlassMenu.popUpLater([AtticMenuCommand(verbatim: "Options") {}], in: anchor,
                                 placement: .below(anchor.bounds), opener: nil)
        anchor.removeFromSuperview() // SwiftUI replaced the button during its own action.
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(opened, 1, "a menu request does not vanish with its presenting view")
        window.contentView = nil
        window.close()
    }

    func testContextRequestSurvivesItsAnchorBeingRebuilt() throws {
        let window = NSWindow(contentRect: NSRect(x: -2_000_000, y: 0, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = AtticContextMenuAnchor.AnchorView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        anchor.build = { [AtticMenuCommand(verbatim: "Context options") {}] }
        window.contentView?.addSubview(anchor)
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 720, clickCount: 1, pressure: 1))
        var opened: [String] = []
        AtticGlassMenu.testDriver = { opened.append($0.commands[0].title) }
        _ = AtticContextMenus.route(press)
        anchor.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(opened, ["Context options"], "the native context press keeps its window and producer")
    }

    /// The first press after a panel/layout rebuild must still open when
    /// SwiftUI has detached the represented anchor before dispatching it.
    /// This is shared by the top-row ⋯ and the menu buttons in other pages.
    func testDetachedMenuButtonAnchorOpensUsingItsLastWindowLocation() {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
        window.contentView = root
        let holder = AtticMenuAnchor.Holder()
        let anchor = AtticMenuAnchor.AnchorView(frame: NSRect(x: 210, y: 220, width: 32, height: 32))
        anchor.holder = holder
        root.addSubview(anchor)
        holder.remember(anchor)
        anchor.removeFromSuperview()
        XCTAssertNil(anchor.window)
        var opened: [String] = []
        AtticGlassMenu.testDriver = { opened.append($0.commands[0].title) }
        holder.open([AtticMenuCommand(verbatim: "⋯ options") {}], event: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(opened, ["⋯ options"], "the click survives the represented NSView being removed")
    }

    /// A first click can arrive before SwiftUI attaches the represented
    /// anchor to the newly shown panel; that click itself names the window.
    func testFirstMenuClickBeforeAnchorAttachesUsesTheClickWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
        let holder = AtticMenuAnchor.Holder()
        XCTAssertNil(holder.view)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
            location: CGPoint(x: 260, y: 250), modifierFlags: [], timestamp: 52,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 813, clickCount: 1, pressure: 1))
        var opened = 0
        AtticGlassMenu.testDriver = { _ in opened += 1 }
        holder.open([AtticMenuCommand(verbatim: "First-click options") {}], event: click)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(opened, 1, "a fresh panel's first menu click does not require a prior layout pass")
    }

    /// Only the newest pending menu should win if a second trigger is
    /// clicked repeatedly before a first menu's tracking has unwound.
    func testRapidMenuRequestsDuringTrackingAlwaysShowTheLatestClick() {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 30, y: 40, width: 32, height: 32))
        window.contentView?.addSubview(anchor)
        var opened: [String] = []
        AtticGlassMenu.testDriver = { menu in
            opened.append(menu.commands[0].title)
            if opened.count == 1 {
                for count in 0..<12 {
                    AtticGlassMenu.popUpLater([AtticMenuCommand(verbatim: "Rapid \(count)") {}], in: anchor,
                                             placement: .below(anchor.bounds), opener: nil)
                }
            }
        }
        AtticGlassMenu.popUp([AtticMenuCommand(verbatim: "First") {}], in: anchor,
                             placement: .below(anchor.bounds), opener: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(opened, ["First", "Rapid 11"], "repeated clicks never leave the menu control inert")
    }

    func testRapidRequestsBeforeTrackingCoalesceToTheLatestMenu() {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 30, y: 40, width: 32, height: 32))
        window.contentView?.addSubview(anchor)
        var opened: [String] = []
        AtticGlassMenu.testDriver = { opened.append($0.commands[0].title) }
        for index in 0..<12 {
            AtticGlassMenu.popUpLater([AtticMenuCommand(verbatim: "Rapid \(index)") {}], in: anchor,
                                     placement: .below(anchor.bounds), opener: nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(opened, ["Rapid 11"], "obsolete requests never reopen over the newest menu")
    }

    /// An AX menu action or another command can request a menu while one is
    /// still tracking. The latest request must open after tracking ends.
    func testMenuRequestedDuringAnotherMenusTrackingIsNotDropped() {
        let window = NSWindow(contentRect: NSRect(x: -7000, y: -7000, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 32, height: 32))
        window.contentView?.addSubview(anchor)
        var opened: [String] = []
        AtticGlassMenu.testDriver = { menu in
            opened.append(menu.commands[0].title)
            if menu.commands[0].title == "First" {
                AtticGlassMenu.popUpLater([AtticMenuCommand(verbatim: "Second") {}], in: anchor,
                                         placement: .below(anchor.bounds), opener: nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            }
        }
        AtticGlassMenu.popUp([AtticMenuCommand(verbatim: "First") {}], in: anchor,
                            placement: .below(anchor.bounds), opener: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(opened, ["First", "Second"])
    }

    /// Settings' choice rows and the other menu controls share the
    /// macOS 27 AXMenuButton implementation, preserving the selected value
    /// as well as the visible name and both keyboard/VoiceOver actions.
    func testMenuButtonAccessibilityKeepsItsNameValueAndActions() {
        let button = AtticMenuButtonAccessibility.ButtonView(frame: .zero)
        button.menuLabel = "Surface"
        button.menuValue = "Solid"
        var presses = 0
        button.open = { _ in presses += 1 }
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .menuButton)
        XCTAssertEqual(button.accessibilityLabel(), "Surface")
        XCTAssertEqual(button.accessibilityTitle(), "Surface")
        XCTAssertEqual(button.accessibilityValue() as? String, "Solid")
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(button.accessibilityPerformShowMenu())
        XCTAssertEqual(presses, 2)
    }

    /// A second ⋯ is a new click, even while the first menu's nested event
    /// loop is running. Losing the mouse-down left its SwiftUI button with a
    /// mouse-up alone, so nothing opened.
    func testOutsideClickReachesTheNextMenuTrigger() throws {
        let menu = openForAccessibilityGeometry([AtticMenuCommand(verbatim: "First") {}])
        defer { menu.close(animated: false) }
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let holder = AtticMenuAnchor.Holder()
        let trigger = AtticMenuAnchor.AnchorView(frame: NSRect(x: 8, y: 8, width: 32, height: 32))
        trigger.holder = holder
        window.contentView?.addSubview(trigger)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 24, y: 24),
            modifierFlags: [], timestamp: 120, windowNumber: window.windowNumber, context: nil,
            eventNumber: 9013, clickCount: 1, pressure: 1))
        menu.handle(down)
        XCTAssertFalse(menu.isOpen, "the old menu closes before the new control gets the click")
        let delivered = NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(0.05),
                                        inMode: .default, dequeue: true)
        XCTAssertEqual(delivered?.eventNumber, down.eventNumber, "the new ⋯ receives its entire press")
    }

    func testCatchupR2DismissingClickDoesNotReplayToAnOrdinaryButton() throws {
        let window = NSWindow(contentRect: NSRect(x: -2_000_000, y: 0, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 80, height: 32))
        window.contentView?.addSubview(button)
        for (index, kind) in [NSEvent.EventType.leftMouseDown, .rightMouseDown].enumerated() {
            let menu = openForAccessibilityGeometry([AtticMenuCommand(verbatim: "Options") {}])
            defer { menu.close(animated: false) }
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: CGPoint(x: 40, y: 30),
                modifierFlags: [], timestamp: 120, windowNumber: window.windowNumber, context: nil,
                eventNumber: 9020 + index, clickCount: 1, pressure: 1))
            menu.handle(down)
            XCTAssertFalse(menu.isOpen)
            let replayed = NSApp.nextEvent(matching: kind == .leftMouseDown ? .leftMouseDown : .rightMouseDown,
                until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            XCTAssertNil(replayed, "The click that dismisses a menu must not activate an ordinary control")
        }
    }

    func testCatchupR2OnlyVisibleMenuTriggersReceiveTheDismissingPress() throws {
        let window = NSWindow(contentRect: NSRect(x: -2_000_000, y: 0, width: 320, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let trigger = AtticMenuAnchor.AnchorView(frame: NSRect(x: 20, y: 20, width: 32, height: 32))
        window.contentView?.addSubview(trigger)
        let context = AtticContextMenuAnchor.AnchorView(frame: trigger.frame)
        context.build = { [AtticMenuCommand(verbatim: "Context") {}] }
        window.contentView?.addSubview(context)
        for (index, mode) in ["button", "hidden", "context-only", "secondary", "control-click", "native-text"].enumerated() {
            trigger.isHidden = mode == "hidden"
            trigger.isMenuTrigger = mode == "button" || mode == "hidden"
            var text: NSTextView?
            if mode == "native-text" {
                let editor = NSTextView(frame: trigger.frame)
                editor.isEditable = true
                window.contentView?.addSubview(editor)
                text = editor
            }
            defer { text?.removeFromSuperview() }
            let secondary = mode == "secondary" || mode == "native-text"
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: secondary ? .rightMouseDown : .leftMouseDown,
                location: CGPoint(x: 30, y: 30), modifierFlags: mode == "control-click" ? .control : [],
                timestamp: 120, windowNumber: window.windowNumber, context: nil,
                eventNumber: 9040 + index, clickCount: 1, pressure: 1))
            let menu = openForAccessibilityGeometry([AtticMenuCommand(verbatim: "First") {}])
            menu.handle(down)
            XCTAssertFalse(menu.isOpen)
            let delivered = NSApp.nextEvent(matching: secondary ? .rightMouseDown : .leftMouseDown,
                until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            let opensMenu = ["button", "secondary", "control-click"].contains(mode)
            XCTAssertEqual(delivered?.eventNumber, opensMenu ? down.eventNumber : nil, mode)
        }
    }

    /// Seeded interaction sequences pin the state invariants across rapid
    /// keyboard navigation, submenu opening, closing and reopening.
    func testSeededMenuOpeningAndNavigationSequences() {
        let keys: [UInt16] = [125, 126, 124, 123, 53, 36, 49, 115, 119]
        for seed in [UInt64(0xB17), 0x130B, 0xC0DE, 0xF150, 0xCAFE] {
            var state = seed
            var menu = openForAccessibilityGeometry(commands())
            for step in 0..<440 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                if !menu.isOpen { menu = openForAccessibilityGeometry(commands()) }
                menu.handle(key(keys[Int((state >> 32) % UInt64(keys.count))], time: Double(step)))
                guard menu.isOpen else { continue }
                XCTAssertFalse(menu.cards.isEmpty, "seed \(seed), step \(step)")
                XCTAssertTrue(menu.cards.indices.contains(menu.focus), "seed \(seed), step \(step)")
                XCTAssertLessThanOrEqual(menu.cards.count, 3, "seed \(seed), step \(step)")
                for card in menu.cards {
                    if let selected = card.highlighted {
                        XCTAssertTrue(card.selectableIndices.contains(selected), "seed \(seed), step \(step)")
                    }
                    XCTAssertGreaterThanOrEqual(card.frame.width, AtticMenuMetrics.minWidth,
                                                "seed \(seed), step \(step)")
                }
            }
            menu.close(animated: false)
        }
    }

    private func key(_ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], time: TimeInterval = 1) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func titleOfHighlight(_ menu: AtticGlassMenu, card: Int) -> String? {
        guard let row = menu.cards[card].highlighted, case let .item(command) = menu.cards[card].entries[row].kind else { return nil }
        return command.title
    }

    private func center(of row: Int, in card: AtticGlassMenuCard) -> NSPoint {
        let frame = card.frame
        let entry = card.entries[row].frame
        return NSPoint(x: frame.minX + entry.midX, y: frame.maxY - entry.midY)
    }

    private func row(titled title: String, in card: AtticGlassMenuCard) -> Int {
        card.entries.firstIndex { if case let .item(command) = $0.kind { return command.title == title } else { return false } }!
    }

    func testCommandMenuOpenersExposeExactAccessibleNames() throws {
        let labels = ["Add a task, note or file", "Alignment, Left", "Chats"]
        let command = [AtticMenuCommand(verbatim: "Example") {}]
        let root = VStack(spacing: 10) {
            AtticCommandMenu(commands: command, accessibilityLabel: labels[0]) { Image(systemName: "plus") }
            AtticCommandMenu(commands: command, accessibilityLabel: labels[1]) { Text("Left") }
            AtticCommandMenu(commands: command, accessibilityLabel: labels[2]) { Image(systemName: "clock") }
        }
        .frame(width: 320, height: 140)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 320, height: 140),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var seen = Set<ObjectIdentifier>()
        var named = [String]()
        var openers = [AnyObject]()
        func walk(_ node: AnyObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            if node.accessibilityRole?() == .menuButton {
                let label = node.accessibilityLabel?() ?? ""
                XCTAssertFalse(label.isEmpty, "Every AXMenuButton needs a label")
                named.append(label)
                openers.append(node)
            }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject) }
        }
        walk(try XCTUnwrap(window.contentView))
        XCTAssertEqual(named.count, labels.count, "Every command menu has one accessible opener")
        XCTAssertEqual(Set(named), Set(labels), "icon-only, text and history menu openers are named")

        // The AX representation can be detached from the window. VoiceOver's
        // Show Menu action still needs to open from the rendered control.
        var opened = 0
        AtticGlassMenu.testDriver = { menu in
            opened += 1
            XCTAssertEqual(menu.commands.map(\.title), ["Example"])
        }
        let opener = try XCTUnwrap(openers.first as? NSView)
        XCTAssertTrue(opener.accessibilityPerformShowMenu())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(opened, 1, "Show Menu opens the real menu from its on-window anchor")
        XCTAssertTrue(opener.accessibilityPerformPress())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(opened, 2, "Press also opens the real menu")
    }

    // MARK: Layout

    func testTheLayoutIsLoamsRowsSeparatorsAndTitlesWithShortcutsAtTheEnd() {
        let layout = AtticGlassMenuCard.layout(commands())
        let kinds = layout.entries.map { entry -> String in
            switch entry.kind {
            case let .item(command): command.title
            case let .header(title): "[\(title)]"
            case .separator: "—"
            }
        }
        XCTAssertEqual(kinds, ["Complete", "Disabled", "Date", "—", "Tags", "—", "Delete"], "a separator starts each section")
        XCTAssertEqual(layout.entries[0].frame.height, 28, "28 pt rows (Menu look picks B, 2026-11-13)")
        XCTAssertEqual(layout.entries[0].frame.minY, 6, "Loam: 6 pt padding")
        XCTAssertEqual(layout.entries[3].frame.height, 11, "a hairline on an 11 pt band")
        XCTAssertEqual(layout.size.width, 200, "at least 200 pt (Menu look picks B)")
        let submenu = AtticGlassMenuCard.layout(commands()[2].children)
        XCTAssertEqual(submenu.entries.first.map { if case .header = $0.kind { true } else { false } }, true, "a titled section's header")
        XCTAssertEqual(submenu.entries.first?.frame.height, 22, "groups C: the heading closer (2026-11-13)")
        // The shortcut sits at the trailing edge (Loam's), and takes room.
        let plain = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title, longer still") {}])
        let hinted = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title, longer still",
                                                                 shortcut: KeyboardShortcut("d", modifiers: [.command, .option])) {}])
        XCTAssertGreaterThan(hinted.size.width, plain.size.width, "the shortcut is drawn at the end")
        XCTAssertEqual(AtticMenuCommand(verbatim: "Info", shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) {}.glassShortcut, "⇧⌘I")
        XCTAssertNil(AtticMenuCommand(verbatim: "Edit", shortcut: KeyboardShortcut(.return, modifiers: [])) {}.glassShortcut,
                     "a bare key is the list's, not drawn")
    }

    private static func systemRed(dark: Bool) -> NSColor {
        var red = NSColor.systemRed
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            red = NSColor.systemRed.usingColorSpace(.sRGB) ?? red
        }
        return red
    }

    /// The card is the panel's material (owner, 12 Nov), so its inks are
    /// the panel's: see-through exactly when the panel is (whatever the
    /// controls setting), and on a solid card the greys are opaque and keep
    /// their floor against the panel's own base.
    func testMenuSecondaryInksAreThePanelsOnItsMaterial() throws {
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted, .solid] {
                for controls in AtticControlMaterial.allCases {
                    for reduced in [false, true] {
                        for contrast in [false, true] {
                            let style = AtticGlassMenuStyle(design: AtticDesignContext(mode: mode, surface: surface,
                                increaseContrast: contrast, reduceTransparency: reduced, controls: controls))
                            XCTAssertEqual(style.isSeeThrough, surface != .solid && !reduced, "\(surface), \(controls), RT=\(reduced)")
                            guard !style.isSeeThrough else { continue } // Real glass is an on-screen gate.
                            let floor = contrast ? 4.5 : 3.0
                            // Disabled rows are the title at 30 % (review #6), below any
                            // floor by design: `testDisabledInkIsTheTitleAtThirtyPercent`.
                            // Section headers are the title at 45 %, as the system menu
                            // draws them (owner, 12 Nov: version 3 of
                            // menu-versions-drafts.html, the look accepted with the grey
                            // hover); Increase Contrast keeps the opaque token below.
                            if !contrast {
                                XCTAssertEqual(style.header, style.title.withAlphaComponent(0.45), "\(surface), \(controls), \(mode)")
                            }
                            for ink in contrast ? [style.detail, style.header] : [style.detail] {
                                let colour = try XCTUnwrap(ink.usingColorSpace(.sRGB))
                                let rgba = AtticRGBA(red: colour.redComponent, green: colour.greenComponent,
                                    blue: colour.blueComponent, alpha: colour.alphaComponent)
                                XCTAssertEqual(rgba.alpha, 1, "opaque card on \(surface), \(controls), \(mode)")
                                XCTAssertGreaterThanOrEqual(rgba.contrast(on: style.tokens.panel.base), floor,
                                    "the panel's base under the card: \(surface), \(controls), \(mode), IC=\(contrast)")
                            }
                            for colour in [style.tokens.tagInk(.pink), style.tokens.ink(.priorityMark)] {
                                XCTAssertEqual(style.colourInk(colour), colour, "no vivid on a solid card")
                            }
                            XCTAssertEqual(style.destructive, Self.systemRed(dark: mode == .dark),
                                "Delete is the system red (Menu look picks B, 2026-11-13)")
                        }
                    }
                }
            }
        }
    }

    /// Accepted 2026-11-12 (evening) · Menus: version 3 on the system
    /// menu's Liquid Glass, with the grey hover. On Glass and Frosted every
    /// command card is AppKit's own system glass (`NSGlassEffectView`,
    /// `.regular`, untinted, at the card's radius) under its rows, drawn in
    /// the active look as the system menu's window draws it, with nothing
    /// over it, no drawn outline and the measured shadow. Solid and Reduce
    /// Transparency keep the opaque card with no glass. The glass's own
    /// colours are the OS's and vary by release, so they are not pinned.
    func testEveryMenuCardWearsTheSystemMenusLiquidGlass() throws {
        let saved = AtticGlassMenu.design
        defer { AtticGlassMenu.design = saved }
        for surface in PanelSurfaceStyle.allCases {
            for reduced in [false, true] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    AtticGlassMenu.design = AtticDesignContext(mode: .light, surface: surface, reduceTransparency: reduced)
                    let menu = AtticGlassMenu(commands(), appearance: NSAppearance(named: appearance), opener: nil)
                    menu.open(.point(CGPoint(x: 400, y: 600)), visible: screen, source: nil)
                    defer { menu.close(animated: false) }
                    let label = "\(surface), reduced \(reduced), \(appearance.rawValue)"
                    let style = menu.style
                    let window = try XCTUnwrap(menu.cards.first?.window, label)
                    let root = try XCTUnwrap(window.cardView, label)
                    let glass = root.subviews.compactMap { $0 as? NSGlassEffectView }
                    XCTAssertEqual(style.isSeeThrough, surface != .solid && !reduced, label)
                    if style.isSeeThrough {
                        XCTAssertEqual(glass.count, 1, "one system glass: \(label)")
                        let face = try XCTUnwrap(glass.first, label)
                        XCTAssertTrue(root.subviews.first === face, "the glass is under the face and rows: \(label)")
                        XCTAssertEqual(face.style, .regular, label)
                        XCTAssertNil(face.tintColor, "untinted: \(label)")
                        XCTAssertEqual(face.cornerRadius, AtticGlassMenuShape.radius, label)
                        XCTAssertEqual(face.frame, root.bounds, label)
                        XCTAssertEqual(style.rim.alphaComponent, 0, "no drawn outline: \(label)")
                        XCTAssertEqual(AtticMenuLook.lift(dark: style.dark).alpha, 0, "nothing over the glass: \(label)")
                    } else {
                        XCTAssertTrue(glass.isEmpty, "the opaque card has no glass: \(label)")
                    }
                    // The active look: the card's window says it is active,
                    // as `NSPopupMenuWindow` does, and never takes key.
                    XCTAssertTrue(window._hasActiveAppearanceIgnoringKeyFocus(), label)
                    XCTAssertTrue(window._hasActiveControls(), label)
                    XCTAssertFalse(window.canBecomeKey, label)
                    // The measured shadow, outside the card.
                    XCTAssertEqual(window.lift.shadowColor, style.shadow, label)
                    window.lift.layoutSubtreeIfNeeded()
                    let caster = try XCTUnwrap(window.lift.subviews.first?.layer?.sublayers?.first { $0.shadowPath != nil }, label)
                    XCTAssertEqual(caster.shadowRadius, AtticShadows.dropdown.radius, label)
                    XCTAssertEqual(abs(caster.shadowOffset.height), AtticShadows.dropdown.y, label)
                    XCTAssertEqual(Double(caster.shadowOpacity), style.dark ? 0.28 : 0.24, accuracy: 0.001, label)
                }
            }
        }
    }

    func testMenuRowsStayClippedToTheCardWhenTheCardIsShortened() throws {
        let menu = open(commands())
        defer { menu.close(animated: false) }
        let root = try XCTUnwrap(menu.cards.first?.window.cardView)
        root.layoutSubtreeIfNeeded()
        let mask = try XCTUnwrap(root.layer?.mask as? CAShapeLayer)
        let path = try XCTUnwrap(mask.path)
        XCTAssertFalse(path.contains(.zero))
        XCTAssertEqual(path, AtticGlassMenuShape.card.path(in: root.bounds).cgPath,
                       "Loam's continuous 18 pt corners (owner, 11 Nov: the squircle read as tight corners)")
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 4)), "round enough that the corner's inner 4 pt stays outside")
        XCTAssertEqual(path.boundingBoxOfPath, root.bounds)
        root.setFrameSize(CGSize(width: root.bounds.width, height: 90))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(mask.path?.boundingBoxOfPath, root.bounds, "scrolling rows remain within a capped card")
        XCTAssertEqual(AtticGlassMenuShape.radius, 18, "Loam's 18 pt menus (Accepted 2026-11-10)")
        XCTAssertEqual(AtticGlassMenuShape.inset, 6)
        // Accepted 2026-11-13 Corners, measured fix: the sheet's B menu row
        // (24 pt, its corner in a 12 pt box) is 8 pt continuous.
        XCTAssertEqual(AtticMenuMetrics.highlightRadius, 8)
        XCTAssertEqual(AtticGlassMenuShape.rowRadius, 8)
        XCTAssertEqual(AtticGlassMenuShape.rowRadius(height: AtticMenuMetrics.rowHeight), 8, "the 28 pt row keeps the drawn corner")
        XCTAssertEqual(AtticGlassMenuShape.rowRadius(height: 12), 6, "never rounder than half the row")
    }

    // MARK: Content rules (Dropdown content: answers, owner, 2026-10-24)

    private func kinds(_ layout: AtticGlassMenuCard.Layout) -> [String] {
        layout.entries.map { entry -> String in
            switch entry.kind {
            case let .item(command): command.title
            case let .header(title): "[\(title)]"
            case .separator: "—"
            }
        }
    }

    /// Accepted 2026-11-10, minimum 200 pt since the 13 Nov picks: as wide
    /// as the control and at least 200 pt; rows that need more widen it up
    /// to 280 pt, past which they are cut short; a menu that names its
    /// width keeps it, never under 200 pt.
    /// Review #3 (12 Nov): the 0.5 pt hairline, centred on its 11 pt band,
    /// straddled two device pixels at half strength. It sits on the backing
    /// grid: one whole device pixel at 2x, one pixel at 1x.
    func testTheSeparatorHairlineSitsOnTheBackingPixelGrid() {
        let band = NSRect(x: 0, y: 0, width: 204, height: AtticMenuMetrics.separatorHeight)
        for scale: CGFloat in [1, 2, 3] {
            let rect = AtticGlassMenuView.separatorRect(in: band, scale: scale)
            XCTAssertEqual((rect.minY * scale).rounded(), rect.minY * scale, accuracy: 0.0001, "starts on a device pixel at \(scale)x")
            XCTAssertEqual(rect.height * scale, max((AtticHairline.width * scale).rounded(), 1), accuracy: 0.0001,
                           "whole device pixels at \(scale)x")
            XCTAssertEqual(rect.midY, band.midY, accuracy: 0.5 / scale + 0.0001, "still centred on its band")
            XCTAssertEqual(rect.minX, AtticMenuMetrics.separatorInset)
            XCTAssertEqual(rect.maxX, band.width - AtticMenuMetrics.separatorInset)
        }
    }

    /// Review #6 (12 Nov): a disabled row is the title's ink at 30 % (50 %
    /// under Increase Contrast), always lighter than the 45 % headers and
    /// never the shortcuts' grey.
    func testDisabledInkIsTheTitleAtThirtyPercent() throws {
        for mode in AtticDesignContext.Mode.allCases {
            for surface in [PanelSurfaceStyle.glass, .frosted, .solid] {
                for contrast in [false, true] {
                    let style = AtticGlassMenuStyle(design: AtticDesignContext(mode: mode, surface: surface, increaseContrast: contrast))
                    let disabled = try XCTUnwrap(style.disabled.usingColorSpace(.sRGB))
                    let title = try XCTUnwrap(style.title.usingColorSpace(.sRGB))
                    XCTAssertEqual(disabled.redComponent, title.redComponent, accuracy: 0.002, "\(mode) \(surface)")
                    XCTAssertEqual(disabled.greenComponent, title.greenComponent, accuracy: 0.002)
                    XCTAssertEqual(disabled.blueComponent, title.blueComponent, accuracy: 0.002)
                    XCTAssertEqual(disabled.alphaComponent, title.alphaComponent * (contrast ? 0.5 : 0.3), accuracy: 0.002,
                                   "\(mode) \(surface) IC=\(contrast)")
                    XCTAssertNotEqual(style.disabled, style.detail, "not the shortcuts' grey")
                }
            }
        }
    }

    /// Review #7 (12 Nov): icons in the titles' regular weight, 8 pt before
    /// the title.
    func testIconsAreRegularWeightAndEightPointsFromTheTitle() {
        XCTAssertEqual(AtticGlassMenuStyle.iconWeight, .regular)
        XCTAssertEqual(AtticMenuMetrics.columnGap, 8)
        XCTAssertEqual(AtticMenuMetrics.iconSize, 14, "the size stays")
        XCTAssertEqual(AtticMenuMetrics.iconSlot, 20, "the column stays")
    }

    func testMenusAreAtLeast200AndAsWideAsTheirControl() {
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Copy") {}]).size.width, 200)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Copy") {}], minimum: 300).size.width, 300, "as wide as the control")
        let long = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A rather long command title, longer still and more") {}]).size.width
        XCTAssertGreaterThan(long, 200)
        XCTAssertLessThanOrEqual(long, 280)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: String(repeating: "Very long ", count: 12)) {}]).size.width,
                       280, "never wider: the row is cut short")
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Today") {}], width: 184).size.width, 200)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Today") {}], width: 224).size.width, 224)
        // A submenu's card takes its command's width (at least 200 pt).
        let date = AtticMenuCommand.submenu("Date", width: AtticMenuMetrics.dateMenuWidth, [AtticMenuCommand(verbatim: "Today") {}])
        let menu = open([date])
        defer { menu.close(animated: false) }
        menu.handle(key(125))
        menu.handle(key(36, "\r"))
        XCTAssertEqual(menu.cards.count, 2, "Return opens Date ›")
        XCTAssertEqual(menu.cards[1].size.width, 200)
    }

    func testDeclaredWideMenuStillGrowsToFitLongTagsUpTo280() {
        let tag = AtticMenuCommand(verbatim: String(repeating: "Long tag ", count: 12)) {}
        let natural = AtticGlassMenuCard.layout([tag]).size.width
        XCTAssertEqual(natural, 280, "content growth remains capped")
        XCTAssertEqual(AtticGlassMenuCard.layout([tag], width: AtticMenuMetrics.wideWidth).size.width, 280,
                       "a named 224 pt width must not override the measured label")
        XCTAssertEqual(AtticGlassMenuCard.layout([tag], width: 224, minimum: 265).size.width, 280,
                       "minimum, named, control and content widths all participate")
        XCTAssertEqual(AtticGlassMenuCard.layout([tag], width: 300).size.width, 300,
                       "280 pt limits content growth, not a caller's explicit wider width")
    }

    /// Rule 2: one icon family. A choice (a row with a tick state) never
    /// takes a command's icon from the table, so View Options' "Priority"
    /// sort has no flag while Priority › keeps it; a priority's mark sits
    /// in the icon column.
    func testChoicesTakeNoCommandIconAndPriorityMarksSitInTheIconColumn() {
        XCTAssertEqual(AtticMenuSymbols.symbol(for: AtticMenuCommand(verbatim: "Priority") {}), "flag")
        XCTAssertNil(AtticMenuSymbols.symbol(for: AtticMenuCommand(verbatim: "Priority", state: .off) {}), "a sort choice")
        XCTAssertNil(AtticMenuSymbols.symbol(for: .header("Priority")))
        XCTAssertEqual(AtticMenuSymbols.symbol(for: AtticMenuCommand(verbatim: "Tasks", systemImage: "checkmark.circle", state: .on) {}),
                       "checkmark.circle", "a named icon always draws")
        let choices = [AtticMenuCommand(verbatim: "Manual Order", state: .on) {}, AtticMenuCommand(verbatim: "Priority", state: .off) {}]
        XCTAssertFalse(AtticGlassMenuCard.layout(choices).hasIcons, "a choice list without marks has no icon column")
        var low = AtticMenuCommand(verbatim: "Low", state: .off) {}
        low.priority = .low
        XCTAssertTrue(AtticGlassMenuCard.layout([low]).hasIcons, "the mark column")
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons([low, AtticMenuCommand(verbatim: "Copy") {}]), [])
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons([AtticMenuCommand(verbatim: "Unlisted") {}]), ["Unlisted"])
    }

    /// Rule 4: a header row for a group of choices, drawn as a header, not
    /// a greyed command (the tag chip's Colour, History's days).
    func testAHeaderIsAHeaderNotARow() {
        let layout = AtticGlassMenuCard.layout([.header("Colour"), AtticMenuCommand(verbatim: "Yellow", state: .on, swatch: .yellow) {}])
        XCTAssertEqual(kinds(layout), ["[Colour]", "Yellow"])
        XCTAssertEqual(layout.entries.filter(\.isSelectable).count, 1)
    }

    // MARK: Placement

    func testTheMenuFlipsAndMovesToStayOnScreen() {
        let size = CGSize(width: 200, height: 300)
        let free = AtticGlassMenu.rootFrame(size: size, placement: .point(CGPoint(x: 400, y: 600)), visible: screen)
        XCTAssertEqual(free.origin, CGPoint(x: 400, y: 300), "its top-left at the point")
        let right = AtticGlassMenu.rootFrame(size: size, placement: .point(CGPoint(x: 1400, y: 600)), visible: screen)
        XCTAssertEqual(right.maxX, 1400, "at the right edge it opens to the left of the point")
        let low = AtticGlassMenu.rootFrame(size: size, placement: .point(CGPoint(x: 400, y: 100)), visible: screen)
        XCTAssertEqual(low.minY, AtticMenuMetrics.screenMargin, "at the bottom it moves up")
        let button = NSRect(x: 300, y: 80, width: 30, height: 30)
        let flipped = AtticGlassMenu.rootFrame(size: size, placement: .below(button), visible: screen)
        XCTAssertEqual(flipped.minY, button.maxY + AtticMenuMetrics.anchorGap, "no room below a button: it opens above")
        let below = AtticGlassMenu.rootFrame(size: size, placement: .below(NSRect(x: 300, y: 600, width: 30, height: 30)), visible: screen)
        XCTAssertEqual(below.maxY, 600 - AtticMenuMetrics.anchorGap)
        XCTAssertEqual(below.minX, 300, "on the button's leading edge")
    }

    /// Accepted 2026-11-10: out of the control, 8 pt away, on its leading
    /// edge (trailing on the panel's right half), toward the panel's
    /// middle, growing from the corner by the control.
    /// Menu look picks, placement B (Accepted 2026-11-13): kept inside the
    /// panel when it fits, never over the row it was opened from; when it
    /// can't, it hangs past the panel as before.
    func testPlacementBKeepsTheMenuInsideThePanelWithoutCoveringItsRow() {
        let panel = NSRect(x: 900, y: 200, width: 400, height: 600)
        let size = CGSize(width: 200, height: 160)
        // Right-clicked low in the panel: no room below, so it opens upward
        // from the pointer instead of sliding over the row.
        let low = NSPoint(x: 1000, y: 260)
        let hanging = (frame: NSRect(x: low.x, y: low.y - size.height, width: size.width, height: size.height),
                       corner: AtticGlassMenu.Corner.topLeading)
        let kept = AtticGlassMenu.keptInside(panel: panel, hanging, placement: .point(low))
        XCTAssertEqual(kept.frame.minY, low.y, "its bottom edge on the pointer")
        XCTAssertEqual(kept.corner, .bottomLeading)
        XCTAssertTrue(panel.insetBy(dx: AtticMenuMetrics.panelInset, dy: AtticMenuMetrics.panelInset).contains(kept.frame))
        // Room below: down from the pointer, as before.
        let high = NSPoint(x: 1000, y: 700)
        let below = AtticGlassMenu.keptInside(panel: panel, (NSRect(x: high.x, y: high.y - size.height, width: size.width, height: size.height),
                                                              .topLeading), placement: .point(high))
        XCTAssertEqual(below.frame.maxY, high.y)
        XCTAssertEqual(below.corner, .topLeading)
        // Near the right edge it flips to the pointer's left.
        let right = NSPoint(x: 1250, y: 700)
        let flipped = AtticGlassMenu.keptInside(panel: panel, (NSRect(x: right.x, y: right.y - size.height, width: size.width, height: size.height),
                                                                .topLeading), placement: .point(right))
        XCTAssertEqual(flipped.frame.maxX, right.x)
        XCTAssertEqual(flipped.corner, .topTrailing)
        // Room neither above nor below the pointer: it hangs past as now.
        let tall = CGSize(width: 200, height: 400)
        let middle = NSPoint(x: 1000, y: 500)
        let placed = (frame: NSRect(x: middle.x, y: middle.y - tall.height, width: tall.width, height: tall.height),
                      corner: AtticGlassMenu.Corner.topLeading)
        let unchanged = AtticGlassMenu.keptInside(panel: panel, placed, placement: .point(middle))
        XCTAssertEqual(unchanged.frame, placed.frame, "never lifted over its own row")
        XCTAssertEqual(unchanged.corner, placed.corner)
    }

    func testTheMenuComesOutOfItsControlTowardThePanelsMiddle() {
        let size = CGSize(width: 216, height: 200)
        let panel = NSRect(x: 900, y: 200, width: 400, height: 600)
        let topLeft = NSRect(x: 920, y: 760, width: 24, height: 24)
        let a = AtticGlassMenu.rootPlacement(size: size, placement: .below(topLeft), visible: screen, container: panel)
        XCTAssertEqual(a.frame.minX, topLeft.minX, "its leading edge on the control's")
        XCTAssertEqual(a.frame.maxY, topLeft.minY - 8, "8 pt below a control on the upper half")
        XCTAssertEqual(a.corner, .topLeading)
        let bottomRight = NSRect(x: 1250, y: 220, width: 24, height: 24)
        let b = AtticGlassMenu.rootPlacement(size: size, placement: .below(bottomRight), visible: screen, container: panel)
        XCTAssertEqual(b.frame.maxX, bottomRight.maxX, "its trailing edge on the control's, on the right half")
        XCTAssertEqual(b.frame.minY, bottomRight.maxY + 8, "up from a control on the lower half")
        XCTAssertEqual(b.corner, .bottomTrailing)
        // No room above at the screen's top: it opens down instead.
        let high = NSRect(x: 920, y: 850, width: 24, height: 24)
        let tall = AtticGlassMenu.rootPlacement(size: CGSize(width: 216, height: 400), placement: .below(high), visible: screen,
                                                container: NSRect(x: 900, y: 0, width: 400, height: 2000))
        XCTAssertEqual(tall.frame.maxY, high.minY - 8)
        // A menu taller than the screen stays inside it (its rows scroll).
        let long = AtticGlassMenu.rootPlacement(size: CGSize(width: 216, height: 2000), placement: .below(topLeft), visible: screen, container: panel)
        XCTAssertGreaterThanOrEqual(long.frame.minY, screen.minY + AtticMenuMetrics.screenMargin)
        XCTAssertLessThanOrEqual(long.frame.maxY, screen.maxY - AtticMenuMetrics.screenMargin)
        // A right-click: from the pointer.
        let point = AtticGlassMenu.rootPlacement(size: size, placement: .point(CGPoint(x: 1400, y: 600)), visible: screen)
        XCTAssertEqual(point.corner, .topTrailing, "flipped left of the pointer, it grows from its top-right")
    }

    /// The motion runs on Core Animation: the card grows from its corner
    /// on the spring, the rows cascade 30 ms apart; Reduce Motion fades
    /// only, with no growth and no cascade.
    func testTheCardGrowsAndItsRowsCascadeButReduceMotionOnlyFades() throws {
        let saved = AtticGlassMenu.design
        let savedStyle = AtticReducedMotionStyle.current
        AtticReducedMotionStyle.current = .fade
        defer { AtticGlassMenu.design = saved; AtticReducedMotionStyle.current = savedStyle }
        // GitHub's macOS runners can enable system Reduce Motion. This case
        // exercises both explicit branches regardless of the runner setting.
        var animated = saved
        animated.reduceMotion = false
        AtticGlassMenu.design = animated
        let menu = open(commands())
        let card = menu.cards[0]
        let lift = try XCTUnwrap(card.window.lift.layer)
        let grow = try XCTUnwrap(lift.animation(forKey: "attic.open.grow") as? CASpringAnimation)
        XCTAssertEqual(grow.perceptualDuration, 0.30, accuracy: 0.01)
        XCTAssertEqual(grow.bounce, 0.28, accuracy: 0.01)
        let small = try XCTUnwrap((grow.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertEqual(small.m11, 0.86, accuracy: 1e-6, "from 0.86")
        XCTAssertNotNil(lift.animation(forKey: "attic.open.fade"))
        let rows = card.view.subviews.first?.subviews.compactMap { $0 as? AtticGlassMenuEntryView }
            .filter { card.entries[$0.index].isItem } ?? []
        let begins = rows.compactMap { $0.layer?.animation(forKey: "attic.row.slide")?.beginTime }
        XCTAssertEqual(begins.count, rows.count, "every row slides in")
        XCTAssertEqual(begins[1] - begins[0], 0.03, accuracy: 0.005, "30 ms apart")
        XCTAssertEqual(AtticMenuMetrics.stagger(20), 0.24, "at most 240 ms")
        menu.close(animated: false)

        var reduced = animated
        reduced.reduceMotion = true
        AtticGlassMenu.design = reduced
        let calm = open(commands())
        defer { calm.close(animated: false) }
        let calmLift = try XCTUnwrap(calm.cards[0].window.lift.layer)
        XCTAssertNil(calmLift.animation(forKey: "attic.open.grow"), "Reduce Motion: no growth")
        XCTAssertNotNil(calmLift.animation(forKey: "attic.open.fade"), "a fade only")
        let calmRows = calm.cards[0].view.subviews.first?.subviews.compactMap { $0 as? AtticGlassMenuEntryView } ?? []
        XCTAssertTrue(calmRows.allSatisfy { $0.layer?.animation(forKey: "attic.row.slide") == nil }, "no cascade")
    }

    func testReducedInstantMenuOpensWithoutAnimation() throws {
        let saved = AtticGlassMenu.design
        let savedStyle = AtticReducedMotionStyle.current
        defer { AtticGlassMenu.design = saved; AtticReducedMotionStyle.current = savedStyle }
        var design = saved
        design.reduceMotion = true
        AtticGlassMenu.design = design
        AtticReducedMotionStyle.current = .instant
        let menu = open(commands())
        defer { menu.close(animated: false) }
        let lift = try XCTUnwrap(menu.cards[0].window.lift.layer)
        XCTAssertNil(lift.animation(forKey: "attic.open.fade"), "Reduced Instant opens immediately")
        XCTAssertNil(lift.animation(forKey: "attic.open.grow"))
    }

    /// Accepted 2026-11-12 (evening) · Menus: version 3 on the system
    /// menu's Liquid Glass, with the grey hover. The system glass lenses
    /// what lies under the card, the panel included, as the system menu's
    /// does, so by design no card cuts its place out of the panel: the cut
    /// stays a preview-only seam (`ATTIC_UI_TEST_MENU_SURFACE=cut`), off in
    /// every normal run, on every surface, and the panel's page is never
    /// masked.
    func testNoCardCutsItsPlaceOutOfThePanel() throws {
        final class Host: NSWindow, AtticMenuBackdropHost {
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            var menuBackdropView: NSView? { page }
        }
        XCTAssertFalse(AtticMenuSurfaceSeam.cutsPanel, "the cut is off by design")
        let window = Host(contentRect: NSRect(x: 100, y: 100, width: 400, height: 500), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.page.wantsLayer = true
        window.contentView = window.page
        let layer = try XCTUnwrap(window.page.layer)
        // The test host keeps its windows off screen: place the card by the window.
        let card = NSRect(x: window.frame.minX + 50, y: window.frame.minY + 200, width: 216, height: 200)
        for surface in PanelSurfaceStyle.allCases {
            for animated in [false, true] {
                var design = AtticDesignContext(mode: .light, surface: surface)
                design.reduceMotion = false
                let style = AtticGlassMenuStyle(design: design)
                XCTAssertNil(AtticMenuBackdropHole.open(under: card, in: window, corner: .topLeading, animated: animated, style: style),
                             "\(surface): nothing is cut")
                XCTAssertNil(layer.mask, "\(surface): the panel's page is whole")
            }
        }
    }

    func testASubmenuOpensBesideItsRowAndFlipsAtTheEdge() {
        let parent = NSRect(x: 400, y: 300, width: 184, height: 400)
        let size = CGSize(width: 150, height: 200)
        let right = AtticGlassMenu.submenuFrame(size: size, parent: parent, rowTop: 600, firstRowOffset: 30, visible: screen)
        XCTAssertEqual(right.minX, parent.maxX + 4, "4 pt to the side")
        XCTAssertEqual(right.maxY, 630, "its first row level with the row that opened it")
        let edge = NSRect(x: 1250, y: 300, width: 184, height: 400)
        let left = AtticGlassMenu.submenuFrame(size: size, parent: edge, rowTop: 600, firstRowOffset: 30, visible: screen)
        XCTAssertEqual(left.maxX, edge.minX - 4, "no room on the right: on the left")
        let low = AtticGlassMenu.submenuFrame(size: size, parent: parent, rowTop: 120, firstRowOffset: 30, visible: screen)
        XCTAssertGreaterThanOrEqual(low.minY, AtticMenuMetrics.screenMargin, "moved up at the bottom")
    }

    // MARK: Keyboard

    /// keyboard-hunt: seeded key sequences across nested menus, including
    /// focus movement, type-to-select, shortcuts, Tab and dismissal.
    func testKeyboardHuntSeededMenuKeysNeverTargetDisabledOrMissingRows() {
        for seed in [UInt64(0x4B4D_1601), 0x4B4D_1602, 0x4B4D_1603] {
            var random = seed
            func next(_ count: Int) -> Int {
                random ^= random << 13
                random ^= random >> 7
                random ^= random << 17
                return Int(random % UInt64(count))
            }
            var menu = open(commands())
            for step in 0..<360 {
                if !menu.isOpen { menu = open(commands()) }
                let action = next(16)
                let label = "seed=\(String(seed, radix: 16)) step=\(step) action=\(action)"
                let timestamp = 1 + Double(step) * 0.08
                switch action {
                case 0: menu.handle(key(125, time: timestamp)) // Down.
                case 1: menu.handle(key(126, time: timestamp)) // Up.
                case 2: menu.handle(key(124, time: timestamp)) // Submenu.
                case 3: menu.handle(key(123, time: timestamp)) // Back from submenu.
                case 4: menu.handle(key(115, time: timestamp)) // Home.
                case 5: menu.handle(key(119, time: timestamp)) // End.
                case 6: menu.handle(key(36, "\r", time: timestamp)) // Return.
                case 7: menu.handle(key(53, "\u{1b}", time: timestamp)) // Escape.
                case 8: menu.handle(key(49, " ", time: timestamp)) // Space.
                case 9: menu.handle(key(48, "\t", time: timestamp)) // Tab.
                case 10: menu.handle(key(48, "\t", flags: .shift, time: timestamp)) // Shift-Tab.
                case 11: menu.handle(key(2, "d", time: timestamp))
                case 12: menu.handle(key(14, "e", time: timestamp))
                case 13: menu.handle(key(17, "t", time: timestamp))
                case 14: menu.handle(key(40, "k", flags: .command, time: timestamp))
                default: menu.handle(key(14, "e", flags: .option, time: timestamp))
                }
                XCTAssertTrue(ran.isEmpty, "a tracked menu never executes a command twice: \(label)")
                if menu.isOpen {
                    XCTAssertTrue(menu.cards.indices.contains(menu.focus), "keyboard focus belongs to an open card: \(label)")
                    for card in menu.cards {
                        if let selected = card.highlighted {
                            XCTAssertTrue(card.selectableIndices.contains(selected), "disabled/removed row cannot take focus: \(label)")
                        }
                    }
                } else if let chosen = menu.chosen {
                    XCTAssertTrue(["Complete", "Today", "Tomorrow", "#home", "Delete"].contains(chosen.title),
                                  "an actual enabled row is chosen once: \(label)")
                }
            }
            menu.close(animated: false)
            print("KEYBOARD_HUNT_MENU seed=\(String(seed, radix: 16)) steps=360")
        }
    }

    func testArrowsSkipDisabledRowsAndRightLeftOpenAndCloseASubmenu() {
        let menu = open(commands())
        menu.handle(key(125))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Complete", "↓ lights the first row")
        menu.handle(key(125))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Date", "↓ skips a disabled row")
        menu.handle(key(124))
        XCTAssertEqual(menu.cards.count, 2, "→ opens the submenu")
        XCTAssertEqual(menu.focus, 1)
        XCTAssertEqual(titleOfHighlight(menu, card: 1), "Today", "its first item is lit (the header is not an item)")
        menu.handle(key(125))
        XCTAssertEqual(titleOfHighlight(menu, card: 1), "Tomorrow")
        menu.handle(key(123))
        XCTAssertEqual(menu.cards.count, 1, "← closes it")
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Date", "its row stays lit")
        menu.handle(key(126))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Complete")
        menu.handle(key(126))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Complete", "no wrap at the top, as a native menu")
        menu.handle(key(36, "\r"))
        XCTAssertEqual(menu.chosen?.title, "Complete", "Return chooses")
        XCTAssertFalse(menu.isOpen)
    }

    func testReturnOnASubmenuOpensItAndEscapeClosesTheMenu() {
        let menu = open(commands())
        menu.handle(key(125))
        menu.handle(key(125))
        menu.handle(key(36, "\r"))
        XCTAssertEqual(menu.cards.count, 2, "Return on a submenu's row opens it")
        menu.handle(key(36, "\r"))
        XCTAssertEqual(menu.chosen?.title, "Today")
        let other = open(commands())
        other.handle(key(53, "\u{1b}"))
        XCTAssertFalse(other.isOpen, "Esc closes")
        XCTAssertNil(other.chosen, "and chooses nothing")
    }

    func testTypingSelectsByTitleAndAShortcutStillRunsItsCommand() {
        let menu = open(commands())
        menu.handle(key(2, "d", time: 10))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Date", "typing selects the first title it starts")
        menu.handle(key(14, "e", time: 10.2))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Delete", "the letters add up")
        menu.handle(key(17, "t", time: 12))
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Tags", "after a pause it starts again")
        menu.handle(key(40, "k", flags: .command))
        XCTAssertEqual(menu.chosen?.title, "Complete", "⌘K runs Complete though its hint is hidden")
    }

    func testChoosingThroughPopUpRunsTheCommandAndPostsTheTrackingNotifications() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        let view = try XCTUnwrap(window.contentView)
        var began: [NSEvent?] = []
        var ended = 0
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                began.append(note.userInfo?[AtticGlassMenu.openerKey] as? NSEvent)
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in ended += 1 },
        ]
        defer { tokens.forEach(center.removeObserver) }
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 5,
                                                     windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        AtticGlassMenu.testDriver = { menu in
            XCTAssertTrue(AtticGlassMenu.current === menu, "one menu tracks at a time")
            menu.handle(self.key(125))
            menu.handle(self.key(36, "\r"))
        }
        let chosen = AtticGlassMenu.popUp(commands(), in: view, placement: .point(CGPoint(x: 20, y: 20)), opener: press)
        XCTAssertEqual(chosen?.title, "Complete")
        XCTAssertEqual(ran, ["Complete"], "the chosen command runs after the menu closes")
        XCTAssertEqual(began.count, 1)
        XCTAssertEqual(began.first??.timestamp, 5, "the opening press travels with the notification")
        XCTAssertEqual(ended, 1)
        XCTAssertNil(AtticGlassMenu.current)
    }

    // MARK: Pointer and submenus

    func testHoverOpensASubmenuAfterItsDelayAndGraceKeepsItOnTheWay() throws {
        let menu = open(commands())
        let root = menu.cards[0]
        let date = row(titled: "Date", in: root)
        menu.pointerMoved(to: center(of: date, in: root))
        XCTAssertEqual(menu.cards.count, 1, "not at once")
        RunLoop.main.run(until: Date().addingTimeInterval(AtticMenuMetrics.submenuDelay + 0.1))
        XCTAssertEqual(menu.cards.count, 2, "after about 180 ms")
        let child = menu.cards[1]
        XCTAssertEqual(child.screenTop(ofRow: try XCTUnwrap(child.selectableIndices.first)), root.screenTop(ofRow: date), accuracy: 0.5,
                       "the submenu's first item lines up with the row that opened it")
        XCTAssertEqual(child.frame.minX, root.frame.maxX + 4, accuracy: 0.5)
        // Crossing the next row on the way: the submenu stays for the grace.
        let tags = row(titled: "Tags", in: root)
        menu.pointerMoved(to: center(of: tags, in: root))
        XCTAssertEqual(menu.cards.count, 2, "pointer grace")
        menu.pointerMoved(to: center(of: try XCTUnwrap(child.selectableIndices.first), in: child))
        RunLoop.main.run(until: Date().addingTimeInterval(AtticMenuMetrics.pointerGrace + 0.1))
        XCTAssertEqual(menu.cards.count, 2, "reaching the submenu keeps it")
        XCTAssertEqual(titleOfHighlight(menu, card: 1), "Today")
        // Settling on another row closes it after the grace.
        menu.pointerMoved(to: center(of: row(titled: "Complete", in: root), in: root))
        RunLoop.main.run(until: Date().addingTimeInterval(AtticMenuMetrics.pointerGrace + 0.1))
        XCTAssertEqual(menu.cards.count, 1)
        XCTAssertEqual(titleOfHighlight(menu, card: 0), "Complete")
        menu.close(animated: false)
    }

    func testAClickOutsideClosesAndTheOpeningReleaseChoosesNothing() throws {
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 400, y: 600), modifierFlags: [], timestamp: 100,
                                                     windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = AtticGlassMenu(commands(), appearance: nil, opener: press)
        menu.open(.point(CGPoint(x: 400, y: 600)), visible: screen, source: nil)
        let complete = center(of: 0, in: menu.cards[0])
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp, location: complete, modifierFlags: [], timestamp: 100.1,
                                                       windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        menu.handle(release)
        XCTAssertTrue(menu.isOpen, "the press's own release chooses nothing")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: complete, modifierFlags: [], timestamp: 101,
                                                     windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        menu.handle(click)
        XCTAssertEqual(menu.chosen?.title, "Complete", "a click on a row chooses it")
        let other = open(commands())
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 3,
                                                       windowNumber: 0, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        other.handle(outside)
        XCTAssertFalse(other.isOpen, "a click outside closes the menu")
        XCTAssertNil(other.chosen)
    }

    // MARK: VoiceOver

    func testVoiceOverReadsAMenuOfMenuItemsWithMarksAndCanPressThem() throws {
        let menu = open(commands())
        let view = menu.cards[0].view
        XCTAssertEqual(view.accessibilityRole(), .menu)
        let items = try XCTUnwrap(view.accessibilityChildren() as? [AtticGlassMenuItemElement])
        XCTAssertEqual(items.map { $0.accessibilityLabel() ?? "" }, ["Complete", "Disabled", "Date", "Tags", "Delete"],
                       "separators are not items")
        XCTAssertTrue(items.allSatisfy { $0.accessibilityRole() == .menuItem })
        XCTAssertFalse(items[1].isAccessibilityEnabled(), "a disabled command reads as dimmed")
        menu.handle(key(125))
        XCTAssertTrue(items[0].isAccessibilitySelected(), "the highlight is the selected item")
        // Open the Tags submenu by pressing its item: its menu is the item's child.
        XCTAssertTrue(items[3].accessibilityPerformPress())
        XCTAssertEqual(menu.cards.count, 2)
        let submenu = try XCTUnwrap(items[3].accessibilityChildren()?.first as? AtticGlassMenuView)
        XCTAssertEqual(submenu.accessibilityRole(), .menu)
        let home = try XCTUnwrap(submenu.accessibilityChildren()?.first as? AtticGlassMenuItemElement)
        XCTAssertEqual(home.accessibilityAttributeValue(AtticDropdownMenuItem.markCharAttribute) as? String, "✓",
                       "a ticked command reports its mark, as NSMenuItem does")
        XCTAssertTrue(home.accessibilityPerformPress())
        XCTAssertEqual(menu.chosen?.title, "#home")
    }

    /// What is under the pointer is the row's menu item, as with `NSMenu`:
    /// the accessibility hit test (VoiceOver's pointer, and the UI tests'
    /// "hittable" check) lands on the item, not on the card's window. The
    /// rows' view takes no AppKit hits (the menu tracks the pointer itself).
    func testThePointOverARowHitsItsMenuItem() throws {
        let menu = openForAccessibilityGeometry(commands())
        let card = menu.cards[0]
        for title in ["Complete", "Date", "Delete"] {
            let point = center(of: row(titled: title, in: card), in: card)
            let hit = card.window.accessibilityHitTest(point)
            XCTAssertEqual((hit as? AtticGlassMenuItemElement)?.command.title, title,
                           "\(title): the hit test finds its item (got \(String(describing: hit)))")
        }
        // A submenu's card answers for its own rows.
        menu.handle(key(125))
        menu.handle(key(125)); menu.handle(key(125)); menu.handle(key(125))
        XCTAssertTrue(card.view.element(for: row(titled: "Tags", in: card))!.accessibilityPerformPress())
        let submenu = try XCTUnwrap(menu.cards.last)
        let home = submenu.window.accessibilityHitTest(center(of: row(titled: "#home", in: submenu), in: submenu))
        XCTAssertEqual((home as? AtticGlassMenuItemElement)?.command.title, "#home")
    }

    /// Each item reports its own row's frame on screen (VoiceOver's box,
    /// XCUITest's hit point). The rows' view is flipped; the items' frames
    /// came out mirrored top to bottom, so CI's pointer at "Duplicate"
    /// (the first row) landed on "Delete" (the last) and chose it (w4 trace,
    /// run 41196043594).
    func testEveryItemsFrameIsItsOwnRowOnScreen() throws {
        let menu = openForAccessibilityGeometry(commands())
        for card in [menu.cards[0]] {
            for row in card.entries.indices {
                guard let element = card.view.element(for: row) else { continue }
                let frame = element.accessibilityFrame()
                let center = center(of: row, in: card)
                XCTAssertEqual(frame.midY, center.y, accuracy: 0.5, "\(element.command.title): \(frame) is its row (centre \(center))")
                XCTAssertEqual(frame.midX, center.x, accuracy: 0.5, element.command.title)
                XCTAssertEqual(frame.height, card.entries[row].frame.height, accuracy: 0.5, element.command.title)
            }
        }
    }

    /// XCUITest's hit point goes through the system, not the card's window:
    /// the window server picks the window under the point, then the app's
    /// accessibility hit test asks it. A clear, non-opaque window lets the
    /// window server pass a point over see-through pixels (the glass is drawn
    /// by the window server, not into the window) to the window below, so
    /// every glass menu item was "Not hittable" on CI.
    func testTheSystemsHitAtARowIsTheCardAndItsMenuItem() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("needs a window on screen (CI and the Air)")
        }
        AtticGlassMenu.ordersCardsFront = true
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let menu = AtticGlassMenu(commands(), appearance: NSAppearance(named: .aqua), opener: nil)
        menu.open(.point(CGPoint(x: visible.midX, y: visible.midY + 100)), visible: visible, source: nil)
        defer { menu.close(animated: false) }
        let card = menu.cards[0]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(card.window.ignoresMouseEvents, "the card takes the pointer")
        for title in ["Complete", "Date", "Delete"] {
            let point = center(of: row(titled: title, in: card), in: card)
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            XCTAssertEqual(number, card.window.windowNumber, "\(title): the window server finds the card's window")
            let hit = NSApp.accessibilityHitTest(point)
            XCTAssertEqual((hit as? AtticGlassMenuItemElement)?.command.title, title,
                           "\(title): the app's hit test finds its item (got \(String(describing: hit)))")
        }
    }

    /// The "+" card over the rows (orchestrator decision, w3 UI tests round 2,
    /// under Accepted 2026-10-29 "The '+' card"): a right-click on the card
    /// opens no row's menu under it; one on a row outside it closes the card
    /// as a click outside does and opens that row's menu in the same press.
    func testARightClickOutsideAnOpenCardClosesItAndOpensTheRowsMenu() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        window.contentView = content
        let anchor = AtticContextMenuAnchor.AnchorView(frame: content.bounds)
        anchor.build = { [AtticMenuCommand(verbatim: "Row menu") {}] }
        content.addSubview(anchor)
        var cardOpen = true
        var closes = 0
        let card = AtticPressShield(frame: NSRect(x: 150, y: 0, width: 150, height: 150))
        card.isActive = { cardOpen }
        card.onOutsidePress = { closes += 1; cardOpen = false }
        content.addSubview(card)
        var opened: [String] = []
        AtticGlassMenu.testDriver = { opened.append(contentsOf: $0.commands.map(\.title)) }
        func press(_ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 1,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertNil(AtticContextMenus.commands(for: press(200, 50)), "the card hides the row under it")
        _ = AtticContextMenus.route(press(200, 50))
        spin()
        XCTAssertEqual(closes, 0, "a press on the card keeps it open")
        XCTAssertEqual(opened, [], "and opens no row's menu")

        _ = AtticContextMenus.route(press(50, 250))
        spin()
        XCTAssertEqual(closes, 1, "a press on a row outside closes the card")
        XCTAssertEqual(opened, ["Row menu"], "and opens the row's menu in the same press")

        // Closed, the card shields nothing.
        XCTAssertNotNil(AtticContextMenus.commands(for: press(200, 50)))
    }

    // MARK: Date card

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testTheDateCardsNewKeys() {
        XCTAssertEqual(AtticDateCardKey(key(123, "", flags: .shift)), .month(-1), "⇧← turns back a month")
        XCTAssertEqual(AtticDateCardKey(key(124, "", flags: .shift)), .month(1))
        XCTAssertEqual(AtticDateCardKey(key(126, "", flags: .shift)), .month(-1))
        XCTAssertEqual(AtticDateCardKey(key(125, "", flags: .shift)), .month(1))
        XCTAssertEqual(AtticDateCardKey(key(116, "")), .month(-1), "Page Up")
        XCTAssertEqual(AtticDateCardKey(key(121, "")), .month(1), "Page Down")
        XCTAssertEqual(AtticDateCardKey(key(126, "", flags: .option)), .year(-1), "⌥↑ a year back")
        XCTAssertEqual(AtticDateCardKey(key(125, "", flags: .option)), .year(1))
        XCTAssertEqual(AtticDateCardKey(key(51, "\u{7f}", flags: .command)), .clear, "⌘⌫ clears")
        XCTAssertEqual(AtticDateCardKey(key(51, "\u{7f}")), .delete, "⌫ edits the field")
        XCTAssertEqual(AtticDateCardKey(key(123, "")), .left)

        var state = AtticDateCardState(start: date(2026, 10, 23))
        _ = state.apply(.year(1), calendar: calendar, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.cursor, date(2027, 10, 23))
        XCTAssertEqual(state.apply(.clear, calendar: calendar, suggestions: 0, typing: false, hasRemove: true), .remove,
                       "⌘⌫ clears a date that is set")
        XCTAssertEqual(state.apply(.clear, calendar: calendar, suggestions: 0, typing: false, hasRemove: false), .nothing,
                       "and does nothing without one")
    }

    func testTheMonthIsSixWeeksWithTheNeighbouringDaysAndTwoLetterWeekdays() {
        let october = AtticDateMonth(containing: date(2026, 10, 9), calendar: calendar)
        XCTAssertEqual(october.weekdays, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(october.cells.count, 42, "six weeks, so the card never changes height")
        XCTAssertEqual(october.cells.first, date(2026, 9, 28), "the grid starts with September's last days")
        XCTAssertEqual(october.inMonth.prefix(4), [false, false, false, true])
        XCTAssertEqual(october.inMonth.filter { $0 }.count, 31)
        XCTAssertEqual(october.cells.last, date(2026, 11, 8))
        XCTAssertEqual(AtticDateCardFormat.monthTitle(october.start, today: date(2026, 10, 23), calendar: calendar), "October",
                       "this year's month is its name alone")
        XCTAssertEqual(AtticDateCardFormat.monthTitle(date(2027, 1, 1), today: date(2026, 10, 23), calendar: calendar), "January 2027")
    }

    func testTypingOffersUpToFourSuggestionsAndReturnTakesTheTopOne() {
        let today = date(2026, 10, 5)
        let parse: (String) -> Date? = { NoteDateQuery.parse($0, today: today, calendar: self.calendar, locale: Locale(identifier: "en_GB")) }
        let t = AtticDateSuggestions.make("t", today: today, calendar: calendar, parse: parse)
        XCTAssertEqual(t.map(\.title), ["Today", "Tomorrow", "Thursday"], "every named day the text starts, one per day")
        XCTAssertLessThanOrEqual(AtticDateSuggestions.make("s", today: today, calendar: calendar, parse: parse).count, 4)
        var state = AtticDateCardState(start: today)
        state.typed(suggestions: t)
        XCTAssertEqual(state.apply(.pick, calendar: calendar, suggestions: t.count, typing: true, hasRemove: false), .suggestion(0),
                       "Return applies the top suggestion")
    }
}
