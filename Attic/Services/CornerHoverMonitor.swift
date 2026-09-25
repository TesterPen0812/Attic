import AppKit
import Combine
import SwiftUI

enum RevealRefreshPolicy: Equatable {
    /// Local-only builds: every writer runs in this process through the
    /// stores themselves, so the in-memory presentation is authoritative and
    /// a reveal reloads nothing. Imports (CloudKit) are the only reason to
    /// replace contexts on reveal, and they are dormant here.
    case inProcessAuthoritative
    case singleEventDrivenPass
    case eventDrivenPassWithRetry(after: Duration)

    static var current: Self {
        #if ATTIC_LOCAL_ONLY
        .inProcessAuthoritative
        #else
        .eventDrivenPassWithRetry(after: .milliseconds(900))
        #endif
    }

    var refreshesOnReveal: Bool { self != .inProcessAuthoritative }

    var retryDelay: Duration? {
        switch self {
        case .inProcessAuthoritative, .singleEventDrivenPass:
            nil
        case let .eventDrivenPassWithRetry(delay):
            delay
        }
    }

    var maximumPassCount: Int {
        switch self {
        case .inProcessAuthoritative: 0
        case .singleEventDrivenPass: 1
        case .eventDrivenPassWithRetry: 2
        }
    }
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
    private var scheduledCadence: CornerHoverSamplingCadence?
    private var cachedScreenFrames: [CGRect] = []
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var screenChangeToken: NSObjectProtocol?
    private var cornerObservation: AnyCancellable?
    private var responsivenessActivity: NSObjectProtocol?
    private var revealRefreshTask: Task<Void, Never>?
    private var dragReleaseTask: Task<Void, Never>?
    private var isRunning = false
    private var lastKeyboardInputAt: TimeInterval = -.infinity
    /// Sampling is event-driven: bursts of pointer events near the corner or
    /// over the visible panel are coalesced to one sample per
    /// `eventSampleInterval`, with a trailing sample so the last position is
    /// never missed.
    private var lastEventSampleAt: TimeInterval = -.infinity
    private var trailingSampleWork: DispatchWorkItem?
    /// The only timed work: one follow-up at the next decision deadline (the
    /// reveal delay while hidden, the hide delay while visible); see
    /// `scheduleFollowUp`.
    private var followUpWork: DispatchWorkItem?
    private var lockObservation: AnyCancellable?
    private var lockSampleScheduled = false
    private static let eventSampleInterval: TimeInterval = 1.0 / 30
    /// Test seam: how many full pointer samples ran.
    private(set) var sampleCount = 0
    var isHiddenForPerformanceProbe: Bool { !stateMachine.isVisible }

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
        // Locks and the pin are the other inputs to the auto-hide decision.
        // With no timer while visible, a change to either re-samples once on
        // the next turn (coalesced across a burst of publications).
        lockObservation = uiState.objectWillChange
            .sink { [weak self] _ in self?.scheduleLockSample() }

        // Establish the initial cadence synchronously. A pointer already near
        // the configured corner gets the responsive path immediately; hidden
        // and far starts at the coalesced idle cadence without an activity hold.
        samplePointer()
    }

    func stop() {
        isRunning = false
        scheduledCadence = nil
        stopPointerActivityMonitoring()
        revealRefreshTask?.cancel()
        revealRefreshTask = nil
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        if let screenChangeToken { NotificationCenter.default.removeObserver(screenChangeToken) }
        screenChangeToken = nil
        cornerObservation = nil
        lockObservation = nil
        trailingSampleWork?.cancel()
        trailingSampleWork = nil
        followUpWork?.cancel()
        followUpWork = nil
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

    /// An explicit open (Show Attic, quick capture, New note, the Dock icon)
    /// takes the keyboard: the panel becomes key, and on Tasks the add bar
    /// is focused. `takesKeyboard: false` shows the panel without touching
    /// the keyboard (an agent's `show` while the user may be typing).
    func revealProgrammatically(
        openComposer: Bool = false,
        section: PanelSection? = nil,
        takesKeyboard: Bool = true
    ) {
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: section) else { return }
        PerformanceSignposts.beginReveal()
        refreshStoreForReveal()
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 3)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: takesKeyboard)
        if takesKeyboard, uiState.selectedSection.isTaskBased {
            uiState.requestPrimaryInputFocus()
        }
    }

    /// Keep the real panel on screen through a performance sample, including
    /// a section change made while it is already visible.
    func revealForPerformanceProbe(section: PanelSection) {
        guard let screen = NSScreen.main,
              preparePresentation(openComposer: false, section: section) else { return }
        PerformanceSignposts.beginReveal()
        refreshStoreForReveal()
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 86_400)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: true)
    }

    @discardableResult
    func hideForPerformanceProbe(
        completion: @escaping (PanelHideCompletion) -> Void
    ) -> PanelHideRequestResult {
        panelController.requestHide { [weak self] outcome in
            if outcome == .hidden {
                self?.stateMachine.forceHidden(untilHotspotExit: true)
                self?.refreshSamplingCadence(at: NSEvent.mouseLocation)
            }
            completion(outcome)
        }
    }

    func keepVisibleForUITesting(openComposer: Bool = false, makeKey: Bool = true) {
        guard let screen = NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: nil) else { return }
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 86_400)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: makeKey)
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
            PerformanceSignposts.beginPageSwitch()
            uiState.selectSection(targetSection)
        }

        guard openComposer else { return true }
        if targetSection.isNotes {
            guard noteDraft.beginNew() else {
                PerformanceSignposts.cancelPageSwitch()
                return false
            }
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { uiState.beginAdding() }
        return true
    }

    private func samplePointer(at location: CGPoint = NSEvent.mouseLocation) {
        sampleCount += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        lastEventSampleAt = uptime
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
        // Mouse passthrough and resize cursors belong to the panel
        // controller's own pointer monitors, which run only while the panel
        // is visible; sampling here must not duplicate that work.
        // The transient subtask surface extends "inside" coverage: the open
        // checklist is useless without its anchor, so hovering it keeps the
        // main panel alive. The pinned window is independent and excluded.
        let isInPanel = panelController.containsScreenPoint(location)
            || panelController.auxiliarySurfaceContains(location)
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

        let isInteractionLocked = MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: uiState.interactionLockReasons, pointerInside: isInPanel,
            secondsSinceKeyboardInput: uptime - lastKeyboardInputAt
        ) || isMouseButtonPressed
        let transition = stateMachine.update(
            at: uptime,
            isInHotspot: isInHotspot,
            isInPanel: isInPanel,
            isInteractionLocked: isInteractionLocked,
            isPinned: uiState.isPanelPinned,
            revealDelay: settings.revealDelay,
            hideDelay: settings.hideDelay
        )
        scheduleFollowUp(
            at: uptime, isInPanel: isInPanel, isInteractionLocked: isInteractionLocked,
            isMouseButtonPressed: isMouseButtonPressed
        )

        switch transition {
        case .none:
            break
        case .reveal:
            guard let activeScreen else { return }
            PerformanceSignposts.beginReveal()
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
        let cadenceChanged = decision.cadence != scheduledCadence
        applySamplingCadence(decision.cadence)
        guard decision.shouldSampleImmediately else { return }
        // A boundary crossing samples at once. Event-driven sampling while
        // visible coalesces bursts: one sample per interval plus a trailing
        // one, so a fast sweep costs a handful of hit tests, not hundreds.
        let now = ProcessInfo.processInfo.systemUptime
        if cadenceChanged || now - lastEventSampleAt >= Self.eventSampleInterval {
            trailingSampleWork?.cancel()
            trailingSampleWork = nil
            samplePointer(at: location)
        } else if trailingSampleWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                self.trailingSampleWork = nil
                self.samplePointer()
            }
            trailingSampleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventSampleInterval, execute: work)
        }
    }

    /// Locks and the pin changed: one coalesced sample on the next turn.
    private func scheduleLockSample() {
        guard isRunning, stateMachine.isVisible, !lockSampleScheduled else { return }
        lockSampleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockSampleScheduled = false
            guard self.isRunning, self.stateMachine.isVisible else { return }
            self.samplePointer()
        }
    }

    /// The only timed work: a single follow-up at the next decision
    /// deadline. Hidden, that is the reveal delay of a pointer resting in the
    /// hotspot (it sends no more events). Visible, it is normally the hide
    /// delay or reveal grace; clean editor focus also gets one deadline
    /// because keyboard-idle time can expire that lock without another event.
    /// Persistent locks and pins remain event-driven (see
    /// `scheduleLockSample`), and a pressed button is followed by its
    /// mouse-up event.
    private func scheduleFollowUp(
        at uptime: TimeInterval, isInPanel: Bool, isInteractionLocked: Bool, isMouseButtonPressed: Bool
    ) {
        followUpWork?.cancel()
        followUpWork = nil
        guard stateMachine.isVisible else {
            if let deadline = stateMachine.nextRevealDeadline(revealDelay: settings.revealDelay) {
                scheduleFollowUp(after: deadline - uptime)
            }
            return
        }
        let isPinned = uiState.isPanelPinned
        guard !stateMachine.isHidePending,
              !isMouseButtonPressed, !isPinned else { return }
        let stateDeadline = stateMachine.nextTimedDecision(
            at: uptime, isInPanel: isInPanel, isInteractionLocked: isInteractionLocked,
            isPinned: isPinned, hideDelay: settings.hideDelay
        )
        let focusDeadline = MainPanelAutoHidePolicy.focusExpirationDeadline(
            reasons: uiState.interactionLockReasons,
            pointerInside: isInPanel,
            lastKeyboardInputAt: lastKeyboardInputAt,
            timestamp: uptime
        )
        guard let deadline = [stateDeadline, focusDeadline].compactMap({ $0 }).min() else { return }
        scheduleFollowUp(after: deadline - uptime)
    }

    private func scheduleFollowUp(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.followUpWork = nil
            self.samplePointer()
        }
        followUpWork = work
        followUpCountForTesting += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay) + 0.02, execute: work)
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

    /// Records the cadence and holds the App Nap exemption only near the
    /// corner. No cadence starts a timer.
    private func applySamplingCadence(_ cadence: CornerHoverSamplingCadence) {
        guard isRunning, cadence != scheduledCadence else { return }
        scheduledCadence = cadence
        updateResponsivenessActivity(for: cadence)
    }

    var scheduledCadenceForTesting: CornerHoverSamplingCadence? { scheduledCadence }
    var holdsResponsivenessActivityForTesting: Bool { responsivenessActivity != nil }
    var hasPendingFollowUpForTesting: Bool { followUpWork != nil }
    /// Test seam: how many one-shot follow-ups were scheduled.
    private(set) var followUpCountForTesting = 0

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
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        // Mouse-up is included so a drag or press that ended away from the
        // panel is judged the moment it releases, with no timer.
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseUp
        ]
        // AppKit's monitor domains are complementary, not interchangeable:
        // local monitors cover Attic (including its tracking loops), while
        // global monitors cover pointer movement over other applications.
        // A hidden LSUIElement needs both regardless of activation state.
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union(.keyDown)) {
            [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    self?.lastKeyboardInputAt = ProcessInfo.processInfo.systemUptime
                    self?.followUpWork?.cancel()
                    self?.followUpWork = nil
                }
                self?.pointerActivityObserved(at: NSEvent.mouseLocation)
            }
            return event
        }
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

    private func stopPointerActivityMonitoring() {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
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
        guard RevealRefreshPolicy.current.refreshesOnReveal else { return }
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
