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
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let (_, subtask) = try tabToASubtask(hosted)
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.renamingSubtaskID, subtask, "Return renames the subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and not the parent's title")
    }

    func testDeleteStillDeletesATabFocusedSubtask() throws {
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
                          step: TimeInterval = 0.25) {
        func post(_ characters: String, _ keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
            }
        }
        var when = start
        for key in keys {
            let timer = Timer(timeInterval: when, repeats: false) { _ in MainActor.assumeIsolated { post(key.characters, key.keyCode) } }
            RunLoop.main.add(timer, forMode: .common)
            when += step
        }
        let escape = Timer(timeInterval: when + 2.5, repeats: false) { _ in MainActor.assumeIsolated { post("\u{1B}", 53) } }
        RunLoop.main.add(escape, forMode: .common)
    }

    /// The row selected and focused, ⇧⌘I pressed for real (a native menu
    /// pops up), `keys` typed into the menu, and the run spun until it closed.
    private func openActionsMenu(_ hosted: Hosted, on title: String, keys: [(characters: String, keyCode: UInt16)]) throws -> UUID {
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == title }?.id)
        try hosted.clickRow(row, tab: .now)
        XCTAssertEqual(model.selection, [row])
        schedule(keys, in: hosted)
        hosted.press("i", keyCode: 34, modifiers: [.command, .shift])
        hosted.spin(1.5)
        return row
    }

    func testReturnInTheActionsMenuActivatesTheHighlightedItemNotEditTitle() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try openActionsMenu(hosted, on: "Ship appearance PR", keys: [("\u{F701}", 125), ("\u{F701}", 125), ("\r", 36)])
        // Complete, then Start Working: the second item is highlighted.
        XCTAssertNil(hosted.model.editingTitleID, "Return did not start Edit Title")
        XCTAssertEqual(hosted.store.task(withID: row)?.status, .inProgress, "Return started work on the highlighted Start Working")
    }

    func testReturnOnAddSubtaskInTheActionsMenuOpensTheSubtaskEditor() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let row = try openActionsMenu(hosted, on: "Call the plumber", keys: Array(repeating: down, count: 8) + [("\r", 36)])
        XCTAssertEqual(hosted.model.newSubtaskParentID, row, "Return ran Add Subtask")
        XCTAssertNil(hosted.model.editingTitleID, "and did not edit the parent's title")
    }

    /// A pop-up menu shows a bare key's shortcut (Return beside Edit Title)
    /// but never answers it as a key equivalent; ⌘ shortcuts still work.
    func testPopUpMenusShowBareShortcutsButAnswerOnlyModifiedOnes() {
        var ran: [String] = []
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Edit Title", shortcut: AtticTaskShortcut.editTitle) { ran.append("edit") },
            AtticMenuCommand(verbatim: "Later", shortcut: AtticTaskShortcut.later) { ran.append("later") }
        ])
        XCTAssertEqual(menu.items.first?.keyEquivalent, "\r", "the hint is shown")
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }
        XCTAssertFalse(menu.performKeyEquivalent(with: key("\r", 36, [])))
        XCTAssertEqual(ran, [], "Return does not run Edit Title")
        XCTAssertTrue(menu.performKeyEquivalent(with: key("b", 11, .command)))
        XCTAssertEqual(ran, ["later"], "⌘B still runs Later")
    }

    // MARK: - Bug 1: ⌘Z after a task-menu change

    private func priority(of id: UUID, _ hosted: Hosted) -> TaskPriority? {
        hosted.store.listedTask(withID: id)?.priority
    }

    /// The composer holds a draft and the keyboard; a task's priority is
    /// changed from its menu (the model call the menu makes). Real ⌘Z
    /// undoes that change and keeps the draft; ⌘Z again is the draft's own
    /// typing undo; typing after a menu change gives ⌘Z back to the field.
    func testCommandZAfterATaskMenuChangeUndoesTheChangeAndKeepsTheDraft() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        let original = try XCTUnwrap(priority(of: row.id, hosted))
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
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        hosted.press("a", keyCode: 0)
        model.setPriority(.high, for: [row.id])
        hosted.spin(0.3)
        hosted.press("b", keyCode: 11)
        XCTAssertEqual(model.addBar.text, "ab")
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertEqual(priority(of: row.id, hosted), .high, "typing came after the change: ⌘Z is text Undo")
        XCTAssertNotEqual(model.addBar.text, "ab")
    }

    func testRedoBringsBackATaskMenuChangeAfterAClaimedUndo() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let row = try XCTUnwrap(model.rows(for: .now).first { hosted.store.listedTask(withID: $0.id)?.priority != .high })
        hosted.press("a", keyCode: 0)
        model.setPriority(.high, for: [row.id])
        hosted.spin(0.3)
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertNotEqual(priority(of: row.id, hosted), .high)
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
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        let model = hosted.model
        let rows = model.rows(for: .now)
        // Two neighbours in one group (started and not started stay apart).
        let at = try XCTUnwrap(rows.indices.dropLast().first { rows[$0].status == rows[$0 + 1].status && rows[$0].status != .done })
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

    // MARK: - Item 5: no edge ghosts

    /// A row scrolled past the tabs or toward the add bar is cut at the
    /// fixed band, not left half-faded in a long ramp (the review's "faint
    /// title fragments"): the partly-transparent stretch of the list's mask
    /// is no longer than the edge softening, at either edge, for every
    /// bottom stack, and the resting rows keep full opacity.
    func testTheListsMaskCutsRowsCleanlyAtTheFixedBands() {
        for stack in [CGFloat(36), 60, 96, 136] {
            let height: CGFloat = 520
            let stops = TasksViewport.maskStops(height: height, tabsTop: 80, listTop: 110, bottomStack: stack)
            func opacity(_ y: CGFloat) -> Double {
                let x = y / height
                for (a, b) in zip(stops, stops.dropFirst()) where x <= b.location {
                    let t = Double((x - a.location) / max(b.location - a.location, 0.000001))
                    return a.opacity + (b.opacity - a.opacity) * min(max(t, 0), 1)
                }
                return stops.last?.opacity ?? 1
            }
            let partial = stride(from: CGFloat(0), through: height, by: 0.5).filter { (0.02...0.98).contains(opacity($0)) }
            let top = partial.filter { $0 < height / 2 }, bottom = partial.filter { $0 >= height / 2 }
            XCTAssertLessThanOrEqual((top.last ?? 0) - (top.first ?? 0), TasksViewport.softEdge + 0.5, "top ramp, stack \(stack)")
            XCTAssertLessThanOrEqual((bottom.last ?? 0) - (bottom.first ?? 0), TasksViewport.softEdge + 0.5, "bottom ramp, stack \(stack)")
            XCTAssertEqual(opacity(110), 1, accuracy: 0.001, "the resting row is whole")
            XCTAssertEqual(opacity(height - stack - 18), 1, accuracy: 0.001, "and so is the row above the bar")
            XCTAssertEqual(opacity(height - stack), 0, accuracy: 0.001, "nothing under the bar")
            XCTAssertEqual(opacity(100), 0, accuracy: 0.05, "nothing just under the tabs' band")
        }
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
