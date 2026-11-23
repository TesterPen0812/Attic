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

    private func host(elevation: AtticPanelSurfaceElevation? = nil, tilesPage: Bool = false) -> (NSPanel, NSView) {
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
        XCTAssertTrue(again.clearBand); XCTAssertEqual(again.clearBandWidth, 16)
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
        XCTAssertEqual(preset.dark, true)
        XCTAssertTrue(tiles.tiles); XCTAssertTrue(tiles.clearControls)
        XCTAssertFalse(tiles.clearBody || tiles.clearBand || tiles.neutralGlass, "glass is set under the tiles")
        XCTAssertFalse(tiles.rimFade || tiles.edgeLight || tiles.innerEdge || tiles.glassShadow)
        XCTAssertEqual(tiles.tilesDimDark, 50)
    }
}
#endif
