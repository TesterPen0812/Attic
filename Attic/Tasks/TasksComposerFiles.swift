import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files added to the add bar while a task is being written (O17-06):
/// dropped on the bar, pasted into it, or chosen with its strip's Attach
/// button. Each batch is staged at once by the task attachment pipeline
/// (`TaskDroppedFiles.stage`, or the picker's originals as they are), so a
/// promise or a pasted image is never lost while the title is typed. It is
/// then copied into the task attachment store, with the importer's limits,
/// and the new task is saved with those copies in its own save
/// (`TaskDraft.attachments`): a task never exists without its files, so no
/// Undo, quit or crash can come between the two.
struct TasksComposerFiles: Identifiable {
    let id = UUID()
    var staging: TaskAttachmentStaging
    /// The files' names, in order, for the strip's value and VoiceOver.
    var names: [String] { staging.urls.map(\.lastPathComponent) }
}

extension TasksAddBarState {
    /// Every file waiting for the new task, in the order they were added.
    var fileNames: [String] { files.flatMap(\.names) }
}

extension TasksPageModel {
    /// Dropped or pasted content for the new task: staged now (a promised
    /// file or pasted image is written once into Attic's own drop folder).
    /// A batch that cannot be staged says why, as a drop on a row does.
    func addComposerFiles(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let generation = addBarState.filesGeneration
        addBarState.stagingFiles += 1
        // The providers are handed over whole and never touched here again
        // (a drop on a row hands its own over the same way).
        nonisolated(unsafe) let batch = providers
        Task { @MainActor [weak self] in
            do {
                let staging = try await TaskDroppedFiles.stage(batch)
                guard let self else { staging.discard(); return }
                guard self.addBarState.filesGeneration == generation else { staging.discard(); return }
                guard !staging.urls.isEmpty else {
                    staging.discard()
                    self.addBarState.stagingFiles -= 1
                    return
                }
                // The draft keeps waiting ("Preparing files") until the
                // copies exist, so Return saves the task with them at once.
                let files = TasksComposerFiles(staging: staging)
                let copied = await self.prepareComposerFiles(files).value
                guard self.addBarState.filesGeneration == generation else {
                    self.discardComposerFiles([files])
                    return
                }
                self.addBarState.stagingFiles -= 1
                if copied != nil { self.appendComposerFiles(files) }
            } catch {
                guard let self else { return }
                guard self.addBarState.filesGeneration == generation else { return }
                self.addBarState.stagingFiles -= 1
                self.store.reportAttachmentImportFailure(error)
            }
        }
    }

    /// Files chosen with the strip's Attach button (the picker's originals,
    /// read only when the task is added, as a row's picker does).
    func addComposerFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        // They show at once and copy in the background; a Return that
        // comes before the copy has finished waits for it.
        let files = TasksComposerFiles(staging: TaskAttachmentStaging(urls: urls))
        prepareComposerFiles(files)
        appendComposerFiles(files)
    }

    private func appendComposerFiles(_ files: TasksComposerFiles) {
        addBarState.files.append(files)
        let names = files.names
        AccessibilityNotification.Announcement(
            names.count == 1 ? String(localized: "\(names[0]) will be attached to the new task")
                : String(localized: "\(names.count) files will be attached to the new task")
        ).post()
    }

    /// The strip's × on the files: none go onto the new task. Staged copies
    /// Attic made are removed; originals are never touched.
    func clearComposerFiles() {
        addBarState.filesGeneration = UUID()
        addBarState.stagingFiles = 0
        let files = addBarState.files
        addBarState.files = []
        discardComposerFiles(files)
    }

    /// The files leave the bar with the draft being submitted.
    func takeComposerFiles() -> [TasksComposerFiles] {
        let files = addBarState.files
        addBarState.files = []
        return files
    }

    /// The task was not saved: its files are the draft's again. (A batch
    /// whose copy failed was dropped with its own notice.)
    func restoreComposerFiles(_ files: [TasksComposerFiles]) {
        addBarState.files.insert(contentsOf: files.filter { composerPreparations[$0.id] != nil }, at: 0)
    }

    /// The task was saved with these files: Attic's staged copies go, and
    /// the copies in the attachment store are the task's now.
    func composerFilesSaved(_ files: [TasksComposerFiles]) {
        for batch in files {
            batch.staging.discard()
            composerPreparations[batch.id] = nil
            composerPrepared[batch.id] = nil
        }
    }

    /// Copies a batch into the task attachment store, once, one batch at a
    /// time so the importer's per-task limits count every file of the
    /// draft. Until a task is saved with them no task names the copies; an
    /// abandoned draft's are removed by the launch sweep.
    @discardableResult
    func prepareComposerFiles(_ files: TasksComposerFiles) -> Task<[TaskImageReference]?, Never> {
        if let running = composerPreparations[files.id] { return running }
        let previous = composerPreparationTail
        let urls = files.staging.urls, id = files.id, images = store.taskImageFiles
        let copy = Task { @MainActor [weak self] () -> [TaskImageReference]? in
            _ = await previous?.value
            let existing = self?.composerPrepared.values.flatMap { $0 } ?? []
            do {
                let references = try await images.importAttachments(urls, existing: existing)
                guard let self, self.composerPreparations[id] != nil else {
                    await images.remove(references)
                    return nil
                }
                self.composerPrepared[id] = references
                return references
            } catch {
                guard let self, self.composerPreparations[id] != nil else { return nil }
                self.store.reportAttachmentImportFailure(error)
                self.addBarState.files.removeAll { $0.id == id }
                files.staging.discard()
                self.composerPreparations[id] = nil
                return nil
            }
        }
        composerPreparations[id] = copy
        composerPreparationTail = copy
        return copy
    }

    /// The strip's ×, or a draft thrown away: staged copies and the copies
    /// in the attachment store both go. Originals are never touched.
    private func discardComposerFiles(_ files: [TasksComposerFiles]) {
        let images = store.taskImageFiles
        for batch in files {
            batch.staging.discard()
            // A copy still running finds its batch gone and removes itself.
            composerPreparations[batch.id] = nil
            if let references = composerPrepared.removeValue(forKey: batch.id) {
                Task { await images.remove(references) }
            }
        }
    }

    /// Runs `save` with the files' references: now, when every copy exists;
    /// otherwise once the copies still running have finished (`waited`),
    /// with nil when one failed. `save` says whether the task was saved.
    /// Returns that answer, or nil while it waits; a waiting save holds
    /// Quit, like any unsaved change.
    @discardableResult
    func whenComposerFilesAreReady(
        _ files: [TasksComposerFiles],
        _ save: @escaping @MainActor (_ references: [TaskImageReference]?, _ waited: Bool) -> Bool
    ) -> Bool? {
        if files.allSatisfy({ composerPrepared[$0.id] != nil }) {
            return save(files.flatMap { composerPrepared[$0.id] ?? [] }, false)
        }
        let copies = files.map { prepareComposerFiles($0) }
        let token = UUID()
        composerAttachmentTasks[token] = Task { @MainActor [self] in
            defer { composerAttachmentTasks[token] = nil }
            var references: [TaskImageReference]? = []
            for copy in copies {
                if let copied = await copy.value { references?.append(contentsOf: copied) } else { references = nil }
            }
            return save(references, true)
        }
        return nil
    }

    /// What the strip's Attach button shows while files wait: the name of
    /// one, or how many; its tooltip names them all.
    var composerFilesValue: AtticStripValue? {
        let names = addBarState.fileNames
        guard let first = names.first else {
            guard addBarState.stagingFiles > 0 else { return nil }
            let words = String(localized: "Attaching…")
            return AtticStripValue(text: words, ink: .helper, spoken: words)
        }
        let text = names.count == 1 ? first : String(localized: "\(names.count) files")
        return AtticStripValue(text: text, spoken: names.count == 1 ? first : String(localized: "\(names.count) files"),
                               full: names.joined(separator: "\n"))
    }
}
