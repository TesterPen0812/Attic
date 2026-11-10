import CoreGraphics
import CoreText
import Foundation

/// The board's colours for the store's five (Planning.md, Draw › Style; the
/// working file's `COLORS`), resolved once per appearance so the renderer
/// never touches AppKit.
struct DrawPalette: Equatable, Sendable {
    let dark: Bool

    /// rgb, 0–255, light then dark (the dark ones are the system's dark
    /// variants; Ink turns light so it stays readable on the dark board).
    private static let values: [DrawColour: (light: (Double, Double, Double), dark: (Double, Double, Double))] = [
        .ink: ((29, 29, 31), (242, 242, 245)),
        .blue: ((0, 113, 227), (10, 132, 255)),
        .red: ((214, 52, 58), (255, 69, 58)),
        .green: ((36, 138, 61), (48, 209, 88)),
        .orange: ((214, 118, 18), (255, 159, 10)),
    ]

    func components(_ colour: DrawColour) -> (red: Double, green: Double, blue: Double) {
        let pair = Self.values[colour] ?? Self.values[.ink]!
        let rgb = dark ? pair.dark : pair.light
        return (rgb.0 / 255, rgb.1 / 255, rgb.2 / 255)
    }

    func cgColor(_ colour: DrawColour, alpha: Double = 1) -> CGColor {
        let c = components(colour)
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }
}

/// A raw pen event. Mouse/trackpad events have no pressure and keep a
/// constant-width stroke; tablet events retain their pressure through smoothing.
struct DrawInkSample: Equatable {
    var point: CGPoint
    var pressure: CGFloat? = nil
}

/// Ink: the pointer's raw samples become the finished, smoothed samples the
/// store keeps (`DrawContent.stroke`). The live layer draws the same
/// quadratic midpoint curve, so a stroke looks the same before and after
/// its raster is installed.
enum DrawInk {
    /// One sample per this many points along each curve piece.
    static let sampleSpacing: CGFloat = 1.5

    static func smooth(_ raw: [CGPoint]) -> [DrawPoint] {
        guard raw.count > 2 else { return raw.map { DrawPoint(x: $0.x, y: $0.y) } }
        var out: [CGPoint] = [raw[0]]
        var start = raw[0]
        for index in 1..<(raw.count - 1) {
            let control = raw[index]
            let end = mid(raw[index], raw[index + 1])
            appendQuad(from: start, control: control, to: end, into: &out)
            start = end
        }
        appendLine(from: start, to: raw[raw.count - 1], into: &out)
        return out.map { DrawPoint(x: $0.x, y: $0.y) }
    }

    static func smooth(_ raw: [DrawInkSample]) -> [DrawPoint] {
        func stored(_ sample: DrawInkSample) -> DrawPoint {
            DrawPoint(x: sample.point.x, y: sample.point.y, pressure: sample.pressure.map(Double.init))
        }
        guard raw.count > 2 else { return raw.map(stored) }
        var out = [stored(raw[0])]
        var start = raw[0]
        for index in 1..<(raw.count - 1) {
            let control = raw[index]
            let end = midpoint(control, raw[index + 1])
            let a = start.point, c = control.point, b = end.point
            let length = hypot(c.x - a.x, c.y - a.y) + hypot(b.x - c.x, b.y - c.y)
            let steps = max(1, Int((length / sampleSpacing).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps), u = 1 - t
                let p = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                                y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
                let pressure: CGFloat?
                if start.pressure == nil && control.pressure == nil && end.pressure == nil {
                    pressure = nil
                } else {
                    pressure = u * u * (start.pressure ?? 0.5) + 2 * u * t * (control.pressure ?? 0.5)
                        + t * t * (end.pressure ?? 0.5)
                }
                out.append(DrawPoint(x: p.x, y: p.y, pressure: pressure.map(Double.init)))
            }
            start = end
        }
        out.append(stored(raw[raw.count - 1]))
        return out
    }

    private static func midpoint(_ a: DrawInkSample, _ b: DrawInkSample) -> DrawInkSample {
        let pressure: CGFloat? = a.pressure == nil && b.pressure == nil ? nil : ((a.pressure ?? 0.5) + (b.pressure ?? 0.5)) / 2
        return DrawInkSample(point: mid(a.point, b.point), pressure: pressure)
    }

    /// Pressure 0...1 maps to 50...150% of the selected pen width.
    static func pressureWidth(_ pressure: Double?, base: CGFloat) -> CGFloat {
        guard let pressure, pressure.isFinite else { return base }
        return base * (0.5 + CGFloat(max(0, min(1, pressure))))
    }

    /// A filled ribbon with round ends. The same geometry is used for the
    /// in-progress layer and the committed bitmap, so the width never jumps.
    static func pressureOutline(_ samples: [DrawPoint], baseWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = samples.first else { return path }
        let firstRadius = pressureWidth(first.pressure, base: baseWidth) / 2
        if samples.count == 1 {
            path.addEllipse(in: CGRect(x: first.x - firstRadius, y: first.y - firstRadius,
                                       width: firstRadius * 2, height: firstRadius * 2))
            return path
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(samples.count)
        right.reserveCapacity(samples.count)
        for index in samples.indices {
            let point = samples[index]
            let previous = samples[max(0, index - 1)]
            let next = samples[min(samples.count - 1, index + 1)]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(0.00001, hypot(dx, dy))
            let radius = pressureWidth(point.pressure, base: baseWidth) / 2
            let offset = CGPoint(x: -dy / length * radius, y: dx / length * radius)
            left.append(CGPoint(x: point.x + offset.x, y: point.y + offset.y))
            right.append(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
        }
        path.move(to: left[0])
        left.dropFirst().forEach { path.addLine(to: $0) }
        right.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        let last = samples[samples.count - 1]
        for (point, radius) in [(first, firstRadius), (last, pressureWidth(last.pressure, base: baseWidth) / 2)] {
            path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        return path
    }

    static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    private static func appendQuad(from a: CGPoint, control c: CGPoint, to b: CGPoint, into out: inout [CGPoint]) {
        let length = hypot(c.x - a.x, c.y - a.y) + hypot(b.x - c.x, b.y - c.y)
        let steps = max(1, Int((length / sampleSpacing).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps), u = 1 - t
            out.append(CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                               y: u * u * a.y + 2 * u * t * c.y + t * t * b.y))
        }
    }

    private static func appendLine(from a: CGPoint, to b: CGPoint, into out: inout [CGPoint]) {
        guard a != b else { return }
        out.append(b)
    }

    /// The live curve through raw samples from `start`: quadratic midpoints,
    /// then a straight line to the latest sample.
    static func livePath(start: CGPoint, points: ArraySlice<CGPoint>, into path: CGMutablePath) {
        path.move(to: start)
        let list = Array(points)
        guard !list.isEmpty else { path.addLine(to: start); return }
        if list.count == 1 { path.addLine(to: list[0]); return }
        for index in 0..<(list.count - 1) {
            path.addQuadCurve(to: mid(list[index], list[index + 1]), control: list[index])
        }
        path.addLine(to: list[list.count - 1])
    }

    /// The live buffer uses typed pen samples; avoid allocating a copy of
    /// the entire long gesture just to draw its last 32 points.
    static func livePath(start: CGPoint, points: ArraySlice<DrawInkSample>, into path: CGMutablePath) {
        path.move(to: start)
        guard let first = points.first else { path.addLine(to: start); return }
        guard points.count > 1 else { path.addLine(to: first.point); return }
        let last = points.endIndex - 1
        for index in points.startIndex..<last {
            path.addQuadCurve(to: mid(points[index].point, points[index + 1].point), control: points[index].point)
        }
        path.addLine(to: points[last].point)
    }
}

/// Text boxes: the system font at the store's sizes, lines 1.25 apart, the
/// first baseline 1.05 × the size below the box's top (the working file).
enum DrawText {
    static let lineHeight: CGFloat = 1.25
    static let baseline: CGFloat = 1.05
    /// A new box starts this far above the click, in sizes (0.6).
    static let clickLift: CGFloat = 0.6
    /// An empty box is still this wide to click.
    static let minimumWidth: CGFloat = 6

    static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func line(_ text: String, size: CGFloat, colour: CGColor?) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font(size: size)]
        if let colour { attributes[.init(kCTForegroundColorAttributeName as String)] = colour }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// The lines as drawn: each paragraph, wrapped at `width` when the box
    /// has one (a text box's side handles set it).
    static func lines(_ text: String, size: CGFloat, width: CGFloat?) -> [String] {
        let paragraphs = lines(text)
        guard let width, width > 0 else { return paragraphs }
        let font = font(size: size)
        return paragraphs.flatMap { paragraph -> [String] in
            guard !paragraph.isEmpty else { return [paragraph] }
            let attributed = NSAttributedString(string: paragraph, attributes: [.init(kCTFontAttributeName as String): font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let utf16 = paragraph.utf16.count
            var result: [String] = [], start = 0
            while start < utf16 {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                if count <= 0 { count = 1 }
                let range = NSRange(location: start, length: min(count, utf16 - start))
                result.append((paragraph as NSString).substring(with: range).trimmingCharacters(in: .newlines))
                start += range.length
            }
            return result
        }
    }

    /// A box's size when its layout (at `fontSize`, wrapped at `wrap` drawn
    /// size) is drawn `scale` times larger: the same lines, scaled.
    static func size(of text: String, fontSize: CGFloat, width wrap: CGFloat?, scale: CGFloat) -> CGSize {
        guard scale != 1, scale > 0 else { return size(of: text, fontSize: fontSize, width: wrap) }
        let laid = size(of: text, fontSize: fontSize, width: wrap.map { $0 / scale })
        return CGSize(width: laid.width * scale, height: laid.height * scale)
    }

    static func size(of text: String, fontSize: CGFloat, width wrap: CGFloat? = nil) -> CGSize {
        let all = lines(text, size: fontSize, width: wrap)
        let height = CGFloat(all.count) * fontSize * lineHeight
        if let wrap, wrap > 0 { return CGSize(width: max(minimumWidth, wrap), height: height) }
        let width = all.map { CGFloat(CTLineGetTypographicBounds(line($0.isEmpty ? " " : $0, size: fontSize, colour: nil), nil, nil, nil)) }.max() ?? 0
        return CGSize(width: max(minimumWidth, width.rounded(.up)), height: height)
    }
}

/// Bounds, hit tests and paths for the store's objects (world points).
enum DrawGeometry {
    static func strokeWidth(_ object: DrawObject) -> CGFloat {
        let base = CGFloat(object.style.size.strokeWidth)
        guard case .stroke(let points) = object.content, !points.isEmpty else { return base }
        return points.reduce(CGFloat.zero) { max($0, DrawInk.pressureWidth($1.pressure, base: base)) }
    }

    static func frame(_ frame: DrawFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).standardized
    }

    /// A line or arrow keeps its direction in its frame: from (x, y) by
    /// (width, height), which may be negative.
    static func endpoints(_ frame: DrawFrame) -> (CGPoint, CGPoint) {
        (CGPoint(x: frame.x, y: frame.y), CGPoint(x: frame.x + frame.width, y: frame.y + frame.height))
    }

    static func lineFrame(from a: CGPoint, to b: CGPoint) -> DrawFrame {
        DrawFrame(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    static func boxFrame(from a: CGPoint, to b: CGPoint) -> DrawFrame {
        let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
        return DrawFrame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    static func strokeFrame(_ points: [DrawPoint]) -> DrawFrame {
        guard let first = points.first else { return DrawFrame(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x); minY = min(minY, point.y); maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return DrawFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// What the selection outline wraps.
    static func bounds(_ object: DrawObject) -> CGRect {
        let rect = frame(object.frame)
        switch object.content {
        case .stroke, .shape:
            let half = strokeWidth(object) / 2
            return rect.insetBy(dx: -half, dy: -half)
        case .text, .image:
            return rect
        }
    }

    static func union(_ objects: [DrawObject]) -> CGRect? {
        guard let first = objects.first else { return nil }
        return objects.dropFirst().reduce(bounds(first)) { $0.union(bounds($1)) }
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    static func hits(_ object: DrawObject, _ point: CGPoint, tolerance: CGFloat) -> Bool {
        let half = strokeWidth(object) / 2
        switch object.content {
        case .stroke(let samples):
            guard let first = samples.first else { return false }
            if samples.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance + half }
            for index in 0..<(samples.count - 1) {
                let a = CGPoint(x: samples[index].x, y: samples[index].y)
                let b = CGPoint(x: samples[index + 1].x, y: samples[index + 1].y)
                let base = CGFloat(object.style.size.strokeWidth)
                let radius = max(DrawInk.pressureWidth(samples[index].pressure, base: base),
                                 DrawInk.pressureWidth(samples[index + 1].pressure, base: base)) / 2
                if segmentDistance(point, a, b) <= tolerance + radius { return true }
            }
            return false
        case .shape(let shape) where shape == .line || shape == .arrow:
            let (a, b) = endpoints(object.frame)
            return segmentDistance(point, a, b) <= tolerance + half
        default:
            return bounds(object).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// The topmost object under `point` (objects are in drawing order).
    static func pick(_ objects: [DrawObject], at point: CGPoint, tolerance: CGFloat) -> DrawObject? {
        objects.last { hits($0, point, tolerance: tolerance) }
    }

    static let roundedCornerRadius: CGFloat = 14
    static func arrowHeadLength(width: CGFloat) -> CGFloat { 6 + width * 2 }

    /// The stroked outline of a stroke or shape, in world points.
    static func path(_ object: DrawObject) -> CGPath? {
        switch object.content {
        case .stroke(let samples):
            guard let first = samples.first else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: first.x, y: first.y))
            if samples.count == 1 { path.addLine(to: CGPoint(x: first.x, y: first.y)) }
            for sample in samples.dropFirst() { path.addLine(to: CGPoint(x: sample.x, y: sample.y)) }
            return path
        case .shape(let shape):
            return shapePath(shape, frame: object.frame, corners: object.style.corners, width: strokeWidth(object))
        case .text, .image:
            return nil
        }
    }

    static func shapePath(_ shape: DrawShape, frame drawFrame: DrawFrame, corners: DrawCorners, width: CGFloat) -> CGPath {
        let rect = frame(drawFrame)
        switch shape {
        case .rectangle:
            let radius = corners == .rounded ? min(roundedCornerRadius, rect.width / 2, rect.height / 2) : 0
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .line, .arrow:
            let (a, b) = endpoints(drawFrame)
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            if shape == .arrow, a != b {
                let angle = atan2(b.y - a.y, b.x - a.x), length = arrowHeadLength(width: width)
                func wing(_ turn: CGFloat) -> CGPoint {
                    CGPoint(x: b.x - cos(angle + turn) * length, y: b.y - sin(angle + turn) * length)
                }
                path.move(to: wing(0.5))
                path.addLine(to: b)
                path.addLine(to: wing(-0.5))
            }
            return path
        }
    }
}
