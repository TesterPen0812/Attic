import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class PerformanceSeedTests: XCTestCase {
    func testDoneHistorySeedLivesOnlyInDoneLog() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticPerformanceSeedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: true, now: now)

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
}
