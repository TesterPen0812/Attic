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
    private struct Page {
        weak var model: DrawPageModel?
    }
    private static var pages: [Page] = []

    static func register(_ page: DrawPageModel) {
        pages.removeAll { $0.model == nil }
        pages.append(Page(model: page))
    }

    /// Agent snapshots must include input still waiting for the page's
    /// bounded save timers. Match the actual store, including injected stores.
    static func flushLiveInput(for store: any DrawStoreProtocol) {
        pages.removeAll { $0.model == nil }
        let models = pages.compactMap(\.model).filter { $0.store === store }
        for model in models { model.flushLiveInput() }
    }

    static func register(_ store: (any DrawStoreProtocol)?) {
        registered = store
    }

    /// The store, or nil while Draw is off or no store is alive.
    static var activeStore: (any DrawStoreProtocol)? {
        AtticDraw.isEnabled ? registered : nil
    }
}
