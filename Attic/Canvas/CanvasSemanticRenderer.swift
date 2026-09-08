#if os(macOS)
import AppKit
import CoreText

@MainActor
final class CanvasSemanticRenderCache {
    private struct Entry {
        let content: CanvasSemanticContent
        let color: NSColor
        let framesetter: CTFramesetter
    }
    private var entries: [UUID: Entry] = [:]

    func prepare(liveIDs: Set<UUID>) {
        entries = entries.filter { liveIDs.contains($0.key) }
    }

    func framesetter(for object: CanvasSemanticObject, content: CanvasSemanticContent) -> CTFramesetter {
        let color = content.color.nsColor.usingColorSpace(.deviceRGB) ?? content.color.nsColor
        if let entry = entries[object.id], entry.content == content, entry.color.isEqual(color) { return entry.framesetter }
        let result = CanvasSemanticRenderer.framesetter(content)
        if entries.count >= 128, let key = entries.keys.first { entries.removeValue(forKey: key) }
        entries[object.id] = Entry(content: content, color: color, framesetter: result)
        return result
    }
}

@MainActor
enum CanvasSemanticRenderer {
    static func readabilityEdgeColor(for ink: NSColor, increasedContrast: Bool) -> NSColor {
        let rgb = ink.usingColorSpace(.deviceRGB) ?? .black
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return (luminance >= 0.5 ? NSColor.black : NSColor.white)
            .withAlphaComponent(AtticClearGlassReadabilityPolicy.edgeOpacity(increasedContrast: increasedContrast))
    }

    static func font(_ content: CanvasSemanticContent, scale: Double = 1) -> NSFont {
        .systemFont(ofSize: content.fontSize * scale,
                    weight: content.fontWeight == "bold" ? .bold : content.fontWeight == "semibold" ? .semibold : .regular)
    }

    static func alignment(_ content: CanvasSemanticContent) -> NSTextAlignment {
        content.alignment == "center" ? .center : content.alignment == "right" ? .right : .left
    }

    static func framesetter(_ content: CanvasSemanticContent) -> CTFramesetter {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment(content)
        let text = NSAttributedString(string: content.text ?? "Unsupported object", attributes: [
            .font: font(content),
            .paragraphStyle: paragraph,
            .foregroundColor: content.color.nsColor
        ])
        return CTFramesetterCreateWithAttributedString(text)
    }

    static func textSize(_ content: CanvasSemanticContent, width: Double) -> CGSize {
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter(content), CFRange(location: 0, length: 0), nil,
            CGSize(width: max(24, width - 8), height: 100_000), nil
        )
        return CGSize(width: max(48, width), height: max(48, ceil(size.height) + 12))
    }

    static func defaultTextSize(_ content: CanvasSemanticContent) -> CGSize {
        textSize(content, width: 280)
    }

    static func draw(_ object: CanvasSemanticObject, in context: CGContext, cache: CanvasSemanticRenderCache,
                     clearReadabilityEnabled: Bool = false, increasedContrast: Bool = false) {
        let rect = object.worldRect
        context.saveGState()
        defer { context.restoreGState() }
        guard let content = object.content else {
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.stroke(rect)
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.strokePath()
            return
        }
        if clearReadabilityEnabled {
            context.setShadow(offset: .zero, blur: AtticClearGlassReadabilityPolicy.edgeRadius,
                color: readabilityEdgeColor(for: content.color.nsColor, increasedContrast: increasedContrast).cgColor)
        }
        if let shape = content.shape {
            let start = CanvasPoint(x: rect.minX + content.start.x * rect.width, y: rect.minY + content.start.y * rect.height)
            let end = CanvasPoint(x: rect.minX + content.end.x * rect.width, y: rect.minY + content.end.y * rect.height)
            let points = shape.points(from: start, to: end)
            guard let first = points.first else { return }
            context.setStrokeColor(content.color.nsColor.cgColor)
            context.setLineWidth(content.strokeWidth)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.move(to: first.cgPoint)
            for point in points.dropFirst() { context.addLine(to: point.cgPoint) }
            context.strokePath()
        } else {
            context.clip(to: rect)
            context.translateBy(x: rect.minX + 4, y: rect.maxY - 4)
            context.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, rect.width - 8), height: max(1, rect.height - 8)), transform: nil)
            let frame = CTFramesetterCreateFrame(cache.framesetter(for: object, content: content), CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }
    }
}
#endif
