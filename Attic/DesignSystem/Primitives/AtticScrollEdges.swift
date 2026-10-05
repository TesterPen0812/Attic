import SwiftUI

// MARK: - Scroll edges before controls (D1, 2026-10-02; Clean cut, 2026-10-03)

/// Tasks and Done use Clean cut with the scroll-under fade (A15).
/// The owner disabled the native soft edge everywhere (overnight A1,
/// 2026-10-04), including saved preview choices and environment overrides.
/// Former soft-edge choices also resolve to Clean cut. Notes editor,
/// All notes and E1 cards use clean edges too.
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
/// switch. Even a choice injected in code stays on Clean cut.
@MainActor
final class AtticScrollEdgeLab: ObservableObject {
    static let shared = AtticScrollEdgeLab(defaults: .standard,
                                           environment: ProcessInfo.processInfo.environment,
                                           isPreview: AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier))

    @Published private var resolvedStyle: AtticScrollEdgeStyle = .cleanCut
    var style: AtticScrollEdgeStyle {
        get { resolvedStyle }
        set { resolvedStyle = .cleanCut }
    }
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
    /// Native effects stay hidden, including legacy geometry test injection.
    func atticScrollEdgeEffect(_ style: AtticScrollEdgeStyle) -> some View {
        scrollEdgeEffectHidden(true, for: .all)
    }
}

// MARK: - Content scrolls under the fixed controls (A15, shared)

/// Scroll-under fade (owner, 2026-10-04, option A of the p2-27 draft; it
/// replaces D1's "rows fade out before the controls"): scrolling content
/// runs under the fixed controls at the top (pin, page button, the tabs or
/// label line with Find and View Options) and the bottom (add bar, strip,
/// selection bar), staying faintly visible as it fades, so the Liquid Glass
/// controls pick up the content moving behind them. An opacity mask over
/// the scroll view, static geometry: no blur, no per-scroll state, and no
/// native soft edge. Resting places are unchanged: the first line rests at
/// `restTop` and the last `restBottom` up from the bottom, both fully there.
///
/// The profile is the draft's: about 6 % at the panel's edges, 10 % over
/// the controls' middle, 22 % at their inner edge (`topBand`, the bottom of
/// the top controls' labels; `bottomBand`, the bottom controls' top), and
/// an eased rise to full at the resting places. Under Reduce Transparency
/// the glass is opaque and hides what passes beneath, as intended.
enum AtticScrollUnderFade {
    /// At the panel's top and bottom edges.
    static let edgeOpacity: Double = 0.06
    /// Over the top controls' middle (the page buttons' lower part).
    static let overTopControls: Double = 0.10
    /// Over the bottom controls' middle (the add bar).
    static let overBottomControls: Double = 0.08
    /// At the controls' inner edge, where the eased rise to full starts.
    static let controlsEdge: Double = 0.22
    /// Where the "over the controls" stop sits, as a fraction of the band.
    static let bandMiddle: CGFloat = 0.6

    /// The eased rise's samples (smoothstep), from `controlsEdge` to 1.
    private static let rise: [CGFloat] = [0.25, 0.5, 0.75]

    static func ease(_ t: CGFloat) -> Double { Double(t * t * (3 - 2 * t)) }

    /// The mask's stops for a view `height` tall: locations 0…1, opacity.
    static func stops(height: CGFloat, topBand: CGFloat, restTop: CGFloat,
                      bottomBand: CGFloat, restBottom: CGFloat) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        let upperEdge = min(max(topBand, 0), restTop)
        let fullTop = max(restTop, upperEdge)
        let barTop = max(height - bottomBand, fullTop)
        let fullBottom = min(max(height - restBottom, fullTop), barTop)
        var points: [(CGFloat, Double)] = [(0, edgeOpacity),
                                           (upperEdge * bandMiddle, overTopControls),
                                           (upperEdge, controlsEdge)]
        for t in rise {
            points.append((upperEdge + (fullTop - upperEdge) * t, controlsEdge + (1 - controlsEdge) * ease(t)))
        }
        points.append((fullTop, 1))
        points.append((fullBottom, 1))
        for t in rise.reversed() {
            points.append((barTop - (barTop - fullBottom) * t, controlsEdge + (1 - controlsEdge) * ease(t)))
        }
        points.append((barTop, controlsEdge))
        points.append((height - (height - barTop) * bandMiddle, overBottomControls))
        points.append((height, edgeOpacity))
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

    /// The mask's opacity at `y` (linear between stops, as the gradient).
    static func opacity(_ stops: [(location: CGFloat, opacity: Double)], at y: CGFloat, height: CGFloat) -> Double {
        let x = y / height
        guard let first = stops.first, x > first.location else { return stops.first?.opacity ?? 1 }
        for (a, b) in zip(stops, stops.dropFirst()) where x <= b.location {
            let t = Double((x - a.location) / max(b.location - a.location, 0.000001))
            return a.opacity + (b.opacity - a.opacity) * min(max(t, 0), 1)
        }
        return stops.last?.opacity ?? 1
    }
}

/// The scroll-under mask (`AtticScrollUnderFade`), sized to the view it masks.
struct AtticScrollUnderMask: View {
    let topBand: CGFloat
    let restTop: CGFloat
    let bottomBand: CGFloat
    let restBottom: CGFloat

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: AtticScrollUnderFade.stops(height: proxy.size.height, topBand: topBand, restTop: restTop,
                                                  bottomBand: bottomBand, restBottom: restBottom)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// This scrolling content runs under the fixed controls and fades
    /// there (see `AtticScrollUnderFade`).
    func atticScrollUnderFade(topBand: CGFloat, restTop: CGFloat, bottomBand: CGFloat, restBottom: CGFloat) -> some View {
        mask { AtticScrollUnderMask(topBand: topBand, restTop: restTop, bottomBand: bottomBand, restBottom: restBottom) }
    }
}
