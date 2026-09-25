import AppKit
import SwiftUI

/// Calls `action` each time the window showing this view comes on screen
/// again (the panel's reveal): "Tasks always opens on Now", and `hidden`
/// when it leaves the screen. Event-driven (the window's occlusion
/// notification); nothing is polled while hidden.
struct TasksWindowReveal: NSViewRepresentable {
    let action: () -> Void
    var hidden: () -> Void = {}

    func makeNSView(context: Context) -> RevealView {
        let view = RevealView()
        view.action = action
        view.onHidden = hidden
        return view
    }

    func updateNSView(_ view: RevealView, context: Context) {
        view.action = action
        view.onHidden = hidden
    }

    final class RevealView: NSView {
        var action: () -> Void = {}
        var onHidden: () -> Void = {}
        private var observation: NSObjectProtocol?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            guard let window else { return }
            wasVisible = window.occlusionState.contains(.visible)
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    let visible = window.occlusionState.contains(.visible)
                    if visible, !self.wasVisible { self.action() }
                    if !visible, self.wasVisible { self.onHidden() }
                    self.wasVisible = visible
                }
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }
}
