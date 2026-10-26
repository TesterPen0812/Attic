import SwiftData
import XCTest
@testable import Attic

/// Tab indents a task under the one above it: one level, following Attic's
/// nesting rules. The store's nesting (placement, state, replicas, refusals)
/// and its one undoable "Indent" step through the Tasks history.
@MainActor
final class TaskIndentTests: XCTestCase {
    private var store: TaskStore!
    private var library: AtticLibrary!

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        store = try makeTestStore()
        library = AtticLibrary(tasks: store)
    }

    override func tearDown() {
        library = nil
        store = nil
    }

    private func make(_ title: String, _ status: TaskStatus = .todo, parent: UUID? = nil) throws -> TaskItem {
        try XCTUnwrap(store.create(title: title, status: status, parentID: parent))
    }

    private func titles(of parent: UUID) -> [String] {
        store.subtasks(of: parent).map(\.title)
    }

    private func mainTitles(_ status: TaskStatus) -> [String] {
        store.orderedTasks(for: status).filter { $0.parentID == nil }.map(\.title)
    }

    private func rows(_ id: UUID) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    // MARK: - Indent

    /// A Now task goes to the end of the task above's open subtasks (before
    /// its finished ones), keeping its state. One Undo puts it back exactly
    /// (main task, same state, same place); Redo indents it again.
    func testIndentingANowTaskIsOneUndoableStep() throws {
        let trip = try make("Trip")
        _ = try make("Pack", parent: trip.id)
        let old = try make("Old", parent: trip.id)
        XCTAssertTrue(library.updateTask(old.id, status: .done).isApplied)
        let book = try make("Book flights")
        let nowBefore = mainTitles(.todo)
        let orderBefore = book.manualOrder

        XCTAssertTrue(library.indentTask(book.id, under: trip.id).isApplied)
        let nested = try XCTUnwrap(store.task(withID: book.id))
        XCTAssertEqual(nested.parentID, trip.id)
        XCTAssertEqual(nested.status, .todo)
        XCTAssertEqual(titles(of: trip.id), ["Pack", "Book flights", "Old"], "at the end of the open subtasks")
        XCTAssertFalse(mainTitles(.todo).contains("Book flights"))
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Indent")

        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        let back = try XCTUnwrap(store.task(withID: book.id))
        XCTAssertNil(back.parentID, "Undo makes it a main task again")
        XCTAssertEqual(back.status, .todo)
        XCTAssertEqual(back.manualOrder, orderBefore, "in its old place")
        XCTAssertEqual(mainTitles(.todo), nowBefore)
        XCTAssertEqual(titles(of: trip.id), ["Pack", "Old"])

        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id)
        XCTAssertEqual(titles(of: trip.id), ["Pack", "Book flights", "Old"])
    }

    /// A Later task nested under a Later task becomes an open (.todo)
    /// subtask of it, as other subtasks of a Later task are; Undo brings
    /// back its Later state and place. An In Progress task keeps its state.
    func testIndentingALaterTaskMakesItATodoSubtask() throws {
        let someday = try make("Someday", .backlog)
        let idea = try make("Sketch it", .backlog)
        let laterBefore = mainTitles(.backlog)
        let orderBefore = idea.manualOrder

        XCTAssertTrue(library.indentTask(idea.id, under: someday.id).isApplied)
        XCTAssertEqual(store.task(withID: idea.id)?.parentID, someday.id)
        XCTAssertEqual(store.task(withID: idea.id)?.status, .todo)
        XCTAssertEqual(titles(of: someday.id), ["Sketch it"], "still in the family")

        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: idea.id)?.parentID)
        XCTAssertEqual(store.task(withID: idea.id)?.status, .backlog, "Undo puts its Later state back")
        XCTAssertEqual(store.task(withID: idea.id)?.manualOrder, orderBefore)
        XCTAssertEqual(mainTitles(.backlog), laterBefore)

        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: idea.id)?.parentID, someday.id)
        XCTAssertEqual(store.task(withID: idea.id)?.status, .todo)

        let launch = try make("Launch")
        let strings = try make("Freeze strings", .inProgress)
        XCTAssertTrue(library.indentTask(strings.id, under: launch.id).isApplied)
        XCTAssertEqual(store.task(withID: strings.id)?.status, .inProgress)
    }

    // MARK: - Refusals

    /// Each refusal writes nothing, is not retryable and records no step.
    func testIndentsThatAreRefused() throws {
        let trip = try make("Trip")
        let pack = try make("Pack", parent: trip.id)
        let party = try make("Party")
        _ = try make("Invite friends", parent: party.id)
        let finished = try make("Finished")
        XCTAssertTrue(library.updateTask(finished.id, status: .done).isApplied)
        let lone = try make("Lone")
        let finishedParent = try make("Finished parent")
        XCTAssertTrue(library.updateTask(finishedParent.id, status: .done).isApplied)
        let undoBefore = library.undo.undoName(in: .tasks)
        let before = store.revision

        func refused(_ id: UUID, under parent: UUID, _ message: String, _ why: String) {
            let outcome = library.indentTask(id, under: parent)
            XCTAssertFalse(outcome.isApplied, why)
            XCTAssertEqual(outcome.failure?.canRetry, false, "a rule, not a save: \(why)")
            XCTAssertEqual(outcome.failure?.message, message, why)
        }
        refused(party.id, under: trip.id, "A task with subtasks can’t become a subtask.", "one level deep")
        refused(finished.id, under: trip.id, "Only an unfinished main task can become a subtask.", "a done task")
        refused(lone.id, under: finishedParent.id, "A task can only become a subtask of an unfinished main task.", "a done parent")
        refused(lone.id, under: pack.id, "A task can only become a subtask of an unfinished main task.", "never under a subtask")
        refused(lone.id, under: lone.id, "A task can only become a subtask of an unfinished main task.", "not under itself")
        refused(pack.id, under: party.id, "Only an unfinished main task can become a subtask.", "already a subtask")

        XCTAssertEqual(store.revision, before, "nothing was written")
        XCTAssertNil(store.task(withID: lone.id)?.parentID)
        XCTAssertNil(store.task(withID: party.id)?.parentID)
        XCTAssertEqual(store.task(withID: pack.id)?.parentID, trip.id)
        XCTAssertEqual(library.undo.undoName(in: .tasks), undoBefore, "no step recorded")
    }

    /// A task with writing on its page stays a main task; a page holding
    /// only its title is not writing.
    func testATaskWithWritingRefuses() throws {
        let trip = try make("Trip")
        let essay = try make("Essay")
        let blank = try make("Blank page")
        let context = ModelContext(store.container)
        let written = NoteItem(id: UUID(), title: "Essay", body: "Draft", createdAt: base)
        written.taskID = essay.id
        written.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Essay"), .text("Draft")], requires: ["taskNote"]))
        context.insert(written)
        let titleOnly = NoteItem(id: UUID(), title: "Blank page", body: "", createdAt: base)
        titleOnly.taskID = blank.id
        titleOnly.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Blank page")], requires: ["taskNote"]))
        context.insert(titleOnly)
        try context.save()
        store.refresh()
        let before = store.revision

        let outcome = library.indentTask(essay.id, under: trip.id)
        XCTAssertFalse(outcome.isApplied)
        XCTAssertEqual(outcome.failure?.message, "A task with writing can’t become a subtask.")
        XCTAssertEqual(outcome.failure?.canRetry, false)
        XCTAssertNil(store.task(withID: essay.id)?.parentID)
        XCTAssertEqual(store.revision, before, "nothing was written")

        XCTAssertTrue(library.indentTask(blank.id, under: trip.id).isApplied)
        XCTAssertEqual(store.task(withID: blank.id)?.parentID, trip.id)
    }

    // MARK: - Replicas

    /// Every agreeing copy is nested; copies that disagree about where the
    /// task belongs or whether it is finished refuse, writing nothing.
    func testEveryReplicaIsNestedAndDivergentCopiesRefuse() throws {
        let trip = try make("Trip")
        let party = try make("Party")

        let id = UUID()
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: id, title: "Book", status: .backlog, createdAt: base, updatedAt: base.addingTimeInterval(60)))
        context.insert(TaskItem(id: id, title: "Book", status: .backlog, createdAt: base, updatedAt: base))
        try context.save()
        store.refresh()
        XCTAssertTrue(library.indentTask(id, under: trip.id).isApplied)
        XCTAssertEqual(try rows(id).map(\.parentID), [trip.id, trip.id], "every copy")
        XCTAssertEqual(try rows(id).map(\.status), [.todo, .todo])
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(try rows(id).map(\.parentID), [nil, nil], "Undo reaches every copy")
        XCTAssertEqual(try rows(id).map(\.status), [.backlog, .backlog])

        let split = UUID()
        let other = ModelContext(store.container)
        other.insert(TaskItem(id: split, title: "Split", createdAt: base, updatedAt: base.addingTimeInterval(60)))
        other.insert(TaskItem(id: split, title: "Split", createdAt: base, updatedAt: base, parentID: party.id))
        try other.save()
        store.refresh()
        let splitOutcome = library.indentTask(split, under: trip.id)
        XCTAssertFalse(splitOutcome.isApplied)
        XCTAssertEqual(splitOutcome.failure?.canRetry, false)
        XCTAssertEqual(Set(try rows(split).map(\.parentID)), [nil, party.id], "nothing was written")

        let torn = UUID()
        let third = ModelContext(store.container)
        third.insert(TaskItem(id: torn, title: "Torn", status: .todo, createdAt: base, updatedAt: base.addingTimeInterval(60)))
        third.insert(TaskItem(id: torn, title: "Torn", status: .done, createdAt: base, updatedAt: base, completedAt: base))
        try third.save()
        store.refresh()
        let tornOutcome = library.indentTask(torn, under: trip.id)
        XCTAssertFalse(tornOutcome.isApplied)
        XCTAssertEqual(tornOutcome.failure?.canRetry, false)
        XCTAssertEqual(try rows(torn).map(\.parentID), [nil, nil], "nothing was written")
        XCTAssertEqual(Set(try rows(torn).map(\.status)), [.todo, .done])
    }
}
