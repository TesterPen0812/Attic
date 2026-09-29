import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 12: one presentation identity for a (tab, task): geometry, focus,
/// editors and menu targets belong to the page that draws the row, never to
/// the task's id alone (Now's kept "Completed today" copy and the Done copy
/// of one task are two rows). Plus the computer-use review's bugs.
@MainActor
final class TasksRound12Tests: XCTestCase {
    // MARK: - P2-1: a failed subtask rename leaves no failure behind

    private func renameFixture() throws -> (gate: PersistenceGate, model: TasksPageModel, library: AtticLibrary, parent: TaskItem, child: TaskItem) {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let library = AtticLibrary(tasks: store, persist: gate.save)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        let parent = try XCTUnwrap(store.create(title: "Plan the trip"))
        let child = try XCTUnwrap(store.create(title: "Book flights", parentID: parent.id))
        model.setExpanded(parent.id, true)
        return (gate, model, library, parent, child)
    }

    /// A rename that failed to save, then put back to the original text (or
    /// emptied) and confirmed: the editor closes, nothing stays unsaved, no
    /// extra Undo step was made, and hiding and revealing is normal.
    private func assertFailureClears(_ replacement: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (gate, model, library, parent, child) = try renameFixture()
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Book flights to Lisbon"
        gate.shouldFail = true
        XCTAssertFalse(model.commitSubtaskRename(), file: file, line: line)
        XCTAssertTrue(model.subtaskRenameFailed, file: file, line: line)
        XCTAssertTrue(model.hasUnsavedEdit, file: file, line: line)
        gate.shouldFail = false
        let step = library.undo.undoStepID(in: .tasks)

        model.subtaskRename = replacement
        XCTAssertTrue(model.commitSubtaskRename(), file: file, line: line)
        XCTAssertNil(model.renamingSubtaskID, "the editor closes", file: file, line: line)
        XCTAssertFalse(model.subtaskRenameFailed, "no failure is left behind", file: file, line: line)
        XCTAssertFalse(model.hasUnsavedEdit, file: file, line: line)
        XCTAssertEqual(library.undo.undoStepID(in: .tasks), step, "no extra Undo step", file: file, line: line)
        XCTAssertEqual(library.tasks.task(withID: child.id)?.title, "Book flights", file: file, line: line)

        // Hide and reveal are normal: nothing is held, the quick look is a
        // plain reveal (an unsaved edit would keep the page as it was).
        model.pageDidHide()
        model.resetForReveal()
        XCTAssertNil(model.renamingSubtaskID, file: file, line: line)
        XCTAssertFalse(model.hasUnsavedEdit, file: file, line: line)
        model.toggleExpanded(parent.id)
        XCTAssertFalse(model.expanded.contains(parent.id), "collapsing is not blocked", file: file, line: line)
    }

    func testAFailedRenameClearsWhenPutBackToTheOriginalText() throws {
        try assertFailureClears("Book flights")
    }

    func testAFailedRenameClearsWhenEmptied() throws {
        try assertFailureClears("   ")
    }

    func testAFailedRenameClearsWhenItsTaskIsGone() throws {
        let (gate, model, library, _, child) = try renameFixture()
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Book flights to Lisbon"
        gate.shouldFail = true
        XCTAssertFalse(model.commitSubtaskRename())
        gate.shouldFail = false
        XCTAssertTrue(library.deleteTasks([child.id]).isApplied)
        model.subtaskRename = "Something else"
        XCTAssertTrue(model.commitSubtaskRename())
        XCTAssertNil(model.renamingSubtaskID)
        XCTAssertFalse(model.subtaskRenameFailed)
        XCTAssertFalse(model.hasUnsavedEdit)
    }
}
