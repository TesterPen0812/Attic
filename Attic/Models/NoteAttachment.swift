import Foundation
import SwiftData
import UniformTypeIdentifiers

@Model
final class NoteAttachment {
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var originalFilename: String = ""
    var contentTypeIdentifier: String = UTType.data.identifier
    var byteCount: Int64 = 0
    var sortIndex: Int64 = 0
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

struct AttachmentFileReference: Sendable {
    let id: UUID
    let digest: String
    let filename: String
    let byteCount: Int64?
    let payload: Data?

    init(_ attachment: NoteAttachment, includePayload: Bool = true) {
        id = attachment.id
        digest = attachment.contentDigest
        filename = attachment.originalFilename
        byteCount = attachment.byteCount
        payload = includePayload ? attachment.payload : nil
    }

    init(id: UUID, digest: String, filename: String, byteCount: Int64? = nil, payload: Data?) {
        self.id = id
        self.digest = digest
        self.filename = filename
        self.byteCount = byteCount
        self.payload = payload
    }
}

struct ImportedAttachment: Sendable {
    let id: UUID
    let filename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let sortIndex: Int64
    let digest: String
    let createdAt: Date
    let payload: Data
}

enum AttachmentImportState: Equatable {
    case idle
    case importing(completed: Int, total: Int)
    case failed(String)
}

enum AttachmentLimits {
    static let maxBytesPerAttachment: Int64 = 15 * 1024 * 1024
    static let maxBytesPerNote: Int64 = 100 * 1024 * 1024
    static let maxAttachmentsPerNote = 20
    static let maxFilenameUTF8Bytes = 512
}
