import Foundation

/// The Draw page's switch-over setting. Off by default: the old Canvas page
/// keeps the fourth page until job 3 turns this on. The library builder reads
/// the same key.
enum AtticDraw {
    static let enabledKey = "AtticDraw.enabled"

    #if DEBUG
    /// Tests only: stands in for the defaults value.
    nonisolated(unsafe) static var enabledOverride: Bool?
    #endif

    static var isEnabled: Bool {
        #if DEBUG
        if let enabledOverride { return enabledOverride }
        #endif
        return UserDefaults.standard.bool(forKey: enabledKey)
    }
}
