import AppKit
import SwiftUI

/// A SwiftUI host laid over the note's text. It never takes the keyboard
/// from the text on a click (its text fields still can), and only its
/// content's rectangle answers the pointer (the shadow room around it is
/// click-through).
final class NoteOverlayHostingView: NSHostingView<AnyView> {
    /// The content's inset from the host's edges (the shadow room).
    var contentInset: CGFloat = AtticNoteFormatMetrics.shadowRoom
    var isInteractive = false
    /// The date and link cards hold a text field that takes the keyboard.
    var acceptsKeyboard = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { acceptsKeyboard }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: contentInset, dy: contentInset).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Which "/" rows, date card and hint a new draft has earned: the first
/// three new drafts show "Type / for lists, checklists and more".
@MainActor
enum NoteSlashHintPolicy {
    static let draftLimit = 3
    static let countKey = "notes.slashHint.draftCount"
    static var defaults: UserDefaults = .standard
    private static var granted = Set<UUID>()

    /// Whether this draft shows the hint; the first look at a new draft
    /// uses up one of the three.
    static func shows(noteID: UUID, isNewDraft: Bool) -> Bool {
        if granted.contains(noteID) { return true }
        guard isNewDraft, defaults.integer(forKey: countKey) < draftLimit else { return false }
        granted.insert(noteID)
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        return true
    }

    /// Typing "/" once is enough: the hint is not shown again.
    static func learned() {
        defaults.set(draftLimit, forKey: countKey)
    }

    static func resetForTesting() { granted = [] }
}

/// The formatting and insertion UI laid over one note's text view: the
/// selection bar, the `/` list, the date and link cards, the link address
/// on hover, the one-time hint, the right-click rows and the keys that
/// reach them. Everything runs through `router` (one command layer). Built
/// per appearance with the text view and invalidated with it.
///
/// Performance: typing with nothing shown costs one range check per
/// selection change; the state snapshot is read once per run-loop turn and
/// only while the bar or Aa shows; nothing here re-renders the editor.
@MainActor
final class NoteFormatControls: NSObject {
    /// The controls of the note the menu bar's Insert and Format act on.
    private(set) static weak var active: NoteFormatControls?

    let engine: NoteEditorEngine
    let router: NoteCommandRouter
    let formatModel = NoteFormatModel()
    let slashModel = NoteSlashListModel()
    let cardModel = NoteFormatCardModel()
    private weak var textView: NoteEditorTextView?
    private weak var scrollView: NSScrollView?
    private let barHost: NoteOverlayHostingView
    private let slashHost: NoteOverlayHostingView
    private let cardHost: NoteOverlayHostingView
    private let hintHost: NoteOverlayHostingView
    private let addressHost: NoteOverlayHostingView
    private(set) var design: AtticDesignContext
    private let noteID: UUID
    private let isNewDraft: Bool

    /// ⌃Tab or ⌘T without a bar, and Aa's own button: the page's pop-over.
    var requestFormatPopover: ((_ keyboard: Bool) -> Void)?
    var closeFormatPopover: (() -> Void)?
    /// Image or File…: the page's open panel (one image for `/`).
    var requestFile: ((_ fromSlash: Bool) -> Void)?
    /// A `/` row was taken (tests: the list runs the engine's commands).
    var onSlashPick: ((NoteSlashItem.Kind) -> Void)?
    /// Aa is open: its toggles follow the selection too.
    var isFormatPopoverOpen = false {
        didSet { if isFormatPopoverOpen { refreshSnapshot() } }
    }

    private var selectionObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var previousLayout: (() -> Void)?
    private var previousActivity: ((NoteEditorEngine.Activity, NoteEditorEngine.Activity) -> Void)?
    private var refreshScheduled = false
    /// Esc hid the bar for this selection; it returns when the selection changes.
    private var dismissedSelection: NSRange?
    /// The selection a card acts on (and returns to).
    private var cardSelection: NSRange?
    private var cardFromSlash = false
    private var cardAnchor: NSRange?
    private var hoverURL: String?
    private var hoverWork: DispatchWorkItem?
    private var hintEligible = false
    private var hintShown = false
    private var barWidth: CGFloat = 0
    /// Diagnostic: how many times the state was read (never while typing
    /// with nothing shown).
    private(set) var snapshotCount = 0

    init(engine: NoteEditorEngine, textView: NoteEditorTextView, scrollView: NSScrollView,
         design: AtticDesignContext, noteID: UUID, isNewDraft: Bool) {
        self.engine = engine
        self.router = NoteCommandRouter(engine: engine)
        self.textView = textView
        self.scrollView = scrollView
        self.design = design
        self.noteID = noteID
        self.isNewDraft = isNewDraft
        barHost = NoteOverlayHostingView(rootView: AnyView(EmptyView()))
        slashHost = NoteOverlayHostingView(rootView: AnyView(EmptyView()))
        cardHost = NoteOverlayHostingView(rootView: AnyView(EmptyView()))
        hintHost = NoteOverlayHostingView(rootView: AnyView(EmptyView()))
        addressHost = NoteOverlayHostingView(rootView: AnyView(EmptyView()))
        super.init()
        formatModel.router = router
        hintHost.contentInset = 0
        cardHost.acceptsKeyboard = true
        hintHost.isHidden = true
        textView.addSubview(hintHost)
        for host in [barHost, slashHost, cardHost, addressHost] { host.isHidden = true }
        rebuildRoots()
        wire()
        Self.active = self
        NoteFormatMenuBar.install()
    }

    // MARK: Wiring

    private func wire() {
        guard let textView, let scrollView else { return }
        router.onChange = { [weak self] in
            self?.refreshSnapshot()
            self?.returnKeyboardFromBar()
        }
        router.requestDate = { [weak self] in self?.openDateCard(fromSlash: false) }
        router.requestFile = { [weak self] in self?.requestFile?(false) }
        formatModel.willRequestLink = { [weak self] in
            if self?.isFormatPopoverOpen == true { self?.closeFormatPopover?() }
        }
        slashModel.onPick = { [weak self] kind in self?.pickSlash(kind) }
        cardModel.onCommitDate = { [weak self] date in self?.commitDate(date) }
        cardModel.onCommitLink = { [weak self] url in self?.commitLink(url) ?? false }
        cardModel.onRemoveLink = { [weak self] in self?.removeLink() }
        cardModel.onCancel = { [weak self] in self?.cancelCard() }

        engine.onSlashSessionChange = { [weak self] session in self?.slashSessionChanged(session) }
        engine.onSlashDateRequest = { [weak self] in self?.openDateCard(fromSlash: true) }
        engine.onSlashFileRequest = { [weak self] in self?.requestFile?(true) }
        engine.onLinkRequest = { [weak self] target in self?.openLinkCard(target: target) }
        previousActivity = engine.onActivityChanged
        engine.onActivityChanged = { [weak self] old, new in
            self?.previousActivity?(old, new)
            self?.scheduleRefresh()
        }
        let previousCommand = textView.suggestionCommand
        textView.suggestionCommand = { [weak self] selector in
            (self?.handleCommand(selector) ?? false) || (previousCommand?(selector) ?? false)
        }
        previousLayout = textView.onLayout
        textView.onLayout = { [weak self] in
            self?.previousLayout?()
            self?.layoutDidChange()
        }
        textView.contextMenuProvider = { [weak self] menu, event in self?.decorate(menu, for: event) }
        applyLinkLook()

        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.selectionDidChange() } }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layoutDidChange() } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        textView.addTrackingArea(area)
        trackingArea = area
        hintEligible = NoteSlashHintPolicy.shows(noteID: noteID, isNewDraft: isNewDraft)
    }

    func invalidate() {
        for observer in [selectionObserver, boundsObserver, resignObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        selectionObserver = nil
        boundsObserver = nil
        resignObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        hoverWork?.cancel()
        if let trackingArea { textView?.removeTrackingArea(trackingArea) }
        engine.onSlashSessionChange = nil
        engine.onSlashDateRequest = nil
        engine.onSlashFileRequest = nil
        engine.onLinkRequest = nil
        engine.onActivityChanged = previousActivity
        if engine.pendingSlashDate != nil { engine.cancelSlashDate() }
        textView?.onLayout = previousLayout
        textView?.contextMenuProvider = nil
        for host in [hintHost, barHost, slashHost, cardHost, addressHost] { host.removeFromSuperview() }
        if Self.active === self { Self.active = nil }
    }

    func update(design: AtticDesignContext) {
        guard design != self.design else { return }
        self.design = design
        barWidths = [:]
        rebuildRoots()
        applyLinkLook()
    }

    private func rebuildRoots() {
        let design = design
        formatModel.highlightSwatch = AtticColorTokens.resolve(design).tagFill
        barHost.rootView = AnyView(NoteFormatBarView(model: formatModel).atticDesign(design))
        slashHost.rootView = AnyView(NoteSlashListView(model: slashModel).atticDesign(design))
        cardHost.rootView = AnyView(NoteFormatCardView(model: cardModel).atticDesign(design))
        hintHost.rootView = AnyView(NoteSlashHintView().atticDesign(design))
    }

    /// Links read as body text with a quiet underline; the pointer shows a
    /// hand over them and a click opens them.
    private func applyLinkLook() {
        let style = NoteTextStyle(design: design)
        textView?.linkTextAttributes = [
            .foregroundColor: style.bodyColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: style.secondaryColor,
            .cursor: NSCursor.pointingHand
        ]
    }

    // MARK: Selection and refresh

    private var selection: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    private func selectionDidChange() {
        // Typing with nothing shown: one range check.
        let current = selection
        if current.length == 0, !formatModel.barShown, !slashModel.shown, cardModel.card == nil,
           !isFormatPopoverOpen, engine.slashSession == nil, !hintEligible {
            dismissedSelection = nil
            return
        }
        if dismissedSelection != nil, dismissedSelection != current { dismissedSelection = nil }
        scheduleRefresh()
    }

    /// Coalesces refreshes into one per run-loop turn (a drag selection or
    /// a burst of keys reads the state once).
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Recomputes what shows. Runs after the engine has handled the event.
    func refresh() {
        guard let textView else { return }
        let current = selection
        let focused = textView.window?.firstResponder === textView || barOwnsKeyboard
        let allowsBar = current.length > 0 && focused && !textView.hasMarkedText() && engine.activity == .idle
            && cardModel.card == nil && dismissedSelection != current && !slashModel.shown && !isFormatPopoverOpen
        if allowsBar || isFormatPopoverOpen {
            snapshotCount += 1
            let snapshot = NoteFormatSnapshot.make(router: router, selection: current)
            formatModel.setSnapshot(snapshot)
            if allowsBar, snapshot.hasEnabledCommand {
                showBar()
            } else {
                hideBar()
            }
        } else {
            hideBar()
        }
        updateHint()
    }

    func refreshSnapshot() {
        snapshotCount += 1
        formatModel.setSnapshot(NoteFormatSnapshot.make(router: router, selection: selection))
        if formatModel.barShown { placeBar() }
    }

    private func layoutDidChange() {
        if formatModel.barShown { placeBar() }
        if slashModel.shown { placeSlashList() }
        if cardModel.card != nil { placeCard() }
        if hintEligible { updateHint() }
        if !addressHost.isHidden { hideAddress() }
    }

    // MARK: Selection bar

    /// A click in the bar can leave the keyboard with its host; the text keeps it.
    private var barOwnsKeyboard: Bool {
        guard let responder = barHost.window?.firstResponder as? NSView else { return false }
        return responder === barHost || responder.isDescendant(of: barHost)
    }

    private func returnKeyboardFromBar() {
        guard barOwnsKeyboard, let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    private func showBar() {
        barWidth = measuredBarWidth(styleName: NoteCommandCatalog.styleName(formatModel.snapshot.paragraph))
        placeBar()
        barHost.isInteractive = true
        if barHost.isHidden { barHost.isHidden = false }
        if !formatModel.barShown { formatModel.barShown = true }
    }

    func hideBar() {
        guard formatModel.barShown || formatModel.barKeyboardIndex != nil else { return }
        formatModel.barShown = false
        formatModel.barKeyboardIndex = nil
        barHost.isInteractive = false
    }

    private var barWidths: [String: CGFloat] = [:]

    /// The bar's laid-out width for a style name (measured once per name).
    private func measuredBarWidth(styleName: String) -> CGFloat {
        if let width = barWidths[styleName] { return width }
        let probe = NoteFormatModel()
        probe.router = router
        probe.setSnapshot(formatModel.snapshot)
        probe.barShown = true
        let host = NSHostingView(rootView: AnyView(NoteFormatBarView(model: probe).atticDesign(design)))
        let measured = host.fittingSize.width - AtticNoteFormatMetrics.shadowRoom * 2
        let width = max(measured, Self.barWidth(styleName: styleName))
        barWidths[styleName] = width
        return width
    }

    /// The bar's width from its metrics: the style control (its label, a
    /// gap and the chevron in its padding) and eight 24 pt toggles in
    /// three groups, inside the 4 pt inset.
    static func barWidth(styleName: String) -> CGFloat {
        let m = AtticNoteFormatMetrics.self
        let font = AtticTextStyle.controlLabel.nsFont
        let label = ceil((styleName as NSString).size(withAttributes: [.font: font]).width)
        let style = label + 4 + m.barStyleChevron + 2 + m.barStylePadding * 2
        let toggles = CGFloat(NoteFormatBarItem.all.count - 1) * m.barToggleWidth
        return ceil(AtticControlSize.capsuleInset * 2 + style + m.barGroupGap * 3 + toggles)
    }

    /// The part of the text view's visible rectangle a floating control
    /// may use: from the header's bottom (the title's top gap included) to
    /// the bottom row, or, for the lists and cards that float over the
    /// bottom row, to 8 above the panel's edge.
    private func usableRect(overBottomRow: Bool = false) -> NSRect {
        guard let textView, let scrollView else { return .zero }
        let visible = textView.visibleRect
        let insets = scrollView.contentInsets
        let top = visible.minY + max(0, insets.top - AtticNoteMetrics.titleTopGap)
        let bottom = overBottomRow ? visible.maxY - 8 : visible.maxY - insets.bottom
        return NSRect(x: visible.minX, y: top, width: visible.width, height: max(0, bottom - top))
    }

    /// Below the anchor line, else above it; with room on neither side, the
    /// roomier one, and the height it can have there.
    private func floatingPlacement(anchorTop: CGFloat, anchorBottom: CGFloat, height: CGFloat)
        -> (y: CGFloat, height: CGFloat) {
        let area = usableRect(overBottomRow: true)
        let gap = AtticNoteFormatMetrics.cardGap
        let roomBelow = area.maxY - (anchorBottom + gap)
        let roomAbove = (anchorTop - gap) - area.minY
        if height <= roomBelow { return (anchorBottom + gap, height) }
        if height <= roomAbove { return (anchorTop - gap - height, height) }
        if roomBelow >= roomAbove { return (anchorBottom + gap, max(0, roomBelow)) }
        return (area.minY, max(0, roomAbove))
    }

    /// Lists and cards float over the whole page (above the bottom row), in
    /// the window's content view, placed from text-view coordinates.
    private func placeOverlay(_ host: NoteOverlayHostingView, rect: NSRect) {
        guard let textView, let parent = textView.window?.contentView else { return }
        if host.superview !== parent { parent.addSubview(host, positioned: .above, relativeTo: nil) }
        let frame = parent.convert(rect, from: textView).integral
        if host.frame != frame { host.frame = frame }
    }

    /// Above the selection's first line, or under its last when there is no
    /// room above; never over the selection while either fits.
    func barPlacement(selection: NSRange) -> (frame: NSRect, below: Bool)? {
        guard let textView, selection.length > 0,
              let first = engine.rect(for: NSRange(location: selection.location, length: 1)),
              let last = engine.rect(for: NSRange(location: NSMaxRange(selection) - 1, length: 1)) else { return nil }
        let m = AtticNoteFormatMetrics.self
        let usable = usableRect()
        let width = barWidth > 0 ? barWidth : Self.barWidth(styleName: NoteCommandCatalog.styleName(formatModel.snapshot.paragraph))
        var y = first.minY - m.barGap - m.barHeight
        var below = false
        if y < usable.minY {
            if last.maxY + m.barGap + m.barHeight <= usable.maxY {
                y = last.maxY + m.barGap
                below = true
            } else {
                y = usable.minY
            }
        }
        let inset = textView.textContainerInset.width
        let preferred = min(first.minX, inset) - AtticControlSize.capsuleInset - m.barStylePadding
        let maxX = textView.bounds.width - width - m.barEdgeMargin
        let x = max(m.barEdgeMargin, min(preferred, maxX))
        return (NSRect(x: x, y: y, width: width, height: m.barHeight), below)
    }

    private func placeBar() {
        guard let placement = barPlacement(selection: selection) else { hideBar(); return }
        let room = AtticNoteFormatMetrics.shadowRoom
        placeOverlay(barHost, rect: placement.frame.insetBy(dx: -room, dy: -room))
        if formatModel.barBelow != placement.below { formatModel.barBelow = placement.below }
    }

    // MARK: Keys

    /// ⌃Tab, the bar's keyboard mode and the format shortcuts, before the
    /// text view sees them (never during a composition).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let textView, let window = textView.window, event.window === window,
              window.firstResponder === textView, !textView.hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.keyCode == 48, flags == [.control] {
            if formatModel.barKeyboardIndex != nil {
                exitBarKeyboard()
            } else if formatModel.barShown {
                enterBarKeyboard()
            } else {
                requestFormatPopover?(true)
            }
            return true
        }
        if formatModel.barKeyboardIndex != nil { return handleBarKey(event, flags: flags) }
        guard flags.contains(.command), let command = NoteCommandCatalog.command(for: event) else { return false }
        router.run(command, from: .shortcut)
        return true
    }

    func enterBarKeyboard() {
        formatModel.barKeyboardIndex = 0
        announceBarItem()
    }

    func exitBarKeyboard() {
        formatModel.barKeyboardIndex = nil
    }

    private func handleBarKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let index = formatModel.barKeyboardIndex else { return false }
        let count = NoteFormatBarItem.all.count
        switch event.keyCode {
        case 123: formatModel.barKeyboardIndex = (index - 1 + count) % count
        case 124: formatModel.barKeyboardIndex = (index + 1) % count
        case 48: formatModel.barKeyboardIndex = flags.contains(.shift) ? (index - 1 + count) % count : (index + 1) % count
        case 36, 76, 49: pressBarItem(NoteFormatBarItem.all[index]); return true
        case 53: exitBarKeyboard(); return true
        default:
            exitBarKeyboard()
            return false
        }
        announceBarItem()
        return true
    }

    private func pressBarItem(_ item: NoteFormatBarItem) {
        switch item {
        case .style:
            guard let textView else { return }
            let anchor = barFrame
            AtticNativeMenu.popUp(formatModel.styleMenu(from: .selectionBar),
                                  below: NSRect(x: anchor.minX, y: anchor.minY, width: 80, height: anchor.height), in: textView)
        case let .command(command):
            guard formatModel.snapshot.isEnabled(command) else { NSSound.beep(); return }
            formatModel.run(command, from: .selectionBar)
        }
    }

    private func announceBarItem() {
        guard let index = formatModel.barKeyboardIndex, let textView else { return }
        let text: String
        switch NoteFormatBarItem.all[index] {
        case .style:
            text = String(localized: "Style, \(NoteCommandCatalog.styleName(formatModel.snapshot.paragraph))")
        case let .command(command):
            let value = AtticFormatValue.spokenValue(formatModel.snapshot.value(command))
            text = "\(NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")), \(value)"
        }
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    /// The text view's command keys while a list or the bar shows: the `/`
    /// list takes ↑ ↓ (and ⌃P ⌃N), Return and Tab; Esc closes what is open.
    func handleCommand(_ selector: Selector) -> Bool {
        if slashModel.shown, !slashModel.items.isEmpty {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): slashModel.move(1); return true
            case #selector(NSResponder.moveUp(_:)): slashModel.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let kind = slashModel.highlightedKind { pickSlash(kind) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                engine.dismissSlashSession()
                return true
            default: return false
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), formatModel.barShown {
            dismissedSelection = selection
            hideBar()
            return true
        }
        return false
    }

    // MARK: The / list

    private func slashSessionChanged(_ session: NoteSlashSession?) {
        guard let session, !session.items.isEmpty, cardModel.card == nil else {
            slashModel.hide()
            slashHost.isInteractive = false
            scheduleRefresh()
            return
        }
        NoteSlashHintPolicy.learned()
        hideBar()
        slashModel.show(session.items)
        placeSlashList()
        slashHost.isInteractive = true
        slashHost.isHidden = false
        updateHint()
    }

    func pickSlash(_ kind: NoteSlashItem.Kind) {
        onSlashPick?(kind)
        slashModel.hide()
        _ = engine.acceptSlashItem(kind)
    }

    private func placeSlashList() {
        guard let textView, let session = engine.slashSession,
              let anchor = engine.rect(for: NSRange(location: session.range.location, length: 1)) else { return }
        let m = AtticNoteFormatMetrics.self
        let room = m.shadowRoom
        let row = AtticControlSize.smallHeight
        let padding = AtticPopoverMetrics.padding * 2
        let wanted = CGFloat(min(slashModel.items.count, m.slashMaxVisibleRows)) * row + padding
        let place = floatingPlacement(anchorTop: anchor.minY, anchorBottom: anchor.maxY, height: wanted)
        let rows = max(3, min(slashModel.items.count, Int((place.height - padding) / row)))
        if slashModel.maxVisibleRows != rows { slashModel.maxVisibleRows = rows }
        let height = CGFloat(min(slashModel.items.count, rows)) * row + padding
        let y = place.y < anchor.minY ? anchor.minY - m.cardGap - height : place.y
        let textInset = AtticPopoverMetrics.padding + AtticPopoverMetrics.rowPadding + AtticPopoverMetrics.rowIconSlot
            + AtticPopoverMetrics.rowGap
        let x = max(m.barEdgeMargin, min(anchor.minX - textInset, textView.bounds.width - m.slashWidth - m.barEdgeMargin))
        placeOverlay(slashHost, rect: NSRect(x: x - room, y: y - room, width: m.slashWidth + room * 2, height: height + room * 2))
    }

    // MARK: Cards (date, link)

    func openDateCard(fromSlash: Bool) {
        hideBar()
        slashModel.hide()
        cardFromSlash = fromSlash
        cardSelection = selection
        cardAnchor = fromSlash ? engine.pendingSlashDate?.range : NSRange(location: selection.location, length: 0)
        cardModel.openDate(fromSlash: fromSlash, today: Date())
        presentCard()
    }

    /// The link card for the engine's captured link target: its range (the
    /// selection, or the whole link around a caret), the selection to come
    /// back to, and the current address.
    func openLinkCard(target: NoteLinkTarget) {
        hideBar()
        cardFromSlash = false
        linkTarget = target
        cardSelection = target.selection
        cardAnchor = target.range
        cardModel.openLink(url: target.url)
        presentCard()
    }

    private var linkTarget: NoteLinkTarget?

    private var cardSize = NSSize.zero

    /// The card's size, measured from its content once as it opens.
    private func presentCard() {
        let room = AtticNoteFormatMetrics.shadowRoom
        let measure = NSHostingView(rootView: NoteFormatCardView(model: cardModel).atticDesign(design))
        let fitting = measure.fittingSize
        cardSize = NSSize(width: max(0, fitting.width - room * 2), height: max(0, fitting.height - room * 2))
        placeCard()
        cardHost.isInteractive = true
        cardHost.isHidden = false
        installCardDismissal()
        // The card's field takes the keyboard (typing goes to it, not the note).
        DispatchQueue.main.async { [weak self] in self?.focusCardField(attempts: 3) }
    }

    private func placeCard() {
        guard let textView, let anchorRange = cardAnchor, engine.textStorage.length > 0 else { return }
        let m = AtticNoteFormatMetrics.self
        let length = engine.textStorage.length
        let start = min(anchorRange.location, length - 1)
        let end = min(max(start, NSMaxRange(anchorRange) - 1), length - 1)
        guard let first = engine.rect(for: NSRange(location: start, length: 1)) ?? caretRect(),
              let last = engine.rect(for: NSRange(location: end, length: 1)) ?? caretRect() else { return }
        let room = m.shadowRoom
        let place = floatingPlacement(anchorTop: first.minY, anchorBottom: last.maxY, height: cardSize.height)
        // A card never shrinks: without room it covers the text rather than the page's edge.
        let area = usableRect(overBottomRow: true)
        let y = place.height < cardSize.height ? max(area.minY, area.maxY - cardSize.height) : place.y
        let x = max(m.barEdgeMargin, min(first.minX - AtticPopoverMetrics.padding - AtticPopoverMetrics.rowPadding,
                                         textView.bounds.width - cardSize.width - m.barEdgeMargin))
        placeOverlay(cardHost, rect: NSRect(x: x - room, y: y - room, width: cardSize.width + room * 2,
                                            height: cardSize.height + room * 2))
    }

    /// The field may not exist until SwiftUI's next pass: a few turns, then
    /// the card's host itself (its field's focus follows).
    private func focusCardField(attempts: Int) {
        guard cardModel.card != nil, let window = cardHost.window, !cardHasKeyboard else { return }
        cardHost.layoutSubtreeIfNeeded()
        if let field = Self.firstTextField(in: cardHost), window.makeFirstResponder(field) { return }
        guard attempts > 1 else {
            window.makeFirstResponder(cardHost)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.focusCardField(attempts: attempts - 1) }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    /// The card's field has the keyboard.
    var cardHasKeyboard: Bool {
        guard let responder = cardHost.window?.firstResponder as? NSView else { return false }
        return responder === cardHost || responder.isDescendant(of: cardHost)
    }

    /// A click outside the card, or the window losing the keyboard, cancels it.
    private func installCardDismissal() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.cardModel.card != nil, event.window === self.cardHost.window else { return event }
                let point = self.cardHost.convert(event.locationInWindow, from: nil)
                let inside = self.cardHost.bounds.insetBy(dx: AtticNoteFormatMetrics.shadowRoom,
                                                          dy: AtticNoteFormatMetrics.shadowRoom).contains(point)
                if !inside { self.cancelCard(refocus: false) }
                return event
            }
        }
        if resignObserver == nil, let window = textView?.window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelCard(refocus: false) } }
        }
    }

    private func closeCard(refocus: Bool, restoring range: NSRange?) {
        cardModel.card = nil
        cardHost.isInteractive = false
        cardAnchor = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard refocus, let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if let range, NSMaxRange(range) <= engine.textStorage.length { textView.setSelectedRange(range) }
        scheduleRefresh()
    }

    private func commitDate(_ date: Date) {
        let day = NoteDay(date: date)
        let fromSlash = cardFromSlash
        closeCard(refocus: true, restoring: fromSlash ? nil : cardSelection)
        if fromSlash {
            _ = engine.commitSlashDate(day)
        } else {
            router.run(.date(day), from: .noteMenu, selection: cardSelection)
        }
    }

    /// A bad address keeps the card and says so; a target that went stale
    /// while the card was open is dropped quietly (the engine refuses it).
    private func commitLink(_ url: String) -> Bool {
        guard let target = linkTarget else { return false }
        guard engine.validate(.link(url), selection: target.range).enabled else { return false }
        linkTarget = nil
        closeCard(refocus: true, restoring: target.selection)
        if router.commitLink(url, target: target, from: .linkPopover), let textView,
           NSMaxRange(target.selection) <= engine.textStorage.length {
            // Editing at a caret leaves the caret where it was.
            textView.setSelectedRange(target.selection)
        }
        return true
    }

    private func removeLink() {
        guard let target = linkTarget else { return }
        linkTarget = nil
        engine.cancelLinkRequest()
        closeCard(refocus: true, restoring: target.selection)
        router.run(.removeLink, from: .linkPopover, selection: target.range)
    }

    func cancelCard(refocus: Bool = true) {
        guard cardModel.card != nil else { return }
        if cardFromSlash, engine.pendingSlashDate != nil { engine.cancelSlashDate() }
        if linkTarget != nil {
            linkTarget = nil
            engine.cancelLinkRequest()
        }
        let range = cardFromSlash ? nil : cardSelection
        closeCard(refocus: refocus, restoring: range)
    }

    // MARK: Right-click

    /// Format ▸ and Insert ▸ from the one command list, and on a link:
    /// Open Link, Edit Link…, Copy Link, Remove Link.
    private func decorate(_ menu: NSMenu, for event: NSEvent) {
        guard let textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        var top: [NSMenuItem] = []
        if let (url, range) = link(at: point) {
            // The system's own link rows would duplicate these.
            let system: Set<String> = ["Open Link", "Copy Link", "Edit Link…", "Remove Link"]
            for item in menu.items where system.contains(item.title) { menu.removeItem(item) }
            top += nativeItems([
                AtticMenuCommand("Open Link", identifier: "notes-link-open") {
                    if let value = URL(string: url) { NSWorkspace.shared.open(value) }
                },
                AtticMenuCommand("Edit Link…", identifier: "notes-link-edit") { [weak self] in
                    guard let self else { return }
                    textView.setSelectedRange(range)
                    self.router.run(.mark(.link), from: .contextMenu, selection: range)
                },
                AtticMenuCommand("Copy Link", identifier: "notes-link-copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                },
                AtticMenuCommand("Remove Link", identifier: "notes-link-remove-menu") { [weak self] in
                    self?.router.run(.removeLink, from: .contextMenu, selection: range)
                }
            ])
            top.append(.separator())
        }
        // The system's Font submenu would style text outside the note's
        // format (bold, colours, sizes it cannot store): Format replaces it.
        for item in menu.items where Self.isFontMenu(item) { menu.removeItem(item) }
        top += nativeItems(router.menuCommands(from: .contextMenu))
        top.append(.separator())
        for (index, item) in top.enumerated() { menu.insertItem(item, at: index) }
    }

    static func isFontMenu(_ item: NSMenuItem) -> Bool {
        guard let submenu = item.submenu else { return false }
        let fontActions: Set<Selector> = [#selector(NSFontManager.orderFrontFontPanel(_:)),
                                          #selector(NSFontManager.addFontTrait(_:)),
                                          #selector(NSText.underline(_:))]
        return submenu.items.contains { $0.action.map(fontActions.contains) ?? false }
    }

    private func nativeItems(_ commands: [AtticMenuCommand]) -> [NSMenuItem] {
        let built = AtticNativeMenu.make(commands)
        let items = built.items
        built.removeAllItems()
        return items
    }

    /// The link under a point in the text view, with its range.
    func link(at point: NSPoint) -> (String, NSRange)? {
        guard let textView, engine.textStorage.length > 0 else { return nil }
        let index = textView.characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < engine.textStorage.length {
            guard let url = engine.textStorage.attribute(.noteMark(.link), at: candidate, effectiveRange: nil) as? String,
                  let rect = engine.rect(for: NSRange(location: candidate, length: 1)),
                  rect.insetBy(dx: -2, dy: -2).contains(point),
                  let range = router.linkRange(at: candidate) else { continue }
            return (url, range)
        }
        return nil
    }

    // MARK: Link address on hover

    @objc func mouseMoved(with event: NSEvent) {
        guard let textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let found = link(at: point)
        guard found?.0 != hoverURL else { return }
        hoverWork?.cancel()
        hideAddress()
        hoverURL = found?.0
        guard let (url, range) = found else { return }
        let work = DispatchWorkItem { [weak self] in self?.showAddress(url, range: range) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        hoverURL = nil
        hideAddress()
    }

    @objc func mouseEntered(with event: NSEvent) {}

    private func showAddress(_ url: String, range: NSRange) {
        guard let textView, hoverURL == url,
              let rect = engine.rect(for: NSRange(location: NSMaxRange(range) - 1, length: 1)) else { return }
        let design = design
        let shown = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        addressHost.rootView = AnyView(NoteLinkAddressView(address: shown).atticDesign(design))
        let size = addressHost.fittingSize
        let room = AtticNoteFormatMetrics.shadowRoom
        let x = max(0, min(rect.minX - room, textView.bounds.width - size.width))
        placeOverlay(addressHost, rect: NSRect(x: x, y: rect.maxY + 4 - room, width: size.width, height: size.height))
        addressHost.isHidden = false
        addressHost.setAccessibilityElement(false)
    }

    private func hideAddress() {
        addressHost.isHidden = true
    }

    // MARK: One-time hint

    private func updateHint() {
        guard hintEligible, let textView else { return }
        let string = engine.textStorage.string as NSString
        let titleEnd = string.range(of: "\n").location
        let bodyEmpty = titleEnd != NSNotFound && titleEnd == string.length - 1
        let caretOnBody = bodyEmpty && selection.length == 0 && selection.location == string.length
        let show = caretOnBody && !textView.hasMarkedText() && engine.slashSession == nil && cardModel.card == nil
        if show, let rect = caretRect() {
            let size = hintHost.fittingSize
            let frame = NSRect(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2, width: size.width, height: size.height).integral
            if hintHost.frame != frame { hintHost.frame = frame }
            hintHost.isHidden = false
            hintShown = true
        } else if hintShown {
            hintHost.isHidden = true
            hintShown = false
        }
        if !bodyEmpty, string.length > (titleEnd == NSNotFound ? string.length : titleEnd + 1) {
            // The body has text: the hint's job on this draft is done.
            hintEligible = false
            hintHost.isHidden = true
        }
    }

    var isHintVisible: Bool { !hintHost.isHidden }

    /// The caret's line rectangle in the text view (empty lines included).
    private func caretRect() -> NSRect? {
        guard let textView, let window = textView.window else { return nil }
        var actual = NSRange()
        let screen = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: &actual)
        guard screen != .zero else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return textView.convert(inWindow, from: nil)
    }

    /// The note's text has the keyboard (the menu bar acts on it).
    var hasKeyboard: Bool {
        guard let textView else { return false }
        return textView.window?.firstResponder === textView
    }

    // MARK: Test access

    /// The bar's capsule in the text view's coordinates.
    var barFrame: NSRect {
        let room = AtticNoteFormatMetrics.shadowRoom
        guard let textView, let parent = barHost.superview else { return .zero }
        return textView.convert(barHost.frame, from: parent).insetBy(dx: room, dy: room)
    }
    var isCardOpen: Bool { cardModel.card != nil }
}

/// The address under a hovered link: a quiet line in a small raised card.
struct NoteLinkAddressView: View {
    let address: String

    var body: some View {
        AtticText(verbatim: address, style: .helper, ink: .helper, truncates: true)
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(AtticPopoverBackground(cornerRadius: 11))
            .padding(AtticNoteFormatMetrics.shadowRoom)
            .accessibilityHidden(true)
    }
}
