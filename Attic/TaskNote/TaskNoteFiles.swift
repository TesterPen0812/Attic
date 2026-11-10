import Foundation
import UniformTypeIdentifiers

/// Files dropped on a Tasks row go into the task's note (`p3-22` row 4),
/// at its end. A task with no note gets one: the drop is the first content
/// (UX plan § 2.1), committed through the same gated save and association
/// as writing. The row stays where it is; a toast offers Open.
@MainActor
enum TaskNoteFiles {
    /// How long the headless import may take before the drop reports it
    /// could not finish (the batch itself keeps going and stays recoverable).
    static var importTimeout: Duration = .seconds(60)

    /// Insert › Image or File and /file share the task editor's live session.
    /// Slash replaces only its captured command, and a late picker/loader
    /// cannot write into another task or an already closed workspace.
    static func importSlashFile(_ url: URL, for request: NoteSlashFileRequest,
                                presenter: TaskNotePresenter, controller: NotesPageController) async -> Bool {
        guard let session = presenter.session, let engine = request.engine,
              presenter.lease != nil, session.engine === engine,
              engine.isPending(request), !session.isReadOnly else { request.cancel(); return false }
        if let failure = controller.sourceAdmissionFailure(url, in: session).1 {
            session.showNotice(NoteNotice(kind: .notAdded, detail: failure))
            request.cancel()
            return false
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let item: NoteImportedObject
        if type.conforms(to: .image), let (image, pixelSize) = await controller.imageLoader(url) {
            item = NoteImportedObject(staged: image.copying(id: UUID()), pixelSize: pixelSize)
        } else {
            item = await NotesPageController.loadFile(url, type: type.identifier)
        }
        guard presenter.lease != nil, presenter.session === session, session.engine === engine,
              engine.activity == .idle, engine.isPending(request) else { request.cancel(); return false }
        let added = engine.commitSlashObject(item, for: request)
        if !added {
            request.cancel()
            session.showNotice(NoteNotice(kind: .notAdded,
                detail: String(localized: "The file could not be added to this note.")))
        }
        return added
    }

    static func add(_ staging: TaskAttachmentStaging, to taskID: UUID, tasks: TaskStore,
                    controller: NotesPageController, toasts: PanelToastCenter?, open: @escaping () -> Void) {
        Task { @MainActor in
            let added = await importFiles(staging.urls, to: taskID, tasks: tasks, controller: controller)
            staging.discard()
            if !added { AtticSounds.play(.failed) }
            guard let toasts else { return }
            if added {
                toasts.show(String(localized: "Added to task's note"), actionTitle: String(localized: "Open"),
                            answersUndoKey: false, action: open)
            } else {
                toasts.show(String(localized: "Couldn't add the files to the task's note"), actionTitle: String(localized: "Open"),
                            answersUndoKey: false, action: open)
            }
        }
    }

    /// The import itself. The open page (panel or window) takes the batch;
    /// otherwise an engine-only session of the task's workspace does, under
    /// its own lease, and lets go durably when the batch is in.
    static func importFiles(_ urls: [URL], to taskID: UUID, tasks: TaskStore, controller: NotesPageController) async -> Bool {
        guard !urls.isEmpty else { return false }
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return false }
        await coordinator.sessions.retryHeadlessClosures()
        if let presenter = TaskNotePresenter.open(for: taskID) {
            guard let session = presenter.session, !session.isReadOnly else { return false }
            return await run(urls, into: session, controller: controller)
        }
        guard let page = try? coordinator.sessions.session(for: .task(taskID), notes: controller),
              let lease = try? page.acquire(surfaceID: UUID()) else { return false }
        guard let session = page.note, !session.isReadOnly else {
            _ = await coordinator.sessions.closeHeadless(page, lease: lease)
            return false
        }
        let added = await run(urls, into: session, controller: controller)
        // Closing preserves durably: the batch's save creates the note.
        let closed = await coordinator.sessions.closeHeadless(page, lease: lease)
        return added && closed
    }

    private static func run(_ urls: [URL], into session: NoteSession, controller: NotesPageController) async -> Bool {
        let end = NSRange(location: session.engine.textStorage.length, length: 0)
        let objectsBefore = session.engine.objectIDs().count
        controller.importFiles(urls, at: end, into: session)
        guard session.isImporting else { return false }
        let deadline = ContinuousClock.now + importTimeout
        while session.isImporting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !session.isImporting && session.engine.objectIDs().count > objectsBefore
    }
}
