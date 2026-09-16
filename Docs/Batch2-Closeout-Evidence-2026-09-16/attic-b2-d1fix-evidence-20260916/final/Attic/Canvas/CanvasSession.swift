import Combine
import Foundation

private enum CanvasImagePreparationOutcome: Sendable {
    case prepared(CanvasPreparedImage)
    case failed(CanvasImageImportFailure)
}

private struct CanvasImagePreparationCompletion: Sendable {
    let index: Int
    let outcome: CanvasImagePreparationOutcome
}

enum CanvasHistoryBudget {
    /// Default byte ceiling for the undo and redo stacks.
    ///
    /// The command-count cap alone let a hundred multi-megabyte image commands
    /// stay resident (CANVAS-010/PERF-11): ten 8 MB imports followed by their
    /// deletion kept roughly 80 MB alive until the commands aged out. The
    /// budget is injectable so tests can drive eviction deterministically.
    static let defaultByteBudget = 64 * 1024 * 1024
}

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
    /// Bumped only by board lifecycle and termination cancellation; the native
    /// surface is rebuilt when it changes.
    @Published private(set) var interactionCancellationEpoch: UInt64 = 0
    /// Delivered synchronously to the live native surface for transient
    /// interruptions (zoom commands, panel hide, section changes). Unlike the
    /// cancellation epoch it keeps the surface, its caches, and in-flight
    /// imports alive.
    let interactionInterruptions = PassthroughSubject<Void, Never>()
    @Published private(set) var pendingPlacement: CanvasPendingPlacement?
    @Published private(set) var imageImportProgress: CanvasImageImportBatchProgress?
    @Published private(set) var failedImageIDs: Set<UUID> = []
    @Published private(set) var imageDecodeRetryRequest: CanvasImageDecodeRetryRequest?
    /// Bumped whenever the focused canvas text editor's undo availability can
    /// change. Typing, an editor undo, and an editor redo all reach the session
    /// through the editor's draft callback, so chrome that routes Undo/Redo can
    /// re-evaluate while editing; editor focus and editor-history resets arrive
    /// through `invalidateEditingAvailability()`. It carries no canvas-history
    /// state and never touches either undo stack.
    @Published private(set) var editingAvailabilityToken: UInt64 = 0
    #if os(macOS)
    @Published private(set) var semanticObjects: [CanvasSemanticObject] = []
    @Published private(set) var selectedSemanticObjectID: UUID?
    @Published private(set) var semanticTextEditRequest: UUID?
    private var semanticTextDrafts: [CanvasReplicaKey: CanvasSemanticTextDraft] = [:]
    #endif

    private enum HistoryCommand {
        case addStroke(CanvasStroke)
        case eraseStrokes([CanvasStroke])
        case addImage(CanvasPlacedImage)
        case addImages([CanvasPlacedImage])
        case transformImage(before: CanvasPlacedImage, after: CanvasPlacedImage)
        case replaceImage(before: CanvasPlacedImage, after: CanvasPlacedImage)
        case deleteImage(CanvasPlacedImage)
        case clear(CanvasBoardContents)
        #if os(macOS)
        case changeSemantic(before: CanvasSemanticObject?, after: CanvasSemanticObject?)
        #endif
    }

    /// A history command plus the payload bytes it keeps alive.
    ///
    /// The cost is measured once, when the command is recorded, so enforcing
    /// the budget later never walks a command's contents.
    private struct HistoryEntry {
        let command: HistoryCommand
        let payloadByteCount: Int

        init(command: HistoryCommand) {
            self.command = command
            payloadByteCount = Self.estimatedPayloadByteCount(of: command)
        }

        private static func estimatedPayloadByteCount(
            of command: HistoryCommand
        ) -> Int {
            switch command {
            case let .addStroke(stroke):
                return cost(of: stroke)
            case let .eraseStrokes(strokes):
                return strokes.reduce(0) { $0 + cost(of: $1) }
            case let .addImage(image), let .deleteImage(image):
                return cost(of: image)
            case let .addImages(images):
                return images.reduce(0) { $0 + cost(of: $1) }
            case let .transformImage(before, after):
                // Both sides reference the same immutable payload, so the
                // retained bytes are counted once.
                return before.payloadMetadata == after.payloadMetadata
                    ? cost(of: after)
                    : cost(of: before) + cost(of: after)
            case let .replaceImage(before, after):
                return cost(of: before) + cost(of: after)
            case let .clear(contents):
                var total = contents.strokes.reduce(0) { $0 + cost(of: $1) }
                total += contents.images.reduce(0) { $0 + cost(of: $1) }
                #if os(macOS)
                total += contents.semanticObjects.reduce(0) { $0 + cost(of: $1) }
                #endif
                return total
            #if os(macOS)
            case let .changeSemantic(before, after):
                return (before.map(cost(of:)) ?? 0) + (after.map(cost(of:)) ?? 0)
            #endif
            }
        }

        private static func cost(of image: CanvasPlacedImage) -> Int {
            // The encoded payload dominates; the transform and identity fields
            // are a fixed, negligible remainder.
            image.encodedByteCount
        }

        private static func cost(of stroke: CanvasStroke) -> Int {
            stroke.points.count * MemoryLayout<CanvasPoint>.stride
        }

        #if os(macOS)
        private static func cost(of object: CanvasSemanticObject) -> Int {
            (object.content?.text?.utf8.count ?? 0) + 128
        }
        #endif
    }

    private let store: CanvasStore
    private let maximumConcurrentImageImports: Int
    private let prepareImage: @Sendable (
        CanvasImageImportSource
    ) async throws -> CanvasPreparedImage
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private var revisionObservation: AnyCancellable?
    private var errorObservation: AnyCancellable?
    private var lastSemanticSnapshot: SemanticSnapshot
    private var isApplyingLocalMutation = false
    private var imageImportTasks: [UUID: Task<Void, Never>] = [:]
    private var latestImageImportBatchID: UUID?
    private static let maximumHistoryCount = 100
    private let historyByteBudget: Int
    private var undoStackByteCount = 0
    private var redoStackByteCount = 0
    private var observedContentRevision: UInt64 = 0
    /// Counts the times the session applied a store presentation. The
    /// performance gate uses it to prove that a no-op revision does not
    /// republish the canvas collections.
    private(set) var storeSynchronizationCount: UInt64 = 0
    private static let maximumErrorMessageLength = 140
    private let viewStateDefaults: UserDefaults?
    private var savedViewStates: [UUID: CanvasViewState] = [:]
    private var viewStateSaveTask: Task<Void, Never>?

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
        #if os(macOS)
        var semanticObjects: [CanvasSemanticObject] = []
        #endif

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

    init(
        store: CanvasStore,
        viewStateDefaults: UserDefaults? = nil,
        maximumConcurrentImageImports: Int = 2,
        historyByteBudget: Int = CanvasHistoryBudget.defaultByteBudget,
        prepareImage: @escaping @Sendable (
            CanvasImageImportSource
        ) async throws -> CanvasPreparedImage = { source in
            switch source {
            case let .data(data):
                try await CanvasImageImporter.prepare(data: data)
            case let .file(url):
                try await CanvasImageImporter.prepare(url: url)
            case let .deliveryFailure(message):
                throw CanvasImageImportSourceError.deliveryFailed(message)
            }
        }
    ) {
        self.store = store
        self.historyByteBudget = max(1, historyByteBudget)
        // The application explicitly injects its own preference domain;
        // synthetic stores and tests never inherit the user's preferences.
        self.viewStateDefaults = viewStateDefaults
        if let data = self.viewStateDefaults?.data(forKey: CanvasViewStateArchive.defaultsKey),
           let archive = try? JSONDecoder().decode(CanvasViewStateArchive.self, from: data) {
            savedViewStates = archive.boards.filter { id, _ in
                store.canvases.contains { $0.id == id }
            }
            if store.canvases.contains(where: { $0.id == archive.selectedCanvasID }) {
                _ = store.selectCanvas(archive.selectedCanvasID)
            }
        }
        self.maximumConcurrentImageImports = max(1, maximumConcurrentImageImports)
        self.prepareImage = prepareImage
        canvases = store.canvases
        selectedCanvasID = store.selectedCanvasID
        strokes = store.strokes
        images = store.images
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage.map(Self.compactErrorMessage)
        lastSemanticSnapshot = SemanticSnapshot(
            canvases: store.canvases,
            selectedCanvasID: store.selectedCanvasID,
            boardGeneration: store.boardGeneration,
            strokes: store.strokes,
            images: store.images
        )
        #if os(macOS)
        semanticObjects = store.semanticObjects
        lastSemanticSnapshot.semanticObjects = semanticObjects
        #endif
        restoreViewState()

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
                    self?.lastErrorMessage = message.map(
                        CanvasSession.compactErrorMessage
                    )
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

    var canBringSelectedImageForward: Bool {
        guard let selectedImage else { return false }
        #if os(macOS)
        if semanticObjects.contains(where: { $0.transform.zIndex >= selectedImage.zIndex }) { return true }
        #endif
        return images.contains {
            CanvasImagePlacement.imageIsInFront($0, selectedImage)
        }
    }

    var canSendSelectedImageBackward: Bool {
        guard let selectedImage else { return false }
        #if os(macOS)
        if semanticObjects.contains(where: { $0.transform.zIndex <= selectedImage.zIndex }) { return true }
        #endif
        return images.contains {
            CanvasImagePlacement.imageIsInFront(selectedImage, $0)
        }
    }

    func captureImageImportTarget() -> CanvasImportTarget {
        CanvasImportTarget(
            canvasID: selectedCanvasID,
            boardGeneration: boardGeneration
        )
    }

    func startImageImportBatch(_ batch: CanvasImageImportBatch) {
        imageImportTasks[batch.id]?.cancel()
        imageImportTasks[batch.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.importImageBatch(batch)
            self.imageImportTasks[batch.id] = nil
        }
    }

    func cancelImageImportBatch(_ id: UUID) {
        imageImportTasks.removeValue(forKey: id)?.cancel()
    }

    func cancelAllImageImportBatches() {
        let tasks = imageImportTasks.values
        imageImportTasks.removeAll(keepingCapacity: true)
        tasks.forEach { $0.cancel() }
    }

    func setFailedImageIDs(_ ids: Set<UUID>) {
        let visible = ids.intersection(Set(images.map(\.id)))
        if failedImageIDs != visible { failedImageIDs = visible }
    }

    func retryImageDecode(_ id: UUID) {
        guard images.contains(where: { $0.id == id }) else { return }
        imageDecodeRetryRequest = CanvasImageDecodeRetryRequest(imageIDs: [id])
    }

    /// Retries every image whose decode failed. The renderer only honours a
    /// retry for an image it is currently tracking, so this is safe to offer
    /// from a banner that may outlive a page change.
    @discardableResult
    func retryFailedImageDecodes() -> Bool {
        let ids = Set(images.map(\.id)).intersection(failedImageIDs)
        guard !ids.isEmpty else { return false }
        imageDecodeRetryRequest = CanvasImageDecodeRetryRequest(imageIDs: ids)
        return true
    }

    /// Clears the canvas failure banner. Recovery is also automatic: the next
    /// successful store action publishes its own (usually absent) warning.
    func dismissErrorMessage() {
        lastErrorMessage = nil
        store.lastErrorMessage = nil
    }

    /// Reports a session-level failure in the compact form the panel banner
    /// can show without overlapping the canvas toolbar (CANVAS-008).
    func reportError(_ message: String) {
        lastErrorMessage = Self.compactErrorMessage(message)
    }

    /// Estimated bytes retained by the undo and redo stacks (CANVAS-010).
    var historyPayloadByteCount: Int { undoStackByteCount + redoStackByteCount }

    var undoCommandCount: Int { undoStack.count }

    var redoCommandCount: Int { redoStack.count }

    func dismissImageImportProgress() {
        guard let progress = imageImportProgress,
              progress.completedCount == progress.items.count else { return }
        latestImageImportBatchID = nil
        imageImportProgress = nil
    }

    @discardableResult
    func replaceImage(_ id: UUID, from url: URL) async -> Bool {
        let target = captureImageImportTarget()
        guard let before = images.first(where: { $0.id == id }) else { return false }
        do {
            let prepared = try await prepareImage(.file(url))
            try Task.checkCancellation()
            guard captureImageImportTarget() == target,
                  let current = images.first(where: { $0.id == id }),
                  current.mutationVersion == before.mutationVersion else { return false }
            let replacement = CanvasPlacedImage(
                id: id, canvasID: target.canvasID,
                encodedData: prepared.encodedData, contentType: prepared.contentType,
                pixelWidth: prepared.pixelWidth, pixelHeight: prepared.pixelHeight,
                transform: before.transform, boardGeneration: target.boardGeneration,
                mutationVersion: before.mutationVersion, createdAt: before.createdAt,
                payloadMetadata: prepared.payloadMetadata
            )
            guard applyLocalMutation({ store.restoreImages([replacement]) }),
                  let after = images.first(where: { $0.id == id }) else { return false }
            recordNewCommand(.replaceImage(before: before, after: after))
            return true
        } catch is CancellationError {
            return false
        } catch {
            reportError(error.localizedDescription)
            return false
        }
    }

    func selectTool(_ tool: CanvasTool) {
        cancelPendingPlacement()
        self.tool = tool
        flushViewState()
    }

    func selectColor(_ color: CanvasInkColor) {
        cancelPendingPlacement()
        self.color = color
        tool = .pen
        flushViewState()
    }

    @discardableResult
    func prepareTextPlacement(
        _ text: String,
        prefersDarkSurface: Bool
    ) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        #if os(macOS)
        guard normalized.utf8.count <= 65_536 else {
            lastErrorMessage = "Keep canvas text below 64 KB. Use a note for longer writing."
            return false
        }
        selectedSemanticObjectID = nil
        #endif
        pendingPlacement = .text(CanvasTextPlacement(
            text: normalized,
            prefersDarkSurface: prefersDarkSurface
        ))
        selectedImageID = nil
        return true
    }

    func prepareShapePlacement(_ shape: CanvasShapeKind) {
        #if os(macOS)
        selectedSemanticObjectID = nil
        #endif
        pendingPlacement = .shape(shape)
        selectedImageID = nil
    }

    func cancelPendingPlacement() {
        pendingPlacement = nil
    }

    func setWidth(_ width: Double) {
        guard width.isFinite else { return }
        self.width = min(max(width, Self.minimumWidth), Self.maximumWidth)
        scheduleViewStateSave()
    }

    @discardableResult
    func selectCanvas(_ id: UUID) -> Bool {
        guard id != selectedCanvasID else { return true }
        let previousCanvasID = selectedCanvasID
        isApplyingLocalMutation = true
        let succeeded = store.selectCanvas(id)
        // A refused selection changed nothing: keep history, placement,
        // imports, and the native surface (CVD-02). Clearing the history
        // resets placement and interaction.
        let boardChanged = succeeded || store.selectedCanvasID != previousCanvasID
        if boardChanged { selectedImageID = nil }
        synchronizeFromStore(clearHistory: boardChanged)
        isApplyingLocalMutation = false
        return succeeded
    }

    @discardableResult
    func createCanvas(name: String? = nil) -> CanvasBoard? {
        #if os(macOS)
        // An empty virtual board disappears when the first stored board is
        // created. Do not strand an interrupted insertion under its old ID.
        if selectedCanvas.createdAt == .distantPast,
           semanticTextDrafts.values.contains(where: {
               $0.isInsertion && $0.baseline.canvasID == selectedCanvasID && !$0.text.isEmpty
           }) {
            lastErrorMessage = "Your unsaved canvas text is retained. Reopen the Text tool to save it, or press Escape in the editor to discard it, before creating another canvas."
            return nil
        }
        #endif
        let previousCanvasID = selectedCanvasID
        isApplyingLocalMutation = true
        let created = store.createCanvas(name: name)
        // An invalid name or failed save must not cost undo history (CVD-02).
        let boardChanged = created != nil || store.selectedCanvasID != previousCanvasID
        if boardChanged { selectedImageID = nil }
        synchronizeFromStore(clearHistory: boardChanged)
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
        let id = selectedCanvasID
        let succeeded = applyLocalMutation {
            store.deleteCanvas(id)
        }
        // A refused delete (for example, the last canvas) changed nothing.
        if succeeded || selectedCanvasID != id {
            cancelPendingPlacement()
            cancelActiveInteraction()
            selectedImageID = nil
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
        #if os(macOS)
        guard start.isFinite, end.isFinite, start != end else { return false }
        let objectWidth = max(abs(end.x - start.x), 1)
        let objectHeight = max(abs(end.y - start.y), 1)
        let content = CanvasSemanticContent(
            shape: shape, color: color, strokeWidth: width,
            start: CanvasPoint(x: end.x >= start.x ? 0 : 1, y: end.y >= start.y ? 0 : 1),
            end: CanvasPoint(x: end.x >= start.x ? 1 : 0, y: end.y >= start.y ? 1 : 0)
        )
        return insertSemanticObject(content: content, transform: CanvasImageTransform(
            center: CanvasPoint(x: start.x / 2 + end.x / 2, y: start.y / 2 + end.y / 2),
            width: objectWidth, height: objectHeight, zIndex: nextObjectZIndex
        ))
        #else
        let points = shape.points(from: start, to: end)
        guard !points.isEmpty else {
            lastErrorMessage = "The shape could not be placed on the canvas."
            return false
        }
        return completeStroke(points: points)
        #endif
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
        #if os(macOS)
        // Semantic placement does not suspend for image decoding. Retain the
        // entered text and placement mode if persistence fails.
        let succeeded = await insertText(placement.text, at: point, prefersDarkSurface: placement.prefersDarkSurface)
        if succeeded { pendingPlacement = nil }
        return succeeded
        #else
        pendingPlacement = nil
        return await insertText(
            placement.text,
            at: point,
            prefersDarkSurface: placement.prefersDarkSurface
        )
        #endif
    }

    @discardableResult
    func insertText(
        _ text: String,
        at point: CanvasPoint,
        prefersDarkSurface: Bool
    ) async -> Bool {
        #if os(macOS)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 65_536, point.isFinite else { return false }
        let content = CanvasSemanticContent(text: normalized, color: color, strokeWidth: width)
        let size = CanvasSemanticRenderer.defaultTextSize(content)
        return insertSemanticObject(content: content, transform: CanvasImageTransform(
            center: point, width: size.width, height: size.height, zIndex: nextObjectZIndex
        ))
        #else
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
            reportError(error.localizedDescription)
            return false
        }
        #endif
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
        #if os(macOS)
        selectedSemanticObjectID = nil
        #endif
        selectedImageID = persistedImage.id
        recordNewCommand(.addImage(persistedImage))
        return true
    }

    @discardableResult
    func importImage(url: URL, at point: CanvasPoint) async -> Bool {
        let request = CanvasImageImportRequest(source: .file(url), center: point)
        let result = await importImageBatch(CanvasImageImportBatch(
            target: captureImageImportTarget(),
            items: [request]
        ))
        return result.items.first?.outcome.importedImageID != nil
    }

    @discardableResult
    func importImage(data: Data, at point: CanvasPoint) async -> Bool {
        let request = CanvasImageImportRequest(source: .data(data), center: point)
        let result = await importImageBatch(CanvasImageImportBatch(
            target: captureImageImportTarget(),
            items: [request]
        ))
        return result.items.first?.outcome.importedImageID != nil
    }

    func importImageBatch(
        _ batch: CanvasImageImportBatch
    ) async -> CanvasImageImportBatchResult {
        var progress = CanvasImageImportBatchProgress(
            batchID: batch.id,
            target: batch.target,
            items: batch.items.map {
                CanvasImageImportProgressItem(requestID: $0.id, state: .pending)
            }
        )
        latestImageImportBatchID = batch.id
        publishImageImportProgress(progress)
        var outcomes = Array<CanvasImageImportOutcome?>(
            repeating: nil,
            count: batch.items.count
        )
        var prepared = Array<CanvasPreparedImage?>(
            repeating: nil,
            count: batch.items.count
        )
        defer {
            CanvasTemporaryImportCleanup.removeOwnedDirectories(
                batch.items.compactMap(\.cleanupURL)
            )
        }

        var preparationIndices: [Int] = []
        preparationIndices.reserveCapacity(batch.items.count)
        for (index, item) in batch.items.enumerated() {
            switch item.source {
            case let .deliveryFailure(message):
                let outcome = CanvasImageImportOutcome.failed(.deliveryFailed(message))
                outcomes[index] = outcome
                progress.items[index].state = .finished(outcome)
            case .data, .file:
                preparationIndices.append(index)
            }
        }
        publishImageImportProgress(progress)

        await withTaskGroup(of: CanvasImagePreparationCompletion.self) { group in
            var nextPreparation = 0
            var activeCount = 0

            func addPreparation(at preparationOffset: Int) {
                let itemIndex = preparationIndices[preparationOffset]
                let source = batch.items[itemIndex].source
                let prepareImage = self.prepareImage
                progress.items[itemIndex].state = .preparing
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let image = try await prepareImage(source)
                        try Task.checkCancellation()
                        return CanvasImagePreparationCompletion(
                            index: itemIndex,
                            outcome: .prepared(image)
                        )
                    } catch is CancellationError {
                        return CanvasImagePreparationCompletion(
                            index: itemIndex,
                            outcome: .failed(.cancelled)
                        )
                    } catch {
                        return CanvasImagePreparationCompletion(
                            index: itemIndex,
                            outcome: .failed(.preparationFailed(error.localizedDescription))
                        )
                    }
                }
            }

            while activeCount < maximumConcurrentImageImports,
                  nextPreparation < preparationIndices.count {
                addPreparation(at: nextPreparation)
                nextPreparation += 1
                activeCount += 1
            }
            publishImageImportProgress(progress)

            while let completion = await group.next() {
                activeCount -= 1
                switch completion.outcome {
                case let .prepared(image):
                    prepared[completion.index] = image
                case let .failed(failure):
                    let outcome = CanvasImageImportOutcome.failed(failure)
                    outcomes[completion.index] = outcome
                    progress.items[completion.index].state = .finished(outcome)
                }

                if Task.isCancelled {
                    group.cancelAll()
                } else if nextPreparation < preparationIndices.count {
                    addPreparation(at: nextPreparation)
                    nextPreparation += 1
                    activeCount += 1
                }
                publishImageImportProgress(progress)
            }
        }

        if Task.isCancelled {
            for index in batch.items.indices where outcomes[index] == nil {
                let outcome = CanvasImageImportOutcome.failed(.cancelled)
                outcomes[index] = outcome
                prepared[index] = nil
                progress.items[index].state = .finished(outcome)
            }
            publishImageImportProgress(progress)
            return makeImageImportResult(batch: batch, outcomes: outcomes)
        }

        let preparedImports = batch.items.indices.compactMap { index -> CanvasPreparedImageImport? in
            guard let image = prepared[index] else { return nil }
            return CanvasPreparedImageImport(
                requestID: batch.items[index].id,
                prepared: image,
                center: batch.items[index].center
            )
        }
        if !preparedImports.isEmpty {
            isApplyingLocalMutation = true
            let storeOutcome = store.importImages(preparedImports, target: batch.target)
            synchronizeFromStore(clearHistory: false)
            isApplyingLocalMutation = false

            switch storeOutcome {
            case let .imported(importedImages):
                let importedByID = Dictionary(
                    uniqueKeysWithValues: importedImages.map { ($0.id, $0) }
                )
                for index in batch.items.indices where prepared[index] != nil {
                    let requestID = batch.items[index].id
                    let outcome = CanvasImageImportOutcome.imported(imageID: requestID)
                    outcomes[index] = outcome
                    progress.items[index].state = .finished(outcome)
                }
                if selectedCanvasID == batch.target.canvasID,
                   boardGeneration == batch.target.boardGeneration {
                    let currentSnapshots = preparedImports.compactMap { item in
                        images.first(where: { image in
                            image.id == item.requestID
                        }) ?? importedByID[item.requestID]
                    }
                    if !currentSnapshots.isEmpty {
                        #if os(macOS)
                        selectedSemanticObjectID = nil
                        #endif
                        selectedImageID = currentSnapshots.last?.id
                        recordNewCommand(.addImages(currentSnapshots))
                    }
                }
            case let .rejected(failure):
                for index in batch.items.indices where prepared[index] != nil {
                    let outcome = CanvasImageImportOutcome.failed(failure)
                    outcomes[index] = outcome
                    progress.items[index].state = .finished(outcome)
                }
            }
        }

        for index in batch.items.indices where outcomes[index] == nil {
            let outcome = CanvasImageImportOutcome.failed(.preparationFailed(
                "The image did not produce an import result."
            ))
            outcomes[index] = outcome
            progress.items[index].state = .finished(outcome)
        }
        publishImageImportProgress(progress)
        if let firstFailure = outcomes.compactMap({ outcome -> CanvasImageImportFailure? in
            guard case let .failed(failure)? = outcome else { return nil }
            return failure
        }).first {
            reportError(firstFailure.message)
        }
        return makeImageImportResult(batch: batch, outcomes: outcomes)
    }

    func selectImage(_ id: UUID?) {
        #if os(macOS)
        if id != nil { selectedSemanticObjectID = nil }
        #endif
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
    func resizeSelectedImage(by factor: Double) -> Bool {
        guard let image = selectedImage,
              factor.isFinite,
              factor > 0 else {
            return false
        }
        let minimumScale = max(
            CanvasImagePlacement.minimumDimension / image.width,
            CanvasImagePlacement.minimumDimension / image.height
        )
        let appliedFactor = max(factor, minimumScale)
        let width = image.width * appliedFactor
        let height = image.height * appliedFactor
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else {
            return false
        }
        var transform = image.transform
        transform.width = width
        transform.height = height
        return transformImage(image.id, to: transform)
    }

    @discardableResult
    func bringSelectedImageForward() -> Bool {
        guard canBringSelectedImageForward,
              let image = selectedImage,
              let highest = objectLayerIndices.max(),
              highest < Int64.max else {
            return false
        }
        var transform = image.transform
        transform.zIndex = highest + 1
        return transformImage(image.id, to: transform)
    }

    @discardableResult
    func sendSelectedImageBackward() -> Bool {
        guard canSendSelectedImageBackward,
              let image = selectedImage,
              let lowest = objectLayerIndices.min(),
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
        var contents = CanvasBoardContents(strokes: strokes, images: images)
        #if os(macOS)
        contents.semanticObjects = semanticObjects
        #endif
        guard !contents.isEmpty else { return false }

        let succeeded = applyLocalMutation {
            store.clearBoard()
        }
        guard succeeded else { return false }

        selectedImageID = nil
        recordNewCommand(.clear(contents))
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = undoStack.last else { return false }
        let command = entry.command

        let succeeded = applyLocalMutation {
            switch command {
            case let .addStroke(stroke):
                return store.setDeleted(true, strokeIDs: [stroke.id])
            case let .eraseStrokes(strokes):
                return store.restore(strokes)
            case let .addImage(image):
                return store.setImageDeleted(true, imageIDs: [image.id])
            case let .addImages(images):
                return store.setImageDeleted(
                    true,
                    imageIDs: Set(images.map(\.id))
                )
            case let .transformImage(before, _):
                return store.updateImage(before.id, transform: before.transform)
            case let .replaceImage(before, _):
                return store.restoreImages([before])
            case let .deleteImage(image):
                return store.restoreImages([image])
            case let .clear(contents):
                return store.restoreBoardContents(contents).succeeded
            #if os(macOS)
            case let .changeSemantic(before, after):
                if let before { return restoreSemanticObject(before) }
                return after.map { store.deleteSemanticObject($0.id) } ?? false
            #endif
            }
        }
        guard succeeded else { return false }

        undoStack.removeLast()
        undoStackByteCount -= entry.payloadByteCount
        redoStack.append(entry)
        redoStackByteCount += entry.payloadByteCount
        synchronizeSelection(after: command, undoing: true)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let entry = redoStack.last else { return false }
        let command = entry.command

        let succeeded = applyLocalMutation {
            switch command {
            case let .addStroke(stroke):
                return store.restore([stroke])
            case let .eraseStrokes(strokes):
                return store.setDeleted(true, strokeIDs: Set(strokes.map(\.id)))
            case let .addImage(image):
                return store.restoreImages([image])
            case let .addImages(images):
                return store.restoreImages(images)
            case let .transformImage(_, after):
                return store.updateImage(after.id, transform: after.transform)
            case let .replaceImage(_, after):
                return store.restoreImages([after])
            case let .deleteImage(image):
                return store.setImageDeleted(true, imageIDs: [image.id])
            case .clear:
                return store.clearBoard()
            #if os(macOS)
            case let .changeSemantic(before, after):
                if let after { return restoreSemanticObject(after) }
                return before.map { store.deleteSemanticObject($0.id) } ?? false
            #endif
            }
        }
        guard succeeded else { return false }

        redoStack.removeLast()
        redoStackByteCount -= entry.payloadByteCount
        undoStack.append(entry)
        undoStackByteCount += entry.payloadByteCount
        synchronizeSelection(after: command, undoing: false)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    private var objectLayerIndices: [Int64] {
        #if os(macOS)
        images.map(\.zIndex) + semanticObjects.map { $0.transform.zIndex }
        #else
        images.map(\.zIndex)
        #endif
    }

    #if os(macOS)
    func selectTextTool() {
        if case .text? = pendingPlacement {
            cancelPendingPlacement()
        } else {
            pendingPlacement = .text(CanvasTextPlacement(text: "", prefersDarkSurface: false))
            selectedImageID = nil
            selectedSemanticObjectID = nil
        }
    }

    func makeTextInsertion(at origin: CanvasPoint, width: Double) -> CanvasSemanticTextDraft? {
        guard case .text? = pendingPlacement, origin.isFinite, width.isFinite, width >= 48 else { return nil }
        // Reopening the tool recovers an interrupted unsaved insertion on this
        // page instead of abandoning it when the native view was recreated.
        if let retained = semanticTextDrafts.values.first(where: {
            $0.isInsertion && $0.baseline.canvasID == selectedCanvasID
        }) { return retained }
        return CanvasSemanticTextDraft(baseline: CanvasSemanticObject(
            textInsertionAt: origin, canvasID: selectedCanvasID, generation: boardGeneration,
            content: CanvasSemanticContent(text: "", color: color, strokeWidth: self.width), width: width
        ), text: "", isInsertion: true)
    }

    var selectedSemanticObject: CanvasSemanticObject? {
        semanticObjects.first { $0.id == selectedSemanticObjectID }
    }

    func preserveSemanticTextDraft(_ key: CanvasReplicaKey, draft: CanvasSemanticTextDraft?) {
        semanticTextDrafts[key] = draft
        // Republish unconditionally. An editor undo back to the baseline stores
        // no draft, yet it still changes what that editor can undo and redo.
        invalidateEditingAvailability()
    }

    /// Republishes Undo/Redo availability for a change that neither drafts nor
    /// canvas history record, such as a canvas text editor taking focus.
    func invalidateEditingAvailability() {
        editingAvailabilityToken &+= 1
    }
    func semanticTextDraft(_ key: CanvasReplicaKey) -> CanvasSemanticTextDraft? { semanticTextDrafts[key] }
    func semanticTextDraft(_ id: UUID) -> String? { semanticTextDrafts[CanvasReplicaKey(canvasID: selectedCanvasID, id: id)]?.text }

    func reportSemanticTextConflict() {
        lastErrorMessage = "This canvas text changed while you were editing. Your draft is retained. Copy it to keep it, or press Escape to discard the draft and show the saved object."
    }

    @discardableResult
    func commitSemanticText(_ draft: CanvasSemanticTextDraft) -> Bool {
        if draft.isInsertion {
            guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            preserveSemanticTextDraft(draft.key, draft: draft)
            guard draft.baseline.canvasID == selectedCanvasID,
                  draft.baseline.boardGeneration == boardGeneration,
                  var content = draft.baseline.content else {
                reportSemanticTextConflict()
                return false
            }
            content.text = draft.text
            let size = CanvasSemanticRenderer.textSize(content, width: draft.baseline.transform.width)
            let origin = draft.baseline.worldRect.origin
            let succeeded = insertSemanticObject(content: content, transform: CanvasImageTransform(
                center: CanvasPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2),
                width: size.width, height: size.height, zIndex: nextObjectZIndex
            ))
            if succeeded { preserveSemanticTextDraft(draft.key, draft: nil) }
            return succeeded
        }
        // No typing means there is no edit to save, even if an external refresh
        // changed or replaced the object before the view could reconfigure.
        if draft.text == draft.baseline.content?.text { return true }
        guard draft.baseline.canvasID == selectedCanvasID,
              let current = semanticObjects.first(where: { $0.id == draft.baseline.id }),
              var content = current.content, content.text != nil else {
            preserveSemanticTextDraft(draft.key, draft: draft)
            reportSemanticTextConflict()
            return false
        }
        if content.text == draft.text { return true }
        guard current.payload == draft.baseline.payload,
              current.payloadVersion == draft.baseline.payloadVersion,
              current.kind == draft.baseline.kind,
              current.boardGeneration == draft.baseline.boardGeneration else {
            preserveSemanticTextDraft(draft.key, draft: draft)
            reportSemanticTextConflict()
            return false
        }
        content.text = draft.text
        return editSemanticObject(current.id, content: content)
    }

    func requestSelectedSemanticTextEditing() {
        guard selectedSemanticObject?.content?.text != nil else { return }
        semanticTextEditRequest = UUID()
    }

    private var nextObjectZIndex: Int64 {
        let highest = objectLayerIndices.max() ?? -1
        return highest < Int64.max ? highest + 1 : highest
    }

    func selectSemanticObject(_ id: UUID?) {
        selectedSemanticObjectID = semanticObjects.contains { $0.id == id } ? id : nil
        if id != nil { selectedImageID = nil }
    }

    @discardableResult
    private func insertSemanticObject(content: CanvasSemanticContent, transform: CanvasImageTransform) -> Bool {
        guard (objectLayerIndices.max() ?? -1) < Int64.max else {
            lastErrorMessage = CanvasReplicaMutationError.sortIndexExhausted.localizedDescription
            return false
        }
        var added: CanvasSemanticObject?
        guard applyLocalMutation({
            added = store.addSemanticObject(content: content, transform: transform)
            return added != nil
        }), let added else { return false }
        selectedImageID = nil
        selectedSemanticObjectID = added.id
        selectTool(.select)
        recordNewCommand(.changeSemantic(before: nil, after: added))
        return true
    }

    private func restoreSemanticObject(_ snapshot: CanvasSemanticObject) -> Bool {
        var contents = CanvasBoardContents(strokes: [], images: [])
        contents.semanticObjects = [snapshot]
        return store.restoreBoardContents(contents).succeeded
    }

    @discardableResult
    func transformSemanticObject(_ id: UUID, to proposed: CanvasImageTransform) -> Bool {
        guard let before = semanticObjects.first(where: { $0.id == id }) else { return false }
        var transform = proposed
        // A resize must never persist a box that clips its text: refit the
        // height to the new width, keeping the top edge where the text starts.
        if let content = before.content, content.text != nil, transform.width.isFinite, transform.height.isFinite,
           transform.width != before.transform.width || transform.height != before.transform.height {
            let proposedHeight = transform.height
            transform.height = max(proposedHeight, CanvasSemanticRenderer.textSize(content, width: transform.width).height)
            transform.center.y += (transform.height - proposedHeight) / 2
        }
        guard transform.isValid, before.transform != transform else { return false }
        var changed = before
        changed.transform = transform
        guard applyLocalMutation({ store.updateSemanticObject(changed) }),
              let after = semanticObjects.first(where: { $0.id == id }) else { return false }
        selectedSemanticObjectID = id
        recordNewCommand(.changeSemantic(before: before, after: after))
        return true
    }

    @discardableResult
    func editSemanticObject(_ id: UUID, content: CanvasSemanticContent) -> Bool {
        guard content.isValid else {
            lastErrorMessage = "Keep canvas text nonempty and below 64 KB, with a valid font size and ink width."
            return false
        }
        guard let before = semanticObjects.first(where: { $0.id == id }),
              before.content != nil,
              before.content != content else { return false }
        var changed = before
        do { changed.payload = try JSONEncoder().encode(content) }
        catch { reportError(error.localizedDescription); return false }
        changed.kind = content.text == nil ? "shape" : "text"
        changed.content = content
        if content.text != nil {
            let size = CanvasSemanticRenderer.textSize(content, width: changed.transform.width)
            let oldHeight = changed.transform.height
            changed.transform.height = max(changed.transform.height, size.height)
            changed.transform.center.y += (changed.transform.height - oldHeight) / 2
        }
        guard applyLocalMutation({ store.updateSemanticObject(changed) }),
              let after = semanticObjects.first(where: { $0.id == id }) else { return false }
        recordNewCommand(.changeSemantic(before: before, after: after))
        return true
    }

    @discardableResult
    func deleteSemanticObject(_ id: UUID) -> Bool {
        guard let before = semanticObjects.first(where: { $0.id == id }),
              applyLocalMutation({ store.deleteSemanticObject(id) }) else { return false }
        recordNewCommand(.changeSemantic(before: before, after: nil))
        return true
    }

    @discardableResult
    func nudgeSelectedSemanticObject(_ delta: CGSize) -> Bool {
        guard let object = selectedSemanticObject else { return false }
        return transformSemanticObject(object.id, to: CanvasImagePlacement.movedTransform(
            from: object.transform,
            by: CanvasPoint(x: Double(delta.width) / viewport.scale, y: Double(delta.height) / viewport.scale)
        ))
    }

    @discardableResult
    func resizeSelectedSemanticObject(by factor: Double) -> Bool {
        guard let object = selectedSemanticObject, factor.isFinite, factor > 0 else { return false }
        var transform = object.transform
        transform.width = max(CanvasImagePlacement.minimumDimension, transform.width * factor)
        transform.height = max(CanvasImagePlacement.minimumDimension, transform.height * factor)
        return transformSemanticObject(object.id, to: transform)
    }

    var canBringSelectedSemanticForward: Bool {
        guard let object = selectedSemanticObject else { return false }
        return placedObjects.contains { CanvasPlacedRenderObject.comesBefore(.semantic(object), $0) }
    }

    var canSendSelectedSemanticBackward: Bool {
        guard let object = selectedSemanticObject else { return false }
        return placedObjects.contains { CanvasPlacedRenderObject.comesBefore($0, .semantic(object)) }
    }

    private var placedObjects: [CanvasPlacedRenderObject] {
        images.map(CanvasPlacedRenderObject.image) + semanticObjects.map(CanvasPlacedRenderObject.semantic)
    }

    @discardableResult
    func moveSelectedSemanticLayer(forward: Bool) -> Bool {
        guard let object = selectedSemanticObject,
              forward ? canBringSelectedSemanticForward : canSendSelectedSemanticBackward else { return false }
        var transform = object.transform
        if forward {
            guard let highest = objectLayerIndices.max(), highest < Int64.max else { return false }
            transform.zIndex = highest + 1
        } else {
            guard let lowest = objectLayerIndices.min(), lowest > Int64.min else { return false }
            transform.zIndex = lowest - 1
        }
        return transformSemanticObject(object.id, to: transform)
    }
    #endif

    func resetView() {
        viewport.reset()
        flushViewState()
    }

    func fit(in size: CGSize, excluding controls: [CGRect] = []) {
        var bounds = strokes.compactMap(\.bounds).reduce(nil as CGRect?) {
            partial, candidate in
            partial.map { $0.union(candidate) } ?? candidate
        }
        for image in images {
            bounds = bounds.map { $0.union(image.worldRect) } ?? image.worldRect
        }
        #if os(macOS)
        for object in semanticObjects {
            bounds = bounds.map { $0.union(object.worldRect) } ?? object.worldRect
        }
        #endif
        let visible = CanvasViewport.unobscuredRect(in: size, excluding: controls)
        viewport.fit(bounds: bounds, in: visible.size)
        viewport.pan(byViewTranslation: CGSize(width: visible.midX - size.width / 2,
                                               height: visible.midY - size.height / 2))
        flushViewState()
    }

    func setViewport(_ viewport: CanvasViewport) {
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        scheduleViewStateSave()
    }

    func pan(byViewTranslation translation: CGSize) {
        viewport.pan(byViewTranslation: translation)
        scheduleViewStateSave()
    }

    func zoom(
        by factor: Double,
        anchoredAt anchor: CGPoint,
        in size: CGSize
    ) {
        viewport.zoom(by: factor, anchoredAt: anchor, in: size)
        scheduleViewStateSave()
    }

    /// Lifecycle cancellation for a board switch, create, or delete, an
    /// external history reset, and stop/termination. Cancels session-owned
    /// image imports and rebuilds the native surface.
    func cancelActiveInteraction() {
        flushViewState()
        cancelAllImageImportBatches()
        interactionCancellationEpoch &+= 1
    }

    /// Transient interruption: the live surface commits or suspends text
    /// editing and discards unfinished input, but is not rebuilt and does not
    /// cancel image imports.
    func interruptActiveInteraction() {
        flushViewState()
        interactionInterruptions.send()
    }

    func flushViewState() {
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        savedViewStates[selectedCanvasID] = CanvasViewState(
            center: viewport.center, scale: viewport.scale, tool: tool,
            color: color, width: width
        )
        savedViewStates = savedViewStates.filter { id, _ in
            canvases.contains { $0.id == id }
        }
        guard let viewStateDefaults,
              let data = try? JSONEncoder().encode(CanvasViewStateArchive(
                selectedCanvasID: selectedCanvasID, boards: savedViewStates
              )) else { return }
        if viewStateDefaults.data(forKey: CanvasViewStateArchive.defaultsKey) != data {
            viewStateDefaults.set(data, forKey: CanvasViewStateArchive.defaultsKey)
        }
    }

    private func scheduleViewStateSave() {
        viewStateSaveTask?.cancel()
        viewStateSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            self?.flushViewState()
        }
    }

    private func restoreViewState() {
        let state = savedViewStates[selectedCanvasID]
        viewport = state?.viewport ?? CanvasViewport()
        tool = state?.tool ?? .pen
        color = state?.color ?? .ink
        let restoredWidth = state?.width ?? 3
        width = restoredWidth.isFinite
            ? min(max(restoredWidth, Self.minimumWidth), Self.maximumWidth) : 3
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
        case let .addImages(images):
            selectedImageID = undoing ? nil : images.last?.id
        case let .transformImage(before, after), let .replaceImage(before, after):
            selectedImageID = undoing ? before.id : after.id
        case let .deleteImage(image):
            selectedImageID = undoing ? image.id : nil
        case .clear:
            selectedImageID = nil
            #if os(macOS)
            selectedSemanticObjectID = nil
            #endif
        #if os(macOS)
        case let .changeSemantic(before, after):
            selectedSemanticObjectID = (undoing ? before : after)?.id
            selectedImageID = nil
        #endif
        case .addStroke, .eraseStrokes:
            break
        }
        #if os(macOS)
        if selectedImageID != nil { selectedSemanticObjectID = nil }
        #endif
    }

    private func makeImageImportResult(
        batch: CanvasImageImportBatch,
        outcomes: [CanvasImageImportOutcome?]
    ) -> CanvasImageImportBatchResult {
        CanvasImageImportBatchResult(
            batchID: batch.id,
            target: batch.target,
            items: zip(batch.items, outcomes).map { item, outcome in
                CanvasImageImportItemResult(
                    requestID: item.id,
                    outcome: outcome ?? .failed(.preparationFailed(
                        "The image did not produce an import result."
                    ))
                )
            }
        )
    }

    private func publishImageImportProgress(_ progress: CanvasImageImportBatchProgress) {
        guard latestImageImportBatchID == progress.batchID else { return }
        imageImportProgress = progress
    }

    private func recordNewCommand(_ command: HistoryCommand) {
        let entry = HistoryEntry(command: command)
        undoStack.append(entry)
        undoStackByteCount += entry.payloadByteCount
        redoStack.removeAll(keepingCapacity: true)
        redoStackByteCount = 0
        trimHistoryIfNeeded()
        updateHistoryAvailability()
    }

    private func clearHistory() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        undoStackByteCount = 0
        redoStackByteCount = 0
        updateHistoryAvailability()
    }

    /// Enforces both history ceilings: the command count and the estimated
    /// payload bytes those commands keep alive. Eviction is always
    /// oldest-first, so the most recent work stays undoable.
    private func trimHistoryIfNeeded() {
        Self.trim(
            stack: &undoStack,
            byteCount: &undoStackByteCount,
            byteBudget: historyByteBudget
        )
        Self.trim(
            stack: &redoStack,
            byteCount: &redoStackByteCount,
            byteBudget: historyByteBudget
        )
    }

    private static func trim(
        stack: inout [HistoryEntry],
        byteCount: inout Int,
        byteBudget: Int
    ) {
        if stack.count > maximumHistoryCount {
            let excess = stack.count - maximumHistoryCount
            for entry in stack.prefix(excess) { byteCount -= entry.payloadByteCount }
            stack.removeFirst(excess)
        }
        // Always keep the newest command, even when it alone exceeds the
        // budget: dropping it would silently make the action the user just
        // performed un-undoable.
        while stack.count > 1, byteCount > byteBudget {
            byteCount -= stack.removeFirst().payloadByteCount
        }
        if stack.isEmpty { byteCount = 0 }
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
        let change = store.lastContentChange
        guard change.isIncremental else {
            // Fallback path: the store could not describe the delta, so the
            // session compares full signature snapshots exactly as before.
            var snapshot = SemanticSnapshot(
                canvases: store.canvases,
                selectedCanvasID: store.selectedCanvasID,
                boardGeneration: store.boardGeneration,
                strokes: store.strokes,
                images: store.images
            )
            #if os(macOS)
            snapshot.semanticObjects = store.semanticObjects
            #endif
            let semanticChange = snapshot != lastSemanticSnapshot
            synchronizeFromStore(
                change: .unknown,
                clearHistory: semanticChange && !isApplyingLocalMutation
            )
            return
        }
        guard change.hasAnyChange else {
            // A revision that republished identical content: nothing to apply
            // and nothing downstream to invalidate (PERF-13/PERF-007).
            observedContentRevision = store.contentRevision
            return
        }
        synchronizeFromStore(
            change: change,
            clearHistory: !isApplyingLocalMutation
        )
    }

    /// Applies whatever the store published most recently, using its own
    /// description of the delta.
    private func synchronizeFromStore(clearHistory: Bool) {
        synchronizeFromStore(
            change: store.lastContentChange,
            clearHistory: clearHistory
        )
    }

    /// Applies the store's published presentation.
    ///
    /// `change` says which collections actually moved. Skipping the untouched
    /// ones matters because every assignment here is a `@Published` write that
    /// re-runs the SwiftUI body and the native surface's `configure`.
    private func synchronizeFromStore(
        change: CanvasStoreContentChange,
        clearHistory: Bool
    ) {
        storeSynchronizationCount &+= 1
        observedContentRevision = store.contentRevision
        let changedBoard = selectedCanvasID != store.selectedCanvasID
        if changedBoard { flushViewState() }
        if change.boardsChanged || canvases != store.canvases {
            canvases = store.canvases
        }
        selectedCanvasID = store.selectedCanvasID
        if changedBoard {
            restoreViewState()
            flushViewState()
        }
        if change.strokesChanged {
            strokes = store.strokes
        }
        if change.imagesChanged {
            images = store.images
        }
        #if os(macOS)
        if change.semanticObjectsChanged {
            semanticObjects = store.semanticObjects
        }
        if let id = selectedSemanticObjectID, !semanticObjects.contains(where: { $0.id == id }) {
            selectedSemanticObjectID = nil
        }
        #endif
        if !failedImageIDs.isEmpty {
            failedImageIDs.formIntersection(Set(images.map(\.id)))
        }
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage.map(Self.compactErrorMessage)
        if let selectedImageID,
           !images.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = nil
        }
        if !change.isIncremental {
            // Only the fallback path needs a baseline snapshot to compare
            // against next time.
            lastSemanticSnapshot = SemanticSnapshot(
                canvases: store.canvases,
                selectedCanvasID: store.selectedCanvasID,
                boardGeneration: store.boardGeneration,
                strokes: store.strokes,
                images: store.images
            )
            #if os(macOS)
            lastSemanticSnapshot.semanticObjects = semanticObjects
            #endif
        }

        if clearHistory {
            cancelPendingPlacement()
            cancelActiveInteraction()
            self.clearHistory()
        }
    }

    /// Keeps a canvas failure readable in the panel's two-line banner.
    ///
    /// Store failures chain their context with " · " separators and some
    /// underlying errors are long, so an unbounded message either truncates
    /// mid-word or pushes the banner over the toolbar (CANVAS-008).
    static func compactErrorMessage(_ message: String) -> String {
        let clauses = message
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var headline = clauses.first else { return message }
        if headline.count > maximumErrorMessageLength {
            headline = String(headline.prefix(maximumErrorMessageLength))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
        }
        let remainder = clauses.count - 1
        guard remainder > 0 else { return headline }
        return remainder == 1
            ? "\(headline) · 1 more detail"
            : "\(headline) · \(remainder) more details"
    }
}
