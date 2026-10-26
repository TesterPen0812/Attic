import AppKit
import SwiftUI

// The Reminders replica's rows (R1). Attic's own SwiftUI on Attic's tasks;
// values from `RemindersReplicaMetrics` (each with its evidence class).

/// Which selection fill a selected row takes (C resource, RES-FS-003).
enum RemindersReplicaSelectionTone: Equatable {
    case focused, unfocused, nonKey

    var fill: AtticRGBA {
        switch self {
        case .focused: RemindersReplicaMetrics.focusedSelection
        case .unfocused: RemindersReplicaMetrics.unfocusedSelection
        case .nonKey: RemindersReplicaMetrics.nonKeySelection
        }
    }

    static func resolve(windowIsKey: Bool, listHasKeyboard: Bool) -> Self {
        guard windowIsKey else { return .nonKey }
        return listHasKeyboard ? .focused : .unfocused
    }
}

/// The completion circle: an open grey ring, or completed as a solid
/// centre inside the ring with a light gap (M, R2-F01), in the list's
/// blue. SF Symbols only.
struct RemindersReplicaCircle: View {
    let done: Bool
    var emphasised = false

    var body: some View {
        let m = RemindersReplicaMetrics.self
        ZStack {
            Circle()
                .strokeBorder(done ? m.listBlue : (emphasised ? Color(nsColor: .secondaryLabelColor) : m.openRing),
                              lineWidth: m.circleStroke)
                .frame(width: m.circleDiameter, height: m.circleDiameter)
            if done {
                Circle()
                    .fill(m.listBlue)
                    .frame(width: m.completedFill, height: m.completedFill)
            }
        }
        .frame(width: m.circleFrame, height: m.circleFrame)
        .accessibilityHidden(true)
    }
}

/// The title as one wrapping text, the priority mark before it (M,
/// UI-ROW-06). Tags go on the date line (M, UI-GEO-01 row 12).
enum RemindersReplicaTitle {
    static func text(_ model: AtticTaskRowModel, done: Bool, parent: Bool) -> Text {
        let m = RemindersReplicaMetrics.self
        let font = Font.system(size: m.titleSize, weight: parent ? m.parentWeight : .regular, design: .rounded)
        let ink = done ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .labelColor)
        var result = Text("")
        if let mark = RemindersReplicaText.priorityMark(model.priority) {
            result = Text(mark).foregroundColor(done ? ink : m.listBlue) + Text(verbatim: m.priorityGap)
        }
        result = result + Text(verbatim: model.title).foregroundColor(ink)
        return result.font(font)
    }

    /// The line spacing that gives the measured 16 pt pitch, and the
    /// padding that makes the first line's box 18 pt.
    static var lineSpacing: CGFloat {
        max(0, RemindersReplicaMetrics.titleLinePitch - naturalLineHeight(RemindersReplicaMetrics.titleFont))
    }

    static var firstLinePadding: CGFloat {
        max(0, (RemindersReplicaMetrics.titleFirstLine - naturalLineHeight(RemindersReplicaMetrics.titleFont)) / 2)
    }

    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }
}

/// One replica row: circle, title (wrapping), notes preview, date line,
/// then the trailing info button and a parent's disclosure.
struct RemindersReplicaRow: View {
    let model: AtticTaskRowModel
    var isSelected = false
    var selectionRun: AtticSelectionRun = .single
    var listHasKeyboard = true
    var isExpanded = false
    let actions: AtticTaskActions
    let onToggleExpanded: () -> Void
    var onSelect: (() -> Void)? = nil
    /// The trailing ⓘ: the detail panel (R2).
    var onInfo: (() -> Void)? = nil
    /// A click on the title's text: it edits in place (R2).
    var onEditTitle: (() -> Void)? = nil
    var focus: AtticRowFocus? = nil
    var titleEditing: AtticTitleEditing? = nil
    /// Today, for the date line (the page's own clock and calendar).
    var dateLine: (text: String, tone: RemindersReplicaText.DateTone)? = nil

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @State private var hovered = false
    @State private var focused = false

    var body: some View {
        let m = RemindersReplicaMetrics.self
        let done = model.state == .done
        let parent = model.subtasks != nil
        let tone = RemindersReplicaSelectionTone.resolve(windowIsKey: activeState == .key || capture != nil,
                                                         listHasKeyboard: listHasKeyboard)
        let rowFocused = focus?.isFocused ?? focused
        let ring = capture == nil && isEnabled && rowFocused && keyboardFocusVisible && titleEditing == nil

        ZStack(alignment: .topLeading) {
            Button(action: actions.toggleDone) {
                RemindersReplicaCircle(done: done, emphasised: hovered || ring)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, m.circleX - (24 - m.circleFrame) / 2)
            // M: the circle's centre 15.5 pt below the row's top.
            .padding(.top, m.circleCentreY - 12)
            .accessibilityLabel(done ? String(localized: "Mark as not done") : String(localized: "Complete"))

            VStack(alignment: .leading, spacing: 0) {
                titleView(done: done, parent: parent)
                    .padding(.trailing, m.titleTrailing - m.notesTrailing)
                if let notes = model.notes {
                    // M: a link in the writing is blue, underlined and
                    // clickable (R2-F06).
                    Text(RemindersReplicaText.linkedNotes(notes))
                        .font(.system(size: m.notesSize, design: .rounded))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(m.notesLineLimit)
                        .padding(.vertical, 1)
                        .frame(minHeight: m.notesFirstLine, alignment: .topLeading)
                        .padding(.top, -m.dateOverlap)
                }
                if let line = detailsLine {
                    line
                        .frame(height: m.dateLineHeight, alignment: .leading)
                        .padding(.top, -m.dateOverlap)
                }
            }
            .padding(.top, m.titleTop)
            .padding(.bottom, m.bottomInset)
            .padding(.leading, m.titleX + m.textInset)
            .padding(.trailing, m.notesTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            trailing(parent: parent)
                .padding(.top, m.titleTop)
                .padding(.trailing, m.infoTrailing)
        }
        .background(alignment: .top) {
            if isSelected {
                AtticHighlight(fill: tone.fill, cornerRadius: m.selectionRadius, run: selectionRun, joinOverlap: 0)
                    .padding(.horizontal, m.selectionInset)
            }
        }
        .overlay {
            if ring {
                AtticFocusRing(cornerRadius: m.selectionRadius, gap: 0, width: 1)
                    .padding(.horizontal, m.selectionInset)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if isEnabled { (onSelect ?? actions.openPage)() } }
        .atticTaskFocus($focused, enabled: isEnabled, actions: actions, listCommands: true,
                        live: capture == nil, external: focus, answersKeys: titleEditing == nil)
        .accessibilityElement(children: titleEditing == nil ? .combine : .contain)
        .accessibilityLabel(model.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("replica-row")
    }

    @ViewBuilder
    private func titleView(done: Bool, parent: Bool) -> some View {
        if let titleEditing, capture == nil {
            AtticRowTitleEditor(editing: titleEditing)
                .frame(height: RemindersReplicaMetrics.titleFirstLine)
        } else {
            RemindersReplicaTitle.text(model, done: done, parent: parent)
                .lineSpacing(RemindersReplicaTitle.lineSpacing)
                .padding(.vertical, RemindersReplicaTitle.firstLinePadding)
                .fixedSize(horizontal: false, vertical: true)
                .help(model.title)
                .onTapGesture {
                    guard isEnabled, capture == nil else { return }
                    (onEditTitle ?? onSelect ?? actions.openPage)()
                }
        }
    }

    /// The date line, with the link and file markers where Attic has them.
    private var detailsLine: AnyView? {
        let markers = model.links > 0 || model.attachments > 0 || model.photos > 0 || model.linkHost != nil
        guard dateLine != nil || markers || !model.tags.isEmpty else { return nil }
        let m = RemindersReplicaMetrics.self
        let font = Font.system(size: m.dateSize, design: .rounded)
        return AnyView(HStack(spacing: m.dateToTag) {
            if let dateLine {
                Text(verbatim: dateLine.text)
                    .font(font)
                    .foregroundStyle(dateLine.tone == .overdue ? Color(nsColor: .systemRed) : Color(nsColor: .secondaryLabelColor))
            }
            // M: a tag sits on the date line after the date (UI-GEO-01 row 12).
            if !model.tags.isEmpty {
                Text(verbatim: model.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(font)
                    .foregroundStyle(m.tagInk)
                    .lineLimit(1)
            }
            if let host = model.linkHost {
                // The link field's marker: its host (Reminders draws a chip
                // below, R2-F07; E).
                Label(host, systemImage: "link")
                    .labelStyle(.titleAndIcon)
                    .font(font)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            } else if model.links > 0 {
                Image(systemName: "link").font(font).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            if model.attachments > 0 || model.photos > 0 {
                Image(systemName: "photo").font(font).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        })
    }

    @ViewBuilder
    private func trailing(parent: Bool) -> some View {
        let m = RemindersReplicaMetrics.self
        // M: the info region 22 pt wide ends 14 pt before the row's end; a
        // parent's disclosure (15 pt) takes that place and the info moves
        // 13 pt further in (UI-GEO-01 rows 7 and 15).
        HStack(spacing: 13) {
            // M: info shows on the selected row too, not only on hover
            // (R2-F09); C: `info.circle` (R3-020..028).
            if let onInfo, capture == nil, titleEditing == nil, hovered || isSelected {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: m.infoSize))
                        .foregroundStyle(m.listBlue)
                        .frame(width: m.infoRegion, height: m.titleFirstLine)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show Info"))
                .accessibilityLabel(String(localized: "Show Info"))
            }
            // The flag at the trailing edge (M: orange, R2-F01/R2-12; E:
            // the system orange and its size).
            if model.flagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: m.infoSize - 3))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(height: m.titleFirstLine)
                    .accessibilityLabel(String(localized: "Flagged"))
            }
            if parent {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: m.disclosureSize, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 15, height: m.titleFirstLine)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"))
            }
        }
        .frame(height: m.titleFirstLine)
    }
}

/// A subtask under its expanded parent: the same row, 30 pt further in
/// (M, UI-ROW-04).
struct RemindersReplicaChildRow: View {
    let subtask: AtticSubtaskModel
    /// Clicked (R2): ⇧Tab makes it a task again.
    var isSelected = false
    var onSelect: (() -> Void)? = nil
    let onToggle: () -> Void

    var body: some View {
        let m = RemindersReplicaMetrics.self
        let ink = subtask.isDone ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .labelColor)
        HStack(alignment: .top, spacing: 0) {
            Button(action: onToggle) {
                RemindersReplicaCircle(done: subtask.isDone)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, m.circleX + m.childIndent - (24 - m.circleFrame) / 2)
            .padding(.top, m.circleCentreY - 12)
            .accessibilityLabel(subtask.isDone ? String(localized: "Mark as not done") : String(localized: "Complete"))
            Text(verbatim: subtask.title)
                .font(.system(size: m.titleSize, design: .rounded))
                .foregroundStyle(ink)
                .lineSpacing(RemindersReplicaTitle.lineSpacing)
                .padding(.vertical, RemindersReplicaTitle.firstLinePadding)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, m.titleTop)
                .padding(.bottom, m.bottomInset)
                .padding(.leading, m.titleX + m.childIndent + m.textInset - (m.circleX + m.childIndent - (24 - m.circleFrame) / 2) - 24)
                .padding(.trailing, m.notesTrailing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            if isSelected {
                AtticHighlight(fill: RemindersReplicaMetrics.focusedSelection, cornerRadius: m.selectionRadius,
                               run: .single, joinOverlap: 0)
                    .padding(.horizontal, m.selectionInset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("replica-subtask-row")
    }
}

/// The new-reminder row at the end of the list: an open circle and the
/// title field. Return saves and the row stays, empty, right below the
/// new reminder; a date in the words is drawn in blue and offered
/// underneath; Tab or a click accepts it.
struct RemindersReplicaNewRow: View {
    @ObservedObject var state: RemindersReplicaDraftState
    let parser: TaskTextParser
    let focusRequest: UInt64
    let dateText: (DueDay) -> String
    let onSubmit: () -> Void
    let onEnd: () -> Void
    let onAcceptDate: () -> Void

    @State private var focused = false
    @State private var reclaims = 0

    var body: some View {
        let m = RemindersReplicaMetrics.self
        let draft = state.draft
        let offered = draft.recognisedDate(parser: parser)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                RemindersReplicaCircle(done: false)
                    .padding(.leading, m.circleX)
                    .padding(.top, m.circleCentreY - m.circleFrame / 2)
                AtticTokenField(
                    text: Binding(get: { state.draft.text }, set: { newValue in
                        guard newValue != state.draft.text else { return }
                        state.draft.text = newValue
                        state.draft.isComposing = TasksPage.isComposing(NSApp.keyWindow?.firstResponder)
                    }),
                    chips: chips(draft),
                    isFocused: $focused,
                    accessibilityLabel: String(localized: "New reminder"),
                    actions: AtticTokenFieldActions(
                        submit: { _ in onSubmit() },
                        dismissChip: { _ in },
                        multilinePaste: { _ in false },
                        escape: { onEnd(); return true },
                        edited: { _, _ in
                            state.draft.isComposing = TasksPage.isComposing(NSApp.keyWindow?.firstResponder)
                        },
                        caretMoved: { _ in
                            let composing = TasksPage.isComposing(NSApp.keyWindow?.firstResponder)
                            if composing != state.draft.isComposing { state.draft.isComposing = composing }
                        },
                        // Tab accepts the offered date; Return stays Return.
                        suggestionKey: { key in
                            guard key == .accept, NSApp.currentEvent?.keyCode == 48,
                                  state.draft.recognisedDate(parser: parser) != nil else { return false }
                            onAcceptDate()
                            return true
                        }
                    ),
                    style: .listBody,
                    pieceColor: .systemBlue,
                    highColor: RemindersReplicaMetrics.tagNSColor,
                    accessibilityIdentifier: "replica-new-row"
                )
                .frame(height: m.titleFirstLine)
                .padding(.top, m.titleTop)
                .padding(.leading, m.titleX - m.circleX - m.circleFrame)
                .padding(.trailing, m.notesTrailing)
            }
            .frame(height: m.rowHeight(titleLines: 1, notesLines: 0, hasDateLine: false), alignment: .top)
            if let offered {
                // Our own suggestion (Apple's bubble is private): the day, as
                // the date line would say it.
                Button(action: onAcceptDate) {
                    Label(String(localized: "Suggested Date: \(dateText(offered.day))"), systemImage: "calendar")
                        .font(.system(size: m.dateSize, design: .rounded))
                        .foregroundStyle(m.listBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(m.listBlue.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(.leading, m.titleX)
                .padding(.bottom, 6)
                .accessibilityIdentifier("replica-date-suggestion")
            }
        }
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focusRequest) { _, _ in
            reclaims = 0
            focused = true
        }
        .onChange(of: focused) { _, now in
            guard !now else { return }
            // A person leaving (a click, a key) ends the row; the list
            // settling its own focus as rows arrive does not.
            if AtticRowTitleEditor.isPersonsDeparture(NSApp.currentEvent?.type) || reclaims >= 2 {
                onEnd()
            } else {
                reclaims += 1
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    private func chips(_ draft: RemindersReplicaDraft) -> [AtticTokenChip] {
        var chips = draft.tagPieces(parser: parser).map { AtticTokenChip(range: $0.range, kind: .high) }
        if let date = draft.recognisedDate(parser: parser) { chips.append(AtticTokenChip(range: date.range, kind: .piece)) }
        return chips.sorted { $0.range.location < $1.range.location }
    }
}
