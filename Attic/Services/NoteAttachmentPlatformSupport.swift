import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
@preconcurrency import Quartz

@MainActor
enum NoteAttachmentActions {
    static func preview(store: NoteStore, attachment: NoteAttachment) {
        Task {
            guard let url = await store.materializedURL(for: attachment) else { return }
            AttachmentQuickLookPresenter.shared.present(url)
        }
    }

    /// Open hands another app a disposable read-only copy, never the private
    /// materialization (DATA-002). The private copy is the attachment's only
    /// working file and is digest-checked on every access, so
    /// `AttachmentFileStore` rewrites it from the stored payload as soon as an
    /// external editor saves over it — the edit would vanish with no warning.
    /// Read-only makes the one-way handoff visible in the editor instead. This
    /// is the same promise task attachments already make
    /// (`TaskImageFiles.openableCopy`).
    static func open(store: NoteStore, attachment: NoteAttachment) {
        guard isSafeToOpen(attachment) else {
            store.setAttachmentError(
                "Opening this file type is disabled. Preview or export a copy instead."
            )
            return
        }
        Task {
            guard let sourceURL = await store.materializedURL(for: attachment) else { return }
            do {
                let openableURL = try await Task.detached(priority: .userInitiated) {
                    try openableCopy(of: sourceURL, named: attachment.originalFilename)
                }.value
                NSWorkspace.shared.open(openableURL)
            } catch {
                store.setAttachmentError(
                    "Unable to open a copy of \(attachment.originalFilename): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Reveal keeps selecting the private file. Finder does not edit it, and
    /// selecting a throwaway export directory instead would hide where the
    /// attachment actually lives — the least surprising of the two.
    static func reveal(store: NoteStore, attachment: NoteAttachment) {
        Task {
            guard let url = await store.materializedURL(for: attachment) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A disposable read-only copy under a temporary exports root that is
    /// pruned after a day. Only these copies are pruned, never durable
    /// attachments.
    nonisolated static func openableCopy(of sourceURL: URL, named filename: String) throws -> URL {
        let directory = try disposableExportDirectory()
        let copyURL = directory
            .appendingPathComponent(AttachmentFileStore.sanitizedFilename(filename), isDirectory: false)
            .standardizedFileURL
        guard copyURL.path.hasPrefix(directory.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: copyURL.path
        )
        return copyURL
    }

    nonisolated private static func disposableExportDirectory() throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AtticNoteExports", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86400)
        let existing = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for url in existing {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantFuture
            guard created < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func export(store: NoteStore, attachment: NoteAttachment) {
        Task {
            guard let sourceURL = await store.materializedURL(for: attachment) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.originalFilename
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try exportCopy(from: sourceURL, to: destinationURL)
                }.value
            } catch {
                store.setAttachmentError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    static func locate(store: NoteStore, attachment: NoteAttachment) {
        let panel = NSOpenPanel()
        panel.title = "Locate Original Attachment"
        panel.message = "Choose the original file for \(attachment.originalFilename). Its contents must match the saved attachment."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await store.locateAttachment(attachment, at: url) }
    }

    static func isSafeToOpen(_ attachment: NoteAttachment) -> Bool {
        isSafeToOpen(contentTypeIdentifier: attachment.contentTypeIdentifier)
    }

    /// Shared with task attachments: executables, scripts, packages and
    /// untyped data are previewed rather than opened.
    static func isSafeToOpen(contentTypeIdentifier: String) -> Bool {
        guard !contentTypeIdentifier.isEmpty else { return false }
        let type = UTType(contentTypeIdentifier) ?? .data
        let unsafeIdentifiers = [
            UTType.application.identifier,
            UTType.executable.identifier,
            UTType.script.identifier,
            UTType.package.identifier,
            UTType.diskImage.identifier,
            "com.apple.installer-package"
        ]
        return !unsafeIdentifiers.contains(where: {
            type.conforms(to: UTType($0) ?? .data)
        })
            && type != .data
    }

    nonisolated private static func exportCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".attic-export-\(UUID().uuidString)-\(destinationURL.lastPathComponent)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

final class AttachmentQuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = AttachmentQuickLookPresenter()
    private var previewURL: URL?

    func present(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel,
        previewItemAt index: Int
    ) -> QLPreviewItem {
        guard let previewURL else {
            return NSURL(fileURLWithPath: "/")
        }
        return previewURL as NSURL
    }
}

#endif
