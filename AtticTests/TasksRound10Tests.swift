import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 10 (the capability audit, owner-approved): every command's model
/// behaviour. Copy and Duplicate; Done's Delete, Edit Title and metadata
/// without changing completion; managing a subtask in the quick look; one
/// command list for the menu, the keys and VoiceOver; the quick capture
/// shortcut's rules and persistence.
@MainActor
final class TasksRound10Tests: XCTestCase {
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore()
        library = AtticLibrary(tasks: store)
        model = TasksPageModel(library: library, services: TasksPageServices())
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func make(_ title: String, _ status: TaskStatus = .todo, parent: UUID? = nil) throws -> TaskItem {
        try XCTUnwrap(store.create(title: title, status: status, parentID: parent))
    }

    /// Finishes `task` (and its family) and moves it to the Done log, as
    /// the daily cleanup does.
    private func log(_ task: TaskItem) {
        XCTAssertTrue(library.completeTask(task.id).isApplied)
        XCTAssertGreaterThan(store.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 0)
        XCTAssertNil(store.task(withID: task.id))
        XCTAssertNotNil(store.listedTask(withID: task.id), "in the Done log")
    }

    // MARK: - Duplicate

    /// ⌘D: an unfinished copy right below the original, with its own id,
    /// the same title, priority, tags and date, and copies of its subtasks
    /// (their own ids, unfinished, in order); files stay with the original.
    /// One step: Undo removes the copy and its subtasks, Redo brings them.
    func testDuplicateMakesAnUnfinishedCopyBelowTheOriginalAsOneStep() throws {
        let top = try make("Top")
        let original = try make("Plan the trip")
        _ = try make("Bottom")
        let day = DueDay(rawValue: "2026-10-09")!
        XCTAssertTrue(library.updateTask(original.id, priority: .high, status: .inProgress, tags: ["travel"], dueDay: .some(day)).isApplied)
        let first = try make("Book flights", parent: original.id)
        let second = try make("Pack", parent: original.id)
        XCTAssertTrue(library.updateTask(first.id, status: .done).isApplied)
        let file = TaskImageReference(id: UUID(), filename: "map.png", digest: "abc", contentTypeIdentifier: "public.png", byteCount: 3)
        original.imageReferencesData = try JSONEncoder().encode([file])
        XCTAssertEqual(store.task(withID: original.id)?.attachments.count, 1)

        let before = store.revision
        XCTAssertTrue(model.duplicate([original.id]).isApplied)
        XCTAssertNotEqual(store.revision, before)
        let copyID = try XCTUnwrap(model.selection.first, "the copy is selected")
        XCTAssertEqual(model.selection.count, 1)
        let copy = try XCTUnwrap(store.task(withID: copyID))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.title, "Plan the trip")
        XCTAssertEqual(copy.status, .todo, "unfinished: to do, whatever the original's state")
        XCTAssertEqual(copy.priority, .high)
        XCTAssertEqual(copy.tags, ["travel"])
        XCTAssertEqual(copy.dueDay, day, "the date is kept")
        XCTAssertTrue(copy.attachments.isEmpty, "files stay with the original")
        let children = store.subtasks(of: copy.id)
        XCTAssertEqual(children.map(\.title), ["Pack", "Book flights"], "every subtask, in the order the family shows")
        XCTAssertTrue(children.allSatisfy { $0.status == .todo }, "unfinished")
        XCTAssertTrue(Set(children.map(\.id)).isDisjoint(with: [first.id, second.id]), "their own ids")
        XCTAssertEqual(store.subtasks(of: original.id).count, 2, "the original keeps its own")

        // The original was in progress: the copy is at the top of to do.
        let todo = model.rows(for: .now).filter { $0.status == .todo }.map(\.model.title)
        XCTAssertEqual(todo, ["Plan the trip", "Bottom", "Top"])
        _ = top

        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(store.task(withID: copyID), "one Undo takes the copy away")
        XCTAssertTrue(children.allSatisfy { store.task(withID: $0.id) == nil }, "with its subtasks")
        XCTAssertTrue(model.redo().isApplied)
        XCTAssertNotNil(store.task(withID: copyID), "Redo brings it back")
        XCTAssertEqual(store.subtasks(of: copyID).count, 2)
    }

    /// A copy lands right below its original in the same group.
    func testDuplicateSitsRightBelowAToDoOriginal() throws {
        let a = try make("A")
        let b = try make("B")
        let c = try make("C")
        _ = (a, c)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["C", "B", "A"])
        XCTAssertTrue(model.duplicate([b.id]).isApplied)
        XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["C", "B", "B", "A"], "right below B")
    }

    /// Later's copy stays in Later; a Done log task's copy goes to Now as
    /// to do, and the page goes where the copy is.
    func testDuplicateFromLaterAndFromTheDoneLog() throws {
        let later = try make("Someday", .backlog)
        model.select(tab: .backlog)
        XCTAssertTrue(model.duplicate([later.id]).isApplied)
        XCTAssertEqual(model.rows(for: .backlog).map(\.model.title), ["Someday", "Someday"])
        XCTAssertEqual(model.tab, .backlog)

        let finished = try make("Water the plants")
        _ = try make("Balcony", parent: finished.id)
        log(finished)
        model.select(tab: .done)
        XCTAssertTrue(model.duplicate([finished.id]).isApplied)
        XCTAssertEqual(model.tab, .now, "the copy is in Now")
        let copy = try XCTUnwrap(model.selection.first.flatMap { store.task(withID: $0) })
        XCTAssertEqual(copy.title, "Water the plants")
        XCTAssertEqual(copy.status, .todo)
        XCTAssertEqual(store.subtasks(of: copy.id).map(\.title), ["Balcony"], "the logged family's subtasks too")
        XCTAssertEqual(store.listedTask(withID: finished.id)?.status, .done, "the original stays done in the log")
    }

    // MARK: - Copy

    /// ⌘C: the titles, one per line, in list order; plain text.
    func testCopyPutsTheTitlesOnThePasteboard() throws {
        let a = try make("Call mom")
        let b = try make("Email beta testers")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AtticRound10-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copy([b.id, a.id], to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Email beta testers\nCall mom")
        XCTAssertTrue(model.copy([a.id], to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Call mom")
        XCTAssertFalse(model.copy([UUID()], to: pasteboard), "nothing to copy")
        XCTAssertEqual(library.undo.undoStepID(in: .tasks), nil, "copying is not a change")
    }

    // MARK: - Done: delete and edit without changing completion

    /// Delete on a Done log task: it and its family go to Recently Deleted
    /// as one step; Undo puts them back in the log.
    func testDeletingADoneLogTaskAndUndoingIt() throws {
        let task = try make("Renew passport")
        let child = try make("Photos", parent: task.id)
        log(task)
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneDays().flatMap(\.rows).contains { $0.id == task.id })
        XCTAssertTrue(model.delete([task.id]).isApplied)
        XCTAssertNil(store.listedTask(withID: task.id), "gone from the log")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, task.id)), .deleted, "in Recently Deleted")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, child.id)), .deleted, "with its subtask")
        XCTAssertTrue(store.recentlyDeletedTasks().contains { $0.ref.id == task.id })
        XCTAssertFalse(model.doneDays().flatMap(\.rows).contains { $0.id == task.id }, "the page no longer lists it")
        XCTAssertTrue(model.undo().isApplied)
        let back = try XCTUnwrap(store.listedTask(withID: task.id))
        XCTAssertNotNil(back.doneLoggedAt, "back in the Done log, not in Now")
        XCTAssertEqual(back.status, .done)
        XCTAssertNil(store.task(withID: task.id))
    }

    /// Several Done rows deleted together (a selection): one step.
    func testBatchDeleteOnDone() throws {
        let a = try make("Pay rent")
        let b = try make("Send invoice")
        log(a)
        log(b)
        let today = try make("Finished today")
        XCTAssertTrue(library.completeTask(today.id).isApplied)
        model.select(tab: .done)
        XCTAssertTrue(model.delete([a.id, b.id, today.id]).isApplied)
        for id in [a.id, b.id, today.id] { XCTAssertNil(store.listedTask(withID: id)) }
        XCTAssertTrue(model.undo().isApplied)
        for id in [a.id, b.id, today.id] { XCTAssertEqual(store.listedTask(withID: id)?.status, .done, "all back, one Undo") }
    }

    /// Done's Edit Title, Date, Tags and Priority change the task and not
    /// its completion: it stays done, in the log, finished when it was.
    func testDoneEditsNeverChangeCompletion() throws {
        let task = try make("Pay rnet")
        log(task)
        let finishedAt = store.listedTask(withID: task.id)?.completedAt
        let loggedAt = store.listedTask(withID: task.id)?.doneLoggedAt
        model.select(tab: .done)
        model.beginEditingTitle(task.id)
        XCTAssertEqual(model.editingTitleID, task.id, "Return edits a Done log title")
        model.editingTitle = "Pay rent"
        XCTAssertTrue(model.commitTitle())
        let day = DueDay(rawValue: "2026-10-01")!
        XCTAssertTrue(model.setDueDay(day, for: [task.id]).isApplied)
        XCTAssertTrue(model.toggleTag("home", for: [task.id]).isApplied)
        XCTAssertEqual(model.tagState("home", for: [task.id]), .on)
        XCTAssertTrue(model.setPriority(.high, for: [task.id]).isApplied)
        let edited = try XCTUnwrap(store.listedTask(withID: task.id))
        XCTAssertEqual(edited.title, "Pay rent")
        XCTAssertEqual(edited.dueDay, day)
        XCTAssertEqual(edited.tags, ["home"])
        XCTAssertEqual(edited.priority, .high)
        XCTAssertEqual(edited.status, .done, "still done")
        XCTAssertEqual(edited.completedAt, finishedAt, "finished when it was")
        XCTAssertEqual(edited.doneLoggedAt, loggedAt, "still in the log")
        XCTAssertNil(store.task(withID: task.id))
        // Each edit is its own step.
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.listedTask(withID: task.id)?.priority, TaskPriority.none)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.listedTask(withID: task.id)?.tags, [])
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(store.listedTask(withID: task.id)?.dueDay)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.listedTask(withID: task.id)?.title, "Pay rnet")
        XCTAssertEqual(store.listedTask(withID: task.id)?.status, .done)
    }

    // MARK: - Subtasks in the quick look

    func testRenamingASubtaskIsOneStepAndAnEmptyNameChangesNothing() throws {
        let parent = try make("Launch")
        let child = try make("Wirte notes", parent: parent.id)
        model.setExpanded(parent.id, true)
        model.beginRenamingSubtask(child.id)
        XCTAssertEqual(model.renamingSubtaskID, child.id)
        XCTAssertEqual(model.subtaskRename, "Wirte notes")
        model.subtaskRename = "Write notes"
        XCTAssertTrue(model.commitSubtaskRename())
        XCTAssertNil(model.renamingSubtaskID)
        XCTAssertEqual(store.task(withID: child.id)?.title, "Write notes")
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: child.id)?.title, "Wirte notes")
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "   "
        XCTAssertTrue(model.commitSubtaskRename(), "an empty name ends the rename")
        XCTAssertEqual(store.task(withID: child.id)?.title, "Wirte notes", "and changes nothing")
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Something else"
        model.cancelSubtaskRename()
        XCTAssertEqual(store.task(withID: child.id)?.title, "Wirte notes", "Esc discards")
    }

    func testDeletingASubtaskGoesToRecentlyDeletedWithUndo() throws {
        let parent = try make("Launch")
        let child = try make("Tag the build", parent: parent.id)
        let other = try make("Freeze strings", parent: parent.id)
        XCTAssertTrue(model.deleteSubtask(child.id).isApplied)
        XCTAssertNil(store.task(withID: child.id))
        XCTAssertNotNil(store.task(withID: parent.id), "the parent stays")
        XCTAssertNotNil(store.task(withID: other.id))
        XCTAssertEqual(library.state(of: AtticItemRef(.task, child.id)), .deleted)
        XCTAssertEqual(model.toasts.current?.message, "Deleted “Tag the build”")
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: child.id)?.parentID, parent.id, "back in its family")
    }

    /// ⌘↑ ⌘↓ on a subtask: among the subtasks in its state; the open quick
    /// look shows the new order at once; each move is one step.
    func testMovingASubtaskUpAndDown() throws {
        let parent = try make("Launch")
        let a = try make("A", parent: parent.id)
        let b = try make("B", parent: parent.id)
        let c = try make("C", parent: parent.id)
        _ = (a, c)
        model.setExpanded(parent.id, true)
        let titles = { self.model.rows(for: .now).first { $0.id == parent.id }?.subtasks.map(\.title) ?? [] }
        XCTAssertEqual(titles(), ["A", "B", "C"], "subtasks added one by one keep their order")
        XCTAssertTrue(model.moveSubtask(b.id, by: -1).isApplied)
        XCTAssertEqual(titles(), ["B", "A", "C"], "the open quick look shows the move")
        XCTAssertTrue(model.moveSubtask(b.id, by: -1).isApplied, "at the top nothing moves")
        XCTAssertEqual(titles(), ["B", "A", "C"])
        XCTAssertTrue(model.moveSubtask(b.id, by: 2).isApplied)
        XCTAssertEqual(titles(), ["A", "C", "B"])
        XCTAssertTrue(model.undo().isApplied)
        model.releaseQuickLookOrder(of: parent.id)
        XCTAssertEqual(titles(), ["B", "A", "C"], "one Undo per move")
    }

    // MARK: - One command list

    /// The row's menu offers every command with its key, and ⌘C / ⌘D find
    /// their commands in it: the key and the menu can never differ.
    func testTheRowMenuHoldsEveryCommandWithItsKey() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let commands = hosted.page.taskCommands(row.id, tab: .now)
        let titles = AtticMenuCommand.titles(in: commands)
        for title in ["Complete", "Start Working", "Edit Title", "Date", "Tags", "Priority", "Move to Later", "Add Subtask",
                      "Open Files…", "Move Up", "Move Down", "Copy", "Duplicate", "Delete", "Pick a Date…", "All Tags…"] {
            XCTAssertTrue(titles.contains(title), "\(title) in \(titles)")
        }
        func key(_ title: String) -> KeyboardShortcut? {
            func find(_ list: [AtticMenuCommand]) -> AtticMenuCommand? {
                for command in list {
                    if command.title == title { return command }
                    if let found = find(command.children) { return found }
                }
                return nil
            }
            return find(commands)?.shortcut
        }
        XCTAssertEqual(key("Move Up"), AtticTaskShortcut.moveUp)
        XCTAssertEqual(key("Move Down"), AtticTaskShortcut.moveDown)
        XCTAssertEqual(key("Copy"), AtticTaskShortcut.copy)
        XCTAssertEqual(key("Duplicate"), AtticTaskShortcut.duplicate)
        XCTAssertEqual(key("Delete"), AtticTaskShortcut.delete)
        XCTAssertEqual(key("Edit Title"), AtticTaskShortcut.editTitle)
        XCTAssertEqual(AtticMenuCommand.command(for: AtticTaskShortcut.duplicate, in: commands)?.title, "Duplicate")
        XCTAssertEqual(AtticMenuCommand.command(for: AtticTaskShortcut.copy, in: commands)?.title, "Copy")

        // A Done page row: Restore, Edit Title, the metadata, Delete.
        hosted.go(to: .done)
        let done = try XCTUnwrap(hosted.model.doneDays().flatMap(\.rows).first { $0.model.title == "Pay rent" })
        let doneTitles = AtticMenuCommand.titles(in: hosted.page.taskCommands(done.id, tab: .done))
        for title in ["Restore to Now", "Mark as Not Done", "Edit Title", "Date", "Tags", "Priority", "Copy", "Duplicate", "Delete"] {
            XCTAssertTrue(doneTitles.contains(title), "Done offers \(title): \(doneTitles)")
        }
        XCTAssertFalse(doneTitles.contains("Move Up"), "a Done log keeps its order")
    }

    /// ⌘D on a selected row, through the app's queue as a key comes: the
    /// page duplicates it (the key runs the menu's own command).
    func testCommandDOnARowDuplicatesIt() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        hosted.spin(0.2)
        hosted.press("d", keyCode: 2, modifiers: .command)
        let titles = hosted.model.rows(for: .now).map(\.model.title)
        XCTAssertEqual(titles.filter { $0 == "Call the plumber" }.count, 2, "⌘D made a copy: \(titles)")
        XCTAssertNotEqual(hosted.model.selection, [row.id], "the copy is selected")
        hosted.model.undo()
        XCTAssertEqual(hosted.model.rows(for: .now).filter { $0.model.title == "Call the plumber" }.count, 1)
    }

    /// VoiceOver offers the same commands the menu does, named.
    func testVoiceOverActionsIncludeTheNewCommands() {
        var fired: [String] = []
        let actions = AtticTaskActions(
            toggleDone: { fired.append("done") }, toggleWorking: {}, openPage: {}, moveToBacklog: {}, delete: {},
            editTitle: {}, moveUp: { fired.append("up") }, moveDown: { fired.append("down") }, addSubtask: {},
            copy: {}, duplicate: { fired.append("dup") }, changePriority: {}, showActions: { fired.append("menu") }
        )
        let names = actions.accessibilityActions(for: .todo).map(\.name)
        for name in ["Change priority", "Add subtask", "Move up", "Move down", "Copy", "Duplicate", "Show actions", "Delete"] {
            XCTAssertTrue(names.contains(name), "\(name) in \(names)")
        }
        XCTAssertEqual(AtticTaskKeys.command(key: KeyEquivalent("d"), characters: "d", modifiers: .command, listCommands: true), .duplicate)
        XCTAssertEqual(AtticTaskKeys.command(key: KeyEquivalent("c"), characters: "c", modifiers: .command, listCommands: true), .copy)
        XCTAssertEqual(AtticTaskKeys.command(key: KeyEquivalent("I"), characters: "I", modifiers: [.command, .shift], listCommands: true), .showActions)
        AtticTaskKeys.perform(.duplicate, actions)
        AtticTaskKeys.perform(.showActions, actions)
        XCTAssertEqual(fired, ["dup", "menu"])
        let card = AtticTaskActions(toggleDone: {}, openPage: {})
        XCTAssertFalse(AtticTaskKeys.offers(.duplicate, card), "a key for a command not offered goes on")
    }

    /// The same list as an `NSMenu`: submenus, ticks and dashes, headings,
    /// key equivalents and details.
    func testTheNativeMenuShowsWhatTheListSays() throws {
        var ran = false
        var tagged = AtticMenuCommand(verbatim: "#home", state: .mixed) {}
        tagged.detail = nil
        let commands: [AtticMenuCommand] = [
            .header("2 Tasks"),
            AtticMenuCommand(verbatim: "Complete", shortcut: AtticTaskShortcut.complete) { ran = true },
            .submenu("Tags", [tagged, AtticMenuCommand(verbatim: "#work", state: .on) {}]),
            AtticMenuCommand(verbatim: "Move Up", shortcut: AtticTaskShortcut.moveUp, isDisabled: true, startsSection: true) {},
            AtticMenuCommand(verbatim: "Tomorrow", detail: "Tue") {},
            AtticMenuCommand(verbatim: "Actions", shortcut: AtticTaskShortcut.actions) {}
        ]
        let menu = AtticNativeMenu.make(commands)
        XCTAssertTrue(menu.items[0].isSectionHeader)
        XCTAssertEqual(menu.items[0].title, "2 Tasks")
        let complete = menu.items[1]
        XCTAssertEqual(complete.keyEquivalent, " ")
        XCTAssertEqual(complete.keyEquivalentModifierMask, [])
        let tags = menu.items[2]
        XCTAssertEqual(tags.submenu?.items.map(\.state), [.mixed, .on])
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        let up = menu.items[4]
        XCTAssertFalse(up.isEnabled)
        XCTAssertEqual(up.keyEquivalentModifierMask, .command)
        XCTAssertEqual(up.keyEquivalent, String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)))
        XCTAssertEqual(menu.items[5].badge?.stringValue, "Tue")
        XCTAssertEqual(menu.items[6].keyEquivalent, "i")
        XCTAssertEqual(menu.items[6].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(complete.action, #selector(AtticMenuTarget.runCommand(_:)))
        NSApp.sendAction(try XCTUnwrap(complete.action), to: complete.target, from: complete)
        XCTAssertTrue(ran, "an item runs its command")
    }

    /// A subtask's keys come from its command list.
    func testASubtasksKeysFindTheirCommands() {
        let commands: [AtticMenuCommand] = [
            AtticMenuCommand(verbatim: "Rename", shortcut: AtticTaskShortcut.editTitle) {},
            AtticMenuCommand(verbatim: "Move Up", shortcut: AtticTaskShortcut.moveUp) {},
            AtticMenuCommand(verbatim: "Delete", shortcut: AtticTaskShortcut.delete) {}
        ]
        XCTAssertEqual(AtticMenuCommand.command(key: .return, characters: "\r", modifiers: [], in: commands)?.title, "Rename")
        XCTAssertEqual(AtticMenuCommand.command(key: .upArrow, characters: "", modifiers: .command, in: commands)?.title, "Move Up")
        XCTAssertNil(AtticMenuCommand.command(key: .upArrow, characters: "", modifiers: [], in: commands), "a plain ↑ moves focus")
        XCTAssertEqual(AtticMenuCommand.command(key: .delete, characters: "\u{7F}", modifiers: [], in: commands)?.title, "Delete")
    }

    // MARK: - Agent tools

    /// `duplicate_task` duplicates as ⌘D does; `delete_task` reaches the
    /// Done log.
    func testTheAgentToolsDuplicateAndDeleteFromTheDoneLog() throws {
        let tools = AgentTaskTools(store: store, library: library)
        let task = try make("Plan the trip")
        _ = try make("Book flights", parent: task.id)
        let text = try tools.call(name: "duplicate_task", arguments: ["id": task.id.uuidString])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let copy = try XCTUnwrap((payload["task"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:))
        let copyID = try XCTUnwrap(copy)
        XCTAssertNotEqual(copyID, task.id)
        XCTAssertEqual(store.subtasks(of: copyID).map(\.title), ["Book flights"])
        XCTAssertTrue(library.undo(in: .tasks).isApplied, "one undoable step")
        XCTAssertNil(store.task(withID: copyID))

        let finished = try make("Renew passport")
        log(finished)
        _ = try tools.call(name: "delete_task", arguments: ["id": finished.id.uuidString])
        XCTAssertEqual(library.state(of: AtticItemRef(.task, finished.id)), .deleted)
    }

    // MARK: - Quick capture shortcut

    func testARecordedShortcutMustNotTakeATypingKeyOrAMacOSShortcut() {
        func combination(_ key: Int, _ mask: Int) -> GlobalHotKeyCombination {
            GlobalHotKeyCombination(keyCode: UInt32(key), modifiers: UInt32(mask))
        }
        XCTAssertNil(GlobalHotKeyCombination.newTask.recordingProblem, "the default is fine")
        XCTAssertNil(combination(kVK_ANSI_K, controlKey | optionKey).recordingProblem)
        XCTAssertNil(combination(kVK_ANSI_N, cmdKey | shiftKey).recordingProblem)
        XCTAssertNotNil(combination(kVK_ANSI_K, 0).recordingProblem, "no modifier")
        XCTAssertNotNil(combination(kVK_ANSI_K, shiftKey).recordingProblem, "Shift alone types")
        XCTAssertNotNil(combination(kVK_ANSI_C, cmdKey).recordingProblem, "Command alone: every app's commands")
        XCTAssertNotNil(combination(kVK_Space, controlKey).recordingProblem, "macOS's input sources")
        XCTAssertNotNil(combination(999, controlKey).recordingProblem, "a key Attic can't name")
        XCTAssertEqual(combination(kVK_ANSI_K, controlKey | optionKey).displayName, "⌃⌥K")
        XCTAssertEqual(combination(kVK_ANSI_K, controlKey | optionKey).spokenName, "Control Option K")
        XCTAssertEqual(combination(kVK_ANSI_K, controlKey | optionKey).keyboardShortcut,
                       KeyboardShortcut("k", modifiers: [.control, .option]), "the menu advertises the same key")
        XCTAssertEqual(GlobalHotKeyCombination.carbonModifiers([.control, .option, .command]), UInt32(controlKey | optionKey | cmdKey))
    }

    func testTheShortcutAndItsSwitchAreKept() throws {
        let suite = "TasksRound10Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.quickCaptureEnabled, "on by default")
        XCTAssertEqual(settings.quickCaptureShortcut, .newTask, "⌃⌥Space by default")
        let recorded = GlobalHotKeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        settings.quickCaptureShortcut = recorded
        settings.quickCaptureEnabled = false
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.quickCaptureShortcut, recorded)
        XCTAssertFalse(again.quickCaptureEnabled)
        again.quickCaptureShortcut = .newTask
        XCTAssertNil(defaults.object(forKey: "quickCaptureKeyCode"), "Reset stores nothing: the default")
        // A stored value Attic can't claim safely is not used.
        defaults.set(kVK_ANSI_C, forKey: "quickCaptureKeyCode")
        defaults.set(cmdKey, forKey: "quickCaptureModifiers")
        XCTAssertEqual(AppSettings(defaults: defaults).quickCaptureShortcut, .newTask)
    }

    /// Turning the shortcut off releases it; the hot key reports nothing
    /// claimed (and Settings shows no refusal for it).
    func testTurningTheShortcutOffReleasesIt() {
        let hotKey = GlobalHotKey(combination: .newTask)
        let other = GlobalHotKeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(hotKey.apply(other, enabled: false), .notRegistered)
        XCTAssertEqual(hotKey.combination, other, "the new combination is kept for when it is on")
        XCTAssertNil(SettingsVisibility.globalShortcutFailure(hotKey.registration))
    }
}
