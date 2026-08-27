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
    let preferences: PanelGlassPreferences
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var panelShape: Squircle {
        Squircle(
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )
    }

    private var supportsNativeGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let profile = PanelGlassProfile.resolve(
            PanelGlassResolutionInputs(
                preferences: preferences,
                supportsNativeGlass: supportsNativeGlass,
                reduceTransparency: reduceTransparency
            )
        )

        switch profile.surface {
        case let .native(material):
            if #available(macOS 26.0, *) {
                content
                    .clipShape(panelShape)
                    .glassEffect(
                        nativeGlass(
                            material: material,
                            tint: profile.tint,
                            response: profile.response
                        ),
                        in: panelShape
                    )
            } else {
                legacyMaterialSurface(content)
            }
        case .legacyMaterial:
            legacyMaterialSurface(content)
        case .opaque:
            opaqueSurface(content)
        }
    }

    private func legacyMaterialSurface(_ content: Content) -> some View {
        content
            .background {
                Rectangle().fill(.ultraThinMaterial)
            }
            .clipShape(panelShape)
    }

    private func opaqueSurface(_ content: Content) -> some View {
        content
            .background {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            }
            .clipShape(panelShape)
    }

    @available(macOS 26.0, *)
    private func nativeGlass(
        material: PanelGlassMaterialPreference,
        tint: PanelGlassTintPreference,
        response: PanelGlassResponsePreference
    ) -> Glass {
        let base: Glass
        switch material {
        case .regular:
            base = .regular
        case .clear:
            base = .clear
        }

        let tinted: Glass
        switch tint {
        case .none:
            tinted = base
        case .accent:
            tinted = base.tint(Color.accentColor)
        }

        return tinted.interactive(response == .interactive)
    }
}

extension View {
    func atticPanelSurface(
        preferences: PanelGlassPreferences,
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius
    ) -> some View {
        modifier(AtticPanelSurface(preferences: preferences, cornerRadius: cornerRadius))
    }

    /// Temporary source compatibility while callers move from the former
    /// translucency toggle to the discrete native glass profile.
    func atticPanelSurface(
        translucent _: Bool,
        cornerRadius: CGFloat = AtticStyle.panelCornerRadius
    ) -> some View {
        modifier(AtticPanelSurface(
            preferences: PanelGlassPreferences(
                material: .regular,
                tint: .none,
                response: .interactive
            ),
            cornerRadius: cornerRadius
        ))
    }
}
