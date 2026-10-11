import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A task's stored files, inline under its row (A1, owner decision B): the
/// files count opens it, apart from the subtasks. It replaces the old
/// floating "Open files" window, the only place a task's files used to be
/// reachable. Compact rows (type icon, name, size) in the quick look's text
/// column, never a checkbox; "Attach file…" under them; a long list shows
/// the first few and "N more…".
///
/// Every action the old window had stays: a click or Space previews the
/// file (Quick Look), a double-click or Return opens it in its app, Delete
/// or the × removes it (one Undo step, a toast), a drag copies it out, and
/// the right-click menu and VoiceOver offer all three. Dropping files on
/// the task attaches them (the page's one drop destination).
struct TasksFilesList: View {
    let files: [TaskImageReference]
    let store: TaskStore
    /// The task that owns the files (its row).
    let owner: UUID
    /// The file picker can open for this task now.
    let canAttach: Bool
    let isImporting: Bool
    let onAttach: () -> Void
    let onRemove: (TaskImageReference) -> Void

    /// Files shown before "N more…".
    static let collapsedCount = 4

    @State private var showsAll = false
    @Environment(\.atticDesign) private var design

    private var shown: [TaskImageReference] {
        showsAll || files.count <= Self.collapsedCount + 1 ? files : Array(files.prefix(Self.collapsedCount))
    }

    /// Lines the collapsed list draws for `files` files: the first few,
    /// "N more…" when it caps, and "Attach file…" (the page's estimate of
    /// a row's height before it is measured).
    static func lineCount(files: Int) -> Int {
        files > collapsedCount + 1 ? collapsedCount + 2 : files + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { file in
                TasksFileRow(file: file, store: store, owner: owner) { onRemove(file) }
            }
            if files.count > Self.collapsedCount + 1 {
                AtticQuietAction(
                    // Its label lines up with the names above it.
                    systemName: showsAll ? "chevron.up" : "chevron.down",
                    title: showsAll ? String(localized: "Show fewer") : String(localized: "\(files.count - Self.collapsedCount) more…"),
                    action: { withAnimation(design.reduceMotion ? nil : AtticMotionPreset.expand.animation(reduceMotion: false)) { showsAll.toggle() } }
                )
                .accessibilityIdentifier("tasks-files-more")
            }
            AtticQuietAction(
                systemName: "paperclip",
                title: isImporting ? String(localized: "Attaching…") : String(localized: "Attach file…"),
                action: onAttach
            )
            .disabled(!canAttach)
            .accessibilityIdentifier("tasks-files-attach")
        }
        .padding(.leading, AtticLayout.textX)
        // Sizes line up with the row's date column; a hover fill (8 pt
        // wider each side) ends where the row's own highlight does.
        .padding(.trailing, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset)
        .padding(.bottom, AtticQuickLookMetrics.bottomPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Files"))
        .accessibilityIdentifier("tasks-files-\(owner.uuidString)")
    }
}

/// One file: its type icon (a thumbnail for an image), name and size. The
/// size gives way to Quick Look and Remove while the pointer or the
/// keyboard is on the line.
private struct TasksFileRow: View {
    let file: TaskImageReference
    let store: TaskStore
    let owner: UUID
    let remove: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovered = false

    private var size: String { ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file) }
    private var canOpen: Bool { TaskAttachmentActions.canOpen(file) }

    var body: some View {
        let m = AtticSubtaskMetrics.self
        let showsControls = hovered || (focused && keyboardFocusVisible)
        HStack(spacing: m.titleGap) {
            Group {
                if file.isImage {
                    // An image shows itself (the A1 sheet).
                    TaskImageThumbnail(reference: file, files: store.taskImageFiles)
                        .frame(width: AtticQuietActionMetrics.iconSlot, height: AtticQuietActionMetrics.iconSlot)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    // Other kinds: the app's outline type icon, in the
                    // quiet actions' ink and size ("Attach file…" under it).
                    AtticIcon(systemName: Self.symbol(for: file.contentType), size: AtticQuietActionMetrics.iconSize,
                              weight: .medium, ink: .icon)
                }
            }
            .frame(width: AtticQuietActionMetrics.iconSlot, height: AtticQuietActionMetrics.iconSlot)
            .accessibilityHidden(true)
            AtticText(verbatim: file.filename, style: .listBody, ink: .body, truncates: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsControls {
                HStack(spacing: 2) {
                    control("eye", help: String(localized: "Quick Look"), action: preview)
                    control("xmark", help: String(localized: "Remove"), action: remove)
                }
                .transition(.opacity)
            } else {
                AtticText(verbatim: size, style: .rowMeta, ink: .helper)
            }
        }
        .frame(height: AtticLayout.subtaskPitch)
        .background {
            RoundedRectangle(cornerRadius: AtticRadius.control(height: AtticLayout.subtaskPitch - 4), style: .continuous)
                .fill((showsControls ? design.tokens.chipHover : .clear).color)
                .padding(.horizontal, -AtticSpacing.s8)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .focused($focused)
        .onTapGesture(count: 2) { if canOpen { open() } else { preview() } }
        .onTapGesture(perform: preview)
        .onKeyPress(.space) { preview(); return .handled }
        .onKeyPress(.return) { if canOpen { open() } else { preview() }; return .handled }
        .onKeyPress(.delete) { remove(); return .handled }
        .onKeyPress(.deleteForward) { remove(); return .handled }
        // The file leaves as itself: a drag to Finder or another app copies
        // it, and so does a drop on another task (as the old window's cards
        // did); its own task refuses it.
        .onDrag {
            MainActor.assumeIsolated { TaskAttachmentCardDrag.begin(file, store: store) }
            return TaskAttachmentDragItem(reference: file, files: store.taskImageFiles).itemProvider()
        }
        .contextMenu {
            Button(String(localized: "Quick Look"), systemImage: "eye", action: preview)
            Button(String(localized: "Open"), systemImage: "arrow.up.forward.square", action: open)
                .disabled(!canOpen)
            Divider()
            Button(String(localized: "Remove"), systemImage: "trash", role: .destructive, action: remove)
        }
        .animation(design.reduceMotion ? nil : AtticMotionPreset.hover.animation(reduceMotion: false), value: showsControls)
        .help(file.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.filename)
        .accessibilityValue(size)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Shows a Quick Look preview"))
        .accessibilityAction(.default, preview)
        .accessibilityActions {
            if canOpen { Button(String(localized: "Open"), action: open) }
            Button(String(localized: "Remove"), action: remove)
        }
        .accessibilityIdentifier("task-attachment-\(file.id.uuidString)")
    }

    private func control(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AtticIcon(systemName: systemName, size: 11, weight: .medium, ink: .icon)
                .frame(width: 24, height: AtticLayout.subtaskPitch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityHidden(true)
    }

    /// The outline symbol for a file that is not an image.
    static func symbol(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        // Office documents are zip archives too: their own kind first.
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return "doc.text" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    private func preview() { TaskAttachmentActions.preview(file, store: store, owner: owner) }
    private func open() { TaskAttachmentActions.open(file, store: store, owner: owner) }
}
