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

    /// The real Phase 2 TaskStore mutation entry points, with durable saves.
    func testMeasuredTaskCRUDSavePaths() throws {
        let store = try seedStore(parents: 200, childrenPerParent: 0)
        let task = try XCTUnwrap(store.tasks.first)
        var tick: [Double] = [], rename: [Double] = [], add: [Double] = [], reorder: [Double] = [], delete: [Double] = []
        func ms(_ action: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            action()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        for index in 0..<8 {
            tick.append(ms { XCTAssertTrue(store.setStatus(index % 2 == 0 ? .done : .todo, for: task)) })
            rename.append(ms { XCTAssertTrue(store.update(task, title: "Renamed \(index)")) })
            var added: TaskItem?
            add.append(ms { added = store.create(title: "Added \(index)") })
            let row = try XCTUnwrap(added)
            reorder.append(ms { XCTAssertTrue(store.move(taskID: row.id, toIndex: 1)) })
            delete.append(ms { XCTAssertTrue(store.delete(row)) })
        }
        for (name, samples) in [("TICK", tick), ("RENAME", rename), ("ADD", add), ("REORDER", reorder), ("DELETE", delete)] {
            print("TASK_\(name)_MS_MEDIAN=\(samples.sorted()[samples.count / 2]) MAX=\(samples.max()!)")
        }
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
        let library = AtticLibrary(tasks: store)
        let children = store.tasks.filter { $0.parentID != nil }
        var index = 0
        var toggle = 0.0, snapshot = 0.0, lookup = 0.0
        #if ATTIC_OPERATION_CRASH_TESTS
        var phases: [String: Double] = [:]
        store.onSaveTiming = { phase, duration in
            let d = duration.components
            phases[phase, default: 0] += Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        #endif
        func ms(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let d = start.duration(to: .now).components
            return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        let median = medianMilliseconds(iterations: 7) {
            let child = children[index]
            index += 1
            toggle += ms { XCTAssertEqual(library.updateTask(child.id, status: .done), .applied) }
            snapshot += ms { _ = store.snapshot(for: .tasks) }
            lookup += ms { _ = store.subtasks(of: child.parentID!) }
        }
        print("PERFGATE toggle=\(toggle / 7) snapshot=\(snapshot / 7) lookup=\(lookup / 7)")
        #if ATTIC_OPERATION_CRASH_TESTS
        let writer = (phases["writer"] ?? 0) / 7
        let presentation = (phases["presentation"] ?? 0) / 7
        print("PERFGATE writer=\(writer) presentation=\(presentation)")
        #endif
        XCTAssertLessThan(median, 120, "a single toggle must not rescan or refetch the whole store (median \(median) ms)")
    }

    /// The audit measured 12.8 ms per 300-row × 6-read pass with a fresh
    /// JSON decode on every read. Compare the memoized path against that same
    /// decode-heavy work on the current runner instead of using a sub-3 ms
    /// absolute wall-clock threshold, which is too sensitive to hosted load.
    func testRepeatedAttachmentReadsAreMemoizedPerPayload() throws {
        let store = try seedStore(parents: 300, childrenPerParent: 0, attachmentsPerTask: 4)
        let rows = store.tasks
        XCTAssertEqual(rows.count, 300)
        let originalPayload = try XCTUnwrap(rows.first?.imageReferencesData)
        let originalReferences = try JSONDecoder().decode([TaskImageReference].self, from: originalPayload)
        let alternateReferences = originalReferences.enumerated().map { index, reference in
            index == 0
                ? TaskImageReference(
                    id: reference.id,
                    filename: "alternate.png",
                    digest: reference.digest,
                    contentTypeIdentifier: reference.contentTypeIdentifier,
                    byteCount: reference.byteCount
                )
                : reference
        }
        let alternatePayload = try JSONEncoder().encode(alternateReferences)

        // Prime each payload once so the timed block measures the contract in
        // this test's name: repeated reads should reuse the memoized decode.
        for row in rows { _ = row.attachments.count }
        var total = 0
        let memoizedMedian = medianMilliseconds {
            for row in rows {
                for _ in 0..<6 { total += row.attachments.count }
            }
        }
        XCTAssertEqual(total % 1_200, 0)

        // Toggle the stored bytes before every read so the cache key changes
        // and each access must decode. The ratio is the invariant we care
        // about and remains meaningful across differently loaded CI runners.
        let decodingMedian = medianMilliseconds(iterations: 7) {
            for row in rows {
                for index in 0..<6 {
                    row.imageReferencesData = index.isMultiple(of: 2) ? alternatePayload : originalPayload
                    total += row.attachments.count
                }
            }
        }
        XCTAssertLessThan(
            memoizedMedian * 2,
            decodingMedian,
            "memoized repeat reads must remain at least twice as fast as forced decodes "
                + "(memoized \(memoizedMedian) ms, decoding \(decodingMedian) ms)"
        )
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

// Process footprint sampled every millisecond during store open and its
// asynchronous reconciliation. Compare the absolute sampled peak with the
// identical fixture/base process, including its measured allocation spread.
private final class PFFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var readFailed = false
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    init() {
        sample()
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.resume()
    }
    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        lock.lock(); defer { lock.unlock() }
        readFailed = readFailed || status != KERN_SUCCESS
        peak = max(peak, Double(info.phys_footprint) / 1_048_576)
    }
    func finish() -> Double {
        timer.cancel()
        sample()
        lock.lock(); defer { lock.unlock() }
        XCTAssertFalse(readFailed, "PF3 footprint sampling must succeed")
        return peak
    }
    deinit { timer.cancel() }
}

// Diagnostic observers are installed only by the paired probe. Both archives
// run the same callbacks; validation and the paired tolerance stay unchanged.
@MainActor
private final class PFSaveDiagnostic {
    private let container: ModelContainer
    private var observers: [NSObjectProtocol] = []
    private var saveStart: UInt64?
    private(set) var saveMilliseconds: Double = 0
    init(_ container: ModelContainer) {
        self.container = container
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? ModelContext)?.container === self.container else { return }
                self.saveStart = DispatchTime.now().uptimeNanoseconds
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? ModelContext)?.container === self.container, let start = self.saveStart else { return }
                self.saveMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                self.saveStart = nil
            }
        })
    }
    func reset() { saveStart = nil; saveMilliseconds = 0 }
    func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
}

// BEGIN PAIRED PHASE 2 PERF PROBE
// This probe also runs from an archive of d77ec80 on the SAME runner. The
// workflow copies this file into that archive; it never touches phase-2's
// worktree/branch. Limits use that run's observed sample spread, not guesses.
extension TaskPerformanceGateTests {
    private struct PFSamples: Codable {
        var values: [Double]
        var median: Double { values.sorted()[values.count / 2] }
        var maximum: Double { values.max()! }
        var minimum: Double { values.min()! }
        var spread: Double { maximum - minimum }
    }
    private func pfMilliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    /// PF2 is measured THROUGH AtticLibrary, including its authoritative undo
    /// and before/after reads. PF3 compares the identical writes with 240
    /// unrelated notes, versions, proposals and attachments (over 60 MiB).
    func testPFFoundationSizeAndProductionPaths() async throws {
        var results: [String: PFSamples] = [:]
        let largeTasks = try seedStore(parents: 1_000, childrenPerParent: 5)
        let largeLibrary = AtticLibrary(tasks: largeTasks)
        let children = largeTasks.tasks.filter { $0.parentID != nil }
        results["SIX_THOUSAND_TOGGLE_MS"] = PFSamples(values: (0..<7).map { i in
            pfMilliseconds { XCTAssertEqual(largeLibrary.updateTask(children[i].id, status: .done), .applied) }.1
        })
        XCTAssertLessThanOrEqual(results["SIX_THOUSAND_TOGGLE_MS"]!.maximum, 120)
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container)
            let head = TaskItem(title: "Measured head", manualOrder: 0)
            seed.insert(head)
            // Keep the active task fixture identical in both size cases.
            for i in 1..<200 { seed.insert(TaskItem(title: "Task \(i)", manualOrder: Int64(i) * 1_024)) }
            let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            let prepared = try PreparedNoteDocument(document)
            let noteID = UUID(), revision = UUID(), timestamp = Date()
            let note = NoteItem(id: noteID)
            note.content = prepared.content; note.contentFormat = 1
            note.title = prepared.title; note.body = prepared.body; note.plainText = prepared.plainText
            note.revisionID = revision
            seed.insert(note)
            if populated {
                let unrelated = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let other = NoteItem(title: "Unrelated \(i)", body: unrelated.body)
                    other.content = unrelated.content; other.contentFormat = 1
                    other.plainText = unrelated.plainText; other.revisionID = UUID()
                    seed.insert(other)
                    seed.insert(NoteVersion(noteID: other.id, createdAt: timestamp, reason: .leave,
                        content: unrelated.content, contentFormat: 1, title: other.title, body: other.body,
                        attachmentIDs: [], sourceRevisionID: other.revisionID))
                    seed.insert(NotePendingEdit(noteID: other.id, baseRevisionToken: other.revisionToken,
                        proposedContent: unrelated.content, agentName: "PF seed", createdAt: timestamp))
                    let bytes = Data(repeating: UInt8(i % 255), count: 128 * 1_024)
                    seed.insert(NoteAttachment(noteID: other.id, originalFilename: "seed-\(i).bin", byteCount: Int64(bytes.count),
                        sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes))
                }
            }
            try seed.save()
            let label = populated ? "POPULATED" : "EMPTY"
            var opens: [Double] = [], footprints: [Double] = []
            for _ in 0..<7 {
                let sampler = PFFootprintSampler()
                let ((tasks, notes, library), duration) = try pfMilliseconds {
                    let opened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                    let tasks = TaskStore(container: opened)
                    let notes = NoteStore(container: opened, attachmentFileStore: makeTestAttachmentFileStore())
                    return (tasks, notes, AtticLibrary(tasks: tasks, notes: notes))
                }
                opens.append(duration)
                XCTAssertEqual(tasks.tasks.count, 200)
                XCTAssertEqual(library.tasks.tasks.count, 200)
                await notes.waitForAttachmentReconciliation()
                footprints.append(sampler.finish())
            }
            results["\(label)_OPEN_MS"] = PFSamples(values: opens)
            results["\(label)_OPEN_PEAK_MB"] = PFSamples(values: footprints)
            let tasks = TaskStore(container: container)
            let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
            let library = AtticLibrary(tasks: tasks, notes: notes)
            await notes.waitForAttachmentReconciliation()
            // Match autosave of an already-open note; both bases perform the
            // same capability preflight outside the timed commit.
            _ = try notes.noteMutationPreflight(noteID, format: .document)
            let source = AtticItemRef(.task, head.id), target = AtticItemRef(.note, noteID)
            let link = try XCTUnwrap(library.links.link(source, to: target, kind: .reference))
            var toggles: [Double] = [], links: [Double] = [], saves: [Double] = []
            var baseRevision = revision
            for i in 0..<9 {
                toggles.append(pfMilliseconds {
                    XCTAssertEqual(library.updateTask(head.id, status: i.isMultiple(of: 2) ? .done : .todo), .applied)
                }.1)
                links.append(pfMilliseconds {
                    XCTAssertTrue(i.isMultiple(of: 2) ? library.links.unlink(link.id) : library.links.restoreLink(link.id))
                }.1)
                var candidate = document
                candidate.blocks[0] = .text("Saved \(i)")
                let projection = try PreparedNoteDocument(candidate)
                let (result, duration) = pfMilliseconds {
                    notes.saveDocument(noteID: noteID, document: candidate, baseRevisionID: baseRevision, staged: [], prepared: projection)
                }
                guard case let .success(next) = result else { return XCTFail("PF autosave failed: \(result)") }
                baseRevision = next
                saves.append(duration)
            }
            results["\(label)_TOGGLE_MS"] = PFSamples(values: toggles)
            results["\(label)_LINK_MS"] = PFSamples(values: links)
            results["\(label)_SAVE_MS"] = PFSamples(values: saves)
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF_\(key)_MEDIAN=\(sample.median) MIN=\(sample.minimum) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        let env = ProcessInfo.processInfo.environment
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(results), as: UTF8.self) + "\n").utf8))
        // Local probes remain useful without an exported hosted baseline.
        // CI sets this for both the focused PF lane and the full hosted suite.
        if env["ATTIC_PF_REQUIRE_REFERENCE"] == "1" {
            XCTAssertNotNil(env["ATTIC_PF_REFERENCE_JSON"], "CI must measure and export the fixed Phase 2 reference")
        }
        if let json = env["ATTIC_PF_REFERENCE_JSON"] {
            let reference = try JSONDecoder().decode([String: PFSamples].self, from: Data(json.utf8))
            for key in results.keys.sorted() {
                let actual = results[key]!, base = try XCTUnwrap(reference[key])
                // Tolerance = largest reference sample + its measured spread.
                // This is the same noise rule as Phase 2's PF1 assertions.
                XCTAssertLessThanOrEqual(actual.median, base.maximum + base.spread, "\(key) exceeded fixed Phase 2 spread")
                XCTAssertLessThanOrEqual(actual.maximum, base.maximum + base.spread, "\(key) maximum exceeded fixed Phase 2 spread")
            }
            for metric in ["SAVE_MS", "TOGGLE_MS", "LINK_MS"] {
                let empty = results["EMPTY_\(metric)"]!, full = results["POPULATED_\(metric)"]!
                let bEmpty = reference["EMPTY_\(metric)"]!, bFull = reference["POPULATED_\(metric)"]!
                // Paired size tolerance uses the reference's worst observed
                // populated-minus-empty delta plus one observed sample spread.
                let noise = bFull.maximum - bEmpty.minimum + max(bFull.spread, bEmpty.spread)
                XCTAssertLessThanOrEqual(full.median - empty.median, noise, "PF3 \(metric) scales with unrelated contents")
            }
        }
        XCTAssertLessThanOrEqual(results["POPULATED_TOGGLE_MS"]!.maximum, 120)
    }
    /// The base archive runs this identical 200-iteration session in one
    /// process. Compare each operation with its matching quintile, including
    /// every maximum; a stable overall median cannot hide session growth.
    func testPF5InterleavedSessionSoakAgainstPairedBase() async throws {
        var results: [String: PFSamples] = [:]
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF5-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container), head = TaskItem(title: "Measured head", manualOrder: 0)
            seed.insert(head)
            for i in 1..<200 { seed.insert(TaskItem(title: "Task \(i)", manualOrder: Int64(i) * 1_024)) }
            let small = NoteDocument(blocks: [.text("Small")])
            let big = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            let smallNote = NoteItem(), bigNote = NoteItem()
            for (row, document) in [(smallNote, small), (bigNote, big)] {
                let prepared = try PreparedNoteDocument(document)
                row.content = prepared.content; row.contentFormat = 1
                row.title = prepared.title; row.body = prepared.body; row.plainText = prepared.plainText; row.revisionID = UUID()
                seed.insert(row)
            }
            if populated {
                let prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let row = NoteItem(title: "Unrelated \(i)", body: prepared.body)
                    row.content = prepared.content; row.contentFormat = 1; row.plainText = prepared.plainText; row.revisionID = UUID()
                    seed.insert(row)
                    seed.insert(NoteVersion(noteID: row.id, createdAt: Date(), reason: .leave, content: prepared.content,
                        contentFormat: 1, title: row.title, body: row.body, attachmentIDs: [], sourceRevisionID: row.revisionID))
                    let bytes = Data(repeating: UInt8(i % 255), count: 128 * 1_024)
                    seed.insert(NoteAttachment(noteID: row.id, originalFilename: "seed-\(i).bin", byteCount: Int64(bytes.count),
                        sortIndex: 0, contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes))
                }
            }
            try seed.save()
            let tasks = TaskStore(container: container), notes = NoteStore(container: container,
                attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            let library = AtticLibrary(tasks: tasks, notes: notes)
            await notes.waitForAttachmentReconciliation()
            _ = try notes.noteMutationPreflight(smallNote.id, format: .document)
            _ = try notes.noteMutationPreflight(bigNote.id, format: .document)
            let link = try XCTUnwrap(library.links.link(.init(.task, head.id), to: .init(.note, bigNote.id), kind: .reference))
            var samples: [String: [Double]] = [:]
            var diagnostics: [String: [(Date, Double)]] = [:]
            let saveDiagnostic = PFSaveDiagnostic(container)
            defer { saveDiagnostic.stop() }
            func measured(_ operation: String, _ body: () throws -> Void) rethrows -> Double {
                let timestamp = Date()
                saveDiagnostic.reset()
                let duration = try pfMilliseconds(body).1
                diagnostics[operation, default: []].append((timestamp, saveDiagnostic.saveMilliseconds))
                return duration
            }
            var smallRevision = smallNote.revisionID!, bigRevision = bigNote.revisionID!
            for i in 0..<200 {
                samples["TOGGLE", default: []].append(measured("TOGGLE") {
                    XCTAssertEqual(library.updateTask(head.id, status: i.isMultiple(of: 2) ? .done : .todo), .applied)
                })
                samples["RENAME", default: []].append(measured("RENAME") {
                    XCTAssertEqual(library.updateTask(head.id, title: "Renamed \(i)"), .applied)
                })
                samples["LINK_PAIR", default: []].append(measured("LINK_PAIR") {
                    XCTAssertTrue(library.links.unlink(link.id)); XCTAssertTrue(library.links.restoreLink(link.id))
                })
                var smallNext = small; smallNext.blocks[0] = .text("Small \(i)")
                let smallPrepared = try PreparedNoteDocument(smallNext)
                samples["SMALL_AUTOSAVE", default: []].append(try measured("SMALL_AUTOSAVE") {
                    smallRevision = try notes.saveDocument(noteID: smallNote.id, document: smallNext,
                        baseRevisionID: smallRevision, staged: [], prepared: smallPrepared).get()
                })
                var bigNext = big; bigNext.blocks[0] = .text("Big \(i)")
                let bigPrepared = try PreparedNoteDocument(bigNext)
                samples["BIG_AUTOSAVE", default: []].append(try measured("BIG_AUTOSAVE") {
                    bigRevision = try notes.saveDocument(noteID: bigNote.id, document: bigNext,
                        baseRevisionID: bigRevision, staged: [], prepared: bigPrepared).get()
                })
            }
            for (operation, values) in samples {
                XCTAssertEqual(values.count, 200)
                for q in 0..<5 {
                    let key = "\(populated ? "POPULATED" : "EMPTY")_\(operation)_Q\(q + 1)_MS"
                    let quintile = Array(values[q * 40..<(q + 1) * 40])
                    results[key] = PFSamples(values: quintile)
                    let index = q * 40 + quintile.firstIndex(of: quintile.max()!)!
                    let diagnostic = diagnostics[operation]![index]
                    print("PF5_MAX_DIAGNOSTIC key=\(key) iteration=\(index) utc=\(diagnostic.0.ISO8601Format()) utc_epoch_ms=\(Int64(diagnostic.0.timeIntervalSince1970 * 1_000)) total_ms=\(values[index]) save_ms=\(diagnostic.1)")
                }
            }
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF5_\(key)_MEDIAN=\(sample.median) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        // Export exact sufficient statistics in a short atomic log line;
        // raw quintile samples remain separately readable below PIPE_BUF.
        for key in results.keys.sorted() {
            print("PF5_SAMPLES_\(key)=" + results[key]!.values.map { String($0) }.joined(separator: ","))
        }
        let summary = results.mapValues { PFSamples(values: [$0.minimum, $0.median, $0.maximum]) }
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF5_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(summary), as: UTF8.self) + "\n").utf8))
        let env = ProcessInfo.processInfo.environment
        if env["ATTIC_PF_REQUIRE_REFERENCE"] == "1" {
            XCTAssertNotNil(env["ATTIC_PF5_REFERENCE_JSON"], "CI must export the matching Phase 2 session")
        }
        if let json = env["ATTIC_PF5_REFERENCE_JSON"] {
            let reference = try JSONDecoder().decode([String: PFSamples].self, from: Data(json.utf8))
            for key in results.keys.sorted() {
                let actual = results[key]!, base = try XCTUnwrap(reference[key])
                XCTAssertLessThanOrEqual(actual.median, base.maximum + base.spread, "PF5 \(key) median")
                XCTAssertLessThanOrEqual(actual.maximum, base.maximum + base.spread, "PF5 \(key) maximum")
            }
        }
    }

    /// Same-runner attribution for both Phase 2 PF1 production entry points.
    /// The unchanged NotesPageControllerTests retain their absolute constants.
    func testPF1LargeAutosaveAndPreparedCommitAgainstPairedBase() async throws {
        var results: [String: PFSamples] = [:]
        for populated in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPF1-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
            let seed = ModelContext(container)
            if populated {
                let prepared = try PreparedNoteDocument(NoteDocument(blocks: [.text(String(repeating: "unrelated ", count: 4_096))]))
                for i in 0..<240 {
                    let note = NoteItem(title: "Unrelated \(i)", body: prepared.body)
                    note.content = prepared.content; note.contentFormat = 1; note.plainText = prepared.plainText; note.revisionID = UUID()
                    seed.insert(note)
                    seed.insert(NoteVersion(noteID: note.id, createdAt: Date(), reason: .leave, content: prepared.content,
                        contentFormat: 1, title: note.title, body: note.body, attachmentIDs: [], sourceRevisionID: note.revisionID))
                }
            }
            try seed.save()
            let store = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            await store.waitForAttachmentReconciliation()
            let document = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0) with ordinary note text") })
            let (id, _) = try store.createDocumentNote(id: UUID(), document: document).get()
            let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root.appendingPathComponent("Drafts")),
                saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
            await controller.startAndWait()
            let opened = await controller.openDurably(noteID: id)
            XCTAssertTrue(opened)
            let session = try XCTUnwrap(controller.active)
            var autosaves: [Double] = [], commits: [Double] = []
            for _ in 0..<8 {
                session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                    with: NSAttributedString(string: "x"), name: "Typing")
                autosaves.append(pfMilliseconds { XCTAssertTrue(controller.save(session)) }.1)
                session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                    with: NSAttributedString(string: "y"), name: "Typing")
                let snapshot = session.engine.document(), prepared = try PreparedNoteDocument(snapshot)
                commits.append(pfMilliseconds {
                    XCTAssertTrue(controller.save(session, snapshot: snapshot, stagedSnapshot: [], prepared: prepared))
                }.1)
            }
            await controller.waitForRecoveryWork()
            let label = populated ? "POPULATED" : "EMPTY"
            results["\(label)_AUTOSAVE_5000_MS"] = PFSamples(values: autosaves)
            results["\(label)_PREPARED_COMMIT_5000_MS"] = PFSamples(values: commits)
        }
        for key in results.keys.sorted() {
            let sample = results[key]!
            print("PF1_\(key)_MEDIAN=\(sample.median) MAX=\(sample.maximum) SPREAD=\(sample.spread)")
        }
        fflush(stdout)
        try FileHandle.standardOutput.write(contentsOf: Data(("PF1_REFERENCE_JSON=" + String(decoding: try JSONEncoder().encode(results), as: UTF8.self) + "\n").utf8))
        let env = ProcessInfo.processInfo.environment
        if env["ATTIC_PF_REQUIRE_REFERENCE"] == "1" {
            XCTAssertNotNil(env["ATTIC_PF1_REFERENCE_JSON"], "CI must export the matching Phase 2 PF1 samples")
        }
        if let json = env["ATTIC_PF1_REFERENCE_JSON"] {
            let reference = try JSONDecoder().decode([String: PFSamples].self, from: Data(json.utf8))
            for key in results.keys.sorted() {
                let actual = results[key]!, base = try XCTUnwrap(reference[key])
                XCTAssertLessThanOrEqual(actual.median, base.maximum + base.spread, "PF1 \(key) median")
                XCTAssertLessThanOrEqual(actual.maximum, base.maximum + base.spread, "PF1 \(key) maximum")
            }
        }
    }

}
// END PAIRED PHASE 2 PERF PROBE
