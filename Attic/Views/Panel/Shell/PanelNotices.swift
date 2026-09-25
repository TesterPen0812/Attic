import SwiftUI

/// A problem the shell shows over the page: the message, and Retry when the
/// failed step can run again.
struct PanelNoticeContent: Equatable {
    let message: String
    let canRetry: Bool
}

/// The Undo toast and the error notice, stacked above the page's bottom
/// controls. The toast slides up (200 ms) and fades out; under Reduce Motion
/// both only fade. The notice sits nearest the page: a problem is never
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
                AtticUndoToast(message: toast.message, actionTitle: toast.actionTitle) {
                    toasts.performAction()
                }
                .onHover { toasts.holdOpen($0) }
                .accessibilityIdentifier("panel-undo-toast")
                .transition(AtticMotionPreset.toast.transition(reduceMotion: design.reduceMotion))
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
                .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
        }
        .animation(AtticMotionPreset.toast.animation(reduceMotion: design.reduceMotion), value: toasts.current)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: notice)
    }
}
