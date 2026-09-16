import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskImageThumbnail: View {
    let reference: TaskImageReference
    let files: TaskImageFiles
    var pixels = 96
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: reference.digest) {
            let data = try? await files.thumbnail(reference, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
        .accessibilityLabel(reference.filename)
    }
}

/// A small square preview for passive row metadata: the image thumbnail, or
/// the file type's system icon.
struct TaskAttachmentGlyph: View {
    let reference: TaskImageReference
    let files: TaskImageFiles

    var body: some View {
        if reference.isImage {
            TaskImageThumbnail(reference: reference, files: files)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                Image(nsImage: NSWorkspace.shared.icon(for: reference.contentType))
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
        }
    }
}

/// The one Add attachment picker: images and general files together. The
/// owner is marked while the picker is up, so the owning panel and the main
/// panel stay open underneath it.
@MainActor
enum TaskAttachmentPicker {
    /// True while any Add attachment picker (a task's or the main composer's)
    /// is up: one picker at a time.
    static func isPresenting(_ uiState: PanelUIState) -> Bool {
        uiState.taskAttachmentPickerOwnerID != nil || uiState.isComposerAttachmentPickerPresented
    }

    /// Every Add attachment affordance is disabled exactly when this is
    /// false, so `choose` never ignores a click the UI offered. One picker at
    /// a time; a child's attachments popover does not block it.
    static func isAvailable(for taskID: UUID, store: TaskStore, uiState: PanelUIState) -> Bool {
        guard let ownerID = store.attachmentOwnerID(for: taskID) else { return false }
        return !isPresenting(uiState)
            && !store.importingAttachmentTaskIDs.contains(ownerID)
    }

    static func choose(for taskID: UUID, store: TaskStore, uiState: PanelUIState,
                       attached: @escaping @MainActor ([UUID], UUID) -> Void) {
        guard isAvailable(for: taskID, store: store, uiState: uiState),
              let ownerID = store.attachmentOwnerID(for: taskID) else { return }
        uiState.taskAttachmentPickerOwnerID = ownerID
        TaskAttachmentPickerSession.present(owner: ownerID) { urls in
            if uiState.taskAttachmentPickerOwnerID == ownerID {
                uiState.taskAttachmentPickerOwnerID = nil
            }
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                if let ids = await store.attachStagedFiles(to: ownerID, stage: { TaskAttachmentStaging(urls: urls) }) {
                    attached(ids, ownerID)
                }
            }
        }
    }

    /// The main composer's picker: files are imported as pending attachments
    /// of the task being written.
    static func chooseForComposer(uiState: PanelUIState, picked: @escaping @MainActor ([URL]) -> Void) {
        guard !isPresenting(uiState) else { return }
        uiState.isComposerAttachmentPickerPresented = true
        TaskAttachmentPickerSession.present(owner: nil) { urls in
            uiState.isComposerAttachmentPickerPresented = false
            if !urls.isEmpty { picked(urls) }
        }
    }

    /// Ends a picker whose owner no longer exists (deleted task) or whose
    /// host is being torn down, as a cancel. Every mark clears through the
    /// session's single finish path.
    static func cancelIfOwned(by ownerID: UUID?) {
        TaskAttachmentPickerSession.cancel(owner: ownerID)
    }

    /// Test seam: whether a picker session is currently up.
    static var isSessionActiveForTesting: Bool { TaskAttachmentPickerSession.current != nil }
}

/// One presented `NSOpenPanel` with exactly one way to finish. OK, cancel,
/// the window closing behind our back, a presentation that never became
/// visible, a panel stranded off every screen, and an owner teardown all
/// converge on `finish`, which runs the completion once and clears the
/// owner marks through it — so no path can strand every Add-attachment
/// affordance disabled (the TP-005 deadlock).
@MainActor
final class TaskAttachmentPickerSession {
    private(set) static var current: TaskAttachmentPickerSession?

    /// The panel floats above Attic's own panels rather than relying on
    /// activation, which macOS may decline for a background accessory app:
    /// a picker that opens behind the foreground app is the other half of
    /// the reported deadlock.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
    /// How long a presented panel gets to become visible on a screen before
    /// it is re-centered (still hidden: the presentation failed and finishes).
    static let presentationCheckDelay: TimeInterval = 0.4

    let owner: UUID?
    private let panel: NSOpenPanel
    private var completion: (@MainActor ([URL]) -> Void)?
    private var closeObservation: NSObjectProtocol?
    private var screenObservation: NSObjectProtocol?

    /// Test seam: the session's panel.
    var panelForTesting: NSOpenPanel { panel }
    var isFinished: Bool { completion == nil }

    static func present(owner: UUID?, completion: @escaping @MainActor ([URL]) -> Void) {
        // One at a time by construction: the marks refuse a second picker,
        // and a stale session that somehow survived is cancelled first.
        current?.finish(urls: [])
        let session = TaskAttachmentPickerSession(owner: owner, completion: completion)
        current = session
        session.begin()
    }

    static func cancel(owner: UUID?) {
        guard let current, current.owner == owner else { return }
        current.finish(urls: [])
    }

    private init(owner: UUID?, completion: @escaping @MainActor ([URL]) -> Void) {
        self.owner = owner
        self.completion = completion
        panel = NSOpenPanel()
        panel.title = "Add Attachment"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    private func begin() {
        let center = NotificationCenter.default
        closeObservation = center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) {
            [weak self] _ in
            // Closed by any route other than its own buttons (Escape handled
            // by AppKit, a programmatic close, a lost owner): cancel.
            MainActor.assumeIsolated { self?.finish(urls: []) }
        }
        screenObservation = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureReachable(finishIfHidden: false) }
        }
        // Attic is a background accessory: without real activation the
        // picker orders in above other apps (its level) but keyboard focus
        // stays with the foreground app, so path entry and Escape never
        // reach it. Cooperative activation may be declined; this form is
        // the one that reliably brings the process forward for its dialog.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finish(urls: response == .OK ? self.panel.urls : [])
            }
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentationCheckDelay) { [weak self] in
            self?.ensureReachable(finishIfHidden: true)
        }
    }

    /// A visible panel is kept on a connected screen; one that never became
    /// visible is a failed presentation and finishes as a cancel.
    func ensureReachable(finishIfHidden: Bool) {
        guard !isFinished else { return }
        guard panel.isVisible else {
            if finishIfHidden { finish(urls: []) }
            return
        }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen {
            panel.center()
        }
        panel.level = Self.windowLevel
        panel.makeKeyAndOrderFront(nil)
    }

    /// The single exit. Idempotent: the first caller wins, later ones are
    /// no-ops, and the completion runs exactly once.
    func finish(urls: [URL]) {
        guard let completion else { return }
        self.completion = nil
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        closeObservation = nil
        screenObservation = nil
        if Self.current === self { Self.current = nil }
        if panel.isVisible {
            // Ordering out after `finish` never re-enters: the observer is gone.
            panel.orderOut(nil)
        }
        completion(urls)
    }
}

/// Quick Look previews the verified private copy; Open hands another app a
/// disposable read-only copy, so no editor can save over the private file.
@MainActor
enum TaskAttachmentActions {
    static func preview(_ reference: TaskImageReference, store: TaskStore, owner: UUID? = nil) {
        Task {
            guard let url = await verifiedURL(reference, store: store, owner: owner) else { return }
            AttachmentQuickLookPresenter.shared.present(url)
        }
    }

    static func open(_ reference: TaskImageReference, store: TaskStore, owner: UUID? = nil) {
        guard canOpen(reference) else { return }
        Task {
            do {
                guard let url = try await store.taskImageFiles.openableCopy(for: reference) else {
                    store.reportUnavailableAttachment(named: reference.filename, owner: owner)
                    return
                }
                NSWorkspace.shared.open(url)
            } catch {
                store.reportAttachmentOpenFailure(named: reference.filename, error: error, owner: owner)
            }
        }
    }

    static func canOpen(_ reference: TaskImageReference) -> Bool {
        NoteAttachmentActions.isSafeToOpen(contentTypeIdentifier: reference.contentTypeIdentifier)
    }

    private static func verifiedURL(_ reference: TaskImageReference, store: TaskStore, owner: UUID?) async -> URL? {
        if let url = try? await store.taskImageFiles.verifiedURL(for: reference) { return url }
        store.reportUnavailableAttachment(named: reference.filename, owner: owner)
        return nil
    }
}

/// Compact two-column gallery of image thumbnails and file cards. Its height
/// is `SubtaskPanelLayout.galleryContentHeight`, so the panel can size to it
/// before it renders.
struct TaskAttachmentGallery: View {
    let attachments: [TaskImageReference]
    let store: TaskStore
    /// The family whose panel hosts the gallery; its errors show there.
    var owner: UUID? = nil
    /// Just-imported cards that play an entrance when the gallery appears
    /// for them (a gallery already on screen animates insertions instead).
    var freshIDs: Set<UUID> = []
    let remove: (TaskImageReference) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atticPanelThemePalette) private var palette

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SubtaskPanelLayout.gallerySpacing, alignment: .top),
              count: SubtaskPanelLayout.galleryColumns)
    }

    var body: some View {
        if attachments.isEmpty {
            Text("No attachments yet")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(palette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
                .frame(maxWidth: .infinity)
                .frame(height: SubtaskPanelLayout.galleryEmptyHeight)
        } else {
            LazyVGrid(columns: columns, spacing: SubtaskPanelLayout.gallerySpacing) {
                ForEach(attachments) { reference in
                    TaskAttachmentCard(reference: reference, store: store, owner: owner,
                                       entranceDelay: entranceDelay(for: reference)) { remove(reference) }
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .padding(.vertical, SubtaskPanelLayout.galleryVerticalPadding)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: attachments.map(\.id))
        }
    }

    /// nil for cards that are already settled; fresh cards enter in order.
    private func entranceDelay(for reference: TaskImageReference) -> TimeInterval? {
        guard freshIDs.contains(reference.id) else { return nil }
        let order = attachments.filter { freshIDs.contains($0.id) }.firstIndex { $0.id == reference.id } ?? 0
        return SubtaskPanelLayout.freshAttachmentEntranceDelay
            + SubtaskPanelLayout.freshAttachmentStagger * Double(min(order, 8))
    }
}

/// One attachment: a click or Space/Return previews it, Delete removes it, and
/// it drags out as its file. A small remove × appears on hover or focus.
struct TaskAttachmentCard: View {
    let reference: TaskImageReference
    let store: TaskStore
    let owner: UUID?
    let remove: () -> Void
    private let entranceDelay: TimeInterval?

    /// Captured when the card is created: a fresh card starts hidden and
    /// plays its entrance once, whatever later happens to its fresh mark.
    @State private var hasEntered: Bool
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.atticPanelThemePalette) private var palette
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(reference: TaskImageReference, store: TaskStore, owner: UUID? = nil,
         entranceDelay: TimeInterval? = nil, remove: @escaping () -> Void) {
        self.reference = reference
        self.store = store
        self.owner = owner
        self.remove = remove
        self.entranceDelay = entranceDelay
        _hasEntered = State(initialValue: entranceDelay == nil)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    private var showsRemove: Bool { isHovering || isFocused }
    private var size: String { ByteCountFormatter.string(fromByteCount: reference.byteCount, countStyle: .file) }

    var body: some View {
        interactive(cardSurface)
            .contextMenu { actions }
            .help(reference.filename)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reference.filename), \(reference.isImage ? "image" : "file"), \(size)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows a Quick Look preview")
            .accessibilityAction(.default, preview)
            .accessibilityActions {
                // Offered only where Open can act; other types preview.
                if TaskAttachmentActions.canOpen(reference) { Button("Open", action: open) }
                Button("Remove", action: remove)
            }
            .accessibilityIdentifier("task-attachment-\(reference.id.uuidString)")
            // Visual only: layout is final from the start, so the panel's
            // height never waits on the entrance.
            .scaleEffect(hasEntered || reduceMotion ? 1 : 0.9)
            .opacity(hasEntered ? 1 : 0)
            .onAppear(perform: playEntrance)
    }

    private func playEntrance() {
        guard !hasEntered else { return }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.34, dampingFraction: 0.82).delay(entranceDelay ?? 0)
        withAnimation(animation) { hasEntered = true }
    }

    private func interactive(_ content: some View) -> some View {
        content
            .contentShape(shape)
            // Keyboard focus like a button: reachable with Full Keyboard
            // Access, while a pointer click previews without taking focus.
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($isFocused)
            .onTapGesture(perform: preview)
            .onKeyPress(.space) { preview(); return .handled }
            .onKeyPress(.return) { preview(); return .handled }
            .onDeleteCommand(perform: remove)
            .onHover { isHovering = $0 }
            .onDrag {
                // Drop targets route the card by this record: other tasks copy
                // it, its own owner refuses it.
                MainActor.assumeIsolated { TaskAttachmentCardDrag.begin(reference, store: store) }
                return TaskAttachmentDragItem(reference: reference, files: store.taskImageFiles).itemProvider()
            } preview: {
                dragPreview
            }
    }

    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 4) {
            previewArea
                .frame(maxWidth: .infinity)
                .frame(height: SubtaskPanelLayout.galleryPreviewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            caption
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SubtaskPanelLayout.galleryCardHeight, alignment: .top)
        .background(Color.primary.opacity(showsRemove ? 0.075 : 0.04), in: shape)
        .overlay { shape.strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 0.5) }
        .overlay(alignment: .topTrailing) {
            if showsRemove { removeButton }
        }
    }

    private var borderColor: Color {
        if isFocused { return Color.accentColor.opacity(0.8) }
        return Color.primary.opacity(colorSchemeContrast == .increased ? 0.25 : 0.06)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(reference.filename)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.primaryForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(size)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(palette.secondaryForegroundColor)
                .lineLimit(1)
        }
        .atticClearGlassForegroundReadability()
        .padding(.horizontal, 2)
    }

    private var dragPreview: some View {
        Label(reference.filename, systemImage: reference.isImage ? "photo" : "doc")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder
    private var previewArea: some View {
        if reference.isImage {
            TaskImageThumbnail(reference: reference, files: store.taskImageFiles, pixels: 256)
        } else {
            ZStack {
                Color.primary.opacity(0.05)
                Image(nsImage: NSWorkspace.shared.icon(for: reference.contentType))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
            }
        }
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.9))
                .frame(width: 18, height: 18)
                .atticGlassControl(in: Circle())
                // Compact glyph, comfortable pointer target.
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Keyboard users remove with Delete or the Remove action; a focusable
        // × would take focus from the card and hide itself.
        .focusable(false)
        .padding(1)
        .help("Remove \(reference.filename)")
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Quick Look", systemImage: "eye", action: preview)
        Button("Open", systemImage: "arrow.up.forward.square", action: open)
            .disabled(!TaskAttachmentActions.canOpen(reference))
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive, action: remove)
    }

    private func preview() { TaskAttachmentActions.preview(reference, store: store, owner: owner) }
    private func open() { TaskAttachmentActions.open(reference, store: store, owner: owner) }
}

/// Attachments that an older build stored on a subtask. New attachments go to
/// the parent; these stay viewable, draggable and removable where they live.
struct TaskAttachmentsPopover: View {
    @ObservedObject var store: TaskStore
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attachments").font(.headline)
            ScrollView {
                TaskAttachmentGallery(attachments: task.attachments, store: store) { reference in
                    store.removeAttachment(reference.id, from: task.id)
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 270)
    }
}
