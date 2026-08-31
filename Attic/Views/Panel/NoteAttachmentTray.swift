import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct NoteAttachmentTray: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    let onCancelImport: () -> Void
    let onImportFiles: ([URL], [URL]) -> Void

    @State private var selectedAttachmentID: UUID?
    @State private var isFileTargeted = false

    init(
        noteStore: NoteStore,
        noteDraft: NoteDraftController,
        onCancelImport: @escaping () -> Void = {},
        onImportFiles: @escaping ([URL], [URL]) -> Void = { _, _ in }
    ) {
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.onCancelImport = onCancelImport
        self.onImportFiles = onImportFiles
    }

    private var attachments: [NoteAttachment] {
        guard let noteID = noteDraft.activeNoteID else { return [] }
        return noteStore.attachments(for: noteID)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(attachments) { attachment in
                if attachment.isImage {
                    NoteImageAttachmentCard(
                        noteStore: noteStore,
                        attachment: attachment,
                        selectedAttachmentID: $selectedAttachmentID
                    )
                } else {
                    NoteFileAttachmentCard(
                        noteStore: noteStore,
                        attachment: attachment,
                        selectedAttachmentID: $selectedAttachmentID
                    )
                }
            }

            importStatus
        }
        .overlay {
            if isFileTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onImportFiles(files, [])
            return true
        } isTargeted: {
            isFileTargeted = $0
        }
        .onChange(of: attachments.map(\.id)) { _, availableIDs in
            if let selectedAttachmentID,
               !availableIDs.contains(selectedAttachmentID) {
                self.selectedAttachmentID = nil
            }
        }
        .animation(AtticMotion.quick, value: attachments.map(\.id))
        .animation(AtticMotion.quick, value: noteStore.attachmentImportState)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note attachments")
    }

    @ViewBuilder
    private var importStatus: some View {
        switch noteStore.attachmentImportState {
        case .idle:
            EmptyView()
        case let .importing(completed, total):
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text(importProgressLabel(completed: completed, total: total))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                Spacer(minLength: 4)
                Button(action: onCancelImport) {
                    Image(systemName: "xmark.circle")
                        .atticClearGlassForegroundReadability()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Cancel attachment import")
                .accessibilityIdentifier("cancel-note-attachment-import")
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(importProgressLabel(completed: completed, total: total))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .atticClearGlassForegroundReadability()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    Color.red.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityIdentifier("note-attachment-import-error")
        }
    }

    private func importProgressLabel(completed: Int, total: Int) -> String {
        let count = max(total, 1)
        if count == 1 { return "Importing attachment" }
        return "Importing attachments \(min(completed, count)) of \(count)"
    }
}

private struct NoteImageAttachmentCard: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @Binding var selectedAttachmentID: UUID?

    @State private var isHovering = false
    @State private var isConfirmingRemoval = false
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        selectedAttachmentID == attachment.id || isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: preview) {
                AttachmentPreviewImage(
                    noteStore: noteStore,
                    attachment: attachment,
                    presentation: .inlineImage
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .help("Quick Look \(attachment.originalFilename)")

            HStack(spacing: 7) {
                Image(systemName: "photo")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                Text(attachment.originalFilename)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .atticClearGlassForegroundReadability()
                Spacer(minLength: 4)
                Text(fileSize)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                actionsMenu
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: 34)
        }
        .background(
            Color.primary.opacity(isSelected ? 0.075 : (isHovering ? 0.05 : 0.025)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isSelected ? 0.22 : 0.07),
                    lineWidth: isSelected ? 1 : 0.75
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { selectedAttachmentID = attachment.id }
        .contextMenu { attachmentActions }
        .confirmationDialog(
            "Remove \(attachment.originalFilename)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Attachment", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app-owned copy will be permanently removed from this local note.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachment.originalFilename), image, \(fileSize)")
        .accessibilityIdentifier("note-attachment-\(attachment.id.uuidString)")
    }

    private var fileSize: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }

    private var actionsMenu: some View {
        Menu {
            attachmentActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .atticClearGlassForegroundReadability()
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attachment actions")
        .accessibilityLabel("Actions for \(attachment.originalFilename)")
    }

    @ViewBuilder
    private var attachmentActions: some View {
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

    private func preview() {
        selectedAttachmentID = attachment.id
        NoteAttachmentActions.preview(store: noteStore, attachment: attachment)
    }

    private func open() {
        selectedAttachmentID = attachment.id
        NoteAttachmentActions.open(store: noteStore, attachment: attachment)
    }

    private func reveal() {
        NoteAttachmentActions.reveal(store: noteStore, attachment: attachment)
    }

    private func export() {
        NoteAttachmentActions.export(store: noteStore, attachment: attachment)
    }

    private func remove() {
        _ = noteStore.removeAttachment(attachment)
    }
}

private struct NoteFileAttachmentCard: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @Binding var selectedAttachmentID: UUID?

    @State private var isHovering = false
    @State private var isConfirmingRemoval = false
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        selectedAttachmentID == attachment.id || isFocused
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                AttachmentPreviewImage(
                    noteStore: noteStore,
                    attachment: attachment,
                    presentation: .fileIcon
                )
                .frame(width: 40, height: 40)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .help("Quick Look \(attachment.originalFilename)")

            Button(action: select) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.originalFilename)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .atticClearGlassForegroundReadability()
                    Text(metadata)
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .atticClearGlassForegroundReadability()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            actionsMenu
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(isSelected ? 0.085 : (isHovering ? 0.055 : 0.03)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isSelected ? 0.22 : 0.08),
                    lineWidth: isSelected ? 1 : 0.75
                )
        }
        .onHover { isHovering = $0 }
        .onTapGesture { select() }
        .contextMenu { attachmentActions }
        .confirmationDialog(
            "Remove \(attachment.originalFilename)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Attachment", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app-owned copy will be permanently removed from this local note.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachment.originalFilename), \(metadata)")
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

    private var actionsMenu: some View {
        Menu {
            attachmentActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .atticClearGlassForegroundReadability()
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attachment actions")
        .accessibilityLabel("Actions for \(attachment.originalFilename)")
    }

    @ViewBuilder
    private var attachmentActions: some View {
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

    private func select() {
        selectedAttachmentID = attachment.id
    }

    private func preview() {
        select()
        NoteAttachmentActions.preview(store: noteStore, attachment: attachment)
    }

    private func open() {
        select()
        NoteAttachmentActions.open(store: noteStore, attachment: attachment)
    }

    private func reveal() {
        NoteAttachmentActions.reveal(store: noteStore, attachment: attachment)
    }

    private func export() {
        NoteAttachmentActions.export(store: noteStore, attachment: attachment)
    }

    private func remove() {
        _ = noteStore.removeAttachment(attachment)
    }
}

private struct AttachmentPreviewImage: View {
    enum Presentation {
        case inlineImage
        case fileIcon
    }

    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    let presentation: Presentation

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if presentation == .inlineImage {
                ZStack {
                    Color.primary.opacity(0.035)
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(height: 148)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: presentation == .inlineImage ? 250 : 40)
        .task(id: "\(attachment.id.uuidString)-\(attachment.contentDigest)-\(presentation)") {
            await loadPreview()
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        attachment.contentType.conforms(to: .pdf) ? "doc.richtext" : "doc"
    }

    private func loadPreview() async {
        if presentation == .fileIcon {
            image = NSWorkspace.shared.icon(for: attachment.contentType)
        }

        guard let url = await noteStore.materializedURL(for: attachment) else { return }
        let targetSize = presentation == .inlineImage
            ? CGSize(width: 960, height: 720)
            : CGSize(width: 96, height: 96)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: targetSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            image = representation.nsImage
        } catch {
            guard !Task.isCancelled else { return }
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
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
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var isFileTargeted: Bool
    let isFocused: Bool
    let session: NoteEditorSession
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
        context.coordinator.textView = textView
        _ = context.coordinator.synchronize(parent: self, textView: textView)
        Self.applyReadability(
            to: textView,
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme
        )
        context.coordinator.recordAppliedReadability(
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme
        )

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AttachmentAcceptingTextView else {
            return
        }

        let synchronization = context.coordinator.synchronize(
            parent: self,
            textView: textView
        )
        guard synchronization != .staleSession else { return }
        let replacedExternalText = synchronization == .replacedText

        if !textView.hasMarkedText(), Self.needsReadabilityApplication(
            lastEnabled: context.coordinator.appliedReadabilityEnabled,
            lastColorScheme: context.coordinator.appliedReadabilityColorScheme,
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme,
            externalTextWasReplaced: replacedExternalText
        ) {
            context.coordinator.isApplyingExternalText = true
            Self.applyReadability(
                to: textView,
                enabled: clearReadabilityEnabled,
                colorScheme: colorScheme
            )
            context.coordinator.isApplyingExternalText = false
            context.coordinator.recordAppliedReadability(
                enabled: clearReadabilityEnabled,
                colorScheme: colorScheme
            )
        }

        let expectedSession = session
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                [weak textView, weak coordinator = context.coordinator] in
                guard let textView,
                      textView.window != nil,
                      coordinator?.isCurrent(expectedSession) == true else { return }
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                [weak textView, weak coordinator = context.coordinator] in
                guard let textView,
                      let window = textView.window,
                      coordinator?.isCurrent(expectedSession) == true,
                      window.firstResponder === textView else { return }
                window.makeFirstResponder(nil)
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

    static func applyReadability(
        to textView: NSTextView,
        enabled: Bool,
        colorScheme: ColorScheme
    ) {
        let key = NSAttributedString.Key.shadow
        let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let selectedRanges = textView.selectedRanges
        textView.undoManager?.disableUndoRegistration()
        defer {
            textView.undoManager?.enableUndoRegistration()
            textView.selectedRanges = selectedRanges
        }

        if enabled {
            let shadow = NSShadow()
            shadow.shadowColor = colorScheme == .dark
                ? NSColor.black.withAlphaComponent(0.56)
                : NSColor.white.withAlphaComponent(0.62)
            shadow.shadowBlurRadius = 0.7
            shadow.shadowOffset = NSSize(width: 0, height: -0.35)
            if fullRange.length > 0 {
                textView.textStorage?.addAttribute(key, value: shadow, range: fullRange)
            }
            textView.typingAttributes[key] = shadow
        } else {
            if fullRange.length > 0 {
                textView.textStorage?.removeAttribute(key, range: fullRange)
            }
            textView.typingAttributes.removeValue(forKey: key)
        }
    }

    static func needsReadabilityApplication(
        lastEnabled: Bool?,
        lastColorScheme: ColorScheme?,
        enabled: Bool,
        colorScheme: ColorScheme,
        externalTextWasReplaced: Bool
    ) -> Bool {
        externalTextWasReplaced
            || lastEnabled != enabled
            || lastColorScheme != colorScheme
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        enum SynchronizationResult: Equatable {
            case staleSession
            case unchanged
            case replacedText
        }

        var parent: AttachmentAwareTextEditor
        weak var textView: NSTextView?
        var isApplyingExternalText = false
        var appliedReadabilityEnabled: Bool?
        var appliedReadabilityColorScheme: ColorScheme?
        private var appliedSession: NoteEditorSession?

        init(parent: AttachmentAwareTextEditor) {
            self.parent = parent
        }

        func recordAppliedReadability(enabled: Bool, colorScheme: ColorScheme) {
            appliedReadabilityEnabled = enabled
            appliedReadabilityColorScheme = colorScheme
        }

        @discardableResult
        func synchronize(
            parent newParent: AttachmentAwareTextEditor,
            textView: NSTextView
        ) -> SynchronizationResult {
            if let appliedSession {
                guard newParent.session.generation > appliedSession.generation
                        || newParent.session == appliedSession else {
                    return .staleSession
                }
            }

            let startsNewSession = newParent.session != appliedSession
            if startsNewSession {
                isApplyingExternalText = true
                if textView.hasMarkedText() {
                    textView.unmarkText()
                }
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }

            parent = newParent
            appliedSession = newParent.session

            guard textView.string != newParent.text,
                  startsNewSession || !textView.hasMarkedText() else {
                isApplyingExternalText = false
                return .unchanged
            }

            let selectedRanges = textView.selectedRanges
            isApplyingExternalText = true
            textView.undoManager?.disableUndoRegistration()
            textView.string = newParent.text
            textView.selectedRanges = AttachmentAwareTextEditor.clamped(
                selectedRanges,
                length: (newParent.text as NSString).length
            )
            textView.undoManager?.enableUndoRegistration()
            if startsNewSession {
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }
            isApplyingExternalText = false
            return .replacedText
        }

        func isCurrent(_ session: NoteEditorSession) -> Bool {
            appliedSession == session
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
    private var activePromiseBatches: [UUID: PromisedFileBatch] = [:]

    private static let promiseOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Attic note file promise receiver"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    deinit {
        activePromiseBatches.values.forEach { $0.cancel() }
    }

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

        let batchID = UUID()
        let batch = PromisedFileBatch(
            expectedCount: receivers.count,
            destination: destination
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.activePromiseBatches[batchID] = nil
                switch result {
                case let .success(urls):
                    if let self {
                        self.onImportFiles?(urls, [destination])
                    } else {
                        try? FileManager.default.removeItem(at: destination)
                    }
                case let .failure(message):
                    try? FileManager.default.removeItem(at: destination)
                    self?.onImportError?(message)
                }
            }
        }
        activePromiseBatches[batchID] = batch

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

final class PromisedFileBatch: @unchecked Sendable {
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
    private var isFinished = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        expectedCount: Int,
        destination: URL,
        timeout: TimeInterval = 30,
        completion: @escaping (Result) -> Void
    ) {
        self.expectedCount = expectedCount
        self.destination = destination
        self.completion = completion

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishWithFailure(
                "Unable to receive a promised file: the provider timed out."
            )
        }
        timeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    func record(index: Int, url: URL, error: Error?) {
        let result: Result?
        lock.lock()
        if isFinished || completedIndices.contains(index) {
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
            isFinished = true
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

        if let result {
            timeoutWorkItem?.cancel()
            if case .failure = result {
                try? FileManager.default.removeItem(at: destination)
            }
            completion(result)
        }
    }

    func cancel() {
        finishWithFailure("Unable to receive a promised file: the operation was cancelled.")
    }

    private func finishWithFailure(_ message: String) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        timeoutWorkItem?.cancel()
        try? FileManager.default.removeItem(at: destination)
        completion(.failure(message))
    }
}
