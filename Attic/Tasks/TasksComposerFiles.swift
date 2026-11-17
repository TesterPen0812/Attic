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
    /// Where the batch goes in the bar: the order it was added in, even
    /// when a dropped batch arrives after a later pick (`nextFilesPlace`).
    var place = 0
}

extension TasksAddBarState {
    /// Every file waiting for the new task, in the order they were added.
    var fileNames: [String] { files.flatMap(\.names) }

    /// The draft holds the panel open: words, files, or files still being
    /// staged or copied (the shell's `.taskComposer` lock).
    var holdsPanel: Bool { Self.holdsPanel(text: text, files: files, stagingFiles: stagingFiles) }

    nonisolated static func holdsPanel(text: TaskAddBarText, files: [TasksComposerFiles], stagingFiles: Int) -> Bool {
        !text.text.isEmpty || !files.isEmpty || stagingFiles > 0
    }

    func nextFilesPlace() -> Int {
        filesPlaced &+= 1
        return filesPlaced
    }

    /// A batch joins the bar in the place it was added in.
    func insert(_ batch: TasksComposerFiles) {
        files.insert(batch, at: files.firstIndex { $0.place > batch.place } ?? files.endIndex)
    }
}

/// A draft's files taken for the save of its task: each batch with its
/// copies in the attachment store.
struct TasksComposerFilesForSave {
    var batches: [(files: TasksComposerFiles, copies: [TaskImageReference])] = []
    var references: [TaskImageReference] { batches.flatMap(\.copies) }
}

extension TasksPageModel {
    // One rule for a draft's files (O17-06): a task is only ever saved at
    // once, with files that are already copied. While a file of this draft
    // is still being staged or copied, Return creates nothing and clears
    // nothing (`composerFilesReadyForSubmission`), so there is no state in
    // which a task is "on its way". What the model holds is this draft's
    // and nothing else's: the copies made (`composerPrepared`) and the
    // copies running (`composerPreparations`). Taking the files for a save
    // takes their entries with them; the strip's × ends all of it.

    /// Dropped or pasted content for the new task: staged now (a promised
    /// file or pasted image is written once into Attic's own drop folder),
    /// then copied into the attachment store, and in the bar once it can be
    /// saved. It keeps the place it was added in, and while it is staged or
    /// copied the draft holds the panel (`holdsPanel`). A batch that cannot
    /// be staged or copied says why, as a drop on a row does.
    func addComposerFiles(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let generation = addBarState.filesGeneration
        let place = addBarState.nextFilesPlace()
        addBarState.stagingFiles += 1
        // The providers are handed over whole and never touched here again
        // (a drop on a row hands its own over the same way).
        nonisolated(unsafe) let batch = providers
        Task { @MainActor [weak self] in
            do {
                let staging = try await TaskDroppedFiles.stage(batch)
                guard self?.addBarState.filesGeneration == generation else { staging.discard(); return }
                guard !staging.urls.isEmpty else {
                    staging.discard()
                    self?.addBarState.stagingFiles -= 1
                    return
                }
                let files = TasksComposerFiles(staging: staging, place: place)
                self?.announceComposerFiles(files)
                // The page model is never held across the copy: one that
                // goes meanwhile ends the copy (`deinit`) and its staging here.
                guard let copy = self?.prepareComposerFiles(files) else { staging.discard(); return }
                let copied = await copy.value
                // The strip was cleared or the page went meanwhile: the copy ended itself.
                guard let self, self.addBarState.filesGeneration == generation else { staging.discard(); return }
                // In the bar before it stops counting as staged, so the
                // draft never lets go of the panel in between.
                if copied != nil { self.addBarState.insert(files) }
                self.addBarState.stagingFiles -= 1
            } catch {
                guard let self, self.addBarState.filesGeneration == generation else { return }
                self.addBarState.stagingFiles -= 1
                self.store.reportAttachmentImportFailure(error)
            }
        }
    }

    /// Files chosen with the strip's Attach button (the picker's originals,
    /// never touched). They show at once and are copied in the background.
    func addComposerFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let files = TasksComposerFiles(staging: TaskAttachmentStaging(urls: urls), place: addBarState.nextFilesPlace())
        addBarState.insert(files)
        announceComposerFiles(files)
        prepareComposerFiles(files)
    }

    private func announceComposerFiles(_ files: TasksComposerFiles) {
        let names = files.names
        AccessibilityNotification.Announcement(
            names.count == 1 ? String(localized: "\(names[0]) will be attached to the new task")
                : String(localized: "\(names.count) files will be attached to the new task")
        ).post()
    }

    /// The strip's × on the files: none go onto the new task. Everything of
    /// this draft ends: copies still running are cancelled, staged copies
    /// and copies in the attachment store are removed, and a copy that
    /// fails afterwards says nothing. Originals are never touched.
    func clearComposerFiles() {
        addBarState.filesGeneration = UUID()
        addBarState.stagingFiles = 0
        let files = addBarState.files
        addBarState.files = []
        files.forEach { $0.staging.discard() }
        endComposerCopies()
    }

    /// The draft's copies end: those running are cancelled and those made
    /// are removed, their import hold at once and their bytes in the
    /// background. A copy belongs to the draft until it is saved with its
    /// task (the save ends the hold), the strip's × removes it, or the page
    /// model goes away (`deinit`); each of those ends it. A copy already
    /// inside one large file can't be interrupted; it ends on its own and
    /// removes what it made. Nothing waits for it.
    func endComposerCopies() {
        composerPreparations.values.forEach { $0.cancel() }
        composerPreparations = [:]
        composerPreparationTail = nil
        let copies = composerPrepared.values.flatMap { $0 }
        composerPrepared = [:]
        guard !copies.isEmpty else { return }
        let images = store.taskImageFiles
        images.files.finishCandidates(Set(copies.map(\.id)))
        Task { await images.remove(copies) }
    }

    /// Whether every file of the draft is staged and copied. Starts the
    /// copy of a batch that has none yet.
    var composerFilesArePrepared: Bool {
        for files in addBarState.files where composerPrepared[files.id] == nil { prepareComposerFiles(files) }
        return addBarState.stagingFiles == 0 && addBarState.files.allSatisfy { composerPrepared[$0.id] != nil }
    }

    /// The draft's files, with their copies, for the save of its task. They
    /// stay the draft's until that save is confirmed (`composerFilesSaved`):
    /// a failed save leaves the draft as it was. Call only when
    /// `composerFilesReadyForSubmission()`.
    func composerFilesForSave() -> TasksComposerFilesForSave {
        TasksComposerFilesForSave(batches: addBarState.files.map { ($0, composerPrepared[$0.id] ?? []) })
    }

    /// The task was saved with these files: they leave the draft, Attic's
    /// staged copies go, and the copies in the attachment store are the
    /// task's now. VoiceOver hears that they arrived, as it did when they
    /// were attached afterwards.
    func composerFilesSaved(_ taken: TasksComposerFilesForSave, on title: String) {
        let saved = Set(taken.batches.map(\.files.id))
        addBarState.files.removeAll { saved.contains($0.id) }
        saved.forEach { composerPrepared[$0] = nil }
        taken.batches.forEach { $0.files.staging.discard() }
        let added = taken.references.count
        guard added > 0 else { return }
        AccessibilityNotification.Announcement(
            added == 1 ? String(localized: "Added 1 file to \(title)") : String(localized: "Added \(added) files to \(title)")
        ).post()
    }

    /// Copies a batch into the task attachment store, once, one batch at a
    /// time so the importer's per-task limits count every file of this
    /// draft (and no other task's). Until a task is saved with them no task
    /// names the copies; an abandoned draft's are removed by the launch
    /// sweep. A batch the strip's × removed meanwhile ends quietly.
    @discardableResult
    func prepareComposerFiles(_ files: TasksComposerFiles) -> Task<[TaskImageReference]?, Never> {
        if let running = composerPreparations[files.id] { return running }
        let previous = composerPreparationTail
        let urls = files.staging.urls, id = files.id, images = store.taskImageFiles
        let copy = Task { @MainActor [weak self] () -> [TaskImageReference]? in
            _ = await previous?.value
            // `self` is never held across the copy: a page model that goes
            // meanwhile cancels it at once (`deinit`).
            guard self?.composerPreparations[id] != nil, !Task.isCancelled,
                  let existing = self?.composerPrepared.values.flatMap({ $0 }) else { return nil }
            do {
                let references = try await images.importAttachments(urls, existing: existing)
                guard let self, self.composerPreparations[id] != nil else {
                    await images.remove(references)
                    return nil
                }
                self.composerPreparations[id] = nil
                self.composerPrepared[id] = references
                return references
            } catch {
                guard let self, self.composerPreparations[id] != nil else { return nil }
                self.composerPreparations[id] = nil
                self.store.reportAttachmentImportFailure(error)
                self.addBarState.files.removeAll { $0.id == id }
                files.staging.discard()
                return nil
            }
        }
        composerPreparations[id] = copy
        composerPreparationTail = copy
        return copy
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
