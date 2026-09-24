import Foundation
import SwiftUI

/// How a background surface is composed: the palette-hued base colour, how
/// much of it covers the desktop on Glass and Frosted (the foundation), and
/// the Tint drawn over it. Customisation changes only this; controls, cards
/// and text stay in the base style.
///
/// The readability model reuses the measured native-surface renders from
/// PR #5 (`Docs/Appearance-Model-2026-09.md`): Liquid Glass and Frosted turn
/// a black and a white desktop into known greys. Two desktops are judged:
///
/// - **typical**: a 50 % grey desktop, interpolated between the measured
///   black and white renders. Every role must reach its full floor here
///   (4.5 : 1 text, 3 : 1 non-text), as on Solid.
/// - **worst**: the desktop that fights the text (black behind Light,
///   white behind Dark). Here the owner's PR #5 transparency decision holds:
///   every role keeps at least 3 : 1 on Glass and 3.5 : 1 on Frosted.
///
/// The foundation is the smallest whole percent that passes both; a Tint
/// that would break a floor is scaled down (`isTintClamped`). Nothing here
/// runs at draw time more than once per context (`AtticColorTokenCache`).
struct AtticSurfaceModel: Equatable, Sendable {
    let kind: AtticPanelSurfaceTreatment.Kind
    let appearance: AtticPanelThemeAppearance
    /// The opaque, palette-hued base colour.
    let base: AtticRGBA
    /// Opacity of `base` over the native material (1 on Solid).
    let foundationOpacity: Double
    /// The Tint's colour (a palette's accent wash, or Original's neutral shade).
    let washColor: AtticRGBA
    /// The drawn Tint, top (0) to bottom (1), after any readability clamp.
    let tintStops: [PanelTintStop]
    /// The factor the readability floors applied to the Tint (1 = as designed).
    let tintScale: Double

    var isTintClamped: Bool { !tintStops.isEmpty && tintScale < 0.999 }

    struct Pair: Equatable, Sendable {
        let ink: AtticInk
        let foreground: AtticRGBA
        /// State fills drawn between the surface and the foreground, bottom first.
        let overlays: [AtticRGBA]
    }

    enum Desktop: String, CaseIterable, Sendable {
        case typical
        case worst
    }

    // MARK: Composite

    /// The measured native render of a grey desktop (`desktop` 0 = black,
    /// 1 = white) under this surface kind, before the foundation.
    static func underlay(kind: AtticPanelSurfaceTreatment.Kind, appearance: AtticPanelThemeAppearance, desktop: Double) -> AtticRGBA {
        let endpoints: (black: Double, white: Double)
        switch (kind, appearance) {
        case (.glass, .dark): endpoints = (20, 143)
        case (.glass, .light): endpoints = (104, 236)
        case (.frosted, .dark): endpoints = (24, 166)
        case (.frosted, .light): endpoints = (89, 241)
        case (.solid, _): endpoints = (desktop * 255, desktop * 255)
        }
        return .grey(endpoints.black + (endpoints.white - endpoints.black) * desktop)
    }

    func underlay(_ desktop: Desktop) -> AtticRGBA {
        switch desktop {
        case .typical: Self.underlay(kind: kind, appearance: appearance, desktop: 0.5)
        case .worst: Self.underlay(kind: kind, appearance: appearance, desktop: appearance == .dark ? 1 : 0)
        }
    }

    /// The desktops this surface is judged over (Solid transmits nothing).
    var desktops: [Desktop] { kind == .solid ? [.typical] : Desktop.allCases }

    /// The least contrast a role must keep over `desktop`.
    func floor(for ink: AtticInk, desktop: Desktop) -> Double {
        let roleFloor = ink.floor.ratio
        guard kind != .solid, desktop == .worst else { return roleFloor }
        let surfaceFloor = kind == .glass ? 3.0 : 3.5
        return min(roleFloor, surfaceFloor)
    }

    func tintOpacity(at location: Double) -> Double {
        Self.opacity(of: tintStops, at: location)
    }

    /// The surface as drawn at a height, over a desktop.
    func composite(_ desktop: Desktop, at location: Double = 0) -> AtticRGBA {
        composite(over: underlay(desktop), at: location)
    }

    func composite(over underlay: AtticRGBA, at location: Double = 0) -> AtticRGBA {
        let founded = kind == .solid ? base : base.withAlpha(foundationOpacity).over(underlay)
        return washColor.withAlpha(tintOpacity(at: location)).over(founded)
    }

    /// Worst contrast of every pair at the top edge (where the Tint is
    /// strongest), relative to its floor. >= 1 means every pair passes.
    func worstMargin(_ pairs: [Pair]) -> Double {
        var margin = Double.infinity
        for desktop in desktops {
            let surface = composite(desktop, at: 0)
            for pair in pairs where pair.ink.floor != .exempt {
                let background = pair.overlays.reduce(surface) { $1.over($0) }
                let ratio = pair.foreground.contrast(on: background)
                margin = min(margin, ratio / floor(for: pair.ink, desktop: desktop))
            }
        }
        return margin
    }

    // MARK: Solving

    /// 1.5 % above every floor, so 8-bit rendering never rounds a pass away.
    static let solverMargin = 1.015

    static func solve(
        base: AtticRGBA,
        kind: AtticPanelSurfaceTreatment.Kind,
        appearance: AtticPanelThemeAppearance,
        palette: AtticPanelTheme,
        themePalette: AtticPanelThemePalette,
        tint: PanelTintLevel,
        tintLength: Double,
        pairs: [Pair]
    ) -> AtticSurfaceModel {
        let wash: AtticRGBA = palette.usesNeutralTint
            ? AtticRGBA(PanelNeutralShade.color(for: appearance))
            : AtticRGBA(PanelTintCalibration.washColor(for: themePalette, appearance: appearance))

        func model(foundation: Double, stops: [PanelTintStop], scale: Double) -> AtticSurfaceModel {
            AtticSurfaceModel(
                kind: kind, appearance: appearance, base: base, foundationOpacity: foundation,
                washColor: wash,
                tintStops: stops.map { PanelTintStop(opacity: $0.opacity * scale, location: $0.location) },
                tintScale: scale
            )
        }

        // 1. The foundation: the least whole percent that keeps every floor.
        var foundation = 1.0
        if kind != .solid {
            for percent in 0...100 {
                let candidate = Double(percent) / 100
                if model(foundation: candidate, stops: [], scale: 1).worstMargin(pairs) >= Self.solverMargin {
                    foundation = candidate
                    break
                }
            }
        }

        // 2. The Tint as designed.
        let length = PanelTintLength.clamped(tintLength)
        var stops: [PanelTintStop] = []
        if tint != .off {
            if palette.usesNeutralTint {
                stops = PanelNeutralShade.stops(level: tint, length: length)
            } else if let target = tint.targetColorDifference {
                let plain = model(foundation: foundation, stops: [], scale: 1).composite(.typical)
                var lower = 0.0
                var upper = 1.0
                for _ in 0..<32 {
                    let middle = (lower + upper) / 2
                    let tinted = wash.withAlpha(middle).over(plain)
                    if ColorDifference.deltaE76(plain.themeColor, tinted.themeColor) < target {
                        lower = middle
                    } else {
                        upper = middle
                    }
                }
                stops = [PanelTintStop(opacity: upper, location: 0), PanelTintStop(opacity: 0, location: length)]
            }
        }

        // 3. Scale the Tint down only as far as readability needs.
        var scale = 1.0
        if !stops.isEmpty, model(foundation: foundation, stops: stops, scale: 1).worstMargin(pairs) < Self.solverMargin {
            var lower = 0.0
            var upper = 1.0
            for _ in 0..<24 {
                let middle = (lower + upper) / 2
                if model(foundation: foundation, stops: stops, scale: middle).worstMargin(pairs) >= Self.solverMargin {
                    lower = middle
                } else {
                    upper = middle
                }
            }
            scale = (lower * 1000).rounded(.down) / 1000
        }
        return model(foundation: foundation, stops: stops, scale: scale)
    }

    /// The pairs every panel surface must keep readable: each text and icon
    /// role on the backgrounds it is actually drawn on.
    static func readabilityPairs(
        inks: [AtticInk: AtticRGBA],
        hover: AtticRGBA,
        selected: AtticRGBA,
        pressed: AtticRGBA,
        controlFace: AtticRGBA,
        chipSelected: AtticRGBA,
        chipHover: AtticRGBA,
        recessed: AtticRGBA,
        tagFill: AtticRGBA,
        tagFillSelected: AtticRGBA
    ) -> [Pair] {
        func p(_ ink: AtticInk, _ overlays: [AtticRGBA]) -> Pair {
            Pair(ink: ink, foreground: inks[ink] ?? .black(1), overlays: overlays)
        }
        return [
            p(.heading, []), p(.body, [pressed]), p(.body, [recessed, hover]), p(.label, [selected]),
            p(.helper, [pressed]), p(.helper, [recessed, hover]),
            p(.placeholder, [controlFace]), p(.glyph, [controlFace]), p(.heading, [controlFace, chipSelected]),
            p(.icon, [selected]), p(.icon, [controlFace, chipHover]), p(.chevron, [selected]),
            p(.accent, [selected]), p(.accentText, [tagFill]), p(.accentText, [recessed, tagFillSelected]),
            p(.dueText, [selected]), p(.warningText, []),
            p(.priorityHigh, [selected]), p(.priorityMedium, [selected]),
            p(.priorityLow, [selected]), p(.priorityNone, [selected]), p(.doneFill, [selected])
        ]
    }

    // MARK: Palette hue

    /// A gentle hue of the palette on a base neutral: same lightness, the
    /// palette's hue, low saturation. Original keeps the neutral base.
    static func hued(
        _ neutral: AtticRGBA,
        palette: AtticPanelTheme,
        themePalette: AtticPanelThemePalette,
        dark: Bool,
        chrome: Bool = false
    ) -> AtticRGBA {
        guard palette != .original else { return neutral }
        let source = AtticRGBA(themePalette.surfaceTint)
        let (hue, sourceSaturation, _) = source.hsl
        let saturation: Double
        switch (dark, chrome) {
        case (false, false): saturation = 0.62
        case (false, true): saturation = 0.30
        case (true, false): saturation = 0.17
        case (true, true): saturation = 0.08
        }
        let tinted = { (lightness: Double) in
            AtticRGBA(hue: hue, saturation: saturation * min(1, sourceSaturation * 2.2), lightness: lightness)
        }
        // Keep the neutral's luminance, so every text contrast is unchanged.
        let target = neutral.relativeLuminance
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<30 {
            let middle = (lower + upper) / 2
            if tinted(middle).relativeLuminance < target { lower = middle } else { upper = middle }
        }
        return tinted(dark ? lower : upper)
    }

    static func opacity(of stops: [PanelTintStop], at location: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        let y = min(max(location, 0), 1)
        if y <= first.location { return first.opacity }
        if y >= last.location { return last.opacity }
        for (lower, upper) in zip(stops, stops.dropFirst()) where y <= upper.location {
            let span = upper.location - lower.location
            guard span > 0 else { return upper.opacity }
            return lower.opacity + (upper.opacity - lower.opacity) * (y - lower.location) / span
        }
        return last.opacity
    }

    /// SwiftUI gradient stops for the Tint, in the wash colour.
    var tintGradientStops: [Gradient.Stop] {
        tintStops.map { Gradient.Stop(color: washColor.withAlpha($0.opacity).color, location: $0.location) }
    }
}
