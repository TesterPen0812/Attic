import AppKit
import SwiftUI

// MARK: - Glass menus (draft C)

/// Attic's command menus on glass (owner, 2026-10-23: draft C, "the menus
/// look good"; superseding the native `NSMenu` look for row menus): the
/// right-click menus, ⋯ and ⇧⌘I, and every other menu built from
/// `AtticMenuCommand`s. Each level is its own floating card of real system
/// glass (`NSGlassEffectView`, regular) with draft C's corners, rim, rows,
/// icons, hairline separators and section headers; a submenu is a separate
/// card beside its row. Shortcut hints are not drawn (as drawn in draft C);
/// the shortcuts still work, in the menu and outside it.
///
/// Parity with a native menu: it tracks in its own event loop, as `NSMenu`
/// does, so nothing under it sees the keys or the clicks; ↑ ↓ move the
/// highlight, → opens a submenu and ← closes it, Return or Space choose,
/// Esc closes, typing selects by title; a click outside closes it;
/// VoiceOver reads menus and menu items (with their marks and states) and
/// can press them; the menu begins and ends tracking with the system's own
/// notifications, so the panel stays put while it is open.
@MainActor
final class AtticGlassMenu {
    /// Where the root card opens, in the source view's coordinates.
    enum Placement: Equatable {
        /// Its top-left corner at the point (a right-click).
        case point(CGPoint)
        /// Under the rect, its leading edge on the rect's (a button);
        /// above it when there is no room below.
        case below(NSRect)
    }

    /// The same, in screen coordinates.
    enum ScreenPlacement: Equatable {
        case point(CGPoint)
        case below(NSRect)
    }

    /// The menu tracking now (one at a time, as with `NSMenu`).
    private(set) static var current: AtticGlassMenu?
    /// The design the cards draw with, kept current by the panel's design
    /// context (`atticDesignFromSystem`); the mode follows the source
    /// window's appearance.
    static var design = AtticDesignContext()
    /// The object of the tracking notifications.
    static let trackingObject = NSMenu(title: "Attic")
    /// The event that opened the menu, in the tracking notifications'
    /// `userInfo` (a right-click's binding is taken from its press).
    static let openerKey = "AtticGlassMenuOpener"

    #if DEBUG
    /// Tests: runs instead of the event loop, with the open menu; the menu
    /// closes when it returns.
    static var testDriver: ((AtticGlassMenu) -> Void)?
    /// Tests: the cards are built and placed but never ordered on screen
    /// (the invisible test host).
    static var ordersCardsFront = true
    #endif

    let commands: [AtticMenuCommand]
    let style: AtticGlassMenuStyle
    /// The open cards, the root first; the last has the keyboard unless
    /// `focus` says otherwise.
    private(set) var cards: [AtticGlassMenuCard] = []
    /// The card the keyboard is in.
    private(set) var focus = 0
    private(set) var chosen: AtticMenuCommand?
    private(set) var isOpen = false
    private let appearance: NSAppearance?
    private let opener: NSEvent?
    private var openerReleasePending: Bool
    private var typeAhead = ""
    private var typeAheadAt: TimeInterval = 0
    private var submenuTimer: Timer?
    private var graceTimer: Timer?
    private var lastPointer: NSPoint?
    private weak var source: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var globalMonitor: Any?
    private var visible: NSRect = .zero

    init(_ commands: [AtticMenuCommand], appearance: NSAppearance?, opener: NSEvent?) {
        self.commands = commands
        self.appearance = appearance
        self.opener = opener
        let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var design = Self.design
        design.mode = dark ? .dark : .light
        style = AtticGlassMenuStyle(design: design)
        openerReleasePending = [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(opener?.type)
    }

    // MARK: Opening

    /// Opens the menu and tracks it until it closes, then runs the chosen
    /// command (as a menu choice, `AtticTextInput.choosing`). Returns the
    /// command chosen, if any.
    @discardableResult
    static func popUp(_ commands: [AtticMenuCommand], in view: NSView, placement: Placement,
                      opener: NSEvent? = NSApp.currentEvent) -> AtticMenuCommand? {
        guard current == nil, let window = view.window, !commands.isEmpty else { return nil }
        let screen: ScreenPlacement
        switch placement {
        case let .point(point):
            let inWindow = view.convert(point, to: nil)
            screen = .point(window.convertPoint(toScreen: inWindow))
        case let .below(rect):
            screen = .below(window.convertToScreen(view.convert(rect, to: nil)))
        }
        let menu = AtticGlassMenu(commands, appearance: window.effectiveAppearance, opener: opener)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        menu.open(screen, visible: visible, source: window)
        current = menu
        let info: [AnyHashable: Any]? = opener.map { [openerKey: $0] }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: trackingObject, userInfo: info)
        #if DEBUG
        if let testDriver {
            testDriver(menu)
            menu.close(animated: false)
        } else {
            menu.track()
        }
        #else
        menu.track()
        #endif
        current = nil
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackingObject, userInfo: info)
        guard let chosen = menu.chosen else { return nil }
        AtticTextInput.choosing(chosen.menuShortcut, chosen.action)
        return chosen
    }

    /// Opens on the next turn of the run loop, so the caller's own event
    /// finishes first (a button's click, a right-click's press).
    static func popUpLater(_ commands: [AtticMenuCommand], in view: NSView, placement: Placement,
                           opener: NSEvent? = NSApp.currentEvent) {
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            popUp(commands, in: view, placement: placement, opener: opener)
        }
    }

    /// Builds and shows the root card (no event loop: `track` runs it).
    func open(_ placement: ScreenPlacement, visible: NSRect, source: NSWindow?) {
        self.visible = visible
        self.source = source
        let card = AtticGlassMenuCard(commands: commands, menu: self, level: 0)
        card.place(Self.rootFrame(size: card.size, placement: placement, visible: visible))
        cards = [card]
        focus = 0
        isOpen = true
        card.show(fading: !style.reduceMotion)
        NSAccessibility.post(element: card.view, notification: Self.menuOpened)
    }

    // MARK: Placement (pure; tested)

    /// The root card's frame: its top-left at the point, or under the rect
    /// (above it when only that fits); flipped to the left of the point at
    /// the screen's right edge, and moved up at its bottom; never past the
    /// visible frame's margin.
    static func rootFrame(size: CGSize, placement: ScreenPlacement, visible: NSRect) -> NSRect {
        let m = AtticMenuMetrics.screenMargin
        let height = min(size.height, visible.height - m * 2)
        var x: CGFloat
        var top: CGFloat
        switch placement {
        case let .point(point):
            x = point.x
            top = point.y
            if x + size.width > visible.maxX - m { x = point.x - size.width }
            if top - height < visible.minY + m { top = visible.minY + m + height }
        case let .below(rect):
            x = rect.minX
            top = rect.minY - AtticMenuMetrics.anchorGap
            if top - height < visible.minY + m {
                let above = rect.maxY + AtticMenuMetrics.anchorGap + height
                top = above <= visible.maxY - m ? above : visible.minY + m + height
            }
            if x + size.width > visible.maxX - m { x = visible.maxX - m - size.width }
        }
        x = max(visible.minX + m, min(x, visible.maxX - m - size.width))
        top = min(top, visible.maxY - m)
        return NSRect(x: x, y: top - height, width: size.width, height: height)
    }

    /// A submenu's frame: 4 pt beside its parent, on the right, or on the
    /// left when the right has no room; its first row level with the row
    /// that opened it (`firstRowOffset` is the room above that first row:
    /// the card's inset and any header); moved up at the screen's bottom.
    static func submenuFrame(size: CGSize, parent: NSRect, rowTop: CGFloat, firstRowOffset: CGFloat, visible: NSRect) -> NSRect {
        let m = AtticMenuMetrics.screenMargin
        let gap = AtticMenuMetrics.submenuGap
        let height = min(size.height, visible.height - m * 2)
        var x = parent.maxX + gap
        if x + size.width > visible.maxX - m {
            let left = parent.minX - gap - size.width
            x = left >= visible.minX + m ? left : max(visible.minX + m, visible.maxX - m - size.width)
        }
        var top = rowTop + firstRowOffset
        if top - height < visible.minY + m { top = visible.minY + m + height }
        top = min(top, visible.maxY - m)
        return NSRect(x: x, y: top - height, width: size.width, height: height)
    }

    // MARK: Tracking

    /// The menu's own event loop (as `NSMenu`'s): every event comes here
    /// first, so no view, key monitor or shortcut under it sees one.
    private func track() {
        installObservers()
        while isOpen {
            guard let event = NSApp.nextEvent(matching: .any, until: .distantFuture, inMode: .eventTracking, dequeue: true) else { continue }
            handle(event)
            if isOpen, source.map({ !$0.isVisible }) == true { close() }
        }
        removeObservers()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        if let source {
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: source, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        // A click in another app (Attic's panel need not have activated it).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
    }

    /// One event of the loop (tests feed synthetic events here).
    func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKey(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseEntered, .mouseExited:
            pointerMoved(to: Self.screenPoint(of: event))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if locate(Self.screenPoint(of: event)) == nil, cardIndex(at: Self.screenPoint(of: event)) == nil {
                // A click outside closes the menu and goes nowhere else,
                // as a native menu's does.
                close()
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            release(at: Self.screenPoint(of: event), timestamp: event.timestamp)
        case .scrollWheel:
            let point = Self.screenPoint(of: event)
            if let index = cardIndex(at: point) { cards[index].scroll(by: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)) }
        case .applicationDefined where event.subtype.rawValue == Self.wakeSubtype:
            break
        case .appKitDefined, .systemDefined, .applicationDefined, .cursorUpdate, .periodic:
            NSApp.sendEvent(event)
        default:
            break
        }
    }

    static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if !flags.isEmpty {
            // A command's own shortcut runs it, hidden hint or not.
            if let key = Self.keyEquivalent(event),
               let command = AtticMenuCommand.command(key: key, characters: event.charactersIgnoringModifiers ?? "",
                                                      modifiers: Self.modifiers(event.modifierFlags), in: commands) {
                choose(command)
            }
            return
        }
        switch event.keyCode {
        case 53: close()
        case 125: moveHighlight(1)
        case 126: moveHighlight(-1)
        case 115, 116: moveHighlight(to: .first)
        case 119, 121: moveHighlight(to: .last)
        case 124: openHighlightedSubmenu(byKeyboard: true)
        case 123: closeFocusedSubmenu()
        case 36, 76:
            activateHighlighted(byKeyboard: true)
        case 49 where typeAhead.isEmpty || event.timestamp - typeAheadAt > AtticMenuMetrics.typeAheadReset:
            activateHighlighted(byKeyboard: true)
        case 48:
            break
        default:
            if let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                typeToSelect(characters, at: event.timestamp)
            }
        }
    }

    enum End { case first, last }

    private func moveHighlight(_ step: Int) {
        let card = cards[focus]
        card.closeSubmenu(of: self)
        let selectable = card.selectableIndices
        guard !selectable.isEmpty else { return }
        let next: Int
        if let current = card.highlighted, let at = selectable.firstIndex(of: current) {
            next = selectable[max(0, min(selectable.count - 1, at + step))]
        } else {
            next = step > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
        card.setHighlight(next)
    }

    private func moveHighlight(to end: End) {
        let card = cards[focus]
        card.closeSubmenu(of: self)
        let selectable = card.selectableIndices
        guard let row = end == .first ? selectable.first : selectable.last else { return }
        card.setHighlight(row)
    }

    private func typeToSelect(_ characters: String, at time: TimeInterval) {
        if time - typeAheadAt > AtticMenuMetrics.typeAheadReset { typeAhead = "" }
        typeAheadAt = time
        typeAhead += characters
        let card = cards[focus]
        let match = card.selectableIndices.first { index in
            guard case let .item(command) = card.entries[index].kind else { return false }
            return command.title.range(of: typeAhead, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
        if let match {
            card.closeSubmenu(of: self)
            card.setHighlight(match)
        }
    }

    private func openHighlightedSubmenu(byKeyboard: Bool) {
        let card = cards[focus]
        guard let row = card.highlighted, case let .item(command) = card.entries[row].kind,
              !command.children.isEmpty, !command.isDisabled else { return }
        openSubmenu(from: focus, row: row)
        if byKeyboard, cards.count > focus + 1 {
            focus += 1
            let child = cards[focus]
            if let first = child.selectableIndices.first { child.setHighlight(first) }
        }
    }

    private func closeFocusedSubmenu() {
        guard focus > 0 else { return }
        // Closing the cards after the parent puts the keyboard there.
        closeCards(after: focus - 1)
    }

    private func activateHighlighted(byKeyboard: Bool) {
        let card = cards[focus]
        guard let row = card.highlighted else {
            // Return with nothing lit closes the menu, as a native one does.
            close()
            return
        }
        activate(card: focus, row: row, byKeyboard: byKeyboard)
    }

    /// A row pressed (Return, a click, VoiceOver's press): a submenu opens,
    /// a command is chosen.
    func activate(card index: Int, row: Int, byKeyboard: Bool) {
        guard cards.indices.contains(index), case let .item(command) = cards[index].entries[row].kind, !command.isDisabled else { return }
        if command.children.isEmpty {
            choose(command)
        } else {
            focus = index
            cards[index].setHighlight(row)
            openHighlightedSubmenu(byKeyboard: byKeyboard)
        }
    }

    func choose(_ command: AtticMenuCommand) {
        guard !command.isDisabled, command.children.isEmpty, !command.isHeader else { return }
        chosen = command
        close()
    }

    // MARK: Pointer

    /// The card and row under a screen point; the deepest card first.
    func locate(_ point: NSPoint) -> (card: Int, row: Int)? {
        guard let index = cardIndex(at: point), let row = cards[index].row(at: point) else { return nil }
        return (index, row)
    }

    func cardIndex(at point: NSPoint) -> Int? {
        cards.indices.reversed().first { cards[$0].window.frame.contains(point) }
    }

    func pointerMoved(to point: NSPoint, afterGrace: Bool = false) {
        lastPointer = point
        guard isOpen else { return }
        guard let index = cardIndex(at: point) else {
            // Outside every card: the deepest one lets go of its highlight,
            // unless it is a submenu's row.
            cancelGrace()
            if let last = cards.last, last.child == nil { last.setHighlight(nil) }
            return
        }
        let card = cards[index]
        let row = card.row(at: point)
        if let child = card.child, row != child.parentRow {
            // On the way to the submenu: its row keeps the highlight for a
            // moment (pointer grace), as a native menu's does.
            if !afterGrace {
                if graceTimer == nil { startGrace() }
                return
            }
            closeCards(after: index)
        } else if card.child != nil {
            cancelGrace()
            focus = index
            return
        }
        cancelGrace()
        focus = index
        if let row, card.selectableIndices.contains(row) {
            card.setHighlight(row)
            scheduleSubmenu(card: index, row: row)
        } else {
            card.setHighlight(nil)
            cancelSubmenuTimer()
        }
    }

    private func startGrace() {
        let timer = Timer(timeInterval: AtticMenuMetrics.pointerGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.graceTimer = nil
                if let point = self.lastPointer { self.pointerMoved(to: point, afterGrace: true) }
            }
        }
        graceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelGrace() {
        graceTimer?.invalidate()
        graceTimer = nil
    }

    private func scheduleSubmenu(card index: Int, row: Int) {
        cancelSubmenuTimer()
        guard case let .item(command) = cards[index].entries[row].kind, !command.children.isEmpty, !command.isDisabled else { return }
        let timer = Timer(timeInterval: AtticMenuMetrics.submenuDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, self.cards.indices.contains(index), self.cards[index].highlighted == row,
                      self.cards[index].child == nil else { return }
                self.openSubmenu(from: index, row: row)
            }
        }
        submenuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSubmenuTimer() {
        submenuTimer?.invalidate()
        submenuTimer = nil
    }

    private func release(at point: NSPoint, timestamp: TimeInterval) {
        defer { openerReleasePending = false }
        guard let (index, row) = locate(point) else { return }
        // The release of the press that opened the menu chooses nothing
        // unless the pointer was held and dragged to a row (press, drag,
        // release, as in a native menu).
        if openerReleasePending, let opener, timestamp - opener.timestamp < 0.35 { return }
        activate(card: index, row: row, byKeyboard: false)
    }

    // MARK: Submenus

    func openSubmenu(from index: Int, row: Int) {
        guard cards.indices.contains(index), case let .item(command) = cards[index].entries[row].kind, !command.children.isEmpty else { return }
        cancelSubmenuTimer()
        closeCards(after: index)
        let parent = cards[index]
        let child = AtticGlassMenuCard(commands: command.children, menu: self, level: index + 1, title: command.title)
        child.parentRow = row
        let rowTop = parent.screenTop(ofRow: row)
        child.place(Self.submenuFrame(size: child.size, parent: parent.window.frame, rowTop: rowTop,
                                      firstRowOffset: child.firstRowOffset, visible: visible))
        parent.child = child
        cards.append(child)
        parent.view.needsDisplay = true
        child.show(fading: false)
        parent.view.updateAccessibility()
        NSAccessibility.post(element: child.view, notification: Self.menuOpened)
    }

    private func closeCards(after index: Int) {
        guard cards.count > index + 1 else { return }
        for card in cards[(index + 1)...] {
            card.hide(fading: false)
            NSAccessibility.post(element: card.view, notification: Self.menuClosed)
        }
        cards.removeSubrange((index + 1)...)
        cards[index].child = nil
        cards[index].view.needsDisplay = true
        cards[index].view.updateAccessibility()
        focus = min(focus, index)
    }

    // MARK: Closing

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        cancelGrace()
        cancelSubmenuTimer()
        for card in cards.reversed() {
            card.hide(fading: animated && !style.reduceMotion && card.level == 0 && chosen == nil)
            NSAccessibility.post(element: card.view, notification: Self.menuClosed)
        }
        cards.forEach { $0.child = nil }
        // Wakes the loop if it is waiting (a timer or VoiceOver closed it).
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: Self.wakeSubtype, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }

    private static let wakeSubtype: Int16 = 0x4154

    // MARK: Accessibility

    static let menuOpened = NSAccessibility.Notification(rawValue: "AXMenuOpened")
    static let menuClosed = NSAccessibility.Notification(rawValue: "AXMenuClosed")
    static let menuItemSelected = NSAccessibility.Notification(rawValue: "AXMenuItemSelected")

    // MARK: Key translation

    nonisolated static func keyEquivalent(_ event: NSEvent) -> KeyEquivalent? {
        switch event.keyCode {
        case 36, 76: return .return
        case 51: return .delete
        case 117: return .deleteForward
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        case 49: return .space
        case 48: return .tab
        case 53: return .escape
        default:
            guard let character = (event.charactersIgnoringModifiers ?? "").lowercased().first else { return nil }
            return KeyEquivalent(character)
        }
    }

    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

// MARK: - Icons

/// Draft C's leading icons for the commands that do not name their own
/// (the row menus were built for native menus, which drew none): looked up
/// by the command's localized title, so only these commands get one and a
/// submenu of choices (Today, Tomorrow…) keeps its plain rows, as drawn.
enum AtticMenuSymbols {
    static func symbol(for command: AtticMenuCommand) -> String? {
        command.systemImage ?? (command.isHeader ? nil : table[command.title])
    }

    private static let table: [String: String] = {
        let pairs: [(String.LocalizationValue, String)] = [
            ("Complete", "checkmark.circle"), ("Mark as Not Done", "circle"), ("Restore to Now", "arrow.uturn.backward.circle"),
            ("Start Working", "play.circle"), ("Stop Working", "stop.circle"), ("Edit Title", "pencil"),
            ("Date", "calendar"), ("Tags", "tag"), ("Priority", "flag"),
            ("Move to Later", "clock"), ("Move to Now", "sun.max"), ("Add Subtask", "plus.square"),
            ("Copy", "doc.on.doc"), ("Duplicate", "plus.square.on.square"), ("More", "ellipsis"),
            ("Delete", "trash"), ("Show Files", "paperclip"), ("Hide Files", "paperclip"),
            ("Move Up", "arrow.up"), ("Move Down", "arrow.down"), ("Rename", "pencil"), ("Pin", "pin"), ("Unpin", "pin.slash"),
        ]
        return Dictionary(pairs.map { (String(localized: $0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
    }()
}

// MARK: - Style

/// The colours and fonts a glass menu draws with: draft C on Attic's tokens.
struct AtticGlassMenuStyle {
    let design: AtticDesignContext
    let tokens: AtticColorTokens

    init(design: AtticDesignContext) {
        self.design = design
        tokens = design.tokens
    }

    var dark: Bool { design.mode == .dark }
    var reduceMotion: Bool { design.reduceMotion }
    /// Real glass, unless Reduce Transparency or the solid controls setting
    /// asks for the opaque card.
    var isGlass: Bool { AtticDropdownSurface.isGlass(design, capture: false) }
    var title: NSColor { tokens.ink(.body).nsColor }
    var icon: NSColor { tokens.ink(.icon).nsColor }
    var detail: NSColor { tokens.ink(.helper).nsColor }
    var header: NSColor { tokens.ink(.helper).nsColor }
    var disabled: NSColor { tokens.ink(.disabledText).nsColor }
    var destructive: NSColor { tokens.ink(.dueText).nsColor }
    var highlight: NSColor { tokens.dropdownHighlight.nsColor }
    var separator: NSColor { tokens.dropdownRule.nsColor }
    var fill: NSColor { tokens.popoverFill.nsColor }
    var rim: NSColor {
        if !isGlass { return tokens.popoverOuterRim.nsColor }
        return (design.increaseContrast ? AtticGlassModel.contrastEdge(dark: dark) : tokens.dropdownRim).nsColor
    }
    var rimWidth: CGFloat { design.increaseContrast ? AtticHairline.widthIncreased : AtticHairline.width }

    static let titleFont = NSFont.systemFont(ofSize: AtticTextStyle.dropdownRow.spec.size)
    static let detailFont = NSFont.systemFont(ofSize: AtticTextStyle.shortcut.spec.size)
    static let headerFont = NSFont.systemFont(ofSize: AtticTextStyle.dropdownSection.spec.size, weight: .semibold)

    /// An SF Symbol in one colour, cached.
    @MainActor static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)"
        if let cached = symbols[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        if symbols.count > 256 { symbols.removeAll() }
        symbols[key] = image
        return image
    }

    @MainActor private static var symbols: [String: NSImage] = [:]
}

// MARK: - Card

/// One level of a glass menu: its entries, its window and its view.
@MainActor
final class AtticGlassMenuCard {
    struct Entry {
        enum Kind {
            case item(AtticMenuCommand)
            case header(String)
            case separator
        }

        let kind: Kind
        /// In the card's flipped coordinates, before scrolling.
        let frame: NSRect

        var isSelectable: Bool {
            if case let .item(command) = kind { return !command.isDisabled }
            return false
        }
    }

    let level: Int
    let entries: [Entry]
    let size: CGSize
    let contentHeight: CGFloat
    let hasIcons: Bool
    let window: AtticGlassMenuWindow
    let view: AtticGlassMenuView
    private(set) var highlighted: Int?
    var child: AtticGlassMenuCard?
    var parentRow: Int?
    private(set) var scrollOffset: CGFloat = 0
    unowned let menu: AtticGlassMenu

    init(commands: [AtticMenuCommand], menu: AtticGlassMenu, level: Int, title: String? = nil) {
        self.menu = menu
        self.level = level
        let layout = Self.layout(commands)
        entries = layout.entries
        size = layout.size
        contentHeight = layout.size.height
        hasIcons = layout.hasIcons
        window = AtticGlassMenuWindow(size: layout.size)
        view = AtticGlassMenuView(frame: NSRect(origin: .zero, size: layout.size))
        view.card = self
        view.setAccessibilityLabel(title)
        window.install(view, style: menu.style)
    }

    /// The selectable rows, in order.
    var selectableIndices: [Int] { entries.indices.filter { entries[$0].isSelectable } }

    /// Room above the first row (the inset and a leading header), so a
    /// submenu's first row lines up with the row that opened it.
    var firstRowOffset: CGFloat {
        guard let first = entries.firstIndex(where: { if case .item = $0.kind { return true } else { return false } }) else { return 0 }
        return entries[first].frame.minY
    }

    // MARK: Layout (pure; tested)

    struct Layout {
        let entries: [Entry]
        let size: CGSize
        let hasIcons: Bool
    }

    /// Draft C's layout: rows 32 pt, 4 pt in; a separator (0.5 pt with 4 pt
    /// above and below) before each new section; a header row (26 pt) for
    /// a titled section; as wide as the widest row (never under 150 pt,
    /// never over 320 pt).
    static func layout(_ commands: [AtticMenuCommand]) -> Layout {
        let m = AtticDropdownMetrics.self
        let hasIcons = commands.contains { AtticMenuSymbols.symbol(for: $0) != nil || $0.image != nil || $0.swatch != nil }
        let leading = m.rowPadding + (hasIcons ? m.iconSlot + m.columnGap : 0)
        var widest: CGFloat = 0
        var kinds: [Entry.Kind] = []
        for (index, command) in commands.enumerated() {
            if command.isHeader {
                if index > 0 { kinds.append(.separator) }
                kinds.append(.header(command.title))
                widest = max(widest, m.rowPadding * 2 + ceil(measure(command.title, AtticGlassMenuStyle.headerFont)))
                continue
            }
            if command.startsSection, index > 0, !(commands[index - 1].isHeader) { kinds.append(.separator) }
            kinds.append(.item(command))
            widest = max(widest, leading + ceil(measure(command.title, AtticGlassMenuStyle.titleFont)) + trailingWidth(command) + m.rowPadding)
        }
        var y = m.inset
        var entries: [Entry] = []
        let width = min(AtticMenuMetrics.maxWidth, max(AtticMenuMetrics.minWidth, ceil(widest + m.inset * 2)))
        for kind in kinds {
            let height: CGFloat
            switch kind {
            case .item: height = m.rowHeight
            case .header: height = m.sectionHeaderHeight
            case .separator: height = m.separatorHeight
            }
            entries.append(Entry(kind: kind, frame: NSRect(x: m.inset, y: y, width: width - m.inset * 2, height: height)))
            y += height
        }
        return Layout(entries: entries, size: CGSize(width: width, height: y + m.inset), hasIcons: hasIcons)
    }

    /// What follows a row's title: a submenu's chevron, a detail, a tick.
    static func trailingWidth(_ command: AtticMenuCommand) -> CGFloat {
        let m = AtticDropdownMetrics.self
        var width: CGFloat = 0
        if !command.children.isEmpty { width += AtticMenuMetrics.trailingGap + AtticMenuMetrics.chevronSize }
        if let detail = command.detail { width += m.detailGap + ceil(measure(detail, AtticGlassMenuStyle.detailFont)) }
        if let state = command.state, state != .off { width += AtticMenuMetrics.trailingGap + m.checkSlot }
        return width
    }

    static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Geometry

    func place(_ frame: NSRect) {
        window.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// The row under a screen point, if any.
    func row(at point: NSPoint) -> Int? {
        let frame = window.frame
        guard frame.contains(point) else { return nil }
        let y = frame.maxY - point.y + scrollOffset
        let x = point.x - frame.minX
        return entries.indices.first { entries[$0].frame.minY <= y && y < entries[$0].frame.maxY && x >= entries[$0].frame.minX && x <= entries[$0].frame.maxX }
    }

    /// A row's top edge in screen coordinates.
    func screenTop(ofRow row: Int) -> CGFloat {
        window.frame.maxY - (entries[row].frame.minY - scrollOffset)
    }

    func scroll(by delta: CGFloat) {
        let most = max(0, contentHeight - window.frame.height)
        let next = max(0, min(most, scrollOffset - delta))
        guard next != scrollOffset else { return }
        scrollOffset = next
        view.needsDisplay = true
    }

    private func scrollToShow(_ row: Int) {
        let height = window.frame.height
        guard contentHeight > height else { return }
        let frame = entries[row].frame
        let inset = AtticDropdownMetrics.inset
        if frame.minY - scrollOffset < inset { scrollOffset = frame.minY - inset }
        if frame.maxY - scrollOffset > height - inset { scrollOffset = frame.maxY - height + inset }
        scrollOffset = max(0, min(contentHeight - height, scrollOffset))
    }

    // MARK: State

    func setHighlight(_ row: Int?) {
        guard row != highlighted else { return }
        highlighted = row
        if let row { scrollToShow(row) }
        view.needsDisplay = true
        view.displayIfNeeded()
        view.updateAccessibility()
        if let row, let element = view.element(for: row) {
            NSAccessibility.post(element: element, notification: AtticGlassMenu.menuItemSelected)
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    func closeSubmenu(of menu: AtticGlassMenu) {
        guard child != nil, let index = menu.cards.firstIndex(where: { $0 === self }) else { return }
        menu.openSubmenuClosing(after: index)
    }

    func show(fading: Bool) {
        #if DEBUG
        guard AtticGlassMenu.ordersCardsFront else { return }
        #endif
        if fading {
            window.alphaValue = 0
            window.orderFront(nil)
            window.invalidateShadow()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AtticMenuMetrics.openFade
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFront(nil)
            window.invalidateShadow()
        }
    }

    func hide(fading: Bool) {
        let window = self.window
        guard fading else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AtticMenuMetrics.closeFade
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }
}

extension AtticGlassMenu {
    /// Closes the cards after `index` (the keyboard moved off a submenu's
    /// row).
    fileprivate func openSubmenuClosing(after index: Int) {
        guard cards.count > index + 1 else { return }
        for card in cards[(index + 1)...] { card.hide(fading: false) }
        cards.removeSubrange((index + 1)...)
        cards[index].child = nil
        cards[index].view.updateAccessibility()
        if focus > index { focus = index }
    }
}

// MARK: - Window

/// A card's borderless, non-activating window: transparent, above the
/// panel, with the system's shadow following the card's rounded shape.
final class AtticGlassMenuWindow: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card: glass (or the opaque fallback), its rim, then the rows.
    @MainActor func install(_ rows: AtticGlassMenuView, style: AtticGlassMenuStyle) {
        let radius = AtticDropdownMetrics.cornerRadius
        let root = NSView(frame: rows.frame)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        rows.autoresizingMask = [.width, .height]
        if style.isGlass {
            let glass = NSGlassEffectView(frame: root.bounds)
            glass.cornerRadius = radius
            glass.style = .regular
            glass.autoresizingMask = [.width, .height]
            glass.contentView = rows
            root.addSubview(glass)
        } else {
            root.layer?.backgroundColor = style.fill.cgColor
            root.layer?.cornerRadius = radius
            root.layer?.cornerCurve = .continuous
            root.layer?.masksToBounds = true
            root.addSubview(rows)
        }
        let rim = NSView(frame: root.bounds)
        rim.wantsLayer = true
        rim.autoresizingMask = [.width, .height]
        rim.layer?.cornerRadius = radius
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = style.rimWidth
        rim.layer?.borderColor = style.rim.cgColor
        rim.setAccessibilityElement(false)
        root.addSubview(rim)
        contentView = root
        appearance = NSAppearance(named: style.dark ? .darkAqua : .aqua)
    }
}

// MARK: - View

/// A card's rows, drawn in one view (one layer for the whole list), with an
/// accessibility element per row: a menu of menu items, as `NSMenu`'s.
final class AtticGlassMenuView: NSView {
    weak var card: AtticGlassMenuCard?
    private var elements: [Int: AtticGlassMenuItemElement] = [:]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let card else { return }
        let style = card.menu.style
        let m = AtticDropdownMetrics.self
        NSGraphicsContext.current?.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: -card.scrollOffset)
        transform.concat()
        for (index, entry) in card.entries.enumerated() {
            let frame = entry.frame
            switch entry.kind {
            case .separator:
                style.separator.setFill()
                NSRect(x: frame.minX + m.separatorInset, y: frame.minY + m.separatorGap,
                       width: frame.width - m.separatorInset * 2, height: m.separator).fill()
            case let .header(title):
                let font = AtticGlassMenuStyle.headerFont
                let y = frame.maxY - m.sectionHeaderBottom - (font.ascender - font.descender)
                drawText(title, in: NSRect(x: frame.minX + m.rowPadding, y: y, width: frame.width - m.rowPadding * 2,
                                           height: font.ascender - font.descender), font: font, color: style.header)
            case let .item(command):
                let lit = card.highlighted == index || card.child?.parentRow == index
                if lit, !command.isDisabled {
                    style.highlight.setFill()
                    NSBezierPath(roundedRect: frame, xRadius: m.highlightRadius, yRadius: m.highlightRadius).fill()
                }
                drawItem(command, in: frame, card: card, style: style)
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawItem(_ command: AtticMenuCommand, in frame: NSRect, card: AtticGlassMenuCard, style: AtticGlassMenuStyle) {
        let m = AtticDropdownMetrics.self
        let ink: NSColor = command.isDisabled ? style.disabled : (command.isDestructive ? style.destructive : style.title)
        let iconInk: NSColor = command.isDisabled ? style.disabled : (command.isDestructive ? style.destructive : style.icon)
        var x = frame.minX + m.rowPadding
        if card.hasIcons {
            let slot = NSRect(x: x, y: frame.midY - m.iconSlot / 2, width: m.iconSlot, height: m.iconSlot)
            if command.state == .mixed, command.systemImage != nil {
                drawImage(AtticGlassMenuStyle.symbol("minus", size: m.iconSize, color: iconInk), centeredIn: slot)
            } else if let name = AtticMenuSymbols.symbol(for: command) {
                drawImage(AtticGlassMenuStyle.symbol(name, size: m.iconSize, color: iconInk), centeredIn: slot)
            } else if let image = command.image {
                drawImage(image, centeredIn: slot)
            } else if let swatch = command.swatch {
                let dot = NSRect(x: slot.midX - m.dotSize / 2, y: slot.midY - m.dotSize / 2, width: m.dotSize, height: m.dotSize)
                style.tokens.tagInk(swatch).nsColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            x += m.iconSlot + m.columnGap
        }
        var trailing = frame.maxX - m.rowPadding
        if !command.children.isEmpty {
            let size = AtticMenuMetrics.chevronSize
            drawImage(AtticGlassMenuStyle.symbol("chevron.right", size: size, weight: .medium, color: command.isDisabled ? style.disabled : style.detail),
                      centeredIn: NSRect(x: trailing - size, y: frame.midY - size / 2, width: size, height: size))
            trailing -= size + AtticMenuMetrics.trailingGap
        }
        if let state = command.state, state != .off {
            let slot = NSRect(x: trailing - m.checkSlot, y: frame.midY - m.checkSlot / 2, width: m.checkSlot, height: m.checkSlot)
            drawImage(AtticGlassMenuStyle.symbol(state == .on ? "checkmark" : "minus", size: m.checkSize, weight: .semibold, color: ink),
                      centeredIn: slot)
            trailing -= m.checkSlot + AtticMenuMetrics.trailingGap
        }
        if let detail = command.detail {
            let font = AtticGlassMenuStyle.detailFont
            let width = ceil(AtticGlassMenuCard.measure(detail, font))
            drawText(detail, in: NSRect(x: trailing - width, y: frame.midY - (font.ascender - font.descender) / 2, width: width,
                                        height: font.ascender - font.descender), font: font, color: style.detail)
            trailing -= width + m.detailGap
        }
        let font = AtticGlassMenuStyle.titleFont
        drawText(command.title, in: NSRect(x: x, y: frame.midY - (font.ascender - font.descender) / 2, width: max(0, trailing - x),
                                           height: font.ascender - font.descender), font: font, color: ink)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawImage(_ image: NSImage?, centeredIn slot: NSRect) {
        guard let image else { return }
        let size = image.size
        let rect = NSRect(x: (slot.midX - size.width / 2).rounded(), y: (slot.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Accessibility (a menu of menu items)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }

    override func accessibilityChildren() -> [Any]? {
        guard let card else { return [] }
        return card.entries.indices.compactMap { element(for: $0) }
    }

    func element(for row: Int) -> AtticGlassMenuItemElement? {
        guard let card, card.entries.indices.contains(row), case let .item(command) = card.entries[row].kind else { return nil }
        if let element = elements[row] { return element }
        let element = AtticGlassMenuItemElement(command: command, row: row, view: self)
        elements[row] = element
        return element
    }

    /// The rows' states changed (highlight, an open submenu).
    func updateAccessibility() {
        guard let card else { return }
        for (row, element) in elements {
            element.setAccessibilitySelected(card.highlighted == row)
            element.setAccessibilityFrameInParentSpace(card.entries[row].frame.offsetBy(dx: 0, dy: -card.scrollOffset))
        }
    }

    override func mouseMoved(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
}

/// One row for VoiceOver: a menu item with its title, its enabled state,
/// its mark (✓ or –, as `NSMenuItem` reports it) and, for a submenu, its
/// open card as its child. Pressing it chooses the command or opens the
/// submenu.
final class AtticGlassMenuItemElement: NSAccessibilityElement {
    let command: AtticMenuCommand
    let row: Int
    weak var view: AtticGlassMenuView?

    @MainActor init(command: AtticMenuCommand, row: Int, view: AtticGlassMenuView) {
        self.command = command
        self.row = row
        self.view = view
        super.init()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(command.title)
        setAccessibilityTitle(command.title)
        setAccessibilityEnabled(!command.isDisabled)
        setAccessibilityParent(view)
        if let identifier = command.identifier { setAccessibilityIdentifier(identifier) }
        if let card = view.card {
            setAccessibilityFrameInParentSpace(card.entries[row].frame.offsetBy(dx: 0, dy: -card.scrollOffset))
            setAccessibilitySelected(card.highlighted == row)
        }
        if command.state == .mixed { setAccessibilityValue(String(localized: "some selected tasks")) }
        if let detail = command.detail { setAccessibilityHelp(detail) }
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let view, let card = view.card, let index = card.menu.cards.firstIndex(where: { $0 === card }) else { return false }
            card.menu.activate(card: index, row: row, byKeyboard: true)
            return true
        }
    }

    override func accessibilityChildren() -> [Any]? {
        MainActor.assumeIsolated {
            guard let card = view?.card, let child = card.child, child.parentRow == row else { return [] }
            return [child.view]
        }
    }

    @available(macOS, deprecated: 10.10, message: "Only the accessibility server calls it")
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        let names = super.accessibilityAttributeNames()
        return names.contains(AtticDropdownMenuItem.markCharAttribute) ? names : names + [AtticDropdownMenuItem.markCharAttribute]
    }

    @available(macOS, deprecated: 10.10, message: "Only the accessibility server calls it")
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attribute == AtticDropdownMenuItem.markCharAttribute else { return super.accessibilityAttributeValue(attribute) }
        return AtticDropdownMenuItem.markChar(command.state)
    }
}

// MARK: - Context menus

/// `atticContextMenu`'s anchors: a right-click (or ⌃-click) on one opens its
/// commands as a glass menu at the pointer. The innermost anchor under the
/// pointer wins (a tag's colour menu inside its row's menu). A press on an
/// editable text view keeps the system's own text menu.
@MainActor
enum AtticContextMenus {
    private static var monitor: Any?
    private static let anchors = NSHashTable<AtticContextMenuAnchor.AnchorView>.weakObjects()

    static func register(_ view: AtticContextMenuAnchor.AnchorView) {
        anchors.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { route(event) }
        }
    }

    static func isContextPress(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    /// The anchor a press is on: the smallest one containing it.
    static func anchor(for event: NSEvent) -> AtticContextMenuAnchor.AnchorView? {
        guard let window = event.window else { return nil }
        var best: (view: AtticContextMenuAnchor.AnchorView, area: CGFloat)?
        // What AppKit would hit there: an anchor under another view (a
        // section drawn over a kept page, a card's own window) opens nothing.
        let content = window.contentView
        let hit = content?.hitTest(content?.convert(event.locationInWindow, from: nil) ?? .zero)
        for view in anchors.allObjects where view.window === window && view.build != nil && Self.isShown(view) {
            if let hit, !Self.shares(hit, with: view) { continue }
            let local = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(local) else { continue }
            let area = view.bounds.width * view.bounds.height
            if best.map({ area < $0.area }) ?? true { best = (view, area) }
        }
        return best?.view
    }

    /// No hidden or fully transparent view holds it.
    static func isShown(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let next = current {
            if next.isHidden || next.alphaValue == 0 || next.layer?.opacity == 0 { return false }
            current = next.superview
        }
        return true
    }

    /// The hit view is the anchor's own SwiftUI hosting view or inside it.
    static func shares(_ hit: NSView, with anchor: NSView) -> Bool {
        var host = anchor.superview
        while let view = host, !String(describing: type(of: view)).contains("HostingView") { host = view.superview }
        guard let host else { return true }
        return hit === host || hit.isDescendant(of: host)
    }

    /// The commands a press would open (the menus, and tests in place of
    /// `NSView.menu(for:)`).
    static func commands(for event: NSEvent) -> [AtticMenuCommand]? {
        anchor(for: event)?.build?()
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        guard isContextPress(event), AtticGlassMenu.current == nil, let window = event.window,
              let anchor = anchor(for: event) else { return event }
        // An editable or selectable text view keeps its own menu (Cut, Copy,
        // Paste, Spelling).
        if let hit = window.contentView?.hitTest(window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero) {
            if let text = hit as? NSTextView, text.isEditable || text.isSelectable { return event }
            if let field = hit as? NSTextField, field.isEditable { return event }
        }
        let location = event.locationInWindow
        DispatchQueue.main.async {
            guard let content = anchor.window?.contentView, let commands = anchor.build?(), !commands.isEmpty else { return }
            AtticGlassMenu.popUp(commands, in: content, placement: .point(content.convert(location, from: nil)), opener: event)
        }
        guard event.type == .leftMouseDown else { return event }
        // ⌃-click is a secondary click: the views under it see a right
        // press, never a click that would toggle or select.
        return NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: event.modifierFlags.subtracting(.control),
                                  timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                  eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) ?? event
    }
}

/// The view behind a SwiftUI view that has a glass context menu.
struct AtticContextMenuAnchor: NSViewRepresentable {
    let build: () -> [AtticMenuCommand]

    final class AnchorView: NSView {
        var build: (() -> [AtticMenuCommand])?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { AtticContextMenus.register(self) }
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { view.build = build }
}

extension View {
    /// A right-click (⌃-click) menu of `commands` on draft C's glass, in
    /// place of SwiftUI's native `.contextMenu`. The commands are built
    /// only when the menu opens. VoiceOver's Show Menu opens it too.
    func atticContextMenu(_ build: @escaping () -> [AtticMenuCommand]) -> some View {
        modifier(AtticContextMenuModifier(build: build))
    }
}

private struct AtticContextMenuModifier: ViewModifier {
    let build: () -> [AtticMenuCommand]
    @State private var anchor = AtticMenuAnchor.Holder()
    @Environment(\.atticCapture) private var capture

    func body(content: Content) -> some View {
        // `ImageRenderer` captures cannot draw AppKit views: no anchors
        // there (as `.contextMenu` drew nothing).
        if capture != nil {
            content
        } else {
            anchored(content)
        }
    }

    private func anchored(_ content: Content) -> some View {
        content
            .background(AtticContextMenuAnchor(build: build).accessibilityHidden(true))
            .background(AtticMenuAnchor(holder: anchor).accessibilityHidden(true))
            .accessibilityAction(.showMenu) {
                guard let view = anchor.view else { return }
                AtticGlassMenu.popUpLater(build(), in: view, placement: .below(view.bounds), opener: nil)
            }
    }
}
