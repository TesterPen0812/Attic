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
    /// "Coloured Tags in Lists": a task row's tags as coloured chips
    /// (`AtticTagLabel`) rather than quiet grey text (the default).
    @Entry var atticColouredTagsInLists = false
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
