import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AtticPanelController {
    private let panel: AtticPanel
    private let containerView: NSView
    private let backdropView: OpticalPanelBackdropView
    private let hostingView: NSHostingView<AtticPanelView>
    private let store: TaskStore
    private let noteStore: NoteStore
    private let noteDraft: NoteDraftController
    private let settings: AppSettings
    private let uiState: PanelUIState
    private var cancellables: Set<AnyCancellable> = []
    private var isShowing = false
    private var needsResizeAfterShowing = false
    private var transitionGeneration = 0
    private(set) var currentScreen: NSScreen?
    private(set) var currentCorner: ScreenCorner = .topRight

    init(
        store: TaskStore,
        noteStore: NoteStore,
        noteDraft: NoteDraftController,
        settings: AppSettings,
        uiState: PanelUIState,
        opticalPermissionController: OpticalPermissionController,
        opticalEnvironmentMonitor: OpticalEnvironmentMonitor
    ) {
        self.store = store
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.settings = settings
        self.uiState = uiState

        let initialSize = CGSize(
            width: settings.panelContentSize,
            height: PanelGeometry.minimumHeight
        )
        panel = AtticPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        containerView = NSView(frame: CGRect(origin: .zero, size: initialSize))
        backdropView = OpticalPanelBackdropView(
            controls: settings.opticalGlassControls,
            preset: settings.glassPerformancePreset,
            cornerRadius: settings.panelCornerSize,
            permissionController: opticalPermissionController,
            environmentMonitor: opticalEnvironmentMonitor
        )
        hostingView = NSHostingView(rootView: AtticPanelView(
            store: store,
            noteStore: noteStore,
            noteDraft: noteDraft,
            uiState: uiState,
            settings: settings
        ))

        configurePanel()
        bindContentSize()
    }

    var visibleFrame: CGRect? {
        panel.isVisible ? panel.frame : nil
    }

    func show(on screen: NSScreen, corner: ScreenCorner, makeKey: Bool = false) {
        currentScreen = screen
        currentCorner = corner
        let finalFrame = frame(on: screen, corner: corner)
        updateOpticalBackdrop(screen: screen, frame: finalFrame)
        backdropView.setVisible(true)

        if panel.isVisible {
            if makeKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            panel.alphaValue = 1

            guard !framesMatch(panel.frame, finalFrame) else { return }
            animateShow(to: finalFrame, fadeIn: false)
            return
        }

        let initialFrame = PanelGeometry.hiddenFrame(from: finalFrame, corner: corner)
        panel.setFrame(initialFrame, display: true)
        panel.alphaValue = 0

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        animateShow(to: finalFrame, fadeIn: true)
    }

    private func animateShow(to finalFrame: CGRect, fadeIn: Bool) {
        transitionGeneration += 1
        let generation = transitionGeneration
        isShowing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(finalFrame, display: true)
            if fadeIn { panel.animator().alphaValue = 1 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard generation == self.transitionGeneration else { return }
                self.isShowing = false
                self.updateOpticalBackdrop(screen: self.currentScreen, frame: finalFrame)
                if self.needsResizeAfterShowing {
                    self.needsResizeAfterShowing = false
                    self.resizeAndReanchor()
                }
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        guard noteDraft.flush() else { return }
        backdropView.setVisible(false)
        transitionGeneration += 1
        let generation = transitionGeneration
        isShowing = false
        needsResizeAfterShowing = false
        let targetFrame = PanelGeometry.hiddenFrame(from: panel.frame, corner: currentCorner)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.transitionGeneration else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    func stop() {
        transitionGeneration += 1
        isShowing = false
        needsResizeAfterShowing = false
        backdropView.stop()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func configurePanel() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.autoresizesSubviews = true

        backdropView.frame = containerView.bounds
        backdropView.autoresizingMask = [.width, .height]
        containerView.addSubview(backdropView)

        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = AtticStyle.panelUsesSystemShadow
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.opticalInteractionHandler = { [weak backdropView = backdropView] in
            backdropView?.respondToInteraction()
        }
    }

    private func bindContentSize() {
        Publishers.CombineLatest4(
            store.$revision,
            uiState.$isComposerPresented,
            uiState.$selectedSection,
            noteStore.$revision
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.resizeAndReanchor()
            }
            .store(in: &cancellables)

        noteDraft.$conflict
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resizeAndReanchor()
            }
            .store(in: &cancellables)

        settings.$corner
            .receive(on: RunLoop.main)
            .sink { [weak self] corner in
                guard let self else { return }
                self.currentCorner = corner
                self.resizeAndReanchor()
            }
            .store(in: &cancellables)

        settings.$panelCornerSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateOpticalBackdrop()
                self.resizeAndReanchor()
            }
            .store(in: &cancellables)

        settings.$panelContentSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resizeAndReanchor()
            }
            .store(in: &cancellables)

        settings.$glassPerformancePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOpticalBackdrop()
            }
            .store(in: &cancellables)

        let opticalPublishers: [AnyPublisher<Double, Never>] = [
            settings.$glassTransparency.eraseToAnyPublisher(),
            settings.$glassFrost.eraseToAnyPublisher(),
            settings.$glassRefraction.eraseToAnyPublisher(),
            settings.$glassEdgeShine.eraseToAnyPublisher(),
            settings.$glassTint.eraseToAnyPublisher(),
            settings.$glassReadability.eraseToAnyPublisher(),
            settings.$glassInteractionResponse.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(opticalPublishers)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOpticalBackdrop()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOpticalBackdrop()
            }
            .store(in: &cancellables)
    }

    private func updateOpticalBackdrop(
        screen: NSScreen? = nil,
        frame suppliedFrame: CGRect? = nil
    ) {
        let resolvedScreen = screen ?? currentScreen
        let resolvedFrame: CGRect
        if let suppliedFrame {
            resolvedFrame = suppliedFrame
        } else if let resolvedScreen {
            resolvedFrame = frame(on: resolvedScreen, corner: currentCorner)
        } else {
            resolvedFrame = panel.frame
        }
        backdropView.update(
            controls: settings.opticalGlassControls,
            preset: settings.glassPerformancePreset,
            cornerRadius: settings.panelCornerSize,
            screen: resolvedScreen,
            panelFrame: resolvedFrame
        )
    }

    private func resizeAndReanchor() {
        guard let screen = currentScreen else { return }
        if isShowing {
            needsResizeAfterShowing = true
            return
        }
        let targetFrame = frame(on: screen, corner: currentCorner)
        updateOpticalBackdrop(screen: screen, frame: targetFrame)
        guard !framesMatch(panel.frame, targetFrame) else { return }
        if panel.isVisible {
            panel.setFrame(
                targetFrame,
                display: true,
                animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        } else {
            panel.setFrame(targetFrame, display: false)
        }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func frame(on screen: NSScreen, corner: ScreenCorner) -> CGRect {
        let height: CGFloat
        if uiState.selectedSection.isNotes {
            height = PanelGeometry.preferredHeight(
                noteCount: noteStore.notes.count,
                isComposing: uiState.isComposerPresented,
                hasConflict: noteDraft.hasConflict
            )
        } else {
            let snapshot = store.snapshot(for: uiState.selectedSection.taskScope ?? .tasks)
            height = PanelGeometry.preferredHeight(
                taskCount: snapshot.visibleCount,
                sectionCount: snapshot.sections.count,
                isComposing: uiState.isComposerPresented
            )
        }
        return PanelGeometry.panelFrame(
            in: screen.visibleFrame,
            size: CGSize(width: settings.panelContentSize, height: height),
            corner: corner
        )
    }
}
