import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct NoteAttachmentTray: View {
    @Environment(\.atticPanelThemePalette) private var palette
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    let onCancelImport: () -> Void
    let onImportFiles: ([URL], [URL]) -> Void

    @State private var selectedAttachmentID: UUID?
    @State private var isFileTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Supplied by the composer, which already resolved every anchor once for
    /// this body (PERF-12). Nil keeps the tray self-sufficient for previews.
    private let providedAttachments: [NoteAttachment]?

    init(
        noteStore: NoteStore,
        noteDraft: NoteDraftController,
        trayAttachments: [NoteAttachment]? = nil,
        onCancelImport: @escaping () -> Void = {},
        onImportFiles: @escaping ([URL], [URL]) -> Void = { _, _ in }
    ) {
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.providedAttachments = trayAttachments
        self.onCancelImport = onCancelImport
        self.onImportFiles = onImportFiles
    }

    /// Attachments the body is not showing inline right now.
    private var attachments: [NoteAttachment] {
        if let providedAttachments { return providedAttachments }
        guard let noteID = noteDraft.activeNoteID else { return [] }
        let body = noteDraft.body
        let savedBody = noteStore.note(withID: noteID)?.body ?? body
        let edits = NoteTextReplacement.edits(from: savedBody, to: body)
        return noteStore.attachments(for: noteID).filter {
            guard let offset = $0.inlineOffset else { return true }
            return NoteInlineAnchor.moved(offset, by: edits, in: body) >= (body as NSString).length
        }
    }

    private var importPresentation: NoteAttachmentImportPresentation {
        noteStore.attachmentImportPresentation(for: noteDraft.editorSession)
    }

    private var importState: AttachmentImportState {
        switch importPresentation {
        case .idle:
            return .idle
        case let .current(state), let .background(_, state):
            return state
        }
    }

    private var importOwnerLabel: String? {
        guard case let .background(ownerLabel, _) = importPresentation else {
            return nil
        }
        return ownerLabel
    }

    var body: some View {
        // The native document owns scrolling and needs the complete section's
        // height. A lazy stack here would estimate offscreen attachment sizes.
        VStack(alignment: .leading, spacing: 9) {
            // Recovery lives on the card itself (NOTES-011) so an attachment
            // placed inline offers the same choices as one waiting here.
            ForEach(attachments) { attachment in
                NoteMovableAttachmentCard(noteStore: noteStore, noteDraft: noteDraft, attachment: attachment)
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
        .animation(reduceMotion ? nil : AtticMotion.quick, value: attachments.map(\.id))
        .animation(reduceMotion ? nil : AtticMotion.quick, value: importPresentation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note attachments")
    }

    @ViewBuilder
    private var importStatus: some View {
        switch importState {
        case .idle:
            EmptyView()
        case let .importing(completed, total):
            let progressLabel = importProgressLabel(
                completed: completed,
                total: total,
                ownerLabel: importOwnerLabel
            )
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text(progressLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                Spacer(minLength: 4)
                Button(action: onCancelImport) {
                    Image(systemName: "xmark.circle")
                        .atticClearGlassForegroundReadability()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help(cancelImportHelp)
                .accessibilityLabel(cancelImportHelp)
                .accessibilityIdentifier("cancel-note-attachment-import")
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(progressLabel)
        case let .failed(message):
            // Quiet and bounded rather than a sticky red block: the glyph
            // carries the meaning and the panel keeps its glass language.
            Label(importFailureLabel(message), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.primaryForegroundColor)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .atticGlassControl(
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    interactive: false
                )
                .accessibilityIdentifier("note-attachment-import-error")
        }
    }

    private func importProgressLabel(
        completed: Int,
        total: Int,
        ownerLabel: String?
    ) -> String {
        let count = max(total, 1)
        let progress = count == 1
            ? "Importing attachment"
            : "Importing attachments \(min(completed, count)) of \(count)"
        guard let ownerLabel else { return progress }
        return "\(progress) for \(ownerLabel)"
    }

    private var cancelImportHelp: String {
        guard let importOwnerLabel else { return "Cancel attachment import" }
        return "Cancel attachment import for \(importOwnerLabel)"
    }

    private func importFailureLabel(_ message: String) -> String {
        guard let importOwnerLabel else { return message }
        return "Attachment import for \(importOwnerLabel) failed: \(message)"
    }
}

private struct NoteImageAttachmentCard: View {
    @Environment(\.atticPanelThemePalette) private var palette
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
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                Text(attachment.originalFilename)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .atticClearGlassForegroundReadability()
                Spacer(minLength: 4)
                Text(fileSize)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(palette.secondaryForegroundColor)
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
        Button("Retry Preview", systemImage: "arrow.clockwise") { noteStore.retryAttachment(attachment) }
        Button("Locate Original…", systemImage: "folder.badge.questionmark") {
            NoteAttachmentActions.locate(store: noteStore, attachment: attachment)
        }
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

struct NoteFileAttachmentCard: View {
    @Environment(\.atticPanelThemePalette) private var palette
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @Binding var selectedAttachmentID: UUID?
    /// Owned by the enclosing card so dismissing the line also releases the
    /// height that line reserved.
    @Binding var dismissedRecoveryMessage: String?

    var placementActions = AnyView(EmptyView())

    @State private var isHovering = false
    @State private var isConfirmingRemoval = false
    @FocusState private var isFocused: Bool

    private var isSelected: Bool {
        selectedAttachmentID == attachment.id || isFocused
    }

    private var failureMessage: String? {
        noteStore.attachmentFailures[attachment.id]
    }

    /// A new failure re-opens the line; dismissing only silences the message
    /// the reader already read.
    private var recoveryMessage: String? {
        guard let failureMessage, failureMessage != dismissedRecoveryMessage else { return nil }
        return failureMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardRow
            recoveryRow
        }
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("note-attachment-\(attachment.id.uuidString)")
        .accessibilityActions {
            if failureMessage != nil {
                Button("Retry", action: retry)
                Button("Locate Original", action: locate)
            }
            Button("Quick Look", action: preview)
            Button("Open", action: open)
                .disabled(!NoteAttachmentActions.isSafeToOpen(attachment))
            Button("Reveal in Finder", action: reveal)
            Button("Export Copy", action: export)
            Button("Remove Attachment", action: remove)
        }
    }

    private var cardRow: some View {
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
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(palette.secondaryForegroundColor)
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
    }

    private var accessibilityLabel: String {
        guard let failureMessage else { return "\(attachment.originalFilename), \(metadata)" }
        return "\(attachment.originalFilename), \(metadata), needs attention: \(failureMessage)"
    }

    /// A quiet single line rather than a sticky red block: the attachment is
    /// still listed, and the same choices stay in the context menu and the
    /// accessibility rotor after the line is dismissed (NOTES-011).
    @ViewBuilder
    private var recoveryRow: some View {
        if let recoveryMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                Text(recoveryMessage)
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                recoveryControl("Retry", symbol: "arrow.clockwise", action: retry)
                recoveryControl("Locate Original", symbol: "folder.badge.questionmark", action: locate)
                recoveryControl("Export Copy", symbol: "square.and.arrow.down", action: export)
                recoveryControl("Remove Attachment", symbol: "trash") { isConfirmingRemoval = true }
                recoveryControl("Dismiss", symbol: "xmark") {
                    dismissedRecoveryMessage = recoveryMessage
                }
            }
            .foregroundStyle(palette.primaryForegroundColor)
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .atticGlassControl(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                interactive: false
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(recoveryMessage)
            .accessibilityIdentifier("attachment-recovery-\(attachment.id.uuidString)")
        }
    }

    private func recoveryControl(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(
            "\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-attachment-\(attachment.id.uuidString)"
        )
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
        if failureMessage != nil {
            Button("Retry", systemImage: "arrow.clockwise", action: retry)
            Button("Locate Original…", systemImage: "folder.badge.questionmark", action: locate)
            Divider()
        }
        placementActions
        Divider()
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

    private func retry() {
        dismissedRecoveryMessage = nil
        noteStore.retryAttachment(attachment)
    }

    private func locate() {
        dismissedRecoveryMessage = nil
        NoteAttachmentActions.locate(store: noteStore, attachment: attachment)
    }
}

struct NoteAttachmentPreviewDemand: Equatable, Hashable {
    var pixelWidth = 0
    var pixelHeight = 0
    var isVisible: Bool { pixelWidth > 0 && pixelHeight > 0 }

    static func resolve(bounds: CGRect, visibleRect: CGRect, scale: CGFloat) -> Self {
        guard bounds.width.isFinite, bounds.height.isFinite, scale.isFinite,
              bounds.width > 0, bounds.height > 0,
              !bounds.intersection(visibleRect).isEmpty else { return Self() }
        // Round into small pixel buckets so live resizing does not restart a
        // request on every point; never request the source image's full size.
        let backingScale = max(1, min(scale, 3))
        return Self(pixelWidth: Int(ceil(bounds.width * backingScale / 64) * 64),
                    pixelHeight: Int(ceil(bounds.height * backingScale / 64) * 64))
    }
}

private struct NoteAttachmentVisibilityReader: NSViewRepresentable {
    let onChange: (NoteAttachmentPreviewDemand) -> Void

    func makeNSView(context: Context) -> NoteAttachmentVisibilityView {
        NoteAttachmentVisibilityView()
    }

    func updateNSView(_ view: NoteAttachmentVisibilityView, context: Context) {
        view.onChange = onChange
        view.refreshVisibility()
    }
}

final class NoteAttachmentVisibilityView: NSView {
    var onChange: ((NoteAttachmentPreviewDemand) -> Void)?
    private(set) var demand = NoteAttachmentPreviewDemand()
    private weak var observedScrollView: NSScrollView?
    private weak var observedWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private var hasPendingDelivery = false

    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshVisibility()
    }
    override func layout() {
        super.layout()
        refreshVisibility()
    }

    func refreshVisibility() {
        let scrollView = enclosingScrollView
        if observedScrollView !== scrollView || observedWindow !== window {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
            observedScrollView = scrollView
            observedWindow = window
            if let scrollView {
                scrollView.contentView.postsBoundsChangedNotifications = true
                for (name, object) in [
                    (NSView.boundsDidChangeNotification, scrollView.contentView as NSView),
                    (NoteEditorDocumentView.layoutDidChange, scrollView.documentView ?? scrollView)
                ] {
                    observations.append(NotificationCenter.default.addObserver(
                        forName: name, object: object, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshVisibility() }
                    })
                }
            }
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification] {
                    observations.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshVisibility() }
                    })
                }
            }
        }
        let documentIsVisible = (scrollView?.documentView as? NoteEditorDocumentView)?.allowsPreviewLoading ?? true
        let windowIsVisible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let next = !windowIsVisible || !documentIsVisible || isHiddenOrHasHiddenAncestor
            ? NoteAttachmentPreviewDemand()
            : NoteAttachmentPreviewDemand.resolve(bounds: bounds, visibleRect: visibleRect,
                                                   scale: window?.backingScaleFactor ?? 2)
        guard next != demand else { return }
        demand = next
        guard !hasPendingDelivery else { return }
        hasPendingDelivery = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingDelivery = false
            self.onChange?(self.demand)
        }
    }
}

struct AttachmentPreviewImage: View {
    @Environment(\.atticPanelThemePalette) private var palette
    enum Presentation {
        case inlineImage
        case fileIcon
    }

    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    let presentation: Presentation
    var displayHeight: CGFloat? = nil

    @State private var image: NSImage?
    @State private var previewDemand = NoteAttachmentPreviewDemand()

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
                    if noteStore.attachmentFailures[attachment.id] != nil {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(palette.secondaryForegroundColor)
                            .atticClearGlassForegroundReadability()
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        // Stable geometry before and after decoding keeps scrolling/caret
        // restoration independent of asynchronous thumbnail completion.
        .frame(height: displayHeight ?? (presentation == .inlineImage ? 250 : 40))
        .background(NoteAttachmentVisibilityReader { previewDemand = $0 })
        .task(id: "\(attachment.id.uuidString)-\(attachment.contentDigest)-\(presentation)-\(noteStore.attachmentRetryVersions[attachment.id, default: 0])-\(previewDemand)") {
            image = nil
            guard previewDemand.isVisible else { return }
            await loadPreview(demand: previewDemand)
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        attachment.contentType.conforms(to: .pdf) ? "doc.richtext" : "doc"
    }

    private func loadPreview(demand: NoteAttachmentPreviewDemand) async {
        if presentation == .fileIcon {
            image = NSWorkspace.shared.icon(for: attachment.contentType)
        }

        guard let url = await noteStore.materializedURL(for: attachment), !Task.isCancelled else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: CGFloat(demand.pixelWidth), height: CGFloat(demand.pixelHeight)),
            scale: 1,
            representationTypes: .all
        )

        do {
            let representation = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            guard !Task.isCancelled else { return }
            if presentation == .inlineImage, representation.type == .icon {
                noteStore.reportAttachmentFailure(attachment.id, message: "This image could not be previewed. Retry, locate the original, or export the saved file.")
            } else {
                image = representation.nsImage
            }
        } catch {
            guard !Task.isCancelled else { return }
            if presentation == .inlineImage {
                noteStore.reportAttachmentFailure(attachment.id, message: "This image could not be previewed. Retry, locate the original, or export the saved file.")
            } else {
                image = NSWorkspace.shared.icon(forFile: url.path)
            }
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
            || pasteboard.availableType(from: [.png, .tiff]) != nil
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

/// One document scroll view keeps text and its attachments in the same flow.
/// Native text layout owns body height; resizing never replaces the editor or
/// publishes geometry through the SwiftUI draft model.
final class NoteDocumentScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? NoteEditorDocumentView)?.layoutDocument(viewport: contentSize)
    }
}

final class NoteEditorDocumentView: NSView {
    static let layoutDidChange = Notification.Name("AtticNoteDocumentLayoutDidChange")
    var allowsPreviewLoading = true {
        didSet {
            if allowsPreviewLoading != oldValue {
                NotificationCenter.default.post(name: Self.layoutDidChange, object: self)
            }
        }
    }
    let textView: AttachmentAcceptingTextView
    let inlineLayout = NoteInlineCardsLayout()
    private let header = NoteDocumentHostingView(rootView: AnyView(EmptyView()))
    private var headerContent = AnyView(EmptyView())
    private var hasHeader = false
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    private let accessories = NoteDocumentHostingView(rootView: AnyView(EmptyView()))
    private var accessoryContent = AnyView(EmptyView())
    private var contentWidth: CGFloat = -1
    private var isLayingOutDocument = false
    private var measuredTextHeight: CGFloat?
    private var hasAccessories = false

    override var isFlipped: Bool { true }

    init(textView: AttachmentAcceptingTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        addSubview(accessories)
        addSubview(header)
        header.sizingOptions = [.intrinsicContentSize]
        header.onSizeInvalidated = { [weak self] in self?.needsLayout = true }
        accessories.sizingOptions = [.intrinsicContentSize]
        accessories.onSizeInvalidated = { [weak self] in
            self?.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { return nil }

    func updateHeader(_ content: AnyView, isPresent: Bool) {
        headerContent = content
        hasHeader = isPresent
        header.isHidden = !isPresent
        updateHeaderWidth(max(1, contentWidth))
        needsLayout = true
    }

    func updateAccessories(_ content: AnyView, isPresent: Bool) {
        accessoryContent = content
        hasAccessories = isPresent
        accessories.isHidden = !isPresent
        updateAccessoryWidth(max(1, contentWidth))
        needsLayout = true
    }

    func invalidateTextLayout() {
        measuredTextHeight = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let scrollView = enclosingScrollView {
            layoutDocument(viewport: scrollView.contentSize)
        }
    }

    func layoutDocument(viewport: NSSize) {
        guard !isLayingOutDocument, viewport.width > 0 else { return }
        isLayingOutDocument = true
        defer { isLayingOutDocument = false }

        if inlineLayout.reserveSpace(in: textView) { measuredTextHeight = nil }
        let width = viewport.width
        if contentWidth != width {
            contentWidth = width
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            updateAccessoryWidth(width)
            updateHeaderWidth(width)
            measuredTextHeight = nil
        }
        // An EmptyView hosting root can still report AppKit's default fitting
        // size. Presence is a document fact, not a measurement inference.
        let accessoryHeight = hasAccessories ? max(0, ceil(accessories.fittingSize.height)) : 0
        let headerHeight = hasHeader ? max(0, ceil(header.fittingSize.height)) : 0
        let topInset = topContentInset.isFinite ? max(0, topContentInset) : 0
        let bottomInset = bottomContentInset.isFinite ? max(0, bottomContentInset) : 0
        let textY = topInset + headerHeight + (hasHeader ? 8 : 0)
        let naturalTextHeight: CGFloat
        if let measuredTextHeight {
            naturalTextHeight = measuredTextHeight
        } else {
            let layoutManager = textView.layoutManager
            if let container = textView.textContainer {
                layoutManager?.ensureLayout(for: container)
                let usedHeight = layoutManager?.usedRect(for: container).maxY ?? 0
                let extraLineHeight = layoutManager?.extraLineFragmentRect.maxY ?? 0
                naturalTextHeight = ceil(max(usedHeight, extraLineHeight)
                    + textView.textContainerInset.height * 2)
            } else {
                naturalTextHeight = 0
            }
            self.measuredTextHeight = naturalTextHeight
        }

        // Empty space belongs to the editor when there are no attachments.
        // Otherwise attachments follow the final text line, not a fixed footer.
        let textHeight = max(naturalTextHeight, hasAccessories ? 24 : max(24, viewport.height - textY - bottomInset))
        let accessoryY = textY + textHeight + (hasAccessories ? 12 : 0)
        let headerFrame = NSRect(x: 0, y: topInset, width: width, height: headerHeight)
        let textFrame = NSRect(x: 0, y: textY, width: width, height: textHeight)
        let accessoryFrame = NSRect(x: 0, y: accessoryY, width: width, height: accessoryHeight)
        let changed = textView.frame != textFrame || accessories.frame != accessoryFrame || header.frame != headerFrame
        if header.frame != headerFrame { header.frame = headerFrame }
        if textView.frame != textFrame { textView.frame = textFrame }
        if accessories.frame != accessoryFrame { accessories.frame = accessoryFrame }
        let documentHeight = max(viewport.height, accessoryY + accessoryHeight + bottomInset)
        if frame.size != NSSize(width: width, height: documentHeight) {
            setFrameSize(NSSize(width: width, height: documentHeight))
        }
        inlineLayout.layout(in: textView)
        if changed { NotificationCenter.default.post(name: Self.layoutDidChange, object: self) }
    }

    private func updateAccessoryWidth(_ width: CGFloat) {
        accessories.rootView = AnyView(accessoryContent
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true))
    }

    private func updateHeaderWidth(_ width: CGFloat) {
        header.rootView = AnyView(headerContent
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true))
    }
}

private final class NoteDocumentHostingView: NSHostingView<AnyView> {
    var onSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeInvalidated?()
    }
}

/// A Cocoa text editor keeps selection, marked text, undo, links, and keyboard
/// behavior native while taking ownership of file drag/paste classification.
struct AttachmentAwareTextEditor: NSViewRepresentable {
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Binding var text: String
    @Binding var isFileTargeted: Bool
    let isFocused: Bool
    let session: NoteEditorSession
    let onFocusChange: (Bool) -> Void
    let onImportFiles: ([URL], [URL]) -> Void
    let onImportError: (String) -> Void
    var initialViewState = NoteEditorViewState()
    var onViewStateChange: (NoteEditorViewState, NoteEditorSession) -> Void = { _, _ in }
    var onViewStateCommit: () -> Void = {}
    var captureImportReceiver: (() -> (([URL], [URL]) -> Void)?)? = nil
    var importUnavailableMessage: (() -> String)? = nil
    var documentAccessories = AnyView(EmptyView())
    var hasDocumentAccessories = false
    var isDocumentVisible = true
    var documentHeader = AnyView(EmptyView())
    var hasDocumentHeader = false
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var inlineCards: [NoteInlineCard] = []
    /// Receives the real text-storage edits so inline anchors rebase from the
    /// delta instead of a whole-document diff (PERF-12).
    var bodyEditLedger: NoteBodyEditLedger? = nil
    var onMoveAttachment: (UUID, Int) -> Bool = { _, _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoteDocumentScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier("note-document-scroll")

        let textView = AttachmentAcceptingTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: AtticStyle.bodyTextSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.registerForDraggedTypes([
            NoteInlineCardsLayout.dragType,
            .png, .tiff,
            .fileURL,
            .URL,
            .string,
            NoteAttachmentPasteboardRouter.legacyFilenamesType,
            NoteAttachmentPasteboardRouter.promisedFileURLType,
            NoteAttachmentPasteboardRouter.promisedFileContentType,
            NoteAttachmentPasteboardRouter.legacyFilePromiseType
        ])
        textView.setAccessibilityIdentifier("note-body")
        textView.setAccessibilityLabel("Note body")
        context.coordinator.textView = textView
        textView.textStorage?.delegate = context.coordinator
        _ = context.coordinator.synchronize(parent: self, textView: textView)
        Self.applyReadability(
            to: textView,
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
        context.coordinator.recordAppliedReadability(
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )

        textView.onImportFiles = { [weak coordinator = context.coordinator] urls, cleanup in
            coordinator?.parent.onImportFiles(urls, cleanup)
        }
        textView.onImportError = { [weak coordinator = context.coordinator] message in
            coordinator?.parent.onImportError(message)
        }
        textView.captureImportReceiver = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return nil }
            if let capture = coordinator.parent.captureImportReceiver { return capture() }
            return coordinator.parent.onImportFiles
        }
        textView.importUnavailableMessage = { [weak coordinator = context.coordinator] in
            coordinator?.parent.importUnavailableMessage?()
                ?? AttachmentAcceptingTextView.busyImportMessage
        }
        textView.onFileTargetingChanged = {
            [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.isFileTargeted = targeted
        }

        textView.onMoveAttachment = { [weak coordinator = context.coordinator] id, offset in
            coordinator?.parent.onMoveAttachment(id, offset) ?? false
        }
        let document = NoteEditorDocumentView(textView: textView)
        document.inlineLayout.update(inlineCards, in: textView)
        document.topContentInset = topContentInset
        document.bottomContentInset = bottomContentInset
        document.updateHeader(AnyView(documentHeader.environment(\.self, context.environment)), isPresent: hasDocumentHeader)
        document.allowsPreviewLoading = isDocumentVisible
        document.updateAccessories(AnyView(documentAccessories.environment(\.self, context.environment)), isPresent: hasDocumentAccessories)
        scrollView.documentView = document
        context.coordinator.observeScrollView(scrollView)
        context.coordinator.restoreScrollPosition(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let document = scrollView.documentView as? NoteEditorDocumentView else {
            return
        }
        let textView = document.textView

        let synchronization = context.coordinator.synchronize(
            parent: self,
            textView: textView
        )
        guard synchronization != .staleSession else { return }
        if document.inlineLayout.update(inlineCards, in: textView) { document.invalidateTextLayout() }
        document.topContentInset = topContentInset
        document.bottomContentInset = bottomContentInset
        document.updateHeader(AnyView(documentHeader.environment(\.self, context.environment)), isPresent: hasDocumentHeader)
        document.allowsPreviewLoading = isDocumentVisible
        document.updateAccessories(AnyView(documentAccessories.environment(\.self, context.environment)), isPresent: hasDocumentAccessories)
        if synchronization == .replacedText { document.invalidateTextLayout() }
        document.layoutDocument(viewport: scrollView.contentSize)
        context.coordinator.captureViewState()
        let replacedExternalText = synchronization == .replacedText

        if !textView.hasMarkedText(), Self.needsReadabilityApplication(
            lastEnabled: context.coordinator.appliedReadabilityEnabled,
            lastColorScheme: context.coordinator.appliedReadabilityColorScheme,
            enabled: clearReadabilityEnabled,
            colorScheme: colorScheme,
            externalTextWasReplaced: replacedExternalText,
            lastIncreasedContrast: context.coordinator.appliedIncreasedContrast,
            increasedContrast: colorSchemeContrast == .increased
        ) {
            context.coordinator.isApplyingExternalText = true
            Self.applyReadability(
                to: textView,
                enabled: clearReadabilityEnabled,
                colorScheme: colorScheme,
                increasedContrast: colorSchemeContrast == .increased
            )
            context.coordinator.isApplyingExternalText = false
            context.coordinator.recordAppliedReadability(
                enabled: clearReadabilityEnabled,
                colorScheme: colorScheme,
                increasedContrast: colorSchemeContrast == .increased
            )
        }

        let expectedSession = session
        if isFocused, textView.window?.firstResponder !== textView {
            context.coordinator.requestFocus(true, for: expectedSession, textView: textView)
        } else if !isFocused, textView.window?.firstResponder === textView {
            context.coordinator.requestFocus(false, for: expectedSession, textView: textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.captureViewState()
        coordinator.parent.onViewStateCommit()
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.textView?.delegate = nil
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
        colorScheme: ColorScheme,
        increasedContrast: Bool = false
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
            let opacity = AtticClearGlassReadabilityPolicy.edgeOpacity(increasedContrast: increasedContrast)
            shadow.shadowColor = colorScheme == .dark
                ? NSColor.black.withAlphaComponent(opacity)
                : NSColor.white.withAlphaComponent(opacity)
            shadow.shadowBlurRadius = AtticClearGlassReadabilityPolicy.edgeRadius
            shadow.shadowOffset = .zero
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
        externalTextWasReplaced: Bool,
        lastIncreasedContrast: Bool = false,
        increasedContrast: Bool = false
    ) -> Bool {
        externalTextWasReplaced
            || lastEnabled != enabled
            || lastColorScheme != colorScheme
            || lastIncreasedContrast != increasedContrast
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
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
        var appliedIncreasedContrast = false
        private var appliedSession: NoteEditorSession?
        private var lastSynchronizedText: String?
        /// The character edits applied since the last published body, kept in
        /// order so unchanged text between them is never folded into a
        /// replaced span.
        private var pendingStorageEdits: [NoteTextReplacement] = []
        /// Proposed text-view changes arrive before NSTextStorage coalesces a
        /// grouped transaction into one union range. Prefer these exact edits.
        private struct ProposedTextEdit {
            let range: NSRange
            let replacement: String

            var replacementShape: NoteTextReplacement {
                NoteTextReplacement(
                    location: range.location,
                    oldLength: range.length,
                    newLength: replacement.utf16.count
                )
            }
        }
        private var pendingProposedEdits: [ProposedTextEdit] = []
        private var pendingScrollRestore = false
        private var scrollObservation: NSObjectProtocol?

        init(parent: AttachmentAwareTextEditor) {
            self.parent = parent
        }

        deinit {
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        }

        func observeScrollView(_ scrollView: NSScrollView) {
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in self?.captureViewState() }
        }

        func recordAppliedReadability(enabled: Bool, colorScheme: ColorScheme, increasedContrast: Bool = false) {
            appliedReadabilityEnabled = enabled
            appliedReadabilityColorScheme = colorScheme
            appliedIncreasedContrast = increasedContrast
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
                captureViewState()
                pendingScrollRestore = true
                isApplyingExternalText = true
                if textView.hasMarkedText() {
                    textView.unmarkText()
                }
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }

            parent = newParent
            appliedSession = newParent.session

            // Selection/layout notifications can publish SwiftUI state in
            // the middle of an AppKit deletion, before textDidChange writes
            // the binding. That old model value must not resurrect the text.
            if !startsNewSession, let lastSynchronizedText,
               NoteTextReplacement.utf16Equal(newParent.text, lastSynchronizedText),
               !NoteTextReplacement.utf16Equal(textView.string, lastSynchronizedText) {
                isApplyingExternalText = false
                return .unchanged
            }
            lastSynchronizedText = newParent.text

            guard !NoteTextReplacement.utf16Equal(textView.string, newParent.text),
                  startsNewSession || !textView.hasMarkedText() else {
                isApplyingExternalText = false
                if startsNewSession { applyInitialSelection(to: textView) }
                return .unchanged
            }

            let selectedRanges = textView.selectedRanges
            isApplyingExternalText = true
            do {
                let undoManager = textView.undoManager
                undoManager?.disableUndoRegistration()
                defer { undoManager?.enableUndoRegistration() }

                textView.string = newParent.text
                textView.selectedRanges = AttachmentAwareTextEditor.clamped(
                    selectedRanges,
                    length: (newParent.text as NSString).length
                )
            }
            // An external replacement is not a typed edit. Drop the recorded
            // edits so the next rebase re-diffs instead of trusting them.
            pendingStorageEdits = []
            pendingProposedEdits = []
            if startsNewSession {
                parent.bodyEditLedger?.reset(to: newParent.text)
            } else {
                parent.bodyEditLedger?.invalidate()
            }
            if startsNewSession {
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
                applyInitialSelection(to: textView)
            }
            isApplyingExternalText = false
            return .replacedText
        }

        private func applyInitialSelection(to textView: NSTextView) {
            let state = parent.initialViewState
            textView.selectedRanges = AttachmentAwareTextEditor.clamped(
                [NSValue(range: NSRange(location: max(0, state.selectionLocation), length: max(0, state.selectionLength)))],
                length: (textView.string as NSString).length
            )
            if let scrollView = textView.enclosingScrollView { restoreScrollPosition(in: scrollView) }
        }

        func restoreScrollPosition(in scrollView: NSScrollView) {
            guard pendingScrollRestore else { return }
            pendingScrollRestore = false
            let session = parent.session
            let y = parent.initialViewState.scrollY
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, self.isCurrent(session), let scrollView else { return }
                (scrollView.documentView as? NoteEditorDocumentView)?.layoutDocument(viewport: scrollView.contentSize)
                let maximum = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, CGFloat(y.isFinite ? y : 0)), maximum)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func captureViewState() {
            guard !isApplyingExternalText, let textView, appliedSession != nil else { return }
            let selection = textView.selectedRange()
            parent.onViewStateChange(NoteEditorViewState(
                selectionLocation: selection.location == NSNotFound ? 0 : selection.location,
                selectionLength: selection.length,
                scrollY: Double(textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
            ), parent.session)
        }

        func isCurrent(_ session: NoteEditorSession) -> Bool {
            appliedSession == session
        }

        func requestFocus(_ focused: Bool, for session: NoteEditorSession, textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.isCurrent(session), self.parent.isFocused == focused,
                      let textView, let window = textView.window else { return }
                if focused {
                    window.makeFirstResponder(textView)
                } else if window.firstResponder === textView {
                    window.makeFirstResponder(nil)
                }
            }
        }

        /// `NSTextStorage` reports the exact span it replaced. Recording each
        /// edit in order is what lets inline anchors rebase in O(edit) instead
        /// of O(document) per card (PERF-12). Attribute-only edits —
        /// readability shadows and reserved paragraph spacing — never move an
        /// anchor.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isApplyingExternalText, editedMask.contains(.editedCharacters) else { return }
            pendingStorageEdits.append(NoteTextReplacement(
                location: editedRange.location,
                oldLength: editedRange.length - delta,
                newLength: editedRange.length
            ))
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard !isApplyingExternalText,
                  let replacementStrings,
                  replacementStrings.count == affectedRanges.count else { return true }
            // Ranges are coordinates in the same pre-edit body. Applying from
            // the end keeps every later coordinate valid and matches AppKit's
            // multi-range replacement semantics.
            pendingProposedEdits.append(contentsOf: zip(affectedRanges, replacementStrings)
                .map { value, replacement in
                    ProposedTextEdit(range: value.rangeValue, replacement: replacement)
                }
                .sorted { $0.range.location > $1.range.location })
            return true
        }

        private func proposedEditsProduce(_ updated: String) -> Bool {
            guard !pendingProposedEdits.isEmpty else { return false }
            let value = NSMutableString(string: parent.text)
            for edit in pendingProposedEdits {
                guard edit.range.location <= value.length,
                      edit.range.length <= value.length - edit.range.location else { return false }
                value.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            return NoteTextReplacement.utf16Equal(value as String, updated)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }
            let updated = textView.string
            let exactEdits = proposedEditsProduce(updated)
                ? pendingProposedEdits.map(\.replacementShape)
                : pendingStorageEdits
            if !exactEdits.isEmpty {
                parent.bodyEditLedger?.record(exactEdits, resulting: updated)
            } else {
                parent.bodyEditLedger?.invalidate()
            }
            pendingStorageEdits = []
            pendingProposedEdits = []
            parent.text = updated
            if let document = textView.superview as? NoteEditorDocumentView,
               let scrollView = textView.enclosingScrollView {
                document.invalidateTextLayout()
                document.layoutDocument(viewport: scrollView.contentSize)
            }
            captureViewState()
        }

        func textViewDidChangeSelection(_ notification: Notification) { captureViewState() }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            captureViewState()
            parent.onViewStateCommit()
            parent.onFocusChange(false)
        }
    }
}

final class AttachmentAcceptingTextView: NSTextView {
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let document = superview as? NoteEditorDocumentView,
              let scrollView = enclosingScrollView,
              let manager = layoutManager, let container = textContainer,
              range.location != NSNotFound else { return }
        document.invalidateTextLayout()
        document.layoutDocument(viewport: scrollView.contentSize)
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: (string as NSString).length))
        let glyphs = manager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        if rect.isEmpty {
            rect = manager.extraLineFragmentRect
            if rect.isEmpty, manager.numberOfGlyphs > 0 {
                rect = manager.lineFragmentRect(forGlyphAt: min(glyphs.location, manager.numberOfGlyphs - 1),
                                                effectiveRange: nil)
            }
        }
        guard rect.height > 0 else { return }
        rect = convert(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), to: document)
        // Inset the *requested visible area*, not the clip view. Wheel scrolling
        // can still pass underneath chrome, while caret navigation avoids it.
        let top = max(0, document.topContentInset)
        let bottom = max(0, document.bottomContentInset)
        guard rect.height + top + bottom < scrollView.contentSize.height else { return }
        rect.origin.y -= top
        rect.size.height += top + bottom
        _ = document.scrollToVisible(rect)
    }

    var onImportFiles: (([URL], [URL]) -> Void)?
    var onImportError: ((String) -> Void)?
    var onFileTargetingChanged: ((Bool) -> Void)?
    var captureImportReceiver: (() -> (([URL], [URL]) -> Void)?)?
    /// Why a capture failed, in the composer's words. Nil falls back to the
    /// busy message the URL-import path already uses.
    var importUnavailableMessage: (() -> String)?
    private var activePromiseBatches: [UUID: PromisedFileBatch] = [:]

    static let busyImportMessage =
        "Finish or cancel the current attachment import before adding more files."

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

    var onMoveAttachment: (UUID, Int) -> Bool = { _, _ in false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [NoteInlineCardsLayout.dragType]) != nil { return .move }
        guard NoteAttachmentPasteboardRouter.prefersAttachments(
            sender.draggingPasteboard
        ) else {
            return super.draggingEntered(sender)
        }
        onFileTargetingChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [NoteInlineCardsLayout.dragType]) != nil {
            if let event = NSApp.currentEvent { autoscroll(with: event) }
            return .move
        }
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
        if sender.draggingPasteboard.availableType(from: [NoteInlineCardsLayout.dragType]) != nil { return true }
        if NoteAttachmentPasteboardRouter.prefersAttachments(
            sender.draggingPasteboard
        ) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileTargetingChanged?(false)
        if let value = sender.draggingPasteboard.string(forType: NoteInlineCardsLayout.dragType), let id = UUID(uuidString: value) {
            let point = convert(sender.draggingLocation, from: nil)
            let offset = characterIndexForInsertion(at: point)
            return onMoveAttachment(id, NoteInlineAnchor.paragraphStart(offset, in: string))
        }
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

    /// Capturing the logical owner fails while another import is in flight or
    /// while the draft cannot flush. Reporting that is not optional: a paste or
    /// drop that silently does nothing is indistinguishable from data loss
    /// (DATA-003). The URL-import path already reports the same message.
    private func captureReportingFileImportReceiver() -> (([URL], [URL]) -> Void)? {
        if let receiver = captureFileImportReceiver() { return receiver }
        onImportError?(importUnavailableMessage?() ?? Self.busyImportMessage)
        return nil
    }

    /// Internal so the paste/drop contract can be tested without the general
    /// pasteboard or a live editor.
    @discardableResult
    func handleAttachmentPasteboard(_ pasteboard: NSPasteboard) -> Bool {
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
        for (type, suffix) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= AttachmentLimits.maxBytesPerAttachment else {
                onImportError?("This image exceeds the 15 MB attachment limit.")
                return true
            }
            guard let receiver = captureReportingFileImportReceiver() else { return true }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtticNotePaste-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Pasted image.\(suffix)")
                try data.write(to: url, options: .atomic)
                receiver([url], [directory])
            } catch {
                try? FileManager.default.removeItem(at: directory)
                onImportError?("Unable to attach the pasted image: \(error.localizedDescription)")
            }
            return true
        }
        return false
    }

    private func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver]) {
        guard let receive = captureReportingFileImportReceiver() else { return }
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
                    receive(urls, [destination])
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

    func captureFileImportReceiver() -> (([URL], [URL]) -> Void)? {
        if let captureImportReceiver {
            return captureImportReceiver()
        }
        return onImportFiles
    }
}

final class PromisedFileBatch: @unchecked Sendable {
    enum Result {
        case success([URL])
        case failure(String)
    }

    private enum TerminalState: Equatable {
        case active
        case succeeded
        case failed
    }

    private let lock = NSLock()
    private let expectedCount: Int
    private let destination: URL
    private let completion: (Result) -> Void
    private var completedIndices = Set<Int>()
    private var delivered: [(Int, URL)] = []
    private var errors: [String] = []
    private var terminalState = TerminalState.active
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
        guard terminalState == .active else {
            let shouldCleanLateDelivery = terminalState == .failed
            lock.unlock()
            if shouldCleanLateDelivery {
                removeFailedBatchDestination()
            }
            return
        }
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
                terminalState = .succeeded
                result = .success(delivered.sorted { $0.0 < $1.0 }.map(\.1))
            } else {
                terminalState = .failed
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
                removeFailedBatchDestination()
            }
            completion(result)
        }
    }

    func cancel() {
        finishWithFailure("Unable to receive a promised file: the operation was cancelled.")
    }

    private func finishWithFailure(_ message: String) {
        lock.lock()
        guard terminalState == .active else {
            lock.unlock()
            return
        }
        terminalState = .failed
        lock.unlock()

        timeoutWorkItem?.cancel()
        removeFailedBatchDestination()
        completion(.failure(message))
    }

    private func removeFailedBatchDestination() {
        // The destination is a unique temporary directory owned by this batch.
        // Providers may recreate it after timeout/cancellation, so every late
        // callback repeats the idempotent cleanup.
        try? FileManager.default.removeItem(at: destination)
    }
}
