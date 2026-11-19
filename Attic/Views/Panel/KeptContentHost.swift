import AppKit
import SwiftUI

// MARK: - Kept content behind its own host (ops/design/host-boundary.md §4)

/// Content the panel keeps built while it is not shown (a warmed Tasks tab)
/// lives in a hosting view of its own, so an update elsewhere in the panel
/// does not run, lay out or walk its SwiftUI graph, and an update inside it
/// does not run the panel's (host-boundary.md §4.3).
///
/// The rules (§4.2): the host is always attached to the window (never
/// detached or `isHidden`: both broke the resize driver, hidden-pages.md:34),
/// takes the live size, gets no new root view while it is not shown, and
/// takes no clicks and answers no accessibility queries while it is not.
final class KeptContentHostingView: NSHostingView<AnyView> {
    /// Whether the content takes part in input and accessibility: the tab
    /// selected on the active page (host-boundary.md §4.2, HB-01). Drawn is
    /// not enough: a swipe or a slide draws a neighbour, and a shell switch
    /// draws the departing page, and neither takes a click, a key or a read.
    /// Not interactive: no clicks, no first responder, no key view, not an
    /// accessibility element, no children and no hit (a client reads only
    /// the tab in use, and the panel's own hit walk never enters this host).
    var isInteractive = true {
        didSet {
            guard isInteractive != oldValue else { return }
            if isInteractive {
                joinAccessibilityAfterTheFirstFrame()
            } else {
                stopJoining()
                isAccessible = false
                releaseKeyboard()
            }
        }
    }

    /// Whether accessibility reads the content. A host that comes into use
    /// takes clicks and the keyboard at once, but joins accessibility only
    /// after its first drawn frame: a client's read mounts the rows it asks
    /// for (Later 9 to 17 on its first reveal), and in that frame it made
    /// the reveal's longest frame 40 ms longer (HB-05, the lead's ruling).
    private(set) var isAccessible = true
    private var joinLink: CADisplayLink?

    /// Joins on the next display frame, after the reveal's frame has been
    /// committed; a window on no screen (draws no frames) joins on the next
    /// turn of the run loop.
    private func joinAccessibilityAfterTheFirstFrame() {
        stopJoining()
        isAccessible = false
        guard window?.screen != nil else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInteractive, self.joinLink == nil else { return }
                self.isAccessible = true
            }
            return
        }
        let link = displayLink(target: self, selector: #selector(joinAccessibility(_:)))
        link.add(to: .main, forMode: .common)
        joinLink = link
    }

    @objc private func joinAccessibility(_ link: CADisplayLink) {
        stopJoining()
        if isInteractive { isAccessible = true }
    }

    private func stopJoining() {
        joinLink?.invalidate()
        joinLink = nil
    }

    /// A host taken out of its window stops waiting (the link holds it).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, joinLink != nil {
            stopJoining()
            isAccessible = isInteractive
        }
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        // The slot decides the size, never the content (as the panel's root,
        // `AtticPanelHostingView`): nothing flows from SwiftUI to AppKit.
        sizingOptions = []
        AtticHostDragHooks.install(on: KeptContentHostingView.self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// As the panel's root host (`AtticPanelHostingView.layout`): this host's
    /// SwiftUI update runs here, and overlay hierarchy changes from it wait
    /// for the next turn (HB-03). The root's pass is not on the stack when
    /// this host lays out alone.
    override func layout() {
        #if DEBUG
        KeptContentHostCounts.layout(interactive: isInteractive)
        #endif
        AtticOverlayHierarchy.layoutPass { super.layout() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    /// The panel takes its first press wherever it lands (O14-01), in a
    /// nested host as in the panel's root.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        isInteractive && super.acceptsFirstResponder
    }

    override var canBecomeKeyView: Bool {
        isInteractive && super.canBecomeKeyView
    }

    override func isAccessibilityElement() -> Bool {
        isInteractive && isAccessible && super.isAccessibilityElement()
    }

    override func accessibilityChildren() -> [Any]? {
        #if DEBUG
        KeptContentHostCounts.accessibilityChildren(interactive: isInteractive)
        #endif
        return isInteractive && isAccessible ? super.accessibilityChildren() : []
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        #if DEBUG
        KeptContentHostCounts.accessibilityHit(interactive: isInteractive)
        #endif
        return isInteractive && isAccessible ? super.accessibilityHitTest(point) : nil
    }

    /// The kept host holding `window`'s keyboard gives it to the view around
    /// it that takes it (the departure step, HB-02: before the departing
    /// tab's focus is cleared).
    static func releaseKeyboard(in window: NSWindow?) {
        var view = window?.firstResponder as? NSView
        while let current = view, !(current is KeptContentHostingView) { view = current.superview }
        (view as? KeptContentHostingView)?.releaseKeyboard()
    }

    /// A host that stops taking part while the keyboard is inside it gives
    /// the keyboard to the nearest view around it that takes it, read back
    /// and, if refused, to the window, so no key reaches a graph that is
    /// not in use (HB-02).
    private func releaseKeyboard() {
        guard let window, let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return }
        var ancestor = superview
        while let view = ancestor, !view.acceptsFirstResponder { ancestor = view.superview }
        if window.makeFirstResponder(ancestor), let ancestor, window.firstResponder === ancestor { return }
        window.makeFirstResponder(nil)
    }
}

/// The container the slot sizes; the host fills it.
final class KeptContentContainer: NSView {
    fileprivate(set) var host: KeptContentHostingView?
    override var isFlipped: Bool { true }

    /// The container itself is never a click target: the host decides.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let host, host.isInteractive else { return nil }
        return super.hitTest(point)
    }
}

/// Places content in its own `KeptContentHostingView` (host-boundary.md §4).
/// Two states: `drawn` decides the root (not drawn, it is set once, on the
/// update that hides it, and not again until it is drawn, so the parent's
/// updates do not invalidate the hidden graph); `interactive` decides input,
/// keyboard and accessibility. The root is set under the update's
/// transaction, so an animation or its suppression crosses the boundary
/// (HB-08).
struct KeptContentHost<Content: View>: NSViewRepresentable {
    let drawn: Bool
    let interactive: Bool
    /// A named space the content reads, declared again at the host's root
    /// (the host fills the slot that declares it outside, so the origins
    /// are the same).
    var space: NamedCoordinateSpace?
    @ViewBuilder let content: () -> Content

    @MainActor
    final class Coordinator {
        /// The root last set was a hidden one.
        var hiddenRootSet = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeptContentContainer {
        let container = KeptContentContainer()
        let host = KeptContentHostingView(rootView: root(context))
        host.isInteractive = interactive
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.host = host
        container.addSubview(host)
        context.coordinator.hiddenRootSet = !drawn
        #if DEBUG
        KeptContentHostCounts.root(drawn: drawn)
        #endif
        return container
    }

    func updateNSView(_ container: KeptContentContainer, context: Context) {
        guard let host = container.host else { return }
        let coordinator = context.coordinator
        // Two hidden updates in a row set nothing (as `TasksKeptPage`'s
        // equality, which this boundary carries across the host).
        if drawn || !coordinator.hiddenRootSet {
            let root = root(context)
            withTransaction(context.transaction) { host.rootView = root }
            #if DEBUG
            KeptContentHostCounts.root(drawn: drawn)
            #endif
        }
        coordinator.hiddenRootSet = !drawn
        host.isInteractive = interactive
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeptContentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func root(_ context: Context) -> AnyView {
        let forwarded = KeptEnvironment(source: context.environment)
        if let space {
            return AnyView(content().coordinateSpace(space).modifier(forwarded))
        }
        return AnyView(content().modifier(forwarded))
    }
}

/// The environment a kept host's content gets from the panel, by name
/// (host-boundary.md §5). The whole environment is never copied: it carries
/// SwiftUI's own focus values of the panel's host, and the tab host's focus
/// bridge then gave the keyboard back to the panel's host whenever a row was
/// focused (trace run 13edbb11+trace: `FocusBridge.moveFocus` from
/// `KeptContentHostingView.layout` made the panel's root host first
/// responder). What the host itself derives from its window (reduce motion,
/// contrast, display scale, active appearance, undo manager) is left to it.
/// `KeptContentHostTests.testTheTasksContentReadsOnlyForwardedOrHostDerivedValues`
/// fails when the Tasks content reads a value that is neither here nor
/// derived by the host.
struct KeptEnvironment: ViewModifier {
    let source: EnvironmentValues

    struct Entry {
        let name: String
        let copy: (EnvironmentValues, inout EnvironmentValues) -> Void
    }

    private static func entry<Value>(_ name: String, _ key: WritableKeyPath<EnvironmentValues, Value>) -> Entry {
        Entry(name: name) { source, values in values[keyPath: key] = source[keyPath: key] }
    }

    /// Set above the host by the panel or the page, and read inside it.
    @MainActor static let entries: [Entry] = [
        // SwiftUI's, set by the panel (AtticPanelView: colour scheme, key
        // state) or by an ancestor (enabled, locale, direction, font, focus
        // effect).
        entry("colorScheme", \.colorScheme),
        entry("controlActiveState", \.controlActiveState),
        entry("isEnabled", \.isEnabled),
        entry("locale", \.locale),
        entry("layoutDirection", \.layoutDirection),
        entry("font", \.font),
        entry("isFocusEffectEnabled", \.isFocusEffectEnabled),
        // Attic's design and theme.
        entry("atticDesign", \.atticDesign),
        entry("atticTagColouring", \.atticTagColouring),
        entry("atticPanelThemePalette", \.atticPanelThemePalette),
        entry("atticPanelUsesSystemAccent", \.atticPanelUsesSystemAccent),
        entry("atticPanelUsesSystemOpaqueSurface", \.atticPanelUsesSystemOpaqueSurface),
        entry("atticClearGlassForegroundReadabilityEnabled", \.atticClearGlassForegroundReadabilityEnabled),
        entry("atticPanelSurfaceSize", \.atticPanelSurfaceSize),
        entry("atticControlCornerExponent", \.atticControlCornerExponent),
        entry("atticControlState", \.atticControlState),
        entry("atticForcedState", \.atticForcedState),
        entry("atticControlAway", \.atticControlAway),
        entry("atticControlGone", \.atticControlGone),
        entry("atticControlReveal", \.atticControlReveal),
        entry("atticIsPressed", \.atticIsPressed),
        entry("atticSmallControlBarSize", \.atticSmallControlBarSize),
        entry("atticPageSwitcherPresence", \.atticPageSwitcherPresence),
        entry("atticPageTabsOnGlass", \.atticPageTabsOnGlass),
        entry("atticRowHoverGate", \.atticRowHoverGate),
        // Keyboard and focus requests.
        entry("atticKeyboardFocusVisible", \.atticKeyboardFocusVisible),
        entry("atticFocusRequests", \.atticFocusRequests),
        // Menus and dropdowns opened from the content.
        entry("atticDropdownRegisterKeys", \.atticDropdownRegisterKeys),
        entry("atticDropdownFocusRequest", \.atticDropdownFocusRequest),
        entry("atticDropdownWidth", \.atticDropdownWidth),
        entry("atticDropdownHeight", \.atticDropdownHeight),
        entry("atticDropdownContentWidthChanged", \.atticDropdownContentWidthChanged),
        entry("atticDropdownContentHeightChanged", \.atticDropdownContentHeightChanged),
        entry("atticMenuHighlight", \.atticMenuHighlight),
        entry("atticUnfold", \.atticUnfold),
        entry("atticUnfoldCornerRadius", \.atticUnfoldCornerRadius),
        entry("atticUnfoldTreated", \.atticUnfoldTreated),
        entry("atticUnfoldDiagnosticsOwner", \.atticUnfoldDiagnosticsOwner),
        // Capture and probes.
        entry("atticCapture", \.atticCapture),
        entry("atticSpecimen", \.atticSpecimen),
        entry("atticProbesDisabled", \.atticProbesDisabled),
        // The panel's shell.
        entry("atticPanelPageIsCurrent", \.atticPanelPageIsCurrent),
        entry("atticPanelToasts", \.atticPanelToasts),
        entry("panelComposer", \.panelComposer),
        entry("panelComposerRoom", \.panelComposerRoom),
        entry("panelResumeDefaults", \.panelResumeDefaults),
        entry("panelSharedChrome", \.panelSharedChrome),
        entry("panelPageTransit", \.panelPageTransit),
        entry("panelPageTravel", \.panelPageTravel),
        entry("panelPageMotion", \.panelPageMotion),
        entry("panelTopRowPage", \.panelTopRowPage),
        entry("panelTopRowState", \.panelTopRowState),
    ]

    func body(content: Content) -> some View {
        let source = source
        let palette = source.atticPanelThemePalette
        return content
            .transformEnvironment(\.self) { values in
                for entry in Self.entries { entry.copy(source, &values) }
            }
            // The panel's default text styles (AtticPanelView's
            // `foregroundStyle`) travel as a style, not a named value.
            .foregroundStyle(palette.primaryForegroundColor, palette.secondaryForegroundColor)
    }
}

#if DEBUG
/// What reaches kept-content hosts (the host-boundary guard counts; the
/// measure's probes print them): layouts and accessibility calls split by
/// interactive or not, root assignments by drawn or not.
@MainActor
enum KeptContentHostCounts {
    /// `on`: interactive (layouts, accessibility) or drawn (roots).
    struct Split: Equatable {
        var on = 0
        var off = 0
    }

    static var layouts = Split()
    static var roots = Split()
    static var accessibilityChildrenCalls = Split()
    static var accessibilityHits = Split()

    static func reset() {
        layouts = Split()
        roots = Split()
        accessibilityChildrenCalls = Split()
        accessibilityHits = Split()
    }

    fileprivate static func layout(interactive: Bool) { count(&layouts, interactive) }
    fileprivate static func root(drawn: Bool) { count(&roots, drawn) }
    fileprivate static func accessibilityChildren(interactive: Bool) { count(&accessibilityChildrenCalls, interactive) }
    fileprivate static func accessibilityHit(interactive: Bool) { count(&accessibilityHits, interactive) }

    private static func count(_ split: inout Split, _ on: Bool) {
        if on { split.on += 1 } else { split.off += 1 }
    }
}
#endif
