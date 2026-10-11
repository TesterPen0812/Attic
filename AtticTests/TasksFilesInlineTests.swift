import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// A1 (owner decision B): a task's files open inline under its row, apart
/// from its subtasks, and the old floating "Open files" window is gone.
@MainActor
final class TasksFilesInlineTests: XCTestCase {
    private func reference(_ name: String, bytes: Int64 = 2_048) -> TaskImageReference {
        TaskImageReference(id: UUID(), filename: name, digest: UUID().uuidString,
                           contentTypeIdentifier: "com.adobe.pdf", byteCount: bytes)
    }

    /// A page model over a store with one task that has two subtasks and
    /// three stored files (references only: no file is read here).
    private func makeModel() throws -> (model: TasksPageModel, store: TaskStore, task: TaskItem, files: [TaskImageReference]) {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let task = try XCTUnwrap(store.create(title: "Finalize launch checklist"))
        _ = try XCTUnwrap(store.create(title: "Write release notes", parentID: task.id))
        _ = try XCTUnwrap(store.create(title: "Final screenshots", parentID: task.id))
        let files = [reference("Launch brief.pdf"), reference("Hero shot.pdf"), reference("Release notes.pdf")]
        let context = ModelContext(store.container)
        let id = task.id
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        stored.imageReferencesData = try TaskStore.encodedAttachments(files)
        try context.save()
        store.refresh()
        return (model, store, task, files)
    }

    func testTheFilesCountOpensOnlyTheFilesAndTheSubtasksCountOnlyTheSubtasks() throws {
        let (model, _, task, files) = try makeModel()
        model.select(tab: .now)
        func row() throws -> TasksListRow { try XCTUnwrap(model.rows(for: .now).first { $0.id == task.id }) }

        XCTAssertEqual(try row().model.attachments, 3, "the row's count is there while the list is shut")
        XCTAssertTrue(try row().files.isEmpty)
        XCTAssertTrue(try row().subtasks.isEmpty)

        model.toggleFiles(task.id)
        XCTAssertEqual(try row().files, files, "the files count opens the files")
        XCTAssertTrue(try row().subtasks.isEmpty, "and only the files")
        XCTAssertFalse(model.expanded.contains(task.id))

        model.toggleExpanded(task.id)
        XCTAssertEqual(try row().subtasks.count, 2, "the subtasks count opens the subtasks")
        XCTAssertEqual(try row().files, files, "without closing the files")

        model.toggleFiles(task.id)
        XCTAssertTrue(try row().files.isEmpty, "each closes on its own")
        XCTAssertEqual(try row().subtasks.count, 2)
    }

    func testTheCommandReturnCommandTogglesTheFilesList() throws {
        let (model, _, task, _) = try makeModel()
        model.openPage(task.id)
        XCTAssertEqual(model.expandedFiles, [task.id])
        model.openPage(task.id)
        XCTAssertTrue(model.expandedFiles.isEmpty)
    }

    func testRemovingAFileIsOneUndoableStepAndItWaitsInRecentlyDeleted() throws {
        let (model, store, task, files) = try makeModel()
        model.toggleFiles(task.id)

        XCTAssertTrue(model.removeFile(files[1], from: task.id).isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.attachments.map(\.filename), ["Launch brief.pdf", "Release notes.pdf"])
        XCTAssertEqual(store.recentlyDeletedAttachments().map(\.filename), ["Hero shot.pdf"], "nothing is deleted for good")
        XCTAssertEqual(model.rows(for: .now).first { $0.id == task.id }?.files.count, 2, "the open list shows it gone")
        XCTAssertNotNil(model.toasts.current, "the toast offers Undo")

        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(Set(try XCTUnwrap(store.task(withID: task.id)).attachments.map(\.filename)),
                       ["Launch brief.pdf", "Hero shot.pdf", "Release notes.pdf"], "Undo puts the file back")
        XCTAssertTrue(store.recentlyDeletedAttachments().isEmpty)

        XCTAssertTrue(model.redo().isApplied)
        XCTAssertEqual(store.task(withID: task.id)?.attachments.count, 2, "and Redo removes it again")
    }

    func testRemovingAFileThatIsGoneReportsInsteadOfPretending() throws {
        let (model, store, task, files) = try makeModel()
        XCTAssertTrue(store.removeAttachment(files[0].id, from: task.id))
        XCTAssertFalse(model.removeFile(files[0], from: task.id).isApplied)
    }

    func testDeletingATaskForgetsItsOpenFilesList() throws {
        let (model, _, task, _) = try makeModel()
        model.toggleFiles(task.id)
        _ = model.delete([task.id])
        XCTAssertTrue(model.expandedFiles.isEmpty)
    }

    // MARK: - On the page

    func testVisibleInlineFilesHoldThePanelAndClosingOrChangingTabReleasesIt() throws {
        var held = false
        let hosted = try Hosted(height: 560, keyWindow: false, chrome: TasksPageChrome(editLock: { held = $0 }))
        defer { hosted.close() }
        let task = try XCTUnwrap(hosted.model.rows(for: .now).first)
        XCTAssertFalse(held)
        hosted.model.toggleFiles(task.id)
        hosted.spin(0.3)
        XCTAssertTrue(held, "explicit files stay open after menu tracking ends")
        hosted.model.select(tab: .backlog)
        hosted.spin(0.3)
        XCTAssertFalse(held, "another tab's invisible files hold nothing")
        hosted.model.select(tab: .now)
        hosted.spin(0.3)
        XCTAssertTrue(held, "returning to the visible inline files restores their hold")
        hosted.model.toggleFiles(task.id)
        hosted.spin(0.3)
        XCTAssertFalse(held, "closing the list releases the hold")
    }

    func testOpeningTheFilesGrowsTheRowByItsListAndLeavesTheSubtasksShut() throws {
        let hosted = try Hosted(height: 560)
        defer { hosted.close() }
        let task = try XCTUnwrap(hosted.model.rows(for: .now).first)
        // Three stored files (references only).
        let context = ModelContext(hosted.store.container)
        let id = task.id
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        stored.imageReferencesData = try TaskStore.encodedAttachments([reference("a.pdf"), reference("b.pdf"), reference("c.pdf")])
        try context.save()
        hosted.store.refresh()
        hosted.spin(0.5)
        let key = TasksRowID(tab: .now, id: id)
        let shut = try XCTUnwrap(hosted.pointer.frames[key]).height

        hosted.model.toggleFiles(id)
        hosted.spin(0.8)
        let open = try XCTUnwrap(hosted.pointer.frames[key]).height
        // Three files and "Attach file…", on the subtask pitch.
        XCTAssertEqual(open - shut, 4 * AtticLayout.subtaskPitch + AtticQuickLookMetrics.bottomPadding, accuracy: 2,
                       "the row measures its files list")
        XCTAssertFalse(hosted.model.expanded.contains(id), "the subtasks stay shut")

        hosted.model.toggleFiles(id)
        hosted.spin(0.8)
        XCTAssertEqual(try XCTUnwrap(hosted.pointer.frames[key]).height, shut, accuracy: 2, "and it closes again")
    }
}
