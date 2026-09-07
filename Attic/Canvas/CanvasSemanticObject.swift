import Foundation

struct CanvasSemanticTextDraft {
    let baseline: CanvasSemanticObject
    let text: String
    var isInsertion = false
    var key: CanvasReplicaKey { CanvasReplicaKey(canvasID: baseline.canvasID, id: baseline.id) }
}

struct CanvasSemanticContent: Codable, Equatable {
    var text: String?
    var shape: CanvasShapeKind?
    var color: CanvasInkColor
    var strokeWidth: Double
    var fontSize: Double = 24
    var fontWeight: String = "regular"
    var alignment: String = "left"
    var start: CanvasPoint = .zero
    var end: CanvasPoint = CanvasPoint(x: 1, y: 1)

    var isValid: Bool {
        strokeWidth.isFinite && strokeWidth > 0 && strokeWidth <= 16
            && fontSize.isFinite && (8...144).contains(fontSize)
            && ["regular", "semibold", "bold"].contains(fontWeight)
            && ["left", "center", "right"].contains(alignment)
            && start.isFinite && end.isFinite
            && (0...1).contains(start.x) && (0...1).contains(start.y)
            && (0...1).contains(end.x) && (0...1).contains(end.y)
            && ((text != nil && shape == nil && !(text ?? "").isEmpty
                && (text?.utf8.count ?? 0) <= 65_536)
                || (shape != nil && text == nil))
    }
}

struct CanvasSemanticObject: Identifiable, Equatable {
    let id: UUID
    let canvasID: UUID
    var kind: String
    var payloadVersion: Int
    var payload: Data
    var transform: CanvasImageTransform
    var rotation: Double
    var boardGeneration: Int64
    var mutationVersion: Int64
    var createdAt: Date
    var updatedAt: Date
    var content: CanvasSemanticContent?

    /// An unsaved insertion point, never passed to persistence before typing.
    init(textInsertionAt origin: CanvasPoint, canvasID: UUID, generation: Int64,
         content: CanvasSemanticContent, width: Double) {
        id = UUID()
        self.canvasID = canvasID
        kind = "text"
        payloadVersion = 1
        payload = Data()
        transform = CanvasImageTransform(center: CanvasPoint(x: origin.x + width / 2, y: origin.y + 24),
                                         width: width, height: 48, zIndex: 0)
        rotation = 0
        boardGeneration = generation
        mutationVersion = 0
        createdAt = Date()
        updatedAt = createdAt
        self.content = content
    }

    init(_ row: CanvasSemanticObjectItem) {
        id = row.id
        canvasID = row.canvasID
        kind = row.kind
        payloadVersion = row.payloadVersion
        payload = row.payload
        transform = CanvasImageTransform(center: CanvasPoint(x: row.centerX, y: row.centerY), width: row.width, height: row.height, zIndex: row.zIndex)
        rotation = row.rotation
        boardGeneration = row.boardGeneration
        mutationVersion = row.mutationVersion
        createdAt = row.createdAt
        updatedAt = row.updatedAt
        // A 64 KB UTF-8 string can expand sixfold as escaped JSON. Keep the
        // decode bound compatible with every content value accepted for save.
        let decoded = row.payloadVersion == 1 && row.payload.count <= 6 * 65_536 + 4_096
            ? try? JSONDecoder().decode(CanvasSemanticContent.self, from: row.payload) : nil
        content = decoded.flatMap { value in
            guard value.isValid,
                  (row.kind == "text" && value.text != nil)
                    || (row.kind == "shape" && value.shape != nil) else { return nil }
            return value
        }
    }

    var worldRect: CGRect {
        CGRect(x: transform.center.x - transform.width / 2,
               y: transform.center.y - transform.height / 2,
               width: transform.width, height: transform.height)
    }

    var title: String {
        if let text = content?.text { return text }
        return content?.shape?.title ?? "Unsupported object"
    }
}
