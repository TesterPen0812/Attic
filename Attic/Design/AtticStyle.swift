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

struct AtticPanelSurface: ViewModifier {
    let treatment: AtticPanelSurfaceTreatment
    let cornerRadius: CGFloat
    let gradientCoverage: Double
    let gradientColorHex: String
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
                if showsElevation, let elevation = treatment.surfaceElevation {
                    shape
                        .fill(treatment.palette.opaqueSurfaceColor)
                        .shadow(
                            color: Color.black.opacity(elevation.opacity),
                            radius: elevation.radius,
                            x: 0,
                            y: elevation.offsetY
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
        if treatment.kind == .clearGlass {
            originalSurfaceBackground(shape: shape)
        } else {
            ZStack {
                themedSurfaceBackground(shape: shape)
                if treatment.kind != .opaque {
                    shape.fill(treatment.palette.opaqueSurfaceColor.opacity(treatment.foundationOpacity))
                }
                let coverage = AtticPanelSurfaceTreatment.normalizedGradientCoverage(gradientCoverage)
                if coverage > 0 {
                    let tint = treatment.gradientColor(customHex: gradientColorHex)
                    LinearGradient(stops: [
                        .init(color: tint.swiftUIColor(
                            opacity: treatment.gradientOpacity(at: 0, coverage: coverage)), location: 0),
                        .init(color: tint.swiftUIColor(opacity: 0), location: coverage),
                        .init(color: tint.swiftUIColor(opacity: 0), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .clipShape(shape)
                }
            }
        }
    }

    @ViewBuilder
    private func originalSurfaceBackground(shape: Squircle) -> some View {
        // Only Original Dark can resolve to Clear. Keep its established
        // glass and lighting intact, outside the readable-material path.
        if #available(macOS 26.0, *) {
            originalNativeGlassBackground(shape: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func themedSurfaceBackground(shape: Squircle) -> some View {
        switch treatment.kind {
        case .opaque:
            // Opaque themes use their solid seed directly; `surfaceTint`
            // remains a glass-only wash regardless of its treatment token.
            shape.fill(treatment.palette.opaqueSurfaceColor)
        case .glassmorphism:
            ZStack {
                if #available(macOS 26.0, *) {
                    shape.fill(.ultraThinMaterial)
                } else {
                    shape.fill(.thinMaterial)
                }
                shape.fill(themedSurfaceTint)
            }
        case .clearGlass, .frostedGlass:
            if #available(macOS 26.0, *) {
                themedNativeGlassBackground(shape: shape)
            } else if treatment.kind == .clearGlass {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(themedSurfaceTint)
                }
            } else {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(themedSurfaceTint)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func originalNativeGlassBackground(shape: Squircle) -> some View {
        let glass: Glass = .clear.tint(Color.black.opacity(0.06))
        let lightingStops: [Gradient.Stop] = [
            .init(color: Color.black.opacity(0.82), location: 0),
            .init(color: Color.black.opacity(0.58), location: 0.42),
            .init(color: Color.black.opacity(0.18), location: 0.74),
            .init(color: Color.black.opacity(0.02), location: 1)
        ]

        return ZStack {
            shape
                .fill(Color.clear)
                .glassEffect(glass, in: shape)
            LinearGradient(
                stops: lightingStops,
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(shape)
        }
    }

    @available(macOS 26.0, *)
    private func themedNativeGlassBackground(shape: Squircle) -> some View {
        // The calibrated foundation and optional gradient already carry the
        // theme color. A second tint inside native glass only adds opacity.
        // Keep regular glass's blur so background lettering does not compete
        // with foreground content. Original Clear has its own untouched path.
        return shape
            .fill(Color.clear)
            .glassEffect(.regular, in: shape)
    }

    private var themedSurfaceTint: Color {
        treatment.palette.surfaceTint.swiftUIColor(opacity: treatment.tintOpacity)
    }

    private var surfaceAnimationIdentity: SurfaceAnimationIdentity {
        // Coverage follows the slider directly; animate appearance/theme changes
        // only, so scrubbing does not continuously restart a transition.
        return .themed(treatment)
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

private struct AtticPanelGlassStyleKey: EnvironmentKey {
    static let defaultValue: PanelGlassStyle = .clear
}

private struct AtticPanelTranslucencyEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var atticPanelTranslucencyEnabled: Bool {
        get { self[AtticPanelTranslucencyEnabledKey.self] }
        set { self[AtticPanelTranslucencyEnabledKey.self] = newValue }
    }

    var atticPanelGlassStyle: PanelGlassStyle {
        get { self[AtticPanelGlassStyleKey.self] }
        set { self[AtticPanelGlassStyleKey.self] = newValue }
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
    @ViewBuilder
    private func nativeGlassControl(content: Content, glass: Glass) -> some View {
        if colorSchemeContrast == .increased {
            content
                .glassEffect(glass, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
        } else {
            content.glassEffect(glass, in: shape)
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
        gradientCoverage: Double = 0.55,
        gradientColorHex: String = "",
        showsElevation: Bool = false
    ) -> some View {
        modifier(
            AtticPanelSurface(
                treatment: treatment,
                cornerRadius: cornerRadius,
                gradientCoverage: gradientCoverage,
                gradientColorHex: gradientColorHex,
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
