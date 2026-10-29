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

/// A day's key (Keys, option 3d): raised from today on, flat before,
/// pressed when selected (ink, or red on today). The day's number, and its
/// event dots and open-task ring under it.
struct CalendarKey: View {
    let day: CalendarGridDay
    let action: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let style = day.style
        let red = TasksPanelDesign.vivid(CalendarDesign.red, tokens: tokens)
        let number: Color = switch style {
        case .selected, .selectedToday: .white
        case .flat: TasksPanelDesign.toneInk(.meta, tokens: tokens).color
        case .raised: day.isToday ? red.color : tokens.ink(.heading).color
        }
        Button(action: action) {
            VStack(spacing: CalendarDesign.dayToDots) {
                Text(verbatim: String(day.day.day))
                    .font(.system(size: CalendarDesign.dayFont, weight: day.isSelected || day.isToday ? .semibold : .regular)
                        .monospacedDigit())
                    .foregroundStyle(number)
                    .frame(height: CalendarDesign.dayLine)
                CalendarDayMarksView(marks: day.marks, isPast: day.isPast)
            }
            .frame(maxWidth: .infinity)
            .frame(height: CalendarDesign.keyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarKeyButtonStyle(style: style))
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

/// The key's material. Raised keys are the panel's button material at rest
/// (not interactive glass: up to 31 share one glass group, so they stay
/// cheap); a press shows as the material's pressed fill.
struct CalendarKeyButtonStyle: ButtonStyle {
    let style: CalendarKeyStyle

    func makeBody(configuration: Configuration) -> some View {
        CalendarKeyFace(configuration: configuration, style: style)
    }
}

private struct CalendarKeyFace: View {
    let configuration: ButtonStyleConfiguration
    let style: CalendarKeyStyle

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    var body: some View {
        let tokens = design.tokens
        let shape = AtticControlShape.shape(cornerRadius: CalendarDesign.keyRadius, exponent: cornerExponent)
        Group {
            switch style {
            case .raised:
                configuration.label
                    .atticRaisedMaterial(cornerRadius: CalendarDesign.keyRadius,
                                         state: configuration.isPressed ? .pressed : .rest, interactive: false)
            case .flat:
                configuration.label
                    .background { if configuration.isPressed { shape.fill(tokens.pressed.color) } }
            case .selected, .selectedToday:
                let fill = style == .selectedToday ? CalendarDesign.red : tokens.ink(.heading)
                configuration.label
                    .background {
                        // The pressed key: the fill, darkened from the top
                        // edge (the design's inset shadow).
                        shape.fill(fill.color)
                            .overlay {
                                shape.fill(LinearGradient(colors: [.black.opacity(0.22), .clear],
                                                          startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)))
                            }
                    }
            }
        }
        .contentShape(shape)
    }
}
