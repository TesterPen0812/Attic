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
