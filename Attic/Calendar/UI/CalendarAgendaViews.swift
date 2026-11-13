import SwiftUI

/// What the agenda's task rows do: the Tasks page's own commands.
@MainActor
struct CalendarTaskRowActions {
    let toggleDone: (UUID) -> Void
    let open: (UUID) -> Void
    /// Return's rename: saves the title; false keeps the field open.
    var rename: ((UUID, String) -> Bool)?
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

/// The agenda's task rows as the Tasks rows behave (Accepted 2026-10-30,
/// "Going into a task's page"): a click selects, Return renames the
/// selected task. Kept by the page's model, so Back from a task's page
/// finds the selection as it was.
@MainActor
final class CalendarTaskRowState: ObservableObject {
    @Published private(set) var selected: UUID?
    @Published private(set) var renaming: UUID?
    @Published var draft = ""

    func select(_ id: UUID) {
        if renaming != nil, renaming != id { renaming = nil }
        if selected != id { selected = id }
    }

    func clearSelection() {
        if renaming == nil, selected != nil { selected = nil }
    }

    func beginRename(_ id: UUID, title: String) {
        select(id)
        draft = title
        renaming = id
    }

    func endRename() { renaming = nil }
}

/// One day of the agenda: the grey date tile on the left, the day's rows on
/// the right; today's day on its raised card (owner, 2026-10-31: the older
/// agenda), a squircle surface at the card radius (Shapes), the tile
/// concentric inside it.
struct CalendarAgendaDay: View, Equatable {
    #if DEBUG && ATTIC_UNIT_TEST_HOST
    /// Count real SwiftUI body evaluations by day, including reused days.
    static var bodyEvaluationsByDay: [DueDay: Int] = [:]
    #endif

    let group: CalendarAgendaGroup
    let today: DueDay
    let taskActions: CalendarTaskRowActions
    @ObservedObject var rows = CalendarTaskRowState()
    var eventRows: CalendarEventRowState = CalendarEventRowState()
    /// The page's keyboard focus for its task rows (Return, ⇧⌘I); nil
    /// leaves each row its own.
    var focus: FocusState<AtticRowFocusID?>.Binding? = nil
    var focused: AtticRowFocusID? = nil
    let onSelectDay: (DueDay) -> Void

    /// The agenda's rows' page in `AtticRowFocusID` (the Tasks tabs use 0–2).
    static let focusPage = 90

    static func == (lhs: CalendarAgendaDay, rhs: CalendarAgendaDay) -> Bool {
        // The seven-day window advances by one day at a time. Six existing
        // groups often move to a new index without changing their contents;
        // let SwiftUI reuse their rendered rows. Event and task edits still
        // invalidate their observed state, and focus changes rebuild the row.
        lhs.group == rhs.group && lhs.today == rhs.today
            && lhs.rows === rhs.rows && lhs.eventRows === rhs.eventRows
            && lhs.focused == rhs.focused
            && (lhs.taskActions.rename != nil) == (rhs.taskActions.rename != nil)
            && (lhs.taskActions.removeFromTasks != nil) == (rhs.taskActions.removeFromTasks != nil)
            && (lhs.taskActions.addFiles != nil) == (rhs.taskActions.addFiles != nil)
    }

    var body: some View {
        #if DEBUG && ATTIC_UNIT_TEST_HOST
        let _ = Self.bodyEvaluationsByDay[group.day, default: 0] += 1
        #endif
        HStack(alignment: .top, spacing: CalendarDesign.tileToRows) {
            CalendarDateTile(group: group) { onSelectDay(group.day) }
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                // A day without events or tasks reads like the other empty
                // days: its date tile alone, without a floating now line.
                ForEach(group.hasRows ? group.items : []) { item in
                    switch item {
                    case let .task(task):
                        taskRow(task)
                        .atticContextMenu { taskActions.commands(for: task.id) }
                        .accessibilityIdentifier("calendar-task-\(task.id.uuidString)")
                    case let .event(event):
                        CalendarEventRow(event: event, day: group.day, today: today, rows: eventRows)
                            .modifier(AgentEventArrival(id: event.id))
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
            if Self.hasCard(group) {
                Color.clear
                    .atticRaisedMaterial(cornerRadius: CalendarDesign.dayRadius, interactive: false)
                    .environment(\.atticControlCornerExponent, CalendarDesign.dayCardExponent)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, CalendarDesign.dayGap)
        .accessibilityElement(children: .contain)
    }
    /// Today's content gets a card; an empty day keeps only its date tile.
    static func hasCard(_ group: CalendarAgendaGroup) -> Bool { group.isToday && group.hasRows }

    /// The Tasks rows' way in (Accepted 2026-10-30): a click selects (the
    /// selected look), Return renames, the ›, a double-click, ⇧⌘I and
    /// ⌘Return open the page.
    func taskRow(_ task: CalendarTaskEntry) -> AtticTaskRow {
        let id = task.id
        let focusID = AtticRowFocusID(page: Self.focusPage, id: id)
        let focus = self.focus
        let rows = self.rows
        let actions = taskActions
        let open = { rows.select(id); actions.open(id) }
        return AtticTaskRow(model: task.row,
            isSelected: rows.selected == id,
            actions: AtticTaskActions(toggleDone: { actions.toggleDone(id) }, openPage: open,
                                      editTitle: actions.rename == nil ? nil : {
                                          rows.beginRename(id, title: task.row.title)
                                      }),
            onToggleExpanded: {},
            onSelect: {
                rows.select(id)
                focus?.wrappedValue = focusID
            },
            onOpenPage: open,
            focus: focus.map { AtticRowFocus(binding: $0, id: focusID, isFocused: focused == focusID) },
            titleEditing: rows.renaming == id ? AtticTitleEditing(
                text: $rows.draft,
                commit: {
                    guard rows.renaming == id else { return true }
                    guard actions.rename?(id, rows.draft) == true else { return false }
                    rows.endRename()
                    focus?.wrappedValue = focusID
                    return true
                },
                cancel: {
                    rows.endRename()
                    focus?.wrappedValue = focusID
                }) : nil)
    }

}

/// The date, Today / Tomorrow / Yesterday, and the weekday on a grey tile
/// (owner, 2026-10-31: the older agenda). Tapping it selects the day (in a
/// search, the grid jumps to it).
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
                        .foregroundStyle(group.isToday ? AtticSurfaceInk.vivid(CalendarDesign.red, tokens: tokens).color
                                         : AtticSurfaceInk.toneInk(.date, tokens: tokens).color)
                        .frame(height: CalendarDesign.tileDateLine)
                }
                Text(verbatim: text.weekday)
                    .font(.system(size: CalendarDesign.tileWeekdayFont))
                    .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: tokens).color)
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
                    .fill(tokens.ink(.heading).withAlpha(CalendarDesign.tileFill).color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: CalendarDesign.tileRadius))
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
        return (AtticDateFormatting.template(date, template: "dMMM", calendar: calendar, locale: locale), relative,
                AtticDateFormatting.template(date, template: "EEEE", calendar: calendar, locale: locale))
    }
}

/// Where an event row is drawn: the agenda's row, or the Day view's block
/// on the hours or its one-line all-day row. Opening and editing are the
/// same in all three.
enum CalendarEventRowStyle: Equatable {
    case agenda
    case dayAllDay
    case dayBlock(showsMeta: Bool, isOver: Bool, paddingY: CGFloat)

    /// The row's sizes, from the agenda's or the Day drawing's.
    fileprivate var metrics: CalendarEventRowMetrics {
        switch self {
        case .agenda, .dayAllDay:
            CalendarEventRowMetrics()
        case let .dayBlock(_, _, paddingY):
            CalendarEventRowMetrics(dot: CalendarDayDesign.blockDot,
                                    dotCentre: CalendarDayDesign.blockPaddingX + CalendarDayDesign.blockDot / 2,
                                    textX: CalendarDayDesign.blockTextX, trailing: CalendarDayDesign.blockPaddingX,
                                    paddingY: paddingY, titleFont: CalendarDayDesign.blockTitleFont,
                                    titleLine: CalendarDayDesign.blockTitleLine, metaFont: CalendarDayDesign.blockMetaFont,
                                    metaLine: CalendarDayDesign.blockMetaLine, metaTop: 0)
        }
    }
}

private struct CalendarEventRowMetrics {
    var dot = CalendarDesign.eventDot
    var dotCentre = AtticLayout.circleX + AtticControlSize.statusCircle / 2
    var textX = TasksDesignMetrics.textX
    var trailing = TasksDesignMetrics.rowPaddingX
    var paddingY = CalendarDesign.eventPaddingY
    var titleFont = CalendarDesign.eventTitleFont
    var titleLine = CalendarDesign.eventLine
    var metaFont = CalendarDesign.eventMetaFont
    var metaLine = CalendarDesign.eventLine
    var metaTop = CalendarDesign.eventMetaTop
}

/// An event: a dot in the calendar's colour where a task's ring sits, the
/// title, then the time range and the location. Past events are grey.
struct CalendarEventRow: View {
    let event: CalendarEvent
    let day: DueDay
    let today: DueDay
    @ObservedObject var rows = CalendarEventRowState()
    var style = CalendarEventRowStyle.agenda

    @Environment(\.atticDesign) private var design
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var headFocused: Bool

    private var isOpen: Bool { rows.rowID == event.id && rows.rowDay == day }
    private var metrics: CalendarEventRowMetrics { style.metrics }
    private var isBlock: Bool { if case .dayBlock = style { true } else { false } }
    /// The Day view's rows inset their open fill as a Tasks row's is.
    private var fillInset: CGFloat { style == .dayAllDay ? AtticLayout.rowHighlightInset : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Button(action: toggleRow) { summary }
                    .buttonStyle(.plain)
                    .focused($headFocused)
                    .focusEffectDisabled()
                    .atticFocusRing(headFocused && keyboardFocusVisible, cornerRadius: CalendarDesign.eventRadius, continuous: true)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        toggleRow()
                        return .handled
                    }
                    .onKeyPress(.space, phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        toggleRow()
                        return .handled
                    }
                    .accessibilityValue(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
                    .accessibilityIdentifier("calendar-event-\(event.id)")
                if isOpen, rows.canEdit {
                    editableHead
                }
            }
            if isOpen {
                details
                    .padding(.leading, metrics.textX)
                    .padding(.trailing, metrics.trailing)
                    .padding(.bottom, isBlock ? metrics.paddingY : 8)
                    // Drops in 4 pt, never a slide from the edge (Accepted 2026-11-10).
                    .transition(design.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -AtticMotionScale.detailsDrop)))
            }
        }
        .background {
            // A block on the hours has its own surface.
            if isOpen, !isBlock {
                RoundedRectangle(cornerRadius: CalendarDesign.eventRadius, style: .continuous)
                    .fill(design.tokens.ink(.heading).withAlpha(0.045).color)
                    .padding(.horizontal, fillInset)
            }
        }
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: isOpen)
        .background(CalendarEventRowBoundary())
        .atticContextMenu {
            [AtticMenuCommand("Open in Calendar") { Task { await rows.openInCalendar(event, on: day) } }]
        }
        .accessibilityElement(children: .contain)
    }

    private func toggleRow() {
        IdleLatencyTrace.controlDispatched(.calendarEvent)
        Task { await rows.toggle(event, on: day) }
    }

    private var isPast: Bool {
        if case let .dayBlock(_, isOver, _) = style { return isOver }
        return day < today || (day == today && !event.isAllDay && event.end <= Date())
    }

    private var summary: some View {
        let tokens = design.tokens
        let past = isPast
        let metrics = self.metrics
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(event.colour.rgba.color)
                .frame(width: dotSize, height: dotSize)
                .opacity(past ? 0.45 : 1)
                .padding(.leading, metrics.dotCentre - dotSize / 2)
                .padding(.top, metrics.paddingY + (metrics.titleLine - dotSize) / 2)
            VStack(alignment: .leading, spacing: metrics.metaTop) {
                title(past: past, tokens: tokens)
                if showsMeta { meta(past: past, tokens: tokens) }
            }
            .padding(.leading, metrics.textX)
            .padding(.trailing, metrics.trailing)
            .padding(.vertical, metrics.paddingY)
            if style == .dayAllDay {
                Text(verbatim: String(localized: "All day"))
                    .font(.system(size: CalendarDayDesign.allDayLabelFont))
                    .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: tokens).color)
                    .frame(height: metrics.titleLine)
                    .padding(.vertical, metrics.paddingY)
                    .padding(.trailing, metrics.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isBlock && !isOpen ? CGFloat.infinity : nil, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var dotSize: CGFloat { style == .dayAllDay ? CalendarDayDesign.allDayDot : metrics.dot }

    private var showsMeta: Bool {
        switch style {
        case .agenda: true
        case .dayAllDay: false
        case let .dayBlock(showsMeta, _, _): showsMeta
        }
    }

    @ViewBuilder
    private func title(past: Bool, tokens: AtticColorTokens) -> some View {
        let text = Text(verbatim: event.title)
            .font(.system(size: metrics.titleFont, weight: .medium))
            .opacity(isOpen && rows.canEdit ? 0 : 1)
            .foregroundStyle(past ? AtticSurfaceInk.toneInk(.meta, tokens: tokens).color : tokens.ink(.heading).color)
        if style == .agenda {
            text
                .lineSpacing(CalendarDesign.eventLine - CalendarDesign.eventTitleFont * 1.2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // The Day drawing's single line; the all-day label keeps clear.
            text
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: metrics.titleLine)
                .padding(.trailing, style == .dayAllDay ? CalendarDayDesign.allDayLabelReserve : 0)
        }
    }

    @ViewBuilder
    private func meta(past: Bool, tokens: AtticColorTokens) -> some View {
        if isBlock {
            // The drawing's one string: "10:00–11:00 · Room".
            let location = event.location.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? ""
            Text(verbatim: Self.timeText(event) + location)
                .font(.system(size: metrics.metaFont).monospacedDigit())
                .foregroundStyle(AtticSurfaceInk.toneInk(past ? .meta : .groupHeader, tokens: tokens).color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: metrics.metaLine)
                .opacity(isOpen && rows.canEdit && !event.isAllDay ? 0 : 1)
        } else {
            HStack(spacing: 7) {
                Text(verbatim: Self.timeText(event))
                    .foregroundStyle(AtticSurfaceInk.toneInk(past ? .meta : .groupHeader, tokens: tokens).color)
                    .layoutPriority(1)
                if let location = event.location, !location.isEmpty {
                    Text(verbatim: location)
                        .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: tokens).color)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: metrics.metaFont).monospacedDigit())
            .lineLimit(1)
            .frame(height: metrics.metaLine)
            .opacity(isOpen && rows.canEdit && !event.isAllDay ? 0 : 1)
        }
    }

    private var editableHead: some View {
        VStack(alignment: .leading, spacing: metrics.metaTop) {
            TextField("Title", text: $rows.title)
                .font(.system(size: metrics.titleFont, weight: .medium))
                .frame(height: metrics.titleLine)
                .accessibilityIdentifier("calendar-event-title-\(event.id)")
            if let owned = rows.owned, !owned.draft.isAllDay {
                HStack(spacing: 0) {
                    TextField("Start time", text: $rows.startText)
                        .frame(width: 40)
                        .accessibilityIdentifier("calendar-event-start-\(event.id)")
                    Text(verbatim: "–" + Self.endText(start: rows.startText, length: rows.length))
                    Spacer(minLength: 0)
                    if let location = event.location { Text(verbatim: location).lineLimit(1) }
                }
                .font(.system(size: metrics.metaFont).monospacedDigit())
                .frame(height: metrics.metaLine)
            }
        }
        .textFieldStyle(.plain)
        .foregroundStyle(design.tokens.ink(.heading).color)
        .padding(.leading, metrics.textX)
        .padding(.trailing, metrics.trailing)
        .padding(.vertical, metrics.paddingY)
        .onSubmit { Task { await rows.close() } }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notes = rows.owned?.draft.notes, !notes.isEmpty {
                Text(verbatim: notes).font(.system(size: 11))
                    .foregroundStyle(AtticSurfaceInk.toneInk(.groupHeader, tokens: design.tokens).color)
            }
            HStack(spacing: 4) {
                if rows.canEdit {
                    choices
                    Spacer(minLength: 0)
                    Button("Delete", role: .destructive) { Task { await rows.delete() } }
                        .accessibilityIdentifier("calendar-event-delete-\(event.id)")
                        .disabled(rows.busy)
                        .atticOwnFocusRing(.rounded(radius: 9, height: 18))
                } else {
                    choiceLabel(event.calendarTitle, dot: event.colour)
                    choiceLabel(event.isAllDay ? String(localized: "All day")
                                : ComposerCard.length(Int(event.end.timeIntervalSince(event.start) / 60)))
                        .accessibilityIdentifier("calendar-event-duration-\(event.id)")
                    Spacer(minLength: 0)
                    Button("Open in Calendar") { Task { await rows.openInCalendar(event, on: day) } }
                        .fixedSize()
                        .accessibilityIdentifier("calendar-event-open-\(event.id)")
                        .atticOwnFocusRing(.rounded(radius: 9, height: 18))
                }
            }
            .font(.system(size: 9))
            .buttonStyle(.plain)
            .focusEffectDisabled()
            if let failure = rows.failure {
                Text(verbatim: failure)
                    .font(.system(size: 11))
                    .foregroundStyle(design.tokens.ink(.warningText).color)
                    .accessibilityIdentifier("calendar-event-failure-\(event.id)")
            }
        }
        .foregroundStyle(AtticSurfaceInk.toneInk(.groupHeader, tokens: design.tokens).color)
    }

    private var choices: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if rows.expandedChoice == .calendar {
                    ForEach(rows.calendars) { calendar in
                        choice(calendar.title, selected: calendar.id == rows.calendarID, dot: calendar.colour) {
                            rows.calendarID = calendar.id
                            rows.expandedChoice = nil
                        }
                    }
                } else if rows.expandedChoice == .length {
                    ForEach(ComposerModel.lengths, id: \.self) { length in
                        choice(ComposerCard.length(length), selected: length == rows.length) {
                            rows.length = length
                            rows.expandedChoice = nil
                        }
                    }
                } else {
                    choice(rows.calendars.first { $0.id == rows.calendarID }?.title ?? event.calendarTitle,
                           dot: rows.calendars.first { $0.id == rows.calendarID }?.colour ?? event.colour) {
                        rows.expandedChoice = .calendar
                    }
                    if rows.owned?.draft.isAllDay == false {
                        choice(ComposerCard.length(rows.length)) { rows.expandedChoice = .length }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 18)
        .background {
            if rows.expandedChoice != nil {
                AtticControlShape.shape(cornerRadius: 9, exponent: AtticShape.controlExponent)
                    .fill(design.tokens.ink(.heading).withAlpha(0.035).color)
            }
        }
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: rows.expandedChoice)
    }

    private func choice(_ title: String, selected: Bool = false, dot: CalendarEventColour? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { choiceLabel(title, selected: selected, dot: dot) }
            .atticOwnFocusRing(.rounded(radius: 9, height: 18))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choiceLabel(_ title: String, selected: Bool = false, dot: CalendarEventColour? = nil) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot.rgba.color).frame(width: 4, height: 4) }
            Text(verbatim: title).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 18)
        .background(AtticControlShape.shape(cornerRadius: 9, exponent: AtticShape.controlExponent)
            .fill(design.tokens.ink(.heading).withAlpha(selected ? 0.06 : (rows.expandedChoice == nil ? 0.05 : 0)).color))
    }

    private static func endText(start: String, length: Int) -> String {
        guard let minutes = CalendarEventRowState.minutes(start) else { return "" }
        return ComposerCard.clock((minutes + length) % (24 * 60))
    }

    /// "09:00–10:00", or "All day".
    static func timeText(_ event: CalendarEvent, locale: Locale = .current) -> String {
        if event.isAllDay { return String(localized: "All day") }
        let calendar = CalendarMonthMath.calendar()
        let start = AtticDateFormatting.template(event.start, template: "jmm", calendar: calendar, locale: locale)
        let end = AtticDateFormatting.template(event.end, template: "jmm", calendar: calendar, locale: locale)
        return "\(start)–\(end)"
    }
}

/// The current time among today's timed events: a red dot where the rings
/// sit, a red line, and the time.
struct CalendarNowLine: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let red = AtticSurfaceInk.vivid(CalendarDesign.nowRed, tokens: design.tokens).color
        let ringCentre = AtticLayout.circleX + AtticControlSize.statusCircle / 2
        TimelineView(.everyMinute) { context in
            HStack(spacing: 5) {
                Circle().fill(red).frame(width: CalendarDesign.nowDot, height: CalendarDesign.nowDot)
                Capsule().fill(red).frame(height: CalendarDesign.nowLine)
                Text(verbatim: AtticDateFormatting.template(context.date, template: "jmm", calendar: CalendarMonthMath.calendar(),
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
