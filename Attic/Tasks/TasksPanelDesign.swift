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
        /// Later's one list (Accepted 2026-10-29, "Later is the backlog"):
        /// every put-off task, no date groups, no header.
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
        var showsHeader: Bool { kind != .backlog }

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

    /// Later's list (Accepted 2026-10-29): one group without a header, the
    /// list's order kept; nothing when Later is empty.
    static func backlogGroups(_ ids: [UUID]) -> [Group] {
        ids.isEmpty ? [] : [Group(kind: .backlog, title: "", isOverdue: false, ids: ids)]
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

    /// A tag's text and soft fill. The text is the changelog's coloured
    /// tag (27 Oct, "coloured text, no pill"): `oklch(0.5 0.14 h)` in
    /// light; the fill, `oklch(0.9 0.028 h)`, is for chips that need one.
    /// In dark, light text on a deep fill.
    static func tagColours(hue: Double?, dark: Bool) -> (text: AtticRGBA, fill: AtticRGBA) {
        let chroma: (text: Double, fill: Double) = hue == nil ? (0, 0) : (0.14, 0.028)
        let h = hue ?? 0
        if dark {
            return (oklch(0.82, hue == nil ? 0 : 0.10, h), oklch(0.34, hue == nil ? 0 : 0.045, h))
        }
        return (oklch(0.5, chroma.text, h), oklch(0.9, chroma.fill, h))
    }

    /// A tag's `#name` ink. Glass keeps its clean colour (owner,
    /// 2026-10-29: `vivid`); Solid in Light is the changelog's
    /// `oklch(0.5 0.14 h)`; Dark and Increase Contrast keep the tag's
    /// token ink, which the changelog does not cover.
    static func tagInk(_ hue: AtticTagHue, tokens: AtticColorTokens) -> AtticRGBA {
        if seeThrough(tokens) { return vivid(tokens.ink(hue.ink), tokens: tokens) }
        guard tokens.context.mode == .light, !tokens.context.increaseContrast else { return tokens.ink(hue.ink) }
        return tagColours(hue: oklchHue(for: hue), dark: false).text
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
    /// pages are not sorted by). `tag` is the chosen tag chip (the
    /// design's list filter).
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
                         body: String(localized: "Tasks you add, or bring in from Later, show up here."), canClear: false)
        case .backlog:
            return Empty(title: String(localized: "Nothing scheduled"),
                         body: String(localized: "Tasks you put off for later show up here."), canClear: false)
        case .done:
            return Empty(title: String(localized: "Nothing completed yet"),
                         body: String(localized: "Tasks you check off show up here."), canClear: false)
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

// MARK: - The design's greys under the title

/// The quieter text of the panel design, each a step under the title:
/// the group headers rgb(72,74,78), the next event's time rgb(86,88,92),
/// the dates rgb(110,112,116) and the meta line rgb(128,130,133), against
/// the title's rgb(29,29,31) on white. In that order, loudest first.
enum TasksDesignTone: CaseIterable, Sendable {
    case groupHeader, nextEventTime, date, meta

    /// The design's colour (it is drawn on white).
    var designColour: AtticRGBA {
        switch self {
        case .groupHeader: AtticRGBA(red: 72 / 255, green: 74 / 255, blue: 78 / 255, alpha: 1)
        case .nextEventTime: AtticRGBA(red: 86 / 255, green: 88 / 255, blue: 92 / 255, alpha: 1)
        case .date: AtticRGBA(red: 110 / 255, green: 112 / 255, blue: 116 / 255, alpha: 1)
        case .meta: AtticRGBA(red: 128 / 255, green: 130 / 255, blue: 133 / 255, alpha: 1)
        }
    }

    static let designTitle = AtticRGBA(red: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)

    /// How far under the title the design puts it: the log of its contrast
    /// on white over the log of the title's (header 0.77, date 0.57, meta
    /// 0.48). Contrast multiplies, so a power keeps the relation on any
    /// surface: on white it gives the design's own colour back.
    var designFraction: Double {
        log(designColour.contrast(on: .white(1))) / log(Self.designTitle.contrast(on: .white(1)))
    }
}

extension TasksPanelDesign {
    /// A design grey on this surface (fidelity round, 2026-10-28). The
    /// surface's tuning sets the title's ink (Phase 0's near-black on Glass,
    /// for example); each grey keeps the design's relation to that title,
    /// so a header reads a step lighter on every surface. Readability
    /// still wins: each is secondary text and keeps its floor (3 : 1, or
    /// 4.5 : 1 under Increase Contrast, with the tokens' margins) on every
    /// background the tokens judge their own grey on, and is never
    /// stronger than the title. Reduce Transparency
    /// keeps the contrast the chosen Glass grey had (U-40).
    @MainActor
    static func tone(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> AtticRGBA {
        let key = ToneKey(colours: tokens.context, tone: tone)
        if let cached = toneCache[key] { return cached }
        var value = solveTone(tone, tokens: tokens)
        if let chosen = tokens.context.chosen {
            let glass = AtticColorTokenCache.shared.tokens(for: chosen)
            let glassTone = Self.tone(tone, tokens: glass)
            let glassSurface = glass.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
            let base = reference(tokens)
            let target = AtticColorTokens.reducedTransparencyTarget(glass: glassTone, glassSurface: glassSurface, base: base)
            value = value.tuned(toContrast: min(target, tokens.ink(.heading).contrast(on: base)), against: [base],
                                lighten: tokens.context.mode == .dark)
        }
        // The design's order holds where the floors bring the greys together:
        // a date never stronger than the header, the meta than a date.
        let louder: TasksDesignTone? = switch tone {
        case .groupHeader: nil
        case .nextEventTime: .groupHeader
        case .date: .nextEventTime
        case .meta: .date
        }
        if let louder {
            let base = reference(tokens)
            let limit = Self.tone(louder, tokens: tokens)
            if value.contrast(on: base) > limit.contrast(on: base) { value = limit }
        }
        toneCache[key] = value
        return value
    }

    /// A design grey as drawn on a see-through surface (owner, 2026-10-29:
    /// "vibrant greys"): the title's ink made see-through so that, over the
    /// surface above a mid-grey desktop, it is exactly `tone`. As macOS's
    /// own secondary label colours do, it darkens (or, in Dark, lightens)
    /// what is behind the glass, so it keeps its step from the glass
    /// wherever the panel sits. Solid, and Reduce Transparency, keep the
    /// opaque grey.
    @MainActor
    static func toneInk(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> AtticRGBA {
        let value = Self.tone(tone, tokens: tokens)
        guard tokens.context.surface != .solid, tokens.context.reducedFrom == nil else { return value }
        let ink = tokens.ink(.heading)
        let base = reference(tokens)
        func mean(_ c: AtticRGBA) -> Double { (c.red + c.green + c.blue) / 3 }
        let span = mean(ink) - mean(base)
        guard abs(span) > 0.01 else { return value }
        return ink.withAlpha((mean(value) - mean(base)) / span)
    }

    /// Glass or Frosted as drawn (not Solid, not made solid by Reduce
    /// Transparency).
    static func seeThrough(_ tokens: AtticColorTokens) -> Bool {
        tokens.context.surface != .solid && tokens.context.reducedFrom == nil
    }

    /// A colour cleaned up for glass (owner, 2026-10-29): the same hue,
    /// more saturated, at the same contrast on the surface, so tags, the
    /// overdue red and "!!" read clean on the glass's own grey instead of
    /// muddy. Solid keeps the colour.
    static func vivid(_ colour: AtticRGBA, tokens: AtticColorTokens) -> AtticRGBA {
        guard seeThrough(tokens) else { return colour }
        let base = reference(tokens)
        let (h, s, l) = colour.hsl
        let richer = AtticRGBA(hue: h, saturation: min(1, s * 1.35 + 0.12), lightness: l, alpha: colour.alpha)
        return richer.tuned(toContrast: colour.contrast(on: base), against: [base], lighten: tokens.context.mode == .dark)
    }

    private struct ToneKey: Hashable {
        let colours: AtticDesignContext.ColourKey
        let tone: TasksDesignTone
    }

    @MainActor private static var toneCache: [ToneKey: AtticRGBA] = [:]

    /// The surface the relation is judged on: over a mid-grey desktop,
    /// where content starts.
    static func reference(_ tokens: AtticColorTokens) -> AtticRGBA {
        tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
    }

    /// Every background a tone is judged on: the backgrounds the tokens
    /// judge their own secondary grey on (the surface over each desktop).
    static func toneBackgrounds(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> [AtticRGBA] {
        tokens.panel.backgrounds(for: .init(ink: .helper, foreground: tokens.ink(.helper), overlays: []))
    }

    /// The floor each tone keeps, with the tokens' margin (3.11 and 4.66).
    static func toneFloor(_ tokens: AtticColorTokens) -> Double {
        tokens.panel.floor(for: .helper) < 4.5 ? 3.11 : 4.66
    }

    /// How much of the design's step under the title the greys keep on
    /// Glass and Frosted.
    static let glassStepScale = 0.5

    private static func solveTone(_ tone: TasksDesignTone, tokens: AtticColorTokens) -> AtticRGBA {
        let dark = tokens.context.mode == .dark
        let base = reference(tokens)
        let title = tokens.ink(.heading)
        let titleContrast = title.contrast(on: base)
        // On see-through surfaces the greys sit half as far under the title
        // as on paper (owner, 2026-10-29: stronger greys on glass), so they
        // hold up on the glass's own grey; the order and steps remain.
        let fraction = tokens.context.surface == .solid ? tone.designFraction : 1 - (1 - tone.designFraction) * glassStepScale
        let target = pow(titleContrast, fraction)
        // The design grey's hue and saturation, at the lightness that gives
        // the target: between the title's lightness and the surface's, where
        // contrast falls steadily.
        let (hue, saturation, _) = tone.designColour.hsl
        func grey(_ lightness: Double) -> AtticRGBA { AtticRGBA(hue: hue, saturation: saturation, lightness: lightness) }
        var near = title.hsl.lightness, far = base.hsl.lightness
        for _ in 0..<40 {
            let mid = (near + far) / 2
            if grey(mid).contrast(on: base) >= target { near = mid } else { far = mid }
        }
        var value = grey(near)
        value = value.tuned(toContrast: toneFloor(tokens), against: toneBackgrounds(tone, tokens: tokens), lighten: dark)
        if value.contrast(on: base) > titleContrast { value = title }
        return value
    }
}
