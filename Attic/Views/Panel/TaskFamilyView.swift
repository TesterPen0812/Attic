import SwiftUI

/// A compact parent row: checkbox, title, an inline `done/total` control when
/// the family has children, and the shared actions menu. Child details live
/// in the auxiliary hover/pinned surface owned by `subtaskPanels`; this view
/// only reports hover and publishes its anchor frame to that controller.
struct TaskFamilyView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var subtaskPanels: SubtaskPanelController
    let task: TaskItem

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var children: [TaskItem] { store.subtasks(of: task.id) }
    private var summary: SubtaskRowSummary? {
        guard !children.isEmpty else { return nil }
        return SubtaskRowSummary(
            done: children.filter { $0.status == .done }.count,
            total: children.count
        )
    }

    /// Hover reporting is worth installing only when a panel could appear:
    /// a family with children, or one holding an in-flight draft entry.
    private var canPresentPanel: Bool {
        !children.isEmpty
            || !(uiState.subtaskDrafts[task.id] ?? "").isEmpty
    }

    private var isFamilyPresented: Bool {
        subtaskPanels.transientFamilyID == task.id
            || subtaskPanels.pinnedFamilyID == task.id
    }

    var body: some View {
        TaskRowView(
            store: store,
            uiState: uiState,
            subtaskPanels: subtaskPanels,
            task: task,
            subtaskSummary: summary,
            isFamilyPresented: isFamilyPresented
        )
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
        .onHover { hovering in
            // Gate entry, not exit: an already-open surface must keep
            // receiving leave events even if the family loses its last child.
            guard hovering == false || canPresentPanel else { return }
            subtaskPanels.noteRowHover(familyID: task.id, isHovering: hovering)
        }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isFamilyPresented)
    }
}
