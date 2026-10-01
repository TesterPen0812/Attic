import Foundation
import Darwin

struct WorkspaceOperationEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let contentType: String
        let digest: String
        var bytes: Data
        let byteCount: Int64
        private enum CodingKeys: String, CodingKey { case id, filename, contentType, digest, byteCount }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            filename = try values.decode(String.self, forKey: .filename)
            contentType = try values.decode(String.self, forKey: .contentType)
            digest = try values.decode(String.self, forKey: .digest)
            byteCount = try values.decode(Int64.self, forKey: .byteCount)
            bytes = Data()
        }
        init(_ staged: StagedNoteAttachment) {
            id = staged.id; filename = staged.filename; contentType = staged.contentTypeIdentifier
            digest = staged.digest; bytes = staged.data; byteCount = staged.byteCount
        }
    }
    let id: UUID
    let intent: String
    let tokens: [WorkspaceModelToken]
    let writes: Set<WorkspaceOwner>
    let inverseGuards: [WorkspaceModelToken]
    let preDraft: NoteDraftJournalEntry?
    let afterDocuments: [UUID: Data]
    let selection: [Int]
    let draftGeneration: UInt64
    let checkpointClaim: NoteRecoveryClaim?
    var payloads: [Payload]
    let historyEffect: Data?
    let replayOf: UUID?
    let compensationOf: UUID?
}

struct WorkspaceOperationClaim: Codable, Equatable, Sendable {
    let id: UUID
    let digest: String
}

/// Compile out all injected process death and thrown-save behavior in shipping.
enum WorkspaceCrashHook {
    static func reach(_ point: String) {
        #if ATTIC_OPERATION_CRASH_TESTS
        if ProcessInfo.processInfo.environment["ATTIC_CRASH_POINT"] == point {
            _exit(86)
        }
        #endif
    }
}
