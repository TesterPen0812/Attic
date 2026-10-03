import SwiftUI

/// The Notes page's session rules, run by the shell because they apply on
/// the way into the page (the 30-minute reopen, a restored draft) and on
/// store changes while it shows. Rebuilt with Notes in phase 2.
extension AtticPanelView {
    func openMostRecentNoteIfNeeded() {
        guard hasRestoredNoteSession,
              uiState.selectedSection.isNotes,
              !uiState.isComposerPresented,
              uiState.editingNoteID == nil else { return }

        if noteDraft.isActive {
            if let restored = noteStore.orderedNotes().first(where: { $0.id == noteDraft.activeNoteID }) {
                uiState.beginEditingNote(restored)
            } else {
                uiState.beginAdding()
            }
            return
        }

        let note: NoteItem
        if noteDraft.resumeLastSession(),
           let restored = noteStore.orderedNotes().first(where: { $0.id == noteDraft.activeNoteID }) {
            note = restored
        } else if let recent = noteStore.orderedNotes().first,
                  noteDraft.beginEditing(recent) {
            note = recent
        } else {
            return
        }

        withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            uiState.beginEditingNote(note)
        }
    }

    func reconcileNoteDraft() {
        guard uiState.selectedSection.isNotes,
              uiState.isComposerPresented,
              noteDraft.isActive else { return }

        guard noteDraft.reconcileWithStore() else {
            uiState.endAdding()
            openMostRecentNoteIfNeeded()
            return
        }

        if uiState.editingNoteID != noteDraft.activeNoteID {
            uiState.editingNoteID = noteDraft.activeNoteID
        }
    }

    func syncNoteDraftInteractionLocks() {
        uiState.setInteractionLock(.notesDirty, isActive: noteDraft.isDirty)
        uiState.setInteractionLock(.notesConflict, isActive: noteDraft.hasConflict)
        let isImporting: Bool
        if case .importing = noteStore.attachmentImportState {
            isImporting = true
        } else {
            isImporting = false
        }
        uiState.setInteractionLock(.notesImport, isActive: isImporting)
    }
}
