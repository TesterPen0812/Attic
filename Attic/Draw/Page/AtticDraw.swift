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
        // `bool(forKey:)` also reads a launch argument's "NO".
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    /// Read once: the switch takes effect at the next launch, so the store,
    /// the page and the old Canvas's dormancy all agree for the whole run.
    private static let launchValue = value(in: .standard)

    static var isEnabled: Bool {
        #if DEBUG
        if let enabledOverride { return enabledOverride }
        #endif
        return launchValue
    }
}

/// The old Canvas rows while Draw has Canvas's place: a container marked
/// dormant has its `Canvas*` rows left untouched and unread (owner,
/// 18 Oct: "the new Canvas just doesn't read them"). Nothing migrates,
/// converts, rewrites or deletes them.
enum AtticLegacyCanvas {
    private final class Entry: @unchecked Sendable {
        weak var container: ModelContainer?
        init(_ container: ModelContainer) { self.container = container }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []

    /// Marks the app's container: its old Canvas rows are not to be read.
    static func markDormant(_ container: ModelContainer) {
        lock.withLock {
            entries.removeAll { $0.container == nil }
            guard !entries.contains(where: { $0.container === container }) else { return }
            entries.append(Entry(container))
        }
    }

    static func isDormant(_ container: ModelContainer) -> Bool {
        lock.withLock { entries.contains { $0.container === container } }
    }

    /// Whether this context's container is dormant.
    static func isDormant(_ context: ModelContext) -> Bool {
        isDormant(context.container)
    }
}
