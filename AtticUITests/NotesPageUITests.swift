import AppKit
import XCTest

/// The native TextKit layers must display the asynchronously decoded image.
/// Offscreen cacheDisplay redraws the text and can conceal a stale layer.
final class NotesHistoryImageUITests: XCTestCase {
    func testU32HistoryImageAppearsWithinFiveSeconds() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_HISTORY_IMAGE_UAT"] == "1" else {
            throw XCTSkip("Requires the isolated history-image preview (run_local_ui_tests.zsh).")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["ATTIC_UI_TESTING": "1", "ATTIC_UI_TEST_NONKEY_REVEAL": "1",
            "ATTIC_UI_TEST_PAGE": "notes", "ATTIC_UI_TEST_NOTES_SCENE": "history-open"]
        app.launchArguments = ["-AtticUseNewNotesEditor", "YES", "-appearancePreference", "dark"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["notes-history-browser"].waitForExistence(timeout: 10))
        let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
        let deadline = Date().addingTimeInterval(5)
        var visible = false
        repeat {
            let capture = panel.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: capture.pngRepresentation))
            var blue = 0, teal = 0
            for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Screenshots carry the display profile. Recognize the two
                // saturated hues rather than assuming the PNG's raw RGB.
                if color.blueComponent - color.redComponent > 0.3,
                   color.blueComponent - color.greenComponent > 0.25 { blue += 1 }
                if color.greenComponent - color.redComponent > 0.3,
                   abs(color.blueComponent - color.greenComponent) < 0.08 { teal += 1 }
            } }
            visible = blue > 300 && teal > 300
            if visible || Date() >= deadline {
                let attachment = XCTAttachment(screenshot: capture)
                attachment.name = "U32-history-image"
                attachment.lifetime = .keepAlways
                add(attachment)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTAssertTrue(visible, "the old version's blue/teal image must appear within five seconds")
    }
}

/// The Phase 2 Notes page in the real app (slice 2's main flows): a new
/// note is kept when you leave and reopens where you left it; `#word` in
/// the title becomes a tag (one ⌘Z undoes it); Delete Note shows All notes
/// with an Undo toast that brings the note back; All notes searches and
/// opens a note. The document editor runs over the UI-test store (in memory).
final class NotesPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        require(noteText, timeout: 10, "the Notes page shows a note")
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
        if !condition() { print("NOTES_UI_TREE for '\(message)':\n\(app.debugDescription)") }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// Waits for an element; on failure the CI log gets the accessibility tree.
    private func require(_ element: XCUIElement, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let found = element.waitForExistence(timeout: timeout)
        if !found { print("NOTES_UI_TREE for '\(message)':\n\(app.debugDescription)") }
        XCTAssertTrue(found, message, file: file, line: line)
    }

    /// A fresh draft with the keyboard in it.
    private func newNote(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["notes-new-note"]
        require(button, "the New note button", file: file, line: line)
        button.click()
        waitFor(noteValue.isEmpty, "a new note starts empty (\(noteValue))", file: file, line: line)
        noteText.click()
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    private func showAllNotes() {
        let allNotes = app.buttons["notes-all-notes"]
        require(allNotes, "the All notes button")
        allNotes.click()
        require(app.descendants(matching: .any)["notes-library"], "All notes shows")
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
        require(row("Kyoto trip"), "the note is saved and listed")
    }

    func testAHashtagInTheTitleBecomesATagAndOneUndoBringsItBack() throws {
        newNote()
        app.typeText("Trip #kyoto ")
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Tag kyoto")).firstMatch
        require(tag, "the tag shows under the title")
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
        require(menu, "the ⋯ shows on a note with text")
        menu.click()
        let delete = app.menuItems["Delete Note"]
        require(delete, "the note's menu opens")
        delete.click()

        require(app.descendants(matching: .any)["notes-library"], "deleting the open note shows All notes")
        waitFor(!row("Delete me").exists, "the note left the list")
        let undo = app.buttons["Undo"]
        require(undo, "the Undo toast shows")
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
        require(row("Groceries"), "the first note is listed")
        require(row("Kyoto trip"), "the second note is listed")
        // The search is quiet: a magnifier on the label line opens the field.
        let magnifier = app.buttons["notes-library-search-button"]
        require(magnifier, "the magnifier on the All notes line")
        magnifier.click()
        // "Search 2 notes" (the Tasks page's Done search reads "Search done tasks").
        let search = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@",
                                                         "Search", "notes")).firstMatch
        require(search, "the search field takes the line")
        app.typeText("temples")
        waitFor(!row("Groceries").exists, "search narrows the list")
        require(row("Kyoto trip"), "the matching note stays")
        row("Kyoto trip").click()
        waitFor(noteText.exists && noteValue == "Kyoto trip\nTemples", "the note opens (\(noteValue))")
    }

    func testATagFiltersAllNotesAndASearchWithNoMatchesMakesTheNote() throws {
        newNote()
        app.typeText("Trip #kyoto ")
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Tag kyoto")).firstMatch
        require(tag, "the title shorthand made the tag")
        newNote()
        app.typeText("Groceries\nOat milk")
        waitFor(noteValue == "Groceries\nOat milk", "the untagged note typed")
        newNote()

        showAllNotes()
        let tab = app.buttons["notes-library-tag-kyoto"]
        require(tab, "the recent tag sits on the All notes line")
        tab.click()
        waitFor(!row("Groceries").exists, "the filter hides the untagged note")
        require(row("Trip"), "the tagged note stays")

        app.buttons["notes-library-search-button"].click()
        let search = app.textFields.matching(NSPredicate(format: "label == %@", "Search #kyoto")).firstMatch
        require(search, "the placeholder names the tag")
        app.typeText("osaka")
        let make = app.buttons["notes-library-new-from-search"]
        require(make, "no matches offers a note named for the search")
        make.click()
        waitFor(noteText.exists && noteValue == "osaka", "the new note has the search as its title (\(noteValue))")
        require(tag, "and the filter's tag")
    }
}
