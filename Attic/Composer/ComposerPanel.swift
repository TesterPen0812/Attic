import AppKit
import Combine
import SwiftUI

/// How a page asks the panel for the "+" card (Phase B): the shell owns one
/// card for every page, attached to the shared bottom bar's "+".
struct PanelComposerRoute {
    let open: (ComposerPage, ComposerKind?) -> Void
    /// Whether the card is open (it then keeps Tab to itself).
    var isOpen: () -> Bool = { false }

    func open(on page: ComposerPage, as kind: ComposerKind? = nil) { open(page, kind) }
}

private struct PanelComposerRouteKey: EnvironmentKey {
    static let defaultValue: PanelComposerRoute? = nil
}

extension EnvironmentValues {
    /// Set by the panel shell. Nil where a page is hosted on its own (tests,
    /// a detached page): there the old add bar still takes "+".
    var panelComposer: PanelComposerRoute? {
        get { self[PanelComposerRouteKey.self] }
        set { self[PanelComposerRouteKey.self] = newValue }
    }
}

/// The panel's one card, made once the Tasks model exists, so a draft kept
/// with Escape survives page switches.
@MainActor
final class PanelComposerState: ObservableObject {
    private(set) var model: ComposerModel?
    /// The room the page's list keeps for the open card (P4).
    let room = PanelComposerRoom()
    nonisolated(unsafe) private var quitting: NSObjectProtocol?

    init() {
        // A draft still in the card when the app quits is kept (A2).
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.saveKeptDraft() }
        }
    }

    deinit {
        if let quitting { NotificationCenter.default.removeObserver(quitting) }
    }

    func model(tasks: TasksPageModel, services: @autoclosure () -> ComposerServices) -> ComposerModel {
        if let model, model.tasks === tasks { return model }
        let made = ComposerModel(tasks: tasks, services: services())
        model = made
        return made
    }
}

/// The "+" corner growing into the card and back (P4's `p1c` box: 54 → 578
/// design px wide, radius 32 → 44, i.e. 27 → 289 pt and 16 → 22 pt), all on
/// curve 1.4. One progress drives size, radius and opacity, so they move
/// together.
enum ComposerGrow {
    static let closedSide = AtticControlSize.headerControl
    static let closedRadius: CGFloat = 16
    static let openRadius: CGFloat = 22

    struct Geometry: Equatable {
        var size: CGSize
        var cornerRadius: CGFloat
    }

    static func geometry(progress: CGFloat, card: CGSize) -> Geometry {
        let p = min(max(progress, 0), 1)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return Geometry(size: CGSize(width: mix(closedSide, card.width), height: mix(closedSide, card.height)),
                        cornerRadius: mix(closedRadius, openRadius))
    }

    /// The card's corner sits on the "+": the bar's own bottom-trailing
    /// insets (`PanelSharedBottomBar.plusInsets`).
    static func anchor(layout: PanelPageLayout) -> EdgeInsets {
        PanelSharedBottomBar.plusInsets(layout: layout)
    }
}

/// The room a page's list keeps for the open card (Accepted 2026-11-03,
/// "The '+' card takes over the bar's row", P4): while it is open the list's
/// bottom clearance is at least the card's height, so the last rows scroll
/// up instead of being covered. Observed only by the pieces that use it
/// (a list's end padding and its scroll keeper), never by a whole page.
@MainActor
final class PanelComposerRoom: ObservableObject {
    /// The card's height while it is open or folding; 0 once it has folded.
    @Published private(set) var height: CGFloat = 0
    /// Whether the card is open: a list resting at its end follows it.
    @Published private(set) var isOpen = false

    #if DEBUG
    /// Test seam: the last room any panel asked for.
    static var lastSet: (height: CGFloat, open: Bool)?
    #endif

    func set(height: CGFloat, open: Bool) {
        #if DEBUG
        Self.lastSet = (height, open)
        #endif
        if self.height != height { self.height = height }
        if isOpen != open { isOpen = open }
    }
}

/// Observe only the content that needs the card's extra scroll clearance.
struct PanelComposerClearance<Content: View>: View {
    @Environment(\.panelComposerRoom) private var room
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        if let room { Observed(room: room, content: content) }
        else { content(0) }
    }

    private struct Observed: View {
        @ObservedObject var room: PanelComposerRoom
        let content: (CGFloat) -> Content
        var body: some View { content(max(0, room.height - AtticControlSize.addBarHeight)) }
    }
}

/// Retain an end anchor only when the person was already at the end.
/// The card publishes before layout; move after the new inset is installed.
@MainActor
final class PanelComposerEndFollower {
    private weak var scroll: NSScrollView?
    private weak var room: PanelComposerRoom?
    private var subscription: AnyCancellable?
    private let glide = TasksScrollGlide()
    private var generation = 0
    var isCurrent = true { didSet { if !isCurrent { glide.stop() } } }

    func stop() {
        generation += 1
        subscription = nil
        glide.stop()
    }

    func bind(scroll: NSScrollView, room: PanelComposerRoom?) {
        self.scroll = scroll
        guard self.room !== room else { return }
        self.room = room
        subscription = room?.$height.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.heightWillChange() }
        }
    }

    private func heightWillChange() {
        generation += 1
        guard isCurrent, let scroll,
              scroll.contentView.bounds.minY >= TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll) - 1 else { return }
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket, self.isCurrent, let scroll = self.scroll else { return }
            scroll.superview?.layoutSubtreeIfNeeded()
            let target = TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll)
            let delta = target - scroll.contentView.bounds.minY
            guard abs(delta) > 0.5 else { return }
            if AtticMotionPreference.reducesMotion {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                let spring = AtticMotionPreset.expand.spring(in: .current)
                self.glide.run(by: delta, in: scroll, spring: Spring(duration: spring.response, bounce: spring.bounce))
            }
        }
    }
}

/// Installed inside a SwiftUI scroll view's content, beside its resume keeper.
struct PanelComposerScrollKeeper: NSViewRepresentable {
    @Environment(\.panelComposerRoom) private var room
    @Environment(\.atticPanelPageIsCurrent) private var isCurrent

    final class Keeper: NSView {
        let follower = PanelComposerEndFollower()
        weak var room: PanelComposerRoom?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bind() }
        override func layout() { super.layout(); bind() }
        func bind() {
            if let scroll = enclosingScrollView { follower.bind(scroll: scroll, room: room) }
        }
    }
    static func dismantleNSView(_ view: Keeper, coordinator: ()) { view.follower.stop() }
    func makeNSView(context: Context) -> Keeper { Keeper() }
    func updateNSView(_ view: Keeper, context: Context) {
        view.room = room
        view.follower.isCurrent = isCurrent
        view.bind()
    }
}

private struct PanelComposerRoomKey: EnvironmentKey {
    static let defaultValue: PanelComposerRoom? = nil
}

extension EnvironmentValues {
    /// Set by the panel shell; nil where a page is hosted alone.
    var panelComposerRoom: PanelComposerRoom? {
        get { self[PanelComposerRoomKey.self] }
        set { self[PanelComposerRoomKey.self] = newValue }
    }
}

/// Size, radius and material from one animatable progress. The card fades
/// in as it grows from the "+" corner and out as it folds back (P4: the
/// bar's own "+" fades out under it, so there is no second "+" to draw).
private struct ComposerGrowFrame: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGSize
    /// Whether the surface is drawn at all: only while open or folding, so a
    /// closed card costs nothing but its (kept) views.
    let drawn: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let geometry = ComposerGrow.geometry(progress: progress, card: card)
        #if DEBUG
        if drawn { let _ = ComposerOverlay.surfaces.append(geometry) }
        #endif
        let shape = AtticControlShape.shape(cornerRadius: geometry.cornerRadius, exponent: AtticShape.controlExponent)
        content
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
            .clipShape(shape)
            .background {
                if drawn {
                    Color.clear.atticRaisedMaterial(cornerRadius: geometry.cornerRadius, interactive: false)
                }
            }
            .atticDesignCorners()
            .opacity(Double(min(max(progress, 0), 1)))
    }
}

/// The card on the bar's own row (P4), anchored on the shared "+": it grows
/// from the "+" corner and its bottom edge lands on the bar's bottom edge,
/// while the bar's tag pills and "+" fade out under it. Nothing dims. The
/// card is built once, with the page content, and kept: opening only grows
/// and fades it (A11, the opening hitch was the card being built).
struct ComposerOverlay: View {
    @ObservedObject var model: ComposerModel
    let layout: PanelPageLayout
    /// Told when the card takes the bar's row and gives it back.
    var chrome: PanelSharedChrome? = nil
    /// Told the room the page's list keeps for the card.
    var room: PanelComposerRoom? = nil

    /// Open or folding: the surface is drawn and the card is on screen.
    @State private var presented = false
    @State private var expanded = false

    #if DEBUG
    /// Test seams: whether the card is on screen, and each frame it drew.
    static var isPresented = false
    static var surfaces: [ComposerGrow.Geometry] = [] {
        didSet { if surfaces.count > AtticDiagnosticHistory.capacity { surfaces.removeFirst(surfaces.count - AtticDiagnosticHistory.retainedAfterOverflow) } }
    }
    static var corners: [CGPoint] = [] {
        didSet { if corners.count > AtticDiagnosticHistory.capacity { corners.removeFirst(corners.count - AtticDiagnosticHistory.retainedAfterOverflow) } }
    }
    #endif
    /// The card's own size, measured at full width; the design's 90 pt
    /// before the first measure.
    @State private var card = CGSize(width: ComposerMetrics.width, height: ComposerMetrics.height)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ComposerCard(model: model, drawsChrome: false)
                .fixedSize(horizontal: false, vertical: true)
                // A click anywhere else in the app folds it, keeping the
                // draft; a right-click on a row also opens the row's menu.
                .background(AtticPressShieldView(isActive: { [model] in model.isOpen },
                                                 onOutsidePress: { [model] in model.close() })
                    .accessibilityHidden(true))
                .onGeometryChange(for: CGSize.self, of: \.size) { size in
                    if size != card { card = size }
                }
                .allowsHitTesting(expanded)
                .accessibilityHidden(!presented)
        }
        .modifier(ComposerGrowFrame(progress: expanded ? 1 : 0, card: card, drawn: presented))
        #if DEBUG
        .onGeometryChange(for: CGPoint.self, of: { CGPoint(x: $0.frame(in: .global).maxX, y: $0.frame(in: .global).maxY) }) {
            Self.corners.append($0)
        }
        #endif
        .allowsHitTesting(presented)
        .padding(ComposerGrow.anchor(layout: layout))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onChange(of: model.isOpen, initial: true) { _, open in transition(open) }
        .onChange(of: card.height) { _, height in
            if presented { room?.set(height: height, open: model.isOpen) }
        }
        #if DEBUG
        .onChange(of: presented, initial: true) { _, now in Self.isPresented = now }
        #endif
    }

    private func transition(_ open: Bool) {
        if chrome?.plusHandedOver != open { chrome?.plusHandedOver = open }
        guard let animation = ComposerMotion.animation(showing: open) else {
            presented = open
            expanded = open
            room?.set(height: open ? card.height : 0, open: open)
            return
        }
        if open {
            presented = true
            room?.set(height: card.height, open: true)
            withAnimation(animation) { expanded = true }
        } else {
            room?.set(height: card.height, open: false)
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                expanded = false
            } completion: {
                guard !model.isOpen else { return }
                presented = false
                room?.set(height: 0, open: false)
            }
        }
    }
}
