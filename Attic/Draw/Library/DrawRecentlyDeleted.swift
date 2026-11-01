import Foundation

/// A Draw deletion as Recently Deleted lists it: a deleted canvas, or an
/// image deleted from a live canvas (D11).
struct DrawDeletedItem: Equatable, Sendable {
    let canvasID: UUID
    /// The image; nil for the canvas itself.
    let objectID: UUID?
}

/// Recently Deleted's Draw rows, read from the store's `library(deleted:)`
/// and `deletedImages(in:)`, restored through `restoreCanvas` and
/// `restoreObjects`. The store has no permanent delete yet, so these rows
/// offer Restore only.
@MainActor
enum DrawRecentlyDeleted {
    static func entries(store: (any DrawStoreProtocol)?, now: Date, calendar: Calendar) -> [RecentlyDeletedEntry] {
        guard let store else { return [] }
        let canvases = ((try? store.library(deleted: true)) ?? []).compactMap { canvas -> RecentlyDeletedEntry? in
            guard let deletedAt = canvas.deletedAt else { return nil }
            return RecentlyDeletedEntry(
                kind: .canvas,
                title: RecentlyDeletedPresentation.displayTitle(canvas.name, kind: .canvas),
                detail: RecentlyDeletedPresentation.deletedPhrase(deletedAt, now: now, calendar: calendar),
                deletedAt: deletedAt,
                ownerTitle: nil,
                source: .draw(DrawDeletedItem(canvasID: canvas.id, objectID: nil))
            )
        }
        // D11: images deleted from a live canvas (a deleted canvas's images
        // come back with it).
        let images = ((try? store.library()) ?? []).flatMap { canvas -> [RecentlyDeletedEntry] in
            let owner = RecentlyDeletedPresentation.displayTitle(canvas.name, kind: .canvas)
            return ((try? store.deletedImages(in: canvas.id)) ?? []).compactMap { image in
                guard let deletedAt = image.deletedAt else { return nil }
                let detail = [String(localized: "From “\(owner)”"),
                              RecentlyDeletedPresentation.deletedPhrase(deletedAt, now: now, calendar: calendar)]
                return RecentlyDeletedEntry(
                    kind: .attachment,
                    title: String(localized: "Image"),
                    detail: detail.joined(separator: " · "),
                    deletedAt: deletedAt,
                    ownerTitle: owner,
                    source: .draw(DrawDeletedItem(canvasID: canvas.id, objectID: image.id))
                )
            }
        }
        return canvases + images
    }

    /// Puts them back, one store command per canvas. Returns how many came
    /// back and the reason for the first that could not, if any.
    static func restore(_ items: [DrawDeletedItem], store: (any DrawStoreProtocol)?) -> (restored: Int, failure: String?) {
        guard let store else { return (0, String(localized: "Draw isn’t available.")) }
        var restored = 0
        var failure: String?
        func settle(_ result: DrawSaveResult, count: Int) {
            switch result {
            case .saved, .unchanged: restored += count
            case let .retry(message), let .held(message): failure = failure ?? message
            }
        }
        var seen = Set<UUID>()
        for item in items where item.objectID == nil && seen.insert(item.canvasID).inserted {
            settle(store.perform(.restoreCanvas, on: item.canvasID), count: 1)
        }
        var images: [UUID: [UUID]] = [:]
        var order: [UUID] = []
        for item in items {
            guard let objectID = item.objectID else { continue }
            if images[item.canvasID] == nil { order.append(item.canvasID) }
            if !(images[item.canvasID]?.contains(objectID) ?? false) { images[item.canvasID, default: []].append(objectID) }
        }
        for canvasID in order {
            let ids = images[canvasID] ?? []
            settle(store.perform(.restoreObjects(ids), on: canvasID), count: ids.count)
        }
        return (restored, failure)
    }
}
