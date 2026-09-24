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
}
