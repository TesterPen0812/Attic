import AppKit
import Combine
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

/// Headless synchronous work triggered by Done's Find binding and body.
/// A keystroke follows panel reveal; reveal does not precompute any query.
@MainActor
final class DoneSearchCostTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

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
            CostBudget.assertLessThanOrEqual(median, 16, "\(fixture): the median Done query \"\(query)\" exceeds the 16 ms budget",
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

    func testExplicitNSStringIndexMatchingPreservesLocalizedSemanticsWithoutWrites() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let titles = ["Café", "Cafe\u{301}", "Résumé", "Straße", "ｶﾀｶﾅ", "task １２", "Plan 🏠", "Unrelated"]
        let tasks = titles.enumerated().map { index, title in
            let date = Date(timeIntervalSince1970: Double(10_000 - index))
            let task = TaskItem(title: title, status: .done, createdAt: date, updatedAt: date, completedAt: date)
            task.doneLoggedAt = date
            context.insert(task)
            return task
        }
        try context.save()
        var saves = 0
        let store = TaskStore(container: container, persist: { context in saves += 1; try context.save() })
        let initialSaves = saves
        let revision = store.revision
        for query in ["", "cafe", "CAFÉ", "Cafe\u{301}", " \n resume \t", "strasse", "カタカナ", "12", "🏠", "no match"] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = tasks.filter { trimmed.isEmpty || $0.title.localizedStandardContains(trimmed) }.map(\.id)
            // Repeat to exercise the cache as well as each fresh search.
            for _ in 0..<2 {
                let page = store.indexedDoneLogPage(limit: 80, matching: query)
                XCTAssertNil(page.failure)
                XCTAssertEqual(page.tasks.map(\.id), expected, query)
                XCTAssertEqual(store.indexedDoneLogCount(matching: query), expected.count, query)
            }
        }
        XCTAssertEqual(saves, initialSaves, "Searching must not enter the gated save path")
        XCTAssertEqual(store.revision, revision)
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
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1 and an exclusive desktop")
        }
        // The predecessor's "cold" boundary is a fresh Done store/model,
        // not initialization of the process-wide native editing machinery.
        // Measure that separately on an empty control, before constructing
        // the 5000-task fixture; no Done data/query is warmed here.
        try measureNativeEditingStartupControl()
        var runs: [[Double]] = []
        var keyPhases: [[[Double]]] = []
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
            var phases: [[Double]] = []
            for character in "Finished task 12" {
                let before = TasksPage.tabsEvaluations
                let parts = host.framePhases {
                    field.insertText(String(character), replacementRange: field.selectedRange())
                }
                times.append(parts.reduce(0, +))
                phases.append(parts)
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
            keyPhases.append(phases)
            host.close()
        }
        // Emit only after every input/results measurement and host close.
        // Logging between keys can change idle publication and the next frame.
        for (run, phases) in keyPhases.enumerated() {
            for (key, parts) in phases.enumerated() {
                print("ATTIC_DONE_KEY_PHASE run=\(run) key=\(key) change/runloop/layout/display/commit_ms=\(parts)")
            }
        }
        // Keep the spec's per-character median budget. Individual samples
        // compare by median with the same-job reference in the CI comparator,
        // rather than the old single-run 16 + 4.3 ms noise constant.
        for key in runs[0].indices {
            let samples = runs.map { $0[key] }
            let median = TasksFrameCostTests.median(samples)
            CostBudget.assertLessThanOrEqual(median, 16, "Done Find key \(key) median exceeds the 16 ms budget")
            print("ATTIC_DONE_KEY key=\(key) raw_ms=\(samples)")
            CostBudget.assertLessThan(samples.max()!, 500, "runaway Done input frame")
        }
        // OD-8: unchanged code ranged 30–84 ms across today's CI runs.
        // The old 77.15 ms bound came from one early run. CI now compares
        // these samples to reference median + max(reference range, measured
        // resolution) + 0.2 ms (OD-9). The comparator prints the resolution.
        print("ATTIC_DONE_RESULTS median_ms=\(TasksFrameCostTests.median(resultFrames))")
        // Every sample still has the independent 500 ms sanity ceiling.
        for sample in resultFrames {
            CostBudget.assertLessThan(sample, 500, "the frame the Done results arrive in: \(resultFrames)")
        }

    }

    /// Keep the input boundary structural: timings are reported by the cost
    /// test, while this guard is independent of the machine's frame time.
    func testFirstNativeCharacterLeavesDoneResultsAndTheTaskPageAloneUntilFlush() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1")
        }
        let host = try FrameCostHost()
        defer { host.close() }
        host.place(.done)
        host.model.beginSearch()
        host.spin(0.6)
        Hosted.pumpEvents()
        host.spin(0.1)
        _ = host.frame()
        let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
        let ids = host.model.doneLogTasks.map(\.id)
        let evaluations = TasksPage.tabsEvaluations
        let layouts = host.layoutPasses
        var pagePublications = 0, inputPublications = 0, resultPublications = 0
        let observations = [
            host.model.objectWillChange.sink { pagePublications += 1 },
            host.model.doneSearchInput.objectWillChange.sink { inputPublications += 1 },
            host.model.doneResults.objectWillChange.sink { resultPublications += 1 }
        ]
        defer { withExtendedLifetime(observations) {} }
        let milliseconds = host.frame {
            editor.insertText("F", replacementRange: editor.selectedRange())
        }
        print("ATTIC_DONE_FIRST_CHARACTER frame_ms=\(milliseconds)")
        print("ATTIC_DONE_FIRST_PUBLICATIONS page/input/results=\([pagePublications, inputPublications, resultPublications])")
        XCTAssertEqual(pagePublications, 0)
        XCTAssertEqual(inputPublications, 0)
        XCTAssertEqual(resultPublications, 0)
        XCTAssertEqual(host.model.doneSearchInput.text, "F")
        XCTAssertEqual(host.model.doneSearch, "")
        XCTAssertEqual(host.model.doneLogTasks.map(\.id), ids)
        XCTAssertEqual(TasksPage.tabsEvaluations, evaluations)
        XCTAssertEqual(host.layoutPasses, layouts,
                       "typing in the fixed native field must not relayout the surrounding page")
        host.model.flushDoneSearchInput()
        XCTAssertEqual(host.model.doneSearch, "F")
        host.model.loadDoneLogIfNeeded()
        XCTAssertEqual(host.model.doneSearchCount()?.matches, host.store.indexedDoneLogCount(matching: "F"))
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
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1 and an exclusive desktop")
        }
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

    func testNativeQueryEditorKeepsCompositionUndoAndFocusBehavior() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1")
        }
        let model = TasksPageModel(library: AtticLibrary(tasks: try makeTestStore()))
        let panel = InputPanel(contentRect: CGRect(x: -4000, y: -4000, width: 344, height: 40),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.makeFirstResponder(nil); panel.contentView = nil; panel.close() }
        var escapes = 0
        panel.contentView = NSHostingView(rootView:
            TasksDoneSearchField(model: model, input: model.doneSearchInput, isFocused: .constant(true),
                                 onEscape: { escapes += 1; model.setSearchQuery("", for: .done) })
                .atticDesign(AtticDesignContext(mode: .light)))
        panel.orderFront(nil)
        panel.makeKey()
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); Hosted.pumpEvents() }
        settle()
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        editor.insertText("café", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        settle()
        XCTAssertEqual(model.doneSearchInput.text, "café")
        XCTAssertTrue(editor.allowsUndo)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(model.doneSearchInput.text, "")
        undo.redo()
        XCTAssertEqual(model.doneSearchInput.text, "café")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("日本", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(model.doneSearchInput.text, "日本")
        XCTAssertTrue(panel.makeFirstResponder(nil))
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertTrue(panel.firstResponder === editor, "the cell keeps its editor across focus changes")
        XCTAssertEqual(editor.string, "日本")
        model.typeDoneSearch("external")
        settle()
        XCTAssertEqual(editor.string, "external")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        settle()
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(model.doneSearchInput.text, "")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapes, 2, "Escape is still routed for an empty query")
        editor.insertText("reopened", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.doneSearchInput.text, "reopened")
    }

    // MARK: Header parity (wave 2 review 2)

    /// Done's header field and the header field the other pages use, each in
    /// its own off-screen panel at the same width.
    private func hostHeaderSearch(done: Bool, focused: Bool) throws -> (panel: InputPanel, field: NSTextField) {
        let model = TasksPageModel(library: AtticLibrary(tasks: try makeTestStore()))
        let panel = InputPanel(contentRect: CGRect(x: -4000, y: -4000, width: 300, height: 40),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let field: AnyView = done
            ? AnyView(TasksDoneSearchField(model: model, input: model.doneSearchInput, isFocused: .constant(focused),
                                           onEscape: {}, header: true))
            : AnyView(AtticTabsSearchField(placeholder: "Search", text: .constant(""), isFocused: .constant(focused),
                                           floating: true, onEscape: {}, header: true))
        panel.contentView = NSHostingView(rootView: field.frame(width: 300, height: 40)
            .atticDesign(AtticDesignContext(mode: .light)))
        panel.orderFront(nil)
        if focused { panel.makeKey() }
        RunLoop.current.run(until: Date().addingTimeInterval(focused ? 0.3 : 0.05))
        Hosted.pumpEvents()
        panel.contentView?.layoutSubtreeIfNeeded()
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] + fields(in: $0) }
        }
        let found = try XCTUnwrap(fields(in: try XCTUnwrap(panel.contentView)).first { $0.isEditable })
        return (panel, found)
    }

    private struct TextGeometry: Equatable {
        var frame: CGRect, baseline: CGFloat, font: String, size: CGFloat
        var placeholderFont: String?, placeholderSize: CGFloat?, placeholderColor: String?
    }

    private func geometry(_ field: NSTextField) throws -> TextGeometry {
        let font = try XCTUnwrap(field.font)
        let title = try XCTUnwrap(field.cell).titleRect(forBounds: field.bounds)
        let baselineInField = field.isFlipped ? title.minY + font.ascender : title.maxY - font.ascender
        let placeholder = field.placeholderAttributedString
        let pFont = placeholder?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let pColor = (placeholder?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
            .usingColorSpace(.sRGB).map { String(format: "%.3f %.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) }
        return TextGeometry(frame: field.convert(field.bounds, to: nil),
                            baseline: field.convert(NSPoint(x: 0, y: baselineInField), to: nil).y,
                            font: font.fontName, size: font.pointSize,
                            placeholderFont: pFont?.fontName, placeholderSize: pFont?.pointSize, placeholderColor: pColor)
    }

    func testDonesHeaderSearchSetsItsTextExactlyWhereTheOtherHeaderSearchDoes() throws {
        let (tasksPanel, tasksField) = try hostHeaderSearch(done: false, focused: false)
        defer { tasksPanel.contentView = nil; tasksPanel.close() }
        let (donePanel, doneField) = try hostHeaderSearch(done: true, focused: false)
        defer { donePanel.contentView = nil; donePanel.close() }
        let tasks = try geometry(tasksField), done = try geometry(doneField)
        XCTAssertEqual(done.font, tasks.font)
        XCTAssertEqual(done.size, tasks.size)
        XCTAssertEqual(done.frame, tasks.frame, "text frame")
        XCTAssertEqual(done.baseline, tasks.baseline, "baseline")
        XCTAssertEqual(done.placeholderFont, tasks.font, "placeholder font")
        XCTAssertEqual(done.placeholderSize, tasks.size, "placeholder size")
        XCTAssertNotNil(done.placeholderColor)
    }

    func testDonesHeaderSearchKeepsTheOtherHeaderSearchsCaretAndSelection() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1")
        }
        // As drawn: each colour resolved in the panel's appearance.
        func drawn(_ colour: NSColor?, in panel: NSPanel) -> String? {
            var out: String?
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                out = colour?.usingColorSpace(.sRGB).map {
                    String(format: "%.3f %.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent)
                }
            }
            return out
        }
        func editing(done: Bool) throws -> (colour: String?, selection: String?) {
            let (panel, _) = try hostHeaderSearch(done: done, focused: true)
            defer { panel.makeFirstResponder(nil); panel.contentView = nil; panel.close() }
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "the field has the keyboard")
            return (drawn(editor.insertionPointColor, in: panel),
                    drawn(editor.selectedTextAttributes[.backgroundColor] as? NSColor, in: panel))
        }
        let tasks = try editing(done: false), done = try editing(done: true)
        XCTAssertEqual(done.colour, tasks.colour, "caret")
        XCTAssertEqual(done.selection, tasks.selection, "selection")
    }

    func testNativeQueryEditorIsReleasedWithItsHostedField() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("Requires ATTIC_KEY_WINDOW_TESTS=1")
        }
        weak var editor: NSTextView?
        try autoreleasepool {
            let model = TasksPageModel(library: AtticLibrary(tasks: try makeTestStore()))
            let panel = InputPanel(contentRect: CGRect(x: -4000, y: -4000, width: 344, height: 40),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView:
                TasksDoneSearchField(model: model, input: model.doneSearchInput,
                                     isFocused: .constant(true), onEscape: {})
                    .atticDesign(AtticDesignContext(mode: .light)))
            panel.orderFront(nil)
            panel.makeKey()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            Hosted.pumpEvents()
            editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            panel.makeFirstResponder(nil)
            panel.contentView = nil
            panel.close()
        }
        let deadline = Date().addingTimeInterval(1)
        while editor != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(editor)
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
        let root = ownedTemporaryDirectory(prefix: "AtticDoneSearch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
