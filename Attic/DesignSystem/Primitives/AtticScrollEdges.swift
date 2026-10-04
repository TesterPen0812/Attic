import SwiftUI

// MARK: - Scroll edges before controls (D1, 2026-10-02; Clean cut, 2026-10-03)

/// Tasks and Done use Clean cut with D1's fade before fixed controls.
/// The owner disabled the native soft edge everywhere (overnight A1,
/// 2026-10-04), including saved preview choices and environment overrides.
/// The soft-edge primitive remains for explicit isolated geometry tests;
/// no app setting offers it. Notes editor and All notes also keep D1 with
/// no native soft effect.
enum AtticScrollEdgeStyle: String, CaseIterable, Sendable {
    case systemSoft
    case cleanCut

    /// The developer panel's words (preview-only, not localized).
    var title: String {
        switch self {
        case .systemSoft: "System soft edge"
        case .cleanCut: "Clean cut"
        }
    }
}

/// The app's edge policy: always initialize to Clean cut, without reading
/// or rewriting a former preview A/B preference. No identity offers the
/// switch. Tests can explicitly exercise the dormant native primitive.
@MainActor
final class AtticScrollEdgeLab: ObservableObject {
    static let shared = AtticScrollEdgeLab(defaults: .standard,
                                           environment: ProcessInfo.processInfo.environment,
                                           isPreview: AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier))

    @Published var style: AtticScrollEdgeStyle = .cleanCut
    let offersChoice = false
    static let styleKey = "AtticScrollEdgeStyle"

    init(defaults: UserDefaults, environment: [String: String] = [:], isPreview: Bool) {}
}

/// Activates Apple's native edge in an empty gap inside the viewport.
/// The tiny fill remains necessary: a clear bar produces no pocket on the
/// installed SDK/runtime. This is a compatibility dependency; the hosted
/// tests assert native pockets, while CI checks actual rendered row ink.
/// Controls are hosted separately, preserving their native hit points.
struct AtticScrollEdgeBar: View {
    let height: CGFloat

    var body: some View {
        Color.black.opacity(0.001)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// No system effect (Clean cut, the default), or native soft edges.
    @ViewBuilder
    func atticScrollEdgeEffect(_ style: AtticScrollEdgeStyle) -> some View {
        switch style {
        case .systemSoft: scrollEdgeEffectStyle(.soft, for: .vertical)
        case .cleanCut: scrollEdgeEffectHidden(true, for: .all)
        }
    }
}

// MARK: - Content fades before fixed controls (D1, shared)

/// D1 (owner, 2026-10-02) for a page whose content scrolls between fixed
/// controls: an opacity mask over the scroll view, the mechanism Tasks'
/// lists use (`TasksViewport.maskStops`). Nothing shows above `clearTop`
/// (the controls at the top); the content comes back along the edge veil's
/// eased ramp over the last `softEdge` before `restTop`, where its first
/// line rests; it recedes along the same ramp over the `softEdge` before
/// the bottom controls' top (`bottomControls` up from the bottom edge) and
/// nothing shows under them. A cheap opacity mask: no blur, no per-scroll
/// state. It works with either scroll edge style; Notes passes Clean cut
/// (owner, 2026-10-03: the native soft edge is off by default).
enum AtticControlsFade {
    /// The length of the softened edge where content meets a control band.
    static let softEdge: CGFloat = 6

    /// Opacity at `depth` into the ramp (0: fully there, 1: gone).
    static func opacity(atDepth depth: Double) -> Double {
        1 - AtticEdgeBlur.veil(at: depth) / AtticEdgeBlur.maximumVeil
    }

    /// The mask's stops for a view `height` tall: locations 0…1, opacity.
    static func stops(height: CGFloat, restTop: CGFloat, bottomControls: CGFloat) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        let clear = max(0, restTop - softEdge)
        let barTop = max(height - bottomControls, restTop)
        let fadeStart = max(barTop - softEdge, restTop)
        var points: [(CGFloat, Double)] = [(0, 0), (clear, 0)]
        for stop in AtticEdgeBlur.veilStops.reversed() where stop.location < 1 {
            points.append((restTop - (restTop - clear) * CGFloat(stop.location), opacity(atDepth: stop.location)))
        }
        points.append((restTop, 1))
        points.append((fadeStart, 1))
        for stop in AtticEdgeBlur.veilStops where stop.location > 0 && stop.location < 1 {
            points.append((fadeStart + (barTop - fadeStart) * CGFloat(stop.location), opacity(atDepth: stop.location)))
        }
        points.append((barTop, 0))
        points.append((height, 0))
        var result: [(location: CGFloat, opacity: Double)] = []
        var last: CGFloat = -1
        for (y, opacity) in points {
            let location = min(max(y / height, 0), 1)
            guard location > last || result.isEmpty else { continue }
            result.append((location, opacity))
            last = location
        }
        return result
    }
}

/// The D1 mask (`AtticControlsFade`), sized to the view it masks.
struct AtticControlsFadeMask: View {
    /// Where the first line rests, from the view's top.
    let restTop: CGFloat
    /// The bottom controls' top, up from the view's bottom edge.
    let bottomControls: CGFloat

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: AtticControlsFade.stops(height: proxy.size.height, restTop: restTop, bottomControls: bottomControls)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// D1: this scrolling content fades out before the fixed controls (see
    /// `AtticControlsFade`).
    func atticControlsFade(restTop: CGFloat, bottomControls: CGFloat) -> some View {
        mask { AtticControlsFadeMask(restTop: restTop, bottomControls: bottomControls) }
    }
}
