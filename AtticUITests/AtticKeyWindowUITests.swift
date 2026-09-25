import AppKit
import XCTest

/// The on-screen key-window check (spec § Appearance: native Liquid Glass
/// renders flat in a window that is not key, which the drawn appearance
/// matrix cannot catch). The panel is revealed the way the corner reveals
/// it (another window holds the keyboard), captured, then made key as a
/// click would, and captured again, in Light and Dark. The Pin control must
/// read as a raised control in both states, never as the flat grey slab
/// inactive glass draws; both captures are attached for review.
final class AtticKeyWindowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testControlsStayRaisedBeforeAndAfterThePanelIsKeyInLight() throws {
        try check(mode: "light", assertsRaised: true)
    }

    func testControlsStayRaisedBeforeAndAfterThePanelIsKeyInDark() throws {
        try check(mode: "dark", assertsRaised: false)
    }

    private func check(mode: String, assertsRaised: Bool) throws {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_NONKEY_REVEAL"] = "4"
        app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", "solid"]
        app.launch()
        let pin = app.buttons["panel-pin-button"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        // The seam hands the keyboard to a stand-in window after 0.5 s.
        Thread.sleep(forTimeInterval: 1.5)
        let nonKey = pin.screenshot().image
        attach(nonKey, name: "pin-\(mode)-not-key")
        // …and gives it back to the panel after 4 s, as a click would.
        Thread.sleep(forTimeInterval: 3.5)
        let key = pin.screenshot().image
        attach(key, name: "pin-\(mode)-key")

        let nonKeyContrast = try fillToSurfaceDifference(nonKey)
        let keyContrast = try fillToSurfaceDifference(key)
        if assertsRaised {
            XCTAssertLessThan(nonKeyContrast, 0.12, "not key: the Pin must not be a flat grey slab (\(nonKeyContrast))")
            XCTAssertLessThan(keyContrast, 0.12, "key: the Pin must not be a flat grey slab (\(keyContrast))")
        }
    }

    /// How far the control's face (left of the glyph) is from the surface
    /// just outside its rounded corner, in sRGB luminance.
    private func fillToSurfaceDifference(_ image: NSImage) throws -> Double {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        func luminance(_ x: Int, _ y: Int) throws -> Double {
            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
        }
        let face = try luminance(Int(Double(bitmap.pixelsWide) * 0.18), bitmap.pixelsHigh / 2)
        let surface = try luminance(1, 1)
        return abs(face - surface)
    }

    private func attach(_ image: NSImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
