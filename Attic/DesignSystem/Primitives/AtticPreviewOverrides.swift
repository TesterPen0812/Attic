import Foundation

// MARK: - Preview-only A/B switches (owner, 2026-10-02)

/// Environment switches that undo one change at a time, so the on-screen
/// performance gate can A/B a single difference on one build.
/// They exist only in a strict preview identity
/// (`com.taha.Attic.preview.` and a name, `isPreviewIdentity`): the official
/// identity and every other one ignore all of them, whatever the environment
/// says, and with none set nothing differs from the product. A value that is
/// not one of the listed words is ignored.
///
/// | Variable | Values | Reverts |
/// |---|---|---|
/// | `ATTIC_UI_TEST_SCROLLERS` | `system`, `overlay` | thin overlay scrollers, hidden during swipes (round 13: the system's own) |
/// | `ATTIC_UI_TEST_LIFT` | `on`, `off` | the reorder card's layer over the page |
///
struct AtticPreviewOverrides: Equatable, Sendable {
    enum Scrollers: String, Sendable { case system, overlay }
    enum Lift: String, Sendable { case on, off }

    var scrollers: Scrollers?
    var lift: Lift?

    /// Thin overlay scrollers, hidden during swipes (the product's way).
    var stylesScrollers: Bool { scrollers != .system }
    /// The reorder card's layer is on the page (the product's way).
    var drawsLiftLayer: Bool { lift != .off }

    static let none = AtticPreviewOverrides()

    /// `com.taha.Attic.preview.` and a non-empty name; launch arguments never
    /// widen it.
    nonisolated static func isPreviewIdentity(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let prefix = AtticMotionLab.previewPrefix
        return bundleIdentifier.hasPrefix(prefix) && bundleIdentifier.count > prefix.count
    }

    nonisolated static func resolve(environment: [String: String], bundleIdentifier: String?) -> AtticPreviewOverrides {
        guard isPreviewIdentity(bundleIdentifier) else { return .none }
        return AtticPreviewOverrides(
            scrollers: environment["ATTIC_UI_TEST_SCROLLERS"].flatMap(Scrollers.init(rawValue:)),
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
    /// The add bar's date card (the same month as Notes' `/date`).
    case taskDate = "task-date"

    /// The page it opens on.
    var page: String { self == .tag || self == .priority || self == .taskDate ? "tasks" : "notes" }

    /// The Notes capture scene that shows it (`NoteFormatCaptureScene`).
    var notesScene: String? {
        switch self {
        case .slash: "slash-lead"
        case .slashDa: "slash-da"
        case .date: "date-lead"
        case .tag, .priority, .taskDate: nil
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
