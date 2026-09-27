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

    private func liveBar(undoFallback: @escaping () -> Void = {}) -> LiveBar {
        let state = model.addBarState
        let actions = AtticTokenFieldActions(
            submit: { _ in },
            dismissChip: { range in
                state.history.checkpoint(state.text, caret: state.caret)
                state.text.dismiss(range)
            },
            multilinePaste: { _ in false },
            escape: { false },
            undoFallback: undoFallback,
            redoFallback: {},
            edited: { range, replacement in
                state.history.willEdit(state.text, caret: state.caret, range: range, replacement: replacement)
                state.text.edited(range, replacement: replacement)
            },
            caretMoved: { caret in
                state.caret = caret
                var shown = state.text
                if shown.markShown(parser: self.model.parser, caret: caret) { state.text = shown }
            },
            undoDraft: { state.undoDraft() },
            redoDraft: { state.redoDraft() }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view.textView)
        let editor = AtticTokenFieldEditor()
        editor.textView = view.textView
        return LiveBar(window: window, view: view, editor: editor, coordinator: coordinator)
    }

    private var liveField: AtticTokenField?

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

    func testBlurKeepsTheDraftsUndoAndChipDismissalUndoes() {
        var pageUndos = 0
        let bar = liveBar(undoFallback: { pageUndos += 1 })
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
        XCTAssertEqual(pageUndos, 0, "the draft's own steps came first")
        bar.view.textView.undo(nil)
        XCTAssertEqual(pageUndos, 1, "with nothing left in the draft, ⌘Z reaches the Tasks history")
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
            history.willEdit(text, caret: at, range: NSRange(location: at, length: 0), replacement: c)
            text.text += c
        }
        "ab".forEach { typeChar(String($0)) }
        typeChar(" ")
        "cd".forEach { typeChar(String($0)) }
        XCTAssertEqual(history.undoStack.map(\.text.text), ["", "ab", "ab "], "a word, the space, the next word")
        history.checkpoint(text, caret: 5)
        text.dismiss(NSRange(location: 3, length: 2))
        let back = history.undo(current: text, caret: 5)
        XCTAssertEqual(back?.text.dismissed, [])
        XCTAssertTrue(history.canRedo)
        history.willEdit(text, caret: 5, range: NSRange(location: 5, length: 0), replacement: "e")
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
        func event(_ type: NSEvent.EventType, at y: CGFloat, control: Bool = false, in target: NSWindow? = nil) -> NSEvent {
            let target = target ?? window
            // Page coordinates are flipped; the window's are not.
            let location = page.convert(NSPoint(x: 50, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: control ? .control : [],
                                      timestamp: 0, windowNumber: target.windowNumber, context: nil,
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
        window.close()
    }
}
