#if DEBUG
import AppKit
import SwiftUI

// Independent pixel and geometry measurements for the appearance check.
//
// The model checks trust what components declare (their ink, their radius
// token). These measurements trust only the rendered pixels: the glyph's
// colour is read from the glyph itself, and a control's corner radius and
// size are fitted to its rendered outline. A component that draws with the
// wrong ink, fades itself below the floor, or uses a different radius than
// it reports fails here even when its declarations are right.

// MARK: - Glyph contrast

extension AtticBitmap {
    /// The contrast of the glyph pixels inside `frame` against
    /// `background`, read from the pixels: the ink is the colour at the
    /// 85th percentile of the pixels that differ from the background (the
    /// glyph's core, not its antialiased edge, and robust to a few stray
    /// pixels). Nil when the frame holds no glyph pixels.
    func glyphContrast(in frame: CGRect, background: AtticRGBA, scale: CGFloat) -> (ratio: Double, ink: AtticRGBA)? {
        let minX = max(Int((frame.minX * scale).rounded(.down)), 0)
        let maxX = min(Int((frame.maxX * scale).rounded(.up)), width)
        let minY = max(Int((frame.minY * scale).rounded(.down)), 0)
        let maxY = min(Int((frame.maxY * scale).rounded(.up)), height)
        guard maxX > minX, maxY > minY else { return nil }
        let backgroundColour = background.themeColor
        var samples: [(ratio: Double, colour: AtticRGBA)] = []
        samples.reserveCapacity((maxX - minX) * (maxY - minY) / 3)
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let colour = pixel(x: x, y: y) else { continue }
                let ratio = colour.themeColor.contrastRatio(with: backgroundColour)
                if ratio > 1.12 { samples.append((ratio, colour)) }
            }
        }
        guard samples.count >= 3 else { return nil }
        samples.sort { $0.ratio > $1.ratio }
        let pick = samples[min(Int(Double(samples.count) * 0.15), samples.count - 1)]
        return (pick.ratio, pick.colour)
    }
}

// MARK: - Corner radius and size

/// Fits a rendered control's corner radius and measures its size, from
/// its pixels over a flat, known backdrop.
enum AtticCornerMeasure {
    /// The backdrop the control is rendered over: a colour no component
    /// uses, so every pixel's distance from it is the control's coverage.
    static let backdrop = AtticRGBA(0xFF00FF)
    /// The margin around the control in the render.
    static let margin: CGFloat = 24
    static let scale: CGFloat = 4
    /// Rendered in capture mode (`ImageRenderer` has no focus system and
    /// cannot draw AppKit), without reporting probes.
    static let captureContext = AtticCaptureContext(collector: nil, backdrop: .desktop(.midGrey))

    struct Measurement: Equatable {
        /// The control's rendered size, in points.
        let size: CGSize
        /// The best-fitting continuous-corner radius, in points.
        let radius: CGFloat
        /// Root-mean-square distance of the fitted outline, in pixels.
        let fitError: Double
    }

    /// The size `view` takes when it chooses (its ideal size).
    @MainActor
    static func naturalSize<V: View>(of view: V, context: AtticDesignContext) -> CGSize? {
        let renderer = ImageRenderer(content: view.fixedSize().atticDesign(context).environment(\.atticCapture, captureContext))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    /// Renders `view` alone over the backdrop and measures it. `layoutSize`
    /// is the size the view is laid out at (its ideal size when nil).
    /// `referenceX` is where, from the layout frame's leading edge, the
    /// control's own face is read (inside the edge; outside for a ring).
    @MainActor
    static func measure<V: View>(_ view: V, layoutSize: CGSize? = nil, referenceX: CGFloat = 3, context: AtticDesignContext) -> Measurement? {
        guard let size = layoutSize ?? naturalSize(of: view, context: context) else { return nil }
        let content = view
            .frame(width: size.width, height: size.height)
            .padding(margin)
            .background(backdrop.color)
            .atticDesign(context)
            .environment(\.atticCapture, captureContext)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage, let bitmap = AtticBitmap(image: image) else { return nil }
        return measure(bitmap: bitmap, layoutSize: size, referenceX: referenceX)
    }

    static func measure(bitmap: AtticBitmap, layoutSize: CGSize, referenceX referenceOffset: CGFloat = 3) -> Measurement? {
        // Coverage: how far each pixel has moved from the backdrop toward
        // the control's own face (read just inside its left edge, at mid-height).
        let referenceX = Int(((margin + referenceOffset) * scale).rounded())
        let referenceY = Int(((margin + layoutSize.height / 2) * scale).rounded())
        guard let face = bitmap.pixel(x: referenceX, y: referenceY) else { return nil }
        let full = distance(face, backdrop)
        guard full > 0.02 else { return nil }
        let coverage = { (x: Int, y: Int) -> Double in
            guard let colour = bitmap.pixel(x: x, y: y) else { return 0 }
            return min(distance(colour, backdrop) / full, 1)
        }

        // The bounds: every pixel at least half covered.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where coverage(x, y) >= 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let widthPx = maxX - minX + 1
        let heightPx = maxY - minY + 1
        let size = CGSize(width: CGFloat(widthPx) / scale, height: CGFloat(heightPx) / scale)

        // The top-left corner's outline: for each pixel row, where the
        // outline crosses half coverage, to a sub-pixel.
        let rows = min(heightPx / 2, Int(26 * scale))
        let span = min(widthPx / 2, Int(40 * scale))
        let measured = profile(rows: rows, span: span) { x, y in coverage(minX + x, minY + y) }

        var best = (radius: CGFloat(0), error: Double.infinity)
        var candidate: CGFloat = 1
        let limit = min(size.width, size.height) / 2
        while candidate <= min(limit, 26) {
            let reference = referenceProfile(size: CGSize(width: widthPx, height: heightPx), radiusPx: candidate * scale, rows: rows, span: span)
            let error = zip(measured, reference).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            if error < best.error { best = (candidate, error) }
            candidate += 0.25
        }
        return Measurement(size: size, radius: best.radius, fitError: (best.error / Double(max(rows, 1))).squareRoot())
    }

    private static func distance(_ a: AtticRGBA, _ b: AtticRGBA) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// For each row, the sub-pixel x where coverage first reaches 0.5
    /// (`span` when it never does within the span).
    private static func profile(rows: Int, span: Int, coverage: (Int, Int) -> Double) -> [Double] {
        (0..<rows).map { y in
            var previous = 0.0
            for x in 0..<span {
                let value = coverage(x, y)
                if value >= 0.5 {
                    let fraction = value == previous ? 0 : (0.5 - previous) / (value - previous)
                    return Double(x) - 1 + min(max(fraction, 0), 1)
                }
                previous = value
            }
            return Double(span)
        }
    }

    /// The same profile for a continuous rounded rectangle of this pixel
    /// size and radius, rasterised directly (antialiased, like SwiftUI).
    private static func referenceProfile(size: CGSize, radiusPx: CGFloat, rows: Int, span: Int) -> [Double] {
        let width = span + 2
        let height = rows
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return [] }
        context.setShouldAntialias(true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Draw the top-left corner region, flipped so row 0 is the top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let path = RoundedRectangle(cornerRadius: radiusPx, style: .continuous)
            .path(in: CGRect(origin: .zero, size: size))
            .cgPath
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return profile(rows: rows, span: span) { x, y in
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            return Double(bytes[y * width + x]) / 255
        }
    }
}

// MARK: - The geometry check

/// Measures a representative set of controls from their pixels and
/// compares the fitted corner radius and the rendered size with the tokens.
@MainActor
enum AtticGeometryCheck {
    struct Specimen {
        let name: String
        let view: AnyView
        var layoutSize: CGSize?
        var referenceX: CGFloat = 3
        /// Token size; a zero width or height is not judged.
        let expectedSize: CGSize
        let expectedRadius: CGFloat
    }

    struct Result {
        let specimen: String
        let measurement: AtticCornerMeasure.Measurement?
        let expectedSize: CGSize
        let expectedRadius: CGFloat

        /// Radii are fitted in quarter points; sizes are whole pixels at 4×.
        static let radiusTolerance: CGFloat = 0.5
        static let sizeTolerance: CGFloat = 0.5

        var problems: [String] {
            guard let m = measurement else { return ["could not be measured"] }
            var problems: [String] = []
            if abs(m.radius - expectedRadius) > Self.radiusTolerance {
                problems.append(String(format: "corner radius %.2f from pixels, token %.2f", m.radius, expectedRadius))
            }
            if expectedSize.width > 0, abs(m.size.width - expectedSize.width) > Self.sizeTolerance {
                problems.append(String(format: "width %.2f from pixels, token %.2f", m.size.width, expectedSize.width))
            }
            if expectedSize.height > 0, abs(m.size.height - expectedSize.height) > Self.sizeTolerance {
                problems.append(String(format: "height %.2f from pixels, token %.2f", m.size.height, expectedSize.height))
            }
            return problems
        }

        var line: String {
            guard let m = measurement else { return "\(specimen): not measured" }
            return String(format: "%@: radius %.2f / %.2f, size %.2f × %.2f (fit %.2f px)",
                          specimen, m.radius, expectedRadius, m.size.width, m.size.height, m.fitError)
        }
    }

    static func specimens(demo: AtticGalleryDemo = AtticGalleryDemo()) -> [Specimen] {
        let noop = demo.record("Geometry check")
        let tokens = AtticDesignContext.default.tokens
        let panelButton = AtticControlSize.panelButton
        let back = AtticControlSize.settingsBackButton
        let row = CGSize(width: AtticLayout.panelSize.width - 2 * AtticLayout.rowHighlightInset, height: AtticLayout.rowHighlightHeight)
        return [
            Specimen(name: "Single button", view: AnyView(AtticRaisedButton(systemName: "pin", label: "Pin", action: noop)),
                     expectedSize: panelButton, expectedRadius: 14.5),
            Specimen(name: "Settings back button", view: AnyView(AtticRaisedButton(systemName: "chevron.left", label: "Back", size: back, action: noop)),
                     expectedSize: back, expectedRadius: 14.5),
            Specimen(name: "Label button", view: AnyView(AtticRaisedButton(systemName: "list.bullet", title: "All notes", action: noop)),
                     expectedSize: CGSize(width: 0, height: 34), expectedRadius: 14.5),
            Specimen(name: "Page switch", view: AnyView(AtticPageSwitch(items: AtticGallerySamples.pages, selection: .constant(0))),
                     expectedSize: CGSize(width: 0, height: AtticControlSize.capsuleHeight), expectedRadius: 14.5),
            Specimen(name: "Add bar", view: AnyView(AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: noop)),
                     layoutSize: CGSize(width: 296, height: AtticControlSize.addBarHeight),
                     expectedSize: CGSize(width: 296, height: 36), expectedRadius: 15),
            Specimen(name: "Small control (pressed)", view: AnyView(AtticSmallButton(systemName: "flag", label: "Priority", action: noop).atticForcedState(.pressed)),
                     expectedSize: CGSize(width: AtticControlSize.smallMinWidth, height: AtticControlSize.smallHeight), expectedRadius: 12),
            Specimen(name: "Selection bar", view: AnyView(AtticSelectionBar(count: 3, actions: [.init(systemName: "flag", label: "Priority", handler: noop)])),
                     expectedSize: CGSize(width: 0, height: 36), expectedRadius: 15),
            Specimen(name: "Undo toast", view: AnyView(AtticUndoToast(message: "Task deleted", onUndo: noop)),
                     expectedSize: CGSize(width: 0, height: AtticControlSize.toastHeight), expectedRadius: 15),
            Specimen(name: "Tag chip", view: AnyView(AtticTagChip(name: "launch")),
                     expectedSize: CGSize(width: 0, height: AtticControlSize.tagHeight), expectedRadius: 7.5),
            Specimen(name: "Pop-over row (highlighted)", view: AnyView(AtticPopoverRow(systemName: "note.text", title: "Launch sync", isHighlighted: true, action: noop)),
                     layoutSize: CGSize(width: 208, height: AtticControlSize.smallHeight),
                     expectedSize: CGSize(width: 208, height: 28), expectedRadius: 12),
            Specimen(name: "Title menu (hover)", view: AnyView(AtticTitleMenu(title: "Launch sync", commands: []).atticForcedState(.hover)),
                     expectedSize: CGSize(width: 0, height: AtticTitleMenuMetrics.height), expectedRadius: 12),
            Specimen(name: "Task card", view: AnyView(
                        AtticTaskCard(model: .init(title: "Go to the appointment", priority: .high), actions: demo.taskActions("card"),
                                      cardActions: .init(toggleExpanded: noop, toggleSubtask: { _ in }, addSubtask: noop, openInTasks: noop))
                     ), layoutSize: CGSize(width: 288, height: AtticTaskCardMetrics.titleHeight),
                     expectedSize: CGSize(width: 288, height: AtticTaskCardMetrics.titleHeight), expectedRadius: AtticRadius.tile),
            Specimen(name: "Group card", view: AnyView(AtticGroupCard { Color.clear.frame(height: AtticLayout.groupedRowSingle) }),
                     layoutSize: CGSize(width: 400, height: AtticLayout.groupedRowSingle),
                     expectedSize: CGSize(width: 400, height: 40), expectedRadius: AtticRadius.groupCard),
            Specimen(name: "Content card", view: AnyView(AtticContentCard { Color.clear }),
                     layoutSize: CGSize(width: 300, height: 120),
                     expectedSize: CGSize(width: 300, height: 120), expectedRadius: AtticRadius.contentCard),
            Specimen(name: "Pop-over", view: AnyView(AtticPopover { Color.clear.frame(height: 64) }),
                     expectedSize: CGSize(width: AtticPopoverMetrics.defaultWidth, height: 64 + 2 * AtticPopoverMetrics.padding), expectedRadius: AtticRadius.popover),
            Specimen(name: "Palette tile", view: AnyView(AtticPaletteTile(palette: .original, action: noop)),
                     expectedSize: CGSize(width: AtticPaletteTileMetrics.width, height: 0), expectedRadius: AtticRadius.tile),
            Specimen(name: "Row highlight", view: AnyView(AtticHighlight(fill: tokens.selected)),
                     layoutSize: row, expectedSize: row, expectedRadius: AtticRadius.highlight),
            Specimen(name: "Focus ring on a row", view: AnyView(Color.clear.atticFocusRing(true, cornerRadius: AtticRadius.highlight)),
                     layoutSize: row, referenceX: -AtticRingMetrics.gap - AtticRingMetrics.width / 2,
                     expectedSize: CGSize(width: row.width + 2 * AtticRingMetrics.outset, height: row.height + 2 * AtticRingMetrics.outset),
                     expectedRadius: AtticRadius.ring(around: AtticRadius.highlight, offset: AtticRingMetrics.outset)),
            Specimen(name: "Subtask checkbox (done)", view: AnyView(AtticSubtaskCheckbox(isDone: true)),
                     expectedSize: CGSize(width: AtticControlSize.subtaskCheckbox, height: AtticControlSize.subtaskCheckbox),
                     expectedRadius: AtticRadius.subtaskCheckbox)
        ]
    }

    static func run(context: AtticDesignContext = .default) -> [Result] {
        specimens().map { specimen in
            Result(
                specimen: specimen.name,
                measurement: AtticCornerMeasure.measure(specimen.view, layoutSize: specimen.layoutSize, referenceX: specimen.referenceX, context: context),
                expectedSize: specimen.expectedSize,
                expectedRadius: specimen.expectedRadius
            )
        }
    }
}

extension AtticBitmap {
    /// The opaque colour of a pixel (nil when transparent or outside).
    func pixel(x: Int, y: Int) -> AtticRGBA? {
        colour(atX: (CGFloat(x) + 0.5) / 1, y: (CGFloat(y) + 0.5) / 1, scale: 1)
    }
}
#endif
