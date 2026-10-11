import SwiftUI

/// A problem the shell shows over the page: the message, and Retry when the
/// failed step can run again.
struct PanelNoticeContent: Equatable {
    let message: String
    let canRetry: Bool
}

/// The Undo toast and the error notice, stacked above the page's bottom
/// controls. The toast springs up and tucks away (the feel's appear and
/// leave styles; Calm slides up and fades out); under Reduce Motion both
/// only fade. The notice sits nearest the page: a problem is never
/// hidden by a toast.
struct PanelNoticeStack: View {
    @ObservedObject var toasts: PanelToastCenter
    let notice: PanelNoticeContent?
    let onRetry: () -> Void
    let onDismissNotice: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        VStack(spacing: AtticSpacing.s8) {
            if let toast = toasts.current {
                AtticUndoToast(message: toast.message, actionTitle: toast.actionTitle, isFailure: toast.isFailure,
                               onHold: { reason, held in toasts.hold(reason, held) }) {
                    toasts.performAction()
                }
                .onHover { toasts.holdOpen($0) }
                .accessibilityIdentifier("panel-undo-toast")
                .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
                .id(toast.id)
            }
            if let notice {
                AtticNotice(
                    message: notice.message,
                    actionTitle: notice.canRetry ? String(localized: "Retry") : nil,
                    onAction: notice.canRetry ? onRetry : nil,
                    onDismiss: onDismissNotice
                )
                .accessibilityIdentifier("panel-error-message")
                .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
            }
        }
        // The overlays' one recipe (A4 M-03), as Notes' status pill and the
        // selection bar: M/S in with a 4 pt rise, F/E out.
        .animation(AtticMotionScale.overlayAnimation(reduceMotion: design.reduceMotion), value: toasts.current)
        .animation(AtticMotionScale.overlayAnimation(reduceMotion: design.reduceMotion), value: notice)
    }
}
