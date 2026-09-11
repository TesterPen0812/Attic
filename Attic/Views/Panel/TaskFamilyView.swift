import SwiftUI

/// One main task owns its indented steps; completed steps never jump to Done.
struct TaskFamilyView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    let task: TaskItem

    @FocusState private var isAddingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atticPanelThemePalette) private var palette

    private var children: [TaskItem] { store.subtasks(of: task.id) }
    private var isExpanded: Bool { uiState.expandedTaskIDs.contains(task.id) }
    private var canAdd: Bool {
        !(uiState.subtaskDrafts[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var draft: Binding<String> {
        Binding(get: { uiState.subtaskDrafts[task.id] ?? "" },
                set: { uiState.subtaskDrafts[task.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if !children.isEmpty || isExpanded {
                    Button(action: toggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.secondaryForegroundColor)
                            .frame(width: 24, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide subtasks" : "Show subtasks")
                    .accessibilityValue("\(children.filter { $0.status == .done }.count) of \(children.count) complete")
                    .accessibilityIdentifier("toggle-subtasks-\(task.id.uuidString)")
                }
                TaskRowView(store: store, uiState: uiState, task: task)
            }
            if !children.isEmpty {
                Text("\(children.filter { $0.status == .done }.count) of \(children.count) complete")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                    .padding(.leading, 64)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("subtask-progress-\(task.id.uuidString)")
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        TaskRowView(store: store, uiState: uiState, task: child)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(palette.secondaryForegroundColor.opacity(0.3))
                                    .frame(width: 12, height: 1)
                                    .offset(x: -16)
                                    .accessibilityHidden(true)
                            }
                    }
                    if task.status != .done {
                        subtaskEntry
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.secondaryForegroundColor.opacity(0.3))
                        .frame(width: 1)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 40)
                .padding(.bottom, 6)
            }
        }
        .onChange(of: uiState.focusedSubtaskParentID) { _, focusedID in
            isAddingFocused = focusedID == task.id
        }
        .onChange(of: isAddingFocused) { _, focused in
            if focused { uiState.focusedSubtaskParentID = task.id }
            else if uiState.focusedSubtaskParentID == task.id { uiState.focusedSubtaskParentID = nil }
        }
        .onAppear { isAddingFocused = uiState.focusedSubtaskParentID == task.id }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isExpanded)
    }

    private var subtaskEntry: some View {
        HStack(spacing: 8) {
            Button(action: addSubtask) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add subtask")
            .accessibilityIdentifier("add-subtask-\(task.id.uuidString)")
            .disabled(!canAdd)
            TextField("Add subtask…", text: draft)
                .textFieldStyle(.plain)
                .focused($isAddingFocused)
                .onSubmit(addSubtask)
                .onExitCommand { isAddingFocused = false }
                .accessibilityIdentifier("subtask-title-\(task.id.uuidString)")
        }
        .font(.system(size: 13, design: .rounded))
        .foregroundStyle(palette.secondaryForegroundColor)
        .atticClearGlassForegroundReadability()
        .padding(.horizontal, 8)
        .id("subtask-entry-\(task.id.uuidString)")
    }

    private func toggleExpanded() {
        if isExpanded {
            isAddingFocused = false
            uiState.expandedTaskIDs.remove(task.id)
        } else {
            uiState.expandedTaskIDs.insert(task.id)
        }
    }

    private func addSubtask() {
        guard store.create(title: uiState.subtaskDrafts[task.id] ?? "", parentID: task.id) != nil else { return }
        uiState.subtaskDrafts[task.id] = nil
        uiState.focusSubtaskEntry(for: task.id)
        isAddingFocused = true
    }
}
