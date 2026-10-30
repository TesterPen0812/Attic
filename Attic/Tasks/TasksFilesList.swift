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
/// the right-click menu and VoiceOver offer all three. A click already
/// previews, so the line has no preview (eye) button of its own (O17-11). Dropping files on
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
    /// The page's Tab loop follows this list's currently drawn controls.
    var onTabStopsChanged: (TasksFileListID, [TasksFileFocusID]) -> Void = { _, _ in }
    var onTabStopsRemoved: (TasksFileListID) -> Void = { _ in }

    /// Files shown before "N more…".
    static let collapsedCount = 4

    @State private var showsAll = false
    @State private var instance = UUID()

    private var listID: TasksFileListID { TasksFileListID(owner: owner, instance: instance) }
    @FocusState private var moreFocused: Bool
    @FocusState private var attachFocused: Bool
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @Environment(\.atticDesign) private var design

    private var shown: [TaskImageReference] {
        showsAll || files.count <= Self.collapsedCount + 1 ? files : Array(files.prefix(Self.collapsedCount))
    }

    private var tabStops: [TasksFileFocusID] {
        var stops = shown.map { TasksFileFocusID.file(owner: owner, id: $0.id) }
        if files.count > Self.collapsedCount + 1 { stops.append(.more(owner)) }
        if canAttach { stops.append(.attach(owner)) }
        return stops
    }

    /// Lines the collapsed list draws for `files` files: the first few,
    /// "N more…" when it caps, and "Attach file…" (the page's estimate of
    /// a row's height before it is measured).
    static func lineCount(files: Int) -> Int {
        files > collapsedCount + 1 ? collapsedCount + 2 : files + 1
    }

    private func toggleShownFiles() {
        withAnimation(design.reduceMotion ? nil : AtticMotionPreset.expand.animation(reduceMotion: false)) { showsAll.toggle() }
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
                    action: toggleShownFiles
                )
                .focusable()
                .focused($moreFocused)
                .onKeyPress(.space) { toggleShownFiles(); return .handled }
                .onKeyPress(.return) { toggleShownFiles(); return .handled }
                .focusEffectDisabled()
                .atticFocusRing(moreFocused && keyboardFocusVisible, cornerRadius: AtticRadius.control(height: AtticQuietActionMetrics.height))
                .atticFocusRequestTarget(TasksFileFocusID.more(owner), focused: $moreFocused)
                .id(TasksFileFocusID.more(owner))
                .accessibilityIdentifier("tasks-files-more")
            }
            AtticQuietAction(
                systemName: "paperclip",
                title: isImporting ? String(localized: "Attaching…") : String(localized: "Attach file…"),
                action: onAttach
            )
            .disabled(!canAttach)
            .focusable()
            .focused($attachFocused)
            .onKeyPress(.space) { if canAttach { onAttach() }; return .handled }
            .onKeyPress(.return) { if canAttach { onAttach() }; return .handled }
            .focusEffectDisabled()
            .atticFocusRing(attachFocused && keyboardFocusVisible, cornerRadius: AtticRadius.control(height: AtticQuietActionMetrics.height))
            .atticFocusRequestTarget(TasksFileFocusID.attach(owner), focused: $attachFocused)
            .id(TasksFileFocusID.attach(owner))
            .accessibilityIdentifier("tasks-files-attach")
        }
        .padding(.leading, TasksDesignMetrics.textX)
        // Sizes line up with the row's date column; a hover fill (8 pt
        // wider each side) ends where the row's own highlight does.
        .padding(.trailing, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset)
        .padding(.bottom, AtticQuickLookMetrics.bottomPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Files"))
        .accessibilityIdentifier("tasks-files-\(owner.uuidString)")
        .onAppear { onTabStopsChanged(listID, tabStops) }
        .onChange(of: tabStops) { _, stops in onTabStopsChanged(listID, stops) }
        .onDisappear { onTabStopsRemoved(listID) }
    }
}

/// One file: its type icon (a thumbnail for an image), name and size. The
/// size gives way to Remove while the pointer or the keyboard is on the
/// line; the line itself previews (a click, Space, VoiceOver's Quick Look).
struct TasksFileRow: View {
    let file: TaskImageReference
    let store: TaskStore
    let owner: UUID
    let remove: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @Environment(\.atticForcedState) private var forced
    @FocusState private var focused: Bool
    @State private var hovered = false
    /// Where the row lies in the panel (K-04), for its drag's way home;
    /// kept outside SwiftUI's state, so scrolling never re-renders it.
    @State private var placement = AtticDragReturn.SourceFrame()

    private var size: String { ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file) }
    private var canOpen: Bool { TaskAttachmentActions.canOpen(file) }

    var body: some View {
        let m = AtticSubtaskMetrics.self
        let showsControls = hovered || forced == .hover || (focused && keyboardFocusVisible)
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
                control("xmark", help: String(localized: "Remove"), action: remove)
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
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .atticFocusRequestTarget(TasksFileFocusID.file(owner: owner, id: file.id), focused: $focused)
        .id(TasksFileFocusID.file(owner: owner, id: file.id))
        .onTapGesture(count: 2) { if canOpen { open() } else { preview() } }
        .onTapGesture(perform: preview)
        .onKeyPress(.space) { preview(); return .handled }
        .onKeyPress(.return) { if canOpen { open() } else { preview() }; return .handled }
        .onKeyPress(.delete) { remove(); return .handled }
        .onKeyPress(.deleteForward) { remove(); return .handled }
        // The file leaves as itself: a drag to Finder or another app copies
        // it, and so does a drop on another task (as the old window's cards
        // did); its own task refuses it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placement.frame = $0 }
        .onDrag {
            MainActor.assumeIsolated {
                TaskAttachmentCardDrag.begin(file, store: store)
                AtticDragReturn.SourceFrame.next = placement.frame
            }
            return TaskAttachmentDragItem(reference: file, files: store.taskImageFiles).itemProvider()
        } preview: {
            // O17-16: the file itself as it leaves (its picture or icon, and
            // its name), never the row's hover fill and buttons.
            TaskFileDragPreview(file: file)
        }
        .atticContextMenu {
            [AtticMenuCommand("Quick Look", systemImage: "eye", action: preview),
             AtticMenuCommand("Open", systemImage: "arrow.up.forward.square", isDisabled: !canOpen, action: open),
             AtticMenuCommand("Remove", systemImage: "trash", isDestructive: true, startsSection: true, action: remove)]
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
            ForEach(Self.voiceOverActions(canOpen: canOpen), id: \.self) { action in
                Button(action.title) { perform(action) }
            }
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

    /// What VoiceOver offers on the line, beyond its default (a preview):
    /// Quick Look by name too, now that the line has no eye button
    /// (O17-11), then Open and Remove.
    enum Action: Hashable {
        case quickLook, open, remove

        var title: String {
            switch self {
            case .quickLook: String(localized: "Quick Look")
            case .open: String(localized: "Open")
            case .remove: String(localized: "Remove")
            }
        }
    }

    static func voiceOverActions(canOpen: Bool) -> [Action] {
        canOpen ? [.quickLook, .open, .remove] : [.quickLook, .remove]
    }

    private func perform(_ action: Action) {
        switch action {
        case .quickLook: preview()
        case .open: open()
        case .remove: remove()
        }
    }

    private func preview() { TaskAttachmentActions.preview(file, store: store, owner: owner) }
    private func open() { TaskAttachmentActions.open(file, store: store, owner: owner) }
}

/// What a file dragged out of a task looks like under the pointer (O17-16):
/// its thumbnail (an image) or its kind's icon, and its name, on a quiet
/// label like a dragged task's. Drawn once, as the drag begins, so it uses
/// only what is at hand: the thumbnail its row already loaded.
struct TaskFileDragPreview: View {
    let file: TaskImageReference

    static let iconSide: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if file.isImage, let thumbnail = TaskThumbnailMemory.image(for: file.digest) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: file.contentType)).resizable()
                        .frame(width: Self.iconSide, height: Self.iconSide)
                }
            }
            Text(verbatim: file.filename)
                .font(.system(size: NSFont.systemFontSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }
}

/// A file list's focus targets, shared with the page-owned Tab loop.
enum TasksFileFocusID: Hashable {
    case file(owner: UUID, id: UUID)
    case more(UUID)
    case attach(UUID)
}

/// A task can have overlapping old/new lists during a removal transition.
/// Disappearance may unregister only the instance that owns the stops.
struct TasksFileListID: Hashable {
    let owner: UUID
    let instance: UUID
}
