import CoreGraphics
import Foundation

/// The Day view's sizes, in points (Accepted 2026-11-09, Timeline, drawn at
/// 2× in `Preview - settings at bottom.dc.html`): each is the drawing's px ÷ 2.
enum CalendarDayDesign {
    /// `DAY_H` 88 px an hour, `DAY_TOP` 14 px above the first hour, 20 px
    /// after the last.
    static let hourHeight: CGFloat = 44
    static let topInset: CGFloat = 7
    static let tail: CGFloat = 10

    // The hours' column: 20 px from the panel's side, the label 62 px wide
    // and 18 px, 12 px to its line; events start 82 px in.
    static let sideInset: CGFloat = 10
    static let labelWidth: CGFloat = 31
    static let labelGap: CGFloat = 6
    static let labelFont: CGFloat = 9
    static let labelHeight: CGFloat = 11
    static let gutter: CGFloat = 41
    static let lineFill: Double = 0.07
    static let line: CGFloat = 0.5

    // A block: never under 44 px; 1 px clear of its hour above and below;
    // 4 px between side-by-side blocks; radius 20 px on curve 1.4.
    static let minBlock: CGFloat = 22
    static let blockInset: CGFloat = 0.5
    static let laneGap: CGFloat = 2
    static let blockRadius: CGFloat = 10
    /// Padding 12 px across; 9 px down, or 6 px on a block under 60 px.
    static let blockPaddingX: CGFloat = 6
    static let blockPaddingY: CGFloat = 4.5
    static let blockPaddingYCompact: CGFloat = 3
    static let compactBelow: CGFloat = 30
    /// The time and place show from 76 px, or when open.
    static let metaFrom: CGFloat = 38
    // Dot 12 px, 10 px to the title; title 22 px (500) on 28 px; second
    // line 19 px on 26 px, starting 22 px in.
    static let blockDot: CGFloat = 6
    static let blockTextX: CGFloat = blockPaddingX + blockDot + 5
    static let blockTitleFont: CGFloat = 11
    static let blockTitleLine: CGFloat = 14
    static let blockMetaFont: CGFloat = 9.5
    static let blockMetaLine: CGFloat = 13
    /// The calendar's colour at 15 %, past events at 7 %.
    static let blockFill: Double = 0.15
    static let blockFillOver: Double = 0.07

    // The now line: time 18 px (600), dot 10 px 7 px after the label's
    // column, line 2 px. The hour within 15 minutes gives up its label.
    static let nowLabelFont: CGFloat = 9
    static let nowDot: CGFloat = 5
    static let nowDotLead: CGFloat = 3.5
    static let nowLine: CGFloat = 1
    static let nowHidesHourWithin: TimeInterval = 15 * 60

    // Tasks and all-day events: 4 px above and 6 px below; rows at least
    // 46 px; the all-day label 19 px.
    static let topPaddingTop: CGFloat = 2
    static let topPaddingBottom: CGFloat = 3
    static let topRowMinHeight: CGFloat = 23
    static let allDayDot: CGFloat = 7
    static let allDayLabelFont: CGFloat = 9.5
    /// Room the title leaves for "All day" on its right.
    static let allDayLabelReserve: CGFloat = 44
    /// Not in the drawing: a day with many tasks still leaves room for its
    /// hours; beyond this share of the page its list scrolls by itself.
    static let topMaxShare: CGFloat = 0.4

    /// 14 px over which the hours come out from under the week.
    static let scrollFade: CGFloat = 7

    /// A short event takes this long on the page, however brief it is.
    static var minBlockDuration: TimeInterval { TimeInterval(minBlock / hourHeight) * 3600 }

    /// Hours either side of what shows that stay built while it scrolls.
    static let overscanHours = 2
}

/// One day by the clock, as values: where each hour and event sits, which
/// events share a row, and how far later hours have moved to make room for
/// an open event. Positions follow elapsed time from the day's start, so a
/// 23- or 25-hour day is that long on the page and the two 01:30s of an
/// autumn change are an hour apart.
struct CalendarDayLayout: Equatable {
    struct Hour: Identifiable, Equatable {
        let index: Int
        let date: Date
        let y: CGFloat
        var isLabelHidden = false
        var id: Int { index }
    }

    struct Block: Identifiable, Equatable {
        let event: CalendarEvent
        let y: CGFloat
        let height: CGFloat
        let lane: Int
        let laneCount: Int
        let isOver: Bool
        let isOpen: Bool
        let showsMeta: Bool
        let paddingY: CGFloat
        var id: String { event.id }
    }

    private(set) var hours: [Hour] = []
    private(set) var blocks: [Block] = []
    private(set) var height: CGFloat = 0
    private(set) var nowY: CGFloat?
    /// How far an open event has pushed the hours after it.
    private(set) var room: CGFloat = 0

    /// `openContentHeight` is the open event's measured content; 0 until
    /// it is known. Only `openEventID` among `events` makes room.
    init(day: DueDay, today: DueDay, now: Date, events: [CalendarEvent], calendar: Calendar,
         openEventID: String? = nil, openContentHeight: CGFloat = 0) {
        guard let interval = CalendarMonthMath.interval(of: day, calendar: calendar) else { return }
        let design = CalendarDayDesign.self
        func elapsed(_ date: Date) -> TimeInterval { min(max(date.timeIntervalSince(interval.start), 0), interval.duration) }
        func points(_ seconds: TimeInterval) -> CGFloat { CGFloat(seconds / 3600) * design.hourHeight }
        func natural(_ start: TimeInterval, _ end: TimeInterval) -> CGFloat { max(design.minBlock, points(end - start)) }

        struct Spot {
            let event: CalendarEvent, start: TimeInterval, end: TimeInterval
            var lane = 0, laneCount = 1
        }
        var spots: [Spot] = events.filter { !$0.isAllDay }.map {
            Spot(event: $0, start: elapsed($0.start), end: elapsed($0.end))
        }.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)

        // Events that take the same space share it side by side. What counts
        // is the space on the page, so a brief event's minimum height never
        // covers the one after it.
        var lanes: [TimeInterval] = []
        var cluster: [Int] = []
        var clusterEnd = -TimeInterval.infinity
        func closeCluster() {
            for index in cluster { spots[index].laneCount = lanes.count }
            cluster.removeAll()
            lanes.removeAll()
        }
        for index in spots.indices {
            let spot = spots[index]
            if spot.start >= clusterEnd {
                closeCluster()
                clusterEnd = -.infinity
            }
            let visualEnd = spot.start + max(spot.end - spot.start, design.minBlockDuration)
            let lane = lanes.firstIndex { $0 <= spot.start } ?? lanes.count
            if lane == lanes.count { lanes.append(0) }
            lanes[lane] = visualEnd
            clusterEnd = max(clusterEnd, visualEnd)
            spots[index].lane = lane
            cluster.append(index)
        }
        closeCluster()

        // An open event makes room: the hours after it move down, it never
        // covers the next one.
        let open = openEventID.flatMap { id in spots.first { $0.event.id == id } }
        let room = open.map { max(0, openContentHeight + 2 * design.blockInset - natural($0.start, $0.end)) } ?? 0
        let openEnd = open?.end
        self.room = room
        func y(_ seconds: TimeInterval) -> CGFloat {
            design.topInset + points(seconds) + (openEnd.map { seconds >= $0 } == true ? room : 0)
        }

        let isToday = day == today
        let hourCount = Int(interval.duration / 3600)
        hours = (0...max(hourCount, 0)).map { index in
            let seconds = TimeInterval(index) * 3600
            let date = interval.start.addingTimeInterval(seconds)
            return Hour(index: index, date: date, y: y(seconds),
                        isLabelHidden: isToday && abs(date.timeIntervalSince(now)) < design.nowHidesHourWithin)
        }
        height = y(interval.duration) + design.tail
        if isToday, interval.contains(now) { nowY = y(elapsed(now)) }

        blocks = spots.map { spot in
            let isOpen = spot.event.id == openEventID
            // Anything running past the open event's end still ends on its
            // own hour, which has moved.
            let reachesRoom = openEnd.map { spot.start < $0 && spot.end >= $0 } == true
            let full = natural(spot.start, spot.end) + (isOpen || reachesRoom ? room : 0)
            let isOver = isToday ? spot.event.end <= now : day < today
            return Block(event: spot.event, y: y(spot.start) + design.blockInset, height: full - 2 * design.blockInset,
                         lane: spot.lane, laneCount: spot.laneCount, isOver: isOver, isOpen: isOpen,
                         showsMeta: full >= design.metaFrom || isOpen,
                         paddingY: full < design.compactBelow ? design.blockPaddingYCompact : design.blockPaddingY)
        }
    }

    /// The block's place in a timeline `width` wide.
    func frame(of block: Block, width: CGFloat) -> CGRect {
        let design = CalendarDayDesign.self
        let column = max(0, width - design.gutter)
        let count = CGFloat(max(block.laneCount, 1))
        return CGRect(x: design.gutter + column * CGFloat(block.lane) / count, y: block.y,
                      width: max(0, column / count - (block.laneCount > 1 ? design.laneGap : 0)), height: block.height)
    }

    /// The scroll position a day opens at: an hour before now on today,
    /// otherwise half an hour before its first timed event, otherwise 08:00.
    static func openingOffset(day: DueDay, today: DueDay, now: Date, events: [CalendarEvent], calendar: Calendar) -> CGFloat {
        guard let interval = CalendarMonthMath.interval(of: day, calendar: calendar) else { return 0 }
        let seconds: TimeInterval
        if day == today {
            seconds = now.timeIntervalSince(interval.start) - 3600
        } else if let first = events.filter({ !$0.isAllDay }).map(\.start).min() {
            seconds = max(first.timeIntervalSince(interval.start), 0) - 1800
        } else {
            let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: interval.start,
                                        matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            seconds = (morning ?? interval.start).timeIntervalSince(interval.start)
        }
        return max(0, CGFloat(seconds / 3600) * CalendarDayDesign.hourHeight)
    }

    /// The opening position kept inside what can scroll.
    static func clampedOffset(_ offset: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> CGFloat {
        min(offset, max(0, contentHeight - viewport))
    }

    /// Which part of the timeline stays built for an hour-sized scroll
    /// bucket: what shows, plus the overscan, widened by the room.
    func builtRange(bucket: Int, viewport: CGFloat) -> ClosedRange<CGFloat> {
        let hour = CalendarDayDesign.hourHeight
        let low = CGFloat(bucket - CalendarDayDesign.overscanHours) * hour - room
        let high = CGFloat(bucket + CalendarDayDesign.overscanHours + 1) * hour + viewport + room
        return low...max(low, high)
    }
}
