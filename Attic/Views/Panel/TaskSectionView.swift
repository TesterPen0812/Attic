import SwiftUI

struct TaskSectionView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var subtaskPanels: SubtaskPanelController
    let status: TaskStatus
    let tasks: [TaskItem]

    @State private var isDropTargeted = false
    @State private var completionDropID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled
    @Environment(\.atticPanelThemePalette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Text("\(status.title) · \(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(clearReadabilityEnabled ? Color.primary.opacity(0.84) : palette.secondaryForegroundColor)
                    .atticClearGlassForegroundReadability()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("task-section-\(status.rawValue)")
                Spacer()
            }
            .frame(height: 22)
            .padding(.horizontal, 8)
            .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                acceptSectionDrop(payloads)
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }

            if !tasks.isEmpty {
                VStack(spacing: 3) {
                    ForEach(tasks) { task in
                        TaskFamilyView(
                            store: store,
                            uiState: uiState,
                            subtaskPanels: subtaskPanels,
                            task: task
                        )
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .scale(scale: 0.96).combined(with: .opacity)
                                )
                            )
                    }
                }
            }
        }
        .background(
            Color.accentColor.opacity(isDropTargeted ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .alert("Complete this task?", isPresented: Binding(
            get: { completionDropID != nil }, set: { if !$0 { completionDropID = nil } }
        )) {
            Button("Complete anyway") {
                if let id = completionDropID { _ = store.drop(taskID: id, into: .done, allowingUnfinishedSubtasks: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some subtasks are unfinished. They will stay unfinished if you complete this task.")
        }
        .onChange(of: completionDropID) { _, value in uiState.confirmingTaskCompletionID = value }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isDropTargeted)
        .animation(reduceMotion ? nil : AtticMotion.spring, value: tasks.map(\.id))
    }

    private func acceptSectionDrop(_ payloads: [TaskDragPayload]) -> Bool {
        guard let draggedTaskID = payloads.first?.taskID else {
            return false
        }
        uiState.endDragging()
        if status == .done,
           let source = store.tasks.first(where: { $0.id == draggedTaskID }), source.status != .done,
           store.subtasks(of: draggedTaskID).contains(where: { $0.status != .done }) {
            completionDropID = draggedTaskID
            return true
        }
        return store.drop(taskID: draggedTaskID, into: status)
    }
}
