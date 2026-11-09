import Foundation

/// The owner's own panel design (Claude Design, 2026-10-27): its state
/// rules, pure so they are tested directly. The drawing is at 2×; every
/// value here is in points (px ÷ 2).
enum TasksPanelDesign {
    /// A day header ("Wed 29 Oct", with the year when it isn't this year).
    static func dayTitle(_ date: Date, sameYear: Bool, calendar: Calendar, locale: Locale) -> String {
        AtticDateFormatting.template(date, template: sameYear ? "EEEdMMM" : "EEEdMMMy", calendar: calendar, locale: locale)
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
        /// Backlog rows with a retained date show their own date.
        case backlog
    }

    struct Group: Equatable, Sendable {
        let kind: GroupKind
        let title: String
        /// The overdue header's own colour.
        let isOverdue: Bool
        /// The rows in clock order within each day, with stable ties.
        var ids: [UUID]
        /// Rows under a day header omit the date; time display is deferred.
        var rowsShowDate: Bool {
            switch kind {
            case .overdue, .today, .noDate, .backlog: true
            case .day, .finished: false
            }
        }

        /// Whether the group draws a header (Later's one list has none).
        var showsHeader: Bool { !title.isEmpty }

        /// The key a fold is remembered by (per page).
        var key: String { kind.key }
    }

    /// Now's and Later's groups (the design's `VIEWS`, applied to Attic's
    /// pages): Overdue · Today · each later day (Tomorrow, then "Wed 29
    /// Oct") · No date. Clock order within each day, stable ties; empty
    /// groups are left out.
    static func groups(_ rows: [(id: UUID, due: DueDay?)], times: [UUID: Int] = [:], today: DueDay, calendar: Calendar, locale: Locale) -> [Group] {
        var overdue: [UUID] = [], todays: [UUID] = [], noDate: [UUID] = []
        var days: [DueDay: [UUID]] = [:]
        // Reorder only slots belonging to the same date. This also keeps
        // overdue tasks from different days in their existing relative slots.
        var ordered: [DueDay: [UUID]] = [:]
        if !times.isEmpty {
            for (day, entries) in Dictionary(grouping: rows.filter { $0.due != nil }, by: { $0.due! }) {
                ordered[day] = entries.enumerated().sorted { a, b in
                    let left = times[a.element.id] ?? 1440, right = times[b.element.id] ?? 1440
                    return left == right ? a.offset < b.offset : left < right
                }.map { $0.element.id }
            }
        }
        var offsets: [DueDay: Int] = [:]
        for original in rows {
            var row = original
            if let day = row.due, let ids = ordered[day] {
                let index = offsets[day, default: 0]
                row.id = ids[index]
                offsets[day] = index + 1
            }
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

    /// Backlog retains dated rows. Those display their dates individually;
    /// undated rows remain under the existing "No date" heading.
    static func backlogGroups(_ rows: [(id: UUID, due: DueDay?)]) -> [Group] {
        let dated = rows.filter { $0.due != nil }.map(\.id)
        let undated = rows.filter { $0.due == nil }.map(\.id)
        if dated.isEmpty {
            return undated.isEmpty ? [] : [Group(kind: .backlog, title: String(localized: "No date"), isOverdue: false, ids: undated)]
        }
        var groups = [Group(kind: .backlog, title: "", isOverdue: false, ids: dated)]
        if !undated.isEmpty {
            groups.append(Group(kind: .noDate, title: String(localized: "No date"), isOverdue: false, ids: undated))
        }
        return groups
    }

    /// Now's groups with the next event (Accepted 2026-10-29, "the next
    /// event in Now"): the event sits at the top of Today, so Today shows
    /// for it even with no task due today (after Overdue, before the days).
    static func withTodayForNextEvent(_ groups: [Group]) -> [Group] {
        guard !groups.contains(where: { $0.kind == .today }) else { return groups }
        var groups = groups
        let at = groups.firstIndex { $0.kind != .overdue } ?? groups.endIndex
        groups.insert(Group(kind: .today, title: String(localized: "Today"), isOverdue: false, ids: []), at: at)
        return groups
    }

    /// The day after `today`, in the stored days' calendar.
    static func tomorrow(after today: DueDay, calendar: Calendar) -> DueDay? {
        let gregorian = DueDay.storageCalendar(matching: calendar)
        return today.startDate(in: gregorian).flatMap { gregorian.date(byAdding: .day, value: 1, to: $0) }
            .map { DueDay(date: $0, calendar: gregorian) }
    }

    /// Now's groups while a row is dragged (Adaptive picks, "Drag a task
    /// into another day"; the orchestrator's call): Today and Tomorrow show
    /// as empty headers when no task is due on them, so a row can be
    /// dropped under them. Today after Overdue, Tomorrow after Today.
    static func withDropDays(_ groups: [Group], today: DueDay, calendar: Calendar) -> [Group] {
        var groups = groups
        if !groups.contains(where: { $0.kind == .today }) {
            let at = groups.firstIndex { $0.kind != .overdue } ?? groups.endIndex
            groups.insert(Group(kind: .today, title: String(localized: "Today"), isOverdue: false, ids: []), at: at)
        }
        if let tomorrow = tomorrow(after: today, calendar: calendar), !groups.contains(where: { $0.kind == .day(tomorrow) }) {
            let at = (groups.firstIndex { $0.kind == .today }).map { $0 + 1 } ?? groups.endIndex
            groups.insert(Group(kind: .day(tomorrow), title: String(localized: "Tomorrow"), isOverdue: false, ids: []), at: at)
        }
        return groups
    }

    /// The Done page's header for a day ("Mon 27 Oct"), today included.
    static func doneDayTitle(_ day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        return dayTitle(calendar.startOfDay(for: day), sameYear: sameYear, calendar: calendar, locale: locale)
    }

    // MARK: - Files

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

    /// Empty views retain result descriptions; unfiltered pages have no helper sentence.
    static func empty(tab: TasksTab, query: String, filtered: Bool, tag: String? = nil) -> Empty {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return Empty(title: String(localized: "No results"), body: String(localized: "No tasks match “\(query)”."), canClear: true)
        }
        if let tag {
            return Empty(title: String(localized: "No results"),
                         body: String(localized: "No tasks in \(tagChipTitle(tag)) in this view."), canClear: true)
        }
        if filtered {
            // The View options' filters.
            return Empty(title: String(localized: "No results"), body: String(localized: "Nothing in this view."), canClear: true)
        }
        switch tab {
        case .now:
            return Empty(title: String(localized: "Nothing to do right now"),
                         body: "", canClear: false)
        case .backlog:
            return Empty(title: String(localized: "Nothing in Backlog"),
                         body: "", canClear: false)
        case .done:
            return Empty(title: String(localized: "Nothing completed yet"),
                         body: "", canClear: false)
        }
    }

    // MARK: - Tag chips (owner, 2026-10-28)

    /// A tag chip's title: the row pills' wording.
    static func tagChipTitle(_ tag: String) -> String { "#" + tag }

    /// The tag a chip's click leaves chosen (the design's `listFilter`):
    /// one at a time; the chosen tag again, or All (nil), clears it.
    static func tagFilter(choosing chip: String?, current: String?) -> String? {
        guard let chip, chip != current else { return nil }
        return chip
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
        case .backlog: "backlog"
        }
    }
}

// Existing Tasks callers retain their names; shared colour policy belongs to DesignSystem.
typealias TasksDesignTone = AtticPanelTone

extension TasksPanelDesign {
    static func oklchHue(for hue: AtticTagHue) -> Double? { AtticSurfaceInk.oklchHue(for: hue) }
    static func tagColours(hue: Double?, dark: Bool) -> (text: AtticRGBA, fill: AtticRGBA) {
        AtticSurfaceInk.tagColours(hue: hue, dark: dark)
    }
    static func tagInk(_ hue: AtticTagHue, tokens: AtticColorTokens) -> AtticRGBA { AtticSurfaceInk.tagInk(hue, tokens: tokens) }
    static func oklch(_ l: Double, _ c: Double, _ hDegrees: Double, alpha: Double = 1) -> AtticRGBA {
        AtticSurfaceInk.oklch(l, c, hDegrees, alpha: alpha)
    }
    @MainActor
    static func tone(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> AtticRGBA { AtticSurfaceInk.tone(tone, tokens: tokens) }
    @MainActor
    static func toneInk(_ tone: TasksDesignTone, tokens: AtticColorTokens, overlays: [AtticRGBA] = []) -> AtticRGBA {
        AtticSurfaceInk.toneInk(tone, tokens: tokens, overlays: overlays)
    }
    static func seeThrough(_ tokens: AtticColorTokens) -> Bool { AtticSurfaceInk.seeThrough(tokens) }
    static func vivid(_ colour: AtticRGBA, tokens: AtticColorTokens) -> AtticRGBA { AtticSurfaceInk.vivid(colour, tokens: tokens) }
    static func reference(_ tokens: AtticColorTokens) -> AtticRGBA { AtticSurfaceInk.reference(tokens) }
    static func toneBackgrounds(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> [AtticRGBA] {
        AtticSurfaceInk.toneBackgrounds(tone, tokens: tokens)
    }
    static func toneFloor(_ tokens: AtticColorTokens) -> Double { AtticSurfaceInk.toneFloor(tokens) }
    static let glassStepScale = AtticSurfaceInk.glassStepScale
}
