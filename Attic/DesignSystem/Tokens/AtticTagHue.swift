import AppKit
import Foundation
import SwiftUI

/// A tag's colour. Since N-2 (owner 2026-10-11) the tags use the
/// highlighter's clear hues, one palette for the app: yellow, green, blue,
/// pink and purple, which new tags are given automatically, and a neutral
/// grey that is only ever chosen.
///
/// The raw value is what a tag stores (`TagColour.colourKey`), so cases are
/// never renamed or removed. The colour pass's seven hues (2026-10-10) stay
/// readable as legacy keys and show as their nearest clear hue
/// (`canonical`): indigo as blue, violet as purple, teal and olive as
/// green, ochre as yellow. Nothing stored is rewritten; choosing a colour
/// stores one of the new keys.
enum AtticTagHue: String, CaseIterable, Sendable {
    case yellow, green, blue, pink, purple, grey
    // Legacy keys (colour pass, 2026-10-10): read, never offered.
    case indigo, violet, teal, olive, ochre

    /// The hues the Colour menu offers, in order (Grey after them).
    static let palette: [AtticTagHue] = [.yellow, .green, .blue, .pink, .purple]

    /// The colour pass's automatic hues, in the order its hash indexed
    /// them. Kept so a tag's automatic colour stays what it was, mapped to
    /// its clear hue (`hashed`).
    static let legacyAutomatic: [AtticTagHue] = [.blue, .indigo, .violet, .pink, .teal, .olive, .ochre]

    /// The hue this one shows as: a legacy key's nearest clear hue.
    var canonical: AtticTagHue {
        switch self {
        case .indigo: .blue
        case .violet: .purple
        case .teal, .olive: .green
        case .ochre: .yellow
        default: self
        }
    }

    /// The ink that draws this hue's text and dot.
    var ink: AtticInk {
        switch canonical {
        case .yellow: .tagYellow
        case .green: .tagGreen
        case .pink: .tagPink
        case .purple: .tagPurple
        case .grey: .tagGrey
        default: .tagBlue
        }
    }

    /// The colour's name in the tag menu.
    var title: String {
        switch canonical {
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .pink: String(localized: "Pink")
        case .purple: String(localized: "Purple")
        case .grey: String(localized: "Grey")
        default: String(localized: "Blue")
        }
    }

    /// The hue a tag's name hashes to: 32-bit FNV-1a of the UTF-8 of its
    /// folded name (trimmed, lowercased, NFC), modulo the colour pass's
    /// seven hues, shown as its clear hue. The hash is unchanged since the
    /// colour pass, so every tag keeps the colour family it had. Explicit,
    /// so it is the same on every launch and device (Swift's `hashValue`
    /// is seeded per process).
    static func hashed(_ name: String) -> AtticTagHue {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        var hash: UInt32 = 2_166_136_261
        for byte in folded.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return legacyAutomatic[Int(hash % UInt32(legacyAutomatic.count))].canonical
    }

    /// The hue a new tag is given: its hashed hue, or, when a tag in use
    /// already shows that hue, the next clear hue in order that none shows
    /// (wrapping round). With all five in use it keeps its hashed hue.
    static func assigned(to name: String, avoiding used: Set<AtticTagHue>) -> AtticTagHue {
        let hashed = hashed(name)
        let shown = Set(used.map(\.canonical))
        guard shown.contains(hashed), let start = palette.firstIndex(of: hashed) else { return hashed }
        for step in 1..<palette.count {
            let candidate = palette[(start + step) % palette.count]
            if !shown.contains(candidate) { return candidate }
        }
        return hashed
    }
}

/// Every tag's hue as the app shows it. Stored hues win; a tag with none
/// stored yet (one an agent or an import just made) shows the hue it is
/// about to be given, so storing it changes nothing on screen.
struct AtticTagPalette: Equatable, Sendable {
    /// The hues of the tags in use (stored, or resolved for storing).
    var hues: [String: AtticTagHue] = [:]

    static let empty = AtticTagPalette()

    func hue(for tag: String) -> AtticTagHue {
        if let hue = hues[tag] { return hue }
        return AtticTagHue.assigned(to: tag, avoiding: Set(hues.values))
    }

    /// Resolves the tags in use, oldest first: a stored hue is kept; a tag
    /// with none takes `AtticTagHue.assigned(to:avoiding:)` against the hues
    /// the tags before it hold (stored ones first, so a stored hue is
    /// never taken from its tag).
    static func resolve(inUse names: [String], stored: [String: AtticTagHue]) -> AtticTagPalette {
        var hues: [String: AtticTagHue] = [:]
        for name in names { if let hue = stored[name] { hues[name] = hue } }
        for name in names where hues[name] == nil {
            hues[name] = AtticTagHue.assigned(to: name, avoiding: Set(hues.values))
        }
        return AtticTagPalette(hues: hues)
    }
}

/// What a view needs to draw a tag in its colour and to change it: the
/// palette, and the tag menu's Colour action (nil where tags can't change,
/// such as the gallery, which then shows each tag's hashed hue).
enum TagColourUndoOrigin: Sendable {
    case page(UndoHistoryID)
    case editor(NoteUndoHistory)
}

struct AtticTagColouring {
    var palette: AtticTagPalette = .empty
    var setHue: (@MainActor @Sendable (_ tag: String, _ hue: AtticTagHue) -> Void)?

    var routeHue: (@MainActor @Sendable (String, AtticTagHue, TagColourUndoOrigin) -> Void)?

    func routed(to origin: TagColourUndoOrigin) -> Self {
        guard let routeHue else { return self }
        var copy = self
        copy.setHue = { tag, hue in routeHue(tag, hue, origin) }
        return copy
    }

    func hue(for tag: String) -> AtticTagHue { palette.hue(for: tag) }

    /// The tag chip's menu: a "Colour" header and the colours themselves,
    /// the five clear hues and Grey, the current one ticked, with no
    /// one-row hop through a Colour › submenu (Dropdown content: answers,
    /// owner, 2026-10-24, sheet 2). Empty where colours can't change.
    func colourCommands(for tag: String) -> [AtticMenuCommand] {
        guard let setHue else { return [] }
        let current = hue(for: tag).canonical
        return [.header(String(localized: "Colour"))] + (AtticTagHue.palette + [.grey]).map { hue in
            AtticMenuCommand(verbatim: hue.title, state: hue == current ? .on : nil, swatch: hue) {
                MainActor.assumeIsolated { setHue(tag, hue) }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var atticTagColouring = AtticTagColouring()
}

/// A tag colour's dot for menus (native and SwiftUI): drawn when the menu
/// draws, in the menu's own Light or Dark, from the tag tokens.
@MainActor
enum AtticTagSwatch {
    static let diameter: CGFloat = 10
    private static var cache: [AtticTagHue: NSImage] = [:]

    static func image(_ hue: AtticTagHue) -> NSImage {
        let hue = hue.canonical
        if let image = cache[hue] { return image }
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let tokens = AtticDesignContext(mode: dark ? .dark : .light, increaseContrast: increased).tokens
            tokens.tagInk(hue).nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = hue.title
        cache[hue] = image
        return image
    }
}

private struct AtticTagColourOrigin: ViewModifier {
    @Environment(\.atticTagColouring) private var colouring
    let origin: TagColourUndoOrigin
    func body(content: Content) -> some View {
        content.environment(\.atticTagColouring, colouring.routed(to: origin))
    }
}

extension View {
    func atticTagColourOrigin(_ origin: TagColourUndoOrigin) -> some View {
        modifier(AtticTagColourOrigin(origin: origin))
    }
}

// Glass-aware ink and contrast policy shared by panel pages and native controls.
// These values are a presentation contract; tag hue storage remains unchanged.
// MARK: - The design's greys under the title

/// The quieter text of the panel design, each a step under the title:
/// the group headers rgb(72,74,78), the next event's time rgb(86,88,92),
/// the dates rgb(110,112,116) and the meta line rgb(128,130,133), against
/// the title's rgb(29,29,31) on white. In that order, loudest first.
enum AtticPanelTone: CaseIterable, Sendable {
    case groupHeader, nextEventTime, date, meta

    /// The design's colour (it is drawn on white).
    var designColour: AtticRGBA {
        switch self {
        case .groupHeader: AtticRGBA(red: 72 / 255, green: 74 / 255, blue: 78 / 255, alpha: 1)
        case .nextEventTime: AtticRGBA(red: 86 / 255, green: 88 / 255, blue: 92 / 255, alpha: 1)
        case .date: AtticRGBA(red: 110 / 255, green: 112 / 255, blue: 116 / 255, alpha: 1)
        case .meta: AtticRGBA(red: 128 / 255, green: 130 / 255, blue: 133 / 255, alpha: 1)
        }
    }

    static let designTitle = AtticRGBA(red: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)

    /// How far under the title the design puts it: the log of its contrast
    /// on white over the log of the title's (header 0.77, date 0.57, meta
    /// 0.48). Contrast multiplies, so a power keeps the relation on any
    /// surface: on white it gives the design's own colour back.
    var designFraction: Double {
        log(designColour.contrast(on: .white(1))) / log(Self.designTitle.contrast(on: .white(1)))
    }
}


enum AtticSurfaceInk {
    // MARK: - Tag colour

    /// The oklch hue that stands for a tag's Attic colour (the branch's own
    /// colours are kept; the design's hashed `tagHue` is not used); nil for grey.
    static func oklchHue(for hue: AtticTagHue) -> Double? {
        switch hue.canonical {
        case .yellow: 85
        case .green: 150
        case .pink: 340
        case .purple: 300
        case .grey: nil
        default: 250
        }
    }

    /// A tag's text and soft fill. The text is the changelog's coloured
    /// tag (27 Oct, "coloured text, no pill"): `oklch(0.5 0.14 h)` in
    /// light; the fill, `oklch(0.9 0.028 h)`, is for chips that need one.
    /// In dark, light text on a deep fill.
    static func tagColours(hue: Double?, dark: Bool) -> (text: AtticRGBA, fill: AtticRGBA) {
        let chroma: (text: Double, fill: Double) = hue == nil ? (0, 0) : (0.14, 0.028)
        let h = hue ?? 0
        if dark {
            return (oklch(0.82, hue == nil ? 0 : 0.10, h), oklch(0.34, hue == nil ? 0 : 0.045, h))
        }
        return (oklch(0.5, chroma.text, h), oklch(0.9, chroma.fill, h))
    }

    /// A tag's `#name` ink. Glass keeps its clean colour (owner,
    /// 2026-10-29: `vivid`); Solid in Light is the changelog's
    /// `oklch(0.5 0.14 h)`; Dark and Increase Contrast keep the tag's
    /// token ink, which the changelog does not cover.
    static func tagInk(_ hue: AtticTagHue, tokens: AtticColorTokens) -> AtticRGBA {
        if seeThrough(tokens) { return vivid(tokens.ink(hue.ink), tokens: tokens) }
        guard tokens.context.mode == .light, !tokens.context.increaseContrast else { return tokens.ink(hue.ink) }
        return tagColours(hue: oklchHue(for: hue), dark: false).text
    }

    /// OKLCH to sRGB (Björn Ottosson's matrices), clipped to the gamut.
    static func oklch(_ l: Double, _ c: Double, _ hDegrees: Double, alpha: Double = 1) -> AtticRGBA {
        let h = hDegrees * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        func encode(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return AtticRGBA(red: encode(r), green: encode(g), blue: encode(bl), alpha: alpha)
    }

    /// The Note and Draw tag labels use the resolved hue's OKLCH text,
    /// then the same glass vibrancy adjustment as their existing rows.
    static func colouredTagText(_ hue: AtticTagHue, dark: Bool, tokens: AtticColorTokens) -> AtticRGBA {
        vivid(tagColours(hue: oklchHue(for: hue), dark: dark).text, tokens: tokens)
    }

    /// A design grey on this surface (fidelity round, 2026-10-28). The
    /// surface's tuning sets the title's ink (Phase 0's near-black on Glass,
    /// for example); each grey keeps the design's relation to that title,
    /// so a header reads a step lighter on every surface. Readability
    /// still wins: each is secondary text and keeps its floor (3 : 1, or
    /// 4.5 : 1 under Increase Contrast, with the tokens' margins) on every
    /// background the tokens judge their own grey on, and is never
    /// stronger than the title. Reduce Transparency
    /// keeps the contrast the chosen Glass grey had (U-40).
    @MainActor
    static func tone(_ tone: AtticPanelTone, tokens: AtticColorTokens) -> AtticRGBA {
        let key = ToneKey(colours: tokens.context, tone: tone)
        if let cached = toneCache[key] { return cached }
        var value = solveTone(tone, tokens: tokens)
        if let chosen = tokens.context.chosen {
            let glass = AtticColorTokenCache.shared.tokens(for: chosen)
            let glassTone = Self.tone(tone, tokens: glass)
            let glassSurface = glass.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
            let base = reference(tokens)
            let target = AtticColorTokens.reducedTransparencyTarget(glass: glassTone, glassSurface: glassSurface, base: base)
            value = value.tuned(toContrast: min(target, tokens.ink(.heading).contrast(on: base)), against: [base],
                                lighten: tokens.context.mode == .dark)
        }
        // The design's order holds where the floors bring the greys together:
        // a date never stronger than the header, the meta than a date.
        let louder: AtticPanelTone? = switch tone {
        case .groupHeader: nil
        case .nextEventTime: .groupHeader
        case .date: .nextEventTime
        case .meta: .date
        }
        if let louder {
            let base = reference(tokens)
            let limit = Self.tone(louder, tokens: tokens)
            if value.contrast(on: base) > limit.contrast(on: base) { value = limit }
        }
        toneCache[key] = value
        return value
    }

    /// A design grey as drawn on a see-through surface (owner, 2026-10-29:
    /// "vibrant greys"): the title's ink made see-through so that, over the
    /// surface above a mid-grey desktop, it is exactly `tone`. As macOS's
    /// own secondary label colours do, it darkens (or, in Dark, lightens)
    /// what is behind the glass, so it keeps its step from the glass
    /// wherever the panel sits. Solid, and Reduce Transparency, keep the
    /// opaque grey. Interactive metadata includes its state fills before
    /// converting the tuned grey back to see-through ink.
    @MainActor
    static func toneInk(_ tone: AtticPanelTone, tokens: AtticColorTokens, overlays: [AtticRGBA] = []) -> AtticRGBA {
        var value = Self.tone(tone, tokens: tokens)
        if !overlays.isEmpty {
            let backgrounds = tokens.panel.backgrounds(for: .init(ink: .helper, foreground: value, overlays: overlays))
            value = value.tuned(toContrast: toneFloor(tokens), against: backgrounds, lighten: tokens.context.mode == .dark)
        }
        guard tokens.context.surface != .solid, tokens.context.reducedFrom == nil else { return value }
        let ink = tokens.ink(.heading)
        let base = overlays.reduce(reference(tokens)) { $1.over($0) }
        func mean(_ c: AtticRGBA) -> Double { (c.red + c.green + c.blue) / 3 }
        let span = mean(ink) - mean(base)
        guard abs(span) > 0.01 else { return value }
        return ink.withAlpha((mean(value) - mean(base)) / span)
    }

    /// Glass or Frosted as drawn (not Solid, not made solid by Reduce
    /// Transparency).
    static func seeThrough(_ tokens: AtticColorTokens) -> Bool {
        tokens.context.surface != .solid && tokens.context.reducedFrom == nil
    }

    /// A colour cleaned up for glass (owner, 2026-10-29): the same hue,
    /// more saturated, at the same contrast on the surface, so tags, the
    /// overdue red and "!!" read clean on the glass's own grey instead of
    /// muddy. Solid keeps the colour.
    static func vivid(_ colour: AtticRGBA, tokens: AtticColorTokens) -> AtticRGBA {
        guard seeThrough(tokens) else { return colour }
        let base = reference(tokens)
        let (h, s, l) = colour.hsl
        let richer = AtticRGBA(hue: h, saturation: min(1, s * 1.35 + 0.12), lightness: l, alpha: colour.alpha)
        return richer.tuned(toContrast: colour.contrast(on: base), against: [base], lighten: tokens.context.mode == .dark)
    }

    private struct ToneKey: Hashable {
        let colours: AtticDesignContext.ColourKey
        let tone: AtticPanelTone
    }

    @MainActor private static var toneCache: [ToneKey: AtticRGBA] = [:]

    /// The surface the relation is judged on: over a mid-grey desktop,
    /// where content starts.
    static func reference(_ tokens: AtticColorTokens) -> AtticRGBA {
        tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
    }

    /// Every background a tone is judged on: the backgrounds the tokens
    /// judge their own secondary grey on (the surface over each desktop).
    static func toneBackgrounds(_ tone: AtticPanelTone, tokens: AtticColorTokens) -> [AtticRGBA] {
        tokens.panel.backgrounds(for: .init(ink: .helper, foreground: tokens.ink(.helper), overlays: []))
    }

    /// The floor each tone keeps, with the tokens' margin (3.11 and 4.66).
    static func toneFloor(_ tokens: AtticColorTokens) -> Double {
        tokens.panel.floor(for: .helper) < 4.5 ? 3.11 : 4.66
    }

    /// How much of the design's step under the title the greys keep on
    /// Glass and Frosted.
    static let glassStepScale = 0.5

    private static func solveTone(_ tone: AtticPanelTone, tokens: AtticColorTokens) -> AtticRGBA {
        let dark = tokens.context.mode == .dark
        let base = reference(tokens)
        let title = tokens.ink(.heading)
        let titleContrast = title.contrast(on: base)
        // On see-through surfaces the greys sit half as far under the title
        // as on paper (owner, 2026-10-29: stronger greys on glass), so they
        // hold up on the glass's own grey; the order and steps remain.
        let fraction = tokens.context.surface == .solid ? tone.designFraction : 1 - (1 - tone.designFraction) * glassStepScale
        let target = pow(titleContrast, fraction)
        // The design grey's hue and saturation, at the lightness that gives
        // the target: between the title's lightness and the surface's, where
        // contrast falls steadily.
        let (hue, saturation, _) = tone.designColour.hsl
        func grey(_ lightness: Double) -> AtticRGBA { AtticRGBA(hue: hue, saturation: saturation, lightness: lightness) }
        var near = title.hsl.lightness, far = base.hsl.lightness
        for _ in 0..<40 {
            let mid = (near + far) / 2
            if grey(mid).contrast(on: base) >= target { near = mid } else { far = mid }
        }
        var value = grey(near)
        value = value.tuned(toContrast: toneFloor(tokens), against: toneBackgrounds(tone, tokens: tokens), lighten: dark)
        if value.contrast(on: base) > titleContrast { value = title }
        return value
    }
}
