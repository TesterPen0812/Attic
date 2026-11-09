import Foundation

/// A Draw deletion as Recently Deleted lists it: a deleted canvas, or an
/// image deleted from a live canvas (D11).
struct DrawDeletedItem: Equatable, Sendable {
    let canvasID: UUID
    /// The image; nil for the canvas itself.
    let objectID: UUID?
}

/// Recently Deleted's Draw rows, read from the store's `library(deleted:)`
/// and `deletedImages()`, restored through `restoreCanvas` and
/// `restoreObjects`, and removed for good through `purge`.
@MainActor
enum DrawRecentlyDeleted {
    struct RestoreAction {
        let canvasID: UUID
        let historyStepID: UUID
    }

    struct RestoreResult {
        var restored: Int
        var failure: String?
        var actions: [RestoreAction]
    }

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
        // come back with it), from the store's metadata only.
        let images = ((try? store.deletedImages()) ?? []).compactMap { image -> RecentlyDeletedEntry? in
            guard let deletedAt = image.object.deletedAt else { return nil }
            let owner = RecentlyDeletedPresentation.displayTitle(image.canvas.name, kind: .canvas)
            let detail = [String(localized: "From “\(owner)”"),
                          RecentlyDeletedPresentation.deletedPhrase(deletedAt, now: now, calendar: calendar)]
            return RecentlyDeletedEntry(
                kind: .attachment,
                title: String(localized: "Image"),
                detail: detail.joined(separator: " · "),
                deletedAt: deletedAt,
                ownerTitle: owner,
                source: .draw(DrawDeletedItem(canvasID: image.canvas.id, objectID: image.object.id))
            )
        }
        return canvases + images
    }

    /// The daily cleanup's Draw half (`DailyCleanupService`): what has been
    /// in Recently Deleted for 30 days goes for good.
    @discardableResult
    static func purgeExpired(store: (any DrawStoreProtocol)?, now: Date, calendar: Calendar) -> DrawPurgeReport {
        store?.purge(deletedBefore: RecentlyDeletedPolicy.purgeCutoff(now: now, calendar: calendar)) ?? DrawPurgeReport()
    }

    /// Delete Permanently and Empty: exactly these rows, at the deletion
    /// times the confirmation counted.
    @discardableResult
    static func purge(_ items: [(item: DrawDeletedItem, deletedAt: Date)], store: (any DrawStoreProtocol)?) -> DrawPurgeReport {
        guard let store, !items.isEmpty else { return DrawPurgeReport(removed: 0, kept: items.count) }
        return store.purge(items.map { entry in
            entry.item.objectID.map { .image(canvas: entry.item.canvasID, object: $0, deletedAt: entry.deletedAt) }
                ?? .canvas(entry.item.canvasID, deletedAt: entry.deletedAt)
        })
    }

    /// Puts them back, one store command per canvas. Returns how many came
    /// back and the reason for the first that could not, if any.
    static func restore(_ items: [DrawDeletedItem], store: (any DrawStoreProtocol)?) -> (restored: Int, failure: String?) {
        let result = restoreTracked(items, store: store)
        return (result.restored, result.failure)
    }

    /// Successful Draw commands carry their exact Undo identity into the
    /// one-step Recently Deleted history, including multiple canvases.
    static func restoreTracked(_ items: [DrawDeletedItem], store: (any DrawStoreProtocol)?) -> RestoreResult {
        guard let store else { return RestoreResult(restored: 0, failure: String(localized: "Draw isn’t available."), actions: []) }
        var restored = 0
        var failure: String?
        var actions: [RestoreAction] = []
        func settle(_ result: DrawSaveResult, canvasID: UUID, count: Int) {
            switch result {
            case .saved:
                restored += count
                if let stepID = store.undoStepID(on: canvasID) {
                    actions.append(RestoreAction(canvasID: canvasID, historyStepID: stepID))
                }
            case .unchanged: restored += count
            case let .retry(message), let .held(message): failure = failure ?? message
            }
        }
        var seen = Set<UUID>()
        for item in items where item.objectID == nil && seen.insert(item.canvasID).inserted {
            settle(store.perform(.restoreCanvas, on: item.canvasID), canvasID: item.canvasID, count: 1)
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
            settle(store.perform(.restoreObjects(ids), on: canvasID), canvasID: canvasID, count: ids.count)
        }
        return RestoreResult(restored: restored, failure: failure, actions: actions)
    }
}

/// A mixed Restore Selected is one library-history step. Individual saved
/// Draw steps retain their own per-canvas history; the token check prevents
/// undoing unrelated Draw edits made after the restore. A failed member
/// compensates previously applied members and keeps this group retryable.
@MainActor
enum RecentlyDeletedRestoreUndo {
    private enum MemberResult {
        case changed
        case alreadyApplied
        case failed
    }

    private struct Member {
        let undo: @MainActor () -> MemberResult
        let redo: @MainActor () -> MemberResult
    }

    static func make(drawStore: (any DrawStoreProtocol)?, actions: [DrawRecentlyDeleted.RestoreAction],
                     librarySteps: [UndoStep], restored: Int) -> UndoStep? {
        guard !actions.isEmpty || !librarySteps.isEmpty else { return nil }
        if actions.isEmpty, librarySteps.count == 1 { return librarySteps[0] }

        var members: [Member] = []
        if let drawStore {
            for action in actions {
                members.append(Member(
                    undo: {
                        guard drawStore.pendingEdits[action.canvasID] == nil else { return .failed }
                        if drawStore.redoStepID(on: action.canvasID) == action.historyStepID {
                            return .alreadyApplied // A previously failed Undo settled through Retry.
                        }
                        guard drawStore.undoStepID(on: action.canvasID) == action.historyStepID else { return .failed }
                        return drawStore.undo(on: action.canvasID).isSaved ? .changed : .failed
                    },
                    redo: {
                        guard drawStore.pendingEdits[action.canvasID] == nil else { return .failed }
                        if drawStore.undoStepID(on: action.canvasID) == action.historyStepID {
                            return .alreadyApplied
                        }
                        guard drawStore.redoStepID(on: action.canvasID) == action.historyStepID else { return .failed }
                        return drawStore.redo(on: action.canvasID).isSaved ? .changed : .failed
                    }
                ))
            }
        }
        members += librarySteps.map { step in Member(
            undo: { step.undo() == .applied ? .changed : .failed },
            redo: { step.redo() == .applied ? .changed : .failed }
        ) }
        let drawRefs = Set(actions.map { AtticItemRef(.canvas, $0.canvasID) })

        func replay(undo: Bool) -> UndoOutcome {
            let ordered = undo ? Array(members.reversed()) : members
            var changed: [Member] = []
            for member in ordered {
                let outcome = undo ? member.undo() : member.redo()
                switch outcome {
                case .changed:
                    changed.append(member)
                case .alreadyApplied:
                    continue
                case .failed:
                    // Compensate only changes made in this replay; a Draw step
                    // settled before this attempt must not be reversed here.
                    for previous in changed.reversed() {
                        _ = undo ? previous.redo() : previous.undo()
                    }
                    return .failed
                }
            }
            return .applied
        }

        return UndoStep(
            name: RecentlyDeletedPresentation.restoreTitle(count: restored),
            lifecycle: .restore,
            items: { drawRefs.union(librarySteps.reduce(into: Set<AtticItemRef>()) { $0.formUnion($1.affectedItems()) }) },
            undoOutcome: { replay(undo: true) },
            redoOutcome: { replay(undo: false) }
        )
    }
}
