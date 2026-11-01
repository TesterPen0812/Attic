import CoreGraphics
import Foundation
import SwiftUI

/// Accepted 2026-11-01 "Adaptive picks", "Drag a task into another day":
/// a row dragged on Now out of its own day and under another day's header
/// takes that day as its date (the orchestrator's calls: it keeps its time,
/// No date clears the date, Overdue takes no drops). Where it would land
/// while the drag is live; committed on release as one step.
struct TasksDayDrop: Equatable {
    /// What the drop does to the task's date.
    enum Change: Equatable {
        case day(DueDay)
        case clear
    }

    /// The day group's key (`TasksPanelDesign.Group.key`).
    let key: String
    let change: Change
    /// The drop's place among the day's drawn rows.
    let index: Int
    /// The day's row it lands just before, or (at the end of its state's
    /// rows) just after; both nil when its place in the day is decided by
    /// its clock or it is the only one of its state there.
    let before: UUID?
    let after: UUID?
    /// The drop line's centre, in the page.
    let lineY: CGFloat
}

/// Finds a cross-day drop from the pointer and the rows' and headers'
/// frames in the page. Pure, so the rules are tested directly.
enum TasksDayDropFinder {
    struct Row: Equatable {
        let id: UUID
        let status: TaskStatus
        /// Minutes since midnight, for a timed task.
        let time: Int?
        /// The row's frame in the page; nil while its cell is not built.
        let frame: CGRect?
    }

    struct Day: Equatable {
        let key: String
        let kind: TasksPanelDesign.GroupKind
        let header: CGRect?
        /// The day's drawn rows, the dragged one not among them.
        let rows: [Row]
    }

    /// What a drop into a group of `kind` does to the date; nil: the group
    /// takes no drop (Overdue, and anything that is not one of Now's days).
    static func change(for kind: TasksPanelDesign.GroupKind, today: DueDay) -> TasksDayDrop.Change? {
        switch kind {
        case .today: .day(today)
        case .day(let day): .day(day)
        case .noDate: .clear
        case .overdue, .finished, .backlog: nil
        }
    }

    /// Started tasks come first within a day, then the ones to do.
    private static func rank(_ status: TaskStatus) -> Int {
        switch status {
        case .inProgress: 0
        case .todo: 1
        default: 2
        }
    }

    /// The day under `y` (the last header or row starting above it), when
    /// it is not the dragged row's own day and takes drops: where the row
    /// would land there. The status edge holds (started tasks stay
    /// together), an untimed task lands after the day's timed ones, and a
    /// timed one lands in clock order.
    static func target(at y: CGFloat, dragged: Row, ownKey: String?, days: [Day], today: DueDay) -> TasksDayDrop? {
        // The day under the pointer: the nearest header or row above it.
        var under: Int?
        var nearest = -CGFloat.infinity
        for (index, day) in days.enumerated() {
            let tops = [day.header?.minY].compactMap { $0 } + day.rows.compactMap { $0.frame?.minY }
            for top in tops where top <= y && top >= nearest {
                nearest = top
                under = index
            }
        }
        guard let under else { return nil }
        let day = days[under]
        guard day.key != ownKey, let change = change(for: day.kind, today: today) else { return nil }
        let rows = day.rows
        let rank = rank(dragged.status)
        // The run of the dragged task's state in that day.
        var lower = (rows.lastIndex { Self.rank($0.status) < rank }).map { $0 + 1 } ?? 0
        var upper = rows.firstIndex { Self.rank($0.status) > rank } ?? rows.count
        if upper < lower { upper = lower }
        let timed = dragged.time != nil && change != .clear
        if !timed, let last = rows[lower..<upper].lastIndex(where: { $0.time != nil }) {
            lower = last + 1
        }
        var index: Int
        if let time = dragged.time, timed {
            index = rows[lower..<upper].firstIndex { ($0.time ?? 1440) > time } ?? upper
        } else {
            // Where it was dropped: before the first row whose middle is
            // below the pointer. Rows not built yet lie above the first
            // built one, or below the last.
            index = rows.count
            var seenFrame = false
            for (offset, row) in rows.enumerated() {
                guard let frame = row.frame else {
                    if seenFrame { index = offset; break }
                    continue
                }
                seenFrame = true
                if frame.midY > y { index = offset; break }
            }
        }
        index = min(max(index, lower), upper)
        var before: UUID?, after: UUID?
        if !timed {
            if index < rows.count, rows[index].status == dragged.status {
                before = rows[index].id
            } else if index > 0, rows[index - 1].status == dragged.status {
                after = rows[index - 1].id
            }
        }
        let lineY: CGFloat
        if index < rows.count, let frame = rows[index].frame {
            lineY = frame.minY
        } else if index > 0, let frame = rows[index - 1].frame {
            lineY = frame.maxY
        } else {
            lineY = day.header?.maxY ?? nearest
        }
        return TasksDayDrop(key: day.key, change: change, index: index, before: before, after: after, lineY: lineY)
    }
}

/// The live cross-day target, observed only by the day headers and the
/// drop line, so a new target redraws them and nothing else. Written only
/// when it changes, from the drag's gesture and its timer (never layout).
/// Used on the main thread only (it lives on the page's `TasksPointer`).
final class TasksDayDropState: ObservableObject {
    @Published private(set) var target: TasksDayDrop?
    /// How many times the target changed (tests bound it).
    private(set) var changes = 0

    /// The drop line's span across the row, in the page (set as the drag
    /// lifts: the lifted row's text column to its trailing padding).
    private(set) var lineX: ClosedRange<CGFloat> = 0...0

    func set(_ target: TasksDayDrop?) {
        guard target != self.target else { return }
        self.target = target
        changes += 1
    }

    func setLineX(_ span: ClosedRange<CGFloat>) {
        if lineX != span { lineX = span }
    }
}

/// A day header that knows when a dragged row would land in its day.
struct TasksDayDropHeader<Header: View>: View {
    @ObservedObject var drop: TasksDayDropState
    let key: String
    @ViewBuilder let header: (Bool) -> Header

    var body: some View {
        header(drop.target?.key == key)
    }
}

/// The drop line where a row dragged into another day would land: the
/// notes' drop line (2 pt in the accent, radius 1), across the row's text.
struct TasksDayDropLine: View {
    @ObservedObject var drop: TasksDayDropState
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let target = drop.target {
                let thickness = AtticNoteType.dropLineThickness
                RoundedRectangle(cornerRadius: thickness / 2)
                    .fill(design.tokens.color(.accent))
                    .frame(width: max(0, drop.lineX.upperBound - drop.lineX.lowerBound), height: thickness)
                    .offset(x: drop.lineX.lowerBound, y: target.lineY - thickness / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
