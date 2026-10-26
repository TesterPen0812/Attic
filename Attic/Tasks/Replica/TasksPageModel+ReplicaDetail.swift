import AppKit
import Foundation

/// The Reminders replica's detail panel, tag filter, indenting and photos
/// (R2). Every write is an existing producer: Edit Task (one step), Make
/// Standalone Task, Add Files… and the note's Delete Attachment edit.
extension TasksPageModel {
    // MARK: The panel

    /// ⓘ, ⌘I or Show Info: the panel opens on a task of Now or Later.
    func openReplicaDetail(_ id: UUID) {
        guard listStyle.usesReplicaMachinery, tab != .done, let task = store.task(withID: id), task.parentID == nil else { return }
        if let open = replicaDetail {
            if open.taskID == id { return }
            closeReplicaDetail()
        }
        // An open title editor saves first, as before any other command.
        guard finishEditing() else { return }
        replicaSubtaskSelection = nil
        replicaDetail = RemindersReplicaDetailState(taskID: id, draft: RemindersReplicaDetailDraft(task: task))
    }

    /// The panel closed. M (R2-F05): a click outside commits what was
    /// staged, as one Edit Task step (one Undo); after Escape nothing is
    /// saved. A failed save shows under the row with Retry.
    @discardableResult
    func closeReplicaDetail() -> CommandOutcome {
        guard let detail = replicaDetail else { return .applied }
        replicaDetail = nil
        if !detail.cancelled, let problem = detail.draft.urlProblem {
            showToast(String(localized: "Link not saved: \(problem)"))
        }
        guard let patch = detail.patch else { return .applied }
        let id = detail.taskID
        let save: () -> CommandOutcome = { [weak self] in
            guard let self else { return .failed(.taskGone) }
            return library.updateTask(id, title: patch.title, priority: patch.priority, status: patch.status,
                                      tags: patch.tags, isFlagged: patch.isFlagged, url: patch.url, dueDay: patch.dueDay,
                                      allowingUnfinishedSubtasks: true)
        }
        return report(save(), on: id, retry: save)
    }

    /// Escape in the panel (M, R2-F05): the staged edits are dropped. In
    /// New, Escape means "leave and keep what I did" (FINAL § 2.13): the
    /// panel closes and saves, and ⌘Z undoes.
    func cancelReplicaDetail() {
        if !listStyle.isNew { replicaDetail?.cancel() }
        closeReplicaDetail()
    }

    // MARK: Flag

    /// Flag or Unflag from the row's menu: one Edit Task step.
    @discardableResult
    func setReplicaFlag(_ flagged: Bool, for id: UUID) -> CommandOutcome {
        let change: () -> CommandOutcome = { [weak self] in
            self?.library.updateTask(id, isFlagged: flagged) ?? .failed(.taskGone)
        }
        return report(change(), on: id, retry: change)
    }

    // MARK: Tags

    /// A tag chosen in the panel filters the list by it, through Attic's
    /// own Find (`#tag` matches the tag). The panel's edits are saved first.
    func filterReplicaByTag(_ tag: String) {
        guard tab != .done else { return }
        closeReplicaDetail()
        setSearchQuery("#" + tag, for: tab)
    }

    // MARK: Tab and ⇧Tab

    /// What Tab or ⇧Tab did: nil when there was nothing to act on, else
    /// the outcome, or the reason it can't be done (shown as a toast).
    enum ReplicaIndentResult: Equatable {
        case done(CommandOutcome)
        case refused(String)
    }

    /// ⇧Tab on a subtask makes it a task again (Make Standalone Task).
    /// Tab has no producer in Attic: a task can't become another's
    /// subtask, and subtasks are one level deep; it says so in Attic's own
    /// words.
    func replicaIndent(_ command: RemindersReplicaIndent, row: UUID?) -> ReplicaIndentResult? {
        if let subtask = replicaSubtaskSelection, store.task(withID: subtask)?.parentID != nil {
            switch command {
            case .outdent:
                let outcome = makeStandalone(subtask)
                if outcome.isApplied { replicaSubtaskSelection = nil }
                return .done(outcome)
            case .indent:
                return refuse(String(localized: "A subtask can only move to an unfinished main task."))
            }
        }
        guard let row, store.task(withID: row) != nil else { return nil }
        switch command {
        case .indent:
            return refuse(String(localized: "Only a subtask can move to another task or become a task of its own."))
        case .outdent:
            // Already a task (Reminders' Outdent is disabled here, R2-07).
            return .done(.applied)
        }
    }

    private func refuse(_ reason: String) -> ReplicaIndentResult {
        showToast(reason)
        return .refused(reason)
    }

    // MARK: Photos

    /// The item's photos: the images in its writing, then any Earlier
    /// image files still on the task.
    func replicaPhotos(for id: UUID) -> [RemindersReplicaPhoto] {
        var photos = services.notePhotos?(id) ?? []
        if let task = store.task(withID: id) {
            photos += store.fileMigration.rowFiles(for: task).filter(\.isImage).map {
                RemindersReplicaPhoto(id: $0.id, filename: $0.filename, source: .task(owner: id))
            }
        }
        return photos
    }

    /// A photo's file, for its thumbnail and Quick Look.
    func replicaPhotoURL(_ photo: RemindersReplicaPhoto) async -> URL? {
        switch photo.source {
        case let .note(attachmentID):
            return await services.notePhotoURL?(attachmentID)
        case let .task(owner):
            guard let task = store.task(withID: owner),
                  let reference = store.fileMigration.rowFiles(for: task).first(where: { $0.id == photo.id }) else { return nil }
            return try? await store.taskImageFiles.verifiedURL(for: reference)
        }
    }

    /// Quick Look on a photo (the verified private copy).
    func previewReplicaPhoto(_ photo: RemindersReplicaPhoto) {
        Task { @MainActor [weak self] in
            guard let url = await self?.replicaPhotoURL(photo) else { return }
            AttachmentQuickLookPresenter.shared.present(url)
        }
    }

    /// Removes a photo through its producer: the note's Delete Attachment
    /// edit for an image in the writing, Remove File for an Earlier file.
    func removeReplicaPhoto(_ photo: RemindersReplicaPhoto, from taskID: UUID) async -> Bool {
        switch photo.source {
        case let .note(attachmentID):
            return await services.removeNotePhoto?(taskID, attachmentID) ?? false
        case let .task(owner):
            let outcome = library.removeTaskAttachment(photo.id, from: owner)
            _ = report(outcome, on: taskID) { [weak self] in
                self?.library.removeTaskAttachment(photo.id, from: owner) ?? .failed(.taskGone)
            }
            return outcome.isApplied
        }
    }

    /// Add Photo…: Add Files…' picker for images; the files go into the
    /// item's note at its end (`addFilesToTaskNote`).
    var canAddReplicaPhoto: Bool { services.chooseImagesForNote != nil }

    func addReplicaPhoto(to id: UUID) {
        services.chooseImagesForNote?(id)
    }
}

extension TasksPageModel {
    /// A click on a replica row's title edits it in place (R2; the study
    /// leaves in-place editing unresolved, INT-02, so this is E).
    @discardableResult
    func editReplicaTitle(_ id: UUID) -> Bool {
        guard listStyle.isReplica, tab != .done, store.task(withID: id) != nil else { return false }
        if replicaDetail != nil { closeReplicaDetail() }
        replicaSubtaskSelection = nil
        selectOnly(id)
        beginEditingTitle(id)
        return editingTitleID == id
    }
}
