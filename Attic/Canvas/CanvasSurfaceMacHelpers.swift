#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CanvasCursorRole: Equatable {
    case arrow
    case pen
    case eraser
    case textPlacement
    case shapePlacement
    case openHand
    case closedHand
    case resizeTopLeftBottomRight
    case resizeTopRightBottomLeft
}

@MainActor
private enum CanvasToolCursors {
    static let pen = symbolCursor(
        primaryName: "pencil.tip",
        fallbackName: "pencil",
        hotSpot: CGPoint(x: 5, y: 19)
    )
    static let eraser = symbolCursor(
        primaryName: "eraser.fill",
        fallbackName: "eraser",
        hotSpot: CGPoint(x: 12, y: 12)
    )

    private static func symbolCursor(
        primaryName: String,
        fallbackName: String,
        hotSpot: CGPoint
    ) -> NSCursor {
        let symbol = NSImage(systemSymbolName: primaryName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil)
        guard let configured = symbol?.withSymbolConfiguration(
            .init(pointSize: 16, weight: .semibold)
        ) else {
            return .crosshair
        }

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        configured.draw(
            in: NSRect(x: 3, y: 3, width: 18, height: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: hotSpot)
    }
}

extension CanvasNSView {
    var selectedImage: CanvasPlacedImage? {
        guard let selectedImageID else { return nil }
        return imagesForDisplay.first { $0.id == selectedImageID }
    }

    var imagesForDisplay: [CanvasPlacedImage] {
        guard let selectedImageID,
              let previewImageTransform else {
            return images
        }
        return images.map {
            $0.id == selectedImageID
                ? $0.replacingTransform(previewImageTransform)
                : $0
        }
    }

    var baseCursor: NSCursor {
        cursor(for: baseCursorRole)
    }

    var baseCursorRole: CanvasCursorRole {
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case let .resizing(_, handle, _): return resizeCursorRole(for: handle)
        case .none: break
        }
        if shapePointerMode != nil { return .shapePlacement }
        switch pendingPlacement {
        case .text: return .textPlacement
        case .shape: return .shapePlacement
        case nil: return toolCursorRole
        }
    }

    func cursor(at viewPoint: CGPoint) -> NSCursor {
        cursor(for: cursorRole(at: viewPoint))
    }

    func cursorRole(at viewPoint: CGPoint) -> CanvasCursorRole {
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case let .resizing(_, handle, _): return resizeCursorRole(for: handle)
        case .none: break
        }
        if shapePointerMode != nil { return .shapePlacement }
        switch pendingPlacement {
        case .text: return .textPlacement
        case .shape: return .shapePlacement
        case nil: break
        }
        guard interaction.tool == .select else { return toolCursorRole }
        if let selectedImage,
           let handle = CanvasImagePlacement.resizeHandle(
                at: viewPoint,
                image: selectedImage,
                viewport: interaction.viewport,
                viewportSize: bounds.size,
                radius: 9
           ) {
            return resizeCursorRole(for: handle)
        }
        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        if CanvasImagePlacement.topmostImage(
            at: worldPoint,
            images: imagesForDisplay
        ) != nil {
            return .openHand
        }
        return .arrow
    }

    var toolCursorRole: CanvasCursorRole {
        switch interaction.tool {
        case .select: .arrow
        case .pen: .pen
        case .eraser: .eraser
        }
    }

    func cursor(for role: CanvasCursorRole) -> NSCursor {
        switch role {
        case .arrow: .arrow
        case .pen: CanvasToolCursors.pen
        case .eraser: CanvasToolCursors.eraser
        case .textPlacement: .iBeam
        case .shapePlacement: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeTopLeftBottomRight:
            if #available(macOS 15.0, *) {
                .frameResize(position: .topLeft, directions: .all)
            } else {
                .crosshair
            }
        case .resizeTopRightBottomLeft:
            if #available(macOS 15.0, *) {
                .frameResize(position: .topRight, directions: .all)
            } else {
                .crosshair
            }
        }
    }

    func resizeCursorRole(
        for handle: CanvasImageResizeHandle
    ) -> CanvasCursorRole {
        switch handle {
        case .topLeft, .bottomRight: .resizeTopLeftBottomRight
        case .topRight, .bottomLeft: .resizeTopRightBottomLeft
        }
    }

    func beginPan(at point: CGPoint) {
        interruptViewportGestureForPointer()
        discardImagePreview()
        discardShapePreview()
        _ = interaction.beginViewportGesture()
        panLastPoint = point
        needsDisplay = true
        NSCursor.closedHand.set()
    }

    @discardableResult
    func finishShapeInteraction(at viewPoint: CGPoint) -> Bool {
        guard let shapePointerMode else { return false }
        let endWorldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        let dragDistance = hypot(
            viewPoint.x - shapePointerMode.startViewPoint.x,
            viewPoint.y - shapePointerMode.startViewPoint.y
        )
        self.shapePointerMode = nil
        shapePreview = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)

        guard dragDistance >= 4, endWorldPoint.isFinite else {
            return true
        }
        onCompleteShape(
            shapePointerMode.kind,
            shapePointerMode.startWorldPoint,
            endWorldPoint
        )
        return true
    }

    func discardShapePreview() {
        shapePointerMode = nil
        shapePreview = nil
        needsDisplay = true
    }

    @discardableResult
    func beginViewportGestureSequence(
        source: ViewportGestureSource,
        mode: ViewportGestureMode
    ) -> Bool {
        let requested = ViewportGestureSequence(source: source, mode: mode)
        if let activeViewportGesture {
            return activeViewportGesture == requested
        }
        guard panLastPoint == nil else { return false }

        discardImagePreview()
        discardShapePreview()
        _ = interaction.beginViewportGesture()
        activeViewportGesture = requested
        return true
    }

    func finishViewportGestureSequence(
        source: ViewportGestureSource,
        at viewPoint: CGPoint
    ) {
        guard activeViewportGesture?.source == source else { return }
        interaction.finishViewportGesture()
        activeViewportGesture = nil
        window?.invalidateCursorRects(for: self)
        cursor(at: viewPoint).set()
    }

    func interruptViewportGestureForPointer() {
        let interruptedScroll = activeViewportGesture?.source == .scroll
            || pendingScrollMomentumMode != nil
        let interruptedMagnification = activeViewportGesture?.source == .magnification

        if activeViewportGesture != nil {
            interaction.finishViewportGesture()
            activeViewportGesture = nil
        }
        pendingScrollMomentumMode = nil
        if interruptedScroll { suppressesScrollMomentum = true }
        if interruptedMagnification { suppressesMagnification = true }
    }

    func resetViewportGestureRouting() {
        activeViewportGesture = nil
        pendingScrollMomentumMode = nil
        suppressesScrollMomentum = false
        suppressesMagnification = false
    }

    func applyViewportPan(by translation: CGSize) {
        guard translation.width.isFinite,
              translation.height.isFinite,
              translation.width != 0 || translation.height != 0 else {
            return
        }
        let previous = interaction.viewport
        let viewport = interaction.pan(byViewTranslation: translation)
        guard viewport != previous else { return }
        onViewportChange(viewport)
        needsDisplay = true
    }

    func applyViewportZoom(
        by factor: Double,
        anchoredAt viewPoint: CGPoint,
        in viewportSize: CGSize
    ) {
        guard factor.isFinite, factor > 0, factor != 1 else { return }
        let previous = interaction.viewport
        let viewport = interaction.zoom(
            by: factor,
            anchoredAt: viewPoint,
            in: viewportSize
        )
        guard viewport != previous else { return }
        onViewportChange(viewport)
        needsDisplay = true
    }

    func continuePan(to point: CGPoint) {
        guard let panLastPoint else { return }
        let translation = CGSize(
            width: point.x - panLastPoint.x,
            height: point.y - panLastPoint.y
        )
        self.panLastPoint = point
        let viewport = interaction.pan(byViewTranslation: translation)
        onViewportChange(viewport)
        needsDisplay = true
    }

    func finishPointerInteraction(finalInkPoint: CGPoint?) {
        if interaction.machine.state == .panning {
            interaction.finishViewportGesture()
            panLastPoint = nil
            window?.invalidateCursorRects(for: self)
            return
        }

        if let finalInkPoint {
            _ = interaction.appendInk(at: finalInkPoint, in: bounds.size)
        }
        let completion = interaction.finishInk()
        needsDisplay = true
        switch completion {
        case let .stroke(points, color, width):
            onCompleteStroke(points, color, width)
        case let .erase(ids):
            onErase(ids)
        case nil:
            break
        }
    }

    @discardableResult
    func finishImageInteraction() -> Bool {
        let id: UUID
        let original: CanvasImageTransform
        switch imagePointerMode {
        case .none:
            return false
        case let .moving(imageID, _, initial):
            id = imageID
            original = initial
        case let .resizing(imageID, _, initial):
            id = imageID
            original = initial
        }
        let final = previewImageTransform
        imagePointerMode = .none
        previewImageTransform = nil
        if let final, final != original {
            onTransformImage(id, final)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return true
    }

    func discardImagePreview() {
        imagePointerMode = .none
        previewImageTransform = nil
        needsDisplay = true
    }

    var defaultPasteViewPoint: CGPoint {
        let screenPoint = NSEvent.mouseLocation
        if let window {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = convert(windowPoint, from: nil)
            if bounds.contains(localPoint) { return localPoint }
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    @discardableResult
    func importPasteboard(
        _ pasteboard: NSPasteboard,
        at viewPoint: CGPoint
    ) -> Bool {
        let worldPoint = interaction.viewport.worldPoint(
            for: viewPoint,
            in: bounds.size
        )
        guard worldPoint.isFinite else {
            return false
        }
        var accepted = false
        var offsetIndex = 0
        func importPoint() -> CanvasPoint {
            defer { offsetIndex += 1 }
            let offset = Double(offsetIndex) * 12 / interaction.viewport.scale
            return CanvasPoint(x: worldPoint.x + offset, y: worldPoint.y + offset)
        }

        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]) ?? []
        if !urls.isEmpty {
            for nsURL in urls {
                onImportImageURL(nsURL as URL, importPoint(), false)
            }
            return true
        }

        let receivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]) ?? []
        if !receivers.isEmpty {
            for receiver in receivers {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AtticCanvasPromise", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                } catch {
                    continue
                }
                let point = importPoint()
                receiver.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: filePromiseQueue
                ) { [weak self] url, error in
                    if error != nil {
                        try? FileManager.default.removeItem(at: destination)
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.onImportImageURL(url, point, true)
                    }
                }
                accepted = true
            }
            return accepted
        }

        if let png = pasteboard.data(forType: .png) {
            onImportImageData(png, importPoint())
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            onImportImageData(tiff, importPoint())
            return true
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation {
            onImportImageData(tiff, importPoint())
            return true
        }
        return false
    }

    func hasSupportedImagePayload(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        if pasteboard.availableType(from: Self.directImagePasteboardTypes) != nil {
            return true
        }
        return pasteboard.canReadObject(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        )
    }

}

extension CanvasInkColor {
    var nsColor: NSColor {
        switch self {
        case .ink: .labelColor
        case .blue: .systemBlue
        case .red: .systemRed
        case .green: .systemGreen
        case .orange: .systemOrange
        }
    }
}
#endif
