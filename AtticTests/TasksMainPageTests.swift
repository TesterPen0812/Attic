import SwiftData
import XCTest
@testable import Attic

/// The New list style's main page, part 2 (council D2 "Pick your Now",
/// owner 2026-10-26; Build B): the card in place (3A), the hotkey filing
/// into Later, the Due line, pick mode, and Find across every list.
@MainActor
final class TasksMainPageTests: XCTestCase {
    // Mon 21 Sep 2026, 12:00 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_789_992_000))
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!
    private var written: [(UUID, String)] = []
    private var writing = TaskNoteWriting.Snapshot(text: "Venues: Lisbon or Porto.", isPlain: true)

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        var services = TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        )
        services.readWriting = { [weak self] _ in self?.writing }
        services.writeWriting = { [weak self] id, text in
            self?.written.append((id, text))
            return true
        }
        model = TasksPageModel(library: library, services: services)
        model.toasts.holdDuration = 3_600
        model.setListStyle(.new)
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private var today: DueDay { DueDay(date: clock.value, calendar: calendar) }

    private func add(_ title: String, on tab: TasksTab = .now) throws -> UUID {
        if model.tab != tab { model.select(tab: tab) }
        model.addBar.text = title
        return try XCTUnwrap(model.submitAddBar())
    }

    private func titles(_ tab: TasksTab) -> [String] {
        model.rows(for: tab).map(\.model.title)
    }

    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: clock.value)!, calendar: calendar)
    }

    // MARK: The card: open, close and full

    func testTheCardOpensOneAtATimeGrowsFullAndShrinksBack() throws {
        let a = try add("Plan the team offsite")
        let b = try add("Call the plumber")
        model.openCard(a)
        XCTAssertEqual(model.mainPage.card?.taskID, a)
        XCTAssertEqual(model.mainPage.card?.isFull, false)
        XCTAssertEqual(model.selection, [a])

        model.openCard(b)
        XCTAssertEqual(model.mainPage.card?.taskID, b, "one card at a time")

        model.openCardFull()
        XCTAssertEqual(model.mainPage.card?.isFull, true)
        model.escapeCard()
        XCTAssertEqual(model.mainPage.card?.isFull, false, "Esc in full shrinks back to the card")
        XCTAssertEqual(model.mainPage.scrollRequest?.id, b, "back to the same row")

        model.escapeCard()
        XCTAssertNil(model.mainPage.card, "Esc again closes the card")
        XCTAssertEqual(model.selection, [b])
    }

    func testOnlyTheNewStyleOpensTheCard() throws {
        let a = try add("Plan the team offsite")
        model.setListStyle(.attic)
        model.openCard(a)
        XCTAssertNil(model.mainPage.card)
        model.setListStyle(.reminders)
        model.openCard(a)
        XCTAssertNil(model.mainPage.card)
    }

    // MARK: Saving as it goes; Esc keeps

    func testEveryFieldSavesAsItChangesAndEscKeepsThem() throws {
        let a = try add("Plan the offsite")
        model.openCard(a)
        XCTAssertTrue(model.commitCardTitle("Plan the team offsite").isApplied)
        XCTAssertEqual(store.task(withID: a)?.title, "Plan the team offsite", "saved at once, not on close")
        XCTAssertTrue(model.setCardPriority(.medium).isApplied)
        XCTAssertTrue(model.setCardDue(day(2)).isApplied)
        XCTAssertTrue(model.setCardTags(["planning", "work"]).isApplied)
        XCTAssertTrue(model.setCardFlag(true).isApplied)
        XCTAssertTrue(model.setCardLink("https://example.com/venues").isApplied)
        let task = try XCTUnwrap(store.task(withID: a))
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.dueDay, day(2))
        XCTAssertEqual(Set(task.tags), ["planning", "work"])
        XCTAssertTrue(task.isFlagged)
        XCTAssertEqual(task.url, "https://example.com/venues")

        model.escapeCard()
        XCTAssertNil(model.mainPage.card)
        XCTAssertEqual(store.task(withID: a)?.title, "Plan the team offsite", "Esc keeps")
        XCTAssertEqual(store.task(withID: a)?.priority, .medium, "Esc keeps")

        // ⌘Z undoes the last field, one step at a time.
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: a)?.url)
        XCTAssertEqual(store.task(withID: a)?.priority, .medium)
    }

    func testTheCardsWritingIsTheNotesOwnEditAndOnlyWhenPlain() async throws {
        let a = try add("Plan the team offsite")
        model.openCard(a)
        try await waitFor { self.model.mainPage.cardWriting != nil }
        XCTAssertEqual(model.mainPage.cardWriting?.text, "Venues: Lisbon or Porto.")
        let saved = await model.commitCardWriting("Venues: Lisbon or Porto. Ask Sam.", for: a)
        XCTAssertTrue(saved)
        XCTAssertEqual(written.map(\.1), ["Venues: Lisbon or Porto. Ask Sam."])

        // Formatted writing is never flattened from the card.
        model.closeCard()
        writing = .init(text: "Agenda\n• Roadmap", isPlain: false)
        model.openCard(a)
        try await waitFor { self.model.mainPage.cardWriting != nil }
        let refused = await model.commitCardWriting("Agenda", for: a)
        XCTAssertFalse(refused)
        XCTAssertEqual(written.count, 1)
    }

    func testMovingTheCardsTaskToLaterClosesItInNow() throws {
        let a = try add("Renew passport")
        model.openCard(a)
        XCTAssertTrue(model.setCardList(.backlog).isApplied)
        XCTAssertEqual(store.task(withID: a)?.status, .backlog)
        XCTAssertNil(model.mainPage.card, "its row left Now")
    }

    // MARK: Add subtask in the card

    func testAddSubtaskReturnMakesTheNextOne() throws {
        let a = try add("Plan the team offsite")
        model.openCard(a)
        XCTAssertTrue(model.addCardSubtask("Shortlist venues"))
        XCTAssertTrue(model.addCardSubtask("Book travel"))
        XCTAssertFalse(model.addCardSubtask("   "), "an empty line adds nothing")
        XCTAssertEqual(model.cardSubtasks().map(\.title), ["Shortlist venues", "Book travel"])
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(model.cardSubtasks().map(\.title), ["Shortlist venues"], "each subtask is one step")
    }

    // MARK: The hotkey files into Later

    func testTheHotkeyFilesIntoLaterAndTheAddBarIntoTheViewedList() throws {
        model.beginHotkeyCapture()
        XCTAssertEqual(model.addPlaceholder, "Add to later")
        let captured = try add("Buy stamps")
        XCTAssertEqual(store.task(withID: captured)?.status, .backlog, "nothing lands in Now by itself")
        model.endHotkeyCapture()
        let typed = try add("Email beta testers")
        XCTAssertEqual(store.task(withID: typed)?.status, .todo, "the add bar adds to the list being viewed")
        let later = try add("Renew passport", on: .backlog)
        XCTAssertEqual(store.task(withID: later)?.status, .backlog)
    }

    func testTheOtherStylesKeepTheHotkeyInNow() throws {
        model.setListStyle(.attic)
        model.beginHotkeyCapture()
        let captured = try add("Buy stamps")
        XCTAssertEqual(store.task(withID: captured)?.status, .todo)
        model.setListStyle(.reminders)
        model.beginHotkeyCapture()
        let replica = try add("Buy more stamps")
        XCTAssertEqual(store.task(withID: replica)?.status, .todo)
    }

    // MARK: The Due line

    func testTheDueLineShowsOnlyForTasksDueOutsideNow() throws {
        XCTAssertEqual(model.dueLine(), .none)
        let inNow = try add("Finalize launch checklist")
        XCTAssertTrue(library.updateTask(inNow, dueDay: .some(day(-1))).isApplied)
        XCTAssertEqual(model.dueLine(), .none, "a task in Now is never on the Due line")

        let bill = try add("Pay the electricity bill", on: .backlog)
        XCTAssertTrue(library.updateTask(bill, dueDay: .some(day(1))).isApplied)
        XCTAssertEqual(model.dueLine(), .none, "due tomorrow is not due yet")
        XCTAssertTrue(library.updateTask(bill, dueDay: .some(day(-3))).isApplied)
        XCTAssertEqual(model.dueLine(), .one(id: bill, title: "Pay the electricity bill", due: day(-3)))

        let rent = try add("Pay rent", on: .backlog)
        XCTAssertTrue(library.updateTask(rent, dueDay: .some(today)).isApplied)
        XCTAssertEqual(model.dueLine(), .several(count: 2), "today counts")

        XCTAssertTrue(model.complete(rent).isApplied)
        XCTAssertEqual(model.dueLine(), .one(id: bill, title: "Pay the electricity bill", due: day(-3)), "a finished task is not due")

        model.setListStyle(.attic)
        XCTAssertEqual(model.dueLine(), .none, "only the New style has a Due line")
    }

    func testTheDueLineIsComputedAgainAtMidnightWithoutAnyEdit() throws {
        clock.value = calendar.startOfDay(for: clock.value).addingTimeInterval(86_400 - 60) // 23:59
        let bill = try add("Pay the electricity bill", on: .backlog)
        XCTAssertTrue(library.updateTask(bill, dueDay: .some(day(1))).isApplied)
        XCTAssertEqual(model.dueLine(), .none)
        let revision = store.revision
        clock.value.addTimeInterval(120) // 00:01
        XCTAssertEqual(store.revision, revision, "no data changed")
        XCTAssertEqual(model.dueLine(), .one(id: bill, title: "Pay the electricity bill", due: today))
        XCTAssertEqual(TasksMainPageState.nextMidnight(after: clock.value, calendar: calendar),
                       calendar.startOfDay(for: clock.value).addingTimeInterval(86_400))
    }

    // MARK: Pick mode

    func testPickModeTogglesAndDoneReturnsToNowWithThePicksAtTheEnd() throws {
        let fin = try add("Finalize launch checklist")
        let email = try add("Email beta testers")
        let plan = try add("Plan the team offsite", on: .backlog)
        let bill = try add("Pay the electricity bill", on: .backlog)
        XCTAssertTrue(library.updateTask(bill, dueDay: .some(day(-3))).isApplied)
        model.select(tab: .now)
        let nowBefore = titles(.now)

        model.beginPick()
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertNotNil(model.mainPage.pick)
        let groups = model.pickGroups()
        XCTAssertEqual(groups.due, [bill], "due tasks first, under DUE")
        XCTAssertEqual(groups.later, [plan])

        model.togglePick(plan)
        model.togglePick(bill)
        model.togglePick(plan)
        XCTAssertEqual(model.mainPage.pick?.picked, [bill], "a second click unpicks")
        model.togglePick(plan)
        XCTAssertEqual(model.mainPage.pick?.count, 2)

        XCTAssertTrue(model.finishPick().isApplied)
        XCTAssertNil(model.mainPage.pick)
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(titles(.now), nowBefore + ["Pay the electricity bill", "Plan the team offsite"],
                       "picks join the end of Now in the order picked; Now keeps its own order")
        XCTAssertEqual(model.mainPage.justPicked, [bill, plan], "tinted until the next action")
        XCTAssertEqual(model.dueLine(), .none, "nothing outside Now is due any more")
        _ = (fin, email)

        model.openCard(bill)
        XCTAssertTrue(model.mainPage.justPicked.isEmpty, "the next action clears the tint")
        XCTAssertEqual(model.newStyleMoveTitle(in: .now), "Back to Later")

        // One step: ⌘Z puts both back in Later.
        model.closeCard()
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: bill)?.status, .backlog)
        XCTAssertEqual(store.task(withID: plan)?.status, .backlog)
    }

    func testEscInPickModeLeavesAndKeepsThePicks() throws {
        _ = try add("Email beta testers")
        let plan = try add("Plan the team offsite", on: .backlog)
        model.beginPick()
        model.togglePick(plan)
        // Esc and Done are the same: leave and keep.
        model.finishPick()
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(store.task(withID: plan)?.status, .todo)
        XCTAssertEqual(titles(.now).last, "Plan the team offsite")
    }

    func testPickingNothingChangesNothing() throws {
        let plan = try add("Plan the team offsite", on: .backlog)
        let revision = store.revision
        model.beginPick()
        model.finishPick()
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(store.task(withID: plan)?.status, .backlog)
        XCTAssertEqual(store.revision, revision)
    }

    func testNowKeepsItsOwnOrderAfterPickingAndShowsNoCompletedToday() throws {
        let x = try add("X")
        let y = try add("Y")
        let z = try add("Z")
        // The person's own order (newest first, then Z moved to the end).
        XCTAssertTrue(library.moveTask(z, toIndex: 2).isApplied)
        XCTAssertEqual(titles(.now), ["Y", "X", "Z"])
        let own = titles(.now)
        let later = try add("Later one", on: .backlog)
        model.beginPick()
        model.togglePick(later)
        model.finishPick()
        XCTAssertEqual(titles(.now), own + ["Later one"])
        _ = (y, z)

        model.select(tab: .done)
        XCTAssertTrue(model.complete(x).isApplied)
        XCTAssertTrue(model.sections(for: .now).done.isEmpty, "no Completed today in Now (New style)")
        model.setListStyle(.attic)
        XCTAssertFalse(model.sections(for: .now).done.isEmpty, "the Attic style keeps Completed today")
    }

    // MARK: Find across every list

    func testFindGroupsEveryListSwitchesScopeAndEscRestores() throws {
        let fin = try add("Finalize launch checklist")
        let email = try add("Email beta testers")
        XCTAssertTrue(library.updateTask(email, tags: ["launch"]).isApplied)
        let plan = try add("Plan the team offsite", on: .backlog)
        XCTAssertTrue(library.updateTask(plan, url: .some("https://example.com/launch-venues")).isApplied)
        let other = try add("Renew passport", on: .backlog)
        model.select(tab: .now)
        let announce = try add("Write the launch announcement")
        XCTAssertTrue(model.complete(announce).isApplied)

        model.select(tab: .backlog)
        model.selectOnly(other)
        model.beginFind(scrollAnchor: other)
        XCTAssertNotNil(model.mainPage.find)
        XCTAssertEqual(model.mainPage.find?.scope, .allLists, "All lists is the default")
        model.setFindQuery("launch")
        let results = model.findResults()
        XCTAssertEqual(results.groups.map(\.title), ["NOW · 2", "LATER · 1", "DONE · 1"])
        XCTAssertEqual(Set(results.groups[0].ids), [fin, email], "titles and tags")
        XCTAssertEqual(results.groups[1].ids, [plan], "the link's host and path")
        XCTAssertEqual(results.groups[2].ids, [announce])

        model.setFindScope(.thisList)
        XCTAssertEqual(model.findResults().groups.map(\.title), ["LATER · 1"], "This list: where Find began")
        model.setFindScope(.allLists)

        // A result opens its card in place, inside the results.
        model.openCard(email)
        XCTAssertEqual(model.mainPage.card?.taskID, email)
        XCTAssertEqual(model.mainPage.card?.tab, .now)
        XCTAssertNotNil(model.mainPage.find)

        let anchor = model.endFind()
        XCTAssertNil(model.mainPage.find)
        XCTAssertNil(model.mainPage.card)
        XCTAssertEqual(model.tab, .backlog, "the list it left")
        XCTAssertEqual(model.selection, [other], "the selection it left")
        XCTAssertEqual(anchor, other, "the scroll position it left")
        XCTAssertEqual(model.mainPage.scrollRequest?.id, other)
    }

    func testFindIsOnlyTheNewStyles() throws {
        model.setListStyle(.reminders)
        model.beginFind(scrollAnchor: nil)
        XCTAssertNil(model.mainPage.find)
    }

    // MARK: Helpers

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
