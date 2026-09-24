import AppKit
import XCTest

/// Real keyboard traversal in the running app: the design system's keyboard
/// lab (a preview-build gallery mode with three live task rows) is launched
/// and activated, and Tab and Shift-Tab are typed as a person types them.
/// Each step reads the window's pixels: the 2 pt accent ring must follow
/// focus from row to row and on to a standalone status circle and a
/// raised button, one ring at a time, and a focused status circle must
/// draw Attic's ring around it instead of the system focus effect.
///
/// Task controls (rows, cards, a standalone status circle) are Tab stops
/// whatever the Full Keyboard Access setting, like text fields: they are
/// the page's content. Generic buttons such as Pin follow the system
/// setting, which this test does not change, so it only requires that Pin,
/// if Tab reaches it, draws Attic's ring.
final class AtticKeyboardFocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launchArguments += ["--attic-gallery", "--attic-gallery-keyboard"]
        app.launch()
        app.activate()
        XCTAssertTrue(lab.waitForExistence(timeout: 20), "The keyboard lab window did not open: \(app.debugDescription)")
        lab.click()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: Reading the rings from pixels

    /// Where keyboard focus shows: a row's ring, the standalone status
    /// circle's ring, or the Pin button's ring (nil when none shows).
    private enum Stop: Equatable, CustomStringConvertible {
        case row(Int), status, pin
        var description: String {
            switch self {
            case let .row(index): "row \(index)"
            case .status: "status circle"
            case .pin: "pin"
            }
        }
    }

    private var lab: XCUIElement { app.windows["Attic Keyboard Lab"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Whether a pixel is the lab's accent (Electric Blue): clearly blue,
    /// never the greys of the surface, hover or text, nor the orange and
    /// red of the priority circles.
    private func isAccent(_ colour: NSColor) -> Bool {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return false }
        return rgb.blueComponent - rgb.redComponent > 0.25 && rgb.blueComponent > 0.45
    }

    /// Most of a small cross of pixels around a point (window points) is the accent.
    private func accent(in bitmap: NSBitmapImageRep, scale: CGFloat, at point: CGPoint) -> Bool {
        var hits = 0
        var total = 0
        for (dx, dy) in [(0.0, 0.0), (0.0, -2.0), (0.0, 2.0), (-0.5, 0.0), (0.5, 0.0)] {
            let x = Int(((point.x + dx) * scale).rounded(.down))
            let y = Int(((point.y + dy) * scale).rounded(.down))
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                  let colour = bitmap.colorAt(x: x, y: y) else { continue }
            total += 1
            if isAccent(colour) { hits += 1 }
        }
        return total > 0 && hits * 2 > total
    }

    /// The ring points (design tokens). A row's highlight is inset 8 pt and
    /// starts 1 pt down; its ring sits 2 pt outside and is 2 pt wide, so its
    /// middle is 3 pt outside, at x = 5. The status circle (16 pt) is centred
    /// in its 28 pt button; its ring's middle is 8 + 3 = 11 pt from the
    /// centre. A raised button's ring middle is 3 pt outside its edge.
    private func ringPoints() -> [(Stop, CGPoint)] {
        let origin = lab.frame.origin
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        var points: [(Stop, CGPoint)] = []
        for index in 0..<3 {
            let frame = element("keyboard-lab-row-\(index)").frame
            points.append((.row(index), local(CGPoint(x: frame.minX + 5, y: frame.minY + 16))))
        }
        let status = element("keyboard-lab-status").frame
        points.append((.status, local(CGPoint(x: status.midX - 11, y: status.midY))))
        let pin = element("keyboard-lab-pin").frame
        points.append((.pin, local(CGPoint(x: pin.minX - 3, y: pin.midY))))
        return points
    }

    /// Every stop whose ring currently shows, read from one window screenshot.
    private func ringsShown() throws -> [Stop] {
        let image = lab.screenshot().image
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(bitmap.pixelsWide) / lab.frame.width
        return ringPoints().filter { accent(in: bitmap, scale: scale, at: $0.1) }.map(\.0)
    }

    /// The one stop showing a ring (failing when two show at once).
    private func focusedStop(file: StaticString = #filePath, line: UInt = #line) throws -> Stop? {
        let shown = try ringsShown()
        XCTAssertLessThanOrEqual(shown.count, 1, "More than one focus ring at once: \(shown)", file: file, line: line)
        return shown.first
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func press(_ shift: Bool = false) {
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: shift ? .shift : [])
    }

    // MARK: Tests

    func testTabAndShiftTabMoveTheFocusRingThroughTaskRowsAndControls() throws {
        // Park the pointer away from the rows so hover fills don't interfere.
        lab.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).hover()

        var forward: [Stop?] = [try focusedStop()]
        for _ in 0..<10 {
            press()
            forward.append(try focusedStop())
        }
        let forwardText = forward.map { $0?.description ?? "none" }.joined(separator: " → ")

        // Tab reaches every row, each drawing the ring while it has focus,
        // in order; the circle inside a row is not a second stop.
        let stops = forward.compactMap { $0 }
        XCTAssertEqual(stops.count, forward.count, "Focus always shows somewhere: \(forwardText)")
        for index in 0..<3 {
            XCTAssertTrue(stops.contains(.row(index)), "Tab brings the ring to row \(index): \(forwardText)")
        }
        // The standalone status circle is a stop too, and draws Attic's
        // ring around the circle (not the system focus effect).
        XCTAssertTrue(stops.contains(.status), "The focused status circle draws its ring: \(forwardText)")
        // One full cycle, in order, repeating: rows, the circle, and Pin
        // only when Full Keyboard Access is on.
        let period = stops.contains(.pin) ? 5 : 4
        let first = try XCTUnwrap(stops.firstIndex(of: .row(0)))
        let expected: [Stop] = period == 5 ? [.row(0), .row(1), .row(2), .status, .pin] : [.row(0), .row(1), .row(2), .status]
        for (offset, stop) in stops.enumerated() {
            let position = ((offset - first) % period + period) % period
            XCTAssertEqual(stop, expected[position], "Tab follows the page order: \(forwardText)")
        }

        // Shift-Tab walks back through the same stops, one at a time.
        var back: [Stop?] = [forward.last!]
        for _ in 0..<period {
            press(true)
            back.append(try focusedStop())
        }
        let backText = back.map { $0?.description ?? "none" }.joined(separator: " → ")
        for offset in 1...period {
            XCTAssertEqual(back[offset], forward[forward.count - 1 - offset], "Shift-Tab retraces Tab (forward: \(forwardText); back: \(backText))")
        }
    }

    func testTheFocusedRowAnswersTheTaskKeys() throws {
        lab.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).hover()
        var stop = try focusedStop()
        for _ in 0..<6 {
            if case .row = stop { break }
            press()
            stop = try focusedStop()
        }
        guard case let .row(index) = stop else { return XCTFail("Tab never focused a row") }
        let title = ["Email beta testers", "Book dentist", "Renew domain"][index]
        let lastAction = app.staticTexts["keyboard-lab-last-action"]
        XCTAssertTrue(lastAction.waitForExistence(timeout: 2))

        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        XCTAssertEqual(text(of: lastAction), "Advance · \(title)")
        // Option-Space (Complete) is not typed here: launchers such as
        // ChatGPT and Raycast take it as a global hot key, so the app may
        // never see it. The hosted unit tests cover it with real key events.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)
        XCTAssertEqual(text(of: lastAction), "Open page · \(title)")
        app.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(text(of: lastAction), "Move to Backlog · \(title)")
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertEqual(text(of: lastAction), "Delete · \(title)")
        // The ring stays on the row throughout.
        XCTAssertEqual(try focusedStop(), .row(index))
    }
}
