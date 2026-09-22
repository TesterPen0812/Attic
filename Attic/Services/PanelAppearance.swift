import Foundation

/// How the panel surface is built. Together with the palette, the Depth
/// toggle and the Tint step this is the whole user-facing appearance model.
enum PanelSurfaceStyle: String, CaseIterable, Identifiable, Sendable {
    // These raw values are persisted (`AppSettings.Key.panelSurfaceStyle`).
    case solid
    case glass
    case frosted

    static let defaultStyle: PanelSurfaceStyle = .glass

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

    var systemImage: String {
        switch self {
        case .solid: "square.fill"
        case .glass: "square.on.square.dashed"
        case .frosted: "square.fill.on.square"
        }
    }

    var accessibilityIdentifier: String { "setting-panel-surface-\(rawValue)" }
}

/// The strength of the accent wash across the top of the panel. Every step
/// is calibrated per palette, mode, surface and Depth state to the same
/// perceived strength (`PanelTintCalibration`).
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

    var detail: String {
        switch self {
        case .off: "No wash. Just the palette surface."
        case .subtle: "A hint of the accent at the top."
        case .vivid: "Clearly coloured, still calm."
        case .bold: "The strongest step that keeps text readable."
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
