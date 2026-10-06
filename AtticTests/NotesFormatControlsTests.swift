import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Attic

/// Slice 3a UI: the selection bar, Aa, the `/` list with its date and file
/// flows, the link card, the menus and the keys all run the engine's one
/// command layer through `NoteCommandRouter`.
@MainActor
final class NotesFormatControlsTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var controlsList: [NoteFormatControls] = []
    private var defaultsSuite: String?

    override func setUp() async throws {
        let suite = "NotesFormatControlsTests.\(UUID().uuidString)"
        defaultsSuite = suite
    }

    override func tearDown() async throws {
        controlsList.forEach { $0.invalidate() }
        controlsList.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
    }

    private static let sample = NoteDocument(blocks: [
        .text("Pricing page"),
        .text("Lead with the free tier: most people only need the panel."),
        .text("Before launch"),
        .text("Annual plan"),
        .text("Student pricing")
    ])

    private func make(_ document: NoteDocument = sample, readOnly: Bool = false, topInset: CGFloat = 0,
                      isNewDraft: Bool = false) -> (NoteFormatControls, NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document, readOnly: readOnly)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        let controls = NoteFormatControls(engine: engine, textView: textView, scrollView: scrollView, design: .default,
                                          noteID: engine.noteID, isNewDraft: isNewDraft)
        controlsList.append(controls)
        scrollView.layoutSubtreeIfNeeded()
        return (controls, engine, textView)
    }

    private func range(_ text: String, _ textView: NSTextView) -> NSRange {
        (textView.string as NSString).range(of: text)
    }

    private func type(_ text: String, _ textView: NoteEditorTextView) {
        for character in text {
            if character == "\n" { textView.insertNewline(nil) } else {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// Runs the loop until `condition` holds (a second at most): SwiftUI
    /// builds a card's field over a few turns.
    private func settle(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { spin() }
    }

    private func marks(_ engine: NoteEditorEngine, block: Int) -> [NoteMark.Kind] {
        engine.document().blocks[block].marks.map(\.kind)
    }

    private func keyEvent(_ characters: String, _ ignoring: String, keyCode: UInt16,
                          _ flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
    }

    private func invoke(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("missing menu item") }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func find(_ title: String, in commands: [AtticMenuCommand]) -> AtticMenuCommand? {
        for command in commands {
            if command.title == title { return command }
            if let found = find(title, in: command.children) { return found }
        }
        return nil
    }

    // MARK: Routing: every surface runs the same engine command

    func testEverySurfaceRunsTheSameBoldCommandWithTheSameResult() throws {
        var results: [NoteCommandSurface: [NoteMark.Kind]] = [:]
        var routes: [NoteCommandSurface: NoteFormatCommand] = [:]
        for surface: NoteCommandSurface in [.selectionBar, .formatBar, .noteMenu, .contextMenu, .menuBar, .shortcut] {
            let (controls, engine, textView) = make()
            controls.router.onRun = { command, from in routes[from] = command }
            let target = range("most people", textView)
            textView.setSelectedRange(target)
            switch surface {
            case .selectionBar, .formatBar:
                controls.formatModel.run(.mark(.bold), from: surface)
            case .noteMenu:
                find("Bold", in: controls.router.menuCommands(from: .noteMenu))?.action()
            case .contextMenu:
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 60, y: 450), modifierFlags: [],
                                               timestamp: 0, windowNumber: textView.window!.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!
                let menu = try XCTUnwrap(textView.menu(for: event))
                textView.setSelectedRange(target)
                let format = menu.items.first { $0.title == "Format" }?.submenu
                XCTAssertNotNil(menu.items.first { $0.title == "Insert" }, "right-click has Insert")
                invoke(format?.items.first { $0.title == "Bold" })
            case .menuBar:
                let items = NoteFormatMenuBar.items(for: NSMenu(title: "Format"), controls: controls)
                invoke(items.first { $0.title == "Bold" })
            case .shortcut:
                let event = keyEvent("b", "b", keyCode: 11, .command, window: textView.window!)
                XCTAssertTrue(controls.handleKey(event), "⌘B is the note's")
            default: break
            }
            results[surface] = marks(engine, block: 1)
            XCTAssertEqual(routes[surface], .mark(.bold), "\(surface) ran Bold")
            XCTAssertEqual(engine.history.undoActionName, "Bold", "\(surface): one engine history step")
        }
        XCTAssertEqual(Set(results.values.map { $0 }), [[.bold]], "every surface made the same change: \(results)")
    }

    func testMenusListEveryCommandWithShortcutsAndChecks() throws {
        let (controls, _, textView) = make()
        textView.setSelectedRange(NSRange(location: range("Annual plan", textView).location, length: 0))
        controls.router.run(.paragraph(.bullet), from: .shortcut)
        let menu = controls.router.menuCommands(from: .noteMenu)
        XCTAssertEqual(menu.map(\.title), ["Insert", "Format"])
        XCTAssertEqual(menu[0].children.map(\.title), ["Image or File…", "Date…", "Divider"])
        let format = menu[1].children
        for command in NoteCommandCatalog.formatSections.flatMap({ $0 }) {
            XCTAssertNotNil(format.first { $0.title == NoteCommandCatalog.menuTitle(command) }, "Format lists \(command)")
        }
        XCTAssertEqual(find("Bulleted List", in: menu)?.state, .on, "the current list is checked")
        XCTAssertEqual(find("Bold", in: menu)?.shortcut, KeyboardShortcut("b", modifiers: .command))
        XCTAssertEqual(find("Checklist", in: menu)?.shortcut, KeyboardShortcut("9", modifiers: [.command, .shift]))
        XCTAssertEqual(find("Check or Uncheck", in: menu)?.shortcut, KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(find("Move Line Up", in: menu)?.shortcut, KeyboardShortcut(.upArrow, modifiers: [.command, .option]))
        XCTAssertEqual(find("Quote", in: menu)?.shortcut, KeyboardShortcut("4", modifiers: [.command, .option]))
        XCTAssertEqual(find("Mono", in: menu)?.shortcut, KeyboardShortcut("5", modifiers: [.command, .option]))
    }

    func testTheMenuBarNeverAnswersKeysAndIsDimmedWithoutANote() {
        let bar = NoteFormatMenuBar.items(for: NSMenu(title: "Format"), controls: nil)
        XCTAssertFalse(bar.isEmpty)
        XCTAssertTrue(bar.allSatisfy { !$0.isEnabled })
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        NoteFormatMenuBar.install(in: main)
        NoteFormatMenuBar.install(in: main)
        XCTAssertEqual(main.items.map(\.title), ["Edit", "Insert", "Format"], "installed once, after Edit")
        let format = main.items[2].submenu!
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        var target: AnyObject?
        var action: Selector?
        XCTAssertFalse(format.delegate!.menuHasKeyEquivalent!(format, for: event, target: &target, action: &action))
    }

    func testShortcutsDecodeShiftedDigitsAndSkipReservedChords() throws {
        let (_, _, textView) = make()
        let window = textView.window!
        // ⇧⌘7 on a US layout: the characters carry Shift ("&").
        let bullet = keyEvent("&", "&", keyCode: 26, [.command, .shift], window: window)
        XCTAssertEqual(NoteCommandCatalog.command(for: bullet), .paragraph(.bullet))
        let checklist = keyEvent("(", "(", keyCode: 25, [.command, .shift], window: window)
        XCTAssertEqual(NoteCommandCatalog.command(for: checklist), .paragraph(.checklist))
        let quit = keyEvent("œ", "q", keyCode: 12, [.command, .option], window: window)
        XCTAssertNil(NoteCommandCatalog.command(for: quit), "⌥⌘Q stays the system's")
        let tick = keyEvent("\r", "\r", keyCode: 36, .command, window: window)
        XCTAssertEqual(NoteCommandCatalog.command(for: tick), .toggleChecklist)
        XCTAssertEqual(NoteCommandCatalog.parseShortcut("⌥⌘↓"), KeyboardShortcut(.downArrow, modifiers: [.command, .option]))
        XCTAssertNil(NoteCommandCatalog.command(for: keyEvent("l", "l", keyCode: 37, [.command, .shift], window: window)),
                     "⇧⌘L stays All notes")
    }

    // MARK: Selection bar

    func testTheBarShowsForASelectionWithItsStatesAndHidesWithoutOne() throws {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(range("most people", textView))
        controls.router.run(.mark(.bold), from: .shortcut)
        textView.setSelectedRange(range("people only", textView))
        controls.refresh()
        XCTAssertTrue(controls.formatModel.barShown, "a selection shows the bar")
        XCTAssertEqual(controls.formatModel.snapshot.value(.mark(.bold)), .mixed, "half bold is mixed")
        XCTAssertEqual(controls.formatModel.snapshot.paragraph, .body)
        textView.setSelectedRange(range("most", textView))
        controls.refresh()
        XCTAssertEqual(controls.formatModel.snapshot.value(.mark(.bold)), .on)
        XCTAssertEqual(controls.formatModel.snapshot.value(.mark(.italic)), .off)
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        controls.refresh()
        XCTAssertFalse(controls.formatModel.barShown, "nothing on screen without a selection")
        XCTAssertEqual(engine.document().blocks[1].marks.first?.kind, .bold)
    }

    func testTheBarStaysAboveTheSelectionAndGoesBelowWithoutRoom() throws {
        let (controls, engine, textView) = make()
        let target = range("Student pricing", textView)
        textView.setSelectedRange(target)
        controls.refresh()
        let selection = try XCTUnwrap(engine.rect(for: target))
        XCTAssertLessThanOrEqual(controls.barFrame.maxY, selection.minY, "above, never over the selection")
        XCTAssertEqual(controls.formatModel.barBelow, false)
        XCTAssertLessThanOrEqual(controls.barFrame.width, 320 - 2 * AtticNoteFormatMetrics.barEdgeMargin, "fits a 320 pt panel")
        XCTAssertGreaterThanOrEqual(controls.barFrame.width, NoteFormatControls.barWidth(styleName: "Body"))

        let (top, topEngine, topView) = make(topInset: 60)
        let first = range("Pricing", topView)
        topView.setSelectedRange(first)
        top.refresh()
        let rect = try XCTUnwrap(topEngine.rect(for: first))
        XCTAssertTrue(top.formatModel.barBelow, "no room under the header (the title's line): below")
        XCTAssertGreaterThanOrEqual(top.barFrame.minY, rect.maxY)
        XCTAssertLessThanOrEqual(top.barFrame.maxX, topView.bounds.width, "inside the panel")
        XCTAssertGreaterThanOrEqual(top.barFrame.minX, 0)
    }

    func testEscHidesTheBarUntilTheSelectionChangesAndReadOnlyShowsNone() {
        let (controls, _, textView) = make()
        textView.setSelectedRange(range("most people", textView))
        controls.refresh()
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        controls.refresh()
        XCTAssertFalse(controls.formatModel.barShown)
        textView.setSelectedRange(range("the panel", textView))
        spin()
        XCTAssertTrue(controls.formatModel.barShown, "a new selection brings it back")

        let (readOnly, _, readOnlyView) = make(readOnly: true)
        readOnlyView.setSelectedRange(range("most people", readOnlyView))
        readOnly.refresh()
        XCTAssertFalse(readOnly.formatModel.barShown, "read only: nothing to offer")
    }

    func testControlTabWalksTheBarAndReturnPresses() throws {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(range("most people", textView))
        controls.refresh()
        let window = textView.window!
        XCTAssertTrue(controls.handleKey(keyEvent("\t", "\t", keyCode: 48, .control, window: window)))
        XCTAssertEqual(controls.formatModel.barKeyboardIndex, 0, "⌃Tab reaches the bar's style control")
        XCTAssertTrue(controls.handleKey(keyEvent("", "", keyCode: 124, [], window: window)))
        XCTAssertEqual(controls.formatModel.barKeyboardIndex, 1)
        XCTAssertTrue(controls.handleKey(keyEvent("\r", "\r", keyCode: 36, [], window: window)))
        XCTAssertEqual(marks(engine, block: 1), [.bold], "Return pressed Bold")
        XCTAssertTrue(controls.handleKey(keyEvent("\u{1b}", "\u{1b}", keyCode: 53, [], window: window)))
        XCTAssertNil(controls.formatModel.barKeyboardIndex, "Esc goes back to the text")
        XCTAssertTrue(window.firstResponder === textView, "the text never lost the keyboard")

        // OD-7: without a bar, ⌃Tab and ⌃⇧Tab leave the text for the
        // page's next and previous control; Aa stays on ⌘T.
        var opened: Bool?
        var left: [Bool] = []
        controls.requestFormatBar = { opened = $0 }
        controls.leaveEditor = { left.append($0) }
        textView.setSelectedRange(NSRange(location: 20, length: 0))
        controls.refresh()
        XCTAssertTrue(controls.handleKey(keyEvent("\t", "\t", keyCode: 48, .control, window: window)))
        XCTAssertTrue(controls.handleKey(keyEvent("\u{19}", "\u{19}", keyCode: 48, [.control, .shift], window: window)))
        XCTAssertEqual(left, [true, false], "⌃Tab leaves forward, ⌃⇧Tab backward")
        XCTAssertNil(opened, "⌃Tab no longer opens Aa")
    }

    /// OD-7: Tab in the title moves to the start of the body (making the
    /// body's first line when there is none); in the body it indents.
    func testTabInTheTitleMovesToTheBodyAndIndentsInTheBody() throws {
        let (_, engine, textView) = make()
        let title = engine.titleParagraphRange
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(title) + 1, length: 0), "Tab in the title: the body's start")
        XCTAssertEqual(engine.titleParagraphRange, title, "nothing typed into the title")
        XCTAssertFalse(textView.string.prefix(NSMaxRange(title)).contains("\t"))

        XCTAssertFalse(engine.moveFromTitleToBody(), "in the body Tab is not navigation (it indents)")

        let (_, empty, emptyView) = make(NoteDocument(blocks: [.text("Only a title")]))
        emptyView.setSelectedRange(NSRange(location: 4, length: 0))
        emptyView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(emptyView.selectedRange().location, empty.titleParagraphRange.length + 1, "a body line to type in")
        XCTAssertEqual(empty.lineText(at: 0), "Only a title")
    }

    func testNotesKeyboardOrderGoesRoundTheBottomRowAndBackIntoTheText() {
        let stops = NotesKeyboardOrder.stops(format: true)
        XCTAssertEqual(stops, [.text, .allNotes, .format, .newNote])
        XCTAssertEqual(NotesKeyboardOrder.next(after: .text, in: stops, forward: true), .allNotes, "⌃Tab: the next control")
        XCTAssertEqual(NotesKeyboardOrder.next(after: .text, in: stops, forward: false), .newNote, "⌃⇧Tab: the previous one")
        XCTAssertEqual(NotesKeyboardOrder.next(after: .newNote, in: stops, forward: true), .text, "round again into the text")
        XCTAssertEqual(NotesKeyboardOrder.next(after: .allNotes, in: stops, forward: false), .text)
        XCTAssertEqual(NotesKeyboardOrder.stops(format: false), [.text, .allNotes, .newNote], "a read-only note has no Aa")
    }

    func testListsToggleBackToBodyAndAaWorksOnTheCaretParagraph() {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(NSRange(location: range("Annual", textView).location + 2, length: 0))
        controls.formatModel.run(.paragraph(.bullet), from: .formatBar)
        XCTAssertEqual(engine.document().blocks[3].style, "bullet")
        controls.refreshSnapshot()
        XCTAssertEqual(controls.formatModel.snapshot.value(.paragraph(.bullet)), .on)
        XCTAssertEqual(controls.formatModel.snapshot.paragraph, .bullet, "the bar's style control says List")
        controls.formatModel.run(.paragraph(.bullet), from: .selectionBar)
        XCTAssertNil(engine.document().blocks[3].style, "choosing an on list returns it to Body")
        controls.formatModel.run(.paragraph(.heading(2)), from: .formatBar)
        XCTAssertEqual(engine.document().blocks[3].style, "heading")
        controls.refreshSnapshot()
        XCTAssertEqual(controls.formatModel.snapshot.paragraph, .heading(2))
    }

    func testTheTitleAndReadOnlyExplainWhyStylesAreDimmed() {
        let (controls, _, textView) = make()
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        controls.refreshSnapshot()
        XCTAssertFalse(controls.formatModel.snapshot.isEnabled(.paragraph(.heading(2))))
        XCTAssertNotNil(controls.formatModel.snapshot.disabledReason)
        let (readOnly, _, _) = make(readOnly: true)
        readOnly.refreshSnapshot()
        XCTAssertEqual(readOnly.formatModel.snapshot.disabledReason, "This note is read only.")
        XCTAssertFalse(readOnly.formatModel.snapshot.hasEnabledCommand)
    }

    func testTypingWithNothingShownReadsNoState() {
        let (controls, _, textView) = make()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        spin()
        let before = controls.snapshotCount
        type(" and more words typed quickly", textView)
        spin()
        XCTAssertEqual(controls.snapshotCount, before, "no state read, no bar work per keystroke")
    }

    /// OD-14: the format row holds the style, the four list types, outdent
    /// and indent, and ✕, round in that order; the selection bar keeps the
    /// marks (decision D), inline code included, and no list.
    func testTheFormatRowAndTheSelectionBarHoldWhatTheDraftShows() {
        XCTAssertEqual(NoteFormatRowItem.all, [.style, .command(.paragraph(.bullet)), .command(.paragraph(.number)),
                                               .command(.paragraph(.checklist)), .command(.paragraph(.quote)),
                                               .command(.outdent), .command(.indent), .close])
        XCTAssertEqual(NoteFormatRowItem.step(7, forward: true), 0, "round again from ✕ to the style")
        XCTAssertEqual(NoteFormatRowItem.step(0, forward: false), 7)
        XCTAssertEqual(NoteFormatBarItem.all, [.style, .command(.mark(.bold)), .command(.mark(.italic)),
                                               .command(.mark(.underline)), .command(.mark(.strikethrough)),
                                               .command(.mark(.link)), .command(.mark(.highlight)), .command(.mark(.code))])
        XCTAssertLessThanOrEqual(NoteFormatControls.barWidth(styleName: "Subheading"), 320 - 8, "the bar fits the panel")
        XCTAssertLessThanOrEqual(NoteFormatRowView.minimumWidth(snapshot: .empty, toggleWidth: AtticNoteFormatMetrics.rowToggleWidth),
                                 288, "the row fits a 320 pt panel's bottom row with 28 pt cells")
    }

    // MARK: The / list

    func testSlashListKeysMoveAndPickAndEscLeavesTheText() throws {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\n/", textView)
        XCTAssertTrue(controls.slashModel.shown)
        XCTAssertEqual(controls.slashModel.items.first?.kind, .checklist, "most used first")
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(controls.slashModel.highlightedKind, .heading)
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(controls.slashModel.highlighted, controls.slashModel.items.count - 1, "↑ wraps")
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controls.slashModel.shown)
        XCTAssertTrue(textView.string.hasSuffix("\n/"), "Esc leaves the typed /")

        type(" /hea", textView)
        XCTAssertEqual(controls.slashModel.items.map(\.kind), [.heading], "the engine filters")
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.insertTab(_:))), "Tab picks")
        let last = try XCTUnwrap(engine.document().blocks.last)
        XCTAssertEqual(last.style, "heading")
        XCTAssertEqual(last.text, "/ ", "the command is replaced")
        XCTAssertFalse(controls.slashModel.shown)

        type("\n/", textView)
        type(" ", textView)
        XCTAssertFalse(controls.slashModel.shown, "Space closes the list")
    }

    func testFullSlashListFlipsAboveALowCaretAndOpensBelowAHighCaret() throws {
        // Real editor + controls: this catches the old Notes-only placement
        // path, which truncated rows before trying the full list above.
        let (lowControls, lowEngine, lowText) = make(NoteDocument(blocks: [.text("Title")] + (0..<14).map { _ in .text("Line") }))
        lowText.setSelectedRange(NSRange(location: lowEngine.textStorage.length, length: 0))
        type("\n/", lowText)
        XCTAssertTrue(lowControls.slashModel.shown)
        XCTAssertTrue(lowControls.slashModel.above)
        XCTAssertNil(lowControls.slashModel.viewportHeight, "all nine rows fit above the low caret")

        let (highControls, highEngine, highText) = make(NoteDocument(blocks: [.text("Title"), .text("")]))
        highText.setSelectedRange(NSRange(location: highEngine.textStorage.length, length: 0))
        type("/", highText)
        XCTAssertTrue(highControls.slashModel.shown)
        XCTAssertFalse(highControls.slashModel.above)
        XCTAssertNil(highControls.slashModel.viewportHeight, "all nine rows fit below the high caret")
    }

    /// P3-B3: the `/` list keeps its side while typing filters it; a list
    /// that opens anew takes its side afresh.
    func testTheSlashListKeepsItsSideWhileFiltering() throws {
        let (controls, engine, textView) = make(NoteDocument(blocks: [.text("Title")] + (0..<12).map { _ in .text("Line") }))
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("\n/", textView)
        XCTAssertTrue(controls.slashModel.shown)
        XCTAssertTrue(controls.slashModel.above, "the full list opens above the low caret")
        let slash = try XCTUnwrap(engine.rect(for: NSRange(location: engine.textStorage.length - 1, length: 1)))
        let d = AtticDropdownMetrics.self
        let below = textView.visibleRect.maxY - d.panelMargin - (slash.maxY + d.anchorGap)
        XCTAssertGreaterThanOrEqual(below, d.rowHeight + d.inset * 2, "one row would fit below the caret")
        type("hea", textView)
        XCTAssertEqual(controls.slashModel.items.map(\.kind), [.heading], "the engine filters")
        XCTAssertTrue(controls.slashModel.above, "the filtered list keeps its side")
        XCTAssertNil(controls.slashModel.viewportHeight)
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controls.slashModel.shown)
        // A new list high in the note opens below its caret.
        textView.setSelectedRange(NSRange(location: ("Title\nLine" as NSString).length, length: 0))
        type("\n/", textView)
        XCTAssertTrue(controls.slashModel.shown)
        XCTAssertFalse(controls.slashModel.above, "a list that opens anew takes its side afresh")
    }

    /// P3-B4: the title's tag suggestions follow their `#` as the note
    /// scrolls (they lived in the text view before the overlay), and wait
    /// out of sight while the `#` is scrolled under the header.
    func testTitleTagSuggestionsFollowTheHashtagAsTheNoteScrolls() throws {
        let title = "Launch plan "
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text(title)] + (0..<40).map { _ in .text("Line") }),
                                      readOnly: false)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        scrollView.automaticallyAdjustsContentInsets = false
        let header: CGFloat = 60
        scrollView.contentInsets = NSEdgeInsets(top: header, left: 0, bottom: 0, right: 0)
        // Room above the title, so the note can scroll a little with the
        // title still in view.
        textView.textContainerInset = NSSize(width: 28, height: 100)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        let accessories = NoteTitleAccessories(engine: engine, textView: textView, scrollView: scrollView, chrome: NotesPageChrome(),
                                               design: .default, headerBottom: header, isUntouched: { false },
                                               tagEditor: { AnyView(EmptyView()) })
        defer { accessories.invalidate() }
        accessories.tagCounts = { ["launch": 3, "landing": 1] }
        // The card moves in the scroll's own pass: no run-loop turn (where
        // a layout pass might re-place it) between the scroll and the checks.
        func scroll(to y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollView.layoutSubtreeIfNeeded()
        scroll(to: -header)
        spin()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (title as NSString).length, length: 0))
        type("#la", textView)
        func hosts(_ view: NSView) -> [AtticOverlayHostingView] {
            ((view as? AtticOverlayHostingView).map { [$0] } ?? []) + view.subviews.flatMap { hosts($0) }
        }
        let overlayParent = try XCTUnwrap(scrollView.superview)
        settle { hosts(overlayParent).contains { $0.menuLabel == "Tag suggestions" && !$0.isHidden } }
        let host = try XCTUnwrap(hosts(overlayParent).first { $0.menuLabel == "Tag suggestions" })
        XCTAssertFalse(host.isHidden, "the suggestions show")
        let hash = try XCTUnwrap(engine.rect(for: NSRange(location: (title as NSString).length, length: 1)))
        /// The card's top, against the `#`'s bottom, in the text's terms.
        func gap() -> CGFloat { textView.convert(host.contentRect, from: host).minY - hash.maxY }
        XCTAssertEqual(gap(), AtticDropdownMetrics.anchorGap, accuracy: 1, "the card hangs from the #")
        let before = host.frame
        scroll(to: -header + 40)
        XCTAssertFalse(host.isHidden)
        XCTAssertEqual(host.frame.minX, before.minX)
        XCTAssertNotEqual(host.frame, before, "the card moved with the note")
        XCTAssertEqual(gap(), AtticDropdownMetrics.anchorGap, accuracy: 1, "and still hangs from the #")
        scroll(to: 200)
        XCTAssertTrue(host.isHidden, "the # is under the header: the card waits out of sight")
        scroll(to: -header)
        XCTAssertFalse(host.isHidden, "the # is back")
        XCTAssertEqual(gap(), AtticDropdownMetrics.anchorGap, accuracy: 1)
        XCTAssertEqual(host.frame, before)
    }

    func testSlashRowsShowTheirTypingShortcuts() {
        XCTAssertEqual(NoteCommandCatalog.slashHint(.checklist), "-[]")
        XCTAssertEqual(NoteCommandCatalog.slashHint(.heading), "#")
        XCTAssertEqual(NoteCommandCatalog.slashHint(.number), "1.")
        XCTAssertNil(NoteCommandCatalog.slashHint(.mono), "no reserved chord shown")
    }

    func testSlashDateTypedDayInsertsAChipAndEscRestoresTheCommand() throws {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\nCall Sam /da", textView)
        XCTAssertEqual(controls.slashModel.items.map(\.kind), [.date])
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(controls.cardModel.card, .date(fromSlash: true))
        settle { controls.cardHasKeyboard }
        XCTAssertTrue(controls.cardHasKeyboard, "typing goes to the date field")
        XCTAssertTrue(textView.string.hasSuffix("/da"), "the command stays until a date is chosen")
        controls.cancelCard()
        XCTAssertNil(controls.cardModel.card)
        XCTAssertTrue(textView.window?.firstResponder === textView, "the keyboard is back in the note")
        XCTAssertTrue(textView.string.hasSuffix("Call Sam /da"), "Esc puts /da back")

        type(" /da", textView)
        controls.pickSlash(.date)
        controls.cardModel.dateText = "fri"
        let friday = try XCTUnwrap(controls.cardModel.candidateDate)
        XCTAssertEqual(Calendar.current.component(.weekday, from: friday), 6)
        controls.cardModel.onCommitDate?(friday)
        XCTAssertNil(controls.cardModel.card)
        let last = try XCTUnwrap(engine.document().blocks.last)
        XCTAssertEqual(last.text, "Call Sam /da " + String(NoteDocument.objectCharacter), "the chip replaces the second /da")
        XCTAssertEqual(last.inlines.first?.kind, .date(NoteDay(date: friday)))
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(textView.string.hasSuffix("Call Sam /da /da"), "one Undo brings the command back")
    }

    func testInsertDateFromTheMenuUsesTheCardAndTheCaret() throws {
        let (controls, engine, textView) = make()
        let caret = NSRange(location: range("Student", textView).location, length: 0)
        textView.setSelectedRange(caret)
        find("Date…", in: controls.router.menuCommands(from: .noteMenu))?.action()
        XCTAssertEqual(controls.cardModel.card, .date(fromSlash: false))
        let today = try XCTUnwrap(controls.cardModel.candidateDate, "an empty field means today")
        controls.cardModel.onCommitDate?(today)
        XCTAssertEqual(engine.document().blocks[4].inlines.first?.kind, .date(NoteDay(date: today)))
    }

    func testSlashImageAsksForAFileAndCancelLeavesTheCommand() {
        let (controls, engine, textView) = make()
        var asked: Bool?
        var request: NoteSlashFileRequest?
        controls.requestFile = { asked = $0 != nil; request = $0 }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\n/ima", textView)
        XCTAssertEqual(controls.slashModel.items.map(\.kind), [.imageOrFile])
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(asked, true, "the open panel, for the / row")
        request?.cancel()
        XCTAssertNil(engine.pendingSlashFile)
        XCTAssertTrue(textView.string.hasSuffix("/ima"))
        find("Image or File…", in: controls.router.menuCommands(from: .noteMenu))?.action()
        XCTAssertEqual(asked, false, "Insert › Image or File… asks too")
    }

    // MARK: Links

    func testTheLinkCardAddsEditsAndRemovesALink() throws {
        let (controls, engine, textView) = make()
        let target = range("free tier", textView)
        textView.setSelectedRange(target)
        controls.router.run(.mark(.link), from: .shortcut)
        XCTAssertEqual(controls.cardModel.card, .link(hasLink: false))
        settle { controls.cardHasKeyboard }
        XCTAssertTrue(controls.cardHasKeyboard, "the card's field takes the keyboard from the note")
        controls.cardModel.linkText = "not a link"
        controls.cardModel.submitLink()
        XCTAssertNotNil(controls.cardModel.linkError, "a bad address says so and keeps the card")
        XCTAssertTrue(controls.isCardOpen)
        controls.cardModel.linkText = "example.com/pricing"
        controls.cardModel.submitLink()
        XCTAssertFalse(controls.isCardOpen)
        let link = try XCTUnwrap(engine.document().blocks[1].marks.first)
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.url, "https://example.com/pricing")
        XCTAssertEqual(textView.selectedRange(), target, "the selection comes back")

        textView.setSelectedRange(target)
        controls.router.run(.mark(.link), from: .contextMenu)
        XCTAssertEqual(controls.cardModel.card, .link(hasLink: true))
        XCTAssertEqual(controls.cardModel.linkText, "https://example.com/pricing", "editing shows the address")
        controls.cardModel.onRemoveLink?()
        XCTAssertTrue(engine.document().blocks[1].marks.isEmpty)
        XCTAssertEqual(engine.history.undoActionName, "Remove Link")
    }

    func testLinkValidationGrowthUpdatesBoundsAndBottomActionsAtCompactSize() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let (controls, engine, textView) = make()
        let window = try XCTUnwrap(textView.window)
        window.setContentSize(CGSize(width: 320, height: 240))
        window.contentView?.layoutSubtreeIfNeeded()
        let target = range("free tier", textView)
        controls.router.run(.link("https://example.com"), from: .linkPopover, selection: target)
        textView.setSelectedRange(target)
        controls.router.run(.mark(.link), from: .shortcut)
        settle { controls.cardHasKeyboard }
        let overlayParent = try XCTUnwrap(window.contentView?.superview)
        let host = try XCTUnwrap(overlayParent.subviews.compactMap { $0 as? AtticOverlayHostingView }.first { $0.acceptsKeyboard && $0.isInteractive })
        let before = host.contentRect.size
        controls.cardModel.linkText = "https://"
        controls.cardModel.submitLink()
        settle { host.contentRect.height > before.height }
        XCTAssertNotNil(controls.cardModel.linkError)
        XCTAssertGreaterThan(host.contentRect.height, before.height)
        XCTAssertEqual(host.contentRect.width, before.width, accuracy: 1)
        let placed = textView.convert(host.contentRect, from: host)
        XCTAssertGreaterThanOrEqual(placed.minY, textView.visibleRect.minY + 11)
        XCTAssertLessThanOrEqual(placed.maxY, textView.visibleRect.maxY - 11)
        func elements(_ root: AnyObject) -> [AnyObject] {
            let children = (root.accessibilityChildren?() ?? nil) ?? []
            return [root] + children.flatMap { elements($0 as AnyObject) }
        }
        func action(_ identifier: String) throws -> AnyObject {
            try XCTUnwrap(elements(host).first { ($0.accessibilityIdentifier?() ?? nil) == identifier })
        }
        for identifier in ["notes-link-remove", "notes-link-apply"] {
            let button = try action(identifier)
            let frame: NSRect = button.accessibilityFrame!()
            let local = host.convert(window.convertFromScreen(frame), from: nil)
            let center = CGPoint(x: local.midX, y: local.midY)
            XCTAssertTrue(host.contentRect.contains(center), "\(identifier) is inside the updated interactive bounds")
            XCTAssertNotNil(host.hitTest(host.convert(center, to: host.superview)))
        }
        // Force the error card to overflow, then bring its bottom actions
        // into view through the real scroll container.
        window.setContentSize(CGSize(width: 320, height: 145))
        window.contentView?.layoutSubtreeIfNeeded()
        textView.onLayout?()
        settle { controls.cardModel.viewportHeight != nil }
        XCTAssertNotNil(controls.cardModel.viewportHeight)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
        }
        settle { !scrolls(host).isEmpty }
        let scroll = try XCTUnwrap(scrolls(host).first)
        let document = try XCTUnwrap(scroll.documentView)
        document.scrollToVisible(CGRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
        spin()
        controls.cardModel.linkText = "example.org"
        spin()
        for identifier in ["notes-link-remove", "notes-link-apply"] {
            let button = try action(identifier)
            let frame: NSRect = button.accessibilityFrame!()
            let local = host.convert(window.convertFromScreen(frame), from: nil)
            let center = CGPoint(x: local.midX, y: local.midY)
            XCTAssertTrue(host.contentRect.contains(center), "\(identifier) is reachable after scrolling")
            XCTAssertNotNil(host.hitTest(host.convert(center, to: host.superview)))
        }
        XCTAssertTrue(try action("notes-link-apply").accessibilityPerformPress?() == true)
        XCTAssertFalse(controls.isCardOpen)
        XCTAssertEqual(engine.document().blocks[1].marks.first?.url, "https://example.org")
    }

    func testEditLinkAtACaretUpdatesTheWholeLinkAndAStaleTargetCancelsQuietly() throws {
        let (controls, engine, textView) = make()
        let target = range("free tier", textView)
        controls.router.run(.link("https://example.com"), from: .linkPopover, selection: target)
        textView.setSelectedRange(NSRange(location: target.location + 3, length: 0))
        controls.router.run(.mark(.link), from: .shortcut)
        XCTAssertEqual(controls.cardModel.card, .link(hasLink: true), "⇧⌘K at a caret inside a link edits it")
        XCTAssertEqual(controls.cardModel.linkText, "https://example.com")
        controls.cardModel.linkText = "example.org"
        controls.cardModel.submitLink()
        let link = try XCTUnwrap(engine.document().blocks[1].marks.first)
        XCTAssertEqual(link.url, "https://example.org")
        XCTAssertEqual(NSRange(location: link.offset, length: link.length),
                       NSRange(location: target.location - range("Lead", textView).location, length: target.length),
                       "the whole link, not just the caret")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: target.location + 3, length: 0), "the caret comes back")

        textView.setSelectedRange(range("most people", textView))
        controls.router.run(.mark(.link), from: .shortcut)
        XCTAssertTrue(controls.isCardOpen)
        // The note changes under the open card (an agent, Undo): the target is stale.
        textView.insertText("So: ", replacementRange: NSRange(location: range("Lead", textView).location, length: 0))
        textView.setSelectedRange(range("most people", textView))
        let before = engine.document()
        controls.cardModel.linkText = "example.com"
        controls.cardModel.submitLink()
        XCTAssertFalse(controls.isCardOpen, "the card closes")
        XCTAssertNil(controls.cardModel.linkError, "no error for a stale target: it just cancels")
        XCTAssertEqual(engine.document().blocks[1].marks.filter { $0.kind == .link }.count,
                       before.blocks[1].marks.filter { $0.kind == .link }.count, "and nothing was linked")
    }

    func testRightClickOnALinkOffersEditCopyAndRemove() throws {
        let (controls, _, textView) = make()
        let target = range("free tier", textView)
        controls.router.run(.link("https://example.com"), from: .linkPopover, selection: target)
        let rect = try XCTUnwrap(controls.engine.rect(for: target))
        let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: textView.window!.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(textView.menu(for: event))
        let titles = menu.items.map(\.title)
        for title in ["Open Link", "Edit Link…", "Copy Link", "Remove Link", "Format", "Insert"] {
            XCTAssertEqual(titles.filter { $0 == title }.count, 1, "\(title) once in \(titles)")
        }
        invoke(menu.items.first { $0.title == "Copy Link" })
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "https://example.com")
        XCTAssertEqual(controls.link(at: textView.convert(point, from: nil))?.0, "https://example.com")
    }

    func testLinksReadAsBodyTextWithAQuietUnderline() {
        let (_, _, textView) = make()
        let style = NoteTextStyle(design: .default)
        XCTAssertEqual(textView.linkTextAttributes?[.foregroundColor] as? NSColor, style.bodyColor)
        XCTAssertEqual(textView.linkTextAttributes?[.underlineColor] as? NSColor, style.secondaryColor)
    }

    // MARK: Hint and dates

    /// Draft 7's hint: an empty body line with the caret in it, every
    /// note; gone with the first keystroke; never on a line with text, the
    /// title, a styled empty line or a read-only note. VoiceOver hears it as
    /// the text's help, never as content.
    func testTheHintShowsOnAnEmptyBodyLineAndGoesWithTheFirstKeystroke() {
        let (controls, _, textView) = make()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        controls.refresh()
        XCTAssertFalse(controls.isHintVisible, "a line with text")
        type("\n", textView)
        controls.refresh()
        XCTAssertTrue(controls.isHintVisible, "an empty body line")
        XCTAssertEqual(textView.accessibilityHelp(), NoteSlashHintView.text)
        XCTAssertFalse(textView.string.contains("Type /"), "never content")
        type("a", textView)
        XCTAssertFalse(controls.isHintVisible, "the first keystroke hides it at once")
        XCTAssertNil(textView.accessibilityHelp())
        type("\n", textView)
        controls.refresh()
        XCTAssertTrue(controls.isHintVisible, "on the next empty line again")
        controls.formatModel.run(.paragraph(.bullet), from: .formatBar)
        controls.refresh()
        XCTAssertFalse(controls.isHintVisible, "an empty list item keeps its own look")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        controls.refresh()
        XCTAssertFalse(controls.isHintVisible, "the title")

        let (empty, _, emptyView) = make(NoteDocument(blocks: [.text("")]))
        type("Plan\n", emptyView)
        empty.refresh()
        XCTAssertTrue(empty.isHintVisible, "any note, not only new drafts")

        let (readOnly, _, readOnlyView) = make(NoteDocument(blocks: [.text("Plan"), .text("")]), readOnly: true)
        readOnlyView.setSelectedRange(NSRange(location: (readOnlyView.string as NSString).length, length: 0))
        readOnly.refresh()
        XCTAssertFalse(readOnly.isHintVisible, "read only")
    }

    func testTypingSlashHidesTheHint() {
        let (controls, _, textView) = make(NoteDocument(blocks: [.text("")]))
        type("Plan\n", textView)
        controls.refresh()
        XCTAssertTrue(controls.isHintVisible)
        type("/", textView)
        controls.refresh()
        XCTAssertFalse(controls.isHintVisible)
    }

    // MARK: The format row (OD-14)

    /// Opening and closing the row changes nothing the page observes, so
    /// the page and the note are not redrawn; only the bottom row's switch
    /// sees it.
    func testOpeningTheFormatRowDoesNotRedrawThePageOrTheNote() {
        let chrome = NotesPageChrome()
        var pageChanges = 0
        let page = chrome.objectWillChange.sink { _ in pageChanges += 1 }
        var rowChanges = 0
        let row = chrome.formatRow.objectWillChange.sink { _ in rowChanges += 1 }
        chrome.formatRow.open(keyboard: false)
        XCTAssertTrue(chrome.formatRow.isOpen)
        chrome.closeFormatBar()
        XCTAssertFalse(chrome.formatRow.isOpen, "✕ or Esc restores the row")
        XCTAssertEqual(pageChanges, 0, "the page (and the note under it) is never invalidated")
        XCTAssertEqual(rowChanges, 2, "the bottom row's switch is")
        page.cancel()
        row.cancel()

        let (controls, _, textView) = make()
        let text = textView.string
        let snapshots = controls.snapshotCount
        controls.isFormatBarOpen = true
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(controls.snapshotCount, snapshots + 1, "one state read as it opens")
    }

    /// A29: a note opens with its caret at the start of the title, where
    /// nothing in the row applies, so Aa showed a row of dimmed controls
    /// ("it's greyed out"). Opening the row from the title now puts the caret
    /// on the first body line (the text is untouched), and every control that
    /// applies there is enabled.
    func testOpeningTheFormatRowFromTheTitleFormatsTheFirstBodyLine() {
        let (controls, _, textView) = make()
        let text = textView.string
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controls.isFormatBarOpen = true
        XCTAssertEqual(textView.selectedRange(), NSRange(location: range("Lead", textView).location, length: 0),
                       "the caret moves to the start of the first body line")
        XCTAssertEqual(textView.string, text, "the text is not changed")
        let snapshot = controls.formatModel.snapshot
        XCTAssertNil(snapshot.disabledReason)
        for command in NoteCommandCatalog.lists + NoteCommandCatalog.styles where command != .paragraph(.heading(1)) {
            XCTAssertTrue(snapshot.isEnabled(command), "\(command) applies to the caret's line")
        }
        XCTAssertTrue(NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) }, "the style pill is live")

        // A caret already in the body stays where it is.
        controls.isFormatBarOpen = false
        let inBody = NSRange(location: range("Annual", textView).location + 3, length: 0)
        textView.setSelectedRange(inBody)
        controls.isFormatBarOpen = true
        XCTAssertEqual(textView.selectedRange(), inBody)

        // A title-only note has no line to format: the caret and text stay.
        let (titleOnly, _, titleView) = make(NoteDocument(blocks: [.text("Only a title")]))
        titleView.setSelectedRange(NSRange(location: 3, length: 0))
        titleOnly.isFormatBarOpen = true
        XCTAssertEqual(titleView.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(titleView.string, "Only a title")
    }

    /// The app's own springs (owner, round 3), and the order that keeps one
    /// glass moving at a time, in every feel: in the narrowest panel (a
    /// 288 pt row, Aa at 208), the growing glass never reaches a neighbour
    /// that is still showing, opening or closing, and the row at rest is the
    /// plain bar with its controls fully drawn.
    func testTheFormatRowGrowsOutOfAaWithOneGlassMoving() {
        let row: CGFloat = 288
        let aa = CGRect(x: 208, y: 0, width: 36, height: 36)
        let allNotes = (minX: CGFloat(0), maxX: CGFloat(36)), newNote = (minX: CGFloat(252), maxX: CGFloat(288))
        let status = (minX: CGFloat(62), maxX: CGFloat(182))
        for feel in AtticMotionFeel.allCases {
            let tuning = feel.tuning
            let plan = NoteFormatMotion.Plan(tuning)
            XCTAssertEqual(plan.openLeading.response, tuning.expand.response, "\(feel): the glass is expand")
            XCTAssertEqual(plan.openLeading.bounce, tuning.expand.bounce)
            XCTAssertEqual(plan.openTrailing.response, tuning.expand.response)
            XCTAssertEqual(plan.openLeading.delay, 0, "\(feel): Aa answers the click at once")
            XCTAssertEqual(plan.closeGrow.response, tuning.expand.response)
            XCTAssertEqual(plan.openControls.response, tuning.popover.response, "\(feel): the controls come as a bar")
            XCTAssertEqual(plan.comeBack.response, tuning.popover.response)
            XCTAssertGreaterThan(plan.openControls.delay, plan.openTrailing.delay, "\(feel): controls once the glass is wide")
            XCTAssertGreaterThan(plan.openTrailing.delay, 0, "\(feel): New note first on its side")
            XCTAssertGreaterThan(plan.closeGrow.delay, 0, "\(feel): controls first when closing")

            func visible(_ value: Double) -> Double { min(1, max(0, value)) }
            func check(_ t: Double, leading: Double, trailing: Double, allShows: Double, rightShows: Double,
                       statusShows: Double, _ phase: String) {
                let extent = AtticFormatRowGrowth(source: aa, rowWidth: row, leading: leading, trailing: trailing,
                                                  sourceSymbol: "textformat").extent
                let glass = (minX: extent.minX, maxX: extent.minX + extent.width)
                // A neighbour still showing keeps clear of the glass's edge: New
                // note by 6 pt (it rests 8 from Aa), the status by 20, All notes by 24.
                func overlaps(_ span: (minX: CGFloat, maxX: CGFloat), clear: CGFloat) -> Bool {
                    glass.minX - clear < span.maxX && glass.maxX + clear > span.minX
                }
                if overlaps(newNote, clear: 6) {
                    XCTAssertLessThanOrEqual(rightShows, 0.03, "\(feel) \(phase) \(t)s: the glass reaches New note")
                }
                if overlaps(status, clear: 20) {
                    XCTAssertLessThanOrEqual(statusShows, 0.05, "\(feel) \(phase) \(t)s: the glass reaches the status")
                }
                if overlaps(allNotes, clear: 24) {
                    XCTAssertLessThanOrEqual(allShows, 0.03, "\(feel) \(phase) \(t)s: the glass reaches All notes")
                }
            }
            for step in 0...1500 {
                let t = Double(step) / 1000
                // Opening: each neighbour fades, then its glass is taken away.
                // (The status, plain text, is hidden as the row opens.)
                check(t, leading: plan.openLeading.value(at: t), trailing: plan.openTrailing.value(at: t),
                      allShows: t >= plan.allNotesSettles ? 0 : visible(1 - plan.allNotesLeave.value(at: t)),
                      rightShows: t >= plan.newNoteSettles ? 0 : visible(1 - plan.leave.value(at: t)),
                      statusShows: 0, "opening")
                // Closing: each comes back on its own clock.
                let back = 1 - plan.closeGrow.value(at: t)
                let newNoteBack = visible(plan.comeBack.value(at: t - plan.newNoteReturns))
                check(t, leading: back, trailing: back,
                      allShows: visible(plan.comeBack.value(at: t - plan.allNotesReturns)),
                      rightShows: newNoteBack, statusShows: newNoteBack, "closing")
            }
        }

        let start = AtticFormatRowGrowth(source: aa, rowWidth: row, grow: 0, sourceSymbol: "textformat")
        XCTAssertEqual(start.extent.minX, aa.minX); XCTAssertEqual(start.extent.width, aa.width)
        XCTAssertEqual(start.sourceGlyphOpacity, 1, "it starts as Aa, glyph and all")
        let end = AtticFormatRowGrowth(source: aa, rowWidth: row, grow: 1, sourceSymbol: "textformat")
        XCTAssertEqual(end.extent.minX, 0); XCTAssertEqual(end.extent.width, row)
        XCTAssertEqual(end.sourceGlyphOpacity, 0)
        XCTAssertEqual(NoteFormatRowChannels.open,
                       NoteFormatRowChannels(leading: 1, trailing: 1, controls: 1, allNotes: 1, newNoteAndStatus: 1),
                       "open, the controls are fully drawn")
    }

    /// Animations: Reduced and Reduce Motion swap the rows at once; with
    /// motion, the bottom row stays live in the tree (away) while the glass
    /// grows. Open, it is disabled, out of the pointer and keyboard.
    func testReduceMotionSwapsTheFormatRowAtOnce() {
        final class Seen { var enabled = true, away = false }
        struct Probe: View {
            let seen: Seen
            @Environment(\.isEnabled) private var isEnabled
            @Environment(\.noteFormatRowStage) private var stage
            var body: some View {
                seen.enabled = isEnabled
                seen.away = stage.sourceHidden
                return Color.clear.frame(width: 288, height: 36)
            }
        }
        func host(reduceMotion: Bool) -> (NoteFormatRowState, Seen) {
            let (controls, _, _) = make()
            let state = NoteFormatRowState()
            let seen = Seen()
            var design = AtticDesignContext(mode: .light)
            design.reduceMotion = reduceMotion
            let view = NoteFormatRowSwitch(state: state, model: { controls.formatModel }) { Probe(seen: seen) }
                .environment(\.atticDesign, design)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 288, height: 36)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            windows.append(window)
            hosting.layoutSubtreeIfNeeded()
            return (state, seen)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        let (reduced, reducedSeen) = host(reduceMotion: true)
        settle()
        XCTAssertTrue(reducedSeen.enabled)
        reduced.open(keyboard: false)
        settle()
        XCTAssertFalse(reducedSeen.enabled, "the row is open at once")
        XCTAssertTrue(reducedSeen.away)
        reduced.close()
        settle()
        XCTAssertTrue(reducedSeen.enabled, "and back at once")
        XCTAssertFalse(reducedSeen.away)

        let (moving, movingSeen) = host(reduceMotion: false)
        settle()
        moving.open(keyboard: false)
        settle()
        XCTAssertTrue(movingSeen.away, "with motion Aa's glass is the row's")
        XCTAssertTrue(movingSeen.enabled, "and the bottom row is still on its way out")
    }

    /// ⌃Tab reaches the open row; ← → Tab ⇧Tab move round it, Return
    /// presses, and any other key goes back to writing. The text keeps the
    /// caret throughout.
    func testTheFormatRowIsOperableFromTheKeyboard() {
        let (controls, engine, textView) = make()
        let window = textView.window!
        textView.setSelectedRange(NSRange(location: range("Annual", textView).location + 2, length: 0))
        controls.isFormatBarOpen = true
        XCTAssertTrue(controls.handleKey(keyEvent("\t", "\t", keyCode: 48, .control, window: window)))
        XCTAssertEqual(controls.formatModel.rowKeyboardIndex, 0, "⌃Tab: the style pill")
        XCTAssertTrue(controls.handleKey(keyEvent("", "", keyCode: 124, [], window: window)))
        XCTAssertEqual(controls.formatModel.rowKeyboardIndex, 1, "→: Bulleted")
        XCTAssertTrue(controls.handleKey(keyEvent("\r", "\r", keyCode: 36, [], window: window)))
        XCTAssertEqual(engine.document().blocks[3].style, "bullet", "Return applies it to the caret's line")
        controls.refreshSnapshot()
        XCTAssertEqual(controls.formatModel.snapshot.value(.paragraph(.bullet)), .on, "the toggle shows it")
        XCTAssertTrue(controls.handleKey(keyEvent("\t", "\t", keyCode: 48, [], window: window)))
        XCTAssertEqual(controls.formatModel.rowKeyboardIndex, 2, "Tab: Numbered")
        XCTAssertTrue(controls.handleKey(keyEvent("\u{19}", "\u{19}", keyCode: 48, .shift, window: window)))
        XCTAssertTrue(controls.handleKey(keyEvent("", "", keyCode: 123, [], window: window)))
        XCTAssertEqual(controls.formatModel.rowKeyboardIndex, 0, "⇧Tab and ← go back")
        XCTAssertTrue(controls.handleKey(keyEvent(" ", " ", keyCode: 49, [], window: window)))
        XCTAssertTrue(controls.formatModel.rowStyleListOpen, "Space on the pill opens the style list")
        controls.formatModel.rowStyleListOpen = false
        XCTAssertFalse(controls.handleKey(keyEvent("x", "x", keyCode: 7, [], window: window)), "a letter is writing")
        XCTAssertNil(controls.formatModel.rowKeyboardIndex)
        XCTAssertTrue(controls.isFormatBarOpen, "the row stays open")
        XCTAssertTrue(window.firstResponder === textView, "the text never lost the keyboard")

        var closed = 0
        controls.closeFormatBar = { closed += 1; controls.isFormatBarOpen = false }
        controls.enterRowKeyboard(at: NoteFormatRowItem.all.count - 1)
        XCTAssertTrue(controls.handleKey(keyEvent("\r", "\r", keyCode: 36, [], window: window)))
        XCTAssertEqual(closed, 1, "Return on ✕ closes the row")
        XCTAssertNil(controls.formatModel.rowKeyboardIndex)
    }

    /// The row's style list and toggles run the route A22/A24 fixed: on an
    /// empty line the next typed text keeps the chosen style.
    func testTheFormatRowsStylesAndListsCarryIntoTheNextTypedText() {
        for style in [NoteParagraphStyle.heading(2), .quote, .checklist, .number, .mono] {
            let command = NoteFormatCommand.paragraph(style)
            let (controls, engine, textView) = make()
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            type("\n", textView)
            controls.isFormatBarOpen = true
            if NoteCommandCatalog.styles.contains(command) {
                // The pill's list: the same model call its rows make.
                controls.formatModel.rowStyleListOpen = true
                controls.formatModel.run(command, from: .formatBar)
            } else {
                controls.pressRowItem(.command(command))
            }
            type("Next words", textView)
            let typed = range("Next words", textView)
            XCTAssertNotEqual(typed.location, NSNotFound)
            XCTAssertEqual(engine.paragraphStyle(at: typed.location + 2), style, "\(style): the next text keeps it")
            XCTAssertTrue(controls.isFormatBarOpen, "the row stays open while you write")
        }
    }

    func testDateQueriesReadCommonWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let wednesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30)))
        func day(_ text: String) -> Int? {
            NoteDateQuery.parse(text, today: wednesday, calendar: calendar).map { calendar.component(.day, from: $0) }
        }
        XCTAssertEqual(day("fri"), 2)
        XCTAssertEqual(day("wed"), 30, "today's weekday is today")
        XCTAssertEqual(day("next wed"), 7)
        XCTAssertEqual(day("tomorrow"), 1)
        XCTAssertEqual(day("today"), 30)
        XCTAssertEqual(day("+3"), 3)
        XCTAssertEqual(day("in 2 days"), 2)
        XCTAssertEqual(day("12"), 12, "a passed day of the month is next month's")
        XCTAssertNil(day("xyzzy"))
    }

    // MARK: The Esc chain: the innermost thing closes, never the panel too

    private func escape(in window: NSWindow) -> NSEvent {
        keyEvent("\u{1b}", "\u{1b}", keyCode: 53, [], window: window)
    }

    func testEscClosesTheBarThenTheListAndOnlyThenReachesThePanel() {
        let (controls, _, textView) = make()
        var panelHides = 0
        textView.escapeFallback = { panelHides += 1 }
        textView.setSelectedRange(range("most people", textView))
        controls.refresh()
        XCTAssertTrue(controls.formatModel.barShown)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controls.formatModel.barShown, "Esc closes the bar")
        XCTAssertEqual(panelHides, 0, "and is used up there")

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\n/", textView)
        XCTAssertTrue(controls.slashModel.shown)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controls.slashModel.shown, "Esc closes the / list")
        XCTAssertEqual(panelHides, 0)
        XCTAssertTrue(textView.string.hasSuffix("\n/"), "and leaves the /")

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(panelHides, 1, "with nothing left to close, Esc goes on to the panel")
    }

    func testEscInTheBarsKeyboardModeLeavesTheBarNotThePanel() {
        let (controls, _, textView) = make()
        var panelHides = 0
        textView.escapeFallback = { panelHides += 1 }
        textView.setSelectedRange(range("most people", textView))
        controls.refresh()
        controls.enterBarKeyboard()
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)), "the monitor uses it up")
        XCTAssertNil(controls.formatModel.barKeyboardIndex)
        XCTAssertTrue(controls.formatModel.barShown, "the first Esc only leaves the bar's keyboard mode")
        XCTAssertEqual(panelHides, 0)
    }

    func testEscClosesTheFormatRowAndIsUsedUp() {
        let (controls, _, textView) = make()
        var closed = 0
        controls.closeFormatBar = { closed += 1; controls.isFormatBarOpen = false }
        var panelHides = 0
        textView.escapeFallback = { panelHides += 1 }
        controls.isFormatBarOpen = true
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)), "Esc closes the row and goes no further")
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(panelHides, 0, "it never reaches the text view's hide-the-panel")
        XCTAssertFalse(controls.handleKey(escape(in: textView.window!)), "with the row closed, it isn't the chain's")
        XCTAssertTrue(textView.window?.firstResponder === textView, "the note keeps the keyboard")

        // The selection bar first: Esc is the text view's (it hides the bar),
        // and the row stays open.
        controls.isFormatBarOpen = true
        textView.setSelectedRange(range("most people", textView))
        controls.refresh()
        XCTAssertTrue(controls.formatModel.barShown, "marks stay on the selection bar while the row is open")
        XCTAssertFalse(controls.handleKey(escape(in: textView.window!)))
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(controls.isFormatBarOpen)

        // The style list first: Esc closes the list only.
        textView.setSelectedRange(NSRange(location: 20, length: 0))
        controls.refresh()
        controls.formatModel.rowStyleListOpen = true
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)))
        XCTAssertFalse(controls.formatModel.rowStyleListOpen)
        XCTAssertEqual(closed, 1, "the row stays")
    }

    func testEscInACardClosesTheCardOnlyAndIsUsedUp() throws {
        let (controls, engine, textView) = make()
        let target = range("free tier", textView)
        textView.setSelectedRange(target)
        controls.router.run(.mark(.link), from: .shortcut)
        settle { controls.cardHasKeyboard }
        XCTAssertTrue(controls.cardHasKeyboard)
        let before = engine.document()
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)))
        XCTAssertFalse(controls.isCardOpen, "Esc closes the link card")
        XCTAssertTrue(textView.window?.firstResponder === textView, "the keyboard is back in the note")
        XCTAssertEqual(textView.selectedRange(), target)
        XCTAssertEqual(engine.document(), before, "nothing changed")
        XCTAssertNil(controls.closeInnermostOnEscape(escape(in: textView.window!)),
                     "the next Esc is the text view's own (the bar, then the panel)")

        // A card whose field never took the keyboard still closes first.
        textView.setSelectedRange(target)
        controls.router.run(.mark(.link), from: .shortcut)
        textView.window?.makeFirstResponder(textView)
        XCTAssertTrue(controls.isCardOpen)
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)))
        XCTAssertFalse(controls.isCardOpen)

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\n/da", textView)
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.insertNewline(_:))))
        settle { controls.cardHasKeyboard }
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)))
        XCTAssertFalse(controls.isCardOpen, "Esc closes the date card")
        XCTAssertTrue(textView.string.hasSuffix("/da"), "and puts /da back")
    }

    func testThePanelIgnoresAnEscTypedInAnotherWindow() {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                               backing: .buffered, defer: false)
        popover.isReleasedWhenClosed = false
        windows += [panel, popover]
        var hides = 0
        panel.onUnhandledEscape = { hides += 1 }
        panel.keyDown(with: escape(in: popover))
        XCTAssertEqual(hides, 0, "a pop-over's Esc never hides the panel as well")
        panel.keyDown(with: escape(in: panel))
        XCTAssertEqual(hides, 1, "the panel's own Esc, with nothing to close, still hides it")
    }

    // MARK: Performance (the engine's 5,000-line stress note)

    /// Keystrokes with the controls installed read no state and cost what
    /// they cost without them (same run, same note); a selection's snapshot
    /// and the bar's first and later placements are timed for the report.
    func testControlsAddNoWorkPerKeystrokeOnAStressNote() throws {
        var blocks: [NoteBlock] = [.text("Stress")]
        for index in 0..<5_000 {
            blocks.append(index % 50 == 10 ? .checklist("Item \(index)")
                          : .text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
        }
        func ms(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func typing(_ textView: NoteEditorTextView) -> [Double] {
            let middle = range("Line 2501 ", textView).location
            textView.setSelectedRange(NSRange(location: middle, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            textView.displayIfNeeded()
            spin()
            return "the quick brown fox jumps over the lazy dog again and again!".map { character in
                ms {
                    textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    textView.displayIfNeeded()
                    RunLoop.main.run(until: Date())
                }
            }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func p95(_ values: [Double]) -> Double { let s = values.sorted(); return s[Int(Double(s.count - 1) * 0.95)] }

        // Without, with, without again: the first run warms the caches.
        func plainRun() -> [Double] {
            let (plainControls, _, plainView) = make(NoteDocument(blocks: blocks))
            plainControls.invalidate()
            return typing(plainView)
        }
        _ = plainRun()
        let (controls, _, textView) = make(NoteDocument(blocks: blocks))
        let before = controls.snapshotCount
        let withControls = typing(textView)
        XCTAssertEqual(controls.snapshotCount, before, "typing reads no format state")
        controls.invalidate()
        let without = plainRun()

        let (timed, _, timedView) = make(NoteDocument(blocks: blocks))
        let sentence = range("Line 2600 with some ordinary words", timedView)
        timedView.setSelectedRange(sentence)
        timedView.scrollRangeToVisible(sentence)
        timedView.displayIfNeeded()
        let snapshot = ms { _ = NoteFormatSnapshot.make(router: timed.router, selection: sentence) }
        let first = ms { timed.refresh() }
        XCTAssertTrue(timed.formatModel.barShown)
        timedView.setSelectedRange(range("Line 2601 with some", timedView))
        let later = ms { timed.refresh() }
        timedView.setSelectedRange(NSRange(location: 0, length: (timedView.string as NSString).length))
        let everything = timedView.selectedRange()
        let all = ms { _ = NoteFormatSnapshot.make(router: timed.router, selection: everything) }
        let markAll = ms { _ = timed.engine.validate(.mark(.bold), selection: everything) }
        let styleAll = ms { _ = timed.engine.validate(.paragraph(.body), selection: everything) }
        let report = String(format: "NOTE-FORMAT-PERF keystroke median %.2f ms p95 %.2f ms (without controls %.2f / %.2f); sentence snapshot %.2f ms; bar first show %.1f ms, next %.2f ms; select-all snapshot %.0f ms (one mark %.0f ms, one style %.0f ms)",
                            median(withControls), p95(withControls), median(without), p95(without), snapshot, first, later, all,
                            markAll, styleAll)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
    }
}

// MARK: - A17: the keyboard's way back into the text (fake text, fake frames)

@MainActor
private final class ManualFrames: NotesFrameClock {
    private var queue: [@MainActor () -> Void] = []
    var pending: Int { queue.count }
    func nextFrame(_ block: @escaping @MainActor () -> Void) { queue.append(block) }
    func cancel() { queue.removeAll() }
    /// One display frame: runs what was waiting for it.
    func tick() {
        let due = queue
        queue.removeAll()
        due.forEach { $0() }
    }
}

@MainActor
private final class FakeText: NotesKeyboardReturnTarget {
    var canTakeKeyboard = true
    var textHasKeyboard = false
    var textHasMarkedText = false
    var textSelection: NSRange? = NSRange(location: 3, length: 0)
    var focusCount = 0
    var takesKeyboard = true
    func focusText() {
        focusCount += 1
        if takesKeyboard { textHasKeyboard = true }
    }
}

extension NotesFormatControlsTests {
    private func makeReturn(_ text: FakeText, _ frames: ManualFrames, pacing: NotesKeyboardReturn.Pacing = .init(),
                            uptime: @escaping () -> TimeInterval = { 0 }) -> NotesKeyboardReturn {
        NotesKeyboardReturn(target: text, clock: frames, pacing: pacing, uptime: uptime)
    }

    /// A17 P2: the return waits out SwiftUI's late focus update. The text is
    /// first responder for two frames, then SwiftUI resigns it on the third:
    /// the run focuses it again, and settles only after it has held the
    /// keyboard for three frames in a row, never before six frames.
    func testReturnToTextSurvivesALateResignAndSettlesOnlyAfterItHeldTheKeyboard() {
        let text = FakeText(), frames = ManualFrames()
        let run = makeReturn(text, frames)
        run.start()
        XCTAssertTrue(text.textHasKeyboard, "focused at once")
        for frame in 1...8 {
            if frame == 3 { text.textHasKeyboard = false }   // SwiftUI's update
            frames.tick()
            if frame < 6 { XCTAssertNil(run.end, "frame \(frame): still watching (two quiet frames are not enough)") }
        }
        XCTAssertEqual(run.end, .settled)
        XCTAssertTrue(text.textHasKeyboard, "the text kept the keyboard")
        XCTAssertEqual(text.focusCount, 2, "focused at the start and once after the resign")
        XCTAssertEqual(text.textSelection, NSRange(location: 3, length: 0), "caret kept")
        XCTAssertEqual(frames.pending, 0, "nothing scheduled after settling")
    }

    func testReturnToTextIsBoundedByFramesAndByTime() {
        let stubborn = FakeText()
        stubborn.takesKeyboard = false
        let frames = ManualFrames()
        let run = makeReturn(stubborn, frames, pacing: .init(minimumFrames: 6, heldFrames: 3, maximumFrames: 10, maximumSeconds: 100))
        run.start()
        var ticks = 0
        while frames.pending > 0, ticks < 100 { frames.tick(); ticks += 1 }
        XCTAssertEqual(run.end, .gaveUp)
        XCTAssertEqual(ticks, 10, "ten frames, then it stops")
        XCTAssertEqual(stubborn.focusCount, 11)

        var clockNow: TimeInterval = 0
        let late = makeReturn(stubborn, frames, pacing: .init(minimumFrames: 6, heldFrames: 3, maximumFrames: 1000, maximumSeconds: 1),
                              uptime: { clockNow })
        late.start()
        clockNow = 0.5
        frames.tick()
        XCTAssertNil(late.end)
        clockNow = 1.2
        frames.tick()
        XCTAssertEqual(late.end, .gaveUp, "time bounds it even when frames are slow")
        XCTAssertEqual(frames.pending, 0)
    }

    /// A17 P2: each way the keyboard (or the note) goes elsewhere ends the
    /// run, and nothing after it focuses the text again.
    func testEveryCancellationEndsTheReturnBeforeAnotherAttempt() {
        func scenario(_ name: String, _ interfere: (FakeText, NotesKeyboardReturn) -> Void) {
            let text = FakeText(), frames = ManualFrames()
            let run = makeReturn(text, frames)
            run.start()
            frames.tick()
            interfere(text, run)
            let focused = text.focusCount
            frames.tick()
            frames.tick()
            XCTAssertEqual(run.end, .cancelled, name)
            XCTAssertEqual(text.focusCount, focused, "\(name): no attempt after it")
            XCTAssertEqual(frames.pending, 0, name)
        }
        scenario("a click or a later ⌃Tab (cancel)") { text, run in text.textHasKeyboard = false; run.cancel() }
        scenario("a caret move") { text, _ in text.textHasKeyboard = true; text.textSelection = NSRange(location: 1, length: 0) }
        scenario("typing") { text, _ in text.textHasKeyboard = true; text.textSelection = NSRange(location: 4, length: 0) }
        scenario("a note switch or the editor dismantled") { text, _ in text.textHasKeyboard = false; text.canTakeKeyboard = false }
        scenario("the panel hiding") { text, _ in text.textHasKeyboard = false; text.canTakeKeyboard = false }
        scenario("composition starting") { text, _ in text.textHasKeyboard = false; text.textHasMarkedText = true }
    }

    func testReturnNeverStartsInsideCompositionOrAHiddenPanel() {
        let composing = FakeText(), frames = ManualFrames()
        composing.textHasMarkedText = true
        let first = makeReturn(composing, frames)
        first.start()
        XCTAssertEqual(first.end, .cancelled)
        XCTAssertEqual(composing.focusCount, 0)
        let hidden = FakeText()
        hidden.canTakeKeyboard = false
        let second = makeReturn(hidden, frames)
        second.start()
        XCTAssertEqual(second.end, .cancelled)
        XCTAssertEqual(hidden.focusCount, 0)
        XCTAssertEqual(frames.pending, 0)
    }

    func testReturnPutsTheCaretBackOnlyWhenItFocusesAndNeverOverTheUsersMove() {
        let text = FakeText(), frames = ManualFrames()
        text.textSelection = NSRange(location: 5, length: 2)
        let run = makeReturn(text, frames)
        run.start()
        text.textHasKeyboard = false
        text.textSelection = NSRange(location: 0, length: 0)    // the text view's selection reset by the loss
        frames.tick()
        XCTAssertEqual(text.textSelection, NSRange(location: 5, length: 2), "refocusing restores the caret and selection")
        frames.tick()
        text.textSelection = NSRange(location: 6, length: 0)    // the user
        frames.tick()
        XCTAssertEqual(text.textSelection, NSRange(location: 6, length: 0), "the user's move is never undone")
        XCTAssertEqual(run.end, .cancelled)
    }
}

// MARK: - A17: the keyboard's way back into the text, on a key window (CI only)

private final class FooterStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// A key-capable panel that does not activate the app (as the real panel).
private final class ReturnKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension NotesFormatControlsTests {
    private struct KeyHarness {
        let chrome: NotesPageChrome
        let accessories: NoteTitleAccessories
        let text: NoteEditorTextView
        let footer: FooterStandIn
        let window: NSWindow
    }

    /// A key window holding the note's text, its title accessories and a view
    /// standing in for the last control of the bottom row, with the caret at 5
    /// and the keyboard on the stand-in (⌃Tab's fourth press is about to come).
    private func keyHarness() throws -> KeyHarness {
        guard ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1" else {
            throw XCTSkip("CI only: the return needs a key window, which locally would take the keyboard")
        }
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Pricing"), .text("Body of the note")]))
        let (scroll, text) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 560))
        container.addSubview(scroll)
        let footer = FooterStandIn(frame: NSRect(x: 10, y: 510, width: 100, height: 30))
        container.addSubview(footer)
        let window = ReturnKeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 560),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        windows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "a key window")
        let chrome = NotesPageChrome()
        let accessories = NoteTitleAccessories(engine: engine, textView: text, scrollView: scroll, chrome: chrome, design: .default,
                                               headerBottom: 40, isUntouched: { false }, tagEditor: { AnyView(EmptyView()) })
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(window.makeFirstResponder(footer))
        return KeyHarness(chrome: chrome, accessories: accessories, text: text, footer: footer, window: window)
    }

    private func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func pause(_ seconds: TimeInterval = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A17 P2 (late focus update): SwiftUI takes the keyboard back after the
    /// text had it, on a later frame; the return gets it back, waits until it
    /// stayed, and typing right after the round trip lands at the caret.
    func testTheReturnSurvivesSwiftUIsLateFocusUpdateAndTypingRightAfterLandsAtTheCaret() throws {
        let h = try keyHarness()
        defer { h.accessories.invalidate() }
        h.chrome.returnKeyboardToText()
        let run = try XCTUnwrap(h.chrome.keyboardReturn)
        for delay in [0.03, 0.07] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = h.window.makeFirstResponder(h.footer) }
        }
        wait { run.end != nil }
        XCTAssertEqual(run.end, .settled)
        XCTAssertTrue(h.window.firstResponder === h.text, "the text has the keyboard after SwiftUI's updates")
        XCTAssertEqual(h.text.selectedRange(), NSRange(location: 5, length: 0), "caret kept")
        h.text.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(h.text.string, "Prici!ng\nBody of the note", "typing right after the round trip landed at the caret")
        XCTAssertNil(h.chrome.keyboardReturn, "the ticket is spent")
    }

    /// A17 P2 (cancellation): a click on another control. The monitor sees
    /// the mouse-down, and the keyboard stays where the user put it.
    func testAClickDuringTheReturnCancelsItAndTheKeyboardStaysWhereTheUserPutIt() throws {
        let h = try keyHarness()
        defer { h.accessories.invalidate() }
        h.chrome.returnKeyboardToText()
        let run = try XCTUnwrap(h.chrome.keyboardReturn)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 250, y: 545), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.sendEvent(click)
        XCTAssertEqual(run.end, .cancelled, "the click ended the return")
        XCTAssertTrue(h.window.makeFirstResponder(h.footer), "the click's target took the keyboard")
        pause()
        XCTAssertTrue(h.window.firstResponder === h.footer, "and the return did not take it back")
    }

    /// A17 P2: a caret move or typing during the return is the user's, and is
    /// never undone by a later attempt.
    func testACaretMoveOrTypingDuringTheReturnCancelsItAndKeepsTheUsersCaret() throws {
        let h = try keyHarness()
        defer { h.accessories.invalidate() }
        h.chrome.returnKeyboardToText()
        let run = try XCTUnwrap(h.chrome.keyboardReturn)
        XCTAssertTrue(h.window.firstResponder === h.text)
        h.text.setSelectedRange(NSRange(location: 2, length: 0))
        wait { run.end != nil }
        XCTAssertEqual(run.end, .cancelled)
        h.window.makeFirstResponder(h.footer)
        pause(0.3)
        XCTAssertEqual(h.text.selectedRange(), NSRange(location: 2, length: 0), "the caret the user chose")
        XCTAssertTrue(h.window.firstResponder === h.footer, "no attempt after the cancellation")

        // Typing, the same way.
        h.window.makeFirstResponder(h.text)
        h.text.setSelectedRange(NSRange(location: 5, length: 0))
        h.window.makeFirstResponder(h.footer)
        h.chrome.returnKeyboardToText()
        let typing = try XCTUnwrap(h.chrome.keyboardReturn)
        h.text.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        wait { typing.end != nil }
        XCTAssertEqual(typing.end, .cancelled)
        XCTAssertEqual(h.text.selectedRange(), NSRange(location: 6, length: 0), "after what was typed")
    }

    /// A17 P2: the note is replaced or the editor dismantled (`invalidate`),
    /// the page moves to another note (`cancelKeyboardReturn`).
    func testANoteSwitchOrDismantlingCancelsTheReturn() throws {
        let h = try keyHarness()
        h.chrome.returnKeyboardToText()
        let dismantled = try XCTUnwrap(h.chrome.keyboardReturn)
        h.accessories.invalidate()
        XCTAssertEqual(dismantled.end, .cancelled, "dismantling the editor ended it")
        h.window.makeFirstResponder(h.footer)
        pause(0.3)
        XCTAssertTrue(h.window.firstResponder === h.footer)

        let again = try keyHarness()
        defer { again.accessories.invalidate() }
        again.chrome.returnKeyboardToText()
        let switched = try XCTUnwrap(again.chrome.keyboardReturn)
        again.chrome.cancelKeyboardReturn()
        XCTAssertEqual(switched.end, .cancelled, "the page's note switch ended it")
        again.window.makeFirstResponder(again.footer)
        pause(0.3)
        XCTAssertTrue(again.window.firstResponder === again.footer)
    }

    /// A17 P2: the panel hides during the return.
    func testThePanelHidingCancelsTheReturn() throws {
        let h = try keyHarness()
        defer { h.accessories.invalidate() }
        h.chrome.returnKeyboardToText()
        let run = try XCTUnwrap(h.chrome.keyboardReturn)
        h.window.orderOut(nil)
        wait { run.end != nil }
        XCTAssertEqual(run.end, .cancelled, "a hidden panel ends it")
        h.window.orderFrontRegardless()
        h.window.makeKey()
        h.window.makeFirstResponder(h.footer)
        pause(0.3)
        XCTAssertTrue(h.window.firstResponder === h.footer, "shown again, nothing takes the keyboard from the control")
    }

    /// A17 P2: an input method starts composing during the return; the
    /// composition is left alone.
    func testCompositionStartingDuringTheReturnCancelsItAndKeepsTheMarkedText() throws {
        let h = try keyHarness()
        defer { h.accessories.invalidate() }
        h.chrome.returnKeyboardToText()
        let run = try XCTUnwrap(h.chrome.keyboardReturn)
        h.text.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(h.text.hasMarkedText())
        wait { run.end != nil }
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(h.text.hasMarkedText(), "the composition was not disturbed")
        XCTAssertTrue(h.window.firstResponder === h.text)
    }
}

// A18: ending the ticket must disarm its clock in the same turn.
extension NotesFormatControlsTests {
    func testReturnClockHasNoPendingFrameAsSoonAsItsTicketEnds() {
        let text = FakeText(), frames = ManualFrames()
        let run = makeReturn(text, frames)
        XCTAssertEqual(frames.pending, 0, "constructing a return never starts its clock")
        run.start()
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(frames.pending, 1)
        run.cancel()
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(frames.pending, 0, "no frame may remain armed while no re-focus is pending")
    }
}

extension NotesFormatControlsTests {
    func testDisplayClockIsIdleUntilRequestedAndStopsImmediatelyOnCancellation() async throws {
        let clock = NotesDisplayFrameClock(view: nil)
        XCTAssertFalse(clock.isRunning, "creating a clock does not schedule work")
        let text = FakeText()
        let run = NotesKeyboardReturn(target: text, clock: clock)
        XCTAssertFalse(clock.isRunning, "creating a return does not schedule work")
        run.start()
        XCTAssertTrue(clock.isRunning, "a pending return arms the fallback")
        run.cancel()
        XCTAssertFalse(clock.isRunning, "cancellation disarms the fallback in the same turn")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(run.focusCount, 1)
        XCTAssertFalse(clock.isRunning)
    }

    func testDisplayClockStopsItsFallbackBeforeReportingSettlementOrFrameLimit() async {
        for settled in [true, false] {
            let clock = NotesDisplayFrameClock(view: nil)
            let text = FakeText()
            text.takesKeyboard = settled
            let run = NotesKeyboardReturn(target: text, clock: clock,
                pacing: .init(minimumFrames: 1, heldFrames: 1, maximumFrames: 1, maximumSeconds: 1))
            let ended = expectation(description: settled ? "settled" : "gave up")
            run.onEnd = { result in
                XCTAssertEqual(result, settled ? .settled : .gaveUp)
                XCTAssertFalse(clock.isRunning, "end callbacks must observe an idle clock")
                ended.fulfill()
            }
            run.start()
            XCTAssertTrue(clock.isRunning)
            await fulfillment(of: [ended], timeout: 2)
            XCTAssertFalse(clock.isRunning)
        }
    }

    func testDisplayClockCancelsAReplacedFrameWithoutFiringItsCallback() async {
        let clock = NotesDisplayFrameClock(view: nil)
        var replacedCalls = 0
        clock.nextFrame { replacedCalls += 1 }
        let frame = expectation(description: "replacement fallback")
        clock.nextFrame {
            XCTAssertFalse(clock.isRunning, "a frame disarms both sources before calling back")
            frame.fulfill()
        }
        await fulfillment(of: [frame], timeout: 2)
        XCTAssertEqual(replacedCalls, 0)
        XCTAssertFalse(clock.isRunning)
    }
}
