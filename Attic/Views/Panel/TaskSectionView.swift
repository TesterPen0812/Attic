import SwiftUI

struct TaskSectionView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    let status: TaskStatus
    let tasks: [TaskItem]
    let showsEmptyDropZone: Bool

    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !tasks.isEmpty || showsEmptyDropZone {
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Text("\(status.title) · \(tasks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("task-section-\(status.rawValue)")
                        Spacer()
                    }
                    .frame(height: 24)
                    .padding(.horizontal, 4)
                    .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                        acceptSectionDrop(payloads)
                    } isTargeted: { isTargeted in
                        isDropTargeted = isTargeted
                    }

                    if tasks.isEmpty {
                        dropPlaceholder
                    } else {
                        VStack(spacing: AtticStyle.taskSpacing) {
                            ForEach(tasks) { task in
                                TaskRowView(store: store, uiState: uiState, task: task)
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
                .animation(reduceMotion ? nil : AtticMotion.quick, value: isDropTargeted)
                .animation(reduceMotion ? nil : AtticMotion.spring, value: tasks.map(\.id))
            }
        }
    }

    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(Color.secondary.opacity(isDropTargeted ? 0.6 : 0.3))
            .frame(height: AtticStyle.rowHeight)
            .overlay(
                Text("Drop here")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            )
            .padding(.horizontal, 4)
            .accessibilityIdentifier("task-section-drop-zone-\(status.rawValue)")
            .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                acceptSectionDrop(payloads)
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
    }

    private func acceptSectionDrop(_ payloads: [TaskDragPayload]) -> Bool {
        guard let draggedTaskID = payloads.first?.taskID else {
            return false
        }
        uiState.endDragging()
        return store.drop(taskID: draggedTaskID, into: status)
    }
}
