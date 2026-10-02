import Foundation

// MARK: - Preview-only A/B switches (owner, 2026-10-02)

/// Environment switches that undo one change at a time, so the on-screen
/// performance gate can A/B a single difference on one build
/// (`Scripts/perf_onscreen.zsh --candidate-env ATTIC_UI_TEST_HOVER=off`).
/// They exist only in a strict preview identity
/// (`com.taha.Attic.preview.` and a name, `isPreviewIdentity`): the official
/// identity and every other one ignore all of them, whatever the environment
/// says, and with none set nothing differs from the product. A value that is
/// not one of the listed words is ignored.
///
/// | Variable | Values | Reverts |
/// |---|---|---|
/// | `ATTIC_UI_TEST_MOTION` | `calm`, `lively`, `subtle`, `reduced` | the motion feel (Calm is c2b41d0's: no bounce on navigation) |
/// | `ATTIC_UI_TEST_SCROLLERS` | `system`, `overlay` | thin overlay scrollers, hidden during swipes (round 13: the system's own) |
/// | `ATTIC_UI_TEST_HOVER` | `tint`, `off` | the pointer's row tint |
/// | `ATTIC_UI_TEST_LIFT` | `on`, `off` | the reorder card's layer over the page |
///
/// (`ATTIC_UI_TEST_SCROLL_EDGES`, `soft` or `clean`, is the scroll edge lab's.)
struct AtticPreviewOverrides: Equatable, Sendable {
    enum Motion: String, Sendable {
        case calm, lively, subtle, reduced

        /// The Animations level this stands for (Calm is a feel Animations
        /// has no level for: it runs with motion on).
        var level: AtticAnimationLevel {
            switch self {
            case .calm, .lively: .lively
            case .subtle: .subtle
            case .reduced: .reduced
            }
        }

        var feel: AtticMotionFeel {
            switch self {
            case .calm: .calm
            case .lively: .lively
            case .subtle, .reduced: .subtle
            }
        }
    }

    enum Scrollers: String, Sendable { case system, overlay }
    enum Hover: String, Sendable { case tint, off }
    enum Lift: String, Sendable { case on, off }

    var motion: Motion?
    var scrollers: Scrollers?
    var hover: Hover?
    var lift: Lift?

    /// Thin overlay scrollers, hidden during swipes (the product's way).
    var stylesScrollers: Bool { scrollers != .system }
    /// The pointer tints the row it is on (the product's way).
    var rowHoverTints: Bool { hover != .off }
    /// The reorder card's layer is on the page (the product's way).
    var drawsLiftLayer: Bool { lift != .off }

    static let none = AtticPreviewOverrides()

    /// `com.taha.Attic.preview.` and a non-empty name; launch arguments never
    /// widen it (the Motion Lab's own policy is broader).
    nonisolated static func isPreviewIdentity(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let prefix = AtticMotionLab.previewPrefix
        return bundleIdentifier.hasPrefix(prefix) && bundleIdentifier.count > prefix.count
    }

    nonisolated static func resolve(environment: [String: String], bundleIdentifier: String?) -> AtticPreviewOverrides {
        guard isPreviewIdentity(bundleIdentifier) else { return .none }
        return AtticPreviewOverrides(
            motion: environment["ATTIC_UI_TEST_MOTION"].flatMap(Motion.init(rawValue:)),
            scrollers: environment["ATTIC_UI_TEST_SCROLLERS"].flatMap(Scrollers.init(rawValue:)),
            hover: environment["ATTIC_UI_TEST_HOVER"].flatMap(Hover.init(rawValue:)),
            lift: environment["ATTIC_UI_TEST_LIFT"].flatMap(Lift.init(rawValue:))
        )
    }

    /// This process's.
    nonisolated static let current = resolve(environment: ProcessInfo.processInfo.environment,
                                             bundleIdentifier: Bundle.main.bundleIdentifier)
}

// MARK: - Dropdown capture seam (E1, 2026-10-02)

/// `ATTIC_UI_TEST_POPOVER=slash|slash-da|date|tag|priority`, with
/// `ATTIC_UI_TESTING=1`, in a strict preview identity only: opens one
/// dropdown by itself on a seeded note or task, for hands-off captures.
/// `slash`, `slash-da` and `date` show Notes (the `/` list, "/da" filtered
/// to Date, the date card with "fri"); `tag` and `priority` show the Tasks
/// composer strip's picker over the draft "Pay rent". The official identity
/// and every other one ignore it.
enum AtticDropdownCaptureSeam: String, CaseIterable, Sendable {
    case slash
    case slashDa = "slash-da"
    case date
    case tag
    case priority

    /// The page it opens on.
    var page: String { self == .tag || self == .priority ? "tasks" : "notes" }

    /// The Notes capture scene that shows it (`NoteFormatCaptureScene`).
    var notesScene: String? {
        switch self {
        case .slash: "slash-lead"
        case .slashDa: "slash-da"
        case .date: "date-lead"
        case .tag, .priority: nil
        }
    }

    nonisolated static func resolve(environment: [String: String], bundleIdentifier: String?) -> AtticDropdownCaptureSeam? {
        guard environment["ATTIC_UI_TESTING"] == "1",
              AtticPreviewOverrides.isPreviewIdentity(bundleIdentifier) else { return nil }
        return environment["ATTIC_UI_TEST_POPOVER"].flatMap(AtticDropdownCaptureSeam.init(rawValue:))
    }

    /// This process's.
    nonisolated static let current = resolve(environment: ProcessInfo.processInfo.environment,
                                             bundleIdentifier: Bundle.main.bundleIdentifier)
}
