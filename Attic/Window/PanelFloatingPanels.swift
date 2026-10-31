import AppKit
import Combine
import SwiftUI

/// What every panel's pages are made from: the app's one model container
/// (through its stores), the one Notes session and the one canvas.
@MainActor
struct PanelPageDependencies {
    let store: TaskStore
    let noteStore: NoteStore
    let canvasSession: CanvasSession
    let noteDraft: NoteDraftController
    let settings: AppSettings
    let tasksMemory: TasksPageMemory?
}

// MARK: - A floating panel

/// A page pulled out of the docked panel: a real panel window (an
/// `AtticPanel`, the docked panel's class, with its surface, glass and
/// shadow) hosting the shell (`AtticPanelView`) on one page, with its own
/// UI state, top row, "+", Search and messages. It has no island and no
/// corner docking: dragged by an empty part of its top row, it moves freely.
@MainActor
final class PanelFloatingPanel: NSObject, NSWindowDelegate {
    let page: PanelPage
    let panel: AtticPanel
    let uiState = PanelUIState()
    let toasts = PanelToastCenter()
    private let hostingView: AtticPanelHostingView
    private let chrome = PanelChromeInteractionState()
    private let store: TaskStore
    private var cancellables: Set<AnyCancellable> = []
    private var keyLookAwaitsRelease = false
    private var fadeGeneration = 0

    var onPressed: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGRect, CGPoint) -> CGRect)?
    var onDragEnded: ((CGRect, CGPoint) -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    var onResized: (() -> Void)?

    init(page: PanelPage, frame: CGRect, pinned: Bool, dependencies deps: PanelPageDependencies) {
        self.page = page
        store = deps.store
        uiState.becomeFloating(on: page)
        uiState.isPanelPinned = pinned
        uiState.updatePanelSize(frame.size)
        panel = AtticPanel(contentRect: CGRect(origin: .zero, size: frame.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hostingView = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: deps.store, noteStore: deps.noteStore, canvasSession: deps.canvasSession,
                noteDraft: deps.noteDraft, chromeInteractionState: chrome, uiState: uiState,
                settings: deps.settings, toasts: toasts,
                // Its own page state (its own Search and drafts), the
                // remembered views shared with the docked panel's.
                tasksPageState: TasksPageState(memory: deps.tasksMemory)),
            panelCornerRadius: deps.settings.panelCornerSize,
            dockedCorner: deps.settings.corner,
            chromeInteractionState: chrome)
        super.init()
        configure(frame: frame)
        uiState.loadPageContent()
    }

    private func configure(frame: CGRect) {
        panel.resizePerimeter = 0
        panel.surfaceMargin = AtticStyle.panelElevationMargin
        panel.setVisibleContentFrame(frame, display: false)
        panel.contentView = AtticPanelContentContainer(hostingView: hostingView, visibleSize: frame.size,
                                                       perimeter: panel.nativeMargin)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = AtticStyle.panelUsesSystemShadow
        // Above the docked panel and its island; a click raises one above
        // the other floating panels.
        panel.level = PanelPullOutController.floatingLevel
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // A window named after its page.
        panel.title = page.title
        panel.setAccessibilityTitle(page.title)
        AtticPanelInteractionPolicy.configure(panel)
        AtticPanelResizePolicy.configure(panel)
        panel.delegate = self
        panel.onPressEnded = { [weak self] in self?.pressEnded() }
        panel.onDirectContentInteraction = { [weak self] in self?.onPressed?() }
        panel.onUnhandledUndo = { [weak self] redo in
            guard let self, let history = AtticPanelController.unhandledUndoHistory(for: self.uiState.selectedSection),
                  let library = self.store.commandLibrary else { return }
            _ = redo ? library.redo(in: history) : library.undo(in: history)
        }
        panel.canPerformUnhandledUndo = { [weak self] redo in
            guard let self, let history = AtticPanelController.unhandledUndoHistory(for: self.uiState.selectedSection),
                  let library = self.store.commandLibrary else { return false }
            return redo ? library.undo.canRedo(in: history) : library.undo.canUndo(in: history)
        }
        hostingView.onWindowDragBegan = { [weak self] in
            guard let self else { return }
            uiState.setInteractionLock(.windowMove, isActive: true)
            onPressed?()
            onDragBegan?()
        }
        hostingView.onWindowDragChanged = { [weak self] frame, pointer in
            self?.onDragChanged?(frame, pointer) ?? frame
        }
        hostingView.onWindowDragEnded = { [weak self] frame, pointer, _, _ in
            guard let self else { return }
            uiState.setInteractionLock(.windowMove, isActive: false)
            onDragEnded?(frame, pointer)
        }
        hostingView.onInteractionCancelled = { [weak self] cancellation, frame in
            guard let self else { return }
            uiState.setInteractionLock(.windowMove, isActive: false)
            uiState.setInteractionLock(.windowResize, isActive: false)
            if cancellation.interaction == .windowMove { onDragEnded?(frame ?? visibleFrame, NSEvent.mouseLocation) }
        }
        hostingView.onLiveResizeBegan = { [weak self] in self?.uiState.setInteractionLock(.windowResize, isActive: true) }
        hostingView.onLiveResizeChanged = { [weak self] size in self?.uiState.updatePanelSize(size) }
        hostingView.onLiveResizeEnded = { [weak self] _ in
            guard let self else { return }
            uiState.updatePanelSize(visibleFrame.size)
            uiState.setInteractionLock(.windowResize, isActive: false)
            onResized?()
        }
        uiState.$isPanelPinned.dropFirst().removeDuplicates()
            .sink { [weak self] pinned in self?.onPinChanged?(pinned) }
            .store(in: &cancellables)
    }

    var visibleFrame: CGRect { panel.visibleContentFrame }
    var isVisible: Bool { panel.isVisible }

    func setFrame(_ frame: CGRect) {
        if panel.visibleContentFrame != frame { panel.setVisibleContentFrame(frame, display: panel.isVisible) }
        uiState.updatePanelSize(frame.size)
    }

    /// Orders it in, fading in over `fade` seconds (0: at once).
    func show(fade: TimeInterval, curve: CAMediaTimingFunction?) {
        fadeGeneration += 1
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = fade > 0 ? 0 : 1 }
        panel.orderFrontRegardless()
        uiState.panelDidReveal()
        animateAlpha(1, duration: wasVisible ? 0 : fade, curve: curve)
    }

    /// Fades it out over `fade` seconds, then orders it out.
    func hide(fade: TimeInterval, curve: CAMediaTimingFunction?) {
        guard panel.isVisible else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        hostingView.cancelActiveInteraction(reason: .explicitHide)
        animateAlpha(0, duration: fade, curve: curve) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.toasts.dismiss()
            self.uiState.panelDidHide()
        }
    }

    /// Gone for good (its page docked again): the window and its pages go.
    func close() {
        fadeGeneration += 1
        hostingView.cancelActiveInteraction(reason: .explicitHide)
        toasts.dismiss()
        panel.orderOut(nil)
        panel.delegate = nil
        uiState.releasePageContent()
        panel.contentView = nil
    }

    func makeKey() {
        guard panel.isVisible, panel.canBecomeKey, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    /// Whether `point` (screen) is on its surface while it shows.
    func contains(_ point: CGPoint) -> Bool {
        guard panel.isVisible, panel.alphaValue > 0.01 else { return false }
        let frame = panel.visibleContentFrame
        guard frame.contains(point) else { return false }
        return Squircle.contains(CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                                 in: CGRect(origin: .zero, size: frame.size),
                                 cornerRadius: hostingView.panelCornerRadius,
                                 exponent: AtticStyle.panelSquircleExponent)
    }

    #if DEBUG
    var hostingViewForTesting: AtticPanelHostingView { hostingView }
    #endif

    private func animateAlpha(_ alpha: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunction?,
                              completion: (@MainActor () -> Void)? = nil) {
        guard duration > 0 else {
            NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = alpha }
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve
            panel.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    // MARK: Key look (one click makes it active, as the docked panel)

    func windowDidBecomeKey(_ notification: Notification) {
        if panel.isPressing { keyLookAwaitsRelease = true } else { uiState.setPanelKey(true) }
        onPressed?()
    }

    private func pressEnded() {
        guard keyLookAwaitsRelease else { return }
        keyLookAwaitsRelease = false
        if panel.isKeyWindow { uiState.setPanelKey(true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        keyLookAwaitsRelease = false
        uiState.setPanelKey(false)
        hostingView.cancelActiveInteraction(reason: .windowDeactivated)
    }

    func windowDidResize(_ notification: Notification) {
        uiState.updatePanelSize(panel.visibleContentFrame.size)
    }
}

// MARK: - The landing outline

/// Where a dropped panel will land: the docked panel's surface, a blue
/// inset ring over a faint blue fill (the design's 4 px at 50 %, 5 %),
/// under the panel being dragged. It never takes the pointer.
@MainActor
final class PanelLandingOutline {
    let window: NSPanel
    private(set) var isShown = false

    init(cornerRadius: CGFloat) {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let shape = Squircle(cornerRadius: cornerRadius, exponent: AtticStyle.panelSquircleExponent)
        window.contentView = NSHostingView(rootView: shape
            .fill(PanelPullOutLayout.blue.opacity(0.05))
            .overlay(shape.strokeBorder(PanelPullOutLayout.blue.opacity(0.5), lineWidth: PanelPullOutLayout.outlineWidth))
            .accessibilityHidden(true))
        window.setAccessibilityElement(false)
    }

    func show(at frame: CGRect) {
        if window.frame != frame { window.setFrame(frame, display: true) }
        guard !isShown else { return }
        isShown = true
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AtticMotionPreference.reducesMotion ? 0 : 0.12
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        window.alphaValue = 0
        window.orderOut(nil)
    }
}

// MARK: - The pull-out

/// Pulls pages out of the docked panel into their own panels and snaps
/// them back in (Accepted "Tall island", "Pull a page out, snap it back
/// in"). The docked panel's controller owns it, feeds it the docked
/// panel's and island's geometry, and asks it about hiding and the
/// pointer: the docked panel, the island and every floating panel are one
/// area for auto-hide.
@MainActor
final class PanelPullOutController {
    static let floatingLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    /// The docked panel's dock motion, which a panel flying home rides.
    static let flyDuration: TimeInterval = 0.18
    static let curve = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)

    private let deps: PanelPageDependencies
    private let docked: PanelUIState
    private(set) var state = PanelPullOutState()
    private var panels: [PanelPage: PanelFloatingPanel] = [:]
    private let outline: PanelLandingOutline
    private var cancellables: Set<AnyCancellable> = []

    private struct Drag {
        let page: PanelPage
        /// From the panel's top-left corner, for a pull off the island.
        let grab: CGPoint?
        var snap: PanelPullOutLayout.Snap?
    }
    private var drag: Drag?

    // The docked panel's controller answers these.
    /// The docked panel's surface, while it shows.
    var dockedFrame: () -> CGRect? = { nil }
    /// The island's capsule, while it shows.
    var islandFrame: () -> CGRect? = { nil }
    /// The work area (placement frame) of the screen holding `point`.
    var workArea: (CGPoint) -> CGRect? = { _ in nil }
    var workAreas: () -> [CGRect] = { [] }
    var makeDockedKey: () -> Void = {}
    /// The island's model (its out dots and ring).
    var island: PanelIslandModel { docked.island }

    init(docked: PanelUIState, dependencies: PanelPageDependencies) {
        self.docked = docked
        deps = dependencies
        outline = PanelLandingOutline(cornerRadius: dependencies.settings.panelCornerSize)
        docked.onPageElsewhere = { [weak self] page in self?.bringForward(page) }
        docked.onOpenElsewhere = { [weak self] page, switchesDocked in
            self?.bringForward(page, switchesDocked: switchesDocked) ?? false
        }
        docked.$selectedSection.map(PanelPage.init).removeDuplicates()
            .sink { [weak self] page in self?.state.dockedShows(page) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.keepOnScreens() } }
            .store(in: &cancellables)
    }

    func panel(for page: PanelPage) -> PanelFloatingPanel? { panels[page] }
    var floatingPanels: [PanelFloatingPanel] { state.floating.compactMap { panels[$0.page] } }
    var isDragging: Bool { drag != nil }

    // MARK: Pulling out

    /// A pull off the island (`PanelIslandWindows.onPull`).
    func handle(_ pull: PanelIslandPull) {
        switch pull {
        case let .began(page, point): beginPull(page, at: point)
        case let .moved(point): movePull(to: point)
        case let .ended(point): endPull(at: point)
        }
    }

    /// `page` comes out under `pointer`, held at its top row. A page that
    /// is out already is picked up the same way. False when it can't come
    /// out (the docked panel's last page, or a Notes save that refused).
    @discardableResult
    func beginPull(_ page: PanelPage, at pointer: CGPoint) -> Bool {
        guard drag == nil else { return false }
        let size = docked.panelSize
        let grab = PanelPullOutLayout.grab(for: panels[page]?.visibleFrame.size ?? size)
        if let floating = panels[page] {
            raise(page, makeKey: false)
            drag = Drag(page: page, grab: grab)
            place(floating, under: pointer)
            return true
        }
        guard state.canPullOut(page) else { return false }
        let dockedPage = PanelPage(docked.selectedSection)
        if page == .notes, dockedPage == .notes {
            guard deps.noteDraft.prepareToLeave(.pageSwitch) else { return false }
        }
        guard let back = state.fallback(for: page) else { return false }
        let frame = clamped(PanelPullOutLayout.frame(under: pointer, grab: grab, size: size), at: pointer)
        state.pullOut(page, at: frame)
        // The docked panel shows the page it showed before.
        if dockedPage == page {
            if dockedPage == .canvas { deps.canvasSession.interruptActiveInteraction() }
            docked.setInteractionLock(.quickEntryFocus, isActive: false)
            docked.switchPage(to: back.section, motion: .instant) {
                if back == .notes { deps.noteDraft.pages.present() }
            }
        }
        docked.setPagesElsewhere(state.outPages)
        let floating = makePanel(page, frame: frame, pinned: false)
        floating.show(fade: fadeDuration(showing: true), curve: Self.curve)
        arrived(floating)
        drag = Drag(page: page, grab: grab)
        save()
        return true
    }

    func movePull(to pointer: CGPoint) {
        guard let drag, let floating = panels[drag.page] else { return }
        place(floating, under: pointer)
    }

    func endPull(at pointer: CGPoint) {
        guard let drag, let floating = panels[drag.page] else { self.drag = nil; return }
        finishDrag(floating, frame: floating.visibleFrame, pointer: pointer)
    }

    private func place(_ floating: PanelFloatingPanel, under pointer: CGPoint) {
        guard let grab = drag?.grab else { return }
        let frame = PanelPullOutLayout.frame(under: pointer, grab: grab, size: floating.visibleFrame.size)
        floating.setFrame(dragged(floating.page, frame: frame, pointer: pointer))
    }

    /// A drag's frame kept inside the work area, and the snap it shows.
    private func dragged(_ page: PanelPage, frame: CGRect, pointer: CGPoint) -> CGRect {
        let clampedFrame = clamped(frame, at: pointer)
        let snap = snapTarget(pointer: pointer, frame: clampedFrame)
        drag?.snap = snap
        island.setSnapTarget(snap == .island)
        if snap != nil, let home = dockedFrame() {
            outline.show(at: home)
            // Under the panel being dragged.
            panels[page]?.panel.orderFrontRegardless()
        } else {
            outline.hide()
        }
        return clampedFrame
    }

    private func snapTarget(pointer: CGPoint, frame: CGRect) -> PanelPullOutLayout.Snap? {
        guard let home = dockedFrame() else { return nil }
        return PanelPullOutLayout.snap(pointer: pointer, frame: frame, island: islandFrame(), home: home)
    }

    private func clamped(_ frame: CGRect, at pointer: CGPoint) -> CGRect {
        guard let area = workArea(pointer) ?? workArea(CGPoint(x: frame.midX, y: frame.midY)) else { return frame }
        return PanelPullOutLayout.clamp(frame, to: area)
    }

    private func finishDrag(_ floating: PanelFloatingPanel, frame: CGRect, pointer: CGPoint) {
        let snap = drag?.snap ?? snapTarget(pointer: pointer, frame: frame)
        drag = nil
        island.setSnapTarget(false)
        outline.hide()
        if snap != nil, dockIn(floating.page) { return }
        state.move(floating.page, to: floating.visibleFrame)
        save()
    }

    // MARK: Snapping in

    /// `page` flies home on the panel's motion (Reduce Motion: at once)
    /// and the docked panel shows it. False when it stays out (Notes
    /// refused to leave, or the docked panel isn't showing).
    @discardableResult
    func dockIn(_ page: PanelPage) -> Bool {
        guard let floating = panels[page], let home = dockedFrame() else { return false }
        if page == .notes { guard deps.noteDraft.prepareToLeave(.pageSwitch) else { return false } }
        let finish = { [weak self] in
            guard let self else { return }
            panels[page] = nil
            floating.close()
            state.dockIn(page)
            docked.setPagesElsewhere(state.outPages)
            switchDocked(to: page)
            makeDockedKey()
            save()
        }
        if AtticMotionPreference.reducesMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.flyDuration
                context.timingFunction = Self.curve
                floating.panel.animator().setFrame(floating.panel.nativeFrame(forVisibleFrame: home), display: true)
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        }
        return true
    }

    // MARK: Bringing forward

    /// A request for `page` from a panel that doesn't host it: its own
    /// panel comes forward if it is out; otherwise the docked panel shows
    /// it. Returns false when nothing could show it.
    @discardableResult
    func bringForward(_ page: PanelPage, switchesDocked: Bool = true) -> Bool {
        if state.isOut(page) {
            raise(page, makeKey: true)
            return true
        }
        guard switchesDocked else { return false }
        guard switchDocked(to: page) else { return false }
        makeDockedKey()
        return true
    }

    func raise(_ page: PanelPage, makeKey: Bool) {
        guard let floating = panels[page] else { return }
        state.raise(page)
        if !floating.isVisible { floating.show(fade: 0, curve: nil); arrived(floating) }
        floating.panel.orderFrontRegardless()
        if makeKey { floating.makeKey() }
        save()
    }

    @discardableResult
    private func switchDocked(to page: PanelPage) -> Bool {
        let current = PanelPage(docked.selectedSection)
        guard current != page else { return true }
        if current == .notes { guard deps.noteDraft.prepareToLeave(.pageSwitch) else { return false } }
        if current == .canvas { deps.canvasSession.interruptActiveInteraction() }
        docked.setInteractionLock(.quickEntryFocus, isActive: false)
        docked.switchPage(to: page.section, motion: .instant) {
            if page == .notes { deps.noteDraft.pages.present() }
        }
        return true
    }

    // MARK: Hiding with the docked panel

    /// Whether the docked panel's hide must leave the Notes session be (it
    /// floats in a pinned panel that stays).
    var notesStaysOnScreen: Bool { state.isOut(.notes) && state.staysWhenDockedHides(.notes) }

    /// The docked panel is hiding: unpinned floating panels go with it.
    func dockedWillHide(duration: TimeInterval) {
        drag = nil
        outline.hide()
        island.setSnapTarget(false)
        for page in state.hidingWithDocked {
            panels[page]?.hide(fade: max(duration, fadeDuration(showing: false)), curve: Self.curve)
        }
    }

    /// The docked panel shows again: so do the floating panels, in front.
    func dockedDidShow() {
        for record in state.floating {
            guard let floating = panels[record.page] else { continue }
            if !floating.isVisible {
                floating.show(fade: fadeDuration(showing: true), curve: Self.curve)
                arrived(floating)
            } else {
                floating.panel.orderFrontRegardless()
            }
        }
    }

    /// The pointer on a floating panel is on the panel.
    func contains(_ point: CGPoint) -> Bool { floatingPanels.contains { $0.contains(point) } }

    /// What holds the unpinned floating panels open (an editor, a menu):
    /// they hide with the docked panel, so it doesn't hide under them.
    var interactionLockReasons: Set<PanelInteractionLockReason> {
        state.hidingWithDocked.compactMap { panels[$0] }.filter(\.isVisible)
            .reduce(into: Set()) { $0.formUnion($1.uiState.interactionLockReasons) }
    }

    // MARK: Restoring and saving

    /// The pages that were out at the last quit, on the screens there are
    /// now; pinned ones show at once, the others with the docked panel.
    func restore() {
        let records = PanelPullOutState.decode(deps.settings.floatingPanelsData)
        guard !records.isEmpty else { return }
        state = PanelPullOutState.restored(records, workAreas: workAreas())
        state.dockedShows(PanelPage(docked.selectedSection))
        let dockedPage = PanelPage(docked.selectedSection)
        if state.isOut(dockedPage), let back = state.fallback(for: dockedPage) {
            docked.switchPage(to: back.section, motion: .instant)
        }
        docked.setPagesElsewhere(state.outPages)
        for record in state.floating {
            let floating = makePanel(record.page, frame: record.frame, pinned: record.isPinned)
            if record.isPinned {
                floating.show(fade: 0, curve: nil)
                arrived(floating)
            }
        }
        save()
    }

    private func keepOnScreens() {
        let areas = workAreas()
        guard !areas.isEmpty else { return }
        for record in state.floating {
            guard let floating = panels[record.page],
                  let frame = PanelPullOutLayout.restore(floating.visibleFrame, workAreas: areas) else { continue }
            floating.setFrame(frame)
            state.move(record.page, to: frame)
        }
        save()
    }

    private func save() {
        let data = state.encoded()
        if deps.settings.floatingPanelsData != data { deps.settings.floatingPanelsData = data }
    }

    // MARK: Making panels

    private func makePanel(_ page: PanelPage, frame: CGRect, pinned: Bool) -> PanelFloatingPanel {
        let floating = PanelFloatingPanel(page: page, frame: frame, pinned: pinned, dependencies: deps)
        floating.uiState.onPageElsewhere = { [weak self] other in self?.bringForward(other) }
        floating.uiState.onOpenElsewhere = { [weak self] other, switchesDocked in
            self?.bringForward(other, switchesDocked: switchesDocked) ?? false
        }
        floating.onPressed = { [weak self] in
            guard let self, state.front != page else { return }
            state.raise(page)
            floating.panel.orderFrontRegardless()
            save()
        }
        floating.onDragBegan = { [weak self] in self?.drag = Drag(page: page, grab: nil) }
        floating.onDragChanged = { [weak self] frame, pointer in
            self?.dragged(page, frame: frame, pointer: pointer) ?? frame
        }
        floating.onDragEnded = { [weak self, weak floating] frame, pointer in
            guard let self, let floating else { return }
            finishDrag(floating, frame: frame, pointer: pointer)
        }
        floating.onPinChanged = { [weak self] pinned in
            self?.state.setPinned(page, pinned)
            self?.save()
        }
        floating.onResized = { [weak self, weak floating] in
            guard let self, let floating else { return }
            state.move(page, to: floating.visibleFrame)
            save()
        }
        panels[page] = floating
        return floating
    }

    /// A page arriving in a panel: Notes shows its session there (a fresh
    /// Notes view; TextKit 2 views lose focus when moved between windows).
    private func arrived(_ floating: PanelFloatingPanel) {
        guard floating.page == .notes else { return }
        DispatchQueue.main.async { [deps] in deps.noteDraft.pages.present() }
    }

    private func fadeDuration(showing: Bool) -> TimeInterval {
        deps.settings.hideMotionDuration(.slide, hiding: !showing)
    }
}
