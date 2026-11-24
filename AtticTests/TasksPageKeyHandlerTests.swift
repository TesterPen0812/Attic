import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Tasks page's key handler and the environment below it (board
/// SPEED-KEPTHOST-ENV-REROOT; the lead, LOG 24 Nov 06:36). A handler that
/// is a new value on every body pass made `.onKeyPress` write a new
/// environment below it each time, with the same contents, and every view
/// down to the tabs' kept hosts took it as a change.
@MainActor
final class TasksPageKeyHandlerTests: XCTestCase {
    /// A composer route the test can swap after the page is up, as the
    /// panel's would change.
    final class ComposerSwitch: ObservableObject {
        @Published var route: PanelComposerRoute?
    }

    private struct Switched: View {
        @ObservedObject var composer: ComposerSwitch
        let page: TasksPage
        var body: some View { page.environment(\.panelComposer, composer.route) }
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func testAPagePassWithNothingChangedKeepsTheEnvironmentBelowItsKeyHandler() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let runs = TasksPageRenderProbe.bodyRuns
        let environments = TasksPageRenderProbe.environmentsBelowKeys
        for _ in 1...5 {
            hosted.model.objectWillChange.send()
            hosted.spin(0.1)
        }
        let passes = TasksPageRenderProbe.bodyRuns - runs
        let below = TasksPageRenderProbe.environmentsBelowKeys - environments
        print("TASKS_KEYS page_passes=\(passes) environments_below_keys=\(below)")
        XCTAssertGreaterThanOrEqual(passes, 5, "harness: the page's body ran on each send")
        XCTAssertEqual(below, 0, "a page pass with nothing changed wrote a new environment below the key handler")
    }

    /// The box takes each pass's page: once the composer card is open, the
    /// page's keys stand down, and they come back when it closes.
    func testTheKeyHandlerActsOnThePageAsItIsNow() throws {
        try requireKeyWindowTests()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: false)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let size = CGSize(width: AtticLayout.panelSize.width, height: 520)
        var addBar = false
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { addBar }, set: { addBar = $0 }),
                             chrome: TasksPageChrome(), pointer: TasksPointer())
        let composer = ComposerSwitch()
        let window = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Switched(composer: composer, page: page)
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        defer { window.close() }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func down() {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                             isARepeat: false, keyCode: 125)!
                NSApp.postEvent(event, atStart: false)
                Hosted.pumpEvents()
            }
            spin(0.4)
        }
        spin(1)
        let rows = model.rows(for: .now).map(\.id)
        XCTAssertGreaterThanOrEqual(rows.count, 3, "harness: the demo seed has rows")

        down()
        XCTAssertEqual(model.selection, [rows[0]], "harness: ↓ with nothing selected selects the first row")

        composer.route = PanelComposerRoute(open: { _, _ in }, isOpen: { true })
        spin(0.4)
        down()
        XCTAssertEqual(model.selection, [rows[0]], "with the card open, the page's keys stand down")

        composer.route = nil
        spin(0.4)
        down()
        XCTAssertEqual(model.selection, [rows[1]], "with the card gone, ↓ moves again")
    }
}
