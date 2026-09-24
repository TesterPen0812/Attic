import Foundation
import SwiftUI

/// A colour role. Components ask for a role, never a hex value; the
/// appearance check knows each role's contrast floor.
enum AtticInk: String, CaseIterable, Sendable {
    // Text ladder (spec § Colour: never pure black or white).
    case heading, body, label, helper, placeholder
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
    /// Disabled controls are a ghost; WCAG exempts inactive components.
    case disabled

    enum Floor: Equatable, Sendable {
        /// 4.5 : 1, including helper and inactive text.
        case text
        /// 3 : 1 for icons, rings, circles and other non-text UI.
        case nonText
        /// Not judged (disabled ghosts).
        case exempt

        var ratio: Double {
            switch self {
            case .text: 4.5
            case .nonText: 3.0
            case .exempt: 1.0
            }
        }
    }

    var floor: Floor {
        switch self {
        case .heading, .body, .label, .helper, .placeholder,
             .chromeHeading, .chromeBody, .chromeHint,
             .accentText, .dueText, .warningText, .onInverse:
            .text
        case .icon, .chromeIcon, .glyph, .chevron, .accent,
             .priorityNone, .priorityLow, .priorityMedium, .priorityHigh,
             .doneFill, .onDone, .inverseFill:
            .nonText
        case .disabled:
            .exempt
        }
    }
}

/// The recipe numbers for the rim-lit raised material (spec § Raised
/// controls, Material). Light layers faint overlays on whatever surface is
/// below (so a palette, glass or tint shows through, as it does in Craft);
/// Dark is a white overlay about 11 % strong.
struct AtticRaisedRecipe: Equatable, Sendable {
    /// Vertical sheen: top, middle band (45–70 %), bottom. Overlays.
    let sheenTop: AtticRGBA
    let face: AtticRGBA
    let sheenBottom: AtticRGBA
    /// 1 pt inner rim, top and bottom of its vertical gradient.
    let innerRimTop: AtticRGBA
    let innerRimBottom: AtticRGBA
    /// Outer hairline, top and bottom (slightly darker at the bottom).
    let outerRimTop: AtticRGBA
    let outerRimBottom: AtticRGBA
    let outerRimWidth: CGFloat
    let shadow: AtticRGBA
    let shadowRadius: CGFloat
    let shadowY: CGFloat
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

    /// The opaque neutral base every raised control is drawn on, so content
    /// never shows through a floating control and controls never pick up a
    /// palette (they always stay in the base style).
    let controlBase: AtticRGBA
    let raised: AtticRaisedRecipe
    let raisedHover: AtticRaisedRecipe
    let raisedPressed: AtticRaisedRecipe
    let raisedDisabled: AtticRaisedRecipe
    /// Menus, pop-overs, toasts and the selection bar: raised over content.
    let popoverFill: AtticRGBA
    let popoverInnerRim: AtticRGBA
    let popoverOuterRim: AtticRGBA
    let popoverShadow: AtticRGBA
    let dragShadow: AtticRGBA

    // MARK: Inks

    let inks: [AtticInk: AtticRGBA]

    func ink(_ ink: AtticInk) -> AtticRGBA { inks[ink] ?? .black(1) }
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

        let recipes = Self.recipes(dark: dark, ic: ic)

        let popoverFill = dark ? AtticRGBA(0x363637) : AtticRGBA(0xFEFEFE)
        let contentCard = dark ? AtticRGBA(0x2E2E2E) : AtticRGBA(0xFBFBFB)
        let groupCard = dark ? AtticRGBA(0x333333) : AtticRGBA(0xF2F2F2)

        /// The backgrounds each role is actually drawn on, over a surface.
        /// Tuning a role against backgrounds it never sits on would flatten
        /// the ladder (helper would climb to the label's grey).
        func backgrounds(for ink: AtticInk, on surface: AtticRGBA) -> [AtticRGBA] {
            let face = recipes.rest.face.over(basePanel)
            let card = recessed.over(surface)
            let rows = [surface, hover.over(surface), selected.over(surface), pressed.over(surface), card, hover.over(card)]
            let menus = [popoverFill, selected.over(popoverFill), pressed.over(popoverFill), chipHover.over(popoverFill)]
            let settings = [contentCard, recessed.over(contentCard), groupCard, hover.over(groupCard), selected.over(groupCard)]
            switch ink {
            case .heading, .body, .glyph:
                return rows + menus + settings + [face, chipHover.over(face), chipSelected.over(face)]
            case .label:
                // Grouped-row labels and quick-look actions.
                return rows + settings
            case .helper:
                // Row meta, hints, Settings helper, and menu shortcuts on the
                // highlighted row.
                return rows + settings + [popoverFill, selected.over(popoverFill)]
            case .placeholder:
                return [face]
            case .icon, .chevron:
                return rows + menus + [face, chipHover.over(face), chipSelected.over(face)]
            default:
                return rows + menus + settings
            }
        }
        // Small safety margins over the floors, so 8-bit rendering never
        // rounds a pass into a miss.
        let textTarget = 4.58
        let nonTextTarget = 3.06

        // The text ladder and the neutral icons are tuned once per mode and
        // contrast setting, on the neutral base: text always stays in the
        // base style. Palette surfaces keep the neutral base's luminance
        // (`AtticSurfaceModel.hued`), so the same text passes on them.
        var inks = Ladder.neutral(dark: dark, ic: ic)
        for ink in [AtticInk.helper, .label, .placeholder, .body, .heading] {
            inks[ink] = inks[ink]!.tuned(toContrast: textTarget, against: backgrounds(for: ink, on: basePanel), lighten: dark)
        }
        for ink in [AtticInk.icon, .chevron, .glyph] {
            inks[ink] = inks[ink]!.tuned(toContrast: nonTextTarget, against: backgrounds(for: ink, on: basePanel), lighten: dark)
        }
        // Keep the ladder in order: a label is never quieter than helper text.
        let helperOnBase = inks[.helper]!.contrast(on: basePanel)
        if inks[.label]!.contrast(on: basePanel) < helperOnBase * 1.06 {
            inks[.label] = inks[.helper]!.tuned(toContrast: helperOnBase * 1.06, against: [basePanel], lighten: dark)
        }
        inks[.priorityNone] = inks[.icon]!
        let chromeBackgrounds = [baseChrome, selected.over(baseChrome), hover.over(baseChrome)]
        for ink in [AtticInk.chromeHeading, .chromeBody, .chromeHint] {
            inks[ink] = inks[ink]!.tuned(toContrast: textTarget, against: chromeBackgrounds, lighten: dark)
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
            .tuned(toContrast: textTarget, against: meaning + tagBackgrounds, lighten: dark)
        let pri = Ladder.priorityHues(dark: dark)
        inks[.priorityHigh] = pri.high.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.priorityMedium] = pri.medium.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.priorityLow] = pri.low.tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.dueText] = pri.high.tuned(toContrast: textTarget, against: meaning, lighten: dark)
        inks[.warningText] = (dark ? AtticRGBA(0xFFB35C) : AtticRGBA(0xC2570C)).tuned(toContrast: textTarget, against: meaning, lighten: dark)
        inks[.doneFill] = (dark ? AtticRGBA(0x7A7B7E) : AtticRGBA(0x9A9B9D)).tuned(toContrast: nonTextTarget, against: meaning, lighten: dark)
        inks[.onDone] = dark ? AtticRGBA(0x1E1E1F) : AtticRGBA(0xFFFFFF)

        let pairs = AtticSurfaceModel.readabilityPairs(
            inks: inks, hover: hover, selected: selected, pressed: pressed,
            controlFace: recipes.rest.face.over(basePanel), chipSelected: chipSelected, chipHover: chipHover,
            recessed: recessed, tagFill: tagFill, tagFillSelected: tagFillSelected
        )
        let chromePairs: [AtticSurfaceModel.Pair] = [
            .init(ink: .chromeHeading, foreground: inks[.chromeHeading]!, overlays: []),
            .init(ink: .chromeBody, foreground: inks[.chromeBody]!, overlays: [selected]),
            .init(ink: .chromeHint, foreground: inks[.chromeHint]!, overlays: []),
            .init(ink: .chromeIcon, foreground: inks[.chromeIcon]!, overlays: [selected])
        ]

        let panel = AtticSurfaceModel.solve(
            base: panelBase, kind: key.surface, appearance: appearance,
            palette: key.palette, themePalette: themePalette,
            tint: key.tint, tintLength: key.tintLength, policy: key.policy, pairs: pairs
        )
        // The chrome is a sidebar material: modelled as Frosted when the
        // panel surface is translucent, and never tinted.
        let chrome = AtticSurfaceModel.solve(
            base: chromeBase, kind: key.surface == .solid ? .solid : .frosted, appearance: appearance,
            palette: key.palette, themePalette: themePalette,
            tint: .off, tintLength: 1, policy: key.policy, pairs: chromePairs
        )

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
            popoverFill: popoverFill,
            popoverInnerRim: dark ? .white(ic ? 0.24 : 0.10) : .white(0.9),
            popoverOuterRim: dark ? (ic ? .white(0.35) : .black(0.55)) : .black(ic ? 0.30 : 0.11),
            popoverShadow: .black(dark ? 0.40 : 0.11),
            dragShadow: .black(dark ? 0.45 : 0.16),
            inks: inks
        )
    }

    private static func recipes(dark: Bool, ic: Bool) -> (rest: AtticRaisedRecipe, hover: AtticRaisedRecipe, pressed: AtticRaisedRecipe, disabled: AtticRaisedRecipe) {
        if dark {
            func recipe(fill: Double, top: Double, outer: AtticRGBA, shadow: Double) -> AtticRaisedRecipe {
                AtticRaisedRecipe(
                    sheenTop: .white(fill + 0.01), face: .white(fill), sheenBottom: .white(fill + 0.005),
                    innerRimTop: .white(top), innerRimBottom: .white(top * 0.55),
                    outerRimTop: outer, outerRimBottom: outer,
                    outerRimWidth: ic ? 1 : 0.5,
                    shadow: .black(shadow), shadowRadius: 1, shadowY: 1
                )
            }
            let outer: AtticRGBA = ic ? .white(0.35) : .black(0.45)
            return (
                recipe(fill: 0.11, top: 0.18, outer: outer, shadow: 0.25),
                recipe(fill: 0.14, top: 0.20, outer: outer, shadow: 0.25),
                recipe(fill: 0.07, top: 0.08, outer: outer, shadow: 0.12),
                recipe(fill: 0.05, top: 0.06, outer: .black(0.25), shadow: 0)
            )
        }
        // Light: "a sheen close to the surface colour (slightly lighter at top
        // and bottom), a 1 pt white inner rim, a 0.5 pt hairline slightly
        // darker at the bottom, and only a tiny 1 pt shadow". The sheen is
        // kept faint on purpose: a stronger middle band is what read as puffy
        // in the prototype.
        func recipe(top: Double, face: Double, bottom: Double, rim: Double, outerTop: Double, outerBottom: Double, shadow: Double) -> AtticRaisedRecipe {
            AtticRaisedRecipe(
                sheenTop: .white(top), face: face >= 0 ? .black(face) : .white(-face), sheenBottom: .white(bottom),
                innerRimTop: .white(rim), innerRimBottom: .white(rim * 0.6),
                outerRimTop: .black(ic ? 0.30 : outerTop), outerRimBottom: .black(ic ? 0.36 : outerBottom),
                outerRimWidth: ic ? 1 : 0.5,
                shadow: .black(shadow), shadowRadius: 0.75, shadowY: 0.5
            )
        }
        return (
            recipe(top: 0.55, face: 0.018, bottom: 0.30, rim: 0.9, outerTop: 0.075, outerBottom: 0.13, shadow: 0.07),
            recipe(top: 0.75, face: -0.25, bottom: 0.45, rim: 0.95, outerTop: 0.075, outerBottom: 0.13, shadow: 0.07),
            recipe(top: 0.0, face: 0.055, bottom: 0.10, rim: 0.0, outerTop: 0.09, outerBottom: 0.12, shadow: 0.0),
            recipe(top: 0.30, face: 0.0, bottom: 0.15, rim: 0.5, outerTop: 0.05, outerBottom: 0.06, shadow: 0.0)
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
                // Spec text (#1E1F1F, #494B4A) kept; label and helper are
                // darker than Craft's (#737473, #898A89 fail 4.5 : 1 on a
                // selected row) and stay apart by weight and size.
                return [
                    .heading: AtticRGBA(0x1E1F1F), .body: AtticRGBA(0x494B4A),
                    .label: AtticRGBA(0x5F605F), .helper: AtticRGBA(0x676867), .placeholder: AtticRGBA(0x676867),
                    .chromeHeading: AtticRGBA(0x1E1F1F), .chromeBody: AtticRGBA(0x494B4A), .chromeHint: AtticRGBA(0x676867),
                    .icon: AtticRGBA(0x7D7E7D), .chromeIcon: AtticRGBA(0x7A7B7A), .glyph: AtticRGBA(0x2F3130), .chevron: AtticRGBA(0x7D7E7D),
                    .inverseFill: AtticRGBA(0x2A2B2B), .onInverse: AtticRGBA(0xFAFAFA),
                    .disabled: AtticRGBA(0xB9BAB9)
                ]
            case (false, true):
                return [
                    .heading: AtticRGBA(0x111212), .body: AtticRGBA(0x2A2B2B),
                    .label: AtticRGBA(0x454645), .helper: AtticRGBA(0x4B4C4B), .placeholder: AtticRGBA(0x4B4C4B),
                    .chromeHeading: AtticRGBA(0x111212), .chromeBody: AtticRGBA(0x2A2B2B), .chromeHint: AtticRGBA(0x4B4C4B),
                    .icon: AtticRGBA(0x5B5C5B), .chromeIcon: AtticRGBA(0x5B5C5B), .glyph: AtticRGBA(0x161717), .chevron: AtticRGBA(0x5B5C5B),
                    .inverseFill: AtticRGBA(0x161717), .onInverse: AtticRGBA(0xFFFFFF),
                    .disabled: AtticRGBA(0x9A9B9A)
                ]
            case (true, false):
                return [
                    .heading: AtticRGBA(0xF5F5F5), .body: AtticRGBA(0xD5D5D5),
                    .label: AtticRGBA(0xB0B0B0), .helper: AtticRGBA(0xA7A7A7), .placeholder: AtticRGBA(0xB0B0B0),
                    .chromeHeading: AtticRGBA(0xF5F5F5), .chromeBody: AtticRGBA(0xE2E2E2), .chromeHint: AtticRGBA(0xC4C4C4),
                    .icon: AtticRGBA(0x9A9A9A), .chromeIcon: AtticRGBA(0xB4B4B4), .glyph: AtticRGBA(0xEAEAEA), .chevron: AtticRGBA(0x9A9A9A),
                    .inverseFill: AtticRGBA(0xEDEDED), .onInverse: AtticRGBA(0x1E1E1F),
                    .disabled: AtticRGBA(0x5E5E5F)
                ]
            case (true, true):
                return [
                    .heading: AtticRGBA(0xFAFAFA), .body: AtticRGBA(0xE8E8E8),
                    .label: AtticRGBA(0xCACACA), .helper: AtticRGBA(0xC2C2C2), .placeholder: AtticRGBA(0xC2C2C2),
                    .chromeHeading: AtticRGBA(0xFAFAFA), .chromeBody: AtticRGBA(0xF0F0F0), .chromeHint: AtticRGBA(0xD8D8D8),
                    .icon: AtticRGBA(0xB4B4B4), .chromeIcon: AtticRGBA(0xC8C8C8), .glyph: AtticRGBA(0xF5F5F5), .chevron: AtticRGBA(0xB4B4B4),
                    .inverseFill: AtticRGBA(0xFAFAFA), .onInverse: AtticRGBA(0x161617),
                    .disabled: AtticRGBA(0x6E6E6F)
                ]
            }
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
final class AtticColorTokenCache: @unchecked Sendable {
    static let shared = AtticColorTokenCache()
    private var cache: [AtticDesignContext.ColourKey: AtticColorTokens] = [:]
    private let lock = NSLock()

    func tokens(for key: AtticDesignContext.ColourKey) -> AtticColorTokens {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let built = AtticColorTokens.build(key)
        lock.lock()
        cache[key] = built
        lock.unlock()
        return built
    }
}

extension EnvironmentValues {
    /// Resolved colour tokens for the current `atticDesign` context.
    var atticTokens: AtticColorTokens { atticDesign.tokens }
}
