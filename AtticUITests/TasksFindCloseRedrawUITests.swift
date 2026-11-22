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
    private var panel: PanelCapture?

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

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5, _ message: @autoclosure () -> String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), message(), file: file, line: line)
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

    /// One shot of the panel, or nil after a failure that names the capture.
    private func shot(_ name: String, keep: Bool = true) -> [ClosedRange<Int>]? {
        guard let panel else { XCTFail("\(name): no panel"); return nil }
        let got = panel.take("find-close-\(name)", keep: keep, in: self)
        if let problem = got.problem { XCTFail(problem) }
        return got.bands
    }

    private func text(_ b: [ClosedRange<Int>]) -> String { b.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " ") }

    func testEveryNowRowIsDrawnAgainSoonAfterClosingFind() {
        let apps = appsUnderTest()
        print("FINDCLOSEREDRAW app under test: \(describe(apps))")
        XCTAssertEqual(apps.count, 1, "exactly one app under test: \(describe(apps))")
        waitFor(tab("now").isSelected, "the panel opens on Now")
        panel = PanelCapture.find(in: app, holding: tab("now"))
        XCTAssertNotNil(panel, "the panel: a top-level dialog holding Now's tab (\(PanelCapture.describeTops(of: app)))")
        for page in ["backlog", "done", "now", "backlog"] {
            activate(); tab(page).clickInsideOwnWindow(of: app)
            waitFor(tab(page).isSelected, "\(page) reads as selected")
        }
        activate(); tab("now").clickInsideOwnWindow(of: app)
        waitFor(tab("now").isSelected, "Now reads as selected")
        activate()
        // Before Find, the Now list as drawn: every one of the seed's twelve text bands.
        guard let panel else { return }
        var poll = PanelCapture.Shot(bands: nil, problem: "not captured", sizes: "none")
        waitFor({ poll = panel.take("find-close-before-poll", keep: false, in: self); return poll.bands?.count == 12 }(),
                "the Now list is drawn before Find (\(poll.problem ?? text(poll.bands ?? [])))")
        print("FINDCLOSEREDRAW panel \(panel.frame), capture \(poll.sizes)")
        guard let before = shot("before") else { return }
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
                let shotAt = Date()
                guard let got = shot("close\(round)-\(offset)") else {
                    line.append(String(format: "+%.2f s NO CAPTURE", took))
                    continue
                }
                let (ok, n) = whole(got, before: before)
                line.append(String(format: "+%.2f s %@ %d/%d (shot %.2f s)", took, ok ? "whole" : "THIN", got.count, before.count,
                                   Date().timeIntervalSince(shotAt)))
                if Self.assertedOffsets.contains(offset) {
                    XCTAssertTrue(ok, String(format: "close %d, %.2f s after Esc: every Now row drawn before Find is drawn (%d of %d bands, %d covered: %@)",
                                             round, took, got.count, before.count, n, text(got)))
                }
            }
            print("FINDCLOSEREDRAW close \(round): \(line.joined(separator: " ; "))")
        }
    }
}

/// The panel as the PR 41 guards capture it.
///
/// The panel is held by its place among the app's top-level dialogs, picked by
/// frame while the tabs show. The app's top-level children of any type also
/// hold a tooltip (HelpTag), the menu bars and the Touch Bar, which come and
/// go, so a place among them can later name another element: in CI run
/// 44973742337 index 3 was the panel at the start (HelpTag, Group, Dialog,
/// Dialog, MenuBar) and the menu bar 9 s on, once the tooltip had gone, and
/// the 1024×30 capture of the menu bar trapped the band reader. Every capture
/// is checked against the panel's frame before it is read, so a capture of
/// anything else fails by name instead.
struct PanelCapture {
    let element: XCUIElement
    let frame: CGRect

    /// The top-level dialog holding `tab`, about the panel's size.
    static func find(in app: XCUIApplication, holding tab: XCUIElement) -> PanelCapture? {
        let target = tab.frame
        for dialog in app.children(matching: .dialog).allElementsBoundByIndex {
            let frame = dialog.frame
            if frame.contains(target), frame.width < 900, frame.height > 300 { return PanelCapture(element: dialog, frame: frame) }
        }
        return nil
    }

    static func describeTops(of app: XCUIApplication) -> String {
        app.children(matching: .any).allElementsBoundByIndex.map { "\($0.elementType.rawValue) \($0.frame)" }.joined(separator: ", ")
    }

    struct Shot {
        let bands: [ClosedRange<Int>]?
        let problem: String?
        let sizes: String
    }

    /// One capture: its text bands, or why it can't be read.
    func take(_ name: String, keep: Bool, in test: XCTestCase) -> Shot {
        let screenshot = element.screenshot()
        if keep {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        let image = screenshot.image
        let rep = image.representations.first
        let pixels = CGSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
        let sizes = "\(Int(pixels.width))×\(Int(pixels.height)) px, \(Int(image.size.width))×\(Int(image.size.height)) pt"
        // The panel's frame at 1×, 2× or 3×, to the pixel.
        let isPanel = [1.0, 2.0, 3.0].contains { s in
            abs(pixels.width - frame.width * s) <= s && abs(pixels.height - frame.height * s) <= s
        }
        guard isPanel, let bands = Self.bands(image) else {
            return Shot(bands: nil, problem: "\(name): the capture is \(sizes), not the panel's \(Int(frame.width))×\(Int(frame.height)) pt "
                            + "window at (\(Int(frame.minX)), \(Int(frame.minY)))", sizes: sizes)
        }
        return Shot(bands: bands, problem: nil, sizes: sizes)
    }

    /// Text bands (top...bottom, points) in the panel's x 0...320, y 55...400;
    /// nil when the image cannot hold that area (empty, zero-size or short).
    static func bands(_ image: NSImage) -> [ClosedRange<Int>]? {
        guard image.size.width >= 1, image.size.height >= 1,
              let tiff = image.tiffRepresentation, let raw = NSBitmapImageRep(data: tiff),
              let rep = raw.converting(to: .sRGB, renderingIntent: .default),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        guard scale.isFinite, scale > 0 else { return nil }
        let x1 = min(Int(320 * scale), rep.pixelsWide)
        let y0 = Int(55 * scale), y1 = min(Int(400 * scale), rep.pixelsHigh)
        guard x1 > 0, y1 > y0 else { return nil }
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
}

/// The band reader never traps, whatever it is handed (no app is launched).
final class PanelCaptureBandsTests: XCTestCase {
    private func image(_ width: CGFloat, _ height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
    }

    func testAMenuBarShapedCaptureReadsAsNoBands() {
        XCTAssertNil(PanelCapture.bands(image(1024, 30)), "CI 44973742337's 1024×30 capture")
    }

    func testAZeroSizeCaptureReadsAsNoBands() {
        XCTAssertNil(PanelCapture.bands(NSImage(size: .zero)))
        XCTAssertNil(PanelCapture.bands(image(0, 464)))
        XCTAssertNil(PanelCapture.bands(image(320, 0)))
    }

    func testANarrowCaptureReadsAsNoBands() {
        XCTAssertNil(PanelCapture.bands(image(0.5, 464)))
    }

    func testABlankPanelSizedCaptureIsReadAndHasNoTextBands() {
        XCTAssertEqual(PanelCapture.bands(image(320, 464))?.count, 0)
    }
}
