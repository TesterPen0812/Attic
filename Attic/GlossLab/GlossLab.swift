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
    /// 3, its own switch: the light runs all the way round the edge
    /// (a second run, brightest at the bottom), not only over the top.
    var edgeLightAround = false { didSet { save(edgeLightAround, "edgeLightAround") } }
    /// 6. Fine grain.
    var grain = false { didSet { save(grain, "grain") } }
    /// 10. One rim recipe for every control.
    var oneRim = false { didSet { save(oneRim, "oneRim") } }
    /// 2. Refracting rim: a band of Apple's Clear glass around the edge,
    /// regular glass inside. The Clear glass bends what lies behind it at
    /// the panel's edge, as the Clear body (12) does.
    var clearBand = false { didSet { save(clearBand, "clearBand") } }
    /// 7. A shadow that fits glass (in place of the trunk's elevation).
    var glassShadow = false { didSet { save(glassShadow, "glassShadow") } }
    /// 7, its own switch: a faint spill of light under the bottom edge.
    var glassSpill = false { didSet { save(glassSpill, "glassSpill") } }
    /// 9. Highlights that move: 3's Edge light, drawn by Core Animation and
    /// tilted a little towards the pointer once per display refresh.
    var movingLight = false { didSet { save(movingLight, "movingLight") } }
    /// 11. Neutral glass: what shows through the glass keeps its light and
    /// shade and loses its colour (a saturation blend over the glass, under
    /// our own fills). The panel and the island, native Glass only.
    var neutralGlass = false { didSet { save(neutralGlass, "neutralGlass") } }
    /// 11, its own switch: the glass controls drained the same way.
    var neutralControls = false { didSet { save(neutralControls, "neutralControls") } }
    /// 12. Clear glass body: the panel's own glass is Apple's Clear variant
    /// in place of Regular, with one plain fill over it. More of the
    /// backdrop's light and dark comes through. The panel and the island,
    /// native Glass only.
    var clearBody = false { didSet { save(clearBody, "clearBody") } }
    /// 13. Clear glass controls: the panel's glass controls wear Apple's
    /// Clear variant in place of Regular.
    var clearControls = false { didSet { save(clearControls, "clearControls") } }
    /// 14. Tiles (23 Nov, after the owner's Control Centre screenshot): on
    /// the Tasks page each group of rows wears its own piece of Apple's
    /// Clear glass with a dim under the text, and the panel behind them
    /// draws no glass of its own (glass cannot show through glass). The
    /// glass controls there wear the tiles' dim. Glass surface only; the
    /// other pages keep the panel as it is.
    var tiles = false { didSet { save(tiles, "tiles") } }
    /// 14, its own switch (23 Nov, second round): the panel's own glass,
    /// rim and shadow stay behind the tiles, as on a page without tiles,
    /// and each tile is a fill and an edge with no glass of its own (glass
    /// cannot show through glass).
    var tilesSheet = false { didSet { save(tilesSheet, "tilesSheet") } }
    /// 14, its own switch: in Light the tiles' dim is black (Smoke · Light),
    /// the glass controls on the tiles' page wear it too, and that page's
    /// text and symbols are drawn as in Dark. Dark is unchanged.
    var tilesSmoky = false { didSet { save(tilesSmoky, "tilesSmoky") } }

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
    /// 6: grain strength, percent (0 to 4).
    var grainPercent: Double = 1.5 { didSet { save(grainPercent, "grainPercent") } }
    /// 2: the band's width, pt (2 to 40): how far in from the edge the
    /// Clear glass, and so the bend, reaches. Apple's glass has no setting
    /// for how strongly it bends; the width is the one honest lever. Then
    /// how the two glasses are laid, and whether they share one container.
    var clearBandWidth: Double = 14 { didSet { save(clearBandWidth, "clearBandWidth") } }
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
    /// 9: how far the light's axis tilts towards the pointer, degrees (0 to
    /// 30), and how far its lit run reaches down or pulls up with the
    /// pointer, as a share of the height (0 to 0.2).
    var movingLightTilt: Double = 10 { didSet { save(movingLightTilt, "movingLightTilt") } }
    var movingLightReach: Double = 0.06 { didSet { save(movingLightReach, "movingLightReach") } }
    /// 11: how much colour is drained, % (0 to 100): the grey fill's opacity.
    var neutralGlassAmount: Double = 60 { didSet { save(neutralGlassAmount, "neutralGlassAmount") } }
    /// 12: the fill over the Clear glass, % (0 to 80): white in Light,
    /// black in Dark. The start is where the Air's stills come nearest
    /// the notification banners the owner showed (about half of the
    /// backdrop comes through); a guess for a first look, not a target.
    var clearBodyFillLight: Double = 15 { didSet { save(clearBodyFillLight, "clearBodyFillLight") } }
    var clearBodyFillDark: Double = 15 { didSet { save(clearBodyFillDark, "clearBodyFillDark") } }
    /// 14: the dim over each tile's Clear glass, % (0 to 80): white in
    /// Light, black in Dark. Apple's own guidance for Clear glass is a
    /// dimming layer under the content. The starts are where the Air's
    /// stills keep the text readable over a white and over a black
    /// backdrop in both modes (35 and 40 did not); a first look, no pick.
    var tilesDimLight: Double = 55 { didSet { save(tilesDimLight, "tilesDimLight") } }
    var tilesDimDark: Double = 50 { didSet { save(tilesDimDark, "tilesDimDark") } }
    /// 14: a tile's corner radius, pt (6 to 28), and the gap above a
    /// group's heading, pt (0 to 16).
    var tilesCorner: Double = 16 { didSet { save(tilesCorner, "tilesCorner") } }
    var tilesGap: Double = 8 { didSet { save(tilesGap, "tilesGap") } }
    /// 14: a plain fill on the panel behind the tiles, % (0 to 60): white
    /// in Light, black in Dark. No glass. 0 is no panel at all.
    var tilesPanelLight: Double = 0 { didSet { save(tilesPanelLight, "tilesPanelLight") } }
    var tilesPanelDark: Double = 0 { didSet { save(tilesPanelDark, "tilesPanelDark") } }
    /// 14: a soft shadow under each tile, cast only outside it (its
    /// opacity, 0 to 0.5). It keeps a tile's outline over a backdrop of
    /// the tile's own lightness, where Clear glass shows no edge.
    var tilesShadow: Double = 0.14 { didSet { save(tilesShadow, "tilesShadow") } }
    /// 14, Smoky in Light: the tiles' black dim in Light, % (0 to 60).
    var tilesSmokeLight: Double = 22 { didSet { save(tilesSmokeLight, "tilesSmokeLight") } }
    /// 14: the tile edge (0 to 1; 0 draws nothing): a 1 pt bright line on
    /// each tile's edge and, inside it, a lighter band fading over 3 pt.
    var tilesEdge: Double = 0.5 { didSet { save(tilesEdge, "tilesEdge") } }

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

    /// Material samples (23 Nov, owner: "do the sample cards side by side"):
    /// whether the sample cards' own window is shown, and the black veil on
    /// the cards that take one, % (0 to 60). The lab window's own state,
    /// like the backdrop: no preset, All off or Reset sliders touches them,
    /// and they are not part of `labLines`, so a preset still matches.
    var samplesShown = false { didSet { save(samplesShown, "samplesShown") } }
    var samplesSmoke: Double = 25 { didSet { save(samplesSmoke, "samplesSmoke") } }
    /// The second row of sample cards (23 Nov, owner on the first six, all
    /// dark with white text: "add a light option as well"): the same six
    /// materials drawn as in Light, with dark text and a white veil.
    var samplesLight = true { didSet { save(samplesLight, "samplesLight") } }
    /// The system's own variants in place of A to L (24 Nov, owner on the
    /// twelve cards beside the real Control Centre: "none of these loook
    /// even close"; then "Yes, try them"). Apple gives apps two glasses;
    /// AppKit's glass view also answers to a hidden variant number, which
    /// is what these cards set, with two more hidden settings on all of
    /// them: content lensing and scrim (0 to 3; 0 is the view's default).
    /// Unsupported: for looking in the lab, never for the panel.
    var samplesSystem = false { didSet { save(samplesSystem, "samplesSystem") } }
    var samplesLensing: Double = 0 { didSet { save(samplesLensing, "samplesLensing") } }
    var samplesScrim: Double = 0 { didSet { save(samplesScrim, "samplesScrim") } }
    /// The stack test (24 Nov, owner: "Yes, Opus builds"; brief
    /// `ops/design/gloss-lab-stack-brief-2026-11-24.md`): Control Centre's
    /// pieces as one stack, each part on its own control, in place of every
    /// card set. The pieces' hidden variant (0 to 23), the ground under them
    /// and its material and dim (0 to 30 %), the veil as the glass's tint,
    /// three more hidden settings and a subvariant (empty: not set), and
    /// whether the cards window may become the key window. The lab window's
    /// own state, like the other sample values. Unsupported settings: for
    /// looking in the lab, never for the panel.
    var samplesStack = false { didSet { save(samplesStack, "samplesStack") } }
    var samplesStackVariant: Double = 11 { didSet { save(samplesStackVariant, "samplesStackVariant") } }
    var samplesGround: StackGround = .off { didSet { save(samplesGround.rawValue, "samplesGround") } }
    var samplesGroundMaterial: StackGroundMaterial = .blur { didSet { save(samplesGroundMaterial.rawValue, "samplesGroundMaterial") } }
    var samplesGroundDim: Double = 8 { didSet { save(samplesGroundDim, "samplesGroundDim") } }
    var samplesStackTint = false { didSet { save(samplesStackTint, "samplesStackTint") } }
    var samplesSubdued: Double = 0 { didSet { save(samplesSubdued, "samplesSubdued") } }
    var samplesAdaptive: Double = 2 { didSet { save(samplesAdaptive, "samplesAdaptive") } }
    var samplesTintReduced = false { didSet { save(samplesTintReduced, "samplesTintReduced") } }
    var samplesSubvariant = "" { didSet { save(samplesSubvariant, "samplesSubvariant") } }
    var samplesStackKey = false { didSet { save(samplesStackKey, "samplesStackKey") } }
    /// Apple's blur, the fourth ground material (24 Nov, owner: "Lift it,
    /// Opus builds"; brief `ops/design/gloss-lab-ground-brief-2026-11-24.md`):
    /// its blur radius (0 to 40 pt, settable to 0.1 since 24 Nov) and how
    /// far beyond the pieces it reaches before the blur is gone (20 to 80
    /// pt). The lab window's own state.
    var samplesGroundRadius: Double = 20 { didSet { save(samplesGroundRadius, "samplesGroundRadius") } }
    var samplesGroundReach: Double = 60 { didSet { save(samplesGroundReach, "samplesGroundReach") } }
    /// Apple's blur's fade (24 Nov, owner: "Fix the fade"; brief
    /// `ops/design/gloss-lab-fade-brief-2026-11-24.md`): how far from the
    /// pieces the blur stays full (0 to 60 pt, kept 5 pt under the reach),
    /// the power the fall is raised to (1 to 4; 1 is the first round's
    /// smoothstep), and extra numeric inputs for the variable blur filter as
    /// `key=value` pairs (empty: none). The lab window's own state.
    var samplesGroundHold: Double = 25 { didSet { save(samplesGroundHold, "samplesGroundHold") } }
    var samplesGroundCurve: Double = GlossLab.groundCurveStart { didSet { save(samplesGroundCurve, "samplesGroundCurve") } }
    var samplesGroundExtras = "" { didSet { save(samplesGroundExtras, "samplesGroundExtras") } }
    /// The panel's blur behind (24 Nov, owner on the Control Centre preset:
    /// "add a switch that adds blur in the background to it. Blur and maybe
    /// a semi-transparent blur"): Apple's blur, uniform under the whole
    /// panel and under its glass; its strength (the filter's radius, 0 to
    /// 40, settable to 0.1); and how much of the sharp backdrop still shows
    /// through the blur, % (0 to 100: the blur layer's own opacity is the
    /// rest). Off to start with. The lab's own state for the panel: no
    /// preset, All off or Reset sliders touches them, and they are not part
    /// of `labLines`, so a preset still matches and a launch preset keeps
    /// them. Unsupported (a private layer): for looking in the lab.
    var panelBlur = false { didSet { save(panelBlur, "panelBlur") } }
    var panelBlurRadius: Double = GlossLab.panelBlurRadiusStart { didSet { save(panelBlurRadius, "panelBlurRadius") } }
    var panelBlurSeeThrough: Double = 0 { didSet { save(panelBlurSeeThrough, "panelBlurSeeThrough") } }
    /// The blur's starting strength: the lead's first value (24 Nov), kept
    /// until the measured match of the real Control Centre's ground is in.
    static let panelBlurRadiusStart: Double = 2
    /// The fade curve's starting value, chosen from the Air's measured
    /// series at curves 1 to 4 (fade start 25, reach 60): the smallest
    /// largest step between neighbouring 4 pt of the walk out to the rim,
    /// taken as the larger of text and texture, was 0.62, 0.48, 0.44, 0.48.
    /// Higher curves move the return to sharp inward; they do not widen it
    /// (report `ops/reviews/gloss-lab-fade-24nov.md`).
    static let groundCurveStart: Double = 3

    /// Where the stack test's blurred ground is: none, a view under the
    /// pieces in the cards window, or a window of its own under it.
    enum StackGround: String, CaseIterable, Identifiable {
        case off, same, below
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .same: "Same window"
            case .below: "Window below"
            }
        }
    }

    /// What the ground is made of: a public behind-window blur, Apple's
    /// Regular or Clear glass, or Apple's blur (Control Centre's own kind of
    /// ground: a private backdrop layer with a variable blur and a mask).
    enum StackGroundMaterial: String, CaseIterable, Identifiable {
        case blur, regular, clear, variable
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blur: "Blur"
            case .regular: "Regular glass"
            case .clear: "Clear glass"
            case .variable: "Apple's blur"
            }
        }
    }

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
        bool("edgeLightAround", &edgeLightAround); bool("grain", &grain)
        bool("oneRim", &oneRim)
        double("rimFadeWidth", &rimFadeWidth); double("edgeLightWidth", &edgeLightWidth)
        double("edgeLightLight", &edgeLightLight); double("edgeLightDark", &edgeLightDark)
        double("edgeLightShade", &edgeLightShade)
        double("innerEdgeInset", &innerEdgeInset); double("innerEdgeStrength", &innerEdgeStrength)
        double("grainPercent", &grainPercent)
        bool("clearBand", &clearBand); bool("glassShadow", &glassShadow); bool("glassSpill", &glassSpill)
        bool("clearBandContainer", &clearBandContainer)
        double("clearBandWidth", &clearBandWidth)
        double("shadowContactLight", &shadowContactLight); double("shadowContactDark", &shadowContactDark)
        double("shadowSoftLight", &shadowSoftLight); double("shadowSoftDark", &shadowSoftDark)
        double("shadowSoftRadius", &shadowSoftRadius); double("shadowSoftDrop", &shadowSoftDrop)
        double("spillStrength", &spillStrength)
        bool("movingLight", &movingLight)
        double("movingLightTilt", &movingLightTilt); double("movingLightReach", &movingLightReach)
        bool("neutralGlass", &neutralGlass); bool("neutralControls", &neutralControls)
        double("neutralGlassAmount", &neutralGlassAmount)
        bool("clearBody", &clearBody); bool("clearControls", &clearControls)
        double("clearBodyFillLight", &clearBodyFillLight); double("clearBodyFillDark", &clearBodyFillDark)
        bool("tiles", &tiles)
        double("tilesDimLight", &tilesDimLight); double("tilesDimDark", &tilesDimDark)
        double("tilesCorner", &tilesCorner); double("tilesGap", &tilesGap)
        double("tilesPanelLight", &tilesPanelLight); double("tilesPanelDark", &tilesPanelDark)
        double("tilesShadow", &tilesShadow)
        bool("tilesSheet", &tilesSheet); bool("tilesSmoky", &tilesSmoky)
        double("tilesSmokeLight", &tilesSmokeLight); double("tilesEdge", &tilesEdge)
        if let raw = defaults.string(forKey: Self.prefix + "clearBandMethod"), let value = ClearBandMethod(rawValue: raw) {
            clearBandMethod = value
        }
        if let raw = defaults.string(forKey: Self.prefix + "backdrop"), let value = Backdrop(rawValue: raw) { backdrop = value }
        bool("samplesShown", &samplesShown); double("samplesSmoke", &samplesSmoke)
        bool("samplesLight", &samplesLight); bool("samplesSystem", &samplesSystem)
        double("samplesLensing", &samplesLensing); double("samplesScrim", &samplesScrim)
        bool("samplesStack", &samplesStack); double("samplesStackVariant", &samplesStackVariant)
        if let raw = defaults.string(forKey: Self.prefix + "samplesGround"), let value = StackGround(rawValue: raw) { samplesGround = value }
        if let raw = defaults.string(forKey: Self.prefix + "samplesGroundMaterial"), let value = StackGroundMaterial(rawValue: raw) {
            samplesGroundMaterial = value
        }
        double("samplesGroundDim", &samplesGroundDim); bool("samplesStackTint", &samplesStackTint)
        double("samplesSubdued", &samplesSubdued); double("samplesAdaptive", &samplesAdaptive)
        bool("samplesTintReduced", &samplesTintReduced)
        if let value = defaults.string(forKey: Self.prefix + "samplesSubvariant") { samplesSubvariant = value }
        bool("samplesStackKey", &samplesStackKey)
        double("samplesGroundRadius", &samplesGroundRadius); double("samplesGroundReach", &samplesGroundReach)
        double("samplesGroundHold", &samplesGroundHold); double("samplesGroundCurve", &samplesGroundCurve)
        if let value = defaults.string(forKey: Self.prefix + "samplesGroundExtras") { samplesGroundExtras = value }
        bool("panelBlur", &panelBlur); double("panelBlurRadius", &panelBlurRadius)
        double("panelBlurSeeThrough", &panelBlurSeeThrough)
        // A launch argument (`-GlossLab.preset <id>`) shows a preset for
        // one run. Still loading, so nothing of it is saved.
        if let id = defaults.string(forKey: Self.prefix + "preset"), let preset = Self.presets.first(where: { $0.id == id }) {
            apply(preset)
        }
    }

    static let prefix = "GlossLab."

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        defaults?.set(value, forKey: Self.prefix + key)
    }

    // MARK: Presets and actions

    /// Every switch off: the trunk's look. Slider values are kept.
    func allOff() {
        rimFade = false; edgeLight = false; edgeLightAround = false; innerEdge = false; grain = false; oneRim = false
        clearBand = false; glassShadow = false; glassSpill = false; movingLight = false
        neutralGlass = false; neutralControls = false
        clearBody = false; clearControls = false
        tiles = false; tilesSheet = false; tilesSmoky = false
    }

    /// The sliders back to the lead's starting values.
    func resetSliders() {
        let fresh = GlossLab(defaults: nil)
        rimFadeWidth = fresh.rimFadeWidth
        edgeLightWidth = fresh.edgeLightWidth; edgeLightLight = fresh.edgeLightLight
        edgeLightDark = fresh.edgeLightDark; edgeLightShade = fresh.edgeLightShade
        innerEdgeInset = fresh.innerEdgeInset; innerEdgeStrength = fresh.innerEdgeStrength
        grainPercent = fresh.grainPercent
        clearBandWidth = fresh.clearBandWidth; clearBandMethod = fresh.clearBandMethod
        clearBandContainer = fresh.clearBandContainer
        shadowContactLight = fresh.shadowContactLight; shadowContactDark = fresh.shadowContactDark
        shadowSoftLight = fresh.shadowSoftLight; shadowSoftDark = fresh.shadowSoftDark
        shadowSoftRadius = fresh.shadowSoftRadius; shadowSoftDrop = fresh.shadowSoftDrop
        spillStrength = fresh.spillStrength
        movingLightTilt = fresh.movingLightTilt; movingLightReach = fresh.movingLightReach
        neutralGlassAmount = fresh.neutralGlassAmount
        clearBodyFillLight = fresh.clearBodyFillLight; clearBodyFillDark = fresh.clearBodyFillDark
        tilesDimLight = fresh.tilesDimLight; tilesDimDark = fresh.tilesDimDark
        tilesCorner = fresh.tilesCorner; tilesGap = fresh.tilesGap
        tilesPanelLight = fresh.tilesPanelLight; tilesPanelDark = fresh.tilesPanelDark
        tilesShadow = fresh.tilesShadow
        tilesSmokeLight = fresh.tilesSmokeLight; tilesEdge = fresh.tilesEdge
    }

    /// A named combination of switches and values. `dark` is the mode it is
    /// made for (the lab window sets it), or nil for either mode.
    struct Preset: Identifiable {
        let id: String
        let title: String
        let note: String
        var dark: Bool?
        let apply: @MainActor (GlossLab) -> Void
    }

    /// The lead's combinations, for a first look; none is a pick.
    static let presets: [Preset] = [
        Preset(id: "today", title: "Today's panel", note: "Everything off.") { _ in },
        Preset(id: "banner", title: "Banner",
               note: "Clear glass, a light fill, no colour from behind. Near the notification banners.") { lab in
            lab.clearBody = true; lab.clearBodyFillLight = 15; lab.clearBodyFillDark = 15
            lab.neutralGlass = true; lab.neutralGlassAmount = 60
        },
        // Retuned on 23 Nov (owner: it does not feel like the real one):
        // a dim under the text, as Apple asks of Clear glass, and none of
        // our drawn lines. The glass's own bent edge is the rim.
        Preset(id: "controlCentre", title: "Control Centre",
               note: "Clear glass with a dim under the text, clear controls, no drawn lines. Sets Dark.", dark: true) { lab in
            lab.clearBody = true; lab.clearBodyFillLight = 35; lab.clearBodyFillDark = 35
            lab.clearControls = true
            lab.glassShadow = true
        },
        // Second round, 23 Nov (owner: "these just dont feel the same"):
        // smoky pieces with a bright edge on the panel's own pale sheet,
        // fatter and further apart. The mode is the app's own.
        Preset(id: "controlCentreTiles", title: "Control Centre, tiles",
               note: "Smoky tiles with a bright edge on the panel's own glass; Tasks and the Notes list.") { lab in
            lab.tiles = true; lab.tilesSheet = true; lab.tilesSmoky = true
            lab.tilesDimLight = 55; lab.tilesDimDark = 50
            lab.tilesCorner = 22; lab.tilesGap = 10; lab.tilesEdge = 0.5
            lab.clearControls = true
        },
        Preset(id: "clearBareEdge", title: "Clear, bare edge",
               note: "Clear glass with more fill under the text, bare at the rim where it bends.") { lab in
            lab.clearBody = true; lab.clearBodyFillLight = 30; lab.clearBodyFillDark = 30
            lab.rimFade = true; lab.rimFadeWidth = 12
            lab.neutralGlass = true; lab.neutralGlassAmount = 40
            lab.glassShadow = true
        },
        Preset(id: "refractingRim", title: "Refracting rim",
               note: "Today's glass with a clear rim that bends what is behind it.") { lab in
            // Owner, 23 Nov ("Yes, 6 pt"): it starts at 6 pt, not 16.
            lab.clearBand = true; lab.clearBandWidth = 6
            lab.rimFade = true; lab.rimFadeWidth = 6
            lab.edgeLight = true
        },
        Preset(id: "thickGlass", title: "Thick glass",
               note: "A clear rim, light all round the edge, a second inner line, a glass shadow.") { lab in
            lab.clearBand = true; lab.clearBandWidth = 10
            lab.rimFade = true; lab.rimFadeWidth = 10
            lab.edgeLight = true; lab.edgeLightAround = true
            lab.innerEdge = true; lab.innerEdgeInset = 3.5
            lab.glassShadow = true; lab.glassSpill = true
        },
        Preset(id: "neutralGrain", title: "Neutral, fine grain",
               note: "Today's glass without the colour from behind, fine grain, a glass shadow.") { lab in
            lab.neutralGlass = true; lab.neutralGlassAmount = 80
            lab.grain = true; lab.grainPercent = 1.5
            lab.glassShadow = true
        },
        Preset(id: "livingLight", title: "Living light",
               note: "The edge light leans towards the pointer; every control is lit the same way.") { lab in
            lab.edgeLight = true; lab.movingLight = true
            lab.oneRim = true
            lab.glassShadow = true
        },
    ]

    /// A preset sets every switch and every slider: all off, the sliders
    /// back to their starts, then its own. The mode is the app's own
    /// setting; the caller sets it.
    func apply(_ preset: Preset) {
        allOff()
        resetSliders()
        preset.apply(self)
    }

    /// The preset the lab's switches and sliders match now, or nil.
    var currentPreset: Preset? {
        let now = labLines
        return Self.presets.first { Self.lines(of: $0) == now }
    }

    private static var presetLines: [String: String] = [:]

    private static func lines(of preset: Preset) -> String {
        if let known = presetLines[preset.id] { return known }
        let lab = GlossLab(defaults: nil)
        lab.apply(preset)
        let lines = lab.labLines
        presetLines[preset.id] = lines
        return lines
    }

    /// The app's own glass settings, as the lab writes them down: with
    /// them, a pick can be rebuilt from the copied text alone.
    struct AppValues {
        var mode: String
        var surface: String
        var palette: String
        var tint: String
        /// The Tint's reach down the panel, 0 to 1.
        var tintLength: Double
        var brightenGlass: Bool
    }

    /// The current switches and values as text, for "Copy values".
    func valuesText(app: AppValues) -> String {
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        return """
        Attic Gloss lab values
        Mode: \(app.mode)
        Surface: \(app.surface)
        Palette: \(app.palette)
        Tint: \(app.tint), length \(Int((app.tintLength * 100).rounded())) %
        Brighten glass: \(on(app.brightenGlass))
        Backdrop: \(backdrop.title)
        Material samples: \(on(samplesShown)), veil \(Int(samplesSmoke.rounded())) %, light row \(on(samplesLight)), system variants \(on(samplesSystem)) (lensing \(Int(samplesLensing.rounded())), scrim \(Int(samplesScrim.rounded())))
        \(stackLine)
        \(fadeLine)
        \(panelBlurLine)
        Preset: \(currentPreset?.title ?? "none (own values)")
        \(labLines)
        """
    }

    /// The stack test's values as one line, for "Copy values".
    var stackLine: String {
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        func n(_ value: Double) -> Int { Int(value.rounded()) }
        let subvariant = samplesSubvariant.isEmpty ? "not set" : "\"\(samplesSubvariant)\""
        return "Stack test: \(on(samplesStack)), variant \(n(samplesStackVariant)), ground \(samplesGround.title.lowercased()) "
            + "(\(samplesGroundMaterial.title.lowercased()), dim \(n(samplesGroundDim)) %), smoke \(n(samplesSmoke)) % "
            + "as \(samplesStackTint ? "the glass's tint" : "a veil"), lensing \(n(samplesLensing)), scrim \(n(samplesScrim)), "
            + "subdued \(n(samplesSubdued)), adaptive \(n(samplesAdaptive)), reduced tint opacity \(on(samplesTintReduced)), "
            + "subvariant \(subvariant), key window \(on(samplesStackKey)), "
            + "Apple's blur radius \(Self.fine(samplesGroundRadius)) pt, reach \(n(samplesGroundReach)) pt"
    }

    /// Apple's blur's fade as one line, for "Copy values" (its own line, so
    /// the stack line reads as before).
    var fadeLine: String {
        let extras = samplesGroundExtras.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Apple's blur fade: start \(Int(samplesGroundHold.rounded())) pt, curve \(String(format: "%.1f", samplesGroundCurve)), "
            + "extras \(extras.isEmpty ? "none" : "\"\(extras)\"")"
    }

    /// The panel's blur behind as one line, for "Copy values".
    var panelBlurLine: String {
        "Panel blur behind: \(panelBlur ? "on" : "off"), strength \(Self.fine(panelBlurRadius)), "
            + "see-through \(Int(panelBlurSeeThrough.rounded())) %"
    }

    /// A value settable to 0.1 as text: whole numbers plain, else one decimal.
    static func fine(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// The lab's own switches and sliders as text, numbered as in the
    /// brief (5, Light from the top, was removed on 23 Nov; 8 was not built).
    var labLines: String {
        func f(_ value: Double) -> String { String(format: "%.2f", value) }
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        return """
        1 Bare glass at the rim: \(on(rimFade)), width \(f(rimFadeWidth)) pt
        2 Refracting rim (a band of Clear glass): \(on(clearBand)), width \(f(clearBandWidth)) pt, \(clearBandMethod.title), one container: \(on(clearBandContainer))
        3 Edge light on the panel: \(on(edgeLight)), width \(f(edgeLightWidth)) pt, Light \(f(edgeLightLight)), Dark \(f(edgeLightDark)), bottom line \(f(edgeLightShade)), all the way round: \(on(edgeLightAround))
        4 A second inner edge: \(on(innerEdge)), inset \(f(innerEdgeInset)) pt, strength \(f(innerEdgeStrength))
        6 Fine grain: \(on(grain)), \(f(grainPercent)) %
        7 A shadow that fits glass: \(on(glassShadow)), contact Light \(f(shadowContactLight)) Dark \(f(shadowContactDark)), soft Light \(f(shadowSoftLight)) Dark \(f(shadowSoftDark)), radius \(f(shadowSoftRadius)) pt, drop \(f(shadowSoftDrop)) pt
        7 Spill of light under the bottom edge: \(on(glassSpill)), \(f(spillStrength))
        9 Highlights that move: \(on(movingLight)), tilt \(f(movingLightTilt)) deg, reach \(f(movingLightReach)) (draws 3's light with 3's values)
        11 Neutral glass: \(on(neutralGlass)), amount \(f(neutralGlassAmount)) %, controls too: \(on(neutralControls))
        12 Clear glass body: \(on(clearBody)), Light white fill \(f(clearBodyFillLight)) %, Dark black fill \(f(clearBodyFillDark)) %
        13 Clear glass controls: \(on(clearControls))
        14 Tiles (each group of tasks on its own Clear glass): \(on(tiles)), dim Light \(f(tilesDimLight)) % Dark \(f(tilesDimDark)) %, corner \(f(tilesCorner)) pt, gap \(f(tilesGap)) pt, panel behind Light \(f(tilesPanelLight)) % Dark \(f(tilesPanelDark)) %, shadow \(f(tilesShadow)), sheet behind: \(on(tilesSheet)), smoky in Light: \(on(tilesSmoky)), smoke Light \(f(tilesSmokeLight)) %, edge \(f(tilesEdge))
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
    /// 9, which runs no SwiftUI body per pointer move: display refreshes
    /// seen, gradient writes made, mask paths built, and the representable's
    /// updates (SwiftUI-driven, never per pointer move).
    static var movingTicks = 0
    static var movingWrites = 0
    static var movingPathBuilds = 0
    static var movingUpdates = 0
    /// 14: the tiles' own layer behind a list.
    static var tilesLayer = 0
    static func reset() {
        surfaceLayer = 0; rimLayer = 0; stageSurface = 0; controlEdgeLight = 0; shadowLayer = 0
        tilesLayer = 0
        movingTicks = 0; movingWrites = 0; movingPathBuilds = 0; movingUpdates = 0
    }
}
#endif
#endif
