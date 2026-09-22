import SwiftUI

/// Depth: a neutral crown across the top of the panel, drawn above the
/// surface fill and clipped to the squircle. It is the Original Dark
/// "near-black crown and progressively clearer lower half" from the accepted
/// panel direction, offered on every palette and surface as one toggle.
/// The stops are the owner's exact values; the colour is black in Dark and
/// white in Light. Everything about Depth lives here so removing it is one
/// type, one modifier and one setting.
enum PanelDepthCrown {
    struct Stop: Equatable, Sendable {
        let opacity: Double
        let location: Double
    }

    /// Top to bottom. The last stop is nearly clear, never zero, so the
    /// crown reads as one continuous shade rather than a band with an end.
    static let stops: [Stop] = [
        Stop(opacity: 0.82, location: 0.00),
        Stop(opacity: 0.58, location: 0.42),
        Stop(opacity: 0.18, location: 0.74),
        Stop(opacity: 0.02, location: 1.00)
    ]

    static func poleColor(for appearance: AtticPanelThemeAppearance) -> AtticThemeColor {
        appearance == .dark
            ? AtticThemeColor(red: 0, green: 0, blue: 0)
            : AtticThemeColor(red: 1, green: 1, blue: 1)
    }

    /// The crown's opacity at a normalised vertical location, linearly
    /// interpolated between stops exactly as the gradient draws it.
    static func opacity(at location: Double) -> Double {
        guard location.isFinite else { return 0 }
        let clamped = min(max(location, 0), 1)
        guard let first = stops.first, let last = stops.last else { return 0 }
        if clamped <= first.location { return first.opacity }
        if clamped >= last.location { return last.opacity }
        for (lower, upper) in zip(stops, stops.dropFirst()) where clamped <= upper.location {
            let span = upper.location - lower.location
            guard span > 0 else { return upper.opacity }
            let progress = (clamped - lower.location) / span
            return lower.opacity + (upper.opacity - lower.opacity) * progress
        }
        return last.opacity
    }

    /// The crown composited over `surface` at a location.
    static func composite(
        over surface: AtticThemeColor,
        appearance: AtticPanelThemeAppearance,
        location: Double
    ) -> AtticThemeColor {
        surface.mixed(with: poleColor(for: appearance), amount: opacity(at: location))
    }
}

/// The drawn crown. Hosts place it directly above the surface fill and
/// below the tint wash, inside the surface clip.
struct PanelDepthCrownView: View {
    let appearance: AtticPanelThemeAppearance
    let shape: Squircle

    var body: some View {
        let pole = PanelDepthCrown.poleColor(for: appearance)
        LinearGradient(
            stops: PanelDepthCrown.stops.map {
                .init(color: pole.swiftUIColor(opacity: $0.opacity), location: $0.location)
            },
            startPoint: .top,
            endPoint: .bottom
        )
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
