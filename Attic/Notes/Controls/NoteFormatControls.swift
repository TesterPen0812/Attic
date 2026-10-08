import AppKit
import SwiftUI

/// The formatting and insertion UI laid over one note's text view: the
/// selection bar, the `/` list, the date and link cards, the link address
/// on hover, the empty-line hint, the right-click rows and the keys that
/// reach them. Everything runs through `router` (one command layer). Built
/// per appearance with the text view and invalidated with it.
///
/// Performance: typing with nothing shown costs one range check per
/// selection change; the state snapshot is read once per run-loop turn and
/// only while the bar or the format row shows; nothing here re-renders
/// the editor.
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
    private let barHost: AtticOverlayHostingView
    private let slashHost: AtticOverlayHostingView
    private let cardHost: AtticOverlayHostingView
    private let hintHost: AtticOverlayHostingView
    private let addressHost: AtticOverlayHostingView
    private(set) var design: AtticDesignContext
    private let noteID: UUID

    /// ⌘T, and Aa's own button: the page's format row.
    var requestFormatBar: ((_ keyboard: Bool) -> Void)?
    /// ⌃Tab (true) or ⌃⇧Tab (false) with no selection bar: the keyboard
    /// leaves the text for the page's next or previous control (OD-7).
    var leaveEditor: ((_ forward: Bool) -> Void)?
    var closeFormatBar: (() -> Void)?
    /// Image or File…: the page's open panel. `slash` is the `/` row's
    /// request (one file, replacing its command); nil for Insert.
    var requestFile: ((_ slash: NoteSlashFileRequest?) -> Void)?
    /// A `/` row was taken (tests: the list runs the engine's commands).
    var onSlashPick: ((NoteSlashItem.Kind) -> Void)?
    /// The format row is open (OD-14): its toggles follow the caret's line.
    var isFormatBarOpen = false {
        didSet {
            guard isFormatBarOpen != oldValue else { return }
            if isFormatBarOpen {
                moveCaretOutOfTitle()
                refreshSnapshot()
            } else {
                formatModel.rowKeyboardIndex = nil
                if formatModel.rowStyleListOpen { formatModel.rowStyleListOpen = false }
            }
        }
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
    private var hintShown = false
    private var barWidth: CGFloat = 0
    /// Diagnostic: how many times the state was read (never while typing
    /// with nothing shown).
    private(set) var snapshotCount = 0

    /// `isNewDraft` is no longer read: the empty-line hint (OD-14) shows on
    /// every note, not only on the first new drafts.
    init(engine: NoteEditorEngine, textView: NoteEditorTextView, scrollView: NSScrollView,
         design: AtticDesignContext, noteID: UUID, isNewDraft: Bool) {
        self.engine = engine
        self.router = NoteCommandRouter(engine: engine)
        self.textView = textView
        self.scrollView = scrollView
        self.design = design
        self.noteID = noteID
        barHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        slashHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        cardHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        hintHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        addressHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        super.init()
        formatModel.router = router
        hintHost.contentInset = 0
        cardHost.acceptsKeyboard = true
        // The `/` list and the cards are dropdowns: their room is the card's
        // shadow's, and VoiceOver hears a menu.
        slashHost.contentInset = AtticDropdownMetrics.shadowRoom
        slashHost.menuLabel = String(localized: "Insert")
        cardHost.contentInset = AtticDropdownMetrics.shadowRoom
        hintHost.isHidden = true
        AtticOverlayHierarchy.attach(hintHost, to: textView)
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
        router.requestFile = { [weak self] in self?.requestFile?(nil) }
        slashModel.onPick = { [weak self] kind in self?.pickSlash(kind) }
        cardModel.onCommitDate = { [weak self] date in self?.commitDate(date) }
        cardModel.onCommitLink = { [weak self] url in self?.commitLink(url) ?? false }
        cardModel.onRemoveLink = { [weak self] in self?.removeLink() }
        cardModel.onCancel = { [weak self] in self?.cancelCard() }

        engine.onSlashSessionChange = { [weak self] session in self?.slashSessionChanged(session) }
        engine.onSlashDateRequest = { [weak self] in self?.openDateCard(fromSlash: true) }
        engine.onSlashFileRequest = { [weak self] request in self?.requestFile?(request) }
        engine.onLinkRequest = { [weak self] target in self?.openLinkCard(target: target) }
        engine.onTableFocusChange = { [weak self] in self?.scheduleRefresh() }
        engine.onCellLinkRequest = { [weak self] target in self?.openCellLinkCard(target: target) }
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
        // A bounds change can come from inside a layout pass (the clip
        // settling): its placement counts as layout.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { AtticOverlayHierarchy.layoutPass { self?.layoutDidChange() } } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        textView.addTrackingArea(area)
        trackingArea = area
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
        engine.onTableFocusChange = nil
        engine.onCellLinkRequest = nil
        engine.onActivityChanged = previousActivity
        if engine.pendingSlashDate != nil { engine.cancelSlashDate() }
        textView?.onLayout = previousLayout
        textView?.contextMenuProvider = nil
        for host in [hintHost, barHost, slashHost, cardHost, addressHost] { AtticOverlayHierarchy.remove(host) }
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
        cardHost.rootView = AnyView(NoteFormatCardView(model: cardModel)
            .environment(\.atticDropdownContentHeightChanged, { [weak self] height in
                guard let self, self.cardModel.card != nil, abs(height - self.cardSize.height) > 0.5 else { return }
                self.cardSize.height = height
                self.placeCard()
            })
            .atticDesign(design))
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
           !isFormatBarOpen, engine.slashSession == nil, !hintShown, !caretOnEmptyLine(current) {
            dismissedSelection = nil
            return
        }
        // The first keystroke on the hint's line: gone before the text draws.
        if hintShown, !caretOnEmptyLine(current) { hideHint() }
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
        let inTable = tableMarkTarget
        let allowsBar = ((current.length > 0 && focused && !textView.hasMarkedText()) || inTable) && engine.activity == .idle
            && cardModel.card == nil && dismissedSelection != current && !slashModel.shown
        if allowsBar || isFormatBarOpen {
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

    /// The format row formats the caret's line, and the title keeps its own
    /// style. A note opens with the caret at the start of its title, so Aa
    /// there would open a row with every control dimmed (A29: "it's greyed
    /// out"). Opening the row from a title caret moves the caret to the start
    /// of the first body line it can format; the text is not changed. A note
    /// with no such line keeps the caret, and the row says why (VoiceOver's
    /// hint on each control).
    private func moveCaretOutOfTitle() {
        guard let textView, !engine.isReadOnly, engine.focusedTable == nil else { return }
        let current = selection
        let title = engine.titleParagraphRange
        guard current.length == 0, current.location <= NSMaxRange(title),
              engine.formattableParagraphs(in: current).isEmpty,
              let line = firstFormattableLine(after: title) else { return }
        textView.setSelectedRange(NSRange(location: line.location, length: 0))
    }

    /// The first body line (not an image or file) after the title, if any.
    private func firstFormattableLine(after title: NSRange) -> NSRange? {
        let length = engine.textStorage.length
        var location = NSMaxRange(title) + 1
        while location <= length {
            let line = engine.lineRange(at: location)
            guard line.location > 0 else { return nil }
            if !engine.isBlockObject(at: line.location) { return line }
            location = NSMaxRange(line) + 1
        }
        return nil
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
        if hintShown { updateHint() }
        if !addressHost.isHidden { hideAddress() }
    }

    // MARK: Selection bar

    /// A click in the bar can leave the keyboard with its host; the text keeps it.
    private var barOwnsKeyboard: Bool {
        guard let responder = barHost.window?.firstResponder as? NSView else { return false }
        return responder === barHost || responder.isDescendant(of: barHost)
    }

    /// After a command from the bar or the list, the keyboard is the
    /// note's again (a click there can leave it with the page's hosting view).
    private func returnKeyboardFromBar() {
        guard cardModel.card == nil else { return }
        if engine.returnKeyboardToTable() { return }
        guard let textView, let window = textView.window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
    }

    /// The keyboard is in one of this note's tables (a cell or whole cells).
    private var keyboardInTable: Bool {
        guard let responder = textView?.window?.firstResponder else { return false }
        if let editor = responder as? NoteTableCellEditor { return editor.table?.engine === engine }
        if let canvas = responder as? NoteTableCanvas { return canvas.table?.engine === engine }
        return false
    }

    /// The text a cell's marks would apply to: the cell editor's selection,
    /// or whole selected cells.
    private var tableMarkTarget: Bool {
        guard keyboardInTable, let table = engine.focusedTable else { return false }
        if table.cellSelection != nil { return true }
        return table.isEditingCell && table.editor.selectedRange().length > 0 && !table.editor.hasMarkedText()
    }

    private var rowItems: [NoteFormatRowItem] { NoteFormatRowItem.items(inTable: formatModel.snapshot.table != nil) }

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

    /// The panel's overlay layer (above the page, moving with the panel,
    /// hit-tested first), or a plain window's content view.
    private var overlayParent: NSView? {
        var view = textView?.superview
        while let candidate = view {
            if let container = candidate as? AtticPanelContentContainer { return container.overlayLayer }
            view = candidate.superview
        }
        return textView?.window?.contentView
    }

    /// Lists and cards float over the whole page (above the bottom row), in
    /// the page's root view, placed from text-view coordinates. Placing runs
    /// in the text's layout pass: a host joins its parent only after it
    /// (`AtticOverlayHierarchy`).
    private func placeOverlay(_ host: AtticOverlayHostingView, rect: NSRect) {
        guard let textView, let parent = overlayParent else { return }
        AtticOverlayHierarchy.place(host, in: parent, frame: parent.convert(rect, from: textView).integral)
    }

    /// Above the selection's first line, or under its last when there is no
    /// room above; never over the selection while either fits.
    func barPlacement(selection: NSRange) -> (frame: NSRect, below: Bool)? {
        guard let textView else { return nil }
        let first: NSRect, last: NSRect
        if tableMarkTarget, let rects = engine.tableSelectionRects(in: textView) {
            (first, last) = rects
        } else {
            guard selection.length > 0,
                  let firstRect = engine.rect(for: NSRange(location: selection.location, length: 1)),
                  let lastRect = engine.rect(for: NSRange(location: NSMaxRange(selection) - 1, length: 1)) else { return nil }
            (first, last) = (firstRect, lastRect)
        }
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
        if event.keyCode == 53, let closed = closeInnermostOnEscape(event) { return closed }
        guard let textView, let window = textView.window, event.window === window else { return false }
        let inTable = keyboardInTable
        guard window.firstResponder === textView || inTable, !textView.hasMarkedText(),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // ⌃Tab / ⌃⇧Tab (OD-7): the selection bar, when one shows, is the
        // next control (⌃Tab again returns to the text); otherwise the
        // keyboard leaves the editor for the page's next or previous control.
        // Aa stays on ⌘T and is a stop of its own on the way. While the
        // format row is open (its row has no other controls), ⌃Tab goes
        // between the text and the row.
        if event.keyCode == 48, flags == [.control] || flags == [.control, .shift] {
            let forward = flags == [.control]
            if formatModel.barKeyboardIndex != nil {
                exitBarKeyboard()
            } else if forward, formatModel.barShown {
                enterBarKeyboard()
            } else if formatModel.rowKeyboardIndex != nil {
                exitRowKeyboard()
            } else if isFormatBarOpen {
                enterRowKeyboard(at: forward ? 0 : rowItems.count - 1)
            } else if let leaveEditor {
                leaveEditor(forward)
            } else {
                return false
            }
            return true
        }
        if formatModel.barKeyboardIndex != nil { return handleBarKey(event, flags: flags) }
        if formatModel.rowKeyboardIndex != nil { return handleRowKey(event, flags: flags) }
        // In a table its own keys come first (marks on cells, ⌥⌘ arrows).
        if inTable { return false }
        guard flags.contains(.command), let command = NoteCommandCatalog.command(for: event) else { return false }
        router.run(command, from: .shortcut)
        return true
    }

    /// Esc closes the innermost open thing and is used up there, so it can
    /// never also reach the panel's "nothing left to close" (which hides the
    /// panel): the format row's style list, then a date or link card (its
    /// field has the keyboard), then the format row itself, unless the
    /// selection bar, its keyboard mode or the `/` list shows: those take
    /// Esc in the text view's own command path first. Returns nil when Esc
    /// isn't this chain's.
    func closeInnermostOnEscape(_ event: NSEvent) -> Bool? {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard event.type == .keyDown, flags.isEmpty, let window = textView?.window else { return nil }
        // An input method keeps its Esc wherever the keyboard is.
        if let editor = (event.window ?? window).firstResponder as? NSTextView, editor.hasMarkedText() { return nil }
        if formatModel.rowStyleListOpen {
            formatModel.rowStyleListOpen = false
            return true
        }
        if cardModel.card != nil, event.window === window {
            cancelCard()
            return true
        }
        if isFormatBarOpen, !formatModel.barShown, formatModel.barKeyboardIndex == nil, !slashModel.shown {
            // The row closes and the keyboard is the text's again (the note's
            // text would otherwise have nothing left to close and hide the
            // panel).
            closeFormatBar?()
            return true
        }
        return nil
    }

    // MARK: The format row's keyboard (OD-14)

    /// ⌘T or ⌃Tab: the keyboard's ring on one of the row's controls; the
    /// text keeps the caret (and the keys, read here first).
    func enterRowKeyboard(at index: Int = 0) {
        guard isFormatBarOpen else { return }
        exitBarKeyboard()
        formatModel.rowKeyboardIndex = max(0, min(index, rowItems.count - 1))
        announceRowItem()
    }

    func exitRowKeyboard() {
        formatModel.rowKeyboardIndex = nil
    }

    private func handleRowKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let index = formatModel.rowKeyboardIndex else { return false }
        let items = rowItems
        let count = items.count
        guard index < count else { exitRowKeyboard(); return false }
        switch event.keyCode {
        case 123 where flags.isEmpty: formatModel.rowKeyboardIndex = NoteFormatRowItem.step(index, forward: false, count: count)
        case 124 where flags.isEmpty: formatModel.rowKeyboardIndex = NoteFormatRowItem.step(index, forward: true, count: count)
        case 48 where flags.isEmpty || flags == [.shift]:
            formatModel.rowKeyboardIndex = NoteFormatRowItem.step(index, forward: !flags.contains(.shift), count: count)
        case 36, 76, 49:
            guard flags.isEmpty else { exitRowKeyboard(); return false }
            pressRowItem(items[index])
            return true
        default:
            // Anything else is writing: the ring goes, the key reaches the text.
            exitRowKeyboard()
            return false
        }
        announceRowItem()
        return true
    }

    func pressRowItem(_ item: NoteFormatRowItem) {
        switch item {
        case .style:
            guard NoteCommandCatalog.styles.contains(where: { formatModel.snapshot.isEnabled($0) }) else { NSSound.beep(); return }
            formatModel.rowStyleListOpen = true
        case let .command(command):
            guard formatModel.snapshot.isEnabled(command) else { NSSound.beep(); return }
            formatModel.run(command, from: .formatBar)
            announceRowItem()
        case .tableMenu:
            formatModel.rowTableMenuOpen = true
        case let .tableTool(tool):
            formatModel.runTable(tool)
            announceRowItem()
        case .close:
            closeFormatBar?()
        }
    }

    private func announceRowItem() {
        guard let index = formatModel.rowKeyboardIndex, let textView else { return }
        let text: String
        let items = rowItems
        guard index < items.count else { return }
        switch items[index] {
        case .tableMenu:
            text = String(localized: "Table")
        case let .tableTool(tool):
            text = tool.title
        case .style:
            text = String(localized: "Style, \(NoteCommandCatalog.styleName(formatModel.snapshot.paragraph))")
        case let .command(command):
            let title = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
            text = NoteCommandCatalog.lists.contains(command)
                ? "\(title), \(AtticFormatValue.spokenValue(formatModel.snapshot.value(command)))" : title
        case .close:
            text = String(localized: "Close Format")
        }
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
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
        hideBar()
        // A list that opens anew takes its side afresh; while it shows,
        // filtering keeps the side it has.
        if !slashModel.shown { slashPlacement = nil }
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
        returnKeyboardFromBar()
    }

    /// The open `/` list's and card's places (nil while closed): each keeps
    /// its side while it shows.
    private var slashPlacement: AtticDropdownLayout.Placement?
    private var cardPlacement: AtticDropdownLayout.Placement?

    /// The shared placement (`AtticDropdownSpace`) for a card anchored at
    /// `anchor` in the text view: in the panel's overlay, within the panel
    /// less its margin (the text view's visible part outside a panel).
    private func placeDropdown(_ host: AtticOverlayHostingView, idealWidth: CGFloat, height: CGFloat, anchor: NSRect,
                               current: AtticDropdownLayout.Placement?) -> AtticDropdownLayout.Placement? {
        guard let textView, let space = AtticDropdownSpace(around: textView, bounding: textView) else { return nil }
        let placed = space.place(idealWidth: idealWidth, height: height, anchor: space.anchor(anchor, in: textView),
                                 prefer: .below, current: current?.side)
        space.show(host, at: placed)
        return placed
    }

    private func placeSlashList() {
        guard let session = engine.slashSession,
              let anchor = engine.rect(for: NSRange(location: session.range.location, length: 1)) else { return }
        let d = AtticDropdownMetrics.self
        let wanted = CGFloat(slashModel.items.count) * d.rowHeight + d.inset * 2
        guard let placed = placeDropdown(slashHost, idealWidth: AtticDropdownLayout.listWidth(titles: slashModel.items.map(\.title),
                                                                                               match: session.query),
                                         height: wanted, anchor: anchor, current: slashPlacement) else { return }
        slashPlacement = placed
        if slashModel.viewportHeight != placed.heightLimit { slashModel.viewportHeight = placed.heightLimit }
        if slashModel.width != placed.width { slashModel.width = placed.width }
        if slashModel.query != session.query { slashModel.query = session.query }
        if slashModel.above != (placed.side == .above) { slashModel.above = placed.side == .above }
    }

    // MARK: Cards (date, link)

    func openDateCard(fromSlash: Bool) {
        hideBar()
        slashModel.hide()
        cardFromSlash = fromSlash
        cardSelection = selection
        cardAnchor = fromSlash ? engine.pendingSlashDate?.range : NSRange(location: selection.location, length: 0)
        cardModel.viewportHeight = nil
        cardModel.viewportWidth = nil
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
        cardModel.viewportHeight = nil
        cardModel.viewportWidth = nil
        cardModel.openLink(url: target.url)
        presentCard()
    }

    private var linkTarget: NoteLinkTarget?
    /// Link… on a cell's text, and where its card is anchored.
    private var cellLinkTarget: NoteCellLinkTarget?
    private var cellCardAnchor: NSRect?

    func openCellLinkCard(target: NoteCellLinkTarget) {
        guard let textView, let rects = engine.tableSelectionRects(in: textView) ?? engine.focusedTable.map({ view in
            let rect = view.canvas.convert(view.grid.cellRect(target.position), to: textView)
            return (rect, rect)
        }) else { return }
        hideBar()
        cardFromSlash = false
        linkTarget = nil
        cellLinkTarget = target
        cellCardAnchor = rects.first.union(rects.last)
        cardAnchor = NSRange(location: 0, length: 0)
        cardModel.viewportHeight = nil
        cardModel.viewportWidth = nil
        cardModel.openLink(url: target.url)
        presentCard()
    }

    private var cardSize = NSSize.zero

    /// Measure the opening width; the card reports subsequent natural heights.
    private func presentCard() {
        let room = AtticDropdownMetrics.shadowRoom
        let measure = NSHostingView(rootView: NoteFormatCardView(model: cardModel).atticDesign(design))
        let fitting = measure.fittingSize
        cardSize = NSSize(width: max(0, fitting.width - room * 2), height: max(0, fitting.height - room * 2))
        cardPlacement = nil
        placeCard()
        cardHost.isInteractive = true
        cardHost.isHidden = false
        installCardDismissal()
        // The card's field takes the keyboard (typing goes to it, not the note).
        DispatchQueue.main.async { [weak self] in self?.focusCardField(attempts: 3) }
    }

    private func placeCard() {
        if cellLinkTarget != nil, let anchor = cellCardAnchor {
            guard let placed = placeDropdown(cardHost, idealWidth: cardSize.width, height: cardSize.height,
                                             anchor: anchor, current: cardPlacement) else { return }
            cardPlacement = placed
            if cardModel.viewportWidth != placed.width { cardModel.viewportWidth = placed.width }
            if cardModel.viewportHeight != placed.heightLimit { cardModel.viewportHeight = placed.heightLimit }
            if cardModel.above != (placed.side == .above) { cardModel.above = placed.side == .above }
            return
        }
        guard let anchorRange = cardAnchor, engine.textStorage.length > 0 else { return }
        let length = engine.textStorage.length
        let start = min(anchorRange.location, length - 1)
        let end = min(max(start, NSMaxRange(anchorRange) - 1), length - 1)
        guard let first = engine.rect(for: NSRange(location: start, length: 1)) ?? caretRect(),
              let last = engine.rect(for: NSRange(location: end, length: 1)) ?? caretRect() else { return }
        guard let placed = placeDropdown(cardHost, idealWidth: cardSize.width, height: cardSize.height,
                                         anchor: first.union(last), current: cardPlacement) else { return }
        cardPlacement = placed
        if cardModel.viewportWidth != placed.width { cardModel.viewportWidth = placed.width }
        if cardModel.viewportHeight != placed.heightLimit { cardModel.viewportHeight = placed.heightLimit }
        if cardModel.above != (placed.side == .above) { cardModel.above = placed.side == .above }
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
                let inside = self.cardHost.contentRect.contains(point)
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
        if let target = cellLinkTarget {
            let parsed = URL(string: url)
            guard parsed?.scheme == "https" || parsed?.scheme == "http", parsed?.host != nil else { return false }
            cellLinkTarget = nil
            closeCard(refocus: false, restoring: nil)
            return engine.commitCellLink(url, target: target)
        }
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
        if let target = cellLinkTarget {
            cellLinkTarget = nil
            closeCard(refocus: false, restoring: nil)
            engine.commitCellLink(nil, target: target)
            return
        }
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
        if let target = cellLinkTarget {
            // Back to the cell the card was opened from.
            cellLinkTarget = nil
            closeCard(refocus: false, restoring: nil)
            if refocus, let (attachment, _) = engine.tableAttachment(id: target.tableID),
               attachment.table.contains(target.position) {
                attachment.hostedView?.activate(target.position, caret: .range(target.selection))
            }
            return
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

    // MARK: Empty-line hint (OD-14, p2-36 draft 7)

    /// The caret sits on an empty line of the body (never the title's): two
    /// character reads, cheap enough for every selection change.
    func caretOnEmptyLine(_ range: NSRange) -> Bool {
        guard range.length == 0 else { return false }
        let string = engine.textStorage.string as NSString
        let location = range.location
        guard location > 0, location <= string.length, Self.isLineBreak(string.character(at: location - 1)) else { return false }
        return location == string.length || Self.isLineBreak(string.character(at: location))
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x2028
    }

    /// The hint shows on an empty Body line with the caret in it (a line
    /// already given a style, or a list item, keeps its own look), never
    /// during a composition, the `/` list or a card.
    private func updateHint() {
        guard let textView else { return }
        let current = selection
        let show = !engine.isReadOnly && caretOnEmptyLine(current) && engine.paragraphStyle(at: current.location) == .body
            && !textView.hasMarkedText() && engine.slashSession == nil && cardModel.card == nil
        if show, let rect = caretRect() {
            let size = hintHost.fittingSize
            let frame = NSRect(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2, width: size.width, height: size.height).integral
            if hintHost.frame != frame { hintHost.frame = frame }
            if !hintShown {
                hintHost.isHidden = false
                hintShown = true
                // A hint, not content: VoiceOver reads it after the text.
                textView.setAccessibilityHelp(NoteSlashHintView.text)
            }
        } else if hintShown {
            hideHint()
        }
    }

    private func hideHint() {
        hintHost.isHidden = true
        hintShown = false
        textView?.setAccessibilityHelp(nil)
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
