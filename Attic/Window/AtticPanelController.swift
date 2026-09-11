import AppKit
import Combine
import QuartzCore
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
    private let hostingView: AtticPanelHostingView
    private let store: TaskStore
    private let noteStore: NoteStore
    private let canvasSession: CanvasSession
    private let noteDraft: NoteDraftController
    private let chromeInteractionState: PanelChromeInteractionState
    private let settings: AppSettings
    private let uiState: PanelUIState
    let subtaskPanels: SubtaskPanelController
    private var cancellables: Set<AnyCancellable> = []
    private var isShowing = false
    private var isPanelMotionActive = false
    private var isInteractiveDismissal = false
    private var interactiveSwipeStartProgress: CGFloat = 0
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
    /// Live snapshot-warp presentation while a visibility transition runs;
    /// nil whenever the panel is at rest or hidden. Internal so tests can
    /// install a session directly without displaying a test window.
    var genieSession: PanelGenieSession?
    private var interactiveCaptureFailed = false
    private(set) var currentScreen: NSScreen?
    private var lastUsableFrame: CGRect?
    private(set) var currentCorner: ScreenCorner = .topRight
    var onInteractiveHideCompleted: (() -> Void)?

    private var contentContainer: AtticPanelContentContainer? {
        panel.contentView as? AtticPanelContentContainer
    }

    init(
        store: TaskStore,
        noteStore: NoteStore,
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        settings: AppSettings,
        uiState: PanelUIState
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
        panel = AtticPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        subtaskPanels = SubtaskPanelController(
            store: store,
            uiState: uiState,
            settings: settings
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
                subtaskPanels: subtaskPanels
            ),
            panelCornerRadius: settings.panelCornerSize,
            dockedCorner: settings.corner,
            chromeInteractionState: chromeInteractionState
        )

        super.init()
        configurePanel()
        bindContentSize()
    }

    deinit {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
    }

    var visibleFrame: CGRect? {
        panel.isVisible ? panel.visibleContentFrame : nil
    }

    /// Pointer inside the open transient subtask surface counts as inside
    /// the panel for auto-hide purposes: the checklist is useless without
    /// its anchor. The pinned window is excluded — it is independent.
    func auxiliarySurfaceContains(_ point: CGPoint) -> Bool {
        subtaskPanels.containsTransientPoint(point)
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
           lastUsableFrame != screen.visibleFrame {
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

    func show(on screen: NSScreen, corner: ScreenCorner, makeKey: Bool = false) {
        // A reveal always supersedes an in-flight hide, even when its frame
        // already matches. This prevents that hide's completion from ordering
        // out a panel the user has just asked to see again.
        clearInteractiveDismissal()
        panel.cancelTrackpadSwipe()
        stopPanelMotion()
        let frameBeforeWorkAreaRefresh = panel.visibleContentFrame
        guard let workArea = refreshCurrentWorkArea(preferredScreen: screen) else {
            // No usable display: hand pixels back to the live subtree rather
            // than leaving a frozen snapshot overlay behind.
            restoreFullPresentation()
            return
        }
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
            animateShow(to: safeFrame)
            return
        }

        let finalFrame = frame(in: visibleFrame, corner: corner)

        if panel.isVisible {
            let localPriorFrame = PanelGeometry.constrainedFrame(priorFrame, to: visibleFrame)
            let mustEstablishOnTargetDisplay = !framesMatch(priorFrame, localPriorFrame)

            if mustEstablishOnTargetDisplay {
                panel.setVisibleContentFrame(finalFrame, display: true)
                // A new anchor invalidates any in-flight presentation: it is
                // restarted below, unfurling toward the new corner.
                genieSession?.teardown()
                genieSession = nil
            }

            if makeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }

            if mustEstablishOnTargetDisplay {
                beginGenieReveal(on: screen, corner: corner)
            }
            animateShow(to: finalFrame)
            return
        }

        panel.setVisibleContentFrame(finalFrame, display: true)
        panel.alphaValue = 1

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        beginGenieReveal(on: screen, corner: corner)
        animateShow(to: finalFrame)
    }

    /// Installs the snapshot-warp presentation for an unfurl from the anchor
    /// point. With Reduce Motion, or when the snapshot cannot be produced,
    /// nothing is installed and the caller's restrained path runs instead.
    private func beginGenieReveal(on screen: NSScreen, corner: ScreenCorner) {
        guard genieSession == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let container = contentContainer else { return }
        genieSession = PanelGenieSession.begin(
            panel: panel,
            contentContainer: container,
            motionView: container.motionView,
            screen: screen,
            corner: corner,
            initialProgress: 1
        )
        // Capture failure degrades to the instant/fade paths inside
        // animateShow — never a blink of the already-visible panel.
    }

    private func animateShow(to finalFrame: CGRect) {
        let generation = visibilityTransition.beginTransition()
        isShowing = true
        if let session = genieSession {
            isPanelMotionActive = true
            session.animate(to: 0, direction: .reveal) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.visibilityTransition.completeTransition(generation) else { return }
                    // Handoff at progress 0: sprite and live pixels are
                    // identical, so removing the overlay is seamless.
                    self.genieSession?.teardown()
                    self.genieSession = nil
                    self.finishShowTransition()
                }
            }
            return
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           panel.alphaValue < 1 {
            // Snapshot capture failed: restrained fade, no deformation.
            animatePanelAlpha(to: 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.visibilityTransition.completeTransition(generation) else { return }
                    self.finishShowTransition()
                }
            }
            return
        }
        // No presentation change in flight: either an instant (Reduce Motion)
        // establish or a plain dock move of a fully-presented panel.
        if !framesMatch(panel.visibleContentFrame, finalFrame) {
            animatePanelFrame(to: finalFrame, duration: 0.18) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.visibilityTransition.completeTransition(generation) else { return }
                    self.finishShowTransition()
                }
            }
        } else {
            visibilityTransition.completeTransition(generation)
            finishShowTransition()
        }
    }

    private func finishShowTransition() {
        isPanelMotionActive = false
        // Interruption of a fade can leave the real window dimmed.
        panel.alphaValue = 1
        contentContainer?.allowsContentInteraction = true
        isShowing = false
        if needsResizeAfterShowing {
            needsResizeAfterShowing = false
            resizeAndReanchor()
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
        guard noteDraft.flush() else {
            return .rejected(.draftFlushFailed)
        }
        clearInteractiveDismissal()
        stopPanelMotion()
        panel.cancelTrackpadSwipe()

        // Destructive/transient presentation state changes only after the
        // persistence boundary accepts the hide transaction.
        hostingView.cancelActiveInteraction(reason: .explicitHide)
        canvasSession.cancelActiveInteraction()
        uiState.isCanvasConfirmationPresented = false
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
        uiState.setInteractionLock(.windowResize, isActive: false)
        let generation = visibilityTransition.beginHideTransition(completion: completion)
        isShowing = false
        needsResizeAfterShowing = false
        let safeFrame = PanelGeometry.constrainedFrame(panel.visibleContentFrame, to: screen.visibleFrame)
        if !framesMatch(panel.visibleContentFrame, safeFrame) {
            panel.setVisibleContentFrame(safeFrame, display: true)
        }
        // Every hide reason converges on the real work-area corner: the warp
        // pulls the sheet into that anchor point from wherever the panel is —
        // a released throw needs no native frame travel.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishHideTransition(generation: generation)
            return .accepted
        }
        if genieSession == nil, let container = contentContainer {
            genieSession = PanelGenieSession.begin(
                panel: panel,
                contentContainer: container,
                motionView: container.motionView,
                screen: screen,
                corner: currentCorner,
                initialProgress: 0
            )
        }
        if let session = genieSession {
            isPanelMotionActive = true
            session.animate(to: 1, direction: .conceal) { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishHideTransition(generation: generation)
                }
            }
        } else {
            // Snapshot unavailable: restrained fade instead of deformation.
            animatePanelAlpha(to: 0) { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishHideTransition(generation: generation)
                }
            }
        }
        return .accepted
    }

    /// Shared hide terminal: runs only while `generation` still owns the
    /// transition, so a stale completion can never order out a re-shown panel.
    private func finishHideTransition(generation: Int) {
        guard visibilityTransition.ownsCompletion(generation) else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
        isPanelMotionActive = false
        genieSession?.teardown()
        genieSession = nil
        stopPointerPassthroughMonitoring()
        subtaskPanels.mainPanelDidHide()
        visibilityTransition.completeHideTransition(generation)
    }

    private func configurePanel() {
        let visibleFrame = panel.frame
        panel.resizePerimeter = AtticPanelResizePolicy.outsideGripThickness
        panel.setVisibleContentFrame(visibleFrame, display: false)
        panel.contentView = AtticPanelContentContainer(
            hostingView: hostingView,
            visibleSize: visibleFrame.size,
            perimeter: panel.resizePerimeter
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
            if !self.requestInteractiveHide().isAccepted {
                self.cancelInteractiveDismissal()
            }
        }
        panel.onTrackpadDismissProgress = { [weak self] distance in
            self?.updateInteractiveDismissal(distance: distance)
        }
        panel.onTrackpadDismissCancelled = { [weak self] in
            self?.cancelInteractiveDismissal()
        }
        panel.onDirectContentInteraction = { [weak self] in
            guard let self, self.isShowing || self.isInteractiveDismissal else { return }
            self.clearInteractiveDismissal()
            self.stopPanelMotion()
            self.restoreFullPresentation()
        }
        panel.canBeginTrackpadSwipe = { [weak self] event in
            guard let self, !self.isPanelMotionActive else { return false }
            let blockers: Set<PanelInteractionLockReason> = [
                .windowMove, .windowResize, .menuTracking, .blockingSave, .canvasConfirmation,
                .notesImport, .taskEditing
            ]
            return self.uiState.interactionLockReasons.isDisjoint(with: blockers)
                && !self.hostingView.isChromeControlPoint(event.locationInWindow)
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
        subtaskPanels.attach(panel: panel, hostView: hostingView)
    }

    private func bindContentSize() {
        uiState.$selectedSection
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.panel.cancelTrackpadSwipe() }
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
                    recoverPanelInsideUsableArea()
                case .applicationDeactivated:
                    panel.cancelTrackpadSwipe()
                    hostingView.cancelActiveInteraction(reason: .applicationDeactivated)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSWorkspace.accessibilityDisplayShouldReduceMotionDidChangeNotification
        )
        .sink { [weak self] _ in
            self?.settlePresentationForAccessibilityChange()
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
        subtaskPanels.mainPanelFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        subtaskPanels.mainPanelFrameDidChange()
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
        let visibleFrame = screen.visibleFrame
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
        let visibleFrame = screen.visibleFrame
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

    private func requestInteractiveHide() -> PanelHideRequestResult {
        requestHide { [weak self] completion in
            guard completion == .hidden else { return }
            self?.onInteractiveHideCompleted?()
        }
    }

    private func updateInteractiveDismissal(distance: CGFloat) {
        guard panel.isVisible else { return }
        let spec = PanelGenieGeometry.Spec.standard
        if !isInteractiveDismissal {
            stopPanelMotion()
            isInteractiveDismissal = true
            interactiveCaptureFailed = false
            // A swipe can begin while a timed run is in flight: the gesture
            // takes over from exactly the progress on screen.
            interactiveSwipeStartProgress = min(1, max(0, genieSession?.progress ?? 0))
            uiState.setInteractionLock(.panelSwipe, isActive: true)
        }
        let progress = PanelGenieGeometry.swipeProgress(
            forSwipeDistance: distance,
            panelWidth: panel.visibleContentFrame.width,
            spec: spec
        )
        let target = interactiveSwipeStartProgress
            + (1 - interactiveSwipeStartProgress) * progress
        contentContainer?.allowsContentInteraction = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            genieSession?.teardown()
            genieSession = nil
            panel.alphaValue = 1 - (1 - spec.reducedMotionSwipeFloor) * min(1, max(0, target))
            return
        }
        if genieSession == nil, !interactiveCaptureFailed,
           let container = contentContainer,
           let screen = panel.screen ?? currentScreen {
            genieSession = PanelGenieSession.begin(
                panel: panel,
                contentContainer: container,
                motionView: container.motionView,
                screen: screen,
                corner: currentCorner,
                initialProgress: interactiveSwipeStartProgress
            )
            if genieSession == nil { interactiveCaptureFailed = true }
        }
        if let session = genieSession {
            session.applyImmediately(target)
        } else {
            panel.alphaValue = 1 - (1 - spec.reducedMotionSwipeFloor) * min(1, max(0, target))
        }
    }

    private func clearInteractiveDismissal() {
        isInteractiveDismissal = false
        interactiveSwipeStartProgress = 0
        uiState.setInteractionLock(.panelSwipe, isActive: false)
    }

    private func cancelInteractiveDismissal() {
        guard isInteractiveDismissal else { return }
        clearInteractiveDismissal()
        stopPanelMotion()
        guard panel.isVisible else { restoreFullPresentation(); return }
        animateShow(to: panel.visibleContentFrame)
    }

    private func restoreFullPresentation() {
        clearInteractiveDismissal()
        genieSession?.teardown()
        genieSession = nil
        interactiveCaptureFailed = false
        panel.alphaValue = 1
        contentContainer?.setPresentationVirtualized(false)
        contentContainer?.allowsContentInteraction = true
    }

    /// A Reduce Motion toggle mid-transition must land in a coherent end
    /// state, not funnel slower. An in-flight run finishes instantly through
    /// its own generation-guarded completion; a held presentation snaps back
    /// to rest with the real content.
    private func settlePresentationForAccessibilityChange() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let session = genieSession else { return }
        if session.isMotionActive {
            session.finishImmediately()
        } else {
            session.teardown()
            genieSession = nil
            panel.alphaValue = 1
        }
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

        let visibleFrame = screen.visibleFrame
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
        animatePanelFrame(to: targetFrame, duration: 0.18) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.completeTransition(generation) else { return }
                self.uiState.updatePanelSize(self.panel.visibleContentFrame.size)
                self.uiState.dockingPreviewCorner = nil
                self.uiState.setInteractionLock(.windowMove, isActive: false)
            }
        }
    }

    /// Bounded native frame move (dock/re-anchor). Visibility deformation is
    /// owned exclusively by PanelGenieSession — this never touches pixels.
    private func animatePanelFrame(
        to frame: CGRect,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let generation = visibilityTransition.generation
        isPanelMotionActive = true
        contentContainer?.allowsContentInteraction = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(panel.nativeFrame(forVisibleFrame: frame), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.isPanelMotionActive = false
                self.contentContainer?.allowsContentInteraction = true
                completion()
            }
        }
    }

    /// Restrained non-deforming fallback for Reduce Motion or a failed
    /// snapshot: a bounded opacity transition on the real window.
    private func animatePanelAlpha(
        to alpha: CGFloat,
        completion: @escaping () -> Void
    ) {
        let generation = visibilityTransition.generation
        isPanelMotionActive = true
        contentContainer?.allowsContentInteraction = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelGenieGeometry.Spec.standard.fadeDuration
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.isPanelMotionActive = false
                self.panel.alphaValue = 1
                completion()
            }
        }
    }

    private func stopPanelMotion() {
        visibilityTransition.invalidatePendingTransition()
        // Freeze the warp where it is — the session survives so the next
        // transition continues from the visible state.
        genieSession?.holdMotion()
        let currentFrame = panel.frame
        // NSAnimatablePropertyContainer documents a zero-duration animator
        // update as the way to stop an in-flight property animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(currentFrame, display: false)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = panel.alphaValue
        }
        isShowing = false
        isPanelMotionActive = false
        needsResizeAfterShowing = false
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let overlapCandidate = screens
            .map { screen in
                let overlap = screen.frame.intersection(frame)
                return (screen, max(0, overlap.width) * max(0, overlap.height))
            }
            .max { $0.1 < $1.1 }
        if let overlapCandidate, overlapCandidate.1 > 0 {
            return overlapCandidate.0
        }
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            squaredDistance(from: frameCenter, to: $0.frame) < squaredDistance(from: frameCenter, to: $1.frame)
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
        let visibleFrame = screen.visibleFrame
        currentScreen = screen
        updateResizeLimits(in: visibleFrame)
        return PanelWorkAreaSnapshot(visibleFrame: visibleFrame)
    }

    private func recoverPanelInsideUsableArea(
        preferredScreen: NSScreen? = nil
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
        if isWindowDragging || isLiveResizing {
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

    func windowDidResignKey(_ notification: Notification) {
        hostingView.cancelActiveInteraction(reason: .windowDeactivated)
    }

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
                self?.updateMousePassthrough(at: NSEvent.mouseLocation)
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // AppKit invokes global event-monitor handlers on the main thread.
            // Keep acquisition synchronous so a fast outside-in move cannot
            // outrun the corner halo before the next mouse event arrives.
            MainActor.assumeIsolated {
                self?.updateMousePassthrough(at: NSEvent.mouseLocation)
            }
        }
        updateMousePassthrough(at: NSEvent.mouseLocation)
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
