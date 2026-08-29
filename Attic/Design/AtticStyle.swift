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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Squircle(
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )

        if #available(macOS 26.0, *), translucent {
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

    @available(macOS 26.0, *)
    private func nativeGlassSurface(content: Content, shape: Squircle) -> some View {
        let glass: Glass = glassStyle == .clear
            ? .clear.tint(Color.black.opacity(0.10))
            : .regular.tint(Color.black.opacity(0.22))
        let lightingStops: [Gradient.Stop] = glassStyle == .clear
            ? [
                .init(color: Color.black.opacity(0.90), location: 0),
                .init(color: Color.black.opacity(0.72), location: 0.42),
                .init(color: Color.black.opacity(0.30), location: 0.74),
                .init(color: Color.black.opacity(0.06), location: 1)
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

private struct AtticGlassControlModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
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
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius
    ) -> some View {
        modifier(
            AtticPanelSurface(
                translucent: translucent,
                glassStyle: glassStyle,
                opaqueColor: opaqueColor,
                cornerRadius: cornerRadius
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
