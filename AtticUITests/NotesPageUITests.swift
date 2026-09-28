import AppKit
import XCTest

/// The Phase 2 Notes page in the real app (slice 2's main flows): a new
/// note is kept when you leave and reopens where you left it; `#word` in
/// the title becomes a tag (one ⌘Z undoes it); Delete Note shows All notes
/// with an Undo toast that brings the note back; All notes searches and
/// opens a note. The page runs with the new editor switched on, over the
/// UI-test store (in memory).
final class NotesPageUITests: XCTestCase {
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
        XCTAssertTrue(noteText.waitForExistence(timeout: 10), "the Notes page shows a note")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: Helpers

    private var noteText: XCUIElement { app.textViews["note-text"] }
    private var noteValue: String { (noteText.value as? String) ?? "" }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 6, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// A fresh draft with the keyboard in it.
    private func newNote(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["notes-new-note"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        button.click()
        waitFor(noteValue.isEmpty, "a new note starts empty (\(noteValue))", file: file, line: line)
        noteText.click()
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func showAllNotes() {
        let allNotes = app.buttons["notes-all-notes"]
        XCTAssertTrue(allNotes.waitForExistence(timeout: 5))
        allNotes.click()
        XCTAssertTrue(app.descendants(matching: .any)["notes-library"].waitForExistence(timeout: 5), "All notes shows")
    }

    // MARK: Flows

    func testANewNoteIsKeptWhenYouLeaveAndReopensWhereYouLeftIt() throws {
        newNote()
        app.typeText("Kyoto trip\nBook the ryokan")
        waitFor(noteValue == "Kyoto trip\nBook the ryokan", "typed (\(noteValue))")

        app.typeKey("1", modifierFlags: .command)
        waitFor(app.buttons["panel-section-tasks"].isSelected, "on Tasks")
        app.typeKey("2", modifierFlags: .command)
        waitFor(app.buttons["panel-section-notes"].isSelected, "back on Notes")
        waitFor(noteValue == "Kyoto trip\nBook the ryokan", "Notes reopens the note you left (\(noteValue))")
        // The caret is where it was: typing continues the body.
        app.typeText(" soon")
        waitFor(noteValue == "Kyoto trip\nBook the ryokan soon", "typing continues where you were (\(noteValue))")

        showAllNotes()
        XCTAssertTrue(row("Kyoto trip").waitForExistence(timeout: 5), "the note is saved and listed")
    }

    func testAHashtagInTheTitleBecomesATagAndOneUndoBringsItBack() throws {
        newNote()
        app.typeText("Trip #kyoto ")
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Tag kyoto")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 5), "the tag shows under the title")
        waitFor(noteValue == "Trip ", "the hashtag left the title (\(noteValue))")

        app.typeKey("z", modifierFlags: .command)
        waitFor(noteValue == "Trip #kyoto", "one ⌘Z brings the text back (\(noteValue))")
        waitFor(!tag.exists, "and removes the tag")
    }

    func testDeletingANoteShowsAllNotesAndUndoBringsItBack() throws {
        newNote()
        app.typeText("Delete me\nNot really")
        waitFor(noteValue == "Delete me\nNot really", "typed")
        let menu = app.buttons["notes-menu-button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the ⋯ shows on a note with text")
        menu.click()
        let delete = app.menuItems["Delete Note"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the note's menu opens")
        delete.click()

        XCTAssertTrue(app.descendants(matching: .any)["notes-library"].waitForExistence(timeout: 5),
                      "deleting the open note shows All notes")
        waitFor(!row("Delete me").exists, "the note left the list")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "the Undo toast shows")
        undo.click()
        waitFor(noteText.exists && noteValue == "Delete me\nNot really", "Undo brings the note back (\(noteValue))")
    }

    func testAllNotesSearchesAndOpensANote() throws {
        newNote()
        app.typeText("Groceries\nOat milk")
        waitFor(noteValue == "Groceries\nOat milk", "first note typed")
        newNote()
        app.typeText("Kyoto trip\nTemples")
        waitFor(noteValue == "Kyoto trip\nTemples", "second note typed")
        newNote()

        showAllNotes()
        XCTAssertTrue(row("Groceries").waitForExistence(timeout: 5))
        XCTAssertTrue(row("Kyoto trip").exists)
        let search = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "Search")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("temples")
        waitFor(!row("Groceries").exists, "search narrows the list")
        XCTAssertTrue(row("Kyoto trip").waitForExistence(timeout: 5), "the matching note stays")
        row("Kyoto trip").click()
        waitFor(noteText.exists && noteValue == "Kyoto trip\nTemples", "the note opens (\(noteValue))")
    }
}
