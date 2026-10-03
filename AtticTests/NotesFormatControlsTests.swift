import AppKit
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
        NoteSlashHintPolicy.defaults = UserDefaults(suiteName: suite)!
        NoteSlashHintPolicy.resetForTesting()
    }

    override func tearDown() async throws {
        controlsList.forEach { $0.invalidate() }
        controlsList.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        NoteSlashHintPolicy.defaults = .standard
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
        for surface: NoteCommandSurface in [.selectionBar, .formatPopover, .noteMenu, .contextMenu, .menuBar, .shortcut] {
            let (controls, engine, textView) = make()
            controls.router.onRun = { command, from in routes[from] = command }
            let target = range("most people", textView)
            textView.setSelectedRange(target)
            switch surface {
            case .selectionBar, .formatPopover:
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

        var opened: Bool?
        controls.requestFormatPopover = { opened = $0 }
        textView.setSelectedRange(NSRange(location: 20, length: 0))
        controls.refresh()
        XCTAssertTrue(controls.handleKey(keyEvent("\t", "\t", keyCode: 48, .control, window: window)))
        XCTAssertEqual(opened, true, "without a bar, ⌃Tab opens Aa from the keyboard")
    }

    func testListsToggleBackToBodyAndAaWorksOnTheCaretParagraph() {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(NSRange(location: range("Annual", textView).location + 2, length: 0))
        controls.formatModel.run(.paragraph(.bullet), from: .formatPopover)
        XCTAssertEqual(engine.document().blocks[3].style, "bullet")
        controls.refreshSnapshot()
        XCTAssertEqual(controls.formatModel.snapshot.value(.paragraph(.bullet)), .on)
        XCTAssertEqual(controls.formatModel.snapshot.paragraph, .bullet, "the bar's style control says List")
        controls.formatModel.run(.paragraph(.bullet), from: .selectionBar)
        XCTAssertNil(engine.document().blocks[3].style, "choosing an on list returns it to Body")
        controls.formatModel.run(.paragraph(.heading(2)), from: .formatPopover)
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

    func testPopoverGridMovesAcrossRows() {
        let start = NoteGridIndex(row: 0, column: 4)
        XCTAssertEqual(NoteFormatPopoverGrid.move(start, by: .rightArrow), NoteGridIndex(row: 1, column: 0))
        XCTAssertEqual(NoteFormatPopoverGrid.move(NoteGridIndex(row: 1, column: 6), by: .downArrow), NoteGridIndex(row: 2, column: 5))
        XCTAssertEqual(NoteFormatPopoverGrid.move(NoteGridIndex(row: 1, column: 0), by: .leftArrow), NoteGridIndex(row: 0, column: 4))
        XCTAssertEqual(NoteFormatPopoverGrid.command(at: NoteGridIndex(row: 1, column: 4)), .mark(.link))
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
        settle { hosts(scrollView).contains { $0.menuLabel == "Tag suggestions" && !$0.isHidden } }
        let host = try XCTUnwrap(hosts(scrollView).first { $0.menuLabel == "Tag suggestions" })
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
        controls.requestFile = { asked = $0 }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("\n/ima", textView)
        XCTAssertEqual(controls.slashModel.items.map(\.kind), [.imageOrFile])
        XCTAssertTrue(controls.handleCommand(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(asked, true, "the open panel, for the / row")
        engine.cancelSlashFile()
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
        let host = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? AtticOverlayHostingView }.first { $0.acceptsKeyboard && $0.isInteractive })
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
        window.setContentSize(CGSize(width: 320, height: 160))
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

    func testTheHintShowsOnTheFirstThreeNewDraftsOnly() {
        var shown: [Bool] = []
        for _ in 0..<4 {
            let (controls, _, textView) = make(NoteDocument(blocks: [.text("")]), isNewDraft: true)
            type("Launch sync\n", textView)
            controls.refresh()
            shown.append(controls.isHintVisible)
        }
        XCTAssertEqual(shown, [true, true, true, false])
    }

    func testTypingSlashRetiresTheHint() {
        let (controls, _, textView) = make(NoteDocument(blocks: [.text("")]), isNewDraft: true)
        type("Plan\n", textView)
        controls.refresh()
        XCTAssertTrue(controls.isHintVisible)
        type("/", textView)
        controls.refresh()
        XCTAssertFalse(controls.isHintVisible)
        XCTAssertFalse(NoteSlashHintPolicy.shows(noteID: UUID(), isNewDraft: true), "learned: no more hints")
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

    func testEscInAaClosesAaOnlyAndIsUsedUp() {
        let (controls, _, textView) = make()
        let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                               backing: .buffered, defer: false)
        popover.isReleasedWhenClosed = false
        windows.append(popover)
        var closed = 0
        controls.closeFormatPopover = { closed += 1; controls.isFormatPopoverOpen = false }
        controls.isFormatPopoverOpen = true
        XCTAssertTrue(controls.handleKey(escape(in: popover)), "Esc in Aa's window is taken before it can travel on")
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(controls.handleKey(escape(in: popover)), "with Aa closed, it isn't the chain's")
        XCTAssertTrue(textView.window?.firstResponder === textView, "the note keeps the keyboard")

        // Aa open but the key still in the note (the pop-over didn't take
        // it): Esc closes Aa and never reaches the text view's "hide the panel".
        var panelHides = 0
        textView.escapeFallback = { panelHides += 1 }
        controls.isFormatPopoverOpen = true
        XCTAssertTrue(controls.handleKey(escape(in: textView.window!)))
        XCTAssertEqual(closed, 2)
        XCTAssertEqual(panelHides, 0)
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
