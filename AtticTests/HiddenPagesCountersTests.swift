import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The hidden pages' counts per Tasks control (ops/design/hidden-pages.md,
/// "Design text: the hidden pages' publishers, mechanisms 2 and 3", the
/// lead's verdict and "GPT Pro's answer, and a gap in the test panel").
///
/// The real `AtticPanelView` in an offscreen `AtticPanel` (never on a
/// display, never key). All four pages are built, Tasks is current, and
/// Notes rests on its library. A small seed: open tasks that own no note,
/// tasks that each own a note, and notes owned by no task.
///
/// Wired as `AppCoordinator` wires the panel: one `CanvasStore` shared by
/// `AtticLibrary` and the `CanvasSession`; the Notes controller on the
/// library's one Undo route (`attachUndoRoute(library.undo)`), with
/// `workspaceTaskStore` set and `didFollowNoteLink` selecting Notes; the
/// workspace lifecycle hooks (journal directory, launch registration and
/// `finishLaunch`) on a file store in an owned temporary folder.
///
/// Not reproduced from `AppCoordinator`: the draft controller's session
/// defaults and recovery URL (the app passes no session defaults under
/// tests either); the agent wiring (`AgentTaskTools`, the note writer, the
/// agent watcher); the shared toast centre, calendar event sources and
/// Tasks page memory; and `DrawPageModel.install` (the app skips it in the
/// unit host too, so Draw runs on its in-memory `DrawPageModel.shared`).
///
/// Counted (deltas around each control, every line prefixed
/// `HIDDEN_COUNTS`): the DEBUG `bodyEvaluations` of the counted views, the
/// `PanelComposerClearance` content-closure calls per page (observed and
/// `content(0)` paths apart), `PanelComposerRoom.$height` publishes, the
/// Notes controller's and draft controller's publishes and its
/// `$undoRevision`, every `NoteStore` publisher, its total
/// `objectWillChange` and the tag-inventory notice apart (the rest is
/// printed as bare sends), and `NotesLibraryModel`'s total
/// `objectWillChange` with its task sink's own branches apart.
///
/// Each control is followed by the same fixed pump (`pumpSeconds` of run
/// loop, layout and display) before its counts are read.
///
/// Only the harness is asserted: each control happened, the panel is wired
/// as stated, and the counters are live. No count's value is asserted;
/// those assertions arrive with the fixes that own them.
@MainActor
final class HiddenPagesCountersTests: XCTestCase {
    private static let pumpSeconds: TimeInterval = 0.6
    private static let menuTag = "errand"

    private struct Seed {
        var plain: [UUID] = []        // open tasks that own no note
        var owners: [UUID] = []       // open tasks that each own a note
        var ownedNotes: [UUID] = []
        var freeNotes: [UUID] = []
    }

    private final class LibraryBox { weak var model: NotesLibraryModel? }

    private struct Rig {
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary
        let draft: NoteDraftController
        let state: PanelUIState
        let composerState: PanelComposerState
        let content: NSView
        let panel: AtticPanel
        let page: TasksPageModel
        let composer: ComposerModel
        let notesLibrary: NotesLibraryModel
        let libraryBox: LibraryBox
        let seed: Seed
        let tally: Tally
        let calendarState: CalendarPageState
        let tasksState: TasksPageState
        /// The scroll views Notes' library holds (the card's end keeper's),
        /// taken before any other page was built.
        let notesScrolls: Set<ObjectIdentifier>
        /// The Calendar page's model (the panel built it behind Tasks).
        @MainActor var calendarModel: CalendarPageModel {
            calendarState.model(store: tasks, resumeDefaults: state.resumeDefaults, owner: .docked)
        }
    }

    /// Subscription counts; read with the static counters into one snapshot.
    private final class Tally {
        var counts: [String: Int] = [:]
        var bag: Set<AnyCancellable> = []
        func count<P: Publisher>(_ key: String, _ publisher: P) where P.Failure == Never {
            counts[key] = 0
            publisher.sink { [weak self] _ in self?.counts[key, default: 0] += 1 }.store(in: &bag)
        }
    }

    private static let storePublishers = ["store.$notes", "store.$revision", "store.$lastErrorMessage",
                                          "store.$cloudSyncStatus", "store.$attachmentsByNoteID",
                                          "store.$attachmentFailures", "store.$attachmentRetryVersions"]

    /// The shell's body runs (`PanelInvalidationProbe.shell`), counted while a rig is up.
    private static var shellRuns = 0

    /// Column order of every printed line.
    private static let columns = [
        "shell", "panelLayouts", "keptLayouts", "route.tasks", "route.notes", "route.calendar",
        "NotesPageHost", "NotesEditorPage", "NotesLibraryView",
        "CalendarPageHost", "CalendarPage", "CalendarDayView", "dayTimeline",
        "DrawPageHost", "CanvasPageHost", "PanelCanvasNoticeAwareHost",
        "clear.notesPage", "clear.notesLeaf", "clear.calendarGrid", "clear.calendarDay", "clear.unnamed",
        "clear0.notesPage", "clear0.notesLeaf", "clear0.calendarGrid", "clear0.calendarDay", "clear0.unnamed",
        "room.$height", "room.$isOpen",
        "notesCtl.willChange", "notesCtl.$undoRevision", "draft.willChange",
        "store.total", "store.inventoryNotice", "store.bare",
    ] + HiddenPagesCountersTests.storePublishers + [
        "libModel.total", "libModel.sinkSends", "libModel.sinkSkippedDisjoint", "libModel.sinkUnchanged",
    ]

    // MARK: - Rig

    private final class Box<T> { var value: T? }
    /// The async call's result, or nil if it did not finish in 20 s.
    private func wait<T>(_ operation: @escaping @MainActor () async -> T) -> T? {
        let box = Box<T>()
        Task { @MainActor in box.value = await operation() }
        let deadline = Date().addingTimeInterval(20)
        while box.value == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        return box.value
    }

    private func pump(_ content: NSView, _ panel: NSWindow, seconds: TimeInterval = HiddenPagesCountersTests.pumpSeconds) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.016)))
            content.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
        } while Date() < end
    }

    private func seedTasks(in container: ModelContainer, seed: inout Seed) throws {
        let context = ModelContext(container)
        let now = Date()
        func insert(_ title: String, tags: [String], index: Int) -> UUID {
            let item = TaskItem(title: title, status: .todo, priority: .none,
                                createdAt: now.addingTimeInterval(Double(-index * 60)),
                                manualOrder: 1_000_000 + Int64(index) * 1_024, parentID: nil)
            item.tags = tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
            return item.id
        }
        for index in 0..<6 {
            seed.plain.append(insert("Plain task \(index + 1)", tags: index.isMultiple(of: 2) ? ["home"] : [], index: index))
        }
        for index in 0..<2 {
            seed.owners.append(insert("Task with a note \(index + 1)", tags: ["work"], index: 6 + index))
        }
        try context.save()
    }

    private func seedNotes(_ notes: NoteStore, seed: inout Seed) throws {
        func create(_ title: String, owner: UUID?) throws -> UUID {
            let id = UUID()
            let document = try NoteAgentTextParser.document(title: title, body: "A line for \(title).", base: .blank)
            if case let .failure(error) = notes.createDocumentNote(id: id, document: document, taskOwner: owner) {
                throw NSError(domain: "HiddenPagesCountersTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "note \(title): \(error)"])
            }
            return id
        }
        for (index, owner) in seed.owners.enumerated() {
            seed.ownedNotes.append(try create("Owned note \(index + 1)", owner: owner))
        }
        for index in 0..<2 {
            seed.freeNotes.append(try create("Free note \(index + 1)", owner: nil))
        }
    }

    private func withRig(_ body: (Rig) throws -> Void) throws {
        let root = ownedTemporaryDirectory(prefix: "HiddenPagesCounters")
        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                storeDirectory: storeDirectory)
        var seed = Seed()
        try seedTasks(in: container, seed: &seed)
        WorkspaceLegacyBridge.configureJournalDirectory(root.appendingPathComponent("NoteDrafts"), for: container)
        let workspace = try? WorkspaceLegacyBridge.coordinator(for: container)
        workspace?.beginLaunchRegistration()
        let tasks = TaskStore(container: container,
                              taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskImages", isDirectory: true)))
        let notes = NoteStore(container: container,
                              attachmentFileStore: makeTestAttachmentFileStore(
                                  rootURL: root.appendingPathComponent("NoteAttachments", isDirectory: true)))
        XCTAssertEqual(wait { () -> Bool in try? await workspace?.finishLaunch(); return true }, true,
                       "harness: the workspace finished its launch")
        try seedNotes(notes, seed: &seed)
        tasks.refresh()
        notes.refresh()

        // AppCoordinator: one CanvasStore for the library and the session;
        // the Notes controller on the library's Undo route.
        let canvasStore = CanvasStore(container: container)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvasStore)
        let canvasSession = CanvasSession(store: canvasStore)
        let draft = NoteDraftController(noteStore: notes)
        let state = PanelUIState()
        draft.pages.didFollowNoteLink = { [weak state] in state?.selectSection(.notes) }
        draft.pages.attachUndoRoute(library.undo)
        draft.pages.workspaceTaskStore = tasks

        let suite = "HiddenPagesCounters.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let tasksState = TasksPageState()
        let composerState = PanelComposerState()
        let calendarState = CalendarPageState()
        let libraryBox = LibraryBox()
        let previousProbe = NotesEditorPage.lifetimeProbe
        NotesEditorPage.lifetimeProbe = { [libraryBox] _, model in libraryBox.model = model }
        defer { NotesEditorPage.lifetimeProbe = previousProbe }
        let mountStart = Self.views()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: tasks, noteStore: notes, canvasSession: canvasSession,
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: AppSettings(defaults: defaults), tasksPageState: tasksState,
                                     calendarPageState: calendarState, composerState: composerState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            panel.orderOut(nil); panel.contentView = nil; panel.close()
        }

        // Notes visited and left on its library; every page built; Tasks current.
        state.selectSection(.notes)
        pump(content, panel, seconds: 1.0)
        XCTAssertTrue(draft.pages.showLibrary(), "harness: Notes goes to its library")
        pump(content, panel, seconds: 0.5)
        let notesScrolls = Set(Self.roomScrolls(in: content).map(ObjectIdentifier.init))
        XCTAssertFalse(notesScrolls.isEmpty, "harness: Notes' library holds a scroll view")
        let previousShellProbe = PanelInvalidationProbe.shell
        PanelInvalidationProbe.shell = { Self.shellRuns += 1 }
        defer { PanelInvalidationProbe.shell = previousShellProbe }
        state.selectSection(.tasks)
        for built in [PanelPage.calendar, .notes, .canvas] { state.prepareBuiltPage(built) }
        pump(content, panel, seconds: 2.0)

        XCTAssertEqual(state.selectedSection, .tasks, "harness: Tasks is current")
        XCTAssertTrue(Set(PanelPage.allCases).subtracting([.tasks]).isSubset(of: state.builtPages),
                      "harness: Notes, Calendar and Draw are built behind Tasks")
        XCTAssertTrue(draft.pages.isLibraryPresented, "harness: Notes rests on its library")
        XCTAssertTrue(draft.pages.undoRoute === library.undo, "harness: the Notes controller is on the app's Undo route")
        XCTAssertTrue(tasks.commandLibrary === library, "harness: the task store's command library is the panel's")
        let page = try XCTUnwrap(tasksState.builtModel, "harness: the panel built the Tasks page")
        XCTAssertTrue(page.library === library, "harness: the Tasks page runs on the shared library")
        page.services.acknowledgementDelay = .seconds(600)
        let composer = try XCTUnwrap(composerState.model, "harness: the panel made its card")
        let notesLibrary = try XCTUnwrap(libraryBox.model, "harness: the Notes page handed over its library model")
        let mounted = Self.diff(Self.views(), mountStart)
        print("HIDDEN_COUNTS mount " + Self.line(mounted))
        XCTAssertGreaterThan(mounted["NotesPageHost", default: 0], 0, "harness: the Notes host counter is live")
        XCTAssertGreaterThan(mounted["NotesEditorPage", default: 0], 0, "harness: the Notes page counter is live")
        XCTAssertGreaterThan(mounted["CalendarPageHost", default: 0], 0, "harness: the Calendar host counter is live")
        XCTAssertGreaterThan(mounted["DrawPageHost", default: 0] + mounted["CanvasPageHost", default: 0], 0,
                             "harness: the Draw host counter is live")
        XCTAssertGreaterThan(mounted["NotesLibraryView", default: 0], 0, "harness: the Notes library counter is live")

        let tally = Tally()
        tally.count("room.$height", composerState.room.$height.dropFirst())
        tally.count("room.$isOpen", composerState.room.$isOpen.dropFirst())
        tally.count("notesCtl.willChange", draft.pages.objectWillChange)
        tally.count("notesCtl.$undoRevision", draft.pages.undoRevisionChanges)
        tally.count("draft.willChange", draft.objectWillChange)
        tally.count("store.total", notes.objectWillChange)
        tally.count("store.inventoryNotice", library.tags.inventoryChanges)
        tally.count("store.$notes", notes.$notes.dropFirst())
        tally.count("store.$revision", notes.$revision.dropFirst())
        tally.count("store.$lastErrorMessage", notes.$lastErrorMessage.dropFirst())
        tally.count("store.$cloudSyncStatus", notes.$cloudSyncStatus.dropFirst())
        tally.count("store.$attachmentsByNoteID", notes.$attachmentsByNoteID.dropFirst())
        tally.count("store.$attachmentFailures", notes.$attachmentFailures.dropFirst())
        tally.count("store.$attachmentRetryVersions", notes.$attachmentRetryVersions.dropFirst())
        tally.count("libModel.total", notesLibrary.objectWillChange)

        try body(Rig(container: container, tasks: tasks, notes: notes, library: library, draft: draft,
                     state: state, composerState: composerState, content: content, panel: panel, page: page,
                     composer: composer, notesLibrary: notesLibrary, libraryBox: libraryBox, seed: seed, tally: tally,
                     calendarState: calendarState, tasksState: tasksState, notesScrolls: notesScrolls))
        XCTAssertTrue(libraryBox.model === notesLibrary,
                      "harness: the Notes page kept the library model the counts subscribed to")
    }

    // MARK: - Snapshots

    private static func views() -> [String: Int] {
        let kept = KeptContentHostCounts.layouts
        var v: [String: Int] = [
            "shell": shellRuns,
            "panelLayouts": AtticPanelHostingView.layoutPasses,
            "keptLayouts": kept.on + kept.off,
            "route.tasks": TaskNoteRouteHostCounts.bodyEvaluations[.tasks, default: 0],
            "route.notes": TaskNoteRouteHostCounts.bodyEvaluations[.notes, default: 0],
            "route.calendar": TaskNoteRouteHostCounts.bodyEvaluations[.calendar, default: 0],
            "NotesPageHost": NotesPageHost.bodyEvaluations,
            "NotesEditorPage": NotesEditorPage.bodyEvaluations,
            "NotesLibraryView": NotesLibraryView.bodyEvaluations,
            "CalendarPageHost": CalendarPageHost.bodyEvaluations,
            "CalendarPage": CalendarPage.bodyEvaluations,
            "CalendarDayView": CalendarDayView.bodyEvaluations,
            "dayTimeline": CalendarDayView.timelineBuilds,
            "DrawPageHost": DrawPageHost.bodyEvaluations,
            "CanvasPageHost": CanvasPageHost.bodyEvaluations,
            "PanelCanvasNoticeAwareHost": PanelCanvasNoticeAwareHost.bodyEvaluations,
        ]
        let sites: [(String, PanelComposerClearanceSite)] = [("notesPage", .notesPage), ("notesLeaf", .notesLeaf), ("calendarGrid", .calendarGrid),
                                                             ("calendarDay", .calendarDay), ("unnamed", .unnamed)]
        for (name, site) in sites {
            v["clear." + name] = PanelComposerClearanceCounts.observed[site, default: 0]
            v["clear0." + name] = PanelComposerClearanceCounts.unobserved[site, default: 0]
        }
        return v
    }

    private func snapshot(_ rig: Rig) -> [String: Int] {
        var s = Self.views().merging(rig.tally.counts) { $1 }
        let sink = rig.notesLibrary.taskSinkCounts
        s["libModel.sinkSends"] = sink.sends
        s["libModel.sinkSkippedDisjoint"] = sink.skippedDisjoint
        s["libModel.sinkUnchanged"] = sink.unchanged
        return s
    }

    private static func diff(_ after: [String: Int], _ before: [String: Int]) -> [String: Int] {
        var d: [String: Int] = [:]
        for key in Set(after.keys).union(before.keys) { d[key] = after[key, default: 0] - before[key, default: 0] }
        if let total = d["store.total"] {
            let named = storePublishers.reduce(0) { $0 + d[$1, default: 0] } + d["store.inventoryNotice", default: 0]
            d["store.bare"] = total - named
        }
        return d
    }

    private static func line(_ counts: [String: Int]) -> String {
        columns.compactMap { key in counts[key].map { "\(key)=\($0)" } }.joined(separator: " ")
    }

    /// Runs one control between two snapshots after the fixed pump.
    @discardableResult
    private func measure(_ rig: Rig, _ label: String, _ control: () -> Void) -> [String: Int] {
        pump(rig.content, rig.panel)
        let before = snapshot(rig)
        control()
        pump(rig.content, rig.panel)
        let counts = Self.diff(snapshot(rig), before)
        print("HIDDEN_COUNTS \(label) " + Self.line(counts))
        return counts
    }

    // MARK: - Controls

    private func openCard(_ rig: Rig) {
        // The shell's composer route (`AtticPanelView.composerRoute`), as "+" does.
        rig.composerState.model?.open(on: .tasks(rig.page.tab), as: nil)
    }

    /// Closes the card and waits (up to 3 s) for the room to come to rest,
    /// so the next "+" counts no fold publishes.
    private func closeCard(_ rig: Rig) {
        if rig.composer.isOpen { rig.composer.close() }
        let deadline = Date().addingTimeInterval(3)
        repeat { pump(rig.content, rig.panel, seconds: 0.1) }
        while (rig.composerState.room.height != 0 || rig.composerState.room.isOpen) && Date() < deadline
        XCTAssertEqual(rig.composerState.room.height, 0, "harness: the folded card left no room")
    }

    /// Whether the store holds a live (not deleted) row with this ID, read
    /// through a fresh context.
    private func storeHasLiveTask(_ id: UUID, _ rig: Rig) -> Bool {
        let context = ModelContext(rig.container)
        let rows = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))) ?? []
        return rows.contains { $0.deletedAt == nil }
    }

    private func hasTask(titled title: String, _ rig: Rig) -> Bool {
        rig.tasks.tasks.contains { $0.title == title && $0.deletedAt == nil }
    }

    private func isShown(_ id: UUID, _ rig: Rig) -> Bool {
        rig.page.rows(for: .now).contains { $0.id == id }
    }

    /// Every scroll view that holds the card's end keeper (Notes' library,
    /// Calendar's grid or day), in hierarchy order.
    private static func roomScrolls(in root: NSView) -> [NSScrollView] {
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

    // MARK: - C1: the card's room per "+"

    /// Mechanism 2's guard (lead's rule in `ops/design/hidden-pages.md`, "The guard for all four"): the card's room reaches a
    /// hidden page only as its scroll view's bottom margin. On "+" or the add bar, no hidden page's clearance closure runs: Notes'
    /// page-wide one and Calendar's grid and day ones are gone. On "+", Notes' hidden library list does not run either.
    private static let roomClearanceSites = ["notesPage", "calendarGrid", "calendarDay"]

    private static func clearanceCalls(_ counts: [String: Int], _ site: String) -> Int {
        counts["clear." + site, default: 0] + counts["clear0." + site, default: 0]
    }

    private func assertRoomChangeReachesNoHiddenPage(_ counts: [String: Int], _ label: String, libraryList: Bool,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        for site in Self.roomClearanceSites {
            XCTAssertEqual(Self.clearanceCalls(counts, site), 0,
                           "\(label): the \(site) clearance closure ran on the card's room change", file: file, line: line)
        }
        if libraryList {
            XCTAssertEqual(counts["NotesLibraryView", default: 0], 0,
                           "\(label): the hidden Notes library list ran on the card's room change", file: file, line: line)
        }
    }

    func testC1RoomPublishesAndClosureCallsPerPlus() throws {
        try withRig { rig in
            for round in 1...3 {
                closeCard(rig)
                let counts = measure(rig, "C1 library plus round=\(round)") { openCard(rig) }
                assertRoomChangeReachesNoHiddenPage(counts, "C1 library plus round=\(round)", libraryList: true)
                XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card")
                XCTAssertGreaterThan(rig.composerState.room.height, 0, "harness: the open card set the room")
            }
            closeCard(rig)

            // Second case: Notes resting on an open note (the editor leaf).
            let noteID = rig.seed.freeNotes[0]
            XCTAssertEqual(wait { await rig.draft.pages.openFromLibrary(noteID: noteID) }, true, "harness: the note opened")
            // The library's own next step after an open (`NotesEditorPage.openFromLibrary`): it dismisses itself.
            rig.notesLibrary.dismissAfterOpenedNote(rig.draft.pages, requestedQuery: "")
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.draft.pages.active?.noteID, noteID, "harness: Notes rests on the open note")
            XCTAssertFalse(rig.draft.pages.isLibraryPresented, "harness: Notes left its library")
            XCTAssertGreaterThan(PanelComposerClearanceCounts.observed[.notesLeaf, default: 0]
                                 + PanelComposerClearanceCounts.unobserved[.notesLeaf, default: 0], 0,
                                 "harness: the note editor's clearance counter is live")
            for round in 1...3 {
                closeCard(rig)
                let counts = measure(rig, "C1 openNote plus round=\(round)") { openCard(rig) }
                // Only the open note's leaf takes the room: it runs, and no other clearance does.
                assertRoomChangeReachesNoHiddenPage(counts, "C1 openNote plus round=\(round)", libraryList: false)
                XCTAssertEqual(Self.clearanceCalls(counts, "unnamed"), 0, "C1 openNote plus round=\(round): an unnamed clearance ran")
                XCTAssertGreaterThan(Self.clearanceCalls(counts, "notesLeaf"), 0,
                                     "C1 openNote plus round=\(round): the open note's editor leaf did not take the room")
                XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card")
                XCTAssertGreaterThan(rig.composerState.room.height, 0, "harness: the open card set the room")
            }
            closeCard(rig)
        }
    }

    // MARK: - C1b: Calendar's grid and day per "+" and fold

    /// Mechanism 2's guard for Calendar, with each scroll view mounted. Calendar opens on its grid, so C1 never had the day's
    /// clearance in the tree to count. Here the day, then the grid, is mounted behind Tasks; the card opens and folds. Each time the
    /// card's room changes inside the measured interval, the scroll view's native bottom inset follows it, no clearance closure
    /// runs, and the day's timeline is not rebuilt.
    func testC1bCalendarGridAndDayTakeTheRoomOnlyAsTheirMargin() throws {
        try withRig { rig in
            closeCard(rig)
            XCTAssertFalse(rig.calendarModel.isDayView, "harness: Calendar rests on its grid")
            let onGrid = Self.roomScrolls(in: rig.content)
            let timelineBefore = CalendarDayView.timelineBuilds
            rig.calendarModel.setDayView(true)
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is still current")
            let onDay = Self.roomScrolls(in: rig.content)
            let day = try XCTUnwrap(onDay.first { scroll in !onGrid.contains { $0 === scroll } },
                                    "harness: the day's scroll view is mounted behind Tasks")
            XCTAssertGreaterThan(CalendarDayView.timelineBuilds - timelineBefore, 0, "harness: the hidden day built its timeline")
            assertOnlyTheMarginTakesTheRoom(rig, day, "C1b day", timeline: true)

            rig.calendarModel.setDayView(false)
            pump(rig.content, rig.panel)
            let grid = try XCTUnwrap(Self.roomScrolls(in: rig.content).first { scroll in !onDay.contains { $0 === scroll } },
                                     "harness: the grid's scroll view is mounted behind Tasks again")
            assertOnlyTheMarginTakesTheRoom(rig, grid, "C1b grid", timeline: false)
        }
    }

    /// Opens the card, then folds it, each as one measured interval: the room changes in it, `scroll`'s native bottom inset gains the
    /// card's room past the bar's row and then gives it back, and no hidden page's clearance closure (nor, with `timeline`, the day's
    /// timeline) runs.
    private func assertOnlyTheMarginTakesTheRoom(_ rig: Rig, _ scroll: NSScrollView, _ label: String, timeline: Bool,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        closeCard(rig)
        pump(rig.content, rig.panel)
        let closedInset = scroll.contentInsets.bottom
        var steps: [(String, [String: Int])] = []
        steps.append(("plus", measure(rig, "\(label) plus") { openCard(rig) }))
        XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card", file: file, line: line)
        let extra = PanelComposerScrollRoom.extra(height: rig.composerState.room.height)
        XCTAssertGreaterThan(extra, 0, "harness: the open card is taller than the bar's row", file: file, line: line)
        XCTAssertEqual(scroll.contentInsets.bottom - closedInset, extra, accuracy: 1,
                       "\(label): the native bottom inset took the card's room", file: file, line: line)
        steps.append(("fold", measure(rig, "\(label) fold") { closeCard(rig) }))
        XCTAssertEqual(scroll.contentInsets.bottom, closedInset, accuracy: 1,
                       "\(label): the native bottom inset gave the room back", file: file, line: line)
        for (step, counts) in steps {
            XCTAssertGreaterThan(counts["room.$height", default: 0], 0,
                                 "harness: \(label) \(step): the card's room changed in the measured interval", file: file, line: line)
            assertRoomChangeReachesNoHiddenPage(counts, "\(label) \(step)", libraryList: false, file: file, line: line)
            if timeline {
                XCTAssertEqual(counts["dayTimeline", default: 0], 0,
                               "\(label) \(step): the day's timeline was rebuilt on the card's room change", file: file, line: line)
            }
        }
    }

    // MARK: - C2: NoteStore publishes on delete and Undo

    func testC2NoteStorePublishesOnDeleteAndUndo() throws {
        try withRig { rig in
            let id = rig.seed.plain[1]
            XCTAssertTrue(isShown(id, rig), "harness: the task is listed")
            measure(rig, "C2 delete noteless") {
                rig.page.deleteAcknowledged([id]) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertFalse(isShown(id, rig), "harness: the task left the list")
            XCTAssertFalse(storeHasLiveTask(id, rig), "harness: the store row was deleted")
            measure(rig, "C2 undo noteless") { _ = rig.page.undo() }
            XCTAssertTrue(isShown(id, rig), "harness: Undo brought the task back to the list")
            XCTAssertTrue(storeHasLiveTask(id, rig), "harness: Undo brought the store row back")
        }
    }

    // MARK: - C3: NotesLibraryModel on a tick and a tag change

    func testC3LibraryModelOnTickAndTag() throws {
        try withRig { rig in
            let sinkBefore = rig.notesLibrary.taskSinkCounts
            defer {
                let sink = rig.notesLibrary.taskSinkCounts
                let ran = (sink.sends - sinkBefore.sends) + (sink.skippedDisjoint - sinkBefore.skippedDisjoint)
                    + (sink.unchanged - sinkBefore.unchanged)
                XCTAssertGreaterThan(ran, 0, "harness: the library model's task sink is live")
            }
            for (label, id) in [("noteless", rig.seed.plain[2]), ("noteOwner", rig.seed.owners[0])] {
                measure(rig, "C3 tick \(label)") {
                    rig.page.completeAcknowledged(id) { _ in }
                    rig.page.settlePendingCompletionAcknowledgements()
                }
                XCTAssertEqual(rig.tasks.task(withID: id)?.status, .done, "harness: the tick saved")
                XCTAssertFalse(rig.tasks.task(withID: id)?.tags.contains(Self.menuTag) ?? true)
                measure(rig, "C3 tag \(label)") {
                    rig.page.toggleTagAcknowledged(Self.menuTag, for: [id]) { _ in }
                    rig.page.settlePendingCompletionAcknowledgements()
                }
                XCTAssertTrue(rig.tasks.task(withID: id)?.tags.contains(Self.menuTag) ?? false, "harness: the tag saved")
            }
        }
    }

    // MARK: - C4: the guard table, per Tasks control

    func testC4GuardTablePerTasksControl() throws {
        try withRig { rig in
            var table: [(String, [String: Int])] = []
            @MainActor func run(_ name: String, _ control: () -> Void) { table.append((name, measure(rig, "C4 control=\(name)", control))) }

            let tick = rig.seed.plain[0]
            run("tick") {
                rig.page.completeAcknowledged(tick) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertEqual(rig.tasks.task(withID: tick)?.status, .done, "harness: the tick saved")

            let tagged = rig.seed.plain[3]
            run("tag") {
                rig.page.toggleTagAcknowledged(Self.menuTag, for: [tagged]) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertTrue(rig.tasks.task(withID: tagged)?.tags.contains(Self.menuTag) ?? false, "harness: the tag saved")

            let prioritised = rig.seed.plain[4]
            run("priority") {
                rig.page.setPriorityAcknowledged(.high, for: [prioritised]) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertEqual(rig.tasks.task(withID: prioritised)?.priority, .high, "harness: the priority saved")

            closeCard(rig)
            run("plus") { openCard(rig) }
            XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card")

            let cardTitle = "Counted card task"
            rig.page.addBar = TaskAddBarText(text: cardTitle)
            rig.page.addBarCaret = nil
            run("card-create") {
                rig.composer.submit()
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertTrue(hasTask(titled: cardTitle, rig), "harness: the card created its task")

            // The add bar's room change: the card folds back into the bar's row. The card is open when the interval starts,
            // and the fold comes to rest inside it.
            if !rig.composer.isOpen { openCard(rig); pump(rig.content, rig.panel) }
            XCTAssertTrue(rig.composer.isOpen, "harness: the card is open before the fold")
            XCTAssertGreaterThan(rig.composerState.room.height, 0, "harness: the open card holds its room before the fold")
            run("add-bar") { closeCard(rig) }

            // The closed bar's own submission: a task-creation check, recorded in the table only.
            let barTitle = "Counted add bar task"
            rig.page.addBar = TaskAddBarText(text: barTitle)
            rig.page.addBarCaret = nil
            run("add-bar-create") {
                _ = rig.page.submitAddBar()
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertTrue(hasTask(titled: barTitle, rig), "harness: the add bar created its task")

            let deleted = rig.seed.plain[5]
            run("delete") {
                rig.page.deleteAcknowledged([deleted]) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }
            XCTAssertFalse(isShown(deleted, rig), "harness: the task left the list")
            XCTAssertFalse(storeHasLiveTask(deleted, rig), "harness: the store row was deleted")
            run("undo") { _ = rig.page.undo() }
            XCTAssertTrue(isShown(deleted, rig), "harness: Undo brought the task back to the list")
            XCTAssertTrue(storeHasLiveTask(deleted, rig), "harness: Undo brought the store row back")

            let shown = ["NotesPageHost", "NotesEditorPage", "NotesLibraryView", "CalendarPageHost", "CalendarPage",
                         "CalendarDayView", "DrawPageHost", "CanvasPageHost", "PanelCanvasNoticeAwareHost",
                         "clear.notesPage", "clear.notesLeaf", "clear.calendarGrid", "clear.calendarDay", "room.$height",
                         "notesCtl.willChange", "notesCtl.$undoRevision", "draft.willChange",
                         "store.total", "store.bare", "libModel.total", "libModel.sinkSends"]
            print("HIDDEN_TABLE " + (["control"] + shown).joined(separator: "\t"))
            for (name, counts) in table {
                print("HIDDEN_TABLE " + ([name] + shown.map { String(counts[$0, default: 0]) }).joined(separator: "\t"))
            }

            // Asserted only for the triggers a merged fix owns; the rest of the table is recorded. Mechanism 2 owns "+" and the
            // add bar's room change (the card folding back into the bar's row); each must change the room inside its interval.
            // The add bar's own task creation still re-runs Notes' list (mechanism 1's trigger, not owned yet): recorded only.
            for (name, counts) in table where name == "plus" || name == "add-bar" {
                XCTAssertGreaterThan(counts["room.$height", default: 0], 0,
                                     "harness: C4 \(name): the card's room changed in the measured interval")
                assertRoomChangeReachesNoHiddenPage(counts, "C4 \(name)", libraryList: name == "plus")
            }
        }
    }

    // MARK: - C5: the panel's size during a live resize

    /// The counted views of each page that is not shown while Tasks is.
    /// The shell holds four pages (`PanelPage.allCases`); Settings is a
    /// window of its own, not a page.
    private static let hiddenPageViews: [PanelPage: [String]] = [
        .notes: ["NotesPageHost", "route.notes", "NotesEditorPage", "NotesLibraryView"],
        .calendar: ["route.calendar", "CalendarPageHost", "CalendarPage", "CalendarDayView", "dayTimeline"],
        .canvas: ["PanelCanvasNoticeAwareHost", "CanvasPageHost", "DrawPageHost"],
    ]
    private static let dragSteps = 6

    /// One step of a drag on the panel's edge, in `AtticPanelController`'s
    /// order: AppKit sets the window's frame, then `windowDidResize` writes
    /// the visible size.
    private func resize(_ rig: Rig, to size: CGSize) {
        rig.panel.setContentSize(size)
        rig.state.updatePanelSize(size)
    }

    private func dragSize(_ start: CGSize, step: Int) -> CGSize {
        CGSize(width: start.width + CGFloat(step * 8), height: start.height + CGFloat(step * 4))
    }

    /// `AtticPanelController.endLiveResize`: the final size, then the lock's release.
    private func release(_ rig: Rig) {
        rig.state.updatePanelSize(rig.panel.contentRect(forFrameRect: rig.panel.frame).size)
        rig.state.setInteractionLock(.windowResize, isActive: false)
    }

    /// The trace (22 Nov, PR 41's build): on each size write of a drag on
    /// Tasks, the hidden Notes page re-ran its editor, library list and
    /// route host. With Tasks shown, a size write under the live-resize
    /// lock runs no body of any page that is not shown. The lock's start
    /// and its release are recorded only: at release the hidden pages take
    /// the new size, so they run then.
    func testC5APanelSizeWriteDuringALiveResizeRunsNoHiddenPage() throws {
        try withRig { rig in
            let hidden = PanelPage.allCases.filter { $0 != .tasks }
            for page in hidden {
                XCTAssertFalse(Self.hiddenPageViews[page, default: []].isEmpty, "harness: \(page) has counted views")
            }
            let start = rig.state.panelSize
            measure(rig, "C5 lock-on") { rig.state.setInteractionLock(.windowResize, isActive: true) }
            var drag: [String: Int] = [:]
            for step in 1...Self.dragSteps {
                let counts = measure(rig, "C5 write step=\(step)") { resize(rig, to: dragSize(start, step: step)) }
                drag.merge(counts) { $0 + $1 }
            }
            measure(rig, "C5 release") { release(rig) }
            print("HIDDEN_COUNTS C5 drag-total " + Self.line(drag))
            XCTAssertEqual(rig.state.panelSize, dragSize(start, step: Self.dragSteps), "harness: the drag reached its size")
            XCTAssertGreaterThan(drag["shell", default: 0], 0, "harness: the size writes reached the shell")
            // Calendar too (M2): the shell re-runs on each write, and its
            // hand-off to the hidden Calendar must compare equal.
            for page in hidden {
                for view in Self.hiddenPageViews[page, default: []] {
                    XCTAssertEqual(drag[view, default: 0], 0,
                                   "C5 \(page): \(view) ran on the \(Self.dragSteps) size writes of a live resize on Tasks")
                }
            }
        }
    }

    /// The page-wide native views of a page, found again on each read:
    /// Notes' library scroll view, Calendar's (the other end keepers) and
    /// the Draw board.
    private func nativeViews(of page: PanelPage, _ rig: Rig) -> [ObjectIdentifier: NSView] {
        var found: [ObjectIdentifier: NSView] = [:]
        switch page {
        case .notes, .calendar:
            for scroll in Self.roomScrolls(in: rig.content)
            where rig.notesScrolls.contains(ObjectIdentifier(scroll)) == (page == .notes) {
                found[ObjectIdentifier(scroll)] = scroll
            }
        case .canvas:
            func walk(_ view: NSView) {
                if view is DrawBoardView { found[ObjectIdentifier(view)] = view }
                view.subviews.forEach(walk)
            }
            walk(rig.content)
        case .tasks:
            break
        }
        return found
    }

    private func widths(of page: PanelPage, _ rig: Rig) -> [ObjectIdentifier: CGFloat] {
        nativeViews(of: page, rig).mapValues(\.bounds.width)
    }

    /// Condition (a) of the brief: a page hidden through a whole drag on
    /// Tasks is right in its first frame after a switch to it. Read in the
    /// first layout pass with it shown (once per run-loop turn, with a
    /// deadline): each of its native views already has the width it keeps
    /// once the switch has settled, and the drag changed that width.
    func testC5BAPageHiddenThroughAResizeIsRightInItsFirstFrame() throws {
        for page in [PanelPage.notes, .calendar, .canvas] {
            try withRig { rig in
                let before = widths(of: page, rig)
                XCTAssertFalse(before.isEmpty, "harness: \(page) has a page-wide native view")
                let start = rig.state.panelSize
                // A frame for the lock and for each step, as the drag draws.
                func frame() { rig.content.layoutSubtreeIfNeeded(); rig.panel.displayIfNeeded() }
                rig.state.setInteractionLock(.windowResize, isActive: true)
                frame()
                for step in 1...Self.dragSteps { resize(rig, to: dragSize(start, step: step)); frame() }
                release(rig)
                waitForTestOperation("the release's pass") {
                    rig.content.layoutSubtreeIfNeeded()
                    rig.panel.displayIfNeeded()
                    return rig.state.retainedPageSizeDuringLiveResize == nil
                }
                let shellBefore = Self.shellRuns
                rig.state.switchPage(to: page.section, motion: .instant)
                var first: [ObjectIdentifier: CGFloat]?
                waitForTestOperation("the first frame with \(page) shown") {
                    rig.content.layoutSubtreeIfNeeded()
                    rig.panel.displayIfNeeded()
                    guard Self.shellRuns > shellBefore else { return false }
                    first = widths(of: page, rig)
                    return true
                }
                XCTAssertEqual(rig.state.selectedSection, page.section, "harness: \(page) is shown")
                pump(rig.content, rig.panel)
                let settled = widths(of: page, rig)
                XCTAssertEqual(Set(settled.keys), Set(before.keys), "harness: \(page) kept its native views")
                for (id, width) in settled {
                    XCTAssertNotEqual(width, before[id] ?? width, "harness: the drag changed \(page)'s width")
                    XCTAssertEqual(first?[id] ?? -1, width, accuracy: 0.5,
                                   "C5 \(page): its first frame after the switch is not at its settled width")
                }
                print("HIDDEN_FIRST page=\(page) before=\(before.values.sorted()) first=\((first ?? [:]).values.sorted()) "
                      + "settled=\(settled.values.sorted())")
            }
        }
    }

    /// Condition (b) of the brief: a page switch is no slower by count.
    /// Recorded only (base against fix): the panel's and the kept hosts'
    /// layout passes and the counted bodies per switch.
    func testC5CPageSwitchCountsAreRecorded() throws {
        try withRig { rig in
            for page in [PanelPage.notes, .tasks, .calendar, .tasks, .canvas, .tasks] {
                let counts = measure(rig, "C5 switch to=\(page)") {
                    rig.state.switchPage(to: page.section, motion: .instant)
                }
                XCTAssertEqual(rig.state.selectedSection, page.section, "harness: the switch to \(page) happened")
                XCTAssertGreaterThan(counts["panelLayouts", default: 0], 0, "harness: the panel layout counter is live")
            }
        }
    }

    // MARK: - C6: the shown page still follows what it reads

    /// A frame of the panel, as the window's display cycle draws it.
    private func frame(_ rig: Rig) {
        rig.content.layoutSubtreeIfNeeded()
        rig.panel.displayIfNeeded()
    }

    /// Switches to `page` and waits, bounded, for the shell's pass with it shown.
    private func show(_ page: PanelPage, _ rig: Rig) {
        let shellBefore = Self.shellRuns
        rig.state.switchPage(to: page.section, motion: .instant)
        waitForTestOperation("the shell's pass with \(page) shown") {
            frame(rig)
            return Self.shellRuns > shellBefore
        }
        XCTAssertEqual(rig.state.selectedSection, page.section, "harness: \(page) is shown")
        pump(rig.content, rig.panel)
    }

    /// The pages stopped observing all of `PanelUIState` (M1): the page
    /// that is shown takes each size of a drag on its own edge. In the
    /// first frame after one size write, read with no wait, each of its
    /// native views has the width it keeps once settled.
    func testC6AAShownPageTakesEachSizeOfADragInItsFirstFrame() throws {
        for page in [PanelPage.notes, .calendar, .canvas] {
            try withRig { rig in
                show(page, rig)
                let before = widths(of: page, rig)
                XCTAssertFalse(before.isEmpty, "harness: \(page) has a page-wide native view")
                let start = rig.state.panelSize
                rig.state.setInteractionLock(.windowResize, isActive: true)
                frame(rig)
                let shellBefore = Self.shellRuns
                resize(rig, to: dragSize(start, step: 3))
                var first: [ObjectIdentifier: CGFloat]?
                waitForTestOperation("the first frame after the size write on \(page)") {
                    frame(rig)
                    guard Self.shellRuns > shellBefore else { return false }
                    first = widths(of: page, rig)
                    return true
                }
                pump(rig.content, rig.panel)
                let settled = widths(of: page, rig)
                release(rig)
                pump(rig.content, rig.panel)
                XCTAssertEqual(Set(settled.keys), Set(before.keys), "harness: \(page) kept its native views")
                for (id, width) in settled {
                    XCTAssertNotEqual(width, before[id] ?? width, "harness: the size write changed \(page)'s width")
                    XCTAssertEqual(first?[id] ?? -1, width, accuracy: 0.5,
                                   "C6 \(page): the shown page's first frame after a size write is not at its new width")
                }
                print("HIDDEN_SHOWN page=\(page) before=\(before.values.sorted()) first=\((first ?? [:]).values.sorted()) "
                      + "settled=\(settled.values.sorted())")
            }
        }
    }

    /// The old Canvas's Clear confirmation (`isCanvasConfirmationPresented`,
    /// the one flag of the panel's state that page reads): shown, the page
    /// re-runs when the flag is set and cleared, and hands the new value on.
    func testC6BShownCanvasFollowsItsClearConfirmationFlag() throws {
        let previous = AtticDraw.enabledOverride
        AtticDraw.enabledOverride = false
        defer { AtticDraw.enabledOverride = previous }
        try withRig { rig in
            show(.canvas, rig)
            for presented in [true, false] {
                let runs = CanvasPageHost.bodyEvaluations
                rig.state.isCanvasConfirmationPresented = presented
                waitForTestOperation("the Canvas page's pass for the flag \(presented)") {
                    frame(rig)
                    return CanvasPageHost.bodyEvaluations > runs
                }
                XCTAssertEqual(CanvasPageHost.handedClearConfirmation, presented,
                               "C6 canvas: the shown page handed on a stale Clear confirmation flag")
            }
            XCTAssertFalse(rig.state.isCanvasConfirmationPresented, "harness: the confirmation is cleared")
        }
    }

    /// Calendar's one followed flag (`isPanelOnScreen`, from the hide and
    /// reveal counts): shown, its model is visible after a reveal, not
    /// after a hide, and visible again after the next reveal.
    func testC6CShownCalendarFollowsThePanelAcrossAHideAndReveal() throws {
        try withRig { rig in
            show(.calendar, rig)
            let model = rig.calendarModel
            for (step, onScreen) in [("reveal", true), ("hide", false), ("reveal again", true)] {
                if onScreen { rig.state.panelDidReveal() } else { rig.state.panelDidHide() }
                XCTAssertEqual(rig.state.isPanelOnScreen, onScreen, "harness: \(step)")
                waitForTestOperation("Calendar's model after the \(step)") {
                    frame(rig)
                    return model.isVisibleForTesting == onScreen
                }
                XCTAssertEqual(model.isVisibleForTesting, onScreen, "C6 calendar: the shown page missed the \(step)")
            }
        }
    }

    // MARK: - C7: Calendar's closure-free hand-off (M2) keeps its routes

    /// The Calendar's "+" now goes through `CalendarPageSlot.startNewTask`
    /// (the shell's one card, as `composerRoute` opens it): shown, it opens
    /// the card on that day.
    func testC7ACalendarPlusOpensTheCardOnItsDay() throws {
        try withRig { rig in
            show(.calendar, rig)
            closeCard(rig)
            let day = rig.calendarModel.newTaskDay
            CalendarPageSlot.startNewTask(day, composerState: rig.composerState)
            XCTAssertTrue(rig.composer.isOpen, "C7: Calendar's \"+\" did not open the card")
            XCTAssertEqual(rig.composer.page, .calendar(selected: day), "C7: the card is not on Calendar's day")
            closeCard(rig)
        }
    }

    /// Calendar's task-note services, now made by the slot from the moved
    /// `AtticPanelView.calendarTaskNoteEntryServices`: Open Task Note opens
    /// the task's page over Calendar with Calendar's way back.
    func testC7BCalendarOpenTaskNoteComesBackToCalendar() throws {
        try withRig { rig in
            show(.calendar, rig)
            let id = rig.seed.plain[0]
            let services = AtticPanelView.calendarTaskNoteEntryServices(
                uiState: rig.state, calendarPageState: rig.calendarState, tasksPageState: rig.tasksState,
                store: rig.tasks, toasts: PanelToastCenter(), noteDraft: rig.draft)
            services.open(id, "Back to Calendar")
            XCTAssertEqual(rig.state.openTaskNoteID, id, "C7: Open Task Note did not open the task's page")
            XCTAssertEqual(rig.state.taskNoteOrigin, .calendar, "C7: the task's page is not over Calendar")
            XCTAssertEqual(rig.state.taskNoteBackTitle, "Back to Calendar", "C7: the way back is not Calendar's")
            pump(rig.content, rig.panel)
            TaskNoteRouteHost<EmptyView>.closeRoute(id, uiState: rig.state, controller: rig.draft.pages)
            waitForTestOperation("the task's page closed") {
                frame(rig)
                return rig.state.openTaskNoteID == nil
            }
            pump(rig.content, rig.panel)
        }
    }
}
