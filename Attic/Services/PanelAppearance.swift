import Foundation

/// How the panel surface is built. Together with the palette and Tint step,
/// this is the whole user-facing appearance model.
enum PanelSurfaceStyle: String, CaseIterable, Identifiable, Sendable {
    // These raw values are persisted (`AppSettings.Key.panelSurfaceStyle`).
    case solid
    case glass
    case frosted

    /// Paper under the list (owner, 2026-10-25: list round 2): Solid for
    /// a fresh install; Glass and Frosted stay in Settings. A stored choice
    /// is never rewritten.
    static let defaultStyle: PanelSurfaceStyle = .solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .glass: "Glass"
        case .frosted: "Frosted"
        }
    }

    /// One line, from the user's side.
    var detail: String {
        switch self {
        case .solid: "A solid panel in the palette colour."
        case .glass: "Liquid Glass with the desktop showing through."
        case .frosted: "A soft blur with a wash of the palette colour."
        }
    }


    var accessibilityIdentifier: String { "setting-panel-surface-\(rawValue)" }
}

/// The strength of the Tint across the top of the panel: Original's neutral
/// shade (`PanelNeutralShade`) or a custom palette's accent wash, which is
/// calibrated per palette, mode and surface to the same perceived strength
/// (`PanelTintCalibration`).
enum PanelTintLevel: String, CaseIterable, Identifiable, Sendable {
    // These raw values are persisted (`AppSettings.Key.panelTint`).
    case off
    case subtle
    case vivid
    case bold

    static let defaultLevel: PanelTintLevel = .off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .vivid: "Vivid"
        case .bold: "Bold"
        }
    }

    /// One line, from the user's side. Original's Tint is a neutral shade;
    /// the custom palettes' Tint is their accent colour.
    func detail(neutral: Bool) -> String {
        switch (self, neutral) {
        case (.off, _): "No tint. Just the palette surface."
        case (.subtle, true): "A faint shade across the top."
        case (.vivid, true): "A clear shade that fades down the panel."
        case (.bold, true): "A deep shade at the top, fading to glass."
        case (.subtle, false): "A hint of the accent at the top."
        case (.vivid, false): "Clearly coloured, still calm."
        case (.bold, false): "The strongest colour that keeps text readable."
        }
    }

    /// The CIE Lab colour difference (ΔE76) the step targets between the
    /// top-edge composite with and without the wash. `nil` draws nothing.
    var targetColorDifference: Double? {
        switch self {
        case .off: nil
        case .subtle: 3
        case .vivid: 7
        case .bold: 12
        }
    }

    var accessibilityIdentifier: String { "setting-panel-tint-\(rawValue)" }

    /// Where a legacy gradient lands: the step whose strength matches what
    /// the user actually saw, by the same colour-difference scale.
    static func level(forLegacyColorDifference difference: Double) -> PanelTintLevel {
        guard difference.isFinite else { return .off }
        if difference < 3 { return .off }
        if difference < 5 { return .subtle }
        if difference < 9.5 { return .vivid }
        return .bold
    }
}
