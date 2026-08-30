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
}

struct AtticPanelSurface: ViewModifier {
    let translucent: Bool
    let glassStyle: PanelGlassStyle
    let opaqueColor: Color
    let cornerRadius: CGFloat
    let prefersDarkSurface: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .animation(reduceMotion ? nil : AtticMotion.background, value: translucent)
                .animation(reduceMotion ? nil : AtticMotion.background, value: glassStyle)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.stroke(
                    Color.primary.opacity(glassStyle == .glassmorphism ? 0.055 : 0.11),
                    lineWidth: 0.75
                )
            }
            .clipShape(shape)
            .contentShape(shape)
    }

    @ViewBuilder
    private func surfaceBackground(shape: Squircle) -> some View {
        if !translucent {
            shape.fill(opaqueColor)
        } else if glassStyle == .glassmorphism {
            // This is Attic's original glassmorphism contract: one native
            // material layer, without an acrylic color wash or capture loop.
            shape.fill(.ultraThinMaterial)
        } else if #available(macOS 26.0, *) {
            nativeGlassBackground(shape: shape)
        } else if glassStyle == .clear {
            shape.fill(.ultraThinMaterial)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    @available(macOS 26.0, *)
    private func nativeGlassBackground(shape: Squircle) -> some View {
        let isDark = prefersDarkSurface
        let glass: Glass = glassStyle == .clear
            ? .clear.tint(isDark ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
            : .regular.tint(isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.24))
        let lightingStops: [Gradient.Stop]

        if isDark {
            lightingStops = glassStyle == .clear
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
            lightingStops = glassStyle == .clear
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

private struct AtticGlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.atticPanelGlassStyle) private var glassStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if glassStyle == .glassmorphism {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.13), lineWidth: 0.75)
                }
        } else if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.13), lineWidth: 0.75) }
        }
    }
}

private struct AtticGlassEffectContainerModifier: ViewModifier {
    let spacing: CGFloat

    @Environment(\.atticPanelGlassStyle) private var glassStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), glassStyle != .glassmorphism {
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
        translucent: Bool,
        glassStyle: PanelGlassStyle = .clear,
        opaqueColor: Color = Color(nsColor: .windowBackgroundColor),
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius,
        prefersDarkSurface: Bool = false
    ) -> some View {
        modifier(
            AtticPanelSurface(
                translucent: translucent,
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
