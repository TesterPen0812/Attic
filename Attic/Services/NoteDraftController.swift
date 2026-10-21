import Combine
import Foundation

/// App lifecycle facade for the document editor. Draft ownership is in pages.
@MainActor final class NoteDraftController: ObservableObject {
    let noteStore: NoteStore
    let pages: NotesPageController
    private var pageChanges: AnyCancellable?
    private var activeChanges: AnyCancellable?
    private var activeSelection: AnyCancellable?
    var isImporting: Bool { pages.active?.isImporting == true }
    var isDirty: Bool { pages.active.map { NoteSessionPolicy.hasPendingWork($0.state) } ?? false }
    var hasConflict: Bool { pages.active?.isConflict == true }
    init(noteStore: NoteStore, sessionDefaults: UserDefaults? = nil, recoveryURL: URL? = nil) {
        self.noteStore = noteStore
        pages = NotesPageController(store: noteStore, journal: recoveryURL.map {
            NoteDraftJournal(directory: $0.deletingLastPathComponent().appendingPathComponent("NoteDrafts", isDirectory: true))
        }, defaults: sessionDefaults)
        pageChanges = pages.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        activeSelection = pages.$active.sink { [weak self] session in
            self?.activeChanges = session?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    @discardableResult func flush() -> Bool { pages.preserveAll() }
    func prepareToLeave(_ reason: NotesPageController.LeaveReason) -> Bool { pages.prepareToLeave(reason) }
    func prepareToLeaveDurably(_ reason: NotesPageController.LeaveReason) async -> Bool { await pages.prepareToLeaveDurably(reason) }
}
