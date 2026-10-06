import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 round 3, stream T: one date model, the add bar's pieces
/// (picked, shown, dismissed), suggestions, title edits as a patch, Date
/// and Tags on one or many tasks, the reorder maths, the list viewport and
/// the quiet open ring.
@MainActor
final class TasksRound3Tests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private var parser: TaskTextParser { model.parser }

    @discardableResult
    private func add(_ text: String) throws -> UUID {
        model.addBar = TaskAddBarText(text: text)
        return try XCTUnwrap(model.submitAddBar())
    }

    private func day(_ raw: String) -> DueDay { DueDay(rawValue: raw)! }

    // MARK: - One date model (review 16)

    func testQuickDaysResolveThroughTheParserAndShowTheirDay() {
        let choices = model.dateChoices
        XCTAssertEqual(choices.today, day("2026-09-21"))
        XCTAssertEqual(choices.quick.map(\.kind), [.today, .tomorrow, .nextWeek])
        XCTAssertEqual(choices.quick.map(\.day), [day("2026-09-21"), day("2026-09-22"), day("2026-09-28")],
                       "next week is next Monday, as the shorthand reads it")
        XCTAssertEqual(choices.detail(for: day("2026-09-21")), "Mon")
        XCTAssertEqual(choices.detail(for: day("2026-09-22")), "Tue")
        XCTAssertTrue(choices.detail(for: day("2026-09-28")).hasPrefix("Mon 28 Sep"), "further on, the date too")
        XCTAssertEqual(choices.shorthand(for: day("2026-09-22")), "tomorrow")
        XCTAssertEqual(choices.shorthand(for: day("2026-10-30")), "30 Oct")
        XCTAssertEqual(choices.shorthand(for: day("2027-01-02")), "2 Jan 2027", "another year says so")
    }

    func testTheMonthStartsOnTheLocalesFirstWeekday() throws {
        let card = model.dateChoices.cardCalendar
        let september = AtticDateMonth(containing: try XCTUnwrap(day("2026-09-21").startDate(in: card)), calendar: card)
        XCTAssertEqual(september.weekdays, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(september.cells.first ?? nil, nil, "1 Sep is a Tuesday: Monday's cell is blank, no August day")
        XCTAssertEqual(september.cells[1].map { DueDay(date: $0, calendar: card) }, day("2026-09-01"))
        XCTAssertEqual(september.cells.count % 7, 0)
        XCTAssertEqual(september.cells.compactMap { $0 }.count, 30)
        XCTAssertEqual(AtticDateCardFormat.monthTitle(september.start, calendar: card), "September 2026")

        var sunday = calendar
        sunday.firstWeekday = 1
        let choices = TaskDateChoices(parser: TaskTextParser(calendar: sunday, locale: Locale(identifier: "en_US"), now: { [clock] in clock.value }))
        let us = AtticDateMonth(containing: try XCTUnwrap(day("2026-09-21").startDate(in: choices.cardCalendar)), calendar: choices.cardCalendar)
        XCTAssertEqual(us.weekdays.first, "S")
        XCTAssertEqual(us.cells.prefix(2), [nil, nil], "Sunday and Monday lead blank")
    }

    func testMonthsAndKeyboardTravelCrossTheYear() throws {
        let card = model.dateChoices.cardCalendar
        func date(_ raw: String) throws -> Date { try XCTUnwrap(day(raw).startDate(in: card)) }
        var state = AtticDateCardState(start: try date("2026-12-31"))
        _ = state.apply(.month(1), calendar: card, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.month(card).start, try date("2027-01-01"))
        _ = state.apply(.month(-1), calendar: card, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.month(card).start, try date("2026-12-01"))
        _ = state.apply(.right, calendar: card, suggestions: 0, typing: false, hasRemove: false) // lights
        _ = state.apply(.right, calendar: card, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(state.cursor, try date("2027-01-01"))
        var march = AtticDateCardState(start: try date("2026-03-01"))
        _ = march.apply(.up, calendar: card, suggestions: 0, typing: false, hasRemove: false)
        _ = march.apply(.up, calendar: card, suggestions: 0, typing: false, hasRemove: false)
        XCTAssertEqual(march.cursor, try date("2026-02-22"))
    }

    // MARK: - The add bar's pieces

    func testAPickedDayIsKeptExactlyWhateverItsWordsWouldParseTo() throws {
        // "1 Sep" typed today would mean next year (a passed date); picked,
        // it is the day that was picked.
        var bar = TaskAddBarText(text: "Pay rent 1 Sep")
        bar.pin(NSRange(location: 9, length: 5), value: .dueDay(day("2026-09-01")))
        XCTAssertEqual(bar.parts(parser: parser).dueDay, day("2026-09-01"))
        XCTAssertEqual(bar.parts(parser: parser).title, "Pay rent")
        XCTAssertEqual(bar.chips(parser: parser, caret: 14), [NSRange(location: 9, length: 5)], "a picked piece is a chip at once")
        // A pinned date wins over a typed one; typing into it forgets it.
        bar.text = "Pay rent 1 Sep tomorrow"
        XCTAssertEqual(bar.parts(parser: parser).dueDay, day("2026-09-01"))
        bar.edited(NSRange(location: 10, length: 0), replacement: "1")
        XCTAssertTrue(bar.pinned.isEmpty)
    }

    func testAPickReplacesThePieceOfItsKindOrGoesInAtTheCaretWithSpaces() {
        var bar = TaskAddBarText(text: "Pay rent tomorrow #home")
        let existing = bar.range(of: .date, parser: parser)
        XCTAssertEqual(existing, NSRange(location: 9, length: 8))
        let replace = bar.insertion(of: "30 Sep", replacing: existing, caret: 23)
        XCTAssertEqual(replace.range, NSRange(location: 9, length: 8))
        XCTAssertEqual(replace.string, "30 Sep")
        XCTAssertEqual(replace.piece, NSRange(location: 9, length: 6))

        bar = TaskAddBarText(text: "Pay rent")
        let append = bar.insertion(of: "!", replacing: nil, caret: 8)
        XCTAssertEqual(append.range, NSRange(location: 8, length: 0))
        XCTAssertEqual(append.string, " ! ")
        XCTAssertEqual(append.piece, NSRange(location: 9, length: 1))
        let midWord = bar.insertion(of: "!", replacing: nil, caret: 2)
        XCTAssertEqual(midWord.range.location, 3, "never inside a word: after it")
    }

    /// Review 3's regression, on the editor's path: type "Call fri ", take the
    /// space back (the caret returns to the end of "fri"), then Backspace.
    /// The chip the person sees is the one Backspace finds.
    func testBackspaceAtTheEndOfAFinishedChipFindsIt() {
        var bar = TaskAddBarText(text: "Call fri")
        let fri = NSRange(location: 5, length: 3)
        XCTAssertEqual(bar.chips(parser: parser, caret: 8), [], "still typing fri: no chip")
        bar.text = "Call fri "
        bar.edited(NSRange(location: 8, length: 0), replacement: " ")
        bar.markShown(parser: parser, caret: 9)
        XCTAssertEqual(bar.chips(parser: parser, caret: 9), [fri])
        bar.edited(NSRange(location: 8, length: 1), replacement: "")
        bar.text = "Call fri"
        bar.markShown(parser: parser, caret: 8)
        XCTAssertEqual(bar.chips(parser: parser, caret: 8), [fri], "the finished chip stays a chip at the caret")
        bar.dismiss(fri)
        XCTAssertEqual(bar.chips(parser: parser, caret: 8), [])
        XCTAssertNil(bar.parts(parser: parser).dueDay, "fri is plain text now")
        XCTAssertEqual(bar.text, "Call fri", "and nothing was deleted")
        // Typing on from a finished chip joins the word, which is read afresh.
        bar = TaskAddBarText(text: "Call fri ")
        bar.markShown(parser: parser, caret: 9)
        bar.edited(NSRange(location: 8, length: 0), replacement: "d")
        XCTAssertTrue(bar.shown.isEmpty)
    }

    // MARK: - Suggestions (review 15)

    func testTagSuggestionsListMatchesFirstAndOfferToCreate() throws {
        let bar = TaskAddBarText(text: "Pay rent #h")
        let tags = ["home", "health", "hiring", "work", "launch"]
        guard case let .tags(range, query, matches, create)? = bar.suggestion(parser: parser, caret: 11, tags: tags) else {
            return XCTFail("expected tag suggestions")
        }
        XCTAssertEqual(range, NSRange(location: 9, length: 2))
        XCTAssertEqual(query, "h")
        XCTAssertEqual(matches, ["home", "health", "hiring", "launch"], "prefix matches first, then the rest")
        XCTAssertEqual(create, "h")
        guard case let .tags(_, _, exact, noCreate)? = TaskAddBarText(text: "#home").suggestion(parser: parser, caret: 5, tags: tags) else {
            return XCTFail("expected tag suggestions")
        }
        XCTAssertEqual(exact, ["home"])
        XCTAssertNil(noCreate, "an existing tag is not offered again")
        XCTAssertNil(TaskAddBarText(text: "#home").suggestion(parser: parser, caret: 2, tags: tags), "only at a word's end")
    }

    func testDateSuggestionsShowTheDayAWordMeans() {
        let tom = TaskAddBarText(text: "Pay rent tom").suggestion(parser: parser, caret: 12, tags: [])
        XCTAssertEqual(tom, .date(range: NSRange(location: 9, length: 3), words: "tomorrow", title: "Tomorrow", day: day("2026-09-22")))
        let nextW = TaskAddBarText(text: "Pay next w").suggestion(parser: parser, caret: 10, tags: [])
        XCTAssertEqual(nextW, .date(range: NSRange(location: 4, length: 6), words: "next week", title: "Next week", day: day("2026-09-28")))
        XCTAssertNil(TaskAddBarText(text: "Get sun").suggestion(parser: parser, caret: 7, tags: []), "everyday words stay words")
        XCTAssertNil(TaskAddBarText(text: "Call to").suggestion(parser: parser, caret: 7, tags: []), "two letters are not enough")
        if case let .date(_, _, _, finished)? = TaskAddBarText(text: "Pay rent 30/9").suggestion(parser: parser, caret: 13, tags: []) {
            XCTAssertEqual(finished, day("2026-09-30"), "a finished date shows its day too")
        } else {
            XCTFail("expected a date suggestion")
        }
    }

    // MARK: - Edit Title understands the shorthand (owner fix 4, review 17)

    func testATitleEditIsAPatchThatKeepsWhatWasNotTyped() throws {
        let id = try add("Call mom #family tomorrow !")
        let before = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(before.dueDay, day("2026-09-22"))
        model.beginEditingTitle(id)
        XCTAssertEqual(model.editingTitle, "Call mom")
        model.titleEdit.text = "Call mom today #home !!"
        XCTAssertTrue(model.commitTitle())
        let after = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(after.title, "Call mom")
        XCTAssertEqual(Set(after.tags), ["family", "home"], "new tags are added to the old ones")
        XCTAssertEqual(after.dueDay, day("2026-09-21"), "a typed date replaces the date")
        XCTAssertEqual(after.priority, .high)
        _ = library.undo.undo(in: .tasks)
        let undone = try XCTUnwrap(store.task(withID: id))
        XCTAssertEqual(undone.dueDay, day("2026-09-22"), "one step: title and metadata together")
        XCTAssertEqual(undone.tags, ["family"])
        XCTAssertEqual(undone.priority, .medium)
    }

    func testARenameNeverRereadsTheWordsTheTitleAlreadyHad() throws {
        // "today" was kept as text when the task was made.
        var bar = TaskAddBarText(text: "Watch the today show")
        bar.dismiss(NSRange(location: 10, length: 5))
        model.addBar = bar
        let id = try XCTUnwrap(model.submitAddBar())
        XCTAssertNil(store.task(withID: id)?.dueDay)
        model.beginEditingTitle(id)
        model.titleEdit.edited(NSRange(location: 20, length: 0), replacement: " again")
        model.titleEdit.text = "Watch the today show again"
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(store.task(withID: id)?.title, "Watch the today show again")
        XCTAssertNil(store.task(withID: id)?.dueDay, "the old word stays a word")
    }

    func testOnlyShorthandKeepsTheTitle() throws {
        let id = try add("Plan trip")
        model.beginEditingTitle(id)
        model.titleEdit.text = "Plan trip #travel"
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(store.task(withID: id)?.title, "Plan trip")
        XCTAssertEqual(store.task(withID: id)?.tags, ["travel"])
        model.beginEditingTitle(id)
        XCTAssertFalse(model.hasUnsavedEdit, "an untouched editor has nothing to save")
    }

    // MARK: - Date and Tags on one or many tasks (owner fixes 3 and 5)

    func testDateOnSeveralTasksIsOneStepWithAToast() throws {
        let a = try add("A")
        let b = try add("B tomorrow")
        model.setDueDay(day("2026-09-30"), for: [a, b])
        XCTAssertEqual(store.task(withID: a)?.dueDay, day("2026-09-30"))
        XCTAssertEqual(store.task(withID: b)?.dueDay, day("2026-09-30"))
        XCTAssertEqual(model.commonDueDay([a, b]), day("2026-09-30"))
        XCTAssertTrue(model.toasts.current?.message.hasPrefix("2 tasks due 30 Sep") == true, model.toasts.current?.message ?? "")
        _ = library.undo.undo(in: .tasks)
        XCTAssertNil(store.task(withID: a)?.dueDay)
        XCTAssertEqual(store.task(withID: b)?.dueDay, day("2026-09-22"), "one undo takes both back")
        model.setDueDay(nil, for: [b])
        XCTAssertNil(store.task(withID: b)?.dueDay)
        XCTAssertEqual(model.toasts.current?.message, "Date removed")
    }

    func testBulkTagsTickMixAndToggleForAll() throws {
        let a = try add("A #home")
        let b = try add("B")
        XCTAssertEqual(model.tagState("home", for: [a, b]), .mixed)
        XCTAssertEqual(model.tagState("home", for: [a]), .on)
        XCTAssertEqual(model.tagState("home", for: [b]), .off)
        XCTAssertEqual(model.tagChoices(for: [a, b]).first, "home", "the targets' own tags first")
        model.toggleTag("home", for: [a, b])
        XCTAssertEqual(store.task(withID: b)?.tags, ["home"], "mixed adds it to all")
        XCTAssertEqual(model.tagState("home", for: [a, b]), .on)
        model.toggleTag("home", for: [a, b])
        XCTAssertEqual(store.task(withID: a)?.tags, [], "ticked removes it from all")
        XCTAssertEqual(store.task(withID: b)?.tags, [])
        XCTAssertEqual(model.toasts.current?.message, "Removed #home")
        _ = library.undo.undo(in: .tasks)
        XCTAssertEqual(store.task(withID: a)?.tags, ["home"])
        XCTAssertEqual(store.task(withID: b)?.tags, ["home"], "one step for both")
    }

    // MARK: - A failed change shows where it was made (review 6)

    func testARowFailureShowsUnderItsRowAndRetryReplacesIt() throws {
        let id = try add("A")
        var attempts = 0
        let failing = CommandOutcome.failed(CommandFailure("Couldn’t save.", canRetry: true))
        model.report(failing, on: id) { attempts += 1; return .applied }
        XCTAssertEqual(model.rowFailure?.id, id)
        XCTAssertEqual(model.rowFailure?.canRetry, true)
        model.retryRowFailure()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(model.rowFailure, "an applied retry clears it")
        model.report(.failed(.taskGone), on: id) { .applied }
        XCTAssertEqual(model.rowFailure?.canRetry, false, "a gone task offers no Retry")
        XCTAssertEqual(model.rowFailure?.message, CommandFailure.taskGone.message)
        model.report(.applied, on: id) { .applied }
        XCTAssertNil(model.rowFailure, "a later success on the row clears it")
    }

    // MARK: - Drag to reorder (owner fix 6, review 10)

    func testReorderTargetsAndNeighboursFollowTheRowsHeights() {
        let ids = (0..<4).map { _ in UUID() }
        let heights: [UUID: CGFloat] = [ids[0]: 34, ids[1]: 48, ids[2]: 34, ids[3]: 34]
        let height = { (id: UUID) in heights[id] ?? 34 }
        typealias Cell = TasksReorderCell<EmptyView, EmptyView>
        XCTAssertEqual(Cell.target(start: 0, translation: 20, group: ids, heights: height), 0, "less than half of a 48 pt row")
        XCTAssertEqual(Cell.target(start: 0, translation: 25, group: ids, heights: height), 1)
        XCTAssertEqual(Cell.target(start: 0, translation: 500, group: ids, heights: height), 3, "clamped to the group")
        XCTAssertEqual(Cell.target(start: 3, translation: -60, group: ids, heights: height), 1)
        XCTAssertFalse(Cell.pushesPastGroup(start: 0, translation: 100, group: ids, heights: height))
        XCTAssertTrue(Cell.pushesPastGroup(start: 0, translation: 135, group: ids, heights: height),
                      "past the last row by more than half a row: the hint shows")
        XCTAssertTrue(Cell.pushesPastGroup(start: 0, translation: -20, group: ids, heights: height))

        let drag = TasksDrag(id: ids[0], tab: .now, group: ids, startIndex: 0, targetIndex: 2)
        XCTAssertEqual(Cell.offset(of: ids[1], in: drag, heights: height), -34)
        XCTAssertEqual(Cell.offset(of: ids[2], in: drag, heights: height), -34)
        XCTAssertEqual(Cell.offset(of: ids[3], in: drag, heights: height), 0)
        XCTAssertEqual(Cell.offset(of: ids[0], in: drag, heights: height), 0, "the dragged row follows the pointer instead")
        let up = TasksDrag(id: ids[3], tab: .now, group: ids, startIndex: 3, targetIndex: 1)
        XCTAssertEqual(Cell.offset(of: ids[1], in: up, heights: height), 34)
        XCTAssertEqual(Cell.offset(of: ids[0], in: up, heights: height), 0)
    }

    // MARK: - The list viewport (owner fix 8, review 9)

    func testTheViewportKeepsTheRestingRowAndClearsTheMeasuredBottomStack() {
        XCTAssertEqual(TasksViewport.listTop(tabsTop: 80), 110, "the tabs (16) and 14 under them")
        XCTAssertEqual(TasksViewport.bottomClearance(stackHeight: 36, bottomInset: 24), 76)
        XCTAssertEqual(TasksViewport.bottomClearance(stackHeight: 36 + 8 + 28, bottomInset: 24), 112, "the strip adds its room")
        XCTAssertEqual(TasksViewport.bottomClearance(stackHeight: 0, bottomInset: 12), 64, "never less than the bar")
        let stops = TasksViewport.maskStops(height: 520, tabsTop: 80)
        // Owner, 2026-10-06: whole under the header's and the add bar's glass.
        XCTAssertEqual(stops.first?.opacity ?? 0, 1, accuracy: 0.001, "whole at the panel's top")
        XCTAssertEqual(stops.first { $0.location >= 110.0 / 520 - 0.0001 }?.opacity, 1, "fully there from the first row's rest")
        XCTAssertEqual(stops.last?.opacity ?? 0, 1, accuracy: 0.001, "whole under the add bar")
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "stops in order")
        let underTabs = stops.filter { $0.location >= 80.0 / 520 - 0.0001 && $0.location <= 96.0 / 520 + 0.0001 }
        XCTAssertTrue(underTabs.allSatisfy { $0.opacity > 0 && $0.opacity <= AtticScrollUnderFade.behindText + 0.001 },
                      "scrolled text shows faintly behind the tabs")
    }

    // MARK: - The quiet open ring (owner fix 1, review 12)

    func testOpenRingIsQuietInLightSolidAndFirmUnderIncreaseContrast() {
        let light = AtticDesignContext(mode: .light).tokens
        let ring = light.openRing()
        XCTAssertEqual(ring.alpha, 0.22, accuracy: 0.001)
        let onWhite = ring.over(AtticRGBA(0xFFFFFF))
        XCTAssertEqual(onWhite.contrast(on: AtticRGBA(0xFFFFFF)), 1.6, accuracy: 0.15, "the owner's reference, about #CDCDCE")
        XCTAssertGreaterThan(light.openRing(emphasised: true).alpha, ring.alpha, "hover and focus step up")
        let dark = AtticDesignContext(mode: .dark).tokens.openRing()
        XCTAssertGreaterThan(dark.alpha, ring.alpha, "Dark keeps a clearly visible ring")
        var contrast = AtticDesignContext(mode: .light)
        contrast.increaseContrast = true
        let firm = contrast.tokens.openRing()
        XCTAssertEqual(firm, contrast.tokens.ink(.heading))
        XCTAssertGreaterThanOrEqual(firm.contrast(on: AtticRGBA(0xFFFFFF)), 3)
    }
}

/// The ⌘Z crash (computer-use review, 2026-09-27): a text field's typing
/// undo must never outlive the field in the window's undo manager.
@MainActor
final class TokenFieldUndoLifetimeTests: XCTestCase {
    func testTypingUndoStaysInTheFieldAndDiesWithIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var field: AtticTokenFieldView? = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        window.contentView?.addSubview(field!)
        XCTAssertTrue(window.makeFirstResponder(field!.textView))
        field!.textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(field!.textView.string, "typed")
        // Round 4: the field registers no undo anywhere; its owner's draft
        // history holds typing (see `TasksRound4Tests`).
        XCTAssertFalse(field!.textView.allowsUndo)
        XCTAssertNil(field!.textView.undoManager, "no undo manager to register with")
        XCTAssertFalse(window.undoManager?.canUndo == true, "nothing of the field's is in the window's undo manager")
        window.makeFirstResponder(nil)
        field!.removeFromSuperview()
        field = nil
        // ⌘Z through the window after the field is gone finds nothing of
        // the field's to invoke (the crash invoked a dead field's action).
        XCTAssertFalse(window.undoManager?.canUndo == true)
        if window.undoManager?.canUndo == true { window.undoManager?.undo() }
        window.close()
    }
}
