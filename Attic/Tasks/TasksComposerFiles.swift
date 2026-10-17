import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files added to the add bar while a task is being written (O17-06):
/// dropped on the bar, pasted into it, or chosen with its strip's Attach
/// button. Each batch is staged at once by the task attachment pipeline
/// (`TaskDroppedFiles.stage`, or the picker's originals as they are), so a
/// promise or a pasted image is never lost while the title is typed; the
/// files go onto the new task when it is added, through the same import
/// (`TaskStore.attachStagedFiles`) with its limits and rollback.
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
        addBarState.stagingFiles += 1
        // The providers are handed over whole and never touched here again
        // (a drop on a row hands its own over the same way).
        nonisolated(unsafe) let batch = providers
        Task { @MainActor [weak self] in
            do {
                let staging = try await TaskDroppedFiles.stage(batch)
                guard let self else { staging.discard(); return }
                self.addBarState.stagingFiles -= 1
                self.appendComposerFiles(staging)
            } catch {
                guard let self else { return }
                self.addBarState.stagingFiles -= 1
                self.store.reportAttachmentImportFailure(error)
            }
        }
    }

    /// Files chosen with the strip's Attach button (the picker's originals,
    /// read only when the task is added, as a row's picker does).
    func addComposerFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        appendComposerFiles(TaskAttachmentStaging(urls: urls))
    }

    private func appendComposerFiles(_ staging: TaskAttachmentStaging) {
        guard !staging.urls.isEmpty else { staging.discard(); return }
        addBarState.files.append(TasksComposerFiles(staging: staging))
        let names = staging.urls.map(\.lastPathComponent)
        AccessibilityNotification.Announcement(
            names.count == 1 ? String(localized: "\(names[0]) will be attached to the new task")
                : String(localized: "\(names.count) files will be attached to the new task")
        ).post()
    }

    /// The strip's × on the files: none go onto the new task. Staged copies
    /// Attic made are removed; originals are never touched.
    func clearComposerFiles() {
        let files = addBarState.files
        addBarState.files = []
        files.forEach { $0.staging.discard() }
    }

    /// The new task takes the bar's files (O17-06): one import, the same
    /// one a drop on its row runs. The task exists already, so a failed
    /// import keeps it and says why; its files list opens on what arrived.
    func attachComposerFiles(to id: UUID) {
        let files = addBarState.files
        guard !files.isEmpty else { return }
        addBarState.files = []
        let staging = TaskAttachmentStaging(merging: files.map(\.staging))
        Task { @MainActor [weak self] in
            guard let self else { staging.discard(); return }
            guard let owner = self.store.attachmentOwnerID(for: id) else { staging.discard(); return }
            let added = await self.store.attachStagedFiles(to: owner) { staging }
            guard let added, !added.isEmpty else { return }
            self.setFilesExpanded(owner, true)
            let title = self.store.task(withID: owner)?.title ?? ""
            AccessibilityNotification.Announcement(
                added.count == 1 ? String(localized: "Added 1 file to \(title)") : String(localized: "Added \(added.count) files to \(title)")
            ).post()
        }
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
