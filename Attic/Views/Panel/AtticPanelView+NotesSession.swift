import SwiftUI

/// The Notes page's session rules, run by the shell because they apply on
/// the way into the page (the 30-minute reopen, a restored draft) and on
/// store changes while it shows. Rebuilt with Notes in phase 2.
extension AtticPanelView {
    func syncNoteDraftInteractionLocks() {
        uiState.setInteractionLock(.notesDirty, isActive: noteDraft.isDirty)
        uiState.setInteractionLock(.notesConflict, isActive: noteDraft.hasConflict)
        uiState.setInteractionLock(.notesImport, isActive: noteDraft.pages.active?.isImporting == true)
    }
}
