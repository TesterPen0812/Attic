import Foundation
import SwiftData

/// The Draw page's switch-over setting. On by default: the Draw page is the
/// Canvas page. `defaults write <identity> AtticDraw.enabled -bool false`
/// brings back the old Canvas page at the next launch (a hidden escape
/// hatch; there is no Settings UI).
enum AtticDraw {
    static let enabledKey = "AtticDraw.enabled"

    #if DEBUG
    /// Tests only: stands in for the defaults value.
    nonisolated(unsafe) static var enabledOverride: Bool?
    #endif

    /// The setting in these defaults (unset is on).
    static func value(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static var isEnabled: Bool {
        #if DEBUG
        if let enabledOverride { return enabledOverride }
        #endif
        return value(in: .standard)
    }
}

/// The old Canvas rows while Draw has Canvas's place: a container marked
/// dormant has its `Canvas*` rows left untouched and unread (owner,
/// 18 Oct: "the new Canvas just doesn't read them"). Nothing migrates,
/// converts, rewrites or deletes them.
enum AtticLegacyCanvas {
    static func markDormant(_ container: ModelContainer) {}
    static func isDormant(_ container: ModelContainer) -> Bool { false }
}
