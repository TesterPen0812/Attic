import SwiftUI

// MARK: - Scroll edges before controls (D1 / D4b, 2026-10-02)

/// Native soft edges, inside each list's visible viewport. Tasks excludes
/// the header and the entire measured bottom control stack from that
/// viewport, then clips the native pocket before the excluded space.
/// Small drawing marker bars occupy only the empty resting gaps inside
/// the viewport: no row ink can reach a control, and the first/last rows
/// rest beyond the native fade. Clean cut retains the earlier mask as a
/// preview-only A/B baseline.
///
/// macOS 27 off-screen probe: `.soft` on a bare padded ScrollView produces
/// no NSScrollPocket. A drawing `safeAreaBar` is still needed to activate
/// the native effect; Attic adds no blur or per-scroll SwiftUI state.
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

/// The scroll edge style, live. Only a strict preview identity can leave the
/// system soft edge (`AtticPreviewOverrides.isPreviewIdentity`: `com.taha.Attic.preview.` and a
/// name, with no `--attic-motion-lab` way in, unlike the Motion Lab's own
/// broader policy): its developer panel (Settings › General › Motion Lab)
/// shows the switch, the choice is kept in the preview's own defaults, and UI
/// tests can force one with `ATTIC_UI_TEST_SCROLL_EDGES` (`soft` or `clean`).
/// The official identity and every other one always resolve to the system soft
/// edge, whatever the environment, the defaults or the launch arguments say,
/// show no switch and keep nothing.
@MainActor
final class AtticScrollEdgeLab: ObservableObject {
    static let shared = AtticScrollEdgeLab(defaults: .standard,
                                           environment: ProcessInfo.processInfo.environment,
                                           isPreview: AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier))

    @Published var style: AtticScrollEdgeStyle {
        didSet { defaults?.set(style.rawValue, forKey: Self.styleKey) }
    }

    /// Whether the developer panel offers the choice (a strict preview).
    let offersChoice: Bool
    /// The preview's own defaults; nil outside a preview, where nothing is kept.
    private let defaults: UserDefaults?
    static let styleKey = "AtticScrollEdgeStyle"

    init(defaults: UserDefaults, environment: [String: String] = [:], isPreview: Bool) {
        offersChoice = isPreview
        self.defaults = isPreview ? defaults : nil
        var style = AtticScrollEdgeStyle.systemSoft
        if isPreview {
            style = defaults.string(forKey: Self.styleKey).flatMap(AtticScrollEdgeStyle.init(rawValue:)) ?? .systemSoft
            #if DEBUG
            switch environment["ATTIC_UI_TEST_SCROLL_EDGES"] {
            case "soft": style = .systemSoft
            case "clean": style = .cleanCut
            default: break
            }
            #endif
        }
        self.style = style
    }
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
    /// Native soft edges, or no system effect for the Clean cut baseline.
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
