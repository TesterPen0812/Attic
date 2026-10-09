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
            notes: trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())),
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
            notes: trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())),
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

    // MARK: - One inventory for every suggestion source

    private func assertInventory(_ library: AtticLibrary, _ expected: [String: Int],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let notes = try XCTUnwrap(library.notes, file: file, line: line)
        let model = TasksPageModel(library: library)
        XCTAssertEqual(notes.tagCounts, expected, "Notes picker and title source", file: file, line: line)
        XCTAssertEqual(library.tags.countsByName, expected, file: file, line: line)
        XCTAssertEqual(Set(model.allTags), Set(expected.keys), "Tasks picker", file: file, line: line)
        XCTAssertEqual(Set(model.cachedTags), Set(expected.keys), "Add-bar suggestions", file: file, line: line)
        XCTAssertEqual(Set(model.composerTagChoices), Set(expected.keys), "Add-bar picker", file: file, line: line)
    }

    func testTaskOnlyAndNoteOnlyTagsAreExistingOnEveryPage() throws {
        let library = try makeLibrary()
        let notes = try XCTUnwrap(library.notes)
        let model = TasksPageModel(library: library)
        XCTAssertTrue(model.cachedTags.isEmpty) // Warm before either page creates a tag.
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        XCTAssertTrue(library.tasks.setTags(["#CU2TaskOnly", "Café"], for: task))
        XCTAssertEqual(notes.tagCounts["cu2taskonly"], 1, "Notes picker recognises an existing task tag")
        let suggestions = AtticTagSuggestion.make(typed: "cu2taskonly", counts: notes.tagCounts, excluding: [])
        XCTAssertEqual(suggestions, [AtticTagSuggestion(name: "cu2taskonly", count: 1, isNew: false)])

        let document = NoteDocument(blocks: [.text("Note")])
        let noteID = UUID()
        guard case let .success((_, revision)) = notes.createDocumentNote(id: noteID, document: document,
                                                                          tags: ["#NoteOnly", "#CU2TaskOnly", "CAFÉ"]) else {
            return XCTFail("Document note creation failed")
        }
        XCTAssertTrue(model.tagChoices(for: [task.id]).contains("noteonly"))
        XCTAssertTrue(model.cachedTags.contains("noteonly"), "the already-warm add bar sees Notes creation")
        guard case let .tags(_, _, matches, create)? = TaskAddBarText(text: "#NOTEONLY")
            .suggestion(parser: model.parser, caret: 9, tags: model.cachedTags) else { return XCTFail() }
        XCTAssertEqual(matches, ["noteonly"])
        XCTAssertNil(create)
        XCTAssertTrue(library.tasks.setTags(["#NOTEONLY", "café", "cu2taskonly"], for: task))
        try assertInventory(library, ["cu2taskonly": 2, "noteonly": 2, "café": 2])
        XCTAssertFalse(model.cachedTags.contains("cafe"), "diacritics remain distinct as before")

        // The tag-only document save is the Notes picker/title's durable path.
        guard case .success = notes.saveDocument(noteID: noteID, document: document, baseRevisionID: revision,
                                                tags: ["title-tag"]) else { return XCTFail() }
        try assertInventory(library, ["cu2taskonly": 1, "noteonly": 1, "café": 1, "title-tag": 1])
    }

    func testRenameMergeRemovalAndUndoUpdateEverySource() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let notes = try XCTUnwrap(library.notes)
        let note = try XCTUnwrap(notes.create(title: "Note"))
        XCTAssertTrue(library.tasks.setTags(["old"], for: task))
        XCTAssertTrue(notes.setTags(["old", "target"], for: note))
        try assertInventory(library, ["old": 2, "target": 1])
        XCTAssertTrue(library.renameTag("old", to: "NEW"))
        try assertInventory(library, ["new": 2, "target": 1])
        XCTAssertTrue(library.mergeTags(["new"], into: "target"))
        try assertInventory(library, ["target": 2])
        XCTAssertTrue(library.deleteTag("target"))
        try assertInventory(library, [:])
        XCTAssertTrue(library.undo.undo(in: .library))
        try assertInventory(library, ["target": 2])
        XCTAssertTrue(library.tasks.setTags([], for: try XCTUnwrap(library.tasks.task(withID: task.id))))
        try assertInventory(library, ["target": 1])
        XCTAssertTrue(notes.setTags([], for: try XCTUnwrap(notes.note(withID: note.id))))
        try assertInventory(library, [:])
    }

    func testDeleteRestoreAndDoneLogKeepSharedCountsCorrect() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let notes = try XCTUnwrap(library.notes)
        let note = try XCTUnwrap(notes.create(title: "Note"))
        XCTAssertTrue(library.tasks.setTags(["shared"], for: task))
        XCTAssertTrue(notes.setTags(["shared"], for: note))
        try assertInventory(library, ["shared": 2])
        XCTAssertTrue(library.tasks.delete(task))
        try assertInventory(library, ["shared": 1])
        XCTAssertTrue(notes.delete(note))
        try assertInventory(library, [:])
        XCTAssertTrue(library.tasks.restoreDeleted(taskID: task.id))
        XCTAssertTrue(notes.restoreDeleted(noteID: note.id))
        try assertInventory(library, ["shared": 2])
        let live = try XCTUnwrap(library.tasks.task(withID: task.id))
        XCTAssertTrue(library.tasks.update(live, status: .done))
        XCTAssertEqual(library.tasks.moveCompletedToDoneLog(before: Date().addingTimeInterval(3 * 86_400)), 1)
        try assertInventory(library, ["shared": 2])
        _ = try XCTUnwrap(library.canvases?.createCanvas(name: "Canvas"))
        let board = try XCTUnwrap(library.canvases?.canvases.first)
        XCTAssertTrue(library.setTags(["shared"], on: AtticItemRef(.canvas, board.id)))
        try assertInventory(library, ["shared": 3])
    }

    func testExternalRefreshOfEitherStoreInvalidatesTheSharedInventory() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let notes = try XCTUnwrap(library.notes)
        let note = try XCTUnwrap(notes.create(title: "Note"))
        try assertInventory(library, [:])
        let external = ModelContext(library.tasks.container)
        for row in try external.fetch(FetchDescriptor<TaskItem>()) where row.id == task.id { row.tags = ["external-task"] }
        try external.save()
        library.tasks.refresh()
        try assertInventory(library, ["external-task": 1])
        for row in try external.fetch(FetchDescriptor<NoteItem>()) where row.id == note.id { row.tags = ["external-note"] }
        try external.save()
        notes.refresh()
        try assertInventory(library, ["external-task": 1, "external-note": 1])
    }

    func testFailedWritesFromEitherStoreAndTagServiceNeverPublishFailedTags() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container, persist: gate.save)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, persist: gate.save,
                                                               attachmentFileStore: makeTestAttachmentFileStore()))
        let library = AtticLibrary(tasks: tasks, notes: notes, persist: gate.save)
        let task = try XCTUnwrap(tasks.create(title: "Task"))
        let note = try XCTUnwrap(notes.create(title: "Note"))
        XCTAssertTrue(tasks.setTags(["task"], for: task))
        XCTAssertTrue(notes.setTags(["note"], for: note))
        try assertInventory(library, ["task": 1, "note": 1])
        gate.shouldFail = true
        XCTAssertFalse(tasks.setTags(["failed-task"], for: task))
        try assertInventory(library, ["task": 1, "note": 1])
        XCTAssertFalse(notes.setTags(["failed-note"], for: note))
        try assertInventory(library, ["task": 1, "note": 1])
        XCTAssertFalse(library.renameTag("task", to: "failed-rename"))
        try assertInventory(library, ["task": 1, "note": 1])
    }

    func testWarmSuggestionsReadNoStoreRowsOrFetchesAndContentSavesStayWarm() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        for index in 0..<1_000 {
            let task = TaskItem(title: "Task \(index)")
            task.tags = ["shared", "task"]
            seed.insert(task)
            let note = NoteItem(title: "Note \(index)")
            note.tags = ["shared", "note"]
            seed.insert(note)
        }
        try seed.save()
        let tasks = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container,
                                                               attachmentFileStore: makeTestAttachmentFileStore()))
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let model = TasksPageModel(library: library)
        let documentID = UUID()
        guard case let .success((_, revision)) = notes.createDocumentNote(id: documentID,
            document: NoteDocument(blocks: [.text("Document")]), tags: ["document"]) else { return XCTFail() }
        XCTAssertEqual(notes.tagCounts["shared"], 2_000)
        let builds = library.tags.inventoryBuildCount
        let fetches = library.tags.inventoryFetchCount
        let reads = library.tags.inventoryRowReadCount
        for _ in 0..<200 {
            XCTAssertNotNil(notes.tagCounts["task"], "Notes picker")
            _ = AtticTagSuggestion.make(typed: "task", counts: notes.tagCounts, excluding: [])
            _ = model.tagChoices(for: [])
            _ = model.composerTagChoices
            _ = TaskAddBarText(text: "#note").suggestion(parser: model.parser, caret: 5, tags: model.cachedTags)
        }
        XCTAssertEqual(library.tags.inventoryBuildCount, builds)
        XCTAssertEqual(library.tags.inventoryFetchCount, fetches)
        XCTAssertEqual(library.tags.inventoryRowReadCount, reads)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.tasks.first), title: "Only task text changed"))
        XCTAssertTrue(notes.update(try XCTUnwrap(notes.notes.first { $0.id != documentID }), body: "Only note text changed"))
        guard case .success = notes.saveDocument(noteID: documentID,
            document: NoteDocument(blocks: [.text("Only document text changed")]), baseRevisionID: revision) else { return XCTFail() }
        XCTAssertEqual(notes.tagCounts["shared"], 2_000)
        XCTAssertEqual(library.tags.inventoryBuildCount, builds)
        XCTAssertEqual(library.tags.inventoryFetchCount, fetches)
        XCTAssertEqual(library.tags.inventoryRowReadCount, reads)
        print("ATTIC_SHARED_TAG_COST rows=2001 requests=200 build_delta=0 fetch_delta=0 row_read_delta=0 content_save_rebuilds=0")
    }

    func testFailedInventoryFetchRetriesOnlyAfterInvalidation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let task = TaskItem(title: "Tagged task")
        task.tags = ["home"]
        context.insert(task)
        try context.save()
        var attempts = 0
        var shouldFail = true
        let service = TagService(container: container, fetchTaggedTasks: { context in
            attempts += 1
            if shouldFail { throw TagServiceError.invalidTag("fetch unavailable") }
            return try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" }))
        })

        XCTAssertTrue(service.names.isEmpty)
        XCTAssertNotNil(service.lastErrorMessage)
        for _ in 0..<20 {
            XCTAssertTrue(service.countsByName.isEmpty)
            XCTAssertTrue(service.counts().isEmpty)
            XCTAssertTrue(service.names.isEmpty)
        }
        XCTAssertEqual(attempts, 1, "failed reads must not fetch again on each keystroke")
        service.invalidateInventory()
        XCTAssertTrue(service.names.isEmpty)
        XCTAssertEqual(attempts, 2, "one retry per explicit refresh, even if it still fails")

        shouldFail = false
        XCTAssertTrue(service.names.isEmpty, "recovery waits for invalidation")
        task.tags = ["work"]
        service.invalidate(in: context)
        try context.save()
        service.publishInventoryChange()
        XCTAssertEqual(service.countsByName, ["work": 1], "a saved tag edit permits recovery")
        XCTAssertEqual(service.names, ["work"])
        XCTAssertEqual(attempts, 3)
        let fetches = service.inventoryFetchCount
        _ = service.counts()
        XCTAssertEqual(service.inventoryFetchCount, fetches, "successful recovery stays cached")
    }

    func testDivergentReplicaWinnerChangeInvalidatesEvenOnContentEdit() throws {
        let library = try makeLibrary()
        let seed = ModelContext(library.tasks.container)
        let id = UUID()
        let old = TaskItem(id: id, title: "Old", updatedAt: Date(timeIntervalSince1970: 1_000))
        old.tags = ["old"]
        let new = TaskItem(id: id, title: "New", updatedAt: Date(timeIntervalSince1970: 2_000))
        new.tags = ["new"]
        seed.insert(old); seed.insert(new); try seed.save()
        library.tasks.refresh()
        try assertInventory(library, ["new": 1])
        old.updatedAt = Date(timeIntervalSince1970: 3_000)
        library.tags.invalidate(in: seed)
        try seed.save(); library.tags.publishInventoryChange()
        try assertInventory(library, ["old": 1])
    }


    func testTagChangesNotifyBothPagesAfterDurableSave() throws {
        let library = try makeLibrary()
        let notes = try XCTUnwrap(library.notes)
        let model = TasksPageModel(library: library)
        let task = try XCTUnwrap(library.tasks.create(title: "Task"))
        let note = try XCTUnwrap(notes.create(title: "Note"))
        _ = notes.tagCounts
        var noteNotifications = 0, taskNotifications = 0
        let noteObservation = notes.objectWillChange.sink { noteNotifications += 1 }
        let taskObservation = model.objectWillChange.sink { taskNotifications += 1 }
        var publishedCounts: [[String: Int]] = []
        let inventoryObservation = library.tags.inventoryChanges.sink { publishedCounts.append(library.tags.countsByName) }
        XCTAssertTrue(library.tasks.setTags(["task"], for: task))
        XCTAssertGreaterThan(noteNotifications, 0)
        XCTAssertGreaterThan(taskNotifications, 0)
        XCTAssertEqual(publishedCounts.last, ["task": 1], "notification follows the durable write")
        let previousNotes = noteNotifications, previousTasks = taskNotifications
        XCTAssertTrue(notes.setTags(["note"], for: note))
        XCTAssertGreaterThan(noteNotifications, previousNotes)
        XCTAssertGreaterThan(taskNotifications, previousTasks)
        XCTAssertEqual(publishedCounts.last, ["task": 1, "note": 1])
        withExtendedLifetime((noteObservation, taskObservation, inventoryObservation)) {}
    }

}
