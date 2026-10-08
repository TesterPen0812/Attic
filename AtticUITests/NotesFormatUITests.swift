import AppKit
import XCTest

/// Slice 3a in the real app: the selection bar by pointer and ⌃Tab, Aa by
/// ⌘T, the `/` list by keys, the date card by typing, the link card by
/// ⇧⌘K, and the right-click Format rows. The keyboard stays in the note
/// throughout (the bar never takes it).
final class NotesFormatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["-AtticUseNewNotesEditor", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        require(noteText, timeout: 10, "the Notes page shows a note")
        let button = app.buttons["notes-new-note"]
        require(button, "the New note button")
        button.click()
        waitFor(noteValue.isEmpty, "a new note starts empty (\(noteValue))")
        // The new note's text view replaces the old one: wait until the new
        // one is on screen before clicking it (the first launch is slowest).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !(noteText.exists && noteText.isHittable) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        require(noteText, "the new note's text")
        noteText.click()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private var noteText: XCUIElement { app.textViews["note-text"] }
    private var noteValue: String { (noteText.value as? String) ?? "" }
    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 6, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !condition() { print("NOTES_FORMAT_UI_TREE for '\(message)':\n\(app.debugDescription)") }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func require(_ element: XCUIElement, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let found = element.waitForExistence(timeout: timeout)
        if !found { print("NOTES_FORMAT_UI_TREE for '\(message)':\n\(app.debugDescription)") }
        XCTAssertTrue(found, message, file: file, line: line)
    }

    /// Selects the last `words` words with ⌥⇧←.
    private func selectLastWords(_ words: Int) {
        for _ in 0..<words { app.typeKey(.leftArrow, modifierFlags: [.option, .shift]) }
    }

    func testTheBarAppearsOverASelectionAndBoldsIt() {
        app.typeText("Pricing\nMost people only")
        selectLastWords(2)
        let bold = element("notes-format-bold")
        require(bold, "the bar shows over the selection")
        XCTAssertEqual(bold.value as? String, "off")
        bold.click()
        waitFor((element("notes-format-bold").value as? String) == "on", "Bold is on for the selection")
        waitFor(noteValue == "Pricing\nMost people only", "the text is unchanged (\(noteValue))")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitFor(!element("notes-format-bar").exists || !element("notes-format-bold").isHittable, "no selection, no bar")
    }

    func testControlTabReachesTheBarWithoutLeavingTheText() {
        app.typeText("Pricing\nMost people only")
        selectLastWords(1)
        require(element("notes-format-bar"), "the bar")
        app.typeKey(.tab, modifierFlags: .control)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitFor((element("notes-format-italic").value as? String) == "on", "⌃Tab → → Return pressed Italic")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeText("!")
        waitFor(noteValue == "Pricing\nMost people only!", "typing went on in the note (\(noteValue))")
    }

    /// OD-7 / P2-A12-1 / A17: ⌃Tab leaves the text for All notes, Aa and New
    /// note, and the fourth stop is the text again, caret where it was, so
    /// typing goes into the note; ⌃⇧Tab does the same the other way round.
    /// The fourth press is followed by typing at once (no wait): SwiftUI's late
    /// focus update must not drop the keys.
    func testControlTabGoesRoundTheFooterAndBackIntoTheTextBothWays() {
        app.typeText("Pricing\nBody")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        func goRound(_ flags: XCUIElement.KeyModifierFlags) {
            for stop in 0..<4 {
                app.typeKey(.tab, modifierFlags: flags)
                // SwiftUI moves its focus a turn after the key; the last
                // press, back into the text, is not waited for.
                if stop < 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
            }
        }
        goRound(.control)
        app.typeText("!")
        waitFor(noteValue == "Pricing\nBo!dy", "⌃Tab ×4 came back into the text, caret kept, typing at once (\(noteValue))")
        goRound([.control, .shift])
        app.typeText("?")
        waitFor(noteValue == "Pricing\nBo!?dy", "⌃⇧Tab ×4 came back into the text, caret kept, typing at once (\(noteValue))")
    }

    /// A17: a caret move straight after the round trip is the user's, and the
    /// return never puts the caret back where it was.
    func testACaretMoveRightAfterTheRoundTripIsNotUndone() {
        app.typeText("Pricing\nBody")
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        for stop in 0..<4 {
            app.typeKey(.tab, modifierFlags: .control)
            if stop < 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        }
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeText("!")
        waitFor(noteValue == "Pricing\nB!ody", "the caret the user moved to kept (\(noteValue))")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("?")
        waitFor(noteValue == "Pricing\nB!?ody", "and nothing moved it afterwards (\(noteValue))")
    }

    /// A17: a click on another control while the keyboard is on its way back
    /// takes the keyboard there, and the text does not take it again.
    func testAClickOnAnotherControlRightAfterTheRoundTripKeepsTheKeyboardThere() {
        app.typeText("Pricing\nBody")
        for stop in 0..<4 {
            app.typeKey(.tab, modifierFlags: .control)
            if stop < 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        }
        let allNotes = element("notes-all-notes")
        require(allNotes, "All notes")
        allNotes.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        waitFor(element("notes-library").exists, "All notes opened")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(element("notes-library").exists, "and the note's text did not take the page back")
    }

    func testCommandTOpensTheFormatRowWhichStylesTheCaretParagraph() {
        app.typeText("Pricing\nBefore launch")
        app.typeKey("t", modifierFlags: .command)
        let pill = element("notes-format-row-style")
        require(pill, "⌘T turns the bottom row into the format row")
        XCTAssertFalse(element("notes-new-note").exists, "New note steps aside")
        pill.click()
        let heading = element("notes-format-row-notes-format-heading2")
        require(heading, "the style list")
        // E1 exposes menu-item semantics, but is a custom dropdown, not an
        // NSMenu. XCUIElement.click() otherwise attempts native menu traversal
        // and waits for a menu-open notification that this view never sends.
        XCTAssertTrue(heading.isHittable, "Heading has a real hit point")
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        waitFor((element("notes-format-row-style").value as? String) == "Heading", "Heading is current")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!element("notes-format-row").exists, "Esc closes the format row")
        require(element("notes-new-note"), "and the bottom row is back")
        app.typeText(" soon")
        waitFor(noteValue == "Pricing\nBefore launch soon", "the keyboard is back in the note (\(noteValue))")
    }

    func testSlashListReturnPicksAndEscLeavesTheSlash() {
        app.typeText("Pricing\n/")
        require(element("notes-slash-list"), "the / list")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!element("notes-slash-list").exists, "Esc closes it")
        waitFor(noteValue == "Pricing\n/", "and leaves the / (\(noteValue))")
        app.typeKey(.delete, modifierFlags: [])
        app.typeText("/che")
        require(element("notes-slash-checklist"), "filtered to Checklist")
        app.typeKey(.return, modifierFlags: [])
        waitFor(!noteValue.contains("/"), "Return takes the row and removes /che (\(noteValue))")
        app.typeText("Book the venue")
        waitFor(noteValue.hasSuffix("Book the venue"), "typing continues on the checklist line")
    }

    /// A22: the owner's exact keys, including typing after slash acceptance.
    private func checkSlashTyping(_ query: String, command: String, value: String) {
        app.typeText("Title\n" + query)
        require(element("notes-slash-list"), "the slash list")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Styled text")
        waitFor(noteValue.hasSuffix("Styled text") && !noteValue.contains(query), "query replaced, next text typed")
        // Move within the typed text before reading Aa: inspect the actual
        // paragraph, rather than the pending typing attributes after choosing.
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey("t", modifierFlags: .command)
        let row = element("notes-format-row")
        require(row, "the format row opens over the typed paragraph")
        if value == "current style" {
            waitFor((element("notes-format-row-style").value as? String) == "Heading", "the typed paragraph is " + command)
        } else {
            let option = row.descendants(matching: .any)["notes-format-" + command]
            require(option, "the row exposes the typed paragraph's list type")
            waitFor((option.value as? String) == value, "the typed paragraph is " + command)
        }
    }

    func testSlashHeadingReturnThenTypingProducesHeading() {
        checkSlashTyping("/heading", command: "heading2", value: "current style")
    }

    func testSlashQuoteReturnThenTypingProducesQuote() {
        checkSlashTyping("/quote", command: "quote", value: "on")
    }

    func testSlashListReturnThenTypingProducesList() {
        checkSlashTyping("/list", command: "bullet", value: "on")
    }

    func testTypedDateReplacesTheCommand() {
        app.typeText("Pricing\nCall Sam /da")
        require(element("notes-slash-date"), "Date is offered")
        app.typeKey(.return, modifierFlags: [])
        require(element("notes-date-card"), "the date card")
        app.typeText("fri")
        require(element("date-suggestion"), "fri reads as a day, suggested above the month")
        app.typeKey(.return, modifierFlags: [])
        waitFor(!element("notes-date-card").exists, "the card closes")
        waitFor(!noteValue.contains("/da"), "the chip replaced /da (\(noteValue))")
    }

    func testShiftCommandKOpensTheLinkCard() {
        app.typeText("Pricing\nSee the docs")
        selectLastWords(1)
        app.typeKey("k", modifierFlags: [.command, .shift])
        require(element("notes-link-field"), "⇧⌘K opens the link card")
        app.typeText("example.com")
        app.typeKey(.return, modifierFlags: [])
        waitFor(!element("notes-link-card").exists, "Return applies and closes")
        waitFor(noteValue == "Pricing\nSee the docs", "the text is unchanged (\(noteValue))")
    }

    func testRightClickHasFormatAndInsert() {
        app.typeText("Pricing\nMost people")
        noteText.rightClick()
        let format = app.menuItems["Format"]
        require(format, "right-click › Format")
        XCTAssertTrue(app.menuItems["Insert"].exists)
        format.hover()
        require(app.menuItems["Bulleted List"], "every Format row")
        app.menuItems["Bulleted List"].click()
        app.typeText("!")
        waitFor(noteValue.hasSuffix("Most people!"), "the list applied and the text kept the keyboard (\(noteValue))")
    }
}
