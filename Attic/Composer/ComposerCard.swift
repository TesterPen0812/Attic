import SwiftUI

/// The design's numbers for the "+" card (`Preview - settings at bottom`,
/// `cp.*`, drawn at 2x; halved here).
enum ComposerMetrics {
    static let width: CGFloat = 289
    /// Curve 1.4, as the "+" it grows out of (Shapes; owner notes 31 Oct).
    static let radius: CGFloat = 22
    static let padding = EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 11)
    static let kindInset: CGFloat = 2
    static let kindButton: CGFloat = 18
    static let kindGap: CGFloat = 1
    static let kindTop: CGFloat = 10
    static let markSlot: CGFloat = 14
    static let markGap: CGFloat = 8
    static let titleHeight: CGFloat = 20
    static let writingTop: CGFloat = 2
    static let writingLeading: CGFloat = markSlot + markGap
    static let writingMinHeight: CGFloat = 15
    static let writingMaxLines = 5
    /// The gap above the chips that keeps the card at the Tasks height.
    static let actionsTop: CGFloat = 43
    static let chipHeight: CGFloat = 26
    static let chipPadding: CGFloat = 5
    static let chipGap: CGFloat = 2
    static let chipIcon: CGFloat = 10
    static let chipLeading: CGFloat = -6
    static let createHeight: CGFloat = 28
    static let createPadding: CGFloat = 10

    /// The switch's room at the end of the title line.
    static func titleTrailing(kinds: Int) -> CGFloat {
        kinds > 1 ? CGFloat(kinds) * (kindButton + kindGap) + kindInset * 2 + padding.trailing : 0
    }
}

/// The "+" card: the title line with its live tints, the writing, one row of
/// chips and Create, and the kind switch in the top-right corner. It mounts on
/// its own; the panel decides where it sits and how it grows.
struct ComposerCard: View {
    @ObservedObject var model: ComposerModel
    @ObservedObject var title: TasksAddBarState

    @Environment(\.atticDesign) private var design
    @State private var titleFocused = true
    @FocusState private var writingFocused: Bool
    @State private var open: Chip?

    enum Chip: Hashable { case date, priority, tags, pin, length, calendar }

    init(model: ComposerModel) {
        self.model = model
        self.title = model.title
    }

    var body: some View {
        let kind = model.kind
        VStack(alignment: .leading, spacing: 0) {
            titleLine(kind)
            writingLine(kind)
                .padding(.top, ComposerMetrics.writingTop)
                .padding(.leading, ComposerMetrics.writingLeading)
            actions(kind)
                .padding(.top, ComposerMetrics.actionsTop)
        }
        .padding(ComposerMetrics.padding)
        .frame(width: ComposerMetrics.width, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if model.kinds.count > 1 {
                kindSwitch
                    .padding(.top, ComposerMetrics.kindTop)
                    .padding(.trailing, ComposerMetrics.padding.trailing)
            }
        }
        .atticRaisedMaterial(cornerRadius: ComposerMetrics.radius, interactive: false)
        .atticDesignCorners()
        .onKeyPress(.escape) {
            guard open == nil else { return .ignored }
            model.close()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "New \(kind.title)"))
        .accessibilityIdentifier("composer-card")
    }

    // MARK: Kind switch

    private var kindSwitch: some View {
        HStack(spacing: ComposerMetrics.kindGap) {
            ForEach(model.kinds, id: \.self) { kind in
                let selected = model.kind == kind
                Button {
                    model.choose(kind)
                    titleFocused = true
                } label: {
                    AtticIcon(systemName: Self.symbol(kind), size: 10.5, weight: .medium, ink: .glyph)
                        .colour(selected ? design.tokens.ink(.heading) : TasksPanelDesign.toneInk(.meta, tokens: design.tokens))
                        .frame(width: ComposerMetrics.kindButton, height: ComposerMetrics.kindButton)
                        .background {
                            if selected {
                                Squircle(cornerRadius: ComposerMetrics.kindButton / 2, exponent: AtticShape.controlExponent)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(kind.title)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("composer-kind-\(kind.rawValue)")
            }
        }
        .padding(ComposerMetrics.kindInset)
        .background(
            Squircle(cornerRadius: ComposerMetrics.kindButton / 2 + ComposerMetrics.kindInset, exponent: AtticShape.controlExponent)
                .fill(Color.black.opacity(0.045))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Item type"))
    }

    static func symbol(_ kind: ComposerKind) -> String {
        switch kind {
        case .task: "checkmark.circle"
        case .event: "calendar"
        case .note: "doc"
        }
    }

    // MARK: Title

    private func titleLine(_ kind: ComposerKind) -> some View {
        HStack(spacing: ComposerMetrics.markGap) {
            mark(kind)
                .frame(width: ComposerMetrics.markSlot, height: ComposerMetrics.markSlot)
            AtticTokenField(
                text: $title.text.text,
                chips: model.chips,
                isFocused: $titleFocused,
                accessibilityLabel: String(localized: "Title"),
                actions: titleActions,
                style: .composerTitle,
                ink: .heading,
                pieceInk: .placeholder,
                editor: model.editor,
                accessibilityIdentifier: "composer-title"
            )
            .frame(height: ComposerMetrics.titleHeight)
            .overlay(alignment: .leading) {
                if title.text.text.isEmpty {
                    AtticText(verbatim: kind.placeholder, style: .composerTitle, ink: .placeholder)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.trailing, ComposerMetrics.titleTrailing(kinds: model.kinds.count))
        .atticDropdown(isPresented: Binding(get: { suggestion != nil }, set: { shown in
            if !shown, let suggestion { title.hiddenSuggestion = suggestion.range }
        }), prefer: .above, label: String(localized: "Suggestions"), takesKeyboard: false, contentHasCard: true,
                       contentHeight: suggestion.map { CGFloat($0.count) * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.inset * 2 },
                       contentWidth: suggestion.map { AtticSuggestionList.idealWidth(items(for: $0)) }) {
            if let suggestion {
                AtticSuggestionList(items: items(for: suggestion), highlighted: min(title.highlighted, suggestion.count - 1),
                                    onHover: { index in if title.highlighted != index { title.highlighted = index } }) { index in
                    model.tasks.accept(suggestion, choice: index, editor: model.editor)
                    title.highlighted = 0
                }
            }
        }
    }

    @ViewBuilder
    private func mark(_ kind: ComposerKind) -> some View {
        let grey = TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color
        switch kind {
        case .task:
            Circle().strokeBorder(grey, lineWidth: 0.9).frame(width: 12.7, height: 12.7)
        case .event:
            Circle().fill(model.selectedCalendar.map { Self.colour($0.colour) } ?? grey).frame(width: 7, height: 7)
        case .note:
            AtticIcon(systemName: "doc", size: 12, ink: .glyph).colour(TasksPanelDesign.toneInk(.meta, tokens: design.tokens))
        }
    }

    static func colour(_ colour: CalendarEventColour) -> Color {
        Color(.sRGB, red: colour.red, green: colour.green, blue: colour.blue, opacity: 1)
    }

    private var suggestion: TaskAddBarText.Suggestion? { model.suggestion(focused: titleFocused) }

    private var titleActions: AtticTokenFieldActions {
        let tasks = model.tasks
        return AtticTokenFieldActions(
            submit: { command in model.create(openingPage: command) },
            dismissChip: { range in
                title.history.checkpoint(title.text, selection: title.currentSelection)
                title.text.dismiss(range)
            },
            // The card's title is one line; pasted lines join it.
            multilinePaste: { _ in false },
            escape: {
                guard open == nil else { open = nil; return true }
                model.close()
                return true
            },
            edited: { range, replacement in tasks.addBarEdited(range, replacement: replacement) },
            caretMoved: { caret in tasks.addBarCaretMoved(caret) },
            suggestionKey: { key in suggestionKey(key) },
            undoDraft: { title.undoDraft() },
            redoDraft: { title.redoDraft() },
            selectionMoved: { title.selection = $0 },
            undoFallback: { model.undoPage() },
            redoFallback: { model.redoPage() }
        )
    }

    /// ↑ ↓ move, Tab or Return take the choice, Esc hides the list (the add
    /// bar's keys, kept).
    private func suggestionKey(_ key: AtticSuggestionKey) -> Bool {
        guard let suggestion else { return false }
        switch key {
        case .up, .down:
            title.highlighted = key == .up ? max(title.highlighted - 1, 0) : min(title.highlighted + 1, suggestion.count - 1)
        case .accept:
            model.tasks.accept(suggestion, choice: min(title.highlighted, suggestion.count - 1), editor: model.editor)
            title.highlighted = 0
        case .dismiss: title.hiddenSuggestion = suggestion.range
        }
        return true
    }

    private func items(for suggestion: TaskAddBarText.Suggestion) -> [AtticSuggestionList.Item] {
        switch suggestion {
        case let .tags(_, _, matches, create):
            return matches.map { AtticSuggestionList.Item(id: $0, title: "#" + $0) }
                + (create.map { [AtticSuggestionList.Item(id: "create-" + $0, title: String(localized: "Create #\($0)"), systemName: "plus")] } ?? [])
        case let .date(_, _, title, day):
            return [AtticSuggestionList.Item(id: day.rawValue, title: title, systemName: "calendar",
                                             detail: model.tasks.dateChoices.longDetail(for: day))]
        }
    }

    // MARK: Writing

    /// The writing, for every kind: a task's or note's writing, an event's
    /// notes.
    private func writingLine(_ kind: ComposerKind) -> some View {
        TextField(String(localized: "Notes"), text: $model.writing, axis: .vertical)
            .textFieldStyle(.plain)
            .font(AtticTextStyle.composerWriting.font)
            .foregroundStyle(TasksPanelDesign.toneInk(.nextEventTime, tokens: design.tokens).color)
            .lineLimit(1...ComposerMetrics.writingMaxLines)
            .frame(minHeight: ComposerMetrics.writingMinHeight, alignment: .topLeading)
            .focused($writingFocused)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) && !press.modifiers.contains(.command) { return .ignored }
                model.create(openingPage: press.modifiers.contains(.command))
                return .handled
            }
            .accessibilityIdentifier("composer-writing")
    }

    // MARK: Chips and Create

    private func actions(_ kind: ComposerKind) -> some View {
        let values = model.values
        return HStack(spacing: ComposerMetrics.chipGap) {
            HStack(spacing: ComposerMetrics.chipGap) {
                switch kind {
                case .task:
                    dateChip(values, flex: true)
                    chip(.priority, systemName: "exclamationmark",
                         label: values.priority.map(\.composerTitle) ?? String(localized: "Priority"),
                         set: values.priority != nil, colour: values.priority == .high ? TasksPanelDesign.vivid(design.tokens.ink(.priorityHigh), tokens: design.tokens) : nil)
                    tagsChip(values)
                case .event:
                    dateChip(values, flex: true)
                    if values.time != nil {
                        chip(.length, systemName: "clock", label: Self.length(model.eventLength), set: true)
                    }
                    calendarChip
                case .note:
                    tagsChip(values).fixedSize()
                    chip(.pin, systemName: "pin", label: model.pinned ? String(localized: "Pinned") : String(localized: "Pin"),
                         set: model.pinned).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, ComposerMetrics.chipLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            createButton
        }
    }

    private func dateChip(_ values: ComposerModel.Values, flex: Bool) -> some View {
        chip(.date, systemName: "calendar", label: dateLabel(values), set: values.day != nil || model.kind == .event)
            .layoutPriority(1)
    }

    private func tagsChip(_ values: ComposerModel.Values) -> some View {
        let tags = values.tags
        let label = tags.first.map { "#" + $0 + (tags.count > 1 ? " +\(tags.count - 1)" : "") } ?? String(localized: "Tags")
        let hue = tags.first.map { model.tasks.library.tagColours.palette.hue(for: $0) }
        return chip(.tags, systemName: "number", label: label, set: !tags.isEmpty,
                    colour: hue.map { TasksPanelDesign.tagInk($0, tokens: design.tokens) })
    }

    private var calendarChip: some View {
        let calendar = model.selectedCalendar
        return chip(.calendar, systemName: nil, dot: calendar.map { Self.colour($0.colour) },
                    label: calendar?.title ?? String(localized: "Calendar"), set: calendar != nil)
    }

    func dateLabel(_ values: ComposerModel.Values) -> String {
        Self.dateLabel(values, kind: model.kind, words: { model.tasks.dueText($0) })
    }

    nonisolated static func dateLabel(_ values: ComposerModel.Values, kind: ComposerKind, words: (DueDay) -> String) -> String {
        let clock = values.time.map(Self.clock)
        switch kind {
        case .event:
            let day = values.day.map(words) ?? String(localized: "Today")
            return clock.map { "\(day), \($0)" } ?? String(localized: "\(day) · All day")
        default:
            guard let day = values.day else { return String(localized: "Date") }
            return clock.map { "\(words(day)), \($0)" } ?? words(day)
        }
    }

    nonisolated static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    nonisolated static func length(_ minutes: Int) -> String {
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(rest)")
    }

    private func chip(_ id: Chip, systemName: String?, dot: Color? = nil, label: String, set: Bool,
                      colour: AtticRGBA? = nil) -> some View {
        let muted = TasksPanelDesign.toneInk(.meta, tokens: design.tokens)
        let ink = set ? design.tokens.ink(.heading) : muted
        return Button {
            if id == .pin { model.pinned.toggle(); return }
            open = open == id ? nil : id
        } label: {
            HStack(spacing: 3.5) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: ComposerMetrics.chipIcon, weight: .semibold, ink: .glyph).colour(ink)
                } else if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6).frame(width: ComposerMetrics.chipIcon)
                }
                AtticText(verbatim: label, style: .composerChip, ink: .body, truncates: true).colour(colour ?? ink)
            }
            .padding(.horizontal, ComposerMetrics.chipPadding)
            .frame(maxWidth: .infinity, minHeight: ComposerMetrics.chipHeight, alignment: .leading)
            .background(
                Squircle(cornerRadius: ComposerMetrics.chipHeight / 2, exponent: AtticShape.controlExponent)
                    .fill(Color.black.opacity(open == id ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(label)
        .accessibilityIdentifier("composer-chip-\(id)")
        .atticDropdown(isPresented: Binding(get: { open == id }, set: { if !$0, open == id { open = nil } }),
                       prefer: .above, label: label) {
            picker(id)
        }
    }

    @ViewBuilder
    private func picker(_ id: Chip) -> some View {
        let tasks = model.tasks
        let editor = model.editor
        switch id {
        case .date:
            TaskDatePickerView(choices: tasks.dateChoices, selected: model.values.day, onPick: { day in
                open = nil
                tasks.pickDate(day, editor: editor)
            }, onRemove: model.kind == .event ? nil : {
                open = nil
                tasks.clearComposer(.date, editor: editor)
            })
        case .priority:
            TaskPriorityPickerView(current: model.values.priority, onPick: { priority in
                open = nil
                tasks.pickPriority(priority, editor: editor)
            })
        case .tags:
            TaskTagPickerView(allTags: tasks.composerTagChoices, state: { tasks.composerTagState($0) },
                              onToggle: { tasks.toggleComposerTag($0, editor: editor) },
                              onCreate: { name, _ in tasks.toggleComposerTag(name, editor: editor); return true },
                              focusField: true)
        case .length:
            ComposerChoiceList(rows: ComposerModel.lengths.map { minutes in
                (id: "\(minutes)", title: Self.length(minutes), dot: nil, on: model.eventLength == minutes, pick: {
                    model.eventLength = minutes
                    open = nil
                })
            })
        case .calendar:
            ComposerChoiceList(rows: model.calendars.map { calendar in
                (id: calendar.id, title: calendar.title, dot: Self.colour(calendar.colour),
                 on: model.selectedCalendar?.id == calendar.id, pick: {
                    model.calendarID = calendar.id
                    open = nil
                })
            })
        case .pin:
            EmptyView()
        }
    }

    private var createButton: some View {
        let can = model.canCreate
        return Button { model.create() } label: {
            AtticText(verbatim: String(localized: "Create"), style: .composerCreate, ink: .body)
                .colour(AtticRGBA(red: 1, green: 1, blue: 1, alpha: 1))
                .padding(.horizontal, ComposerMetrics.createPadding)
                .frame(height: ComposerMetrics.createHeight)
                .background(
                    Squircle(cornerRadius: ComposerMetrics.createHeight / 2, exponent: AtticShape.controlExponent)
                        .fill(can ? design.tokens.ink(.heading).color
                              : Color(.sRGB, red: 176 / 255, green: 178 / 255, blue: 182 / 255, opacity: 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!can)
        .fixedSize()
        .accessibilityIdentifier("composer-create")
    }
}

/// A short list for the event's length and calendar, in the menus' rows.
private struct ComposerChoiceList: View {
    let rows: [(id: String, title: String, dot: Color?, on: Bool, pick: () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { row in
                AtticChoiceRow(title: row.title, check: row.on ? .on : .off, action: row.pick)
                    .overlay(alignment: .leading) {
                        if let dot = row.dot { Circle().fill(dot).frame(width: 6, height: 6).padding(.leading, 2) }
                    }
            }
        }
        .padding(AtticDropdownMetrics.inset)
        .frame(minWidth: 140)
    }
}

extension TaskPriority {
    /// The Priority chip's word.
    var composerTitle: String {
        switch self {
        case .high: String(localized: "High")
        case .medium: String(localized: "Medium")
        case .low: String(localized: "Low")
        case .none: String(localized: "Priority")
        }
    }
}
