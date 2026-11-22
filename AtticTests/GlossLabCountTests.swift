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

    private func host(elevation: AtticPanelSurfaceElevation? = nil) -> (NSPanel, NSView) {
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
            Spacer()
        }
        .modifier(PanelShellSurface(cornerSize: 26, elevation: elevation))
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
            ("5 top light", { $0.topLight = true }),
            ("5 top light, not keeping out", { $0.topLight = true; $0.topLightKeepsOut = false }),
            ("6 grain", { $0.grain = true }),
            ("10 one rim", { $0.oneRim = true }),
            ("0 3D (5 and 3)", { $0.apply3D() }),
        ]
        for (name, configure) in switches {
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
            ("5 top light", \.topLight, { GlossLabCounters.surfaceLayer }),
            ("6 grain", \.grain, { GlossLabCounters.surfaceLayer }),
            ("10 one rim", \.oneRim, { GlossLabCounters.controlEdgeLight }),
            ("2 clear band", \.clearBand, { GlossLabCounters.stageSurface }),
            ("7 shadow", \.glassShadow, { GlossLabCounters.shadowLayer }),
            ("7 spill", \.glassSpill, { GlossLabCounters.shadowLayer }),
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
        let text = lab.valuesText(mode: "Dark")
        XCTAssertTrue(text.contains("2 A band of Clear glass: on, width 10.00 pt, Stacked, one container: on"), text)
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
}
#endif
