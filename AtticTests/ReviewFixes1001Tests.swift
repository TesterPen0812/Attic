import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// GPT-6.1's review of the consolidated Phase 1 (`ae84d1c`): drag-out where
/// reordering is off, Copy with a Done-log family, ⌥⌘V while Find is open,
/// and integration coverage for a real AppKit drag session ended as Esc ends
/// it, and for swipe-to-close over a task edit and a failed note save.
@MainActor
final class ReviewFixes1001Tests: XCTestCase {
    // MARK: - Drag-out where reordering is off (P2-2)

    func testOnlyNowAndLatersManualOrderReorders() {
        XCTAssertTrue(TasksPage.reorders(tab: .now, manual: true))
        XCTAssertTrue(TasksPage.reorders(tab: .backlog, manual: true))
        XCTAssertFalse(TasksPage.reorders(tab: .now, manual: false), "a sorted view only drags out")
        XCTAssertFalse(TasksPage.reorders(tab: .done, manual: true), "Done only drags out")
    }

    /// A sorted Now: a row dragged inside the panel moves nothing (no
    /// neighbour moves aside, the release commits nothing), and dragged out
    /// of the window it goes out as a copy.
    func testASortedViewDragsOutButNeverReorders() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        var options = TasksViewOptions()
        options.sort = .priority
        hosted.model.setViewOptions(options, for: .now)
        hosted.spin(0.6)
        let rows = hosted.model.rows(for: .now).filter { $0.status == .todo }
        let first = try XCTUnwrap(rows.first)
        let before = hosted.model.rows(for: .now).map(\.id)
        let revision = hosted.store.revision
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first.id)])

        // Inside the panel, down past two rows, and released.
        drag(in: hosted, from: frame.midY, through: [(200, frame.midY + 30), (200, frame.midY + 110)], release: (200, frame.midY + 110))
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), before, "nothing moved")
        XCTAssertEqual(hosted.store.revision, revision, "nothing saved")

        // Out of the window.
        var exported: TasksTextExport?
        hosted.pointer.startDragOut = { export, _ in exported = export }
        drag(in: hosted, from: frame.midY, through: [(200, frame.midY + 20), (420, frame.midY + 20), (520, frame.midY + 20)],
             release: (520, frame.midY + 20), until: { exported != nil })
        XCTAssertEqual(exported?.items.map(\.title), [first.model.title], "the drag went out")
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), before, "still nothing moved")
        XCTAssertNil(hosted.pointer.liftedCard.lift)
    }

    /// Done: a finished task drags out of the panel too.
    func testDoneDragsOut() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .done)
        let row = try XCTUnwrap(hosted.model.doneDays().flatMap(\.rows).first)
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .done, id: row.id)])
        var exported: TasksTextExport?
        hosted.pointer.startDragOut = { export, _ in exported = export }
        drag(in: hosted, from: frame.midY, through: [(200, frame.midY + 20), (420, frame.midY + 20), (520, frame.midY + 20)],
             release: (520, frame.midY + 20), until: { exported != nil })
        XCTAssertEqual(exported?.items.map(\.title), [row.model.title])
        XCTAssertNil(hosted.pointer.liftedCard.lift)
    }

    // MARK: - The AppKit session's end

    /// A drag out offers a copy to other apps and nothing within Attic.
    /// Esc, or a release over nothing, ends the session with no operation:
    /// the source finishes once, the panel's drag state clears, and nothing
    /// in the store changes. (A real `NSDraggingSession` runs AppKit's modal
    /// drag loop, which waits for real mouse input: in a unit test it hangs,
    /// as CI's first run did. `TasksDragOutUITests` drives one for real.)
    func testTheDragSourceOffersACopyAndEndsOnce() {
        XCTAssertEqual(TasksDragOut.operations(for: .outsideApplication), .copy)
        XCTAssertEqual(TasksDragOut.operations(for: .withinApplication), [])
        var ends = 0
        let source = TasksDragOut.Source(ended: { ends += 1 })
        TasksDragOut.Source.current = source
        let endedBefore = TasksDragOut.Probe.shared.ended
        source.finish()
        source.finish()
        XCTAssertEqual(ends, 1, "it ends once")
        XCTAssertNil(TasksDragOut.Source.current)
        XCTAssertEqual(TasksDragOut.Probe.shared.ended, endedBefore + 1)
    }

    // MARK: - Copy with a Done-log family (P2-3)

    func testCopyCarriesLiveAndArchivedSubtasksAndStopsOnAnUnreadableFamily() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        let live = try XCTUnwrap(store.create(title: "Plan the trip", status: .todo))
        _ = try XCTUnwrap(store.create(title: "Book flights", status: .todo, parentID: live.id))
        let archived = try XCTUnwrap(store.create(title: "Move house", status: .todo))
        _ = try XCTUnwrap(store.create(title: "Pack the kitchen", status: .todo, parentID: archived.id))
        XCTAssertTrue(library.completeTask(archived.id).isApplied)
        XCTAssertGreaterThan(store.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 0)
        XCTAssertNil(store.task(withID: archived.id), "in the Done log")

        let export = try XCTUnwrap(model.export([live.id, archived.id]))
        XCTAssertEqual(export.items.map(\.title), ["Plan the trip", "Move house"])
        XCTAssertEqual(export.items[0].subtasks.map(\.title), ["Book flights"], "a live family")
        XCTAssertEqual(export.items[1].subtasks.map(\.title), ["Pack the kitchen"], "an archived family")
        XCTAssertTrue(export.markdown.contains("  - [x] Pack the kitchen"), export.markdown)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AtticReviewFixes-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copy([archived.id], to: pasteboard))
        XCTAssertTrue(pasteboard.string(forType: TasksTextExport.markdownType)?.contains("Pack the kitchen") == true)

        // Either of the family's reads failing: no copy at all, the error kept.
        for skip in 0...1 {
            let failing = NSPasteboard(name: NSPasteboard.Name("AtticReviewFixes-\(UUID().uuidString)"))
            defer { failing.releaseGlobally() }
            store.doneFamilyReadsToSkipBeforeFailing = skip
            XCTAssertNil(model.export([live.id, archived.id]), "read \(skip) fails: no export")
            store.doneFamilyReadsToSkipBeforeFailing = skip
            XCTAssertFalse(model.copy([archived.id], to: failing), "read \(skip) fails: nothing copied")
            XCTAssertNil(failing.string(forType: .string), "the pasteboard is untouched")
            XCTAssertEqual(store.lastErrorMessage, "The Done log could not be read.")
        }
    }

    // MARK: - ⌥⌘V while Find is open

    func testViewOptionsOpensWhileFindIsOpen() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let deadline = Date().addingTimeInterval(2)
        while !hosted.window.isKeyWindow, Date() < deadline {
            NSApp.activate()
            hosted.window.makeKeyAndOrderFront(nil)
            hosted.spin(0.1)
        }
        var anchors: [NSView] = []
        hosted.pointer.openViewOptions = { anchors.append($0) }
        hosted.press("v", keyCode: 9, modifiers: [.command, .option])
        XCTAssertEqual(anchors.count, 1, "⌥⌘V opens View Options")
        hosted.press("f", keyCode: 3, modifiers: .command)
        hosted.spin(0.6)
        XCTAssertTrue(hosted.searchFieldShown, "Find has taken the line, and View Options' button with it")
        hosted.press("v", keyCode: 9, modifiers: [.command, .option])
        XCTAssertEqual(anchors.count, 2, "⌥⌘V still opens View Options with Find open")
        XCTAssertNotNil(anchors.last?.window, "under an anchor in the panel")
    }

    // MARK: - Helpers

    /// A press on the row at `y` (page coordinates), moves through
    /// `points`, and a release (none: the button stays down).
    private func drag(in hosted: Hosted, from y: CGFloat, through points: [(CGFloat, CGFloat)], release: (CGFloat, CGFloat)?,
                      until done: () -> Bool = { false }) {
        let window = hosted.window
        func post(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: hosted.height - y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 7, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        post(.leftMouseDown, x: 200, y: y)
        for (x, y) in points { post(.leftMouseDragged, x: x, y: y) }
        var timer: Timer?
        if let release {
            timer = Timer(timeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated { post(.leftMouseUp, x: release.0, y: release.1) }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (timer?.isValid ?? false) || !done() {
            Hosted.pumpEvents(limit: 8)
            hosted.spin(0.05)
            if timer == nil, done() { break }
        }
        hosted.spin(0.6)
    }
}

/// Swipe-to-close over the real panel (GPT-6.1's review): a task edit
/// blocks it, and so does a note draft that cannot be saved (the draft
/// stays); with neither, the same swipe closes the panel.
@MainActor
final class SwipeToCloseIntegrationTests: XCTestCase {
    private var cleanup: [() -> Void] = []

    override func tearDown() async throws {
        cleanup.forEach { $0() }
        cleanup.removeAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func makeController() throws -> (AtticPanelController, PanelUIState, NoteDraftController, PersistenceGate) {
        let suite = "SwipeToCloseIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let gate = PersistenceGate()
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore())
        let noteDraft = NoteDraftController(noteStore: notes)
        let uiState = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: noteDraft, settings: AppSettings(defaults: defaults), uiState: uiState
        )
        cleanup.append {
            gate.shouldFail = false
            _ = controller.requestHide { _ in }
            defaults.removePersistentDomain(forName: suite)
        }
        controller.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight)
        spin(until: { controller.isVisibleForPerformanceProbe }, timeout: 3)
        spin(0.8)
        return (controller, uiState, noteDraft, gate)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
    }

    /// A fresh two-finger pull toward the right edge over the header.
    private func swipe(_ panel: AtticPanel) throws {
        let point = CGPoint(x: panel.frame.width / 2, y: panel.frame.height - AtticStyle.panelElevationMargin - 20)
        func scroll(_ dx: Int32, phase: Int64) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            let screen = panel.convertPoint(toScreen: point)
            let height = NSScreen.screens.first?.frame.height ?? 0
            event.location = CGPoint(x: screen.x, y: height - screen.y)
            let ns = try XCTUnwrap(NSEvent(cgEvent: event))
            return ns
        }
        // Classic scrolling reports the other sign: either way, toward the
        // right edge (the panel is docked top right).
        let sign: Int32 = (try scroll(1, phase: 1)).isDirectionInvertedFromDevice ? 1 : -1
        panel.sendEvent(try scroll(0, phase: 1))
        for _ in 0..<14 { panel.sendEvent(try scroll(6 * sign, phase: 2)) }
        panel.sendEvent(try scroll(0, phase: 4))
        spin(0.8)
    }

    func testATaskEditBlocksSwipeToCloseAndTheSameSwipeClosesWithout() throws {
        let (controller, uiState, _, _) = try makeController()
        let panel = controller.panelForTesting
        // The Tasks page holds this lock while a title or subtask is edited.
        uiState.setInteractionLock(.taskEditing, isActive: true)
        try swipe(panel)
        XCTAssertTrue(controller.isVisibleForPerformanceProbe, "an edit keeps the panel")
        uiState.setInteractionLock(.taskEditing, isActive: false)
        try swipe(panel)
        spin(until: { !controller.isVisibleForPerformanceProbe }, timeout: 3)
        XCTAssertFalse(controller.isVisibleForPerformanceProbe, "without the edit the same swipe closes it")
    }

    func testAFailedNoteSaveBlocksSwipeToCloseAndKeepsTheDraft() throws {
        let (controller, uiState, noteDraft, gate) = try makeController()
        let panel = controller.panelForTesting
        uiState.selectSection(.notes)
        spin(0.5)
        XCTAssertTrue(noteDraft.beginNew())
        noteDraft.body = "An unsaved thought"
        gate.shouldFail = true
        try swipe(panel)
        XCTAssertTrue(controller.isVisibleForPerformanceProbe, "a draft that cannot be saved keeps the panel")
        XCTAssertEqual(noteDraft.body, "An unsaved thought", "the draft stays")
        gate.shouldFail = false
        try swipe(panel)
        spin(until: { !controller.isVisibleForPerformanceProbe }, timeout: 3)
        XCTAssertFalse(controller.isVisibleForPerformanceProbe, "saved, the same swipe closes it")
    }
}
