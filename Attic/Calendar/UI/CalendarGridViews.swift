import SwiftUI

/// The weekday letters over the grid: semibold, weekends lighter, Monday
/// first.
struct CalendarWeekdayRow: View {
    @Environment(\.atticDesign) private var design

    static func letters(locale: Locale = .current) -> [String] {
        var calendar = CalendarMonthMath.calendar()
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols // Sunday first
        return (0..<7).map { symbols[($0 + 1) % 7] }
    }

    var body: some View {
        let tokens = design.tokens
        let weekday = TasksPanelDesign.toneInk(.date, tokens: tokens).color
        let weekend = TasksPanelDesign.toneInk(.meta, tokens: tokens).color.opacity(0.75)
        HStack(spacing: CalendarDesign.keyGap) {
            ForEach(Array(Self.letters().enumerated()), id: \.offset) { index, letter in
                Text(verbatim: letter)
                    .font(.system(size: CalendarDesign.weekdayFont, weight: .semibold))
                    .tracking(CalendarDesign.weekdayTracking)
                    .foregroundStyle(index > 4 ? weekend : weekday)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarDesign.weekdayLine)
        .padding(.top, CalendarDesign.weekdayTop)
        .padding(.bottom, CalendarDesign.weekdayBottom)
        .padding(.horizontal, CalendarDesign.gridInset)
        .accessibilityHidden(true)
    }
}

/// One row of keys. Days of the neighbouring months are hidden while the
/// whole month shows and shown in the week view.
struct CalendarWeekRow: View, Equatable {
    let week: CalendarGridWeek
    let isWeekView: Bool
    let onSelect: (DueDay) -> Void

    nonisolated static func == (lhs: CalendarWeekRow, rhs: CalendarWeekRow) -> Bool {
        lhs.week == rhs.week && lhs.isWeekView == rhs.isWeekView
    }

    var body: some View {
        HStack(spacing: CalendarDesign.keyGap) {
            ForEach(week.days) { day in
                let hidden = !day.isInMonth && !isWeekView
                CalendarKey(day: day) { onSelect(day.day) }
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
            }
        }
        .padding(.top, CalendarDesign.weekTop)
        .padding(.bottom, CalendarDesign.weekBottom)
        .padding(.horizontal, CalendarDesign.gridInset)
    }
}

/// A day (Accepted 2026-10-30, "Calendar page: Grid"): flat in every
/// month. The number (today red, past days grey, the rest ink) and its
/// event dots and open-task ring under it. The selected day is the older
/// big key (owner, 2026-10-31): ink with a white number, red when it is
/// today.
struct CalendarKey: View {
    let day: CalendarGridDay
    let action: () -> Void

    @Environment(\.atticDesign) private var design

    static func numberColour(_ number: CalendarKeyNumber, tokens: AtticColorTokens) -> AtticRGBA {
        switch number {
        case .red: TasksPanelDesign.vivid(CalendarDesign.red, tokens: tokens)
        case .grey: TasksPanelDesign.toneInk(.meta, tokens: tokens)
        case .ink: tokens.ink(.heading)
        case .white: AtticRGBA(red: 1, green: 1, blue: 1)
        }
    }

    var body: some View {
        let tokens = design.tokens
        Button(action: action) {
            VStack(spacing: CalendarDesign.dayToDots) {
                Text(verbatim: String(day.day.day))
                    .font(.system(size: CalendarDesign.dayFont, weight: day.isSelected || day.isToday ? .semibold : .regular)
                        .monospacedDigit())
                    .foregroundStyle(Self.numberColour(day.number, tokens: tokens).color)
                    .frame(height: CalendarDesign.dayLine)
                CalendarDayMarksView(marks: day.marks, isPast: day.isPast)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CalendarDesign.keyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarKeyButtonStyle(style: day.style))
        .focusEffectDisabled()
        .accessibilityLabel(Self.accessibilityName(day.day))
        .accessibilityAddTraits(day.isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar-day-\(day.day.rawValue)")
    }

    static func accessibilityName(_ day: DueDay, locale: Locale = .current) -> String {
        let calendar = CalendarMonthMath.calendar()
        guard let date = day.startDate(in: calendar) else { return day.rawValue }
        return TaskRowPresentation.format(date, template: "EEEEdMMMM", calendar: calendar, locale: locale)
    }
}

/// Up to three dots in the calendars' colours, then a hollow ring for open
/// tasks (red once the day has passed). A past day without open tasks
/// shows its dots faint.
struct CalendarDayMarksView: View {
    let marks: CalendarDayMarks
    let isPast: Bool

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        HStack(spacing: CalendarDesign.dotGap) {
            ForEach(Array(marks.eventColours.enumerated()), id: \.offset) { _, colour in
                Circle().fill(colour.rgba.color)
                    .frame(width: CalendarDesign.dot, height: CalendarDesign.dot)
            }
            if marks.hasOpenTasks {
                let ring = isPast ? TasksPanelDesign.vivid(CalendarDesign.red, tokens: tokens)
                    : TasksPanelDesign.toneInk(.meta, tokens: tokens)
                Circle().strokeBorder(ring.color, lineWidth: CalendarDesign.ringWidth)
                    .frame(width: CalendarDesign.dot, height: CalendarDesign.dot)
            }
        }
        .frame(height: CalendarDesign.dot)
        .opacity(isPast && !marks.hasOpenTasks ? 0.4 : 1)
        .accessibilityHidden(true)
    }
}

/// The selected day's key, as the older page drew it (owner, 2026-10-31):
/// the whole cell, radius 10 pt, filled ink (red on today) and darkened
/// from its top edge; a press on another day shows the press grey there.
/// No raised material in the grid.
struct CalendarKeyButtonStyle: ButtonStyle {
    let style: CalendarKeyStyle

    func makeBody(configuration: Configuration) -> some View {
        CalendarKeyFace(configuration: configuration, style: style)
    }

    /// The key's fill: the selected ink or red, the press grey, or none.
    static func fill(style: CalendarKeyStyle, isPressed: Bool, tokens: AtticColorTokens) -> AtticRGBA? {
        switch style {
        case .selected: tokens.ink(.heading)
        case .selectedToday: CalendarDesign.red
        case .plain: isPressed ? tokens.pressed : nil
        }
    }
}

private struct CalendarKeyFace: View {
    let configuration: ButtonStyleConfiguration
    let style: CalendarKeyStyle

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    var body: some View {
        let shape = AtticControlShape.shape(cornerRadius: CalendarDesign.keyRadius, exponent: cornerExponent)
        let fill = CalendarKeyButtonStyle.fill(style: style, isPressed: configuration.isPressed, tokens: design.tokens)
        configuration.label
            .background {
                if let fill {
                    shape.fill(fill.color)
                        .overlay {
                            if style != .plain {
                                // The pressed key: darkened from the top edge
                                // (the design's inset shadow).
                                shape.fill(LinearGradient(colors: [.black.opacity(0.22), .clear],
                                                          startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)))
                            }
                        }
                }
            }
            .contentShape(shape)
    }
}
