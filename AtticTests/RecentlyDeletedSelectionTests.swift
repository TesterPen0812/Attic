import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 follow-up, control audit item 11: selection in Recently Deleted
/// (click, ⌘-click, ⇧-click, ⌘A, ↑ ↓), Restore Selected as one Undo step,
/// Delete Permanently… of exactly the selection after a confirmation, and
/// Empty All… still taking everything.
@MainActor
final class RecentlyDeletedSelectionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    private struct Fixture {
        let clock: MutableNow
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let canvases: CanvasStore
        let library: AtticLibrary
    }

    private func makeFixture() throws -> Fixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        return Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
    }

    /// Deletes tasks titled `titles`, one second apart (newest last, so
    /// the list shows them in reverse).
    private func deleteTasks(_ titles: [String], in fixture: Fixture) throws -> [UUID] {
        try titles.map { title in
            let task = try XCTUnwrap(fixture.tasks.create(title: title))
            fixture.clock.value += 1
            XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, task.id)))
            return task.id
        }
    }

    private func model(_ fixture: Fixture) -> RecentlyDeletedModel {
        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.reload()
        return model
    }

    private func entry(_ title: String, in model: RecentlyDeletedModel) throws -> RecentlyDeletedEntry {
        try XCTUnwrap(model.entries.first { $0.title == title })
    }

    // MARK: - Selection

    func testClickCommandClickShiftClickAndSelectAll() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C", "D"], in: fixture)
        let model = model(fixture)
        XCTAssertEqual(model.listedEntries.map(\.title), ["D", "C", "B", "A"], "newest first")

        model.click(try entry("C", in: model))
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C"])
        model.click(try entry("A", in: model), command: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C", "A"], "⌘-click adds")
        model.click(try entry("C", in: model), command: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["A"], "⌘-click again removes")
        model.click(try entry("A", in: model))
        model.click(try entry("D", in: model), shift: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["D", "C", "B", "A"], "⇧-click selects the run from the anchor")
        model.click(try entry("B", in: model), shift: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B", "A"], "the anchor stays where the run started")
        model.click(try entry("B", in: model))
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B"], "a plain click selects it alone")

        model.selectAll()
        XCTAssertEqual(model.selection.count, 4)
        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testArrowsMoveAndShiftArrowsGrowTheSelection() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C"], "↓ with nothing selected starts at the top")
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B"])
        model.moveCursor(by: 1, extending: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B", "A"], "⇧↓ grows it")
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["A"], "stays on the last row")
        XCTAssertEqual(model.cursor, try entry("A", in: model).id, "the keyboard's row (kept in view)")
    }

    /// Only listed entries stay selected: a search never hides what a
    /// command would touch.
    func testSearchingDropsWhatItHides() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["Book dentist", "Email testers", "Book flights"], in: fixture)
        let model = model(fixture)
        model.selectAll()
        model.query = "book"
        XCTAssertEqual(Set(model.selectedEntries.map(\.title)), ["Book dentist", "Book flights"])
        XCTAssertEqual(model.selection.count, 2, "the hidden one left the selection")
        model.query = ""
        XCTAssertEqual(model.selection.count, 2, "and does not come back by itself")
    }

    /// A row's commands act on the selection when the row is in it, and
    /// on the row alone otherwise; their titles count.
    func testARowsCommandsTargetTheSelectionOrTheRow() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.click(try entry("A", in: model))
        model.click(try entry("B", in: model), command: true)
        XCTAssertEqual(model.targets(for: try entry("A", in: model)).map(\.title), ["B", "A"])
        XCTAssertEqual(model.targets(for: try entry("C", in: model)).map(\.title), ["C"])
        XCTAssertEqual(RecentlyDeletedPresentation.restoreTitle(count: 2), "Restore 2 Items")
        XCTAssertEqual(RecentlyDeletedPresentation.deleteTitle(count: 2), "Delete 2 Items Permanently…")
        XCTAssertEqual(RecentlyDeletedPresentation.restoreTitle(count: 1), "Restore")
        XCTAssertEqual(RecentlyDeletedPresentation.deleteTitle(count: 1), "Delete Permanently…")
        XCTAssertEqual(RecentlyDeletedPresentation.selectedPhrase(2), "2 selected")
    }

    // MARK: - Restore Selected

    /// Several kinds at once come back, and one ⌘Z sends them all back.
    func testRestoreSelectedIsOneUndoStep() throws {
        let fixture = try makeFixture()
        let taskIDs = try deleteTasks(["Plan", "Pack"], in: fixture)
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        XCTAssertNotNil(fixture.canvases.createCanvas(name: "Keep"), "the last canvas is never deleted")
        let board = try XCTUnwrap(fixture.canvases.createCanvas(name: "Board"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.canvas, board.id)))
        let untouched = try deleteTasks(["Keep deleted"], in: fixture)
        let model = model(fixture)
        for title in ["Plan", "Pack", "Notes", "Board"] {
            model.click(try entry(title, in: model), command: true)
        }
        XCTAssertEqual(model.selection.count, 4)

        model.restoreSelected()
        XCTAssertNil(model.message)
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) != nil })
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertTrue(fixture.canvases.canvases.contains { $0.id == board.id })
        XCTAssertEqual(model.entries.map(\.title), ["Keep deleted"])
        XCTAssertTrue(model.selection.isEmpty, "what came back left the selection")
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore 4 Items")
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Plan", "Pack", "Notes", "Board", "Keep deleted"], "one ⌘Z sends all four back")
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) == nil })
        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) != nil }, "Redo restores them again")
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, untouched[0])), .deleted)
    }

    /// A subtask deleted on its own and its main task deleted later come
    /// back together; one that can't come back stays listed, with why,
    /// while the rest still return.
    func testRestoreSelectedBringsBackWhatItCanAndSaysWhy() throws {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        let orphanParent = try XCTUnwrap(fixture.tasks.create(title: "Other parent"))
        let orphan = try XCTUnwrap(fixture.tasks.create(title: "Orphan", parentID: orphanParent.id))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, child.id)))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, orphan.id)))
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, parent.id)))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, orphanParent.id)))
        let model = model(fixture)
        for title in ["Parent", "Child", "Orphan"] {
            model.click(try entry(title, in: model), command: true)
        }
        model.restoreSelected()
        XCTAssertNotNil(fixture.tasks.task(withID: parent.id))
        XCTAssertEqual(fixture.tasks.subtasks(of: parent.id).map(\.id), [child.id], "the subtask returns to its main task")
        XCTAssertNil(fixture.tasks.task(withID: orphan.id), "its main task is still deleted")
        XCTAssertEqual(model.message?.tone, .error)
        XCTAssertTrue(model.message?.text.hasPrefix("1 item couldn’t be restored") == true, model.message?.text ?? "")
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Orphan", "Other parent"])
        XCTAssertEqual(model.selectedEntries.map(\.title), ["Orphan"], "what stayed stays selected")
    }

    /// A removed file and a deleted task, selected together, come back
    /// together; one ⌘Z sends both back.
    func testRestoreSelectedTakesFilesAndItemsAsOneStep() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Trip"))
        let reference = TaskImageReference(id: UUID(), filename: "map.png", digest: "abc", contentTypeIdentifier: "public.png", byteCount: 3)
        task.imageReferencesData = try JSONEncoder().encode([reference])
        XCTAssertTrue(fixture.tasks.removeAttachment(reference.id, from: task.id))
        let old = try deleteTasks(["Old"], in: fixture)
        let model = model(fixture)
        XCTAssertEqual(Set(model.entries.map(\.kind)), [.task, .attachment])
        model.selectAll()
        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertEqual(fixture.tasks.task(withID: task.id)?.attachments.map(\.id), [reference.id])
        XCTAssertNotNil(fixture.tasks.task(withID: old[0]))
        XCTAssertTrue(model.entries.isEmpty)
        model.undo()
        XCTAssertEqual(Set(model.entries.map(\.kind)), [.task, .attachment], "one ⌘Z undoes both")
        XCTAssertTrue(fixture.tasks.task(withID: task.id)?.attachments.isEmpty == true)
    }

    // MARK: - Delete Permanently…

    /// Only the selection goes, only after the confirmation; Cancel keeps
    /// everything; Empty All… still counts everything, searched for or not.
    func testDeletePermanentlyRemovesExactlyTheSelectionAfterConfirming() throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.click(try entry("A", in: model))
        model.click(try entry("C", in: model), command: true)

        model.requestDeleteSelected()
        var request = try XCTUnwrap(model.emptyRequest)
        XCTAssertEqual(request.scope, .selected)
        XCTAssertEqual(request.count, 2)
        XCTAssertEqual(request.title, "Delete 2 Items Permanently?")
        XCTAssertEqual(request.confirmTitle, "Delete Permanently")
        XCTAssertEqual(request.confirmationText, "2 items will be removed for good. You can’t undo this.")
        model.cancelEmpty()
        XCTAssertEqual(model.entries.count, 3, "Cancel removes nothing")

        model.requestDeleteSelected()
        model.confirmEmpty()
        XCTAssertEqual(model.entries.map(\.title), ["B"])
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[0])), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[2])), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[1])), .deleted)

        // Empty All… takes what a search hides too, and says so.
        _ = try deleteTasks(["D"], in: fixture)
        model.reload()
        model.query = "D"
        model.requestEmpty()
        request = try XCTUnwrap(model.emptyRequest)
        XCTAssertEqual(request.scope, .all)
        XCTAssertEqual(request.count, 2, "everything here, not only what the search shows")
        XCTAssertEqual(request.title, "Empty Recently Deleted?")
        model.cancelEmpty()
    }

    /// With nothing selected there is nothing to confirm.
    func testNothingSelectedAsksNothing() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A"], in: fixture)
        let model = model(fixture)
        model.requestDeleteSelected()
        XCTAssertNil(model.emptyRequest)
        model.restoreSelected()
        XCTAssertEqual(model.entries.count, 1)
    }

    /// The page's keys and its Undo name: ⌘R restores, ⌘⌫ asks.
    func testKeys() {
        XCTAssertEqual(RecentlyDeletedKeys.restore, KeyboardShortcut("r", modifiers: .command))
        XCTAssertEqual(RecentlyDeletedKeys.delete, KeyboardShortcut(.delete, modifiers: .command))
        XCTAssertEqual(RecentlyDeletedKeys.selectAll, KeyboardShortcut("a", modifiers: .command))
    }

    /// Agents restore several as one step too (restore_items); nothing
    /// is restored when one of them is not in Recently Deleted.
    func testTheAgentToolRestoresSeveralAsOneStep() throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A", "B"], in: fixture)
        let live = try XCTUnwrap(fixture.tasks.create(title: "Live"))
        let tools = AgentTaskTools(store: fixture.tasks, library: fixture.library)
        let items: [[String: Any]] = ids.map { ["kind": "task", "id": $0.uuidString] }
        XCTAssertThrowsError(try tools.call(name: "restore_items", arguments: ["items": items + [["kind": "task", "id": live.id.uuidString]]]))
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) == nil }, "nothing restored")
        _ = try tools.call(name: "restore_items", arguments: ["items": items])
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) != nil })
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) == nil }, "one Undo")
    }

    // MARK: - Fix round: Undo of Restore Selected reaches the Done log (finding 4)

    /// A task the daily cleanup moved to the Done log, deleted, and restored
    /// comes back to the log (not the list); Undo sends it back to Recently
    /// Deleted with the ordinary task restored beside it.
    func testRestoreSelectedUndoSendsArchivedTasksBackToo() throws {
        let fixture = try makeFixture()
        let archived = try archivedTask("Archived", in: fixture)
        XCTAssertTrue(fixture.library.deleteListedTasks([archived]).isApplied)
        let ordinary = try deleteTasks(["Ordinary"], in: fixture)
        let model = model(fixture)
        model.selectAll()

        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived), "back in the Done log")
        XCTAssertNil(fixture.tasks.task(withID: archived))
        XCTAssertNotNil(fixture.tasks.task(withID: ordinary[0]))

        model.undo()
        XCTAssertNil(fixture.tasks.listedTask(withID: archived), "one Undo sends the archived task back too")
        XCTAssertNil(fixture.tasks.task(withID: ordinary[0]))
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, archived)), .deleted)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ordinary[0])), .deleted)
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Archived", "Ordinary"])

        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived), "Redo restores it to the log again")
        XCTAssertNotNil(fixture.tasks.task(withID: ordinary[0]))
    }

    /// An archived main task and its separately deleted archived subtask come
    /// back together, and Undo sends them back as two entries again, subtask
    /// first so the main task's delete does not take it along.
    func testRestoreSelectedUndoKeepsArchivedFamiliesApart() throws {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(fixture.library.deleteListedTasks([child.id]).isApplied)
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.deleteListedTasks([parent.id]).isApplied)
        let model = model(fixture)
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Parent", "Child"])
        model.selectAll()

        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))

        model.undo()
        XCTAssertNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNil(fixture.tasks.listedTask(withID: child.id))
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Parent", "Child"], "two entries again")
    }

    /// Restoring one archived task on its own undoes the same way.
    func testRestoreUndoOfASingleArchivedTaskSendsItBack() throws {
        let fixture = try makeFixture()
        let archived = try archivedTask("Archived", in: fixture)
        XCTAssertTrue(fixture.library.deleteListedTasks([archived]).isApplied)
        XCTAssertTrue(fixture.library.restore(AtticItemRef(.task, archived)))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived))
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertNil(fixture.tasks.listedTask(withID: archived))
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, archived)), .deleted)
    }

    private func archivedTask(_ title: String, in fixture: Fixture) throws -> UUID {
        let task = try XCTUnwrap(fixture.tasks.create(title: title))
        XCTAssertTrue(fixture.tasks.markDone(task))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 1)
        XCTAssertNil(fixture.tasks.task(withID: task.id))
        return task.id
    }
}
