import AppKit
import Carbon
import SwiftUI

/// Where a formatting or insertion command came from. Every surface runs
/// the same `NoteFormatCommand` through `NoteCommandRouter`; the surface is
/// recorded only so tests can prove it.
enum NoteCommandSurface: String, CaseIterable, Sendable {
    case selectionBar, formatBar, slashList, noteMenu, contextMenu, menuBar, shortcut, linkPopover
}

/// The Insert menu's three rows (⋯ › Insert, right-click, the menu bar).
/// Divider is an engine command; Date and Image or File open their pickers.
enum NoteInsertAction: String, CaseIterable, Sendable {
    case imageOrFile, date, divider, table

    var title: String {
        switch self {
        case .imageOrFile: String(localized: "Image or File…")
        case .date: String(localized: "Date…")
        case .divider: String(localized: "Divider")
        case .table: String(localized: "Table")
        }
    }

    var symbolName: String {
        switch self {
        case .imageOrFile: "photo"
        case .date: "calendar"
        case .divider: "minus"
        case .table: "tablecells"
        }
    }
}

/// The one list of Notes formatting commands the UI shows: the selection
/// bar, Aa's format row, ⋯ › Format, the right-click menu, the menu bar and
/// the keyboard shortcuts all read their rows, order and keys from here, and
/// the engine (`NoteEditorEngine.validate` / `perform`) decides what each
/// one does. Nothing here keeps a second list of behaviour.
enum NoteCommandCatalog {
    /// Paragraph styles, a choice of one (Title … Mono, then Quote: a
    /// paragraph style like them, not a list; owner pick Q6, 2026-10-08).
    static let styles: [NoteFormatCommand] = [
        .paragraph(.heading(1)), .paragraph(.heading(2)), .paragraph(.heading(3)), .paragraph(.body), .paragraph(.mono),
        .paragraph(.quote)
    ]
    /// B I U S.
    static let marks: [NoteFormatCommand] = [.mark(.bold), .mark(.italic), .mark(.underline), .mark(.strikethrough)]
    /// Link, highlight and inline code.
    static let inline: [NoteFormatCommand] = [.mark(.link), .mark(.highlight), .mark(.code)]
    /// The format row's four cells: the lists, each toggling back to Body
    /// when it is already on, and Table (it takes Quote's cell; Q6).
    static let lists: [NoteFormatCommand] = [
        .paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .table
    ]
    static let indents: [NoteFormatCommand] = [.outdent, .indent]
    static let lineActions: [NoteFormatCommand] = [.toggleChecklist, .moveUp, .moveDown]

    /// The selection bar (mockup p2-16 D as p2-36 draws it): style, B I U
    /// S, link, highlight, inline code. The lists are on the format row.
    static let barMarks: [NoteFormatCommand] = marks
    static let barInline: [NoteFormatCommand] = inline

    /// ⋯ › Format and every other Format menu, in sections.
    static let formatSections: [[NoteFormatCommand]] = [
        styles, marks + [.mark(.highlight), .mark(.code)], [.mark(.link), .removeLink], lists, [.indent, .outdent], lineActions
    ]
    /// The Format menus' rows, without Table (it is in Insert there).
    static var formatMenuSections: [[NoteFormatCommand]] { formatSections.map { $0.filter { $0 != .table } } }

    /// Every command a person can reach (the five-route check iterates it).
    static let allCommands: [NoteFormatCommand] = formatSections.flatMap { $0 } + [.divider]

    /// Styles that act as a toggle: choosing one that is on returns the
    /// lines to Body (Apple Notes' lists). Text styles are a plain choice.
    static func togglesOff(_ command: NoteFormatCommand) -> Bool {
        if case let .paragraph(style) = command { return [.bullet, .number, .checklist, .quote].contains(style) }
        return false
    }

    /// Menus say "Link…": it opens the link pop-over.
    static func menuTitle(_ command: NoteFormatCommand) -> String {
        switch command {
        case .mark(.link): String(localized: "Link…")
        case .mark(.code): String(localized: "Code")
        default: command.title
        }
    }

    /// The short name on the style controls (the selection bar, the format row).
    static func styleName(_ style: NoteParagraphStyle?) -> String {
        guard let style else { return String(localized: "Style") }
        return switch style {
        case .body: String(localized: "Body")
        case .heading(1): String(localized: "Title")
        case .heading(2): String(localized: "Heading")
        case .heading: String(localized: "Subheading")
        case .mono: String(localized: "Mono")
        case .bullet: String(localized: "List")
        case .number: String(localized: "List")
        case .checklist: String(localized: "Checklist")
        case .quote: String(localized: "Quote")
        }
    }

    /// Glyphs for the bar and the format row (SF Symbols; the engine's names are the
    /// menus' images).
    static func symbol(_ command: NoteFormatCommand) -> String {
        switch command {
        case .mark(.link): "link"
        case .mark(.highlight): "highlighter"
        case .paragraph(.checklist): "checklist"
        case .table: "tablecells"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        default: command.symbolName
        }
    }

    // MARK: Keys

    /// Chords macOS reserves in every app (⌥⌘Q Quit and Keep Windows,
    /// ⌥⌘M Minimize All): never bound or shown, whatever the engine says
    /// (Astra A11). Quote and Mono use the owner's ⌥⌘4/5 instead.
    static let reservedChords: Set<String> = ["⌥⌘Q", "⌥⌘M"]

    /// The keyboard shortcut of each command, read from the engine's own
    /// metadata (`NoteFormatCommand.shortcut`, e.g. "⇧⌘7", "⌘Return",
    /// "⌥⌘↑"), so menus, tooltips and keys never keep a second table.
    static func keyboardShortcut(_ command: NoteFormatCommand) -> KeyboardShortcut? {
        guard let label = command.shortcut, !reservedChords.contains(label) else { return nil }
        return parseShortcut(label)
    }

    /// "⌃⌥⇧⌘" then one key: a character, "Return", "↑" or "↓".
    static func parseShortcut(_ label: String) -> KeyboardShortcut? {
        var modifiers: SwiftUI.EventModifiers = []
        var rest = Substring(label)
        let symbols: [(Character, SwiftUI.EventModifiers)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let first = rest.first, let match = symbols.first(where: { $0.0 == first }) {
            modifiers.insert(match.1)
            rest = rest.dropFirst()
        }
        guard !modifiers.isEmpty, !rest.isEmpty else { return nil }
        let key: KeyEquivalent
        switch rest {
        case "Return", "↩": key = .return
        case "↑": key = .upArrow
        case "↓": key = .downArrow
        case "←": key = .leftArrow
        case "→": key = .rightArrow
        default:
            guard rest.count == 1, let character = rest.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// The shortcut as menus print it, or nil when unbound.
    static func shortcutLabel(_ command: NoteFormatCommand) -> String? {
        keyboardShortcut(command) == nil ? nil : command.shortcut
    }

    /// The command a key press means, matched on the key as printed
    /// without modifiers (so ⇧⌘7 is "7", not "&").
    static func command(for event: NSEvent) -> NoteFormatCommand? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags.contains(.command) else { return nil }
        let plain = (unshiftedKey(for: event) ?? event.characters(byApplyingModifiers: []) ?? "").lowercased()
        let ignoring = (event.charactersIgnoringModifiers ?? "").lowercased()
        for command in allCommands {
            guard let shortcut = keyboardShortcut(command), modifierFlags(shortcut.modifiers) == flags else { continue }
            switch shortcut.key {
            case .return: if event.keyCode == 36 || event.keyCode == 76 { return command }
            case .upArrow: if event.keyCode == 126 { return command }
            case .downArrow: if event.keyCode == 125 { return command }
            default:
                let key = String(shortcut.key.character)
                if plain == key || ignoring == key { return command }
            }
        }
        return nil
    }

    /// Translate the physical event through the active keyboard layout with
    /// no modifiers. Shift and Option digits yield punctuation in NSEvent.characters.
    private static func unshiftedKey(for event: NSEvent) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackDigit(for: event.keyCode)
        }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return fallbackDigit(for: event.keyCode) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var count = 0
        let status = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &dead, chars.count, &count, &chars)
        guard status == noErr, count > 0 else { return fallbackDigit(for: event.keyCode) }
        return String(utf16CodeUnits: chars, count: count).lowercased()
    }

    private static func fallbackDigit(for keyCode: UInt16) -> String? {
        // Only used when the OS exposes no layout data (for example in a
        // headless test host); the normal path translates the active layout.
        switch keyCode {
        case 21: "4"
        case 23: "5"
        case 26: "7"
        case 28: "8"
        case 25: "9"
        default: nil
        }
    }

    static func modifierFlags(_ modifiers: SwiftUI.EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// Aa's format row opens with ⌘T (the system's Show Fonts key, which a
    /// note has no other use for); ⌃Tab reaches the selection bar while one
    /// shows, or the format row while it is open.
    static let formatBarShortcut = KeyboardShortcut("t", modifiers: .command)

    // MARK: The / list

    /// The typing shortcut a `/` row shows (the habits the engine converts
    /// as you type), or the key shortcut when a row has no habit.
    static func slashHint(_ kind: NoteSlashItem.Kind) -> String? {
        switch kind {
        case .checklist: "-[]"
        case .heading: "#"
        case .bullet: "-"
        case .number: "1."
        case .quote: ">"
        case .imageOrFile: String(localized: "paste or drop")
        case .table: "2 × 3"
        case .title, .subheading, .body, .date, .divider, .mono: nil
        }
    }

    static func slashSymbol(_ kind: NoteSlashItem.Kind) -> String {
        switch kind {
        case .checklist: "checklist"
        case .title, .heading, .subheading: "textformat.size"
        case .body: "text.alignleft"
        case .bullet: "list.bullet"
        case .number: "list.number"
        case .imageOrFile: "photo"
        case .date: "calendar"
        case .quote: "text.quote"
        case .divider: "minus"
        case .mono: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        }
    }
}
