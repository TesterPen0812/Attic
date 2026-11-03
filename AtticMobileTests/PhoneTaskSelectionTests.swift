import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneTaskSelectionTests: XCTestCase {
    func testSelectionEditsAllPhysicalReplicasAndLeavesUnselectedTasksAlone() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let library = PhoneLibrary(container: container)
        let first = try library.createTask(title: "Review design")
        let second = try library.createTask(title: "Write tests")
        let untouched = try library.createTask(title: "Leave alone", status: .backlog)

        let replica = ModelContext(container)
        replica.insert(TaskItem(id: first.id, title: first.title, status: .todo,
                                createdAt: first.createdAt.addingTimeInterval(-30)))
        try replica.save()

        let day = try XCTUnwrap(DueDay(rawValue: "2028-04-21"))
        XCTAssertEqual(try library.editSelectedTasks(ids: [second.id, first.id, first.id],
                                                       change: .dueDay(day)).count, 2)
        _ = try library.editSelectedTasks(ids: [first.id, second.id], change: .priority(.high))
        _ = try library.editSelectedTasks(ids: [first.id, second.id], change: .addTag("#Team Work"))
        _ = try library.editSelectedTasks(ids: [first.id], change: .removeTag("TEAM_WORK"))

        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.filter { $0.id == first.id }.count, 2)
        XCTAssertTrue(rows.filter { $0.id == first.id }.allSatisfy {
            $0.dueDay == day && $0.priority == .high && $0.tags.isEmpty
        })
        XCTAssertTrue(rows.filter { $0.id == second.id }.allSatisfy {
            $0.dueDay == day && $0.priority == .high && $0.tags == ["team-work"]
        })
        XCTAssertEqual(try library.tasks().first { $0.id == untouched.id }?.listedStatus, .backlog)
        XCTAssertNil(rows.first { $0.id == untouched.id }?.dueDay)
    }

    func testFailedBulkCompletionDoesNotPartiallySaveOtherSelectedRoots() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let library = PhoneLibrary(container: container)
        let valid = try library.createTask(title: "Could finish")
        let blocked = try library.createTask(title: "Needs its step")
        _ = try PhoneTaskSubtasks(container: container).addSubtask(to: blocked.id, title: "Unfinished step")

        XCTAssertThrowsError(try library.editSelectedTasks(ids: [valid.id, blocked.id], change: .status(.done))) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .taskFamily)
        }
        let reader = ModelContext(container)
        let roots = try reader.fetch(FetchDescriptor<TaskItem>()).filter { $0.parentID == nil }
        XCTAssertEqual(roots.count, 2)
        XCTAssertTrue(roots.allSatisfy { $0.status == .todo && $0.completedAt == nil })

        // Moving every selected root into Later also clears all its dates.
        _ = try library.editSelectedTasks(ids: [valid.id, blocked.id], change: .status(.backlog))
        XCTAssertEqual(try library.tasks().filter { $0.parentID == nil && $0.listedStatus == .backlog }.count, 2)
    }

    func testBulkTagDeltaPreservesDivergentReplicaTags() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let library = PhoneLibrary(container: container)
        let root = try library.createTask(title: "Shared identity", tags: ["work"])
        let other = try library.createTask(title: "Second task", tags: ["personal"])
        let writer = ModelContext(container)
        let replica = TaskItem(id: root.id, title: root.title, status: .todo,
                               createdAt: root.createdAt.addingTimeInterval(-40))
        replica.tags = ["home"]
        writer.insert(replica)
        try writer.save()

        _ = try library.editSelectedTasks(ids: [root.id, other.id], change: .addTag("urgent"))
        let added = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(added.filter { $0.id == root.id }.map { Set($0.tags) }),
                       Set([Set(["work", "urgent"]), Set(["home", "urgent"])]))
        XCTAssertEqual(added.first { $0.id == other.id }?.tags, ["personal", "urgent"])

        _ = try library.editSelectedTasks(ids: [root.id, other.id], change: .removeTag("urgent"))
        let removed = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(Set(removed.filter { $0.id == root.id }.map { Set($0.tags) }),
                       Set([Set(["work"]), Set(["home"])]))
        XCTAssertEqual(removed.first { $0.id == other.id }?.tags, ["personal"])
    }

    func testInactiveDuplicateRejectsWholeBulkTagMutation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let library = PhoneLibrary(container: container)
        let valid = try library.createTask(title: "Must stay unchanged", tags: ["work"])
        let blocked = try library.createTask(title: "Has inactive replica", tags: ["home"])
        let writer = ModelContext(container)
        let inactive = TaskItem(id: blocked.id, title: blocked.title, status: .todo)
        inactive.deletedAt = Date()
        writer.insert(inactive)
        try writer.save()

        XCTAssertThrowsError(try library.editSelectedTasks(ids: [valid.id, blocked.id], change: .addTag("new"))) {
            XCTAssertEqual($0 as? PhoneLibrary.Failure, .inactiveReplica)
        }
        let items = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(items.first { $0.id == valid.id }?.tags, ["work"])
        XCTAssertEqual(items.filter { $0.id == blocked.id }.count, 2)
        XCTAssertEqual(items.first { $0.id == blocked.id && $0.deletedAt == nil }?.tags, ["home"])
    }

    func testSaveFailureRollsBackEverySelectedTask() throws {
        enum SaveFailure: Error { case rejected }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = PhoneLibrary(container: container)
        let a = try seed.createTask(title: "A")
        let b = try seed.createTask(title: "B")
        let library = PhoneLibrary(container: container, save: { _ in throw SaveFailure.rejected })
        XCTAssertThrowsError(try library.editSelectedTasks(ids: [a.id, b.id], change: .priority(.low)))
        let reader = ModelContext(container)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.priority == .none })
    }
}
