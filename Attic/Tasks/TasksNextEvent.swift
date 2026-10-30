import Combine
import Foundation
import SwiftUI

/// The next event in Now (Accepted 2026-10-29, "Tasks: the next event in
/// Now"): one read-only row at the top of Today while an event is still
/// ahead today, its calendar's dot, its time and its title. A click opens
/// that day on the Calendar page.
struct TasksNextEvent: Equatable, Sendable {
    let id: String
    let day: DueDay
    /// The start, as the Calendar writes a time ("16:30").
    let time: String
    let title: String
    let colour: CalendarEventColour

    /// Today's first timed event that has not ended yet (the design's
    /// `nextToday`): all-day events have no time to show, and one already
    /// over is no longer ahead. By start, then title, as the agenda orders.
    static func pick(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> CalendarEvent? {
        events.filter { !$0.isAllDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sortedForAgenda()
            .first
    }

    init(_ event: CalendarEvent, calendar: Calendar, locale: Locale) {
        id = event.id
        day = DueDay(date: event.start, calendar: calendar)
        time = TaskRowPresentation.format(event.start, template: "jmm", calendar: calendar, locale: locale)
        title = event.title
        colour = event.colour
    }
}

/// Keeps `TasksNextEvent` current for the Tasks page. Engineering default
/// (w2-tasks brief): Tasks never asks for Calendar access. The row shows
/// only once access has been granted (on the Calendar page) and only while
/// the "Next event in Now" switch is on.
@MainActor
final class TasksNextEventFeed {
    private let source: CalendarEventSource
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let locale: Locale
    private var enabled = false
    private var timer: Timer?
    private var enabledObservation: AnyCancellable?

    /// The page's sink; called only when the row changes.
    var onUpdate: ((TasksNextEvent?) -> Void)?
    private(set) var current: TasksNextEvent?

    init(source: CalendarEventSource, now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { CalendarMonthMath.calendar() }, locale: Locale = .current) {
        self.source = source
        self.now = now
        self.calendar = calendar
        self.locale = locale
        // This source is the feed's own instance, so its one change hook is
        // free (the Calendar page keeps its own source and hook).
        source.onChange = { [weak self] in self?.refresh() }
    }

    /// Follows the setting (`AppSettings.nextEventInNow`).
    func follow(_ enabled: AnyPublisher<Bool, Never>) {
        enabledObservation = enabled.removeDuplicates().sink { [weak self] on in self?.setEnabled(on) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        refresh()
    }

    /// Reads today's events again: on a calendar change, when the page
    /// shows, when the shown event ends and at midnight.
    func refresh() {
        timer?.invalidate()
        timer = nil
        // Never `requestAccess()` here: only the Calendar page asks.
        guard enabled, source.accessState == .granted else { publish(nil); return }
        let date = now(), calendar = calendar()
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { publish(nil); return }
        let next = TasksNextEvent.pick(source.events(in: DateInterval(start: start, end: end)), now: date, calendar: calendar)
        publish(next.map { TasksNextEvent($0, calendar: calendar, locale: locale) })
        let wake = min(next?.end ?? end, end)
        let timer = Timer(fire: wake.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func publish(_ event: TasksNextEvent?) {
        guard event != current else { return }
        current = event
        onUpdate?(event)
    }
}

/// The next event's row, at the top of Today: the calendar's dot where a
/// task's ring sits, the time in the header's grey, then the title, all on
/// a task row's line (the design's 28 + 20 px columns and row padding). A
/// hover tints it (3.5 %); a click opens that day on the Calendar page.
struct TasksNextEventRow: View {
    static let height: CGFloat = TasksRowDesign.height(twoLine: false, tiles: false)
    /// The dot: 12 px in the design.
    static let dot: CGFloat = 6
    /// Between the time and the title: 10 px.
    static let gap: CGFloat = 5
    /// The hover tint: rgba(0,0,0,0.035) on white, the title's ink here.
    static let hoverAlpha = 0.035

    let event: TasksNextEvent
    let open: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        let d = TasksRowDesign.self
        let ringCentre = AtticLayout.circleX + AtticControlSize.statusCircle / 2
        let font = Font.system(size: 12, weight: .medium).monospacedDigit()
        Button(action: open) {
            ZStack(alignment: .topLeading) {
                Squircle(cornerRadius: d.radius, exponent: AtticShape.surfaceExponent)
                    .fill(tokens.ink(.heading).withAlpha(hovered ? Self.hoverAlpha : 0).color)
                    .padding(.horizontal, AtticLayout.rowHighlightInset)
                Circle()
                    .fill(event.colour.rgba.color)
                    .frame(width: Self.dot, height: Self.dot)
                    .padding(.leading, ringCentre - Self.dot / 2)
                    .padding(.top, d.paddingY + (d.line - Self.dot) / 2)
                HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                    Text(verbatim: event.time)
                        .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: tokens).color)
                        .fixedSize()
                    Text(verbatim: event.title)
                        .foregroundStyle(tokens.ink(.heading).color)
                        .truncationMode(.tail)
                }
                .font(font)
                .lineLimit(1)
                .frame(height: d.line)
                .padding(.leading, TasksDesignMetrics.textX)
                .padding(.trailing, AtticLayout.rowHighlightInset + d.paddingX)
                .padding(.top, d.paddingY)
            }
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(design.reduceMotion ? nil : AtticMotionPreset.hover.animation(reduceMotion: false), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(event.time) \(event.title)"))
        .accessibilityIdentifier("tasks-next-event")
    }
}
