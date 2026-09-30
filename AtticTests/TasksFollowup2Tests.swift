import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 follow-up part 2 (the owner's decisions of 2026-09-30): Low
/// priority returns with its grey ↓ and ⌥⌘0–3, the rarer task-menu
/// commands sit under More, and a Done task's details show what it still
/// carries. The model's rules are tested directly; the keys and menus on a
/// hosted page (`Hosted`).
@MainActor
final class TasksFollowup2Tests: XCTestCase {
    // MARK: - Low priority (option A)

    func testEveryPickerOffersAllFourPrioritiesWithTheirKeys() {
        XCTAssertEqual(TaskPriority.choices, [.none, .low, .medium, .high])
        XCTAssertEqual(TaskPriority.choices.map(\.shortcut), AtticTaskShortcut.priorities)
        XCTAssertEqual(AtticTaskShortcut.priorityNone, KeyboardShortcut("0", modifiers: [.command, .option]))
        XCTAssertEqual(AtticTaskShortcut.priorityHigh, KeyboardShortcut("3", modifiers: [.command, .option]))
        XCTAssertEqual(TaskPriority.low.pickerTitle, "↓  Low")
        XCTAssertEqual(TaskPriority.low.mark, "↓")
        XCTAssertEqual(TasksComposerValues.priority(.low)?.text, "↓", "the strip shows Low's mark")
    }

    /// ⌥⌘1 is ⌥⌘1 by its key, whatever ⌥ makes the digit type, and never
    /// without both modifiers.
    func testPriorityKeysMatchTheNumberRow() {
        let low = AtticTaskShortcut.priorityLow
        XCTAssertTrue(AtticTaskShortcut.matches(low, characters: "1", keyCode: 18, modifiers: [.command, .option]))
        XCTAssertTrue(AtticTaskShortcut.matches(low, characters: "¡", keyCode: 18, modifiers: [.command, .option]),
                      "a layout whose ⌥ changes the digit")
        XCTAssertFalse(AtticTaskShortcut.matches(low, characters: "1", keyCode: 18, modifiers: .command), "⌘1 is the shell's")
        XCTAssertFalse(AtticTaskShortcut.matches(low, characters: "2", keyCode: 19, modifiers: [.command, .option]))
    }

    /// The add bar still reads `!` and `!!`; nothing typed means Low.
    func testTheShorthandStillParsesMediumAndHighAndHasNoLow() {
        let parser = TaskTextParser(calendar: .autoupdatingCurrent, locale: Locale(identifier: "en_GB"), now: Date.init)
        XCTAssertEqual(parser.parse("Call the bank !").priority, .medium)
        XCTAssertEqual(parser.parse("Call the bank !!").priority, .high)
        XCTAssertNil(parser.parse("Call the bank ↓").priority)
        XCTAssertNil(parser.parse("Call the bank low").priority)
        XCTAssertNil(TaskPriority.low.shorthand)
    }

    /// ⌥⌘1 on the selected row sets Low (one step, with its toast), ⌥⌘0
    /// takes the priority away; the row menu shows the keys.
    func testPriorityKeysSetTheSelectedTasksPriority() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        hosted.spin(0.2)
        // Each key through the app's queue; the queue is pumped until the
        // change lands (a posted key can wait behind others in a test host).
        func press(_ digit: String, _ code: UInt16, expecting priority: TaskPriority) {
            hosted.press(digit, keyCode: code, modifiers: [.command, .option])
            let deadline = Date().addingTimeInterval(2)
            while hosted.store.task(withID: row.id)?.priority != priority, Date() < deadline {
                Hosted.pumpEvents()
                hosted.spin(0.05)
            }
            XCTAssertEqual(hosted.store.task(withID: row.id)?.priority, priority, "⌥⌘\(digit)")
        }
        press("1", 18, expecting: .low)
        press("3", 20, expecting: .high)
        press("0", 29, expecting: .none)

        let priority = try XCTUnwrap(hosted.page.taskCommands(row.id, tab: .now).first { $0.title == "Priority" })
        XCTAssertEqual(priority.children.map(\.title), TaskPriority.choices.map(\.menuTitle))
        XCTAssertEqual(priority.children.compactMap(\.menuShortcut), AtticTaskShortcut.priorities, "active menu keys")
    }

    // MARK: - L5: the rarer commands under More

    /// The top level keeps the common actions; Open Files…, Move Up and
    /// Move Down sit under More with their keys, and the keys still find
    /// them in the one list.
    func testTheRarerCommandsSitUnderMoreWithTheirKeys() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" })
        hosted.model.selectOnly(row.id)
        let commands = hosted.page.taskCommands(row.id, tab: .now)
        let top = commands.map(\.title)
        XCTAssertEqual(top, ["Complete", "Start Working", "Edit Title", "Date", "Tags", "Priority", "Move to Later",
                             "Add Subtask", "Copy", "Duplicate", "More", "Delete"])
        let more = try XCTUnwrap(commands.first { $0.title == "More" })
        XCTAssertEqual(more.children.map(\.title), ["Open Files…", "Move Up", "Move Down"])
        XCTAssertEqual(more.children.map(\.shortcut), [AtticTaskShortcut.openPage, AtticTaskShortcut.moveUp, AtticTaskShortcut.moveDown])
        // Call the plumber is the last to do: Move Down is off, Move Up runs.
        XCTAssertEqual(more.children.map(\.isDisabled), [false, false, true])
        XCTAssertEqual(AtticMenuCommand.command(for: AtticTaskShortcut.moveUp, in: commands)?.title, "Move Up")
        XCTAssertEqual(AtticMenuCommand.command(key: .upArrow, characters: "", modifiers: .command, in: commands)?.title, "Move Up")
        // The native menu keeps the sections inside More.
        let menu = AtticNativeMenu.make(commands)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu)
        XCTAssertEqual(submenu.items.map { $0.isSeparatorItem ? "—" : $0.title }, ["Open Files…", "—", "Move Up", "Move Down"])
    }

    // MARK: - L6: a Done task's details show its metadata

    func testDoneMetadataReadsDatePriorityAndTags() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let task = try XCTUnwrap(store.create(title: "Pay rent", priority: .high))
        XCTAssertNil(model.doneMetadata(for: try XCTUnwrap(store.create(title: "Plain"))), "nothing to show")
        let day = try XCTUnwrap(DueDay(rawValue: "2031-03-04"))
        XCTAssertTrue(model.library.updateTask(task.id, tags: ["home", "bills"], dueDay: .some(day)).isApplied)
        let metadata = try XCTUnwrap(model.doneMetadata(for: try XCTUnwrap(store.task(withID: task.id))))
        XCTAssertTrue(metadata.hasPrefix("Due "), metadata)
        XCTAssertTrue(metadata.contains("!! High"), metadata)
        XCTAssertTrue(metadata.contains("#home") && metadata.contains("#bills"), metadata)
    }

    /// ⌘Return (or Show Details) on a Done row finished today opens its
    /// details in place, as a Done log task's do; a date changed there
    /// shows in them.
    func testADoneTodayRowShowsItsDetailsWithTheEditedDate() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .done)
        let row = try XCTUnwrap(hosted.model.doneDays().flatMap(\.rows).first { $0.model.title == "Renew domain" })
        XCTAssertNotNil(hosted.store.task(withID: row.id), "still in Now's done group")
        let day = try XCTUnwrap(DueDay(rawValue: "2031-03-04"))
        XCTAssertTrue(hosted.model.setDueDay(day, for: [row.id]).isApplied)
        hosted.page.actions(for: row.id, in: .done).openPage()
        XCTAssertEqual(hosted.model.doneDetailID, row.id, "its details open")
        let detail = try XCTUnwrap(hosted.model.doneDetail(for: row.id))
        XCTAssertEqual(detail.metadata?.hasPrefix("Due "), true, "the edited date shows: \(String(describing: detail.metadata))")
        let titles = AtticMenuCommand.titles(in: hosted.page.taskCommands(row.id, tab: .done))
        XCTAssertTrue(titles.contains("Close Details"), "\(titles)")
        hosted.page.actions(for: row.id, in: .done).openPage()
        XCTAssertNil(hosted.model.doneDetailID, "⌘Return again closes them")
    }
}
