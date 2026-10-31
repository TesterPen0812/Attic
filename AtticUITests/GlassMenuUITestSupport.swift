import XCTest

/// Attic's menus are glass cards, not `NSMenu` (outdated: glass menus,
/// `37174a4d` "Dropdowns and menus: draft C" through the C2 merge
/// `a5d565fe`; Accepted "Shapes" and "Radii" draw them as squircle cards).
/// Each card is an AXMenu of AXMenuItems for VoiceOver, and the system's
/// hit test finds the right item at every row, but XCUITest's own menu path
/// ("Find the Menu", "Scroll to menu item") never accepts them, so a plain
/// `click()` or `hover()` on one reports "Not hittable".
///
/// These act through the pointer instead, as `clickDropdownRow` does for the
/// dropdowns, and keep what the native path checked: the item exists with
/// its label, it lies inside its open card, and the click lands on it and
/// does its command (each test checks the command). Every suite uses them.
/// The pointer goes to the item's own accessibility frame: until w4 those
/// frames were mirrored top to bottom inside the card, so the pointer sent
/// to the first item chose the last (`AtticGlassMenuTests
/// .testEveryItemsFrameIsItsOwnRowOnScreen`).
extension XCTestCase {
    /// Moves the pointer onto an open glass card's item (it lights; a
    /// submenu's row opens its card).
    func hoverGlassMenuItem(_ item: XCUIElement, titled title: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        pointAtGlassMenuItem(item, titled: title, in: app, file: file, line: line)
    }

    /// Moves the pointer onto an open glass card's item, then clicks it.
    func clickGlassMenuItem(_ item: XCUIElement, titled title: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        pointAtGlassMenuItem(item, titled: title, in: app, file: file, line: line)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func pointAtGlassMenuItem(_ item: XCUIElement, titled title: String, in app: XCUIApplication,
                                      file: StaticString, line: UInt) {
        XCTAssertTrue(item.waitForExistence(timeout: 3), "the menu offers \(title)", file: file, line: line)
        let label = item.label
        XCTAssertTrue(label.hasPrefix(title), "the item reads \(title): \(label)", file: file, line: line)
        let frame = item.frame
        XCTAssertGreaterThan(frame.width, 0, "\(title) has a rendered frame", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        // Its own card: an open menu (the menu bar's have no size until
        // opened) that holds it as a direct item, not through a submenu.
        let own = NSPredicate(format: "label == %@", label)
        let card = app.menus.containing(own).allElementsBoundByIndex.last {
            $0.frame.width > 0 && $0.frame.height > 0 && $0.children(matching: .menuItem).matching(own).count > 0
        }
        XCTAssertNotNil(card, "\(title) sits in an open menu card", file: file, line: line)
        if let card {
            XCTAssertTrue(card.frame.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(title) \(frame) lies inside its card \(card.frame)", file: file, line: line)
        }
        // The pointer goes to the item's centre, inside its card. What it
        // does there is the test's next check: a submenu opens, Return runs
        // the lit item, a click does the item's command.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    }
}
