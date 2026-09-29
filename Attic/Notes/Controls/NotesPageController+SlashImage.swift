import Foundation

extension NotesPageController {
    /// The `/` Image or File row's one image: read, then put in place of the
    /// typed command in one undoable step (the engine's slash hand-off,
    /// `commitSlashImage`). A file that can't be read, or a stale request,
    /// leaves the typed command as text. The autosave that follows every
    /// editor change stores the staged image with the note.
    func importSlashImage(_ url: URL) {
        guard let session = active else { return }
        let engine = session.engine
        guard !session.isReadOnly else { engine.cancelSlashFile(); return }
        let loader = imageLoader
        Task { @MainActor [session] in
            guard let (item, pixelSize) = await loader(url) else {
                engine.cancelSlashFile()
                session.notice = String(localized: "The image could not be read, so it was not added.")
                return
            }
            let staged = StagedNoteAttachment(id: UUID(), filename: item.filename,
                                              contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                                              digest: item.digest, data: item.data)
            guard engine.activity == .idle, engine.commitSlashImage(staged, pixelSize: pixelSize) else {
                engine.cancelSlashFile()
                session.notice = String(localized: "The image could not be added to this note.")
                return
            }
        }
    }
}
