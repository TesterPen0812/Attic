import AppKit
import SwiftUI

// List Style: New, the row (FINAL § 2.1–2.9 and D1's column; picks 2A and
// 4A). SF Symbols and system fonts; geometry from `TasksNewMetrics`.

/// The ring (§ 2.7): an 18 pt ring, 1.5 pt stroke; a centre dot while in
/// progress; done, the accent ring with a filled centre and a white tick.
struct TasksNewRing: View {
    let state: AtticTaskState
    var size: CGFloat = TasksNewMetrics.ringSize
    var stroke: CGFloat = TasksNewMetrics.ringStroke
    var emphasised = false

    var body: some View {
        ZStack {
            if state == .done {
                Circle().strokeBorder(TasksNewInk.doneFill, lineWidth: stroke)
                Circle().fill(TasksNewInk.doneFill).padding(stroke + 1.6)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(emphasised ? TasksNewInk.secondary : TasksNewInk.ring, lineWidth: stroke)
                if state == .inProgress {
                    Circle().fill(TasksNewInk.ring)
                        .frame(width: TasksNewMetrics.progressDot, height: TasksNewMetrics.progressDot)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TasksNewRow: View {
    let model: AtticTaskRowModel
    var isSelected = false
    var listHasKeyboard = true
    var isExpanded = false
    let actions: AtticTaskActions
    let onToggleExpanded: () -> Void
    var onSelect: (() -> Void)? = nil
    var focus: AtticRowFocus? = nil
    var titleEditing: AtticTitleEditing? = nil
    var date: (text: String, tone: TasksNewText.Tone)? = nil
    /// Just ticked and kept in place (4A): the column shows Undo.
    var isKept = false
    /// Date, Move and ⓘ (not on Done).
    var actionsAvailable = true
    var moveToNow = false
    var onDate: (() -> Void)? = nil
    var onMove: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var onUndo: (() -> Void)? = nil
    var meta: AtticRowMeta? = nil

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @State private var hovered = false
    @State private var focused = false

    private typealias M = TasksNewMetrics

    var body: some View {
        let done = model.state == .done
        let rowFocused = focus?.isFocused ?? focused
        let ring = capture == nil && isEnabled && rowFocused && keyboardFocusVisible && titleEditing == nil
        let windowKey = activeState == .key || capture != nil
        let column = TasksNewColumn.resolve(isDone: done, isKept: isKept, isHovered: hovered && capture == nil,
                                            isKeyboardSelected: isSelected && listHasKeyboard && windowKey,
                                            hasDate: date != nil, actionsAvailable: actionsAvailable && titleEditing == nil)

        ZStack(alignment: .topLeading) {
            Button(action: actions.toggleDone) {
                TasksNewRing(state: model.state, emphasised: hovered || ring)
                    .frame(width: M.ringHit, height: M.ringHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, M.ringCentreX - M.ringHit / 2)
            .padding(.top, M.ringCentreY - M.ringHit / 2)
            .accessibilityLabel(done ? String(localized: "Mark as not done") : String(localized: "Complete"))

            VStack(alignment: .leading, spacing: 0) {
                titleLine(done: done)
                // A kept tick keeps its line 2: nothing moves (4A).
                if let details = detailsLine(done: done && !isKept) {
                    details
                        .frame(height: M.detailsLine, alignment: .leading)
                        .padding(.top, M.detailsTop - M.titleTop - M.titleLine)
                        .padding(.bottom, -1)
                }
            }
            .padding(.top, M.titleTop)
            .padding(.bottom, M.titleTop)
            .padding(.leading, M.titleX)
            .padding(.trailing, M.textTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The column: fixed, reserved on every row; what it shows takes
        // turns by paint alone.
        .overlay(alignment: .topTrailing) {
            columnView(column)
                .frame(width: M.columnWidth, height: M.columnHeight, alignment: .trailing)
                .atticDropdown(isPresented: meta?.datePresented ?? .constant(false), label: String(localized: "Date")) {
                    meta?.datePicker()
                }
                .padding(.top, M.columnTop)
                .padding(.trailing, M.columnTrailing)
        }
        .overlay(alignment: .topLeading) {
            // Tags open under line 2.
            Color.clear
                .frame(width: 1, height: M.detailsLine)
                .atticDropdown(isPresented: meta?.tagsPresented ?? .constant(false), label: String(localized: "Tags")) {
                    meta?.tagPicker()
                }
                .padding(.leading, M.titleX)
                .padding(.top, M.detailsTop)
                .allowsHitTesting(false)
        }
        .background { fill(windowKey: windowKey) }
        .overlay {
            if ring {
                RoundedRectangle(cornerRadius: M.fillRadius, style: .continuous)
                    .strokeBorder(TasksNewInk.focus, lineWidth: M.focusWidth)
                    .padding(.horizontal, M.fillInsetX)
                    .padding(.vertical, M.fillInsetY)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in if hovered != inside { hovered = inside } }
        .onTapGesture { if isEnabled { (onSelect ?? actions.openPage)() } }
        .atticTaskFocus($focused, enabled: isEnabled, actions: actions, listCommands: true,
                        live: capture == nil, external: focus, answersKeys: titleEditing == nil)
        .accessibilityElement(children: titleEditing == nil ? .combine : .contain)
        .accessibilityLabel(TasksNewText.accessibilityDescription(model, date: date?.text))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("new-row")
    }

    @ViewBuilder
    private func fill(windowKey: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: M.fillRadius, style: .continuous)
        Group {
            if isSelected {
                shape.fill(listHasKeyboard && windowKey ? TasksNewInk.selection : TasksNewInk.selectionUnfocused)
            } else if hovered, capture == nil {
                shape.fill(TasksNewInk.hover)
            }
        }
        .padding(.horizontal, M.fillInsetX)
        .padding(.vertical, M.fillInsetY)
    }

    // MARK: Line 1

    @ViewBuilder
    private func titleLine(done: Bool) -> some View {
        if let titleEditing, capture == nil {
            AtticRowTitleEditor(editing: titleEditing)
                .frame(height: M.titleLine)
        } else {
            HStack(alignment: .lastTextBaseline, spacing: M.marksGap) {
                Text(verbatim: model.title)
                    .font(.system(size: M.titleSize))
                    .foregroundStyle(done ? TasksNewInk.secondary : TasksNewInk.label)
                    .strikethrough(done, color: TasksNewInk.secondary)
                    .lineLimit(M.titleLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)
                    .help(model.title)
                // 2A: the marks follow the title and never truncate.
                if !done, let marks = TasksNewText.priorityMarks(model.priority) {
                    Text(verbatim: marks)
                        .font(.system(size: M.titleSize, weight: .bold))
                        .kerning(0.4)
                        .foregroundStyle(TasksNewInk.orange)
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: M.titleLine, alignment: .leading)
        }
    }

    // MARK: Line 2

    private func detailsLine(done: Bool) -> AnyView? {
        let tags = TasksNewText.tags(model.tags)
        let photos = model.photos > 0 || model.attachments > 0
        let link = model.linkHost != nil || model.links > 0
        guard !done, !tags.shown.isEmpty || model.subtasks != nil || model.hasPage || photos || model.flagged || link else {
            return nil
        }
        let font = Font.system(size: M.detailsSize)
        return AnyView(HStack(spacing: M.detailsGap) {
            if !tags.shown.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags.shown, id: \.self) { tag in
                        (Text(verbatim: "#").foregroundStyle(TasksNewInk.tertiary)
                            + Text(verbatim: tag).foregroundStyle(TasksNewInk.secondary))
                    }
                    if tags.more > 0 {
                        Text(verbatim: "+\(tags.more)").foregroundStyle(TasksNewInk.tertiary)
                    }
                }
                .lineLimit(1)
            }
            if let subtasks = model.subtasks {
                // § 2.8: the progress is the disclosure (click, → or ←).
                Button(action: onToggleExpanded) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.square").font(.system(size: M.markSize))
                        Text(verbatim: "\(subtasks.done)/\(subtasks.total)").monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(TasksNewInk.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(TasksNewInk.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(isExpanded ? String(localized: "Hide subtasks (←)") : String(localized: "Show subtasks (→)"))
                .accessibilityLabel(String(localized: "\(subtasks.done) of \(subtasks.total) subtasks done"))
            }
            if photos { mark("photo") }
            if model.hasPage { mark("doc.text") }
            if link { mark("link") }
            if model.flagged {
                Image(systemName: "flag.fill").font(.system(size: M.markSize - 1)).foregroundStyle(TasksNewInk.orange)
            }
        }
        .font(font)
        .foregroundStyle(TasksNewInk.secondary))
    }

    private func mark(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: M.markSize))
            .foregroundStyle(TasksNewInk.secondary)
    }

    // MARK: The column

    @ViewBuilder
    private func columnView(_ column: TasksNewColumn) -> some View {
        switch column {
        case .empty:
            Color.clear
        case .date:
            if let date {
                Text(verbatim: date.text)
                    .font(.system(size: M.detailsSize, weight: date.tone == .quiet ? .regular : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(date.tone == .overdue ? TasksNewInk.red : date.tone == .today ? TasksNewInk.label : TasksNewInk.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        case .actions:
            HStack(spacing: M.slotSpacing) {
                slot("calendar", ink: date?.tone == .overdue ? TasksNewInk.red : TasksNewInk.secondary,
                     help: String(localized: "Date (D)"), action: onDate)
                slot(moveToNow ? "tray.and.arrow.up" : "tray.and.arrow.down", ink: TasksNewInk.secondary,
                     help: moveToNow ? String(localized: "Move to Now (L)") : String(localized: "Move to Later (L)"), action: onMove)
                slot("info.circle", ink: TasksNewInk.accent, help: String(localized: "Show Info (⌘I)"), action: onInfo)
            }
        case .undo:
            Button { onUndo?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    Text("Undo").font(.system(size: M.detailsSize, weight: .semibold))
                }
                .foregroundStyle(TasksNewInk.label)
                .padding(.horizontal, M.undoPadding)
                .frame(height: M.undoHeight)
                .background(Capsule().fill(TasksNewInk.slotFill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Undo (⌘Z)"))
            .accessibilityIdentifier("new-row-undo")
        }
    }

    private func slot(_ symbol: String, ink: Color, help: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: M.slotGlyph))
                .foregroundStyle(ink)
                .frame(width: M.slotButton, height: M.slotButton)
                .background(RoundedRectangle(cornerRadius: M.slotRadius, style: .continuous).fill(TasksNewInk.slotFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - The key strip (6B)

/// While the single keys are live, a strip of them takes the add bar's
/// place. A click on it (or ⌘N) brings the add bar back.
struct TasksNewKeyStrip: View {
    let onTap: () -> Void

    var body: some View {
        let height = AtticControlSize.addBarHeight
        ViewThatFits(in: .horizontal) {
            content(TasksNewKey.strip)
            content(Array(TasksNewKey.strip.prefix(4)))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .atticRaisedMaterial(cornerRadius: AtticRadius.control(height: height), interactive: false)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .help(String(localized: "Add a task (⌘N)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Keys for the selected task: Space Done, D Date, L Move, 1 to 3 Priority, T Tags"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("new-key-strip")
    }

    private func content(_ items: [(key: String, label: String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.key) { item in
                HStack(spacing: 4) {
                    Text(verbatim: item.key)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(TasksNewInk.slotFill))
                        .foregroundStyle(TasksNewInk.label)
                    Text(verbatim: item.label)
                        .font(.system(size: 12))
                        .foregroundStyle(TasksNewInk.secondary)
                }
                .fixedSize()
            }
        }
    }
}
