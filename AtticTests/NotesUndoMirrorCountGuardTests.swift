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
        let settings: AppSettings
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
        let settings = AppSettings(defaults: defaults)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: tasks, noteStore: notes, canvasSession: canvasSession,
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, toasts: toasts,
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

        try body(Rig(tasks: tasks, notes: notes, library: library, draft: draft, state: state, settings: settings, toasts: toasts,
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
            // while the priority change is counted. (A toast running the
            // hidden Calendar is SPEED-TOAST-HIDDEN-CALENDAR, guarded in
            // testAToastRunsNoHiddenCalendarOrNotesHost.)
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

            // The Notes columns' positive control: the same settle sees the
            // hidden Notes views and route host run when something they read
            // changes (a note pinned in the store).
            let pinned = rig.freeNotes[0]
            let control = measure(rig, "note pinned in the store", {
                _ = rig.notes.setPinned(true, noteID: pinned)
            }, saved: { rig.notes.note(withID: pinned)?.isPinned == true })
            for key in ["NotesPageHost", "NotesEditorPage", "NotesLibraryView", "route.notes"] {
                XCTAssertGreaterThan(control[key, default: 0], 0, "harness: the settle sees the hidden \(key) run")
            }
            // The Calendar columns' positive control: the same settle sees
            // the hidden Calendar host, page and route host run when their
            // layout changes.
            assertCalendarColumnsAreLive(rig)
        }
    }

    /// A corner change gives every page a new layout, which the Calendar
    /// host, page and route host read once Calendar is shown: the counters
    /// are live. (A
    /// panel size change was the control until the layout stopped carrying
    /// the size: ops/design/resize-cause.md, cause 1. A size change now
    /// hands no page a new value, so it can no longer show a live counter.)
    private func assertCalendarColumnsAreLive(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let original = rig.settings.panelCornerSize
        let changed = original == PanelCornerSize.large.rawValue ? PanelCornerSize.extraLarge.rawValue : PanelCornerSize.large.rawValue
        // Calendar sits in a kept host of its own (PR 80): hidden, it takes
        // no new root, so its views do not run on the change. Shown, the
        // host takes the change it held, and the same settle sees the
        // Calendar host, page and route host run: the counters are live.
        _ = measure(rig, "panel corner changed", { rig.settings.panelCornerSize = changed },
                    saved: { rig.settings.panelCornerSize == changed })
        let control = measure(rig, "Calendar shown after the corner change", { rig.state.selectSection(.calendar) },
                              saved: { rig.state.selectedSection == .calendar })
        for key in ["CalendarPageHost", "CalendarPage", "route.calendar"] {
            XCTAssertGreaterThan(control[key, default: 0], 0, "harness: the settle sees the Calendar \(key) run",
                                 file: file, line: line)
        }
        rig.state.selectSection(.tasks)
        settle(rig)
        rig.settings.panelCornerSize = original
        settle(rig)
    }

    // MARK: - A toast runs no hidden page (SPEED-TOAST-HIDDEN-CALENDAR)

    /// A toast changes only the notices. Posting one, replacing it with a
    /// failure and dismissing it must run none of the hidden Calendar and
    /// Notes views; the hidden Canvas host, the one reader of the notices'
    /// height, still gets it while the toast is up and loses it after.
    func testAToastRunsNoHiddenCalendarOrNotesHost() throws {
        // Printed beside the counts: how often the shell's body ran.
        var shellRuns = 0
        #if ATTIC_LOCAL_ONLY
        let previousShell = PanelInvalidationProbe.shell
        PanelInvalidationProbe.shell = { shellRuns += 1 }
        defer { PanelInvalidationProbe.shell = previousShell }
        #endif
        try withRig { rig in
            XCTAssertNil(rig.toasts.current, "harness: no toast is up before the first post")
            let steps: [(String, () -> Void, () -> Bool)] = [
                ("toast posted", { rig.toasts.show("Counted toast") {} },
                 { rig.toasts.current?.message == "Counted toast" }),
                ("toast replaced by a failure", { _ = rig.toasts.showFailure("Counted failure") },
                 { rig.toasts.current?.message == "Counted failure" }),
                ("toast dismissed", { rig.toasts.dismiss() }, { rig.toasts.current == nil }),
            ]
            for (label, control, saved) in steps {
                settle(rig)
                let shellBefore = shellRuns
                let canvasBefore = PanelCanvasNoticeAwareHost.bodyEvaluations
                let counts = measure(rig, label, control, saved: saved)
                print("TOAST_HIDDEN_COUNTS \(label) shell=\(shellRuns - shellBefore) "
                      + "canvasHost=\(PanelCanvasNoticeAwareHost.bodyEvaluations - canvasBefore) "
                      + "canvasBanner=\(PanelCanvasNoticeAwareHost.lastErrorBannerHeight)")
                for key in Self.hidden {
                    XCTAssertEqual(counts[key, default: 0], 0,
                                   "\(label): the hidden \(key) ran, though nothing in it reads the toast")
                }
                if rig.toasts.current != nil {
                    XCTAssertGreaterThan(PanelCanvasNoticeAwareHost.lastErrorBannerHeight, 0,
                                         "\(label): the hidden Canvas keeps clear of the toast")
                } else {
                    XCTAssertEqual(PanelCanvasNoticeAwareHost.lastErrorBannerHeight, 0,
                                   "\(label): the hidden Canvas gives the room back once the toast is gone")
                }
            }
            assertCalendarColumnsAreLive(rig)
        }
    }

    // MARK: - The Draw page's two shell values across its kept host

    /// `noticeHeight` and `headerControlRects` (draw-kept-host-brief.md):
    /// `PanelCanvasNoticeAwareHost` takes both from the shell. With the page
    /// shown, a toast's room reaches it and goes again, and a corner change
    /// hands it the shell's new header control frames. With the page hidden
    /// through a toast and a corner change, its first frame shown has both
    /// current values. Run on the Draw page and on the old Canvas (the arm
    /// that reads the two values).
    func testDR5NoticeHeightAndHeaderRectsReachTheCanvasPageShownAndOnItsFirstFrame() throws {
        let previous = AtticDraw.enabledOverride
        defer { AtticDraw.enabledOverride = previous }
        for draw in [true, false] {
            AtticDraw.enabledOverride = draw
            try withRig { rig in
                @MainActor func expectedRects(_ corner: Double? = nil) -> [CGRect] {
                    let insets = PanelPageLayout(cornerSize: corner ?? rig.settings.panelCornerSize,
                                                 cornerRoom: rig.state.panelCornerRoom).chromeInsets
                    return [CGRect(x: insets.leading, y: insets.top, width: PanelHeaderLayout.pinSize.width,
                                   height: PanelHeaderLayout.height)]
                }
                @MainActor func drawn(_ label: String, _ applied: @escaping () -> Bool) {
                    waitForTestOperation("draw=\(draw) \(label)") {
                        rig.content.layoutSubtreeIfNeeded(); rig.panel.displayIfNeeded(); return applied()
                    }
                }
                let original = rig.settings.panelCornerSize
                // A corner whose header rects differ from the original's, so the check can fail.
                let changed = try XCTUnwrap(PanelCornerSize.allCases.map(\.rawValue).first { expectedRects($0) != expectedRects(original) },
                                            "harness: some corner size moves the header rects")
                print("DR5 draw=\(draw) corners original=\(original) changed=\(changed) rects \(expectedRects(original)) vs \(expectedRects(changed))")
                rig.state.selectSection(.canvas)
                settle(rig)
                XCTAssertNil(rig.toasts.current, "harness: no toast is up")
                XCTAssertEqual(PanelCanvasNoticeAwareHost.lastErrorBannerHeight, 0, "draw=\(draw): shown with no notice, no banner room")
                XCTAssertEqual(PanelCanvasNoticeAwareHost.lastHeaderControlRects, expectedRects(), "draw=\(draw): shown, the header rects")
                // Shown: a toast's room arrives and goes; a corner change's rects arrive.
                rig.toasts.show("DR5 toast") {}
                drawn("shown, the toast's room") { PanelCanvasNoticeAwareHost.lastErrorBannerHeight > 0 }
                rig.toasts.dismiss()
                drawn("shown, the room given back") { PanelCanvasNoticeAwareHost.lastErrorBannerHeight == 0 }
                rig.settings.panelCornerSize = changed
                drawn("shown, the new header rects") { PanelCanvasNoticeAwareHost.lastHeaderControlRects == expectedRects() }
                // Hidden: a toast and a corner change, then the first frame shown.
                rig.state.selectSection(.tasks)
                settle(rig)
                rig.toasts.show("DR5 hidden toast") {}
                rig.settings.panelCornerSize = original
                settle(rig)
                XCTAssertNotNil(rig.toasts.current, "harness: the toast is up")
                var shellRuns = 0
                #if ATTIC_LOCAL_ONLY
                let previousShell = PanelInvalidationProbe.shell
                PanelInvalidationProbe.shell = { shellRuns += 1 }
                defer { PanelInvalidationProbe.shell = previousShell }
                #else
                shellRuns = 1
                #endif
                rig.state.selectSection(.canvas)
                var first: (CGFloat, [CGRect])?
                waitForTestOperation("draw=\(draw): the first frame with the page shown") {
                    rig.content.layoutSubtreeIfNeeded(); rig.panel.displayIfNeeded()
                    guard shellRuns > 0 else { return false }
                    first = (PanelCanvasNoticeAwareHost.lastErrorBannerHeight, PanelCanvasNoticeAwareHost.lastHeaderControlRects)
                    return true
                }
                print("DR5 draw=\(draw) first_frame{banner=\(first?.0 ?? -1) rects=\(first?.1 ?? []) expected=\(expectedRects())}")
                XCTAssertGreaterThan(first?.0 ?? 0, 0, "draw=\(draw): the first frame shown has no room for the toast up while hidden")
                XCTAssertEqual(first?.1, expectedRects(), "draw=\(draw): the first frame shown has stale header rects")
                rig.toasts.dismiss()
                rig.state.selectSection(.tasks)
                settle(rig)
            }
        }
    }

    // MARK: - A clearance change runs no shell (SPEED-NOTICE-CLEARANCE-SHELL)

    /// The Tasks page's bottom stack growing or shrinking (here a paste
    /// offer over the bar, as the composer's date and tags row does) moves
    /// the notices' clearance. Only the notices' padding reads it: neither
    /// the shell nor any hidden Notes or Calendar view may run, while the
    /// notices still get the new padding and give it back. The hidden
    /// Canvas host, whose banner room is 0 with no notice up, may not run
    /// either (SPEED-TOAST-HIDDEN-CANVAS (a), PR52 B1).
    func testANoticeClearanceChangeRunsNoShellOrHiddenPage() throws {
        var shellRuns = 0
        #if ATTIC_LOCAL_ONLY
        let previousShell = PanelInvalidationProbe.shell
        PanelInvalidationProbe.shell = { shellRuns += 1 }
        defer { PanelInvalidationProbe.shell = previousShell }
        #endif
        try withRig { rig in
            settle(rig)
            let resting = PanelNoticeClearanceProbe.lastBottomPadding
            XCTAssertGreaterThan(resting, 0, "harness: the notices are padded above the bar before the change")
            XCTAssertNil(rig.page.pasteOffer, "harness: no paste offer before the change")
            XCTAssertEqual(rig.state.selectedSection, .tasks, "harness: Tasks is in front, Canvas hidden")
            XCTAssertNil(rig.toasts.current, "harness: no toast is up")
            XCTAssertNil(rig.tasks.lastErrorMessage, "harness: no Tasks notice is up")
            let offer = try XCTUnwrap(TaskPasteOffer("Counted milk\nCounted eggs"))
            func drawn(_ applied: @escaping () -> Bool) -> () -> Bool {
                { rig.content.layoutSubtreeIfNeeded(); rig.panel.displayIfNeeded(); return applied() }
            }
            let steps: [(String, () -> Void, () -> Bool)] = [
                ("clearance grows", { rig.page.pasteOffer = offer },
                 drawn { PanelNoticeClearanceProbe.lastBottomPadding > resting + 0.5 }),
                ("clearance shrinks", { rig.page.pasteOffer = nil },
                 drawn { abs(PanelNoticeClearanceProbe.lastBottomPadding - resting) < 0.5 }),
            ]
            for (label, control, applied) in steps {
                settle(rig)
                let shellBefore = shellRuns
                let paddedBefore = PanelNoticeClearanceProbe.applications
                let canvasBefore = PanelCanvasNoticeAwareHost.bodyEvaluations
                let counts = measure(rig, label, control, saved: applied)
                let padded = PanelNoticeClearanceProbe.applications - paddedBefore
                let canvasHost = PanelCanvasNoticeAwareHost.bodyEvaluations - canvasBefore
                print("CLEARANCE_SHELL_COUNTS \(label) shell=\(shellRuns - shellBefore) notices=\(padded) "
                      + "canvasHost=\(canvasHost) canvasBanner=\(PanelCanvasNoticeAwareHost.lastErrorBannerHeight) "
                      + "padding=\(PanelNoticeClearanceProbe.lastBottomPadding) resting=\(resting)")
                XCTAssertEqual(shellRuns - shellBefore, 0,
                               "\(label): the shell ran, though only the notices read the clearance")
                XCTAssertEqual(canvasHost, 0,
                               "\(label): the hidden Canvas host ran, though with no notice up its banner room is 0")
                XCTAssertEqual(PanelCanvasNoticeAwareHost.lastErrorBannerHeight, 0,
                               "\(label): the hidden Canvas has no banner room with no notice up")
                for key in Self.hidden {
                    XCTAssertEqual(counts[key, default: 0], 0,
                                   "\(label): the hidden \(key) ran, though nothing in it reads the clearance")
                }
                // The positive control: the notices' padding was applied.
                XCTAssertGreaterThan(padded, 0, "\(label): the notices took the new clearance")
            }
            // Liveness (PR52 B3): a new layout (a corner change; a size
            // change no longer makes one) runs the shell's probe. The Canvas
            // page sits in a kept host of its own (draw-kept-host-brief.md):
            // hidden, it takes no new layout; shown, it takes the one it held,
            // so its counter runs then.
            let canvasBefore = PanelCanvasNoticeAwareHost.bodyEvaluations
            let shellBefore = shellRuns
            assertCalendarColumnsAreLive(rig)
            let original = rig.settings.panelCornerSize
            rig.settings.panelCornerSize = original == PanelCornerSize.large.rawValue
                ? PanelCornerSize.extraLarge.rawValue : PanelCornerSize.large.rawValue
            settle(rig)
            let canvasHidden = PanelCanvasNoticeAwareHost.bodyEvaluations - canvasBefore
            rig.state.selectSection(.canvas)
            settle(rig)
            let canvasShown = PanelCanvasNoticeAwareHost.bodyEvaluations - canvasBefore - canvasHidden
            rig.state.selectSection(.tasks)
            settle(rig)
            rig.settings.panelCornerSize = original
            settle(rig)
            print("CLEARANCE_SHELL_COUNTS panel corner changed shell=\(shellRuns - shellBefore) canvasHost=\(canvasHidden) canvasShown=\(canvasShown)")
            XCTAssertEqual(canvasHidden, 0, "a new layout ran the hidden Canvas host")
            XCTAssertGreaterThan(canvasShown, 0, "harness: shown after the new layout, the Canvas host runs")
            #if ATTIC_LOCAL_ONLY
            XCTAssertGreaterThan(shellRuns - shellBefore, 0, "harness: a new layout runs the shell")
            #endif
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
