import XCTest

/// XCUITest clicks are real system events, so a click whose point is not on
/// the app's own window lands on whatever is there (on 22 Nov a synthetic
/// click on the Air's wallpaper pushed the owner's windows aside). This click
/// goes ahead only when the element is hittable and the point it clicks lies
/// inside one of the app's own windows; otherwise the test fails and nothing
/// is clicked.
extension XCUIElement {
    func clickInsideOwnWindow(of app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard exists, isHittable else {
            XCTFail("not clicked: \(identifier.isEmpty ? label : identifier) is not hittable", file: file, line: line)
            return
        }
        let target = CGPoint(x: frame.midX, y: frame.midY)
        // The app's windows, plus panel-shaped top-level elements (the panel
        // is not always typed as a window), never the screen-wide menu bar.
        let windows = app.windows.allElementsBoundByIndex.map(\.frame)
            + app.children(matching: .any).allElementsBoundByIndex.map(\.frame)
                .filter { $0.width < 900 && $0.height > 300 }
        guard windows.contains(where: { !$0.isEmpty && $0.contains(target) }) else {
            XCTFail("not clicked: \(identifier.isEmpty ? label : identifier) at \(target) is outside the app's windows \(windows)",
                    file: file, line: line)
            return
        }
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
