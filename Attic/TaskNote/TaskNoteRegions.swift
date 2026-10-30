import SwiftUI

/// The geometry of the item page (mockups `p3-20` 2b, `p3-21`; the subtasks
/// in draft B, owner 2026-10-23). Everything sits on the note's text column.
enum TaskNoteMetrics {
    /// The status circle's column: the title starts where a Tasks row's
    /// does, the circle plus spacing B's circle-to-title gap (15 + 8 = 23;
    /// was 16 + 12 = 28 before Attic Rows, owner 2026-10-20).
    static let titleIndent: CGFloat = AtticControlSize.statusCircle + AtticLayout.circleToTitle
    /// Room at the end of the title's lines for the note's ⋯.
    static let titleTrailing: CGFloat = 26
    static let titleLineHeight: CGFloat = 22
    static let detailsGap: CGFloat = 4
    static let detailsHeight: CGFloat = 16
    static let detailsSpacing: CGFloat = 12
    /// Head to the subtasks (draft B: 10).
    static let headToBlock: CGFloat = 10
    /// The list's last line to the writing (draft B: 12).
    static let blockToWriting: CGFloat = 12
    /// The quiet "Subtasks · n/m" label's line.
    static let blockHeader: CGFloat = 28
    /// "Its note is in Recently Deleted · Restore Note" under the block.
    static let noticeHeight: CGFloat = 34
    /// Rows in the Tasks list's rhythm: a 28 pt pitch for one-line rows.
    static let rowHeight: CGFloat = AtticLayout.subtaskPitch
    /// The rows' box column is the head's status-circle column (the 13 pt
    /// box centred in 15), so the text starts on the title's line (x 47 on
    /// the 24 pt content line), the Tasks title column.
    static let boxColumn: CGFloat = AtticControlSize.statusCircle
    static var rowTextIndent: CGFloat { boxColumn + AtticSubtaskMetrics.titleGap }
}

// MARK: - The head

/// The live task head (§ 2.2 item 1): the status circle, the task's title
/// (17 pt bold, wrapping; Tasks' title editor), the priority mark, the
/// note's ⋯, then the details line (date, tags).
struct TaskNoteHeadView: View {
    @ObservedObject var model: TaskNotePageModel
    var openNoteMenu: () -> Void = {}
    /// The task's menu (right-click the head, ⇧⌘I): § 5.5.
    var taskMenu: () -> [AtticMenuCommand] = { [] }

    @Environment(\.atticDesign) private var design
    @Environment(\.undoManager) private var undoManager
    @FocusState private var titleFocused: Bool

    var body: some View {
        let head = model.head
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                titleLine(head)
                    .padding(.leading, TaskNoteMetrics.titleIndent)
                    .padding(.trailing, TaskNoteMetrics.titleTrailing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if head.exists {
                    AtticStatusButton(state: head.state, priority: head.priority,
                                      subtasks: head.subtasks.total > 0 ? head.subtasks : nil,
                                      isDisabled: !head.exists) {
                        model.toggleTask()
                    }
                    // The circle's centre on the first line's centre.
                    .offset(x: AtticControlSize.statusCircle / 2 - AtticControlSize.minimumHitTarget / 2,
                            y: TaskNoteMetrics.titleLineHeight / 2 - AtticControlSize.minimumHitTarget / 2)
                    .accessibilityIdentifier("task-note-status")
                } else {
                    // Task deleted (`p3-22` row 1): no circle, a quiet bin.
                    AtticIcon(systemName: "trash", size: 13, weight: .medium, ink: .helper)
                        .frame(width: AtticControlSize.statusCircle, height: TaskNoteMetrics.titleLineHeight)
                        .accessibilityHidden(true)
                }
                AtticNoteMenuButton { openNoteMenu() }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .offset(x: 4, y: -1)
                    .accessibilityIdentifier("task-note-menu")
            }
            if !head.exists {
                deletedLine
                    .padding(.top, TaskNoteMetrics.detailsGap)
                    .padding(.leading, TaskNoteMetrics.titleIndent)
            } else if head.due != nil || !head.tags.isEmpty {
                details(head)
                    .padding(.top, TaskNoteMetrics.detailsGap)
                    .padding(.leading, TaskNoteMetrics.titleIndent)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { if head.exists { AtticMenuItems(commands: taskMenu()) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenSummary(head))
        .accessibilityIdentifier("task-note-head")
        .onChange(of: model.focusRequestCount) { _, _ in
            if model.focusRequest == .title {
                model.beginEditingTitle(undoManager: undoManager)
                titleFocused = true
            }
        }
    }

    @ViewBuilder
    private func titleLine(_ head: TaskNotePageModel.Head) -> some View {
        if model.isEditingTitle {
            AtticRowTitleEditor(editing: titleEditing)
                .font(Font(AtticTextStyle.noteTitle.nsFont))
                .accessibilityIdentifier("task-note-title-editor")
        } else {
            // The title wraps and is never truncated; the mark follows its
            // last word.
            let title = Text(verbatim: head.title)
                .font(Font(AtticTextStyle.noteTitle.nsFont))
                .foregroundColor(design.tokens.color(head.state == .done ? .helper : .heading))
            Text("\(title)\(priorityText(head.priority))")
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: TaskNoteMetrics.titleLineHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { if head.exists { model.beginEditingTitle(undoManager: undoManager) } }
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .accessibilityLabel(head.title)
                .accessibilityAction(named: Text("Edit Title")) { model.beginEditingTitle(undoManager: undoManager) }
                .accessibilityIdentifier("task-note-title")
        }
    }

    /// "Task deleted · Restore" (`p3-22` row 1, column 4).
    private var deletedLine: some View {
        HStack(spacing: 6) {
            AtticText("Task deleted", style: .rowMeta, ink: .helper)
            AtticText(verbatim: "·", style: .rowMeta, ink: .helper)
            Button(String(localized: "Restore")) { model.restoreTask() }
                .buttonStyle(.plain)
                .font(Font(AtticTextStyle.rowMeta.nsFont).weight(.semibold))
                .foregroundStyle(design.tokens.color(.heading))
                .accessibilityLabel(String(localized: "Restore Task"))
                .accessibilityIdentifier("task-note-restore-task")
        }
        .frame(height: TaskNoteMetrics.detailsHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-note-deleted")
    }

    private func priorityText(_ priority: AtticPriority) -> Text {
        let mark: String
        let ink: AtticInk
        switch priority {
        case .high: mark = "!!"; ink = .priorityMark
        case .medium: mark = "!"; ink = .helper
        case .low: mark = "↓"; ink = .helper
        case .none: return Text("")
        }
        return Text(verbatim: "  " + mark)
            .font(Font(AtticTextStyle.priorityMark.nsFont).weight(.bold))
            .foregroundColor(design.tokens.color(ink))
            .baselineOffset(1)
    }

    private func details(_ head: TaskNotePageModel.Head) -> some View {
        HStack(spacing: TaskNoteMetrics.detailsSpacing) {
            if let due = head.due { AtticDueText(due: due) }
            ForEach(head.tags, id: \.self) { tag in
                AtticText(verbatim: "#" + tag, style: .rowMeta, ink: .helper)
            }
        }
        .frame(height: TaskNoteMetrics.detailsHeight, alignment: .leading)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-note-details")
    }

    private var titleEditing: AtticTitleEditing {
        AtticTitleEditing(
            text: Binding(get: { model.titleEdit.text }, set: { model.titleEdit.text = $0 }),
            commit: { model.commitTitle() },
            cancel: { model.cancelTitle() },
            tokens: AtticTitleEditing.Tokens(
                chips: model.titleEdit.tokenChips(parser: model.parser, caret: model.titleEditCaret),
                dismissChip: { range in model.dismissTitleChip(range) },
                edited: { range, replacement in model.titleEdited(range, replacement: replacement) },
                caretMoved: { caret in
                    if model.titleEditCaret != caret { model.titleEditCaret = caret }
                    var shown = model.titleEdit
                    if shown.markShown(parser: model.parser, caret: caret) { model.titleEdit = shown }
                },
                // The field's own draft first, then the workspace's history.
                undoDraft: { model.undoTitleDraft() },
                redoDraft: { model.redoTitleDraft() },
                selectionMoved: { model.titleEditSelection = $0 },
                undoFallback: { model.undoWorkspace() },
                redoFallback: { model.redoWorkspace() },
                admitEdit: { model.admitFieldInput() }
            ),
            accessibilityLabel: String(localized: "Title"))
    }

    /// "Finalize launch checklist, in progress, high priority, due today" (§ 8).
    private func spokenSummary(_ head: TaskNotePageModel.Head) -> String {
        var parts = [head.title]
        guard head.exists else { return parts.joined() + ", " + String(localized: "task deleted") }
        parts.append(head.state.spokenName)
        if let priority = head.priority.spokenName { parts.append(priority) }
        if let due = head.due { parts.append(String(localized: "due \(due.text)")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The Subtasks block

/// Draft B (owner, 2026-10-23): a quiet "Subtasks · 4/10" label, the first
/// three subtasks as compact rows in the Tasks list's rhythm, then "N more…"
/// (expanded: every row, "+ Add subtask" and "Show less"). No card. With
/// 0–3 subtasks, Add subtask follows the rows.
///
/// Keys (§ 7): the list is one Tab stop (a roving focus: only the current
/// row is focusable, so exactly one row is focused for VoiceOver too); ↑↓
/// move it among the rows on screen, Space ticks, Return renames (Return
/// saves), ⌘↑↓ reorder within the group, ⌫ deletes (Undo). Tab goes on to
/// Add subtask and "N more…" / "Show less" when shown, then the writing.
struct TaskNoteSubtasksBlock: View {
    @ObservedObject var model: TaskNotePageModel
    /// Restore Note (§ 5.6), shown while the task's note is in Recently
    /// Deleted.
    var restoreNote: () -> Void = {}
    /// A row's menu (right-click), from the page.
    var subtaskMenu: (UUID) -> [AtticMenuCommand] = { _ in [] }
    /// S10's Review: Merge into This Note, Keep as Separate Note.
    var reviewAlternate: () -> [AtticMenuCommand] = { [] }
    /// Earlier files' menu: Move into Note, then each file's actions.
    var earlierFiles: () -> [AtticMenuCommand] = { [] }

    /// What has the keyboard inside the block.
    enum Field: Hashable { case row(UUID), add, more }

    @Environment(\.atticDesign) private var design
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            label
            list
                .disabled(isSnapshot)
            if model.showsAddRow { addRow }
            if model.showsDisclosure { disclosure }
            if model.deletedNote { deletedNoteLine }
            if !model.alternateNotes.isEmpty { alternateNoteLine }
            if !model.earlierFiles.earlier.isEmpty || model.earlierFiles.refusal != nil { earlierFilesLine }
        }
            // The native host commits the arithmetic block height at once.
            // A SwiftUI transition would animate inside that final frame,
            // briefly centering/emptying the rows.
            .animation(nil, value: model.isExpanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onHover(perform: pointerMoved)
            .onChange(of: focus, focusMoved)
            .onChange(of: model.focusRequestCount, focusRequested)
            .onChange(of: model.focusedRowID, ringMoved)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.spokenGroup)
            .accessibilityActions {
                if let name = model.disclosureActionName {
                    Button(name) { toggleExpanded() }
                }
            }
            .accessibilityIdentifier("task-note-subtasks")
    }

    /// `p3-22` row 2, column 4: the note went to Recently Deleted; the
    /// task works as before.
    private var deletedNoteLine: some View {
        HStack(spacing: 6) {
            AtticText("Its note is in Recently Deleted", style: .rowMeta, ink: .helper)
            AtticText(verbatim: "·", style: .rowMeta, ink: .helper)
            Button(String(localized: "Restore Note"), action: restoreNote)
                .buttonStyle(.plain)
                .font(Font(AtticTextStyle.rowMeta.nsFont).weight(.semibold))
                .foregroundStyle(design.tokens.color(.heading))
                .accessibilityIdentifier("task-note-restore-note")
        }
        .frame(height: TaskNoteMetrics.noticeHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-note-deleted-note")
    }

    /// S10: another note claims this task. Nothing merges by itself; the
    /// person reviews it here.
    private var alternateNoteLine: some View {
        HStack(spacing: 6) {
            AtticText(model.alternateNotes.count == 1 ? "Another note for this task" : "Other notes for this task",
                      style: .rowMeta, ink: .helper)
            AtticText(verbatim: "·", style: .rowMeta, ink: .helper)
            Menu {
                AtticMenuItems(commands: reviewAlternate())
            } label: {
                Text(String(localized: "Review"))
                    .font(Font(AtticTextStyle.rowMeta.nsFont).weight(.semibold))
                    .foregroundStyle(design.tokens.color(.heading))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("task-note-review-alternate")
        }
        .frame(height: TaskNoteMetrics.noticeHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-note-alternate-note")
    }

    /// § 5.6 "Migration incomplete": "Earlier files · 3 · the note would
    /// exceed 20 files", with the files and Move into Note in its menu.
    private var earlierFilesLine: some View {
        let status = model.earlierFiles
        return HStack(spacing: 6) {
            Menu {
                AtticMenuItems(commands: earlierFiles())
            } label: {
                Text(String(localized: "Earlier files · \(status.earlier.count)"))
                    .font(Font(AtticTextStyle.rowMeta.nsFont).weight(.semibold))
                    .foregroundStyle(design.tokens.color(.heading))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("task-note-earlier-files-menu")
            if let reason = status.refusal?.reason ?? (status.kind == .legacy ? String(localized: "not moved into the note yet") : nil) {
                AtticText(verbatim: "·", style: .rowMeta, ink: .helper)
                AtticText(verbatim: reason, style: .rowMeta, ink: .helper, truncates: true)
            }
        }
        .frame(height: TaskNoteMetrics.noticeHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-note-earlier-files")
    }

    /// A deleted task's subtasks are a read-only snapshot "as it was".
    private var isSnapshot: Bool { !model.head.exists }

    private func pointerMoved(_ inside: Bool) { model.setPointerInside(inside) }

    private func focusMoved(_ old: Field?, _ new: Field?) {
        if case let .row(id)? = new {
            if model.focusedRowID != id { model.focusedRowID = id }
            model.noteRowFocused(id)
        }
        model.setFocusInside(new != nil)
    }

    private func focusRequested(_ old: UInt64, _ new: UInt64) { followFocusRequest() }

    /// Arrows move the ring: the keyboard goes with it while the list has it.
    private func ringMoved(_ old: UUID?, _ new: UUID?) {
        guard case .row? = focus, let new else { return }
        focus = .row(new)
    }

    private func followFocusRequest() {
        guard let region = model.focusRequest else { return }
        switch region {
        case .list: focus = model.listEntryRowID.map(Field.row)
        case .add: focus = .add
        case .more: focus = .more
        case .title: focus = nil
        // AppKit's first-responder change takes SwiftUI's focus away; setting
        // it here would race the text view and win (CU P1).
        case .writing: break
        }
    }

    /// Tab and ⇧Tab inside the block follow the model's order.
    private func tab(from region: TaskNotePageModel.Region, backwards: Bool) {
        switch model.tabTarget(from: region, backwards: backwards) {
        case .add: focus = .add
        case .more: focus = .more
        case .writing: model.focusWriting(atTop: true)
        case .list: model.requestFocus(.list)
        case .title: model.requestFocus(.title)
        }
    }

    // MARK: The label and "N more…"

    /// p3-20/p3-21: the label is quiet secondary text, lighter than the
    /// rows, on the content line. VoiceOver hears it as the group's name.
    private var label: some View {
        AtticText(verbatim: isSnapshot ? model.countLabel + " · " + String(localized: "as it was") : model.countLabel,
                  style: .rowMeta, ink: .helper)
            .frame(height: TaskNoteMetrics.blockHeader, alignment: .leading)
            .accessibilityHidden(true)
            .accessibilityIdentifier("task-note-subtasks-label")
    }

    /// "5 more…" / "Show less" on the text column (draft B: 12.5 medium,
    /// helper ink). A Tab stop, so Full Keyboard Access reaches it.
    private var disclosure: some View {
        let ringed = keyboardFocusVisible && focus == .more
        return Button(action: toggleExpanded) {
            AtticText(verbatim: model.disclosureLabel, style: .controlLabel, ink: .helper)
                .frame(height: TaskNoteMetrics.rowHeight)
                .background { ring(ringed, height: TaskNoteMetrics.rowHeight) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .focused($focus, equals: .more)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .tab:
                tab(from: .more, backwards: press.modifiers.contains(.shift))
                return .handled
            case .space, .return:
                toggleExpanded()
                return .handled
            default:
                return .ignored
            }
        }
        .padding(.leading, TaskNoteMetrics.rowTextIndent)
        .accessibilityLabel(model.disclosureSpokenLabel)
        .accessibilityIdentifier("task-note-subtasks-more")
    }

    private func toggleExpanded() {
        let wasFocused = focus == .more
        model.toggleExpanded()
        // The control moves with the list's end; the keyboard stays on it.
        if wasFocused { focus = .more }
    }

    // MARK: Rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.visibleRows) { row in
                rowView(row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-note-subtask-list")
    }

    private func rowView(_ row: TaskNotePageModel.Row) -> some View {
        let current: Bool = model.listEntryRowID == row.id
        let focused: Bool = focus == .row(row.id)
        let ringed: Bool = keyboardFocusVisible && focused && model.renamingID == nil
        let value: String = row.isDone ? String(localized: "completed") : String(localized: "not completed")
        let focusable: Bool = current && model.renamingID == nil
        let line = rowLine(row)
            .frame(height: TaskNoteMetrics.rowHeight)
            .background(alignment: .leading) { rowRing(ringed) }
            .contentShape(Rectangle())
            .focusable(focusable)
            .focused($focus, equals: .row(row.id))
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in rowKey(press, row: row.id) }
            .onTapGesture { select(row.id) }
            .contextMenu { AtticMenuItems(commands: subtaskMenu(row.id)) }
            .id(row.id)
        return rowAccessibility(line, row: row, value: value)
    }

    private func rowAccessibility(_ line: some View, row: TaskNotePageModel.Row, value: String) -> some View {
        line
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.title)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(value)
            .accessibilityAction { model.toggle(row.id) }
            .accessibilityAction(named: Text("Rename")) { model.beginRename(row.id, undoManager: undoManager) }
            .accessibilityAction(named: Text("Delete Subtask")) { model.delete(row.id) }
            .accessibilityAction(named: Text("Make Checkbox")) {
                subtaskMenu(row.id).first { $0.identifier == "task-note-subtask-make-checkbox" }?.action()
            }
            .accessibilityIdentifier("task-note-subtask-row")
    }

    private func rowLine(_ row: TaskNotePageModel.Row) -> some View {
        HStack(spacing: AtticSubtaskMetrics.titleGap) {
            checkbox(row)
            rowTitle(row)
            Spacer(minLength: 0)
        }
    }

    /// The 13 pt box centred in the 15 pt circle column; the 28 pt hit area
    /// around it.
    private func checkbox(_ row: TaskNotePageModel.Row) -> some View {
        let inset: CGFloat = -(AtticSubtaskMetrics.hitSize - TaskNoteMetrics.boxColumn) / 2
        return Button { model.toggle(row.id) } label: {
            AtticSubtaskCheckbox(isDone: row.isDone)
                .frame(width: AtticSubtaskMetrics.hitSize, height: AtticSubtaskMetrics.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(.horizontal, inset)
    }

    @ViewBuilder
    private func rowTitle(_ row: TaskNotePageModel.Row) -> some View {
        if model.renamingID == row.id {
            AtticRowTitleEditor(editing: renameEditing)
        } else {
            // Done rows are quiet, without a strikethrough (the mockups).
            AtticText(verbatim: row.title, style: .listBody, ink: row.isDone ? .helper : .body, truncates: true)
        }
    }

    /// The rename field: plain text (no chips), with its own draft Undo.
    private var renameEditing: AtticTitleEditing {
        AtticTitleEditing(
            text: Binding(get: { model.renameEdit.text }, set: { model.renameEdit.text = $0 }),
            commit: { commitRename() },
            cancel: { cancelRename() },
            tokens: AtticTitleEditing.Tokens(
                chips: [],
                dismissChip: { _ in },
                edited: { range, replacement in model.renameEdited(range, replacement: replacement) },
                caretMoved: { _ in },
                undoDraft: { model.undoRenameDraft() },
                redoDraft: { model.redoRenameDraft() },
                undoFallback: { model.undoWorkspace() },
                redoFallback: { model.redoWorkspace() },
                admitEdit: { model.admitFieldInput() }
            ),
            accessibilityLabel: String(localized: "Rename subtask"))
    }

    private func commitRename() -> Bool {
        let id = model.renamingID
        let saved = model.commitRename()
        if saved, let id { focus = .row(id) }
        return saved
    }

    private func cancelRename() {
        let id = model.renamingID
        model.cancelRename()
        if let id { focus = .row(id) }
    }

    private func rowRing(_ ringed: Bool) -> some View { ring(ringed, height: TaskNoteMetrics.rowHeight) }

    @ViewBuilder
    private func ring(_ ringed: Bool, height: CGFloat) -> some View {
        if ringed {
            Color.clear
                .atticFocusRing(true, cornerRadius: AtticRadius.control(height: height - 4))
                .padding(.horizontal, -6)
                .padding(.vertical, 2)
        }
    }

    private func select(_ id: UUID) {
        model.focusedRowID = id
        focus = .row(id)
    }

    private func rowKey(_ press: KeyPress, row id: UUID) -> KeyPress.Result {
        guard model.renamingID == nil else { return .ignored }
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .upArrow:
            if command { model.move(id, by: -1) } else { model.moveRing(by: -1) }
            return .handled
        case .downArrow:
            if command { model.move(id, by: 1) } else { model.moveRing(by: 1) }
            return .handled
        case .space:
            model.toggle(id)
            return .handled
        case .return:
            model.beginRename(id, undoManager: undoManager)
            return .handled
        case .delete, .deleteForward:
            model.delete(id)
            return .handled
        case .tab:
            tab(from: .list, backwards: press.modifiers.contains(.shift))
            return .handled
        default:
            if press.characters == "\u{7F}" || press.characters == "\u{8}" {
                model.delete(id)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: Add subtask

    private var addRow: some View {
        HStack(spacing: AtticSubtaskMetrics.titleGap) {
            AtticIcon(systemName: "plus", size: 11, weight: .medium, ink: .helper)
                .frame(width: TaskNoteMetrics.boxColumn)
            TaskNoteAddField(model: model, focused: Binding(get: { focus == .add }, set: { focus = $0 ? .add : nil }),
                color: NSColor(design.tokens.color(.body)), submit: submitAdd, tab: { tab(from: .add, backwards: $0) })
        }
        .frame(height: TaskNoteMetrics.rowHeight)
    }

    private func submitAdd() {
        let leaving = model.newSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _ = model.commitNewSubtask()
        if !leaving { focus = .add }
    }

    /// Tab: "Show less" when shown, else the writing, with a caret and no
    /// ring (§ 7). ⇧Tab: back to the list (or the title with no rows).
}

/// A one-line native field with admission before mutation. It adds no
/// scroll view to the composed page and retains AppKit's field draft Undo.
struct TaskNoteAddField: NSViewRepresentable {
    let model: TaskNotePageModel
    @Binding var focused: Bool
    let color: NSColor
    let submit: () -> Void
    let tab: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = AtticSubtaskTitleField.makeField()
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.font = AtticTextStyle.listBody.nsFont
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("task-note-add-subtask")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let label = String(localized: "Add subtask")
        field.textColor = color; field.placeholderString = label; field.setAccessibilityLabel(label)
        if field.stringValue != model.newSubtaskText { field.stringValue = model.newSubtaskText }
        var editing = AtticTitleEditing(text: Binding(get: { model.newSubtaskText }, set: { model.editNewSubtask($0) }),
            commit: { model.commitNewSubtask() }, cancel: { model.cancelNewSubtask() })
        editing.admitEdit = { model.admitFieldInput() }
        let editor = (field.cell as? AtticSubtaskTitleCell)?.editor
        editor?.editing = editing; editor?.allowsUndo = true
        if focused, field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard coordinator?.parent.focused == true, let field, let window = field.window,
                      window.isKeyWindow, !field.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(field)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskNoteAddField
        init(_ parent: TaskNoteAddField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.focused { parent.focused = false }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.model.editNewSubtask(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if command == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.model.cancelNewSubtask(); return true }
            if command == #selector(NSResponder.insertTab(_:)) { parent.tab(false); return true }
            if command == #selector(NSResponder.insertBacktab(_:)) { parent.tab(true); return true }
            return false
        }
    }
}
