import Foundation
import CryptoKit
import SwiftData

/// Immutable changed-field handles, not a board snapshot or copied originals.
final class CanvasCoreFields {
    let values: [String: Data]
    init(_ values: [String: Data]) { self.values = values }
}
struct CanvasCorePatch {
    let owner: WorkspaceOwner
    let canvasID: UUID
    let physicalID: PersistentIdentifier?
    let fields: CanvasCoreFields
    let inserting: Bool
    init(owner: WorkspaceOwner, canvasID: UUID, physicalID: PersistentIdentifier? = nil,
         fields: [String: Data], inserting: Bool = false) {
        self.owner = owner; self.canvasID = canvasID; self.physicalID = physicalID
        self.fields = CanvasCoreFields(fields); self.inserting = inserting
    }
}

@MainActor
final class CanvasCoreWriter {
    struct Counters: Equatable {
        var fetchedReplicas = 0
        var fetchedFamilies = 0
        var changedReplicas = 0
        var saves = 0
        var publications = 0
    }
    struct Entry {
        let name: String
        let undo: [CanvasCorePatch]
        let redo: [CanvasCorePatch]
        let barrier: String?
    }
    private struct Pending {
        let name: String
        let patches: [CanvasCorePatch]
        let inverse: [CanvasCorePatch]
        let origin: String?
        let cursor: Int?
        let owners: Set<WorkspaceOwner>
    }
    let gate: WorkspaceOperationCoordinator
    private(set) var tokens: [WorkspaceOwner: WorkspaceModelToken] = [:]
    private(set) var history: [Entry] = []
    private(set) var cursor = 0
    private(set) var counters = Counters()
    private var pending: Pending?
    private var pendingTruthConfirmed = false
    var hasUnresolvedOutcome: Bool { pending != nil }
    var barrierReason: String? { cursor > 0 ? history[cursor - 1].barrier : nil }
    var canUndo: Bool { cursor > 0 && barrierReason == nil && pending == nil }
    var canRedo: Bool { cursor < history.count && pending == nil }
    init(gate: WorkspaceOperationCoordinator) { self.gate = gate }
    func resetCounters() { counters = Counters() }

    /// Explicit affected-family read, used when a scalar session opens an
    /// object. No eager board/default creation occurs in this type.
    func capture(_ owners: Set<WorkspaceOwner>) throws {
        let context = gate.freshContext()
        tokens.merge(try read(owners, context: context)) { _, value in value }
    }
    private func read(_ owners: Set<WorkspaceOwner>, context: ModelContext) throws -> [WorkspaceOwner: WorkspaceModelToken] {
        var result: [WorkspaceOwner: WorkspaceModelToken] = [:]
        let list = Array(owners)
        for start in stride(from: 0, to: list.count, by: 128) {
            let batch = Set(list[start..<min(start + 128, list.count)])
            let values = try WorkspaceModelToken.read(owners: batch, in: context)
            counters.fetchedFamilies += batch.count
            counters.fetchedReplicas += values.values.reduce(0) { $0 + $1.replicas.count }
            result.merge(values) { _, value in value }
        }
        return result
    }
    @discardableResult
    func perform(name: String, patches: [CanvasCorePatch], origin: String? = nil,
                 cursor nextCursor: Int? = nil) -> WorkspaceOperationCoordinator.Outcome {
        guard pending == nil, !patches.isEmpty else { return pending == nil ? .notCommitted : .unknown }
        let owners = Set(patches.map(\.owner))
        let boardGuards = Set(patches.map { WorkspaceOwner(entity: .board, id: $0.canvasID) })
        let reads = owners.union(boardGuards)
        let context = gate.freshContext()
        var inverse: [CanvasCorePatch] = []
        do {
            let before = try read(reads, context: context)
            for owner in reads {
                let expected = tokens[owner] ?? .init(owner: owner, replicas: [])
                guard before[owner] == expected else { return .conflict }
            }
            for guardOwner in boardGuards where !owners.contains(guardOwner) {
                let boards = before[guardOwner]!.replicas.compactMap { context.model(for: $0.physicalID) as? CanvasBoardItem }
                guard !boards.isEmpty, !CanvasStore.winningBoardReplica(in: boards).tombstoned else { return .conflict }
            }
            for patch in patches {
                let family = before[patch.owner]!
                var rows = family.replicas.map { context.model(for: $0.physicalID) }.filter {
                    Self.belongs($0, canvasID: patch.canvasID) && (patch.physicalID == nil || $0.persistentModelID == patch.physicalID)
                }
                if patch.inserting {
                    guard rows.isEmpty else { return .conflict }
                    let row: any PersistentModel
                    let parentOwner = WorkspaceOwner(entity: .board, id: patch.canvasID)
                    let parentRows = before[parentOwner]?.replicas.compactMap { context.model(for: $0.physicalID) as? CanvasBoardItem } ?? []
                    let generation = parentRows.isEmpty ? 0 : CanvasStore.winningBoardReplica(in: parentRows).clearGeneration
                    switch patch.owner.entity {
                    case .board: row = CanvasBoardItem(id: patch.owner.id, name: "Untitled canvas")
                    case .stroke: row = CanvasStrokeItem(id: patch.owner.id, canvasID: patch.canvasID, boardGeneration: generation)
                    case .semantic:
                        let semantic = CanvasSemanticObjectItem(id: patch.owner.id, canvasID: patch.canvasID)
                        semantic.boardGeneration = generation; row = semantic
                    default: throw CanvasCoreError.conflict
                    }
                    context.insert(row); rows = [row]
                    inverse.append(.init(owner: patch.owner, canvasID: patch.canvasID,
                        fields: ["tombstoned": try WorkspaceModelFields.encode(true), "deletedAt": try WorkspaceModelFields.encode(Optional(Date()))]))
                } else {
                    guard !rows.isEmpty else { return .conflict }
                    for row in rows {
                        inverse.append(.init(owner: patch.owner, canvasID: patch.canvasID, physicalID: row.persistentModelID,
                            fields: try WorkspaceModelFields.patchValues(Set(patch.fields.values.keys), from: row)))
                    }
                }
                let maxVersion = rows.map(Self.version).max() ?? 0
                guard maxVersion < Int64.max else { throw CanvasCoreError.overflow }
                for row in rows {
                    if !patch.inserting,
                       try WorkspaceModelFields.patchValues(Set(patch.fields.values.keys), from: row) == patch.fields.values { continue }
                    try WorkspaceModelFields.apply(patch.fields.values, to: row)
                    try WorkspaceModelFields.apply(["mutationVersion": try WorkspaceModelFields.encode(maxVersion + 1),
                        "updatedAt": try WorkspaceModelFields.encode(Date())], to: row)
                }
            }
            guard !context.insertedModelsArray.isEmpty || !context.changedModelsArray.isEmpty else { return .notCommitted }
            let models = try WorkspaceModelToken.stagedModels(owners: owners, before: before, in: context)
            let after = try WorkspaceModelToken.capture(owners: owners, models: models)
            // Phase 3 reconciliation compares ordered family-state arrays.
            // Dictionary iteration order cannot determine save-then-throw truth.
            let order = owners.sorted { ($0.entity.rawValue, $0.id.uuidString) < ($1.entity.rawValue, $1.id.uuidString) }
            let readOrder = reads.sorted { ($0.entity.rawValue, $0.id.uuidString) < ($1.entity.rawValue, $1.id.uuidString) }
            let previous = readOrder.map { before[$0]! }, next = order.map { after[$0]! }
            guard try gate.mayUsePlainSave(before: previous, after: next, in: context) else { return .conflict }
            counters.changedReplicas = context.insertedModelsArray.count + context.changedModelsArray.count
            let prepared = Pending(name: name, patches: patches, inverse: inverse, origin: origin, cursor: nextCursor, owners: owners)
            let result = gate.commitInPlace(context, before: previous, requiredScopes: [], scopes: { [] }, after: next,
                capturedOwners: owners, using: { context in self.counters.saves += 1; try self.gate.save(context) },
                confirmed: { confirmed in self.tokens.merge(confirmed) { _, value in value } })
            switch result {
            case .committed: publish(prepared)
            case .unknown: pending = prepared
            default: context.rollback()
            }
            return result
        } catch { context.rollback(); return .notCommitted }
    }
    /// Reconciliation is confined to the held families. A retry never allocates
    /// a new board/object ID or runs a second inverse after save-then-throw.
    func resolve() -> WorkspaceOperationCoordinator.Outcome {
        guard let held = pending else { return .conflict }
        let outcome: WorkspaceOperationCoordinator.Outcome = pendingTruthConfirmed ? .committed : gate.reconcilePlain()
        if outcome == .committed {
            pendingTruthConfirmed = true
            do { try capture(held.owners) } catch { return .unknown }
            pending = nil; pendingTruthConfirmed = false; publish(held)
        } else if outcome == .notCommitted { pending = nil; pendingTruthConfirmed = false }
        return outcome
    }
    private func publish(_ command: Pending) {
        counters.publications += 1
        if let next = command.cursor { cursor = next; return }
        history.removeSubrange(cursor..<history.count)
        if let origin = command.origin {
            history.append(.init(name: command.name, undo: [], redo: [], barrier: "Edited by \(origin): can't undo past this"))
        } else {
            let redo = command.patches.map { patch in
                // Undo of insertion retains exact canonical bytes as a tombstone.
                patch.inserting ? CanvasCorePatch(owner: patch.owner, canvasID: patch.canvasID,
                    fields: ["tombstoned": (try? WorkspaceModelFields.encode(false)) ?? Data(),
                             "deletedAt": (try? WorkspaceModelFields.encode(Optional<Date>.none)) ?? Data()]) : patch
            }
            history.append(.init(name: command.name, undo: command.inverse, redo: redo, barrier: nil))
        }
        cursor = history.count
    }
    func undo() -> WorkspaceOperationCoordinator.Outcome {
        guard canUndo else { return .conflict }
        let entry = history[cursor - 1]
        return perform(name: entry.name, patches: entry.undo, cursor: cursor - 1)
    }
    func redo() -> WorkspaceOperationCoordinator.Outcome {
        guard canRedo else { return .conflict }
        let entry = history[cursor]
        return perform(name: entry.name, patches: entry.redo, cursor: cursor + 1)
    }
    private static func belongs(_ row: any PersistentModel, canvasID: UUID) -> Bool {
        switch row {
        case let row as CanvasBoardItem: row.id == canvasID
        case let row as CanvasStrokeItem: row.canvasID == canvasID
        case let row as CanvasSemanticObjectItem: row.canvasID == canvasID
        case let row as CanvasImageItem: row.canvasID == canvasID
        default: false
        }
    }
    private static func version(_ row: any PersistentModel) -> Int64 {
        switch row {
        case let row as CanvasBoardItem: row.mutationVersion
        case let row as CanvasStrokeItem: row.mutationVersion
        case let row as CanvasSemanticObjectItem: row.mutationVersion
        case let row as CanvasImageItem: row.mutationVersion
        default: Int64.max
        }
    }
    static func inkPatch(id: CanvasCoreID, ink: CanvasCoreInk) throws -> CanvasCorePatch {
        let bytes = try CanvasCoreInkCodec.encode(ink)
        let xs = ink.samples.map(\.x), ys = ink.samples.map(\.y), radius = ink.width / 2
        return .init(owner: .init(entity: .stroke, id: id.objectID), canvasID: id.canvasID, fields: [
            "payloadVersion": try WorkspaceModelFields.encode(2),
            "binaryPayload": try WorkspaceModelFields.encode(Optional(bytes)),
            "binaryDigest": try WorkspaceModelFields.encode(Optional(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())),
            "boundsMinX": try WorkspaceModelFields.encode(Optional(xs.min()! - radius)),
            "boundsMinY": try WorkspaceModelFields.encode(Optional(ys.min()! - radius)),
            "boundsMaxX": try WorkspaceModelFields.encode(Optional(xs.max()! + radius)),
            "boundsMaxY": try WorkspaceModelFields.encode(Optional(ys.max()! + radius))
        ], inserting: true)
    }
    static func semanticPatch(id: CanvasCoreID, content: CanvasCoreSemanticContract,
                              bounds: CanvasCoreBounds, inserting: Bool) throws -> CanvasCorePatch {
        guard bounds.valid else { throw CanvasCoreError.invalidGeometry }
        return .init(owner: .init(entity: .semantic, id: id.objectID), canvasID: id.canvasID, fields: [
            "payload": try WorkspaceModelFields.encode(content.encode()),
            "kind": try WorkspaceModelFields.encode(content.text == nil ? "shape" : "text"),
            "centerX": try WorkspaceModelFields.encode((bounds.minX + bounds.maxX) / 2),
            "centerY": try WorkspaceModelFields.encode((bounds.minY + bounds.maxY) / 2),
            "width": try WorkspaceModelFields.encode(bounds.maxX - bounds.minX),
            "height": try WorkspaceModelFields.encode(bounds.maxY - bounds.minY)
        ], inserting: inserting)
    }
}

/// A provisional ID is allocated once. Empty drafts/open/New do not issue a
/// command; first content supplies this board patch in the same gated save.
struct CanvasCoreCreation {
    let boardID: UUID
    let firstObjectID: UUID
    init(boardID: UUID = UUID(), firstObjectID: UUID = UUID()) { self.boardID = boardID; self.firstObjectID = firstObjectID }
    @MainActor func firstInk(_ ink: CanvasCoreInk) throws -> [CanvasCorePatch] {
        let content = try CanvasCoreWriter.inkPatch(id: .init(canvasID: boardID, objectID: firstObjectID), ink: ink)
        return firstContent(content)
    }
    /// An image import supplies the same declared board+object write set to
    /// the shared journal (slice 3); it cannot enter this ordinary writer.
    func firstContent(_ content: CanvasCorePatch) -> [CanvasCorePatch] {
        guard content.canvasID == boardID, content.owner.id == firstObjectID, content.inserting else { return [] }
        return [.init(owner: .init(entity: .board, id: boardID), canvasID: boardID, fields: [:], inserting: true), content]
    }
}
