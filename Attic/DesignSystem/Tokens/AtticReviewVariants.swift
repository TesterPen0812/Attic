import Foundation

// MARK: - Temporary review switches

/// The owner's rule for a change that departs from one of their decisions:
/// it is built behind a switch, so they can flip it and pick. The switch
/// defaults to the suggestion (on); off is exactly the design they decided.
///
/// Every switched look reads its switch here, through the design context
/// (`AtticDesignContext.variants`), never with a check of its own, so
/// retiring a switch is one small diff: delete its case, keep the branch
/// the owner picked. The list and how to remove each one:
/// `attic-redesign-assets/phase1/review-switches.md`.
enum AtticReviewVariant: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Astra 11: Glass and Frosted keep enough of their own surface colour
    /// behind the text that titles keep 4.5 : 1 and secondary text 3 : 1
    /// over the black, mid-grey and white desktops it is solved against
    /// (the primary and secondary greys; tag accents keep their named
    /// exceptions). Off: Phase 0's see-through surfaces, exactly.
    case readableGlass
    /// Astra 27: out-of-focus drawn controls keep one readable edge instead
    /// of the nested inner rim and the lower-edge shadow. Off: today's drawn
    /// controls.
    case quietInactiveControls
    /// Astra 26: Appearance settings start 24 pt under the header (not 52)
    /// and show Surface and tint before Palette. Off: today's page.
    case compactAppearance
    /// Astra 25: Phase 1 names what the commands open today: "Search Done
    /// Tasks…", "Open Files…" (a live task) and "Show Details" (a Done log
    /// task). Shortcuts and identifiers are unchanged. Off: "Search", "Open
    /// Page".
    case explicitPhase1Labels
    /// CU review, visual 4: Dark Glass and Frosted panels get a clearer
    /// palette-coloured edge and a faint inner highlight, so the surface
    /// stays separate from what is behind it (Dark Porcelain Vapor on
    /// Frosted read as one flat grey). Off: Phase 0's 0.75 pt hairline.
    case definedDarkEdge

    var id: String { rawValue }

    /// The row's title in Settings › Compare (temporary).
    var title: String {
        switch self {
        case .readableGlass: String(localized: "Readable Glass")
        case .quietInactiveControls: String(localized: "Quiet Inactive Controls")
        case .compactAppearance: String(localized: "Compact Appearance")
        case .explicitPhase1Labels: String(localized: "Explicit Phase 1 Labels")
        case .definedDarkEdge: String(localized: "Defined Dark Edge")
        }
    }

    /// One line under the row: what on and off do.
    var summary: String {
        switch self {
        case .readableGlass:
            String(localized: "On: Glass and Frosted keep enough backing that titles and secondary text keep their contrast over black, grey and white desktops (tag accents excepted). Off: Phase 0’s surfaces exactly.")
        case .quietInactiveControls:
            String(localized: "On: out-of-focus controls on Solid keep one quiet edge. Off: the nested rim and heavier shadow.")
        case .compactAppearance:
            String(localized: "On: Appearance starts closer to the header, with Surface and tint before Palette. Off: today’s spacing and order.")
        case .explicitPhase1Labels:
            String(localized: "On: “Search Done Tasks…”, “Open Files…” and “Show Details”. Off: “Search” and “Open Page”.")
        case .definedDarkEdge:
            String(localized: "On: Dark Glass and Frosted panels keep a clearer edge in the palette’s colour. Off: Phase 0’s faint hairline.")
        }
    }

    /// The suggestion is on until the owner picks.
    var defaultIsOn: Bool { true }

    /// For UI tests and automation.
    var identifier: String { "setting-review-\(rawValue)" }
}

/// Which review switches are on. Carried in the design context, so every
/// switched look (colours, spacing, order, words) follows one value and
/// changes live when a switch flips.
struct AtticReviewVariants: Hashable, Sendable {
    private(set) var on: Set<AtticReviewVariant>

    init(on: Set<AtticReviewVariant>) {
        self.on = on
    }

    /// The suggestions (the app's default until the owner picks).
    static let defaults = AtticReviewVariants(on: Set(AtticReviewVariant.allCases.filter(\.defaultIsOn)))
    /// Every switch off: exactly the design the owner decided.
    static let decided = AtticReviewVariants(on: [])

    func isOn(_ variant: AtticReviewVariant) -> Bool { on.contains(variant) }

    mutating func set(_ variant: AtticReviewVariant, _ isOn: Bool) {
        if isOn { on.insert(variant) } else { on.remove(variant) }
    }

    func with(_ variant: AtticReviewVariant, _ isOn: Bool) -> AtticReviewVariants {
        var copy = self
        copy.set(variant, isOn)
        return copy
    }

    // MARK: Persistence (AppSettings)

    /// Stored as the switches that differ from their default, so a switch
    /// added later starts at its default and a removed one is ignored.
    var storedOverrides: [String: Bool] {
        Dictionary(uniqueKeysWithValues: AtticReviewVariant.allCases
            .filter { isOn($0) != $0.defaultIsOn }
            .map { ($0.rawValue, isOn($0)) })
    }

    init(storedOverrides: [String: Any]?) {
        var variants = Self.defaults
        for (key, value) in storedOverrides ?? [:] {
            guard let variant = AtticReviewVariant(rawValue: key), let isOn = value as? Bool else { continue }
            variants.set(variant, isOn)
        }
        self = variants
    }
}

// MARK: - Switched words (Explicit Phase 1 Labels)

/// The Phase 1 command names the Explicit Phase 1 Labels switch changes.
/// Only the words change: shortcuts, identifiers and what the commands do
/// stay the same either way.
enum AtticPhase1Labels {
    /// The menu-bar item's search (it opens the Done page's search).
    static func search(_ variants: AtticReviewVariants) -> String {
        variants.isOn(.explicitPhase1Labels) ? String(localized: "Search Done Tasks…") : String(localized: "Search")
    }

    /// A live task's "open" command (its files and details panel until task
    /// pages arrive in Phase 3): menus.
    static func openLiveTask(_ variants: AtticReviewVariants) -> String {
        variants.isOn(.explicitPhase1Labels) ? String(localized: "Open Files…") : String(localized: "Open Page")
    }

    /// The same command as VoiceOver names it and as the quick look shows it
    /// (sentence case).
    static func openLiveTaskAction(_ variants: AtticReviewVariants) -> String {
        variants.isOn(.explicitPhase1Labels) ? String(localized: "Open files") : String(localized: "Open page")
    }

    /// A Done log task's inline details: menus.
    static func showArchivedDetails(_ variants: AtticReviewVariants) -> String {
        variants.isOn(.explicitPhase1Labels) ? String(localized: "Show Details") : String(localized: "Open Page")
    }

    /// The same, as VoiceOver names it.
    static func showArchivedDetailsAction(_ variants: AtticReviewVariants) -> String {
        variants.isOn(.explicitPhase1Labels) ? String(localized: "Show details") : String(localized: "Open page")
    }
}
