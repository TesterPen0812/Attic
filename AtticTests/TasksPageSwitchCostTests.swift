import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 10 (the orchestrator, after Astra's round 9 check): since round 9
/// a page that is not on screen is not built, so a switch builds its page
/// cold. This measures that, headless, on the spec's seeded sizes (500
/// open tasks, 500 in Later, 5,000 in the Done log): a tab chosen, the page
/// placed at once, then the layout and draw pass that shows it. It prints
/// what it measures (`ATTIC_PAGE_SWITCH`) and sets no budget of its own:
/// the spec's perception budget (a page switch within 50 ms) is judged on
/// the owner's Mac with the Phase 0 signposts, not on a test host.
@MainActor
final class TasksPageSwitchCostTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    func testMeasuresTheColdBuildOfEachPage() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let now = Date()
        var order: Int64 = 10_000_000
        func insert(_ title: String, _ status: TaskStatus, logged: Bool = false, completed: Date? = nil) {
            order -= 1_024
            let item = TaskItem(title: title, status: status, priority: .none, createdAt: now, completedAt: completed,
                                manualOrder: order, parentID: nil)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if logged { item.doneLoggedAt = now }
            context.insert(item)
        }
        for index in 0..<500 { insert("Open task \(index)", .todo) }
        for index in 0..<500 { insert("Later task \(index)", .backlog) }
        for index in 0..<5_000 {
            insert("Finished task \(index)", .done, logged: true, completed: now.addingTimeInterval(-Double(index + 1) * 3_600))
        }
        try context.save()
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        // Cold builds are what this measures: no page kept built (round 11).
        model.pagerSwipe.motion.warms = false
        let size = CGSize(width: 344, height: 520)
        let hosting = NSHostingView(rootView: TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                                                        addBarFocused: .constant(false))
            .frame(width: size.width, height: size.height)
            .atticDesign(.default))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        func switchTo(_ tab: TasksTab) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            model.select(tab: tab)
            model.showPagerPage(animated: false)
            RunLoop.current.run(until: Date())
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            // Let the page settle and the one it left be released.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return elapsed
        }
        var samples: [TasksTab: [Double]] = [:]
        for _ in 0..<3 {
            for tab in [TasksTab.backlog, .done, .now] { samples[tab, default: []].append(switchTo(tab)) }
        }
        let report = [TasksTab.now, .backlog, .done].map { tab -> String in
            let values = (samples[tab] ?? []).sorted()
            return "\(tab.identifier)=\(String(format: "%.1f", values[values.count / 2]))ms"
        }.joined(separator: " ")
        print("ATTIC_PAGE_SWITCH cold build, median of 3: \(report)")
        XCTAssertEqual(model.pagerSwipe.span.pages, 0...0, "only the page shown stays built")
        XCTAssertTrue(samples.values.allSatisfy { $0.allSatisfy { $0 > 0 } })
    }
}
