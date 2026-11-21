import AppKit
import XCTest

/// Clearing a tag filter that hid most of Now's rows draws every row again
/// at once (PR 41 guard, the Find-close guard's sibling).
///
/// The Find guard's method on the long seed: the same tab tour and the same
/// before-shot, then three rounds of "#" (open the tag bar), the #launch pill,
/// "#" (close the bar), and the close step: the collapsed bar's ✕ (Clear
/// tags). Shots at 0, +0.2, +0.5, +1.0 and +2.0 s after the ✕ click returns
/// are compared with the before-shot as the Find guard compares them and
/// recorded; the last one is asserted.
final class TasksTagClearRedrawUITests: XCTestCase {
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
    private func bar(_ part: String) -> XCUIElement { app.descendants(matching: .any)["tasks-tag-bar-\(part)"].firstMatch }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

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

    private func activate() {
        let apps = appsUnderTest()
        XCTAssertEqual(apps.count, 1, "exactly one app under test: \(describe(apps))")
        apps.first?.activate()
        usleep(500_000)
    }

    private func findPanel() -> XCUIElement? {
        let frame = tab("now").frame
        let tops = app.windows.allElementsBoundByIndex + app.children(matching: .any).allElementsBoundByIndex
        return tops.first { $0.frame.contains(frame) && $0.frame.width < 900 && $0.frame.height > 300 }
    }

    /// The Find guard's bands, unchanged.
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

    /// The Find guard's "whole", unchanged.
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
            attachment.name = "tag-clear-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return bands(screenshot.image)
    }

    private func text(_ b: [ClosedRange<Int>]) -> String { b.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " ") }

    func testEveryNowRowIsDrawnAgainSoonAfterClearingATagFilter() {
        let apps = appsUnderTest()
        print("TAGCLEARREDRAW app under test: \(describe(apps))")
        XCTAssertEqual(apps.count, 1, "exactly one app under test: \(describe(apps))")
        waitFor(tab("now").isSelected, "the panel opens on Now")
        panel = findPanel()
        for page in ["backlog", "done", "now", "backlog"] {
            activate(); tab(page).click()
            waitFor(tab(page).isSelected, "\(page) reads as selected")
        }
        activate(); tab("now").click()
        waitFor(tab("now").isSelected, "Now reads as selected")
        activate()
        waitFor(shot("before-poll", keep: false).count == 12, "the Now list is drawn before the filter")
        let before = shot("before")
        for round in 1...3 {
            activate(); bar("key").click()
            waitFor(bar("launch").exists && bar("launch").isHittable, "round \(round): the tag bar shows #launch")
            activate(); bar("launch").click()
            activate(); bar("key").click()
            waitFor(bar("clear").exists && bar("clear").isHittable, "round \(round): the collapsed bar shows ✕ for #launch")
            usleep(1_000_000) // Settle: the filtered list is read a second after the bar closes.
            let filtered = shot("filtered\(round)")
            print("TAGCLEARREDRAW filtered \(round): \(filtered.count)/\(before.count) bands shown under #launch (\(text(filtered)))")
            activate(); let clearAt = Date()
            bar("clear").click()
            let clickReturned = Date()
            var line: [String] = []
            // The ✕ click returns about 2 s after it is asked for and lands
            // inside that time, so the shots are timed from its return. They
            // are recorded, and only the last is asserted: on the trunk
            // (79c06ffc, no kept host) the list is 7/12 at the return and
            // whole from +0.19 s, and behind the kept host before its fix
            // it was thin until +0.20 s and whole from +0.35 s (Air, 9
            // clears each), so no offset tells the two apart with room to
            // spare. The Find-close guard and
            // `KeptContentHostTests.testADrawnRootIsLaidOutInThePassThatSetsIt`
            // carry the timing.
            for offset in [0.0, 0.2, 0.5, 1.0, 2.0] {
                // Measurement offset: the shot is taken this long after the click returned.
                let wait = clickReturned.addingTimeInterval(offset).timeIntervalSinceNow
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                let took = Date().timeIntervalSince(clickReturned)
                let got = shot("clear\(round)-\(offset)")
                let (ok, n) = whole(got, before: before)
                line.append(String(format: "+%.2f s %@ %d/%d", took, ok ? "whole" : "THIN", got.count, before.count))
                if offset == 2.0 {
                    XCTAssertTrue(ok, String(format: "clear %d, %.2f s after the ✕ click returned: every Now row drawn before the filter is drawn (%d of %d bands, %d covered: %@)",
                                             round, took, got.count, before.count, n, text(got)))
                }
            }
            print(String(format: "TAGCLEARREDRAW clear %d (click took %.2f s): ", round, clickReturned.timeIntervalSince(clearAt)) + line.joined(separator: " ; "))
        }
    }
}
