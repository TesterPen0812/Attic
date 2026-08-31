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

struct CanvasReplicaKey: Hashable {
    let canvasID: UUID
    let id: UUID
}

struct CanvasStoredReplicas {
    let boards: [CanvasBoardItem]
    let strokes: [CanvasStrokeItem]
    let images: [CanvasImageItem]

    static func load(from context: ModelContext) throws -> CanvasStoredReplicas {
        CanvasStoredReplicas(
            boards: try context.fetch(FetchDescriptor<CanvasBoardItem>()),
            strokes: try context.fetch(FetchDescriptor<CanvasStrokeItem>()),
            images: try context.fetch(FetchDescriptor<CanvasImageItem>())
        )
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
    let warning: String?
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
    let encodedByteCount: Int
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
        encodedByteCount == replica.encodedData.count
            && contentType == replica.contentType
            && pixelWidth == replica.pixelWidth
            && pixelHeight == replica.pixelHeight
            // The cache token must change when the bitmap changes even if its
            // dimensions and encoded byte count happen to remain identical.
            // `image` already owns the prior bytes, so this exact comparison
            // does not duplicate the payload in the cache.
            && image.encodedData == replica.encodedData
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
            encodedByteCount: replica.encodedData.count,
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
    @Published var boardGeneration: Int64 = 0
    @Published var lastErrorMessage: String?
    @Published var revision: UInt64 = 0
    @Published var cloudSyncStatus = CloudSyncStatus()

    let container: ModelContainer
    var context: ModelContext
    let now: () -> Date
    let persist: (ModelContext) throws -> Void
    let makeFreshContext: () throws -> ModelContext
    let loadReplicas: (ModelContext) throws -> CanvasStoredReplicas
    let decodeStroke: (Data, Int) throws -> CanvasStrokeGeometry
    var visibleStrokeCache: [CanvasReplicaKey: CanvasStrokeCacheEntry] = [:]
    var visibleImageCache: [CanvasReplicaKey: CanvasImageCacheEntry] = [:]
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
        loadReplicas: @escaping (ModelContext) throws -> CanvasStoredReplicas = {
            try CanvasStoredReplicas.load(from: $0)
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
