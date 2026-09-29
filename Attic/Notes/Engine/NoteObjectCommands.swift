import AppKit
import CryptoKit
import QuickLookUI
import UniformTypeIdentifiers

/// One action vocabulary for the card, keyboard, menus and VoiceOver.
enum NoteImageSizePreset: String, CaseIterable {
    case small, medium, full
    var fraction: Double {
        switch self {
        case .small: 0.25
        case .medium: 0.5
        case .full: 1
        }
    }
}

enum NoteObjectCommand: Equatable {
    case quickLook
    case open
    case openWith(URL)
    case copyImage
    case copyFile
    case exportCopy(URL?)
    case showInFinder
    case size(Double)
    case sizePreset(NoteImageSizePreset)
    case delete
    case retry
    case retryPreview
    case locate
    case locateAt(URL)
}

enum NoteObjectState: Equatable {
    case ready
    case importFailed(String)
    case previewUnavailable
    case originalMissing
}

struct NoteObjectCommandValidation: Equatable {
    let enabled: Bool
    let state: NoteObjectState?
}

@MainActor
extension NoteEditorEngine {
    func objectPlacement(_ id: UUID) -> (NoteObjectAttachment, NSRange)? {
        var found: (NoteObjectAttachment, NSRange)?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) {
            value, range, stop in
            if let object = value as? NoteObjectAttachment, object.objectID == id {
                found = (object, range)
                stop.pointee = true
            }
        }
        return found
    }

    func objectState(_ id: UUID) -> NoteObjectState? {
        guard let (object, _) = objectPlacement(id) else { return nil }
        return objectState(for: object)
    }

    func objectState(for object: NoteObjectAttachment) -> NoteObjectState {
        if let file = object as? NoteFileAttachment, let failure = file.importFailure {
            return .importFailed(failure)
        }
        let attachmentID = (object as? NoteImageAttachment)?.attachmentID
            ?? (object as? NoteFileAttachment)?.attachmentID
        guard let attachmentID, staged[attachmentID] != nil || imageProvider?.hasAttachmentBytes(attachmentID) == true else {
            return .originalMissing
        }
        if let image = object as? NoteImageAttachment, image.isMissing { return .previewUnavailable }
        if let file = object as? NoteFileAttachment, file.previewUnavailable { return .previewUnavailable }
        return .ready
    }

    func validate(_ command: NoteObjectCommand, objectID: UUID) -> NoteObjectCommandValidation {
        guard let (object, _) = objectPlacement(objectID),
              object is NoteImageAttachment || object is NoteFileAttachment else {
            return .init(enabled: false, state: nil)
        }
        return validate(command, object: object, state: objectState(for: object))
    }

    func validate(_ command: NoteObjectCommand, object: NoteObjectAttachment,
                  state: NoteObjectState) -> NoteObjectCommandValidation {
        let bytesExist = state == .ready || state == .previewUnavailable
        let enabled: Bool
        switch command {
        case .quickLook, .exportCopy:
            enabled = bytesExist
        case .open, .openWith, .showInFinder:
            enabled = state == .ready
        case .copyImage:
            enabled = state == .ready && object is NoteImageAttachment
        case .copyFile:
            enabled = state == .ready && object is NoteFileAttachment
        case let .size(fraction):
            enabled = !isReadOnly && state == .ready && object is NoteImageAttachment
                && fraction.isFinite && (0.1...1).contains(fraction)
        case .sizePreset:
            enabled = !isReadOnly && state == .ready && object is NoteImageAttachment
        case .delete:
            enabled = !isReadOnly
        case .retry:
            if case .importFailed = state { enabled = !isReadOnly } else { enabled = false }
        case .retryPreview:
            enabled = state == .previewUnavailable
        case .locate, .locateAt:
            enabled = state == .originalMissing && !isReadOnly
        }
        return .init(enabled: enabled, state: state)
    }

    /// A presentation surface can report a failed preview without changing
    /// the saved object or treating its verified bytes as lost.
    func markPreviewUnavailable(_ objectID: UUID) {
        guard let (object, _) = objectPlacement(objectID),
              objectState(objectID) == .ready else { return }
        if let file = object as? NoteFileAttachment { file.previewUnavailable = true }
        if let image = object as? NoteImageAttachment {
            image.isMissing = true
            image.failureMessage = String(localized: "Preview unavailable")
        }
    }

    /// The surface may pass a destination/app URL after its own picker. An
    /// omitted Export destination uses NSSavePanel here. System actions use
    /// a read-only temporary copy, never the private stored file itself.
    @discardableResult
    func perform(_ command: NoteObjectCommand, objectID: UUID) async -> Bool {
        guard validate(command, objectID: objectID).enabled,
              let (object, range) = objectPlacement(objectID) else { return false }
        switch command {
        case let .sizePreset(preset):
            return await perform(.size(preset.fraction), objectID: objectID)
        case let .size(fraction):
            guard let image = object as? NoteImageAttachment else { return false }
            let resized = NoteImageAttachment(objectID: image.objectID, attachmentID: image.attachmentID,
                preferredWidthFraction: fraction, pixelSize: image.pixelSize, extras: image.extras)
            resized.filename = image.filename
            resized.isMissing = image.isMissing
            resized.renderedImage = image.renderedImage
            return performEdit(range, with: NoteTextCodec.attachmentString(resized,
                attributes: textStorage.attributes(at: range.location, effectiveRange: nil)),
                name: String(localized: "Resize Image"), selection: range)
        case .delete:
            return performEdit(range, with: NSAttributedString(string: ""),
                name: String(localized: "Delete Attachment"),
                selection: NSRange(location: range.location, length: 0))
        case .retry:
            onRetryImportObject?(objectID)
            return onRetryImportObject != nil
        case .retryPreview:
            if let image = object as? NoteImageAttachment {
                retryImagePreview(image)
                return true
            }
            if let file = object as? NoteFileAttachment {
                file.previewUnavailable = false
                return true
            }
            return false
        case .locate:
            onLocateObject?(objectID)
            return onLocateObject != nil
        case let .locateAt(url):
            guard let id = (object as? NoteImageAttachment)?.attachmentID
                ?? (object as? NoteFileAttachment)?.attachmentID,
                await imageProvider?.locateAttachment(id, at: url) == true else { return false }
            if let image = object as? NoteImageAttachment { retryImagePreview(image) }
            if let file = object as? NoteFileAttachment { file.originalMissing = false }
            return true
        case .copyImage:
            guard let image = object as? NoteImageAttachment,
                  let data = await objectBytes(image) else { return false }
            let board = NSPasteboard.general
            board.clearContents()
            let contentType = staged[image.attachmentID]?.contentTypeIdentifier
                ?? UTType(filenameExtension: (image.filename as NSString).pathExtension)?.identifier ?? UTType.png.identifier
            let fragment = writeSelection(range, to: board,
                types: [Self.fragmentType, .rtf, .string, NSPasteboard.PasteboardType(contentType)])
            let imageData = board.setData(data, forType: NSPasteboard.PasteboardType(contentType))
            return fragment && imageData
        case .copyFile:
            guard let bytes = await objectBytes(object) else { return false }
            do {
                let name = objectFilename(object)
                let url = try await Task.detached(priority: .userInitiated) {
                    try NoteObjectTemporaryCopy.write(bytes, filename: name)
                }.value
                let board = NSPasteboard.general
                board.clearContents()
                return board.writeObjects([url as NSURL])
            } catch { onNotice?(error.localizedDescription); return false }
        case let .exportCopy(destination):
            let name = objectFilename(object)
            let target: URL
            if let destination { target = destination }
            else {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                target = chosen
            }
            guard let bytes = await objectBytes(object) else { return false }
            let scoped = target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() } }
            do { try bytes.write(to: target, options: .atomic); return true }
            catch { onNotice?(error.localizedDescription); return false }
        case .quickLook, .open, .openWith, .showInFinder:
            guard let bytes = await objectBytes(object) else { return false }
            do {
                let filename = objectFilename(object)
                let url = try await Task.detached(priority: .userInitiated) {
                    try NoteObjectTemporaryCopy.write(bytes, filename: filename)
                }.value
                switch command {
                case .quickLook:
                    if !NoteObjectQuickLook.shared.show(url) {
                        markPreviewUnavailable(objectID)
                        return false
                    }
                case .open: return NSWorkspace.shared.open(url)
                case let .openWith(application):
                    let opened = await withCheckedContinuation { continuation in
                        NSWorkspace.shared.open([url], withApplicationAt: application,
                            configuration: NSWorkspace.OpenConfiguration()) { _, error in
                            continuation.resume(returning: error == nil)
                        }
                    }
                    return opened
                case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
                default: break
                }
                return true
            } catch {
                if command == .quickLook { markPreviewUnavailable(objectID) }
                onNotice?(error.localizedDescription)
                return false
            }
        }
    }

    /// Completes Retry after the surface has let the person reselect a file.
    @discardableResult
    func replaceFailedFile(_ objectID: UUID, with imported: NoteImportedObject) -> Bool {
        guard let (object, range) = objectPlacement(objectID), object is NoteFileAttachment,
              case .importFailed = objectState(objectID) else { return false }
        if let staged = imported.staged, let reason = onImportAdmission?(staged) {
            onNotice?(reason)
            return false
        }
        let replacement: NoteObjectAttachment
        if let item = imported.staged, let size = imported.pixelSize {
            let image = NoteImageAttachment(objectID: objectID, attachmentID: item.id,
                preferredWidthFraction: 1, pixelSize: size)
            image.filename = imported.filename
            replacement = image
        } else {
            replacement = NoteFileAttachment(objectID: objectID, attachmentID: imported.staged?.id,
                filename: imported.filename, contentTypeIdentifier: imported.contentTypeIdentifier,
                byteCount: imported.byteCount, importFailure: imported.failure)
        }
        if let item = imported.staged { stageImported(item) }
        let result = performEdit(range, with: NoteTextCodec.attachmentString(replacement,
            attributes: textStorage.attributes(at: range.location, effectiveRange: nil)),
            name: String(localized: "Retry File Import"), selection: range)
        if !result, let id = imported.staged?.id { unstageImported(id) }
        return result
    }

    private func objectFilename(_ object: NoteObjectAttachment) -> String {
        if let file = object as? NoteFileAttachment { return file.filename }
        if let image = object as? NoteImageAttachment { return image.filename.isEmpty ? "image" : image.filename }
        return "attachment"
    }

    private func objectBytes(_ object: NoteObjectAttachment) async -> Data? {
        guard let id = (object as? NoteImageAttachment)?.attachmentID
            ?? (object as? NoteFileAttachment)?.attachmentID else { return nil }
        if let staged = staged[id] { return staged.data }
        if let stored = imageProvider?.attachmentBytes(forAttachment: id) { return stored.data }
        guard let url = await imageProvider?.fileURL(forAttachment: id) else { return nil }
        return try? await Task.detached { try Data(contentsOf: url) }.value
    }
}

private enum NoteObjectTemporaryCopy {
    static func write(_ data: Data, filename: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Attic Note Actions", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Copies handed to another process may still be open. Only collect
        // old copies on a later action, never the one just presented.
        if let older = try? FileManager.default.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.creationDateKey]) {
            for entry in older {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
                if Date().timeIntervalSince(created) > 86_400 { try? FileManager.default.removeItem(at: entry) }
            }
        }
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = (filename as NSString).lastPathComponent
        let url = root.appendingPathComponent(safe.isEmpty || safe == "." || safe == ".." ? "attachment" : safe)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }
}

@MainActor
private final class NoteObjectQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = NoteObjectQuickLook()
    private var item: NSURL?

    func show(_ url: URL) -> Bool {
        item = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        item
    }
}
