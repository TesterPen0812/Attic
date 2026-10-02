import AppKit
import SwiftUI

// MARK: - Attic's own dropdowns (E1)

// The one pop-over list Attic draws itself (owner, 2026-10-02: E1 of
// mockup p2-25, with p2-24 D's rows and p2-23's width rule): the `/` list,
// the date card (Notes and Tasks), the tag and priority pickers, Aa and the
// link card. Native menus (right-click, ⋯, the menu bar) stay native.
//
// - `AtticDropdownCard`: the solid card (no blur), one hairline, D's shadow,
//   20 pt corners, rows 10 pt in.
// - `AtticDropdownRow`: a 32 pt row, touching its neighbours; the pill is the
//   whole row. One highlight per list, which the keyboard and the pointer
//   share (`onHover` moves the list's).
// - `AtticDropdownField`: the card's field (Find or add a tag, the date).
// - `AtticDropdownLayout`: the width rule and where the card opens.
// - `atticDropdown(isPresented:…)`: shows a card in the panel's overlay
//   layer, so opening, filtering and closing it never re-render the page
//   behind it.
//
// Every value is in `AtticDropdownMetrics` and the colour tokens
// (`popoverFill`, `popoverOuterRim`, `dropdownHighlight`, `dropdownShadow`,
// `dropdownContactShadow`).

/// The card's face: a solid fill, one hairline just outside it (Attic's
/// outer-rim token, 1 pt under Increase Contrast) and D's two shadows. Solid,
/// so Reduce Transparency changes nothing.
struct AtticDropdownSurface: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticDropdownMetrics.cornerRadius, style: .continuous)
        let edge = design.increaseContrast ? AtticHairline.widthIncreased : AtticHairline.width
        ZStack {
            AtticOutsideShadow(shape: shape, color: tokens.dropdownShadow, spec: AtticShadows.dropdown)
            AtticOutsideShadow(shape: shape, color: tokens.dropdownContactShadow, spec: AtticShadows.dropdownContact)
            shape.fill(tokens.popoverFill.color)
            // CSS's `0 0 0 .5px`: a ring wholly outside the fill.
            shape.inset(by: -edge / 2).stroke(tokens.popoverOuterRim.color, lineWidth: edge)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The card: its rows or fields 10 pt in, on `AtticDropdownSurface`. With
/// no `width` it is as wide as its content, never under 144 pt; the
/// presenter caps it at the panel's margin (`AtticDropdownLayout.width`).
struct AtticDropdownCard<Content: View>: View {
    var width: CGFloat?
    @ViewBuilder let content: Content

    init(width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(m.inset)
            .frame(minWidth: width == nil ? m.minWidth : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .background(AtticDropdownSurface())
    }
}

/// A quiet gap between a card's groups (space, never a line).
struct AtticDropdownGap: View {
    var height: CGFloat = AtticDropdownMetrics.groupGap

    var body: some View { Color.clear.frame(height: height).accessibilityHidden(true) }
}

/// One row of a dropdown (p2-24 D): 32 pt, touching; an optional check
/// column, a priority's mark, a 14 pt icon in an 18 pt slot, the 14 pt
/// name and a short trailing detail (⌥⌘2, 2 Oct). Never a hint column.
///
/// One highlight (fix 1): a list with a keyboard highlight owns it and the
/// pointer moves it (`onHover`), as in a native menu; with no `onHover` the
/// row lights while hovered.
struct AtticDropdownRow: View {
    let title: String
    var systemName: String?
    /// nil: no check column.
    var check: AtticCheckState?
    /// A priority's mark column (`.none` keeps the column empty).
    var mark: AtticPriority?
    var detail: String?
    /// Typed text to embolden in the name (the `/` list's filter).
    var match: String?
    var isHighlighted = false
    var titleInk: AtticInk = .body
    var onHover: ((Bool) -> Void)?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    init(title: String, systemName: String? = nil, check: AtticCheckState? = nil, mark: AtticPriority? = nil,
         detail: String? = nil, match: String? = nil, isHighlighted: Bool = false, titleInk: AtticInk = .body,
         onHover: ((Bool) -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemName = systemName
        self.check = check
        self.mark = mark
        self.detail = detail
        self.match = match
        self.isHighlighted = isHighlighted
        self.titleInk = titleInk
        self.onHover = onHover
        self.action = action
    }

    /// The row is lit: the list's highlight, or its own hover in a list
    /// without one.
    static func isLit(highlighted: Bool, hovered: Bool, listOwnsHighlight: Bool) -> Bool {
        listOwnsHighlight ? highlighted : (highlighted || hovered)
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        let tokens = design.tokens
        let lit = Self.isLit(highlighted: isHighlighted, hovered: hovered, listOwnsHighlight: onHover != nil)
        let pill = RoundedRectangle(cornerRadius: m.highlightRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: m.columnGap) {
                    if let check {
                        Group {
                            switch check {
                            case .on: AtticIcon(systemName: "checkmark", size: m.checkSize, weight: .semibold, ink: .glyph)
                            case .mixed: AtticIcon(systemName: "minus", size: m.checkSize, weight: .semibold, ink: .glyph)
                            case .off: Color.clear
                            }
                        }
                        .frame(width: m.checkSlot)
                    }
                    if let mark {
                        AtticPriorityMark(priority: mark).frame(width: m.markSlot)
                    }
                    if let systemName {
                        AtticIcon(systemName: systemName, size: m.iconSize, ink: .icon)
                            .frame(width: m.iconSlot)
                    }
                    name
                }
                Spacer(minLength: detail == nil ? 0 : m.detailGap)
                if let detail {
                    AtticText(verbatim: detail, style: .shortcut, ink: .helper)
                        .fixedSize()
                }
            }
            .padding(.horizontal, m.rowPadding)
            .frame(height: m.rowHeight)
            .background(pill.fill((lit ? tokens.dropdownHighlight : .clear).color))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: m.highlightRadius, height: m.rowHeight))
        // The whole row answers the pointer (no dead gap between rows). A
        // row sliding under a resting pointer as the keyboard scrolls the
        // list is not the pointer moving: the keyboard keeps its highlight.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                if !hovered { hovered = true }
                onHover?(true)
            case .ended:
                if hovered { hovered = false }
                onHover?(false)
            }
        }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(check == .on || isHighlighted ? .isSelected : [])
        .accessibilityValue(check == .mixed ? String(localized: "some selected tasks") : "")
    }

    @ViewBuilder
    private var name: some View {
        if let match, !match.isEmpty, let range = title.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
            Text(Self.emboldened(title, range: range))
                .font(AtticTextStyle.dropdownRow.font)
                .foregroundStyle(design.tokens.color(titleInk))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            AtticText(verbatim: title, style: .dropdownRow, ink: titleInk, truncates: true)
        }
    }

    private static func emboldened(_ title: String, range: Range<String.Index>) -> AttributedString {
        var string = AttributedString(title)
        if let lower = AttributedString.Index(range.lowerBound, within: string),
           let upper = AttributedString.Index(range.upperBound, within: string) {
            string[lower..<upper].font = .system(size: AtticTextStyle.dropdownHeading.spec.size,
                                                 weight: AtticTextStyle.dropdownHeading.spec.weight)
        }
        return string
    }
}

/// A card's field (Find or add a tag, the date, a link): a row's height and
/// pill on the recessed fill. Its placeholder sets its width, so a card
/// that fits its content is as wide as the placeholder asks.
struct AtticDropdownField: View {
    @Binding var text: String
    let placeholder: String
    /// A trailing glyph (the tag field's magnifier).
    var systemName: String?
    var focus: FocusState<Bool>.Binding
    /// VoiceOver's name for the field (the placeholder by default) and
    /// the UI tests' identifier.
    var label: String?
    var identifier: String?
    var onSubmit: () -> Void = {}

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticDropdownMetrics.self
        let font = AtticTextStyle.dropdownRow.font
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Text(verbatim: placeholder).font(font).lineLimit(1).fixedSize().hidden()
                    .accessibilityHidden(true)
                TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(design.tokens.color(.helper)))
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused(focus)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(label ?? placeholder)
                    .accessibilityIdentifier(identifier ?? "")
            }
            if let systemName {
                Spacer(minLength: m.detailGap)
                AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, ink: .helper)
            }
        }
        .padding(.horizontal, m.rowPadding)
        .frame(height: m.fieldHeight)
        .background(RoundedRectangle(cornerRadius: m.highlightRadius, style: .continuous).fill(design.tokens.recessed.color))
    }
}

// MARK: - Layout

/// The width rule (p2-23) and where a card opens.
enum AtticDropdownLayout {
    enum Side: Equatable, Sendable { case below, above }

    /// A card's width: its content's, never under 144 pt, never wider than
    /// `available` (the panel less its 12 pt margins).
    static func width(ideal: CGFloat, available: CGFloat) -> CGFloat {
        min(max(ideal.rounded(.up), AtticDropdownMetrics.minWidth), max(0, available.rounded(.down)))
    }

    /// The content width of a list of icon-and-name rows (the `/` list),
    /// with the typed `match` emboldened in each name; the card adds its
    /// inset.
    static func listWidth(titles: [String], match: String? = nil) -> CGFloat {
        let m = AtticDropdownMetrics.self
        let regular = AtticTextStyle.dropdownRow
        let bold = AtticTextStyle.dropdownHeading
        let widest = titles.map { title -> CGFloat in
            var width = regular.measuredWidth(title)
            if let match, !match.isEmpty,
               let range = title.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
                let part = String(title[range])
                width += max(0, bold.measuredWidth(part) - regular.measuredWidth(part))
            }
            return width
        }.max() ?? 0
        return m.inset * 2 + m.rowPadding * 2 + m.iconSlot + m.columnGap + widest
    }

    /// Where a card of `size` opens, in top-down coordinates (y grows
    /// down): its left edge on the anchor's (the caret's column, a strip
    /// button), moved left only as far as `bounds` (the panel less its
    /// margin) needs; `prefer`'s side when it fits there, else the other
    /// side, else the roomier one, kept inside `bounds`.
    static func frame(size: CGSize, anchor: CGRect, bounds: CGRect, prefer: Side,
                      gap: CGFloat = AtticDropdownMetrics.anchorGap) -> (frame: CGRect, side: Side) {
        let x = max(bounds.minX, min(anchor.minX, bounds.maxX - size.width))
        let belowY = anchor.maxY + gap
        let aboveY = anchor.minY - gap - size.height
        let fitsBelow = belowY + size.height <= bounds.maxY
        let fitsAbove = aboveY >= bounds.minY
        let side: Side
        switch prefer {
        case .below: side = fitsBelow || !fitsAbove && bounds.maxY - belowY >= anchor.minY - gap - bounds.minY ? .below : .above
        case .above: side = fitsAbove || !fitsBelow && anchor.minY - gap - bounds.minY > bounds.maxY - belowY ? .above : .below
        }
        var y = side == .below ? belowY : aboveY
        y = max(bounds.minY, min(y, bounds.maxY - size.height))
        return (CGRect(x: x, y: y, width: size.width, height: size.height), side)
    }

    /// `rect` in `view` turned top-down (and back: the flip is its own
    /// inverse).
    static func topDown(_ rect: CGRect, in view: NSView) -> CGRect {
        view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Overlay host

/// A SwiftUI host laid over a page in the panel's overlay layer (Notes' bar,
/// `/` list and cards; every dropdown). It never takes the keyboard on a
/// click unless it holds a field (`acceptsKeyboard`), and only its content's
/// rectangle answers the pointer: the shadow room around it is click-through.
final class AtticOverlayHostingView: NSHostingView<AnyView> {
    /// The content's inset from the host's edges (the shadow room).
    var contentInset: CGFloat = AtticNoteFormatMetrics.shadowRoom
    var isInteractive = false
    /// The host takes the keyboard (a card with a field, a picker's keys).
    var acceptsKeyboard = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { acceptsKeyboard }

    /// The content's rectangle (the host less its shadow room).
    var contentRect: NSRect { bounds.insetBy(dx: contentInset, dy: contentInset) }

    /// What VoiceOver hears this host as: a dropdown is a menu with its
    /// items (NSHostingView would say "group").
    var menuLabel: String?

    override func accessibilityRole() -> NSAccessibility.Role? {
        menuLabel == nil ? super.accessibilityRole() : .menu
    }

    override func accessibilityLabel() -> String? {
        menuLabel ?? super.accessibilityLabel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard contentRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Presenting

/// The open card's motion and size, which only the card's own host reads.
@MainActor
final class AtticDropdownStageModel: ObservableObject {
    @Published var shown = false
    @Published var side: AtticDropdownLayout.Side = .below
    /// The card's width once the width rule capped it (nil: its content's).
    @Published var width: CGFloat?
    /// Bumped once the card's host has the keyboard: the content's own
    /// focus (`atticDropdownFocus`) takes it then.
    @Published var focusRequest = 0
}

private struct AtticDropdownFocusRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Changes when a dropdown's host takes the keyboard.
    var atticDropdownFocusRequest: Int {
        get { self[AtticDropdownFocusRequestKey.self] }
        set { self[AtticDropdownFocusRequestKey.self] = newValue }
    }
}

extension View {
    /// Focuses `focus` as the view appears and again when its dropdown's
    /// host takes the keyboard (the host joins the window after SwiftUI has
    /// built the content).
    func atticDropdownFocus(_ focus: FocusState<Bool>.Binding, when enabled: Bool = true) -> some View {
        modifier(AtticDropdownFocusModifier(focus: focus, enabled: enabled))
    }
}

private struct AtticDropdownFocusModifier: ViewModifier {
    var focus: FocusState<Bool>.Binding
    let enabled: Bool
    @Environment(\.atticDropdownFocusRequest) private var request

    func body(content: Content) -> some View {
        content
            .onAppear { if enabled { focus.wrappedValue = true } }
            .onChange(of: request) { _, _ in if enabled { focus.wrappedValue = true } }
    }
}

/// The card on screen, with the pop-over preset's motion: it springs in
/// from the edge by its anchor (Lively by default) and tucks away; a fade
/// under Reduce Motion or Animations: Reduced. Only transforms and opacity
/// animate, in this host alone.
struct AtticDropdownStage: View {
    @ObservedObject var model: AtticDropdownStageModel
    let content: AnyView

    @Environment(\.atticDesign) private var design

    var body: some View {
        let preset = AtticMotionPreset.popover
        let reduce = design.reduceMotion
        // A card below its anchor comes down from its top edge; above it, up
        // from its bottom edge.
        let fromTop = model.side == .below
        AtticDropdownCard(width: model.width) { content }
            .scaleEffect(model.shown ? 1 : preset.hiddenScale(reduceMotion: reduce),
                         anchor: fromTop ? .topLeading : .bottomLeading)
            .offset(y: model.shown || reduce ? 0 : (fromTop ? -preset.rise : preset.rise))
            .opacity(model.shown ? 1 : 0)
            .animation(preset.animation(reduceMotion: reduce, showing: model.shown), value: model.shown)
            .environment(\.atticDropdownFocusRequest, model.focusRequest)
            .padding(AtticDropdownMetrics.shadowRoom)
    }
}

/// Shows one dropdown card in the panel's overlay layer (above the page,
/// moving with the panel, hit-tested first), placed by the width rule from
/// its anchor. The page behind is never re-rendered: the card has its own
/// host, and only the state that opened it changes. While it is open its
/// keys are its own (`AtticTextInput.isPopoverOpen`); Esc, a click outside
/// or the panel losing the keyboard closes it, and the keyboard goes back
/// where it was.
@MainActor
final class AtticDropdownPresenter {
    /// How many dropdowns are open (the row and page keys stand aside).
    private(set) static var openCount = 0
    static var isAnyOpen: Bool { openCount > 0 }

    let stage = AtticDropdownStageModel()
    private(set) var host: AtticOverlayHostingView?
    private(set) var isOpen = false
    /// Asked to open (the binding is true): the next turn presents.
    var wantsOpen = false
    /// Sets the presenting binding to false.
    var onDismiss: (() -> Void)?
    var prefer: AtticDropdownLayout.Side = .below
    var label = ""
    var design = AtticDesignContext()
    var content = AnyView(EmptyView())

    private weak var anchor: NSView?
    private weak var previousResponder: NSResponder?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var removal: DispatchWorkItem?

    init() {}

    private var root: AnyView {
        AnyView(AtticDropdownStage(model: stage, content: content).atticDesign(design))
    }

    /// The overlay layer and the panel's visible rectangle in it; a plain
    /// window's content view otherwise.
    static func overlay(for view: NSView) -> (parent: NSView, panel: CGRect)? {
        var candidate = view.superview
        while let current = candidate {
            if let container = current as? AtticPanelContentContainer {
                return (container.overlayLayer, container.hostingView.frame)
            }
            candidate = current.superview
        }
        guard let content = view.window?.contentView else { return nil }
        return (content, content.bounds)
    }

    /// Opens the card from `anchor`.
    func present(from anchor: NSView) {
        guard !isOpen, let window = anchor.window, let overlay = Self.overlay(for: anchor) else { return }
        removal?.cancel()
        removal = nil
        host?.removeFromSuperview()
        self.anchor = anchor
        let m = AtticDropdownMetrics.self
        let room = m.shadowRoom
        stage.shown = false
        stage.width = nil
        stage.side = prefer
        let host = AtticOverlayHostingView(rootView: root)
        host.contentInset = room
        host.acceptsKeyboard = true
        host.isInteractive = true
        // The content's size, once, as it opens (the card keeps its width
        // while it is open, so filtering never makes it jump).
        let fitting = host.fittingSize
        let bounds = AtticDropdownLayout.topDown(overlay.panel, in: overlay.parent).insetBy(dx: m.panelMargin, dy: m.panelMargin)
        let width = AtticDropdownLayout.width(ideal: fitting.width - room * 2, available: bounds.width)
        if width != (fitting.width - room * 2).rounded(.up) { stage.width = width }
        let size = CGSize(width: width, height: max(0, fitting.height - room * 2))
        let anchorRect = AtticDropdownLayout.topDown(anchor.convert(anchor.bounds, to: overlay.parent), in: overlay.parent)
        let placed = AtticDropdownLayout.frame(size: size, anchor: anchorRect, bounds: bounds, prefer: prefer)
        stage.side = placed.side
        host.frame = AtticDropdownLayout.topDown(placed.frame.insetBy(dx: -room, dy: -room), in: overlay.parent).integral
        host.menuLabel = label
        overlay.parent.addSubview(host, positioned: .above, relativeTo: nil)
        self.host = host
        isOpen = true
        Self.openCount += 1
        previousResponder = Self.owner(of: window.firstResponder)
        install(in: window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            self.takeKeyboard()
            self.stage.shown = true
        }
    }

    /// Opens it if it is still asked for and the anchor is in a window
    /// (otherwise the anchor calls again when it joins one).
    func presentIfWanted(from anchor: NSView) {
        guard wantsOpen, !isOpen, anchor.window != nil else { return }
        wantsOpen = false
        present(from: anchor)
    }

    /// New content while open (the page's state changed: a tick, a failure line).
    func update() {
        host?.rootView = root
    }

    /// Closes the card (the binding went false, or the anchor went away).
    func close(restoreFocus: Bool, immediately: Bool = false) {
        wantsOpen = false
        guard isOpen, let host else { return }
        isOpen = false
        Self.openCount = max(0, Self.openCount - 1)
        uninstall()
        host.isInteractive = false
        host.setAccessibilityElement(false)
        let window = host.window
        let responderInside = (window?.firstResponder as? NSView).map { $0 === host || $0.isDescendant(of: host) } ?? false
        if restoreFocus, responderInside, let window {
            if let previous = previousResponder as? NSView, previous.window === window {
                window.makeFirstResponder(previous)
            } else {
                window.makeFirstResponder(nil)
            }
        } else if responderInside {
            window?.makeFirstResponder(nil)
        }
        previousResponder = nil
        if immediately {
            host.removeFromSuperview()
            self.host = nil
            return
        }
        stage.shown = false
        let work = DispatchWorkItem { [weak self, weak host] in
            host?.removeFromSuperview()
            if let self, self.host === host { self.host = nil }
        }
        removal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AtticDropdownMetrics.leaveCleanup, execute: work)
    }

    /// The person closed it (Esc, a click outside, the panel let go).
    func dismiss() {
        guard isOpen else { return }
        onDismiss?()
        close(restoreFocus: true)
    }

    /// The card's field, else the host itself, takes the keyboard; then the
    /// content's own focus follows.
    private func takeKeyboard() {
        guard let host, let window = host.window else { return }
        host.layoutSubtreeIfNeeded()
        if let field = Self.firstTextField(in: host) {
            window.makeFirstResponder(field)
        } else {
            window.makeFirstResponder(host)
        }
        stage.focusRequest += 1
    }

    /// The view to give the keyboard back to: a field's own view, not the
    /// window's shared field editor, which leaves with the editing.
    static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            return field
        }
        return responder
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    private func install(in window: NSWindow) {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.keyCode == 53, event.window === self.host?.window else { return event }
            self.dismiss()
            return nil
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isOpen, let host = self.host else { return event }
            guard event.window === host.window else {
                self.dismiss()
                return event
            }
            if host.contentRect.contains(host.convert(event.locationInWindow, from: nil)) { return event }
            // A click on the button that opened it only closes it.
            let onAnchor = self.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            self.dismiss()
            return onAnchor ? nil : event
        }
        monitors = [keys, clicks].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
    }

    private func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

/// The anchor a dropdown opens from: an empty view behind the control.
struct AtticDropdownAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let prefer: AtticDropdownLayout.Side
    let label: String
    let design: AtticDesignContext
    let content: () -> AnyView

    final class AnchorView: NSView {
        /// Opens a card that was asked for before this view had a window.
        var onWindow: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI's layout pass, so the anchor has its frame.
            DispatchQueue.main.async { [weak self] in self?.onWindow?() }
        }
    }

    func makeCoordinator() -> AtticDropdownPresenter { AtticDropdownPresenter() }

    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }

    func updateNSView(_ view: AnchorView, context: Context) {
        let presenter = context.coordinator
        let binding = $isPresented
        presenter.onDismiss = { if binding.wrappedValue { binding.wrappedValue = false } }
        presenter.prefer = prefer
        presenter.label = label
        presenter.design = design
        guard isPresented else {
            if presenter.isOpen || presenter.wantsOpen { presenter.close(restoreFocus: true) }
            return
        }
        presenter.content = content()
        if presenter.isOpen {
            presenter.update()
        } else if !presenter.wantsOpen {
            presenter.wantsOpen = true
            view.onWindow = { [weak view, weak presenter] in
                guard let view, let presenter else { return }
                presenter.presentIfWanted(from: view)
            }
            // After this update: the anchor has its frame, and opening
            // changes no state while SwiftUI is updating views.
            DispatchQueue.main.async { [weak view, weak presenter] in
                guard let view, let presenter else { return }
                presenter.presentIfWanted(from: view)
            }
        }
    }

    /// The binding went false (the anchor leaves with it), or the control
    /// itself went away: the card leaves with its motion and the keyboard
    /// goes back (its host removes itself, whatever happens to this anchor).
    static func dismantleNSView(_ view: AnchorView, coordinator: AtticDropdownPresenter) {
        coordinator.close(restoreFocus: true)
    }
}

extension View {
    /// Shows `content` in Attic's dropdown card while `isPresented`, its left
    /// edge on this view's, on the `prefer` side when there is room. Only
    /// for Attic's own pop-over lists; native menus stay native.
    func atticDropdown<Content: View>(isPresented: Binding<Bool>, prefer: AtticDropdownLayout.Side = .below,
                                      label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(AtticDropdownModifier(isPresented: isPresented, prefer: prefer, label: label, card: content))
    }
}

private struct AtticDropdownModifier<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let prefer: AtticDropdownLayout.Side
    let label: String
    let card: () -> Card

    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        // The anchor exists only while the card is asked for: a row at rest
        // costs nothing (no AppKit view per row).
        content.background {
            if isPresented {
                AtticDropdownAnchor(isPresented: $isPresented, prefer: prefer, label: label, design: design,
                                    content: { AnyView(card()) })
                    .accessibilityHidden(true)
            }
        }
    }
}
