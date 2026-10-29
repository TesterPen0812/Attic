import SwiftUI

/// The Calendar page's month controls on the panel's top row (owner's panel
/// design, 28 Oct): the month pill ("**October** 2026 ⌄"), which collapses
/// the grid to the week and back, then previous and next. They are the
/// panel's top-row glass buttons, in one glass group. Kept in a view of
/// their own so they can move into the shared top row unchanged.
struct CalendarTopRowControls: View {
    let month: CalendarMonth
    let isWeekView: Bool
    let onToggleWeekView: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let flat = design.effectiveControls != .liquidGlass
        AtticControlGroup {
            HStack(spacing: CalendarDesign.controlsGap) {
                monthPill(flat: flat)
                Spacer(minLength: CalendarDesign.controlsGap)
                AtticRaisedButton(systemName: "chevron.left",
                                  label: isWeekView ? "Previous week" : "Previous month",
                                  size: AtticControlSize.panelButton, emphasisedGlyph: true, flat: flat,
                                  cornerRadius: AtticRadius.header, action: onPrevious)
                    .accessibilityIdentifier("calendar-previous")
                AtticRaisedButton(systemName: "chevron.right",
                                  label: isWeekView ? "Next week" : "Next month",
                                  size: AtticControlSize.panelButton, emphasisedGlyph: true, flat: flat,
                                  cornerRadius: AtticRadius.header, action: onNext)
                    .accessibilityIdentifier("calendar-next")
            }
        }
        .atticDesignCorners()
        .frame(height: AtticControlSize.headerControl)
    }

    private func monthPill(flat: Bool) -> some View {
        let tokens = design.tokens
        let title = Self.monthTitle(month)
        let grey = TasksPanelDesign.toneInk(.meta, tokens: tokens).color
        return Button(action: onToggleWeekView) {
            HStack(spacing: CalendarDesign.pillGap) {
                Text(verbatim: title.month)
                    .font(.system(size: CalendarDesign.pillFont, weight: .bold))
                    .tracking(CalendarDesign.monthTracking)
                    .foregroundStyle(tokens.ink(.heading).color)
                Text(verbatim: title.year)
                    .font(.system(size: CalendarDesign.pillFont).monospacedDigit())
                    .foregroundStyle(grey)
                CalendarChevron()
                    .stroke(grey, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                    .frame(width: CalendarDesign.chevronSize.width, height: CalendarDesign.chevronSize.height)
                    .rotationEffect(.degrees(isWeekView ? -90 : 0))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, CalendarDesign.pillPaddingLeading)
            .padding(.trailing, CalendarDesign.pillPaddingTrailing)
            .frame(height: AtticControlSize.headerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: AtticRadius.header, flat: flat))
        .focusEffectDisabled()
        .help(isWeekView ? String(localized: "Show month") : String(localized: "Show week only"))
        .accessibilityLabel("\(title.month) \(title.year)")
        .accessibilityIdentifier("calendar-month-pill")
    }

    /// "October", "2026": the month's stand-alone name and the year without
    /// grouping.
    static func monthTitle(_ month: CalendarMonth, locale: Locale = .current) -> (month: String, year: String) {
        let calendar = CalendarMonthMath.calendar()
        let date = month.firstDay.startDate(in: calendar) ?? Date()
        let name = TaskRowPresentation.format(date, template: "LLLL", calendar: calendar, locale: locale)
        return (name, String(month.year))
    }
}

/// The design's down chevron (10 × 7 viewBox: 1.5,1.5 → 5,5 → 8.5,1.5).
struct CalendarChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
