#if ATTIC_GLOSS_LAB
import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

/// Gloss lab (experimental preview only): what one resize write costs with
/// each static switch on, against all off. Counts only, no timing. The
/// surface is the live panel's own (`PanelShellSurface`) in an off-screen
/// panel of the invisible unit host.
@MainActor
final class GlossLabCountTests: XCTestCase {
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

    private var design: AtticDesignContext {
        var design = AtticDesignContext()
        design.mode = .light
        design.surface = .glass
        return design
    }

    private func spin(_ seconds: TimeInterval = 0.2) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func host(elevation: AtticPanelSurfaceElevation? = nil, tilesPage: Bool = false, smokedContent: Bool = false) -> (NSPanel, NSView) {
        let size = CGSize(width: 360, height: 560)
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // The panel's surface, and a wide glass control with the Edge
        // light that stretches with the panel (as the search field does).
        let content = VStack(spacing: 0) {
            Color.clear.frame(height: 16)
            Color.clear.frame(height: 32).frame(maxWidth: .infinity)
                .atticRaisedMaterial(cornerRadius: 16, interactive: false, edgeLight: true)
                .padding(.horizontal, 16)
            if tilesPage {
                // 14: a list of two groups, a heading and a row each, as
                // the Tasks lists mark theirs.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 24).frame(maxWidth: .infinity).glossTile("a", leads: true)
                    Color.clear.frame(height: 32).frame(maxWidth: .infinity).glossTile("a")
                    Color.clear.frame(height: 24).frame(maxWidth: .infinity).glossTile("b", leads: true)
                    Color.clear.frame(height: 32).frame(maxWidth: .infinity).glossTile("b")
                }
                .backgroundPreferenceValue(GlossTileBounds.self) { GlossTilesBackground(anchors: $0) }
            }
            Spacer()
        }
        // 14, Smoky in Light: the live panel's content modifier, under the
        // shell as there (only where a test asks for it).
        .modifier(GlossSmokedContent(tilesPage: smokedContent && tilesPage, theme: .original, contrast: .standard,
                                     palette: AtticPanelTheme.original.palette(for: ColorScheme.light)))
        .modifier(PanelShellSurface(cornerSize: 26, elevation: elevation, glossLabTilesPage: tilesPage))
        .environment(\.glossTilesGround, tilesPage)
        .atticDesign(design)
        let view = NSHostingView(rootView: content)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFront(nil)
        spin(0.5)
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        return (panel, view)
    }

    private struct Count: Equatable, CustomStringConvertible {
        var stage = 0, surface = 0, rim = 0, controlLight = 0, shadow = 0
        var description: String {
            "stage \(stage), surface layer \(surface), rim layer \(rim), control edge light \(controlLight), shadow layer \(shadow)"
        }
    }

    /// One resize write: the panel's size changes once, then one layout and
    /// display pass.
    private func oneResize(elevation: AtticPanelSurfaceElevation? = nil, _ configure: (GlossLab) -> Void) -> Count {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        configure(lab)
        let (panel, view) = host(elevation: elevation)
        defer { panel.orderOut(nil); panel.close() }
        spin()
        GlossLabCounters.reset()
        panel.setContentSize(CGSize(width: 380, height: 590))
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        spin()
        return Count(stage: GlossLabCounters.stageSurface, surface: GlossLabCounters.surfaceLayer,
                     rim: GlossLabCounters.rimLayer, controlLight: GlossLabCounters.controlEdgeLight,
                     shadow: GlossLabCounters.shadowLayer)
    }

    func testOneResizeWriteCountsPerSwitch() {
        let off = oneResize { _ in }
        var lines = ["all off: \(off)"]
        let switches: [(String, (GlossLab) -> Void)] = [
            ("1 rim fade", { $0.rimFade = true }),
            ("3 edge light", { $0.edgeLight = true }),
            ("4 inner edge", { $0.innerEdge = true }),
            ("3 edge light, all the way round", { $0.edgeLight = true; $0.edgeLightAround = true }),
            ("6 grain", { $0.grain = true }),
            ("10 one rim", { $0.oneRim = true }),
            ("11 neutral glass", { $0.neutralGlass = true }),
            ("11 neutral glass, controls too", { $0.neutralGlass = true; $0.neutralControls = true }),
            ("11 neutral glass with 1", { $0.neutralGlass = true; $0.rimFade = true }),
            ("12 clear body", { $0.clearBody = true }),
            ("12 clear body with 1 and 11", { $0.clearBody = true; $0.rimFade = true; $0.neutralGlass = true }),
            ("13 clear controls", { $0.clearControls = true }),
        ]
        // The presets without 9 or 10 (9 has its own tests; 10 reads the
        // control's size by design).
        let presets: [(String, (GlossLab) -> Void)] = GlossLab.presets.filter { $0.id != "livingLight" }.map { preset in
            ("preset \(preset.id)", { $0.apply(preset) })
        }
        for (name, configure) in switches + presets {
            let count = oneResize(configure)
            lines.append("\(name): \(count)")
            // The static switches add no body run of their own on a resize:
            // shapes and unit gradients re-path, nothing re-evaluates.
            if name != "10 one rim" {
                XCTAssertEqual(count, off, "\(name) adds body runs on one resize write")
            }
        }
        // Pass 2, with the panel's exterior shadow present (as the live
        // panel draws it), against all off with that shadow.
        let offShadow = oneResize(elevation: .light) { _ in }
        lines.append("all off, with the panel's shadow: \(offShadow)")
        let pass2: [(String, (GlossLab) -> Void)] = [
            ("2 clear band, ring beside", { $0.clearBand = true }),
            ("2 clear band, ring, one container", { $0.clearBand = true; $0.clearBandContainer = true }),
            ("2 clear band, stacked", { $0.clearBand = true; $0.clearBandMethod = .stacked }),
            ("2 clear band, stacked, one container", { $0.clearBand = true; $0.clearBandMethod = .stacked; $0.clearBandContainer = true }),
            ("7 shadow", { $0.glassShadow = true }),
            ("7 spill", { $0.glassSpill = true }),
            ("7 shadow and spill", { $0.glassShadow = true; $0.glassSpill = true }),
        ]
        for (name, configure) in pass2 {
            let count = oneResize(elevation: .light, configure)
            lines.append("\(name): \(count)")
            XCTAssertEqual(count, offShadow, "\(name) adds body runs on one resize write")
        }
        GlossLab.shared.allOff(); GlossLab.shared.resetSliders()
        let report = lines.joined(separator: "\n")
        print("GLOSS_LAB_COUNTS\n\(report)\nGLOSS_LAB_COUNTS_END")
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Flipping a switch live (as the owner does in the lab) re-runs only
    /// the layer that reads it, and flipping it back does the same.
    func testFlippingEachSwitchLiveRerunsOnlyItsLayer() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        let (panel, view) = host(elevation: .light)
        defer { panel.orderOut(nil); panel.close(); lab.allOff() }
        spin()
        typealias Read = () -> Int
        let cases: [(String, ReferenceWritableKeyPath<GlossLab, Bool>, Read)] = [
            ("1 rim fade", \.rimFade, { GlossLabCounters.stageSurface }),
            ("3 edge light", \.edgeLight, { GlossLabCounters.rimLayer }),
            ("4 inner edge", \.innerEdge, { GlossLabCounters.rimLayer }),
            ("6 grain", \.grain, { GlossLabCounters.surfaceLayer }),
            ("10 one rim", \.oneRim, { GlossLabCounters.controlEdgeLight }),
            ("2 clear band", \.clearBand, { GlossLabCounters.stageSurface }),
            ("7 shadow", \.glassShadow, { GlossLabCounters.shadowLayer }),
            ("7 spill", \.glassSpill, { GlossLabCounters.shadowLayer }),
            ("9 moving light", \.movingLight, { GlossLabCounters.rimLayer }),
            ("11 neutral glass", \.neutralGlass, { GlossLabCounters.stageSurface }),
            ("11 controls too", \.neutralControls, { GlossLabCounters.controlEdgeLight }),
            ("12 clear body", \.clearBody, { GlossLabCounters.stageSurface }),
            ("13 clear controls", \.clearControls, { GlossLabCounters.controlEdgeLight }),
        ]
        var lines: [String] = []
        for (name, key, read) in cases {
            for value in [true, false] {
                GlossLabCounters.reset()
                lab[keyPath: key] = value
                spin()
                view.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                let total = GlossLabCounters.stageSurface + GlossLabCounters.surfaceLayer + GlossLabCounters.rimLayer
                    + GlossLabCounters.controlEdgeLight + GlossLabCounters.shadowLayer
                lines.append("\(name) \(value ? "on" : "off"): own layer \(read()), all lab-touched bodies \(total)")
                XCTAssertGreaterThanOrEqual(read(), 1, "\(name) \(value ? "on" : "off") did not re-run its layer")
                XCTAssertEqual(total, read(), "\(name) re-ran more than its own layer")
            }
        }
        print("GLOSS_LAB_FLIPS\n\(lines.joined(separator: "\n"))\nGLOSS_LAB_FLIPS_END")
    }

    /// 14 (Tiles), on the page that has tiles: flipping it re-runs the
    /// panel's surface, the tiles' own layer and each control there once
    /// (a control takes the tiles' dim); the rim,
    /// grain and shadow layers are left out while it is on; and one resize
    /// write with it on runs no more of the shell's bodies than with it
    /// off, and the tiles' layer a bounded number of times.
    func testTilesFlipAndOneResizeWrite() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        let (panel, view) = host(elevation: .light, tilesPage: true)
        defer { panel.orderOut(nil); panel.close(); lab.allOff() }
        spin()
        var size = CGSize(width: 380, height: 590)
        func resize() -> (Count, Int) {
            GlossLabCounters.reset()
            panel.setContentSize(size)
            size.width += 20; size.height += 30
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            spin()
            return (bodies(), GlossLabCounters.tilesLayer)
        }
        let (off, offTiles) = resize()
        var lines = ["14 off, one resize write: \(off), tiles layer \(offTiles)"]

        GlossLabCounters.reset()
        lab.tiles = true
        spin()
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let turnedOn = bodies(), turnedOnTiles = GlossLabCounters.tilesLayer
        lines.append("14 on: \(turnedOn), tiles layer \(turnedOnTiles)")
        XCTAssertGreaterThanOrEqual(turnedOn.stage, 1, "14 on did not re-run the panel's surface")
        XCTAssertGreaterThanOrEqual(turnedOnTiles, 1, "14 on did not run the tiles' layer")
        // The host's one control takes the tiles' dim, so it runs once.
        XCTAssertLessThanOrEqual(turnedOn.controlLight, 1, "14 on ran the control more than once")
        XCTAssertEqual(turnedOn.rim + turnedOn.surface + turnedOn.shadow, 0, "14 on ran a layer it leaves out")

        let (on, onTiles) = resize()
        lines.append("14 on, one resize write: \(on), tiles layer \(onTiles)")
        XCTAssertLessThanOrEqual(on.stage, off.stage); XCTAssertLessThanOrEqual(on.controlLight, off.controlLight)
        XCTAssertLessThanOrEqual(on.rim, off.rim); XCTAssertLessThanOrEqual(on.surface, off.surface)
        XCTAssertLessThanOrEqual(on.shadow, off.shadow)
        // The tiles follow the list's new width: their layer runs for the
        // write, and not in a loop.
        XCTAssertLessThanOrEqual(onTiles, 3, "the tiles' layer ran \(onTiles) times on one resize write")

        GlossLabCounters.reset()
        lab.tiles = false
        spin()
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let turnedOff = bodies()
        lines.append("14 off again: \(turnedOff), tiles layer \(GlossLabCounters.tilesLayer)")
        XCTAssertGreaterThanOrEqual(turnedOff.stage, 1, "14 off did not re-run the panel's surface")
        XCTAssertLessThanOrEqual(turnedOff.controlLight, 1, "14 off ran the control more than once")
        print("GLOSS_LAB_TILES\n\(lines.joined(separator: "\n"))\nGLOSS_LAB_TILES_END")
    }

    /// 14's second round (23 Nov): with Tiles, Sheet behind, Smoky in Light
    /// and the tile edge on, the panel's own surface, rim and shadow are
    /// back behind the tiles; one resize write runs no more of the shell's
    /// bodies than with every switch off, and the tiles' layer a bounded
    /// number of times.
    func testTilesSheetSmokyEdgeOneResizeWrite() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        let (panel, view) = host(elevation: .light, tilesPage: true, smokedContent: true)
        defer { panel.orderOut(nil); panel.close(); lab.allOff(); lab.resetSliders() }
        spin()
        var size = CGSize(width: 380, height: 590)
        func resize() -> (Count, Int) {
            GlossLabCounters.reset()
            panel.setContentSize(size)
            size.width += 20; size.height += 30
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            spin()
            return (bodies(), GlossLabCounters.tilesLayer)
        }
        let (off, offTiles) = resize()
        var lines = ["all off, one resize write: \(off), tiles layer \(offTiles)"]

        GlossLabCounters.reset()
        lab.tiles = true; lab.tilesSheet = true; lab.tilesSmoky = true; lab.tilesEdge = 0.5
        spin()
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let turnedOn = bodies(), turnedOnTiles = GlossLabCounters.tilesLayer
        lines.append("14 + sheet + smoky + edge on: \(turnedOn), tiles layer \(turnedOnTiles)")
        XCTAssertGreaterThanOrEqual(turnedOnTiles, 1, "the switches on did not run the tiles' layer")

        let (on, onTiles) = resize()
        lines.append("14 + sheet + smoky + edge on, one resize write: \(on), tiles layer \(onTiles)")
        XCTAssertLessThanOrEqual(on.stage, off.stage); XCTAssertLessThanOrEqual(on.controlLight, off.controlLight)
        XCTAssertLessThanOrEqual(on.rim, off.rim); XCTAssertLessThanOrEqual(on.surface, off.surface)
        XCTAssertLessThanOrEqual(on.shadow, off.shadow)
        XCTAssertLessThanOrEqual(onTiles, 3, "the tiles' layer ran \(onTiles) times on one resize write")
        // Sheet behind keeps the panel's own surface, rim and shadow.
        XCTAssertFalse(GlossTiles.replacePanel(tilesPage: true, design: design))
        XCTAssertTrue(GlossTiles.smoked(tilesPage: true, design: design))
        print("GLOSS_LAB_TILES2\n\(lines.joined(separator: "\n"))\nGLOSS_LAB_TILES2_END")
    }

    /// 14's second round: Smoky in Light is Light only and the tiles' page
    /// only; its dim is black at Smoke · Light; with Sheet behind a
    /// control wears the dim only on a smoked page.
    func testSmokyIsLightAndTilesPageOnly() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        defer { lab.allOff(); lab.resetSliders() }
        var dark = design; dark.mode = .dark
        lab.tilesSmoky = true
        XCTAssertFalse(GlossTiles.smoked(tilesPage: true, design: design), "smoked with Tiles off")
        lab.tiles = true
        XCTAssertTrue(GlossTiles.smoked(tilesPage: true, design: design))
        XCTAssertFalse(GlossTiles.smoked(tilesPage: false, design: design), "smoked off the tiles' page")
        XCTAssertFalse(GlossTiles.smoked(tilesPage: true, design: dark), "smoked in Dark")
        XCTAssertEqual(GlossTiles.dim(design: design, smoked: true), Color.black.opacity(0.22))
        XCTAssertEqual(GlossTiles.dim(design: design, smoked: false), Color.white.opacity(0.55))
        XCTAssertEqual(GlossTiles.dim(design: dark, smoked: false), Color.black.opacity(0.50))
        XCTAssertNotNil(GlossTiles.controlDim(ground: true, smoked: false, design: design), "no panel behind: a control keeps the dim")
        lab.tilesSheet = true
        XCTAssertNil(GlossTiles.controlDim(ground: true, smoked: false, design: design), "the panel is behind: no dim")
        XCTAssertEqual(GlossTiles.controlDim(ground: true, smoked: true, design: design), Color.black.opacity(0.22))
        XCTAssertNil(GlossTiles.controlDim(ground: false, smoked: true, design: design))
    }

    /// 14 on a page without tiles (every page but Tasks): the switch is
    /// not read there, so flipping it re-runs nothing of the shell.
    func testTilesAreNotReadOffTheirPage() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        let (panel, view) = host(elevation: .light)
        defer { panel.orderOut(nil); panel.close(); lab.allOff() }
        spin()
        for value in [true, false] {
            GlossLabCounters.reset()
            lab.tiles = value
            spin()
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            XCTAssertEqual(bodies(), Count(), "14 \(value ? "on" : "off") re-ran the shell off its page")
        }
    }

    /// 14's second round: with Tiles off, Sheet behind, Smoky in Light and
    /// the tile edge are not read, on the tiles' page or off it.
    func testSecondRoundSwitchesAreNotReadWithTilesOff() {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        for tilesPage in [true, false] {
            let (panel, view) = host(elevation: .light, tilesPage: tilesPage, smokedContent: true)
            defer { panel.orderOut(nil); panel.close(); lab.allOff(); lab.resetSliders() }
            spin()
            for value in [true, false] {
                GlossLabCounters.reset()
                lab.tilesSheet = value; lab.tilesSmoky = value; lab.tilesEdge = value ? 1 : 0.5
                spin()
                view.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                XCTAssertEqual(bodies(), Count(), "second-round switches \(value ? "on" : "off") re-ran the shell with Tiles off (tiles page \(tilesPage))")
                XCTAssertEqual(GlossLabCounters.tilesLayer, 0, "the tiles' layer ran with Tiles off (tiles page \(tilesPage))")
            }
        }
    }

    private func movingLightView(in root: NSView) -> GlossMovingEdgeLightView? {
        if let view = root as? GlossMovingEdgeLightView { return view }
        for sub in root.subviews { if let found = movingLightView(in: sub) { return found } }
        return nil
    }

    private struct Moving: CustomStringConvertible {
        var ticks = 0, writes = 0, paths = 0, updates = 0
        @MainActor static func read() -> Moving {
            Moving(ticks: GlossLabCounters.movingTicks, writes: GlossLabCounters.movingWrites,
                   paths: GlossLabCounters.movingPathBuilds, updates: GlossLabCounters.movingUpdates)
        }
        var description: String { "refreshes \(ticks), gradient writes \(writes), path builds \(paths), representable updates \(updates)" }
    }

    private func bodies() -> Count {
        Count(stage: GlossLabCounters.stageSurface, surface: GlossLabCounters.surfaceLayer, rim: GlossLabCounters.rimLayer,
              controlLight: GlossLabCounters.controlEdgeLight, shadow: GlossLabCounters.shadowLayer)
    }

    /// 9, one resize write: no body run beyond all off, the representable is
    /// not updated, and the mask path is built once (the stroke follows the
    /// new size). Nothing else is written.
    func testMovingLightOneResizeWrite() {
        let off = oneResize { _ in }
        var lines = ["all off: \(off), \(Moving.read())"]
        for (name, configure) in [("9 moving light", { (lab: GlossLab) in lab.movingLight = true }),
                                  ("9 with 3", { (lab: GlossLab) in lab.movingLight = true; lab.edgeLight = true })] {
            let count = oneResize(configure)
            let moving = Moving.read()
            lines.append("\(name): \(count), \(moving)")
            XCTAssertEqual(count, off, "\(name) adds body runs on one resize write")
            XCTAssertEqual(moving.updates, 0, "a resize updated the representable")
            XCTAssertEqual(moving.paths, 1, "the stroke's path is built once per resize")
            XCTAssertEqual(moving.writes, 0, "a resize rewrote the gradient's points")
        }
        GlossLab.shared.allOff(); GlossLab.shared.resetSliders()
        print("GLOSS_LAB_MOVING_RESIZE\n\(lines.joined(separator: "\n"))\nGLOSS_LAB_MOVING_RESIZE_END")
    }

    /// 9, pointer moves: each display refresh after a move writes the
    /// gradient's two points once and runs no SwiftUI body; a refresh with
    /// the pointer still writes nothing. With 9 off there is no view at all.
    func testMovingLightPointerMovesRunNoBody() throws {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        // The machine's own Reduce Motion must not decide this test.
        AtticMotionPreference.systemReduceMotionOverride = false
        defer {
            lab.allOff(); GlossMovingEdgeLightView.pointerForTesting = nil
            AtticMotionPreference.systemReduceMotionOverride = nil
        }
        do {
            let (panel, view) = host()
            defer { panel.orderOut(nil); panel.close() }
            XCTAssertNil(movingLightView(in: view), "with 9 off there is no moving light view")
        }
        lab.movingLight = true
        lab.edgeLight = true
        let (panel, view) = host()
        defer { panel.orderOut(nil); panel.close() }
        spin()
        let light = try XCTUnwrap(movingLightView(in: view))
        let frame = panel.frame
        // The pointer at rest in the middle: idea 3's axis, top to bottom.
        GlossMovingEdgeLightView.pointerForTesting = CGPoint(x: frame.midX, y: frame.midY)
        light.step(dt: 1)
        let rest = light.gradientPoints
        XCTAssertEqual(rest.start.x, 0.5, accuracy: 1e-6); XCTAssertEqual(rest.end.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(abs(rest.end.y - rest.start.y), 1, accuracy: 1e-6)
        GlossLabCounters.reset()
        let moves = 24
        var last = rest
        for i in 0..<moves {
            let angle = Double(i) / Double(moves) * 2 * .pi
            GlossMovingEdgeLightView.pointerForTesting = CGPoint(x: frame.midX + cos(angle) * frame.width * 0.45,
                                                                 y: frame.midY + sin(angle) * frame.height * 0.45)
            light.step(dt: 1.0 / 60)
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            let now = light.gradientPoints
            XCTAssertTrue(now.start != last.start || now.end != last.end, "move \(i) did not move the light")
            last = now
        }
        let moved = Moving.read(), movedBodies = bodies()
        // Refreshes with the pointer still: it eases in, then stops writing.
        GlossLabCounters.reset()
        for _ in 0..<120 { light.step(dt: 1.0 / 60) }
        let settling = Moving.read()
        GlossLabCounters.reset()
        for _ in 0..<30 { light.step(dt: 1.0 / 60) }
        let still = Moving.read(), stillBodies = bodies()
        let report = """
        \(moves) pointer moves, one refresh each: \(moved); bodies \(movedBodies)
        120 refreshes after the last move: \(settling)
        30 more refreshes, pointer still: \(still); bodies \(stillBodies)
        """
        print("GLOSS_LAB_MOVING_POINTER\n\(report)\nGLOSS_LAB_MOVING_POINTER_END")
        XCTAssertEqual(movedBodies, Count(), "a pointer move ran a SwiftUI body")
        XCTAssertEqual(moved.writes, moves, "one gradient write per refresh after a move")
        XCTAssertEqual(moved.updates, 0); XCTAssertEqual(moved.paths, 0)
        XCTAssertLessThanOrEqual(settling.writes, 120)
        XCTAssertEqual(still.writes, 0, "a still pointer still writes")
        XCTAssertEqual(stillBodies, Count())
        // Tilt: a pointer on the left leans the lit end to the left.
        let left = GlossMovingEdgeLightView.points(pointer: CGPoint(x: -1, y: 0), tilt: 10, reach: 0)
        XCTAssertLessThan(left.start.x, 0.5); XCTAssertGreaterThan(left.end.x, 0.5)
        XCTAssertEqual(left.start.y, 0.5 - cos(10 * .pi / 180) / 2, accuracy: 1e-9)
    }

    /// 9 under Reduce Motion: the link does not run, a refresh writes
    /// nothing, and the light goes back to rest (idea 3's axis).
    func testMovingLightRestsUnderReduceMotion() throws {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        lab.movingLight = true
        let (panel, view) = host()
        defer {
            panel.orderOut(nil); panel.close(); lab.allOff()
            GlossMovingEdgeLightView.pointerForTesting = nil
            AtticMotionPreference.systemReduceMotionOverride = nil
        }
        AtticMotionPreference.systemReduceMotionOverride = false
        spin()
        let light = try XCTUnwrap(movingLightView(in: view))
        GlossMovingEdgeLightView.pointerForTesting = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        light.step(dt: 1)
        XCTAssertNotEqual(light.current, .zero, "the light did not follow the pointer")
        AtticMotionPreference.systemReduceMotionOverride = true
        light.updateRunning()
        XCTAssertFalse(light.isRunning)
        XCTAssertEqual(light.current, .zero, "the light did not go back to rest")
        let rest = light.gradientPoints
        XCTAssertEqual(rest.start.x, 0.5, accuracy: 1e-6)
        GlossLabCounters.reset()
        for _ in 0..<10 { light.step(dt: 1.0 / 60) }
        XCTAssertEqual(GlossLabCounters.movingWrites, 0, "a refresh under Reduce Motion wrote")
        XCTAssertEqual(light.current, .zero)
        XCTAssertFalse(light.isRunning)
    }

    /// Idea 1's mask is a linear alpha ramp: step k leaves alpha (k + 1) / n.
    func testRimFadeStepsComposeToALinearRamp() {
        for width in [1.0, 9.0, 16.0] {
            let n = GlossRimFadeMask.steps(width: width)
            var alpha = 0.0
            for k in 0..<n {
                let a = GlossRimFadeMask.alpha(step: k, of: n)
                alpha = alpha + a * (1 - alpha)
                XCTAssertEqual(alpha, Double(k + 1) / Double(n), accuracy: 1e-9)
            }
            XCTAssertEqual(alpha, 1, accuracy: 1e-9)
        }
        XCTAssertEqual(GlossRimFadeMask.steps(width: 0), 0)
    }

    /// Idea 7's soft shadow and spill stay inside the window's margin by
    /// the trunk's own extent rule (radius x 2 + drop).
    func testShadowExtentIsHeldInsideTheMargin() {
        for margin in [AtticStyle.panelElevationMargin, AtticStyle.dockedPanelMargin] {
            for wanted in stride(from: 4.0, through: 18.0, by: 1.0) {
                for drop in stride(from: 0.0, through: 10.0, by: 1.0) {
                    let r = GlossLabPanelShadow.softRadius(wanted, drop: drop, margin: margin)
                    XCTAssertLessThanOrEqual(r * 2 + drop, margin + 1e-9)
                    XCTAssertLessThanOrEqual(r, wanted)
                }
            }
        }
        let spill = GlossLabPanelShadow.softRadius(GlossLabPanelShadow.spillRadius, drop: GlossLabPanelShadow.spillDrop,
                                                   margin: AtticStyle.panelElevationMargin)
        XCTAssertEqual(spill, GlossLabPanelShadow.spillRadius, "the spill fits the smaller margin whole")
        // The starting values fit the docked margin whole (15 x 2 + 6 = 36).
        XCTAssertEqual(GlossLabPanelShadow.softRadius(15, drop: 6, margin: AtticStyle.dockedPanelMargin), 15)
        XCTAssertEqual(GlossLabPanelShadow.softRadius(15, drop: 6, margin: AtticStyle.panelElevationMargin), 11)
    }
}
#endif

#if ATTIC_GLOSS_LAB
@MainActor
final class GlossLabValuesTests: XCTestCase {
    private final class CountingDefaults: UserDefaults {
        var writes: [String] = []
        override func set(_ value: Any?, forKey defaultName: String) {
            writes.append(defaultName)
            super.set(value, forKey: defaultName)
        }
    }

    /// Reading the stored values never writes them back (on 22 Nov a launch
    /// argument read this way was saved for good), and a change is kept.
    func testLoadingNeverWritesAndChangesPersist() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.grain")
        defaults.set(3.0, forKey: "GlossLab.grainPercent")
        defaults.writes = []
        let loaded = GlossLab(defaults: defaults)
        XCTAssertTrue(loaded.grain)
        XCTAssertEqual(loaded.grainPercent, 3)
        XCTAssertEqual(defaults.writes, [], "loading wrote values back")
        loaded.edgeLight = true
        XCTAssertEqual(defaults.writes, ["GlossLab.edgeLight"])
        XCTAssertTrue(GlossLab(defaults: defaults).edgeLight, "a change is kept")
    }

    /// Pass 2's switches and values load, are written down by Copy values,
    /// and All off and Reset sliders reach them.
    func testPassTwoValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.clearBand")
        defaults.set("stacked", forKey: "GlossLab.clearBandMethod")
        defaults.set(true, forKey: "GlossLab.clearBandContainer")
        defaults.set(10.0, forKey: "GlossLab.clearBandWidth")
        defaults.set(true, forKey: "GlossLab.glassShadow")
        defaults.set(true, forKey: "GlossLab.glassSpill")
        defaults.set(9.0, forKey: "GlossLab.shadowSoftRadius")
        defaults.set(0.3, forKey: "GlossLab.spillStrength")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.clearBand); XCTAssertTrue(lab.glassShadow); XCTAssertTrue(lab.glassSpill)
        XCTAssertEqual(lab.clearBandMethod, .stacked); XCTAssertTrue(lab.clearBandContainer)
        XCTAssertEqual(lab.clearBandWidth, 10); XCTAssertEqual(lab.shadowSoftRadius, 9); XCTAssertEqual(lab.spillStrength, 0.3)
        let text = lab.valuesText(app: Self.app(mode: "Dark"))
        XCTAssertTrue(text.contains("2 Refracting rim (a band of Clear glass): on, width 10.00 pt, Stacked, one container: on"), text)
        XCTAssertTrue(text.contains("7 A shadow that fits glass: on"), text)
        XCTAssertTrue(text.contains("radius 9.00 pt"), text)
        XCTAssertTrue(text.contains("7 Spill of light under the bottom edge: on, 0.30"), text)
        lab.allOff()
        XCTAssertFalse(lab.clearBand); XCTAssertFalse(lab.glassShadow); XCTAssertFalse(lab.glassSpill)
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(lab.clearBandMethod, fresh.clearBandMethod); XCTAssertEqual(lab.clearBandContainer, fresh.clearBandContainer)
        XCTAssertEqual(lab.clearBandWidth, fresh.clearBandWidth); XCTAssertEqual(lab.shadowSoftRadius, fresh.shadowSoftRadius)
        XCTAssertEqual(lab.spillStrength, fresh.spillStrength)
        XCTAssertFalse(fresh.clearBand || fresh.glassShadow || fresh.glassSpill, "pass 2 starts off")
    }

    private static func app(mode: String) -> GlossLab.AppValues {
        GlossLab.AppValues(mode: mode, surface: "Glass", palette: "Original", tint: "Subtle", tintLength: 0.6, brightenGlass: false)
    }

    /// 23 Nov round: 5 (Light from the top) is gone from the values and
    /// from Copy values, and an old stored key of it changes nothing.
    func testLightFromTheTopIsGone() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.topLight")
        defaults.set(0.6, forKey: "GlossLab.topLightLight")
        defaults.writes = []
        let lab = GlossLab(defaults: defaults)
        XCTAssertEqual(lab.labLines, GlossLab(defaults: nil).labLines, "a stored switch 5 still changes the lab")
        XCTAssertEqual(defaults.writes, [])
        XCTAssertFalse(lab.valuesText(app: Self.app(mode: "Light")).contains("Light from the top"))
    }

    /// 23 Nov round: the rim's width starts at 14 pt; 3's "All the way
    /// round" and 13 (Clear glass controls) load, are written down by Copy
    /// values, and All off reaches them.
    func testRoundOf23NovValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GlossLab(defaults: nil).clearBandWidth, 14)
        defaults.set(true, forKey: "GlossLab.edgeLight")
        defaults.set(true, forKey: "GlossLab.edgeLightAround")
        defaults.set(true, forKey: "GlossLab.clearControls")
        defaults.set(32.0, forKey: "GlossLab.clearBandWidth")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.edgeLightAround); XCTAssertTrue(lab.clearControls); XCTAssertEqual(lab.clearBandWidth, 32)
        let text = lab.valuesText(app: Self.app(mode: "Dark"))
        XCTAssertTrue(text.contains("all the way round: on"), text)
        XCTAssertTrue(text.contains("13 Clear glass controls: on"), text)
        XCTAssertTrue(text.contains("width 32.00 pt"), text)
        XCTAssertTrue(text.contains("Preset: none (own values)"), text)
        lab.allOff()
        XCTAssertFalse(lab.edgeLightAround); XCTAssertFalse(lab.clearControls)
        let fresh = GlossLab(defaults: nil)
        XCTAssertFalse(fresh.edgeLightAround || fresh.clearControls, "the round's switches start off")
        // The second run's stops: none at the top, rising to the bottom.
        let stops = GlossLabPanelRimLayer.aroundStops(strength: 1)
        XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted())
        XCTAssertEqual(stops.last?.location, 1)
    }

    /// Presets: distinct ids, each one the same look whatever was set
    /// before it, recognised as the current one, and lost on a change.
    func testPresetsAreDistinctRepeatableAndRecognised() {
        let presets = GlossLab.presets
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(presets.first?.id, "today")
        var looks: [String] = []
        for preset in presets {
            let clean = GlossLab(defaults: nil)
            clean.apply(preset)
            let dirty = GlossLab(defaults: nil)
            for other in presets { dirty.apply(other) }
            dirty.grainPercent = 4; dirty.clearBandMethod = .stacked; dirty.neutralControls = true
            dirty.apply(preset)
            XCTAssertEqual(dirty.labLines, clean.labLines, "\(preset.id) depends on what was set before it")
            XCTAssertEqual(clean.currentPreset?.id, preset.id)
            looks.append(clean.labLines)
        }
        XCTAssertEqual(Set(looks).count, presets.count, "two presets are the same look")
        XCTAssertEqual(looks.first, GlossLab(defaults: nil).labLines, "Today's panel is everything off at the starting values")
        let lab = GlossLab(defaults: nil)
        lab.apply(presets[1])
        lab.clearBodyFillLight += 5
        XCTAssertNil(lab.currentPreset, "a changed slider still reads as the preset")
        // No preset turns 2 on under 12 (the rim would draw nothing).
        for preset in presets {
            let lab = GlossLab(defaults: nil)
            lab.apply(preset)
            XCTAssertFalse(lab.clearBand && lab.clearBody, "\(preset.id) sets the rim under a Clear body")
        }
    }

    /// A preset applied by a button is saved; one shown by launch argument
    /// is not.
    func testPresetIsSavedByApplyAndNotByLaunchArgument() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("banner", forKey: "GlossLab.preset")
        defaults.writes = []
        let shown = GlossLab(defaults: defaults)
        XCTAssertTrue(shown.clearBody); XCTAssertTrue(shown.neutralGlass)
        XCTAssertEqual(shown.currentPreset?.id, "banner")
        XCTAssertEqual(defaults.writes, [], "a preset shown by launch argument was saved")
        defaults.removeObject(forKey: "GlossLab.preset")
        let lab = GlossLab(defaults: defaults)
        XCTAssertNil(lab.currentPreset.flatMap { $0.id == "today" ? nil : $0 })
        lab.apply(try XCTUnwrap(GlossLab.presets.first { $0.id == "refractingRim" }))
        let again = GlossLab(defaults: defaults)
        XCTAssertEqual(again.currentPreset?.id, "refractingRim", "an applied preset is kept")
        // The preset starts at 6 pt since 23 Nov (owner: "Yes, 6 pt"; it was 16).
        XCTAssertTrue(again.clearBand); XCTAssertEqual(again.clearBandWidth, 6)
    }

    /// Fix round 2: the backdrop follows the panel's visibility, not only
    /// its frame. The panel hides with orderOut and keeps its frame.
    func testBackdropHidesAndReturnsWithThePanel() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let panel = CGRect(x: 1100, y: 300, width: 380, height: 640)
        let shown = GlossLabWindows.backdropFrame(panelFrame: panel, panelVisible: true, screenFrame: screen)
        XCTAssertEqual(shown, panel.insetBy(dx: -220, dy: -220).intersection(screen))
        XCTAssertNil(GlossLabWindows.backdropFrame(panelFrame: panel, panelVisible: false, screenFrame: screen),
                     "same frame, panel hidden: the backdrop must leave the screen")
        XCTAssertEqual(GlossLabWindows.backdropFrame(panelFrame: panel, panelVisible: true, screenFrame: screen), shown,
                       "the panel back: the backdrop returns to the same place")
        XCTAssertNil(GlossLabWindows.backdropFrame(panelFrame: nil, panelVisible: false, screenFrame: screen), "no panel, no backdrop")
    }

    /// Fix round 4: Copy values writes down the app's own glass settings,
    /// so a pick can be rebuilt from the text alone.
    func testCopyValuesIncludesTheAppGlassSettings() {
        let lab = GlossLab(defaults: nil)
        let text = lab.valuesText(app: GlossLab.AppValues(mode: "Dark", surface: "Frosted", palette: "Sea Glass",
                                                          tint: "Vivid", tintLength: 0.45, brightenGlass: true))
        for line in ["Mode: Dark", "Surface: Frosted", "Palette: Sea Glass", "Tint: Vivid, length 45 %", "Brighten glass: on"] {
            XCTAssertTrue(text.contains(line), "missing \(line):\n\(text)")
        }
    }

    /// Idea 11's switches and amount load, are written down by Copy
    /// values, and All off and Reset sliders reach them.
    func testNeutralGlassValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.neutralGlass")
        defaults.set(true, forKey: "GlossLab.neutralControls")
        defaults.set(85.0, forKey: "GlossLab.neutralGlassAmount")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.neutralGlass); XCTAssertTrue(lab.neutralControls); XCTAssertEqual(lab.neutralGlassAmount, 85)
        XCTAssertEqual(GlossNeutralGlass<Rectangle>.amount(lab), 0.85)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("11 Neutral glass: on, amount 85.00 %, controls too: on"), text)
        lab.allOff()
        XCTAssertFalse(lab.neutralGlass); XCTAssertFalse(lab.neutralControls)
        XCTAssertNil(GlossNeutralGlass<Rectangle>.amount(lab), "off draws nothing")
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(lab.neutralGlassAmount, fresh.neutralGlassAmount)
        XCTAssertEqual(fresh.neutralGlassAmount, 60)
        XCTAssertFalse(fresh.neutralGlass || fresh.neutralControls, "11 starts off")
    }

    /// Idea 12's switch and fills load, are written down by Copy values,
    /// and All off and Reset sliders reach them. The fill follows the mode.
    func testClearBodyValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.clearBody")
        defaults.set(30.0, forKey: "GlossLab.clearBodyFillLight")
        defaults.set(70.0, forKey: "GlossLab.clearBodyFillDark")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.clearBody)
        XCTAssertEqual(GlossClearBody.fill(lab, dark: false), 0.30)
        XCTAssertEqual(GlossClearBody.fill(lab, dark: true), 0.70)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("12 Clear glass body: on, Light white fill 30.00 %, Dark black fill 70.00 %"), text)
        lab.allOff()
        XCTAssertFalse(lab.clearBody)
        XCTAssertNil(GlossClearBody.fill(lab, dark: false), "off keeps Regular glass and draws no fill")
        XCTAssertNil(GlossClearBody.fill(lab, dark: true))
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(lab.clearBodyFillLight, fresh.clearBodyFillLight)
        XCTAssertEqual(lab.clearBodyFillDark, fresh.clearBodyFillDark)
        XCTAssertEqual(fresh.clearBodyFillLight, 15); XCTAssertEqual(fresh.clearBodyFillDark, 15)
        XCTAssertFalse(fresh.clearBody, "12 starts off")
    }

    /// Pass 3's switch and values load, are written down by Copy values,
    /// and All off and Reset sliders reach them.
    func testPassThreeValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.movingLight")
        defaults.set(20.0, forKey: "GlossLab.movingLightTilt")
        defaults.set(0.15, forKey: "GlossLab.movingLightReach")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.movingLight); XCTAssertEqual(lab.movingLightTilt, 20); XCTAssertEqual(lab.movingLightReach, 0.15)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("9 Highlights that move: on, tilt 20.00 deg, reach 0.15"), text)
        lab.allOff()
        XCTAssertFalse(lab.movingLight)
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(lab.movingLightTilt, fresh.movingLightTilt); XCTAssertEqual(lab.movingLightReach, fresh.movingLightReach)
        XCTAssertFalse(fresh.movingLight, "pass 3 starts off")
    }

    /// 14 (Tiles, 23 Nov): the switch and its values load, are written
    /// down by Copy values, and All off and Reset sliders reach them.
    func testTilesValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.tiles")
        defaults.set(55.0, forKey: "GlossLab.tilesDimLight")
        defaults.set(20.0, forKey: "GlossLab.tilesDimDark")
        defaults.set(22.0, forKey: "GlossLab.tilesCorner")
        defaults.set(12.0, forKey: "GlossLab.tilesGap")
        defaults.set(10.0, forKey: "GlossLab.tilesPanelLight")
        defaults.set(25.0, forKey: "GlossLab.tilesPanelDark")
        defaults.set(0.3, forKey: "GlossLab.tilesShadow")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.tiles)
        XCTAssertEqual(lab.tilesDimLight, 55); XCTAssertEqual(lab.tilesDimDark, 20)
        XCTAssertEqual(lab.tilesCorner, 22); XCTAssertEqual(lab.tilesGap, 12)
        XCTAssertEqual(lab.tilesPanelLight, 10); XCTAssertEqual(lab.tilesPanelDark, 25)
        XCTAssertEqual(lab.tilesShadow, 0.3)
        let text = lab.valuesText(app: Self.app(mode: "Dark"))
        XCTAssertTrue(text.contains("14 Tiles (each group of tasks on its own Clear glass): on, dim Light 55.00 % Dark 20.00 %, corner 22.00 pt, gap 12.00 pt, panel behind Light 10.00 % Dark 25.00 %, shadow 0.30"), text)
        lab.allOff()
        XCTAssertFalse(lab.tiles)
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(lab.labLines, fresh.labLines)
        XCTAssertFalse(fresh.tiles, "14 starts off")
        XCTAssertEqual(GlossLab(defaults: defaults).labLines, fresh.labLines, "All off and Reset sliders were not saved")
    }

    /// 14: a tile is the union of its members' frames, pulled in at the
    /// sides; tiles come top to bottom; empty members and tiles are left out.
    func testTileFramesAreTheUnionPerKey() {
        let frames = GlossTiles.frames([
            "b": [CGRect(x: 0, y: 100, width: 300, height: 24), CGRect(x: 0, y: 124, width: 300, height: 32)],
            "a": [CGRect(x: 0, y: 32, width: 300, height: 32), CGRect(x: 0, y: 8, width: 300, height: 24), .zero],
            "gone": [CGRect(x: 0, y: 200, width: 300, height: 0)],
            "thin": [CGRect(x: 0, y: 300, width: 6, height: 32)],
        ], sideInset: 4)
        XCTAssertEqual(frames.map(\.key), ["a", "b"])
        XCTAssertEqual(frames.first?.frame, CGRect(x: 4, y: 8, width: 292, height: 56))
        XCTAssertEqual(frames.last?.frame, CGRect(x: 4, y: 100, width: 292, height: 56))
        XCTAssertTrue(GlossTiles.frames([:], sideInset: 4).isEmpty)
    }

    /// 23 Nov, the owner on the Control Centre preset ("It doesn't" feel
    /// like the real one): it now carries a dim under the text and none of
    /// our drawn lines, and a second preset puts the tiles on with no
    /// glass body under them.
    func testControlCentrePresetsOf23Nov() throws {
        let one = GlossLab(defaults: nil)
        one.apply(try XCTUnwrap(GlossLab.presets.first { $0.id == "controlCentre" }))
        XCTAssertTrue(one.clearBody); XCTAssertTrue(one.clearControls)
        XCTAssertEqual(one.clearBodyFillDark, 35)
        XCTAssertFalse(one.rimFade || one.edgeLight || one.edgeLightAround || one.innerEdge, "a drawn line is still on")
        XCTAssertFalse(one.tiles)
        let tiles = GlossLab(defaults: nil)
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "controlCentreTiles" })
        tiles.apply(preset)
        // Second round, 23 Nov (brief item 5): the preset no longer sets
        // Dark (it was `true`); the mode is the app's own.
        XCTAssertNil(preset.dark)
        XCTAssertTrue(tiles.tiles); XCTAssertTrue(tiles.clearControls)
        XCTAssertFalse(tiles.clearBody || tiles.clearBand || tiles.neutralGlass, "glass is set under the tiles")
        XCTAssertFalse(tiles.rimFade || tiles.edgeLight || tiles.innerEdge || tiles.glassShadow)
        XCTAssertEqual(tiles.tilesDimDark, 50)
        // Second round: Sheet behind, Smoky in Light, corner 22, gap 10,
        // tile edge 0.5, the dims as they were.
        XCTAssertTrue(tiles.tilesSheet); XCTAssertTrue(tiles.tilesSmoky)
        XCTAssertEqual(tiles.tilesCorner, 22); XCTAssertEqual(tiles.tilesGap, 10); XCTAssertEqual(tiles.tilesEdge, 0.5)
        XCTAssertEqual(tiles.tilesDimLight, 55); XCTAssertEqual(tiles.tilesSmokeLight, 22)
    }

    /// 14's second round (23 Nov): Sheet behind, Smoky in Light, Smoke ·
    /// Light and the tile edge load, are written down by Copy values, and
    /// All off and Reset sliders reach them.
    func testTilesSecondRoundValuesLoadCopyAndReset() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "GlossLab.tiles")
        defaults.set(true, forKey: "GlossLab.tilesSheet")
        defaults.set(true, forKey: "GlossLab.tilesSmoky")
        defaults.set(30.0, forKey: "GlossLab.tilesSmokeLight")
        defaults.set(0.7, forKey: "GlossLab.tilesEdge")
        defaults.set(34.0, forKey: "GlossLab.tilesCorner")
        defaults.set(18.0, forKey: "GlossLab.tilesGap")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.tilesSheet); XCTAssertTrue(lab.tilesSmoky)
        XCTAssertEqual(lab.tilesSmokeLight, 30); XCTAssertEqual(lab.tilesEdge, 0.7)
        XCTAssertEqual(lab.tilesCorner, 34); XCTAssertEqual(lab.tilesGap, 18)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("corner 34.00 pt, gap 18.00 pt,"), text)
        XCTAssertTrue(text.contains("sheet behind: on, smoky in Light: on, smoke Light 30.00 %, edge 0.70"), text)
        lab.allOff()
        XCTAssertFalse(lab.tiles || lab.tilesSheet || lab.tilesSmoky)
        lab.resetSliders()
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(fresh.tilesSmokeLight, 22); XCTAssertEqual(fresh.tilesEdge, 0.5)
        XCTAssertFalse(fresh.tilesSheet || fresh.tilesSmoky, "the second round's switches start off")
        XCTAssertEqual(lab.labLines, fresh.labLines)
        XCTAssertEqual(GlossLab(defaults: defaults).labLines, fresh.labLines, "All off and Reset sliders were not saved")
    }

    /// Material samples (23 Nov): the switch and the veil load and are
    /// written down by Copy values. They are the lab window's own state:
    /// All off, Reset sliders and a preset leave them alone, and a preset
    /// still matches whatever they are.
    func testMaterialSamplesValuesLoadCopyAndStayOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = GlossLab(defaults: nil)
        XCTAssertFalse(fresh.samplesShown, "the sample cards start hidden")
        XCTAssertEqual(fresh.samplesSmoke, 25)
        XCTAssertTrue(fresh.valuesText(app: Self.app(mode: "Light")).contains("Material samples: off, veil 25 %"))
        defaults.set(true, forKey: "GlossLab.samplesShown")
        defaults.set(40.0, forKey: "GlossLab.samplesSmoke")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.samplesShown); XCTAssertEqual(lab.samplesSmoke, 40)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("Material samples: on, veil 40 %"), text)
        XCTAssertFalse(lab.labLines.lowercased().contains("sample"), "the samples are not a numbered idea")
        lab.allOff(); lab.resetSliders()
        XCTAssertTrue(lab.samplesShown, "All off hid the sample cards")
        XCTAssertEqual(lab.samplesSmoke, 40, "Reset sliders moved the samples' veil")
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertTrue(lab.samplesShown); XCTAssertEqual(lab.samplesSmoke, 40)
        lab.samplesSmoke = 55
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "the samples' veil broke the preset's match")
        let again = GlossLab(defaults: defaults)
        XCTAssertTrue(again.samplesShown); XCTAssertEqual(again.samplesSmoke, 55, "a change is kept")
    }

    /// The sample cards: six, lettered A to F in order, each named once,
    /// and the veil reaches exactly the four that take one.
    func testMaterialSamplesAreSixDistinctCards() {
        let all = GlossSample.allCases
        XCTAssertEqual(all.map(\.letter), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(Set(all.map(\.title)).count, 6)
        XCTAssertEqual(all.filter(\.usesSmoke), [.regularSmoke, .regularTint, .clearSmoke, .lightSmoke])
        let size = GlossSamples.windowSize
        // Margins 20 + 20, six cards of 150, six gaps of 14, the close button 28.
        XCTAssertEqual(size.width, 1052)
        XCTAssertEqual(size.height, 190)
    }

    /// The sample cards' window is clear and borderless (so the glass has
    /// only what is behind the window under it), floats over other apps'
    /// windows, stays up while another app is in front, is on every
    /// desktop, and is not shown by being made.
    func testSamplesWindowIsClearFloatsAndStays() {
        let window = GlossSamplesWindows.makeWindow()
        XCTAssertFalse(window.isVisible, "making the window showed it")
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor?.alphaComponent, 0)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.hidesOnDeactivate, "the cards would vanish when another app is clicked")
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertEqual(window.title, "Gloss samples")
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.frame.size, GlossSamples.windowSize)
    }

    /// Where the sample cards' window goes: where it was left while at
    /// least half of it is on the screen, else the top centre.
    func testSamplesWindowComesBackOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let size = GlossSamples.windowSize
        let top = CGRect(x: ((1800 - size.width) / 2).rounded(), y: 1100 - 60 - size.height, width: size.width, height: size.height)
        XCTAssertEqual(GlossSamples.frame(savedOrigin: nil, size: size, visible: visible), top, "first time: top centre")
        let kept = CGPoint(x: 300, y: 400)
        XCTAssertEqual(GlossSamples.frame(savedOrigin: kept, size: size, visible: visible), CGRect(origin: kept, size: size))
        XCTAssertEqual(GlossSamples.frame(savedOrigin: CGPoint(x: 5000, y: 400), size: size, visible: visible), top, "left on a screen that is gone")
        XCTAssertEqual(GlossSamples.frame(savedOrigin: CGPoint(x: 1800 - size.width / 4, y: 400), size: size, visible: visible), top,
                       "three quarters off the screen")
        let half = CGPoint(x: 1800 - size.width / 2, y: 400)
        XCTAssertEqual(GlossSamples.frame(savedOrigin: half, size: size, visible: visible), CGRect(origin: half, size: size), "half on: kept")
    }

    /// The light row (owner, 23 Nov: "add a light option as well"): on to
    /// start with, loaded, written by Copy values, and no preset, All off
    /// or Reset sliders touches it.
    func testMaterialSamplesLightRowLoadsCopiesAndStaysOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = GlossLab(defaults: nil)
        XCTAssertTrue(fresh.samplesLight, "the light row starts on")
        XCTAssertTrue(fresh.valuesText(app: Self.app(mode: "Light")).contains("Material samples: off, veil 25 %, light row on"))
        defaults.set(false, forKey: "GlossLab.samplesLight")
        let lab = GlossLab(defaults: defaults)
        XCTAssertFalse(lab.samplesLight)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("light row off"), text)
        lab.samplesLight = true
        lab.allOff(); lab.resetSliders()
        XCTAssertTrue(lab.samplesLight, "All off or Reset sliders took the light row away")
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertTrue(lab.samplesLight)
        lab.samplesLight = false
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "the light row broke the preset's match")
        XCTAssertFalse(GlossLab(defaults: defaults).samplesLight, "a change is kept")
    }

    /// The light row's cards: G to L in order, none sharing a letter with
    /// the first row, and the window grows by one row of cards for them.
    func testMaterialSamplesLightRowIsSixMoreCards() {
        let all = GlossSample.allCases
        XCTAssertEqual(all.map(\.lightLetter), ["G", "H", "I", "J", "K", "L"])
        XCTAssertTrue(Set(all.map(\.lightLetter)).isDisjoint(with: Set(all.map(\.letter))))
        XCTAssertEqual(all.map(\.lightTitle), ["Regular", "Regular + veil", "Regular, tinted", "Clear", "Clear + veil", "Dark + veil"])
        let one = GlossSamples.windowSize(lightRow: false)
        XCTAssertEqual(one, GlossSamples.windowSize)
        let two = GlossSamples.windowSize(lightRow: true)
        XCTAssertEqual(two.width, 1052)
        // One row 190, a gap of 14, a second row of 150.
        XCTAssertEqual(two.height, 354)
    }

    /// The window's top left corner is what is kept, so the light row
    /// coming or going leaves the top edge where it was; a place saved
    /// before there was a light row is read as the one-row window's.
    func testSamplesWindowKeepsItsTopEdgeAcrossTheLightRow() {
        let one = GlossSamples.windowSize(lightRow: false)
        let two = GlossSamples.windowSize(lightRow: true)
        XCTAssertNil(GlossSamples.origin(savedTopLeft: nil, savedOneRowOrigin: nil, size: two))
        let old = CGPoint(x: 300, y: 400)
        XCTAssertEqual(GlossSamples.origin(savedTopLeft: nil, savedOneRowOrigin: old, size: one), old, "one row: where it was")
        XCTAssertEqual(GlossSamples.origin(savedTopLeft: nil, savedOneRowOrigin: old, size: two), CGPoint(x: 300, y: 236),
                       "two rows hang from the same top edge (400 + 190 - 354)")
        let topLeft = CGPoint(x: 120, y: 900)
        XCTAssertEqual(GlossSamples.origin(savedTopLeft: topLeft, savedOneRowOrigin: old, size: two), CGPoint(x: 120, y: 546))
        XCTAssertEqual(GlossSamples.origin(savedTopLeft: topLeft, savedOneRowOrigin: old, size: one), CGPoint(x: 120, y: 710))
    }

    /// The cards' view never resizes the window: the window is sized for
    /// one row or two where it is shown.
    func testSamplesWindowIsNotResizedByItsCards() throws {
        let window = GlossSamplesWindows.makeWindow()
        let host = try XCTUnwrap(window.contentView as? NSHostingView<GlossSamplesView>)
        XCTAssertEqual(host.sizingOptions, [])
        XCTAssertEqual(window.frame.size, GlossSamples.windowSize)
    }

    /// The system's variants (owner, 24 Nov: "Yes, try them"): off to start
    /// with, loaded with their two settings, written by Copy values, and
    /// no preset, All off or Reset sliders touches them.
    func testSystemVariantsLoadCopyAndStayOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = GlossLab(defaults: nil)
        XCTAssertFalse(fresh.samplesSystem, "the system's variants start off")
        XCTAssertEqual(fresh.samplesLensing, 0); XCTAssertEqual(fresh.samplesScrim, 0)
        XCTAssertTrue(fresh.valuesText(app: Self.app(mode: "Light")).contains("system variants off (lensing 0, scrim 0)"))
        defaults.set(true, forKey: "GlossLab.samplesSystem")
        defaults.set(2.0, forKey: "GlossLab.samplesLensing")
        defaults.set(1.0, forKey: "GlossLab.samplesScrim")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.samplesSystem); XCTAssertEqual(lab.samplesLensing, 2); XCTAssertEqual(lab.samplesScrim, 1)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("system variants on (lensing 2, scrim 1)"), text)
        lab.allOff(); lab.resetSliders()
        XCTAssertTrue(lab.samplesSystem, "All off took the system's variants away")
        XCTAssertEqual(lab.samplesLensing, 2, "Reset sliders moved the lensing")
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertTrue(lab.samplesSystem); XCTAssertEqual(lab.samplesScrim, 1)
        lab.samplesLensing = 3
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "the samples' lensing broke the preset's match")
        XCTAssertEqual(GlossLab(defaults: defaults).samplesLensing, 3, "a change is kept")
    }

    /// The system's variants are numbers 0 to 23, six to a row like A to
    /// F, so the window keeps its width and is four rows tall; the light
    /// row does not count while they are shown.
    func testSystemVariantsFillFourRowsOfSix() {
        XCTAssertEqual(GlossSystemGlass.variants, Array(0...23))
        XCTAssertEqual(GlossSamples.systemColumns, 6)
        let size = GlossSamples.windowSize(lightRow: true, systemVariants: true)
        XCTAssertEqual(size.width, 1052)
        // Margins 20 + 20, four rows of 150, three gaps of 14.
        XCTAssertEqual(size.height, 682)
        XCTAssertEqual(GlossSamples.windowSize(lightRow: false, systemVariants: true), size)
        XCTAssertEqual(GlossSamples.windowSize(lightRow: true, systemVariants: false), GlossSamples.windowSize(lightRow: true))
        XCTAssertEqual(GlossSamples.windowSize(lightRow: false, systemVariants: false), GlossSamples.windowSize)
    }

    /// The hidden settings go on AppKit's glass view where this system has
    /// them, and read back; a view without them is left alone.
    func testSystemGlassSettingsReachTheGlassView() {
        let glass = NSGlassEffectView()
        // Both Macs' systems have them (26.4.1 and 27.0); a system that
        // drops one fails here, which is the news the lab needs.
        for key in [GlossSystemGlass.variantKey, GlossSystemGlass.lensingKey, GlossSystemGlass.scrimKey] {
            XCTAssertTrue(GlossSystemGlass.answers(glass, key), "this system's glass view has no \(key)")
        }
        guard GlossSystemGlass.answers(glass, GlossSystemGlass.variantKey) else { return }
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: glass), 0, "the public glass is variant 0")
        GlossSystemGlass.apply(variant: 8, lensing: 1, scrim: 1, to: glass)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: glass), 8)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.lensingKey, of: glass), 1)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.scrimKey, of: glass), 1)
        GlossSystemGlass.apply(variant: 0, lensing: 0, scrim: 0, to: glass)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: glass), 0)
        let plain = NSView()
        XCTAssertFalse(GlossSystemGlass.answers(plain, GlossSystemGlass.variantKey))
        XCTAssertNil(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: plain))
        GlossSystemGlass.apply(variant: 8, lensing: 1, scrim: 1, to: plain) // no such setting: nothing happens
    }

    /// When rows come, a window that would hang off the screen is moved up
    /// by the least that fits it; one that fits, or is taller than the
    /// screen, is left where it is.
    func testSamplesWindowIsRaisedIntoViewWhenItGrows() {
        let visible = CGRect(x: 0, y: 51, width: 1800, height: 1079)
        let fits = CGRect(x: 522, y: 300, width: 1052, height: 682)
        XCTAssertEqual(GlossSamples.raised(fits, into: visible), fits)
        let low = CGRect(x: 522, y: -40, width: 1052, height: 682)
        XCTAssertEqual(GlossSamples.raised(low, into: visible), CGRect(x: 522, y: 51, width: 1052, height: 682))
        let high = CGRect(x: 522, y: 600, width: 1052, height: 682)
        XCTAssertEqual(GlossSamples.raised(high, into: visible), CGRect(x: 522, y: 448, width: 1052, height: 682))
        let tall = CGRect(x: 0, y: -100, width: 1052, height: 2000)
        XCTAssertEqual(GlossSamples.raised(tall, into: visible), tall)
    }

    /// The stack test (owner, 24 Nov: "Yes, Opus builds"): every value
    /// starts where the brief says, loads, is written by Copy values in one
    /// line, and no preset, All off or Reset sliders touches it.
    func testStackTestValuesLoadCopyAndStayOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = GlossLab(defaults: nil)
        XCTAssertFalse(fresh.samplesStack); XCTAssertEqual(fresh.samplesStackVariant, 11)
        XCTAssertEqual(fresh.samplesGround, .off); XCTAssertEqual(fresh.samplesGroundMaterial, .blur)
        XCTAssertEqual(fresh.samplesGroundDim, 8); XCTAssertFalse(fresh.samplesStackTint)
        XCTAssertEqual(fresh.samplesSubdued, 0); XCTAssertEqual(fresh.samplesAdaptive, 2)
        XCTAssertFalse(fresh.samplesTintReduced); XCTAssertEqual(fresh.samplesSubvariant, "")
        XCTAssertFalse(fresh.samplesStackKey)
        let freshText = fresh.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(freshText.contains("Stack test: off, variant 11, ground off (blur, dim 8 %), smoke 25 % as a veil, lensing 0, scrim 0, "
            + "subdued 0, adaptive 2, reduced tint opacity off, subvariant not set, key window off"), freshText)
        defaults.set(true, forKey: "GlossLab.samplesStack")
        defaults.set(5.0, forKey: "GlossLab.samplesStackVariant")
        defaults.set("below", forKey: "GlossLab.samplesGround")
        defaults.set("clear", forKey: "GlossLab.samplesGroundMaterial")
        defaults.set(20.0, forKey: "GlossLab.samplesGroundDim")
        defaults.set(true, forKey: "GlossLab.samplesStackTint")
        defaults.set(1.0, forKey: "GlossLab.samplesSubdued")
        defaults.set(3.0, forKey: "GlossLab.samplesAdaptive")
        defaults.set(true, forKey: "GlossLab.samplesTintReduced")
        defaults.set("platter", forKey: "GlossLab.samplesSubvariant")
        defaults.set(true, forKey: "GlossLab.samplesStackKey")
        let lab = GlossLab(defaults: defaults)
        XCTAssertTrue(lab.samplesStack); XCTAssertEqual(lab.samplesStackVariant, 5)
        XCTAssertEqual(lab.samplesGround, .below); XCTAssertEqual(lab.samplesGroundMaterial, .clear)
        XCTAssertEqual(lab.samplesGroundDim, 20); XCTAssertTrue(lab.samplesStackTint)
        XCTAssertEqual(lab.samplesSubdued, 1); XCTAssertEqual(lab.samplesAdaptive, 3)
        XCTAssertTrue(lab.samplesTintReduced); XCTAssertEqual(lab.samplesSubvariant, "platter")
        XCTAssertTrue(lab.samplesStackKey)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("Stack test: on, variant 5, ground window below (clear glass, dim 20 %), smoke 25 % as the glass's tint, "
            + "lensing 0, scrim 0, subdued 1, adaptive 3, reduced tint opacity on, subvariant \"platter\", key window on"), text)
        XCTAssertFalse(lab.labLines.lowercased().contains("stack"), "the stack test is not a numbered idea")
        lab.allOff(); lab.resetSliders()
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertEqual(lab.stackLine, GlossLab(defaults: defaults).stackLine, "All off, Reset sliders or a preset moved a stack value")
        lab.samplesGround = .same; lab.samplesGroundMaterial = .regular; lab.samplesGroundDim = 12
        lab.samplesSubvariant = ""; lab.samplesStackKey = false; lab.samplesStackVariant = 19
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "a stack value broke the preset's match")
        let again = GlossLab(defaults: defaults)
        XCTAssertEqual(again.samplesGround, .same); XCTAssertEqual(again.samplesGroundMaterial, .regular)
        XCTAssertEqual(again.samplesGroundDim, 12); XCTAssertEqual(again.samplesSubvariant, "")
        XCTAssertFalse(again.samplesStackKey); XCTAssertEqual(again.samplesStackVariant, 19, "a change is kept")
    }

    /// The stack test's window: a column of two 138 x 62 capsules and a
    /// 138 pt round square, 14 pt apart, 60 pt of room round them; the
    /// ground 40 pt beyond the pieces. It replaces every card set.
    func testStackTestWindowSize() {
        XCTAssertEqual(GlossSamples.stackGroup, CGSize(width: 290, height: 138))
        XCTAssertEqual(GlossSamples.stackWindowSize, CGSize(width: 410, height: 258))
        XCTAssertEqual(GlossSamples.stackGroundRect, CGRect(x: 20, y: 20, width: 370, height: 218))
        for light in [false, true] {
            for system in [false, true] {
                XCTAssertEqual(GlossSamples.windowSize(lightRow: light, systemVariants: system, stack: true), GlossSamples.stackWindowSize)
                XCTAssertEqual(GlossSamples.windowSize(lightRow: light, systemVariants: system, stack: false),
                               GlossSamples.windowSize(lightRow: light, systemVariants: system), "stack test off: the card sets as before")
            }
        }
        // The ground window sits 20 pt in from every side of the cards window.
        XCTAssertEqual(GlossSamples.stackGroundFrame(under: CGRect(x: 100, y: 200, width: 410, height: 258)),
                       CGRect(x: 120, y: 220, width: 370, height: 218))
    }

    /// The Blur ground's mask: opaque in the middle, nothing at the rim,
    /// and half way through its 30 pt fade about half.
    func testStackGroundFadesTowardsItsRim() throws {
        let size = GlossSamples.stackGroundRect.size
        let mask = GlossSamples.fadeMask(size: size)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        mask.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        let midY = Int(size.height / 2), midX = Int(size.width / 2)
        XCTAssertEqual(alpha(midX, midY), 1, accuracy: 0.01, "the middle is all ground")
        XCTAssertEqual(alpha(31, midY), 1, accuracy: 0.02, "the fade ends 30 pt in")
        XCTAssertLessThan(alpha(0, midY), 0.05, "the rim has no ground")
        XCTAssertEqual(alpha(15, midY), 0.5, accuracy: 0.1, "half way through the fade")
        XCTAssertLessThan(alpha(2, 2), 0.01, "the corner is round")
    }

    /// The ground view: Blur is the public behind-window blur with the soft
    /// mask; Regular and Clear glass are a round rectangle of 44 pt with no
    /// blur shown; the dim is black at its strength.
    func testStackGroundViewShowsTheChosenMaterial() throws {
        let view = GlossStackGroundView(frame: CGRect(origin: .zero, size: GlossSamples.stackGroundRect.size))
        view.configure(material: .blur, dim: 0.08)
        view.layout()
        let blur = try XCTUnwrap(view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertFalse(blur.isHidden); XCTAssertNotNil(blur.maskImage)
        XCTAssertEqual(blur.blendingMode, .behindWindow); XCTAssertEqual(blur.state, .active)
        XCTAssertEqual(blur.material, GlossStackGroundView.blurMaterial)
        XCTAssertNil(view.subviews.first { $0 is NSGlassEffectView }, "no glass made for Blur")
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100)), "the ground takes no clicks")
        for (material, style) in [(GlossLab.StackGroundMaterial.regular, NSGlassEffectView.Style.regular), (.clear, .clear)] {
            view.configure(material: material, dim: 0.2)
            view.layout()
            let glass = try XCTUnwrap(view.subviews.compactMap { $0 as? NSGlassEffectView }.first)
            XCTAssertFalse(glass.isHidden); XCTAssertTrue(blur.isHidden)
            XCTAssertEqual(glass.style, style); XCTAssertEqual(glass.cornerRadius, 44)
            XCTAssertEqual(glass.frame, view.bounds)
        }
        XCTAssertEqual(view.dim, 0.2)
    }

    /// Each further hidden setting reaches the glass view and reads back
    /// where this system has it; the subvariant clears when the field is
    /// emptied; a plain view is left alone. `_tintOpacityReduced` is not
    /// on 26.4.1 (seen on 27.0), so it is checked only where it answers.
    func testStackPieceSettingsReachTheGlassView() {
        let glass = NSGlassEffectView()
        for key in [GlossSystemGlass.subduedKey, GlossSystemGlass.adaptiveKey, GlossSystemGlass.subvariantKey] {
            XCTAssertTrue(GlossSystemGlass.answers(glass, key), "this system's glass view has no \(key)")
        }
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.adaptiveKey, of: glass), 2, "the view's own adaptive value")
        XCTAssertNil(GlossSystemGlass.subvariant(of: glass), "no subvariant to start with")
        let tintAnswers = GlossSystemGlass.answers(glass, GlossSystemGlass.tintReducedKey)
        let set = GlossSystemGlass.PieceSettings(variant: 5, lensing: 1, scrim: 1, subdued: 2, adaptive: 1, tintReduced: true,
                                                 subvariant: "zzNotASubvariant")
        GlossSystemGlass.apply(set, to: glass)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: glass), 5)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.lensingKey, of: glass), 1)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.scrimKey, of: glass), 1)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.subduedKey, of: glass), 2)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.adaptiveKey, of: glass), 1)
        XCTAssertEqual(GlossSystemGlass.subvariant(of: glass), "zzNotASubvariant", "a name the system does not know is kept, not refused")
        XCTAssertEqual(GlossSystemGlass.flag(GlossSystemGlass.tintReducedKey, of: glass), tintAnswers ? true : nil)
        GlossSystemGlass.apply(GlossSystemGlass.PieceSettings(), to: glass)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.variantKey, of: glass), 11)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.subduedKey, of: glass), 0)
        XCTAssertEqual(GlossSystemGlass.value(GlossSystemGlass.adaptiveKey, of: glass), 2)
        XCTAssertNil(GlossSystemGlass.subvariant(of: glass), "an empty field clears the subvariant")
        XCTAssertEqual(GlossSystemGlass.flag(GlossSystemGlass.tintReducedKey, of: glass), tintAnswers ? false : nil)
        let plain = NSView()
        for key in [GlossSystemGlass.subduedKey, GlossSystemGlass.adaptiveKey, GlossSystemGlass.tintReducedKey, GlossSystemGlass.subvariantKey] {
            XCTAssertFalse(GlossSystemGlass.answers(plain, key))
        }
        GlossSystemGlass.apply(set, to: plain) // no such settings: nothing happens
        XCTAssertNil(GlossSystemGlass.subvariant(of: plain)); XCTAssertNil(GlossSystemGlass.flag(GlossSystemGlass.tintReducedKey, of: plain))
    }

    /// With the Key window switch off (or the stack test off) the cards
    /// window cannot become key, exactly as before; only both on let it.
    func testSamplesWindowTakesTheKeyboardOnlyWithTheKeySwitch() {
        let window = GlossSamplesWindows.makeWindow()
        XCTAssertFalse(window.canBecomeKey, "the cards window never takes the keyboard")
        XCTAssertTrue(window.becomesKeyOnlyIfNeeded)
        let lab = GlossLab(defaults: nil)
        XCTAssertFalse(GlossSamplesWindows.keyAllowed(for: lab))
        lab.samplesStackKey = true
        XCTAssertFalse(GlossSamplesWindows.keyAllowed(for: lab), "the switch belongs to the stack test")
        lab.samplesStack = true
        XCTAssertTrue(GlossSamplesWindows.keyAllowed(for: lab))
        lab.samplesStackKey = false
        XCTAssertFalse(GlossSamplesWindows.keyAllowed(for: lab))
        window.keyAllowed = true
        XCTAssertTrue(window.canBecomeKey); XCTAssertFalse(window.becomesKeyOnlyIfNeeded)
        window.keyAllowed = false
        XCTAssertFalse(window.canBecomeKey, "off again: as before"); XCTAssertTrue(window.becomesKeyOnlyIfNeeded)
    }

    /// The ground's own window ("Window below"): clear, borderless, without
    /// a shadow, taking no clicks and never key, the ground's size, and
    /// wanted only in the stack test with that ground chosen.
    func testStackGroundWindowIsClearAndTakesNoClicks() {
        let ground = GlossSamplesWindows.makeGroundWindow()
        XCTAssertFalse(ground.isVisible, "making the window showed it")
        XCTAssertFalse(ground.isOpaque); XCTAssertEqual(ground.backgroundColor?.alphaComponent, 0)
        XCTAssertFalse(ground.hasShadow); XCTAssertTrue(ground.ignoresMouseEvents)
        XCTAssertFalse(ground.canBecomeKey)
        XCTAssertEqual(ground.title, "Gloss samples ground")
        XCTAssertEqual(ground.frame.size, GlossSamples.stackGroundRect.size)
        XCTAssertTrue(ground.contentView is GlossStackGroundView)
        let lab = GlossLab(defaults: nil)
        for place in GlossLab.StackGround.allCases {
            lab.samplesGround = place
            lab.samplesStack = false
            XCTAssertFalse(GlossSamplesWindows.groundWindowWanted(for: lab))
            lab.samplesStack = true
            XCTAssertEqual(GlossSamplesWindows.groundWindowWanted(for: lab), place == .below)
        }
    }

    // MARK: Apple's blur (24 Nov, owner: "Lift it, Opus builds")

    /// Apple's blur's two values start where the brief says, load, are
    /// written by Copy values on the stack test's line with the material's
    /// name, and no preset, All off or Reset sliders touches them.
    func testAppleBlurValuesLoadCopyAndStayOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GlossLab.StackGroundMaterial.variable.title, "Apple's blur")
        XCTAssertEqual(GlossLab.StackGroundMaterial(rawValue: "variable"), .variable)
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(fresh.samplesGroundRadius, 20); XCTAssertEqual(fresh.samplesGroundReach, 60)
        XCTAssertTrue(fresh.stackLine.hasSuffix("key window off, Apple's blur radius 20 pt, reach 60 pt"), fresh.stackLine)
        defaults.set("variable", forKey: "GlossLab.samplesGroundMaterial")
        defaults.set(12.0, forKey: "GlossLab.samplesGroundRadius")
        defaults.set(30.0, forKey: "GlossLab.samplesGroundReach")
        defaults.set("same", forKey: "GlossLab.samplesGround")
        let lab = GlossLab(defaults: defaults)
        XCTAssertEqual(lab.samplesGroundMaterial, .variable)
        XCTAssertEqual(lab.samplesGroundRadius, 12); XCTAssertEqual(lab.samplesGroundReach, 30)
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("ground same window (apple's blur, dim 8 %)"), text)
        XCTAssertTrue(text.contains("Apple's blur radius 12 pt, reach 30 pt"), text)
        lab.allOff(); lab.resetSliders()
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertEqual(lab.samplesGroundRadius, 12); XCTAssertEqual(lab.samplesGroundReach, 30)
        XCTAssertEqual(lab.samplesGroundMaterial, .variable, "All off, Reset sliders or a preset moved Apple's blur")
        lab.samplesGroundRadius = 40; lab.samplesGroundReach = 80
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "an Apple's blur value broke the preset's match")
        let again = GlossLab(defaults: defaults)
        XCTAssertEqual(again.samplesGroundRadius, 40); XCTAssertEqual(again.samplesGroundReach, 80, "a change is kept")
    }

    /// With Apple's blur the ground reaches as far as Reach: in the cards
    /// window the room round the pieces grows to it where it is over 60 pt
    /// (the pieces stay `room` in from the sides), the window below is the
    /// ground's size; every other material keeps 410 x 258 and the 40 pt
    /// ground exactly.
    func testAppleBlurWindowSizeFollowsTheReach() {
        XCTAssertTrue(GlossBackdropGround.isAvailable, "this system lacks a piece of Apple's blur")
        let lab = GlossLab(defaults: nil)
        lab.samplesStack = true; lab.samplesGround = .same; lab.samplesGroundMaterial = .variable
        for (reach, room) in [(CGFloat(20), CGFloat(60)), (60, 60), (80, 80)] {
            lab.samplesGroundReach = Double(reach)
            XCTAssertEqual(GlossSamples.stackGroundReach(for: lab), reach)
            XCTAssertEqual(GlossSamples.stackRoom(for: lab), room, "reach \(reach)")
            XCTAssertEqual(GlossSamples.windowSize(for: lab), CGSize(width: 290 + room * 2, height: 138 + room * 2))
            let ground = GlossSamples.stackGroundRect(room: room, reach: reach)
            XCTAssertEqual(ground, CGRect(x: room - reach, y: room - reach, width: 290 + reach * 2, height: 138 + reach * 2))
            XCTAssertGreaterThanOrEqual(ground.minX, 0, "the ground is cut off at reach \(reach)")
            let window = GlossSamples.windowSize(for: lab)
            XCTAssertLessThanOrEqual(ground.maxX, window.width); XCTAssertLessThanOrEqual(ground.maxY, window.height)
        }
        // Window below: the cards window keeps its 60 pt room; the ground
        // window is the ground, centred on the pieces.
        lab.samplesGround = .below; lab.samplesGroundReach = 80
        XCTAssertEqual(GlossSamples.stackRoom(for: lab), 60)
        XCTAssertEqual(GlossSamples.windowSize(for: lab), CGSize(width: 410, height: 258))
        XCTAssertEqual(GlossSamples.stackGroundFrame(under: CGRect(x: 100, y: 200, width: 410, height: 258), room: 60, reach: 80),
                       CGRect(x: 80, y: 180, width: 450, height: 298), "the pieces lie 80 pt in from the ground window's sides")
        // Every other material, whatever Reach says: exactly as before.
        for material in [GlossLab.StackGroundMaterial.blur, .regular, .clear] {
            lab.samplesGroundMaterial = material
            for place in [GlossLab.StackGround.same, .below] {
                lab.samplesGround = place
                XCTAssertEqual(GlossSamples.stackGroundReach(for: lab), 40)
                XCTAssertEqual(GlossSamples.windowSize(for: lab), GlossSamples.stackWindowSize)
                XCTAssertEqual(GlossSamples.stackGroundRect(room: GlossSamples.stackRoom(for: lab), reach: 40), GlossSamples.stackGroundRect)
            }
        }
        lab.samplesStack = false
        XCTAssertEqual(GlossSamples.windowSize(for: lab), GlossSamples.windowSize(lightRow: lab.samplesLight, systemVariants: lab.samplesSystem))
    }

    /// The cards' view is as large as the window at every reach, so the
    /// pieces lie `room` in from its sides and the ground is not cut off
    /// (Air still ab-white-same-reach80, 24 Nov: the view kept 410 x 258
    /// in a 450 x 298 window).
    func testAppleBlurCardsViewFillsTheGrownWindow() {
        let lab = GlossLab(defaults: nil)
        lab.samplesStack = true; lab.samplesGround = .same; lab.samplesGroundMaterial = .variable
        for reach in [20.0, 60.0, 80.0] {
            lab.samplesGroundReach = reach
            let host = NSHostingView(rootView: GlossSamplesView(lab: lab))
            XCTAssertEqual(host.fittingSize, GlossSamples.windowSize(for: lab), "reach \(reach)")
        }
        lab.samplesStack = false
        XCTAssertEqual(NSHostingView(rootView: GlossSamplesView(lab: lab)).fittingSize, GlossSamples.windowSize(for: lab), "the card sets as before")
    }

    /// Apple's blur's mask: full over the pieces and for the first 25/60 of
    /// the reach, then a smooth fall to nothing at the rim, by the distance
    /// from the pieces' round rectangle, so a corner falls as a side does.
    func testAppleBlurMaskFallsFromThePiecesToTheRim() throws {
        let reach: CGFloat = 60
        let size = CGSize(width: 290 + reach * 2, height: 138 + reach * 2)
        func strength(_ x: CGFloat, _ y: CGFloat) -> CGFloat { GlossSamples.variableStrength(at: CGPoint(x: x, y: y), size: size, reach: reach) }
        XCTAssertEqual(strength(size.width / 2, size.height / 2), 1, "over the pieces")
        XCTAssertEqual(strength(reach + 10, size.height / 2), 1, "inside the pieces' edge")
        XCTAssertEqual(strength(reach - 24, size.height / 2), 1, "full for the first 25 pt")
        XCTAssertEqual(strength(0, size.height / 2), 0, accuracy: 0.001, "nothing at the rim")
        XCTAssertEqual(strength(size.width / 2, size.height), 0, accuracy: 0.001, "nothing at the bottom rim")
        XCTAssertEqual(strength(reach - 42.5, size.height / 2), 0.5, accuracy: 0.01, "half way through the fall")
        XCTAssertEqual(strength(0, 0), 0, "the ground's corner")
        // The pieces' corner arc (centre 30 pt in from the group's corner,
        // radius 30): 40 pt out from it along the diagonal is as strong as
        // 40 pt out from a side.
        let arc = CGPoint(x: reach + 30, y: reach + 30)
        let along = (30 + 40) / CGFloat(2).squareRoot()
        let side = strength(reach - 40, size.height / 2)
        XCTAssertEqual(strength(arc.x - along, arc.y - along), side, accuracy: 0.01)
        XCTAssertGreaterThan(side, 0.05); XCTAssertLessThan(side, 0.95)
        let image = try XCTUnwrap(GlossSamples.variableMask(size: size, reach: reach, scale: 2))
        XCTAssertEqual(image.width, Int(size.width * 2)); XCTAssertEqual(image.height, Int(size.height * 2))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { let i = y * image.bytesPerRow + x * 4; return Array(data[i..<i + 4]) }
        XCTAssertEqual(pixel(image.width / 2, image.height / 2), [255, 255, 255, 255], "white, opaque over the pieces")
        XCTAssertEqual(pixel(0, image.height / 2)[3], 0, "clear at the rim")
        let mid = pixel(Int((reach - 42.5) * 2), image.height / 2)
        XCTAssertEqual(mid[0], mid[3], "premultiplied white"); XCTAssertEqual(Double(mid[3]), 127.5, accuracy: 4)
    }

    /// The private layer is made, samples behind the window, and the radius
    /// and the mask reach it and read back; a new radius reaches it too; the
    /// other materials hide it and draw as before.
    func testAppleBlurRadiusAndMaskReachTheLayer() throws {
        XCTAssertNil(GlossBackdropGround.backdropClassNameForTesting, "the seam is set outside a test")
        let size = GlossSamples.stackGroundRect(room: 60, reach: 30).size
        let view = GlossStackGroundView(frame: CGRect(origin: .zero, size: size))
        view.configure(material: .variable, dim: 0.08, radius: 12, reach: 30)
        view.layout()
        XCTAssertEqual(view.drawnMaterial, .variable)
        let layer = try XCTUnwrap(view.backdropLayer, "no private layer made")
        XCTAssertEqual(NSStringFromClass(type(of: layer)), "CABackdropLayer")
        XCTAssertEqual(layer.value(forKey: GlossBackdropGround.behindWindowKey) as? Bool, true, "it must sample behind the window")
        XCTAssertEqual(layer.frame, view.bounds)
        var back = GlossBackdropGround.readBack(layer)
        XCTAssertEqual(back.radius, 12)
        let mask = try XCTUnwrap(back.mask, "the mask did not reach the layer")
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertEqual(mask.width, Int((size.width * scale).rounded()))
        XCTAssertNotNil(view.subviews.first { !$0.isHidden && $0.layer?.sublayers?.contains(layer) == true }, "the layer is not shown")
        let blur = try XCTUnwrap(view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertTrue(blur.isHidden, "the public blur is drawn as well")
        XCTAssertNil(view.subviews.first { $0 is NSGlassEffectView }, "no glass made for Apple's blur")
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100)), "the ground takes no clicks")
        XCTAssertEqual(view.dim, 0.08)
        view.configure(material: .variable, dim: 0.08, radius: 30, reach: 30)
        view.layout()
        back = GlossBackdropGround.readBack(layer)
        XCTAssertEqual(back.radius, 30, "a new radius did not reach the layer")
        view.configure(material: .blur, dim: 0.08, radius: 30, reach: 30)
        view.layout()
        XCTAssertEqual(view.drawnMaterial, .blur)
        XCTAssertFalse(blur.isHidden); XCTAssertNotNil(blur.maskImage)
        XCTAssertNil(view.subviews.first { !$0.isHidden && $0.layer?.sublayers?.contains(layer) == true }, "Blur still shows Apple's blur")
        view.configure(material: .variable, dim: 0.08, radius: 30, reach: 30)
        view.layout()
        XCTAssertTrue(blur.isHidden); XCTAssertEqual(GlossBackdropGround.readBack(layer).radius, 30)
    }

    /// With the private class made unavailable (the test seam), Apple's
    /// blur draws the public Blur ground with its geometry, the quiet line
    /// is shown, and nothing throws; with the seam cleared it is back.
    func testAppleBlurFallsBackToBlurWithoutThePrivateLayer() throws {
        defer { GlossBackdropGround.backdropClassNameForTesting = nil }
        XCTAssertNil(GlossBackdropGround.line(for: .variable), "this system lacks a piece of Apple's blur")
        for missing in ["AtticGlossNoSuchBackdropLayer", "CALayer"] {
            GlossBackdropGround.backdropClassNameForTesting = missing
            XCTAssertFalse(GlossBackdropGround.isAvailable, missing)
            XCTAssertNil(GlossBackdropGround.make(), missing)
            XCTAssertEqual(GlossBackdropGround.line(for: .variable), "Apple's blur is not available on this macOS")
            XCTAssertNil(GlossBackdropGround.line(for: .blur), "the line belongs to Apple's blur")
            XCTAssertEqual(GlossSamples.drawnGroundMaterial(.variable), .blur)
            let lab = GlossLab(defaults: nil)
            lab.samplesStack = true; lab.samplesGround = .same; lab.samplesGroundMaterial = .variable; lab.samplesGroundReach = 80
            XCTAssertEqual(GlossSamples.windowSize(for: lab), GlossSamples.stackWindowSize, "the fall-back keeps Blur's window")
            XCTAssertEqual(GlossSamples.stackGroundReach(for: lab), 40)
            let view = GlossStackGroundView(frame: CGRect(origin: .zero, size: GlossSamples.stackGroundRect.size))
            view.configure(material: .variable, dim: 0.08, radius: 20, reach: 40)
            view.layout()
            XCTAssertEqual(view.drawnMaterial, .blur); XCTAssertNil(view.backdropLayer)
            let blur = try XCTUnwrap(view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            XCTAssertFalse(blur.isHidden); XCTAssertNotNil(blur.maskImage, "the public Blur's soft rim")
        }
        GlossBackdropGround.backdropClassNameForTesting = nil
        XCTAssertTrue(GlossBackdropGround.isAvailable)
        XCTAssertEqual(GlossSamples.drawnGroundMaterial(.variable), .variable)
    }

    // MARK: The fade (24 Nov, "Fix the fade")

    /// Fade start, curve and extras load from storage, are written by Copy
    /// values on a line of their own, and stay out of presets, All off and
    /// Reset sliders.
    func testFadeValuesLoadCopyAndStayOutOfPresets() throws {
        let suite = "GlossLabValuesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = GlossLab(defaults: nil)
        XCTAssertEqual(fresh.samplesGroundHold, 25); XCTAssertEqual(fresh.samplesGroundCurve, GlossLab.groundCurveStart)
        XCTAssertEqual(fresh.samplesGroundExtras, "")
        XCTAssertEqual(fresh.fadeLine, "Apple's blur fade: start 25 pt, curve \(String(format: "%.1f", GlossLab.groundCurveStart)), extras none")
        XCTAssertTrue(fresh.valuesText(app: Self.app(mode: "Light")).contains(fresh.fadeLine))
        defaults.set("variable", forKey: "GlossLab.samplesGroundMaterial")
        defaults.set(10.0, forKey: "GlossLab.samplesGroundHold")
        defaults.set(2.5, forKey: "GlossLab.samplesGroundCurve")
        defaults.set("inputFade=1; inputDither=0", forKey: "GlossLab.samplesGroundExtras")
        let lab = GlossLab(defaults: defaults)
        XCTAssertEqual(lab.samplesGroundHold, 10); XCTAssertEqual(lab.samplesGroundCurve, 2.5)
        XCTAssertEqual(lab.samplesGroundExtras, "inputFade=1; inputDither=0")
        let text = lab.valuesText(app: Self.app(mode: "Light"))
        XCTAssertTrue(text.contains("Apple's blur fade: start 10 pt, curve 2.5, extras \"inputFade=1; inputDither=0\""), text)
        XCTAssertTrue(lab.stackLine.hasSuffix("Apple's blur radius 20 pt, reach 60 pt"), "the stack line reads as before")
        lab.allOff(); lab.resetSliders()
        let preset = try XCTUnwrap(GlossLab.presets.first { $0.id == "thickGlass" })
        lab.apply(preset)
        XCTAssertEqual(lab.samplesGroundHold, 10); XCTAssertEqual(lab.samplesGroundCurve, 2.5)
        XCTAssertEqual(lab.samplesGroundExtras, "inputFade=1; inputDither=0", "All off, Reset sliders or a preset moved the fade")
        lab.samplesGroundHold = 40; lab.samplesGroundCurve = 4; lab.samplesGroundExtras = ""
        XCTAssertEqual(lab.currentPreset?.id, "thickGlass", "a fade value broke the preset's match")
        let again = GlossLab(defaults: defaults)
        XCTAssertEqual(again.samplesGroundHold, 40); XCTAssertEqual(again.samplesGroundCurve, 4)
        XCTAssertEqual(again.samplesGroundExtras, "", "a change is kept")
    }

    /// The first round's strength function, copied verbatim from `ddfcc821`
    /// (`GlossSamples.variableStrength`, hold 25/60 of the reach), so curve
    /// 1 can be held to it.
    private static func firstRoundStrength(at point: CGPoint, size: CGSize, reach: CGFloat) -> CGFloat {
        let halfWidth = max(size.width / 2 - reach, 0), halfHeight = max(size.height / 2 - reach, 0)
        let corner = min(GlossSamples.stackSquareCorner, halfWidth, halfHeight)
        let qx = max(abs(point.x - size.width / 2) - (halfWidth - corner), 0)
        let qy = max(abs(point.y - size.height / 2) - (halfHeight - corner), 0)
        let distance = max((qx * qx + qy * qy).squareRoot() - corner, 0)
        let hold = reach * (25.0 / 60.0)
        guard distance > hold, reach > hold else { return 1 }
        let left = 1 - min((distance - hold) / (reach - hold), 1)
        return left * left * (3 - 2 * left)
    }

    /// The first round's mask bytes, made as `ddfcc821` made them.
    private static func firstRoundMask(size: CGSize, reach: CGFloat, scale: CGFloat) -> [UInt8] {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                let value = UInt8((firstRoundStrength(at: point, size: size, reach: reach) * 255).rounded())
                let index = (y * width + x) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value; pixels[index + 3] = value
            }
        }
        return pixels
    }

    private static func bytes(_ image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertEqual(image.bytesPerRow, image.width * 4)
        return [UInt8](data)
    }

    /// At fade start 25, curve 1 and reach 60 the strength and the mask are
    /// the first round's, value for value and byte for byte, and so is the
    /// mask the ground's layer holds with no extra inputs.
    func testFadeAtCurveOneIsTheFirstRoundsMask() throws {
        let reach: CGFloat = 60
        let size = CGSize(width: 290 + reach * 2, height: 138 + reach * 2)
        var y: CGFloat = 0
        while y <= size.height {
            var x: CGFloat = 0
            while x <= size.width {
                let point = CGPoint(x: x, y: y)
                XCTAssertEqual(GlossSamples.variableStrength(at: point, size: size, reach: reach, hold: 25, curve: 1),
                               Self.firstRoundStrength(at: point, size: size, reach: reach), "at \(point)")
                x += 1.25
            }
            y += 1.25
        }
        for scale in [CGFloat(1), 2] {
            let mask = try XCTUnwrap(GlossSamples.variableMask(size: size, reach: reach, hold: 25, curve: 1, scale: scale))
            XCTAssertEqual(try Self.bytes(mask), Self.firstRoundMask(size: size, reach: reach, scale: scale), "mask at scale \(scale)")
        }
        let view = GlossStackGroundView(frame: CGRect(origin: .zero, size: size))
        view.configure(material: .variable, dim: 0, radius: 20, reach: reach, hold: 25, curve: 1, extras: "")
        view.layout()
        let held = try XCTUnwrap(GlossBackdropGround.readBack(try XCTUnwrap(view.backdropLayer)).mask)
        let scale = CGFloat(held.width) / size.width
        XCTAssertEqual(try Self.bytes(held), Self.firstRoundMask(size: size, reach: reach, scale: scale), "the layer's mask")
    }

    /// For every curve, fade start and reach: full to the fade start (kept
    /// 5 pt under the reach), nothing at the rim, never rising with
    /// distance; a higher curve is never stronger than curve 1.
    func testFadeStrengthIsFullThenFallsToTheRimForEveryCurve() {
        for reach in [CGFloat(20), 60, 120, 160] {
            let size = CGSize(width: 290 + reach * 2, height: 138 + reach * 2)
            for hold in [CGFloat(0), 25, 60] {
                let used = GlossSamples.variableFadeStart(hold, reach: reach)
                XCTAssertEqual(used, min(hold, reach - 5))
                for curve in [CGFloat(1), 1.5, 2, 3, 4] {
                    var last: CGFloat = 1
                    var distance: CGFloat = 0
                    while distance <= reach {
                        let point = CGPoint(x: reach - distance, y: size.height / 2)
                        let strength = GlossSamples.variableStrength(at: point, size: size, reach: reach, hold: hold, curve: curve)
                        let label = "reach \(reach) hold \(hold) curve \(curve) at \(distance) pt"
                        if distance <= used { XCTAssertEqual(strength, 1, label) }
                        XCTAssertLessThanOrEqual(strength, last + 1e-12, "rises with distance: \(label)")
                        XCTAssertLessThanOrEqual(strength, GlossSamples.variableStrength(at: point, size: size, reach: reach, hold: hold, curve: 1) + 1e-12, label)
                        last = strength
                        distance += 0.5
                    }
                    XCTAssertEqual(GlossSamples.variableStrength(at: CGPoint(x: 0, y: size.height / 2), size: size, reach: reach, hold: hold, curve: curve),
                                   0, accuracy: 1e-9, "the rim: reach \(reach) hold \(hold) curve \(curve)")
                }
            }
        }
    }

    /// Reach goes to 160 pt: the cards window grows round the pieces in
    /// Same window, the window below is the ground's size, and neither cuts
    /// the ground.
    func testFadeWindowSizeAtReach160() {
        let lab = GlossLab(defaults: nil)
        lab.samplesStack = true; lab.samplesGround = .same; lab.samplesGroundMaterial = .variable; lab.samplesGroundReach = 160
        XCTAssertEqual(GlossSamples.stackRoom(for: lab), 160)
        XCTAssertEqual(GlossSamples.windowSize(for: lab), CGSize(width: 610, height: 458))
        XCTAssertEqual(GlossSamples.stackGroundRect(room: 160, reach: 160), CGRect(x: 0, y: 0, width: 610, height: 458))
        XCTAssertEqual(NSHostingView(rootView: GlossSamplesView(lab: lab)).fittingSize, CGSize(width: 610, height: 458))
        lab.samplesGround = .below
        XCTAssertEqual(GlossSamples.windowSize(for: lab), CGSize(width: 410, height: 258))
        XCTAssertEqual(GlossSamples.stackGroundFrame(under: CGRect(x: 300, y: 200, width: 410, height: 258), room: 60, reach: 160),
                       CGRect(x: 200, y: 100, width: 610, height: 458), "the pieces lie 160 pt in from the ground window's sides")
    }

    /// The extras text: only pairs whose key the filter lists, that the lab's
    /// own controls do not set, whose value is a finite number and whose
    /// current value is a number or unset; everything else is ignored and
    /// nothing throws. Against the real filter as well.
    func testFadeExtrasKeepOnlyNumbersForTheFiltersOwnKeys() throws {
        let keys = ["inputMaskImage", "inputRadius", "inputNormalizeEdges", "inputFade", "inputDither", "inputSourceSublayerName"]
        func read(_ text: String) -> GlossBackdropGround.Extras {
            GlossBackdropGround.extras(text, keys: keys) { $0 == "inputSourceSublayerName" ? "name" as NSString : nil }
        }
        typealias Pair = GlossBackdropGround.Extras.Pair
        XCTAssertEqual(read(""), .none, "an empty text")
        XCTAssertEqual(read("  ;\n ; "), .none, "only separators")
        XCTAssertEqual(read("inputFade=1"), GlossBackdropGround.Extras(applied: [Pair(key: "inputFade", value: 1)]))
        XCTAssertEqual(read(" inputFade = 0.5 ;\ninputDither=0").applied, [Pair(key: "inputFade", value: 0.5), Pair(key: "inputDither", value: 0)])
        XCTAssertEqual(read("inputNoSuchKey=1").ignored, ["inputNoSuchKey"], "an unknown key")
        XCTAssertEqual(read("inputBlurFillDarkenOpacity=0").ignored, ["inputBlurFillDarkenOpacity"], "a key this filter lacks")
        XCTAssertEqual(read("inputFade=abc").ignored, ["inputFade"], "not a number")
        XCTAssertEqual(read("inputFade=nan; inputDither=inf").ignored, ["inputFade", "inputDither"], "not a finite number")
        XCTAssertEqual(read("inputFade=").ignored, ["inputFade"], "no value")
        XCTAssertEqual(read("inputFade").ignored, ["inputFade"], "no =")
        XCTAssertEqual(read("=1").ignored, ["=1"], "no key")
        XCTAssertEqual(read("inputRadius=5; inputMaskImage=1").ignored, ["inputRadius", "inputMaskImage"], "the lab's own inputs")
        XCTAssertEqual(read("inputSourceSublayerName=1").ignored, ["inputSourceSublayerName"], "not a numeric input")
        let mixed = read("inputFade=1; junk; inputNope=2; inputDither=x")
        XCTAssertEqual(mixed.applied, [Pair(key: "inputFade", value: 1)])
        XCTAssertEqual(mixed.ignored, ["junk", "inputNope", "inputDither"])
        XCTAssertEqual(mixed.line, "Applied: inputFade=1.0. Ignored: junk, inputNope, inputDither.")
        XCTAssertNil(GlossBackdropGround.extrasLine("  "))
        // The real filter: its own keys decide, and setting them does not throw.
        let made = try XCTUnwrap(GlossBackdropGround.makeFilter())
        let text = "inputFade=1; inputBlurFillDarkenOpacity=0; inputRadius=3; bogus"
        let applied = GlossBackdropGround.applyExtras(text, to: made.filter)
        XCTAssertEqual((made.filter.value(forKey: "inputFade") as? NSNumber)?.doubleValue, 1)
        XCTAssertNotEqual((made.filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue, 3, "the radius is the slider's")
        let fill = made.keys.contains("inputBlurFillDarkenOpacity")
        XCTAssertEqual(applied.applied.map(\.key), fill ? ["inputFade", "inputBlurFillDarkenOpacity"] : ["inputFade"])
        XCTAssertEqual(applied.ignored, fill ? ["inputRadius", "bogus"] : ["inputBlurFillDarkenOpacity", "inputRadius", "bogus"])
        XCTAssertEqual(GlossBackdropGround.extrasLine(text), applied.line)
    }

    /// Configuring Apple's blur writes its check line to the check file, with
    /// the fade, the extras and the filter's numeric inputs; clearing the
    /// extras makes a new filter, so the input goes back to unset; another
    /// material writes nothing.
    func testFadeCheckFileHoldsTheValuesSet() throws {
        let url = GlossBackdropGround.checkFileURL
        XCTAssertEqual(url.lastPathComponent, "gloss-ground-check.txt")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = GlossSamples.stackGroundRect(room: 80, reach: 80).size
        let view = GlossStackGroundView(frame: CGRect(origin: .zero, size: size))
        view.configure(material: .variable, dim: 0, radius: 14, reach: 80, hold: 10, curve: 3, extras: "inputFade=1; bogus=2")
        view.layout()
        var line = try String(contentsOf: url, encoding: .utf8)
        for part in ["groundChosen=variable", "groundDrawn=variable", "radius=14.0", "hold=10.0", "holdUsed=10.0", "curve=3.0", "reach=80.0",
                     "extrasApplied=[inputFade=1.0]", "extrasIgnored=[bogus]", "inputRadius=14", "inputFade=1"] {
            XCTAssertTrue(line.contains(part), "missing \(part): \(line)")
        }
        XCTAssertEqual(line.split(separator: "\n").count, 1, "one line")
        let layer = try XCTUnwrap(view.backdropLayer)
        XCTAssertEqual(((layer.filters?.first as? NSObject)?.value(forKey: "inputFade") as? NSNumber)?.doubleValue, 1)
        view.configure(material: .variable, dim: 0, radius: 14, reach: 80, hold: 78, curve: 3, extras: "")
        view.layout()
        line = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(line.contains("hold=78.0 holdUsed=75.0"), line)
        XCTAssertTrue(line.contains("extrasApplied=[] extrasIgnored=[]"), line)
        XCTAssertNotEqual(((layer.filters?.first as? NSObject)?.value(forKey: "inputFade") as? NSNumber)?.doubleValue, 1,
                          "a cleared extra input stayed set")
        XCTAssertEqual(GlossBackdropGround.readBack(layer).radius, 14, "the new filter has the radius")
        XCTAssertNotNil(GlossBackdropGround.readBack(layer).mask, "the new filter has the mask")
        try FileManager.default.removeItem(at: url)
        view.configure(material: .blur, dim: 0, radius: 14, reach: 80)
        view.layout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "another material wrote the check file")
    }
}
#endif
