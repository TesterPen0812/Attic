import SwiftUI

/// The date card on `TaskDateChoices` (the shared `AtticDateCard`): the
/// same for the add bar's strip, a row's date and the right-click menu's
/// "Pick a Date…". Typed text resolves through the shorthand's parser.
struct TaskDatePickerView: View {
    let choices: TaskDateChoices
    /// The task's current day (filled), if any.
    let selected: DueDay?
    /// A row's card offers "Remove date" when the row has one.
    var forRow = false
    let onPick: (DueDay) -> Void
    var onRemove: () -> Void = {}

    @State private var typed = ""

    var body: some View {
        let calendar = choices.cardCalendar
        let parser = choices.parser
        AtticDateCard(
            today: choices.today.startDate(in: calendar) ?? parser.now(),
            selected: selected?.startDate(in: calendar),
            calendar: calendar,
            typed: $typed,
            parse: { parser.parseDueDay($0)?.startDate(in: calendar) },
            removeTitle: forRow && selected != nil ? String(localized: "Remove date") : nil,
            onPick: { onPick(DueDay(date: $0, calendar: calendar)) },
            onRemove: onRemove
        )
    }
}

/// The Tasks tag list: every tag, ticked as `state` says (how many of the
/// targets have it), filtered by what is typed, with "New tag “#…”" for a
/// name no tag has. The card, its highlight and keys are the shared
/// `AtticTagPickerCard` (Notes' ⋯ → Tags… uses the same one).
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

    var body: some View {
        AtticTagPickerCard(rows: { query in
            let lowered = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
            let filtered = lowered.isEmpty ? allTags : allTags.filter { $0.lowercased().contains(lowered) }
            let create = AtticTag.normalize(lowered).flatMap { name in allTags.contains { $0.lowercased() == name.lowercased() } ? nil : name }
            return (filtered.map { AtticTagPicker.Tag(name: $0, state: state($0)) }, create)
        }, listRows: allTags.count, onToggle: onToggle, onCreate: onCreate, focusField: focusField)
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
    @FocusState private var focus: AtticDropdownFocusTarget?

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
            focus: $focus,
            onHover: { index, inside in
                let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                if next != highlighted { highlighted = next }
            },
            onListHighlight: $highlighted
        )
        .atticDropdownFocus($focus)
        .atticDropdownTabs(focus: $focus, count: filtered.count)
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
                if press.key == .space, focus != .list { return .ignored }
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
