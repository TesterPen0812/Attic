import AppKit
import CryptoKit
import Foundation
import SwiftData

/// Disposable, deterministic fixture. The caller has already proved ownership of
/// a temporary directory; no production container or attachment root is used.
@MainActor
enum PerformanceSeed {
    // Version 1 remains the no-history fixture; version 2 changes Done history.
    static let version = 2
    static let taskCount = 500
    static let noteCount = 200
    static let canvasCount = 20
    static let objectsPerCanvas = 2_000
    static let doneHistoryCount = 5_000

    private struct Random {
        var state: UInt64 = 0x4154_5449_4350_4552
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
        mutating func number(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        mutating func identifier() -> UUID {
            let a = next(), b = next()
            return UUID(uuidString: String(format: "%016llx%016llx", a, b).enumerated().map { index, character in
                [8, 12, 16, 20].contains(index) ? "-\(character)" : String(character)
            }.joined())!
        }
    }

    static func generate(
        in container: ModelContainer,
        root: URL,
        includeDoneHistory: Bool,
        now: Date = Date()
    ) throws {
        let context = ModelContext(container)
        var random = Random()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let image = try makeImage()
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let taskImageRoot = root.appendingPathComponent("TaskImages", isDirectory: true)
        let statuses: [TaskStatus] = [.todo, .todo, .inProgress, .backlog, .done]
        let priorities: [TaskPriority] = [.none, .none, .none, .low, .medium, .high]
        var parents: [UUID] = []

        for index in 0..<taskCount {
            let id = random.identifier()
            let parentID = index % 5 == 4 ? parents[random.number(parents.count)] : nil
            if parentID == nil { parents.append(id) }
            let status = statuses[random.number(statuses.count)]
            let created = today.addingTimeInterval(TimeInterval(-random.number(60) * 86_400 - 3_600))
            let item = TaskItem(
                id: id,
                title: "\(["Review", "Draft", "Check", "Plan", "Send", "Organise"][random.number(6)]) project \(index)",
                status: status,
                priority: priorities[random.number(priorities.count)],
                createdAt: created,
                completedAt: status == .done ? today.addingTimeInterval(3_600) : nil,
                manualOrder: Int64(index * 1_024),
                parentID: parentID
            )
            if index % 23 == 0 {
                let attachmentID = random.identifier()
                let name = "task-image-\(index).png"
                let directory = taskImageRoot.appendingPathComponent(attachmentID.uuidString, isDirectory: true)
                    .appendingPathComponent(digest, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.write(to: directory.appendingPathComponent(name), options: .atomic)
                item.imageReferencesData = try JSONEncoder().encode([
                    TaskImageReference(id: attachmentID, filename: name, digest: digest,
                                       contentTypeIdentifier: "public.png", byteCount: Int64(image.count))
                ])
            }
            // A store this version wrote: no one-time order migration runs at
            // launch, so it never lands inside a measured phase.
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try context.save()

        if includeDoneHistory {
            for index in 0..<doneHistoryCount {
                let completed = today.addingTimeInterval(
                    TimeInterval(-(1 + index % 365) * 86_400 + 1 + index % 3_600)
                )
                let created = completed.addingTimeInterval(
                    TimeInterval(-(1 + random.number(30)) * 86_400 - 3_600)
                )
                let item = TaskItem(
                    id: random.identifier(), title: "Finished item \(index)", status: .done,
                    priority: priorities[random.number(priorities.count)], createdAt: created,
                    completedAt: completed
                )
                // The daily move keeps the row and completion date, marking
                // every moved task with the same cleanup timestamp.
                item.doneLoggedAt = now
                item.listOrderVersion = TaskItem.currentListOrderVersion
                context.insert(item)
                if index % 500 == 499 { try context.save() }
            }
            try context.save()
        }

        for index in 0..<noteCount {
            let id = random.identifier()
            let length = [80, 400, 2_000, 8_000][random.number(4)]
            let sentence = "Notes for project \(index). Follow up with the team and record decisions. "
            let body = String(repeating: sentence, count: max(1, length / sentence.count))
            context.insert(NoteItem(id: id, title: "Project note \(index)", body: body,
                                    createdAt: today.addingTimeInterval(TimeInterval(-index * 3_600))))
            if index % 17 == 0 {
                context.insert(NoteAttachment(
                    id: random.identifier(), noteID: id, originalFilename: "note-image-\(index).png",
                    contentTypeIdentifier: "public.png", byteCount: Int64(image.count),
                    sortIndex: 0, contentDigest: digest, payload: image
                ))
            }
        }
        try context.save()

        let encoder = JSONEncoder()
        for boardIndex in 0..<canvasCount {
            let boardID = random.identifier()
            context.insert(CanvasBoardItem(id: boardID, name: "Performance canvas \(boardIndex)",
                                           sortIndex: Int64(boardIndex)))
            for objectIndex in 0..<objectsPerCanvas {
                let id = random.identifier()
                let x = Double(objectIndex % 50) * 90 + Double(random.number(20))
                let y = Double(objectIndex / 50) * 75 + Double(random.number(20))
                switch objectIndex % 20 {
                case 0:
                    context.insert(CanvasImageItem(
                        id: id, canvasID: boardID, encodedData: image,
                        contentType: "public.png", pixelWidth: 128, pixelHeight: 128,
                        centerX: x, centerY: y, width: 96, height: 96,
                        zIndex: Int64(objectIndex)
                    ))
                case 1, 2:
                    let isText = objectIndex % 20 == 1
                    let content = CanvasSemanticContent(
                        text: isText ? "Canvas \(boardIndex) label \(objectIndex)" : nil,
                        shape: isText ? nil : .rectangle, color: .blue, strokeWidth: 2
                    )
                    let row = CanvasSemanticObjectItem(id: id, canvasID: boardID)
                    row.kind = isText ? "text" : "shape"
                    row.payload = try encoder.encode(content)
                    row.centerX = x; row.centerY = y
                    row.zIndex = Int64(objectIndex)
                    context.insert(row)
                default:
                    let strokePayload = try CanvasStrokeCodec.encode(
                        color: [.ink, .blue, .red, .green][random.number(4)],
                        width: Double(1 + random.number(4)),
                        points: (0..<8).map { offset in
                            CanvasPoint(x: x + Double(offset * 4),
                                        y: y + Double(offset * 3 + random.number(3)))
                        }
                    )
                    context.insert(CanvasStrokeItem(
                        id: id, canvasID: boardID, payload: strokePayload
                    ))
                }
                if objectIndex % 500 == 499 { try context.save() }
            }
            try context.save()
        }
        guard try context.fetchCount(FetchDescriptor<TaskItem>()) == taskCount
                    + (includeDoneHistory ? doneHistoryCount : 0),
              try context.fetchCount(FetchDescriptor<NoteItem>()) == noteCount,
              try context.fetchCount(FetchDescriptor<CanvasBoardItem>()) == canvasCount,
              try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()) == canvasCount * 1_700,
              try context.fetchCount(FetchDescriptor<CanvasSemanticObjectItem>()) == canvasCount * 200,
              try context.fetchCount(FetchDescriptor<CanvasImageItem>()) == canvasCount * 100 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func makeImage() throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for y in 0..<128 {
            for x in 0..<128 {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(x) / 127,
                                        green: CGFloat(y) / 127, blue: 0.4, alpha: 1), atX: x, y: y)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
