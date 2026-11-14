import AppKit
import CoreGraphics
import Foundation
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
        let recoveryLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-hang-recovery-\(UUID().uuidString).txt")
        private(set) var probe: URL?
        private(set) var recovery: HoverScrollHangRecovery?

        init(prefix: String) { self.prefix = prefix }

        func arm(pid: Int32, probe: URL) -> HoverScrollHangRecovery {
            self.probe = probe
            let recovery = HoverScrollHangRecovery(pid: pid, probe: probe, screenshot: screenshot, sample: sample, log: recoveryLog)
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
            sampleExists: fileManager.fileExists(atPath: pass.sample.path),
            recoveryLogExists: fileManager.fileExists(atPath: pass.recoveryLog.path))
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
            case .recoveryLog: attach(pass.recoveryLog, "recovery-log")
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
    private let log: URL
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "attic.ci.hover-scroll.recovery"))
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var policy: HangRecoveryPolicy
    private var reason: String?

    init(pid: Int32, probe: URL, screenshot: URL, sample: URL, log: URL) {
        self.pid = pid
        self.log = log
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
        var steps = ["decision: \(decision), pid \(pid), probe \(probe.path)"]
        let windows = HangWindowCapture.currentWindows()
        let windowID = HangWindowCapture.windowID(forPID: pid, in: windows)
        let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        steps.append("window list: \(windows.count) windows, \(own.count) owned by the app, chosen id \(windowID.map(String.init) ?? "none")")
        if let arguments = HangWindowCapture.arguments(windowID: windowID, path: screenshot.path) {
            steps.append("screencapture \(runHangTool("/usr/sbin/screencapture", arguments, timeout: 3)); file \(FileManager.default.fileExists(atPath: screenshot.path) ? "written" : "missing")")
        } else {
            steps.append("screencapture not run: no window of the app")
        }
        // The stack the freeze is in, before the process is killed.
        steps.append("sample \(runHangTool("/usr/bin/sample", [String(pid), "3", "-file", sample.path], timeout: 10)); file \(FileManager.default.fileExists(atPath: sample.path) ? "written" : "missing")")
        try? Data((steps.joined(separator: "\n") + "\n").utf8).write(to: log, options: .atomic)
        if pid > 0 { _ = Darwin.kill(pid, SIGTERM) }
        timer.cancel()
    }
}

// Pure decisions behind the CI hang recovery of ScrollEdgeUITests, kept apart
// from XCUIApplication so HangRecoverySupportTests can drive them with a fake
// clock, fake window lists and injected failures. Nothing here touches the app.

/// Where the launched app's probe file is. A signed (sandboxed) app cannot
/// write to the UI runner's temporary folder, so the test names only a leaf
/// (`ATTIC_HANG_PROBE_FILE`). The app writes it into its own temporary folder:
/// `~/Library/Containers/<bundle id>/Data/tmp` when sandboxed, the user's
/// temporary folder (shared with this runner) when not, as in CI's unsigned lane.
struct HangProbeLocation {
    let leaf: String

    init(leaf: String = "attic-hang-\(UUID().uuidString).txt") { self.leaf = leaf }

    func candidates(bundleIdentifier: String?, homeDirectory: String, temporaryDirectory: URL) -> [URL] {
        var urls: [URL] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            urls.append(URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/tmp/\(leaf)"))
        }
        urls.append(temporaryDirectory.appendingPathComponent(leaf))
        return urls
    }

    /// The first candidate the app has already written.
    func armedURL(bundleIdentifier: String?, homeDirectory: String = HangProbeLocation.homeDirectory(),
                  temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                  fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        candidates(bundleIdentifier: bundleIdentifier, homeDirectory: homeDirectory,
                   temporaryDirectory: temporaryDirectory).first { fileExists($0.path) }
    }

    static func homeDirectory() -> String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }
}

/// What the app's last probe write said.
struct HangProbeReading: Equatable {
    var isHang: Bool
    /// The app's count of real run-loop waits when it wrote the dump. A change
    /// between two dumps proves the loop slept in between.
    var healthyWaits: Int?
    /// Seconds since the file was written.
    var ageSeconds: Double

    init(isHang: Bool, healthyWaits: Int?, ageSeconds: Double) {
        self.isHang = isHang
        self.healthyWaits = healthyWaits
        self.ageSeconds = ageSeconds
    }

    init(contents: String, ageSeconds: Double) {
        isHang = contents.hasPrefix("HANG:")
        let first = contents.prefix { $0 != "\n" }
        healthyWaits = first.range(of: "healthy-waits=").flatMap { range in
            Int(first[range.upperBound...].prefix { $0.isNumber })
        }
        self.ageSeconds = ageSeconds
    }
}

/// When to give up on a launched app. A hang is a *continuous* stall: dumps keep
/// arriving with the same healthy-wait count. Busy bursts separated by real waits
/// change that count and restart the interval, so they never add up to a kill.
/// The fallback measures time since the test last made progress, not since
/// launch, so a slow but advancing test is never killed for being slow.
struct HangRecoveryPolicy {
    enum Decision: Equatable { case sustainedHang, noProgress }

    static let sustainedNanos: UInt64 = 20_000_000_000
    static let progressDeadlineNanos: UInt64 = 60_000_000_000
    static let freshSeconds = 4.5

    private(set) var sustainedSince: UInt64?
    private var generation: Int?
    private var lastProgress: UInt64

    init(startedAt: UInt64) { lastProgress = startedAt }

    mutating func noteProgress(at now: UInt64) { lastProgress = max(lastProgress, now) }

    mutating func evaluate(now: UInt64, reading: HangProbeReading?) -> Decision? {
        if let reading, reading.isHang, reading.ageSeconds < Self.freshSeconds {
            if sustainedSince == nil || reading.healthyWaits != generation {
                sustainedSince = now
                generation = reading.healthyWaits
            }
            if now &- (sustainedSince ?? now) >= Self.sustainedNanos { return .sustainedHang }
        } else {
            sustainedSince = nil
            generation = nil
        }
        return now &- lastProgress > Self.progressDeadlineNanos ? .noProgress : nil
    }
}

/// A pass needs its recovery (a launched PID and an armed probe) before any
/// risky hover or scroll. Without either, the pass ends with a clear failure.
enum HangPassGuard {
    enum Outcome: Equatable {
        case proceed(pid: Int32, probe: URL)
        case skip(reason: String)
    }

    static func evaluate(pid: Int32, armedProbe: URL?) -> Outcome {
        guard pid > 0 else { return .skip(reason: "launched app PID is unavailable for recovery") }
        guard let armedProbe else { return .skip(reason: "the app-side hang probe never wrote its file") }
        return .proceed(pid: pid, probe: armedProbe)
    }

    /// Runs `risky` only when the recovery can be armed. Returns the reason when it did not run.
    static func run(pid: Int32, armedProbe: URL?, risky: (Int32, URL) -> Void) -> String? {
        switch evaluate(pid: pid, armedProbe: armedProbe) {
        case let .proceed(pid, probe):
            risky(pid, probe)
            return nil
        case let .skip(reason):
            return reason
        }
    }
}

/// What a pass attaches after a hang, a recovery or an abandoned XCUI call.
/// It follows the recovery's status and which files exist, never only the
/// latest dump's prefix (the fallback can fire while the file still says ARMED).
enum HangEvidencePlan {
    enum Item: Equatable { case probeLatest, probeFirst, screenshot, screenshotUnavailableNote, sample, recoveryLog }

    static func items(recovered: Bool, probeText: String?, probeFirstExists: Bool,
                      screenshotExists: Bool, sampleExists: Bool, recoveryLogExists: Bool = false) -> [Item] {
        var items: [Item] = []
        if recovered || probeText?.hasPrefix("HANG:") == true {
            if probeText != nil { items.append(.probeLatest) }
            if probeFirstExists { items.append(.probeFirst) }
        }
        guard recovered else { return items }
        items.append(screenshotExists ? .screenshot : .screenshotUnavailableNote)
        if sampleExists { items.append(.sample) }
        if recoveryLogExists { items.append(.recoveryLog) }
        return items
    }
}

/// The recovery's picture is of the launched app's own window only, found from
/// its PID in the window server's list (no AX request, which can block on a
/// hung app). Never the whole display: other apps' windows and notifications
/// must not end up in a result bundle.
enum HangWindowCapture {
    static func windowID(forPID pid: Int32, in windows: [[String: Any]]) -> CGWindowID? {
        func area(_ window: [String: Any]) -> Double {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return 0 }
            return width * height
        }
        let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && area($0) > 0 }
        let onScreen = own.filter { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true }
        let pool = onScreen.isEmpty ? own : onScreen
        return pool.max { area($0) < area($1) }
            .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// `screencapture` arguments for one window, or nil when the app has none.
    static func arguments(windowID: CGWindowID?, path: String) -> [String]? {
        guard let windowID else { return nil }
        return ["-x", "-o", "-l", String(windowID), "-t", "png", path]
    }

    static func currentWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    }
}

/// Runs a short-lived tool with a hard time limit and says what happened
/// (launch failure, timeout, exit status and the start of its error output),
/// so a recovery that could not take a picture or a stack can say why.
@discardableResult
func runHangTool(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = errors
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return "could not start: \(error)" }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return "timed out after \(Int(timeout)) s and was terminated"
    }
    let output = String(decoding: errors.fileHandleForReading.availableData.prefix(400), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return "exited \(process.terminationStatus)" + (output.isEmpty ? "" : ": \(output)")
}

/// The decisions behind ScrollEdgeUITests' hang recovery, with a fake clock,
/// fake window lists and injected failures. No app is launched and nothing is
/// scrolled, so these run in any UI lane in a fraction of a second.
final class HangRecoverySupportTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func hang(waits: Int?, age: Double = 1) -> HangProbeReading {
        HangProbeReading(isHang: true, healthyWaits: waits, ageSeconds: age)
    }

    // MARK: Dot R-6: only a continuous stall is killed

    func testBurstsSeparatedByHealthyWaitsNeverAddUpToAKill() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // Two minutes: a busy stretch of 3 s or more every 5 s, a real wait between,
        // so the app keeps refreshing a fresh HANG dump with a new wait count.
        for tick in 1...120 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: hang(waits: tick / 5)), "tick \(tick)")
        }
    }

    func testAContinuousStallIsKilledAfterTwentySeconds() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        var firedAt: Int?
        for tick in 1...40 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            if policy.evaluate(now: now, reading: hang(waits: 7)) == .sustainedHang { firedAt = tick; break }
        }
        XCTAssertEqual(firedAt, 21, "first seen at 1 s, sustained for 20 s")
    }

    func testALaunchTimeDumpThatEndsByItselfNeverCounts() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // A slow runner's first layout: about 4 s of busy, then the loop sleeps and the file goes stale.
        for tick in 1...4 { XCTAssertNil(policy.evaluate(now: UInt64(tick) * second, reading: hang(waits: 0))) }
        for tick in 5...40 {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: hang(waits: 0, age: 6)), "tick \(tick)")
        }
        XCTAssertNil(policy.sustainedSince)
    }

    func testTheFallbackMeasuresProgressNotTimeSinceLaunch() {
        var policy = HangRecoveryPolicy(startedAt: 0)
        // A slow but advancing test (each XCUI step takes 10 s) is never killed for being slow.
        for tick in stride(from: 10, through: 300, by: 10) {
            let now = UInt64(tick) * second
            policy.noteProgress(at: now)
            XCTAssertNil(policy.evaluate(now: now, reading: nil), "tick \(tick)")
        }
        // The XCUI call stops returning.
        XCTAssertNil(policy.evaluate(now: 359 * second, reading: nil))
        XCTAssertEqual(policy.evaluate(now: 361 * second, reading: nil), .noProgress)
    }

    func testTheProbeReadingParsesTheHealthyWaitCount() {
        let dump = "HANG: no-genuine-wait, elapsed=4250ms, turns=3, healthy-waits=12\nlast-turn=0ms ago\n"
        XCTAssertEqual(HangProbeReading(contents: dump, ageSeconds: 1),
                       HangProbeReading(isHang: true, healthyWaits: 12, ageSeconds: 1))
        XCTAssertEqual(HangProbeReading(contents: "ARMED: main-run-loop watchdog, 3s threshold\n", ageSeconds: 2),
                       HangProbeReading(isHang: false, healthyWaits: nil, ageSeconds: 2))
    }

    // MARK: Dot R-2: no risky scroll without its recovery

    func testNothingRiskyRunsWithoutAPIDOrAnArmedProbe() {
        var runs = 0
        let probe = URL(fileURLWithPath: "/tmp/attic-hang-probe.txt")
        XCTAssertNotNil(HangPassGuard.run(pid: 0, armedProbe: probe) { _, _ in runs += 1 }, "no PID: the pass ends with a reason")
        XCTAssertNotNil(HangPassGuard.run(pid: -1, armedProbe: probe) { _, _ in runs += 1 })
        XCTAssertNotNil(HangPassGuard.run(pid: 4242, armedProbe: nil) { _, _ in runs += 1 }, "unarmed probe: the pass ends with a reason")
        XCTAssertNotNil(HangPassGuard.run(pid: 0, armedProbe: nil) { _, _ in runs += 1 })
        XCTAssertEqual(runs, 0, "the scroll is never invoked without a recovery")
        var ran: (Int32, URL)?
        XCTAssertNil(HangPassGuard.run(pid: 4242, armedProbe: probe) { ran = ($0, $1) })
        XCTAssertEqual(ran?.0, 4242)
        XCTAssertEqual(ran?.1, probe)
    }

    // MARK: Opus R-4, R-2: where the app wrote its probe, and what counts as armed

    func testTheProbeIsFoundInTheAppsOwnContainerOrTheSharedTemporaryFolder() {
        let location = HangProbeLocation(leaf: "attic-hang-X.txt")
        let temporary = URL(fileURLWithPath: "/var/folders/t/T/", isDirectory: true)
        let candidates = location.candidates(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                             temporaryDirectory: temporary)
        XCTAssertEqual(candidates.map(\.path), ["/Users/me/Library/Containers/com.taha.Attic.ui.abc/Data/tmp/attic-hang-X.txt",
                                                "/var/folders/t/T/attic-hang-X.txt"])
        // A signed app wrote into its container; CI's unsigned app into the shared folder.
        XCTAssertEqual(location.armedURL(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                         temporaryDirectory: temporary) { $0.hasPrefix("/Users/me/Library/Containers") }?.path,
                       candidates[0].path)
        XCTAssertEqual(location.armedURL(bundleIdentifier: "com.taha.Attic.ui.abc", homeDirectory: "/Users/me",
                                         temporaryDirectory: temporary) { $0.hasPrefix("/var/folders") }?.path,
                       candidates[1].path)
        XCTAssertNil(location.armedURL(bundleIdentifier: nil, homeDirectory: "/Users/me", temporaryDirectory: temporary) { _ in false })
        XCTAssertEqual(location.candidates(bundleIdentifier: nil, homeDirectory: "/Users/me", temporaryDirectory: temporary).count, 1)
    }

    // MARK: Dot R-7: evidence survives teardown

    func testEvidenceFollowsTheRecoveryStatusNotTheLatestDumpPrefix() {
        // The fallback fired while the file still said ARMED.
        let items = HangEvidencePlan.items(recovered: true, probeText: "ARMED: main-run-loop watchdog\n",
                                           probeFirstExists: false, screenshotExists: true, sampleExists: true)
        XCTAssertEqual(items, [.probeLatest, .screenshot, .sample])
        XCTAssertEqual(HangEvidencePlan.items(recovered: true, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false, recoveryLogExists: true),
                       [.probeLatest, .screenshotUnavailableNote, .recoveryLog],
                       "the recovery's own log says why a picture or a stack is missing")
        XCTAssertEqual(HangEvidencePlan.items(recovered: true, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false),
                       [.probeLatest, .screenshotUnavailableNote])
        // A launch-time dump of a pass that recovered by itself is kept as evidence, and nothing else.
        XCTAssertEqual(HangEvidencePlan.items(recovered: false, probeText: "HANG: x\n", probeFirstExists: true,
                                              screenshotExists: true, sampleExists: true),
                       [.probeLatest, .probeFirst])
        XCTAssertEqual(HangEvidencePlan.items(recovered: false, probeText: "ARMED\n", probeFirstExists: false,
                                              screenshotExists: false, sampleExists: false), [])
    }

    // MARK: Opus R-6 = Dot R-8: the window only, never the display

    private func window(pid: Int32, number: UInt32, width: Double, height: Double, onScreen: Bool = true) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: number),
         kCGWindowIsOnscreen as String: NSNumber(value: onScreen),
         kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": width, "Height": height] as [String: Any]]
    }

    func testTheCaptureTargetsOnlyTheLaunchedAppsOwnWindow() {
        let windows = [window(pid: 1, number: 10, width: 3_000, height: 2_000),     // another app, bigger
                       window(pid: 4242, number: 20, width: 24, height: 24),        // the status item
                       window(pid: 4242, number: 21, width: 320, height: 464),      // the panel
                       window(pid: 4242, number: 22, width: 900, height: 900, onScreen: false)]
        XCTAssertEqual(HangWindowCapture.windowID(forPID: 4242, in: windows), 21)
        let arguments = HangWindowCapture.arguments(windowID: 21, path: "/tmp/p.png")
        XCTAssertEqual(arguments, ["-x", "-o", "-l", "21", "-t", "png", "/tmp/p.png"])
        XCTAssertTrue(arguments?.contains("-l") == true, "window capture, never the whole display")
    }

    func testWithoutAWindowThereIsNoPictureAtAll() {
        let windows = [window(pid: 1, number: 10, width: 3_000, height: 2_000)]
        let id = HangWindowCapture.windowID(forPID: 4242, in: windows)
        XCTAssertNil(id)
        XCTAssertNil(HangWindowCapture.arguments(windowID: id, path: "/tmp/p.png"), "no window: no capture command to run")
        XCTAssertNil(HangWindowCapture.windowID(forPID: 4242, in: []))
    }
}
