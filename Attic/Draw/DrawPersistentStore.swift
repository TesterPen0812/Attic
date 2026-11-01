import Foundation
import SwiftData

/// Instrument actual fetched/written rows and materialised binary bytes, not
/// the size of an open UI snapshot. Reset after fixture construction/opening.
@MainActor
final class DrawSaveMetrics {
    var metadataRowsRead = 0
    var objectRowsRead = 0
    var payloadBytesRead = 0
    var thumbnailBytesRead = 0
    var metadataRowsWritten = 0
    var objectRowsWritten = 0
    var payloadRowsWritten = 0
    var saveAttempts = 0
    func reset() {
        metadataRowsRead = 0; objectRowsRead = 0; payloadBytesRead = 0; thumbnailBytesRead = 0
        metadataRowsWritten = 0; objectRowsWritten = 0; payloadRowsWritten = 0; saveAttempts = 0
    }
}

@MainActor
final class DrawPersistentStore: DrawStore {
    let metrics: DrawSaveMetrics
    /// The app's container it writes to (never one it opened itself).
    let container: ModelContainer
    /// Accept an already-owned app container. This initializer never opens a
    /// path, default store, legacy store, or container on its own.
    init(container: ModelContainer, now: @escaping () -> Date = Date.init,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        let metrics = DrawSaveMetrics()
        self.metrics = metrics
        self.container = container
        super.init(repository: DrawSwiftDataRepository(container: container, metrics: metrics, save: save), now: now)
    }
}

/// Main-actor, synchronous commands serialize across all Draw sessions. There
/// is no await between validation and save; the guard also rejects reentrancy.
@MainActor
final class DrawSwiftDataRepository: DrawRepository {
    private static var writing: Set<ObjectIdentifier> = []
    private let container: ModelContainer
    private let metrics: DrawSaveMetrics
    private let save: (ModelContext) throws -> Void
    private var attempts: [UUID: Attempt] = [:]

    private struct Scope {
        var canvases: [DrawCanvasRecord]
        var objects: [DrawObjectRecord]
        var payloads: [DrawPayloadRecord]
        var thumbnails: [DrawPayloadRecord]
    }
    private struct Physical: Equatable {
        var canvases: [Data]
        var objects: [Data]
        var payloads: [Data]
        var thumbnails: [Data]
    }
    private struct Attempt { var change: DrawChange; var before: Physical; var after: Physical }

    init(container: ModelContainer, metrics: DrawSaveMetrics, save: @escaping (ModelContext) throws -> Void) {
        self.container = container; self.metrics = metrics; self.save = save
    }
    private func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func library() throws -> [DrawCanvas] {
        let context = context()
        let rows = try context.fetch(FetchDescriptor<DrawCanvasRecord>())
        metrics.metadataRowsRead += rows.count
        // Metadata contains no original images or stroke bodies. Only explicitly
        // requested thumbnail rows are materialised during library presentation.
        return try Dictionary(grouping: rows, by: \.id).values.map { replicas in
            let row = try canvasWinner(replicas)
            return try row.value(thumbnail: thumbnail(for: row, in: context))
        }
    }

    func textMatches(_ words: [String], in id: UUID) throws -> [UUID] {
        let context = context()
        let rows = try context.fetch(FetchDescriptor<DrawObjectRecord>(predicate:
            #Predicate { $0.canvasID == id && $0.textIndex != "" }))
        metrics.objectRowsRead += rows.count
        return Dictionary(grouping: rows, by: \.id).values.compactMap { replicas in
            guard let row = objectWinner(replicas), row.deletedAt == nil,
                  words.contains(where: { row.textIndex.localizedStandardContains($0) }) else { return nil }
            return row.id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func load(_ id: UUID) throws -> DrawSnapshot? {
        let context = context()
        let rows = try context.fetch(FetchDescriptor<DrawCanvasRecord>(predicate: #Predicate { $0.id == id }))
        metrics.metadataRowsRead += rows.count
        guard !rows.isEmpty else { return nil }
        let board = try canvasWinner(rows)
        let canvas = try board.value(thumbnail: thumbnail(for: board, in: context))
        let objects = try context.fetch(FetchDescriptor<DrawObjectRecord>(predicate: #Predicate { $0.canvasID == id }))
        metrics.objectRowsRead += objects.count
        let values = try Dictionary(grouping: objects, by: \.id).values.compactMap { replicas -> DrawObject? in
            guard let row = objectWinner(replicas) else { return nil }
            return try objectValue(row, in: context)
        }
        return DrawSnapshot(canvas: canvas, objects: values)
    }

    func write(_ change: DrawChange) -> DrawWriteOutcome {
        let identity = ObjectIdentifier(container)
        guard Self.writing.insert(identity).inserted else { return .held("Another Draw command is saving.") }
        defer { Self.writing.remove(identity) }
        let context = context()
        do {
            let scope = try scope(change, in: context)
            let before = try physical(scope, countBytes: true)
            if let attempt = attempts[change.canvasID] {
                guard before == attempt.before else { return reconcile(change) }
            }
            guard try matchesBefore(change, scope: scope) else {
                return .held("The stored canvas changed. Reload it before making another edit.")
            }
            try apply(change, scope: scope, in: context)
            // Include every physical replica and expected absence. This snapshot
            // is made from the staging context, before its single model save.
            let after = try physical(self.scope(change, in: context, countRows: false), countBytes: false)
            attempts[change.canvasID] = Attempt(change: change, before: before, after: after)
            metrics.saveAttempts += 1
            do {
                try save(context)
                attempts[change.canvasID] = nil
                return .committed
            } catch {
                context.rollback()
                return reconcile(change)
            }
        } catch {
            context.rollback()
            return .held("Could not validate the stored canvas: \(error)")
        }
    }

    func discardAttempt(for id: UUID) {}
    func deletedImageHeaders() throws -> [DrawDeletedImage] { [] }
    func purge(canvases: [UUID: Date], images: [UUID: DrawImageTarget]) -> DrawRepositoryPurge {
        DrawRepositoryPurge(kept: canvases.count + images.count)
    }

    func reconcile(_ change: DrawChange) -> DrawWriteOutcome {
        guard let attempt = attempts[change.canvasID], attempt.change == change else {
            return .held("There is no verified save attempt to reconcile; keep this draft for review.")
        }
        do {
            let fresh = try physical(scope(change, in: context()), countBytes: true)
            if fresh == attempt.after {
                attempts[change.canvasID] = nil
                return .committed
            }
            if fresh == attempt.before { return .retry("The edit was not saved. Retry when ready.") }
            return .held("The stored result is mixed. Keep this draft until the affected records can be reconciled.")
        } catch { return .held("The save result cannot be read. Keep this draft and reconcile again: \(error)") }
    }

    private func binaryIDs(_ change: DrawChange) -> [UUID] {
        change.objectIDs.filter { change.objectsBefore[$0].flatMap(DrawCodec.payload) != change.objectsAfter[$0].flatMap(DrawCodec.payload) }
            .sorted { $0.uuidString < $1.uuidString }
    }
    private func scope(_ change: DrawChange, in context: ModelContext, countRows: Bool = true) throws -> Scope {
        let id = change.canvasID
        let ids = Array(change.objectIDs)
        let binaryIDs = binaryIDs(change)
        let canvases = try context.fetch(FetchDescriptor<DrawCanvasRecord>(predicate: #Predicate { $0.id == id }))
        // Mutation identity is global, even when an imported physical replica
        // has a divergent parent. Presentation alone filters by canvas.
        let objects = ids.isEmpty ? [] : try context.fetch(FetchDescriptor<DrawObjectRecord>(predicate:
            #Predicate { ids.contains($0.id) }))
        let payloads = binaryIDs.isEmpty ? [] : try context.fetch(FetchDescriptor<DrawPayloadRecord>(predicate:
            #Predicate { $0.role == "object" && binaryIDs.contains($0.id) }))
        let thumbnails = change.before?.thumbnail == change.after?.thumbnail ? [] : try context.fetch(FetchDescriptor<DrawPayloadRecord>(predicate:
            #Predicate { $0.id == id && $0.role == "thumbnail" }))
        if countRows { metrics.metadataRowsRead += canvases.count; metrics.objectRowsRead += objects.count }
        return Scope(canvases: canvases, objects: objects, payloads: payloads, thumbnails: thumbnails)
    }

    private func matchesBefore(_ change: DrawChange, scope: Scope) throws -> Bool {
        if let expected = change.before {
            guard !scope.canvases.isEmpty else { return false }
            var metadata = expected; metadata.thumbnail = nil
            guard try DrawCodec.encode(canvasWinner(scope.canvases).value()) == DrawCodec.encode(metadata) else { return false }
        } else if !scope.canvases.isEmpty { return false }
        for id in change.objectIDs {
            let rows = scope.objects.filter { $0.id == id }
            if let expected = change.objectsBefore[id] {
                guard let row = objectWinner(rows), row.formatVersion == 1,
                      row.zIndex == expected.zIndex, row.deletedAt == expected.deletedAt,
                      row.textIndex.utf8.elementsEqual(expected.text.utf8),
                      row.header.utf8.elementsEqual(try DrawCodec.header(expected).utf8),
                      row.payloadDigest == DrawCodec.payload(expected).map(DrawCodec.digest) ?? "" else { return false }
            } else if !rows.isEmpty { return false }
        }
        return true
    }

    private func apply(_ change: DrawChange, scope: Scope, in context: ModelContext) throws {
        if let canvas = change.after {
            let rows = scope.canvases.isEmpty ? [DrawCanvasRecord()] : scope.canvases
            if scope.canvases.isEmpty { context.insert(rows[0]) }
            for row in rows { try row.apply(canvas); metrics.metadataRowsWritten += 1 }
        } else {
            for row in scope.canvases { context.delete(row); metrics.metadataRowsWritten += 1 }
        }
        for id in change.objectIDs {
            let old = scope.objects.filter { $0.id == id }
            if let object = change.objectsAfter[id] {
                let rows = old.isEmpty ? [DrawObjectRecord()] : old
                if old.isEmpty { context.insert(rows[0]) }
                for row in rows { try row.apply(object, canvasID: change.canvasID); metrics.objectRowsWritten += 1 }
            } else {
                for row in old { context.delete(row); metrics.objectRowsWritten += 1 }
            }
        }
        for id in binaryIDs(change) {
            applyPayload(change.objectsAfter[id].flatMap(DrawCodec.payload), id: id, canvasID: change.canvasID,
                         role: "object", old: scope.payloads.filter { $0.id == id }, context: context)
        }
        if change.before?.thumbnail != change.after?.thumbnail {
            applyPayload(change.after?.thumbnail, id: change.canvasID, canvasID: change.canvasID,
                         role: "thumbnail", old: scope.thumbnails, context: context)
        }
    }
    private func applyPayload(_ data: Data?, id: UUID, canvasID: UUID, role: String,
                              old: [DrawPayloadRecord], context: ModelContext) {
        if let data {
            let rows = old.isEmpty ? [DrawPayloadRecord()] : old
            if old.isEmpty { context.insert(rows[0]) }
            for row in rows { row.apply(data, id: id, canvasID: canvasID, role: role); metrics.payloadRowsWritten += 1 }
        } else {
            for row in old { context.delete(row); metrics.payloadRowsWritten += 1 }
        }
    }

    private func physical(_ scope: Scope, countBytes: Bool) throws -> Physical {
        let canvases = try scope.canvases.map { row in
            try DrawCodec.encode([DrawCodec.string(row.value()), row.thumbnailID?.uuidString ?? ""])
        }
        let objects = try scope.objects.map { row in
            try DrawCodec.encode([row.id.uuidString, row.canvasID.uuidString, row.header, String(row.formatVersion), String(row.zIndex), row.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "", row.textIndex, row.payloadDigest])
        }
        func payloads(_ rows: [DrawPayloadRecord], thumbnail: Bool) throws -> [Data] {
            try rows.map { row in
                let bytes = row.bytes
                if countBytes {
                    if thumbnail { metrics.thumbnailBytesRead += bytes.count } else { metrics.payloadBytesRead += bytes.count }
                }
                return try DrawCodec.encode([row.id.uuidString, row.canvasID.uuidString, row.role, String(row.formatVersion), row.digest, bytes.base64EncodedString()])
            }
        }
        return try Physical(canvases: canvases.sorted { $0.lexicographicallyPrecedes($1) },
                            objects: objects.sorted { $0.lexicographicallyPrecedes($1) },
                            payloads: payloads(scope.payloads, thumbnail: false).sorted { $0.lexicographicallyPrecedes($1) },
                            thumbnails: payloads(scope.thumbnails, thumbnail: true).sorted { $0.lexicographicallyPrecedes($1) })
    }

    private func canvasWinner(_ rows: [DrawCanvasRecord]) throws -> DrawCanvasRecord {
        let sorted = try rows.map { ($0, try DrawCodec.encode([DrawCodec.string($0.value()), $0.thumbnailID?.uuidString ?? ""])) }.sorted {
            if ($0.0.deletedAt != nil) != ($1.0.deletedAt != nil) { return $0.0.deletedAt != nil }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $1.1.lexicographicallyPrecedes($0.1)
        }
        guard let winner = sorted.first?.0 else { throw DrawStoreError.missingCanvas }
        return winner
    }
    private func objectWinner(_ rows: [DrawObjectRecord]) -> DrawObjectRecord? {
        rows.sorted {
            if ($0.deletedAt != nil) != ($1.deletedAt != nil) { return $0.deletedAt != nil }
            if $0.header.utf8.elementsEqual($1.header.utf8) {
                if $0.payloadDigest != $1.payloadDigest { return $0.payloadDigest > $1.payloadDigest }
                return $0.formatVersion > $1.formatVersion
            }
            return $1.header.utf8.lexicographicallyPrecedes($0.header.utf8)
        }.first
    }
    private func thumbnail(for row: DrawCanvasRecord, in context: ModelContext) throws -> Data? {
        guard let id = row.thumbnailID else { return nil }
        let canvasID = row.id
        let payloads = try context.fetch(FetchDescriptor<DrawPayloadRecord>(predicate:
            #Predicate { $0.id == id && $0.canvasID == canvasID && $0.role == "thumbnail" }))
        guard let payload = payloads.sorted(by: { $0.digest > $1.digest }).first else { return nil }
        let bytes = payload.bytes
        metrics.thumbnailBytesRead += bytes.count
        return bytes
    }
    private func objectValue(_ row: DrawObjectRecord, in context: ModelContext) throws -> DrawObject {
        guard row.formatVersion == 1 else { throw DrawStoreError.invalidObject }
        var object = try DrawCodec.decode(DrawObject.self, from: row.header)
        guard object.id == row.id, object.zIndex == row.zIndex, object.deletedAt == row.deletedAt,
              object.text == row.textIndex else { throw DrawStoreError.invalidObject }
        guard !row.payloadDigest.isEmpty else { return object }
        let id = row.id, canvasID = row.canvasID, digest = row.payloadDigest
        let payloads = try context.fetch(FetchDescriptor<DrawPayloadRecord>(predicate:
            #Predicate { $0.id == id && $0.canvasID == canvasID && $0.role == "object" && $0.digest == digest }))
        guard let payload = payloads.first, payload.formatVersion == 1 else { throw DrawStoreError.invalidObject }
        let bytes = payload.bytes
        metrics.payloadBytesRead += bytes.count
        guard DrawCodec.digest(bytes) == digest else { throw DrawStoreError.invalidObject }
        switch object.content {
        case .stroke: object.content = .stroke(try JSONDecoder().decode([DrawPoint].self, from: bytes))
        case .image(var image): image.original = bytes; object.content = .image(image)
        default: throw DrawStoreError.invalidObject
        }
        return object
    }
}
