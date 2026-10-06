import SwiftUI

/// The geometry of the task's note page (mockups `p3-20` 2b, `p3-21`, block
/// shape `p3-19` column 2). Everything sits on the note's text column.
enum TaskNoteMetrics {
    /// The status circle's column: the title starts 28 in.
    static let titleIndent: CGFloat = 28
    /// Room at the end of the title's lines for the note's ⋯.
    static let titleTrailing: CGFloat = 26
    static let titleLineHeight: CGFloat = 22
    static let detailsGap: CGFloat = 4
    static let detailsHeight: CGFloat = 16
    static let detailsSpacing: CGFloat = 12
    /// Head to the block: 12, plus the block's own 4 above it.
    static let headToBlock: CGFloat = 16
    /// The block to the writing.
    static let blockToWriting: CGFloat = 10
    static let blockHeader: CGFloat = 28
    static let blockBottomPadding: CGFloat = 10
    static let rowHeight: CGFloat = AtticLayout.subtaskPitch
    static var blockRadius: CGFloat { AtticRadius.groupCard }
    static var blockPadding: CGFloat { AtticSpacing.s12 }
}

// MARK: - The head

/// The live task head (§ 2.2 item 1): the status circle, the task's title
/// (17 pt bold, wrapping; Tasks' title editor), the priority mark, the
/// note's ⋯, then the details line (date, tags).
struct TaskNoteHeadView: View {
    @ObservedObject var model: TaskNotePageModel
    var openNoteMenu: () -> Void = {}

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
                AtticStatusButton(state: head.state, priority: head.priority,
                                  subtasks: head.subtasks.total > 0 ? head.subtasks : nil,
                                  isDisabled: !head.exists) {
                    model.toggleTask()
                }
                // The circle's centre on the first line's centre.
                .offset(x: AtticControlSize.statusCircle / 2 - AtticControlSize.minimumHitTarget / 2,
                        y: TaskNoteMetrics.titleLineHeight / 2 - AtticControlSize.minimumHitTarget / 2)
                .accessibilityIdentifier("task-note-status")
                AtticNoteMenuButton { openNoteMenu() }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .offset(x: 4, y: -1)
                    .accessibilityIdentifier("task-note-menu")
            }
            if head.due != nil || !head.tags.isEmpty {
                details(head)
                    .padding(.top, TaskNoteMetrics.detailsGap)
                    .padding(.leading, TaskNoteMetrics.titleIndent)
            }
        }
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
                .onTapGesture { model.beginEditingTitle(undoManager: undoManager) }
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .accessibilityLabel(head.title)
                .accessibilityAction(named: Text("Edit Title")) { model.beginEditingTitle(undoManager: undoManager) }
                .accessibilityIdentifier("task-note-title")
        }
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
                redoFallback: { model.redoWorkspace() }
            ),
            accessibilityLabel: String(localized: "Title"))
    }

    /// "Finalize launch checklist, in progress, high priority, due today" (§ 8).
    private func spokenSummary(_ head: TaskNotePageModel.Head) -> String {
        var parts = [head.title]
        parts.append(head.state.spokenName)
        if let priority = head.priority.spokenName { parts.append(priority) }
        if let due = head.due { parts.append(String(localized: "due \(due.text)")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The Subtasks block

/// "Subtasks · 4/10" with its disclosure chevron, the rows and "+ Add
/// subtask" (§ 2.2 item 2), block-shaped (`p3-19` column 2: radius 17, the
/// recessed fill, no border, 12 inside, a 28 pt header). Folded, it is one
/// line: "Subtasks · 4/10 ›".
///
/// Keys (§ 7): the list is one Tab stop (a roving focus: only the current
/// row is focusable, so exactly one row is focused for VoiceOver too); ↑↓
/// move it, Space ticks, Return renames (Return saves), ⌘↑↓ reorder within
/// the group, ⌫ deletes (Undo), Tab goes to Add subtask and from there to the
/// writing; → ← on the header unfold and fold.
struct TaskNoteSubtasksBlock: View {
    @ObservedObject var model: TaskNotePageModel

    /// What has the keyboard inside the block.
    enum Field: Hashable { case row(UUID), add }

    @Environment(\.atticDesign) private var design
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focus: Field?

    var body: some View {
        blockShape
            .onHover(perform: pointerMoved)
            .onChange(of: focus, focusMoved)
            .onChange(of: model.focusRequestCount, focusRequested)
            .onChange(of: model.focusedRowID, ringMoved)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spokenGroup)
            .accessibilityIdentifier("task-note-subtasks")
    }

    /// The block's shape (`p3-19` column 2): radius 17, the recessed fill;
    /// with Increase Contrast, the recessed hairline (§ 4).
    private var blockShape: some View {
        let shape = RoundedRectangle(cornerRadius: TaskNoteMetrics.blockRadius, style: .continuous)
        let fill: Color = design.tokens.recessed.color
        let edge: Color = design.tokens.recessedBorder?.color ?? .clear
        return content
            .padding(.horizontal, TaskNoteMetrics.blockPadding)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: design.tokens.recessedBorder == nil ? 0 : 1))
            .clipShape(shape)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.isFolded { rowsAndAdd }
        }
    }

    private var rowsAndAdd: some View {
        let transition: AnyTransition = design.reduceMotion ? .identity : .opacity
        return VStack(alignment: .leading, spacing: 0) {
            list
            addRow
        }
        .padding(.bottom, TaskNoteMetrics.blockBottomPadding)
        .transition(transition)
    }

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
        case .title: focus = nil
        // AppKit's first-responder change takes SwiftUI's focus away; setting
        // it here would race the text view and win (CU P1).
        case .writing: break
        }
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleFold) {
            HStack(spacing: AtticSpacing.s8) {
                // p3-20/p3-21: the label is quiet secondary text, lighter
                // than the rows.
                AtticText(verbatim: model.countLabel, style: .rowMeta, ink: .helper)
                Spacer(minLength: 0)
                AtticIcon(systemName: model.isFolded ? "chevron.right" : "chevron.down", size: 10, weight: .medium, ink: .helper)
            }
            .frame(height: TaskNoteMetrics.blockHeader)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { model.setFolded(false); return .handled }
        .onKeyPress(.leftArrow) { model.setFolded(true); return .handled }
        .accessibilityLabel(model.countLabel)
        .accessibilityValue(model.isFolded ? String(localized: "collapsed") : String(localized: "expanded"))
        .accessibilityHint(model.isFolded ? String(localized: "Shows the subtasks") : String(localized: "Hides the subtasks"))
        .accessibilityIdentifier("task-note-subtasks-header")
    }

    private func toggleFold() {
        let animation: Animation? = design.reduceMotion ? nil : AtticMotionPreset.expand.animation(reduceMotion: false)
        withAnimation(animation) { model.toggleFold(undoManager: undoManager) }
    }

    // MARK: Rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
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
            .accessibilityIdentifier("task-note-subtask-row")
    }

    private func rowLine(_ row: TaskNotePageModel.Row) -> some View {
        HStack(spacing: AtticSubtaskMetrics.titleGap) {
            checkbox(row)
            rowTitle(row)
            Spacer(minLength: 0)
        }
    }

    private func checkbox(_ row: TaskNotePageModel.Row) -> some View {
        let inset: CGFloat = -(AtticSubtaskMetrics.hitSize - AtticControlSize.subtaskCheckbox) / 2
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
                redoFallback: { model.redoWorkspace() }
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

    @ViewBuilder
    private func rowRing(_ ringed: Bool) -> some View {
        if ringed {
            Color.clear
                .atticFocusRing(true, cornerRadius: AtticRadius.control(height: TaskNoteMetrics.rowHeight - 4))
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
            if press.modifiers.contains(.shift) { model.requestFocus(.title) } else { focus = .add }
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
                .frame(width: AtticControlSize.subtaskCheckbox)
            TextField(String(localized: "Add subtask"), text: $model.newSubtaskText)
                .textFieldStyle(.plain)
                .font(Font(AtticTextStyle.listBody.nsFont))
                .focused($focus, equals: .add)
                .onSubmit(submitAdd)
                .onKeyPress(.tab, phases: .down, action: tabFromAdd)
                .accessibilityLabel(String(localized: "Add subtask"))
                .accessibilityIdentifier("task-note-add-subtask")
        }
        .frame(height: TaskNoteMetrics.rowHeight)
    }

    private func submitAdd() {
        let leaving = model.newSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        _ = model.commitNewSubtask()
        if !leaving { focus = .add }
    }

    /// Tab: the writing, with a caret and no ring (§ 7). ⇧Tab: back to the
    /// list (or the title with no rows).
    private func tabFromAdd(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) {
            model.requestFocus(model.rows.isEmpty ? .title : .list)
        } else {
            model.focusWriting(atTop: true)
        }
        return .handled
    }

    /// "Subtasks, 3 items, 1 completed" (§ 8).
    private var spokenGroup: String {
        let head = model.head
        return String(localized: "Subtasks, \(head.subtasks.total) items, \(head.subtasks.done) completed")
    }
}
