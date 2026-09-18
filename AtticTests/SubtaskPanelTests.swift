import XCTest
@testable import Attic

@MainActor
final class SubtaskPanelTests: XCTestCase {
    func testTransientPlacementAvoidsPinnedFamilyWithoutMovingIt() {
        let main = CGRect(x: 1000, y: 400, width: 320, height: 460)
        let pinned = CGRect(x: 716, y: 500, width: 272, height: 220)
        let placed = SubtaskPanelLayout.transientFrame(size: pinned.size,
            anchorScreenRect: CGRect(x: 1000, y: 680, width: 300, height: 40),
            panelScreenFrame: main, screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            occupiedFrames: [pinned])
        XCTAssertFalse(placed.intersects(pinned))
        XCTAssertFalse(placed.intersects(main))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1440, height: 900).contains(placed))
    }
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    // MARK: - Transient placement

    func testTransientFrameSitsLeftOfPanelDockedOnRight() {
        let panel = CGRect(x: 1500, y: 400, width: 420, height: 600)
        let anchor = CGRect(x: 1512, y: 600, width: 396, height: 42)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 300)
        let frame = SubtaskPanelLayout.transientFrame(
            size: size,
            anchorScreenRect: anchor,
            panelScreenFrame: panel,
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.maxX, panel.minX - SubtaskPanelLayout.sideGap, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, anchor.maxY, accuracy: 0.5)
        XCTAssertEqual(frame.size, size)
    }

    func testTransientFrameSitsRightOfPanelDockedOnLeft() {
        let panel = CGRect(x: 12, y: 400, width: 420, height: 600)
        let anchor = CGRect(x: 24, y: 700, width: 396, height: 42)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 200)
        let frame = SubtaskPanelLayout.transientFrame(
            size: size,
            anchorScreenRect: anchor,
            panelScreenFrame: panel,
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.minX, panel.maxX + SubtaskPanelLayout.sideGap, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, anchor.maxY, accuracy: 0.5)
    }

    func testTransientFrameStaysOnScreenWhenNoSideHasRoom() {
        // A display too narrow for panel + surface on either side still
        // yields a frame inside the safe area rather than overflowing.
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 1200)
        let panel = CGRect(x: 280, y: 400, width: 200, height: 600)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 300)
        let frame = SubtaskPanelLayout.transientFrame(
            size: size,
            anchorScreenRect: nil,
            panelScreenFrame: panel,
            screenVisibleFrame: narrow
        )
        let safe = narrow.insetBy(
            dx: SubtaskPanelLayout.screenInset,
            dy: SubtaskPanelLayout.screenInset
        )
        XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 0.5)
        XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 0.5)
    }

    func testTransientFrameClampsIntoSafeAreaWhenAnchorNearBottom() {
        let panel = CGRect(x: 1500, y: 300, width: 420, height: 800)
        let anchor = CGRect(x: 1512, y: 400, width: 396, height: 42)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 340)
        let frame = SubtaskPanelLayout.transientFrame(
            size: size,
            anchorScreenRect: anchor,
            panelScreenFrame: panel,
            screenVisibleFrame: screen
        )
        let safe = screen.insetBy(
            dx: SubtaskPanelLayout.screenInset,
            dy: SubtaskPanelLayout.screenInset
        )
        XCTAssertTrue(safe.contains(frame.origin))
        XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 0.5)
        XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 0.5)
    }

    func testTransientFrameWithoutAnchorAlignsNearPanelTop() {
        let panel = CGRect(x: 12, y: 300, width: 420, height: 600)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 240)
        let frame = SubtaskPanelLayout.transientFrame(
            size: size,
            anchorScreenRect: nil,
            panelScreenFrame: panel,
            screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.minX, panel.maxX + SubtaskPanelLayout.sideGap, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, panel.maxY - 60, accuracy: 0.5)
    }

    // MARK: - Sizing

    func testClampedListHeightBounds() {
        XCTAssertEqual(
            SubtaskPanelLayout.clampedListHeight(0),
            SubtaskPanelLayout.minimumListHeight
        )
        XCTAssertEqual(
            SubtaskPanelLayout.clampedListHeight(20),
            SubtaskPanelLayout.minimumListHeight
        )
        XCTAssertEqual(SubtaskPanelLayout.clampedListHeight(150), 150, accuracy: 0.001)
        XCTAssertEqual(
            SubtaskPanelLayout.clampedListHeight(10000),
            SubtaskPanelLayout.maximumListHeight
        )
    }

    func testFramePreservingTopKeepsTopEdgeStationary() throws {
        let frame = CGRect(x: 100, y: 500, width: 292, height: 200)
        let adjusted = try XCTUnwrap(SubtaskPanelLayout.framePreservingTop(frame, height: 260))
        XCTAssertEqual(adjusted.maxY, frame.maxY, accuracy: 0.001)
        XCTAssertEqual(adjusted.height, 260, accuracy: 0.001)
        XCTAssertNil(SubtaskPanelLayout.framePreservingTop(frame, height: 200.2))
        XCTAssertNil(SubtaskPanelLayout.framePreservingTop(frame, height: 0))
    }

    // MARK: - Pinned restore

    func testRestoredPinnedFrameHonorsSavedPositionOnScreen() {
        let saved = CGRect(x: 400, y: 300, width: 292, height: 220)
        let size = CGSize(width: 292, height: 260)
        let frame = SubtaskPanelLayout.restoredPinnedFrame(
            saved: saved,
            size: size,
            screenVisibleFrames: [screen]
        )
        XCTAssertEqual(frame.origin, saved.origin)
        XCTAssertEqual(frame.size, size)
    }

    func testRestoredPinnedFrameDropsPositionOffEveryScreen() {
        let saved = CGRect(x: 9000, y: 9000, width: 292, height: 220)
        let fallback = CGRect(x: 100, y: 500, width: 292, height: 240)
        let size = CGSize(width: 292, height: 240)
        let frame = SubtaskPanelLayout.restoredPinnedFrame(
            saved: saved,
            size: size,
            screenVisibleFrames: [screen],
            fallback: fallback
        )
        XCTAssertEqual(frame.origin, fallback.origin)
    }

    func testRestoredPinnedFrameCentersWithoutMemoryOrAnchor() {
        let size = CGSize(width: 292, height: 240)
        let frame = SubtaskPanelLayout.restoredPinnedFrame(
            saved: nil,
            size: size,
            screenVisibleFrames: [screen]
        )
        let safe = screen.insetBy(
            dx: SubtaskPanelLayout.screenInset,
            dy: SubtaskPanelLayout.screenInset
        )
        XCTAssertEqual(frame.midX, safe.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, safe.midY, accuracy: 1)
    }

    // MARK: - Lifecycle

    /// Every transient is a deliberate open: it is never pending, never
    /// pointer-governed, and stays until an explicit close.
    func testOpenIsDeliberateAndStaysUntilClosed() {
        var lifecycle = SubtaskPanelLifecycle()
        let a = UUID(), b = UUID()
        XCTAssertNil(lifecycle.transientFamilyID)
        XCTAssertTrue(lifecycle.openTransient(a))
        XCTAssertEqual(lifecycle.transientFamilyID, a)
        XCTAssertFalse(lifecycle.openTransient(a), "re-opening the same family changes nothing")
        XCTAssertTrue(lifecycle.openTransient(b), "explicit actions switch tasks")
        XCTAssertEqual(lifecycle.transientFamilyID, b)
        lifecycle.closeTransient()
        XCTAssertNil(lifecycle.transientFamilyID)
    }

    func testPinPromotesTransientAndBlocksASecondSurface() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.openTransient(family)
        lifecycle.pin(family)
        XCTAssertEqual(lifecycle.pinnedFamilyIDs, [family])
        XCTAssertNil(lifecycle.transientFamilyID)
        XCTAssertFalse(lifecycle.mayOpenTransient(for: family))
        XCTAssertFalse(lifecycle.openTransient(family), "a pinned family never gets a second surface")
        XCTAssertNil(lifecycle.transientFamilyID)
    }

    func testDraggingTransientDetachesAndPreservesFamily() {
        var lifecycle = SubtaskPanelLifecycle()
        let a = UUID()
        lifecycle.openTransient(a)
        lifecycle.detachTransient()
        XCTAssertTrue(lifecycle.isTransientDetached)
        XCTAssertEqual(lifecycle.transientFamilyID, a)
        lifecycle.closeTransient()
        XCTAssertFalse(lifecycle.isTransientDetached)
        lifecycle.detachTransient()
        XCTAssertFalse(lifecycle.isTransientDetached, "nothing to detach without a surface")
    }

    func testPinningSecondFamilyKeepsFirstPinnedWindow() {
        var lifecycle = SubtaskPanelLifecycle()
        let a = UUID()
        let b = UUID()
        lifecycle.pin(a)
        lifecycle.pin(b)
        XCTAssertEqual(lifecycle.pinnedFamilyIDs, [a, b])
        XCTAssertEqual(lifecycle.unpin(b), b)
        XCTAssertEqual(lifecycle.pinnedFamilyIDs, [a])
        XCTAssertFalse(lifecycle.mayOpenTransient(for: a))
        XCTAssertTrue(lifecycle.mayOpenTransient(for: b))
    }

    // MARK: - Idempotent scheduling and browsing timings

    // MARK: - Corridor transit vs arrival

    /// Surface, corridor and outside are three different answers, and the
    /// corridor is bounded by the row/surface band — not the full height of
    /// the main panel, which used to swallow unrelated clicks.
    func testPointerCoverageSeparatesSurfaceTransitAndOutside() {
        let main = CGRect(x: 1200, y: 100, width: 420, height: 900)
        let surface = CGRect(x: 900, y: 700, width: SubtaskPanelLayout.panelWidth, height: 220)
        let anchor = CGRect(x: 1212, y: 900, width: 396, height: 42)
        func coverage(_ point: CGPoint) -> SubtaskPanelLayout.PointerCoverage {
            SubtaskPanelLayout.pointerCoverage(
                point,
                surfaceFrame: surface,
                cornerSize: PanelCornerSize.standard.rawValue,
                mainPanelFrame: main,
                anchorRect: anchor
            )
        }
        XCTAssertEqual(coverage(CGPoint(x: surface.midX, y: surface.midY)), .surface)
        XCTAssertEqual(
            coverage(CGPoint(x: surface.maxX + 5, y: surface.midY)), .transit,
            "the row→surface gap is transit"
        )
        XCTAssertEqual(
            coverage(CGPoint(x: surface.maxX + 5, y: main.maxY - 20)), .outside,
            "far above the row/surface band the gap is not a corridor"
        )
        XCTAssertEqual(
            coverage(CGPoint(x: surface.maxX + 5, y: main.minY + 20)), .outside,
            "far below the band the gap is not a corridor"
        )
        XCTAssertEqual(
            coverage(CGPoint(x: surface.minX - 5, y: surface.midY)), .outside,
            "the far side of the surface is not a corridor"
        )
        XCTAssertEqual(
            coverage(CGPoint(x: surface.minX + 1, y: surface.maxY - 1)), .outside,
            "the transparent corner wedge is not the surface"
        )
    }

    func testPointerCoverageWithoutAMainPanelHasNoCorridor() {
        let surface = CGRect(x: 900, y: 700, width: SubtaskPanelLayout.panelWidth, height: 220)
        XCTAssertEqual(
            SubtaskPanelLayout.pointerCoverage(
                CGPoint(x: surface.maxX + 5, y: surface.midY),
                surfaceFrame: surface,
                cornerSize: PanelCornerSize.standard.rawValue,
                mainPanelFrame: nil,
                anchorRect: nil
            ),
            .outside
        )
    }

    // MARK: - Batch 4 (R6): corridor to the actual placement

    /// A pinned family beside the main panel pushes the transient elsewhere;
    /// the corridor must follow the surface to its actual frame, and crossing
    /// the pinned window on the way is transit, not a dismissal.
    func testCorridorFollowsAPlacementMovedClearOfAPinnedPanel() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let main = CGRect(x: 1100, y: 300, width: 320, height: 560)
        let anchor = CGRect(x: 1112, y: 700, width: 296, height: 40)
        let pinned = CGRect(x: 818, y: 560, width: 272, height: 220)
        let size = CGSize(width: SubtaskPanelLayout.panelWidth, height: 200)
        let surface = SubtaskPanelLayout.transientFrame(
            size: size, anchorScreenRect: anchor, panelScreenFrame: main,
            screenVisibleFrame: screenFrame, occupiedFrames: [pinned]
        )
        XCTAssertFalse(surface.intersects(pinned), "placement avoids the pinned panel where the screen permits")
        XCTAssertFalse(surface.intersects(main))
        func coverage(_ point: CGPoint, crossing: [CGRect] = [pinned]) -> SubtaskPanelLayout.PointerCoverage {
            SubtaskPanelLayout.pointerCoverage(point, surfaceFrame: surface, cornerSize: PanelCornerSize.standard.rawValue,
                                               mainPanelFrame: main, anchorRect: anchor, crossingFrames: crossing)
        }
        // Sample the straight route from the row to the surface's centre.
        let start = CGPoint(x: anchor.minX + 8, y: anchor.midY)
        let end = CGPoint(x: surface.midX, y: surface.midY)
        var crossedPinned = false
        for step in 0...40 {
            let t = CGFloat(step) / 40
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            XCTAssertNotEqual(coverage(point), .outside, "route point \(step) must never dismiss")
            if pinned.contains(point) { crossedPinned = true }
        }
        XCTAssertEqual(coverage(end), .surface)
        if crossedPinned {
            let onPinned = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y + (end.y - start.y) * 0.5)
            if pinned.contains(onPinned) { XCTAssertEqual(coverage(onPinned), .transit) }
        }

        // Clearly away from both source and destination.
        XCTAssertEqual(coverage(CGPoint(x: 200, y: 100)), .outside)
        XCTAssertEqual(coverage(CGPoint(x: anchor.midX, y: main.minY + 10)), .outside, "far below the row")
        XCTAssertEqual(coverage(CGPoint(x: surface.midX, y: surface.midY)
            .applying(CGAffineTransform(translationX: (surface.midX - anchor.midX) * 0.9, y: 0))), .outside,
                       "beyond the surface, away from the row")
    }

    func testCrossingPanelsCountOnlyWhereTheyLieOnTheRoute() {
        let main = CGRect(x: 1200, y: 100, width: 420, height: 900)
        let anchor = CGRect(x: 1212, y: 800, width: 396, height: 42)
        let surface = CGRect(x: 700, y: 400, width: SubtaskPanelLayout.panelWidth, height: 220)
        // Its top lies across the route; its lower part hangs below the hull.
        let onRoute = CGRect(x: 1050, y: 300, width: 200, height: 250)
        let offRoute = CGRect(x: 980, y: 120, width: 200, height: 120)
        func coverage(_ point: CGPoint) -> SubtaskPanelLayout.PointerCoverage {
            SubtaskPanelLayout.pointerCoverage(point, surfaceFrame: surface, cornerSize: 20, mainPanelFrame: main,
                                               anchorRect: anchor, crossingFrames: [onRoute, offRoute])
        }
        // A corner of the on-route panel that sticks out of the hull.
        XCTAssertEqual(coverage(CGPoint(x: onRoute.maxX - 10, y: onRoute.minY + 20)), .transit)
        XCTAssertEqual(coverage(CGPoint(x: offRoute.midX, y: offRoute.midY)), .outside)
        XCTAssertEqual(
            SubtaskPanelLayout.pointerCoverage(CGPoint(x: onRoute.maxX - 10, y: onRoute.minY + 20), surfaceFrame: surface,
                                               cornerSize: 20, mainPanelFrame: main, anchorRect: anchor),
            .outside, "without the pinned panel that point is off the corridor"
        )
        XCTAssertEqual(SubtaskPanelLayout.distance(from: CGPoint(x: surface.maxX + 30, y: surface.maxY + 40), to: surface), 50,
                       accuracy: 0.001)
        XCTAssertEqual(SubtaskPanelLayout.distance(from: CGPoint(x: surface.midX, y: surface.midY), to: surface), 0)
    }

    // MARK: - Surface size and corner-aware geometry

    func testSurfaceSizeStaysInsideTheSpecifiedBounds() {
        XCTAssertTrue((260...310).contains(SubtaskPanelLayout.panelWidth))
        XCTAssertLessThanOrEqual(SubtaskPanelLayout.maximumListHeight, 240)
        // Short families still size to content — the cap is a ceiling only.
        XCTAssertEqual(SubtaskPanelLayout.clampedListHeight(96), 96, accuracy: 0.5)
        XCTAssertEqual(
            SubtaskPanelLayout.clampedListHeight(900),
            SubtaskPanelLayout.maximumListHeight,
            accuracy: 0.5
        )
    }

    /// The hit shape follows the live corner setting: the same near-corner
    /// point is surface at a small corner and genuinely outside at the
    /// largest one, which a fixed radius of 18 could never express.
    func testSurfaceContainmentFollowsTheConfiguredCorner() {
        let bounds = CGRect(x: 0, y: 0, width: SubtaskPanelLayout.panelWidth, height: 220)
        let nearCorner = CGPoint(x: 3, y: 3)
        XCTAssertTrue(
            SubtaskPanelLayout.surfaceContains(
                nearCorner, in: bounds, cornerSize: PanelCornerSize.small.rawValue
            )
        )
        XCTAssertFalse(
            SubtaskPanelLayout.surfaceContains(
                nearCorner, in: bounds, cornerSize: PanelCornerSize.maximum.rawValue
            )
        )
        // Interior and edge-centre points are surface at every setting.
        for size in PanelCornerSize.allCases {
            XCTAssertTrue(
                SubtaskPanelLayout.surfaceContains(
                    CGPoint(x: bounds.midX, y: bounds.midY),
                    in: bounds, cornerSize: size.rawValue
                )
            )
            XCTAssertTrue(
                SubtaskPanelLayout.surfaceContains(
                    CGPoint(x: bounds.midX, y: 1),
                    in: bounds, cornerSize: size.rawValue
                ),
                "the header strip's centre is always inside the shape"
            )
            XCTAssertFalse(
                SubtaskPanelLayout.surfaceContains(
                    CGPoint(x: bounds.maxX + 1, y: bounds.midY),
                    in: bounds, cornerSize: size.rawValue
                )
            )
        }
    }

    /// Padding must clear the curve at every setting, and the narrower
    /// surface must still leave a readable title column beside the header
    /// controls at the deepest corner (two 30pt controls + 6pt spacing).
    func testSurfaceInsetsClearTheCurveAndKeepATitleColumn() {
        for size in PanelCornerSize.allCases {
            let insets = SubtaskPanelLayout.surfaceInsets(cornerSize: size.rawValue)
            XCTAssertGreaterThan(insets.horizontal, insets.cornerClearance)
            XCTAssertGreaterThan(insets.top, insets.cornerClearance)
            XCTAssertGreaterThan(insets.bottom, insets.cornerClearance)
            XCTAssertGreaterThan(insets.row, insets.cornerClearance)
            XCTAssertGreaterThanOrEqual(
                insets.titleWidth(
                    panelWidth: SubtaskPanelLayout.panelWidth,
                    controlWidth: 66,
                    spacing: 8
                ),
                148,
                "\(size) must leave a readable title column"
            )
        }
    }

    // MARK: - Pinned header drag region

    func testHeaderDragRegionExcludesItsControls() {
        let bounds = CGRect(x: 0, y: 0, width: SubtaskPanelLayout.panelWidth, height: 240)
        let geometry = PanelSurfaceDragGeometry(
            headerFrame: CGRect(x: 0, y: 0, width: bounds.width, height: 52),
            controlFrames: [CGRect(x: 196, y: 11, width: 66, height: 30)]
        )
        XCTAssertTrue(
            geometry.allowsWindowDrag(at: CGPoint(x: 40, y: 26), in: bounds),
            "the title stretch of the header drags the window"
        )
        XCTAssertFalse(
            geometry.allowsWindowDrag(at: CGPoint(x: 230, y: 26), in: bounds),
            "unpin/close keep their own presses"
        )
        XCTAssertFalse(
            geometry.allowsWindowDrag(at: CGPoint(x: 40, y: 120), in: bounds),
            "the checklist body is not a drag handle"
        )
        XCTAssertTrue(
            geometry.allowsWindowDrag(at: CGPoint(x: 40, y: 48), in: bounds),
            "the measured header extends past the old fixed 44pt strip"
        )
    }

    /// Larger corners push the header down and make it taller; the drag
    /// region follows the measurement instead of a hard-coded strip.
    func testHeaderDragRegionFollowsCornerAwarePadding() {
        let bounds = CGRect(x: 0, y: 0, width: SubtaskPanelLayout.panelWidth, height: 260)
        let tallHeader = PanelSurfaceDragGeometry(
            headerFrame: CGRect(x: 0, y: 0, width: bounds.width, height: 74),
            controlFrames: [CGRect(x: 182, y: 22, width: 66, height: 30)]
        )
        XCTAssertTrue(tallHeader.allowsWindowDrag(at: CGPoint(x: 40, y: 66), in: bounds))
        XCTAssertFalse(tallHeader.allowsWindowDrag(at: CGPoint(x: 200, y: 30), in: bounds))
    }

    func testUnmeasuredHeaderDoesNotStealAControlPress() {
        let bounds = CGRect(x: 0, y: 0, width: 272, height: 240)
        XCTAssertFalse(PanelSurfaceDragGeometry().allowsWindowDrag(
            at: CGPoint(x: 40, y: 20), in: bounds
        ))
    }

    func testDragGeometryMergeKeepsEveryControlAndTheLatestHeader() {
        let header = PanelSurfaceDragGeometry(
            headerFrame: CGRect(x: 0, y: 0, width: 272, height: 52)
        )
        let control = PanelSurfaceDragGeometry(
            controlFrames: [CGRect(x: 196, y: 11, width: 66, height: 30)]
        )
        let merged = header.merging(control)
        XCTAssertEqual(merged.headerFrame, header.headerFrame)
        XCTAssertEqual(merged.controlFrames, control.controlFrames)
        // Merging in the other order must not lose the measured header.
        XCTAssertEqual(control.merging(header).headerFrame, header.headerFrame)
    }

    // MARK: - Task panel V2 batch 2: shared view sizing

    func testBothViewsShareTheListMaximumAndSizeToTheirContent() {
        typealias Layout = SubtaskPanelLayout
        XCTAssertEqual(Layout.galleryContentHeight(itemCount: 0), Layout.galleryEmptyHeight)
        let oneRow = Layout.galleryContentHeight(itemCount: 1)
        XCTAssertEqual(Layout.galleryContentHeight(itemCount: 2), oneRow, "two cards share a row")
        XCTAssertEqual(
            Layout.galleryContentHeight(itemCount: 3),
            oneRow + Layout.galleryCardHeight + Layout.gallerySpacing,
            accuracy: 0.001
        )
        // One image is a half-width compact card, never most of the panel.
        XCTAssertLessThan(oneRow, Layout.maximumListHeight / 2)
        XCTAssertLessThanOrEqual(Layout.galleryContentHeight(itemCount: 4), Layout.maximumListHeight,
                                 "four items show without scrolling")

        func height(_ view: FamilyPanelView, children: Int = 0, measured: CGFloat? = nil, attachments: Int = 0) -> CGFloat {
            Layout.contentHeight(for: view, childCount: children, measuredListHeight: measured, attachmentCount: attachments)
        }
        // Growth stops at the existing subtask maximum for both views.
        XCTAssertEqual(height(.subtasks, children: 40, measured: 40 * 42), Layout.maximumListHeight)
        XCTAssertEqual(height(.attachments, attachments: 20), Layout.maximumListHeight)
        XCTAssertEqual(height(.subtasks, children: 40), Layout.maximumListHeight, "unmeasured lists use the same bound")
        XCTAssertEqual(height(.subtasks), 0)
        XCTAssertEqual(height(.attachments), Layout.galleryEmptyHeight)

        // A long list switching to a small gallery shrinks; the converse grows.
        let longList = height(.subtasks, children: 12, measured: 12 * 42, attachments: 1)
        let smallGallery = height(.attachments, children: 12, measured: 12 * 42, attachments: 1)
        XCTAssertLessThan(smallGallery, longList)
        let shortList = height(.subtasks, children: 1, measured: 50, attachments: 6)
        let bigGallery = height(.attachments, children: 1, measured: 50, attachments: 6)
        XCTAssertGreaterThan(bigGallery, shortList)
    }

    func testViewSwitchNamesItsDestination() {
        XCTAssertEqual(FamilyPanelView.subtasks.destination, .attachments)
        XCTAssertEqual(FamilyPanelView.attachments.destination, .subtasks)
        XCTAssertEqual(FamilyPanelView.subtasks.switchLabel, "Show attachments")
        XCTAssertEqual(FamilyPanelView.subtasks.switchSymbol, "photo.on.rectangle")
        XCTAssertEqual(FamilyPanelView.attachments.switchLabel, "Show subtasks")
        XCTAssertEqual(FamilyPanelView.attachments.switchSymbol, "checklist")
    }
}
