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
    private var transientHost: NSHostingView<SubtaskPanelContent>?
    private var pinnedPanel: SubtaskPinnedPanel?
    private var pinnedHost: NSHostingView<SubtaskPanelContent>?

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
    /// the same click is suppressed.
    private var lastOutsideDismissal: (familyID: UUID, at: TimeInterval)?

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
            .sink { [weak self] _ in self?.refreshSurfaceSizes() }
            .store(in: &cancellables)
        uiState.$selectedSection
            .dropFirst()
            .sink { [weak self] _ in self?.dismissTransient() }
            .store(in: &cancellables)
        uiState.$subtaskDrafts
            .dropFirst()
            .sink { [weak self] _ in self?.syncComposerLock() }
            .store(in: &cancellables)
        uiState.$focusedSubtaskParentID
            .dropFirst()
            .sink { [weak self] _ in self?.syncComposerLock() }
            .store(in: &cancellables)
        uiState.$subtaskEntryActiveIDs
            .dropFirst()
            .sink { [weak self] _ in self?.refreshSurfaceSizes() }
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
        notificationTokens.append(contentsOf: [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionTransient() }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionTransient() }
            }
        ])
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
        // Hovering another row while the open surface has an in-flight edit
        // or a tracked menu must not replace it mid-interaction.
        if isHovering, let current = lifecycle.transientFamilyID,
           current != familyID, surfaceInteractionBusy(current) {
            return
        }
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
        // Defense in depth alongside the noteRowHover gate: if the current
        // surface became edit/menu busy after the dwell was scheduled, drop
        // the pending claim rather than swap families mid-interaction.
        if lifecycle.pendingOpen?.familyID == familyID,
           let current = lifecycle.transientFamilyID, current != familyID,
           surfaceInteractionBusy(current) {
            lifecycle.discardPendingOpen()
            rescheduleTimers()
            return
        }
        guard lifecycle.maturePendingOpen(for: familyID, at: Self.now()) else { return }
        // Hover opens only for a real family with a live anchor: no empty
        // panels for childless rows, none for rows already scrolled away.
        guard screenAnchorRect(for: familyID) != nil, hoverWorthy(familyID) else {
            lifecycle.closeTransient()
            syncState()
            return
        }
        presentTransient(familyID)
        syncState()
    }

    private func commitPendingClose(for familyID: UUID) {
        // Menus, inline editors, and confirmation alerts raise interaction
        // locks — pointer position alone must not close the surface
        // underneath them mid-action. Retry rather than drop: once the lock
        // clears, the overdue leave closes it without needing new hover.
        if uiState.isInteractionLocked {
            lifecycle.noteRowHover(familyID: familyID, isHovering: false, at: Self.now())
            rescheduleTimers()
            return
        }
        guard lifecycle.maturePendingClose(for: familyID, at: Self.now()) else { return }
        syncState()
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

    /// Guard shared by hover dwell, explicit opens, and outside clicks.
    func surfaceInteractionBusy(_ familyID: UUID) -> Bool {
        familyEditBusy(familyID) || menuTrackingActive
    }

    /// The transient surface's composer work is what keeps the main panel
    /// alive — a pinned window is independent and a dismissed surface's
    /// retained draft must not lock anything.
    private func syncComposerLock() {
        let active = lifecycle.transientFamilyID.map { familyID in
            !(uiState.subtaskDrafts[familyID] ?? "").isEmpty
                || uiState.focusedSubtaskParentID == familyID
        } ?? false
        uiState.setInteractionLock(.subtaskComposer, isActive: active)
    }

    /// The family's single pinned surface is already up — raise it (and
    /// focus its entry when asked) instead of showing a second surface.
    private func raisePinned(focusEntry: Bool) {
        pinnedPanel?.deminiaturize(nil)
        pinnedPanel?.orderFrontRegardless()
        if focusEntry, let familyID = lifecycle.pinnedFamilyID {
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
        // precedence over switching it to another family.
        if let current = lifecycle.transientFamilyID, current != familyID,
           surfaceInteractionBusy(current) {
            return
        }
        guard lifecycle.openTransient(familyID, latched: true) else { return }
        presentTransient(familyID)
        syncState()
        if focusEntry {
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
        // of the toggle, not a cue to reopen.
        if let last = lastOutsideDismissal,
           last.familyID == familyID,
           Self.now() - last.at < 0.5 {
            lastOutsideDismissal = nil
            return
        }
        openFamilyPanel(for: familyID, focusEntry: false)
    }

    func dismissTransient() {
        lifecycle.closeTransient()
        rescheduleTimers()
        syncState()
    }

    /// The transient surface's geometric hit test, used to extend the main
    /// panel's "pointer inside" coverage so hovering the open checklist never
    /// fights auto-hide. The pinned window is deliberately excluded: it lives
    /// independently of the main panel.
    func containsTransientPoint(_ point: CGPoint) -> Bool {
        guard let panel = transientPanel, panel.isVisible,
              panel.frame.contains(point) else { return false }
        let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        return Squircle.contains(
            local,
            in: CGRect(origin: .zero, size: panel.frame.size),
            cornerRadius: AtticStyle.panelCornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )
    }

    // MARK: - Pin / unpin

    /// Promotes the shared checklist into the pinned mini-window. Pinning a
    /// second family resolves the existing window first — v1 allows exactly
    /// one — and drafts live in `uiState.subtaskDrafts`, so they follow.
    func pinFamily(_ familyID: UUID) {
        guard resolvedParent(familyID) != nil else { return }
        let promotedFrame = lifecycle.transientFamilyID == familyID
            && transientPanel?.isVisible == true
            ? transientPanel?.frame
            : nil
        lifecycle.pin(familyID)
        presentPinned(familyID, promotedFrame: promotedFrame)
        rescheduleTimers()
        syncState()
    }

    /// Unpin returns to transient behaviour when a live row anchor exists;
    /// otherwise it simply dismisses. It never deletes or mutates tasks.
    func unpinPinned() {
        guard let familyID = lifecycle.unpin() else { return }
        pinnedPanel?.orderOut(nil)
        if mainPanelVisible, screenAnchorRect(for: familyID) != nil {
            lifecycle.openTransient(familyID, latched: true)
            presentTransient(familyID)
        }
        rescheduleTimers()
        syncState()
    }

    func closePinned() {
        guard lifecycle.unpin() != nil else { return }
        pinnedPanel?.orderOut(nil)
        rescheduleTimers()
        syncState()
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
        _ = lifecycle.unpin()
        lifecycle.closeTransient()
        transientPanel?.orderOut(nil)
        pinnedPanel?.orderOut(nil)
        transientFamilyID = nil
        pinnedFamilyID = nil
        uiState.setInteractionLock(.subtaskComposer, isActive: false)
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

    private func closeTransientSurface() {
        lifecycle.closeTransient()
        rescheduleTimers()
        syncState()
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
        let host: NSHostingView<SubtaskPanelContent>
        let surface: SubtaskAuxiliaryPanel
        if let existingPanel = transientPanel, let existingHost = transientHost {
            surface = existingPanel
            host = existingHost
            host.rootView = makeContent(familyID, mode: .transient)
        } else {
            host = NSHostingView(rootView: makeContent(familyID, mode: .transient))
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
    /// surfaces intentionally skip the main panel's genie-style motion.
    private func orderSurfaceFront(_ surface: NSWindow) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            surface.orderFrontRegardless()
        } else {
            surface.alphaValue = 0
            surface.orderFrontRegardless()
            surface.animator().alphaValue = 1
        }
    }

    private func presentPinned(_ familyID: UUID, promotedFrame: CGRect?) {
        guard presentationEnabled, resolvedParent(familyID) != nil else { return }
        let host: NSHostingView<SubtaskPanelContent>
        let surface: SubtaskPinnedPanel
        if let existingPanel = pinnedPanel, let existingHost = pinnedHost {
            surface = existingPanel
            host = existingHost
            host.rootView = makeContent(familyID, mode: .pinned)
        } else {
            host = NSHostingView(rootView: makeContent(familyID, mode: .pinned))
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
            surface.isMovableByWindowBackground = true
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
        surface.setFrame(frame, display: false)
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
                surface.setFrame(adjusted, display: true)
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
        if surface.frame.contains(location) { return }
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
                    surface.setFrame(clamped, display: true)
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
        }
        // Child adds/removals, status changes, and error rows all change the
        // content height — re-fit (and re-clamp) on every store revision.
        refreshSurfaceSizes()
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
              window === pinnedPanel else { return }
        settings.pinnedSubtaskWindowFrame = window.frame
    }

    /// The pinned window owns its own lifetime: Cmd-W or other AppKit close
    /// paths dissolve the surface only — never the family itself.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === pinnedPanel else { return }
        _ = lifecycle.unpin()
        syncState()
    }
}
