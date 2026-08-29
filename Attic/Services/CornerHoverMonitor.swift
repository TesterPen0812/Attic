import AppKit
import SwiftUI

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
    private var pollingTimer: DispatchSourceTimer?
    private var screenChangeToken: NSObjectProtocol?
    private var responsivenessActivity: NSObjectProtocol?
    private var revealRefreshTask: Task<Void, Never>?
    private var dragReleaseTask: Task<Void, Never>?

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
    }

    func start() {
        guard pollingTimer == nil else { return }

        responsivenessActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the configured Attic corner responsive"
        )

        // A coalesced 20 Hz sample keeps the corner responsive without tracking raw mouse events.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(50),
            leeway: .milliseconds(15)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        pollingTimer = timer
        timer.resume()

        screenChangeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.samplePointer() }
        }
    }

    func stop() {
        pollingTimer?.cancel()
        pollingTimer = nil
        revealRefreshTask?.cancel()
        revealRefreshTask = nil
        dragReleaseTask?.cancel()
        dragReleaseTask = nil
        if let screenChangeToken { NotificationCenter.default.removeObserver(screenChangeToken) }
        screenChangeToken = nil
        if let responsivenessActivity {
            ProcessInfo.processInfo.endActivity(responsivenessActivity)
            self.responsivenessActivity = nil
        }
        stateMachine.forceHidden()
        panelController.hide()
    }

    func revealProgrammatically(openComposer: Bool = false, section: PanelSection? = nil) {
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: section) else { return }
        refreshStoreForReveal()
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 3)
        panelController.show(on: screen, corner: settings.corner, makeKey: openComposer)
    }

    func keepVisibleForUITesting(openComposer: Bool = false) {
        guard let screen = NSScreen.main else { return }
        guard preparePresentation(openComposer: openComposer, section: nil) else { return }
        stateMachine.forceVisible(at: ProcessInfo.processInfo.systemUptime, grace: 86_400)
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

    private func samplePointer() {
        let location = NSEvent.mouseLocation
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
            // the 20 Hz pointer sampling path.
            refreshStoreForReveal()
            panelController.show(on: activeScreen, corner: settings.corner)
        case .hide:
            panelController.hide()
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            // Edge-pinned pointer coordinates can land exactly on frame.maxX, outside
            // every screen frame; tolerate a 1 pt overshoot so corners keep working.
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private func refreshStoreForReveal() {
        store.refresh()
        noteStore.refresh()
        canvasStore.refresh()
        revealRefreshTask?.cancel()
        revealRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.store.refresh()
            self.noteStore.refresh()
            self.canvasStore.refresh()
        }
    }
}
