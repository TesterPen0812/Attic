import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

/// Headless synchronous work triggered by Done's Find binding and body.
/// A keystroke follows panel reveal; reveal does not precompute any query.
@MainActor
final class DoneSearchCostTests: XCTestCase {
    /// The spec's 16 ms query budget holds each query's median across the
    /// three fresh sessions (owner, 2026-10-03), not every single sample: a
    /// shared CI runner's spike put one sample of 24 over 16 ms (16.19 ms
    /// in a session whose median was 12.6 ms). The slowest sample is held
    /// to no regression instead: `Scripts/check_done_search_costs.py`
    /// compares it with the accepted baseline's slowest plus its spread.
    static func assertMediansFitTheBudget(_ samples: [String: [Double]], _ fixture: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for (query, values) in samples.sorted(by: { $0.key < $1.key }) {
            let median = TasksFrameCostTests.median(values)
            print("ATTIC_DONE_QUERY_MEDIAN fixture=\(fixture) query=\(query) median_ms=\(median) sessions=\(values.count)")
            XCTAssertLessThanOrEqual(median, 16, "\(fixture): the median Done query \"\(query)\" exceeds the 16 ms budget",
                                     file: file, line: line)
        }
    }

    func testMeasuresDoneSearchOn5000Tasks() throws {
        var byQuery: [String: [Double]] = [:]
        for session in 0..<3 {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            try TasksPagePreview.seedScale(in: container)
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            revealBeforeTyping(model)
            var samples: [Double] = []
            for query in ["F", "Fi", "Finished", "task 12", "no match", "task", "task 123", "z"] {
                var marks = [DispatchTime.now().uptimeNanoseconds]
                model.doneSearch = query
                model.loadDoneLogIfNeeded()
                marks.append(DispatchTime.now().uptimeNanoseconds)
                _ = model.doneDays()
                marks.append(DispatchTime.now().uptimeNanoseconds)
                _ = model.doneSearchCount()
                marks.append(DispatchTime.now().uptimeNanoseconds)
                let parts = zip(marks.dropFirst(), marks).map { Double($0 - $1) / 1_000_000 }
                samples.append(parts.reduce(0, +))
                byQuery[query, default: []].append(samples.last!)
                print("ATTIC_DONE_SEARCH session=\(session) query=\(query) page/group/count_ms=\(parts) total_ms=\(samples.last!)")
            }
            print("ATTIC_DONE_SEARCH summary session=\(session) cold=\(samples[0]) warm=\(TasksFrameCostTests.stats(Array(samples.dropFirst())))")
        }
        Self.assertMediansFitTheBudget(byQuery, "memory")
    }

    private func revealBeforeTyping(_ model: TasksPageModel) {
        // Match the product lifecycle: the unfiltered panel must exist before
        // Find can receive a keystroke. This initializes its rows/date labels,
        // not matching or count work for any nonempty query. Each fixture's
        // first search below remains uncached; no tolerance raises 16 ms.
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        _ = model.doneDays()
    }

    func testIndexedPagesMatchTheExistingLocalizedSearchAndOrder() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let context = ModelContext(container)
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        let old = TaskItem(id: id, title: "Café old", status: .done, createdAt: date, updatedAt: date, completedAt: date)
        old.doneLoggedAt = date
        let winner = TaskItem(id: id, title: "Résumé current", status: .done, createdAt: date,
                              updatedAt: date.addingTimeInterval(1), completedAt: date)
        winner.doneLoggedAt = date
        context.insert(old)
        context.insert(winner)
        try context.save()
        let store = TaskStore(container: container)
        for query in ["", "F", "task 12", "no match", "CAFÉ", "resume", " Résumé "] {
            var legacyIDs: [UUID] = []
            var cursor = TaskStore.DoneLogCursor()
            while true {
                let page = store.doneLogPage(from: cursor, limit: 80, matching: query, excluding: Set(legacyIDs))
                XCTAssertNil(page.failure)
                legacyIDs += page.tasks.map(\.id)
                cursor = page.next
                if !page.hasMore { break }
            }
            var indexedIDs: [UUID] = []
            cursor = TaskStore.DoneLogCursor()
            while true {
                let page = store.indexedDoneLogPage(from: cursor, limit: 80, matching: query)
                XCTAssertNil(page.failure)
                XCTAssertLessThanOrEqual(page.tasks.count, 80)
                indexedIDs += page.tasks.map(\.id)
                cursor = page.next
                if !page.hasMore { break }
            }
            XCTAssertEqual(indexedIDs, legacyIDs, query)
            XCTAssertEqual(store.indexedDoneLogCount(matching: query), legacyIDs.count, query)
        }
    }

    func testSearchStaysLiveThroughEditsDeleteRestoreUndoAndRefresh() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.doneSearch = "task 12"
        model.loadDoneLogIfNeeded()
        let id = try XCTUnwrap(model.doneLogTasks.first?.id)
        model.beginEditingTitle(id)
        model.titleEdit.text = "Renamed café"
        XCTAssertTrue(model.commitTitle())
        model.loadDoneLogIfNeeded()
        XCTAssertFalse(model.doneLogTasks.contains { $0.id == id })
        model.doneSearch = "cafe"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.map(\.id), [id])
        model.undo()
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneLogTasks.isEmpty)
        model.redo()
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.map(\.id), [id])
        model.selectOnly(id)
        model.delete([id])
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneLogTasks.isEmpty)
        model.undo()
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.map(\.id), [id])
        model.restoreToNow(id)
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneLogTasks.isEmpty)
        model.undo()
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.map(\.id), [id])
        // Imported/direct writes replace the index and context on refresh.
        let external = ModelContext(container)
        let rows = try external.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        for row in rows { row.title = "External edit"; row.updatedAt = Date().addingTimeInterval(10) }
        try external.save()
        store.refresh()
        model.loadDoneLogIfNeeded()
        XCTAssertTrue(model.doneLogTasks.isEmpty)
        model.doneSearch = "External"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.map(\.id), [id])
        // A changed query always starts with one page, even after scrolling.
        model.doneSearch = "task"
        model.loadDoneLogIfNeeded()
        model.loadMoreDoneLog()
        XCTAssertEqual(model.doneLogTasks.count, 2 * TasksPageModel.doneLogPageSize)
        model.doneSearch = "Finished"
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneLogTasks.count, TasksPageModel.doneLogPageSize)
    }

    func testAFailedSaveNeverPublishesTheDraftIntoSearch() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        let original = try XCTUnwrap(store.indexedDoneLogPage(limit: 1).tasks.first)
        let id = original.id
        gate.shouldFail = true
        XCTAssertFalse(store.updateListed([id], title: "Unsaved searchable draft"))
        XCTAssertEqual(store.indexedDoneLogCount(matching: "Unsaved searchable"), 0)
        XCTAssertEqual(store.indexedDoneLogPage(limit: 1).tasks.first?.id, id)
        gate.shouldFail = false
        XCTAssertTrue(store.updateListed([id], title: "Saved searchable title"))
        XCTAssertEqual(store.indexedDoneLogCount(matching: "Saved searchable"), 1)
    }
    private final class InputPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func measureNativeEditingStartupControl() throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let panel = InputPanel(contentRect: CGRect(x: -4000, y: -4000, width: 344, height: 40),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = NSHostingView(rootView:
            TasksDoneSearchField(model: model, input: model.doneSearchInput, isFocused: .constant(true), onEscape: {})
                .atticDesign(AtticDesignContext(mode: .light)))
        panel.orderFront(nil)
        panel.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        Hosted.pumpEvents()
        let field = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let start = DispatchTime.now().uptimeNanoseconds
        field.insertText("F", replacementRange: field.selectedRange())
        RunLoop.current.run(until: Date())
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        print("ATTIC_NATIVE_INPUT_STARTUP zero_tasks_ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
        XCTAssertEqual(model.doneSearchInput.text, "F")
    }

    func testRenderedFindKeystrokeMediansFitTheInputBudget() throws {
        // The predecessor's "cold" boundary is a fresh Done store/model,
        // not initialization of the process-wide native editing machinery.
        // Measure that separately on an empty control, before constructing
        // the 5000-task fixture; no Done data/query is warmed here.
        try measureNativeEditingStartupControl()
        var runs: [[Double]] = []
        var resultFrames: [Double] = []
        for run in 0..<3 {
            let host = try FrameCostHost()
            host.place(.done)
            host.model.beginSearch()
            host.spin(0.6)
            Hosted.pumpEvents()
            host.spin(0.1)
            _ = host.frame()
            XCTAssertTrue(host.window.firstResponder is NSTextView, "Find must own the keyboard before typing")
            XCTAssertTrue(NSApp.keyWindow === host.window)
            let field = try XCTUnwrap(host.window.firstResponder as? NSTextView)
            var times: [Double] = []
            for character in "Finished task 12" {
                let before = TasksPage.tabsEvaluations
                let parts = host.framePhases {
                    field.insertText(String(character), replacementRange: field.selectedRange())
                }
                times.append(parts.reduce(0, +))
                XCTAssertEqual(TasksPage.tabsEvaluations, before, "typing must not rebuild the task page")
            }
            // The frame the results arrive in (PR prep, review P2-2): the
            // keystrokes above publish nothing; after 75 ms idle the query
            // publishes and the Done list rebuilds. Timed here directly,
            // before the idle publication can run on its own.
            XCTAssertNotEqual(host.model.doneSearch, "Finished task 12", "the query is still waiting for the idle publication")
            let parts = host.framePhases { host.model.flushDoneSearchInput() }
            let results = parts.reduce(0, +)
            resultFrames.append(results)
            print("ATTIC_DONE_RESULTS run=\(run) frame_ms=\(results) change/runloop/layout/display/commit_ms=\(parts)")
            host.spin(0.3)
            print("ATTIC_DONE_INPUT run=\(run) " + TasksFrameCostTests.stats(times) + " raw_ms=\(times)")
            XCTAssertEqual(host.model.doneSearchInput.text, "Finished task 12")
            XCTAssertEqual(host.model.doneSearch, "Finished task 12")
            XCTAssertEqual(host.model.doneSearchCount()?.matches, 111)
            runs.append(times)
            host.close()
        }
        // Independent optimized cold-first-frame runs: 12.754, 15.137,
        // 17.003 ms, a 4.249 ms within-build range. Freeze 4.3 ms as the
        // noise guard, while EACH character's median must fit the spec's
        // unchanged 16 ms budget. Query/controller samples above stay
        // hard-capped at 16 ms, including cold and the disk-backed seed.
        for key in runs[0].indices {
            let samples = runs.map { $0[key] }
            let median = TasksFrameCostTests.median(samples)
            XCTAssertLessThanOrEqual(median, 16, "Done Find key \(key) median exceeds the 16 ms budget")
            XCTAssertLessThanOrEqual(samples.max()!, 16 + 4.3, "sample exceeds the independently measured noise guard")
        }
        // The frame after the typing pauses, where the first results
        // arrive (not a keystroke frame, so not the keystroke budget). It
        // took 86–116 ms on CI (run 37107829899) while it redrew the whole
        // page twice and built the result rows cold; after the fix it
        // measured 73.9, 57.0 and 53.8 ms on CI (run 37135232964), and
        // 17–22 ms against 37–56 ms before on the owner's Mac (local,
        // optimized, interleaved).
        // Bound: that CI median plus its measured spread, 57.04 + 20.11 ms,
        // on the median of the three runs. The no-regression comparison
        // with the accepted baseline stays (`search-show`,
        // Scripts/check_cost_comparison.py).
        let resultsMedian = TasksFrameCostTests.median(resultFrames)
        print("ATTIC_DONE_RESULTS median_ms=\(resultsMedian) bound_ms=77.15")
        XCTAssertLessThanOrEqual(resultsMedian, 57.04 + 20.11, "the frame the Done results arrive in: \(resultFrames)")
    }

    func testDoneTodaySlicePreservesSnapshotRootsAndOrder() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let parent = TaskItem(title: "Parent", status: .todo)
        let doneParent = TaskItem(title: "Finished parent", status: .done, manualOrder: 20)
        let child = TaskItem(title: "Finished child", status: .done, parentID: parent.id)
        let orphan = TaskItem(title: "Orphan", status: .done, manualOrder: 30, parentID: UUID())
        let selfLinked = TaskItem(title: "Self linked", status: .done, manualOrder: 10)
        selfLinked.parentID = selfLinked.id
        let nested = TaskItem(title: "Nested root", status: .done, parentID: child.id)
        let logged = TaskItem(title: "Logged", status: .done)
        logged.doneLoggedAt = Date()
        let deleted = TaskItem(title: "Deleted", status: .done)
        deleted.deletedAt = Date()
        for task in [parent, doneParent, child, orphan, selfLinked, nested, logged, deleted] { context.insert(task) }
        try context.save()
        let store = TaskStore(container: container)
        let slice = store.doneTodayTasks().map(\.id)
        XCTAssertEqual(slice, store.snapshot(for: .tasks).sections.first { $0.status == .done }?.tasks.map(\.id))
        XCTAssertEqual(Set(slice), Set([doneParent.id, orphan.id, selfLinked.id, nested.id]))
        XCTAssertTrue(store.setStatus(.todo, for: try XCTUnwrap(store.task(withID: orphan.id))))
        XCTAssertEqual(store.doneTodayTasks().map(\.id), store.snapshot(for: .tasks).sections.first { $0.status == .done }?.tasks.map(\.id))
    }

    func testPreFocusTypingReachesTheEditorBeforeNativeTypingContinues() throws {
        let host = try FrameCostHost()
        defer { host.close() }
        host.place(.done)
        host.model.beginSearch()
        host.spin(0.6)
        Hosted.pumpEvents()
        let field = try XCTUnwrap(host.window.firstResponder as? NSTextView)
        // The keyboard fallback can supply letters before field ownership.
        // It must update only the small input view, before the idle query.
        host.model.typeDoneSearch("early")
        host.spin(0.02)
        XCTAssertEqual(field.string, "early")
        field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
        field.insertText("x", replacementRange: field.selectedRange())
        XCTAssertEqual(host.model.doneSearchInput.text, "earlyx")
    }

    func testCoalescingNeverAppliesAnOldQueryAfterEscapeAndFlushesBeforeNavigation() async throws {
        let store = try makeTestStore()
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.typeDoneSearch("old")
        model.typeDoneSearch("latest")
        XCTAssertEqual(model.doneSearch, "")
        XCTAssertEqual(model.searchQuery(for: .done), "latest")
        model.flushDoneSearchInput()
        XCTAssertEqual(model.doneSearch, "latest")
        model.typeDoneSearch("cancelled")
        model.setSearchQuery("", for: .done)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.doneSearch, "")
        XCTAssertEqual(model.doneSearchInput.text, "")
        model.typeDoneSearch("applied")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.doneSearch, "applied")
    }

    func testAnExplicitShowCancelsAPendingQueryThatWouldHideTheTask() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let id = try XCTUnwrap(store.indexedDoneLogPage(limit: 1).tasks.first?.id)
        model.typeDoneSearch("no match")
        XCTAssertEqual(model.show(id), .shown)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.doneSearch, "")
        XCTAssertEqual(model.doneSearchInput.text, "")
        XCTAssertTrue(model.doneLogTasks.contains { $0.id == id })
    }

    func testTheDiskBackedPhase5SeedAlsoFitsTheQueryBudget() throws {
        // Three sessions, each its own freshly seeded store measured as the
        // seed leaves it (as the accepted build measured its one session):
        // the budget holds each query's median across them.
        var byQuery: [String: [Double]] = [:]
        for session in 0..<3 {
            try measurePhase5Session(session, into: &byQuery)
        }
        Self.assertMediansFitTheBudget(byQuery, "phase5")
    }

    private func measurePhase5Session(_ session: Int, into byQuery: inout [String: [Double]]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDoneSearch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: true,
                                     now: Date(timeIntervalSince1970: 1_800_000_000))
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        XCTAssertEqual(store.indexedDoneLogCount(), 5000)
        revealBeforeTyping(model)
        var legacyTotal: Int?
        for query in ["F", "Fi", "Finished", "item 12", "zzzz-no-hit", "item", "item 123", "z"] {
            let before = DispatchTime.now().uptimeNanoseconds
            let legacy = store.doneLogPage(limit: TasksPageModel.doneLogPageSize, matching: query)
            let legacyMatches = store.doneLogTaskCount(matching: query)
            if legacyTotal == nil { legacyTotal = store.doneLogTaskCount() }
            let legacyMS = Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000
            let start = DispatchTime.now().uptimeNanoseconds
            model.doneSearch = query
            model.loadDoneLogIfNeeded()
            _ = model.doneDays()
            let count = model.doneSearchCount()
            let indexedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            byQuery[query, default: []].append(indexedMS)
            print("ATTIC_PHASE5_DONE session=\(session) query=\(query) legacy_page_count_lower_bound_ms=\(legacyMS) indexed_page_group_count_ms=\(indexedMS)")
            XCTAssertNil(legacy.failure)
            XCTAssertEqual(model.doneLogTasks.map(\.id), legacy.tasks.map(\.id))
            XCTAssertEqual(store.indexedDoneLogCount(matching: query), legacyMatches)
            XCTAssertEqual(count?.total, legacyTotal! + (store.snapshot(for: .tasks).sections.first { $0.status == .done }?.tasks.count ?? 0))
        }
    }

    func testPagingAfterADirectEditRefreshesTheCursorBeforeAppending() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.doneSearch = "task"
        model.loadDoneLogIfNeeded()
        let id = try XCTUnwrap(model.doneLogTasks.first?.id)
        XCTAssertTrue(store.updateListed([id], title: "Renamed"))
        // No revision watcher has run; paging must itself catch up.
        model.loadMoreDoneLog()
        let twoPages = 2 * TasksPageModel.doneLogPageSize
        XCTAssertEqual(model.doneLogTasks.count, twoPages)
        XCTAssertFalse(model.doneLogTasks.contains { $0.id == id })
        XCTAssertEqual(Set(model.doneLogTasks.map(\.id)).count, twoPages)
        XCTAssertEqual(model.doneLogTasks.map(\.id), store.doneLogPage(limit: twoPages, matching: "task").tasks.map(\.id))
    }

}
