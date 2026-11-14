import Foundation

struct DrawPoint: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    /// Nil for mouse/trackpad strokes. Tablet pressure is normalized to 0...1.
    /// Optional so old drawings keep their original constant-width rendering.
    var pressure: Double? = nil

    init(x: Double = 0, y: Double = 0, pressure: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    private enum CodingKeys: String, CodingKey { case x, y, pressure }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        pressure = try values.decodeIfPresent(Double.self, forKey: .pressure)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(x, forKey: .x)
        try values.encode(y, forKey: .y)
        try values.encodeIfPresent(pressure, forKey: .pressure)
    }
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
    /// A text box scaled with a group: its lines are laid out at the
    /// style's size and drawn this much larger or smaller, so they scale
    /// rather than reflow. Nil is 1.
    var textScale: Double? = nil

    var text: String { if case .text(let text) = content { text } else { "" } }
    /// The text's size as drawn, in points.
    var textPointSize: Double { style.size.textSize * (textScale ?? 1) }
    var isImage: Bool { if case .image = content { true } else { false } }

    /// The object without an image's original bytes (metadata reads).
    var header: Self {
        guard case .image(var image) = content else { return self }
        var result = self
        image.original = Data()
        result.content = .image(image)
        return result
    }

    func translated(by offset: DrawPoint, id: UUID = UUID()) -> Self {
        var result = self
        result.id = id
        result.deletedAt = nil
        result.frame.x += offset.x
        result.frame.y += offset.y
        if case .stroke(let points) = content {
            #if DEBUG
            DrawRasterProbe.recordTranslatedSamples(points.count)
            #endif
            result.content = .stroke(points.map { DrawPoint(x: $0.x + offset.x, y: $0.y + offset.y, pressure: $0.pressure) })
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
    /// The appearance `thumbnail` was rendered for (true: the dark board);
    /// nil without a thumbnail, or for one rendered before this was kept.
    var thumbnailDark: Bool? = nil
    var textIndex: String = ""
}

struct DrawSnapshot: Codable, Equatable, Sendable {
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
    /// Persist a new, empty canvas without adding an invisible object.
    case saveCanvas
    /// Add, replace, transform or restyle any set of objects as one Undo step.
    case put([DrawObject])
    case remove([UUID])
    case restoreObjects([UUID])
    case rename(String)
    case tags([String])
    /// Quiet: the rendered thumbnail and the appearance it was rendered for.
    case thumbnail(Data?, dark: Bool? = nil)
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
    /// The first unsaved edit's outcome (`.retry` or `.held`).
    var outcome: DrawSaveResult
    /// How many edits on this canvas wait to be saved, in order.
    var count = 1
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
    var recoveryIssue: String? { get }
    func library(deleted: Bool) throws -> [DrawCanvas]
    /// The live library list is metadata only; each row reads its thumbnail
    /// through `searchThumbnail` when it is built.
    func presentationLibrary() throws -> [DrawCanvas]
    func search(_ query: String) throws -> [DrawSearchMatch]
    /// The thumbnail of one realized row, without opening its drawing. The
    /// store keeps a bounded number of them; a miss reads this row and the
    /// uncached rows after it in the same window (a page of 12 in the order
    /// of the last list asked for, the menu's or the search's) in one batch.
    /// A canvas it has not listed yet refreshes the list first; nil means
    /// there is no such canvas.
    func searchThumbnail(_ id: UUID) throws -> DrawCanvas?
    func create(name: String?) -> DrawCanvas
    func open(_ id: UUID) throws -> DrawSnapshot
    /// The canvas presently owned by the Draw page; never evict its session.
    func activate(_ id: UUID)
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
    /// A bounded text burst is one physical write while retaining each
    /// keystroke as a separate session Undo step.
    func performTypingBurst(_ commands: [DrawCommand], on id: UUID) -> DrawSaveResult
    /// Agent-only write with physical replica preflight, without altering
    /// the owner's regular Draw command and Undo behavior.
    func performAgent(_ command: DrawCommand, on id: UUID) -> DrawSaveResult
    func retry(on id: UUID) -> DrawSaveResult
    func reconcile(on id: UUID) -> DrawSaveResult
    /// Abandon the last failed rename only if its physical write did not commit.
    /// Other queued edits, their recovery proof and their Undo history survive.
    func abandonPendingRename(on id: UUID, named name: String, restoring original: String) -> Bool
    func canUndo(on id: UUID) -> Bool
    func canRedo(on id: UUID) -> Bool
    /// Stable identity of the top history step; a foreign Draw edit must not
    /// be consumed by Recently Deleted's grouped Undo.
    func undoStepID(on id: UUID) -> UUID?
    func redoStepID(on id: UUID) -> UUID?
    /// A self-contained inverse sealed to the physical state after one saved
    /// edit, for the agent's versioned Undo journal across launches.
    func agentUndoProof(on id: UUID, stepID: UUID) -> Data?
    func undoAgentStep(on id: UUID, proof: Data) -> DrawSaveResult
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
    func presentationLibrary() throws -> [DrawCanvas] { try library() }
    func searchThumbnail(_ id: UUID) throws -> DrawCanvas? { try library().first { $0.id == id } }
    func performTypingBurst(_ commands: [DrawCommand], on id: UUID) -> DrawSaveResult {
        var result: DrawSaveResult = .unchanged
        for command in commands { result = perform(command, on: id) }
        return result
    }
    func performAgent(_ command: DrawCommand, on id: UUID) -> DrawSaveResult { perform(command, on: id) }
    func library() throws -> [DrawCanvas] { try library(deleted: false) }
    func create() -> DrawCanvas { create(name: nil) }
    func duplicate(_ id: UUID) throws -> DrawCanvas? { try duplicate(id, name: nil) }
    func paste(_ data: Data, into id: UUID) -> DrawSaveResult {
        paste(data, into: id, offset: DrawPoint(x: 12, y: 12))
    }
}
