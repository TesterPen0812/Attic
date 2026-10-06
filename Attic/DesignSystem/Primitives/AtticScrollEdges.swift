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

/// Scroll-under fade, revised (owner, 2026-10-06: "those are just controls
/// and are fine"): scrolling content runs under the fixed glass controls at
/// full strength, with no fade; the glass keeps its own icons readable. A
/// short fade stays only where scrolled text would sit behind plain text
/// that has no glass of its own (Tasks' Now · Later · Done line, All notes'
/// label line): faint across that text's own height, back to full within a
/// few points either side. An opacity mask over the scroll view, static
/// geometry: no blur, no per-scroll state, and no native soft edge. Resting
/// places are unchanged.
enum AtticScrollUnderFade {
    /// Behind a line of plain text (scrolled text stays faintly there).
    static let behindText: Double = 0.10
    /// From faint to full on either side of that line.
    static let textRamp: CGFloat = 6

    /// The mask's stops for a view `height` tall: locations 0…1, opacity.
    /// `plainText` holds the vertical spans (in the view's space) of plain
    /// text lines over the content; everywhere else is full.
    static func stops(height: CGFloat, plainText: [ClosedRange<CGFloat>]) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        var points: [(CGFloat, Double)] = [(0, opacity(at: 0, plainText: plainText))]
        for band in plainText.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            points += [(band.lowerBound - textRamp, 1), (band.lowerBound, behindText),
                       (band.upperBound, behindText), (band.upperBound + textRamp, 1)]
        }
        points.append((height, opacity(at: height, plainText: plainText)))
        var result: [(location: CGFloat, opacity: Double)] = []
        var last: CGFloat = -1
        for (y, value) in points where y >= 0 && y <= height {
            let location = y / height
            guard location > last || result.isEmpty else { continue }
            result.append((location, value))
            last = location
        }
        return result
    }

    /// The profile's opacity at `y`, straight from the bands.
    private static func opacity(at y: CGFloat, plainText: [ClosedRange<CGFloat>]) -> Double {
        plainText.map { band -> Double in
            if band.contains(y) { return behindText }
            let distance = y < band.lowerBound ? band.lowerBound - y : y - band.upperBound
            guard distance < textRamp else { return 1 }
            return behindText + (1 - behindText) * Double(distance / textRamp)
        }.min() ?? 1
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

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: AtticScrollUnderFade.stops(height: proxy.size.height, plainText: plainText)
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
    func atticScrollUnderFade(plainText: [ClosedRange<CGFloat>]) -> some View {
        mask { AtticScrollUnderMask(plainText: plainText) }
    }
}
