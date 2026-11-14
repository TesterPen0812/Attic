import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The fixes from gpt-6-sol's review of the Tasks stream (phase0/runs/
/// p1-tasks-review.md), one test per finding.
@MainActor
final class TasksReviewFixTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func rows(_ container: ModelContainer, _ id: UUID) throws -> [TaskItem] {
        try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    // MARK: 1. Batch edits are atomic

    func testABatchEditIsOneSaveAndAFailedSaveChangesNothing() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let library = AtticLibrary(tasks: store)
        let a = try XCTUnwrap(store.create(title: "A"))
        let b = try XCTUnwrap(store.create(title: "B"))
        let c = try XCTUnwrap(store.create(title: "C"))

        let before = gate.saveCount
        XCTAssertTrue(library.updateTasks([a.id, b.id], priority: .high).isApplied)
        XCTAssertEqual(gate.saveCount, before + 1, "the whole batch is one save")

        gate.shouldFail = true
        let steps = library.undo.undoCount(in: .tasks)
        XCTAssertFalse(library.updateTasks([a.id, b.id, c.id], status: .backlog).isApplied)
        XCTAssertFalse(library.updateTasks([a.id, b.id, c.id], status: .done).isApplied)
        gate.shouldFail = false
        for id in [a.id, b.id, c.id] {
            XCTAssertTrue(try rows(store.container, id).allSatisfy { $0.status == .todo }, "nothing changed")
            XCTAssertEqual(store.task(withID: id)?.status, .todo)
        }
        XCTAssertEqual(library.undo.undoCount(in: .tasks), steps, "a failed batch records no step")
    }

    // MARK: 2. Failed writes keep what was typed

    func testAFailedTitleSaveKeepsTheEditorOpenWithTheTextUntilARetryWorks() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let id = try XCTUnwrap(store.create(title: "Old")).id
        model.beginEditingTitle(id)
        model.editingTitle = "New title"
        gate.shouldFail = true
        XCTAssertFalse(model.commitTitle())
        XCTAssertEqual(model.editingTitleID, id, "the editor stays open")
        XCTAssertEqual(model.editingTitle, "New title", "with what was typed")
        XCTAssertEqual(model.failedSave, .title(id), "and offers Retry")
        gate.shouldFail = false
        XCTAssertTrue(model.commitTitle())
        XCTAssertNil(model.editingTitleID)
        XCTAssertNil(model.failedSave)
        XCTAssertEqual(store.task(withID: id)?.title, "New title")
    }

    func testBlockedAlternateSubmissionFromDoneStillSaysAddedToNow() throws {
        let store = try makeTestStore(persist: { context in
            if try context.fetch(FetchDescriptor<TaskItem>()).contains(where: { $0.title == "Unsaved edit" }) {
                throw PersistenceGate.Failure()
            }
            try context.save()
        })
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let other = try XCTUnwrap(store.create(title: "Original title"))
        model.select(tab: .done)
        model.beginEditingTitle(other.id)
        model.editingTitle = "Unsaved edit"
        model.addBar.text = "Added despite blocked navigation"
        let id = try XCTUnwrap(model.submitAddBar(openingPage: true))
        XCTAssertEqual(store.task(withID: id)?.status, .todo)
        XCTAssertEqual(model.tab, .done, "the failed edit keeps its page")
        XCTAssertEqual(model.editingTitleID, other.id)
        XCTAssertEqual(model.editingTitle, "Unsaved edit")
        XCTAssertEqual(store.task(withID: other.id)?.title, "Original title")
        XCTAssertEqual(model.toasts.current?.message, "Added to Now")
    }

    func testAFailedPasteKeepsTheOfferUntilTheTasksExist() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.pasteOffer = TaskPasteOffer("Milk\nEggs")
        gate.shouldFail = true
        model.acceptPaste(asOne: false)
        XCTAssertNotNil(model.pasteOffer, "the pasted text is still on offer")
        XCTAssertEqual(model.failedSave, .paste)
        XCTAssertTrue(store.tasks.isEmpty)
        gate.shouldFail = false
        model.retryPaste()
        XCTAssertNil(model.pasteOffer)
        XCTAssertNil(model.failedSave)
        XCTAssertEqual(Set(store.tasks.map(\.title)), ["Milk", "Eggs"])
    }

    func testAFailedNewSubtaskKeepsItsText() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        model.beginAddingSubtask(to: parent.id)
        model.newSubtaskTitle = "Pack"
        gate.shouldFail = true
        XCTAssertFalse(model.commitNewSubtask())
        XCTAssertEqual(model.newSubtaskTitle, "Pack")
        XCTAssertEqual(model.failedSave, .newSubtask(parent.id))
    }

    // MARK: Round 2 #1: unsaved edits survive page switches and reveals

    /// A failed title save keeps its text and Retry when the person goes to
    /// Notes and back (the host resets the page on return) and when the
    /// panel hides and shows again.
    func testAFailedTitleSaveSurvivesAPageSwitchAndARereveal() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let id = try XCTUnwrap(store.create(title: "Old")).id
        model.beginEditingTitle(id)
        model.editingTitle = "New title"
        gate.shouldFail = true
        XCTAssertFalse(model.commitTitle())
        model.resetForReveal()          // back from Notes
        model.pageDidHide()
        model.resetForReveal()          // hidden and shown again
        XCTAssertEqual(model.editingTitleID, id)
        XCTAssertEqual(model.editingTitle, "New title")
        XCTAssertEqual(model.failedSave, .title(id))
        model.select(tab: .backlog)
        XCTAssertEqual(model.tab, .now, "moving to Backlog tries the save; it fails, so the page stays")
        XCTAssertEqual(model.failedSave, .title(id))
        gate.shouldFail = false
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(store.task(withID: id)?.title, "New title")
    }

    func testAFailedNewSubtaskSurvivesAPageSwitchAndARereveal() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        model.beginAddingSubtask(to: parent.id)
        model.newSubtaskTitle = "Pack"
        gate.shouldFail = true
        XCTAssertFalse(model.commitNewSubtask())
        model.resetForReveal()
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertEqual(model.newSubtaskParentID, parent.id)
        XCTAssertEqual(model.newSubtaskTitle, "Pack")
        XCTAssertEqual(model.failedSave, .newSubtask(parent.id))
        gate.shouldFail = false
        XCTAssertTrue(model.commitNewSubtask())
        XCTAssertEqual(store.tasks.filter { $0.parentID == parent.id }.map(\.title), ["Pack"])
    }

    /// An edit that was changed but not yet committed is kept too; an open
    /// editor with nothing changed closes on a reveal, as before.
    func testAnUncommittedTitleChangeSurvivesARevealButAnUnchangedOneCloses() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let id = try XCTUnwrap(store.create(title: "Old")).id
        model.beginEditingTitle(id)
        model.resetForReveal()
        XCTAssertNil(model.editingTitleID, "nothing typed: the editor closes")
        model.beginEditingTitle(id)
        model.editingTitle = "Typed"
        model.resetForReveal()
        XCTAssertEqual(model.editingTitleID, id)
        XCTAssertEqual(model.editingTitle, "Typed")
        model.select(tab: .backlog)
        XCTAssertEqual(store.task(withID: id)?.title, "Typed", "moving page saves it")
        XCTAssertEqual(model.tab, .backlog)
    }

    // MARK: Round 2 #2: the Undo toast undoes only its own step

    func testTheToastNeverUndoesAChangeMadeAfterIt() throws {
        let store = try makeTestStore()
        let toasts = PanelToastCenter()
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, toasts: toasts)
        let doomed = try XCTUnwrap(store.create(title: "Doomed"))
        model.delete([doomed.id])
        XCTAssertNotNil(toasts.current, "Deleted … · Undo shows")

        model.addBar = TaskAddBarText(text: "Newer task")
        XCTAssertNotNil(model.submitAddBar())
        // Clicked before the page noticed: the button still does not reach
        // past its own step.
        let steps = library.undo.undoCount(in: .tasks)
        toasts.performAction()
        XCTAssertEqual(library.undo.undoCount(in: .tasks), steps)
        XCTAssertTrue(store.tasks.contains { $0.title == "Newer task" })
        XCTAssertNil(store.task(withID: doomed.id), "the delete stands too")

        // And once it has noticed, the stale toast is gone.
        let other = try XCTUnwrap(store.create(title: "Other"))
        model.delete([other.id])
        XCTAssertNotNil(toasts.current)
        model.addBar = TaskAddBarText(text: "Newest")
        XCTAssertNotNil(model.submitAddBar())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(toasts.current, "a newer change takes the toast away")
    }

    func testTheToastUndoesItsStepWhileItIsStillTheLatest() throws {
        let store = try makeTestStore()
        let toasts = PanelToastCenter()
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library, toasts: toasts)
        let task = try XCTUnwrap(store.create(title: "Keep me"))
        model.delete([task.id])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(toasts.current, "an unrelated redraw leaves the toast")
        toasts.performAction()
        XCTAssertNotNil(store.task(withID: task.id), "Undo brings it back")
    }

    // MARK: 3. Completing a family reads every copy of its subtasks

    func testCompletingAMainTaskCompletesASubtaskWhoseHiddenCopyIsStillOpen() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let childID = UUID()
        let context = ModelContext(store.container)
        let shown = TaskItem(id: childID, title: "Pack", status: .done, createdAt: base,
                             updatedAt: base.addingTimeInterval(60), completedAt: base, parentID: parent.id)
        let hidden = TaskItem(id: childID, title: "Pack", status: .todo, createdAt: base, updatedAt: base, parentID: parent.id)
        context.insert(shown)
        context.insert(hidden)
        try context.save()
        store.refresh()
        XCTAssertEqual(store.task(withID: childID)?.status, .done, "the copy shown is done")

        XCTAssertTrue(store.completeFamily(taskID: parent.id))
        XCTAssertTrue(try rows(store.container, childID).allSatisfy { $0.status == .done }, "the hidden open copy is completed too")
        XCTAssertEqual(store.task(withID: parent.id)?.status, .done)
    }

    func testCompletingAFamilyWhoseSubtaskCopiesDisagreeOnTheParentIsRefused() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let childID = UUID()
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: childID, title: "Pack", createdAt: base, updatedAt: base.addingTimeInterval(60), parentID: parent.id))
        context.insert(TaskItem(id: childID, title: "Pack", createdAt: base, updatedAt: base, parentID: other.id))
        try context.save()
        store.refresh()
        XCTAssertFalse(store.completeFamily(taskID: parent.id))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.task(withID: parent.id)?.status, .todo, "nothing changed")
        XCTAssertTrue(try rows(store.container, childID).allSatisfy { $0.status == .todo })
    }

    // MARK: 4. The Done log walks physical rows

    func testBG3FoldedHighVolumeDoneDayKeepsPagingUntilTheOlderDayIsReachable() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: base)
        let now = today.addingTimeInterval(16 * 3_600)
        let store = try makeTestStore(now: { now })
        let context = ModelContext(store.container)
        let older = UUID()
        for i in 0..<131 {
            let completed = today.addingTimeInterval(12 * 3_600 + Double(i))
            let item = TaskItem(id: UUID(), title: "Recent \(i)", status: .done,
                createdAt: today, updatedAt: completed, completedAt: completed)
            item.doneLoggedAt = completed
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        let oldCompletion = calendar.date(byAdding: .day, value: -2, to: today)!.addingTimeInterval(12 * 3_600)
        let old = TaskItem(id: older, title: "Older day", status: .done,
                           createdAt: oldCompletion, updatedAt: oldCompletion, completedAt: oldCompletion)
        old.doneLoggedAt = oldCompletion
        old.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(old)
        try context.save()
        store.refresh()
        let model = TasksPageModel(library: AtticLibrary(tasks: store),
                                   services: TasksPageServices(now: { now }, calendar: { calendar }))
        let size = CGSize(width: 360, height: 520)
        let page = TasksPage(model: model, store: store,
            layout: PanelPageLayout(cornerSize: 24, panelSize: size), addBarFocused: .constant(false))
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let window = KeyPanel(contentRect: CGRect(x: -8_000, y: -8_000, width: 360, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light, reduceMotion: true))
            .frame(width: 360, height: 520))
        window.orderFront(nil)
        window.makeKey()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        // TasksPage intentionally resets a newly shown page to Now. Select
        // Done after mounting, just as a real tab click does.
        model.select(tab: .done)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(model.tab, .done)
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        let recent = try XCTUnwrap(model.doneDays().first)
        model.toggleGroup(recent.key, on: .done)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // The paging contract is visibility-driven: scroll to the bottom
        // of the actually drawn Done list before expecting another page.
        func visibleList(in view: NSView) -> NSScrollView? {
            if let keeper = view as? TasksScrollKeeper.KeeperView,
               let scroll = keeper.enclosingScrollView {
                let frame = scroll.convert(scroll.bounds, to: window.contentView)
                if frame.width > size.width / 2, frame.height > size.height / 3,
                   frame.minX >= -1, frame.minX < size.width / 2 { return scroll }
            }
            return view.subviews.lazy.compactMap { visibleList(in: $0) }.first
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(window.contentView.flatMap { visibleList(in: $0) }, "Done must have a drawn scroll view")
        let contentHeight = try XCTUnwrap(scroll.documentView).bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, contentHeight - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<80 where !model.doneLogTasks.contains(where: { $0.id == older }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertTrue(model.doneLogTasks.contains { $0.id == older },
            "BG-3: a visible loading sentinel must keep paging through folded same-day rows")
        XCTAssertFalse(model.doneLogHasMore)
        XCTAssertTrue(model.folded(on: .done).contains(recent.key))
    }

    // MARK: 4b. The Done paging sentinel (pro-bugs-tasks-r1 fix 1)

    /// The real Done list in a key panel, off screen, with `days` of
    /// `(daysAgo, count)` done tasks (one completion a second from noon).
    private struct DoneHost {
        let model: TasksPageModel
        let window: NSPanel
        let size: CGSize
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func close() { window.orderOut(nil); window.contentView = nil; window.close() }
        /// The drawn Done list's scroll view.
        func list() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let keeper = view as? TasksScrollKeeper.KeeperView, let scroll = keeper.enclosingScrollView {
                    let frame = scroll.convert(scroll.bounds, to: window.contentView)
                    if frame.width > size.width / 2, frame.height > size.height / 3,
                       frame.minX >= -1, frame.minX < size.width / 2 { return scroll }
                }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView.flatMap { find($0) }
        }
        func scrollToBottom() {
            guard let scroll = list(), let document = scroll.documentView else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func mountDone(days: [(ago: Int, count: Int)]) throws -> DoneHost {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: base)
        let now = today.addingTimeInterval(16 * 3_600)
        let store = try makeTestStore(now: { now })
        let context = ModelContext(store.container)
        for day in days {
            let start = calendar.date(byAdding: .day, value: -day.ago, to: today)!
            for i in 0..<day.count {
                let completed = start.addingTimeInterval(12 * 3_600 + Double(i))
                let item = TaskItem(id: UUID(), title: "Day \(day.ago) task \(i)", status: .done,
                                    createdAt: start, updatedAt: completed, completedAt: completed)
                item.doneLoggedAt = completed
                item.listOrderVersion = TaskItem.currentListOrderVersion
                context.insert(item)
            }
        }
        try context.save()
        store.refresh()
        let model = TasksPageModel(library: AtticLibrary(tasks: store),
                                   services: TasksPageServices(now: { now }, calendar: { calendar }))
        let size = CGSize(width: 360, height: 520)
        let page = TasksPage(model: model, store: store,
            layout: PanelPageLayout(cornerSize: 24, panelSize: size), addBarFocused: .constant(false))
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let window = KeyPanel(contentRect: CGRect(x: -8_000, y: -8_000, width: 360, height: 520),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light, reduceMotion: true))
            .frame(width: 360, height: 520))
        window.orderFront(nil)
        window.makeKey()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let host = DoneHost(model: model, window: window, size: size)
        model.select(tab: .done)
        host.spin(1.2)
        XCTAssertEqual(model.tab, .done)
        model.loadDoneLogIfNeeded()
        return host
    }

    /// Dot R-1 (P1): a page that ends with one row of an open day leaves the
    /// sentinel on screen. It must still read the next page, with no scroll.
    /// (119 folded rows, one row of an open day, then more: a page ends there,
    /// and the open day's single row leaves the sentinel in view.)
    func testDoneSentinelStillOnScreenAfterAPageEndingInAnOpenDayReadsOneMore() throws {
        let host = try mountDone(days: [(0, 119), (2, 1), (4, 50)])
        defer { host.close() }
        let model = host.model
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        // Fold the first day: its rows leave and the sentinel comes up in view.
        let first = try XCTUnwrap(model.doneDays().first)
        model.toggleGroup(first.key, on: .done)
        for _ in 0..<150 where model.doneLogTasks.count < 160 { host.spin(0.03) }
        // 119 folded + 1 open row = 120 loaded: the sentinel is still in view and
        // reads on. The next page brings 40 open rows, which push it off screen:
        // the last 10 wait for a scroll.
        XCTAssertEqual(model.doneLogTasks.count, 160, "a visible sentinel keeps paging until it is pushed off screen")
        host.spin(0.5)
        XCTAssertEqual(model.doneLogTasks.count, 160, "and stops there")
        XCTAssertTrue(model.doneLogHasMore)
    }

    /// Opus R-3: one reach of the end is one page, though the sentinel
    /// announces itself twice (appearing, and scroll visibility).
    func testDoneSentinelReadsOnePagePerReachOfTheEnd() throws {
        let host = try mountDone(days: [(0, 130)])
        defer { host.close() }
        let model = host.model
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
        host.spin(0.5)
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize, "the sentinel is far below: nothing paged yet")
        host.scrollToBottom()
        host.spin(1.0)
        XCTAssertEqual(model.doneLogTasks.count, 2 * TasksPageModel.doneLogPageSize, "one reach of the end reads one page")
    }

    /// Opus R-3: a sentinel below the viewport, with a folded tail, pages on
    /// by itself only while it is actually on screen.
    func testDoneSentinelBelowTheViewportDoesNotPageOnByItself() throws {
        let host = try mountDone(days: [(0, 12), (2, 200)])
        defer { host.close() }
        let model = host.model
        let second = try XCTUnwrap(model.doneDays().dropFirst().first)
        model.toggleGroup(second.key, on: .done)
        host.spin(1.5)
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize,
                       "12 open rows and two headings fill the screen: the sentinel below them is not on screen")
        XCTAssertTrue(model.doneLogHasMore)
    }

    func testDoneLogPagesReachEveryTaskAcrossDuplicatesAndSupersededCopies() throws {
        let store = try makeTestStore()
        let context = ModelContext(store.container)
        func logged(_ title: String, id: UUID = UUID(), completed: TimeInterval, updated: TimeInterval = 0) -> TaskItem {
            let item = TaskItem(id: id, title: title, status: .done, createdAt: base,
                                updatedAt: base.addingTimeInterval(updated), completedAt: base.addingTimeInterval(completed))
            item.doneLoggedAt = base
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
            return item
        }
        // A: two logged copies that disagree (both sort first).
        let a = UUID()
        _ = logged("A shown", id: a, completed: 400, updated: 10)
        _ = logged("A hidden", id: a, completed: 399, updated: 1)
        // B: its logged copy is superseded by a newer live copy.
        let b = UUID()
        _ = logged("B old", id: b, completed: 300)
        let live = TaskItem(id: b, title: "B back in Now", createdAt: base, updatedAt: base.addingTimeInterval(99))
        live.listOrderVersion = TaskItem.currentListOrderVersion
        context.insert(live)
        _ = logged("C", completed: 200)
        _ = logged("D", completed: 100)
        try context.save()
        store.refresh()

        var seen: [String] = []
        var shown = Set<UUID>()
        var cursor = TaskStore.DoneLogCursor()
        var pages = 0
        repeat {
            let page = store.doneLogPage(from: cursor, limit: 1, excluding: shown)
            seen += page.tasks.map(\.title)
            shown.formUnion(page.tasks.map(\.id))
            cursor = page.next
            pages += 1
            if !page.hasMore { break }
        } while pages < 10
        XCTAssertEqual(seen, ["A shown", "C", "D"], "every logged task once; the superseded copy never shows")
        XCTAssertLessThan(pages, 10, "the walk always makes progress")
    }

    // MARK: 5. "Open page" works for a task in the Done log

    func testOpenPageOnADoneLogTaskShowsItsSubtasksAndKeptFiles() async throws {
        let root = ownedTemporaryDirectory(prefix: "AtticDoneDetail")

        let files = TaskImageFiles(rootURL: root.appendingPathComponent("files", isDirectory: true))
        let source = root.appendingPathComponent("plan.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: source)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let clock = MutableNow(base)
        let store = TaskStore(container: container, now: { clock.value }, taskImageFiles: files)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let task = try XCTUnwrap(store.create(title: "Ship"))
        _ = try XCTUnwrap(store.create(title: "Pack", parentID: task.id))
        let attached = await store.attachFiles([source], to: task.id)
        XCTAssertTrue(attached)
        XCTAssertTrue(store.completeFamily(taskID: task.id))
        clock.value = base.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: base.addingTimeInterval(86_400)), 2)
        XCTAssertNil(store.task(withID: task.id))

        model.openPage(task.id)
        XCTAssertEqual(model.doneDetailID, task.id, "a logged task opens its read-only details")
        let detail = try XCTUnwrap(model.doneDetail(for: task.id))
        XCTAssertEqual(detail.title, "Ship")
        XCTAssertEqual(detail.subtasks.map(\.title), ["Pack"])
        XCTAssertEqual(detail.files.map(\.filename), ["plan.txt"])
        let url = try await files.verifiedURL(for: try XCTUnwrap(detail.files.first))
        XCTAssertNotNil(url, "the file is kept while the task is in the log")

        // A task in the lists has no files list to open (Accepted
        // 2026-11-01 "Task rows: no paperclip count"): nothing changes.
        model.doneDetailID = nil
        let live = try XCTUnwrap(store.create(title: "Live"))
        model.openPage(live.id)
        XCTAssertNil(model.doneDetailID, "a task in the lists opens no details here")
    }

    // MARK: 6. Own focus rings only for the keyboard

    func testAButtonFocusedByAClickShowsNoRing() {
        XCTAssertFalse(AtticOwnFocusRing.shows(pinned: false, focused: true, keyboardFocusVisible: false))
        XCTAssertTrue(AtticOwnFocusRing.shows(pinned: false, focused: true, keyboardFocusVisible: true))
        XCTAssertTrue(AtticOwnFocusRing.shows(pinned: true, focused: false, keyboardFocusVisible: false), "the gallery's pinned state")
        XCTAssertFalse(AtticOwnFocusRing.shows(pinned: false, focused: false, keyboardFocusVisible: true))
    }
}
