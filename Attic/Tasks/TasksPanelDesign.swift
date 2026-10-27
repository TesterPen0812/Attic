import Foundation

/// The owner's own panel design (Claude Design, 2026-10-27): its state
/// rules, pure so they are tested directly. The drawing is at 2×; every
/// value here is in points (px ÷ 2).
enum TasksPanelDesign {
    /// A day header ("Wed 29 Oct", with the year when it isn't this year).
    static func dayTitle(_ date: Date, sameYear: Bool, calendar: Calendar, locale: Locale) -> String {
        TaskRowPresentation.format(date, template: sameYear ? "EEEdMMM" : "EEEdMMMy", calendar: calendar, locale: locale)
            .replacingOccurrences(of: ",", with: "")
    }

    // MARK: - Date groups (owner, 2026-10-27: yes)

    /// A group of rows under one header.
    enum GroupKind: Hashable, Sendable {
        case overdue
        case today
        /// A later day (Tomorrow, then day headers).
        case day(DueDay)
        case noDate
        /// A Done page day (the day the tasks were finished).
        case finished(Date)
    }

    struct Group: Equatable, Sendable {
        let kind: GroupKind
        let title: String
        /// The overdue header's own colour.
        let isOverdue: Bool
        /// The rows, in the list's order.
        var ids: [UUID]
        /// Rows under a day header show only a time (none in Attic).
        var rowsShowDate: Bool {
            switch kind {
            case .overdue, .today, .noDate: true
            case .day, .finished: false
            }
        }

        /// The key a fold is remembered by (per page).
        var key: String { kind.key }
    }

    /// Now's and Later's groups (the design's `VIEWS`, applied to Attic's
    /// pages): Overdue · Today · each later day (Tomorrow, then "Wed 29
    /// Oct") · No date. Rows keep the list's order inside each group; empty
    /// groups are left out.
    static func groups(_ rows: [(id: UUID, due: DueDay?)], today: DueDay, calendar: Calendar, locale: Locale) -> [Group] {
        var overdue: [UUID] = [], todays: [UUID] = [], noDate: [UUID] = []
        var days: [DueDay: [UUID]] = [:]
        for row in rows {
            guard let due = row.due else { noDate.append(row.id); continue }
            if due < today { overdue.append(row.id) } else if due == today { todays.append(row.id) } else { days[due, default: []].append(row.id) }
        }
        var groups: [Group] = []
        if !overdue.isEmpty { groups.append(Group(kind: .overdue, title: String(localized: "Overdue"), isOverdue: true, ids: overdue)) }
        if !todays.isEmpty { groups.append(Group(kind: .today, title: String(localized: "Today"), isOverdue: false, ids: todays)) }
        let gregorian = DueDay.storageCalendar(matching: calendar)
        let tomorrow = today.startDate(in: gregorian).flatMap { gregorian.date(byAdding: .day, value: 1, to: $0) }
            .map { DueDay(date: $0, calendar: gregorian) }
        for day in days.keys.sorted() {
            let title: String
            if day == tomorrow {
                title = String(localized: "Tomorrow")
            } else if let start = day.startDate(in: gregorian) {
                title = dayTitle(start, sameYear: day.year == today.year, calendar: gregorian, locale: locale)
            } else {
                title = day.rawValue
            }
            groups.append(Group(kind: .day(day), title: title, isOverdue: false, ids: days[day] ?? []))
        }
        if !noDate.isEmpty { groups.append(Group(kind: .noDate, title: String(localized: "No date"), isOverdue: false, ids: noDate)) }
        return groups
    }

    /// The Done page's header for a day ("Mon 27 Oct"), today included.
    static func doneDayTitle(_ day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        return dayTitle(calendar.startOfDay(for: day), sameYear: sameYear, calendar: calendar, locale: locale)
    }

    // MARK: - Tag colour

    /// The oklch hue that stands for a tag's Attic colour (the branch's own
    /// colours are kept; the design's hashed `tagHue` is not used); nil for grey.
    static func oklchHue(for hue: AtticTagHue) -> Double? {
        switch hue.canonical {
        case .yellow: 85
        case .green: 150
        case .pink: 340
        case .purple: 300
        case .grey: nil
        default: 250
        }
    }

    /// The tinted pill's text and fill: `oklch(0.46 0.13 h)` on
    /// `oklch(0.9 0.028 h)` in light; in dark, light text on a deep fill.
    static func tagColours(hue: Double?, dark: Bool) -> (text: AtticRGBA, fill: AtticRGBA) {
        let chroma: (text: Double, fill: Double) = hue == nil ? (0, 0) : (0.13, 0.028)
        let h = hue ?? 0
        if dark {
            return (oklch(0.82, hue == nil ? 0 : 0.10, h), oklch(0.34, hue == nil ? 0 : 0.045, h))
        }
        return (oklch(0.46, chroma.text, h), oklch(0.9, chroma.fill, h))
    }

    /// OKLCH to sRGB (Björn Ottosson's matrices), clipped to the gamut.
    static func oklch(_ l: Double, _ c: Double, _ hDegrees: Double, alpha: Double = 1) -> AtticRGBA {
        let h = hDegrees * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        func encode(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return AtticRGBA(red: encode(r), green: encode(g), blue: encode(bl), alpha: alpha)
    }

    // MARK: - Files

    /// The most files a row draws as tiles.
    static let maxTiles = 6

    /// A file tile's label: its extension, upper case, at most 4 letters.
    static func tileLabel(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return String(ext.uppercased().prefix(4))
    }

    // MARK: - Footer

    /// The footer's turn (the design's `addOpen`): while the add field has
    /// the keyboard, or keeps a draft, the tabs fold away and the field
    /// takes the row.
    static func footerFolded(addFocused: Bool, hasDraft: Bool) -> Bool {
        addFocused || hasDraft
    }

    // MARK: - Empty states

    struct Empty: Equatable {
        let title: String
        let body: String
        /// "Clear filters" shows (a search or a filter hides tasks).
        let canClear: Bool
    }

    /// The design's empty states. Now's and Later's sentences say what
    /// Attic's pages hold (the design's speak of dates, which Attic's
    /// pages are not sorted by).
    static func empty(tab: TasksTab, query: String, filtered: Bool) -> Empty {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return Empty(title: String(localized: "No results"), body: String(localized: "No tasks match “\(query)”."), canClear: true)
        }
        if filtered {
            // Attic's filters are the View options (the design's are lists).
            return Empty(title: String(localized: "No results"), body: String(localized: "Nothing in this view."), canClear: true)
        }
        switch tab {
        case .now:
            return Empty(title: String(localized: "Nothing to do right now"),
                         body: String(localized: "Tasks you add, or bring in from Later, show up here."), canClear: false)
        case .backlog:
            return Empty(title: String(localized: "Nothing scheduled"),
                         body: String(localized: "Tasks you put off for later show up here."), canClear: false)
        case .done:
            return Empty(title: String(localized: "Nothing completed yet"),
                         body: String(localized: "Tasks you check off show up here."), canClear: false)
        }
    }

    // MARK: - Filter chips

    /// A chip under the header: one of the View options' filters.
    struct Chip: Equatable, Identifiable {
        let id: String
        let title: String
        /// What the chip sets (the other filter returns to its default;
        /// the sort is kept).
        let show: TasksViewOptions.Show
        let priority: TasksViewOptions.Priority
    }

    /// The design shows lists, which Attic doesn't have: until the owner
    /// says otherwise the chips are the View options' filters, "All" first.
    static let chips: [Chip] = [
        Chip(id: "all", title: String(localized: "All"), show: .all, priority: .any),
        Chip(id: "due", title: String(localized: "Due or overdue"), show: .dueOrOverdue, priority: .any),
        Chip(id: "overdue", title: String(localized: "Overdue"), show: .overdueOnly, priority: .any),
        Chip(id: "medium", title: String(localized: "Medium and high"), show: .all, priority: .mediumAndHigh),
        Chip(id: "high", title: String(localized: "High"), show: .all, priority: .highOnly),
    ]

    /// The chip a view shows as chosen (nil for a mix the menu made).
    static func selectedChip(for view: TasksViewOptions) -> Chip? {
        chips.first { $0.show == view.show && $0.priority == view.priority }
    }

    /// The view a chip's click leaves: the chip's filter, the sort kept.
    static func view(choosing chip: Chip, from view: TasksViewOptions) -> TasksViewOptions {
        var next = view
        next.show = chip.show
        next.priority = chip.priority
        return next
    }
}

extension TasksPanelDesign.GroupKind {
    /// The key a fold is remembered by (per page).
    var key: String {
        switch self {
        case .overdue: "overdue"
        case .today: "today"
        case let .day(day): "day:\(day.rawValue)"
        case .noDate: "nodate"
        case let .finished(date): "done:\(Int(date.timeIntervalSinceReferenceDate))"
        }
    }
}
