import AppKit
import Combine
import SwiftUI

/// Borderless hover surface that lives beside a task row. It is never
/// user-movable, never enters the Dock, and dismisses with the main panel.
private final class SubtaskAuxiliaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The pinned mini-window: a persistent, draggable counterpart to the
/// transient surface. Closing it only dismisses the surface — it neither
/// quits the app nor touches task data.
private final class SubtaskPinnedPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // Escape closes the window, but never while a field editor owns it —
        // there it remains "cancel editing", not "close the checklist".
        if event.keyCode == 53,
           !(firstResponder is NSTextView) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
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
    private var transientHost: NSHostingView<SubtaskPanelContent>?
    private var pinnedPanel: SubtaskPinnedPanel?
    private var pinnedHost: NSHostingView<SubtaskPanelContent>?

    /// Row frames in the panel workspace coordinate space, republished on
    /// every scroll/layout pass by `TaskRowAnchorPreferenceKey`.
    private var rowFrames: [UUID: CGRect] = [:]
    private var listViewport: CGRect = .null

    private var pendingOpenWork: DispatchWorkItem?
    private var pendingCloseWork: DispatchWorkItem?
    private var outsideClickMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
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
        uiState.$selectedSection
            .dropFirst()
            .sink { [weak self] _ in self?.dismissTransient() }
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
        guard let panel = panelWindow, panel.isVisible,
              let hostView,
              let row = rowFrames[familyID] else { return nil }
        if !listViewport.isNull, !row.intersects(listViewport) {
            return nil
        }
        return panel.convertToScreen(hostView.convert(row, to: nil))
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

    /// A family is hover-presentable when it has children or an in-flight
    /// draft; childless rows rely on the explicit Add subtask path instead.
    private func hoverWorthy(_ familyID: UUID) -> Bool {
        !store.subtasks(of: familyID).isEmpty
            || !(uiState.subtaskDrafts[familyID] ?? "").isEmpty
    }

    private func resolvedParent(_ familyID: UUID) -> TaskItem? {
        store.tasks.first { $0.id == familyID && $0.parentID == nil }
    }

    // MARK: - Explicit surface control

    /// Click/keyboard/VoiceOver path: opens the same family panel latched so
    /// it never depends on pointer position, and optionally focuses entry.
    func openFamilyPanel(for familyID: UUID, focusEntry: Bool) {
        guard resolvedParent(familyID) != nil else { return }
        guard panelWindow?.isVisible == true else { return }
        lifecycle.openTransient(familyID, latched: true)
        presentTransient(familyID)
        syncState()
        if focusEntry {
            uiState.focusSubtaskEntry(for: familyID)
        }
    }

    /// The inline count control toggles presentation for its family: an open
    /// surface (hover or latched) closes, anything else opens latched.
    func toggleFamilyPanel(for familyID: UUID) {
        if lifecycle.transientFamilyID == familyID {
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
        if panelWindow?.isVisible == true, screenAnchorRect(for: familyID) != nil {
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
        guard resolvedParent(familyID) != nil,
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
        surface.orderFrontRegardless()
    }

    private func presentPinned(_ familyID: UUID, promotedFrame: CGRect?) {
        guard resolvedParent(familyID) != nil else { return }
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
            surface.onEscape = { [weak self] in self?.closePinned() }
            pinnedPanel = surface
            pinnedHost = host
        }
        surface.setAccessibilityIdentifier("subtask-pinned-\(familyID.uuidString)")
        let fitting = fittingSize(of: host)
        let frame = SubtaskPanelLayout.restoredPinnedFrame(
            saved: settings.pinnedSubtaskWindowFrame,
            size: fitting,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: promotedFrame ?? screenAnchorRect(for: familyID)
        )
        surface.setFrame(frame, display: false)
        surface.orderFrontRegardless()
    }

    private func repositionTransient() {
        guard let familyID = lifecycle.transientFamilyID,
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

    /// Growing content keeps the surface's top edge stationary so the panel
    /// extends downward from its anchor rather than drifting.
    private func refreshSurfaceSizes() {
        if let surface = transientPanel, surface.isVisible, let host = transientHost {
            let fitting = fittingSize(of: host)
            if let adjusted = SubtaskPanelLayout.framePreservingTop(
                surface.frame, height: fitting.height
            ) {
                surface.setFrame(adjusted, display: true)
            }
        }
        if let surface = pinnedPanel, surface.isVisible, let host = pinnedHost {
            let fitting = fittingSize(of: host)
            if let adjusted = SubtaskPanelLayout.framePreservingTop(
                surface.frame, height: fitting.height
            ) {
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
                MainActor.assumeIsolated { self?.noteOutsideMouseDown() }
                return event
            }
            if let local { outsideClickMonitors.append(local) }
            let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteOutsideMouseDown() }
            }
            if let global { outsideClickMonitors.append(global) }
        } else if !shouldMonitor, !outsideClickMonitors.isEmpty {
            outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
            outsideClickMonitors.removeAll()
        }
    }

    private func noteOutsideMouseDown() {
        guard let openFamily = lifecycle.transientFamilyID,
              let surface = transientPanel, surface.isVisible else { return }
        let location = NSEvent.mouseLocation
        if surface.frame.contains(location) { return }
        // Only a mouse-down inside the family's own row can be the count
        // control's toggle mousedown — remember it so the paired action does
        // not reopen what the click just dismissed. Dismissals triggered by
        // clicks elsewhere leave no suppression behind.
        if screenAnchorRect(for: openFamily)?.contains(location) == true {
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
