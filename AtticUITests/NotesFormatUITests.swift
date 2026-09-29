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
        app.typeText("Pricing\nmost people only")
        selectLastWords(2)
        let bold = element("notes-format-bold")
        require(bold, "the bar shows over the selection")
        XCTAssertEqual(bold.value as? String, "off")
        bold.click()
        waitFor((element("notes-format-bold").value as? String) == "on", "Bold is on for the selection")
        waitFor(noteValue == "Pricing\nmost people only", "the text is unchanged (\(noteValue))")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitFor(!element("notes-format-bar").exists || !element("notes-format-bold").isHittable, "no selection, no bar")
    }

    func testControlTabReachesTheBarWithoutLeavingTheText() {
        app.typeText("Pricing\nmost people only")
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
        waitFor(noteValue == "Pricing\nmost people only!", "typing went on in the note (\(noteValue))")
    }

    func testCommandTOpensAaWhichStylesTheCaretParagraph() {
        app.typeText("Pricing\nBefore launch")
        app.typeKey("t", modifierFlags: .command)
        let heading = element("notes-aa-notes-format-heading2")
        require(heading, "Aa opens with ⌘T")
        heading.click()
        waitFor((element("notes-aa-notes-format-heading2").value as? String) == "current style", "Heading is current")
        app.typeKey(.escape, modifierFlags: [])
        waitFor(!element("notes-format-popover").exists, "Esc closes Aa")
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

    func testTypedDateReplacesTheCommand() {
        app.typeText("Pricing\nCall Sam /da")
        require(element("notes-slash-date"), "Date is offered")
        app.typeKey(.return, modifierFlags: [])
        let field = element("notes-date-field")
        require(field, "the date card")
        app.typeText("fri")
        require(element("notes-date-suggestion"), "fri reads as a day")
        app.typeKey(.return, modifierFlags: [])
        waitFor(!element("notes-date-card").exists, "the card closes")
        waitFor(!noteValue.contains("/da"), "the chip replaced /da (\(noteValue))")
    }

    func testShiftCommandKOpensTheLinkCard() {
        app.typeText("Pricing\nsee the docs")
        selectLastWords(1)
        app.typeKey("k", modifierFlags: [.command, .shift])
        require(element("notes-link-field"), "⇧⌘K opens the link card")
        app.typeText("example.com")
        app.typeKey(.return, modifierFlags: [])
        waitFor(!element("notes-link-card").exists, "Return applies and closes")
        waitFor(noteValue == "Pricing\nsee the docs", "the text is unchanged (\(noteValue))")
    }

    func testRightClickHasFormatAndInsert() {
        app.typeText("Pricing\nmost people")
        noteText.rightClick()
        let format = app.menuItems["Format"]
        require(format, "right-click › Format")
        XCTAssertTrue(app.menuItems["Insert"].exists)
        format.hover()
        require(app.menuItems["Bulleted List"], "every Format row")
        app.menuItems["Bulleted List"].click()
        app.typeText("!")
        waitFor(noteValue.hasSuffix("most people!"), "the list applied and the text kept the keyboard (\(noteValue))")
    }
}
