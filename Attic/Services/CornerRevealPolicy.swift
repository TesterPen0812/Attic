import AppKit
import CoreGraphics

/// Settings › Panel › Corner (control audit item 10): whether hovering in
/// the corner reveals the panel at all, a key that must be held as the
/// pointer arrives, and which displays' corners answer. The menu bar
/// icon, the quick capture shortcut and every other explicit open are not
/// affected: they always show the panel.

/// The key hover needs (Settings: "Only while holding").
enum RevealModifier: String, CaseIterable, Identifiable, Codable {
    case none, option, control, command, shift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "No Key")
        case .option: String(localized: "⌥ Option")
        case .control: String(localized: "⌃ Control")
        case .command: String(localized: "⌘ Command")
        case .shift: String(localized: "⇧ Shift")
        }
    }

    /// The symbol a sentence uses ("Hold ⌥ …"); nil for none.
    var symbol: String? {
        switch self {
        case .none: nil
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .shift: "⇧"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .none: []
        case .option: .option
        case .control: .control
        case .command: .command
        case .shift: .shift
        }
    }
}

/// Which displays' corners reveal the panel.
enum RevealDisplays: String, CaseIterable, Identifiable, Codable {
    case all, selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All Displays")
        case .selected: String(localized: "Selected Displays")
        }
    }
}

/// The hover rule, pure so it is unit-tested: `CornerHoverMonitor` asks it
/// on every sample, with the display under the pointer and the modifier
/// keys held at that moment.
struct CornerRevealPolicy: Equatable {
    var revealsOnHover = true
    var modifier: RevealModifier = .none
    var displays: RevealDisplays = .all
    var selectedDisplayIDs: Set<String> = []

    /// Whether the corner of the display `displayID` answers hover at all
    /// (the sampling cadence near a corner follows this).
    func answers(displayID: String?) -> Bool {
        guard revealsOnHover else { return false }
        switch displays {
        case .all: return true
        case .selected: return displayID.map(selectedDisplayIDs.contains) ?? false
        }
    }

    /// Whether a pointer in the corner of `displayID`, with `flags` held,
    /// counts as in the hotspot. The key must be held when the reveal
    /// happens: released during the reveal delay, nothing opens.
    func reveals(displayID: String?, flags: NSEvent.ModifierFlags) -> Bool {
        answers(displayID: displayID) && flags.intersection(.deviceIndependentFlagsMask).contains(modifier.flags)
    }
}

/// A display as Settings lists it: a stable identifier (the display's
/// UUID, the same across launches and cables) and its name.
struct AtticDisplay: Identifiable, Equatable {
    let id: String
    let name: String

    /// Every connected display, in the system's order.
    @MainActor
    static func connected() -> [AtticDisplay] {
        NSScreen.screens.compactMap { screen in
            identifier(for: screen).map { AtticDisplay(id: $0, name: screen.localizedName) }
        }
    }

    /// The display's stable identifier, or nil when it has none.
    static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
