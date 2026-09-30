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
}
