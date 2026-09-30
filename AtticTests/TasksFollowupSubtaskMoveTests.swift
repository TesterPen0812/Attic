import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 follow-up, control audit item 5: Move to Task… and Make
/// Standalone Task. The store's move (identity, placement, files, replicas,
/// one level), its one-step Undo through the Tasks history, the page's one
/// command list, the picker's filter, and the agent tool.
@MainActor
final class TasksFollowupSubtaskMoveTests: XCTestCase {
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore()
        library = AtticLibrary(tasks: store)
        model = TasksPageModel(library: library, services: TasksPageServices())
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func make(_ title: String, _ status: TaskStatus = .todo, parent: UUID? = nil) throws -> TaskItem {
        try XCTUnwrap(store.create(title: title, status: status, parentID: parent))
    }

    private func titles(of parent: UUID) -> [String] {
        store.subtasks(of: parent).map(\.title)
    }

    private func rows(_ id: UUID) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    private func file(_ name: String) -> TaskImageReference {
        TaskImageReference(id: UUID(), filename: name, digest: "d-\(name)", contentTypeIdentifier: "public.png", byteCount: 3)
    }

    // MARK: - Move to Task…

    /// The subtask keeps its id and everything it holds, goes to the end of
    /// the new task's open subtasks, and leaves its old family. One Undo
    /// puts it back exactly where it was; Redo moves it again.
    func testMoveToTaskKeepsIdentityAndIsOneUndoableStep() throws {
        let trip = try make("Plan the trip")
        let book = try make("Book flights", parent: trip.id)
        _ = try make("Pack", parent: trip.id)
        let party = try make("Party")
        _ = try make("Invite friends", parent: party.id)
        let day = DueDay(rawValue: "2026-10-09")!
        XCTAssertTrue(library.updateTask(book.id, priority: .high, tags: ["travel"], dueDay: .some(day)).isApplied)
        let tripOrder = titles(of: trip.id)
        let partyOrder = titles(of: party.id)

        XCTAssertTrue(model.moveSubtask(book.id, toTask: party.id).isApplied)
        let moved = try XCTUnwrap(store.task(withID: book.id), "the same task, by its id")
        XCTAssertEqual(moved.parentID, party.id)
        XCTAssertEqual(moved.title, "Book flights")
        XCTAssertEqual(moved.priority, .high)
        XCTAssertEqual(moved.tags, ["travel"])
        XCTAssertEqual(moved.dueDay, day)
        XCTAssertEqual(moved.status, .todo)
        XCTAssertEqual(titles(of: party.id), partyOrder + ["Book flights"], "at the end of its new family")
        XCTAssertEqual(titles(of: trip.id), tripOrder.filter { $0 != "Book flights" })
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Move to Task")

        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id, "one Undo puts it back")
        XCTAssertEqual(titles(of: trip.id), tripOrder, "in its old place")
        XCTAssertEqual(titles(of: party.id), partyOrder)
        XCTAssertTrue(model.redo().isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, party.id)
        XCTAssertEqual(titles(of: party.id), partyOrder + ["Book flights"])
    }

    /// A finished subtask keeps its state and joins the new family's
    /// finished ones (which list after the open ones).
    func testAFinishedSubtaskMovesAmongTheFinishedOnes() throws {
        let trip = try make("Trip")
        let done = try make("Renew passport", parent: trip.id)
        XCTAssertTrue(library.updateTask(done.id, status: .done).isApplied)
        let party = try make("Party")
        let open = try make("Invite", parent: party.id)
        let closed = try make("Pick a date", parent: party.id)
        XCTAssertTrue(library.updateTask(closed.id, status: .done).isApplied)
        _ = open
        XCTAssertTrue(model.moveSubtask(done.id, toTask: party.id).isApplied)
        XCTAssertEqual(store.task(withID: done.id)?.status, .done)
        XCTAssertNotNil(store.task(withID: done.id)?.completedAt)
        XCTAssertEqual(titles(of: party.id), ["Invite", "Pick a date", "Renew passport"])
    }

    /// Files: the subtask keeps the files on its own row (a legacy
    /// subtask attachment); the files attached to its old main task stay
    /// with that task; the new main task's files are untouched.
    func testFilesStayWithTheTaskTheyWereAttachedTo() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let party = try make("Party")
        let tripFile = file("map.png")
        let bookFile = file("ticket.png")
        let partyFile = file("invite.png")
        trip.imageReferencesData = try JSONEncoder().encode([tripFile])
        book.imageReferencesData = try JSONEncoder().encode([bookFile])
        party.imageReferencesData = try JSONEncoder().encode([partyFile])

        XCTAssertTrue(model.moveSubtask(book.id, toTask: party.id).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.attachments, [bookFile], "its own files go with it")
        XCTAssertEqual(store.task(withID: trip.id)?.attachments, [tripFile], "the old main task keeps its files")
        XCTAssertEqual(store.task(withID: party.id)?.attachments, [partyFile])
        XCTAssertEqual(store.attachmentOwnerID(for: book.id), party.id, "new files for it now go to its new main task")

        XCTAssertTrue(model.makeStandalone(book.id).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.attachments, [bookFile])
        XCTAssertEqual(store.attachmentOwnerID(for: book.id), book.id, "a task of its own owns its files")
    }

    /// Where it cannot go, nothing changes and the reason is said: a
    /// finished main task, another subtask, itself, a task that is not a
    /// subtask. Its own main task is no move at all.
    func testMovesThatAreRefused() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let other = try make("Pack", parent: trip.id)
        let finished = try make("Finished")
        XCTAssertTrue(library.updateTask(finished.id, status: .done).isApplied)
        let lone = try make("Lone")
        let before = store.revision

        let toDone = model.moveSubtask(book.id, toTask: finished.id)
        XCTAssertFalse(toDone.isApplied)
        XCTAssertEqual(toDone.failure?.canRetry, false, "a rule, not a save: no Retry")
        XCTAssertFalse(model.moveSubtask(book.id, toTask: other.id).isApplied, "never under a subtask")
        XCTAssertFalse(model.moveSubtask(book.id, toTask: book.id).isApplied)
        XCTAssertFalse(library.moveSubtask(lone.id, toTask: trip.id).isApplied, "a main task is not moved here")
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id)
        XCTAssertEqual(store.task(withID: lone.id)?.parentID, nil)
        XCTAssertTrue(library.moveSubtask(book.id, toTask: trip.id).isApplied, "its own main task: nothing to do")
        XCTAssertEqual(store.revision, before, "nothing was written")
        XCTAssertNil(library.undo.undoName(in: .tasks).flatMap { $0 == "Move to Task" ? $0 : nil })
    }

    /// The picker lists every unfinished main task in Now and Later but the
    /// subtask's own, each with where it is; typing filters.
    func testThePickerListsWhereASubtaskCanGo() throws {
        let trip = try make("Plan the trip")
        let book = try make("Book flights", parent: trip.id)
        _ = try make("Party")
        _ = try make("Someday trip", .backlog)
        let finished = try make("Finished trip")
        XCTAssertTrue(library.updateTask(finished.id, status: .done).isApplied)
        let choices = model.moveChoices(forSubtask: book.id)
        XCTAssertEqual(Set(choices.map(\.title)), ["Party", "Someday trip"])
        XCTAssertEqual(choices.first { $0.title == "Someday trip" }?.detail, "Later")
        XCTAssertEqual(choices.first { $0.title == "Party" }?.detail, "Now")
        XCTAssertEqual(TaskMovePickerView.filter(choices, query: " TRIP ").map(\.title), ["Someday trip"])
        XCTAssertEqual(TaskMovePickerView.filter(choices, query: "").count, 2)
        XCTAssertTrue(model.moveChoices(forSubtask: trip.id).isEmpty, "a main task has no Move to Task…")
    }

    // MARK: - Make Standalone Task

    /// It becomes a main task right below its old one, keeping its id; one
    /// Undo makes it a subtask again, in its old place.
    func testMakeStandaloneLandsBelowItsOldMainTaskAsOneStep() throws {
        _ = try make("Bottom")
        let trip = try make("Plan the trip")
        let book = try make("Book flights", parent: trip.id)
        _ = try make("Pack", parent: trip.id)
        _ = try make("Top")
        let familyOrder = titles(of: trip.id)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Top", "Plan the trip", "Bottom"])

        XCTAssertTrue(model.makeStandalone(book.id).isApplied)
        let task = try XCTUnwrap(store.task(withID: book.id))
        XCTAssertNil(task.parentID)
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Top", "Plan the trip", "Book flights", "Bottom"],
                       "right below its old main task")
        XCTAssertEqual(model.selection, [book.id], "the new task is selected")
        XCTAssertEqual(titles(of: trip.id), ["Pack"])
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Make Standalone Task")

        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id)
        XCTAssertEqual(titles(of: trip.id), familyOrder)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Top", "Plan the trip", "Bottom"])
        XCTAssertTrue(model.redo().isApplied)
        XCTAssertNil(store.task(withID: book.id)?.parentID)
    }

    /// An open subtask of a Later task stays in Later with it; one being
    /// worked on keeps that state in Now.
    func testMakeStandaloneKeepsItsPage() throws {
        let someday = try make("Someday", .backlog)
        let idea = try make("Sketch it", parent: someday.id)
        XCTAssertTrue(model.makeStandalone(idea.id).isApplied)
        XCTAssertEqual(store.task(withID: idea.id)?.status, .backlog)
        XCTAssertEqual(model.rows(for: .backlog).map(\.model.title), ["Someday", "Sketch it"])
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: idea.id)?.status, .todo, "Undo puts its own state back")

        let launch = try make("Launch")
        let strings = try make("Freeze strings", parent: launch.id)
        XCTAssertTrue(library.updateTask(strings.id, status: .inProgress).isApplied)
        XCTAssertTrue(model.makeStandalone(strings.id).isApplied)
        XCTAssertEqual(store.task(withID: strings.id)?.status, .inProgress)
    }

    // MARK: - Undo that can no longer apply

    /// Undo needs the old main task: once it is in Recently Deleted, the
    /// step refuses and nothing changes.
    func testUndoRefusesWhenTheOldMainTaskIsDeleted() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let party = try make("Party")
        XCTAssertTrue(model.moveSubtask(book.id, toTask: party.id).isApplied)
        XCTAssertTrue(library.delete(AtticItemRef(.task, trip.id), in: .library))
        let outcome = model.undo()
        XCTAssertFalse(outcome.isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, party.id, "nothing moved")
    }

    /// One level: a task made standalone that has since gained subtasks
    /// can't become a subtask again, so its Undo refuses.
    func testATaskWithSubtasksNeverBecomesASubtask() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        XCTAssertTrue(model.makeStandalone(book.id).isApplied)
        _ = try make("Pick seats", parent: book.id)
        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: book.id)?.parentID)
        XCTAssertEqual(titles(of: book.id), ["Pick seats"])
    }

    // MARK: - Replicas

    /// Every physical copy of the subtask moves; copies that disagree about
    /// where it belongs refuse the move rather than guess.
    func testEveryReplicaMovesAndDisagreeingCopiesRefuse() throws {
        let trip = try make("Trip")
        let party = try make("Party")
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: id, title: "Book", createdAt: base, updatedAt: base.addingTimeInterval(60), parentID: trip.id))
        context.insert(TaskItem(id: id, title: "Book", createdAt: base, updatedAt: base, parentID: trip.id))
        try context.save()
        store.refresh()
        XCTAssertTrue(library.moveSubtask(id, toTask: party.id).isApplied)
        XCTAssertEqual(try rows(id).map(\.parentID), [party.id, party.id], "every copy")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(try rows(id).map(\.parentID), [trip.id, trip.id], "Undo reaches every copy")

        let split = UUID()
        let other = ModelContext(store.container)
        other.insert(TaskItem(id: split, title: "Split", createdAt: base, updatedAt: base.addingTimeInterval(60), parentID: trip.id))
        other.insert(TaskItem(id: split, title: "Split", createdAt: base, updatedAt: base, parentID: party.id))
        try other.save()
        store.refresh()
        XCTAssertFalse(library.moveSubtask(split, toTask: party.id).isApplied)
        XCTAssertFalse(library.moveSubtask(split, toTask: nil).isApplied)
        XCTAssertEqual(Set(try rows(split).map(\.parentID)), [trip.id, party.id], "nothing was written")
    }

    // MARK: - One command list

    /// The quick look's subtask commands (its right-click menu, ⇧⌘I, the
    /// actions button and its VoiceOver actions are this one list) offer
    /// both; ⇧⌘I on the line opens the list instead of running anything.
    func testSubtaskCommandsOfferMoveAndMakeStandalone() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        hosted.model.setExpanded(row.id, true)
        let open = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == row.id })
        let subtask = try XCTUnwrap(open.subtasks.first { $0.title == "Merge" })
        let commands = hosted.page.subtaskCommands(subtask, of: row.id, in: open.subtasks)
        let titles = AtticMenuCommand.titles(in: commands)
        XCTAssertTrue(titles.contains("Move to Task…"), "\(titles)")
        XCTAssertTrue(titles.contains("Make Standalone Task"), "\(titles)")
        XCTAssertLessThan(try XCTUnwrap(titles.firstIndex(of: "Make Standalone Task")), try XCTUnwrap(titles.firstIndex(of: "Delete")))

        var shown = 0
        XCTAssertEqual(AtticMenuCommand.performSubtaskKey(key: "i", characters: "I", modifiers: [.command, .shift],
                                                          in: commands, showActions: { shown += 1 }), .handled)
        XCTAssertEqual(shown, 1, "⇧⌘I opens the line's menu")
        XCTAssertEqual(AtticMenuCommand.performSubtaskKey(key: "i", characters: "i", modifiers: .command,
                                                          in: commands, showActions: { shown += 1 }), .ignored)
        XCTAssertEqual(shown, 1)

        // The menu's Make Standalone Task is the command itself.
        let standalone = try XCTUnwrap(commands.first { $0.title == "Make Standalone Task" })
        standalone.action()
        hosted.spin(0.2)
        XCTAssertNil(hosted.store.task(withID: subtask.id)?.parentID)
        XCTAssertTrue(hosted.model.rows(for: .now).contains { $0.id == subtask.id }, "a row of its own on Now")
    }

    /// VoiceOver's actions on a subtask line include both commands, named.
    func testVoiceOverOffersBothCommands() {
        let commands = [
            AtticMenuCommand(verbatim: "Mark as Done", shortcut: AtticTaskShortcut.complete) {},
            AtticMenuCommand(verbatim: "Move to Task…", startsSection: true) {},
            AtticMenuCommand(verbatim: "Make Standalone Task") {}
        ]
        let spoken = commands.filter { !$0.isDisabled && $0.children.isEmpty && !$0.isHeader && $0.shortcut != AtticTaskShortcut.complete }
            .map(\.title)
        XCTAssertEqual(spoken, ["Move to Task…", "Make Standalone Task"])
    }

    // MARK: - Agent tool

    func testTheAgentToolMovesAndMakesStandalone() throws {
        let tools = AgentTaskTools(store: store, library: library)
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let party = try make("Party")
        _ = try tools.call(name: "move_subtask", arguments: ["id": book.id.uuidString, "parent_id": party.id.uuidString])
        XCTAssertEqual(store.task(withID: book.id)?.parentID, party.id)
        _ = try tools.call(name: "move_subtask", arguments: ["id": book.id.uuidString, "parent_id": NSNull()])
        XCTAssertNil(store.task(withID: book.id)?.parentID)
        XCTAssertThrowsError(try tools.call(name: "move_subtask", arguments: ["id": book.id.uuidString, "parent_id": party.id.uuidString]),
                             "a main task is not moved by this tool")
        XCTAssertTrue(tools.definitions.contains { $0["name"] as? String == "move_subtask" })
    }

    // MARK: - Fix round: divergent replicas (finding 1)

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Two physical copies of one subtask: the newer (shown) is open, the
    /// older is finished and carries its completion.
    private func insertDivergentSubtask(under parent: UUID, parentOfOlder: UUID? = nil) throws -> (id: UUID, finishedAt: Date) {
        let id = UUID()
        let finishedAt = base.addingTimeInterval(-3_600)
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: id, title: "Book", status: .todo, createdAt: base, updatedAt: base.addingTimeInterval(60), parentID: parent))
        context.insert(TaskItem(id: id, title: "Book", status: .done, createdAt: base, updatedAt: base, completedAt: finishedAt, parentID: parentOfOlder ?? parent))
        try context.save()
        store.refresh()
        return (id, finishedAt)
    }

    private func assertCopiesKeepTheirOwnState(_ id: UUID, finishedAt: Date, parent: UUID?, file: StaticString = #filePath, line: UInt = #line) throws {
        let copies = try rows(id)
        XCTAssertEqual(copies.count, 2, file: file, line: line)
        XCTAssertEqual(copies.map(\.parentID), [parent, parent], "every copy is under the same task", file: file, line: line)
        let open = try XCTUnwrap(copies.first { $0.statusRaw == TaskStatus.todo.rawValue }, "the open copy stays open", file: file, line: line)
        let finished = try XCTUnwrap(copies.first { $0.statusRaw == TaskStatus.done.rawValue }, "the finished copy stays finished", file: file, line: line)
        XCTAssertNil(open.completedAt, file: file, line: line)
        XCTAssertEqual(finished.completedAt, finishedAt, "and keeps when it was finished", file: file, line: line)
    }

    /// A move writes the parent and the placement, nothing else: the older
    /// finished copy stays finished (with its completion time) through the
    /// move, Undo and Redo.
    func testMovingASubtaskLeavesADivergentCopysCompletionAlone() throws {
        let trip = try make("Trip")
        let party = try make("Party")
        let (id, finishedAt) = try insertDivergentSubtask(under: trip.id)

        XCTAssertTrue(library.moveSubtask(id, toTask: party.id).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: party.id)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: trip.id)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: party.id)
    }

    /// A promotion that keeps the subtask's state writes placement only, so a
    /// divergent copy keeps its own completion through Undo and Redo too.
    func testMakingStandaloneLeavesADivergentCopysCompletionAlone() throws {
        let trip = try make("Trip")
        let (id, finishedAt) = try insertDivergentSubtask(under: trip.id)

        XCTAssertTrue(library.moveSubtask(id, toTask: nil).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: nil)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: trip.id)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: nil)
    }

    /// An open subtask of a Later task stays in Later when it becomes a task
    /// of its own: that changes its state, so copies that disagree about
    /// their completion refuse it before anything is written.
    func testPromotionThatChangesStateRefusesCopiesWithDifferentCompletion() throws {
        let later = try make("Later trip", .backlog)
        let (id, finishedAt) = try insertDivergentSubtask(under: later.id)

        XCTAssertFalse(library.moveSubtask(id, toTask: nil).isApplied)
        try assertCopiesKeepTheirOwnState(id, finishedAt: finishedAt, parent: later.id)
        XCTAssertNil(library.undo.undoName(in: .tasks), "no step was recorded")
    }

    // MARK: - Fix round: destinations and the replay state (finding 2)

    /// A destination with a newer unfinished copy and an older finished one
    /// is not an unfinished main task on every copy: the move is refused.
    func testMoveRefusesADestinationWithAFinishedCopy() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let destination = UUID()
        let context = ModelContext(store.container)
        context.insert(TaskItem(id: destination, title: "Party", status: .todo, createdAt: base, updatedAt: base.addingTimeInterval(60), manualOrder: 5_000))
        context.insert(TaskItem(id: destination, title: "Party", status: .done, createdAt: base, updatedAt: base, completedAt: base, manualOrder: 5_000))
        try context.save()
        store.refresh()

        XCTAssertFalse(library.moveSubtask(book.id, toTask: destination).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id, "nothing moved")
        XCTAssertNil(library.undo.undoName(in: .tasks))
    }

    /// Undo checks the child as it is now: a finished subtask was moved to B,
    /// its old main task A was finished and the subtask reopened through
    /// another history. Undo would leave an open subtask under a finished
    /// task, so it refuses and changes nothing.
    func testUndoRefusesToPutAReopenedSubtaskUnderAFinishedTask() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", .done, parent: trip.id)
        let party = try make("Party")
        XCTAssertTrue(library.moveSubtask(book.id, toTask: party.id).isApplied)
        XCTAssertTrue(library.updateTask(trip.id, status: .done, in: .library).isApplied)
        XCTAssertTrue(library.updateTask(book.id, status: .todo, in: .library).isApplied)

        XCTAssertFalse(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, party.id, "still under the open task")
        XCTAssertEqual(store.task(withID: book.id)?.status, .todo)
    }

    // MARK: - Fix round: unchanged siblings (finding 3)

    /// The step keeps only what the move changed. A sibling in the new family
    /// that was not touched and is deleted afterwards (the family panel
    /// deletes through the store) does not make Undo obsolete.
    func testADeletedUntouchedSiblingDoesNotMakeTheMoveNonUndoable() throws {
        let trip = try make("Trip")
        let book = try make("Book flights", parent: trip.id)
        let party = try make("Party")
        let invite = try make("Invite friends", parent: party.id)
        let context = ModelContext(store.container)
        let inviteID = invite.id
        for row in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == inviteID })) { row.manualOrder = 50_000 }
        try context.save()
        store.refresh()
        let before = try XCTUnwrap(store.editableState(of: invite.id))

        XCTAssertTrue(library.moveSubtask(book.id, toTask: party.id).isApplied)
        XCTAssertEqual(store.editableState(of: invite.id), before, "the sibling was not touched")
        XCTAssertTrue(store.delete(taskIDs: [invite.id]))

        XCTAssertTrue(library.undo(in: .tasks).isApplied, "the sibling's deletion does not matter")
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: book.id)?.parentID, party.id)
    }

    // MARK: - Fix round: standalone placement when the order gap is used up

    /// Made standalone, a subtask goes right below its old main task even when
    /// no order is left between that task and the next one: the group is
    /// re-spaced around the insertion point instead of sending the new task
    /// to the top.
    func testMakeStandaloneRespacesAroundTheInsertionPointWhenTheGapIsUsedUp() throws {
        let top = try make("Top")
        let trip = try make("Trip")
        let next = try make("Next")
        let book = try make("Book flights", parent: trip.id)
        let context = ModelContext(store.container)
        for (task, order) in [(top, Int64(9_000)), (trip, 501), (next, 500)] {
            let id = task.id
            for row in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })) { row.manualOrder = order }
        }
        try context.save()
        store.refresh()
        XCTAssertEqual(store.orderedTasks(for: .todo).filter { $0.parentID == nil }.map(\.title), ["Top", "Trip", "Next"])

        XCTAssertTrue(library.moveSubtask(book.id, toTask: nil).isApplied)
        XCTAssertEqual(store.orderedTasks(for: .todo).filter { $0.parentID == nil }.map(\.title),
                       ["Top", "Trip", "Book flights", "Next"], "right below its old main task")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.orderedTasks(for: .todo).filter { $0.parentID == nil }.map(\.title), ["Top", "Trip", "Next"])
        XCTAssertEqual(store.task(withID: book.id)?.parentID, trip.id)
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.orderedTasks(for: .todo).filter { $0.parentID == nil }.map(\.title),
                       ["Top", "Trip", "Book flights", "Next"])
    }

    // MARK: - Fix round 2: a promotion that changes the state, on agreeing copies

    /// Two agreeing open copies of a subtask; `newestFirst` decides whether
    /// the shown (newest) one is fetched before or after the other.
    private func insertAgreeingSubtask(under parent: UUID, newestFirst: Bool) throws -> UUID {
        let id = UUID()
        func copy(updatedAt: Date) -> TaskItem {
            let item = TaskItem(id: id, title: "Book", status: .todo, createdAt: base, updatedAt: updatedAt, parentID: parent)
            item.completedFromRaw = TaskStatus.inProgress.rawValue
            item.completedFromOrder = 7
            return item
        }
        let newest = copy(updatedAt: base.addingTimeInterval(60))
        let oldest = copy(updatedAt: base)
        let context = ModelContext(store.container)
        for item in newestFirst ? [newest, oldest] : [oldest, newest] { context.insert(item) }
        try context.save()
        store.refresh()
        return id
    }

    private func assertEveryCopy(_ id: UUID, parent: UUID?, status: TaskStatus, file: StaticString = #filePath, line: UInt = #line) throws {
        let copies = try rows(id)
        XCTAssertEqual(copies.count, 2, file: file, line: line)
        for copy in copies {
            XCTAssertEqual(copy.parentID, parent, "every copy's parent", file: file, line: line)
            XCTAssertEqual(copy.status, status, "every copy's state", file: file, line: line)
            XCTAssertNil(copy.completedAt, file: file, line: line)
            XCTAssertEqual(copy.completedFromRaw, TaskStatus.inProgress.rawValue, "completion origin is left alone", file: file, line: line)
            XCTAssertEqual(copy.completedFromOrder, 7, file: file, line: line)
        }
    }

    /// An open subtask of a Later task stays in Later when made standalone,
    /// on every copy, whichever copy is shown first; Undo and Redo move all
    /// of them too.
    func testMakeStandaloneMovesEveryAgreeingCopyToLater() throws {
        for newestFirst in [true, false] {
            let later = try make("Later trip \(newestFirst)", .backlog)
            let id = try insertAgreeingSubtask(under: later.id, newestFirst: newestFirst)
            try assertEveryCopy(id, parent: later.id, status: .todo)

            XCTAssertTrue(library.moveSubtask(id, toTask: nil).isApplied, "newestFirst \(newestFirst)")
            try assertEveryCopy(id, parent: nil, status: .backlog)
            XCTAssertTrue(library.undo(in: .tasks).isApplied)
            try assertEveryCopy(id, parent: later.id, status: .todo)
            XCTAssertTrue(library.redo(in: .tasks).isApplied)
            try assertEveryCopy(id, parent: nil, status: .backlog)
        }
    }
}
