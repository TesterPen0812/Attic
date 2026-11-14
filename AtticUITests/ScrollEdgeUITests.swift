import AppKit
import Darwin
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
            capturePass(surface: surface, mode: mode)
        }
    }

    private func capturePass(surface: String, mode: String) {
        let prefix = "scroll-edges-\(surface)-\(mode)"
        let pass = HangPass(prefix: prefix)
        let app = launchHangPass(pass, surface: surface, mode: mode)
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pin.waitForExistence(timeout: 8), "\(surface) \(mode): the panel shows")
        XCTAssertTrue(app.buttons["tasks-page-now"].waitForExistence(timeout: 4), "the tabs are there")
        let pid = launchedPID(of: app)
        // Evidence is attached in teardown too: XCTest can abandon the method
        // when the app is killed during an XCUI scroll or snapshot.
        addTeardownBlock { [weak self] in self?.attachEvidence(of: pass) }
        // Without a PID and an armed probe there is no recovery: leave the pass
        // before any hover or scroll rather than risk the minutes-long freeze.
        let skipped = HangPassGuard.run(pid: pid, armedProbe: waitForProbe(of: pass, pid: pid)) { pid, probe in
            let recovery = pass.arm(pid: pid, probe: probe)
            let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
            let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            middle.hover()
            recovery.noteProgress()
            // Either sign: one of the two leaves rows under the tabs.
            for (index, delta) in [CGFloat(-140), 280].enumerated() {
                if recovery.hasRecovered { break }
                middle.scroll(byDeltaX: 0, deltaY: delta)
                recovery.noteProgress()
                if recovery.hasRecovered { break }
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                save(panel.screenshot(), name: "scroll-edges-\(surface)-\(mode)-soft-\(index)")
                recovery.noteProgress()
            }
            let result = recovery.finish()
            if result.recovered { XCTFail("\(prefix): \(result.reason ?? "sustained main-run-loop hang")") }
        }
        if let skipped { XCTFail("\(prefix): \(skipped)") }
        if pass.recovery?.hasRecovered != true { app.terminate() }
    }

    /// Diagnostic-only CI experiment. The long fixture and these events are
    /// deliberately identical to the Dark Glass pass of the capture test.
    /// Each run has a fresh app process, so a hang cannot contaminate the
    /// next sample. The recovery thread uses the launched PID only.
    ///
    /// Not run unless asked: set `TEST_RUNNER_ATTIC_HANG_DIAGNOSTICS=1` (CI's
    /// focused dispatch does), so a local run of this class stays at the
    /// required capture test. `TEST_RUNNER_ATTIC_HANG_REPETITIONS=<1...25>`
    /// sets the number of launches (default 25); xcodebuild forwards only
    /// `TEST_RUNNER_`-prefixed variables to this runner.
    func testDarkGlassHoverScrollRepeats() throws {
        try XCTSkipUnless(Self.diagnosticsRequested, "hang diagnostics are opt-in: TEST_RUNNER_ATTIC_HANG_DIAGNOSTICS=1")
        let requested = Int(ProcessInfo.processInfo.environment["ATTIC_HANG_REPETITIONS"] ?? "25") ?? 25
        repeatHoveredScroll(surface: "glass", mode: "dark", count: min(max(1, requested), 25))
    }

    /// Controlled appearance comparison: same hover and wheel sequence,
    /// independent process, probe and fixture.
    func testLightGlassHoverScrollControl() throws {
        try XCTSkipUnless(Self.diagnosticsRequested, "hang diagnostics are opt-in: TEST_RUNNER_ATTIC_HANG_DIAGNOSTICS=1")
        repeatHoveredScroll(surface: "glass", mode: "light", count: 1)
    }

    private static var diagnosticsRequested: Bool {
        ProcessInfo.processInfo.environment["ATTIC_HANG_DIAGNOSTICS"] == "1"
    }

    private func repeatHoveredScroll(surface: String, mode: String, count: Int) {
        var failures: [String] = []
        for number in 1...count {
            let prefix = "hover-scroll-\(mode)-\(number)"
            let pass = HangPass(prefix: prefix)
            let app = launchHangPass(pass, surface: surface, mode: mode)
            addTeardownBlock { [weak self] in self?.attachEvidence(of: pass) }
            let pin = app.buttons["panel-pin-button"]
            let tabs = app.buttons["tasks-page-now"]
            guard pin.waitForExistence(timeout: 8), tabs.waitForExistence(timeout: 4) else {
                failures.append("\(prefix): panel or tabs did not appear")
                app.terminate()
                continue
            }
            let pid = launchedPID(of: app)
            let skipped = HangPassGuard.run(pid: pid, armedProbe: waitForProbe(of: pass, pid: pid)) { pid, probe in
                let recovery = pass.arm(pid: pid, probe: probe)
                let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
                let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                middle.hover()
                recovery.noteProgress()
                for delta in [CGFloat(-140), 280] {
                    if recovery.hasRecovered { break }
                    middle.scroll(byDeltaX: 0, deltaY: delta)
                    recovery.noteProgress()
                    if recovery.hasRecovered { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    recovery.noteProgress()
                }
                let result = recovery.finish()
                if result.recovered {
                    failures.append("\(prefix): \(result.reason ?? "probe reported a run-loop hang")")
                }
            }
            if let skipped { failures.append("\(prefix): \(skipped)") }
            if pass.recovery?.hasRecovered != true { app.terminate() }
        }
        XCTAssertTrue(failures.isEmpty, "\(mode) \(count) independent attempts: \(failures.joined(separator: "; "))")
    }

    /// One launched pass of the original hover-and-scroll sequence: its probe
    /// file, recovery and the files the recovery leaves as evidence.
    private final class HangPass {
        let prefix: String
        let location = HangProbeLocation()
        let screenshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-hang-screen-\(UUID().uuidString).png")
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-hang-sample-\(UUID().uuidString).txt")
        private(set) var probe: URL?
        private(set) var recovery: HoverScrollHangRecovery?

        init(prefix: String) { self.prefix = prefix }

        func arm(pid: Int32, probe: URL) -> HoverScrollHangRecovery {
            self.probe = probe
            let recovery = HoverScrollHangRecovery(pid: pid, probe: probe, screenshot: screenshot, sample: sample)
            self.recovery = recovery
            recovery.start()
            return recovery
        }

        /// Remembered even when the guard refuses the pass, so evidence of
        /// the launch-time dump is attached too.
        func remember(probe: URL?) { if self.probe == nil { self.probe = probe } }
    }

    private func launchHangPass(_ pass: HangPass, surface: String, mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
        // A leaf in the app's own temporary folder: a signed app is sandboxed.
        app.launchEnvironment["ATTIC_HANG_PROBE_FILE"] = pass.location.leaf
        app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", surface]
        app.launch()
        return app
    }

    private func launchedPID(of app: XCUIApplication) -> Int32 {
        let pidValue = app.responds(to: NSSelectorFromString("processID")) ? app.value(forKey: "processID") : nil
        return (pidValue as? NSNumber)?.int32Value ?? (pidValue as? Int32) ?? 0
    }

    /// "Armed" is the app having written the probe file, whatever it says: a
    /// slow first layout may already have replaced the ARMED line with a HANG
    /// dump, which is evidence but not a reason to doubt the probe.
    private func waitForProbe(of pass: HangPass, pid: Int32) -> URL? {
        let bundle = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        var found: URL?
        _ = waitFor(timeout: 5) {
            found = pass.location.armedURL(bundleIdentifier: bundle)
            return found != nil
        }
        pass.remember(probe: found)
        return found
    }

    /// Attaches what a pass left behind, by recovery status and by which files
    /// exist. A launch-time HANG dump is kept as evidence but never counts as
    /// the target hang; only the recovery's verdict fails a pass.
    private func attachEvidence(of pass: HangPass) {
        let fileManager = FileManager.default
        let latest = pass.probe
        let first = latest.map { URL(fileURLWithPath: $0.path + ".first") }
        let items = HangEvidencePlan.items(
            recovered: pass.recovery?.hasRecovered == true,
            probeText: latest.flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            probeFirstExists: first.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            screenshotExists: fileManager.fileExists(atPath: pass.screenshot.path),
            sampleExists: fileManager.fileExists(atPath: pass.sample.path))
        func attach(_ url: URL, _ name: String) {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "\(pass.prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for item in items {
            switch item {
            case .probeLatest: if let latest { attach(latest, "probe-latest") }
            case .probeFirst: if let first { attach(first, "probe-first") }
            case .screenshot: attach(pass.screenshot, "frozen-window")
            case .sample: attach(pass.sample, "sample")
            case .screenshotUnavailableNote:
                let note = XCTAttachment(string: "No window of the launched app was on screen for \(pass.prefix); no picture was taken.")
                note.name = "\(pass.prefix)-frozen-window-unavailable"
                note.lifetime = .keepAlways
                add(note)
            }
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
        XCTAssertTrue(findButton.isHittable, "Find's button has a hit point over scrolled rows")
        findButton.click()
        let find = app.descendants(matching: .any).matching(identifier: "tasks-find").firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 3), "Find opens")
        // While searching, Pin folds away (Accepted 2026-10-29 "Top row and
        // bottom bar": "Pin, the switch and ••• fold away"): the panel is
        // the dialog holding "+" from here.
        let searchingPanel = app.dialogs.containing(.button, identifier: "tasks-new-task").firstMatch
        XCTAssertTrue(find.isHittable, "Find's field has a hit point over scrolled rows: \(find.frame)")
        find.click()
        app.typeText("Ship")
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Ship appearance PR,")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 3), "the match is listed")
        XCTAssertTrue(waitFor { match.isHittable && searchingPanel.frame.contains(CGPoint(x: match.frame.midX, y: match.frame.midY)) },
                      "and in view, not past the list's end: \(match.frame)")
        let count = app.descendants(matching: .any).matching(identifier: "tasks-find-count").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 3), "the count shows")
        let counted = [count.label, count.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(counted.contains("1 of "), "the count says one: \(counted)")
        save(searchingPanel.screenshot(), name: "scroll-edges-glass-light-find-from-far-down")
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
                XCTFail("\(identifiers[index]) has a hit point at rest: \(control.frame)")
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
                        XCTFail("\(identifiers[index]) keeps its hit point after scrolling: \(control.frame)")
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

/// XCUITest can wait indefinitely for AX to become idle while the app's main
/// thread is spinning. A separate watchdog reads the app's background dump,
/// captures the frozen app's own window (by PID, no AX request), samples its
/// stack, and sends SIGTERM only to the PID captured from this particular
/// launched instance.
private final class HoverScrollHangRecovery {
    private let pid: Int32
    private let probe: URL
    private let screenshot: URL
    private let sample: URL
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "attic.ci.hover-scroll.recovery"))
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var policy: HangRecoveryPolicy
    private var reason: String?

    init(pid: Int32, probe: URL, screenshot: URL, sample: URL) {
        self.pid = pid
        self.probe = probe
        self.screenshot = screenshot
        self.sample = sample
        policy = HangRecoveryPolicy(startedAt: DispatchTime.now().uptimeNanoseconds)
    }

    var hasRecovered: Bool { lock.withLock { reason != nil } }

    /// The test advanced (an XCUI step returned): the no-progress deadline restarts.
    func noteProgress() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { policy.noteProgress(at: now) }
    }

    func start() {
        finished.enter()
        let completion = finished
        timer.setCancelHandler { completion.leave() }
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
    }

    func finish() -> (recovered: Bool, reason: String?) {
        timer.cancel()
        _ = finished.wait(timeout: .now() + .seconds(20))
        return lock.withLock { (reason != nil, reason) }
    }

    private func reading() -> HangProbeReading? {
        guard let contents = try? String(contentsOf: probe, encoding: .utf8) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: probe.path)[.modificationDate] as? Date) ?? nil
        return HangProbeReading(contents: contents, ageSeconds: modified.map { Date().timeIntervalSince($0) } ?? .infinity)
    }

    private func check() {
        let now = DispatchTime.now().uptimeNanoseconds
        let reading = reading()
        let decision = lock.withLock { policy.evaluate(now: now, reading: reading) }
        guard let decision else { return }
        lock.withLock {
            reason = decision == .sustainedHang
                ? "app's background watchdog saw a run loop that stayed busy continuously for 20 s"
                : "scroll/AX made no progress for 60 seconds"
        }
        // Only the app's own window, found without asking the (hung) app. No window: no picture.
        let windowID = HangWindowCapture.windowID(forPID: pid, in: HangWindowCapture.currentWindows())
        if let arguments = HangWindowCapture.arguments(windowID: windowID, path: screenshot.path) {
            runHangTool("/usr/sbin/screencapture", arguments, timeout: 3)
        }
        // The stack the freeze is in, before the process is killed.
        runHangTool("/usr/bin/sample", [String(pid), "3", "-file", sample.path], timeout: 10)
        if pid > 0 { _ = Darwin.kill(pid, SIGTERM) }
        timer.cancel()
    }
}
