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

/// What an explicit reveal did.
enum PanelRevealOutcome: Equatable {
    case shown
    case refused(PanelRevealRefusal)
}

enum PanelRevealRefusal: Equatable {
    /// No display to show the panel on.
    case noScreen
    /// The open note could not be saved, so the page did not change.
    case unsavedNote
    /// The display has no usable area for the panel.
    case noUsableScreenArea

    var explanation: String {
        switch self {
        case .noScreen: "no display is available for the Attic panel."
        case .unsavedNote: "the note open in Attic could not be saved, so the panel stayed on it. Nothing was moved."
        case .noUsableScreenArea: "the display has no room for the Attic panel right now."
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
    /// The frames of the displays whose corner answers hover (all of them,
    /// the chosen ones, or none when hover is off): the sampling cadence
    /// is responsive only near those corners.
    private var cachedScreenFrames: [CGRect] = []
    /// Every display's frame and identifier, read when displays change.
    private var cachedScreens: [(frame: CGRect, id: String?)] = []
    /// The hover rule (Settings › Panel › Corner), read when it changes.
    private var revealPolicy = CornerRevealPolicy()
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var screenChangeToken: NSObjectProtocol?
    private var spaceChangeToken: NSObjectProtocol?
    private var cornerObservation: AnyCancellable?
    private var dismissModeObservation: AnyCancellable?
    private var responsivenessActivity: NSObjectProtocol?
    private var revealRefreshTask: Task<Void, Never>?
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
    private var sizeObservation: AnyCancellable?
    private var hideObservation: AnyCancellable?
    private var lockSampleScheduled = false
    /// The watched hotspot the pointer has rested in since the latest hide
    /// began; the one thing the exit latch reads (CORNER-REVEAL-MISS).
    private var restingHotspot = CornerHoverRestingHotspot()
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
            hideCompleted()
        }
        panelController.onOutsidePress = { [weak self] location, window in self?.outsidePress(at: location, in: window) }
        panelController.onHideBegan = { [weak self] in self?.hideBegan() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        IdleLatencyTrace.startMonitoring()
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
        spaceChangeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // WindowServer changes Space membership independently of mouse
            // delivery. Reconcile on the next turn, after that change lands.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.refreshCachedScreenFrames()
                self.samplePointer()
                guard self.stateMachine.isVisible, !self.stateMachine.isHidePending else { return }
                self.panelController.reassertPresentationAfterSpaceChange()
            }
        }
        // The corner and the hover rule (control audit item 10): a change
        // re-reads which corners answer and samples once.
        cornerObservation = Publishers.MergeMany(
            settings.$corner.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$revealOnHover.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$revealModifier.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$revealDisplays.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$revealDisplayIDs.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        // @Published sends before the value is stored: read it next turn.
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self, isRunning else { return }
            refreshCachedScreenFrames()
            samplingState = CornerHoverSamplingState()
            samplePointer()
        }
        dismissModeObservation = settings.$panelDismissMode.dropFirst().removeDuplicates()
            // @Published sends before the assignment. Read the new choice
            // after it has landed and cancel any old cursor-hide deadline.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.samplePointer()
            }
        // Locks and the pin are the other inputs to the auto-hide decision.
        // With no timer while visible, a change to either re-samples once on
        // the next turn (coalesced across a burst of publications).
        lockObservation = uiState.objectWillChange
            .sink { [weak self] _ in self?.scheduleLockSample() }
        // The panel's size is an input as well: a shrink that is no pointer
        // drag (an accessibility client, a display change) can leave a
        // resting pointer outside the panel, and a resting pointer sends no
        // event. The size is not published state, so the same coalesced
        // sample wakes from the settled size: every size write outside a
        // drag, and a drag's end.
        sizeObservation = uiState.settledPanelSize.$value.dropFirst()
            .sink { [weak self] _ in self?.scheduleLockSample() }

        // A controller-owned hide can complete before the deferred Space
        // observer (notably with Reduced Motion). Native hide completion is
        // authoritative even when the request did not come from this monitor.
        // A monitor-owned request must instead finish through its registered
        // callback: replacing its pending state here would discard that
        // callback's reset and swallow the next corner entry with an exit latch.
        hideObservation = uiState.$hideCount.dropFirst().sink { [weak self] _ in
            guard let self, self.isRunning, !self.stateMachine.isHidePending else { return }
            self.hideCompleted()
        }

        panelController.buildTasksPageWhenIdle()

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
        if let screenChangeToken { NotificationCenter.default.removeObserver(screenChangeToken) }
        screenChangeToken = nil
        if let spaceChangeToken { NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeToken) }
        spaceChangeToken = nil
        cornerObservation = nil
        dismissModeObservation = nil
        lockObservation = nil
        sizeObservation = nil
        hideObservation = nil
        trailingSampleWork?.cancel()
        trailingSampleWork = nil
        followUpWork?.cancel()
        followUpWork = nil
        panelController.endCornerFirstTouchWarmup()
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
    ///
    /// Returns whether the panel now shows the requested page. A refusal
    /// changes nothing: a Notes draft that could not be saved keeps its
    /// page, and no reveal starts.
    @discardableResult
    func revealProgrammatically(
        openComposer: Bool = false,
        section: PanelSection? = nil,
        takesKeyboard: Bool = true,
        focusesAddBar: Bool = true
    ) -> PanelRevealOutcome {
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else {
            return .refused(.noScreen)
        }
        if let refusal = preparePresentation(openComposer: openComposer, section: section) {
            return .refused(refusal)
        }
        IdleLatencyTrace.begin("explicit_reveal", original: nil,
                               context: panelController.idleLatencyContext(activity: responsivenessActivity != nil))
        PerformanceSignposts.beginReveal()
        refreshStoreForReveal()
        let wasVisible = stateMachine.isVisible
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 3)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        guard panelController.show(on: screen, corner: settings.corner, makeKey: takesKeyboard) else {
            if !wasVisible { stateMachine.forceHidden() }
            refreshSamplingCadence(at: NSEvent.mouseLocation)
            return .refused(.noUsableScreenArea)
        }
        if takesKeyboard, focusesAddBar, uiState.selectedSection.isTaskBased {
            uiState.requestPrimaryInputFocus()
        }
        return .shown
    }

    /// Keep the real panel on screen through a performance sample, including
    /// a section change made while it is already visible.
    func revealForPerformanceProbe(section: PanelSection) {
        guard let screen = Self.uiTestingScreen,
              preparePresentation(openComposer: false, section: section) == nil else { return }
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
            if outcome == .hidden { self?.hideCompleted() }
            completion(outcome)
        }
    }

    func keepVisibleForUITesting(openComposer: Bool = false, makeKey: Bool = true) {
        guard let screen = Self.uiTestingScreen else { return }
        guard preparePresentation(openComposer: openComposer, section: nil) == nil else { return }
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 86_400)
        refreshSamplingCadence(at: NSEvent.mouseLocation)
        panelController.show(on: screen, corner: settings.corner, makeKey: makeKey)
    }

    /// Moves to the target page (and opens its composer) before a reveal.
    /// Returns why it could not, having changed nothing, or nil.
    private func preparePresentation(
        openComposer: Bool,
        section: PanelSection?
    ) -> PanelRevealRefusal? {
        let targetSection = section ?? uiState.selectedSection

        if targetSection != uiState.selectedSection, uiState.routeElsewhere(targetSection) {
            // Its page is out in its own panel, which came forward.
        } else if targetSection != uiState.selectedSection {
            if uiState.selectedSection.isNotes {
                guard noteDraft.prepareToLeave(.pageSwitch) else { return .unsavedNote }
            }
            PerformanceSignposts.beginPageSwitch()
            // The shell's one switch (A20): sprung like any other while the
            // panel shows, at once before a reveal from hidden.
            let motion = panelController.isPanelVisible
                ? PanelPageMotion.current(reduceMotion: AtticMotionPreference.reducesMotion) : .instant
            uiState.switchPage(to: targetSection, motion: motion)
        }

        guard openComposer else { return nil }
        if targetSection.isNotes {
            // The new Notes page: New Note always starts a fresh draft.
            guard noteDraft.pages.requestNewNote() else {
                PerformanceSignposts.cancelPageSwitch()
                return .unsavedNote
            }
            return nil
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { uiState.beginAdding() }
        return nil
    }

    private func samplePointer(at requestedLocation: CGPoint? = nil,
                               uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let location = requestedLocation ?? pointerLocationForTesting ?? NSEvent.mouseLocation
        sampleCount += 1
        lastEventSampleAt = uptime
        defer { refreshSamplingCadence(at: location) }
        restingHotspot.pointerObserved(at: location)
        let activeScreen = screen(containing: location)
        let activeFrame = screenFrame(of: activeScreen, at: location)
        // When the cursor is pinned against a screen edge, mouseLocation sits exactly on
        // the frame boundary (e.g. y == maxY at the top), which CGRect.contains excludes.
        // Expand the hotspot outward so edge-pinned coordinates still count as inside.
        // Only a corner that answers hover, with the chosen key held now
        // (Settings › Panel › Corner; control audit item 10).
        let isInHotspot = activeFrame.map {
            revealPolicy.reveals(displayID: $0.id, flags: NSEvent.modifierFlags)
                && PanelGeometry.hotspot(in: $0.frame, corner: settings.corner)
                    .insetBy(dx: -1, dy: -1)
                    .contains(location)
        } ?? false
        // Mouse passthrough and resize cursors belong to the panel
        // controller's own pointer monitors, which run only while the panel
        // is visible; sampling here must not duplicate that work.
        let isInPanel = panelController.containsScreenPoint(location)
        let isMouseButtonPressed = NSEvent.pressedMouseButtons != 0

        let isInteractionLocked = MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: uiState.interactionLockReasons.union(panelController.floatingInteractionLockReasons),
            pointerInside: isInPanel,
            secondsSinceKeyboardInput: uptime - lastKeyboardInputAt
        ) || isMouseButtonPressed
        let hadRevealDeadline = stateMachine.nextRevealDeadline(revealDelay: settings.revealDelay) != nil
        let transition = stateMachine.update(
            at: uptime,
            isInHotspot: isInHotspot,
            isInPanel: isInPanel,
            isInteractionLocked: isInteractionLocked,
            isPinned: uiState.isPanelPinned,
            isRevealHeldByMenu: uiState.interactionLockReasons.contains(.menuTracking)
                || panelController.floatingInteractionLockReasons.contains(.menuTracking),
            revealDelay: settings.revealDelay,
            hideDelay: settings.hideDelay,
            dismissMode: settings.panelDismissMode
        )
        let hasRevealDeadline = stateMachine.nextRevealDeadline(revealDelay: settings.revealDelay) != nil
        #if (ATTIC_FIRST_TOUCH_LOG || ATTIC_MEASURE) && ATTIC_LOCAL_ONLY && arch(arm64)
        if !hadRevealDeadline, hasRevealDeadline {
            IdleLatencyTrace.cornerHotspotEntered(revealDelay: settings.revealDelay)
        }
        #endif
        scheduleFollowUp(
            at: uptime, isInHotspot: isInHotspot, isInPanel: isInPanel,
            isInteractionLocked: isInteractionLocked, isMouseButtonPressed: isMouseButtonPressed
        )
        if hasRevealDeadline {
            panelController.beginCornerFirstTouchWarmup()
        } else if hadRevealDeadline {
            panelController.endCornerFirstTouchWarmup()
            panelController.cancelHiddenPagePreparation()
        }

        switch transition {
        case .none:
            break
        case .reveal:
            guard let activeScreen else { return }
            IdleLatencyTrace.point("reveal_decision")
            PerformanceSignposts.beginReveal()
            // Pull any CloudKit import out of SwiftData's context cache before
            // calculating the panel contents. This only runs on reveal, not on
            // the pointer sampling path.
            refreshStoreForReveal()
            panelController.show(on: activeScreen, corner: settings.corner)
            IdleLatencyTrace.point("view_dispatch_done")
        case .requestHide:
            let result = panelController.requestHide { [weak self] completion in
                guard let self else { return }
                stateMachine.resolveHideCompletion(
                    didOrderOut: completion == .hidden
                )
                let location = pointerLocationForTesting ?? NSEvent.mouseLocation
                refreshSamplingCadence(at: location)
                // A cursor-away hide never latches (the pointer leaving is
                // its reason). A pointer that arrived in a corner during it
                // still needs the one sample that starts its dwell; one that
                // has rested there since the hide began (an Option-to-reveal
                // corner with the key up, say) gets none, as with every
                // other hide.
                if completion == .hidden, !restingHotspot.holds(location) {
                    scheduleHideEndSample(at: location)
                }
            }
            if !result.isAccepted {
                stateMachine.resolveHideCompletion(didOrderOut: false)
            }
        }
    }

    private func outsidePress(at location: CGPoint, in window: NSWindow?) {
        guard isRunning else { return }
        let isInside = panelController.containsScreenPoint(location) || Self.isAtticOwnedWindow(window)
        let locked = MainPanelAutoHidePolicy.isInteractionLocked(
            reasons: uiState.interactionLockReasons.union(panelController.floatingInteractionLockReasons),
            pointerInside: isInside,
            secondsSinceKeyboardInput: ProcessInfo.processInfo.systemUptime - lastKeyboardInputAt
        )
        guard MainPanelAutoHidePolicy.shouldDismissPress(
            isVisible: panelController.isPanelVisible,
            isPinned: uiState.isPanelPinned,
            mode: settings.panelDismissMode,
            isWithinPanelFamily: isInside,
            isInteractionLocked: locked,
            hasOpenMenu: AtticGlassMenu.current?.isOpen == true
        ) else { return }

        followUpWork?.cancel()
        followUpWork = nil
        stateMachine.beginOutsidePressHide()
        let result = panelController.requestHide { [weak self] outcome in
            guard let self else { return }
            self.stateMachine.resolveHideCompletion(didOrderOut: outcome == .hidden)
            if outcome == .hidden {
                self.hideCompleted()
            } else {
                self.refreshSamplingCadence(at: NSEvent.mouseLocation)
            }
        }
        if !result.isAccepted { stateMachine.resolveHideCompletion(didOrderOut: false) }
    }

    /// Local mouse-down events carry their AppKit window; the pointer can be
    /// far outside the panel while the click is in Settings, a sheet, alert,
    /// popover or another Attic-owned card. Global clicks carry no window.
    /// A hide is beginning (`AtticPanelController.onHideBegan`): note the
    /// watched hotspot the pointer rests in now, or none.
    private func hideBegan() {
        let location = pointerLocationForTesting ?? NSEvent.mouseLocation
        restingHotspot.hideBegan(in: watchedHotspot(containing: location))
    }

    /// A hide that did not come from the pointer leaving (click away, Esc,
    /// menu, swipe, probe) has ordered the panel out.
    ///
    /// The exit latch keeps the hide from re-revealing under a pointer that
    /// has rested in the corner since the hide began, so it is set only
    /// while `restingHotspot` still holds the pointer. That state is set
    /// when the hide begins and cleared by any pointer event or sample
    /// outside it, before coalescing, so a pointer that was elsewhere at
    /// the start, left during the hide or moved to another display's corner
    /// is an approach. (Hidden and far from the corner no sample runs, so a
    /// latch set for an approach could only clear on a second entry.) The
    /// read does not consume it: a swipe or Esc completes twice, through
    /// the `hideCount` sink and `onInteractiveHideCompleted`.
    private func hideCompleted() {
        let location = pointerLocationForTesting ?? NSEvent.mouseLocation
        let latched = restingHotspot.holds(location)
        stateMachine.forceHidden(untilHotspotExit: latched)
        refreshSamplingCadence(at: location)
        // Latched, no sample: as on the trunk, so nothing at the hide's end
        // (a key not held, say) can release the latch of a resting pointer.
        guard !latched else { return }
        scheduleHideEndSample(at: location)
    }

    /// A pointer resting in the hotspot as a hide ends sends no more events,
    /// so one sample starts its reveal dwell. It runs on the next turn,
    /// outside the hide's completion, so even a zero reveal delay cannot
    /// show the panel from inside it.
    private func scheduleHideEndSample(at location: CGPoint) {
        guard watchedHotspot(containing: location) != nil else { return }
        followUpWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.stateMachine.isVisible else { return }
            self.followUpWork = nil
            self.samplePointer()
        }
        followUpWork = work
        DispatchQueue.main.async(execute: work)
    }

    /// The hotspot of a watched display (one whose corner answers hover, so
    /// it is in `cachedScreenFrames` and samples near the corner) that holds
    /// `location`, with the same 1 pt edge allowance as a sample; nil when
    /// none does. The key is left out: a pointer resting in the corner
    /// latches whether or not it is held. An unwatched corner never
    /// reveals, so it needs no latch, and one set there would sit under an
    /// idle cadence and block the next watched corner.
    private func watchedHotspot(containing location: CGPoint) -> CGRect? {
        guard let screen = screenFrame(containing: location),
              revealPolicy.answers(displayID: screen.id) else { return nil }
        let hotspot = PanelGeometry.hotspot(in: screen.frame, corner: settings.corner).insetBy(dx: -1, dy: -1)
        return hotspot.contains(location) ? hotspot : nil
    }

    private static func isAtticOwnedWindow(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if NSApp.windows.contains(where: { $0 === current }) { return true }
            candidate = current.parent
        }
        return false
    }

    private func pointerActivityObserved(at location: CGPoint, eventTimestamp: TimeInterval? = nil) {
        guard isRunning else { return }
        // Before the cadence guard and the coalescing: an exit delivered
        // inside one coalescing interval still counts as leaving.
        restingHotspot.pointerObserved(at: location)
        #if (ATTIC_FIRST_TOUCH_LOG || ATTIC_MEASURE) && ATTIC_LOCAL_ONLY && arch(arm64)
        let callbackNS = DispatchTime.now().uptimeNanoseconds
        #endif
        let decision = samplingState.update(
            pointer: location,
            screenFrames: cachedScreenFrames,
            corner: settings.corner,
            isPanelVisible: stateMachine.isVisible
        )
        let cadenceChanged = decision.cadence != scheduledCadence
        // This describes the state on entry, before the callback can acquire an activity.
        let activityAtEntry = responsivenessActivity != nil
        applySamplingCadence(decision.cadence)
        if cadenceChanged, decision.cadence == .responsive, !stateMachine.isVisible {
            #if (ATTIC_FIRST_TOUCH_LOG || ATTIC_MEASURE) && ATTIC_LOCAL_ONLY && arch(arm64)
            IdleLatencyTrace.begin("corner_approach", original: eventTimestamp,
                                   context: panelController.idleLatencyContext(activity: activityAtEntry),
                                   receivedNS: callbackNS)
            IdleLatencyTrace.point("handler_entered")
            #endif
        }
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
    /// Visible, every lock change samples. Hidden, only a reveal an open
    /// menu is holding does: not every hidden lock change, because
    /// `objectWillChange` also fires for `hideCount` one turn after each
    /// hide, and a sample there could release an exit latch just set.
    private func scheduleLockSample() {
        guard isRunning, samplesOnLockChange, !lockSampleScheduled else { return }
        lockSampleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lockSampleScheduled = false
            guard self.isRunning, self.samplesOnLockChange else { return }
            self.samplePointer()
        }
    }

    private var samplesOnLockChange: Bool { stateMachine.isVisible || stateMachine.isRevealWaitingOnMenu }

    /// The only timed work: a single follow-up at the next decision
    /// deadline. Hidden, that is the reveal delay of a pointer resting in the
    /// hotspot (it sends no more events). Visible, it is normally the hide
    /// delay or reveal grace; clean editor focus also gets one deadline
    /// because keyboard-idle time can expire that lock without another event.
    /// Persistent locks and pins remain event-driven (see
    /// `scheduleLockSample`), and a pressed button is followed by its
    /// mouse-up event.
    private func scheduleFollowUp(
        at uptime: TimeInterval, isInHotspot: Bool, isInPanel: Bool,
        isInteractionLocked: Bool, isMouseButtonPressed: Bool
    ) {
        followUpWork?.cancel()
        followUpWork = nil
        guard stateMachine.isVisible else {
            if let deadline = stateMachine.nextRevealDeadline(revealDelay: settings.revealDelay) {
                onVisibilityChangeExpected?((hiding: false, delay: deadline - uptime))
                scheduleFollowUp(after: deadline - uptime)
            } else {
                onVisibilityChangeExpected?(nil)
            }
            return
        }
        let isPinned = uiState.isPanelPinned
        guard !stateMachine.isHidePending,
              !isMouseButtonPressed, !isPinned else { onVisibilityChangeExpected?(nil); return }
        let stateDeadline = stateMachine.nextTimedDecision(
            at: uptime, isInHotspot: isInHotspot, isInPanel: isInPanel,
            isInteractionLocked: isInteractionLocked, isPinned: isPinned, hideDelay: settings.hideDelay,
            dismissMode: settings.panelDismissMode
        )
        // Away from the panel and the corner, nothing holding it open: the
        // panel hides at that deadline unless the pointer comes back.
        onVisibilityChangeExpected?(stateDeadline.map { (hiding: true, delay: $0 - uptime) })
        let focusDeadline = (settings.panelDismissMode == .moveCursorAway || stateMachine.canHideOnCursorExitInClickAwayMode)
            ? MainPanelAutoHidePolicy.focusExpirationDeadline(
                reasons: uiState.interactionLockReasons,
                pointerInside: isInPanel,
                lastKeyboardInputAt: lastKeyboardInputAt,
                timestamp: uptime
            ) : nil
        guard let deadline = [stateDeadline, focusDeadline].compactMap({ $0 }).min() else { return }
        scheduleFollowUp(after: deadline - uptime)
    }

    private func scheduleFollowUp(after delay: TimeInterval) {
        let due = ProcessInfo.processInfo.systemUptime + max(0.01, delay) + 0.02
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.followUpWork = nil
            IdleLatencyTrace.followUpFired(scheduled: due)
            self.samplePointer()
        }
        followUpWork = work
        followUpCountForTesting += 1
        IdleLatencyTrace.followUpScheduled(at: due)
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
        let leavingResponsiveCorner = scheduledCadence == .responsive && cadence != .responsive
        scheduledCadence = cadence
        if leavingResponsiveCorner { panelController.cancelHiddenPagePreparation() }
        updateResponsivenessActivity(for: cadence)
        if cadence == .responsive {
            // Near the corner of a hidden panel: build its pages during the
            // reveal delay (once; released again if no reveal follows).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.scheduledCadence == .responsive else { return }
                self.panelController.preparePagesForReveal()
            }
        }
    }

    /// Test seam: how many one-shot follow-ups were scheduled.
    private(set) var followUpCountForTesting = 0
    /// Test seam: how many times the monitor has looked a point's screen up
    /// in `NSScreen.screens`.
    private(set) var screenLookupCountForTesting = 0
    /// A timed reveal (`hiding` false) or hide is due in `delay` seconds
    /// unless the pointer changes course; nil when none is. The panel uses
    /// it to prepare a hide animation's snapshot ahead of the motion.
    var onVisibilityChangeExpected: (((hiding: Bool, delay: TimeInterval)?) -> Void)?

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
        cachedScreens = screensForTesting ?? NSScreen.screens.map { ($0.frame, AtticDisplay.identifier(for: $0)) }
        revealPolicy = settings.cornerRevealPolicy
        cachedScreenFrames = cachedScreens.filter { revealPolicy.answers(displayID: $0.id) }.map(\.frame)
    }

    /// The screen a test launch shows the panel on: the key screen, unless
    /// `ATTIC_UI_TEST_DISPLAY` names one ("external" for the first screen that
    /// isn't built in, or a display UUID), so on-screen checks can stay off
    /// the display the owner is working on.
    static var uiTestingScreen: NSScreen? {
        let request = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_DISPLAY"] ?? ""
        guard !request.isEmpty else { return NSScreen.main }
        let named = NSScreen.screens.first { screen in
            if request == "external" {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
            }
            return AtticDisplay.identifier(for: screen) == request
        }
        return named ?? NSScreen.main
    }

    /// The identifier of the display at `screen`'s frame, from the cache.
    private func displayID(of screen: NSScreen) -> String? {
        cachedScreens.first { $0.frame == screen.frame }?.id ?? AtticDisplay.identifier(for: screen)
    }

    /// Test seams: the frames whose corners answer hover, and the rule.
    var hoverScreenFramesForTesting: [CGRect] { cachedScreenFrames }
    var revealPolicyForTesting: CornerRevealPolicy { revealPolicy }
    /// Test seam: one pointer sample at `location`, as an event would run it.
    func sampleForTesting(at location: CGPoint, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        samplePointer(at: location, uptime: uptime)
    }
    func pointerActivityForTesting(at location: CGPoint) { pointerActivityObserved(at: location) }
    /// Test seam: where the monitor's own samples (follow-ups, lock
    /// changes, a hide's end) read the pointer; nil reads the real pointer.
    var pointerLocationForTesting: CGPoint?
    /// Test seam: the displays the monitor's sampling and latch read, as
    /// (frame, id); nil reads `NSScreen.screens`. Set it before `start()`.
    /// Showing the panel always uses a real `NSScreen`.
    var screensForTesting: [(frame: CGRect, id: String?)]?
    /// Test seam: whether a pointer at `location` counts as in the hotspot
    /// with `flags` held, as a sample decides it.
    func isInHotspotForTesting(_ location: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        guard let screen = screenFrame(containing: location) else { return false }
        return revealPolicy.reveals(displayID: screen.id, flags: flags)
            && PanelGeometry.hotspot(in: screen.frame, corner: settings.corner).insetBy(dx: -1, dy: -1).contains(location)
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
                self?.pointerActivityObserved(at: NSEvent.mouseLocation, eventTimestamp: event.timestamp)
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            // AppKit delivers global event-monitor callbacks on the main thread.
            // The handler only runs the cheap cadence state until a boundary
            // crossing requests one immediate full sample.
            MainActor.assumeIsolated {
                self?.pointerActivityObserved(at: NSEvent.mouseLocation, eventTimestamp: event.timestamp)
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

    /// The display holding `point` as (frame, id), for the latch and the
    /// test seam: from `screensForTesting` when a test sets it, else the
    /// one `screen(containing:)` lookup with its id from `displayID(of:)`.
    private func screenFrame(containing point: CGPoint) -> (frame: CGRect, id: String?)? {
        if screensForTesting != nil { return screenFrame(of: nil, at: point) }
        return screenFrame(of: screen(containing: point), at: point)
    }

    /// `screen`, already looked up by the caller for `point`, as (frame, id):
    /// a miss stays a miss, with no second lookup. With `screensForTesting`
    /// set, its stand-ins answer instead (the same 1 pt fallback).
    private func screenFrame(of screen: NSScreen?, at point: CGPoint) -> (frame: CGRect, id: String?)? {
        if let screensForTesting {
            return screensForTesting.first { NSMouseInRect(point, $0.frame, false) }
                ?? screensForTesting.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
        }
        return screen.map { ($0.frame, displayID(of: $0)) }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        screenLookupCountForTesting += 1
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
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
