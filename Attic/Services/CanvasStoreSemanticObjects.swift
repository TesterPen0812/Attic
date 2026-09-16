import Foundation
import SwiftData

enum CanvasSemanticError: LocalizedError {
    case unavailable, invalidContent, missingObject
    var errorDescription: String? {
        switch self {
        case .unavailable: "Editable objects are unavailable in this canvas store."
        case .invalidContent: "The canvas object has invalid content or dimensions."
        case .missingObject: "The canvas object is no longer available."
        }
    }
}

extension CanvasStore {
    var supportsSemanticObjects: Bool {
        container.schema.entities.contains { $0.name == "CanvasSemanticObjectItem" }
    }

    static func winningSemanticReplica(_ rows: [CanvasSemanticObjectItem]) -> CanvasSemanticObjectItem? {
        rows.max { lhs, rhs in
            if lhs.mutationVersion != rhs.mutationVersion { return lhs.mutationVersion < rhs.mutationVersion }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.tombstoned != rhs.tombstoned { return !lhs.tombstoned }
            if lhs.boardGeneration != rhs.boardGeneration { return lhs.boardGeneration < rhs.boardGeneration }
            if lhs.payload != rhs.payload { return lhs.payload.lexicographicallyPrecedes(rhs.payload) }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.payloadVersion != rhs.payloadVersion { return lhs.payloadVersion < rhs.payloadVersion }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            if lhs.centerX != rhs.centerX { return lhs.centerX < rhs.centerX }
            if lhs.centerY != rhs.centerY { return lhs.centerY < rhs.centerY }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            if lhs.rotation != rhs.rotation { return lhs.rotation < rhs.rotation }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return String(reflecting: lhs.persistentModelID) < String(reflecting: rhs.persistentModelID)
        }
    }

    func storedSemanticReplicas(canvasID: UUID) throws -> [CanvasSemanticObjectItem] {
        guard supportsSemanticObjects else { return [] }
        let targetID = canvasID
        return try context.fetchCanvasReplicas(FetchDescriptor<CanvasSemanticObjectItem>(
            predicate: #Predicate { $0.canvasID == targetID }
        ))
    }

    @discardableResult
    func addSemanticObject(content: CanvasSemanticContent, transform: CanvasImageTransform) -> CanvasSemanticObject? {
        guard supportsSemanticObjects, content.isValid, transform.isValid else {
            lastErrorMessage = CanvasSemanticError.invalidContent.localizedDescription
            return nil
        }
        do {
            let timestamp = now()
            try ensureSelectedBoardReplicaExists(at: timestamp)
            let row = CanvasSemanticObjectItem(canvasID: selectedCanvasID)
            row.kind = content.text == nil ? "shape" : "text"
            row.payload = try JSONEncoder().encode(content)
            row.centerX = transform.center.x
            row.centerY = transform.center.y
            row.width = transform.width
            row.height = transform.height
            row.zIndex = transform.zIndex
            row.boardGeneration = boardGeneration
            row.createdAt = timestamp
            row.updatedAt = timestamp
            context.insert(row)
            let id = row.id
            guard save().succeeded else { return nil }
            return semanticObjects.first { $0.id == id }
        } catch {
            discardPendingChanges(after: error)
            return nil
        }
    }

    @discardableResult
    func updateSemanticObject(_ snapshot: CanvasSemanticObject) -> Bool {
        do {
            guard try storedSemanticReplicas(canvasID: selectedCanvasID).contains(where: { $0.id == snapshot.id }) else {
                throw CanvasSemanticError.missingObject
            }
            try stageSemanticRestore([snapshot], at: now())
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save().succeeded
    }

    func stageSemanticRestore(_ snapshots: [CanvasSemanticObject], at timestamp: Date) throws {
        guard !snapshots.isEmpty else { return }
        guard supportsSemanticObjects else { throw CanvasSemanticError.unavailable }
        let groups = Dictionary(grouping: try storedSemanticReplicas(canvasID: selectedCanvasID), by: \.id)
        for snapshot in snapshots {
            guard snapshot.canvasID == selectedCanvasID, snapshot.transform.isValid,
                  snapshot.rotation.isFinite else { throw CanvasSemanticError.invalidContent }
            let rows = groups[snapshot.id] ?? []
            let version = try Self.nextMutationVersion(
                after: max(snapshot.mutationVersion, rows.map(\.mutationVersion).max() ?? 0),
                objectID: snapshot.id
            )
            let targets: [CanvasSemanticObjectItem]
            if rows.isEmpty {
                let row = CanvasSemanticObjectItem(id: snapshot.id, canvasID: selectedCanvasID)
                context.insert(row)
                targets = [row]
            } else { targets = rows }
            for row in targets {
                applySemanticSnapshot(snapshot, to: row)
                row.boardGeneration = boardGeneration
                row.mutationVersion = version
                row.tombstoned = false
                row.updatedAt = timestamp
                row.deletedAt = nil
            }
        }
    }

    @discardableResult
    func deleteSemanticObject(_ id: UUID) -> Bool {
        do {
            let rows = try storedSemanticReplicas(canvasID: selectedCanvasID).filter { $0.id == id }
            guard let winner = Self.winningSemanticReplica(rows) else { throw CanvasSemanticError.missingObject }
            try stageSemanticTombstone(rows, winner: winner, at: now())
        } catch {
            discardPendingChanges(after: error)
            return false
        }
        return save().succeeded
    }

    func tombstoneSemanticObjects(canvasID: UUID, at timestamp: Date) throws {
        let groups = Dictionary(grouping: try storedSemanticReplicas(canvasID: canvasID), by: \.id)
        for rows in groups.values {
            if let winner = Self.winningSemanticReplica(rows) {
                try stageSemanticTombstone(rows, winner: winner, at: timestamp)
            }
        }
    }

    private func stageSemanticTombstone(_ rows: [CanvasSemanticObjectItem], winner: CanvasSemanticObjectItem, at timestamp: Date) throws {
        let snapshot = CanvasSemanticObject(winner)
        let version = try Self.nextMutationVersion(after: rows.map(\.mutationVersion).max() ?? 0, objectID: winner.id)
        for row in rows {
            applySemanticSnapshot(snapshot, to: row)
            row.mutationVersion = version
            row.tombstoned = true
            row.updatedAt = timestamp
            row.deletedAt = timestamp
        }
    }

    private func applySemanticSnapshot(_ snapshot: CanvasSemanticObject, to row: CanvasSemanticObjectItem) {
        row.kind = snapshot.kind
        row.payloadVersion = snapshot.payloadVersion
        row.payload = snapshot.payload
        row.centerX = snapshot.transform.center.x
        row.centerY = snapshot.transform.center.y
        row.width = snapshot.transform.width
        row.height = snapshot.transform.height
        row.zIndex = snapshot.transform.zIndex
        row.rotation = snapshot.rotation
        row.boardGeneration = snapshot.boardGeneration
        row.createdAt = snapshot.createdAt
    }
}
