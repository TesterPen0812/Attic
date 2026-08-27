import Combine
import Foundation

@MainActor
final class CanvasSession: ObservableObject {
    static let minimumWidth = 1.0
    static let maximumWidth = 16.0

    @Published private(set) var strokes: [CanvasStroke]
    @Published private(set) var boardGeneration: Int64
    @Published private(set) var tool: CanvasTool = .pen
    @Published private(set) var color: CanvasInkColor = .ink
    @Published private(set) var width: Double = 3
    @Published private(set) var viewport = CanvasViewport()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastErrorMessage: String?

    private enum HistoryCommand {
        case add(CanvasStroke)
        case erase([CanvasStroke])
        case clear([CanvasStroke])
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
        let boardGeneration: Int64
        let strokes: [CanvasStroke]
    }

    init(store: CanvasStore) {
        self.store = store
        strokes = store.strokes
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage
        lastSemanticSnapshot = SemanticSnapshot(
            boardGeneration: store.boardGeneration,
            strokes: store.strokes
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

    func selectTool(_ tool: CanvasTool) {
        self.tool = tool
    }

    func selectColor(_ color: CanvasInkColor) {
        self.color = color
        tool = .pen
    }

    func setWidth(_ width: Double) {
        guard width.isFinite else { return }
        self.width = min(
            max(width, Self.minimumWidth),
            Self.maximumWidth
        )
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

        recordNewCommand(.add(persistedStroke))
        return true
    }

    @discardableResult
    func erase(strokeIDs: Set<UUID>) -> Bool {
        let captured = strokes.filter { strokeIDs.contains($0.id) }
        guard !captured.isEmpty else { return false }

        let succeeded = applyLocalMutation {
            store.setDeleted(
                true,
                strokeIDs: Set(captured.map(\.id))
            )
        }
        guard succeeded else { return false }

        recordNewCommand(.erase(captured))
        return true
    }

    @discardableResult
    func clear() -> Bool {
        let captured = strokes
        guard !captured.isEmpty else { return false }

        let succeeded = applyLocalMutation {
            store.clearBoard()
        }
        guard succeeded else { return false }

        recordNewCommand(.clear(captured))
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoStack.last else { return false }

        let succeeded = applyLocalMutation {
            switch command {
            case let .add(stroke):
                return store.setDeleted(true, strokeIDs: [stroke.id])
            case let .erase(strokes), let .clear(strokes):
                return store.restore(strokes)
            }
        }
        guard succeeded else { return false }

        undoStack.removeLast()
        redoStack.append(command)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoStack.last else { return false }

        let succeeded = applyLocalMutation {
            switch command {
            case let .add(stroke):
                return store.restore([stroke])
            case let .erase(strokes):
                return store.setDeleted(
                    true,
                    strokeIDs: Set(strokes.map(\.id))
                )
            case .clear:
                return store.clearBoard()
            }
        }
        guard succeeded else { return false }

        redoStack.removeLast()
        undoStack.append(command)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
        return true
    }

    func resetView() {
        viewport.reset()
    }

    func fit(in size: CGSize) {
        let bounds = strokes.compactMap(\.bounds).reduce(nil as CGRect?) {
            partial, bounds in
            partial.map { $0.union(bounds) } ?? bounds
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

    func refresh() {
        store.refresh()
    }

    private func recordNewCommand(_ command: HistoryCommand) {
        undoStack.append(command)
        redoStack.removeAll(keepingCapacity: true)
        trimHistoryIfNeeded()
        updateHistoryAvailability()
    }

    private func trimHistoryIfNeeded() {
        if undoStack.count > Self.maximumHistoryCount {
            undoStack.removeFirst(
                undoStack.count - Self.maximumHistoryCount
            )
        }
        if redoStack.count > Self.maximumHistoryCount {
            redoStack.removeFirst(
                redoStack.count - Self.maximumHistoryCount
            )
        }
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func applyLocalMutation(
        _ mutation: () -> Bool
    ) -> Bool {
        isApplyingLocalMutation = true
        let succeeded = mutation()
        synchronizeFromStore(clearHistory: false)
        isApplyingLocalMutation = false
        return succeeded
    }

    private func handleStoreRevision() {
        let snapshot = SemanticSnapshot(
            boardGeneration: store.boardGeneration,
            strokes: store.strokes
        )
        let semanticChange = snapshot != lastSemanticSnapshot
        synchronizeFromStore(
            clearHistory: semanticChange && !isApplyingLocalMutation
        )
    }

    private func synchronizeFromStore(clearHistory: Bool) {
        strokes = store.strokes
        boardGeneration = store.boardGeneration
        lastErrorMessage = store.lastErrorMessage
        lastSemanticSnapshot = SemanticSnapshot(
            boardGeneration: store.boardGeneration,
            strokes: store.strokes
        )

        if clearHistory {
            undoStack.removeAll(keepingCapacity: true)
            redoStack.removeAll(keepingCapacity: true)
            updateHistoryAvailability()
        }
    }
}
