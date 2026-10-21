import SwiftUI

/// The document editor is the only Notes page.
struct NotesPageHost: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    let hasRestoredSession: Bool
    var body: some View {
        if hasRestoredSession {
            NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                            uiState: uiState, layout: layout)
        } else { ProgressView("Restoring draft…") }
    }
}
