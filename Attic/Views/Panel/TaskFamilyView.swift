import SwiftUI

/// A compact parent row: checkbox, title, passive `done/total` progress when
/// the family has children, and the shared actions menu. Child details live
/// in the auxiliary transient/pinned surface owned by `subtaskPanels`; this
/// view only publishes its anchor frame to that controller. Hover is purely
/// visual (the row surface and its actions); opening the workspace is always
/// a deliberate action on the row.
struct TaskFamilyView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var subtaskPanels: SubtaskPanelController
    let task: TaskItem

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: SubtaskRowSummary? {
        let children = store.subtasks(of: task.id)
        guard !children.isEmpty else { return nil }
        return SubtaskRowSummary(
            done: children.reduce(0) { $0 + ($1.status == .done ? 1 : 0) },
            total: children.count
        )
    }

    private var isFamilyPresented: Bool {
        subtaskPanels.transientFamilyID == task.id
            || subtaskPanels.pinnedFamilyIDs.contains(task.id)
    }

    var body: some View {
        TaskRowView(
            store: store,
            uiState: uiState,
            subtaskPanels: subtaskPanels,
            task: task,
            subtaskSummary: summary,
            isFamilyPresented: isFamilyPresented,
            isFamilyPinned: subtaskPanels.pinnedFamilyIDs.contains(task.id),
            isEditing: uiState.editingTaskID == task.id,
            isConfirmingDeletion: uiState.confirmingTaskDeletionID == task.id,
            isImportingAttachments: store.importingAttachmentTaskIDs.contains(task.id)
        )
        .equatable()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TaskRowAnchorPreferenceKey.self,
                    value: [task.id: proxy.frame(
                        in: .named(AtticPanelCoordinateSpaceName.taskWorkspace)
                    )]
                )
            }
        }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isFamilyPresented)
    }
}
