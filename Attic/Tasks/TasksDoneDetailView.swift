import SwiftUI

/// "Show Details" on a Done page row (Phase 1, until task pages exist):
/// its title, when it was finished, its date, priority and tags (L6), its
/// subtasks and the files it kept,
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
                // What the finished task still carries (L6): its row shows
                // none of it.
                if let metadata = detail.metadata {
                    AtticText(verbatim: metadata, style: .helper, ink: .helper, truncates: true)
                        .help(metadata)
                        .accessibilityIdentifier("tasks-done-detail-metadata")
                }
            }
            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
            .padding(.vertical, AtticSpacing.s8)
            if !detail.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(detail.subtasks) { subtask in
                        HStack(spacing: AtticSubtaskMetrics.titleGap) {
                            AtticSubtaskCheckbox(isDone: subtask.isDone)
                            AtticText(verbatim: subtask.title, style: .listBody, ink: .body, truncates: true)
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
