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

extension View {
    /// Native effects stay hidden, including legacy geometry test injection.
    func atticScrollEdgeEffect(_ style: AtticScrollEdgeStyle) -> some View {
        scrollEdgeEffectHidden(true, for: .all)
    }
}

// MARK: - Content scrolls under the fixed controls (A15, shared)

/// Scroll-under fade, revised (owner, 2026-10-06: "those are just controls
/// and are fine"): scrolling content runs under the fixed glass controls at
/// full strength, with no fade; the glass keeps its own icons readable. A
/// short fade stays only where scrolled text would sit behind plain text
/// that has no glass of its own (Tasks' Now · Later · Done line, All notes'
/// label line): faint across that text's own height, back to full within a
/// few points either side. At the panel's own top and bottom edges content
/// dissolves into the edge over a short band (round 4), so the rounded edge
/// never slices a line. An opacity mask over the scroll view, static
/// geometry: no blur, no per-scroll state, and no native soft edge. Resting
/// places are unchanged.
enum AtticScrollUnderFade {
    /// Behind a line of plain text (scrolled text stays faintly there).
    static let behindText: Double = 0.10
    /// From faint to full on either side of that line.
    static let textRamp: CGFloat = 6
    /// At the panel's very edge: as faint as behind plain text. (Nearer
    /// nothing, a list's kept pages stopped being built while idle in the
    /// hosted pager tests, so the floor stays at a value they pass with.)
    static let edgeFloor: Double = 0.10
    /// The eased ramp's samples at the panel's edges.
    private static let edgeSamples: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]

    static func ease(_ t: CGFloat) -> Double { Double(t * t * (3 - 2 * t)) }

    /// The mask's stops for a view `height` tall: locations 0…1, opacity.
    /// `plainText` holds the vertical spans (in the view's space) of plain
    /// text lines over the content; `topEdge` and `bottomEdge` are the
    /// bands at the panel's own edges where content dissolves into the edge
    /// (owner, 2026-10-06: "some sort of fade-away effect there"), eased from
    /// `edgeFloor` at the edge to full at the band's inner end (about the middle
    /// of the header's controls and of the bottom row). Everywhere else,
    /// glass included, is full.
    static func stops(height: CGFloat, plainText: [ClosedRange<CGFloat>],
                      topEdge: CGFloat = 0, bottomEdge: CGFloat = 0) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        var ys: [CGFloat] = [0, height]
        if topEdge > 0 { ys += edgeSamples.map { $0 * topEdge } }
        if bottomEdge > 0 { ys += edgeSamples.map { height - $0 * bottomEdge } }
        for band in plainText {
            ys += [band.lowerBound - textRamp, band.lowerBound, band.upperBound, band.upperBound + textRamp]
        }
        var result: [(location: CGFloat, opacity: Double)] = []
        for y in Set(ys.filter { $0 >= 0 && $0 <= height }).sorted() {
            result.append((y / height, opacity(at: y, height: height, plainText: plainText,
                                               topEdge: topEdge, bottomEdge: bottomEdge)))
        }
        return result
    }

    /// The profile's opacity at `y`, straight from the edges and the bands.
    static func opacity(at y: CGFloat, height: CGFloat, plainText: [ClosedRange<CGFloat>],
                        topEdge: CGFloat = 0, bottomEdge: CGFloat = 0) -> Double {
        var value = 1.0
        if topEdge > 0, y < topEdge { value = min(value, edgeFloor + (1 - edgeFloor) * ease(max(y, 0) / topEdge)) }
        if bottomEdge > 0, y > height - bottomEdge { value = min(value, edgeFloor + (1 - edgeFloor) * ease(max(height - y, 0) / bottomEdge)) }
        for band in plainText {
            if band.contains(y) { value = min(value, behindText); continue }
            let distance = y < band.lowerBound ? band.lowerBound - y : y - band.upperBound
            if distance < textRamp { value = min(value, behindText + (1 - behindText) * Double(distance / textRamp)) }
        }
        return value
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
    let plainText: [ClosedRange<CGFloat>]
    var topEdge: CGFloat = 0
    var bottomEdge: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: AtticScrollUnderFade.stops(height: proxy.size.height, plainText: plainText,
                                                  topEdge: topEdge, bottomEdge: bottomEdge)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// This scrolling content runs under the fixed controls, faint only
    /// behind lines of plain text (see `AtticScrollUnderFade`).
    func atticScrollUnderFade(plainText: [ClosedRange<CGFloat>], topEdge: CGFloat = 0, bottomEdge: CGFloat = 0) -> some View {
        mask { AtticScrollUnderMask(plainText: plainText, topEdge: topEdge, bottomEdge: bottomEdge) }
    }
}
