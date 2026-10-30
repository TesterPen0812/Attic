import SwiftUI

enum AtticStyle {
    /// Superellipse exponent for the panel corners. `5` produces a
    /// recognisably squircular silhouette without aggressive inward
    /// curvature.
    static let panelSquircleExponent: CGFloat = AtticShape.surfaceExponent

    /// The AppKit window remains rectangular while the visible panel is a squircle.
    /// Disabling its system shadow prevents square bounds from showing beyond large corners.
    static let panelUsesSystemShadow = false
    /// Transparent, click-through room the native window keeps around the
    /// visible surface so the SwiftUI shape elevation can fade out instead of
    /// being cut at the window edge. It never becomes a resize grip.
    /// 28 pt (visual A): room for the panel's 12 pt, y 4 shadow to fade out.
    static let panelElevationMargin: CGFloat = 28
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4

    // Keep the compact workboard visually light while preserving forgiving
    // pointer targets around the smaller rendered controls.
    static let actionControlSize: CGFloat = 36
    static let modeControlSize: CGFloat = 34
    static let controlHitSize: CGFloat = 42
    static let entryControlHeight: CGFloat = 38
    static let composerControlHeight: CGFloat = 42
    static let taskComposerControlSize: CGFloat = 36
    static let composerActionSize: CGFloat = 34
    /// Width of the composer paperclip between the title field and submit.
    static let composerAttachWidth: CGFloat = 28

    /// Permanent chrome keeps a calm, even optical margin from every panel
    /// edge. Larger squircles can require more room where the corner curve
    /// moves inward, so PanelGeometry adds curve-aware clearance to this
    /// minimum rather than treating it as a fixed position.
    /// 16 pt from every edge at the default corner size (chrome B, Notes v2,
    /// owner 2026-10-08; it was 24); larger corners still push the
    /// controls inward.
    static let chromeMinimumInset: CGFloat = 16
    static let chromeCornerClearance: CGFloat = 7
    static let chromeWorkspaceSpacing: CGFloat = 24
    static let taskScrollTopPadding: CGFloat = 22
}



/// The panel's exterior elevation: a soft shadow of the squircle with the
/// squircle itself cut back out, so nothing is ever drawn under the surface.
/// A translucent Glass or Frosted interior therefore stays exactly as
/// see-through as its own composite; only the room outside the shape (the
/// window's transparent margin) carries the shadow.
///
/// The shadow-casting fill is inset by `casterInset` while the cut-out is
/// the exact shape: the caster's anti-aliased rim then lies wholly inside
/// the cut-out and can never survive as a dark ring under the edge stroke,
/// and the cut-out removes nothing beyond the true edge, so there is no
/// bright seam between the hairline and the shadow either. Half a point of
/// inset moves a 10pt-radius shadow by an invisible amount.
struct AtticPanelOutsideShadow: View {
    let shape: Squircle
    let elevation: AtticPanelSurfaceElevation

    /// How far inside the shape the shadow-casting fill stops, in points.
    static let casterInset: CGFloat = 0.5

    var body: some View {
        ZStack {
            shape
                .fill(Color.black)
                .padding(Self.casterInset)
                .shadow(
                    color: Color.black.opacity(elevation.opacity),
                    radius: elevation.radius,
                    x: 0,
                    y: elevation.offsetY
                )
            if elevation.contactOpacity > 0 {
                shape
                    .fill(Color.black)
                    .padding(Self.casterInset)
                    .shadow(
                        color: Color.black.opacity(elevation.contactOpacity),
                        radius: elevation.contactRadius,
                        x: 0,
                        y: elevation.contactOffsetY
                    )
            }
            shape
                .fill(Color.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

private struct AtticPanelUsesSystemOpaqueSurfaceKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var atticPanelUsesSystemOpaqueSurface: Bool {
        get { self[AtticPanelUsesSystemOpaqueSurfaceKey.self] }
        set { self[AtticPanelUsesSystemOpaqueSurfaceKey.self] = newValue }
    }
}

/// How floating interactive controls (pin, mode dock, composers, view
/// switches) are backed. Translucency and the glass style change the panel
/// SURFACE only: every surface keeps its controls on Liquid Glass. Reduce
/// Transparency is the accessibility override that makes controls opaque.
enum AtticGlassControlTreatment: Equatable {
    case opaque
    case nativeGlass
    /// The design system's drawn raised material: the panel is not key
    /// (a corner reveal), where native glass renders flat.
    case drawn

    static let systemSupportsNativeGlass = true

    /// Reduce Transparency wins; otherwise the controls follow the panel's
    /// design context: real glass while the panel is key, the drawn look
    /// while it is not (`PanelKeyTreatment`).
    static func resolve(
        reduceTransparency: Bool,
        controls: AtticControlMaterial = .liquidGlass
    ) -> Self {
        if reduceTransparency { return .opaque }
        return controls == .craft ? .drawn : .nativeGlass
    }

    /// Native Liquid Glass takes its tone from whatever is behind it, so on a
    /// pure-white Solid surface a control's fill lands within a couple of
    /// levels of the panel and the pill all but disappears. This faint
    /// `Color.primary` outline keeps every native-glass control legible on
    /// white and on busy glass alike; Increased Contrast is one step stronger.
    /// Measured on the Light Solid `#FFFFFF` composer field (see
    /// `Docs/Appearance-Model-2026-09.md`).
    static func nativeGlassOutlineOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.20 : 0.10
    }

    static func nativeGlassOutlineLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1 : 0.75
    }
}

private struct AtticGlassControlModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.colorSchemeContrast) private var systemContrast
    /// The Mac's contrast (or a UI-test launch's, `AtticContrastSeam`).
    private var colorSchemeContrast: ColorSchemeContrast { AtticContrastSeam.resolve(systemContrast) }
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    /// The Mac's setting (or a UI-test launch's, `AtticTransparencySeam`).
    private var reduceTransparency: Bool { AtticTransparencySeam.resolve(systemReduceTransparency) }
    @Environment(\.atticPanelThemePalette) private var palette
    @Environment(\.atticPanelUsesSystemOpaqueSurface) private var usesSystemOpaqueSurface
    @Environment(\.atticDesign) private var design

    @ViewBuilder
    func body(content: Content) -> some View {
        switch AtticGlassControlTreatment.resolve(
            reduceTransparency: reduceTransparency,
            controls: design.controls
        ) {
        case .drawn:
            // The panel is not key (a corner reveal): the design system's
            // drawn material, as every design-system control draws then.
            content.background(AtticRaisedShapeBackground(shape: shape))
        case .opaque:
            content
                .background(opaqueControlColor, in: shape)
                .overlay {
                    shape.stroke(
                        opaqueControlEdgeColor,
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                }
        case .nativeGlass:
            if interactive {
                nativeGlassControl(content: content, glass: .regular.interactive())
            } else {
                nativeGlassControl(content: content, glass: .regular)
            }
        }
    }

    private func nativeGlassControl(content: Content, glass: Glass) -> some View {
        content
            .glassEffect(glass, in: shape)
            .overlay {
                shape.stroke(
                    Color.primary.opacity(
                        AtticGlassControlTreatment.nativeGlassOutlineOpacity(for: colorSchemeContrast)
                    ),
                    lineWidth: AtticGlassControlTreatment.nativeGlassOutlineLineWidth(for: colorSchemeContrast)
                )
            }
    }

    private var opaqueControlColor: Color {
        usesSystemOpaqueSurface
            ? Color(nsColor: .windowBackgroundColor)
            : palette.opaqueSurfaceColor
    }

    private var opaqueControlEdgeColor: Color {
        if usesSystemOpaqueSurface {
            return Color.primary.opacity(colorSchemeContrast == .increased ? 0.28 : 0.17)
        }
        return palette.edgeTint.swiftUIColor(
            opacity: colorSchemeContrast == .increased ? 0.38 : 0.24
        )
    }
}

private struct AtticGlassEffectContainerModifier: ViewModifier {
    let spacing: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    /// The Mac's setting (or a UI-test launch's, `AtticTransparencySeam`).

    private var reduceTransparency: Bool { AtticTransparencySeam.resolve(systemReduceTransparency) }
    @Environment(\.atticDesign) private var design

    @ViewBuilder
    func body(content: Content) -> some View {
        if AtticGlassControlTreatment.resolve(reduceTransparency: reduceTransparency, controls: design.controls) == .nativeGlass {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {

    func atticGlassControl<S: InsettableShape>(
        in shape: S,
        interactive: Bool = true
    ) -> some View {
        // These controls have their own native/opaque backing. Applying the
        // clear-panel glyph shadow here creates a halo on an already readable
        // surface; only unbacked panel content should inherit that treatment.
        environment(\.atticClearGlassForegroundReadabilityEnabled, false)
            .modifier(AtticGlassControlModifier(shape: shape, interactive: interactive))
    }

    func atticGlassEffectContainer(spacing: CGFloat) -> some View {
        modifier(AtticGlassEffectContainerModifier(spacing: spacing))
    }

    /// Quiets the glyph of a `.borderlessButton` `Menu` whose label is an
    /// `Image`. AppKit renders that label through a pop-up button which paints
    /// the symbol as an accent-tinted template and ignores the label's own
    /// `foregroundStyle`, so every such menu showed system blue at rest. All
    /// three overrides are needed: `tint` and `accentColor` reach the AppKit
    /// cell, `foregroundStyle` the SwiftUI label. Proven by the task composer's
    /// `+` menu, which was the one site that already did this.
    func atticQuietMenuGlyph(_ color: Color) -> some View {
        tint(color)
            .accentColor(color)
            .foregroundStyle(color)
    }
}


extension AtticPanelSurfaceTreatment {
    /// `tintStops` as SwiftUI gradient stops in the wash colour. The panel
    /// and the Settings samples both draw these.
    var tintGradientStops: [Gradient.Stop] {
        let wash = washColor
        return tintStops.map {
            Gradient.Stop(color: wash.swiftUIColor(opacity: $0.opacity), location: $0.location)
        }
    }
}
