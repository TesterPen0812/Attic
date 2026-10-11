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

    /// Ends a picker whose owner no longer exists (deleted task) or whose
    /// host is being torn down, as a cancel. Every mark clears through the
    /// session's single finish path.
    static func cancelIfOwned(by ownerID: UUID?) {
        TaskAttachmentPickerSession.cancel(owner: ownerID)
    }

    /// Test seam: whether a picker session is currently up.
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
    private weak var ownerWindow: NSWindow?
    private var completion: (@MainActor ([URL]) -> Void)?
    private var closeObservation: NSObjectProtocol?
    private var screenObservation: NSObjectProtocol?

    /// Test seam: the session's panel.
    var panelForTesting: NSOpenPanel { panel }
    var isFinished: Bool { completion == nil }

    static func present(owner: UUID?, parentWindow: NSWindow? = nil, allowedTypes: [UTType] = [.data],
                        allowsMultipleSelection: Bool = true, completion: @escaping @MainActor ([URL]) -> Void) {
        // One at a time by construction: the marks refuse a second picker,
        // and a stale session that somehow survived is cancelled first.
        current?.finish(urls: [])
        let session = TaskAttachmentPickerSession(owner: owner, parentWindow: parentWindow, allowedTypes: allowedTypes,
                                                  allowsMultipleSelection: allowsMultipleSelection, completion: completion)
        current = session
        session.begin()
    }

    static func cancel(owner: UUID?) {
        guard let current, current.owner == owner else { return }
        current.finish(urls: [])
    }

    private init(owner: UUID?, parentWindow: NSWindow?, allowedTypes: [UTType], allowsMultipleSelection: Bool,
                 completion: @escaping @MainActor ([URL]) -> Void) {
        self.owner = owner
        self.completion = completion
        ownerWindow = parentWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        panel = NSOpenPanel()
        panel.title = "Add Attachment"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedTypes
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
        positionBesideOwner()
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
        positionBesideOwner()
        panel.level = Self.windowLevel
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionBesideOwner() {
        guard let ownerWindow, let screen = ownerWindow.screen ?? NSScreen.main,
              let frame = Self.placement(size: panel.frame.size, beside: ownerWindow.frame, in: screen.visibleFrame) else { return }
        panel.setFrame(frame, display: panel.isVisible)
    }

    /// Detached from the utility panel so AppKit cannot resize or reanchor
    /// its owner to accommodate a sheet. Prefer an unchanged picker size;
    /// on narrower displays, fit the largest adjacent usable rectangle.
    static func placement(size: CGSize, beside owner: CGRect, in screen: CGRect) -> CGRect? {
        let gap: CGFloat = 12
        let areas = [
            CGRect(x: screen.minX, y: screen.minY, width: max(0, owner.minX - gap - screen.minX), height: screen.height),
            CGRect(x: owner.maxX + gap, y: screen.minY, width: max(0, screen.maxX - owner.maxX - gap), height: screen.height),
            CGRect(x: screen.minX, y: owner.maxY + gap, width: screen.width, height: max(0, screen.maxY - owner.maxY - gap)),
            CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: max(0, owner.minY - gap - screen.minY))
        ].map { $0.intersection(screen) }.filter { !$0.isNull && $0.width >= 500 && $0.height >= 320 }
        guard let area = areas.first(where: { $0.width >= size.width && $0.height >= size.height })
                ?? areas.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let width = min(size.width, area.width), height = min(size.height, area.height)
        return CGRect(x: min(max(owner.midX - width / 2, area.minX), area.maxX - width),
                      y: min(max(owner.maxY - height, area.minY), area.maxY - height), width: width, height: height)
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
