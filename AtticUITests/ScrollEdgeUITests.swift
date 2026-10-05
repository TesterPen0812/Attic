import AppKit
import XCTest

/// The lists' edges on screen: Clean cut with A15's scroll-under fade (owner,
/// 2026-10-04, replacing D1's fade before the controls): rows pass under the
/// controls faintly, never readably. The system soft edge is a
/// preview identity's choice only, and CI runs the official identity, which
/// ignores `ATTIC_UI_TEST_SCROLL_EDGES`, so every capture here is Clean cut,
/// whatever `edge` a fixture names. These captures are the evidence the
/// hosted tests cannot give: rows scrolled under the tabs, the header's
/// buttons and the add bar, in Light Solid, Light Glass and Dark Glass. Each
/// capture is attached to the result (and saved with the visual UAT when CI
/// asks).
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

    /// Window-server pixels (A15, replacing D1): scrolling changes row ink in
    /// the body, and rows pass under the tabs and the strip pills faintly:
    /// some ink changes there, never at a readable strength.
    func testRowsPassFaintlyAndNeverReadablyUnderTheTabsAndMetadataPills() throws {
        for (surface, mode) in [("solid", "light"), ("glass", "light"), ("glass", "dark")] {
            let app = launchPixelFixture(surface: surface, mode: mode, edge: "soft")
            defer { app.terminate() }
            let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
            let field = app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isHittable)
            field.click()
            app.typeText("Water plants tomorrow #home !!")
            let date = app.buttons["composer-date"]
            XCTAssertTrue(date.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["composer-tag"].isHittable)
            XCTAssertTrue(app.buttons["composer-priority"].isHittable)
            let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            middle.hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let tabs = app.buttons["tasks-page-now"].frame.union(app.buttons["tasks-page-backlog"].frame)
                .union(app.buttons["tasks-page-done"].frame)
            let pills = date.frame.union(app.buttons["composer-tag"].frame).union(app.buttons["composer-priority"].frame)
            let before = try bitmap(panel)
            save(panel.screenshot(), name: "d1-\(surface)-\(mode)-controls-reference")
            for identifier in ["tasks-page-now", "tasks-page-backlog", "tasks-page-done", "panel-pin-button", "panel-section-picker"] {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.isHittable,
                              "\(identifier) retains a hit point")
            }
            let body = CGRect(x: panel.frame.minX + 75, y: tabs.maxY + 25,
                              width: panel.frame.width - 110, height: pills.minY - tabs.maxY - 50)
            // One sign advances this list regardless of natural scrolling.
            var moved = false
            for delta in [CGFloat(-170), 340] {
                middle.scroll(byDeltaX: 0, deltaY: delta)
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let after = try bitmap(panel)
                let movement = changedFraction(before, after, in: body, panel: panel.frame)
                guard movement > 0.02 else { continue }
                moved = true
                // Faint: the lower bound is what separates this from a clip
                // (D1's cut), so each control band has its own.
                XCTAssertGreaterThan(changedFraction(before, after, in: tabs, panel: panel.frame), 0.0005,
                                     "\(surface) \(mode): rows show faintly under the tabs labels")
                XCTAssertGreaterThan(changedFraction(before, after, in: pills, panel: panel.frame), 0.0005,
                                     "\(surface) \(mode): rows show faintly under the metadata pills")
                // Never readable: no pixel changes by a text-strength step.
                XCTAssertLessThan(changedFraction(before, after, in: tabs, panel: panel.frame, threshold: 0.35), 0.002,
                                  "\(surface) \(mode): never readable under the tabs labels")
                XCTAssertLessThan(changedFraction(before, after, in: pills, panel: panel.frame, threshold: 0.35), 0.002,
                                  "\(surface) \(mode): never readable under the metadata pills")
                save(panel.screenshot(), name: "a15-\(surface)-\(mode)-controls-faint")
            }
            XCTAssertTrue(moved, "positive control: scrolling visibly changed row ink in the body")
        }
    }

    /// Clean cut is the unfaded reference, available only in a strict
    /// preview test identity. No empty capture can pass this comparison.
    func testTheFirstRowAtRestMatchesTheUnfadedCleanReference() throws {
        var reference: NSBitmapImageRep?
        var referenceRect: CGRect?
        for edge in ["clean", "soft"] {
            let app = launchPixelFixture(surface: "glass", mode: "light", edge: edge)
            let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
            let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Finalize launch checklist,")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.55)).hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let rect = first.frame.insetBy(dx: 55, dy: 1)
            let image = try bitmap(panel)
            XCTAssertGreaterThan(darkPixels(image, in: rect, panel: panel.frame), 80, "a real resting row was rendered")
            if let reference, let referenceRect {
                XCTAssertEqual(rect.minY - panel.frame.minY, referenceRect.minY, accuracy: 0.5)
                XCTAssertLessThan(changedFraction(reference, image, in: rect, panel: panel.frame), 0.003,
                                  "native soft edge does not fade the first row at rest")
            } else {
                reference = image
                referenceRect = rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            }
            save(panel.screenshot(), name: "d1-at-rest-\(edge)")
            app.terminate()
        }
    }

    private func launchPixelFixture(surface: String, mode: String, edge: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
        app.launchEnvironment["ATTIC_UI_TEST_SCROLL_EDGES"] = edge
        app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", surface]
        app.launch()
        XCTAssertTrue(app.buttons["panel-pin-button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tasks-page-now"].waitForExistence(timeout: 5))
        return app
    }

    private func bitmap(_ panel: XCUIElement) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: panel.screenshot().pngRepresentation))
    }

    private func sample(_ image: NSBitmapImageRep, in rect: CGRect, panel: CGRect,
                        _ visit: (Int, Int, NSColor) -> Void) -> Int {
        let area = rect.offsetBy(dx: -panel.minX, dy: -panel.minY).intersection(CGRect(origin: .zero, size: panel.size))
        guard !area.isNull, !area.isEmpty else { return 0 }
        let scale = CGFloat(image.pixelsWide) / panel.width
        var total = 0
        for y in stride(from: max(0, Int(area.minY * scale)), to: min(Int(area.maxY * scale), image.pixelsHigh), by: 2) {
            for x in stride(from: max(0, Int(area.minX * scale)), to: min(Int(area.maxX * scale), image.pixelsWide), by: 2) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                visit(x, y, color)
            }
        }
        return total
    }

    private func darkPixels(_ image: NSBitmapImageRep, in rect: CGRect, panel: CGRect) -> Int {
        var ink = 0
        _ = sample(image, in: rect, panel: panel) { _, _, color in
            if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65 { ink += 1 }
        }
        return ink
    }

    private func changedFraction(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect, panel: CGRect,
                                 threshold: CGFloat = 0.05) -> Double {
        var changed = 0
        let total = sample(b, in: rect, panel: panel) { x, y, color in
            guard let other = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return }
            if max(abs(color.redComponent - other.redComponent), abs(color.greenComponent - other.greenComponent),
                   abs(color.blueComponent - other.blueComponent)) > threshold { changed += 1 }
        }
        XCTAssertGreaterThan(total, 100, "a nonempty pixel sample")
        return Double(changed) / Double(max(total, 1))
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
