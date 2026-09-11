import AppKit
import Combine
import SwiftUI

/// Shared window behavior for the auxiliary surfaces: key-capable for inline
/// entry, never a main window, and Escape dismisses the surface — but never
/// while a field editor owns it, where it remains "cancel editing".
private class SubtaskSurfacePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,
           !(firstResponder is NSTextView) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Borderless hover surface that lives beside a task row. It is never
/// user-movable, never enters the Dock, and dismisses with the main panel.
private final class SubtaskAuxiliaryPanel: SubtaskSurfacePanel {}

/// The pinned mini-window: a persistent, draggable counterpart to the
/// transient surface. Closing it only dismisses the surface — it neither
/// quits the app nor touches task data.
private final class SubtaskPinnedPanel: SubtaskSurfacePanel {}

/// Hosts the checklist inside the auxiliary panels. A plain `NSHostingView`
/// answers `acceptsFirstMouse` false, so the click that makes a nonactivating
/// panel key never reaches the content — the entry field, controls, and the
/// pinned window's drag all look dead on first interaction. Accepting it
/// delivers the click alongside the key-making.
private final class SubtaskHostingView: NSHostingView<SubtaskPanelContent> {
    /// Pinned surfaces only: presses that hit-test down to this hosting view
    /// inside the header strip drag the window. SwiftUI's empty header space
    /// resolves to the hosting view itself, so the drag must start here —
    /// a `.background` representable never lands in the hit-test chain.
    /// Controls and fields claim their own presses before this view sees them.
    var dragsWindowFromHeader = false

    /// Top strip of the window treated as the drag handle (view coords).
    private var headerDragLimit: CGFloat { 44 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if dragsWindowFromHeader,
           let window,
           local.y >= 0, local.y < headerDragLimit {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Owns the auxiliary subtask surfaces: a transient hover panel anchored to a
/// task row, and at most one pinned mini-window that survives main-panel
/// hides. SwiftUI rows report hover and anchor geometry; this controller
/// decides dwell/open/close, positions the windows, and mirrors state into
/// `transientFamilyID`/`pinnedFamilyID` for the shared checklist view.
@MainActor
final class SubtaskPanelController: NSObject, ObservableObject {
    @Published private(set) var transientFamilyID: UUID?
    @Published private(set) var pinnedFamilyID: UUID?
    @Published private var listHeights: [UUID: CGFloat] = [:]

    private let store: TaskStore
    private let uiState: PanelUIState
    private let settings: AppSettings

    private var lifecycle = SubtaskPanelLifecycle()
    private weak var panelWindow: NSWindow?
    private weak var hostView: NSView?

    private var transientPanel: SubtaskAuxiliaryPanel?
    private var transientHost: SubtaskHostingView?
    private var pinnedPanel: SubtaskPinnedPanel?
    private var pinnedHost: SubtaskHostingView?

    /// Row frames in the panel workspace coordinate space, republished on
    /// every scroll/layout pass by `TaskRowAnchorPreferenceKey`.
    private var rowFrames: [UUID: CGRect] = [:]
    /// The inline count control's frame per family, used to recognize the
    /// toggle's paired mousedown when it dismisses a latched surface.
    private var controlFrames: [UUID: CGRect] = [:]
    private var listViewport: CGRect = .null

    private var pendingOpenWork: DispatchWorkItem?
    private var pendingCloseWork: DispatchWorkItem?
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
    /// Set while a programmatic setFrame runs so windowDidMove doesn't
    /// overwrite the user's remembered pinned position with a clamp.
    private var suppressPinnedMovePersist = false

    init(store: TaskStore, uiState: PanelUIState, settings: AppSettings) {
        self.store = store
        self.uiState = uiState
        self.settings = settings
        super.init()

        store.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.reconcileStore() }
            .store(in: &cancellables)
        store.$lastErrorMessage
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
        pendingOpenWork?.cancel()
        pendingCloseWork?.cancel()
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

    func updateSubtaskControlFrames(_ frames: [UUID: CGRect]) {
        controlFrames = frames
    }

    func updateTaskRowFrames(_ frames: [UUID: CGRect]) {
        rowFrames = frames
        guard let open = lifecycle.transientFamilyID else { return }
        if screenAnchorRect(for: open) == nil {
            // The row scrolled away or disappeared; close instead of leaving
            // a detached surface floating beside the panel.
            closeTransientSurface()
        } else {
            repositionTransient()
        }
    }

    func updateTaskListViewport(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        listViewport = rect
        if let open = lifecycle.transientFamilyID, screenAnchorRect(for: open) == nil {
            closeTransientSurface()
        }
    }

    // MARK: - Hover-driven transient surface

    func noteRowHover(familyID: UUID, isHovering: Bool) {
        // Hover enters always schedule; commitPendingOpen defers maturation
        // while the open surface is edit/menu busy, so a resting pointer
        // still opens once the interaction resolves instead of dying here.
        lifecycle.noteRowHover(familyID: familyID, isHovering: isHovering, at: Self.now())
        rescheduleTimers()
    }

    func noteTransientPointer(inside: Bool) {
        lifecycle.noteTransientPointer(inside: inside, at: Self.now())
        rescheduleTimers()
    }

    private func rescheduleTimers() {
        pendingOpenWork?.cancel()
        pendingCloseWork?.cancel()
        pendingOpenWork = nil
        pendingCloseWork = nil
        if let pending = lifecycle.pendingOpen {
            let work = DispatchWorkItem { [weak self] in
                self?.commitPendingOpen(for: pending.familyID)
            }
            pendingOpenWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, pending.deadline - Self.now()),
                execute: work
            )
        }
        if let pending = lifecycle.pendingClose {
            let work = DispatchWorkItem { [weak self] in
                self?.commitPendingClose(for: pending.familyID)
            }
            pendingCloseWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, pending.deadline - Self.now()),
                execute: work
            )
        }
    }

    private func commitPendingOpen(for familyID: UUID) {
        // A live context menu owns the row's interaction: ordering a surface
        // front mid-tracking would tear the menu down before its action can
        // run. Re-arm so the open lands once the menu resolves — the leave
        // event still cancels it if the pointer moved on.
        if menuTrackingActive {
            lifecycle.rearmPendingOpen(at: Self.now())
            rescheduleTimers()
            return
        }
        // While the open surface is busy — its family's edit/confirmation,
        // a tracked menu, or its focused/drafting composer — a stale pending
        // claim re-arms for another dwell rather than ripping the surface out
        // from under in-flight work. The pointer is still resting on the row
        // and a leave event cancels it.
        if lifecycle.pendingOpen?.familyID == familyID,
           let current = lifecycle.transientFamilyID, current != familyID,
           shouldDeferPointerClose(for: current) {
            lifecycle.rearmPendingOpen(at: Self.now())
            rescheduleTimers()
            return
        }
        guard lifecycle.maturePendingOpen(for: familyID, at: Self.now()) else { return }
        // Hover opens only for a real family with a live anchor: no empty
        // panels for childless rows, none for rows already scrolled away.
        guard screenAnchorRect(for: familyID) != nil, hoverWorthy(familyID) else {
            // Same teardown path as every other close — the matured family's
            // surface-hosted interaction state must not outlive it either.
            closeTransientSurface()
            return
        }
        lastOutsideDismissal = nil
        presentTransient(familyID)
        syncState()
    }

    private func commitPendingClose(for familyID: UUID) {
        // Menus, inline editors, and confirmation alerts raise interaction
        // locks — pointer position alone must not close the surface
        // underneath them mid-action. Retry rather than drop: once the lock
        // clears, the overdue leave closes it without needing new hover.
        if shouldDeferPointerClose(for: familyID) {
            lifecycle.noteRowHover(familyID: familyID, isHovering: false, at: Self.now())
            rescheduleTimers()
            return
        }
        guard lifecycle.maturePendingClose(for: familyID, at: Self.now()) else { return }
        syncState()
        releaseFamilyInteractionState(familyID)
    }

    /// Pointer-leave close only defers for locks that actually belong to this
    /// surface — its family's edit/confirmation, a tracked menu, or the
    /// surface's own focused/drafting composer. Unrelated panel work (the
    /// main composer, notes, canvas dialogs) must not pin the surface open.
    func shouldDeferPointerClose(for familyID: UUID) -> Bool {
        surfaceInteractionBusy(familyID)
            || uiState.interactionLockReasons.contains(.subtaskComposer)
    }

    /// A family is hover-presentable when it has children, an in-flight
    /// draft, or an activated entry; childless rows rely on the explicit Add
    /// subtask path instead.
    private func hoverWorthy(_ familyID: UUID) -> Bool {
        !store.subtasks(of: familyID).isEmpty
            || !(uiState.subtaskDrafts[familyID] ?? "").isEmpty
            || uiState.subtaskEntryActiveIDs.contains(familyID)
    }

    private func resolvedParent(_ familyID: UUID) -> TaskItem? {
        store.tasks.first { $0.id == familyID && $0.parentID == nil }
    }

    /// True while the family (its parent row or one of its children) has a
    /// rename or delete-confirmation in flight, or any context menu is being
    /// tracked. Such work is surface-owned: it protects the surface from
    /// pointer-position decisions but never blocks a deliberate close API.
    func familyEditBusy(_ familyID: UUID) -> Bool {
        func belongsToFamily(_ id: UUID?) -> Bool {
            guard let id else { return false }
            if id == familyID { return true }
            return store.tasks.contains { $0.id == id && $0.parentID == familyID }
        }
        return belongsToFamily(uiState.editingTaskID)
            || belongsToFamily(uiState.confirmingTaskDeletionID)
    }

    var menuTrackingActive: Bool {
        uiState.interactionLockReasons.contains(.menuTracking)
    }

    /// Whether that surface kind currently hosts the family. The content
    /// view consults this from its focus-teardown path: a dying host (a
    /// transient ordered out by a pin, a pinned window replaced by a
    /// re-anchored transient, a swapped family) must not clear
    /// `focusedSubtaskParentID` after the replacement surface already
    /// asserted it — AppKit's field-editor resignation is not synchronous
    /// with `orderOut`, so the stale resign can otherwise land after the
    /// controller's re-focus bump and leave the new entry unfocused.
    func isLiveSurface(for familyID: UUID, mode: SubtaskPanelContent.Mode) -> Bool {
        switch mode {
        case .transient: return lifecycle.transientFamilyID == familyID
        case .pinned: return lifecycle.pinnedFamilyID == familyID
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
            return lifecycle.pinnedFamilyID == familyID
                && pinnedPanel?.isKeyWindow == true
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

    /// The family's single pinned surface is already up — raise it (and
    /// focus its entry when asked) instead of showing a second surface.
    private func raisePinned(focusEntry: Bool) {
        pinnedPanel?.deminiaturize(nil)
        pinnedPanel?.orderFrontRegardless()
        if focusEntry, let familyID = lifecycle.pinnedFamilyID {
            pinnedPanel?.makeKey()
            uiState.activateSubtaskEntry(for: familyID)
        }
    }

    // MARK: - Explicit surface control

    /// Click/keyboard/VoiceOver path: opens the same family panel latched so
    /// it never depends on pointer position, and optionally focuses entry.
    /// When the family is pinned, its pinned window is the surface — the
    /// action raises it rather than presenting a duplicate transient.
    func openFamilyPanel(for familyID: UUID, focusEntry: Bool) {
        guard resolvedParent(familyID) != nil else { return }
        if lifecycle.pinnedFamilyID == familyID {
            raisePinned(focusEntry: focusEntry)
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
        if !lifecycle.openTransient(familyID, latched: true) {
            // Already latched open for this family: the action still means
            // "bring it forward" — raise it and honor the entry request.
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

    /// The inline count control toggles presentation for its family: an open
    /// transient closes (unless its family is mid-edit/confirmation), a
    /// pinned window raises, anything else opens latched.
    func toggleFamilyPanel(for familyID: UUID) {
        if lifecycle.pinnedFamilyID == familyID {
            raisePinned(focusEntry: false)
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
        let closing = lifecycle.transientFamilyID
        lifecycle.closeTransient()
        rescheduleTimers()
        syncState()
        if let closing {
            releaseFamilyInteractionState(closing)
        }
    }

    /// The transient surface's geometric hit test, used both by the main
    /// panel's "pointer inside" coverage (hovering the open checklist never
    /// fights auto-hide) and by latched outside-click dismissal — one
    /// predicate keeps those paths consistent. The pointer-travel corridor
    /// between the panel and the surface counts as inside so crossing the
    /// gap can't trip either. The pinned window is deliberately excluded:
    /// it lives independently of the main panel.
    func containsTransientPoint(_ point: CGPoint) -> Bool {
        guard let panel = transientPanel, panel.isVisible else { return false }
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        if Squircle.contains(
            local,
            in: CGRect(origin: .zero, size: panel.frame.size),
            cornerRadius: AtticStyle.panelCornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ) {
            return true
        }
        guard let main = panelWindow, main.isVisible else { return false }
        let mainFrame = (main as? AtticPanel)?.visibleContentFrame ?? main.frame
        let surface = panel.frame
        let spanMinY = min(mainFrame.minY, surface.minY)
        let spanMaxY = max(mainFrame.maxY, surface.maxY)
        if surface.minX >= mainFrame.maxX {
            return CGRect(x: mainFrame.maxX, y: spanMinY,
                          width: surface.minX - mainFrame.maxX,
                          height: spanMaxY - spanMinY).contains(point)
        }
        if surface.maxX <= mainFrame.minX {
            return CGRect(x: surface.maxX, y: spanMinY,
                          width: mainFrame.minX - surface.maxX,
                          height: spanMaxY - spanMinY).contains(point)
        }
        return false
    }

    // MARK: - Pin / unpin

    /// Promotes the shared checklist into the pinned mini-window. Pinning a
    /// second family resolves the existing window first — v1 allows exactly
    /// one — and drafts live in `uiState.subtaskDrafts`, so they follow.
    func pinFamily(_ familyID: UUID) {
        guard resolvedParent(familyID) != nil else { return }
        let displaced = lifecycle.pinnedFamilyID.flatMap { $0 == familyID ? nil : $0 }
        // An in-flight edit or confirmation inside the live pinned window
        // survives the replacement affordance's deliberate wording but not
        // a silent swap — refuse while the displaced family is mid-action.
        if let displaced, familyEditBusy(displaced) { return }
        let refocusEntry = entryFocusEngaged(for: familyID)
        let promotedFrame = lifecycle.transientFamilyID == familyID
            && transientPanel?.isVisible == true
            ? transientPanel?.frame
            : nil
        lifecycle.pin(familyID)
        presentPinned(familyID, promotedFrame: promotedFrame)
        rescheduleTimers()
        syncState()
        if refocusEntry {
            // Re-bump after the host swap so the new surface's entry
            // refocuses regardless of when the old field editor resigns.
            pinnedPanel?.makeKey()
            uiState.focusSubtaskEntry(for: familyID)
        }
        if let displaced {
            releaseFamilyInteractionState(displaced)
        }
    }

    /// Unpin returns to transient behaviour when a live row anchor exists;
    /// otherwise it simply dismisses. It never deletes or mutates tasks.
    func unpinPinned() {
        guard let familyID = lifecycle.unpin() else { return }
        pinnedPanel?.orderOut(nil)
        // Re-anchoring must not evict a different family that's mid-edit —
        // in that case unpin behaves like a plain close of the pinned window.
        let evictionBusy = lifecycle.transientFamilyID.map {
            $0 != familyID && surfaceInteractionBusy($0)
        } ?? false
        let refocusEntry = entryFocusEngaged(for: familyID)
        if mainPanelVisible, screenAnchorRect(for: familyID) != nil, !evictionBusy {
            lifecycle.openTransient(familyID, latched: true)
            presentTransient(familyID)
        }
        rescheduleTimers()
        syncState()
        if refocusEntry {
            transientPanel?.makeKey()
            uiState.focusSubtaskEntry(for: familyID)
        }
        // Runs after any transient re-anchoring: the release only fires when
        // no surface still hosts the family.
        releaseFamilyInteractionState(familyID)
    }

    func closePinned() {
        guard let familyID = lifecycle.unpin() else { return }
        pinnedPanel?.orderOut(nil)
        rescheduleTimers()
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
        pendingOpenWork?.cancel()
        pendingCloseWork?.cancel()
        pendingOpenWork = nil
        pendingCloseWork = nil
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
        let released = lifecycle.unpin()
        let transientWas = lifecycle.transientFamilyID
        lifecycle.closeTransient()
        transientPanel?.orderOut(nil)
        pinnedPanel?.orderOut(nil)
        transientFamilyID = nil
        pinnedFamilyID = nil
        uiState.setInteractionLock(.subtaskComposer, isActive: false)
        if let transientWas {
            releaseFamilyInteractionState(transientWas)
        }
        if let released {
            releaseFamilyInteractionState(released)
        }
    }

    // MARK: - Content metrics

    func measuredListHeight(for familyID: UUID) -> CGFloat? {
        listHeights[familyID]
    }

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
        }
        if pinnedFamilyID != lifecycle.pinnedFamilyID {
            pinnedFamilyID = lifecycle.pinnedFamilyID
        }
        if lifecycle.transientFamilyID == nil {
            transientPanel?.orderOut(nil)
        }
        if lifecycle.pinnedFamilyID == nil {
            pinnedPanel?.orderOut(nil)
        }
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
              lifecycle.pinnedFamilyID != familyID else { return }
        func isSurfaceHostedChild(_ id: UUID?) -> Bool {
            guard let id else { return false }
            return store.tasks.contains { $0.id == id && $0.parentID == familyID }
        }
        if isSurfaceHostedChild(uiState.editingTaskID) {
            uiState.endEditing()
        }
        if isSurfaceHostedChild(uiState.confirmingTaskDeletionID) {
            uiState.confirmingTaskDeletionID = nil
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
        rescheduleTimers()
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
            parentID: familyID,
            mode: mode
        )
    }

    private func presentTransient(_ familyID: UUID) {
        guard presentationEnabled,
              resolvedParent(familyID) != nil,
              let panel = panelWindow, panel.isVisible else { return }
        let host: SubtaskHostingView
        let surface: SubtaskAuxiliaryPanel
        if let existingPanel = transientPanel, let existingHost = transientHost {
            surface = existingPanel
            host = existingHost
            host.rootView = makeContent(familyID, mode: .transient)
        } else {
            host = SubtaskHostingView(rootView: makeContent(familyID, mode: .transient))
            surface = SubtaskAuxiliaryPanel(
                contentRect: CGRect(
                    origin: .zero,
                    size: CGSize(width: SubtaskPanelLayout.panelWidth, height: 160)
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            surface.isOpaque = false
            surface.backgroundColor = .clear
            surface.hasShadow = false
            surface.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            surface.hidesOnDeactivate = false
            surface.isMovable = false
            surface.acceptsMouseMovedEvents = true
            surface.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            AtticPanelInteractionPolicy.configure(surface)
            surface.contentView = host
            transientPanel = surface
            transientHost = host
        }
        // Escape dismisses the transient surface too (except while a field
        // editor owns it — there Escape cancels the entry instead).
        surface.onEscape = { [weak self] in self?.closeTransientSurface() }
        let fitting = fittingSize(of: host)
        let anchor = screenAnchorRect(for: familyID)
        let screen = anchorScreen(for: anchor) ?? panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        // Side decisions anchor to the panel's visible frame, not the
        // transparent resize perimeter that pads its window frame.
        let panelFrame = (panel as? AtticPanel)?.visibleContentFrame ?? panel.frame
        surface.setFrame(
            SubtaskPanelLayout.transientFrame(
                size: fitting,
                anchorScreenRect: anchor,
                panelScreenFrame: panelFrame,
                screenVisibleFrame: visibleFrame
            ),
            display: false
        )
        surface.setAccessibilityIdentifier("subtask-panel-\(familyID.uuidString)")
        orderSurfaceFront(surface)
    }

    /// Subtle fade-in honoring the user's reduced-motion preference — the
    /// surfaces intentionally skip the main panel's genie-style motion. An
    /// already-visible surface (family swap, pin replace) never fades.
    private func orderSurfaceFront(_ surface: NSWindow) {
        if surface.isVisible
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.alphaValue = 1
            surface.orderFrontRegardless()
        } else {
            surface.alphaValue = 0
            surface.orderFrontRegardless()
            surface.animator().alphaValue = 1
        }
    }

    /// Programmatic frame writes must not overwrite the user's remembered
    /// pinned position — windowDidMove saves only genuine user drags.
    private func setPinnedFrameProgrammatically(_ surface: NSWindow, _ frame: CGRect) {
        suppressPinnedMovePersist = true
        surface.setFrame(frame, display: true)
        suppressPinnedMovePersist = false
    }

    private func presentPinned(_ familyID: UUID, promotedFrame: CGRect?) {
        guard presentationEnabled, resolvedParent(familyID) != nil else { return }
        let host: SubtaskHostingView
        let surface: SubtaskPinnedPanel
        if let existingPanel = pinnedPanel, let existingHost = pinnedHost {
            surface = existingPanel
            host = existingHost
            host.rootView = makeContent(familyID, mode: .pinned)
        } else {
            host = SubtaskHostingView(rootView: makeContent(familyID, mode: .pinned))
            host.dragsWindowFromHeader = true
            surface = SubtaskPinnedPanel(
                contentRect: CGRect(
                    origin: .zero,
                    size: CGSize(width: SubtaskPanelLayout.panelWidth, height: 160)
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            surface.isOpaque = false
            surface.backgroundColor = .clear
            surface.hasShadow = false
            surface.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            surface.hidesOnDeactivate = false
            surface.isMovableByWindowBackground = false
            surface.acceptsMouseMovedEvents = true
            surface.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            AtticPanelInteractionPolicy.configure(surface)
            surface.contentView = host
            surface.delegate = self
            pinnedPanel = surface
            pinnedHost = host
        }
        surface.setAccessibilityIdentifier("subtask-pinned-\(familyID.uuidString)")
        surface.onEscape = { [weak self] in self?.closePinned() }
        let fitting = fittingSize(of: host)
        let frame = SubtaskPanelLayout.restoredPinnedFrame(
            saved: settings.pinnedSubtaskWindowFrame,
            size: fitting,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: promotedFrame ?? screenAnchorRect(for: familyID)
        )
        setPinnedFrameProgrammatically(surface, frame)
        orderSurfaceFront(surface)
    }

    private func repositionTransient() {
        guard presentationEnabled,
              let familyID = lifecycle.transientFamilyID,
              let surface = transientPanel, surface.isVisible,
              let panel = panelWindow, panel.isVisible,
              let host = transientHost else { return }
        let anchor = screenAnchorRect(for: familyID)
        let fitting = fittingSize(of: host)
        let screen = anchorScreen(for: anchor) ?? panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let panelFrame = (panel as? AtticPanel)?.visibleContentFrame ?? panel.frame
        surface.setFrame(
            SubtaskPanelLayout.transientFrame(
                size: fitting,
                anchorScreenRect: anchor,
                panelScreenFrame: panelFrame,
                screenVisibleFrame: visibleFrame
            ),
            display: true
        )
    }

    /// Every layout-affecting change re-fits the whole surface AND re-applies
    /// the screen-bound clamps — growth near a display edge can push controls
    /// offscreen, so a plain top-preserving resize is not enough.
    private func refreshSurfaceSizes() {
        guard presentationEnabled else { return }
        // The transient re-runs full placement: its anchor, side choice and
        // clamp all respond to the new height.
        if transientPanel?.isVisible == true {
            repositionTransient()
        }
        if let surface = pinnedPanel, surface.isVisible, let host = pinnedHost {
            let fitting = fittingSize(of: host)
            if let adjusted = SubtaskPanelLayout.pinnedResizedFrame(
                surface.frame,
                newHeight: fitting.height,
                screenVisibleFrames: NSScreen.screens.map(\.visibleFrame)
            ), adjusted != surface.frame {
                setPinnedFrameProgrammatically(surface, adjusted)
            }
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

    /// A latched (explicit-open) transient dismisses on any mouse-down outside
    /// its bounds — the familiar "click elsewhere to close" — while hover-open
    /// surfaces are dismissed by pointer leave alone.
    private func updateOutsideClickMonitoring() {
        let shouldMonitor = lifecycle.transientFamilyID != nil && lifecycle.isTransientLatched
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
        if containsTransientPoint(location) { return }
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

    private func handleScreenParametersChanged() {
        // Displays changed: reclamp the pinned window into a visible work
        // area and re-anchor the transient to its row's current position.
        if let surface = pinnedPanel, surface.isVisible {
            let host = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(surface.frame)
            }) ?? NSScreen.main
            if let host {
                let clamped = PanelGeometry.constrainedFrame(
                    surface.frame,
                    to: host.visibleFrame
                )
                if clamped != surface.frame {
                    setPinnedFrameProgrammatically(surface, clamped)
                }
            }
        }
        repositionTransient()
    }

    private func reconcileStore() {
        if let open = lifecycle.transientFamilyID, resolvedParent(open) == nil {
            closeTransientSurface()
        }
        if let pinned = lifecycle.pinnedFamilyID, resolvedParent(pinned) == nil {
            _ = lifecycle.unpin()
            syncState()
            releaseFamilyInteractionState(pinned)
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
    /// Only the pinned window moves; remember its screen position so a later
    /// pin restores here instead of beside the panel.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === pinnedPanel,
              !suppressPinnedMovePersist else { return }
        settings.pinnedSubtaskWindowFrame = window.frame
    }

    /// The pinned window owns its own lifetime: Cmd-W or other AppKit close
    /// paths dissolve the surface only — never the family itself.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === pinnedPanel else { return }
        if let released = lifecycle.unpin() {
            syncState()
            releaseFamilyInteractionState(released)
        }
    }
}
