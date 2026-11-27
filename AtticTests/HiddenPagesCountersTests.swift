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
    /// C9's seed: a scrollable Now list and a task due today (off for the rest).
    private static var scrollSeed = false
    private static let scrollRows = 60
    private static let scrollSteps = 30
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
        /// The shell's chrome state: AppKit's top drag lane reads the top
        /// row's footprint from it.
        let chrome: PanelChromeInteractionState
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
        // C9 only: a Now list long enough to scroll, and today's agenda day
        // with a row on it, so the hidden Calendar draws its now line.
        if Self.scrollSeed {
            let tail = " and the long tail of words a tracker row carries about its pull request and its review"
            for index in 0..<Self.scrollRows {
                _ = insert("Tracker task \(index + 1)" + tail, tags: ["tag\(index % 7)"], index: 8 + index)
            }
            let due = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == seed.plain[0] })
            due.dueDay = DueDay(date: now, calendar: CalendarMonthMath.calendar())
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
        // Its first show ever (built as the current page): the shell's notice
        // clearance in that first frame, and Notes' own once settled (ND4).
        AtticPanelView.lastNoticeClearance = nil
        NotesEditorPage.lastOwnNoticeClearance = nil
        state.selectSection(.notes)
        content.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let firstShowShellClearance = AtticPanelView.lastNoticeClearance
        pump(content, panel, seconds: 1.0)
        Self.firstEverNotesShow = (firstShowShellClearance, NotesEditorPage.lastOwnNoticeClearance)
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
                     calendarState: calendarState, tasksState: tasksState, notesScrolls: notesScrolls, chrome: chrome))
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
            // Calendar sits in a kept host of its own (PR 80), not laid out
            // while hidden: the day it switched to is mounted in its first
            // frame shown. Mounted so, it goes back behind Tasks.
            showAndHideCalendar(rig)
            let onDay = Self.roomScrolls(in: rig.content)
            let day = try XCTUnwrap(onDay.first { scroll in !onGrid.contains { $0 === scroll } },
                                    "harness: the day's scroll view is mounted behind Tasks")
            XCTAssertGreaterThan(CalendarDayView.timelineBuilds - timelineBefore, 0, "harness: the day built its timeline")
            assertOnlyTheMarginTakesTheRoomOnFirstShow(rig, day, "C1b day", timeline: true)

            rig.calendarModel.setDayView(false)
            pump(rig.content, rig.panel)
            showAndHideCalendar(rig)
            let grid = try XCTUnwrap(Self.roomScrolls(in: rig.content).first { scroll in !onDay.contains { $0 === scroll } },
                                     "harness: the grid's scroll view is mounted behind Tasks again")
            assertOnlyTheMarginTakesTheRoomOnFirstShow(rig, grid, "C1b grid", timeline: false)
        }
    }

    private func showAndHideCalendar(_ rig: Rig) {
        rig.state.switchPage(to: PanelPage.calendar.section, motion: .instant)
        pump(rig.content, rig.panel)
        rig.state.switchPage(to: PanelPage.tasks.section, motion: .instant)
        pump(rig.content, rig.panel)
        XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is current again")
    }

    /// `assertOnlyTheMarginTakesTheRoom` for Calendar in its kept host
    /// (PR 80): hidden, the card's room change reaches none of it (no
    /// clearance closure, no timeline). The user's path: the card open on
    /// Tasks, then Calendar's page. The switch closes the card at once (the
    /// shell's `selectedSection` change), so in Calendar's first frame shown
    /// `scroll`'s native bottom inset has the card's room as it is then,
    /// and a settle later the closed one, the same when the room was already
    /// closed in that frame: no held room shown, no slide from it.
    private func assertOnlyTheMarginTakesTheRoomOnFirstShow(_ rig: Rig, _ scroll: NSScrollView, _ label: String, timeline: Bool,
                                                            file: StaticString = #filePath, line: UInt = #line) {
        closeCard(rig)
        pump(rig.content, rig.panel)
        let closedInset = scroll.contentInsets.bottom
        var steps: [(String, [String: Int])] = []
        steps.append(("plus", measure(rig, "\(label) plus") { openCard(rig) }))
        XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card", file: file, line: line)
        let extra = PanelComposerScrollRoom.extra(height: rig.composerState.room.height)
        XCTAssertGreaterThan(extra, 0, "harness: the open card is taller than the bar's row", file: file, line: line)
        let shellBefore = Self.shellRuns
        rig.state.switchPage(to: PanelPage.calendar.section, motion: .instant)
        var firstInset: CGFloat?
        waitForTestOperation("the first frame with Calendar shown") {
            rig.content.layoutSubtreeIfNeeded()
            rig.panel.displayIfNeeded()
            guard Self.shellRuns > shellBefore else { return false }
            firstInset = scroll.contentInsets.bottom
            return true
        }
        let roomAtFirst = rig.composerState.room.height
        XCTAssertEqual((firstInset ?? -1) - closedInset, PanelComposerScrollRoom.extra(height: roomAtFirst), accuracy: 1,
                       "\(label): in Calendar's first frame shown, the native bottom inset has the card's room as it is then (\(roomAtFirst))",
                       file: file, line: line)
        pump(rig.content, rig.panel)
        XCTAssertFalse(rig.composer.isOpen, "harness: the switch closed the card", file: file, line: line)
        XCTAssertEqual(scroll.contentInsets.bottom, closedInset, accuracy: 1,
                       "\(label): Calendar shown with the card closed has the closed inset", file: file, line: line)
        if PanelComposerScrollRoom.extra(height: roomAtFirst) < 0.5 {
            XCTAssertEqual(firstInset ?? -1, scroll.contentInsets.bottom, accuracy: 1,
                           "\(label): the inset moved after Calendar's first frame shown", file: file, line: line)
        }
        rig.state.switchPage(to: PanelPage.tasks.section, motion: .instant)
        pump(rig.content, rig.panel)
        openCard(rig)
        pump(rig.content, rig.panel)
        XCTAssertTrue(rig.composer.isOpen, "harness: \"+\" opened the card again on Tasks", file: file, line: line)
        steps.append(("fold", measure(rig, "\(label) fold") { closeCard(rig) }))
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

            // One change of the shell's environment: the window's appearance.
            let appearance = rig.panel.appearance
            let dark = rig.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            run("appearance") { rig.panel.appearance = NSAppearance(named: dark ? .aqua : .darkAqua) }
            rig.panel.appearance = appearance
            pump(rig.content, rig.panel)

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
            // Hidden behind Tasks, Notes sits in a kept host (page-host-notes-draw): a change of the
            // shell's environment runs none of its views. A store change from Tasks' rows still runs
            // them (board NOTES-HIDDEN-STORE-RUNS): no more than on the trunk (run 45961603654).
            let trunkNotesRuns: [String: [String: Int]] = [
                "tick": [:],
                "tag": ["route.notes": 1, "NotesPageHost": 1, "NotesEditorPage": 2, "NotesLibraryView": 2],
                "delete": ["route.notes": 1, "NotesPageHost": 1, "NotesEditorPage": 1, "NotesLibraryView": 1],
                "appearance": [:],
            ]
            for (name, counts) in table {
                guard let trunk = trunkNotesRuns[name] else { continue }
                for view in Self.hiddenPageViews[.notes, default: []] {
                    XCTAssertLessThanOrEqual(counts[view, default: 0], trunk[view, default: 0],
                                             "C4 \(name): hidden Notes' \(view) ran more than on the trunk")
                }
            }
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
            // The size is a layout input now (resize-cause.md, lead's ruling
            // of 24 Nov 13:42, criterion 2): a write no longer runs the
            // shell. The harness check is that each step reached the shown
            // page through layout.
            XCTAssertEqual(drag["shell", default: 0], 0, "a size write of a drag ran the shell's body")
            XCTAssertEqual(PanelRootLayout.lastPlacedSize, dragSize(start, step: Self.dragSteps),
                           "harness: the drag's last size reached the root's layout")
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

    /// Calendar's kept page host, if it has one (P1-b).
    private func calendarHost(_ rig: Rig) -> KeptContentHostingView? {
        func hosts(_ view: NSView) -> [KeptContentHostingView] {
            ((view as? KeptContentHostingView).map { [$0] } ?? []) + view.subviews.flatMap(hosts)
        }
        return hosts(rig.content).first { PanelPageKeyboard.membership(of: $0) == .page(.calendar) }
    }

    /// P1-b's guard (review of PR 80, P1-1). With Calendar hidden behind
    /// Tasks, through a live resize with its release, one size write
    /// outside a drag and a switch from Tasks to Notes, Calendar's kept host
    /// stays undrawn and is laid out no more, and Calendar's views do not
    /// run through the resize. The PR's speed target itself is a time,
    /// measured on the Air; on the trunk these views ran 0 times through
    /// the resize as well (fka runs 45866976309 and 45867028693). The
    /// guard was shown red with the hidden host forced drawn (scratch run,
    /// see the PR body).
    func testC5DHiddenCalendarRunsNothingThroughAResizeAWriteAndASwitch() throws {
        try withRig { rig in
            XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is shown")
            let host = calendarHost(rig)
            let layoutsBefore = host.map { KeptContentHostCounts.layoutsByHost[ObjectIdentifier($0), default: 0] }
            var drawnAt: [String] = []
            let start = rig.state.panelSize
            var resizing: [String: Int] = [:]
            @MainActor func add(_ label: String, _ counts: [String: Int]) {
                resizing.merge(counts) { $0 + $1 }
                if host?.isDrawn == true { drawnAt.append(label) }
            }
            add("lock-on", measure(rig, "C5D lock-on") { rig.state.setInteractionLock(.windowResize, isActive: true) })
            for step in 1...Self.dragSteps {
                add("write step=\(step)", measure(rig, "C5D write step=\(step)") { resize(rig, to: dragSize(start, step: step)) })
            }
            add("release", measure(rig, "C5D release") { release(rig) })
            add("outside a drag", measure(rig, "C5D outside a drag") { resize(rig, to: dragSize(start, step: Self.dragSteps + 2)) })
            XCTAssertEqual(PanelRootLayout.lastPlacedSize, dragSize(start, step: Self.dragSteps + 2),
                           "harness: the write outside a drag reached the root's layout")
            let switching = measure(rig, "C5D Tasks to Notes") { show(.notes, rig) }
            if host?.isDrawn == true { drawnAt.append("Tasks to Notes") }
            let layoutsAfter = host.map { KeptContentHostCounts.layoutsByHost[ObjectIdentifier($0), default: 0] }
            print("HIDDEN_COUNTS C5D resize-total " + Self.line(resizing))
            print("HIDDEN_COUNTS C5D guard host=\(host != nil) drawn_at=\(drawnAt) host_layouts=\(layoutsBefore ?? -1)->\(layoutsAfter ?? -1)")
            for view in Self.hiddenPageViews[.calendar, default: []] {
                XCTAssertEqual(resizing[view, default: 0], 0,
                               "C5D: Calendar's \(view) ran while hidden through a resize and a write")
            }
            // CAL-RUNS-ON-NOTES-SWITCH (board): Notes' draft publishes on the
            // switch and Calendar's route host, which observes it, runs its
            // page once, on the trunk as well. Pinned at that count so it
            // cannot grow; it goes to 0 when that fix lands.
            let pinned = ["route.calendar": 1, "CalendarPageHost": 1, "CalendarPage": 1, "CalendarDayView": 0, "dayTimeline": 0]
            for view in Self.hiddenPageViews[.calendar, default: []] {
                XCTAssertEqual(switching[view, default: 0], pinned[view, default: 0],
                               "C5D: Calendar's \(view) on the switch to Notes (CAL-RUNS-ON-NOTES-SWITCH)")
            }
            // Not thrown: a missing host must not cut the rig's teardown short.
            if host != nil {
                XCTAssertEqual(drawnAt, [], "C5D: hidden, Calendar's host was drawn")
                XCTAssertEqual(layoutsAfter, layoutsBefore, "C5D: hidden, Calendar's host was laid out")
            } else {
                XCTFail("C5D: Calendar sits in a kept host of its own")
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

    /// A hidden page's native view widths in the first layout pass with it
    /// shown (as C5B reads them): a page whose host is not laid out while
    /// hidden (Calendar, PR 80) must be right there.
    private func firstShownWidths(of page: PanelPage, _ rig: Rig) -> [ObjectIdentifier: CGFloat]? {
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
        return first
    }

    /// A hidden page not laid out while hidden has, in its first frame
    /// shown, every native view grown by `grown` from `before`.
    private func assertFirstShownFrameTookTheSize(_ page: PanelPage, _ rig: Rig, before: [ObjectIdentifier: CGFloat], grown: CGFloat,
                                                  _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = widths(of: page, rig).keys
        XCTAssertFalse(expected.isEmpty, "harness: hidden \(page) has a native view to read", file: file, line: line)
        let first = firstShownWidths(of: page, rig) ?? [:]
        XCTAssertEqual(rig.state.selectedSection, page.section, "harness: \(page) is shown", file: file, line: line)
        XCTAssertEqual(Set(first.keys), Set(expected), "harness: \(page) kept its native views", file: file, line: line)
        for (id, width) in first {
            XCTAssertEqual(width - (before[id] ?? -1), grown, accuracy: 0.5,
                           "\(label): \(page) does not have the size in its first frame shown", file: file, line: line)
        }
        // No jump: a settle later, the same widths.
        pump(rig.content, rig.panel)
        for (id, width) in widths(of: page, rig) {
            XCTAssertEqual(width, first[id] ?? -1, accuracy: 0.5,
                           "\(label): \(page)'s width moved after its first frame shown", file: file, line: line)
        }
    }

    /// A page's page-wide native views: each is as wide as its page, so
    /// shown it is as wide as the window. (PR 69 review: a width that only
    /// moves by the step would pass for a page that stays too narrow.)
    private func pageWideWidths(of page: PanelPage, _ rig: Rig) -> [CGFloat] {
        func find(_ name: String, in view: NSView) -> [NSView] {
            (view.className.hasSuffix(name) ? [view] : []) + view.subviews.flatMap { find(name, in: $0) }
        }
        switch page {
        case .tasks:
            // Tasks' tab hosts only: Calendar and Notes each sit in a
            // kept host of their own, which keeps its settled size while
            // hidden (PR 80; speed/page-host-notes-draw).
            return find("KeptContentContainer", in: rig.content).filter { view in
                guard let host = (view as? KeptContentContainer)?.host else { return false }
                return !view.isHiddenOrHasHiddenAncestor && Self.isTasksHost(host)
            }.map(\.bounds.width)
        case .notes: return find("NotesPageSwipeView", in: rig.content).map(\.bounds.width)
        case .calendar: return find("CalendarPageInput5Input", in: rig.content).map(\.bounds.width)
        case .canvas: return find("DrawBoardView", in: rig.content).map(\.bounds.width)
        }
    }

    /// The widths of Calendar's kept-host container (PR 80): hidden, a
    /// hidden page's frame.
    private func calendarContainerWidths(_ rig: Rig) -> [CGFloat] {
        func find(_ view: NSView) -> [NSView] {
            (view is KeptContentContainer ? [view] : []) + view.subviews.flatMap(find)
        }
        return find(rig.content).filter { view in
            guard let host = (view as? KeptContentContainer)?.host else { return false }
            return PanelPageKeyboard.membership(of: host) == .page(.calendar)
        }.map(\.bounds.width)
    }

    /// Body runs of the Calendar page's own views (the lead's condition 1,
    /// 27 Nov: a hidden page's work is counted on its views, not on its
    /// host's callbacks, which C9A showed flat while agenda days ran).
    private func hiddenCalendarBodies() -> [String: Int] {
        var bodies: [String: Int] = [
            "CalendarPageHost": CalendarPageHost.bodyEvaluations,
            "CalendarPage": CalendarPage.bodyEvaluations,
            "route.calendar": TaskNoteRouteHostCounts.bodyEvaluations[.calendar, default: 0],
            "CalendarDayView": CalendarDayView.bodyEvaluations,
            "dayTimeline": CalendarDayView.timelineBuilds,
            "gridDay": CalendarDayMarksView.bodyEvaluations,
            "nowLine": CalendarNowLine.bodyEvaluations,
        ]
        bodies["agendaDay"] = CalendarAgendaDay.bodyEvaluationsByDay.values.reduce(0, +)
        return bodies
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
                resize(rig, to: dragSize(start, step: 3))
                var first: [ObjectIdentifier: CGFloat]?
                waitForTestOperation("the first frame after the size write on \(page)") {
                    frame(rig)
                    // The frame the write produced: the root laid out at the
                    // new size (a size write no longer runs the shell, so
                    // its body is not the signal; resize-cause.md, cause 1).
                    guard PanelRootLayout.lastPlacedSize == dragSize(start, step: 3) else { return false }
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

    /// The Tasks tab drawn in the pager: its host's width.
    private func drawnTasksHostWidths(_ rig: Rig) -> [CGFloat] {
        var found: [CGFloat] = []
        func walk(_ view: NSView) {
            if let host = view as? KeptContentHostingView, host.isDrawn, !host.isHiddenOrHasHiddenAncestor {
                found.append(host.bounds.width)
            }
            view.subviews.forEach(walk)
        }
        walk(rig.content)
        return found
    }

    /// Resize cause 2 (resize-cause.md; the trigger named 24 Nov): the pager
    /// sat in a geometry reader and was handed each new size as a value, so
    /// every size step re-made the pages: one pager pass, an update of each
    /// tab's host, a new root and a new environment for the shown one. The
    /// pager's size is a layout input: a size step, in a drag or outside
    /// one, runs no pager pass, updates no tab host and sets no root, and
    /// the shown tab is at the new width in the step's own frame; the swipe
    /// hears the width.
    func testRZ7ASizeStepRunsNoPagerPassAndUpdatesNoTabHost() throws {
        // Reduce Motion off, stated (CI's runners have it on): hidden pages
        // then rest a settled width to their side, so a write outside a
        // drag moves them (review of PR 80, P2-1).
        let previousReduceMotion = AtticMotionPreference.systemReduceMotionOverride
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = previousReduceMotion }
        try withRig { rig in
            XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is shown")
            let start = rig.state.panelSize
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.page.pagerSwipe.width, drawnTasksHostWidths(rig).first ?? -1, accuracy: 0.5,
                           "the swipe knows the pager's width before any resize")
            var sizes = (1...Self.dragSteps).map { dragSize(start, step: $0) }
            // A height-only step, then (after the release) a write that is no drag.
            sizes.append(CGSize(width: sizes[sizes.count - 1].width, height: sizes[sizes.count - 1].height + 10))
            let outsideADrag = dragSize(start, step: Self.dragSteps + 2)
            rig.state.setInteractionLock(.windowResize, isActive: true)
            pump(rig.content, rig.panel)
            for (index, size) in (sizes + [outsideADrag]).enumerated() {
                let label = size == outsideADrag ? "outside a drag" : "step \(index + 1)"
                if size == outsideADrag {
                    release(rig)
                    pump(rig.content, rig.panel)
                }
                let before = (TasksPagerPassCount.passes, KeptContentHostCounts.updates, KeptContentHostCounts.roots,
                              KeptContentHostCounts.environments, AtticPanelHostingView.layoutPasses)
                resize(rig, to: size)
                var first: [CGFloat] = []
                waitForTestOperation("the first frame after the size write (\(label))") {
                    frame(rig)
                    guard PanelRootLayout.lastPlacedSize == size else { return false }
                    first = drawnTasksHostWidths(rig)
                    return true
                }
                pump(rig.content, rig.panel)
                let passes = TasksPagerPassCount.passes - before.0
                let updates = (KeptContentHostCounts.updates.on - before.1.on, KeptContentHostCounts.updates.off - before.1.off)
                let roots = (KeptContentHostCounts.roots.on - before.2.on, KeptContentHostCounts.roots.off - before.2.off)
                let environments = KeptContentHostCounts.environments.on - before.3.on
                print("PAGER_SIZE_STEP \(label) width=\(size.width) pager=\(passes) updates=\(updates.0)/\(updates.1) roots=\(roots.0)/\(roots.1) "
                      + "envs=\(environments) panel_layouts=\(AtticPanelHostingView.layoutPasses - before.4) first=\(first) swipe=\(rig.page.pagerSwipe.width) "
                      + "reduce=\(String(describing: AtticMotionPreference.systemReduceMotionOverride)) level=\(AtticMotionPreference.level) "
                      + "travels=\(PanelPageMotion.current(reduceMotion: (AtticMotionPreference.systemReduceMotionOverride ?? false) || AtticMotionPreference.level == .reduced).travels)")
                XCTAssertEqual(passes, 0, "\(label): a size write ran the pager's pages again")
                XCTAssertEqual(updates.0, 0, "\(label): a size write updated the shown tab's host")
                XCTAssertEqual(updates.1, 0, "\(label): a size write updated a hidden tab's host")
                XCTAssertEqual(roots.0 + roots.1, 0, "\(label): a size write set a tab host's root")
                XCTAssertEqual(environments, 0, "\(label): a size write handed the shown tab a new environment")
                XCTAssertEqual(first.count, 1, "harness: one Tasks tab is drawn")
                XCTAssertEqual(first.first ?? -1, size.width, accuracy: 0.5,
                               "\(label): the shown tab's first frame after the size write is not at the new width")
                XCTAssertEqual(rig.page.pagerSwipe.width, size.width, accuracy: 0.5, "\(label): the swipe did not hear the new width")
            }
            // The counters count: a tick sets the shown host's root.
            let roots = KeptContentHostCounts.roots.on, passes = TasksPagerPassCount.passes
            let row = try XCTUnwrap(rig.page.rows(for: .now).first { $0.status != .done }, "harness: Now holds an open row")
            rig.page.completeAcknowledged(row.id) { _ in }
            pump(rig.content, rig.panel, seconds: 0.6)
            XCTAssertGreaterThan(KeptContentHostCounts.roots.on, roots, "harness: a tick still sets the shown host's root")
            XCTAssertGreaterThan(TasksPagerPassCount.passes, passes, "harness: a tick still runs the pager")
        }
    }

    /// SPEED-TASKSPAGE-BODY-ON-WRITE (rows-rerun-fable.md §4): on each size
    /// write of a drag on Tasks, `TasksPage.body` ran (`@self changed`): its
    /// equality compared the whole layout, the panel's size included, though
    /// the pager takes its size from its own geometry. A size write that
    /// leaves the page's insets as they were runs no `TasksPage.body`, and
    /// the drawn tab still takes each size in its first frame. Past the
    /// reading column's width the insets follow the width, so the page runs
    /// there (the control: the counter is live).
    func testC8ASizeWriteOnTasksRunsNoTasksPageBodyAndTheListFollows() throws {
        try withRig { rig in
            XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is shown")
            let start = rig.state.panelSize
            XCTAssertLessThan(dragSize(start, step: Self.dragSteps).width, PanelPageLayout.readingWidth,
                              "harness: the drag stays inside the reading column")
            rig.state.setInteractionLock(.windowResize, isActive: true)
            pump(rig.content, rig.panel)
            // The top row's right-hand controls sit at a fixed distance
            // from the panel's right edge, whatever its width.
            let dockWidth = rig.chrome.modeDockWidth
            var pageRuns: [Int] = []
            for step in 1...Self.dragSteps {
                let size = dragSize(start, step: step)
                let before = (TasksPageRenderProbe.bodyRuns, TasksPage.tabsEvaluations, KeptContentHostCounts.updates,
                              KeptContentHostCounts.roots, KeptContentHostCounts.environments, Self.shellRuns)
                resize(rig, to: size)
                var first: [CGFloat] = []
                waitForTestOperation("the first frame after size write \(step) on Tasks") {
                    frame(rig)
                    // The frame the write produced: the root laid out at the
                    // new size (a size write no longer runs the shell).
                    guard PanelRootLayout.lastPlacedSize == size else { return false }
                    first = drawnTasksHostWidths(rig)
                    return true
                }
                pump(rig.content, rig.panel)
                let runs = TasksPageRenderProbe.bodyRuns - before.0
                pageRuns.append(runs)
                print("TASKSPAGE_WRITE step=\(step) width=\(size.width) page=\(runs) tabs=\(TasksPage.tabsEvaluations - before.1) "
                      + "updates=\(KeptContentHostCounts.updates.on - before.2.on)/\(KeptContentHostCounts.updates.off - before.2.off) "
                      + "roots=\(KeptContentHostCounts.roots.on - before.3.on)/\(KeptContentHostCounts.roots.off - before.3.off) "
                      + "envs=\(KeptContentHostCounts.environments.on - before.4.on)/\(KeptContentHostCounts.environments.off - before.4.off) "
                      + "first=\(first) settled=\(drawnTasksHostWidths(rig))")
                XCTAssertEqual(first.count, 1, "harness: one Tasks tab is drawn")
                XCTAssertEqual(first.first ?? -1, size.width, accuracy: 0.5,
                               "C8 step \(step): the drawn Tasks tab's first frame after a size write is not at its new width")
            }
            XCTAssertEqual(pageRuns, Array(repeating: 0, count: Self.dragSteps),
                           "C8: a size write that leaves the page's insets alone runs no TasksPage.body")
            print("TASKSPAGE_WRITE dock before=\(dockWidth) after=\(rig.chrome.modeDockWidth)")
            XCTAssertGreaterThan(dockWidth, 0, "harness: the top row reported its right-hand controls")
            XCTAssertEqual(rig.chrome.modeDockWidth, dockWidth, accuracy: 0.5,
                           "C8: the top row's right-hand footprint follows the drag (AppKit's drag lane)")

            // Past the reading column (U-42) the insets change with the width.
            let wide = CGSize(width: PanelPageLayout.readingWidth + 100, height: start.height)
            resize(rig, to: wide)
            pump(rig.content, rig.panel)
            let wideBefore = TasksPageRenderProbe.bodyRuns
            resize(rig, to: CGSize(width: wide.width + 8, height: wide.height))
            pump(rig.content, rig.panel)
            let wideRuns = TasksPageRenderProbe.bodyRuns - wideBefore
            print("TASKSPAGE_WRITE wide page=\(wideRuns)")
            XCTAssertGreaterThan(wideRuns, 0, "C8 control: a write that moves the reading column's insets runs the page")
            release(rig)
            pump(rig.content, rig.panel)
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

    // MARK: - Focus readers at a click (speed/rings-focusstate-on-keyboard)

    /// The trace (Air, opt=1, 413c02c4): a click that moves focus between
    /// Tasks rows re-checks every focus reader in the panel, the hidden
    /// pages' included. 84-86 of them were Attic's own focus rings, which
    /// hold a `@FocusState` with the mouse too, where no ring can show, and
    /// 9 were `NotesLibraryRow`s, whose body held the •••'s focus state.
    /// With the mouse driving, after building every page and a MOVE click
    /// (the click's selection, then the page's focus route), no ring holds a
    /// focus state and no Notes row's body does. The control: once the
    /// keyboard drives, the rings hold one again.
    func testFocusReadersAtAMoveClickWithTheMouse() throws {
        AtticFocusReaderCensus.reset()
        AtticFocusReaderCensus.records = true
        defer { AtticFocusReaderCensus.records = false; AtticFocusReaderCensus.reset() }
        try withRig { rig in
            let tracker = rig.state.keyboardFocus
            tracker.observe(.leftMouseDown, keyCode: nil)
            pump(rig.content, rig.panel)
            XCTAssertFalse(tracker.isKeyboardDriving, "harness: the mouse drives")

            let ids = rig.page.rows(for: .now).map(\.id)
            XCTAssertGreaterThan(ids.count, 4, "harness: Now has rows to click")
            @MainActor func focus(_ id: UUID) { // TasksPage.rowFocusChanged's two calls, for a click
                rig.page.receiveKeyboardFocus(AtticRowFocusID(page: TasksTab.now.rawValue, id: id), keyboardDriving: false)
                rig.page.cellUpdates.objectWillChange.send()
            }
            let c = ids[2], d = ids[4]
            rig.page.selectOnly(c)
            focus(c)
            pump(rig.content, rig.panel)
            rig.page.click(d, modifiers: [], visible: ids)
            focus(d)
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.page.selection, [d], "harness: the click selected D")
            XCTAssertEqual(rig.page.keyboardFocus?.id, d, "harness: the focus route reached D")

            let rings = AtticFocusReaderCensus.rings.values
            let notesRows = AtticFocusReaderCensus.notesRows.count
            let actions = AtticFocusReaderCensus.notesRowActions.count
            print("FOCUS_READERS move-click mouse rings=\(rings.count) "
                  + "rings_kv_off=\(rings.filter { !$0.keyboardFocusVisible }.count) "
                  + "rings_kv_on=\(rings.filter(\.keyboardFocusVisible).count) "
                  + "notes_row_bodies=\(notesRows) notes_row_actions=\(actions)")
            XCTAssertEqual(rings.count, 0, "with the mouse, a focus ring holds a focus state (a reader re-checked per click)")
            XCTAssertGreaterThan(actions, 0, "harness: the hidden Notes library built its rows' •••")
            XCTAssertEqual(notesRows, 0, "a Notes row's body holds the •••'s focus state (a reader re-checked per click)")

            // The control: the keyboard drives, and the rings hold their
            // focus state again. Read on a shown page: hidden, Notes and
            // Calendar sit in kept hosts that hold their environment, so a
            // hidden page's rings no longer re-run (page-host-notes-draw).
            show(.notes, rig)
            AtticFocusReaderCensus.rings = [:]
            tracker.noteKeyboardNavigation()
            pump(rig.content, rig.panel)
            let keyboardRings = AtticFocusReaderCensus.rings.values.filter(\.keyboardFocusVisible).count
            print("FOCUS_READERS keyboard rings=\(keyboardRings)")
            XCTAssertGreaterThan(keyboardRings, 0, "harness: with the keyboard driving, the rings hold a focus state")
            tracker.observe(.leftMouseDown, keyCode: nil)
            pump(rig.content, rig.panel)
        }
    }

    // MARK: - A row move is not a focus move (list-owned-focus.md §5)

    /// Posts events through the app's queue one at a time, each pumped, so
    /// a mouse-down's pass and the mouse-up's stay apart.
    @MainActor private func post(_ rig: Rig, _ events: [NSEvent]) {
        for event in events {
            NSApp.postEvent(event, atStart: false)
            Hosted.pumpEvents()
            pump(rig.content, rig.panel)
        }
    }

    @MainActor private func rowClick(_ rig: Rig, _ id: UUID, modifiers: NSEvent.ModifierFlags = []) throws {
        let frame = try XCTUnwrap(rig.page.agentRowFrames([id]).first?.frame, "harness: the row \(id) is on the page")
        let point = CGPoint(x: frame.minX + min(120, frame.width / 2), y: frame.midY)
        post(rig, try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
        })
    }

    @MainActor private func rowKey(_ rig: Rig, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
        var flags = modifiers
        if [123, 124, 125, 126].contains(code) { flags.formUnion([.numericPad, .function]) }
        post(rig, try [NSEvent.EventType.keyDown, .keyUp].map { type in
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        })
    }

    /// The sentinel checks since the last call, by "region@phase"; resets.
    @MainActor private func takePhaseChecks() -> [String: Int] {
        let checks = AtticFocusReaderCensus.phaseChecks
        AtticFocusReaderCensus.reset()
        return checks
    }

    private static let regions = ["tasks", "calendar", "notes", "canvas"]

    /// list-owned-focus.md §5, "Red, then green": the Tasks list owns the
    /// keyboard, so a move from row to row writes the selection and the
    /// cursor but no SwiftUI focus.
    /// - A MOVE click checks no focus reader in any region, in the
    ///   mouse-down's pass or the one after it. Red on the trunk 5fe27e46:
    ///   `after-md` 1/1/1/1 (Air, stage 1, s1-base.log).
    /// - ↓, ↑, ⇧↓ and Tab from row to row write no focus state through the
    ///   link (the trunk writes one per move), and check no more readers than
    ///   the trunk's 2 per region and step (stage 1: ↓ 2 then 2 on the trunk;
    ///   a key the panel's monitor takes is counted under the phase before
    ///   it, so each step's phases are summed).
    /// - Observed apart from the new code: the first responder is the same
    ///   object before and after each move, and the selection, the cursor
    ///   and (for a key) the drawn ring land on the row.
    /// - The control: a click on the row that has the keyboard (STAY)
    ///   checks nothing.
    func testARowMoveIsNotAFocusMove() throws {
        try requireKeyWindowTests()
        try withRig { rig in
            rig.panel.makeKey()
            pump(rig.content, rig.panel)
            XCTAssertTrue(rig.panel.isKeyWindow, "harness: the panel is the key window")
            let ids = rig.page.rows(for: .now).map(\.id)
            XCTAssertGreaterThan(ids.count, 6, "harness: Now has rows to move between")
            let link = try XCTUnwrap(TasksRowFocusLink.current, "harness: the page's focus link")

            try rowClick(rig, ids[2])  // the list takes the keyboard once
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.page.keyboardFocus?.id, ids[2], "harness: the first click gave row 2 the keyboard")
            _ = takePhaseChecks()
            let responder = try XCTUnwrap(rig.panel.firstResponder, "harness: something holds the keyboard")

            // MOVE click.
            var writes = link.focusWrites
            var environments = TasksPageRenderProbe.environmentsBelowKeys
            var tabEnvironments = TasksPageRenderProbe.environmentsBelowTabKeys
            try rowClick(rig, ids[4])
            let move = takePhaseChecks()
            print("LIST_FOCUS env move-click page=\(TasksPageRenderProbe.environmentsBelowKeys - environments) tab=\(TasksPageRenderProbe.environmentsBelowTabKeys - tabEnvironments)")
            XCTAssertEqual(rig.page.selection, [ids[4]], "the click selected row 4")
            XCTAssertEqual(rig.page.keyboardFocus?.id, ids[4], "the click gave row 4 the cursor")
            XCTAssertTrue(rig.panel.firstResponder === responder, "the first responder changed on a row click")
            XCTAssertEqual(link.focusWrites - writes, 0, "a row click wrote a focus state")
            for region in Self.regions {
                for phase in ["md", "after-md"] {
                    XCTAssertEqual(move["\(region)@\(phase)", default: 0], 0,
                                   "a MOVE click checked a focus reader in \(region) at \(phase) (\(move))")
                }
            }

            // STAY: the row that has the keyboard, clicked again.
            try rowClick(rig, ids[4])
            let stay = takePhaseChecks()
            XCTAssertEqual(stay.values.reduce(0, +), 0, "control: a click that moves nothing checked a focus reader (\(stay))")

            // Keys from row to row.
            let keys: [(name: String, code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, row: Int, selection: [Int])] = [
                ("↓", 125, "\u{F701}", [], 5, [5]),
                ("↓ again", 125, "\u{F701}", [], 6, [6]),
                ("↑", 126, "\u{F700}", [], 5, [5]),
                ("⇧↓", 125, "\u{F701}", .shift, 6, [5, 6]),
                ("Tab", 48, "\t", [], 7, [5, 6]),
            ]
            for key in keys {
                writes = link.focusWrites
                environments = TasksPageRenderProbe.environmentsBelowKeys
                tabEnvironments = TasksPageRenderProbe.environmentsBelowTabKeys
                try rowKey(rig, key.code, key.characters, key.modifiers)
                pump(rig.content, rig.panel)
                print("LIST_FOCUS env \(key.name) page=\(TasksPageRenderProbe.environmentsBelowKeys - environments) tab=\(TasksPageRenderProbe.environmentsBelowTabKeys - tabEnvironments)")
                let checks = takePhaseChecks()
                let row = ids[key.row]
                XCTAssertEqual(rig.page.keyboardFocus?.id, row, "\(key.name): the cursor is not on row \(key.row)")
                XCTAssertEqual(rig.page.selection, Set(key.selection.map { ids[$0] }), "\(key.name): the selection")
                XCTAssertTrue(rig.page.rowPointer?.drawnFocus.contains(TasksRowID(tab: .now, id: row)) ?? false,
                              "\(key.name): no ring was drawn on row \(key.row)")
                XCTAssertTrue(rig.panel.firstResponder === responder, "\(key.name): the first responder changed")
                XCTAssertEqual(link.focusWrites - writes, 0, "\(key.name) wrote a focus state")
                for region in Self.regions {
                    let total = checks.filter { $0.key.hasPrefix(region + "@") }.values.reduce(0, +)
                    XCTAssertLessThanOrEqual(total, 2, "\(key.name) checked \(total) focus readers in \(region), more than the trunk (\(checks))")
                }
            }
        }
    }
}

// MARK: - Resize: the size is a layout input (ops/design/resize-cause.md, cause 1)

/// The panel's size reaches the pages through layout (the window's frame),
/// never as shell state. Each step of a resize drag is driven as
/// `AtticPanelController` drives it: the window's frame, then the size
/// write. `layoutSubtreeIfNeeded` and `displayIfNeeded` are one frame, with
/// no run-loop turn between the write and the reading.
extension HiddenPagesCountersTests {
    private func oneFrame(_ rig: Rig) {
        rig.content.layoutSubtreeIfNeeded()
        rig.panel.displayIfNeeded()
    }

    /// Criteria 2 and 4. On each drag step, whatever page is shown: the
    /// panel's state publishes nothing, the shell's body does not run, and
    /// the root of a page whose content does not depend on the width
    /// (Tasks under the reading width, Notes, Draw) does not run. In that
    /// same frame the root is laid out at the window's content size and the
    /// shown page's page-wide native view has taken the step.
    func testRZ1ADragStepPublishesNoSizeAndRunsNoShellOrPageRoot() throws {
        for page in PanelPage.allCases {
            try withRig { rig in
                if page != .tasks {
                    rig.state.switchPage(to: page.section, motion: .instant)
                    pump(rig.content, rig.panel, seconds: 1.0)
                }
                XCTAssertEqual(rig.state.selectedSection, page.section, "harness: \(page) is shown")
                var published = 0, tasksHost = 0, notesHost = 0, sentToIsland = 0
                let subscription = rig.state.objectWillChange.sink { published += 1 }
                defer { subscription.cancel() }
                // The island's glass is in another window and cannot take
                // the size from layout: it is sent each size, live.
                let islandFeed = rig.state.panelSizeChanges.sink { _ in sentToIsland += 1 }
                defer { islandFeed.cancel() }
                let previousTasks = PanelInvalidationProbe.tasksHost, previousNotes = PanelInvalidationProbe.notesHost
                PanelInvalidationProbe.tasksHost = { tasksHost += 1 }
                PanelInvalidationProbe.notesHost = { notesHost += 1 }
                defer {
                    PanelInvalidationProbe.tasksHost = previousTasks
                    PanelInvalidationProbe.notesHost = previousNotes
                }
                let start = rig.state.panelSize
                let nativeStart = widths(of: page, rig)
                // Calendar's page sits in a kept host of its own (PR 80):
                // hidden, its container is a hidden page and keeps the
                // drag's start size, as every hidden page does (RZ3).
                let calendarStart = page == .calendar ? [] : calendarContainerWidths(rig)
                if page != .calendar {
                    XCTAssertFalse(calendarStart.isEmpty, "harness: \(page): the hidden Calendar's container is found")
                }
                rig.state.setInteractionLock(.windowResize, isActive: true)
                pump(rig.content, rig.panel)
                published = 0; tasksHost = 0; notesHost = 0; sentToIsland = 0
                let calendarBodiesBefore = hiddenCalendarBodies()
                let shellBefore = Self.shellRuns
                let drawBefore = PanelCanvasNoticeAwareHost.bodyEvaluations
                for step in 1...Self.dragSteps {
                    let size = dragSize(start, step: step)
                    resize(rig, to: size)
                    oneFrame(rig)
                    XCTAssertEqual(PanelRootLayout.lastPlacedSize, size,
                                   "\(page) step \(step): the root is laid out at the window's content size in the step's frame")
                    for (view, width) in widths(of: page, rig) {
                        XCTAssertEqual(width - (nativeStart[view] ?? width), size.width - start.width, accuracy: 0.5,
                                       "\(page) step \(step): the shown page's native view took the step in the same frame")
                    }
                    if page != .calendar {
                        XCTAssertEqual(calendarContainerWidths(rig), calendarStart,
                                       "\(page) step \(step): the hidden Calendar keeps the drag's start size")
                    }
                    let pageWide = pageWideWidths(of: page, rig)
                    XCTAssertFalse(pageWide.isEmpty, "\(page) step \(step): the shown page has a page-wide native view")
                    for width in pageWide {
                        XCTAssertEqual(width, rig.panel.contentRect(forFrameRect: rig.panel.frame).width, accuracy: 0.5,
                                       "\(page) step \(step): the shown page is as wide as the window in the step's frame")
                    }
                }
                XCTAssertEqual(rig.state.panelSize, dragSize(start, step: Self.dragSteps), "harness: the drag reached its size")
                XCTAssertEqual(published, 0, "\(page): the panel's state published on the \(Self.dragSteps) steps of a drag")
                XCTAssertEqual(sentToIsland, Self.dragSteps, "\(page): the island is sent each step's size once")
                XCTAssertEqual(Self.shellRuns - shellBefore, 0, "\(page): the shell's body ran on the steps of a drag")
                XCTAssertEqual(tasksHost, 0, "\(page): the Tasks host's body ran on the steps of a drag")
                XCTAssertEqual(notesHost, 0, "\(page): the Notes host's body ran on the steps of a drag")
                XCTAssertEqual(PanelCanvasNoticeAwareHost.bodyEvaluations - drawBefore, 0,
                               "\(page): the Draw host's body ran on the steps of a drag")
                if page != .calendar {
                    XCTAssertEqual(hiddenCalendarBodies().subtracting(calendarBodiesBefore), [:],
                                   "\(page): a hidden Calendar view's body ran on the steps of a drag")
                }
                release(rig)
                pump(rig.content, rig.panel)
            }
        }
    }

    /// The layout a page is handed carries no size: two ordinary sizes give
    /// equal values, so a resize hands no page a new one.
    func testRZ2TheLayoutIsTheSameValueAtEveryOrdinarySize() {
        let small = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 340, height: 560))
        let large = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 900, height: 700))
        XCTAssertEqual(small, large)
        // The insets still follow a panel too small for its corner.
        let tiny = PanelPageLayout(cornerSize: 140, panelSize: CGSize(width: 200, height: 560))
        XCTAssertNotEqual(tiny, PanelPageLayout(cornerSize: 140, panelSize: CGSize(width: 340, height: 560)))
        XCTAssertEqual(tiny.chromeInsets, PanelGeometry.chromeInsets(cornerSize: 140, panelSize: CGSize(width: 200, height: 560)))
    }

    /// Kept behaviour (criterion 5): a hidden page keeps the drag's start
    /// size through every step and has the final size in its first frame
    /// shown after the release.
    func testRZ3HiddenPagesKeepTheDragsStartSizeAndCatchUpOnRelease() throws {
        try withRig { rig in
            let hidden = [PanelPage.notes, .calendar, .canvas]
            var before: [ObjectIdentifier: CGFloat] = [:]
            for page in hidden { before.merge(widths(of: page, rig)) { first, _ in first } }
            for page in hidden { XCTAssertFalse(widths(of: page, rig).isEmpty, "harness: hidden \(page) has a native view to read") }
            let start = rig.state.panelSize
            rig.state.setInteractionLock(.windowResize, isActive: true)
            oneFrame(rig)
            for step in 1...Self.dragSteps {
                resize(rig, to: dragSize(start, step: step))
                oneFrame(rig)
                XCTAssertEqual(rig.state.retainedPageSizeDuringLiveResize, start, "step \(step): the hidden pages hold the start size")
                for page in hidden {
                    let now = widths(of: page, rig)
                    XCTAssertFalse(now.isEmpty, "step \(step): hidden \(page) has a native view to read")
                    for (view, width) in now {
                        XCTAssertEqual(width, before[view] ?? -1, accuracy: 0.5, "step \(step): hidden \(page) was laid out again")
                    }
                }
            }
            release(rig)
            let grown = dragSize(start, step: Self.dragSteps).width - start.width
            // Draw is laid out while hidden: it takes the final size hidden.
            let laidOutHidden: [PanelPage] = [.canvas]
            waitForTestOperation("the hidden pages take the final size") {
                oneFrame(rig)
                return laidOutHidden.allSatisfy { page in
                    let now = widths(of: page, rig)
                    return !now.isEmpty && now.allSatisfy { abs($0.value - (before[$0.key] ?? -1) - grown) < 0.5 }
                }
            }
            XCTAssertNil(rig.state.retainedPageSizeDuringLiveResize)
            // Notes and Calendar sit in kept hosts that are not laid out while
            // hidden (page-host-notes-draw; PR 80): each takes the final size
            // in its first frame shown.
            for page in [PanelPage.notes, .calendar] { assertFirstShownFrameTookTheSize(page, rig, before: before, grown: grown, "RZ3") }
        }
    }

    /// Criterion 6: a size change that is not our drag (a reveal, a display
    /// change, a programmatic frame; `windowDidResize`) still reaches the
    /// hidden pages, by their first frame shown.
    func testRZ4ASizeChangeOutsideADragReachesTheHiddenPages() throws {
        try withRig { rig in
            let hidden = [PanelPage.notes, .calendar, .canvas]
            var before: [ObjectIdentifier: CGFloat] = [:]
            for page in hidden {
                XCTAssertFalse(widths(of: page, rig).isEmpty, "harness: hidden \(page) has a native view to read")
                before.merge(widths(of: page, rig)) { first, _ in first }
            }
            let start = rig.state.panelSize
            resize(rig, to: CGSize(width: start.width + 24, height: start.height + 12))
            // Draw is laid out while hidden: it takes the size hidden.
            let laidOutHidden: [PanelPage] = [.canvas]
            waitForTestOperation("the hidden pages take a size written outside a drag") {
                oneFrame(rig)
                return laidOutHidden.allSatisfy { page in
                    let now = widths(of: page, rig)
                    return !now.isEmpty && now.allSatisfy { abs($0.value - (before[$0.key] ?? -1) - 24) < 0.5 }
                }
            }
            // Notes and Calendar sit in kept hosts that are not laid out while
            // hidden (page-host-notes-draw; PR 80): each takes the size in its
            // first frame shown.
            for page in [PanelPage.notes, .calendar] { assertFirstShownFrameTookTheSize(page, rig, before: before, grown: 24, "RZ4A") }
        }
    }

    /// Kept behaviour (criterion 5): the 600 pt reading column, read where
    /// the page is laid out. Up to the reading width the page is handed the
    /// layout unchanged; past it, the side insets grow by half the extra.
    func testRZ5TheReadingColumnFollowsTheLaidOutWidth() {
        final class Seen { var layouts: [PanelPageLayout] = [] }
        let seen = Seen()
        let layout = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 340, height: 560))
        let host = NSHostingView(rootView: PanelReadingColumn(layout: layout) { column -> Color in
            seen.layouts.append(column)
            return Color.clear
        })
        for (width, extra) in [(340.0, 0.0), (592, 0), (600, 0), (608, 4), (1700, 550)] {
            seen.layouts.removeAll()
            host.frame = CGRect(x: 0, y: 0, width: width, height: 560)
            host.layoutSubtreeIfNeeded()
            guard let column = seen.layouts.last else {
                XCTFail("width \(width): the page was handed no layout at this width")
                continue
            }
            XCTAssertEqual(column, layout.readingColumn(panelWidth: width), "width \(width)")
            XCTAssertEqual(column.contentInsets.leading, layout.contentInsets.leading + extra, accuracy: 0.001, "width \(width)")
            XCTAssertEqual(column.chromeInsets.trailing, layout.chromeInsets.trailing + extra, accuracy: 0.001, "width \(width)")
            if extra == 0 { XCTAssertEqual(column, layout, "width \(width): under the reading width the page's layout is unchanged") }
        }
    }
}

// MARK: - PR 69 fix round 1, item 2: a hidden page's rows read the page's own width

extension HiddenPagesCountersTests {
    /// The width a row is handed is its page's own frame. An open note is
    /// hidden behind Tasks through a drag: on every step its bottom row is
    /// handed the width the page is held at, never the live one. Shown
    /// mid-drag, it is handed the window's width, and no stale one.
    func testRZ6AHiddenEditorsRowReadsThePagesOwnWidth() throws {
        #if ATTIC_LOCAL_ONLY
        try withRig { rig in
            var handed: [CGFloat] = []
            PanelInvalidationProbe.rowPageWidth = { row, width in if row == "notes-editor" { handed.append(width) } }
            defer { PanelInvalidationProbe.rowPageWidth = nil }
            rig.state.switchPage(to: .notes, motion: .instant)
            pump(rig.content, rig.panel, seconds: 1.0)
            let noteID = rig.seed.freeNotes[0]
            XCTAssertEqual(wait { await rig.draft.pages.openFromLibrary(noteID: noteID) }, true, "harness: the note opened")
            rig.notesLibrary.dismissAfterOpenedNote(rig.draft.pages, requestedQuery: "")
            pump(rig.content, rig.panel, seconds: 1.0)
            XCTAssertFalse(rig.draft.pages.isLibraryPresented, "harness: Notes rests on the open note")
            let start = rig.state.panelSize
            XCTAssertEqual(try XCTUnwrap(handed.last, "harness: the editor's row is laid out"), start.width, accuracy: 0.5,
                           "shown, the row is handed the panel's width")

            rig.state.switchPage(to: .tasks, motion: .instant)
            pump(rig.content, rig.panel, seconds: 1.0)
            rig.state.setInteractionLock(.windowResize, isActive: true)
            oneFrame(rig)
            handed.removeAll()
            for step in 1...Self.dragSteps {
                resize(rig, to: dragSize(start, step: step))
                oneFrame(rig)
                XCTAssertEqual(handed.filter { abs($0 - start.width) >= 0.5 }, [],
                               "step \(step): the hidden editor's row was handed a width its page does not have")
            }
            let live = dragSize(start, step: Self.dragSteps).width
            handed.removeAll()
            rig.state.switchPage(to: .notes, motion: .instant)
            oneFrame(rig)
            XCTAssertEqual(try XCTUnwrap(handed.last, "shown mid-drag, the row is laid out in the first frame"), live, accuracy: 0.5,
                           "shown mid-drag, the row has the window's width in its first frame")
            // A rare state, on the board: with Notes in a kept host of its own
            // (page-host-notes-draw), the shell's layout of the frame that
            // shows it mid-drag hands the row the start width once before
            // the live one (AtticPanelHostingView.layout, run 45958590350);
            // the frame drawn has the live width (asserted above).
            XCTExpectFailure("PR-NOTES-RZ6A-MIDDRAG (board): shown mid-drag, the row is handed the start width "
                             + "once in the frame's layout", strict: true) {
                XCTAssertEqual(handed.filter { abs($0 - live) >= 0.5 }, [], "shown mid-drag, the row was handed a stale width")
            }
            release(rig)
            pump(rig.content, rig.panel)
        }
        #endif
    }

    /// The reader itself, for every row that uses it: its own width plus
    /// the outset, whatever the panel's coordinate space around it measures.
    func testRZ6TheWidthReaderReadsItsOwnWidthNotThePanelSpaces() {
        final class Seen { var widths: [CGFloat] = [] }
        let seen = Seen()
        let host = NSHostingView(rootView: PanelWidthReader(row: "pin", outset: 40) { width -> Color in
            seen.widths.append(width)
            return Color.clear
        }
        .frame(width: 300, height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(PanelPageLayout.coordinateSpace))
        for panel in [340.0, 500, 388] {
            seen.widths.removeAll()
            host.frame = CGRect(x: 0, y: 0, width: panel, height: 30)
            host.layoutSubtreeIfNeeded()
            if panel == 340 { XCTAssertEqual(seen.widths.last, 340, "harness: the reader ran") }
            XCTAssertEqual(seen.widths.filter { $0 != 340 }, [], "panel \(panel): a row 300 wide with 40 around it is in a page 340 wide")
        }
    }

    // MARK: - C9: a Tasks scroll with Calendar built behind it

    /// The Tasks Now list: the long list inside a Tasks tab host. Calendar's
    /// page sits in a kept host of its own (PR 80), whose agenda is a long
    /// list too: the walk found it first and scrolled the hidden Calendar
    /// itself (run 45923411211, `C9GEO`: the hidden host's agenda clip went
    /// 14, 28 … 126 with the steps).
    /// A Tasks tab host: a kept host that carries no other page's tag
    /// (Calendar's and Notes' hosts carry theirs).
    private static func isTasksHost(_ host: KeptContentHostingView) -> Bool {
        guard let membership = PanelPageKeyboard.membership(of: host) else { return true }
        return membership == .page(.tasks)
    }

    private func tasksList(_ rig: Rig) throws -> NSScrollView {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
               let host = KeptContentHostingView.enclosing(scroll),
               Self.isTasksHost(host),
               let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 200 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(rig.content)
        return try XCTUnwrap(found.first, "harness: the Tasks Now list is long enough to scroll")
    }

    /// The clip origins of the scroll views inside Calendar's kept host.
    private func calendarScrollOrigins(_ rig: Rig) -> [CGFloat] {
        var origins: [CGFloat] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let host = KeptContentHostingView.enclosing(scroll),
               PanelPageKeyboard.membership(of: host) == .page(.calendar) {
                origins.append(scroll.contentView.bounds.origin.y)
            }
            view.subviews.forEach(walk)
        }
        walk(rig.content)
        return origins
    }

    /// One scroll step of the Tasks list, then the file's pump: a couple of
    /// run-loop turns, each with a layout and display pass (the window's own
    /// cycle).
    private func scrollStep(_ list: NSScrollView, _ rig: Rig, step: Int) {
        let y = CGFloat(step) * 14
        list.contentView.scroll(to: CGPoint(x: 0, y: y))
        list.reflectScrolledClipView(list.contentView)
        pump(rig.content, rig.panel, seconds: 0.024)
        XCTAssertEqual(list.contentView.bounds.origin.y, y, accuracy: 0.6, "harness: step \(step) moved the list")
    }

    /// Today's agenda day, with its row and its now line, in the hidden Calendar.
    private func assertTodayHasItsNowLine(_ rig: Rig) {
        let today = rig.calendarModel.snapshot.groups.first { $0.isToday }
        XCTAssertEqual(today?.hasRows, true, "harness: today's agenda day has a row")
        XCTAssertEqual(today?.items.contains(.now), true, "harness: today's agenda day has its now line")
    }

    /// The traces (Air, t446n439, 24-25 Nov): while the Tasks list scrolls,
    /// the panel's host updates its graph on each step, and the Calendar
    /// kept built behind Tasks costs most of it; its agenda most of all,
    /// and the agenda's every-minute now line alone about two thirds of
    /// that (scroll-takeover-notes.md, Opus build). With Calendar hidden
    /// behind Tasks through its build and a scroll of the list: no agenda
    /// day's body runs, and the now line holds no minute clock.
    func testC9AHiddenCalendarDoesNoClockOrAgendaWorkThroughATasksScroll() throws {
        Self.scrollSeed = true
        defer { Self.scrollSeed = false }
        let linesBefore = CalendarNowLine.bodyEvaluations
        let clocksBefore = CalendarNowLine.clockBuilds
        try withRig { rig in
            // The panel is on screen, as in the app (the rig starts unrevealed).
            rig.state.panelDidReveal()
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.state.selectedSection, PanelPage.tasks.section, "harness: Tasks is shown")
            assertTodayHasItsNowLine(rig)
            XCTAssertGreaterThan(CalendarNowLine.bodyEvaluations - linesBefore, 0,
                                 "harness: the hidden Calendar built today's now line")
            let list = try tasksList(rig)
            let calendarClips = calendarScrollOrigins(rig)
            XCTAssertFalse(calendarClips.isEmpty, "harness: the hidden Calendar's scroll views are found")
            let agendaBefore = CalendarAgendaDay.bodyEvaluationsByDay.values.reduce(0, +)
            let linesAtScroll = CalendarNowLine.bodyEvaluations
            let clocksAtScroll = CalendarNowLine.clockBuilds
            let bodiesBefore = hiddenCalendarBodies()
            // The same pumps with no scroll first: the hidden Calendar does no work at rest either.
            for _ in 1...Self.scrollSteps { pump(rig.content, rig.panel, seconds: 0.024) }
            XCTAssertEqual(hiddenCalendarBodies().subtracting(bodiesBefore), [:],
                           "C9: a hidden Calendar view's body ran with Tasks at rest")
            let panelBefore = AtticPanelHostingView.layoutPasses
            for step in 1...Self.scrollSteps { scrollStep(list, rig, step: step) }
            XCTAssertEqual(calendarScrollOrigins(rig), calendarClips, "harness: the scroll moved the Tasks list, not the hidden Calendar")
            XCTAssertEqual(hiddenCalendarBodies().subtracting(bodiesBefore), [:],
                           "C9: a hidden Calendar view's body ran during a Tasks scroll")
            let agenda = CalendarAgendaDay.bodyEvaluationsByDay.values.reduce(0, +) - agendaBefore
            let panel = AtticPanelHostingView.layoutPasses - panelBefore
            print("HIDDEN_COUNTS C9A steps=\(Self.scrollSteps) panelLayouts=\(panel) agendaDays=\(agenda) "
                  + "nowLine=\(CalendarNowLine.bodyEvaluations - linesAtScroll) clockScroll=\(CalendarNowLine.clockBuilds - clocksAtScroll) "
                  + "clockHidden=\(CalendarNowLine.clockBuilds - clocksBefore)")
            XCTAssertGreaterThan(panel, 0, "harness: the panel's host laid out during the Tasks scroll")
            XCTAssertEqual(agenda, 0, "C9: an agenda day's body ran during a Tasks scroll with Calendar hidden")
            XCTAssertEqual(CalendarNowLine.clockBuilds - clocksBefore, 0,
                           "C9: the hidden Calendar's now line built a minute clock (build and Tasks scroll, Calendar never shown)")
        }
    }

    /// The other half: Calendar shown after the scroll is current in its
    /// first frame. Read in the first pass with Calendar shown: the now
    /// line's clock is built, at the minute of the switch; and the page
    /// model's snapshot, which that pass draws from, has today's agenda day
    /// with the task made due today while Calendar was hidden. The drawn
    /// rows themselves are not read.
    func testC9BCalendarShownAfterATasksScrollIsCurrentInItsFirstFrame() throws {
        Self.scrollSeed = true
        defer { Self.scrollSeed = false }
        // Only a clock built in this rig counts: a hidden line draws no clock.
        CalendarNowLine.lastClockDate = nil
        try withRig { rig in
            // The panel is on screen, as in the app (the rig starts unrevealed).
            rig.state.panelDidReveal()
            pump(rig.content, rig.panel)
            assertTodayHasItsNowLine(rig)
            // A change while hidden: a second task made due today.
            let late = rig.seed.plain[1]
            let lateTask = try XCTUnwrap(rig.tasks.task(withID: late), "harness: the second plain task")
            XCTAssertTrue(rig.tasks.update(lateTask, dueDay: .some(DueDay(date: Date(), calendar: CalendarMonthMath.calendar()))),
                          "harness: the second task is due today")
            pump(rig.content, rig.panel)
            let list = try tasksList(rig)
            for step in 1...10 { scrollStep(list, rig, step: step) }
            let shellBefore = Self.shellRuns
            let switchedAt = Date()
            rig.state.switchPage(to: PanelPage.calendar.section, motion: .instant)
            var firstClock: Date?
            var firstHasLate = false
            var recorded = false
            waitForTestOperation("the first frame with Calendar shown") {
                // The helper calls this again once it has returned true:
                // only the first frame with Calendar shown is recorded.
                if recorded { return true }
                frame(rig)
                guard Self.shellRuns > shellBefore else { return false }
                recorded = true
                firstClock = CalendarNowLine.lastClockDate
                firstHasLate = rig.calendarModel.snapshot.groups.first { $0.isToday }?.items.contains {
                    if case let .task(task) = $0 { return task.id == late } else { return false }
                } ?? false
                return true
            }
            let after = Date()
            XCTAssertEqual(rig.state.selectedSection, PanelPage.calendar.section, "harness: Calendar is shown")
            let calendar = CalendarMonthMath.calendar()
            let minute = { (date: Date) in calendar.dateInterval(of: .minute, for: date)?.start }
            let shown = try XCTUnwrap(firstClock, "C9: no now-line clock was live in the first frame with Calendar shown")
            XCTAssertTrue([minute(switchedAt), minute(after)].contains(minute(shown)),
                          "C9: the first frame's now line shows \(shown), not the minute of the switch (\(switchedAt))")
            XCTAssertTrue(firstHasLate, "C9: the task made due today while Calendar was hidden is missing from its first frame")
        }
    }

    // MARK: - Inputs a hidden Calendar takes on show (pr80-hidden-inputs.md, the lead's condition 3, 27 Nov)

    /// Runs `switching`, then reads once in the first frame with `page`
    /// shown: the first frame whose pass ran the shell (as C9B reads).
    private func inFirstShownFrame(of page: PanelPage, _ rig: Rig, switching: () -> Void, read: () -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let shellBefore = Self.shellRuns
        switching()
        var recorded = false
        waitForTestOperation("the first frame with \(page) shown") {
            if recorded { return true }
            frame(rig)
            guard Self.shellRuns > shellBefore else { return false }
            recorded = true
            read()
            return true
        }
        XCTAssertTrue(recorded, "harness: a frame with \(page) shown", file: file, line: line)
        XCTAssertEqual(rig.state.selectedSection, page.section, "harness: \(page) is shown", file: file, line: line)
    }

    /// A day asked for from another page while Calendar is hidden: Tasks'
    /// next event opens its day on the Calendar page (the shell's
    /// `openCalendarDay`, which Tasks' row calls: select the day, then
    /// switch, in one pass). In the first frame with Calendar shown, the
    /// day is selected and its agenda day is drawn.
    func testC11ADayAskedForFromTasksIsOnScreenInCalendarsFirstFrame() throws {
        try withRig { rig in
            rig.state.panelDidReveal()
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.state.selectedSection, PanelPage.tasks.section, "harness: Tasks is shown")
            let open = try XCTUnwrap(rig.page.services.openCalendarDay, "harness: the shell handed Tasks its open-day path")
            let calendar = CalendarMonthMath.calendar()
            let asked = DueDay(date: try XCTUnwrap(calendar.date(byAdding: .day, value: 45, to: Date())), calendar: calendar)
            XCTAssertNotEqual(rig.calendarModel.snapshot.selected, asked, "harness: another day is selected before")
            let drawnBefore = CalendarAgendaDay.bodyEvaluationsByDay[asked, default: 0]
            var selected: DueDay?
            var listed = false
            var drawn = 0
            inFirstShownFrame(of: .calendar, rig, switching: { open(asked) }, read: {
                selected = rig.calendarModel.snapshot.selected
                listed = rig.calendarModel.snapshot.groups.contains { $0.day == asked }
                drawn = CalendarAgendaDay.bodyEvaluationsByDay[asked, default: 0] - drawnBefore
            })
            XCTAssertEqual(selected, asked, "C11: the day asked for is not selected in Calendar's first frame shown")
            XCTAssertTrue(listed, "C11: the day asked for is not in the agenda of Calendar's first frame shown")
            XCTAssertGreaterThan(drawn, 0, "C11: the day asked for is not drawn in Calendar's first frame shown")
        }
    }

    /// The day rolls over while Calendar is hidden (the system's day-changed
    /// notice, which the page's model observes; not the now line's minute
    /// clock): no hidden Calendar view runs, and in the first frame with
    /// Calendar shown its model and every agenda day drawn have the new today.
    func testC12ADayRolloverWhileCalendarIsHiddenIsInItsFirstFrame() throws {
        var clock = Date()
        CalendarPageState.now = { clock }
        defer { CalendarPageState.now = nil }
        try withRig { rig in
            rig.state.panelDidReveal()
            pump(rig.content, rig.panel)
            XCTAssertEqual(rig.state.selectedSection, PanelPage.tasks.section, "harness: Tasks is shown")
            let calendar = CalendarMonthMath.calendar()
            XCTAssertEqual(rig.calendarModel.snapshot.today, DueDay(date: clock, calendar: calendar),
                           "harness: the page's model runs on the test's clock")
            clock = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: clock))
            let next = DueDay(date: clock, calendar: calendar)
            let bodies = hiddenCalendarBodies()
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            pump(rig.content, rig.panel)
            XCTAssertEqual(hiddenCalendarBodies().subtracting(bodies), [:],
                           "C12: a hidden Calendar view's body ran on a day rollover")
            let drawnBefore = CalendarAgendaDay.bodyEvaluationsByDay
            var today: DueDay?
            var drawnTodays: [DueDay: DueDay] = [:]
            inFirstShownFrame(of: .calendar, rig, switching: {
                rig.state.switchPage(to: PanelPage.calendar.section, motion: .instant)
            }, read: {
                today = rig.calendarModel.snapshot.today
                for (day, count) in CalendarAgendaDay.bodyEvaluationsByDay where count != drawnBefore[day, default: 0] {
                    drawnTodays[day] = CalendarAgendaDay.todayByDay[day]
                }
            })
            XCTAssertEqual(today, next, "C12: Calendar's first frame shown has the day it was hidden on as today")
            XCTAssertFalse(drawnTodays.isEmpty, "C12: no agenda day was drawn in Calendar's first frame shown")
            XCTAssertEqual(drawnTodays.filter { $0.value != next }.keys.sorted { "\($0)" < "\($1)" }, [],
                           "C12: agenda days drawn in Calendar's first frame shown with the old today")
        }
    }
}

private extension Dictionary where Key == String, Value == Int {
    /// The counts that moved since `before`, by how much.
    func subtracting(_ before: [String: Int]) -> [String: Int] {
        reduce(into: [:]) { moved, entry in
            let delta = entry.value - before[entry.key, default: 0]
            if delta != 0 { moved[entry.key] = delta }
        }
    }
}

// MARK: - A press on something drawn over a row (PR 71 review round, 25 Nov): pins from the trunk's run lines

extension HiddenPagesCountersTests {
    @MainActor private func rcbPost(_ rig: Rig, _ events: [NSEvent]) {
        for event in events {
            NSApp.postEvent(event, atStart: false)
            Hosted.pumpEvents()
            pump(rig.content, rig.panel)
        }
    }

    /// The press and the release queued together before anything is pumped, as `Hosted.click` does: a view
    /// that tracks the mouse from its press (a text view) reads the release from the queue itself.
    @MainActor private func rcbClick(_ rig: Rig, at point: CGPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
        }
        Hosted.pumpEvents()
        pump(rig.content, rig.panel)
    }

    @MainActor private func rcbKey(_ rig: Rig, _ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
        rcbPost(rig, try [NSEvent.EventType.keyDown, .keyUp].map { type in
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        })
    }

    /// More rows than the panel shows, so rows reach the bottom of the list's viewport.
    @MainActor private func rcbFill(_ rig: Rig) {
        let context = ModelContext(rig.container)
        let now = Date()
        for index in 0..<18 {
            let item = TaskItem(title: "Filler \(index)", status: .todo, priority: .none,
                                createdAt: now.addingTimeInterval(Double(-(100 + index) * 60)),
                                manualOrder: 9_000_000 + Int64(index) * 1_024, parentID: nil)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try? context.save()
        rig.tasks.refresh()
        pump(rig.content, rig.panel, seconds: 0.8)
    }

    /// Accessibility elements whose label or identifier matches, with their frames in window points (bottom origin).
    @MainActor private func rcbAX(_ rig: Rig, _ wanted: (_ label: String, _ identifier: String) -> Bool) -> [(what: String, frame: CGRect)] {
        var found: [(what: String, frame: CGRect)] = []
        func walk(_ element: AnyObject, depth: Int) {
            let label = element.accessibilityLabel?() ?? ""
            let identifier = element.accessibilityIdentifier?() ?? ""
            if wanted(label, identifier), let rect: CGRect = element.accessibilityFrame?(), rect.width > 1 {
                let origin = rig.panel.convertPoint(fromScreen: rect.origin)
                let entry = (what: "\(identifier.isEmpty ? "" : identifier + ":")\(label.prefix(28))", frame: CGRect(origin: origin, size: rect.size))
                if !found.contains(where: { $0.what == entry.what && $0.frame == entry.frame }) { found.append(entry) }
            }
            guard depth > 0, let children = element.accessibilityChildren?() else { return }
            for child in children { walk(child as AnyObject, depth: depth - 1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        for root in [rig.content] + all(rig.content).filter({ $0 is NSHostingView<AnyView> || String(describing: type(of: $0)).contains("Hosting") }) { walk(root, depth: 50) }
        return found
    }

    @MainActor private func rcbToastParts(_ rig: Rig) -> [(what: String, frame: CGRect)] {
        let message = rig.page.toasts.current?.message ?? "\u{0}"
        return rcbAX(rig) { label, identifier in identifier == "panel-undo-toast" || label.contains(message) || label.hasPrefix("Undo") }
    }

    @MainActor private func rcbShow(_ frame: CGRect) -> String { "x\(Int(frame.minX))-\(Int(frame.maxX)) y\(Int(frame.minY))-\(Int(frame.maxY))" }


    /// A press inside the open "+" card, where the card stands over a row,
    /// puts no cursor on the row beneath, then or after the card closes
    /// (the trunk, t10: `F2b after-press cursor=nil`, `F2b card-closed cursor=nil`).
    func testAPressInTheOpenCardPutsNoCursorOnTheRowBeneath() throws {
        try requireKeyWindowTests()
        try withRig { rig in
            rig.panel.makeKey()
            pump(rig.content, rig.panel)
            rcbFill(rig)
            let ids = rig.page.rows(for: .now).map(\.id)
            let first = try XCTUnwrap(rig.page.agentRowFrames([ids[1]]).first?.frame, "harness: row 1 is on the page")
            try rcbClick(rig, at: CGPoint(x: first.minX + min(120, first.width / 2), y: first.midY))
            pump(rig.content, rig.panel, seconds: 0.3)
            XCTAssertEqual(rig.page.selection, [ids[1]], "harness: a click selected row 1")
            openCard(rig)
            pump(rig.content, rig.panel, seconds: 1.5)
            let field = try XCTUnwrap((rig.panel.firstResponder as? NSView).map { $0.convert($0.bounds, to: nil) }, "harness: the card's field holds the keyboard")
            let frames = rig.page.agentRowFrames(nil)
            var point: CGPoint?
            for y in stride(from: field.maxY - 3, through: field.minY + 3, by: -3) where point == nil {
                if frames.contains(where: { $0.frame.contains(CGPoint(x: field.midX, y: y)) }) { point = CGPoint(x: field.midX, y: y) }
            }
            try rcbClick(rig, at: try XCTUnwrap(point, "harness: a row lies under the card's field"))
            pump(rig.content, rig.panel, seconds: 0.5)
            XCTAssertNil(rig.page.keyboardFocus, "no cursor on the row under the card")
            closeCard(rig)
            pump(rig.content, rig.panel, seconds: 0.5)
            XCTAssertNil(rig.page.keyboardFocus, "nor after the card closed")
            XCTAssertEqual(rig.page.selection, [ids[1]], "the selection is as it was")
        }
    }

    /// Nothing selected and the keyboard on the panel: a press on the Undo
    /// toast's words, where the toast lies over a row, puts no cursor on
    /// that row, and ⌘D then duplicates nothing (the trunk, t10: `P21-body
    /// after-press cursor=nil selection=[]`, `cmdD tasks=25->25 new=["none"]`).
    func testAPressOnTheToastPutsNoCursorOnTheRowBeneath() throws {
        try requireKeyWindowTests()
        try withRig { rig in
            rig.panel.makeKey()
            pump(rig.content, rig.panel)
            rcbFill(rig)
            let ids = rig.page.rows(for: .now).map(\.id)
            rig.page.toasts.holdDuration = 60
            _ = rig.page.delete([ids[0]])
            pump(rig.content, rig.panel, seconds: 1)
            rig.page.clearSelection()
            rig.panel.makeFirstResponder(nil)
            pump(rig.content, rig.panel, seconds: 0.3)
            XCTAssertNotNil(rig.page.toasts.current, "harness: the Undo toast is up")
            XCTAssertNil(rig.page.keyboardFocus, "harness: no cursor before the press")
            // The toast by accessibility when it answers; else by geometry: it hugs its words, centred,
            // `toastHeight` high, standing on the notices' bottom padding.
            let middle = rig.panel.frame.width / 2
            let toast = rcbToastParts(rig).first { $0.what.hasPrefix("panel-undo-toast") }?.frame
                ?? CGRect(x: middle - 40, y: PanelNoticeClearanceProbe.lastBottomPadding, width: 80, height: AtticControlSize.toastHeight)
            let point = CGPoint(x: middle - 30, y: toast.midY)
            XCTAssertTrue(toast.contains(point), "harness: the press is on the toast")
            XCTAssertTrue(rig.page.agentRowFrames(nil).contains { $0.frame.contains(point) }, "harness: a row lies under the toast there")
            try rcbClick(rig, at: point)
            pump(rig.content, rig.panel, seconds: 0.6)
            XCTAssertNil(rig.page.keyboardFocus, "no cursor on the row under the toast")
            XCTAssertEqual(rig.page.selection, [], "and nothing selected")
            let before = rig.tasks.tasks.filter { $0.deletedAt == nil }.count
            try rcbKey(rig, 2, "d", .command)
            pump(rig.content, rig.panel, seconds: 1.2)
            XCTAssertEqual(rig.tasks.tasks.filter { $0.deletedAt == nil }.count, before, "⌘D duplicated nothing")
        }
    }
}

// MARK: - Notes and Draw in kept hosts (speed/page-host-notes-draw; the lead's ruling, 27 Nov)

/// The lead's conditions for moving Notes into a host of its own (Draw
/// follows in its own pull request): every leave hook runs no later than on
/// the trunk, by the new page's first frame; the first responder after the
/// switch is the trunk's; the shell's notice clearance is the trunk's with
/// Notes shown and hidden; and the common paths are right in their first
/// frame shown.
@MainActor
extension HiddenPagesCountersTests {
    /// The ways a switch leaves a page: ⌘-digit (the header's shortcut),
    /// a click on the island (the shell's `selectPage`), and the state's own
    /// switch (the agent's and the menu's `uiState.selectSection`, as
    /// `AppCoordinator` calls it).
    private enum LeavePath: String, CaseIterable { case shortcut, click, state }

    private static let switchDigits: [PanelPage: (UInt16, String)] = [.tasks: (18, "1"), .notes: (19, "2"), .calendar: (20, "3"), .canvas: (21, "4")]

    private func keyEvents(_ rig: Rig, code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> [NSEvent] {
        try [NSEvent.EventType.keyDown, .keyUp].map { type in
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
    }

    private func sentinel(_ rig: Rig) throws -> NSEvent {
        try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.panel.windowNumber,
                                         context: nil, subtype: 0x4E44, data1: 0, data2: 0))
    }

    /// Switches to `page` by `path`, then in the same turn presses `x`: the
    /// events are queued back to back and delivered as the app delivers
    /// them (`Hosted.pumpEvents`), with no layout or display forced. `atKey`
    /// runs as the key comes up for delivery (a sentinel event queued just
    /// before it); `afterKey` once it was handled.
    private func switchThenKey(_ rig: Rig, to page: PanelPage, by path: LeavePath,
                               atKey: @escaping () -> Void, afterKey: () -> Void) throws {
        let (code, digit) = try XCTUnwrap(Self.switchDigits[page])
        let sentinelEvent = try sentinel(rig)
        let key = try keyEvents(rig, code: 7, "x")
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            if event.subtype.rawValue == 0x4E44 { atKey() }
            return event
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        switch path {
        case .shortcut:
            for event in try keyEvents(rig, code: code, digit, .command) { NSApp.postEvent(event, atStart: false) }
        case .click:
            rig.state.island.click(page)
        case .state:
            rig.state.selectSection(page.section)
        }
        NSApp.postEvent(sentinelEvent, atStart: false)
        for event in key { NSApp.postEvent(event, atStart: false) }
        Hosted.pumpEvents()
        afterKey()
    }

    private func editors(_ rig: Rig) -> [NoteEditorTextView] {
        func walk(_ view: NSView) -> [NoteEditorTextView] {
            ((view as? NoteEditorTextView).map { [$0] } ?? []) + view.subviews.flatMap(walk)
        }
        return walk(rig.content)
    }

    private func storedText(_ rig: Rig, _ id: UUID) -> String {
        let context = ModelContext(rig.container)
        return ((try? context.fetch(FetchDescriptor<NoteItem>())) ?? []).first { $0.id == id && $0.deletedAt == nil }?.plainText ?? "<missing>"
    }

    private func responderName(_ rig: Rig, editor: NSView?) -> String {
        guard let responder = rig.panel.firstResponder else { return "nil" }
        if let editor, responder === editor { return "editor" }
        if let view = responder as? NSView {
            var membership: PanelKeyboardMembership?
            var walker: NSView? = view
            while membership == nil, let current = walker {
                membership = PanelPageKeyboard.membership(of: current)
                walker = current.superview
            }
            return "\(type(of: view))@\(membership.map { "\($0)" } ?? "none")"
        }
        return "\(type(of: responder))"
    }

    /// The Tasks row with the cursor, by its index in Now.
    private func focusRow(_ rig: Rig) -> String {
        guard let focus = rig.page.keyboardFocus else { return "nil" }
        return rig.page.rows(for: .now).firstIndex { $0.id == focus.id }.map { "now[\($0)]" } ?? "other"
    }

    /// Shows Notes by a click, opens a free note and puts the keyboard in its editor.
    private func focusANotesEditor(_ rig: Rig) throws -> (NoteEditorTextView, UUID) {
        rig.panel.makeKey()
        rig.state.panelDidReveal()
        rig.state.island.click(.notes)
        pump(rig.content, rig.panel)
        XCTAssertEqual(rig.state.selectedSection, .notes, "harness: Notes is shown")
        let id = rig.seed.freeNotes[0]
        XCTAssertEqual(wait { await rig.draft.pages.openFromLibrary(noteID: id) }, true, "harness: the note opened")
        rig.notesLibrary.dismissAfterOpenedNote(rig.draft.pages, requestedQuery: "")
        pump(rig.content, rig.panel)
        let editor = try XCTUnwrap(editors(rig).first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.isSuspended },
                                   "harness: the open note's editor is on screen")
        XCTAssertTrue(rig.panel.makeFirstResponder(editor), "harness: the editor took the keyboard")
        pump(rig.content, rig.panel)
        XCTAssertTrue(rig.panel.firstResponder === editor, "harness: the editor holds the keyboard")
        return (editor, id)
    }

    /// After a switch's events were handled: the run loop's own turns, one
    /// at a time with nothing forced (as the app runs), then frames as the
    /// display cycle draws them. Each change of `state` is logged with the
    /// turn it showed in; the first turn in which the shell ran is marked.
    private func leaveSequence(_ rig: Rig, shellBefore: Int, _ state: () -> String) -> String {
        var log: [String] = []
        var last = state()
        log.append("key:" + last)
        var shellSeen = Self.shellRuns > shellBefore
        if shellSeen { log.append("key:SHELL") }
        for turn in 0..<40 {
            if turn < 20 {
                CFRunLoopRunInMode(.defaultMode, 0, true)
            } else {
                frame(rig)
                CFRunLoopRunInMode(.defaultMode, 0.005, true)
            }
            let label = turn < 20 ? "t\(turn)" : "f\(turn - 20)"
            if !shellSeen, Self.shellRuns > shellBefore { shellSeen = true; log.append("\(label):SHELL") }
            let now = state()
            if now != last { log.append("\(label):" + now); last = now }
        }
        return log.joined(separator: " ")
    }

    /// (a), (b) and (c) of the ruling for Notes, on each leave path: with the
    /// editor focused and an unsaved word typed, a switch to Tasks and a key
    /// queued in the same turn. Printed for the trunk comparison: the state
    /// when the key comes up, then each run-loop turn's changes (Notes' key
    /// monitor, the editor's suspension, the first responder, the stored
    /// word) and the first shell pass. Asserted: by the first frame with
    /// Tasks shown, the monitor is gone, the editor is suspended and does
    /// not hold the keyboard, and the typed word is stored; settled, the
    /// keyboard is Tasks', as on the trunk.
    func testND2NotesLeavesInTheSwitchsTurnOnEveryPath() throws {
        try requireKeyWindowTests()
        for path in LeavePath.allCases {
            try withRig { rig in
                let (editor, id) = try focusANotesEditor(rig)
                let monitorsShown = NotesPageChrome.installedKeyMonitors
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
                editor.insertText(" zq7", replacementRange: editor.selectedRange())
                let typed = editor.string
                XCTAssertTrue(typed.hasSuffix(" zq7"), "harness: the word was typed")
                let shellBefore = Self.shellRuns
                @MainActor func state() -> String {
                    "mon=\(NotesPageChrome.installedKeyMonitors - monitorsShown) susp=\(editor.isSuspended ? 1 : 0) "
                        + "resp=\(responderName(rig, editor: editor)) saved=\(storedText(rig, id).contains("zq7") ? 1 : 0) "
                        + "x=\(editor.string.hasSuffix("zq7x") ? 1 : 0)"
                }
                var atKey = ""
                try switchThenKey(rig, to: .tasks, by: path, atKey: { atKey = state() }, afterKey: {})
                var shellAtFirstFrame = false
                var hooksAtFirstFrame = ""
                let sequence = leaveSequence(rig, shellBefore: shellBefore) {
                    let now = state()
                    if !shellAtFirstFrame, Self.shellRuns > shellBefore { shellAtFirstFrame = true; hooksAtFirstFrame = now }
                    return now
                }
                pump(rig.content, rig.panel)
                print("ND_LEAVE notes path=\(path.rawValue) at_key{\(atKey)} seq{\(sequence)} first{\(hooksAtFirstFrame)} "
                      + "settled{\(state()) focus=\(focusRow(rig))}")
                XCTAssertEqual(rig.state.selectedSection, .tasks, "ND2 \(path): Tasks is shown")
                XCTAssertTrue(shellAtFirstFrame, "harness ND2 \(path): the shell ran after the switch")
                XCTAssertTrue(hooksAtFirstFrame.hasPrefix("mon=-1 susp=1 "), "ND2 \(path): Notes' hooks had not run by the first frame (\(hooksAtFirstFrame))")
                XCTAssertFalse(hooksAtFirstFrame.contains("resp=editor"), "ND2 \(path): the editor held the keyboard in the first frame")
                XCTAssertTrue(storedText(rig, id).contains("zq7"), "ND2 \(path): the typed word was not stored")
                XCTAssertTrue(responderIsTasks(rig), "ND2 \(path): settled on Tasks, the keyboard is not Tasks' (\(responderName(rig, editor: editor)))")
                // (a): red on the trunk too (fka runs 45951126247 and 45951136189).
                // The fix is its own keyboard-ownership pull request; it deletes this marker.
                XCTExpectFailure("NOTES-KEY-AFTER-LEAVE-SAVED (board): a key queued behind the switch reaches the note's editor "
                                 + "and is saved, on the trunk as well", strict: true) {
                    XCTAssertFalse(editor.string.hasSuffix("zq7x"), "ND2 \(path): the key queued behind the switch reached the note's editor")
                    XCTAssertFalse(storedText(rig, id).contains("zq7x"), "ND2 \(path): the key queued behind the switch reached the stored note")
                }
            }
        }
    }

    /// Whether the first responder is Tasks' (a Tasks tab host, or a view in one), as on the trunk after a switch to Tasks.
    private func responderIsTasks(_ rig: Rig) -> Bool {
        var walker = rig.panel.firstResponder as? NSView
        while let view = walker {
            if let host = view as? KeptContentHostingView { return Self.isTasksHost(host) }
            walker = view.superview
        }
        return false
    }

    /// Notes leaves in the panel's own update, before any pass of its host
    /// (`KeptContentHost.laysOutOnLeave`): with the switch made and only the
    /// panel's host laid out, Notes' key monitor is already gone, the editor
    /// is suspended and it no longer holds the keyboard.
    func testND8NotesLeavesInThePanelsOwnUpdate() throws {
        try requireKeyWindowTests()
        try withRig { rig in
            let (editor, _) = try focusANotesEditor(rig)
            func panelHost(_ view: NSView) -> AtticPanelHostingView? {
                (view as? AtticPanelHostingView) ?? view.subviews.lazy.compactMap(panelHost).first
            }
            let host = try XCTUnwrap(rig.panel.contentView.flatMap(panelHost), "harness: the panel's host")
            XCTAssertFalse(editor.isSuspended, "harness: the editor is live before the switch")
            let monitors = NotesPageChrome.installedKeyMonitors
            rig.state.selectSection(.tasks)
            host.layout()
            let monitorsAfter = NotesPageChrome.installedKeyMonitors - monitors
            let suspended = editor.isSuspended
            let responder = responderName(rig, editor: editor)
            print("ND_INTURN mon=\(monitorsAfter) susp=\(suspended ? 1 : 0) resp=\(responder)")
            XCTAssertEqual(monitorsAfter, -1, "ND8: after the panel's update alone, Notes' key monitor was still installed")
            XCTAssertTrue(suspended, "ND8: after the panel's update alone, Notes' editor was not suspended")
            XCTAssertNotEqual(responder, "editor", "ND8: after the panel's update alone, the editor held the keyboard")
            pump(rig.content, rig.panel)
        }
    }

    /// Notes' library stops its keys by the first frame after a switch
    /// away (`NotesLibraryView`, `onChange(of: isCurrent)`), as its editor's
    /// hooks do (ND2).
    func testND9NotesLibraryStopsItsKeysByTheFirstFrameAway() throws {
        try requireKeyWindowTests()
        var keys: [NotesLibraryKeys] = []
        NotesLibraryView.lifetimeProbe = { keys.append($0) }
        defer { NotesLibraryView.lifetimeProbe = nil }
        try withRig { rig in
            rig.panel.makeKey()
            rig.state.panelDidReveal()
            inFirstShownFrame(of: .notes, rig, switching: { rig.state.island.click(.notes) }, read: {})
            pump(rig.content, rig.panel)
            let shownKeys = try XCTUnwrap(keys.last, "harness: Notes' library appeared")
            XCTAssertNotNil(shownKeys.handler, "harness: Notes is shown on its library, with its keys on")
            var handlerAtFirstFrame = true
            inFirstShownFrame(of: .tasks, rig, switching: { rig.state.island.click(.tasks) }, read: {
                handlerAtFirstFrame = shownKeys.handler != nil
            })
            print("ND_LIBKEYS keys_on_at_first_frame_away=\(handlerAtFirstFrame)")
            XCTAssertFalse(handlerAtFirstFrame, "ND9: Notes' library still had its keys in the first frame away")
        }
    }

    /// Notes' first show ever, recorded by the rig: the shell's clearance in
    /// that first frame, and Notes' own once settled.
    private static var firstEverNotesShow: (shell: CGFloat?, own: CGFloat?) = (nil, nil)

    /// The shell's notice clearance (`AtticPanelView.lastNoticeClearance`)
    /// with Notes shown is Notes' own (`NotesEditorPage.noticeClearance`),
    /// in the first frame shown: on Notes' first show ever, and on the first
    /// show after a resize while it was hidden. Notes' own preference reaches
    /// the shell across its kept host; with it removed the shell reads the
    /// key's default (20, run 46001199605) and this fails. With Notes hidden,
    /// Tasks' first frame has its settled value.
    func testND4NoticeClearanceIsNotesOwnFromItsFirstFrameShown() throws {
        try requireKeyWindowTests()
        try withRig { rig in
            let first = Self.firstEverNotesShow
            rig.state.island.click(.notes)
            pump(rig.content, rig.panel)
            var hiddenFirst: CGFloat?
            inFirstShownFrame(of: .tasks, rig, switching: { rig.state.island.click(.tasks) }, read: {
                hiddenFirst = AtticPanelView.lastNoticeClearance
            })
            pump(rig.content, rig.panel)
            let hiddenSettled = AtticPanelView.lastNoticeClearance
            let size = rig.state.panelSize
            resize(rig, to: CGSize(width: size.width + 40, height: size.height + 30))
            pump(rig.content, rig.panel)
            var shownFirst: CGFloat?
            inFirstShownFrame(of: .notes, rig, switching: { rig.state.island.click(.notes) }, read: {
                shownFirst = AtticPanelView.lastNoticeClearance
            })
            pump(rig.content, rig.panel)
            let own = NotesEditorPage.lastOwnNoticeClearance
            let shownSettled = AtticPanelView.lastNoticeClearance
            func text(_ value: CGFloat?) -> String { value.map { "\($0)" } ?? "nil" }
            print("ND_CLEAR first_ever shell=\(text(first.shell)) own=\(text(first.own)) tasks_first=\(text(hiddenFirst)) "
                  + "tasks_settled=\(text(hiddenSettled)) after_resize notes_first=\(text(shownFirst)) own=\(text(own)) "
                  + "notes_settled=\(text(shownSettled))")
            XCTAssertNotNil(first.own, "harness: Notes' page reported its clearance on its first show")
            XCTAssertNotEqual(first.own, PanelPageNoticeClearancePreferenceKey.defaultValue,
                              "harness: Notes' clearance is not the key's default, so the check means something")
            XCTAssertEqual(first.shell, first.own, "ND4: on Notes' first show ever, the shell's first frame has another clearance than Notes'")
            XCTAssertEqual(shownFirst, own, "ND4: after a resize while hidden, Notes' first frame shown has another clearance than Notes'")
            XCTAssertEqual(shownSettled, own, "ND4: settled on Notes, the shell's clearance is not Notes'")
            XCTAssertEqual(hiddenFirst, hiddenSettled, "ND4: Tasks' first frame has another clearance than when settled")
            resize(rig, to: size)
            pump(rig.content, rig.panel)
        }
    }

    /// A page's kept host, if it has one.
    private func keptHost(_ page: PanelPage, _ rig: Rig) -> KeptContentHostingView? {
        func hosts(_ view: NSView) -> [KeptContentHostingView] {
            ((view as? KeptContentHostingView).map { [$0] } ?? []) + view.subviews.flatMap(hosts)
        }
        return hosts(rig.content).first { PanelPageKeyboard.membership(of: $0) == .page(page) }
    }

    /// The target: hidden behind Tasks, Notes is in a host of its own that
    /// is neither drawn nor laid out through a live resize, its release and
    /// a write outside a drag, and its views do not run.
    func testND1HiddenNotesSitsOutAResize() throws {
        try withRig { rig in
            let pages: [PanelPage] = [.notes]
            let hosts = Dictionary(uniqueKeysWithValues: pages.map { ($0, keptHost($0, rig)) })
            let layoutsBefore = hosts.mapValues { $0.map { KeptContentHostCounts.layoutsByHost[ObjectIdentifier($0), default: 0] } ?? -1 }
            var drawnAt: [String] = []
            var resizing: [String: Int] = [:]
            @MainActor func add(_ label: String, _ counts: [String: Int]) {
                resizing.merge(counts) { $0 + $1 }
                for page in pages where (hosts[page] ?? nil)?.isDrawn == true { drawnAt.append("\(page)@\(label)") }
            }
            let start = rig.state.panelSize
            add("lock-on", measure(rig, "ND1 lock-on") { rig.state.setInteractionLock(.windowResize, isActive: true) })
            for step in 1...Self.dragSteps {
                add("step=\(step)", measure(rig, "ND1 write step=\(step)") { resize(rig, to: dragSize(start, step: step)) })
            }
            add("release", measure(rig, "ND1 release") { release(rig) })
            add("outside", measure(rig, "ND1 outside a drag") { resize(rig, to: dragSize(start, step: Self.dragSteps + 2)) })
            let layoutsAfter = hosts.mapValues { $0.map { KeptContentHostCounts.layoutsByHost[ObjectIdentifier($0), default: 0] } ?? -1 }
            print("HIDDEN_COUNTS ND1 resize-total " + Self.line(resizing))
            print("HIDDEN_COUNTS ND1 hosts=\(hosts.mapValues { $0 != nil }) drawn_at=\(drawnAt) layouts=\(layoutsBefore)->\(layoutsAfter)")
            for page in pages {
                for view in Self.hiddenPageViews[page, default: []] {
                    XCTAssertEqual(resizing[view, default: 0], 0, "ND1: \(page)'s \(view) ran while hidden through a resize")
                }
                if (hosts[page] ?? nil) != nil {
                    XCTAssertEqual(layoutsAfter[page], layoutsBefore[page], "ND1: hidden, \(page)'s host was laid out")
                } else {
                    XCTFail("ND1: \(page) sits in a kept host of its own")
                }
            }
            XCTAssertEqual(drawnAt, [], "ND1: a hidden host was drawn")
        }
    }

    /// A plain switch away from Calendar and from Notes: the layouts each
    /// host takes from the switch until its hide's turn has ended (reported
    /// against the trunk's rule), and a resize straight after that turn,
    /// which neither host takes: no layout, no hidden view run.
    func testND7APlainSwitchsHideLayoutsAndAResizeStraightAfter() throws {
        try withRig { rig in
            for page in [PanelPage.calendar, .notes] {
                rig.state.selectSection(page.section)
                pump(rig.content, rig.panel)
                guard let host = keptHost(page, rig) else {
                    XCTFail("ND7: \(page) sits in a kept host of its own")
                    continue
                }
                let id = ObjectIdentifier(host)
                let before = KeptContentHostCounts.layoutsByHost[id, default: 0]
                let passesBefore = KeptContentHostCounts.passesOfTheHide[id, default: 0]
                rig.state.selectSection(.tasks)
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    CFRunLoopRunInMode(.defaultMode, 0.005, true)
                    rig.content.layoutSubtreeIfNeeded()
                    rig.panel.displayIfNeeded()
                } while host.isDrawn && Date() < deadline
                XCTAssertFalse(host.isDrawn, "harness: \(page) was hidden")
                // The hide's turn ends (the run loop waits once).
                CFRunLoopRunInMode(.defaultMode, 0.02, false)
                let atHide = KeptContentHostCounts.layoutsByHost[id, default: 0] - before
                let views = snapshot(rig)
                let layouts = KeptContentHostCounts.layoutsByHost[id, default: 0]
                let size = rig.state.panelSize
                resize(rig, to: CGSize(width: size.width + 8, height: size.height + 4))
                pump(rig.content, rig.panel)
                let ran = Self.diff(snapshot(rig), views)
                let resizeLayouts = KeptContentHostCounts.layoutsByHost[id, default: 0] - layouts
                let passes = KeptContentHostCounts.passesOfTheHide[id, default: 0] - passesBefore
                print("ND_HIDECOUNT \(page) switch_to_hide_end_layouts=\(atHide) hide_turn_passes=\(passes) resize_after_layouts=\(resizeLayouts) views=\(Self.line(ran))")
                if page == .calendar {
                    XCTAssertEqual(passes, 0, "ND7: a switch away from Calendar gave its host passes of a hide turn")
                }
                XCTAssertEqual(resizeLayouts, 0, "ND7: hidden, \(page)'s host was laid out by a resize straight after the switch")
                for view in Self.hiddenPageViews[page, default: []] {
                    XCTAssertEqual(ran[view, default: 0], 0, "ND7: \(page)'s \(view) ran while hidden through a resize straight after the switch")
                }
                resize(rig, to: size)
                pump(rig.content, rig.panel)
            }
        }
    }

    /// The first frame shown of the gate's common Notes paths: a note open
    /// in the editor changed in the store while Notes was hidden (as the
    /// composer's or the agent's write lands), and a note opened from Tasks
    /// (the composer's `openNote`: the switch, then the open a turn later).
    /// In each, the first frame in which the note is the active one shows
    /// the editor with the text and width it has once settled.
    func testND5NotesPathsAreRightInTheirFirstFrameShown() throws {
        try requireKeyWindowTests()
        // A note changed while Notes was hidden.
        try withRig { rig in
            let (_, id) = try focusANotesEditor(rig)
            rig.state.island.click(.tasks)
            pump(rig.content, rig.panel)
            let note = try XCTUnwrap(rig.notes.note(withID: id))
            let changed = try NoteAgentTextParser.document(title: "Free note 1", body: "Changed while hidden.", base: .blank)
            if case let .failure(error) = rig.notes.saveDocument(noteID: id, document: changed, baseRevisionID: note.revisionID) {
                XCTFail("harness: the hidden note's write failed: \(error)")
            }
            pump(rig.content, rig.panel)
            var first: (String, CGFloat)?
            inFirstShownFrame(of: .notes, rig, switching: { rig.state.island.click(.notes) }, read: {
                first = self.editors(rig).first { !$0.isSuspended }.map { ($0.string, $0.bounds.width) }
            })
            pump(rig.content, rig.panel)
            let settled = editors(rig).first { !$0.isSuspended }.map { ($0.string, $0.bounds.width) }
            print("ND_FIRST changed-hidden first=\(first.map { "\($0.0.contains("Changed while hidden")) w=\($0.1)" } ?? "nil") "
                  + "settled=\(settled.map { "\($0.0.contains("Changed while hidden")) w=\($0.1)" } ?? "nil")")
            XCTAssertEqual(first?.0, settled?.0, "ND5 changed while hidden: the first frame's text is not the settled text")
            XCTAssertEqual(first?.1 ?? -1, settled?.1 ?? -2, accuracy: 0.5, "ND5 changed while hidden: the first frame's width")
        }
        // A note opened from Tasks.
        try withRig { rig in
            rig.panel.makeKey()
            rig.state.panelDidReveal()
            pump(rig.content, rig.panel)
            let id = rig.seed.freeNotes[1]
            var frames: [(active: Bool, text: String?, width: CGFloat?)] = []
            rig.composer.services.openNote(id)
            waitForTestOperation("the opened note's first frame") {
                frame(rig)
                let active = rig.draft.pages.active?.noteID == id && !rig.draft.pages.isLibraryPresented
                let editor = editors(rig).first { !$0.isSuspended && !$0.isHiddenOrHasHiddenAncestor }
                frames.append((active, editor?.string, editor?.bounds.width))
                return active || frames.count > 400
            }
            let firstActive = frames.last
            pump(rig.content, rig.panel)
            let settled = editors(rig).first { !$0.isSuspended && !$0.isHiddenOrHasHiddenAncestor }
            print("ND_FIRST open-from-tasks frames=\(frames.count) first_active{text=\(firstActive?.text?.contains("Free note 2") ?? false) "
                  + "w=\(firstActive?.width ?? -1)} settled{text=\(settled?.string.contains("Free note 2") ?? false) w=\(settled?.bounds.width ?? -1)}")
            XCTAssertEqual(rig.state.selectedSection, .notes, "ND5 open from Tasks: Notes is shown")
            XCTAssertEqual(firstActive?.text, settled?.string, "ND5 open from Tasks: the first frame with the note active shows other text")
            XCTAssertEqual(firstActive?.width ?? -1, settled?.bounds.width ?? -2, accuracy: 0.5,
                           "ND5 open from Tasks: the first frame with the note active has another width")
        }
    }
}
