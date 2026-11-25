import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 13: who owns the keyboard. A subtask focused by Tab, a task menu
/// popped up as a real NSMenu, the composer's undo history: each is driven
/// with real key events through the app's queue, real Tab focus changes and
/// a real menu, never by calling the handlers.
@MainActor
final class TasksRound13Tests: XCTestCase {
    /// host-boundary.md §5.1 row, as the user's sequence: a tab switch while
    /// the panel is not key, then the panel becomes key and ↓. Wanted: a row
    /// of the shown tab takes the keyboard. Today no row does, on step 1 as
    /// on the trunk (`4b55a9e8`, the same test): pinned, KB-DOWN-AFTER-NOTKEY-SWITCH.
    /// Its fix flips this assertion.
    func testDownAfterASwitchMadeWhileThePanelWasNotKeyIsPinned() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row")
        let other = NSWindow(contentRect: CGRect(x: -3_000, y: -3_000, width: 80, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        hosted.spin(0.2)
        XCTAssertFalse(hosted.window.isKeyWindow, "another window is key")
        hosted.go(to: .backlog)
        hosted.window.makeKey()
        hosted.spin(0.3)
        XCTAssertTrue(hosted.window.isKeyWindow, "the panel is key again")
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertNil(hosted.model.keyboardFocus?.page, "KB-DOWN-AFTER-NOTKEY-SWITCH: today ↓ reaches no row (pinned; the fix makes it a row of the shown tab)")
    }

    /// host-boundary.md §5.1 row, as the user's sequence: a rename on Now,
    /// a switch to Later (which saves it), then ↓. Wanted: a Later row takes
    /// the keyboard. Today no row does, on step 1 as on the trunk
    /// (`4b55a9e8`, the same test): pinned, KB-DOWN-AFTER-RENAME-SWITCH. Its
    /// fix flips this assertion.
    func testDownAfterASwitchThatSavedARenameIsPinned() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        hosted.press("\u{F701}", keyCode: 125)
        let row = try XCTUnwrap(hosted.model.keyboardFocus?.id, "↓ on Now reaches a Now row")
        hosted.model.beginEditingTitle(row)
        hosted.spin(0.4)
        XCTAssertEqual(hosted.model.editingTitleID, row, "the rename is open")
        hosted.go(to: .backlog)
        XCTAssertNil(hosted.model.editingTitleID, "the switch saved the rename")
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertNil(hosted.model.keyboardFocus?.page, "KB-DOWN-AFTER-RENAME-SWITCH: today ↓ reaches no row (pinned; the fix makes it a Later row)")
    }

    /// host-boundary.md §5.1 row: a responder in the panel outside the tabs
    /// (as an open dropdown's host) keeps the keyboard across a switch. The
    /// trunk runs the same test as the reference.
    func testAResponderOutsideTheTabsKeepsTheKeyboardAcrossASwitch() throws {
        final class StandIn: NSView { override var acceptsFirstResponder: Bool { true } }
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "↓ on Now reaches a Now row")
        let standIn = StandIn(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        hosted.window.contentView?.addSubview(standIn)
        defer { standIn.removeFromSuperview() }
        XCTAssertTrue(hosted.window.makeFirstResponder(standIn))
        hosted.spin(0.2)
        XCTAssertTrue(hosted.window.firstResponder === standIn, "it holds the keyboard before the switch")
        hosted.go(to: .backlog)
        XCTAssertTrue(hosted.window.firstResponder === standIn, "and after it: \(String(describing: hosted.window.firstResponder))")
    }

    // H12-06: native Tab focus must supersede a previous arrow selection.
    func testH12_06TabFocusMovesSelectionAndReturnEditsTheFocusedTask() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("native keyboard interaction runs on CI only")
        }
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.press("\u{F701}", keyCode: 125)
        let first = try XCTUnwrap(hosted.model.keyboardFocus)
        XCTAssertEqual(hosted.model.selection, [first.id])
        hosted.press("\t", keyCode: 48)
        let next = try XCTUnwrap(hosted.model.keyboardFocus)
        XCTAssertNotEqual(next.id, first.id, "Tab reached the next row's visible focus ring")
        XCTAssertEqual(hosted.model.selection, [next.id], "selection follows keyboard focus")
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, next.id, "Return edits the visibly focused task")
    }

    /// Review 8, kept by the night job's a2f6599d (the focus watch reads
    /// the snapshot's ordered IDs): Space completes the row the keyboard is
    /// on, and once that row leaves Now the keyboard moves to the row that
    /// took its place. (The selection is printed, not asserted: it is empty
    /// afterwards on the trunk too, a separate board finding.)
    func testSpaceOnTheFocusedRowMovesTheKeyboardToTheRowThatTookItsPlace() throws {
        try requireKeyWindowTests()
        var services = TasksPageServices()
        services.acknowledgementDelay = .milliseconds(50)
        services.doneHold = .milliseconds(300)
        let hosted = try Hosted(height: 520, services: services)
        defer { hosted.close() }
        hosted.press("\u{F701}", keyCode: 125)
        hosted.press("\t", keyCode: 48)
        let focused = try XCTUnwrap(hosted.model.keyboardFocus?.id, "Tab gave a row the keyboard")
        let before = hosted.model.rows(for: .now).map(\.id)
        let index = try XCTUnwrap(before.firstIndex(of: focused))
        XCTAssertLessThan(index + 1, before.count, "a row below takes its place")
        let expected = before[index + 1]

        hosted.press(" ", keyCode: 49)
        func stillOnNow() -> Bool { hosted.model.rows(for: .now).contains { $0.id == focused } }
        for _ in 0..<40 where stillOnNow() { hosted.spin(0.1) }  // the save, then the hold's release
        XCTAssertFalse(stillOnNow(), "the completed row left Now")
        XCTAssertEqual(hosted.store.task(withID: focused)?.status, .done)
        hosted.spin(0.4)
        print("FOCUS_TRANSFER completed=\(focused) expected=\(expected) "
              + "focus=\(hosted.model.keyboardFocus?.id.uuidString ?? "nil") selection=\(hosted.model.selection.map(\.uuidString))")
        XCTAssertEqual(hosted.model.keyboardFocus?.id, expected, "the keyboard moved to the row that took its place")
    }

    func testAR08NativeTabAndShiftTabPreserveExtendedSelectionAndReturnEditsFocus() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("native keyboard interaction runs on CI only")
        }
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.press("\u{F701}", keyCode: 125)
        hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)
        let selection = hosted.model.selection
        XCTAssertEqual(selection.count, 2)
        for _ in 0..<6 {
            hosted.press("\t", keyCode: 48)
            XCTAssertEqual(hosted.model.selection, selection, "Tab never silently collapses a range")
            if let focus = hosted.model.keyboardFocus, !selection.contains(focus.id) { break }
        }
        let outside = try XCTUnwrap(hosted.model.keyboardFocus)
        XCTAssertFalse(selection.contains(outside.id))
        hosted.press("\u{19}", keyCode: 48, modifiers: .shift)
        XCTAssertEqual(hosted.model.selection, selection, "Shift-Tab preserves the range")
        let back = try XCTUnwrap(hosted.model.keyboardFocus)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, back.id, "Return edits the visibly focused row")
    }

    // MARK: - Bug 3: a Tab-focused subtask owns ⌘↑ ⌘↓ and Return

    /// The demo task with subtasks, expanded, and a Tab pressed until a
    /// subtask line has the keyboard.
    private func tabToASubtask(_ hosted: Hosted) throws -> (parent: UUID, subtask: UUID) {
        let model = hosted.model
        let ship = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        model.setExpanded(ship.id, true)
        hosted.spin(1)
        var tabs = 0
        while model.focusedSubtaskID == nil, tabs < 14 {
            hosted.press("\t", keyCode: 48)
            tabs += 1
        }
        return (ship.id, try XCTUnwrap(model.focusedSubtaskID, "Tab reached a subtask line"))
    }

    private func subtasks(_ hosted: Hosted, of parent: UUID) -> [String] {
        (hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks ?? []).map(\.title)
    }

    func testCommandDownReordersATabFocusedSubtaskNotItsParent() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (parent, subtask) = try tabToASubtask(hosted)
        let rowsBefore = hosted.model.rows(for: .now).map(\.model.title)
        let before = subtasks(hosted, of: parent)
        let title = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks.first { $0.id == subtask }?.title)
        XCTAssertEqual(before.first, title, "the first Tab stop in the quick look is its first subtask")
        hosted.press("\u{F701}", keyCode: 125, modifiers: .command)
        let after = subtasks(hosted, of: parent)
        XCTAssertNotEqual(after, before, "the subtask moved down")
        XCTAssertEqual(after.firstIndex(of: title), 1)
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.model.title), rowsBefore, "the parent did not move")
        hosted.press("\u{F700}", keyCode: 126, modifiers: .command)
        XCTAssertEqual(subtasks(hosted, of: parent), before, "⌘↑ moves it back")
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.model.title), rowsBefore)
    }

    func testReturnRenamesATabFocusedSubtaskNotItsParent() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (_, subtask) = try tabToASubtask(hosted)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.renamingSubtaskID, subtask, "Return renames the subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and not the parent's title")
    }

    func testDeleteStillDeletesATabFocusedSubtask() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (parent, subtask) = try tabToASubtask(hosted)
        let before = subtasks(hosted, of: parent).count
        hosted.press("\u{7F}", keyCode: 51)
        XCTAssertEqual(subtasks(hosted, of: parent).count, before - 1)
        XCTAssertFalse(hosted.model.rows(for: .now).first { $0.id == parent }?.subtasks.contains { $0.id == subtask } ?? true)
    }

    // MARK: - Bug 2: Return in an open task menu activates the highlighted item

    /// Posts real key presses to the app while a menu tracks: each fires from
    /// a timer in the common modes (menu tracking is not the default mode),
    /// with an Esc at the end so a menu that ignores them cannot hang the run.
    private func schedule(_ keys: [(characters: String, keyCode: UInt16)], in hosted: Hosted, from start: TimeInterval = 0.8,
                          step: TimeInterval = 0.25, coreGraphicsReturn: Bool = false) -> [Timer] {
        func post(_ characters: String, _ keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event: NSEvent
                if coreGraphicsReturn, keyCode == 36 {
                    let cg = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type == .keyDown)!
                    cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                    event = NSEvent(cgEvent: cg)!
                } else {
                    event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                }
                NSApp.postEvent(event, atStart: false)
            }
        }
        var when = start
        var timers: [Timer] = []
        for key in keys {
            let timer = Timer(timeInterval: when, repeats: false) { _ in MainActor.assumeIsolated { post(key.characters, key.keyCode) } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            when += step
        }
        let escape = Timer(timeInterval: when + 2.5, repeats: false) { _ in MainActor.assumeIsolated { post("\u{1B}", 53) } }
        RunLoop.main.add(escape, forMode: .common)
        timers.append(escape)
        return timers
    }

    /// The row selected and focused, a real secondary click on it (a native
    /// menu pops up; ⇧⌘I opens the page since 2026-10-30), `keys` typed into
    /// the menu, and the run spun until it closed.
    private func openActionsMenu(_ hosted: Hosted, on title: String, keys: [(characters: String, keyCode: UInt16)],
                                 coreGraphicsReturn: Bool = false) throws -> UUID {
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
        try hosted.clickRow(row, tab: .now)
        XCTAssertEqual(model.selection, [row])
        let timers = schedule(keys, in: hosted, coreGraphicsReturn: coreGraphicsReturn)
        defer { timers.forEach { $0.invalidate() } }
        hosted.rightClick(y: try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row)]).midY, x: 200)
        hosted.spin(1.5)
        return row
    }

    func testReturnInTheActionsMenuActivatesTheHighlightedItemNotEditTitle() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try openActionsMenu(hosted, on: "Ship appearance PR", keys: [("\u{F701}", 125), ("\u{F701}", 125), ("\r", 36)])
        // Complete, then Start Working: the second item is highlighted.
        XCTAssertNil(hosted.model.editingTitleID, "Return did not start Edit Title")
        XCTAssertEqual(hosted.store.task(withID: row)?.status, .inProgress, "Return started work on the highlighted Start Working")
    }

    func testReturnOnAddSubtaskInTheActionsMenuOpensTheSubtaskEditor() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        // Dropdown content: answers (owner, 2026-10-24), answer 1 A: Complete,
        // Start Working, Edit Title, Add Subtask (4th), Date (5th), Tags,
        // Priority, Move to Backlog, More (9th), Delete.
        let row = try openActionsMenu(hosted, on: "Call the plumber", keys: Array(repeating: down, count: 4) + [("\r", 36)])
        XCTAssertEqual(hosted.model.newSubtaskParentID, row, "Return ran Add Subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and did not edit the parent's title")
    }

    /// A CoreGraphics-backed Return down/up pair goes through the native
    /// menu tracker, including its internal key-equivalent lookup. No direct
    /// responder dispatch or permission-dependent CGEvent posting is used.
    func testCoreGraphicsBackedReturnInTheActionsMenuRunsTheHighlightedItem() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let row = try openActionsMenu(hosted, on: "Call the plumber",
                                     keys: Array(repeating: down, count: 4) + [("\r", 36)], // Add Subtask is 4th (answer 1 A)
                                     coreGraphicsReturn: true)
        XCTAssertEqual(hosted.model.newSubtaskParentID, row, "the highlighted Add Subtask owns Return")
        XCTAssertNil(hosted.model.editingTitleID, "the key never edits the parent")
    }

    func testReturnOpensAHighlightedSubmenuAndRunsItsHighlightedCommand() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let row = try openActionsMenu(hosted, on: "Call the plumber",
                                     keys: Array(repeating: down, count: 5) + [("\r", 36), down, ("\r", 36)], // Date is 5th (answer 1 A)
                                     coreGraphicsReturn: true)
        XCTAssertNotNil(hosted.model.dueDay(of: row), "Return opens Date, then runs its highlighted quick day")
        XCTAssertNil(hosted.model.editingTitleID)
    }

    func testReturnWithoutAnActionsMenuStillEditsTheSelectedTitle() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Call the plumber" }?.id)
        try hosted.clickRow(row, tab: .now)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, row)
        XCTAssertNil(hosted.model.newSubtaskParentID)
    }

    func testReturnAfterCancellingAnActionsMenuStillEditsTheSelectedTitle() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try openActionsMenu(hosted, on: "Call the plumber", keys: [("\u{1B}", 53)])
        XCTAssertNil(hosted.model.editingTitleID)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, row)
        XCTAssertNil(hosted.model.newSubtaskParentID)
    }

    /// A pop-up menu shows a bare key's shortcut (Return beside Edit Title)
    /// but never answers it as a key equivalent; ⌘ shortcuts still work.
    func testPopUpMenusShowBareShortcutsButAnswerOnlyModifiedOnes() {
        var ran: [String] = []
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Edit Title", shortcut: AtticTaskShortcut.editTitle) { ran.append("edit") },
            AtticMenuCommand(verbatim: "Later", shortcut: AtticTaskShortcut.later) { ran.append("later") }
        ])
        XCTAssertEqual(menu.items.first?.keyEquivalent, "", "Return is not registered with the native tracker")
        XCTAssertEqual(menu.items.first?.badge?.stringValue, "↩", "the list's Return shortcut remains discoverable")
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
        XCTAssertFalse(menu.performKeyEquivalent(with: key("\r", 36, [])))
        XCTAssertEqual(ran, [], "Return does not run Edit Title")
        XCTAssertTrue(menu.performKeyEquivalent(with: key("b", 11, .command)))
        XCTAssertEqual(ran, ["later"], "⌘B still runs Later")
    }

    func testAllBareMenuShortcutsAreHintsAndKeepExistingDetails() {
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Complete", shortcut: AtticTaskShortcut.complete) {},
            AtticMenuCommand(verbatim: "Start Working", shortcut: AtticTaskShortcut.working) {},
            AtticMenuCommand(verbatim: "Delete", shortcut: AtticTaskShortcut.delete) {},
            AtticMenuCommand(verbatim: "Edit Title", shortcut: AtticTaskShortcut.editTitle, detail: "Tue") {}
        ])
        XCTAssertEqual(menu.items.map(\.keyEquivalent), ["", "", "", ""])
        XCTAssertEqual(menu.items.map { $0.badge?.stringValue }, ["Space", "⇧Space", "⌫", "Tue · ↩"])
    }

    /// Dispatch always runs the chosen item's action. Keyboard ownership
    /// is resolved before dispatch, without redirecting pointer actions.
    func testChoosingAMenuItemRunsThatItemsCommand() throws {
        var ran: [String] = []
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Edit Title", shortcut: AtticTaskShortcut.editTitle) { ran.append("edit") },
            AtticMenuCommand(verbatim: "Add Subtask") { ran.append("subtask") },
            AtticMenuCommand(verbatim: "Later", shortcut: AtticTaskShortcut.later) { ran.append("later") }
        ])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 2)
        XCTAssertEqual(ran, ["subtask", "edit", "later"])
    }

    // MARK: - Bug 1: ⌘Z after a task-menu change

    /// Synthetic typing goes to the key window's first responder. A requested
    /// SwiftUI focus binding does not prove its deferred AppKit focus landed.
    /// Find the actual composer and establish the same state a click gives it.
    private func focusComposer(in hosted: Hosted) throws {
        func composers(in view: NSView) -> [AtticTokenTextView] {
            if let text = view as? AtticTokenTextView,
               text.owner?.parent.accessibilityLabel == hosted.model.addPlaceholder,
               !text.isHiddenOrHasHiddenAncestor { return [text] }
            return view.subviews.flatMap { composers(in: $0) }
        }
        print("ROUND13_COMPOSER_FOCUS requested=\(hosted.focus.addBar) key=\(hosted.window.isKeyWindow) responder=\(String(describing: hosted.window.firstResponder))")
        hosted.focus.addBar = true
        let content = try XCTUnwrap(hosted.window.contentView)
        let deadline = Date().addingTimeInterval(2)
        var fields = composers(in: content)
        while fields.isEmpty, Date() < deadline {
            content.layoutSubtreeIfNeeded()
            hosted.spin(0.01)
            fields = composers(in: content)
        }
        XCTAssertEqual(fields.count, 1, "one live composer is ready")
        let composer = try XCTUnwrap(fields.first)
        hosted.window.makeKey()
        XCTAssertTrue(hosted.window.makeFirstResponder(composer))
        XCTAssertTrue(hosted.window.isKeyWindow)
        XCTAssertTrue(hosted.window.firstResponder === composer)
    }

    private func priority(of id: UUID, _ hosted: Hosted) -> TaskPriority? {
        hosted.store.listedTask(withID: id)?.priority
    }

    /// The composer holds a draft and the keyboard; a task's priority is
    /// changed from its menu (the model call the menu makes). Real ⌘Z
    /// undoes that change and keeps the draft; ⌘Z again is the draft's own
    /// typing undo; typing after a menu change gives ⌘Z back to the field.
    func testCommandZAfterATaskMenuChangeUndoesTheChangeAndKeepsTheDraft() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        let original = try XCTUnwrap(priority(of: row.id, hosted))
        try focusComposer(in: hosted)
        XCTAssertTrue(hosted.window.firstResponder is AtticTokenTextView, "the composer has the keyboard")
        hosted.press("a", keyCode: 0)
        hosted.press("b", keyCode: 11)
        XCTAssertEqual(model.addBar.text, "ab")

        model.setPriority(.high, for: [row.id])
        hosted.spin(0.3)
        XCTAssertEqual(priority(of: row.id, hosted), .high)
        XCTAssertTrue(hosted.window.firstResponder is AtticTokenTextView, "the composer still has the keyboard")

        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertEqual(priority(of: row.id, hosted), original, "the first ⌘Z undid the menu change")
        XCTAssertEqual(model.addBar.text, "ab", "the draft was kept")

        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertNotEqual(model.addBar.text, "ab", "the next ⌘Z is the composer's typing undo")
        XCTAssertEqual(priority(of: row.id, hosted), original)
    }

    func testTypingAfterATaskMenuChangeGivesCommandZBackToTheComposer() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        try focusComposer(in: hosted)
        hosted.press("a", keyCode: 0)
        XCTAssertEqual(model.addBar.text, "a")
        model.setPriority(.high, for: [row.id])
        hosted.spin(0.3)
        hosted.press("b", keyCode: 11)
        XCTAssertEqual(model.addBar.text, "ab")
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertEqual(priority(of: row.id, hosted), .high, "typing came after the change: ⌘Z is text Undo")
        XCTAssertNotEqual(model.addBar.text, "ab")
    }

    func testRedoBringsBackATaskMenuChangeAfterAClaimedUndo() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        try focusComposer(in: hosted)
        hosted.press("a", keyCode: 0)
        XCTAssertEqual(model.addBar.text, "a", "the real key reached the composer before the menu change")
        model.setPriority(.high, for: [row.id])
        hosted.spin(0.3)
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertNotEqual(priority(of: row.id, hosted), .high)
        XCTAssertEqual(model.addBar.text, "a", "claimed Undo preserved the draft")
        hosted.press("z", keyCode: 6, modifiers: [.command, .shift])
        XCTAssertEqual(priority(of: row.id, hosted), .high, "⇧⌘Z redid the menu change")
        XCTAssertEqual(model.addBar.text, "a")
    }

    // MARK: - Item 4: Full-animation reorder does not overlap rows

    /// How much ink each pixel line of the two rows' band holds, so the
    /// lines between the titles can be told from the titles themselves.
    private func inkProfile(_ hosted: Hosted, top: CGFloat, bottom: CGFloat) throws -> [Int] {
        let content = try XCTUnwrap(hosted.window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let x0 = Int(40 * scale), x1 = Int((content.bounds.width - 40) * scale)
        return (Int(top * scale)..<Int(bottom * scale)).map { y in
            guard let base = rep.colorAt(x: x0, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return stride(from: x0, to: x1, by: 2).reduce(0) { count, x in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return count }
                let d = max(abs(c.redComponent - base.redComponent), abs(c.greenComponent - base.greenComponent),
                            abs(c.blueComponent - base.blueComponent))
                return count + (d > 0.12 ? 1 : 0)
            }
        }
    }

    /// Move a row down with ⌘↓ under Full animation and look at the picture
    /// every frame or so while it settles: the two rows' band must never
    /// hold ink between the lines the titles sit on before and after (two
    /// rows sliding through each other put titles and circles there).
    func testAFullAnimationReorderNeverPutsInkBetweenTheRowsLines() throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let rows = model.rows(for: .now)
        // Two neighbours in one group (started and not started stay apart).
        // (and, in the owner's panel design, in one date group).
        let at = try XCTUnwrap(rows.indices.dropLast().first { rows[$0].status == rows[$0 + 1].status && rows[$0].status != .done
            && model.groupKey(of: rows[$0].id, on: .now) == model.groupKey(of: rows[$0 + 1].id, on: .now) })
        let pair = [rows[at], rows[at + 1]]
        let first = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: pair[0].id)])
        let second = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: pair[1].id)])
        let top = min(first.minY, second.minY), bottom = max(first.maxY, second.maxY)
        try hosted.clickRow(pair[0].id, tab: .now)
        hosted.spin(0.6)
        let before = try inkProfile(hosted, top: top, bottom: bottom)
        hosted.press("\u{F701}", keyCode: 125, modifiers: .command)
        hosted.spin(1)
        XCTAssertEqual(model.rows(for: .now).map(\.id)[at], pair[1].id, "the row moved down one place")
        let after = try inkProfile(hosted, top: top, bottom: bottom)
        // Put it back and sample the return trip frame by frame.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                                             context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                             isARepeat: false, keyCode: 126)!, atStart: false)
            Hosted.pumpEvents()
        }
        XCTAssertEqual(model.rows(for: .now).map(\.id)[at], pair[0].id)
        var worst = 0
        var samples = 0
        let end = Date().addingTimeInterval(0.6)
        while Date() < end {
            let now = try inkProfile(hosted, top: top, bottom: bottom)
            var gap = 0
            for (line, ink) in now.enumerated() where before[line] == 0 && after[line] == 0 { gap += ink }
            worst = max(worst, gap)
            samples += 1
            hosted.spin(0.016)
        }
        XCTAssertGreaterThan(samples, 3)
        let text = before.reduce(0, +)
        XCTAssertLessThan(Double(worst), Double(text) * 0.06, "ink between the titles' lines while rows reorder: \(worst) of \(text)")
    }

    // MARK: - Item 5, revised by A15: faint under the controls, whole at rest

    /// N-6 D hid rows under the header and the tabs line; the owner's
    /// 10-17 decision supersedes it (rows run on under them, visible
    /// through the blur: `RoundO3ControlsTests`). Still: the tabs' plain
    /// line (its underline included) is part of the top controls, and the
    /// first row's words rest below it.
    func testTheFirstRowsWordsRestBelowTheTabsLine() {
        let rest = TasksViewport.listTop(tabsTop: 80) + AtticTaskRowMetrics.titleTop(twoLine: false)
        // The owner's panel design: the controls end at `tabsTop` (no tabs line).
        XCTAssertGreaterThan(rest, 80)
        XCTAssertGreaterThanOrEqual(TasksViewport.topEdges(tabsTop: 80).top, 80, "the blur covers the header's controls")
    }

    // MARK: - Item 6: the new-subtask field says what it is

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap { textFields(in: $0) }
    }

    func testTheNewSubtaskFieldShowsAddSubtaskAsItsPlaceholder() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let ship = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" })
        hosted.model.beginAddingSubtask(to: ship.id)
        hosted.spin(1)
        let content = try XCTUnwrap(hosted.window.contentView)
        let prompts = textFields(in: content).compactMap { $0.placeholderString ?? ($0.placeholderAttributedString?.string) }
        XCTAssertTrue(prompts.contains("Add subtask…"), "an empty new-subtask line reads Add subtask… (found \(prompts))")
        hosted.model.newSubtaskTitle = "Pack"
        hosted.spin(0.4)
        let typed = textFields(in: content).filter { $0.stringValue == "Pack" }
        XCTAssertFalse(typed.isEmpty, "the typed text replaces the prompt")
    }

    // MARK: - Item 7: the Settings pop-up's list is opaque

    /// A pop-up row's list drawn over a solid black page shows none of it:
    /// the popover's own surface is what is behind the choices.
    func testAPopUpRowsChoicesHideWhatLiesBehindThem() throws {
        struct Scene: View {
            var body: some View {
                ZStack {
                    Color.black
                    AtticPopUpChoices(label: "Surface", choices: [("solid", "Solid"), ("glass", "Glass"), ("clear", "Clear")],
                                      selection: "solid") { _ in }
                }
                .environment(\.atticDesign, AtticDesignContext(mode: .light))
            }
        }
        let host = NSHostingView(rootView: Scene())
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // The list is centred; the right strip of its lower two rows (past
        // the titles, off the ticked row's fill) is bare surface. The
        // bitmap is in pixels: the view's points times the backing scale.
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let listMinX = (320 - AtticPopoverMetrics.defaultWidth) / 2
        var dark = 0, total = 0
        for x in Int((listMinX + AtticPopoverMetrics.defaultWidth - 40) * scale)..<Int((listMinX + AtticPopoverMetrics.defaultWidth - 12) * scale) {
            for y in Int(92 * scale)..<Int(124 * scale) {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                total += 1
                if color.brightnessComponent < 0.9 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(dark, 0, "the backdrop shows through \(dark) of \(total) sampled pixels")
    }
}

// MARK: - Keys on a row outside the lazy list's built range (list-owned-focus.md §2.3; lead, LOG 24 Nov 17:01)

/// The trunk's behaviour, pinned on 5fe27e46 before the list-owned focus
/// change and kept by it: when the list scrolls the cursor row out of the
/// lazy list's built range, Space, Delete and ⌘B still act, on the rows
/// the trunk acts on. Each case starts from a fresh page; before the key
/// the test checks, apart from the key's effect, that the row's cell is
/// gone (it reports no frame), what is selected, and that the keyboard is
/// in the Now list.
@MainActor
extension TasksRound13Tests {
    private func longHosted() throws -> Hosted {
        var services = TasksPageServices()
        services.acknowledgementDelay = .milliseconds(50)
        services.doneHold = .milliseconds(300)
        let hosted = try Hosted(height: 520, services: services)
        let context = ModelContext(hosted.store.container)
        let now = Date()
        for index in 0..<80 {
            let item = TaskItem(title: "Long list task \(index + 1)", status: .todo, priority: .none,
                                createdAt: now.addingTimeInterval(Double(-(20 + index) * 60)),
                                manualOrder: -2_000_000 - Int64(index) * 1_024, parentID: nil)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
        }
        try context.save()
        hosted.store.refresh()
        hosted.spin(0.8)
        return hosted
    }

    /// The Now list on the page: the shown, tallest list.
    private func nowList(_ hosted: Hosted) -> NSScrollView? {
        guard let content = hosted.window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return hosted.lists(in: content).filter { list in
            let frame = list.convert(list.bounds, to: nil)
            return !list.isHiddenOrHasHiddenAncestor && frame.minX > -1 && frame.minX < content.bounds.width / 2
        }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func scrollNow(_ hosted: Hosted, toEnd: Bool) throws {
        let list = try XCTUnwrap(nowList(hosted), "harness: the Now list")
        let document = list.documentView?.frame.height ?? 0, visible = list.contentView.bounds.height
        list.contentView.scroll(to: NSPoint(x: 0, y: toEnd ? max(0, document - visible) : 0))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.6)
    }

    /// Whether the row's cell is built: its frame is set in the cell's
    /// `onAppear` and removed in its `onDisappear` (TasksPage's cell), so
    /// false after a scroll is the lazy list's teardown of that cell, seen.
    private func isBuilt(_ hosted: Hosted, _ id: UUID) -> Bool {
        hosted.pointer.frame(for: TasksRowID(tab: .now, id: id)) != nil
    }

    /// The keyboard is in the Now list: its first responder is the view
    /// that holds the list (the tab's host), not a field.
    private func keyboardIsInNowList(_ hosted: Hosted) -> Bool {
        guard let view = hosted.window.firstResponder as? NSView, !(view is NSTextView), let list = nowList(hosted) else { return false }
        return list.isDescendant(of: view)
    }

    private func clickRow(_ hosted: Hosted, _ id: UUID, modifiers: NSEvent.ModifierFlags = []) throws {
        let frame = try XCTUnwrap(hosted.pointer.frame(for: TasksRowID(tab: .now, id: id)), "harness: the row is built")
        let view = try XCTUnwrap(hosted.pointer.view)
        let inWindow = view.convert(frame, to: nil)
        hosted.click(y: hosted.height - inWindow.midY, x: inWindow.minX + min(110, inWindow.width / 2), modifiers: modifiers)
        hosted.spin(0.3)
    }

    /// What each Now row is: its status, or gone.
    private func states(_ hosted: Hosted, _ ids: [UUID]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: ids.map { id in (id, hosted.store.task(withID: id).map { "\($0.status)" } ?? "gone") })
    }

    private enum Selected { case one, several, cursorOutside }

    private static let rowKeys: [(name: String, characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, after: String)] = [
        ("Space", " ", 49, [], "done"), ("Delete", "\u{7F}", 51, [], "gone"), ("⌘B", "b", 11, .command, "backlog"),
    ]

    /// Sets up `selected` near the top of the long list, scrolls the list to
    /// its end, checks the state before the key, presses it, and returns the
    /// rows whose state changed, with what they became.
    private func keyOutOfRange(_ selected: Selected, key: (name: String, characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, after: String),
                               _ hosted: Hosted) throws -> (acted: [Int: String], selection: [Int], cursorBefore: Int?) {
        let ids = hosted.model.rows(for: .now).map(\.id)
        func index(_ id: UUID) -> Int { ids.firstIndex(of: id) ?? -1 }
        try clickRow(hosted, ids[0])
        switch selected {
        case .one:
            hosted.press("\u{F701}", keyCode: 125)  // cursor and selection on row 1
        case .several:
            hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)
            hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)  // rows 0-2, cursor on 2
        case .cursorOutside:
            // Two ⌘-clicks on row 2 leave the cursor on row 2 and nothing
            // selected (the trunk, lt-trunk.log 24 Nov 20:2x, Air).
            try clickRow(hosted, ids[2], modifiers: .command)
            try clickRow(hosted, ids[2], modifiers: .command)
        }
        let cursorBefore = hosted.model.keyboardFocus.map { index($0.id) }
        let selection = hosted.model.selection.map(index).sorted()
        try scrollNow(hosted, toEnd: true)
        for row in 0...2 { XCTAssertFalse(isBuilt(hosted, ids[row]), "harness: row \(row) is still built after the scroll") }
        XCTAssertTrue(keyboardIsInNowList(hosted), "harness: the keyboard is not in the Now list before \(key.name)")
        XCTAssertEqual(hosted.model.selection.map(index).sorted(), selection, "harness: the scroll changed the selection")
        let before = states(hosted, ids)
        hosted.press(key.characters, keyCode: key.code, modifiers: key.modifiers)
        var waited = 0.0
        while waited < 3, states(hosted, ids) == before { hosted.spin(0.1); waited += 0.1 }
        hosted.spin(0.5)
        let after = states(hosted, ids)
        let acted = Dictionary(uniqueKeysWithValues: ids.enumerated().compactMap { offset, id in
            after[id] != before[id] ? (offset, after[id] ?? "?") : nil
        })
        print("OUT_OF_RANGE \(selected) \(key.name) cursor_before=\(cursorBefore.map(String.init) ?? "nil") selection=\(selection) acted=\(acted.sorted { $0.key < $1.key })")
        return (acted, selection, cursorBefore)
    }

    /// Condition 1, one selected row: the key acts on that row only.
    func testKeysOnAnOutOfRangeCursorRowActOnTheOneSelectedRow() throws {
        try requireKeyWindowTests()
        for key in Self.rowKeys {
            let hosted = try longHosted()
            defer { hosted.close() }
            let result = try keyOutOfRange(.one, key: key, hosted)
            XCTAssertEqual(result.selection, [1], "harness: ↓ selected row 1")
            XCTAssertEqual(result.acted, [1: key.after], "\(key.name) out of the built range")
        }
    }

    /// Condition 1, several selected rows with the cursor row among them:
    /// the key acts on every selected row.
    func testKeysOnAnOutOfRangeCursorRowActOnEverySelectedRow() throws {
        try requireKeyWindowTests()
        for key in Self.rowKeys {
            let hosted = try longHosted()
            defer { hosted.close() }
            let result = try keyOutOfRange(.several, key: key, hosted)
            XCTAssertEqual(result.selection, [0, 1, 2], "harness: ⇧↓ twice selected rows 0-2")
            XCTAssertEqual(result.cursorBefore, 2, "harness: the cursor was on row 2")
            XCTAssertEqual(result.acted, [0: key.after, 1: key.after, 2: key.after], "\(key.name) out of the built range")
        }
    }

    /// Condition 1, the cursor on a row that is not selected (two ⌘-clicks
    /// on row 2 leave the cursor there and the selection empty): the key
    /// acts on the cursor row, as the trunk does.
    func testKeysOnAnOutOfRangeCursorRowOutsideTheSelection() throws {
        try requireKeyWindowTests()
        for key in Self.rowKeys {
            let hosted = try longHosted()
            defer { hosted.close() }
            let result = try keyOutOfRange(.cursorOutside, key: key, hosted)
            XCTAssertEqual(result.selection, [], "harness: nothing is selected")
            XCTAssertEqual(result.cursorBefore, 2, "harness: the cursor stayed on row 2")
            XCTAssertEqual(result.acted, [2: key.after], "\(key.name) out of the built range")
        }
    }

    /// Condition 4: the same state, scrolled back. The trunk keeps the
    /// cursor on the row and draws its ring again, and the first ↓ after it
    /// goes on to the next row (lt-trunk.log, 24 Nov 20:2x, Air).
    func testAnOutOfRangeCursorRowScrolledBackAndTheFirstDownAfter() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        try clickRow(hosted, ids[0])
        hosted.press("\u{F701}", keyCode: 125)
        try scrollNow(hosted, toEnd: true)
        XCTAssertFalse(isBuilt(hosted, ids[1]), "harness: row 1 is still built after the scroll")
        try scrollNow(hosted, toEnd: false)
        XCTAssertTrue(isBuilt(hosted, ids[1]), "harness: row 1 is built again")
        let ring = hosted.pointer.drawnFocus.contains(TasksRowID(tab: .now, id: ids[1]))
        let cursor = hosted.model.keyboardFocus.map { ids.firstIndex(of: $0.id) ?? -1 }
        hosted.press("\u{F701}", keyCode: 125)
        let next = hosted.model.keyboardFocus.map { ids.firstIndex(of: $0.id) ?? -1 }
        print("OUT_OF_RANGE back ring=\(ring) cursor=\(cursor.map(String.init) ?? "nil") first_down=\(next.map(String.init) ?? "nil") selection=\(hosted.model.selection.map { ids.firstIndex(of: $0) ?? -1 }.sorted())")
        XCTAssertTrue(ring, "the row draws the keyboard's ring when it scrolls back")
        XCTAssertEqual(cursor, 1, "the cursor stays on the row while it is torn down")
        XCTAssertEqual(next, 2, "the first ↓ after goes on from the selected row")
        XCTAssertEqual(hosted.model.selection, [ids[2]], "the first ↓ selects the row it reaches")
    }
}

// MARK: - List-owned focus guards (list-owned-focus.md §5, Guards)

@MainActor
extension TasksRound13Tests {
    private func index(_ hosted: Hosted, _ ids: [UUID], _ id: UUID?) -> Int? {
        id.map { ids.firstIndex(of: $0) ?? -1 }
    }

    private func selected(_ hosted: Hosted, _ ids: [UUID]) -> [Int] {
        hosted.model.selection.map { ids.firstIndex(of: $0) ?? -1 }.sorted()
    }

    /// A press on a control inside a row, then ↓ (the trunk, Air tk-trunk.log
    /// 24 Nov 22:0x, `TK_CLICK first row=0`): row 0's subtask count is under
    /// the point `clickRow` presses, so the press opens its quick look and
    /// never reaches the row's own tap. The trunk's focusable row took the
    /// keyboard from that press: the cursor on row 0, nothing selected, and
    /// the next ↓ moves from it. The list keeps that: a press inside a row
    /// puts the cursor there. A click on a row's own part selects it.
    func testTheFirstDownAfterOneClickMovesTheCursor() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        XCTAssertFalse(hosted.model.expanded.contains(ids[0]), "harness: row 0's quick look is shut")
        try clickRow(hosted, ids[0])
        XCTAssertTrue(hosted.model.expanded.contains(ids[0]), "harness: the press landed on row 0's subtask count and opened its quick look")
        XCTAssertEqual(selected(hosted, ids), [], "a press on a control inside a row selects nothing")
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 0, "the cursor is on the row the press was in")
        XCTAssertTrue(keyboardIsInNowList(hosted), "the keyboard is in the Now list")
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 1, "the first ↓ moves from that row")
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertEqual(selected(hosted, ids), [2], "two ↓ after the press reach row 2")
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 2, "the cursor on row 2")
        // From a selected row, on a fresh page (row 0's quick look shut):
        // a click on a row's own part selects it and takes the cursor; the
        // press on row 0's control then moves the cursor and leaves the
        // selection (the trunk: `third-other row=0`).
        let second = try longHosted()
        defer { second.close() }
        let others = second.model.rows(for: .now).map(\.id)
        try clickRow(second, others[5])
        XCTAssertEqual(selected(second, others), [5], "a click on a row selects it")
        XCTAssertEqual(index(second, others, second.model.keyboardFocus?.id), 5, "and takes the cursor")
        try clickRow(second, others[0])
        XCTAssertEqual(selected(second, others), [5], "the press leaves the selection")
        XCTAssertEqual(index(second, others, second.model.keyboardFocus?.id), 0, "and moves the cursor to its row")
        // A second press at the same point lands in the quick look the
        // first one opened, below the row's own part: the cursor leaves the
        // row (the trunk: `second row=0 after cursor=nil selection=[]`).
        let third = try longHosted()
        defer { third.close() }
        let rows = third.model.rows(for: .now).map(\.id)
        try clickRow(third, rows[0])
        XCTAssertEqual(index(third, rows, third.model.keyboardFocus?.id), 0, "harness: the first press put the cursor on row 0")
        try clickRow(third, rows[0])
        print("LIST_FOCUS quicklook-press cursor=\(index(third, rows, third.model.keyboardFocus?.id).map(String.init) ?? "nil") "
              + "selection=\(selected(third, rows)) holds=\(TasksRowFocusLink.current?.holds(.now) ?? false) "
              + "responder=\(third.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        XCTAssertNil(third.model.keyboardFocus, "a press in the open quick look takes the cursor off the row")
        XCTAssertEqual(selected(third, rows), [], "and selects nothing")
    }

    /// A row key right after a press on a control inside the row: Space
    /// completes that row. Read from the trunk's source, not run there: the
    /// focused row answers its own keys (AtticTaskComponents.swift,
    /// `AtticListTaskFocusModifier`). A difference here goes to the lead
    /// (LOG 24 Nov 17:0x, e), not to a patch.
    func testSpaceAfterAPressOnARowsControlCompletesThatRow() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        try clickRow(hosted, ids[0])
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 0, "harness: the press put the cursor on row 0")
        let before = states(hosted, ids)
        print("LIST_FOCUS key-after-press before holds=\(TasksRowFocusLink.current?.holds(.now) ?? false) inList=\(keyboardIsInNowList(hosted))")
        hosted.press(" ", keyCode: 49)
        var waited = 0.0
        while waited < 3, states(hosted, ids) == before { hosted.spin(0.1); waited += 0.1 }
        hosted.spin(0.5)
        let after = states(hosted, ids)
        let acted = ids.enumerated().compactMap { offset, id in after[id] != before[id] ? "\(offset):\(after[id] ?? "?")" : nil }
        print("LIST_FOCUS key-after-press acted=\(acted) holds=\(TasksRowFocusLink.current?.holds(.now) ?? false)")
        XCTAssertEqual(acted, ["0:done"], "Space after a press on row 0's control completes row 0")
    }

    /// The lead's ruling (LOG 24 Nov 21:28): after a tab switch a row has
    /// the cursor exactly where the trunk has one. Four switches, each from
    /// ↓ on Now: one that saved a rename, one made while the panel was not
    /// key, a plain one, and one back to the tab that had the cursor. The
    /// trunk (Air tk-trunk.log 24 Nov 22:0x, `TK_SWITCH … after-switch`):
    /// no row has the cursor after any of them; the ↓ that follows reaches
    /// a row after the plain switch and the switch back, and none after
    /// the other two (the two §5.1 pins).
    func testNoRowHasTheCursorAfterATabSwitchAsOnTheTrunk() throws {
        try requireKeyWindowTests()
        func start() throws -> Hosted {
            let hosted = try Hosted(height: 520)
            hosted.spin(1.5)
            hosted.press("\u{F701}", keyCode: 125)
            XCTAssertEqual(hosted.model.keyboardFocus?.page, TasksTab.now.rawValue, "harness: ↓ on Now reaches a Now row")
            return hosted
        }
        func check(_ name: String, _ hosted: Hosted, tab: TasksTab, downReachesARow: Bool) {
            XCTAssertEqual(hosted.model.tab, tab, "harness: \(name): the switch landed")
            XCTAssertNil(hosted.model.keyboardFocus, "\(name): no row has the cursor after the switch")
            let holding = TasksRowFocusLink.current?.tabsHoldingFocus(besides: tab) ?? []
            print("LIST_FOCUS switch \(name) holding_besides=\(holding.map(\.rawValue)) holds=\(TasksRowFocusLink.current?.holds(tab) ?? false)")
            XCTAssertEqual(holding, [], "\(name): no list target of a tab that is not shown holds the keyboard")
            hosted.press("\u{F701}", keyCode: 125)
            XCTAssertEqual(hosted.model.keyboardFocus?.page, downReachesARow ? tab.rawValue : nil,
                           "\(name): the ↓ after the switch")
        }
        do {
            let hosted = try start()
            defer { hosted.close() }
            let row = try XCTUnwrap(hosted.model.keyboardFocus?.id)
            hosted.model.beginEditingTitle(row)
            hosted.spin(0.4)
            XCTAssertEqual(hosted.model.editingTitleID, row, "harness: the rename is open")
            hosted.go(to: .backlog)
            XCTAssertNil(hosted.model.editingTitleID, "harness: the switch saved the rename")
            check("a switch that saved a rename", hosted, tab: .backlog, downReachesARow: false)
        }
        do {
            let hosted = try start()
            defer { hosted.close() }
            let other = NSWindow(contentRect: CGRect(x: -3_000, y: -3_000, width: 80, height: 80),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            other.makeKeyAndOrderFront(nil)
            hosted.spin(0.2)
            XCTAssertFalse(hosted.window.isKeyWindow, "harness: another window is key")
            hosted.go(to: .backlog)
            hosted.window.makeKey()
            hosted.spin(0.3)
            check("a switch while the panel was not key", hosted, tab: .backlog, downReachesARow: false)
        }
        do {
            let hosted = try start()
            defer { hosted.close() }
            hosted.go(to: .backlog)
            check("a plain switch", hosted, tab: .backlog, downReachesARow: true)
        }
        do {
            let hosted = try start()
            defer { hosted.close() }
            hosted.go(to: .backlog)
            hosted.go(to: .now)
            check("a switch back to the tab that had the cursor", hosted, tab: .now, downReachesARow: true)
        }
    }

    /// Range selection: ⇧-click grows from the clicked row, and ⇧↓ then
    /// grows the same range from that anchor, the cursor on its far end.
    func testShiftClickAndShiftDownGrowFromAClickAnchor() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        try clickRow(hosted, ids[1])
        try clickRow(hosted, ids[3], modifiers: .shift)
        XCTAssertEqual(selected(hosted, ids), [1, 2, 3], "⇧-click grows from the clicked row")
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 3, "the cursor on the ⇧-clicked row")
        hosted.press("\u{F701}", keyCode: 125, modifiers: .shift)
        XCTAssertEqual(selected(hosted, ids), [1, 2, 3, 4], "⇧↓ grows the range from the click anchor")
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 4, "the cursor on the range's far end")
        XCTAssertTrue(hosted.pointer.drawnFocus.contains(TasksRowID(tab: .now, id: ids[4])), "the ring on the cursor row")
        XCTAssertTrue(keyboardIsInNowList(hosted), "the keyboard stays in the Now list")
    }

    /// Lazy-row reveal: ↓ onto a row the lazy list has not built yet brings
    /// it into view, with the cursor and the selection on it.
    func testDownOntoARowTheLazyListHasNotBuiltRevealsIt() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        // Row 1, whose press selects it. A press at row 0's point lands on
        // a control and opens its quick look, and with that open neither
        // the trunk nor this list scrolls on ↓ (Air, 25 Nov, tk6-trunk.log
        // and tk6-head.log: the same frames to ↓ 6, no row built after).
        try clickRow(hosted, ids[1])
        XCTAssertTrue(hosted.model.expanded.isEmpty, "harness: no quick look open")
        var unbuiltReached = 0
        for step in 2...31 {
            let wasBuilt = isBuilt(hosted, ids[step])
            hosted.press("\u{F701}", keyCode: 125)
            hosted.spin(0.2)
            XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), step, "↓ \(step): the cursor")
            XCTAssertEqual(selected(hosted, ids), [step], "↓ \(step): the selection")
            XCTAssertTrue(isBuilt(hosted, ids[step]), "↓ \(step): the row is built")
            if let frame = hosted.pointer.frame(for: TasksRowID(tab: .now, id: ids[step])), let view = hosted.pointer.view {
                let inWindow = view.convert(frame, to: nil)
                XCTAssertTrue(inWindow.minY >= 0 && inWindow.maxY <= hosted.height, "↓ \(step): the row is in view (\(inWindow))")
            }
            if !wasBuilt { unbuiltReached += 1 }
        }
        print("LIST_FOCUS lazy_reveal unbuilt_reached=\(unbuiltReached)")
        XCTAssertGreaterThan(unbuiltReached, 0, "harness: ↓ reached at least one row the list had not built")
    }

    /// Deletion succession: Delete on the cursor row moves the cursor and
    /// the selection to the row that took its place, once the row is gone
    /// from the store.
    func testDeleteMovesTheCursorToTheRowThatTookItsPlaceAfterTheSave() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        try clickRow(hosted, ids[0])
        hosted.press("\u{F701}", keyCode: 125)
        XCTAssertEqual(index(hosted, ids, hosted.model.keyboardFocus?.id), 1, "harness: the cursor on row 1")
        hosted.press("\u{7F}", keyCode: 51)
        var waited = 0.0
        while waited < 3, hosted.store.task(withID: ids[1]) != nil { hosted.spin(0.1); waited += 0.1 }
        hosted.spin(0.4)
        XCTAssertNil(hosted.store.task(withID: ids[1]), "Delete deleted row 1")
        XCTAssertEqual(hosted.model.keyboardFocus?.id, ids[2], "the cursor went to the row that took its place")
        XCTAssertEqual(hosted.model.selection, [ids[2]], "the selection went with it")
        XCTAssertTrue(keyboardIsInNowList(hosted), "the keyboard stays in the Now list")
        XCTAssertNotNil(hosted.store.task(withID: ids[2]), "the survivor is kept")
    }

    /// Dispatch isolation: while a row's title is edited, Space and Delete
    /// are the editor's, never the row's (the list answers row keys only
    /// when its own target holds the keyboard).
    func testTheTitleEditorKeepsSpaceAndDelete() throws {
        try requireKeyWindowTests()
        let hosted = try longHosted()
        defer { hosted.close() }
        let ids = hosted.model.rows(for: .now).map(\.id)
        try clickRow(hosted, ids[1])
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, ids[1], "harness: Return edits row 1's title")
        let before = states(hosted, ids)
        hosted.press(" ", keyCode: 49)
        hosted.press("\u{7F}", keyCode: 51)
        hosted.spin(0.5)
        XCTAssertEqual(states(hosted, ids), before, "Space and Delete in the title editor act on no row")
        XCTAssertEqual(hosted.model.editingTitleID, ids[1], "the editor stays open")
    }
}
