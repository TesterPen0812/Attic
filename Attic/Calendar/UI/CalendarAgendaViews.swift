import SwiftUI

/// What the agenda's task rows do: the Tasks page's own commands.
@MainActor
struct CalendarTaskRowActions {
    let toggleDone: (UUID) -> Void
    let open: (UUID) -> Void
    var removeFromTasks: ((UUID) -> Void)?
    var canRemoveFromTasks: (UUID) -> Bool = { _ in false }
    var addFiles: ((UUID) -> Void)?

    func commands(for id: UUID) -> [AtticMenuCommand] {
        var commands = [AtticMenuCommand("Open Page", shortcut: AtticTaskShortcut.openPage) { open(id) }]
        if let addFiles {
            commands.append(.submenu("More", [AtticMenuCommand("Add Files…") { addFiles(id) }]))
        }
        if let removeFromTasks {
            var conversion = TaskNoteConversion.commands(taskID: id, hasWriting: canRemoveFromTasks(id),
                isSubtask: false, add: {}, remove: { removeFromTasks(id) })
            if !conversion.isEmpty { conversion[0].startsSection = true }
            commands += conversion
        }
        return commands
    }
}

/// One day of the agenda: the date tile on the left, the day's rows on the
/// right; today's day on a raised card.
struct CalendarAgendaDay: View {
    let group: CalendarAgendaGroup
    let today: DueDay
    let taskActions: CalendarTaskRowActions
    let onSelectDay: (DueDay) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: CalendarDesign.tileToRows) {
            CalendarDateTile(group: group) { onSelectDay(group.day) }
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.items) { item in
                    switch item {
                    case let .task(task):
                        taskRow(task)
                        .atticContextMenu { taskActions.commands(for: task.id) }
                        .accessibilityIdentifier("calendar-task-\(task.id.uuidString)")
                    case let .event(event):
                        CalendarEventRow(event: event, day: group.day, today: today)
                    case .now:
                        CalendarNowLine()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(CalendarDesign.dayPadding)
        .background {
            if group.isToday {
                Color.clear
                    .atticRaisedMaterial(cornerRadius: CalendarDesign.dayRadius, interactive: false)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, CalendarDesign.dayGap)
        .accessibilityElement(children: .contain)
    }
    func taskRow(_ task: CalendarTaskEntry) -> AtticTaskRow {
        AtticTaskRow(model: task.row,
            actions: AtticTaskActions(toggleDone: { taskActions.toggleDone(task.id) },
                                      openPage: { taskActions.open(task.id) }),
            // The Tasks rows' way in (Accepted 2026-10-30): the › and a
            // double-click open the page; a single click selects nothing here.
            onToggleExpanded: {}, onSelect: {}, onOpenPage: { taskActions.open(task.id) })
    }

}

/// The date, Today / Tomorrow / Yesterday, and the weekday. Tapping it
/// selects the day (in a search, the grid jumps to it).
struct CalendarDateTile: View {
    let group: CalendarAgendaGroup
    let action: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let text = Self.text(group)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: text.date)
                    .font(.system(size: CalendarDesign.tileDateFont, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tokens.ink(.heading).color)
                    .frame(height: CalendarDesign.tileDateLine)
                if let relative = text.relative {
                    Text(verbatim: relative)
                        .font(.system(size: CalendarDesign.tileDateFont, weight: .semibold))
                        .foregroundStyle(group.isToday ? TasksPanelDesign.vivid(CalendarDesign.red, tokens: tokens).color
                                         : TasksPanelDesign.toneInk(.date, tokens: tokens).color)
                        .frame(height: CalendarDesign.tileDateLine)
                }
                Text(verbatim: text.weekday)
                    .font(.system(size: CalendarDesign.tileWeekdayFont))
                    .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: tokens).color)
                    .frame(height: CalendarDesign.tileWeekdayLine)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, CalendarDesign.tilePaddingTop)
            .padding(.horizontal, CalendarDesign.tilePaddingX)
            .padding(.bottom, CalendarDesign.tilePaddingBottom)
            .frame(width: CalendarDesign.tileWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                AtticControlShape.shape(cornerRadius: CalendarDesign.tileRadius, exponent: AtticControlShape.designExponent)
                    .fill(tokens.ink(.heading).withAlpha(0.04).color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(CalendarKey.accessibilityName(group.day))
        .accessibilityIdentifier("calendar-tile-\(group.day.rawValue)")
    }

    /// "29 Oct", "Today", "Wednesday".
    static func text(_ group: CalendarAgendaGroup, locale: Locale = .current) -> (date: String, relative: String?, weekday: String) {
        let calendar = CalendarMonthMath.calendar()
        let date = group.day.startDate(in: calendar) ?? Date()
        let relative: String? = switch group.relative {
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case .yesterday: String(localized: "Yesterday")
        case nil: nil
        }
        return (TaskRowPresentation.format(date, template: "dMMM", calendar: calendar, locale: locale), relative,
                TaskRowPresentation.format(date, template: "EEEE", calendar: calendar, locale: locale))
    }
}

/// An event: a dot in the calendar's colour where a task's ring sits, the
/// title, then the time range and the location. Past events are grey.
struct CalendarEventRow: View {
    let event: CalendarEvent
    let day: DueDay
    let today: DueDay

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let past = day < today || (day == today && !event.isAllDay && event.end <= Date())
        let ringCentre = AtticLayout.circleX + AtticControlSize.statusCircle / 2
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(event.colour.rgba.color)
                .frame(width: CalendarDesign.eventDot, height: CalendarDesign.eventDot)
                .opacity(past ? 0.45 : 1)
                .padding(.leading, ringCentre - CalendarDesign.eventDot / 2)
                .padding(.top, CalendarDesign.eventPaddingY + (CalendarDesign.eventLine - CalendarDesign.eventDot) / 2)
            VStack(alignment: .leading, spacing: CalendarDesign.eventMetaTop) {
                Text(verbatim: event.title)
                    .font(.system(size: CalendarDesign.eventTitleFont, weight: .medium))
                    .foregroundStyle(past ? TasksPanelDesign.toneInk(.meta, tokens: tokens).color : tokens.ink(.heading).color)
                    .lineSpacing(CalendarDesign.eventLine - CalendarDesign.eventTitleFont * 1.2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Text(verbatim: Self.timeText(event))
                        .foregroundStyle(TasksPanelDesign.toneInk(past ? .meta : .groupHeader, tokens: tokens).color)
                        .layoutPriority(1)
                    if let location = event.location, !location.isEmpty {
                        Text(verbatim: location)
                            .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: tokens).color)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: CalendarDesign.eventMetaFont).monospacedDigit())
                .lineLimit(1)
                .frame(height: CalendarDesign.eventLine)
            }
            .padding(.leading, TasksDesignMetrics.textX)
            .padding(.trailing, TasksDesignMetrics.rowPaddingX)
            .padding(.vertical, CalendarDesign.eventPaddingY)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar-event-\(event.id)")
    }

    /// "09:00–10:00", or "All day".
    static func timeText(_ event: CalendarEvent, locale: Locale = .current) -> String {
        if event.isAllDay { return String(localized: "All day") }
        let calendar = CalendarMonthMath.calendar()
        let start = TaskRowPresentation.format(event.start, template: "jmm", calendar: calendar, locale: locale)
        let end = TaskRowPresentation.format(event.end, template: "jmm", calendar: calendar, locale: locale)
        return "\(start)–\(end)"
    }
}

/// The current time among today's timed events: a red dot where the rings
/// sit, a red line, and the time.
struct CalendarNowLine: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let red = TasksPanelDesign.vivid(CalendarDesign.nowRed, tokens: design.tokens).color
        let ringCentre = AtticLayout.circleX + AtticControlSize.statusCircle / 2
        TimelineView(.everyMinute) { context in
            HStack(spacing: 5) {
                Circle().fill(red).frame(width: CalendarDesign.nowDot, height: CalendarDesign.nowDot)
                Capsule().fill(red).frame(height: CalendarDesign.nowLine)
                Text(verbatim: TaskRowPresentation.format(context.date, template: "jmm", calendar: CalendarMonthMath.calendar(),
                                                          locale: .current))
                    .font(.system(size: CalendarDesign.nowFont, weight: .semibold).monospacedDigit())
                    .foregroundStyle(red)
            }
            .padding(.leading, ringCentre - CalendarDesign.nowDot / 2)
            .padding(.trailing, TasksDesignMetrics.rowPaddingX)
            .padding(.vertical, CalendarDesign.nowPaddingY)
        }
        .accessibilityHidden(true)
    }
}
