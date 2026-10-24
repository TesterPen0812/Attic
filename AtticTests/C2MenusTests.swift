import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// C2 (part 1): the one-item commands in the new menus, and All notes rows.
///
/// Names and casing: One item: owner answers (2026-10-23), answer 3 (Add to
/// Tasks, Remove from Tasks, Delete; Make Checkbox mirrors Make Subtask;
/// Open Page stays). Places: Dropdown content: answers (owner, 2026-10-24),
/// sheets 1, 2 and 5. Subtasks and bare tasks have no Add to / Remove from
/// Tasks, hidden rather than disabled (the build rules' orchestrator
/// decisions). All notes: one row per item with the live task title, tags
/// and circle and no "Task note" wording (plan, "All notes rows"); clearing
/// all the writing takes the item out of All notes (owner answer 2).
@MainActor
final class C2MenusTests: XCTestCase {

    // MARK: Task row menu

    private func taskHost(removable: Bool) throws -> (Hosted, opened: Box<[UUID]>, removed: Box<[UUID]>, files: Box<[UUID]>) {
        let hosted = try Hosted(height: 520, keyWindow: false)
        let opened = Box<[UUID]>([]), removed = Box<[UUID]>([]), files = Box<[UUID]>([])
        hosted.model.services.openTaskNote = { opened.value.append($0) }
        hosted.model.services.chooseFilesForNote = { files.value.append($0) }
        hosted.model.services.removeFromTasks = { removed.value.append($0) }
        hosted.model.services.canRemoveFromTasks = { _ in removable }
        return (hosted, opened, removed, files)
    }

    func testTaskMenuPutsOpenPageFirstInItsGroupAndRemoveFromTasksBeforeDelete() throws {
        let (hosted, opened, removed, _) = try taskHost(removable: true)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let commands = hosted.page.taskCommands(row.id, tab: .now)
        let layout = AtticGlassMenuCard.layout(commands)
        XCTAssertEqual(TasksFollowup2Tests.kinds(layout),
                       ["Complete", "Start Working", "—", "Open Page", "Edit Title", "Add Subtask", "—",
                        "Date", "Tags", "Priority", "—", "Move to Later", "More", "—", "Remove from Tasks", "Delete"])
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons(commands), [], "an icon on every row")
        let open = try XCTUnwrap(commands.first { $0.title == "Open Page" })
        XCTAssertEqual(open.shortcut, AtticTaskShortcut.openPage, "⌘Return still opens the page")
        let remove = try XCTUnwrap(commands.first { $0.title == "Remove from Tasks" })
        XCTAssertFalse(remove.isDestructive, "only Delete is red")
        XCTAssertTrue(try XCTUnwrap(commands.last).isDestructive)
        XCTAssertEqual(commands.last?.shortcut, AtticTaskShortcut.delete)
        open.action()
        hosted.spin(0.2)
        XCTAssertEqual(opened.value, [row.id])
        remove.action()
        XCTAssertEqual(removed.value, [row.id])
    }

    /// More ›: Show Files and Add Files… (the plan's menu word) │ Copy,
    /// Duplicate │ Move Up, Move Down. Add Files… keeps its picker.
    func testTaskMenuMoreKeepsAddFilesBesideShowFiles() throws {
        let (hosted, _, _, files) = try taskHost(removable: true)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let more = try XCTUnwrap(hosted.page.taskCommands(row.id, tab: .now).first { $0.title == "More" })
        XCTAssertEqual(TasksFollowup2Tests.kinds(AtticGlassMenuCard.layout(more.children)),
                       ["Show Files", "Add Files…", "—", "Copy", "Duplicate", "—", "Move Up", "Move Down"])
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons(more.children), [])
        try XCTUnwrap(more.children.first { $0.title == "Add Files…" }).action()
        XCTAssertEqual(files.value, [row.id])
    }

    /// A bare task (no writing) has no Remove from Tasks: hidden, not dimmed.
    func testBareTaskHidesRemoveFromTasks() throws {
        let (hosted, _, _, _) = try taskHost(removable: false)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let titles = AtticMenuCommand.titles(in: hosted.page.taskCommands(row.id, tab: .now))
        XCTAssertFalse(titles.contains("Remove from Tasks"), "\(titles)")
        XCTAssertFalse(titles.contains("Add to Tasks"), "\(titles)")
        XCTAssertTrue(titles.contains("Open Page"), "\(titles)")
    }

    /// A selection has no Open Page or Remove from Tasks (one item each).
    func testSelectionMenuHasNoOneItemCommands() throws {
        let (hosted, _, _, _) = try taskHost(removable: true)
        defer { hosted.close() }
        let rows = hosted.model.rows(for: .now)
        XCTAssertGreaterThan(rows.count, 1)
        hosted.model.selectOnly(rows[0].id)
        hosted.model.extendSelection(to: rows[1].id, visible: rows.map(\.id))
        let titles = AtticMenuCommand.titles(in: hosted.page.taskCommands(rows[0].id, tab: .now))
        XCTAssertFalse(titles.contains("Open Page"), "\(titles)")
        XCTAssertFalse(titles.contains("Remove from Tasks"), "\(titles)")
    }

    /// VoiceOver's named action says the menu's word.
    func testOpenPageVoiceOverActionUsesTheMenuWord() throws {
        let (hosted, _, _, _) = try taskHost(removable: true)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first)
        XCTAssertEqual(hosted.page.actions(for: row.id, in: .now).names.openPage, "Open page")
    }

    // MARK: Subtask menu

    func testSubtaskMenuOffersMakeCheckboxAfterMakeStandaloneTask() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let made = Box<[UUID]>([])
        hosted.model.services.makeCheckbox = { made.value.append($0) }
        hosted.model.services.canRemoveFromTasks = { _ in true }
        hosted.model.services.removeFromTasks = { _ in }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        hosted.model.setExpanded(row.id, true)
        let open = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == row.id })
        let subtask = try XCTUnwrap(open.subtasks.first { $0.title == "Merge" })
        let commands = hosted.page.subtaskCommands(subtask, of: row.id, in: open.subtasks)
        XCTAssertEqual(TasksFollowup2Tests.kinds(AtticGlassMenuCard.layout(commands)),
                       ["Complete", "Edit Title", "—", "Move Up", "Move Down", "—",
                        "Move to Task…", "Make Standalone Task", "Make Checkbox", "—", "Delete"])
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons(commands), [])
        let make = try XCTUnwrap(commands.first { $0.title == "Make Checkbox" })
        XCTAssertNil(make.shortcut, "⌥⌘S stays Make Subtask's")
        make.action()
        XCTAssertEqual(made.value, [subtask.id])
    }

    /// Without the host's service (previews, Phase 1 hosts) the row is
    /// hidden, never dimmed.
    func testSubtaskMenuHidesMakeCheckboxWithoutTheService() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        hosted.model.setExpanded(row.id, true)
        let open = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == row.id })
        let subtask = try XCTUnwrap(open.subtasks.first)
        let titles = AtticMenuCommand.titles(in: hosted.page.subtaskCommands(subtask, of: row.id, in: open.subtasks))
        XCTAssertFalse(titles.contains("Make Checkbox"))
        XCTAssertFalse(titles.contains("Add to Tasks"))
        XCTAssertFalse(titles.contains("Remove from Tasks"))
    }

    // MARK: Preview

    /// "Attic One Item" opens on Attic Task Life's samples; the official
    /// identity never gets demo content.
    func testTheOneItemPreviewIsSeededLikeTaskLife() {
        XCTAssertTrue(TaskNoteLifecyclePreviewSeed.seeds(bundleIdentifier: "com.taha.Attic.preview.oneitem"))
        XCTAssertTrue(TaskNoteLifecyclePreviewSeed.seeds(bundleIdentifier: "com.taha.Attic.preview.tasklife"))
        XCTAssertFalse(TaskNoteLifecyclePreviewSeed.seeds(bundleIdentifier: "com.taha.Attic"))
        XCTAssertTrue(AtticDemoData.isAllowed(bundleIdentifier: "com.taha.Attic.preview.oneitem"))
    }

    // MARK: Keyboard: dimmed commands say why and keep their keys

    /// One-item plan, "Menus and keyboard": a disabled command explains why
    /// and consumes its shortcut (nothing runs, nothing else gets the key).
    func testDimmedMoveUpSaysWhyAndStillOwnsItsKey() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let first = try XCTUnwrap(hosted.model.rows(for: .now).first)
        hosted.model.selectOnly(first.id)
        let commands = hosted.page.taskCommands(first.id, tab: .now)
        let more = try XCTUnwrap(commands.first { $0.title == "More" })
        let up = try XCTUnwrap(more.children.first { $0.title == "Move Up" })
        XCTAssertTrue(up.isDisabled)
        XCTAssertEqual(up.disabledReason, "Already at the top")
        XCTAssertNil(AtticMenuCommand.command(for: AtticTaskShortcut.moveUp, in: commands), "it can't run")
        XCTAssertEqual(AtticMenuCommand.keyOwner(for: AtticTaskShortcut.moveUp, in: commands)?.title, "Move Up",
                       "but the key is still Move Up's")

        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        hosted.model.setExpanded(row.id, true)
        let open = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == row.id })
        let subtask = try XCTUnwrap(open.subtasks.first)
        let subUp = try XCTUnwrap(hosted.page.subtaskCommands(subtask, of: row.id, in: open.subtasks).first { $0.title == "Move Up" })
        XCTAssertEqual(subUp.disabledReason, "Already at the top")
    }

    // MARK: Note menus and All notes

    private var container: ModelContainer!
    private var notes: NotesPageController!
    private var tasks: TaskStore!

    override func tearDown() async throws {
        notes = nil; tasks = nil; container = nil
    }

    private func makeStores() throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        tasks = TaskStore(container: container)
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
    }

    /// One task with `notes` own notes (S10 when two), each with `body`.
    @discardableResult
    private func seedTask(_ title: String, tags: [String] = [], status: TaskStatus = .todo,
                          bodies: [[NoteBlock]], noteTags: [String] = []) throws -> (task: UUID, notes: [UUID]) {
        let context = ModelContext(container)
        let now = Date()
        let task = TaskItem(title: title, status: status, createdAt: now.addingTimeInterval(-86_400), manualOrder: 1_024)
        task.tags = tags
        context.insert(task)
        var ids: [UUID] = []
        for (index, body) in bodies.enumerated() {
            let created = now.addingTimeInterval(Double(index - bodies.count) * 600)
            let row = NoteItem(id: UUID(), createdAt: created, updatedAt: created)
            row.taskID = task.id
            row.tags = noteTags
            let document = try NoteDocument(blocks: [.text(title)] + body).taskSnapshot(title: title)
            NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [row], timestamp: created,
                                           revision: 0, revisionID: UUID())
            context.insert(row)
            context.insert(TaskNoteAssociation(taskID: task.id, noteID: row.id))
            ids.append(row.id)
        }
        try context.save()
        notes.store.refresh()
        tasks.refresh()
        return (task.id, ids)
    }

    private func seedOrdinaryNote(_ title: String, body: [NoteBlock]) throws -> UUID {
        let context = ModelContext(container)
        let row = NoteItem(id: UUID(), createdAt: Date(), updatedAt: Date())
        let document = NoteDocument(blocks: [.text(title)] + body)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [row], timestamp: Date(),
                                       revision: 0, revisionID: UUID())
        context.insert(row)
        try context.save()
        notes.store.refresh()
        return row.id
    }

    private func rowCommands(_ id: UUID, opened: Box<[UUID]>? = nil, deleted: Box<[UUID]>? = nil) -> [AtticMenuCommand] {
        NotesEditorPage.libraryRowCommands(id, noteStore: notes.store, controller: notes, taskStore: tasks,
                                           activeTag: nil, hue: { _ in nil }, filter: { _ in },
                                           open: { opened?.value.append($0) }, delete: { deleted?.value.append($0) })
    }

    func testNoteRowMenuOffersAddToTasksAfterOpenPageAndSaysDelete() throws {
        try makeStores()
        let added = Box<[UUID]>([])
        notes.makeTaskFromNote = { added.value.append($0) }
        notes.removeFromTasks = { _ in XCTFail("an ordinary note has no circle to remove") }
        let id = try seedOrdinaryNote("Groceries", body: [.text("Milk and eggs")])
        let deleted = Box<[UUID]>([])
        let commands = rowCommands(id, deleted: deleted)
        XCTAssertEqual(TasksFollowup2Tests.kinds(AtticGlassMenuCard.layout(commands)),
                       ["Open Page", "Add to Tasks", "—", "Pin to Top", "Filter by Tag", "—",
                        "Copy as Markdown", "Duplicate", "—", "Delete"])
        XCTAssertEqual(AtticMenuSymbols.rowsWithoutIcons(commands), [])
        let delete = try XCTUnwrap(commands.last)
        XCTAssertEqual(delete.identifier, "notes-row-delete", "⌘⌫ still finds it")
        XCTAssertEqual(delete.shortcut, KeyboardShortcut(.delete, modifiers: .command))
        XCTAssertTrue(delete.isDestructive)
        delete.action()
        XCTAssertEqual(deleted.value, [id])
        XCTAssertEqual(try XCTUnwrap(commands.first { $0.title == "Add to Tasks" }).identifier, "one-item-add-to-tasks")
    }

    func testNoteRowMenuOffersRemoveFromTasksForAnItemWithACircle() throws {
        try makeStores()
        let removed = Box<[UUID]>([])
        notes.removeFromTasks = { removed.value.append($0) }
        notes.makeTaskFromNote = { _ in XCTFail("an item in Tasks has no Add to Tasks") }
        let seeded = try seedTask("Plan the offsite", bodies: [[.text("Book the boathouse.")]])
        let commands = rowCommands(seeded.notes[0])
        let titles = commands.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["Open Page", "Remove from Tasks"], "\(titles)")
        XCTAssertFalse(titles.contains("Add to Tasks"))
        try XCTUnwrap(commands.first { $0.title == "Remove from Tasks" }).action()
        XCTAssertEqual(removed.value, [seeded.task])
    }

    /// A row for a note that isn't saved yet: its dimmed rows say why, and
    /// the one-item rows are hidden.
    func testNoteRowDimmedCommandsSayWhy() throws {
        try makeStores()
        notes.makeTaskFromNote = { _ in }
        let commands = rowCommands(UUID())
        for title in ["Pin to Top", "Duplicate", "Delete"] {
            let command = try XCTUnwrap(commands.first { $0.title == title }, title)
            XCTAssertTrue(command.isDisabled, title)
            XCTAssertEqual(command.disabledReason, "Not saved yet", title)
        }
        XCTAssertEqual(commands.first { $0.title == "Filter by Tag" }?.disabledReason, "No tags")
        XCTAssertFalse(commands.contains { $0.title == "Add to Tasks" })
        XCTAssertTrue(NotesLibraryView.run("notes-row-delete", in: commands), "⌘⌫ is swallowed, not passed on")
    }

    /// The ⋯ menu's one-item row comes from the same producer as the row's.
    func testNoteMenuConversionComesFromTheSharedProducer() throws {
        try makeStores()
        notes.makeTaskFromNote = { _ in }
        let id = try seedOrdinaryNote("Ideas", body: [.text("A line")])
        XCTAssertEqual(NotesEditorPage.oneItemCommands(noteID: id, noteStore: notes.store, controller: notes, taskStore: tasks,
                                                       add: {}).map(\.title), ["Add to Tasks"])
        XCTAssertEqual(NotesEditorPage.deleteTitle, "Delete")
    }

    private func libraryRows() -> [AtticNoteRowModel] {
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, controller: notes, taskStore: tasks)
        return model.groups(store: notes.store, drafts: []).flatMap(\.rows)
    }

    func testAllNotesRowUsesTheLiveTaskTitleTagsAndCircleWithoutTaskNoteWording() throws {
        try makeStores()
        let seeded = try seedTask("Write the launch post", tags: ["launch"], status: .inProgress,
                                  bodies: [[.text("Draft 3: tasks and notes together.")]], noteTags: ["old"])
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, controller: notes, taskStore: tasks)
        let rows = model.groups(store: notes.store, drafts: []).flatMap(\.rows)
        let row = try XCTUnwrap(rows.first { $0.id == seeded.notes[0] })
        XCTAssertEqual(row.title, "Write the launch post")
        XCTAssertEqual(row.taskState, .inProgress)
        XCTAssertFalse(row.preview.localizedCaseInsensitiveContains("task note"), row.preview)
        XCTAssertFalse(row.spoken.localizedCaseInsensitiveContains("task note"), row.spoken)
        XCTAssertTrue(row.preview.hasPrefix("Draft 3"), row.preview)
        model.tagFilter = "launch"
        XCTAssertEqual(model.groups(store: notes.store, drafts: []).flatMap(\.rows).map(\.id), [seeded.notes[0]],
                       "the item's tags filter All notes")
        model.tagFilter = "old"
        XCTAssertTrue(model.groups(store: notes.store, drafts: []).flatMap(\.rows).isEmpty,
                      "a note-only tag is not the item's while it is in Tasks")
    }

    /// S10: two live notes claim one task: one row, the note made first.
    func testAllNotesShowsOneRowPerItem() throws {
        try makeStores()
        let seeded = try seedTask("Venue shortlist", bodies: [[.text("The boathouse.")], [.text("The library hall.")]])
        let rows = libraryRows().filter { seeded.notes.contains($0.id) }
        XCTAssertEqual(rows.map(\.id), [seeded.notes[0]], "the earliest note is the item's row")
    }

    /// Clearing all the writing takes the item out of All notes; it stays
    /// in Tasks (owner answer 2). An ordinary note is unaffected.
    func testAnItemWithNoWritingLeavesAllNotes() throws {
        try makeStores()
        let empty = try seedTask("Call the bank", bodies: [[]])
        let written = try seedTask("Pack for the trip", bodies: [[.text("Passport")]])
        let ordinary = try seedOrdinaryNote("Loose thought", body: [])
        let ids = Set(libraryRows().map(\.id))
        XCTAssertFalse(ids.contains(empty.notes[0]), "no writing: not in All notes")
        XCTAssertTrue(ids.contains(written.notes[0]))
        XCTAssertTrue(ids.contains(ordinary), "ordinary notes keep their rows")
        XCTAssertNotNil(tasks.listedTask(withID: empty.task), "it stays in Tasks")
    }
}

/// A reference cell for closures in tests.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
