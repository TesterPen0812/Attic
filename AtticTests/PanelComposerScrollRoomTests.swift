import AppKit
import XCTest
@testable import Attic

/// The "+" card's room in the real panel (Accepted 2026-11-03, "The '+'
/// card takes over the bar's row": the list's bottom inset grows by the
/// card's height so the last rows scroll up instead of being covered).
/// The room reaches each page's scroll view through its bottom content
/// margin only (`panelComposerScrollRoom`), and a leaf that takes the
/// number through its own clearance. Every check reads the real
/// `NSScrollView` insets.
///
/// A page switch closes the card at once (the shell's `selectedSection`
/// change), so the room is held open here through the shared
/// `PanelComposerRoom`, as the card's overlay sets it. Hidden pages are
/// read while hidden: the margin a page shows on its first frame is the
/// one it already has behind the current page.
@MainActor
final class PanelComposerScrollRoomTests: XCTestCase {
    private let cardHeight: CGFloat = 152
    private var extra: CGFloat { max(0, cardHeight - AtticControlSize.addBarHeight) }

    @MainActor
    private struct Rig {
        let host: AtticPanelHostingView
        let state: PanelUIState
        let room: PanelComposerRoom
        let store: TaskStore
        let draft: NoteDraftController
        let calendarState: CalendarPageState
        let noteIDs: [UUID]

        var calendarModel: CalendarPageModel {
            calendarState.model(store: store, resumeDefaults: state.resumeDefaults, owner: .docked)
        }
    }

    override func setUp() {
        super.setUp()
        // Invisible windows receive no display-link frames; the end anchor
        // is checked under Reduce Motion, as the page-level tests do.
        AtticMotionPreference.systemReduceMotionOverride = true
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: First frame

    /// Notes' library and Calendar's grid, built behind Tasks with the card
    /// closed, take the room while hidden in one layout; Calendar's day,
    /// first built while hidden with the card open, has it on its first
    /// layout. Those hidden reads are the strict check: the scroll view a
    /// switch shows is the same object, so its first shown margin is the
    /// hidden one. The read right after a switch is looser: the switch
    /// closes the card, so it only checks that the margin is the open or
    /// the closed one (`assertShownMargin`).
    func testHiddenPagesCarryTheCardsRoomInTheirScrollMarginForTheirFirstFrame() throws {
        XCTAssertGreaterThan(extra, 0, "the card is taller than the bar's row")
        try withRig { rig in
            XCTAssertTrue(rig.draft.pages.showLibrary())
            var known = Set<ObjectIdentifier>()
            rig.state.selectSection(.notes)
            let library = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "the Notes library's scroll view")
            settle(rig.host, times: 3)
            rig.state.selectSection(.calendar)
            let grid = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "Calendar's grid scroll view")
            settle(rig.host, times: 3)
            rig.state.selectSection(.tasks)
            settle(rig.host, times: 2)
            let libraryClosed = library.contentInsets.bottom
            let gridClosed = grid.contentInsets.bottom

            rig.room.set(height: cardHeight, open: true)
            rig.host.layoutSubtreeIfNeeded() // one layout, no run-loop turn
            XCTAssertEqual(library.contentInsets.bottom - libraryClosed, extra, accuracy: 1,
                           "the hidden library's margin already has the card's room")
            XCTAssertEqual(grid.contentInsets.bottom - gridClosed, extra, accuracy: 1,
                           "the hidden grid's margin already has the card's room")

            // Calendar's day, first built while the card is open and Calendar hidden.
            rig.calendarModel.setDayView(true)
            let day = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "Calendar's day scroll view")
            let dayFirst = day.contentInsets.bottom
            settle(rig.host)

            // The switch closes the card; whatever the room is on the first
            // layout after it, the shown margin matches it.
            rig.state.selectSection(.notes)
            rig.host.layoutSubtreeIfNeeded()
            assertShownMargin(library.contentInsets.bottom - libraryClosed, roomAtRead: rig.room.height, "the library")
            settle(rig.host, times: 2)
            rig.state.selectSection(.tasks)
            settle(rig.host, times: 2)
            rig.room.set(height: cardHeight, open: true)
            settle(rig.host)
            rig.state.selectSection(.calendar)
            rig.host.layoutSubtreeIfNeeded()
            let dayAtSwitch = day.contentInsets.bottom
            let roomAtSwitch = rig.room.height

            rig.room.set(height: 0, open: false)
            settle(rig.host, times: 2)
            let dayClosed = day.contentInsets.bottom
            XCTAssertEqual(dayFirst - dayClosed, extra, accuracy: 1, "the day's first layout had the card's room")
            assertShownMargin(dayAtSwitch - dayClosed, roomAtRead: roomAtSwitch, "the day")
        }
    }

    /// Notes and Calendar not yet built when the card opens, then built
    /// behind Tasks (the pointer on the page switch) and shown: each scroll
    /// view's first layout has the room.
    func testAPageFirstBuiltWhileTheCardIsOpenHasTheRoomOnItsFirstLayout() throws {
        try withRig { rig in
            XCTAssertTrue(rig.draft.pages.showLibrary())
            var known = Set<ObjectIdentifier>()
            rig.room.set(height: cardHeight, open: true)
            settle(rig.host)

            rig.state.prepareBuiltPage(PanelPage(.notes))
            let library = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "the Notes library's scroll view")
            let libraryFirst = library.contentInsets.bottom
            rig.state.prepareBuiltPage(PanelPage(.calendar))
            let grid = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "Calendar's grid scroll view")
            let gridFirst = grid.contentInsets.bottom
            settle(rig.host)

            rig.state.selectSection(.notes)
            rig.host.layoutSubtreeIfNeeded()
            let libraryAtSwitch = library.contentInsets.bottom
            let roomAtSwitch = rig.room.height

            rig.room.set(height: 0, open: false)
            settle(rig.host, times: 2)
            let libraryClosed = library.contentInsets.bottom
            let gridClosed = grid.contentInsets.bottom
            XCTAssertEqual(libraryFirst - libraryClosed, extra, accuracy: 1, "the library's first layout had the card's room")
            XCTAssertEqual(gridFirst - gridClosed, extra, accuracy: 1, "the grid's first layout had the card's room")
            assertShownMargin(libraryAtSwitch - libraryClosed, roomAtRead: roomAtSwitch, "the library")
        }
    }

    // MARK: Height change while shown

    /// With Notes' library or Calendar's grid shown and the card open, the
    /// card grows: the margin follows in the same layout, and a list resting
    /// at its end stays at its end.
    func testTheShownMarginFollowsTheCardsHeightAndTheEndStaysAtTheEnd() throws {
        try withRig { rig in
            XCTAssertTrue(rig.draft.pages.showLibrary())
            var known = Set<ObjectIdentifier>()
            for section in [PanelSection.notes, .calendar] {
                rig.state.selectSection(section)
                let scroll = try XCTUnwrap(firstLaidOut(in: rig.host, besides: &known), "\(section)'s scroll view")
                settle(rig.host, times: 4)
                let closed = scroll.contentInsets.bottom
                rig.room.set(height: 90, open: true)
                settle(rig.host)
                for _ in 0..<2 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    settle(rig.host)
                }

                rig.room.set(height: cardHeight, open: true)
                rig.host.layoutSubtreeIfNeeded() // the same update: no run-loop turn
                XCTAssertEqual(scroll.contentInsets.bottom - closed, extra, accuracy: 1,
                               "\(section): the margin follows the card's height")
                settle(rig.host, times: 2) // the end follower moves after the new inset
                XCTAssertEqual(scroll.contentView.bounds.origin.y,
                               TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll), accuracy: 1,
                               "\(section): a list at its end stays at its end")

                rig.room.set(height: 0, open: false)
                settle(rig.host, times: 2)
                XCTAssertEqual(scroll.contentInsets.bottom, closed, accuracy: 1, "\(section): closed, the margin is the base")
            }
        }
    }

    // MARK: The open note

    /// With a note open and the card open, the editor's own scroll insets
    /// include the room, as before.
    func testAnOpenNotesEditorInsetsIncludeTheCardsRoom() throws {
        try withRig { rig in
            rig.state.selectSection(.notes)
            settle(rig.host, times: 2)
            let id = try XCTUnwrap(rig.noteIDs.first)
            if rig.draft.pages.isLibraryPresented { rig.draft.pages.dismissLibrary() }
            XCTAssertTrue(rig.draft.pages.open(noteID: id), "the note opens")
            settle(rig.host, times: 3)
            let editor = try XCTUnwrap(rig.draft.pages.active?.engine.scrollView, "the open note's scroll view")
            let resting = editor.contentInsets.bottom

            rig.room.set(height: cardHeight, open: true)
            settle(rig.host)
            XCTAssertEqual(editor.contentInsets.bottom - resting, extra, accuracy: 1, "the editor makes room for the card")
            rig.room.set(height: 0, open: false)
            settle(rig.host)
            XCTAssertEqual(editor.contentInsets.bottom, resting, accuracy: 1)
        }
    }

    /// On the first layout after a switch, the card closing with the switch
    /// may not have reached the margin yet: with the room still open the
    /// shown margin has it; once the room has folded, either the open or
    /// the closed margin, never anything else. This branch alone does not
    /// prove the room was there on the first frame; the hidden reads do.
    private func assertShownMargin(_ added: CGFloat, roomAtRead: CGFloat, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        if abs(roomAtRead - cardHeight) < 0.5 {
            XCTAssertEqual(added, extra, accuracy: 1, "\(what)'s first shown margin has the open card's room", file: file, line: line)
        } else {
            XCTAssertTrue(abs(added - extra) <= 1 || abs(added) <= 1,
                          "\(what)'s first shown margin is the open or the closed one, not \(added)", file: file, line: line)
        }
    }

    // MARK: Rig

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func settle(_ host: NSView, times: Int = 1) {
        for _ in 0..<times { spin(0.3); host.layoutSubtreeIfNeeded() }
    }

    /// Every scroll view that holds the card's end keeper (Notes' library,
    /// Calendar's grid and day), in hierarchy order.
    private func roomScrolls(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if view is PanelComposerScrollKeeper.Keeper, let scroll = view.enclosingScrollView,
               !found.contains(where: { $0 === scroll }) {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The first such scroll view not seen before, on the first layout it
    /// is in. A layout with no run-loop turn first; only if the page's
    /// views are not there yet, single short turns until they are.
    private func firstLaidOut(in host: NSView, besides known: inout Set<ObjectIdentifier>) -> NSScrollView? {
        for attempt in 0..<40 {
            if attempt > 0 { spin(0.01) }
            host.layoutSubtreeIfNeeded()
            let all = roomScrolls(in: host)
            if let new = all.first(where: { !known.contains(ObjectIdentifier($0)) }) {
                known.formUnion(all.map(ObjectIdentifier.init))
                return new
            }
        }
        return nil
    }

    private func withRig(_ body: (Rig) throws -> Void) throws {
        let suite = "PanelComposerScrollRoom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit([TaskDraft(title: "Write launch notes"), TaskDraft(title: "Return books")])
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        // Enough notes that the library scrolls.
        var noteIDs: [UUID] = []
        for index in 0..<30 {
            let id = UUID()
            _ = try notes.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Note \(index) of the room check")]),
                                             tags: []).get()
            noteIDs.append(id)
        }
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let composerState = PanelComposerState()
        let calendarState = CalendarPageState()
        let draft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: AppSettings(defaults: defaults), tasksPageState: TasksPageState(),
                                     calendarPageState: calendarState, composerState: composerState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        // Off screen, never key: the invisible unit host keeps the keyboard.
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        state.panelDidReveal()
        panel.orderFront(nil)
        defer {
            state.panelDidHide()
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        if state.selectedSection != .tasks { state.selectSection(.tasks) }
        settle(host, times: 3)
        try body(Rig(host: host, state: state, room: composerState.room, store: store, draft: draft,
                     calendarState: calendarState, noteIDs: noteIDs))
    }
}
