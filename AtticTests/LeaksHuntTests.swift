import AppKit
import Darwin
import QuartzCore
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// 12 Nov memory hunt. Only the invisible, in-memory Local host runs this
/// expensive, opt-in test. Every seed and measured checkpoint is logged.
#if DEBUG && !ATTIC_GENERATED_TESTS
@MainActor
final class LeaksHuntTests: XCTestCase {
    private let panelSeed: UInt64 = 0x12A0_2026_CAFE
    private let editorSeed: UInt64 = 0x12B0_2026_CAFE
    private let runnerSeed: UInt64 = 0x12C0_2026_CAFE

    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
            return Int((state >> 32) % UInt64(bound))
        }
    }

    private final class WeakObject {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    @MainActor
    private struct Snapshot {
        let views: Int
        let layers: Int
        let rss: Double
        let footprint: Double
        let monitors: Int
        let subscriptions: Int
        let drawObservers: Int

        var line: String {
            "views=\(views) layers=\(layers) rss_mib=\(String(format: "%.2f", rss)) " +
            "footprint_mib=\(String(format: "%.2f", footprint)) monitors=\(monitors) " +
            "subscriptions=\(subscriptions) draw_notification_tokens=\(drawObservers) " +
            "genie_links=\(PanelGenieView.activeDisplayLinksForTesting) " +
            "task_frame_sources=\(TasksDisplayClock.activeSourcesForTesting) " +
            "note_frame_sources=\(NotesDisplayFrameClock.activeSourcesForTesting)"
        }
    }

    @MainActor
    private final class Rig {
        let suite: String
        let defaults: UserDefaults
        let tasks: TaskStore
        let notes: NoteStore
        let draft: NoteDraftController
        let ui: PanelUIState
        let panel: AtticPanelController

        init(makeNotes: (ModelContainer) -> NoteStore) throws {
            suite = "LeaksHuntTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            tasks = TaskStore(container: container)
            notes = makeNotes(container)
            draft = NoteDraftController(noteStore: notes)
            ui = PanelUIState()
            panel = AtticPanelController(
                store: tasks, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: draft, settings: AppSettings(defaults: defaults), uiState: ui
            )
        }

        func dispose() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeRig() throws -> Rig {
        try Rig { container in
            trackAttachmentReconciliation(of: NoteStore(
                container: container, attachmentFileStore: makeTestAttachmentFileStore()
            ))
        }
    }

    private func requireInvisibleSoak() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_LEAKS_HUNT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_ATTIC_LEAKS_HUNT=1 to run the hosted leak hunt.")
        }
        guard TestPresentationPolicy.isInvisible else {
            throw XCTSkip("The leak hunt must run in the invisible unit-test host.")
        }
    }

    private enum HuntError: Error { case incompleteHide }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            // Back closes its lease in a MainActor task. Yield the current
            // XCTest task so the durable handoff can actually complete.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func hide(_ rig: Rig, step: Int) async throws {
        var outcome: PanelHideCompletion?
        let accepted = rig.panel.requestHide { outcome = $0 }
        XCTAssertTrue(accepted.isAccepted, "hide rejected at step \(step)")
        guard await eventually({ outcome != nil }) else {
            XCTFail("hide completion timed out at step \(step)")
            throw HuntError.incompleteHide
        }
        XCTAssertEqual(outcome, .hidden, "unexpected hide result at step \(step)")
        XCTAssertFalse(rig.panel.panelForTesting.isVisible, "panel remained visible at step \(step)")
    }

    private func memoryMiB(_ flavor: task_flavor_t) -> Double {
        if flavor == task_flavor_t(MACH_TASK_BASIC_INFO) {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, flavor, $0, &count)
                }
            }
            return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func snapshot(_ rig: Rig) -> Snapshot {
        var views = Set<ObjectIdentifier>()
        var layers = Set<ObjectIdentifier>()
        func walkLayer(_ layer: CALayer) {
            guard layers.insert(ObjectIdentifier(layer)).inserted else { return }
            layer.sublayers?.forEach(walkLayer)
        }
        func walkView(_ view: NSView) {
            guard views.insert(ObjectIdentifier(view)).inserted else { return }
            if let layer = view.layer { walkLayer(layer) }
            view.subviews.forEach(walkView)
        }
        if let content = rig.panel.panelForTesting.contentView { walkView(content) }
        return Snapshot(
            views: views.count, layers: layers.count,
            rss: memoryMiB(task_flavor_t(MACH_TASK_BASIC_INFO)),
            footprint: memoryMiB(task_flavor_t(TASK_VM_INFO)),
            monitors: rig.panel.activeEventMonitorsForTesting,
            subscriptions: rig.panel.activeSubscriptionsForTesting,
            drawObservers: DrawBoardView.activeNotificationRegistrationsForTesting
        )
    }

    private func checkpoint(_ label: String, rig: Rig, baseline: Snapshot?) -> Snapshot {
        settle(0.45)
        let current = snapshot(rig)
        print("LEAKS_HUNT \(label) \(current.line)")
        fflush(stdout)
        XCTAssertFalse(rig.panel.hasSwipeCarryTimerForTesting, "\(label): hidden panel has a swipe timer")
        XCTAssertEqual(PanelGenieView.activeDisplayLinksForTesting, 0, "\(label): hidden panel has a Genie display link")
        XCTAssertEqual(TasksDisplayClock.activeSourcesForTesting, 0, "\(label): task display link/timer still running")
        XCTAssertEqual(NotesDisplayFrameClock.activeSourcesForTesting, 0, "\(label): note frame link/timer still running")
        XCTAssertEqual(current.monitors, 0, "\(label): hidden panel keeps event monitors")
        XCTAssertFalse(rig.panel.hasPendingPageReleaseRetryForTesting,
                       "\(label): unexpected hidden release observer")
        if let baseline {
            XCTAssertEqual(current.subscriptions, baseline.subscriptions,
                           "\(label): Combine subscription count changed from warmed baseline")
            XCTAssertEqual(current.drawObservers, baseline.drawObservers,
                           "\(label): Draw NotificationCenter tokens accumulated")
            // SwiftUI/CA may retain bounded warm hosts and reuse allocation pools.
            // The warm baseline is captured after each real page was first visited.
            XCTAssertLessThanOrEqual(current.views, baseline.views + max(24, baseline.views / 10),
                                     "\(label): native view count continues growing")
            XCTAssertLessThanOrEqual(current.layers, baseline.layers + max(24, baseline.layers / 10),
                                     "\(label): layer count continues growing")
        }
        return current
    }

    func testPanel200ShowsHidesAnd500PageSwitches() async throws {
        try requireInvisibleSoak()
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let rig = try makeRig()
        defer { rig.dispose() }
        let screen = try XCTUnwrap(NSScreen.main)
        var rng = Generator(state: panelSeed)
        var switches = 0
        var baseline: Snapshot?
        var at100: Snapshot?
        print("LEAKS_HUNT seed=\(panelSeed) group=panel requested_shows=200 requested_switches=500 pid=\(getpid())")

        for cycle in 0..<200 {
            XCTAssertTrue(rig.panel.show(on: screen, corner: .topRight))
            XCTAssertTrue(rig.panel.panelForTesting.isVisible)
            // Exactly 500 real route switches, distributed across 200 reveals.
            let moves = cycle.isMultiple(of: 2) ? 3 : 2
            for move in 0..<moves {
                // End each cycle on Tasks, so every hidden sample has the
                // same foreground page and the switch total remains exact.
                let other = PanelSection.allCases.filter {
                    $0 != .tasks && $0 != rig.ui.selectedSection
                }
                let next: PanelSection = move == moves - 1 ? .tasks : other[rng.next(other.count)]
                rig.ui.switchPage(to: next, motion: .instant)
                XCTAssertEqual(rig.ui.selectedSection, next)
                switches += 1
            }
            try await hide(rig, step: cycle)
            if (cycle + 1).isMultiple(of: 25) {
                let sample = checkpoint("panel_cycles=\(cycle + 1) page_switches=\(switches)", rig: rig, baseline: baseline)
                if baseline == nil { baseline = sample }
                if cycle == 99 { at100 = sample }
                if cycle == 199, let at100 {
                    print("LEAKS_HUNT panel_last100_delta_rss_mib=\(sample.rss - at100.rss) " +
                          "footprint_mib=\(sample.footprint - at100.footprint)")
                    XCTAssertLessThanOrEqual(sample.rss - at100.rss, 28,
                                             "resident growth persisted after warm-up")
                    XCTAssertLessThanOrEqual(sample.footprint - at100.footprint, 28,
                                             "physical footprint growth persisted after warm-up")
                }
            }
        }
        XCTAssertEqual(switches, 500)
    }

    private func openAndCloseOneTaskNote(_ rig: Rig, taskID: UUID, directClose: Bool = false) async throws -> WeakObject {
        rig.ui.openTaskNote(taskID, from: .tasks)
        let didOpen = await eventually { rig.draft.pages.taskNotePresenter?.taskID == taskID }
        XCTAssertTrue(didOpen)
        // Never bind a strong presenter local in this suspended async test
        // frame: otherwise the test can itself keep the object alive.
        let ref = WeakObject(try XCTUnwrap(rig.draft.pages.taskNotePresenter))
        if directClose {
            let closed = await rig.draft.pages.prepareTaskNoteRoute(nil)
            XCTAssertTrue(closed, "direct durable close should succeed")
            rig.ui.openTaskNoteID = nil
        } else {
            TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: rig.ui, controller: rig.draft.pages)
        }
        let didClose = await eventually {
            rig.ui.openTaskNoteID == nil && rig.draft.pages.taskNotePresenter == nil
        }
        XCTAssertTrue(didClose)
        XCTAssertNil((ref.object as? TaskNotePresenter)?.host.textView.escapeFallback,
                     "closed warm editor retains its Escape route callback")
        let detached = await eventually(timeout: .seconds(2)) {
            (ref.object as? TaskNotePresenter)?.host.scrollView.window == nil
        }
        print("LEAKS_HUNT_ROUTE detached_native_scroll=\(detached) has_superview=\((ref.object as? TaskNotePresenter)?.host.scrollView.superview != nil)")
        return ref
    }

    private func closeHeadlessTaskNote(_ rig: Rig, taskID: UUID) async throws -> WeakObject {
        let library = AtticLibrary(tasks: rig.tasks)
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: rig.tasks, library: library,
                                              notes: rig.draft.pages, design: .default, columnInset: 28,
                                              defaults: rig.defaults)
        let ref = WeakObject(presenter)
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        return ref
    }

    func testHeadlessClosedTaskNoteReleasesItsPresenter() async throws {
        try requireInvisibleSoak()
        let rig = try makeRig()
        defer { rig.dispose() }
        let taskID = try XCTUnwrap(rig.tasks.commit([TaskDraft(title: "Headless release")])?.first?.id)
        await rig.draft.pages.startAndWait()
        let ref = try await closeHeadlessTaskNote(rig, taskID: taskID)
        let released = await eventually { ref.object == nil }
        XCTAssertTrue(released,
                      "headless presenter must not be owned by its completed close task")
    }

    func testOneClosedTaskNoteReleasesItsPresenterAndCallbacks() async throws {
        try requireInvisibleSoak()
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let rig = try makeRig()
        defer { rig.dispose() }
        let taskID = try XCTUnwrap(rig.tasks.commit([TaskDraft(title: "One task note")])?.first?.id)
        await rig.draft.pages.startAndWait()
        XCTAssertTrue(rig.panel.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight))
        let ref = try await openAndCloseOneTaskNote(rig, taskID: taskID)
        try? await Task.sleep(for: .milliseconds(500))
        try await hide(rig, step: 0)
        print("LEAKS_HUNT_SINGLE_READY pid=\(getpid()) weak_presenter_alive=\(ref.object != nil)")
        fflush(stdout)
        if ProcessInfo.processInfo.environment["ATTIC_LEAKS_HUNT_SAMPLE"] == "1" {
            try await Task.sleep(for: .seconds(50))
        }
        XCTAssertNil(ref.object, "one closed task-note presenter must be deallocated")
    }

    func testDirectDurableTaskNoteCloseReleasesItsPresenter() async throws {
        try requireInvisibleSoak()
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let rig = try makeRig()
        defer { rig.dispose() }
        let taskID = try XCTUnwrap(rig.tasks.commit([TaskDraft(title: "Direct durable close")])?.first?.id)
        await rig.draft.pages.startAndWait()
        XCTAssertTrue(rig.panel.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight))
        let ref = try await openAndCloseOneTaskNote(rig, taskID: taskID, directClose: true)
        try? await Task.sleep(for: .milliseconds(500))
        try await hide(rig, step: 0)
        XCTAssertNil(ref.object, "direct durable close must release its presenter")
    }

    func testEditors100EachWithDrawObserverAndWeakLifetimeChecks() async throws {
        try requireInvisibleSoak()
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let rig = try makeRig()
        defer { rig.dispose() }
        let taskID = try XCTUnwrap(rig.tasks.commit([TaskDraft(title: "Hunt task note")])?.first?.id)
        guard case .success = rig.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Saved note")])) else {
            return XCTFail("could not seed Notes library")
        }
        await rig.draft.pages.startAndWait()
        if rig.draft.pages.isLibraryPresented { rig.draft.pages.dismissLibrary() }
        XCTAssertTrue(rig.panel.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight))
        let draw = DrawPageModel(store: DrawInMemoryStore())
        draw.pasteboard = NSPasteboard(name: NSPasteboard.Name("leaks-hunt-\(UUID().uuidString)"))
        draw.start()
        defer { draw.setShown(false); draw.pasteboard.releaseGlobally() }
        var rng = Generator(state: editorSeed)
        var transientRefs: [WeakObject] = []
        var presenters: [WeakObject] = []
        var baseline: Snapshot?
        print("LEAKS_HUNT seed=\(editorSeed) group=editors cycles=100 chat=100 task_note=100 notes_library=100 draw_library=100")

        for cycle in 0..<100 {
            // Shuffle the independent controls while preserving the real
            // open/close pairing. Closing chat never cancels its background work.
            var order = [0, 1, 2, 3]
            for index in 0..<order.count {
                order.swapAt(index, index + rng.next(order.count - index))
            }
            for action in order {
                switch action {
                case 0:
                    rig.ui.agentChat.open()
                    XCTAssertTrue(rig.ui.agentChat.isOpen)
                    rig.ui.agentChat.close()
                    XCTAssertFalse(rig.ui.agentChat.isOpen)
                case 1:
                    rig.ui.switchPage(to: .tasks, motion: .instant)
                    // Let the Tasks route's hosting view mount before asking
                    // it to present a task note.
                    await Task.yield()
                    rig.ui.openTaskNote(taskID, from: .tasks, backTitle: "Back to Tasks")
                    let didOpen = await eventually { rig.draft.pages.taskNotePresenter?.taskID == taskID }
                    guard didOpen else {
                        XCTFail("task note did not mount at cycle \(cycle)")
                        return
                    }
                    presenters.append(WeakObject(rig.draft.pages.taskNotePresenter))
                    TaskNoteRouteHost<EmptyView>.closeRoute(taskID, uiState: rig.ui, controller: rig.draft.pages)
                    let didClose = await eventually {
                        rig.ui.openTaskNoteID == nil && rig.draft.pages.taskNotePresenter == nil
                    }
                    guard didClose else {
                        XCTFail("task note did not close at cycle \(cycle)")
                        return
                    }
                case 2:
                    rig.ui.switchPage(to: .notes, motion: .instant)
                    XCTAssertTrue(rig.draft.pages.showLibrary(), "notes library refused at cycle \(cycle)")
                    XCTAssertTrue(rig.draft.pages.isLibraryPresented)
                    rig.draft.pages.dismissLibrary()
                    XCTAssertFalse(rig.draft.pages.isLibraryPresented)
                default:
                    rig.ui.switchPage(to: .canvas, motion: .instant)
                    draw.openFilter()
                    XCTAssertTrue(draw.isFiltering, "Draw library did not open at cycle \(cycle)")
                    draw.closeFilter()
                    XCTAssertFalse(draw.isFiltering)
                    // A real offscreen board window registers seven
                    // NotificationCenter observers, then detaches them.
                    // Keep only weak references to its controller/view/layers.
                    autoreleasepool {
                        let window = NSWindow(
                            contentRect: CGRect(x: -6000, y: -6000, width: 320, height: 460),
                            styleMask: [.borderless], backing: .buffered, defer: false
                        )
                        window.isReleasedWhenClosed = false
                        let view = DrawBoardView(model: draw)
                        view.frame = CGRect(x: 0, y: 0, width: 320, height: 460)
                        let controller = NSViewController()
                        controller.view = view
                        window.contentViewController = controller
                        transientRefs += [WeakObject(window), WeakObject(view), WeakObject(controller), WeakObject(view.layer)]
                        XCTAssertEqual(DrawBoardView.activeNotificationRegistrationsForTesting % 7, 0)
                        window.contentViewController = nil
                        window.close()
                    }
                }
            }
            if (cycle + 1).isMultiple(of: 25) {
                rig.ui.switchPage(to: .tasks, motion: .instant)
                // SwiftUI's route teardown and native close finish in actor
                // tasks; give them a turn before checking weak lifetimes.
                try? await Task.sleep(for: .milliseconds(400))
                try await hide(rig, step: cycle)
                try? await Task.sleep(for: .milliseconds(400))
                let sample = checkpoint("editor_cycles=\(cycle + 1)", rig: rig, baseline: baseline)
                if baseline == nil { baseline = sample }
                let liveTransient = transientRefs.compactMap(\.object).count
                let livePresenters = presenters.compactMap(\.object).count
                print("LEAKS_HUNT editor_weak cycle=\(cycle + 1) transient=\(liveTransient) task_presenters=\(livePresenters)")
                XCTAssertEqual(liveTransient, 0, "detached Draw board/view controller/layers remain alive")
                XCTAssertEqual(livePresenters, 0, "closed task-note presenters remain alive")
                if cycle < 99 {
                    XCTAssertTrue(rig.panel.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight))
                }
            }
        }
    }

    func testRunner50ReadOnlyScriptsReleaseTheirOwners() async throws {
        try requireInvisibleSoak()
        var rng = Generator(state: runnerSeed)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let tasks = TaskStore(container: container)
        _ = tasks.commit([TaskDraft(title: "Scripted test task")])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let parser = TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { now })
        let tools = AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks), parser: parser)
        let startingTasks = tasks.tasks.count
        var runners: [WeakObject] = []
        print("LEAKS_HUNT seed=\(runnerSeed) group=agent requested_runs=50 mode=readOnly")
        for cycle in 0..<50 {
            do {
                let runner = ScriptedAgentRunner(tools: tools, mode: { .readOnly }, now: { now },
                                                 calendar: calendar, pace: 0)
                runners.append(WeakObject(runner))
                let scripts = ["tidy", "week", "plan today"]
                var finished = false
                for await event in runner.send(scripts[rng.next(scripts.count)], watching: false) {
                    if case .finished = event { finished = true }
                    if case .approvalNeeded = event { XCTFail("read-only run unexpectedly requested approval") }
                    if case .changes = event { XCTFail("read-only run unexpectedly mutated a task") }
                }
                XCTAssertTrue(finished, "script did not finish at cycle \(cycle)")
            }
            await Task.yield()
            XCTAssertEqual(tasks.tasks.count, startingTasks, "read-only run changed tasks")
            if (cycle + 1).isMultiple(of: 10) {
                settle(0.2)
                let live = runners.compactMap(\.object).count
                print("LEAKS_HUNT agent_runs=\(cycle + 1) weak_live_runners=\(live) " +
                      "rss_mib=\(memoryMiB(task_flavor_t(MACH_TASK_BASIC_INFO))) " +
                      "footprint_mib=\(memoryMiB(task_flavor_t(TASK_VM_INFO)))")
                XCTAssertEqual(live, 0, "completed scripted runners remain alive")
            }
        }
        print("LEAKS_HUNT_READY pid=\(getpid()) for_usr_bin_leaks=1")
        fflush(stdout)
        if ProcessInfo.processInfo.environment["ATTIC_LEAKS_HUNT_SAMPLE"] == "1" {
            try await Task.sleep(for: .seconds(35))
        }
    }
}
#endif
