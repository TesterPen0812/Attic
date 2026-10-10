import AppKit
import Foundation
import SwiftUI

/// A tag's colour (colour pass, owner 2026-10-10): seven hues that new tags
/// are given automatically, and a neutral grey that is only ever chosen.
/// Red (overdue), orange (High's "!!"), green and yellow (the find highlight)
/// are left out on purpose. The raw value is what a tag stores
/// (`TagColour.colourKey`), so cases are never renamed.
enum AtticTagHue: String, CaseIterable, Sendable {
    case blue, indigo, violet, pink, teal, olive, ochre, grey

    /// The hues a new tag can be given, in the order the hash indexes.
    static let automatic: [AtticTagHue] = [.blue, .indigo, .violet, .pink, .teal, .olive, .ochre]

    /// The ink that draws this hue's text and dot.
    var ink: AtticInk {
        switch self {
        case .blue: .tagBlue
        case .indigo: .tagIndigo
        case .violet: .tagViolet
        case .pink: .tagPink
        case .teal: .tagTeal
        case .olive: .tagOlive
        case .ochre: .tagOchre
        case .grey: .tagGrey
        }
    }

    /// The colour's name in the tag menu.
    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .violet: String(localized: "Violet")
        case .pink: String(localized: "Pink")
        case .teal: String(localized: "Teal")
        case .olive: String(localized: "Olive")
        case .ochre: String(localized: "Ochre")
        case .grey: String(localized: "Grey")
        }
    }

    /// The hue a tag's name hashes to: 32-bit FNV-1a of the UTF-8 of its
    /// folded name (trimmed, lowercased, NFC), modulo the seven hues.
    /// Explicit, so it is the same on every launch and device (Swift's
    /// `hashValue` is seeded per process).
    static func hashed(_ name: String) -> AtticTagHue {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        var hash: UInt32 = 2_166_136_261
        for byte in folded.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return automatic[Int(hash % UInt32(automatic.count))]
    }

    /// The hue a new tag is given: its hashed hue, or, when a tag in use
    /// already has that hue, the next hue in order that none has (wrapping
    /// round). With all seven in use it keeps its hashed hue.
    static func assigned(to name: String, avoiding used: Set<AtticTagHue>) -> AtticTagHue {
        let hashed = hashed(name)
        guard used.contains(hashed), let start = automatic.firstIndex(of: hashed) else { return hashed }
        for step in 1..<automatic.count {
            let candidate = automatic[(start + step) % automatic.count]
            if !used.contains(candidate) { return candidate }
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
struct AtticTagColouring {
    var palette: AtticTagPalette = .empty
    var setHue: (@MainActor @Sendable (_ tag: String, _ hue: AtticTagHue) -> Void)?

    func hue(for tag: String) -> AtticTagHue { palette.hue(for: tag) }

    /// The tag menu's Colour row: seven hues and Grey, the current one
    /// ticked. Empty where colours can't change.
    func colourCommands(for tag: String) -> [AtticMenuCommand] {
        guard let setHue else { return [] }
        let current = hue(for: tag)
        return [.submenu(String(localized: "Colour"), AtticTagHue.allCases.map { hue in
            AtticMenuCommand(verbatim: hue.title, state: hue == current ? .on : nil, swatch: hue) {
                MainActor.assumeIsolated { setHue(tag, hue) }
            }
        })]
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
