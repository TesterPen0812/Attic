import SwiftUI

/// The Calendar page's sizes, in points: the owner's design (Task Panel v11,
/// the Calendar page) is drawn at 2×, so each value is the design's px ÷ 2.
enum CalendarDesign {
    // Weekday letters: 15 px semibold on a 22 px line, 20 px above, 8 px below.
    static let weekdayFont: CGFloat = 7.5
    static let weekdayLine: CGFloat = 11
    static let weekdayTop: CGFloat = 10
    static let weekdayBottom: CGFloat = 4
    static let weekdayRowHeight: CGFloat = weekdayTop + weekdayLine + weekdayBottom
    /// 0.04 em.
    static let weekdayTracking: CGFloat = 0.3

    // Grid: 30 px from the panel's sides, 7 px between keys.
    static let gridInset: CGFloat = 15
    static let keyGap: CGFloat = 3.5
    // Days: 60 px tall; 2 px above and 7 px below each row.
    static let keyHeight: CGFloat = 30
    /// The selected day's key (Accepted 2026-10-30): a 60 × 60 px whole
    /// superellipse on curve 1.4, so rounded by half its side.
    static let keySize: CGFloat = 30
    static let keyCornerRadius: CGFloat = AtticShape.controlRadius(height: keySize)
    static let keyExponent: CGFloat = AtticShape.controlExponent
    static let weekTop: CGFloat = 1
    static let weekBottom: CGFloat = 3.5
    static let weekPitch: CGFloat = weekTop + keyHeight + weekBottom
    // The number: 21 px on a 24 px line; 5 px to the dots.
    static let dayFont: CGFloat = 10.5
    static let dayLine: CGFloat = 12
    static let dayToDots: CGFloat = 2.5
    // Dots: 6 px, 4 px apart; the open-task ring 1.5 px.
    static let dot: CGFloat = 3
    static let dotGap: CGFloat = 2
    static let ringWidth: CGFloat = 0.75
    static let maxEventDots = 3

    // Agenda: 20 px from the panel's sides, 8 px under the grid, 160 px of
    // room at the end for the footer.
    static let agendaInset: CGFloat = 10
    static let agendaTop: CGFloat = 4
    static let agendaBottom: CGFloat = 80
    // A day: 8 px apart, radius 48 px (so padding 13 px), 10 px tile to rows.
    static let dayPadding: CGFloat = dayPadding(radius: dayRadius)
    /// A day card's padding grows with its radius (Shapes): the design's
    /// max(6, round(10 + (R − 36) / 4)) px, R in px.
    static func dayPadding(radius: CGFloat) -> CGFloat {
        max(6, (10 + (radius * 2 - 36) / 4).rounded()) / 2
    }
    static let dayGap: CGFloat = 4
    static let dayRadius: CGFloat = AtticRadius.card
    /// Today's card is a surface: a squircle (Shapes, Accepted 2026-10-30).
    static let dayCardExponent: CGFloat = AtticShape.surfaceExponent
    static let tileToRows: CGFloat = 5
    // Date (Accepted 2026-10-30: plain text, no box): 128 px wide,
    // padding 14 16 16 16 px.
    static let tileWidth: CGFloat = 64
    static let tilePaddingTop: CGFloat = 7
    static let tilePaddingX: CGFloat = 8
    static let tilePaddingBottom: CGFloat = 8
    // Date and Today/Tomorrow 22 px (650) on 28 px; weekday 19 px on 26 px.
    static let tileDateFont: CGFloat = 11
    static let tileDateLine: CGFloat = 14
    static let tileWeekdayFont: CGFloat = 9.5
    static let tileWeekdayLine: CGFloat = 13

    // A run of free days ("10–11 Oct"): a 40 px line, the card's padding
    // plus 16 px in, 19 px text, 14 px to a 1 px hairline.
    static let freeHeight: CGFloat = 20
    static let freeInsetX: CGFloat = dayPadding + 8
    static let freeFont: CGFloat = 9.5
    static let freeGap: CGFloat = 7
    static let freeHairline: CGFloat = 0.5

    /// The agenda fades in over 40 px under the pinned week (Accepted
    /// 2026-10-30, "Scrolling": a plain gradient, no native soft edge).
    static let agendaFade: CGFloat = 20

    // Event rows: padding 12 × 14 px, the 28 px dot column, 20 px to the
    // title; dot 12 px; title 24 px (500) on 30 px; second line 22 px on
    // 30 px, 3 px under the title.
    static let eventPaddingY: CGFloat = 6
    static let eventDot: CGFloat = 6
    static let eventTitleFont: CGFloat = 12
    static let eventLine: CGFloat = 15
    static let eventMetaFont: CGFloat = 11
    static let eventMetaTop: CGFloat = 1.5
    static let eventRadius: CGFloat = AtticRadius.row
    // Now line: 10 px dot, 2 px line, 18 px time; 4 px above and below.
    static let nowDot: CGFloat = 5
    static let nowLine: CGFloat = 1
    static let nowFont: CGFloat = 9
    static let nowPaddingY: CGFloat = 2

    // "No matches": 24 × 18 px padding, 22 px text.
    static let noMatchesPaddingY: CGFloat = 12
    static let noMatchesPaddingX: CGFloat = 9
    static let noMatchesFont: CGFloat = 11

    // Top row: month and year 24 px.
    static let pillFont: CGFloat = 12
    /// -0.015 em.
    static let monthTracking: CGFloat = -0.18
    static let controlsGap: CGFloat = 3
    /// The header (Accepted 2026-10-30): month and year 9 px apart; ‹ ›
    /// 1 pt apart in their capsule.
    static let titleGap: CGFloat = 4.5
    static let arrowsGap: CGFloat = 1

    // Footer: Today 61 px tall, 22 px padding, 22 px medium text.
    static let footerHeight: CGFloat = AtticControlSize.headerControl
    static let todayPaddingX: CGFloat = 11
    static let todayFont: CGFloat = 11

    // The design's own colours (drawn on white), for the greys that have no
    // Tasks tone of their own; they are made see-through on glass.
    static let red = AtticRGBA(red: 222 / 255, green: 56 / 255, blue: 46 / 255, alpha: 1)
    static let nowRed = AtticRGBA(red: 232 / 255, green: 64 / 255, blue: 52 / 255, alpha: 1)

    /// The page's search window: a year back, two years ahead.
    static let searchYearsBack = 1
    static let searchYearsAhead = 2

    /// The design's ease, `cubic-bezier(0.3, 0.7, 0.2, 1)` (the Tasks
    /// search's motion: it opens in 240 ms and leaves in 120 ms).
    static func searchAnimation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return opening ? TasksDesignMetrics.curve(0.24) : .easeOut(duration: 0.12)
    }
}

extension CalendarEventColour {
    var rgba: AtticRGBA { AtticRGBA(red: red, green: green, blue: blue, alpha: 1) }
}
