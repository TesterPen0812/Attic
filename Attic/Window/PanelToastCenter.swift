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
        var id = UUID()
        let message: String
        let actionTitle: String
        /// A failed action's message (Astra 23): the toast stays, in the
        /// warning colour, and its button retries (or only dismisses when
        /// retrying cannot help).
        var isFailure = false
        /// Whether ⌘Z means this toast's action (Tasks: the page's history
        /// undoes the same step). Notes passes false (B2): ⌘Z there follows
        /// the text under the caret, then the library's history, so the
        /// toast never owns it and never says it does.
        var answersUndoKey = true

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    typealias Hold = AtticToastHold

    @Published private(set) var current: Toast?
    /// An action that finishes later is running (the toast stays, its
    /// button waits: a second press does nothing).
    @Published private(set) var isPerforming = false
    private var action: (@MainActor () -> CommandOutcome)?
    private var asyncAction: (@MainActor () async -> CommandOutcome)?
    private var dismissWork: DispatchWorkItem?
    private var holds: Set<Hold> = []
    /// How long a toast stays (spec: 6 s). Tests shorten it.
    var holdDuration: TimeInterval = AtticMotionPreset.toastHold

    /// Shows `message` with an action that reports what it did, replacing
    /// any toast on screen.
    @discardableResult
    func show(_ message: String, actionTitle: String = String(localized: "Undo"), answersUndoKey: Bool = true,
              performing action: @escaping @MainActor () -> CommandOutcome) -> Toast {
        let toast = Toast(message: message, actionTitle: actionTitle, answersUndoKey: answersUndoKey)
        present(toast, action: action)
        let announcement = answersUndoKey
            ? "\(message). \(actionTitle) with Command-Z."
            : "\(message). \(actionTitle) is available."
        AccessibilityNotification.Announcement(announcement).post()
        return toast
    }

    /// An action that cannot fail (a page's own bookkeeping).
    @discardableResult
    func show(_ message: String, actionTitle: String = String(localized: "Undo"), answersUndoKey: Bool = true,
              action: @escaping () -> Void) -> Toast {
        show(message, actionTitle: actionTitle, answersUndoKey: answersUndoKey, performing: { action(); return .applied })
    }

    /// An action that finishes later (Notes' durable Undo, which may wait
    /// for a recovery write): the toast stays until its outcome is known,
    /// then goes, or says what went wrong and offers Retry, as
    /// `performAction()` does for an immediate action.
    @discardableResult
    func show(_ message: String, actionTitle: String = String(localized: "Undo"), answersUndoKey: Bool = true,
              performingAsync action: @escaping @MainActor () async -> CommandOutcome) -> Toast {
        let toast = Toast(message: message, actionTitle: actionTitle, answersUndoKey: answersUndoKey)
        present(toast, action: nil, asyncAction: action)
        let announcement = answersUndoKey
            ? "\(message). \(actionTitle) with Command-Z."
            : "\(message). \(actionTitle) is available."
        AccessibilityNotification.Announcement(announcement).post()
        return toast
    }

    /// The button of a toast whose action finishes later: runs it once and
    /// waits for its outcome. Returns nil when nothing ran (no such action,
    /// or it is already running).
    @discardableResult
    func performActionAsync() async -> CommandOutcome? {
        guard let asyncAction, !isPerforming, let pressed = current else { return nil }
        isPerforming = true
        // Nothing expires while the action runs.
        dismissWork?.cancel()
        dismissWork = nil
        let outcome = await asyncAction()
        isPerforming = false
        // Another toast replaced this one meanwhile: that one stays. A
        // failure of a toast the page took down is still said.
        guard current == nil || current?.id == pressed.id else { return outcome }
        switch outcome {
        case .applied:
            if current?.id == pressed.id { dismiss() }
        case let .failed(failure):
            let toast = Toast(id: pressed.id, message: failure.message,
                              actionTitle: failure.canRetry ? String(localized: "Retry") : String(localized: "OK"),
                              isFailure: true, answersUndoKey: pressed.answersUndoKey)
            present(toast, action: nil, asyncAction: failure.canRetry ? asyncAction : nil)
            AccessibilityNotification.Announcement(failure.message).post()
        }
        return outcome
    }

    /// The toast's button: runs the action once. On success (or when there
    /// is nothing left to do) the toast goes; on failure it stays with the
    /// reason, and its button retries the same action while retrying can
    /// help. The toast is not dismissed before the action has run.
    @discardableResult
    func performAction() -> CommandOutcome {
        if asyncAction != nil {
            Task { await performActionAsync() }
            return .applied
        }
        guard let action else {
            dismiss()
            return .applied
        }
        let outcome = action()
        switch outcome {
        case .applied:
            dismiss()
        case let .failed(failure):
            // The same toast, now saying what went wrong. A problem is never
            // hidden: it stays until it is retried, dismissed or replaced.
            let toast = Toast(
                id: current?.id ?? UUID(),
                message: failure.message,
                actionTitle: failure.canRetry ? String(localized: "Retry") : String(localized: "OK"),
                isFailure: true,
                answersUndoKey: current?.answersUndoKey ?? true
            )
            present(toast, action: failure.canRetry ? action : nil)
            AccessibilityNotification.Announcement(failure.message).post()
        }
        return outcome
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        action = nil
        asyncAction = nil
        holds = []
        current = nil
    }

    /// The pointer rests on the toast: it stays until the pointer leaves.
    func holdOpen(_ isHovering: Bool) {
        hold(.pointer, isHovering)
    }

    /// Something holds the toast (or lets it go). It expires 6 s after the
    /// last hold ends.
    func hold(_ reason: Hold, _ isHeld: Bool) {
        guard let current else { return }
        if isHeld {
            holds.insert(reason)
            dismissWork?.cancel()
            dismissWork = nil
        } else {
            holds.remove(reason)
            if holds.isEmpty, !current.isFailure { scheduleDismissal(of: current) }
        }
    }

    private func present(_ toast: Toast, action: (@MainActor () -> CommandOutcome)?,
                         asyncAction: (@MainActor () async -> CommandOutcome)? = nil) {
        self.action = action
        self.asyncAction = asyncAction
        current = toast
        dismissWork?.cancel()
        dismissWork = nil
        if holds.isEmpty, !toast.isFailure { scheduleDismissal(of: toast) }
    }

    private func scheduleDismissal(of toast: Toast) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current == toast, self.holds.isEmpty, !self.isPerforming else { return }
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
