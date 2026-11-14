import AppKit
import SwiftData
import Combine
import Observation
import SwiftUI

enum DrawTool: String, CaseIterable, Sendable {
    case select, pen, eraser, text, shape
}

/// What widens in place in the tool capsule (one at a time): Shape's
/// shapes, the swatch's colours (D1), Pen's and Text's widths (D2).
enum DrawStrip: Equatable, Sendable {
    case shape, colour, pen, text
}

/// The selection bar's buttons, in order (Planning.md, Draw › Selection).
enum DrawSelectionAction: String, Equatable, Sendable {
    case style, saveImage, duplicate, delete, more
}

/// ⋯'s rows (Planning.md, Draw › Selection), with no keys printed.
enum DrawMoreCommand: String, CaseIterable, Sendable {
    case cut, copy, paste, duplicate, copyAsImage, bringToFront, sendToBack, delete
}

/// Job 3's seam: Save Image, Copy as Image and image drops. Nil keeps those
/// commands visible but inert (Copy as Image greyed).
@MainActor
protocol DrawImageSeam: AnyObject {
    func saveImage(_ object: DrawObject)
    func copyAsImage(_ objects: [DrawObject])
}

/// The open text box: each committed text change has its own Undo step.
struct DrawTextEdit: Equatable {
    var id: UUID
    var origin: CGPoint
    var text: String
    var style: DrawStyle
    /// In the store (false for a new box until its first character).
    var stored: Bool
    /// The box's wrap width, once a side handle has set one.
    var width: CGFloat? = nil
    /// The box's scale from a group resize (1 for a new box).
    var scale: CGFloat = 1
    /// Original metadata stays available while clearing text removes its
    /// stored object; retyping must keep its width, scale and layer.
    var retainedObject: DrawObject? = nil
    /// The text's size as drawn, in points.
    var pointSize: CGFloat { CGFloat(style.size.textSize) * scale }
}

/// Mutable live samples: AppKit can deliver thousands of drag events before
/// mouse-up. Keep one buffer so extending a stroke never copies its prefix.
final class DrawInkTrace: Equatable {
    private(set) var samples: [DrawInkSample]
    private(set) var hasPressure: Bool

    init(_ sample: DrawInkSample) {
        samples = [sample]
        hasPressure = sample.pressure != nil
    }

    func append(_ sample: DrawInkSample) {
        // AppKit can interleave ordinary mouse-drag/up events with tablet
        // points. Do not let an unpressured event reset the stylus nib.
        let pressure = sample.pressure ?? (hasPressure ? samples.last?.pressure : nil)
        samples.append(DrawInkSample(point: sample.point, pressure: pressure))
        if pressure != nil { hasPressure = true }
    }

    static func == (lhs: DrawInkTrace, rhs: DrawInkTrace) -> Bool { lhs.samples == rhs.samples }
}

/// What the pointer is doing on the board right now (never published: the
/// board view reads it on each event).
enum DrawLive: Equatable {
    case ink(DrawInkTrace)
    case shape(DrawShape, start: CGPoint, end: CGPoint)
    case erase(gone: Set<UUID>, last: CGPoint)
    case move(from: CGPoint, offset: CGPoint, moved: Bool)
    case marquee(from: CGPoint, to: CGPoint, base: Set<UUID>)
    case pan(start: CGPoint, viewport: DrawViewport)
    case resize(DrawResize)
}

/// What the board view hears from the page model. Calls arrive on the main
/// actor, synchronously, from input handlers too: the view only moves layers
/// and queues background rasters in response.
@MainActor
protocol DrawBoardSink: AnyObject {
    func drawContentChanged()
    func drawLiveChanged()
    func drawViewportChanged()
    func drawSelectionChanged()
    func drawEditingChanged(replacingText: Bool)
    func drawVisibilityChanged()
    func drawReturnKeyboard()
}

extension DrawBoardSink {
    func drawReturnKeyboard() {}
}

/// The viewport and the zoom pill (D5), observed only by the overlays that
/// follow the board (selection bar, pill), so a pan never re-evaluates the
/// page's other views.
@MainActor
final class DrawViewportState: ObservableObject {
    @Published var viewport = DrawViewport()
    /// The zoom level shows for a moment after a zoom or a fit.
    @Published var isFlashing = false
    /// D5: nothing on the board is in view (only after the user's own pan or zoom).
    @Published var isLost = false

    var pillShown: Bool { isFlashing || isLost }
    var pillLabel: String {
        isLost && !isFlashing ? String(localized: "Fit") : "\(Int((viewport.zoom * 100).rounded())) %"
    }
}

/// The Draw page: the open canvas, the tools and the board's interaction
/// state, over the store (`Attic/Draw/API.md`). Every edit is one store
/// command; the model keeps the open canvas's objects in drawing order from
/// the store's deltas, never rebuilding them in an input handler.
@MainActor
final class DrawPageModel: ObservableObject {
    let store: any DrawStoreProtocol
    let viewportState = DrawViewportState()

    // MARK: Published page state

    @Published var tool: DrawTool = .pen
    @Published private(set) var shape: DrawShape = .rectangle
    @Published private(set) var colour: DrawColour = .ink
    @Published private(set) var strokeSize: DrawSize = .medium
    @Published private(set) var textSize: DrawSize = .medium
    @Published var strip: DrawStrip?
    @Published private(set) var selection: [UUID] = []
    /// D3: Style is open inside the selection bar.
    @Published var isSelectionStyleOpen = false
    /// D4: the title capsule is the canvas filter.
    @Published private(set) var isFiltering = false
    @Published private(set) var isSearching = false
    /// D6: a stroke (or a shape or erase) is under way.
    @Published var isDrawingLive = false
    @Published var isMovingSelection = false
    @Published private(set) var editingID: UUID?
    @Published private(set) var canvasName = ""
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var lastError: String?
    /// Bumped when the selection's objects change shape (the bar follows them).
    @Published private(set) var selectionRevision = 0

    // MARK: Board state (not published)

    private(set) var canvasID: UUID?
    /// The open canvas's live objects, in drawing order.
    private(set) var objects: [DrawObject] = []
    /// Advances with every change the board must redraw.
    private(set) var contentRevision = 0
    var objectNavigationCache: (revision: Int, ids: [UUID])?
    var live: DrawLive?
    /// A middle-button pan keeps ownership until that button is released,
    /// even if the original left button finishes first.
    var liveStartedWithMiddleButton = false
    /// Last drag modifier for callers that finish an input without an event.
    var lastPointerShift = false
    private(set) var editing: DrawTextEdit?
    /// Disk-backed typing is visible immediately; its bounded burst reaches
    /// the recovery checkpoint and repository after a frame opportunity.
    private var typingCommands: [DrawCommand] = []
    private var typingCanvasID: UUID?
    private var typingStartedAt: UInt64 = 0
    private var typingTimer: DispatchWorkItem?
    private enum AcknowledgedAction {
        case command(DrawCommand)
        case undo
        case redo
    }
    private struct AcknowledgedDraw {
        let canvas: UUID
        let action: AcknowledgedAction
        let before: [DrawObject]
    }
    /// Visual changes are made on the input callback. The same ordered
    /// commands enter the store after one display interval, or immediately
    /// on a lifecycle/command boundary. Until then only this page owns them.
    private var acknowledgedDraw: [AcknowledgedDraw] = []
    private var acknowledgedDrawTimer: DispatchWorkItem?
    /// Sparse, read-only history projections while a batch is waiting to
    /// settle. Their heads track rapid Undo/Redo without entering the writer.
    private var acknowledgedUndoChanges: [DrawChange]?
    private var acknowledgedRedoChanges: [DrawChange] = []
    private(set) var isShown = false
    var spaceHeld = false
    /// Where the board is, and its clear area (inside the top row and the
    /// bottom bar), in board points.
    private(set) var boardSize = CGSize(width: 320, height: 460)
    private(set) var clearInsets = NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5)
    weak var board: DrawBoardSink?
    weak var imageSeam: DrawImageSeam?
    var pasteboard: NSPasteboard = .general
    /// The seconds the zoom level shows for (the working file's 1.1 s).
    var pillFlashDuration: TimeInterval = 1.1
    /// Save Image, Copy as Image and Export… (the page's image seam).
    private(set) lazy var images = DrawImageActions(model: self)
    /// The latest drop or paste of images, until it is placed.
    private(set) var pendingImport: Task<Void, Never>?
    /// Every drop or paste of images not yet placed (quit waits for all).
    private var imports: [UUID: Task<Void, Never>] = [:]
    /// A canvas's thumbnail renders once its edits have been quiet this long.
    var thumbnailSettleDelay: TimeInterval = 1.5
    /// Renders a thumbnail away from the main thread (tests hold one back).
    var thumbnailRenderer: @Sendable (_ objects: [DrawObject], _ dark: Bool) async -> Data? = { objects, dark in
        await Task.detached(priority: .utility) { DrawThumbnail.render(objects, dark: dark) }.value
    }

    private var viewports: [UUID: DrawViewport] = [:]
    private var initialFitPending = false
    private var boardHasRoom: Bool {
        boardSize.width > clearInsets.left + clearInsets.right + 2 * DrawViewport.fitPadding
            && boardSize.height > clearInsets.top + clearInsets.bottom + 2 * DrawViewport.fitPadding
    }
    private var userMovedView = false
    private var appliedRevision: UInt64 = 0
    var externalSyncDeferred = false
    /// While a canvas switch or an acknowledged flush is settling queued
    /// input, a canvas that input just deleted must not navigate from inside
    /// it: the switch finishes its own navigation, and a flush hops once at
    /// its end.
    private var deletedCanvasHopDeferrals = 0
    private var flashGeneration = 0
    /// Canvases whose thumbnail is behind their content.
    private var thumbnailDirty: Set<UUID> = []
    /// A render can outlive the bounded quit. Keep dirty IDs across launch
    /// until their quiet thumbnail write succeeds (no drawing-store schema change).
    private var unrenderedThumbnails: Set<UUID> = []
    private var thumbnailTimer: DispatchWorkItem?
    private var thumbnailRenders: [UUID: (generation: Int, dark: Bool, task: Task<Void, Never>)] = [:]
    private var thumbnailGeneration = 0
    /// Shown canvases whose thumbnail was rendered for the other
    /// appearance, waiting for the next turn of the main loop.
    private var appearanceQueue: Set<UUID> = []
    private var appearanceDrainScheduled = false
    private var appearanceObservation: NSKeyValueObservation?
    /// The save notice's ✕ hides it until the next problem.
    @Published private var dismissedSaveProblem: String?
    /// A file Save Image or Export… couldn't write, or an image that
    /// couldn't be added: shown in the same notice, without Retry.
    @Published private var actionProblem: String?
    /// A bounded quit attempt can refuse while original image bytes are still loading.
    @Published private var quitImportPending = false

    private let resumeDefaults: UserDefaults?
    private var viewportMemorySave: DispatchWorkItem?

    init(store: any DrawStoreProtocol, resumeDefaults: UserDefaults? = nil) {
        self.resumeDefaults = resumeDefaults
        self.store = store
        if let ids = resumeDefaults?.stringArray(forKey: "AtticDraw.unrenderedThumbnails") {
            unrenderedThumbnails = Set(ids.compactMap(UUID.init(uuidString:)))
            thumbnailDirty = unrenderedThumbnails
        }
        if let data = resumeDefaults?.data(forKey: "AtticDraw.viewports"),
           let saved = try? JSONDecoder().decode([UUID: DrawViewport].self, from: data) {
            viewports = saved.filter { _, v in
                v.x.isFinite && v.y.isFinite && v.zoom.isFinite && (DrawViewport.minZoom...DrawViewport.maxZoom).contains(v.zoom)
            }
        }
        observeStore()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceChanged() } }
        }
        DrawLibraryHub.register(store)
        DrawLibraryHub.register(self)
        imageSeam = images
    }

    /// The library's canvas menu under the title capsule (D4) and the top
    /// Search's results (`Attic/Draw/Library/`).
    private(set) lazy var library = DrawLibraryMenuModel(store: store, actions: libraryActions)
    private(set) lazy var search = DrawSearchModel(store: store, actions: libraryActions)

    /// The page's side of the library seam.
    var libraryActions: DrawLibraryActions {
        DrawLibraryActions(open: { [weak self] in self?.open($0) },
                           newCanvas: { [weak self] in
                               guard let self else { return }
                               AtticSounds.play(.created, if: self.newCanvas(name: $0))
                           },
                           reveal: { [weak self] in self?.reveal(canvasID: $0, objectID: $1) },
                           close: { [weak self] in self?.closeFilter() },
                           canvasChanged: { [weak self] in self?.syncExternalChanges() },
                           export: { [weak self] in self?.images.exportCanvas($0) },
                           copyAsImage: { [weak self] in self?.images.copyCanvas($0) },
                           hasContent: { [weak self] in self?.hasContent($0) ?? false },
                           thumbnailsShown: { [weak self] in self?.thumbnailsShown($0) })
    }

    /// The one model the panel keeps for the session (the store owns Undo,
    /// so it outlives page and panel switches).
    /// The panel's page. The app installs the durable store at launch
    /// (`install(container:)`); tests and previews keep the in-memory one.
    private(set) static var shared = DrawPageModel(store: DrawInMemoryStore())

    /// Called once by the app with its own container, only while the setting is on.
    static func install(container: ModelContainer, resumeDefaults: UserDefaults? = nil) {
        shared = DrawPageModel(store: DrawPersistentStore(container: container), resumeDefaults: resumeDefaults)
    }

    #if DEBUG
    /// Tests only: the session's page model (the quit route asks it).
    static func replaceShared(_ model: DrawPageModel) { shared = model }
    #endif

    // MARK: Save problems and quit

    /// The shell's notice for a save the store couldn't confirm (`.retry` or
    /// `.held`), with Retry: the open canvas's first, else any canvas's.
    var saveNotice: PanelNoticeContent? {
        if let issue = store.recoveryIssue {
            return PanelNoticeContent(message: issue, canRetry: false)
        }
        if let problem = saveProblem, problem.message != dismissedSaveProblem {
            return PanelNoticeContent(message: problem.message, canRetry: true)
        }
        if let actionProblem { return PanelNoticeContent(message: actionProblem, canRetry: false) }
        if quitImportPending {
            return PanelNoticeContent(message: String(localized: "Importing images…"), canRetry: false,
                                      isInformational: true)
        }
        return nil
    }

    /// Shows a problem that has nothing to retry (a file that couldn't be
    /// written: the old one is left as it was).
    func report(_ message: String) {
        actionProblem = message
    }

    private var saveProblem: (id: UUID, message: String)? {
        let pending = store.pendingEdits
        let id = canvasID.flatMap { pending[$0] == nil ? nil : $0 } ?? pending.keys.sorted { $0.uuidString < $1.uuidString }.first
        guard let id, let edit = pending[id] else { return nil }
        switch edit.outcome {
        case .retry(let message), .held(let message):
            return (id, message.isEmpty ? String(localized: "Your drawing couldn’t be saved.") : message)
        case .saved, .unchanged:
            return (id, String(localized: "Your drawing couldn’t be saved."))
        }
    }

    /// The notice's Retry: a failed save is tried again; a held one is
    /// reconciled with what the store has.
    func retrySave() {
        dismissedSaveProblem = nil
        for (id, edit) in store.pendingEdits {
            let result: DrawSaveResult
            if case .held = edit.outcome { result = store.reconcile(on: id) } else { result = store.retry(on: id) }
            if id == canvasID { apply(result) }
            library.renameSavedByRetry(on: id)
        }
        objectWillChange.send()
    }

    /// The notice's ✕ (the edit stays unsettled, so quit still waits).
    func dismissSaveError() {
        if let problem = saveProblem, problem.message != dismissedSaveProblem {
            dismissedSaveProblem = problem.message
        } else if actionProblem != nil {
            actionProblem = nil
        } else {
            quitImportPending = false
        }
    }

    /// The app's quit: finish input, give imports a bounded chance to save,
    /// then settle saved edits. A still-running import refuses termination;
    /// its task stays owned by this model and completes normally. Thumbnails
    /// are regenerable and never hold the quit reply indefinitely.
    func prepareToQuit() async -> Bool {
        finishLiveInput()
        endEditing()
        flushAcknowledgedDraw()
        flushTyping()
        flushViewportMemory()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        while !imports.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard imports.isEmpty else {
            quitImportPending = true
            return false
        }
        quitImportPending = false
        flushThumbnail()
        while !thumbnailRenders.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if store.hasUnsettledEdits { retrySave() }
        return !store.hasUnsettledEdits
    }

    private func hasContent(_ id: UUID) -> Bool {
        if id == canvasID { return !objects.isEmpty }
        return ((try? store.open(id).objects) ?? []).contains { $0.deletedAt == nil }
    }

    // MARK: Thumbnails

    private func markThumbnailDirty(_ id: UUID) {
        thumbnailDirty.insert(id)
        if unrenderedThumbnails.insert(id).inserted { persistUnrenderedThumbnails() }
    }

    private func persistUnrenderedThumbnails() {
        resumeDefaults?.set(unrenderedThumbnails.map(\.uuidString).sorted(), forKey: "AtticDraw.unrenderedThumbnails")
    }

    /// The open canvas changed: its thumbnail renders once edits settle.
    private func thumbnailNeeded() {
        guard let canvasID else { return }
        markThumbnailDirty(canvasID)
        thumbnailTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.thumbnailSettled() }
        }
        thumbnailTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + thumbnailSettleDelay, execute: timer)
    }

    private func thumbnailSettled() {
        thumbnailTimer = nil
        // Still drawing: wait for the next quiet spell.
        guard live == nil else { return thumbnailNeeded() }
        flushThumbnail()
    }

    /// Renders the open canvas's thumbnail now if it is behind (a switch,
    /// a hide, quit).
    func flushThumbnail() {
        thumbnailTimer?.cancel()
        thumbnailTimer = nil
        guard let id = canvasID, thumbnailDirty.contains(id) else { return }
        renderThumbnail(id, objects: objects)
    }

    /// Off the main thread, from this snapshot, through the store's quiet
    /// `.thumbnail` command (no Undo, no date, no new order), recording the
    /// appearance it was rendered for. With `keepOnFailure`, a render that
    /// fails leaves the shown thumbnail alone.
    private func renderThumbnail(_ id: UUID, objects snapshot: [DrawObject], keepOnFailure: Bool = false) {
        thumbnailDirty.remove(id)
        thumbnailGeneration += 1
        let generation = thumbnailGeneration
        guard !snapshot.isEmpty else {
            // Nothing drawn: any render still under way is out of date and
            // must never land after the empty card.
            thumbnailRenders[id]?.task.cancel()
            thumbnailRenders[id] = nil
            writeThumbnail(nil, dark: DrawImageActions.isDark, on: id)
            return
        }
        let dark = DrawImageActions.isDark
        let render = thumbnailRenderer
        let task = Task { @MainActor [weak self] in
            let data = await render(snapshot, dark)
            guard let self, self.thumbnailRenders[id]?.generation == generation else { return }
            self.thumbnailRenders[id] = nil
            if data == nil, keepOnFailure { return }
            self.writeThumbnail(data, dark: dark, on: id)
        }
        thumbnailRenders[id] = (generation, dark, task)
    }

    /// These canvases' thumbnails are about to show (the canvas menu,
    /// Search). Any rendered for the other appearance is queued, once per
    /// canvas, and re-rendered on the next turn of the main loop, so the
    /// caller (a view's appearance) never renders or writes state. The old
    /// thumbnail shows until the new one lands, then the card updates in
    /// place. Canvases that never show are left alone.
    func thumbnailsShown(_ canvases: [DrawCanvas]) {
        let dark = DrawImageActions.isDark
        for canvas in canvases where canvas.deletedAt == nil &&
            (unrenderedThumbnails.contains(canvas.id) || (canvas.thumbnail != nil && canvas.thumbnailDark != dark)) {
            appearanceQueue.insert(canvas.id)
        }
        guard !appearanceQueue.isEmpty, !appearanceDrainScheduled else { return }
        appearanceDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.renderQueuedAppearances() }
        }
    }

    /// The app's appearance changed: the open canvas's thumbnail renders
    /// again once edits settle, like an edit's.
    func appearanceChanged() {
        guard let canvasID, !objects.isEmpty else { return }
        let dark = DrawImageActions.isDark
        // Already on its way in this appearance, or settling (which renders
        // in the appearance of the moment it settles).
        if thumbnailRenders[canvasID]?.dark == dark { return }
        if thumbnailDirty.contains(canvasID), thumbnailTimer != nil { return }
        if let canvas = try? store.open(canvasID).canvas, canvas.thumbnail != nil, canvas.thumbnailDark == dark,
           thumbnailRenders[canvasID] == nil { return }
        thumbnailNeeded()
    }

    private func renderQueuedAppearances() {
        appearanceDrainScheduled = false
        let ids = appearanceQueue
        appearanceQueue = []
        let dark = DrawImageActions.isDark
        for id in ids where thumbnailRenders[id]?.dark != dark {
            if id == canvasID {
                if thumbnailDirty.contains(id), thumbnailTimer == nil, live == nil {
                    renderThumbnail(id, objects: objects, keepOnFailure: true)
                    continue
                }
                appearanceChanged()
                continue
            }
            guard store.pendingEdits[id] == nil, let snapshot = try? store.open(id), snapshot.canvas.deletedAt == nil else { continue }
            let stale = unrenderedThumbnails.contains(id)
            guard stale || (snapshot.canvas.thumbnail != nil && snapshot.canvas.thumbnailDark != dark) else { continue }
            renderThumbnail(id, objects: snapshot.objects, keepOnFailure: true)
        }
    }

    private func writeThumbnail(_ data: Data?, dark: Bool, on id: UUID) {
        let synced = appliedRevision == store.revision
        switch store.perform(.thumbnail(data, dark: dark), on: id) {
        case .saved:
            if synced { appliedRevision = store.revision }
            if !thumbnailDirty.contains(id), unrenderedThumbnails.remove(id) != nil { persistUnrenderedThumbnails() }
        case .unchanged:
            // An unsettled edit comes first; the thumbnail follows it.
            if store.pendingEdits[id] != nil { markThumbnailDirty(id) }
            else if !thumbnailDirty.contains(id), unrenderedThumbnails.remove(id) != nil { persistUnrenderedThumbnails() }
        case .retry, .held:
            markThumbnailDirty(id)
        }
    }

    var viewport: DrawViewport { viewportState.viewport }

    var clearRect: CGRect {
        CGRect(x: clearInsets.left, y: clearInsets.top,
               width: max(1, boardSize.width - clearInsets.left - clearInsets.right),
               height: max(1, boardSize.height - clearInsets.top - clearInsets.bottom))
    }

    var selectedObjects: [DrawObject] {
        let ids = Set(selection)
        return objects.filter { ids.contains($0.id) }
    }

    func object(_ id: UUID) -> DrawObject? { objects.first { $0.id == id } }

    /// Objects the agent saved but has not drawn in yet: the chat's sketch
    /// replay draws them over the board, then lets them show (Accepted
    /// 2026-11-06, "the living spark does the work"). Presentation only.
    var agentVeil: Set<UUID> = [] {
        didSet { if agentVeil != oldValue { board?.drawContentChanged() } }
    }

    /// What the next raster leaves out or draws moved.
    var rasterHidden: Set<UUID> {
        var hidden: Set<UUID> = agentVeil
        if let editing { hidden.insert(editing.id) }
        if case .erase(let gone, _) = live { hidden.formUnion(gone) }
        return hidden
    }

    var rasterMove: (ids: Set<UUID>, offset: CGPoint)? {
        guard case .move(_, let offset, true) = live else { return nil }
        return (Set(selection), offset)
    }

    // MARK: Canvas lifecycle

    /// The first visit: the newest canvas, or a new empty one.
    func start() {
        guard canvasID == nil else { return }
        if let raw = resumeDefaults?.string(forKey: "AtticDraw.lastCanvas"), let id = UUID(uuidString: raw),
           (try? store.open(id)) != nil { open(id) }
        else if let newest = try? store.library().first { open(newest.id) } else { newCanvas() }
    }

    func open(_ id: UUID) {
        if id != canvasID, library.isRenaming {
            library.commitRename()
            guard !library.isRenaming else { return }
        }
        finishLiveInput()
        deletedCanvasHopDeferrals += 1
        endEditing()
        flushAcknowledgedDraw()
        deletedCanvasHopDeferrals -= 1
        // The canvas being left gets its thumbnail now.
        flushThumbnail()
        if let canvasID { viewports[canvasID] = viewport }
        flushViewportMemory()
        guard let snapshot = try? IdleLatencyTrace.span("draw_board_open", { try store.open(id) }) else { return }
        IdleLatencyTrace.count("draw_objects_opened", snapshot.objects.count)
        store.activate(id)
        canvasID = id
        resumeDefaults?.set(id.uuidString, forKey: "AtticDraw.lastCanvas")
        canvasName = confirmedName(in: snapshot)
        library.currentCanvasID = id
        objects = snapshot.objects.filter { $0.deletedAt == nil }
        // A prior session may have quit while its thumbnail renderer was
        // still running. Its persisted dirty marker forces regeneration here.
        if thumbnailDirty.contains(id), thumbnailRenders[id] == nil {
            renderThumbnail(id, objects: objects, keepOnFailure: true)
        }
        selection = []
        strip = nil
        isSelectionStyleOpen = false
        closeFilter()
        appliedRevision = store.revision
        externalSyncDeferred = false
        initialFitPending = false
        if let kept = viewports[id] {
            setViewport(kept, byUser: false)
        } else {
            initialFitPending = !objects.isEmpty && !boardHasRoom
            setViewport(objects.isEmpty || initialFitPending ? DrawViewport()
                : DrawViewport.fit(DrawGeometry.union(objects), in: clearRect), byUser: false)
        }
        userMovedView = false
        refreshHistory()
        contentRevision += 1
        board?.drawContentChanged()
        board?.drawSelectionChanged()
    }

    /// "+": a new, empty canvas straight away (a draft until its first content).
    @discardableResult
    func newCanvas(name: String? = nil) -> Bool {
        if library.isRenaming {
            library.commitRename()
            guard !library.isRenaming else { return false }
        }
        let canvas = store.create(name: name)
        viewports[canvas.id] = DrawViewport()
        open(canvas.id)
        setTool(.pen)
        return canvasID == canvas.id
    }

    /// The library's "reveal": open the canvas, bring the text box into view
    /// and select it.
    func reveal(canvasID id: UUID, objectID: UUID) {
        if canvasID != id { open(id) }
        guard canvasID == id else { return }
        guard let target = object(objectID) else { return }
        let rect = viewport.screen(DrawGeometry.bounds(target))
        if !clearRect.contains(rect) {
            let centre = DrawGeometry.bounds(target)
            setViewport(DrawViewport(x: clearRect.midX - centre.midX * viewport.zoom,
                                     y: clearRect.midY - centre.midY * viewport.zoom, zoom: viewport.zoom), byUser: false)
        }
        setTool(.select)
        select([objectID])
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        if !shown {
            spaceHeld = false
            finishLiveInput()
            flushThumbnail()
        }
        isShown = shown
        board?.drawVisibilityChanged()
    }

    func setBoard(size: CGSize, clearInsets insets: NSEdgeInsets) {
        let changed = size != boardSize || insets.top != clearInsets.top || insets.bottom != clearInsets.bottom
            || insets.left != clearInsets.left || insets.right != clearInsets.right
        guard changed else { return }
        boardSize = size
        clearInsets = insets
        if initialFitPending, boardHasRoom {
            initialFitPending = false
            setViewport(DrawViewport.fit(DrawGeometry.union(objects), in: clearRect), byUser: false)
        }
        updateLost()
    }

    // MARK: Tools

    func setTool(_ next: DrawTool) {
        if editing != nil, next != .text { endEditing() }
        strip = nil
        if next != .select, !selection.isEmpty { select([]) }
        tool = next
    }

    /// A click on a tool in the capsule: Shape widens into its shapes; a
    /// second click on the selected Pen or Text widens it into its widths (D2).
    func clickTool(_ clicked: DrawTool) {
        switch clicked {
        case .shape:
            if tool == .shape, strip == .shape { strip = nil; return }
            setTool(.shape)
            strip = .shape
        case .pen, .text:
            let widths: DrawStrip = clicked == .pen ? .pen : .text
            if tool == clicked {
                strip = strip == widths ? nil : widths
            } else {
                setTool(clicked)
            }
        case .select, .eraser:
            setTool(clicked)
        }
    }

    func pickShape(_ next: DrawShape) {
        setTool(.shape)
        shape = next
        strip = nil
    }

    /// D1: the swatch widens into the colours (and folds the open strip).
    func clickSwatch() { strip = strip == .colour ? nil : .colour }

    /// The swatch's colour: the tools' next colour, and the open text box's
    /// (the working file's bug, not copied: it styles the box).
    func pickColour(_ next: DrawColour) {
        colour = next
        strip = nil
        restyleEditing { $0.colour = next }
    }

    /// D2's widths: Pen's stroke (shapes share it) or Text's size.
    func pickSize(_ size: DrawSize, for widths: DrawStrip) {
        if widths == .text {
            textSize = size
            restyleEditing { $0.size = size }
        } else {
            strokeSize = size
        }
        strip = nil
    }

    func closeStrip() { strip = nil }

    /// Undo folds away while a strip is open (nobody undoes mid-pick).
    var isUndoShown: Bool { strip == nil }

    // MARK: Selection

    func select(_ ids: [UUID]) {
        syncExternalChanges()
        let next = ids.filter { id in objects.contains { $0.id == id } }
        guard next != selection else { return }
        selection = next
        if next.isEmpty { isSelectionStyleOpen = false }
        board?.drawSelectionChanged()
    }

    func selectAll() {
        endEditing()
        setTool(.select)
        select(objects.map(\.id))
    }

    var selectionActions: [DrawSelectionAction] {
        guard editingID == nil, !isDrawingLive, !isMovingSelection else { return [] }
        let chosen = selectedObjects
        guard !chosen.isEmpty else { return [] }
        let oneImage = chosen.count == 1 && chosen[0].isImage
        var actions: [DrawSelectionAction] = []
        if chosen.contains(where: { !$0.isImage }) { actions.append(.style) }
        if oneImage { actions.append(.saveImage) }
        if chosen.count > 1 || oneImage { actions.append(.duplicate) }
        actions += [.delete, .more]
        return actions
    }

    func toggleSelectionStyle() {
        guard !selection.isEmpty else { return }
        isSelectionStyleOpen.toggle()
    }

    /// Style's values for the selection: nil where the selected objects differ.
    var selectionStyleColour: DrawColour? {
        let styled = selectedObjects.filter { !$0.isImage }
        guard let first = styled.first, styled.allSatisfy({ $0.style.colour == first.style.colour }) else { return nil }
        return first.style.colour
    }

    var selectionStyleSize: DrawSize? {
        let styled = selectedObjects.filter { !$0.isImage }
        guard let first = styled.first, styled.allSatisfy({ $0.style.size == first.style.size }) else { return nil }
        return first.style.size
    }

    /// Style shows text sizes when every styled object is text.
    var selectionIsAllText: Bool {
        let styled = selectedObjects.filter { !$0.isImage }
        return !styled.isEmpty && styled.allSatisfy { if case .text = $0.content { true } else { false } }
    }

    var selectionHasRectangle: Bool {
        selectedObjects.contains { $0.content == .shape(.rectangle) }
    }

    var selectionCorners: DrawCorners {
        selectedObjects.first { $0.content == .shape(.rectangle) }?.style.corners ?? .square
    }

    func styleSelection(colour next: DrawColour) { restyleSelection { $0.style.colour = next } }
    func styleSelection(size next: DrawSize) { restyleSelection { $0.style.size = next } }
    func styleSelection(corners next: DrawCorners) {
        restyleSelection { object in if object.content == .shape(.rectangle) { object.style.corners = next } }
    }

    private func restyleSelection(_ change: (inout DrawObject) -> Void) {
        syncExternalChanges()
        let changed = selectedObjects.filter { !$0.isImage }.map { object -> DrawObject in
            var copy = object
            change(&copy)
            if case .text(let text) = copy.content { Self.measure(&copy, text: text) }
            return copy
        }
        performAcknowledged(.put(changed))
    }

    // MARK: Commands

    func deleteSelection() {
        syncExternalChanges()
        guard !selection.isEmpty else { return }
        let ids = selection
        select([])
        performAcknowledged(.remove(ids))
    }

    func duplicateSelection() {
        syncExternalChanges()
        let chosen = selectedObjects
        guard !chosen.isEmpty else { return }
        var z = topZ
        let step = 12 / viewport.zoom
        let copies = chosen.map { object -> DrawObject in
            z += 1
            var copy = object.translated(by: DrawPoint(x: step, y: step))
            copy.zIndex = z
            return copy
        }
        performAcknowledged(.put(copies))
        select(copies.map(\.id))
    }

    func arrange(toFront: Bool) {
        syncExternalChanges()
        let chosen = selectedObjects
        guard !chosen.isEmpty else { return }
        // Pre-increment below: leave every chosen object's z below the
        // previous bottom, so UUID tie-breaking cannot leave one in front.
        var z = toFront ? topZ : (objects.first?.zIndex ?? 0) - Int64(chosen.count) - 1
        let moved = chosen.map { object -> DrawObject in
            z += 1
            var copy = object
            copy.zIndex = z
            return copy
        }
        performAcknowledged(.put(moved))
    }

    func copySelection() {
        guard let canvasID, !selection.isEmpty, let data = try? store.copy(selection, from: canvasID) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(DrawStore.clipboardType))
    }

    func cutSelection() {
        syncExternalChanges()
        guard let canvasID, !selection.isEmpty, let data = try? store.copy(selection, from: canvasID) else { return }
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType(DrawStore.clipboardType)) else { return }
        let ids = selection
        select([])
        apply(store.cut(ids, from: canvasID))
    }

    var canPaste: Bool {
        pasteboard.availableType(from: [NSPasteboard.PasteboardType(DrawStore.clipboardType)]) != nil || pasteboardHasImage
    }

    /// Draw objects paste as objects; otherwise an image pastes at the
    /// centre of the view.
    func paste() {
        let requestedCanvas = canvasID
        // Establish the current object set before comparing IDs. An agent
        // may have inserted objects since the last asynchronous observation;
        // those must never become part of the owner's pasted selection.
        syncExternalChanges()
        // The same reconciliation can reveal a deleted canvas. In that case
        // the clipboard action belonged to the old canvas, not its successor.
        guard canvasID == requestedCanvas, let canvasID else { return }
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(DrawStore.clipboardType)) else {
            importImages(from: pasteboard, at: nil)
            return
        }
        let before = Set(objects.map(\.id))
        let step = 12 / viewport.zoom
        apply(store.paste(data, into: canvasID, offset: DrawPoint(x: step, y: step)))
        setTool(.select)
        select(objects.map(\.id).filter { !before.contains($0) })
    }

    func runMore(_ command: DrawMoreCommand) {
        switch command {
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: paste()
        case .duplicate: duplicateSelection()
        case .copyAsImage: imageSeam?.copyAsImage(selectedObjects)
        case .bringToFront: arrange(toFront: true)
        case .sendToBack: arrange(toFront: false)
        case .delete: deleteSelection()
        }
    }

    func isEnabled(_ command: DrawMoreCommand) -> Bool {
        switch command {
        case .paste: canPaste
        case .copyAsImage: !selection.isEmpty && imageSeam != nil
        default: !selection.isEmpty
        }
    }

    func saveSelectedImage() {
        guard let image = selectedObjects.first(where: \.isImage) else { return }
        imageSeam?.saveImage(image)
    }

    func undo() {
        guard let canvasID, live == nil else { return }
        flushAcknowledgedDraw()
        flushTyping()
        syncExternalChanges()
        guard self.canvasID == canvasID else { return }
        if editing == nil { select([]) }
        IdleLatencyTrace.count("draw_undo_objects", objects.count)
        IdleLatencyTrace.span("draw_undo_apply") {
            apply(store.undo(on: canvasID), replacingEditorText: true)
        }
    }

    func redo() {
        guard let canvasID, live == nil else { return }
        flushAcknowledgedDraw()
        flushTyping()
        syncExternalChanges()
        guard self.canvasID == canvasID else { return }
        if editing == nil { select([]) }
        apply(store.redo(on: canvasID), replacingEditorText: true)
    }

    // MARK: Text boxes

    /// Text places a box and types straight away.
    func beginText(at world: CGPoint) {
        endEditing()
        let style = DrawStyle(colour: colour, size: textSize, corners: .square)
        editing = DrawTextEdit(id: UUID(), origin: CGPoint(x: world.x, y: world.y - CGFloat(textSize.textSize) * DrawText.clickLift),
                               text: "", style: style, stored: false)
        editingID = editing?.id
        select([])
        board?.drawEditingChanged(replacingText: true)
    }

    /// Return on a selected text box, a double click, or Text on a box.
    func edit(_ id: UUID) {
        syncExternalChanges()
        guard let object = object(id), case .text(let text) = object.content else { return }
        endEditing()
        editing = DrawTextEdit(id: id, origin: CGPoint(x: object.frame.x, y: object.frame.y), text: text,
                               style: object.style, stored: true, width: object.textWidth.map { CGFloat($0) },
                               scale: CGFloat(object.textScale ?? 1), retainedObject: object)
        editingID = id
        select([])
        contentRevision += 1
        board?.drawContentChanged()
        board?.drawEditingChanged(replacingText: true)
    }

    /// Each edit has one Undo step. Disk-backed typing is painted before its
    /// bounded burst save; IME marked text is never sent here.
    func typed(_ text: String) {
        // The observer callback is asynchronous. A keystroke arriving first
        // must still use the agent's current position and text geometry.
        syncExternalChanges()
        guard var edit = editing, text != edit.text else { return }
        edit.text = text
        if text.isEmpty {
            editing = edit
            if edit.stored {
                editing?.stored = false
                if store is DrawPersistentStore {
                    queueTyping(.remove([edit.id]), changed: nil, id: edit.id)
                } else { perform(.remove([edit.id])) }
            }
            return
        }
        var object = object(edit.id) ?? edit.retainedObject ?? DrawObject(
            id: edit.id, frame: DrawFrame(x: edit.origin.x, y: edit.origin.y),
            zIndex: topZ + 1, style: edit.style, content: .text(text))
        object.content = .text(text)
        object.style = edit.style
        object.frame.x = edit.origin.x
        object.frame.y = edit.origin.y
        Self.measure(&object, text: text)
        edit.stored = true
        edit.retainedObject = object
        editing = edit
        if store is DrawPersistentStore {
            queueTyping(.put([object]), changed: object, id: edit.id)
        } else { perform(.put([object])) }
    }

    func endEditing() {
        flushTyping()
        guard editing != nil else { return }
        editing = nil
        editingID = nil
        if tool == .text { tool = .select }
        contentRevision += 1
        board?.drawEditingChanged(replacingText: false)
        board?.drawContentChanged()
    }

    /// A quiet burst saves 120 ms after its last key; continuous typing
    /// checkpoints at most 250 ms after its first key. Quit, blur, page
    /// switch and Undo flush the outstanding changes immediately.
    private func queueTyping(_ command: DrawCommand, changed: DrawObject?, id: UUID) {
        guard let canvasID else { return }
        // A preceding gesture settles on its earlier timer; this keypress
        // must not force that gesture's writer onto the input callback.
        if typingCanvasID != nil, typingCanvasID != canvasID { flushTyping() }
        let now = DispatchTime.now().uptimeNanoseconds
        if typingCommands.isEmpty { typingStartedAt = now; typingCanvasID = canvasID }
        typingCommands.append(command)
        if let changed {
            if let index = objects.firstIndex(where: { $0.id == id }) { objects[index] = changed }
            else { objects.append(changed); objects.sort(by: Self.order) }
        } else { objects.removeAll { $0.id == id } }
        afterContentChange(replacingEditorText: false)
        typingTimer?.cancel()
        let elapsed = Double(now - typingStartedAt) / 1_000_000_000
        let delay = max(0, min(0.120, 0.250 - elapsed))
        let timer = DispatchWorkItem { [self] in flushTyping() }
        typingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func flushTyping() {
        typingTimer?.cancel()
        typingTimer = nil
        guard let canvasID = typingCanvasID, !typingCommands.isEmpty else { return }
        flushAcknowledgedDraw()
        let commands = typingCommands
        typingCommands = []
        typingCanvasID = nil
        typingStartedAt = 0
        let result = store.performTypingBurst(commands, on: canvasID)
        if self.canvasID == canvasID { apply(result) }
    }

    /// Settle queued owner input before an agent reads its baseline or
    /// validates a token. The pointer gesture and text editor stay open;
    /// failed saves remain pending in store.
    func flushLiveInput() {
        flushAcknowledgedDraw()
        flushTyping()
    }

    private func restyleEditing(_ change: (inout DrawStyle) -> Void) {
        syncExternalChanges()
        guard var edit = editing else { return }
        change(&edit.style)
        editing = edit
        board?.drawEditingChanged(replacingText: false)
        guard edit.stored, var object = object(edit.id) else { return }
        object.style = edit.style
        Self.measure(&object, text: edit.text)
        if store is DrawPersistentStore {
            queueTyping(.put([object]), changed: object, id: edit.id)
        } else {
            performAcknowledged(.put([object]))
        }
    }

    static func measure(_ object: inout DrawObject, text: String) {
        let size = DrawText.size(of: text, fontSize: CGFloat(object.style.size.textSize),
                                 width: object.textWidth.map { CGFloat($0) }, scale: CGFloat(object.textScale ?? 1))
        object.frame.width = size.width
        object.frame.height = size.height
    }

    // MARK: Title filter (D4) and search

    func openFilter() {
        if library.isRenaming {
            library.commitRename()
            guard !library.isRenaming else { return }
        }
        endEditing()
        strip = nil
        if !library.filter.isEmpty { library.filter = "" }
        isFiltering = true
    }

    func closeFilter() {
        guard isFiltering else { return }
        isFiltering = false
        library.closeTags()
        if !library.filter.isEmpty { library.filter = "" }
        board?.drawReturnKeyboard()
    }

    func openSearch() {
        if library.isRenaming {
            library.commitRename()
            guard !library.isRenaming else { return }
        }
        endEditing()
        closeFilter()
        isSearching = true
    }

    func closeSearch() {
        isSearching = false
        if !search.query.isEmpty { search.query = "" }
    }

    // MARK: Viewport

    func setViewport(_ next: DrawViewport, byUser: Bool) {
        if byUser { userMovedView = true; initialFitPending = false }
        guard next != viewportState.viewport else { return }
        viewportState.viewport = next
        if let canvasID {
            viewports[canvasID] = next
            if resumeDefaults != nil {
                viewportMemorySave?.cancel()
                let save = DispatchWorkItem { [weak self] in self?.flushViewportMemory() }
                viewportMemorySave = save
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: save)
            }
        }
        updateLost()
        board?.drawViewportChanged()
    }

    /// Coalesced off the pan/zoom input path, and explicitly flushed on
    /// canvas switches and both quit routes.
    func flushViewportMemory() {
        viewportMemorySave?.cancel()
        viewportMemorySave = nil
        guard let resumeDefaults, let data = try? JSONEncoder().encode(viewports) else { return }
        resumeDefaults.set(data, forKey: "AtticDraw.viewports")
    }

    /// ••• (Accepted 2026-11-05, "Page-specific options"): what the board
    /// and the current canvas can do, under their own keys.
    func moreCommands() -> [AtticMenuCommand] {
        let empty = objects.isEmpty
        return [
            AtticMenuCommand(verbatim: String(localized: "Zoom to Fit"), shortcut: KeyboardShortcut("1", modifiers: .shift),
                             isDisabled: empty) { [weak self] in self?.fit() },
            AtticMenuCommand(verbatim: String(localized: "Actual Size"), shortcut: KeyboardShortcut("0", modifiers: .shift)) { [weak self] in
                self?.actualSize()
            },
            AtticMenuCommand(verbatim: String(localized: "Select All"), shortcut: KeyboardShortcut("a", modifiers: .command),
                             isDisabled: empty, startsSection: true) { [weak self] in self?.selectAll() },
            AtticMenuCommand(verbatim: String(localized: "New Canvas"), startsSection: true) { [weak self] in
                guard let self else { return }
                AtticSounds.play(.created, if: self.newCanvas())
            },
            AtticMenuCommand(verbatim: String(localized: "Copy as Image"), isDisabled: empty) { [weak self] in
                guard let self, let canvasID = self.canvasID else { return }
                self.images.copyCanvas(canvasID)
            },
            AtticMenuCommand(verbatim: String(localized: "Export…"), isDisabled: empty) { [weak self] in
                guard let self, let canvasID = self.canvasID else { return }
                self.images.exportCanvas(canvasID)
            }
        ]
    }

    /// ⇧1 and a click on the pill.
    func fit() {
        setViewport(DrawViewport.fit(DrawGeometry.union(objects), in: clearRect), byUser: false)
        flashZoom()
    }

    /// ⇧0.
    func actualSize() {
        setViewport(viewport.actualSize(centre: CGPoint(x: clearRect.midX, y: clearRect.midY)), byUser: true)
        flashZoom()
    }

    func flashZoom() {
        flashGeneration += 1
        let generation = flashGeneration
        if !viewportState.isFlashing { viewportState.isFlashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + pillFlashDuration) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.viewportState.isFlashing = false
        }
    }

    func updateLost() {
        let lost = userMovedView && !objects.isEmpty
            && !viewport.anyInView(objects.map(DrawGeometry.bounds), clear: clearRect)
        if viewportState.isLost != lost { viewportState.isLost = lost }
    }

    // MARK: Store

    var topZ: Int64 { objects.last?.zIndex ?? 0 }

    /// Gesture and menu acknowledgement: update the board's own snapshot on
    /// input, then let the existing duplicate-safe, recoverable store command
    /// run once a frame has had a chance to render. Commands stay ordered.
    func performAcknowledged(_ command: DrawCommand) {
        guard let canvasID else { return }
        // Test/in-memory stores have no disk latency to remove. Keep their
        // immediate command and history semantics for direct model callers.
        guard store is DrawPersistentStore else { _ = perform(command); return }
        // Preserve the order when a text burst began before this gesture.
        if !typingCommands.isEmpty { flushTyping() }
        if acknowledgedDraw.isEmpty { syncExternalChanges() }
        prepareAcknowledgedHistory(on: canvasID)
        let before = objects
        let touched: Set<UUID>
        let afterValues: [UUID: DrawObject]
        switch command {
        case .put(let changed):
            guard !changed.isEmpty else { return }
            touched = Set(changed.map(\.id))
            afterValues = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
            var byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
            for object in changed { byID[object.id] = object }
            objects = byID.values.filter { $0.deletedAt == nil }.sorted(by: Self.order)
        case .remove(let removed):
            guard !removed.isEmpty else { return }
            let ids = Set(removed)
            touched = ids
            afterValues = [:]
            objects.removeAll { ids.contains($0.id) }
        default:
            acknowledgedUndoChanges = nil
            acknowledgedRedoChanges = []
            _ = perform(command)
            return
        }
        guard objects != before else { return }
        let beforeValues = Dictionary(uniqueKeysWithValues: before.filter { touched.contains($0.id) }.map { ($0.id, $0) })
        acknowledgedUndoChanges?.append(DrawChange(canvasID: canvasID, before: nil, after: nil,
                                                    objectsBefore: beforeValues, objectsAfter: afterValues))
        acknowledgedRedoChanges.removeAll()
        acknowledgedDraw.append(AcknowledgedDraw(canvas: canvasID, action: .command(command), before: before))
        afterContentChange(replacingEditorText: false)
        scheduleAcknowledgedDraw()
    }

    /// Undo/Redo from the board and toolbar may preview the stored inverse
    /// without changing the history. The store moves that history only after
    /// its write succeeds. A just-finished stroke is previewed from the
    /// snapshot captured when that gesture ended.
    func undoAcknowledged() { acknowledgeHistory(redo: false) }
    func redoAcknowledged() { acknowledgeHistory(redo: true) }

    private func acknowledgeHistory(redo: Bool) {
        guard let canvasID, live == nil else { return }
        guard store is DrawPersistentStore else {
            if redo { self.redo() } else { self.undo() }
            return
        }
        // Typing has its own 120–250 ms burst semantics and per-key history.
        // Its flush is still the required boundary for Undo/Redo.
        if !typingCommands.isEmpty { if redo { self.redo() } else { self.undo() }; return }
        if acknowledgedDraw.isEmpty { syncExternalChanges() }
        prepareAcknowledgedHistory(on: canvasID)
        let before = objects
        let change: DrawChange
        if redo {
            guard let next = acknowledgedRedoChanges.popLast() else { return }
            change = next
            acknowledgedUndoChanges?.append(next)
        } else {
            guard let next = acknowledgedUndoChanges?.popLast() else { return }
            change = next
            acknowledgedRedoChanges.append(next)
        }
        var projected = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        let target = redo ? change.objectsAfter : change.objectsBefore
        for id in change.objectIDs {
            if let object = target[id], object.deletedAt == nil { projected[id] = object }
            else { projected[id] = nil }
        }
        if editing == nil { select([]) }
        objects = projected.values.sorted(by: Self.order)
        if let canvas = redo ? change.after : change.before { canvasName = canvas.name }
        acknowledgedDraw.append(AcknowledgedDraw(canvas: canvasID,
                                                  action: redo ? .redo : .undo, before: before))
        afterContentChange(replacingEditorText: true)
        scheduleAcknowledgedDraw()
    }

    private func prepareAcknowledgedHistory(on id: UUID) {
        // Only queued actions own a projection. A no-op or empty Undo/Redo
        // must not leave a cached baseline for the next input or canvas.
        guard acknowledgedDraw.isEmpty else { return }
        let history = (store as? DrawStore)?.historyChanges(on: id)
        acknowledgedUndoChanges = history?.undo
        acknowledgedRedoChanges = history?.redo ?? []
    }

    private func scheduleAcknowledgedDraw() {
        guard acknowledgedDrawTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushAcknowledgedDraw() }
        }
        acknowledgedDrawTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020, execute: work)
    }

    /// A canvas switch, quit, synchronous API call or elapsed frame window
    /// settles the same actions through the original store and recovery code.
    /// Failed edits keep the store's recoverable after-draft and Retry UI.
    func flushAcknowledgedDraw() {
        acknowledgedDrawTimer?.cancel()
        acknowledgedDrawTimer = nil
        acknowledgedUndoChanges = nil
        acknowledgedRedoChanges = []
        guard !acknowledgedDraw.isEmpty else { return }
        let entries = acknowledgedDraw
        acknowledgedDraw = []
        deletedCanvasHopDeferrals += 1
        // Once an Undo/Redo has put a canvas in Recently Deleted, the actions
        // still queued behind it are for a board nobody is looking at.
        var deletedHere = Set<UUID>()
        for entry in entries {
            if deletedHere.contains(entry.canvas) { continue }
            let result: DrawSaveResult
            switch entry.action {
            case .command(let command): result = store.perform(command, on: entry.canvas)
            case .undo: result = store.undo(on: entry.canvas)
            case .redo: result = store.redo(on: entry.canvas)
            }
            if case .saved(let delta) = result, delta.canvas.deletedAt != nil { deletedHere.insert(entry.canvas) }
            if canvasID == entry.canvas { apply(result, replacingEditorText: typingCommands.isEmpty) }
        }
        deletedCanvasHopDeferrals -= 1
        if externalSyncDeferred { syncExternalChanges() }
    }

    @discardableResult
    func perform(_ command: DrawCommand) -> DrawSaveResult {
        guard let canvasID else { return .unchanged }
        flushAcknowledgedDraw()
        flushTyping()
        syncExternalChanges()
        guard self.canvasID == canvasID else { return .unchanged }
        let result = store.perform(command, on: canvasID)
        apply(result)
        return result
    }

    /// A command for a canvas that may no longer be open (an image import
    /// that finished after a switch): it goes to that canvas through the
    /// store, and a failure shows rather than vanishing.
    @discardableResult
    func perform(_ command: DrawCommand, on id: UUID) -> DrawSaveResult {
        flushAcknowledgedDraw()
        guard id != canvasID else { return perform(command) }
        let result = store.perform(command, on: id)
        switch result {
        case .unchanged:
            break
        case .saved:
            markThumbnailDirty(id)
            renderThumbnail(id, objects: (try? store.open(id).objects) ?? [])
        case .retry(let message), .held(let message):
            markThumbnailDirty(id)
            if store.pendingEdits[id] != nil {
                dismissedSaveProblem = nil
            } else {
                report(message.isEmpty ? String(localized: "The image couldn’t be added to its canvas.") : message)
            }
        }
        objectWillChange.send()
        return result
    }

    func importStarted(_ token: UUID, _ task: Task<Void, Never>) {
        imports[token] = task
        pendingImport = task
    }

    func importFinished(_ token: UUID) {
        imports[token] = nil
        if imports.isEmpty { quitImportPending = false }
    }

    /// Folds a store result into the open canvas's objects.
    func apply(_ result: DrawSaveResult, replacingEditorText: Bool = false) {
        switch result {
        case .unchanged:
            return
        case .saved(let delta):
            guard delta.canvas.id == canvasID else { return }
            // A delta includes only this command. If some earlier external
            // revision was missed, read the complete snapshot before claiming
            // the store revision has been incorporated.
            if delta.revision != appliedRevision &+ 1 {
                externalSyncDeferred = true
                syncExternalChanges()
                return
            }
            // The canvas lifecycle is part of this revision. Navigate while
            // the current store revision is still unseen, through the same
            // path used for external deletion (including the last canvas).
            if delta.canvas.deletedAt != nil {
                externalSyncDeferred = true
                syncExternalChanges()
                return
            }
            canvasName = delta.canvas.name
            if delta.removedIDs.isEmpty, delta.upserted.count == 1,
               let changed = delta.upserted.first,
               let index = objects.firstIndex(where: { $0.id == changed.id }),
               objects[index].zIndex == changed.zIndex {
                // The common text/shape update keeps its layer: update that
                // slot without reconstructing and sorting the entire canvas.
                objects[index] = changed
            } else {
                var byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
                for id in delta.removedIDs { byID[id] = nil }
                for object in delta.upserted { byID[object.id] = object }
                objects = byID.values.sorted(by: Self.order)
            }
            lastError = nil
        case .retry(let message), .held(let message):
            // The store keeps the visible after-draft.
            if let canvasID, let pending = store.pendingEdits[canvasID] {
                objects = pending.objects.filter { $0.deletedAt == nil }.sorted(by: Self.order)
            }
            lastError = message
            dismissedSaveProblem = nil
        }
        appliedRevision = store.revision
        afterContentChange(replacingEditorText: replacingEditorText)
    }

    private func afterContentChange(replacingEditorText: Bool) {
        let ids = Set(objects.map(\.id))
        let kept = selection.filter { ids.contains($0) }
        if kept != selection { selection = kept }
        if kept.isEmpty { isSelectionStyleOpen = false }
        if replacingEditorText, var edit = editing {
            if let object = object(edit.id), case .text(let text) = object.content {
                edit.text = text
                edit.style = object.style
                edit.origin = CGPoint(x: object.frame.x, y: object.frame.y)
                edit.width = object.textWidth.map { CGFloat($0) }
                edit.scale = CGFloat(object.textScale ?? 1)
                edit.stored = true
                edit.retainedObject = object
            } else {
                edit.text = ""
                edit.stored = false
            }
            editing = edit
            board?.drawEditingChanged(replacingText: true)
        }
        refreshHistory()
        contentRevision += 1
        selectionRevision += 1
        thumbnailNeeded()
        updateLost()
        board?.drawContentChanged()
        board?.drawSelectionChanged()
    }

    private func refreshHistory() {
        guard let canvasID else { canUndo = false; canRedo = false; return }
        if !acknowledgedDraw.isEmpty, let acknowledgedUndoChanges {
            canUndo = !acknowledgedUndoChanges.isEmpty
            canRedo = !acknowledgedRedoChanges.isEmpty
            return
        }
        let undoable = store.canUndo(on: canvasID), redoable = store.canRedo(on: canvasID)
        if canUndo != undoable { canUndo = undoable }
        if canRedo != redoable { canRedo = redoable }
    }

    static func order(_ lhs: DrawObject, _ rhs: DrawObject) -> Bool {
        lhs.zIndex == rhs.zIndex ? lhs.id.uuidString < rhs.id.uuidString : lhs.zIndex < rhs.zIndex
    }

    /// Changes made by someone else (the library's Rename, Delete or a
    /// restore): the open canvas is read again, outside any input handler.
    private func observeStore() {
        withObservationTracking { _ = store.revision } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncExternalChanges()
                    self.observeStore()
                }
            }
        }
    }

    func syncExternalChanges() {
        guard let canvasID else { return }
        if !acknowledgedDraw.isEmpty {
            if store.revision != appliedRevision { externalSyncDeferred = true }
            return
        }
        if !typingCommands.isEmpty {
            if store.revision != appliedRevision { externalSyncDeferred = true }
            return
        }
        if live != nil {
            if store.revision != appliedRevision { externalSyncDeferred = true }
            return
        }
        guard externalSyncDeferred || store.revision != appliedRevision else { return }
        guard let snapshot = try? store.open(canvasID) else { return }
        if snapshot.canvas.deletedAt != nil, deletedCanvasHopDeferrals > 0 {
            externalSyncDeferred = true
            return
        }
        externalSyncDeferred = false
        appliedRevision = store.revision
        if snapshot.canvas.deletedAt != nil {
            if let next = try? store.library().first { open(next.id) } else { newCanvas() }
            return
        }
        canvasName = confirmedName(in: snapshot)
        let fresh = snapshot.objects.filter { $0.deletedAt == nil }
        // Editing text is checkpointed in bounded bursts. If an agent
        // replaces/deletes that text, stop the old editor rather than letting
        // its next keystroke restore stale content. The previous text remains
        // in the store's undo history for recovery.
        let editorConflicts = editing.map { edit in
            guard let updated = fresh.first(where: { $0.id == edit.id }),
                  case .text(let text) = updated.content else { return true }
            return text != edit.text
        } ?? false
        guard fresh != objects else { refreshHistory(); return }
        objects = fresh
        if editorConflicts { endEditing() }
        afterContentChange(replacingEditorText: editing != nil)
    }

    /// The store keeps an optimistic after-draft for recovery. While it is
    /// unsettled, the title shown outside the editor must use saved metadata.
    private func confirmedName(in snapshot: DrawSnapshot) -> String {
        guard store.pendingEdits[snapshot.canvas.id] != nil else { return snapshot.canvas.name }
        return ((try? store.library()) ?? []).first(where: { $0.id == snapshot.canvas.id })?.name
            ?? snapshot.canvas.name // An unpublished canvas's chosen draft name has no saved row yet.
    }
}
