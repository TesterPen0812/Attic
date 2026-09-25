import SwiftUI

/// "Open page" on a task in the Done log (Phase 1, until task pages exist):
/// its title, when it was finished, its subtasks and the files it kept,
/// read-only, with Restore to Now. The files open from Attic's private
/// storage, where they stay while the task is in the log.
struct TasksDoneDetailView: View {
    let detail: TasksPageModel.DoneDetail
    let store: TaskStore
    let restore: () -> Void

    var body: some View {
        AtticPopover(width: 260) {
            VStack(alignment: .leading, spacing: AtticSpacing.s4) {
                AtticText(verbatim: detail.title, style: .rowTitle, ink: .heading, truncates: true)
                AtticText(verbatim: detail.finished, style: .helper, ink: .helper)
            }
            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
            .padding(.vertical, AtticSpacing.s8)
            if !detail.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(detail.subtasks) { subtask in
                        HStack(spacing: AtticSubtaskMetrics.titleGap) {
                            AtticSubtaskCheckbox(isDone: subtask.isDone)
                            AtticText(verbatim: subtask.title, style: .body, ink: subtask.isDone ? .helper : .body,
                                      strikethrough: subtask.isDone, truncates: true)
                        }
                        .frame(height: AtticLayout.subtaskPitch)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                AtticPopoverGap()
            }
            ForEach(detail.files, id: \.id) { file in
                AtticPopoverRow(systemName: "paperclip", title: file.filename) {
                    TaskAttachmentActions.open(file, store: store)
                }
                .disabled(!TaskAttachmentActions.canOpen(file))
            }
            if !detail.files.isEmpty { AtticPopoverGap() }
            AtticPopoverRow(systemName: "arrow.uturn.backward", title: String(localized: "Restore to Now"), action: restore)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.title)
    }
}
