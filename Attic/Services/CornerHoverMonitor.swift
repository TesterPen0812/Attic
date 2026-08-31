import AppKit
import Combine
import SwiftUI

enum RevealRefreshPolicy: Equatable {
    case singleEventDrivenPass
    case eventDrivenPassWithRetry(after: Duration)

    static var current: Self {
        #if ATTIC_LOCAL_ONLY
        .singleEventDrivenPass
        #else
        .eventDrivenPassWithRetry(after: .milliseconds(900))
        #endif
    }

    var retryDelay: Duration? {
        switch self {
        case .singleEventDrivenPass:
            nil
        case let .eventDrivenPassWithRetry(delay):
            delay
        }
    }

    var maximumPassCount: Int { retryDelay == nil ? 1 : 2 }
}

@MainActor
final class CornerHoverMonitor {
    private let settings: AppSettings
    private let panelController: AtticPanelController
    private let uiState: PanelUIState
    private let store: TaskStore
    private let noteStore: NoteStore
    private let canvasStore: CanvasStore
    private let noteDraft: NoteDraftController

    private var stateMachine = CornerHoverStateMachine()
    private var samplingState = CornerHoverSamplingState()
    private var pollingTimer: DispatchSourceTimer?
    private var pollingTimerEpoch = CornerHoverTimerEpoch()
    private var scheduledCadence: CornerHoverSamplingCadence?
    private var cachedScreenFrames: [CGRect] = []
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var appActivationTokens: [NSObjectProtocol] = []
    private var screenChangeToken: NSObjectProtocol?
    private var cornerObservation: AnyCancellable?
    private var responsivenessActivity: NSObjectProtocol?
    private var revealRefreshTask: Task<Void, Never>?
    private var dragReleaseTask: Task<Void, Never>?
    private var isRunning = false

    init(
        settings: AppSettings,
        panelController: AtticPanelController,
        uiState: PanelUIState,
        store: TaskStore,
        noteStore: NoteStore,
        canvasStore: CanvasStore,
        noteDraft: NoteDraftController
    ) {
        self.settings = settings
        self.panelController = panelController
        self.uiState = uiState
        self.store = store
        self.noteStore = noteStore
        self.canvasStore = canvasStore
        self.noteDraft = noteDraft
        panelController.onInteractiveHideCompleted = { [weak self] in
            guard let self else { return }
            stateMachine.forceHidden(untilHotspotExit: true)
            refreshSamplingCadence(at: NSEvent.mouseLocation)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        samplingState = CornerHoverSamplingState()
        scheduledCadence = nil
        refreshCachedScreenFrames()
        startPointerActivityMonitoring()

        screenChangeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCachedScreenFrames()
                self?.samplePointer()
            }
        }
        cornerObservation = settings.$corner
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                samplingState = CornerHoverSamplingState()
                samplePointer()
            }

        // Establish the initial cadence synchronously. A pointer already near
        // the configured corner gets the responsive path immediately; hidden
        // and far starts at the coalesced idle cadence without an activity hold.
        samplePointer()
    }

    func stop() {
        isRunning = false
        pollingTimer?.cancel()
        pollingTimer = nil
        pollingTimerEpoch.invalidate()
        scheduledCadence = nil
        stopPointerActivityMonitoring()
        revealRefreshTask?.cancel()
        revealRefreshTask = nil
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        if let screenChangeToken { NotificationCenter.default.removeObserver(screenChangeToken) }
        screenChangeToken = nil
        cornerObservation = nil
        endResponsivenessActivity()
        let hideResult = panelController.requestHide { [weak self] completion in
            guard let self else { return }
            if completion == .hidden {
                stateMachine.forceHidden()
            } else {
                stateMachine.resolveHideCompletion(didOrderOut: false)
            }
        }
        if !hideResult.isAccepted {
            stateMachine.resolveHideCompletion(didOrderOut: false)
        }
    }

    func revealProgrammatically(openComposer: Bool = false, section: PanelSection? = nil) {
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: section) else { return }
        refreshStoreForReveal()
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 3)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: openComposer)
    }

    func keepVisibleForUITesting(openComposer: Bool = false) {
        guard let screen = NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: nil) else { return }
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 86_400)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: true)
    }

    private func preparePresentation(
        openComposer: Bool,
        section: PanelSection?
    ) -> Bool {
        let targetSection = section ?? uiState.selectedSection

        if targetSection != uiState.selectedSection {
            if uiState.selectedSection.isNotes, noteDraft.isActive {
                guard noteDraft.close() else { return false }
            }
            uiState.selectSection(targetSection)
        }

        guard openComposer else { return true }
        if targetSection.isNotes {
            guard noteDraft.beginNew() else { return false }
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { uiState.beginAdding() }
        return true
    }

    private func samplePointer(at location: CGPoint = NSEvent.mouseLocation) {
        defer { refreshSamplingCadence(at: location) }
        let activeScreen = screen(containing: location)
        // When the cursor is pinned against a screen edge, mouseLocation sits exactly on
        // the frame boundary (e.g. y == maxY at the top), which CGRect.contains excludes.
        // Expand the hotspot outward so edge-pinned coordinates still count as inside.
        let isInHotspot = activeScreen.map {
            PanelGeometry.hotspot(in: $0.frame, corner: settings.corner)
                .insetBy(dx: -1, dy: -1)
                .contains(location)
        } ?? false
        panelController.updateMousePassthrough(at: location)
        let isInPanel = panelController.containsScreenPoint(location)
        let isMouseButtonPressed = NSEvent.pressedMouseButtons != 0
        if isMouseButtonPressed {
            dragReleaseTask?.cancel()
            dragReleaseTask = nil
        } else if uiState.isDraggingTask, dragReleaseTask == nil {
            // SwiftUI dispatches performDrop just after mouse-up. Give an
            // in-panel destination a short chance to consume draggedTaskID
            // before treating the release as a cancelled or external drag.
            dragReleaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                let releasedInPanel = panelController.containsScreenPoint(NSEvent.mouseLocation)
                if let draggedTaskID = uiState.finishDragging(
                    releasedOutsidePanel: !releasedInPanel
                ) {
                    store.startAfterExternalDrag(taskID: draggedTaskID)
                }
                dragReleaseTask = nil
            }
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let transition = stateMachine.update(
            at: uptime,
            isInHotspot: isInHotspot,
            isInPanel: isInPanel,
            isInteractionLocked: uiState.isInteractionLocked || isMouseButtonPressed,
            isPinned: uiState.isPanelPinned,
            revealDelay: settings.revealDelay,
            hideDelay: settings.hideDelay
        )

        switch transition {
        case .none:
            break
        case .reveal:
            guard let activeScreen else { return }
            // Pull any CloudKit import out of SwiftData's context cache before
            // calculating the panel contents. This only runs on reveal, not on
            // the pointer sampling path.
            refreshStoreForReveal()
            panelController.show(on: activeScreen, corner: settings.corner)
        case .requestHide:
            let result = panelController.requestHide { [weak self] completion in
                guard let self else { return }
                stateMachine.resolveHideCompletion(
                    didOrderOut: completion == .hidden
                )
                refreshSamplingCadence(at: NSEvent.mouseLocation)
            }
            if !result.isAccepted {
                stateMachine.resolveHideCompletion(didOrderOut: false)
            }
        }
    }

    private func pointerActivityObserved(at location: CGPoint) {
        guard isRunning else { return }
        let decision = samplingState.update(
            pointer: location,
            screenFrames: cachedScreenFrames,
            corner: settings.corner,
            isPanelVisible: stateMachine.isVisible
        )
        applySamplingCadence(decision.cadence)
        guard decision.shouldSampleImmediately else { return }
        samplePointer(at: location)
    }

    private func refreshSamplingCadence(at location: CGPoint) {
        guard isRunning else { return }
        let decision = samplingState.update(
            pointer: location,
            screenFrames: cachedScreenFrames,
            corner: settings.corner,
            isPanelVisible: stateMachine.isVisible
        )
        applySamplingCadence(decision.cadence)
    }

    private func applySamplingCadence(_ cadence: CornerHoverSamplingCadence) {
        guard isRunning, cadence != scheduledCadence else { return }
        pollingTimer?.cancel()
        let timerEpoch = pollingTimerEpoch.beginTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(cadence.intervalMilliseconds),
            repeating: .milliseconds(cadence.intervalMilliseconds),
            leeway: .milliseconds(cadence.leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.pollingTimerEpoch.permits(
                        timerEpoch,
                        whileRunning: self.isRunning
                      ) else { return }
                self.samplePointer()
            }
        }
        pollingTimer = timer
        scheduledCadence = cadence
        updateResponsivenessActivity(for: cadence)
        timer.resume()
    }

    private func updateResponsivenessActivity(for cadence: CornerHoverSamplingCadence) {
        if cadence.holdsResponsivenessActivity {
            guard responsivenessActivity == nil else { return }
            responsivenessActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keep the configured Attic corner responsive"
            )
        } else {
            endResponsivenessActivity()
        }
    }

    private func endResponsivenessActivity() {
        guard let responsivenessActivity else { return }
        ProcessInfo.processInfo.endActivity(responsivenessActivity)
        self.responsivenessActivity = nil
    }

    private func refreshCachedScreenFrames() {
        cachedScreenFrames = NSScreen.screens.map(\.frame)
    }

    private func startPointerActivityMonitoring() {
        guard appActivationTokens.isEmpty else { return }
        installPointerActivityMonitor(
            scope: .required(isApplicationActive: NSApp.isActive)
        )
        let center = NotificationCenter.default
        appActivationTokens = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.installPointerActivityMonitor(scope: .local)
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.installPointerActivityMonitor(scope: .global)
                }
            }
        ]
    }

    private func installPointerActivityMonitor(
        scope: CornerHoverPointerMonitorScope
    ) {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        switch scope {
        case .local:
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
                [weak self] event in
                MainActor.assumeIsolated {
                    self?.pointerActivityObserved(at: NSEvent.mouseLocation)
                }
                return event
            }
        case .global:
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
                [weak self] _ in
                // AppKit delivers global event-monitor callbacks on the main thread.
                // The handler only runs the cheap cadence state until a boundary
                // crossing requests one immediate full sample.
                MainActor.assumeIsolated {
                    self?.pointerActivityObserved(at: NSEvent.mouseLocation)
                }
            }
        }
    }

    private func stopPointerActivityMonitoring() {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        appActivationTokens.forEach(NotificationCenter.default.removeObserver)
        appActivationTokens.removeAll()
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            // Edge-pinned pointer coordinates can land exactly on frame.maxX, outside
            // every screen frame; tolerate a 1 pt overshoot so corners keep working.
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func refreshStoreForReveal() {
        revealRefreshTask?.cancel()
        revealRefreshTask = nil
        store.refresh()
        noteStore.refresh()
        canvasStore.refresh()

        guard let retryDelay = RevealRefreshPolicy.current.retryDelay else {
            return
        }
        revealRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: retryDelay)
            guard let self, !Task.isCancelled else { return }
            self.store.refresh()
            self.noteStore.refresh()
            self.canvasStore.refresh()
        }
    }
}
