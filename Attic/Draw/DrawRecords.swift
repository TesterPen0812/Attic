import CryptoKit
import Foundation
import SwiftData

/// New schema only. No relationship or adapter to any legacy Canvas entity.
@Model
final class DrawCanvasRecord {
    #Index<DrawCanvasRecord>([\.id])
    var id: UUID = UUID()
    var name: String = "Untitled"
    var tagsJSON: String = "[]"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil
    var thumbnailID: UUID? = nil
    /// The appearance the thumbnail was rendered for (true: dark); nil
    /// without one, or for one rendered before this was kept.
    var thumbnailDark: Bool? = nil
    var textIndex: String = ""

    init() {}
    func apply(_ canvas: DrawCanvas) throws {
        id = canvas.id; name = canvas.name
        tagsJSON = try DrawCodec.string(canvas.tags)
        createdAt = canvas.createdAt; updatedAt = canvas.updatedAt; deletedAt = canvas.deletedAt
        thumbnailID = canvas.thumbnail == nil ? nil : canvas.id
        thumbnailDark = canvas.thumbnail == nil ? nil : canvas.thumbnailDark
        textIndex = canvas.textIndex
    }
    func value(thumbnail: Data? = nil) throws -> DrawCanvas {
        DrawCanvas(id: id, name: name, tags: try DrawCodec.decode([String].self, from: tagsJSON),
                   createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt,
                   thumbnail: thumbnail, thumbnailDark: thumbnailID == nil ? nil : thumbnailDark, textIndex: textIndex)
    }
}

@Model
final class DrawObjectRecord {
    #Index<DrawObjectRecord>([\.id], [\.canvasID, \.id])
    var id: UUID = UUID()
    var canvasID: UUID = UUID()
    /// Versioned Codable geometry/style/content header. Contains no binary body.
    var header: String = ""
    var formatVersion: Int = 1
    var zIndex: Int64 = 0
    var deletedAt: Date? = nil
    var textIndex: String = ""
    var payloadDigest: String = ""

    init() {}
    func apply(_ object: DrawObject, canvasID: UUID) throws {
        id = object.id; self.canvasID = canvasID
        header = try DrawCodec.header(object)
        zIndex = object.zIndex; deletedAt = object.deletedAt; textIndex = object.text
        payloadDigest = DrawCodec.payload(object).map(DrawCodec.digest) ?? ""
    }
}

@Model
final class DrawPayloadRecord {
    #Index<DrawPayloadRecord>([\.role, \.id], [\.canvasID, \.role, \.id])
    var id: UUID = UUID()
    var canvasID: UUID = UUID()
    /// "object" for exact image originals or stroke samples; "thumbnail" for previews.
    var role: String = "object"
    var formatVersion: Int = 1
    var digest: String = ""
    @Attribute(.externalStorage) var bytes: Data = Data()

    init() {}
    func apply(_ bytes: Data, id: UUID, canvasID: UUID, role: String) {
        self.id = id; self.canvasID = canvasID; self.role = role
        self.bytes = bytes; digest = DrawCodec.digest(bytes)
    }
}

enum DrawCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }
    static func header(_ object: DrawObject) throws -> String {
        var header = object
        switch object.content {
        case .stroke: header.content = .stroke([])
        case .image(var image): image.original = Data(); header.content = .image(image)
        default: break
        }
        return try string(header)
    }
    static func payload(_ object: DrawObject) -> Data? {
        switch object.content {
        case .stroke(let points): return try? encode(points)
        case .image(let image): return image.original
        default: return nil
        }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
