import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 12: one presentation identity for a (tab, task): geometry, focus,
/// editors and menu targets belong to the page that draws the row, never to
/// the task's id alone (Now's kept "Completed today" copy and the Done copy
/// of one task are two rows). Plus the computer-use review's bugs.
@MainActor
final class TasksRound12Tests: XCTestCase {
    // MARK: - P2-1: a failed subtask rename leaves no failure behind

    private func renameFixture() throws -> (gate: PersistenceGate, model: TasksPageModel, library: AtticLibrary, parent: TaskItem, child: TaskItem) {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let library = AtticLibrary(tasks: store, persist: gate.save)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        let parent = try XCTUnwrap(store.create(title: "Plan the trip"))
        let child = try XCTUnwrap(store.create(title: "Book flights", parentID: parent.id))
        model.setExpanded(parent.id, true)
        return (gate, model, library, parent, child)
    }

    /// A rename that failed to save, then put back to the original text (or
    /// emptied) and confirmed: the editor closes, nothing stays unsaved, no
    /// extra Undo step was made, and hiding and revealing is normal.
    private func assertFailureClears(_ replacement: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (gate, model, library, parent, child) = try renameFixture()
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Book flights to Lisbon"
        gate.shouldFail = true
        XCTAssertFalse(model.commitSubtaskRename(), file: file, line: line)
        XCTAssertTrue(model.subtaskRenameFailed, file: file, line: line)
        XCTAssertTrue(model.hasUnsavedEdit, file: file, line: line)
        gate.shouldFail = false
        let step = library.undo.undoStepID(in: .tasks)

        model.subtaskRename = replacement
        XCTAssertTrue(model.commitSubtaskRename(), file: file, line: line)
        XCTAssertNil(model.renamingSubtaskID, "the editor closes", file: file, line: line)
        XCTAssertFalse(model.subtaskRenameFailed, "no failure is left behind", file: file, line: line)
        XCTAssertFalse(model.hasUnsavedEdit, file: file, line: line)
        XCTAssertEqual(library.undo.undoStepID(in: .tasks), step, "no extra Undo step", file: file, line: line)
        XCTAssertEqual(library.tasks.task(withID: child.id)?.title, "Book flights", file: file, line: line)

        // Hide and reveal are normal: nothing is held, the quick look is a
        // plain reveal (an unsaved edit would keep the page as it was).
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertNil(model.renamingSubtaskID, file: file, line: line)
        XCTAssertFalse(model.hasUnsavedEdit, file: file, line: line)
        model.toggleExpanded(parent.id)
        XCTAssertFalse(model.expanded.contains(parent.id), "collapsing is not blocked", file: file, line: line)
    }

    func testAFailedRenameClearsWhenPutBackToTheOriginalText() throws {
        try assertFailureClears("Book flights")
    }

    func testAFailedRenameClearsWhenEmptied() throws {
        try assertFailureClears("   ")
    }

    func testAFailedRenameClearsWhenItsTaskIsGone() throws {
        let (gate, model, library, _, child) = try renameFixture()
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Book flights to Lisbon"
        gate.shouldFail = true
        XCTAssertFalse(model.commitSubtaskRename())
        gate.shouldFail = false
        XCTAssertTrue(library.deleteTasks([child.id]).isApplied)
        model.subtaskRename = "Something else"
        XCTAssertTrue(model.commitSubtaskRename())
        XCTAssertNil(model.renamingSubtaskID)
        XCTAssertFalse(model.subtaskRenameFailed)
        XCTAssertFalse(model.hasUnsavedEdit)
    }

    // MARK: - CU bug 2: Shift-selection grows from the row the keyboard is on

    /// A menu's selection (the actions menu) moves the selection to a row
    /// the keyboard was not on. ⇧↓ grows from that row, never back to a row
    /// remembered from before.
    func testShiftDownGrowsFromTheMenuSelectedRowNotFromAStaleOne() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let model = hosted.model
        let rows = model.rows(for: .now).map(\.model.title)
        let stale = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Call the plumber" }?.id)
        try hosted.clickRow(stale, tab: .now)
        XCTAssertEqual(model.selection.count, 1, "a click selects one row and focuses it")
        // The actions menu picks a row far from the focused one.
        let picked = try XCTUnwrap(model.rows(for: .now).first?.id, "rows: \(rows)")
        model.selectOnly(picked)
        hosted.spin(0.2)
        let idx = { model.rows(for: .now).enumerated().filter { model.selection.contains($0.element.id) }.map(\.offset) }
        var trace = [idx()]
        hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)
        trace.append(idx())
        hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)
        trace.append(idx())
        XCTAssertEqual(model.selection.count, 3, "the picked row and the two below it: \(trace)")
        XCTAssertTrue(model.selection.contains(picked))
    }

    /// The anchor: a delete of a selected batch leaves none behind, a menu's
    /// selection is its own anchor, and a held anchor outside the selection
    /// is not used.
    func testTheAnchorFollowsTheSelectionThroughMutations() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let ids = try (1...50).map { try XCTUnwrap(store.create(title: "CU review \(String(format: "%02d", $0))")).id }
        // Select 10 rows, delete them: no anchor or selection remains.
        model.click(ids[0], modifiers: [], visible: ids)
        model.click(ids[9], modifiers: .shift, visible: ids)
        XCTAssertEqual(model.selection.count, 10)
        XCTAssertTrue(model.delete(Array(ids[0...9])).isApplied)
        let visible = Array(ids[10...])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.selectionAnchorForTesting, "the deleted row is not an anchor")
        // The menu selects 42; ⇧↓ twice from it.
        model.selectOnly(ids[41])
        model.extendSelection(to: ids[42], visible: visible, from: ids[41])
        model.extendSelection(to: ids[43], visible: visible, from: ids[42])
        XCTAssertEqual(model.selection, Set(ids[41...43]), "three rows, from the picked one")
        // A held anchor outside the selection (a click, then a ⌘-click
        // toggled it out) never stretches the selection to it.
        model.click(ids[12], modifiers: [], visible: visible)
        model.click(ids[30], modifiers: .command, visible: visible)
        model.click(ids[12], modifiers: .command, visible: visible)
        XCTAssertEqual(model.selection, [ids[30]])
        model.extendSelection(to: ids[31], visible: visible, from: ids[30])
        XCTAssertEqual(model.selection, [ids[30], ids[31]])
        // An anchor that is no longer a visible row is dropped.
        model.selectOnly(ids[20])
        model.extendSelection(to: ids[22], visible: visible, from: ids[20])
        XCTAssertEqual(model.selection.count, 3)
        model.extendSelection(to: ids[23], visible: Array(visible.filter { $0 != ids[20] }), from: ids[22])
        XCTAssertFalse(model.selection.contains(ids[20]) && model.selection.count > 4, "no jump across a row that has left the list")
    }

    // MARK: - P2-2 and CU bug 1: one row, one identity per (tab, task)

    /// "Renew domain", done today: Now's "Completed today" (opened) lists it
    /// and so does Done.
    private func completedToday(_ hosted: Hosted) throws -> UUID {
        hosted.model.completedTodayExpanded = true
        hosted.spin(1.2)
        return try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Renew domain" }?.id, "Now's Completed today copy")
    }

    /// Now keeps a "Completed today" copy of a task Done also lists: each
    /// page registers its own frame, and a click on a row selects the row
    /// under the pointer, whichever row was selected before.
    func testACompletedTaskHasAFrameOnEachPageAndClicksLandOnTheRowUnderThem() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let model = hosted.model
        let domain = try completedToday(hosted)
        let nowKey = TasksRowID(tab: .now, id: domain), doneKey = TasksRowID(tab: .done, id: domain)
        let frames = hosted.pointer.frames
        let nowFrame = try XCTUnwrap(frames[nowKey], "Now's copy has its own frame")
        let doneFrame = try XCTUnwrap(frames[doneKey], "Done's copy has its own frame")
        XCTAssertNotEqual(nowFrame, doneFrame, "two rows, two places")

        // Every row on the page: a click selects that row, after any other.
        let visible = model.rows(for: .now).map(\.id).filter { id in
            guard let frame = frames[TasksRowID(tab: .now, id: id)] else { return false }
            return frame.minY > 90 && frame.maxY < 430
        }
        XCTAssertGreaterThan(visible.count, 4)
        var previous: UUID?
        for id in visible.reversed() + visible {
            if let previous, previous != id { XCTAssertEqual(model.selection, [previous]) }
            try hosted.clickRow(id, tab: .now)
            XCTAssertEqual(model.selection, [id], "the click selected the row under it")
            previous = id
        }
        // The Now copy clicked while the Done copy exists: still Now's row.
        try hosted.clickRow(domain, tab: .now)
        XCTAssertEqual(model.selection, [domain])
        XCTAssertEqual(model.tab, .now)
    }

    /// Frames are found by tab: a point over one page's copy is that page's
    /// row only, in either order of registration; a drop or a menu never
    /// lands on the other page's copy.
    func testFramesAreFoundByTabInEitherRegistrationOrder() {
        let shared = UUID(), other = UUID()
        let nowRect = CGRect(x: 0, y: 100, width: 300, height: 34)
        let doneRect = CGRect(x: 360, y: 100, width: 300, height: 34)
        let orders: [[(TasksRowID, CGRect)]] = [
            [(TasksRowID(tab: .now, id: shared), nowRect), (TasksRowID(tab: .done, id: shared), doneRect), (TasksRowID(tab: .done, id: other), doneRect.offsetBy(dx: 0, dy: 40))],
            [(TasksRowID(tab: .done, id: other), doneRect.offsetBy(dx: 0, dy: 40)), (TasksRowID(tab: .done, id: shared), doneRect), (TasksRowID(tab: .now, id: shared), nowRect)],
        ]
        for order in orders {
            var frames: [TasksRowID: CGRect] = [:]
            for (key, rect) in order { frames[key] = rect }
            XCTAssertEqual(TasksPage.row(at: CGPoint(x: 100, y: 110), frames: frames, tab: .now, among: [shared]), shared)
            XCTAssertNil(TasksPage.row(at: CGPoint(x: 100, y: 110), frames: frames, tab: .done, among: [shared]), "Done has nothing there")
            XCTAssertEqual(TasksPage.row(at: CGPoint(x: 400, y: 110), frames: frames, tab: .done, among: [shared, other]), shared)
            XCTAssertNil(TasksPage.row(at: CGPoint(x: 400, y: 110), frames: frames, tab: .now, among: [shared]), "Now has nothing there")
            // One page's disappearance removes only its own frame.
            frames[TasksRowID(tab: .done, id: shared)] = nil
            XCTAssertEqual(frames[TasksRowID(tab: .now, id: shared)], nowRect)
        }
    }

    /// A hidden page's rows go when its page is let go; the shown page's
    /// rows, the same tasks included, keep theirs.
    func testAHiddenCopyRemovalLeavesTheShownPagesFrame() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let domain = try completedToday(hosted)
        XCTAssertNotNil(hosted.pointer.frames[TasksRowID(tab: .done, id: domain)])
        hosted.model.pageDidHide()
        hosted.spin(1)
        XCTAssertNil(hosted.pointer.frames[TasksRowID(tab: .done, id: domain)], "the let-go page's copy is gone")
        XCTAssertNotNil(hosted.pointer.frames[TasksRowID(tab: .now, id: domain)], "Now's copy stays")
    }

    /// Scrolling for a reveal is claimed by the page it was asked for.
    func testARevealScrollBelongsToItsTab() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let task = try XCTUnwrap(store.create(title: "One"))
        XCTAssertEqual(model.show(task.id), .shown)
        XCTAssertNil(model.claimScrollRequest(holding: [task.id], in: .done), "another tab's page does not take it")
        XCTAssertNotNil(model.claimScrollRequest(holding: [task.id], in: .now))
    }

    // MARK: - P2-3: only the active page holds an editor or answers keys

    private func titleFields(_ hosted: Hosted) -> [NSTextView] {
        func find(_ view: NSView) -> [NSTextView] {
            let here = (view as? NSTextView).map { $0.accessibilityIdentifier() == "AtticTitleField" ? [$0] : [] } ?? []
            return here + view.subviews.flatMap(find)
        }
        return hosted.window.contentView.map(find) ?? []
    }

    /// One editor on one row, wherever the task is listed twice; it has the
    /// keyboard and is visible; an unrelated store update leaves it alone; a
    /// tab switch closes it and the other page's copy never opens one.
    func testOnlyTheActivePageHoldsTheEditor() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let model = hosted.model
        let domain = try completedToday(hosted)
        model.selectOnly(domain)
        model.beginEditingTitle(domain)
        hosted.spin(0.6)
        XCTAssertEqual(titleFields(hosted).count, 1, "one editor, not one per page")
        let editor = try XCTUnwrap(titleFields(hosted).first)
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor, "on the page shown")
        XCTAssertTrue(hosted.window.firstResponder === editor, "with the keyboard: \(String(describing: hosted.window.firstResponder))")
        // Something else changes in the store: the editor is where it was.
        _ = hosted.store.create(title: "Unrelated")
        hosted.spin(0.6)
        XCTAssertEqual(titleFields(hosted).count, 1)
        XCTAssertEqual(model.editingTitleID, domain)
        XCTAssertTrue(hosted.window.firstResponder === titleFields(hosted).first)
        // ⌘Z in the editor is the draft's, not the task list's.
        let step = model.library.undo.undoStepID(in: .tasks)
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertEqual(model.library.undo.undoStepID(in: .tasks), step, "no task step was undone")
        XCTAssertEqual(model.editingTitleID, domain, "the editor stays open")
        // To Done and back: the editor closed on leaving, and no page's copy
        // has one now.
        hosted.go(to: .done)
        XCTAssertNil(model.editingTitleID)
        XCTAssertEqual(titleFields(hosted).count, 0, "Done's copy of the task opened no editor")
        hosted.go(to: .now)
        XCTAssertEqual(titleFields(hosted).count, 0)
    }

    /// ⌘D on the selected row acts once, on the page shown, though the task
    /// has a row on two pages; ⌘C and the actions menu key belong to it too.
    func testKeysActOnceOnTheActivePageWhenATaskIsListedTwice() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let model = hosted.model
        let domain = try completedToday(hosted)
        try hosted.clickRow(domain, tab: .now)
        XCTAssertEqual(model.selection, [domain])
        let before = hosted.store.tasks.filter { $0.title == "Renew domain" }.count
        hosted.press("d", keyCode: 2, modifiers: .command)
        XCTAssertEqual(hosted.store.tasks.filter { $0.title == "Renew domain" }.count, before + 1, "one copy, not two")
    }

    /// A parent selected while one of its subtasks has the keyboard: ⌘D is
    /// the subtask's, so it duplicates nothing.
    func testCommandDWithASubtaskFocusedDuplicatesNothing() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let model = hosted.model
        let shipID = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Ship appearance PR" }?.id)
        model.setExpanded(shipID, true)
        let ship = try XCTUnwrap(model.rows(for: .now).first { $0.id == shipID })
        model.selectOnly(ship.id)
        model.focusedSubtaskID = try XCTUnwrap(ship.subtasks.first?.id)
        hosted.spin(0.3)
        let before = hosted.store.tasks.count
        hosted.press("d", keyCode: 2, modifiers: .command)
        XCTAssertEqual(hosted.store.tasks.count, before, "nothing was duplicated")
        XCTAssertNil(model.shortcutRow(focusedRow: ship.id, visible: Set(model.rows(for: .now).map(\.id))))
    }

    // MARK: - CU bug 4: Esc closes an open quick look first

    func testEscClosesTheQuickLookFirstThenClearsTheSelection() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let model = hosted.model
        let ship = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Ship appearance PR" }?.id)
        let plumber = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Call the plumber" }?.id)
        model.setExpanded(ship, true)
        model.click(ship, modifiers: [], visible: model.rows(for: .now).map(\.id))
        model.click(plumber, modifiers: .command, visible: model.rows(for: .now).map(\.id))
        // The keyboard is on no row (the quick look opened by a click).
        hosted.window.makeFirstResponder(nil)
        hosted.window.makeKey()
        hosted.spin(0.3)
        XCTAssertTrue(model.expanded.contains(ship))
        hosted.press("\u{1B}", keyCode: 53)
        XCTAssertFalse(model.expanded.contains(ship), "the first Esc closes the quick look")
        XCTAssertEqual(model.selection.count, 2, "and leaves the selection")
        hosted.press("\u{1B}", keyCode: 53)
        XCTAssertTrue(model.selection.isEmpty, "the next Esc clears the selection")
    }

    // MARK: - CU bug 3: the Tasks page persists across sections

    func testTheTasksPageIsWhereYouLeftItAfterOtherSections() throws {
        let suite = "TasksRound12Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        state.updatePanelSize(CGSize(width: 340, height: 560))
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: NoteDraftController(noteStore: notes),
                chromeInteractionState: chrome, uiState: state, settings: settings,
                subtaskPanels: SubtaskPanelController(store: store, uiState: state, settings: settings),
                tasksPageState: tasksState
            ),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: CGSize(width: 340, height: 560)),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        panel.makeKey()
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        /// Which tab's list is on the page: the three lists lie side by side
        /// once built (Now, Later, Done from the left); the one at the page's
        /// left edge is shown.
        func shownTab() -> Int? {
            host.layoutSubtreeIfNeeded()
            func lists(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(lists)
            }
            let all = lists(host).filter { $0.frame.height > host.bounds.height / 3 }
                .map { $0.convert($0.bounds, to: nil).minX }.sorted()
            guard all.count == 3 else { return nil }
            return all.firstIndex { $0 > -1 && $0 < host.bounds.width / 2 }
        }
        spin(1.5)
        state.selectSection(.tasks)
        spin(1.5)
        XCTAssertEqual(shownTab(), 0, "opens on Now")
        // Done, with its search (the menu bar's Search opens both).
        state.requestSearch()
        spin(1.5)
        XCTAssertEqual(shownTab(), 2, "on Done")
        for section in [PanelSection.notes, .canvas] {
            state.selectSection(section)
            spin(0.8)
            state.selectSection(.tasks)
            spin(1.5)
            XCTAssertEqual(shownTab(), 2, "back on Tasks after \(section), Done is still where it was")
        }
        // A tab the person chose (the search's own reveal no longer holds
        // the page on Done): Later, as a tab click selects it.
        withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) {
            tasksState.model(for: store, toasts: nil).select(tab: .backlog)
        }
        spin(1.5)
        XCTAssertEqual(shownTab(), 1, "on Later")
        for section in [PanelSection.notes, .canvas] {
            state.selectSection(section)
            spin(0.8)
            state.selectSection(.tasks)
            spin(1.5)
            XCTAssertEqual(shownTab(), 1, "back on Tasks after \(section), Later is still where it was")
        }
    }

    // MARK: - UX 6: the add bar is empty once a pasted batch exists

    func testTheAddBarClearsAfterAPastedBatchButNotAfterAFailedOne() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store, persist: gate.save), services: TasksPageServices())
        model.addBar.text = "Half a thought"
        model.pasteOffer = TaskPasteOffer("Milk\nEggs\nBread")
        gate.shouldFail = true
        model.acceptPaste(asOne: false)
        XCTAssertEqual(model.addBar.text, "Half a thought", "a failed save keeps the draft")
        gate.shouldFail = false
        model.retryPaste()
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["Milk", "Eggs", "Bread"])
        XCTAssertEqual(model.addBar.text, "", "the batch exists, the bar is empty")
        XCTAssertNil(model.pasteOffer)
    }

    // MARK: - UX 5: the selection bar's count is never cut mid-word

    /// Measures a view at a proposed width, as its parent would ask.
    private struct WidthProbe: Layout {
        let proposed: CGFloat
        let record: (CGSize) -> Void
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposed, height: 40))
            record(size)
            return size
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: proposed, height: 40))
        }
    }

    private func selectionBarWidth(count: Int, at proposed: CGFloat) -> CGFloat {
        let noop: () -> Void = {}
        let actions = ["checkmark.circle", "exclamationmark", "calendar", "number", "tray.and.arrow.down", "trash"]
            .map { AtticSelectionBar.Action(systemName: $0, label: "Action", handler: noop) }
        var measured: CGSize = .zero
        let probe = WidthProbe(proposed: proposed) { measured = $0 } {
            AtticSelectionBar(count: count, actions: actions)
        }
        let host = NSHostingView(rootView: probe.atticDesign(AtticDesignContext(mode: .light)))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        return measured.width
    }

    /// With the room, "3 selected" in full; without it the count gives up
    /// its word, never its digits ("3 sel..." was the review's bar), and the
    /// bar always fits the width it is given.
    func testTheSelectionBarNeverCutsItsCountMidWord() {
        let full = selectionBarWidth(count: 3, at: 400)
        XCTAssertGreaterThan(full, 250, "the words are there with room")
        for width in stride(from: 296.0, through: 260.0, by: -12.0) {
            for count in [3, 45, 128] {
                let bar = selectionBarWidth(count: count, at: width)
                XCTAssertLessThanOrEqual(bar, width + 0.5, "\(count) selected fits \(width)")
            }
        }
        // 3 does not fit "3 selected" between a rounder corner's margins
        // (about 280): the bar shrinks to the number, it does not squeeze
        // the words into what is left.
        let squeezed = selectionBarWidth(count: 3, at: full - 8)
        XCTAssertLessThan(squeezed, full - 30, "the words give way whole, not by a few points")
    }

    // MARK: - Visual 2: the tag keeps a meaningful prefix

    /// The widths of the strip's filled pills (Date, Tag, Priority: each a
    /// run of non-background pixels along the strip's middle), as drawn in
    /// `width` points.
    private func stripPills(date: String?, tag: String?, priority: String?, width: CGFloat) throws -> [CGFloat] {
        func value(_ text: String?) -> AtticStripValue? { text.map { AtticStripValue(text: $0, spoken: $0) } }
        let context = AtticDesignContext(mode: .light)
        let strip = AtticGallerySamples.strip(date: value(date), tags: value(tag), priority: value(priority))
            .frame(width: width, height: AtticControlSize.smallHeight, alignment: .leading)
            .frame(width: 340, height: 40, alignment: .leading)
            .background(context.tokens.panel.base.color)
            .atticDesign(context)
        let host = NSHostingView(rootView: strip)
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let y = Int(20 * scale)
        func pixel(_ x: Int) -> [Int] {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
            return [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]
        }
        let background = pixel(rep.pixelsWide - 2)
        var runs: [CGFloat] = []
        var start: Int?
        for x in 0..<Int((width + 4) * scale) {
            let differs = zip(pixel(x), background).contains { abs($0 - $1) > 2 }
            if differs, start == nil { start = x }
            if !differs, let s = start {
                runs.append(CGFloat(x - s) / scale)
                start = nil
            }
        }
        if let s = start { runs.append(CGFloat(Int((width + 4) * scale) - s) / scale) }
        return runs
    }

    /// Date, Tag and Priority all set, in the room the add bar gives them
    /// (a rounder corner takes more): the tag keeps a meaningful prefix
    /// ("#laun..."), the date gives way after it, and a short tag is not
    /// padded.
    func testTheStripKeepsAMeaningfulTagPrefix() throws {
        let iconAndPaddings: CGFloat = 55
        for width in [296.0, 280.0, 264.0] {
            let pills = try stripPills(date: "Wed 14 Oct", tag: "#launch-checklist +1", priority: "!!", width: width)
            XCTAssertEqual(pills.count, 3, "three pills at \(width): \(pills)")
            guard pills.count == 3 else { continue }
            XCTAssertGreaterThanOrEqual(pills[1] - iconAndPaddings, 30, "the tag shows a prefix, not '#', at \(width): \(pills)")
            XCTAssertLessThanOrEqual(pills.reduce(0, +) + 8, width + 1, "the strip fits \(width): \(pills)")
        }
        let short = try stripPills(date: nil, tag: "#a", priority: nil, width: 296)
        let alone = try stripPills(date: nil, tag: "#a", priority: nil, width: 120)
        XCTAssertEqual(short.first ?? 0, alone.first ?? -1, accuracy: 1, "a short tag is as wide as it is")
        XCTAssertLessThan(short.first ?? 999, 80, "and not padded to a prefix's width")
    }

    // MARK: - Bug 5: rows are not readable under the tabs or the add bar

    /// The mask's opacity at `y` (the gradient's linear interpolation).
    private func maskOpacity(_ stops: [(location: CGFloat, opacity: Double)], at y: CGFloat, height: CGFloat) -> Double {
        let x = y / height
        guard let first = stops.first, let last = stops.last else { return 1 }
        if x <= first.location { return first.opacity }
        if x >= last.location { return last.opacity }
        for (a, b) in zip(stops, stops.dropFirst()) where x <= b.location {
            let t = Double((x - a.location) / (b.location - a.location))
            return a.opacity + (b.opacity - a.opacity) * t
        }
        return last.opacity
    }

    /// B (owner, 2026-10-01) replaces round 12's rule: whatever the
    /// bottom stack, rows stay whole under the tabs and the bar, and recede
    /// only past the controls toward the panel's edges, rising and falling
    /// smoothly (never a step).
    func testRowsPassUnderTheTabsAndTheBottomStack() {
        let height: CGFloat = 520
        let stops = TasksViewport.maskStops(height: height, tabsTop: 80, bottomInset: 12)
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "stops in order")
        for y in stride(from: CGFloat(80), through: height - 12, by: 1) {
            XCTAssertEqual(maskOpacity(stops, at: y, height: height), 1, accuracy: 0.001, "whole at \(y)")
        }
        let top = stride(from: CGFloat(0), through: 80, by: 1).map { maskOpacity(stops, at: $0, height: height) }
        XCTAssertEqual(top, top.sorted(), "rises from the top edge")
        let bottom = stride(from: height - 12, through: height, by: 1).map { maskOpacity(stops, at: $0, height: height) }
        XCTAssertEqual(bottom, bottom.sorted(by: >), "falls toward the bottom edge")
        XCTAssertGreaterThanOrEqual(top.min() ?? 0, AtticEdgeBlur.edgeVisible - 0.001, "never fainter than the edge")
    }

    // MARK: - Astra P2: a page kept behind another section takes no mouse

    /// The mouse monitor stays installed while Tasks is kept built behind
    /// Notes or Canvas. Real left and right presses over a hidden row's
    /// position, and over the empty list, change no selection, anchor or
    /// first responder and bind no menu; back on Tasks, targeting is normal.
    func testAPageKeptBehindAnotherSectionTakesNoMouse() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.2)
        let tab = hosted.model.tab
        let rows = hosted.pointer.frames.filter { $0.key.tab == tab }.sorted { $0.value.minY < $1.value.minY }
        XCTAssertGreaterThanOrEqual(rows.count, 3, "the demo list has rows to press")
        let first = try XCTUnwrap(rows.first?.key), second = try XCTUnwrap(rows.dropFirst().first?.key)
        let secondFrame = try XCTUnwrap(rows.dropFirst().first?.value)
        // A plain click selects the first row: the baseline the hidden
        // presses must leave alone.
        try hosted.clickRow(first.id, tab: tab)
        XCTAssertEqual(hosted.model.selection, [first.id])
        XCTAssertEqual(hosted.model.selectionAnchor, first.id)
        let responder = hosted.window.firstResponder

        // Tasks is kept, not shown, and another section is drawn over it as
        // in the panel: the events reach the monitor (the same window) but
        // no Tasks row beneath, so nothing here opens a real context menu.
        final class Cover: NSView {
            override func mouseDown(with event: NSEvent) {}
            override func rightMouseDown(with event: NSEvent) {}
            override func otherMouseDown(with event: NSEvent) {}
        }
        let content = try XCTUnwrap(hosted.window.contentView)
        let cover = Cover(frame: content.bounds)
        cover.autoresizingMask = [.width, .height]
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        defer { cover.removeFromSuperview() }
        hosted.model.isPageShown = false
        hosted.spin(0.3)
        let spaceY = try XCTUnwrap(rows.last?.value.maxY) + 24
        hosted.click(y: spaceY)
        hosted.rightClick(y: spaceY)
        hosted.click(y: secondFrame.midY)
        hosted.click(y: secondFrame.midY, modifiers: .shift)
        hosted.click(y: secondFrame.midY, modifiers: .control)
        hosted.rightClick(y: secondFrame.midY)
        XCTAssertEqual(hosted.model.selection, [first.id], "a hidden page's rows take no press")
        XCTAssertEqual(hosted.model.selectionAnchor, first.id, "and the anchor stays")
        XCTAssertTrue(hosted.window.firstResponder === responder, "and focus stays")
        XCTAssertNil(hosted.pointer.invocation, "no menu is bound to a hidden row")

        // Shown again: the same presses target as before.
        cover.removeFromSuperview()
        hosted.model.isPageShown = true
        hosted.spin(0.3)
        try hosted.clickRow(second.id, tab: tab)
        XCTAssertEqual(hosted.model.selection, [second.id], "a click on the page selects its row")
        XCTAssertEqual(hosted.model.selectionAnchor, second.id)
        hosted.click(y: spaceY)
        XCTAssertTrue(hosted.model.selection.isEmpty, "and a click on the empty list clears it")
        // (A shown page's right-click opens a real context menu that blocks
        // the run loop, so the binding on a shown row is covered by round 4's
        // pointer tests; this test's hidden right-clicks are the ones that
        // must bind nothing.)
        let third = try XCTUnwrap(rows.dropFirst(2).first?.key)
        try hosted.clickRow(second.id, tab: tab)
        try hosted.clickRow(third.id, tab: tab, modifiers: .shift)
        XCTAssertEqual(hosted.model.selection, [second.id, third.id], "a Shift-click extends from the click before")
        XCTAssertNil(hosted.pointer.invocation, "a left click binds no menu")
    }

    /// The page drawn with a long list scrolled to two places (a hosted
    /// stand-in for the round's UI test): since B (owner, 2026-10-01) the
    /// rows are drawn under the tabs' line and the add bar's band, so the
    /// picture there changes with what lies beneath (round 12 asserted the
    /// opposite).
    func testRowsAreDrawnUnderTheTabsAndTheAddBarsBand() throws {
        let height: CGFloat = 520
        let hosted = try Hosted(height: height, long: true)
        defer { hosted.close() }
        hosted.spin(1.5)
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        let list = try XCTUnwrap(hosted.lists(in: content).first {
            $0.frame.height > content.bounds.height / 2 && $0.frame.minX > -1 && $0.frame.minX < content.bounds.width / 2
        })
        func capture(scrolledTo y: CGFloat) throws -> NSBitmapImageRep {
            list.contentView.scroll(to: CGPoint(x: 0, y: y))
            list.reflectScrolledClipView(list.contentView)
            hosted.spin(0.5)
            content.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            return rep
        }
        func share(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, from top: CGFloat, to bottom: CGFloat) throws -> Double {
            XCTAssertEqual(a.pixelsWide, b.pixelsWide)
            let scale = CGFloat(a.pixelsWide) / content.bounds.width
            var differing = 0, total = 0
            for y in Int(top * scale)..<min(Int(bottom * scale), a.pixelsHigh, b.pixelsHigh) {
                for x in 0..<a.pixelsWide {
                    guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    total += 1
                    if max(abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                           abs(p.blueComponent - q.blueComponent)) > 0.03 { differing += 1 }
                }
            }
            return total == 0 ? 1 : Double(differing) / Double(total)
        }
        let first = try capture(scrolledTo: 260)
        let second = try capture(scrolledTo: 1_300)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: height))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let tabsBottom = tabsTop + AtticLayout.pageTabsHeight
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let barTop = height - bottomInset - AtticControlSize.addBarHeight
        // The list itself moved, or the bands prove nothing.
        let moved = try share(first, second, from: tabsBottom + 40, to: barTop - 40)
        XCTAssertGreaterThan(moved, 0.02, "the long list scrolled between the captures (\(moved))")
        // The tabs' line and the gap under it, and the add bar's band.
        let top = try share(first, second, from: tabsTop, to: TasksViewport.listTop(tabsTop: tabsTop))
        XCTAssertGreaterThan(top, 0.004, "rows pass under the tabs' line (\(top))")
        let bottom = try share(first, second, from: barTop - 4, to: height)
        XCTAssertGreaterThan(bottom, 0.004, "rows pass under the add bar's band (\(bottom))")
    }

    // MARK: - Hidden Done reads nothing

    /// A Done page kept built but not drawn does not read the log, does not
    /// watch the store's revision, and catches up when it is drawn.
    func testAHiddenDonePageReadsNothingUntilItIsDrawn() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "Done is built beside the page")
        XCTAssertTrue(hosted.model.doneLogTasks.isEmpty, "built hidden, it read no log")
        // The store changes while Done is hidden: still nothing read.
        let library = AtticLibrary(tasks: hosted.store)
        var ids: [UUID] = []
        for index in 0..<5 { ids.append(try XCTUnwrap(hosted.store.create(title: "Old finished \(index)")).id) }
        XCTAssertTrue(library.updateTasks(ids, status: .done).isApplied)
        XCTAssertGreaterThan(hosted.store.moveCompletedToDoneLog(before: Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))), 0)
        hosted.spin(0.6)
        XCTAssertTrue(hosted.model.doneLogTasks.isEmpty, "a store change read nothing for the hidden page")
        // Drawn, it catches up with everything at once.
        hosted.go(to: .done)
        XCTAssertTrue(ids.allSatisfy { id in hosted.model.doneLogTasks.contains { $0.id == id } }, "drawn, it read the log as it is now")
        // And watches again: a change while drawn is read.
        let more = try XCTUnwrap(hosted.store.create(title: "Finished while watching")).id
        XCTAssertTrue(library.updateTasks([more], status: .done).isApplied)
        XCTAssertGreaterThan(hosted.store.moveCompletedToDoneLog(before: Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))), 0)
        hosted.spin(0.6)
        XCTAssertTrue(hosted.model.doneLogTasks.contains { $0.id == more }, "a drawn Done follows the store")
    }
}

extension Hosted {
    /// Clicks the middle of a row as the page laid it out (its frame in the
    /// page's own space, the top left of the window).
    func clickRow(_ id: UUID, tab: TasksTab, x: CGFloat = 200, modifiers: NSEvent.ModifierFlags = []) throws {
        let frame = try XCTUnwrap(pointer.frames[TasksRowID(tab: tab, id: id)], "the row \(id) is on the page")
        click(y: frame.midY, x: x, modifiers: modifiers)
    }
}
