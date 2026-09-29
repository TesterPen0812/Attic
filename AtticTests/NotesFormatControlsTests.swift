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
            if let found = find(title, in: command.submenu) { return found }
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
        XCTAssertEqual(menu[0].submenu.map(\.title), ["Image or File…", "Date…", "Divider"])
        let format = menu[1].submenu
        for command in NoteCommandCatalog.formatSections.flatMap({ $0 }) {
            XCTAssertNotNil(format.first { $0.title == NoteCommandCatalog.menuTitle(command) }, "Format lists \(command)")
        }
        XCTAssertEqual(find("Bulleted List", in: menu)?.isChecked, true, "the current list is checked")
        XCTAssertEqual(find("Bold", in: menu)?.shortcut, KeyboardShortcut("b", modifiers: .command))
        XCTAssertEqual(find("Checklist", in: menu)?.shortcut, KeyboardShortcut("9", modifiers: [.command, .shift]))
        XCTAssertEqual(find("Check or Uncheck", in: menu)?.shortcut, KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(find("Move Line Up", in: menu)?.shortcut, KeyboardShortcut(.upArrow, modifiers: [.command, .option]))
        XCTAssertNil(find("Quote", in: menu)?.shortcut, "⌥⌘Q is Quit and Keep Windows: left unbound")
        XCTAssertNil(find("Mono", in: menu)?.shortcut, "⌥⌘M is Minimize All: left unbound")
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
        XCTAssertTrue(textView.string.hasSuffix("/da"), "the command stays until a date is chosen")
        controls.cancelCard()
        XCTAssertNil(controls.cardModel.card)
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

    // MARK: Performance (the engine's 5,000-line stress note)

    /// Keystrokes with the controls installed read no state; a selection's
    /// snapshot and a select-all are timed for the report.
    func testControlsAddNoWorkPerKeystrokeOnAStressNote() throws {
        var blocks: [NoteBlock] = [.text("Stress")]
        for index in 0..<5_000 {
            blocks.append(index % 50 == 10 ? .checklist("Item \(index)")
                          : .text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
        }
        let (controls, _, textView) = make(NoteDocument(blocks: blocks))
        let middle = range("Line 2501 ", textView).location
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.displayIfNeeded()
        spin()
        let before = controls.snapshotCount
        var samples: [Double] = []
        for character in "the quick brown fox jumps over the lazy dog again and again!" {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.displayIfNeeded()
            spin()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        XCTAssertEqual(controls.snapshotCount, before, "typing reads no format state")
        func ms(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        textView.setSelectedRange(range("Line 2600 with some ordinary words", textView))
        let sentence = ms { controls.refresh() }
        XCTAssertTrue(controls.formatModel.barShown)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        let all = ms { controls.refresh() }
        let sorted = samples.sorted()
        let report = String(format: "NOTE-FORMAT-PERF keystroke+runloop median %.2f ms p95 %.2f ms; bar state for a sentence %.2f ms; select-all %.1f ms",
                            sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sentence, all)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
    }
}
