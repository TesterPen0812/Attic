import XCTest

/// Real-pointer UAT for the hover-pinned subtask surfaces. `XCUIElement.hover()`
/// and `XCUICoordinate.hover()` move the actual cursor through testmanagerd,
/// so these tests exercise dwell timing, the pointer corridor, focus-loss
/// survival, and window-level Escape — paths unit tests can only simulate at
/// the state-machine layer. All assertions go through accessibility-visible
/// elements of the launched test app only.
///
/// Timing assertions reference the layout constants in
/// `SubtaskPanelLayout` (openDwell 0.35s, closeGrace 0.45s); the waits below
/// are the behavior under test, not synchronization sleeps.
final class SubtaskHoverPinnedUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 5)
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app = nil
    }

    // MARK: - Helpers

    private func element(identifiedBy identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }

    private func transient(_ parentID: String) -> XCUIElement {
        element(identifiedBy: "subtask-panel-\(parentID)")
    }

    private func pinned(_ parentID: String) -> XCUIElement {
        element(identifiedBy: "subtask-pinned-\(parentID)")
    }

    private func anyTransient() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "subtask-panel-"
        )).firstMatch
    }

    private func row(titled title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "task-row-", title
        )).firstMatch
    }

    /// A real pointer move onto the row's center. Element `hover()` goes
    /// through XCUI's hit-point resolution, which intermittently reports the
    /// custom-hit-tested panel's rows as needing a scroll — the scroll then
    /// dies on the mouse-transparent empty list area. A coordinate hover
    /// synthesizes the same genuine cursor move without that detour.
    private func hover(row title: String) {
        row(titled: title)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .hover()
    }

    private func parentID(forTitle title: String) -> String {
        row(titled: title).identifier
            .replacingOccurrences(of: "task-row-", with: "")
    }

    private func progressControl(_ parentID: String) -> XCUIElement {
        app.buttons["subtask-progress-\(parentID)"]
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            description
        )
    }

    /// Asserts `condition` stays false for `duration` — the honest way to
    /// assert that an event does *not* happen inside a timing window.
    private func expectAbsent(
        _ description: String,
        for duration: TimeInterval,
        _ condition: @escaping () -> Bool
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        expectation.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: duration),
            .completed,
            description
        )
    }

    /// The waits here are part of the assertion itself (dwell/grace timing),
    /// not synchronization.
    private func hold(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func addTask(named title: String) {
        let titleField = app.textFields["quick-entry-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.click()
        titleField.typeText(title)
        // App-level Return: the focused TextField's AX element is swapped for
        // its field editor, so element-scoped typeKey can hit a stale handle.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            row(titled: title).waitForExistence(timeout: 3),
            "quick-entry submit must create the task row"
        )
    }

    /// Creates a parent with `children` through the real menu → entry path,
    /// then dismisses the latched surface with an outside click. The entry
    /// stays armed (only Escape cancels it). Returns the parent's UUID string.
    @discardableResult
    private func makeFamily(
        parent title: String,
        children: [String]
    ) -> String {
        addTask(named: title)
        let id = parentID(forTitle: title)
        let actions = app.descendants(matching: .any)["task-actions-\(id)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        waitFor("row actions control hittable") { actions.isHittable }
        actions.click()
        XCTAssertTrue(
            app.menuItems["Add subtask…"].waitForExistence(timeout: 2)
        )
        app.menuItems["Add subtask…"].click()
        let field = app.textFields["subtask-title-\(id)"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        // The menu open focuses the entry (the surface takes key status);
        // a click is kept as a belt-and-suspenders hittest/focus step before
        // the chained Return submissions below.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        for child in children {
            field.typeText(child)
            // App-level Return targets the live field editor: the focused
            // TextField's AX element is replaced whenever its editor
            // attaches/detaches, so element-scoped typeKey can race it.
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(
                app.staticTexts[child].waitForExistence(timeout: 2),
                "expected child row: \(child)"
            )
        }
        app.textFields["quick-entry-title"].click()
        waitFor("latched surface dismissed by outside click") {
            !self.transient(id).exists
        }
        return id
    }

    /// Deterministic latched open through the row's context menu — the
    /// documented non-hover path. The count control itself is a toggle and
    /// can race the hover dwell, so tests that need a stable open use this.
    private func openLatched(_ parentID: String) {
        let actions = app.descendants(matching: .any)["task-actions-\(parentID)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        waitFor("row actions control hittable") { actions.isHittable }
        actions.click()
        XCTAssertTrue(
            app.menuItems["Show subtasks"].waitForExistence(timeout: 2)
        )
        app.menuItems["Show subtasks"].click()
        XCTAssertTrue(transient(parentID).waitForExistence(timeout: 2))
    }

    /// A neutral point inside the main panel: hittable, interactive, and
    /// carrying no hover-driven side effects. `panel-section-picker` is not
    /// usable — its identifier resolves onto the task list's scroll view,
    /// whose empty regions are mouse-transparent by design.
    private func hoverNeutralPanelPoint() {
        app.textFields["quick-entry-title"].hover()
    }

    /// Sends window-level Escape while a surface is key. If the entry field
    /// still holds first responder, the first Escape only collapses it to the
    /// affordance — retry until the surface itself is dismissed.
    private func dismissWithEscape(_ surface: XCUIElement, _ description: String) {
        for _ in 0..<3 where surface.exists {
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        waitFor(description) { !surface.exists }
    }

    // MARK: - Dwell and corridor

    func testHoverDwellOpensTransientAndBriefHoverDoesNot() throws {
        let a = makeFamily(parent: "Hover target", children: ["Kid A"])
        _ = makeFamily(parent: "Brief pass", children: ["Kid B"])

        // A passing hover must not survive the dwell: sweep onto the row and
        // straight off to a neutral area before openDwell (0.35s) elapses,
        // then prove no surface appeared during a window longer than dwell.
        hover(row: "Brief pass")
        hoverNeutralPanelPoint()
        expectAbsent(
            "a brief pass must never open a surface",
            for: 0.8
        ) { self.anyTransient().exists }

        // A held hover matures into the real transient checklist.
        hover(row: "Hover target")
        let panel = transient(a)
        XCTAssertTrue(
            panel.waitForExistence(timeout: 2),
            "a 0.35s dwell must open the transient checklist"
        )
        XCTAssertTrue(
            app.buttons["subtask-pin-\(a)"].waitForExistence(timeout: 2),
            "the surface must expose its pin control"
        )
        XCTAssertTrue(
            app.staticTexts["Kid A"].exists,
            "the surface must list the family's children"
        )
    }

    func testPointerCorridorAndInsideHoverKeepTransientOpen() throws {
        let a = makeFamily(parent: "Corridor family", children: ["Kid A"])
        let surfaceElement = transient(a)
        let rowElement = row(titled: "Corridor family")

        hover(row: "Corridor family")
        XCTAssertTrue(surfaceElement.waitForExistence(timeout: 2))

        // Walk the pointer through the row→panel gap in real moves. The gap
        // is inside coverage for the main panel, and crossing it is quicker
        // than closeGrace (0.45s), so the surface must stay alive.
        let rowFrame = rowElement.frame
        let surfaceFrame = surfaceElement.frame
        XCTAssertFalse(surfaceFrame.isEmpty)
        let gapY = (max(rowFrame.minY, surfaceFrame.minY)
            + min(rowFrame.maxY, surfaceFrame.maxY)) / 2
        let gapX = surfaceFrame.minX >= rowFrame.maxX
            ? (rowFrame.maxX + surfaceFrame.minX) / 2
            : (surfaceFrame.maxX + rowFrame.minX) / 2
        let rowCenter = CGPoint(
            x: rowFrame.midX, y: rowFrame.midY
        )
        rowElement
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(
                dx: gapX - rowCenter.x,
                dy: gapY - rowCenter.y
            ))
            .hover()
        hold(0.15) // inside the corridor, well under closeGrace
        XCTAssertTrue(
            surfaceElement.exists,
            "the row→panel corridor must not dismiss the surface"
        )
        surfaceElement
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .hover()
        expectAbsent(
            "hovering inside the surface must cancel the pending close",
            for: 0.7 // exceeds closeGrace: only a cancelled close survives
        ) { !surfaceElement.exists }

        // Leaving to a neutral area inside the main panel lets the grace
        // elapse — first the grace must actually be a grace (still present
        // shortly after leaving), then the surface must close.
        hoverNeutralPanelPoint()
        hold(0.15) // inside closeGrace
        XCTAssertTrue(
            surfaceElement.exists,
            "the close grace must not fire instantly on leave"
        )
        waitFor("leaving both surfaces closes the transient after grace") {
            !surfaceElement.exists
        }
    }

    func testRapidFamilySwitchShowsLatestOnly() throws {
        let a = makeFamily(parent: "First family", children: ["Kid A"])
        let b = makeFamily(parent: "Second family", children: ["Kid B"])

        // Sweep A → B faster than openDwell; only B may mature.
        hover(row: "First family")
        hover(row: "Second family")
        XCTAssertTrue(
            transient(b).waitForExistence(timeout: 2),
            "the latest hovered family must open"
        )
        XCTAssertFalse(
            transient(a).exists,
            "at most one transient surface may exist"
        )
    }

    // MARK: - Pinned window lifecycle

    func testPinnedWindowSurvivesAppDeactivation() throws {
        let a = makeFamily(parent: "Pinned family", children: ["Kid A"])

        // Latched open → pin promotes the checklist into the mini-window.
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        let pinnedElement = pinned(a)
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))
        XCTAssertFalse(
            transient(a).exists,
            "pinning must promote the transient surface, not duplicate it"
        )

        // Focus loss is the pinned window's reason to exist: another app
        // takes the foreground and the mini-window must stay onscreen. (The
        // main panel itself is force-visible under ATTIC_UI_TESTING, so its
        // hide behavior is not assertable here.)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        waitFor("Finder must actually take the foreground", timeout: 5) {
            finder.state == .runningForeground
        }
        XCTAssertTrue(
            pinnedElement.exists,
            "the pinned window must survive main-panel hide and focus loss"
        )

        app.activate()
        XCTAssertTrue(pinnedElement.exists)
    }

    func testPinnedWindowDragsAndRemembersPosition() throws {
        let a = makeFamily(parent: "Drag family", children: ["Kid A"])
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        let pinnedElement = pinned(a)
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))

        // The header's drag handle is a real AX element marking the drag
        // region; press its left stretch and the hosting view's header
        // mousedown runs performDrag on the pinned window.
        let initial = pinnedElement.frame
        let dragHandle = app.groups["subtask-drag-\(a)"]
        XCTAssertTrue(
            dragHandle.waitForExistence(timeout: 2),
            "the pinned header must expose a drag-handle element"
        )
        let handleFrame = dragHandle.frame
        XCTAssertTrue(
            handleFrame.intersects(initial),
            "the drag handle must live inside the pinned surface header"
        )
        // Press on the handle's left stretch (desktop overlays can claim the
        // far right of this screen region), drag left-and-down — keeping the
        // dragged window clear of the right screen edge.
        let pressPoint = dragHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)
        )
        let expectedDX: CGFloat = -120
        let expectedDY: CGFloat = 80
        pressPoint.click(
            forDuration: 0.2,
            thenDragTo: pressPoint.withOffset(
                CGVector(dx: expectedDX, dy: expectedDY)
            )
        )
        let dragged = pinnedElement.frame
        XCTAssertEqual(
            dragged.minX, initial.minX + expectedDX, accuracy: 10,
            "the pinned window must follow a header drag"
        )
        XCTAssertEqual(
            dragged.minY, initial.minY + expectedDY, accuracy: 10,
            "the pinned window must follow a header drag"
        )

        // Dismiss the surface entirely; the next pin must restore the user's
        // dragged position rather than re-anchoring beside the row.
        app.buttons["subtask-close-\(a)"].click()
        waitFor("pinned surface closed") { !self.pinned(a).exists }
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))
        XCTAssertEqual(
            pinnedElement.frame.minX, dragged.minX, accuracy: 6,
            "re-pinning must restore the remembered position"
        )
        XCTAssertEqual(
            pinnedElement.frame.minY, dragged.minY, accuracy: 6,
            "re-pinning must restore the remembered position"
        )
    }

    func testPinnedFamilyCountControlAnnouncesReveal() throws {
        let a = makeFamily(parent: "VoiceOver family", children: ["Kid A"])
        openLatched(a)
        waitFor("open transient announces the hide action") {
            self.progressControl(a).label == "Hide subtasks"
        }

        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))
        waitFor("pinned family must announce the reveal action") {
            self.progressControl(a).label == "Reveal pinned subtasks"
        }

        app.buttons["subtask-unpin-\(a)"].click()
        XCTAssertTrue(transient(a).waitForExistence(timeout: 2))
        waitFor("unpinned family returns to the toggle wording") {
            self.progressControl(a).label == "Hide subtasks"
        }
    }

    func testPinnedReplacementDisabledWhilePinnedFamilyIsBusy() throws {
        let a = makeFamily(parent: "Busy pinned", children: ["Kid A"])
        let b = makeFamily(parent: "Waiting family", children: ["Kid B"])

        // Pin A, then put a member of its family into an in-flight rename —
        // a draft alone is not busy; an edit or delete-confirmation is.
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))

        let actions = app.descendants(matching: .any)["task-actions-\(a)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        waitFor("row actions control hittable") { actions.isHittable }
        actions.click()
        let editItem = app.menuItems["Edit title…"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 2))
        editItem.click()
        XCTAssertTrue(
            app.textFields["edit-task-title-\(a)"]
                .waitForExistence(timeout: 2),
            "a rename must be in flight for the family to count as busy"
        )

        // B's surface offers replacement, but never silently: the affordance
        // is visibly disabled while A has an edit in flight.
        openLatched(b)
        let replaceButton = app.buttons["subtask-pin-\(b)"]
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 2))
        XCTAssertFalse(
            replaceButton.isEnabled,
            "replacement must be disabled while the pinned list is busy"
        )
    }

    // MARK: - Escape and bounded scrolling

    func testEscapeDismissesSurfacesOutsideFieldEditing() throws {
        let a = makeFamily(parent: "Escape family", children: ["Kid A"])

        openLatched(a)
        let transientElement = transient(a)
        // Make the surface key without activating a field editor.
        transientElement
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        dismissWithEscape(
            transientElement,
            "Escape must dismiss the transient surface"
        )

        // The pinned window honors the same contract.
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        let pinnedElement = pinned(a)
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))
        pinnedElement
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        dismissWithEscape(
            pinnedElement,
            "Escape must dismiss the pinned surface"
        )
    }

    func testLargeFamilyKeepsSurfaceHeightBounded() throws {
        let children = (1...12).map { "Step \($0)" }
        let a = makeFamily(parent: "Big family", children: children)

        openLatched(a)
        let element = transient(a)
        // Spec bound: the list caps at 264pt (SubtaskPanelLayout) plus header
        // and footer chrome; twelve 32pt rows would exceed 450pt unbounded.
        XCTAssertLessThan(
            element.frame.height, 400,
            "the checklist must scroll inside its height bound, not grow"
        )
        XCTAssertTrue(
            element.scrollViews.firstMatch.exists,
            "a bounded list must keep a real scroll view"
        )
    }
}
