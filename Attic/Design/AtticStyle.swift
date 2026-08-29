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

        if translucent && glassStyle == .stableAcrylic {
            stableAcrylicSurface(content: content, shape: shape)
        } else if #available(macOS 26.0, *), translucent {
            nativeGlassSurface(content: content, shape: shape)
        } else {
            content
                .background {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(translucent && glassStyle == .clear ? 1 : 0)
                        Rectangle()
                            .fill(.regularMaterial)
                            .opacity(translucent && glassStyle == .frosted ? 1 : 0)
                        Rectangle()
                            .fill(opaqueColor)
                            .opacity(translucent ? 0 : 1)
                    }
                    .animation(reduceMotion ? nil : AtticMotion.background, value: translucent)
                    .animation(reduceMotion ? nil : AtticMotion.background, value: glassStyle)
                }
                .clipShape(shape)
                .contentShape(shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.075), lineWidth: 0.7)
                }
        }
    }

    private func stableAcrylicSurface(content: Content, shape: Squircle) -> some View {
        let isDark = prefersDarkSurface
        let base = isDark
            ? Color(red: 0.055, green: 0.058, blue: 0.068)
            : Color(red: 0.925, green: 0.930, blue: 0.942)
        let edge = isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)

        return content
            .background {
                ZStack {
                    shape.fill(base)
                    LinearGradient(
                        stops: isDark
                            ? [
                                .init(color: Color.black.opacity(0.44), location: 0),
                                .init(color: Color.black.opacity(0.16), location: 0.46),
                                .init(color: Color.white.opacity(0.075), location: 1)
                            ]
                            : [
                                .init(color: Color.white.opacity(0.46), location: 0),
                                .init(color: Color.white.opacity(0.12), location: 0.42),
                                .init(color: Color.black.opacity(0.055), location: 1)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.085 : 0.32),
                            Color.clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 8,
                        endRadius: 310
                    )
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.055 : 0.30),
                            Color.clear,
                            Color.black.opacity(isDark ? 0.18 : 0.06)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.stroke(edge, lineWidth: 0.75)
            }
            .clipShape(shape)
            .contentShape(shape)
    }

    @available(macOS 26.0, *)
    private func nativeGlassSurface(content: Content, shape: Squircle) -> some View {
        let glass: Glass = glassStyle == .clear
            ? .clear.tint(Color.black.opacity(0.06))
            : .regular.tint(Color.black.opacity(0.22))
        let lightingStops: [Gradient.Stop] = glassStyle == .clear
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

        return content
            .background {
                ZStack {
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
                .allowsHitTesting(false)
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.16), lineWidth: 0.75)
            }
            .clipShape(shape)
            .contentShape(shape)
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
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if glassStyle == .stableAcrylic {
            content
                .background {
                    ZStack {
                        shape.fill(
                            colorScheme == .dark
                                ? Color(red: 0.14, green: 0.145, blue: 0.16)
                                : Color(red: 0.82, green: 0.83, blue: 0.85)
                        )
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.11 : 0.42),
                                Color.clear,
                                Color.black.opacity(colorScheme == .dark ? 0.12 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .clipShape(shape)
                }
                .overlay {
                    shape.stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.15)
                            : Color.black.opacity(0.12),
                        lineWidth: 0.75
                    )
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
}
