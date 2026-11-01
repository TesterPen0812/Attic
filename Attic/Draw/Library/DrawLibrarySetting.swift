import Foundation

/// Whether Draw shows at all: the defaults key `AtticDraw.enabled` (Bool,
/// default off), the same key the Draw page reads through
/// `AtticDraw.isEnabled`. While it is off, nothing of the library shows:
/// no canvas menu rows, no Search results, nothing in Recently Deleted.
enum DrawLibrarySetting {
    static let key = "AtticDraw.enabled"
    /// Tests state the setting here instead of writing any defaults.
    @MainActor static var override: Bool?

    @MainActor static var isEnabled: Bool {
        override ?? UserDefaults.standard.bool(forKey: key)
    }
}

/// The session's one Draw store, as the library's other surfaces (Search,
/// Recently Deleted in Settings) reach it. Whoever keeps the store alive
/// above page and panel switches registers it here; the hub holds it weakly
/// and hands it out only while Draw is enabled.
@MainActor
enum DrawLibraryHub {
    private static weak var registered: (any DrawStoreProtocol)?

    static func register(_ store: (any DrawStoreProtocol)?) {
        registered = store
    }

    /// The store, or nil while Draw is off or no store is alive.
    static var activeStore: (any DrawStoreProtocol)? {
        DrawLibrarySetting.isEnabled ? registered : nil
    }
}
