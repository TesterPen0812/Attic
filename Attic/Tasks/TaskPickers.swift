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

    @State private var shown: TaskDateChoices.Month?
    @State private var cursor: DueDay?
    @FocusState private var focused: Bool

    var body: some View {
        let today = choices.today
        let month = shown ?? choices.month(containing: selected ?? today)
        let quick = choices.quick
        AtticDatePicker(
            quick: quick.map { item in
                AtticDatePicker.Quick(id: item.id, title: item.title, detail: choices.detail(for: item.day), isChecked: item.day == selected)
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
            cursor: cursor?.rawValue,
            removeTitle: forRow && selected != nil ? String(localized: "Remove date") : nil,
            onQuick: { id in if let item = quick.first(where: { $0.id == id }) { onPick(item.day) } },
            onDay: { id in if let day = DueDay(rawValue: id) { onPick(day) } },
            onMonth: { step in shown = choices.month(after: month, by: step) },
            onRemove: onRemove
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in key(press, month: month) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Choose a date"))
    }

    private func key(_ press: KeyPress, month: TaskDateChoices.Month) -> KeyPress.Result {
        let start = cursor ?? selected ?? choices.today
        let step: Int? = switch press.key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -7
        case .downArrow: 7
        default: nil
        }
        if let step {
            let next = choices.day(start, movedBy: step)
            cursor = next
            if next.month != month.month || next.year != month.year { shown = choices.month(containing: next) }
            return .handled
        }
        switch press.key {
        case .pageUp, .pageDown:
            shown = choices.month(after: month, by: press.key == .pageUp ? -1 : 1)
            return .handled
        case .return:
            guard let cursor else { return .ignored }
            onPick(cursor)
            return .handled
        default:
            return .ignored
        }
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
    let onCreate: (String) -> Void
    /// Opened by "New Tag…": the field has the keyboard at once.
    var focusField = true

    @State private var query = ""
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool

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
            onCreate: { name in onCreate(name); query = "" },
            fieldFocused: $fieldFocused
        )
        .onAppear { if focusField { fieldFocused = true } }
        .onChange(of: query) { _, _ in highlighted = filtered.isEmpty && create == nil ? nil : 0 }
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
            case .return:
                if let highlighted, highlighted < filtered.count {
                    onToggle(filtered[highlighted])
                } else if let create {
                    onCreate(create)
                    query = ""
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

/// Priority as a short list (the strip's Priority): None, ! Medium,
/// !! High. A task that already has the legacy Low keeps it representable
/// (review 17): it shows, ticked, until another is chosen.
struct TaskPriorityPickerView: View {
    let current: TaskPriority?
    let onPick: (TaskPriority) -> Void

    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var options: [TaskPriority] {
        current == .low ? [.none, .low, .medium, .high] : [.none, .medium, .high]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, priority in
                AtticChoiceRow(title: priority.pickerTitle, detail: nil,
                               check: current == priority || (current == nil && priority == .none) ? .on : .off,
                               isHighlighted: highlighted == index, titleInk: .body) { onPick(priority) }
            }
        }
        .frame(width: AtticPickerMetrics.tagWidth - 40)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow: highlighted = min((highlighted ?? -1) + 1, options.count - 1); return .handled
            case .upArrow: highlighted = max((highlighted ?? options.count) - 1, 0); return .handled
            case .return:
                guard let highlighted else { return .ignored }
                onPick(options[highlighted])
                return .handled
            default: return .ignored
            }
        }
    }
}

extension TaskPriority {
    /// The strip's and menu's wording: "None", "!  Medium", "!!  High".
    var pickerTitle: String {
        switch self {
        case .none: String(localized: "None")
        case .low: String(localized: "Low")
        case .medium: String(localized: "!  Medium")
        case .high: String(localized: "!!  High")
        }
    }

    var mark: String? {
        switch self {
        case .medium: "!"
        case .high: "!!"
        case .none, .low: nil
        }
    }

    /// The shorthand the add bar inserts for it.
    var shorthand: String? {
        switch self {
        case .medium: "!"
        case .high: "!!"
        case .none, .low: nil
        }
    }
}
