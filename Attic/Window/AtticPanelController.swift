import AppKit
import Combine
import QuartzCore
import SwiftUI

enum PanelHideCompletion: Equatable {
    case hidden
    case superseded
}

struct PanelVisibilityTransitionState {
    private(set) var generation = 0
    private var pendingHide: (
        generation: Int,
        completion: (PanelHideCompletion) -> Void
    )?

    mutating func invalidatePendingTransition() {
        generation += 1
        resolvePendingHide(.superseded)
    }

    mutating func beginTransition() -> Int {
        generation += 1
        resolvePendingHide(.superseded)
        return generation
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
    private var needsResizeAfterShowing = false
    private var isLiveResizing = false
    private var isPersistingManualSize = false
    private var isApplyingInteractiveCorner = false
    private var isWindowDragging = false
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var visibilityTransition = PanelVisibilityTransitionState()
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
        // A reveal always supersedes an in-flight hide, even when its frame
        // already matches. This prevents that hide's completion from ordering
        // out a panel the user has just asked to see again.
        visibilityTransition.invalidatePendingTransition()
        let priorFrame = panel.frame
        currentScreen = screen
        currentCorner = corner
        hostingView.dockedCorner = corner
        updateResizeLimits(for: screen)
        startPointerPassthroughMonitoring()

        if isLiveResizing {
            if makeKey { panel.makeKey() }
            panel.orderFrontRegardless()
            animateShow(to: panel.frame)
            return
        }

        let finalFrame = frame(on: screen, corner: corner)

        if panel.isVisible {
            let localPriorFrame = PanelGeometry.constrainedFrame(priorFrame, to: screen.visibleFrame)
            let mustEstablishOnTargetDisplay = !framesMatch(priorFrame, localPriorFrame)

            if mustEstablishOnTargetDisplay {
                let localInitialFrame = PanelGeometry.hiddenFrame(
                    from: finalFrame,
                    corner: corner,
                    in: screen.visibleFrame
                )
                panel.alphaValue = 0
                panel.setFrame(localInitialFrame, display: true)
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
            in: screen.visibleFrame
        )
        panel.setFrame(initialFrame, display: true)
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.visibilityTransition.ownsCompletion(generation) else { return }
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

        // Destructive/transient presentation state changes only after the
        // persistence boundary accepts the hide transaction.
        canvasSession.cancelActiveInteraction()
        uiState.isCanvasConfirmationPresented = false
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowMove, isActive: false)
        uiState.setInteractionLock(.windowResize, isActive: false)
        let generation = visibilityTransition.beginHideTransition(completion: completion)
        isShowing = false
        needsResizeAfterShowing = false
        let safeFrame = PanelGeometry.constrainedFrame(panel.frame, to: screen.visibleFrame)
        if !framesMatch(panel.frame, safeFrame) {
            panel.setFrame(safeFrame, display: true)
        }
        let targetFrame = PanelGeometry.hiddenFrame(
            from: safeFrame,
            corner: currentCorner,
            in: screen.visibleFrame
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
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
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
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

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
            .sink { [weak self] _ in
                self?.recoverPanelInsideUsableArea()
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
        guard let screen = currentScreen else { return }
        guard !isLiveResizing, !panel.inLiveResize else { return }
        if isShowing {
            needsResizeAfterShowing = true
            return
        }
        let targetFrame = frame(
            on: screen,
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
        on screen: NSScreen,
        corner: ScreenCorner,
        configuredSize: CGSize? = nil
    ) -> CGRect {
        let size = PanelGeometry.clampedPanelSize(
            configuredSize
                ?? CGSize(width: settings.panelContentSize, height: settings.panelHeight),
            in: screen.visibleFrame
        )
        return PanelGeometry.panelFrame(
            in: screen.visibleFrame,
            size: size,
            corner: corner
        )
    }

    private func updateResizeLimits(for screen: NSScreen) {
        AtticPanelResizePolicy.configure(
            panel,
            maximumSize: PanelGeometry.resizeMaximumSize(in: screen.visibleFrame)
        )
    }

    private func applyAccessibilityResizeRequest(_ requestedSize: CGSize) {
        guard let screen = panel.screen ?? currentScreen else { return }
        currentScreen = screen
        updateResizeLimits(for: screen)
        let targetFrame = frame(
            on: screen,
            corner: currentCorner,
            configuredSize: requestedSize
        )
        panel.setFrame(targetFrame, display: panel.isVisible)
        uiState.updatePanelSize(targetFrame.size)

        isPersistingManualSize = true
        settings.persistPanelSize(targetFrame.size)
        isPersistingManualSize = false
    }

    private func applyAccessibilityMoveRequest(_ requestedFrame: CGRect) {
        guard let screen = bestScreen(for: requestedFrame) ?? panel.screen ?? currentScreen else {
            return
        }
        if currentScreen !== screen {
            currentScreen = screen
            updateResizeLimits(for: screen)
        }
        let targetFrame = PanelGeometry.constrainedFrame(
            requestedFrame,
            to: screen.visibleFrame
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
        visibilityTransition.invalidatePendingTransition()
        isShowing = false
        needsResizeAfterShowing = false
        isLiveResizing = true
        uiState.dockingPreviewCorner = nil
        uiState.setInteractionLock(.windowResize, isActive: true)
        panel.ignoresMouseEvents = false
    }

    private func endLiveResize(at finalSize: CGSize) {
        guard isLiveResizing else { return }
        isLiveResizing = false
        if let screen = panel.screen {
            currentScreen = screen
            updateResizeLimits(for: screen)
        }
        uiState.updatePanelSize(finalSize)

        // These publications are intentionally suppressed as frame commands:
        // AppKit has already reached this exact size and remains authoritative.
        isPersistingManualSize = true
        settings.persistPanelSize(finalSize)
        isPersistingManualSize = false
        uiState.setInteractionLock(.windowResize, isActive: false)
    }

    private func beginWindowDrag() {
        visibilityTransition.invalidatePendingTransition()
        isShowing = false
        needsResizeAfterShowing = false
        isWindowDragging = true
        uiState.setInteractionLock(.windowMove, isActive: true)
        panel.ignoresMouseEvents = false
    }

    private func updateWindowDrag(frame: CGRect, pointer: CGPoint) -> CGRect {
        guard let screen = screen(containing: pointer) ?? panel.screen ?? currentScreen else {
            return frame
        }
        if currentScreen !== screen {
            currentScreen = screen
            updateResizeLimits(for: screen)
        }
        let constrainedFrame = PanelGeometry.constrainedFrame(
            frame,
            to: screen.visibleFrame
        )
        let previewCorner = PanelDockingPolicy.nearestCorner(
            for: constrainedFrame,
            in: screen.visibleFrame
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
        updateResizeLimits(for: screen)
        let releaseAction = PanelDockingPolicy.releaseAction(
            velocity: velocity,
            translation: translation,
            attachedCorner: currentCorner,
            panelFrame: frame,
            in: screen.visibleFrame
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
                    from: frame,
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
            from: frame,
            on: screen,
            to: corner,
            persistsCorner: true,
            showsPreview: true
        )
    }

    private func animateDock(
        from frame: CGRect,
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

        let targetFrame = PanelGeometry.panelFrame(
            in: screen.visibleFrame,
            size: PanelGeometry.clampedPanelSize(frame.size, in: screen.visibleFrame),
            corner: corner
        )
        let generation = visibilityTransition.beginTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityTransition.ownsCompletion(generation) else { return }
                self.uiState.updatePanelSize(self.panel.frame.size)
                self.uiState.dockingPreviewCorner = nil
                self.uiState.setInteractionLock(.windowMove, isActive: false)
            }
        }
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

    private func recoverPanelInsideUsableArea() {
        guard let screen = bestScreen(for: panel.frame) ?? panel.screen ?? currentScreen else {
            return
        }
        currentScreen = screen
        updateResizeLimits(for: screen)

        let targetFrame: CGRect
        if isWindowDragging || isLiveResizing {
            targetFrame = PanelGeometry.constrainedFrame(panel.frame, to: screen.visibleFrame)
        } else {
            targetFrame = frame(on: screen, corner: currentCorner)
        }
        if !framesMatch(panel.frame, targetFrame) {
            panel.setFrame(targetFrame, display: panel.isVisible)
        }
        uiState.updatePanelSize(targetFrame.size)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        recoverPanelInsideUsableArea()
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
