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

    static func open(store: NoteStore, attachment: NoteAttachment) {
        guard isSafeToOpen(attachment) else {
            store.setAttachmentError(
                "Opening this file type is disabled. Preview or export a copy instead."
            )
            return
        }
        Task {
            guard let url = await store.materializedURL(for: attachment) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(store: NoteStore, attachment: NoteAttachment) {
        Task {
            guard let url = await store.materializedURL(for: attachment) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
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
                try exportCopy(from: sourceURL, to: destinationURL)
            } catch {
                store.setAttachmentError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    static func isSafeToOpen(_ attachment: NoteAttachment) -> Bool {
        let type = attachment.contentType
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
            && !attachment.contentTypeIdentifier.isEmpty
            && attachment.contentType != .data
    }

    private static func exportCopy(from sourceURL: URL, to destinationURL: URL) throws {
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
