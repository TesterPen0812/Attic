import Foundation

struct DrawPoint: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
}

struct DrawFrame: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 160
    var height: Double = 48
}

enum DrawColour: String, Codable, CaseIterable, Sendable { case ink, blue, red, green, orange }
enum DrawSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    // The working drawing is at 2×. All API geometry is in points.
    var strokeWidth: Double { switch self { case .small: 1.5; case .medium: 2.25; case .large: 4 } }
    var textSize: Double { switch self { case .small: 11; case .medium: 14; case .large: 20 } }
}
enum DrawCorners: String, Codable, CaseIterable, Sendable { case square, rounded }
enum DrawShape: String, Codable, CaseIterable, Sendable { case rectangle, ellipse, line, arrow }

struct DrawStyle: Codable, Equatable, Sendable {
    var colour: DrawColour = .ink
    var size: DrawSize = .medium
    var corners: DrawCorners = .square
}

struct DrawImage: Codable, Equatable, Sendable {
    var original: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var contentType: String = "public.png"
}

enum DrawContent: Codable, Equatable, Sendable {
    /// Finished, smoothed samples. The UI supplies smoothing; storage never resamples ink.
    case stroke([DrawPoint])
    case shape(DrawShape)
    case text(String)
    case image(DrawImage)
}

struct DrawObject: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var frame: DrawFrame = DrawFrame()
    var zIndex: Int64 = 0
    var style: DrawStyle = DrawStyle()
    var content: DrawContent
    var deletedAt: Date? = nil
    /// A text box whose width was set by its handles: its lines wrap to this
    /// many points. Nil keeps the box as wide as its longest line.
    var textWidth: Double? = nil

    var text: String { if case .text(let text) = content { text } else { "" } }
    var isImage: Bool { if case .image = content { true } else { false } }

    func translated(by offset: DrawPoint, id: UUID = UUID()) -> Self {
        var result = self
        result.id = id
        result.deletedAt = nil
        result.frame.x += offset.x
        result.frame.y += offset.y
        if case .stroke(let points) = content {
            result.content = .stroke(points.map { DrawPoint(x: $0.x + offset.x, y: $0.y + offset.y) })
        }
        return result
    }
}

struct DrawCanvas: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = "Untitled"
    var tags: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil
    /// Small, UI-rendered thumbnail only; never an original image or stroke body.
    var thumbnail: Data? = nil
    var textIndex: String = ""
}

struct DrawSnapshot: Equatable, Sendable {
    var canvas: DrawCanvas
    var objects: [DrawObject]
}

/// What Delete Permanently, Empty and the 30-day removal take out of the
/// store, matched by deletion time: anything restored and deleted again
/// since the list was read stays.
enum DrawPurgeTarget: Hashable, Sendable {
    case canvas(UUID, deletedAt: Date)
    case image(canvas: UUID, object: UUID, deletedAt: Date)
}

/// How many targets went for good, and how many stayed (their replicas
/// disagree, their deletion time moved, or their canvas has an unsettled edit).
struct DrawPurgeReport: Equatable, Sendable {
    var removed = 0
    var kept = 0
}

/// An image deleted from a live canvas, as Recently Deleted lists it: read
/// from metadata only, so `object`'s original bytes are empty.
struct DrawDeletedImage: Equatable, Sendable {
    var canvas: DrawCanvas
    var object: DrawObject
}

struct DrawSearchMatch: Equatable, Sendable {
    var canvas: DrawCanvas
    var matchingTextBoxIDs: [UUID]
}

enum DrawCommand: Sendable {
    /// Add, replace, transform or restyle any set of objects as one Undo step.
    case put([DrawObject])
    case remove([UUID])
    case restoreObjects([UUID])
    case rename(String)
    case tags([String])
    case thumbnail(Data?)
    case deleteCanvas
    case restoreCanvas
}

struct DrawDelta: Equatable, Sendable {
    var canvas: DrawCanvas
    var upserted: [DrawObject]
    var removedIDs: [UUID]
    var revision: UInt64
}

enum DrawSaveResult: Equatable, Sendable {
    case saved(DrawDelta)
    case unchanged
    case retry(String)
    case held(String)
    var isSaved: Bool { if case .saved = self { true } else { false } }
}

struct DrawPendingEdit: Equatable, Sendable {
    var canvas: DrawCanvas
    var objects: [DrawObject]
    var outcome: DrawSaveResult
}

enum DrawStoreError: Error { case missingCanvas, invalidClipboard, invalidObject, pendingEdit }

/// A session-scoped store. Retain it above page/panel lifetimes to retain Undo.
/// No selection, tool, viewport, AppKit or SwiftUI dependency is required.
@MainActor
protocol DrawStoreProtocol: AnyObject {
    var revision: UInt64 { get }
    var lastDelta: DrawDelta? { get }
    var pendingEdits: [UUID: DrawPendingEdit] { get }
    var hasUnsettledEdits: Bool { get }
    func library(deleted: Bool) throws -> [DrawCanvas]
    func search(_ query: String) throws -> [DrawSearchMatch]
    func create(name: String?) -> DrawCanvas
    func open(_ id: UUID) throws -> DrawSnapshot
    func deletedImages(in id: UUID) throws -> [DrawObject]
    /// Every image deleted from a live canvas, from metadata only (no
    /// original bytes, no thumbnails, no board state).
    func deletedImages() throws -> [DrawDeletedImage]
    /// Removes the targets for good, every physical replica of each; a
    /// target whose replicas disagree stays until they agree.
    func purge(_ targets: [DrawPurgeTarget]) -> DrawPurgeReport
    /// The 30-day removal: everything deleted strictly before `cutoff`.
    func purge(deletedBefore cutoff: Date) -> DrawPurgeReport
    func perform(_ command: DrawCommand, on id: UUID) -> DrawSaveResult
    func retry(on id: UUID) -> DrawSaveResult
    func reconcile(on id: UUID) -> DrawSaveResult
    func canUndo(on id: UUID) -> Bool
    func canRedo(on id: UUID) -> Bool
    func undo(on id: UUID) -> DrawSaveResult
    func redo(on id: UUID) -> DrawSaveResult
    func duplicate(_ id: UUID, name: String?) throws -> DrawCanvas?
    func copy(_ ids: [UUID], from id: UUID) throws -> Data
    func cut(_ ids: [UUID], from id: UUID) -> DrawSaveResult
    func paste(_ data: Data, into id: UUID, offset: DrawPoint) -> DrawSaveResult
    /// Fresh read after an external import. Refuses to discard an unsettled draft.
    func reload(_ id: UUID) throws
}

extension DrawStoreProtocol {
    func library() throws -> [DrawCanvas] { try library(deleted: false) }
    func create() -> DrawCanvas { create(name: nil) }
    func duplicate(_ id: UUID) throws -> DrawCanvas? { try duplicate(id, name: nil) }
    func paste(_ data: Data, into id: UUID) -> DrawSaveResult {
        paste(data, into: id, offset: DrawPoint(x: 12, y: 12))
    }
}
