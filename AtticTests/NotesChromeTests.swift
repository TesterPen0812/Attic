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
    /// CI regression (run 43198094521): the Notes UI tests still asked for
    /// `notes-library-search-button` and `notes-library-tag-<tag>`, which the
    /// shared top row and bottom bar replaced, so they waited five seconds
    /// for nothing. Every id the Notes UI tests look up must still be one the
    /// product spells (a literal, a literal stem ending in "-", or the tag
    /// bar's `notes-tag-bar-<tag>`).
    func testNotesUITestsOnlyAskForIdentifiersTheProductSpells() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        let ui = text(root.appendingPathComponent("AtticUITests/NotesPageUITests.swift"))
        try XCTSkipIf(ui.isEmpty, "sources are not beside the tests")
        let literal = try NSRegularExpression(pattern: #""([a-z][a-z0-9-]*)(?=["\\])"#)
        var stems = Set<String>()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Attic"), includingPropertiesForKeys: nil)
        for case let url as URL in files ?? NSEnumerator() where url.pathExtension == "swift" {
            let source = text(url)
            for match in literal.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                stems.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        let lookups = try NSRegularExpression(pattern: #"\["([a-z][a-z0-9-]+)"\]"#)
        let asked = Set(lookups.matches(in: ui, range: NSRange(ui.startIndex..., in: ui)).map {
            String(ui[Range($0.range(at: 1), in: ui)!])
        })
        XCTAssertGreaterThan(asked.count, 5, "the scan found the UI test's lookups")
        let missing = asked.filter { id in
            !(stems.contains(id) || id.hasPrefix("notes-tag-bar-") || stems.contains { $0.hasSuffix("-") && id.hasPrefix($0) })
        }
        XCTAssertEqual(missing.sorted(), [], "UI-test identifiers the product no longer spells")
    }

    func testBA5BlankUntouchedDraftMakesNoCreationSoundForCommandN() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil)
        controller.start()
        let firstSession = try XCTUnwrap(controller.active)
        XCTAssertTrue(firstSession.isUntouchedDraft)
        let firstID = firstSession.noteID
        var played: [AtticSounds.Cue] = []
        let sounds = AtticSounds.shared
        sounds.lastPlayed = -.infinity
        sounds.settingEnabled = { true }
        sounds.systemAllows = { true }
        sounds.clock = { 20_000 }
        sounds.output = { played.append($0) }
        defer {
            sounds.output = nil
            sounds.settingEnabled = nil
            sounds.systemAllows = { true }
            sounds.clock = { ProcessInfo.processInfo.systemUptime }
            sounds.lastPlayed = -.infinity
        }
        XCTAssertTrue(NotesEditorPage.requestNewNoteAndPlayCue(controller))
        XCTAssertEqual(controller.active?.noteID, firstID, "Command-N reuses the untouched draft")
        XCTAssertTrue(played.isEmpty, "no session or note was created")
        XCTAssertTrue(controller.requestNewNote(title: "A note", tags: []))
        let writtenID = try XCTUnwrap(controller.active?.noteID)
        XCTAssertTrue(NotesEditorPage.requestNewNoteAndPlayCue(controller))
        XCTAssertNotEqual(controller.active?.noteID, writtenID, "Command-N starts a fresh draft after writing")
        XCTAssertEqual(played, [.created], "a real new session keeps the creation cue")
    }
    // MARK: Geometry

    /// Accepted 2026-10-30 ("Top row and bottom bar"): Search far right,
    /// ••• a gap before it, the page's own switch a gap before that.
    func testTheTopRowPutsSearchFarRightThenMoreThenTheSwitch() {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let chrome = layout.chromeInsets
        let button = PanelTopRowLayout.searchButtonFrame(layout)
        XCTAssertEqual(button.size, CGSize(width: 27, height: 27))
        XCTAssertEqual(button.minY, chrome.top)
        XCTAssertEqual(button.maxX, 340 - chrome.trailing, accuracy: 0.001)
        let more = PanelTopRowLayout.moreButtonFrame(layout)
        XCTAssertEqual(more.maxX, button.minX - PanelTopRowLayout.gap, accuracy: 0.001)
        let pageSwitch = PanelTopRowLayout.switchFrame(layout, width: 60)
        XCTAssertEqual(pageSwitch.maxX, more.minX - PanelTopRowLayout.switchGap, accuracy: 0.001)
        XCTAssertEqual(PanelTopRowLayout.leading(layout), chrome.leading + 27 + PanelTopRowLayout.leadingGap, accuracy: 0.001)
        let field = PanelTopRowLayout.fieldFrame(layout)
        XCTAssertEqual(field.minX, chrome.leading, accuracy: 0.001)
        XCTAssertEqual(340 - field.maxX, chrome.trailing, accuracy: 0.001, "the open field: equal room both sides")
    }

    func testTheBarsTakeTheTasksFooterMeasures() {
        XCTAssertEqual(NotesBarMetrics.control, 27, "one size: 27 pt (Accepted 2026-10-30)")
        XCTAssertEqual(NotesBarMetrics.radius, 13.5, "a capsule")
        XCTAssertEqual(NotesBarMetrics.gap, 5, "10 px")
        XCTAssertEqual(NotesBarMetrics.pillHeight, 21, "21 pt tags")
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

    func testOpenNoteComposerHidesBackAndPlusFromAccessibility() throws {
        try withPanel { host, state, _, _, draft, _ in
            state.selectSection(.notes)
            spin(1)
            draft.pages.dismissLibrary()
            spin(1)
            let back = try XCTUnwrap(element("notes-all-notes", in: host), "Back before composer")
            // Owner, 13 Nov: the gallery's icon (Notes' own symbol), same name.
            XCTAssertEqual(back.accessibilityLabel?() ?? nil, "All notes")
            XCTAssertEqual(NotesBarMetrics.allNotesSymbol, PanelPage.notes.systemName)
            XCTAssertNotEqual(NotesBarMetrics.allNotesSymbol, "chevron.left", "not a back arrow")
            XCTAssertNotNil(NSImage(systemSymbolName: NotesBarMetrics.allNotesSymbol, accessibilityDescription: nil))
            let plus = try XCTUnwrap(element("notes-new-note", in: host), "+ before composer")
            XCTAssertTrue(plus.accessibilityPerformPress?() ?? false, "open the real composer")
            spin(1)
            XCTAssertNotNil(element("composer-title", in: host), "the composer is actually open")
            XCTAssertNil(element("notes-all-notes", in: host), "Back must leave AX with its folded row")
            XCTAssertNil(element("notes-new-note", in: host), "+ must leave AX with its folded row")
            _ = back.accessibilityPerformPress?() // A stale AX reference must not navigate behind the card.
            spin(0.2)
            XCTAssertNotNil(element("composer-title", in: host), "stale Back cannot dismiss the composer")
        }
    }

    func testCatchupR4OpenNotePlusDoesNotInheritHiddenLibraryTags() throws {
        try withPanel { host, state, tasksState, store, draft, library in
            state.selectSection(.notes)
            spin(1)
            try XCTUnwrap(library()).tagPicks = TagPicks(["launch"])
            draft.pages.dismissLibrary()
            spin(1)
            XCTAssertFalse(draft.pages.isLibraryPresented)
            let plus = try XCTUnwrap(element("notes-new-note", in: host))
            XCTAssertTrue(plus.accessibilityPerformPress?() ?? false)
            spin(1)
            XCTAssertNotNil(element("composer-title", in: host))
            XCTAssertTrue(tasksState.model(for: store, toasts: nil).addBar.picked.tags.isEmpty,
                          "The open note's + has no library filter to inherit")
        }
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
            // Only as wide as its tags (the user's addition to T6, Accepted
            // 2026-11-01): it never reaches past the gap before "+".
            XCTAssertGreaterThanOrEqual(compose.minX - tagBar.maxX, NotesBarMetrics.gap - 0.5, "at least 10 px apart")
            XCTAssertEqual(tagBar.minX, layout.chromeInsets.leading, accuracy: 0.5, "against the panel's left")
            XCTAssertEqual(compose.maxX, host.bounds.width - layout.chromeInsets.trailing, accuracy: 0.5, "compose on the right")
            XCTAssertNil(element("notes-all-notes", in: host), "no Back while All notes shows")
            XCTAssertNil(element("notes-format-button", in: host))

            // Choosing a tag filters the list.
            let model2 = try XCTUnwrap(library(), "the library model")
            // Collapsed by default (Accepted 2026-11-13): "#" opens the bar.
            XCTAssertTrue(try XCTUnwrap(element("notes-tag-bar-key", in: host)).accessibilityPerformPress?() ?? false)
            spin(0.3)
            let books = try XCTUnwrap(element("notes-tag-bar-books", in: host), "the #books pill")
            XCTAssertTrue(books.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertEqual(model2.tagPicks, TagPicks(["books"]))
            let all = try XCTUnwrap(element("notes-tag-bar-all", in: host))
            XCTAssertTrue(all.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertTrue(model2.tagPicks.isEmpty, "All shows every note")

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
