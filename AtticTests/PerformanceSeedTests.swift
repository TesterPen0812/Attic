import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class PerformanceSeedTests: XCTestCase {
    #if ATTIC_GENERATED_TESTS
    func testClickLag4ProfileSeedsCurrentDrawBoardAndTaggedTaskAndNotes() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = ownedTemporaryDirectory(prefix: "AtticClickLag4Seed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: false, profile: .clickLag4)

        let context = ModelContext(container)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.count, 300)
        XCTAssertTrue(tasks.contains { !$0.tags.isEmpty })
        XCTAssertTrue(tasks.contains { $0.parentID != nil })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteItem>()), 80)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DrawCanvasRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DrawObjectRecord>()), 2_000)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DrawPayloadRecord>()), 200)
        let draw = DrawPersistentStore(container: container)
        guard let board = try draw.library().first else { return XCTFail("Missing Draw board") }
        XCTAssertEqual(try draw.open(board.id).objects.count, 2_000)
    }

    func testDoneHistorySeedLivesOnlyInDoneLog() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = ownedTemporaryDirectory(prefix: "AtticPerformanceSeedTests")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: true, now: now)

        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(notes.count, PerformanceSeed.noteCount)
        XCTAssertTrue(notes.allSatisfy { $0.contentFormat == 1 && $0.content.map { NoteContentCodec.decode($0).isEditable } == true })
        let noteAttachments = try context.fetch(FetchDescriptor<NoteAttachment>())
        let documentIDs = Set(notes.flatMap { $0.content.flatMap { NoteContentCodec.decode($0).document }?.attachmentIDs ?? [] })
        XCTAssertEqual(documentIDs, Set(noteAttachments.map(\.id)), "Every seeded attachment remains placed in a document")
        let store = TaskStore(container: container)
        let logged = store.doneLog()
        let today = Calendar.current.startOfDay(for: now)
        XCTAssertNil(store.lastErrorMessage, store.lastErrorMessage ?? "")
        XCTAssertEqual(logged.count, PerformanceSeed.doneHistoryCount)
        XCTAssertEqual(Set(logged.map(\.id)).count, PerformanceSeed.doneHistoryCount)
        XCTAssertTrue(logged.allSatisfy { task in
            guard let completedAt = task.completedAt else { return false }
            return task.status == .done && completedAt < today
                && task.doneLoggedAt == now && task.createdAt < completedAt
        })
        let completionDays = Set(logged.compactMap {
            $0.completedAt.map { Calendar.current.startOfDay(for: $0) }
        })
        XCTAssertGreaterThan(completionDays.count, 1)

        let loggedIDs = Set(logged.map(\.id))
        XCTAssertEqual(store.tasks.count, PerformanceSeed.taskCount)
        XCTAssertTrue(store.tasks.allSatisfy { !loggedIDs.contains($0.id) })
        XCTAssertTrue(store.snapshot(for: .tasks).sections
            .flatMap(\.tasks).allSatisfy { !loggedIDs.contains($0.id) })
    }
    #endif
}
