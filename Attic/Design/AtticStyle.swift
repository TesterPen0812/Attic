import SwiftUI

enum AtticStyle {
    static let panelCornerRadius: CGFloat = 18
    /// Superellipse exponent for the panel corners. `5` produces a
    /// recognisably squircular silhouette without aggressive inward
    /// curvature.
    static let panelSquircleExponent: CGFloat = 5

    /// The AppKit window remains rectangular while the visible panel is a squircle.
    /// Disabling its system shadow prevents square bounds from showing beyond large corners.
    static let panelUsesSystemShadow = false
    /// Transparent, click-through room the native window keeps around the
    /// visible surface so the SwiftUI shape elevation can fade out instead of
    /// being cut at the window edge. It never becomes a resize grip.
    static let panelElevationMargin: CGFloat = 24
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4
    static let bodyTextSize: CGFloat = 13

    // Keep the compact workboard visually light while preserving forgiving
    // pointer targets around the smaller rendered controls.
    static let actionControlSize: CGFloat = 36
    static let modeControlSize: CGFloat = 34
    static let controlHitSize: CGFloat = 42
    static let entryControlHeight: CGFloat = 38
    static let controlSymbolSize: CGFloat = 14
    static let composerControlHeight: CGFloat = 42
    static let taskComposerControlSize: CGFloat = 36
    static let composerActionSize: CGFloat = 34
    /// Width of the composer paperclip between the title field and submit.
    static let composerAttachWidth: CGFloat = 28
    static let taskComposerRowHeight: CGFloat = taskComposerControlSize
    static let taskComposerOptionsHeight: CGFloat = 34

    /// Permanent chrome keeps a calm, even optical margin from every panel
    /// edge. Larger squircles can require more room where the corner curve
    /// moves inward, so PanelGeometry adds curve-aware clearance to this
    /// minimum rather than treating it as a fixed position.
    static let chromeMinimumInset: CGFloat = 22
    static let chromeCornerClearance: CGFloat = 8
    static let chromeWorkspaceSpacing: CGFloat = 24
    static let taskScrollTopPadding: CGFloat = 22
}

/// The one panel surface: fill, Tint, hairline edge and
/// outside-only elevation, in that order. The main panel and the subtask
/// checklist windows both render through this modifier, so they can only
/// ever look the same.
struct AtticPanelSurface: ViewModifier {
    let treatment: AtticPanelSurfaceTreatment
    let cornerRadius: CGFloat
    /// Only hosts whose native window leaves `AtticStyle.panelElevationMargin`
    /// around the surface should draw the exterior shadow.
    let showsElevation: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Squircle(
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )

        content
            .background {
                ZStack {
                    surfaceBackground(shape: shape)
                        .transition(.opacity)
                }
                .animation(
                    (reduceMotion || reduceTransparency) ? nil : AtticMotion.background,
                    value: surfaceAnimationIdentity
                )
                // Keep the full glass surface in the native event region.
                // Disabling background hit testing makes blank visible areas
                // click through at WindowServer, before host.hitTest runs.
            }
            .overlay {
                shape.stroke(
                    surfaceEdgeColor,
                    lineWidth: treatment.surfaceEdgeLineWidth(
                        for: colorSchemeContrast
                    )
                )
            }
            .clipShape(shape)
            .contentShape(shape)
            .background {
                // Outside the clip on purpose: the shadow belongs to the
                // visible squircle, not to the rectangular AppKit window.
                if showsElevation {
                    AtticPanelOutsideShadow(
                        shape: shape,
                        elevation: treatment.surfaceElevation
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(
                        (reduceMotion || reduceTransparency) ? nil : AtticMotion.background,
                        value: surfaceAnimationIdentity
                    )
                }
            }
    }

    @ViewBuilder
    private func surfaceBackground(shape: Squircle) -> some View {
        ZStack {
            themedSurfaceBackground(shape: shape)
            if treatment.kind != .solid {
                shape.fill(treatment.palette.opaqueSurfaceColor.opacity(treatment.foundationOpacity))
            }
            if treatment.tintTopOpacity > 0 {
                tintWash(shape: shape)
            }
        }
    }

    /// The Tint (neutral shade or accent wash) along `tintStops`, above
    /// the fill.
    private func tintWash(shape: Squircle) -> some View {
        LinearGradient(
            stops: treatment.tintGradientStops,
            startPoint: .top,
            endPoint: .bottom
        )
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func themedSurfaceBackground(shape: Squircle) -> some View {
        switch treatment.kind {
        case .solid:
            // Solid uses the palette seed directly; `surfaceTint` remains a
            // Frosted-only wash regardless of its treatment token.
            shape.fill(treatment.palette.opaqueSurfaceColor)
        case .frosted:
            ZStack {
                if #available(macOS 26.0, *) {
                    shape.fill(.ultraThinMaterial)
                } else {
                    shape.fill(.thinMaterial)
                }
                shape.fill(themedSurfaceTint)
            }
        case .glass:
            if #available(macOS 26.0, *) {
                nativeGlassBackground(shape: shape)
            } else {
                // The foundation carries the colour here too; Glass has no
                // material wash of its own.
                shape.fill(.regularMaterial)
            }
        }
    }

    @available(macOS 26.0, *)
    private func nativeGlassBackground(shape: Squircle) -> some View {
        // The calibrated foundation already carries the palette colour. A
        // second tint inside native glass only adds opacity. Keep regular
        // glass's blur so background lettering does not compete with
        // foreground content.
        shape
            .fill(Color.clear)
            .glassEffect(.regular, in: shape)
    }

    private var themedSurfaceTint: Color {
        treatment.palette.surfaceTint.swiftUIColor(opacity: treatment.materialTintOpacity)
    }

    /// Every surface and Tint change is one crossfade of the whole
    /// background; Reduce Motion (and Reduce Transparency) disable it.
    private var surfaceAnimationIdentity: SurfaceAnimationIdentity {
        .themed(treatment)
    }

    private var surfaceEdgeColor: Color {
        let opacity = treatment.surfaceEdgeOpacity(for: colorSchemeContrast)
        if treatment.usesSystemOpaqueSurface {
            return Color.primary.opacity(opacity)
        }
        return treatment.palette.edgeTint.swiftUIColor(
            opacity: opacity
        )
    }
}

private enum SurfaceAnimationIdentity: Equatable {
    case themed(AtticPanelSurfaceTreatment)
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
/// Transparency is the accessibility override that makes controls opaque, and
/// systems without native glass fall back to material.
enum AtticGlassControlTreatment: Equatable {
    case opaque
    case material
    case nativeGlass

    static var systemSupportsNativeGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func resolve(reduceTransparency: Bool, supportsNativeGlass: Bool) -> Self {
        if reduceTransparency { return .opaque }
        return supportsNativeGlass ? .nativeGlass : .material
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

private struct AtticGlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.atticPanelThemePalette) private var palette
    @Environment(\.atticPanelUsesSystemOpaqueSurface) private var usesSystemOpaqueSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        switch AtticGlassControlTreatment.resolve(
            reduceTransparency: reduceTransparency,
            supportsNativeGlass: AtticGlassControlTreatment.systemSupportsNativeGlass
        ) {
        case .opaque:
            content
                .background(opaqueControlColor, in: shape)
                .overlay {
                    shape.stroke(
                        opaqueControlEdgeColor,
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                }
        case .material:
            materialControl(content: content)
        case .nativeGlass:
            if #available(macOS 26.0, *) {
                if interactive {
                    nativeGlassControl(content: content, glass: .regular.interactive())
                } else {
                    nativeGlassControl(content: content, glass: .regular)
                }
            } else {
                materialControl(content: content)
            }
        }
    }

    private func materialControl(content: Content) -> some View {
        content
            .background(.thinMaterial, in: shape)
            .overlay {
                shape.stroke(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.23 : 0.13),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                )
            }
    }

    @available(macOS 26.0, *)
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *),
           AtticGlassControlTreatment.resolve(
               reduceTransparency: reduceTransparency,
               supportsNativeGlass: true
           ) == .nativeGlass {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func atticPanelSurface(
        treatment: AtticPanelSurfaceTreatment,
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius,
        showsElevation: Bool = false
    ) -> some View {
        modifier(
            AtticPanelSurface(
                treatment: treatment,
                cornerRadius: cornerRadius,
                showsElevation: showsElevation
            )
        )
    }

    func atticGlassControl<S: Shape>(
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

/// An inert band over a scrolling list, sized to the fixed chrome above or
/// below it plus the mask's fade. Rows hidden or fading under chrome are
/// dimmed by the mask; this makes them inert as well, so a press or hover
/// landing beside a chrome control, or in the fade, can never reach a row the
/// user cannot see. Scroll wheel events still reach the list, which AppKit
/// hit-tests independently of this shape.
struct AtticPointerShield: View {
    let height: CGFloat

    /// A degenerate measurement collapses the shield rather than making the
    /// whole list inert: chrome heights are measured from live geometry, and a
    /// band that swallowed every press would be far worse than none.
    static func shieldedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return 0 }
        return max(0, height)
    }

    var body: some View {
        Color.clear
            .frame(height: Self.shieldedHeight(height))
            .contentShape(Rectangle())
            .accessibilityHidden(true)
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
