import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Accepted 2026-11-01 "Adaptive picks", the Tasks items: T2 (the selection
/// bar takes the tag bar's place), T3 (Find counts the other tabs' matches),
/// T6 (Done keeps the tag bar; the bar hides only while no tags exist) and
/// the user's addition to T6 (the tag bar is only as wide as its tags).
/// Reduce Motion and Reduce Transparency are stated (CI turns both on).
@MainActor
final class AdaptiveTasksTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    /// Accepted 2026-11-05, "Compact tab switch": a tab showing only its
    /// icon keeps its name for VoiceOver and the tooltip.
    func testEveryTabKeepsItsNameOutOfSight() throws {
        try withPanel(seed: []) { host, _, _, _, _ in
            for tab in TasksTab.allCases {
                let cell = try XCTUnwrap(element("tasks-page-\(tab.identifier)", in: host))
                XCTAssertEqual(cell.accessibilityLabel?(), tab.title)
                XCTAssertEqual(cell.accessibilityHelp?(), tab.title)
            }
        }
    }

    // MARK: T2

    func testTheSelectionBarTakesTheTagBarsPlaceAndGivesItBackWithItsFilter() throws {
        try withPanel(seed: [TaskDraft(title: "Review the launch checklist", tags: ["launch"]),
                             TaskDraft(title: "Write the launch post", tags: ["launch"]),
                             TaskDraft(title: "Send the invite list", tags: ["launch"]),
                             TaskDraft(title: "Return books", tags: ["books"])]) { host, _, tasksState, store, _ in
            let model = tasksState.model(for: store, toasts: nil)
            model.chooseTagChip("launch")
            spin(0.4)
            let bar = try XCTUnwrap(frame(of: "tasks-tag-bar", in: host), "the tag bar")
            let plus = try XCTUnwrap(frame(of: "tasks-new-task", in: host))

            model.selectCopies(model.rows(for: .now).prefix(3).map(\.id))
            spin(0.5)
            XCTAssertNil(element("tasks-tag-bar", in: host), "the tag bar gives up its place")
            let selection = try XCTUnwrap(frame(of: "tasks-selection-bar", in: host), "the selection bar")
            XCTAssertEqual(selection.minX, bar.minX, accuracy: 0.5, "in the tag bar's place")
            XCTAssertEqual(selection.midY, bar.midY, accuracy: 0.5, "on the bottom bar's line, not stacked over it")
            XCTAssertEqual(selection.height, AtticControlSize.headerControl, accuracy: 0.5)
            XCTAssertLessThan(selection.maxX, plus.minX, "as wide as its content, before \"+\"")
            XCTAssertEqual(try XCTUnwrap(frame(of: "tasks-new-task", in: host)), plus, "\"+\" stays")
            let words = elements(host).compactMap { element -> String? in
                if let object = element as? NSAccessibilityElement, let value = object.accessibilityValue() as? String, !value.isEmpty { return value }
                if let view = element as? NSView, let value = view.accessibilityValue() as? String, !value.isEmpty { return value }
                return element.accessibilityLabel?() ?? nil
            }
            XCTAssertTrue(words.contains("3 selected · #launch"), "the filter stays in sight: \(words.filter { $0.contains("selected") })")

            model.clearSelection()
            spin(0.5)
            XCTAssertNil(element("tasks-selection-bar", in: host))
            XCTAssertEqual(try XCTUnwrap(frame(of: "tasks-tag-bar", in: host)), bar, "the tag bar is back as it was")
            XCTAssertEqual(model.tagPicks(on: .now), TagPicks(["launch"]), "with its filter")
            XCTAssertNotNil(element("tasks-tag-bar-picked", in: host), "collapsed, the bar shows the picked tag (1A)")
        }
    }

    // MARK: T3

    func testFindCountsTheOtherTabsMatchesAndEachLinkKeepsTheQuery() throws {
        let (store, model) = try makeModel()
        _ = store.commit([TaskDraft(title: "Launch checklist", tags: ["launch"]), TaskDraft(title: "Water plants")])
        _ = store.commit([TaskDraft(title: "Launch walkthrough", status: .backlog),
                          TaskDraft(title: "Launch stickers", status: .backlog)])
        for title in ["Launch date", "Launch blog post", "Launch photos", "Boiler service"] {
            let task = try XCTUnwrap(store.create(title: title))
            XCTAssertTrue(model.library.completeTask(task.id).isApplied)
        }
        _ = store.moveCompletedToDoneLog(before: Date().addingTimeInterval(2 * 86_400))
        model.setSearchQuery("launch", for: .now)
        XCTAssertEqual(model.searchMatchesElsewhere(from: .now),
                       [TasksElsewhereCount(tab: .backlog, count: 2), TasksElsewhereCount(tab: .done, count: 3)])
        model.setSearchQuery("water", for: .now)
        XCTAssertEqual(model.searchMatchesElsewhere(from: .now), [], "a tab with no matches is left out")
        model.setSearchQuery("launch", for: .now)

        model.followSearch(from: .now, to: .done)
        XCTAssertEqual(model.tab, .done)
        XCTAssertEqual(model.trimmedQuery(for: .done), "launch", "the query is kept")
        XCTAssertEqual(model.searchMatchesElsewhere(from: .done),
                       [TasksElsewhereCount(tab: .now, count: 1), TasksElsewhereCount(tab: .backlog, count: 2)])
        model.followSearch(from: .done, to: .backlog)
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(model.trimmedQuery(for: .backlog), "launch")
        XCTAssertEqual(model.rows(for: .backlog).count, 2)
    }

    func testFindsCountLineDrawsTheLinks() throws {
        try withPanel(seed: [TaskDraft(title: "Launch checklist"), TaskDraft(title: "Launch walkthrough", status: .backlog)]) { host, _, tasksState, store, _ in
            let model = tasksState.model(for: store, toasts: nil)
            model.setSearchQuery("launch", for: .now)
            spin(0.5)
            XCTAssertNotNil(element("tasks-find-count", in: host), "Find's count")
            let later = try XCTUnwrap(element("tasks-find-count-backlog", in: host), "· 1 in Later")
            XCTAssertNil(element("tasks-find-count-done", in: host), "no part for Done's 0")
            XCTAssertTrue(later.accessibilityPerformPress?() ?? false)
            spin(0.5)
            XCTAssertEqual(model.tab, .backlog)
            XCTAssertEqual(model.trimmedQuery(for: .backlog), "launch")
        }
    }

    /// T3 with no results on the current tab (Accepted, not drawn): the
    /// line reads "No results · 2 in Later · 1 in Done", each part a link
    /// to that tab that keeps the query, as the count line's links; a tab
    /// with no matches is left out; no matches anywhere is just "No results".
    func testNoResultsShowsTheOtherTabsMatchesAsLinks() throws {
        try withPanel(seed: [TaskDraft(title: "Water plants"),
                             TaskDraft(title: "Launch walkthrough", status: .backlog),
                             TaskDraft(title: "Launch stickers", status: .backlog)]) { host, _, tasksState, store, _ in
            let model = tasksState.model(for: store, toasts: nil)
            model.setSearchQuery("launch", for: .now)
            spin(0.5)
            XCTAssertNotNil(element("tasks-empty-line", in: host), "No results on Now")
            XCTAssertNil(element("tasks-find-count", in: host), "no count line: Now has no matches")
            let later = try XCTUnwrap(element("tasks-find-count-backlog", in: host), "· 2 in Later on the No results line")
            XCTAssertEqual(later.accessibilityLabel?(), "2 in Backlog")
            XCTAssertNil(element("tasks-find-count-done", in: host), "no part for Done's 0")
            XCTAssertTrue(later.accessibilityPerformPress?() ?? false)
            spin(0.5)
            XCTAssertEqual(model.tab, .backlog)
            XCTAssertEqual(model.trimmedQuery(for: .backlog), "launch", "the query is kept")

            // Done with no results: its line links to Now's match.
            model.setSearchQuery("water", for: .done)
            model.select(tab: .done)
            spin(0.5)
            XCTAssertNotNil(element("tasks-empty-line", in: host), "No results on Done")
            let now = try XCTUnwrap(element("tasks-find-count-now", in: host), "· 1 in Now on Done's No results line")
            XCTAssertEqual(now.accessibilityLabel?(), "1 in Now")
            XCTAssertNil(element("tasks-find-count-backlog", in: host))

            // No matches anywhere: just "No results".
            model.setSearchQuery("zebra", for: .done)
            spin(0.5)
            XCTAssertNotNil(element("tasks-empty-line", in: host))
            for tab in ["now", "later", "done"] { XCTAssertNil(element("tasks-find-count-\(tab)", in: host), "no \(tab) part") }
        }
    }

    /// Now's Find counts Done's matches through the Done log's index, so
    /// Now's first key still shows at once on 5,000 finished tasks: the
    /// count's median stays in Done's own 16 ms query budget.
    func testTheDoneCountFromNowsFindFitsTheQueryBudget() throws {
        var byQuery: [String: [Double]] = [:]
        for _ in 0..<3 {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            try TasksPagePreview.seedScale(in: container)
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            _ = model.rows(for: .now)
            for query in ["F", "Fi", "Finished", "task 12", "no match"] {
                let start = DispatchTime.now().uptimeNanoseconds
                model.setSearchQuery(query, for: .now)
                _ = model.searchMatchesElsewhere(from: .now)
                byQuery[query, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        DoneSearchCostTests.assertMediansFitTheBudget(byQuery, "now-find-elsewhere")
    }

    // MARK: T6

    func testDoneKeepsTheTagBarAndItsTagsFilterTheDoneLog() throws {
        let (store, model) = try makeModel()
        for (title, tags) in [("Launch date", ["launch"]), ("Boiler service", ["house"]), ("Launch post", ["launch"]),
                              ("Stickers", ["archive"])] {
            let task = try XCTUnwrap(store.commit([TaskDraft(title: title, tags: tags)])?.first)
            XCTAssertTrue(model.library.completeTask(task.id).isApplied)
        }
        _ = store.moveCompletedToDoneLog(before: Date().addingTimeInterval(2 * 86_400))
        XCTAssertTrue(model.tagChips().contains("archive"), "a tag only Done has is a chip")
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap(\.rows).count, 4)
        model.chooseTagChip("launch")
        XCTAssertEqual(model.tagPicks(on: .done), TagPicks(["launch"]), "Done has no exception")
        model.loadDoneLogIfNeeded()
        let titles = Set(model.doneDays().flatMap(\.rows).map(\.model.title))
        XCTAssertEqual(titles, ["Launch date", "Launch post"], "the paged Done log is filtered")
        XCTAssertEqual(store.indexedDoneLogCount(tags: TagPicks(["launch"])), 2)
        model.doneSearch = "post"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap(\.rows).map(\.model.title), ["Launch post"], "with the search")
        XCTAssertEqual(model.doneSearchCount()?.matches, 1)
        XCTAssertEqual(model.doneSearchCount()?.total, 2, "of the tag's finished tasks")
    }

    func testTheTagBarHidesOnlyWhileNoTagsExist() throws {
        try withPanel(seed: [TaskDraft(title: "Water plants"), TaskDraft(title: "Call the dentist")]) { host, state, tasksState, store, _ in
            XCTAssertNil(element("tasks-tag-bar", in: host), "no tags: no bar")
            XCTAssertNotNil(element("tasks-new-task", in: host), "\"+\" stands alone")
            let model = tasksState.model(for: store, toasts: nil)
            model.select(tab: .done)
            spin(0.5)
            XCTAssertNil(element("tasks-tag-bar", in: host))
            model.select(tab: .now)
            _ = store.commit([TaskDraft(title: "Venue shortlist", tags: ["team"])])
            spin(0.6)
            let bar = try XCTUnwrap(frame(of: "tasks-tag-bar", in: host), "the first tag brings the bar")
            XCTAssertEqual(bar.minX, PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size).chromeInsets.leading, accuracy: 0.5,
                           "from the left")
            model.select(tab: .done)
            spin(0.5)
            XCTAssertNotNil(element("tasks-tag-bar", in: host), "Done keeps it")
            _ = state
        }
    }

    // MARK: The user's addition to T6: the bar's width

    func testTheTagBarIsOnlyAsWideAsItsTags() throws {
        XCTAssertEqual(PanelTagBarWidth.width(ideal: 120, room: 260, collapsed: false), 120)
        XCTAssertEqual(PanelTagBarWidth.width(ideal: 400, room: 260, collapsed: false), 260, "stops at the room before \"+\"")
        XCTAssertEqual(PanelTagBarWidth.width(ideal: 120, room: 260, collapsed: true), 0)

        try withPanel(seed: [TaskDraft(title: "One", tags: ["launch"])]) { host, state, tasksState, store, draft in
            let insets = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size).chromeInsets
            // The bar starts collapsed as "#" (Accepted 2026-11-13, 1A); its
            // width is measured open.
            XCTAssertTrue(try XCTUnwrap(element("tasks-tag-bar-key", in: host)).accessibilityPerformPress?() ?? false)
            spin(0.6)
            let one = try XCTUnwrap(frame(of: "tasks-tag-bar", in: host))
            let plus = try XCTUnwrap(frame(of: "tasks-new-task", in: host))
            XCTAssertEqual(one.minX, insets.leading, accuracy: 0.5)
            let key = try XCTUnwrap(frame(of: "tasks-tag-bar-key", in: host))
            XCTAssertLessThan(one.width - key.width, 100, "All and #launch after the open \"#\": a short bar")
            _ = store.commit([TaskDraft(title: "Two", tags: ["team"])])
            spin(0.6)
            let two = try XCTUnwrap(frame(of: "tasks-tag-bar", in: host))
            XCTAssertEqual(two.minX, one.minX, accuracy: 0.5, "it grows to the right")
            XCTAssertGreaterThan(two.width, one.width + 20)
            XCTAssertLessThan(two.maxX, plus.minX - 40, "two tags make a short bar, not a full-width one")
            _ = store.commit((0..<14).map { TaskDraft(title: "Many \($0)", tags: ["longertag\($0)"]) })
            spin(0.6)
            let many = try XCTUnwrap(frame(of: "tasks-tag-bar", in: host))
            XCTAssertEqual(many.minX, one.minX, accuracy: 0.5)
            XCTAssertEqual(many.maxX, plus.minX - TasksDesignMetrics.footerGap, accuracy: 0.5, "stops at the room before \"+\"")

            // A tab switch keeps the left edge; a page switch too.
            let model = tasksState.model(for: store, toasts: nil)
            model.select(tab: .done)
            spin(0.6)
            XCTAssertEqual(try XCTUnwrap(frame(of: "tasks-tag-bar", in: host)).minX, one.minX, accuracy: 0.5, "Done: the left edge stays")
            state.switchPage(to: .notes, motion: .instant)
            spin(0.8)
            _ = draft.pages.showLibrary()
            spin(0.8)
            if element("notes-tag-bar-all", in: host) == nil {
                XCTAssertTrue(try XCTUnwrap(element("notes-tag-bar-key", in: host)).accessibilityPerformPress?() ?? false)
                spin(0.6)
            }
            let notes = try XCTUnwrap(frame(of: "notes-tag-bar", in: host), "Notes has the same bar")
            XCTAssertEqual(notes.minX, one.minX, accuracy: 0.5, "the page switch keeps the left edge")
            XCTAssertLessThan(notes.width, many.width, "only the width changes")
        }
    }

    // MARK: Hosting

    private func makeModel() throws -> (TaskStore, TasksPageModel) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        return (store, TasksPageModel(library: AtticLibrary(tasks: store)))
    }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func withPanel(seed: [TaskDraft], _ body: (_ host: AtticPanelHostingView, _ state: PanelUIState,
                                                        _ tasks: TasksPageState, _ store: TaskStore,
                                                        _ draft: NoteDraftController) throws -> Void) throws {
        let suite = "AdaptiveTasks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit(seed)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let draft = NoteDraftController(noteStore: notes)
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
        state.selectSection(.tasks)
        spin(1.0)
        try body(host, state, tasksState, store, draft)
    }

    private func frame(of identifier: String, in host: AtticPanelHostingView) -> CGRect? {
        host.layoutSubtreeIfNeeded()
        guard let element = element(identifier, in: host), let screen = element.accessibilityFrame?(),
              let window = host.window, screen.width > 0 else { return nil }
        let local = host.convert(window.convertFromScreen(screen), from: nil)
        return host.isFlipped ? local : CGRect(x: local.minX, y: host.bounds.height - local.maxY,
                                               width: local.width, height: local.height)
    }

    private func element(_ identifier: String, in host: AtticPanelHostingView) -> AnyObject? {
        elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
    }
}
