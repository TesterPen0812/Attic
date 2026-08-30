import Combine
import Foundation

@MainActor
final class CanvasSession: ObservableObject {
    static let minimumWidth = 1.0
    static let maximumWidth = 16.0

    @Published private(set) var canvases: [CanvasBoard]
    @Published private(set) var selectedCanvasID: UUID
    @Published private(set) var strokes: [CanvasStroke]
    @Published private(set) var images: [CanvasPlacedImage]
    @Published private(set) var selectedImageID: UUID?
    @Published private(set) var boardGeneration: Int64
    @Published private(set) var tool: CanvasTool = .pen
    @Published private(set) var color: CanvasInkColor = .ink
    @Published private(set) var width: Double = 3
    @Published private(set) var viewport = CanvasViewport()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var interactionCancellationEpoch: UInt64 = 0
    @Published private(set) var pendingPlacement: CanvasPendingPlacement?

    private enum HistoryCommand {
        case addStroke(CanvasStroke)
        case eraseStrokes([CanvasStroke])
        case addImage(CanvasPlacedImage)
        case transformImage(before: CanvasPlacedImage, after: CanvasPlacedImage)
        case deleteImage(CanvasPlacedImage)
        case clear(strokes: [CanvasStroke], images: [CanvasPlacedImage])
    }

    private let store: CanvasStore
    private var undoStack: [HistoryCommand] = []
    private var redoStack: [HistoryCommand] = []
    private var revisionObservation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var lastSemanticSnapshot: SemanticSnapshot
    private var isApplyingLocalMutation = false
    private static let maximumHistoryCount = 100

    private struct SemanticSnapshot: Equatable {
        struct BoardSignature: Equatable {
            let id: UUID
            let name: String
            let sortIndex: Int64
            let clearGeneration: Int64
            let mutationVersion: Int64
            let updatedAt: Date
        }

        struct StrokeSignature: Equatable {
            let id: UUID
            let canvasID: UUID
            let boardGeneration: Int64
            let mutationVersion: Int64
            let updatedAt: Date
        }

        struct ImageSignature: Equatable {
            let id: UUID
            let canvasID: UUID
            let transform: CanvasImageTransform
            let boardGeneration: Int64
            let mutationVersion: Int64
            let updatedAt: Date
        }

        let canvases: [BoardSignature]
        let selectedCanvasID: UUID
        let boardGeneration: Int64
        let strokes: [StrokeSignature]
        let images: [ImageSignature]

        init(
            canvases: [CanvasBoard],
            selectedCanvasID: UUID,
            boardGeneration: Int64,
            strokes: [CanvasStroke],
            images: [CanvasPlacedImage]
        ) {
            self.canvases = canvases.map {
                BoardSignature(
                    id: $0.id,
                    name: $0.name,
                    sortIndex: $0.sortIndex,
                    clearGeneration: $0.clearGeneration,
                    mutationVersion: $0.mutationVersion,
                    updatedAt: $0.updatedAt
                )
            }
            self.selectedCanvasID = selectedCanvasID
            self.boardGeneration = boardGeneration
            self.strokes = strokes.map {
                StrokeSignature(
                    id: $0.id,
                    canvasID: $0.canvasID,
                    boardGeneration: $0.boardGeneration,
                    mutationVersion: $0.mutationVersion,
                    updatedAt: $0.updatedAt
                )
            }
            self.images = images.map {
                ImageSignature(
                    id: $0.id,
                    canvasID: $0.canvasID,
                    transform: $0.transform,
                    boardGeneration: $0.boardGeneration,
                    mutationVersion: $0.mutationVersion,
                    updatedAt: $0.updatedAt
                )
            }
        }
    }

    init(store: CanvasStore) {
        self.store = store
        canvases = store.canvases
        selectedCanvasID = store.selectedCanvasID
        strokes = store.strokes
        images = store.images
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage
        lastSemanticSnapshot = SemanticSnapshot(
            canvases: store.canvases,
            selectedCanvasID: store.selectedCanvasID,
            boardGeneration: store.boardGeneration,
            strokes: store.strokes,
            images: store.images
        )

        revisionObservation = store.$revision
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleStoreRevision()
                }
            }
        errorObservation = store.$lastErrorMessage
            .dropFirst()
            .sink { [weak self] message in
                MainActor.assumeIsolated {
                    self?.lastErrorMessage = message
                }
            }
    }

    var selectedCanvas: CanvasBoard {
        canvases.first { $0.id == selectedCanvasID } ?? .defaultBoard
    }

    var selectedImage: CanvasPlacedImage? {
        guard let selectedImageID else { return nil }
        return images.first { $0.id == selectedImageID }
    }

    func selectTool(_ tool: CanvasTool) {
        cancelPendingPlacement()
        self.tool = tool
    }

    func selectColor(_ color: CanvasInkColor) {
        cancelPendingPlacement()
        self.color = color
        tool = .pen
    }

    @discardableResult
    func prepareTextPlacement(
        _ text: String,
        prefersDarkSurface: Bool
    ) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        pendingPlacement = .text(CanvasTextPlacement(
            text: normalized,
            prefersDarkSurface: prefersDarkSurface
        ))
        selectedImageID = nil
        return true
    }

    func prepareShapePlacement(_ shape: CanvasShapeKind) {
        pendingPlacement = .shape(shape)
        selectedImageID = nil
    }

    func cancelPendingPlacement() {
        pendingPlacement = nil
    }

    func setWidth(_ width: Double) {
        guard width.isFinite else { return }
        self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
    }

    @discardableResult
    func selectCanvas(_ id: UUID) -> Bool {
        guard id != selectedCanvasID else { return true }
        cancelPendingPlacement()
        cancelActiveInteraction()
        selectedImageID = nil
        isApplyingLocalMutation = true
        let succeeded = store.selectCanvas(id)
        synchronizeFromStore(clearHistory: true)
        isApplyingLocalMutation = false
        return succeeded
    }

    @discardableResult
    func createCanvas(name: String? = nil) -> CanvasBoard? {
        cancelPendingPlacement()
        cancelActiveInteraction()
        selectedImageID = nil
        isApplyingLocalMutation = true
        let created = store.createCanvas(name: name)
        synchronizeFromStore(clearHistory: true)
        isApplyingLocalMutation = false
        return created
    }

    @discardableResult
    func renameSelectedCanvas(to name: String) -> Bool {
        let succeeded = applyLocalMutation {
            store.renameCanvas(selectedCanvasID, to: name)
        }
        if succeeded {
            clearHistory()
        }
        return succeeded
    }

    @discardableResult
    func deleteSelectedCanvas() -> Bool {
        cancelPendingPlacement()
        cancelActiveInteraction()
        selectedImageID = nil
        let id = selectedCanvasID
        let succeeded = applyLocalMutation {
            store.deleteCanvas(id)
        }
        if succeeded {
            clearHistory()
        }
        return succeeded
    }

    @discardableResult
    func completeStroke(
        points: [CanvasPoint],
        color strokeColor: CanvasInkColor? = nil,
        width strokeWidth: Double? = nil
    ) -> Bool {
        let resolvedColor = strokeColor ?? color
        let requestedWidth = strokeWidth ?? width
        guard requestedWidth.isFinite else {
            lastErrorMessage = "The canvas stroke width is invalid."
            return false
        }
        let resolvedWidth = min(
            max(requestedWidth, Self.minimumWidth),
            Self.maximumWidth
        )
        var persistedStroke: CanvasStroke?
        let succeeded = applyLocalMutation {
            persistedStroke = store.addStroke(
                color: resolvedColor,
                width: resolvedWidth,
                points: points
            )
            return persistedStroke != nil
        }
        guard succeeded, let persistedStroke else { return false }

        recordNewCommand(.addStroke(persistedStroke))
        return true
    }

    @discardableResult
    func insertShape(
        _ shape: CanvasShapeKind,
        from start: CanvasPoint,
        to end: CanvasPoint
    ) -> Bool {
        let points = shape.points(from: start, to: end)
        guard !points.isEmpty else {
            lastErrorMessage = "The shape could not be placed on the canvas."
            return false
        }
        return completeStroke(points: points)
    }

    @discardableResult
    func completePendingShape(
        _ shape: CanvasShapeKind,
        from start: CanvasPoint,
        to end: CanvasPoint
    ) -> Bool {
        guard pendingPlacement == .shape(shape) else { return false }
        let succeeded = insertShape(shape, from: start, to: end)
        if succeeded {
            pendingPlacement = nil
        }
        return succeeded
    }

    @discardableResult
    func completePendingText(
        _ placement: CanvasTextPlacement,
        at point: CanvasPoint
    ) async -> Bool {
        guard pendingPlacement == .text(placement) else { return false }
        pendingPlacement = nil
        return await insertText(
            placement.text,
            at: point,
            prefersDarkSurface: placement.prefersDarkSurface
        )
    }

    @discardableResult
    func insertText(
        _ text: String,
        at point: CanvasPoint,
        prefersDarkSurface: Bool
    ) async -> Bool {
        let targetCanvasID = selectedCanvasID
        let targetGeneration = boardGeneration
        do {
            let prepared = try await CanvasTextRenderer.prepare(
                text: text,
                color: color,
                prefersDarkSurface: prefersDarkSurface
            )
            try Task.checkCancellation()
            guard selectedCanvasID == targetCanvasID,
                  boardGeneration == targetGeneration else {
                return false
            }
            return importPreparedImage(prepared, at: point)
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func erase(strokeIDs: Set<UUID>) -> Bool {
        let captured = strokes.filter { strokeIDs.contains($0.id) }
        guard !captured.isEmpty else { return false }

        let succeeded = applyLocalMutation {
            store.setDeleted(true, strokeIDs: Set(captured.map(\.id)))
        }
        guard succeeded else { return false }

        recordNewCommand(.eraseStrokes(captured))
        return true
    }

    @discardableResult
    func importPreparedImage(
        _ prepared: CanvasPreparedImage,
        at point: CanvasPoint
    ) -> Bool {
        var persistedImage: CanvasPlacedImage?
        let succeeded = applyLocalMutation {
            persistedImage = store.addImage(prepared, center: point)
            return persistedImage != nil
        }
        guard succeeded, let persistedImage else { return false }
        selectedImageID = persistedImage.id
        recordNewCommand(.addImage(persistedImage))
        return true
    }

    @discardableResult
    func importImage(url: URL, at point: CanvasPoint) async -> Bool {
        do {
            let prepared = try await CanvasImageImporter.prepare(url: url)
            try Task.checkCancellation()
            return importPreparedImage(prepared, at: point)
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func importImage(data: Data, at point: CanvasPoint) async -> Bool {
        do {
            let prepared = try await CanvasImageImporter.prepare(data: data)
            try Task.checkCancellation()
            return importPreparedImage(prepared, at: point)
        } catch is CancellationError {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func selectImage(_ id: UUID?) {
        guard let id else {
            selectedImageID = nil
            return
        }
        selectedImageID = images.contains(where: { $0.id == id }) ? id : nil
    }

    @discardableResult
    func transformImage(
        _ id: UUID,
        to transform: CanvasImageTransform
    ) -> Bool {
        guard let before = images.first(where: { $0.id == id }),
              before.transform != transform else {
            return false
        }
        let succeeded = applyLocalMutation {
            store.updateImage(id, transform: transform)
        }
        guard succeeded,
              let after = images.first(where: { $0.id == id }) else {
            return false
        }
        selectedImageID = id
        recordNewCommand(.transformImage(before: before, after: after))
        return true
    }

    @discardableResult
    func deleteImage(_ id: UUID) -> Bool {
        guard let captured = images.first(where: { $0.id == id }) else {
            return false
        }
        let succeeded = applyLocalMutation {
            store.setImageDeleted(true, imageIDs: [id])
        }
        guard succeeded else { return false }
        if selectedImageID == id { selectedImageID = nil }
        recordNewCommand(.deleteImage(captured))
        return true
    }

    @discardableResult
    func deleteSelectedImage() -> Bool {
        guard let selectedImageID else { return false }
        return deleteImage(selectedImageID)
    }

    @discardableResult
    func nudgeSelectedImage(viewDelta: CGSize) -> Bool {
        guard let image = selectedImage,
              viewDelta.width.isFinite,
              viewDelta.height.isFinite else {
            return false
        }
        let transform = CanvasImagePlacement.movedTransform(
            from: image.transform,
            by: CanvasPoint(
                x: Double(viewDelta.width) / viewport.scale,
                y: Double(viewDelta.height) / viewport.scale
            )
        )
        return transformImage(image.id, to: transform)
    }

    @discardableResult
    func bringSelectedImageForward() -> Bool {
        guard let image = selectedImage,
              let highest = images.map(\.zIndex).max(),
              highest < Int64.max else {
            return false
        }
        var transform = image.transform
        transform.zIndex = highest + 1
        return transformImage(image.id, to: transform)
    }

    @discardableResult
    func sendSelectedImageBackward() -> Bool {
        guard let image = selectedImage,
              let lowest = images.map(\.zIndex).min(),
              lowest > Int64.min else {
            return false
        }
        var transform = image.transform
        transform.zIndex = lowest - 1
        return transformImage(image.id, to: transform)
    }

    @discardableResult
    func clear() -> Bool {
        cancelPendingPlacement()
        let capturedStrokes = strokes
        let capturedImages = images
        guard !capturedStrokes.isEmpty || !capturedImages.isEmpty else { return false }

        let succeeded = applyLocalMutation {
            store.clearBoard()
        }
        guard succeeded else { return false }

        selectedImageID = nil
        recordNewCommand(.clear(strokes: capturedStrokes, images: capturedImages))
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.last else { return false }

        let succeeded = applyLocalMutation {
            switch command {
            case let .addStroke(stroke):
                return store.setDeleted(true, strokeIDs: [stroke.id])
            case let .eraseStrokes(strokes):
                return store.restore(strokes)
            case let .addImage(image):
                return store.setImageDeleted(true, imageIDs: [image.id])
            case let .transformImage(before, _):
                return store.updateImage(before.id, transform: before.transform)
            case let .deleteImage(image):
                return store.restoreImages([image])
            case let .clear(strokes, images):
                return store.restore(strokes) && store.restoreImages(images)
            }
        }
        guard succeeded else { return false }

        undoStack.removeLast()
        redoStack.append(command)
        synchronizeSelection(after: command, undoing: true)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.last else { return false }

        let succeeded = applyLocalMutation {
            switch command {
            case let .addStroke(stroke):
                return store.restore([stroke])
            case let .eraseStrokes(strokes):
                return store.setDeleted(true, strokeIDs: Set(strokes.map(\.id)))
            case let .addImage(image):
                return store.restoreImages([image])
            case let .transformImage(_, after):
                return store.updateImage(after.id, transform: after.transform)
            case let .deleteImage(image):
                return store.setImageDeleted(true, imageIDs: [image.id])
            case .clear:
                return store.clearBoard()
            }
        }
        guard succeeded else { return false }

        redoStack.removeLast()
        undoStack.append(command)
        synchronizeSelection(after: command, undoing: false)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    func resetView() {
        viewport.reset()
    }

    func fit(in size: CGSize) {
        var bounds = strokes.compactMap(\.bounds).reduce(nil as CGRect?) {
            partial, candidate in
            partial.map { $0.union(candidate) } ?? candidate
        }
        for image in images {
            bounds = bounds.map { $0.union(image.worldRect) } ?? image.worldRect
        }
        viewport.fit(bounds: bounds, in: size)
    }

    func setViewport(_ viewport: CanvasViewport) {
        self.viewport = viewport
    }

    func pan(byViewTranslation translation: CGSize) {
        viewport.pan(byViewTranslation: translation)
    }

    func zoom(
        by factor: Double,
        anchoredAt anchor: CGPoint,
        in size: CGSize
    ) {
        viewport.zoom(by: factor, anchoredAt: anchor, in: size)
    }

    func cancelActiveInteraction() {
        interactionCancellationEpoch &+= 1
    }

    func refresh() {
        store.refresh()
    }

    private func synchronizeSelection(
        after command: HistoryCommand,
        undoing: Bool
    ) {
        switch command {
        case let .addImage(image):
            selectedImageID = undoing ? nil : image.id
        case let .transformImage(before, after):
            selectedImageID = undoing ? before.id : after.id
        case let .deleteImage(image):
            selectedImageID = undoing ? image.id : nil
        case .clear:
            selectedImageID = nil
        case .addStroke, .eraseStrokes:
            break
        }
    }

    private func recordNewCommand(_ command: HistoryCommand) {
        undoStack.append(command)
        redoStack.removeAll(keepingCapacity: true)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
    }

    private func clearHistory() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        updateHistoryAvailability()
    }

    private func trimHistoryIfNeeded() {
        if undoStack.count > Self.maximumHistoryCount {
            undoStack.removeFirst(undoStack.count - Self.maximumHistoryCount)
        }
        if redoStack.count > Self.maximumHistoryCount {
            redoStack.removeFirst(redoStack.count - Self.maximumHistoryCount)
        }
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func applyLocalMutation(_ mutation: () -> Bool) -> Bool {
        isApplyingLocalMutation = true
        let succeeded = mutation()
        synchronizeFromStore(clearHistory: false)
        isApplyingLocalMutation = false
        return succeeded
    }

    private func handleStoreRevision() {
        let snapshot = SemanticSnapshot(
            canvases: store.canvases,
            selectedCanvasID: store.selectedCanvasID,
            boardGeneration: store.boardGeneration,
            strokes: store.strokes,
            images: store.images
        )
        let semanticChange = snapshot != lastSemanticSnapshot
        synchronizeFromStore(
            clearHistory: semanticChange && !isApplyingLocalMutation
        )
    }

    private func synchronizeFromStore(clearHistory: Bool) {
        canvases = store.canvases
        selectedCanvasID = store.selectedCanvasID
        strokes = store.strokes
        images = store.images
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage
        if let selectedImageID,
           !images.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = nil
        }
        lastSemanticSnapshot = SemanticSnapshot(
            canvases: store.canvases,
            selectedCanvasID: store.selectedCanvasID,
            boardGeneration: store.boardGeneration,
            strokes: store.strokes,
            images: store.images
        )

        if clearHistory {
            cancelPendingPlacement()
            cancelActiveInteraction()
            self.clearHistory()
        }
    }
}
