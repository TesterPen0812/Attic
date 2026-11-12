import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// A run the test drives by hand, event by event.
@MainActor
private final class FakeRunner: AgentRunning {
    var continuation: AsyncStream<AgentEvent>.Continuation?
    var observedContinuation: AsyncStream<AgentEvent>.Continuation?
    var retainsThread = false
    var snapshot = AgentThreadSnapshot(entries: [], events: [], isRunning: false)
    var forgotten = false
    var sent: [(text: String, watching: Bool)] = []
    var watching: [Bool] = []
    var resolved: [(UUID, Bool)] = []
    var undone: [UUID] = []
    var undoFailure: Error?
    var cancels = 0
    var contexts: [AgentRequestContext] = []
    var saved: [AgentChatSummary] = []
    var savedEntries: [UUID: [AgentThreadEntry]] = [:]

    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent> {
        sent.append((text, watching))
        return AsyncStream { self.continuation = $0 }
    }

    func send(_ text: String, context: AgentRequestContext, watching: Bool) -> AsyncStream<AgentEvent> {
        contexts.append(context)
        return send(text, watching: watching)
    }

    func chats() -> [AgentChatSummary] { saved }
    func reopen(chat id: UUID) -> Bool {
        guard let entries = savedEntries[id] else { return false }
        snapshot = AgentThreadSnapshot(entries: entries, events: [], isRunning: false)
        return true
    }

    func setWatching(_ watching: Bool) { self.watching.append(watching) }
    func resolve(approval id: UUID, allow: Bool) { resolved.append((id, allow)) }
    func undo(changeSet id: UUID) async throws {
        if let undoFailure { throw undoFailure }
        undone.append(id)
    }
    func cancel() {
        cancels += 1
        continuation?.finish()
    }
    func observe() -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            observedContinuation = continuation
            snapshot.events.forEach { _ = continuation.yield($0) }
        }
    }
    func threadSnapshot() -> AgentThreadSnapshot { snapshot }
    func forgetThread() { forgotten = true }
}

@MainActor
final class AgentChatTests: XCTestCase {
    private var model: AgentChatModel!
    private var runner: FakeRunner!
    private var page: AgentPage? = .tasks

    override func setUp() async throws {
        model = AgentChatModel()
        model.pacing = .instant
        runner = FakeRunner()
        model.connect(runner)
        model.currentPage = { [unowned self] in self.page }
        // A strip only shows when the week holds something (a day with a bar).
        model.weekDays = { day in
            AgentChatModel.emptyWeek(holding: day).enumerated().map { index, entry in
                AgentChatWeekDay(day: entry.day, bars: index == 2 ? [0.1...0.3] : [])
            }
        }
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func emit(_ events: AgentEvent...) async {
        events.forEach { runner.continuation?.yield($0) }
        await settle()
    }

    private func start(_ text: String = "tidy") async {
        model.draft = text
        model.send()
        await settle()
    }

    private func step(_ kind: AgentStepKind, targets: [AgentTarget], state: AgentStepState = .running, title: String = "Step") -> AgentStep {
        AgentStep(id: UUID(), title: title, kind: kind, targets: targets, state: state)
    }

    private var steps: [AgentStep] {
        model.entries.compactMap { if case let .step(step) = $0.content { step } else { nil } }
    }

    private var replies: [AgentChatReply] {
        model.entries.compactMap { if case let .reply(reply) = $0.content { reply } else { nil } }
    }

    private var week: AgentChatWeek? {
        model.entries.compactMap { if case let .week(week) = $0.content { week } else { nil } }.last
    }

    private var changes: AgentChatChanges? {
        model.entries.compactMap { if case let .changes(changes) = $0.content { changes } else { nil } }.last
    }

    private var weeks: [AgentChatWeek] {
        model.entries.compactMap { if case let .week(week) = $0.content { week } else { nil } }
    }

    private var weekIDs: [UUID] {
        model.entries.compactMap { if case .week = $0.content { $0.id } else { nil } }
    }

    private func november(_ day: Int) -> Date {
        Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }

    private func midnight(_ date: Date) -> Date { Calendar.autoupdatingCurrent.startOfDay(for: date) }

    private func tasks(_ titles: [String]) -> [AgentTarget] {
        titles.map { AgentTarget(page: .tasks, itemID: UUID(), title: $0) }
    }

    func testReconnectingLiveRunnerRestoresHistoryAndReplaysInFlightStepsOnce() async {
        let reading = step(.read, targets: tasks(["Real task"]), title: "Reading 1 task")
        runner.retainsThread = true
        runner.snapshot = AgentThreadSnapshot(entries: [
            AgentThreadEntry(id: UUID(), role: "user", text: "Earlier"),
            AgentThreadEntry(id: UUID(), role: "assistant", text: "Done."),
            AgentThreadEntry(id: UUID(), role: "user", text: "What next?"),
            AgentThreadEntry(id: UUID(), role: "assistant", text: "Reading 1 task")
        ], events: [.stepStarted(reading), .textDelta("Reading 1 task")], isRunning: true)

        model.connect(runner)
        await settle()
        XCTAssertEqual(model.entries.compactMap { if case let .asked(text) = $0.content { return text }; return nil },
                       ["Earlier", "What next?"])
        XCTAssertEqual(steps.map(\.title), ["Reading 1 task"], "Replayed events must not duplicate live tool rows")
        XCTAssertTrue(model.isBusy)
        var finished = reading
        finished.state = .done
        runner.observedContinuation?.yield(.stepFinished(finished))
        runner.observedContinuation?.yield(.finished)
        await settle()
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(model.isBusy)
        model.newChat()
        XCTAssertTrue(runner.forgotten, "A new conversation must also clear the persisted CLI thread")
    }

    func testDataSafetyFailedForgetWhileChatCatchesUpEndsVisibleRun() async {
        runner.retainsThread = true
        let saved = AgentThreadEntry(id: UUID(), role: "user", text: "Keep this saved question")
        runner.snapshot = AgentThreadSnapshot(entries: [saved], events: [], isRunning: true)
        model.connect(runner)
        XCTAssertTrue(model.isBusy)
        // The runner has stopped, but the view has not consumed its last event.
        runner.snapshot = AgentThreadSnapshot(entries: [saved], events: [], isRunning: false)
        model.newChat()
        XCTAssertFalse(model.isBusy, "a failed new-chat save must not trap the composer in a busy state")
        XCTAssertTrue(model.entries.contains { if case .asked("Keep this saved question") = $0.content {
            return true
        }; return false }, "the original durable chat must still be presented")
    }

    private func readTheCalendar() async {
        var read = step(.read, targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)])
        await emit(.stepStarted(read))
        read.state = .done
        await emit(.stepFinished(read))
    }

    /// One whole run: reads the calendar, moves `titles`, and their dots land.
    private func runMoving(_ titles: [String], to day: Date) async {
        await start()
        await readTheCalendar()
        var moved = step(.move(toDay: day), targets: tasks(titles))
        await emit(.stepStarted(moved))
        titles.forEach { _ in model.dotLanded(week: weekIDs.last!) }
        moved.state = .done
        await emit(.stepFinished(moved),
                   .changes(AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: titles.count)), .finished)
    }

    // MARK: Open and close

    func testOpeningWatchesAndClosingStopsWatchingWithoutStoppingTheRun() async {
        model.open()
        XCTAssertTrue(model.bar.isChatOpen)
        await start()
        XCTAssertEqual(runner.sent.first?.watching, true)
        model.close()
        XCTAssertEqual(runner.watching, [true, false])
        XCTAssertEqual(runner.cancels, 0, "Closing keeps the run going")
        XCTAssertTrue(model.isBusy)
    }

    func testPanelHidingClosesAtOnceAndKeepsTheRun() async {
        model.open()
        await start()
        model.panelDidHide()
        XCTAssertFalse(model.bar.isChatOpen)
        XCTAssertTrue(model.closedAtOnce, "Still set when the views read it a tick later")
        XCTAssertEqual(runner.cancels, 0)
        model.open()
        XCTAssertFalse(model.closedAtOnce, "The next close animates again")
    }

    func testThePersonChangingPageClosesTheChatButTheAgentDoesNot() async {
        model.open()
        var opened: [AgentPage] = []
        model.openPage = { opened.append($0) }
        page = .notes
        await start()
        await emit(.stepStarted(step(.openPage, targets: [AgentTarget(page: .tasks, itemID: nil, title: nil)])))
        XCTAssertEqual(opened, [.tasks])
        XCTAssertTrue(steps.isEmpty, "Opening a page is not a tool row")
        model.pageChanged(to: .tasks)
        XCTAssertTrue(model.isOpen, "The agent's own page change keeps the chat open")
        model.pageChanged(to: .notes)
        XCTAssertFalse(model.isOpen)
    }

    func testAClosedRunNeverMovesThePage() async {
        var opened: [AgentPage] = []
        model.openPage = { opened.append($0) }
        page = .notes
        await start()
        await emit(.stepStarted(step(.openPage, targets: [AgentTarget(page: .tasks, itemID: nil, title: nil)])))
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: The ✦ button

    func testBarSaysWorkingThenNeedsYouThenTheChanges() async {
        await start()
        XCTAssertEqual(model.bar.state.label, "Working")
        await emit(.progress(done: 0, total: 3))
        XCTAssertEqual(model.bar.state.label, "Working 1 of 3")
        await emit(.progress(done: 1, total: 3))
        XCTAssertEqual(model.bar.state.label, "Working 2 of 3")
        let approval = AgentApproval(id: UUID(), title: "Delete 2 tasks?", targets: [])
        await emit(.approvalNeeded(approval))
        XCTAssertEqual(model.bar.state.label, "Needs you")
        model.resolveApproval(allow: true)
        XCTAssertEqual(model.bar.state.label, "Working 2 of 3")
        await emit(.changes(AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: 3)), .finished)
        XCTAssertEqual(model.bar.state, .changes(3))
        XCTAssertEqual(model.bar.state.label, "3 changes")
        model.open()
        XCTAssertEqual(model.bar.state, .idle, "Reading the thread clears the count")
    }

    func testARunWithNoChangesEndsOnDone() async {
        await start()
        await emit(.finished)
        XCTAssertEqual(model.bar.state, .done)
    }

    func testFinishingWhileOpenLeavesNothingUnread() async {
        model.open()
        await start()
        await emit(.changes(AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: 1)), .finished)
        model.close()
        XCTAssertEqual(model.bar.state, .idle)
    }

    // MARK: Approval

    func testApprovalTakesTheComposersPlaceAndGoesBack() async {
        model.open()
        await start()
        let approval = AgentApproval(id: UUID(), title: "Delete?", targets: [])
        await emit(.approvalNeeded(approval))
        XCTAssertEqual(model.approval, approval)
        XCTAssertEqual(model.phase, .needsYou)
        model.resolveApproval(allow: false)
        XCTAssertNil(model.approval)
        XCTAssertEqual(runner.resolved.first?.0, approval.id)
        XCTAssertEqual(runner.resolved.first?.1, false)
        XCTAssertEqual(model.phase, .acting)
    }

    func testAnApprovalWaitsThroughCloseAndReopen() async {
        await start()
        let approval = AgentApproval(id: UUID(), title: "Delete?", targets: [])
        await emit(.approvalNeeded(approval))
        model.open()
        model.close()
        model.open()
        XCTAssertEqual(model.approval, approval)
        XCTAssertTrue(runner.resolved.isEmpty)
    }

    func testConcurrentApprovalsAreAnsweredExactlyOnceInArrivalOrder() async {
        await start()
        let first = AgentApproval(id: UUID(), title: "Delete first?", targets: [])
        let second = AgentApproval(id: UUID(), title: "Delete second?", targets: [])
        await emit(.approvalNeeded(first), .approvalNeeded(second), .approvalNeeded(first))
        XCTAssertEqual(model.approval, first)
        XCTAssertEqual(model.bar.state, .needsYou)
        model.resolveApproval(allow: false)
        XCTAssertEqual(model.approval, second)
        XCTAssertEqual(model.bar.state, .needsYou)
        model.resolveApproval(allow: true)
        XCTAssertNil(model.approval)
        XCTAssertEqual(runner.resolved.map { $0.0 }, [first.id, second.id])
        XCTAssertEqual(runner.resolved.map { $0.1 }, [false, true])
    }

    func testPartialBatchKeepsSuccessfulTargetsAndShowsIndividualErrors() async {
        page = .notes
        await start("Create two tasks")
        let success = tasks(["Saved task"])
        var batch = step(.create, targets: success, title: "Create tasks")
        await emit(.stepStarted(batch))
        batch.state = .partial("1 of 2 operations failed. Item 2: Missing title.")
        await emit(.stepFinished(batch), .changes(AgentChangeSet(
            id: UUID(), title: "Create tasks", pages: [.tasks], count: 1)))
        XCTAssertEqual(changes?.items.map(\.title), ["Saved task"])
        XCTAssertEqual(changes?.steps, [batch.id])
        XCTAssertTrue(model.dots.contains(.tasks), "The successful task must light its page")
        XCTAssertTrue(model.entries.contains { entry in
            if case let .note(message) = entry.content { return message.contains("Missing title") }
            return false
        }, "The failed item's explanation must remain visible")
    }

    // MARK: The thread

    func testWaitingShowsNothingUntilTheFirstTextOrStep() async {
        model.open()
        await start()
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertEqual(model.entries.count, 1, "Only what you sent: no thinking row")
        await emit(.textDelta("Hello"))
        XCTAssertEqual(model.phase, .acting)
    }

    func testReopeningShowsTheWholeThread() async {
        model.open()
        await start()
        model.close()
        await emit(.stepStarted(step(.read, targets: [], title: "Reading")),
                   .textDelta("All **done** here."), .finished)
        XCTAssertEqual(model.entries.count, 3)
        model.open()
        XCTAssertEqual(model.entries.count, 3)
        let reply = try? XCTUnwrap(replies.first)
        XCTAssertEqual(reply?.wordTimes.allSatisfy { $0 == .distantPast }, true, "Written while closed: it does not replay")
        XCTAssertEqual(reply?.marksStart, .distantPast)
    }

    func testAnEntryIsNewUntilItHasBeenShown() {
        let id = UUID()
        XCTAssertFalse(model.wasShown(id))
        XCTAssertFalse(model.wasShown(id), "Asking changes nothing: a body can run twice")
        model.noteShown(id)
        XCTAssertTrue(model.wasShown(id))
    }

    func testTextAcrossDeltasIsOneReplyAndAStepStartsANewOne() async {
        await start()
        await emit(.textDelta("One "), .textDelta("two"))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].raw, "One two")
        XCTAssertEqual(replies[0].wordTimes.count, 2)
        await emit(.stepStarted(step(.read, targets: [])), .textDelta("Three"))
        XCTAssertEqual(replies.count, 2)
    }

    func testProgressBetweenDeltasKeepsOneReply() async {
        await start()
        await emit(.textDelta("One "), .progress(done: 1, total: 2), .textDelta("two"))
        XCTAssertEqual(replies.count, 1)
    }

    func testWordsAreTimedWithSentencePauses() async {
        var pacing = AgentChatPacing()
        pacing.settle = 0
        model.pacing = pacing
        let start = Date(timeIntervalSince1970: 1000)
        model.now = { start }
        model.open()
        await self.start()
        await emit(.textDelta("Hi, there. Now"))
        let times = replies[0].wordTimes.map { $0.timeIntervalSince(start) }
        XCTAssertEqual(times[0], 0, accuracy: 0.001)
        XCTAssertEqual(times[1], pacing.comma, accuracy: 0.001)
        XCTAssertEqual(times[2], pacing.comma + pacing.sentence, accuracy: 0.001)
    }

    func testReduceMotionShowsARepliesWordsAtOnce() async {
        model.reducesMotion = { true }
        model.open()
        await start()
        await emit(.textDelta("Hello there"), .finished)
        XCTAssertEqual(replies[0].wordTimes.count, 2)
        XCTAssertTrue(replies[0].wordTimes.allSatisfy { $0 <= Date() })
        XCTAssertEqual(replies[0].marksStart, .distantPast)
    }

    func testKeyWordsAreMarkedAndTheStarsNeverShow() {
        let paragraphs = AgentChatWords.paragraphs("Three on **Friday, soon**.\n\nThe **landlord reply** waits")
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].map(\.text), ["Three", "on", "Friday,", "soon", "."])
        XCTAssertEqual(paragraphs[0].map(\.key), [nil, nil, 1, 1, nil])
        XCTAssertEqual(paragraphs[1].map(\.key), [nil, 2, 2, nil])
        XCTAssertEqual(AgentChatWords.paragraphs("An **open").first?.map(\.key), [nil, 1], "A stream can stop mid-mark")
    }

    /// The reply as the renderer writes it.
    private func written(_ raw: String) -> String {
        AgentChatWords.paragraphs(raw).flatMap { $0 }.reduce(into: "") { text, word in
            if !text.isEmpty, !word.joinsPrevious { text += " " }
            text += word.text
        }
    }

    func testPunctuationStaysOnTheHighlightedWordItTouches() {
        let words = AgentChatWords.paragraphs("Now on **Friday**, your first. In **two places**: soon")[0]
        XCTAssertEqual(words.map(\.text), ["Now", "on", "Friday", ",", "your", "first.", "In", "two", "places", ":", "soon"])
        XCTAssertEqual(words.filter(\.joinsPrevious).map(\.text), [",", ":"])
        XCTAssertEqual(words.map(\.key), [nil, nil, 1, nil, nil, nil, nil, 2, 2, nil, nil], "The underline stops at the word")
        XCTAssertEqual(written("Now on **Friday**, your first."), "Now on Friday, your first.")
        XCTAssertEqual(written("Done in **two places**: Friday"), "Done in two places: Friday")
        XCTAssertEqual(written("(**Friday**)"), "(Friday)")
        XCTAssertEqual(written("Re**do**ing it"), "Redoing it")
        XCTAssertEqual(written("**a****b** c"), "ab c")
    }

    func testSpacesAroundAMarkStaySpaces() {
        XCTAssertEqual(written("On **Friday** at **noon** today"), "On Friday at noon today")
        XCTAssertEqual(written("On ** Friday ** today"), "On Friday today")
        XCTAssertEqual(written("**Friday** first"), "Friday first")
    }

    func testAParagraphStartsOnItsOwn() {
        let paragraphs = AgentChatWords.paragraphs("One **key**\n\n**Two** words")
        XCTAssertEqual(paragraphs.flatMap { $0 }.filter(\.joinsPrevious), [])
    }

    func testDeltasCutAnywhereWriteTheSameWords() async {
        let raw = "2 tasks now on **Friday**, your first free afternoon."
        let whole = AgentChatWords.paragraphs(raw)
        XCTAssertEqual(whole[0].filter(\.joinsPrevious).map(\.text), [","])
        for cut in 1..<raw.count {
            model.newChat()
            await start()
            let index = raw.index(raw.startIndex, offsetBy: cut)
            await emit(.textDelta(String(raw[..<index])), .textDelta(String(raw[index...])), .finished)
            XCTAssertEqual(replies.count, 1)
            XCTAssertEqual(AgentChatWords.paragraphs(replies[0].raw), whole)
            XCTAssertEqual(replies[0].wordTimes.count, whole[0].count, "Cut at \(cut)")
        }
    }

    func testStoppingMarksRunningStepsAndClearsTheApproval() async {
        model.open()
        await start()
        await emit(.stepStarted(step(.read, targets: [])),
                   .approvalNeeded(AgentApproval(id: UUID(), title: "Delete?", targets: [])))
        model.stop()
        await settle()
        XCTAssertEqual(runner.cancels, 1)
        XCTAssertEqual(steps.first?.title, "Stopped")
        XCTAssertNil(model.approval)
        XCTAssertEqual(model.phase, .idle)
    }

    func testAFailedRunSaysSoInTheThread() async {
        model.open()
        await start()
        await emit(.failed("No connection"))
        XCTAssertEqual(model.entries.last?.content, .note("No connection"))
        XCTAssertEqual(model.phase, .idle)
    }

    func testSendingNeedsTextAndNoRunGoing() async {
        model.draft = "   "
        model.send()
        XCTAssertTrue(runner.sent.isEmpty)
        await start("one")
        model.draft = "two"
        model.send()
        XCTAssertEqual(runner.sent.count, 1)
        XCTAssertEqual(model.draft, "two", "What you typed waits")
    }

    // MARK: The composer's controls

    private func finishRun() async {
        runner.continuation?.yield(.finished)
        runner.continuation?.finish()
        await settle()
    }

    func testThePageChipSendsThePageAndItsItemUntilItIsRemoved() async {
        let note = AgentTarget(page: .notes, itemID: UUID(), title: "Launch plan")
        page = .notes
        model.currentItem = { note }
        model.open()
        XCTAssertEqual(model.chipPage, .notes, "The chip names the page on show")
        XCTAssertTrue(model.includesPage)
        await start("Summarise this")
        XCTAssertEqual(runner.contexts.last?.page, .notes)
        XCTAssertEqual(runner.contexts.last?.pageItem, note, "The open item goes with the page")
        await finishRun()

        model.removePage()
        await start("And now?")
        XCTAssertEqual(runner.contexts.last, AgentRequestContext.none, "Without the chip, no page context")
        await finishRun()

        model.addPage()
        await start("This page again")
        XCTAssertEqual(runner.contexts.last?.page, .notes, "This page brings it back")
        await finishRun()
    }

    func testTheChipFollowsThePage() {
        model.open()
        XCTAssertEqual(model.chipPage, .tasks)
        page = .calendar
        model.pageChanged(to: .calendar)
        XCTAssertEqual(model.chipPage, .calendar)
    }

    func testAddedTasksNotesAndFilesGoWithOneMessage() async throws {
        let task = AgentTarget(page: .tasks, itemID: UUID(), title: "Call the plumber")
        model.attach(task)
        model.attach(task)
        XCTAssertEqual(model.attachments.count, 1, "Adding the same item twice keeps one chip")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-chat-\(UUID().uuidString).txt")
        try Data("eggs, milk".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        model.attachFile(at: url)
        XCTAssertEqual(model.attachments.count, 2)
        await start("Plan the shop")
        XCTAssertEqual(runner.contexts.last?.items, [task])
        XCTAssertEqual(runner.contexts.last?.files, [AgentFileAttachment(name: url.lastPathComponent, text: "eggs, milk")])
        XCTAssertTrue(model.attachments.isEmpty, "What was added went with that message")
        await finishRun()
        await start("Next")
        XCTAssertEqual(runner.contexts.last?.items, [])
        XCTAssertEqual(runner.contexts.last?.files, [])
        await finishRun()
    }

    func testFileRefusesAnythingButSmallTextFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-chat-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("Hello".utf8).write(to: text)
        let image = folder.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]).write(to: image)
        let large = folder.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: AgentChatFiles.maxBytes + 1).write(to: large)
        let binary = folder.appendingPathComponent("binary.txt")
        try Data([0x41, 0, 0x42]).write(to: binary)

        XCTAssertEqual(try AgentChatFiles.read(text).get(), AgentFileAttachment(name: "notes.txt", text: "Hello"))
        XCTAssertEqual(AgentChatFiles.read(image).failure, .notText)
        XCTAssertEqual(AgentChatFiles.read(large).failure, .tooLarge)
        XCTAssertEqual(AgentChatFiles.read(binary).failure, .notText, "Text that isn't text is refused")
        XCTAssertEqual(AgentChatFiles.read(folder).failure, .unreadable)

        model.attachFile(at: image)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(model.attachmentRefusal, AgentChatFiles.Refusal.notText.message, "Refused plainly")
        model.attachFile(at: text)
        XCTAssertNil(model.attachmentRefusal)
        XCTAssertEqual(model.attachments.map(\.name), ["notes.txt"])
    }

    func testTheAgentMenuAndSettingsAreOneSetting() throws {
        let suite = "attic-chat-agent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.inAppAgentBackend = .claude
        let binding = model.bindAgent(to: settings)
        defer { binding.cancel() }
        XCTAssertEqual(model.agent, .claude)
        model.agent = .codex
        XCTAssertEqual(settings.inAppAgentBackend, .codex, "The chat's menu changes Settings")
        settings.inAppAgentBackend = .claude
        XCTAssertEqual(model.agent, .claude, "Settings changes the chat's menu")
        XCTAssertEqual(AppSettings(defaults: defaults).inAppAgentBackend, .claude, "Saved as the one setting")
    }

    func testReopeningAChatShowsItAsItEndedAndListsHistory() async {
        let old = AgentChatSummary(id: UUID(), title: "Boiler quotes", updated: Date().addingTimeInterval(-86_400))
        runner.saved = [old]
        runner.savedEntries[old.id] = [AgentThreadEntry(id: UUID(), role: "user", text: "Boiler quotes"),
                                       AgentThreadEntry(id: UUID(), role: "assistant", text: "Three so far."),
                                       AgentThreadEntry(id: UUID(), role: "notice", text: "A note")]
        model.refreshHistory()
        XCTAssertEqual(model.history, [old])
        model.open()
        await start("Something new")
        model.reopen(old.id)
        XCTAssertFalse(model.entries.isEmpty, "A chat can't be reopened over a run still going")
        await finishRun()
        model.reopen(old.id)
        XCTAssertEqual(model.entries.count, 3)
        guard case let .asked(text) = model.entries.first?.content else { return XCTFail("Expected the question") }
        XCTAssertEqual(text, "Boiler quotes")
        guard case let .reply(reply) = model.entries[1].content else { return XCTFail("Expected the reply") }
        XCTAssertTrue(reply.wordTimes.allSatisfy { $0 == .distantPast }, "A reopened reply is already written")
        XCTAssertTrue(model.entries.allSatisfy { model.wasShown($0.id) }, "Nothing in it plays again")
        XCTAssertEqual(model.phase, .idle)
    }

    func testHistoryDaysReadTodayAWeekdayOrTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15)))
        XCTAssertEqual(AgentChatModel.dayLabel(now.addingTimeInterval(-3600), now: now, calendar: calendar),
                       String(localized: "Today"))
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9)))
        XCTAssertNotEqual(AgentChatModel.dayLabel(tuesday, now: now, calendar: calendar), String(localized: "Today"))
        let october = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9)))
        XCTAssertTrue(AgentChatModel.dayLabel(october, now: now, calendar: calendar).contains("19"))
    }

    func testEscapeLeavesTaskOrNoteBeforeClosing() {
        model.open()
        model.pickingItem = true
        model.escape()
        XCTAssertFalse(model.pickingItem)
        XCTAssertTrue(model.isOpen)
        model.escape()
        XCTAssertFalse(model.isOpen)
    }

    func testNewChatPutsThePageChipBackAndClearsWhatWasAdded() async {
        model.removePage()
        model.attach(AgentTarget(page: .tasks, itemID: UUID(), title: "Call"))
        model.newChat()
        XCTAssertTrue(model.includesPage)
        XCTAssertTrue(model.attachments.isEmpty)
    }

    func testNewChatStopsTheRunAndEmptiesTheThread() async {
        await start()
        model.newChat()
        await settle()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(runner.cancels, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.bar.state, .idle)
    }

    // MARK: Week strip, dots, effects

    #if !ATTIC_GENERATED_TESTS
    func testWeekStripUsesRealCalendarTimingAndTaskDueDatesWithFakeSource() throws {
        let calendar = CalendarMonthMath.calendar(timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/London")))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        func event(_ name: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: name, title: name, start: start, end: end, isAllDay: allDay,
                          location: nil, calendarTitle: "Fake", colour: .init(red: 0.2, green: 0.5, blue: 0.8))
        }
        let source = CalendarEventSourceStub(events: [
            event("Meeting", date(9, 9), date(9, 11)),
            event("Overlap", date(9, 10), date(9, 12)),
            event("Overnight", date(10, 23), date(11, 2)),
            event("All day", date(12, 0), date(13, 0), allDay: true)
        ])
        let interval = DateInterval(start: date(9, 0), end: date(16, 0))
        let bars = AgentChatModel.week(holding: date(11, 12),
                                      dueDays: [DueDay(year: 2026, month: 11, day: 13)!,
                                                DueDay(year: 2026, month: 11, day: 13)!],
                                      events: source.events(in: interval), calendar: calendar)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars[0].bars.count, 1, "Overlapping meetings show one occupied period")
        XCTAssertEqual(bars[0].bars[0].lowerBound, 9.0 / 24, accuracy: 0.001)
        XCTAssertEqual(bars[0].bars[0].upperBound, 12.0 / 24, accuracy: 0.001)
        XCTAssertEqual(bars[1].bars[0].lowerBound, 23.0 / 24, accuracy: 0.001)
        XCTAssertEqual(bars[1].bars[0].upperBound, 1, accuracy: 0.001)
        XCTAssertEqual(bars[2].bars[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(bars[2].bars[0].upperBound, 2.0 / 24, accuracy: 0.001)
        XCTAssertEqual(bars[3].bars, [0...1], "All-day events occupy the full day")
        XCTAssertEqual(bars[4].bars.count, 2, "Task due-date marks still show alongside events")
        source.accessState = .denied
        let denied = AgentChatModel.week(holding: date(11, 12), dueDays: [],
                                        events: source.events(in: interval), calendar: calendar)
        XCTAssertTrue(denied.allSatisfy { $0.bars.isEmpty }, "Denied Calendar access must remain read-only and blank")
    }
    #endif

    func testACalendarReadShowsTheWeekAndAMoveTargetsADay() async {
        model.open()
        await start()
        let read = step(.read, targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)])
        await emit(.stepStarted(read))
        XCTAssertEqual(week?.days.count, 7)
        XCTAssertEqual(week?.read, false)
        var done = read
        done.state = .done
        await emit(.stepFinished(done))
        XCTAssertEqual(week?.read, true)

        let friday = Date(timeIntervalSince1970: 1_800_000_000)
        let moved = (0..<3).map { AgentTarget(page: .tasks, itemID: UUID(), title: "Task \($0)") }
        await emit(.stepStarted(step(.move(toDay: friday), targets: moved)))
        XCTAssertEqual(week?.target, friday)
        XCTAssertEqual(week?.dots, 3)
        XCTAssertEqual(week?.landed, 0)
        let id = try? XCTUnwrap(model.entries.first { if case .week = $0.content { true } else { false } }?.id)
        model.dotLanded(week: id!)
        XCTAssertEqual(week?.landed, 1)
    }

    func testAWeekWithNothingOnItIsNotDrawn() async {
        model.weekDays = { AgentChatModel.emptyWeek(holding: $0) }
        model.open()
        await start()
        await emit(.stepStarted(step(.read, targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)])))
        XCTAssertNil(week, "Seven blank boxes say nothing")
        let moved = AgentTarget(page: .tasks, itemID: UUID(), title: "Call")
        await emit(.stepStarted(step(.move(toDay: Date(timeIntervalSince1970: 1_800_000_000)), targets: [moved])))
        XCTAssertNotNil(week, "A move still has a day to land on")
    }

    func testAMoveToAnotherWeekShowsTheWeekThatHoldsTheDay() async {
        let friday = november(6)
        model.now = { friday }
        model.open()
        await start()
        await readTheCalendar()
        XCTAssertEqual(week?.days.first?.day, midnight(november(2)), "A calendar read shows this week")

        await emit(.stepStarted(step(.move(toDay: november(13)), targets: tasks(["A", "B"]))))
        XCTAssertEqual(weeks.count, 1, "The run keeps one strip")
        XCTAssertEqual(week?.days.first?.day, midnight(november(9)), "The strip follows the destination")
        XCTAssertEqual(week?.days.last?.day, midnight(november(15)))
        XCTAssertEqual(week?.target, november(13))

        await readTheCalendar()
        XCTAssertEqual(week?.days.first?.day, midnight(november(9)), "A later read leaves the destination on show")
        XCTAssertEqual(week?.target, november(13))
    }

    func testAMoveInsideTheShownWeekKeepsItsDays() async {
        let wednesday = november(4)
        var asked = 0
        model.now = { wednesday }
        model.weekDays = {
            asked += 1
            return AgentChatModel.emptyWeek(holding: $0).map { AgentChatWeekDay(day: $0.day, bars: [0.1...0.3]) }
        }
        model.open()
        await start()
        await readTheCalendar()
        await emit(.stepStarted(step(.move(toDay: november(6)), targets: tasks(["A"]))))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(week?.target, november(6))
    }

    func testEachRunGetsItsOwnWeek() async {
        let friday = november(6)
        model.now = { friday }
        model.open()
        await runMoving(["A", "B"], to: november(13))
        await runMoving(["C"], to: november(13))
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks.map(\.dots), [2, 1])
        XCTAssertEqual(weeks.map(\.landed), [2, 1])
        let order = model.entries.compactMap { entry -> String? in
            switch entry.content {
            case .asked: "asked"
            case .week: "week"
            default: nil
            }
        }
        XCTAssertEqual(order, ["asked", "week", "asked", "week"], "A run's strip sits in its own exchange")
    }

    func testUndoTakesTheDotsOffItsOwnRunsStrip() async {
        let friday = november(6)
        model.now = { friday }
        model.open()
        await runMoving(["A", "B"], to: november(13))
        await runMoving(["C"], to: november(13))
        let first = model.entries.first { if case .changes = $0.content { true } else { false } }!.id
        model.undo(first)
        await settle()
        XCTAssertEqual(weeks.map(\.landed), [0, 1])
    }

    func testMovesToOneDayAddUpAndANewDayStartsOver() async {
        let friday = november(6)
        model.now = { friday }
        model.open()
        await start()
        await emit(.stepStarted(step(.move(toDay: november(13)), targets: tasks(["A"]))))
        model.dotLanded(week: weekIDs[0])
        await emit(.stepStarted(step(.move(toDay: november(13)), targets: tasks(["B"]))))
        XCTAssertEqual(week?.dots, 2, "One task at a time still fills the day")
        XCTAssertEqual(week?.landed, 1)
        await emit(.stepStarted(step(.move(toDay: november(23)), targets: tasks(["C"]))))
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(week?.days.first?.day, midnight(november(23)))
        XCTAssertEqual(week?.dots, 1)
        XCTAssertEqual(week?.landed, 0)
    }

    func testAStoppedRunsWorkStaysOutOfTheNextRunsList() async {
        model.open()
        await start()
        var stopped = step(.move(toDay: Date()), targets: tasks(["Stopped"]))
        await emit(.stepStarted(stopped))
        stopped.state = .done
        await emit(.stepFinished(stopped))
        model.stop()
        await settle()
        await start()
        var moved = step(.move(toDay: Date()), targets: tasks(["Kept"]))
        await emit(.stepStarted(moved))
        moved.state = .done
        await emit(.stepFinished(moved), .changes(AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: 1)), .finished)
        XCTAssertEqual(changes?.items.map(\.title), ["Kept"])
        XCTAssertEqual(changes?.steps, [moved.id])
    }

    func testAMoveWhileClosedLandsWithNoMotionAndNoEffects() async {
        var effects: [AgentChatEffect] = []
        let watch = model.effects.sink { effects.append($0) }
        await start()
        await emit(.stepStarted(step(.move(toDay: Date()), targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "A")])),
                   .stepStarted(step(.delete, targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "B")])))
        XCTAssertEqual(week?.landed, 1)
        XCTAssertTrue(effects.isEmpty, "Closed, it works without touching the page")
        watch.cancel()
    }

    func testEffectsPlayWhileOpen() async {
        var effects: [AgentChatEffect] = []
        let watch = model.effects.sink { effects.append($0) }
        model.open()
        await start()
        let read = step(.read, targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "A")])
        let gone = step(.delete, targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "B")])
        await emit(.stepStarted(read), .stepStarted(gone))
        XCTAssertEqual(effects.count, 3)
        XCTAssertEqual(effects[1], .reading(read))
        XCTAssertEqual(effects[2], .deleting(gone))
        watch.cancel()
    }

    func testDotsMarkOtherPagesAndGoWhenYouGetThere() async {
        var island: Set<AgentPage> = []
        model.onDotsChanged = { island = $0 }
        await start()
        var note = step(.create, targets: [AgentTarget(page: .notes, itemID: nil, title: "N")])
        note.state = .done
        var here = step(.update, targets: [AgentTarget(page: .tasks, itemID: nil, title: "T")])
        here.state = .done
        var read = step(.read, targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)])
        read.state = .done
        await emit(.stepFinished(note), .stepFinished(here), .stepFinished(read))
        XCTAssertEqual(island, [.notes], "Not the page you are on, and not a page only read")
        model.pageChanged(to: .notes)
        XCTAssertTrue(island.isEmpty)
    }

    // MARK: Undo

    private func finishWithChanges() async -> AgentChangeSet {
        var moved = step(.move(toDay: Date()), targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "Call")])
        await emit(.stepStarted(moved))
        moved.state = .done
        var gone = step(.delete, targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "Old")])
        gone.state = .done
        let set = AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: 2)
        await emit(.stepFinished(moved), .stepFinished(gone), .changes(set), .finished)
        return set
    }

    func testChangesListWhatTheStepsDid() async {
        model.open()
        await start()
        _ = await finishWithChanges()
        XCTAssertEqual(changes?.items.map(\.title), ["Call", "Old"])
        XCTAssertEqual(changes?.items.last?.detail, "Deleted")
        XCTAssertEqual(changes?.items.last?.isDelete, true)
        XCTAssertEqual(changes?.steps.count, 2)
    }

    func testUndoUndoesTheWholeSetAndSaysSo() async {
        model.open()
        await start()
        let set = await finishWithChanges()
        var effects: [AgentChatEffect] = []
        let watch = model.effects.sink { effects.append($0) }
        let id = model.entries.first { if case .changes = $0.content { true } else { false } }!.id
        model.undo(id)
        XCTAssertEqual(changes?.state, .undoing)
        await settle()
        XCTAssertEqual(runner.undone, [set.id])
        XCTAssertEqual(changes?.state, .undone)
        XCTAssertEqual(week?.landed, 0)
        XCTAssertEqual(effects.count, 1)
        model.undo(id)
        await settle()
        XCTAssertEqual(runner.undone.count, 1, "Undone once")
        watch.cancel()
    }

    func testAFailedUndoKeepsTheRowAndSaysWhy() async {
        struct Refused: LocalizedError { var errorDescription: String? { "Can’t undo" } }
        model.open()
        await start()
        _ = await finishWithChanges()
        runner.undoFailure = Refused()
        let id = model.entries.first { if case .changes = $0.content { true } else { false } }!.id
        model.undo(id)
        await settle()
        XCTAssertEqual(changes?.state, .ready)
        XCTAssertEqual(model.entries.last?.content, .note("Can’t undo"))
    }
}

/// `ScriptedAgentRunner` against a real store, through `AgentTaskTools`.
@MainActor
final class ScriptedAgentRunnerTests: XCTestCase {
    private var store: TaskStore!
    private var tools: AgentTaskTools!
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // Mon 21 Sep 2026
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() async throws {
        let now = now
        store = try makeTestStore(now: { now })
        let parser = TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { now })
        tools = AgentTaskTools(store: store, library: AtticLibrary(tasks: store), parser: parser)
    }

    private func addTask(_ title: String, due: String) throws {
        _ = try tools.call(name: "create_task", arguments: ["title": title, "due": due])
    }

    private func runner(_ mode: AgentChatMode = .askFirst) -> ScriptedAgentRunner {
        ScriptedAgentRunner(tools: tools, mode: { mode }, now: { [now] in now }, calendar: calendar, pace: 0)
    }

    private func collect(_ runner: ScriptedAgentRunner, _ text: String, allow: Bool = true) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in runner.send(text, watching: false) {
            events.append(event)
            if case let .approvalNeeded(approval) = event { runner.resolve(approval: approval.id, allow: allow) }
        }
        return events
    }

    private func due(_ title: String) -> String? {
        store.tasks.first { $0.title == title }?.dueDay?.rawValue
    }

    func testPicksTheDesignsScripts() {
        XCTAssertEqual(ScriptedAgentRunner.script(for: "Tidy my overdue tasks"), .tidy)
        XCTAssertEqual(ScriptedAgentRunner.script(for: "Plan today around my calendar"), .book)
        XCTAssertEqual(ScriptedAgentRunner.script(for: "plan today"), .plan)
        XCTAssertEqual(ScriptedAgentRunner.script(for: "What’s coming up this week?"), .week)
        XCTAssertEqual(ScriptedAgentRunner.script(for: "Add a checklist to my note"), .note)
        XCTAssertEqual(ScriptedAgentRunner.script(for: "Get me ready for the launch"), .all)
    }

    func testTidyMovesAsksDeletesAndUndoRestoresEverything() async throws {
        for (title, day) in [("One", "2026-09-10"), ("Two", "2026-09-11"), ("Three", "2026-09-12"), ("New Reminder", "2026-09-13")] {
            try addTask(title, due: day)
        }
        try addTask("Later", due: "2026-10-30")
        let runner = runner()
        let events = await collect(runner, "tidy")
        XCTAssertEqual(due("One"), "2026-09-25", "The next Friday")
        XCTAssertEqual(due("Three"), "2026-09-25")
        XCTAssertEqual(due("Later"), "2026-10-30")
        XCTAssertFalse(store.tasks.contains { $0.title == "New Reminder" })
        XCTAssertTrue(events.contains { if case .approvalNeeded = $0 { true } else { false } })
        let set = events.compactMap { if case let .changes(set) = $0 { set } else { nil } }.first
        XCTAssertEqual(set?.count, 4)
        XCTAssertEqual(events.last, .finished)
        try await runner.undo(changeSet: XCTUnwrap(set?.id))
        XCTAssertEqual(due("One"), "2026-09-10")
        XCTAssertEqual(due("Three"), "2026-09-12")
        XCTAssertEqual(due("New Reminder"), "2026-09-13")
    }

    func testDenyingKeepsTheTasks() async throws {
        for (title, day) in [("One", "2026-09-10"), ("New Reminder", "2026-09-13")] { try addTask(title, due: day) }
        _ = await collect(runner(), "tidy", allow: false)
        XCTAssertTrue(store.tasks.contains { $0.title == "New Reminder" })
    }

    func testAutoNeverAsksAndReadOnlyChangesNothing() async throws {
        for (title, day) in [("One", "2026-09-10"), ("New Reminder", "2026-09-13")] { try addTask(title, due: day) }
        let readOnly = await collect(runner(.readOnly), "tidy")
        XCTAssertEqual(due("One"), "2026-09-10")
        XCTAssertFalse(readOnly.contains { if case .changes = $0 { true } else { false } })
        let auto = await collect(runner(.auto), "tidy")
        XCTAssertFalse(auto.contains { if case .approvalNeeded = $0 { true } else { false } })
        XCTAssertEqual(due("One"), "2026-09-25")
    }

    private func reply(_ events: [AgentEvent]) -> String {
        events.compactMap { if case let .textDelta(text) = $0 { text } else { nil } }.joined()
    }

    func testATaskAlreadyOnTheDayIsNotAChange() async throws {
        for (title, day) in [("Dentist", "2026-09-25"), ("One", "2026-09-28"), ("Two", "2026-09-29")] { try addTask(title, due: day) }
        let runner = runner()
        let events = await collect(runner, "tidy", allow: false)
        let move = events.compactMap { event -> AgentStep? in
            if case let .stepFinished(step) = event, case .move = step.kind { step } else { nil }
        }.first
        XCTAssertEqual(Set(move?.targets.compactMap(\.title) ?? []), ["One", "Two"])
        XCTAssertEqual(move?.title, "Moved 2 tasks to Friday")
        XCTAssertTrue(reply(events).contains("2 tasks now on"))
        let set = events.compactMap { if case let .changes(set) = $0 { set } else { nil } }.first
        XCTAssertEqual(set?.count, 2)
        XCTAssertEqual(due("One"), "2026-09-25")
        try await runner.undo(changeSet: XCTUnwrap(set?.id))
        XCTAssertEqual(due("One"), "2026-09-28")
        XCTAssertEqual(due("Two"), "2026-09-29")
        XCTAssertEqual(due("Dentist"), "2026-09-25")
    }

    func testWithEveryTaskAlreadyOnTheDayNothingMoves() async throws {
        try addTask("Dentist", due: "2026-09-25")
        let kept = await collect(runner(), "tidy", allow: false)
        XCTAssertFalse(kept.contains { if case .changes = $0 { true } else { false } })
        XCTAssertFalse(kept.contains { if case let .stepStarted(step) = $0, case .move = step.kind { true } else { false } })
        XCTAssertTrue(reply(kept).contains("Nothing has been changed."))

        let gone = await collect(runner(), "tidy", allow: true)
        XCTAssertFalse(reply(gone).contains("Nothing has been changed."), "A delete is a change")
        XCTAssertTrue(reply(gone).contains("One task is gone."))
    }

    func testRepliesCarryKeyWordsAndAStepPerTool() async throws {
        try addTask("One", due: "2026-09-10")
        let events = await collect(runner(), "tidy")
        let text = events.compactMap { if case let .textDelta(text) = $0 { text } else { nil } }.joined()
        XCTAssertTrue(text.contains("**Friday**"))
        let move = events.compactMap { event -> AgentStep? in
            if case let .stepFinished(step) = event, case .move = step.kind { step } else { nil }
        }.first
        XCTAssertEqual(move?.state, .done)
        XCTAssertEqual(move?.targets.first?.title, "One")
    }

    func testCancelEndsTheStreamAtAnApproval() async throws {
        for (title, day) in [("One", "2026-09-10"), ("New Reminder", "2026-09-13")] { try addTask(title, due: day) }
        let runner = runner()
        var finished = false
        for await event in runner.send("tidy", watching: false) {
            if case .approvalNeeded = event { runner.cancel() }
            if case .finished = event { finished = true }
        }
        XCTAssertFalse(finished)
        XCTAssertTrue(store.tasks.contains { $0.title == "New Reminder" })
    }
}

/// The chat on the real bar: what a closed chat costs, and how it comes and goes.
@MainActor
final class AgentChatHostedTests: XCTestCase {
    private var model: AgentChatModel!
    private var runner: FakeRunner!
    private var chrome: PanelSharedChrome!
    private var topRow: PanelTopRowState!
    private var window: NSWindow!
    private var fx: AgentChatFX { AgentChatHost.lastFX! }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testA11yChatNamesControlsAndEscapeClosesOneLevel() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
                                  "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXLink"]
        func inspect(_ state: String, field: Bool, picker: Bool = false) throws {
            guard let root = window.contentView else { return XCTFail("chat host") }
            var visited = Set<ObjectIdentifier>()
            var interactive = 0
            var missing: [String] = []
            var identifiers = Set<String>()
            func walk(_ node: AnyObject) {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return }
                if let id = node.accessibilityIdentifier?() { identifiers.insert(id) }
                if let role = node.accessibilityRole?()?.rawValue, roles.contains(role) {
                    interactive += 1
                    if (node.accessibilityLabel?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        missing.append("\(role) \(node.accessibilityIdentifier?() ?? "")")
                    }
                }
                for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject) }
            }
            walk(root)
            print("A11Y_CHAT state=\(state) interactive=\(interactive) missing=\(missing)")
            XCTAssertGreaterThan(interactive, 0)
            XCTAssertTrue(missing.isEmpty, "chat \(state) has unnamed controls: \(missing)")
            XCTAssertEqual(identifiers.contains("agent-chat-field"), field, "chat field visible in \(state)")
            XCTAssertEqual(identifiers.contains("agent-chat-pick-field"), picker,
                           "only the open picker exposes its replacement search field")
        }
        model.open()
        spin(0.45)
        try inspect("open", field: true)
        model.pickingItem = true
        spin(0.2)
        try inspect("picker", field: false, picker: true)
        model.escape()
        spin(0.2)
        XCTAssertFalse(model.pickingItem, "first Escape closes the item picker")
        XCTAssertTrue(model.isOpen, "first Escape must preserve the chat")
        try inspect("returned", field: true)
        model.escape()
        spin(0.8)
        XCTAssertFalse(model.isOpen, "second Escape closes chat")
        try inspect("closed", field: false)
    }

    func testSA5ComposerPhaseGeometryRespectsReduceMotion() {
        XCTAssertNil(AgentChatComposer.phaseAnimation(alive: false), "Reduce Motion must move composer geometry instantly")
        XCTAssertNotNil(AgentChatComposer.phaseAnimation(alive: true), "Standard composer motion stays enabled")
    }

    override func setUp() async throws {
        model = AgentChatModel()
        model.pacing = .instant
        runner = FakeRunner()
        model.connect(runner)
        chrome = PanelSharedChrome()
        topRow = PanelTopRowState()
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let root = ZStack(alignment: .bottom) {
            PanelSharedBottomBar(chrome: chrome, page: .tasks, layout: layout, agentChat: model)
            AgentChatHost(bar: model.bar, room: PanelComposerRoom(), model: model, layout: layout, page: .tasks, chrome: chrome,
                          rows: { _ in [] }, selectPage: { _ in }, setTyping: { _ in })
        }
        .frame(width: 340, height: 560)
        .environment(\.panelSharedChrome, chrome)
        .environment(\.panelTopRowState, topRow)
        .atticDesign(.default)
        window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 340, height: 560),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        AgentChatStage.bodyEvaluations = 0
        AgentChatStage.chipFlights = []
        spin(0.2)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        spin(0.05)
    }

    func testTheBarDrawsTheStarOnlyWhenConnected() {
        XCTAssertTrue(PanelSharedBottomBar.drawsAgentChat)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let plain = NSHostingView(rootView: PanelSharedBottomBar(chrome: PanelSharedChrome(), page: .tasks, layout: layout,
                                                                 agentChat: AgentChatModel()).atticDesign(.default))
        plain.frame = CGRect(x: 0, y: 0, width: 340, height: 60)
        plain.layoutSubtreeIfNeeded()
        spin(0.05)
        XCTAssertFalse(PanelSharedBottomBar.drawsAgentChat)
    }

    func testARunWhileClosedTouchesNeitherTheBarsBodyNorTheStage() {
        let before = PanelSharedBottomBar.bodyEvaluations
        model.draft = "tidy"
        model.send()
        spin(0.05)
        for index in 0..<30 {
            runner.continuation?.yield(.progress(done: index, total: 30))
            runner.continuation?.yield(.textDelta("word "))
            spin(0.005)
        }
        runner.continuation?.yield(.finished)
        spin(0.1)
        XCTAssertEqual(model.bar.state, .done)
        XCTAssertEqual(PanelSharedBottomBar.bodyEvaluations, before, "The ✦ redraws alone")
        XCTAssertEqual(AgentChatStage.bodyEvaluations, 0, "A closed chat builds nothing")
        XCTAssertFalse(AgentChatStage.isMounted)
    }

    func testOpeningTakesTheBarsRowAndClosingGivesItBack() {
        model.open()
        spin(0.15)
        XCTAssertTrue(AgentChatStage.isMounted)
        XCTAssertTrue(chrome.plusHandedOver, "The bar folds away: the composer takes its row")
        model.close()
        XCTAssertTrue(AgentChatStage.isMounted, "Still there for its closing motion")
        spin(0.7)
        XCTAssertFalse(AgentChatStage.isMounted)
        XCTAssertFalse(chrome.plusHandedOver)
    }

    func testTheTopRowFoldsAwayWhileTheChatIsOpen() {
        XCTAssertFalse(topRow.isAway(.tasks))
        model.open()
        spin(0.15)
        XCTAssertTrue(topRow.chatOver, "The old controls must not show through the blur")
        XCTAssertTrue(topRow.isAway(.tasks))
        model.close()
        spin(0.7)
        XCTAssertFalse(topRow.chatOver)
        XCTAssertFalse(topRow.isAway(.tasks))
    }

    /// While the chat watches the agent work, the page's own top row shows
    /// beside the chat's controls (the drawing's Calendar, f018–f030); under
    /// the blur it folds again.
    func testThePagesTopRowShowsWhileTheChatWatches() {
        let gate = WatchGate()
        model.currentPage = { .tasks }
        model.presentWatched = { _ in { await gate.wait() } }
        model.open()
        spin(0.15)
        XCTAssertTrue(topRow.isAway(.tasks), "Precondition: folded under the blur")
        model.draft = "open my calendar"
        model.send()
        spin(0.05)
        runner.continuation?.yield(.stepStarted(AgentStep(id: UUID(), title: "Opening Calendar", kind: .openPage,
                                                          targets: [AgentTarget(page: .calendar)], state: .running)))
        for _ in 0..<60 where model.watch != .watching { spin(0.05) }
        spin(0.1)
        XCTAssertEqual(model.watch, .watching, "Precondition: the glass has cleared")
        XCTAssertTrue(topRow.chatOver, "The chat is still open")
        XCTAssertTrue(topRow.chatWatching)
        XCTAssertFalse(topRow.isAway(.tasks), "The page's top row shows while the agent works")
        XCTAssertFalse(topRow.isAway(.calendar), "And on the page it switches to")
        gate.open()
        for _ in 0..<60 where model.watch != .none { spin(0.05) }
        spin(0.1)
        XCTAssertEqual(model.watch, .none)
        XCTAssertFalse(topRow.chatWatching)
        XCTAssertTrue(topRow.isAway(.calendar), "The blur back, the top row folds again")
    }

    private func backdropView() -> AgentChatBackdropView? {
        func find(_ view: NSView) -> AgentChatBackdropView? {
            if let found = view as? AgentChatBackdropView { return found }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// Mid-opening, the blur is part way and at the thread's circle: a
    /// representable alone is handed only the wipe's end, and the preview
    /// showed the whole panel blurred in its first frame.
    func testMidOpeningTheBlurIsPartWayAndAtTheThreadsCircle() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        model.seedExchangeForUITesting(asked: "Tell me a short hello.", reply: "Hi there!")
        model.open()
        spin(0.12)
        let blur = try XCTUnwrap(backdropView()?.appliedScale)
        XCTAssertLessThan(blur, 0.97, "The blur wipes; it is not all there at once")
        XCTAssertEqual(blur, try XCTUnwrap(AgentChatWipeReveal.lastScale), accuracy: 0.02, "One circle for the blur and the thread")
        spin(0.8)
        XCTAssertEqual(try XCTUnwrap(backdropView()?.appliedScale), 1, accuracy: 0.001)
    }

    /// Screen 9: the earlier reply was drawn over the page's still readable
    /// rows before the blur had covered them. It arrives with the wipe.
    func testTheThreadArrivesWithTheWipeNotBeforeIt() {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        model.seedExchangeForUITesting(asked: "Tell me a short hello.", reply: "Hi there!")
        AgentChatWipeReveal.lastScale = nil
        model.open()
        spin(0.01)
        XCTAssertLessThan(AgentChatWipeReveal.lastScale ?? 1, 0.2, "At the start of the wipe the thread is hidden with the blur")
        spin(1)
        XCTAssertEqual(AgentChatWipeReveal.lastScale ?? 0, 1, accuracy: 0.001, "Open, the whole thread shows")
    }

    func testPanelHidingRemovesTheStageAtOnce() {
        model.open()
        spin(0.15)
        model.panelDidHide()
        spin(0.05)
        XCTAssertFalse(AgentChatStage.isMounted)
        XCTAssertFalse(chrome.plusHandedOver)
    }

    private var weekIDs: [UUID] {
        model.entries.compactMap { if case .week = $0.content { $0.id } else { nil } }
    }

    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = findScrollView(in: child) { return found } }
        return nil
    }

    /// A finished exchange in the open chat: the message and a short reply.
    private func exchange(_ text: String) {
        model.draft = text
        model.send()
        spin(0.05)
        runner.continuation?.yield(.textDelta("All done, nothing else to do here."))
        spin(0.1)
        runner.continuation?.yield(.finished)
        spin(0.6)
    }

    func testTheSecondMessageLandsWhereTheFirstDid() {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        model.open()
        spin(0.2)
        exchange("hi")
        let first = fx.turnTop
        exchange("hi")
        XCTAssertEqual(fx.turnTop ?? 0, first ?? -1, accuracy: 0.5, "Each message rests at the same height")
        XCTAssertGreaterThan(AgentChatThread.lastOutgoingTravel, 20, "The earlier exchange moves up, it doesn't vanish")
    }

    func testTheEarlierExchangeIsStillThereAboveTheNewOne() {
        model.open()
        spin(0.2)
        exchange("hi")
        exchange("hi again")
        let top = fx.turnTop ?? 0
        let scroll = try? XCTUnwrap(findScrollView(in: window.contentView))
        scroll?.contentView.scroll(to: .zero)
        scroll?.reflectScrolledClipView(scroll!.contentView)
        spin(0.1)
        XCTAssertGreaterThan(fx.turnTop ?? 0, top + 40, "Scrolling back up shows the earlier exchange, clear of the top")
        XCTAssertEqual(model.entries.filter { if case .asked = $0.content { true } else { false } }.count, 2)
    }

    /// One run in the open chat: reads the calendar, moves a task to `day`.
    private func runMoving(to day: Date) {
        model.draft = "tidy"
        model.send()
        spin(0.05)
        var read = AgentStep(id: UUID(), title: "Checking", kind: .read,
                             targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)], state: .running)
        runner.continuation?.yield(.stepStarted(read))
        spin(0.1)
        read.state = .done
        runner.continuation?.yield(.stepFinished(read))
        spin(0.1)
        runner.continuation?.yield(.stepStarted(AgentStep(id: UUID(), title: "Moving", kind: .move(toDay: day),
                                                          targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "Call")],
                                                          state: .running)))
        spin(0.5)
    }

    func testChipsHaveASlotWhenTheDestinationIsAnotherWeek() {
        model.open()
        spin(0.1)
        runMoving(to: Calendar.autoupdatingCurrent.date(byAdding: .day, value: 14, to: Date())!)
        XCTAssertEqual(AgentChatStage.chipFlights, weekIDs)
    }

    func testALaterRunsChipsFlyToItsOwnStrip() {
        let day = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 14, to: Date())!
        model.open()
        spin(0.1)
        runMoving(to: day)
        runner.continuation?.yield(.finished)
        spin(0.2)
        runMoving(to: day)
        XCTAssertEqual(weekIDs.count, 2)
        XCTAssertEqual(AgentChatStage.chipFlights, weekIDs)
    }

    func testFullThreadRendersWithOneRunThrough() {
        model.open()
        spin(0.1)
        model.draft = "tidy"
        model.send()
        spin(0.05)
        let day = Date()
        var move = AgentStep(id: UUID(), title: "Moving", kind: .move(toDay: day),
                             targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "Call")], state: .running)
        runner.continuation?.yield(.stepStarted(move))
        spin(0.05)
        move.state = .done
        runner.continuation?.yield(.stepFinished(move))
        runner.continuation?.yield(.textDelta("All on **Friday**."))
        runner.continuation?.yield(.changes(AgentChangeSet(id: UUID(), title: "Changes", pages: [.tasks], count: 1)))
        runner.continuation?.yield(.finished)
        spin(1.2)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.entries.count, 5, "Sent, step, week, reply, changes")
        // At rest means after the moved chip has landed on the week strip
        // (0.82 s from its start, which can fall after the 1.2 s above):
        // its landing is the run's last change, not a loop.
        for _ in 0..<60 where !fx.isIdle { spin(0.05) }
        XCTAssertTrue(fx.isIdle, "Everything has landed")
        // Bounded: a thread at rest stops updating (no layout feedback loop).
        let rest = AgentChatStage.bodyEvaluations
        spin(0.5)
        XCTAssertEqual(AgentChatStage.bodyEvaluations, rest)
    }
}

/// The alive layer stops asking for frames once nothing moves.
@MainActor
final class AgentChatFXTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func run(_ fx: AgentChatFX, seconds: Double) {
        var date = Date()
        for _ in 0..<Int(seconds * 60) {
            date += 1 / 60
            fx.advance(to: date)
        }
        spin(0.01)
    }

    func testAnOpenChatAtRestGoesIdleAndAnEffectWakesIt() {
        let fx = AgentChatFX()
        fx.emptyThread = false
        run(fx, seconds: 4)
        XCTAssertTrue(fx.isIdle, "Nothing moving: the timelines pause")
        fx.burst(10, 10)
        XCTAssertFalse(fx.isIdle)
        XCTAssertGreaterThan(fx.liveCount, 0)
        run(fx, seconds: 4)
        XCTAssertEqual(fx.liveCount, 0)
        XCTAssertTrue(fx.isIdle)
    }

    /// The spark heading past the stage's edge (to the island) hands the
    /// layer to the reach window; back inside, the stage draws it again.
    func testTheSparkReachesPastTheEdgeAndComesBack() {
        let fx = AgentChatFX()
        fx.acting = true
        // The stage's size, as a frame would draw it.
        let renderer = ImageRenderer(content: Canvas { context, size in fx.draw(in: &context, size: size) }
            .frame(width: 300, height: 500))
        _ = renderer.cgImage
        XCTAssertEqual(fx.stageSize, CGSize(width: 300, height: 500), "Precondition: the stage has drawn")
        fx.point(at: CGPoint(x: 150, y: 620))
        XCTAssertFalse(fx.reachesOut, "Nothing to draw it in: the stage keeps it")
        fx.canReachOut = true
        fx.point(at: CGPoint(x: 150, y: 250))
        XCTAssertFalse(fx.reachesOut, "Inside, the stage draws it")
        fx.point(at: CGPoint(x: 150, y: 620))
        XCTAssertTrue(fx.reachesOut, "Past the edge: the window takes over before the spark moves")
        run(fx, seconds: 1)
        fx.tap(at: CGPoint(x: 150, y: 620))
        run(fx, seconds: 0.2)
        XCTAssertTrue(fx.reachesOut, "Still out while the spark and its ring are there")
        fx.point(at: CGPoint(x: 150, y: 250))
        run(fx, seconds: 2)
        XCTAssertFalse(fx.reachesOut, "Back inside, once the ring and stars have gone")
    }

    func testWorkingKeepsItAwake() {
        let fx = AgentChatFX()
        fx.emptyThread = false
        fx.acting = true
        run(fx, seconds: 3)
        XCTAssertFalse(fx.isIdle)
    }

    func testAChipLandsThenUndoFliesItHomeAndSettlesDust() {
        let fx = AgentChatFX()
        fx.emptyThread = false
        let step = UUID()
        var landed = 0
        fx.fly(step: step, [(title: "Call", row: CGRect(x: 10, y: 100, width: 200, height: 28),
                             to: CGPoint(x: 50, y: 20), onLand: { landed += 1 })])
        fx.turnToDust(step: step, [CGRect(x: 10, y: 140, width: 200, height: 28)])
        run(fx, seconds: 2.5)
        XCTAssertEqual(landed, 1)
        XCTAssertEqual(fx.liveCount, 0)
        fx.undo(steps: [step])
        XCTAssertGreaterThan(fx.liveCount, 100, "A chip and the dust coming back")
        run(fx, seconds: 2.5)
        XCTAssertEqual(fx.liveCount, 0)
        XCTAssertEqual(landed, 1, "Going home lands nothing on the week")
    }

    func testOpeningDrawsNoRingAcrossTheComposerAndLeavesNothingBehind() {
        let fx = AgentChatFX()
        fx.composerFrame = CGRect(x: 10, y: 480, width: 300, height: 62)
        fx.emptyThread = true
        fx.open(at: CGPoint(x: 250, y: 520))
        XCTAssertEqual(fx.ringCount, 0, "No ring over the composer as it grows")
        XCTAssertEqual(fx.liveCount, 0, "No stars burst from the ✦: they spread as a dotted halo round it")
        run(fx, seconds: 0.12)
        XCTAssertEqual(fx.liveCount, 0, "Nothing around the ✦ while the composer grows")
        run(fx, seconds: AgentChatWipe.opening.duration + 0.05)
        XCTAssertEqual(fx.liveCount, 0, "The opening's stars end with the wipe")
        run(fx, seconds: 0.3)
        XCTAssertEqual(fx.liveCount, 0, "Nothing rises in the first second")
    }

    func testTheShimmerNeverLosesItsLine() throws {
        // The glass behind the line in the owner's recording, and the 3:1
        // floor WCAG sets for text that only has to stay legible.
        let glass = (r: 0.76, g: 0.76, b: 0.79)
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        func contrast(_ color: Color) throws -> Double {
            let srgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            let a = luminance(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
            let b = luminance(glass.r, glass.g, glass.b)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        let ink = Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)
        let highlight = AgentIris.shimmer(over: ink)
        XCTAssertGreaterThanOrEqual(try contrast(highlight.blue), 3)
        XCTAssertGreaterThanOrEqual(try contrast(highlight.pink), 3)
    }

    func testBackdropWipesWithASoftEdgeOnBothLayers() throws {
        let view = AgentChatBackdropView()
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 560)
        view.layout()
        view.apply(reveal: 0.4, origin: CGPoint(x: 280, y: 530), fades: false)
        let layers = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertFalse(layers.isEmpty)
        for layer in layers {
            let mask = try XCTUnwrap(layer.mask as? CAGradientLayer, "A hard path edge slices through text")
            XCTAssertEqual(mask.type, .radial)
            XCTAssertNil(mask.animation(forKey: "wipe"), "No clock of its own: it moves with the rest of the opening")
            XCTAssertEqual(mask.locations?.dropFirst().first?.doubleValue ?? 0, Double(1 - AgentChatWipe.feather), accuracy: 0.001)
        }
    }

    func testTheWipeFollowsItsCurveFromTheStar() {
        let timing = AgentChatWipe.opening
        XCTAssertEqual([timing.x1, timing.y1, timing.x2, timing.y2, timing.duration], [0.3, 0.7, 0.2, 1, 0.62])
        XCTAssertEqual([AgentChatWipe.closing.x1, AgentChatWipe.closing.y1, AgentChatWipe.closing.x2, AgentChatWipe.closing.y2,
                        AgentChatWipe.closing.duration], [0.5, 0, 0.8, 0.4, 0.4])
        let wipe = AgentChatWipe(origin: CGPoint(x: 280, y: 530), size: CGSize(width: 340, height: 560))
        XCTAssertEqual(wipe.scale(reveal: 0) * wipe.fullRadius, 0.5, accuracy: 0.001, "Closed: half a point at the ✦")
        XCTAssertEqual(wipe.scale(reveal: 1), 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(wipe.fullRadius * (1 - AgentChatWipe.feather), hypot(280, 530) - 0.5,
                                    "Fully open, the solid part reaches every corner")
    }

    /// Screen 9, item 21, stepped and paused: at every point of the wipe the
    /// blur, the colour over it and the thread are drawn at one circle.
    func testBlurColourAndThreadShareOneCircleAtEveryStep() throws {
        let size = CGSize(width: 340, height: 560)
        let star = CGPoint(x: 280, y: 530)
        let wipe = AgentChatWipe(origin: star, size: size)
        let view = AgentChatBackdropView()
        view.frame = CGRect(origin: .zero, size: size)
        view.layout()
        let fx = AgentChatFX()
        fx.wipeOrigin = star
        for step in 1...9 {
            let reveal = CGFloat(step) / 10
            view.apply(reveal: reveal, origin: star, fades: false)
            let blur = try XCTUnwrap(view.appliedScale)
            fx.lastAuraScale = nil
            AgentChatWipeReveal.lastScale = nil
            let aura = ImageRenderer(content: AgentChatAuraLayer(fx: fx, reveal: reveal).frame(width: size.width, height: size.height))
            _ = aura.nsImage
            let thread = ImageRenderer(content: Color.red
                .modifier(AgentChatWipeReveal(reveal: reveal, wipe: wipe, fades: false))
                .frame(width: size.width, height: size.height)
                .coordinateSpace(.named(AgentChatStage.space)))
            _ = thread.nsImage
            XCTAssertEqual(blur, wipe.scale(reveal: reveal), accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(fx.lastAuraScale), blur, accuracy: 0.0001, "The colour is where the blur is")
            XCTAssertEqual(try XCTUnwrap(AgentChatWipeReveal.lastScale), blur, accuracy: 0.0001,
                           "The thread shows only where the blur is")
        }
    }

    /// Reduce Motion: the blur and the thread fade in together.
    func testReducedMotionFadesTheBlurAndTheThreadTogether() throws {
        let view = AgentChatBackdropView()
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 560)
        view.layout()
        view.apply(reveal: 0.3, origin: CGPoint(x: 280, y: 530), fades: true)
        for layer in try XCTUnwrap(view.layer?.sublayers) {
            XCTAssertNil(layer.mask)
            XCTAssertEqual(layer.opacity, 0.3, accuracy: 0.001)
        }
        AgentChatWipeReveal.lastScale = nil
        _ = ImageRenderer(content: Color.red
            .modifier(AgentChatWipeReveal(reveal: 0.3, wipe: AgentChatWipe(origin: .zero, size: CGSize(width: 10, height: 10)),
                                          fades: true))
            .frame(width: 10, height: 10)).nsImage
        XCTAssertEqual(try XCTUnwrap(AgentChatWipeReveal.lastScale), 0.3, accuracy: 0.001)
    }

    func testClearLiveDropsLeftovers() {
        let fx = AgentChatFX()
        fx.dust(CGRect(x: 0, y: 0, width: 100, height: 20))
        fx.clearLive()
        XCTAssertEqual(fx.liveCount, 0)
    }
}

/// Draw's floating controls fold under the chat as the top row does (screen 9,
/// item 24): blurred, the title capsule stayed a bright patch and the tool bar
/// glowed through the composer.
@MainActor
final class AgentChatDrawFoldTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func find(_ id: String, in element: AnyObject, depth: Int = 0) -> AnyObject? {
        guard depth < 50 else { return nil }
        if (element.accessibilityIdentifier?() ?? nil) == id { return element }
        for child in (element.accessibilityChildren?() ?? nil) ?? [] {
            if let found = find(id, in: child as AnyObject, depth: depth + 1) { return found }
        }
        return nil
    }

    func testDrawsTitleAndToolsFoldWhileTheChatIsOver() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let topRow = PanelTopRowState()
        let model = DrawPageModel(store: DrawInMemoryStore())
        let size = CGSize(width: 320, height: 460)
        let host = NSHostingView(rootView: DrawPageHost(model: model, uiState: PanelUIState(),
                                                        layout: PanelPageLayout(cornerSize: 52, panelSize: size))
            .environment(\.panelTopRowState, topRow)
            .atticDesign(AtticDesignContext(mode: .dark))
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        spin(0.3)
        XCTAssertNotNil(find("draw-title", in: host), "Precondition: the title is there before the chat")
        XCTAssertNotNil(find("draw-tool-bar", in: host), "Precondition: the tools are there before the chat")
        topRow.chatOver = true
        spin(0.5)
        XCTAssertNil(find("draw-title", in: host), "The title capsule folds away under the chat")
        XCTAssertNil(find("draw-tool-bar", in: host), "The tool bar folds away under the chat")
        topRow.chatWatching = true
        spin(0.5)
        XCTAssertNotNil(find("draw-title", in: host), "Watching, the page's top row shows again, as drawn")
        XCTAssertNil(find("draw-tool-bar", in: host), "The tools stay folded under the composer")
        topRow.chatWatching = false
        spin(0.5)
        XCTAssertNil(find("draw-title", in: host), "The blur back, the title folds again")
        topRow.chatOver = false
        spin(0.5)
        XCTAssertNotNil(find("draw-title", in: host), "The title comes back when the chat closes")
        XCTAssertNotNil(find("draw-tool-bar", in: host))
    }
}

private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}

/// Holds a watched presentation until the test lets it go.
@MainActor
private final class WatchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// A surface that records what the writer did to it.
@MainActor
private final class FakeNoteSurface: AgentNoteSurface {
    var insertion: NoteAgentInsertion?
    var text = ""
    var veils: [Int] = []
    var lifts = 0

    func agentInsertion(since before: NoteDocument) -> NoteAgentInsertion? { insertion }
    func agentText(in range: NSRange) -> String { text }
    func veilAgentWriting(_ range: NSRange, shown: Int) -> CGRect? {
        veils.append(shown)
        return CGRect(x: CGFloat(shown), y: 10, width: 0, height: 14)
    }
    func liftAgentVeil() { lifts += 1 }
}

/// A watched run's note edit: saved at once, then shown being written
/// (Accepted 2026-11-06, "the living spark does the work").
@MainActor
final class AgentNoteWritingTests: XCTestCase {
    private var tasks: TaskStore!
    private var notes: NoteStore!
    private var tools: AgentTaskTools!
    private var model: AgentChatModel!
    private var noteID: UUID!
    private let checklist = "Press kit to Mira"

    private actor BA1DecodeGate {
        private(set) var waiting = false
        private var hold: CheckedContinuation<Void, Never>?
        func decode(_ bytes: Data) async -> (content: NoteContent, onMainThread: Bool) {
            waiting = true
            await withCheckedContinuation { hold = $0 }
            return (NoteContentCodec.decode(bytes), false)
        }
        func release() { hold?.resume(); hold = nil }
    }

    func testBA1LateWatchedOpenCannotChangeNoteOrPageAfterChatClosesAndReopens() async throws {
        let gate = BA1DecodeGate()
        let pages = NotesPageController(store: notes, journal: nil,
                                        decodeOpenDocument: { bytes in await gate.decode(bytes) })
        let chat = AgentChatModel()
        chat.open()
        let generation = chat.watchingGeneration
        var section: PanelSection = .tasks
        let open = Task {
            await AgentNoteWriter.openInNotes(noteID, before: nil, pages: pages, select: {
                // The former coordinator's watched navigation + unconditional fallback.
                if chat.isOpen { section = .notes }
                if section != .notes { section = .notes }
            }, stillWatching: { chat.isWatching(generation) })
        }
        for _ in 0..<200 { if await gate.waiting { break }; await Task.yield() }
        let waiting = await gate.waiting
        XCTAssertTrue(waiting, "the watched note's decoder must be held")
        chat.close()
        chat.open() // A later session must never adopt the earlier open.
        XCTAssertFalse(chat.isWatching(generation))
        await gate.release()
        _ = await open.value
        XCTAssertEqual(section, .tasks, "a closed watching session cannot navigate to Notes")
        XCTAssertNil(pages.active, "the stale decode cannot open a note in the background")
    }
    /// The presentation the model is waiting on, held until released.
    private var gate: CheckedContinuation<Void, Never>?
    private var presented: [UUID] = []
    private var pagesOpened: [AgentPage] = []

    override func setUp() async throws {
        tasks = try makeTestStore()
        notes = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        tools = AgentTaskTools(store: tasks, noteStore: notes, library: AtticLibrary(tasks: tasks, notes: notes))
        let made = try JSONSerialization.jsonObject(with: Data(tools.call(name: "create_note", arguments: [
            "title": "Write the launch blog post", "body": "Draft 3: Attic keeps your tasks and notes one keystroke away."
        ]).utf8)) as? [String: Any]
        noteID = try XCTUnwrap(((made?["note"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)))
        model = AgentChatModel()
        model.pacing = .instant
        model.currentPage = { .tasks }
        model.openPage = { [unowned self] in pagesOpened.append($0) }
        model.presentWatched = { [unowned self] action in
            guard case let .note(id) = action else { return nil }
            presented.append(id)
            return { await withCheckedContinuation { self.gate = $0 } }
        }
        model.connect(ScriptedAgentRunner(tools: tools, pace: 0))
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func run() async {
        model.draft = "Add a launch checklist to my blog post note"
        model.send()
        await settle()
    }

    private func release() async {
        gate?.resume()
        gate = nil
        await settle()
    }

    private var steps: [AgentStep] {
        model.entries.compactMap { if case let .step(step) = $0.content { step } else { nil } }
    }

    private var changes: (id: UUID, value: AgentChatChanges)? {
        model.entries.compactMap { if case let .changes(value) = $0.content { ($0.id, value) } else { nil } }.last
    }

    /// The note as saved, read through a store of its own.
    private func savedBody() -> String {
        let other = NoteStore(container: tasks.container, attachmentFileStore: makeTestAttachmentFileStore())
        guard let load = other.loadDocument(noteID: noteID), case let .editable(document) = load.content else { return "" }
        return NoteTextExport.agentBody(document)
    }

    func testTheEditIsSavedBeforeItIsShownBeingWritten() async {
        var back = 0
        let watch = model.effects.sink { if $0 == .watchEnded { back += 1 } }
        defer { watch.cancel() }
        model.open()
        await run()
        XCTAssertEqual(presented, [noteID], "Watching, the note is shown being written")
        XCTAssertNotNil(gate, "The writing is under way")
        XCTAssertTrue(savedBody().contains(checklist), "Mid-way, the whole edit is already saved")
        XCTAssertEqual(model.liveLabel, "Writing in your note")
        XCTAssertEqual(steps.last?.state, .running, "The row turns done once it has been written")
        XCTAssertEqual(back, 0, "The keyboard stays put while it is written")
        await release()
        XCTAssertNil(model.liveLabel, "Then the chat comes back")
        XCTAssertEqual(back, 1, "and the composer has the keyboard again")
        XCTAssertEqual(steps.last?.state, .done)
        XCTAssertEqual(steps.last?.title, "Added a checklist to your note")
        XCTAssertEqual(changes?.value.items.map(\.title), ["Write the launch blog post"])
    }

    func testUndoPutsTheNoteBackWhileItIsOnScreen() async throws {
        let before = savedBody()
        model.open()
        await run()
        await release()
        await settle()
        // The watched write left the note open on the Notes page.
        notes.agentWriteDisposition = { _ in .proposal }
        notes.agentUndoMayReplaceOnScreen = { _ in true }
        var reloaded: [UUID] = []
        notes.agentUndoReplacedOnScreen = { reloaded.append($0) }
        let id = try XCTUnwrap(changes?.id)
        model.undo(id)
        await settle()
        XCTAssertEqual(changes?.value.state, .undone)
        XCTAssertEqual(savedBody(), before, "Undo restores the note as before")
        XCTAssertEqual(reloaded, [noteID], "Its clean editor reloads")
        XCTAssertTrue(notes.pendingEdits(noteID: noteID).isEmpty, "Never a proposal of its own")
    }

    func testUndoKeepsAnEditorsUnsavedText() async throws {
        model.open()
        await run()
        await release()
        await settle()
        notes.agentWriteDisposition = { _ in .proposal }
        notes.agentUndoMayReplaceOnScreen = { _ in false }
        let id = try XCTUnwrap(changes?.id)
        model.undo(id)
        await settle()
        XCTAssertEqual(changes?.value.state, .ready)
        XCTAssertTrue(savedBody().contains(checklist))
    }

    func testAClosedRunBringsNoPageForwardAndCountsTheChange() async {
        await run()
        await settle()
        XCTAssertTrue(presented.isEmpty, "Closed: nothing is shown being written")
        XCTAssertTrue(pagesOpened.isEmpty, "Closed: no page comes forward")
        XCTAssertNil(model.liveLabel)
        XCTAssertTrue(savedBody().contains(checklist), "The change lands as before")
        XCTAssertEqual(model.bar.state, .changes(1), "The ✦ counts it")
    }

    func testClosingWhileWritingLetsTheRunGoOn() async {
        model.open()
        await run()
        XCTAssertEqual(model.liveLabel, "Writing in your note")
        model.close()
        XCTAssertNil(model.liveLabel, "The label goes with the chat")
        await release()
        XCTAssertEqual(steps.last?.state, .done)
    }

    // MARK: The writer

    private func writer(_ surface: FakeNoteSurface?, opened: @escaping (UUID) -> Void = { _ in }) -> AgentNoteWriter {
        let writer = AgentNoteWriter(open: { id, _, _ in opened(id); return surface }, base: { _ in NoteDocument(blocks: [.text("Before")]) })
        writer.pace = .init(character: 0.001, newline: 0.002, cap: 3, arrive: 0, settle: 0, hold: 0.01, frame: 0.001)
        return writer
    }

    func testTheWriterWritesTheAddedTextInAndLiftsTheVeil() async {
        let surface = FakeNoteSurface()
        surface.text = "Launch checklist\n– Visuals by Friday"
        surface.insertion = NoteAgentInsertion(range: NSRange(location: 10, length: (surface.text as NSString).length), replaces: false)
        var points: [CGPoint] = []
        let present = writer(surface).presentation(for: UUID(), watching: { true }, point: { p, _ in points.append(p) })
        await present?()
        XCTAssertEqual(surface.veils.first, 0, "Nothing written yet when the note comes forward")
        XCTAssertEqual(surface.veils.last, (surface.text as NSString).length, "All of it in the end")
        XCTAssertEqual(surface.veils, surface.veils.sorted(), "Written in order")
        XCTAssertGreaterThan(surface.lifts, 0, "The veil is gone at the end")
        XCTAssertFalse(points.isEmpty, "The spark is the writing point")
    }

    func testReducedShowsTheNoteWithoutWriting() async {
        let surface = FakeNoteSurface()
        surface.text = "Launch checklist"
        surface.insertion = NoteAgentInsertion(range: NSRange(location: 0, length: 16), replaces: false)
        var opened = 0
        let writer = writer(surface, opened: { _ in opened += 1 })
        writer.reducesMotion = { true }
        await writer.presentation(for: UUID(), watching: { true }, point: { _, _ in })?()
        XCTAssertEqual(opened, 1, "The page still comes forward")
        XCTAssertTrue(surface.veils.isEmpty, "No typing: the text is there at once")
    }

    func testReplacedTextIsShownPlainly() async {
        let surface = FakeNoteSurface()
        surface.text = "New"
        surface.insertion = NoteAgentInsertion(range: NSRange(location: 0, length: 3), replaces: true)
        await writer(surface).presentation(for: UUID(), watching: { true }, point: { _, _ in })?()
        XCTAssertTrue(surface.veils.isEmpty)
    }

    func testNotWatchingTheWriterOpensNothing() async {
        var opened = 0
        let present = writer(FakeNoteSurface(), opened: { _ in opened += 1 })
            .presentation(for: UUID(), watching: { false }, point: { _, _ in })
        XCTAssertNil(present)
        XCTAssertEqual(opened, 0)
    }

    func testClosingMidWritingShowsItAllAtOnce() async {
        let surface = FakeNoteSurface()
        surface.text = String(repeating: "word ", count: 200)
        surface.insertion = NoteAgentInsertion(range: NSRange(location: 0, length: 1000), replaces: false)
        let writer = writer(surface)
        writer.pace = .init()
        var frames = 0
        let started = Date()
        await writer.presentation(for: UUID(), watching: { frames += 1; return frames < 6 }, point: { _, _ in })?()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6, "It stops at once")
        XCTAssertGreaterThan(surface.lifts, 0, "Lifting the veil shows the whole edit")
    }

    func testALongEditIsWrittenWithinTheCap() {
        let pace = AgentNoteWriter.Pace()
        let long = AgentNoteWriter.schedule(String(repeating: "A long line of text.\n", count: 200), pace: pace)
        XCTAssertLessThanOrEqual(long.last?.at ?? 0, pace.cap + 0.001)
        let design = AgentNoteWriter.schedule("\n\nLaunch checklist\n– Final copy by Thursday\n– Visuals by Friday\n– Press kit to Mira", pace: pace)
        XCTAssertEqual(design.last?.at ?? 0, 77 * 0.026 + 5 * 0.15, accuracy: 0.001, "The design's checklist keeps the design's pace")
        XCTAssertEqual(design.last?.end, ("\n\nLaunch checklist\n– Final copy by Thursday\n– Visuals by Friday\n– Press kit to Mira" as NSString).length)
    }

    func testTheAddedSpanIsFoundAgainstTheTextBefore() {
        let append = NoteEditorEngine.agentInsertion(from: "Title\nDraft", to: "Title\nDraft\nLaunch checklist")
        XCTAssertEqual(append, NoteAgentInsertion(range: NSRange(location: 11, length: 17), replaces: false))
        let middle = NoteEditorEngine.agentInsertion(from: "A\nC", to: "A\nB\nC")
        XCTAssertEqual(middle?.range, NSRange(location: 2, length: 2))
        XCTAssertEqual(NoteEditorEngine.agentInsertion(from: "Title\nOld", to: "Title\nNew")?.replaces, true)
        XCTAssertNil(NoteEditorEngine.agentInsertion(from: "Same", to: "Same"))
    }
}

/// Watching (Accepted 2026-11-06, "open means watching"; gaps 09, 14–22):
/// one mechanism shows every change the agent makes on a page, each saved
/// before any of it shows.
@MainActor
final class AgentChatWatchingTests: XCTestCase {
    private var tasks: TaskStore!
    private var backend: FakeCalendarEventWriteStore!
    private var draw: DrawPersistentStore!
    private var actions: AgentActions!
    private var model: AgentChatModel!
    private var canvasID: UUID!
    private var launchDay: DrawObject!
    private var gate: CheckedContinuation<Void, Never>?
    private var presented: [AgentWatchedAction] = []
    private var pagesOpened: [AgentPage] = []

    func testBA4ClosingWatchingClearsDeferredCalendarDayAndOldSessionCannotReuseIt() async throws {
        let chat = AgentChatModel()
        let board = AgentWatchBoard()
        let watcher = PanelAgentWatcher(chat: chat,
            noteWriter: AgentNoteWriter(open: { _, _, _ in nil }, base: { _ in nil }), board: board)
        watcher.pace = .instant
        watcher.reducesMotion = { true }
        watcher.currentPage = { .calendar }
        chat.open()
        let occurrence = "held@\(Date().timeIntervalSinceReferenceDate)"
        await watcher.presentation(for: .calendarEvent(AgentTarget(page: .calendar, externalID: occurrence)))?()
        XCTAssertNotNil(board.dayRequest, "a watched event requests its day")
        let request = try XCTUnwrap(board.dayRequest)
        XCTAssertFalse(board.acceptsDayRequest(id: request.id, generation: request.generation, pageIsVisible: false),
                       "a retained, hidden Calendar must ignore the day")
        XCTAssertTrue(board.acceptsDayRequest(id: request.id, generation: request.generation, pageIsVisible: true))
        chat.close()
        XCTAssertNil(board.dayRequest, "a closed chat must retire its unpublished day request")
        XCTAssertFalse(board.acceptsDayRequest(id: request.id, generation: request.generation, pageIsVisible: true),
                       "a retired generation cannot override a manual day selection")
        chat.open()
        XCTAssertNil(board.dayRequest, "a new watch session must not reuse the old day")
    }

    override func setUp() async throws {
        tasks = try makeTestStore()
        let library = AtticLibrary(tasks: tasks)
        backend = FakeCalendarEventWriteStore()
        backend.availableCalendars = [CalendarWriteCalendar(
            id: "home", title: "Home", colour: .init(red: 0.2, green: 0.5, blue: 0.8),
            sourceID: "local", sourceTitle: "Local", isWritable: true)]
        let writer = EventKitCalendarEventWriter(store: backend, record: try CalendarOwnershipRecord(), undoRoute: library.undo)
        draw = DrawPersistentStore(container: try ModelContainer(
            for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        canvasID = draw.create(name: "Launch plan").id
        // Launch day, already sketched.
        launchDay = DrawObject(frame: DrawFrame(x: 240, y: 160, width: 100, height: 44), zIndex: 1, content: .text("Launch day"))
        XCTAssertTrue(draw.perform(.put([launchDay]), on: canvasID).isSaved)
        let tools = AgentTaskTools(store: tasks, library: library)
        actions = AgentActions(tasks: tools, calendarSource: CalendarEventSourceStub(), calendarWriter: writer, draw: draw)
        model = AgentChatModel()
        model.pacing = .instant
        model.currentPage = { .tasks }
        model.openPage = { [unowned self] in pagesOpened.append($0) }
        model.presentWatched = { [unowned self] action in
            presented.append(action)
            return { await withCheckedContinuation { self.gate = $0 } }
        }
        model.connect(ScriptedAgentRunner(tools: tools, actions: actions, mode: { [unowned self] in model.mode }, pace: 0))
    }

    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private func run(_ text: String) async {
        model.draft = text
        model.send()
        await settle()
    }

    private func release() async {
        gate?.resume()
        gate = nil
        await settle()
    }

    private var steps: [AgentStep] {
        model.entries.compactMap { if case let .step(step) = $0.content { step } else { nil } }
    }

    private var changes: (id: UUID, value: AgentChatChanges)? {
        model.entries.compactMap { if case let .changes(value) = $0.content { ($0.id, value) } else { nil } }.last
    }

    /// The canvas as saved, read through a store of its own: what a relaunch finds.
    private func savedObjects() throws -> [DrawObject] {
        try DrawPersistentStore(container: draw.container).open(canvasID).objects.filter { $0.deletedAt == nil }
    }

    // MARK: Committed before shown

    /// The composer's page chip names the new page once the action has been
    /// seen and the chat comes back, as drawn, not at the switch.
    func testThePageChipTurnsOverAfterTheActionNotAtTheSwitch() async {
        model.mode = .auto
        model.open()
        XCTAssertEqual(model.chipPage, .tasks)
        await run("Put the dentist on Friday morning")
        guard case .calendarEvent? = presented.last else { return XCTFail("The event is shown being added: \(presented)") }
        // The watcher switches the page part way; the panel reports it.
        model.pageChanged(to: .calendar)
        XCTAssertTrue(model.isOpen, "The agent's own switch keeps the chat open")
        XCTAssertEqual(model.watch, .watching)
        XCTAssertEqual(model.chipPage, .tasks, "While the event is added, the chip is unchanged")
        await release()
        XCTAssertEqual(model.watch, .none, "The chat is back")
        XCTAssertEqual(model.chipPage, .calendar, "Now the chip names Calendar")
    }

    func testACalendarEventIsSavedBeforeItIsShown() async throws {
        model.mode = .auto
        model.open()
        await run("Put the dentist on Friday morning")
        guard case let .calendarEvent(target)? = presented.last else { return XCTFail("The event is shown being added: \(presented)") }
        XCTAssertNotNil(gate, "It is on screen now")
        XCTAssertEqual(backend.events.values.map(\.draft.title), ["Dentist"], "Mid-way, the event is already saved")
        XCTAssertEqual(target.externalID, backend.events.values.first?.occurrenceID)
        XCTAssertEqual(model.watch, .watching, "The glass has cleared")
        XCTAssertEqual(model.liveLabel, "Adding it to your calendar", "The step's own words over the composer")
        XCTAssertEqual(steps.last?.state, .running, "The row turns done once it has been seen")
        await release()
        XCTAssertEqual(model.watch, .none, "Then the chat comes back")
        XCTAssertNil(model.liveLabel)
        XCTAssertEqual(steps.last?.title, "Added Dentist to Friday")
        XCTAssertEqual(changes?.value.items.map(\.title), ["Dentist"])
    }

    func testASketchIsSavedBeforeItIsShown() async throws {
        model.open()
        await run("Add a press kit step to my launch sketch")
        guard case let .sketch(canvas, objects)? = presented.last else { return XCTFail("The sketch is shown being drawn: \(presented)") }
        XCTAssertEqual(canvas, canvasID)
        XCTAssertEqual(objects.count, 4, "The box, the arrow's two strokes and its words")
        XCTAssertNotNil(gate)
        // A quit now leaves the whole sketch saved.
        XCTAssertEqual(Set(try savedObjects().map(\.id)), Set(objects + [launchDay.id]))
        XCTAssertEqual(Set(try savedObjects().map(\.text).filter { !$0.isEmpty }), ["Launch day", "Press kit"])
        XCTAssertEqual(model.liveLabel, "Sketching on Launch plan")
        await release()
        XCTAssertEqual(model.watch, .none)
        XCTAssertEqual(steps.last?.title, "Added Press kit to your sketch")
    }

    // MARK: Not watching

    func testAClosedRunShowsNothingAndCountsTheChanges() async throws {
        model.mode = .auto
        await run("Put the dentist on Friday morning")
        await settle()
        XCTAssertTrue(presented.isEmpty, "Closed: nothing is shown being made")
        XCTAssertTrue(pagesOpened.isEmpty, "Closed: no page comes forward")
        XCTAssertEqual(model.watch, .none)
        XCTAssertNil(model.liveLabel)
        XCTAssertEqual(backend.events.count, 1, "The change lands as it would")
        XCTAssertEqual(model.bar.state, .changes(1), "The ✦ counts it")
        await run("Add a press kit step to my launch sketch")
        await settle()
        XCTAssertTrue(presented.isEmpty)
        XCTAssertEqual(try savedObjects().count, 5)
    }

    // MARK: Undo

    func testUndoRemovesTheEvent() async throws {
        model.mode = .auto
        model.open()
        await run("Put the dentist on Friday morning")
        await release()
        await settle()
        let id = try XCTUnwrap(changes?.id)
        model.undo(id)
        for _ in 0..<10 { await settle() }
        XCTAssertEqual(changes?.value.state, .undone)
        XCTAssertTrue(backend.events.isEmpty, "Undo takes the event off the calendar")
    }

    func testUndoRemovesTheSketch() async throws {
        model.open()
        await run("Add a press kit step to my launch sketch")
        await release()
        await settle()
        let id = try XCTUnwrap(changes?.id)
        model.undo(id)
        for _ in 0..<10 { await settle() }
        XCTAssertEqual(changes?.value.state, .undone)
        XCTAssertEqual(try savedObjects().map(\.id), [launchDay.id], "Undo takes the sketch off the canvas, and only it")
    }

    func testUndoWhileOnScreenLeavesNothingHidden() async throws {
        // The watcher hides what it is about to show; Undo while it is on
        // screen, or a close part-way, never leaves it hidden.
        let board = AgentWatchBoard()
        let chat = AgentChatModel()
        chat.connect(ScriptedAgentRunner(tools: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)), pace: 0))
        chat.open()
        let watcher = PanelAgentWatcher(chat: chat, noteWriter: AgentNoteWriter(open: { _, _, _ in nil }, base: { _ in nil }), board: board)
        watcher.pace = .instant
        watcher.currentPage = { .calendar }
        let occurrence = "dentist@\(Date().timeIntervalSinceReferenceDate)"
        let present = watcher.presentation(for: .calendarEvent(AgentTarget(page: .calendar, externalID: occurrence)))
        XCTAssertTrue(board.hiddenEvents.contains(occurrence), "Hidden before the page draws it")
        chat.close()
        await present?()
        XCTAssertTrue(board.hiddenEvents.isEmpty, "Closed part-way: it shows at once")
        XCTAssertTrue(board.growingEvents.isEmpty)
    }

    // MARK: Mode

    func testAskFirstShowsTheApprovalBeforeTheEvent() async throws {
        model.mode = .askFirst
        model.open()
        await run("Put the dentist on Friday morning")
        XCTAssertNotNil(model.approval, "The approval card comes first")
        XCTAssertTrue(presented.isEmpty, "Nothing is shown before it is allowed")
        XCTAssertTrue(backend.events.isEmpty, "Nor saved")
        XCTAssertEqual(model.watch, .none, "The chat stays as it is for the card")
        model.resolveApproval(allow: true)
        await settle()
        guard case .calendarEvent? = presented.last else { return XCTFail("Allowed, it is shown being added") }
        XCTAssertEqual(backend.events.count, 1)
        await release()
    }

    // MARK: Step beats

    func testTheStepQueueNeverDelaysTheRunsResult() async throws {
        let runner = BurstRunner()
        let chat = AgentChatModel()
        chat.pacing = AgentChatPacing()
        chat.connect(runner)
        chat.open()
        chat.draft = "Tidy"
        let sent = Date()
        chat.send()
        // The run finished at once; the thread's beats catch up within the
        // catch-up time, never one beat per step (8 × 0.96 s).
        while chat.isBusy, Date().timeIntervalSince(sent) < 6 { try await Task.sleep(for: .milliseconds(20)) }
        let caughtUp = Date().timeIntervalSince(sent)
        XCTAssertFalse(chat.isBusy)
        XCTAssertLessThan(caughtUp, chat.pacing.catchUp + 0.8, "The steps catch up with the run")
        XCTAssertEqual(stepStates(chat),
                       Array(repeating: .done, count: 8))
        // Closed, nothing is held at all.
        let closed = AgentChatModel()
        closed.pacing = AgentChatPacing()
        closed.connect(BurstRunner())
        closed.draft = "Tidy"
        let start = Date()
        closed.send()
        while closed.isBusy, Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }

    private func stepStates(_ chat: AgentChatModel) -> [AgentStepState] {
        chat.entries.compactMap { entry -> AgentStepState? in
            if case let .step(step) = entry.content { return step.state }
            return nil
        }
    }

    func testAStepShowsRunningForItsBeatWhenTheRunIsSlow() async throws {
        let runner = BurstRunner()
        runner.steps = 1
        let chat = AgentChatModel()
        chat.pacing = AgentChatPacing()
        chat.connect(runner)
        chat.open()
        chat.draft = "Read"
        chat.send()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stepStates(chat), [.running],
                       "A step that finished at once still shows running for its beat")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(stepStates(chat), [.done])
    }

    // MARK: Glass, label, hover

    func testReadingTasksThinsTheGlass() async throws {
        let runner = BurstRunner()
        runner.steps = 0
        let chat = AgentChatModel()
        chat.pacing = .instant
        chat.connect(runner)
        chat.open()
        chat.draft = "Read"
        chat.send()
        let step = AgentStep(id: UUID(), title: "Reading 7 overdue tasks", kind: .read,
                             targets: [AgentTarget(page: .tasks, itemID: UUID(), title: "A")], state: .running)
        runner.continuation?.yield(.stepStarted(step))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(chat.watch, .glance, "The rows being read show through")
        var done = step
        done.state = .done
        runner.continuation?.yield(.stepFinished(done))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(chat.watch, .none)
    }

    func testTheGlassLevels() {
        XCTAssertEqual(AgentWatchLevel.blurRadius(clearing: AgentWatchLevel.none.clearing), 5)
        XCTAssertEqual(AgentWatchLevel.blurRadius(clearing: AgentWatchLevel.glance.clearing), 1.5, accuracy: 0.001)
        XCTAssertEqual(AgentWatchLevel.blurRadius(clearing: AgentWatchLevel.watching.clearing), 0)
        XCTAssertEqual(AgentWatchLevel.tintShare(clearing: AgentWatchLevel.glance.clearing), 0.5)
    }

    func testHoveringAnUnderlinedPhrasePingsItsRow() {
        let row = UUID()
        model.rowTitles = { [(UUID(), "Call the dentist"), (row, "Renew the parking permit"), (UUID(), "Parking fine")] }
        var pings: [[UUID]] = []
        let sink = model.effects.sink { if case let .pingRows(ids) = $0 { pings.append(ids) } }
        defer { sink.cancel() }
        model.pingPhrase("parking permit")
        XCTAssertTrue(pings.isEmpty, "Closed, nothing to light")
        model.open()
        model.pingPhrase("parking permit")
        XCTAssertEqual(pings, [[row]], "The first row naming the phrase's first word, as drawn")
    }

    // MARK: The watcher

    func testReducedMotionBringsThePageWithoutTravel() async {
        let chat = AgentChatModel()
        chat.connect(ScriptedAgentRunner(tools: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)), pace: 0))
        chat.open()
        var opened: [AgentPage] = []
        chat.openPage = { opened.append($0) }
        var effects: [AgentChatEffect] = []
        let sink = chat.effects.sink { effects.append($0) }
        defer { sink.cancel() }
        let board = AgentWatchBoard()
        let watcher = PanelAgentWatcher(chat: chat, noteWriter: AgentNoteWriter(open: { _, _, _ in nil }, base: { _ in nil }), board: board)
        watcher.pace = .instant
        watcher.reducesMotion = { true }
        watcher.islandPoint = { _ in CGPoint(x: 10, y: 10) }
        var page: AgentPage = .tasks
        watcher.currentPage = { page }
        chat.openPage = { opened.append($0); page = $0 }
        let occurrence = "dentist@\(Date().timeIntervalSinceReferenceDate)"
        let present = watcher.presentation(for: .calendarEvent(AgentTarget(page: .calendar, externalID: occurrence)))
        XCTAssertFalse(board.hiddenEvents.contains(occurrence), "Reduced: the event is there at once")
        await present?()
        XCTAssertEqual(opened, [.calendar], "The page still comes forward")
        XCTAssertNotNil(board.dayRequest, "On its day")
        XCTAssertTrue(effects.isEmpty, "No travel, taps or bursts: \(effects)")
    }

    /// The reach window lies exactly over the stage and the island, even
    /// with the panel at the top of the screen (a window there was pushed
    /// down from under the menu bar, so the spark drew 67 pt below the
    /// island's dot).
    func testTheReachWindowLiesOverTheStageAndTheIsland() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = NSWindow(contentRect: CGRect(x: screen.frame.maxX - 420, y: screen.frame.maxY - 560, width: 400, height: 544),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let stage = FlippedTestView(frame: CGRect(x: 40, y: 40, width: 320, height: 464))
        panel.contentView?.addSubview(stage)
        panel.orderFront(nil)
        let stageFrame = panel.convertToScreen(stage.convert(stage.bounds, to: nil))
        let island = CGRect(x: stageFrame.midX - 95, y: stageFrame.minY - 55, width: 190, height: 71)
        let reach = AgentReachWindow()
        defer { reach.hide() }
        XCTAssertTrue(reach.show(fx: AgentChatFX(), stage: stage, over: panel, island: island))
        let frame = try XCTUnwrap(reach.window?.frame)
        XCTAssertEqual(frame.maxY, stageFrame.maxY, accuracy: 1, "Its top is the stage's: never moved down")
        XCTAssertEqual(frame.minY, island.minY - AgentReachWindow.margin, accuracy: 1, "Down past the island")
        XCTAssertEqual(frame.minX, stageFrame.minX - AgentReachWindow.margin, accuracy: 1)
        XCTAssertTrue(reach.window?.ignoresMouseEvents == true, "Clicks pass through")
        XCTAssertTrue(reach.window?.isVisible == true)
        reach.hide()
        XCTAssertFalse(reach.window?.isVisible == true)
    }

    func testTheSparkTapsTheIslandBeforeThePageSwitches() async {
        let chat = AgentChatModel()
        chat.connect(ScriptedAgentRunner(tools: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)), pace: 0))
        chat.open()
        var log: [String] = []
        let sink = chat.effects.sink { effect in
            switch effect {
            case .pointer: log.append("pointer")
            case .tap: log.append("tap")
            default: break
            }
        }
        defer { sink.cancel() }
        let watcher = PanelAgentWatcher(chat: chat, noteWriter: AgentNoteWriter(open: { _, _, _ in nil }, base: { _ in nil }),
                                        board: AgentWatchBoard())
        watcher.pace = .instant
        watcher.islandPoint = { _ in CGPoint(x: 400, y: 300) }
        watcher.islandTap = { _ in log.append("island") }
        watcher.currentPage = { .tasks }
        chat.openPage = { log.append("switch \($0.rawValue)") }
        await watcher.presentation(for: .openPage(.calendar))?()
        XCTAssertEqual(log, ["pointer", "tap", "island", "switch calendar"])
        chat.close()
        XCTAssertNil(watcher.presentation(for: .openPage(.draw)), "Closed: nothing comes forward")
    }
}

/// A run that does all its work at once: steps, then its changes and the end.
@MainActor
private final class BurstRunner: AgentRunning {
    var steps = 8
    var continuation: AsyncStream<AgentEvent>.Continuation?
    var retainsThread = false

    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            guard steps > 0 else { return }
            for index in 0..<steps {
                var step = AgentStep(id: UUID(), title: "Step \(index)", kind: .read, targets: [], state: .running)
                continuation.yield(.stepStarted(step))
                step.state = .done
                continuation.yield(.stepFinished(step))
            }
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    func setWatching(_ watching: Bool) {}
    func resolve(approval id: UUID, allow: Bool) {}
    func undo(changeSet id: UUID) async throws {}
    func cancel() { continuation?.finish() }
    func observe() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func threadSnapshot() -> AgentThreadSnapshot { AgentThreadSnapshot(entries: [], events: [], isRunning: false) }
    func forgetThread() {}
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

/// Gap fixes 2 (Accepted 6 Nov, "Chat with an agent: floating, Chat life
/// alive"): the closed ✦'s states as drawn in `Preview - settings at
/// bottom.dc.html` (`[data-chat-trigger] svg`, `.ch-tg-need svg`,
/// `ch-breathe`).
@MainActor
final class AgentChatTriggerMotionTests: XCTestCase {
    func testNeedsYouBreathesOverOnePointTwoSecondsToOnePointOneEightWithEaseInOut() {
        typealias M = AgentChatTriggerMotion
        XCTAssertEqual(M.breathPeriod, 1.2)
        XCTAssertEqual(M.breath(at: 0), 1, accuracy: 0.0001, "each breath starts at scale 1")
        XCTAssertEqual(M.breath(at: 0.6), 1.18, accuracy: 0.0001, "and peaks at 1.18 half way")
        XCTAssertEqual(M.breath(at: 1.2), 1, accuracy: 0.0001)
        XCTAssertEqual(M.breath(at: 0.3), 1.09, accuracy: 0.0001, "ease-in-out is half way at half time")
        // CSS ease-in-out (0.42, 0, 0.58, 1): slow out of each end.
        XCTAssertEqual(M.breath(at: 0.06), 1 + 0.18 * CGFloat(AgentEase.curve(0.42, 0, 0.58, 1, 0.1)), accuracy: 0.0001)
        XCTAssertLessThan(M.breath(at: 0.06) - 1, 0.18 * 0.1, "slower than linear at the start")
        XCTAssertEqual(M.breath(at: 0.9), M.breath(at: 0.3), accuracy: 0.0001, "the way down mirrors the way up")
        XCTAssertEqual(M.breath(at: 1.8), 1.18, accuracy: 0.0001, "and it repeats")
    }

    func testOnlyNeedsYouBreathesAndReducedMotionKeepsItStill() {
        typealias M = AgentChatTriggerMotion
        XCTAssertTrue(M.breathes(.needsYou, reduceMotion: false))
        XCTAssertFalse(M.breathes(.needsYou, reduceMotion: true), "Reduce Motion or Animations: Reduced: no breath")
        for state: AgentChatBarState in [.idle, .working(step: nil, of: nil), .working(step: 2, of: 3), .changes(2), .done] {
            XCTAssertFalse(M.breathes(state, reduceMotion: false), "\(state): no motion on the closed ✦ (thinking has no look)")
            XCTAssertTrue(M.pose(state, hovered: false, reduceMotion: false, time: 0.6) == (0, 1))
        }
        XCTAssertTrue(M.pose(.needsYou, hovered: false, reduceMotion: true, time: 0.6) == (0, 1), "reduced: still")
    }

    func testHoverTurnsAndScalesTheGlyphButTheBreathWinsWhileItNeedsYou() {
        typealias M = AgentChatTriggerMotion
        XCTAssertTrue(M.pose(.idle, hovered: true, reduceMotion: false, time: 0) == (90, 1.14))
        XCTAssertTrue(M.pose(.working(step: 1, of: 3), hovered: true, reduceMotion: false, time: 0) == (90, 1.14))
        XCTAssertTrue(M.pose(.idle, hovered: true, reduceMotion: true, time: 0) == (0, 1))
        let pose = M.pose(.needsYou, hovered: true, reduceMotion: false, time: 0.6)
        XCTAssertTrue(pose == (0, 1.18), "the CSS animation replaces the hover's transform")
    }

    /// Off-screen renders of the real button at paused times, Light and
    /// Dark. Saved for the report (`GF2RENDER` in the log gives the folder).
    func testTheClosedTriggerRendersIdleWorkingAndNeedsYouAtPausedTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-gap-fixes-2-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("GF2RENDER \(folder.path)")
        func render(_ state: AgentChatBarState, _ time: Double, dark: Bool, reduced: Bool = false,
                    name: String) throws -> NSBitmapImageRep {
            var design = AtticDesignContext.default
            design.mode = dark ? .dark : .light
            design.reduceMotion = reduced
            // Glass draws as artefacts off-screen: the solid (craft) button
            // stands in, with the same glyph, label and motion.
            design.controls = .craft
            let root = AgentChatBarButton(bar: AgentChatBar(showing: state), action: {}, frozenTime: time)
                .environment(\.atticDesign, design)
                .padding(12)
                .frame(width: 150, height: 52, alignment: .leading)
                .background(dark ? Color(white: 0.13) : Color(white: 0.95))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 150, height: 52)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            return rep
        }
        /// Pixels that differ around the glyph (12 + 8 pt in, 13 pt square
        /// covers the 11 pt ✦ at 1.18).
        func glyphDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            let scale = CGFloat(a.pixelsWide) / 150
            XCTAssertEqual(a.pixelsHigh, Int(52 * scale), "the render keeps its 150 × 52 pt frame")
            var count = 0
            for y in Int(12 * scale)..<Int(40 * scale) {
                for x in Int(16 * scale)..<Int(36 * scale) {
                    guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                        + abs(p.blueComponent - q.blueComponent) > 0.06 { count += 1 }
                }
            }
            return count
        }
        for dark in [false, true] {
            _ = try render(.idle, 0, dark: dark, name: "idle")
            let working = try [0.0, 0.4, 0.8].map { try render(.working(step: 2, of: 3), $0, dark: dark, name: "working-\(Int($0 * 1000))ms") }
            let needsStart = try render(.needsYou, 0, dark: dark, name: "needs-start")
            let needsPeak = try render(.needsYou, 0.6, dark: dark, name: "needs-peak")
            let reducedStart = try render(.needsYou, 0, dark: dark, reduced: true, name: "needs-reduced-start")
            let reducedPeak = try render(.needsYou, 0.6, dark: dark, reduced: true, name: "needs-reduced-peak")
            XCTAssertEqual(glyphDifference(working[0], working[1]), 0, "Working: the closed ✦ holds still")
            XCTAssertEqual(glyphDifference(working[0], working[2]), 0)
            XCTAssertGreaterThan(glyphDifference(needsStart, needsPeak), 10, "Needs you: the ✦ grows at the breath's peak")
            XCTAssertEqual(glyphDifference(reducedStart, reducedPeak), 0, "reduced: no breath")
            XCTAssertEqual(glyphDifference(needsStart, reducedStart), 0, "the reduced Needs you is the breath's resting pose")
        }
    }
}
