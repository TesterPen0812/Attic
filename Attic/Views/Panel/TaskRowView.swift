import SwiftUI

/// Compact `done/total` child progress rendered on a parent row. Presented
/// inline when children exist; tapping it opens the family's shared subtask
/// panel (the click/keyboard/VoiceOver alternative to hover).
struct SubtaskRowSummary: Equatable {
    let done: Int
    let total: Int
}

struct TaskRowView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var subtaskPanels: SubtaskPanelController
    let task: TaskItem
    var subtaskSummary: SubtaskRowSummary? = nil
    /// True while the family's auxiliary surface (transient or pinned) is
    /// presenting this row's checklist — keeps a soft highlight so the open
    /// panel reads as anchored to the row.
    var isFamilyPresented = false
    /// True while the family's PINNED window is up — the count control then
    /// raises (never hides) so its label and selection state stay truthful.
    var isFamilyPinned = false

    @State private var isHovering = false
    @State private var isDropTargeted = false
    @FocusState private var isRenameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
    @Environment(\.atticPanelThemePalette) private var palette

    private var isEditing: Bool { uiState.editingTaskID == task.id }
    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(get: { uiState.confirmingTaskDeletionID == task.id },
                set: { if !$0, uiState.confirmingTaskDeletionID == task.id { uiState.confirmingTaskDeletionID = nil } })
    }

    var body: some View {
        HStack(spacing: 12) {
            TaskStatusButton(status: task.status, priority: task.priority) {
                store.performPrimaryAction(task)
            }
            .accessibilityIdentifier("complete-task-\(task.id.uuidString)")

            Group {
                if isEditing {
                    TextField("Task title", text: $uiState.editingDraftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($isRenameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .accessibilityIdentifier("edit-task-title-\(task.id.uuidString)")
                } else {
                    Text(task.title)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .strikethrough(task.status == .done, color: .secondary)
                        .foregroundStyle(task.status == .done
                            ? palette.secondaryForegroundColor : palette.primaryForegroundColor)
                        .accessibilityLabel(task.title)
                }
            }
            .font(.system(size: 14, weight: task.status == .inProgress ? .medium : .regular, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
            .atticClearGlassForegroundReadability()

            if let subtaskSummary {
                subtaskCountButton(summary: subtaskSummary)
            }

            trailingAction
        }
        .padding(.vertical, 4)
        .frame(minHeight: 42)
        .padding(.horizontal, 8)
        .background(
            isDropTargeted
                ? Color.accentColor.opacity(0.08)
                : Color.primary.opacity(isHovering || isFamilyPresented ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: handleDoubleClick)
        .help(progressToggleHelp)
        .contextMenu { taskActions }
        .alert("Delete task and subtasks?", isPresented: isDeleteConfirmationPresented) {
            Button("Delete all", role: .destructive) { store.delete(task) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes “\(task.title)” and its \(store.subtasks(of: task.id).count) subtasks.")
        }
        .draggable(TaskDragPayload(taskID: task.id, title: task.title)) {
            dragPreview
        }
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
            guard let draggedTaskID = payloads.first?.taskID else {
                return false
            }
            uiState.endDragging()
            return store.drop(taskID: draggedTaskID, onto: task.id)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
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

    private func subtaskCountButton(summary: SubtaskRowSummary) -> some View {
        Button {
            subtaskPanels.toggleFamilyPanel(for: task.id)
        } label: {
            Text("\(summary.done)/\(summary.total)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
                .padding(.horizontal, 6)
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TaskSubtaskControlFramePreferenceKey.self,
                    value: [task.id: proxy.frame(
                        in: .named(AtticPanelCoordinateSpaceName.taskWorkspace)
                    )]
                )
            }
        }
        .help(countControlLabel)
        .accessibilityLabel(countControlLabel)
        .accessibilityValue("\(summary.done) of \(summary.total) complete")
        .accessibilityIdentifier("subtask-progress-\(task.id.uuidString)")
        .accessibilityAddTraits(
            isFamilyPresented && !isFamilyPinned ? .isSelected : []
        )
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
        } else {
            Menu {
                taskActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Edit task")
            .accessibilityLabel("Edit task")
            .accessibilityIdentifier("task-actions-\(task.id.uuidString)")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var taskActions: some View {
        if task.parentID == nil {
            if !store.subtasks(of: task.id).isEmpty {
                Button("Show subtasks", systemImage: "list.bullet.indent") {
                    subtaskPanels.openFamilyPanel(for: task.id, focusEntry: false)
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
        }) {
            uiState.beginEditing(task)
        }
    }

    private func commitRename() {
        if store.rename(task, to: uiState.editingDraftTitle) {
            uiState.endEditing()
        }
    }

    private func cancelRename() {
        uiState.endEditing()
    }

    private func handleDoubleClick() {
        guard !isEditing else { return }
        store.performDoubleClickAction(task)
    }

    private var countControlLabel: String {
        if isFamilyPinned { return "Reveal pinned subtasks" }
        return isFamilyPresented ? "Hide subtasks" : "Show subtasks"
    }

    private var progressToggleHelp: String {
        task.status.doubleClickTitle
    }
}
