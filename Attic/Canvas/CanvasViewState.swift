import Foundation

/// Small presentation preferences, separate from durable board content. No
/// selection, placement, or Undo history is restored after relaunch.
struct CanvasViewState: Codable, Equatable {
    var center: CanvasPoint
    var scale: Double
    var tool: CanvasTool
    var color: CanvasInkColor
    var width: Double

    var viewport: CanvasViewport { CanvasViewport(center: center, scale: scale) }
}

struct CanvasViewStateArchive: Codable {
    static let defaultsKey = "canvas.viewState.v1"
    var selectedCanvasID: UUID
    var boards: [UUID: CanvasViewState]
}
