import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The lists' edges under the floating controls (owner, 2026-10-01): the
/// system's soft scroll edge by default, round 13's clean cut as a
/// preview-only comparison, and nothing left of the per-control softening
/// (no content re-rendered to blur it, no mask under the system edge).
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
    /// soft edge, whatever the environment or the stored choice says, and
    /// nothing is kept. `isPreview` is what `AtticMotionLab` decides for an
    /// identity, so each identity goes through that check here.
    func testNoNonPreviewIdentityLeavesTheSystemSoftEdge() throws {
        let identities: [(String?, [String])] = [
            ("com.taha.Attic", []),
            ("com.taha.Attic", [AtticMotionLab.argument]),
            ("com.taha.Attic.UnitTestHost", []),
            ("com.taha.Attic.perf.ui", []),
            ("com.taha.Attic.preview.", []),
            (nil, [AtticMotionLab.argument]),
        ]
        for (identity, arguments) in identities {
            let isPreview = AtticMotionLab.isAvailable(bundleIdentifier: identity, arguments: arguments)
            XCTAssertFalse(isPreview, "\(identity ?? "nil") \(arguments) is not a preview")
            let (defaults, cleanup) = try scratchDefaults()
            defer { cleanup() }
            // The environment says clean.
            let forced = AtticScrollEdgeLab(defaults: defaults, environment: ["ATTIC_UI_TEST_SCROLL_EDGES": "clean"], isPreview: isPreview)
            XCTAssertEqual(forced.style, .systemSoft, "\(identity ?? "nil"): the environment cannot choose Clean cut")
            // The defaults say clean.
            defaults.set(AtticScrollEdgeStyle.cleanCut.rawValue, forKey: AtticScrollEdgeLab.styleKey)
            XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style, .systemSoft,
                           "\(identity ?? "nil"): a stored Clean cut is ignored")
            // A choice made in code is not kept.
            defaults.removeObject(forKey: AtticScrollEdgeLab.styleKey)
            AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style = .cleanCut
            XCTAssertNil(defaults.string(forKey: AtticScrollEdgeLab.styleKey), "\(identity ?? "nil"): nothing is kept")
        }
        // A preview identity is the one that may.
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.preview.main", arguments: []))
    }

    // MARK: - The system soft edge on the Tasks lists

    /// Under the system soft edge, the shown list's scroll view has the
    /// system's pockets (AppKit's scroll edge effect views) at its top and
    /// bottom, as tall as the tabs' bar (to the resting row) and the add
    /// bar's zone; the rows rest where they always did; nothing masks the
    /// list and no row is blurred by Attic.
    func testTheShownListHasTheSystemsEdgeEffectUnderTheBars() throws {
        use(.systemSoft)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let listTop = TasksViewport.listTop(tabsTop: layout.headerBottom + AtticLayout.pageTabsTop)
        let bottomMargin = TasksViewport.bottomMargin(bottomInset: max(AtticSpacing.panelMargin, layout.chromeInsets.bottom))
        XCTAssertEqual(list.contentInsets.top, listTop, accuracy: 0.5, "the first row rests where it always did")
        XCTAssertEqual(list.contentInsets.bottom, bottomMargin, accuracy: 0.5)
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        let pockets = Self.pockets(in: list).map(\.frame.height).sorted()
        XCTAssertEqual(pockets.count, 2, "a pocket at the top and at the bottom (\(pockets))")
        XCTAssertEqual(pockets.last ?? 0, listTop, accuracy: 0.5, "the top pocket runs to the resting row")
        XCTAssertEqual(pockets.first ?? 0, bottomMargin, accuracy: 0.5, "the bottom pocket is the add bar's zone")
        XCTAssertNil(Self.maskedAncestor(of: list, below: hosted.window.contentView), "no mask over the list")
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
