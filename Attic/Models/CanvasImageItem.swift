import CryptoKit
import Foundation
import SwiftData

/// Counts every materialisation of a `CanvasImageItem.encodedData` blob.
///
/// `encodedData` is a SwiftData external-storage attribute: reading it faults
/// the payload in from disk. Presentation resolution runs after every canvas
/// mutation, so a single read inside that loop costs one blob fault per image
/// per save. The counter exists so tests can assert the absence of those reads
/// directly instead of inferring it from wall-clock timing.
enum CanvasImagePayloadAccessCounter {
    static private(set) var count = 0

    static func reset() {
        count = 0
    }

    static func note() {
        count &+= 1
    }
}

/// Scalar identity for an encoded canvas image payload.
///
/// Validating an unchanged image needs only these two values, both of which are
/// ordinary scalar columns. Comparing them never touches external storage.
struct CanvasImagePayloadMetadata: Equatable, Sendable {
    let byteCount: Int
    let digest: String

    static func compute(for data: Data) -> CanvasImagePayloadMetadata {
        CanvasImagePayloadMetadata(
            byteCount: data.count,
            digest: data.isEmpty ? "" : Self.digest(of: data)
        )
    }

    /// Truncated SHA-256. Sixteen bytes of a cryptographic digest make an
    /// accidental collision between two distinct canvas payloads unreachable in
    /// practice, and keep the stored scalar short.
    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

@Model
final class CanvasImageItem {
    // CloudKit cannot enforce SwiftData uniqueness. CanvasStore presents one
    // deterministic winner and applies every mutation to all physical replicas.
    var id: UUID = UUID()
    var canvasID: UUID = CanvasBoardItem.logicalBoardID
    @Attribute(.externalStorage) var encodedData: Data = Data()
    /// Scalar mirror of `encodedData.count`. Defaults to zero so an existing
    /// store migrates lightly; a legacy row is backfilled on first load.
    var encodedByteCount: Int64 = 0
    /// Scalar content digest of `encodedData`. Empty for a legacy row.
    var contentDigest: String = ""
    var contentType: String = "public.png"
    var pixelWidth: Int64 = 0
    var pixelHeight: Int64 = 0
    var centerX: Double = 0
    var centerY: Double = 0
    var width: Double = CanvasImagePlacement.minimumDimension
    var height: Double = CanvasImagePlacement.minimumDimension
    var zIndex: Int64 = 0
    var boardGeneration: Int64 = 0
    var mutationVersion: Int64 = 1
    var tombstoned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        id: UUID = UUID(),
        canvasID: UUID = CanvasBoardItem.logicalBoardID,
        encodedData: Data = Data(),
        contentType: String = "public.png",
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        centerX: Double = 0,
        centerY: Double = 0,
        width: Double = CanvasImagePlacement.minimumDimension,
        height: Double = CanvasImagePlacement.minimumDimension,
        zIndex: Int64 = 0,
        boardGeneration: Int64 = 0,
        mutationVersion: Int64 = 1,
        tombstoned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        payloadMetadata: CanvasImagePayloadMetadata? = nil
    ) {
        self.id = id
        self.canvasID = canvasID
        self.encodedData = encodedData
        let metadata = payloadMetadata ?? .compute(for: encodedData)
        encodedByteCount = Int64(metadata.byteCount)
        contentDigest = metadata.digest
        self.contentType = contentType
        self.pixelWidth = Int64(pixelWidth)
        self.pixelHeight = Int64(pixelHeight)
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.boardGeneration = boardGeneration
        self.mutationVersion = mutationVersion
        self.tombstoned = tombstoned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }
}

extension CanvasImageItem {
    /// Scalar payload identity, or `nil` when this row predates the metadata
    /// columns and its identity can only be recovered from the blob itself.
    var resolvedPayloadMetadata: CanvasImagePayloadMetadata? {
        guard !contentDigest.isEmpty else { return nil }
        return CanvasImagePayloadMetadata(
            byteCount: Int(encodedByteCount),
            digest: contentDigest
        )
    }

    /// Reads the external-storage payload and records the fault. Every read of
    /// `encodedData` inside the store must go through this accessor so the
    /// performance gate can prove that unchanged images are never materialised.
    var materialisedPayload: Data {
        CanvasImagePayloadAccessCounter.note()
        return encodedData
    }

    /// Scalar payload identity, materialising the blob only for a legacy row.
    var payloadMetadata: CanvasImagePayloadMetadata {
        resolvedPayloadMetadata ?? .compute(for: materialisedPayload)
    }

    /// True when the payload is non-empty without faulting the blob for a row
    /// that already carries its scalar metadata.
    var hasEncodedPayload: Bool {
        if let resolvedPayloadMetadata {
            return resolvedPayloadMetadata.byteCount > 0
        }
        return !materialisedPayload.isEmpty
    }

    /// Writes a payload and its scalar metadata as one unit so the two can
    /// never disagree.
    func applyEncodedPayload(
        _ data: Data,
        metadata: CanvasImagePayloadMetadata? = nil
    ) {
        let resolved = metadata ?? .compute(for: data)
        encodedData = data
        encodedByteCount = Int64(resolved.byteCount)
        contentDigest = resolved.digest
    }

    /// Backfills the scalar metadata of a legacy row. This is derived data: it
    /// deliberately leaves `mutationVersion`, `updatedAt` and every
    /// replica-resolution field alone so a backfill can never change which
    /// replica wins or make two replicas look divergent.
    @discardableResult
    func backfillPayloadMetadataIfNeeded() -> Bool {
        guard contentDigest.isEmpty else { return false }
        let data = materialisedPayload
        guard !data.isEmpty else {
            // An empty payload has no digest to record; leaving the row alone
            // keeps the "invalid data" warning path unchanged.
            return false
        }
        let metadata = CanvasImagePayloadMetadata.compute(for: data)
        encodedByteCount = Int64(metadata.byteCount)
        contentDigest = metadata.digest
        return true
    }
}
