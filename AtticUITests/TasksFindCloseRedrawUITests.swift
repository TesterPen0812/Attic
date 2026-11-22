import AppKit
import XCTest

/// Closing Find draws every Now row again at once (PR 41 guard).
///
/// The launched panel on the long seed: Later, Done, Now, Later, then Now,
/// then ⌘F, "err", "an", Esc, three times. Each input follows an activation of
/// the app from this process and a 0.5 s offset, as the replay script that
/// found the fault gives them. An Esc counts only when Find was open with
/// "erran" in its field just before it. Shots of the panel taken at fixed
/// offsets after each Esc are compared with this launch's own shot before
/// Find, so no fixed reference decides the call.
final class TasksFindCloseRedrawUITests: XCTestCase {
    /// Offsets after Esc (seconds) whose shots are asserted: those whole on the
    /// trunk in every try. The others are recorded, not asserted.
    private static let assertedOffsets: Set<Double> = [0.5, 1.0, 1.5, 2.3]

    private var app: XCUIApplication!
    private var launchedAt = Date()
    private var panel: XCUIElement?

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
        launchedAt = Date()
        app.launch()
        XCTAssertTrue(tab("now").waitForExistence(timeout: 15), "the panel's Now tab")
    }

    override func tearDownWithError() throws { app?.terminate() }

    private func tab(_ page: String) -> XCUIElement { app.buttons["tasks-page-\(page)"] }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// The app built beside this runner (same products folder) and launched by this test:
    /// never another Attic, a preview or the runner itself.
    private func appsUnderTest() -> [NSRunningApplication] {
        let products = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.deletingLastPathComponent().standardizedFileURL == products
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && ($0.launchDate ?? .distantPast) >= launchedAt.addingTimeInterval(-1)
        }
    }

    private func describe(_ apps: [NSRunningApplication]) -> String {
        apps.map { "\($0.bundleIdentifier ?? "?") at \($0.bundleURL?.path ?? "?")" }.joined(separator: ", ")
    }

    /// The replay script's input: the app is activated from another process,
    /// then the action follows 0.5 s later.
    private func activate() {
        let apps = appsUnderTest()
        XCTAssertEqual(apps.count, 1, "exactly one app under test: \(describe(apps))")
        apps.first?.activate()
        usleep(500_000) // Input offset: the script acts 0.5 s after each activation.
    }

    /// The top-level element holding Now's tab and about the panel's size,
    /// found while the tabs are shown (Find replaces them).
    private func findPanel() -> XCUIElement? {
        let frame = tab("now").frame
        let tops = app.windows.allElementsBoundByIndex + app.children(matching: .any).allElementsBoundByIndex
        return tops.first { $0.frame.contains(frame) && $0.frame.width < 900 && $0.frame.height > 300 }
    }

    /// Text bands (top...bottom, points) in the panel's x 0...320, y 55...400.
    private func bands(_ image: NSImage) -> [ClosedRange<Int>] {
        guard let tiff = image.tiffRepresentation, let raw = NSBitmapImageRep(data: tiff),
              let rep = raw.converting(to: .sRGB, renderingIntent: .default) else { return [] }
        let scale = CGFloat(rep.pixelsWide) / max(image.size.width, 1)
        let x1 = min(Int(320 * scale), rep.pixelsWide)
        let y0 = Int(55 * scale), y1 = min(Int(400 * scale), rep.pixelsHigh)
        func lum(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y) else { return 0 }
            return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }
        var ink: [Bool] = []
        for y in y0..<y1 {
            var values: [CGFloat] = []
            for x in stride(from: 0, to: x1, by: 2) { values.append(lum(x, y)) }
            let median = values.sorted()[values.count / 2]
            ink.append(values.filter { abs($0 - median) > 0.25 }.count >= 3)
        }
        var found: [(Int, Int)] = []
        var start: Int?, gap = 0
        for (i, on) in ink.enumerated() {
            if on { if start == nil { start = i }; gap = 0 }
            else if let s = start { gap += 1; if gap > 3 { found.append((s, i - gap)); start = nil; gap = 0 } }
        }
        if let s = start { found.append((s, ink.count - 1)) }
        return found.filter { $0.1 - $0.0 >= Int(6 * scale) }
            .map { Int(CGFloat(y0 + $0.0) / scale)...Int(CGFloat(y0 + $0.1) / scale) }
    }

    /// Whole: at the best shift within ±12 pt, every band before Find is
    /// covered by a band now within 3 pt, and there are at least as many bands.
    private func whole(_ now: [ClosedRange<Int>], before: [ClosedRange<Int>]) -> (Bool, Int) {
        func covered(_ s: Int) -> Int {
            before.filter { b in now.contains { $0.lowerBound - s <= b.upperBound + 3 && $0.upperBound - s >= b.lowerBound - 3 } }.count
        }
        let best = (-12...12).max { (covered($0), -abs($0)) < (covered($1), -abs($1)) } ?? 0
        let n = covered(best)
        return (!before.isEmpty && n == before.count && now.count >= before.count, n)
    }

    private func shot(_ name: String, keep: Bool = true) -> [ClosedRange<Int>] {
        guard let panel else { XCTFail("\(name): no panel element"); return [] }
        let screenshot = panel.screenshot()
        if keep {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "find-close-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return bands(screenshot.image)
    }

    private func text(_ b: [ClosedRange<Int>]) -> String { b.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " ") }

    func testEveryNowRowIsDrawnAgainSoonAfterClosingFind() {
        let apps = appsUnderTest()
        print("FINDCLOSEREDRAW app under test: \(describe(apps))")
        XCTAssertEqual(apps.count, 1, "exactly one app under test: \(describe(apps))")
        waitFor(tab("now").isSelected, "the panel opens on Now")
        panel = findPanel()
        for page in ["backlog", "done", "now", "backlog"] {
            activate(); tab(page).clickInsideOwnWindow(of: app)
            waitFor(tab(page).isSelected, "\(page) reads as selected")
        }
        activate(); tab("now").clickInsideOwnWindow(of: app)
        waitFor(tab("now").isSelected, "Now reads as selected")
        activate()
        // Before Find, the Now list as drawn: every one of the seed's twelve text bands.
        waitFor(shot("before-poll", keep: false).count == 12, "the Now list is drawn before Find")
        let before = shot("before")
        for round in 1...3 {
            activate(); app.typeKey("f", modifierFlags: .command)
            activate(); app.typeText("err")
            activate(); app.typeText("an")
            let fields = app.textFields.allElementsBoundByIndex.compactMap { $0.value as? String }
            let findOpen = !tab("now").exists
            XCTAssertTrue(findOpen && fields.contains("erran"), "close \(round): Find is open with \"erran\" before Esc (\(fields))")
            activate(); let escAt = Date()
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            let keyReturned = Date()
            var line: [String] = []
            for offset in [0.5, 1.0, 1.5, 2.3] {
                // Measurement offset: the shot is taken this long after Esc (+2.3 s: 2 s after the key call returned).
                let at = offset == 2.3 ? keyReturned.addingTimeInterval(2) : escAt.addingTimeInterval(offset)
                let wait = at.timeIntervalSinceNow
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                let took = Date().timeIntervalSince(escAt)
                let got = shot("close\(round)-\(offset)")
                let (ok, n) = whole(got, before: before)
                line.append(String(format: "+%.2f s %@ %d/%d", took, ok ? "whole" : "THIN", got.count, before.count))
                if Self.assertedOffsets.contains(offset) {
                    XCTAssertTrue(ok, String(format: "close %d, %.2f s after Esc: every Now row drawn before Find is drawn (%d of %d bands, %d covered: %@)",
                                             round, took, got.count, before.count, n, text(got)))
                }
            }
            print("FINDCLOSEREDRAW close \(round): \(line.joined(separator: " ; "))")
        }
    }
}
