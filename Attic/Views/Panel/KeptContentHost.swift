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
    /// Whether the content is drawn. Not shown: no clicks, no accessibility
    /// children, no accessibility hit (a client reads only the page shown,
    /// and the panel's own hit-test walk never enters a hidden host).
    var isShown = true {
        didSet {
            guard isShown != oldValue else { return }
            if !isShown { releaseKeyboard() }
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

    override func layout() {
        #if DEBUG
        KeptContentHostCounts.layout(shown: isShown)
        #endif
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    /// The panel takes its first press wherever it lands (O14-01), in a
    /// nested host as in the panel's root.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityChildren() -> [Any]? {
        #if DEBUG
        KeptContentHostCounts.accessibilityChildren(shown: isShown)
        #endif
        return isShown ? super.accessibilityChildren() : []
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        #if DEBUG
        KeptContentHostCounts.accessibilityHit(shown: isShown)
        #endif
        return isShown ? super.accessibilityHitTest(point) : nil
    }

    /// A host that stops being shown while the keyboard is inside it gives
    /// the keyboard to the nearest host around it, so no key reaches a
    /// hidden graph (host-boundary.md §5, keyboard ownership).
    private func releaseKeyboard() {
        guard let window, let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return }
        var ancestor = superview
        while let view = ancestor, !view.acceptsFirstResponder { ancestor = view.superview }
        window.makeFirstResponder(ancestor)
    }
}

/// The container the slot sizes; the host fills it.
final class KeptContentContainer: NSView {
    fileprivate(set) var host: KeptContentHostingView?
    override var isFlipped: Bool { true }

    /// Hidden or shown, the container itself is never a click target: the
    /// host decides.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let host, host.isShown else { return nil }
        return super.hitTest(point)
    }
}

/// Places content in its own `KeptContentHostingView`. `shown` false: the
/// content's root is set once (on the update that hides it) and then not
/// again until it is shown, so the hidden graph is not invalidated by the
/// parent's updates; the root is set again, with the current environment,
/// in the update that shows it, before its first drawn frame.
struct KeptContentHost<Content: View>: NSViewRepresentable {
    let shown: Bool
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
        host.isShown = shown
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.host = host
        container.addSubview(host)
        context.coordinator.hiddenRootSet = !shown
        #if DEBUG
        KeptContentHostCounts.root(shown: shown)
        #endif
        return container
    }

    func updateNSView(_ container: KeptContentContainer, context: Context) {
        guard let host = container.host else { return }
        let coordinator = context.coordinator
        // Two hidden updates in a row set nothing (as `TasksKeptPage`'s
        // equality, which this boundary carries across the host).
        if shown || !coordinator.hiddenRootSet {
            host.rootView = root(context)
            #if DEBUG
            KeptContentHostCounts.root(shown: shown)
            #endif
        }
        coordinator.hiddenRootSet = !shown
        host.isShown = shown
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeptContentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func root(_ context: Context) -> AnyView {
        let environment = context.environment
        if let space {
            return AnyView(content().coordinateSpace(space).environment(\.self, environment))
        }
        return AnyView(content().environment(\.self, environment))
    }
}

#if DEBUG
/// What reaches kept-content hosts, split by shown and hidden (the
/// host-boundary guard counts; the measure's probes print them).
@MainActor
enum KeptContentHostCounts {
    struct Split: Equatable {
        var shown = 0
        var hidden = 0
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

    fileprivate static func layout(shown: Bool) { count(&layouts, shown) }
    fileprivate static func root(shown: Bool) { count(&roots, shown) }
    fileprivate static func accessibilityChildren(shown: Bool) { count(&accessibilityChildrenCalls, shown) }
    fileprivate static func accessibilityHit(shown: Bool) { count(&accessibilityHits, shown) }

    private static func count(_ split: inout Split, _ shown: Bool) {
        if shown { split.shown += 1 } else { split.hidden += 1 }
    }
}
#endif
