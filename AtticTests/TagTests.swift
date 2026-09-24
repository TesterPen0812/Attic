import SwiftData
import XCTest
@testable import Attic

@MainActor
final class TagTests: XCTestCase {
    // MARK: - Normalisation

    func testNormalisationKeepsLowercaseLettersNumbersAndHyphens() {
        XCTAssertEqual(AtticTag.normalize("#Home"), "home")
        XCTAssertEqual(AtticTag.normalize("  Big Idea  "), "big-idea")
        XCTAssertEqual(AtticTag.normalize("q3_planning"), "q3-planning")
        XCTAssertEqual(AtticTag.normalize("a--b__c  d"), "a-b-c-d")
        XCTAssertEqual(AtticTag.normalize("-edge-"), "edge")
        XCTAssertEqual(AtticTag.normalize("Café"), "café")
        XCTAssertEqual(AtticTag.normalize("R&D!"), "rd")
        XCTAssertEqual(AtticTag.normalize("2026"), "2026")
        XCTAssertNil(AtticTag.normalize("#"))
        XCTAssertNil(AtticTag.normalize("  -- "))
        XCTAssertNil(AtticTag.normalize("!!!"))
        XCTAssertEqual(AtticTag.normalize(String(repeating: "a", count: 100))?.count, AtticTag.maximumLength)
    }

    func testStoredFormIsSortedUniqueAndRoundTrips() {
        let encoded = AtticTag.encode(["Work", "home", "#work", "big idea", "?"])
        XCTAssertEqual(encoded, "big-idea home work")
        XCTAssertEqual(AtticTag.decode(encoded), ["big-idea", "home", "work"])
        XCTAssertEqual(AtticTag.decode(""), [])
    }

    // MARK: - Items

    private func makeLibrary() throws -> AtticLibrary {
        let container = try PersistenceController.makeContainer(inMemory: true)
        return AtticLibrary(
            tasks: TaskStore(container: container),
            notes: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
            canvases: CanvasStore(container: container)
        )
    }

    func testTagsAreStoredOnTasksNotesAndCanvasesOnEveryReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let id = UUID()
        seed.insert(TaskItem(id: id, title: "Copy A"))
        seed.insert(TaskItem(id: id, title: "Copy B", updatedAt: Date().addingTimeInterval(1)))
        try seed.save()
        let library = AtticLibrary(
            tasks: TaskStore(container: container),
            notes: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
            canvases: CanvasStore(container: container)
        )
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        let board = try XCTUnwrap(library.canvases?.createCanvas(name: "Board"))

        XCTAssertTrue(library.setTags(["Work", "#home"], on: AtticItemRef(.task, id)))
        XCTAssertTrue(library.setTags(["work"], on: AtticItemRef(.note, note.id)))
        XCTAssertTrue(library.setTags(["sketch"], on: AtticItemRef(.canvas, board.id)))

        let rows = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.tags == ["home", "work"] })
        XCTAssertEqual(library.notes?.note(withID: note.id)?.tags, ["work"])
        XCTAssertEqual(library.canvases?.canvases.first { $0.id == board.id }?.tags, ["sketch"])
        XCTAssertEqual(library.tags.counts(), [
            TagCount(name: "work", count: 2), TagCount(name: "home", count: 1), TagCount(name: "sketch", count: 1)
        ])
        XCTAssertEqual(library.tags.items(taggedWith: "#Work"), [AtticItemRef(.task, id), AtticItemRef(.note, note.id)])
    }

    func testSettingANoteTagDoesNotMoveTheNote() throws {
        let library = try makeLibrary()
        let notes = try XCTUnwrap(library.notes)
        let older = try XCTUnwrap(notes.create(title: "Older"))
        _ = try XCTUnwrap(notes.create(title: "Newer"))
        let before = notes.orderedNotes().map(\.id)
        XCTAssertTrue(library.setTags(["x"], on: AtticItemRef(.note, older.id)))
        XCTAssertEqual(notes.orderedNotes().map(\.id), before)
    }

    func testRenameMergeAndDeleteApplyEverywhereIncludingDeletedItems() throws {
        let library = try makeLibrary()
        let tasks = library.tasks
        let live = try XCTUnwrap(tasks.create(title: "Live"))
        let deleted = try XCTUnwrap(tasks.create(title: "Deleted"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        XCTAssertTrue(library.setTags(["todo-later", "home"], on: AtticItemRef(.task, live.id)))
        XCTAssertTrue(library.setTags(["todolater"], on: AtticItemRef(.task, deleted.id)))
        XCTAssertTrue(library.setTags(["later"], on: AtticItemRef(.note, note.id)))
        XCTAssertTrue(library.delete(AtticItemRef(.task, deleted.id)))
        XCTAssertFalse(library.tags.counts().contains { $0.name == "todolater" }, "deleted items are not counted")

        XCTAssertTrue(library.mergeTags(["todo-later", "todolater"], into: "later"))
        XCTAssertEqual(tasks.task(withID: live.id)?.tags, ["home", "later"])
        XCTAssertEqual(library.tags.counts().first { $0.name == "later" }?.count, 2)
        XCTAssertTrue(library.restore(AtticItemRef(.task, deleted.id)))
        XCTAssertEqual(tasks.task(withID: deleted.id)?.tags, ["later"], "a restored item comes back with current names")

        XCTAssertTrue(library.renameTag("Later", to: "Someday"))
        XCTAssertEqual(Set(library.tags.counts().map(\.name)), ["home", "someday"])
        XCTAssertEqual(library.notes?.note(withID: note.id)?.tags, ["someday"])

        XCTAssertTrue(library.deleteTag("someday"))
        XCTAssertEqual(library.tags.counts(), [TagCount(name: "home", count: 1)])
        XCTAssertNotNil(tasks.task(withID: deleted.id), "deleting a tag never deletes an item")
    }

    func testEachTagOperationIsOneUndoStep() throws {
        let library = try makeLibrary()
        let first = try XCTUnwrap(library.tasks.create(title: "One"))
        let second = try XCTUnwrap(library.tasks.create(title: "Two"))
        let note = try XCTUnwrap(library.notes?.create(title: "Note"))
        for ref in [AtticItemRef(.task, first.id), AtticItemRef(.task, second.id), AtticItemRef(.note, note.id)] {
            XCTAssertTrue(library.setTags(["old"], on: ref, in: .library))
        }
        let steps = library.undo.undoCount(in: .library)

        XCTAssertTrue(library.renameTag("old", to: "new"))
        XCTAssertEqual(library.undo.undoCount(in: .library), steps + 1)
        XCTAssertEqual(library.tags.counts(), [TagCount(name: "new", count: 3)])
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(library.tags.counts(), [TagCount(name: "old", count: 3)])
        XCTAssertEqual(library.tasks.task(withID: first.id)?.tags, ["old"])
        XCTAssertTrue(library.undo.redo(in: .library))
        XCTAssertEqual(library.tags.counts(), [TagCount(name: "new", count: 3)])
    }

    func testInvalidOrNoOpTagOperationsChangeNothing() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        XCTAssertTrue(library.setTags(["keep"], on: AtticItemRef(.task, task.id)))
        let steps = library.undo.undoCount(in: .library)
        XCTAssertFalse(library.renameTag("keep", to: "!!!"))
        XCTAssertTrue(library.renameTag("absent", to: "other"), "renaming an unused tag is a harmless no-op")
        XCTAssertTrue(library.renameTag("keep", to: "Keep"), "renaming onto itself changes nothing")
        XCTAssertEqual(library.undo.undoCount(in: .library), steps)
        XCTAssertEqual(library.tasks.task(withID: task.id)?.tags, ["keep"])
    }

    func testFailedTagSaveLeavesTagsAndHistoryUntouched() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container)
        let library = AtticLibrary(tasks: tasks, persist: gate.save)
        let task = try XCTUnwrap(tasks.create(title: "Task"))
        XCTAssertTrue(tasks.setTags(["a"], for: task))
        gate.shouldFail = true
        XCTAssertFalse(library.renameTag("a", to: "b"))
        XCTAssertFalse(library.undo.canUndo(in: .library))
        XCTAssertEqual(TaskStore(container: container).task(withID: task.id)?.tags, ["a"])
    }
}
