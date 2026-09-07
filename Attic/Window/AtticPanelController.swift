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
    private var cancellables: Set<AnyCancellable> = []
    private var isShowing = false
    private var isPanelMotionActive = false
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
        hostingView = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store,
                noteStore: noteStore,
                canvasSession: canvasSession,
                noteDraft: noteDraft,
                chromeInteractionState: chromeInteractionState,
                uiState: uiState,
                settings: settings
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
        stopPanelMotion()
        let frameBeforeWorkAreaRefresh = panel.visibleContentFrame
        guard let workArea = refreshCurrentWorkArea(preferredScreen: screen) else {
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
                let localInitialFrame = PanelGeometry.hiddenFrame(
                    from: finalFrame,
                    corner: corner,
                    in: visibleFrame
                )
                panel.alphaValue = 0
                panel.setVisibleContentFrame(localInitialFrame, display: true)
            }

            if makeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }

            animateShow(to: finalFrame)
            return
        }

        let initialFrame = PanelGeometry.hiddenFrame(
            from: finalFrame,
            corner: corner,
            in: visibleFrame
        )
        panel.setVisibleContentFrame(initialFrame, display: true)
        panel.alphaValue = 0

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        animateShow(to: finalFrame)
    }

    private func animateShow(to finalFrame: CGRect) {
        let generation = visibilityTransition.beginTransition()
        isShowing = true
        animatePanel(to: finalFrame, alpha: 1, duration: 0.18) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.visibilityTransition.completeTransition(generation) else { return }
                self.isShowing = false
                if self.needsResizeAfterShowing {
                    self.needsResizeAfterShowing = false
                    self.resizeAndReanchor()
                }
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
        guard noteDraft.flush() else {
            return .rejected(.draftFlushFailed)
        }
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
        let targetFrame = PanelGeometry.hiddenFrame(
            from: safeFrame,
            corner: currentCorner,
            in: screen.visibleFrame
        )
        animatePanel(to: targetFrame, alpha: 0, duration: 0.16) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.stopPointerPassthroughMonitoring()
                self.visibilityTransition.completeHideTransition(generation)
            }
        }
        return .accepted
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
            _ = self?.requestInteractiveHide()
        }
        panel.canBeginTrackpadSwipe = { [weak self] event in
            guard let self else { return false }
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
    }

    private func bindContentSize() {
        settings.$corner
            .sink { [weak self] corner in
                guard let self else { return }
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
                    hostingView.cancelActiveInteraction(reason: .screenChanged)
                    recoverPanelInsideUsableArea()
                case .applicationActivated:
                    recoverPanelInsideUsableArea()
                case .applicationDeactivated:
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
        guard let workArea = refreshCurrentWorkArea(preferredScreen: currentScreen) else {
            return
        }
        if isShowing {
            needsResizeAfterShowing = true
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
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSWindow else { return }
        endLiveResize(at: ((resizedPanel as? AtticPanel)?.visibleContentFrame ?? resizedPanel.frame).size)
    }

    private func beginLiveResize() {
        guard !isLiveResizing else { return }
        stopPanelMotion()
        panel.cancelTrackpadSwipe()
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
        stopPanelMotion()
        panel.cancelTrackpadSwipe()
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
        animatePanel(to: targetFrame, alpha: 1, duration: 0.18) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.completeTransition(generation) else { return }
                self.uiState.updatePanelSize(self.panel.visibleContentFrame.size)
                self.uiState.dockingPreviewCorner = nil
                self.uiState.setInteractionLock(.windowMove, isActive: false)
            }
        }
    }

    /// Every visibility and docking trigger retargets the same native frame
    /// and alpha properties, preserving AppKit's current presentation values.
    private func animatePanel(
        to frame: CGRect,
        alpha: CGFloat,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let generation = visibilityTransition.generation
        isPanelMotionActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(panel.nativeFrame(forVisibleFrame: frame), display: true)
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.visibilityTransition.ownsCompletion(generation) {
                    self.isPanelMotionActive = false
                }
                completion()
            }
        }
    }

    private func stopPanelMotion() {
        visibilityTransition.invalidatePendingTransition()
        let currentFrame = panel.frame
        let currentAlpha = panel.alphaValue
        // NSAnimatablePropertyContainer documents a zero-duration animator
        // update as the way to stop an in-flight property animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(currentFrame, display: false)
            panel.animator().alphaValue = currentAlpha
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

        if isPanelMotionActive {
            stopPanelMotion()
            isShowing = false
            needsResizeAfterShowing = false
            panel.alphaValue = 1
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
