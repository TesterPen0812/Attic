import AppKit
import XCTest

/// Clean cut with the owner's revised 2026-10-06 scroll-under rule:
/// full content under glass, short fades behind plain labels and at edges. The system soft edge is a
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

    /// Far down the long list, rows lie under Find and the "+": both
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

        // "+", over the rows: hittable, and a click opens the card with the
        // keyboard in its title (Accepted 2026-10-29 "The '+' card": the
        // card replaced the add bar).
        let plus = app.buttons["tasks-new-task"]
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        XCTAssertTrue(plus.isHittable, "\"+\" has a hit point over scrolled rows: \(plus.frame)")
        plus.click()
        let addBar = app.descendants(matching: .any).matching(identifier: "composer-title").firstMatch
        XCTAssertTrue(addBar.waitForExistence(timeout: 3), "the card opens")
        XCTAssertTrue(waitFor { (addBar.value(forKey: "hasKeyboardFocus") as? Bool) == true }, "the card's title has the keyboard")
        app.typeText("Water the plants tomorrow #home !!")
        XCTAssertTrue(waitFor { (addBar.value as? String)?.contains("Water the plants") == true }, "typing lands in the title")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(panel.screenshot(), name: "scroll-edges-glass-light-card-over-rows")
        addBar.typeKey("a", modifierFlags: .command)
        addBar.typeKey(.delete, modifierFlags: [])
        // Escape closes the card (Accepted: it keeps the draft, empty here).
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(addBar.waitForNonExistence(timeout: 3), "Escape closes the card")

        // Find, over the rows: its button and its field take their clicks.
        let findButton = app.buttons["tasks-find-button"]
        XCTAssertTrue(findButton.waitForExistence(timeout: 3))
        if !findButton.isHittable {
            atticHitReport(app, findButton, "find")
        }
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

    /// Rows scroll under the floating glass, and the controls over them stay
    /// put and keep their hit points: the tabs and Pin in the top row, the
    /// page switch and "+" in the bottom bar (Accepted 2026-10-29 "Top row and
    /// bottom bar"; 2026-10-31 "Shared controls stay still while pages
    /// switch"). The tabs are the 21 pt chips of "One size". Keep the pixel
    /// movement positive control and the original hang sequence.
    func testRowsScrollUnderFloatingGlassWithoutMovingTheControls() throws {
        for (surface, mode) in [("solid", "light"), ("glass", "light"), ("glass", "dark")] {
            let app = launchPixelFixture(surface: surface, mode: mode, edge: "soft")
            defer { app.terminate() }
            let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
            // The launch is an explicit open, which opens the "+" card; its
            // scrim covers the rows. Escape closes it (Accepted "The '+' card").
            let card = app.descendants(matching: .any).matching(identifier: "composer-title").firstMatch
            if card.waitForExistence(timeout: 2) {
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(card.waitForNonExistence(timeout: 3), "Escape closes the card")
            }
            let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            middle.hover()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Finalize launch checklist,")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5), "the long list is shown")
            let firstY = first.frame.minY
            let identifiers = ["tasks-page-now", "tasks-page-backlog", "tasks-page-done", "panel-pin-button",
                               "panel-section-picker", "tasks-new-task"]
            let controls = identifiers.map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            let frames = controls.map(\.frame)
            for (index, control) in controls.enumerated() where !control.isHittable {
                XCTFail("\(identifiers[index]) has a hit point at rest: " + atticHitReport(app, control, identifiers[index]))
            }
            let tabs = frames[0].union(frames[1]).union(frames[2])
            XCTAssertEqual(tabs.height, 21, accuracy: 0.5, "the tabs are the top row's 21 pt chips")
            let bottomBar = frames[4].union(frames[5])
            let body = CGRect(x: panel.frame.minX + 75, y: tabs.maxY + 25,
                              width: panel.frame.width - 110, height: bottomBar.minY - tabs.maxY - 50)
            let before = try bitmap(panel)
            save(panel.screenshot(), name: "floating-glass-\(surface)-\(mode)-reference")
            var moved = false
            for delta in [CGFloat(-170), 11, 11, 340] {
                middle.scroll(byDeltaX: 0, deltaY: delta)
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let after = try sampledIfStalled(app, step: "\(surface)-\(mode)-\(delta)") { try bitmap(panel) }
                if changedFraction(before, after, in: body, panel: panel.frame) > 0.02,
                   !first.exists || abs(first.frame.minY - firstY) > 1 {
                    moved = true
                }
                for (index, control) in controls.enumerated() {
                    let actual = control.frame, expected = frames[index]
                    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, identifiers[index])
                    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, identifiers[index])
                    XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, identifiers[index])
                    XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, identifiers[index])
                    if !control.isHittable {
                        XCTFail("\(identifiers[index]) keeps its hit point after scrolling: " + atticHitReport(app, control, identifiers[index]))
                    }
                }
                save(panel.screenshot(), name: "floating-glass-\(surface)-\(mode)-\(delta)")
            }
            XCTAssertTrue(moved, "positive control: scrolling moves both row geometry and rendered ink")
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

    /// PR #11: on CI this step's snapshot found the app's main thread busy
    /// for minutes after the third scroll on macOS 26.6.2 at 1×. If the
    /// call has not returned in 20 s, sample the
    /// app (5 s), print the main thread's stack and attach the whole sample.
    private func sampledIfStalled<T>(_ app: XCUIApplication, step: String, _ body: () throws -> T) throws -> T {
        let pid = (app.responds(to: NSSelectorFromString("processID")) ? app.value(forKey: "processID") as? Int32 : nil) ?? 0
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("attic-scroll-stall-\(step).txt")
        try? FileManager.default.removeItem(at: output)
        let sampler = DispatchWorkItem {
            guard pid > 0 else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "5", "-mayDie", "-file", output.path]
            try? process.run()
            process.waitUntilExit()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: sampler)
        defer {
            sampler.cancel()
            if FileManager.default.fileExists(atPath: output.path) {
                sampler.wait()
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                let main = text.components(separatedBy: "\n").drop { !$0.contains("Thread_") || !$0.contains("main-thread") }
                print("ATTIC_SCROLL_STALL step=\(step) pid=\(pid)\n" + main.prefix(160).joined(separator: "\n"))
                let attachment = XCTAttachment(contentsOfFile: output)
                attachment.name = "scroll-stall-sample-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        return try body()
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

/// Diagnostics for "Not hittable": the app's own probe (DEBUG, the panel's
/// "attic-hit-probe") runs the system's accessibility hit test at each
/// watched control's and open menu item's centre and says what it found.
extension XCTestCase {
    @discardableResult
    func atticHitReport(_ app: XCUIApplication, _ element: XCUIElement, _ name: String) -> String {
        let probe = app.descendants(matching: .any).matching(identifier: "attic-hit-probe").firstMatch
        let found = probe.exists ? (probe.value as? String ?? "no value") : "no probe"
        let report = "HIT \(name) frame=\(element.exists ? element.frame : .zero) hittable=\(element.exists && element.isHittable)\nPROBE\n\(found)"
        print(report)
        return name
    }
}
