import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The list hover tracker (25 Nov 2026): the Tasks list finds the row under
/// the pointer from the frames it already measures and tells only that row
/// (`TasksPointer.updateHover`, `AtticRowHover`), in place of a SwiftUI
/// hover region in every row. What hover feeds stays as it was: the row's
/// tint and its hover-shown controls come and go with the pointer, a still
/// pointer over a moving list lands on the row under it, leaving the list
/// or hiding the panel clears it, and the tint hold keeps the hovered row
/// through a live scroll and lands the row under the pointer at its end.
@MainActor
final class TasksListHoverTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        try await super.tearDown()
    }

    @MainActor private struct List {
        let pointer = TasksPointer()
        let gate = AtticRowHoverGate()
        let cells = (a: TasksCellReports(), b: TasksCellReports(), c: TasksCellReports())
        let rows = (a: TasksRowID(tab: .now, id: UUID()), b: TasksRowID(tab: .now, id: UUID()),
                    c: TasksRowID(tab: .now, id: UUID()))
    }

    /// Three 30 pt rows from y 50 on Now; the pointer at `point`.
    private func list(point: @escaping () -> CGPoint?, shown: @escaping () -> Bool = { true }) -> List {
        let list = List()
        list.pointer.pointerLocation = point
        list.pointer.hoverScope = { [gate = list.gate] in shown() ? (.now, gate) : nil }
        list.pointer.setFrame(CGRect(x: 0, y: 50, width: 300, height: 30), for: list.rows.a, from: list.cells.a)
        list.pointer.setFrame(CGRect(x: 0, y: 80, width: 300, height: 30), for: list.rows.b, from: list.cells.b)
        list.pointer.setFrame(CGRect(x: 0, y: 110, width: 300, height: 30), for: list.rows.c, from: list.cells.c)
        return list
    }

    private func hovered(_ list: List) -> [Bool] {
        [list.cells.a.hover.isPointerInside, list.cells.b.hover.isPointerInside, list.cells.c.hover.isPointerInside]
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The tracker

    func testOnlyTheRowUnderThePointerIsToldAndLeavingTheListClearsIt() {
        var point: CGPoint? = CGPoint(x: 40, y: 60)
        let list = list(point: { point })
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false], "the row under the pointer")
        XCTAssertEqual(list.pointer.hovered, AnyHashable(list.rows.a))

        point = CGPoint(x: 40, y: 95)
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual(hovered(list), [false, true, false], "the pointer moved on: the row it left lets go")

        point = CGPoint(x: 40, y: 200)
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual(hovered(list), [false, false, false], "under the rows: nothing")

        point = CGPoint(x: 40, y: 120)
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual(hovered(list), [false, false, true])
        point = nil
        list.pointer.pointerMoved(inside: false)
        XCTAssertEqual(hovered(list), [false, false, false], "the pointer left the list")
        XCTAssertNil(list.pointer.hovered)
    }

    func testOnlyTheRowsVisiblePartAnswers() {
        let list = list(point: { CGPoint(x: 40, y: 60) })
        list.pointer.hoverBand = { (top: 70, bottom: 0) }
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [false, false, false], "under the tabs' band, as a press is")
        list.pointer.hoverBand = { (top: 0, bottom: 0) }
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false])
    }

    func testAStillPointerLandsOnTheRowTheListMovesUnderIt() {
        let list = list(point: { CGPoint(x: 40, y: 60) })
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false])
        // The list scrolls by a row (a wheel or a reveal, no live scroll):
        // its rows report their new frames one by one.
        list.pointer.setFrame(CGRect(x: 0, y: 20, width: 300, height: 30), for: list.rows.a, from: list.cells.a)
        list.pointer.setFrame(CGRect(x: 0, y: 50, width: 300, height: 30), for: list.rows.b, from: list.cells.b)
        list.pointer.setFrame(CGRect(x: 0, y: 80, width: 300, height: 30), for: list.rows.c, from: list.cells.c)
        spin()
        XCTAssertEqual(hovered(list), [false, true, false], "the row now under the still pointer")
    }

    /// The tint hold (owner, 17 Nov): while the list scrolls live, the row
    /// hovered when it began keeps its hover and no other row takes it;
    /// when the scroll ends, the row under the pointer is hovered at once.
    func testTheTintHoldKeepsTheHoveredRowUntilTheScrollEnds() {
        let list = list(point: { CGPoint(x: 40, y: 60) })
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false])

        list.gate.hold()
        list.pointer.setFrame(CGRect(x: 0, y: 20, width: 300, height: 30), for: list.rows.a, from: list.cells.a)
        list.pointer.setFrame(CGRect(x: 0, y: 50, width: 300, height: 30), for: list.rows.b, from: list.cells.b)
        list.pointer.setFrame(CGRect(x: 0, y: 80, width: 300, height: 30), for: list.rows.c, from: list.cells.c)
        spin()
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual(hovered(list), [true, false, false], "held: the hovered row keeps it while the list scrolls")

        list.gate.release()
        XCTAssertEqual(hovered(list), [false, true, false], "released: the row under the pointer, at once")
    }

    func testNothingIsHoveredWhileThePanelIsHiddenOrTasksIsNotShown() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        let list = list(point: { CGPoint(x: 40, y: 60) })
        model.rowPointer = list.pointer
        list.pointer.hoverScope = TasksPointer.hoverScope(model: model) { [gate = list.gate] _ in gate }
        model.select(tab: .now)
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false])

        model.pageDidHide()
        XCTAssertEqual(hovered(list), [false, false, false], "hidden: cleared at once")
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual(hovered(list), [false, false, false], "hidden: a move hovers nothing")

        model.pageDidReturn()
        spin()
        XCTAssertEqual(hovered(list), [true, false, false], "back: the row under the pointer")

        model.isPageShown = false
        XCTAssertEqual(hovered(list), [false, false, false], "Notes or Canvas shown: cleared")
    }

    func testARowThatGoesTakesItsHoverWithItAndAnotherTabsRowsNeverAnswer() {
        let list = list(point: { CGPoint(x: 40, y: 60) })
        let doneCell = TasksCellReports()
        list.pointer.setFrame(CGRect(x: 0, y: 50, width: 300, height: 30),
                              for: TasksRowID(tab: .done, id: UUID()), from: doneCell)
        list.pointer.updateHover()
        XCTAssertEqual(hovered(list), [true, false, false])
        XCTAssertFalse(doneCell.hover.isPointerInside, "Done's row at the same place is not on the tab shown")

        list.pointer.removeFrame(for: list.rows.a, of: list.cells.a)
        XCTAssertFalse(list.cells.a.hover.isPointerInside, "the cell went: not hovered")
        XCTAssertNil(list.pointer.hovered)
    }

    /// A day's heading, the next event and Completed today hover as rows do.
    func testALineBetweenTheRowsIsToldAsARowIs() {
        var point = CGPoint(x: 40, y: 30)
        let list = list(point: { point })
        let heading = AtticRowHover()
        list.pointer.setLineHover(heading, frame: CGRect(x: 0, y: 20, width: 300, height: 30), for: "group:today", tab: .now)
        // Backlog, kept built beside Now, has its own copy of the heading.
        let backlogHeading = AtticRowHover()
        list.pointer.setLineHover(backlogHeading, frame: CGRect(x: 0, y: 20, width: 300, height: 30), for: "group:today", tab: .backlog)
        list.pointer.updateHover()
        XCTAssertTrue(heading.isPointerInside)
        XCTAssertFalse(backlogHeading.isPointerInside, "another tab's copy never answers")
        point = CGPoint(x: 40, y: 60)
        list.pointer.pointerMoved(inside: true)
        XCTAssertFalse(heading.isPointerInside)
        XCTAssertEqual(hovered(list), [true, false, false])
    }

    /// A hovered row's parts (its date, its circle, its ›) are each told
    /// whether the pointer is over them, once their frames arrive.
    func testTheHoveredRowsPartsAreToldWhenTheirFramesArrive() {
        var point = CGPoint(x: 250, y: 60)
        let list = list(point: { point })
        list.pointer.updateHover()
        let date = AtticRowHoverPart(), title = AtticRowHoverPart()
        date.frame = CGRect(x: 230, y: 55, width: 50, height: 20)
        title.frame = CGRect(x: 30, y: 55, width: 150, height: 20)
        list.cells.a.hover.add(date)
        list.cells.a.hover.add(title)
        spin()
        XCTAssertEqual([date.isHovered, title.isHovered], [true, false], "the part under the pointer")
        point = CGPoint(x: 60, y: 60)
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual([date.isHovered, title.isHovered], [false, true])
        point = CGPoint(x: 60, y: 95)
        list.pointer.pointerMoved(inside: true)
        XCTAssertEqual([date.isHovered, title.isHovered], [false, false], "another row: none of this row's parts")
    }

    // MARK: The page's view

    func testThePagesViewTracksThePointerWithoutTakingClicks() {
        let pointer = TasksPointer()
        var moves: [Bool] = []
        pointer.pointerLocation = { nil }
        pointer.hoverScope = { moves.append(true); return nil }
        let view = TasksPointerProbeView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.pointer = pointer
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 300, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView?.addSubview(view)
        let areas = view.trackingAreas.filter { $0.owner === view }
        XCTAssertEqual(areas.count, 1, "one tracking area")
        let options = areas.first?.options ?? []
        for option: NSTrackingArea.Options in [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect] {
            XCTAssertTrue(options.contains(option), "tracking option \(option.rawValue)")
        }
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.filter { $0.owner === view }.count, 1, "never a second one")
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)), "click-through")
        let before = moves.count
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 0, pressure: 0)!
        view.mouseMoved(with: event)
        XCTAssertGreaterThan(moves.count, before, "a move asks the list")
        XCTAssertTrue(pointer.pointerInView)
        view.mouseExited(with: event)
        XCTAssertFalse(pointer.pointerInView)
    }

    // MARK: The row: what hover feeds

    private static let space = "tasks-list-hover-test"

    private func host<V: View>(_ view: V, size: CGSize) -> NSHostingView<AnyView> {
        let context = AtticDesignContext(reduceMotion: true)
        let root = AnyView(
            view
                .frame(width: size.width, height: size.height)
                .background(context.tokens.panel.base.color)
                .coordinateSpace(.named(Self.space))
                .atticDesign(context)
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame.offsetBy(dx: -6000, dy: -6000), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        spin(0.2)
        return hosting
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixels that differ between two renders, in a band of x (points).
    private func changed(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: ClosedRange<CGFloat>) -> Int {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        var count = 0
        for py in 0..<a.pixelsHigh {
            for px in Int(x.lowerBound * scale)..<min(a.pixelsWide, Int(x.upperBound * scale)) {
                guard let ca = a.colorAt(x: px, y: py), let cb = b.colorAt(x: px, y: py) else { continue }
                if abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent) > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// The row the list tells: hovered, it takes its tint and shows its ›;
    /// told the pointer left, it is as it was. It holds no SwiftUI hover
    /// region of its own while the pointer is not in it.
    func testATrackedRowTakesItsTintAndItsControlsAndLetsThemGo() throws {
        let hover = AtticRowHover()
        hover.space = .named(Self.space)
        let point = CGPoint(x: 120, y: 22)
        var inside = false
        hover.onPartMoved = { [weak hover] in hover?.pointer(at: inside ? point : nil) }
        let size = CGSize(width: 340, height: 44)
        let row = AtticTaskRow(model: .init(title: "Email beta testers", due: .init(text: "Friday")),
                               actions: AtticTaskActions(toggleDone: {}, toggleWorking: {}, openPage: {}, moveToBacklog: {}, delete: {}),
                               onToggleExpanded: {}, onOpenPage: {})
            .environment(\.atticRowHover, hover)
        let hosting = host(row, size: size)
        let rest = try bitmap(hosting)
        XCTAssertEqual(hover.partCount, 0, "not hovered: no part measures")

        inside = true
        hover.pointer(at: point)
        spin(0.3)
        let hovered = try bitmap(hosting)
        XCTAssertGreaterThan(hover.partCount, 0, "hovered: its parts measure")
        XCTAssertGreaterThan(changed(rest, hovered, x: 4...200), 200, "the row's tint")
        XCTAssertGreaterThan(changed(rest, hovered, x: 300...340), 20, "the › shows")

        inside = false
        hover.pointer(at: nil)
        spin(0.3)
        let after = try bitmap(hosting)
        XCTAssertEqual(changed(rest, after, x: 0...340), 0, "left: as it was")
        XCTAssertEqual(hover.partCount, 0)
    }
}
