import AppKit
import Combine
import Darwin
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// The "+" card (Accepted 2026-10-29 and 30 Oct): its model and its view,
/// mounted on their own. Event writes go to a fake store only.
@MainActor
final class ComposerTests: XCTestCase {
    func testMultiplePanelDraftsSurviveQuitAndClosingAnotherPanel() throws {
        let suite = "ComposerPanelDrafts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let locations: [PanelPage?] = [nil, .tasks, .notes, .calendar]
        let inputs = [
            ComposerDraftStore.Draft(title: "Docked task", writing: "Keep first", kind: "task"),
            ComposerDraftStore.Draft(title: "Floating tasks", writing: "Keep second", kind: "task"),
            ComposerDraftStore.Draft(title: "Floating note", writing: "Keep third", kind: "note"),
            ComposerDraftStore.Draft(title: "Floating event", writing: "Keep fourth", kind: "event")
        ]
        let active = locations.map { ComposerDraftStore.forPanel(defaults: defaults, floatingPage: $0) }
        for (index, store) in active.enumerated() { store.save(inputs[index]) }
        let reopened = locations.map { ComposerDraftStore.forPanel(defaults: defaults, floatingPage: $0) }
        for (index, store) in reopened.enumerated() {
            XCTAssertEqual(store.load(), inputs[index], "relaunch kept panel \(index)'s draft")
        }

        reopened[1].save(nil) // Tasks in its own panel has been submitted.
        XCTAssertNil(reopened[1].load())
        for index in [0, 2, 3] {
            XCTAssertEqual(reopened[index].load(), inputs[index], "closing one panel cannot erase panel \(index)")
        }
    }

    /// Splitting the panels' kept words must still leave a failed Calendar
    /// submission available for retry from whichever panel opens Calendar.
    func testFailedCalendarEventRecoveryIsSharedBetweenDockedAndFloatingPanels() throws {
        let suite = "ComposerFailedEventPanels.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let docked = ComposerDraftStore.forPanel(defaults: defaults, floatingPage: nil)
        let floating = ComposerDraftStore.forPanel(defaults: defaults, floatingPage: .calendar)
        let event = ComposerDraftStore.FailedEvent(title: "Retry calendar event", writing: "Unsaved details",
                                                   day: nil, length: 60, calendarID: "test-calendar")
        docked.saveFailedEvents([event])
        XCTAssertEqual(floating.loadFailedEvents(), [event], "a pulled-out Calendar can recover the failed event")
        floating.saveFailedEvents([])
        XCTAssertTrue(docked.loadFailedEvents().isEmpty, "a successful retry clears the shared backup")
    }

    func testCP19RecoveredTaskConvertedToEventDoesNotReturnAsTask() async throws {
        let suite = "ComposerConvertEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        page.services.acknowledgementDelay = .seconds(3600)
        model.open(on: .tasks(.now)); type("Convert to event"); model.writing = "Task writing"; model.submit()
        saveFailure.on = true; page.settlePendingCompletionAcknowledgements(); saveFailure.on = false
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(drafts.loadFailedTasks().isEmpty)
        model.open(on: .calendar(selected: today), as: .event)
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(drafts.loadFailedTasks().isEmpty)
        model.open(on: .tasks(.now))
        XCTAssertTrue(page.addBar.text.isEmpty)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(events.events.count, 1)
    }

    func testR1PendingTaskExplainsBothSubmitRoutesAndKeepsCreateEnabled() async throws {
        model.open(on: .tasks(.now))
        type("Pending task")
        page.addBarState.stagingFiles = 1
        XCTAssertTrue(model.canCreate, "Create must remain reachable so it can explain why the draft is waiting")
        model.submit()
        XCTAssertEqual(page.toasts.current?.message, "Preparing files · try again in a moment")
        page.toasts.dismiss()
        let created = await model.create()
        XCTAssertFalse(created)
        XCTAssertEqual(page.toasts.current?.message, "Preparing files · try again in a moment")
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(page.addBar.text, "Pending task")
    }

    func testR2PendingTaskFilesDoNotBlockNoteOrFakeEventCreation() async {
        model.open(on: .calendar(selected: today), as: .note)
        type("Independent note")
        page.addBarState.stagingFiles = 1
        let noteCreated = await model.create()
        XCTAssertTrue(noteCreated)
        model.choose(.event)
        await model.loadCalendars()
        type("Independent event")
        let eventCreated = await model.create()
        XCTAssertTrue(eventCreated)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(page.addBarState.stagingFiles, 1, "neither kind consumes Task files")
    }

    private final class HeldFileProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (URL?, Bool, Error?) -> Void)?
        let provider = NSItemProvider()

        init(started: XCTestExpectation, name: String) {
            provider.suggestedName = name
            provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier,
                fileOptions: [], visibility: .all) { [weak self] completion in
                guard let self else { completion(nil, false, CocoaError(.userCancelled)); return nil }
                self.lock.withLock { self.completion = completion }
                started.fulfill()
                return nil
            }
        }

        func finish(_ url: URL) {
            let callback = lock.withLock { let value = completion; completion = nil; return value }
            callback?(url, false, nil)
        }
    }

    func testR8RealProvidersStayWithTheirSubmittedDraftAcrossClearDraft() async throws {
        let root = ownedTemporaryDirectory(prefix: "ComposerProviders")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("first.pdf")
        let secondURL = root.appendingPathComponent("second.pdf")
        try Data("first payload".utf8).write(to: firstURL)
        try Data("second payload".utf8).write(to: secondURL)
        let firstStarted = expectation(description: "first provider requested")
        let first = HeldFileProvider(started: firstStarted, name: "first.pdf")
        model.open(on: .tasks(.now))
        type("Task A")
        page.addComposerFiles([first.provider])
        await fulfillment(of: [firstStarted], timeout: 5)
        model.submit()
        XCTAssertEqual(page.toasts.current?.message, "Preparing files · try again in a moment")
        XCTAssertTrue(liveTasks().isEmpty)
        first.finish(firstURL)
        try await waitForComposer { self.page.addBarState.stagingFiles == 0 }
        model.submit() // acknowledged submission synchronously calls clearDraft
        XCTAssertTrue(page.addBar.text.isEmpty)
        type("Task B")
        let secondStarted = expectation(description: "second provider requested")
        let second = HeldFileProvider(started: secondStarted, name: "second.pdf")
        page.addComposerFiles([second.provider])
        await fulfillment(of: [secondStarted], timeout: 5)
        try await waitForComposer { !self.model.isCreating }
        second.finish(secondURL) // completion after A's clearDraft and durable save
        try await waitForComposer { self.page.addBarState.stagingFiles == 0 }
        model.submit()
        try await waitForComposer {
            self.liveTasks().count == 2 && self.liveTasks().allSatisfy { $0.attachments.count == 1 }
        }
        XCTAssertEqual(liveTasks().first { $0.title == "Task A" }?.attachments.map(\.filename), ["first.pdf"])
        XCTAssertEqual(liveTasks().first { $0.title == "Task B" }?.attachments.map(\.filename), ["second.pdf"])
        let reopened = TaskStore(container: container, taskImageFiles: tasks.taskImageFiles)
        for (title, payload) in [("Task A", "first payload"), ("Task B", "second payload")] {
            let reference = try XCTUnwrap(reopened.tasks.first { $0.title == title }?.attachments.first)
            let url = try await tasks.taskImageFiles.verifiedURL(for: reference)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), Data(payload.utf8), title)
        }
    }

    private func waitForComposer(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready(), "provider/submission must settle")
    }

    func testComposerCannotSubmitWhileFirstDraftFileProviderIsStillStaging() async throws {
        model.open(on: .tasks(.now))
        type("Task A with a pending file")
        page.addBarState.stagingFiles = 1 // deterministic held provider; completion still owns A's draft
        let premature = await model.create()
        XCTAssertFalse(premature, "the staging batch must settle before A can be submitted")
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(page.addBar.text, "Task A with a pending file")
        page.addBarState.stagingFiles = 0
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(liveTasks().map(\.title), ["Task A with a pending file"])
        type("Task B")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["Task A with a pending file", "Task B"])
    }

    func testTaskSaveFailureAfterNextDraftStartsKeepsBothDraftsAndTheirFiles() async throws {
        let root = ownedTemporaryDirectory(prefix: "ComposerFailedTasks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appendingPathComponent("original.pdf")
        let nextURL = root.appendingPathComponent("next.pdf")
        try Data("original attachment".utf8).write(to: firstURL)
        try Data("next attachment".utf8).write(to: nextURL)
        page.services.acknowledgementDelay = .seconds(3600)

        model.open(on: .tasks(.now))
        type("Original task #first")
        model.writing = "Original writing"
        page.addComposerFiles(urls: [firstURL])
        model.submit()
        XCTAssertEqual(page.addBar.text, "")

        type("Next task #second")
        model.writing = "Next writing"
        page.addComposerFiles(urls: [nextURL])
        let focusBeforeLateFailure = model.focusRequest
        saveFailure.on = true
        page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(liveTasks().isEmpty, "the failed task+writing transaction must roll back")
        XCTAssertEqual(model.focusRequest, focusBeforeLateFailure,
            "a late failure must not steal the keyboard from the next draft")
        XCTAssertEqual(page.addBar.text, "Next task #second")
        XCTAssertEqual(model.writing, "Next writing")
        XCTAssertEqual(page.addBarState.fileNames, ["next.pdf"], "failed task files must not migrate into the next draft")

        saveFailure.on = false
        model.submit()
        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(page.addBar.text, "Original task #first", "failed task should be recoverable after the next one saves")
        XCTAssertEqual(model.writing, "Original writing")
        XCTAssertEqual(page.addBarState.fileNames, ["original.pdf"])

        page.setViewOptions(TasksViewOptions(status: .inProgress), for: .now)
        model.submit()
        page.settlePendingCompletionAcknowledgements()
        try await waitForComposer {
            self.liveTasks().count == 2 && self.liveTasks().allSatisfy { $0.attachments.count == 1 }
        }
        XCTAssertEqual(liveTasks().first { $0.title == "Original task" }?.status, .todo,
            "retrying the failed task must preserve its originally submitted status")
        XCTAssertEqual(liveTasks().first { $0.title == "Original task" }?.attachments.map(\.filename), ["original.pdf"])
        XCTAssertEqual(liveTasks().first { $0.title == "Next task" }?.attachments.map(\.filename), ["next.pdf"])
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 2, "failed save must not add an Undo step")
        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertEqual(liveTasks().count, 1)
        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["Original task", "Next task"])
        let fixed = now
        let reopened = TaskStore(container: container, now: { fixed }, taskImageFiles: tasks.taskImageFiles)
        XCTAssertEqual(reopened.tasks.first { $0.title == "Original task" }?.attachments.map(\.filename), ["original.pdf"])
        XCTAssertEqual(reopened.tasks.first { $0.title == "Next task" }?.attachments.map(\.filename), ["next.pdf"])
    }

    func testFailedTaskAndNextDraftBothSurviveComposerRelaunch() throws {
        let suite = "ComposerFailedTasks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        page.services.acknowledgementDelay = .seconds(3600)

        model.open(on: .tasks(.now))
        type("Task to retry")
        page.addBar.picked.tags = ["chosen"]
        model.writing = "Keep my writing"
        model.submit()
        type("Later draft")
        model.writing = "Also keep this"
        saveFailure.on = true
        page.settlePendingCompletionAcknowledgements()
        model.saveKeptDraft()

        let fixed = now
        let restartedPage = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        restartedPage.services.acknowledgementDelay = .seconds(3600)
        ComposerRecoveryJournal.simulateProcessExitForTesting(drafts)
        let restarted = ComposerModel(tasks: restartedPage, services: ComposerServices(drafts: drafts))
        restarted.open(on: .tasks(.now))
        XCTAssertEqual(restartedPage.addBar.text, "Later draft")
        XCTAssertEqual(restarted.writing, "Also keep this")

        saveFailure.on = false
        restarted.submit()
        restartedPage.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(restartedPage.addBar.text, "Task to retry")
        XCTAssertEqual(restarted.writing, "Keep my writing")
        XCTAssertEqual(restartedPage.addBar.picked.tags, ["chosen"])
        restarted.submit()
        restartedPage.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["Later draft", "Task to retry"])
        XCTAssertNil(defaults.data(forKey: drafts.key + ".failedTasks"), "saved retries must clear the durable failure queue")
    }

    func testFailedTaskOwnsStagedBytesUntilRecoveryThenTransfersOwnershipToEditor() throws {
        var staging = TaskAttachmentStaging()
        let directory = try staging.makeOwnedDirectory()
        let file = directory.appendingPathComponent("owned.pdf")
        let payload = Data("owned staged bytes".utf8)
        try payload.write(to: file)
        staging.urls = [file]
        page.services.acknowledgementDelay = .seconds(3600)
        model.open(on: .tasks(.now))
        type("Failed owner")
        model.writing = "Writing forces the atomic save failure"
        page.addBarState.files = [TasksComposerFiles(staging: staging)]
        model.submit()
        type("Another draft")
        saveFailure.on = true
        page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(page.addBarState.files.isEmpty, "the next draft never claims A's files")
        page.clearComposerFiles()
        XCTAssertEqual(try Data(contentsOf: file), payload, "clearing B must not delete A's referenced staged bytes")
        model.clearDraft()
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Failed owner")
        XCTAssertEqual(page.addBarState.fileNames, ["owned.pdf"])
        XCTAssertEqual(try Data(contentsOf: file), payload)
        // Explicitly removing the recovered file transfers no ownership back
        // to the failed queue. Reopening must never advertise deleted bytes.
        page.clearComposerFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        model.clearDraft()
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Failed owner")
        XCTAssertTrue(page.addBarState.fileNames.isEmpty)
    }

    func testIdenticallyWordedNewDraftNeverTakesFailedDraftPicksOrFiles() throws {
        page.services.acknowledgementDelay = .seconds(3600)
        model.open(on: .tasks(.now))
        type("Same words")
        model.writing = "Same writing"
        page.addBar.picked.priority = .high
        let file = try ownedTemporaryFile(named: "first.pdf", prefix: "ComposerIdenticalDrafts")
        try Data("first only".utf8).write(to: file)
        page.addComposerFiles(urls: [file])
        model.submit()
        type("Same words")
        model.writing = "Same writing"
        page.addBar.picked.priority = .low
        saveFailure.on = true
        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(page.addBar.picked.priority, .low)
        XCTAssertTrue(page.addBarState.fileNames.isEmpty)
        saveFailure.on = false
        model.submit()
        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(liveTasks().map(\.priority), [.low])
        XCTAssertEqual(page.addBar.picked.priority, .high)
        XCTAssertEqual(page.addBarState.fileNames, ["first.pdf"])
    }

    func testPendingTaskSubmissionSurvivesQuitBeforeAcknowledgedSave() throws {
        let suite = "ComposerPendingTasks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        page.services.acknowledgementDelay = .seconds(3600)

        model.open(on: .tasks(.now))
        type("Important unsaved task #keep")
        model.writing = "Pending task writing"
        model.submit()

        XCTAssertTrue(liveTasks().isEmpty, "the acknowledged preview is not yet durable")
        XCTAssertEqual(page.addBar.text, "")
        XCTAssertEqual(drafts.loadFailedTasks().map(\.title), ["Important unsaved task #keep"],
            "quitting before the delayed save must not lose the submitted words")

        let fixed = now
        let restartedStore = TaskStore(container: container, now: { fixed }, taskImageFiles: tasks.taskImageFiles)
        let restartedLibrary = AtticLibrary(tasks: restartedStore, notes: notes)
        let restartedPage = TasksPageModel(library: restartedLibrary, services: TasksPageServices(now: { fixed }))
        ComposerRecoveryJournal.simulateProcessExitForTesting(drafts)
        let restarted = ComposerModel(tasks: restartedPage, services: ComposerServices(drafts: drafts))
        restarted.open(on: .tasks(.now))
        XCTAssertEqual(restartedPage.addBar.text, "Important unsaved task #keep")
        XCTAssertEqual(restarted.writing, "Pending task writing")
        XCTAssertEqual(restartedPage.addBar.parts(parser: restartedPage.parser).tags, ["keep"])

        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(liveTasks().map(\.title), ["Important unsaved task"])
        XCTAssertTrue(drafts.loadFailedTasks().isEmpty, "committed submissions must clear their recovery record")
    }

    func testRelaunchDiscardsPendingRecoveryWhenTaskAlreadyCommitted() throws {
        let suite = "ComposerCommittedPending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        let id = UUID()
        drafts.saveFailedTasks([ComposerDraftStore.FailedTask(id: id,
            title: TaskAddBarText(text: "Committed before crash"), writing: "Existing writing",
            status: .todo, page: .tasks(.now))])
        XCTAssertNotNil(library.createTask(TaskDraft(title: "Committed before crash"),
            writing: "Existing writing", in: .tasks, id: id))

        let restarted = ComposerModel(tasks: page, services: ComposerServices(drafts: drafts))
        restarted.open(on: .tasks(.now))
        XCTAssertTrue(drafts.loadFailedTasks().isEmpty,
            "a saved UUID must not remain queued for a duplicate retry")
        XCTAssertTrue(page.addBar.text.isEmpty, "a committed task must not reappear as an unsaved draft")
        XCTAssertEqual(liveTasks().map(\.title), ["Committed before crash"])
    }

    func testDelayedTaskToastUndoesCreationInItsOriginalHistoryAfterPageSwitch() throws {
        page.services.acknowledgementDelay = .seconds(3600)
        model.open(on: .tasks(.done))
        type("Follow up from Done")
        model.submit()
        model.open(on: .notes)
        page.settlePendingCompletionAcknowledgements()

        XCTAssertEqual(toasts, ["Added to Now"])
        XCTAssertEqual(library.undo.undoCount(in: .tasks), 1)
        XCTAssertTrue(toastUndos[0]().isApplied, "the toast must undo the Tasks step even after navigating to Notes")
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testSupersededComposerToastNeverUndoesTheNextTask() throws {
        page.services.acknowledgementDelay = .seconds(3600)
        model.open(on: .tasks(.done))
        type("First from Done")
        model.submit()
        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(liveTasks().map(\.title), ["First from Done"])
        XCTAssertEqual(toastUndos.count, 1)

        type("Second from Done")
        model.submit()
        page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["First from Done", "Second from Done"])
        XCTAssertEqual(toastUndos.count, 2)

        XCTAssertEqual(toastUndos[0](), .applied, "an old toast is stale once a newer Undo step exists")
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["First from Done", "Second from Done"])
        XCTAssertEqual(toastUndos[1](), .applied)
        XCTAssertEqual(liveTasks().map(\.title), ["First from Done"])
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["First from Done", "Second from Done"])
    }

    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var library: AtticLibrary!
    private var page: TasksPageModel!
    private var model: ComposerModel!
    private let events = FakeCalendarEventWriteStore()
    private var opened: [UUID] = []
    private var openedNotes: [UUID] = []
    private var openedEvents: [CalendarOwnedEvent] = []
    private var toasts: [String] = []
    private var failureNotices: [String] = []
    private var toastUndos: [@MainActor () -> CommandOutcome] = []
    private var windows: [NSWindow] = []
    private final class Switch { var on = false }
    private let saveFailure = Switch()
    private let clock: Calendar = Calendar.autoupdatingCurrent
    private lazy var now: Date = clock.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
    private var today: DueDay { DueDay(date: now, calendar: clock) }
    private func day(_ offset: Int) -> DueDay { DueDay(date: clock.date(byAdding: .day, value: offset, to: now)!, calendar: clock) }

    override func setUp() async throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        _ = try WorkspaceLegacyBridge.coordinator(for: container)
        let fixed = now
        tasks = TaskStore(container: container, now: { fixed },
            taskImageFiles: TaskImageFiles(rootURL: ownedTemporaryDirectory(prefix: "ComposerTaskFiles")))
        let failing = saveFailure
        notes = NoteStore(container: container, now: { fixed }, persist: { context in
            if failing.on { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, attachmentFileStore: makeTestAttachmentFileStore())
        library = AtticLibrary(tasks: tasks, notes: notes)
        page = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        events.availableCalendars = [
            CalendarWriteCalendar(id: "home", title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.9),
                                  sourceID: "local", sourceTitle: "On My Mac", isWritable: true),
            CalendarWriteCalendar(id: "work", title: "Work", colour: .init(red: 0.9, green: 0.4, blue: 0.2),
                                  sourceID: "local", sourceTitle: "On My Mac", isWritable: true),
        ]
        let store = events, undo = library.undo
        model = ComposerModel(tasks: page, services: ComposerServices(
            makeWriter: { EventKitCalendarEventWriter(store: store, record: try CalendarOwnershipRecord(), undoRoute: undo,
                                                      notificationCenter: NotificationCenter()) },
            openTaskPage: { [unowned self] in opened.append($0) },
            openNote: { [unowned self] in openedNotes.append($0) },
            openEvent: { [unowned self] in openedEvents.append($0) },
            toast: { [unowned self] message, undo in toasts.append(message); toastUndos.append(undo) },
            eventFailure: { [unowned self] message in failureNotices.append(message) }))
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        windows.forEach { $0.contentView = nil; $0.close() }
        windows.removeAll()
    }


    // R5: fresh page/card instances model relaunch; only the isolated defaults survive.
    private func r5Relaunch(_ store: ComposerDraftStore) -> (TasksPageModel, ComposerModel) {
        let fresh = TasksPageModel(library: library)
        return (fresh, ComposerModel(tasks: fresh, services: ComposerServices(drafts: store)))
    }

    func testR5BothOwnedDraftsSurviveQuitWithNoteShown() throws {
        let suite = "ComposerR5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        let (first, card) = r5Relaunch(store)
        card.open(on: .tasks(.now))
        first.addBar = TaskAddBarText(text: "Invoice for Bob")
        card.writing = "Task details"
        first.addBarState.stagingFiles = 1
        card.open(on: .notes)
        first.addBar = TaskAddBarText(text: "Half a note")
        card.writing = "Note details"
        card.saveKeptDraft()
        let (second, again) = r5Relaunch(store)
        XCTAssertEqual(again.kind, .note)
        XCTAssertEqual(second.addBar.text, "Half a note")
        XCTAssertEqual(again.writing, "Note details")
        again.open(on: .tasks(.now))
        again.choose(.task)
        XCTAssertEqual(second.addBar.text, "Invoice for Bob")
        XCTAssertEqual(again.writing, "Task details")
        again.choose(.note)
        XCTAssertEqual(second.addBar.text, "Half a note")
        XCTAssertEqual(again.writing, "Note details")
    }

    func testR5FileOnlyTaskCannotEraseTheAsideNoteOnQuit() throws {
        let suite = "ComposerR5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        let (first, card) = r5Relaunch(store)
        card.open(on: .tasks(.now))
        first.addBarState.stagingFiles = 1
        card.open(on: .notes)
        first.addBar = TaskAddBarText(text: "Half a note")
        card.writing = "Note details"
        card.close() // An earlier backup exists before Task is shown.
        card.open(on: .tasks(.now))
        card.choose(.task)
        XCTAssertEqual(first.addBar.text, "")
        card.saveKeptDraft()
        let (second, again) = r5Relaunch(store)
        XCTAssertEqual(again.kind, .task, "restore which owner was shown, including an empty Task")
        again.open(on: .tasks(.now))
        again.choose(.note)
        XCTAssertEqual(second.addBar.text, "Half a note")
        XCTAssertEqual(again.writing, "Note details")
    }

    func testR5SubmittingTaskKeepsTheAsideNoteAcrossRelaunch() async throws {
        let suite = "ComposerR5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        let (first, card) = r5Relaunch(store)
        card.open(on: .tasks(.now))
        first.addBar = TaskAddBarText(text: "Invoice for Bob")
        first.addBarState.stagingFiles = 1
        card.open(on: .notes)
        first.addBar = TaskAddBarText(text: "Half a note")
        card.writing = "Keep this writing"
        card.close()
        card.open(on: .tasks(.now))
        card.choose(.task)
        first.addBarState.stagingFiles = 0 // Completed staging; file persistence is a separate job.
        card.submit()
        for _ in 0..<100 where card.isCreating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(card.isCreating)
        XCTAssertEqual(liveTasks().map(\.title), ["Invoice for Bob"])
        // The acknowledgement must itself preserve the Note, without another close/quit save.
        let (second, again) = r5Relaunch(store)
        again.open(on: .tasks(.now))
        again.choose(.note)
        XCTAssertEqual(second.addBar.text, "Half a note")
        XCTAssertEqual(again.writing, "Keep this writing")
    }

    func testR5LegacySingleDraftMigratesWithoutChangingItsWordsOrKind() throws {
        let suite = "ComposerR5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"title":"Old note #home","writing":"kept\nexactly","kind":"note"}"#.utf8), forKey: "composerKeptDraft")
        let store = ComposerDraftStore(defaults: defaults)
        let (first, card) = r5Relaunch(store)
        XCTAssertEqual(first.addBar.text, "Old note #home")
        XCTAssertEqual(card.writing, "kept\nexactly")
        XCTAssertEqual(card.kind, .note)
        card.saveKeptDraft()
        let (second, again) = r5Relaunch(store)
        XCTAssertEqual(second.addBar, first.addBar)
        XCTAssertEqual(again.writing, card.writing)
        XCTAssertEqual(again.kind, .note)
    }

    func testR5MarkedWritingLeavesCommandReturnToTheInputMethod() throws {
        let (window, host, title) = try mountForKeys(on: .notes)
        typeKeys(title, "Composition note")
        let control = try XCTUnwrap(writingControl(in: host))
        XCTAssertTrue(window.makeFirstResponder(control))
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        writing.insertText("before ", replacementRange: writing.selectedRange())
        writing.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(control.performKeyEquivalent(with: event), "the real key-equivalent path leaves marked input to the IME")
        XCTAssertTrue(notes.notes.isEmpty)
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(writing.hasMarkedText())
        XCTAssertEqual(writing.string, "before 漢字")
        writing.insertText("漢字", replacementRange: writing.markedRange())
        spin()
        XCTAssertFalse(writing.hasMarkedText())
        XCTAssertTrue(control.performKeyEquivalent(with: event))
        spin()
        XCTAssertEqual(notes.notes.filter { $0.deletedAt == nil }.count, 1)
        XCTAssertTrue(try XCTUnwrap(notes.notes.first).body.contains("before 漢字"))
    }

    func testR5MarkedWritingDeclinesReturnLineBreakAndCancelCommands() throws {
        let (window, host, title) = try mountForKeys(on: .notes)
        typeKeys(title, "Composition note")
        let control = try XCTUnwrap(writingControl(in: host))
        XCTAssertTrue(window.makeFirstResponder(control))
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        let selectors = [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.cancelOperation(_:))]
        for selector in selectors {
            writing.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: (writing.string as NSString).length))
            let handled = control.delegate?.control?(control, textView: writing, doCommandBy: selector) ?? false
            XCTAssertFalse(handled, "marked command belongs to the input method: \(selector)")
            XCTAssertTrue(notes.notes.isEmpty)
            XCTAssertTrue(model.isOpen)
            XCTAssertTrue(writing.hasMarkedText())
            XCTAssertEqual(writing.string, "漢字")
        }
    }

    func testR5LibraryTagsSeedTheNoteAfterItsTaskOwnerIsSetAside() throws {
        for taskTitle in ["", "Invoice for Bob"] {
            let fresh = TasksPageModel(library: library)
            let card = ComposerModel(tasks: fresh)
            card.open(on: .tasks(.now))
            fresh.addBar = TaskAddBarText(text: taskTitle)
            fresh.addBarState.stagingFiles = 1
            card.startTags(["library"])
            card.open(on: .notes)
            try captureR13NoteDraft(taskTitle.isEmpty ? "R5-tags-empty" : "R5-tags-words", card: card)
            XCTAssertEqual(fresh.addBar.picked.tags, ["library"], "the opened Note owns the library filter")
            fresh.addBar.text = "Half a note"
            card.open(on: .tasks(.now))
            card.choose(.task)
            XCTAssertEqual(fresh.addBar.text, taskTitle)
            XCTAssertTrue(fresh.addBar.picked.tags.isEmpty, "Notes tags never leak onto the Task")
        }
    }

    func testR5SwitchingOwnedDraftsRestoresTheNativeTitleSelection() throws {
        let (window, _, title) = try mountForKeys(on: .tasks(.now))
        typeKeys(title, "Invoice for Bob 🧾")
        let expected = NSRange(location: 3, length: 5)
        title.setSelectedRange(expected)
        spin()
        XCTAssertEqual(page.addBarState.selection, expected)
        page.addBarState.stagingFiles = 1
        model.open(on: .notes)
        spin()
        typeKeys(title, "Half a note")
        title.setSelectedRange(NSRange(location: 2, length: 3))
        spin()
        model.open(on: .tasks(.now))
        model.choose(.task)
        spin()
        XCTAssertTrue(window.firstResponder === title)
        XCTAssertEqual(title.string, "Invoice for Bob 🧾")
        XCTAssertEqual(page.addBarState.selection, expected)
        XCTAssertEqual(title.selectedRange(), expected, "native selection must match the restored draft")
        // A saved range from before an external shortening must be clamped.
        page.addBarState.selection = NSRange(location: 1_000, length: 30)
        model.choose(.note)
        spin()
        model.choose(.task)
        spin()
        XCTAssertEqual(title.selectedRange(), NSRange(location: (title.string as NSString).length, length: 0))
    }

    func testR5FileDropSetsAsideAKeptNoteBeforeForcingTask() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r5-drop-\(UUID().uuidString).txt")
        try "dropped".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file); page.clearComposerFiles() }
        model.open(on: .notes)
        type("A kept note #home")
        model.writing = "Only the Note owns these words"
        model.pinned = true
        page.addBarState.selection = NSRange(location: 2, length: 4)
        let note = page.addBar
        model.close()
        let route = PanelComposerRoute(open: { [model] page, kind in model?.open(on: page, as: kind) })
        XCTAssertTrue(page.dropFilesOnComposer([try XCTUnwrap(NSItemProvider(contentsOf: file))], card: route))
        for _ in 0..<100 where page.addBarState.stagingFiles > 0 { try await Task.sleep(for: .milliseconds(20)) }
        try captureR13NoteDraft("R5-file-drop")
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(page.addBar.text, "", "a file's Task must not borrow the kept Note's title")
        XCTAssertEqual(model.writing, "")
        XCTAssertFalse(model.pinned)
        XCTAssertEqual(page.addBarState.fileNames.count, 1)
        model.choose(.note)
        XCTAssertEqual(page.addBar, note)
        XCTAssertEqual(model.writing, "Only the Note owns these words")
        XCTAssertTrue(model.pinned)
        XCTAssertEqual(page.addBarState.selection, NSRange(location: 2, length: 4))
    }

    private var r13RenderDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("R13Renders-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    func testR5RenderOutputStaysInTheTestTemporaryDirectory() {
        let output = r13RenderDirectory.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(output.hasPrefix(temporary + "/"), "render output must stay in test temporary storage: \(output)")
    }

    private func type(_ text: String) {
        // Typing keeps the draft's picks (the Calendar's day), as the field does.
        var draft = TaskAddBarText(text: text)
        draft.picked = page.addBar.picked
        page.addBar = draft
        page.addBarCaret = nil
    }

    private func liveTasks() -> [TaskItem] { tasks.tasks.filter { $0.deletedAt == nil } }

    func testCatchup2R2TasksAndCalendarAbandonOnlyTheirFilterSeed() async throws {
        for calendar in [false, true] {
            let nextFilters: [[String]] = calendar ? [[]] : [[], ["home"]]
            for nextTags in nextFilters {
                page.setTagPicks(TagPicks(["work"]))
                page.startDraftFromFilter() // Tasks '+'; Calendar shares this draft.
                model.open(on: calendar ? .calendar(selected: today) : .tasks(.now), as: .task)
                XCTAssertEqual(page.addBar.picked.tags, ["work"])
                model.close()
                page.setTagPicks(TagPicks(nextTags))
                page.startDraftFromFilter()
                model.open(on: .tasks(.now))
                let before = Set(liveTasks().map(\.id))
                type("Buy milk")
                await XCTAssertTrueAsync(await model.create())
                XCTAssertEqual(liveTasks().first { !before.contains($0.id) }?.tags, nextTags, "calendar=\(calendar)")
                model.clearDraft()
                model.close()
            }
        }
    }

    func testCatchup2R2CreationReseedsOnlyAnOpenCardAndDismissalEndsTheSeed() async throws {
        for acknowledged in [false, true] {
            for openingPage in [false, true] {
                page.setTagPicks(TagPicks(["work"]))
                page.startDraftFromFilter()
                model.open(on: .tasks(.now))
                let before = Set(liveTasks().map(\.id))
                type("Filtered task")
                if acknowledged {
                    model.submit(openingPage: openingPage)
                    for _ in 0..<200 where model.isCreating { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertFalse(model.isCreating)
                } else { await XCTAssertTrueAsync(await model.create(openingPage: openingPage)) }
                XCTAssertEqual(liveTasks().first { !before.contains($0.id) }?.tags, ["work"])
                XCTAssertEqual(model.isOpen, !openingPage)
                if !openingPage {
                    XCTAssertEqual(page.addBar.picked.tags, ["work"], "Return keeps the filter for the next task")
                    model.close()
                }
                XCTAssertTrue(page.addBar.picked.tags.isEmpty, "ack=\(acknowledged), commandReturn=\(openingPage)")
                page.setTagPicks(.none)
                model.open(on: .calendar(selected: today), as: .task)
                let beforeCalendar = Set(liveTasks().map(\.id))
                type("Unfiltered calendar task")
                await XCTAssertTrueAsync(await model.create())
                XCTAssertTrue(try XCTUnwrap(liveTasks().first { !beforeCalendar.contains($0.id) }).tags.isEmpty)
                model.clearDraft()
                model.close()
            }
        }
    }

    func testCatchupR4AbandonedFilterTagsDoNotTagTheNextTask() async throws {
        for atOnce in [false, true] {
            model.startTags(["work", "home"])
            model.open(on: .notes)
            XCTAssertEqual(page.addBar.picked.tags, ["work", "home"])
            XCTAssertFalse(model.hasDraft)
            model.close(atOnce: atOnce)
            XCTAssertTrue(page.addBar.picked.tags.isEmpty, "An empty dismissal ends its filter context")
            model.open(on: .tasks(.now))
            type("Buy milk")
            await XCTAssertTrueAsync(await model.create())
            XCTAssertTrue(try XCTUnwrap(liveTasks().last).tags.isEmpty)
            model.close()
        }
        model.startTags(["fresh"])
        model.open(on: .notes)
        XCTAssertEqual(page.addBar.picked.tags, ["fresh"], "An empty card can seed the next filter")
        model.clearDraft()
        model.close()
    }

    func testCatchupR4FilterTagsStayWithAKeptWritingDraftAndExplicitPicks() {
        model.startTags(["work"])
        model.open(on: .notes)
        model.writing = "Keep this writing"
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.picked.tags, ["work"])
        XCTAssertEqual(model.writing, "Keep this writing")
        model.clearDraft()
        model.close()
        model.startTags(["work"])
        model.open(on: .tasks(.now))
        page.addBar.picked.tags = ["chosen"]
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.picked.tags, ["chosen"], "Explicit picks remain part of the kept draft")
        model.clearDraft()
        model.close()
    }

    func testBG7ConsecutiveCalendarEventsKeepTheSelectedDay() async throws {
        let selected = day(3)
        model.open(on: .calendar(selected: selected))
        await model.loadCalendars()
        for title in ["First event", "Second event"] {
            type(title)
            let made = await model.create()
            XCTAssertTrue(made)
            XCTAssertTrue(model.isOpen)
        }
        XCTAssertEqual(events.events.count, 2)
        for event in events.events.values {
            XCTAssertEqual(DueDay(date: event.draft.start, calendar: clock), selected)
        }
    }

    func testBG7ConsecutiveCalendarTasksKeepTheSelectedDayThroughSubmit() async throws {
        let selected = day(3)
        model.open(on: .calendar(selected: selected), as: .task)
        for title in ["First task", "Second task"] {
            type(title)
            model.submit()
            for _ in 0..<200 where model.isCreating { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isCreating)
            XCTAssertTrue(model.isOpen)
        }
        XCTAssertEqual(liveTasks().count, 2)
        XCTAssertTrue(liveTasks().allSatisfy { $0.dueDay == selected })
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertEqual(liveTasks().count, 1)
    }

    func testBG8ClearDateRemovesDateAndTimeAndUndoRestoresBoth() async throws {
        model.open(on: .tasks(.now))
        for text in ["Call tomorrow 4pm", "Call 4pm"] {
            type(text)
            let before = page.addBar
            let expected = before.parts(parser: page.parser)
            let steps = page.addBarState.history.undoStack.count
            page.clearComposer(.date, editor: model.editor)
            XCTAssertNil(model.values.day)
            XCTAssertNil(model.values.time)
            XCTAssertEqual(page.addBarState.history.undoStack.count, steps + 1)
            let cleared = page.addBar
            let undo = try XCTUnwrap(page.addBarState.history.undo(current: cleared, selection: nil))
            page.addBar = undo.text
            XCTAssertEqual(page.addBar.parts(parser: page.parser), expected)
            let redo = try XCTUnwrap(page.addBarState.history.redo(current: page.addBar, selection: nil))
            page.addBar = redo.text
            let made = await model.create()
            XCTAssertTrue(made)
        }
        XCTAssertEqual(liveTasks().count, 2)
        XCTAssertTrue(liveTasks().allSatisfy { $0.dueDay == nil && $0.dueTimeMinutes == nil })
    }

    func testBG9EventDraftUsesGregorianCivilDayForEverySystemCalendar() throws {
        for zone in ["Europe/London", "America/Los_Angeles"] {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(identifier: zone)!
            let civilDay = DueDay(year: 2026, month: 11, day: 13)!
            for time: Int? in [nil, 16 * 60 + 30] {
                let expected = try XCTUnwrap(ComposerModel.eventDraft(title: "Meeting", day: civilDay, time: time,
                    length: 60, calendarID: "home", calendar: gregorian))
                for identifier in [Calendar.Identifier.buddhist, .japanese, .gregorian] {
                    var calendar = Calendar(identifier: identifier)
                    calendar.timeZone = gregorian.timeZone
                    let actual = try XCTUnwrap(ComposerModel.eventDraft(title: "Meeting", day: civilDay, time: time,
                        length: 60, calendarID: "home", calendar: calendar))
                    XCTAssertEqual(actual, expected, "\(identifier), \(zone), \(String(describing: time))")
                }
            }
        }
    }

    func testQueuedEventSubmissionCannotCreateAReplacementSession() async {
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Old event")
        model.submit(openingPage: true)
        // Stay on this actor turn: the queued event has not started yet.
        model.close()
        model.open(on: .tasks(.now))
        type("Replacement draft")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Replacement draft")
    }

    func testUnhandledEscapeClosesTheComposerAndKeepsItsDraftBeforeWindowDismissal() {
        let state = PanelComposerState()
        let shared = state.model(tasks: page, services: ComposerServices())
        shared.open(on: .tasks(.now))
        type("Keep this draft")
        XCTAssertTrue(state.closeForUnhandledEscape())
        XCTAssertFalse(shared.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep this draft")
        XCTAssertFalse(state.closeForUnhandledEscape(), "A second Escape can dismiss the panel")
    }

    func testAnInFlightEventCreatesOnceAndLeavesAReopenedDraftAlone() async throws {
        let staged = expectation(description: "event proof staged off main")
        let release = DispatchSemaphore(value: 0)
        var paused = false // confined to the writer worker
        let record = try CalendarOwnershipRecord(persist: { _ in
            if !paused {
                paused = true
                staged.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        })
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            CalendarEventTransactions(store: backend, record: record)
        }
        model.services.makeWriter = { writer }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        XCTAssertTrue(model.isCreating)
        let duplicate = Task { await self.model.create() }
        await Task.yield()
        model.close()
        model.open(on: .tasks(.now))
        type("New draft")
        release.signal()
        defer { release.signal() }
        await XCTAssertTrueAsync(await submission.value)
        await XCTAssertFalseAsync(await duplicate.value)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(events.events.values.first?.draft.title, "Submitted event")
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "New draft")
    }

    /// A held write: the record's persist parks on the writer worker until
    /// released, then fails (rolled back) or succeeds. Fakes only.
    private func holdEventWrite(failing: Bool) throws -> (staged: XCTestExpectation, release: DispatchSemaphore) {
        let staged = expectation(description: "event write held off main")
        let release = DispatchSemaphore(value: 0)
        var held = false // confined to the writer worker
        let record = try CalendarOwnershipRecord(persist: { _ in
            guard !held else { return }
            held = true
            staged.fulfill()
            _ = release.wait(timeout: .now() + 10)
            if failing { throw CocoaError(.fileWriteUnknown) }
        })
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            CalendarEventTransactions(store: backend, record: record)
        }
        model.services.makeWriter = { writer }
        return (staged, release)
    }

    func testAHeldEventWriteThatFailsAfterTheDraftChangesSaysSoAndKeepsTheEdit() async throws {
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        type("Edited event")
        model.writing = "Edited notes"
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(model.failed)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Edited event")
        XCTAssertEqual(model.writing, "Edited notes")
        XCTAssertTrue(events.events.isEmpty)
    }

    func testAHeldEventFailureAfterReopeningAsTaskNotifiesAndRecoversOriginalEvent() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }

        let selected = day(3)
        model.open(on: .calendar(selected: selected))
        await model.loadCalendars()
        type("Original event 2pm")
        model.writing = "Original notes"
        model.eventLength = 90
        model.calendarID = "work"
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        model.open(on: .tasks(.now))
        type("Replacement task")
        model.writing = "Different notes"
        release.signal()

        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(failureNotices.contains { $0.contains("Couldn’t save event") },
                      "a failed closed/reopened event must be announced")
        XCTAssertEqual(page.addBar.text, "Replacement task", "the new task is untouched")
        XCTAssertEqual(model.writing, "Different notes")
        XCTAssertTrue(events.events.isEmpty, "failure rolls back the event")
        XCTAssertEqual(drafts.loadFailedEvents().map(\.title), ["Original event 2pm"])

        await XCTAssertTrueAsync(await model.create())
        model.close()
        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.kind, .event)
        XCTAssertEqual(page.addBar.text, "Original event 2pm")
        XCTAssertEqual(model.writing, "Original notes")
        XCTAssertEqual(model.values.day, selected)
        XCTAssertEqual(model.eventLength, 90)
        XCTAssertEqual(model.calendarID, "work")
        XCTAssertTrue(model.failed, "the recovered event clearly remains unsaved")
        XCTAssertEqual(drafts.loadFailedEvents().map(\.title), ["Original event 2pm"],
                       "reopening is not a durable save; recovery stays backed up")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(drafts.loadFailedEvents().isEmpty, "durable retry consumes the recovery backup")
        XCTAssertEqual(events.events.values.first?.draft.title, "Original event")
    }

    func testAHeldEventFailureAfterCloseSurvivesAComposerRelaunch() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        type("Still mine")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(failureNotices.contains { $0.contains("Couldn’t save event") })

        // An app restart reconstructs the composer using its saved drafts.
        let fixed = now
        let freshPage = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        let restarted = ComposerModel(tasks: freshPage, services: ComposerServices(drafts: drafts))
        restarted.open(on: .calendar(selected: today))
        XCTAssertEqual(freshPage.addBar.text, "Still mine")
        XCTAssertEqual(restarted.values.day, day(2))
        XCTAssertTrue(restarted.failed)
        restarted.close()
        let lastPage = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
        let stillRecoverable = ComposerModel(tasks: lastPage, services: ComposerServices(drafts: drafts))
        stillRecoverable.open(on: .calendar(selected: today))
        XCTAssertEqual(stillRecoverable.values.day, day(2), "closing without saving keeps the original date")
        XCTAssertTrue(stillRecoverable.failed)
    }

    func testFailedEventRecoveryRemembersTypedDateOverEarlierPickedDay() async throws {
        let suite = "ComposerFailedEvent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drafts = ComposerDraftStore(defaults: defaults)
        model.services.drafts = drafts
        let (staged, release) = try holdEventWrite(failing: true)
        defer { release.signal() }
        model.open(on: .calendar(selected: day(3)))
        await model.loadCalendars()
        type("Appointment tomorrow 2pm")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        model.close()
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertEqual(drafts.loadFailedEvents().first?.day, day(1), "the typed day wins before submission")

        model.open(on: .calendar(selected: today))
        XCTAssertEqual(model.values.day, day(1))
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(events.events.values.first?.draft.start, day(1).startDate(in: clock)?.addingTimeInterval(14 * 3600))
    }

    func testAHeldEventWriteThatSucceedsAfterTheDraftChangesShowsNoFailure() async throws {
        let (staged, release) = try holdEventWrite(failing: false)
        defer { release.signal() }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Submitted event")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [staged], timeout: 3)
        type("Edited event")
        model.writing = "Edited notes"
        release.signal()
        await XCTAssertTrueAsync(await submission.value)
        XCTAssertFalse(model.failed)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Edited event")
        XCTAssertEqual(model.writing, "Edited notes")
        XCTAssertEqual(events.events.values.map(\.draft.title), ["Submitted event"])
    }

    func testTypingDuringCalendarLoadingCannotSubmitTheNewerDraft() async throws {
        let loading = expectation(description: "calendar load")
        let submitting = expectation(description: "submission entered")
        let release = DispatchSemaphore(value: 0)
        let backend = events
        let writer = BackgroundCalendarEventWriter(undoRoute: library.undo) {
            loading.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return CalendarEventTransactions(store: backend, record: try CalendarOwnershipRecord())
        }
        model.services.makeWriter = { writer }
        let token = model.$isCreating.dropFirst().filter { $0 }.sink { _ in submitting.fulfill() }
        defer { token.cancel(); release.signal() }
        model.open(on: .calendar(selected: today))
        type("First draft")
        let submission = Task { await self.model.create() }
        await fulfillment(of: [loading, submitting], timeout: 3)
        type("Newer draft")
        release.signal()
        await XCTAssertFalseAsync(await submission.value)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Newer draft")
    }

    // MARK: Kinds

    func testPlusOpensOnThePagesOwnKindWithItsKinds() async {
        model.open(on: .tasks(.now))
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(model.kinds, [.task, .note])
        model.close()
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        XCTAssertEqual(model.kind, .event)
        XCTAssertEqual(model.kinds, [.task, .event, .note])
    }

    func testShiftCommandNOpensOnNote() {
        model.open(on: .tasks(.now), as: .note)
        XCTAssertEqual(model.kind, .note)
    }

    func testAKeptNoteDraftOpensAsNoteOnAnyPage() async {
        model.open(on: .tasks(.now))
        model.choose(.note)
        type("Idea #work")
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        XCTAssertEqual(model.kind, .note)
        XCTAssertEqual(page.addBar.text, "Idea #work")
    }

    func testAnEmptyNoteDraftOpensOnThePagesKind() {
        model.open(on: .tasks(.now), as: .note)
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
    }

    func testAKeptEventDraftIsATaskOutsideCalendar() async {
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        type("Lunch 1pm")
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
        XCTAssertEqual(page.addBar.text, "Lunch 1pm")
        XCTAssertFalse(model.kinds.contains(.event))
    }

    func testCalendarStartsOnTheSelectedDayAndNowStartsEmpty() async {
        model.open(on: .tasks(.now))
        XCTAssertNil(model.values.day, "Date is empty by default on Now")
        model.close()
        model.open(on: .calendar(selected: day(3)))
        await model.loadCalendars()
        XCTAssertEqual(model.values.day, day(3))
        model.choose(.task)
        XCTAssertEqual(model.values.day, day(3))
    }

    func testTheTitleTintsWhatThisKindReads() async {
        model.open(on: .tasks(.now))
        type("Call !! #home tomorrow 4pm")
        XCTAssertEqual(model.chips.count, 4)
        model.choose(.note)
        XCTAssertEqual(model.chips.count, 1)
        XCTAssertEqual(model.values.tags, ["home"])
        model.close()
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        model.choose(.event)
        XCTAssertEqual(model.chips.count, 2, "an event reads a day and a time")
        XCTAssertNil(model.values.priority)
    }

    // MARK: Tasks

    func testReturnCreatesATaskWithItsWritingAsOneUndoStep() async throws {
        model.open(on: .tasks(.now))
        type("Pay rent !! #home tomorrow 4pm")
        model.writing = "Bank details"
        await XCTAssertTrueAsync(await model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.title, "Pay rent")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertEqual(task.dueDay, day(1))
        XCTAssertEqual(task.dueTimeMinutes, 16 * 60)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertTrue(model.isOpen, "P4: Return adds the task and the card stays open")
        XCTAssertFalse(model.hasDraft)
        XCTAssertTrue(opened.isEmpty)

        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.redo(in: .tasks), .applied)
        XCTAssertEqual(liveTasks().map(\.id), [task.id])
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
    }

    func testCommandReturnCreatesAndOpensTheTasksPage() async throws {
        model.open(on: .tasks(.now))
        type("Call Sam")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        XCTAssertEqual(opened, [try XCTUnwrap(liveTasks().first).id])
    }

    func testLaterMakesAnUndatedPutOffTask() async throws {
        model.open(on: .tasks(.backlog))
        type("Someday")
        await XCTAssertTrueAsync(await model.create())
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertEqual(task.status, .backlog)
        XCTAssertNil(task.dueDay)
        XCTAssertTrue(toasts.isEmpty)
    }

    func testADatedTaskFromLaterGoesToNow() async throws {
        model.open(on: .tasks(.backlog))
        type("Dentist tomorrow")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    func testDoneCreatesInNow() async throws {
        model.open(on: .tasks(.done))
        type("Follow up")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).status, .todo)
        XCTAssertEqual(toasts, ["Added to Now"])
    }

    func testBG2SharedComposerOpensTheFoldedDayForItsNewTask() async throws {
        let anchor = try XCTUnwrap(tasks.create(title: "Due today"))
        XCTAssertTrue(page.setDueDay(today, for: [anchor.id]).isApplied)
        let key = try XCTUnwrap(page.groupKey(of: anchor.id, on: .now))
        page.toggleGroup(key, on: .now)
        XCTAssertTrue(page.folded(on: .now).contains(key))
        model.open(on: .tasks(.now))
        type("Call the team")
        page.addBar.picked.day = today
        model.submit(openingPage: false)
        for _ in 0..<100 where liveTasks().count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let created = try XCTUnwrap(liveTasks().first { $0.title == "Call the team" })
        XCTAssertEqual(created.dueDay, today)
        XCTAssertFalse(page.folded(on: .now).contains(key), "BG-2: creating a task opens its folded destination")
        XCTAssertTrue(page.rows(for: .now).contains { $0.id == created.id })
        XCTAssertEqual(page.addedRequest?.id, created.id)
    }

    func testBG2DatedTaskFromBacklogOpensItsFoldedNowDestination() async throws {
        let anchor = try XCTUnwrap(tasks.create(title: "Already in Now"))
        XCTAssertTrue(page.setDueDay(today, for: [anchor.id]).isApplied)
        let key = try XCTUnwrap(page.groupKey(of: anchor.id, on: .now))
        page.toggleGroup(key, on: .now)
        page.select(tab: .backlog)
        model.open(on: .tasks(.backlog))
        type("Due on the active list")
        page.addBar.picked.day = today
        model.submit(openingPage: false)
        for _ in 0..<100 where liveTasks().count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let created = try XCTUnwrap(liveTasks().first { $0.title == "Due on the active list" })
        XCTAssertEqual(created.listedStatus, .todo)
        XCTAssertFalse(page.folded(on: .now).contains(key),
                       "BG-2: the destination is Now even while the composer originated on Backlog")
        XCTAssertTrue(page.rows(for: .now).contains { $0.id == created.id })
    }

    /// Review B-4: once closing starts, nothing creates.
    func testAClosedCardCreatesNothing() async {
        model.open(on: .tasks(.now))
        type("Not yet")
        model.close()
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(page.addBar.text, "Not yet", "the draft is kept")
    }

    func testEscapeKeepsTheDraftAndAnEmptyTitleCannotCreate() async {
        model.open(on: .tasks(.now))
        await XCTAssertFalseAsync(await model.create())
        type("Draft")
        model.writing = "kept"
        model.close()
        XCTAssertFalse(model.isOpen)
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Draft")
        XCTAssertEqual(model.writing, "kept")
    }

    /// Accepted 2026-11-04 (#9): a page switch closes the card at once and
    /// whole; Escape and a click outside fold it back into "+". The draft
    /// is kept either way.
    func testAPageSwitchClosesTheCardAtOnceKeepingItsDraft() {
        model.open(on: .tasks(.now))
        type("Draft")
        model.close(atOnce: true)
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(model.closedAtOnce)
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar.text, "Draft")
        model.close()
        XCTAssertFalse(model.closedAtOnce, "Escape folds it")
    }

    /// Accepted 2026-11-04: a press anywhere outside the open card closes
    /// it (keeping its draft); a press on the card keeps it.
    func testAPressOutsideTheCardClosesIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = content
        let watcher = ComposerOutsideClick.Watcher(frame: NSRect(x: 100, y: 20, width: 289, height: 90))
        content.addSubview(watcher)
        var open = true
        watcher.isOpen = { open }
        func press(_ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        XCTAssertFalse(watcher.closes(on: try press(NSPoint(x: 150, y: 60))), "on the card")
        XCTAssertTrue(watcher.closes(on: try press(NSPoint(x: 150, y: 300))), "on the list above it")
        XCTAssertTrue(watcher.closes(on: try press(NSPoint(x: 20, y: 30))), "on the bar beside it")
        open = false
        XCTAssertFalse(watcher.closes(on: try press(NSPoint(x: 150, y: 300))), "a closed card closes nothing")
    }

    /// Accepted 2026-11-03 (P4): Return or Create adds the task and the card
    /// stays open, empty, its title asked for the keyboard again; ⌘Return
    /// opens the task's page, so the card folds.
    func testReturnAddsTheTaskAndTheCardStaysOpenEmptyForTheNextOne() async throws {
        func awaitDurableCreation() async throws {
            for _ in 0..<60 {
                if !model.isCreating { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Task creation did not finish its durable transaction")
        }
        model.open(on: .tasks(.now))
        type("Call Sam")
        let asked = model.focusRequest
        model.submit()
        XCTAssertTrue(page.rows(for: .now).contains { $0.model.title == "Call Sam" }, "Row appears before disk write")
        XCTAssertTrue(model.isCreating)
        try await awaitDurableCreation()
        XCTAssertEqual(liveTasks().map(\.title), ["Call Sam"])
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(page.addBar.text, "")
        XCTAssertNotEqual(model.focusRequest, asked, "the title takes the keyboard for the next one")
        type("Call Ann")
        model.submit()
        XCTAssertTrue(page.rows(for: .now).contains { $0.model.title == "Call Ann" })
        try await awaitDurableCreation()
        XCTAssertEqual(Set(liveTasks().map(\.title)), ["Call Sam", "Call Ann"])
        XCTAssertTrue(model.isOpen)
        type("Open it")
        model.submit(openingPage: true)
        XCTAssertFalse(model.isOpen, "⌘Return opens the page and the card folds")
        try await awaitDurableCreation()
        XCTAssertEqual(opened.count, 1)
    }

    /// UX audit A2: a draft kept with Escape comes back after a quit and
    /// relaunch (a new model on the same defaults), and is gone once used.
    func testAKeptDraftComesBackAfterRelaunchAndGoesOnceUsed() throws {
        let suite = "ComposerDraft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComposerDraftStore(defaults: defaults)
        func relaunch() -> (TasksPageModel, ComposerModel) {
            let fixed = now
            let page = TasksPageModel(library: library, services: TasksPageServices(now: { fixed }))
            return (page, ComposerModel(tasks: page, services: ComposerServices(drafts: store)))
        }
        let (first, card) = relaunch()
        card.open(on: .tasks(.now))
        card.choose(.note)
        first.addBar = TaskAddBarText(text: "Plan the trip #travel")
        card.writing = "Book trains"
        card.close()
        let (second, again) = relaunch()
        XCTAssertEqual(second.addBar.text, "Plan the trip #travel")
        XCTAssertEqual(again.writing, "Book trains")
        XCTAssertEqual(again.kind, .note)
        // The app quitting with the card open keeps what it holds too.
        again.open(on: .tasks(.now))
        second.addBar = TaskAddBarText(text: "Plan the trip, then pack")
        again.saveKeptDraft()
        let (third, card3) = relaunch()
        XCTAssertEqual(third.addBar.text, "Plan the trip, then pack")
        card3.open(on: .notes)
        card3.submit()
        XCTAssertNil(store.load(), "a used draft is not kept")
        let (fourth, card4) = relaunch()
        XCTAssertEqual(fourth.addBar.text, "")
        XCTAssertEqual(card4.writing, "")
    }

    /// B1: a long title wraps into the writing line's space while the
    /// writing is empty and not being typed in.
    func testALongTitleTakesTheWritingLinesSpaceOnlyWhileTheWritingIsEmpty() {
        XCTAssertTrue(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: false, writing: "", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "notes", writingFocused: false))
        XCTAssertFalse(ComposerCard.titleTakesWritingSpace(titleWraps: true, writing: "", writingFocused: true))
    }

    // MARK: Events

    func testAnEventIsWrittenThroughTheWriterAndUndoneWithIt() async throws {
        model.open(on: .calendar(selected: day(2)))
        await model.loadCalendars()
        XCTAssertEqual(model.calendars.map(\.id), ["home", "work"])
        XCTAssertEqual(model.selectedCalendar?.id, "home")
        model.calendarID = "work"
        model.eventLength = 90
        type("Lunch with Ana 1pm")
        await XCTAssertTrueAsync(await model.create())
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertEqual(event.draft.title, "Lunch with Ana")
        XCTAssertEqual(event.draft.calendarID, "work")
        XCTAssertFalse(event.draft.isAllDay)
        XCTAssertNil(event.draft.notes, "an empty writing line writes no notes")
        var start = DateComponents(year: day(2).year, month: day(2).month, day: day(2).day, hour: 13)
        start.calendar = clock
        XCTAssertEqual(event.draft.start, clock.date(from: start))
        XCTAssertEqual(event.draft.end.timeIntervalSince(event.draft.start), 90 * 60)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(model.calendarID, "work", "the calendar choice is kept for the next event")

        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(events.events.isEmpty)
    }

    func testAnEventsWritingLineBecomesItsNotesAndUndoStillRemovesIt() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Dentist 9am")
        model.writing = "  Bring the form\nRoom 4  "
        await XCTAssertTrueAsync(await model.create())
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.notes, "Bring the form\nRoom 4")
        XCTAssertEqual(model.writing, "")
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.redo(in: .calendar), .applied)
        XCTAssertEqual(events.events.values.first?.draft.notes, "Bring the form\nRoom 4")
    }

    func testAWhitespaceWritingLineWritesNoNotes() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Gym")
        model.writing = " \n "
        await XCTAssertTrueAsync(await model.create())
        XCTAssertNil(try XCTUnwrap(events.events.values.first).draft.notes)
    }

    func testAnEventWithNoTimeIsAllDayAndCommandReturnOpensIt() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        type("Holiday")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertTrue(event.draft.isAllDay)
        XCTAssertEqual(event.draft.start, day(1).startDate(in: clock).flatMap { clock.startOfDay(for: $0) })
        XCTAssertEqual(openedEvents.count, 1)
    }

    func testATaskMadeOnCalendarIsOneStepInCalendarsHistory() async throws {
        model.open(on: .calendar(selected: day(1)))
        await model.loadCalendars()
        model.choose(.task)
        type("Buy flowers")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try XCTUnwrap(liveTasks().first).dueDay, day(1))
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAFailedEventWriteKeepsTheDraft() async {
        let failureToast = PanelToastCenter()
        model.services.eventFailure = { [failureToast] message in failureToast.showFailure(message) }
        model.services.makeWriter = { throw CalendarEventWriteError.accessDenied }
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Standup 9am")
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Standup 9am")
        XCTAssertEqual(failureToast.current?.isFailure, true, "Calendar reports the red failure toast")
        XCTAssertEqual(failureToast.current?.actionTitle, "OK")
        XCTAssertFalse(failureToast.current?.answersUndoKey ?? true, "the failed save did not create an Undo step")
        XCTAssertFalse(failureToast.hasPendingDismissalForTesting, "failure persists for acknowledgement")
    }

    // MARK: Quick note

    func testAQuickNoteIsFiledInNotesWithItsTagsAndPin() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Gift ideas #home")
        model.writing = "Scarf"
        model.pinned = true
        await XCTAssertTrueAsync(await model.create())
        let note = try XCTUnwrap(notes.notes.first { $0.deletedAt == nil })
        XCTAssertEqual(note.title, "Gift ideas")
        XCTAssertEqual(note.tags, ["home"])
        XCTAssertTrue(note.isPinned)
        XCTAssertTrue(note.body.contains("Scarf"))
        XCTAssertNil(note.taskID)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertEqual(toasts, ["Added to Notes"])
        XCTAssertFalse(model.pinned)

        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertNil(notes.notes.first { $0.id == note.id && $0.deletedAt == nil })
    }

    /// Review B-1: the toast undoes the history its creation went into,
    /// even after the card moved to another page.
    func testAToastsUndoUndoesTheHistoryItsCreationWentInto() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Tasks-side idea")
        await XCTAssertTrueAsync(await model.create())
        let note = try XCTUnwrap(notes.notes.first { $0.deletedAt == nil })
        let undo = try XCTUnwrap(toastUndos.last)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        model.close()
        XCTAssertEqual(undo(), .applied)
        XCTAssertNil(notes.notes.first { $0.id == note.id && $0.deletedAt == nil }, "the note went, not a Calendar step")
    }

    func testCommandReturnOpensTheNoteInNotes() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Reading list")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        XCTAssertEqual(openedNotes.count, 1)
        XCTAssertTrue(toasts.isEmpty)
    }

    // MARK: Phase A fixes (review of 15109359)

    private func rows<T: PersistentModel>(_ type: T.Type) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func testAFailedSaveLeavesNoTaskNoWritingNoStepAndARetryMakesOne() async throws {
        model.open(on: .tasks(.now))
        type("Pay rent")
        model.writing = "Bank details"
        saveFailure.on = true
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(try rows(TaskItem.self).isEmpty, "no live or Recently Deleted task")
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(try rows(TaskNoteAssociation.self).isEmpty)
        XCTAssertFalse(library.undo.canUndo(in: .tasks))
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(page.addBar.text, "Pay rent")
        XCTAssertEqual(model.writing, "Bank details")

        saveFailure.on = false
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(try rows(TaskItem.self).count, 1)
        let task = try XCTUnwrap(liveTasks().first)
        XCTAssertTrue(TaskNoteConversion.hasWriting(task.id, in: ModelContext(container)))
        XCTAssertEqual(library.undo(in: .tasks), .applied)
        XCTAssertTrue(liveTasks().isEmpty)
    }

    func testAPinThatCannotSaveKeepsTheCardOpenWithTheDraft() async throws {
        model.open(on: .tasks(.now), as: .note)
        type("Pinned idea")
        model.pinned = true
        saveFailure.on = true
        await XCTAssertFalseAsync(await model.create())
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.failed)
        XCTAssertTrue(model.pinned)
        XCTAssertTrue(try rows(NoteItem.self).isEmpty)
        XCTAssertTrue(toasts.isEmpty)

        saveFailure.on = false
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(try XCTUnwrap(notes.notes.first).isPinned)
    }

    func testATypedDayReplacesCalendarsPickedDayEvenAtTheCaret() async throws {
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("Lunch tomorrow")
        await XCTAssertTrueAsync(await model.create(openingPage: true))
        let event = try XCTUnwrap(events.events.values.first)
        XCTAssertEqual(event.draft.title, "Lunch")
        XCTAssertEqual(DueDay(date: event.draft.start, calendar: clock), day(1))
    }

    func testCalendarUndoReachesTheNewestCalendarActionWhateverItsKind() async throws {
        let b = try XCTUnwrap(library.createTasks([TaskDraft(title: "B")])?.first)
        model.open(on: .calendar(selected: today))
        await model.loadCalendars()
        type("A 1pm")
        await XCTAssertTrueAsync(await model.create())
        XCTAssertEqual(events.events.count, 1)
        CalendarAgendaCommands.toggleDone(b.id, store: tasks)
        XCTAssertEqual(tasks.listedTask(withID: b.id)?.status, .done)

        let history = try XCTUnwrap(AtticPanelController.unhandledUndoHistory(for: .calendar))
        XCTAssertEqual(library.undo(in: history), .applied)
        XCTAssertEqual(tasks.listedTask(withID: b.id)?.status, .todo, "B is reopened")
        XCTAssertEqual(events.events.count, 1, "A stays")
        XCTAssertEqual(library.undo(in: history), .applied)
        XCTAssertTrue(events.events.isEmpty, "then A goes")
        XCTAssertNotNil(tasks.task(withID: b.id), "B's own creation belongs to Tasks")
        XCTAssertEqual(AtticPanelController.unhandledUndoHistory(for: .tasks), .tasks)
    }

    func testAnAgendaRenameIsACalendarStep() throws {
        let b = try XCTUnwrap(library.createTasks([TaskDraft(title: "Old")])?.first)
        XCTAssertTrue(CalendarAgendaCommands.rename(b.id, to: " New ", store: tasks))
        XCTAssertEqual(tasks.task(withID: b.id)?.title, "New")
        XCTAssertEqual(library.undo(in: .calendar), .applied)
        XCTAssertEqual(tasks.task(withID: b.id)?.title, "Old")
    }

    // MARK: Keys through the mounted card

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private func spin(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func mountForKeys(on composerPage: ComposerPage,
                              onKeyboardTargetChange: ((ComposerCard.KeyboardTarget) -> Void)? = nil,
                              captureSurface: Bool = false, mode: AtticDesignContext.Mode? = nil) throws -> (NSWindow, NSView, NSTextView) {
        try requireKeyWindowTests()
        model.open(on: composerPage)
        let hosting: NSView
        if captureSurface {
            // The production panel supplies its material behind this card.
            // Draw the real card contents over a stable panel surface here:
            // sandboxed offscreen AppKit cannot snapshot system glass.
            let design = AtticDesignContext(mode: mode ?? .light, reduceTransparency: true)
            hosting = NSHostingView(rootView: ComposerCard(model: model, drawsChrome: false,
                onKeyboardTargetChange: onKeyboardTargetChange)
                .atticDesign(design).background(design.tokens.panel.base.color))
        } else if let mode {
            hosting = NSHostingView(rootView: ComposerCard(model: model,
                onKeyboardTargetChange: onKeyboardTargetChange).atticDesign(AtticDesignContext(mode: mode)))
        } else {
            hosting = NSHostingView(rootView: ComposerCard(model: model,
                onKeyboardTargetChange: onKeyboardTargetChange))
        }
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let window = KeyWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.becomeKey()
        windows.append(window)
        spin()
        let field = try XCTUnwrap(model.editor.textView, "the title field is live")
        window.makeFirstResponder(field)
        spin()
        return (window, hosting, field)
    }

    private func key(_ window: NSWindow, _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        spin(0.1)
    }

    private func typeKeys(_ field: NSTextView, _ text: String) {
        field.insertText(text, replacementRange: field.selectedRange())
        spin(0.1)
    }

    func testA11yWritingFieldKeepsItsSpokenNameInTheHostedComposer() throws {
        let (_, hosting, _) = try mountForKeys(on: .tasks(.now))
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        func descendants(_ node: AnyObject) -> [AnyObject] {
            [node] + ((node.accessibilityChildren?() ?? nil) ?? []).flatMap { descendants($0 as AnyObject) }
        }
        let writing = try XCTUnwrap(descendants(hosting).first {
            $0.accessibilityIdentifier?() == "composer-writing"
        }, "the shared writing field must be in the hosted accessibility tree")
        XCTAssertTrue(["AXTextField", "AXTextArea"].contains(writing.accessibilityRole?()?.rawValue ?? ""))
        XCTAssertEqual(writing.accessibilityLabel?(), String(localized: "Notes"))
    }

    /// The full Tasks page and its overlaid card share a key window. A
    /// printable key belongs to the card on either tab, never to Find.
    func testTypingInOpenTaskComposerDoesNotReachSearchOnDoneOrNow() throws {
        try requireKeyWindowTests()
        let composer = try XCTUnwrap(model)
        let size = CGSize(width: AtticLayout.panelSize.width, height: 520)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let route = PanelComposerRoute(
            open: { page, kind in composer.open(on: page, as: kind) },
            isOpen: { composer.isOpen }
        )

        for tab in [TasksTab.done, .now] {
            page.select(tab: tab)
            composer.open(on: .tasks(tab))
            let host = NSHostingView(rootView: TasksPage(
                model: page, store: tasks, layout: layout, addBarFocused: .constant(false)
            )
            .environment(\.panelComposer, route)
            .overlay(alignment: .bottomTrailing) { ComposerCard(model: composer) }
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
            let window = KeyWindow(
                contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.becomeKey()
            windows.append(window)
            spin(0.4)

            let field = try XCTUnwrap(composer.editor.textView)
            XCTAssertTrue(window.makeFirstResponder(field))
            spin(0.1)
            XCTAssertTrue(window.firstResponder === field, "\(tab): composer starts with the keyboard")
            for (letter, code) in [("c", UInt16(8)), ("a", UInt16(0)), ("t", UInt16(17))] {
                key(window, letter, code: code)
                XCTAssertTrue(window.firstResponder === field, "\(tab): \(letter) did not steal the caret")
                XCTAssertEqual(page.searchQuery(for: tab), "", "\(tab): \(letter) never entered Find")
            }
            XCTAssertEqual(page.addBar.text, "cat", "\(tab): the card receives the typed text")
            composer.close(atOnce: true)
            window.contentView = nil
            window.close()
            page.addBar = TaskAddBarText(text: "")
        }
    }

    func testPriorityWidensFoldsItsNeighboursAndEscapeHasTwoSteps() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep priority !")
        @MainActor func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        @MainActor func element(_ id: String) -> AnyObject? {
            hosting.layoutSubtreeIfNeeded()
            return elements(hosting).first { $0.accessibilityIdentifier?() == id }
        }
        let create = try XCTUnwrap((element("composer-create") as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        let priority = try XCTUnwrap(element("composer-chip-priority"))
        XCTAssertTrue(priority.accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertNotNil(element("composer-priority-low"), "choices widen in the card")
        XCTAssertEqual(model.values.priority, .medium, "typed ! keeps the existing parser meaning")
        XCTAssertNil(element("composer-chip-date"))
        XCTAssertNil(element("composer-chip-tags"))
        XCTAssertNotNil(element("composer-create"))
        window.makeFirstResponder(field)
        key(window, "\u{1b}", code: 53)
        XCTAssertTrue(model.isOpen, "first Escape closes only the choices")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
        key(window, "\u{1b}", code: 53)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep priority !")
        model.open(on: .tasks(.now)); spin()
        XCTAssertTrue(try XCTUnwrap(element("composer-chip-priority")).accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertTrue(try XCTUnwrap(element("composer-priority-high")).accessibilityPerformPress?() ?? false)
        spin()
        XCTAssertEqual(model.values.priority, .high)
        XCTAssertNil(element("composer-priority-high"), "picking closes the levels")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
        let restoredCreate = try XCTUnwrap((element("composer-create") as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        XCTAssertEqual(restoredCreate, create, "Create stays in place")

    }

    func testReturnInTheTitleCreatesAndTheCardStaysOpenInTheTitle() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Call Sam")
        key(window, "\r", code: 36)
        XCTAssertEqual(liveTasks().map(\.title), ["Call Sam"])
        XCTAssertTrue(model.isOpen, "P4: the card stays open")
        XCTAssertTrue(window.firstResponder === field, "ready for the next one")
        XCTAssertEqual(field.string, "")
        XCTAssertTrue(opened.isEmpty)
    }

    /// Accepted P4 (3 Nov): all of the card's chips and Create are keyboard
    /// reachable after the writing line. Reverse traversal returns to Title.
    func testTabAndShiftTabStayInsideTheCard() throws {
        var target: ComposerCard.KeyboardTarget = .outside
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { target = $0 })
        typeKeys(field, "Call Sam")
        @MainActor func inWriting() -> Bool {
            guard let editor = window.firstResponder as? NSTextView, editor !== field else { return false }
            return (editor.delegate as? NSView)?.isDescendant(of: hosting) ?? editor.isDescendant(of: hosting)
        }
        // Pass events through NSApplication: the card's native Tab monitor
        // runs there, before AppKit's default key-view traversal.
        func tab(back: Bool = false) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: back ? .shift : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: back ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48)!
                NSApp.postEvent(event, atStart: false)
            }
            var sent = 0
            while sent < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                sent += 1
            }
            spin(0.15)
        }
        func focused(_ expected: ComposerCard.KeyboardTarget) -> Bool {
            guard target == expected else { return false }
            switch expected {
            case .title: return window.firstResponder === field
            case .writing: return inWriting()
            case .clearFiles, .chip, .create:
                // SwiftUI's KeyViewProxy is the native first responder. AX
                // focus in an inactive XCTest host reports false for every
                // control, including the active writing field.
                guard let responder = window.firstResponder as? NSView else { return false }
                return responder.isDescendant(of: hosting) && responder !== field
            case .outside: return false
            }
        }
        tab()
        XCTAssertTrue(focused(.writing), "Tab from the title goes to the writing line, not out of the card")
        tab(back: true)
        XCTAssertTrue(focused(.title), "⇧Tab from writing returns to Title")
        tab()
        XCTAssertTrue(focused(.writing))
        for (stop, id) in [(ComposerCard.KeyboardTarget.chip(.date), "composer-chip-date"),
                           (.chip(.priority), "composer-chip-priority"),
                           (.chip(.tags), "composer-chip-tags"),
                           (.create, "composer-create")] {
            tab()
            XCTAssertTrue(focused(stop), "Tab moves onto \(id) in P4 order")
        }
        for (stop, id) in [(ComposerCard.KeyboardTarget.chip(.tags), "composer-chip-tags"),
                           (.chip(.priority), "composer-chip-priority"),
                           (.chip(.date), "composer-chip-date")] {
            tab(back: true)
            XCTAssertTrue(focused(stop), "⇧Tab moves onto \(id) in reverse")
        }
        tab(back: true)
        XCTAssertTrue(focused(.writing), "⇧Tab from Date returns to writing")
        tab(back: true)
        XCTAssertTrue(focused(.title), "⇧Tab from writing returns to Title")
        XCTAssertEqual(page.addBar.text, "Call Sam")
        XCTAssertTrue(liveTasks().isEmpty, "keyboard traversal does not submit the draft")
    }

    func testBG10ShiftTabFromTitleExitsBackwardsWithoutEnteringWriting() throws {
        var target: ComposerCard.KeyboardTarget = .outside
        let (_, _, field) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { target = $0 })
        field.insertBacktab(nil)
        spin()
        XCTAssertNotEqual(target, .writing, "BG-10: Shift-Tab from Title must exit backwards")
    }

    func testBG70MarkedTextKeepsBothDirectionsOfTabInTheInputMethod() throws {
        var targets: [ComposerCard.KeyboardTarget] = []
        let (window, _, field) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { targets.append($0) })
        field.insertTab(nil)
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(writing === field, "the IME test must focus the Writing field")
        for backwards in [false, true] {
            window.makeFirstResponder(writing)
            writing.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(writing.hasMarkedText(), "test must enter native IME composition")
            let before = targets.count
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: backwards ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
            NSApp.postEvent(event, atStart: false)
            var dispatched = 0
            while dispatched < 64,
                  let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                dispatched += 1
            }
            spin(0.1)
            XCTAssertEqual(targets.count, before, "BG-70: a marked-text Tab must not ask the composer to navigate")
            XCTAssertTrue(window.firstResponder === writing, "composition owns keyboard focus")
            writing.unmarkText()
        }
    }

    /// Opus R-14: the Tab boundary does not swap the delegate of the window's
    /// shared field editor, not even for the length of the key. Every field in
    /// the window uses that one text view; while it is swapped, a reply from the
    /// input method (a commit, a later `insertTab:`) goes to the stand-in.
    func testTheTabBoundaryNeverSwapsTheSharedFieldEditorsDelegate() throws {
        var targets: [ComposerCard.KeyboardTarget] = []
        let (window, _, field) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { targets.append($0) })
        field.insertTab(nil)
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(writing === field)
        let editorDelegate = writing.delegate
        XCTAssertNotNil(editorDelegate)
        for backwards in [false, true] {
            window.makeFirstResponder(writing)
            writing.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(writing.hasMarkedText())
            let swallowed = ComposerInputMethod.swallowedTabCommands
            let before = targets.count
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: backwards ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
            // The key itself, through the monitor and the text view, with the main
            // queue not drained: the editor still has its own delegate.
            NSApp.sendEvent(event)
            XCTAssertTrue(writing.delegate === editorDelegate,
                          "the field editor's delegate is its own right after the key (\(String(describing: writing.delegate)))")
            spin(0.1)
            XCTAssertTrue(writing.delegate === editorDelegate, "and after the turn")
            XCTAssertEqual(ComposerInputMethod.swallowedTabCommands, swallowed + 1, "the Tab command was still answered with nothing")
            XCTAssertEqual(targets.count, before, "the composer's keyboard does not move")
            XCTAssertTrue(window.firstResponder === writing)
            writing.unmarkText()
        }
    }

    /// R-14: a delayed input-method reply commits through the real control,
    /// then sends its unhandled Tab command after a main-queue turn. The
    /// control still owns its editor and publishes every committed character.
    func testADelayedTabCommandKeepsTheCommitAndOnlyGuardsItsOwnField() throws {
        let (window, host, titleField) = try mountForKeys(on: .tasks(.now))
        titleField.insertTab(nil)
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        let control = try XCTUnwrap(writing.delegate as? NSTextField)
        for backwards in [false, true] {
            XCTAssertTrue(window.makeFirstResponder(control))
            writing.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            ComposerInputMethod.holdTabCommands(on: writing)
            XCTAssertTrue(control.currentEditor() === writing)
            writing.insertText("語", replacementRange: NSRange(location: NSNotFound, length: 0))
            let committed = writing.string
            XCTAssertEqual(model.writing, committed, "the composition commits to the model immediately")
            spin(0.1)
            let swallowed = ComposerInputMethod.swallowedTabCommands
            writing.doCommand(by: backwards ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:)))
            XCTAssertEqual(ComposerInputMethod.swallowedTabCommands, swallowed + 1, "a later Tab command still ends here")
            XCTAssertEqual(model.writing, committed)
            XCTAssertTrue(control.currentEditor() === writing)
            XCTAssertTrue(window.firstResponder === writing)
        }
        // A second control uses the very same window field editor. Its
        // commands must go to its own delegate, never the composer's guard.
        let other = NSTextField(string: "other")
        other.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        host.addSubview(other)
        ComposerInputMethod.holdTabCommands(on: writing)
        XCTAssertTrue(window.makeFirstResponder(other))
        let otherEditor = try XCTUnwrap(other.currentEditor() as? NSTextView)
        XCTAssertTrue(otherEditor === writing)
        XCTAssertTrue(otherEditor.delegate as? NSTextField === other)
        let swallowed = ComposerInputMethod.swallowedTabCommands
        otherEditor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(other.stringValue.contains("!"))
        otherEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(ComposerInputMethod.swallowedTabCommands, swallowed, "another field's Tab is not intercepted")
    }

    private func writingControl(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityIdentifier() == "composer-writing" { return field }
        return view.subviews.lazy.compactMap { self.writingControl(in: $0) }.first
    }

    /// A 2× capture of the actual field, used for ink checks and visual proof.
    private func writingBitmap(in view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.alignmentRect(forFrame: view.bounds)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(bounds.width * 2)), pixelsHigh: Int(ceil(bounds.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    /// Compare translucent ink against the same light or dark surface.
    private func writingInk(in view: NSView, background: CGFloat = 1) throws -> [CGFloat] {
        let bitmap = try writingBitmap(in: view)
        var ink = [CGFloat](repeating: background, count: 3)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                for (index, value) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                    let component = background * (1 - color.alphaComponent) + value * color.alphaComponent
                    ink[index] = background == 1 ? min(ink[index], component) : max(ink[index], component)
                }
            }
        }
        return ink
    }

    /// The field-specific IME boundary preserves the writing line's existing
    /// native commands, including Shift-Return and the two submit routes.
    func testWritingKeepsNewlineSubmitAndEscapeCommands() throws {
        var target: ComposerCard.KeyboardTarget = .outside
        let (window, host, titleField) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { target = $0 })
        func writingKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!
                NSApp.sendEvent(event)
            }
            spin(0.1)
        }
        typeKeys(titleField, "Task with writing")
        let control = try XCTUnwrap(writingControl(in: host))
        XCTAssertTrue(window.makeFirstResponder(control), "native focus can enter writing before any text is typed")
        spin()
        XCTAssertEqual(target, .writing)
        var writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(writing === titleField)
        writing.insertText("first", replacementRange: writing.selectedRange())
        writingKey("\r", code: 36, modifiers: .shift)
        writing.insertText("second", replacementRange: writing.selectedRange())
        XCTAssertEqual(model.writing, "first\nsecond")
        XCTAssertTrue(liveTasks().isEmpty, "Shift-Return writes a newline without submitting")
        writingKey("\r", code: 36)
        spin(0.3)
        XCTAssertEqual(liveTasks().count, 1)
        XCTAssertEqual(model.writing, "")
        XCTAssertTrue(window.firstResponder === titleField, "Return readies the empty title")
        typeKeys(titleField, "Kept draft")
        titleField.insertTab(nil)
        spin()
        writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        writing.insertText("kept writing", replacementRange: writing.selectedRange())
        writingKey("\u{1b}", code: 53)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Kept draft")
        XCTAssertEqual(model.writing, "kept writing")
        model.open(on: .tasks(.now))
        spin()
        titleField.insertTab(nil)
        spin()
        XCTAssertEqual(target, .writing)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as? NSTextField === control)
        XCTAssertTrue(model.canCreate)
        writingKey("\r", code: 36, modifiers: .command)
        spin(0.3)
        XCTAssertEqual(liveTasks().count, 2)
        XCTAssertEqual(opened.count, 1, "Command-Return opens the created task")
        XCTAssertFalse(model.isOpen)
    }

    func testReplacingWritingDuringCompositionKeepsTheNewDraft() throws {
        let (window, _, titleField) = try mountForKeys(on: .tasks(.now))
        titleField.insertTab(nil)
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(writing === titleField)
        writing.setMarkedText("old composition", selectedRange: NSRange(location: 15, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(writing.hasMarkedText())
        model.writing = "replacement draft"
        spin()
        XCTAssertEqual(model.writing, "replacement draft", "the old editing callback cannot replace the new draft")
        XCTAssertEqual(writing.string, "replacement draft")
        XCTAssertFalse(writing.hasMarkedText(), "the replaced draft no longer has an active composition")
    }

    /// Keep the native bridge's placeholder ink and line sizing equal to the
    /// original SwiftUI field, including wrapping and the five-line cap.
    func testWritingLineKeepsTheExistingInkAndLineHeights() throws {
        for mode in AtticDesignContext.Mode.allCases {
            let (window, host, _) = try mountForKeys(on: .tasks(.now), mode: mode)
            defer { window.contentView = nil; window.close() }
            let field = try XCTUnwrap(writingControl(in: host))
            let cases = [""] + (1...6).map { Array(repeating: "a line", count: $0).joined(separator: "\n") }
                + [Array(repeating: "a sentence long enough to wrap", count: 8).joined(separator: " ")]
            let wrapping = [10, 15, 18, 20].map { String(repeating: "ab ", count: $0) }
            for text in cases + wrapping {
                model.writing = text
                spin(0.1)
                host.layoutSubtreeIfNeeded()
                let width = field.alignmentRect(forFrame: field.frame).width
                let reference = NSHostingView(rootView:
                    TextField(String(localized: "Notes"), text: .constant(text), axis: .vertical)
                        .textFieldStyle(.plain).font(AtticTextStyle.composerWriting.font)
                        .foregroundStyle(AtticSurfaceInk.toneInk(.nextEventTime, tokens: AtticDesignContext(mode: mode).tokens).color)
                        .lineLimit(1...ComposerMetrics.writingMaxLines)
                        .frame(minHeight: ComposerMetrics.writingMinHeight, alignment: .topLeading)
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .atticDesign(AtticDesignContext(mode: mode)))
                reference.setFrameSize(reference.fittingSize)
                reference.layoutSubtreeIfNeeded()
                if text.isEmpty || text == "a line" {
                    let surface: CGFloat = mode == .light ? 1 : 0
                    let actual = try writingInk(in: field, background: surface)
                    let expected = try writingInk(in: reference, background: surface)
                    print("R14_INK mode=\(mode) rendered empty=\(text.isEmpty) actual=\(actual) legacy=\(expected)")
                    for index in 0..<3 {
                        XCTAssertEqual(actual[index], expected[index], accuracy: 1.0 / 255,
                                       "the writing line keeps the original field's ink (empty \(text.isEmpty))")
                    }
                }
                if mode == .light, text.components(separatedBy: "\n").count == 5,
                   ProcessInfo.processInfo.environment["ATTIC_R13_RENDER"] != nil {
                    let directory = r13RenderDirectory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for (name, view) in [("writing-native.png", field as NSView), ("writing-legacy.png", reference as NSView)] {
                        let bitmap = try writingBitmap(in: view)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: directory.appendingPathComponent(name))
                    }
                }
                print("R14_HEIGHT actual=\(field.frame.height) legacy=\(reference.fittingSize.height) cell=\(field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? -1)")
                XCTAssertEqual(field.frame.height, reference.fittingSize.height, accuracy: 1,
                               "same writing height for \(text.components(separatedBy: "\n").count) lines / \(text.count) characters")
            }
        }
    }

    /// Opus R-6 = Dot R-5, and R-9: a Tab typed while text is marked goes the
    /// normal way (the text view offers it to the input method first), and the
    /// Tab command a key the input method leaves alone becomes (`insertTab:`,
    /// `insertBacktab:`) neither inserts a tab nor moves the composer's
    /// keyboard (BG-70). Here the source is the Air's plain layout: it does not
    /// consume the key, as an input method that commits and passes Tab on does.
    func testMarkedTextTabAndBacktabAreAnsweredWithNothingAndKeepTheComposerFocus() throws {
        var targets: [ComposerCard.KeyboardTarget] = []
        let (window, _, field) = try mountForKeys(on: .tasks(.now), onKeyboardTargetChange: { targets.append($0) })
        field.insertTab(nil)
        spin()
        let writing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(writing === field)
        func send(backwards: Bool) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: backwards ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
            NSApp.postEvent(event, atStart: false)
            var dispatched = 0
            while dispatched < 64,
                  let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                dispatched += 1
            }
            spin(0.1)
        }
        for backwards in [false, true] {
            window.makeFirstResponder(writing)
            writing.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(writing.hasMarkedText())
            let before = targets.count
            let swallowed = ComposerInputMethod.swallowedTabCommands
            let text = writing.string
            try send(backwards: backwards)
            XCTAssertEqual(ComposerInputMethod.swallowedTabCommands, swallowed + 1,
                           "the \(backwards ? "Shift-Tab" : "Tab") went the normal way and its command was answered with nothing")
            XCTAssertEqual(writing.string, text, "no tab is inserted")
            XCTAssertTrue(writing.hasMarkedText(), "composition is untouched")
            XCTAssertEqual(targets.count, before, "the composer's keyboard does not move")
            XCTAssertTrue(window.firstResponder === writing, "composition keeps the keyboard")
            XCTAssertFalse(writing.delegate.map { String(describing: Swift.type(of: $0)).contains("TabCommandGuard") } ?? false,
                           "the boundary is taken down after the key")
            writing.unmarkText()
        }
        // Committed: Tab navigates again.
        let after = targets.count
        window.makeFirstResponder(writing)
        let swallowed = ComposerInputMethod.swallowedTabCommands
        try send(backwards: false)
        XCTAssertEqual(ComposerInputMethod.swallowedTabCommands, swallowed, "no marked text: nothing is swallowed")
        XCTAssertGreaterThan(targets.count, after, "after the commit Tab moves the composer's keyboard")
    }

    /// Opus R-8 (P1), the dead end: files staged on Tasks wait for a task, and
    /// a Note made where Task cannot be reached (Notes) is made normally: the
    /// files stay staged, shown again on the Tasks card's chip, and are never
    /// attached to the note. The quick-note route (⇧⌘N: `as: .note`) is
    /// never refused either.
    func testStagedTaskFilesDoNotBlockANoteWhereTaskCannotBeReached() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r8-\(UUID().uuidString).txt")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        model.open(on: .tasks(.now))
        type("Draft with a file")
        page.addComposerFiles(urls: [file])
        XCTAssertEqual(page.addBarState.fileNames.count, 1)
        model.close()
        for (route, requested) in [("Notes, +", nil), ("Notes, ⇧⌘N", ComposerKind.note), ("Tasks, ⇧⌘N", .note)] as [(String, ComposerKind?)] {
            let onTasks = route.hasPrefix("Tasks")
            model.open(on: onTasks ? .tasks(.now) : .notes, as: requested)
            XCTAssertEqual(model.kind, .note, route)
            type("A note via \(route)")
            let made = await model.create()
            XCTAssertTrue(made, "\(route): a note is made, not refused behind a chip nobody can reach")
            XCTAssertEqual(page.addBarState.fileNames.count, 1, "\(route): the Task's files stay staged")
            model.close()
        }
        XCTAssertEqual(notes.notes.filter { $0.deletedAt == nil }.count, 3)
        XCTAssertTrue(liveTasks().allSatisfy { $0.attachments.isEmpty }, "the staged file went nowhere while notes were made")
        XCTAssertTrue(page.toasts.current == nil, "nothing was refused")
        // The Tasks card shows the chip again, and the task takes the file.
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .task)
        XCTAssertNotNil(page.composerFilesValue)
        type("Task for the file")
        await XCTAssertTrueAsync(await model.create())
        try await waitForAttachment(of: "Task for the file")
        XCTAssertTrue(page.addBarState.fileNames.isEmpty)
    }

    /// Optional 2× captures of the real card for the hunt's HTML proof.
    private func captureR13NoteDraft(_ route: String, card: ComposerModel? = nil) throws {
        guard let phase = ProcessInfo.processInfo.environment["ATTIC_R13_RENDER"] else { return }
        let design = AtticDesignContext(mode: .light, reduceTransparency: true)
        let host = NSHostingView(rootView: ComposerCard(model: card ?? model, drawsChrome: false)
            .atticDesign(design).background(design.tokens.panel.base.color))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        spin(0.2)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = r13RenderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = route.hasPrefix("R5-") ? route : (route.hasPrefix("Tasks") ? "quick-note" : "notes")
            + (route.contains("restored") ? "-restored-task" : "")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(phase)-\(name).png"))
        print("R13_RENDER_DIR \(directory.path)")
    }

    /// Opus R-13: a note made where Task cannot be reached (Notes, or ⇧⌘N)
    /// starts from its own draft. It does not take the Task draft's title and
    /// leave the Task's files on an empty draft; the Task's title and files
    /// are there when the person is back on Task.
    func testANoteWhereTaskIsUnreachableStartsFromItsOwnDraftAndTheTaskDraftStaysWithItsFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r13-\(UUID().uuidString).txt")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        for (route, requested) in [("Notes, +", nil), ("Tasks, ⇧⌘N", ComposerKind.note)] as [(String, ComposerKind?)] {
            model.open(on: .tasks(.now))
            model.choose(.task)
            type("Invoice for Bob")
            page.addComposerFiles(urls: [file])
            XCTAssertEqual(page.addBarState.fileNames.count, 1)
            model.close()
            let notesBefore = notes.notes.filter { $0.deletedAt == nil }.count
            model.open(on: route.hasPrefix("Tasks") ? .tasks(.now) : .notes, as: requested)
            try captureR13NoteDraft(route)
            XCTAssertEqual(model.kind, .note, route)
            XCTAssertEqual(page.addBar.text, "", "\(route): the note starts from its own, empty draft")
            XCTAssertFalse(model.canCreate, "\(route): the Task's title is not the note's")
            type("A note, \(route)")
            let made = await model.create()
            XCTAssertTrue(made, route)
            XCTAssertEqual(notes.notes.filter { $0.deletedAt == nil }.count, notesBefore + 1)
            XCTAssertEqual(page.addBarState.fileNames.count, 1, "\(route): the files stay staged")
            model.close()
            // Back on Task: the draft is whole, title and files together.
            model.open(on: .tasks(.now))
            try captureR13NoteDraft(route + " restored")
            XCTAssertEqual(model.kind, .task, route)
            XCTAssertEqual(page.addBar.text, "Invoice for Bob", "\(route): the Task draft kept its title")
            XCTAssertEqual(page.addBarState.fileNames.count, 1, "\(route): and its file")
            XCTAssertFalse(notes.notes.filter { $0.deletedAt == nil }.contains { $0.title == "Invoice for Bob" })
            // Leave the Task draft for the next route, files and all.
            page.addBarState.clearDraft()
            page.addBarState.files = []
            model.clearDraft()
            model.close()
        }
    }

    /// R-13: the other way round. A note draft being written on Notes is kept
    /// when the person goes to Tasks, where the card still shows it; Task and
    /// Note then switch between their own drafts, not each other's words.
    func testANoteDraftAndTheTaskDraftWithFilesDoNotTradeWords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r13b-\(UUID().uuidString).txt")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        model.open(on: .tasks(.now))
        type("Invoice for Bob")
        page.addComposerFiles(urls: [file])
        model.close()
        model.open(on: .notes)
        type("Half a note")
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(model.kind, .note, "a kept note draft is shown first")
        XCTAssertEqual(page.addBar.text, "Half a note")
        model.choose(.task)
        XCTAssertEqual(page.addBar.text, "Invoice for Bob", "Task has its own draft back, not the note's words")
        XCTAssertEqual(page.addBarState.fileNames.count, 1, "with its file")
        model.choose(.note)
        XCTAssertEqual(page.addBar.text, "Half a note", "and the note keeps its own")
        XCTAssertEqual(page.addBarState.fileNames.count, 1, "the Task's file stayed staged throughout")
        model.choose(.task)
        model.clearDraft() // An intentionally empty title still owns the staged file.
        model.choose(.note)
        XCTAssertEqual(page.addBar.text, "Half a note")
        model.choose(.task)
        XCTAssertEqual(page.addBar.text, "", "the file-only Task draft still has its own words")
        XCTAssertEqual(page.addBarState.fileNames.count, 1)
        model.choose(.note)
        XCTAssertEqual(page.addBar.text, "Half a note")
    }

    func testANoteAfterARefusedKindSwitchPreservesTheWholeStagingTaskDraft() throws {
        model.open(on: .tasks(.now))
        type("Invoice for Bob")
        page.addBar.picked.tags = ["billing"]
        model.writing = "Task writing"
        page.addBarState.history.checkpoint(TaskAddBarText(text: "Invoice"), selection: NSRange(location: 7, length: 0))
        let draft = page.addBar
        let history = page.addBarState.history
        let generation = page.addBarState.filesGeneration
        page.addBarState.stagingFiles = 1
        model.choose(.note) // Still the shared draft; this route would refuse submission.
        model.close()
        model.open(on: .notes)
        XCTAssertEqual(page.addBar.text, "")
        XCTAssertEqual(model.writing, "")
        XCTAssertTrue(page.addBar.picked.tags.isEmpty)
        XCTAssertEqual(page.addBarState.stagingFiles, 1)
        XCTAssertEqual(page.addBarState.filesGeneration, generation)
        model.close()
        model.open(on: .tasks(.now))
        XCTAssertEqual(page.addBar, draft)
        XCTAssertEqual(model.writing, "Task writing")
        XCTAssertEqual(page.addBarState.history, history, "Task typing Undo stays with its draft")
        XCTAssertEqual(page.addBarState.stagingFiles, 1)
        XCTAssertEqual(page.addBarState.filesGeneration, generation)
    }

    /// Opus R-8, the variant: a file dropped on the add bar zone opens the
    /// card on Task, though a Note draft is kept (it would hide the file
    /// behind a kind that has no chip, and refuse Return).
    func testAFileDroppedOnTheAddBarOpensTheCardOnTaskOverAKeptNoteDraft() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r8-drop-\(UUID().uuidString).txt")
        try "dropped".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        model.open(on: .tasks(.now))
        model.choose(.note)
        type("A kept note draft")
        model.close()
        XCTAssertEqual(model.kind, .note)
        XCTAssertTrue(model.hasDraft)
        let route = PanelComposerRoute(open: { [model] page, kind in model?.open(on: page, as: kind) })
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        XCTAssertTrue(page.dropFilesOnComposer([provider], card: route), "the card took it")
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.kind, .task, "the card shows Task, where the file is")
        for _ in 0..<100 where page.addBarState.stagingFiles > 0 || page.addBarState.files.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(page.addBarState.fileNames.count, 1)
        XCTAssertNotNil(page.composerFilesValue, "and its chip is drawn")
        page.clearComposerFiles()
    }

    /// Waits for the import a created task started and checks it landed.
    private func waitForAttachment(of title: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<250 {
            if liveTasks().first(where: { $0.title == title })?.attachments.isEmpty == false { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the file never landed on \(title)", file: file, line: line)
    }

    /// Dot R-4: a file staged for a Task must not be consumed or inherited by
    /// a Note made from the same shared draft where the file can be seen. The
    /// note does not silently leave the file behind for a later, unrelated
    /// task: it waits, the file stays staged and removable, and the person is
    /// told.
    func testStagedTaskFilesDoNotSurviveANoteSubmitIntoALaterTask() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r4-\(UUID().uuidString).txt")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        model.open(on: .tasks(.now))
        type("Draft with a file")
        page.addComposerFiles(urls: [file])
        XCTAssertEqual(page.addBarState.fileNames.count, 1)
        model.choose(.note)
        let made = await model.create()
        XCTAssertFalse(made, "a Note must not use up a draft that holds a Task's staged file")
        XCTAssertTrue(notes.notes.filter { $0.deletedAt == nil }.isEmpty)
        XCTAssertEqual(page.addBarState.fileNames.count, 1, "the file stays staged and removable")
        XCTAssertNotNil(page.toasts.current, "the person is told why nothing was made")
        // Back on Task the file is shown and goes onto the task it was staged for.
        model.choose(.task)
        XCTAssertNotNil(page.composerFilesValue)
        await XCTAssertTrueAsync(await model.create())
        XCTAssertTrue(page.addBarState.fileNames.isEmpty, "the Task took its file")
        // The import runs on its own task: wait for it before the file goes
        // (the `defer`), and check that the attachment landed.
        try await waitForAttachment(of: "Draft with a file")
    }

    func testBG11ImagePasteInSharedTaskTitleStagesAndAttachesTheFile() throws {
        let (_, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Screenshot to review")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        XCTAssertTrue(pasteboard.setData(png, forType: .png))
        let providers = AtticPastedFiles.providers(from: pasteboard)
        XCTAssertEqual(providers.count, 1, "the native paste route recognizes the copied image")
        let nativeTitle = try XCTUnwrap(field as? AtticTokenTextView)
        XCTAssertTrue(nativeTitle.owner?.parent.actions.pasteFiles?(providers) == true,
                      "BG-11: the shared title must wire its file-paste action")
        for _ in 0..<50 where page.addBarState.fileNames.isEmpty { spin(0.02) }
        XCTAssertEqual(page.addBarState.fileNames.count, 1, "BG-11: paste should stage the image in the shared task card")
        model.submit(openingPage: false)
        for _ in 0..<100 where liveTasks().first?.attachments.count != 1 { spin(0.03) }
        XCTAssertEqual(liveTasks().first?.attachments.count, 1, "the created task owns the pasted image")
    }

    func testBG11SubmitKeepsTheDraftWhileFileStagingIsInFlight() throws {
        model.open(on: .tasks(.now))
        type("Wait for the photo")
        page.addBarState.stagingFiles = 1
        model.submit(openingPage: false)
        spin(0.1)
        XCTAssertTrue(liveTasks().isEmpty, "submitting before a promised image arrives cannot silently drop it")
        XCTAssertEqual(page.addBar.text, "Wait for the photo")
        page.addBarState.stagingFiles = 0
        model.submit(openingPage: false)
        for _ in 0..<60 where liveTasks().isEmpty { spin(0.02) }
        XCTAssertEqual(liveTasks().first?.title, "Wait for the photo")
    }

    func testBG11SharedCardShowsAndCanRemoveStagedFiles() throws {
        let (_, hosting, _) = try mountForKeys(on: .tasks(.now), captureSurface: true)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        // Optional 2× offscreen evidence for the hunt's plain HTML review.
        func capture(_ filename: String) throws {
            guard ProcessInfo.processInfo.environment["ATTIC_BG11_RENDER_DIR"] != nil else { return }
            // Keep the 2× offscreen captures in the test host's sandboxed
            // Documents folder: XCTest removes its temporary directory at exit.
            let directory = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                .appendingPathComponent("BG11Renders", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            print("BG11_RENDER_DIR \(directory.path)")
            hosting.layoutSubtreeIfNeeded()
            let bounds = hosting.bounds
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = bounds.size
            hosting.cacheDisplay(in: bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(filename))
        }

        try capture("bg11-before.png")
        page.addComposerFiles(urls: [URL(fileURLWithPath: "/tmp/queued-photo.png")])
        spin(0.3)
        XCTAssertEqual(page.addBarState.fileNames, ["queued-photo.png"])
        try capture("bg11-after.png")

        func descendants(_ node: AnyObject) -> [AnyObject] {
            [node] + ((node.accessibilityChildren?() ?? nil) ?? []).flatMap { descendants($0 as AnyObject) }
        }
        let remove = try XCTUnwrap(descendants(hosting).first {
            $0.accessibilityIdentifier?() == "composer-pending-files"
        }, "a staged attachment must be reviewable in the shared card")
        XCTAssertEqual(remove.accessibilityRole?()?.rawValue, "AXButton")
        XCTAssertTrue((remove.accessibilityLabel?() ?? "").contains("queued-photo.png"),
                      "VoiceOver must identify which staged file this control removes")
        XCTAssertTrue(remove.accessibilityPerformPress?() ?? false,
                      "the visible Remove files control must discard staged files")
        spin(0.1)
        XCTAssertTrue(page.addBarState.fileNames.isEmpty)
        XCTAssertNil(descendants(hosting).first { $0.accessibilityIdentifier?() == "composer-pending-files" })
    }

    func testCommandReturnInTheTitleCreatesAndOpens() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Open me")
        key(window, "\r", code: 36, modifiers: .command)
        XCTAssertEqual(opened, liveTasks().map(\.id))
        XCTAssertEqual(opened.count, 1)
    }

    func testEscapeInTheTitleClosesAndKeepsTheDraft() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep me")
        key(window, "\u{1B}", code: 53)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(page.addBar.text, "Keep me")
        XCTAssertTrue(liveTasks().isEmpty)
    }

    /// Review B-4: Escape then Return at once (the shrink still drawing)
    /// creates nothing, and the keyboard has left the card.
    func testReturnRightAfterEscapeCreatesNothing() throws {
        let (window, _, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Keep me too")
        key(window, "\u{1B}", code: 53)
        key(window, "\r", code: 36)
        XCTAssertTrue(liveTasks().isEmpty)
        XCTAssertFalse(window.firstResponder === field, "the keyboard leaves the card as it closes")
        XCTAssertEqual(page.addBar.text, "Keep me too")
    }

    func testTabTakesASuggestionThenMovesOnFromTheTitle() throws {
        XCTAssertNotNil(library.createTasks([TaskDraft(title: "Seed", tags: ["home"])]))
        let (window, hosting, field) = try mountForKeys(on: .tasks(.now))
        typeKeys(field, "Buy #ho")
        XCTAssertNotNil(model.suggestion(focused: true))
        key(window, "\t", code: 48)
        XCTAssertTrue(page.addBar.text.hasPrefix("Buy #home"), page.addBar.text)
        XCTAssertTrue(window.firstResponder === field, "taking a suggestion keeps the keyboard in the title")
        // No list now: Tab moves on to the card's next control.
        typeKeys(field, " ")
        key(window, "\t", code: 48)
        let next = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertFalse(next === field)
        XCTAssertTrue(next.isDescendant(of: hosting))
    }

    func testReduceMotionMakesTheCardInstant() {
        AtticMotionPreference.systemReduceMotionOverride = true
        XCTAssertNil(ComposerMotion.animation())
        XCTAssertNil(ComposerMotion.animation(showing: false))
        AtticMotionPreference.systemReduceMotionOverride = false
        let level = AtticMotionPreference.level
        defer { AtticMotionPreference.level = level }
        AtticMotionPreference.level = .lively
        XCTAssertNotNil(ComposerMotion.animation())
    }

    /// The HTML's `cp` box: 54 → 578 design px, radius 32 → 44 (16 → 22 pt),
    /// curve 1.4, one progress for size and radius, on the bar's own corner.
    func testTheGrowRunsFromThePlusToTheCardOnOneProgress() {
        let card = CGSize(width: ComposerMetrics.width, height: 131)
        let closed = ComposerGrow.geometry(progress: 0, card: card)
        XCTAssertEqual(closed.size, CGSize(width: AtticControlSize.headerControl, height: AtticControlSize.headerControl))
        XCTAssertEqual(closed.cornerRadius, 16)
        let open = ComposerGrow.geometry(progress: 1, card: card)
        XCTAssertEqual(open.size, card)
        XCTAssertEqual(open.cornerRadius, 22)
        XCTAssertEqual(ComposerMetrics.radius, 22)
        let half = ComposerGrow.geometry(progress: 0.5, card: card)
        XCTAssertEqual(half.size.width, (27 + 289) / 2, accuracy: 0.01)
        XCTAssertEqual(half.cornerRadius, 19, accuracy: 0.01)
        XCTAssertEqual(ComposerGrow.geometry(progress: 2, card: card), open, "clamped")
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        XCTAssertEqual(ComposerGrow.anchor(layout: layout), PanelSharedBottomBar.plusInsets(layout: layout))
    }

    /// RC-7: the visible surface still travels from + to full size while the
    /// editor receives the final-size layout proposal at every progress step.
    func testGrowingComposerKeepsEditorLayoutStable() {
        let card = CGSize(width: ComposerMetrics.width, height: 130)
        for progress: CGFloat in [0.2, 0.5, 0.8] {
            var editorSize = CGSize.zero
            var surfaceSize = CGSize.zero
            let root = Color.clear
                .onGeometryChange(for: CGSize.self, of: \.size) { editorSize = $0 }
                .modifier(ComposerGrowFrame(progress: progress, card: card, drawn: true))
                .onGeometryChange(for: CGSize.self, of: \.size) { surfaceSize = $0 }
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: card),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(editorSize.width, card.width, accuracy: 0.5)
            XCTAssertEqual(editorSize.height, card.height, accuracy: 0.5)
            let expected = ComposerGrow.geometry(progress: progress, card: card).size
            XCTAssertEqual(surfaceSize.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(surfaceSize.height, expected.height, accuracy: 0.5)
            window.close()
        }
    }

    /// Review B-2: in the panel, Tab after the last row reaches the shown
    /// "+", never the add bar or its strip that the panel no longer draws.
    func testInThePanelTabReachesThePlusNotTheAddBar() {
        let a = UUID(), b = UUID()
        let stops = TasksTabOrder.stops(find: true, rows: [(a, []), (b, [])], strip: true, plus: true)
        XCTAssertEqual(stops, [.find, .row(a), .row(b), .plus])
        XCTAssertEqual(TasksTabOrder.next(after: .row(b), in: stops, forward: true), .plus)
        XCTAssertEqual(TasksTabOrder.next(after: .plus, in: stops, forward: true), .find)
        XCTAssertEqual(TasksTabOrder.stops(find: false, rows: [(a, [])], strip: false), [.row(a), .addBar], "hosted on its own: as before")
    }

    // MARK: The card

    private func host(_ kind: ComposerKind?, on composerPage: ComposerPage) -> NSHostingView<some View> {
        model.open(on: composerPage, as: kind)
        let view = NSHostingView(rootView: ComposerCard(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testFollowupChangingKindsClosesThePreviousKindsInlinePicker() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let view = host(.task, on: .calendar(selected: today))
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func element(_ id: String) -> AnyObject? {
            view.layoutSubtreeIfNeeded()
            return elements(view).first { $0.accessibilityIdentifier?() == id }
        }
        XCTAssertTrue(try XCTUnwrap(element("composer-chip-priority")).accessibilityPerformPress?() ?? false)
        spin(0.1)
        XCTAssertNotNil(element("composer-priority-low"))
        model.choose(.event); spin(0.1)
        model.choose(.task); spin(0.1)
        XCTAssertNil(element("composer-priority-low"), "switching kind closes its old inline picker")
        XCTAssertNotNil(element("composer-chip-date"))
        XCTAssertNotNil(element("composer-chip-tags"))
    }

    func testFollowupEventGetsLengthAndCalendarRowsAndGrowsTheListRoom() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        model.open(on: .calendar(selected: today), as: .event)
        await model.loadCalendars()
        type("Appointment tomorrow at 10am")
        let view = host(.event, on: .calendar(selected: today))
        spin(0.2)
        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        let all = elements(view)
        func frame(_ id: String) throws -> CGRect {
            let element = try XCTUnwrap(all.first { $0.accessibilityIdentifier?() == id }, id)
            return try XCTUnwrap(element.accessibilityFrame?())
        }
        let date = try frame("composer-chip-date"), length = try frame("composer-chip-length"), calendar = try frame("composer-chip-calendar")
        XCTAssertGreaterThan(abs(date.midY - length.midY), 20, "length has its own row")
        XCTAssertGreaterThan(abs(length.midY - calendar.midY), 20, "calendar has its own row")
        XCTAssertGreaterThan(view.fittingSize.height, ComposerMetrics.height + 40)
        // Option A (Accepted 2026-11-09): nothing at rest, a soft wash under the
        // pointer, and the open button still reads stronger than the hover.
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let tokens = AtticDesignContext(mode: mode, surface: .glass).tokens
            XCTAssertEqual(ComposerChipLook.fill(open: false, hovered: false, tokens: tokens).alpha, 0)
            XCTAssertEqual(ComposerChipLook.fill(open: false, hovered: true, tokens: tokens), tokens.ink(.heading).withAlpha(0.04))
            XCTAssertEqual(ComposerChipLook.fill(open: true, hovered: true, tokens: tokens), tokens.ink(.heading).withAlpha(0.06))
        }
        // The chip hugs its name (Accepted 2026-11-04: the Date hover was
        // far too wide); the row leaves a long name its room before Create.
        XCTAssertGreaterThan(try frame("composer-create").minX - calendar.minX, 150, "calendar names have room")
        let room = PanelComposerRoom()
        let overlay = NSHostingView(rootView: ComposerOverlay(model: model,
            layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 352, height: 520)), room: room)
            .frame(width: 352, height: 520))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 352, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = overlay; windows.append(window)
        spin(0.4); overlay.layoutSubtreeIfNeeded(); spin(0.1)
        XCTAssertEqual(room.height, view.fittingSize.height, accuracy: 1, "the inset follows the actual Event card")
    }

    func testTheCardKeepsTheTasksHeightExceptForEvents() {
        let task = host(nil, on: .calendar(selected: today)).fittingSize
        XCTAssertEqual(task.width, ComposerMetrics.width, accuracy: 0.5)
        var heights: [CGFloat] = []
        for kind in [ComposerKind.task, .event, .note] {
            model.choose(kind)
            let view = host(kind, on: .calendar(selected: today))
            heights.append(view.fittingSize.height)
        }
        XCTAssertEqual(heights[0], heights[2], accuracy: 1, "Task and Note keep the compact card")
        XCTAssertGreaterThan(heights[1], heights[0], "P4 supersedes the old same-height Event card")
        // P4: 9 + 20 + 5 + 15 + 5 + 28 + 8 = 90 (the design's 180 px).
        XCTAssertEqual(heights[0], ComposerMetrics.height, accuracy: 1)
        XCTAssertEqual(ComposerMetrics.height, 90)
    }

    /// B1 on screen: a title too long for one line wraps into the writing
    /// line's space, and the card keeps its 90 pt.
    func testALongTitleWrapsAndTheCardKeepsItsHeight() {
        let short = host(nil, on: .tasks(.now)).fittingSize.height
        type("Ring the plumber about the dripping kitchen tap before the weekend")
        let view = host(nil, on: .tasks(.now))
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); spin(0.05) }
        XCTAssertEqual(view.fittingSize.height, short, accuracy: 1, "the card keeps its height")
        @MainActor func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        XCTAssertNil(elements(view).first { $0.accessibilityIdentifier?() == "composer-writing" },
                     "the writing line gives its space to the title")
    }

    func testDateLabels() {
        let words: (DueDay) -> String = { _ in "Tomorrow" }
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: nil, time: nil, priority: nil, tags: []), kind: .task, words: words), "Date")
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: today, time: 990, priority: nil, tags: []), kind: .task, words: words), "Tomorrow, 16:30")
        XCTAssertEqual(ComposerCard.dateLabel(.init(title: "", day: today, time: nil, priority: nil, tags: []), kind: .event, words: words), "Tomorrow · All day")
        XCTAssertEqual(ComposerCard.length(90), "1 h 30")
        XCTAssertEqual(ComposerCard.length(30), "30 min")
    }
}

/// BT9: a real disk store and a new container/controller on every relaunch.
/// All paths and defaults belong to this fixture, never the app's store.
@MainActor
final class ComposerRecoveryTests: XCTestCase {
    private final class Failure { var on = false }
    private struct Session {
        let container: ModelContainer
        let library: AtticLibrary
        let page: TasksPageModel
        let composer: ComposerModel
    }
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let failure = Failure()

    override func setUp() async throws {
        root = ownedTemporaryDirectory(prefix: "ComposerRecoveryDisk")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ComposerRecoveryDisk.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
    private var drafts: ComposerDraftStore {
        ComposerDraftStore(defaults: defaults, taskRecoveryURL: root.appendingPathComponent("pending.json"))
    }
    private func launch(_ recovery: ComposerDraftStore? = nil) throws -> Session {
        ComposerRecoveryJournal.simulateProcessExitForTesting(recovery ?? drafts)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("files")))
        let failing = failure
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, persist: { context in
            if failing.on { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, attachmentFileStore: makeTestAttachmentFileStore()))
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let page = TasksPageModel(library: library)
        page.services.acknowledgementDelay = .seconds(3600)
        let composer = ComposerModel(tasks: page, services: ComposerServices(drafts: recovery ?? drafts))
        composer.open(on: .tasks(.now))
        // A simulated quit leaves the old controller's delayed command alive
        // in this test process. Abort it before the temporary store disappears;
        // it must never commit later or query a removed SQLite file.
        ownPageLifetime(page)
        return Session(container: container, library: library, page: page, composer: composer)
    }
    private func ownPageLifetime(_ page: TasksPageModel) {
        let failing = failure
        addTeardownBlock { @MainActor [weak page, failing] in
            failing.on = true
            page?.settlePendingCompletionAcknowledgements()
            if let page {
                for work in Array(page.composerAttachmentTasks.values) { _ = await work.value }
                await page.library.notes?.waitForAttachmentReconciliation()
            }
            await Task.yield()
        }
    }

    private func waitForFiles(_ session: Session) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.page.addBarState.stagingFiles > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.page.addBarState.stagingFiles, 0)
    }
    private func seedKeptBackupForCrash(_ kept: ComposerDraftStore.Draft) throws {
        let url = try XCTUnwrap(drafts.taskRecoveryURL)
        var disk = try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: Data(contentsOf: url))
        disk.draft = kept
        try drafts.persistTaskRecovery(JSONEncoder().encode(disk), url)
    }

    private func rows(_ session: Session) throws -> [TaskItem] {
        try ModelContext(session.container).fetch(FetchDescriptor<TaskItem>())
    }
    private func type(_ text: String, in session: Session) {
        session.page.addBar = TaskAddBarText(text: text)
        session.composer.writing = "Writing that must survive"
    }

    private func capturePersistenceNotice(_ session: Session, phase: String) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ComposerPersistenceRenders-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, mode) in [("light", AtticDesignContext.Mode.light), ("dark", .dark)] {
            let design = AtticDesignContext(mode: mode, reduceTransparency: true)
            let host = NSHostingView(rootView: VStack(spacing: 16) {
                ComposerCard(model: session.composer, drawsChrome: false)
                PanelNoticeStack(toasts: session.page.toasts, notice: nil, onRetry: {}, onDismissNotice: {})
            }.padding(16).frame(width: 360, height: 300, alignment: .top)
                .atticDesign(design).background(design.tokens.panel.base.color))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 360, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(phase)-\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(phase)-\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("CP_RENDER_DIR \(output.path)")
    }

    /// Compatibility guards use the unchanged wire layouts, not the new
    /// journal's convenience save APIs. Every model opens a real temp store.
    func testOriginalPersistenceLayoutsStillMigrateWithoutLosingEitherOwner() throws {
        let parent = root!
        let oldDraft = Data(#"{"title":"Old note","writing":"Old writing","kind":"note"}"#.utf8)
        for format in 0..<5 {
            defaults.removePersistentDomain(forName: suite)
            root = parent.appendingPathComponent("format-\(format)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var legacyID: UUID?
            switch format {
            case 0:
                try Data(#"{"tasks":[],"draft":{"title":"Old note","writing":"Old writing","kind":"note"}}"#.utf8)
                    .write(to: XCTUnwrap(drafts.taskRecoveryURL))
            case 1: defaults.set(oldDraft, forKey: "composerKeptDraft")
            case 2, 4:
                let record = ComposerDraftStore.FailedTask(id: UUID(), title: TaskAddBarText(text: "Legacy task"),
                    writing: "Old task writing", status: .backlog, page: .tasks(.backlog))
                legacyID = record.id
                // Nil extension fields encode no keys: this is [FailedTask]'s
                // original pending-only layout, with no kept-draft envelope.
                let data = try JSONEncoder().encode([record])
                if format == 2 { try data.write(to: XCTUnwrap(drafts.taskRecoveryURL)) }
                else { defaults.set(data, forKey: "composerKeptDraft.failedTasks") }
            default:
                defaults.set(Data(#"{"shown":{"title":"Old note","writing":"Old writing","kind":"note"},"aside":{"title":"Aside task","writing":"Aside writing","kind":"task"}}"#.utf8), forKey: "composerKeptDraft")
            }
            let session = try launch()
            if let legacyID {
                XCTAssertEqual(session.page.addBar.text, "Legacy task")
                session.composer.submit(); session.page.settlePendingCompletionAcknowledgements()
                let physical = try rows(session)
                XCTAssertEqual(physical.filter { $0.id == legacyID }.count, 1)
                XCTAssertEqual(physical.first?.status, .backlog)
            } else {
                XCTAssertEqual(session.composer.kind, .note)
                XCTAssertEqual(session.page.addBar.text, "Old note")
                XCTAssertEqual(session.composer.writing, "Old writing")
                if format == 3 {
                    XCTAssertNotNil(session.page.toasts.current, "legacy aside Task files require an explicit re-attach notice")
                    session.composer.choose(.task)
                    XCTAssertEqual(session.page.addBar.text, "Aside task")
                    XCTAssertEqual(session.composer.writing, "Aside writing")
                    session.composer.choose(.note)
                    XCTAssertEqual(session.page.addBar.text, "Old note")
                }
            }
            XCTAssertTrue(session.composer.saveKeptDraft())
        }
        root = parent
    }

    // CP regression oracles: authored on the merged branch before fixes.
    private func anotherPanel(_ s: Session, key: String = "composerKeptDraft") -> Session {
        let p = TasksPageModel(library: s.library)
        p.services.acknowledgementDelay = .seconds(3600)
        var d = drafts; d.key = key
        let c = ComposerModel(tasks: p, services: ComposerServices(drafts: d))
        c.open(on: .tasks(.now))
        ownPageLifetime(p)
        return Session(container: s.container, library: s.library, page: p, composer: c)
    }
    func testCP01PanelsMergeRecordsInsteadOfReplacingAnotherPanelsFailure() throws {
        let a = try launch(), b = anotherPanel(a)
        type("Failed A", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        type("New A", in: a)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        type("Saved B", in: b); b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [id], "B may retire only B")
        XCTAssertEqual(try rows(a).count, 1)
    }
    func testCP02LivePendingCannotBeRecoveredOrCreatedTwiceByAnotherPanel() throws {
        let a = try launch(); type("Live A", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id), b = anotherPanel(a)
        XCTAssertTrue(b.page.addBar.text.isEmpty, "live pending is not crash recovery")
        type("Independent B", in: b); a.page.settlePendingCompletionAcknowledgements()
        b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).filter { $0.id == id }.count, 1)
        XCTAssertEqual(Set(try rows(a).map(\.title)), ["Live A", "Independent B"])
    }
    func testCP03KeptDraftRestoresExactSemanticStateAndAside() throws {
        let a = try launch(); a.page.addBar = TaskAddBarText(text: "Literal Monday #milk")
        a.page.addBar.dismissed = [(a.page.addBar.text as NSString).range(of: "Monday")]
        a.page.addBar.shown = [(a.page.addBar.text as NSString).range(of: "#milk")]
        a.page.addBar.picked.priority = .low; a.page.addBar.picked.tags = ["seed"]
        a.page.addBarState.seededTags = ["seed"]; a.composer.writing = "Task writing"
        let expected = a.page.addBar
        a.page.addBarState.stagingFiles = 1; a.composer.open(on: .notes, as: .note)
        a.page.addBar.text = "Independent Note"; a.composer.writing = "Note writing"; a.composer.pinned = true
        a.composer.close(); let b = try launch()
        XCTAssertTrue(b.composer.pinned)
        b.composer.open(on: .tasks(.now), as: .task)
        XCTAssertEqual(b.page.addBar, expected); XCTAssertEqual(b.composer.writing, "Task writing")
        XCTAssertEqual(b.page.addBarState.seededTags, ["seed"])
    }
    func testCP04EmptyingRecoveredTaskDiscardsIdentityAndOriginalPage() throws {
        let a = try launch(); a.composer.open(on: .tasks(.backlog)); type("Abandoned", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.page.addBar.clear(); a.composer.writing = ""; a.composer.close()
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        a.composer.open(on: .tasks(.now)); type("Fresh Now", in: a)
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertNotEqual(try rows(a).first?.id, id); XCTAssertEqual(try rows(a).first?.status, .todo)
        XCTAssertFalse(a.composer.failed)
    }
    func testCP05ConvertingRecoveredTaskToNoteRetiresItsRecord() async throws {
        let a = try launch(); type("Convert recovery", in: a); a.composer.submit()
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.choose(.note); await XCTAssertTrueAsync(await a.composer.create())
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty); XCTAssertTrue(try rows(a).isEmpty)
        XCTAssertTrue(try launch().page.addBar.text.isEmpty)
    }
    func testCP06CorruptJournalIsQuarantinedAndSubmissionKeepsWorking() throws {
        let url = try XCTUnwrap(drafts.taskRecoveryURL), bytes = Data("{garbage".utf8)
        try bytes.write(to: url); let a = try launch()
        XCTAssertNotNil(a.page.toasts.current, "damaged recovery needs a visible notice")
        type("Works after corruption", in: a); a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).map(\.title), ["Works after corruption"])
        let copies = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(copies.contains { $0 != url && (try? Data(contentsOf: $0)) == bytes })
    }
    func testCP07CloseWriteFailureIsVisibleAndRetryKeepsDraft() throws {
        var d = drafts; let write = d.persistTaskRecovery; var broken = true
        d.persistTaskRecovery = { data, url in
            if broken { throw CocoaError(.fileWriteOutOfSpace) }; try write(data, url)
        }
        let a = try launch(d); a.composer.choose(.note); type("Keep on close", in: a); a.composer.close()
        XCTAssertNotNil(a.page.toasts.current, "close cannot silently lose kept words")
        try capturePersistenceNotice(a, phase: "after")
        broken = false; a.composer.saveKeptDraft()
        XCTAssertEqual(try launch().page.addBar.text, "Keep on close")
    }
    func testCP08EditedRecoveryKeepsLatestPicksAndDismissedTokens() throws {
        let a = try launch(); type("Call Monday #milk", in: a)
        a.page.addBar.picked.priority = .high; a.composer.submit()
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.page.addBar.picked.priority = .low; a.page.addBar.picked.day = DueDay(year: 2027, month: 3, day: 4)
        a.page.addBar.dismissed = [(a.page.addBar.text as NSString).range(of: "#milk")]
        let expected = a.page.addBar; a.composer.close(); let b = try launch()
        XCTAssertEqual(b.page.addBar, expected)
        b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(b).first?.priority, .low); XCTAssertEqual(try rows(b).first?.tags, [])
    }
    func testCP09PicksOnlyDraftCannotBeDisplacedByRecovery() throws {
        let a = try launch(); type("Failed waiting", in: a); a.composer.submit(); type("Next", in: a)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.submit(); a.page.addBar.picked.priority = .low; a.page.addBar.picked.tags = ["next"]
        a.page.addBarState.seededTags = ["next"]; a.page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(a.page.addBar.text.isEmpty); XCTAssertEqual(a.page.addBar.picked.priority, .low)
        XCTAssertEqual(a.page.addBar.picked.tags, ["next"]); XCTAssertEqual(a.page.addBarState.seededTags, ["next"])
    }
    func testCP10KeptAndFailedOwnedFilesSurviveRelaunchWithExactBytes() throws {
        let a = try launch(), payload = Data("only promised copy".utf8)
        var staged = TaskAttachmentStaging()
        let directory = try staged.makeOwnedDirectory(), file = directory.appendingPathComponent("promise.pdf")
        try payload.write(to: file); staged.urls = [file]
        a.page.addBarState.files = [TasksComposerFiles(staging: staged)]
        type("Own my files", in: a); a.composer.close()
        staged.discard() // the promise/paste temporary copy disappears at quit
        let b = try launch()
        XCTAssertEqual(b.page.addBarState.fileNames, ["promise.pdf"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(b.page.addBarState.files.first?.staging.urls.first)), payload)
        b.composer.open(on: .tasks(.now)); b.composer.submit()
        failure.on = true; b.page.settlePendingCompletionAcknowledgements(); failure.on = false
        let c = try launch(); XCTAssertEqual(c.page.addBarState.fileNames, ["promise.pdf"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(c.page.addBarState.files.first?.staging.urls.first)), payload)
    }
    func testCP11ClosingPanelCannotOrphanPendingFiles() async throws {
        let base = try launch(); var panel: Session? = anotherPanel(base)
        let file = root.appendingPathComponent("pending.pdf"), payload = Data("pending bytes".utf8)
        try payload.write(to: file); panel?.page.addComposerFiles(urls: [file])
        try await waitForFiles(try XCTUnwrap(panel))
        type("Pending close", in: try XCTUnwrap(panel)); panel?.composer.submit(); panel?.composer.close()
        let pendingPage = try XCTUnwrap(panel?.page); panel = nil
        pendingPage.settlePendingCompletionAcknowledgements()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try rows(base).first?.attachments.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try rows(base).count, 1)
        let reference = try XCTUnwrap(try rows(base).first?.attachments.first)
        let url = try await base.library.tasks.taskImageFiles.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), payload)
    }
    func testCP12PanelKeptDraftsRemainIndependentOnOneJournal() throws {
        let a = try launch(), b = anotherPanel(a, key: "composerKeptDraft.floating.tasks")
        type("Docked", in: a); type("Floating", in: b); a.composer.close(); b.composer.close()
        let c = try launch(), d = anotherPanel(c, key: "composerKeptDraft.floating.tasks")
        XCTAssertEqual(c.page.addBar.text, "Docked"); XCTAssertEqual(d.page.addBar.text, "Floating")
        d.page.addBar.clear(); d.composer.writing = ""; d.composer.close()
        XCTAssertEqual(try launch().page.addBar.text, "Docked")
    }

    func testCP13FailedRetirementRetriesBeforeDeletedTaskCanReturn() throws {
        var d = drafts; let write = d.persistTaskRecovery; var failOnce = true
        d.persistTaskRecovery = { data, url in
            if try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: data).tasks.isEmpty, failOnce {
                failOnce = false; throw CocoaError(.fileWriteOutOfSpace)
            }
            try write(data, url)
        }
        let a = try launch(d); type("Retire durably", in: a); a.composer.submit()
        a.page.settlePendingCompletionAcknowledgements(); a.composer.saveKeptDraft()
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty, "failed retirement must be retried")
        let context = ModelContext(a.container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) { context.delete(row) }
        try context.save()
        XCTAssertTrue(try launch().page.addBar.text.isEmpty, "permanently deleted task must stay gone")
    }
    func testCP14RelativeDayNeverResolvesAgainstRelaunchDay() throws {
        let a = try launch()
        a.page.services.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        a.page.addBar = TaskAddBarText(text: "Call today")
        let expected = a.composer.values.day; a.composer.close()
        let b = try launch(); b.page.services.now = { Date(timeIntervalSince1970: 1_900_000_000) }
        XCTAssertEqual(b.composer.values.day, expected)
        XCTAssertEqual(b.composer.values.title, "Call")
        let current = DueDay(date: b.page.services.now(), calendar: b.page.services.calendar())
        XCTAssertEqual(b.page.parser.today, current, "ordinary row edits keep the current clock")
        XCTAssertEqual(b.page.dateChoices.today, current, "date pickers offer the actual current day")
        b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(b).count, 1)
        XCTAssertEqual(try rows(b).first?.dueDay, expected)
    }
    func testCP15TransientReadFailureDoesNotPermanentlyDisableSubmit() throws {
        XCTAssertTrue(drafts.save(.init(title: "Existing", writing: "", kind: "task")))
        var d = drafts; let read = d.readTaskRecovery; var fail = true
        d.readTaskRecovery = { url in
            if fail { fail = false; throw CocoaError(.fileReadNoPermission) }; return try read(url)
        }
        let a = try launch(d)
        a.page.addBar.clear(); a.composer.writing = ""; a.composer.close()
        a.composer.open(on: .tasks(.now)); type("After read retry", in: a)
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).map(\.title), ["After read retry"])
    }
    func testCP16StoreFamilyResetRemovesComposerJournalAndOwnedFiles() throws {
        let base = root.appendingPathComponent("Reset")
        let identifier = (Bundle.main.bundleIdentifier ?? "unknown-bundle").replacingOccurrences(of: "/", with: "-")
        let directory = base.appendingPathComponent("AtticCanvasUITests").appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("canvas.store.composer-tasks.json")
        try Data("[]".utf8).write(to: journal)
        let staging = directory.appendingPathComponent("canvas.store.composer-files")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let container = try PersistenceController.makeCanvasUITestContainer(reset: true, baseDirectory: base)
        XCTAssertFalse(container.configurations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCP17QuitRefusesAnUncheckpointedDraftOrPendingProvider() throws {
        var d = drafts
        d.persistTaskRecovery = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let a = try launch(d); type("Do not lose on quit", in: a)
        XCTAssertFalse(TasksPageModel.prepareForTermination(in: a.library.tasks))
        XCTAssertNotNil(a.page.toasts.current)
        a.composer.services.drafts = drafts
        a.page.addBarState.stagingFiles = 1
        XCTAssertFalse(TasksPageModel.prepareForTermination(in: a.library.tasks))
        a.page.addBarState.stagingFiles = 0
        XCTAssertTrue(TasksPageModel.prepareForTermination(in: a.library.tasks))
        XCTAssertEqual(drafts.load()?.title, "Do not lose on quit")
    }
    func testCP18TransientReconciliationFailureIsRetried() throws {
        let task = ComposerDraftStore.FailedTask(id: UUID(), title: TaskAddBarText(text: "Retry fetch"),
            writing: "", status: .todo, page: .tasks(.now))
        XCTAssertTrue(drafts.saveFailedTasks([task]))
        let a = try launch()
        // Recreate only the card, with a launch fetch that fails once.
        a.composer.close(); a.page.addBar.clear(); a.composer.writing = ""
        var fails = true
        let c = ComposerModel(tasks: a.page, services: ComposerServices(drafts: drafts, taskRecoveryIDs: { _ in
            if fails { fails = false; throw CocoaError(.fileReadUnknown) }; return []
        }))
        c.open(on: .tasks(.now)); c.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).map(\.id), [task.id])
    }
    func testCP20FailedRecoveryRetainsPinnedAndShownTokenState() throws {
        let a = try launch(); a.page.addBar = TaskAddBarText(text: "Call Monday #home")
        a.composer.writing = "Pinned task writing"
        let range = (a.page.addBar.text as NSString).range(of: "Monday")
        let exactDay = try XCTUnwrap(DueDay(year: 2028, month: 4, day: 5))
        a.page.addBar.pinned = [.init(range: range, value: .dueDay(exactDay))]
        a.page.addBar.shown = [range]
        a.composer.submit(); failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        let b = try launch()
        XCTAssertEqual(b.page.addBar.pinned, [.init(range: range, value: .dueDay(exactDay))])
        XCTAssertEqual(b.page.addBar.shown, [range])
        XCTAssertEqual(b.composer.values.day, DueDay(year: 2028, month: 4, day: 5))
    }
    func testCP21MissingOwnedFilesRequireVisibleReattachmentWithoutPhantomChips() async throws {
        let a = try launch(), file = root.appendingPathComponent("lost.pdf")
        try Data("missing file".utf8).write(to: file); a.page.addComposerFiles(urls: [file])
        try await waitForFiles(a)
        type("Missing attachment", in: a); a.composer.close()
        // Remove only this test's staging family to model unavailable bytes.
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where child.path.hasSuffix(".files") { try FileManager.default.removeItem(at: child) }
        try FileManager.default.removeItem(at: file)
        let b = try launch()
        XCTAssertTrue(b.page.addBarState.fileNames.isEmpty)
        XCTAssertNotNil(b.page.toasts.current, "the draft must explicitly ask for re-attachment")
        XCTAssertEqual(b.page.addBar.text, "Missing attachment")
    }
    func testCP22ReturnDoesNotRepeatedlyReadAndDecodeTheJournal() throws {
        var d = drafts; let read = d.readTaskRecovery, write = d.persistTaskRecovery
        var reads = 0
        let fullFlush = ProcessInfo.processInfo.environment["ATTIC_COMPOSER_FULLFSYNC"] == "1"
        let cycles = ProcessInfo.processInfo.environment["ATTIC_COMPOSER_COST_PROBE"] == "1" ? 100 : 1
        d.readTaskRecovery = { url in reads += 1; return try read(url) }
        d.persistTaskRecovery = { data, url in
            try write(data, url)
            if fullFlush {
                let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { close(descriptor) }
                guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
        }
        let a = try launch(d)
        var elapsed: [Double] = [], coldLoads: [Double] = [], keptSizes: [Int] = [], sizes: [Int] = [], readCounts: [Int] = []
        for cycle in 0..<cycles {
            type("Measured kept draft \(cycle)", in: a)
            if cycles > 1 { a.composer.writing = String(repeating: "retained writing ", count: 6_400) }
            a.composer.saveKeptDraft()
            if cycles > 1 {
                keptSizes.append(try Data(contentsOf: XCTUnwrap(drafts.taskRecoveryURL)).count)
                reads = 0
                let coldStart = ContinuousClock.now
                ComposerRecoveryJournal.simulateProcessExitForTesting(d)
                let coldDuration = coldStart.duration(to: .now).components
                coldLoads.append(Double(coldDuration.seconds) * 1000 + Double(coldDuration.attoseconds) / 1e15)
                XCTAssertEqual(reads, 1, "a cold owner reads one journal")
            }
            reads = 0
            let start = ContinuousClock.now
            a.composer.submit()
            let duration = start.duration(to: .now).components
            elapsed.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            readCounts.append(reads)
            XCTAssertLessThanOrEqual(reads, 1, "one owner must avoid redundant reads before acknowledgement")
            a.page.settlePendingCompletionAcknowledgements()
            XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
            sizes.append(try Data(contentsOf: XCTUnwrap(drafts.taskRecoveryURL)).count)
        }
        XCTAssertEqual(try rows(a).count, cycles)
        let budget = try XCTUnwrap(sizes.first)
        XCTAssertTrue(sizes.allSatisfy { $0 <= budget }, "successful history must not enlarge the recovery journal")
        let sorted = elapsed.sorted()
        if let maximum = coldLoads.max() {
            let cold = coldLoads.sorted()
            print("CP_COLD n=\(cold.count) p50_ms=\(cold[cold.count / 2]) p95_ms=\(cold[cold.count * 95 / 100]) max_ms=\(maximum) journal_bytes_max=\(keptSizes.max()!)")
        }
        print("CP_RETURN mode=\(fullFlush ? "fullfsync" : "fsync") n=\(cycles) p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) max_ms=\(sorted.last!) reads_max=\(readCounts.max()!) journal_first=\(budget) journal_last=\(sizes.last!)")
    }

    func testCP23PermanentPurgeWaitsForDurableRecoveryRetirement() throws {
        var d = drafts; let write = d.persistTaskRecovery
        d.persistTaskRecovery = { data, url in
            if try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: data).tasks.isEmpty {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try write(data, url)
        }
        let a = try launch(d)
        a.page.addBar = TaskAddBarText(text: "Purge safely")
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        let id = try XCTUnwrap(try rows(a).first?.id)
        XCTAssertTrue(a.library.delete(AtticItemRef(.task, id), in: .tasks))
        XCTAssertTrue(a.library.tasks.purgeDeleted(before: .distantFuture).isEmpty,
            "retain the tombstone while retirement cannot be made durable")
        XCTAssertEqual(try rows(a).count, 1)
        a.composer.services.drafts = drafts; a.composer.saveKeptDraft()
        XCTAssertEqual(a.library.tasks.purgeDeleted(before: .distantFuture), [id])
        XCTAssertTrue(try rows(a).isEmpty)
        XCTAssertTrue(try launch().page.addBar.text.isEmpty)
    }

    func testCP24CommittedTaskFinishesFilesAfterCrashWithoutReattachingTwice() async throws {
        var d = drafts; let write = d.persistTaskRecovery; var retirementArmed = false
        d.persistTaskRecovery = { data, url in
            if try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: data).tasks.isEmpty, retirementArmed {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try write(data, url)
        }
        let a = try launch(d), file = root.appendingPathComponent("crash.pdf"), payload = Data("crash-proof bytes".utf8)
        try payload.write(to: file); a.page.addComposerFiles(urls: [file])
        let staged = ContinuousClock.now.advanced(by: .seconds(5))
        while a.page.addBarState.stagingFiles > 0, ContinuousClock.now < staged { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(a.page.addBarState.stagingFiles, 0)
        type("Committed before files", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        retirementArmed = true
        let ownedCopy = try XCTUnwrap(try drafts.readFailedTasks().first?.draftState?.files?.first?.urls.first)
        XCTAssertNotNil(a.library.createTask(TaskDraft(title: "Committed before files"),
            writing: "Writing that must survive", in: .tasks, id: id))
        let replay = try launch(d)
        XCTAssertTrue(replay.page.addBar.text.isEmpty, "a committed task's backup must not be offered as a new draft")
        let imported = ContinuousClock.now.advanced(by: .seconds(5))
        while try rows(replay).first?.attachments.count != 1, ContinuousClock.now < imported { try await Task.sleep(for: .milliseconds(10)) }
        for work in Array(replay.page.composerAttachmentTasks.values) { _ = await work.value }
        XCTAssertEqual(try rows(replay).filter { $0.id == id }.count, 1)
        XCTAssertEqual(try rows(replay).first?.attachments.count, 1)
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [id], "retirement failure leaves the file manifest durable")
        let final = try launch()
        let retired = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try drafts.readFailedTasks().isEmpty), ContinuousClock.now < retired { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        XCTAssertTrue(final.page.addBar.text.isEmpty)
        XCTAssertEqual(try rows(final).filter { $0.id == id }.count, 1)
        XCTAssertEqual(try rows(final).first?.attachments.count, 1, "replay must recognize an already imported digest")
        let reference = try XCTUnwrap(try rows(final).first?.attachments.first)
        let url = try await final.library.tasks.taskImageFiles.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedCopy.path), "retirement cleans only the consumed staged copy")
    }

    func testCP25ClosedPanelCannotCheckpointOverAnotherPanelsEditedRecoveryAndFiles() async throws {
        let a = try launch(); type("Original failed words", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.close()
        let b = anotherPanel(a, key: "composerKeptDraft.floating.tasks")
        b.page.addBar = TaskAddBarText(text: "Revised in the other panel")
        b.page.addBar.picked.priority = .low; b.page.addBar.picked.tags = ["handoff"]
        b.composer.writing = "New writing from the current editor"
        let source = root.appendingPathComponent("handoff.pdf"), payload = Data("only the new panel's bytes".utf8)
        try payload.write(to: source); b.page.addComposerFiles(urls: [source]); try await waitForFiles(b)
        b.composer.close()
        let owned = try XCTUnwrap(try drafts.readFailedTasks().first?.draftState?.files?.first?.urls.first)
        try FileManager.default.removeItem(at: source)

        // Quit checkpoints every retained model, including the older closed
        // card. Its stale projection may not overwrite the current record.
        XCTAssertTrue(a.composer.saveKeptDraft())
        XCTAssertEqual(try drafts.readFailedTasks().first?.draftState?.title, "Revised in the other panel")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: owned.path))
        XCTAssertTrue(try rows(a).isEmpty)
        a.composer.open(on: .tasks(.now))
        XCTAssertEqual(a.page.addBar.text, "Revised in the other panel")
        XCTAssertEqual(a.composer.writing, "New writing from the current editor")
        XCTAssertEqual(a.page.addBarState.fileNames, ["handoff.pdf"])
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        for work in Array(a.page.composerAttachmentTasks.values) { _ = await work.value }
        let physical = try rows(a)
        XCTAssertEqual(physical.filter { $0.id == id }.count, 1)
        XCTAssertEqual(physical.first?.title, "Revised in the other panel")
        XCTAssertEqual(physical.first?.priority, .low); XCTAssertEqual(physical.first?.tags, ["handoff"])
        let reference = try XCTUnwrap(physical.first?.attachments.first)
        let url = try await a.library.tasks.taskImageFiles.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), payload)
    }

    func testCP26ReopeningAnOldPanelUsesTheCurrentRecoveryInsteadOfItsPrivateCopy() throws {
        let a = try launch(); type("Older panel words", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.close()
        let b = anotherPanel(a, key: "composerKeptDraft.floating.tasks")
        b.page.addBar = TaskAddBarText(text: "Current shared words")
        b.composer.writing = "Current shared writing"; b.composer.close()
        a.composer.open(on: .tasks(.now))
        XCTAssertEqual(a.page.addBar.text, "Current shared words")
        XCTAssertEqual(a.composer.writing, "Current shared writing")
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).filter { $0.id == id }.count, 1)
        XCTAssertEqual(try rows(a).first?.title, "Current shared words")
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
    }

    func testCP27LateSettlementCannotEraseAClosedReplacementPanelsKeptDraft() throws {
        let a = try launch(); type("Older acknowledged task", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        a.composer.close()
        weak var replacement: ComposerModel?
        autoreleasepool {
            let b = anotherPanel(a) // the same panel slot was recreated
            type("Kept by the younger window", in: b); b.composer.close()
            replacement = b.composer
        }
        XCTAssertNil(replacement, "the weak current-panel lease has expired")
        XCTAssertTrue(a.composer.isCreating, "drive the older callback after replacement teardown")
        a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).filter { $0.id == id }.count, 1)
        XCTAssertEqual(drafts.loadKeptDrafts()?.shown.title, "Kept by the younger window")
        XCTAssertEqual(try launch().page.addBar.text, "Kept by the younger window")
    }

    func testCP28ReopeningRecoveryAsNoteKeepsItsLiveLeaseUntilConversion() async throws {
        let a = try launch(); type("Recover as a Note", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.close(); a.composer.open(on: .tasks(.now), as: .note)
        let b = anotherPanel(a, key: "composerKeptDraft.floating.tasks")
        XCTAssertTrue(b.page.addBar.text.isEmpty, "a live Note conversion still owns its Task recovery")
        await XCTAssertTrueAsync(await a.composer.create())
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        type("Independent task in B", in: b); b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        let physical = try rows(b)
        XCTAssertEqual(physical.count, 1)
        XCTAssertEqual(physical.first?.title, "Independent task in B")
        XCTAssertNotEqual(physical.first?.id, id)
    }

    func testCP29AnIndependentAsideNoteCannotOwnOrRetireItsTaskDraftsRecoveryID() async throws {
        let a = try launch(); type("Task that must remain aside", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.open(on: .tasks(.now), as: .note)
        a.page.addBar = TaskAddBarText(text: "Separate note words"); a.composer.writing = "Separate note writing"
        a.composer.open(on: .tasks(.now), as: .task)
        XCTAssertEqual(a.page.addBar.text, "Task that must remain aside")
        XCTAssertEqual(try drafts.readFailedTasks().first?.draftState?.kind, "task")
        XCTAssertEqual(try drafts.readFailedTasks().first?.draftState?.title, "Task that must remain aside")
        a.composer.open(on: .tasks(.now), as: .note)
        XCTAssertEqual(a.page.addBar.text, "Separate note words")
        await XCTAssertTrueAsync(await a.composer.create())
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [id], "making the independent Note must keep its Task owner")
        a.composer.choose(.task)
        XCTAssertEqual(a.page.addBar.text, "Task that must remain aside")
        a.composer.submit(); a.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(a).filter { $0.id == id }.count, 1)
        XCTAssertEqual(try rows(a).first?.title, "Task that must remain aside")
    }

    func testCP30ClosingAnIndependentNoteReleasesItsAsideTasksRecoveryLease() async throws {
        let a = try launch(), source = root.appendingPathComponent("aside-handoff.pdf")
        let payload = Data("aside Task's only bytes".utf8)
        try payload.write(to: source); a.page.addComposerFiles(urls: [source]); try await waitForFiles(a)
        try FileManager.default.removeItem(at: source)
        type("Task set aside with its files", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.open(on: .notes, as: .note)
        XCTAssertTrue(a.page.addBar.text.isEmpty)
        type("Independent Note stays here", in: a); a.composer.close()
        let b = anotherPanel(a, key: "composerKeptDraft.floating.tasks")
        XCTAssertEqual(b.page.addBar.text, "Task set aside with its files")
        XCTAssertEqual(b.page.addBarState.fileNames, ["aside-handoff.pdf"])
        XCTAssertTrue(a.composer.saveKeptDraft())
        XCTAssertEqual(a.page.addBar.text, "Independent Note stays here")
        b.composer.submit(); b.page.settlePendingCompletionAcknowledgements()
        for work in Array(b.page.composerAttachmentTasks.values) { _ = await work.value }
        let physical = try rows(b)
        XCTAssertEqual(physical.filter { $0.id == id }.count, 1)
        let reference = try XCTUnwrap(physical.first?.attachments.first)
        let url = try await b.library.tasks.taskImageFiles.verifiedURL(for: reference)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), payload)
    }

    func testCP31AFreshNoteOnlyPanelDoesNotConsumeAnotherPanelsFailedTask() async throws {
        let a = try launch(); type("Failed Task stays available", in: a); a.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true; a.page.settlePendingCompletionAcknowledgements(); failure.on = false
        a.composer.close()
        let page = TasksPageModel(library: a.library)
        var d = drafts; d.key = "composerKeptDraft.floating.notes"
        let note = ComposerModel(tasks: page, services: ComposerServices(drafts: d))
        ownPageLifetime(page)
        note.open(on: .notes, as: .note)
        XCTAssertEqual(note.kind, .note)
        XCTAssertTrue(page.addBar.text.isEmpty, "where Task is unreachable, Note starts from its own draft")
        XCTAssertTrue(note.writing.isEmpty)
        page.addBar = TaskAddBarText(text: "My independent Note"); note.writing = "My own writing"
        await XCTAssertTrueAsync(await note.create())
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [id])
        XCTAssertEqual(try drafts.readFailedTasks().first?.title, "Failed Task stays available")
        XCTAssertTrue(try rows(a).isEmpty)
    }

    func testPendingDiskRecoveryPrecedesClearAndRelaunchRetryKeepsIdentity() throws {
        let first = try launch()
        type("Pending task", in: first)
        first.page.addBar.picked.tags = ["chosen"]
        first.page.addBar.picked.priority = .high
        first.composer.submit()
        XCTAssertTrue(first.page.addBar.text.isEmpty)
        XCTAssertTrue(try rows(first).isEmpty)
        // Reading from a new draft store goes to disk, not the old object.
        let bytes = try Data(contentsOf: XCTUnwrap(drafts.taskRecoveryURL))
        XCTAssertEqual(try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: bytes).tasks.count, 1)
        let pending = try XCTUnwrap(try drafts.readFailedTasks().first)
        XCTAssertEqual(pending.writing, "Writing that must survive")
        XCTAssertEqual(pending.pickedTags, ["chosen"])
        let restarted = try launch()
        XCTAssertEqual(restarted.page.addBar.text, "Pending task")
        XCTAssertEqual(restarted.page.addBar.picked.priority, .high)
        XCTAssertTrue(restarted.page.addBarState.fileNames.isEmpty)
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).map(\.id), [pending.id])
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        let again = try launch()
        XCTAssertEqual(try rows(again).map(\.id), [pending.id])
        XCTAssertTrue(again.page.addBar.text.isEmpty)
    }

    func testRecoveryWriteFailureLeavesWordsPicksFilesAndStoreUntouched() async throws {
        var recovery = drafts
        recovery.persistTaskRecovery = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let session = try launch(recovery)
        type("Never clear this", in: session)
        session.page.addBar.picked.tags = ["keep"]
        let file = root.appendingPathComponent("keep.pdf")
        try Data("keep file".utf8).write(to: file)
        session.page.addComposerFiles(urls: [file])
        try await waitForFiles(session)
        session.composer.submit()
        XCTAssertEqual(session.page.addBar.text, "Never clear this")
        XCTAssertEqual(session.composer.writing, "Writing that must survive")
        XCTAssertEqual(session.page.addBar.picked.tags, ["keep"])
        XCTAssertEqual(session.page.addBarState.fileNames, ["keep.pdf"])
        XCTAssertTrue(session.composer.failed)
        XCTAssertFalse(session.composer.isCreating)
        session.page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(try rows(session).isEmpty)
        XCTAssertEqual(session.library.undo.undoCount(in: .tasks), 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep file".utf8))
        XCTAssertTrue(try rows(try launch()).isEmpty)
    }

    func testTaskSaveFailureKeepsDiskRecoveryAndRelaunchHasNoPhantomFiles() async throws {
        let session = try launch()
        type("Failed task", in: session)
        let file = root.appendingPathComponent("reattach.pdf")
        try Data("still owned".utf8).write(to: file)
        session.page.addComposerFiles(urls: [file])
        try await waitForFiles(session)
        session.composer.submit()
        let pendingID = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        failure.on = true
        session.page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(try rows(session).isEmpty)
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [pendingID])
        XCTAssertEqual(session.page.addBarState.fileNames, ["reattach.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restarted = try launch()
        XCTAssertEqual(restarted.page.addBar.text, "Failed task")
        XCTAssertEqual(restarted.composer.writing, "Writing that must survive")
        XCTAssertEqual(restarted.page.addBarState.fileNames, ["reattach.pdf"], "BT10: restore the draft’s durable owned copy")
        failure.on = false
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).map(\.id), [pendingID])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try rows(restarted).first?.attachments.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try rows(restarted).first?.attachments.map(\.filename), ["reattach.pdf"])
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
    }

    func testIdenticallyWordedNewDraftAndPendingDraftRemainSeparateAfterRelaunch() throws {
        let first = try launch()
        type("Same words", in: first)
        first.page.addBar.picked.priority = .high
        first.composer.submit()
        failure.on = true
        first.page.settlePendingCompletionAcknowledgements() // recovery now owns the kept-card backup
        first.composer.submit() // retry; a new draft can begin while this one saves
        type("Same words", in: first)
        first.page.settlePendingCompletionAcknowledgements()
        XCTAssertNil(first.page.addBar.picked.priority, "even an older kept recovery identity cannot claim newer typing")
        first.composer.saveKeptDraft()
        let pendingID = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        let restarted = try launch()
        XCTAssertNil(restarted.page.addBar.picked.priority, "the newer kept draft is not the pending high-priority task")
        failure.on = false
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).count, 1)
        XCTAssertNotEqual(try rows(restarted).first?.id, pendingID)
        XCTAssertEqual(restarted.page.addBar.picked.priority, .high)
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).count, 2)
        XCTAssertTrue(try rows(restarted).contains { $0.id == pendingID && $0.priority == .high })
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
    }

    func testCrashAfterCommitBeforeCleanupDoesNotRestoreKeptRecoveryOrDuplicateReplicas() throws {
        let first = try launch()
        type("Committed recovery", in: first)
        first.composer.submit()
        // Relaunch restores the pending task and saves a kept-card backup.
        var recovery = drafts
        let write = recovery.persistTaskRecovery
        recovery.persistTaskRecovery = { data, url in
            if try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: data).tasks.isEmpty {
                throw CocoaError(.fileWriteUnknown) // crash window: commit succeeded, retirement did not
            }
            try write(data, url)
        }
        let retry = try launch(recovery)
        let keptAtCrash = try XCTUnwrap(drafts.load())
        retry.composer.submit()
        retry.page.settlePendingCompletionAcknowledgements()
        // The actual crash stops the callback before it can clear this
        // older kept-card backup. Retain that exact disk state here.
        try seedKeptBackupForCrash(keptAtCrash)
        let id = try XCTUnwrap(try rows(retry).first?.id)
        XCTAssertEqual(try drafts.readFailedTasks().map(\.id), [id])
        // Two physical app-level replicas, one logical task.
        let context = ModelContext(retry.container)
        context.insert(TaskItem(id: id, title: "Committed recovery"))
        try context.save()
        let restarted = try launch()
        XCTAssertEqual(try rows(restarted).count, 2)
        XCTAssertEqual(restarted.library.tasks.tasks.count, 1)
        XCTAssertTrue(restarted.page.addBar.text.isEmpty)
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        restarted.composer.submit() // an empty card cannot duplicate the committed UUID
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).count, 2)
        XCTAssertTrue(restarted.page.setStatus(.inProgress, for: [id]).isApplied)
        XCTAssertTrue(try rows(restarted).allSatisfy { $0.status == .inProgress })
        XCTAssertTrue(restarted.library.delete(AtticItemRef(.task, id), in: .tasks))
        XCTAssertTrue(try rows(restarted).allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(try rows(try launch()).count, 2)
    }

    func testRecoveryWriteThatReplacesFileThenThrowsKeepsBothSubmissionIdentities() throws {
        let first = try launch()
        type("Earlier failed draft", in: first)
        first.composer.submit()
        type("Newer draft", in: first)
        failure.on = true
        first.page.settlePendingCompletionAcknowledgements()
        failure.on = false
        var recovery = drafts
        let write = recovery.persistTaskRecovery
        var reportFailure = true
        recovery.persistTaskRecovery = { data, url in
            try write(data, url)
            if reportFailure { reportFailure = false; throw CocoaError(.fileWriteUnknown) }
        }
        first.composer.services.drafts = recovery
        first.composer.submit()
        XCTAssertEqual(first.page.addBar.text, "Newer draft")
        XCTAssertTrue(first.composer.failed)
        XCTAssertFalse(first.composer.isCreating)
        XCTAssertTrue(try rows(first).isEmpty)
        let pendingID = try XCTUnwrap(try drafts.readFailedTasks().first { $0.title == "Newer draft" }?.id)
        first.composer.saveKeptDraft()
        let restarted = try launch()
        XCTAssertEqual(restarted.page.addBar.text, "Newer draft")
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).map(\.id), [pendingID])
        XCTAssertEqual(try drafts.readFailedTasks().map(\.title), ["Earlier failed draft"])
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).count, 2)
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
    }

    func testEditedRecoveryRelaunchKeepsWordsAndOriginalSubmissionIdentity() throws {
        let first = try launch()
        type("Original words", in: first)
        first.composer.submit()
        let id = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        let retry = try launch()
        type("Edited recovery words", in: retry)
        retry.composer.saveKeptDraft()
        let restarted = try launch()
        XCTAssertEqual(restarted.page.addBar.text, "Edited recovery words")
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).map(\.id), [id])
        XCTAssertEqual(try rows(restarted).first?.title, "Edited recovery words")
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
    }

    func testSubmittingPreviouslyKeptDraftAtomicallyConsumesItsBackup() throws {
        let first = try launch()
        type("Previously kept", in: first)
        first.composer.saveKeptDraft()
        XCTAssertEqual(drafts.load()?.title, "Previously kept")
        first.composer.submit()
        let pendingID = try XCTUnwrap(try drafts.readFailedTasks().first?.id)
        XCTAssertNil(drafts.load(), "acknowledgement atomically moves the kept card into the pending record")
        // A physical commit followed immediately by a crash: neither the
        // original controller's callback nor its defaults cleanup ran.
        XCTAssertNotNil(first.library.createTask(TaskDraft(title: "Previously kept"),
            writing: "Writing that must survive", in: .tasks, id: pendingID))
        let restarted = try launch()
        XCTAssertTrue(restarted.page.addBar.text.isEmpty)
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).map(\.id), [pendingID])
    }

    func testCrashAfterRecordRetirementStillDiscardsCommittedKeptDraft() throws {
        let first = try launch()
        type("Retired before crash", in: first)
        first.composer.submit()
        let retry = try launch()
        let keptAtCrash = try XCTUnwrap(drafts.load())
        retry.composer.submit()
        retry.page.settlePendingCompletionAcknowledgements()
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        // The ledger retirement was durable; the process stopped immediately
        // before clearing the older kept-card backup.
        try seedKeptBackupForCrash(keptAtCrash)
        let restarted = try launch()
        XCTAssertTrue(restarted.page.addBar.text.isEmpty)
        restarted.composer.submit()
        restarted.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(restarted).count, 1)
        XCTAssertEqual(try rows(restarted).first?.id, keptAtCrash.recoveringTaskID)
    }

    func testReconcileCommittedTombstonesDoesNotResurrectDeletedTask() throws {
        let session = try launch()
        type("Already deleted", in: session)
        session.composer.submit()
        let pending = try drafts.readFailedTasks()
        session.page.settlePendingCompletionAcknowledgements()
        let id = try XCTUnwrap(try rows(session).first?.id)
        XCTAssertTrue(session.library.delete(AtticItemRef(.task, id), in: .tasks))
        XCTAssertTrue(drafts.saveFailedTasks(pending)) // record survived the crash; task was committed then deleted
        let restarted = try launch()
        XCTAssertTrue(restarted.page.addBar.text.isEmpty)
        XCTAssertTrue(try drafts.readFailedTasks().isEmpty)
        XCTAssertEqual(try rows(restarted).count, 1)
        XCTAssertTrue(try rows(restarted).allSatisfy { $0.deletedAt != nil })
    }

    func testRecoveryRecordRetiresOnlyOnceAfterCommit() throws {
        var recovery = drafts
        let write = recovery.persistTaskRecovery
        var transitions: [Int] = []
        recovery.persistTaskRecovery = { data, url in
            transitions.append(try JSONDecoder().decode(ComposerDraftStore.TaskRecovery.self, from: data).tasks.count)
            try write(data, url)
        }
        let session = try launch(recovery)
        type("Exactly once", in: session)
        session.composer.submit()
        XCTAssertEqual(transitions, [1], "pending record is durable before acknowledgement")
        XCTAssertTrue(try rows(session).isEmpty)
        session.page.settlePendingCompletionAcknowledgements()
        session.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(transitions, [1, 0])
        XCTAssertEqual(try rows(try launch(recovery)).count, 1)
        XCTAssertEqual(transitions, [1, 0], "reconciliation must not retire an already removed record")
    }

    func testUnreadableRecoveryRefusesToOverwriteOrClearAnotherDraft() throws {
        let url = try XCTUnwrap(drafts.taskRecoveryURL)
        let bytes = Data("unreadable interrupted recovery".utf8)
        try bytes.write(to: url)
        let session = try launch()
        type("Do not clear", in: session)
        session.composer.submit()
        let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(siblings.contains { $0 != url && (try? Data(contentsOf: $0)) == bytes }, "damaged bytes stay readable beside the new journal")
        XCTAssertTrue(session.page.addBar.text.isEmpty, "a damaged journal cannot disable submission")
        session.page.settlePendingCompletionAcknowledgements()
        XCTAssertEqual(try rows(session).map(\.title), ["Do not clear"])
    }
}
