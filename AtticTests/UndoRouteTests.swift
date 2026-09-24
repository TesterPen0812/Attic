import SwiftData
import XCTest
@testable import Attic

@MainActor
final class UndoRouteTests: XCTestCase {
    // MARK: - The route

    private final class Counter {
        var value = 0
        var failUndo = false
        var failRedo = false
    }

    private func step(_ counter: Counter, name: String = "Add") -> UndoStep {
        UndoStep(
            name: name,
            undo: { guard !counter.failUndo else { return false }; counter.value -= 1; return true },
            redo: { guard !counter.failRedo else { return false }; counter.value += 1; return true }
        )
    }

    func testAStepIsRecordedOnlyWhenTheChangeSucceeded() {
        let route = UndoRoute()
        let counter = Counter()
        XCTAssertFalse(route.perform(in: .tasks) { nil })
        XCTAssertFalse(route.canUndo(in: .tasks), "a failed operation leaves the history untouched (CVD-02)")
        XCTAssertTrue(route.perform(in: .tasks) { counter.value += 1; return step(counter) })
        XCTAssertEqual(route.undoName(in: .tasks), "Add")
    }

    func testUndoAndRedoWalkTheHistoryAndANewChangeClearsRedo() {
        let route = UndoRoute()
        let counter = Counter()
        for _ in 0..<2 { route.perform(in: .tasks) { counter.value += 1; return step(counter) } }
        XCTAssertTrue(route.undo(in: .tasks))
        XCTAssertTrue(route.undo(in: .tasks))
        XCTAssertFalse(route.undo(in: .tasks))
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(route.redo(in: .tasks))
        XCTAssertEqual(counter.value, 1)
        route.perform(in: .tasks) { counter.value += 1; return step(counter, name: "Other") }
        XCTAssertFalse(route.canRedo(in: .tasks))
        XCTAssertEqual(route.undoCount(in: .tasks), 2)
    }

    func testAFailedUndoOrRedoLeavesTheHistoryExactlyAsItWas() {
        let route = UndoRoute()
        let counter = Counter()
        route.perform(in: .tasks) { counter.value += 1; return step(counter) }
        counter.failUndo = true
        XCTAssertFalse(route.undo(in: .tasks))
        XCTAssertTrue(route.canUndo(in: .tasks))
        XCTAssertFalse(route.canRedo(in: .tasks))
        counter.failUndo = false
        XCTAssertTrue(route.undo(in: .tasks))
        counter.failRedo = true
        XCTAssertFalse(route.redo(in: .tasks))
        XCTAssertTrue(route.canRedo(in: .tasks))
        XCTAssertFalse(route.canUndo(in: .tasks))
        XCTAssertEqual(counter.value, 0)
    }

    func testHistoriesAreSeparateAndBounded() {
        let route = UndoRoute(limit: 3)
        let counter = Counter()
        let note = UndoHistoryID.note(UUID())
        for _ in 0..<5 { route.perform(in: .tasks) { counter.value += 1; return step(counter) } }
        route.perform(in: note) { counter.value += 1; return step(counter, name: "Type") }
        XCTAssertEqual(route.undoCount(in: .tasks), 3)
        XCTAssertEqual(route.undoName(in: note), "Type")
        XCTAssertFalse(route.canUndo(in: .canvas(UUID())))
        route.clear(note)
        XCTAssertFalse(route.canUndo(in: note))
        XCTAssertTrue(route.canUndo(in: .tasks))
    }

    /// History lives in the route, not in views: a released view model loses
    /// nothing.
    func testHistorySurvivesTheViewThatMadeTheChange() throws {
        @MainActor final class FakeTaskListViewModel {
            let library: AtticLibrary
            init(library: AtticLibrary) { self.library = library }
            func add(_ title: String) { library.createTasks([TaskDraft(title: title)]) }
        }
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        var viewModel: FakeTaskListViewModel? = FakeTaskListViewModel(library: library)
        weak var released = viewModel
        viewModel?.add("Survives")
        viewModel = nil
        XCTAssertNil(released)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertTrue(store.tasks.isEmpty)
    }

    // MARK: - One step per action type

    private func makeLibrary(persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> AtticLibrary {
        let container = try PersistenceController.makeContainer(inMemory: true)
        return AtticLibrary(
            tasks: TaskStore(container: container, persist: persist),
            notes: NoteStore(container: container, persist: persist, attachmentFileStore: makeTestAttachmentFileStore()),
            canvases: CanvasStore(container: container, persist: persist)
        )
    }

    func testCreateIsUndoable() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.createTasks([TaskDraft(title: "New")])?.first)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNil(library.tasks.task(withID: task.id))
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertNotNil(library.tasks.task(withID: task.id))
    }

    func testEditAndStateChangeRestoreTheExactEarlierValues() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let library = AtticLibrary(tasks: TaskStore(container: container, now: { clock.value }))
        let task = try XCTUnwrap(library.createTasks([TaskDraft(title: "Draft", priority: .low)])?.first)
        let due = DueDay(year: 2026, month: 10, day: 1)

        XCTAssertTrue(library.updateTask(task.id, title: "Final", priority: .high, tags: ["a"], dueDay: .some(due)))
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Edit Task")
        clock.value = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(library.updateTask(task.id, status: .done))
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Change Task State")
        XCTAssertEqual(task.completedAt, Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(task.status, .todo)
        XCTAssertNil(task.completedAt)
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(task.title, "Draft")
        XCTAssertEqual(task.priority, .low)
        XCTAssertEqual(task.tags, [])
        XCTAssertNil(task.dueDay)
        clock.value = Date(timeIntervalSince1970: 9_000)
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(task.title, "Final")
        XCTAssertEqual(task.dueDay, due)
        XCTAssertEqual(task.completedAt, Date(timeIntervalSince1970: 2_000), "redo restores the original completion time")
    }

    func testANoOpEditSucceedsWithoutAStep() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Same"))
        XCTAssertTrue(library.updateTask(task.id, title: "Same"))
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
    }

    func testMoveIsUndoable() throws {
        let library = try makeLibrary()
        let created = try XCTUnwrap(library.tasks.commit([TaskDraft(title: "A"), TaskDraft(title: "B"), TaskDraft(title: "C")]))
        XCTAssertEqual(library.tasks.orderedTasks(for: .todo).map(\.title), ["A", "B", "C"])
        XCTAssertTrue(library.moveTask(created[2].id, relativeTo: created[0].id))
        XCTAssertEqual(library.tasks.orderedTasks(for: .todo).map(\.title), ["C", "A", "B"])
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.orderedTasks(for: .todo).map(\.title), ["A", "B", "C"])
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(library.tasks.orderedTasks(for: .todo).map(\.title), ["C", "A", "B"])
    }

    func testDeleteAndRestoreAreUndoableForEveryKind() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        XCTAssertNotNil(library.canvases?.createCanvas(name: "Keep"))
        let board = try XCTUnwrap(library.canvases?.createCanvas(name: "Board"))
        let refs = [AtticItemRef(.task, task.id), AtticItemRef(.note, note.id), AtticItemRef(.canvas, board.id)]

        for ref in refs {
            XCTAssertTrue(library.delete(ref))
            XCTAssertEqual(library.state(of: ref), .deleted)
            XCTAssertTrue(library.undo.undo(in: AtticLibrary.defaultHistory(for: ref)))
            XCTAssertEqual(library.state(of: ref), .live)
            XCTAssertTrue(library.undo.redo(in: AtticLibrary.defaultHistory(for: ref)))
            XCTAssertEqual(library.state(of: ref), .deleted)
        }
        for ref in refs {
            XCTAssertTrue(library.restore(ref))
            XCTAssertEqual(library.undo.undoName(in: .library), "Restore \(AtticLibrary.noun(for: ref.kind))")
        }
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(library.state(of: refs[2]), .deleted)
    }

    func testTagAndLinkChangesAreUndoable() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        let taskRef = AtticItemRef(.task, task.id)
        XCTAssertTrue(library.setTags(["x"], on: taskRef))
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertEqual(library.tasks.task(withID: task.id)?.tags, [])

        let link = try XCTUnwrap(library.link(AtticItemRef(.note, note.id), to: taskRef, kind: .card))
        XCTAssertTrue(library.undo.undo(in: .note(note.id)))
        XCTAssertTrue(library.links.backlinks(to: taskRef).isEmpty)
        XCTAssertTrue(library.undo.redo(in: .note(note.id)))
        XCTAssertEqual(library.links.backlinks(to: taskRef).map(\.id), [link.id])
    }

    func testFailedStoreOperationsNeverReachTheHistory() throws {
        let gate = PersistenceGate()
        let library = try makeLibrary(persist: gate.save)
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        gate.shouldFail = true
        XCTAssertNil(library.createTasks([TaskDraft(title: "Fails")]))
        XCTAssertFalse(library.updateTask(task.id, title: "Fails"))
        XCTAssertFalse(library.delete(AtticItemRef(.task, task.id)))
        XCTAssertFalse(library.setTags(["x"], on: AtticItemRef(.task, task.id)))
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
        XCTAssertEqual(library.tasks.task(withID: task.id)?.title, "Task")
    }

    func testAnUndoWhoseSaveFailsStaysUndoable() throws {
        let gate = PersistenceGate()
        let library = try makeLibrary(persist: gate.save)
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        XCTAssertTrue(library.delete(AtticItemRef(.task, task.id)))
        gate.shouldFail = true
        XCTAssertFalse(library.undo.undo(in: .tasks))
        XCTAssertTrue(library.undo.canUndo(in: .tasks))
        XCTAssertNil(library.tasks.task(withID: task.id))
        gate.shouldFail = false
        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertNotNil(library.tasks.task(withID: task.id))
    }
}
