#if ATTIC_GLOSS_LAB
import AppKit
import Observation
import SwiftUI

/// The Gloss lab's switches and sliders (experimental preview only, branch
/// `try/panel-gloss`; brief `ops/design/gloss-lab-brief-2026-11-22.md`).
/// Every idea is off by default, and with every switch off the panel draws
/// exactly as the trunk does. Values persist in this preview's own defaults;
/// a launch argument (`-GlossLab.<key> <value>`) overrides one for a run.
@MainActor
@Observable
final class GlossLab {
    static let shared = GlossLab(defaults: GlossLab.isTestProcess ? nil : .standard)

    static var isTestProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    @ObservationIgnored private let defaults: UserDefaults?
    /// True while `init` reads the stored values: reading must never write
    /// them back (a launch argument would otherwise be saved for good).
    @ObservationIgnored private var loading = true

    // MARK: Switches (ideas, numbered as in the brief)

    /// 1. Bare glass at the rim.
    var rimFade = false { didSet { save(rimFade, "rimFade") } }
    /// 3. Edge light on the panel.
    var edgeLight = false { didSet { save(edgeLight, "edgeLight") } }
    /// 4. A second inner edge.
    var innerEdge = false { didSet { save(innerEdge, "innerEdge") } }
    /// 5. Light from the top.
    var topLight = false { didSet { save(topLight, "topLight") } }
    /// 5, second switch: the light keeps out from under the controls (on by default).
    var topLightKeepsOut = true { didSet { save(topLightKeepsOut, "topLightKeepsOut") } }
    /// 6. Fine grain.
    var grain = false { didSet { save(grain, "grain") } }
    /// 10. One rim recipe for every control.
    var oneRim = false { didSet { save(oneRim, "oneRim") } }
    /// 2. A band of Apple's Clear glass around the edge, regular glass inside.
    var clearBand = false { didSet { save(clearBand, "clearBand") } }
    /// 7. A shadow that fits glass (in place of the trunk's elevation).
    var glassShadow = false { didSet { save(glassShadow, "glassShadow") } }
    /// 7, its own switch: a faint spill of light under the bottom edge.
    var glassSpill = false { didSet { save(glassSpill, "glassSpill") } }

    // MARK: Sliders

    /// 1: how far in from the edge the fade runs, pt (0 to 16).
    var rimFadeWidth: Double = 9 { didSet { save(rimFadeWidth, "rimFadeWidth") } }
    /// 3: line width, pt (1 to 4), and its strength in Light and in Dark.
    var edgeLightWidth: Double = 2.5 { didSet { save(edgeLightWidth, "edgeLightWidth") } }
    var edgeLightLight: Double = 0.6 { didSet { save(edgeLightLight, "edgeLightLight") } }
    var edgeLightDark: Double = 0.3 { didSet { save(edgeLightDark, "edgeLightDark") } }
    /// 3: the thin darker line along the bottom (its opacity).
    var edgeLightShade: Double = 0.14 { didSet { save(edgeLightShade, "edgeLightShade") } }
    /// 4: how far inside the rim, pt (1.5 to 4), and its strength.
    var innerEdgeInset: Double = 2.5 { didSet { save(innerEdgeInset, "innerEdgeInset") } }
    var innerEdgeStrength: Double = 0.25 { didSet { save(innerEdgeStrength, "innerEdgeStrength") } }
    /// 5: the top light and the bottom shade, per mode.
    var topLightLight: Double = 0.26 { didSet { save(topLightLight, "topLightLight") } }
    var bottomShadeLight: Double = 0.10 { didSet { save(bottomShadeLight, "bottomShadeLight") } }
    var topLightDark: Double = 0.13 { didSet { save(topLightDark, "topLightDark") } }
    var bottomShadeDark: Double = 0.14 { didSet { save(bottomShadeDark, "bottomShadeDark") } }
    /// 6: grain strength, percent (0 to 4).
    var grainPercent: Double = 1.5 { didSet { save(grainPercent, "grainPercent") } }
    /// 2: the band's width, pt (4 to 12), how the two glasses are laid, and
    /// whether they share one glass container.
    var clearBandWidth: Double = 7 { didSet { save(clearBandWidth, "clearBandWidth") } }
    var clearBandMethod: ClearBandMethod = .ring { didSet { save(clearBandMethod.rawValue, "clearBandMethod") } }
    var clearBandContainer = false { didSet { save(clearBandContainer, "clearBandContainer") } }
    /// 7: the tight contact shadow (Light, Dark) and the wide soft one
    /// (Light, Dark, radius, drop). The soft one is held inside the
    /// window's transparent margin (28 pt floating, 40 pt docked).
    var shadowContactLight: Double = 0.16 { didSet { save(shadowContactLight, "shadowContactLight") } }
    var shadowContactDark: Double = 0.34 { didSet { save(shadowContactDark, "shadowContactDark") } }
    var shadowSoftLight: Double = 0.10 { didSet { save(shadowSoftLight, "shadowSoftLight") } }
    var shadowSoftDark: Double = 0.26 { didSet { save(shadowSoftDark, "shadowSoftDark") } }
    var shadowSoftRadius: Double = 15 { didSet { save(shadowSoftRadius, "shadowSoftRadius") } }
    var shadowSoftDrop: Double = 6 { didSet { save(shadowSoftDrop, "shadowSoftDrop") } }
    /// 7, spill: its strength (white, 0 to 0.5).
    var spillStrength: Double = 0.14 { didSet { save(spillStrength, "spillStrength") } }

    // MARK: The lab window's own state

    enum Backdrop: String, CaseIterable, Identifiable {
        case none, black, white, picture
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .black: "Black"
            case .white: "White"
            case .picture: "Picture"
            }
        }
    }

    /// 2: Clear in a ring beside Regular inside it (no glass over glass), or
    /// Clear under the whole panel with Regular stacked over its inner part.
    enum ClearBandMethod: String, CaseIterable, Identifiable {
        case ring, stacked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ring: "Ring beside"
            case .stacked: "Stacked"
            }
        }
    }

    var backdrop: Backdrop = .none { didSet { save(backdrop.rawValue, "backdrop") } }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        defer { loading = false }
        guard let defaults else { return }
        func bool(_ key: String, _ value: inout Bool) {
            if defaults.object(forKey: Self.prefix + key) != nil { value = defaults.bool(forKey: Self.prefix + key) }
        }
        func double(_ key: String, _ value: inout Double) {
            if defaults.object(forKey: Self.prefix + key) != nil { value = defaults.double(forKey: Self.prefix + key) }
        }
        bool("rimFade", &rimFade); bool("edgeLight", &edgeLight); bool("innerEdge", &innerEdge)
        bool("topLight", &topLight); bool("topLightKeepsOut", &topLightKeepsOut); bool("grain", &grain)
        bool("oneRim", &oneRim)
        double("rimFadeWidth", &rimFadeWidth); double("edgeLightWidth", &edgeLightWidth)
        double("edgeLightLight", &edgeLightLight); double("edgeLightDark", &edgeLightDark)
        double("edgeLightShade", &edgeLightShade)
        double("innerEdgeInset", &innerEdgeInset); double("innerEdgeStrength", &innerEdgeStrength)
        double("topLightLight", &topLightLight); double("bottomShadeLight", &bottomShadeLight)
        double("topLightDark", &topLightDark); double("bottomShadeDark", &bottomShadeDark)
        double("grainPercent", &grainPercent)
        bool("clearBand", &clearBand); bool("glassShadow", &glassShadow); bool("glassSpill", &glassSpill)
        bool("clearBandContainer", &clearBandContainer)
        double("clearBandWidth", &clearBandWidth)
        double("shadowContactLight", &shadowContactLight); double("shadowContactDark", &shadowContactDark)
        double("shadowSoftLight", &shadowSoftLight); double("shadowSoftDark", &shadowSoftDark)
        double("shadowSoftRadius", &shadowSoftRadius); double("shadowSoftDrop", &shadowSoftDrop)
        double("spillStrength", &spillStrength)
        if let raw = defaults.string(forKey: Self.prefix + "clearBandMethod"), let value = ClearBandMethod(rawValue: raw) {
            clearBandMethod = value
        }
        if let raw = defaults.string(forKey: Self.prefix + "backdrop"), let value = Backdrop(rawValue: raw) { backdrop = value }
    }

    static let prefix = "GlossLab."

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        defaults?.set(value, forKey: Self.prefix + key)
    }

    // MARK: Presets and actions

    /// Every switch off: the trunk's look. Slider values are kept.
    func allOff() {
        rimFade = false; edgeLight = false; innerEdge = false; topLight = false; grain = false; oneRim = false
        clearBand = false; glassShadow = false; glassSpill = false
    }

    /// The sliders back to the lead's starting values.
    func resetSliders() {
        let fresh = GlossLab(defaults: nil)
        rimFadeWidth = fresh.rimFadeWidth
        edgeLightWidth = fresh.edgeLightWidth; edgeLightLight = fresh.edgeLightLight
        edgeLightDark = fresh.edgeLightDark; edgeLightShade = fresh.edgeLightShade
        innerEdgeInset = fresh.innerEdgeInset; innerEdgeStrength = fresh.innerEdgeStrength
        topLightLight = fresh.topLightLight; bottomShadeLight = fresh.bottomShadeLight
        topLightDark = fresh.topLightDark; bottomShadeDark = fresh.bottomShadeDark
        grainPercent = fresh.grainPercent
        topLightKeepsOut = true
        clearBandWidth = fresh.clearBandWidth; clearBandMethod = fresh.clearBandMethod
        clearBandContainer = fresh.clearBandContainer
        shadowContactLight = fresh.shadowContactLight; shadowContactDark = fresh.shadowContactDark
        shadowSoftLight = fresh.shadowSoftLight; shadowSoftDark = fresh.shadowSoftDark
        shadowSoftRadius = fresh.shadowSoftRadius; shadowSoftDrop = fresh.shadowSoftDrop
        spillStrength = fresh.spillStrength
    }

    /// 0. 3D: dark glass lit from the top is Dark mode plus ideas 5 and 3.
    /// The mode is the app's own setting; the caller sets it.
    func apply3D() {
        topLight = true
        edgeLight = true
    }

    /// The current switches and values as text, for "Copy values".
    func valuesText(mode: String) -> String {
        func f(_ value: Double) -> String { String(format: "%.2f", value) }
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        return """
        Attic Gloss lab values
        Mode: \(mode)
        Backdrop: \(backdrop.title)
        1 Bare glass at the rim: \(on(rimFade)), width \(f(rimFadeWidth)) pt
        2 A band of Clear glass: \(on(clearBand)), width \(f(clearBandWidth)) pt, \(clearBandMethod.title), one container: \(on(clearBandContainer))
        3 Edge light on the panel: \(on(edgeLight)), width \(f(edgeLightWidth)) pt, Light \(f(edgeLightLight)), Dark \(f(edgeLightDark)), bottom line \(f(edgeLightShade))
        4 A second inner edge: \(on(innerEdge)), inset \(f(innerEdgeInset)) pt, strength \(f(innerEdgeStrength))
        5 Light from the top: \(on(topLight)), Light top \(f(topLightLight)) shade \(f(bottomShadeLight)), Dark top \(f(topLightDark)) shade \(f(bottomShadeDark)), keeps out from under the controls: \(on(topLightKeepsOut))
        6 Fine grain: \(on(grain)), \(f(grainPercent)) %
        7 A shadow that fits glass: \(on(glassShadow)), contact Light \(f(shadowContactLight)) Dark \(f(shadowContactDark)), soft Light \(f(shadowSoftLight)) Dark \(f(shadowSoftDark)), radius \(f(shadowSoftRadius)) pt, drop \(f(shadowSoftDrop)) pt
        7 Spill of light under the bottom edge: \(on(glassSpill)), \(f(spillStrength))
        10 One rim recipe for every control: \(on(oneRim))
        """
    }
}

#if DEBUG
/// Test seam: how many times each lab layer's body has run.
@MainActor
enum GlossLabCounters {
    static var surfaceLayer = 0
    static var rimLayer = 0
    static var stageSurface = 0
    /// Edge light builds on glass controls (the trunk's or idea 10's).
    static var controlEdgeLight = 0
    /// The panel's exterior shadow (the trunk's, or idea 7's).
    static var shadowLayer = 0
    static func reset() { surfaceLayer = 0; rimLayer = 0; stageSurface = 0; controlEdgeLight = 0; shadowLayer = 0 }
}
#endif
#endif
