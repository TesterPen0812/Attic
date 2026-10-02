import AppKit
import XCTest

/// The lists' edges on screen (owner, 2026-10-01: the system's soft scroll
/// edge). Round 13's clean cut is a preview identity's only, and CI runs the
/// official identity, so only the system edge is captured here. The window server draws the
/// system's edge effect, so these captures are the evidence the hosted tests
/// cannot give: rows scrolled under the tabs, the header's buttons and the
/// add bar, in Light Solid, Light Glass and Dark Glass. Each capture is
/// attached to the result (and saved with the visual UAT when CI asks).
final class ScrollEdgeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testCapturesRowsPassingUnderTheControls() throws {
        for (surface, mode) in [("solid", "light"), ("glass", "light"), ("glass", "dark")] {
            let app = XCUIApplication()
            app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
            app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
            app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", surface]
            app.launch()
            let pin = app.buttons["panel-pin-button"]
            XCTAssertTrue(pin.waitForExistence(timeout: 8), "\(surface) \(mode): the panel shows")
            XCTAssertTrue(app.buttons["tasks-page-now"].waitForExistence(timeout: 4), "the tabs are there")
            let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
            let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            middle.hover()
            // Either sign: one of the two leaves rows under the tabs.
            for (index, delta) in [CGFloat(-140), 280].enumerated() {
                middle.scroll(byDeltaX: 0, deltaY: delta)
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                save(panel.screenshot(), name: "scroll-edges-\(surface)-\(mode)-soft-\(index)")
            }
            app.terminate()
        }
    }

    /// Far down the long list, rows lie under Find and the add bar: both
    /// still take their clicks (deep review P2-02's hit points), and a query
    /// typed from there shows its match and its count (P2-01: the list
    /// stayed far down, past the matches, and showed nothing). The strip
    /// and Find over the scrolled rows are captured for the owner's look.
    func testFindAndTheAddBarTakeClicksOverScrolledRows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
        app.launchArguments += ["-appearancePreference", "light", "-panelSurfaceStyle", "glass"]
        app.launch()
        defer { app.terminate() }
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pin.waitForExistence(timeout: 8), "the panel shows")
        let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Finalize launch checklist,")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 4), "the long list is shown")
        let resting = first.frame.minY
        let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        middle.hover()
        // Down the list, whichever way the Mac's scroll direction goes.
        for delta in [CGFloat(-600), 1_200] where !(first.exists && first.frame.minY < resting - 200) && first.exists {
            middle.scroll(byDeltaX: 0, deltaY: delta)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        XCTAssertTrue(!first.exists || first.frame.minY < resting - 200, "the list is far down (\(first.frame.minY), resting \(resting))")

        // The add bar, over the rows: hittable, and a click gives it the keyboard.
        let addBar = app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
        XCTAssertTrue(addBar.waitForExistence(timeout: 3))
        XCTAssertTrue(addBar.isHittable, "the add bar has a hit point over scrolled rows: \(addBar.frame)")
        addBar.click()
        XCTAssertTrue(waitFor { (addBar.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "the click gives the add bar the keyboard")
        app.typeText("Water the plants tomorrow #home !!")
        XCTAssertTrue(waitFor { (addBar.value as? String)?.contains("Water the plants") == true }, "typing lands in the add bar")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(panel.screenshot(), name: "scroll-edges-glass-light-strip-over-rows")
        addBar.typeKey("a", modifierFlags: .command)
        addBar.typeKey(.delete, modifierFlags: [])

        // Find, over the rows: its button and its field take their clicks.
        let findButton = app.buttons["tasks-find-button"]
        XCTAssertTrue(findButton.waitForExistence(timeout: 3))
        XCTAssertTrue(findButton.isHittable, "Find's button has a hit point over scrolled rows")
        findButton.click()
        let find = app.descendants(matching: .any).matching(identifier: "tasks-find").firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 3), "Find opens")
        XCTAssertTrue(find.isHittable, "Find's field has a hit point over scrolled rows: \(find.frame)")
        find.click()
        app.typeText("Ship")
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Ship appearance PR,")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 3), "the match is listed")
        XCTAssertTrue(waitFor { match.isHittable && panel.frame.contains(CGPoint(x: match.frame.midX, y: match.frame.midY)) },
                      "and in view, not past the list's end: \(match.frame)")
        let count = app.descendants(matching: .any).matching(identifier: "tasks-find-count").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 3), "the count shows")
        let counted = [count.label, count.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(counted.contains("1 of "), "the count says one: \(counted)")
        save(panel.screenshot(), name: "scroll-edges-glass-light-find-from-far-down")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return condition()
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let path = ProcessInfo.processInfo.environment["ATTIC_VISUAL_UAT_DIRECTORY"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
