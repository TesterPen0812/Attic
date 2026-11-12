import SwiftUI

/// The Calendar page's Day view (Accepted 2026-11-09, Timeline): the
/// selected week stays on top, tasks and all-day events sit under it, then
/// the hours. It opens at the current time, or just before the first event
/// on other days. A click opens an event where it is, through the agenda's
/// own row and editing state; later hours move down to make room.
struct CalendarDayView: View {
    let model: CalendarPageModel
    let snapshot: CalendarPageSnapshot
    @ObservedObject var eventRows: CalendarEventRowState
    @ObservedObject var taskRows: CalendarTaskRowState
    let taskActions: CalendarTaskRowActions
    var focus: FocusState<AtticRowFocusID?>.Binding
    var focused: AtticRowFocusID?
    /// The page is on screen: the now line moves only then.
    let isLive: Bool
    let isLoadingEvents: Bool
    let onSelectDay: (DueDay) -> Void

    @Environment(\.atticDesign) private var design
    @State private var scroll = ScrollPosition(y: 0)
    /// The scroll position in whole hours: all the timeline hears of a scroll.
    @State private var bucket: Int?
    /// The day's opening position is waiting for its events to arrive.
    @State private var awaitingEvents = false
    @State private var topHeight: CGFloat = 0
    @State private var measuredOpen: MeasuredOpen?

    private struct MeasuredOpen: Equatable {
        let id: String
        let height: CGFloat
    }

    #if DEBUG
    /// Test seams: how often the timeline was built, and its last size.
    static var timelineBuilds = 0
    static var builtHours = 0
    #endif

    private var day: DueDay { snapshot.selected }

    private var items: [CalendarAgendaItem] {
        snapshot.groups.first { $0.day == day }?.items ?? []
    }

    private var events: [CalendarEvent] {
        items.compactMap { if case let .event(event) = $0 { event } else { nil } }
    }

    private var tasks: [CalendarTaskEntry] {
        items.compactMap { if case let .task(task) = $0 { task } else { nil } }
    }

    var body: some View {
        let allDay = events.filter(\.isAllDay)
        let tasks = self.tasks
        VStack(spacing: 0) {
            if let index = snapshot.pinnedWeekIndex, snapshot.weeks.indices.contains(index) {
                // The week as the week view draws it, neighbouring months too.
                CalendarWeekRow(week: snapshot.weeks[index], isWeekView: true, onSelect: onSelectDay)
                    .equatable()
            }
            GeometryReader { outer in
                VStack(spacing: 0) {
                    if !allDay.isEmpty || !tasks.isEmpty {
                        top(allDay: allDay, tasks: tasks, limit: outer.size.height * CalendarDayDesign.topMaxShare)
                    }
                    GeometryReader { proxy in
                        hours(viewport: proxy.size)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-day")
    }

    // MARK: Tasks and all-day events

    private func top(allDay: [CalendarEvent], tasks: [CalendarTaskEntry], limit: CGFloat) -> some View {
        let agenda = CalendarAgendaDay(group: CalendarAgendaGroup(day: day, relative: nil, items: []), today: snapshot.today,
                                       taskActions: taskActions, rows: taskRows, eventRows: eventRows,
                                       focus: focus, focused: focused, onSelectDay: onSelectDay)
        let estimate = CGFloat(allDay.count + tasks.count) * CalendarDayDesign.topRowMinHeight
            + CalendarDayDesign.topPaddingTop + CalendarDayDesign.topPaddingBottom
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(allDay) { event in
                    CalendarEventRow(event: event, day: day, today: snapshot.today, rows: eventRows, style: .dayAllDay)
                        .frame(minHeight: CalendarDayDesign.topRowMinHeight)
                }
                ForEach(tasks, id: \.id) { task in
                    agenda.taskRow(task)
                        .atticContextMenu { taskActions.commands(for: task.id) }
                        .accessibilityIdentifier("calendar-task-\(task.id.uuidString)")
                }
            }
            .padding(.top, CalendarDayDesign.topPaddingTop)
            .padding(.bottom, CalendarDayDesign.topPaddingBottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - topHeight) > 0.5 { topHeight = height }
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .atticScrollEdgeEffect()
        .frame(height: min(topHeight > 0 ? topHeight : estimate, limit))
        .clipped()
        .accessibilityIdentifier("calendar-day-top")
    }

    // MARK: Hours

    private func hours(viewport: CGSize) -> some View {
        PanelComposerClearance { extra in
            ScrollView(.vertical) {
                timeline(viewport: viewport)
                    .padding(.horizontal, CalendarDayDesign.sideInset)
                    .padding(.bottom, CalendarDesign.agendaBottom)
                    .background(PanelComposerScrollKeeper().frame(width: 0, height: 0))
            }
            .contentMargins(.bottom, extra, for: .scrollContent)
            .scrollIndicators(.never)
            // Clean cut (3 Oct): the native soft scroll edge stays off.
            .atticScrollEdgeEffect()
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: Int.self) { geometry in
                Int(max(0, geometry.contentOffset.y + geometry.contentInsets.top) / CalendarDayDesign.hourHeight)
            } action: { _, new in
                if bucket != new { bucket = new }
            }
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: CalendarDayDesign.scrollFade)
                    Color.black
                }
            }
            .clipped()
            .accessibilityIdentifier("calendar-day-scroll")
            .onAppear { openDay(viewport: viewport.height) }
            .onChange(of: day) { _, _ in openDay(viewport: viewport.height) }
            .onChange(of: isLoadingEvents) { _, loading in
                guard !loading, awaitingEvents else { return }
                awaitingEvents = false
                scrollToOpening(viewport: viewport.height)
            }
        }
    }

    /// A day opens at its place by the clock; if its events are still on
    /// their way, again once they have arrived.
    private func openDay(viewport: CGFloat) {
        scrollToOpening(viewport: viewport)
        awaitingEvents = isLoadingEvents
    }

    private func scrollToOpening(viewport: CGFloat) {
        let offset = openingOffset(viewport: viewport)
        scroll.scrollTo(y: offset)
        bucket = Int(offset / CalendarDayDesign.hourHeight)
    }

    private func openingOffset(viewport: CGFloat) -> CGFloat {
        IdleLatencyTrace.span("calendar_day_offset") {
            let now = model.currentTime
            let opening = CalendarDayLayout.openingOffset(day: day, today: snapshot.today, now: now, events: events,
                                                          calendar: model.calendar)
            let layout = CalendarDayLayout(day: day, today: snapshot.today, now: now, events: events, calendar: model.calendar)
            return CalendarDayLayout.clampedOffset(opening, contentHeight: layout.height + CalendarDesign.agendaBottom, viewport: viewport)
        }
    }

    /// Only today's now line needs the clock, and only on screen.
    static func ticks(day: DueDay, today: DueDay, isLive: Bool) -> Bool { day == today && isLive }

    @ViewBuilder
    private func timeline(viewport: CGSize) -> some View {
        if Self.ticks(day: day, today: snapshot.today, isLive: isLive) {
            TimelineView(.everyMinute) { _ in
                grid(now: model.currentTime, viewport: viewport)
            }
        } else {
            grid(now: model.currentTime, viewport: viewport)
        }
    }

    private func grid(now: Date, viewport: CGSize) -> some View {
        let open = eventRows.rowDay == day ? eventRows.rowID : nil
        let measured = measuredOpen?.id == open ? measuredOpen?.height ?? 0 : 0
        let layout = CalendarDayLayout(day: day, today: snapshot.today, now: now, events: events, calendar: model.calendar,
                                       openEventID: open, openContentHeight: measured)
        let width = max(0, viewport.width - 2 * CalendarDayDesign.sideInset)
        // Only what is near the view is built; a scroll within the hour
        // changes nothing here.
        let shown = bucket ?? Int(openingOffset(viewport: viewport.height) / CalendarDayDesign.hourHeight)
        let range = layout.builtRange(bucket: shown, viewport: viewport.height)
        let hours = layout.hours.filter { range.contains($0.y) }
        let blocks = layout.blocks.filter { $0.isOpen || range.overlaps($0.y...($0.y + $0.height)) }
        #if DEBUG
        let _ = Self.timelineBuilds += 1
        let _ = Self.builtHours = hours.count
        #endif
        return ZStack(alignment: .topLeading) {
            ForEach(hours) { hour in
                CalendarDayHourLine(date: hour.date, isLabelHidden: hour.isLabelHidden, calendar: model.calendar)
                    .offset(y: hour.y - CalendarDayDesign.labelHeight / 2)
            }
            ForEach(blocks) { block in
                let frame = layout.frame(of: block, width: width)
                CalendarDayBlock(block: block, day: day, today: snapshot.today, rows: eventRows, size: frame.size) { height in
                    let next = MeasuredOpen(id: block.id, height: height)
                    if measuredOpen.map({ $0.id != next.id || abs($0.height - height) > 0.5 }) ?? true { measuredOpen = next }
                }
                .offset(x: frame.minX, y: frame.minY)
            }
            if let nowY = layout.nowY {
                CalendarDayNowLine(date: now, calendar: model.calendar)
                    .offset(y: nowY - CalendarDayDesign.labelHeight / 2)
            }
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: layout.room)
    }
}

/// An hour: its time, right-aligned in the hours' column, and its line.
private struct CalendarDayHourLine: View {
    let date: Date
    let isLabelHidden: Bool
    let calendar: Calendar

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        HStack(spacing: CalendarDayDesign.labelGap) {
            Text(verbatim: AtticDateFormatting.template(date, template: "jmm", calendar: calendar, locale: .current))
                .font(.system(size: CalendarDayDesign.labelFont).monospacedDigit())
                .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: tokens).color)
                .lineLimit(1)
                .fixedSize()
                .frame(width: CalendarDayDesign.labelWidth, alignment: .trailing)
                .opacity(isLabelHidden ? 0 : 1)
            Rectangle()
                .fill(tokens.ink(.heading).withAlpha(CalendarDayDesign.lineFill).color)
                .frame(height: CalendarDayDesign.line)
        }
        .frame(height: CalendarDayDesign.labelHeight)
        .accessibilityHidden(true)
    }
}

/// The current time across the hours: the time in the hours' column, a dot,
/// and the line.
private struct CalendarDayNowLine: View {
    let date: Date
    let calendar: Calendar

    @Environment(\.atticDesign) private var design

    var body: some View {
        let red = TasksPanelDesign.vivid(CalendarDesign.nowRed, tokens: design.tokens).color
        HStack(spacing: 0) {
            Text(verbatim: AtticDateFormatting.template(date, template: "jmm", calendar: calendar, locale: .current))
                .font(.system(size: CalendarDayDesign.nowLabelFont, weight: .semibold).monospacedDigit())
                .foregroundStyle(red)
                .lineLimit(1)
                .fixedSize()
                .frame(width: CalendarDayDesign.labelWidth, alignment: .trailing)
            Circle().fill(red)
                .frame(width: CalendarDayDesign.nowDot, height: CalendarDayDesign.nowDot)
                .padding(.leading, CalendarDayDesign.nowDotLead)
            Capsule().fill(red).frame(height: CalendarDayDesign.nowLine)
        }
        .frame(height: CalendarDayDesign.labelHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An event on the hours: the calendar's colour at rest; open, it is a raised
/// card as tall as its contents. The contents are the agenda's own row, so
/// opening and saving are the same path as everywhere else on the page.
private struct CalendarDayBlock: View {
    let block: CalendarDayLayout.Block
    let day: DueDay
    let today: DueDay
    @ObservedObject var rows: CalendarEventRowState
    let size: CGSize
    let onOpenHeight: (CGFloat) -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = AtticControlShape.shape(cornerRadius: CalendarDayDesign.blockRadius, exponent: AtticShape.controlExponent)
        let fill = block.isOver ? CalendarDayDesign.blockFillOver : CalendarDayDesign.blockFill
        CalendarEventRow(event: block.event, day: day, today: today, rows: rows,
                         style: .dayBlock(showsMeta: block.showsMeta, isOver: block.isOver, paddingY: block.paddingY))
            // Open, the row's own height decides the block's and never
            // the other way round, so the two cannot chase each other.
            .fixedSize(horizontal: false, vertical: block.isOpen)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if block.isOpen { onOpenHeight(height) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(shape)
            .background {
                if block.isOpen {
                    Color.clear
                        .atticRaisedMaterial(cornerRadius: CalendarDayDesign.blockRadius, interactive: false)
                        .allowsHitTesting(false)
                } else {
                    shape.fill(block.event.colour.rgba.withAlpha(fill).color)
                }
            }
    }
}
