import SwiftData
import XCTest
@testable import Attic

/// Reproducible scaling gates for the task model. Each test measures the
/// hot path the audits timed and also asserts an absolute bound, so a
/// regression back to the O(n²) shapes fails the test rather than only
/// shifting a metric. Bounds are generous for CI machines; the recorded
/// medians live in Docs/Fable51FullRepair.md.
@MainActor
final class TaskPerformanceGateTests: XCTestCase {
    private func seedStore(parents: Int, childrenPerParent: Int, attachmentsPerTask: Int = 0) throws -> TaskStore {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let references = (0..<attachmentsPerTask).map { index in
            TaskImageReference(id: UUID(), filename: "file-\(index).png", digest: String(repeating: "a", count: 64),
                               contentTypeIdentifier: "public.png", byteCount: 1_024)
        }
        let payload = attachmentsPerTask > 0 ? try JSONEncoder().encode(references) : nil
        for parentIndex in 0..<parents {
            let parent = TaskItem(title: "Parent \(parentIndex)", manualOrder: Int64(parentIndex))
            parent.imageReferencesData = payload
            context.insert(parent)
            for childIndex in 0..<childrenPerParent {
                let child = TaskItem(title: "Child \(childIndex)", manualOrder: Int64(childIndex), parentID: parent.id)
                context.insert(child)
            }
        }
        try context.save()
        return TaskStore(container: container)
    }

    private func medianMilliseconds(iterations: Int = 9, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            body()
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        return samples.sorted()[iterations / 2]
    }

    /// The audit's family-summary shape: three children evaluations per
    /// parent across 1,000 parents / 6,000 tasks measured 357 ms with the
    /// scan-based lookup. The index answers each in O(1).
    func testFamilySummaryPassAtSixThousandTasksIsMilliseconds() throws {
        let store = try seedStore(parents: 1_000, childrenPerParent: 5)
        let parents = store.tasks.filter { $0.parentID == nil }
        XCTAssertEqual(parents.count, 1_000)
        var checksum = 0
        let median = medianMilliseconds {
            for parent in parents {
                guard store.hasSubtasks(parent.id) else { continue }
                checksum += store.subtasks(of: parent.id).reduce(0) { $0 + ($1.status == .done ? 1 : 0) }
                checksum += store.subtasks(of: parent.id).count
            }
        }
        XCTAssertEqual(checksum, 5_000 * 9)
        XCTAssertLessThan(median, 25, "family lookups must stay near-constant per row (median \(median) ms)")
        measure(metrics: [XCTClockMetric()]) {
            for parent in parents { _ = store.subtasks(of: parent.id).count }
        }
    }

    /// A mutation invalidates the index once; the rebuild is one linear pass
    /// and the sections snapshot stays memoized between mutations.
    func testStatusToggleAtSixThousandTasksStaysBounded() throws {
        let store = try seedStore(parents: 1_000, childrenPerParent: 5)
        let children = store.tasks.filter { $0.parentID != nil }
        var index = 0
        var toggle = 0.0, snapshot = 0.0, lookup = 0.0
        func ms(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let d = start.duration(to: .now).components
            return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        let median = medianMilliseconds(iterations: 7) {
            let child = children[index]
            index += 1
            toggle += ms { XCTAssertTrue(store.setStatus(.done, for: child)) }
            snapshot += ms { _ = store.snapshot(for: .tasks) }
            lookup += ms { _ = store.subtasks(of: child.parentID!) }
        }
        print("PERFGATE toggle=\(toggle / 7) snapshot=\(snapshot / 7) lookup=\(lookup / 7)")
        XCTAssertLessThan(median, 120, "a single toggle must not rescan or refetch the whole store (median \(median) ms)")
    }

    /// The audit measured 12.8 ms per 300-row × 6-read pass with a fresh
    /// JSON decode on every read; the memo makes repeat reads a comparison.
    func testRepeatedAttachmentReadsAreMemoizedPerPayload() throws {
        let store = try seedStore(parents: 300, childrenPerParent: 0, attachmentsPerTask: 4)
        let rows = store.tasks
        XCTAssertEqual(rows.count, 300)
        // Prime each payload once so the timed block measures the contract in
        // this test's name: repeated reads should reuse the memoized decode.
        for row in rows { _ = row.attachments.count }
        var total = 0
        let median = medianMilliseconds {
            for row in rows {
                for _ in 0..<6 { total += row.attachments.count }
            }
        }
        XCTAssertEqual(total % 1_200, 0)
        XCTAssertLessThan(median, 3, "repeat reads must not decode again (median \(median) ms)")
        measure(metrics: [XCTClockMetric()]) {
            for row in rows { _ = row.attachments.count }
        }
    }

    /// Writing a new payload invalidates the memo: the decoded list follows
    /// the stored bytes, never a stale copy.
    func testAttachmentMemoFollowsThePayload() throws {
        let task = TaskItem(title: "Memo")
        XCTAssertTrue(task.attachments.isEmpty)
        let one = TaskImageReference(id: UUID(), filename: "a.png", digest: "d", contentTypeIdentifier: "public.png", byteCount: 1)
        task.imageReferencesData = try JSONEncoder().encode([one])
        XCTAssertEqual(task.attachments.map(\.id), [one.id])
        let two = TaskImageReference(id: UUID(), filename: "b.png", digest: "e", contentTypeIdentifier: "public.png", byteCount: 2)
        task.imageReferencesData = try JSONEncoder().encode([one, two])
        XCTAssertEqual(task.attachments.map(\.id), [one.id, two.id])
        task.imageReferencesData = nil
        XCTAssertTrue(task.attachments.isEmpty)
    }
}
