import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 13: who owns the keyboard. A subtask focused by Tab, a task menu
/// popped up as a real NSMenu, the composer's undo history: each is driven
/// with real key events through the app's queue, real Tab focus changes and
/// a real menu, never by calling the handlers.
@MainActor
final class TasksRound13Tests: XCTestCase {
    // MARK: - Bug 3: a Tab-focused subtask owns ⌘↑ ⌘↓ and Return

    /// The demo task with subtasks, expanded, and a Tab pressed until a
    /// subtask line has the keyboard.
    private func tabToASubtask(_ hosted: Hosted) throws -> (parent: UUID, subtask: UUID) {
        let model = hosted.model
        let ship = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        model.setExpanded(ship.id, true)
        hosted.spin(1)
        var tabs = 0
        while model.focusedSubtaskID == nil, tabs < 14 {
            hosted.press("\t", keyCode: 48)
            tabs += 1
        }
        return (ship.id, try XCTUnwrap(model.focusedSubtaskID, "Tab reached a subtask line"))
    }

    private func subtasks(_ hosted: Hosted, of parent: UUID) -> [String] {
        (hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks ?? []).map(\.title)
    }

    func testCommandDownReordersATabFocusedSubtaskNotItsParent() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (parent, subtask) = try tabToASubtask(hosted)
        let rowsBefore = hosted.model.rows(for: .now).map(\.model.title)
        let before = subtasks(hosted, of: parent)
        let title = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks.first { $0.id == subtask }?.title)
        XCTAssertEqual(before.first, title, "the first Tab stop in the quick look is its first subtask")
        hosted.press("\u{F701}", keyCode: 125, modifiers: .command)
        let after = subtasks(hosted, of: parent)
        XCTAssertNotEqual(after, before, "the subtask moved down")
        XCTAssertEqual(after.firstIndex(of: title), 1)
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.model.title), rowsBefore, "the parent did not move")
        hosted.press("\u{F700}", keyCode: 126, modifiers: .command)
        XCTAssertEqual(subtasks(hosted, of: parent), before, "⌘↑ moves it back")
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.model.title), rowsBefore)
    }

    func testReturnRenamesATabFocusedSubtaskNotItsParent() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (_, subtask) = try tabToASubtask(hosted)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.renamingSubtaskID, subtask, "Return renames the subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and not the parent's title")
    }

    func testDeleteStillDeletesATabFocusedSubtask() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (parent, subtask) = try tabToASubtask(hosted)
        let before = subtasks(hosted, of: parent).count
        hosted.press("\u{7F}", keyCode: 51)
        XCTAssertEqual(subtasks(hosted, of: parent).count, before - 1)
        XCTAssertFalse(hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks.contains { $0.id == subtask } ?? true)
    }

    // MARK: - Bug 2: Return in an open task menu activates the highlighted item

    /// Posts real key presses to the app while a menu tracks: each fires from
    /// a timer in the common modes (menu tracking is not the default mode),
    /// with an Esc at the end so a menu that ignores them cannot hang the run.
    private func schedule(_ keys: [(characters: String, keyCode: UInt16)], in hosted: Hosted, from start: TimeInterval = 0.8,
                          step: TimeInterval = 0.25) {
        func post(_ characters: String, _ keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
            }
        }
        var when = start
        for key in keys {
            let timer = Timer(timeInterval: when, repeats: false) { _ in MainActor.assumeIsolated { post(key.characters, key.keyCode) } }
            RunLoop.main.add(timer, forMode: .common)
            when += step
        }
        let escape = Timer(timeInterval: when + 2.5, repeats: false) { _ in MainActor.assumeIsolated { post("\u{1B}", 53) } }
        RunLoop.main.add(escape, forMode: .common)
    }

    /// The row selected and focused, ⇧⌘I pressed for real (a native menu
    /// pops up), `keys` typed into the menu, and the run spun until it closed.
    private func openActionsMenu(_ hosted: Hosted, on title: String, keys: [(characters: String, keyCode: UInt16)]) throws -> UUID {
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
        try hosted.clickRow(row, tab: .now)
        XCTAssertEqual(model.selection, [row])
        schedule(keys, in: hosted)
        hosted.press("i", keyCode: 34, modifiers: [.command, .shift])
        hosted.spin(1.5)
        return row
    }

    func testReturnInTheActionsMenuActivatesTheHighlightedItemNotEditTitle() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try openActionsMenu(hosted, on: "Ship appearance PR", keys: [("\u{F701}", 125), ("\u{F701}", 125), ("\r", 36)])
        // Complete, then Start Working: the second item is highlighted.
        XCTAssertNil(hosted.model.editingTitleID, "Return did not start Edit Title")
        XCTAssertEqual(hosted.store.task(withID: row)?.status, .inProgress, "Return started work on the highlighted Start Working")
    }

    func testReturnOnAddSubtaskInTheActionsMenuOpensTheSubtaskEditor() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let row = try openActionsMenu(hosted, on: "Call the plumber", keys: Array(repeating: down, count: 8) + [("\r", 36)])
        XCTAssertEqual(hosted.model.newSubtaskParentID, row, "Return ran Add Subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and did not edit the parent's title")
    }

    /// A pop-up menu shows a bare key's shortcut (Return beside Edit Title)
    /// but never answers it as a key equivalent; ⌘ shortcuts still work.
    func testPopUpMenusShowBareShortcutsButAnswerOnlyModifiedOnes() {
        var ran: [String] = []
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Edit Title", shortcut: AtticTaskShortcut.editTitle) { ran.append("edit") },
            AtticMenuCommand(verbatim: "Later", shortcut: AtticTaskShortcut.later) { ran.append("later") }
        ])
        XCTAssertEqual(menu.items.first?.keyEquivalent, "\r", "the hint is shown")
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
        XCTAssertFalse(menu.performKeyEquivalent(with: key("\r", 36, [])))
        XCTAssertEqual(ran, [], "Return does not run Edit Title")
        XCTAssertTrue(menu.performKeyEquivalent(with: key("b", 11, .command)))
        XCTAssertEqual(ran, ["later"], "⌘B still runs Later")
    }
}
