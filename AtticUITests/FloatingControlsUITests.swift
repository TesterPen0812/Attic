import AppKit
import XCTest

/// Floating controls on screen (owner, 2026-10-01: B with softening). The
/// panel is drawn by the window server here, as the owner sees it, so the
/// captures are the evidence the hosted tests cannot give: rows scrolled
/// under the tabs, the add bar and the header's buttons, with the default
/// softening and with none (for comparison), in Light Solid, Light Glass and
/// Dark Glass. Each capture is attached to the result
/// (and saved with the visual UAT when CI asks for it).
final class FloatingControlsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testCapturesRowsPassingUnderTheControls() throws {
        for (surface, mode) in [("solid", "light"), ("glass", "light"), ("glass", "dark")] {
            for strength in ["default", "0"] {
                let app = XCUIApplication()
                app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
                app.launchEnvironment["ATTIC_UI_TEST_SEED"] = "long"
                if strength != "default" { app.launchEnvironment["ATTIC_UI_TEST_SOFTENING_STRENGTH"] = strength }
                app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", surface]
                app.launch()
                let pin = app.buttons["panel-pin-button"]
                XCTAssertTrue(pin.waitForExistence(timeout: 8), "\(surface) \(mode) \(strength): the panel shows")
                let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
                let middle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                middle.hover()
                // Either sign: one of the two leaves rows under the tabs.
                for (index, delta) in [CGFloat(-140), 280].enumerated() {
                    middle.scroll(byDeltaX: 0, deltaY: delta)
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    save(panel.screenshot(), name: "softening-\(surface)-\(mode)-\(strength)-\(index)")
                }
                app.terminate()
            }
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
