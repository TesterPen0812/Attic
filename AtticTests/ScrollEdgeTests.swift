import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The lists' edges under the floating controls (owner, 2026-10-01): the
/// system's soft scroll edge by default, round 13's clean cut as a
/// preview-only comparison, and nothing left of the per-control softening
/// (no content re-rendered to blur it).
@MainActor
final class ScrollEdgeTests: XCTestCase {
    private var saved: AtticScrollEdgeStyle?

    override func tearDown() async throws {
        if let saved { AtticScrollEdgeLab.shared.style = saved }
        saved = nil
        try await super.tearDown()
    }

    private func use(_ style: AtticScrollEdgeStyle) {
        if saved == nil { saved = AtticScrollEdgeLab.shared.style }
        AtticScrollEdgeLab.shared.style = style
    }

    // MARK: - The switch

    private func scratchDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "AtticScrollEdgeLabTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testTheSystemSoftEdgeIsTheDefault() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: true).style, .systemSoft)
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: false).style, .systemSoft)
    }

    func testAPreviewKeepsItsChoiceAndUITestsCanForceOne() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let lab = AtticScrollEdgeLab(defaults: defaults, isPreview: true)
        XCTAssertEqual(lab.style, .systemSoft)
        lab.style = .cleanCut
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: true).style, .cleanCut, "a preview keeps the owner's choice")
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, environment: ["ATTIC_UI_TEST_SCROLL_EDGES": "soft"], isPreview: true).style, .systemSoft)
        let (fresh, freshCleanup) = try scratchDefaults()
        defer { freshCleanup() }
        XCTAssertEqual(AtticScrollEdgeLab(defaults: fresh, environment: ["ATTIC_UI_TEST_SCROLL_EDGES": "clean"], isPreview: true).style, .cleanCut)
        XCTAssertEqual(AtticScrollEdgeStyle.allCases.map(\.title), ["System soft edge", "Clean cut"])
    }

    /// The official identity and every other non-preview one: the system
    /// soft edge, whatever the environment or the stored choice says, no
    /// switch, and nothing is kept. The strict predicate ignores the launch
    /// arguments (`--attic-motion-lab` widens the Motion Lab, not this), so
    /// each identity is paired with and without it.
    func testNoNonPreviewIdentityLeavesTheSystemSoftEdge() throws {
        let identities: [String?] = [
            "com.taha.Attic", "com.taha.Attic.UnitTestHost", "com.taha.Attic.perf.ui",
            "com.taha.Attic.previewish", "com.taha.Attic.preview.", "com.taha.AtticUITests", "", nil,
        ]
        for identity in identities {
            for arguments in [[String](), [AtticMotionLab.argument]] {
                let name = "\(identity ?? "nil") \(arguments)"
                let isPreview = AtticPreviewOverrides.isPreviewIdentity(identity)
                XCTAssertFalse(isPreview, "\(name) is not a preview")
                let (defaults, cleanup) = try scratchDefaults()
                defer { cleanup() }
                // The environment says clean.
                let forced = AtticScrollEdgeLab(defaults: defaults, environment: ["ATTIC_UI_TEST_SCROLL_EDGES": "clean"], isPreview: isPreview)
                XCTAssertEqual(forced.style, .systemSoft, "\(name): the environment cannot choose Clean cut")
                XCTAssertFalse(forced.offersChoice, "\(name): no switch")
                // The defaults say clean.
                defaults.set(AtticScrollEdgeStyle.cleanCut.rawValue, forKey: AtticScrollEdgeLab.styleKey)
                XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style, .systemSoft,
                               "\(name): a stored Clean cut is ignored")
                // A choice made in code is not kept.
                defaults.removeObject(forKey: AtticScrollEdgeLab.styleKey)
                AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style = .cleanCut
                XCTAssertNil(defaults.string(forKey: AtticScrollEdgeLab.styleKey), "\(name): nothing is kept")
            }
        }
        // The Motion Lab's own policy is wider, and is left as it is: this is
        // the gap the strict predicate closes.
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.perf.ui", arguments: [AtticMotionLab.argument]))
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.preview.", arguments: [AtticMotionLab.argument]))
        // A preview identity is the one that may.
        XCTAssertTrue(AtticPreviewOverrides.isPreviewIdentity("com.taha.Attic.preview.main"))
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let preview = AtticScrollEdgeLab(defaults: defaults, isPreview: true)
        XCTAssertTrue(preview.offersChoice)
    }

    // MARK: - The system soft edge on the Tasks lists

    /// Native pockets occupy only resting gaps INSIDE the viewport. The
    /// controls never overlap the scroll view or its clipped native effect.
    func testTheNativeEdgesEndBeforeTheControlsAndLeaveTheFirstRowAtRest() throws {
        use(.systemSoft)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let listTop = TasksViewport.listTop(tabsTop: tabsTop)
        let top = TasksViewport.controlsBottom(tabsTop: tabsTop)
        let content = try XCTUnwrap(hosted.window.contentView)
        let frame = list.convert(list.bounds, to: content)
        XCTAssertEqual(frame.minY, top, accuracy: 0.5)
        XCTAssertEqual(list.contentInsets.top, listTop - top, accuracy: 0.5)
        let first = try XCTUnwrap(hosted.model.rows(for: .now).first?.id)
        XCTAssertEqual(try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first)]).minY, listTop, accuracy: 0.5,
                       "the first row keeps its resting place beyond the native fade")
        let topPocket = try XCTUnwrap(Self.pockets(in: list).first { $0.frame.minY < 1 })
        XCTAssertEqual(topPocket.frame.maxY, listTop - top, accuracy: 0.5,
                       "resting row ink starts beyond the pocket's clear boundary")
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        let pockets = Self.pockets(in: list).map(\.frame.height).sorted()
        XCTAssertEqual(pockets.count, 2)
        XCTAssertEqual(pockets.first ?? 0, listTop - top, accuracy: 0.5)
        XCTAssertEqual(pockets.last ?? 0, AtticLayout.contentToAddBar, accuracy: 0.5)
        XCTAssertTrue(Self.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty, "no row is blurred by Attic")
    }

    /// Clean cut: no bars and no system pockets; the list's own mask cuts
    /// the rows, and the rows rest in the same place.
    func testTheCleanCutHasNoSystemEdgeEffect() throws {
        use(.cleanCut)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        XCTAssertEqual(list.contentInsets.top, TasksViewport.listTop(tabsTop: layout.headerBottom + AtticLayout.pageTabsTop),
                       accuracy: 0.5)
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertTrue(Self.pockets(in: list).isEmpty, "no system edge effect")
        XCTAssertTrue(Self.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty, "no row is blurred by Attic")
    }

    /// Done's log takes the same edges as Now and Later.
    func testDoneHasTheSystemsEdgeEffectToo() throws {
        use(.systemSoft)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        hosted.go(to: .done)
        let list = try shownList(hosted)
        list.contentView.scroll(to: CGPoint(x: 0, y: 200))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertEqual(Self.pockets(in: list).count, 2)
    }

    /// The tabs still work under the lists' top bar: a tab click switches
    /// the page. (Typing in the add bar is a UI test's: `TasksPageUITests`.)
    func testTheTabsStillSwitchThePagesUnderTheBar() throws {
        use(.systemSoft)
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .backlog)
        XCTAssertEqual(hosted.model.tab, .backlog)
        XCTAssertEqual(hosted.shownPage(), 1)
        hosted.go(to: .now)
        XCTAssertEqual(hosted.shownPage(), 0)
    }

    // MARK: - Helpers

    private func shownList(_ hosted: Hosted) throws -> NSScrollView {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        return try XCTUnwrap(hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        })
    }

    /// AppKit's scroll edge effect views (`NSScrollPocket`) in a scroll view.
    static func pockets(in scroll: NSScrollView) -> [NSView] {
        scroll.subviews.filter { String(describing: type(of: $0)) == "NSScrollPocket" }
    }

    /// The nearest ancestor (or the view) whose layer is masked.
    static func maskedAncestor(of view: NSView, below root: NSView?) -> NSView? {
        var current: NSView? = view
        while let candidate = current, candidate !== root {
            if candidate.layer?.mask != nil { return candidate }
            current = candidate.superview
        }
        return nil
    }

    /// Layers with a blur filter (Attic's own, as `.blur` or a visual effect).
    static func blurredLayers(in layer: CALayer) -> [CALayer] {
        let own = (layer.filters ?? []).contains { String(describing: $0).localizedCaseInsensitiveContains("blur") } ? [layer] : []
        return own + (layer.sublayers ?? []).flatMap { blurredLayers(in: $0) }
    }
}
