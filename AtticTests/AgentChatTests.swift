import AppKit
import Combine
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

    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent> {
        sent.append((text, watching))
        return AsyncStream { self.continuation = $0 }
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
    private var window: NSWindow!

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    override func setUp() async throws {
        model = AgentChatModel()
        model.pacing = .instant
        runner = FakeRunner()
        model.connect(runner)
        chrome = PanelSharedChrome()
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let root = ZStack(alignment: .bottom) {
            PanelSharedBottomBar(chrome: chrome, page: .tasks, layout: layout, agentChat: model)
            AgentChatHost(bar: model.bar, room: PanelComposerRoom(), model: model, layout: layout, page: .tasks, chrome: chrome,
                          rows: { _ in [] }, selectPage: { _ in }, setTyping: { _ in })
        }
        .frame(width: 340, height: 560)
        .environment(\.panelSharedChrome, chrome)
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

    func testClearLiveDropsLeftovers() {
        let fx = AgentChatFX()
        fx.dust(CGRect(x: 0, y: 0, width: 100, height: 20))
        fx.clearLive()
        XCTAssertEqual(fx.liveCount, 0)
    }
}
