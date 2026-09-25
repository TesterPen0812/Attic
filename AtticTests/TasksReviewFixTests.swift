import SwiftData
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
        XCTAssertTrue(library.updateTasks([a.id, b.id], priority: .high))
        XCTAssertEqual(gate.saveCount, before + 1, "the whole batch is one save")

        gate.shouldFail = true
        let steps = library.undo.undoCount(in: .tasks)
        XCTAssertFalse(library.updateTasks([a.id, b.id, c.id], status: .backlog))
        XCTAssertFalse(library.updateTasks([a.id, b.id, c.id], status: .done))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDoneDetail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("files", isDirectory: true))
        let source = root.appendingPathComponent("plan.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: source)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let clock = MutableNow(base)
        let store = TaskStore(container: container, now: { clock.value }, taskImageFiles: files)
        var opened: [UUID] = []
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices(openPage: { opened.append($0) }))
        let task = try XCTUnwrap(store.create(title: "Ship"))
        _ = try XCTUnwrap(store.create(title: "Pack", parentID: task.id))
        let attached = await store.attachFiles([source], to: task.id)
        XCTAssertTrue(attached)
        XCTAssertTrue(store.completeFamily(taskID: task.id))
        clock.value = base.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: base.addingTimeInterval(86_400)), 2)
        XCTAssertNil(store.task(withID: task.id))

        model.openPage(task.id)
        XCTAssertTrue(opened.isEmpty, "the host's route can't show a logged task")
        XCTAssertEqual(model.doneDetailID, task.id)
        let detail = try XCTUnwrap(model.doneDetail(for: task.id))
        XCTAssertEqual(detail.title, "Ship")
        XCTAssertEqual(detail.subtasks.map(\.title), ["Pack"])
        XCTAssertEqual(detail.files.map(\.filename), ["plan.txt"])
        let url = try await files.verifiedURL(for: try XCTUnwrap(detail.files.first))
        XCTAssertNotNil(url, "the file is kept while the task is in the log")

        let live = try XCTUnwrap(store.create(title: "Live"))
        model.openPage(live.id)
        XCTAssertEqual(opened, [live.id], "a task in the lists still goes to the host's route")
    }

    // MARK: 6. Own focus rings only for the keyboard

    func testAButtonFocusedByAClickShowsNoRing() {
        XCTAssertFalse(AtticOwnFocusRing.shows(pinned: false, focused: true, keyboardFocusVisible: false))
        XCTAssertTrue(AtticOwnFocusRing.shows(pinned: false, focused: true, keyboardFocusVisible: true))
        XCTAssertTrue(AtticOwnFocusRing.shows(pinned: true, focused: false, keyboardFocusVisible: false), "the gallery's pinned state")
        XCTAssertFalse(AtticOwnFocusRing.shows(pinned: false, focused: false, keyboardFocusVisible: true))
    }
}
