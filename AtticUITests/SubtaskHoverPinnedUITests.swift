import XCTest

/// Real-pointer UAT for the task subpanels. `XCUIElement.hover()` and
/// `XCUICoordinate.hover()` move the actual cursor through testmanagerd, so
/// these tests exercise the rule that hover only reveals the row and never
/// navigates, deliberate opening, outside-click dismissal, focus-loss
/// survival, and window-level Escape — paths unit tests can only simulate at
/// the state-machine layer. All assertions go through accessibility-visible
/// elements of the launched test app only. The waits below are the behavior
/// under test, not synchronization sleeps.
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

    /// The row menu is inert and hidden from accessibility until the row is
    /// hovered or keyboard-focused, so tests hover the row first.
    private func revealActions(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["task-row-\(id)"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .hover()
        let actions = app.descendants(matching: .any)["task-actions-\(id)"]
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        waitFor("row actions control hittable") { actions.isHittable }
        return actions
    }

    private func pinnedStatus(_ parentID: String) -> XCUIElement {
        app.buttons["task-pinned-status-\(parentID)"]
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

    /// Polls tightly and returns how long `condition` took to become true.
    /// `XCTNSPredicateExpectation` re-evaluates on a ~1s timer, so it can only
    /// ever report latencies quantised to whole seconds — useless for
    /// asserting that a dismissal was near-immediate.
    @discardableResult
    private func measureUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> TimeInterval {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail(description)
        return .infinity
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
        revealActions(id).click()
        XCTAssertTrue(
            app.menuItems["Add subtask…"].waitForExistence(timeout: 2)
        )
        app.menuItems["Add subtask…"].click()
        let field = app.textFields["subtask-title-\(id)"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        for child in children {
            focusEntryField(field)
            field.typeText(child)
            // Reacquire the live field editor for every row, then keep the
            // documented Enter-to-save path under test at every list size.
            app.typeKey(.return, modifierFlags: [])
            // The bounded checklist scrolls a lazy row stack, so a row added
            // below the fold stays out of the accessibility tree until the
            // list scrolls to it. Reveal the created row instead of treating
            // absence from the tree as a failed submit.
            let row = app.staticTexts[child]
            if !row.waitForExistence(timeout: 2) {
                let list = transient(id).scrollViews.firstMatch
                for attempt in 0..<10 where !row.exists {
                    list.scroll(byDeltaX: 0, deltaY: attempt.isMultiple(of: 2) ? 140 : -140)
                }
            }
            XCTAssertTrue(
                row.waitForExistence(timeout: 2),
                "expected child row: \(child)"
            )
        }
        app.textFields["quick-entry-title"].click()
        waitFor("latched surface dismissed by outside click") {
            !self.transient(id).exists
        }
        return id
    }

    /// Clicks the entry field until it demonstrably holds the field editor.
    /// `XCUIElement.typeText` refuses to dispatch without keyboard focus, and
    /// the menu-open → surface-key → field-editor handoff occasionally lands
    /// after the click; probing with an app-level keystroke (which needs no
    /// element focus) makes the setup deterministic instead of racy.
    private func focusEntryField(_ field: XCUIElement) {
        for _ in 0..<5 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click()
            app.typeKey("x", modifierFlags: [])
            if ((field.value as? String) ?? "").contains("x") {
                app.typeKey(.delete, modifierFlags: [])
                waitFor("the focus probe character must be cleared") {
                    !(((field.value as? String) ?? "").contains("x"))
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("the subtask entry field never took keyboard focus")
    }

    /// Deterministic latched open through the row's actions menu — the
    /// documented non-hover path that avoids racing the hover dwell.
    private func openLatched(_ parentID: String) {
        revealActions(parentID).click()
        XCTAssertTrue(
            app.menuItems["Show subtasks"].waitForExistence(timeout: 2)
        )
        app.menuItems["Show subtasks"].click()
        XCTAssertTrue(transient(parentID).waitForExistence(timeout: 2))
    }

    private func hover(point: CGPoint, relativeTo element: XCUIElement) {
        let frame = element.frame
        element
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
            .hover()
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

    // MARK: - Hover reveals, click opens

    /// TP-003: a neutral hover — however long it rests — only reveals the
    /// row's affordances. Opening the workspace takes a click on the row.
    func testNeutralHoverNeverOpensAndAClickDoes() throws {
        let a = makeFamily(parent: "Hover target", children: ["Kid A"])

        hover(row: "Hover target")
        XCTAssertTrue(
            app.descendants(matching: .any)["task-actions-\(a)"].waitForExistence(timeout: 2),
            "hover reveals the row's actions"
        )
        expectAbsent(
            "a resting hover must never open a surface",
            for: 1.2
        ) { self.anyTransient().exists }

        row(titled: "Hover target")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        let panel = transient(a)
        XCTAssertTrue(panel.waitForExistence(timeout: 2), "a row click opens the checklist")
        XCTAssertTrue(
            app.buttons["subtask-pin-\(a)"].waitForExistence(timeout: 2),
            "the surface must expose its pin control"
        )
        XCTAssertTrue(app.staticTexts["Kid A"].exists, "the surface must list the family's children")
        XCTAssertEqual(app.textFields["subtask-title-\(a)"].exists || app.buttons["add-subtask-\(a)"].exists, true,
                       "a fresh open starts on Subtasks")
    }

    /// A deliberately opened panel is not bound to the pointer: leaving it,
    /// resting beside it and hovering other rows keep it. An outside click
    /// closes it, and the next row click opens the latest family only.
    func testOpenPanelIgnoresPointerLeaveAndClosesOnOutsideClick() throws {
        let a = makeFamily(parent: "Stay family", children: ["Kid A"])
        let b = makeFamily(parent: "Other family", children: ["Kid B"])
        let surfaceElement = transient(a)

        openLatched(a)
        XCTAssertTrue(surfaceElement.waitForExistence(timeout: 2))
        surfaceElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        hover(row: "Other family")
        hoverNeutralPanelPoint()
        expectAbsent(
            "pointer position must never close a deliberately opened panel",
            for: 1.0
        ) { !surfaceElement.exists }

        app.textFields["quick-entry-title"].click()
        waitFor("an outside click dismisses the panel") { !surfaceElement.exists }

        row(titled: "Other family")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        XCTAssertTrue(transient(b).waitForExistence(timeout: 2), "the clicked family opens")
        XCTAssertFalse(transient(a).exists, "at most one transient surface may exist")
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

    func testPinnedWindowDragsAndRepinsAtCurrentPopoverPosition() throws {
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

        // A fresh pin retains the current popover position, regardless of
        // where a previously dismissed window was dragged.
        app.buttons["subtask-close-\(a)"].click()
        waitFor("pinned surface closed") { !self.pinned(a).exists }
        openLatched(a)
        let reopened = transient(a).frame
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))
        XCTAssertEqual(
            pinnedElement.frame.minX, reopened.minX, accuracy: 6,
            "re-pinning must retain the current popover position"
        )
        XCTAssertEqual(
            pinnedElement.frame.minY, reopened.minY, accuracy: 6,
            "re-pinning must retain the current popover position"
        )
    }

    func testPinnedFamilyShowsQuietStatusThatRevealsPanel() throws {
        let a = makeFamily(parent: "VoiceOver family", children: ["Kid A"])
        openLatched(a)
        XCTAssertFalse(pinnedStatus(a).exists, "an unpinned family shows no pinned status")

        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))
        XCTAssertTrue(pinnedStatus(a).waitForExistence(timeout: 2))
        XCTAssertEqual(pinnedStatus(a).label, "Panel pinned")
        XCTAssertFalse(app.buttons["subtask-progress-\(a)"].exists, "progress stays passive metadata")

        // Activating the status reveals the same pinned window, no duplicate.
        pinnedStatus(a).click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))
        XCTAssertFalse(transient(a).exists)

        app.buttons["subtask-unpin-\(a)"].click()
        XCTAssertTrue(transient(a).waitForExistence(timeout: 2))
        waitFor("unpinned family drops the pinned status") { !self.pinnedStatus(a).exists }
    }

    func testMultiplePinnedFamiliesStayIndependentWhileEditing() throws {
        let a = makeFamily(parent: "Busy pinned", children: ["Kid A"])
        let b = makeFamily(parent: "Waiting family", children: ["Kid B"])

        // Pin A, then put a member of its family into an in-flight rename —
        // a draft alone is not busy; an edit or delete-confirmation is.
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))

        revealActions(a).click()
        let editItem = app.menuItems["Edit title…"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 2))
        editItem.click()
        XCTAssertTrue(
            app.textFields["edit-task-title-\(a)"]
                .waitForExistence(timeout: 2),
            "a rename must be in flight for the family to count as busy"
        )

        openLatched(b)
        let pinButton = app.buttons["subtask-pin-\(b)"]
        XCTAssertTrue(pinButton.waitForExistence(timeout: 2))
        XCTAssertTrue(pinButton.isEnabled)
        pinButton.click()
        XCTAssertTrue(pinned(a).exists)
        XCTAssertTrue(pinned(b).waitForExistence(timeout: 2))
        app.buttons["subtask-close-\(b)"].click()
        XCTAssertTrue(pinned(a).exists)
        XCTAssertFalse(pinned(b).exists)
        XCTAssertTrue(app.textFields["edit-task-title-\(a)"].exists)

    }

    // MARK: - Surface hit geometry

    /// The reported defect: the surface's glass, header and padding are drawn
    /// by a non-hit-testable background, so presses there could fall through
    /// to whatever window was underneath while the child rows still worked.
    ///
    /// This asserts absorption the only way that cannot be confounded by
    /// key-window or Escape semantics: it parks the pinned window ON TOP of
    /// the main panel's quick-entry field, clicks an inert padding point of
    /// the pinned window, and requires the covered field NOT to take focus.
    /// A positive control first proves the field does take focus from a
    /// direct click, so a false pass is not possible.
    ///
    /// Inert HEADER space is covered separately and already passes:
    /// `testPinnedWindowDragsAndRepinsAtCurrentPopoverPosition` can only move the window
    /// if a header press hit-tests to the hosting view.
    func testPinnedSurfaceAbsorbsInertPaddingInsteadOfPassingThrough() throws {
        let a = makeFamily(parent: "Absorb family", children: ["Kid A"])
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        let pinnedElement = pinned(a)
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))

        // Focus is probed by where typed characters land — `hasFocus` is not
        // available on this platform's XCUIElement.
        let field = app.textFields["quick-entry-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        func fieldText() -> String { (field.value as? String) ?? "" }

        // Positive control: a direct click really does focus this field, so a
        // later "nothing was typed" assertion cannot pass vacuously.
        field.click()
        app.typeKey("q", modifierFlags: [])
        waitFor("quick entry must take a direct click's keystroke") {
            fieldText().contains("q")
        }
        app.typeKey(.delete, modifierFlags: [])
        waitFor("the control character must be cleared again") {
            !fieldText().contains("q")
        }
        let target = field.frame

        // Hand focus to the pinned window so the assertion below is about the
        // covered click alone.
        pinnedElement
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()

        // Move several painted but inert regions over the same verified
        // underlying input. The assertion depends on actual event delivery.
        let size = pinnedElement.frame.size
        let points = [
            CGPoint(x: size.width / 2, y: size.height - 3),
            CGPoint(x: size.width / 2, y: 5),
            CGPoint(x: 3, y: size.height / 2),
            CGPoint(x: size.width - 3, y: size.height / 2)
        ]
        for inert in points {
            let before = pinnedElement.frame
            let handle = app.groups["subtask-drag-\(a)"]
            XCTAssertTrue(handle.waitForExistence(timeout: 2))
            let press = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            press.click(forDuration: 0.2, thenDragTo: press.withOffset(CGVector(
                dx: target.midX - (before.minX + inert.x),
                dy: target.midY - (before.minY + inert.y)
            )))
            let moved = pinnedElement.frame
            let covered = CGPoint(x: moved.minX + inert.x, y: moved.minY + inert.y)
            XCTAssertTrue(target.insetBy(dx: -2, dy: -2).contains(covered),
                          "the tested point must actually cover the underlying field")
            pinnedElement.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: inert.x, dy: inert.y)).click()
            app.typeKey("z", modifierFlags: [])
            expectAbsent("painted point \(inert) must not click through", for: 0.4) {
                fieldText().contains("z")
            }
            XCTAssertTrue(pinnedElement.exists)
        }

    }

    /// The transparent corner wedges are NOT the surface: a press there
    /// belongs to whatever is behind. A latched transient dismisses on any
    /// genuine outside mousedown, so the corner must dismiss it while its own
    /// padding must not.
    func testTransientCornerIsOutsideAndPaddingIsInside() throws {
        let a = makeFamily(parent: "Corner family", children: ["Kid A"])
        openLatched(a)
        let surfaceElement = transient(a)
        let frame = surfaceElement.frame
        let origin = surfaceElement.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )

        // Left padding strip, vertically centred: inert but inside the shape.
        origin.withOffset(CGVector(dx: 3, dy: frame.height / 2)).click()
        expectAbsent(
            "a press on the surface's own padding must not dismiss it",
            for: 0.8
        ) { !surfaceElement.exists }

        // One point inside the bounding box's top-left corner but outside the
        // drawn squircle at the default corner size.
        origin.withOffset(CGVector(dx: 1, dy: 1)).click()
        waitFor("the transparent corner must not belong to the surface") {
            !surfaceElement.exists
        }
    }

    /// First click after the app loses focus must reach the control itself
    /// (acceptsFirstMouse) rather than being spent making the panel key.
    func testFirstClickReachesPinnedControlAfterDeactivation() throws {
        let a = makeFamily(parent: "First click", children: ["Kid A"])
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        waitFor("Finder must actually take the foreground", timeout: 5) {
            finder.state == .runningForeground
        }
        app.buttons["subtask-close-\(a)"].click()
        waitFor("a single first click must close the pinned window") {
            !self.pinned(a).exists
        }
    }

    /// Header controls own their presses: a press-drag starting on the unpin
    /// control must unpin, never move the window.
    func testPinnedHeaderControlPressDoesNotDragTheWindow() throws {
        let a = makeFamily(parent: "Ownership family", children: ["Kid A"])
        openLatched(a)
        app.buttons["subtask-pin-\(a)"].click()
        let pinnedElement = pinned(a)
        XCTAssertTrue(pinnedElement.waitForExistence(timeout: 2))
        let initial = pinnedElement.frame

        let unpin = app.buttons["subtask-unpin-\(a)"]
        let press = unpin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        press.click(
            forDuration: 0.2,
            thenDragTo: press.withOffset(CGVector(dx: -90, dy: 60))
        )
        XCTAssertTrue(pinnedElement.exists, "dragging out of a button cancels its action")
        XCTAssertEqual(pinnedElement.frame.minX, initial.minX, accuracy: 3)
        XCTAssertEqual(pinnedElement.frame.minY, initial.minY, accuracy: 3)
        // A normal single click still activates the same button.
        unpin.click()
        XCTAssertTrue(transient(a).waitForExistence(timeout: 2))
        XCTAssertEqual(transient(a).frame.minX, initial.minX, accuracy: 3)
        XCTAssertEqual(transient(a).frame.minY, initial.minY, accuracy: 3)

    }

    func testUnpinnedHeaderDragAndSingleClickEntry() throws {
        try assertUnpinnedDragAndEntry()
    }

    func testFrostedHeaderDragAndSingleClickEntry() throws {
        app.terminate()
        app.launchArguments += ["-panelGlassStyle", "frosted", "-panelCornerSize", "70"]
        app.launch()
        app.activate()
        XCTAssertTrue(element(identifiedBy: "panel-section-picker").waitForExistence(timeout: 5))
        try assertUnpinnedDragAndEntry()
    }

    private func assertUnpinnedDragAndEntry() throws {
        addTask(named: "Detached entry")
        let a = parentID(forTitle: "Detached entry")
        revealActions(a).click()
        app.menuItems["Add subtask…"].click()
        let surface = transient(a)
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        let before = surface.frame
        // Blank top strip, away from the title and header controls.
        let press = surface.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.width / 2, dy: 5))
        press.click(forDuration: 0.2, thenDragTo: press.withOffset(CGVector(dx: -100, dy: 60)))
        XCTAssertEqual(surface.frame.minX, before.minX - 100, accuracy: 8)
        XCTAssertEqual(surface.frame.minY, before.minY + 60, accuracy: 8)
        hoverNeutralPanelPoint()
        hold(0.5)
        XCTAssertTrue(surface.exists, "dragged unpinned surface must stay open")
        let entry = app.textFields["subtask-title-\(a)"]
        XCTAssertTrue(entry.waitForExistence(timeout: 2))
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText("First child")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row(titled: "First child").waitForExistence(timeout: 2))
        let moved = surface.frame
        app.buttons["subtask-pin-\(a)"].click()
        XCTAssertTrue(pinned(a).waitForExistence(timeout: 2))
        XCTAssertEqual(pinned(a).frame.minX, moved.minX, accuracy: 3)
        XCTAssertEqual(pinned(a).frame.minY, moved.minY, accuracy: 3)
        app.buttons["subtask-unpin-\(a)"].click()
        XCTAssertTrue(surface.waitForExistence(timeout: 2))
        XCTAssertEqual(surface.frame.minX, moved.minX, accuracy: 3)
        let secondEntry = app.textFields["subtask-title-\(a)"]
        secondEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeText("Second child")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row(titled: "Second child").waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        let add = app.buttons["add-subtask-\(a)"]
        XCTAssertTrue(add.waitForExistence(timeout: 2))
        add.click()
        XCTAssertTrue(app.textFields["subtask-title-\(a)"].waitForExistence(timeout: 2))
        app.typeText("Third child")
        app.buttons["subtask-composer-action-\(a)"].click()
        XCTAssertTrue(row(titled: "Third child").waitForExistence(timeout: 2))
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
        // Spec bound: the list caps at 240pt (SubtaskPanelLayout) plus header
        // and footer chrome; twelve 32pt rows would exceed 450pt unbounded.
        XCTAssertLessThan(
            element.frame.height, 380,
            "the checklist must scroll inside its height bound, not grow"
        )
        XCTAssertTrue(
            element.scrollViews.firstMatch.exists,
            "a bounded list must keep a real scroll view"
        )
    }
}
