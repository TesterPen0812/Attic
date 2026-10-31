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

    func model(tasks: TasksPageModel, services: @autoclosure () -> ComposerServices) -> ComposerModel {
        if let model, model.tasks === tasks { return model }
        let made = ComposerModel(tasks: tasks, services: services())
        model = made
        return made
    }
}

/// The "+" growing into the card and back (the HTML's `cp` box: 54 → 578
/// design px wide, radius 32 → 44, i.e. 27 → 289 pt and 16 → 22 pt), all on
/// curve 1.4. One progress drives size and radius, so they move together.
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

/// Size, radius and material from one animatable progress.
private struct ComposerGrowFrame: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let geometry = ComposerGrow.geometry(progress: progress, card: card)
        #if DEBUG
        let _ = ComposerOverlay.surfaces.append(geometry)
        #endif
        let shape = AtticControlShape.shape(cornerRadius: geometry.cornerRadius, exponent: AtticShape.controlExponent)
        content
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
            .clipShape(shape)
            .atticRaisedMaterial(cornerRadius: geometry.cornerRadius, interactive: false)
            .atticDesignCorners()
    }
}

/// The scrim and the card over the panel, anchored on the shared "+".
/// The bottom bar is not part of it, so it never moves while the card opens.
struct ComposerOverlay: View {
    @ObservedObject var model: ComposerModel
    let layout: PanelPageLayout
    /// Told when the grow takes the "+" over and hands it back.
    var chrome: PanelSharedChrome? = nil

    @State private var presented = false
    @State private var expanded = false

    #if DEBUG
    /// Test seams: whether the grow is drawn, and each frame it drew.
    static var isPresented = false
    static var surfaces: [ComposerGrow.Geometry] = []
    static var corners: [CGPoint] = []
    #endif
    /// The card's own size, measured at full width (it grows with its
    /// writing); a first guess before the first measure.
    @State private var card = CGSize(width: ComposerMetrics.width, height: 130)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if presented {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(expanded ? 0.6 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .accessibilityHidden(true)
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: ComposerGrow.closedSide, height: ComposerGrow.closedSide)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .scaleEffect(expanded ? 0.5 : 1)
                        .opacity(expanded ? 0 : 1)
                        .accessibilityHidden(true)
                    ComposerCard(model: model, drawsChrome: false)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self, of: \.size) { size in
                            if size != card { card = size }
                        }
                        .opacity(expanded ? 1 : 0)
                        .allowsHitTesting(expanded)
                }
                .modifier(ComposerGrowFrame(progress: expanded ? 1 : 0, card: card))
                #if DEBUG
                .onGeometryChange(for: CGPoint.self, of: { CGPoint(x: $0.frame(in: .global).maxX, y: $0.frame(in: .global).maxY) }) {
                    Self.corners.append($0)
                }
                #endif
                .padding(ComposerGrow.anchor(layout: layout))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onChange(of: model.isOpen, initial: true) { _, open in transition(open) }
        #if DEBUG
        .onChange(of: presented, initial: true) { _, now in Self.isPresented = now }
        #endif
    }

    private func transition(_ open: Bool) {
        guard let animation = ComposerMotion.animation(showing: open) else {
            present(open)
            expanded = open
            return
        }
        if open {
            present(true)
            // One frame at the "+" first, then the grow.
            DispatchQueue.main.async {
                guard model.isOpen else { return }
                withAnimation(animation) { expanded = true }
            }
        } else {
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                expanded = false
            } completion: {
                if !model.isOpen { present(false) }
            }
        }
    }

    /// The grow and the bar's "+" swap in one update: one "+" at a time.
    private func present(_ shown: Bool) {
        presented = shown
        if chrome?.plusHandedOver != shown { chrome?.plusHandedOver = shown }
    }
}
