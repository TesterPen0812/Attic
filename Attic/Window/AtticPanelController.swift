import AppKit
import Combine
import QuartzCore
import SwiftData
import SwiftUI

enum PanelWorkAreaEvent: Equatable {
    case screenParametersChanged
    case applicationActivated
    case applicationDeactivated
}

enum PanelWorkAreaEvents {
    static func publisher(
        center: NotificationCenter = .default
    ) -> AnyPublisher<PanelWorkAreaEvent, Never> {
        Publishers.Merge3(
            center.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .map { _ in PanelWorkAreaEvent.screenParametersChanged },
            center.publisher(for: NSApplication.didBecomeActiveNotification)
                .map { _ in PanelWorkAreaEvent.applicationActivated },
            center.publisher(for: NSApplication.didResignActiveNotification)
                .map { _ in PanelWorkAreaEvent.applicationDeactivated }
        )
        .eraseToAnyPublisher()
    }
}

struct PanelResizePersistenceState {
    private var wasTemporarilyClamped = false

    mutating func beginUserResize() {
        wasTemporarilyClamped = false
    }

    mutating func recordTemporaryWorkAreaClamp() {
        wasTemporarilyClamped = true
    }

    mutating func finishUserResize(at finalSize: CGSize) -> CGSize? {
        defer { wasTemporarilyClamped = false }
        guard !wasTemporarilyClamped else { return nil }
        return PanelGeometry.clampedPanelSize(finalSize)
    }
}

private struct PanelWorkAreaSnapshot {
    let visibleFrame: CGRect
}

enum PanelHideCompletion: Equatable {
    case hidden
    case superseded
}

/// A stationary window can finish its AppKit frame animation before the live
/// subtree finishes collapsing. Order-out must wait for both, exactly once.
@MainActor
final class PanelMotionCompletionBarrier {
    private var frameFinished = false
    private var presentationFinished = false
    private var completion: (() -> Void)?

    init(completion: @escaping () -> Void) { self.completion = completion }

    func finishFrame() { frameFinished = true; finishIfReady() }
    func finishPresentation() { presentationFinished = true; finishIfReady() }

    private func finishIfReady() {
        guard frameFinished, presentationFinished, let completion else { return }
        self.completion = nil
        completion()
    }
}

struct PanelVisibilityTransitionState {
    private(set) var generation = 0
    private var transitionCancellation: (() -> Void)?
    private var pendingHide: (
        generation: Int,
        completion: (PanelHideCompletion) -> Void
    )?

    mutating func invalidatePendingTransition() {
        generation += 1
        cancelTransition()
        resolvePendingHide(.superseded)
    }

    mutating func beginTransition(onSuperseded: (() -> Void)? = nil) -> Int {
        generation += 1
        cancelTransition()
        resolvePendingHide(.superseded)
        transitionCancellation = onSuperseded
        return generation
    }

    @discardableResult
    mutating func completeTransition(_ candidate: Int) -> Bool {
        guard ownsCompletion(candidate) else { return false }
        transitionCancellation = nil
        return true
    }

    private mutating func cancelTransition() {
        let cancellation = transitionCancellation
        transitionCancellation = nil
        cancellation?()
    }

    mutating func beginHideTransition(
        completion: @escaping (PanelHideCompletion) -> Void
    ) -> Int {
        let generation = beginTransition()
        pendingHide = (generation, completion)
        return generation
    }

    @discardableResult
    mutating func completeHideTransition(_ candidate: Int) -> Bool {
        guard ownsCompletion(candidate), pendingHide?.generation == candidate else {
            return false
        }
        resolvePendingHide(.hidden)
        return true
    }

    func ownsCompletion(_ candidate: Int) -> Bool {
        candidate == generation
    }

    private mutating func resolvePendingHide(_ completion: PanelHideCompletion) {
        guard let pendingHide else { return }
        self.pendingHide = nil
        pendingHide.completion(completion)
    }
}

enum PanelHideRejection: Equatable {
    case draftFlushFailed
    case missingUsableScreen
}

enum PanelHideRequestResult: Equatable {
    case accepted
    case rejected(PanelHideRejection)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

@MainActor
final class AtticPanelController: NSObject, NSWindowDelegate {
    private let panel: AtticPanel
    var isVisibleForPerformanceProbe: Bool { panel.isVisible }
    /// Whether the panel is on screen (a page switch then animates).
    var isPanelVisible: Bool { panel.isVisible }
    #if DEBUG
    /// The motion bench: how far the panel is collapsed now (0 shown, 1
    /// hidden), whichever animation draws it.
    var displayedProgressForProbe: Double {
        guard let container = contentContainer else { return 0 }
        if container.alternateMode != nil { return container.alternateProgress }
        return Double((1 - container.presentationTransform.m11) / (1 - PanelCollapseGeometry.collapsedScale))
    }
    /// The motion bench: whether the panel takes clicks and keys right now.
    var acceptsInputForProbe: Bool { contentContainer?.allowsContentInteraction == true && panel.isKeyWindow }
    /// The motion bench: what starting the last hide animation cost (ms).
    var alternateBeginCostForProbe: Double { contentContainer?.lastAlternateBeginMilliseconds ?? 0 }
    #endif
    /// Tests: the panel's window, to send it a swipe as the system does.
    var panelForTesting: AtticPanel { panel }
    private(set) var performanceVisibilityChanges = 0
    private let hostingView: AtticPanelHostingView
    private let store: TaskStore
    private let noteStore: NoteStore
    private let canvasSession: CanvasSession
    private let noteDraft: NoteDraftController
    private let chromeInteractionState: PanelChromeInteractionState
    private let settings: AppSettings
    private let uiState: PanelUIState
    /// The panel's Undo toast; dismissed whenever the panel hides.
    let toasts: PanelToastCenter
    private var cancellables: Set<AnyCancellable> = []
    private var isShowing = false
    private var isPanelMotionActive = false
    private var isInteractiveDismissal = false
    private var interactiveSwipeStartProgress: CGFloat = 0
    /// The hide animation a swipe drives (nil: Slide),
    /// its recent progress for the release speed, and that release.
    private var swipeDraft: PanelHideAnimation?
    private var swipeSamples: [(time: CFTimeInterval, progress: Double)] = []
    private var pendingDraftRelease: Double?
    /// The running motion is a swipe's release (its close or spring-back),
    /// which a new swipe may take over; `nextMotionIsRelease` marks the
    /// motion about to start as one. Slide's runs on Core Animation, so
    /// `slideMotionRun` mirrors it for its speed.
    private var isReleaseMotionActive = false
    private var nextMotionIsRelease = false
    private var slideMotionRun: PanelHideMotionRun?
    /// A takeover's speed carried into the swipe (`PanelSwipeTakeover.carry`),
    /// the swipe's last distance, and the timer that keeps the carry moving
    /// between the fingers' events.
    private var swipeCarry: (velocity: CGFloat, start: CFTimeInterval)?
    private var lastSwipeDistance: CGFloat = 0
    private var swipeCarryTimer: Timer?
    /// The next hide was asked for by a swipe: under Reduced motion it
    /// fades out rather than vanishing at once (owner, 2026-10-01).
    private var hideFadesWhenReduced = false
    private var needsResizeAfterShowing = false
    private var isLiveResizing = false
    private var resizePersistenceState = PanelResizePersistenceState()
    private var isPersistingManualSize = false
    private var isApplyingInteractiveCorner = false
    private var isWindowDragging = false
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var isDisplayingResizeCursor = false
    private var visibilityTransition = PanelVisibilityTransitionState()
    private(set) var currentScreen: NSScreen?
    private var lastUsableFrame: CGRect?
    private(set) var currentCorner: ScreenCorner = .topRight
    var onInteractiveHideCompleted: (() -> Void)?
    /// Where the pointer is, for the click-through hit test. Tests place it.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var isResamplingPassthrough = false
    /// O14-01: the panel became key under a press; its key look waits for
    /// the release.
    private var keyLookAwaitsRelease = false

    private var contentContainer: AtticPanelContentContainer? {
        panel.contentView as? AtticPanelContentContainer
    }

    init(
        store: TaskStore,
        noteStore: NoteStore,
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        settings: AppSettings,
        uiState: PanelUIState,
        tasksMemory: TasksPageMemory? = nil
    ) {
        self.store = store
        self.noteStore = noteStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.settings = settings
        self.uiState = uiState

        let initialSize = PanelGeometry.clampedPanelSize(
            CGSize(width: settings.panelContentSize, height: settings.panelHeight)
        )
        uiState.updatePanelSize(initialSize)
        let chromeInteractionState = PanelChromeInteractionState()
        self.chromeInteractionState = chromeInteractionState
        let toasts = PanelToastCenter()
        self.toasts = toasts
        panel = AtticPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        hostingView = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store,
                noteStore: noteStore,
                canvasSession: canvasSession,
                noteDraft: noteDraft,
                chromeInteractionState: chromeInteractionState,
                uiState: uiState,
                settings: settings,
                toasts: toasts,
                // The Tasks page remembers its page and views (L7).
                tasksPageState: TasksPageState(memory: tasksMemory)
            ),
            panelCornerRadius: settings.panelCornerSize,
            dockedCorner: settings.corner,
            chromeInteractionState: chromeInteractionState
        )

        super.init()
        configurePanel()
        bindContentSize()
        uiState.$dockingPreviewCorner.sink { [weak self] corner in
            self?.updateDockingIndicator(corner: corner)
        }.store(in: &cancellables)
        // Saved data may change what the panel shows, hidden or not: a
        // snapshot taken before it is stale.
        NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.contentContainer?.noteContentMayChange()
                self?.scheduleIdlePrepare()
            }
            .store(in: &cancellables)
        // Genie's shader compiles off the main thread before its first use.
        settings.$hideAnimation.sink { [weak self] mode in
            if mode.usesGenieMesh {
                PanelGenieRenderer.shared.prewarm()
                PanelGenieView.prewarmImageWork()
            }
            DispatchQueue.main.async { self?.scheduleIdlePrepare() }
        }.store(in: &cancellables)
    }

    private var dockingIndicator: NSPanel?
    private var dockingIndicatorCorner: ScreenCorner?

    private func updateDockingIndicator(corner: ScreenCorner?, frame: CGRect? = nil) {
        guard let corner else { dockingIndicator?.orderOut(nil); return }
        let frame = frame ?? panel.visibleContentFrame
        guard let screen = bestScreen(for: frame) else { return }
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let proposed = CGRect(x: right ? frame.maxX + 8 : frame.minX - 36,
                              y: top ? frame.maxY - 28 : frame.minY, width: 28, height: 28)
        let target = PanelGeometry.avoidingOverlap(proposed, occupied: [frame],
            within: TestPresentationPolicy.placementFrame(screen.visibleFrame).insetBy(dx: 4, dy: 4), gap: 8)
        let indicator = dockingIndicator ?? NSPanel(contentRect: target,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicator.isOpaque = false
        indicator.backgroundColor = .clear
        indicator.ignoresMouseEvents = true
        indicator.hasShadow = false
        indicator.level = .floating
        let symbol = top ? (right ? "arrow.up.right" : "arrow.up.left") : (right ? "arrow.down.right" : "arrow.down.left")
        if dockingIndicatorCorner != corner || indicator.contentView == nil {
            indicator.contentView = NSHostingView(rootView:
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).background(.regularMaterial, in: Circle())
                    .accessibilityHidden(true))
            dockingIndicatorCorner = corner
        }
        indicator.setFrame(target, display: true)
        if !indicator.isVisible { indicator.orderFrontRegardless() }
        dockingIndicator = indicator
    }

    deinit {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
    }


    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard panel.isVisible, panel.frame.contains(point) else { return false }
        let localPoint = CGPoint(
            x: point.x - panel.visibleContentFrame.minX,
            y: point.y - panel.visibleContentFrame.minY
        )
        let bounds = CGRect(origin: .zero, size: panel.visibleContentFrame.size)
        return Squircle.contains(
            localPoint,
            in: bounds,
            cornerRadius: settings.panelCornerSize,
            exponent: AtticStyle.panelSquircleExponent
        ) || AtticPanelResizePolicy.resizeEdges(
            at: localPoint, in: bounds, cornerRadius: settings.panelCornerSize,
            dockedAt: currentCorner, acquisitionInset: panel.resizePerimeter
        ) != nil
    }

    func updateMousePassthrough(at point: CGPoint) {
        // Dock auto-hide/orientation changes can alter visibleFrame without a
        // display-configuration notification. Reconcile on existing pointer
        // activity; no additional polling or rendering loop is needed.
        if panel.isVisible, !isLiveResizing, !isWindowDragging,
           let screen = panel.screen ?? currentScreen,
           lastUsableFrame != TestPresentationPolicy.placementFrame(screen.visibleFrame) {
            recoverPanelInsideUsableArea(preferredScreen: screen)
        }
        guard !isLiveResizing else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let isInsideRectangularFrame = panel.isVisible && panel.frame.contains(point)
        let localPoint = CGPoint(
            x: point.x - panel.visibleContentFrame.minX,
            y: point.y - panel.visibleContentFrame.minY
        )
        let acquisitionEdges = isInsideRectangularFrame
            ? AtticPanelResizePolicy.resizeEdges(
                    at: localPoint,
                    in: CGRect(origin: .zero, size: panel.visibleContentFrame.size),
                    cornerRadius: settings.panelCornerSize,
                    dockedAt: currentCorner,
                    acquisitionInset: panel.resizePerimeter
            )
            : nil
        let shouldIgnoreMouseEvents = isInsideRectangularFrame
            && !containsScreenPoint(point)
            && acquisitionEdges == nil
        if panel.ignoresMouseEvents != shouldIgnoreMouseEvents {
            panel.ignoresMouseEvents = shouldIgnoreMouseEvents
            panel.invalidateCursorRects(for: hostingView)
        }
        if let acquisitionEdges {
            hostingView.displayResizeCursor(for: acquisitionEdges)
            isDisplayingResizeCursor = true
        } else if isDisplayingResizeCursor {
            isDisplayingResizeCursor = false
            NSCursor.arrow.set()
            panel.invalidateCursorRects(for: hostingView)
        }
    }

    /// Orders the panel front at `corner`. Returns false (and shows
    /// nothing) when the screen has no usable area for it.
    @discardableResult
    func show(on screen: NSScreen, corner: ScreenCorner, makeKey: Bool = false) -> Bool {
        cancelPageRelease()
        // Build the pages now, before the first frame is shown, so the panel
        // never slides in empty; the reveal signpost includes it.
        buildPagesIfNeeded()
        defer { buildKeptPagesAfterReveal() }
        // A reveal always supersedes an in-flight hide, even when its frame
        // already matches. This prevents that hide's completion from ordering
        // out a panel the user has just asked to see again.
        clearInteractiveDismissal()
        panel.cancelTrackpadSwipe()
        stopPanelMotion()
        let frameBeforeWorkAreaRefresh = panel.visibleContentFrame
        guard let workArea = refreshCurrentWorkArea(preferredScreen: screen) else {
            PerformanceSignposts.cancelReveal()
            PerformanceSignposts.cancelPageSwitch()
            return false
        }
        if uiState.selectedSection.isNotes { noteDraft.pages.present() }
        let visibleFrame = workArea.visibleFrame
        let priorFrame = panel.visibleContentFrame
        currentCorner = corner
        panel.trackpadDismissCorner = corner
        hostingView.dockedCorner = corner
        startPointerPassthroughMonitoring()

        if isLiveResizing {
            let safeFrame = PanelGeometry.constrainedFrame(
                panel.visibleContentFrame,
                to: visibleFrame
            )
            if abs(safeFrame.width - frameBeforeWorkAreaRefresh.width) >= 0.5
                || abs(safeFrame.height - frameBeforeWorkAreaRefresh.height) >= 0.5 {
                resizePersistenceState.recordTemporaryWorkAreaClamp()
            }
            if !framesMatch(panel.visibleContentFrame, safeFrame) {
                panel.setVisibleContentFrame(safeFrame, display: panel.isVisible)
                uiState.updatePanelSize(safeFrame.size)
            }
            if makeKey { panel.makeKey() }
            panel.orderFrontRegardless()
            resamplePointerPassthrough()
            animateShow(to: safeFrame)
            PerformanceSignposts.panelOrderedFront()
            return true
        }

        let finalFrame = frame(in: visibleFrame, corner: corner)

        if panel.isVisible {
            let localPriorFrame = PanelGeometry.constrainedFrame(priorFrame, to: visibleFrame)
            let mustEstablishOnTargetDisplay = !framesMatch(priorFrame, localPriorFrame)

            if mustEstablishOnTargetDisplay {
                panel.setVisibleContentFrame(finalFrame, display: true)
                prepareCollapsedPresentation(corner: corner)
            }

            if makeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }

            resamplePointerPassthrough()
            animateShow(to: finalFrame)
            PerformanceSignposts.panelOrderedFront()
            return true
        }

        panel.setVisibleContentFrame(finalFrame, display: true)
        prepareCollapsedPresentation(corner: corner)
        panel.alphaValue = 1

        performanceVisibilityChanges += 1

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        // The pointer monitor started before the panel was on screen, so
        // its first hit test could not see the corner wedges or the shadow
        // margin; a pointer resting there sends no event to correct it.
        resamplePointerPassthrough()
        animateShow(to: finalFrame)
        PerformanceSignposts.panelOrderedFront()
        // A reveal: the panel was hidden and is now on screen.
        uiState.panelDidReveal()
        return true
    }

    private func animateShow(to finalFrame: CGRect, spring: AtticMotionSpring? = nil) {
        let generation = visibilityTransition.beginTransition()
        isShowing = true
        animatePanel(to: finalFrame, collapseProgress: 0,
                     duration: settings.hideMotionDuration(.slide, hiding: false), spring: spring,
                     reducedFade: spring != nil) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.visibilityTransition.completeTransition(generation) else { return }
                self.isShowing = false
                self.scheduleIdlePrepare()
                if self.needsResizeAfterShowing {
                    self.needsResizeAfterShowing = false
                    self.resizeAndReanchor()
                }
                self.resamplePointerPassthrough()
            }
        }
    }

    @discardableResult
    func requestHide(
        completion: @escaping (PanelHideCompletion) -> Void
    ) -> PanelHideRequestResult {
        guard panel.isVisible else {
            stopPointerPassthroughMonitoring()
            completion(.hidden)
            return .accepted
        }
        guard let screen = panel.screen ?? currentScreen else {
            return .rejected(.missingUsableScreen)
        }
        guard noteDraft.prepareToLeave(.hide) else {
            return .rejected(.draftFlushFailed)
        }
        clearInteractiveDismissal()
        stopPanelMotion()
        panel.cancelTrackpadSwipe()

        // Destructive/transient presentation state changes only after the
        // persistence boundary accepts the hide transaction.
        hostingView.cancelActiveInteraction(reason: .explicitHide)
        canvasSession.interruptActiveInteraction()
        uiState.isCanvasConfirmationPresented = false
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
        uiState.setInteractionLock(.windowResize, isActive: false)
        let generation = visibilityTransition.beginHideTransition(completion: completion)
        isShowing = false
        needsResizeAfterShowing = false
        let safeFrame = PanelGeometry.constrainedFrame(panel.visibleContentFrame, to: TestPresentationPolicy.placementFrame(screen.visibleFrame))
        if !framesMatch(panel.visibleContentFrame, safeFrame) {
            panel.setVisibleContentFrame(safeFrame, display: true)
        }
        // A released window throw can start away from its attached corner.
        // Move its fixed-size native frame back while the same live subtree
        // collapses, so every hide reason converges on the actual dock anchor.
        let targetFrame = PanelGeometry.panelFrame(
            in: TestPresentationPolicy.placementFrame(screen.visibleFrame), size: safeFrame.size, corner: currentCorner
        )
        let reducedFade = hideFadesWhenReduced
        hideFadesWhenReduced = false
        animatePanel(to: targetFrame, collapseProgress: 1,
                     duration: settings.hideMotionDuration(.slide, hiding: true), reducedFade: reducedFade) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.panel.orderOut(nil)
                self.contentContainer?.resetReducedFade()
                self.performanceVisibilityChanges += 1
                self.uiState.panelDidHide()
                self.panel.alphaValue = 1
                self.stopPointerPassthroughMonitoring()
                self.toasts.dismiss()
                self.schedulePageRelease()
                self.visibilityTransition.completeHideTransition(generation)
            }
        }
        return .accepted
    }

    private func configurePanel() {
        let visibleFrame = panel.frame
        panel.resizePerimeter = AtticPanelResizePolicy.outsideGripThickness
        panel.surfaceMargin = AtticStyle.panelElevationMargin
        panel.setVisibleContentFrame(visibleFrame, display: false)
        panel.contentView = AtticPanelContentContainer(
            hostingView: hostingView,
            visibleSize: visibleFrame.size,
            perimeter: panel.nativeMargin
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = AtticStyle.panelUsesSystemShadow
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        AtticPanelInteractionPolicy.configure(panel)
        AtticPanelResizePolicy.configure(panel)
        panel.onAccessibilityResizeRequest = { [weak self] requestedSize in
            self?.applyAccessibilityResizeRequest(requestedSize)
        }
        panel.onAccessibilityMoveRequest = { [weak self] requestedFrame in
            self?.applyAccessibilityMoveRequest(requestedFrame)
        }
        panel.onTrackpadDismissRequest = { [weak self] in
            guard let self else { return }
            // A pinned panel closes too (owner, 2026-10-02) and stays pinned:
            // the hide completes through the hover monitor's
            // `forceHidden(untilHotspotExit:)`, so it neither re-shows at
            // once nor loses its pin.
            self.hideFadesWhenReduced = true
            self.captureSwipeRelease()
            self.nextMotionIsRelease = true
            let accepted = self.requestInteractiveHide().isAccepted
            self.nextMotionIsRelease = false
            if !accepted {
                self.hideFadesWhenReduced = false
                self.cancelInteractiveDismissal()
            }
        }
        panel.onContentMayChange = { [weak self] hoverOnly in
            self?.contentContainer?.noteContentMayChange(hoverOnly: hoverOnly)
            self?.scheduleIdlePrepare()
        }
        panel.onTrackpadDismissProgress = { [weak self] distance in
            self?.updateInteractiveDismissal(distance: distance)
        }
        panel.onTrackpadDismissCancelled = { [weak self] in
            self?.cancelInteractiveDismissal()
        }
        // Esc with nothing left to close hides the panel, as a swipe does;
        // the corner then needs the pointer to leave before it reveals again.
        panel.onUnhandledEscape = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.requestInteractiveHide()
        }
        // ⌘Z with the keyboard nowhere in a page (after clicking the pin,
        // say): the Tasks history, the one the Undo toast names.
        panel.onUnhandledUndo = { [weak self] redo in
            guard let self, self.uiState.selectedSection.isTaskBased, let library = self.store.commandLibrary else { return }
            _ = redo ? library.redo(in: .tasks) : library.undo(in: .tasks)
        }
        panel.canPerformUnhandledUndo = { [weak self] redo in
            guard let self, self.uiState.selectedSection.isTaskBased, let library = self.store.commandLibrary else { return false }
            return redo ? library.undo.canRedo(in: .tasks) : library.undo.canUndo(in: .tasks)
        }
        panel.onPressEnded = { [weak self] in self?.pressEnded() }
        panel.onDirectContentInteraction = { [weak self] in
            guard let self, self.isShowing || self.isInteractiveDismissal else { return }
            self.clearInteractiveDismissal()
            self.stopPanelMotion()
            self.restoreFullPresentation()
        }
        panel.trackpadSwipeTakeover = { [weak self] in self?.releaseMotionTakeover() }
        panel.canBeginTrackpadSwipe = { [weak self] event in
            // A swipe's own release motion can be taken over; any other
            // motion (a timed hide or reveal, a dock) cannot.
            guard let self, !self.isPanelMotionActive || self.releaseMotionTakeover() != nil else { return false }
            let blockers: Set<PanelInteractionLockReason> = [
                .windowMove, .windowResize, .menuTracking, .blockingSave, .canvasConfirmation,
                .notesImport, .taskEditing
            ]
            // Over the header and the controls too (owner, 2026-10-01):
            // a swipe has no other job there. Controls that scroll sideways
            // keep theirs (`contentOwnsHorizontalScrolling`).
            return self.uiState.interactionLockReasons.isDisjoint(with: blockers)
        }
        hostingView.onLiveResizeBegan = { [weak self] in
            self?.beginLiveResize()
        }
        hostingView.onLiveResizeChanged = { [weak self] size in
            self?.uiState.updatePanelSize(size)
        }
        hostingView.onLiveResizeEnded = { [weak self] size in
            self?.endLiveResize(at: size)
        }
        hostingView.onWindowDragBegan = { [weak self] in
            self?.beginWindowDrag()
        }
        hostingView.onWindowDragChanged = { [weak self] frame, pointer in
            self?.updateWindowDrag(frame: frame, pointer: pointer) ?? frame
        }
        hostingView.onWindowDragEnded = { [weak self] frame, pointer, velocity, translation in
            self?.endWindowDrag(
                frame: frame,
                pointer: pointer,
                velocity: velocity,
                translation: translation
            )
        }
        hostingView.onInteractionCancelled = { [weak self] cancellation, frame in
            self?.handleInteractionCancellation(cancellation, frame: frame)
        }
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func bindContentSize() {
        uiState.$selectedSection
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                panel.cancelTrackpadSwipe()
                // A page kept built behind the new one must not keep the
                // keyboard (a field in it would take what is typed on the
                // page now showing). The new page asks for focus itself.
                if let responder = panel.firstResponder as? NSView, responder !== hostingView,
                   responder.isDescendant(of: hostingView) {
                    panel.makeFirstResponder(nil)
                }
            }
            .store(in: &cancellables)

        settings.$corner
            .sink { [weak self] corner in
                guard let self else { return }
                if !self.isApplyingInteractiveCorner {
                    // A new attached corner invalidates the old layer-space
                    // anchor before either routing or layout can observe it.
                    self.settlePresentationBeforeReanchoring()
                }
                self.currentCorner = corner
                self.panel.trackpadDismissCorner = corner
                self.hostingView.dockedCorner = corner
                guard !self.isApplyingInteractiveCorner else { return }
                self.resizeAndReanchor()
            }
            .store(in: &cancellables)

        PanelWorkAreaEvents.publisher()
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .screenParametersChanged:
                    panel.cancelTrackpadSwipe()
                    hostingView.cancelActiveInteraction(reason: .screenChanged)
                    recoverPanelInsideUsableArea()
                case .applicationActivated:
                    recoverPanelInsideUsableArea(preservingPlacement: true)
                case .applicationDeactivated:
                    panel.cancelTrackpadSwipe()
                    hostingView.cancelActiveInteraction(reason: .applicationDeactivated)
                }
            }
            .store(in: &cancellables)

        settings.$panelCornerSize
            .sink { [weak self] cornerRadius in
                self?.hostingView.panelCornerRadius = cornerRadius
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            settings.$panelContentSize.removeDuplicates(),
            settings.$panelHeight.removeDuplicates()
        )
            .sink { [weak self] width, height in
                guard let self, !self.isPersistingManualSize else { return }
                self.resizeAndReanchor(
                    to: CGSize(width: width, height: height)
                )
            }
            .store(in: &cancellables)
    }

    private func resizeAndReanchor(to configuredSize: CGSize? = nil) {
        guard !isLiveResizing, !panel.inLiveResize else { return }
        if isShowing {
            needsResizeAfterShowing = true
            return
        }
        settlePresentationBeforeReanchoring()
        guard let workArea = refreshCurrentWorkArea(preferredScreen: currentScreen) else {
            return
        }
        let targetFrame = frame(
            in: workArea.visibleFrame,
            corner: currentCorner,
            configuredSize: configuredSize
        )
        guard !framesMatch(panel.visibleContentFrame, targetFrame) else { return }
        panel.setVisibleContentFrame(targetFrame, display: panel.isVisible)
    }

    private func settlePresentationBeforeReanchoring() {
        clearInteractiveDismissal()
        panel.cancelTrackpadSwipe()
        stopPanelMotion()
        restoreFullPresentation()
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func frame(
        in visibleFrame: CGRect,
        corner: ScreenCorner,
        configuredSize: CGSize? = nil
    ) -> CGRect {
        PanelGeometry.workAreaPlacement(
            preferredSize: configuredSize
                ?? CGSize(width: settings.panelContentSize, height: settings.panelHeight),
            in: visibleFrame,
            corner: corner
        ).frame
    }

    private func updateResizeLimits(in visibleFrame: CGRect) {
        lastUsableFrame = visibleFrame
        AtticPanelResizePolicy.configure(
            panel,
            maximumSize: PanelGeometry.resizeMaximumSize(in: visibleFrame)
        )
    }

    private func applyAccessibilityResizeRequest(_ requestedSize: CGSize) {
        clearInteractiveDismissal()
        panel.cancelTrackpadSwipe()
        stopPanelMotion()
        restoreFullPresentation()
        guard let workArea = refreshCurrentWorkArea(
            preferredScreen: panel.screen ?? currentScreen
        ) else { return }
        let placement = PanelGeometry.workAreaPlacement(
            preferredSize: requestedSize,
            in: workArea.visibleFrame,
            corner: currentCorner
        )
        panel.setVisibleContentFrame(placement.frame, display: panel.isVisible)
        uiState.updatePanelSize(placement.frame.size)

        isPersistingManualSize = true
        settings.persistPanelSize(placement.preferredSize)
        isPersistingManualSize = false
    }

    private func applyAccessibilityMoveRequest(_ requestedFrame: CGRect) {
        clearInteractiveDismissal()
        panel.cancelTrackpadSwipe()
        stopPanelMotion()
        restoreFullPresentation()
        guard let screen = bestScreen(for: requestedFrame) ?? panel.screen ?? currentScreen else {
            return
        }
        guard let workArea = refreshCurrentWorkArea(preferredScreen: screen) else { return }
        let targetFrame = PanelGeometry.constrainedFrame(
            requestedFrame,
            to: workArea.visibleFrame
        )
        panel.setVisibleContentFrame(targetFrame, display: panel.isVisible)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        beginLiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSWindow else { return }
        uiState.updatePanelSize(((resizedPanel as? AtticPanel)?.visibleContentFrame ?? resizedPanel.frame).size)
        if !isPanelMotionActive { resamplePointerPassthrough() }
    }

    func windowDidMove(_ notification: Notification) {
        if !isPanelMotionActive { resamplePointerPassthrough() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSWindow else { return }
        endLiveResize(at: ((resizedPanel as? AtticPanel)?.visibleContentFrame ?? resizedPanel.frame).size)
    }

    private func beginLiveResize() {
        guard !isLiveResizing else { return }
        clearInteractiveDismissal()
        stopPanelMotion()
        panel.cancelTrackpadSwipe()
        restoreFullPresentation()
        panel.alphaValue = 1
        isShowing = false
        needsResizeAfterShowing = false
        resizePersistenceState.beginUserResize()
        isLiveResizing = true
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowResize, isActive: true)
        panel.ignoresMouseEvents = false
    }

    private func endLiveResize(at finalSize: CGSize) {
        guard isLiveResizing else { return }
        recoverPanelInsideUsableArea(preferredScreen: panel.screen ?? currentScreen)
        isLiveResizing = false
        let resolvedFinalSize = panel.visibleContentFrame.size
        uiState.updatePanelSize(resolvedFinalSize)

        // These publications are intentionally suppressed as frame commands:
        // AppKit has already reached this exact size and remains authoritative.
        if let preferredSize = resizePersistenceState.finishUserResize(at: resolvedFinalSize) {
            isPersistingManualSize = true
            settings.persistPanelSize(preferredSize)
            isPersistingManualSize = false
        }
        uiState.setInteractionLock(.windowResize, isActive: false)
    }

    private func beginWindowDrag() {
        clearInteractiveDismissal()
        stopPanelMotion()
        panel.cancelTrackpadSwipe()
        restoreFullPresentation()
        panel.alphaValue = 1
        isShowing = false
        needsResizeAfterShowing = false
        isWindowDragging = true
        uiState.setInteractionLock(.windowMove, isActive: true)
        panel.ignoresMouseEvents = false
    }

    private func handleInteractionCancellation(
        _ cancellation: PanelInteractionCancellation,
        frame: CGRect?
    ) {
        panel.ignoresMouseEvents = false
        switch cancellation.interaction {
        case .windowResize:
            endLiveResize(at: (frame ?? panel.visibleContentFrame).size)
        case .windowMove:
            isWindowDragging = false
            uiState.dockingPreviewCorner = nil
            uiState.setInteractionLock(.windowMove, isActive: false)
            guard cancellation.reason != .explicitHide,
                  cancellation.reason != .lostWindow else { return }
            recoverPanelInsideUsableArea(preferredScreen: panel.screen ?? currentScreen)
        }
    }

    private func updateWindowDrag(frame: CGRect, pointer: CGPoint) -> CGRect {
        guard let screen = screen(containing: pointer) ?? panel.screen ?? currentScreen else {
            return frame
        }
        let visibleFrame = TestPresentationPolicy.placementFrame(screen.visibleFrame)
        if currentScreen !== screen {
            currentScreen = screen
            updateResizeLimits(in: visibleFrame)
        }
        let constrainedFrame = PanelGeometry.constrainedFrame(
            frame,
            to: visibleFrame
        )
        let previewCorner = PanelDockingPolicy.nearestCorner(
            for: constrainedFrame,
            in: visibleFrame
        )
        if uiState.dockingPreviewCorner != previewCorner {
            uiState.dockingPreviewCorner = previewCorner
        }
        updateDockingIndicator(corner: previewCorner, frame: constrainedFrame)
        return constrainedFrame
    }

    private func endWindowDrag(
        frame: CGRect,
        pointer: CGPoint,
        velocity: CGPoint,
        translation: CGPoint
    ) {
        isWindowDragging = false
        guard let screen = screen(containing: pointer) ?? panel.screen ?? currentScreen else {
            uiState.dockingPreviewCorner = nil
            uiState.setInteractionLock(.windowMove, isActive: false)
            return
        }

        currentScreen = screen
        let visibleFrame = TestPresentationPolicy.placementFrame(screen.visibleFrame)
        updateResizeLimits(in: visibleFrame)
        let releaseAction = PanelDockingPolicy.releaseAction(
            velocity: velocity,
            translation: translation,
            attachedCorner: currentCorner,
            panelFrame: frame,
            in: visibleFrame
        )
        if releaseAction == .hide {
            uiState.dockingPreviewCorner = nil
            uiState.setInteractionLock(.windowMove, isActive: false)
            let result = requestInteractiveHide()
            if !result.isAccepted {
                animateDock(
                    on: screen,
                    to: currentCorner,
                    persistsCorner: false,
                    showsPreview: false
                )
            }
            return
        }

        guard case let .dock(corner) = releaseAction else { return }
        animateDock(
            on: screen,
            to: corner,
            persistsCorner: true,
            showsPreview: true
        )
    }

    @discardableResult
    private func requestInteractiveHide() -> PanelHideRequestResult {
        requestHide { [weak self] completion in
            guard completion == .hidden else { return }
            self?.onInteractiveHideCompleted?()
        }
    }

    private func updateInteractiveDismissal(distance: CGFloat) {
        guard panel.isVisible else { return }
        #if DEBUG
        let traceBegan = CACurrentMediaTime()
        var traced: CGFloat = -1
        defer {
            PanelSwipeTrace.events.append([traceBegan, panel.lastScrollEventTime, Double(distance), Double(traced),
                                           (CACurrentMediaTime() - traceBegan) * 1000])
        }
        #endif
        if !isInteractiveDismissal {
            // A swipe that takes over a release motion starts where that
            // motion had the panel, with its speed (owner, 2026-10-22).
            let takeover = panel.swipeTakeover
            stopPanelMotion()
            isInteractiveDismissal = true
            // Swoop and both Genies follow the
            // fingers themselves (Reduced keeps today's dimming pull).
            swipeDraft = nil
            swipeSamples = []
            if !AtticMotionPreference.reducesMotion, let container = contentContainer {
                let mode = container.alternateMode ?? settings.hideAnimation
                if mode != .slide { swipeDraft = mode }
            }
            if let takeover {
                interactiveSwipeStartProgress = min(1, max(0, takeover.progress))
                swipeCarry = takeover.velocity != 0 ? (takeover.velocity, CACurrentMediaTime()) : nil
            } else if swipeDraft != nil, let container = contentContainer {
                interactiveSwipeStartProgress = container.alternateMode == nil
                    ? 0 : CGFloat(min(1, max(0, container.alternateProgress)))
            } else {
                let scale = contentContainer?.presentationTransform.m11 ?? 1
                interactiveSwipeStartProgress = min(1, max(0,
                    (1 - scale) / (1 - PanelCollapseGeometry.collapsedScale)
                ))
            }
            uiState.setInteractionLock(.panelSwipe, isActive: true)
        }
        lastSwipeDistance = distance
        #if DEBUG
        traced = applyInteractiveDismissal(recordsSample: true)
        #else
        applyInteractiveDismissal(recordsSample: true)
        #endif
    }

    /// Puts the panel where the swipe has it: the fingers (a pull, from
    /// where the swipe started), plus a takeover's carried speed while it
    /// lasts. Returns that progress.
    @discardableResult
    private func applyInteractiveDismissal(recordsSample: Bool) -> CGFloat {
        let follow = PanelCollapseGeometry.followProgress(
            from: interactiveSwipeStartProgress, distance: lastSwipeDistance, panelWidth: panel.visibleContentFrame.width
        )
        var collapse = follow
        if let carry = swipeCarry {
            let elapsed = CACurrentMediaTime() - carry.start
            if PanelSwipeTakeover.carryHasEnded(velocity: carry.velocity, elapsed: elapsed) {
                swipeCarry = nil
                swipeCarryTimer?.invalidate()
                swipeCarryTimer = nil
            } else {
                collapse = min(1, max(0, follow + PanelSwipeTakeover.carry(velocity: carry.velocity, elapsed: elapsed)))
                // Between the fingers' events the carry still moves.
                if swipeCarryTimer == nil {
                    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.isInteractiveDismissal else { return }
                            self.applyInteractiveDismissal(recordsSample: false)
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    swipeCarryTimer = timer
                }
            }
        }
        contentContainer?.allowsContentInteraction = false
        if let draft = swipeDraft, let container = contentContainer {
            if recordsSample {
                // The fingers' speed is timed by the events' own times: after a
                // stall the main thread gets to them bunched (g6: release speed
                // 10% low after an 80 ms snapshot).
                let now = panel.lastScrollEventTime > 0 ? panel.lastScrollEventTime : CACurrentMediaTime()
                swipeSamples.append((now, Double(collapse)))
                swipeSamples.removeAll { now - $0.time > PanelTrackpadDismissTracker.velocityWindow }
            }
            container.dockedCornerForAlternate = currentCorner
            container.setAlternateProgress(draft, Double(collapse), corner: currentCorner, surface: genieSurface(for: draft))
            return collapse
        }
        contentContainer?.setCollapseProgress(
            collapse,
            corner: currentCorner,
            reduceMotion: AtticMotionPreference.reducesMotion
        )
        return collapse
    }

    /// A swipe's release motion still running, for a new swipe to take
    /// over: where it has the panel and how fast it goes. Not under Reduced
    /// motion (its fade has no position to pick up).
    private func releaseMotionTakeover() -> PanelSwipeTakeover? {
        guard isPanelMotionActive, isReleaseMotionActive, panel.isVisible,
              !AtticMotionPreference.reducesMotion, let container = contentContainer else { return nil }
        let progress: Double
        let velocity: Double
        if container.alternateMode != nil {
            progress = container.alternateProgress
            velocity = container.alternateVelocity
        } else {
            let scale = container.presentationTransform.m11
            progress = Double((1 - scale) / (1 - PanelCollapseGeometry.collapsedScale))
            velocity = slideMotionRun?.velocity(at: CACurrentMediaTime()) ?? 0
        }
        guard progress.isFinite, velocity.isFinite else { return nil }
        return PanelSwipeTakeover(
            progress: CGFloat(min(1, max(0, progress))),
            velocity: CGFloat(min(PanelHideMotionTuning.swipeMaxVelocity, max(-PanelHideMotionTuning.swipeMaxVelocity, velocity))),
            panelWidth: panel.visibleContentFrame.width
        )
    }

    /// The fingers' speed at release, in progress per second (the swipe's
    /// own window of recent movement), for the animation's spring.
    private func captureSwipeRelease() {
        #if DEBUG
        defer {
            PanelSwipeTrace.release = ["t": CACurrentMediaTime(), "velocity": pendingDraftRelease ?? -99,
                                       "progress": swipeSamples.last?.progress ?? -1]
        }
        #endif
        guard swipeDraft != nil else { pendingDraftRelease = nil; return }
        let limit = PanelHideMotionTuning.swipeMaxVelocity
        guard let first = swipeSamples.first, let last = swipeSamples.last,
              last.time - first.time > 1.0 / 240 else { pendingDraftRelease = 0; return }
        let velocity = (last.progress - first.progress) / (last.time - first.time)
        pendingDraftRelease = min(limit, max(-limit, velocity))
    }

    private func clearInteractiveDismissal() {
        isInteractiveDismissal = false
        swipeCarry = nil
        swipeCarryTimer?.invalidate()
        swipeCarryTimer = nil
        lastSwipeDistance = 0
        scheduleIdlePrepare()
        swipeDraft = nil
        swipeSamples = []
        interactiveSwipeStartProgress = 0
        uiState.setInteractionLock(.panelSwipe, isActive: false)
    }

    private func cancelInteractiveDismissal() {
        guard isInteractiveDismissal else { return }
        if pendingDraftRelease == nil { captureSwipeRelease() }
        clearInteractiveDismissal()
        stopPanelMotion()
        guard panel.isVisible else { restoreFullPresentation(); return }
        // Below the threshold it springs back with the feel's navigation
        // spring (Lively by default); under Reduced it fades back.
        nextMotionIsRelease = true
        animateShow(to: panel.visibleContentFrame, spring: AtticMotionTuning.current.slide)
        nextMotionIsRelease = false
    }

    private func restoreFullPresentation() {
        clearInteractiveDismissal()
        contentContainer?.setCollapseProgress(0, corner: currentCorner, reduceMotion: true)
        contentContainer?.allowsContentInteraction = true
    }

    private func animateDock(
        on screen: NSScreen,
        to corner: ScreenCorner,
        persistsCorner: Bool,
        showsPreview: Bool
    ) {
        stopPanelMotion()
        uiState.setInteractionLock(.windowMove, isActive: true)
        uiState.dockingPreviewCorner = showsPreview ? corner : nil

        if persistsCorner {
            currentCorner = corner
            panel.trackpadDismissCorner = corner
            hostingView.dockedCorner = corner
            isApplyingInteractiveCorner = true
            settings.corner = corner
            isApplyingInteractiveCorner = false
        }

        let visibleFrame = TestPresentationPolicy.placementFrame(screen.visibleFrame)
        updateResizeLimits(in: visibleFrame)
        let targetFrame = PanelGeometry.workAreaPlacement(
            preferredSize: CGSize(
                width: settings.panelContentSize,
                height: settings.panelHeight
            ),
            in: visibleFrame,
            corner: corner
        ).frame
        let generation = visibilityTransition.beginTransition(onSuperseded: { [weak self] in
            self?.uiState.dockingPreviewCorner = nil
            self?.uiState.setInteractionLock(.windowMove, isActive: false)
        })
        animatePanel(to: targetFrame, collapseProgress: 0, duration: 0.18) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.completeTransition(generation) else { return }
                self.uiState.updatePanelSize(self.panel.visibleContentFrame.size)
                self.uiState.dockingPreviewCorner = nil
                self.uiState.setInteractionLock(.windowMove, isActive: false)
            }
        }
    }

    /// Native layout remains full size. Only the live presentation subtree is
    /// transformed; no snapshot, opacity track, or per-frame SwiftUI layout is
    /// involved. Both animation paths are bounded and generation-owned.
    private func animatePanel(
        to frame: CGRect,
        collapseProgress: CGFloat,
        duration: TimeInterval,
        spring: AtticMotionSpring? = nil,
        reducedFade: Bool = false,
        completion: @escaping () -> Void
    ) {
        let generation = visibilityTransition.generation
        isPanelMotionActive = true
        isReleaseMotionActive = nextMotionIsRelease
        nextMotionIsRelease = false
        contentContainer?.catchesSwipeStarts = isReleaseMotionActive && !AtticMotionPreference.reducesMotion
        slideMotionRun = nil
        contentContainer?.allowsContentInteraction = false
        let reduceMotion = AtticMotionPreference.reducesMotion
        let currentScale = contentContainer?.presentationTransform.m11 ?? 1
        let targetScale = 1 - collapseProgress * (1 - PanelCollapseGeometry.collapsedScale)
        let remaining = min(1, abs(currentScale - targetScale) / (1 - PanelCollapseGeometry.collapsedScale))
        // Genie, Genie Classic or Swoop owns a hide from the full panel, and
        // the reveal or reversal that follows it.
        // A swipe's partly collapsed Slide keeps Slide.
        // A swipe's release (its speed) belongs to this motion only.
        let release = pendingDraftRelease
        pendingDraftRelease = nil
        let draft: PanelHideAnimation? = {
            guard let container = contentContainer else { return nil }
            // An animation that owns the presentation (a swipe following the
            // fingers, or its own motion) finishes or springs back as itself.
            if let active = container.alternateMode { return active }
            guard spring == nil, collapseProgress >= 1, settings.hideAnimation != .slide,
                  CATransform3DIsIdentity(container.presentationTransform) else { return nil }
            return settings.hideAnimation
        }()
        // A swipe's close or spring-back under Reduced motion fades; so
        // does every hide animation other than Slide.
        let fades = reduceMotion && (reducedFade || draft != nil || (spring == nil && settings.hideAnimation != .slide))
        if let draft, !reduceMotion, let container = contentContainer {
            let target = Double(collapseProgress)
            let current = container.alternateMode == nil ? 0 : container.alternateProgress
            let hiding = collapseProgress >= 1
            let base = settings.hideMotionDuration(draft, hiding: hiding)
            let left = min(1, abs(current - target))
            let timedDuration = left > 0.001 ? max(0.08, base * sqrt(left)) : base
            // After a swipe: a short spring into the corner from the fingers'
            // progress and speed, or the feel's spring back open. Otherwise
            // timed like Slide.
            let curve: PanelHideMotionCurve
            if hiding, let release {
                curve = .spring(PanelHideMotionTuning.swipeCloseSpring, velocity: release)
            } else if !hiding, let spring {
                curve = .spring(spring, velocity: release ?? 0)
            } else {
                curve = .timed(
                    duration: timedDuration,
                    timing: hiding ? PanelHideMotionTuning.hideTiming : PanelHideMotionTuning.showTiming
                )
            }
            // A reveal takes clicks and keys from its first frame.
            container.allowsContentInteraction = !hiding
            container.dockedCornerForAlternate = currentCorner
            let finishes = PanelMotionCompletionBarrier { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                    self.isPanelMotionActive = false
                    self.isReleaseMotionActive = false
                    self.contentContainer?.catchesSwipeStarts = false
                    self.contentContainer?.allowsContentInteraction = collapseProgress == 0
                    completion()
                }
            }
            let duration = container.animateAlternate(
                draft, to: target, corner: currentCorner, surface: genieSurface(for: draft), curve: curve
            ) {
                MainActor.assumeIsolated { finishes.finishPresentation() }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
                panel.animator().setFrame(panel.nativeFrame(forVisibleFrame: frame), display: true)
            } completionHandler: {
                MainActor.assumeIsolated { finishes.finishFrame() }
            }
            return
        }
        let duration = fades ? PanelCollapseGeometry.reducedFadeDuration
            : reduceMotion ? 0 : remaining > 0.001 ? max(0.08, duration * sqrt(remaining)) : duration
        let finishes = PanelMotionCompletionBarrier { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.isPanelMotionActive = false
                self.isReleaseMotionActive = false
                self.contentContainer?.catchesSwipeStarts = false
                self.slideMotionRun = nil
                self.contentContainer?.allowsContentInteraction = collapseProgress == 0
                completion()
            }
        }
        if !fades, !reduceMotion, duration > 0 {
            // Slide's motion, mirrored for its speed (a takeover reads it).
            let from = Double(1 - currentScale) / Double(1 - PanelCollapseGeometry.collapsedScale)
            let start = CACurrentMediaTime()
            slideMotionRun = spring.map {
                PanelHideMotionRun(from: from, to: Double(collapseProgress), start: start, spring: $0, velocity: 0)
            } ?? PanelHideMotionRun(from: from, to: Double(collapseProgress), start: start, duration: duration,
                                    timing: UnitBezier(0.22, 0.8, 0.28, 1))
        }
        contentContainer?.setCollapseProgress(
            collapseProgress, corner: currentCorner, reduceMotion: reduceMotion,
            duration: duration, spring: spring, fades: fades, completion: {
                MainActor.assumeIsolated { finishes.finishPresentation() }
            }
        )
        if contentContainer == nil { finishes.finishPresentation() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
            panel.animator().setFrame(panel.nativeFrame(forVisibleFrame: frame), display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                finishes.finishFrame()
            }
        }
    }

    /// A timed hide (the pointer has left) or reveal (it rests in the
    /// corner) will happen in `delay` unless something changes: Genie takes
    /// its snapshot shortly before, so the flight starts on its first frame.
    /// nil: none is due any more.
    func prepareForExpectedVisibilityChange(_ expected: (hiding: Bool, delay: TimeInterval)?) {
        let mode = settings.hideAnimation
        guard let (hiding, delay) = expected, mode.usesGenieMesh, !AtticMotionPreference.reducesMotion, delay > 0 else {
            expectedChangeWork?.cancel()
            expectedChangeWork = nil
            return
        }
        // Each pointer sample re-states the same deadline: keep its work.
        let due = CACurrentMediaTime() + delay
        if let expectedChange, expectedChange.hiding == hiding, abs(expectedChange.due - due) < 0.02,
           expectedChangeWork?.isCancelled == false { return }
        expectedChangeWork?.cancel()
        expectedChange = (hiding, due)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let container = self.contentContainer, !self.isInteractiveDismissal,
                  self.panel.isVisible == hiding, self.settings.hideAnimation == mode else { return }
            // The pointer has just left (or arrived in the corner): hover fresh.
            container.prepareAlternateSnapshot(mode, surface: self.genieSurface(for: mode), hoverFresh: true)
        }
        expectedChangeWork = work
        let lead = max(0, delay - PanelHideMotionTuning.geniePrepareLead)
        DispatchQueue.main.asyncAfter(deadline: .now() + lead, execute: work)
    }

    private var expectedChangeWork: DispatchWorkItem?
    private var idlePrepareWork: DispatchWorkItem?

    /// Genie: once the panel has been idle `genieIdlePrepareDelay`, prepare
    /// the snapshot a swipe or hide will start from, and keep it fresh
    /// while the panel stays open and idle. Anything that may change the
    /// panel calls this again.
    func scheduleIdlePrepare() {
        idlePrepareWork?.cancel()
        idlePrepareWork = nil
        let mode = settings.hideAnimation
        guard mode.usesGenieMesh, !AtticMotionPreference.reducesMotion else { return }
        let lifetime = PanelHideMotionTuning.genieIdlePreparedLifetime
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible, self.settings.hideAnimation == mode,
                  let container = self.contentContainer else { return }
            // A motion still running: try again once it is done.
            guard !self.isPanelMotionActive, !self.isInteractiveDismissal, container.alternateMode == nil else {
                self.scheduleIdlePrepare()
                return
            }
            container.prepareAlternateSnapshot(mode, surface: self.genieSurface(for: mode), lifetime: lifetime, hoverFresh: true)
            // Renewed before it lapses, while the panel stays open and idle.
            let renew = DispatchWorkItem { [weak self] in self?.scheduleIdlePrepare() }
            self.idlePrepareWork = renew
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime - 2, execute: renew)
        }
        idlePrepareWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelHideMotionTuning.genieIdlePrepareDelay, execute: work)
    }
    private var expectedChange: (hiding: Bool, due: CFTimeInterval)?

    /// Before a reveal from hidden: the presentation collapsed the way the
    /// chosen hide animation reveals from.
    private func prepareCollapsedPresentation(corner: ScreenCorner) {
        let mode = settings.hideAnimation
        guard mode != .slide, let container = contentContainer else {
            contentContainer?.setCollapseProgress(1, corner: corner, reduceMotion: false)
            return
        }
        if AtticMotionPreference.reducesMotion {
            // Reduced: the draft's reveal is a fade in from nothing.
            container.setCollapseProgress(1, corner: corner, reduceMotion: true, fades: true)
        } else {
            container.dockedCornerForAlternate = corner
            container.prepareAlternateCollapsed(mode, corner: corner, surface: genieSurface(for: mode))
        }
    }

    /// What a Genie snapshot stands on: the panel's own material, live,
    /// under the bent snapshot. Solid needs none.
    private func genieSurface(for mode: PanelHideAnimation) -> PanelGenieSurface? {
        guard mode.usesGenieMesh else { return nil }
        let dark = hostingView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let treatment = settings.panelSurfaceTreatment(
            colorScheme: dark ? .dark : .light,
            contrast: increaseContrast ? .increased : .standard,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        guard treatment.kind != .solid else { return PanelGenieSurface(live: nil, translucent: false) }
        // As `AtticPanelSurface.nativeSurfaceColorScheme`.
        let scheme: ColorScheme = treatment.usesShadeAsFoundation ? .light : treatment.appearance == .dark ? .dark : .light
        return PanelGenieSurface(
            live: PanelGenieLiveMaterial(
                kind: treatment.kind == .glass ? .glass : .frosted,
                colorScheme: scheme,
                cornerRadius: hostingView.panelCornerRadius
            ),
            translucent: true
        )
    }

    private func stopPanelMotion() {
        visibilityTransition.invalidatePendingTransition()
        contentContainer?.stopCollapseMotion()
        let currentFrame = panel.frame
        // NSAnimatablePropertyContainer documents a zero-duration animator
        // update as the way to stop an in-flight property animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(currentFrame, display: false)
        }
        isShowing = false
        isPanelMotionActive = false
        isReleaseMotionActive = false
        contentContainer?.catchesSwipeStarts = false
        slideMotionRun = nil
        needsResizeAfterShowing = false
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(point, TestPresentationPolicy.placementFrame($0.frame), false) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        let frame = TestPresentationPolicy.offscreenFrame(frame)
        let screens = NSScreen.screens
        let overlapCandidate = screens
            .map { screen in
                let overlap = TestPresentationPolicy.placementFrame(screen.frame).intersection(frame)
                return (screen, max(0, overlap.width) * max(0, overlap.height))
            }
            .max { $0.1 < $1.1 }
        if let overlapCandidate, overlapCandidate.1 > 0 {
            return overlapCandidate.0
        }
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            squaredDistance(from: frameCenter, to: TestPresentationPolicy.placementFrame($0.frame))
                < squaredDistance(from: frameCenter, to: TestPresentationPolicy.placementFrame($1.frame))
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - nearestX
        let dy = point.y - nearestY
        return (dx * dx) + (dy * dy)
    }

    private func refreshCurrentWorkArea(
        preferredScreen: NSScreen? = nil
    ) -> PanelWorkAreaSnapshot? {
        guard let screen = preferredScreen
                ?? bestScreen(for: panel.visibleContentFrame)
                ?? panel.screen
                ?? currentScreen
                ?? NSScreen.main else { return nil }
        let visibleFrame = TestPresentationPolicy.placementFrame(screen.visibleFrame)
        currentScreen = screen
        updateResizeLimits(in: visibleFrame)
        return PanelWorkAreaSnapshot(visibleFrame: visibleFrame)
    }

    private func recoverPanelInsideUsableArea(
        preferredScreen: NSScreen? = nil,
        preservingPlacement: Bool = false
    ) {
        let frameBeforeWorkAreaRefresh = panel.visibleContentFrame
        guard let workArea = refreshCurrentWorkArea(
            preferredScreen: preferredScreen
        ) else { return }

        if isPanelMotionActive || isInteractiveDismissal {
            clearInteractiveDismissal()
            panel.cancelTrackpadSwipe()
            stopPanelMotion()
            isShowing = false
            needsResizeAfterShowing = false
            panel.alphaValue = 1
            restoreFullPresentation()
        }

        let targetFrame: CGRect
        if preservingPlacement, workArea.visibleFrame.contains(frameBeforeWorkAreaRefresh) {
            return
        }
        if preservingPlacement || isWindowDragging || isLiveResizing {
            targetFrame = PanelGeometry.constrainedFrame(
                panel.visibleContentFrame,
                to: workArea.visibleFrame
            )
        } else {
            targetFrame = frame(in: workArea.visibleFrame, corner: currentCorner)
        }
        let didClampLiveResize = isLiveResizing && (
            abs(targetFrame.width - frameBeforeWorkAreaRefresh.width) >= 0.5
                || abs(targetFrame.height - frameBeforeWorkAreaRefresh.height) >= 0.5
        )
        if didClampLiveResize {
            resizePersistenceState.recordTemporaryWorkAreaClamp()
        }
        if !framesMatch(panel.visibleContentFrame, targetFrame) {
            panel.setVisibleContentFrame(targetFrame, display: panel.isVisible)
        }
        uiState.updatePanelSize(targetFrame.size)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        panel.cancelTrackpadSwipe()
        // A pointer-driven cross-display move is still the same gesture.
        // Actual display reconfiguration is cancelled by the separate
        // didChangeScreenParameters observer.
        guard !isWindowDragging else { return }
        hostingView.cancelActiveInteraction(reason: .screenChanged)
        let destinationScreen = (notification.object as? NSWindow)?.screen ?? panel.screen
        recoverPanelInsideUsableArea(preferredScreen: destinationScreen)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // O14-01 (owner, 2026-10-14): one click on a panel that is not key
        // must act. That press makes it key, and the key look (a Solid
        // panel's corner buttons turn from flat to glass) redrew the very
        // control being pressed, so its press was lost and the click only
        // focused the panel. The look follows once the button is up.
        if panel.isPressing {
            keyLookAwaitsRelease = true
        } else {
            uiState.setPanelKey(true)
        }
    }

    /// The press that made the panel key ended: it shows as key now.
    private func pressEnded() {
        guard keyLookAwaitsRelease else { return }
        keyLookAwaitsRelease = false
        if panel.isKeyWindow { uiState.setPanelKey(true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        keyLookAwaitsRelease = false
        uiState.setPanelKey(false)
        hostingView.cancelActiveInteraction(reason: .windowDeactivated)
    }

    // MARK: Built on approach, released when hidden

    private func buildPagesIfNeeded() {
        guard !uiState.isPageContentLoaded else { return }
        uiState.loadPageContent()
        hostingView.layoutSubtreeIfNeeded()
    }

    /// After launch, once the main thread is idle: build the Tasks page
    /// while hidden, so the first explicit open (quick capture, Show Attic)
    /// shows a built list instead of building it before its first frame.
    /// Tasks is never released while hidden, so this happens once. A
    /// one-shot, not a timer.
    func buildTasksPageWhenIdle(after delay: TimeInterval = 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isVisible, !self.uiState.isPageContentLoaded,
                      !Self.releasesWhenHidden(self.uiState.selectedSection) else { return }
                self.buildPagesIfNeeded()
            }
        }
    }

    /// Once the panel has been shown for a moment: build the pages the
    /// switch leads to (Canvas, and Tasks from another page) behind the
    /// current one, one per main-thread turn, so a first ⌘1–⌘3 or click
    /// only shows them. A hidden Canvas decodes no images until it shows
    /// (`atticPanelPageIsCurrent`), and the hidden release frees them.
    /// A one-shot per reveal, not a timer.
    static var keptPagesBuildDelay: TimeInterval = 0.6

    private func buildKeptPagesAfterReveal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keptPagesBuildDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.uiState.isPageContentLoaded else { return }
                let current = PanelPage(self.uiState.selectedSection)
                let pending = PanelPage.allCases.filter {
                    $0 != current && PanelUIState.keepsBuilt($0) && !self.uiState.builtPages.contains($0)
                }
                for (index, page) in pending.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(index)) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.panel.isVisible else { return }
                            self.uiState.prepareBuiltPage(page)
                        }
                    }
                }
            }
        }
    }

    /// The pointer is approaching the corner of a hidden panel: build the
    /// pages during the reveal delay instead of after it. If no reveal
    /// follows, the usual hidden release frees a heavy page again.
    func preparePagesForReveal() {
        guard !panel.isVisible, !uiState.isPageContentLoaded else { return }
        buildPagesIfNeeded()
        schedulePageRelease()
    }

    /// How long the panel stays hidden before its pages are released (spec:
    /// about 5 minutes; a tunable, adjusted after real use).
    static var pageReleaseDelay: TimeInterval = 300
    private var pageReleaseWork: DispatchWorkItem?

    /// One one-shot deadline per hide; a reveal cancels it. Nothing else runs
    /// while hidden.
    private func schedulePageRelease() {
        cancelPageRelease()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageReleaseWork = nil
                self.releasePagesIfSafe()
            }
        }
        pageReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageReleaseDelay, execute: work)
    }

    private func cancelPageRelease() {
        pageReleaseWork?.cancel()
        pageReleaseWork = nil
        pageReleaseRetry = nil
    }

    /// A release the deadline had to skip (an import, a lock, an unsaved
    /// draft) waits for that work to finish: every input to the decision
    /// publishes its change, so the retry is event-driven, never polled,
    /// and exists only between a skipped release and the next reveal.
    private var pageReleaseRetry: AnyCancellable?

    private func retryPageReleaseWhenWorkFinishes() {
        guard pageReleaseRetry == nil else { return }
        // Locks, the note draft and the canvas session announce every change
        // before it lands; the retry runs on the next turn, after it.
        pageReleaseRetry = Publishers.Merge3(
            uiState.objectWillChange.map { _ in () },
            noteDraft.objectWillChange.map { _ in () },
            canvasSession.objectWillChange.map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pageReleaseRetry != nil else { return }
                    self.releasePagesIfSafe()
                }
            }
    }

    var hasPendingPageReleaseRetryForTesting: Bool { pageReleaseRetry != nil }

    /// Whether the page showing is one the hidden release frees. The spec
    /// releases heavy views (an open canvas, large images: the Canvas and
    /// Notes pages); the Tasks list stays, so an explicit open after a long
    /// idle (quick capture, Show Attic) never waits for the list to be
    /// rebuilt. Speed outranks weight.
    static func releasesWhenHidden(_ section: PanelSection) -> Bool {
        PanelPage(section) != .tasks
    }

    /// Releases the pages only while hidden, only for a heavy page, and only
    /// once every change is saved: a dirty note draft, an import, an open
    /// confirmation or any other interaction lock keeps them (the next hide
    /// tries again).
    ///
    /// A release skipped for unfinished work is retried when that work
    /// finishes, while the panel stays hidden (a reveal cancels it).
    func releasePagesIfSafe() {
        let current = PanelPage(uiState.selectedSection)
        let releasesCurrent = Self.releasesWhenHidden(uiState.selectedSection)
        let hasBackgroundPages = !uiState.builtPages.subtracting([current]).isEmpty
        guard !panel.isVisible, uiState.isPageContentLoaded, releasesCurrent || hasBackgroundPages else {
            pageReleaseRetry = nil
            return
        }
        // Focus left in a field, and text typed in the add bar (kept in the
        // shell's TasksPageState), are not unsaved work; every other lock is.
        let keepsPages = uiState.interactionLockReasons
            .subtracting([.quickEntryFocus, .notesEditorFocus, .taskComposer])
        let importInFlight = canvasSession.imageImportProgress.map { $0.completedCount < $0.items.count } ?? false
        guard keepsPages.isEmpty,
              !noteDraft.isDirty,
              !importInFlight,
              canvasSession.pendingPlacement == nil,
              noteDraft.flush() else {
            retryPageReleaseWhenWorkFinishes()
            return
        }
        pageReleaseRetry = nil
        canvasSession.flushViewState()
        if releasesCurrent {
            uiState.releasePageContent()
        } else {
            // Tasks stays built (an explicit open never waits for the list);
            // the pages kept behind it go.
            uiState.releaseBackgroundPages()
        }
    }

    /// Performance probe (`--extra`): types `text` one key at a time into
    /// whatever holds the panel's keyboard (the Tasks add bar after an
    /// explicit open), through AppKit's own key path, and returns how long
    /// each keystroke took until the panel had laid out and displayed it.
    /// A proxy for "one frame per keystroke": it ends at the panel's
    /// display pass, not at scan-out. The text is removed again afterwards.
    func typeForPerformanceProbe(_ text: String) -> [Double] {
        guard panel.isVisible else { return [] }
        if !(panel.firstResponder is AtticTokenTextView), let bar = Self.firstTokenField(in: panel.contentView) {
            panel.makeFirstResponder(bar)
        }
        guard let field = panel.firstResponder as? NSTextView else { return [] }
        var durations: [Double] = []
        for character in text {
            let characters = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: character == " " ? 49 : 0
            ) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            panel.sendEvent(event)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        field.selectAll(nil)
        field.insertText("", replacementRange: field.selectedRange())
        return durations
    }

    /// Performance seam (probe only): scrolls the tallest visible vertical
    /// list down `steps` times by `step` points, drawing each step before
    /// the next, and returns each step's time in milliseconds.
    func scrollForPerformanceProbe(steps: Int, step: CGFloat) -> [Double] {
        guard panel.isVisible, let scrollView = Self.tallestScrollView(in: panel.contentView) else { return [] }
        let clip = scrollView.contentView
        var durations: [Double] = []
        for _ in 0..<steps {
            let start = DispatchTime.now().uptimeNanoseconds
            var origin = clip.bounds.origin
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            origin.y = min(origin.y + step, maxY)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return durations
    }

    private static func tallestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        var best: NSScrollView?
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || (scroll.documentView?.frame.height ?? 0) > scroll.frame.height,
           scroll.visibleRect.width > 0 {
            best = scroll
        }
        for subview in view.subviews {
            if let found = tallestScrollView(in: subview),
               (found.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = found }
        }
        return best
    }

    private static func firstTokenField(in view: NSView?) -> AtticTokenTextView? {
        guard let view else { return nil }
        if let field = view as? AtticTokenTextView, !field.isHiddenOrHasHiddenAncestor { return field }
        for subview in view.subviews {
            if let found = firstTokenField(in: subview) { return found }
        }
        return nil
    }

    /// Capture seam (UI testing only): the panel takes the keyboard as a
    /// click would.
    func makeKeyForCapture() {
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSLog("Attic capture seam: panel key = %d, shell key state = %d",
                  self.panel.isKeyWindow ? 1 : 0, self.uiState.isPanelKey ? 1 : 0)
        }
    }

    /// Re-runs the click-through hit test where the pointer is now: after
    /// the panel is ordered front and after its geometry changes, when a
    /// resting pointer sends no event of its own. Only while visible and
    /// monitored; a live resize or drag keeps its own state.
    private func resamplePointerPassthrough() {
        guard panel.isVisible, localPointerMonitor != nil || globalPointerMonitor != nil,
              !isResamplingPassthrough else { return }
        isResamplingPassthrough = true
        defer { isResamplingPassthrough = false }
        updateMousePassthrough(at: pointerLocation())
    }

    /// Test seam: whether clicks at the pointer now pass to the app behind.
    var ignoresMouseEventsForTesting: Bool { panel.ignoresMouseEvents }
    /// Test seam: the visible surface's frame on screen.
    var visibleContentFrameForTesting: CGRect { panel.visibleContentFrame }

    private func startPointerPassthroughMonitoring() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateMousePassthrough(at: self.pointerLocation())
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // AppKit invokes global event-monitor handlers on the main thread.
            // Keep acquisition synchronous so a fast outside-in move cannot
            // outrun the corner halo before the next mouse event arrives.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateMousePassthrough(at: self.pointerLocation())
            }
        }
        updateMousePassthrough(at: pointerLocation())
    }

    private func stopPointerPassthroughMonitoring() {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        isDisplayingResizeCursor = false
    }
}

#if DEBUG
/// The motion bench's record of a swipe: each update (handled at, the
/// event's own time, finger distance, collapse applied, ms to apply) and
/// the release.
@MainActor
enum PanelSwipeTrace {
    static var events: [[Double]] = []
    static var release: [String: Double] = [:]
}
#endif
