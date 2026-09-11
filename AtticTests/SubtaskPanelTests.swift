import XCTest
@testable import Attic

@MainActor
final class SubtaskPanelTests: XCTestCase {
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

    func testFramePreservingTopKeepsTopEdgeStationary() {
        let frame = CGRect(x: 100, y: 500, width: 292, height: 200)
        let adjusted = SubtaskPanelLayout.framePreservingTop(frame, height: 260)
        XCTAssertEqual(adjusted?.maxY, frame.maxY, accuracy: 0.001)
        XCTAssertEqual(adjusted?.height, 260, accuracy: 0.001)
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

    func testHoverOpenRequiresDwellToMature() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.noteRowHover(familyID: family, isHovering: true, at: 0)
        XCTAssertNil(lifecycle.transientFamilyID)
        XCTAssertNotNil(lifecycle.pendingOpen)
        // An early row leave cancels the pending open before it matures.
        lifecycle.noteRowHover(familyID: family, isHovering: false, at: 0.1)
        XCTAssertNil(lifecycle.pendingOpen)
        XCTAssertFalse(lifecycle.maturePendingOpen(for: family, at: 0.5))
        lifecycle.noteRowHover(familyID: family, isHovering: true, at: 0.2)
        XCTAssertFalse(
            lifecycle.maturePendingOpen(for: family, at: 0.4),
            "Open must wait for the full dwell"
        )
        XCTAssertTrue(lifecycle.maturePendingOpen(for: family, at: 0.56))
        XCTAssertEqual(lifecycle.transientFamilyID, family)
    }

    func testRowLeaveSchedulesCancellableCloseGrace() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.openTransient(family, latched: false)
        lifecycle.noteRowHover(familyID: family, isHovering: false, at: 1.0)
        XCTAssertNotNil(lifecycle.pendingClose)
        XCTAssertFalse(lifecycle.maturePendingClose(for: family, at: 1.2))
        // Pointer crossing into the panel cancels the pending close.
        lifecycle.noteTransientPointer(inside: true, at: 1.3)
        XCTAssertNil(lifecycle.pendingClose)
        XCTAssertFalse(lifecycle.maturePendingClose(for: family, at: 2.0))
        XCTAssertEqual(lifecycle.transientFamilyID, family)
    }

    func testPendingCloseMaturesAfterGrace() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.openTransient(family, latched: false)
        lifecycle.noteRowHover(familyID: family, isHovering: false, at: 1.0)
        XCTAssertTrue(
            lifecycle.maturePendingClose(
                for: family,
                at: 1.0 + SubtaskPanelLayout.closeGrace + 0.01
            )
        )
        XCTAssertNil(lifecycle.transientFamilyID)
    }

    func testHoveringSecondFamilySupersedesPendingOpen() {
        var lifecycle = SubtaskPanelLifecycle()
        let a = UUID()
        let b = UUID()
        lifecycle.noteRowHover(familyID: a, isHovering: true, at: 0)
        lifecycle.noteRowHover(familyID: a, isHovering: false, at: 0.1)
        lifecycle.noteRowHover(familyID: b, isHovering: true, at: 0.1)
        // A's dwell never ran to maturity; only B may open.
        XCTAssertFalse(lifecycle.maturePendingOpen(for: a, at: 0.6))
        XCTAssertTrue(lifecycle.maturePendingOpen(for: b, at: 0.46))
        XCTAssertEqual(lifecycle.transientFamilyID, b)
    }

    func testExplicitOpenLatchesAndSurvivesRowLeave() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.openTransient(family, latched: true)
        lifecycle.noteRowHover(familyID: family, isHovering: false, at: 1.0)
        XCTAssertNil(lifecycle.pendingClose)
        lifecycle.noteTransientPointer(inside: false, at: 1.1)
        XCTAssertNil(lifecycle.pendingClose)
        XCTAssertEqual(lifecycle.transientFamilyID, family)
    }

    func testPinPromotesTransientAndSuppressesHoverReopen() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.openTransient(family, latched: true)
        lifecycle.pin(family)
        XCTAssertEqual(lifecycle.pinnedFamilyID, family)
        XCTAssertNil(lifecycle.transientFamilyID)
        XCTAssertFalse(lifecycle.mayOpenTransient(for: family))
        lifecycle.noteRowHover(familyID: family, isHovering: true, at: 2.0)
        XCTAssertNil(lifecycle.pendingOpen)
    }

    func testPinningSecondFamilyReplacesFirstPinnedWindow() {
        var lifecycle = SubtaskPanelLifecycle()
        let a = UUID()
        let b = UUID()
        lifecycle.pin(a)
        lifecycle.pin(b)
        XCTAssertEqual(lifecycle.pinnedFamilyID, b)
        XCTAssertEqual(lifecycle.unpin(), b)
        XCTAssertNil(lifecycle.pinnedFamilyID)
    }

    func testDismissClearsPendingWork() {
        var lifecycle = SubtaskPanelLifecycle()
        let family = UUID()
        lifecycle.noteRowHover(familyID: family, isHovering: true, at: 0)
        lifecycle.closeTransient()
        XCTAssertNil(lifecycle.pendingOpen)
        XCTAssertNil(lifecycle.transientFamilyID)
        XCTAssertFalse(lifecycle.maturePendingOpen(for: family, at: 1.0))
    }
}
