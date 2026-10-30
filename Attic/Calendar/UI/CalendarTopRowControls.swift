import SwiftUI

/// The Calendar page's header (Accepted 2026-10-30, "Calendar page",
/// Header): "October 2026" in plain bold text after the pin, with no ⌄;
/// tapping it still folds the grid to the week and back.
struct CalendarMonthTitle: View {
    let month: CalendarMonth
    let isWeekView: Bool
    let onToggleWeekView: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let title = Self.monthTitle(month)
        Button(action: onToggleWeekView) {
            HStack(spacing: CalendarDesign.titleGap) {
                Text(verbatim: title.month)
                    .font(.system(size: CalendarDesign.pillFont, weight: .bold))
                    .tracking(CalendarDesign.monthTracking)
                    .foregroundStyle(tokens.ink(.heading).color)
                Text(verbatim: title.year)
                    .font(.system(size: CalendarDesign.pillFont).monospacedDigit())
                    .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: tokens).color)
            }
            .lineLimit(1)
            .fixedSize()
            .frame(height: AtticControlSize.headerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isWeekView ? String(localized: "Show month") : String(localized: "Show week only"))
        .accessibilityLabel("\(title.month) \(title.year)")
        .accessibilityValue(isWeekView ? String(localized: "Week") : String(localized: "Month"))
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

/// The Calendar page's own switch on the top row: ‹ › in one capsule before
/// ••• (Accepted 2026-10-30), the top row's 27 pt glass with 21 pt cells in
/// its 3 pt inset.
struct CalendarMonthArrows: View {
    let isWeekView: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        HStack(spacing: CalendarDesign.arrowsGap) {
            arrow("chevron.left", label: isWeekView ? "Previous week" : "Previous month", action: onPrevious)
                .accessibilityIdentifier("calendar-previous")
            arrow("chevron.right", label: isWeekView ? "Next week" : "Next month", action: onNext)
                .accessibilityIdentifier("calendar-next")
        }
        .padding(AtticPageButtonMetrics.inset)
        .frame(height: AtticControlSize.headerControl)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false))
        .atticDesignCorners()
        .accessibilityElement(children: .contain)
    }

    private func arrow(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        CalendarArrowCell(systemName: systemName, label: label, action: action)
    }

    /// The capsule's width.
    static var width: CGFloat {
        2 * AtticPageButtonMetrics.inset + 2 * AtticPageButtonMetrics.segment + CalendarDesign.arrowsGap
    }
}

/// One arrow: a 21 pt cell, the hover's quiet fill under the pointer.
private struct CalendarArrowCell: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let side = AtticPageButtonMetrics.segment
        let radius = AtticShape.controlRadius(height: side)
        Button(action: action) {
            AtticIcon(systemName: systemName, size: AtticPageButtonMetrics.iconSize, weight: .semibold, ink: .glyph)
                .frame(width: side, height: side)
                .background {
                    if hovered {
                        AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent)
                            .fill(AtticSelectionMarker.hoverFill(design.tokens).color)
                    }
                }
                .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: side)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
