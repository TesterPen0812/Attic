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

    private func host() -> (NSPanel, NSView) {
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
        .modifier(PanelShellSurface(cornerSize: 26, elevation: nil))
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
        var stage = 0, surface = 0, rim = 0, controlLight = 0
        var description: String { "stage \(stage), surface layer \(surface), rim layer \(rim), control edge light \(controlLight)" }
    }

    /// One resize write: the panel's size changes once, then one layout and
    /// display pass.
    private func oneResize(_ configure: (GlossLab) -> Void) -> Count {
        let lab = GlossLab.shared
        lab.allOff(); lab.resetSliders()
        configure(lab)
        let (panel, view) = host()
        defer { panel.orderOut(nil); panel.close() }
        spin()
        GlossLabCounters.reset()
        panel.setContentSize(CGSize(width: 380, height: 590))
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        spin()
        return Count(stage: GlossLabCounters.stageSurface, surface: GlossLabCounters.surfaceLayer,
                     rim: GlossLabCounters.rimLayer, controlLight: GlossLabCounters.controlEdgeLight)
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
        let (panel, view) = host()
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
                    + GlossLabCounters.controlEdgeLight
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
}
#endif
