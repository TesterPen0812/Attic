import AppKit
import SwiftUI

/// The panel's one toast at a time: "Task deleted · Undo" after a delete or
/// a move (spec § Recently Deleted: the Undo toast stays 6 s). Pages and the
/// agent server post here; the shell shows it above the page's bottom
/// controls. Nothing runs while the panel is hidden: hiding the panel
/// dismisses the toast and cancels its timer (⌘Z still undoes the step).
@MainActor
final class PanelToastCenter: ObservableObject {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?
    private var action: (() -> Void)?
    private var dismissWork: DispatchWorkItem?
    /// How long a toast stays (spec: 6 s). Tests shorten it.
    var holdDuration: TimeInterval = AtticMotionPreset.toastHold

    /// Shows `message` with its action, replacing any toast on screen.
    @discardableResult
    func show(_ message: String, actionTitle: String = String(localized: "Undo"), action: @escaping () -> Void) -> Toast {
        let toast = Toast(message: message, actionTitle: actionTitle)
        self.action = action
        current = toast
        scheduleDismissal(of: toast)
        AccessibilityNotification.Announcement("\(message). \(actionTitle) with Command-Z.").post()
        return toast
    }

    /// The toast's button (or ⌘Z while it shows): runs the action once and
    /// dismisses the toast.
    func performAction() {
        let action = action
        dismiss()
        action?()
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        action = nil
        current = nil
    }

    /// The pointer rests on the toast: it stays until the pointer leaves.
    func holdOpen(_ isHovering: Bool) {
        guard let current else { return }
        if isHovering {
            dismissWork?.cancel()
            dismissWork = nil
        } else {
            scheduleDismissal(of: current)
        }
    }

    private func scheduleDismissal(of toast: Toast) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current == toast else { return }
                self.dismiss()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    var hasPendingDismissalForTesting: Bool { dismissWork != nil }
}

private struct PanelToastCenterKey: EnvironmentKey {
    static let defaultValue: PanelToastCenter? = nil
}

extension EnvironmentValues {
    /// Where a page posts its Undo toast. nil outside the panel.
    var atticPanelToasts: PanelToastCenter? {
        get { self[PanelToastCenterKey.self] }
        set { self[PanelToastCenterKey.self] = newValue }
    }
}
