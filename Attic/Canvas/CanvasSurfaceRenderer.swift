import CoreGraphics
import Foundation

final class CanvasPathCache {
    private struct Entry {
        let renderToken: UUID
        let path: CGPath
    }

    private var entries: [UUID: Entry] = [:]

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

    func prune(to strokes: [CanvasStroke]) {
        let visibleIDs = Set(strokes.map(\.id))
        entries = entries.filter { visibleIDs.contains($0.key) }
    }

    private static func makePath(
        points: [CanvasPoint]
    ) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }

        path.move(to: first.cgPoint)
        guard points.count > 1 else {
            path.addLine(to: first.cgPoint)
            return path
        }
        guard points.count > 2 else {
            path.addLine(to: points[1].cgPoint)
            return path
        }

        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(
                x: CGFloat((control.x + next.x) / 2),
                y: CGFloat((control.y + next.y) / 2)
            )
            path.addQuadCurve(
                to: midpoint,
                control: control.cgPoint
            )
        }
        path.addLine(to: points[points.count - 1].cgPoint)
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

    pathCache.prune(to: interaction.strokes)

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
        context.addPath(pathCache.path(for: stroke))
        context.setStrokeColor(strokeColor(stroke.color))
        context.setLineWidth(CGFloat(stroke.width))
        context.strokePath()
    }

    if let activePath = interaction.activePath {
        context.addPath(activePath)
        context.setStrokeColor(
            strokeColor(interaction.activeStrokeColor)
        )
        context.setLineWidth(
            CGFloat(interaction.activeStrokeWidth)
        )
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
