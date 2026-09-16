import AppKit
import SwiftUI

/// Attachments picked or dropped while a new task is being written. Each
/// batch is imported straight into private storage, so it previews like any
/// attachment and submit binds the same references in the new task's single
/// save; nothing is copied again. Until then the composer owns those private
/// copies: removing one, or cancelling an import, deletes only what this
/// composer created, and never a user's original.
@MainActor
final class TaskComposerAttachments: ObservableObject {
    @Published private(set) var pending: [TaskImageReference] = []
    /// Items of the batch still copying in, shown as one placeholder.
    @Published private(set) var importingCount = 0

    private var importTask: Task<Void, Never>?
    /// Bumped by every new batch and every cancel, so a batch that finishes
    /// after it was cancelled deletes its copies instead of appearing.
    private var generation: UInt64 = 0

    var isImporting: Bool { importingCount > 0 }
    var isEmpty: Bool { pending.isEmpty && !isImporting }

    /// One batch at a time, so a second drop and submit can never interleave
    /// with an import that is still copying.
    var canAdd: Bool {
        !isImporting && pending.count < AttachmentLimits.maxAttachmentsPerNote
    }

    func canSubmit(title: String) -> Bool {
        !isImporting && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stages and imports one batch. Limits count the items already pending.
    /// A failure removes the batch's own copies and staging and reports it;
    /// pending items are untouched. A `stage` that throws must already have
    /// discarded any directory it owns; a returned staging is discarded here.
    func add(count: Int, files: TaskImageFiles,
             stage: @escaping @MainActor () async throws -> TaskAttachmentStaging,
             succeeded: (@MainActor () -> Void)? = nil,
             reportFailure: @escaping @MainActor (Error) -> Void) {
        add(count: count, files: files, importing: { existing in
            var staging = TaskAttachmentStaging()
            defer { staging.discard() }
            staging = try await stage()
            try Task.checkCancellation()
            return try await files.importAttachments(staging.urls, existing: existing)
        }, succeeded: succeeded, reportFailure: reportFailure)
    }

    /// One batch from any source. `importing` receives the pending items (for
    /// limits) and, when it throws, leaves no private copies behind.
    /// `succeeded` runs once the batch is pending, so a stale failure notice
    /// from an earlier attempt can clear.
    func add(count: Int, files: TaskImageFiles,
             importing: @escaping @MainActor ([TaskImageReference]) async throws -> [TaskImageReference],
             succeeded: (@MainActor () -> Void)? = nil,
             reportFailure: @escaping @MainActor (Error) -> Void) {
        guard canAdd, count > 0 else { return }
        generation &+= 1
        let batch = generation
        let existing = pending
        importingCount = count
        importTask = Task { [weak self] in
            do {
                let imported = try await importing(existing)
                guard let self, self.generation == batch else {
                    await files.remove(imported)
                    return
                }
                self.pending.append(contentsOf: imported)
                self.finish(batch)
                succeeded?()
            } catch {
                guard let self, self.generation == batch else { return }
                self.finish(batch)
                reportFailure(error)
            }
        }
    }

    /// Stops the batch that is copying in. Its partial copies and staging
    /// are removed by the importer's own rollback or by the batch on return.
    func cancelImport() {
        guard isImporting else { return }
        generation &+= 1
        // The cancelled task still settles on its own and cleans up after
        // itself; a new batch simply replaces this handle.
        importTask?.cancel()
        importingCount = 0
    }

    func remove(_ attachmentID: UUID, files: TaskImageFiles) {
        guard let index = pending.firstIndex(where: { $0.id == attachmentID }) else { return }
        let removed = pending.remove(at: index)
        Task { await files.remove([removed]) }
    }

    /// The pending references now belong to a saved task: forget them
    /// without touching their files.
    func didBind() {
        pending = []
    }

    /// Test seam: waits for the current batch, if any, to settle.
    func waitForImport() async {
        await importTask?.value
    }

    private func finish(_ batch: UInt64) {
        guard generation == batch else { return }
        importingCount = 0
        importTask = nil
    }
}

enum TaskComposerLayout {
    /// The pending strip above the text row; the shell grows upward by this.
    static let pendingStripHeight: CGFloat = 54
    static let chipHeight: CGFloat = 40
}

/// Pending attachments above the composer's text row: image thumbnails and
/// compact file cards, plus a placeholder while a batch copies in.
struct TaskComposerAttachmentStrip: View {
    @ObservedObject var attachments: TaskComposerAttachments
    let store: TaskStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments.pending) { reference in
                    TaskComposerAttachmentChip(reference: reference, store: store) {
                        attachments.remove(reference.id, files: store.taskImageFiles)
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if attachments.isImporting {
                    importingChip
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
        .frame(height: TaskComposerLayout.pendingStripHeight)
        .animation(reduceMotion ? nil : AtticMotion.quick, value: attachments.pending.map(\.id))
        .animation(reduceMotion ? nil : AtticMotion.quick, value: attachments.isImporting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments for the new task")
        .accessibilityIdentifier("quick-entry-attachments")
    }

    private var importingChip: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(attachments.importingCount == 1 ? "Attaching…" : "Attaching \(attachments.importingCount)…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(action: attachments.cancelImport) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .atticGlassControl(in: Circle())
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel attaching")
            .accessibilityLabel("Cancel attaching")
            .accessibilityIdentifier("quick-entry-attachments-cancel")
        }
        .padding(.horizontal, 10)
        .frame(height: TaskComposerLayout.chipHeight)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attaching files")
    }
}

/// One pending attachment. Click or Space previews, Delete or the × removes.
struct TaskComposerAttachmentChip: View {
    let reference: TaskImageReference
    let store: TaskStore
    let remove: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.atticPanelThemePalette) private var palette

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
    private var size: String { ByteCountFormatter.string(fromByteCount: reference.byteCount, countStyle: .file) }

    var body: some View {
        content
            .frame(height: TaskComposerLayout.chipHeight)
            .background(Color.primary.opacity(isHovering || isFocused ? 0.08 : 0.05), in: shape)
            .overlay { shape.strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5) }
            .overlay(alignment: .topTrailing) {
                if isHovering || isFocused { removeButton }
            }
            .contentShape(shape)
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($isFocused)
            .onTapGesture { TaskAttachmentActions.preview(reference, store: store) }
            .onKeyPress(.space) { TaskAttachmentActions.preview(reference, store: store); return .handled }
            .onDeleteCommand(perform: remove)
            .onHover { isHovering = $0 }
            .help(reference.filename)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reference.filename), \(reference.isImage ? "image" : "file"), \(size)")
            .accessibilityHint("Attaches when the task is added")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { TaskAttachmentActions.preview(reference, store: store) }
            .accessibilityActions { Button("Remove", action: remove) }
            .accessibilityIdentifier("quick-entry-attachment-\(reference.id.uuidString)")
    }

    @ViewBuilder
    private var content: some View {
        if reference.isImage {
            TaskImageThumbnail(reference: reference, files: store.taskImageFiles)
                .frame(width: TaskComposerLayout.chipHeight, height: TaskComposerLayout.chipHeight)
                .clipShape(shape)
        } else {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(for: reference.contentType))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxWidth: 96, alignment: .leading)
            }
            .padding(.leading, 7)
            .padding(.trailing, 12)
        }
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.9))
                .frame(width: 16, height: 16)
                .atticGlassControl(in: Circle())
                // Compact glyph, comfortable pointer target.
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Keyboard users remove with Delete or the Remove action.
        .focusable(false)
        .padding(-2)
        .help("Remove \(reference.filename)")
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}
