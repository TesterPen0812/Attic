import SwiftData
import XCTest
@testable import Attic

@MainActor
final class LinkStoreTests: XCTestCase {
    private var library: AtticLibrary!

    override func setUp() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        library = AtticLibrary(
            tasks: TaskStore(container: container),
            notes: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
            canvases: CanvasStore(container: container)
        )
    }

    override func tearDown() async throws {
        library = nil
    }

    private var links: LinkStore { library.links }

    func testLinksAndBacklinksBetweenAnyKinds() throws {
        let task = try XCTUnwrap(library.tasks.create(title: "Email testers"))
        let note = try XCTUnwrap(library.notes?.create(title: "Beta plan"))
        let board = try XCTUnwrap(library.canvases?.createCanvas(name: "Flow"))
        let taskRef = AtticItemRef(.task, task.id)
        let noteRef = AtticItemRef(.note, note.id)
        let boardRef = AtticItemRef(.canvas, board.id)

        let card = try XCTUnwrap(library.link(noteRef, to: taskRef, kind: .card))
        let attachment = try XCTUnwrap(library.link(taskRef, to: boardRef, kind: .attachment))
        XCTAssertEqual(card.source, noteRef)
        XCTAssertEqual(card.kind, .card)

        XCTAssertEqual(links.links(from: noteRef).map(\.id), [card.id])
        XCTAssertEqual(links.backlinks(to: taskRef).map(\.id), [card.id])
        XCTAssertEqual(links.links(from: taskRef).map(\.id), [attachment.id])
        XCTAssertEqual(links.backlinks(to: boardRef).map(\.source), [taskRef])
        XCTAssertTrue(links.backlinks(to: noteRef).isEmpty)
    }

    func testACanvasCanBeAttachedToAnyNumberOfTasksAndANoteCanHoldTwoCardsForOneTask() throws {
        let board = try XCTUnwrap(library.canvases?.createCanvas(name: "Shared"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        let boardRef = AtticItemRef(.canvas, board.id)
        var taskRefs: [AtticItemRef] = []
        for index in 0..<3 {
            let task = try XCTUnwrap(library.tasks.create(title: "Task \(index)"))
            taskRefs.append(AtticItemRef(.task, task.id))
            XCTAssertNotNil(library.link(taskRefs[index], to: boardRef, kind: .attachment))
        }
        XCTAssertEqual(Set(links.backlinks(to: boardRef).map(\.source)), Set(taskRefs))
        XCTAssertNotNil(library.link(AtticItemRef(.note, note.id), to: taskRefs[0], kind: .card))
        XCTAssertNotNil(library.link(AtticItemRef(.note, note.id), to: taskRefs[0], kind: .card))
        XCTAssertEqual(links.links(from: AtticItemRef(.note, note.id)).count, 2)
    }

    func testLinkingRefusesMissingDeletedAndSelfEndpoints() throws {
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let gone = try XCTUnwrap(library.tasks.create(title: "Gone"))
        XCTAssertTrue(library.delete(AtticItemRef(.task, gone.id)))
        let ref = AtticItemRef(.task, task.id)
        XCTAssertNil(library.link(ref, to: ref, kind: .reference))
        XCTAssertNil(library.link(ref, to: AtticItemRef(.note, UUID()), kind: .reference))
        XCTAssertNil(library.link(ref, to: AtticItemRef(.task, gone.id), kind: .reference))
        XCTAssertNotNil(links.lastErrorMessage)
        XCTAssertEqual(try ModelContext(library.tasks.container).fetchCount(FetchDescriptor<ItemLink>()), 0)
    }

    func testDeletingATargetKeepsItsLinksSoARestoreRelinksAndPurgeRemovesThem() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let library = AtticLibrary(tasks: tasks, notes: notes, now: { clock.value })
        let task = try XCTUnwrap(tasks.create(title: "Task"))
        let note = try XCTUnwrap(notes.create(title: "Note"))
        let taskRef = AtticItemRef(.task, task.id)
        let noteRef = AtticItemRef(.note, note.id)
        let card = try XCTUnwrap(library.link(noteRef, to: taskRef, kind: .card))

        XCTAssertTrue(library.delete(taskRef))
        XCTAssertTrue(library.links.links(from: noteRef).isEmpty, "the card turns back into text")
        XCTAssertEqual(library.links.links(from: noteRef, includingUnavailableEndpoints: true).map(\.id), [card.id],
                       "the link, and the target id, are kept")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemLink>()), 1)

        XCTAssertTrue(library.restore(taskRef))
        XCTAssertEqual(library.links.links(from: noteRef).map(\.id), [card.id], "restore relinks")

        XCTAssertTrue(library.delete(taskRef))
        clock.value = clock.value.addingTimeInterval(31 * 24 * 3_600)
        let report = library.purgeExpired(now: clock.value, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(report.taskIDs, [task.id])
        XCTAssertEqual(report.removedLinks, 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemLink>()), 0)
        XCTAssertEqual(library.state(of: taskRef), .missing)
    }

    func testUnlinkIsSoftAppliesToEveryReplicaAndIsPurgedAfterThirtyDays() throws {
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        let link = try XCTUnwrap(library.link(AtticItemRef(.note, note.id), to: AtticItemRef(.task, task.id), kind: .card))
        // A duplicate replica of the same link.
        let context = ModelContext(library.tasks.container)
        context.insert(ItemLink(id: link.id, source: link.source, target: link.target, kind: .card, createdAt: link.createdAt))
        try context.save()
        XCTAssertEqual(links.backlinks(to: AtticItemRef(.task, task.id)).count, 1, "replicas are presented once")

        XCTAssertTrue(library.unlink(link.id, in: .note(note.id)))
        XCTAssertTrue(links.backlinks(to: AtticItemRef(.task, task.id)).isEmpty)
        let rows = try ModelContext(library.tasks.container).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt != nil })

        XCTAssertTrue(library.undo.undo(in: .note(note.id)))
        XCTAssertEqual(links.backlinks(to: AtticItemRef(.task, task.id)).count, 1)
        XCTAssertTrue(library.undo.redo(in: .note(note.id)))
        XCTAssertEqual(links.purgeRemovedLinks(before: Date().addingTimeInterval(-60)), 0, "not yet 30 days")
        XCTAssertEqual(links.purgeRemovedLinks(before: .distantFuture), 1)
        XCTAssertEqual(try ModelContext(library.tasks.container).fetchCount(FetchDescriptor<ItemLink>()), 0)
    }

    func testFailedLinkSaveRecordsNothing() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container)
        let library = AtticLibrary(tasks: tasks, persist: gate.save)
        let first = try XCTUnwrap(tasks.create(title: "One"))
        let second = try XCTUnwrap(tasks.create(title: "Two"))
        gate.shouldFail = true
        XCTAssertNil(library.link(AtticItemRef(.task, first.id), to: AtticItemRef(.task, second.id), kind: .reference))
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemLink>()), 0)
    }
}
