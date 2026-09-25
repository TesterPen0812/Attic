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

    /// An explicit open on Tasks (quick capture, Show Attic) puts the
    /// keyboard in the add bar, and the add bar draws no focus ring: text
    /// typed right away lands there. (`ATTIC_UI_TEST_HOVER_MONITOR` opens
    /// the panel the way quick capture does.)
    func testAnExplicitOpenFocusesTheAddBarWithoutARing() throws {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_HOVER_MONITOR"] = "1"
        app.launchArguments += ["-appearancePreference", "light", "-panelSurfaceStyle", "solid"]
        app.launch()
        app.activate()
        // The legacy add bar, or the Tasks stream's token field once it lands.
        let addBar = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["quick-entry-title", "AtticTokenField"]))
            .firstMatch
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (addBar.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(addBar.value(forKey: "hasKeyboardFocus") as? Bool, true, "the add bar has the keyboard on open")

        let image = addBar.screenshot().image
        attach(image, name: "add-bar-on-open")
        XCTAssertLessThan(try accentFraction(image), 0.002, "no focus ring on open")

        app.typeText("Typed on open")
        let typed = NSPredicate(format: "value CONTAINS %@", "Typed on open")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: typed, evaluatedWith: addBar)], timeout: 3), .completed,
                       "what is typed on open lands in the add bar")
    }

    /// The share of pixels in the system's focus-ring blue (Original's accent
    /// is grey, so nothing else in the add bar is blue).
    private func accentFraction(_ image: NSImage) throws -> Double {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent - c.redComponent > 0.25, c.blueComponent > 0.45 { blue += 1 }
            }
        }
        return Double(blue) / Double(max(1, bitmap.pixelsWide * bitmap.pixelsHigh))
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
