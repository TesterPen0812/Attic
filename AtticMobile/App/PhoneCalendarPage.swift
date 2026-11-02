import SwiftUI

/// Calendar A + rows 2: one week under the month title, expandable to a
/// full month, and an agenda with fixed time labels and colour dots.
struct PhoneCalendarPage: View {
    let tasks: [PhoneLibrary.TaskRow]
    let syntheticEventsEnabled: Bool
    let onOpenTask: (UUID) -> Void

    @State private var selectedDay = DueDay(date: Date(), calendar: .autoupdatingCurrent)
    @State private var monthExpanded = false
    @State private var days: [PhoneCalendar.Day] = []
    @State private var collapsedDays: Set<DueDay> = []
    @State private var presentedEvent: CalendarEvent?
    @State private var problem: String?

    private var calendar: Calendar { .autoupdatingCurrent }
    private var today: DueDay { DueDay(date: Date(), calendar: calendar) }

    private var selectedDate: Date {
        selectedDay.startDate(in: calendar) ?? Date()
    }

    private var visibleDates: [Date] {
        let start: Date
        let count: Int
        if monthExpanded {
            let month = calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
            let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
            start = calendar.date(byAdding: .day, value: -leading, to: month) ?? month
            let range = calendar.range(of: .day, in: .month, for: month)?.count ?? 31
            count = ((leading + range + 6) / 7) * 7
        } else {
            start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
            count = 7
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var taskKey: String {
        selectedDay.rawValue + "/" + tasks.map {
            "\($0.id.uuidString):\($0.updatedAt.timeIntervalSinceReferenceDate):\($0.dueDay?.rawValue ?? "")"
        }.joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedDate.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 33, weight: .bold))
                        .tracking(-0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if selectedDay != today {
                        Button("Today") { selectedDay = today }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier("phone-calendar-today")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 18)

                monthGrid
                    .padding(.horizontal, 17)

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { monthExpanded.toggle() }
                } label: {
                    Capsule().fill(Color.secondary.opacity(0.28))
                        .frame(width: 38, height: 5)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monthExpanded ? "Collapse month" : "Expand month")
                .accessibilityIdentifier("phone-calendar-month-toggle")
                .gesture(DragGesture(minimumDistance: 20).onEnded { movement in
                    if movement.translation.height > 20 { withAnimation { monthExpanded = true } }
                    if movement.translation.height < -20 { withAnimation { monthExpanded = false } }
                })

                if let problem {
                    ContentUnavailableView("Calendar unavailable", systemImage: "calendar",
                                           description: Text(problem))
                } else if days.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    ForEach(days) { day in
                        let headerDate = day.day.startDate(in: calendar) ?? Date()
                        let isCollapsed = collapsedDays.contains(day.day)
                        Button {
                            if isCollapsed { collapsedDays.remove(day.day) }
                            else { collapsedDays.insert(day.day) }
                        } label: {
                            HStack(spacing: 8) {
                                Text(dayTitle(day.day))
                                    .font(.system(size: 17, weight: .semibold))
                                Text(headerDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isCollapsed {
                                    Text(day.rows.count, format: .number)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 21)
                            .frame(minHeight: 53)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(dayTitle(day.day)), \(day.rows.count) items")
                        if !isCollapsed {
                            ForEach(day.rows) { row in calendarRow(row) }
                        }
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .task(id: taskKey) {
            do {
                let model = try PhoneCalendar.synthetic(starting: selectedDay,
                                                        includingFixtureEvents: syntheticEventsEnabled)
                let entries = await model.agenda(starting: selectedDay, dayCount: 7, tasks: tasks)
                days = entries
                problem = nil
            } catch {
                days = []
                problem = error.localizedDescription
            }
        }
        .sheet(item: $presentedEvent) { event in
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text(event.title).font(.system(size: 30, weight: .bold))
                    Label(event.isAllDay ? "All day" : event.start.formatted(date: .abbreviated, time: .shortened),
                          systemImage: "calendar")
                    Label(event.calendarTitle, systemImage: "circle.fill")
                        .foregroundStyle(Color(red: event.colour.red, green: event.colour.green, blue: event.colour.blue))
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { presentedEvent = nil }
                } }
            }
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { offset in
                    let first = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
                    let day = calendar.date(byAdding: .day, value: offset, to: first) ?? first
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
            }
            let dates = visibleDates
            ForEach(0..<(dates.count / 7), id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(dates[week * 7 + column])
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let day = DueDay(date: date, calendar: calendar)
        let isToday = day == today
        let selected = day == selectedDay
        let sameMonth = calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        let hasTasks = tasks.contains { $0.dueDay == day }
        let eventDots = days.first(where: { $0.day == day })?.rows.compactMap { row -> CalendarEventColour? in
            if case let .event(event, _) = row { return event.colour }
            return nil
        }.prefix(2) ?? []
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 16, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.white : sameMonth ? Color.primary : Color.secondary)
                    .frame(width: 35, height: 35)
                    .background {
                        if isToday { Circle().fill(Color.accentColor) }
                        else if selected { Circle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
                    }
                HStack(spacing: 2) {
                    if hasTasks { Circle().fill(Color.primary).frame(width: 3, height: 3) }
                    ForEach(Array(eventDots.enumerated()), id: \.offset) { _, c in
                        Circle().fill(Color(red: c.red, green: c.green, blue: c.blue))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dayTitle(_ date: DueDay) -> String {
        let next = calendar.date(byAdding: .day, value: 1, to: Date())
            .map { DueDay(date: $0, calendar: calendar) }
        if date == today { return "Today" }
        if date == next { return "Tomorrow" }
        return date.startDate(in: calendar)?.formatted(.dateTime.weekday(.wide)) ?? date.rawValue
    }

    @ViewBuilder private func calendarRow(_ row: PhoneCalendar.Row) -> some View {
        switch row {
        case let .event(event, past):
            Button { presentedEvent = event } label: {
                HStack(spacing: 12) {
                    Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Circle().fill(Color(red: event.colour.red, green: event.colour.green, blue: event.colour.blue))
                        .frame(width: 8, height: 8)
                        .frame(width: 22)
                    Text(event.title)
                        .font(.body)
                        .foregroundStyle(past ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case let .task(task):
            Button { onOpenTask(task.id) } label: {
                HStack(spacing: 12) {
                    Text(task.dueTimeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Image(systemName: task.listedStatus == .done ? "checkmark.circle.fill" :
                            task.listedStatus == .backlog ? "circle.dashed" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(task.title).font(.body)
                        .foregroundStyle(task.listedStatus == .done ? Color.secondary : Color.primary)
                        .lineLimit(2)
                    if task.priority == .high {
                        Text("!!").font(.system(size: 13, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
