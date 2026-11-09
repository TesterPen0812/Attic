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
                    .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: tokens).color)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(height: AtticControlSize.headerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.rounded(radius: AtticRadius.header, height: AtticControlSize.headerControl))
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
        let name = AtticDateFormatting.template(date, template: "LLLL", calendar: calendar, locale: locale)
        return (name, String(month.year))
    }
}

/// ‹ Today › in one 27 pt capsule before ••• (Adaptive picks C3, Accepted
/// 2026-11-01). Today folds away on today; the existing arrows keep their
/// 21 pt cells and 3 pt inset.
struct CalendarMonthArrows: View {
    let isWeekView: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    var todayShown = false
    var onToday: () -> Void = {}

    @Environment(\.atticDesign) private var design

    var body: some View {
        HStack(spacing: CalendarDesign.arrowsGap) {
            arrow("chevron.left", label: isWeekView ? "Previous week" : "Previous month", action: onPrevious)
                .accessibilityIdentifier("calendar-previous")
            if todayShown {
                Button(action: onToday) {
                    Text("Today")
                        .font(.system(size: CalendarDesign.navigationTodayFont, weight: .medium))
                        .foregroundStyle(design.tokens.ink(.heading).color)
                        .frame(width: CalendarDesign.navigationTodayWidth, height: AtticPageButtonMetrics.segment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .atticOwnFocusRing(.rounded(radius: AtticShape.controlRadius(height: AtticPageButtonMetrics.segment), height: AtticPageButtonMetrics.segment))
                .help(String(localized: "Go to today (⌘T)"))
                .accessibilityIdentifier("calendar-today")
                .transition(.opacity)
            }
            arrow("chevron.right", label: isWeekView ? "Next week" : "Next month", action: onNext)
                .accessibilityIdentifier("calendar-next")
        }
        .padding(AtticPageButtonMetrics.inset)
        .frame(height: AtticControlSize.headerControl)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false))
        .atticDesignCorners()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-navigation")
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: todayShown)
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
        .atticOwnFocusRing(.rounded(radius: radius, height: side))
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
