import SwiftUI

/// A problem the shell shows over the page: the message, and Retry when the
/// failed step can run again.
struct PanelNoticeContent: Equatable {
    let message: String
    let canRetry: Bool
    var isInformational = false
}

/// The Undo toast and the error notice, stacked above the page's bottom
/// controls. The toast pops up rising 12 pt and sinks 8 pt as it leaves
/// on the eased-in exit; a swipe down dismisses it (Accepted 2026-11-10).
/// Under Reduce Motion both only fade. The notice sits nearest the page:
/// a problem is never hidden by a toast.
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
                .modifier(PanelToastSwipe(onDismiss: { toasts.dismiss() }))
                .accessibilityIdentifier("panel-undo-toast")
                .transition(AtticMotionScale.toastTransition(reduceMotion: design.reduceMotion))
                .id(toast.id)
            }
            if let notice {
                AtticNotice(
                    message: notice.message,
                    isInformational: notice.isInformational,
                    actionTitle: notice.canRetry ? String(localized: "Retry") : nil,
                    onAction: notice.canRetry ? onRetry : nil,
                    onDismiss: onDismissNotice
                )
                .accessibilityIdentifier("panel-error-message")
                .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
            }
        }
        // The toast pops in (its own spring); the notice keeps the
        // overlays' one recipe (A4 M-03): M/S in with a 4 pt rise, F/E out.
        .animation(AtticMotionPreset.toast.animation(reduceMotion: design.reduceMotion), value: toasts.current)
        .animation(AtticMotionScale.overlayAnimation(reduceMotion: design.reduceMotion), value: notice)
    }
}

/// A swipe down dismisses the toast (its own state, so each toast starts
/// at rest): it follows the pointer down (and barely up), and past
/// `toastSwipe` it goes; short of that it springs back. The Undo button's
/// click is not a swipe (it never moves 6 pt).
struct PanelToastSwipe: ViewModifier {
    let onDismiss: () -> Void

    @Environment(\.atticDesign) private var design
    /// How far the toast is being swiped down (0 at rest).
    @State private var swipe: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: swipe)
            .gesture(swipeDown)
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let dy = value.translation.height
                swipe = dy > 0 ? dy : dy / 6
            }
            .onEnded { value in
                if Self.swipeDismisses(translation: value.translation.height,
                                       predicted: value.predictedEndTranslation.height) {
                    onDismiss()
                } else {
                    withAnimation(AtticMotionPreset.toast.animation(reduceMotion: design.reduceMotion)) { swipe = 0 }
                }
            }
    }

    /// Whether a swipe that moved `translation` (and would have gone on to
    /// `predicted`) dismisses the toast.
    static func swipeDismisses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation >= AtticMotionScale.toastSwipe || predicted >= AtticMotionScale.toastSwipe * 2
    }
}
