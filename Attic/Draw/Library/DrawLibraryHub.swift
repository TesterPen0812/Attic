import Foundation

/// The session's one Draw store, as the library's other surfaces (Search,
/// Recently Deleted in Settings) reach it. Whoever keeps the store alive
/// above page and panel switches registers it here; the hub holds it weakly
/// and hands it out only while Draw is enabled (`AtticDraw.isEnabled`): while
/// it is off, nothing of the library shows, Search and Recently Deleted
/// included.
@MainActor
enum DrawLibraryHub {
    private static weak var registered: (any DrawStoreProtocol)?

    static func register(_ store: (any DrawStoreProtocol)?) {
        registered = store
    }

    /// The store, or nil while Draw is off or no store is alive.
    static var activeStore: (any DrawStoreProtocol)? {
        AtticDraw.isEnabled ? registered : nil
    }
}
