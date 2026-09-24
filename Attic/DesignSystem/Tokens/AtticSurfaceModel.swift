import Foundation
import SwiftUI

/// How a background surface is composed: the palette-hued base colour, how
/// much of it covers the desktop on Glass and Frosted (the foundation), and
/// the Tint drawn over it. Customisation changes only the background and the
/// accent; on translucent or tinted panels the text steps one shade stronger
/// (`AtticColorTokens`) so the PR #5 look stays readable.
///
/// The owner's decision (2026-09-24) keeps the PR #5 look:
///
/// - **Glass and Frosted** keep the PR #5 coverage: the least foundation at
///   which every base-ladder text role keeps 3 : 1 (Glass) or 3.5 : 1
///   (Frosted) over the desktop that fights the text. Under Increase
///   Contrast the coverage rises until all text keeps 4.5 : 1.
/// - **Tints** are drawn at the strengths PR #5 designed (ΔE 3 / 7 / 12, or
///   Original's neutral shade), never held back.
///
/// The readability rule the tokens are tuned to and the appearance check
/// enforces (`floor(for:)`): on Solid, tinted Solid, and whenever Increase
/// Contrast or Reduce Transparency is on, all text keeps 4.5 : 1. On Glass
/// and Frosted, body text and labels keep 4.5 : 1 and helper text at least
/// 3 : 1 over any desktop (black, mid-grey, white). Icons and priority
/// colours keep 3 : 1 everywhere.
///
/// Desktops are modelled from the measured PR #5 renders of a black and a
/// white desktop under each native surface
/// (`Docs/Appearance-Model-2026-09.md`), interpolated linearly.
struct AtticSurfaceModel: Equatable, Sendable {
    let kind: AtticPanelSurfaceTreatment.Kind
    let appearance: AtticPanelThemeAppearance
    /// The opaque, palette-hued base colour.
    let base: AtticRGBA
    /// Opacity of `base` over the native material (1 on Solid).
    let foundationOpacity: Double
    /// The Tint's colour (a palette's accent wash, or Original's neutral shade).
    let washColor: AtticRGBA
    /// The drawn Tint, top (0) to bottom (1), at its designed strength.
    let tintStops: [PanelTintStop]
    /// Increase Contrast is on (all text keeps 4.5 : 1 on every surface).
    let increaseContrast: Bool

    struct Pair: Equatable, Sendable {
        let ink: AtticInk
        let foreground: AtticRGBA
        /// State fills drawn between the surface and the foreground, bottom first.
        let overlays: [AtticRGBA]
    }

    /// A flat grey desktop behind a translucent surface.
    enum Desktop: String, CaseIterable, Sendable {
        case black
        case midGrey
        case white

        var level: Double {
            switch self {
            case .black: 0
            case .midGrey: 0.5
            case .white: 1
            }
        }
    }

    // MARK: Composite

    /// The measured native render of a grey desktop (`desktop` 0 = black,
    /// 1 = white) under this surface kind, before the foundation.
    static func underlay(kind: AtticPanelSurfaceTreatment.Kind, appearance: AtticPanelThemeAppearance, desktop: Double) -> AtticRGBA {
        guard let endpoints = renderEndpoints(kind: kind, appearance: appearance) else {
            return .grey(desktop * 255)
        }
        return .grey(endpoints.black + (endpoints.white - endpoints.black) * desktop)
    }

    /// The measured native renders (sRGB bytes) of a black and a white
    /// desktop; nil for Solid, which transmits nothing.
    static func renderEndpoints(kind: AtticPanelSurfaceTreatment.Kind, appearance: AtticPanelThemeAppearance) -> (black: Double, white: Double)? {
        switch (kind, appearance) {
        case (.glass, .dark): (20, 143)
        case (.glass, .light): (104, 236)
        case (.frosted, .dark): (24, 166)
        case (.frosted, .light): (89, 241)
        case (.solid, _): nil
        }
    }

    func underlay(_ desktop: Desktop) -> AtticRGBA {
        Self.underlay(kind: kind, appearance: appearance, desktop: desktop.level)
    }

    /// The desktop that fights the text most.
    var worstDesktop: Desktop { appearance == .dark ? .white : .black }

    /// The desktops this surface is judged over (Solid transmits nothing).
    var desktops: [Desktop] { kind == .solid ? [.midGrey] : Desktop.allCases }

    /// Helper-level text: helper, placeholder, the sidebar's hint, and
    /// disabled text (the quiet end of the ladder, with the same floor).
    static func isHelperText(_ ink: AtticInk) -> Bool {
        ink == .helper || ink == .placeholder || ink == .chromeHint || ink == .disabledText
    }

    /// The least contrast a role must keep on this surface (the rule above).
    func floor(for ink: AtticInk) -> Double {
        Self.floor(for: ink, kind: kind, increaseContrast: increaseContrast)
    }

    static func floor(for ink: AtticInk, kind: AtticPanelSurfaceTreatment.Kind, increaseContrast: Bool) -> Double {
        switch ink.floor {
        case .nonText: return 3
        case .text:
            if kind != .solid, !increaseContrast, isHelperText(ink) { return 3 }
            return 4.5
        }
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

    /// Where panel content starts: the first content line (the status tabs
    /// or a note's title), below the 12 + 32 + 12 pt header. Above it only
    /// the opaque header controls sit, and scrolled content fades under the
    /// edge veil. Text is judged here, where the Tint is strongest for it.
    static let contentTop: Double = (AtticSpacing.panelMargin * 2 + AtticControlSize.capsuleHeight) / AtticLayout.panelSize.height

    /// Every background a pair is drawn on, over every desktop, from the
    /// first content line (strongest Tint) to the bottom edge (weakest):
    /// a Light tint darkens the surface, a Dark tint deepens it, so either
    /// end can be the hard one.
    func backgrounds(for pair: Pair) -> [AtticRGBA] {
        let heights = tintStops.isEmpty ? [Self.contentTop] : [Self.contentTop, 1]
        return desktops.flatMap { desktop in
            heights.map { height in pair.overlays.reduce(composite(desktop, at: height)) { $1.over($0) } }
        }
    }

    /// Worst contrast of every pair relative to its floor (the rule above).
    /// >= 1 means every pair passes.
    func worstMargin(_ pairs: [Pair]) -> Double {
        var margin = Double.infinity
        for pair in pairs {
            for background in backgrounds(for: pair) {
                margin = min(margin, pair.foreground.contrast(on: background) / floor(for: pair.ink))
            }
        }
        return margin
    }

    // MARK: Solving

    /// 1.5 % above every floor, so 8-bit rendering never rounds a pass away.
    static let solverMargin = 1.015

    /// Solves the surface. `lookPairs` are the base-ladder roles that set
    /// the PR #5 coverage; under Increase Contrast `pairs` (the final inks)
    /// must keep the full rule instead.
    static func solve(
        base: AtticRGBA,
        kind: AtticPanelSurfaceTreatment.Kind,
        appearance: AtticPanelThemeAppearance,
        palette: AtticPanelTheme,
        themePalette: AtticPanelThemePalette,
        tint: PanelTintLevel,
        tintLength: Double,
        increaseContrast: Bool,
        lookPairs: [Pair]
    ) -> AtticSurfaceModel {
        let wash = washColor(palette: palette, themePalette: themePalette, appearance: appearance)

        func model(foundation: Double, stops: [PanelTintStop]) -> AtticSurfaceModel {
            AtticSurfaceModel(
                kind: kind, appearance: appearance, base: base, foundationOpacity: foundation,
                washColor: wash, tintStops: stops, increaseContrast: increaseContrast
            )
        }

        // 1. The foundation.
        var foundation = 1.0
        if kind != .solid {
            let surfaceFloor = kind == .glass ? 3.0 : 3.5
            for percent in 0...100 {
                let candidate = model(foundation: Double(percent) / 100, stops: [])
                let passes: Bool
                if increaseContrast {
                    // All text 4.5 : 1, icons 3 : 1, over every desktop.
                    passes = candidate.worstMargin(lookPairs) >= solverMargin
                } else {
                    // The PR #5 coverage: every text role of the base ladder
                    // keeps the surface floor over the worst desktop.
                    let worst = candidate.composite(candidate.worstDesktop)
                    passes = lookPairs.filter { $0.ink.floor == .text }.allSatisfy { pair in
                        pair.foreground.contrast(on: pair.overlays.reduce(worst) { $1.over($0) }) >= surfaceFloor * solverMargin
                    }
                }
                if passes {
                    foundation = candidate.foundationOpacity
                    break
                }
            }
        }

        // 2. The Tint at its designed strength.
        let length = PanelTintLength.clamped(tintLength)
        var stops: [PanelTintStop] = []
        if tint != .off {
            if palette.usesNeutralTint {
                stops = PanelNeutralShade.stops(level: tint, length: length)
            } else if let target = tint.targetColorDifference {
                let plain = model(foundation: foundation, stops: []).composite(.midGrey)
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
        return model(foundation: foundation, stops: stops)
    }

    /// The Tint's colour. Original keeps its neutral shade. A palette washes
    /// in its accent's hue: bright in Light, but deep in Dark, so the wash
    /// colours and darkens the charcoal (light text gains contrast) instead
    /// of lightening it (which the soft grey ladder cannot afford).
    static func washColor(palette: AtticPanelTheme, themePalette: AtticPanelThemePalette, appearance: AtticPanelThemeAppearance) -> AtticRGBA {
        if palette.usesNeutralTint { return AtticRGBA(PanelNeutralShade.color(for: appearance)) }
        guard appearance == .dark else {
            return AtticRGBA(PanelTintCalibration.washColor(for: themePalette, appearance: appearance))
        }
        // The palette's hue, fully saturated, at 80 % of the charcoal's
        // luminance (deep enough to darken, bright enough to carry colour:
        // every palette reaches its designed ΔE, Sea Glass included):
        // every hue then darkens the surface by the same amount, whatever its
        // natural brightness (a green is far brighter than a blue at one value).
        let hue = PanelTintCalibration.hue(of: themePalette.accent)
        let target = AtticRGBA(0x2C2C2D).relativeLuminance * 0.8
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<30 {
            let middle = (lower + upper) / 2
            if AtticRGBA(PanelTintCalibration.color(hue: hue, saturation: 1, value: middle)).relativeLuminance < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        return AtticRGBA(PanelTintCalibration.color(hue: hue, saturation: 1, value: lower))
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
            p(.icon, [pressed]), p(.icon, [recessed, hover]), p(.icon, [controlFace, chipHover]),
            p(.chevron, [pressed]), p(.chevron, [recessed, hover]),
            p(.accent, [selected]), p(.accentText, [tagFill]), p(.accentText, [recessed, tagFillSelected]),
            p(.dueText, [selected]), p(.warningText, []),
            p(.priorityHigh, [pressed]), p(.priorityMedium, [pressed]),
            p(.priorityLow, [pressed]), p(.priorityNone, [pressed]), p(.doneFill, [pressed]),
            p(.priorityHigh, [recessed, hover]), p(.priorityMedium, [recessed, hover]),
            p(.priorityLow, [recessed, hover]), p(.priorityNone, [recessed, hover]),
            // Disabled rows and the ghost of a raised control (no hover or
            // press while disabled).
            p(.disabledText, []), p(.disabledText, [recessed]), p(.disabledText, [controlFace]),
            p(.disabledIcon, []), p(.disabledIcon, [recessed]), p(.disabledIcon, [controlFace])
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
