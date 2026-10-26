import Foundation

/// Files dropped on a Tasks row go into the task's note (`p3-22` row 4),
/// at its end. A task with no note gets one: the drop is the first content
/// (UX plan § 2.1), committed through the same gated save and association
/// as writing. The row stays where it is; a toast offers Open.
@MainActor
enum TaskNoteFiles {
    /// How long the headless import may take before the drop reports it
    /// could not finish (the batch itself keeps going and stays recoverable).
    static var importTimeout: Duration = .seconds(60)

    static func add(_ staging: TaskAttachmentStaging, to taskID: UUID, tasks: TaskStore,
                    controller: NotesPageController, toasts: PanelToastCenter?, open: @escaping () -> Void) {
        Task { @MainActor in
            let added = await importFiles(staging.urls, to: taskID, tasks: tasks, controller: controller)
            staging.discard()
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

    /// Removes one image or file from the task's writing (the Reminders
    /// replica's panel): the note's own Delete Attachment edit, on the
    /// open page's session or, as `importFiles` does, a headless one that
    /// lets go durably. Its Undo is the note's.
    static func removeAttachment(_ attachmentID: UUID, from taskID: UUID, tasks: TaskStore,
                                 controller: NotesPageController) async -> Bool {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return false }
        await coordinator.sessions.retryHeadlessClosures()
        if let presenter = TaskNotePresenter.open(for: taskID) {
            guard let session = presenter.session, !session.isReadOnly else { return false }
            return await deleteObject(holding: attachmentID, in: session)
        }
        guard let page = try? coordinator.sessions.session(for: .task(taskID), notes: controller),
              let lease = try? page.acquire(surfaceID: UUID()) else { return false }
        guard let session = page.note, !session.isReadOnly else {
            _ = await coordinator.sessions.closeHeadless(page, lease: lease)
            return false
        }
        let removed = await deleteObject(holding: attachmentID, in: session)
        let closed = await coordinator.sessions.closeHeadless(page, lease: lease)
        return removed && closed
    }

    private static func deleteObject(holding attachmentID: UUID, in session: NoteSession) async -> Bool {
        let engine = session.engine
        let objectID = engine.objectIDs().first { id in
            switch engine.objectPlacement(id)?.0 {
            case let image as NoteImageAttachment: image.attachmentID == attachmentID
            case let file as NoteFileAttachment: file.attachmentID == attachmentID
            default: false
            }
        }
        guard let objectID else { return false }
        return await engine.perform(.delete, objectID: objectID)
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
