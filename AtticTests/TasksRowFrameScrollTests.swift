import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// S2, the lead's scroll fix (`ops/design/task-row-cost.md`, "the scroll
/// trace, and two scroll fixes", 18 Nov 2026): a row's frame is kept in its
/// list's own coordinates, and one shared offset (the list's place in the
/// page, with the pager's) is applied when a hit test asks, as the pager's
/// sideways move already is. A steady scroll then reports no row's frame;
/// a row reports only when its size, its order or its expansion changes.
///
/// The page is the real `TasksPage` with the long demo (`Hosted`), off
/// screen. A scroll step moves the list's clip view, as a live scroll does,
/// then lays out and draws.
@MainActor
final class TasksRowFrameScrollTests: XCTestCase {
    override func tearDown() async throws {
        TasksPointer.recordsSlotFrames = false
        try await super.tearDown()
    }

    // MARK: - Guard

    /// Red first: 10 steps of 6.5 and 5.25 pt (a trackpad's steps are not
    /// whole points) on Now, then on Done. No report moves a frame the
    /// pointer already holds (rows, day headers, Completed today). A row
    /// whose quick look opens still reports, and so do the rows below it.
    func testGuardASteadyScrollMovesNoRowFrame() throws {
        let hosted = try Hosted(height: 520, long: true, keyWindow: false)
        defer { hosted.close() }
        for tab in [TasksTab.now, .done] {
            if tab != .now { hosted.go(to: tab) }
            let scroll = try list(hosted)
            let held = hosted.pointer.frames.filter { $0.key.tab == tab }.count
            let moves = hosted.pointer.frameMoveReports, reports = hosted.pointer.frameReports
            let top = scroll.contentView.bounds.minY
            for index in 0..<10 { step(hosted, scroll, by: index.isMultiple(of: 2) ? 6.5 : 5.25) }
            let scrolled = scroll.contentView.bounds.minY - top
            let moved = hosted.pointer.frameMoveReports - moves
            print("GUARD_S2_SCROLL tab=\(tab) steps=10 step_pt=6.5/5.25 scrolled_pt=\(scrolled) frames_held=\(held) " +
                  "frame_move_reports=\(moved) frame_reports=\(hosted.pointer.frameReports - reports)")
            XCTAssertGreaterThan(scrolled, 50, "the \(tab) list scrolled")
            XCTAssertGreaterThan(held, 4, "the \(tab) list holds rows")
            XCTAssertEqual(moved, 0, "a steady scroll moves no frame the pointer holds (\(tab))")
        }

        // A row's quick look opens: it reports, and the rows below it move.
        hosted.go(to: .now)
        let rows = hosted.pointer.frames.filter { $0.key.tab == .now && $0.value.minY > 140 }.sorted { $0.value.minY < $1.value.minY }
        let row = try XCTUnwrap(rows.first, "a Now row below the top")
        let moves = hosted.pointer.frameMoveReports
        hosted.model.toggleExpanded(row.key.id)
        hosted.spin(0.8)
        let moved = hosted.pointer.frameMoveReports - moves
        print("GUARD_S2_EXPAND frame_move_reports=\(moved) rows_below=\(rows.count - 1)")
        XCTAssertGreaterThan(moved, 0, "a row that grows reports its new frame")
        XCTAssertGreaterThan(try XCTUnwrap(hosted.pointer.frame(for: row.key)).height, row.value.height, "and the pointer holds its new size")
    }

    // MARK: - The same frames as the old way

    /// At several offsets, down and back up (rows leave the lazy list and
    /// come back in reused cells), on Now and on Done: every row the pointer
    /// holds is where the old way measures it (in its pager slot, on every
    /// move), and a point anywhere on the list finds the row the old way
    /// finds there, or none. No row that left answers a hit test.
    func testFramesMatchTheOldWayAtSeveralOffsetsAndRowsThatLeaveAnswerNoHitTest() throws {
        let hosted = try slotRecording()
        defer { hosted.close() }
        for tab in [TasksTab.now, .done] {
            if tab != .now { hosted.go(to: tab) }
            let scroll = try list(hosted)
            var checked = 0
            for target in [0, 40, 130, 420, 900, 130, 0] as [CGFloat] {
                scrollTo(hosted, scroll, y: target)
                checked += try assertMatchesTheOldWay(hosted, tab: tab, at: "\(tab) y=\(target)")
            }
            XCTAssertGreaterThan(checked, 30, "rows compared on \(tab)")
        }
    }

    /// A row's quick look opens in a scrolled list: the row grows, the
    /// rows below it move, and every frame is still where the old way puts
    /// it. It closes again, the same.
    func testQuickLookInAScrolledListKeepsEveryFrameWhereTheOldWayPutsIt() throws {
        let hosted = try slotRecording()
        defer { hosted.close() }
        let scroll = try list(hosted)
        scrollTo(hosted, scroll, y: 130)
        let row = try XCTUnwrap(visibleRows(hosted, tab: .now).first, "a Now row in view")
        let closed = try XCTUnwrap(hosted.pointer.frame(for: row))
        hosted.model.toggleExpanded(row.id)
        hosted.spin(0.8)
        let open = try XCTUnwrap(hosted.pointer.frame(for: row))
        XCTAssertGreaterThan(open.height, closed.height, "the quick look opened in the row's frame")
        _ = try assertMatchesTheOldWay(hosted, tab: .now, at: "quick look open")
        hosted.model.toggleExpanded(row.id)
        hosted.spin(0.8)
        XCTAssertEqual(try XCTUnwrap(hosted.pointer.frame(for: row)).height, closed.height, accuracy: 0.5)
        _ = try assertMatchesTheOldWay(hosted, tab: .now, at: "quick look closed")
    }

    /// Mid-travel, the pager's offset and the list's origin add up: with
    /// Now scrolled and a sideways swipe held part way, every frame is
    /// where the old way puts it, and a file over a row finds that row.
    func testMidPagerTravelWithTheListScrolledCombinesBothOffsets() throws {
        let hosted = try slotRecording()
        defer { hosted.close() }
        let model = hosted.model
        let scroll = try list(hosted)
        let resting = try XCTUnwrap(hosted.pointer.contentOrigin(for: .now), "the list reported its origin")
        let top = scroll.contentView.bounds.minY
        scrollTo(hosted, scroll, y: 130)
        let scrolled = scroll.contentView.bounds.minY - top
        XCTAssertGreaterThan(scrolled, 100, "Now scrolled")
        let origin = try XCTUnwrap(hosted.pointer.contentOrigin(for: .now))
        XCTAssertEqual(origin.y, resting.y - scrolled, accuracy: 0.5, "the origin moved with the scroll")
        XCTAssertEqual(origin.x, resting.x, accuracy: 0.5)
        var time: TimeInterval = 0
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0, after: TimeInterval = 1.0 / 120) {
            time += after
            _ = model.pagerScrolled(.init(phase: phase, momentum: false, dx: dx, dy: 0, time: time), allowed: true)
        }
        send(.began)
        for _ in 0..<8 { send(.changed, dx: -8) }
        hosted.spin(0.1)
        let offset = hosted.pointer.pageOffset(.now)
        XCTAssertLessThan(offset, -20, "Now is part way out")
        XCTAssertGreaterThan(offset, -AtticLayout.panelSize.width + 20, "and still part on the page")
        _ = try assertMatchesTheOldWay(hosted, tab: .now, at: "mid-travel")
        // A file over a row in the moving, scrolled list lands on that row.
        let row = try XCTUnwrap(visibleRows(hosted, tab: .now).first)
        let frame = try XCTUnwrap(hosted.pointer.slotProbeFrame(for: row))
        XCTAssertEqual(hosted.pointer.fileDropRow(at: CGPoint(x: frame.midX, y: frame.midY), in: .now, eligible: [row.id]), row.id)
        // A slow lift: the pager settles where it chooses; the shown
        // page's frames are where the old way puts them.
        send(.ended, after: 0.4)
        hosted.spin(1.2)
        _ = try assertMatchesTheOldWay(hosted, tab: model.tab, at: "after the lift (\(model.tab))")
    }

    // MARK: - Rig

    /// The long demo, hosted with the old way's slot frames recorded.
    private func slotRecording() throws -> Hosted {
        TasksPointer.recordsSlotFrames = true
        return try Hosted(height: 520, long: true, keyWindow: false)
    }

    /// The rows of `tab` the pointer holds, inside the list's visible band.
    private func visibleRows(_ hosted: Hosted, tab: TasksTab) -> [TasksRowID] {
        hosted.pointer.frames.filter { $0.key.tab == tab && $0.value.minY > 120 && $0.value.maxY < hosted.height - 120 }
            .sorted { $0.value.minY < $1.value.minY }.map(\.key)
    }

    /// Every row the pointer holds on `tab` is where the old way measured
    /// it, and every 7 pt down the page a hit test finds what the old way
    /// finds. Returns how many rows it compared.
    private func assertMatchesTheOldWay(_ hosted: Hosted, tab: TasksTab, at label: String) throws -> Int {
        let pointer = hosted.pointer
        let held = pointer.frames.filter { $0.key.tab == tab }
        XCTAssertFalse(held.isEmpty, "rows held (\(label))")
        func same(_ frame: CGRect, _ old: CGRect?, _ what: String) throws {
            let old = try XCTUnwrap(old, "the old way measured \(what) (\(label))")
            XCTAssertEqual(frame.minX, old.minX, accuracy: 0.5, "x of \(what) (\(label))")
            XCTAssertEqual(frame.minY, old.minY, accuracy: 0.5, "y of \(what) (\(label))")
            XCTAssertEqual(frame.height, old.height, accuracy: 0.5, "height of \(what) (\(label))")
        }
        for (row, frame) in held { try same(frame, pointer.slotProbeFrame(for: row), "row \(row.id)") }
        if tab == .now {
            for (key, frame) in pointer.headerFrames {
                try same(frame, pointer.slotProbeFrame(.header(.now, key), on: .now), "header \(key)")
            }
        }
        if let line = pointer.completedTodayFrames[tab] {
            try same(line, pointer.slotProbeFrame(.completedToday(tab), on: tab), "Completed today")
        }
        let oldFrames: [(UUID, CGRect)] = pointer.slotFrames.keys.compactMap { key in
            guard case let .row(row) = key, row.tab == tab else { return nil }
            return pointer.slotProbeFrame(for: row).map { (row.id, $0) }
        }
        let x = (held.values.first?.midX ?? 100)
        for y in stride(from: CGFloat(0), through: hosted.height, by: 7) {
            let point = CGPoint(x: x, y: y)
            let expected = oldFrames.first { $0.1.height < 2_000 && $0.1.contains(point) }?.0
            XCTAssertEqual(pointer.row(at: point, in: tab), expected, "the row at y=\(y) (\(label))")
        }
        return held.count
    }

    /// The list scrolled to `y`, in steps of at most 40 pt, as a scroll does.
    private func scrollTo(_ hosted: Hosted, _ scroll: NSScrollView, y: CGFloat) {
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        let target = min(y, maxY)
        for _ in 0..<60 where abs(clip.bounds.minY - target) > 0.5 {
            let before = clip.bounds.minY
            step(hosted, scroll, by: max(-40, min(40, target - before)))
            if clip.bounds.minY == before { break }
        }
        hosted.spin(0.2)
    }

    /// The shown tab's list: the vertical list on the page.
    private func list(_ hosted: Hosted) throws -> NSScrollView {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        return try XCTUnwrap(hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        }, "the shown tab's list is on the page")
    }

    /// One scroll step, as a live scroll moves the list, then one frame.
    private func step(_ hosted: Hosted, _ scroll: NSScrollView, by points: CGFloat) {
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += points
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        hosted.spin(0.05)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        hosted.window.displayIfNeeded()
    }
}
