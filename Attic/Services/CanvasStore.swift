import Combine
import CoreData
import Foundation
import SwiftData

enum CanvasReplicaMutationError: LocalizedError {
    case missingStroke(UUID)
    case missingImage(UUID)
    case missingCanvas(UUID)
    case mutationVersionExhausted(UUID)
    case generationExhausted
    case sortIndexExhausted
    case invalidCanvasName
    case cannotDeleteLastCanvas
    case invalidImage

    var errorDescription: String? {
        switch self {
        case let .missingStroke(id):
            "The canvas stroke replicas for \(id.uuidString) could not be loaded safely."
        case let .missingImage(id):
            "The canvas image replicas for \(id.uuidString) could not be loaded safely."
        case let .missingCanvas(id):
            "The canvas replicas for \(id.uuidString) could not be loaded safely."
        case let .mutationVersionExhausted(id):
            "The canvas object \(id.uuidString) cannot be changed because its mutation version is exhausted."
        case .generationExhausted:
            "The canvas cannot be cleared because its generation is exhausted."
        case .sortIndexExhausted:
            "A new canvas cannot be ordered safely."
        case .invalidCanvasName:
            "Enter a canvas name between 1 and 80 characters."
        case .cannotDeleteLastCanvas:
            "Keep at least one canvas."
        case .invalidImage:
            "The image could not be stored because its data or transform is invalid."
        }
    }
}

enum CanvasSaveOutcome: Equatable {
    case noChanges
    case persisted(warning: String?)
    case persistedButRefreshFailed(String)
    case failed(String)

    var didPersist: Bool {
        switch self {
        case .persisted, .persistedButRefreshFailed:
            true
        case .noChanges, .failed:
            false
        }
    }

    var succeeded: Bool {
        switch self {
        case .noChanges, .persisted, .persistedButRefreshFailed:
            true
        case .failed:
            false
        }
    }
}

#if DEBUG
/// Counts every Canvas replica fetch and the rows it materialised.
///
/// Every save resolves the presentation twice and each mutation looks up the
/// replicas it changes. A fetch without a predicate turns each of those into a
/// read of every board's rows, including every stroke payload, so tests assert
/// the row counts directly instead of inferring them from wall-clock timing.
///
/// Test instrumentation only: it is compiled out of builds without `DEBUG`,
/// where the fetch helpers below are plain `fetch`/`fetchCount` calls.
enum CanvasReplicaFetchCounter {
    static private(set) var fetches = 0
    static private(set) var rows = 0

    static func reset() {
        fetches = 0
        rows = 0
    }

    static func note(rows count: Int) {
        fetches &+= 1
        rows &+= count
    }
}
#endif

extension ModelContext {
    /// The only way the Canvas store reads replica rows, so
    /// `CanvasReplicaFetchCounter` sees every one of them in `DEBUG` builds.
    func fetchCanvasReplicas<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> [Model] {
        #if DEBUG
        let rows = try fetch(descriptor)
        CanvasReplicaFetchCounter.note(rows: rows.count)
        return rows
        #else
        return try fetch(descriptor)
        #endif
    }

    func countCanvasReplicas<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> Int {
        #if DEBUG
        let count = try fetchCount(descriptor)
        CanvasReplicaFetchCounter.note(rows: 0)
        return count
        #else
        return try fetchCount(descriptor)
        #endif
    }
}

struct CanvasReplicaKey: Hashable {
    let canvasID: UUID
    let id: UUID
}

/// Every board replica, plus the content replicas of one canvas.
///
/// Presentation only ever shows the selected canvas, so content rows claiming
/// any other canvas are not fetched: loading them materialised every stroke
/// payload on every board twice per save (PERF-A1). Tombstones and duplicate
/// replicas of the loaded canvas are all present, so winner resolution is
/// unchanged.
struct CanvasStoredReplicas {
    let boards: [CanvasBoardItem]
    let strokes: [CanvasStrokeItem]
    let images: [CanvasImageItem]
    #if os(macOS)
    var semanticObjects: [CanvasSemanticObjectItem] = []
    #endif
    /// True when no physical default board row exists but live content still
    /// claims the default canvas, so presentation must show a virtual default
    /// board for it.
    var hasUnboardedLegacyDefaultContent = false

    init(boards: [CanvasBoardItem], strokes: [CanvasStrokeItem], images: [CanvasImageItem]) {
        self.boards = boards
        self.strokes = strokes
        self.images = images
    }

    static func load(
        from context: ModelContext,
        contentCanvasID canvasID: UUID
    ) throws -> CanvasStoredReplicas {
        #if os(macOS)
        let supportsSemanticObjects = context.container.schema.entities.contains {
            $0.name == "CanvasSemanticObjectItem"
        }
        #endif
        var replicas = CanvasStoredReplicas(
            boards: try context.fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>()),
            strokes: try context.fetchCanvasReplicas(FetchDescriptor<CanvasStrokeItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            )),
            images: try context.fetchCanvasReplicas(FetchDescriptor<CanvasImageItem>(
                predicate: #Predicate { $0.canvasID == canvasID }
            ))
        )
        #if os(macOS)
        if supportsSemanticObjects {
            replicas.semanticObjects = try context.fetchCanvasReplicas(
                FetchDescriptor<CanvasSemanticObjectItem>(
                    predicate: #Predicate { $0.canvasID == canvasID }
                )
            )
        }
        #endif

        let defaultID = CanvasBoardItem.logicalBoardID
        guard !replicas.boards.contains(where: { $0.id == defaultID }) else {
            return replicas
        }
        if canvasID == defaultID {
            replicas.hasUnboardedLegacyDefaultContent = replicas.strokes.contains { !$0.tombstoned }
                || replicas.images.contains { !$0.tombstoned }
            #if os(macOS)
            replicas.hasUnboardedLegacyDefaultContent = replicas.hasUnboardedLegacyDefaultContent
                || replicas.semanticObjects.contains { !$0.tombstoned }
            #endif
        } else {
            // Counting leaves the default canvas's payloads on disk.
            replicas.hasUnboardedLegacyDefaultContent = try context.countCanvasReplicas(
                FetchDescriptor<CanvasStrokeItem>(
                    predicate: #Predicate { $0.canvasID == defaultID && !$0.tombstoned }
                )
            ) > 0 || context.countCanvasReplicas(
                FetchDescriptor<CanvasImageItem>(
                    predicate: #Predicate { $0.canvasID == defaultID && !$0.tombstoned }
                )
            ) > 0
            #if os(macOS)
            if !replicas.hasUnboardedLegacyDefaultContent, supportsSemanticObjects {
                replicas.hasUnboardedLegacyDefaultContent = try context.countCanvasReplicas(
                    FetchDescriptor<CanvasSemanticObjectItem>(
                        predicate: #Predicate { $0.canvasID == defaultID && !$0.tombstoned }
                    )
                ) > 0
            }
            #endif
        }
        return replicas
    }
}

struct CanvasPresentationSnapshot {
    let canvases: [CanvasBoard]
    let selectedCanvasID: UUID
    let boardGeneration: Int64
    let strokeCache: [CanvasReplicaKey: CanvasStrokeCacheEntry]
    let imageCache: [CanvasReplicaKey: CanvasImageCacheEntry]
    let strokes: [CanvasStroke]
    let images: [CanvasPlacedImage]
    #if os(macOS)
    var semanticObjects: [CanvasSemanticObject] = []
    #endif
    let warning: String?
}

/// Per-collection description of what changed between two published canvas
/// presentations (PERF-13 / PERF-007).
///
/// `CanvasSession` used to rebuild a full signature snapshot of every board,
/// stroke, image and semantic object on every store revision and compare it
/// element by element, purely to decide whether the change came from outside
/// the session. The store already walks those collections while resolving, so
/// it publishes the answer instead.
struct CanvasStoreContentChange: Equatable {
    /// `false` means the descriptor could not be derived and an observer must
    /// fall back to comparing the published collections itself.
    var isIncremental: Bool
    var boardsChanged: Bool
    var selectionChanged: Bool
    var boardGenerationChanged: Bool
    var strokesChanged: Bool
    var imagesChanged: Bool
    var semanticObjectsChanged: Bool

    static let unchanged = CanvasStoreContentChange(
        isIncremental: true,
        boardsChanged: false,
        selectionChanged: false,
        boardGenerationChanged: false,
        strokesChanged: false,
        imagesChanged: false,
        semanticObjectsChanged: false
    )

    /// The conservative fallback: everything may have changed and the
    /// descriptor carries no usable delta.
    static let unknown = CanvasStoreContentChange(
        isIncremental: false,
        boardsChanged: true,
        selectionChanged: true,
        boardGenerationChanged: true,
        strokesChanged: true,
        imagesChanged: true,
        semanticObjectsChanged: true
    )

    var hasAnyChange: Bool {
        boardsChanged
            || selectionChanged
            || boardGenerationChanged
            || strokesChanged
            || imagesChanged
            || semanticObjectsChanged
    }
}

/// Order-sensitive hash of the semantic fields of a stroke collection.
///
/// Stroke equality compares every point, so an exact array comparison per
/// revision is O(total points). The presentation only needs to know whether the
/// committed identity of the collection changed, which these scalar fields
/// already determine.
enum CanvasStrokeCollectionFingerprint {
    static func value(for strokes: [CanvasStroke]) -> Int {
        var hasher = Hasher()
        hasher.combine(strokes.count)
        for stroke in strokes {
            hasher.combine(stroke.id)
            hasher.combine(stroke.canvasID)
            hasher.combine(stroke.boardGeneration)
            hasher.combine(stroke.mutationVersion)
            hasher.combine(stroke.updatedAt)
        }
        return hasher.finalize()
    }
}

struct CanvasStrokeCacheEntry {
    let sourceReplicaID: String
    let payloadVersion: Int
    let payloadByteCount: Int
    let boardGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date
    let stroke: CanvasStroke

    func matches(_ replica: CanvasStrokeItem) -> Bool {
        sourceReplicaID == String(reflecting: replica.persistentModelID)
            && representsSameCommittedValue(as: replica)
    }

    func representsSameCommittedValue(as replica: CanvasStrokeItem) -> Bool {
        payloadVersion == replica.payloadVersion
            && payloadByteCount == replica.payload.count
            && boardGeneration == replica.boardGeneration
            && mutationVersion == replica.mutationVersion
            && createdAt == replica.createdAt
            && updatedAt == replica.updatedAt
    }

    func rebound(to replica: CanvasStrokeItem) -> CanvasStrokeCacheEntry {
        CanvasStrokeCacheEntry(
            sourceReplicaID: String(reflecting: replica.persistentModelID),
            payloadVersion: replica.payloadVersion,
            payloadByteCount: replica.payload.count,
            boardGeneration: replica.boardGeneration,
            mutationVersion: replica.mutationVersion,
            createdAt: replica.createdAt,
            updatedAt: replica.updatedAt,
            stroke: stroke
        )
    }
}

struct CanvasImageCacheEntry {
    let sourceReplicaID: String
    let payloadMetadata: CanvasImagePayloadMetadata
    let contentType: String
    let pixelWidth: Int64
    let pixelHeight: Int64
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
    let zIndex: Int64
    let boardGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date
    let image: CanvasPlacedImage

    func contentMatches(_ replica: CanvasImageItem) -> Bool {
        sourceReplicaID == String(reflecting: replica.persistentModelID)
            && contentValueMatches(replica)
    }

    func contentValueMatches(_ replica: CanvasImageItem) -> Bool {
        guard contentType == replica.contentType,
              pixelWidth == replica.pixelWidth,
              pixelHeight == replica.pixelHeight else {
            return false
        }
        // The cache token must change when the bitmap changes even if its
        // dimensions and encoded byte count happen to remain identical, so the
        // comparison has to be content-sensitive. The scalar digest column
        // makes that comparison exact without faulting the external-storage
        // payload (CANVAS-016/PERF-08); only a legacy row that predates the
        // column falls back to comparing the bytes.
        guard let replicaMetadata = replica.resolvedPayloadMetadata else {
            return payloadMetadata.byteCount == replica.materialisedPayload.count
                && image.encodedData == replica.encodedData
        }
        guard payloadMetadata == replicaMetadata else { return false }
        // A version bump with no transform change is not something this
        // store writes for an unchanged bitmap: a writer that predates the
        // digest column (or bypassed it) may have replaced the bytes and left
        // the metadata stale. Only that anomaly pays for a byte comparison;
        // moves and resizes still cost no image I/O.
        let transformUnchanged = centerX == replica.centerX && centerY == replica.centerY
            && width == replica.width && height == replica.height && zIndex == replica.zIndex
        let versionChanged = mutationVersion != replica.mutationVersion || updatedAt != replica.updatedAt
        if transformUnchanged, versionChanged {
            return image.encodedData == replica.encodedData
        }
        return true
    }

    func matches(_ replica: CanvasImageItem) -> Bool {
        sourceReplicaID == String(reflecting: replica.persistentModelID)
            && representsSameCommittedValue(as: replica)
    }

    func representsSameCommittedValue(as replica: CanvasImageItem) -> Bool {
        contentValueMatches(replica)
            && centerX == replica.centerX
            && centerY == replica.centerY
            && width == replica.width
            && height == replica.height
            && zIndex == replica.zIndex
            && boardGeneration == replica.boardGeneration
            && mutationVersion == replica.mutationVersion
            && createdAt == replica.createdAt
            && updatedAt == replica.updatedAt
    }

    func rebound(to replica: CanvasImageItem) -> CanvasImageCacheEntry {
        CanvasImageCacheEntry(
            sourceReplicaID: String(reflecting: replica.persistentModelID),
            // `contentValueMatches` has already proved the payload is the same,
            // so the cached scalar identity is carried over rather than
            // recomputed from the blob.
            payloadMetadata: payloadMetadata,
            contentType: replica.contentType,
            pixelWidth: replica.pixelWidth,
            pixelHeight: replica.pixelHeight,
            centerX: replica.centerX,
            centerY: replica.centerY,
            width: replica.width,
            height: replica.height,
            zIndex: replica.zIndex,
            boardGeneration: replica.boardGeneration,
            mutationVersion: replica.mutationVersion,
            createdAt: replica.createdAt,
            updatedAt: replica.updatedAt,
            image: image
        )
    }
}

enum CanvasCloudInfrastructurePolicy {
    static var isEnabled: Bool {
        #if ATTIC_LOCAL_ONLY
        false
        #else
        true
        #endif
    }
}

@MainActor
final class CanvasStore: ObservableObject {
    @Published var canvases: [CanvasBoard] = [.defaultBoard]
    @Published var selectedCanvasID = CanvasBoardItem.logicalBoardID
    @Published var strokes: [CanvasStroke] = []
    @Published var images: [CanvasPlacedImage] = []
    #if os(macOS)
    @Published var semanticObjects: [CanvasSemanticObject] = []
    #endif
    @Published var boardGeneration: Int64 = 0
    @Published var lastErrorMessage: String?
    @Published var revision: UInt64 = 0
    @Published var cloudSyncStatus = CloudSyncStatus()

    let container: ModelContainer
    var context: ModelContext
    let now: () -> Date
    let persist: (ModelContext) throws -> Void
    let makeFreshContext: () throws -> ModelContext
    /// Loads every board replica and the content replicas of the given canvas.
    let loadReplicas: (ModelContext, UUID) throws -> CanvasStoredReplicas
    let decodeStroke: (Data, Int) throws -> CanvasStrokeGeometry
    var visibleStrokeCache: [CanvasReplicaKey: CanvasStrokeCacheEntry] = [:]
    var visibleImageCache: [CanvasReplicaKey: CanvasImageCacheEntry] = [:]
    /// What the most recent published presentation changed. Observers read it
    /// alongside `revision` to skip work for collections that did not move.
    var lastContentChange = CanvasStoreContentChange.unknown
    /// Bumped only when a published presentation actually changed content, so
    /// an observer can detect a no-op revision in constant time.
    var contentRevision: UInt64 = 0
    var publishedStrokeFingerprint = CanvasStrokeCollectionFingerprint.value(for: [])
    /// Forces the next published presentation to report `.unknown`, which makes
    /// observers take their full comparison path.
    var requiresFullContentComparison = true
    var remoteChangeObservation: AnyCancellable?
    var cloudKitEventObservation: AnyCancellable?
    var cloudImportRefreshTask: Task<Void, Never>?
    var cloudSyncProtection = CloudSyncProtectionState()
#if os(macOS)
    var exportActivityToken: NSObjectProtocol?
    var importActivityToken: NSObjectProtocol?
    var exportActivityTimeoutTask: Task<Void, Never>?
    var importActivityTimeoutTask: Task<Void, Never>?
    static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        makeFreshContext: (() throws -> ModelContext)? = nil,
        loadReplicas: @escaping (ModelContext, UUID) throws -> CanvasStoredReplicas = {
            try CanvasStoredReplicas.load(from: $0, contentCanvasID: $1)
        },
        decodeStroke: @escaping (Data, Int) throws -> CanvasStrokeGeometry = { data, version in
            try CanvasStrokeCodec.decode(data, expectedVersion: version)
        }
    ) {
        self.container = container
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        self.makeFreshContext = makeFreshContext ?? { ModelContext(container) }
        self.loadReplicas = loadReplicas
        self.decodeStroke = decodeStroke
        refresh()
        if CanvasCloudInfrastructurePolicy.isEnabled {
            observeRemoteChanges()
            observeCloudKitEvents()
        }
    }

    var selectedCanvas: CanvasBoard {
        if let board = canvases.first(where: { $0.id == selectedCanvasID }) {
            return board
        }
        return selectedCanvasID == CanvasBoardItem.recoveryBoardID
            ? .recoveryBoard
            : .defaultBoard
    }

}
