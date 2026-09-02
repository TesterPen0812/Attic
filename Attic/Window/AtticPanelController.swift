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

/// A hide request whose completion is still owed to its caller. The
/// continuous motion model resolves it when the presentation coordinate
/// actually reaches hidden, or as superseded when a reveal retargets the
/// timeline before completion.
struct PanelPendingHide {
    let completion: (PanelHideCompletion) -> Void
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
    private var motion = PanelMotion.Transition()
    private var pendingHide: PanelPendingHide?
    private var motionCompletion: (() -> Void)?
    private var needsResizeAfterShowing = false
    private var isLiveResizing = false
    private var resizePersistenceState = PanelResizePersistenceState()
    private var isPersistingManualSize = false
    private var isApplyingInteractiveCorner = false
    private var isWindowDragging = false
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private(set) var currentScreen: NSScreen?
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
        panel.isVisible ? panel.frame : nil
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard panel.isVisible, panel.frame.contains(point) else { return false }
        let localPoint = CGPoint(
            x: point.x - panel.frame.minX,
            y: point.y - panel.frame.minY
        )
        return Squircle.contains(
            localPoint,
            in: CGRect(origin: .zero, size: panel.frame.size),
            cornerRadius: settings.panelCornerSize,
            exponent: AtticStyle.panelSquircleExponent
        )
    }

    func updateMousePassthrough(at point: CGPoint) {
        guard !isLiveResizing else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let isInsideRectangularFrame = panel.isVisible && panel.frame.contains(point)
        let localPoint = CGPoint(
            x: point.x - panel.frame.minX,
            y: point.y - panel.frame.minY
        )
        let acquisitionEdges = isInsideRectangularFrame
            ? AtticPanelResizePolicy.allowedResizeEdges(
                AtticPanelResizePolicy.cornerAcquisitionEdges(
                    at: localPoint,
                    in: CGRect(origin: .zero, size: panel.frame.size),
                    cornerRadius: settings.panelCornerSize
                ),
                dockedAt: currentCorner
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
        }
    }

    func show(on screen: NSScreen, corner: ScreenCorner, makeKey: Bool = false) {
        // A reveal always retargets the single motion timeline. If a hide
        // is mid-flight, the pending hide's completion resolves superseded
        // and the window continues from its live presentation state.
        resolvePendingHide(.superseded)
        motionCompletion = nil
        let frameBeforeWorkAreaRefresh = panel.frame
        guard let workArea = refreshCurrentWorkArea(preferredScreen: screen) else {
            return
        }
        let visibleFrame = workArea.visibleFrame
        let priorFrame = panel.frame
        currentCorner = corner
        hostingView.dockedCorner = corner
        startPointerPassthroughMonitoring()

        if isLiveResizing {
            let safeFrame = PanelGeometry.constrainedFrame(
                panel.frame,
                to: visibleFrame
            )
            if abs(safeFrame.width - frameBeforeWorkAreaRefresh.width) >= 0.5
                || abs(safeFrame.height - frameBeforeWorkAreaRefresh.height) >= 0.5 {
                resizePersistenceState.recordTemporaryWorkAreaClamp()
            }
            if !framesMatch(panel.frame, safeFrame) {
                panel.setFrame(safeFrame, display: panel.isVisible)
                uiState.updatePanelSize(safeFrame.size)
            }
            if makeKey { panel.makeKey() }
            panel.orderFrontRegardless()
            let emergenceFrame = PanelGeometry.hiddenFrame(
                from: safeFrame,
                corner: corner,
                in: visibleFrame
            )
            animateMotion(
                toVisibleFrame: safeFrame,
                emergingFrom: emergenceFrame
            )
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
                panel.setFrame(localInitialFrame, display: true)
            }

            if makeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }

            let emergenceFrame = PanelGeometry.hiddenFrame(
                from: finalFrame,
                corner: corner,
                in: visibleFrame
            )
            animateMotion(
                toVisibleFrame: finalFrame,
                emergingFrom: emergenceFrame
            )
            return
        }

        // Hidden reveal: stage at the corner-aligned emergence geometry.
        // If a prior transition left the window mid-flight, the retarget
        // below continues from the live frame rather than teleporting.
        let initialFrame = PanelGeometry.hiddenFrame(
            from: finalFrame,
            corner: corner,
            in: visibleFrame
        )
        panel.setFrame(initialFrame, display: true)
        panel.alphaValue = 0

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        animateMotion(
            toVisibleFrame: finalFrame,
            emergingFrom: initialFrame
        )
    }

    /// The single motion command. Every reveal and every hide retargets
    /// the same window-owned timeline: the window server reports live
    /// animated frames, so a new `animator().setFrame` continues from the
    /// currently presented frame instead of restarting the motion.
    private func animateMotion(
        toVisibleFrame visibleFrame: CGRect,
        emergingFrom emergenceFrame: CGRect
    ) {
        let geometry = PanelMotion.Geometry(
            visibleFrame: visibleFrame,
            hiddenFrame: emergenceFrame
        )
        motion.geometry = geometry

        // Continue from the live window state. Reading `panel.frame`
        // mid-animation returns the currently presented frame.
        let liveFrame = panel.frame
        let liveProgress = PanelMotion.progress(of: liveFrame, in: geometry)
        motion.presentedProgress = liveProgress

        // If the window is already presenting the destination, the motion
        // system still completes presentation state atomically.
        if framesMatch(liveFrame, visibleFrame) {
            motion.finishPresentation(at: 1)
            finishMotionIfNeeded()
            return
        }

        motion.beginReveal()
        let intent = motion.intentSequence
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = PanelMotion.duration(for: .revealing, reduceMotion: reduceMotion)

        if reduceMotion {
            // Low-motion alternative: the frame reaches its destination
            // immediately; only a short alpha crossfade presents the change.
            panel.setFrame(visibleFrame, display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = nil
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeMotion(at: 1, intent: intent)
                }
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(visibleFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.completeMotion(at: 1, intent: intent)
            }
        }
    }

    /// Completes the presentation only if `intent` still owns the motion.
    /// An interrupted animation's completion handler arrives with a stale
    /// intent and is ignored; the retargeting animation completes instead.
    private func completeMotion(at progress: CGFloat, intent: UInt64) {
        guard motion.ownsCompletion(intent) else { return }
        motion.finishPresentation(at: progress)
        finishMotionIfNeeded()
    }

    private func finishMotionIfNeeded() {
        let completion = motionCompletion
        motionCompletion = nil
        if motion.phase == .visible {
            if needsResizeAfterShowing {
                needsResizeAfterShowing = false
                resizeAndReanchor()
            }
        } else if motion.phase == .hidden {
            panel.orderOut(nil)
            panel.alphaValue = 1
            stopPointerPassthroughMonitoring()
            resolvePendingHide(.hidden)
        }
        completion?()
    }

    private func resolvePendingHide(_ outcome: PanelHideCompletion) {
        guard let pendingHide else { return }
        self.pendingHide = nil
        pendingHide.completion(outcome)
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

        // Destructive/transient presentation state changes only after the
        // persistence boundary accepts the hide transaction.
        hostingView.cancelActiveInteraction(reason: .explicitHide)
        canvasSession.cancelActiveInteraction()
        uiState.isCanvasConfirmationPresented = false
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
        uiState.setInteractionLock(.windowResize, isActive: false)
        resolvePendingHide(.superseded)
        pendingHide = PanelPendingHide(completion: completion)
        needsResizeAfterShowing = false
        let safeFrame = PanelGeometry.constrainedFrame(panel.frame, to: screen.visibleFrame)
        if !framesMatch(panel.frame, safeFrame) {
            panel.setFrame(safeFrame, display: true)
        }
        let emergenceFrame = PanelGeometry.hiddenFrame(
            from: safeFrame,
            corner: currentCorner,
            in: screen.visibleFrame
        )
        let geometry = PanelMotion.Geometry(
            visibleFrame: safeFrame,
            hiddenFrame: emergenceFrame
        )
        motion.geometry = geometry
        let liveProgress = PanelMotion.progress(of: panel.frame, in: geometry)
        motion.presentedProgress = liveProgress
        motion.beginHide()
        let intent = motion.intentSequence

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = PanelMotion.duration(for: .hiding, reduceMotion: reduceMotion)

        if reduceMotion {
            panel.setFrame(emergenceFrame, display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = nil
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeMotion(at: 0, intent: intent)
                }
            }
            return .accepted
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(emergenceFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.completeMotion(at: 0, intent: intent)
            }
        }
        return .accepted
    }

    private func configurePanel() {
        panel.contentView = hostingView
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
        hostingView.onSwipeDismissalTriggered = { [weak self] in
            self?.handleSwipeDismissal()
        }
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    /// Two-finger swipe toward the attached edge hides through the same
    /// interactive-hide path as a header flick: persistence gate first,
    /// then the unified hide motion, with a fallback dock if the draft
    /// cannot flush.
    private func handleSwipeDismissal() {
        guard !isWindowDragging, !isLiveResizing else { return }
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
        let result = requestHide { [weak self] completion in
            guard completion == .hidden else { return }
            self?.onInteractiveHideCompleted?()
        }
        if !result.isAccepted {
            // A dirty draft blocks the hide; keep the panel attached and
            // visible at its current corner without motion ambiguity.
            if let screen = panel.screen ?? currentScreen ?? NSScreen.main {
                animateDock(
                    on: screen,
                    to: currentCorner,
                    persistsCorner: false,
                    showsPreview: false
                )
            }
        }
    }

    private func bindContentSize() {
        settings.$corner
            .sink { [weak self] corner in
                guard let self else { return }
                self.currentCorner = corner
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
        if motion.phase == .revealing || motion.phase == .docking {
            needsResizeAfterShowing = true
            return
        }
        let targetFrame = frame(
            in: workArea.visibleFrame,
            corner: currentCorner,
            configuredSize: configuredSize
        )
        guard !framesMatch(panel.frame, targetFrame) else { return }
        panel.setFrame(targetFrame, display: panel.isVisible)
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
        panel.setFrame(placement.frame, display: panel.isVisible)
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
        panel.setFrame(targetFrame, display: panel.isVisible)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        beginLiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSWindow else { return }
        uiState.updatePanelSize(resizedPanel.frame.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSWindow else { return }
        endLiveResize(at: resizedPanel.frame.size)
    }

    private func beginLiveResize() {
        guard !isLiveResizing else { return }
        // Live user resize takes over window motion; the timeline stops
        // wherever it is and the frame becomes user-authoritative.
        motion.beginUserTakeover()
        motionCompletion = nil
        resolvePendingHide(.superseded)
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
        let resolvedFinalSize = panel.frame.size
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
        // The user's drag is the motion authority while it lasts.
        motion.beginUserTakeover()
        motionCompletion = nil
        resolvePendingHide(.superseded)
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
            endLiveResize(at: (frame ?? panel.frame).size)
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
            let result = requestHide { [weak self] completion in
                guard completion == .hidden else { return }
                self?.onInteractiveHideCompleted?()
            }
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

    private func animateDock(
        on screen: NSScreen,
        to corner: ScreenCorner,
        persistsCorner: Bool,
        showsPreview: Bool
    ) {
        uiState.setInteractionLock(.windowMove, isActive: true)
        uiState.dockingPreviewCorner = showsPreview ? corner : nil

        if persistsCorner {
            currentCorner = corner
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
        motion.beginDock()
        let intent = motion.intentSequence
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = PanelMotion.duration(for: .docking, reduceMotion: reduceMotion)

        if reduceMotion {
            panel.setFrame(targetFrame, display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeDock(intent: intent)
                }
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.completeDock(intent: intent)
            }
        }
    }

    private func completeDock(intent: UInt64) {
        guard motion.ownsCompletion(intent) else { return }
        motion.finishPresentation(at: 1)
        uiState.updatePanelSize(panel.frame.size)
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
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
                ?? bestScreen(for: panel.frame)
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
        let frameBeforeWorkAreaRefresh = panel.frame
        guard let workArea = refreshCurrentWorkArea(
            preferredScreen: preferredScreen
        ) else { return }

        if motion.isTransitioning {
            // A screen change or app activation must not leave a partially
            // presented window in a stale geometry. The user's environment
            // takes over: settle to fully visible rather than snapping
            // alpha mid-motion.
            motion.beginUserTakeover()
            motionCompletion = nil
            resolvePendingHide(.superseded)
            needsResizeAfterShowing = false
            panel.alphaValue = 1
            let safeFrame = PanelGeometry.constrainedFrame(
                panel.frame,
                to: workArea.visibleFrame
            )
            if !framesMatch(panel.frame, safeFrame) {
                panel.setFrame(safeFrame, display: true)
            }
        }

        let targetFrame: CGRect
        if isWindowDragging || isLiveResizing {
            targetFrame = PanelGeometry.constrainedFrame(
                panel.frame,
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
        if !framesMatch(panel.frame, targetFrame) {
            panel.setFrame(targetFrame, display: panel.isVisible)
        }
        uiState.updatePanelSize(targetFrame.size)
    }

    func windowDidChangeScreen(_ notification: Notification) {
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
    }
}
