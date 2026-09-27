import AppKit
import XCTest

final class AtticUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        if name.contains("testMainPanelIdle") {
            app.launchEnvironment["ATTIC_UI_TEST_HOVER_MONITOR"] = "1"
        }
        if name.contains("RecentlyDeleted") {
            // A deleted task (with a subtask) and a deleted note in the
            // in-memory UI-test store.
            app.launchEnvironment["ATTIC_UI_TEST_SEED_RECENTLY_DELETED"] = "1"
        }
        forwardOwnedAttachmentRoot(to: app)
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 5)
        )
    }

    private func forwardOwnedAttachmentRoot(to application: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["ATTIC_TEST_ATTACHMENT_ROOT"],
              let token = environment[
                "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
              ] else {
            return
        }
        application.launchEnvironment["ATTIC_TEST_ATTACHMENT_ROOT"] = root
        application.launchEnvironment[
            "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
        ] = token
    }

    /// The main Attic panel stays visible under UI testing and is docked over
    /// the right side of the default 1024pt CI display. Move Settings into the
    /// clear work area before interacting with controls that otherwise exist
    /// but are correctly reported as not hittable behind that panel.
    private func openSettings(section identifier: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Attic Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let distanceToLeftInset = max(0, settings.frame.minX - 12)
        if distanceToLeftInset > 1 {
            let titleBar = settings.coordinate(
                withNormalizedOffset: CGVector(dx: 0.25, dy: 0.02)
            )
            titleBar.click(
                forDuration: 0.1,
                thenDragTo: titleBar.withOffset(
                    CGVector(dx: -distanceToLeftInset, dy: 0)
                ),
                withVelocity: .slow,
                thenHoldForDuration: 0.1
            )
        }
        let section = settings.descendants(matching: .any)[identifier]
        XCTAssertTrue(section.waitForExistence(timeout: 3))
        XCTAssertTrue(section.isHittable)
        section.click()
        return settings
    }

    /// Distance kept between a Settings control and the floating Attic panel's
    /// lower edge. A control that merely touches that edge still reports as
    /// hittable while its click is swallowed by the panel above it, so the
    /// reveal leaves real clearance instead of lining the two frames up.
    private static let settingsControlClearance: CGFloat = 40

    /// Largest single scroll step; the page is short enough that one step can
    /// always cover the distance from a control to the bottom of the band.
    private static let settingsScrollStep: CGFloat = 450

    /// How the last gesture left the control it was aimed at.
    private enum GestureOutcome {
        /// The control travelled in the requested direction.
        case moved
        /// The page or window was already at its limit.
        case pinned
        /// The control moved the other way, which also happens while the sign
        /// of XCUI's wheel delta is still being worked out.
        case backwards
    }

    /// Which wheel sign carries the page towards its end on this Xcode. The
    /// first gesture that moves a control the opposite way flips this for the
    /// rest of the test, so the reveal never guesses twice.
    private var scrollTowardsEndSign: CGFloat = 1

    /// Movement below this is jitter rather than a gesture response.
    private static let settingsGestureTolerance: CGFloat = 2

    /// Report how a gesture moved the control, given its travel in the
    /// direction the gesture asked for.
    private static func outcome(for travel: CGFloat) -> GestureOutcome {
        if travel >= settingsGestureTolerance { return .moved }
        if travel <= -settingsGestureTolerance { return .backwards }
        return .pinned
    }

    /// Slide the window by `deltaY` and report whether the control followed.
    /// A window that has reached the bottom of the display stays where it is,
    /// which is the caller's cue to move the control by scrolling instead.
    private func slideSettingsWindow(
        _ settings: XCUIElement,
        by deltaY: CGFloat,
        moving element: XCUIElement
    ) -> GestureOutcome {
        guard abs(deltaY) > 1 else { return .pinned }
        let before = element.frame
        let titleBar = settings.coordinate(
            withNormalizedOffset: CGVector(dx: 0.25, dy: 0.02)
        )
        titleBar.click(
            forDuration: 0.1,
            thenDragTo: titleBar.withOffset(CGVector(dx: 0, dy: deltaY)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        guard let after = settledFrame(of: element, differingFrom: before) else { return .pinned }
        let travelled = after.minY - before.minY
        return Self.outcome(for: deltaY > 0 ? travelled : -travelled)
    }

    /// Scroll the page so the control travels in the requested direction,
    /// reporting whether it did. A page at the end of its range leaves the
    /// control in place.
    private func scrollPage(
        _ page: XCUIElement,
        element: XCUIElement,
        towardsTop: Bool,
        distance: CGFloat
    ) -> GestureOutcome {
        let before = element.frame
        let delta = (towardsTop ? -1 : 1) * scrollTowardsEndSign * distance
        // Element-scoped scroll asks XCTest to find the ScrollView's hit
        // point, which can be below the display after moving Settings. Use
        // the visible part of its empty leading gutter instead of its center.
        let pageFrame = page.frame
        let band = settingsBand()
        let top = max(pageFrame.minY + 8, band.top)
        let bottom = min(pageFrame.maxY - 8, band.bottom)
        guard bottom > top else {
            XCTFail("Settings page must have a visible scroll surface")
            return .pinned
        }
        // The application AX frame can be infinite, and a ScrollView-rooted
        // coordinate still resolves its off-screen hit point. The Settings
        // close button stays visible when the window moves; use its finite
        // frame as the origin for a scroll in the page's empty gutter.
        let anchor = app.windows["Attic Settings"].buttons[XCUIIdentifierCloseWindow]
        let anchorFrame = anchor.frame
        guard anchorFrame.minX.isFinite, anchorFrame.minY.isFinite,
              anchor.isHittable else {
            XCTFail("Settings scroll anchor must be visible and finite")
            return .pinned
        }
        anchor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: pageFrame.minX + 8 - anchorFrame.minX,
                                 dy: (top + bottom) / 2 - anchorFrame.minY))
            .scroll(byDeltaX: 0, deltaY: delta)
        guard let after = settledFrame(of: element, differingFrom: before) else { return .pinned }
        let travelled = before.minY - after.minY
        let outcome = Self.outcome(for: towardsTop ? travelled : -travelled)
        if outcome == .backwards {
            // The running Xcode applied the opposite sign: remember it and let
            // the caller re-measure the control rather than guessing again.
            scrollTowardsEndSign = -scrollTowardsEndSign
        }
        return outcome
    }

    /// The control's frame once it has reacted to the last gesture, or nil
    /// when it did not move within a second.
    private func settledFrame(of element: XCUIElement, differingFrom before: CGRect) -> CGRect? {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let frame = element.frame
            if frame != before { return frame }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    /// The vertical band, in accessibility (top-left origin) coordinates,
    /// where a Settings control can be clicked. Its lower edge is the top of
    /// the Dock: the Settings window is taller than this display, so once the
    /// window is slid down to clear the floating panel its last rows end up
    /// behind the Dock, and a control that cannot be scrolled above the Dock
    /// can only be reached by raising the window again.
    private func settingsBand() -> (top: CGFloat, bottom: CGFloat) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return (44, 768 - 73)
        }
        // Screen frames use the bottom-left origin of the primary screen;
        // accessibility frames grow downwards from its top edge.
        let primaryHeight = (NSScreen.screens.first ?? screen).frame.height
        let visible = screen.visibleFrame
        return (primaryHeight - visible.maxY + 8, primaryHeight - visible.minY - 8)
    }

    /// The lowest screen position a control may keep when the window is
    /// raised: the panel's lower edge when the panel covers the control's
    /// column, the top of the band otherwise.
    private static func settingsCeiling(
        for frame: CGRect,
        panel: CGRect,
        bandTop: CGFloat
    ) -> CGFloat {
        let sharesPanelColumn = frame.minX < panel.maxX && frame.maxX > panel.minX
        return sharesPanelColumn ? panel.maxY + settingsControlClearance : bandTop
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app = nil
    }

    /// Bring a Settings control into reach before interacting with it. Two
    /// ordinary windows cover a Settings control on a small display: the main
    /// panel floats over the window's right-hand controls, and the Dock covers
    /// the window's last rows once the window has been slid down to clear that
    /// panel. This slides the window (never resizing it) and scrolls the page
    /// until the control sits in the band between the panel and the Dock, and
    /// re-measures actual frames after every gesture; a stale `isHittable`
    /// reading is exactly what let a covered control through to a click that
    /// could not land. Callers still assert that the control is hittable.
    private func revealSettingsControl(
        _ element: XCUIElement,
        in settings: XCUIElement,
        page: XCUIElement
    ) {
        let panel = app.dialogs.firstMatch
        guard element.waitForExistence(timeout: 3), panel.exists else { return }
        let band = settingsBand()
        for _ in 0..<8 {
            let panelFrame = panel.frame
            let frame = element.frame
            guard frame.width > 0, frame.height > 0,
                  frame.minY.isFinite, frame.maxY.isFinite else { return }
            // Scrolling can leave an element with a valid AX frame outside
            // the page's clipped viewport. Moving the whole window cannot
            // reveal it: first scroll it back into the page, then resolve
            // screen/panel occlusion below.
            let viewport = page.frame.intersection(settings.frame)
            if !viewport.isNull, frame.minY < viewport.minY + 8 {
                let needed = viewport.minY + 8 - frame.minY
                switch scrollPage(page, element: element, towardsTop: false,
                                  distance: min(needed, Self.settingsScrollStep)) {
                case .moved, .backwards: continue
                case .pinned: return
                }
            }
            if !viewport.isNull, frame.maxY > viewport.maxY - 8 {
                let needed = frame.maxY - viewport.maxY + 8
                switch scrollPage(page, element: element, towardsTop: true,
                                  distance: min(needed, Self.settingsScrollStep)) {
                case .moved, .backwards: continue
                case .pinned: return
                }
            }
            let panelEdge = panelFrame.maxY + Self.settingsControlClearance
            let sharesPanelColumn = frame.minX < panelFrame.maxX && frame.maxX > panelFrame.minX
            // A control that only grazes the panel's lower edge still reports
            // as hittable while the panel swallows the click, so treat the
            // whole strip up to `panelEdge` as covered.
            if frame.intersects(panelFrame)
                || (sharesPanelColumn && frame.minY < panelEdge - Self.settingsGestureTolerance) {
                // The panel covers this control's hit point. Sliding the
                // window down is the direct fix; when the window has already
                // reached the bottom of the display, bring the control down by
                // scrolling the page towards its top instead.
                let needed = panelEdge - frame.minY
                switch slideSettingsWindow(settings, by: needed, moving: element) {
                case .moved, .backwards: continue
                case .pinned: break
                }
                switch scrollPage(page, element: element, towardsTop: false, distance: min(needed, Self.settingsScrollStep)) {
                case .moved, .backwards: continue
                case .pinned: return
                }
            }
            if frame.maxY > band.bottom {
                // Under the Dock, or past the bottom of the display. Scrolling
                // is the gentler move, so try it first and raise the window
                // only when the page has no room left to scroll.
                let needed = frame.maxY - band.bottom
                switch scrollPage(page, element: element, towardsTop: true, distance: min(needed, Self.settingsScrollStep)) {
                case .moved, .backwards: continue
                case .pinned: break
                }
                let room = frame.minY - Self.settingsCeiling(
                    for: frame, panel: panelFrame, bandTop: band.top
                )
                guard room > 1 else { return }
                switch slideSettingsWindow(settings, by: -min(needed, room), moving: element) {
                case .moved, .backwards: continue
                case .pinned: return
                }
            }
            if frame.minY < band.top {
                let needed = band.top - frame.minY
                switch scrollPage(page, element: element, towardsTop: false, distance: min(needed, Self.settingsScrollStep)) {
                case .moved, .backwards: continue
                case .pinned: break
                }
                switch slideSettingsWindow(settings, by: needed, moving: element) {
                case .moved, .backwards: continue
                case .pinned: return
                }
            }
            return
        }
    }

    /// The Tasks page's add bar (the chip-drawing native field).
    private var addBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "AtticTokenField").firstMatch
    }

    func testMainPanelIdleRetainsTaskDraftThenHidesCleanEditor() throws {
        let field = addBar
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("Keep this unfinished draft")
        let outside = app.dialogs.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: -100, dy: 220))
        outside.hover()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !field.exists }, object: nil)
        hidden.isInverted = true
        wait(for: [hidden], timeout: 4)
        XCTAssertEqual(field.value as? String, "Keep this unfinished draft")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        outside.hover()
        XCTAssertTrue(field.waitForNonExistence(timeout: 8), "A clean idle main entry must stop acting as a pin")
    }

    func testMainPanelIdleHidesAutosavedNoteWithEditorFocus() throws {
        addBar.click()
        app.typeKey("2", modifierFlags: .command)
        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()
        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        body.click()
        body.typeText("An autosaved note can rest.")
        app.dialogs.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: -100, dy: 220)).hover()
        XCTAssertTrue(body.waitForNonExistence(timeout: 8), "Autosaved Notes focus must not permanently pin the main panel")
    }

    func testAgentAccessConnectionDetailsRemainAccessible() throws {
        let settings = openSettings(section: "settings-nav-agentAccess")
        let page = settings.descendants(matching: .any)["settings-page-agentAccess"]
        let toggle = settings.descendants(matching: .any)["setting-agent-access"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        revealSettingsControl(toggle, in: settings, page: page)
        XCTAssertTrue(toggle.isHittable, "Settings control must be reachable without resizing the window")
        if settings.descendants(matching: .any)["settings-agent-disabled-message"].exists {
            toggle.click()
        }
        let endpoint = settings.descendants(matching: .any)["settings-agent-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        // Request the full AX subtree: the selectable endpoint previously
        // recursed through its overridden accessibility label on macOS.
        XCTAssertTrue(settings.debugDescription.contains("127.0.0.1"))
        let copy = settings.buttons["settings-copy-agent-endpoint"]
        revealSettingsControl(copy, in: settings, page: page)
        XCTAssertTrue(copy.isHittable, "Settings control must be reachable without resizing the window")
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        XCTAssertTrue(settings.buttons["settings-copy-agent-setup"].isEnabled)
        revealSettingsControl(toggle, in: settings, page: page)
        XCTAssertTrue(toggle.isHittable, "Settings control must be reachable without resizing the window")
        toggle.click()
        XCTAssertTrue(settings.descendants(matching: .any)["settings-agent-disabled-message"].waitForExistence(timeout: 3))
    }

    /// Phase 1 Settings: the Appearance page is built from the design
    /// system. Mode is three tiles, palettes are tiles, and Surface and Tint
    /// are native ⌃⌄ pop-ups (menu items), with Tint length under Advanced.
    func testAppearanceControlsCoverEveryPaletteSurfaceAndTint() throws {
        let settings = openSettings(section: "settings-nav-appearance")
        let page = settings.descendants(matching: .any)["settings-page-appearance"]
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        let surface = settings.descendants(matching: .any)["setting-panel-surface"]
        let tint = settings.descendants(matching: .any)["setting-panel-tint"]
        let preview = settings.descendants(matching: .any)["setting-appearance-preview"]

        func reveal(_ element: XCUIElement) {
            revealSettingsControl(element, in: settings, page: page)
            XCTAssertTrue(element.isHittable, "Settings control must be reachable without resizing the window")
        }
        func waitFor(_ message: @autoclosure () -> String, _ condition: @escaping () -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, message())
        }
        func assertSelected(_ element: XCUIElement) {
            waitFor("Expected selection: \(element.label)") {
                element.isSelected || (element.value as? String) == "Selected"
            }
        }
        func choose(_ title: String, in popUp: XCUIElement) {
            reveal(popUp)
            popUp.click()
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "the pop-up offers \(title)")
            item.click()
            waitFor("\(popUp.label) shows \(title)") { (popUp.value as? String) == title }
        }
        func recordPanel(_ name: String) {
            // Evidence only: the live panel, and the Settings window as the
            // user sees it at that moment.
            let attachment = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let window = XCTAttachment(screenshot: settings.screenshot())
            window.name = "Settings-\(name)"
            window.lifetime = .keepAlways
            add(window)
        }

        XCTAssertTrue(preview.waitForExistence(timeout: 3), "the live preview is one element")
        XCTAssertTrue((preview.label).hasPrefix("Panel preview:"), "the preview says what it shows")
        XCTAssertTrue(surface.exists)
        XCTAssertTrue(tint.exists)
        XCTAssertFalse(settings.descendants(matching: .any)["setting-translucency"].exists)
        XCTAssertFalse(settings.descendants(matching: .any)["setting-glass-style"].exists)
        XCTAssertFalse(settings.sliders["setting-panel-gradient-coverage"].exists)

        // Every surface, on every palette, in both explicit appearances:
        // nothing is ever unavailable and no choice is erased by another.
        let themes = ["original", "midnightCobalt", "porcelainVapor", "smokedUmber",
                      "electricBlue", "seaGlass", "amethyst"]
        for scheme in ["light", "dark"] {
            let schemeControl = settings.buttons["setting-appearance-\(scheme)"]
            reveal(schemeControl)
            schemeControl.click()
            assertSelected(schemeControl)
            for theme in themes {
                let choice = settings.buttons["setting-panel-theme-\(theme)"]
                XCTAssertTrue(choice.waitForExistence(timeout: 3))
                reveal(choice)
                choice.click()
                assertSelected(choice)
                for style in ["Solid", "Glass", "Frosted"] {
                    choose(style, in: surface)
                }
                // Evidence only: these screenshots do not assert contrast or
                // physical desktop readability on their own.
                recordPanel("Theme-\(theme)-\(scheme)")
            }
        }

        let tintLength = settings.sliders["setting-panel-tint-length"]
        XCTAssertTrue(tintLength.waitForExistence(timeout: 3), "Tint has a Length slider under Advanced")
        for level in ["Subtle", "Vivid", "Bold", "Off"] {
            choose(level, in: tint)
            if level == "Bold" {
                reveal(tintLength)
                waitFor("Length is adjustable while a Tint step is on") { tintLength.isEnabled }
                // XCUITest reports a macOS slider's raw value (0.3...1), not
                // the spoken description; accept either. The drag is
                // pixel-positioned and lands differently from run to run, so
                // check that each drag clearly moves the length, not where it
                // lands exactly.
                func length() -> Double? {
                    if let number = tintLength.value as? NSNumber { return number.doubleValue }
                    guard let text = tintLength.value as? String else { return nil }
                    if text == "Full height" { return 1 }
                    guard text.hasSuffix(" percent of the panel"), let percent = Double(text.prefix { $0.isNumber }) else { return nil }
                    return percent / 100
                }
                tintLength.adjust(toNormalizedSliderPosition: 0)
                waitFor("Length moves toward its shortest; it reads \(String(describing: tintLength.value))") {
                    length().map { $0 <= 0.45 } ?? false
                }
                let short = length() ?? 0
                recordPanel("Tint-\(level)-Short")
                tintLength.adjust(toNormalizedSliderPosition: 1)
                waitFor("Length moves toward its longest; it reads \(String(describing: tintLength.value))") {
                    length().map { $0 >= 0.8 && $0 - short >= 0.35 } ?? false
                }
            }
            recordPanel("Tint-\(level)")
        }
        waitFor("Length is disabled while Tint is Off") { !tintLength.isEnabled }

        choose("Glass", in: surface)
        let systemAppearance = settings.buttons["setting-appearance-system"]
        reveal(systemAppearance)
        systemAppearance.click()
        assertSelected(systemAppearance)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.descendants(matching: .any)["panel-section-picker"].exists)
    }

    func testAppearancePickerSelectionTransitions() throws {
        let settings = openSettings(section: "settings-nav-appearance")
        let page = settings.descendants(matching: .any)["settings-page-appearance"]
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        let surface = settings.descendants(matching: .any)["setting-panel-surface"]
        func reveal(_ element: XCUIElement) {
            revealSettingsControl(element, in: settings, page: page)
            XCTAssertTrue(element.isHittable)
        }
        func waitFor(_ message: @autoclosure () -> String, _ condition: @escaping () -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, message())
        }
        let original = settings.buttons["setting-panel-theme-original"]
        reveal(original)
        original.click()
        // Surface never depends on the mode or the palette: its pop-up always
        // offers all three.
        for scheme in ["dark", "light", "dark"] {
            let choice = settings.buttons["setting-appearance-\(scheme)"]
            reveal(choice)
            choice.click()
            reveal(surface)
            surface.click()
            waitFor("Every surface stays available in \(scheme)") {
                ["Solid", "Glass", "Frosted"].allSatisfy { self.app.menuItems[$0].exists }
            }
            app.typeKey(.escape, modifierFlags: [])
        }
        for style in ["Frosted", "Solid", "Glass"] {
            reveal(surface)
            surface.click()
            let item = app.menuItems[style]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.click()
            waitFor("Surface selection must settle on \(style)") { (surface.value as? String) == style }
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
    }

    /// The sidebar lists every page (Recently Deleted included), each opens
    /// its page in the content card, and the back button (⌘[) returns to the
    /// page before; it is a disabled ghost with no history.
    func testSettingsSidebarOpensEveryPageAndBackReturns() throws {
        let settings = openSettings(section: "settings-nav-general")
        let back = settings.buttons["settings-back"]
        XCTAssertTrue(settings.descendants(matching: .any)["settings-page-general"].waitForExistence(timeout: 3))
        for section in ["panel", "appearance", "recentlyDeleted", "agentAccess", "about", "general"] {
            let row = settings.descendants(matching: .any)["settings-nav-\(section)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.click()
            XCTAssertTrue(settings.descendants(matching: .any)["settings-page-\(section)"].waitForExistence(timeout: 3),
                          "\(section) opens its page")
        }
        XCTAssertTrue(back.isEnabled)
        back.click()
        XCTAssertTrue(settings.descendants(matching: .any)["settings-page-about"].waitForExistence(timeout: 3))
        settings.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(settings.descendants(matching: .any)["settings-page-agentAccess"].waitForExistence(timeout: 3))

        // General: Haptics is a switch that remembers its state.
        settings.descendants(matching: .any)["settings-nav-general"].click()
        let haptics = settings.descendants(matching: .any)["setting-haptics"]
        XCTAssertTrue(haptics.waitForExistence(timeout: 3))
        // On the 1024 pt CI display the panel covers part of Settings.
        revealSettingsControl(haptics, in: settings,
                              page: settings.descendants(matching: .any)["settings-page-general"])
        XCTAssertTrue(haptics.isHittable, "Settings control must be reachable without resizing the window")
        let before = String(describing: haptics.value)
        haptics.click()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in String(describing: haptics.value) != before }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, "Haptics toggles")
        haptics.click()
    }

    /// Recently Deleted lists what was deleted (a task with its subtask, a
    /// note; seeded in the UI-test store), searches it, restores an item,
    /// and empties the rest after a clear confirmation.
    func testRecentlyDeletedRestoresSearchesAndEmpties() throws {
        let settings = openSettings(section: "settings-nav-recentlyDeleted")
        let page = settings.descendants(matching: .any)["settings-page-recentlyDeleted"]
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        let restoreTask = settings.buttons["Restore Plan the launch"]
        let restoreNote = settings.buttons["Restore Meeting notes"]
        XCTAssertTrue(restoreTask.waitForExistence(timeout: 3), "the deleted task is listed")
        XCTAssertTrue(restoreNote.exists, "the deleted note is listed")
        XCTAssertTrue(settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "with 1 subtask", "with 1 subtask")).firstMatch.exists,
            "its subtask is counted")

        let search = settings.textFields["recently-deleted-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        revealSettingsControl(search, in: settings, page: page)
        search.click()
        search.typeText("meeting")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: restoreTask)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "search narrows the list")
        XCTAssertTrue(restoreNote.exists)
        search.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(restoreTask.waitForExistence(timeout: 3))
        revealSettingsControl(restoreTask, in: settings, page: page)
        restoreTask.click()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: restoreTask)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed, "a restored task leaves the list")

        let empty = settings.buttons["recently-deleted-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 3))
        revealSettingsControl(empty, in: settings, page: page)
        empty.click()
        // The native alert's destructive button (identified, or by its title
        // where the alert does not carry the identifier through).
        let confirm = app.descendants(matching: .button).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "recently-deleted-confirm-empty", "Empty"
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "emptying asks first")
        confirm.click()
        XCTAssertTrue(settings.descendants(matching: .any)["recently-deleted-empty-state"].waitForExistence(timeout: 3))
        XCTAssertFalse(restoreNote.exists)
    }

    func testNotesEditorKeepsDraftWhileBrowsingSavedNotes() throws {
        app.typeKey("2", modifierFlags: .command)

        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let title = app.textFields["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        app.typeText("Live Notes UI")
        app.typeKey(.return, modifierFlags: [])

        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 2))
        let controls = app.descendants(matching: .any)["note-entry-bar"]
        XCTAssertGreaterThan(body.frame.height, app.dialogs.firstMatch.frame.height * 0.5,
                             "An attachment-free note should use the workspace, not a fixed short editor")
        XCTAssertLessThan(abs(controls.frame.minY - body.frame.maxY), 20,
                          "Writing should extend down to the note controls")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText("The active draft stays mounted while the library is open.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(body.exists)

        XCTAssertFalse(app.buttons["save-note"].exists, "Autosave needs no redundant save control")
        XCTAssertTrue(body.exists, "Autosaving must keep the focused workspace open")

        let browse = app.buttons["browse-saved-notes"]
        XCTAssertTrue(browse.waitForExistence(timeout: 2))
        browse.click()

        let drawer = app.descendants(matching: .any)["saved-notes-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        let savedTitle = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@",
            "Live Notes UI"
        )).firstMatch
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 2))

        let returnToWriting = app.buttons["return-to-writing"]
        XCTAssertTrue(returnToWriting.waitForExistence(timeout: 2))
        returnToWriting.click()

        XCTAssertTrue(body.waitForExistence(timeout: 2))
        XCTAssertEqual(
            body.value as? String,
            "The active draft stays mounted while the library is open."
        )
        XCTAssertTrue(app.buttons["add-note-attachment"].exists)
        XCTAssertFalse(app.staticTexts["Drop files here"].exists)
    }

    func testNativePanelResizeKeepsDockedEdgesAndMinimumSize() throws {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        app.buttons["panel-pin-button"].click()
        let initial = panel.frame
        let left = panel.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        left.click(forDuration: 0.1,
                   thenDragTo: left.withOffset(CGVector(dx: -90, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(panel.frame.width, initial.width + 90, accuracy: 3)
        XCTAssertEqual(panel.frame.height, initial.height, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, initial.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)

        let wider = panel.frame
        let bottom = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
        bottom.click(forDuration: 0.1,
                     thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: 80)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(panel.frame.height, wider.height + 80, accuracy: 3)
        XCTAssertEqual(panel.frame.width, wider.width, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)

        let larger = panel.frame
        let corner = panel.coordinate(withNormalizedOffset: CGVector(
            dx: 25 / larger.width, dy: 1 - 25 / larger.height
        ))
        corner.click(forDuration: 0.1,
                     thenDragTo: corner.withOffset(CGVector(dx: 240, dy: -240)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        // AX exposes AtticPanel.visibleContentFrame. Its current minimum is
        // PanelContentSize.min (320) by PanelGeometry.minimumHeight (460).
        XCTAssertEqual(panel.frame.width, 320, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 460, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, initial.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, initial.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["panel-pin-button"].isSelected)
        XCTAssertTrue(addBar.isHittable)
        XCTAssertTrue(app.buttons["panel-section-tasks"].isHittable)
    }

    func testNoteTextScrollsUnderStationaryControls() throws {
        app.typeKey("2", modifierFlags: .command)
        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()
        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        let scroll = app.scrollViews["note-document-scroll"]
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText((1...30).map { String($0) }.joined(separator: "\n"))
        let pin = app.buttons["panel-pin-button"]
        let controls = app.descendants(matching: .any)["note-entry-bar"]
        XCTAssertTrue(scroll.exists)
        XCTAssertLessThan(scroll.frame.minY, pin.frame.minY)
        XCTAssertGreaterThan(scroll.frame.maxY, controls.frame.maxY)
        let pinFrame = pin.frame
        let controlsFrame = controls.frame
        // AppKit's scroll view delegates hit testing to its document; XCTest
        // cannot synthesize a wheel hit on the scroll-view AX wrapper. Native
        // Home/Page Down scroll the same viewport without relocating controls.
        app.typeKey(.home, modifierFlags: [])
        let title = app.textFields["note-title"]
        XCTAssertTrue(title.isHittable)
        let initialTitleY = title.frame.minY
        app.typeKey(.pageDown, modifierFlags: [])
        XCTAssertEqual(pin.frame, pinFrame)
        XCTAssertEqual(controls.frame, controlsFrame)
        XCTAssertLessThan(title.frame.minY, initialTitleY)
        let capture = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
        capture.name = "Note-text-under-fixed-controls"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testNotesBodyPreservesFocusAcrossIncrementalTyping() throws {
        app.typeKey("2", modifierFlags: .command)

        let newNote = app.buttons["new-note-empty-state"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let body = app.textViews["note-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 2))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Send separate key events instead of one `typeText` batch. This
        // catches focus bridges that surrender first responder after the
        // SwiftUI update caused by each character.
        app.typeText("a")
        app.typeText("b")
        app.typeText("c")

        XCTAssertEqual(body.value as? String, "abc")
    }

}
