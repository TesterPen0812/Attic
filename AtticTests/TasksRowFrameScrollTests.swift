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

    // MARK: - Rig

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
