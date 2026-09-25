import SwiftData
import XCTest
@testable import Attic

/// Undo across histories and across the daily cleanup (final review
/// findings 2 and 7): a step undoes only the fields it changed and keeps
/// what other histories changed since; redo records what it changed again;
/// a task the cleanup moved to the Done log can still be undone; and a step
/// that can never apply again no longer blocks the steps before it.
@MainActor
final class UndoInterleavingTests: XCTestCase {
    private let day: TimeInterval = 24 * 3_600

    private func makeLibrary(clock: MutableNow? = nil) throws -> AtticLibrary {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let now: () -> Date = { clock?.value ?? Date() }
        return AtticLibrary(
            tasks: TaskStore(container: container, now: now),
            notes: NoteStore(container: container, now: now, attachmentFileStore: makeTestAttachmentFileStore()),
            canvases: CanvasStore(container: container, now: now),
            now: now
        )
    }

    private func tags(_ library: AtticLibrary, _ id: UUID) -> [String]? {
        library.tasks.task(withID: id)?.tags
    }

    // MARK: - Tag operations across histories (finding 2)

    func testUndoingARenameKeepsATagAddedSinceThroughTheTasksHistory() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        XCTAssertTrue(library.setTags(["x"], on: AtticItemRef(.task, task.id)))
        XCTAssertTrue(library.setTags(["x"], on: AtticItemRef(.note, note.id)))

        XCTAssertTrue(library.renameTag("x", to: "y"))
        XCTAssertTrue(library.setTags(["y", "z"], on: AtticItemRef(.task, task.id)), "through the Tasks history")
        XCTAssertEqual(tags(library, task.id), ["y", "z"])

        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(tags(library, task.id), ["x", "z"], "the rename is undone and z, added since, is kept")
        XCTAssertEqual(library.notes?.note(withID: note.id)?.tags, ["x"])

        // The Tasks step now undoes only what it did: it added z.
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(tags(library, task.id), ["x"], "the rename's undo is kept")
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(tags(library, task.id), ["x", "z"])
    }

    func testUndoingAMergeKeepsTagsChangedSinceAndARedoRecordsWhatItChanged() throws {
        let library = try makeLibrary()
        let first = try XCTUnwrap(library.tasks.create(title: "One"))
        XCTAssertTrue(library.setTags(["a"], on: AtticItemRef(.task, first.id)))
        XCTAssertTrue(library.mergeTags(["a"], into: "t"))
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(tags(library, first.id), ["a"])

        // Between the undo and the redo, a new task gains the source tag.
        let later = try XCTUnwrap(library.createTasks([TaskDraft(title: "Later", tags: ["a"])])?.first)
        XCTAssertTrue(library.undo.redo(in: .library))
        XCTAssertEqual(tags(library, first.id), ["t"])
        XCTAssertEqual(tags(library, later.id), ["t"], "the redo merges every row carrying the tag now")

        // The next undo covers what that redo changed, the new task included.
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(tags(library, first.id), ["a"])
        XCTAssertEqual(tags(library, later.id), ["a"], "the row created in between is covered too")
        XCTAssertEqual(library.tags.counts(), [TagCount(name: "a", count: 2)])
    }

    func testUndoingATagChangeKeepsARenameMadeSinceInTheLibraryHistory() throws {
        let library = try makeLibrary()
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        let ref = AtticItemRef(.note, note.id)
        XCTAssertTrue(library.setTags(["y"], on: ref))
        XCTAssertTrue(library.setTags(["y", "z"], on: ref))
        XCTAssertTrue(library.renameTag("y", to: "w"))
        XCTAssertTrue(library.undo.undo(in: .note(note.id)))
        XCTAssertEqual(library.notes?.note(withID: note.id)?.tags, ["w"], "z is removed; the rename stays")
    }

    // MARK: - Task edits and moves are field-specific (finding 2)

    func testUndoingAnEditRestoresOnlyTheFieldsItChanged() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Draft"))
        XCTAssertTrue(library.setTags(["t"], on: AtticItemRef(.task, task.id)))
        XCTAssertTrue(library.updateTask(task.id, title: "Final"))
        // Since the edit: a tag rename in the library history, and a
        // priority change made outside the route.
        XCTAssertTrue(library.renameTag("t", to: "u"))
        // The rename refreshed the store; read the task afresh.
        XCTAssertTrue(library.tasks.setPriority(.high, for: try XCTUnwrap(library.tasks.task(withID: task.id))))

        XCTAssertTrue(library.undo.undo(in: .tasks))
        var current = try XCTUnwrap(library.tasks.task(withID: task.id))
        XCTAssertEqual(current.title, "Draft")
        XCTAssertEqual(current.tags, ["u"], "the rename made since is kept")
        XCTAssertEqual(current.priority, .high, "the priority changed since is kept")
        XCTAssertTrue(library.undo.redo(in: .tasks))
        current = try XCTUnwrap(library.tasks.task(withID: task.id))
        XCTAssertEqual(current.title, "Final")
        XCTAssertEqual(current.tags, ["u"])
        XCTAssertEqual(current.priority, .high)
    }

    func testUndoingAMoveRestoresOnlyTheOrder() throws {
        let library = try makeLibrary()
        let created = try XCTUnwrap(library.tasks.commit([TaskDraft(title: "A"), TaskDraft(title: "B"), TaskDraft(title: "C")]))
        XCTAssertTrue(library.moveTask(created[2].id, relativeTo: created[0].id))
        XCTAssertTrue(library.tasks.rename(created[1], to: "B renamed"), "renamed outside the route")
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.orderedTasks(for: .todo).map(\.title), ["A", "B renamed", "C"],
                       "the order is restored and the rename made since is kept")
    }

    func testAStepWhoseEveryFieldChangedSinceIsDroppedAndTheEarlierStepStillUndoes() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Draft"))
        let due = try XCTUnwrap(DueDay(year: 2026, month: 10, day: 1))
        XCTAssertTrue(library.updateTask(task.id, dueDay: .some(due)))
        XCTAssertTrue(library.updateTask(task.id, title: "Final"))
        XCTAssertTrue(library.tasks.rename(task, to: "Other"), "changed outside the route")
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 2)

        XCTAssertFalse(library.undo.undo(in: .tasks), "the title step can't apply: the title changed since")
        XCTAssertEqual(task.title, "Other", "the newer value is kept")
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1, "the stale step no longer blocks the history")
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNil(task.dueDay)
        XCTAssertEqual(task.title, "Other")
    }

    func testAStepForATaskDeletedSinceNoLongerBlocksEarlierSteps() throws {
        let library = try makeLibrary()
        let first = try XCTUnwrap(library.tasks.create(title: "First"))
        let second = try XCTUnwrap(library.tasks.create(title: "Second"))
        XCTAssertTrue(library.updateTask(first.id, title: "First edited"))
        XCTAssertTrue(library.updateTask(second.id, title: "Second edited"))
        XCTAssertTrue(library.tasks.delete(second), "deleted outside the route")

        XCTAssertFalse(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.task(withID: first.id)?.title, "First")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, second.id)), .deleted, "the deleted task is untouched")
    }

    // MARK: - Divergent replicas (astra re-check of finding 2)

    private func replicas(_ library: AtticLibrary, _ id: UUID) throws -> [TaskItem] {
        try ModelContext(library.tasks.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    /// An older copy of `task` holding its own title and tags, as a
    /// divergent replica from another device would.
    private func insertDivergentCopy(of task: TaskItem, title: String, tags: [String], in library: AtticLibrary) throws {
        let context = ModelContext(library.tasks.container)
        let copy = TaskItem(id: task.id, title: title, status: task.status, priority: task.priority,
                            createdAt: task.createdAt, updatedAt: task.updatedAt.addingTimeInterval(-3_600),
                            completedAt: task.completedAt, manualOrder: task.manualOrder, parentID: task.parentID)
        copy.tagsRaw = AtticTag.encode(tags)
        context.insert(copy)
        try context.save()
        library.tasks.refresh()
    }

    func testTagUndoAndRedoMoveEachReplicaByItsOwnDifference() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        XCTAssertTrue(library.setTags(["x"], on: AtticItemRef(.task, task.id)))
        XCTAssertTrue(library.setTags(["x", "z"], on: AtticItemRef(.task, task.id)), "the step: add z")
        let shown = try XCTUnwrap(library.tasks.task(withID: task.id))
        try insertDivergentCopy(of: shown, title: "Task", tags: ["x", "z", "q"], in: library)
        XCTAssertEqual(tags(library, task.id), ["x", "z"], "the newer copy is shown")

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(Set(try replicas(library, task.id).map(\.tags)), [["x"], ["q", "x"]],
                       "z is removed from each copy; q, held only by the divergent one, stays")
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(Set(try replicas(library, task.id).map(\.tags)), [["x", "z"], ["q", "x", "z"]])
    }

    func testAnEditUndoLeavesADivergentReplicasOwnValueAlone() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Draft"))
        XCTAssertTrue(library.updateTask(task.id, title: "Final"))
        let shown = try XCTUnwrap(library.tasks.task(withID: task.id))
        try insertDivergentCopy(of: shown, title: "Renamed elsewhere", tags: [], in: library)

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(Set(try replicas(library, task.id).map(\.title)), ["Draft", "Renamed elsewhere"])
        XCTAssertEqual(library.tasks.task(withID: task.id)?.title, "Draft")
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(Set(try replicas(library, task.id).map(\.title)), ["Final", "Renamed elsewhere"])
    }

    func testAMoveUndoLeavesADivergentReplicasOwnOrderAlone() throws {
        let library = try makeLibrary()
        let created = try XCTUnwrap(library.tasks.commit([TaskDraft(title: "A"), TaskDraft(title: "B"), TaskDraft(title: "C")]))
        XCTAssertTrue(library.moveTask(created[2].id, relativeTo: created[0].id))
        let shown = try XCTUnwrap(library.tasks.task(withID: created[2].id))
        let movedOrder = shown.manualOrder
        let context = ModelContext(library.tasks.container)
        let copy = TaskItem(id: shown.id, title: shown.title, createdAt: shown.createdAt,
                            updatedAt: shown.updatedAt.addingTimeInterval(-3_600), manualOrder: 999_999)
        context.insert(copy)
        try context.save()
        library.tasks.refresh()

        XCTAssertTrue(library.undo.undo(in: .tasks))
        let orders = Set(try replicas(library, created[2].id).map(\.manualOrder))
        XCTAssertTrue(orders.contains(999_999), "the divergent copy keeps its own order")
        XCTAssertFalse(orders.contains(movedOrder), "the shown copy's move was undone")
    }

    // MARK: - Across the daily cleanup (finding 7)

    private func cleanup(_ library: AtticLibrary, at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return DailyCleanupService(store: library.tasks, now: { date }, calendar: { calendar }).performCleanup(at: date)
    }

    func testACompletionCanBeUndoneAndRedoneAfterTheCleanupMovedTheTask() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
        let library = try makeLibrary(clock: clock)
        let earlier = try XCTUnwrap(library.createTasks([TaskDraft(title: "Earlier")])?.first)
        let task = try XCTUnwrap(library.createTasks([TaskDraft(title: "Finish")])?.first)
        let completedAt = clock.value
        XCTAssertTrue(library.updateTask(task.id, status: .done))
        clock.value += 2 * day
        XCTAssertEqual(cleanup(library, at: clock.value), 1)
        XCTAssertNil(library.tasks.task(withID: task.id))
        XCTAssertEqual(library.tasks.doneLog().map(\.id), [task.id])

        XCTAssertTrue(library.undo.undo(in: .tasks), "the Done-log record is found and restored")
        let restored = try XCTUnwrap(library.tasks.task(withID: task.id))
        XCTAssertEqual(restored.status, .todo)
        XCTAssertNil(restored.completedAt)
        XCTAssertTrue(library.tasks.doneLog().isEmpty)

        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(library.tasks.task(withID: task.id)?.status, .done)
        XCTAssertEqual(library.tasks.task(withID: task.id)?.completedAt, completedAt)
        XCTAssertEqual(cleanup(library, at: clock.value), 1, "the redone completion is moved again")
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.task(withID: task.id)?.status, .todo)

        // The earlier steps are still reachable.
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNil(library.tasks.task(withID: task.id))
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNil(library.tasks.task(withID: earlier.id))
        let rows = try ModelContext(library.tasks.container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2, "nothing was removed for good")
    }

    func testUndoingASubtasksCompletionBringsItsFamilyBackFromTheDoneLog() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
        let library = try makeLibrary(clock: clock)
        let parent = try XCTUnwrap(library.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(library.tasks.create(title: "Child", parentID: parent.id))
        let sibling = try XCTUnwrap(library.tasks.create(title: "Sibling", parentID: parent.id))
        XCTAssertTrue(library.tasks.markDone(sibling))
        XCTAssertTrue(library.updateTask(child.id, status: .done))
        XCTAssertTrue(library.updateTask(parent.id, status: .done))
        clock.value += 2 * day
        XCTAssertEqual(cleanup(library, at: clock.value), 3)
        XCTAssertTrue(library.tasks.tasks.isEmpty)

        XCTAssertTrue(library.undo.undo(in: .tasks), "undo the parent's completion")
        XCTAssertEqual(library.tasks.task(withID: parent.id)?.status, .todo)
        XCTAssertEqual(Set(library.tasks.subtasks(of: parent.id).map(\.id)), [child.id, sibling.id],
                       "the family returns together")
        XCTAssertTrue(library.tasks.doneLog().isEmpty)
        XCTAssertTrue(library.undo.undo(in: .tasks), "undo the child's completion")
        XCTAssertEqual(library.tasks.task(withID: child.id)?.status, .todo)
        XCTAssertEqual(library.tasks.task(withID: sibling.id)?.status, .done)
    }

    func testAnEditOfATaskNowInTheDoneLogIsUndoneWhereItIs() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
        let library = try makeLibrary(clock: clock)
        let task = try XCTUnwrap(library.tasks.create(title: "Draft"))
        XCTAssertTrue(library.updateTask(task.id, title: "Final"))
        XCTAssertTrue(library.tasks.markDone(task), "completed outside the route")
        clock.value += 2 * day
        XCTAssertEqual(cleanup(library, at: clock.value), 1)

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.doneLog().map(\.title), ["Draft"], "still done, still in the Done log")
        XCTAssertNil(library.tasks.task(withID: task.id))
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(library.tasks.doneLog().map(\.title), ["Final"])
    }
}
