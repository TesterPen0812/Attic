import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

/// Round 11 (performance): what building a screenful of task rows costs,
/// cold, headless: the design system's row alone and with what the Tasks
/// page adds to each row. Prints `ATTIC_ROW_BUILD` (16 rows, median of
/// five cold builds, minus an empty window's); no budget of its own.
@MainActor
final class TasksRowBuildCostTests: XCTestCase {
    private static func models() -> [AtticTaskRowModel] {
        (0..<16).map { index in
            AtticTaskRowModel(title: "Open task number \(index) with a title",
                              state: index % 5 == 0 ? .inProgress : .todo,
                              priority: index % 4 == 0 ? .medium : .none,
                              due: index % 3 == 0 ? .init(text: "Tomorrow") : nil,
                              tags: index % 4 == 0 ? ["home", "work"] : [])
        }
    }

    private static func actions() -> AtticTaskActions {
        AtticTaskActions(toggleDone: {}, toggleWorking: {}, openPage: {}, moveToBacklog: {}, delete: {}, editTitle: {})
    }

    private func coldBuild<Content: View>(_ content: @escaping () -> Content) -> Double {
        var samples: [Double] = []
        for _ in 0..<5 {
            let size = CGSize(width: 360, height: 600)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let start = DispatchTime.now().uptimeNanoseconds
            let hosting = NSHostingView(rootView: content().frame(width: size.width, height: size.height, alignment: .top)
                .atticDesign(EdgesUnderTest.context(AtticDesignContext(mode: .light))))
            window.contentView = hosting
            RunLoop.current.run(until: Date())
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return TasksFrameCostTests.median(samples)
    }

    func testMeasuresTheColdBuildOfAScreenOfRows() {
        let feel = MotionFeelUnderTest.apply()
        defer { MotionFeelUnderTest.restore() }
        let models = Self.models()
        let actions = Self.actions()
        let empty = coldBuild { Color.clear }
        let plain = coldBuild {
            VStack(spacing: 0) { ForEach(models) { AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {}) } }
        }
        let menu = coldBuild {
            VStack(spacing: 0) {
                ForEach(models) {
                    AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {})
                        .contextMenu { AtticMenuItems { [] } }
                }
            }
        }
        let geometry = coldBuild {
            VStack(spacing: 0) {
                ForEach(models) {
                    AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {})
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in }
                }
            }
        }
        let drop = coldBuild {
            VStack(spacing: 0) {
                ForEach(models) {
                    AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {})
                        .onDrop(of: TaskDropContent.dropTypes, isTargeted: nil) { _ in false }
                }
            }
        }
        let gesture = coldBuild {
            VStack(spacing: 0) {
                ForEach(models) {
                    AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {})
                        .simultaneousGesture(DragGesture(minimumDistance: 4))
                }
            }
        }
        // The Motion Lab's "Blur and fade" puts the edge blur on each cell.
        let bands = TasksViewport.edgeBands(tabsTop: 80, listTop: 110, bottomStack: 48)
        let edgeBlur = coldBuild {
            VStack(spacing: 0) {
                ForEach(models) {
                    AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {})
                        .atticEdgeBlur(true, in: .named("edge-blur-cost"), top: bands.top, bottom: bands.bottom)
                }
            }
            .coordinateSpace(.named("edge-blur-cost"))
        }
        let lazy = coldBuild {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(models) { AtticTaskRow(model: $0, actions: actions, onToggleExpanded: {}, onSelect: {}) } }
            }
        }
        let report = String(format: "empty=%.1fms rows=+%.1fms +menu=+%.1fms +geometry=+%.1fms +drop=+%.1fms +gesture=+%.1fms +edge-blur=+%.1fms lazy-scroll=+%.1fms",
                            empty, plain - empty, menu - plain, geometry - plain, drop - plain, gesture - plain, edgeBlur - plain, lazy - empty)
        print("ATTIC_ROW_BUILD 16 rows (feel=\(feel), edges=\(EdgesUnderTest.style.rawValue)): " + report)
        XCTAssertGreaterThan(plain, 0)
    }
}
