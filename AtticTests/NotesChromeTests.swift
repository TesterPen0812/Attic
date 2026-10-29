import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Notes page's chrome (Notes Page v2 in the task panel, accepted
/// 2026-10-27/28): the shared top row (pin, middle slot, search, page
/// switch) in Tasks' places, the list right under it, the tag bar and
/// compose in All notes' bottom bar, Back and Aa in the writing view's.
@MainActor
final class NotesChromeTests: XCTestCase {
    // MARK: Geometry

    func testTheTopRowKeepsTasksPlacesAndLeavesAMiddleSlot() {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let chrome = layout.chromeInsets
        let button = PanelTopRowLayout.searchButtonFrame(layout)
        // The design (2×): a 54 px search 10 px before the switch, the
        // row starting 10 px after the pin.
        XCTAssertEqual(button.size, CGSize(width: 27, height: 27))
        XCTAssertEqual(button.minY, chrome.top)
        let switchShut = AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count)
        XCTAssertEqual(button.maxX, 340 - chrome.trailing - switchShut - TasksDesignMetrics.headerGap, accuracy: 0.001)
        XCTAssertEqual(PanelTopRowLayout.leading(layout), chrome.leading + 27 + 5, accuracy: 0.001)
        let slot = PanelTopRowLayout.middleSlot(layout)
        XCTAssertEqual(slot.lowerBound, PanelTopRowLayout.leading(layout))
        XCTAssertEqual(slot.upperBound, button.minX - 5, accuracy: 0.001, "the middle slot ends a gap before the search")
        XCTAssertGreaterThan(slot.upperBound - slot.lowerBound, 100, "room for Calendar's month controls")
    }

    func testTheBarsTakeTheTasksFooterMeasures() {
        XCTAssertEqual(NotesBarMetrics.control, 30.5, "61 px")
        XCTAssertEqual(NotesBarMetrics.radius, 16, "32 px")
        XCTAssertEqual(NotesBarMetrics.gap, 5, "10 px")
        XCTAssertEqual(NotesBarMetrics.pillHeight, 23.5, "47 px")
        XCTAssertEqual(NotesBarMetrics.pillFontSize, 10.5, "21 px")
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        XCTAssertEqual(NotesLibraryView.restTop(layout: layout), layout.headerBottom + 7.5,
                       "the list starts right under the top row (100 px under 85 px)")
        XCTAssertEqual(NotesLibraryView.edges(layout: layout, bottomControls: 40).top, layout.headerBottom)
    }

    // MARK: In the panel

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private final class Box<T> { var value: T?; init() {} }

    /// The real panel with two tagged notes; `body` runs with it up.
    private func withPanel(_ body: (_ host: AtticPanelHostingView, _ state: PanelUIState, _ tasks: TasksPageState,
                                    _ store: TaskStore, _ draft: NoteDraftController,
                                    _ library: () -> NotesLibraryModel?) throws -> Void) throws {
        let suite = "NotesChrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Reading list")]), tags: ["books"]).get()
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let draft = NoteDraftController(noteStore: notes)
        let library = Box<NotesLibraryModel>()
        NotesEditorPage.lifetimeProbe = { _, model in library.value = model }
        defer { NotesEditorPage.lifetimeProbe = nil }
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: tasksState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        spin(1.0)
        try body(host, state, tasksState, store, draft, { library.value })
    }

    /// An element's frame in the host's top-left space, or nil if absent.
    private func frame(of identifier: String, in host: AtticPanelHostingView) -> CGRect? {
        host.layoutSubtreeIfNeeded()
        guard let element = elements(host).first(where: { ($0.accessibilityIdentifier?() ?? "") == identifier }),
              let screen = element.accessibilityFrame?(), let window = host.window, screen.width > 0 else { return nil }
        let local = host.convert(window.convertFromScreen(screen), from: nil)
        return host.isFlipped ? local : CGRect(x: local.minX, y: host.bounds.height - local.maxY,
                                               width: local.width, height: local.height)
    }

    private func element(_ identifier: String, in host: AtticPanelHostingView) -> AnyObject? {
        elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
    }

    func testNotesSharesTheTopRowAndTheBarsAndTasksKeepsItsState() throws {
        try withPanel { host, state, tasksState, store, draft, library in
            // Tasks: the search button in the shared row's place.
            state.selectSection(.tasks)
            spin(1.0)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let expected = PanelTopRowLayout.searchButtonFrame(layout)
            let tasksSearch = try XCTUnwrap(frame(of: "tasks-find-button", in: host), "Tasks' search button")
            let model = tasksState.model(for: store, toasts: nil)
            model.tab = .backlog
            spin(0.5)

            // Notes: the same place; no task-list filter button.
            state.selectSection(.notes)
            spin(1.5)
            let notesSearch = try XCTUnwrap(frame(of: "notes-search-button", in: host), "Notes' search button")
            XCTAssertEqual(notesSearch.midX, tasksSearch.midX, accuracy: 0.5, "the search keeps its place across pages")
            XCTAssertEqual(notesSearch.midY, tasksSearch.midY, accuracy: 0.5)
            XCTAssertEqual(notesSearch.midX, expected.midX, accuracy: 1)
            XCTAssertNil(element("tasks-view-options", in: host), "the task-list filter button is hidden on Notes")

            // All notes: tag bar and compose in the bottom bar.
            XCTAssertTrue(draft.pages.showLibrary())
            spin(1.0)
            let tagBar = try XCTUnwrap(frame(of: "notes-tag-bar", in: host), "the tag bar")
            let compose = try XCTUnwrap(frame(of: "notes-new-note", in: host), "compose")
            XCTAssertEqual(compose.height, NotesBarMetrics.control, accuracy: 0.5)
            XCTAssertEqual(tagBar.height, NotesBarMetrics.control, accuracy: 0.5)
            XCTAssertEqual(compose.minX - tagBar.maxX, NotesBarMetrics.gap, accuracy: 0.5, "10 px apart")
            XCTAssertEqual(compose.maxX, host.bounds.width - layout.chromeInsets.trailing, accuracy: 0.5, "compose on the right")
            XCTAssertNil(element("notes-all-notes", in: host), "no Back while All notes shows")
            XCTAssertNil(element("notes-format-button", in: host))

            // Choosing a tag filters the list.
            let model2 = try XCTUnwrap(library(), "the library model")
            let books = try XCTUnwrap(element("notes-tag-bar-books", in: host), "the #books pill")
            XCTAssertTrue(books.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertEqual(model2.tagFilter, "books")
            let all = try XCTUnwrap(element("notes-tag-bar-all", in: host))
            XCTAssertTrue(all.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertNil(model2.tagFilter, "All shows every note")

            // The search filters All notes through the library's query.
            let searchButton = try XCTUnwrap(element("notes-search-button", in: host))
            XCTAssertTrue(searchButton.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNotNil(element("notes-search", in: host), "the field takes the row")
            XCTAssertNil(element("notes-search-button", in: host))
            model2.query = "launch"
            spin(0.2)
            XCTAssertEqual(model2.query, "launch")

            // The writing view: Back on the left, Aa (once the note has a body) on the right.
            draft.pages.dismissLibrary()
            spin(1.0)
            let back = try XCTUnwrap(frame(of: "notes-all-notes", in: host), "Back")
            XCTAssertEqual(back.minX, layout.chromeInsets.leading, accuracy: 0.5, "Back on the left")
            XCTAssertEqual(back.height, NotesBarMetrics.control, accuracy: 0.5)
            XCTAssertNil(element("notes-tag-bar", in: host), "the tag bar is All notes' only")
            XCTAssertNotNil(element("notes-search-button", in: host), "the search button returns on a note")

            // Back on Tasks: the page as it was left.
            state.selectSection(.tasks)
            spin(1.0)
            XCTAssertTrue(tasksState.model(for: store, toasts: nil) === model, "the same page model")
            XCTAssertEqual(model.tab, .backlog, "Tasks keeps its tab across the switch")
        }
    }
}
