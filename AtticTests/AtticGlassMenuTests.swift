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

    private func key(_ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], time: TimeInterval = 1) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func titleOfHighlight(_ menu: AtticGlassMenu, card: Int) -> String? {
        guard let row = menu.cards[card].highlighted, case let .item(command) = menu.cards[card].entries[row].kind else { return nil }
        return command.title
    }

    private func center(of row: Int, in card: AtticGlassMenuCard) -> NSPoint {
        let frame = card.window.frame
        let entry = card.entries[row].frame
        return NSPoint(x: frame.minX + entry.midX, y: frame.maxY - entry.midY)
    }

    private func row(titled title: String, in card: AtticGlassMenuCard) -> Int {
        card.entries.firstIndex { if case let .item(command) = $0.kind { return command.title == title } else { return false } }!
    }

    // MARK: Layout

    func testTheLayoutIsDraftCsRowsSeparatorsAndHeadersWithNoShortcutHints() {
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
        XCTAssertEqual(layout.entries[0].frame.minY, 4, "rows 4 pt in")
        XCTAssertEqual(layout.entries[3].frame.height, 8.5, "a 0.5 pt hairline with 4 pt above and below")
        XCTAssertGreaterThanOrEqual(layout.size.width, AtticMenuMetrics.minWidth)
        let submenu = AtticGlassMenuCard.layout(commands()[2].children)
        XCTAssertEqual(submenu.entries.first.map { if case .header = $0.kind { true } else { false } }, true, "a titled section's header")
        XCTAssertEqual(submenu.entries.first?.frame.height, 26)
        // The hint is hidden: a shortcut adds no width.
        let plain = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title here") {}])
        let hinted = AtticGlassMenuCard.layout([AtticMenuCommand(verbatim: "A very long command title here",
                                                                 shortcut: KeyboardShortcut("d", modifiers: [.command, .option])) {}])
        XCTAssertEqual(plain.size, hinted.size, "shortcut hints are not drawn (draft C), so they take no room")
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
        XCTAssertEqual(child.window.frame.minX, root.window.frame.maxX + 4, accuracy: 0.5)
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
        XCTAssertEqual(october.weekdays, ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])
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
