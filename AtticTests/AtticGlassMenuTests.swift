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
        func walk(_ node: AnyObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            if node.accessibilityRole?() == .menuButton {
                let label = node.accessibilityLabel?() ?? ""
                XCTAssertFalse(label.isEmpty, "Every AXMenuButton needs a label")
                named.append(label)
            }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject) }
        }
        walk(try XCTUnwrap(window.contentView))
        XCTAssertEqual(named.count, labels.count, "Every command menu has one accessible opener")
        XCTAssertEqual(Set(named), Set(labels), "icon-only, text and history menu openers are named")
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
        XCTAssertEqual(layout.entries[0].frame.height, 32, "32 pt rows")
        XCTAssertEqual(layout.entries[0].frame.minY, 6, "Loam: 6 pt padding")
        XCTAssertEqual(layout.entries[3].frame.height, 11, "a hairline on an 11 pt band")
        XCTAssertEqual(layout.size.width, 216, "at least 216 pt")
        let submenu = AtticGlassMenuCard.layout(commands()[2].children)
        XCTAssertEqual(submenu.entries.first.map { if case .header = $0.kind { true } else { false } }, true, "a titled section's header")
        XCTAssertEqual(submenu.entries.first?.frame.height, 26)
        // The shortcut sits at the trailing edge (Loam's), and takes room.
        let plain = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title, longer still") {}])
        let hinted = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title, longer still",
                                                                 shortcut: KeyboardShortcut("d", modifiers: [.command, .option])) {}])
        XCTAssertGreaterThan(hinted.size.width, plain.size.width, "the shortcut is drawn at the end")
        XCTAssertEqual(AtticMenuCommand(verbatim: "Info", shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) {}.glassShortcut, "⇧⌘I")
        XCTAssertNil(AtticMenuCommand(verbatim: "Edit", shortcut: KeyboardShortcut(.return, modifiers: [])) {}.glassShortcut,
                     "a bare key is the list's, not drawn")
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
                            for ink in [style.detail, style.header] {
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
                            XCTAssertEqual(style.destructive, style.tokens.ink(.dueText).nsColor,
                                "solid cards keep the original colour, without vivid")
                        }
                    }
                }
            }
        }
    }

    /// Owner, 12 Nov: "make them the same material as the panel". Every
    /// menu card's face (the command menus' `AtticGlassMenuSurface` and the
    /// picker cards' `AtticDropdownSurface`) draws the panel's own surface
    /// (`AtticPanelStageSurface`'s path) in every appearance: rendered in
    /// capture mode over the same desktop, the card's middle is the panel's
    /// middle. A bare `.glassEffect(.regular)` card draws nothing here, so
    /// the backdrop (magenta) would show through.
    func testEveryMenuCardWearsThePanelsMaterialInEveryAppearance() throws {
        let size = CGSize(width: 120, height: 120)
        let capture = AtticCaptureContext(collector: nil, backdrop: .desktop(.midGrey))
        func middle<V: View>(_ view: V, _ design: AtticDesignContext) throws -> NSColor {
            let content = view.frame(width: size.width, height: size.height)
                .padding(40)
                .background(Color(red: 1, green: 0, blue: 1))
                .atticDesign(design)
                .environment(\.atticCapture, capture)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try XCTUnwrap(bitmap.colorAt(x: 40 + Int(size.width / 2), y: 40 + Int(size.height / 2))?.usingColorSpace(.sRGB))
        }
        let access: [(contrast: Bool, reduced: Bool)] = [(false, false), (true, false), (false, true)]
        for mode in AtticDesignContext.Mode.allCases {
            for palette in AtticPanelTheme.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    for tint in [PanelTintLevel.off, .vivid] {
                        for (contrast, reduced) in access {
                            for controls in AtticControlMaterial.allCases {
                                let design = AtticDesignContext(mode: mode, palette: palette, surface: surface, tint: tint,
                                    increaseContrast: contrast, reduceTransparency: reduced, controls: controls)
                                let label = "\(design.caption), \(controls)"
                                let panel = try middle(AtticPanelStageSurface(cornerSize: 0), design)
                                let cards = [
                                    ("command menu", try middle(AtticGlassMenuSurface(style: AtticGlassMenuStyle(design: design)), design)),
                                    ("picker card", try middle(AtticDropdownSurface(), design)),
                                ]
                                for (name, card) in cards {
                                    XCTAssertEqual(Double(card.alphaComponent), Double(panel.alphaComponent), accuracy: 0.01, "\(name): \(label)")
                                    XCTAssertEqual(Double(card.redComponent), Double(panel.redComponent), accuracy: 0.01, "\(name): \(label)")
                                    XCTAssertEqual(Double(card.greenComponent), Double(panel.greenComponent), accuracy: 0.01, "\(name): \(label)")
                                    XCTAssertEqual(Double(card.blueComponent), Double(panel.blueComponent), accuracy: 0.01, "\(name): \(label)")
                                }
                            }
                        }
                    }
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
        XCTAssertEqual(AtticGlassMenuShape.rowRadius, 12, "concentric: 18 − 6")
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

    /// Accepted 2026-11-10: as wide as the control and at least 216 pt;
    /// rows that need more widen it up to 280 pt, past which they are cut
    /// short; a menu that names its width keeps it, never under 216 pt.
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

    func testMenusAreAtLeast216AndAsWideAsTheirControl() {
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Copy") {}]).size.width, 216)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Copy") {}], minimum: 300).size.width, 300, "as wide as the control")
        let long = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A rather long command title, longer still and more") {}]).size.width
        XCTAssertGreaterThan(long, 216)
        XCTAssertLessThanOrEqual(long, 280)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: String(repeating: "Very long ", count: 12)) {}]).size.width,
                       280, "never wider: the row is cut short")
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Today") {}], width: 200).size.width, 216)
        XCTAssertEqual(AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "Today") {}], width: 224).size.width, 224)
        // A submenu's card takes its command's width (at least 216 pt).
        let date = AtticMenuCommand.submenu("Date", width: AtticMenuMetrics.dateMenuWidth, [AtticMenuCommand(verbatim: "Today") {}])
        let menu = open([date])
        defer { menu.close(animated: false) }
        menu.handle(key(125))
        menu.handle(key(36, "\r"))
        XCTAssertEqual(menu.cards.count, 2, "Return opens Date ›")
        XCTAssertEqual(menu.cards[1].size.width, 216)
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
        defer { AtticGlassMenu.design = saved }
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

    /// Owner, 12 Nov ("it's not even the same glass"): over the panel the
    /// card's glass blurred the panel's rows. Each card cuts its place out
    /// of the panel's page on its own spring, cards chain their cuts, and a
    /// Solid card cuts nothing.
    func testACardCutsItsPlaceOutOfThePanelOnTheCardsOwnMotion() throws {
        final class Host: NSWindow, AtticMenuBackdropHost {
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            var menuBackdropView: NSView? { page }
        }
        let window = Host(contentRect: NSRect(x: 100, y: 100, width: 400, height: 500), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.page.wantsLayer = true
        window.contentView = window.page
        let layer = try XCTUnwrap(window.page.layer)
        var design = AtticDesignContext(mode: .light, surface: .glass)
        design.reduceMotion = false
        let style = AtticGlassMenuStyle(design: design)
        // The test host keeps its windows off screen: place the card by the window.
        let card = NSRect(x: window.frame.minX + 50, y: window.frame.minY + 200, width: 216, height: 200)
        let root = try XCTUnwrap(AtticMenuBackdropHole.open(under: card, in: window, corner: .topLeading, animated: true, style: style))
        XCTAssertTrue(layer.mask === root.mask, "the page is masked")
        XCTAssertEqual(root.cut.frame, window.page.convert(window.convertFromScreen(card), from: nil))
        let grow = try XCTUnwrap(root.cut.animation(forKey: "attic.open.grow") as? CASpringAnimation)
        XCTAssertEqual(grow.perceptualDuration, 0.30, accuracy: 0.01)
        XCTAssertEqual(grow.bounce, 0.28, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap((grow.fromValue as? NSValue)?.caTransform3DValue).m11, 0.86, accuracy: 1e-6)
        XCTAssertNotNil(root.page.animation(forKey: "attic.open.fade"), "the page fades out under the card")
        XCTAssertEqual(root.page.opacity, 0)

        let submenu = try XCTUnwrap(AtticMenuBackdropHole.open(under: card.offsetBy(dx: 220, dy: 0), in: window,
                                                              corner: .topLeading, animated: false, style: style))
        XCTAssertTrue(root.mask.mask === submenu.mask, "cuts chain")
        root.close(animated: false, reduceMotion: false)
        XCTAssertTrue(layer.mask === submenu.mask)
        XCTAssertNil(submenu.mask.mask)
        submenu.close(animated: false, reduceMotion: false)
        XCTAssertNil(layer.mask, "the page is whole again")

        XCTAssertNil(AtticMenuBackdropHole.open(under: card.offsetBy(dx: 2000, dy: 0), in: window, corner: .topLeading,
                                                animated: false, style: style), "off the panel: nothing to cut")
        let solid = AtticGlassMenuStyle(design: AtticDesignContext(mode: .light, surface: .solid))
        XCTAssertNil(AtticMenuBackdropHole.open(under: card, in: window, corner: .topLeading, animated: false, style: solid))
        XCTAssertNil(layer.mask)
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
