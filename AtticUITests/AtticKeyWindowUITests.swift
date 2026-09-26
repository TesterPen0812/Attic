import AppKit
import XCTest

/// The on-screen key-window check (spec § Appearance: native Liquid Glass
/// renders flat in a window that is not key, which the drawn appearance
/// matrix cannot catch). The panel is revealed the way the corner reveals
/// it, another app is brought to the front (so Attic holds no keyboard),
/// the whole panel is captured, then it is clicked (it becomes key) and
/// captured again, in Light and Dark. Each capture waits for the key state
/// the panel reports, never a fixed time. The controls must read as raised
/// in both states, never as the flat grey slab inactive glass draws.
final class AtticKeyWindowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testControlsStayRaisedBeforeAndAfterThePanelIsKeyInLight() throws {
        try check(mode: "light")
    }

    func testControlsStayRaisedBeforeAndAfterThePanelIsKeyInDark() throws {
        try check(mode: "dark")
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
        let addBar = app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
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

    private func check(mode: String) throws {
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchEnvironment["ATTIC_UI_TEST_NONKEY_REVEAL"] = "1"
        app.launchArguments += ["-appearancePreference", mode, "-panelSurfaceStyle", "solid"]
        app.launch()
        let pin = app.buttons["panel-pin-button"]
        let keyState = app.descendants(matching: .any)["panel-key-state"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(keyState.waitForExistence(timeout: 5))

        // Another app in front holds the keyboard, as when the corner
        // reveals the panel over the app the person is typing in.
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
        try waitForKeyState("not key", keyState)
        // The panel is a non-activating panel: XCUI lists it as a dialog.
        let panel = app.dialogs.containing(.button, identifier: "panel-pin-button").firstMatch
        let nonKeyPanel = panel.screenshot().image
        let nonKeyPin = pin.screenshot().image
        attach(nonKeyPanel, name: "panel-\(mode)-not-key")
        attach(nonKeyPin, name: "pin-\(mode)-not-key")

        // A click on blank surface makes the panel key, as in real use.
        pin.coordinate(withNormalizedOffset: CGVector(dx: 2.6, dy: 0.5)).click()
        try waitForKeyState("key", keyState)
        let keyPanel = panel.screenshot().image
        let keyPin = pin.screenshot().image
        attach(keyPanel, name: "panel-\(mode)-key")
        attach(keyPin, name: "pin-\(mode)-key")

        for (image, state) in [(nonKeyPin, "not key"), (keyPin, "key")] {
            let relief = try verticalRelief(image)
            XCTAssertGreaterThan(relief, Self.minimumRelief,
                                 "\(mode), \(state): the Pin must read as raised, not a flat slab (relief \(relief))")
        }
    }

    /// A flat inactive-glass slab is one even grey from top to bottom; a
    /// raised control (the drawn recipe's sheen and rim, or live glass's
    /// highlight) changes along its height. The spread of luminance down the
    /// control's left face, away from the glyph, in sRGB. Measured on
    /// 2026-09-25 screen captures of the Pin: the flat inactive-glass slab
    /// 0.000; the drawn look 0.009 (Dark) and 0.025 (Light); key glass 0.016
    /// (Light) and 0.020 (Dark). The bar sits well above flat and below all.
    private static let minimumRelief = 0.004

    private func verticalRelief(_ image: NSImage) throws -> Double {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let x = Int(Double(bitmap.pixelsWide) * 0.2)
        var values: [Double] = []
        for y in stride(from: Int(Double(bitmap.pixelsHigh) * 0.12), through: Int(Double(bitmap.pixelsHigh) * 0.88), by: 1) {
            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            values.append(0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent)
        }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private func waitForKeyState(_ expected: String, _ element: XCUIElement) throws {
        let matches = NSPredicate(format: "label == %@ OR value == %@", expected, expected)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: matches, evaluatedWith: element)], timeout: 5), .completed,
                       "the panel reports \(expected) (it reports \(element.label) / \(element.value ?? "nothing"))")
    }

    private func attach(_ image: NSImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
