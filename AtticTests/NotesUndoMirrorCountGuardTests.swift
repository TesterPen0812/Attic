import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// speed-mech5-undo-mirror: the Notes controller's copy of the app's Undo
/// revision (reading: hunt-13nov/reports/hidden-counters/MECH5-READING.md).
///
/// The real `AtticPanelView` in an offscreen `AtticPanel` (never on a
/// display, never key), wired as `AppCoordinator` wires it: the Notes
/// controller on the library's one Undo route, the workspace lifecycle on a
/// file store in an owned temporary folder. Every step lets the main queue
/// drain (an expectation, no fixed wait), then lays out and draws, until
/// the counted views stop moving.
///
/// - The count guard: a Tasks tick and a priority change record a step on
///   the route, and nothing in the hidden Notes and Calendar pages reads
///   it, so none of their hosts runs.
/// - The guards for what still reads the route: with Notes in front and
///   hidden, a Tasks step that evicts the Notes library's history ends the
///   delete toast and its Undo items; a text edit's unsaved state still
///   reaches the panel's locks; the library's Undo and Redo items follow a
///   library action; the toast's own Undo restores the note.
@MainActor
final class NotesUndoMirrorCountGuardTests: XCTestCase {
    private final class PageBox {
        weak var chrome: NotesPageChrome?
        weak var library: NotesLibraryModel?
    }

    private struct Rig {
        let tasks: TaskStore
        let notes: NoteStore
        let library: AtticLibrary
        let draft: NoteDraftController
        let state: PanelUIState
        let toasts: PanelToastCenter
        let content: NSView
        let panel: NSWindow
        let page: TasksPageModel
        let pageBox: PageBox
        let plain: [UUID]
        let freeNotes: [UUID]
        @MainActor var controller: NotesPageController { draft.pages }
    }

    /// The views that must not run on a Tasks step nothing in them reads.
    private static let hidden = ["NotesPageHost", "NotesEditorPage", "NotesLibraryView",
                                 "CalendarPageHost", "CalendarPage", "route.notes", "route.calendar"]
    /// Printed beside them, not asserted: the route host that wraps the
    /// Tasks page in front.
    private static let columns = hidden + ["route.tasks", "route.revision"]

    // MARK: - Rig

    private func seedTasks(in container: ModelContainer) throws -> [UUID] {
        let context = ModelContext(container)
        let now = Date()
        var ids: [UUID] = []
        for index in 0..<4 {
            let item = TaskItem(title: "Plain task \(index + 1)", status: .todo, priority: .none,
                                createdAt: now.addingTimeInterval(Double(-index * 60)),
                                manualOrder: 1_000_000 + Int64(index) * 1_024, parentID: nil)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
            ids.append(item.id)
        }
        try context.save()
        return ids
    }

    private func seedNotes(_ notes: NoteStore) throws -> [UUID] {
        try (1...3).map { index in
            let id = UUID()
            let title = "Free note \(index)"
            let document = try NoteAgentTextParser.document(title: title, body: "A line for \(title).", base: .blank)
            if case let .failure(error) = notes.createDocumentNote(id: id, document: document, taskOwner: nil) {
                throw NSError(domain: "NotesUndoMirrorCountGuardTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "note \(title): \(error)"])
            }
            return id
        }
    }

    /// `undo` replaces the library's route (a small one makes a Tasks step
    /// evict the Notes library's history).
    private func withRig(undo: UndoRoute? = nil, _ body: (Rig) throws -> Void) throws {
        let root = ownedTemporaryDirectory(prefix: "NotesUndoMirror")
        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                storeDirectory: storeDirectory)
        let plain = try seedTasks(in: container)
        WorkspaceLegacyBridge.configureJournalDirectory(root.appendingPathComponent("NoteDrafts"), for: container)
        let workspace = try? WorkspaceLegacyBridge.coordinator(for: container)
        workspace?.beginLaunchRegistration()
        let tasks = TaskStore(container: container,
                              taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("TaskImages", isDirectory: true)))
        let notes = NoteStore(container: container,
                              attachmentFileStore: makeTestAttachmentFileStore(
                                  rootURL: root.appendingPathComponent("NoteAttachments", isDirectory: true)))
        let launched = expectation(description: "the workspace finished its launch")
        Task { @MainActor in
            try? await workspace?.finishLaunch()
            launched.fulfill()
        }
        wait(for: [launched], timeout: 10)
        let freeNotes = try seedNotes(notes)
        tasks.refresh()
        notes.refresh()

        let canvasStore = CanvasStore(container: container)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvasStore, undo: undo)
        let canvasSession = CanvasSession(store: canvasStore)
        let draft = NoteDraftController(noteStore: notes)
        let state = PanelUIState()
        draft.pages.didFollowNoteLink = { [weak state] in state?.selectSection(.notes) }
        draft.pages.attachUndoRoute(library.undo)
        draft.pages.workspaceTaskStore = tasks
        let toasts = PanelToastCenter()
        toasts.holdDuration = 600

        let suite = "NotesUndoMirror.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let tasksState = TasksPageState()
        let pageBox = PageBox()
        let previousProbe = NotesEditorPage.lifetimeProbe
        NotesEditorPage.lifetimeProbe = { [pageBox] chrome, model in
            pageBox.chrome = chrome
            pageBox.library = model
        }
        defer { NotesEditorPage.lifetimeProbe = previousProbe }
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: tasks, noteStore: notes, canvasSession: canvasSession,
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: AppSettings(defaults: defaults), toasts: toasts,
                                     tasksPageState: tasksState, calendarPageState: CalendarPageState(),
                                     composerState: PanelComposerState()),
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
            settle(content, panel)
            panel.orderOut(nil); panel.contentView = nil; panel.close()
        }

        // Notes visited and left on its library; every page built; Tasks current.
        state.selectSection(.notes)
        waitForTestOperation("the Notes page built", timeout: 10) {
            content.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            return pageBox.chrome != nil && pageBox.library != nil
        }
        XCTAssertTrue(draft.pages.showLibrary(), "harness: Notes goes to its library")
        settle(content, panel)
        state.selectSection(.tasks)
        for built in [PanelPage.calendar, .notes, .canvas] { state.prepareBuiltPage(built) }
        waitForTestOperation("every page built behind Tasks", timeout: 10) {
            content.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            return CalendarPageHost.bodyEvaluations > 0 && tasksState.builtModel != nil
        }
        settle(content, panel)

        XCTAssertEqual(state.selectedSection, .tasks, "harness: Tasks is current")
        XCTAssertTrue(Set(PanelPage.allCases).subtracting([.tasks]).isSubset(of: state.builtPages),
                      "harness: Notes, Calendar and Draw are built behind Tasks")
        XCTAssertTrue(draft.pages.isLibraryPresented, "harness: Notes rests on its library")
        XCTAssertTrue(draft.pages.undoRoute === library.undo, "harness: the Notes controller is on the app's Undo route")
        let page = try XCTUnwrap(tasksState.builtModel, "harness: the panel built the Tasks page")
        XCTAssertTrue(page.library === library, "harness: the Tasks page runs on the shared library")
        page.services.acknowledgementDelay = .seconds(600)

        try body(Rig(tasks: tasks, notes: notes, library: library, draft: draft, state: state, toasts: toasts,
                     content: content, panel: panel, page: page, pageBox: pageBox, plain: plain, freeNotes: freeNotes))
    }

    // MARK: - Settling and counting

    /// Drains the main queue, lays out and draws, until the counted views
    /// and the route have not moved for three rounds (at most 60 rounds).
    private func settle(_ content: NSView, _ panel: NSWindow) {
        var last = Self.views()
        var still = 0
        for _ in 0..<60 {
            let drained = expectation(description: "main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 5)
            content.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            let now = Self.views()
            if now == last {
                still += 1
                if still >= 3 { return }
            } else {
                still = 0
                last = now
            }
        }
    }

    private func settle(_ rig: Rig) { settle(rig.content, rig.panel) }

    private static func views() -> [String: Int] {
        [
            "NotesPageHost": NotesPageHost.bodyEvaluations,
            "NotesEditorPage": NotesEditorPage.bodyEvaluations,
            "NotesLibraryView": NotesLibraryView.bodyEvaluations,
            "CalendarPageHost": CalendarPageHost.bodyEvaluations,
            "CalendarPage": CalendarPage.bodyEvaluations,
            "route.notes": TaskNoteRouteHostCounts.bodyEvaluations[.notes, default: 0],
            "route.calendar": TaskNoteRouteHostCounts.bodyEvaluations[.calendar, default: 0],
            "route.tasks": TaskNoteRouteHostCounts.bodyEvaluations[.tasks, default: 0],
        ]
    }

    private func snapshot(_ rig: Rig) -> [String: Int] {
        var counts = Self.views()
        counts["route.revision"] = Int(truncatingIfNeeded: rig.library.undo.revision)
        return counts
    }

    /// One control between two snapshots; `saved` says the control's change
    /// reached the store before the views are settled and counted.
    private func measure(_ rig: Rig, _ label: String, _ control: () -> Void, saved: () -> Bool) -> [String: Int] {
        settle(rig)
        let before = snapshot(rig)
        control()
        waitForTestOperation("\(label) saved") { saved() }
        settle(rig)
        let after = snapshot(rig)
        var counts: [String: Int] = [:]
        for key in after.keys { counts[key] = after[key, default: 0] - before[key, default: 0] }
        print("UNDO_MIRROR_COUNTS \(label) " + Self.columns.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " "))
        return counts
    }

    // MARK: - The count guard (red before the cut)

    func testATickAndAPriorityChangeRunNoHiddenNotesOrCalendarHost() throws {
        try withRig { rig in
            let ticked = rig.plain[0]
            let tick = measure(rig, "tick", {
                rig.page.completeAcknowledged(ticked) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }, saved: { rig.tasks.task(withID: ticked)?.status == .done })

            // Printed, not asserted: a toast alone, no Tasks step (the
            // priority change posts one, the tick does not). It stays up
            // while the priority change is counted.
            _ = measure(rig, "toast only", { rig.toasts.show("Counted toast") {} },
                        saved: { rig.toasts.current?.message == "Counted toast" })

            let prioritised = rig.plain[1]
            let priority = measure(rig, "priority", {
                rig.page.setPriorityAcknowledged(.high, for: [prioritised]) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
            }, saved: { rig.tasks.task(withID: prioritised)?.priority == .high })

            for (label, counts) in [("tick", tick), ("priority", priority)] {
                XCTAssertGreaterThan(counts["route.revision", default: 0], 0,
                                     "harness: the \(label) recorded its step on the app's Undo route")
                for key in Self.hidden {
                    XCTAssertEqual(counts[key, default: 0], 0,
                                   "\(label): the hidden \(key) ran, though nothing in it reads the Tasks step")
                }
            }

            // The same settle sees a hidden Notes host run when something it
            // reads changes (a note pinned in the store).
            let pinned = rig.freeNotes[0]
            let control = measure(rig, "note pinned in the store", {
                _ = rig.notes.setPinned(true, noteID: pinned)
            }, saved: { rig.notes.note(withID: pinned)?.isPinned == true })
            XCTAssertGreaterThan(control["NotesPageHost", default: 0], 0,
                                 "harness: the settle sees the hidden Notes host run")
        }
    }

    // MARK: - What still reads the route

    private func undoItems(_ rig: Rig) -> [(title: String, enabled: Bool)] {
        NotesEditorPage.historyCommands(for: rig.controller).map { ($0.title, !$0.isDisabled) }
    }

    /// Notes in front with `note` open in its editor.
    private func openInFront(_ note: UUID, _ rig: Rig) {
        rig.state.selectSection(.notes)
        settle(rig)
        XCTAssertTrue(rig.controller.open(noteID: note), "harness: the note opened")
        rig.controller.dismissLibrary()
        waitForTestOperation("the note's editor in the panel", timeout: 10) {
            rig.content.layoutSubtreeIfNeeded(); rig.panel.displayIfNeeded()
            return rig.controller.active?.engine.textView?.window === rig.panel
                && !(rig.pageBox.chrome?.menuCommands().isEmpty ?? true)
        }
        XCTAssertEqual(rig.state.selectedSection, .notes, "harness: Notes is in front")
    }

    /// The open note's own Delete (its ••• menu), as a person would.
    private func deleteOpenNote(_ rig: Rig) throws -> UUID {
        let note = try XCTUnwrap(rig.controller.active?.noteID, "harness: a note is open")
        let commands = try XCTUnwrap(rig.pageBox.chrome?.menuCommands(), "harness: the page installed its commands")
        let delete = try XCTUnwrap(commands.first { $0.identifier == "notes-menu-delete" }, "harness: the note's menu has Delete")
        delete.action()
        waitForTestOperation("the delete and its toast", timeout: 10) {
            rig.notes.note(withID: note) == nil && rig.toasts.current?.message == "Note deleted"
        }
        XCTAssertTrue(rig.controller.canUndoLibrary, "harness: the delete is the library's next Undo")
        XCTAssertEqual(undoItems(rig).first?.title, "Undo Delete Note")
        XCTAssertEqual(undoItems(rig).first?.enabled, true)
        return note
    }

    func testATasksStepThatEvictsNotesHistoryEndsTheDeleteToastWithNotesInFrontAndHidden() throws {
        for notesInFront in [true, false] {
            // One history kept at a time: a Tasks step drops the library's.
            try withRig(undo: UndoRoute(historyLimit: 1)) { rig in
                openInFront(rig.freeNotes[0], rig)
                _ = try deleteOpenNote(rig)
                if !notesInFront {
                    rig.state.selectSection(.tasks)
                    settle(rig)
                    XCTAssertEqual(rig.toasts.current?.message, "Note deleted", "harness: the toast outlives the page switch")
                }
                let ticked = rig.plain[0]
                rig.page.completeAcknowledged(ticked) { _ in }
                rig.page.settlePendingCompletionAcknowledgements()
                waitForTestOperation("the tick saved") { rig.tasks.task(withID: ticked)?.status == .done }
                settle(rig)
                let label = notesInFront ? "Notes in front" : "Notes hidden"
                XCTAssertFalse(rig.controller.canUndoLibrary, "harness (\(label)): the Tasks step evicted the library's history")
                XCTAssertNil(rig.toasts.current, "\(label): the delete's toast goes once Undo no longer reaches it")
                XCTAssertEqual(undoItems(rig).map(\.title), ["Undo", "Redo"], label)
                XCTAssertEqual(undoItems(rig).map(\.enabled), [false, false], label)
            }
        }
    }

    func testWithNotesInFrontAnEditAndALibraryActionKeepUndoStateRight() throws {
        try withRig { rig in
            // A text edit: the unsaved note holds the panel, then lets it go
            // once saved.
            openInFront(rig.freeNotes[0], rig)
            let textView = try XCTUnwrap(rig.controller.active?.engine.textView)
            XCTAssertTrue(rig.panel.makeFirstResponder(textView))
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            textView.insertText(" typed", replacementRange: textView.selectedRange())
            waitForTestOperation("the edit reached the panel's locks") {
                rig.content.layoutSubtreeIfNeeded()
                return rig.state.interactionLockReasons.contains(.notesDirty)
            }
            XCTAssertTrue(rig.draft.isDirty)
            waitForTestOperation("the edit saved and the lock released", timeout: 10) {
                rig.content.layoutSubtreeIfNeeded()
                return !rig.draft.isDirty && !rig.state.interactionLockReasons.contains(.notesDirty)
            }

            // A library action, its Undo and its Redo: the items follow each.
            XCTAssertTrue(rig.controller.showLibrary())
            settle(rig)
            XCTAssertTrue(rig.controller.setPinned(true, noteID: rig.freeNotes[1]))
            settle(rig)
            XCTAssertEqual(undoItems(rig).map(\.title), ["Undo Pin Note", "Redo"])
            XCTAssertEqual(undoItems(rig).map(\.enabled), [true, false])
            NotesEditorPage.historyCommands(for: rig.controller)[0].action()
            waitForTestOperation("the library's Undo") { rig.controller.canRedoLibrary }
            settle(rig)
            XCTAssertEqual(rig.notes.note(withID: rig.freeNotes[1])?.isPinned, false)
            XCTAssertEqual(undoItems(rig).map(\.title), ["Undo", "Redo Pin Note"])
            XCTAssertEqual(undoItems(rig).map(\.enabled), [false, true])
            NotesEditorPage.historyCommands(for: rig.controller)[1].action()
            waitForTestOperation("the library's Redo") { rig.controller.canUndoLibrary }
            XCTAssertEqual(rig.notes.note(withID: rig.freeNotes[1])?.isPinned, true)
            XCTAssertEqual(undoItems(rig).map(\.title), ["Undo Pin Note", "Redo"])
        }
    }

    func testTheDeleteToastsOwnUndoRestoresTheNote() throws {
        try withRig { rig in
            openInFront(rig.freeNotes[0], rig)
            let note = try deleteOpenNote(rig)
            var outcome: CommandOutcome?
            let undone = expectation(description: "the toast's Undo finished")
            Task { @MainActor in
                outcome = await rig.toasts.performActionAsync()
                undone.fulfill()
            }
            wait(for: [undone], timeout: 10)
            XCTAssertEqual(outcome, .applied)
            XCTAssertNotNil(rig.notes.note(withID: note), "the note is back")
            settle(rig)
            XCTAssertNil(rig.toasts.current, "the toast goes once its Undo worked")
            XCTAssertEqual(undoItems(rig).map(\.title), ["Undo", "Redo Delete Note"])
        }
    }
}
