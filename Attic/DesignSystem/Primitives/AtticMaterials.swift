import AppKit
import SwiftUI

/// Interaction state of a control or row. Selection is separate: a row can
/// be selected and hovered at once.
enum AtticControlState: String, CaseIterable, Sendable {
    case rest, hover, pressed, focused, disabled

    var title: String {
        switch self {
        case .rest: "Rest"
        case .hover: "Hover"
        case .pressed: "Pressed"
        case .focused: "Keyboard focus"
        case .disabled: "Disabled"
        }
    }
}

private struct AtticForcedStateKey: EnvironmentKey {
    static let defaultValue: AtticControlState? = nil
}

extension EnvironmentValues {
    /// The gallery pins components in a state with this; live UI leaves it nil.
    var atticForcedState: AtticControlState? {
        get { self[AtticForcedStateKey.self] }
        set { self[AtticForcedStateKey.self] = newValue }
    }
}

extension View {
    func atticForcedState(_ state: AtticControlState?) -> some View {
        environment(\.atticForcedState, state)
    }
}

/// The live state from hover, press, focus and enabled, unless the gallery
/// pins one.
struct AtticStateResolver {
    var forced: AtticControlState?
    var isEnabled: Bool
    var isHovered: Bool
    var isPressed: Bool
    var isFocused: Bool

    var state: AtticControlState {
        if let forced { return forced }
        if !isEnabled { return .disabled }
        if isPressed { return .pressed }
        if isFocused { return .focused }
        if isHovered { return .hover }
        return .rest
    }
}

// MARK: - Raised material

/// The drawn raised material: the Craft style (Reduce Transparency, or the
/// gallery's Craft switch), or in captures, which cannot render Liquid
/// Glass, its stand-in (`AtticGlassModel`). Live glass is not drawn here:
/// see `atticRaisedMaterial`.
struct AtticRaisedBackground: View {
    var cornerRadius: CGFloat
    var state: AtticControlState = .rest

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let recipe: AtticRaisedRecipe = if design.effectiveControls == .liquidGlass {
            tokens.glassStandIn
        } else {
            switch state {
            case .hover: tokens.raisedHover
            case .pressed: tokens.raisedPressed
            case .disabled: tokens.raisedDisabled
            case .rest, .focused: tokens.raised
            }
        }
        AtticRecipeBackground(recipe: recipe, cornerRadius: cornerRadius)
            .overlay {
                // The glass stand-in shows hover and press as the live glass
                // control does: a fill inside it.
                if design.effectiveControls == .liquidGlass, let fill = AtticGlassStateFill.fill(for: state, tokens: tokens) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill.color)
                }
            }
    }
}

/// Hover, press and the disabled ghost inside a Liquid Glass control (and
/// its stand-in).
enum AtticGlassStateFill {
    static func fill(for state: AtticControlState, tokens: AtticColorTokens) -> AtticRGBA? {
        switch state {
        case .hover: tokens.chipHover
        case .pressed: tokens.glassPressed
        case .disabled: tokens.glassDisabled
        case .rest, .focused: nil
        }
    }
}

/// Draws one `AtticRaisedRecipe`.
struct AtticRecipeBackground: View {
    let recipe: AtticRaisedRecipe
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let reach = min(max(recipe.sheenReach, 0.01), 0.45)
        ZStack {
            if recipe.shadow.alpha > 0 {
                AtticOutsideShadow(shape: shape, color: recipe.shadow, radius: recipe.shadowRadius, y: recipe.shadowY)
            }
            if let base = recipe.base {
                shape.fill(base.color)
            }
            shape.fill(recipe.fill.color)
            shape.fill(LinearGradient(stops: [
                .init(color: recipe.sheenTop.color, location: 0),
                .init(color: recipe.sheenTop.withAlpha(0).color, location: reach),
                .init(color: recipe.sheenBottom.withAlpha(0).color, location: 1 - reach),
                .init(color: recipe.sheenBottom.color, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            if recipe.innerRimTop.alpha > 0 || recipe.innerRimMiddle.alpha > 0 || recipe.innerRimBottom.alpha > 0 {
                shape.inset(by: recipe.edgeWidth + AtticHairline.innerRim / 2).stroke(
                    LinearGradient(stops: [
                        .init(color: recipe.innerRimTop.color, location: 0),
                        .init(color: recipe.innerRimMiddle.color, location: 0.5),
                        .init(color: recipe.innerRimBottom.color, location: 1)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: AtticHairline.innerRim
                )
            }
            shape.inset(by: recipe.edgeWidth / 2).stroke(
                LinearGradient(stops: [
                    .init(color: recipe.edgeTop.color, location: 0),
                    .init(color: recipe.edgeMiddle.color, location: 0.5),
                    .init(color: recipe.edgeBottom.color, location: 1)
                ], startPoint: .top, endPoint: .bottom),
                lineWidth: recipe.edgeWidth
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Gives a raised control its material. Live, with Liquid Glass: the
/// system's glass in the control's shape (interactive for buttons), with
/// hover and press as fills inside it and, under Increase Contrast, a
/// stronger edge. Otherwise (the Craft style, Reduce Transparency, or a
/// capture) the drawn `AtticRaisedBackground`.
struct AtticRaisedMaterialModifier: ViewModifier {
    let cornerRadius: CGFloat
    let state: AtticControlState
    let interactive: Bool

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if capture == nil, design.effectiveControls == .liquidGlass {
            let tokens = design.tokens
            content
                .background {
                    if let fill = AtticGlassStateFill.fill(for: state, tokens: tokens) {
                        shape.fill(fill.color)
                    }
                }
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay {
                    if design.increaseContrast {
                        shape.inset(by: AtticHairline.widthIncreased / 2)
                            .stroke(AtticGlassModel.contrastEdge(dark: design.mode == .dark).color, lineWidth: AtticHairline.widthIncreased)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content.background(AtticRaisedBackground(cornerRadius: cornerRadius, state: state))
        }
    }
}

extension View {
    /// The raised material in a control's shape (see `AtticRaisedMaterialModifier`).
    func atticRaisedMaterial(cornerRadius: CGFloat, state: AtticControlState = .rest, interactive: Bool = true) -> some View {
        modifier(AtticRaisedMaterialModifier(cornerRadius: cornerRadius, state: state, interactive: interactive))
    }
}

/// Controls that float together (the header's pin and page switch): live
/// Liquid Glass shares one `GlassEffectContainer`, so neighbouring glass
/// renders and blends as one material. A plain group otherwise.
struct AtticControlGroup<Content: View>: View {
    var spacing: CGFloat = AtticSpacing.betweenControls
    @ViewBuilder let content: Content

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture

    var body: some View {
        if capture == nil, design.effectiveControls == .liquidGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A shadow cast only outside `shape`.
struct AtticOutsideShadow<S: Shape>: View {
    let shape: S
    let color: AtticRGBA
    let radius: CGFloat
    let y: CGFloat

    init(shape: S, color: AtticRGBA, radius: CGFloat, y: CGFloat) {
        self.shape = shape
        self.color = color
        self.radius = radius
        self.y = y
    }

    /// A shadow from the shadow tokens, in the look's colour.
    init(shape: S, color: AtticRGBA, spec: AtticShadowSpec) {
        self.init(shape: shape, color: color.withAlpha(color.alpha * spec.alphaScale), radius: spec.radius, y: spec.y)
    }

    var body: some View {
        ZStack {
            shape
                .fill(Color.black)
                .padding(0.5)
                .shadow(color: color.color, radius: radius, x: 0, y: y)
            shape
                .fill(Color.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Menus, pop-overs, the selection bar and toasts: raised over content,
/// with a hairline, an inner light band and a soft shadow.
struct AtticPopoverBackground: View {
    var cornerRadius: CGFloat = AtticRadius.popover

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            AtticOutsideShadow(shape: shape, color: tokens.popoverShadow, spec: AtticShadows.popover)
            AtticOutsideShadow(shape: shape, color: tokens.popoverShadow, spec: AtticShadows.popoverContact)
            shape.fill(tokens.popoverFill.color)
            shape.inset(by: AtticHairline.innerRim / 2).stroke(tokens.popoverInnerRim.color, lineWidth: AtticHairline.innerRim)
            shape.stroke(tokens.popoverOuterRim.color, lineWidth: design.increaseContrast ? AtticHairline.widthIncreased : AtticHairline.width)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Highlights and rings

/// Where a selected row sits in a run of touching selected rows. Touching
/// selected rows merge into one shape rounded only at its outer corners.
enum AtticSelectionRun: String, CaseIterable, Sendable {
    case single, first, middle, last

    var roundsTop: Bool { self == .single || self == .first }
    var roundsBottom: Bool { self == .single || self == .last }
}

/// The soft grey rounded rectangle for hover, selection and press. Rows use
/// radius 10; in a run it reaches into the 2 pt gap so the run is one shape.
struct AtticHighlight: View {
    let fill: AtticRGBA
    var cornerRadius: CGFloat = AtticRadius.highlight
    var run: AtticSelectionRun = .single
    /// Half the gap between rows, covered where the run continues.
    var joinOverlap: CGFloat = (AtticLayout.rowPitch - AtticLayout.rowHighlightHeight) / 2

    var body: some View {
        let top = run.roundsTop ? cornerRadius : 0
        let bottom = run.roundsBottom ? cornerRadius : 0
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top),
            style: .continuous
        )
        .fill(fill.color)
        .padding(.top, run.roundsTop ? 0 : -joinOverlap)
        .padding(.bottom, run.roundsBottom ? 0 : -joinOverlap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keyboard focus: a 2 pt accent ring with a 2 pt gap, following the
/// shape (its radius is the shape's plus the ring's offset).
struct AtticFocusRing: View {
    let cornerRadius: CGFloat
    var gap: CGFloat = AtticRingMetrics.gap
    var width: CGFloat = AtticRingMetrics.width

    @Environment(\.atticDesign) private var design

    var body: some View {
        let outset = gap + width
        RoundedRectangle(cornerRadius: AtticRadius.ring(around: cornerRadius, offset: outset), style: .continuous)
            .strokeBorder(design.tokens.focusRing.color, lineWidth: width)
            .padding(-outset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Draws the focus ring around this view when `visible`.
    func atticFocusRing(_ visible: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if visible { AtticFocusRing(cornerRadius: cornerRadius) }
        }
    }
}

// MARK: - Surfaces

/// A background surface drawn from its model: the native material (Glass or
/// Frosted, live only), the palette-hued base at its foundation opacity, then
/// the Tint. In capture mode the native material is replaced by the capture
/// backdrop: a flat measured underlay, or a blurred stand-in wallpaper.
struct AtticSurfaceBackground<S: Shape>: View {
    let model: AtticSurfaceModel
    let shape: S
    /// Settings chrome uses the sidebar material instead of glass.
    var isChrome = false
    /// The height the Tint spans (the panel's height). Nil spans the whole
    /// surface; gallery boards taller than a panel pass the panel's height,
    /// so text sits in the Tint exactly as it would in the panel.
    var tintHeight: CGFloat?

    @Environment(\.atticCapture) private var capture

    var body: some View {
        ZStack {
            if model.kind != .solid {
                underlay
                shape.fill(model.base.withAlpha(model.foundationOpacity).color)
            } else {
                shape.fill(model.base.color)
            }
            if !model.tintStops.isEmpty {
                if let tintHeight {
                    ZStack(alignment: .top) {
                        model.washColor.withAlpha(model.tintOpacity(at: 1)).color
                        LinearGradient(stops: model.tintGradientStops, startPoint: .top, endPoint: .bottom)
                            .frame(height: tintHeight)
                    }
                    .clipShape(shape)
                } else {
                    shape.fill(LinearGradient(stops: model.tintGradientStops, startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var underlay: some View {
        if let capture {
            switch capture.backdrop {
            case .desktop(let desktop):
                shape.fill(model.underlay(desktop).color)
            case .wallpaper(let tone):
                // The wallpaper as the native surface renders it: blurred,
                // then each channel mapped through the measured black and
                // white renders of this surface kind (a linear model).
                let endpoints = AtticSurfaceModel.renderEndpoints(kind: model.kind, appearance: model.appearance) ?? (0, 255)
                AtticStandInWallpaper(tone: tone, dark: model.appearance == .dark)
                    .blur(radius: model.kind == .frosted ? 28 : 16, opaque: true)
                    .colorMultiply(Color(.sRGB, white: (endpoints.white - endpoints.black) / 255))
                    .overlay(Color(.sRGB, white: endpoints.black / 255, opacity: 1).blendMode(BlendMode.plusLighter))
                    .compositingGroup()
                    .clipShape(shape)
            }
        } else if isChrome {
            AtticVisualEffect(material: .sidebar)
                .clipShape(shape)
        } else if model.kind == .glass {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

/// A stand-in desktop for gallery stages and contact sheets: the soft
/// gradient the redesign mockups use, so glass has something to show.
struct AtticStandInWallpaper: View {
    var tone: AtticWallpaperTone = .matchingMode
    var dark = false

    init(dark: Bool = false) {
        self.tone = .matchingMode
        self.dark = dark
    }

    init(tone: AtticWallpaperTone, dark: Bool) {
        self.tone = tone
        self.dark = dark
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(.sRGB, red: 0.42, green: 0.53, blue: 0.70), location: 0),
                .init(color: Color(.sRGB, red: 0.61, green: 0.55, blue: 0.75), location: 0.35),
                .init(color: Color(.sRGB, red: 0.81, green: 0.62, blue: 0.58), location: 0.70),
                .init(color: Color(.sRGB, red: 0.86, green: 0.75, blue: 0.57), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(veil)
        .accessibilityHidden(true)
    }

    private var veil: Color {
        switch tone {
        case .matchingMode: dark ? Color.black.opacity(0.35) : Color.clear
        case .light: Color.white.opacity(0.35)
        case .dark: Color.black.opacity(0.68)
        }
    }
}

/// `NSVisualEffectView` for the translucent Settings sidebar.
struct AtticVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Scroll edge fade

/// Content that scrolls under a floating bar (the header, the add bar)
/// blurs and fades as it passes under it: over the edge zone (top 56 pt,
/// bottom 60 pt) it blurs up to 6 pt and fades along the veil's eased ramp
/// (to 65 % at the edge), into whatever surface is behind. Applied per
/// item in a scroll view; the zones are measured in `space`, a coordinate
/// space whose bounds are the whole visible area with the bars (the
/// panel's own space).
///
/// The system's soft scroll edge does this under ordinary bars, but not
/// under Liquid Glass ones: macOS 26 draws no edge effect at all under a
/// `safeAreaBar` of glass controls (whatever the edge style, container or
/// interactivity), and a hard band with a line under drawn controls. So
/// the controls float over a scroll view with no bars and no system edge
/// effect, and Attic fades the content itself, the same with either
/// control material.
struct AtticScrollEdgeFade: ViewModifier {
    var space: NamedCoordinateSpace
    var top: CGFloat = AtticEdgeBlur.panelTop
    var bottom: CGFloat = AtticEdgeBlur.panelBottom

    func body(content: Content) -> some View {
        content.visualEffect { [space, top, bottom] effect, proxy in
            let frame = proxy.frame(in: space)
            let height = proxy.bounds(of: space)?.height ?? .infinity
            let intoTop = (top - frame.midY) / top
            let intoBottom = (frame.midY - (height - bottom)) / bottom
            let depth = min(max(max(intoTop, intoBottom), 0), 1)
            let veil = AtticEdgeBlur.veil(at: depth)
            return effect
                .blur(radius: AtticEdgeBlur.maximumBlur * depth)
                .opacity(1 - veil)
        }
    }
}

extension View {
    /// Blurs and fades this item as it scrolls under a bar (see `AtticScrollEdgeFade`).
    @ViewBuilder
    func atticScrollEdgeFade(_ enabled: Bool = true, in space: NamedCoordinateSpace) -> some View {
        if enabled {
            modifier(AtticScrollEdgeFade(space: space))
        } else {
            self
        }
    }
}

// MARK: - Edge veil

/// Content under a floating bar fades under a veil of the surface (up to
/// 65 %, the same ramp `AtticScrollEdgeFade` uses). For content that does
/// not scroll, and for captures, which draw the list still. Static: it
/// never animates.
struct AtticEdgeVeil: View {
    enum Edge { case top, bottom }

    let edge: Edge
    var height: CGFloat

    @Environment(\.atticDesign) private var design

    var body: some View {
        let model = design.tokens.panel
        let location: Double = edge == .top ? 0 : 1
        let colour = model.washColor.withAlpha(model.tintOpacity(at: location)).over(model.base)
        let strength = model.kind == .solid ? 1 : model.foundationOpacity
        let ramp = AtticEdgeBlur.veilStops.map {
            Gradient.Stop(color: colour.withAlpha($0.opacity * strength).color, location: $0.location)
        }
        LinearGradient(
            stops: edge == .top ? ramp.reversed().map { Gradient.Stop(color: $0.color, location: 1 - $0.location) } : ramp,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
