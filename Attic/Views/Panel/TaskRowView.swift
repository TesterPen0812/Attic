import SwiftUI
import UniformTypeIdentifiers

/// Compact `done/total` child progress rendered on a parent row. It is
/// passive metadata: the row itself opens the family's subtask panel.
struct SubtaskRowSummary: Equatable {
    let done: Int
    let total: Int
}

/// A row is driven by values: its task (an observable model, so its own
/// field changes still re-render it), a few flags its parent derives from
/// the store and shell state, and plain references to the objects it acts
/// on. It observes no store-wide publisher, so a keystroke in one rename
/// field, a subtask draft, or a panel resize never re-evaluates every row.
/// `Equatable` lets SwiftUI skip rows whose inputs did not change.
struct TaskRowView: View, Equatable {
    let store: TaskStore
    let uiState: PanelUIState
    let subtaskPanels: SubtaskPanelController
    let task: TaskItem
    var subtaskSummary: SubtaskRowSummary? = nil
    /// True while the family's auxiliary surface (transient or pinned) is
    /// presenting this row's checklist — keeps a soft highlight so the open
    /// panel reads as anchored to the row.
    var isFamilyPresented = false
    /// True while the family's PINNED window is up — the row shows a quiet
    /// pinned status and activating the row raises that window.
    var isFamilyPinned = false
    /// Shell state the parent derives from `uiState` for this task.
    var isEditing = false
    var isConfirmingDeletion = false
    /// Files are copying into this task's owner right now.
    var isImportingAttachments = false

    static func == (lhs: TaskRowView, rhs: TaskRowView) -> Bool {
        lhs.task === rhs.task
            && lhs.store === rhs.store
            && lhs.uiState === rhs.uiState
            && lhs.subtaskPanels === rhs.subtaskPanels
            && lhs.subtaskSummary == rhs.subtaskSummary
            && lhs.isFamilyPresented == rhs.isFamilyPresented
            && lhs.isFamilyPinned == rhs.isFamilyPinned
            && lhs.isEditing == rhs.isEditing
            && lhs.isConfirmingDeletion == rhs.isConfirmingDeletion
            && lhs.isImportingAttachments == rhs.isImportingAttachments
    }

    @State private var isHovering = false
    @State private var isDropTargeted = false
    /// Files over a main-list row. Rows inside a family panel report to the
    /// panel's target instead, so the whole panel highlights.
    @State private var isFileDropTargeted = false
    @Environment(\.taskFileDropTarget) private var panelFileDrop
    @State private var confirmsIncompleteCompletion = false
    @State private var completionDropID: UUID?
    /// Legacy attachments stored on a subtask by an earlier build. Parent
    /// attachments live in the family panel's Attachments view instead.
    @State private var showsChildAttachments = false
    @FocusState private var isRenameFocused: Bool
    @FocusState private var focusedControl: RowControl?
    /// Single-line title widths: what the title wants versus what it got.
    @State private var titleIdealWidth: CGFloat = 0
    @State private var titleRenderedWidth: CGFloat = 0
    /// The AppKit view the actions menu pops up from.
    @StateObject private var menuAnchor = TaskRowMenuAnchor.Holder()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
    @Environment(\.atticPanelThemePalette) private var palette

    private enum RowControl: Hashable {
        case status
        case pinnedStatus
        case actions
    }

    private var isTopLevel: Bool { task.parentID == nil }
    /// Hover and keyboard focus reveal the same row affordances together.
    private var showsRowAffordances: Bool { isHovering || focusedControl != nil }
    /// Keyboard focus has no tooltip, so a clipped title is disclosed in full.
    private var disclosesFullTitle: Bool {
        TaskTitleDisclosure.showsFullTitle(
            isClipped: TaskTitleDisclosure.isClipped(idealWidth: titleIdealWidth, renderedWidth: titleRenderedWidth),
            hasRowFocus: focusedControl != nil,
            isEditing: isEditing
        )
    }
    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(get: { isConfirmingDeletion },
                set: { if !$0, uiState.confirmingTaskDeletionID == task.id { uiState.confirmingTaskDeletionID = nil } })
    }

    var body: some View {
        HStack(spacing: TaskRowLayout.statusSpacing) {
            TaskStatusButton(status: task.status, priority: task.priority) {
                requestStatus(task.status.primaryActionDestination)
            }
            .focused($focusedControl, equals: .status)
            .accessibilityIdentifier("complete-task-\(task.id.uuidString)")

            HStack(spacing: TaskRowLayout.metadataSpacing) {
                titleArea
                    .font(.system(size: AtticStyle.bodyTextSize, weight: task.status == .inProgress ? .medium : .regular, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .atticClearGlassForegroundReadability()

                if !task.attachments.isEmpty {
                    attachmentPreview
                }
                if isImportingAttachments {
                    ProgressView().controlSize(.mini).accessibilityLabel("Attaching files")
                }
                if let subtaskSummary {
                    subtaskProgress(summary: subtaskSummary)
                }

                trailingAction
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: TaskRowLayout.minimumHeight)
        .padding(.horizontal, 8)
        .background(
            rowHighlightColor,
            in: RoundedRectangle(cornerRadius: TaskRowLayout.hoverCornerRadius, style: .continuous)
        )
        // The continuous shape is visual; the whole row stays hit-testable
        // so drag, click and context menu keep the full rectangle.
        .contentShape(Rectangle())
        // One recognizer reads the AppKit click count, so a single click
        // opens the panel immediately (no double-click delay) while the
        // second click of a double-click keeps the status shortcut. Child
        // buttons and the actions menu keep their own clicks exclusively.
        .onTapGesture { handleRowClick(clickCount: NSApp.currentEvent?.clickCount ?? 1) }
        .help(TaskRowClick.help(status: task.status, isTopLevel: isTopLevel, isFamilyPinned: isFamilyPinned))
        .contextMenu { taskActions }
        .onChange(of: showsChildAttachments) { _, _ in syncAttachmentInteraction() }
        .onDisappear {
            // Only this row's own popover mark; the picker has its own.
            if showsChildAttachments, uiState.presentedTaskAttachmentsID == task.id { uiState.presentedTaskAttachmentsID = nil }
        }
        .alert("Complete this task?", isPresented: $confirmsIncompleteCompletion) {
            Button("Complete anyway") {
                if let id = completionDropID {
                    _ = store.drop(taskID: id, onto: task.id, allowingUnfinishedSubtasks: true)
                } else {
                    store.setStatus(.done, for: task, allowingUnfinishedSubtasks: true)
                }
                completionDropID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some subtasks are unfinished. They will stay unfinished if you complete this task.")
        }
        .onChange(of: confirmsIncompleteCompletion) { _, shown in
            uiState.confirmingTaskCompletionID = shown ? (completionDropID ?? task.id) : nil
            if !shown { completionDropID = nil }
        }
        .alert("Delete task and subtasks?", isPresented: isDeleteConfirmationPresented) {
            Button("Delete all", role: .destructive) { store.delete(task) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes “\(task.title)” and its \(store.subtasks(of: task.id).count) subtasks.")
        }
        .draggable(TaskDragPayload(taskID: task.id, title: task.title, imageReferences: task.attachments)) {
            dragPreview
        }
        .onDrop(of: rowDropTypes, delegate: TaskRowDropDelegate(
            taskID: task.id,
            panelTarget: panelFileDrop,
            canAcceptAttachment: { TaskFileDrop.canAccept($0, onto: task.id, store: store) },
            setTaskTargeted: { isDropTargeted = $0 },
            setFileTargeted: { targeted in
                withAnimation(reduceMotion ? nil : AtticMotion.quick) { isFileDropTargeted = targeted }
            },
            performTaskDrop: acceptTaskDrop,
            beginTaskDrop: { uiState.endDragging() },
            attach: { TaskFileDrop.attach($0, $1, to: task.id, store: store, subtaskPanels: subtaskPanels) }
        ))
        .overlay {
            if isFileDropTargeted {
                TaskDropOverlay(
                    message: TaskFileDrop.message(for: store.tasks.first { $0.id == store.attachmentOwnerID(for: task.id) }?.title ?? task.title),
                    shape: RoundedRectangle(cornerRadius: TaskRowLayout.hoverCornerRadius, style: .continuous),
                    labelAlignment: .trailing,
                    compact: true
                )
            }
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : AtticMotion.quick) {
                isHovering = hovering
            }
        }
        .animation(reduceMotion ? nil : AtticMotion.spring, value: task.statusRaw)
        .animation(reduceMotion ? nil : AtticMotion.quick, value: task.priorityRaw)
        .onChange(of: isEditing) { _, nowEditing in
            guard nowEditing else { return }
            // The draft text is seeded by PanelUIState.beginEditing so a row
            // recreated mid-edit (pin promote, family switch) resumes with
            // the user's typed text instead of a fresh empty field.
            DispatchQueue.main.async { isRenameFocused = true }
        }
        .onAppear {
            // A row born mid-edit (host swap on pin/unpin/family switch) never
            // sees an isEditing transition — restore focus on appear too.
            guard isEditing else { return }
            DispatchQueue.main.async { isRenameFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
        .accessibilityIdentifier("task-row-\(task.id.uuidString)")
        .accessibilityActions {
            if isTopLevel, !isEditing {
                Button(isFamilyPinned ? "Reveal pinned panel" : "Show subtasks", action: activateRow)
            }
        }
    }

    private var rowHighlightColor: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.08) }
        return Color.primary.opacity(showsRowAffordances || isFamilyPresented ? 0.055 : 0)
    }

    /// Single-line title with a soft trailing fade instead of wrapping, so
    /// every row keeps the same height. The full title stays available as
    /// the accessibility label, the tooltip when clipped, a focus disclosure
    /// when clipped, and in editing.
    @ViewBuilder
    private var titleArea: some View {
        if isEditing {
            TaskRenameField(draft: uiState.renameDraft, taskID: task.id,
                            commit: commitRename, cancel: cancelRename)
                .focused($isRenameFocused)
        } else {
            HStack(spacing: TaskRowLayout.pinnedStatusSpacing) {
                ViewThatFits(in: .horizontal) {
                    titleText
                    titleText
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .mask {
                            HStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: TaskRowLayout.titleFadeWidth)
                            }
                        }
                        .help(task.title)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { titleRenderedWidth = $0 }
                .background(alignment: .leading) {
                    titleText
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { titleIdealWidth = $0 }
                }
                .background {
                    TaskTitleExpansion(
                        title: task.title,
                        isPresented: disclosesFullTitle,
                        weight: task.status == .inProgress ? .medium : .regular,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: colorSchemeContrast == .increased
                    )
                }
                if isFamilyPinned {
                    pinnedStatus
                }
            }
        }
    }

    private var titleText: some View {
        Text(task.title)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .strikethrough(task.status == .done, color: .secondary)
            .foregroundStyle(task.status == .done
                ? palette.secondaryForegroundColor : palette.primaryForegroundColor)
            .accessibilityLabel(task.title)
    }

    /// Quiet status only: the pin/unpin control belongs to the subpanel.
    private var pinnedStatus: some View {
        Button {
            subtaskPanels.openFamilyPanel(for: task.id, focusEntry: false)
        } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(palette.secondaryForegroundColor.opacity(0.75))
                .atticClearGlassForegroundReadability()
                .frame(width: 16, height: 16)
                // Quiet glyph, comfortable pointer target.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .pinnedStatus)
        .help("Panel pinned")
        .accessibilityLabel("Panel pinned")
        .accessibilityHint("Reveals the pinned panel")
        .accessibilityIdentifier("task-pinned-status-\(task.id.uuidString)")
    }

    /// Passive previews (image thumbnails or file icons): clicks fall through
    /// to the row, which opens the family panel. A subtask's legacy
    /// attachments anchor their popover here.
    private var attachmentPreview: some View {
        HStack(spacing: -10) {
            ForEach(Array(task.attachments.prefix(2))) { reference in
                TaskAttachmentGlyph(reference: reference, files: store.taskImageFiles)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.background, lineWidth: 1.5))
            }
            if task.attachments.count > 2 {
                Text("+\(task.attachments.count - 2)").font(.system(size: 9, weight: .medium))
                    .padding(.leading, 12)
            }
        }
        .fixedSize()
        .help(attachmentCountLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachmentCountLabel)
        .accessibilityIdentifier("task-images-\(task.id.uuidString)")
        .popover(isPresented: $showsChildAttachments) {
            TaskAttachmentsPopover(store: store, task: task)
        }
    }

    private var attachmentCountLabel: String {
        task.attachments.count == 1 ? "1 attachment" : "\(task.attachments.count) attachments"
    }

    private var dragPreview: some View {
        HStack(spacing: 7) {
            TaskStatusMark(status: task.status, priority: task.priority, size: 13)
            Text(task.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2)
                .atticClearGlassForegroundReadability()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear {
            uiState.beginDragging(task)
        }
    }

    private func subtaskProgress(summary: SubtaskRowSummary) -> some View {
        Text("\(summary.done)/\(summary.total)")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(palette.secondaryForegroundColor)
            .atticClearGlassForegroundReadability()
            .fixedSize()
            .help("\(summary.done) of \(summary.total) subtasks complete")
            .accessibilityLabel("Subtasks")
            .accessibilityValue("\(summary.done) of \(summary.total) complete")
            .accessibilityIdentifier("subtask-progress-\(task.id.uuidString)")
    }

    @ViewBuilder
    private var trailingAction: some View {
        if isEditing {
            Button(action: commitRename) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.accentColor)
                    .atticClearGlassForegroundReadability()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save title")
            .accessibilityLabel("Save title")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if #available(macOS 14.4, *) {
            // A plain button that pops the same actions as a native menu.
            // SwiftUI's borderless `Menu` renders its label through an AppKit
            // pop-up button, which paints the symbol as an accent-tinted
            // template and ignores the label's opacity — the blue "•••"
            // visible on every resting row. Owning the glyph keeps its
            // colour quiet and lets the whole control fade at rest while its
            // 24×24 footprint stays reserved.
            Button(action: presentActionsMenu) {
                actionsGlyph
            }
            .buttonStyle(.plain)
            .background(TaskRowMenuAnchor(anchor: menuAnchor))
            .modifier(RowActionsAffordance(isShown: showsRowAffordances, taskID: task.id))
            .focused($focusedControl, equals: .actions)
        } else {
            // Older systems have no NSHostingMenu; the SwiftUI menu keeps the
            // same actions and the same at-rest gating.
            Menu {
                taskActions
            } label: {
                actionsGlyph
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // The same pop-up button the newer path exists to avoid: it paints
            // the label as a tinted template and ignores its foregroundStyle,
            // so without this the fallback row rested on the panel accent.
            .atticQuietMenuGlyph(palette.secondaryForegroundColor)
            .modifier(RowActionsAffordance(isShown: showsRowAffordances, taskID: task.id))
            .focused($focusedControl, equals: .actions)
        }
    }

    @ViewBuilder
    private var taskActions: some View {
        // New attachments always belong to the parent; a subtask's command
        // adds to its parent and shows the result there.
        Button("Add attachment…", systemImage: "paperclip") {
            let atStart = subtaskPanels.revealContext
            TaskAttachmentPicker.choose(for: task.id, store: store, uiState: uiState) { ids, ownerID in
                subtaskPanels.revealImportedAttachments(ids, for: ownerID, since: atStart)
            }
        }
        .disabled(!TaskAttachmentPicker.isAvailable(for: task.id, store: store, uiState: uiState))
        // A parent's attachments are reached from the switch inside its
        // panel, which every open starts on Subtasks; only a subtask's
        // legacy attachments need a command of their own.
        if !isTopLevel, !task.attachments.isEmpty {
            Button("Show attachments", systemImage: "photo.on.rectangle") { showsChildAttachments = true }
        }
        if task.parentID == nil {
            if !store.subtasks(of: task.id).isEmpty {
                Button("Show subtasks", systemImage: "list.bullet.indent") {
                    subtaskPanels.openFamilyPanel(for: task.id, focusEntry: false, view: .subtasks)
                }
            }
            if task.status != .done {
                Button("Add subtask…", systemImage: "plus") {
                    subtaskPanels.openFamilyPanel(for: task.id, focusEntry: true)
                }
            }
            Divider()
        }
        TaskActionsMenu(store: store, task: task, editLabel: "Edit title…", deleteRequested: {
            if store.subtasks(of: task.id).isEmpty { store.delete(task) }
            else { uiState.confirmingTaskDeletionID = task.id }
        }, statusRequested: requestStatus) {
            uiState.beginEditing(task)
        }
    }

    private var rowDropTypes: [UTType] {
        [TaskDragPayload.internalTaskType] + TaskDropContent.dropTypes
    }

    /// The task-drag half of the row's drop: unchanged reorder and status
    /// rules, including the unfinished-subtasks confirmation.
    private func acceptTaskDrop(_ draggedTaskID: UUID) {
        if task.status == .done,
           let source = store.tasks.first(where: { $0.id == draggedTaskID }), source.status != .done,
           source.parentID == task.parentID,
           store.subtasks(of: draggedTaskID).contains(where: { $0.status != .done }) {
            completionDropID = draggedTaskID
            confirmsIncompleteCompletion = true
            return
        }
        store.drop(taskID: draggedTaskID, onto: task.id)
    }

    private func requestStatus(_ status: TaskStatus) {
        if status == .done, task.status != .done,
           store.subtasks(of: task.id).contains(where: { $0.status != .done }) {
            confirmsIncompleteCompletion = true
        } else {
            store.setStatus(status, for: task)
        }
    }

    private var actionsGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.secondaryForegroundColor)
            .atticClearGlassForegroundReadability()
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    /// The row's actions as a native menu below the control. The menu is
    /// built from the same SwiftUI actions the context menu uses, so both
    /// paths stay identical; NSMenu tracking raises the shared
    /// `.menuTracking` lock like every other menu.
    @available(macOS 14.4, *)
    private func presentActionsMenu() {
        let menu = NSHostingMenu(rootView: taskActions)
        guard let view = menuAnchor.view else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }

    private func syncAttachmentInteraction() {
        if showsChildAttachments { uiState.presentedTaskAttachmentsID = task.id }
        else if uiState.presentedTaskAttachmentsID == task.id { uiState.presentedTaskAttachmentsID = nil }
    }

    private func commitRename() {
        if store.rename(task, to: uiState.editingDraftTitle) {
            uiState.endEditing()
        }
    }

    private func cancelRename() {
        uiState.endEditing()
    }

    private func handleRowClick(clickCount: Int) {
        switch TaskRowClick.resolve(clickCount: clickCount, isTopLevel: isTopLevel, isEditing: isEditing) {
        case .openFamilyPanel: activateRow()
        case .statusShortcut: store.performDoubleClickAction(task)
        case .none: break
        }
    }

    /// The row opens (never toggles) its family panel; a pinned family's
    /// existing window is raised instead of duplicated.
    private func activateRow() {
        guard isTopLevel, !isEditing else { return }
        subtaskPanels.openFamilyPanel(for: task.id, focusEntry: false)
    }

}

/// Hidden at rest means inert as well as invisible: no click target, no
/// VoiceOver element, no layout shift — the footprint stays reserved and the
/// row's context menu keeps the same actions.
private struct RowActionsAffordance: ViewModifier {
    let isShown: Bool
    let taskID: UUID

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
            .help("Task actions")
            .accessibilityLabel("Task actions")
            .accessibilityIdentifier("task-actions-\(taskID.uuidString)")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// An invisible AppKit sibling under the actions control, so a native menu
/// can pop up from the control's exact position.
struct TaskRowMenuAnchor: NSViewRepresentable {
    @MainActor
    final class Holder: ObservableObject {
        weak var view: NSView?
    }

    let anchor: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// The rename field observes the draft alone, so typing re-renders this
/// view and nothing else in the list.
private struct TaskRenameField: View {
    @ObservedObject var draft: TaskRenameDraft
    let taskID: UUID
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        TextField("Task title", text: $draft.title, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .accessibilityIdentifier("edit-task-title-\(taskID.uuidString)")
    }
}

enum TaskRowLayout {
    static let minimumHeight: CGFloat = 42
    static let statusSpacing: CGFloat = 10
    /// Title → attachments → progress → actions sit close together.
    static let metadataSpacing: CGFloat = 6
    static let pinnedStatusSpacing: CGFloat = 4
    static let titleFadeWidth: CGFloat = 22
    static let hoverCornerRadius: CGFloat = 10
}

/// What a plain click on a task row means. Opening is idempotent, so the
/// first click of a double-click may open the panel without undoing the
/// status shortcut the second click performs. Child rows have no nested
/// panel (subtasks are one level deep).
enum TaskRowClick: Equatable {
    case none
    case openFamilyPanel
    case statusShortcut

    static func resolve(clickCount: Int, isTopLevel: Bool, isEditing: Bool) -> Self {
        guard !isEditing else { return .none }
        if clickCount >= 2 { return clickCount == 2 ? .statusShortcut : .none }
        return isTopLevel ? .openFamilyPanel : .none
    }

    /// Row help leads with the primary click and keeps the double-click
    /// status shortcut as the secondary hint. Child rows have no panel.
    static func help(status: TaskStatus, isTopLevel: Bool, isFamilyPinned: Bool) -> String {
        guard isTopLevel else { return status.doubleClickTitle }
        let primary = isFamilyPinned ? "Click to reveal the pinned panel" : "Click to show subtasks"
        guard status.doubleClickDestination != nil else { return primary }
        return "\(primary). \(status.doubleClickTitle)"
    }
}

/// Whether keyboard focus discloses the full title. Only a clipped title
/// needs it; editing already shows the whole title in its field.
enum TaskTitleDisclosure {
    static func isClipped(idealWidth: CGFloat, renderedWidth: CGFloat) -> Bool {
        idealWidth > renderedWidth + 0.5
    }

    static func showsFullTitle(isClipped: Bool, hasRowFocus: Bool, isEditing: Bool) -> Bool {
        isClipped && hasRowFocus && !isEditing
    }
}

/// Focus disclosure for a clipped title, modelled on AppKit expansion
/// tooltips: a borderless, mouse-transparent child window lays the full title
/// over the row, starting at the title's own position. The row keeps its
/// height and metadata, and the list's scroll view cannot clip the label.
/// The window exists only while presented, and only over the key window.
struct TaskTitleExpansion: NSViewRepresentable {
    let title: String
    let isPresented: Bool
    let weight: Font.Weight
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.update(self)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.tearDown()
    }

    final class AnchorView: NSView {
        private var configuration: TaskTitleExpansion?
        private var panel: NSPanel?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private weak var observedClipView: NSClipView?

        /// Key-window and scroll observers held by this row: none unless its
        /// title is presented in a window, so unfocused rows do no work.
        var observerCount: Int { observers.count }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        func update(_ configuration: TaskTitleExpansion) {
            self.configuration = configuration
            refresh()
        }

        func tearDown() {
            configuration = nil
            stopObserving()
            dismiss()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            if panel != nil { refresh() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if panel != nil { refresh() }
        }

        /// Observes key changes (to hide on key loss and return on key gain)
        /// and clip-view scrolling only while presented in a window. Observers
        /// stay across key loss and scroll-out so the title can come back.
        private func updateObservation() {
            let window = configuration?.isPresented == true ? self.window : nil
            let clipView = window == nil ? nil : enclosingScrollView?.contentView
            guard window !== observedWindow || clipView !== observedClipView
                    || (window == nil) != observers.isEmpty else { return }
            stopObserving()
            guard let window else { return }
            observedWindow = window
            observedClipView = clipView
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            if let clipView {
                observers.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = nil
            observedClipView = nil
        }

        private func refresh() {
            updateObservation()
            guard let configuration, configuration.isPresented,
                  let window, window.isVisible, window.isKeyWindow,
                  !visibleRect.isEmpty else {
                dismiss()
                return
            }
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let textWidth = max(anchor.width, TaskTitleExpansionLabel.minimumTextWidth)
            let label = TaskTitleExpansionLabel(configuration: configuration, textWidth: textWidth)
            let panel = self.panel ?? makePanel()
            let host: NSHostingView<TaskTitleExpansionLabel>
            if let existing = panel.contentView as? NSHostingView<TaskTitleExpansionLabel> {
                existing.rootView = label
                host = existing
            } else {
                host = NSHostingView(rootView: label)
                host.setAccessibilityElement(false)
                panel.contentView = host
            }
            let size = host.fittingSize
            // The first text line sits exactly on the clipped title.
            var frame = CGRect(
                x: anchor.minX - TaskTitleExpansionLabel.horizontalPadding,
                y: anchor.maxY + TaskTitleExpansionLabel.verticalPadding - size.height,
                width: size.width,
                height: size.height
            )
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = max(frame.minY, visible.minY)
            }
            panel.appearance = window.effectiveAppearance
            panel.setFrame(frame, display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                panel.level = window.level
                window.addChildWindow(panel, ordered: .above)
            }
        }

        private func makePanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            panel.setAccessibilityElement(false)
            self.panel = panel
            return panel
        }

        private func dismiss() {
            guard let panel else { return }
            self.panel = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

/// The disclosed title: the row's type on a quiet material card that wraps
/// within the title column (or a modest minimum width in narrow rows).
struct TaskTitleExpansionLabel: View {
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let minimumTextWidth: CGFloat = 200

    let configuration: TaskTitleExpansion
    let textWidth: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(configuration.title)
            .font(.system(size: AtticStyle.bodyTextSize, weight: configuration.weight, design: .rounded))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: textWidth, alignment: .leading)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background {
                if configuration.reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                shape.stroke(
                    Color.primary.opacity(configuration.increasedContrast ? 0.28 : 0.12),
                    lineWidth: configuration.increasedContrast ? 1 : 0.5
                )
            }
            .accessibilityHidden(true)
    }
}
