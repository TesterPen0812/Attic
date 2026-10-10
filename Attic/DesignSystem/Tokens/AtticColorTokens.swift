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
    /// Priority is the status ring's weight and a grey that deepens with
    /// it (None the faintest, Medium the darkest); only High is red.
    case priorityNone, priorityLow, priorityMedium, priorityHigh
    /// Direction A: High's "!!" after the title, in orange (red is kept
    /// for overdue). Secondary text, like a tag: 3 : 1, 4.5 : 1 under
    /// Increase Contrast.
    case priorityMark
    /// Done (colour pass, owner 2026-10-10): the filled mark is the title's
    /// own ink (near-black in Light, near-white in Dark), and its tick the
    /// inverse. The same mark on tasks, subtasks and note checklists.
    case doneFill, onDone
    /// A tag's hue (`AtticTagHue`): its text and dot. Secondary text, like
    /// the grey tags they replace: 3 : 1 on the surface, the tag's own fill,
    /// and that fill under hover and selection; 4.5 : 1 under Increase
    /// Contrast. Grey is the manual-only neutral.
    case tagBlue, tagIndigo, tagViolet, tagPink, tagTeal, tagOlive, tagOchre, tagGrey
    /// A link in a note's body: blue, at the text floor; its underline
    /// (`linkUnderline`) carries the difference from body text too.
    case linkText
    /// The amber icon of a notice that needs attention but lost nothing
    /// (a read failure, an edit conflict, a deletion proposal). Errors take
    /// the overdue red (`dueText`). Only the icon is coloured.
    case noticeCaution
    /// The red icon of an error notice ("Not saved", a failed toast): the
    /// overdue red, held as an icon (3 : 1) on the pill and toast faces.
    case noticeError
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
             .accentText, .dueText, .warningText, .onInverse, .disabledText, .priorityMark,
             .tagBlue, .tagIndigo, .tagViolet, .tagPink, .tagTeal, .tagOlive, .tagOchre, .tagGrey, .linkText:
            .text
        case .icon, .chromeIcon, .glyph, .chevron, .accent,
             .priorityNone, .priorityLow, .priorityMedium, .priorityHigh,
             .doneFill, .onDone, .inverseFill, .disabledIcon, .noticeCaution, .noticeError:
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
        case .helper, .muted, .placeholder, .chromeHint, .disabledText, .accentText, .priorityMark,
             .tagBlue, .tagIndigo, .tagViolet, .tagPink, .tagTeal, .tagOlive, .tagOchre, .tagGrey: true
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
    /// Phase 0's Light palettes: the page button's current page in the
    /// accent (its fill and hairline at the palette's selected opacities);
    /// nil draws the neutral chip.
    let pageChipAccent: PageChipAccent?

    struct PageChipAccent: Equatable, Sendable {
        let fill: AtticRGBA
        let stroke: AtticRGBA
    }
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
    /// Attic's own dropdowns (E1): the pill on a solid `popoverFill`
    /// (#F1F1F1 / #444445) and D's two shadows. The card's edge is
    /// `popoverOuterRim`, which steps up under Increase Contrast.
    let dropdownHighlight: AtticRGBA
    let dropdownShadow: AtticRGBA
    let dropdownContactShadow: AtticRGBA
    let dragShadow: AtticRGBA

    // MARK: Inks

    let inks: [AtticInk: AtticRGBA]

    func ink(_ ink: AtticInk) -> AtticRGBA { inks[ink] ?? .black(1) }

    /// The Craft-style control face (opaque).
    var controlFace: AtticRGBA { raised.face.over(controlBase) }

    /// A search match in a title (the Done search, owner item 17): the
    /// find highlight's soft yellow behind the matched letters, which take
    /// the primary ink on it (heading reads at more than 7 : 1 on it in
    /// Light and 4.5 : 1 in Dark). Increase Contrast makes it firmer.
    var findHighlight: AtticRGBA {
        let ic = context.increaseContrast
        return context.mode == .dark
            ? AtticRGBA(0xFFD60A).withAlpha(ic ? 0.42 : 0.30)
            : AtticRGBA(0xFFDD33).withAlpha(ic ? 0.70 : 0.48)
    }

    /// Every face a control's label can sit on over `surface`: the Craft
    /// style's, and the worst Liquid Glass leaves on that surface.
    func controlFaces(over surface: AtticRGBA) -> [AtticRGBA] {
        [controlFace, glassFace.over(surface)]
    }
    func color(_ ink: AtticInk) -> Color { self.ink(ink).color }

    /// The ink of an icon that sits beside page labels (design review D-10):
    /// the secondary tier the inactive labels beside it are drawn in
    /// (#7A7A7A Light, #A4A4A4 Dark on the default Solid panel; the review
    /// sampled #737373 / #A7A7A7 for it), so it is never heavier than the
    /// words. Where the secondary ink would be the stronger of the two it
    /// keeps the primary glyph ink: never darker than before.
    var quietIconInk: AtticInk {
        ink(.helper).contrast(on: panel.base) <= ink(.glyph).contrast(on: panel.base) ? .helper : .glyph
    }

    /// The quietest note text: a new note's "Title" and the empty line's
    /// "Type / for headings…" hint (A39 F10). On Glass and Frosted the
    /// design's placeholder ink is Phase 0's secondary grey, near the
    /// primary (0.12 against 0.08, Light), so a hint in it read as typed
    /// text. This is the primary ink at partial opacity: it follows the
    /// surface it sits on, stays clearly lighter than typing in Light and
    /// Dark, and steps up under Increase Contrast.
    var hintInk: AtticRGBA {
        ink(.heading).withAlpha(context.increaseContrast ? 0.80 : 0.52)
    }

    /// An open task's ring (to do, and Later's dashed ring), owner fix 1
    /// (2026-09-27, card B of v15): the primary ink at low opacity, so it
    /// follows the surface it sits on and the title carries the row. Light
    /// Solid is the owner's reference (≈ #CDCDCE on white, 1.6 : 1); Dark
    /// and the see-through surfaces keep a clearly visible ring (the
    /// conservative default for the cases the owner left open); hovered or
    /// keyboard-focused it steps up to a firm ring. Below the 3 : 1 icon
    /// floor on purpose: a named exception in the appearance test
    /// (`OpenRingException`), never a loosened rule. Increase Contrast
    /// draws the primary ink (well past 3 : 1).
    func openRing(emphasised: Bool = false) -> AtticRGBA {
        let heading = ink(.heading)
        guard !context.increaseContrast else { return heading }
        let dark = context.mode == .dark
        let translucent = context.surface != .solid
        let alpha: Double = if emphasised {
            dark ? 0.62 : 0.55
        } else if dark {
            // L4 (owner, 2026-09-30): Dark Glass and Frosted one step
            // firmer (0.36 before); Dark Solid unchanged.
            translucent ? 0.46 : 0.28
        } else {
            translucent ? 0.30 : 0.22
        }
        return heading.withAlpha(alpha)
    }

    // MARK: Note tables (sheet 3)

    /// The table's grid and outer edge: the text's ink at 13 % (Light) or
    /// 18 % (Dark), 30 % under Increase Contrast (drawn 1 pt then).
    var tableGrid: AtticRGBA {
        ink(.heading).withAlpha(context.increaseContrast ? 0.30 : (context.mode == .dark ? 0.18 : 0.13))
    }
    /// The header row's fill (Light black 3.5 %).
    var tableHeaderFill: AtticRGBA { ink(.heading).withAlpha(context.mode == .dark ? 0.055 : 0.035) }
    /// The active cell's ring: a neutral focus ink, as drawn.
    var tableActiveRing: AtticRGBA { ink(.heading).withAlpha(context.increaseContrast ? 0.75 : (context.mode == .dark ? 0.55 : 0.42)) }
    /// A multi-cell selection's tint.
    var tableSelectionFill: AtticRGBA { tagFillSelected }
    /// The sideways scroll indicator under a wide table.
    var tableIndicator: AtticRGBA { ink(.heading).withAlpha(context.mode == .dark ? 0.36 : 0.28) }
    /// The row and column grips and the "+" chips.
    var tableGripFill: AtticRGBA { ink(.heading).withAlpha(context.mode == .dark ? 0.22 : 0.15) }
    var tableGripDot: AtticRGBA { ink(.heading).withAlpha(context.mode == .dark ? 0.70 : 0.53) }
    var tableAddFill: AtticRGBA { ink(.heading).withAlpha(context.mode == .dark ? 0.16 : 0.105) }

    var focusRing: AtticRGBA { ink(.accent) }
    /// The accent at a tag's fill alphas: the note date chip, the code
    /// chip's grey and the table selection (tags draw in their own hue,
    /// `tagFill(_:)`).
    var tagFill: AtticRGBA { ink(.accent).withAlpha(Self.tagFillAlpha(dark: context.mode == .dark)) }
    var tagFillSelected: AtticRGBA { ink(.accent).withAlpha(Self.tagFillSelectedAlpha(dark: context.mode == .dark)) }

    // MARK: Tag hues (colour pass, owner 2026-10-10)

    /// Today's tag-fill alphas, applied to each tag's own hue.
    static func tagFillAlpha(dark: Bool) -> Double { dark ? 0.16 : 0.10 }
    static func tagFillSelectedAlpha(dark: Bool) -> Double { dark ? 0.26 : 0.18 }

    /// A tag's text and dot.
    func tagInk(_ hue: AtticTagHue) -> AtticRGBA { ink(hue.ink) }
    /// A tag chip's fill: the hue at 10 % (Light) or 16 % (Dark). Under
    /// Increase Contrast, the neutral chip fill: the hue stays in the text.
    func tagFill(_ hue: AtticTagHue) -> AtticRGBA {
        context.increaseContrast ? tagFill : tagInk(hue).withAlpha(Self.tagFillAlpha(dark: context.mode == .dark))
    }
    /// A selected (filtering) tag chip's fill: the hue at 18 % / 26 %.
    func tagFillSelected(_ hue: AtticTagHue) -> AtticRGBA {
        context.increaseContrast ? tagFillSelected : tagInk(hue).withAlpha(Self.tagFillSelectedAlpha(dark: context.mode == .dark))
    }

    // MARK: Note content (colour pass)

    /// The highlight mark: a plain grey wash (black 16 % in Light, white
    /// 22 % in Dark) in every palette and surface (owner 2026-10-10: back
    /// to grey; a separate colour highlighter is later work). It is
    /// stronger than inline code's accent tint (`tagFill`: 10 % / 16 %), and
    /// code also keeps its monospaced font, so the two never read alike.
    /// Decoration under body text, which keeps 4.5 : 1 over it.
    var highlightMarker: AtticRGBA {
        context.mode == .dark ? AtticRGBA(0xFFFFFF).withAlpha(0.22) : AtticRGBA(0x000000).withAlpha(0.16)
    }
    /// A quote's bar (owner 2026-10-10, F-02): the quiet grey, never the
    /// primary ink. The quietest text ink at 22 % (Light, about #E5E5E5 on
    /// white: the owner's reference bar is #E6E7E7) or 32 % (Dark), 55 %
    /// under Increase Contrast. Decoration only: the text's indent and the
    /// line's own words carry the quote.
    var quoteBar: AtticRGBA {
        ink(.muted).withAlpha(context.increaseContrast ? 0.55 : (context.mode == .dark ? 0.32 : 0.22))
    }
    /// A link's underline: its blue at 55 %, kept so the link never depends
    /// on colour alone (the blue is only 1.5 : 1 against body text).
    var linkUnderline: AtticRGBA { ink(.linkText).withAlpha(0.55) }

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
        // Visual A ("Calm", 2026-09-26) sets the default look: Original on
        // Solid without a Tint. Other palettes, Tints, Glass and Frosted keep
        // their recipes; the drawn control material is Calm everywhere.
        let calm = key.palette == .original && key.surface == .solid && key.tint == .off
        // Phase 0's surfaces and Light palettes (owner, 2026-09-26).
        let phase0Treatment = key.palette.surfaceTreatment(
            appearance: appearance, contrast: ic ? .increased : .standard,
            surface: PanelSurfaceStyle(key.surface), tint: key.tint, tintLength: key.tintLength,
            reduceTransparency: false
        )
        let phase0LightPalette = !dark && key.palette != .original
        let usesPhase0Surface = key.surface != .solid || phase0LightPalette
        let basePanel = calm ? Calm.panel(dark: dark) : (dark ? AtticRGBA(0x2C2C2D) : AtticRGBA(0xFAFAFA))
        let baseChrome = dark ? Ladder.darkChrome : AtticRGBA(0xF3F3F3)
        let panelBase = AtticSurfaceModel.hued(basePanel, palette: key.palette, themePalette: themePalette, dark: dark)
        let chromeBase = AtticSurfaceModel.hued(baseChrome, palette: key.palette, themePalette: themePalette, dark: dark, chrome: true)

        let calmStates = calm && !ic
        let hover: AtticRGBA = calmStates ? .overlay(reaching: Calm.rowHover(dark: dark), on: basePanel)
            : (dark ? .white(ic ? 0.08 : 0.04) : .black(ic ? 0.07 : 0.035))
        let selected: AtticRGBA = calmStates ? .overlay(reaching: Calm.rowSelection(dark: dark), on: basePanel)
            : (dark ? .white(ic ? 0.14 : 0.07) : .black(ic ? 0.12 : 0.06))
        let pressed: AtticRGBA = dark ? .white(ic ? 0.18 : 0.10) : .black(ic ? 0.16 : 0.085)
        // The selected chip inside a raised control (Phase 0's drawn look,
        // as before visual A).
        let chipSelected: AtticRGBA = dark ? .white(ic ? 0.16 : 0.08) : .black(ic ? 0.13 : 0.10)
        let chipHover: AtticRGBA = dark ? .white(0.04) : .black(0.03)
        let recessed: AtticRGBA = dark ? .white(ic ? 0.09 : 0.055) : .black(ic ? 0.07 : 0.045)

        // The drawn controls sit on a neutral base of the surface's lightness
        // (no warm or green cast in their faces; owner, 2026-09-26).
        let recipes = Self.recipes(dark: dark, ic: ic, base: calm ? basePanel.neutralGrey : basePanel)
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
        // Priority greys, on the rows the ring sits on (as High's red): None
        // the faintest grey at the non-text floor, Low and Medium a step and
        // two beyond it, as in the approved status sheet.
        inks[.priorityNone] = (dark ? AtticRGBA(0x6C6C6F) : AtticRGBA(0xA2A2A4)).tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        let noneOnBase = inks[.priorityNone]!.contrast(on: basePanel)
        for (ink, step) in Self.priorityGreySteps(dark: dark) {
            inks[ink] = inks[.priorityNone]!.tuned(toContrast: noneOnBase * step, against: [basePanel], lighten: dark)
        }
        inks[.dueText] = pri.high.tuned(toContrast: textTarget, against: meaning, lighten: dark)
        inks[.priorityMark] = (dark ? AtticRGBA(0xF0A04E) : AtticRGBA(0xE2711D)).tuned(toContrast: target(.priorityMark), against: meaning, lighten: dark)
        inks[.warningText] = (dark ? AtticRGBA(0xFFB35C) : AtticRGBA(0xC2570C)).tuned(toContrast: textTarget, against: meaning, lighten: dark)
        // The PR #5 coverage was measured with the old faded Done (#C9CBCE /
        // a dim fill, at 3 : 1); it keeps setting the coverage, so the new
        // ink mark never changes how see-through a surface is.
        // The tick: white on the Light mark, near-black on the Dark one.
        inks[.onDone] = dark ? AtticRGBA(0x1E1E1F) : AtticRGBA(0xFFFFFF)
        let legacyDoneFill = (dark ? AtticRGBA(0x6E6F72) : AtticRGBA(0xC9CBCE))
            .tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
            .tuned(toContrast: nonTextTarget, against: [inks[.onDone]!], lighten: dark)
        // A disabled done task's mark is the disabled icon colour; the tick
        // keeps 3 : 1 on it, so that fill steps away from the tick.
        inks[.disabledIcon] = inks[.disabledIcon]!.tuned(toContrast: nonTextTarget, against: [inks[.onDone]!], lighten: dark)
        inks[.doneFill] = legacyDoneFill

        // Colour pass (owner, 2026-10-10). Notices: amber for "needs a look,
        // nothing lost", tuned on the pill faces and the details pop-over.
        let pillFaces = [recipes.rest.face.over(basePanel), glassFace.over(panelBase), popoverFill, contentCard]
        inks[.noticeCaution] = (dark ? AtticRGBA(0xF0AD2E) : AtticRGBA(0xB37B09)).tuned(toContrast: nonTextTarget, against: pillFaces, lighten: dark)
        inks[.noticeError] = inks[.dueText]!.tuned(toContrast: nonTextTarget, against: pillFaces, lighten: dark)
        // Links in a note's body: blue (tuned with the tags, below).
        inks[.linkText] = dark ? AtticRGBA(0x93B6F7) : AtticRGBA(0x2760BF)

        // Visual A's exact inks on the default surface (the review's colour
        // table; Increase Contrast takes its stronger secondary grey and
        // keeps the tuned ladder otherwise).
        if calm {
            // Under Increase Contrast the review's grey is a starting point:
            // it keeps 4.5 : 1 on the panel but not on the stronger pressed
            // and selected fills, so it steps darker only as far as those need.
            var secondary = Calm.secondary(dark: dark, increaseContrast: ic)
            if ic {
                secondary = secondary.tuned(toContrast: textTarget, against: backgrounds(for: .helper, on: basePanel)
                    + [inks[.accent]!.withAlpha(dark ? 0.26 : 0.18).over(recessed.over(basePanel)), hover.over(inks[.accent]!.withAlpha(dark ? 0.16 : 0.10).over(basePanel))], lighten: dark)
            }
            for ink in [AtticInk.helper, .placeholder, .accentText] { inks[ink] = secondary }
            if !ic {
                inks[.body] = Calm.taskText(dark: dark)
                inks[.heading] = Calm.strongText(dark: dark)
                inks[.glyph] = Calm.strongText(dark: dark)
                inks[.priorityNone] = Calm.openRing(dark: dark)
                inks[.priorityMark] = Calm.highPriority(dark: dark)
            }
            // Keep the ladder in order around the new secondary grey.
            let helperOnBase = secondary.contrast(on: basePanel)
            if inks[.muted]!.contrast(on: basePanel) > helperOnBase { inks[.muted] = secondary }
            if inks[.disabledText]!.contrast(on: basePanel) > helperOnBase { inks[.disabledText] = secondary }
            if inks[.label]!.contrast(on: basePanel) < helperOnBase * 1.06 {
                inks[.label] = secondary.tuned(toContrast: helperOnBase * 1.06, against: [basePanel], lighten: dark)
            }
            let noneOnBase = inks[.priorityNone]!.contrast(on: basePanel)
            for (ink, step) in Self.priorityGreySteps(dark: dark) {
                inks[ink] = inks[.priorityNone]!.tuned(toContrast: noneOnBase * step, against: [basePanel], lighten: dark)
            }
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
        // Low and Medium were blue and orange at the floor when PR #5 was
        // measured; the greys that replaced them are never harder, and the
        // coverage keeps the colours it was set with.
        let legacyPriority: [AtticInk: AtticRGBA] = [
            .doneFill: legacyDoneFill,
            .priorityNone: inks[.icon]!,
            .priorityLow: pri.low.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark),
            .priorityMedium: pri.medium.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        ]
        func coveragePairs(_ pairs: [AtticSurfaceModel.Pair]) -> [AtticSurfaceModel.Pair] {
            // Labels on Liquid Glass are kept readable by their inks (tuned
            // against the worst glass face), never by making the surface
            // less see-through: the coverage stays the PR #5 look.
            let pairs = pairs.filter { !$0.onGlass }.map { pair in
                legacyPriority[pair.ink].map { AtticSurfaceModel.Pair(ink: pair.ink, foreground: $0, overlays: pair.overlays, onGlass: pair.onGlass) } ?? pair
            }
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
        // Phase 0's surfaces (owner, 2026-09-26): Glass and Frosted in both
        // modes, and the palettes' Light Solid, are Phase 0's recipe
        // exactly. Original's Light Solid (pure white) and every Dark Solid
        // keep the design system's own.
        let panel = usesPhase0Surface
            ? AtticSurfaceModel.phase0(phase0Treatment, increaseContrast: ic)
                .readable(primary: AtticRGBA(phase0Treatment.palette.primaryForeground),
                          secondary: AtticRGBA(phase0Treatment.palette.secondaryForeground))
                .darkTinted(primary: AtticRGBA(phase0Treatment.palette.primaryForeground),
                            secondary: AtticRGBA(phase0Treatment.palette.secondaryForeground))
                .definedDarkEdge()
            : AtticSurfaceModel.solve(
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
        // Phase 0's Glass and Frosted keep their text as Phase 0 drew it (the
        // palettes' inks, or the ladder for Original and Dark): the owner's
        // named exception, not a stepped-up ladder (`phase0Translucent`).
        let phase0Translucent = key.surface != .solid
        let translucentOrTinted = !phase0Translucent && (key.tint != .off || usesPhase0Surface)
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
        // Phase 0's Light palettes (owner, 2026-09-26): their text and accent
        // colours exactly, whatever the surface (named exceptions in
        // `AtticDesignSystemTests.phase0ContrastExceptions` if one misses a
        // floor).
        // Glass and Frosted (every palette, both modes; owner, 2026-09-26)
        // take Phase 0's text too: its near-black / near-white primary and
        // secondary greys stay readable where the softer ladder fades.
        if phase0LightPalette || phase0Translucent {
            let p0 = phase0Treatment.palette
            for ink in [AtticInk.heading, .body, .label] { inks[ink] = AtticRGBA(p0.primaryForeground) }
            inks[.helper] = AtticRGBA(p0.secondaryForeground)
            inks[.placeholder] = AtticRGBA(p0.secondaryForeground)
        }
        if phase0LightPalette {
            let p0 = phase0Treatment.palette
            inks[.accent] = AtticRGBA(p0.accent)
            inks[.accentText] = AtticRGBA(p0.accent)
        }
        // Glass and Frosted: every secondary text role reads as Phase 0's
        // secondary grey, a step below the primary (owner item 7, Astra 11).
        // Before, only helper and placeholder took it, so tags, the quietest
        // grey and the colours of meaning kept greys tuned for Solid, which
        // fade to about 1.5 : 1 on Dark Glass over a light desktop.
        if phase0Translucent {
            let p0 = phase0Treatment.palette
            let secondary = AtticRGBA(p0.secondaryForeground)
            let p0Base = AtticRGBA(p0.opaqueSurface)
            inks[.muted] = secondary
            // Tags: Original's grey is the secondary grey; a palette keeps its
            // hue at the secondary grey's lightness (Dark). The Light
            // palettes keep Phase 0's accent exactly (above).
            if key.palette == .original {
                inks[.accentText] = secondary
            } else if dark {
                inks[.accentText] = accentBase.tuned(toContrast: secondary.contrast(on: p0Base), against: [p0Base], lighten: true)
            }
            // The colours of meaning (overdue, the High mark, warnings) keep
            // their floors on the surface as drawn over a mid-grey desktop.
            // Over black and white desktops they stay inside the named
            // translucency exception: a red that kept 4.5 : 1 there would
            // be almost white or black and stop meaning "overdue".
            let surfaces = [AtticSurfaceModel.contentTop, 1].map { panel.composite(.midGrey, at: $0) }
            // High's orange "!!" would have to go almost white to reach the
            // 4.5 : 1 Increase Contrast asks of it here, and stop reading as
            // orange: under Increase Contrast it stays in the exception.
            for ink in [AtticInk.dueText, .priorityMark, .warningText, .linkText, .noticeCaution, .noticeError] where !(ink == .priorityMark && ic) {
                let floor = AtticSurfaceModel.floor(for: ink, kind: key.surface, increaseContrast: ic)
                inks[ink] = inks[ink]!.tuned(toContrast: floor * (floor > 3 ? textTarget / 4.5 : secondaryTarget / 3),
                                             against: surfaces, lighten: dark)
            }
        }
        // Tags (colour pass, owner 2026-10-10): seven hues and a grey, each
        // a starting value tuned per palette, mode and surface to the tag
        // floor (secondary text: 3 : 1, 4.5 : 1 under Increase Contrast) on
        // the surface, on its own fill (at rest, hovered, selected) and on
        // that fill over a hovered or selected row, in the panel, a card and
        // a menu. Palettes keep the hues: a tag is learned by its colour.
        // Grey (manual only) starts from the secondary grey, as tags were.
        // Under Increase Contrast the fill is the neutral chip fill
        // (`tagFill(_:)`): a tint of the text's own hue behind it would
        // force every hue to near white or black to keep 4.5 : 1.
        let tagStarts = Ladder.tagHues(dark: dark, ic: ic)
        let tagSurfaces: [AtticRGBA] = phase0Translucent
            ? [AtticSurfaceModel.contentTop, 1].map { panel.composite(.midGrey, at: $0) }
            : [panelBase, panel.base]
        // Links in a note's body: blue at the text floor on the body's
        // surface, hovered and selected.
        inks[.linkText] = inks[.linkText]!.tuned(toContrast: textTarget, against: tagSurfaces.flatMap { [$0, hover.over($0), selected.over($0)] }, lighten: dark)
        let tagBases = tagSurfaces + [recessed.over(panelBase), contentCard, popoverFill]
        for hue in AtticTagHue.allCases {
            let start = tagStarts[hue] ?? inks[.helper]!
            var tagInk = start
            // Twice: the fills move with the ink they are made of.
            for _ in 0..<2 {
                let tint = ic ? inks[.accent]! : tagInk
                let fill = tint.withAlpha(Self.tagFillAlpha(dark: dark))
                let fillSelected = tint.withAlpha(Self.tagFillSelectedAlpha(dark: dark))
                // Every base: the tag at rest, hovered and filtering. The
                // panel's rows also hover and select under it.
                let backgrounds = tagBases.flatMap { base in
                    [base, fill.over(base), fillSelected.over(base), hover.over(fill.over(base))]
                } + tagSurfaces.flatMap { surface in
                    [fill.over(hover.over(surface)), fill.over(selected.over(surface))]
                }
                tagInk = start.tuned(toContrast: target(hue.ink), against: backgrounds, lighten: dark)
            }
            inks[hue.ink] = tagInk
        }

        // Done (owner, 2026-10-10): the filled mark is the title's own ink
        // (the status ring's), so open, in progress and done read as one
        // ink: a ring, a ring and pie, a filled disc with its tick. The tick
        // keeps 3 : 1 on the mark (4.5 : 1 under Increase Contrast).
        inks[.doneFill] = inks[.heading]!
        inks[.onDone] = inks[.onDone]!.tuned(toContrast: ic ? textTarget : nonTextTarget, against: [inks[.doneFill]!], lighten: !dark)

        // The surface tuning can bring the priority greys together (each
        // stops at the floor): keep Low and Medium a step beyond None.
        let noneOnPanel = inks[.priorityNone]!.contrast(on: basePanel)
        for (ink, step) in Self.priorityGreySteps(dark: dark) where inks[ink]!.contrast(on: basePanel) < noneOnPanel * step {
            inks[ink] = inks[ink]!.tuned(toContrast: noneOnPanel * step, against: [basePanel], lighten: dark)
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
            pageChipAccent: phase0LightPalette ? PageChipAccent(
                fill: AtticRGBA(phase0Treatment.palette.accent).withAlpha(phase0Treatment.palette.selectedFillOpacity),
                stroke: AtticRGBA(phase0Treatment.palette.accent).withAlpha(min(phase0Treatment.palette.selectedStrokeOpacity + (ic ? 0.14 : 0), 1))
            ) : nil,
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
            dropdownHighlight: dark ? AtticRGBA(0x444445) : AtticRGBA(0xF1F1F1),
            dropdownShadow: .black(dark ? 0.42 : 0.12),
            dropdownContactShadow: .black(dark ? 0.24 : 0.05),
            dragShadow: .black(dark ? 0.45 : 0.16),
            inks: inks
        )
    }

    /// Low and Medium's contrast on the panel as multiples of None's: wider
    /// steps in Light (the reference sheet's greys), gentler in Dark, where
    /// the same multiples would reach almost white.
    private static func priorityGreySteps(dark: Bool) -> [(AtticInk, Double)] {
        dark ? [(.priorityLow, 1.2), (.priorityMedium, 1.5)] : [(.priorityLow, 1.35), (.priorityMedium, 1.85)]
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
    ///
    /// Quiet inactive controls (Astra 27, kept by the owner in round 6):
    /// one even edge at the side's strength, with no inner rim and no
    /// shadow below, so an out-of-focus control is never heavier than a
    /// focused one. The face, the sheen and the selected chip (the pinned
    /// pin) are the recipe's; Increase Contrast keeps its stronger edge.
    private static func recipes(dark: Bool, ic: Bool, base: AtticRGBA) -> (rest: AtticRaisedRecipe, hover: AtticRaisedRecipe, pressed: AtticRaisedRecipe, disabled: AtticRaisedRecipe) {
        let recipes = drawnRecipes(dark: dark, ic: ic, base: base)
        guard !ic else { return recipes }
        func quieted(_ recipe: AtticRaisedRecipe) -> AtticRaisedRecipe {
            var recipe = recipe
            recipe.edgeTop = recipe.edgeMiddle
            recipe.edgeBottom = recipe.edgeMiddle
            recipe.innerRimTop = .clear
            recipe.innerRimMiddle = .clear
            recipe.innerRimBottom = .clear
            recipe.shadow = .clear
            return recipe
        }
        return (quieted(recipes.rest), quieted(recipes.hover), quieted(recipes.pressed), quieted(recipes.disabled))
    }

    /// The drawn faces and edges before quieting (Increase Contrast keeps
    /// them whole).
    private static func drawnRecipes(dark: Bool, ic: Bool, base: AtticRGBA) -> (rest: AtticRaisedRecipe, hover: AtticRaisedRecipe, pressed: AtticRaisedRecipe, disabled: AtticRaisedRecipe) {
        if dark {
            func recipe(fill: Double, top: Double, middle: Double, bottom: Double) -> AtticRaisedRecipe {
                AtticRaisedRecipe(
                    base: base, fill: .white(fill), sheenTop: .white(0.015), sheenBottom: .white(0.005),
                    edgeTop: .white(ic ? 0.45 : top), edgeMiddle: .white(ic ? 0.35 : middle), edgeBottom: .white(ic ? 0.42 : bottom)
                )
            }
            // Phase 0's out-of-focus weight (owner, 2026-09-26): a fuller
            // face and a clearer rim than before visual A.
            return (
                recipe(fill: 0.11, top: 0.26, middle: 0.15, bottom: 0.22),
                recipe(fill: 0.13, top: 0.28, middle: 0.17, bottom: 0.24),
                recipe(fill: 0.07, top: 0.16, middle: 0.10, bottom: 0.15),
                recipe(fill: 0.05, top: 0.10, middle: 0.06, bottom: 0.08)
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
        // Phase 0's out-of-focus weight (owner, 2026-09-26): the face about
        // 19 below the surface (the reference's #ECECEC on white), a crisp
        // grey rim, a softer sheen, and the soft shadow.
        return (
            recipe(fill: 0.075, sheen: 0.3, top: 0.14, middle: 0.19, bottom: 0.24, shadow: 0.06),
            recipe(fill: 0.055, sheen: 0.4, top: 0.14, middle: 0.19, bottom: 0.24, shadow: 0.06),
            recipe(fill: 0.11, sheen: 0, top: 0.16, middle: 0.20, bottom: 0.22, shadow: 0),
            recipe(fill: 0.04, sheen: 0.3, top: 0.07, middle: 0.09, bottom: 0.12, shadow: 0)
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

        /// Starting values for the tag hues (`colour-final.md` § 1), measured
        /// to pass on every Solid, Glass and Frosted surface already; the
        /// build tunes each only as far as a surface needs.
        static func tagHues(dark: Bool, ic: Bool) -> [AtticTagHue: AtticRGBA] {
            let values: [UInt32] = switch (dark, ic) {
            case (false, false): [0x3975D7, 0x5A62D6, 0x8C55C8, 0xC24C8C, 0x218384, 0x6E7F28, 0x9A7023]
            case (true, false): [0x7CA9F2, 0x9EA3F5, 0xC29AF0, 0xF08FC4, 0x5CC9C6, 0xB4C766, 0xE2B65A]
            case (false, true): [0x2358AD, 0x3D47CF, 0x753AB5, 0x98346A, 0x196363, 0x53601E, 0x74551A]
            case (true, true): [0xC7DAF9, 0xD5D8FB, 0xE4D2F8, 0xF8CCE4, 0xABE3E1, 0xD3DEA5, 0xEFD6A2]
            }
            return Dictionary(uniqueKeysWithValues: zip(AtticTagHue.automatic, values.map { AtticRGBA($0) }))
        }

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

// MARK: - Visual A ("Calm")

/// Visual A, "Calm" (Astra's visual review, 2026-09-26): the exact colours
/// of the default look (Original on Solid, no Tint) and the drawn control
/// material. Solid and drawn targets: native Liquid Glass keeps its own.
enum Calm {
    /// Owner, 2026-09-26: the Light surface is pure white.
    static func panel(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0x2E2E2E) : AtticRGBA(0xFFFFFF) }
    static func taskText(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xDFDFDF) : AtticRGBA(0x4B4B4B) }
    static func strongText(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xF1F1F1) : AtticRGBA(0x272727) }
    static func secondary(dark: Bool, increaseContrast: Bool) -> AtticRGBA {
        switch (dark, increaseContrast) {
        case (false, false): AtticRGBA(0x7A7A7A)
        case (false, true): AtticRGBA(0x626262)
        case (true, false): AtticRGBA(0xA4A4A4)
        case (true, true): AtticRGBA(0xBFBFBF)
        }
    }
    static func openRing(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0x959595) : AtticRGBA(0x838383) }
    static func rowHover(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0x383838) : AtticRGBA(0xF1F1F1) }
    static func rowSelection(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0x454545) : AtticRGBA(0xE7E7E7) }
    static func highPriority(dark: Bool) -> AtticRGBA { dark ? AtticRGBA(0xD9A16C) : AtticRGBA(0xB35D27) }
}
