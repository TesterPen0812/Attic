import AppKit
import XCTest
@testable import Attic

/// Round 8: Astra's round-7 check (G1–G3).
@MainActor
final class TasksRound8Tests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private var gate: PersistenceGate!
    private var store: TaskStore!
    private var model: TasksPageModel!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        let library = AtticLibrary(tasks: store, now: { [clock] in clock.value }, persist: gate.save)
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { Calendar(identifier: .gregorian) },
            locale: Locale(identifier: "en_GB")
        ))
    }

    override func tearDown() {
        model = nil
        store = nil
        gate = nil
    }

    private let editor = AtticTokenFieldEditor()
    private func day(_ raw: String) -> DueDay { DueDay(rawValue: raw)! }

    /// Types `text` as the field reports it: the edit, then the caret at
    /// its end (the page model's own handlers).
    private func type(_ text: String) {
        for character in text {
            let at = (model.addBar.text as NSString).length
            model.addBarEdited(NSRange(location: at, length: 0), replacement: String(character))
            model.addBar.text += String(character)
            model.addBarCaretMoved((model.addBar.text as NSString).length)
        }
    }

    // MARK: - G1: submitting finishes the pieces at the end

    /// `Call `, pick High, `!`, then Return (or ⌘Return, or the send button:
    /// all `submitAddBar`) with no space: the typed Medium is the task's,
    /// and the `!` is not in its title.
    func testSubmittingAMarkStillAtTheCaretUsesTheMark() throws {
        for opening in [false, true] {
            model.addBarState.clearDraft()
            type("Call ")
            model.pickPriority(.high, editor: editor)
            type("!")
            XCTAssertEqual(model.addBar.parts(parser: model.parser).priority, .high, "still typing: the pick shows")
            let id = try XCTUnwrap(model.submitAddBar(openingPage: opening))
            let task = try XCTUnwrap(store.task(withID: id))
            XCTAssertEqual(task.priority, .medium, "opening \(opening)")
            XCTAssertEqual(task.title, "Call")
        }
    }

    func testSubmittingADateStillAtTheCaretUsesTheDateButWordsStayWords() throws {
        let picked = day("2026-10-09")
        model.addBarState.clearDraft()
        type("Call ")
        model.pickDate(picked, editor: editor)
        type("fri")
        let friday = try XCTUnwrap(model.submitAddBar())
        XCTAssertNotEqual(store.task(withID: friday)?.dueDay, picked, "a finished date at the end replaces the pick")
        XCTAssertEqual(store.task(withID: friday)?.title, "Call")
        for word in ["friend", "money"] {
            model.addBarState.clearDraft()
            type("Call ")
            model.pickDate(picked, editor: editor)
            type(word)
            let id = try XCTUnwrap(model.submitAddBar())
            XCTAssertEqual(store.task(withID: id)?.dueDay, picked, "\(word) is a word: the pick stays")
            XCTAssertEqual(store.task(withID: id)?.title, "Call \(word)")
        }
    }

    /// A failed save keeps the draft exactly as it was (text, pick,
    /// history); the retry finishes it the same way.
    func testAFailedSaveKeepsTheDraftAsItWas() throws {
        type("Call ")
        model.pickPriority(.high, editor: editor)
        type("!")
        let before = model.addBar
        gate.shouldFail = true
        XCTAssertNil(model.submitAddBar())
        XCTAssertEqual(model.addBar, before, "nothing of the draft changed")
        gate.shouldFail = false
        let id = try XCTUnwrap(model.submitAddBar())
        XCTAssertEqual(store.task(withID: id)?.priority, .medium)
    }

    // MARK: - G2: an input method keeps its Esc

    func testAComposingEditorIsComposing() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        XCTAssertFalse(TasksPage.isComposing(view))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(TasksPage.isComposing(view))
        view.unmarkText()
        XCTAssertFalse(TasksPage.isComposing(view))
        XCTAssertFalse(TasksPage.isComposing(nil))
    }

    // MARK: - G3: a queued correction yields to anything newer

    /// The pager comes to rest off its page and queues a correction; before
    /// it runs, a tab (even the one shown), `show`, Search, a reveal or a
    /// new gesture happens. The correction does not run; with nothing in
    /// between, it does.
    func testAQueuedCorrectionYieldsToNewerNavigationOrAGesture() throws {
        let task = try XCTUnwrap(store.create(title: "Call the plumber"))
        let swipe = model.pagerSwipe
        let newer: [(String, () -> Void)] = [
            ("the tab shown", { self.model.select(tab: self.model.tab) }),
            ("another tab", { self.model.select(tab: .done) }),
            ("show", { _ = self.model.show(task.id) }),
            ("Search", { self.model.beginSearch() }),
            ("a reveal", { self.model.resetForReveal() }),
            ("a new gesture", { _ = swipe.phaseChanged(to: .interacting, shown: 0) }),
            ("a programmatic scroll", { _ = swipe.phaseChanged(to: .animating, shown: 0) })
        ]
        for (name, happen) in newer {
            model.select(tab: .now)
            _ = swipe.phaseChanged(to: .idle, shown: 0)
            let ticket = swipe.correctionTicket()
            XCTAssertTrue(swipe.mayCorrect(ticket, to: 0, shown: 0), "\(name): nothing yet, it may run")
            happen()
            let shown = TasksTab.allCases.firstIndex(of: model.tab) ?? 0
            XCTAssertFalse(swipe.mayCorrect(ticket, to: 0, shown: shown), "\(name) came after: the queued correction is stale")
            _ = swipe.phaseChanged(to: .idle, shown: shown)
        }
        // The model's page changed without a navigation (a failed settle):
        // the destination no longer matches.
        let ticket = swipe.correctionTicket()
        XCTAssertFalse(swipe.mayCorrect(ticket, to: 1, shown: 0))
    }
}
