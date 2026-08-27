import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AtticPanelController {
    private let panel: AtticPanel
    private let hostingView: NSHostingView<AtticPanelView>
    private let store: TaskStore
    private let noteStore: NoteStore
    private let canvasSession: CanvasSession
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
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        settings: AppSettings,
        uiState: PanelUIState
    ) {
        self.store = store
        self.noteStore = noteStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.settings = settings
        self.uiState = uiState

        panel = AtticPanel(
            contentRect: CGRect(x: 0, y: 0, width: settings.panelContentSize, height: PanelGeometry.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        hostingView = NSHostingView(rootView: AtticPanelView(
            store: store,
            noteStore: noteStore,
            canvasSession: canvasSession,
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
                if self.needsResizeAfterShowing {
                    self.needsResizeAfterShowing = false
                    self.resizeAndReanchor()
                }
            }
        }
    }

    func hide() {
        canvasSession.cancelActiveInteraction()
        uiState.isCanvasConfirmationPresented = false
        guard panel.isVisible else { return }
        guard noteDraft.flush() else { return }
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

    private func configurePanel() {
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = AtticStyle.panelUsesSystemShadow
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
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
                guard let self else { return }
                self.resizeAndReanchor()
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
                self?.resizeAndReanchor()
            }
            .store(in: &cancellables)

        settings.$panelContentSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.resizeAndReanchor()
            }
            .store(in: &cancellables)
    }

    private func resizeAndReanchor() {
        guard let screen = currentScreen else { return }
        if isShowing {
            needsResizeAfterShowing = true
            return
        }
        let targetFrame = frame(on: screen, corner: currentCorner)
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
        if uiState.selectedSection.isCanvas {
            height = PanelGeometry.preferredCanvasHeight()
        } else if uiState.selectedSection.isNotes {
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
