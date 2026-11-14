import AppKit
import SwiftUI
import ObjectiveC

/// A custom AppKit control's actual menu hit region, including drawn controls.
@MainActor
protocol AtticMenuTrigger: AnyObject {
    func opensAtticMenu(for event: NSEvent) -> Bool
}

// MARK: - Glass menus (Loam's, Accepted 2026-11-10)
//
// The look, placement and motion follow Loam's `GlassMenu.swift` (MIT,
// commit e2e1f56, https://github.com/Azilone/Loam.md); its values are
// ported here onto Attic's own AppKit card (no Loam code is copied).

/// Attic's command menus on glass: the right-click menus, ⋯ and ⇧⌘I, and
/// every other menu built from `AtticMenuCommand`s, in Loam's glass menu
/// (Accepted 2026-11-10). Each level is its own floating card of real
/// system glass with 18 pt corners, 6 pt padding, 28 pt rows, a 20 pt icon
/// column, a shortcut or value at the trailing edge and a highlight that
/// slides from row to row; a submenu is a separate card beside its row.
/// A card comes out of the control that opened it (leading or trailing
/// edge by the control's side of the panel, 8 pt away, opening toward the
/// panel's middle), grows from that corner on a spring while its rows
/// arrive one after another, and shrinks back toward it as it closes.
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
        /// Out of the rect (a button): see `rootPlacement`.
        case below(NSRect)
    }

    /// The same, in screen coordinates.
    enum ScreenPlacement: Equatable {
        case point(CGPoint)
        case below(NSRect)
    }

    /// The corner of a card it grows from and shrinks toward: the one by
    /// the control (or the pointer) that opened it.
    enum Corner: Equatable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    }

    /// The menu tracking now (one at a time, as with `NSMenu`).
    private(set) static var current: AtticGlassMenu?
    /// An accessibility action or a second trigger can request a menu while
    /// the previous one's nested tracking loop is still unwinding. Keep the
    /// last request so its click cannot silently disappear.
    private static var pendingRequest: Request?
    private static var requestScheduled = false
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
    private var openingAnchor: NSRect?
    /// The window that opened the menu (the panel, mostly).
    var sourceWindow: NSWindow? { source }
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

    /// Snapshot the source window and trigger geometry *before* deferring.
    /// SwiftUI can replace the anchor during the click that requests a menu;
    /// looking up `view.window` on the next turn silently lost that click.
    private struct Request {
        let commands: [AtticMenuCommand]
        let screen: ScreenPlacement
        let window: NSWindow
        let appearance: NSAppearance
        let opener: NSEvent?
    }

    private static func request(_ commands: [AtticMenuCommand], in view: NSView,
                                placement: Placement, opener: NSEvent?) -> Request? {
        guard let window = view.window, !commands.isEmpty else { return nil }
        let screen: ScreenPlacement
        switch placement {
        case let .point(point):
            let inWindow = view.convert(point, to: nil)
            screen = .point(window.convertPoint(toScreen: inWindow))
        case let .below(rect):
            screen = .below(window.convertToScreen(view.convert(rect, to: nil)))
        }
        return Request(commands: commands, screen: screen, window: window,
                       appearance: window.effectiveAppearance, opener: opener)
    }

    /// Opens the menu and tracks it until it closes, then runs the chosen
    /// command (as a menu choice, `AtticTextInput.choosing`). Returns the
    /// command chosen, if any.
    @discardableResult
    static func popUp(_ commands: [AtticMenuCommand], in view: NSView, placement: Placement,
                      opener: NSEvent? = NSApp.currentEvent) -> AtticMenuCommand? {
        guard let request = request(commands, in: view, placement: placement, opener: opener) else { return nil }
        return popUp(request)
    }

    @discardableResult
    private static func popUp(_ request: Request) -> AtticMenuCommand? {
        guard request.window.contentView != nil else { return nil }
        if let current {
            pendingRequest = request
            current.close()
            return nil
        }
        pendingRequest = nil
        let window = request.window
        let menu = AtticGlassMenu(request.commands, appearance: request.appearance, opener: request.opener)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        // Kept inside the panel when it fits (Menu look picks, placement B).
        let panel = (window as? AtticPanel)?.visibleContentFrame
        menu.open(request.screen, visible: visible, source: window, container: window.frame, panel: panel)
        current = menu
        let info: [AnyHashable: Any]? = request.opener.map { [openerKey: $0] }
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
        // Tracking has returned to the normal event loop. Open the newest
        // request on its next turn so the previous card can finish closing.
        schedulePendingRequest()
        guard let chosen = menu.chosen else { return nil }
        AtticTextInput.choosing(chosen.menuShortcut, chosen.action)
        return chosen
    }

    /// Opens on the next turn of the run loop, after the caller's own event.
    /// Use the snapshotted window and placement even when SwiftUI has already
    /// detached the specific anchor that was under the pointer.
    static func popUpLater(_ commands: [AtticMenuCommand], in view: NSView, placement: Placement,
                           opener: NSEvent? = NSApp.currentEvent) {
        guard let request = request(commands, in: view, placement: placement, opener: opener) else { return }
        pendingRequest = request
        if let current { current.close() }
        else { schedulePendingRequest() }
    }

    private static func schedulePendingRequest() {
        guard pendingRequest != nil, !requestScheduled else { return }
        requestScheduled = true
        DispatchQueue.main.async {
            requestScheduled = false
            guard current == nil, let next = pendingRequest else { return }
            pendingRequest = nil
            popUp(next)
        }
    }

    /// Builds and shows the root card (no event loop: `track` runs it).
    /// `container`: the source window's frame, whose halves decide which
    /// edge of a control the card lines up with and which way it opens.
    func open(_ placement: ScreenPlacement, visible: NSRect, source: NSWindow?, container: NSRect? = nil, panel: NSRect? = nil) {
        self.visible = visible
        self.source = source
        if case let .below(rect) = placement { openingAnchor = rect }
        else { openingAnchor = nil }
        var minimum: CGFloat = 0
        if case let .below(rect) = placement { minimum = rect.width }
        let card = AtticGlassMenuCard(commands: commands, menu: self, level: 0, minimumWidth: minimum)
        var placed = Self.rootPlacement(size: card.size, placement: placement, visible: visible, container: container)
        if let panel { placed = Self.keptInside(panel: panel, placed, placement: placement) }
        card.place(placed.frame)
        cards = [card]
        focus = 0
        isOpen = true
        card.show(animated: true, from: placed.corner)
        NSAccessibility.post(element: card.view, notification: Self.menuOpened)
    }

    // MARK: Placement (pure; tested)

    /// The root card's frame.
    static func rootFrame(size: CGSize, placement: ScreenPlacement, visible: NSRect, container: NSRect? = nil) -> NSRect {
        rootPlacement(size: size, placement: placement, visible: visible, container: container).frame
    }

    /// The root card's frame and the corner it grows from. From a point
    /// (a right-click): its top-left at the point, flipped to the left of
    /// it at the screen's right edge, moved up at its bottom. From a
    /// control (Accepted 2026-11-10): 8 pt out of it, lined up with its
    /// leading edge, or its trailing edge when the control is on the
    /// right half of `container` (the panel); opening toward the panel's
    /// middle (up from a control on its lower half, down from one on its
    /// upper half), on the other side when only that fits, else kept
    /// inside the screen over the control, as before. Never past the
    /// visible frame's margin; a card taller than the screen is capped
    /// (its rows scroll).
    static func rootPlacement(size: CGSize, placement: ScreenPlacement, visible: NSRect,
                              container: NSRect? = nil) -> (frame: NSRect, corner: Corner) {
        let m = AtticMenuMetrics.screenMargin
        let height = min(size.height, visible.height - m * 2)
        var x: CGFloat
        var top: CGFloat
        let leading: Bool
        let fromTop: Bool
        switch placement {
        case let .point(point):
            x = point.x
            top = point.y
            if x + size.width > visible.maxX - m { x = point.x - size.width }
            if top - height < visible.minY + m { top = visible.minY + m + height }
            leading = x >= point.x - 0.5
            fromTop = top <= point.y + 0.5
        case let .below(rect):
            let gap = AtticMenuMetrics.anchorGap
            let trailing = container.map { rect.midX > $0.midX } ?? false
            let upward = container.map { rect.midY < $0.midY } ?? false
            x = trailing ? rect.maxX - size.width : rect.minX
            let belowTop = rect.minY - gap
            let aboveBottom = rect.maxY + gap
            let fitsBelow = belowTop - height >= visible.minY + m
            let fitsAbove = aboveBottom + height <= visible.maxY - m
            var up = upward
            if up, !fitsAbove, fitsBelow { up = false } else if !up, !fitsBelow, fitsAbove { up = true }
            if up {
                top = fitsAbove ? aboveBottom + height : visible.maxY - m
            } else {
                top = fitsBelow ? belowTop : visible.minY + m + height
            }
            if x + size.width > visible.maxX - m { x = visible.maxX - m - size.width }
            leading = !trailing
            fromTop = !up
        }
        x = max(visible.minX + m, min(x, visible.maxX - m - size.width))
        top = min(top, visible.maxY - m)
        let corner: Corner = fromTop ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing)
        return (NSRect(x: x, y: top - height, width: size.width, height: height), corner)
    }

    /// Placement B (Menu look picks, Accepted 2026-11-13): the card kept
    /// inside the panel's visible surface, 8 pt in, when it fits there
    /// without covering what opened it. From a point (a right-clicked row)
    /// it flips left, and opens upward from the pointer when it can't fit
    /// below; it never slides over the pointer's row. From a control it
    /// stays on its side, or flips to the other side when only that fits,
    /// never covering the control. Otherwise the screen rule, hanging past
    /// the panel as before.
    static func keptInside(panel: NSRect, _ placed: (frame: NSRect, corner: Corner),
                           placement: ScreenPlacement) -> (frame: NSRect, corner: Corner) {
        let inner = panel.insetBy(dx: AtticMenuMetrics.panelInset, dy: AtticMenuMetrics.panelInset)
        var frame = placed.frame
        guard frame.height <= inner.height, frame.width <= inner.width else { return placed }
        var corner = placed.corner
        let leading = corner == .topLeading || corner == .bottomLeading
        switch placement {
        case let .point(point):
            if frame.maxX > inner.maxX { frame.origin.x = point.x - frame.width }
            // Below the pointer, or above it; never over it (the owner
            // turned down lifting the task menu over its own task).
            let fitsBelow = point.y - frame.height >= inner.minY && point.y <= inner.maxY
            let fitsAbove = point.y + frame.height <= inner.maxY && point.y >= inner.minY
            if fitsBelow {
                frame.origin.y = point.y - frame.height
            } else if fitsAbove {
                frame.origin.y = point.y
            } else {
                return placed
            }
            let flipped = frame.minX < point.x - 0.5
            let fromTop = fitsBelow
            corner = fromTop ? (flipped ? .topTrailing : .topLeading) : (flipped ? .bottomTrailing : .bottomLeading)
        case let .below(rect):
            let gap = AtticMenuMetrics.anchorGap
            let fitsBelow = rect.minY - gap - frame.height >= inner.minY
            let fitsAbove = rect.maxY + gap + frame.height <= inner.maxY
            let down = corner == .topLeading || corner == .topTrailing
            if down ? fitsBelow : !fitsAbove && fitsBelow {
                frame.origin.y = rect.minY - gap - frame.height
                corner = leading ? .topLeading : .topTrailing
            } else if fitsAbove {
                frame.origin.y = rect.maxY + gap
                corner = leading ? .bottomLeading : .bottomTrailing
            } else {
                return placed
            }
        }
        frame.origin.x = max(inner.minX, min(frame.minX, inner.maxX - frame.width))
        return (frame, corner)
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
                // Give a click on a second menu trigger to that trigger.
                // Swallowing its down event left only a mouse-up for SwiftUI,
                // so a click on ⋯ while another menu tracked opened nothing.
                // Only registered triggers get that press: ordinary controls
                // must not act on the click used to dismiss a menu.
                let pressesOpener = event.window === source && openingAnchor?.contains(Self.screenPoint(of: event)) == true
                let opensMenu = !pressesOpener && AtticContextMenus.isMenuTrigger(for: event)
                close()
                if opensMenu {
                    NSApp.postEvent(event, atStart: true)
                }
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
        cards.indices.reversed().first { cards[$0].frame.contains(point) }
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
        let child = AtticGlassMenuCard(commands: command.children, menu: self, level: index + 1, title: command.title,
                                       width: command.menuWidth)
        child.parentRow = row
        let rowTop = parent.screenTop(ofRow: row)
        let frame = Self.submenuFrame(size: child.size, parent: parent.frame, rowTop: rowTop,
                                      firstRowOffset: child.firstRowOffset, visible: visible)
        child.place(frame)
        parent.child = child
        cards.append(child)
        parent.refreshHighlight(animated: false)
        // It grows out of its row: from its top corner by the parent.
        child.show(animated: true, from: frame.minX >= parent.frame.midX ? .topLeading : .topTrailing)
        parent.view.updateAccessibility()
        NSAccessibility.post(element: child.view, notification: Self.menuOpened)
    }

    private func closeCards(after index: Int) {
        guard cards.count > index + 1 else { return }
        for card in cards[(index + 1)...] {
            card.hide(animated: true)
            NSAccessibility.post(element: card.view, notification: Self.menuClosed)
        }
        cards.removeSubrange((index + 1)...)
        cards[index].child = nil
        cards[index].refreshHighlight(animated: false)
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
            card.hide(animated: animated)
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
/// by the command's localized title. One icon family, on every row of a
/// command menu or on none (Dropdown content: answers, owner, 2026-10-24,
/// rule 2): a choice (a row with a tick state: dates, priorities, sorts)
/// never takes one from this table, so a choice list carries only its own
/// marks (a dot, ↓ ! !!) or nothing, and View Options' "Priority" sort is
/// not given the Priority command's flag.
enum AtticMenuSymbols {
    static func symbol(for command: AtticMenuCommand) -> String? {
        if let name = command.systemImage { return name }
        guard !command.isHeader, command.state == nil else { return nil }
        return table[command.title]
    }

    /// The rows of a command menu that draw no icon, mark or dot: empty
    /// when the menu keeps the one-family rule (tests read it).
    static func rowsWithoutIcons(_ commands: [AtticMenuCommand]) -> [String] {
        commands.filter { !$0.isHeader && symbol(for: $0) == nil && $0.image == nil && $0.swatch == nil && $0.priority == nil }
            .map(\.title)
    }

    private static let table: [String: String] = {
        let pairs: [(String.LocalizationValue, String)] = [
            // The task menu (sheet 1).
            ("Complete", "checkmark.circle"), ("Mark as Not Done", "circle"), ("Restore to Now", "arrow.uturn.backward.circle"),
            ("Start Working", "play.circle"), ("Stop Working", "stop.circle"), ("Edit Title", "pencil"),
            ("Show Details", "info.circle"), ("Close Details", "info.circle"),
            ("Date", "calendar"), ("Tags", "tag"), ("Priority", "flag"),
            ("Move to Backlog", "clock"), ("Move to Now", "sun.max"), ("Add Subtask", "plus"),
            ("Copy", "doc.on.doc"), ("Duplicate", "plus.square.on.square"), ("More", "ellipsis.circle"),
            ("Delete", "trash"),
            ("Move Up", "arrow.up"), ("Move Down", "arrow.down"), ("Rename", "pencil"), ("Pin", "pin"), ("Unpin", "pin.slash"),
            // The subtask and note row menus (sheet 2).
            ("Move to Task…", "arrow.turn.up.right"), ("Make Standalone Task", "arrow.up.left.square"),
            ("Open Page", "doc.text"), ("Pin to Top", "pin"), ("Unpin from Top", "pin.slash"),
            ("Filter by Tag", "line.3.horizontal.decrease"), ("Copy as Markdown", "doc.on.doc"), ("Delete Note", "trash"),
            // The one-item commands (sheets 1, 2 and 5; C2).
            ("Add to Tasks", "checkmark.circle"), ("Remove from Tasks", "minus.circle"),
            ("Make Checkbox", "checkmark.square"), ("Add Files…", "doc.badge.plus"),
            // The note's ⋯ (sheet 5).
            ("Tags…", "tag"), ("Version History", "clock.arrow.circlepath"), ("Print…", "printer"),
            ("Save Recovery Copy…", "square.and.arrow.down"), ("Insert", "plus"), ("Format", "textformat"),
            ("Paragraph", "text.alignleft"), ("Text", "bold"), ("Lists", "list.bullet"), ("Line", "increase.indent"),
            // The panel and Recently Deleted (sheet 5).
            ("Pin Panel", "pin"), ("Unpin Panel", "pin.slash"), ("Settings…", "gearshape"),
            ("Restore", "arrow.uturn.backward"), ("Select All", "checklist"), ("Delete Permanently…", "trash"),
            // History (sheet 4).
            ("Copy This Version", "doc.on.doc"),
        ]
        return Dictionary(pairs.map { (String(localized: $0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
    }()
}

// MARK: - Style

/// The colours and fonts a glass menu draws with: Loam's menu on Attic's
/// tokens.
@MainActor
struct AtticGlassMenuStyle {
    let design: AtticDesignContext
    let tokens: AtticColorTokens

    init(design: AtticDesignContext) {
        self.design = design
        tokens = design.tokens
    }

    var dark: Bool { design.mode == .dark }
    var reduceMotion: Bool { design.reduceMotion }
    /// The active system menu's glass (Accepted 12 Nov evening) on Glass
    /// and Frosted; the opaque fallback on Solid or Reduce Transparency.
    /// The controls setting does not change a menu card.
    var isSeeThrough: Bool { AtticSurfaceInk.seeThrough(tokens) }
    var title: NSColor { tokens.ink(.body).nsColor }
    var icon: NSColor { tokens.ink(.icon).nsColor }
    var detail: NSColor { secondary(.meta) }
    /// Lighter headers, as the system menu draws them (owner, 12 Nov:
    /// version 3 of menu-versions-drafts.html); Increase Contrast keeps the token.
    var header: NSColor { design.increaseContrast ? secondary(.groupHeader) : title.withAlphaComponent(0.45) }
    /// A disabled row (title, icon, chevron, shortcut): the title's ink at
    /// 30 %, 50 % under Increase Contrast (menu review #6, 12 Nov). Always
    /// lighter than the 45 % headers, never the shortcuts' grey, in both
    /// appearances, as the system orders them (tertiary under secondary).
    var disabled: NSColor {
        title.withAlphaComponent(title.alphaComponent * (design.increaseContrast ? 0.5 : 0.3))
    }
    var destructive: NSColor {
        // The system red in Light and Dark (Menu look picks B, Accepted
        // 2026-11-13).
        var red = NSColor.systemRed
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            red = NSColor.systemRed.usingColorSpace(.sRGB) ?? red
        }
        return red
    }
    /// The highlight: 8 % ink (16 % under Increase Contrast).
    var highlight: NSColor {
        tokens.dropdownHighlight.nsColor
    }
    var separator: NSColor { tokens.dropdownRule.nsColor }
    var rim: NSColor {
        if !isSeeThrough { return tokens.popoverOuterRim.nsColor }
        return (design.increaseContrast ? AtticGlassModel.contrastEdge(dark: dark) : AtticMenuLook.outline(dark: dark)).nsColor
    }
    var rimWidth: CGFloat { design.increaseContrast ? AtticHairline.widthIncreased : AtticHairline.width }
    var shadow: NSColor { tokens.dropdownShadow.nsColor }

    /// The menu keeps the panel's ink policy: see-through on Glass and
    /// Frosted, opaque and floored on Solid.
    private func secondary(_ tone: AtticPanelTone) -> NSColor {
        AtticSurfaceInk.toneInk(tone, tokens: tokens).nsColor
    }

    /// The panel's colour ink: vivid on a see-through surface only.
    func colourInk(_ colour: AtticRGBA) -> AtticRGBA {
        AtticSurfaceInk.vivid(colour, tokens: tokens)
    }

    /// Regular weight, as the system menu (owner, 12 Nov: version 3, with Attic's grey hover).
    static let titleFont = NSFont.systemFont(ofSize: AtticMenuMetrics.titleSize, weight: .regular)
    static let detailFont = NSFont.systemFont(ofSize: AtticMenuMetrics.detailSize)
    static let headerFont = NSFont.systemFont(ofSize: AtticMenuMetrics.headerSize, weight: .semibold)
    /// The rows' icons: regular, as the titles (menu review #7, 12 Nov;
    /// medium icons were the heaviest ink on a quiet row).
    static let iconWeight: NSFont.Weight = .regular

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

/// The menus' shape (Accepted 2026-11-10): 18 pt continuous corners, 6 pt
/// padding and 8 pt rows' highlight (Corners B, measured fix).
enum AtticGlassMenuShape {
    static let radius: CGFloat = AtticMenuMetrics.cardRadius
    static let inset: CGFloat = AtticMenuMetrics.cardPadding
    static let rowRadius: CGFloat = AtticMenuMetrics.highlightRadius
    /// The highlight on a row this tall: 8 pt, or half the row when that
    /// is smaller, so a very short row stays a capsule at most.
    static func rowRadius(height: CGFloat) -> CGFloat { min(rowRadius, height / 2) }
    /// Loam's card: Apple's continuous rounded rectangle at 18 pt. Attic's
    /// surface squircle at 18 pt read as tight, ~8 pt corners (owner, 11 Nov).
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension AtticMenuCommand {
    /// The shortcut drawn at a row's trailing edge (⇧⌘I), for a command
    /// whose shortcut has a modifier; a bare key's is a hint of the list's.
    var glassShortcut: String? {
        guard let shortcut = menuShortcut else { return nil }
        let m = shortcut.modifiers
        var text = ""
        if m.contains(.control) { text += "⌃" }
        if m.contains(.option) { text += "⌥" }
        if m.contains(.shift) { text += "⇧" }
        if m.contains(.command) { text += "⌘" }
        switch shortcut.key {
        case .return: text += "↩"
        case .space: text += String(localized: "Space")
        case .delete: text += "⌫"
        case .deleteForward: text += "⌦"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .escape: text += "⎋"
        case .tab: text += "⇥"
        default: text += String(shortcut.key.character).uppercased()
        }
        return text
    }

    /// What a row shows at its trailing edge: its value, else its shortcut.
    var glassTrailingText: String? { detail ?? glassShortcut }
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

        var isItem: Bool {
            if case .item = kind { return true }
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
    /// The card on screen (its window adds a margin for the shadow and
    /// the spring's overshoot).
    private(set) var frame: NSRect = .zero
    private(set) var highlighted: Int?
    var child: AtticGlassMenuCard?
    var parentRow: Int?
    private(set) var scrollOffset: CGFloat = 0
    /// The corner it grew from, which it shrinks back toward.
    private var corner: AtticGlassMenu.Corner = .topLeading
    private var isHidden = false
    /// The hole under the card in the panel it covers, while it is shown.
    private var backdropHole: AtticMenuBackdropHole?
    unowned let menu: AtticGlassMenu

    init(commands: [AtticMenuCommand], menu: AtticGlassMenu, level: Int, title: String? = nil, width: CGFloat? = nil,
         minimumWidth: CGFloat = 0) {
        self.menu = menu
        self.level = level
        let layout = Self.layout(commands, width: width, minimum: minimumWidth)
        entries = layout.entries
        size = layout.size
        contentHeight = layout.size.height
        hasIcons = layout.hasIcons
        window = AtticGlassMenuWindow(size: layout.size)
        view = AtticGlassMenuView(frame: NSRect(origin: .zero, size: layout.size))
        view.card = self
        view.setAccessibilityLabel(title)
        window.install(view, style: menu.style)
        view.build()
    }

    /// The selectable rows, in order.
    var selectableIndices: [Int] { entries.indices.filter { entries[$0].isSelectable } }

    /// Room above the first row (the inset and a leading header), so a
    /// submenu's first row lines up with the row that opened it.
    var firstRowOffset: CGFloat {
        guard let first = entries.firstIndex(where: \.isItem) else { return 0 }
        return entries[first].frame.minY
    }

    // MARK: Layout (pure; tested)

    struct Layout {
        let entries: [Entry]
        let size: CGSize
        let hasIcons: Bool
    }

    /// The picked 28 pt rows inside 6 pt of padding, with compact ruled
    /// groups and their headings. As wide as `minimum` (the control that
    /// opened it) and at least 200 pt, or `width` when named; wider when its
    /// rows need it, up to 280 pt, past which a row is cut short.
    static func layout(_ commands: [AtticMenuCommand], width declared: CGFloat? = nil, minimum: CGFloat = 0) -> Layout {
        let m = AtticMenuMetrics.self
        let hasIcons = commands.contains {
            AtticMenuSymbols.symbol(for: $0) != nil || $0.image != nil || $0.swatch != nil || $0.priority != nil
        }
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
            widest = max(widest, leading + ceil(measure(command.title, command.titleFont ?? AtticGlassMenuStyle.titleFont))
                         + trailingWidth(command) + m.rowPadding)
        }
        var y = AtticGlassMenuShape.inset
        var entries: [Entry] = []
        let fit = min(m.maxWidth, ceil(widest + AtticGlassMenuShape.inset * 2))
        let width = max(m.minWidth, minimum.rounded(.up), declared ?? 0, fit)
        for kind in kinds {
            let height: CGFloat
            switch kind {
            case .item: height = m.rowHeight
            case .header: height = m.headerHeight
            case .separator: height = m.separatorHeight
            }
            entries.append(Entry(kind: kind, frame: NSRect(x: AtticGlassMenuShape.inset, y: y, width: width - AtticGlassMenuShape.inset * 2, height: height)))
            y += height
        }
        return Layout(entries: entries, size: CGSize(width: width, height: y + AtticGlassMenuShape.inset), hasIcons: hasIcons)
    }

    /// What follows a row's title: a value or shortcut, a tick, a
    /// submenu's chevron.
    static func trailingWidth(_ command: AtticMenuCommand) -> CGFloat {
        let m = AtticDropdownMetrics.self
        var width: CGFloat = 0
        if !command.children.isEmpty { width += AtticMenuMetrics.trailingGap + AtticMenuMetrics.chevronSize }
        if let text = command.glassTrailingText { width += m.detailGap + ceil(measure(text, AtticGlassMenuStyle.detailFont)) }
        if let state = command.state, state != .off { width += AtticMenuMetrics.trailingGap + m.checkSlot }
        return width
    }

    static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Geometry

    /// Puts the card at `frame` (screen); its window takes the margin.
    func place(_ frame: NSRect) {
        self.frame = frame
        let margin = AtticMenuMetrics.windowMargin
        window.setFrame(frame.insetBy(dx: -margin, dy: -margin), display: false)
        window.layoutCard(size: frame.size)
        view.layoutContent()
    }

    /// The row under a screen point, if any.
    func row(at point: NSPoint) -> Int? {
        guard frame.contains(point) else { return nil }
        let y = frame.maxY - point.y + scrollOffset
        let x = point.x - frame.minX
        return entries.indices.first { entries[$0].frame.minY <= y && y < entries[$0].frame.maxY && x >= entries[$0].frame.minX && x <= entries[$0].frame.maxX }
    }

    /// A row's frame in the rows' view, for its accessibility element.
    /// AppKit reads an element's frame in its parent's space bottom-up,
    /// whatever the view's flip, so the row is turned over here (flipped,
    /// every item reported its mirror row, and a pointer sent to the first
    /// item landed on the last).
    func accessibilityFrame(ofRow row: Int) -> NSRect {
        let entry = entries[row].frame.offsetBy(dx: 0, dy: -scrollOffset)
        return NSRect(x: entry.minX, y: view.bounds.height - entry.maxY, width: entry.width, height: entry.height)
    }

    /// A row's top edge in screen coordinates.
    func screenTop(ofRow row: Int) -> CGFloat {
        frame.maxY - (entries[row].frame.minY - scrollOffset)
    }

    func scroll(by delta: CGFloat) {
        let most = max(0, contentHeight - frame.height)
        let next = max(0, min(most, scrollOffset - delta))
        guard next != scrollOffset else { return }
        scrollOffset = next
        view.layoutContent()
        view.updateAccessibility()
    }

    private func scrollToShow(_ row: Int) {
        let height = frame.height
        guard contentHeight > height else { return }
        let rowFrame = entries[row].frame
        let inset = AtticGlassMenuShape.inset
        var offset = scrollOffset
        if rowFrame.minY - offset < inset { offset = rowFrame.minY - inset }
        if rowFrame.maxY - offset > height - inset { offset = rowFrame.maxY - height + inset }
        offset = max(0, min(contentHeight - height, offset))
        guard offset != scrollOffset else { return }
        scrollOffset = offset
        view.layoutContent()
    }

    // MARK: State

    func setHighlight(_ row: Int?) {
        guard row != highlighted else { return }
        highlighted = row
        if let row { scrollToShow(row) }
        refreshHighlight(animated: true)
        view.updateAccessibility()
        if let row, let element = view.element(for: row) {
            NSAccessibility.post(element: element, notification: AtticGlassMenu.menuItemSelected)
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    /// The lit row: the highlighted one, else the row whose submenu is out.
    var litRow: Int? {
        let row = highlighted ?? child?.parentRow
        guard let row, entries.indices.contains(row), entries[row].isSelectable else { return nil }
        return row
    }

    func refreshHighlight(animated: Bool) {
        view.moveHighlight(to: litRow.map { entries[$0].frame }, animated: animated && !menu.style.reduceMotion)
    }

    func closeSubmenu(of menu: AtticGlassMenu) {
        guard child != nil, let index = menu.cards.firstIndex(where: { $0 === self }) else { return }
        menu.openSubmenuClosing(after: index)
    }

    // MARK: Motion

    /// Orders the card in: it grows from `corner` (0.86 → 1) and fades in
    /// on the spring while its rows arrive one after another; under Reduce
    /// Motion it only fades.
    func show(animated: Bool, from corner: AtticGlassMenu.Corner) {
        let animated = animated && (!menu.style.reduceMotion || AtticReducedMotionStyle.current == .fade)
        self.corner = corner
        window.alphaValue = 1
        #if DEBUG
        // Tests: built and animated, never ordered on screen.
        if AtticGlassMenu.ordersCardsFront {
            window.orderFront(nil)
            backdropHole = AtticMenuBackdropHole.open(under: frame, in: menu.sourceWindow, corner: corner, animated: animated, style: menu.style)
        }
        #else
        window.orderFront(nil)
        backdropHole = AtticMenuBackdropHole.open(under: frame, in: menu.sourceWindow, corner: corner, animated: animated, style: menu.style)
        #endif
        guard animated else { return }
        let lift: AtticGlassMenuLiftView = window.lift
        let reduce = menu.style.reduceMotion
        if reduce {
            lift.layer?.add(AtticMenuMotion.fade(from: 0, to: 1, duration: AtticMenuMetrics.openFade, easeIn: false), forKey: "attic.open.fade")
            return
        }
        lift.layer?.add(AtticMenuMotion.spring("opacity", from: 0, to: 1, duration: AtticMenuMetrics.openDuration,
                                               bounce: AtticMenuMetrics.openBounce), forKey: "attic.open.fade")
        if let layer = lift.layer {
            let small = AtticMenuMotion.scale(AtticMenuMetrics.startScale, about: corner, in: layer)
            layer.add(AtticMenuMotion.spring("transform", from: NSValue(caTransform3D: small),
                                             to: NSValue(caTransform3D: CATransform3DIdentity),
                                             duration: AtticMenuMetrics.openDuration, bounce: AtticMenuMetrics.openBounce),
                      forKey: "attic.open.grow")
        }
        view.playEntrance(fromTop: corner.isTop)
    }

    /// Orders the card out: an ease-in 0.12 s fade and shrink toward the
    /// corner it grew from (a fade only under Reduce Motion); at once when
    /// not `animated`.
    func hide(animated: Bool) {
        let animated = animated && (!menu.style.reduceMotion || AtticReducedMotionStyle.current == .fade)
        guard !isHidden else { return }
        isHidden = true
        let window = self.window
        window.ignoresMouseEvents = true
        backdropHole?.close(animated: animated && window.isVisible, reduceMotion: menu.style.reduceMotion)
        backdropHole = nil
        guard animated, window.isVisible, let layer = window.lift.layer else {
            window.orderOut(nil)
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
        let fade = AtticMenuMotion.fade(from: layer.presentation()?.opacity ?? 1, to: 0, duration: AtticMenuMetrics.closeFade, easeIn: true)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "attic.close.fade")
        if !menu.style.reduceMotion {
            let from = layer.presentation()?.transform ?? CATransform3DIdentity
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: from)
            shrink.toValue = NSValue(caTransform3D: AtticMenuMotion.scale(AtticMenuMetrics.startScale, about: corner, in: layer))
            shrink.duration = AtticMenuMetrics.closeFade
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.removeAnimation(forKey: "attic.open.grow")
            layer.add(shrink, forKey: "attic.close.shrink")
        }
        layer.removeAnimation(forKey: "attic.open.fade")
        CATransaction.commit()
    }
}

/// The menus' Core Animation: springs with SwiftUI's duration and bounce
/// (`CASpringAnimation(perceptualDuration:bounce:)`), fades, and a scale
/// about a corner of a layer.
@MainActor
enum AtticMenuMotion {
    static func spring(_ keyPath: String, from: Any, to: Any, duration: TimeInterval, bounce: CGFloat,
                       delay: TimeInterval = 0) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        if delay > 0 { animation.beginTime = CACurrentMediaTime() + delay }
        animation.fillMode = .backwards
        return animation
    }

    static func fade(from: Float, to: Float, duration: TimeInterval, easeIn: Bool) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeIn : .easeOut)
        animation.fillMode = .backwards
        return animation
    }

    /// `scale` about `corner` of `layer` (its own coordinates, whatever its
    /// anchor point and flip).
    static func scale(_ scale: CGFloat, about corner: AtticGlassMenu.Corner, in layer: CALayer) -> CATransform3D {
        let bounds = layer.bounds
        let flipped = layer.contentsAreFlipped()
        let top = flipped ? bounds.minY : bounds.maxY
        let bottom = flipped ? bounds.maxY : bounds.minY
        let point = CGPoint(x: corner.isLeading ? bounds.minX : bounds.maxX, y: corner.isTop ? top : bottom)
        let anchor = CGPoint(x: bounds.minX + layer.anchorPoint.x * bounds.width, y: bounds.minY + layer.anchorPoint.y * bounds.height)
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        var transform = CATransform3DMakeTranslation(-dx, -dy, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(dx, dy, 0))
    }
}

// MARK: - The panel under a card

/// A window whose own surface a menu card replaces where it covers it: the
/// panel. The card's native glass blurs what is under it, and over the
/// panel that was the panel's rows (ghosted grey text and tag smudges in
/// the card) on the panel's glass, not the desktop the panel's own glass
/// blurs. So while a card is shown, the panel's page and surface are cut
/// away under it and the card's glass sees the desktop, as the panel does:
/// one material, not glass on glass.
@MainActor
protocol AtticMenuBackdropHost: AnyObject {
    /// The view to cut (the panel's page and surface), or nil.
    var menuBackdropView: NSView? { get }
}

/// The cut under one card, in its host view's layer mask: the card's shape,
/// 3 pt in, so no desktop shows at the card's edge. It grows from the card's
/// corner on the card's own spring and the page under it fades as the card
/// fades in (back as it fades out), so it follows the card's live frame and
/// nothing pops. Several cards (a submenu over the panel) chain their masks,
/// each multiplying the last. Only on a see-through surface: a Solid card
/// already covers what is under it.
@MainActor
final class AtticMenuBackdropHole {
    /// Every host's open cuts, in mask order.
    private static var chains: [ObjectIdentifier: [AtticMenuBackdropHole]] = [:]
    /// The cut stays this far inside the card. 1 pt let a 1 px sliver of
    /// the desktop show at the card's moving edge as it grew (the panel's
    /// window draws the cut a few ms ahead of the card's window); 3 pt keeps
    /// the cut under the card at every frame on the Air.
    private static let edgeInset: CGFloat = 3

    private weak var host: NSView?
    /// The whole host (the mask), holding `cut`.
    let mask = CALayer()
    /// The card's place in the host: the outside opaque, the card a hole.
    let cut = CALayer()
    /// The page under the card, fading out as the card fades in.
    let page = CAShapeLayer()
    /// The card's corner, which the cut grows from and shrinks toward.
    private var corner: AtticGlassMenu.Corner = .topLeading
    private var isClosed = false

    private init(host: NSView, frame: NSRect) {
        self.host = host
        mask.frame = host.bounds
        cut.frame = frame
        let card = AtticGlassMenuShape.card.path(in: CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.edgeInset, dy: Self.edgeInset)).cgPath
        let outside = CAShapeLayer()
        let room = max(host.bounds.width, host.bounds.height) * 4 + 1000
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: frame.size).insetBy(dx: -room, dy: -room))
        path.addPath(card)
        outside.path = path
        outside.fillRule = .evenOdd
        outside.fillColor = NSColor.black.cgColor
        outside.frame = cut.bounds
        // 1 pt past the hole's edge: two shapes meeting edge to edge left a
        // faint antialiased outline of the cut while the page was whole
        // (the open's first frames, the close's last).
        page.path = AtticGlassMenuShape.card.path(in: CGRect(origin: .zero, size: frame.size)
            .insetBy(dx: Self.edgeInset - 1, dy: Self.edgeInset - 1)).cgPath
        page.fillColor = NSColor.black.cgColor
        page.frame = cut.bounds
        page.opacity = 0
        cut.addSublayer(outside)
        cut.addSublayer(page)
        mask.addSublayer(cut)
    }

    /// Cuts the card's place (`frame`, screen) out of `window`'s surface,
    /// with the card's open motion; nil when there is nothing to cut.
    static func open(under frame: NSRect, in window: NSWindow?, corner: AtticGlassMenu.Corner, animated: Bool,
                     style: AtticGlassMenuStyle) -> AtticMenuBackdropHole? {
        guard style.isSeeThrough, AtticMenuSurfaceSeam.cutsPanel,
              let window, let host = (window as? AtticMenuBackdropHost)?.menuBackdropView,
              host.window === window, let layer = host.layer else { return nil }
        let local = host.convert(window.convertFromScreen(frame), from: nil)
        guard local.intersects(host.bounds) else { return nil }
        let key = ObjectIdentifier(host)
        // Another mask is the host's own: leave it be.
        if layer.mask != nil, chains[key]?.first?.mask !== layer.mask { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hole = AtticMenuBackdropHole(host: host, frame: local)
        hole.corner = corner
        chains[key, default: []].append(hole)
        relink(key, layer: layer)
        CATransaction.commit()
        guard animated else { return hole }
        if style.reduceMotion {
            let fade = AtticMenuMotion.fade(from: 1, to: 0, duration: AtticMenuMetrics.openFade, easeIn: false)
            hole.page.add(fade, forKey: "attic.open.fade")
        } else {
            // The page fades a beat behind the card, so the desktop never
            // shows through a card still fading in.
            hole.page.add(AtticMenuMotion.spring("opacity", from: 1, to: 0, duration: AtticMenuMetrics.openDuration,
                                                 bounce: AtticMenuMetrics.openBounce, delay: AtticMenuMetrics.openFade / 2),
                          forKey: "attic.open.fade")
            let small = AtticMenuMotion.scale(AtticMenuMetrics.startScale, about: corner, in: hole.cut)
            hole.cut.add(AtticMenuMotion.spring("transform", from: NSValue(caTransform3D: small),
                                                to: NSValue(caTransform3D: CATransform3DIdentity),
                                                duration: AtticMenuMetrics.openDuration, bounce: AtticMenuMetrics.openBounce),
                         forKey: "attic.open.grow")
        }
        return hole
    }

    /// Gives the page back: ahead of the card's fade-out and with its
    /// shrink, then the cut is gone.
    func close(animated: Bool, reduceMotion: Bool) {
        guard !isClosed else { return }
        isClosed = true
        guard animated, host != nil else { remove(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated { self.remove() }
        }
        let back = AtticMenuMotion.fade(from: page.presentation()?.opacity ?? 0, to: 1,
                                        duration: AtticMenuMetrics.closeFade / 2, easeIn: false)
        back.fillMode = .forwards
        back.isRemovedOnCompletion = false
        page.removeAnimation(forKey: "attic.open.fade")
        page.add(back, forKey: "attic.close.fade")
        if !reduceMotion {
            let from = cut.presentation()?.transform ?? CATransform3DIdentity
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: from)
            shrink.toValue = NSValue(caTransform3D: AtticMenuMotion.scale(AtticMenuMetrics.startScale, about: corner, in: cut))
            shrink.duration = AtticMenuMetrics.closeFade
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            cut.removeAnimation(forKey: "attic.open.grow")
            cut.add(shrink, forKey: "attic.close.shrink")
        }
        CATransaction.commit()
    }

    private func remove() {
        guard let host else { return }
        let key = ObjectIdentifier(host)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.chains[key]?.removeAll { $0 === self }
        if Self.chains[key]?.isEmpty == true { Self.chains[key] = nil }
        if let layer = host.layer { Self.relink(key, layer: layer, removing: self) }
        CATransaction.commit()
    }

    /// The host's mask is the first cut's; each cut's mask, the next's.
    private static func relink(_ key: ObjectIdentifier, layer: CALayer, removing gone: AtticMenuBackdropHole? = nil) {
        let holes = chains[key] ?? []
        gone?.mask.mask = nil
        for hole in holes { hole.mask.mask = nil }
        layer.mask = holes.first?.mask
        for index in holes.indices.dropLast() { holes[index].mask.mask = holes[index + 1].mask }
    }

    #if DEBUG
    /// Tests: the open cuts in `view`'s mask.
    static func cuts(in view: NSView) -> [AtticMenuBackdropHole] { chains[ObjectIdentifier(view)] ?? [] }
    #endif
}

/// Capture seam (`ATTIC_UI_TEST_MENU_SURFACE`, with `ATTIC_UI_TESTING=1`,
/// preview identities only): a comma list that brings back round 1's card
/// piece by piece, to measure each cause on screen. `inshadow`: the shadow
/// fills the card under its glass; `nocut`: the panel stays under the card;
/// `cardsize`: the native glass at the card's own size.
/// Which menu Attic opens, and the system menu's look on Attic's card
/// (owner, 12 Nov: the system menu's Liquid Glass, "but the same shape
/// and card as what we had before … improved"). Measured on macOS 27 from
/// an `NSMenu`: its face is a plain `NSGlassEffectView` (regular, no tint),
/// its outline a dark hairline at the edge (black 30 % Light, 85 % Dark),
/// its shadow soft and mostly below (about 22 % at the edge, gone 15 pt
/// out).
enum AtticMenuLook {
    /// The system's `NSMenu` instead of Attic's card.
    static let native = false
    /// From a control: this far out of it.
    static let gap: CGFloat = 4

    /// No drawn outline (owner, 12 Nov: the system menu has none; its edge
    /// is the glass's own light rim).
    static func outline(dark: Bool) -> AtticRGBA { .black(0) }

    /// Liquid Glass: `NSGlassEffectView`, regular, untinted, nothing over
    /// it. Over bold stripes on macOS 27 this is the one that lets colour
    /// through like the real `NSMenu` does (12 Nov). NSMenu's private "menu"
    /// sub-variant, used outside a real menu window, frosts to a pale fog,
    /// and the white wash used to match the menu's brightness over light
    /// backgrounds hid the glass (owner: "but are they glass?").
    static func glass(frame: NSRect, cornerRadius: CGFloat) -> NSGlassEffectView {
        let glass = AtticActiveMenuGlassView(frame: frame)
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        return glass
    }

    /// Nothing over the glass.
    static func lift(dark: Bool) -> AtticRGBA { .white(0) }
}

/// AppKit asks the *window* about activity, even for a glass view embedded
/// in SwiftUI. Lease that appearance while a picker is attached, without
/// making its window key or changing the panel's first-mouse policy.
final class AtticActiveMenuGlassView: NSGlassEffectView {
    private weak var leasedWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if leasedWindow !== newWindow {
            if let leasedWindow { AtticMenuGlassActivity.release(leasedWindow) }
            leasedWindow = nil
            if let newWindow, !(newWindow is AtticGlassMenuWindow) {
                AtticMenuGlassActivity.acquire(newWindow)
                leasedWindow = newWindow
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// These are the same private AppKit queries that NSPopupMenuWindow and
/// AtticGlassMenuWindow answer. The intercept forwards to AppKit unchanged
/// for every unleased window; a weak, counted lease covers nested pickers.
/// Keeping the forwarding on NSWindow also covers Settings and mini windows.
@MainActor
private enum AtticMenuGlassActivity {
    private static let leases = NSMapTable<NSWindow, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let installed: Bool = {
        let pairs = [("_hasActiveAppearanceIgnoringKeyFocus", "attic_menuHasActiveAppearance"),
                     ("_hasActiveControls", "attic_menuHasActiveControls")]
        let methods = pairs.compactMap { original, replacement -> (Method, Method)? in
            guard let first = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(original)),
                  let second = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(replacement)) else { return nil }
            return (first, second)
        }
        guard methods.count == pairs.count else { return false }
        for (first, second) in methods { method_exchangeImplementations(first, second) }
        return true
    }()

    static func contains(_ window: NSWindow) -> Bool { (leases.object(forKey: window)?.intValue ?? 0) > 0 }

    static func acquire(_ window: NSWindow) {
        guard installed else { return }
        let count = leases.object(forKey: window)?.intValue ?? 0
        leases.setObject(NSNumber(value: count + 1), forKey: window)
        if count == 0 { refresh(window) }
    }

    static func release(_ window: NSWindow) {
        let count = leases.object(forKey: window)?.intValue ?? 0
        guard count > 0 else { return }
        if count == 1 { leases.removeObject(forKey: window); refresh(window) }
        else { leases.setObject(NSNumber(value: count - 1), forKey: window) }
    }

    private static func refresh(_ window: NSWindow) {
        // Joining/leaving a hierarchy can happen in SwiftUI's layout pass.
        // Ask for the native appearance refresh after that pass has ended.
        DispatchQueue.main.async { [weak window] in
            let selector = NSSelectorFromString("_sendForcedWindowChangedKeyState")
            if let window, window.responds(to: selector) { _ = window.perform(selector) }
        }
    }
}

extension NSWindow {
    @objc dynamic fileprivate func attic_menuHasActiveAppearance() -> Bool {
        AtticMenuGlassActivity.contains(self) || attic_menuHasActiveAppearance()
    }

    @objc dynamic fileprivate func attic_menuHasActiveControls() -> Bool {
        AtticMenuGlassActivity.contains(self) || attic_menuHasActiveControls()
    }
}

/// The system menu's glass in SwiftUI (the picker cards).
struct AtticMenuGlassView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        AtticMenuLook.glass(frame: .zero, cornerRadius: cornerRadius)
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
    }
}

enum AtticMenuSurfaceSeam {
    #if DEBUG
    nonisolated static let flags: Set<String> = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1", AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier),
              let list = environment["ATTIC_UI_TEST_MENU_SURFACE"] else { return [] }
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()
    #else
    nonisolated static let flags: Set<String> = []
    #endif
    nonisolated static var interiorShadow: Bool { flags.contains("inshadow") }
    /// Off with Craft's frosted face (12 Nov quick look): the card blurs
    /// what lies under it, the panel included, as Craft's does.
    nonisolated static var cutsPanel: Bool { flags.contains("cut") }
    nonisolated static var cardSizedGlass: Bool { flags.contains("cardsize") }
}

extension AtticGlassMenu {
    /// Closes the cards after `index` (the keyboard moved off a submenu's
    /// row).
    fileprivate func openSubmenuClosing(after index: Int) {
        guard cards.count > index + 1 else { return }
        for card in cards[(index + 1)...] { card.hide(animated: true) }
        cards.removeSubrange((index + 1)...)
        cards[index].child = nil
        cards[index].refreshHighlight(animated: false)
        cards[index].view.updateAccessibility()
        if focus > index { focus = index }
    }
}

// MARK: - Window

/// A card's borderless, non-activating window: transparent, above the
/// panel, with room around the card for its own shadow (drawn by the card,
/// so it grows and fades with it) and the spring's overshoot.
final class AtticGlassMenuWindow: NSPanel {
    /// The card's moving layer (it scales and fades), its shadow with it.
    private(set) var lift: AtticGlassMenuLiftView!
    private var root: AtticGlassMenuRootView!

    init(size: CGSize) {
        let margin = AtticMenuMetrics.windowMargin
        super.init(contentRect: NSRect(origin: .zero, size: CGSize(width: size.width + margin * 2, height: size.height + margin * 2)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        acceptsMouseMovedEvents = true
        // Set explicitly: by default the window server passes a point over
        // this clear window's see-through pixels (the glass is composited by
        // the window server, not drawn into the window) to the window below.
        // The system's accessibility hit test (VoiceOver's pointer, a UI
        // test's hit point) then finds the panel, not the card's item.
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The system menu's own window (`NSPopupMenuWindow`) never becomes key
    // either, but it overrides these two to say it is active, so its Liquid
    // Glass draws the active look: brighter, a glossy rim, lensed edges.
    // Without them this window's glass draws the inactive look, flatter and
    // greyer (owner, 12 Nov: "its not the same glass at all"). Private AppKit
    // methods, read and measured on macOS 27; if a later macOS drops them
    // these are never called and the glass falls back to the inactive look.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }

    /// The rows' view (the card's menu for accessibility).
    var rows: AtticGlassMenuView? { root?.subviews.lazy.compactMap { $0 as? AtticGlassMenuView }.first }
    /// The card's clipping view (its squircle mask).
    var cardView: NSView? { root }

    /// The pointer's accessibility hit is the row's menu item, as over an
    /// `NSMenu` (VoiceOver's pointer, a UI test's hit point). The rows'
    /// view takes no AppKit hits, so the window's own hit test stopped at
    /// the material's hosting view, which is hidden from accessibility.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard frame.contains(point), let rows else { return super.accessibilityHitTest(point) }
        return rows.accessibilityHitTest(point)
    }

    /// The card: glass (or the opaque fallback), its rim, then the rows,
    /// in a lift with its shadow, inside the margin.
    @MainActor func install(_ rows: AtticGlassMenuView, style: AtticGlassMenuStyle) {
        let margin = AtticMenuMetrics.windowMargin
        let stage = NSView(frame: NSRect(origin: .zero, size: frame.size))
        stage.wantsLayer = true
        let lift = AtticGlassMenuLiftView(frame: NSRect(x: margin, y: margin, width: rows.frame.width, height: rows.frame.height))
        lift.shadowColor = style.shadow
        let root = AtticGlassMenuRootView(frame: lift.bounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        rows.frame = root.bounds
        rows.autoresizingMask = [.width, .height]
        // The system menu's own face (12 Nov): AppKit's NSGlassEffectView,
        // regular, untinted, as NSMenu draws it; SwiftUI adds the outline
        // (and the opaque fill on Solid). Rows remain AppKit's views with
        // the existing native menu accessibility.
        if style.isSeeThrough {
            let glass = AtticMenuLook.glass(frame: root.bounds, cornerRadius: AtticGlassMenuShape.radius)
            glass.autoresizingMask = [.width, .height]
            root.addSubview(glass)
        }
        let face = NSHostingView(rootView: AtticGlassMenuSurface(style: style, nativeGlass: style.isSeeThrough))
        face.frame = root.bounds
        face.autoresizingMask = [.width, .height]
        root.addSubview(face)
        root.addSubview(rows)
        lift.addSubview(root)
        stage.addSubview(lift)
        contentView = stage
        self.lift = lift
        self.root = root
        appearance = NSAppearance(named: style.dark ? .darkAqua : .aqua)
    }

    /// The card at `size` inside the margin (a capped card is shorter).
    @MainActor func layoutCard(size: CGSize) {
        let margin = AtticMenuMetrics.windowMargin
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
        lift.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        lift.layoutSubtreeIfNeeded()
    }
}

/// The card's moving part: it scales from its corner and fades, with its
/// shadow (the glass's own shape), as one layer.
///
/// The shadow falls outside the card only. The card's native glass blurs
/// whatever lies under it, its own window's shadow included: a shadow
/// filling the card's shape (a layer shadow) greyed the glass from within,
/// so the card read darker than the panel over the same backdrop (owner,
/// 12 Nov: "it's not even the same glass").
final class AtticGlassMenuLiftView: NSView {
    var shadowColor: NSColor = .clear
    /// Holds the shadow, masked to outside the card.
    private let shadowHost = NSView()
    private let shadowCaster = CALayer()
    private let outside = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadowHost.wantsLayer = true
        shadowHost.frame = bounds
        shadowHost.autoresizingMask = [.width, .height]
        addSubview(shadowHost)
        shadowHost.layer?.addSublayer(shadowCaster)
        outside.fillRule = .evenOdd
        outside.fillColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let layer, let host = shadowHost.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = false
        host.masksToBounds = false
        let colour = shadowColor.usingColorSpace(.sRGB) ?? shadowColor
        let card = AtticGlassMenuShape.card.path(in: bounds).cgPath
        shadowCaster.frame = host.bounds
        shadowCaster.shadowColor = colour.withAlphaComponent(1).cgColor
        shadowCaster.shadowOpacity = Float(colour.alphaComponent)
        shadowCaster.shadowRadius = AtticShadows.dropdown.radius
        shadowCaster.shadowOffset = CGSize(width: 0, height: host.contentsAreFlipped() ? AtticShadows.dropdown.y : -AtticShadows.dropdown.y)
        shadowCaster.shadowPath = card
        if AtticMenuSurfaceSeam.interiorShadow {
            host.mask = nil
        } else {
            let room = AtticMenuMetrics.windowMargin * 4
            let path = CGMutablePath()
            path.addRect(host.bounds.insetBy(dx: -room, dy: -room))
            path.addPath(card)
            outside.frame = host.bounds
            outside.path = path
            host.mask = outside
        }
        CATransaction.commit()
    }
}

/// Rows and material share one contour, including when placement caps a
/// long card's height. No scrolled highlight may draw past that contour.
private final class AtticGlassMenuRootView: NSView {
    private let clip = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = clip
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.path = AtticGlassMenuShape.card.path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// The card's face: Liquid Glass (`AtticGlassCardFace`, owner's
/// 12 Nov quick look), with the menus' own shape, rim and rows.
struct AtticGlassMenuSurface: View {
    let style: AtticGlassMenuStyle
    /// The glass is AppKit's view under this one: draw only the outline.
    var nativeGlass = false

    var body: some View {
        let shape = AtticGlassMenuShape.card
        Group {
            if nativeGlass { shape.fill(AtticMenuLook.lift(dark: style.dark).color) } else { AtticGlassCardFace(shape: shape, tokens: style.tokens, dark: style.dark) }
        }
            .environment(\.atticDesign, style.design)
            .overlay {
                shape.inset(by: style.rimWidth / 2)
                    .stroke(Color(nsColor: style.rim), lineWidth: style.rimWidth)
            }
            .environment(\.colorScheme, style.dark ? .dark : .light)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - View

/// A card's rows: one view per entry inside a scrolling content view, and
/// the highlight as its own layer under them (it slides from row to row);
/// with an accessibility element per row: a menu of menu items, as
/// `NSMenu`'s.
final class AtticGlassMenuView: NSView {
    weak var card: AtticGlassMenuCard?
    private var elements: [Int: AtticGlassMenuItemElement] = [:]
    private let content = AtticGlassMenuFlippedView()
    private let highlight = AtticGlassMenuFlippedView()
    private var entryViews: [AtticGlassMenuEntryView] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The entries' views and the highlight, once the card is set.
    func build() {
        guard let card else { return }
        content.wantsLayer = true
        addSubview(content)
        highlight.wantsLayer = true
        highlight.isHidden = true
        highlight.layer?.cornerRadius = AtticGlassMenuShape.rowRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = card.menu.style.highlight.cgColor
        content.addSubview(highlight)
        for index in card.entries.indices {
            let entry = AtticGlassMenuEntryView(frame: card.entries[index].frame)
            entry.index = index
            entry.menuView = self
            entry.wantsLayer = true
            content.addSubview(entry)
            entryViews.append(entry)
        }
        layoutContent()
    }

    /// The content at the card's scroll.
    func layoutContent() {
        guard let card else { return }
        content.frame = NSRect(x: 0, y: -card.scrollOffset, width: bounds.width, height: max(card.contentHeight, bounds.height))
    }

    /// The highlight onto `frame` (content coordinates), sliding there on
    /// 0.20 s without bounce when `animated` and already shown; nil hides
    /// it.
    func moveHighlight(to frame: NSRect?, animated: Bool) {
        guard let frame else {
            highlight.isHidden = true
            return
        }
        highlight.layer?.cornerRadius = AtticGlassMenuShape.rowRadius(height: frame.height)
        guard let layer = highlight.layer, animated, !highlight.isHidden, highlight.frame != frame else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.frame = frame
            highlight.isHidden = false
            CATransaction.commit()
            return
        }
        let fromPosition = (layer.presentation() ?? layer).position
        let fromBounds = (layer.presentation() ?? layer).bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = frame
        CATransaction.commit()
        let duration = AtticMenuMetrics.highlightDuration
        layer.add(AtticMenuMotion.spring("position", from: NSValue(point: fromPosition), to: NSValue(point: layer.position),
                                         duration: duration, bounce: 0), forKey: "attic.highlight.position")
        layer.add(AtticMenuMotion.spring("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds),
                                         duration: duration, bounce: 0), forKey: "attic.highlight.bounds")
    }

    /// The rows arrive one after another, 30 ms apart (at most 240 ms),
    /// each fading in and sliding 6 pt from the side of the control.
    func playEntrance(fromTop: Bool) {
        guard let card else { return }
        var number = 0
        for view in entryViews where card.entries[view.index].isItem {
            guard let layer = view.layer else { continue }
            let delay = AtticMenuMetrics.stagger(number)
            number += 1
            // Toward the control: up for a card opening down. "Up" in the
            // row's superlayer depends on its effective flip.
            let up: CGFloat = (layer.superlayer?.contentsAreFlipped() ?? false) ? -1 : 1
            let travel = AtticMenuMetrics.rowTravel * up * (fromTop ? 1 : -1)
            layer.add(AtticMenuMotion.spring("opacity", from: 0, to: 1, duration: AtticMenuMetrics.rowDuration,
                                             bounce: AtticMenuMetrics.rowBounce, delay: delay), forKey: "attic.row.fade")
            layer.add(AtticMenuMotion.spring("transform", from: NSValue(caTransform3D: CATransform3DMakeTranslation(0, travel, 0)),
                                             to: NSValue(caTransform3D: CATransform3DIdentity), duration: AtticMenuMetrics.rowDuration,
                                             bounce: AtticMenuMetrics.rowBounce, delay: delay), forKey: "attic.row.slide")
        }
    }

    /// Draws entry `index` in its own view's coordinates.
    func drawEntry(_ index: Int) {
        guard let card, card.entries.indices.contains(index) else { return }
        let style = card.menu.style
        let m = AtticMenuMetrics.self
        let entry = card.entries[index]
        let frame = NSRect(origin: .zero, size: entry.frame.size)
        switch entry.kind {
        case .separator:
            style.separator.setFill()
            Self.separatorRect(in: frame, scale: window?.backingScaleFactor ?? layer?.contentsScale ?? 2).fill()
        case let .header(title):
            let font = AtticGlassMenuStyle.headerFont
            let y = frame.maxY - m.headerBottom - (font.ascender - font.descender)
            drawText(title, in: NSRect(x: frame.minX + m.rowPadding, y: y, width: frame.width - m.rowPadding * 2,
                                       height: font.ascender - font.descender), font: font, color: style.header)
        case let .item(command):
            drawItem(command, in: frame, card: card, style: style)
        }
    }

    /// A separator's hairline, `separatorInset` in from the band's sides
    /// and centred on it, on the backing pixel grid (menu review #3, 12 Nov:
    /// centred at y 5.25 on its 11 pt band, the 0.5 pt line straddled two
    /// device pixels at half strength). The band's own origin is whole
    /// points, so whole device pixels here are whole pixels in the layer.
    static func separatorRect(in frame: NSRect, scale: CGFloat) -> NSRect {
        let m = AtticMenuMetrics.self
        let scale = max(scale, 1)
        let height = max((AtticHairline.width * scale).rounded(), 1) / scale
        let y = ((frame.midY - height / 2) * scale).rounded(.down) / scale
        return NSRect(x: frame.minX + m.separatorInset, y: y, width: frame.width - m.separatorInset * 2, height: height)
    }

    private func drawItem(_ command: AtticMenuCommand, in frame: NSRect, card: AtticGlassMenuCard, style: AtticGlassMenuStyle) {
        let m = AtticMenuMetrics.self
        let d = AtticDropdownMetrics.self
        let ink: NSColor = command.isDisabled ? style.disabled : (command.isDestructive ? style.destructive : style.title)
        let iconInk: NSColor = command.isDisabled ? style.disabled : (command.isDestructive ? style.destructive : style.icon)
        var x = frame.minX + m.rowPadding
        if card.hasIcons {
            let slot = NSRect(x: x, y: frame.midY - m.iconSlot / 2, width: m.iconSlot, height: m.iconSlot)
            if command.state == .mixed, command.systemImage != nil {
                drawImage(AtticGlassMenuStyle.symbol("minus", size: m.iconSize, weight: AtticGlassMenuStyle.iconWeight, color: iconInk), centeredIn: slot)
            } else if let name = AtticMenuSymbols.symbol(for: command) {
                drawImage(AtticGlassMenuStyle.symbol(name, size: m.iconSize, weight: AtticGlassMenuStyle.iconWeight, color: iconInk), centeredIn: slot)
            } else if let image = command.image {
                drawImage(image, centeredIn: slot)
            } else if let priority = command.priority {
                drawPriority(priority, in: slot, disabled: command.isDisabled, style: style)
            } else if let swatch = command.swatch {
                let dot = NSRect(x: slot.midX - d.dotSize / 2, y: slot.midY - d.dotSize / 2, width: d.dotSize, height: d.dotSize)
                style.colourInk(style.tokens.tagInk(swatch)).nsColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            x += m.iconSlot + m.columnGap
        }
        var trailing = frame.maxX - m.rowPadding
        if !command.children.isEmpty {
            let size = m.chevronSize
            drawImage(AtticGlassMenuStyle.symbol("chevron.right", size: size, weight: .medium, color: command.isDisabled ? style.disabled : style.detail),
                      centeredIn: NSRect(x: trailing - size, y: frame.midY - size / 2, width: size, height: size))
            trailing -= size + m.trailingGap
        }
        if let state = command.state, state != .off {
            let slot = NSRect(x: trailing - d.checkSlot, y: frame.midY - d.checkSlot / 2, width: d.checkSlot, height: d.checkSlot)
            drawImage(AtticGlassMenuStyle.symbol(state == .on ? "checkmark" : "minus", size: d.checkSize, weight: .semibold, color: ink),
                      centeredIn: slot)
            trailing -= d.checkSlot + m.trailingGap
        }
        if let text = command.glassTrailingText {
            let font = AtticGlassMenuStyle.detailFont
            let width = ceil(AtticGlassMenuCard.measure(text, font))
            drawText(text, in: NSRect(x: trailing - width, y: frame.midY - (font.ascender - font.descender) / 2, width: width,
                                      height: font.ascender - font.descender), font: font, color: command.isDisabled ? style.disabled : style.detail)
            trailing -= width + d.detailGap
        }
        let font = command.titleFont ?? AtticGlassMenuStyle.titleFont
        drawText(command.title, in: NSRect(x: x, y: frame.midY - (font.ascender - font.descender) / 2, width: max(0, trailing - x),
                                           height: font.ascender - font.descender), font: font, color: ink)
    }

    /// A priority's mark in the icon column, as the priority picker draws
    /// it: High in its own ink, Low and Medium quiet, None empty.
    private func drawPriority(_ priority: AtticPriority, in slot: NSRect, disabled: Bool, style: AtticGlassMenuStyle) {
        let text: String
        switch priority {
        case .none: return
        case .low: text = "↓"
        case .medium: text = "!"
        case .high: text = "!!"
        }
        let ink = disabled ? style.disabled : (priority == .high ? style.colourInk(style.tokens.ink(.priorityMark)).nsColor : style.detail)
        let font = AtticTextStyle.priorityMark.nsFont
        let width = ceil(AtticGlassMenuCard.measure(text, font))
        let height = font.ascender - font.descender
        drawText(text, in: NSRect(x: slot.midX - width / 2, y: slot.midY - height / 2, width: width, height: height), font: font, color: ink)
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

    /// `point` is in screen coordinates: the item under it, else the menu.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let card, let row = card.row(at: point), let element = element(for: row) else { return self }
        return element
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
            element.setAccessibilityFrameInParentSpace(card.accessibilityFrame(ofRow: row))
        }
    }

    override func mouseMoved(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
}

/// A flipped, layer-backed view that takes no hits (the rows' content and
/// the highlight).
final class AtticGlassMenuFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One entry of a card (a row, a title, a separator) in its own layer, so
/// the rows can arrive one after another.
final class AtticGlassMenuEntryView: NSView {
    var index = 0
    weak var menuView: AtticGlassMenuView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        menuView?.drawEntry(index)
    }
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
            setAccessibilityFrameInParentSpace(card.accessibilityFrame(ofRow: row))
            setAccessibilitySelected(card.highlighted == row)
        }
        if command.state == .mixed { setAccessibilityValue(String(localized: "some selected tasks")) }
        if let detail = command.detail { setAccessibilityHelp(detail) }
        if command.isDisabled, let reason = command.disabledReason { setAccessibilityHelp(reason) }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? { self }

    /// Its card's window, as an `NSMenu` item reports its menu's (XCUITest
    /// places a menu item's hit point in its window).
    override func accessibilityWindow() -> Any? { MainActor.assumeIsolated { view?.window } }
    override func accessibilityTopLevelUIElement() -> Any? { MainActor.assumeIsolated { view?.window } }

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
        let hit = hitView(for: event, in: window)
        for view in anchors.allObjects where view.window === window && view.build != nil && Self.isShown(view) {
            if let hit, !Self.shares(hit, with: view) { continue }
            let local = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(local) else { continue }
            let area = view.bounds.width * view.bounds.height
            if best.map({ area < $0.area }) ?? true { best = (view, area) }
        }
        return best?.view
    }

    /// Some AppKit text views claim clicks well outside their frames during
    /// window hit-testing (including above the task page's writing). Ignore
    /// that result; it cannot cover the pointer or suppress an anchor there.
    private static func hitView(for event: NSEvent, in window: NSWindow) -> NSView? {
        guard let content = window.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
              hit.bounds.contains(hit.convert(event.locationInWindow, from: nil)) else { return nil }
        return hit
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
        target(for: event)?.build?()
    }

    /// The open cards in the press's window.
    private static func activeShields(for event: NSEvent) -> [AtticPressShield] {
        guard let window = event.window else { return [] }
        return shields.allObjects.filter { $0.window === window && $0.isActive() }
    }

    /// The anchor a press opens: none on an open card (what is under it is
    /// covered), else the innermost one under the pointer.
    static func target(for event: NSEvent) -> AtticContextMenuAnchor.AnchorView? {
        if activeShields(for: event).contains(where: { $0.contains(event) }) { return nil }
        return anchor(for: event)
    }

    static func isMenuTrigger(for event: NSEvent) -> Bool {
        if activeShields(for: event).contains(where: { $0.contains(event) }) { return false }
        if !isContextPress(event), event.type == .leftMouseDown, AtticMenuAnchor.containsTrigger(for: event) { return true }
        if let window = event.window, let hit = hitView(for: event, in: window), isShown(hit) {
            var view: NSView? = hit
            while let current = view {
                if let trigger = current as? any AtticMenuTrigger { return trigger.opensAtticMenu(for: event) }
                if current is NSTextView || (!isContextPress(event) && current is NSControl) { return false }
                view = current.superview
            }
        }
        if isContextPress(event) { return routedTarget(for: event) != nil }
        return false
    }

    /// Native text and table controls are not triggers for this router.
    private static func routedTarget(for event: NSEvent) -> AtticContextMenuAnchor.AnchorView? {
        guard let window = event.window, let anchor = target(for: event) else { return nil }
        if let hit = hitView(for: event, in: window) {
            if let text = hit as? NSTextView, text.isEditable || text.isSelectable { return nil }
            if let field = hit as? NSTextField, field.isEditable { return nil }
            var view: NSView? = hit
            while let current = view {
                if current is NoteTableCanvas || current is NoteTableView { return nil }
                view = current.superview
            }
        }
        return anchor
    }

    /// The open cards (the "+" card) that shield what is under them.
    private static let shields = NSHashTable<AtticPressShield>.weakObjects()

    static func register(_ shield: AtticPressShield) {
        shields.add(shield)
    }

    /// One press, as the monitor sees it (tests call it in its place).
    static func route(_ event: NSEvent) -> NSEvent? {
        guard isContextPress(event), AtticGlassMenu.current == nil, let window = event.window,
              let anchor = routedTarget(for: event) else { return event }
        // A row's menu outside an open card: the press is also a click
        // outside the card, which closes it (keeping its draft) first.
        for shield in activeShields(for: event) { shield.onOutsidePress() }
        let location = event.locationInWindow
        let build = anchor.build
        DispatchQueue.main.async {
            guard let content = window.contentView, let commands = build?(), !commands.isEmpty else { return }
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

/// The view behind an open card drawn over the panel (the "+" card): a
/// right-click on the card opens no menu of a row under it, and one on a
/// row outside it counts as a click outside the card (it closes, keeping
/// its draft) and still opens that row's menu, in the same press
/// (orchestrator decision, w3 UI tests round 2, under Accepted 2026-10-29
/// "The '+' card": "Escape or a click outside keeps the draft").
final class AtticPressShield: NSView {
    /// Whether the card is open (it stays drawn while it shrinks away).
    var isActive: @MainActor () -> Bool = { false }
    /// A context press outside the card: close it, as a click outside does.
    var onOutsidePress: @MainActor () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { AtticContextMenus.register(self) }
    }

    /// The press is on the card.
    func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }
}

/// `AtticPressShield` in SwiftUI: put it behind the card.
struct AtticPressShieldView: NSViewRepresentable {
    let isActive: @MainActor () -> Bool
    let onOutsidePress: @MainActor () -> Void

    func makeNSView(context: Context) -> AtticPressShield {
        let view = AtticPressShield()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: AtticPressShield, context: Context) {
        view.isActive = isActive
        view.onOutsidePress = onOutsidePress
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
            .background(AtticMenuAnchor(holder: anchor, isMenuTrigger: false).accessibilityHidden(true))
            .accessibilityAction(.showMenu) {
                anchor.open(build(), event: nil)
            }
    }
}
