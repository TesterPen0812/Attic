#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case .resizing: return .crosshair
        case .none: return .crosshair
        }
    }

    func cursor(at viewPoint: CGPoint) -> NSCursor {
        if spacePressed { return .openHand }
        switch imagePointerMode {
        case .moving: return .closedHand
        case .resizing: return .crosshair
        case .none: break
        }
        if let selectedImage,
           CanvasImagePlacement.resizeHandle(
                at: viewPoint,
                image: selectedImage,
                viewport: interaction.viewport,
                viewportSize: bounds.size,
                radius: 9
           ) != nil {
            return .crosshair
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
        return .crosshair
    }

    func beginPan(at point: CGPoint) {
        discardImagePreview()
        _ = interaction.beginViewportGesture()
        panLastPoint = point
        needsDisplay = true
        NSCursor.closedHand.set()
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
        var accepted = false
        var offsetIndex = 0
        func importPoint() -> CanvasPoint {
            defer { offsetIndex += 1 }
            let offset = Double(offsetIndex * 12) / interaction.viewport.scale
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
