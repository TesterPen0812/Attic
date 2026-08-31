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
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 32
    static let taskSpacing: CGFloat = 4

    // Keep the compact workboard visually light while preserving forgiving
    // pointer targets around the smaller rendered controls.
    static let actionControlSize: CGFloat = 36
    static let modeControlSize: CGFloat = 34
    static let controlHitSize: CGFloat = 42
    static let entryControlHeight: CGFloat = 38
    static let controlSymbolSize: CGFloat = 14
    static let composerControlHeight: CGFloat = 42
    static let composerActionSize: CGFloat = 34

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
    let glassStyle: PanelGlassStyle
    let opaqueColor: Color
    let cornerRadius: CGFloat
    let prefersDarkSurface: Bool

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
                .allowsHitTesting(false)
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
    }

    @ViewBuilder
    private func surfaceBackground(shape: Squircle) -> some View {
        if treatment.usesSystemOpaqueSurface {
            originalSurfaceBackground(shape: shape)
        } else {
            themedSurfaceBackground(shape: shape)
        }
    }

    @ViewBuilder
    private func originalSurfaceBackground(shape: Squircle) -> some View {
        switch treatment.kind {
        case .opaque:
            shape.fill(opaqueColor)
        case .glassmorphism:
            // This is Attic's original glassmorphism contract: one native
            // material layer, without an acrylic color wash or capture loop.
            shape.fill(.ultraThinMaterial)
        case .clearGlass, .frostedGlass:
            if #available(macOS 26.0, *) {
                originalNativeGlassBackground(shape: shape)
            } else if treatment.kind == .clearGlass {
                shape.fill(.ultraThinMaterial)
            } else {
                shape.fill(.regularMaterial)
            }
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
        let isDark = prefersDarkSurface
        let glass: Glass = treatment.kind == .clearGlass
            ? .clear.tint(isDark ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
            : .regular.tint(isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.24))
        let lightingStops: [Gradient.Stop]

        if isDark {
            lightingStops = treatment.kind == .clearGlass
                ? [
                    .init(color: Color.black.opacity(0.82), location: 0),
                    .init(color: Color.black.opacity(0.58), location: 0.42),
                    .init(color: Color.black.opacity(0.18), location: 0.74),
                    .init(color: Color.black.opacity(0.02), location: 1)
                ]
                : [
                    .init(color: Color.black.opacity(0.94), location: 0),
                    .init(color: Color.black.opacity(0.82), location: 0.42),
                    .init(color: Color.black.opacity(0.58), location: 0.74),
                    .init(color: Color.black.opacity(0.30), location: 1)
                ]
        } else {
            lightingStops = treatment.kind == .clearGlass
                ? [
                    .init(color: Color.white.opacity(0.42), location: 0),
                    .init(color: Color.white.opacity(0.23), location: 0.45),
                    .init(color: Color.white.opacity(0.10), location: 0.76),
                    .init(color: Color.black.opacity(0.025), location: 1)
                ]
                : [
                    .init(color: Color.white.opacity(0.72), location: 0),
                    .init(color: Color.white.opacity(0.56), location: 0.45),
                    .init(color: Color.white.opacity(0.36), location: 0.76),
                    .init(color: Color.black.opacity(0.045), location: 1)
                ]
        }

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
        let glass: Glass = treatment.kind == .clearGlass
            ? .clear.tint(themedSurfaceTint)
            : .regular.tint(themedSurfaceTint)

        return shape
            .fill(Color.clear)
            .glassEffect(glass, in: shape)
    }

    private var themedSurfaceTint: Color {
        treatment.palette.surfaceTint.swiftUIColor(opacity: treatment.tintOpacity)
    }

    private var surfaceAnimationIdentity: SurfaceAnimationIdentity {
        if treatment.usesSystemOpaqueSurface {
            // Original follows the system appearance directly. Its light/dark
            // palette is implementation data, not a theme transition to
            // crossfade.
            return .original(treatment.kind)
        }
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
    case original(AtticPanelSurfaceTreatment.Kind)
    case themed(AtticPanelSurfaceTreatment)
}

private struct AtticPanelGlassStyleKey: EnvironmentKey {
    static let defaultValue: PanelGlassStyle = .clear
}

extension EnvironmentValues {
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

private struct AtticGlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.atticPanelGlassStyle) private var glassStyle
    @Environment(\.atticPanelThemePalette) private var palette
    @Environment(\.atticPanelUsesSystemOpaqueSurface) private var usesSystemOpaqueSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(opaqueControlColor, in: shape)
                .overlay {
                    shape.stroke(
                        opaqueControlEdgeColor,
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                }
        } else if glassStyle == .glassmorphism {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(colorSchemeContrast == .increased ? 0.23 : 0.13),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                }
        } else if #available(macOS 26.0, *) {
            if interactive {
                nativeGlassControl(content: content, glass: .regular.interactive())
            } else {
                nativeGlassControl(content: content, glass: .regular)
            }
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(
                        Color.primary.opacity(colorSchemeContrast == .increased ? 0.23 : 0.13),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                }
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
    @Environment(\.atticPanelGlassStyle) private var glassStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *),
           glassStyle != .glassmorphism,
           !reduceTransparency {
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
        glassStyle: PanelGlassStyle = .clear,
        opaqueColor: Color = Color(nsColor: .windowBackgroundColor),
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius,
        prefersDarkSurface: Bool = false
    ) -> some View {
        modifier(
            AtticPanelSurface(
                treatment: treatment,
                glassStyle: glassStyle,
                opaqueColor: opaqueColor,
                cornerRadius: cornerRadius,
                prefersDarkSurface: prefersDarkSurface
            )
        )
    }

    func atticGlassControl<S: Shape>(
        in shape: S,
        interactive: Bool = true
    ) -> some View {
        modifier(AtticGlassControlModifier(shape: shape, interactive: interactive))
    }

    func atticGlassEffectContainer(spacing: CGFloat) -> some View {
        modifier(AtticGlassEffectContainerModifier(spacing: spacing))
    }
}
