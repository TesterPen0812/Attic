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
                cameIntoUse = true
                claimKeyboard()
                joinAccessibilityAfterTheFirstFrame()
            } else {
                stopJoining()
                isAccessible = false
                releaseKeyboard()
            }
        }
    }

    /// Whether the content is drawn: the tab shown, or one a move passes
    /// (`KeptContentHost.drawn`). A host not drawn takes its hidden root in
    /// one layout pass and then holds every layout until it is drawn again
    /// (host-boundary.md §4.2): a click changed its own environment (the
    /// window's focus, key and accessibility values) and a resize changed
    /// its size, and each laid it out, with nothing on screen to show for
    /// it (Air, PR 41 844907fb: once a click, as often as the shown host on
    /// a resize). A request made while it holds is owed; drawn again, the
    /// host is marked for layout in the update that draws it, so the pass
    /// before its first frame takes the current size, environment and root
    /// together.
    ///
    /// The hold starts when the hide has settled: in the turn the host stops
    /// being drawn, it takes up to `hideTurnPasses` layouts its content asks
    /// for after the hidden root's pass (a task note's editor leaving Notes
    /// takes two: run 45984030524), then holds as above. A request past
    /// them in that turn is held and counted (`KeptContentHostCounts.heldPastTheHide`).
    var isDrawn = true {
        didSet {
            guard isDrawn != oldValue else { return }
            guard isDrawn else {
                // A host made hidden has not laid out yet: its first pass runs anyway.
                if window != nil { openTheHideTurn() }
                return
            }
            hideTurnPassesLeft = 0
            holdsLayout = false
            if owesLayout {
                owesLayout = false
                super.needsLayout = true
            }
        }
    }
    /// Hidden, and its hidden root laid out: a layout is owed, not run.
    private var holdsLayout = false
    private var owesLayout = false
    static let hideTurnPasses = 3
    /// Layouts the hide's turn may still take (0 once the turn has ended).
    private var hideTurnPassesLeft = 0
    private var hideTurnIsOpen = false

    /// The turn ends where AppKit's own display pass of it has run: the
    /// first time the main run loop is about to wait, after every other
    /// observer of that moment (the display cycle among them).
    private func openTheHideTurn() {
        hideTurnPassesLeft = Self.hideTurnPasses
        guard !hideTurnIsOpen else { return }
        hideTurnIsOpen = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false,
                                                          CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.hideTurnPassesLeft = 0
                self?.hideTurnIsOpen = false
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Whether a layout asked for while the host holds is one of the hide's
    /// own (it then runs); otherwise it is owed.
    private func takesAPassOfTheHide() -> Bool {
        guard hideTurnPassesLeft > 0 else {
            #if DEBUG
            if hideTurnIsOpen { KeptContentHostCounts.heldPastTheHide += 1 }
            #endif
            return false
        }
        hideTurnPassesLeft -= 1
        holdsLayout = false
        #if DEBUG
        KeptContentHostCounts.passesOfTheHide += 1
        #endif
        return true
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if newValue, holdsLayout, !takesAPassOfTheHide() {
                owesLayout = true
                return
            }
            super.needsLayout = newValue
        }
    }

    /// Whether accessibility reads the content. A host that comes into use
    /// takes clicks and the keyboard at once, but joins accessibility only
    /// after its first drawn frame: a client's read mounts the rows it asks
    /// for (Later 9 to 17 on its first reveal), and in that frame it made
    /// the reveal's longest frame 40 ms longer (HB-05, the lead's ruling).
    private(set) var isAccessible = true
    private var joinLink: CADisplayLink?
    /// Whether the host has come into use: turned into use, or made in use
    /// and reached its window.
    private var cameIntoUse = false
    /// A host made already in use claims the keyboard at its first frame,
    /// with its accessibility join (host-boundary.md §5.1, the first switch
    /// to a tab not yet built; the lead, 19 Nov).
    private var claimsAtFirstFrame = false

    /// Joins on the next display frame, after the reveal's frame has been
    /// committed; a window on no screen (draws no frames) joins on the next
    /// turn of the run loop. With `claiming`, it claims the keyboard there
    /// first. The link holds only a weak stand-in, never the host (HB-10).
    private func joinAccessibilityAfterTheFirstFrame(claiming: Bool = false) {
        stopJoining()
        isAccessible = false
        claimsAtFirstFrame = claiming
        guard let window, window.screen != nil else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInteractive, self.joinLink == nil else { return }
                self.cameIntoUseAtTheFirstFrame()
            }
            return
        }
        let link = displayLink(target: KeptHostJoinTarget(self), selector: #selector(KeptHostJoinTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        joinLink = link
        // HB-10: a window not shown draws no frame, so the host is read on
        // the next turn; a pending claim still waits for the first drawn
        // frame (when the keyboard moves is not HB-10's to change).
        guard !window.isVisible || !window.occlusionState.contains(.visible) else { return }
        let waiting = ObjectIdentifier(link)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInteractive, self.joinLink.map(ObjectIdentifier.init) == waiting else { return }
            self.isAccessible = true
            if !self.claimsAtFirstFrame { self.stopJoining() }
        }
    }

    fileprivate func joinAccessibility(_ link: CADisplayLink) {
        let claiming = claimsAtFirstFrame
        stopJoining()
        claimsAtFirstFrame = claiming
        if isInteractive { cameIntoUseAtTheFirstFrame() }
    }

    /// The deferred part of coming into use: the keyboard first (for a host
    /// made in use), then accessibility.
    private func cameIntoUseAtTheFirstFrame() {
        if claimsAtFirstFrame {
            claimsAtFirstFrame = false
            claimKeyboard()
        }
        isAccessible = true
    }

    private func stopJoining() {
        joinLink?.invalidate()
        joinLink = nil
        claimsAtFirstFrame = false
    }

    /// A host taken out of its window stops waiting.
    /// A host made already in use never turns into use: once it has a
    /// window it comes into use the same way, with its claim deferred to
    /// its first frame, when its content takes keys (a claim at the attach
    /// gave first responder that no key reached; hb-step1/pr41-c).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, joinLink != nil {
            stopJoining()
            isAccessible = isInteractive
        }
        if window != nil, isInteractive, !cameIntoUse {
            cameIntoUse = true
            joinAccessibilityAfterTheFirstFrame(claiming: true)
        }
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        // The slot decides the size, never the content (as the panel's root,
        // `AtticPanelHostingView`): nothing flows from SwiftUI to AppKit.
        sizingOptions = []
        AtticHostDragHooks.install(on: KeptContentHostingView.self)
        Self.installKeyboardGiveBackRule()
        Self.all.add(self)
    }

    /// Every host alive, so a card's declined give-back finds the one in use.
    private static let all = NSHashTable<KeptContentHostingView>.weakObjects()
    private static var givesBackRuleInstalled = false

    /// claimKeyboard alone gives a tab host the keyboard (host-boundary.md
    /// §5.1, HB-DROPDOWN-RESTORE-HIDDEN): a card closing never gives it
    /// back to a tab host that left use, or a view inside one. It goes to
    /// no one, and the host in use claims it under the same rules.
    private static func installKeyboardGiveBackRule() {
        guard !givesBackRuleInstalled else { return }
        givesBackRuleInstalled = true
        AtticDropdownPresenter.mayGiveKeyboardBack = { view in
            guard let host = (view as? KeptContentHostingView) ?? KeptContentHostingView.enclosing(view) else { return true }
            return host.isInteractive
        }
        AtticDropdownPresenter.declinedKeyboard = { window in
            for host in KeptContentHostingView.all.allObjects where host.window === window && host.isInteractive {
                host.claimKeyboard()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A new root, laid out in the pass that sets it (PR 41, Find close).
    /// The root alone only marks the host for layout, and AppKit laid it out
    /// about 0.1 s later, in a pass of its own with no animation: the rows
    /// had by then taken the update under the list's animation, the late
    /// pass gave every row a second, un-animated update, and the lazy list
    /// drew its returning rows thin for about 1.3 s. Laid out here, under
    /// the update's transaction, the content takes one pass, as it does
    /// without a host. A hidden root is not laid out: its graph does not
    /// run until it is drawn (host-boundary.md §4.2).
    ///
    /// Only a root that moves the content's rows is laid out here
    /// (`KeptContentHost.rows`). A layout inside the panel's update runs
    /// before the content's own actions, which wait for that update to
    /// end (a row's focus change redraws its cells that way), so the host
    /// was then laid out a second time for them: twice a row click, where
    /// AppKit's one pass takes the root and the actions together.
    func setRoot(_ root: AnyView, laidOut: Bool, under transaction: Transaction) {
        // A hidden root is taken in one pass (`isDrawn`).
        if !isDrawn { holdsLayout = false }
        withTransaction(transaction) {
            rootView = root
            if laidOut, window != nil {
                #if DEBUG
                KeptContentHostCounts.laidOutInSet += 1
                #endif
                layoutSubtreeIfNeeded()
            }
        }
    }

    /// As the panel's root host (`AtticPanelHostingView.layout`): this host's
    /// SwiftUI update runs here, and overlay hierarchy changes from it wait
    /// for the next turn (HB-03). The root's pass is not on the stack when
    /// this host lays out alone.
    override func layout() {
        #if DEBUG
        KeptContentHostCounts.layout(interactive: isInteractive, host: self)
        #endif
        // AppKit reached a host that holds (a request it marked itself).
        if holdsLayout, !takesAPassOfTheHide() {
            owesLayout = true
            return
        }
        AtticOverlayHierarchy.layoutPass { super.layout() }
        if !isDrawn, !bounds.isEmpty { holdsLayout = true }
    }

    /// HB-09 (host-boundary.md §5.1, hb09-key-note §1): whether a focus
    /// state drawn in `host` may be written nil (or false) now. SwiftUI
    /// applies such a write later, at whichever update ends first, by
    /// asking for no first responder, whoever holds the keyboard then. So
    /// the write is skipped only while a view outside `host` holds the
    /// keyboard (a field editor judged by its field); the focus state then
    /// goes nil by itself as the holder took it. Written when `host` holds
    /// the keyboard, when no one does (the window, or nil), and when the
    /// host is unknown or has no window.
    static func mayLetGo(in host: KeptContentHostingView?) -> Bool {
        guard let host, let window = host.window,
              let holder = (window.firstResponder as? NSTextView)?.delegate as? NSView ?? window.firstResponder as? NSView,
              holder.window === window else { return true }
        return holder === host || holder.isDescendant(of: host)
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

    /// A host that does not claim the keyboard is a key view only under full
    /// keyboard access, as AppKit's own buttons are: with it off, Tab passes
    /// the host by and stays where the window had it; with it on, the panel's
    /// loop enters the host and Tab walks the content's controls, leaving by
    /// the loop when they end. A click still hands it the keyboard.
    ///
    /// Such a host answers for itself, not through `super`: NSHostingView
    /// accepts no first responder, so `super.canBecomeKeyView` is false, and
    /// a host that never claims the keyboard was no stop at all; the loop
    /// wrapped to the panel's tab bar (fka lane run 45808976473: the shown
    /// Calendar host `canKey=false`, no `KeyViewProxy` child;
    /// page-host-tech-note.md, "FKA entry into the Calendar host").
    ///
    /// It is the stop for entering, not one inside: while the keyboard is in
    /// its content it is no key view, so Shift-Tab from the content's first
    /// control leaves for the stop before the host rather than re-entering
    /// the host at its last control (fka run 45820495764: Shift-Tab from
    /// Calendar's header went on to Calendar's own `57,30` stop).
    override var canBecomeKeyView: Bool {
        guard isInteractive else { return false }
        if claimsKeyboard { return super.canBecomeKeyView }
        guard NSApp.isFullKeyboardAccessEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return false }
        return true
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

    /// Whether this host claims the keyboard when it comes into use. A host
    /// whose content owns no keys of its own (the Calendar page) leaves it
    /// with the window, where it was before the content had a host, and is
    /// in the key-view loop only under full keyboard access (`canBecomeKeyView`).
    var claimsKeyboard = true

    /// The keyboard belongs to the tab host in use (host-boundary.md §5.1,
    /// the lead's decision of 19 Nov 08:22): a host claims it when it comes
    /// into use, but only from no one (the window itself) or from a tab
    /// host, never from a text editor (add bar, search, a rename), a
    /// dropdown or menu, the panel's own host (its tab bar's ←/→), or while
    /// the panel is not key. A refusal is left alone.
    private func claimKeyboard() {
        guard claimsKeyboard else { return joinKeyViewLoop() }
        guard let window, window.isKeyWindow else { return }
        let responder = window.firstResponder
        let fromNoOne = responder == nil || responder === window
        let fromATabHost = (responder as? NSView).map { view in
            !(view is NSText) && (view is KeptContentHostingView || Self.enclosing(view) != nil)
        } ?? false
        guard fromNoOne || fromATabHost else { return }
        if window.makeFirstResponder(self), window.firstResponder === self { return }
        #if DEBUG
        print("KeptContentHost: claim refused; first responder \(String(describing: window.firstResponder))")
        #endif
    }

    /// The kept host `view` lies in, if any.
    static func enclosing(_ view: NSView) -> KeptContentHostingView? {
        var current = view.superview
        while let candidate = current {
            if let host = candidate as? KeptContentHostingView { return host }
            current = candidate.superview
        }
        return nil
    }

    /// A host that claims no keyboard takes its place in the panel's
    /// key-view loop instead, under full keyboard access, where it would
    /// have claimed: as it comes into use (at its first frame when made in
    /// use) and when a dropdown gives the keyboard back.
    /// The window's loop is recalculated there and then; a fresh panel's
    /// loop otherwise stays as it was before the host was attached (fka run
    /// 45820495764, first panel: `hostInChainFromBar=false fromContent=48
    /// hostIndex=-1` before the first Tab and after each of 8). A host put
    /// away needs no unlinking: it is no key view (`canBecomeKeyView`).
    private func joinKeyViewLoop() {
        guard NSApp.isFullKeyboardAccessEnabled, let window, window.autorecalculatesKeyViewLoop else { return }
        window.recalculateKeyViewLoop()
    }

    /// A host that stops taking part while the keyboard is inside it gives
    /// it to no one (the window), so no key reaches a graph that is not in
    /// use (HB-02); the host that comes into use claims it. Handing it up
    /// had no taker: the panel's host refused first responder (trace run
    /// on `2904c288`).
    private func releaseKeyboard() {
        guard let window, let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return }
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
/// keyboard and accessibility. The root is set, and a drawn one laid out,
/// under the update's transaction, so an animation or its suppression
/// crosses the boundary (HB-08) and the content takes a change of its rows
/// in one pass (`KeptContentHostingView.setRoot`).
struct KeptContentHost<Content: View>: NSViewRepresentable {
    let drawn: Bool
    let interactive: Bool
    /// A named space the content reads, declared again at the host's root
    /// (the host fills the slot that declares it outside, so the origins
    /// are the same).
    var space: NamedCoordinateSpace?
    /// Whether the host claims the keyboard when it comes into use
    /// (`KeptContentHostingView.claimsKeyboard`).
    var claimsKeyboard = true
    /// The shell page this host holds whole, if it holds one: the host is
    /// tagged with it (`PanelPageKeyboard`), so the panel's keyboard rule
    /// knows the page from the host itself.
    var page: PanelPage?
    /// Whether the root that takes the host out of use is laid out in the
    /// update that sets it, so the content's own leave work (a page's
    /// actions on `atticPanelPageIsCurrent`: commands released, an editor
    /// resigned) runs in the panel's update that makes
    /// the switch, where it ran when the page sat in the panel's own host,
    /// not in a later pass of this host (pr80-hidden-inputs.md, "Notes and
    /// Draw", the lead's ordering condition).
    var laysOutOnLeave = false
    /// The rows the content animates between by itself (a list's ids), if
    /// it has any. A drawn root that changes them is laid out in the pass
    /// that sets it; any other root is left to AppKit's pass (`setRoot`).
    var rows: AnyHashable?
    @ViewBuilder let content: () -> Content

    @MainActor
    final class Coordinator {
        /// The root last set was a hidden one.
        var hiddenRootSet = false
        /// The rows of the drawn root last set; nil after a hidden one.
        var drawnRows: AnyHashable?
        /// The host's own environment, held while it is not drawn.
        let hold = KeptEnvironmentHold()
        /// The host, as its content knows it (one box for the host's life,
        /// so the root it is in stays equal).
        let reference = KeptHostReference()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeptContentContainer {
        let container = KeptContentContainer()
        let host = KeptContentHostingView(rootView: root(context))
        context.coordinator.reference.host = host
        host.isDrawn = drawn
        host.isInteractive = interactive
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        host.claimsKeyboard = claimsKeyboard
        if let page { PanelPageKeyboard.tag(host, .page(page)) }
        container.host = host
        container.addSubview(host)
        context.coordinator.hiddenRootSet = !drawn
        context.coordinator.drawnRows = drawn ? rows : nil
        #if DEBUG
        KeptContentHostCounts.root(drawn: drawn)
        #endif
        return container
    }

    func updateNSView(_ container: KeptContentContainer, context: Context) {
        guard let host = container.host else { return }
        let coordinator = context.coordinator
        #if DEBUG
        KeptContentHostCounts.update(drawn: drawn)
        #endif
        // Drawn first, so a host that held its layouts while hidden is
        // marked for the pass that takes this root.
        host.isDrawn = drawn
        // Two hidden updates in a row set nothing (as `TasksKeptPage`'s
        // equality, which this boundary carries across the host).
        // A leaving page's root, and its first hidden one (the slide over),
        // are laid out here, so its leave actions and removals apply where
        // they did in the panel's own host (`laysOutOnLeave`).
        let leaving = laysOutOnLeave && ((host.isInteractive && !interactive) || (!drawn && !coordinator.hiddenRootSet))
        if drawn || !coordinator.hiddenRootSet {
            let root = root(context)
            host.setRoot(root, laidOut: leaving || Self.movesRows(from: coordinator.drawnRows, to: drawn ? rows : nil),
                         under: context.transaction)
            #if DEBUG
            KeptContentHostCounts.root(drawn: drawn)
            #endif
        }
        coordinator.hiddenRootSet = !drawn
        coordinator.drawnRows = drawn ? rows : nil
        host.isInteractive = interactive
    }

    /// Whether a root moves the rows of the drawn root before it. A root
    /// revealed (nothing drawn before it) and a hidden one move none.
    static func movesRows(from drawnRows: AnyHashable?, to rows: AnyHashable?) -> Bool {
        guard let drawnRows, let rows else { return false }
        return drawnRows != rows
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeptContentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func root(_ context: Context) -> AnyView {
        // A new root brings its own values: the environment a hidden root
        // handed its content is not handed to the next one.
        context.coordinator.hold.output = nil
        let forwarded = KeptEnvironment(source: context.environment, hold: context.coordinator.hold, holding: !drawn)
        // Inside the forwarded environment, which would replace it.
        let known = content().environment(\.keptHost, context.coordinator.reference)
        if let space {
            return AnyView(known.coordinateSpace(space).modifier(forwarded))
        }
        return AnyView(known.modifier(forwarded))
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
///
/// Not drawn, the host takes no new environment (§4.2, "No new root while
/// hidden"): the forwarded values come from the root, which is not set
/// while hidden, and what the host derives itself is held at its last
/// drawn value. An outside accessibility read changes the host's own
/// values, and a hidden Later tab then mounted 9 to 17 rows (resize's
/// HB5B census on c6042b47). Drawn again, it takes the current values in
/// the update that draws it, before its first frame.
///
/// Not drawn, the content is also handed the very value it was given
/// before, not one built again: the transform still runs on every pass of
/// the panel (a size write, a click's action pass), and a value built again
/// holds the same values but is new to SwiftUI, so every environment reader
/// in the hidden tab re-checked on each of them (rows-rerun-fable.md,
/// probe 3: 244 such replacements in a drive against 2).
struct KeptEnvironment: ViewModifier {
    let source: EnvironmentValues
    var hold: KeptEnvironmentHold?
    var holding = false

    struct Entry {
        let name: String
        let copy: (EnvironmentValues, inout EnvironmentValues) -> Void
        let describe: (EnvironmentValues) -> String
    }

    private static func entry<Value>(_ name: String, _ key: WritableKeyPath<EnvironmentValues, Value>) -> Entry {
        Entry(name: name,
              copy: { source, values in values[keyPath: key] = source[keyPath: key] },
              describe: { String(describing: $0[keyPath: key]) })
    }

    /// Set above the host by the panel or the page, and read inside it.
    @MainActor static let entries: [Entry] = {
        var entries: [Entry] = [
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
        // Capture and probes.
        entry("atticCapture", \.atticCapture),
        entry("atticSpecimen", \.atticSpecimen),
        entry("atticProbesDisabled", \.atticProbesDisabled),
        // The panel's shell.
        entry("atticPanelPageIsCurrent", \.atticPanelPageIsCurrent),
        // The page its content is part of, which our AppKit views take as
        // their keyboard tag (PanelPageKeyboard). It arrives today without
        // this line too (HiddenPageKeyboardTests.testAKeptHostHandsItsContentThePage
        // passes without it); named here, it no longer rests on that.
        entry("atticPanelPage", \.atticPanelPage),
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
        #if DEBUG
        // The key itself is DEBUG-only (AtticDropdown.swift); a container
        // literal cannot hold an #if, so it is added here.
        entries.append(entry("atticUnfoldDiagnosticsOwner", \.atticUnfoldDiagnosticsOwner))
        #endif
        return entries
    }()

    func body(content: Content) -> some View {
        let source = source
        let hold = hold
        let holding = holding
        let palette = source.atticPanelThemePalette
        #if DEBUG
        // Counts each environment the content takes as new
        // (`KeptContentHostCounts.environments`).
        let counted = content.transformEnvironment(\.self) { _ in KeptContentHostCounts.environment(drawn: !holding) }
        #else
        let counted = content
        #endif
        return counted
            .transformEnvironment(\.self) { values in
                if let hold {
                    #if DEBUG
                    if holding, let held = hold.held { hold.logChanges(from: held, to: values) }
                    #endif
                    // Hidden, the value this root handed its content before.
                    if holding, let output = hold.output {
                        values = output
                        return
                    }
                    if holding, let held = hold.held {
                        values = held
                    } else {
                        hold.held = values
                    }
                }
                for entry in Self.entries { entry.copy(source, &values) }
                // Kept while hidden; a drawn run builds its value each time.
                hold?.output = holding ? values : nil
            }
            // The panel's default text styles (AtticPanelView's
            // `foregroundStyle`) travel as a style, not a named value.
            .foregroundStyle(palette.primaryForegroundColor, palette.secondaryForegroundColor)
    }
}

/// The environment a kept host derives itself, as last drawn (or as first
/// seen, for a host that has never been drawn).
@MainActor
final class KeptEnvironmentHold {
    var held: EnvironmentValues?
    /// What the transform handed a hidden root's content, handed back on
    /// that root's later runs. Cleared by a drawn run and by a new root.
    var output: EnvironmentValues?

    #if DEBUG
    /// Names what changes in a hidden host's own environment (the lead's
    /// ruling: which value an outside read flips).
    func logChanges(from held: EnvironmentValues, to values: EnvironmentValues) {
        let before = String(describing: held), after = String(describing: values)
        guard before != after else { return }
        let named = KeptEnvironment.entries
            .filter { $0.describe(held) != $0.describe(values) }
            .map(\.name)
        let old = Set(before.components(separatedBy: ", ")), new = after.components(separatedBy: ", ")
        let others = new.filter { !old.contains($0) }.prefix(8).map { String($0.prefix(160)) }
        print("KeptEnvironment: hidden host's own values changed; forwarded \(named); others \(others)")
    }
    #endif
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
    /// Layouts a hiding host took in its hide's turn, and requests it held
    /// past `KeptContentHostingView.hideTurnPasses` in that turn.
    static var passesOfTheHide = 0
    static var heldPastTheHide = 0
    /// Root sets that laid the host out in their own pass.
    static var laidOutInSet = 0
    static var roots = Split()
    /// `updateNSView` calls, by drawn or not.
    static var updates = Split()
    /// Environments handed to the content that SwiftUI took as new, by the
    /// root's drawn or not (`KeptEnvironment.body`).
    static var environments = Split()
    static var accessibilityChildrenCalls = Split()
    static var accessibilityHits = Split()
    /// Layouts by host (a host's own count, whatever its state).
    static var layoutsByHost: [ObjectIdentifier: Int] = [:]

    static func reset() {
        layoutsByHost = [:]
        layouts = Split()
        passesOfTheHide = 0
        heldPastTheHide = 0
        laidOutInSet = 0
        roots = Split()
        updates = Split()
        environments = Split()
        accessibilityChildrenCalls = Split()
        accessibilityHits = Split()
    }

    fileprivate static func layout(interactive: Bool, host: KeptContentHostingView) {
        count(&layouts, interactive)
        layoutsByHost[ObjectIdentifier(host), default: 0] += 1
    }
    fileprivate static func root(drawn: Bool) { count(&roots, drawn) }
    fileprivate static func update(drawn: Bool) { count(&updates, drawn) }
    fileprivate static func environment(drawn: Bool) { count(&environments, drawn) }
    fileprivate static func accessibilityChildren(interactive: Bool) { count(&accessibilityChildrenCalls, interactive) }
    fileprivate static func accessibilityHit(interactive: Bool) { count(&accessibilityHits, interactive) }

    private static func count(_ split: inout Split, _ on: Bool) {
        if on { split.on += 1 } else { split.off += 1 }
    }
}
#endif

/// The join link's target: it holds the host weakly, so a wait for a frame
/// never keeps a host its slot let go (HB-10); with the host gone, the link
/// ends at its next frame.
@MainActor
private final class KeptHostJoinTarget: NSObject {
    weak var host: KeptContentHostingView?
    init(_ host: KeptContentHostingView) { self.host = host }
    @objc func frame(_ link: CADisplayLink) {
        guard let host else { link.invalidate(); return }
        host.joinAccessibility(link)
    }
}

/// The kept host a view is drawn in, for its focus states (HB-09): weak,
/// and nil outside a kept host.
@MainActor
final class KeptHostReference {
    weak var host: KeptContentHostingView?
}

extension EnvironmentValues {
    /// The kept host this content is drawn in, if any (HB-09).
    @Entry var keptHost: KeptHostReference?
}
