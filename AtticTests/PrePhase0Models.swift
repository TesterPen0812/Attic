import Foundation
import SwiftData
import UniformTypeIdentifiers
@testable import Attic

/// The seven SwiftData models exactly as they were stored before Phase 0
/// (revision f2c737a), copied verbatim: every `@Model` class body below is
/// the unmodified text of `Attic/Models/<Name>.swift` at that revision,
/// nested here only so the names don't clash. `SchemaMigrationTests` checks
/// their entity hashes against `Scripts/print_model_hashes.sh f2c737a`,
/// which compiles the same classes straight from git.
enum PrePhase0 {
    @Model
    final class TaskItem {
        // CloudKit can't enforce SwiftData uniqueness. UUID generation plus the
        // TaskStore refresh deduplication keep the app-level identity stable.
        var id: UUID = UUID()
        var title: String = ""
        var statusRaw: String = TaskStatus.todo.rawValue
        var priorityRaw: String = TaskPriority.none.rawValue
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        /// A scalar, optional link keeps existing local stores compatible and
        /// avoids SwiftData relationship ownership across duplicate UUID replicas.
        var parentID: UUID? = nil
        /// Small file references only; image and file bytes live in the private
        /// local attachment directory and are never decoded by task-list queries.
        /// The stored name predates general files and stays for compatibility.
        var imageReferencesData: Data? = nil

        /// Images and general files in one ordered list, parent-owned. Decoded
        /// once per stored payload: SwiftUI reads this several times per row body,
        /// so the last decode is kept beside the bytes it came from and reused
        /// until the stored data changes (any replica write replaces the data).
        var attachments: [TaskImageReference] {
            guard let imageReferencesData, !imageReferencesData.isEmpty else { return [] }
            if let cached = decodedAttachments, cached.data == imageReferencesData {
                return cached.references
            }
            let references = (try? JSONDecoder().decode([TaskImageReference].self, from: imageReferencesData)) ?? []
            decodedAttachments = DecodedAttachments(data: imageReferencesData, references: references)
            return references
        }

        /// Memo for `attachments`; never persisted.
        @Transient private var decodedAttachments: DecodedAttachments? = nil

        private struct DecodedAttachments {
            let data: Data
            let references: [TaskImageReference]
        }

        init(
            id: UUID = UUID(),
            title: String,
            status: TaskStatus = .todo,
            priority: TaskPriority = .none,
            createdAt: Date = Date(),
            updatedAt: Date? = nil,
            completedAt: Date? = nil,
            manualOrder: Int64? = nil,
            parentID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            statusRaw = status.rawValue
            priorityRaw = priority.rawValue
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.completedAt = completedAt
            self.manualOrder = manualOrder
            self.parentID = parentID
        }

        var status: TaskStatus {
            get { TaskStatus(rawValue: statusRaw) ?? .todo }
            set { statusRaw = newValue.rawValue }
        }

        var priority: TaskPriority {
            get { TaskPriority(rawValue: priorityRaw) ?? .none }
            set { priorityRaw = newValue.rawValue }
        }
    }

    @Model
    final class NoteItem {
        // CloudKit can't enforce SwiftData uniqueness. UUID generation plus the
        // NoteStore refresh deduplication keep the app-level identity stable.
        var id: UUID = UUID()
        var title: String = ""
        var body: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init(
            id: UUID = UUID(),
            title: String = "",
            body: String = "",
            createdAt: Date = Date(),
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }
    }

    @Model
    final class NoteAttachment {
        var id: UUID = UUID()
        var noteID: UUID = UUID()
        var originalFilename: String = ""
        var contentTypeIdentifier: String = UTType.data.identifier
        var byteCount: Int64 = 0
        var sortIndex: Int64 = 0
        /// UTF-16 body offset at a paragraph boundary; nil keeps the card in the tray.
        var inlineOffset: Int? = nil
        var displayWidth: Double? = nil
        var displayHeight: Double? = nil
        var contentDigest: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Attribute(.externalStorage) var payload: Data? = nil

        init(
            id: UUID = UUID(),
            noteID: UUID,
            originalFilename: String,
            contentTypeIdentifier: String = UTType.data.identifier,
            byteCount: Int64,
            sortIndex: Int64,
            contentDigest: String,
            createdAt: Date = Date(),
            updatedAt: Date? = nil,
            payload: Data? = nil
        ) {
            self.id = id
            self.noteID = noteID
            self.originalFilename = originalFilename
            self.contentTypeIdentifier = contentTypeIdentifier
            self.byteCount = byteCount
            self.sortIndex = sortIndex
            self.contentDigest = contentDigest
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.payload = payload
        }

        var contentType: UTType {
            UTType(contentTypeIdentifier) ?? .data
        }

        var isImage: Bool {
            contentType.conforms(to: .image)
        }
    }

    @Model
    final class CanvasBoardItem {
        /// The original single-canvas identity. Existing installations continue to
        /// resolve their ink and images into this default canvas.
        static let logicalBoardID = UUID(
            uuidString: "8A9475C5-85B2-4D51-9CF6-A8D7EE6A4E01"
        )!

        /// Used only when every physical board is tombstoned. Keeping this identity
        /// distinct prevents a deleted default canvas from being synthesized again.
        static let recoveryBoardID = UUID(
            uuidString: "B9C741E8-72F4-4E8E-A87C-64F77C2C1B01"
        )!

        /// App-level identity only. CloudKit can contain multiple physical rows for
        /// the same UUID, so CanvasStore deterministically resolves a winner and
        /// applies mutations to every replica rather than using a unique constraint.
        var id: UUID = CanvasBoardItem.logicalBoardID
        var name: String = "Canvas"
        var sortIndex: Int64 = 0
        var formatVersion: Int = 1
        var clearGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil

        init(
            id: UUID = CanvasBoardItem.logicalBoardID,
            name: String = "Canvas",
            sortIndex: Int64 = 0,
            formatVersion: Int = 1,
            clearGeneration: Int64 = 0,
            mutationVersion: Int64 = 1,
            tombstoned: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.sortIndex = sortIndex
            self.formatVersion = formatVersion
            self.clearGeneration = clearGeneration
            self.mutationVersion = mutationVersion
            self.tombstoned = tombstoned
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.deletedAt = deletedAt
        }
    }

    @Model
    final class CanvasStrokeItem {
        /// Logical stroke identity. This deliberately has no SwiftData unique
        /// constraint because CloudKit cannot enforce one.
        var id: UUID = UUID()
        var canvasID: UUID = CanvasBoardItem.logicalBoardID
        var payloadVersion: Int = 1
        var payload: Data = Data()
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil

        init(
            id: UUID = UUID(),
            canvasID: UUID = CanvasBoardItem.logicalBoardID,
            payloadVersion: Int = 1,
            payload: Data = Data(),
            boardGeneration: Int64 = 0,
            mutationVersion: Int64 = 1,
            tombstoned: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.canvasID = canvasID
            self.payloadVersion = payloadVersion
            self.payload = payload
            self.boardGeneration = boardGeneration
            self.mutationVersion = mutationVersion
            self.tombstoned = tombstoned
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.deletedAt = deletedAt
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

    @Model
    final class CanvasSemanticObjectItem {
        var id: UUID = UUID()
        var canvasID: UUID = CanvasBoardItem.logicalBoardID
        var kind: String = "text"
        var payloadVersion: Int = 1
        var payload: Data = Data()
        var centerX: Double = 0
        var centerY: Double = 0
        var width: Double = 160
        var height: Double = 48
        var rotation: Double = 0
        var zIndex: Int64 = 0
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil

        init(id: UUID = UUID(), canvasID: UUID = CanvasBoardItem.logicalBoardID) {
            self.id = id
            self.canvasID = canvasID
        }
    }
}
