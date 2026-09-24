import SwiftData
import XCTest
@testable import Attic

@MainActor
final class TaskDraftTests: XCTestCase {
    private let parser: TaskTextParser = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10))!
        return TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_US"), now: { now })
    }()

    // MARK: - Builder

    func testOneDraftPerLineSkipsBlankLinesAndListMarkers() {
        let text = """
        - Call mom tomorrow #family
        * [ ] Pay rent !!

        1. Book flights sep 30
        • Plain line
        """
        let drafts = TaskDraftBuilder(parser: parser).drafts(from: text, mode: .onePerLine)
        XCTAssertEqual(drafts.map(\.title), ["Call mom", "Pay rent", "Book flights", "Plain line"])
        XCTAssertEqual(drafts[0].tags, ["family"])
        XCTAssertEqual(drafts[0].dueDay, DueDay(year: 2026, month: 9, day: 25))
        XCTAssertEqual(drafts[1].priority, .high)
        XCTAssertEqual(drafts[2].dueDay, DueDay(year: 2026, month: 9, day: 30))
        XCTAssertTrue(drafts.allSatisfy { $0.status == .todo && $0.parentID == nil })
    }

    func testTheWholeTextCanBecomeOneDraft() {
        let drafts = TaskDraftBuilder(parser: parser, status: .backlog)
            .drafts(from: "Plan the offsite\nwith the team #work\n\n", mode: .single)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.title, "Plan the offsite with the team")
        XCTAssertEqual(drafts.first?.tags, ["work"])
        XCTAssertEqual(drafts.first?.status, .backlog)
    }

    func testTokenOnlyLinesKeepTheirTextAndInheritedTagsAreAdded() {
        let builder = TaskDraftBuilder(parser: parser, inheritedTags: ["Trip"])
        let drafts = builder.drafts(from: "#home\nPack bags", mode: .onePerLine)
        XCTAssertEqual(drafts.map(\.title), ["#home", "Pack bags"])
        XCTAssertEqual(drafts[0].tags, ["home", "trip"])
        XCTAssertEqual(drafts[1].tags, ["trip"])
        XCTAssertTrue(builder.drafts(from: " \n\t\n", mode: .onePerLine).isEmpty)
        XCTAssertTrue(builder.drafts(from: "", mode: .single).isEmpty)
    }

    // MARK: - Commit

    func testCommitCreatesEveryDraftInOneSaveInDraftOrder() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let drafts = TaskDraftBuilder(parser: parser).drafts(from: "First #a\nSecond tomorrow\nThird !", mode: .onePerLine)

        let created = try XCTUnwrap(store.commit(drafts))
        XCTAssertEqual(gate.saveCount, 1)
        XCTAssertEqual(created.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.title), ["Third", "First", "Second"],
                       "priority first, then the drafts' own order")
        XCTAssertEqual(created[0].tags, ["a"])
        XCTAssertEqual(created[1].dueDay, DueDay(year: 2026, month: 9, day: 25))
        XCTAssertEqual(created[2].priority, .medium)
        let stored = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first { $0.title == "Second" }?.dueDayRaw, "2026-09-25")
    }

    func testSameGroupDraftsKeepTheirOrderAboveExistingTasks() throws {
        let store = try makeTestStore()
        _ = try XCTUnwrap(store.create(title: "Existing"))
        let created = try XCTUnwrap(store.commit([TaskDraft(title: "A"), TaskDraft(title: "B"), TaskDraft(title: "C")]))
        XCTAssertEqual(created.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.title), ["A", "B", "C", "Existing"])
    }

    func testCommitIsAllOrNothing() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        XCTAssertTrue(store.markDone(parent))

        // One invalid draft refuses the whole batch.
        XCTAssertNil(store.commit([TaskDraft(title: "Fine"), TaskDraft(title: "Child", parentID: parent.id)]))
        XCTAssertNil(store.commit([TaskDraft(title: "Fine"), TaskDraft(title: "   ")]))
        // A failed save leaves nothing behind.
        gate.shouldFail = true
        XCTAssertNil(store.commit([TaskDraft(title: "One"), TaskDraft(title: "Two")]))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.tasks.map(\.id), [parent.id])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()), 1)
    }

    func testSubtaskDraftsJoinTheirParent() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Trip"))
        let drafts = TaskDraftBuilder(parser: parser, parentID: parent.id).drafts(from: "Book hotel\nPack", mode: .onePerLine)
        XCTAssertEqual(try XCTUnwrap(store.commit(drafts)).count, 2)
        XCTAssertEqual(Set(store.subtasks(of: parent.id).map(\.title)), ["Book hotel", "Pack"])
    }

    func testCommittingDraftsThroughTheLibraryIsOneUndoStep() throws {
        let store = try makeTestStore()
        let library = AtticLibrary(tasks: store)
        let drafts = TaskDraftBuilder(parser: parser).drafts(from: "One\nTwo\nThree", mode: .onePerLine)
        let created = try XCTUnwrap(library.createTasks(drafts))
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Add 3 Tasks")

        XCTAssertTrue(library.undo.undo(in: .tasks))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(Set(store.recentlyDeletedTasks().map(\.ref.id)), Set(created.map(\.id)))
        XCTAssertTrue(library.undo.redo(in: .tasks))
        XCTAssertEqual(Set(store.tasks.map(\.id)), Set(created.map(\.id)))
    }
}
