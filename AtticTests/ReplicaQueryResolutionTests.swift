import SwiftData
import XCTest
@testable import Attic

/// Final review finding 6: queries resolve every replica of an identity
/// first and only then apply their visibility, tag or Done-log filter, so an
/// older copy never answers for a newer one.
@MainActor
final class ReplicaQueryResolutionTests: XCTestCase {
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)

    // MARK: - Links

    func testANewerRemovedLinkReplicaHidesAnOlderLiveOne() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let links = LinkStore(container: container)
        let note = AtticItemRef(.note, UUID())
        let task = AtticItemRef(.task, UUID())
        let linkID = UUID()
        let context = ModelContext(container)
        let live = ItemLink(id: linkID, source: note, target: task, kind: .card, createdAt: older)
        live.updatedAt = older
        let removed = ItemLink(id: linkID, source: note, target: task, kind: .card, createdAt: older, deletedAt: newer)
        removed.updatedAt = newer
        context.insert(live)
        context.insert(removed)
        try context.save()

        XCTAssertTrue(links.links(from: note).isEmpty, "the newer removal wins")
        XCTAssertTrue(links.backlinks(to: task).isEmpty)
        XCTAssertTrue(links.links(from: note, includingUnavailableEndpoints: true).isEmpty)

        // Restored later on the other copy: the newer live replica wins.
        live.deletedAt = nil
        live.updatedAt = Date(timeIntervalSince1970: 3_000)
        try context.save()
        XCTAssertEqual(links.links(from: note).map(\.id), [linkID])
        XCTAssertEqual(links.backlinks(to: task).map(\.id), [linkID])
    }

    func testALinkWhoseNewerReplicaWasRetargetedIsNotABacklinkOfTheOldTarget() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let links = LinkStore(container: container)
        let note = AtticItemRef(.note, UUID())
        let oldTarget = AtticItemRef(.task, UUID())
        let newTarget = AtticItemRef(.task, UUID())
        let linkID = UUID()
        let context = ModelContext(container)
        let stale = ItemLink(id: linkID, source: note, target: oldTarget, kind: .card, createdAt: older)
        stale.updatedAt = older
        let current = ItemLink(id: linkID, source: note, target: newTarget, kind: .card, createdAt: older)
        current.updatedAt = newer
        context.insert(stale)
        context.insert(current)
        try context.save()

        XCTAssertTrue(links.backlinks(to: oldTarget).isEmpty)
        XCTAssertEqual(links.backlinks(to: newTarget).map(\.id), [linkID])
        XCTAssertEqual(links.links(from: note).map(\.target), [newTarget])
    }

    // MARK: - Tag counts

    func testTagCountsReadTheNewestReplicaEvenWhenItHasNoTags() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tags = TagService(container: container)
        let context = ModelContext(container)
        let taskID = UUID()
        let taggedTask = TaskItem(id: taskID, title: "Task", createdAt: older, updatedAt: older)
        taggedTask.tagsRaw = AtticTag.encode(["old"])
        context.insert(taggedTask)
        context.insert(TaskItem(id: taskID, title: "Task", createdAt: older, updatedAt: newer))

        let noteID = UUID()
        let taggedNote = NoteItem(id: noteID, title: "Note", createdAt: older, updatedAt: older)
        taggedNote.tagsRaw = AtticTag.encode(["old"])
        context.insert(taggedNote)
        context.insert(NoteItem(id: noteID, title: "Note", createdAt: older, updatedAt: newer))

        // A newer deleted copy carries tags; the older copy is live.
        let deletedID = UUID()
        let deletedCopy = TaskItem(id: deletedID, title: "Deleted", createdAt: older, updatedAt: newer)
        deletedCopy.tagsRaw = AtticTag.encode(["gone"])
        deletedCopy.deletedAt = newer
        context.insert(deletedCopy)
        context.insert(TaskItem(id: deletedID, title: "Deleted", createdAt: older, updatedAt: older))

        let liveID = UUID()
        let live = TaskItem(id: liveID, title: "Live", createdAt: older, updatedAt: newer)
        live.tagsRaw = AtticTag.encode(["kept"])
        context.insert(live)
        try context.save()

        XCTAssertEqual(tags.counts(), [TagCount(name: "kept", count: 1)])
        XCTAssertTrue(tags.items(taggedWith: "old").isEmpty)
        XCTAssertTrue(tags.items(taggedWith: "gone").isEmpty)
        XCTAssertEqual(tags.items(taggedWith: "kept"), [AtticItemRef(.task, liveID)])
    }

    func testCanvasTagCountsReadTheWinningBoardReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tags = TagService(container: container)
        let context = ModelContext(container)
        let boardID = UUID()
        let tagged = CanvasBoardItem(id: boardID, name: "Board", sortIndex: 0, mutationVersion: 1,
                                     createdAt: older, updatedAt: older)
        tagged.tagsRaw = AtticTag.encode(["old"])
        context.insert(tagged)
        context.insert(CanvasBoardItem(id: boardID, name: "Board", sortIndex: 0, mutationVersion: 2,
                                       createdAt: older, updatedAt: newer))
        try context.save()
        XCTAssertEqual(tags.counts(), [])
    }

    // MARK: - Done log

    func testTheDoneLogReadsTheNewestReplicaOfEachTask() throws {
        let store = try makeTestStore()
        let context = ModelContext(store.container)
        // Brought back to the list on a newer copy: not in the Done log.
        let returnedID = UUID()
        let loggedCopy = TaskItem(id: returnedID, title: "Returned", status: .done, createdAt: older,
                                  updatedAt: older, completedAt: older)
        loggedCopy.doneLoggedAt = older
        context.insert(loggedCopy)
        context.insert(TaskItem(id: returnedID, title: "Returned", status: .todo, createdAt: older, updatedAt: newer))
        // Deleted on a newer copy: in Recently Deleted, not the Done log.
        let deletedID = UUID()
        let logged = TaskItem(id: deletedID, title: "Deleted", status: .done, createdAt: older,
                              updatedAt: older, completedAt: older)
        logged.doneLoggedAt = older
        context.insert(logged)
        let deleted = TaskItem(id: deletedID, title: "Deleted", status: .done, createdAt: older,
                               updatedAt: newer, completedAt: older)
        deleted.doneLoggedAt = older
        deleted.deletedAt = newer
        deleted.deletionRootID = deletedID
        deleted.deletionMembersRaw = deletedID.uuidString
        context.insert(deleted)
        // Logged on its newest copy: in the Done log once.
        let keptID = UUID()
        let kept = TaskItem(id: keptID, title: "Kept", status: .done, createdAt: older,
                            updatedAt: newer, completedAt: older)
        kept.doneLoggedAt = newer
        context.insert(kept)
        context.insert(TaskItem(id: keptID, title: "Kept", status: .todo, createdAt: older, updatedAt: older))
        try context.save()
        store.refresh()

        XCTAssertEqual(store.doneLog().map(\.id), [keptID])
        XCTAssertEqual(store.tasks.map(\.id), [returnedID])
    }
}
