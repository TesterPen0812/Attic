import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Owner decision 2026-10-23: one deletion/restore for the whole item.
@MainActor
final class OneItemLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var coordinator: WorkspaceOperationCoordinator!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var library: AtticLibrary!
    private let root = UUID(), child = UUID(), note = UUID(), alternate = UUID(), earlier = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        let context = ModelContext(container)
        let document = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Parent"), .text("Writing")], requires: ["taskNote"]))
        for _ in 0..<2 {
            let task = TaskItem(id: root, title: "Parent", status: .done, createdAt: date, completedAt: date, manualOrder: 42)
            task.doneLoggedAt = date
            context.insert(task)
            context.insert(TaskItem(id: child, title: "Child", createdAt: date, parentID: root))
            let old = TaskItem(id: earlier, title: "Earlier", createdAt: date, parentID: root)
            old.deletedAt = date; old.deletionRootID = earlier; old.deletionMembersRaw = earlier.uuidString
            context.insert(old)
            for id in [note, alternate] {
                let row = NoteItem(id: id, title: "Parent", body: "Writing", createdAt: date)
                row.taskID = root
                row.content = document
                context.insert(row)
            }
        }
        try context.save()
        tasks = try TaskStore(container: container, now: { self.date })
        notes = try NoteStore(container: container, now: { self.date })
        library = AtticLibrary(tasks: tasks, notes: notes)
    }

    private func rows() throws -> ([TaskItem], [NoteItem]) {
        let context = ModelContext(container)
        return try (context.fetch(FetchDescriptor<TaskItem>()), context.fetch(FetchDescriptor<NoteItem>()))
    }
    private func group(_ model: any PersistentModel) throws -> UUID? {
        guard let field = try WorkspaceModelFields.read(model)["deletionGroupID"] else { return nil }
        return try JSONDecoder().decode(UUID?.self, from: field)
    }

    func testTaskDeleteFansOutS10AndRestoreReturnsExactPlacement() throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let (t, n) = try rows()
        XCTAssertTrue(n.allSatisfy { $0.deletedAt == date }, "writing and unresolved alternates go together")
        let id = try XCTUnwrap(group(t.first { $0.id == root }!))
        for row in t where row.id != earlier { XCTAssertEqual(try group(row), id) }
        for row in n { XCTAssertEqual(try group(row), id) }
        for row in t where row.id == earlier { XCTAssertNil(try group(row)) }
        XCTAssertEqual(library.recentlyDeleted().count, 2, "one item row plus the earlier child deletion")
        XCTAssertTrue(library.restore(AtticItemRef(.note, alternate)))
        let (restored, writing) = try rows()
        XCTAssertTrue(writing.allSatisfy { $0.deletedAt == nil })
        for row in restored where row.id == root {
            XCTAssertNil(row.deletedAt); XCTAssertEqual(row.status, .done)
            XCTAssertEqual(row.doneLoggedAt, date); XCTAssertEqual(row.manualOrder, 42)
        }
        XCTAssertTrue(restored.filter { $0.id == earlier }.allSatisfy { $0.deletedAt == date })
    }

    func testNoteAliasDeleteTakesTaskAndUndoRestoresAll() throws {
        XCTAssertTrue(library.delete(AtticItemRef(.note, note)))
        XCTAssertTrue(try rows().0.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(library.undo.undo(in: .note(note)))
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
    }

    func testFailedSaveRollsBackWholeItemAndHistory() throws {
        enum Failure: Error { case save }
        tasks = try TaskStore(container: container, now: { self.date }, persist: { _ in throw Failure.save })
        library = AtticLibrary(tasks: tasks, notes: notes)
        XCTAssertFalse(library.deleteListedTasks([root]).isApplied)
        XCTAssertTrue(try rows().0.filter { $0.id != earlier }.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try rows().1.allSatisfy { $0.deletedAt == nil })
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
    }

    func testPurgeRemovesGroupTogetherAndNeverEarlierDelete() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertEqual(Set(try rows().0.map(\.id)), [earlier])
        XCTAssertTrue(try rows().1.isEmpty)
    }

    func testDivergentWritingReplicaKeepsEntirePurgeGroup() async throws {
        XCTAssertTrue(library.deleteListedTasks([root]).isApplied)
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
        row.body = "diverged"; try context.save()
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertNotEqual(result.outcome, .committed)
        XCTAssertEqual(try rows().0.count, 6); XCTAssertEqual(try rows().1.count, 4)
    }
    func testLegacyPurgeConvertsWritingToCheckboxesWithoutTaskMetadata() async throws {
        let context = WorkspaceLegacyBridge.context(for: container)
        try TaskStore.stageSoftDeletion(in: context, taskID: root, preservationID: UUID(), timestamp: date)
        try context.save() // Fixture of a pre-2026-10-23 independent deletion.
        let result = await WorkspacePurge.purge(rootID: root, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles, inventory: { .init(generation: 0) })
        XCTAssertEqual(result.outcome, .committed)
        for row in try rows().1 {
            XCTAssertNil(row.taskID)
            let doc = try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
            XCTAssertFalse(doc.requires.contains("taskNote"))
            XCTAssertEqual(doc.blocks.map(\.text), ["Parent", "Child", "Writing"])
            XCTAssertEqual(doc.blocks[1].kind, .checklist)
        }
    }

}
