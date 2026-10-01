import SwiftUI

// MARK: - Scroll edges under floating controls (owner, 2026-10-01)

/// How a list meets the floating controls at its top and bottom edges.
///
/// - **System soft edge** (the default, and the only one outside previews):
///   macOS 26's own scroll edge effect, soft style. The controls are the
///   list's bars (`safeAreaBar`), so SwiftUI gives its scroll view a pocket
///   at each edge (AppKit's `NSScrollPocket`): what scrolls under a bar of
///   bare labels is progressively blurred and faded toward the panel's edge
///   (a variable blur), and under a bar of Liquid Glass controls it fades
///   into the background (the glass does its own lensing). The window
///   server draws it; Attic draws nothing of its own and re-renders nothing.
/// - **Clean cut** (round 13, preview builds only, to compare): no bars and
///   no system effect; the list's own mask cuts rows cleanly at the
///   controls' bands.
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

/// The scroll edge style, live: release builds always use the system soft
/// edge; a preview's developer panel (Settings › General › Motion Lab)
/// switches it, kept in the preview's own defaults; UI tests can set it with
/// `ATTIC_UI_TEST_SCROLL_EDGES` (`soft` or `clean`).
@MainActor
final class AtticScrollEdgeLab: ObservableObject {
    static let shared = AtticScrollEdgeLab(defaults: AtticMotionLab.isAvailable ? .standard : nil,
                                           environment: ProcessInfo.processInfo.environment)

    @Published var style: AtticScrollEdgeStyle {
        didSet { defaults?.set(style.rawValue, forKey: Self.styleKey) }
    }

    private let defaults: UserDefaults?
    static let styleKey = "AtticScrollEdgeStyle"

    init(defaults: UserDefaults?, environment: [String: String] = [:]) {
        self.defaults = defaults
        var style = (defaults?.string(forKey: Self.styleKey)).flatMap(AtticScrollEdgeStyle.init(rawValue:)) ?? .systemSoft
        #if DEBUG
        switch environment["ATTIC_UI_TEST_SCROLL_EDGES"] {
        case "soft": style = .systemSoft
        case "clean": style = .cleanCut
        default: break
        }
        #endif
        self.style = style
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
