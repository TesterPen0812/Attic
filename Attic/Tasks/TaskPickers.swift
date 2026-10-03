import SwiftUI

/// The date picker with its state (the month shown, the keyboard cursor),
/// on `TaskDateChoices`: the same for the add bar's strip, a row's date and
/// the right-click menu's "Pick a Date…".
struct TaskDatePickerView: View {
    let choices: TaskDateChoices
    /// The task's current day (ticked, filled), if any.
    let selected: DueDay?
    /// A row's picker offers "Remove date" and ticks the current choice.
    var forRow = false
    let onPick: (DueDay) -> Void
    var onRemove: () -> Void = {}

    @State private var highlight: TaskDatePickerHighlight?
    @FocusState private var focused: Bool

    var body: some View {
        let today = choices.today
        let highlight = self.highlight ?? TaskDatePickerHighlight(cursor: TaskDateCursor(start: selected ?? today))
        let cursor = highlight.cursor
        let month = cursor.month(in: choices)
        let quick = choices.quick
        // One tick for one day: when Tomorrow and Next week are the same
        // day (on a Sunday), only the first shows it (review wording).
        let tickedQuick = quick.first { $0.day == selected }?.id
        AtticDatePicker(
            quick: quick.map { item in
                AtticDatePicker.Quick(id: item.id, title: item.title, detail: choices.detail(for: item.day), isChecked: item.id == tickedQuick)
            },
            showsChecks: forRow,
            monthTitle: month.title,
            weekdays: month.weekdaySymbols,
            days: month.days.map { day in
                AtticDatePicker.Day(
                    id: day.day.rawValue,
                    number: "\(day.day.day)",
                    inMonth: day.inMonth,
                    isToday: day.day == today,
                    isSelected: day.day == selected,
                    isPast: day.day < today,
                    spoken: spoken(day.day)
                )
            },
            cursor: cursor.isKeyboardActive ? cursor.active.rawValue : nil,
            removeTitle: forRow && selected != nil ? String(localized: "Remove date") : nil,
            highlightedRow: highlight.row,
            onQuick: { id in if let item = quick.first(where: { $0.id == id }) { onPick(item.day) } },
            onDay: { id in if let day = DueDay(rawValue: id) { onPick(day) } },
            onMonth: { step in
                var next = highlight
                next.cursor.move(months: step, in: choices, byKeyboard: false)
                self.highlight = next
            },
            onRemove: onRemove,
            onHoverRow: { id, inside in
                var next = highlight
                next.hoverRow(id, inside: inside)
                if next != highlight { self.highlight = next }
            },
            onHoverDay: { id, inside in
                guard let day = DueDay(rawValue: id) else { return }
                var next = highlight
                next.hoverDay(day, inside: inside, inShownMonth: month.days.contains { $0.day == day && $0.inMonth })
                if next != highlight { self.highlight = next }
            }
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .atticDropdownFocus($focused)
        .onKeyPress(phases: .down) { press in key(press, highlight: highlight, quick: quick) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Choose a date"))
    }

    private func key(_ press: KeyPress, highlight start: TaskDatePickerHighlight, quick: [TaskDateChoices.Quick]) -> KeyPress.Result {
        var next = start
        switch press.key {
        case .leftArrow: next.moveByKeyboard { $0.move(days: -1, in: choices) }
        case .rightArrow: next.moveByKeyboard { $0.move(days: 1, in: choices) }
        case .upArrow: next.moveByKeyboard { $0.move(days: -7, in: choices) }
        case .downArrow: next.moveByKeyboard { $0.move(days: 7, in: choices) }
        case .pageUp: next.moveByKeyboard { $0.move(months: -1, in: choices, byKeyboard: true) }
        case .pageDown: next.moveByKeyboard { $0.move(months: 1, in: choices, byKeyboard: true) }
        case .return:
            // What the person sees highlighted: a quick day's row the
            // pointer is on, or the cursor's day in the month shown.
            if let row = start.row {
                if row == AtticDatePicker.removeID { onRemove() } else if let item = quick.first(where: { $0.id == row }) { onPick(item.day) }
                return .handled
            }
            guard start.cursor.isKeyboardActive else { return .ignored }
            onPick(start.cursor.active)
            return .handled
        default:
            return .ignored
        }
        self.highlight = next
        return .handled
    }

    private func spoken(_ day: DueDay) -> String {
        let calendar = DueDay.storageCalendar(matching: choices.parser.calendar)
        guard let date = day.startDate(in: calendar) else { return day.rawValue }
        return TaskRowPresentation.format(date, template: "EEEEdMMMMy", calendar: calendar, locale: choices.parser.locale)
    }
}

/// The tag list with its state (the query, the keyboard highlight). `state`
/// says how many of the targets have a tag.
struct TaskTagPickerView: View {
    let allTags: [String]
    let state: (String) -> AtticCheckState
    let onToggle: (String) -> Void
    /// Adds a new tag; false when it did not save, so what was typed stays.
    /// `completed` finishes the typed entry (clears the field) when a later
    /// Retry saves it (round 5, F5), as a first-time save does.
    let onCreate: (_ name: String, _ completed: @escaping () -> Void) -> Bool
    /// Opened by "New Tag…": the field has the keyboard at once.
    var focusField = true

    @State private var query = ""
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        let lowered = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
        let filtered = lowered.isEmpty ? allTags : allTags.filter { $0.lowercased().contains(lowered) }
        let create = AtticTag.normalize(lowered).flatMap { name in allTags.contains { $0.lowercased() == name.lowercased() } ? nil : name }
        AtticTagPicker(
            query: $query,
            tags: filtered.map { AtticTagPicker.Tag(name: $0, state: state($0)) },
            create: create,
            highlighted: highlighted,
            onToggle: onToggle,
            onCreate: { name in
                let clear = { query = "" }
                if onCreate(name, clear) { clear() }
            },
            fieldFocused: $fieldFocused,
            onHover: { index, inside in
                let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                if next != highlighted { highlighted = next }
            },
            listRows: allTags.count,
            listFocus: $listFocused,
            onListHighlight: $highlighted
        )
        .atticDropdownFocus($fieldFocused, when: focusField)
        // Typing highlights the first match; an empty field (as after a new
        // tag saved) highlights nothing, so another Return does nothing
        // rather than toggle a tag (round 5, F5).
        .onChange(of: query) { _, _ in highlighted = lowered.isEmpty || (filtered.isEmpty && create == nil) ? nil : 0 }
        .onKeyPress(phases: .down) { press in
            let count = filtered.count + (create == nil ? 0 : 1)
            switch press.key {
            case .downArrow:
                guard count > 0 else { return .ignored }
                highlighted = min((highlighted ?? -1) + 1, count - 1)
                return .handled
            case .upArrow:
                guard count > 0 else { return .ignored }
                highlighted = max((highlighted ?? count) - 1, 0)
                return .handled
            case .return, .space:
                // Space presses the highlighted row only while the rows have
                // the keyboard; in the field it types.
                if press.key == .space, !listFocused { return .ignored }
                if let highlighted, highlighted < filtered.count {
                    onToggle(filtered[highlighted])
                } else if let create {
                    let clear = { query = "" }
                    if onCreate(create, clear) { clear() }
                } else {
                    return .ignored
                }
                return .handled
            default:
                return .ignored
            }
        }
    }
}

/// Move to Task… (control audit item 5): the task list with its state (the
/// query, the keyboard highlight), as `TaskTagPickerView` is the tag list's.
/// `choices` are read once when it opens; typing filters them.
struct TaskMovePickerView: View {
    let choices: [AtticTaskPicker.Choice]
    let onChoose: (UUID) -> Void

    @State private var query = ""
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool
    @FocusState private var listFocused: Bool

    /// What `query` leaves, in list order (tests read it).
    static func filter(_ choices: [AtticTaskPicker.Choice], query: String) -> [AtticTaskPicker.Choice] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? choices : choices.filter { $0.title.localizedStandardContains(needle) }
    }

    var body: some View {
        let filtered = Self.filter(choices, query: query)
        AtticTaskPicker(
            query: $query,
            choices: filtered,
            highlighted: highlighted,
            onChoose: onChoose,
            fieldFocused: $fieldFocused,
            onHover: { index, inside in
                let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                if next != highlighted { highlighted = next }
            },
            listFocus: $listFocused,
            onListHighlight: $highlighted
        )
        .atticDropdownFocus($fieldFocused)
        // Typing highlights the first match, so Return chooses it.
        .onChange(of: query) { _, now in highlighted = now.isEmpty || Self.filter(choices, query: now).isEmpty ? nil : 0 }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow:
                guard !filtered.isEmpty else { return .ignored }
                highlighted = min((highlighted ?? -1) + 1, filtered.count - 1)
                return .handled
            case .upArrow:
                guard !filtered.isEmpty else { return .ignored }
                highlighted = max((highlighted ?? filtered.count) - 1, 0)
                return .handled
            case .return, .space:
                if press.key == .space, !listFocused { return .ignored }
                guard let highlighted, filtered.indices.contains(highlighted) else { return .ignored }
                onChoose(filtered[highlighted].id)
                return .handled
            default:
                return .ignored
            }
        }
    }
}

/// Priority as a short list (the strip's Priority): No Priority, ↓ Low,
/// ! Medium, !! High (follow-up part 2: all four, everywhere).
struct TaskPriorityPickerView: View {
    let current: TaskPriority?
    let onPick: (TaskPriority) -> Void

    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    @Environment(\.atticDropdownRegisterKeys) private var registerKeys

    private var options: [TaskPriority] { TaskPriority.choices }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, priority in
                // Its ⌥⌘ key on every row: real commands, learned here (p2-24).
                AtticDropdownRow(title: priority.choiceTitle,
                                 check: current == priority || (current == nil && priority == .none) ? .on : .off,
                                 mark: TaskRowPresentation.priority(priority),
                                 detail: priority.shortcutHint,
                                 isHighlighted: highlighted == index,
                                 onHover: { inside in
                                     let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                                     if next != highlighted { highlighted = next }
                                 }, position: index + 1, itemCount: options.count) { onPick(priority) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .atticDropdownFocus($focused)
        .onAppear {
            registerKeys { event in
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option],
                      let priority = options.first(where: { String($0.shortcut.key.character) == event.charactersIgnoringModifiers }) else { return false }
                onPick(priority)
                return true
            }
        }
        .onDisappear { registerKeys(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Priority"))
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow: highlighted = min((highlighted ?? -1) + 1, options.count - 1); return .handled
            case .upArrow: highlighted = max((highlighted ?? options.count) - 1, 0); return .handled
            case .return, .space:
                guard let highlighted else { return .ignored }
                onPick(options[highlighted])
                return .handled
            default: return .ignored
            }
        }
    }
}

extension TaskPriority {
    /// What every priority menu offers (the row menu, the strip, the bulk
    /// bar, the details panel): all four (follow-up part 2, option A). Low
    /// was hidden while it had no mark (round 7, R6); it now shows as a
    /// grey ↓, so it is offered to every task and selection again.
    static let choices: [TaskPriority] = [.none, .low, .medium, .high]

    /// Its key in every priority menu (⌥⌘0–3).
    var shortcut: KeyboardShortcut {
        switch self {
        case .none: AtticTaskShortcut.priorityNone
        case .low: AtticTaskShortcut.priorityLow
        case .medium: AtticTaskShortcut.priorityMedium
        case .high: AtticTaskShortcut.priorityHigh
        }
    }

    /// The toast's wording: "High priority", "Priority removed".
    var spokenTitle: String {
        switch self {
        case .none: String(localized: "Priority removed")
        case .low: String(localized: "Low priority")
        case .medium: String(localized: "Medium priority")
        case .high: String(localized: "High priority")
        }
    }

    /// The strip's wording: "No Priority", "↓  Low", "!  Medium", "!!  High".
    var pickerTitle: String {
        switch self {
        case .none: String(localized: "No Priority")
        case .low: String(localized: "↓  Low")
        case .medium: String(localized: "!  Medium")
        case .high: String(localized: "!!  High")
        }
    }

    /// The priority picker's name (p2-24): "None", "Low", "Medium", "High".
    var choiceTitle: String {
        switch self {
        case .none: String(localized: "None")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }

    /// Its key as the picker's rows show it: "⌥⌘0" to "⌥⌘3".
    var shortcutHint: String {
        let key = shortcut.key.character
        return "⌥⌘" + String(key).uppercased()
    }

    /// The plain name ("Low", "Medium", "High"; "No Priority").
    var detailTitle: String {
        switch self {
        case .none: String(localized: "No Priority")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }

    var mark: String? {
        switch self {
        case .low: "↓"
        case .medium: "!"
        case .high: "!!"
        case .none: nil
        }
    }

    /// The shorthand the add bar inserts for it. Low has none: no typed
    /// mark is both easy to type and never part of ordinary words (`↓`
    /// needs a special character, `!low` or `p4` collide with titles); the
    /// strip's Priority and ⌥⌘1 set it.
    var shorthand: String? {
        switch self {
        case .medium: "!"
        case .high: "!!"
        case .none, .low: nil
        }
    }
}
