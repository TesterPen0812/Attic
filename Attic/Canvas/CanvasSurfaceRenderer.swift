import CoreGraphics
import Foundation

final class CanvasPathCache {
    private struct Entry {
        let renderToken: UUID
        let path: CGPath
    }

    private var entries: [UUID: Entry] = [:]
    private var preparedKeys: [CanvasStrokeRenderKey] = []

    var cachedPathCount: Int { entries.count }

    func prepare(for strokes: [CanvasStroke]) {
        if preparedKeys.count == strokes.count {
            var unchanged = true
            for index in strokes.indices where preparedKeys[index] != strokes[index].renderKey {
                unchanged = false
                break
            }
            if unchanged { return }
        }

        let keys = strokes.map(\.renderKey)
        preparedKeys = keys
        let visibleIDs = Set(keys.map(\.id))
        entries = entries.filter { visibleIDs.contains($0.key) }
    }

    func path(for stroke: CanvasStroke) -> CGPath {
        if let entry = entries[stroke.id],
           entry.renderToken == stroke.renderToken {
            return entry.path
        }

        let path = Self.makePath(points: stroke.points)
        entries[stroke.id] = Entry(
            renderToken: stroke.renderToken,
            path: path
        )
        return path
    }

    private static func makePath(points: [CanvasPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }

        path.move(to: first.cgPoint)
        if points.count == 1 {
            path.addLine(to: first.cgPoint)
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point.cgPoint)
            }
        }
        return path
    }
}

func drawCanvas(
    in context: CGContext,
    bounds: CGRect,
    interaction: CanvasInteractionController,
    pathCache: CanvasPathCache,
    backgroundColor: CGColor,
    strokeColor: (CanvasInkColor) -> CGColor,
    eraserOutlineColor: CGColor
) {
    context.saveGState()
    context.setFillColor(backgroundColor)
    context.fill(bounds)
    context.clip(to: bounds)

    pathCache.prepare(for: interaction.strokes)

    let worldViewport = interaction.viewport.worldRect(
        for: bounds,
        in: bounds.size
    )
    let cullingMargin = CGFloat(64 / interaction.viewport.scale)
    let cullingRect = worldViewport.insetBy(
        dx: -cullingMargin,
        dy: -cullingMargin
    )

    context.saveGState()
    context.translateBy(x: bounds.midX, y: bounds.midY)
    context.scaleBy(
        x: CGFloat(interaction.viewport.scale),
        y: CGFloat(interaction.viewport.scale)
    )
    context.translateBy(
        x: -CGFloat(interaction.viewport.center.x),
        y: -CGFloat(interaction.viewport.center.y)
    )
    context.setLineCap(.round)
    context.setLineJoin(.round)

    for stroke in interaction.strokes {
        guard stroke.bounds?.intersects(cullingRect) != false else {
            continue
        }
        context.addPath(pathCache.path(for: stroke))
        context.setStrokeColor(strokeColor(stroke.color))
        context.setLineWidth(CGFloat(stroke.width))
        context.strokePath()
    }

    if let activePath = interaction.activePath {
        context.addPath(activePath)
        context.setStrokeColor(strokeColor(interaction.activeStrokeColor))
        context.setLineWidth(CGFloat(interaction.activeStrokeWidth))
        context.strokePath()
    }
    context.restoreGState()

    if let eraserWorldPoint = interaction.eraserWorldPoint {
        let viewPoint = interaction.viewport.viewPoint(
            for: eraserWorldPoint,
            in: bounds.size
        )
        let radius = CGFloat(
            interaction.eraserRadiusWorld * interaction.viewport.scale
        )
        context.setStrokeColor(eraserOutlineColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(
            x: viewPoint.x - radius,
            y: viewPoint.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    context.restoreGState()
}
