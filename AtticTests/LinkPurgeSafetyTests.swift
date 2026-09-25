import SwiftData
import XCTest
@testable import Attic

/// Link purge matches kind and id and every replica (data review finding 2).
@MainActor
final class LinkPurgeSafetyTests: XCTestCase {
    private let day: TimeInterval = 24 * 3_600


    func testPurgingATaskKeepsTheLinksOfANoteWithTheSameUUID() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes, now: { clock.value })
        let doomed = try XCTUnwrap(tasks.create(title: "Doomed"))
        let other = try XCTUnwrap(tasks.create(title: "Other"))
        let twinNote = try XCTUnwrap(notes.create(id: doomed.id, title: "Same UUID, different kind"))
        XCTAssertEqual(twinNote.id, doomed.id)
        let noteLink = try XCTUnwrap(library.link(AtticItemRef(.note, twinNote.id), to: AtticItemRef(.task, other.id), kind: .card))
        _ = try XCTUnwrap(library.link(AtticItemRef(.task, doomed.id), to: AtticItemRef(.task, other.id), kind: .reference))

        XCTAssertTrue(library.delete(AtticItemRef(.task, doomed.id)))
        clock.value += 31 * day
        let report = library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(report.removedLinks, 1)
        XCTAssertEqual(library.links.links(from: AtticItemRef(.note, twinNote.id)).map(\.id), [noteLink.id])
    }

    func testLinksWhoseReplicasDisagreeAreNeverPurged() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let links = LinkStore(container: container)
        let purgedTask = AtticItemRef(.task, UUID())
        let liveNote = AtticItemRef(.note, UUID())
        let linkID = UUID()
        let context = ModelContext(container)
        context.insert(ItemLink(id: linkID, source: liveNote, target: purgedTask, kind: .card))
        // Another device retargeted the same link to a live item.
        context.insert(ItemLink(id: linkID, source: liveNote, target: AtticItemRef(.task, UUID()), kind: .card))
        let removedID = UUID()
        let removedAt = Date(timeIntervalSince1970: 10)
        context.insert(ItemLink(id: removedID, source: liveNote, target: purgedTask, kind: .card,
                                createdAt: removedAt, deletedAt: removedAt))
        context.insert(ItemLink(id: removedID, source: liveNote, target: AtticItemRef(.canvas, UUID()), kind: .card,
                                createdAt: removedAt, deletedAt: removedAt))
        try context.save()

        XCTAssertEqual(links.purgeLinks(touching: [purgedTask]), 0)
        XCTAssertEqual(links.purgeRemovedLinks(before: .distantFuture), 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemLink>()), 4)
    }

    // MARK: - Failed link cleanup is retried (final review finding 8)

    /// Saves normally, except that while `failsLinkRemoval` is set any save
    /// that would remove a link fails: the item purge may already have
    /// removed its rows by then.
    @MainActor
    private final class LinkRemovalFailure {
        struct Failure: Error {}
        var failsLinkRemoval = false
        private(set) var refusedSaves = 0

        func save(_ context: ModelContext) throws {
            if failsLinkRemoval, context.deletedModelsArray.contains(where: { $0 is ItemLink }) {
                refusedSaves += 1
                throw Failure()
            }
            try context.save()
        }
    }

    func testLinksOfAPurgedItemAreRemovedByTheNextCleanupWhenTheirRemovalFailed() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 100_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = LinkRemovalFailure()
        let tasks = TaskStore(container: container, now: { clock.value }, persist: gate.save)
        let notes = NoteStore(container: container, now: { clock.value }, persist: gate.save,
                              attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes, now: { clock.value }, persist: gate.save)
        let doomed = try XCTUnwrap(tasks.create(title: "Doomed"))
        let other = try XCTUnwrap(tasks.create(title: "Other"))
        let note = try XCTUnwrap(notes.create(title: "Note"))
        let doomedNote = try XCTUnwrap(notes.create(title: "Doomed note"))
        XCTAssertNotNil(library.link(AtticItemRef(.task, doomed.id), to: AtticItemRef(.task, other.id), kind: .reference))
        XCTAssertNotNil(library.link(AtticItemRef(.note, note.id), to: AtticItemRef(.task, doomed.id), kind: .card))
        XCTAssertNotNil(library.link(AtticItemRef(.note, doomedNote.id), to: AtticItemRef(.task, other.id), kind: .card))
        let kept = try XCTUnwrap(library.link(AtticItemRef(.note, note.id), to: AtticItemRef(.task, other.id), kind: .card))
        XCTAssertTrue(library.delete(AtticItemRef(.task, doomed.id)))
        XCTAssertTrue(library.delete(AtticItemRef(.note, doomedNote.id)))
        clock.value += 31 * day

        gate.failsLinkRemoval = true
        let failed = library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian))
        XCTAssertGreaterThan(gate.refusedSaves, 0)
        XCTAssertEqual(failed.removedLinks, 0)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemLink>()), 4, "no link was removed")
        // Items and links go together: a failed link removal keeps the items
        // too, so the next cleanup still knows which links to remove.
        XCTAssertTrue(failed.taskIDs.isEmpty)
        XCTAssertTrue(failed.noteIDs.isEmpty)
        let doomedID = doomed.id
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == doomedID })), 1)
        XCTAssertEqual(library.state(of: AtticItemRef(.task, doomed.id)), .deleted)

        gate.failsLinkRemoval = false
        let retried = library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(retried.taskIDs, [doomed.id])
        XCTAssertEqual(retried.noteIDs, [doomedNote.id])
        XCTAssertEqual(retried.removedLinks, 3)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ItemLink>()).map(\.id), [kept.id],
                       "only the link between live items is left")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, doomed.id)), .missing)
    }
}
