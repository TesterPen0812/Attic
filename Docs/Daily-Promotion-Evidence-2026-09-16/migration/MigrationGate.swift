import CryptoKit
import Foundation
import SwiftData

enum GateError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GateError.assertion(message) }
}

let root = URL(fileURLWithPath: "/tmp/attic-promotion-migration-20260916", isDirectory: true)
let seedRoot = root.appendingPathComponent("seed-installed-8b03586", isDirectory: true)
let migratedRoot = root.appendingPathComponent("candidate-copy-f8a18a0", isDirectory: true)
let seedStore = seedRoot.appendingPathComponent("development.store")
let migratedStore = migratedRoot.appendingPathComponent("development.store")

let taskID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
let noteID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
let attachmentID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
let boardID = UUID(uuidString: "8A9475C5-85B2-4D51-9CF6-A8D7EE6A4E01")!
let strokeID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
let imageID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
let semanticID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
let childID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
// Large enough to force Core Data's external-binary storage path rather than
// merely marking small inline SQLite blobs with the external-storage option.
let attachmentPayload = Data(repeating: 0xA7, count: 2 * 1024 * 1024)
let imagePayload = Data(repeating: 0x5D, count: 3 * 1024 * 1024)
let strokePayload = Data("legacy-stroke-payload".utf8)
let semanticPayload = Data("legacy-semantic-payload".utf8)

// These seven declarations reproduce the persisted fields at installed commit
// 8b03586df79c6d667a6aea444b74f7167e552568. Nested qualification keeps the
// Swift symbols separate while SwiftData retains the original entity names.
private enum Installed8b03586 {
    @Model final class TaskItem {
        var id: UUID = UUID()
        var title: String = ""
        var statusRaw: String = "todo"
        var priorityRaw: String = "none"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        init() {}
    }

    @Model final class NoteItem {
        var id: UUID = UUID()
        var title: String = ""
        var body: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        init() {}
    }

    @Model final class NoteAttachment {
        var id: UUID = UUID()
        var noteID: UUID = UUID()
        var originalFilename: String = ""
        var contentTypeIdentifier: String = "public.data"
        var byteCount: Int64 = 0
        var sortIndex: Int64 = 0
        var contentDigest: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Attribute(.externalStorage) var payload: Data? = nil
        init() {}
    }

    @Model final class CanvasBoardItem {
        var id: UUID = boardID
        var name: String = "Canvas"
        var sortIndex: Int64 = 0
        var formatVersion: Int = 1
        var clearGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }

    @Model final class CanvasStrokeItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
        var payloadVersion: Int = 1
        var payload: Data = Data()
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }

    @Model final class CanvasImageItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
        @Attribute(.externalStorage) var encodedData: Data = Data()
        var contentType: String = "public.png"
        var pixelWidth: Int64 = 0
        var pixelHeight: Int64 = 0
        var centerX: Double = 0
        var centerY: Double = 0
        var width: Double = 32
        var height: Double = 32
        var zIndex: Int64 = 0
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }

    @Model final class CanvasSemanticObjectItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
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
        init() {}
    }
}

// Exact persisted fields at candidate f8a18a0. Unchanged entity declarations
// are repeated so the copied store is opened as one complete application schema.
private enum CandidateF8a18a0 {
    @Model final class TaskItem {
        var id: UUID = UUID()
        var title: String = ""
        var statusRaw: String = "todo"
        var priorityRaw: String = "none"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var completedAt: Date? = nil
        var manualOrder: Int64? = nil
        var parentID: UUID? = nil
        var imageReferencesData: Data? = nil
        init() {}
    }

    @Model final class NoteItem {
        var id: UUID = UUID()
        var title: String = ""
        var body: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        init() {}
    }

    @Model final class NoteAttachment {
        var id: UUID = UUID()
        var noteID: UUID = UUID()
        var originalFilename: String = ""
        var contentTypeIdentifier: String = "public.data"
        var byteCount: Int64 = 0
        var sortIndex: Int64 = 0
        var inlineOffset: Int? = nil
        var displayWidth: Double? = nil
        var displayHeight: Double? = nil
        var contentDigest: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Attribute(.externalStorage) var payload: Data? = nil
        init() {}
    }

    @Model final class CanvasBoardItem {
        var id: UUID = boardID
        var name: String = "Canvas"
        var sortIndex: Int64 = 0
        var formatVersion: Int = 1
        var clearGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }

    @Model final class CanvasStrokeItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
        var payloadVersion: Int = 1
        var payload: Data = Data()
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}
    }

    @Model final class CanvasImageItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
        @Attribute(.externalStorage) var encodedData: Data = Data()
        var encodedByteCount: Int64 = 0
        var contentDigest: String = ""
        var contentType: String = "public.png"
        var pixelWidth: Int64 = 0
        var pixelHeight: Int64 = 0
        var centerX: Double = 0
        var centerY: Double = 0
        var width: Double = 32
        var height: Double = 32
        var zIndex: Int64 = 0
        var boardGeneration: Int64 = 0
        var mutationVersion: Int64 = 1
        var tombstoned: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var deletedAt: Date? = nil
        init() {}

        @discardableResult
        func backfillPayloadMetadataIfNeeded() -> Bool {
            guard contentDigest.isEmpty, !encodedData.isEmpty else { return false }
            encodedByteCount = Int64(encodedData.count)
            contentDigest = SHA256.hash(data: encodedData).prefix(16).map {
                String(format: "%02x", $0)
            }.joined()
            return true
        }
    }

    @Model final class CanvasSemanticObjectItem {
        var id: UUID = UUID()
        var canvasID: UUID = boardID
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
        init() {}
    }
}

func installedSchema() -> Schema {
    Schema([
        Installed8b03586.TaskItem.self,
        Installed8b03586.NoteItem.self,
        Installed8b03586.NoteAttachment.self,
        Installed8b03586.CanvasBoardItem.self,
        Installed8b03586.CanvasStrokeItem.self,
        Installed8b03586.CanvasImageItem.self,
        Installed8b03586.CanvasSemanticObjectItem.self,
    ])
}

func candidateSchema() -> Schema {
    Schema([
        CandidateF8a18a0.TaskItem.self,
        CandidateF8a18a0.NoteItem.self,
        CandidateF8a18a0.NoteAttachment.self,
        CandidateF8a18a0.CanvasBoardItem.self,
        CandidateF8a18a0.CanvasStrokeItem.self,
        CandidateF8a18a0.CanvasImageItem.self,
        CandidateF8a18a0.CanvasSemanticObjectItem.self,
    ])
}

func makeContainer(schema: Schema, url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration(
        "development",
        schema: schema,
        url: url,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}

func checkpointStore(at url: URL) throws {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path, "PRAGMA wal_checkpoint(TRUNCATE);"]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try require(process.terminationStatus == 0, "sqlite checkpoint failed: \(stderr)")
    try stdout.write(to: root.appendingPathComponent("seed-checkpoint.log"), atomically: true, encoding: .utf8)
}

func treeHashes(at directory: URL) throws -> [String: String] {
    let manager = FileManager.default
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    guard let enumerator = manager.enumerator(
        at: resolvedDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [:] }
    var result: [String: String] = [:]
    for case let file as URL in enumerator {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let components = file.pathComponents
        let rootIndex = try components.lastIndex(of: directory.lastPathComponent)
            .unwrap("unable to relativize seed-tree path")
        let relative = components[(rootIndex + 1)...].joined(separator: "/")
        result[relative] = SHA256.hash(data: try Data(contentsOf: file)).map {
            String(format: "%02x", $0)
        }.joined()
    }
    return result
}

func seedInstalledStore() throws {
    let manager = FileManager.default
    try manager.createDirectory(at: seedRoot, withIntermediateDirectories: true)
    let container = try makeContainer(schema: installedSchema(), url: seedStore)
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let task = Installed8b03586.TaskItem()
    task.id = taskID
    task.title = "Installed task"
    task.statusRaw = "inProgress"
    task.priorityRaw = "high"
    task.createdAt = Date(timeIntervalSince1970: 100)
    task.updatedAt = Date(timeIntervalSince1970: 200)
    task.completedAt = nil
    task.manualOrder = 1_024
    context.insert(task)

    let note = Installed8b03586.NoteItem()
    note.id = noteID
    note.title = "Installed note"
    note.body = "First paragraph\nSecond paragraph"
    note.createdAt = Date(timeIntervalSince1970: 300)
    note.updatedAt = Date(timeIntervalSince1970: 400)
    context.insert(note)

    let attachment = Installed8b03586.NoteAttachment()
    attachment.id = attachmentID
    attachment.noteID = noteID
    attachment.originalFilename = "legacy.bin"
    attachment.contentTypeIdentifier = "public.data"
    attachment.byteCount = Int64(attachmentPayload.count)
    attachment.sortIndex = 9
    attachment.contentDigest = "installed-attachment-digest"
    attachment.createdAt = Date(timeIntervalSince1970: 500)
    attachment.updatedAt = Date(timeIntervalSince1970: 600)
    attachment.payload = attachmentPayload
    context.insert(attachment)

    let board = Installed8b03586.CanvasBoardItem()
    board.id = boardID
    board.name = "Installed board"
    board.sortIndex = 4
    board.formatVersion = 7
    board.clearGeneration = 2
    board.mutationVersion = 11
    board.createdAt = Date(timeIntervalSince1970: 700)
    board.updatedAt = Date(timeIntervalSince1970: 800)
    context.insert(board)

    let stroke = Installed8b03586.CanvasStrokeItem()
    stroke.id = strokeID
    stroke.canvasID = boardID
    stroke.payloadVersion = 3
    stroke.payload = strokePayload
    stroke.boardGeneration = 2
    stroke.mutationVersion = 12
    stroke.createdAt = Date(timeIntervalSince1970: 900)
    stroke.updatedAt = Date(timeIntervalSince1970: 1_000)
    context.insert(stroke)

    let image = Installed8b03586.CanvasImageItem()
    image.id = imageID
    image.canvasID = boardID
    image.encodedData = imagePayload
    image.contentType = "public.png"
    image.pixelWidth = 640
    image.pixelHeight = 480
    image.centerX = 12.5
    image.centerY = -9.25
    image.width = 320
    image.height = 240
    image.zIndex = 5
    image.boardGeneration = 2
    image.mutationVersion = 13
    image.createdAt = Date(timeIntervalSince1970: 1_100)
    image.updatedAt = Date(timeIntervalSince1970: 1_200)
    context.insert(image)

    let semantic = Installed8b03586.CanvasSemanticObjectItem()
    semantic.id = semanticID
    semantic.canvasID = boardID
    semantic.kind = "text"
    semantic.payloadVersion = 2
    semantic.payload = semanticPayload
    semantic.centerX = 40
    semantic.centerY = 50
    semantic.width = 180
    semantic.height = 60
    semantic.rotation = 0.25
    semantic.zIndex = 6
    semantic.boardGeneration = 2
    semantic.mutationVersion = 14
    semantic.createdAt = Date(timeIntervalSince1970: 1_300)
    semantic.updatedAt = Date(timeIntervalSince1970: 1_400)
    context.insert(semantic)

    try context.save()
}

func verifyAndMutateCandidate() throws {
    let container = try makeContainer(schema: candidateSchema(), url: migratedStore)
    let context = ModelContext(container)
    context.autosaveEnabled = false

    let tasks = try context.fetch(FetchDescriptor<CandidateF8a18a0.TaskItem>())
    let notes = try context.fetch(FetchDescriptor<CandidateF8a18a0.NoteItem>())
    let attachments = try context.fetch(FetchDescriptor<CandidateF8a18a0.NoteAttachment>())
    let boards = try context.fetch(FetchDescriptor<CandidateF8a18a0.CanvasBoardItem>())
    let strokes = try context.fetch(FetchDescriptor<CandidateF8a18a0.CanvasStrokeItem>())
    let images = try context.fetch(FetchDescriptor<CandidateF8a18a0.CanvasImageItem>())
    let semantics = try context.fetch(FetchDescriptor<CandidateF8a18a0.CanvasSemanticObjectItem>())
    try require(tasks.count == 1 && notes.count == 1 && attachments.count == 1, "legacy task/note/attachment counts changed")
    try require(boards.count == 1 && strokes.count == 1 && images.count == 1 && semantics.count == 1, "legacy canvas counts changed")

    let task = tasks[0]
    try require(task.id == taskID && task.title == "Installed task", "task identity/content changed")
    try require(task.statusRaw == "inProgress" && task.priorityRaw == "high" && task.manualOrder == 1_024, "task metadata changed")
    try require(task.createdAt == Date(timeIntervalSince1970: 100) && task.updatedAt == Date(timeIntervalSince1970: 200), "task timestamps changed")
    try require(task.parentID == nil && task.imageReferencesData == nil, "new task columns did not default to nil")

    let note = notes[0]
    try require(note.id == noteID && note.body == "First paragraph\nSecond paragraph", "note changed")
    let attachment = attachments[0]
    try require(attachment.id == attachmentID && attachment.noteID == noteID, "attachment identity changed")
    try require(attachment.payload == attachmentPayload && attachment.byteCount == Int64(attachmentPayload.count), "attachment external payload changed")
    try require(attachment.inlineOffset == nil && attachment.displayWidth == nil && attachment.displayHeight == nil, "new attachment columns did not default to nil")

    let board = boards[0]
    try require(board.id == boardID && board.name == "Installed board" && board.mutationVersion == 11, "board changed")
    let stroke = strokes[0]
    try require(stroke.id == strokeID && stroke.payload == strokePayload && stroke.mutationVersion == 12, "stroke changed")
    let semantic = semantics[0]
    try require(semantic.id == semanticID && semantic.payload == semanticPayload && semantic.mutationVersion == 14, "semantic object changed")

    let image = images[0]
    try require(image.id == imageID && image.encodedData == imagePayload, "image identity/external payload changed")
    try require(image.encodedByteCount == 0 && image.contentDigest.isEmpty, "new image columns did not receive legacy defaults")
    let oldImageMutation = image.mutationVersion
    let oldImageUpdated = image.updatedAt
    let oldImageGeneration = image.boardGeneration
    let oldImageTombstone = image.tombstoned
    try require(image.backfillPayloadMetadataIfNeeded(), "legacy image backfill did not run")
    try context.save()
    let expectedDigest = SHA256.hash(data: imagePayload).prefix(16).map { String(format: "%02x", $0) }.joined()
    try require(image.encodedByteCount == Int64(imagePayload.count) && image.contentDigest == expectedDigest, "image metadata backfill is incorrect")
    try require(image.encodedData == imagePayload, "image backfill changed payload bytes")
    try require(image.mutationVersion == oldImageMutation && image.updatedAt == oldImageUpdated && image.boardGeneration == oldImageGeneration && image.tombstoned == oldImageTombstone, "image backfill changed replica/user fields")

    task.imageReferencesData = Data("candidate-attachment-reference".utf8)
    attachment.inlineOffset = 6
    attachment.displayWidth = 320
    attachment.displayHeight = 180
    let child = CandidateF8a18a0.TaskItem()
    child.id = childID
    child.title = "Candidate child"
    child.parentID = taskID
    child.createdAt = Date(timeIntervalSince1970: 1_500)
    child.updatedAt = Date(timeIntervalSince1970: 1_500)
    context.insert(child)
    try context.save()
}

func verifyCandidateReopen() throws {
    let container = try makeContainer(schema: candidateSchema(), url: migratedStore)
    let context = ModelContext(container)
    let tasks = try context.fetch(FetchDescriptor<CandidateF8a18a0.TaskItem>())
    try require(tasks.count == 2, "candidate task insertion did not survive reopen")
    let parent = try tasks.first { $0.id == taskID }.unwrap("legacy task missing after reopen")
    let child = try tasks.first { $0.id == childID }.unwrap("candidate child missing after reopen")
    try require(parent.imageReferencesData == Data("candidate-attachment-reference".utf8), "candidate task data did not survive reopen")
    try require(child.parentID == taskID && child.title == "Candidate child", "candidate parent link did not survive reopen")

    let attachment = try context.fetch(FetchDescriptor<CandidateF8a18a0.NoteAttachment>()).first.unwrap("attachment missing after reopen")
    try require(attachment.payload == attachmentPayload, "attachment payload changed after reopen")
    try require(attachment.inlineOffset == 6 && attachment.displayWidth == 320 && attachment.displayHeight == 180, "candidate attachment columns did not survive reopen")

    let image = try context.fetch(FetchDescriptor<CandidateF8a18a0.CanvasImageItem>()).first.unwrap("image missing after reopen")
    let expectedDigest = SHA256.hash(data: imagePayload).prefix(16).map { String(format: "%02x", $0) }.joined()
    try require(image.encodedData == imagePayload && image.encodedByteCount == Int64(imagePayload.count) && image.contentDigest == expectedDigest, "backfilled image did not survive reopen")
    try require(image.mutationVersion == 13 && image.updatedAt == Date(timeIntervalSince1970: 1_200) && image.boardGeneration == 2, "image replica fields changed after reopen")
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw GateError.assertion(message) }
        return self
    }
}

@main
enum MigrationGate {
    static func main() {
        do {
            let manager = FileManager.default
            for directory in [seedRoot, migratedRoot] where manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
            try autoreleasepool {
                try seedInstalledStore()
            }
            try checkpointStore(at: seedStore)
            // SwiftData checkpoints the committed WAL into the main database as
            // its container closes. Remove only the empty WAL and its transient
            // shared-memory index so the baseline is a quiescent store family.
            let seedWAL = URL(fileURLWithPath: seedStore.path + "-wal")
            let seedSHM = URL(fileURLWithPath: seedStore.path + "-shm")
            if manager.fileExists(atPath: seedWAL.path) {
                let size = try seedWAL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                try require(size == 0, "installed seed WAL was not checkpointed")
                try manager.removeItem(at: seedWAL)
            }
            if manager.fileExists(atPath: seedSHM.path) {
                try manager.removeItem(at: seedSHM)
            }
            let originalHashes = try treeHashes(at: seedRoot)
            try require(!originalHashes.isEmpty, "seed store tree is empty")
            try manager.copyItem(at: seedRoot, to: migratedRoot)
            try autoreleasepool {
                try verifyAndMutateCandidate()
            }
            try autoreleasepool {
                try verifyCandidateReopen()
            }
            let finalOriginalHashes = try treeHashes(at: seedRoot)
            try require(originalHashes == finalOriginalHashes, "original seeded store tree changed during migration")

            let hashLines = originalHashes.keys.sorted().map { "\($0)  \(originalHashes[$0]!)" }.joined(separator: "\n") + "\n"
            try hashLines.write(to: root.appendingPathComponent("seed-tree-sha256.txt"), atomically: true, encoding: .utf8)
            print("MIGRATION_GATE=PASS")
            print("installed_sha=8b03586df79c6d667a6aea444b74f7167e552568")
            print("candidate_sha=f8a18a09b7d6cc914ab97fdfad252d1f2f8b3d6c")
            print("entities=7")
            print("seed_files=\(originalHashes.count)")
            print("original_seed_unchanged=true")
            print("candidate_round_trip=true")
            print("external_payloads_preserved=true")
            print("image_backfill_preserved_replica_fields=true")
        } catch {
            fputs("MIGRATION_GATE=FAIL\nerror=\(error)\n", stderr)
            exit(1)
        }
    }
}
