import Foundation
import CoreData
import SwiftData

enum CanvasCoreMetadataQuery {
    struct Stroke: Equatable {
        // Durable physical identity, including divergent logical replicas.
        // No SwiftData model is instantiated to obtain this URI.
        let physicalURI: URL
        let id: UUID
        let canvasID: UUID
        let version: Int64
        let generation: Int64
        let tombstoned: Bool
        let bounds: CanvasCoreBounds?
        let rank: Int64?
        let binaryRowID: UUID?
        let payloadVersion: Int
        let digest: String?
        let offsetX: Double
        let offsetY: Double
    }
    enum QueryError: Error { case unsupportedStore, incompatibleModel, malformedResult }

    /// Committed scalar truth only. Open the same store read-only with the
    /// public SwiftData/Core Data model conversion; never migrate, save, or
    /// access SwiftData's private backing context. A dictionary-result fetch
    /// must earn the emitted-SQL gate on each supported toolchain.
    @MainActor static func strokes(canvasID: UUID, in context: ModelContext) throws -> [Stroke] {
        let configurations = context.container.configurations.filter {
            !$0.isStoredInMemoryOnly && ($0.schema?.entities.contains { $0.name == "CanvasStrokeItem" } ?? true)
        }
        guard configurations.count == 1, let configuration = configurations.first else { throw QueryError.unsupportedStore }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: context.container.schema) else {
            throw QueryError.incompatibleModel
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: configuration.url, options: [NSReadOnlyPersistentStoreOption: true])
        defer { try? coordinator.remove(store) }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        let request = NSFetchRequest<NSDictionary>(entityName: "CanvasStrokeItem")
        request.resultType = .dictionaryResultType
        request.includesPendingChanges = false
        request.predicate = NSPredicate(format: "canvasID == %@", canvasID as NSUUID)
        let physicalID = NSExpressionDescription()
        physicalID.name = "physicalID"
        physicalID.expression = NSExpression.expressionForEvaluatedObject()
        physicalID.expressionResultType = .objectIDAttributeType
        request.propertiesToFetch = [physicalID, "id", "canvasID", "mutationVersion", "boardGeneration", "tombstoned",
            "boundsMinX", "boundsMinY", "boundsMaxX", "boundsMaxY", "rankOverride", "binaryRowID",
            "payloadVersion", "binaryDigest", "offsetX", "offsetY"]
        return try reader.fetch(request).map { row in
            guard let objectID = row["physicalID"] as? NSManagedObjectID,
                  let id = row["id"] as? UUID, let board = row["canvasID"] as? UUID,
                  let version = row["mutationVersion"] as? NSNumber,
                  let generation = row["boardGeneration"] as? NSNumber,
                  let tombstoned = row["tombstoned"] as? NSNumber,
                  let payloadVersion = row["payloadVersion"] as? NSNumber,
                  let offsetX = row["offsetX"] as? Double, let offsetY = row["offsetY"] as? Double else { throw QueryError.malformedResult }
            let bounds: CanvasCoreBounds?
            if let x = row["boundsMinX"] as? Double, let y = row["boundsMinY"] as? Double,
               let mx = row["boundsMaxX"] as? Double, let my = row["boundsMaxY"] as? Double {
                bounds = .init(minX: x, minY: y, maxX: mx, maxY: my)
            } else { bounds = nil }
            return .init(physicalURI: objectID.uriRepresentation(), id: id, canvasID: board,
                version: version.int64Value, generation: generation.int64Value, tombstoned: tombstoned.boolValue,
                bounds: bounds, rank: (row["rankOverride"] as? NSNumber)?.int64Value, binaryRowID: row["binaryRowID"] as? UUID,
                payloadVersion: payloadVersion.intValue, digest: row["binaryDigest"] as? String, offsetX: offsetX, offsetY: offsetY)
        }
    }
}
