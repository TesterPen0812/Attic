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
