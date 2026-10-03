import SwiftUI

/// The one place the shell hosts the Notes page (rebuilt in phase 2).
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// False until the shell has restored the last note session.
    let hasRestoredSession: Bool

    private var horizontalInset: CGFloat { layout.contentInsets.leading }

    var body: some View {
        Group {
            if !hasRestoredSession {
                ProgressView("Restoring draft…")
            } else if uiState.isComposerPresented {
                NoteComposerView(noteDraft: noteDraft, uiState: uiState,
                                 topContentInset: layout.contentInsets.top + 64,
                                 bottomContentInset: layout.contentInsets.bottom)
                    .padding(.horizontal, horizontalInset)
            } else {
                NotesPanelContent(
                    noteStore: noteStore,
                    noteDraft: noteDraft,
                    uiState: uiState,
                    topContentInset: layout.contentInsets.top + 64,
                    bottomContentInset: layout.contentInsets.bottom
                )
            }
        }
    }
}
