import SwiftUI

// MARK: - Scroll edges under floating controls (owner, 2026-10-01)

/// How a list meets the floating controls at its top and bottom edges.
///
/// - **System soft edge** (the default, and the only one outside previews):
///   macOS 26's own scroll edge effect, soft style. The controls' zones are
///   the list's bars (`safeAreaBar`, `AtticScrollEdgeBar`), so SwiftUI gives
///   its scroll view a pocket at each edge (AppKit's `NSScrollPocket`): what
///   scrolls under a bar is progressively blurred and faded toward the
///   panel's edge (a variable blur). The window server draws it; Attic
///   re-renders nothing. The pocket is its bar's height, and its fade is a
///   straight ramp over that height (measured in-process, 2026-10-02: the
///   pocket's backdrop is masked by a linear gradient from clear at the
///   bar's inner edge to 0.85 at the panel's edge, reaching about 10 pt
///   past the bar while content is under it). A control near the bar's
///   inner edge, such as the tabs' line, sits where the fade is weakest.
/// - **Clean cut** (round 13, preview builds only, to compare): no bars and
///   no system effect; the list's own mask cuts rows cleanly at the
///   controls' bands. The controls float over the list in both.
///
/// What the SDK offers (Xcode 27, macOS 27 SDK): SwiftUI's
/// `scrollEdgeEffectStyle(_:for:)` (`.automatic`, `.soft`, `.hard`),
/// `scrollEdgeEffectHidden(_:for:)` and `safeAreaBar(edge:alignment:spacing:)`;
/// AppKit's `NSScrollEdgeEffectStyle` only through
/// `NSTitlebarAccessoryViewController` and
/// `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle`
/// (a titled window or a split view; the panel is a borderless `NSPanel`).
/// `NSScrollView` has no public edge-effect property, so an AppKit scroll
/// view (the note editor) cannot take it, and neither does SwiftUI's
/// `TextEditor`. A pocket appears only for a SwiftUI `ScrollView` under a
/// bar that draws something: a clear, hidden or zero-opacity bar gets none,
/// and neither do `safeAreaInset` or `contentMargins`.
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

/// A list's bar under floating controls (`safeAreaBar` content): it marks
/// the controls' zone, so the list's scroll view gets the system's edge
/// effect there, and the controls themselves float over the list in the
/// page's own layer.
///
/// Where the bars go, and what did not work (CI, 2026-10-01). Making the
/// controls themselves the bar did not work: SwiftUI hosts a bar's content in
/// a separate AppKit container, XCUITest found no hit point on the add bar's
/// text view, and typing cost about 1.5 ms more per keystroke. Marker bars on
/// the pager, with the controls floating over it, did not work either: the
/// same hit point was still missing. What works is a marker bar on each list
/// (`tasksListEdges`), the controls floating over the pager as before; the
/// add bar has a hit point and every UI test passes (CI run 36910820304). The
/// exact obstruction at the pager's level is an inference, not established.
///
/// Why a faint fill: SwiftUI makes a bar's pocket only for a bar that draws
/// something (measured: a clear, hidden or zero-opacity bar gets none), so
/// the bar draws an imperceptible one, opacity 0.001. That rests on
/// undocumented SwiftUI behaviour, a compatibility risk: `ScrollEdgeTests`
/// checks that the pockets exist (their structure), not how they look, so an
/// SDK that stops treating the fill as content fails that test only if the
/// pockets vanish, and a change in appearance needs the on-screen captures.
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
    /// A list's top and bottom edges: the system's soft scroll edge effect
    /// under its bars, or (clean cut) none, its own mask doing the cut.
    @ViewBuilder
    func atticScrollEdgeEffect(_ style: AtticScrollEdgeStyle) -> some View {
        switch style {
        case .systemSoft: scrollEdgeEffectStyle(.soft, for: .vertical)
        case .cleanCut: scrollEdgeEffectHidden(true, for: .all)
        }
    }
}
