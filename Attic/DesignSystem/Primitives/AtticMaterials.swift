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

// MARK: - Raised (rim-lit) material

/// The rim-lit raised material every control uses (spec § Raised controls):
/// an opaque neutral base (content scrolling underneath never shows through),
/// a faint vertical sheen, a 1 pt inner rim lit from above, a hairline that
/// is slightly darker at the bottom, and a tiny shadow drawn outside the
/// shape only (so a translucent face never darkens itself). Softly raised,
/// never puffy.
struct AtticRaisedBackground: View {
    var cornerRadius: CGFloat
    var state: AtticControlState = .rest

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let recipe: AtticRaisedRecipe = switch state {
        case .hover: tokens.raisedHover
        case .pressed: tokens.raisedPressed
        case .disabled: tokens.raisedDisabled
        case .rest, .focused: tokens.raised
        }
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if recipe.shadow.alpha > 0 {
                AtticOutsideShadow(shape: shape, color: recipe.shadow, radius: recipe.shadowRadius, y: recipe.shadowY)
            }
            shape.fill(tokens.controlBase.color)
            shape.fill(LinearGradient(stops: [
                .init(color: recipe.sheenTop.color, location: 0),
                .init(color: recipe.face.color, location: 0.45),
                .init(color: recipe.face.color, location: 0.70),
                .init(color: recipe.sheenBottom.color, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            if recipe.innerRimTop.alpha > 0 {
                shape.inset(by: 0.5).stroke(
                    LinearGradient(colors: [recipe.innerRimTop.color, recipe.innerRimBottom.color], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            shape.inset(by: recipe.outerRimWidth / 2).stroke(
                LinearGradient(colors: [recipe.outerRimTop.color, recipe.outerRimBottom.color], startPoint: .top, endPoint: .bottom),
                lineWidth: recipe.outerRimWidth
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A shadow cast only outside `shape`.
struct AtticOutsideShadow<S: Shape>: View {
    let shape: S
    let color: AtticRGBA
    let radius: CGFloat
    let y: CGFloat

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
            AtticOutsideShadow(shape: shape, color: tokens.popoverShadow, radius: 12, y: 6)
            AtticOutsideShadow(shape: shape, color: tokens.popoverShadow.withAlpha(tokens.popoverShadow.alpha * 0.5), radius: 1, y: 0.5)
            shape.fill(tokens.popoverFill.color)
            shape.inset(by: 0.5).stroke(tokens.popoverInnerRim.color, lineWidth: 1)
            shape.stroke(tokens.popoverOuterRim.color, lineWidth: design.increaseContrast ? 1 : 0.5)
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
    var joinOverlap: CGFloat = 1

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
    var gap: CGFloat = 2
    var width: CGFloat = 2

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
                shape.fill(LinearGradient(stops: model.tintGradientStops, startPoint: .top, endPoint: .bottom))
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
            case .wallpaper:
                AtticStandInWallpaper(dark: model.appearance == .dark)
                    .blur(radius: model.kind == .frosted ? 28 : 16)
                    .overlay(model.kind == .glass ? Color.white.opacity(model.appearance == .dark ? 0.02 : 0.12) : Color.clear)
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
    var dark = false

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
        .overlay(dark ? Color.black.opacity(0.35) : Color.clear)
        .accessibilityHidden(true)
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

// MARK: - Edge veil

/// Content scrolling under a floating bar fades under a veil of the surface
/// (up to 65 %), on top of the system's soft scroll-edge blur. It replaces
/// the hard divider line the system edge draws on the plain Light surface.
/// Static: it never animates.
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
