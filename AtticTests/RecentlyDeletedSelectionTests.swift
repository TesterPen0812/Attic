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

    // MARK: - Fix round: partial failures inside one bulk step (finding 5)

    private struct GatedFixture {
        let fixture: Fixture
        let gate: PersistenceGate
        let taskID: UUID
        let noteID: UUID
    }

    /// A deleted task and a deleted note, where the note store's saves can
    /// be made to fail.
    private func makeGatedFixture() throws -> GatedFixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let fixture = Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
        let taskID = try deleteTasks(["Plan"], in: fixture)[0]
        let note = try XCTUnwrap(notes.create(title: "Notes"))
        XCTAssertTrue(library.delete(AtticItemRef(.note, note.id)))
        return GatedFixture(fixture: fixture, gate: gate, taskID: taskID, noteID: note.id)
    }

    /// Redo that brings back only part of the step reports the failure and
    /// stays on the Redo list; the retry restores just what is still deleted.
    func testRedoAfterAPartialFailureFailsAndRetriesOnlyTheRest() throws {
        let gated = try makeGatedFixture()
        let fixture = gated.fixture
        let taskRef = AtticItemRef(.task, gated.taskID)
        let noteRef = AtticItemRef(.note, gated.noteID)
        let report = fixture.library.restoreRecentlyDeleted(items: [taskRef, noteRef], attachments: [])
        XCTAssertEqual(report.restored, 2)
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted)

        gated.gate.shouldFail = true
        XCTAssertEqual(fixture.library.undo.redoStep(in: .library), .failed, "part of it did not come back")
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID), "the task did")
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted, "the note did not")
        XCTAssertNotNil(fixture.library.lastErrorMessage, "the failure is reported")
        XCTAssertTrue(fixture.library.undo.canRedo(in: .library), "the step stays for a retry")

        gated.gate.shouldFail = false
        XCTAssertEqual(fixture.library.undo.redoStep(in: .library), .applied)
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID))
        XCTAssertEqual(fixture.library.state(of: noteRef), .live)
        XCTAssertFalse(fixture.library.undo.canRedo(in: .library))

        XCTAssertTrue(fixture.library.undo.undo(in: .library), "Undo sends both back again")
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted)
    }

    /// Undo that sends back only part of the step fails and keeps the step;
    /// the retry touches only what it has not sent back yet, so an item the
    /// person restored in the meantime stays restored.
    func testUndoAfterAPartialFailureRetriesOnlyTheRest() throws {
        let gated = try makeGatedFixture()
        let fixture = gated.fixture
        let taskRef = AtticItemRef(.task, gated.taskID)
        let noteRef = AtticItemRef(.note, gated.noteID)
        XCTAssertEqual(fixture.library.restoreRecentlyDeleted(items: [taskRef, noteRef], attachments: []).restored, 2)

        gated.gate.shouldFail = true
        XCTAssertEqual(fixture.library.undo.undoStep(in: .library), .failed)
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted, "the task went back")
        XCTAssertEqual(fixture.library.state(of: noteRef), .live, "the note did not")
        XCTAssertNotNil(fixture.library.lastErrorMessage)
        XCTAssertTrue(fixture.library.undo.canUndo(in: .library), "the step stays for a retry")

        // The person brings the task back by itself before retrying.
        XCTAssertTrue(fixture.library.restore(AtticItemRef(.task, gated.taskID), in: .tasks))
        gated.gate.shouldFail = false
        XCTAssertEqual(fixture.library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted, "the retry sent the note back")
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID), "and left the task the person restored")
    }
    // MARK: - Fix round: repeated items

    /// The same item listed twice is restored once and is not a failure.
    func testRestoreItemsIgnoresRepeatedItems() throws {
        let fixture = try makeFixture()
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let taskIDs = try deleteTasks(["A"], in: fixture)
        let noteItem: [String: Any] = ["kind": "note", "id": note.id.uuidString]
        let taskItem: [String: Any] = ["kind": "task", "id": taskIDs[0].uuidString]
        let tools = AgentTaskTools(store: fixture.tasks, library: fixture.library)

        let reply = try tools.call(name: "restore_items", arguments: ["items": [noteItem, taskItem, noteItem, taskItem]])
        XCTAssertFalse(reply.contains("\"reason\""), reply)
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertNotNil(fixture.tasks.task(withID: taskIDs[0]))
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore 2 Items")
    }

    /// The library ignores repeats too, whoever calls it.
    func testRestoreRecentlyDeletedIgnoresRepeatedItems() throws {
        let fixture = try makeFixture()
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let ref = AtticItemRef(.note, note.id)
        let report = fixture.library.restoreRecentlyDeleted(items: [ref, ref], attachments: [])
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
    }

    // MARK: - Fix round: keyboard focus on the list

    /// Tab reaching the list draws its ring before any arrow key; a click,
    /// an empty list or another focus draws none.
    @MainActor
    func testTheListShowsAFocusRingWhenTabReachesIt() {
        let tracker = AtticKeyboardFocusTracker()
        XCTAssertFalse(tracker.isKeyboardDriving)
        let ring = { RecentlyDeletedSettingsView.showsListFocusRing(listFocused: true, keyboardDriving: tracker.isKeyboardDriving, hasRows: true) }
        XCTAssertFalse(ring(), "a click gave it the keyboard: no ring")
        tracker.observe(.keyDown, keyCode: 48)
        XCTAssertTrue(ring(), "Tab reached it: the ring shows before the first arrow")
        tracker.observe(.leftMouseDown, keyCode: nil)
        XCTAssertFalse(ring(), "a click hides it again")
        XCTAssertFalse(RecentlyDeletedSettingsView.showsListFocusRing(listFocused: false, keyboardDriving: true, hasRows: true))
        XCTAssertFalse(RecentlyDeletedSettingsView.showsListFocusRing(listFocused: true, keyboardDriving: true, hasRows: false))
    }

    // MARK: - Fix round 2: a parent's delete and the subtasks the step tracks

    /// Fails the saves it is told to, in order, and lets the rest through.
    private final class SaveScript {
        /// `false` fails that save; an empty list lets every save through.
        var results: [Bool] = []

        func save(_ context: ModelContext) throws {
            if !results.isEmpty, !results.removeFirst() { throw PersistenceGate.Failure() }
            try context.save()
        }
    }

    private struct FamilyFixture {
        let fixture: Fixture
        let script: SaveScript
        let parent: AtticItemRef
        let child: AtticItemRef
    }

    /// A main task and its subtask, deleted separately (the subtask first),
    /// then restored together as one Restore Selected step.
    private func makeRestoredFamily() throws -> FamilyFixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let script = SaveScript()
        let tasks = TaskStore(container: container, now: { clock.value }, persist: { try script.save($0) })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let fixture = Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
        let parent = try XCTUnwrap(tasks.create(title: "Parent"))
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: parent.id))
        let parentRef = AtticItemRef(.task, parent.id)
        let childRef = AtticItemRef(.task, child.id)
        clock.value += 1
        XCTAssertTrue(library.delete(childRef))
        clock.value += 1
        XCTAssertTrue(library.delete(parentRef))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [childRef, parentRef], attachments: []).restored, 2)
        XCTAssertNotNil(tasks.task(withID: child.id))
        XCTAssertNotNil(tasks.task(withID: parent.id))
        return FamilyFixture(fixture: fixture, script: script, parent: parentRef, child: childRef)
    }

    /// The recheck's reproducer. Undo sends the subtask back, then its main
    /// task's save fails. The person restores the subtask on its own. The
    /// retry must not delete the main task, because that would take the
    /// subtask along and reverse the person's restore.
    func testUndoRetryDoesNotDeleteAParentPastASubtaskRestoredInTheMeantime() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library

        family.script.results = [true, false]
        XCTAssertEqual(library.undo.undoStep(in: .library), .failed, "the main task did not go back")
        XCTAssertEqual(library.state(of: family.child), .deleted, "the subtask did")
        XCTAssertEqual(library.state(of: family.parent), .live)

        family.script.results = []
        XCTAssertTrue(library.restore(family.child, in: .tasks), "the person restores the subtask")
        XCTAssertEqual(library.state(of: family.child), .live)

        _ = library.undo.undoStep(in: .library)
        XCTAssertEqual(library.state(of: family.child), .live, "the retry left what the person restored")
        XCTAssertEqual(library.state(of: family.parent), .live, "and kept its main task with it")
    }

    /// The same after a partial Redo: the subtask did not come back with the
    /// step, the person restored it, and Redo let go of it. Undo then reaches
    /// the main task alone and must not take that subtask with it.
    func testUndoDoesNotDeleteAParentPastASubtaskThatRedoLetGoOf() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .deleted)

        // Redo's batch save fails; then the main task comes back on its own
        // and the subtask's save fails.
        family.script.results = [false, true, false]
        XCTAssertEqual(library.undo.redoStep(in: .library), .failed)
        XCTAssertEqual(library.state(of: family.parent), .live, "the main task came back")
        XCTAssertEqual(library.state(of: family.child), .deleted, "the subtask did not")

        family.script.results = []
        XCTAssertTrue(library.restore(family.child, in: .tasks), "the person restores the subtask")
        XCTAssertEqual(library.undo.redoStep(in: .library), .applied, "the retry lets go of the subtask")

        XCTAssertEqual(library.undo.undoStep(in: .library), .obsolete, "nothing is left that the step may send back")
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.parent), .live)
    }

    /// A subtask that would not go back keeps its main task from going back
    /// in the same pass; the retry sends both.
    func testUndoDoesNotDeleteAParentPastASubtaskThatFailedInTheSamePass() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library

        family.script.results = [false]
        XCTAssertEqual(library.undo.undoStep(in: .library), .failed)
        XCTAssertEqual(library.state(of: family.child), .live, "the subtask stayed")
        XCTAssertEqual(library.state(of: family.parent), .live, "so its main task stayed with it")
        XCTAssertTrue(library.undo.canUndo(in: .library), "the step stays for a retry")

        family.script.results = []
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .deleted)
    }

    /// The same removed file listed twice comes back once, without a failure
    /// for the second copy of it.
    func testRestoreRecentlyDeletedIgnoresRepeatedAttachments() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Trip"))
        let reference = TaskImageReference(id: UUID(), filename: "map.png", digest: "abc", contentTypeIdentifier: "public.png", byteCount: 3)
        task.imageReferencesData = try JSONEncoder().encode([reference])
        XCTAssertTrue(fixture.tasks.removeAttachment(reference.id, from: task.id))
        let summary = try XCTUnwrap(fixture.library.recentlyDeletedAttachments().first)

        let report = fixture.library.restoreRecentlyDeleted(items: [], attachments: [summary, summary])
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(fixture.tasks.task(withID: task.id)?.attachments.map(\.id), [reference.id])
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore Item")
    }

    // MARK: - Fix round 3: a family delete only takes what its step owns

    /// A main task with two subtasks and a note, nothing deleted yet.
    private struct OwnershipFixture {
        let fixture: Fixture
        let parent: AtticItemRef
        let child: AtticItemRef
        let sibling: AtticItemRef
        let note: AtticItemRef
    }

    private func makeOwnershipFixture() throws -> OwnershipFixture {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        let sibling = try XCTUnwrap(fixture.tasks.create(title: "Sibling", parentID: parent.id))
        let note = try XCTUnwrap(fixture.notes.create(title: "Note"))
        return OwnershipFixture(
            fixture: fixture,
            parent: AtticItemRef(.task, parent.id),
            child: AtticItemRef(.task, child.id),
            sibling: AtticItemRef(.task, sibling.id),
            note: AtticItemRef(.note, note.id)
        )
    }

    /// Deletes the subtask, then its main task (with the other subtask), each
    /// as its own step in Tasks.
    private func deleteChildThenParent(_ family: OwnershipFixture) {
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.child))
        family.fixture.clock.value += 1
        XCTAssertTrue(library.delete(family.parent))
        family.fixture.clock.value += 1
    }

    /// The recheck's single-item reproducer. Delete C, then P (Tasks).
    /// Restore only P through Recently Deleted. Undo in Tasks twice (P's
    /// Delete is obsolete, C's Delete brings C back). Undo P's Restore: it
    /// must not delete P and so C, whose restore it never made.
    func testUndoOfASingleRestoreKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.restore(family.parent, in: .library))
        XCTAssertEqual(library.state(of: family.child), .deleted, "the child was deleted on its own")

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "P is live already")
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "C comes back")
        XCTAssertEqual(library.state(of: family.child), .live)

        XCTAssertEqual(library.undo.undoStep(in: .library), .obsolete, "the restore no longer reaches P")
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live, "C's restore was not undone")
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// The bulk variant: P is restored together with an unrelated note, so C
    /// is not tracked by the step at all.
    func testUndoOfABulkRestoreKeepsAChildItDidNotTrack() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(library.state(of: family.child), .live)

        XCTAssertEqual(library.undo.undoStep(in: .library), .applied, "the note still goes back")
        XCTAssertEqual(library.state(of: family.note), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .live, "P stays")
        XCTAssertEqual(library.state(of: family.child), .live, "and so does C")
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Ordinary single restore: Undo takes the whole family back, Redo brings
    /// it again, and Undo still takes the whole family (the ownership carries
    /// through Redo).
    func testOrdinarySingleRestoreUndoRedoUndoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.restore(family.parent, in: .library))
        let refs = [family.parent, family.child, family.sibling]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
        }
    }

    /// Ordinary bulk restore, through Undo, Redo and Undo again.
    func testOrdinaryBulkRestoreUndoRedoUndoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)
        let refs = [family.parent, family.child, family.sibling, family.note]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live, .live])
        }
    }

    /// Redo of a bulk restore owns what that restore brought back this time,
    /// not what the first one did. A subtask deleted on its own before the
    /// Undo is not part of the Redo, so restoring it through another history
    /// afterwards is not something a later Undo may reverse.
    func testRedoOfABulkRestoreOwnsWhatItRestoredThisTime() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)
        XCTAssertTrue(library.delete(family.child), "the subtask goes on its own")
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted, "Redo did not bring it back")
        XCTAssertTrue(library.restore(family.child, in: .tasks))

        XCTAssertEqual(library.undo.undoStep(in: .library), .applied, "the note goes back")
        XCTAssertEqual(library.state(of: family.note), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Redo of a Delete takes the family it took, and no more: a subtask
    /// restored through Recently Deleted while the Delete was undone stays.
    func testRedoOfADeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "P comes back; C was deleted on its own")
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertTrue(library.restore(family.child, in: .library))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete, "Redo no longer reaches P")
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Ordinary Delete: Undo, Redo, Undo, Redo each move the whole family.
    func testOrdinaryDeleteUndoRedoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        let refs = [family.parent, family.child, family.sibling]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
        }
    }

    /// Redo of a multi-selection Delete keeps a subtask restored meanwhile.
    func testRedoOfABulkDeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        let other = try XCTUnwrap(family.fixture.tasks.create(title: "Other"))
        XCTAssertTrue(library.delete(family.child))
        family.fixture.clock.value += 1
        XCTAssertTrue(library.deleteTasks([family.parent.id, other.id]).isApplied)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertTrue(library.restore(family.child, in: .library))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete)
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: AtticItemRef(.task, other.id)), .live)
    }

    /// Ordinary multi-selection Delete, through Undo and Redo.
    func testOrdinaryBulkDeleteUndoRedoMovesEveryFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        let other = try XCTUnwrap(family.fixture.tasks.create(title: "Other"))
        let otherRef = AtticItemRef(.task, other.id)
        XCTAssertTrue(library.deleteTasks([family.parent.id, other.id]).isApplied)
        let refs = [family.parent, family.child, family.sibling, otherRef]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted, .deleted])
        }
    }

    /// Undo of Add Task keeps a subtask that came back under it through
    /// Recently Deleted after its own Add was undone.
    func testUndoOfAddTaskKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(library.createTasks([TaskDraft(title: "Parent")])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: parent.id)])?.first)
        let parentRef = AtticItemRef(.task, parent.id)
        let childRef = AtticItemRef(.task, child.id)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "Add Child")
        XCTAssertTrue(library.restore(childRef, in: .library))

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "Add Parent no longer reaches P")
        XCTAssertEqual(library.state(of: parentRef), .live)
        XCTAssertEqual(library.state(of: childRef), .live)
    }

    /// Ordinary Add Task with a subtask: Undo, Redo, Undo in order.
    func testOrdinaryAddTaskUndoRedoMovesTheWholeFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(library.createTasks([TaskDraft(title: "Parent")])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: parent.id)])?.first)
        let refs = [AtticItemRef(.task, parent.id), AtticItemRef(.task, child.id)]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live])
        }
    }

    // MARK: - Fix round 4: every history closure deletes through the guard

    /// The recheck's Duplicate reproducer. Duplicate a task without
    /// subtasks (P), add C under P, Undo Add C, restore C through Recently
    /// Deleted, Undo Duplicate: it must not take C.
    func testUndoOfDuplicateKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let source = try XCTUnwrap(fixture.tasks.create(title: "Source"))
        let copy = try XCTUnwrap(library.duplicateTasks([source.id])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: copy.id)])?.first)
        let copyRef = AtticItemRef(.task, copy.id)
        let childRef = AtticItemRef(.task, child.id)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "Add Child")
        XCTAssertTrue(library.restore(childRef, in: .library))

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "Duplicate no longer reaches the copy")
        XCTAssertEqual(library.state(of: copyRef), .live)
        XCTAssertEqual(library.state(of: childRef), .live, "C's restore was not undone")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, source.id)), .live)
    }

    /// A duplicate that carries copied subtasks still undoes whole: the copies
    /// are the step's own.
    func testOrdinaryDuplicateWithSubtasksUndoRedoMovesTheWholeFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let source = try XCTUnwrap(fixture.tasks.create(title: "Source"))
        _ = try XCTUnwrap(fixture.tasks.create(title: "One", parentID: source.id))
        _ = try XCTUnwrap(fixture.tasks.create(title: "Two", parentID: source.id))
        let copy = try XCTUnwrap(library.duplicateTasks([source.id])?.first)
        let copyChildren = try fixture.tasks.subtasks(of: copy.id).map(\.id)
        XCTAssertEqual(copyChildren.count, 2)
        let refs = ([copy.id] + copyChildren).map { AtticItemRef(.task, $0) }
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
        }
        XCTAssertEqual(library.state(of: AtticItemRef(.task, source.id)), .live)
    }

    /// The recheck's Done-delete reproducer. P and C are in the Done log;
    /// delete C, then P. Undo P's Delete (C stays deleted), restore C through
    /// Recently Deleted, Redo P's Delete: it must not take C.
    func testRedoOfADoneDeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(library.deleteListedTasks([child.id]).isApplied)
        fixture.clock.value += 1
        XCTAssertTrue(library.deleteListedTasks([parent.id]).isApplied)
        fixture.clock.value += 1

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "P's Delete")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNil(fixture.tasks.listedTask(withID: child.id), "C was deleted on its own")
        XCTAssertTrue(library.restore(AtticItemRef(.task, child.id), in: .library))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete, "the Delete no longer reaches P")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id), "C's restore was not undone")
    }

    /// Ordinary Done delete of an archived family: Undo, Redo, Undo.
    func testOrdinaryDoneDeleteUndoRedoMovesTheWholeArchivedFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(library.deleteListedTasks([parent.id]).isApplied)
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
            XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertNil(fixture.tasks.listedTask(withID: parent.id))
            XCTAssertNil(fixture.tasks.listedTask(withID: child.id))
        }
    }

    /// A tripwire for the guard itself. Every Undo or Redo closure in the
    /// app deletes task families through `deleteFamiliesFromHistory` (or
    /// `deleteOutcome`, which needs the step's ownership). This reads the
    /// sources and fails when a raw family delete appears after an
    /// `undoOutcome:` / `redoOutcome:` label, or outside the functions that
    /// implement the guard or run a command's first delete.
    func testNoHistoryClosureDeletesAFamilyOutsideTheGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Attic")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasPrefix("TaskStore") }
        XCTAssertGreaterThan(files.count, 50, "the sources were found")
        let rawDelete = try NSRegularExpression(
            pattern: #"\.delete\(taskIDs:|\btasks\.delete\(|deleteFamiliesNow\(|performDelete\("#
        )
        // Functions that are the guard, or the first run of a command.
        let allowed: Set<String> = ["deleteFamiliesFromHistory", "deleteOutcome", "deleteFamiliesNow", "performDelete"]
        let historyMarkers = ["undoOutcome:", "redoOutcome:", "undo:", "redo:"]
        var violations: [String] = []
        var firstRunCalls = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var function = ""
            var inHistory = false
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let range = trimmed.range(of: #"func \w+"#, options: .regularExpression) {
                    function = String(trimmed[range].dropFirst(5))
                    inHistory = false
                    if trimmed.hasPrefix("func ") || trimmed.contains(" func ") { continue }
                }
                if trimmed.contains("UndoStep(") { inHistory = false }
                if historyMarkers.contains(where: { trimmed.contains($0) }) { inHistory = true }
                let range = NSRange(line.startIndex..., in: line)
                guard rawDelete.firstMatch(in: line, range: range) != nil, !trimmed.hasPrefix("//"),
                      !trimmed.hasPrefix("///") else { continue }
                if allowed.contains(function) { continue }
                if inHistory {
                    violations.append("\(file.lastPathComponent):\(index + 1) in \(function): \(trimmed)")
                } else {
                    firstRunCalls += 1
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "family deletes in a history closure: \(violations)")
        XCTAssertGreaterThanOrEqual(firstRunCalls, 3, "the scan still sees the commands' first deletes")
    }
}
