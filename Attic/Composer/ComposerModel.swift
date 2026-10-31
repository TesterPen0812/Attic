import Foundation
import SwiftUI

/// What the "+" card makes (Accepted 2026-10-29, "The '+' card").
enum ComposerKind: String, CaseIterable, Equatable, Sendable {
    case task, event, note

    var title: String {
        switch self {
        case .task: String(localized: "Task")
        case .event: String(localized: "Event")
        case .note: String(localized: "Note")
        }
    }

    var placeholder: String {
        switch self {
        case .task: String(localized: "New task")
        case .event: String(localized: "New event")
        case .note: String(localized: "New note")
        }
    }
}

/// The page the card opens on: it decides the kinds on offer, the kind "+"
/// opens on, where a task goes and which history a creation joins.
enum ComposerPage: Equatable {
    case tasks(TasksTab)
    case calendar(selected: DueDay)
    case notes

    /// Events only on the Calendar page (Accepted 2026-10-30): Task · Note
    /// on Tasks, Task · Event · Note on Calendar.
    var kinds: [ComposerKind] {
        switch self {
        case .tasks: [.task, .note]
        case .calendar: [.task, .event, .note]
        case .notes: [.note]
        }
    }

    var ownKind: ComposerKind {
        switch self {
        case .tasks: .task
        case .calendar: .event
        case .notes: .note
        }
    }

    /// Each creation is one Undo step in the history ⌘Z reaches on the page
    /// it was made on (events: the writer's own `.calendar` steps).
    var history: UndoHistoryID {
        switch self {
        case .tasks: .tasks
        case .calendar: .calendar
        case .notes: .notesLibrary
        }
    }
}

/// What the card asks of the panel. Every event write goes through
/// `makeWriter`; tests inject a fake-backed writer, never a live store.
struct ComposerServices {
    var makeWriter: (() throws -> CalendarEventWriter)?
    var openTaskPage: (UUID) -> Void = { _ in }
    var openNote: (UUID) -> Void = { _ in }
    var openEvent: (CalendarOwnedEvent) -> Void = { _ in }
    var toast: (String) -> Void = { _ in }
}

/// The "+" card's state. It lives as long as the panel, so a draft dismissed
/// with Escape or a click outside is there again on the next "+", on any page.
/// The title is the add bar's draft (`TasksPageModel.addBarState`): its
/// shorthand, picks, suggestions and typing Undo carry over unchanged.
@MainActor
final class ComposerModel: ObservableObject {
    let tasks: TasksPageModel
    var services: ComposerServices

    @Published private(set) var isOpen = false
    @Published private(set) var page: ComposerPage = .tasks(.now)
    @Published private(set) var kind: ComposerKind = .task
    /// The second line: the task's or note's writing.
    @Published var writing = ""
    @Published var pinned = false
    /// An event's length in minutes, for a timed event.
    @Published var eventLength = 60
    @Published var calendarID: String?
    @Published private(set) var calendars: [CalendarWriteCalendar] = []
    /// A creation that did not save: the draft stays, the card says so.
    @Published private(set) var failed = false

    /// The card's title field.
    let editor = AtticTokenFieldEditor()
    private var writer: CalendarEventWriter?

    static let lengths = [30, 60, 90, 120]

    init(tasks: TasksPageModel, services: ComposerServices = ComposerServices()) {
        self.tasks = tasks
        self.services = services
    }

    var title: TasksAddBarState { tasks.addBarState }
    var kinds: [ComposerKind] { page.kinds }

    var hasDraft: Bool {
        !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty
            || !writing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCreate: Bool { !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty }

    // MARK: Opening and closing

    /// "+" opens on the page's own kind unless a note draft was kept; ⇧⌘N
    /// asks for Note. A kept event draft is a task outside Calendar.
    func open(on page: ComposerPage, as requested: ComposerKind? = nil) {
        let keptNote = kind == .note && hasDraft
        self.page = page
        if let requested, page.kinds.contains(requested) || requested == .note {
            kind = requested
        } else if !keptNote {
            kind = page.ownKind
        }
        if !page.kinds.contains(kind) { kind = kind == .event ? .task : page.ownKind }
        if !page.kinds.contains(kind) { kind = .note }
        fillCalendarDay()
        if kind == .event { loadCalendars() }
        failed = false
        isOpen = true
    }

    /// Escape or a click outside: the card closes and keeps the draft.
    func close() {
        isOpen = false
    }

    func choose(_ newKind: ComposerKind) {
        guard page.kinds.contains(newKind), newKind != kind else { return }
        kind = newKind
        fillCalendarDay()
        if newKind == .event { loadCalendars() }
        failed = false
    }

    /// On Calendar a task or an event starts on the selected day, unless the
    /// draft already has one.
    private func fillCalendarDay() {
        guard case let .calendar(day) = page, kind != .note,
              tasks.addBar.parts(parser: tasks.parser).dueDay == nil else { return }
        var text = tasks.addBar
        text.picked.day = day
        tasks.addBar = text
    }

    // MARK: What the title says

    /// The pieces the title reads for this kind: a task reads `!`, `#tag`,
    /// a day and a time; an event a day and a time; a note `#tag`.
    func reads(_ value: ParsedTaskToken.Value) -> Bool {
        switch (kind, value) {
        case (.task, _): true
        case (.event, .dueDay), (.event, .time): true
        case (.note, .tag): true
        default: false
        }
    }

    private var tokens: [ParsedTaskToken] {
        tasks.addBar.activeTokens(parser: tasks.parser).filter { reads($0.value) }
    }

    /// The tinted pieces of the title line.
    var chips: [AtticTokenChip] {
        let text = tasks.addBar
        let ranges = tokens.map { $0.utf16Range(in: text.text) }
        return text.tokenChips(parser: tasks.parser, caret: title.caret).filter { ranges.contains($0.range) }
    }

    /// A suggestion this kind can use: tags for a task or note, days for a
    /// task or event.
    func suggestion(focused: Bool) -> TaskAddBarText.Suggestion? {
        guard focused, let suggestion = tasks.addBar.suggestion(parser: tasks.parser, caret: title.caret, tags: tasks.cachedTags),
              suggestion.range != title.hiddenSuggestion else { return nil }
        switch (kind, suggestion) {
        case (.task, _), (.event, .date), (.note, .tags): return suggestion
        default: return nil
        }
    }

    struct Values: Equatable {
        var title: String
        var day: DueDay?
        var time: Int?
        var priority: TaskPriority?
        var tags: [String]
    }

    /// What Create would make from the title, for this kind.
    var values: Values {
        let text = tasks.addBar
        switch kind {
        case .task:
            let parts = text.parts(parser: tasks.parser)
            return Values(title: parts.title, day: parts.dueDay, time: parts.dueTimeMinutes,
                          priority: parts.priority, tags: parts.tags)
        case .event:
            let parts = text.parts(parser: tasks.parser)
            return Values(title: TaskTextParser.title(text.text, removing: tokens.map(\.range)),
                          day: parts.dueDay, time: parts.dueTimeMinutes, priority: nil, tags: [])
        case .note:
            var tags: [String] = []
            for token in tokens { if case let .tag(tag) = token.value, !tags.contains(tag) { tags.append(tag) } }
            for tag in text.picked.tags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
            return Values(title: TaskTextParser.title(text.text, removing: tokens.map(\.range)),
                          day: nil, time: nil, priority: nil, tags: tags)
        }
    }

    var selectedCalendar: CalendarWriteCalendar? {
        calendars.first { $0.id == calendarID } ?? calendars.first
    }

    // MARK: Creating

    /// Return creates; ⌘Return creates and opens the item's page. The card
    /// closes on success and keeps the draft (and says so) on failure.
    @discardableResult
    func create(openingPage: Bool = false) -> Bool {
        guard canCreate else { return false }
        let made: Bool = switch kind {
        case .task: createTask(openingPage: openingPage)
        case .event: createEvent(openingPage: openingPage)
        case .note: createNote(openingPage: openingPage)
        }
        failed = !made
        guard made else { return false }
        clearDraft()
        isOpen = false
        return true
    }

    private func createTask(openingPage: Bool) -> Bool {
        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.parser, caret: nil)
        tasks.addBar = finished
        let day = finished.parts(parser: tasks.parser).dueDay
        // Later makes an undated put-off task; Done (and a dated task from
        // Later) creates in Now.
        let status: TaskStatus = page == .tasks(.backlog) && day == nil ? .backlog : .todo
        guard let draft = finished.draft(parser: tasks.parser, status: status),
              let task = tasks.library.createTask(draft, writing: writing, in: page.history) else { return false }
        tasks.attachComposerFiles(to: task.id)
        if openingPage {
            services.openTaskPage(task.id)
        } else if case let .tasks(tab) = page {
            if tab == .done || (tab == .backlog && status == .todo) {
                services.toast(String(localized: "Added to Now"))
            } else {
                tasks.addedRequest = TasksPageModel.ScrollRequest(id: task.id)
            }
        }
        return true
    }

    private func createEvent(openingPage: Bool) -> Bool {
        guard let writer = loadWriter(), let calendar = selectedCalendar else { return false }
        let values = values
        let clock = tasks.services.calendar()
        let day = values.day ?? tasks.parser.today
        guard let draft = Self.eventDraft(title: values.title.isEmpty ? TaskDraftBuilder.collapsed(tasks.addBar.text) : values.title,
                                          day: day, time: values.time, length: eventLength,
                                          calendarID: calendar.id, calendar: clock),
              let made = try? writer.create(draft) else { return false }
        calendarID = calendar.id
        if openingPage { services.openEvent(made) }
        return true
    }

    /// A timed event lasts `length` minutes; one with no time is all day
    /// (end exclusive, the next local midnight).
    nonisolated static func eventDraft(title: String, day: DueDay, time: Int?, length: Int,
                                       calendarID: String, calendar: Calendar) -> CalendarEventDraft? {
        let zone = calendar.timeZone.identifier
        var components = DateComponents(year: day.year, month: day.month, day: day.day)
        if let time {
            components.hour = time / 60
            components.minute = time % 60
            guard let start = calendar.date(from: components) else { return nil }
            return CalendarEventDraft(title: title, start: start, length: TimeInterval(length * 60),
                                      calendarID: calendarID, timeZoneID: zone)
        }
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return CalendarEventDraft(title: title, start: start, end: end, isAllDay: true, calendarID: calendarID, timeZoneID: zone)
    }

    private func createNote(openingPage: Bool) -> Bool {
        let values = values
        let title = values.title.isEmpty ? TaskDraftBuilder.collapsed(tasks.addBar.text) : values.title
        guard let id = tasks.library.createNote(title: title, body: writing, tags: values.tags,
                                                pinned: pinned, in: page.history) else { return false }
        if openingPage { services.openNote(id) } else { services.toast(String(localized: "Added to Notes")) }
        return true
    }

    /// The draft is used up: title, picks, writing and pin. The event's
    /// length and calendar stay as the person last chose them.
    func clearDraft() {
        title.clearDraft()
        writing = ""
        pinned = false
    }

    // MARK: Calendars

    private func loadWriter() -> CalendarEventWriter? {
        if let writer { return writer }
        writer = try? services.makeWriter?()
        return writer
    }

    func loadCalendars() {
        guard let writer = loadWriter() else { return }
        let list = (try? writer.writableCalendars()) ?? []
        if list != calendars { calendars = list }
        if let calendarID, list.contains(where: { $0.id == calendarID }) { return }
        calendarID = list.first?.id
    }

    // MARK: Undo

    /// ⌘Z past the title's own typing: the page's history.
    func undoPage() { _ = tasks.library.undo(in: page.history) }
    func redoPage() { _ = tasks.library.redo(in: page.history) }
}
