import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1 fix round 4 (Astra's final review): bulk Restore, the draft's
/// undo history with its pieces, menu invocations, picker keyboard, show,
/// drag cancellation and geometry, and the ⌘Z menu path.
@MainActor
final class TasksRound4Tests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private var gate: PersistenceGate!
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestStore(now: { [clock] in clock.value }, persist: gate.save)
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value }, persist: gate.save)
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
        gate = nil
    }

    private func rows(_ id: UUID) throws -> [TaskItem] {
        try ModelContext(store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
    }

    // MARK: - Must fix 1: bulk Restore to Now

    func testRestoringSeveralTasksIsOneSaveOneStepAndAllOrNothing() throws {
        let logged = try XCTUnwrap(store.create(title: "Invoice"))
        let child = try XCTUnwrap(store.create(title: "Send", parentID: logged.id))
        let today = try XCTUnwrap(store.create(title: "Water plants"))
        XCTAssertTrue(library.completeTask(logged.id).isApplied)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        _ = store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value))
        XCTAssertTrue(library.completeTask(today.id).isApplied)
        XCTAssertNil(store.task(withID: logged.id), "one in the Done log")
        XCTAssertEqual(store.task(withID: today.id)?.status, .done, "one in today's done group")

        // A failed save changes nothing: neither comes back.
        gate.shouldFail = true
        let failed = library.restoreToNow([logged.id, today.id])
        XCTAssertNotNil(failed.failure)
        XCTAssertNil(store.task(withID: logged.id))
        XCTAssertEqual(store.task(withID: today.id)?.status, .done)
        gate.shouldFail = false

        let saves = gate.saveCount
        model.select(tab: .done)
        XCTAssertTrue(model.restoreToNow([logged.id, today.id]).isApplied)
        XCTAssertEqual(gate.saveCount, saves + 1, "one save for both and the family")
        XCTAssertEqual(store.task(withID: logged.id)?.status, .todo)
        XCTAssertNotNil(store.task(withID: child.id), "the family came back")
        XCTAssertEqual(store.task(withID: today.id)?.status, .todo)
        XCTAssertEqual(model.toasts.current?.message, "Restored 2 tasks to Now")
        XCTAssertEqual(library.undo.undoName(in: .tasks), "Restore 2 Tasks")

        // One undo puts both back where they were; one redo restores both.
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertNil(store.task(withID: logged.id), "back in the Done log")
        XCTAssertTrue(try rows(child.id).allSatisfy { $0.doneLoggedAt != nil }, "with its family")
        XCTAssertEqual(store.task(withID: today.id)?.status, .done, "back in today's done group")
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        XCTAssertEqual(store.task(withID: logged.id)?.status, .todo)
        XCTAssertEqual(store.task(withID: today.id)?.status, .todo)
    }

    // MARK: - Must fix 2: the draft keeps its undo, pieces included

    private func day(_ raw: String) -> DueDay { DueDay(rawValue: raw)! }

    /// A live add bar: the real text view, its coordinator and the page's
    /// own add-bar state and actions (the same closures `TasksAddBar` uses).
    private struct LiveBar {
        let window: NSWindow
        let view: AtticTokenFieldView
        let editor: AtticTokenFieldEditor
        let coordinator: AtticTokenField.Coordinator
    }

    private func liveBar(escape: @escaping () -> Bool = { false },
                         in host: NSWindow? = nil) -> LiveBar {
        let state = model.addBarState
        let actions = AtticTokenFieldActions(
            submit: { _ in },
            dismissChip: { range in
                self.chipDismissals += 1
                state.history.checkpoint(state.text, selection: state.currentSelection)
                state.text.dismiss(range)
            },
            multilinePaste: { _ in false },
            escape: escape,
            edited: { range, replacement in
                state.history.willEdit(state.text, selection: state.currentSelection, range: range, replacement: replacement)
                state.text.edited(range, replacement: replacement)
            },
            caretMoved: { caret in
                state.caret = caret
                var shown = state.text
                if shown.markShown(parser: self.model.parser, caret: caret) { state.text = shown }
            },
            undoDraft: { state.undoDraft() },
            redoDraft: { state.redoDraft() },
            selectionMoved: { state.selection = $0 }
        )
        let field = AtticTokenField(
            text: Binding(get: { state.text.text }, set: { state.text.text = $0 }),
            chips: [], isFocused: .constant(true), accessibilityLabel: "Add a task", actions: actions
        )
        let coordinator = field.makeCoordinator()
        liveField = field
        let view = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
        view.textView.delegate = coordinator
        view.textView.owner = coordinator
        coordinator.view = view
        let window = host ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view.textView)
        let editor = AtticTokenFieldEditor()
        editor.textView = view.textView
        return LiveBar(window: window, view: view, editor: editor, coordinator: coordinator)
    }

    private var liveField: AtticTokenField?
    private var chipDismissals = 0

    /// What `updateNSView` does after each change: the chips drawn now.
    private func refreshChips(_ bar: LiveBar) {
        guard var field = liveField else { return }
        field.chips = model.addBar.chips(parser: model.parser, caret: model.addBarCaret)
        bar.coordinator.parent = field
    }

    private func type(_ text: String, into bar: LiveBar) {
        for character in text {
            bar.view.textView.insertText(String(character), replacementRange: bar.view.textView.selectedRange())
        }
    }

    func testAPickedPastDaySurvivesUndoAndRedoWithItsValue() {
        let bar = liveBar()
        type("Pay rent", into: bar)
        // 1 Sep has passed: typed, it would mean next year; picked, it is 2026.
        model.pickDate(day("2026-09-01"), editor: bar.editor)
        XCTAssertTrue(model.addBar.text.hasPrefix("Pay rent 1 Sep"), model.addBar.text)
        XCTAssertEqual(model.addBar.parts(parser: model.parser).dueDay, day("2026-09-01"))
        // One ⌘Z undoes the pick (text and value); the typing is still there.
        bar.view.textView.undo(nil)
        XCTAssertEqual(model.addBar.text, "Pay rent")
        XCTAssertTrue(model.addBar.pinned.isEmpty)
        // Redo brings the exact day back, not "1 Sep" read afresh (2027).
        bar.view.textView.redo(nil)
        XCTAssertEqual(model.addBar.parts(parser: model.parser).dueDay, day("2026-09-01"))
        XCTAssertEqual(bar.view.textView.string, model.addBar.text, "the field shows the model's text")
        // Typing is one step per word run.
        bar.view.textView.undo(nil)
        bar.view.textView.undo(nil)
        XCTAssertEqual(model.addBar.text, "Pay ", "the second word is one step (the space another)")
        bar.window.close()
    }

    func testBlurKeepsTheDraftsUndoAndChipDismissalUndoes() throws {
        let done = try XCTUnwrap(store.create(title: "Ring the bank"))
        XCTAssertTrue(library.completeTask(done.id).isApplied)
        let bar = liveBar()
        type("Call fri ", into: bar)
        XCTAssertNotNil(model.addBar.parts(parser: model.parser).dueDay)
        // The keyboard leaves (a picker opens) and comes back.
        bar.window.makeFirstResponder(nil)
        bar.window.makeFirstResponder(bar.view.textView)
        // Backspace after the space, then on the chip: the chip becomes text.
        bar.view.textView.deleteBackward(nil)
        refreshChips(bar)
        bar.view.textView.deleteBackward(nil)
        XCTAssertEqual(model.addBar.text, "Call fri", "nothing was deleted by the chip Backspace")
        XCTAssertNil(model.addBar.parts(parser: model.parser).dueDay, "fri is plain text now")
        // ⌘Z makes it a chip again, then restores the space, then the typing.
        bar.view.textView.undo(nil)
        XCTAssertNotNil(model.addBar.parts(parser: model.parser).dueDay, "the dismissal undoes")
        bar.view.textView.undo(nil)
        XCTAssertEqual(model.addBar.text, "Call fri ")
        var steps = 0
        while !model.addBar.text.isEmpty, steps < 8 { bar.view.textView.undo(nil); steps += 1 }
        XCTAssertEqual(model.addBar.text, "")
        XCTAssertEqual(steps, 4, "fri, the space, Call's space, Call")
        // With nothing left in the draft, ⌘Z stays with the field that is
        // typing: it never reaches the Tasks history (round 5).
        bar.view.textView.undo(nil)
        XCTAssertEqual(store.task(withID: done.id)?.status, .done, "the Tasks history was not touched")
        bar.window.close()
    }

    func testAnInputMethodsMarkedTextKeepsEscBackspaceAndUndo() {
        var escapes = 0
        let bar = liveBar(escape: { escapes += 1; return true })
        let textView = bar.view.textView
        // "fri" is a chip right before the caret: Backspace would dismiss it.
        type("Call fri ", into: bar)
        textView.deleteBackward(nil)
        refreshChips(bar)
        XCTAssertNotNil(bar.coordinator.chipBeforeCaret(textView), "the harness has a chip to protect")
        let text = model.addBar.text
        // An input method starts composing right there.
        textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.hasMarkedText())
        // Esc, ⌘Z and the Edit menu's Undo belong to the composition.
        textView.cancelOperation(nil)
        textView.undo(nil)
        textView.redo(nil)
        XCTAssertEqual(escapes, 0, "Esc cancels the composition, not the field")
        XCTAssertTrue(textView.hasMarkedText())
        // Backspace deletes inside the composition, never the chip.
        textView.deleteBackward(nil)
        XCTAssertEqual(chipDismissals, 0, "Backspace stayed in the composition")
        // Once the composition ends, the same keys are the field's again.
        textView.unmarkText()
        textView.cancelOperation(nil)
        XCTAssertEqual(escapes, 1)
        XCTAssertNotEqual(model.addBar.text, "", "the draft is intact: \(text)")
        bar.window.close()
    }

    func testAnEscTheFieldDoesNotUseGoesUpTheChainWithoutRaising() {
        // NSTextView declares cancelOperation: without implementing it: the
        // field used to call `super` for an Esc it did not use, which raises.
        final class Catcher: NSView {
            var caught = 0
            override func cancelOperation(_ sender: Any?) { caught += 1 }
        }
        let bar = liveBar(escape: { false })
        let catcher = Catcher(frame: bar.view.frame)
        bar.window.contentView?.addSubview(catcher)
        bar.view.removeFromSuperview()
        catcher.addSubview(bar.view)
        bar.view.textView.cancelOperation(nil)
        XCTAssertEqual(catcher.caught, 1, "the unused Esc reached the view that holds the field")
        catcher.removeFromSuperview()
        let lone = liveBar(escape: { false })
        lone.view.textView.cancelOperation(nil) // up to the window, which has it
        lone.window.close()
        bar.window.close()
    }

    func testUndoingAReplacementSelectsTheReplacedTextAgain() {
        let bar = liveBar()
        let textView = bar.view.textView
        type("Call the office", into: bar)
        // Select "the" and type over it.
        textView.setSelectedRange(NSRange(location: 5, length: 3))
        textView.insertText("x", replacementRange: textView.selectedRange())
        XCTAssertEqual(model.addBar.text, "Call x office")
        textView.undo(nil)
        XCTAssertEqual(model.addBar.text, "Call the office")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 3), "the replaced text is selected again")
        textView.redo(nil)
        XCTAssertEqual(model.addBar.text, "Call x office")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0), "redo puts the caret after the replacement")
        bar.window.close()
    }

    func testAddingTheTaskEndsTheDraftsHistory() {
        let bar = liveBar()
        type("Buy milk", into: bar)
        XCTAssertTrue(model.addBarState.history.canUndo)
        XCTAssertNotNil(model.submitAddBar())
        XCTAssertFalse(model.addBarState.history.canUndo, "the added draft is gone")
        bar.window.close()
    }

    func testDraftHistoryCoalescesTypingAndKeepsStepsApart() {
        var history = TaskDraftHistory()
        var text = TaskAddBarText()
        func typeChar(_ c: String) {
            let at = (text.text as NSString).length
            history.willEdit(text, selection: NSRange(location: at, length: 0), range: NSRange(location: at, length: 0), replacement: c)
            text.text += c
        }
        "ab".forEach { typeChar(String($0)) }
        typeChar(" ")
        "cd".forEach { typeChar(String($0)) }
        XCTAssertEqual(history.undoStack.map(\.text.text), ["", "ab", "ab "], "a word, the space, the next word")
        history.checkpoint(text, selection: NSRange(location: 5, length: 0))
        text.dismiss(NSRange(location: 3, length: 2))
        let back = history.undo(current: text, selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(back?.text.dismissed, [])
        XCTAssertTrue(history.canRedo)
        history.willEdit(text, selection: NSRange(location: 5, length: 0), range: NSRange(location: 5, length: 0), replacement: "e")
        XCTAssertFalse(history.canRedo, "a new edit ends the redo")
        history.reset()
        XCTAssertFalse(history.canUndo)
    }

    // MARK: - Must fix 3: each menu is bound to its own press

    func testEachContextMenuIsBoundToThePressThatOpenedIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let page = Flipped(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView?.addSubview(page)
        let pointer = TasksPointer()
        pointer.view = page
        let a = UUID(), b = UUID()
        pointer.frames = [a: CGRect(x: 0, y: 100, width: 300, height: 34), b: CGRect(x: 0, y: 134, width: 300, height: 34)]
        func event(_ type: NSEvent.EventType, at y: CGFloat, control: Bool = false, in target: NSWindow? = nil,
                   time: TimeInterval = 0) -> NSEvent {
            let target = target ?? window
            // Page coordinates are flipped; the window's are not.
            let location = page.convert(NSPoint(x: 50, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: control ? .control : [],
                                      timestamp: time, windowNumber: target.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        var selected: [UUID] = []
        let select: (UUID) -> [UUID] = { selected.append($0); return [$0] }

        pointer.press(event(.rightMouseDown, at: 110), below: 90, select: select)
        XCTAssertEqual(pointer.invocation?.row, a, "a right-click binds A")
        // Dismissed without a command, then Control-click on B.
        pointer.press(event(.leftMouseDown, at: 150, control: true), below: 90, select: select)
        XCTAssertEqual(pointer.invocation?.row, b, "a Control-click binds B, never the stale A")
        XCTAssertEqual(selected, [a, b])
        // Right-click A again, then a plain click anywhere ends the binding.
        pointer.press(event(.rightMouseDown, at: 110), below: 90, select: select)
        XCTAssertEqual(pointer.invocation?.row, a)
        pointer.press(event(.leftMouseDown, at: 150), below: 90, select: select)
        XCTAssertNil(pointer.invocation, "a plain press ends the last menu's binding")
        // Over the tabs' band, or off the rows: no binding.
        pointer.press(event(.rightMouseDown, at: 50), below: 90, select: select)
        XCTAssertNil(pointer.invocation)
        // Another window's press never binds this page's rows.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        pointer.press(event(.rightMouseDown, at: 110, in: other), below: 90, select: select)
        XCTAssertNil(pointer.invocation)
        other.close()

        // Round 5 (F2): a binding lives for the menu its press opened, and
        // only for a menu on the same row.
        let c = UUID()
        pointer.press(event(.rightMouseDown, at: 110, time: 10), below: 90) { _ in [a, c] }
        pointer.menuBegan(with: event(.rightMouseDown, at: 110, time: 10))
        XCTAssertEqual(pointer.binding(for: a)?.targets, [a, c], "A's menu acts on the selection its press took")
        XCTAssertNil(pointer.binding(for: b), "a menu on B never inherits A's binding")
        // A's menu is dismissed; the next menu opens without a press (the
        // keyboard, VoiceOver): the binding is gone, the row's own targets
        // (read when its command runs) apply.
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 20,
                                                 windowNumber: window.windowNumber, context: nil, characters: " ",
                                                 charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        pointer.menuBegan(with: key)
        XCTAssertNil(pointer.binding(for: a), "a menu no press opened is not bound")
        pointer.press(event(.rightMouseDown, at: 110, time: 30), below: 90) { _ in [a] }
        pointer.menuBegan(with: nil)
        XCTAssertNil(pointer.binding(for: a), "a menu with no current event is not bound either")
        // A command ends the binding (as do hiding and a tab change).
        pointer.press(event(.rightMouseDown, at: 110, time: 40), below: 90) { _ in [a] }
        pointer.menuBegan(with: event(.rightMouseDown, at: 110, time: 40))
        XCTAssertNotNil(pointer.binding(for: a))
        pointer.endInvocation()
        XCTAssertNil(pointer.binding(for: a))
        window.close()
    }

    // MARK: - Must fix 4: the calendar's month follows its active day

    func testTheCalendarsActiveDayAndMonthMoveTogether() {
        let choices = model.dateChoices
        var cursor = TaskDateCursor(start: day("2026-09-21"))
        cursor.move(days: 1, in: choices)                           // →
        cursor.move(months: 1, in: choices, byKeyboard: true)       // Page Down
        XCTAssertEqual(cursor.active, day("2026-10-22"), "Return picks the day shown, in October")
        XCTAssertEqual(cursor.month(in: choices).month, 10)
        var clamp = TaskDateCursor(start: day("2027-01-31"))
        clamp.move(months: 1, in: choices, byKeyboard: false)       // the chevron
        XCTAssertEqual(clamp.active, day("2027-02-28"), "clamped to February's length")
        XCTAssertFalse(clamp.isKeyboardActive, "a click on the chevron draws no keyboard cursor")
        clamp.move(days: -60, in: choices)
        XCTAssertEqual(clamp.month(in: choices).month, 12, "arrows past the month's edge show the new month")
    }

    // MARK: - Must fix 6: show reveals its destination, or waits

    func testShowOpensCompletedTodayAndClearsAnExcludingDoneSearch() throws {
        let done = try XCTUnwrap(store.create(title: "Renew domain"))
        XCTAssertTrue(library.completeTask(done.id).isApplied)
        XCTAssertFalse(model.completedTodayExpanded)
        XCTAssertEqual(model.show(done.id), .shown)
        XCTAssertEqual(model.tab, .now)
        XCTAssertTrue(model.completedTodayExpanded, "Completed today opens to show it")
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == done.id })

        // A Done log task behind a search that excludes it, beyond the
        // first loaded page.
        let old = try XCTUnwrap(store.create(title: "Old invoice"))
        let oldChild = try XCTUnwrap(store.create(title: "Send it", parentID: old.id))
        XCTAssertTrue(library.completeTask(old.id).isApplied)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        for index in 0..<(TasksPageModel.doneLogPageSize + 5) {
            let filler = try XCTUnwrap(store.create(title: "Filler \(index)"))
            XCTAssertTrue(library.completeTask(filler.id).isApplied)
        }
        clock.value = clock.value.addingTimeInterval(86_400)
        _ = store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value))
        model.select(tab: .done)
        model.doneSearch = "Filler"
        model.loadDoneLogIfNeeded()
        XCTAssertFalse(model.doneLogTasks.contains { $0.id == old.id })
        XCTAssertEqual(model.show(oldChild.id), .shown, "an archived subtask shows its parent")
        XCTAssertEqual(model.tab, .done)
        XCTAssertEqual(model.doneSearch, "", "the search that hid it is cleared")
        XCTAssertTrue(model.doneLogTasks.contains { $0.id == old.id }, "its page of the log is loaded")
        XCTAssertEqual(model.doneDetailID, old.id, "its parent's details open")
        XCTAssertEqual(model.selection, [old.id])
    }

    func testAShowThatAnUnsavedEditBlocksIsNotConsumed() throws {
        let a = try XCTUnwrap(store.create(title: "A"))
        let b = try XCTUnwrap(store.create(title: "B"))
        model.beginEditingTitle(a.id)
        model.titleEdit.text = "A renamed"
        gate.shouldFail = true
        XCTAssertEqual(model.show(b.id), .blocked, "the edit could not save: the request is deferred")
        XCTAssertEqual(model.editingTitleID, a.id, "the edit and its text stay")
        gate.shouldFail = false
        XCTAssertEqual(model.show(b.id), .shown, "tried again, it goes through")
        XCTAssertEqual(store.task(withID: a.id)?.title, "A renamed")
        XCTAssertEqual(model.selection, [b.id])
    }

    func testAShowWhosePageCouldNotBeReadWaitsForRetry() throws {
        // The oldest of more tasks than one page holds, all in the Done log.
        let old = try XCTUnwrap(store.create(title: "Old invoice"))
        XCTAssertTrue(library.completeTask(old.id).isApplied)
        clock.value = clock.value.addingTimeInterval(86_400)
        for index in 0..<(TasksPageModel.doneLogPageSize + 5) {
            let filler = try XCTUnwrap(store.create(title: "Filler \(index)"))
            XCTAssertTrue(library.completeTask(filler.id).isApplied)
        }
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        _ = store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        XCTAssertFalse(model.doneLogTasks.contains { $0.id == old.id })

        // The next page's read fails: nothing is shown as if it had been.
        store.doneLogReadFailures = 1
        XCTAssertEqual(model.show(old.id), .pending, "a failed read is not success")
        XCTAssertNotNil(model.doneLogFailure)
        XCTAssertEqual(model.pendingReveal, old.id, "the page holds the request")
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.scrollRequest)

        // Retry reads the page and finishes the show.
        model.retryDoneLog()
        XCTAssertNil(model.doneLogFailure)
        XCTAssertNil(model.pendingReveal)
        XCTAssertEqual(model.selection, [old.id])
        XCTAssertEqual(model.scrollRequest?.id, old.id, "it is scrolled to (and the page focuses it)")
    }

    // MARK: - Must fix 7: cancellation, controls, edge scrolling

    func testACancelledDragCommitsNothingUntilTheButtonIsUp() {
        let session = TasksDragSession()
        XCTAssertFalse(session.isCancelled)
        session.cancel()
        XCTAssertTrue(session.isCancelled, "Esc while tracking: the release will not commit")
        session.end()
        XCTAssertFalse(session.isCancelled, "the next press starts afresh")
    }

    func testAPressOnARowsControlNeverStartsADrag() {
        let session = TasksDragSession()
        let row = UUID()
        // The row's checklist and date, in the row's own space.
        session.controlFrames[row] = [CGRect(x: 56, y: 26, width: 40, height: 16), CGRect(x: 280, y: 8, width: 60, height: 18)]
        let origin = CGPoint(x: 12, y: 200)
        XCTAssertTrue(session.isOnControl(row, at: CGPoint(x: 80, y: 234), rowOrigin: origin), "on the checklist")
        XCTAssertTrue(session.isOnControl(row, at: CGPoint(x: 310, y: 215), rowOrigin: origin), "on the date")
        XCTAssertFalse(session.isOnControl(row, at: CGPoint(x: 180, y: 215), rowOrigin: origin), "on the title: a drag")
        XCTAssertFalse(session.isOnControl(row, at: CGPoint(x: 80, y: 234), rowOrigin: nil), "unknown frame: no guess")
    }

    func testEdgeAutoScrollIsBoundedAndOnlyNearTheEdges() {
        let step = { (y: CGFloat) in TasksDragSession.autoScrollStep(y: y, top: 110, bottom: 440) }
        XCTAssertEqual(step(300), 0, "inside the usable viewport: no scrolling")
        XCTAssertLessThan(step(120), 0, "near the top: up")
        XCTAssertGreaterThan(step(430), 0, "near the bottom: down")
        XCTAssertEqual(step(0), -14, "bounded at the top")
        XCTAssertEqual(step(900), 14, "bounded at the bottom")
        XCTAssertLessThan(abs(step(145)), abs(step(115)), "faster deeper into the edge")
    }

    // MARK: - Must fix 9: the ⌘Z crash's own path

    /// The crash (AtticCUReview, 2026-09-27): EXC_BAD_ACCESS in
    /// `-[_NSUndoStack popAndInvoke]` from `-[NSUndoManager undoNestedGroup]`,
    /// from `-[NSApplication sendAction:to:from:]`, from the Edit menu item's
    /// key equivalent. Here: a real text view types into the panel's undo
    /// manager, is removed while it still has the keyboard (never resigned),
    /// is released, and the Edit menu's Undo item then performs its action
    /// on the panel through `NSMenu.performKeyEquivalent`.
    func testTheEditMenusUndoAfterAFieldWasRemovedWithoutResigning() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        let manager = try XCTUnwrap(panel.undoManager)
        weak var gone: NSTextView?
        autoreleasepool {
            let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
            field.allowsUndo = true
            panel.contentView?.addSubview(field)
            XCTAssertTrue(panel.makeFirstResponder(field))
            field.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(manager.canUndo, "typing registered with the window's undo manager")
            gone = field
            // Removed while it has the keyboard: no resign, no focus change.
            field.removeFromSuperview()
        }
        XCTAssertNil(gone?.window, "the field has left the panel")

        let menu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(AtticPanel.undo(_:)), keyEquivalent: "z")
        undoItem.target = panel
        menu.addItem(undoItem)
        let commandZ = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "z",
                                                      charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        // The menu first, as the crash's route did: nothing of the removed
        // field is invoked, and nothing crashes.
        XCTAssertTrue(menu.performKeyEquivalent(with: commandZ))
        XCTAssertFalse(manager.canUndo, "the removed field's registrations were dropped")
        XCTAssertEqual(gone?.string ?? "typed", "typed", "and never invoked")
        panel.close()
    }

    /// The Edit menu's Undo and Redo as AppKit sends them: no target, so
    /// they go to the key window's responder chain. With
    /// `ATTIC_KEY_WINDOW_TESTS` (CI) the panel is made key and AppKit
    /// resolves the target itself; elsewhere (a person's Mac, where taking
    /// the keyboard would steal their typing) the same chain is walked from
    /// the panel's first responder, as AppKit's resolution does for a key
    /// window.
    private func sendEditMenu(_ action: Selector, in panel: NSWindow) -> (target: AnyObject?, enabled: Bool, sent: Bool) {
        let item = NSMenuItem(title: "Edit", action: action, keyEquivalent: "")
        if ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" {
            panel.makeKeyAndOrderFront(nil)
            XCTAssertTrue(NSApp.keyWindow === panel, "the panel is the key window")
            let target = NSApp.target(forAction: action, to: nil, from: item) as AnyObject?
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target != nil)
            return (target, enabled, enabled && NSApp.sendAction(action, to: nil, from: item))
        }
        var responder: NSResponder? = panel.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        let enabled = (responder as? NSMenuItemValidation)?.validateMenuItem(item) ?? (responder != nil)
        return (responder, enabled, enabled && NSApp.sendAction(action, to: responder, from: item))
    }

    func testTheEditMenuUndoesTheDraftThenTheTasksHistoryAfterTheFieldIsRemoved() throws {
        let panel = AtticPanel(contentRect: CGRect(x: -4_000, y: -4_000, width: 320, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.onUnhandledUndo = { [library] redo in _ = redo ? library!.redo(in: .tasks) : library!.undo(in: .tasks) }
        panel.canPerformUnhandledUndo = { [library] redo in
            redo ? library!.undo.canRedo(in: .tasks) : library!.undo.canUndo(in: .tasks)
        }
        defer { panel.orderOut(nil); panel.close() }
        // A Tasks step to undo later, then a draft being typed.
        let added = try XCTUnwrap(store.create(title: "Ring the bank"))
        XCTAssertTrue(library.completeTask(added.id).isApplied)
        let bar = liveBar(in: panel)
        type("Buy milk", into: bar)

        // With the field there, the Edit menu's Undo is the draft's.
        let first = sendEditMenu(#selector(AtticPanel.undo(_:)), in: panel)
        XCTAssertTrue(first.target === bar.view.textView, "the field answers first")
        XCTAssertTrue(first.sent)
        XCTAssertEqual(model.addBar.text, "Buy ", "one word run undone")
        XCTAssertEqual(store.task(withID: added.id)?.status, .done, "the Tasks history was not touched")

        // The field leaves the panel while it has the keyboard.
        bar.view.removeFromSuperview()
        let undo = sendEditMenu(#selector(AtticPanel.undo(_:)), in: panel)
        XCTAssertTrue(undo.target === panel, "the panel answers once the field is gone")
        XCTAssertTrue(undo.enabled, "Undo is enabled for the Tasks history")
        XCTAssertTrue(undo.sent)
        XCTAssertEqual(store.task(withID: added.id)?.status, .todo, "the Tasks history's step was undone")
        XCTAssertEqual(model.addBar.text, "Buy ", "the draft is as it was")
        let redo = sendEditMenu(#selector(AtticPanel.redo(_:)), in: panel)
        XCTAssertTrue(redo.enabled && redo.sent)
        XCTAssertEqual(store.task(withID: added.id)?.status, .done, "and redone")
        // Nothing left to redo: the menu item is disabled, not swallowed.
        XCTAssertFalse(sendEditMenu(#selector(AtticPanel.redo(_:)), in: panel).enabled)
    }

    // MARK: - Round 5: a field that is typing keeps its keys

    func testATypingFieldIsRecognisedAndKeepsCommandZFromTheTasksHistory() throws {
        let editable = NSTextView(frame: .zero)
        XCTAssertTrue(AtticTextInput.isTyping(editable))
        editable.isEditable = false
        XCTAssertFalse(AtticTextInput.isTyping(editable), "a read-only text is not typing")
        XCTAssertFalse(AtticTextInput.isTyping(nil))
        XCTAssertFalse(AtticTextInput.isTyping(NSView(frame: .zero)))

        // A plain field with nothing of its own to undo has the keyboard:
        // the Edit menu's Undo is disabled and never reaches the Tasks
        // history (the owner's rule: no page command from a field's keys).
        let panel = AtticPanel(contentRect: CGRect(x: -4_000, y: -4_000, width: 320, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.onUnhandledUndo = { [library] redo in _ = redo ? library!.redo(in: .tasks) : library!.undo(in: .tasks) }
        panel.canPerformUnhandledUndo = { [library] redo in
            redo ? library!.undo.canRedo(in: .tasks) : library!.undo.canUndo(in: .tasks)
        }
        defer { panel.orderOut(nil); panel.close() }
        let done = try XCTUnwrap(store.create(title: "Ring the bank"))
        XCTAssertTrue(library.completeTask(done.id).isApplied)
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        panel.contentView?.addSubview(field)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let undo = sendEditMenu(#selector(AtticPanel.undo(_:)), in: panel)
        XCTAssertFalse(undo.enabled, "Undo is not offered for the Tasks history while a field types")
        panel.undo(nil)
        XCTAssertEqual(store.task(withID: done.id)?.status, .done, "the Tasks history was not touched")
        if ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" {
            XCTAssertTrue(AtticTextInput.hasKeyboard, "the key window's field has the keyboard")
        }
        // The field gone, the same Undo reaches the Tasks history.
        field.removeFromSuperview()
        XCTAssertTrue(sendEditMenu(#selector(AtticPanel.undo(_:)), in: panel).sent)
        XCTAssertEqual(store.task(withID: done.id)?.status, .todo)
    }

    // MARK: - Should fix: canonical Done order across pages

    func testTheDoneLogPagesByTheShownReplicasOrder() throws {
        let older = try XCTUnwrap(store.create(title: "Older"))
        XCTAssertTrue(library.completeTask(older.id).isApplied)            // Mon
        clock.value = clock.value.addingTimeInterval(86_400)
        let newer = try XCTUnwrap(store.create(title: "Newer"))
        XCTAssertTrue(library.completeTask(newer.id).isApplied)            // Tue
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        _ = store.moveCompletedToDoneLog(before: calendar.startOfDay(for: clock.value))
        // A stale physical copy of Older, finished later but superseded
        // (older updatedAt), as a sync import can leave.
        let shown = try XCTUnwrap(store.listedTask(withID: older.id))
        let context = ModelContext(store.container)
        let stale = TaskItem(id: shown.id, title: shown.title, status: .done, priority: shown.priority,
                             createdAt: shown.createdAt, updatedAt: shown.updatedAt.addingTimeInterval(-600),
                             completedAt: clock.value, manualOrder: shown.manualOrder, parentID: nil)
        stale.doneLoggedAt = shown.doneLoggedAt
        context.insert(stale)
        try context.save()
        store.refresh()
        XCTAssertEqual(store.listedTask(withID: older.id)?.completedAt, shown.completedAt, "the shown copy is unchanged")

        let first = store.doneLogPage(limit: 1)
        XCTAssertEqual(first.tasks.map(\.title), ["Newer"], "the newest shown task leads, across pages")
        let second = store.doneLogPage(from: first.next, limit: 1, excluding: Set(first.tasks.map(\.id)))
        XCTAssertEqual(second.tasks.map(\.title), ["Older"])
    }

    // MARK: - Should fix: pasted tasks, focus reclaim, one tick

    func testAcceptedPasteIsRevealedAndSaysWhereItWent() throws {
        model.select(tab: .done)
        model.pasteOffer = TaskPasteOffer("Buy milk\nCall mum")
        model.acceptPaste(asOne: false)
        XCTAssertNil(model.pasteOffer)
        XCTAssertEqual(model.toasts.current?.message, "Added 2 tasks to Now")
        let first = try XCTUnwrap(model.addedRequest?.id)
        XCTAssertEqual(store.task(withID: first)?.title, "Buy milk", "the first new row comes into view")
    }

    func testOnlyAPersonsInputEndsATitleEdit() {
        XCTAssertTrue(AtticRowTitleEditor.isPersonsDeparture(.leftMouseDown))
        XCTAssertTrue(AtticRowTitleEditor.isPersonsDeparture(.keyDown))
        XCTAssertFalse(AtticRowTitleEditor.isPersonsDeparture(nil), "a loss no input caused: the list settling")
        XCTAssertFalse(AtticRowTitleEditor.isPersonsDeparture(.appKitDefined))
    }

    func testOneTickForTomorrowAndNextWeekOnTheSameDay() throws {
        // Sunday 27 Sep 2026: Tomorrow and Next week are both Monday 28.
        clock.value = Date(timeIntervalSince1970: 1_790_518_400)
        let choices = model.dateChoices
        XCTAssertEqual(choices.today, day("2026-09-27"))
        let same = choices.quick.filter { $0.day == day("2026-09-28") }
        XCTAssertEqual(same.map(\.kind), [.tomorrow, .nextWeek])
        XCTAssertEqual(choices.quick.first { $0.day == day("2026-09-28") }?.kind, .tomorrow, "only the first is ticked")
    }
}
