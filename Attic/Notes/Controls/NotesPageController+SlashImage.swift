import Foundation
import UniformTypeIdentifiers

/// A `/` Image or File… request as the page's open panel carries it: the
/// session it was made in and the engine's request (its generation and the
/// captured command).
struct NoteSlashFileTicket: Equatable {
    let sessionID: NoteSession.ID
    let request: NoteSlashFileRequest
}

extension NotesPageController {
    /// The `/` Image or File row uses the same stored-object path as Insert.
    /// The file answers `ticket` only: a completion that arrives after its
    /// request was cancelled or superseded (another `/` Image or File…, a
    /// note switch) commits nothing and cancels nothing else (review P2).
    func importSlashImage(_ url: URL, for ticket: NoteSlashFileTicket) {
        let request = ticket.request
        guard let session = active, session.id == ticket.sessionID,
              let engine = request.engine, engine === session.engine, engine.isPending(request) else { return }
        guard !session.isReadOnly else { request.cancel(); return }
        if let failure = sourceAdmissionFailure(url, in: session).1 {
            session.notice = failure
            request.cancel()
            return
        }
        let loader = imageLoader
        Task { @MainActor [weak self, session] in
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let item: NoteImportedObject
            if type.conforms(to: .image), let (image, pixelSize) = await loader(url) {
                item = NoteImportedObject(staged: image.copying(id: UUID()), pixelSize: pixelSize)
            } else {
                item = await NotesPageController.loadFile(url, type: type.identifier)
            }
            guard self?.active === session, session.engine === engine,
                  engine.activity == .idle, engine.commitSlashObject(item, for: request) else {
                request.cancel()
                session.notice = String(localized: "The file could not be added to this note.")
                return
            }
        }
    }
}
