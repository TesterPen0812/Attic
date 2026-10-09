import SwiftUI

#if DEBUG
/// Native boundaries let off-screen tests inspect SwiftUI's mounted tree,
/// where AppKit does not expose the accessibility tree of a hidden window.
struct NotesRenderBoundary: NSViewRepresentable {
    static let isTesting = NSClassFromString("XCTestCase") != nil
    final class BoundaryView: NSView {
        var boundaryID = ""
    }
    let identifier: String
    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.boundaryID = identifier
        return view
    }
    func updateNSView(_ view: BoundaryView, context: Context) { view.boundaryID = identifier }
}

extension View {
    @ViewBuilder func notesRenderBoundary(_ identifier: String) -> some View {
        if NotesRenderBoundary.isTesting {
            background(NotesRenderBoundary(identifier: identifier).allowsHitTesting(false))
        } else {
            self
        }
    }
}
#else
extension View {
    func notesRenderBoundary(_ identifier: String) -> some View { self }
}
#endif

/// The one place the shell hosts the Notes page (rebuilt in phase 2).
struct NotesPageHost: View {
    @AppStorage(NotesEditorSetting.defaultsKey) private var newEditorEnabled = NotesEditorSetting.isPreviewIdentity(Bundle.main.bundleIdentifier)
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// False until the shell has restored the last note session.
    let hasRestoredSession: Bool

    private var horizontalInset: CGFloat { layout.contentInsets.leading }

    /// The Phase 2 editor hosts the page when the internal switch is on, or
    /// when the old page opened a note already in the new format (only the
    /// new editor may write it).
    private var usesNewEditor: Bool {
        if newEditorEnabled { return true }
        guard uiState.isComposerPresented, let id = noteDraft.activeNoteID else { return false }
        return noteStore.note(withID: id)?.usesDocumentFormat ?? false
    }

    var legacyExitAction: (() -> Void)? {
        guard !newEditorEnabled else { return nil }
        return { exitToOldPage() }
    }

    var body: some View {
        Group {
            if !hasRestoredSession {
                ProgressView("Restoring draft…")
            } else if usesNewEditor {
                NotesEditorPage(controller: noteDraft.pages, noteStore: noteStore, noteDraft: noteDraft,
                                uiState: uiState, layout: layout,
                                exitToOldPage: legacyExitAction)
                    .onAppear { openDocumentNoteFromOldPage() }
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

    /// The old page opened a new-format note: show it in the new editor
    /// (the old draft stays clean; the store refuses its writes to it).
    private func openDocumentNoteFromOldPage() {
        guard !NotesEditorSetting.isEnabled(), let id = noteDraft.activeNoteID else { return }
        _ = noteDraft.pages.open(noteID: id)
    }

    private func exitToOldPage() {
        // A closure captured before the flag changed cannot reopen the old UI.
        guard !NotesEditorSetting.isEnabled() else { return }
        guard noteDraft.prepareToLeave(.exitToOldPage) else { return }
        noteDraft.discardDraft()
        uiState.endAdding()
    }
}
