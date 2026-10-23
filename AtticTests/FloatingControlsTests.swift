import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Floating controls over the approved variable blur (owner, 2026-10-14):
/// content runs on under every page's fixed controls, top and bottom; the
/// blur is the top's only (owner, 2026-10-22: no bottom blur).
@MainActor
final class FloatingControlsTests: XCTestCase {
    func testTheApprovedBlurIsTheDefault() {
        XCTAssertEqual(AtticEdgeBlurMetrics.radius, 0.5, "the owner's slight strength, 2026-10-22")
        XCTAssertEqual(AtticEdgeBlurMetrics.reach, 0, "the owner's reach, 2026-10-22: it ends with the controls")
    }

    func testOnlyAPreviewTunesTheBlurAndOnlyThereIsItKept() throws {
        let suite = "AtticEdgeBlurLabTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9.0, forKey: AtticEdgeBlurLab.radiusKey)
        defaults.set(400.0, forKey: AtticEdgeBlurLab.reachKey)

        let product = AtticEdgeBlurLab(defaults: defaults, isPreview: false, blurAvailable: true)
        XCTAssertFalse(product.offersTuning)
        XCTAssertEqual(product.radius, 0.5, "a product identity ignores a stored value")
        XCTAssertEqual(product.reach, 0)
        product.radius = 4
        XCTAssertEqual(defaults.double(forKey: AtticEdgeBlurLab.radiusKey), 9, "and keeps nothing")

        let preview = AtticEdgeBlurLab(defaults: defaults, isPreview: true, blurAvailable: true)
        XCTAssertTrue(preview.offersTuning)
        XCTAssertEqual(preview.radius, 9)
        XCTAssertEqual(preview.reach, AtticEdgeBlurLab.reachRange.upperBound, "clamped")
        preview.reach = 20
        XCTAssertEqual(defaults.double(forKey: AtticEdgeBlurLab.reachKey), 20)

        XCTAssertFalse(AtticEdgeBlurLab(defaults: defaults, isPreview: true, blurAvailable: false).offersTuning,
                       "no tuning where there is no blur")
    }

    /// The owner's 10-17 decision: content shows under every control,
    /// blurred at the top (sharp at the bottom since 10-22), with no fade hiding it, on every surface: no surface fade
    /// over the blur on an opaque panel, and no content fade on a
    /// see-through one (T-03 C). The pixels: `RoundO3ControlsTests`.
    func testWithTheBlurNothingButTheBlurIsDrawnUnderTheControls() {
        for surface in PanelSurfaceStyle.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                let design = AtticDesignContext(mode: mode, surface: surface)
                XCTAssertTrue(AtticEdgeBlurBackdrop.blurs(design, available: true), "\(surface) \(mode)")
                XCTAssertFalse(AtticEdgeBlurBackdrop.drawsSolidSurface(design, available: true), "\(surface) \(mode): no fade")
                let contrast = AtticDesignContext(mode: mode, surface: surface, increaseContrast: true)
                XCTAssertFalse(AtticEdgeBlurBackdrop.drawsSolidSurface(contrast, available: true), "\(surface) \(mode): Increase Contrast too")
            }
        }
    }

    /// A plain-text line among the top controls is part of them: the blur
    /// covers it, from the panel's edge (owner, 2026-10-17: content is no
    /// longer gone above its lower edge).
    func testAPlainTopLineIsPartOfTheTopControls() {
        let tabsTop: CGFloat = 80
        XCTAssertGreaterThanOrEqual(TasksViewport.topEdges(tabsTop: tabsTop).top, TasksViewport.plainLine(tabsTop: tabsTop).upperBound)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 520))
        XCTAssertGreaterThanOrEqual(NoteHistoryPage.edges(layout).top, NoteHistoryPage.versionLine(layout).upperBound)
    }

    func testTheBlurIsStrongestAtThePanelsEdge() throws {
        func alphas(_ edge: VerticalEdge) throws -> [UInt8] {
            let image = try XCTUnwrap(AtticVariableBlurView.maskImage(height: 40, edge: edge))
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            return (0..<image.height).map { data[$0 * image.bytesPerRow + 3] }
        }
        let top = try alphas(.top)
        XCTAssertEqual(top.first, 255)
        XCTAssertEqual(top.last, 0)
        XCTAssertEqual(top, top.sorted(by: >))
        XCTAssertEqual(try alphas(.bottom), top.reversed(), "the bottom edge's blur is the top's, mirrored")
    }

    /// Reduce Transparency, or a system without the filter: an opaque fade
    /// in the blur's place (U-02), the deliberate look with no blur.
    func testReduceTransparencyGivesTheBlurWayToAFade() {
        XCTAssertTrue(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(reduceTransparency: true), available: true))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blurs(AtticDesignContext(), available: false))
        for surface in PanelSurfaceStyle.allCases {
            XCTAssertTrue(AtticEdgeBlurBackdrop.drawsSolidSurface(AtticDesignContext(surface: surface, reduceTransparency: true), available: true),
                          "\(surface): solid under the controls with Reduce Transparency")
        }
    }

    /// Tasks: the tabs' plain line is part of the top controls; the
    /// bottom edge follows the stack, the composer's strip included.
    func testTasksEdgesFollowTheTabsAndTheBottomStack() {
        let tabsTop: CGFloat = 80
        let top = TasksViewport.topEdges(tabsTop: tabsTop)
        XCTAssertEqual(top.top, TasksViewport.controlsBottom(tabsTop: tabsTop))
        XCTAssertEqual(TasksViewport.plainLine(tabsTop: tabsTop).upperBound,
                       tabsTop + AtticLayout.pageTabsHeight + AtticPageTabsMetrics.underlineHeight + AtticPageTabsMetrics.underlineGap,
                       "the underline is part of the line")
        XCTAssertGreaterThanOrEqual(top.top, TasksViewport.plainLine(tabsTop: tabsTop).upperBound)
        XCTAssertGreaterThan(TasksViewport.listTop(tabsTop: tabsTop), TasksViewport.plainLine(tabsTop: tabsTop).upperBound,
                             "a resting row is clear of the line")

        let inset: CGFloat = 12
        let idle = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack - AtticPickerMetrics.stripHeight, bottomInset: inset)
        XCTAssertEqual(idle.bottom, AtticControlSize.addBarHeight + inset)
        let strip = TasksViewport.bottomEdges(stack: TasksViewport.reservedStack, bottomInset: inset)
        XCTAssertEqual(strip.bottom, TasksViewport.reservedStack + inset, "the strip is part of the bottom controls")
    }

    /// Owner, 2026-10-22 (Tasks and Notes): no blur at the bottom. Content
    /// runs under the bottom controls sharp, with no blur and no fade; the
    /// top keeps the approved blur; Reduce Transparency keeps its solid
    /// surface under the controls at both edges (U-02). It supersedes S3-01
    /// (the blur held full under the composer's Date, Tag and Priority).
    func testOnlyTheTopEdgeIsBlurred() throws {
        XCTAssertTrue(AtticEdgeBlurBackdrop.blursEdge(.top))
        XCTAssertFalse(AtticEdgeBlurBackdrop.blursEdge(.bottom))
        try XCTSkipUnless(AtticVariableBlur.isAvailable, "no variable blur on this system")

        func blurEdges(_ design: AtticDesignContext) throws -> [VerticalEdge] {
            let host = NSHostingView(rootView: AnyView(AtticEdgeBlurBackdrops(top: 60, bottom: 90)
                .frame(width: 340, height: 520).atticDesign(design)))
            host.frame = CGRect(x: 0, y: 0, width: 340, height: 520)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            func views(_ view: NSView) -> [AtticVariableBlurView] {
                ((view as? AtticVariableBlurView).map { [$0] } ?? []) + view.subviews.flatMap(views)
            }
            return views(host).map(\.edge)
        }
        for surface in PanelSurfaceStyle.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                XCTAssertEqual(try blurEdges(AtticDesignContext(mode: mode, surface: surface)), [.top],
                               "\(surface) \(mode): the top blurs, the bottom does not")
            }
        }
        let reduced = AtticDesignContext(surface: .glass, reduceTransparency: true)
        XCTAssertEqual(try blurEdges(reduced), [], "Reduce Transparency: no blur at either edge")
        XCTAssertTrue(AtticEdgeBlurBackdrop.drawsSolidSurface(reduced, available: true),
                      "and the solid surface stays under the controls (U-02)")
    }

    /// U-02: with no blur (Reduce Transparency) the surface is solid under
    /// the controls, out to their inner edge, and gone 12 pt past it, so no
    /// text shows sharp behind a control and the title's rest (16 below
    /// the header) is untouched.
    func testWithoutTheBlurTheSurfaceIsSolidUnderTheControls() {
        // The solid surface keeps room for its fade even when the blur's
        // reach is 0 (the slight top blur, 2026-10-22).
        let extent: CGFloat = 52, height = extent + max(AtticEdgeBlurMetrics.reach, AtticEdgeBlurMetrics.solidFade)
        let stops = AtticEdgeBlurBackdrop.solidStops(height: height, extent: extent)
        XCTAssertEqual(stops.solid * height, extent, accuracy: 0.01)
        XCTAssertEqual(stops.clear * height, extent + AtticEdgeBlurMetrics.solidFade, accuracy: 0.01)
        XCTAssertLessThan(AtticEdgeBlurMetrics.solidFade, AtticNoteMetrics.titleTopGap, "the resting title stays clear")
    }

    /// U-02: under Reduce Transparency a raised control lies on the panel's
    /// solid surface; otherwise its recipe is unchanged.
    func testReduceTransparencyMakesRaisedControlsOpaque() throws {
        var design = AtticDesignContext(mode: .dark)
        let plain = design.tokens.raised
        XCTAssertEqual(plain.opaque(design), plain)
        design.reduceTransparency = true
        let opaque = design.tokens.raised.opaque(design)
        let base = try XCTUnwrap(opaque.base)
        XCTAssertEqual(base.alpha, 1)
        XCTAssertEqual(opaque.fill, design.tokens.raised.fill)
    }
}

/// V-10: what opens under a task row is uncovered from its top as the rows
/// below make room: never drawn over them mid-spring.
@MainActor
final class TopRevealTests: XCTestCase {
    func testTheRevealUncoversFromTheTopOnly() {
        let rect = CGRect(x: 0, y: 40, width: 300, height: 120)
        let shut = AtticTopRevealShape(fraction: 0).path(in: rect).boundingRect
        XCTAssertEqual(shut.maxY, rect.minY, accuracy: 0.01, "nothing below the row shows")
        let half = AtticTopRevealShape(fraction: 0.5).path(in: rect).boundingRect
        XCTAssertEqual(half.maxY, rect.minY + 60, accuracy: 0.01, "as far down as the rows below have moved")
        XCTAssertLessThan(half.minX, rect.minX, "only the bottom edge cuts")
        XCTAssertLessThan(half.minY, rect.minY)
        let rest = AtticTopRevealShape(fraction: 1).path(in: rect).boundingRect
        XCTAssertTrue(rest.contains(rect.insetBy(dx: -20, dy: -20)), "at rest it cuts nothing")
    }
}

/// Owner B (2026-10-22): with no bottom blur, the composer's Date, Tag,
/// Priority and paperclip float on their own glass, as the corner buttons
/// do: one shared container with one shape per button (never one capsule
/// behind the row), and the other raised controls' opaque surface wherever
/// the controls are not live glass (Reduce Transparency included).
@MainActor
final class ComposerStripGlassTests: XCTestCase {
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
    private typealias Strip = AtticComposerStrip<EmptyView, EmptyView, EmptyView>

    private func strip(date: AtticStripValue? = nil) -> Strip {
        Strip(datePresented: .constant(false), tagsPresented: .constant(false), priorityPresented: .constant(false),
              date: date, tags: nil, priority: nil, onClearDate: {}, onClearTags: {}, onClearPriority: {},
              datePicker: { EmptyView() }, tagPicker: { EmptyView() }, priorityPicker: { EmptyView() },
              files: nil, onAttach: {}, onClearFiles: {})
    }

    private func host(_ design: AtticDesignContext, date: AtticStripValue? = nil) -> (NSPanel, NSView) {
        let size = CGSize(width: 300, height: 40)
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: strip(date: date).frame(width: size.width, height: size.height).atticDesign(design))
        panel.contentView = view
        panel.orderFront(nil)
        panel.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        return (panel, view)
    }

    /// AppKit's backdrop layers (the glass the window server samples), with
    /// how many glass shapes each draws.
    private func backdrops(in view: NSView) -> [Int] {
        func shapes(_ layer: CALayer) -> Int {
            ("\(type(of: layer))".contains("SDFElement") ? 1 : 0) + (layer.sublayers ?? []).map(shapes).reduce(0, +)
        }
        func walk(_ layer: CALayer) -> [Int] {
            ("\(type(of: layer))".contains("Backdrop") ? [shapes(layer)] : []) + (layer.sublayers ?? []).flatMap(walk)
        }
        return view.layer.map(walk) ?? []
    }

    func testTheStripButtonsAreTheFloatingGlassOnePillEach() {
        XCTAssertEqual(AtticPickerMetrics.stripHeight, AtticControlSize.secondaryControl, "the secondary controls' height, a step under the add bar")
        XCTAssertLessThan(AtticPickerMetrics.stripHeight, AtticControlSize.addBarHeight, "the strip reads under the add bar (owner, 2026-10-22)")
        XCTAssertEqual(Strip.usualWidth([("Attach", nil)], iconOnly: [0]), AtticPickerMetrics.stripHeight,
                       "the paperclip alone is a circle: as wide as it is tall")
        let tomorrow = AtticStripValue(text: "Tomorrow", spoken: "Tomorrow")
        for surface in PanelSurfaceStyle.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                for increaseContrast in [false, true] {
                    for date in [nil, tomorrow] {
                        let design = AtticDesignContext(mode: mode, surface: surface, increaseContrast: increaseContrast)
                        guard design.effectiveControls == .liquidGlass else { continue }
                        let (panel, view) = host(design, date: date)
                        defer { panel.orderOut(nil); panel.close() }
                        let name = "\(surface) \(mode) contrast=\(increaseContrast) date=\(date?.text ?? "unset")"
                        XCTAssertEqual(backdrops(in: view), [4], "\(name): one container, Date, Tag, Priority and the paperclip its shapes")
                    }
                }
            }
        }
    }

    func testWhereTheControlsAreNotGlassTheStripTakesTheirOpaqueSurface() throws {
        let opaque: [(String, AtticDesignContext)] = [
            ("Reduce Transparency", AtticDesignContext(reduceTransparency: true)),
            ("Reduce Transparency, Dark", AtticDesignContext(mode: .dark, reduceTransparency: true)),
            ("Craft (a Solid panel that is not key)", AtticDesignContext(controls: .craft)),
        ]
        for (name, design) in opaque {
            let (panel, view) = host(design)
            defer { panel.orderOut(nil); panel.close() }
            XCTAssertTrue(backdrops(in: view).isEmpty, "\(name): no glass")
            guard design.reduceTransparency else { continue }
            // Date's pill, between its edge and its icon, is opaque.
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let pixel = try XCTUnwrap(rep.colorAt(x: Int(4 * scale), y: Int(view.bounds.midY * scale)))
            let opaqueFound = pixel.alphaComponent > 0.99
            XCTAssertTrue(opaqueFound, "\(name): the pills lie on the opaque raised surface (U-02), alpha \(pixel.alphaComponent)")
        }
    }
}

/// Top glass (option "B for the top", 2026-10-22): the plain controls on
/// the top line, which rows and notes run under, float on the raised
/// material as the composer strip's do: Tasks' tabs in one capsule and its
/// Find and View Options each on a circle, All notes' title and tags in one
/// capsule and its magnifier on a circle, an open search field, and
/// History's version switch. Where the controls are not glass (Reduce
/// Transparency, Craft) they take the opaque raised surface.
@MainActor
final class TopGlassTests: XCTestCase {
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    /// All notes' line, with its own focus state.
    private struct LibraryLine: View {
        let tags: [String]
        var searchShown = false
        @FocusState private var focused: Bool

        var body: some View {
            AtticNoteLibraryLine(title: "All notes", placeholder: "Search notes", query: .constant(""),
                                 searchShown: searchShown, fieldFocused: $focused,
                                 onBeginSearch: {}, onEndSearch: {}, tags: tags, activeTag: tags.first)
        }
    }

    /// Tasks' top line as the page builds it: the tabs' capsule, then Find
    /// and View Options on their circles, in one glass container.
    private struct TasksLine: View {
        var body: some View {
            AtticControlGroup {
                HStack(spacing: 0) {
                    AtticPageTabs(items: [.init(page: 0, title: "Now"), .init(page: 1, title: "Later"), .init(page: 2, title: "Done")],
                                  selection: .constant(0))
                        .atticTopLineCapsule()
                        .padding(.leading, AtticLayout.pageTabsX - AtticTopGlassMetrics.capsulePadding)
                    Spacer(minLength: AtticTopGlassMetrics.spacing)
                    AtticSmallButton(systemName: "magnifyingglass", label: "Find", quietIcon: true, floating: true) {}
                        .padding(.trailing, AtticTopGlassMetrics.spacing)
                    AtticMenuButton(systemName: "line.3.horizontal.decrease", label: "View Options", commands: { [] },
                                    showsDot: true, quietIcon: false, floating: true)
                        .padding(.trailing, AtticTopGlassMetrics.lineEndInset)
                }
            }
        }
    }

    private struct VersionSwitch: View {
        @State private var current = true
        var body: some View {
            NoteHistoryVersionSwitch(choices: [(true, "Current"), (false, "Oct 21, 9:41")], selection: $current)
        }
    }

    private func host<V: View>(_ content: V, _ design: AtticDesignContext, width: CGFloat = 300) -> (NSPanel, NSView) {
        let size = CGSize(width: width, height: 44)
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height).atticDesign(design))
        panel.contentView = view
        panel.orderFront(nil)
        panel.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        return (panel, view)
    }

    /// AppKit's backdrop layers (the glass the window server samples), with
    /// how many glass shapes each draws.
    private func backdrops(in view: NSView) -> [Int] {
        func shapes(_ layer: CALayer) -> Int {
            ("\(type(of: layer))".contains("SDFElement") ? 1 : 0) + (layer.sublayers ?? []).map(shapes).reduce(0, +)
        }
        func walk(_ layer: CALayer) -> [Int] {
            ("\(type(of: layer))".contains("Backdrop") ? [shapes(layer)] : []) + (layer.sublayers ?? []).flatMap(walk)
        }
        return view.layer.map(walk) ?? []
    }

    /// The top line's controls in every glass context, with how many glass
    /// shapes each must draw.
    private var specimens: [(String, AnyView, Int)] {
        [("Tasks' tabs, Find and View Options", AnyView(TasksLine()), 3),
         ("All notes alone", AnyView(LibraryLine(tags: [])), 2),
         ("All notes and its tags", AnyView(LibraryLine(tags: ["home", "work"])), 2),
         ("All notes' search field", AnyView(LibraryLine(tags: [], searchShown: true)), 1),
         ("Tasks' search field", AnyView(AtticTabsSearchField(placeholder: "Find", text: .constant(""), floating: true, onEscape: {})), 1),
         ("History's version switch", AnyView(VersionSwitch()), 1)]
    }

    func testTheTopLineTakesTheFloatingControlsMeasures() {
        XCTAssertEqual(AtticTopGlassMetrics.height, AtticControlSize.secondaryControl, "the secondary controls' height")
        XCTAssertLessThan(AtticTopGlassMetrics.height, AtticControlSize.headerControl, "a step under the corner buttons (owner, 2026-10-22)")
        // The search field, All notes' line and History's switch are
        // secondary controls too: 26 pt (owner, 2026-10-22, Top controls
        // on glass: B), not the corner buttons' 30.
        XCTAssertEqual(AtticTabsSearchField.height(floating: true), AtticControlSize.secondaryControl)
        XCTAssertEqual(AtticTabsSearchField.height(floating: false), AtticControlSize.smallHeight, "the find bar's field is unchanged")
        XCTAssertEqual(AtticNoteLibraryLine.height, AtticControlSize.secondaryControl)
        XCTAssertEqual(NoteHistoryVersionSwitch.height, AtticControlSize.secondaryControl)
        // The capsule's edge and the last circle's on the controls' line;
        // the labels stay on the content line (24 pt at the 16 pt chrome).
        let chrome = AtticStyle.chromeMinimumInset
        let pageEdge = AtticLayout.tasksPageEdge(chromeInset: chrome)
        XCTAssertEqual(pageEdge + AtticLayout.pageTabsX, chrome + AtticLayout.contentFromChrome, "the labels where they were")
        XCTAssertEqual(pageEdge + AtticLayout.pageTabsX - AtticTopGlassMetrics.capsulePadding, chrome, "the capsule's leading edge")
        XCTAssertEqual(pageEdge + AtticTopGlassMetrics.lineEndInset, chrome, "the last circle's trailing edge")
        XCTAssertEqual(AtticNoteMetrics.libraryPageEdge(chromeInset: chrome), pageEdge, "Notes' line on the same edges")
    }

    func testTheTopLinesControlsAreFloatingGlass() {
        for surface in PanelSurfaceStyle.allCases {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                for increaseContrast in [false, true] {
                    let design = AtticDesignContext(mode: mode, surface: surface, increaseContrast: increaseContrast)
                    guard design.effectiveControls == .liquidGlass else { continue }
                    for (name, view, count) in specimens {
                        let (panel, hosted) = host(view, design)
                        defer { panel.orderOut(nil); panel.close() }
                        let found = backdrops(in: hosted)
                        XCTAssertEqual(found.reduce(0, +), count, "\(name), \(surface) \(mode) contrast=\(increaseContrast): \(found)")
                        if count > 1 {
                            XCTAssertEqual(found.count, 1, "\(name): one glass container, one shape per control")
                        }
                    }
                }
            }
        }
    }

    func testWhereTheControlsAreNotGlassTheTopLineTakesTheirOpaqueSurface() throws {
        let opaque: [(String, AtticDesignContext)] = [
            ("Reduce Transparency", AtticDesignContext(reduceTransparency: true)),
            ("Reduce Transparency, Dark", AtticDesignContext(mode: .dark, reduceTransparency: true)),
            ("Craft (a Solid panel that is not key)", AtticDesignContext(controls: .craft)),
        ]
        for (name, design) in opaque {
            for (specimen, view, _) in specimens {
                let (panel, hosted) = host(view, design)
                defer { panel.orderOut(nil); panel.close() }
                XCTAssertTrue(backdrops(in: hosted).isEmpty, "\(name), \(specimen): no glass")
            }
            guard design.reduceTransparency else { continue }
            // The tabs' capsule, in its padding before "Now", and the last
            // circle, at its centre's height near its trailing edge, are opaque.
            let (panel, hosted) = host(TasksLine(), design)
            defer { panel.orderOut(nil); panel.close() }
            let rep = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / hosted.bounds.width
            let y = Int(hosted.bounds.midY * scale)
            let capsule = try XCTUnwrap(rep.colorAt(x: Int((AtticLayout.pageTabsX - AtticTopGlassMetrics.capsulePadding + 3) * scale), y: y))
            XCTAssertGreaterThan(capsule.alphaComponent, 0.99, "\(name): the tabs' capsule is the opaque raised surface (U-02)")
            let circleX = hosted.bounds.width - AtticTopGlassMetrics.lineEndInset - 4
            let circle = try XCTUnwrap(rep.colorAt(x: Int(circleX * scale), y: y))
            XCTAssertGreaterThan(circle.alphaComponent, 0.99, "\(name): View Options' circle is the opaque raised surface (U-02)")
        }
    }

    func testTheFindBarsFieldKeepsItsRecessedFill() {
        let (panel, hosted) = host(AtticTabsSearchField(placeholder: "Find in note", text: .constant(""), onEscape: {}),
                                   AtticDesignContext())
        defer { panel.orderOut(nil); panel.close() }
        XCTAssertTrue(backdrops(in: hosted).isEmpty, "on its own card: no glass of its own")
    }
}
