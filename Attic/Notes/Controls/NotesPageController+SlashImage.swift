import Foundation
import UniformTypeIdentifiers

extension NotesPageController {
    /// The `/` Image or File row uses the same stored-object path as Insert.
    func importSlashImage(_ url: URL) {
        guard let session = active else { return }
        let engine = session.engine
        guard !session.isReadOnly else { engine.cancelSlashFile(); return }
        if let failure = sourceAdmissionFailure(url, in: session).1 {
            session.notice = failure
            engine.cancelSlashFile()
            return
        }
        let loader = imageLoader
        Task { @MainActor [session] in
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let item: NoteImportedObject
            if type.conforms(to: .image), let (image, pixelSize) = await loader(url) {
                item = NoteImportedObject(staged: image.copying(id: UUID()), pixelSize: pixelSize)
            } else {
                item = await NotesPageController.loadFile(url, type: type.identifier)
            }
            guard engine.activity == .idle, engine.commitSlashObject(item) else {
                engine.cancelSlashFile()
                session.notice = String(localized: "The file could not be added to this note.")
                return
            }
        }
    }
}
