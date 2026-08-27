import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct NoteAttachmentTray: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    let onCancelImport: () -> Void

    init(
        noteStore: NoteStore,
        noteDraft: NoteDraftController,
        onCancelImport: @escaping () -> Void = {}
    ) {
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.onCancelImport = onCancelImport
    }

    private var attachments: [NoteAttachment] {
        guard let noteID = noteDraft.activeNoteID else { return [] }
        return noteStore.attachments(for: noteID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 3) {
                        ForEach(attachments) { attachment in
                            NoteAttachmentRow(
                                noteStore: noteStore,
                                attachment: attachment
                            )
                        }
                    }
                }
                .frame(maxHeight: 132)
                .scrollIndicators(.never)
                .accessibilityLabel("Note attachments")
            }

            switch noteStore.attachmentImportState {
            case .idle:
                EmptyView()
            case let .importing(completed, total):
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(importProgressLabel(completed: completed, total: total))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Cancel import", systemImage: "xmark.circle", action: onCancelImport)
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Cancel attachment import")
                        .accessibilityIdentifier("cancel-note-attachment-import")
                }
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(importProgressLabel(completed: completed, total: total))
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        Color.red.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .accessibilityIdentifier("note-attachment-import-error")
            }
        }
        .animation(AtticMotion.quick, value: attachments.map(\.id))
        .animation(AtticMotion.quick, value: noteStore.attachmentImportState)
    }

    private func importProgressLabel(completed: Int, total: Int) -> String {
        let count = max(total, 1)
        if count == 1 { return "Importing attachment" }
        return "Importing attachments \(min(completed, count)) of \(count)"
    }
}

private struct NoteAttachmentRow: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment

    @State private var isHovering = false
    @State private var isConfirmingRemoval = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Button(action: preview) {
                HStack(spacing: 8) {
                    AttachmentThumbnail(noteStore: noteStore, attachment: attachment)
                        .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.originalFilename)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(metadata)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens Quick Look")

            Menu {
                Button("Quick Look", systemImage: "eye", action: preview)
                Button("Open", systemImage: "arrow.up.forward.square", action: open)
                    .disabled(!NoteAttachmentActions.isSafeToOpen(attachment))
                Button("Reveal in Finder", systemImage: "folder", action: reveal)
                Button("Export Copy…", systemImage: "square.and.arrow.down", action: export)
                Divider()
                Button("Remove Attachment", systemImage: "trash", role: .destructive) {
                    isConfirmingRemoval = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attachment actions")
            .accessibilityLabel("Actions for \(attachment.originalFilename)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(
            Color.primary.opacity(isHovering || isFocused ? 0.06 : 0.025),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isFocused ? 0.45 : 0),
                    lineWidth: 1
                )
        }
        .onHover { isHovering = $0 }
        .confirmationDialog(
            "Remove \(attachment.originalFilename)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Attachment", role: .destructive) {
                _ = noteStore.removeAttachment(attachment)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The attachment will be removed from every synced copy of this note.")
        }
        .contextMenu {
            Button("Quick Look", systemImage: "eye", action: preview)
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
                .disabled(!NoteAttachmentActions.isSafeToOpen(attachment))
            Button("Reveal in Finder", systemImage: "folder", action: reveal)
            Button("Export Copy…", systemImage: "square.and.arrow.down", action: export)
            Divider()
            Button("Remove Attachment", systemImage: "trash", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-attachment-\(attachment.id.uuidString)")
    }

    private var metadata: String {
        let type = attachment.contentType.localizedDescription
            ?? attachment.contentType.preferredFilenameExtension?.uppercased()
            ?? "File"
        let size = ByteCountFormatter.string(
            fromByteCount: attachment.byteCount,
            countStyle: .file
        )
        return "\(type) · \(size)"
    }

    private var accessibilityLabel: String {
        "\(attachment.originalFilename), \(metadata)"
    }

    private func preview() {
        NoteAttachmentActions.preview(store: noteStore, attachment: attachment)
    }

    private func open() {
        NoteAttachmentActions.open(store: noteStore, attachment: attachment)
    }

    private func reveal() {
        NoteAttachmentActions.reveal(store: noteStore, attachment: attachment)
    }

    private func export() {
        NoteAttachmentActions.export(store: noteStore, attachment: attachment)
    }
}

private struct AttachmentThumbnail: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.primary.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: "\(attachment.id.uuidString)-\(attachment.contentDigest)") {
            if !attachment.isImage {
                image = NSWorkspace.shared.icon(forFileType: attachment.contentTypeIdentifier)
            }

            guard let url = await noteStore.materializedURL(for: attachment) else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 72, height: 72),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                representation,
                _
            in
                let generated = representation?.nsImage
                    ?? NSWorkspace.shared.icon(forFile: url.path)
                DispatchQueue.main.async {
                    image = generated
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Routes Finder-backed representations before generic strings. A path-looking
/// plain string remains text; only an actual file URL, legacy filename list, or
/// file-promise representation is considered an attachment.
enum NoteAttachmentPasteboardRouter {
    static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let promisedFileURLType = NSPasteboard.PasteboardType(
        "com.apple.pasteboard.promised-file-url"
    )
    static let promisedFileContentType = NSPasteboard.PasteboardType(
        "com.apple.pasteboard.promised-file-content-type"
    )
    static let legacyFilePromiseType = NSPasteboard.PasteboardType("NSFilesPromisePboardType")

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let modern = (
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [NSURL]
        )?.map { $0 as URL }.filter(\.isFileURL) ?? []
        if !modern.isEmpty {
            return deduplicated(modern)
        }

        let legacyPaths = pasteboard.propertyList(forType: legacyFilenamesType)
            as? [String] ?? []
        return deduplicated(legacyPaths.map { URL(fileURLWithPath: $0) })
    }

    static func filePromiseReceivers(
        from pasteboard: NSPasteboard
    ) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
    }

    static func containsFilePromiseRepresentation(_ pasteboard: NSPasteboard) -> Bool {
        if !filePromiseReceivers(from: pasteboard).isEmpty { return true }
        let types = Set(pasteboard.types ?? [])
        return types.contains(promisedFileURLType)
            || types.contains(promisedFileContentType)
            || types.contains(legacyFilePromiseType)
    }

    static func prefersAttachments(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty
            || containsFilePromiseRepresentation(pasteboard)
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}

/// A Cocoa text editor keeps selection, marked text, undo, links, and keyboard
/// behavior native while taking ownership of file drag/paste classification.
struct AttachmentAwareTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFileTargeted: Bool
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    let onImportFiles: ([URL], [URL]) -> Void
    let onImportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = AttachmentAcceptingTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.registerForDraggedTypes([
            .fileURL,
            .URL,
            .string,
            NoteAttachmentPasteboardRouter.legacyFilenamesType,
            NoteAttachmentPasteboardRouter.promisedFileURLType,
            NoteAttachmentPasteboardRouter.promisedFileContentType,
            NoteAttachmentPasteboardRouter.legacyFilePromiseType
        ])
        textView.setAccessibilityIdentifier("note-body")

        textView.onImportFiles = { [weak coordinator = context.coordinator] urls, cleanup in
            coordinator?.parent.onImportFiles(urls, cleanup)
        }
        textView.onImportError = { [weak coordinator = context.coordinator] message in
            coordinator?.parent.onImportError(message)
        }
        textView.onFileTargetingChanged = {
            [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.isFileTargeted = targeted
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? AttachmentAcceptingTextView else {
            return
        }

        if textView.string != text, !textView.hasMarkedText() {
            let selectedRanges = textView.selectedRanges
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            textView.selectedRanges = Self.clamped(
                selectedRanges,
                length: (text as NSString).length
            )
            context.coordinator.isApplyingExternalText = false
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    private static func clamped(_ ranges: [NSValue], length: Int) -> [NSValue] {
        let clamped = ranges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location != NSNotFound else { return nil }
            let location = min(max(range.location, 0), length)
            let available = max(length - location, 0)
            return NSValue(range: NSRange(
                location: location,
                length: min(range.length, available)
            ))
        }
        return clamped.isEmpty
            ? [NSValue(range: NSRange(location: length, length: 0))]
            : clamped
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AttachmentAwareTextEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false

        init(parent: AttachmentAwareTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }
    }
}

private final class AttachmentAcceptingTextView: NSTextView {
    var onImportFiles: (([URL], [URL]) -> Void)?
    var onImportError: ((String) -> Void)?
    var onFileTargetingChanged: ((Bool) -> Void)?

    private static let promiseOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Attic note file promise receiver"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard NoteAttachmentPasteboardRouter.prefersAttachments(
            sender.draggingPasteboard
        ) else {
            return super.draggingEntered(sender)
        }
        onFileTargetingChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard NoteAttachmentPasteboardRouter.prefersAttachments(
            sender.draggingPasteboard
        ) else {
            onFileTargetingChanged?(false)
            return super.draggingUpdated(sender)
        }
        onFileTargetingChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileTargetingChanged?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if NoteAttachmentPasteboardRouter.prefersAttachments(
            sender.draggingPasteboard
        ) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileTargetingChanged?(false)
        if handleAttachmentPasteboard(sender.draggingPasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if handleAttachmentPasteboard(.general) { return }
        super.paste(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape does not turn an editing session into an implicit save, close,
        // or focus transition. Standard text undo remains Command-Z.
    }

    private func handleAttachmentPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let urls = NoteAttachmentPasteboardRouter.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            onImportFiles?(urls, [])
            return true
        }

        let receivers = NoteAttachmentPasteboardRouter.filePromiseReceivers(
            from: pasteboard
        )
        if !receivers.isEmpty {
            receivePromisedFiles(receivers)
            return true
        }

        if NoteAttachmentPasteboardRouter.containsFilePromiseRepresentation(
            pasteboard
        ) {
            onImportError?("The promised file could not be received from its source app.")
            return true
        }
        return false
    }

    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attic", isDirectory: true)
            .appendingPathComponent("FilePromises", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            onImportError?("Unable to prepare a safe location for the promised file.")
            return
        }

        let batch = PromisedFileBatch(
            expectedCount: receivers.count,
            destination: destination
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case let .success(urls):
                    self?.onImportFiles?(urls, [destination])
                case let .failure(message):
                    try? FileManager.default.removeItem(at: destination)
                    self?.onImportError?(message)
                }
            }
        }

        for (index, receiver) in receivers.enumerated() {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: Self.promiseOperationQueue
            ) { url, error in
                batch.record(index: index, url: url, error: error)
            }
        }
    }
}

private final class PromisedFileBatch: @unchecked Sendable {
    enum Result {
        case success([URL])
        case failure(String)
    }

    private let lock = NSLock()
    private let expectedCount: Int
    private let destination: URL
    private let completion: (Result) -> Void
    private var completedIndices = Set<Int>()
    private var delivered: [(Int, URL)] = []
    private var errors: [String] = []

    init(
        expectedCount: Int,
        destination: URL,
        completion: @escaping (Result) -> Void
    ) {
        self.expectedCount = expectedCount
        self.destination = destination
        self.completion = completion
    }

    func record(index: Int, url: URL, error: Error?) {
        let result: Result?
        lock.lock()
        if completedIndices.contains(index) {
            lock.unlock()
            return
        }
        completedIndices.insert(index)
        if let error {
            errors.append(error.localizedDescription)
        } else {
            delivered.append((index, url.standardizedFileURL))
        }

        if completedIndices.count == expectedCount {
            if errors.isEmpty, delivered.count == expectedCount {
                result = .success(delivered.sorted { $0.0 < $1.0 }.map(\.1))
            } else {
                let detail = errors.first ?? "No file was delivered."
                result = .failure("Unable to receive a promised file: \(detail)")
            }
        } else {
            result = nil
        }
        lock.unlock()

        if let result { completion(result) }
    }
}
