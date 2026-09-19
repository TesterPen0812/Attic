import AppKit
import Combine
import SwiftUI

/// Owns one deliberately opened transient surface (anchored to its row or
/// dragged away from it) and independently pinned family windows. Pointer
/// position never opens or closes a surface: rows open on click, keyboard,
/// VoiceOver or a menu command, and a transient stays until an outside
/// click, Escape, or an explicit close. Native surface behavior is
/// shared with future non-task content through PanelSurfaceWindow and
/// PanelSurfaceHostingView.
@MainActor
final class SubtaskPanelController: NSObject, ObservableObject {
    @Published private(set) var transientFamilyID: UUID?
    @Published private(set) var pinnedFamilyIDs: Set<UUID> = []
    @Published private var listHeights: [UUID: CGFloat] = [:]
    /// Which view each presented family shows. Kept out of this controller's
    /// own published state so a switch re-renders the panel, not every row.
    let panelViews = FamilyPanelViewState()

    private let store: TaskStore
    private let uiState: PanelUIState
    private let settings: AppSettings

    private var lifecycle = SubtaskPanelLifecycle()
    private weak var panelWindow: NSWindow?
    private weak var hostView: NSView?

    private typealias SurfaceHost = PanelSurfaceHostingView<SubtaskPanelContent>
    private var transientPanel: PanelSurfaceWindow?
    private var transientHost: SurfaceHost?
    private var pinnedSurfaces: [UUID: (window: PanelSurfaceWindow, host: SurfaceHost)] = [:]

    /// Row frames in the panel workspace coordinate space, republished on
    /// every scroll/layout pass by `TaskRowAnchorPreferenceKey`.
    private var rowFrames: [UUID: CGRect] = [:]
    /// The inline count control's frame per family, used to recognize the
    /// toggle's paired mousedown when it dismisses a latched surface.
    private var controlFrames: [UUID: CGRect] = [:]
    private var listViewport: CGRect = .null

    private var outsideClickMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
    /// Unit-test seams: the test host cannot order a real main panel
    /// onscreen, so tests steer visibility and suppress actual window work
    /// while still exercising the full lifecycle and lock plumbing.
    var mainPanelVisibleForTesting: Bool?
    var presentationEnabled = true
    /// Test seam: published row frames are treated as screen coordinates
    /// directly instead of being converted through a detached host view.
    var anchorsAreScreenCoordinatesForTesting = false
    private var mainPanelVisible: Bool {
        mainPanelVisibleForTesting ?? (panelWindow?.isVisible == true)
    }
    /// Guards the count-button toggle: an outside mouse-down dismisses the
    /// latched surface before the button's action fires, so reopening within
    /// the same click is suppressed. Bounded to the mousedown→mouseup window;
    /// cleared by every successful open so a stale record can't eat the next
    /// deliberate toggle.
    private var lastOutsideDismissal: (familyID: UUID, at: TimeInterval)?
    var surfaceCornerSize: CGFloat { CGFloat(settings.panelCornerSize) }

    init(store: TaskStore, uiState: PanelUIState, settings: AppSettings) {
        self.store = store
        self.uiState = uiState
        self.settings = settings
        super.init()

        store.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.reconcileStore() }
            .store(in: &cancellables)
        store.$errorNotice
            .dropFirst()
            .sink { [weak self] _ in
                // @Published emits in willSet — before the value stores —
                // and the hosting view applies it on its own pass. Fit on
                // the next turn, like noteMeasuredListHeight does.
                DispatchQueue.main.async { self?.refreshSurfaceSizes() }
            }
            .store(in: &cancellables)
        uiState.$selectedSection
            .dropFirst()
            .sink { [weak self] _ in self?.dismissTransient() }
            .store(in: &cancellables)
        // The lock must engage the moment a draft/focus change lands, so
        // these sinks hand the just-emitted values to syncComposerLock —
        // reading uiState here would lag one change behind.
        uiState.$subtaskDrafts
            .dropFirst()
            .sink { [weak self] drafts in
                guard let self else { return }
                self.syncComposerLock(
                    drafts: drafts,
                    focusedParentID: self.uiState.focusedSubtaskParentID
                )
            }
            .store(in: &cancellables)
        uiState.$focusedSubtaskParentID
            .dropFirst()
            .sink { [weak self] focused in
                guard let self else { return }
                self.syncComposerLock(
                    drafts: self.uiState.subtaskDrafts,
                    focusedParentID: focused
                )
            }
            .store(in: &cancellables)
        uiState.$subtaskEntryActiveIDs
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSurfaceSizes() }
            }
            .store(in: &cancellables)
        // The corner setting drives the surfaces' squircle radius and the
        // corner-aware content padding — a live change must re-fit both.
        settings.$panelCornerSize
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSurfaceSizes() }
            }
            .store(in: &cancellables)
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
            }
        )
    }

    /// Called once the main panel exists: the surfaces anchor to it and track
    /// its motion without ever becoming its child window (child windows would
    /// follow the parent's orderOut and break the pinned window's
    /// independent lifecycle).
    func attach(panel: NSWindow, hostView: NSView) {
        panelWindow = panel
        self.hostView = hostView
        // Panel move/resize re-anchoring comes through the main panel's
        // NSWindowDelegate (AtticPanelController calls mainPanelFrameDidChange)
        // — no duplicate observers here, or every drag would re-fit twice.
    }

    deinit {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Anchors

    /// `nil` when the family has no laid-out row, when that row has fully
    /// scrolled out of the list viewport, or when the main panel is hidden.
    private func screenAnchorRect(for familyID: UUID) -> CGRect? {
        if anchorsAreScreenCoordinatesForTesting {
            guard let row = rowFrames[familyID] else { return nil }
            if !listViewport.isNull, !row.intersects(listViewport) { return nil }
            return mainPanelVisible ? row : nil
        }
        guard let panel = panelWindow, panel.isVisible,
              let hostView,
              let row = rowFrames[familyID] else { return nil }
        if !listViewport.isNull, !row.intersects(listViewport) {
            return nil
        }
        return panel.convertToScreen(hostView.convert(row, to: nil))
    }

    /// The count control's frame in screen space — only its own mousedown
    /// can pair with the toggle's reopen after a dismissal.
    private func screenControlRect(for familyID: UUID) -> CGRect? {
        guard let frame = controlFrames[familyID] else { return nil }
        if anchorsAreScreenCoordinatesForTesting { return frame }
        guard let panel = panelWindow, let hostView else { return nil }
        return panel.convertToScreen(hostView.convert(frame, to: nil))
    }

    func noteSurfaceDragGeometry(
        _ geometry: PanelSurfaceDragGeometry,
        for familyID: UUID,
        mode: SubtaskPanelContent.Mode
    ) {
        guard isLiveSurface(for: familyID, mode: mode) else { return }
        if mode == .pinned {
            pinnedSurfaces[familyID]?.host.dragGeometry = geometry
        } else {
            transientHost?.dragGeometry = geometry
        }
    }

    func detachTransient() {
        lifecycle.detachTransient()
        syncState()
    }

    func updateSubtaskControlFrames(_ frames: [UUID: CGRect]) {
        controlFrames = frames
    }

    /// Row frames republish on every scroll/layout pass. Anchor tracking is
    /// coalesced to one reposition per run-loop turn, so a scroll that emits
    /// several preference updates per frame forces at most one layout pass
    /// on the hosted surface — and none at all while the frames are unchanged.
    func updateTaskRowFrames(_ frames: [UUID: CGRect]) {
        let changed = frames != rowFrames
        rowFrames = frames
        guard changed, !lifecycle.isTransientDetached, lifecycle.transientFamilyID != nil else { return }
        scheduleTransientReposition()
    }

    func updateTaskListViewport(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        let changed = rect != listViewport
        listViewport = rect
        guard changed, !lifecycle.isTransientDetached, lifecycle.transientFamilyID != nil else { return }
        scheduleTransientReposition()
    }

    private var transientRepositionScheduled = false

    private func scheduleTransientReposition() {
        guard !transientRepositionScheduled else { return }
        transientRepositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transientRepositionScheduled = false
            self.repositionTransient()
        }
    }

    /// Test seam: how many times the transient surface was actually re-fit
    /// and repositioned from anchor/viewport publications.
    private(set) var transientRepositionCount = 0

    private func resolvedParent(_ familyID: UUID) -> TaskItem? {
        guard let task = store.task(withID: familyID), task.parentID == nil else { return nil }
        return task
    }

    /// True while the family (its parent row or one of its children) has a
    /// rename or delete-confirmation in flight, or any context menu is being
    /// tracked. Such work is surface-owned: it protects the surface from
    /// pointer-position decisions but never blocks a deliberate close API.
    func familyEditBusy(_ familyID: UUID) -> Bool {
        func belongsToFamily(_ id: UUID?) -> Bool {
            guard let id else { return false }
            if id == familyID { return true }
            return store.task(withID: id)?.parentID == familyID
        }
        return belongsToFamily(uiState.editingTaskID)
            || belongsToFamily(uiState.confirmingTaskDeletionID)
            || belongsToFamily(uiState.confirmingTaskCompletionID)
            || belongsToFamily(uiState.presentedTaskAttachmentsID)
            || belongsToFamily(uiState.taskAttachmentPickerOwnerID)
    }

    var menuTrackingActive: Bool {
        uiState.interactionLockReasons.contains(.menuTracking)
    }

    /// Whether that surface kind currently hosts the family. The content
    /// view consults this from its focus-teardown path: stale content after
    /// pin/unpin or a family swap must not clear
    /// `focusedSubtaskParentID` after the replacement surface already
    /// asserted it — AppKit's field-editor resignation is not synchronous
    /// with `orderOut`, so the stale resign can otherwise land after the
    /// controller's re-focus bump and leave the new entry unfocused.
    func isLiveSurface(for familyID: UUID, mode: SubtaskPanelContent.Mode) -> Bool {
        switch mode {
        case .transient: return lifecycle.transientFamilyID == familyID
        case .pinned: return lifecycle.pinnedFamilyIDs.contains(familyID)
        }
    }

    /// Whether the family's live surface is also the key window — the only
    /// state in which its entry's `.focused` claim can be a real field
    /// editor rather than a host-reuse leftover.
    func isLiveSurfaceKey(for familyID: UUID, mode: SubtaskPanelContent.Mode) -> Bool {
        switch mode {
        case .transient:
            return lifecycle.transientFamilyID == familyID
                && transientPanel?.isKeyWindow == true
        case .pinned:
            return lifecycle.pinnedFamilyIDs.contains(familyID)
                && pinnedSurfaces[familyID]?.window.isKeyWindow == true
        }
    }

    /// When a LIVE surface's entry last resigned its field editor. A
    /// pin/unpin click resigns on mouse-down, before the button's action
    /// runs — recording the resign lets the swap still restore focus.
    private var entryResignTimestamps: [UUID: TimeInterval] = [:]

    /// Called by a live surface when its entry's field editor resigns:
    /// releases the shared focus pointer (so the composer lock drops) and
    /// records the resign so a same-click pin/unpin still counts the entry
    /// as engaged. Dying hosts are gated off by `isLiveSurface`.
    func noteSubtaskEntryResigned(for familyID: UUID) {
        guard uiState.focusedSubtaskParentID == familyID else { return }
        uiState.focusedSubtaskParentID = nil
        entryResignTimestamps[familyID] = Self.now()
    }

    /// Whether the family's entry counts as focus-engaged for a host swap:
    /// still focused, or resigned inside the same click that triggered the
    /// swap (the press resigns on mouse-down, the action fires on up).
    private func entryFocusEngaged(for familyID: UUID) -> Bool {
        if uiState.focusedSubtaskParentID == familyID { return true }
        guard uiState.subtaskEntryActiveIDs.contains(familyID),
              let at = entryResignTimestamps[familyID] else { return false }
        return Self.now() - at < SubtaskPanelLayout.entryResignReuseWindow
    }

    /// Guard shared by hover dwell, explicit opens, and outside clicks.
    func surfaceInteractionBusy(_ familyID: UUID) -> Bool {
        familyEditBusy(familyID) || menuTrackingActive
    }

    /// The transient surface's composer work is what keeps the main panel
    /// alive — a pinned window is independent and a dismissed surface's
    /// retained draft must not lock anything. The value-taking overload is
    /// for the Combine sinks: @Published delivers the new value in willSet,
    /// before the property stores it, so reading uiState there lags a
    /// change behind — the lock would engage late and release late.
    private func syncComposerLock() {
        syncComposerLock(
            drafts: uiState.subtaskDrafts,
            focusedParentID: uiState.focusedSubtaskParentID
        )
    }

    private func syncComposerLock(
        drafts: [UUID: String],
        focusedParentID: UUID?
    ) {
        let active = lifecycle.transientFamilyID.map { familyID in
            !(drafts[familyID] ?? "").isEmpty || focusedParentID == familyID
        } ?? false
        uiState.setInteractionLock(.subtaskComposer, isActive: active)
    }

    private func raisePinned(_ familyID: UUID, focusEntry: Bool) {
        let panel = pinnedSurfaces[familyID]?.window
        panel?.deminiaturize(nil)
        panel?.orderFrontRegardless()
        if focusEntry {
            panel?.makeKey()
            uiState.activateSubtaskEntry(for: familyID)
        }
    }

    // MARK: - Explicit surface control

    /// Click/keyboard/VoiceOver path: opens the same family panel latched so
    /// it never depends on pointer position, and optionally focuses entry.
    /// When the family is pinned, its pinned window is the surface — the
    /// action raises it rather than presenting a duplicate transient.
    ///
    /// A fresh open always starts on Subtasks, whatever `view` asks: the
    /// Attachments view is reached from the switch inside the panel (or by
    /// an import reveal, which switches deliberately after opening).
    /// Re-activating a panel already presenting the family keeps its view
    /// unless `view` asks for one; entering a subtask always shows Subtasks.
    func openFamilyPanel(for familyID: UUID, focusEntry: Bool, view: FamilyPanelView? = nil) {
        guard resolvedParent(familyID) != nil else { return }
        let requestedView = focusEntry ? .subtasks : view
        if lifecycle.pinnedFamilyIDs.contains(familyID) {
            if let requestedView { showPanelView(requestedView, for: familyID) }
            raisePinned(familyID, focusEntry: focusEntry)
            return
        }
        guard mainPanelVisible else { return }
        // An in-flight edit or confirmation inside the current surface takes
        // precedence over switching it to another family. Deliberate opens
        // (menu commands, count control, keyboard/VoiceOver) are never
        // blocked by menuTracking — the lock protects pointer-driven paths,
        // and a menu's own action would otherwise eat the user's choice.
        if let current = lifecycle.transientFamilyID, current != familyID,
           familyEditBusy(current) {
            return
        }
        // Already on screen for this family: the action still means "bring
        // it forward" — raise it and honor the entry request. With
        // presentation suppressed (unit tests) the lifecycle is the
        // presentation.
        if !lifecycle.openTransient(familyID) {
            lastOutsideDismissal = nil
            syncState()
            if let requestedView { showPanelView(requestedView, for: familyID) }
            transientPanel?.deminiaturize(nil)
            transientPanel?.orderFrontRegardless()
            if focusEntry {
                // SwiftUI's .focused() can only land on a key window — the
                // surface must take key status before the deferred assertion.
                transientPanel?.makeKey()
                uiState.activateSubtaskEntry(for: familyID)
            }
            return
        }
        lastOutsideDismissal = nil
        presentTransient(familyID)
        syncState()
        if focusEntry {
            transientPanel?.makeKey()
            uiState.activateSubtaskEntry(for: familyID)
        }
    }

    // MARK: - Panel views

    func panelView(for familyID: UUID) -> FamilyPanelView {
        panelViews.view(for: familyID)
    }

    /// Deliberate switch from inside a presented panel (or an explicit menu
    /// command). Hover and movement never call this. The surface re-fits on
    /// the next turn, once the content has laid out the destination view.
    func showPanelView(_ view: FamilyPanelView, for familyID: UUID) {
        guard lifecycle.transientFamilyID == familyID || lifecycle.pinnedFamilyIDs.contains(familyID),
              panelViews.view(for: familyID) != view else { return }
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.15)
            : .easeInOut(duration: SubtaskPanelLayout.viewSwitchDuration)
        withAnimation(animation) {
            panelViews.set(view, for: familyID)
        }
        DispatchQueue.main.async { [weak self] in self?.refreshSurfaceSizes() }
    }

    /// The transient panel when an import begins, and how many times the
    /// transient has changed since. Comparing both means a panel opened and
    /// closed again during the import still counts as a change.
    struct RevealContext: Equatable {
        let transientFamilyID: UUID?
        let transientChanges: UInt64
    }

    private var transientChangeCount: UInt64 = 0

    var revealContext: RevealContext {
        RevealContext(transientFamilyID: lifecycle.transientFamilyID, transientChanges: transientChangeCount)
    }

    /// After an import finishes: show the family's Attachments with the new
    /// cards animating in, but only where the user still expects it. A panel
    /// already presenting the family switches in place (an open gallery just
    /// inserts the cards). Otherwise the family opens — on Subtasks, like
    /// every fresh open — and then switches deliberately to Attachments,
    /// but only if the transient has not changed at all since the import
    /// began; a panel opened, closed or replaced meanwhile is left alone,
    /// never reopened or stolen.
    func revealImportedAttachments(_ ids: [UUID], for familyID: UUID, since context: RevealContext) {
        guard resolvedParent(familyID) != nil, !ids.isEmpty else { return }
        let isPresented = lifecycle.transientFamilyID == familyID
            || lifecycle.pinnedFamilyIDs.contains(familyID)
        guard isPresented || revealContext == context else { return }
        let switchesView = !isPresented || panelViews.view(for: familyID) != .attachments
        if switchesView { panelViews.markFresh(ids, for: familyID) }
        openFamilyPanel(for: familyID, focusEntry: false, view: .attachments)
        showPanelView(.attachments, for: familyID)
        let nowPresented = lifecycle.transientFamilyID == familyID
            || lifecycle.pinnedFamilyIDs.contains(familyID)
        guard switchesView else { return }
        guard nowPresented else {
            panelViews.clearFresh(ids, for: familyID)
            return
        }
        // Cards read their fresh flag when created; clearing it once the
        // entrance has played keeps a later rebuild from replaying it.
        DispatchQueue.main.asyncAfter(deadline: .now() + SubtaskPanelLayout.freshAttachmentLifetime) { [weak self] in
            self?.panelViews.clearFresh(ids, for: familyID)
        }
    }

    /// The inline count control toggles presentation for its family: an open
    /// transient closes (unless its family is mid-edit/confirmation), a
    /// pinned window raises, anything else opens latched.
    func toggleFamilyPanel(for familyID: UUID) {
        if lifecycle.pinnedFamilyIDs.contains(familyID) {
            raisePinned(familyID, focusEntry: false)
            return
        }
        if lifecycle.transientFamilyID == familyID {
            guard !familyEditBusy(familyID) else { return }
            closeTransientSurface()
            return
        }
        // The outside-click monitor dismisses on mouse-down, one beat before
        // this action arrives on mouse-up; that dismissal is the close half
        // of the toggle, not a cue to reopen. The window covers one click's
        // down→up span, not any later deliberate press.
        if let last = lastOutsideDismissal,
           last.familyID == familyID,
           Self.now() - last.at < 0.3 {
            lastOutsideDismissal = nil
            return
        }
        openFamilyPanel(for: familyID, focusEntry: false)
    }

    func dismissTransient() {
        closeTransientSurface()
    }

    /// The main panel's "pointer inside" coverage: hovering the open
    /// checklist, or travelling to it (across a pinned window on the way),
    /// never fights auto-hide. A pinned window alone keeps nothing alive —
    /// without an open transient this is always false.
    func containsTransientPoint(_ point: CGPoint) -> Bool {
        transientCoverage(of: point) != .outside
    }

    /// Latched outside-click dismissal: the surface, and the corridor only in
    /// the narrow gap beside it. A press anywhere else along a long route, on
    /// the main panel's content or on a pinned panel is a click elsewhere.
    func transientClickIsInside(_ point: CGPoint) -> Bool {
        switch transientCoverage(of: point) {
        case .surface: return true
        case .outside: return false
        case .transit:
            guard let surface = transientPanel?.frame,
                  SubtaskPanelLayout.distance(from: point, to: surface) <= SubtaskPanelLayout.sideGap else { return false }
            let main = panelWindow.map { ($0 as? AtticPanel)?.visibleContentFrame ?? $0.frame }
            return main?.contains(point) != true && !visiblePinnedFrames.contains { $0.contains(point) }
        }
    }

    private var visiblePinnedFrames: [CGRect] {
        pinnedSurfaces.values.filter { $0.window.isVisible }.map { $0.window.frame }
    }

    /// Classifies a screen point against the open transient surface and the
    /// corridor from its source row to wherever it was placed.
    func transientCoverage(of point: CGPoint) -> SubtaskPanelLayout.PointerCoverage {
        guard let panel = transientPanel, panel.isVisible else { return .outside }
        let main = panelWindow
        let mainFrame: CGRect? = (main?.isVisible == true && !lifecycle.isTransientDetached)
            ? ((main as? AtticPanel)?.visibleContentFrame ?? main?.frame)
            : nil
        return SubtaskPanelLayout.pointerCoverage(
            point,
            surfaceFrame: panel.frame,
            cornerSize: surfaceCornerSize,
            mainPanelFrame: mainFrame,
            anchorRect: lifecycle.transientFamilyID.flatMap { screenAnchorRect(for: $0) },
            crossingFrames: visiblePinnedFrames
        )
    }

    // MARK: - Pin / unpin

    /// A promotion retains the live window and its screen position. Each
    /// family owns a separate pinned window; pinning never evicts another.
    func pinFamily(_ familyID: UUID) {
        guard resolvedParent(familyID) != nil else { return }
        if lifecycle.pinnedFamilyIDs.contains(familyID) {
            raisePinned(familyID, focusEntry: false)
            return
        }
        let refocusEntry = entryFocusEngaged(for: familyID)
        if lifecycle.transientFamilyID == familyID,
           let surface = transientPanel, let host = transientHost {
            pinnedSurfaces[familyID] = (surface, host)
            transientPanel = nil
            transientHost = nil
        }
        lifecycle.pin(familyID)
        presentPinned(familyID)
        syncState()
        if refocusEntry {
            pinnedSurfaces[familyID]?.window.makeKey()
            uiState.focusSubtaskEntry(for: familyID)
        }
    }

    /// Unpinning keeps a visible window where it is, detached from the row.
    /// Without the main panel it dismisses; pinned windows alone survive hide.
    func unpinPinned(_ familyID: UUID) {
        guard lifecycle.pinnedFamilyIDs.contains(familyID) else { return }
        let evictionBusy = lifecycle.transientFamilyID.map {
            $0 != familyID && surfaceInteractionBusy($0)
        } ?? false
        let refocusEntry = entryFocusEngaged(for: familyID)
        let retainedView = panelViews.view(for: familyID)
        let surface = pinnedSurfaces.removeValue(forKey: familyID)
        lifecycle.unpin(familyID)
        if mainPanelVisible, !evictionBusy {
            closeTransientSurface()
            lifecycle.openTransient(familyID)
            lifecycle.detachTransient()
            // The same window stays up, so it keeps the view it showed.
            panelViews.set(retainedView, for: familyID)
            transientPanel = surface?.window
            transientHost = surface?.host
            if let surface {
                configureSurface(surface.window, host: surface.host, familyID: familyID, mode: .transient)
            } else {
                presentTransient(familyID)
            }
            if refocusEntry {
                transientPanel?.makeKey()
                uiState.focusSubtaskEntry(for: familyID)
            }
        } else {
            surface?.window.close()
        }
        syncState()
        releaseFamilyInteractionState(familyID)
    }

    func closePinned(_ familyID: UUID) {
        guard lifecycle.unpin(familyID) != nil else { return }
        pinnedSurfaces.removeValue(forKey: familyID)?.window.close()
        syncState()
        releaseFamilyInteractionState(familyID)
    }

    // MARK: - Main-panel lifecycle

    func mainPanelDidHide() {
        closeTransientSurface()
    }

    func mainPanelFrameDidChange() {
        repositionTransient()
    }

    func tearDown() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
        let released = lifecycle.pinnedFamilyIDs
        let transientWas = lifecycle.transientFamilyID
        lifecycle.closeTransient()
        transientPanel?.orderOut(nil)
        for familyID in released {
            lifecycle.unpin(familyID)
            pinnedSurfaces.removeValue(forKey: familyID)?.window.close()
        }
        if transientFamilyID != nil { transientChangeCount &+= 1 }
        transientFamilyID = nil
        pinnedFamilyIDs = []
        uiState.setInteractionLock(.subtaskComposer, isActive: false)
        if let transientWas { releaseFamilyInteractionState(transientWas) }
        for familyID in released { releaseFamilyInteractionState(familyID) }
    }

    // MARK: - Content metrics

    func measuredListHeight(for familyID: UUID) -> CGFloat? {
        listHeights[familyID]
    }

    /// A live surface measured its header/footer. The first fit used
    /// estimates, and an Attachments-first or childless panel has no list
    /// measurement to trigger the correcting re-fit, so this one does.
    func noteChromeMeasured(for familyID: UUID, mode: SubtaskPanelContent.Mode) {
        guard isLiveSurface(for: familyID, mode: mode) else { return }
        chromeRefitRequestCount += 1
        DispatchQueue.main.async { [weak self] in self?.refreshSurfaceSizes() }
    }

    /// Test seam: how many chrome measurements scheduled a re-fit.
    private(set) var chromeRefitRequestCount = 0

    func noteMeasuredListHeight(for familyID: UUID, height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        guard abs((listHeights[familyID] ?? 0) - height) >= 0.5 else { return }
        listHeights[familyID] = height
        // The shared view relayouts on the @Published change; fittingSize is
        // only stable after that pass, so resize on the next runloop turn.
        DispatchQueue.main.async { [weak self] in
            self?.refreshSurfaceSizes()
        }
    }

    // MARK: - Window plumbing

    private func syncState() {
        if transientFamilyID != lifecycle.transientFamilyID {
            transientFamilyID = lifecycle.transientFamilyID
            transientChangeCount &+= 1
        }
        if pinnedFamilyIDs != lifecycle.pinnedFamilyIDs {
            pinnedFamilyIDs = lifecycle.pinnedFamilyIDs
        }
        if lifecycle.transientFamilyID == nil {
            transientPanel?.orderOut(nil)
        }
        // A family without a surface forgets its view, so its next fresh
        // open starts on Subtasks. Pin keeps the family presented throughout.
        var presented = lifecycle.pinnedFamilyIDs
        if let transient = lifecycle.transientFamilyID { presented.insert(transient) }
        panelViews.retain(presented)
        syncComposerLock()
        updateOutsideClickMonitoring()
    }

    /// Called when a family's last surface is torn down: an in-flight rename
    /// or delete confirmation hosted by that surface must not outlive it —
    /// the orphaned lock would hold the main panel open and stall every
    /// future hover-close retry. Only CHILD work is surface-hosted: the
    /// checklist renders child rows, while the parent's own rename field and
    /// delete alert live on its main-list row, which outlives any auxiliary
    /// surface. Ends the interaction the same way a section switch does;
    /// subtask drafts are unaffected and keep surviving.
    private func releaseFamilyInteractionState(_ familyID: UUID) {
        guard lifecycle.transientFamilyID != familyID,
              !lifecycle.pinnedFamilyIDs.contains(familyID) else { return }
        func isSurfaceHostedChild(_ id: UUID?) -> Bool {
            guard let id else { return false }
            return store.task(withID: id)?.parentID == familyID
        }
        if isSurfaceHostedChild(uiState.editingTaskID) {
            uiState.endEditing()
        }
        if isSurfaceHostedChild(uiState.confirmingTaskDeletionID) {
            uiState.confirmingTaskDeletionID = nil
        }
        if isSurfaceHostedChild(uiState.confirmingTaskCompletionID) {
            uiState.confirmingTaskCompletionID = nil
        }
        // The entry's focus pointer is surface-hosted too: with the last
        // surface gone, a stale pointer would refocus the entry on the next
        // open without being asked. The entry row itself (its active flag
        // and draft) still survives — only the focus claim is released.
        if uiState.focusedSubtaskParentID == familyID {
            uiState.focusedSubtaskParentID = nil
        }
    }

    private func closeTransientSurface() {
        let closing = lifecycle.transientFamilyID
        lifecycle.closeTransient()
        syncState()
        if let closing {
            releaseFamilyInteractionState(closing)
        }
    }

    private func makeContent(_ familyID: UUID, mode: SubtaskPanelContent.Mode)
        -> SubtaskPanelContent {
        SubtaskPanelContent(
            store: store,
            uiState: uiState,
            settings: settings,
            subtaskPanels: self,
            panelViews: panelViews,
            parentID: familyID,
            mode: mode
        )
    }

    private func makeSurface(_ familyID: UUID, mode: SubtaskPanelContent.Mode)
        -> (window: PanelSurfaceWindow, host: SurfaceHost) {
        let host = SurfaceHost(rootView: makeContent(familyID, mode: mode))
        let surface = PanelSurfaceWindow(
            contentView: host,
            initialSize: CGSize(width: SubtaskPanelLayout.panelWidth, height: 160)
        )
        surface.delegate = self
        return (surface, host)
    }

    private func configureSurface(_ surface: PanelSurfaceWindow, host: SurfaceHost,
                                  familyID: UUID, mode: SubtaskPanelContent.Mode) {
        // A task click commits the replacement immediately. Per-view paging
        // and user-driven height changes retain their own scoped animations.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            host.rootView = makeContent(familyID, mode: mode)
            host.layoutSubtreeIfNeeded()
        }
        host.surfaceCornerSize = surfaceCornerSize
        host.onBeginWindowDrag = mode == .transient
            ? { [weak self] in self?.detachTransient() } : nil
        let prefix = mode == .pinned ? "subtask-pinned" : "subtask-panel"
        surface.setAccessibilityIdentifier("\(prefix)-\(familyID.uuidString)")
        surface.onEscape = { [weak self] in
            if mode == .pinned { self?.closePinned(familyID) }
            else { self?.closeTransientSurface() }
        }
    }

    private func presentTransient(_ familyID: UUID) {
        guard presentationEnabled, resolvedParent(familyID) != nil,
              let panel = panelWindow, panel.isVisible else { return }
        let pair: (window: PanelSurfaceWindow, host: SurfaceHost)
        if let surface = transientPanel, let host = transientHost {
            pair = (surface, host)
        } else {
            pair = makeSurface(familyID, mode: .transient)
            transientPanel = pair.window
            transientHost = pair.host
        }
        configureSurface(pair.window, host: pair.host, familyID: familyID, mode: .transient)
        let anchor = screenAnchorRect(for: familyID)
        guard let visibleFrame = (anchorScreen(for: anchor) ?? panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        stopFrameAnimation(pair.window, at: SubtaskPanelLayout.transientFrame(
            size: fittingSize(of: pair.host), anchorScreenRect: anchor,
            panelScreenFrame: (panel as? AtticPanel)?.visibleContentFrame ?? panel.frame,
            screenVisibleFrame: visibleFrame,
            occupiedFrames: visiblePinnedFrames
        ))
        pair.window.orderFrontRegardless()

    }

    private func presentPinned(_ familyID: UUID) {
        guard presentationEnabled, resolvedParent(familyID) != nil else { return }
        let pair = pinnedSurfaces[familyID] ?? makeSurface(familyID, mode: .pinned)
        let wasVisible = pair.window.isVisible
        pinnedSurfaces[familyID] = pair
        configureSurface(pair.window, host: pair.host, familyID: familyID, mode: .pinned)
        if !wasVisible {
            pair.window.setFrame(SubtaskPanelLayout.restoredPinnedFrame(
                saved: nil, size: fittingSize(of: pair.host),
                screenVisibleFrames: NSScreen.screens.map(\.visibleFrame),
                fallback: screenAnchorRect(for: familyID)
            ), display: true)
        }
        pair.window.orderFrontRegardless()
    }

    private func repositionTransient() {
        guard presentationEnabled,
              let familyID = lifecycle.transientFamilyID,
              let surface = transientPanel, surface.isVisible,
              let panel = panelWindow, panel.isVisible,
              let host = transientHost else { return }
        let anchor = screenAnchorRect(for: familyID)
        transientRepositionCount += 1
        // Detached, or with its row scrolled away: it stays where it is and
        // only follows its content height.
        if lifecycle.isTransientDetached || anchor == nil {
            resizeDetachedSurface(surface, host: host)
            return
        }
        let fitting = fittingSize(of: host)
        let screen = anchorScreen(for: anchor) ?? panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let panelFrame = (panel as? AtticPanel)?.visibleContentFrame ?? panel.frame
        applyFrame(
            SubtaskPanelLayout.transientFrame(
                size: fitting,
                anchorScreenRect: anchor,
                panelScreenFrame: panelFrame,
                screenVisibleFrame: visibleFrame,
                occupiedFrames: visiblePinnedFrames
            ),
            to: surface
        )
    }

    /// Every layout-affecting change re-fits the whole surface AND re-applies
    /// the screen-bound clamps — growth near a display edge can push controls
    /// offscreen, so a plain top-preserving resize is not enough.
    private func refreshSurfaceSizes() {
        guard presentationEnabled else { return }
        // A live corner change repaints the squircle; the hit shape follows in
        // the same pass so clicks never disagree with what is drawn.
        transientHost?.surfaceCornerSize = surfaceCornerSize
        if transientPanel?.isVisible == true { repositionTransient() }
        for pair in pinnedSurfaces.values {
            pair.host.surfaceCornerSize = surfaceCornerSize
            resizeDetachedSurface(pair.window, host: pair.host)
        }
    }

    private func resizeDetachedSurface(_ surface: NSWindow, host: SurfaceHost) {
        guard surface.isVisible else { return }
        let current = frameAnimationTargets.target(for: surface) ?? surface.frame
        if let frame = SubtaskPanelLayout.pinnedResizedFrame(
            current, newHeight: fittingSize(of: host).height,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame)
        ), frame != current {
            applyFrame(frame, to: surface)
        }
    }

    /// In-flight height animations by window, so repeated re-fits toward the
    /// same target neither restart the animation nor pile up.
    private var frameAnimationTargets = SurfaceFrameAnimationTargets()

    /// Height-only changes of a visible surface animate with its content,
    /// holding the top edge. Anything that moves the surface (anchor tracking,
    /// display clamps) applies at once, which also stops an in-flight change.
    private func applyFrame(_ frame: CGRect, to surface: NSWindow) {
        let current = surface.frame
        let target = frameAnimationTargets.target(for: surface)
        if target == frame { return }
        guard frame != current else {
            if target != nil { stopFrameAnimation(surface, at: frame) }
            return
        }
        let holdsTopAndWidth = abs(frame.maxY - current.maxY) < 0.5
            && abs(frame.minX - current.minX) < 0.5
            && abs(frame.width - current.width) < 0.5
        guard surface.isVisible, holdsTopAndWidth,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopFrameAnimation(surface, at: frame)
            return
        }
        frameAnimationTargets.set(frame, for: surface)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SubtaskPanelLayout.viewSwitchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            surface.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak surface] in
            MainActor.assumeIsolated {
                guard let self, let surface,
                      self.frameAnimationTargets.target(for: surface) == frame else { return }
                self.frameAnimationTargets.clear(for: surface)
            }
        }
    }

    /// A zero-duration animator update stops any in-flight frame animation.
    private func stopFrameAnimation(_ surface: NSWindow, at frame: CGRect) {
        frameAnimationTargets.clear(for: surface)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            surface.animator().setFrame(frame, display: true)
        }
    }

    private func fittingSize(of host: NSHostingView<SubtaskPanelContent>) -> CGSize {
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        return CGSize(
            width: max(fitting.width, SubtaskPanelLayout.panelWidth),
            height: max(fitting.height, SubtaskPanelLayout.minimumContentHeight)
        )
    }

    private func anchorScreen(for anchor: CGRect?) -> NSScreen? {
        anchor.flatMap { rect in
            NSScreen.screens.first {
                NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false)
            }
        }
    }

    /// The transient dismisses on any mouse-down outside its bounds — the
    /// familiar "click elsewhere to close".
    private func updateOutsideClickMonitoring() {
        let shouldMonitor = lifecycle.transientFamilyID != nil
        if shouldMonitor, outsideClickMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.noteOutsideMouseDown(event) }
                return event
            }
            if let local { outsideClickMonitors.append(local) }
            let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.noteOutsideMouseDown(event) }
            }
            if let global { outsideClickMonitors.append(global) }
        } else if !shouldMonitor, !outsideClickMonitors.isEmpty {
            outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
            outsideClickMonitors.removeAll()
        }
    }

    private func noteOutsideMouseDown(_ event: NSEvent) {
        guard let openFamily = lifecycle.transientFamilyID,
              let surface = transientPanel, surface.isVisible else { return }
        let location = NSEvent.mouseLocation
        // Same predicate as auto-hide coverage: the rounded corner wedges
        // and the panel↔surface corridor are inside for both paths.
        if transientClickIsInside(location) { return }
        // Windows owned by the surface extend beyond its frame — a context
        // menu (popUpMenu-level window) or a sheet/alert hanging off it must
        // count as inside so their clicks don't dismiss the host.
        if let eventWindow = event.window {
            if eventWindow === surface || eventWindow.sheetParent === surface {
                return
            }
            if eventWindow.level == .popUpMenu || eventWindow.level == .statusBar {
                return
            }
        }
        // The family's own source row reopens/raises this surface on click,
        // so its press is not "outside" — dismissing here would flicker the
        // panel closed and open again within one click.
        if isSourceRowPoint(location, for: openFamily) { return }
        // An in-flight rename or delete confirmation inside this family, or
        // any tracked menu, owns the surface until it resolves.
        if familyEditBusy(openFamily) || menuTrackingActive { return }
        // Only the count control's own mousedown pairs with the toggle
        // action: dismissals triggered by clicks elsewhere — including other
        // controls inside the same row — leave no suppression behind, so a
        // deliberate toggle afterward still opens.
        if screenControlRect(for: openFamily)?.contains(location) == true {
            lastOutsideDismissal = (openFamily, Self.now())
        }
        closeTransientSurface()
    }

    /// Whether a screen point lands on the family's visible main-list row.
    func isSourceRowPoint(_ point: CGPoint, for familyID: UUID) -> Bool {
        screenAnchorRect(for: familyID)?.contains(point) == true
    }

    private func handleScreenParametersChanged() {
        for pair in pinnedSurfaces.values {
            resizeDetachedSurface(pair.window, host: pair.host)
        }
        repositionTransient()
    }

    private func reconcileStore() {
        if let open = lifecycle.transientFamilyID, resolvedParent(open) == nil {
            closeTransientSurface()
        }
        for familyID in lifecycle.pinnedFamilyIDs where resolvedParent(familyID) == nil {
            closePinned(familyID)
        }
        // Prune cached geometry for deleted families so the maps stay
        // bounded by live tasks only.
        let liveIDs = Set(store.tasks.map(\.id))
        listHeights = listHeights.filter { liveIDs.contains($0.key) }
        rowFrames = rowFrames.filter { liveIDs.contains($0.key) }
        controlFrames = controlFrames.filter { liveIDs.contains($0.key) }
        entryResignTimestamps = entryResignTimestamps.filter { liveIDs.contains($0.key) }
        // Child adds/removals, status changes, and error rows all change the
        // content height — re-fit (and re-clamp) once the hosting views have
        // applied the revision on their own pass.
        DispatchQueue.main.async { [weak self] in self?.refreshSurfaceSizes() }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

extension SubtaskPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === transientPanel {
            closeTransientSurface()
        } else if let familyID = pinnedSurfaces.first(where: { $0.value.window === window })?.key {
            closePinned(familyID)
        }
    }
}

/// In-flight frame animation targets. Each entry holds its window weakly and
/// is honored only for that same live object: a window closed or released
/// mid-animation never completes its entry, and AppKit may hand its address
/// (and so its `ObjectIdentifier`) to a new surface, which must not inherit
/// the dead window's frame. Dead entries are pruned whenever one is added.
struct SurfaceFrameAnimationTargets {
    private struct Entry {
        weak var owner: AnyObject?
        let frame: CGRect
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var count: Int { entries.count }

    mutating func target(for owner: AnyObject) -> CGRect? {
        let key = ObjectIdentifier(owner)
        guard let entry = entries[key] else { return nil }
        guard entry.owner === owner else {
            entries[key] = nil
            return nil
        }
        return entry.frame
    }

    mutating func set(_ frame: CGRect, for owner: AnyObject) {
        entries = entries.filter { $0.value.owner != nil }
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, frame: frame)
    }

    mutating func clear(for owner: AnyObject) {
        entries[ObjectIdentifier(owner)] = nil
    }
}

/// Per-family panel view, observed only by the panel content. Families that
/// are not presented have no entry and read as Subtasks.
@MainActor
final class FamilyPanelViewState: ObservableObject {
    @Published private(set) var views: [UUID: FamilyPanelView] = [:]

    func view(for familyID: UUID) -> FamilyPanelView {
        views[familyID] ?? .subtasks
    }

    func set(_ view: FamilyPanelView, for familyID: UUID) {
        let stored: FamilyPanelView? = view == .subtasks ? nil : view
        guard views[familyID] != stored else { return }
        views[familyID] = stored
    }

    /// Newly imported cards that should play their entrance when the
    /// gallery appears for them.
    @Published private(set) var freshAttachmentIDs: [UUID: Set<UUID>] = [:]

    func freshAttachments(for familyID: UUID) -> Set<UUID> {
        freshAttachmentIDs[familyID] ?? []
    }

    func markFresh(_ ids: [UUID], for familyID: UUID) {
        freshAttachmentIDs[familyID, default: []].formUnion(ids)
    }

    func clearFresh(_ ids: [UUID], for familyID: UUID) {
        guard let current = freshAttachmentIDs[familyID], !current.isDisjoint(with: ids) else { return }
        let remaining = current.subtracting(ids)
        freshAttachmentIDs[familyID] = remaining.isEmpty ? nil : remaining
    }

    func retain(_ familyIDs: Set<UUID>) {
        if freshAttachmentIDs.keys.contains(where: { !familyIDs.contains($0) }) {
            freshAttachmentIDs = freshAttachmentIDs.filter { familyIDs.contains($0.key) }
        }
        guard views.keys.contains(where: { !familyIDs.contains($0) }) else { return }
        views = views.filter { familyIDs.contains($0.key) }
    }
}
