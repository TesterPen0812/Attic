import Foundation
import SwiftUI

/// A colour role. Components ask for a role, never a hex value; the
/// appearance check knows each role's contrast floor.
enum AtticInk: String, CaseIterable, Sendable {
    // Text ladder (spec § Colour: never pure black or white). `helper` is
    // the secondary grey (dates, counts, hints, done rows); `muted` the
    // quietest (inactive status tabs), as in the approved v4 mockup.
    case heading, body, label, helper, muted, placeholder
    // Text on the Settings chrome (sidebar).
    case chromeHeading, chromeBody, chromeHint
    // Icons are lighter than text; glyphs inside controls are the primary colour.
    case icon, chromeIcon, glyph, chevron
    // Meaning.
    case accent, accentText, dueText, warningText
    case priorityNone, priorityLow, priorityMedium, priorityHigh
    case doneFill, onDone
    /// The one near-black (Light) / near-white (Dark) primary fill: the send
    /// button and the drag-stack count. Near-black is never used for chips.
    case inverseFill, onInverse
    /// Disabled controls are a ghost (a faint rim, a light glyph), but
    /// nothing is exempt from the readability rule: disabled text is
    /// secondary text (3 : 1; 4.5 : 1 under Increase Contrast), and
    /// disabled icons keep the icons' 3 : 1.
    case disabledText, disabledIcon

    enum Floor: Equatable, Sendable {
        /// Text: 4.5 : 1 for text that matters, 3 : 1 for secondary text
        /// (`isSecondaryText`), 4.5 : 1 for all text under Increase Contrast.
        case text
        /// 3 : 1 for icons, rings, circles and other non-text UI.
        case nonText

        var ratio: Double {
            switch self {
            case .text: 4.5
            case .nonText: 3.0
            }
        }
    }

    var floor: Floor {
        switch self {
        case .heading, .body, .label, .helper, .muted, .placeholder,
             .chromeHeading, .chromeBody, .chromeHint,
             .accentText, .dueText, .warningText, .onInverse, .disabledText:
            .text
        case .icon, .chromeIcon, .glyph, .chevron, .accent,
             .priorityNone, .priorityLow, .priorityMedium, .priorityHigh,
             .doneFill, .onDone, .inverseFill, .disabledIcon:
            .nonText
        }
    }

    /// Secondary text (spec rev 175): inactive tabs, counts, non-urgent
    /// dates, placeholders, hints, helper text, done rows, tags in a
    /// details line, disabled text. It stays soft, as in v4, at 3 : 1 at
    /// least; everything else that is text (titles, body, labels, today and
    /// overdue, errors, the main action) keeps 4.5 : 1. Under Increase
    /// Contrast every text keeps 4.5 : 1.
    var isSecondaryText: Bool {
        switch self {
        case .helper, .muted, .placeholder, .chromeHint, .disabledText, .accentText: true
        default: false
        }
    }
}

/// What raised controls are made of (the gallery's "Controls" switch).
/// Liquid Glass is the default in Light and Dark; the Craft style is the
/// drawn recipe matched to Craft's controls, and what Reduce Transparency
/// always gets.
enum AtticControlMaterial: String, CaseIterable, Hashable, Sendable {
    case liquidGlass
    case craft

    var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .craft: "Craft style"
        }
    }
}

/// A drawn raised material: the Craft-style recipe (opaque, over the neutral
/// control base) or, in captures, the stand-in for Liquid Glass (a
/// translucent fill over whatever is behind, as the glass takes the
/// surface's colour). Drawn bottom to top: shadow outside the shape, base,
/// fill, a vertical sheen, a 1 pt inner rim, and the edge.
struct AtticRaisedRecipe: Equatable, Sendable {
    /// The opaque base, or nil when the fill is laid over what is behind.
    var base: AtticRGBA?
    /// The face in the middle of the control, where its label sits.
    var fill: AtticRGBA
    /// Sheen overlays at the top and bottom, fading out over `sheenReach`
    /// of the height (never over the middle, where the label sits).
    var sheenTop: AtticRGBA = .clear
    var sheenBottom: AtticRGBA = .clear
    var sheenReach: Double = 0.35
    /// 1 pt rim just inside the edge: top, sides and bottom.
    var innerRimTop: AtticRGBA = .clear
    var innerRimMiddle: AtticRGBA = .clear
    var innerRimBottom: AtticRGBA = .clear
    /// The edge: top, sides and bottom of a vertical gradient.
    var edgeTop: AtticRGBA
    var edgeMiddle: AtticRGBA
    var edgeBottom: AtticRGBA
    var edgeWidth: CGFloat = 1
    var shadow: AtticRGBA = .clear
    var shadowRadius: CGFloat = 0.5
    var shadowY: CGFloat = 0.5

    /// The face (fill over base): opaque for the Craft style, an overlay
    /// on the surface for the glass stand-in.
    var face: AtticRGBA { base.map { fill.over($0) } ?? fill }
}

/// What real Liquid Glass (`.regular`, macOS 26, key window) does to the
/// surface it sits on, measured with the gallery's `--glass-lab` on every
/// flat colour the panel can draw under a control (the neutral ladder and
/// each palette's surface over the black, mid-grey and white desktops, with
/// and without the Bold tint at its strongest), sampled in the middle of
/// the control where its label sits (2026-09-25):
///
/// - **Light:** the face follows the surface, a little darker on near-white
///   (#FAFAFA → 246–251, #FFFFFF → 248–254) and lighter on greyer surfaces
///   (#C8C8C8 → 218–223): per channel about 0.55 × surface + 108. The
///   darkest face measured on every swatch is at or above
///   `worstFace(dark: false).over(surface)` (0.54 × surface + 0.46 × 236).
/// - **Dark:** a white veil of 0.12–0.15 over the surface (#2C2C2D →
///   71–74, +28); `worstFace(dark: true)` is white at 0.16.
///
/// The worst face is what the label's contrast must survive: the darkest
/// in Light (dark text), the lightest in Dark (light text). On all 206
/// swatches the model is no kinder to the label than the real glass (in
/// relative luminance, which is what contrast reads), so a label that
/// passes on the worst face passes on the real glass. The inks are tuned
/// against it over every surface, and captures (which cannot render glass)
/// draw a stand-in whose middle is exactly that worst face.
enum AtticGlassModel {
    static func worstFace(dark: Bool) -> AtticRGBA {
        dark ? .white(0.16) : AtticRGBA.grey(236).withAlpha(0.46)
    }

    /// The capture stand-in: the worst face in the middle, and the measured
    /// shape of the glass around it. Light: a white band inside the top and
    /// bottom edges and a fine grey edge, darkest on the sides (sides
    /// about −59, top −20, bottom −23 on #FAFAFA) with a faint shadow
    /// below. Dark: a bright rim at the top and bottom (about +60 over the
    /// face) fading along the sides, which end in a fine dark edge.
    static func standIn(dark: Bool, increaseContrast: Bool) -> AtticRaisedRecipe {
        if dark {
            return AtticRaisedRecipe(
                base: nil, fill: worstFace(dark: true),
                sheenTop: .white(0.05), sheenBottom: .white(0.05), sheenReach: 0.25,
                edgeTop: .white(increaseContrast ? 0.45 : 0.33),
                edgeMiddle: increaseContrast ? .white(0.35) : .black(0.30),
                edgeBottom: .white(increaseContrast ? 0.45 : 0.33),
                edgeWidth: 1
            )
        }
        return AtticRaisedRecipe(
            base: nil, fill: worstFace(dark: false),
            sheenTop: .white(0.7), sheenBottom: .white(0.6), sheenReach: 0.35,
            innerRimTop: .white(0.95), innerRimBottom: .white(0.9),
            edgeTop: .black(increaseContrast ? 0.30 : 0.08),
            edgeMiddle: .black(increaseContrast ? 0.34 : 0.22),
            edgeBottom: .black(increaseContrast ? 0.36 : 0.09),
            edgeWidth: increaseContrast ? 1 : 0.5,
            shadow: .black(0.05), shadowRadius: 3, shadowY: 1
        )
    }

    /// A disabled glass control's ghost fill: the glass is taken back
    /// towards the surface (lighter in Light, darker in Dark), so its label
    /// can stay as quiet as the helper grey and still keep 3 : 1.
    static func disabledFill(dark: Bool) -> AtticRGBA {
        dark ? .black(0.12) : .white(0.35)
    }

    /// Increase Contrast: a stronger edge drawn over the system's own glass
    /// (the same strength as the Craft style's contrast edge).
    static func contrastEdge(dark: Bool) -> AtticRGBA {
        dark ? .white(0.35) : .black(0.30)
    }
}

/// Every resolved colour for one `AtticDesignContext`.
struct AtticColorTokens: Equatable, Sendable {
    let context: AtticDesignContext.ColourKey

    // MARK: Surfaces (backgrounds: the only layer customisation changes)

    /// The panel's model: base colour, foundation over the desktop and Tint.
    let panel: AtticSurfaceModel
    /// Settings chrome and sidebar (translucent, desaturated).
    let chrome: AtticSurfaceModel

    // MARK: Cards (base style, never customised)

    let contentCard: AtticRGBA
    let contentCardRim: AtticRGBA
    let groupCard: AtticRGBA
    /// Group cards get a 1 pt border only under Increase Contrast.
    let groupCardBorder: AtticRGBA?
    let divider: AtticRGBA
    /// Things inside content (task cards, tiles, tag fills) are recessed:
    /// a flat overlay on the surface, no border.
    let recessed: AtticRGBA
    let recessedBorder: AtticRGBA?

    // MARK: States (same shapes everywhere; hover lighter than selected)

    let hover: AtticRGBA
    let selected: AtticRGBA
    let pressed: AtticRGBA
    /// The selected chip inside a capsule: pressed-in grey (Light), lighter (Dark).
    let chipSelected: AtticRGBA
    let chipHover: AtticRGBA
    let skeleton: AtticRGBA

    // MARK: Materials

    /// The opaque neutral base the Craft-style controls are drawn on, so
    /// content never shows through a floating control and the drawn
    /// controls never pick up a palette. (Liquid Glass takes the colour of
    /// whatever is behind it; see `AtticGlassModel`.)
    let controlBase: AtticRGBA
    /// The Craft-style recipe (Reduce Transparency, or the Craft switch).
    let raised: AtticRaisedRecipe
    let raisedHover: AtticRaisedRecipe
    let raisedPressed: AtticRaisedRecipe
    let raisedDisabled: AtticRaisedRecipe
    /// The capture stand-in for Liquid Glass.
    let glassStandIn: AtticRaisedRecipe
    /// The worst face Liquid Glass leaves over a surface (an overlay).
    let glassFace: AtticRGBA
    /// A disabled glass control's ghost: a fill that takes the glass back
    /// towards the surface.
    let glassDisabled: AtticRGBA
    /// A pressed glass control (the system's interactive glass adds its
    /// own press response live).
    let glassPressed: AtticRGBA
    /// Menus, pop-overs, toasts and the selection bar: raised over content.
    let popoverFill: AtticRGBA
    let popoverInnerRim: AtticRGBA
    let popoverOuterRim: AtticRGBA
    let popoverShadow: AtticRGBA
    let dragShadow: AtticRGBA

    // MARK: Inks

    let inks: [AtticInk: AtticRGBA]

    func ink(_ ink: AtticInk) -> AtticRGBA { inks[ink] ?? .black(1) }

    /// The Craft-style control face (opaque).
    var controlFace: AtticRGBA { raised.face.over(controlBase) }

    /// Every face a control's label can sit on over `surface`: the Craft
    /// style's, and the worst Liquid Glass leaves on that surface.
    func controlFaces(over surface: AtticRGBA) -> [AtticRGBA] {
        [controlFace, glassFace.over(surface)]
    }
    func color(_ ink: AtticInk) -> Color { self.ink(ink).color }

    var focusRing: AtticRGBA { ink(.accent) }
    var tagFill: AtticRGBA { ink(.accent).withAlpha(context.mode == .dark ? 0.16 : 0.10) }
    var tagFillSelected: AtticRGBA { ink(.accent).withAlpha(context.mode == .dark ? 0.26 : 0.18) }

    func priority(_ priority: AtticPriority) -> AtticRGBA {
        switch priority {
        case .none: ink(.priorityNone)
        case .low: ink(.priorityLow)
        case .medium: ink(.priorityMedium)
        case .high: ink(.priorityHigh)
        }
    }

    // MARK: Resolution

    static func resolve(_ context: AtticDesignContext) -> AtticColorTokens {
        AtticColorTokenCache.shared.tokens(for: context.colourKey)
    }

    static func build(_ key: AtticDesignContext.ColourKey) -> AtticColorTokens {
        let dark = key.mode == .dark
        let ic = key.increaseContrast
        let appearance = key.mode.themeAppearance
        let themePalette = key.palette.palette(for: appearance)

        // Base neutrals (spec § Default and Dark ladder). The Dark chrome is
        // #505050, not the spec's #5B5B5B: see `Ladder.darkChrome`.
        let basePanel = dark ? AtticRGBA(0x2C2C2D) : AtticRGBA(0xFAFAFA)
        let baseChrome = dark ? Ladder.darkChrome : AtticRGBA(0xF3F3F3)
        let panelBase = AtticSurfaceModel.hued(basePanel, palette: key.palette, themePalette: themePalette, dark: dark)
        let chromeBase = AtticSurfaceModel.hued(baseChrome, palette: key.palette, themePalette: themePalette, dark: dark, chrome: true)

        let hover: AtticRGBA = dark ? .white(ic ? 0.08 : 0.04) : .black(ic ? 0.07 : 0.035)
        let selected: AtticRGBA = dark ? .white(ic ? 0.14 : 0.07) : .black(ic ? 0.12 : 0.06)
        let pressed: AtticRGBA = dark ? .white(ic ? 0.18 : 0.10) : .black(ic ? 0.16 : 0.085)
        let chipSelected: AtticRGBA = dark ? .white(ic ? 0.16 : 0.08) : .black(ic ? 0.12 : 0.06)
        let chipHover: AtticRGBA = dark ? .white(0.04) : .black(0.03)
        let recessed: AtticRGBA = dark ? .white(ic ? 0.09 : 0.055) : .black(ic ? 0.07 : 0.045)

        let recipes = Self.recipes(dark: dark, ic: ic, base: basePanel)
        let glassFace = AtticGlassModel.worstFace(dark: dark)
        let glassDisabled = AtticGlassModel.disabledFill(dark: dark)
        // Lighter than the selected chip in Light: the outline icons on a
        // pressed glass button render thin, and glass over a tinted Light
        // surface is already the darkest face they sit on.
        let glassPressed: AtticRGBA = dark ? chipSelected : .black(ic ? 0.10 : 0.045)

        let popoverFill = dark ? AtticRGBA(0x363637) : AtticRGBA(0xFEFEFE)
        let contentCard = dark ? AtticRGBA(0x2E2E2E) : AtticRGBA(0xFBFBFB)
        let groupCard = dark ? AtticRGBA(0x333333) : AtticRGBA(0xF2F2F2)

        /// The backgrounds each role is actually drawn on, over a surface.
        /// Tuning a role against backgrounds it never sits on would flatten
        /// the ladder (helper would climb to the label's grey).
        func backgrounds(for ink: AtticInk, on surface: AtticRGBA) -> [AtticRGBA] {
            // A control's label sits on the Craft-style face or on Liquid
            // Glass over the surface, whichever the controls are.
            let faces = [recipes.rest.face.over(basePanel), glassFace.over(surface)]
            // A disabled control: the Craft style's ghost is judged on its
            // rest face (the harder of the two), glass on its ghost fill.
            let ghostFaces = [recipes.rest.face.over(basePanel), glassDisabled.over(glassFace.over(surface))]
            let card = recessed.over(surface)
            let rows = [surface, hover.over(surface), selected.over(surface), pressed.over(surface), card, hover.over(card)]
            let menus = [popoverFill, selected.over(popoverFill), pressed.over(popoverFill), chipHover.over(popoverFill)]
            let settings = [contentCard, recessed.over(contentCard), groupCard, hover.over(groupCard), selected.over(groupCard)]
            switch ink {
            case .heading, .glyph:
                // Labels and glyphs on controls, their hover and press,
                // and the selected chip.
                return rows + menus + settings + faces.flatMap { [$0, chipHover.over($0), chipSelected.over($0)] }
            case .body:
                // Typed text in the add bar, the selection bar's count.
                return rows + menus + settings + faces
            case .label:
                // Grouped-row labels and quick-look actions.
                return rows + settings
            case .helper:
                // Row meta, done rows, hints, Settings helper, and menu
                // shortcuts on the highlighted row.
                return rows + settings + [popoverFill, selected.over(popoverFill)]
            case .muted:
                // Inactive status tabs: on the surface, and under a drop
                // target's hover fill (hover itself turns them to body).
                return [surface, hover.over(surface)]
            case .placeholder:
                // The add bar's field, and the surface.
                return faces + [surface]
            case .icon, .chevron:
                return rows + menus + faces.flatMap { [$0, chipHover.over($0), chipSelected.over($0)] }
            case .disabledText, .disabledIcon:
                // Disabled rows, menu rows, and the ghost of a raised control.
                // A disabled control shows no hover or press.
                return [surface, card, popoverFill, contentCard, groupCard] + ghostFaces
            default:
                return rows + menus + settings
            }
        }
        // Safety margins over the floors, so 8-bit rendering and the blur
        // of the rendered glass never round a pass into a miss.
        let textTarget = 4.66
        let nonTextTarget = 3.12
        let secondaryTarget = 3.11
        /// Each text role's target: secondary text 3 : 1 (4.5 : 1 under
        /// Increase Contrast), every other text 4.5 : 1, with the margins.
        func target(_ ink: AtticInk) -> Double {
            ink.isSecondaryText && !ic ? secondaryTarget : textTarget
        }

        // The text ladder and the neutral icons are tuned once per mode and
        // contrast setting, on the neutral base: text always stays in the
        // base style. Palette surfaces keep the neutral base's luminance
        // (`AtticSurfaceModel.hued`), so the same text passes on them.
        var inks = Ladder.neutral(dark: dark, ic: ic)
        for ink in [AtticInk.helper, .muted, .label, .placeholder, .body, .heading] {
            inks[ink] = inks[ink]!.tuned(toContrast: target(ink), against: backgrounds(for: ink, on: basePanel), lighten: dark)
        }
        for ink in [AtticInk.icon, .chevron, .glyph, .disabledIcon] {
            inks[ink] = inks[ink]!.tuned(toContrast: nonTextTarget, against: backgrounds(for: ink, on: basePanel), lighten: dark)
        }
        // Disabled text sits at the text floor, and never louder than the
        // helper grey: it is the quiet end of the ladder.
        inks[.disabledText] = inks[.disabledText]!.tuned(toContrast: target(.disabledText), against: backgrounds(for: .disabledText, on: basePanel), lighten: dark)
        if inks[.disabledText]!.contrast(on: basePanel) > inks[.helper]!.contrast(on: basePanel) {
            inks[.disabledText] = inks[.helper]!
        }
        // Keep the ladder in order: a label is never quieter than helper text.
        let helperOnBase = inks[.helper]!.contrast(on: basePanel)
        if inks[.label]!.contrast(on: basePanel) < helperOnBase * 1.06 {
            inks[.label] = inks[.helper]!.tuned(toContrast: helperOnBase * 1.06, against: [basePanel], lighten: dark)
        }
        inks[.priorityNone] = inks[.icon]!
        let chromeBackgrounds = [baseChrome, selected.over(baseChrome), hover.over(baseChrome)]
        for ink in [AtticInk.chromeHeading, .chromeBody, .chromeHint] {
            inks[ink] = inks[ink]!.tuned(toContrast: target(ink), against: chromeBackgrounds, lighten: dark)
        }
        inks[.chromeIcon] = inks[.chromeIcon]!.tuned(toContrast: nonTextTarget, against: chromeBackgrounds, lighten: dark)

        // Colours of meaning are tuned per palette and mode (spec § Colour).
        let accentBase: AtticRGBA = key.palette == .original
            ? (dark ? AtticRGBA(0x9FA0A7) : AtticRGBA(0x8A8A8F))
            : AtticRGBA(themePalette.accent)
        let meaning = backgrounds(for: .accent, on: panelBase)
        inks[.accent] = accentBase.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        let tagFill = inks[.accent]!.withAlpha(dark ? 0.16 : 0.10)
        let tagFillSelected = inks[.accent]!.withAlpha(dark ? 0.26 : 0.18)
        let tagBackgrounds = [panelBase, recessed.over(panelBase), contentCard].flatMap { base in
            [tagFill.over(base), tagFillSelected.over(base), hover.over(tagFill.over(base))]
        }
        inks[.accentText] = (key.palette == .original ? inks[.helper]! : accentBase)
            .tuned(toContrast: target(.accentText), against: meaning + tagBackgrounds, lighten: dark)
        let pri = Ladder.priorityHues(dark: dark)
        inks[.priorityHigh] = pri.high.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.priorityMedium] = pri.medium.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.priorityLow] = pri.low.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.dueText] = pri.high.tuned(toContrast: textTarget, against: meaning, lighten: dark)
        inks[.warningText] = (dark ? AtticRGBA(0xFFB35C) : AtticRGBA(0xC2570C)).tuned(toContrast: textTarget, against: meaning, lighten: dark)
        // Done is faded as in v4 (#C9CBCE / a dim fill), held at 3 : 1.
        inks[.doneFill] = (dark ? AtticRGBA(0x6E6F72) : AtticRGBA(0xC9CBCE)).tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.onDone] = dark ? AtticRGBA(0x1E1E1F) : AtticRGBA(0xFFFFFF)
        // The check mark keeps 3 : 1 on the fills it is drawn on (the done
        // fill, and the disabled icon colour on a disabled row): a fill that
        // would leave it fainter steps away from the check.
        for fill in [AtticInk.doneFill, .disabledIcon] {
            inks[fill] = inks[fill]!.tuned(toContrast: nonTextTarget, against: [inks[.onDone]!], lighten: dark)
        }

        func panelPairs() -> [AtticSurfaceModel.Pair] {
            // Tag fills follow the accent as it is now (it may be retuned).
            AtticSurfaceModel.readabilityPairs(
                inks: inks, hover: hover, selected: selected, pressed: pressed,
                controlFace: recipes.rest.face.over(basePanel), glassFace: glassFace, glassDisabled: glassDisabled, glassPressed: glassPressed,
                chipSelected: chipSelected, chipHover: chipHover,
                recessed: recessed,
                tagFill: inks[.accent]!.withAlpha(dark ? 0.16 : 0.10),
                tagFillSelected: inks[.accent]!.withAlpha(dark ? 0.26 : 0.18)
            )
        }
        /// The pairs that set the PR #5 Glass and Frosted coverage: every
        /// pair as the PR #5 look was measured, with the secondary roles in
        /// the greys they had then (4.5 : 1 on the base), so softening the
        /// secondary text never changes how see-through the surfaces are.
        var legacy: [AtticInk: AtticRGBA] = [:]
        legacy[.helper] = Ladder.legacyHelper(dark: dark).tuned(toContrast: textTarget, against: backgrounds(for: .helper, on: basePanel), lighten: dark)
        legacy[.placeholder] = Ladder.legacyPlaceholder(dark: dark).tuned(toContrast: textTarget, against: [recipes.rest.face.over(basePanel)], lighten: dark)
        legacy[.chromeHint] = Ladder.legacyChromeHint(dark: dark).tuned(toContrast: textTarget, against: chromeBackgrounds, lighten: dark)
        // Disabled text never set the look (PR #5 predates it), so it has
        // no legacy grey and plays no part in the coverage.
        legacy[.accentText] = (key.palette == .original ? legacy[.helper]! : accentBase)
            .tuned(toContrast: textTarget, against: meaning + tagBackgrounds, lighten: dark)
        func coveragePairs(_ pairs: [AtticSurfaceModel.Pair]) -> [AtticSurfaceModel.Pair] {
            // Labels on Liquid Glass are kept readable by their inks (tuned
            // against the worst glass face), never by making the surface
            // less see-through: the coverage stays the PR #5 look.
            let pairs = pairs.filter { !$0.onGlass }
            guard !ic else { return pairs }
            return pairs.compactMap { pair in
                guard pair.ink.isSecondaryText else { return pair }
                guard let old = legacy[pair.ink] else { return nil }
                return .init(ink: .body, foreground: old, overlays: pair.overlays, onGlass: pair.onGlass)
            }
        }

        func chromePairs() -> [AtticSurfaceModel.Pair] {
            [
                .init(ink: .chromeHeading, foreground: inks[.chromeHeading]!, overlays: []),
                .init(ink: .chromeBody, foreground: inks[.chromeBody]!, overlays: [selected]),
                .init(ink: .chromeHint, foreground: inks[.chromeHint]!, overlays: []),
                .init(ink: .chromeIcon, foreground: inks[.chromeIcon]!, overlays: [selected])
            ]
        }

        // The surfaces: the PR #5 coverage (set by the base ladder) and the
        // designed tint. The chrome is a sidebar material, modelled as
        // Frosted when the panel is translucent, and never tinted.
        let panel = AtticSurfaceModel.solve(
            base: panelBase, kind: key.surface, appearance: appearance,
            palette: key.palette, themePalette: themePalette,
            tint: key.tint, tintLength: key.tintLength, increaseContrast: ic,
            lookPairs: coveragePairs(panelPairs())
        )
        let chrome = AtticSurfaceModel.solve(
            base: chromeBase, kind: key.surface == .solid ? .solid : .frosted, appearance: appearance,
            palette: key.palette, themePalette: themePalette,
            tint: .off, tintLength: 1, increaseContrast: ic,
            lookPairs: coveragePairs(chromePairs())
        )

        // On translucent or tinted surfaces every role is tuned against the
        // surface as drawn, over every desktop, to the same floors
        // (`AtticSurfaceModel.floor`): the ladder steps stronger only where
        // a role would otherwise miss its floor, and a role already passing
        // is left exactly as it is.
        let translucentOrTinted = key.surface != .solid || key.tint != .off
        // Twice: the second pass sees the tag fills of a retuned accent.
        for _ in 0..<(translucentOrTinted ? 2 : 0) {
            for (model, pairs) in [(panel, panelPairs()), (chrome, chromePairs())] {
                for (ink, group) in Dictionary(grouping: pairs, by: \.ink) {
                    let backgrounds = group.flatMap { model.backgrounds(for: $0) }
                    let target = model.floor(for: ink) * (ink.floor == .text ? textTarget / 4.5 : nonTextTarget / 3)
                    inks[ink] = inks[ink]!.tuned(toContrast: target, against: backgrounds, lighten: dark)
                }
            }
        }

        return AtticColorTokens(
            context: key,
            panel: panel,
            chrome: chrome,
            contentCard: contentCard,
            contentCardRim: dark ? .white(ic ? 0.22 : 0.08) : (ic ? .black(0.30) : AtticRGBA(0xE4E4E4)),
            groupCard: groupCard,
            groupCardBorder: ic ? (dark ? .white(0.30) : .black(0.28)) : nil,
            divider: dark ? .white(ic ? 0.20 : 0.07) : .black(ic ? 0.18 : 0.06),
            recessed: recessed,
            recessedBorder: ic ? (dark ? .white(0.30) : .black(0.28)) : nil,
            hover: hover,
            selected: selected,
            pressed: pressed,
            chipSelected: chipSelected,
            chipHover: chipHover,
            skeleton: dark ? .white(0.08) : .black(0.06),
            controlBase: basePanel,
            raised: recipes.rest,
            raisedHover: recipes.hover,
            raisedPressed: recipes.pressed,
            raisedDisabled: recipes.disabled,
            glassStandIn: AtticGlassModel.standIn(dark: dark, increaseContrast: ic),
            glassFace: glassFace,
            glassDisabled: glassDisabled,
            glassPressed: glassPressed,
            popoverFill: popoverFill,
            popoverInnerRim: dark ? .white(ic ? 0.24 : 0.10) : .white(0.9),
            popoverOuterRim: dark ? (ic ? .white(0.35) : .black(0.55)) : .black(ic ? 0.30 : 0.11),
            popoverShadow: .black(dark ? 0.40 : 0.11),
            dragShadow: .black(dark ? 0.45 : 0.16),
            inks: inks
        )
    }

    /// The Craft-style recipe, matched to Craft's controls by their measured
    /// deltas from the page (owner references, 2026-09-25) and moved onto
    /// Attic's surfaces. Light (one notch firmer than Craft): a fill 7
    /// below #FAFAFA with a white band inside the top and bottom edges, a
    /// 1 pt edge about −11 at the top, −23 on the sides and −31 at the
    /// bottom, and a barely-there shadow. Dark: a fill 17 above #2C2C2D and
    /// a bright 1 pt rim, about +64 at the top, +37 on the sides and +56 at
    /// the bottom, with no dark outer edge. Increase Contrast keeps the
    /// fill and strengthens the edge.
    private static func recipes(dark: Bool, ic: Bool, base: AtticRGBA) -> (rest: AtticRaisedRecipe, hover: AtticRaisedRecipe, pressed: AtticRaisedRecipe, disabled: AtticRaisedRecipe) {
        if dark {
            func recipe(fill: Double, top: Double, middle: Double, bottom: Double) -> AtticRaisedRecipe {
                AtticRaisedRecipe(
                    base: base, fill: .white(fill), sheenTop: .white(0.015), sheenBottom: .white(0.005),
                    edgeTop: .white(ic ? 0.45 : top), edgeMiddle: .white(ic ? 0.35 : middle), edgeBottom: .white(ic ? 0.42 : bottom)
                )
            }
            return (
                recipe(fill: 0.08, top: 0.24, middle: 0.10, bottom: 0.21),
                recipe(fill: 0.10, top: 0.26, middle: 0.12, bottom: 0.23),
                recipe(fill: 0.05, top: 0.14, middle: 0.08, bottom: 0.14),
                recipe(fill: 0.04, top: 0.10, middle: 0.06, bottom: 0.08)
            )
        }
        func recipe(fill: Double, sheen: Double, top: Double, middle: Double, bottom: Double, shadow: Double) -> AtticRaisedRecipe {
            AtticRaisedRecipe(
                base: base, fill: fill >= 0 ? .black(fill) : .white(-fill),
                sheenTop: .white(sheen), sheenBottom: .white(sheen * 0.67),
                innerRimTop: .white(sheen > 0 ? 0.95 : 0), innerRimBottom: .white(sheen > 0 ? 0.7 : 0),
                edgeTop: .black(ic ? 0.30 : top), edgeMiddle: .black(ic ? 0.30 : middle), edgeBottom: .black(ic ? 0.36 : bottom),
                shadow: .black(shadow), shadowRadius: 0.75, shadowY: 0.5
            )
        }
        return (
            recipe(fill: 0.028, sheen: 0.6, top: 0.045, middle: 0.065, bottom: 0.12, shadow: 0.05),
            recipe(fill: 0.012, sheen: 0.7, top: 0.045, middle: 0.065, bottom: 0.12, shadow: 0.05),
            recipe(fill: 0.06, sheen: 0, top: 0.06, middle: 0.075, bottom: 0.10, shadow: 0),
            recipe(fill: 0.02, sheen: 0.4, top: 0.03, middle: 0.04, bottom: 0.06, shadow: 0)
        )
    }

    /// The fixed neutral values.
    enum Ladder {
        /// The spec asks for #5B5B5B. On it no helper or hint grey can reach
        /// 4.5 : 1 while staying lighter than the row text (the hint would
        /// have to be #D3D3D3, the body colour). #505050 keeps the mid-grey
        /// chrome step clearly above the #2E2E2E page and lets the italic hint
        /// (#C4C4C4) sit visibly below the rows (#E2E2E2) at 4.6 : 1.
        static let darkChrome = AtticRGBA(0x505050)

        static func neutral(dark: Bool, ic: Bool) -> [AtticInk: AtticRGBA] {
            switch (dark, ic) {
            case (false, false):
                // The approved v4 greys: body #494B4A, secondary #898A89,
                // the quietest #A6A7A8, icons #888888; each is tuned only
                // as far as its floor needs (secondary 3 : 1 on every row
                // state it sits on, so it lands a touch darker than v4).
                return [
                    .heading: AtticRGBA(0x1E1F1F), .body: AtticRGBA(0x494B4A),
                    .label: AtticRGBA(0x5F605F), .helper: AtticRGBA(0x898A89), .muted: AtticRGBA(0xA6A7A8), .placeholder: AtticRGBA(0xA6A7A8),
                    .chromeHeading: AtticRGBA(0x1E1F1F), .chromeBody: AtticRGBA(0x494B4A), .chromeHint: AtticRGBA(0x898A89),
                    .icon: AtticRGBA(0x888888), .chromeIcon: AtticRGBA(0x7A7B7A), .glyph: AtticRGBA(0x2F3130), .chevron: AtticRGBA(0x888888),
                    .inverseFill: AtticRGBA(0x2A2B2B), .onInverse: AtticRGBA(0xFAFAFA),
                    .disabledText: AtticRGBA(0x767776), .disabledIcon: AtticRGBA(0xA3A4A3)
                ]
            case (false, true):
                return [
                    .heading: AtticRGBA(0x111212), .body: AtticRGBA(0x2A2B2B),
                    .label: AtticRGBA(0x454645), .helper: AtticRGBA(0x4B4C4B), .muted: AtticRGBA(0x4B4C4B), .placeholder: AtticRGBA(0x4B4C4B),
                    .chromeHeading: AtticRGBA(0x111212), .chromeBody: AtticRGBA(0x2A2B2B), .chromeHint: AtticRGBA(0x4B4C4B),
                    .icon: AtticRGBA(0x5B5C5B), .chromeIcon: AtticRGBA(0x5B5C5B), .glyph: AtticRGBA(0x161717), .chevron: AtticRGBA(0x5B5C5B),
                    .inverseFill: AtticRGBA(0x161717), .onInverse: AtticRGBA(0xFFFFFF),
                    .disabledText: AtticRGBA(0x575857), .disabledIcon: AtticRGBA(0x8A8B8A)
                ]
            case (true, false):
                return [
                    .heading: AtticRGBA(0xF5F5F5), .body: AtticRGBA(0xD5D5D5),
                    .label: AtticRGBA(0xB0B0B0), .helper: AtticRGBA(0x959595), .muted: AtticRGBA(0x7C7C7E), .placeholder: AtticRGBA(0x7C7C7E),
                    .chromeHeading: AtticRGBA(0xF5F5F5), .chromeBody: AtticRGBA(0xE2E2E2), .chromeHint: AtticRGBA(0xA8A8A8),
                    .icon: AtticRGBA(0x8E8E8E), .chromeIcon: AtticRGBA(0xB4B4B4), .glyph: AtticRGBA(0xEAEAEA), .chevron: AtticRGBA(0x8E8E8E),
                    .inverseFill: AtticRGBA(0xEDEDED), .onInverse: AtticRGBA(0x1E1E1F),
                    .disabledText: AtticRGBA(0x939394), .disabledIcon: AtticRGBA(0x6E6E6F)
                ]
            case (true, true):
                return [
                    .heading: AtticRGBA(0xFAFAFA), .body: AtticRGBA(0xE8E8E8),
                    .label: AtticRGBA(0xCACACA), .helper: AtticRGBA(0xC2C2C2), .muted: AtticRGBA(0xC2C2C2), .placeholder: AtticRGBA(0xC2C2C2),
                    .chromeHeading: AtticRGBA(0xFAFAFA), .chromeBody: AtticRGBA(0xF0F0F0), .chromeHint: AtticRGBA(0xD8D8D8),
                    .icon: AtticRGBA(0xB4B4B4), .chromeIcon: AtticRGBA(0xC8C8C8), .glyph: AtticRGBA(0xF5F5F5), .chevron: AtticRGBA(0xB4B4B4),
                    .inverseFill: AtticRGBA(0xFAFAFA), .onInverse: AtticRGBA(0x161617),
                    .disabledText: AtticRGBA(0xB0B0B1), .disabledIcon: AtticRGBA(0x7E7E7F)
                ]
            }
        }

        /// The helper grey the PR #5 Glass and Frosted coverage was measured
        /// with (before rev 175 softened secondary text). It still sets the
        /// coverage, so the surfaces look exactly as they did.
        static func legacyHelper(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xA7A7A7) : AtticRGBA(0x676867) }
        static func legacyChromeHint(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xC4C4C4) : AtticRGBA(0x676867) }
        static func legacyPlaceholder(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xB0B0B0) : AtticRGBA(0x676867) }

        /// Starting hues for priority; each is tuned per palette and mode to
        /// 3 : 1 on the surface, its hover and its selection.
        static func priorityHues(dark: Bool) -> (high: AtticRGBA, medium: AtticRGBA, low: AtticRGBA) {
            dark
                ? (AtticRGBA(0xFF6B5E), AtticRGBA(0xFFAE45), AtticRGBA(0x76A6F5))
                : (AtticRGBA(0xD93A30), AtticRGBA(0xDB7C0B), AtticRGBA(0x3F7BDB))
        }
    }
}

/// Resolved tokens are pure functions of their key; resolve each once.
///
/// Bounded: a least-recently-used cache of `capacity` keys. Live UI touches
/// a handful (the current look, plus the palette tiles' swatches); the
/// appearance check walks the combinations one after another, so a small
/// window still hits on every render of the same combination. Tint lengths
/// are quantised in the key (`AtticDesignContext.quantisedTintLength`), so
/// a slider drag cannot grow it past the bound either.
final class AtticColorTokenCache: @unchecked Sendable {
    static let shared = AtticColorTokenCache()
    /// Enough for the live look, the 14 palette swatches and a slider drag's
    /// recent steps; small enough to stay a few hundred kilobytes.
    static let defaultCapacity = 48

    let capacity: Int
    private var cache: [AtticDesignContext.ColourKey: AtticColorTokens] = [:]
    /// Keys from least to most recently used.
    private var recency: [AtticDesignContext.ColourKey] = []
    private let lock = NSLock()

    init(capacity: Int = AtticColorTokenCache.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    func tokens(for key: AtticDesignContext.ColourKey) -> AtticColorTokens {
        lock.lock()
        if let hit = cache[key] {
            touch(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        let built = AtticColorTokens.build(key)
        lock.lock()
        defer { lock.unlock() }
        if cache[key] == nil {
            cache[key] = built
            recency.append(key)
            while cache.count > capacity, !recency.isEmpty {
                cache[recency.removeFirst()] = nil
            }
        } else {
            touch(key)
        }
        return built
    }

    /// Moves `key` to the most recent end (the lock is held).
    private func touch(_ key: AtticDesignContext.ColourKey) {
        guard recency.last != key, let index = recency.lastIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}

extension EnvironmentValues {
    /// Resolved colour tokens for the current `atticDesign` context.
    var atticTokens: AtticColorTokens { atticDesign.tokens }
}
