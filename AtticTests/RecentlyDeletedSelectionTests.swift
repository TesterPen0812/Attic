import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 follow-up, control audit item 11: selection in Recently Deleted
/// (click, ⌘-click, ⇧-click, ⌘A, ↑ ↓), Restore Selected as one Undo step,
/// Delete Permanently… of exactly the selection after a confirmation, and
/// Empty All… still taking everything.
@MainActor
final class RecentlyDeletedSelectionTests: XCTestCase {
    /// PF-47: the real Settings scroll column must mount a bounded number
    /// of rows when one deleted-item section contains 5,000 entries.
    func testPF47DeletedSectionRealizesOnlyVisibleRows() {
        let entries = (0..<5_000).map { index in
            RecentlyDeletedEntry(kind: .canvas, title: "Canvas \(index)", detail: "Deleted today",
                                 deletedAt: Date(), ownerTitle: nil,
                                 source: .draw(DrawDeletedItem(canvasID: UUID(), objectID: nil)))
        }
        var realized = Set<String>()
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 520, height: 420),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SettingsPage(section: .recentlyDeleted) {
            ScrollViewReader { proxy in
                SettingsGroup(title: "Canvases") {
                    RecentlyDeletedSectionRows(entries: entries) { entry in
                        Text(entry.title)
                            .frame(height: 58)
                            .frame(maxWidth: .infinity)
                            .onAppear { realized.insert(entry.id) }
                    }
                }
                .onAppear {
                    // The keyboard uses the same proxy/ID path to bring an
                    // unrealized last row into the viewport.
                    DispatchQueue.main.async { proxy.scrollTo(entries[entries.count - 1].id) }
                }
            }
        }.atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 420)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(realized.count, 0)
        XCTAssertLessThan(realized.count, 50,
                          "a fixed-height Settings viewport may prefetch, but must not realize all 5,000 rows (mounted \(realized.count))")
        XCTAssertTrue(realized.contains(entries[entries.count - 1].id),
                      "keyboard scrolling must still reach the last logical entry")
    }

    /// PF-46: stale Draw observation callbacks must not multiply work when
    /// Settings is deactivated/reactivated before the next Draw revision.
    func testPF46RepeatedSettingsActivationsDoNotMultiplyDrawReloads() async throws {
        let draw = DrawInMemoryStore()
        let canvas = draw.create(name: "Observed canvas")
        let model = RecentlyDeletedModel(library: nil, draw: { draw })
        for _ in 0..<50 { model.start(); model.stop() }
        model.start()
        defer { model.stop() }

        var reloads = 0
        let subscription = model.$entries.dropFirst().sink { _ in reloads += 1 }
        defer { subscription.cancel() }

        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("first"))]), on: canvas.id).isSaved)
        try await Task.sleep(for: .milliseconds(60)) // Drain posted observation callbacks; measure work, not time.
        XCTAssertEqual(reloads, 1, "one Draw change should reload once after 50 stop/start cycles")

        reloads = 0
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("second"))]), on: canvas.id).isSaved)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reloads, 1, "old callbacks must not rearm into additional observation chains")
    }

    /// PF-49: frequent activation with no expired task/redirect group must
    /// start zero asynchronous ownership scans, independent of live data size.
    func testPF49RepeatedActivationWithoutExpiredFamiliesStartsNoCoordinatedPurges() async throws {
        let fixture = try makeFixture()
        for index in 0..<120 { XCTAssertNotNil(fixture.tasks.create(title: "Live \(index)")) }
        var started = 0
        fixture.library.taskNotePurge = { _, _, _ in started += 1; return [] }
        fixture.library.presentationDefaults = nil

        for _ in 0..<100 {
            _ = fixture.library.purgeExpired(now: fixture.clock.value, calendar: calendar)
        }
        for _ in 0..<150 { await Task.yield() }
        XCTAssertEqual(started, 0, "no expired groups means no speculative coordinated purge work")
    }

    /// One expired family must not materialize the many unrelated live
    /// tasks/notes simply to preserve the family's Undo writing references.
    func testPF49ExpiredFamilyInventoryAvoidsUnrelatedLiveRows() async throws {
        let fixture = try makeFixture()
        fixture.library.presentationDefaults = nil
        let context = ModelContext(fixture.container)
        for index in 0..<120 {
            let live = try XCTUnwrap(fixture.tasks.create(title: "Unrelated \(index)"))
            let note = NoteItem(id: UUID())
            note.taskID = live.id
            context.insert(note)
        }
        try context.save()
        let expired = try XCTUnwrap(fixture.tasks.create(title: "Expired family"))
        XCTAssertTrue(fixture.library.delete(.init(.task, expired.id)))
        let linked = NoteItem(id: UUID())
        linked.taskID = expired.id
        context.insert(linked)
        try context.save()
        fixture.clock.value += 35 * 86_400
        var started = 0
        fixture.library.taskNotePurge = { _, _, _ in started += 1; return [] }

        _ = fixture.library.purgeExpired(now: fixture.clock.value, calendar: calendar)
        for _ in 0..<200 where started == 0 { await Task.yield() }
        XCTAssertEqual(started, 1, "the expired family still enters coordinated purge")
        XCTAssertLessThanOrEqual(fixture.library.lastDeletedGroupWritingInventoryRows, 12,
                                 "120 unrelated live task/note pairs should not be materialized for one expired family")
    }

    /// The fast eligibility probe must ignore independent note deletion,
    /// but recognize a grouped redirect with no expired task row.
    func testPF49CandidateProbeIncludesExpiredRedirectOnlyNoteGroups() throws {
        let fixture = try makeFixture()
        let cutoff = RecentlyDeletedPolicy.purgeCutoff(now: fixture.clock.value, calendar: calendar)
        let context = ModelContext(fixture.container)
        let independent = NoteItem(id: UUID())
        independent.deletedAt = cutoff.addingTimeInterval(-86_400)
        context.insert(independent)
        try context.save()
        XCTAssertFalse(TaskNotePurge.hasExpiredCandidates(in: ModelContext(fixture.container), before: cutoff),
                       "an unrelated deleted note does not need coordinated ownership scans")

        let grouped = NoteItem(id: UUID())
        grouped.deletedAt = cutoff.addingTimeInterval(-86_400)
        grouped.deletionGroupID = UUID()
        context.insert(grouped)
        try context.save()
        XCTAssertTrue(TaskNotePurge.hasExpiredCandidates(in: ModelContext(fixture.container), before: cutoff),
                      "a redirect-note-only group still needs the coordinated purge")
    }

    /// Repeated wake/activation during a suspended coordinated purge must
    /// leave one owner of that work and at most one follow-up cycle.
    func testPF49OverlappingActivationsCoalesceCoordinatedPurge() async throws {
        let fixture = try makeFixture()
        fixture.library.presentationDefaults = nil
        let task = try XCTUnwrap(fixture.tasks.create(title: "Task with writing"))
        XCTAssertTrue(fixture.library.delete(.init(.task, task.id)))
        let context = ModelContext(fixture.container)
        let note = NoteItem(id: UUID())
        note.taskID = task.id
        context.insert(note)
        try context.save()
        fixture.clock.value += 35 * 86_400

        let held = HeldFamilyPurge()
        var started = 0
        var concurrent = 0
        var peak = 0
        fixture.library.taskNotePurge = { _, _, _ in
            started += 1
            concurrent += 1
            peak = max(peak, concurrent)
            defer { concurrent -= 1 }
            if started == 1 { return await held.wait() }
            return []
        }

        _ = fixture.library.purgeExpired(now: fixture.clock.value, calendar: calendar)
        for _ in 0..<200 where held.gate == nil { await Task.yield() }
        let gate = try XCTUnwrap(held.gate, "first coordinated purge must start")
        for _ in 0..<50 { _ = fixture.library.purgeExpired(now: fixture.clock.value, calendar: calendar) }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(started, 1, "activation must not start a second purge while the first waits")
        gate.resume(returning: [])
        for _ in 0..<200 { await Task.yield() }
        XCTAssertLessThanOrEqual(started, 2, "50 overlapping activations need at most one follow-up")
        XCTAssertEqual(peak, 1, "only one coordinated purge may own the same deletion family")
    }

    private final class HeldFamilyPurge {
        var gate: CheckedContinuation<Set<UUID>, Never>?
        func wait() async -> Set<UUID> {
            await withCheckedContinuation { gate = $0 }
        }
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    private struct Fixture {
        let clock: MutableNow
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let canvases: CanvasStore
        let library: AtticLibrary
    }

    private func makeFixture() throws -> Fixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        return Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
    }

    /// Deletes tasks titled `titles`, one second apart (newest last, so
    /// the list shows them in reverse).
    private func deleteTasks(_ titles: [String], in fixture: Fixture) throws -> [UUID] {
        try titles.map { title in
            let task = try XCTUnwrap(fixture.tasks.create(title: title))
            fixture.clock.value += 1
            XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, task.id)))
            return task.id
        }
    }

    private func model(_ fixture: Fixture) -> RecentlyDeletedModel {
        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.reload()
        return model
    }

    private func entry(_ title: String, in model: RecentlyDeletedModel) throws -> RecentlyDeletedEntry {
        try XCTUnwrap(model.entries.first { $0.title == title })
    }

    // MARK: - Selection

    func testClickCommandClickShiftClickAndSelectAll() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C", "D"], in: fixture)
        let model = model(fixture)
        XCTAssertEqual(model.listedEntries.map(\.title), ["D", "C", "B", "A"], "newest first")

        model.click(try entry("C", in: model))
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C"])
        model.click(try entry("A", in: model), command: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C", "A"], "⌘-click adds")
        model.click(try entry("C", in: model), command: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["A"], "⌘-click again removes")
        model.click(try entry("A", in: model))
        model.click(try entry("D", in: model), shift: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["D", "C", "B", "A"], "⇧-click selects the run from the anchor")
        model.click(try entry("B", in: model), shift: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B", "A"], "the anchor stays where the run started")
        model.click(try entry("B", in: model))
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B"], "a plain click selects it alone")

        model.selectAll()
        XCTAssertEqual(model.selection.count, 4)
        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testArrowsMoveAndShiftArrowsGrowTheSelection() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["C"], "↓ with nothing selected starts at the top")
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B"])
        model.moveCursor(by: 1, extending: true)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["B", "A"], "⇧↓ grows it")
        model.moveCursor(by: 1)
        XCTAssertEqual(model.selectedEntries.map(\.title), ["A"], "stays on the last row")
        XCTAssertEqual(model.cursor, try entry("A", in: model).id, "the keyboard's row (kept in view)")
    }

    /// Only listed entries stay selected: a search never hides what a
    /// command would touch.
    func testSearchingDropsWhatItHides() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["Book dentist", "Email testers", "Book flights"], in: fixture)
        let model = model(fixture)
        model.selectAll()
        model.query = "book"
        XCTAssertEqual(Set(model.selectedEntries.map(\.title)), ["Book dentist", "Book flights"])
        XCTAssertEqual(model.selection.count, 2, "the hidden one left the selection")
        model.query = ""
        XCTAssertEqual(model.selection.count, 2, "and does not come back by itself")
    }

    /// A row's commands act on the selection when the row is in it, and
    /// on the row alone otherwise; their titles count.
    func testARowsCommandsTargetTheSelectionOrTheRow() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.click(try entry("A", in: model))
        model.click(try entry("B", in: model), command: true)
        XCTAssertEqual(model.targets(for: try entry("A", in: model)).map(\.title), ["B", "A"])
        XCTAssertEqual(model.targets(for: try entry("C", in: model)).map(\.title), ["C"])
        XCTAssertEqual(RecentlyDeletedPresentation.restoreTitle(count: 2), "Restore 2 Items")
        XCTAssertEqual(RecentlyDeletedPresentation.deleteTitle(count: 2), "Delete 2 Items Permanently…")
        XCTAssertEqual(RecentlyDeletedPresentation.restoreTitle(count: 1), "Restore")
        XCTAssertEqual(RecentlyDeletedPresentation.deleteTitle(count: 1), "Delete Permanently…")
        XCTAssertEqual(RecentlyDeletedPresentation.selectedPhrase(2), "2 selected")
    }

    // MARK: - Restore Selected

    func testDrawOnlyRestoreSelectedIsOneUndoAcrossCanvasesAndDeletedImage() throws {
        let fixture = try makeFixture()
        let draw = DrawInMemoryStore()
        let first = draw.create(name: "First drawing")
        let second = draw.create(name: "Second drawing")
        let imageBoard = draw.create(name: "Image board")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("first"))]), on: first.id).isSaved)
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("second"))]), on: second.id).isSaved)
        let image = DrawObject(content: .image(DrawImage(original: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)))
        XCTAssertTrue(draw.perform(.put([image]), on: imageBoard.id).isSaved)
        XCTAssertTrue(draw.perform(.remove([image.id]), on: imageBoard.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: first.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: second.id).isSaved)

        let model = RecentlyDeletedModel(library: fixture.library, draw: { draw })
        model.reload()
        XCTAssertEqual(model.entries.count, 3)
        model.selectAll()
        model.restoreSelected()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.canUndo, "Draw-only Restore Selected must offer one Undo")

        model.undo()
        XCTAssertEqual(model.entries.count, 3, "one Undo puts both canvases and the image back")
        XCTAssertTrue(try draw.open(first.id).canvas.deletedAt != nil)
        XCTAssertTrue(try draw.open(second.id).canvas.deletedAt != nil)
        XCTAssertEqual(try draw.deletedImages(in: imageBoard.id).map(\.id), [image.id])
        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        model.reload()
        XCTAssertTrue(model.entries.isEmpty, "one Redo restores every Draw item")
    }

    func testMixedDrawAndNoteRestoreUndoRedoAsOneStep() throws {
        let fixture = try makeFixture()
        let draw = DrawInMemoryStore()
        let board = draw.create(name: "Drawing")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("drawing"))]), on: board.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: board.id).isSaved)
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let model = RecentlyDeletedModel(library: fixture.library, draw: { draw })
        model.reload()
        model.selectAll()
        model.restoreSelected()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(fixture.notes.note(withID: note.id))

        model.undo()
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Drawing", "Notes"])
        XCTAssertNil(fixture.notes.note(withID: note.id))
        XCTAssertNotNil(try draw.open(board.id).canvas.deletedAt)
        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        model.reload()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertNil(try draw.open(board.id).canvas.deletedAt)
    }

    func testMixedUndoFinishesAfterDrawFailureIsRetried() throws {
        let fixture = try makeFixture()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var failNextDrawSave = false
        let draw = DrawPersistentStore(container: container, save: { context in
            if failNextDrawSave {
                failNextDrawSave = false
                throw NSError(domain: "Draw undo failure", code: 1)
            }
            try context.save()
        })
        let board = draw.create(name: "Drawing")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("drawing"))]), on: board.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: board.id).isSaved)
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let model = RecentlyDeletedModel(library: fixture.library, draw: { draw })
        model.reload()
        model.selectAll()
        model.restoreSelected()

        failNextDrawSave = true
        model.undo()
        XCTAssertEqual(model.message?.tone, .error)
        XCTAssertTrue(model.canUndo, "the grouped Undo remains retryable")
        XCTAssertNotNil(fixture.notes.note(withID: note.id), "compensate the confirmed library Undo")
        XCTAssertTrue(draw.retry(on: board.id).isSaved, "finish the failed Draw operation")

        model.undo()
        XCTAssertNil(fixture.notes.note(withID: note.id), "finish the same group after Draw settled")
        XCTAssertNotNil(try draw.open(board.id).canvas.deletedAt)
        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertNil(try draw.open(board.id).canvas.deletedAt)
    }

    func testRecentlyDeletedUndoDoesNotUndoALaterDrawEdit() throws {
        let fixture = try makeFixture()
        let draw = DrawInMemoryStore()
        let board = draw.create(name: "Original")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("content"))]), on: board.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: board.id).isSaved)
        let model = RecentlyDeletedModel(library: fixture.library, draw: { draw })
        model.reload()
        model.restore(try XCTUnwrap(model.entries.first))
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(draw.perform(.rename("Later change"), on: board.id).isSaved)

        model.undo()
        XCTAssertNil(try draw.open(board.id).canvas.deletedAt, "Undo must not target a different Draw step")
        XCTAssertEqual(try draw.open(board.id).canvas.name, "Later change")
        XCTAssertTrue(model.canUndo, "the composite step must remain retryable")

        XCTAssertTrue(draw.undo(on: board.id).isSaved)
        model.undo()
        XCTAssertNotNil(try draw.open(board.id).canvas.deletedAt)
    }

    func testMixedRestoreWithOneFailedDrawSaveUndoesOnlyConfirmedRestores() throws {
        let fixture = try makeFixture()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var rejectRestore = false
        var restoresAttempted = 0
        let draw = DrawPersistentStore(container: container, save: { context in
            if rejectRestore {
                restoresAttempted += 1
                if restoresAttempted == 2 { throw NSError(domain: "Draw restore test", code: 1) }
            }
            try context.save()
        })
        let first = draw.create(name: "First")
        let second = draw.create(name: "Second")
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("one"))]), on: first.id).isSaved)
        XCTAssertTrue(draw.perform(.put([DrawObject(content: .text("two"))]), on: second.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: first.id).isSaved)
        XCTAssertTrue(draw.perform(.deleteCanvas, on: second.id).isSaved)
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))

        let model = RecentlyDeletedModel(library: fixture.library, draw: { draw })
        model.reload()
        model.selectAll()
        rejectRestore = true
        model.restoreSelected()
        XCTAssertEqual(model.message?.tone, .error)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(try draw.library(deleted: false).filter { [first.id, second.id].contains($0.id) }.count, 1)
        XCTAssertNotNil(fixture.notes.note(withID: note.id))

        rejectRestore = false
        model.undo()
        XCTAssertNil(fixture.notes.note(withID: note.id))
        XCTAssertEqual(try draw.library(deleted: true).filter { [first.id, second.id].contains($0.id) }.count, 2,
                       "the successful Draw restore goes back; the refused one was never included")
    }

    func testUnrelatedStepNamedRestoreDoesNotEnableRecentlyDeletedUndo() throws {
        let fixture = try makeFixture()
        let model = model(fixture)
        fixture.library.undo.record(UndoStep(name: "Restore Appearance", undo: { true }, redo: { true }), in: .library)
        XCTAssertFalse(model.canUndo, "only a typed restore operation may be reversed on Recently Deleted")
    }

    /// Several kinds at once come back, and one ⌘Z sends them all back.
    func testRestoreSelectedIsOneUndoStep() throws {
        let fixture = try makeFixture()
        let taskIDs = try deleteTasks(["Plan", "Pack"], in: fixture)
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        XCTAssertNotNil(fixture.canvases.createCanvas(name: "Keep"), "the last canvas is never deleted")
        let board = try XCTUnwrap(fixture.canvases.createCanvas(name: "Board"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.canvas, board.id)))
        let untouched = try deleteTasks(["Keep deleted"], in: fixture)
        let model = model(fixture)
        for title in ["Plan", "Pack", "Notes", "Board"] {
            model.click(try entry(title, in: model), command: true)
        }
        XCTAssertEqual(model.selection.count, 4)

        model.restoreSelected()
        XCTAssertNil(model.message)
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) != nil })
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertTrue(fixture.canvases.canvases.contains { $0.id == board.id })
        XCTAssertEqual(model.entries.map(\.title), ["Keep deleted"])
        XCTAssertTrue(model.selection.isEmpty, "what came back left the selection")
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore 4 Items")
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Plan", "Pack", "Notes", "Board", "Keep deleted"], "one ⌘Z sends all four back")
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) == nil })
        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        XCTAssertTrue(taskIDs.allSatisfy { fixture.tasks.task(withID: $0) != nil }, "Redo restores them again")
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, untouched[0])), .deleted)
    }

    /// A subtask deleted on its own and its main task deleted later come
    /// back together; one that can't come back stays listed, with why,
    /// while the rest still return.
    func testRestoreSelectedBringsBackWhatItCanAndSaysWhy() throws {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        let orphanParent = try XCTUnwrap(fixture.tasks.create(title: "Other parent"))
        let orphan = try XCTUnwrap(fixture.tasks.create(title: "Orphan", parentID: orphanParent.id))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, child.id)))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, orphan.id)))
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, parent.id)))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, orphanParent.id)))
        let model = model(fixture)
        for title in ["Parent", "Child", "Orphan"] {
            model.click(try entry(title, in: model), command: true)
        }
        model.restoreSelected()
        XCTAssertNotNil(fixture.tasks.task(withID: parent.id))
        XCTAssertEqual(fixture.tasks.subtasks(of: parent.id).map(\.id), [child.id], "the subtask returns to its main task")
        XCTAssertNil(fixture.tasks.task(withID: orphan.id), "its main task is still deleted")
        XCTAssertEqual(model.message?.tone, .error)
        XCTAssertTrue(model.message?.text.hasPrefix("1 item couldn’t be restored") == true, model.message?.text ?? "")
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Orphan", "Other parent"])
        XCTAssertEqual(model.selectedEntries.map(\.title), ["Orphan"], "what stayed stays selected")
    }

    /// A removed file and a deleted task, selected together, come back
    /// together; one ⌘Z sends both back.
    func testRestoreSelectedTakesFilesAndItemsAsOneStep() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Trip"))
        let reference = TaskImageReference(id: UUID(), filename: "map.png", digest: "abc", contentTypeIdentifier: "public.png", byteCount: 3)
        task.imageReferencesData = try JSONEncoder().encode([reference])
        XCTAssertTrue(fixture.tasks.removeAttachment(reference.id, from: task.id))
        let old = try deleteTasks(["Old"], in: fixture)
        let model = model(fixture)
        XCTAssertEqual(Set(model.entries.map(\.kind)), [.task, .attachment])
        model.selectAll()
        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertEqual(fixture.tasks.task(withID: task.id)?.attachments.map(\.id), [reference.id])
        XCTAssertNotNil(fixture.tasks.task(withID: old[0]))
        XCTAssertTrue(model.entries.isEmpty)
        model.undo()
        XCTAssertEqual(Set(model.entries.map(\.kind)), [.task, .attachment], "one ⌘Z undoes both")
        XCTAssertTrue(fixture.tasks.task(withID: task.id)?.attachments.isEmpty == true)
    }

    // MARK: - Delete Permanently…

    /// Only the selection goes, only after the confirmation; Cancel keeps
    /// everything; Empty All… still counts everything, searched for or not.
    func testDeletePermanentlyRemovesExactlyTheSelectionAfterConfirming() throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A", "B", "C"], in: fixture)
        let model = model(fixture)
        model.click(try entry("A", in: model))
        model.click(try entry("C", in: model), command: true)

        model.requestDeleteSelected()
        var request = try XCTUnwrap(model.emptyRequest)
        XCTAssertEqual(request.scope, .selected)
        XCTAssertEqual(request.count, 2)
        XCTAssertEqual(request.title, "Delete 2 Items Permanently?")
        XCTAssertEqual(request.confirmTitle, "Delete Permanently")
        XCTAssertEqual(request.confirmationText, "2 items will be removed for good. You can’t undo this.")
        model.cancelEmpty()
        XCTAssertEqual(model.entries.count, 3, "Cancel removes nothing")

        model.requestDeleteSelected()
        model.confirmEmpty()
        XCTAssertEqual(model.entries.map(\.title), ["B"])
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[0])), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[2])), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ids[1])), .deleted)

        // Empty All… takes what a search hides too, and says so.
        _ = try deleteTasks(["D"], in: fixture)
        model.reload()
        model.query = "D"
        model.requestEmpty()
        request = try XCTUnwrap(model.emptyRequest)
        XCTAssertEqual(request.scope, .all)
        XCTAssertEqual(request.count, 2, "everything here, not only what the search shows")
        XCTAssertEqual(request.title, "Empty Recently Deleted?")
        model.cancelEmpty()
    }

    /// With nothing selected there is nothing to confirm.
    func testNothingSelectedAsksNothing() throws {
        let fixture = try makeFixture()
        _ = try deleteTasks(["A"], in: fixture)
        let model = model(fixture)
        model.requestDeleteSelected()
        XCTAssertNil(model.emptyRequest)
        model.restoreSelected()
        XCTAssertEqual(model.entries.count, 1)
    }

    func testFix18LateFamilyPurgeDoesNotEraseNewerRestoreError() async throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A", "B"], in: fixture)
        fixture.library.presentationDefaults = nil
        let held = HeldFamilyPurge()
        fixture.library.taskNotePurge = { _, _, _ in await held.wait() }
        let model = model(fixture)
        let removed = try entry("A", in: model)
        model.requestDelete([removed])
        model.confirmEmpty()
        for _ in 0..<200 where held.gate == nil { await Task.yield() }
        let gate = try XCTUnwrap(held.gate)

        model.restore(removed) // Its deletion has been purged, so this is a newer error.
        let feedback = try XCTUnwrap(model.message)
        XCTAssertEqual(feedback.tone, .error)
        gate.resume(returning: [ids[0]])
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(model.message?.text, feedback.text,
            "the older purge completion must not erase newer feedback")
        XCTAssertEqual(model.message?.tone, .error)
    }

    /// E-4: the cue is a result of completed work, including asynchronous
    /// task/note-family cleanup, never a confirmation-button sound.
    func testE4EmptiedCueWaitsForCoordinatedPurgeAndPlaysOnce() async throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A"], in: fixture)
        fixture.library.presentationDefaults = nil
        let held = HeldFamilyPurge()
        fixture.library.taskNotePurge = { _, _, _ in await held.wait() }
        let model = model(fixture)

        var cues: [AtticSounds.Cue] = []
        let sounds = AtticSounds.shared
        sounds.lastPlayed = -.infinity
        sounds.settingEnabled = { true }
        sounds.systemAllows = { true }
        sounds.clock = { 20_000 }
        sounds.output = { cues.append($0) }
        defer {
            sounds.settingEnabled = nil
            sounds.output = nil
            sounds.systemAllows = { true }
            sounds.clock = { ProcessInfo.processInfo.systemUptime }
            sounds.lastPlayed = -.infinity
        }

        model.requestEmpty()
        model.confirmEmpty()
        for _ in 0..<200 where held.gate == nil { await Task.yield() }
        let gate = try XCTUnwrap(held.gate)
        XCTAssertTrue(cues.isEmpty, "nothing sounds while coordinated deletion is pending")
        gate.resume(returning: [ids[0]])
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(cues, [.emptied], "one sound after the coordinated purge finishes")
    }

    /// The page's keys and its Undo name: ⌘R restores, ⌘⌫ asks.
    func testKeys() {
        XCTAssertEqual(RecentlyDeletedKeys.restore, KeyboardShortcut("r", modifiers: .command))
        XCTAssertEqual(RecentlyDeletedKeys.delete, KeyboardShortcut(.delete, modifiers: .command))
        XCTAssertEqual(RecentlyDeletedKeys.selectAll, KeyboardShortcut("a", modifiers: .command))
    }

    /// Agents restore several as one step too (restore_items); nothing
    /// is restored when one of them is not in Recently Deleted.
    func testTheAgentToolRestoresSeveralAsOneStep() throws {
        let fixture = try makeFixture()
        let ids = try deleteTasks(["A", "B"], in: fixture)
        let live = try XCTUnwrap(fixture.tasks.create(title: "Live"))
        let tools = AgentTaskTools(store: fixture.tasks, library: fixture.library)
        let items: [[String: Any]] = ids.map { ["kind": "task", "id": $0.uuidString] }
        XCTAssertThrowsError(try tools.call(name: "restore_items", arguments: ["items": items + [["kind": "task", "id": live.id.uuidString]]]))
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) == nil }, "nothing restored")
        _ = try tools.call(name: "restore_items", arguments: ["items": items])
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) != nil })
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertTrue(ids.allSatisfy { fixture.tasks.task(withID: $0) == nil }, "one Undo")
    }

    // MARK: - Fix round: Undo of Restore Selected reaches the Done log (finding 4)

    /// A task the daily cleanup moved to the Done log, deleted, and restored
    /// comes back to the log (not the list); Undo sends it back to Recently
    /// Deleted with the ordinary task restored beside it.
    func testRestoreSelectedUndoSendsArchivedTasksBackToo() throws {
        let fixture = try makeFixture()
        let archived = try archivedTask("Archived", in: fixture)
        XCTAssertTrue(fixture.library.deleteListedTasks([archived]).isApplied)
        let ordinary = try deleteTasks(["Ordinary"], in: fixture)
        let model = model(fixture)
        model.selectAll()

        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived), "back in the Done log")
        XCTAssertNil(fixture.tasks.task(withID: archived))
        XCTAssertNotNil(fixture.tasks.task(withID: ordinary[0]))

        model.undo()
        XCTAssertNil(fixture.tasks.listedTask(withID: archived), "one Undo sends the archived task back too")
        XCTAssertNil(fixture.tasks.task(withID: ordinary[0]))
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, archived)), .deleted)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, ordinary[0])), .deleted)
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Archived", "Ordinary"])

        XCTAssertTrue(fixture.library.undo.redo(in: .library))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived), "Redo restores it to the log again")
        XCTAssertNotNil(fixture.tasks.task(withID: ordinary[0]))
    }

    /// An archived main task and its separately deleted archived subtask come
    /// back together, and Undo sends them back as two entries again, subtask
    /// first so the main task's delete does not take it along.
    func testRestoreSelectedUndoKeepsArchivedFamiliesApart() throws {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(fixture.library.deleteListedTasks([child.id]).isApplied)
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.deleteListedTasks([parent.id]).isApplied)
        let model = model(fixture)
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Parent", "Child"])
        model.selectAll()

        model.restoreSelected()
        XCTAssertNil(model.message, model.message?.text ?? "")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))

        model.undo()
        XCTAssertNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNil(fixture.tasks.listedTask(withID: child.id))
        XCTAssertEqual(Set(model.entries.map(\.title)), ["Parent", "Child"], "two entries again")
    }

    /// Restoring one archived task on its own undoes the same way.
    func testRestoreUndoOfASingleArchivedTaskSendsItBack() throws {
        let fixture = try makeFixture()
        let archived = try archivedTask("Archived", in: fixture)
        XCTAssertTrue(fixture.library.deleteListedTasks([archived]).isApplied)
        XCTAssertTrue(fixture.library.restore(AtticItemRef(.task, archived)))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: archived))
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertNil(fixture.tasks.listedTask(withID: archived))
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, archived)), .deleted)
    }

    private func archivedTask(_ title: String, in fixture: Fixture) throws -> UUID {
        let task = try XCTUnwrap(fixture.tasks.create(title: title))
        XCTAssertTrue(fixture.tasks.markDone(task))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 1)
        XCTAssertNil(fixture.tasks.task(withID: task.id))
        return task.id
    }

    // MARK: - Fix round: partial failures inside one bulk step (finding 5)

    private struct GatedFixture {
        let fixture: Fixture
        let gate: PersistenceGate
        let taskID: UUID
        let noteID: UUID
    }

    /// A deleted task and a deleted note, where the note store's saves can
    /// be made to fail.
    private func makeGatedFixture() throws -> GatedFixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let fixture = Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
        let taskID = try deleteTasks(["Plan"], in: fixture)[0]
        let note = try XCTUnwrap(notes.create(title: "Notes"))
        XCTAssertTrue(library.delete(AtticItemRef(.note, note.id)))
        return GatedFixture(fixture: fixture, gate: gate, taskID: taskID, noteID: note.id)
    }

    /// Redo that brings back only part of the step reports the failure and
    /// stays on the Redo list; the retry restores just what is still deleted.
    func testRedoAfterAPartialFailureFailsAndRetriesOnlyTheRest() throws {
        let gated = try makeGatedFixture()
        let fixture = gated.fixture
        let taskRef = AtticItemRef(.task, gated.taskID)
        let noteRef = AtticItemRef(.note, gated.noteID)
        let report = fixture.library.restoreRecentlyDeleted(items: [taskRef, noteRef], attachments: [])
        XCTAssertEqual(report.restored, 2)
        XCTAssertTrue(fixture.library.undo.undo(in: .library))
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted)

        gated.gate.shouldFail = true
        XCTAssertEqual(fixture.library.undo.redoStep(in: .library), .failed, "part of it did not come back")
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID), "the task did")
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted, "the note did not")
        XCTAssertNotNil(fixture.library.lastErrorMessage, "the failure is reported")
        XCTAssertTrue(fixture.library.undo.canRedo(in: .library), "the step stays for a retry")

        gated.gate.shouldFail = false
        XCTAssertEqual(fixture.library.undo.redoStep(in: .library), .applied)
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID))
        XCTAssertEqual(fixture.library.state(of: noteRef), .live)
        XCTAssertFalse(fixture.library.undo.canRedo(in: .library))

        XCTAssertTrue(fixture.library.undo.undo(in: .library), "Undo sends both back again")
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted)
    }

    /// Undo that sends back only part of the step fails and keeps the step;
    /// the retry touches only what it has not sent back yet, so an item the
    /// person restored in the meantime stays restored.
    func testUndoAfterAPartialFailureRetriesOnlyTheRest() throws {
        let gated = try makeGatedFixture()
        let fixture = gated.fixture
        let taskRef = AtticItemRef(.task, gated.taskID)
        let noteRef = AtticItemRef(.note, gated.noteID)
        XCTAssertEqual(fixture.library.restoreRecentlyDeleted(items: [taskRef, noteRef], attachments: []).restored, 2)

        gated.gate.shouldFail = true
        XCTAssertEqual(fixture.library.undo.undoStep(in: .library), .failed)
        XCTAssertEqual(fixture.library.state(of: taskRef), .deleted, "the task went back")
        XCTAssertEqual(fixture.library.state(of: noteRef), .live, "the note did not")
        XCTAssertNotNil(fixture.library.lastErrorMessage)
        XCTAssertTrue(fixture.library.undo.canUndo(in: .library), "the step stays for a retry")

        // The person brings the task back by itself before retrying.
        XCTAssertTrue(fixture.library.restore(AtticItemRef(.task, gated.taskID), in: .tasks))
        gated.gate.shouldFail = false
        XCTAssertEqual(fixture.library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(fixture.library.state(of: noteRef), .deleted, "the retry sent the note back")
        XCTAssertNotNil(fixture.tasks.task(withID: gated.taskID), "and left the task the person restored")
    }
    // MARK: - Fix round: repeated items

    /// The same item listed twice is restored once and is not a failure.
    func testRestoreItemsIgnoresRepeatedItems() throws {
        let fixture = try makeFixture()
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let taskIDs = try deleteTasks(["A"], in: fixture)
        let noteItem: [String: Any] = ["kind": "note", "id": note.id.uuidString]
        let taskItem: [String: Any] = ["kind": "task", "id": taskIDs[0].uuidString]
        let tools = AgentTaskTools(store: fixture.tasks, library: fixture.library)

        let reply = try tools.call(name: "restore_items", arguments: ["items": [noteItem, taskItem, noteItem, taskItem]])
        XCTAssertFalse(reply.contains("\"reason\""), reply)
        XCTAssertNotNil(fixture.notes.note(withID: note.id))
        XCTAssertNotNil(fixture.tasks.task(withID: taskIDs[0]))
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore 2 Items")
    }

    /// The library ignores repeats too, whoever calls it.
    func testRestoreRecentlyDeletedIgnoresRepeatedItems() throws {
        let fixture = try makeFixture()
        let note = try XCTUnwrap(fixture.notes.create(title: "Notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))
        let ref = AtticItemRef(.note, note.id)
        let report = fixture.library.restoreRecentlyDeleted(items: [ref, ref], attachments: [])
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
    }

    // MARK: - Fix round: keyboard focus on the list

    /// Tab reaching the list draws its ring before any arrow key; a click,
    /// an empty list or another focus draws none.
    @MainActor
    func testTheListShowsAFocusRingWhenTabReachesIt() {
        let tracker = AtticKeyboardFocusTracker()
        XCTAssertFalse(tracker.isKeyboardDriving)
        let ring = { RecentlyDeletedSettingsView.showsListFocusRing(listFocused: true, keyboardDriving: tracker.isKeyboardDriving, hasRows: true) }
        XCTAssertFalse(ring(), "a click gave it the keyboard: no ring")
        tracker.observe(.keyDown, keyCode: 48)
        XCTAssertTrue(ring(), "Tab reached it: the ring shows before the first arrow")
        tracker.observe(.leftMouseDown, keyCode: nil)
        XCTAssertFalse(ring(), "a click hides it again")
        XCTAssertFalse(RecentlyDeletedSettingsView.showsListFocusRing(listFocused: false, keyboardDriving: true, hasRows: true))
        XCTAssertFalse(RecentlyDeletedSettingsView.showsListFocusRing(listFocused: true, keyboardDriving: true, hasRows: false))
    }

    // MARK: - Fix round 2: a parent's delete and the subtasks the step tracks

    /// Fails the saves it is told to, in order, and lets the rest through.
    private final class SaveScript {
        /// `false` fails that save; an empty list lets every save through.
        var results: [Bool] = []

        func save(_ context: ModelContext) throws {
            // 2026-10-23: grouped deletes journal receipt publication too.
            // This script targets model commits, not receipt bookkeeping.
            let models = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
            if models.contains(where: { $0 is TaskItem || $0 is NoteItem }),
               !results.isEmpty, !results.removeFirst() { throw PersistenceGate.Failure() }
            try context.save()
        }
    }

    private struct FamilyFixture {
        let fixture: Fixture
        let script: SaveScript
        let parent: AtticItemRef
        let child: AtticItemRef
    }

    /// A main task and its subtask, deleted separately (the subtask first),
    /// then restored together as one Restore Selected step.
    private func makeRestoredFamily() throws -> FamilyFixture {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000_000))
        let container = try PersistenceController.makeContainer(inMemory: true)
        let script = SaveScript()
        let tasks = TaskStore(container: container, now: { clock.value }, persist: { try script.save($0) })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let fixture = Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
        let parent = try XCTUnwrap(tasks.create(title: "Parent"))
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: parent.id))
        let parentRef = AtticItemRef(.task, parent.id)
        let childRef = AtticItemRef(.task, child.id)
        clock.value += 1
        XCTAssertTrue(library.delete(childRef))
        clock.value += 1
        XCTAssertTrue(library.delete(parentRef))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [childRef, parentRef], attachments: []).restored, 2)
        XCTAssertNotNil(tasks.task(withID: child.id))
        XCTAssertNotNil(tasks.task(withID: parent.id))
        return FamilyFixture(fixture: fixture, script: script, parent: parentRef, child: childRef)
    }

    /// The recheck's reproducer. Undo sends the subtask back, then its main
    /// task's save fails. The person restores the subtask on its own. The
    /// retry must not delete the main task, because that would take the
    /// subtask along and reverse the person's restore.
    func testUndoRetryDoesNotDeleteAParentPastASubtaskRestoredInTheMeantime() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library

        family.script.results = [true, false]
        XCTAssertEqual(library.undo.undoStep(in: .library), .failed, "the main task did not go back")
        XCTAssertEqual(library.state(of: family.child), .deleted, "the subtask did")
        XCTAssertEqual(library.state(of: family.parent), .live)

        family.script.results = []
        XCTAssertTrue(library.restore(family.child, in: .tasks), "the person restores the subtask")
        XCTAssertEqual(library.state(of: family.child), .live)

        _ = library.undo.undoStep(in: .library)
        XCTAssertEqual(library.state(of: family.child), .live, "the retry left what the person restored")
        XCTAssertEqual(library.state(of: family.parent), .live, "and kept its main task with it")
    }

    /// The same after a partial Redo: the subtask did not come back with the
    /// step, the person restored it, and Redo let go of it. Undo then reaches
    /// the main task alone and must not take that subtask with it.
    func testUndoDoesNotDeleteAParentPastASubtaskThatRedoLetGoOf() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .deleted)

        // Redo's batch save fails; then the main task comes back on its own
        // and the subtask's save fails.
        family.script.results = [false, true, false]
        XCTAssertEqual(library.undo.redoStep(in: .library), .failed)
        XCTAssertEqual(library.state(of: family.parent), .live, "the main task came back")
        XCTAssertEqual(library.state(of: family.child), .deleted, "the subtask did not")

        family.script.results = []
        XCTAssertTrue(library.restore(family.child, in: .tasks), "the person restores the subtask")
        XCTAssertEqual(library.undo.redoStep(in: .library), .applied, "the retry lets go of the subtask")

        XCTAssertEqual(library.undo.undoStep(in: .library), .obsolete, "nothing is left that the step may send back")
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.parent), .live)
    }

    /// A subtask that would not go back keeps its main task from going back
    /// in the same pass; the retry sends both.
    func testUndoDoesNotDeleteAParentPastASubtaskThatFailedInTheSamePass() throws {
        let family = try makeRestoredFamily()
        let library = family.fixture.library

        family.script.results = [false]
        XCTAssertEqual(library.undo.undoStep(in: .library), .failed)
        XCTAssertEqual(library.state(of: family.child), .live, "the subtask stayed")
        XCTAssertEqual(library.state(of: family.parent), .live, "so its main task stayed with it")
        XCTAssertTrue(library.undo.canUndo(in: .library), "the step stays for a retry")

        family.script.results = []
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .deleted)
    }

    /// The same removed file listed twice comes back once, without a failure
    /// for the second copy of it.
    func testRestoreRecentlyDeletedIgnoresRepeatedAttachments() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Trip"))
        let reference = TaskImageReference(id: UUID(), filename: "map.png", digest: "abc", contentTypeIdentifier: "public.png", byteCount: 3)
        task.imageReferencesData = try JSONEncoder().encode([reference])
        XCTAssertTrue(fixture.tasks.removeAttachment(reference.id, from: task.id))
        let summary = try XCTUnwrap(fixture.library.recentlyDeletedAttachments().first)

        let report = fixture.library.restoreRecentlyDeleted(items: [], attachments: [summary, summary])
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertEqual(fixture.tasks.task(withID: task.id)?.attachments.map(\.id), [reference.id])
        XCTAssertEqual(fixture.library.undo.undoName(in: .library), "Restore Item")
    }

    // MARK: - Fix round 3: a family delete only takes what its step owns

    /// A main task with two subtasks and a note, nothing deleted yet.
    private struct OwnershipFixture {
        let fixture: Fixture
        let parent: AtticItemRef
        let child: AtticItemRef
        let sibling: AtticItemRef
        let note: AtticItemRef
    }

    private func makeOwnershipFixture() throws -> OwnershipFixture {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        let sibling = try XCTUnwrap(fixture.tasks.create(title: "Sibling", parentID: parent.id))
        let note = try XCTUnwrap(fixture.notes.create(title: "Note"))
        return OwnershipFixture(
            fixture: fixture,
            parent: AtticItemRef(.task, parent.id),
            child: AtticItemRef(.task, child.id),
            sibling: AtticItemRef(.task, sibling.id),
            note: AtticItemRef(.note, note.id)
        )
    }

    /// Deletes the subtask, then its main task (with the other subtask), each
    /// as its own step in Tasks.
    private func deleteChildThenParent(_ family: OwnershipFixture) {
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.child))
        family.fixture.clock.value += 1
        XCTAssertTrue(library.delete(family.parent))
        family.fixture.clock.value += 1
    }

    /// The recheck's single-item reproducer. Delete C, then P (Tasks).
    /// Restore only P through Recently Deleted. Undo in Tasks skips P's
    /// obsolete Delete and brings C back (af29d060). Undo P's Restore: it
    /// must not delete P and so C, whose restore it never made.
    func testUndoOfASingleRestoreKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.restore(family.parent, in: .library))
        XCTAssertEqual(library.state(of: family.child), .deleted, "the child was deleted on its own")

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "skip the already-live P and bring C back in one command")
        XCTAssertNil(library.undo.undoStep(in: .tasks), "both Delete steps were consumed")
        XCTAssertEqual(library.state(of: family.child), .live)

        XCTAssertEqual(library.undo.undoStep(in: .library), .obsolete, "the restore no longer reaches P")
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live, "C's restore was not undone")
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// The bulk variant: P is restored together with an unrelated note, so C
    /// is not tracked by the step at all.
    func testUndoOfABulkRestoreKeepsAChildItDidNotTrack() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertNil(library.undo.undoStep(in: .tasks), "af29d060: the same command skipped P's obsolete Delete")
        XCTAssertEqual(library.state(of: family.child), .live)

        XCTAssertEqual(library.undo.undoStep(in: .library), .applied, "the note still goes back")
        XCTAssertEqual(library.state(of: family.note), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .live, "P stays")
        XCTAssertEqual(library.state(of: family.child), .live, "and so does C")
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Ordinary single restore: Undo takes the whole family back, Redo brings
    /// it again, and Undo still takes the whole family (the ownership carries
    /// through Redo).
    func testOrdinarySingleRestoreUndoRedoUndoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.restore(family.parent, in: .library))
        let refs = [family.parent, family.child, family.sibling]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
        }
    }

    /// Ordinary bulk restore, through Undo, Redo and Undo again.
    func testOrdinaryBulkRestoreUndoRedoUndoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)
        let refs = [family.parent, family.child, family.sibling, family.note]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live, .live])
        }
    }

    /// Redo of a bulk restore owns what that restore brought back this time,
    /// not what the first one did. A subtask deleted on its own before the
    /// Undo is not part of the Redo, so restoring it through another history
    /// afterwards is not something a later Undo may reverse.
    func testRedoOfABulkRestoreOwnsWhatItRestoredThisTime() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)
        XCTAssertTrue(library.delete(family.child), "the subtask goes on its own")
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.child), .deleted, "Redo did not bring it back")
        XCTAssertTrue(library.restore(family.child, in: .tasks))

        XCTAssertEqual(library.undo.undoStep(in: .library), .applied, "the note goes back")
        XCTAssertEqual(library.state(of: family.note), .deleted)
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Redo of a Delete takes the family it took, and no more: a subtask
    /// restored through Recently Deleted while the Delete was undone stays.
    func testRedoOfADeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "P comes back; C was deleted on its own")
        XCTAssertEqual(library.state(of: family.child), .deleted)
        XCTAssertTrue(library.restore(family.child, in: .library))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete, "Redo no longer reaches P")
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: family.sibling), .live)
    }

    /// Ordinary Delete: Undo, Redo, Undo, Redo each move the whole family.
    func testOrdinaryDeleteUndoRedoMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        XCTAssertTrue(library.delete(family.parent))
        let refs = [family.parent, family.child, family.sibling]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
        }
    }

    /// Redo of a multi-selection Delete keeps a subtask restored meanwhile.
    func testRedoOfABulkDeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        let other = try XCTUnwrap(family.fixture.tasks.create(title: "Other"))
        XCTAssertTrue(library.delete(family.child))
        family.fixture.clock.value += 1
        XCTAssertTrue(library.deleteTasks([family.parent.id, other.id]).isApplied)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertTrue(library.restore(family.child, in: .library))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete)
        XCTAssertEqual(library.state(of: family.parent), .live)
        XCTAssertEqual(library.state(of: family.child), .live)
        XCTAssertEqual(library.state(of: AtticItemRef(.task, other.id)), .live)
    }

    /// Ordinary multi-selection Delete, through Undo and Redo.
    func testOrdinaryBulkDeleteUndoRedoMovesEveryFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        let other = try XCTUnwrap(family.fixture.tasks.create(title: "Other"))
        let otherRef = AtticItemRef(.task, other.id)
        XCTAssertTrue(library.deleteTasks([family.parent.id, other.id]).isApplied)
        let refs = [family.parent, family.child, family.sibling, otherRef]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted, .deleted])
        }
    }

    /// Undo of Add Task keeps a subtask that came back under it through
    /// Recently Deleted after its own Add was undone.
    func testUndoOfAddTaskKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(library.createTasks([TaskDraft(title: "Parent")])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: parent.id)])?.first)
        let parentRef = AtticItemRef(.task, parent.id)
        let childRef = AtticItemRef(.task, child.id)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "Add Child")
        XCTAssertTrue(library.restore(childRef, in: .library))

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "Add Parent no longer reaches P")
        XCTAssertEqual(library.state(of: parentRef), .live)
        XCTAssertEqual(library.state(of: childRef), .live)
    }

    /// Ordinary Add Task with a subtask: Undo, Redo, Undo in order.
    func testOrdinaryAddTaskUndoRedoMovesTheWholeFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(library.createTasks([TaskDraft(title: "Parent")])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: parent.id)])?.first)
        let refs = [AtticItemRef(.task, parent.id), AtticItemRef(.task, child.id)]
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live])
        }
    }

    // MARK: - Fix round 4: every history closure deletes through the guard

    /// The recheck's Duplicate reproducer. Duplicate a task without
    /// subtasks (P), add C under P, Undo Add C, restore C through Recently
    /// Deleted, Undo Duplicate: it must not take C.
    func testUndoOfDuplicateKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let source = try XCTUnwrap(fixture.tasks.create(title: "Source"))
        let copy = try XCTUnwrap(library.duplicateTasks([source.id])?.first)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", parentID: copy.id)])?.first)
        let copyRef = AtticItemRef(.task, copy.id)
        let childRef = AtticItemRef(.task, child.id)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "Add Child")
        XCTAssertTrue(library.restore(childRef, in: .library))

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "Duplicate no longer reaches the copy")
        XCTAssertEqual(library.state(of: copyRef), .live)
        XCTAssertEqual(library.state(of: childRef), .live, "C's restore was not undone")
        XCTAssertEqual(library.state(of: AtticItemRef(.task, source.id)), .live)
    }

    /// A duplicate that carries copied subtasks still undoes whole: the copies
    /// are the step's own.
    func testOrdinaryDuplicateWithSubtasksUndoRedoMovesTheWholeFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let source = try XCTUnwrap(fixture.tasks.create(title: "Source"))
        _ = try XCTUnwrap(fixture.tasks.create(title: "One", parentID: source.id))
        _ = try XCTUnwrap(fixture.tasks.create(title: "Two", parentID: source.id))
        let copy = try XCTUnwrap(library.duplicateTasks([source.id])?.first)
        let copyChildren = try fixture.tasks.subtasks(of: copy.id).map(\.id)
        XCTAssertEqual(copyChildren.count, 2)
        let refs = ([copy.id] + copyChildren).map { AtticItemRef(.task, $0) }
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
        }
        XCTAssertEqual(library.state(of: AtticItemRef(.task, source.id)), .live)
    }

    /// The recheck's Done-delete reproducer. P and C are in the Done log;
    /// delete C, then P. Undo P's Delete (C stays deleted), restore C through
    /// Recently Deleted, Redo P's Delete: it must not take C.
    func testRedoOfADoneDeleteKeepsAChildRestoredThroughAnotherHistory() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(library.deleteListedTasks([child.id]).isApplied)
        fixture.clock.value += 1
        XCTAssertTrue(library.deleteListedTasks([parent.id]).isApplied)
        fixture.clock.value += 1

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "P's Delete")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNil(fixture.tasks.listedTask(withID: child.id), "C was deleted on its own")
        XCTAssertTrue(library.restore(AtticItemRef(.task, child.id), in: .library))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))

        XCTAssertEqual(library.undo.redoStep(in: .tasks), .obsolete, "the Delete no longer reaches P")
        XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
        XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id), "C's restore was not undone")
    }

    /// Ordinary Done delete of an archived family: Undo, Redo, Undo.
    func testOrdinaryDoneDeleteUndoRedoMovesTheWholeArchivedFamily() throws {
        let fixture = try makeFixture()
        let library = fixture.library
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        XCTAssertTrue(fixture.tasks.markDone(child))
        XCTAssertTrue(fixture.tasks.markDone(parent))
        fixture.clock.value += 1
        XCTAssertEqual(fixture.tasks.moveCompletedToDoneLog(before: fixture.clock.value + 10), 2)
        XCTAssertTrue(library.deleteListedTasks([parent.id]).isApplied)
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertNotNil(fixture.tasks.listedTask(withID: parent.id))
            XCTAssertNotNil(fixture.tasks.listedTask(withID: child.id))
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertNil(fixture.tasks.listedTask(withID: parent.id))
            XCTAssertNil(fixture.tasks.listedTask(withID: child.id))
        }
    }

    // MARK: - Fix round 5: every history closure restores through the guard

    /// The recheck's 5-step reproducer. Delete C, then P (Tasks). Restore P
    /// through Recently Deleted (the step owns P and its other subtask, not
    /// C) and Undo that restore. In Tasks, Undo P's Delete, then C's Delete:
    /// all live. Delete P again: its new record now holds C. Redo the
    /// Restore: it would bring C back too, and C's delete was not its own.
    func testRedoOfASingleRestoreDoesNotRestoreAChildDeletedByAnotherStep() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.restore(family.parent, in: .library))
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        // Undo may adopt a newer group wholly inside this step's ownership.
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "P was deleted again by Undo Restore")
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied, "C's Delete")
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.live, .live, .live])
        XCTAssertTrue(library.delete(family.parent))
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted, .deleted])

        XCTAssertEqual(library.undo.redoStep(in: .library), .obsolete, "the restore no longer reaches this delete")
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted, .deleted],
                       "nothing was restored")
    }

    /// The same sequence through Restore Selected (one step, several items).
    /// The note in the step still comes back; the main task is let go of.
    func testRedoOfARestoreSelectedDoesNotRestoreAChildDeletedByAnotherStep() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.delete(family.note))
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent, family.note], attachments: []).restored, 2)
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        XCTAssertEqual(library.state(of: family.note), .deleted)
        // Undo may adopt a newer group wholly inside this step's ownership.
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertTrue(library.delete(family.parent))

        XCTAssertEqual(library.undo.redoStep(in: .library), .applied, "the note comes back")
        XCTAssertEqual(library.state(of: family.note), .live)
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied, "Undo still reaches what did come back")
        XCTAssertEqual(library.state(of: family.note), .deleted)
    }

    /// A Restore Selected of the main task alone: nothing is left for Redo.
    func testRedoOfARestoreSelectedOfOneTaskIsObsoleteWhenItsRecordGrew() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent], attachments: []).restored, 1)
        XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
        // Undo may adopt a newer group wholly inside this step's ownership.
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertTrue(library.delete(family.parent))

        XCTAssertEqual(library.undo.redoStep(in: .library), .obsolete)
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
    }

    /// The delete side of the same hole: Undo of P's Delete in Tasks, after P
    /// was restored and deleted again by another history with C in its record.
    func testUndoOfADeleteDoesNotRestoreAChildDeletedByAnotherStep() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertTrue(library.restore(family.parent, in: .library))
        XCTAssertTrue(library.restore(family.child, in: .library))
        XCTAssertTrue(library.delete(family.parent, in: .library))

        XCTAssertEqual(library.undo.undoStep(in: .tasks), .obsolete, "P's Delete no longer reaches this record")
        XCTAssertEqual([family.parent, family.child, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
    }

    /// Delete Tasks, Add Tasks and Duplicate reach their Undo and Redo
    /// restores through the same check; an ordinary family goes back and
    /// forth whole, more than once.
    func testOrdinaryFamilyCyclesRestoreWholeThroughEveryPath() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        let refs = [family.parent, family.child, family.sibling]

        // delete(ref) / restore(ref): Tasks Undo restores, Library Redo/Undo cycle.
        XCTAssertTrue(library.delete(family.parent))
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
        }
        XCTAssertTrue(library.restore(family.parent, in: .library))
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
        }

        // deleteTasks: Undo restores through the guard, Redo deletes.
        XCTAssertTrue(library.deleteTasks([family.parent.id]).isApplied)
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.live, .live, .live])
            XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
            XCTAssertEqual(refs.map { library.state(of: $0) }, [.deleted, .deleted, .deleted])
        }
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)

        // createTasks with a subtask: Undo deletes the pair, Redo restores it.
        let parentDraft = TaskDraft(title: "New")
        let created = try XCTUnwrap(library.createTasks([parentDraft])?.first)
        let createdChild = try XCTUnwrap(library.createTasks([TaskDraft(title: "New child", parentID: created.id)])?.first)
        let pair = [AtticItemRef(.task, created.id), AtticItemRef(.task, createdChild.id)]
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(library.undo.undoStep(in: .tasks), .applied)
        XCTAssertEqual(pair.map { library.state(of: $0) }, [.deleted, .deleted])
        XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
        XCTAssertEqual(library.undo.redoStep(in: .tasks), .applied)
        XCTAssertEqual(pair.map { library.state(of: $0) }, [.live, .live])
    }

    /// Restore Selected of a family Undoes and Redoes whole, more than once,
    /// with a subtask that was deleted on its own left where it is.
    func testOrdinaryBulkRestoreCycleMovesTheWholeFamily() throws {
        let family = try makeOwnershipFixture()
        let library = family.fixture.library
        deleteChildThenParent(family)
        XCTAssertEqual(library.restoreRecentlyDeleted(items: [family.parent], attachments: []).restored, 1)
        for _ in 0..<2 {
            XCTAssertEqual(library.undo.undoStep(in: .library), .applied)
            XCTAssertEqual([family.parent, family.sibling].map { library.state(of: $0) }, [.deleted, .deleted])
            XCTAssertEqual(library.undo.redoStep(in: .library), .applied)
            XCTAssertEqual([family.parent, family.sibling].map { library.state(of: $0) }, [.live, .live])
            XCTAssertEqual(library.state(of: family.child), .deleted, "C stays where it was deleted")
        }
    }

    /// A tripwire for the guard itself. Every Undo or Redo closure in the
    /// app deletes task families through `deleteFamiliesFromHistory` (or
    /// `deleteOutcome`, which needs the step's ownership). This reads the
    /// sources and fails when a raw family delete appears after an
    /// `undoOutcome:` / `redoOutcome:` label, or outside the functions that
    /// implement the guard or run a command's first delete.
    func testNoHistoryClosureDeletesAFamilyOutsideTheGuard() throws {
        let scan = try scanHistoryClosures(
            pattern: #"\.delete\(taskIDs:|\btasks\.delete\(|deleteFamiliesNow\(|performDelete\("#,
            allowed: ["deleteFamiliesFromHistory", "deleteOutcome", "deleteFamiliesNow", "performDelete"]
        )
        XCTAssertTrue(scan.violations.isEmpty, "family deletes in a history closure: \(scan.violations)")
        XCTAssertGreaterThanOrEqual(scan.firstRunCalls, 3, "the scan still sees the commands' first deletes")
    }

    /// The mirror image: a history closure restores task families only through
    /// the guarded restores, which read the deletion records before anything
    /// comes back. `restoreAgain` runs the same check per task, then restores.
    func testNoHistoryClosureRestoresAFamilyOutsideTheGuard() throws {
        let scan = try scanHistoryClosures(
            pattern: #"\btasks\.restoreDeleted\(|performRestore\(|performRestoreAll\("#,
            allowed: ["restoreFamiliesFromHistory", "restoreOutcome", "restoreAgain", "performRestore", "performRestoreAll"]
        )
        XCTAssertTrue(scan.violations.isEmpty, "family restores in a history closure: \(scan.violations)")
        XCTAssertGreaterThanOrEqual(scan.firstRunCalls, 2, "the scan still sees the commands' first restores")
    }

    /// Every match of `pattern` in `Attic/` (outside `TaskStore*`), split into
    /// calls inside a history closure (Undo/Redo) that are not in an allowed
    /// function, and first-run calls from commands.
    private func scanHistoryClosures(pattern: String, allowed: Set<String>) throws -> (violations: [String], firstRunCalls: Int) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Attic")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasPrefix("TaskStore") }
        XCTAssertGreaterThan(files.count, 50, "the sources were found")
        let raw = try NSRegularExpression(pattern: pattern)
        let historyMarkers = ["undoOutcome:", "redoOutcome:", "undo:", "redo:"]
        var violations: [String] = []
        var firstRunCalls = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var function = ""
            var inHistory = false
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let range = trimmed.range(of: #"func \w+"#, options: .regularExpression) {
                    function = String(trimmed[range].dropFirst(5))
                    inHistory = false
                    if trimmed.hasPrefix("func ") || trimmed.contains(" func ") { continue }
                }
                if trimmed.contains("UndoStep(") { inHistory = false }
                if historyMarkers.contains(where: { trimmed.contains($0) }) { inHistory = true }
                let range = NSRange(line.startIndex..., in: line)
                guard raw.firstMatch(in: line, range: range) != nil, !trimmed.hasPrefix("//"),
                      !trimmed.hasPrefix("///") else { continue }
                if allowed.contains(function) { continue }
                if inHistory {
                    violations.append("\(file.lastPathComponent):\(index + 1) in \(function): \(trimmed)")
                } else {
                    firstRunCalls += 1
                }
            }
        }
        return (violations, firstRunCalls)
    }
}
