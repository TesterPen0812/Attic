import AppKit
import SwiftUI

// MARK: - Choice rows

/// A row's leading check column in a picker: ticked, part-ticked (a
/// multi-selection where only some tasks have it) or empty.
enum AtticCheckState: Equatable, Sendable {
    case off, on, mixed
}

/// One choice in a picker (the date picker's quick days, the tag list,
/// Priority, a suggestion): 28 tall, the pop-over row's shape, an optional
/// check column, a quiet trailing detail ("Thu 1 Oct"). One row of a list
/// takes the selection fill: in a list with a keyboard highlight the list
/// owns it and the pointer moves it (`onHover`), as in a native menu, so a
/// hovered row and a keyboard row are never lit together (round 5). The
/// fill is inset 1 pt top and bottom: two lit rows never merge into one
/// block.
struct AtticChoiceRow: View {
    let title: String
    var systemName: String?
    var detail: String?
    /// nil: no check column.
    var check: AtticCheckState?
    var isHighlighted = false
    var titleInk: AtticInk = .body
    /// The pointer entered (true) or left (false) the row: the list moves
    /// its one highlight here. Nil: the row lights itself while hovered (a
    /// list with no keyboard highlight).
    var onHover: ((Bool) -> Void)? = nil
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticPickerMetrics.self
        let height = AtticControlSize.smallHeight
        let fillHeight = height - m.highlightGap
        let radius = AtticRadius.control(height: fillHeight)
        let lit = onHover == nil ? (hovered || isHighlighted) : isHighlighted
        let fill: AtticRGBA = lit ? design.tokens.selected : .clear
        Button(action: action) {
            HStack(spacing: m.rowGap) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: AtticPopoverMetrics.rowIconSize, ink: .icon)
                        .frame(width: AtticPopoverMetrics.rowIconSlot)
                }
                AtticText(verbatim: title, style: .menuRow, ink: titleInk, truncates: true)
                Spacer(minLength: AtticPopoverMetrics.trailingMinGap)
                if let detail {
                    AtticText(verbatim: detail, style: .shortcut, ink: .helper)
                        .fixedSize()
                }
                // The tick after the item (N-4's card design).
                if let check {
                    Group {
                        switch check {
                        case .on: AtticIcon(systemName: "checkmark", size: m.checkSize, weight: .semibold, ink: .glyph)
                        case .mixed: AtticIcon(systemName: "minus", size: m.checkSize, weight: .semibold, ink: .glyph)
                        case .off: Color.clear
                        }
                    }
                    .frame(width: m.checkSlot)
                }
            }
            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color)
                .padding(.vertical, m.highlightGap / 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        // Keyboard focus (Full Keyboard Access) draws Attic's ring, never
        // nothing (round 4), on the fill's shape.
        .atticOwnFocusRing(.rounded(radius: radius, height: fillHeight))
        // The whole row answers the pointer (no dead gap between rows). A
        // row moving under a resting pointer as the keyboard scrolls the
        // list is not the pointer moving: the keyboard keeps its highlight.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                if !hovered { hovered = true }
                onHover?(true)
            case .ended:
                hovered = false
                onHover?(false)
            }
        }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(check == .on || isHighlighted ? .isSelected : [])
        .accessibilityValue(check == .mixed ? String(localized: "some selected tasks") : "")
    }
}

/// A list's one highlight (round 5, the owner's item: two rows lit at
/// once): the keyboard and the pointer move the same index, as in a native
/// menu.
enum AtticListHighlight {
    /// The highlight after the pointer entered (`inside`) or left row
    /// `index`: entering takes it there; leaving clears it only if it is
    /// still on that row (the pointer went off the list, not to a
    /// neighbour, whose entry may come first).
    static func hovered(_ index: Int, inside: Bool, current: Int?) -> Int? {
        if inside { return index }
        return current == index ? nil : current
    }

    /// A hover the pointer made: a row sliding under a resting pointer as
    /// the keyboard scrolls the list (a key event, or none) is not one.
    static func isPointerMove(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            return true
        default:
            return false
        }
    }
}

/// A picker's divider: a hairline inset like the rows' text.

// MARK: - Date card

/// A suggestion for what was typed into the date card ("Tomorrow · Tue",
/// "Friday · 9 Oct").
struct AtticDateSuggestion: Equatable, Identifiable {
    let id: Int
    let title: String
    let detail: String
    let date: Date
    /// The typed text the title starts with, emboldened ("Fri" of Friday).
    var match: String?
}

enum AtticDateSuggestions {
    /// The most suggestions the field offers (the Craft spec: four).
    static let limit = 4

    /// Up to four days for what was typed (the Craft spec), none when
    /// nothing is: the named
    /// days the text starts ("t": Today, Tomorrow; "fri": Friday), then
    /// what the host's parser reads in it ("9 oct", "in 3 days"). Each resolves through `parse`,
    /// the same parser that reads typed dates elsewhere.
    static func make(_ typed: String, today: Date, calendar: Calendar, parse: (String) -> Date?) -> [AtticDateSuggestion] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let start = calendar.startOfDay(for: today)
        var named: [(phrase: String, title: String)] = [
            ("today", String(localized: "Today")),
            ("tomorrow", String(localized: "Tomorrow")),
            ("next week", String(localized: "Next week")),
        ]
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        let local = calendar.weekdaySymbols
        for (index, word) in english.weekdaySymbols.enumerated() {
            let title = local.indices.contains(index) ? local[index] : word.capitalized
            named.append((word.lowercased(), title))
            if title.lowercased() != word.lowercased() { named.append((title.lowercased(), title)) }
        }
        var found: [(title: String, date: Date, match: String?)] = []
        func add(_ title: String, _ date: Date, match: String?) {
            let day = calendar.startOfDay(for: date)
            guard !found.contains(where: { calendar.isDate($0.date, inSameDayAs: day) }) else { return }
            found.append((title, day, match))
        }
        // The named days the text starts first, then what the parser reads.
        for phrase in named where phrase.phrase.hasPrefix(query) {
            guard found.count < limit else { break }
            if let date = resolve(phrase.phrase, start: start, parse: parse) { add(phrase.title, date, match: typed) }
        }
        if found.count < limit, let parsed = parse(query) {
            add(title(for: parsed, start: start, calendar: calendar), parsed, match: nil)
        }
        return found.prefix(limit).enumerated().map { index, item in
            AtticDateSuggestion(id: index, title: item.title, detail: detail(for: item.date, start: start, calendar: calendar),
                                date: item.date, match: item.match?.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func resolve(_ phrase: String, start: Date, parse: (String) -> Date?) -> Date? {
        phrase == "today" ? start : parse(phrase)
    }

    /// A typed date's name: Today, Tomorrow, or its weekday.
    private static func title(for date: Date, start: Date, calendar: Calendar) -> String {
        switch calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day {
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        default: date.formatted(AtticDateCardFormat.style(calendar).weekday(.wide))
        }
    }

    /// Today and tomorrow say their weekday ("Tue"); further days their
    /// date ("9 Oct", with the year when it is not this year's).
    static func detail(for date: Date, start: Date, calendar: Calendar) -> String {
        let style = AtticDateCardFormat.style(calendar)
        let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        if (0...1).contains(offset) { return date.formatted(style.weekday(.abbreviated)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: start)
        return sameYear ? date.formatted(style.day().month(.abbreviated)) : date.formatted(style.day().month(.abbreviated).year())
    }
}

enum AtticDateCardFormat {
    /// The calendar's own locale, time zone and calendar.
    static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
                         timeZone: calendar.timeZone)
    }

    /// "October 2026".
    static func monthTitle(_ month: Date, calendar: Calendar) -> String {
        month.formatted(style(calendar).month(.wide).year())
    }

    /// The card's month title (draft C): "October" in this year,
    /// "January 2027" in any other.
    static func monthTitle(_ month: Date, today: Date, calendar: Calendar) -> String {
        calendar.component(.year, from: month) == calendar.component(.year, from: today)
            ? month.formatted(style(calendar).month(.wide)) : monthTitle(month, calendar: calendar)
    }

    /// VoiceOver's name for a day: "Friday 9 October".
    static func spoken(_ day: Date, calendar: Calendar) -> String {
        day.formatted(style(calendar).weekday(.wide).day().month(.wide))
    }
}

/// The month as the card lays it out (draft C): six whole weeks from the
/// locale's first weekday, the days of the months either side included
/// (drawn lighter), so the grid never changes height.
struct AtticDateMonth: Equatable {
    let start: Date
    /// Seven per week, six weeks.
    let cells: [Date]
    /// Which cells are this month's.
    let inMonth: [Bool]
    /// Two-letter weekdays in column order ("Mo Tu We Th Fr Sa Su").
    let weekdays: [String]

    init(containing day: Date, calendar: Calendar) {
        let first = calendar.dateInterval(of: .month, for: day)?.start ?? calendar.startOfDay(for: day)
        start = first
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let cellCount = AtticDropdownMetrics.monthWeeks * 7
        cells = (0..<cellCount).map { calendar.date(byAdding: .day, value: $0 - lead, to: first) ?? first }
        inMonth = (0..<cellCount).map { $0 >= lead && $0 < lead + count }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        weekdays = (0..<7).map { String(symbols[(calendar.firstWeekday - 1 + $0) % 7].prefix(2)) }
    }

    var weeks: Int { cells.count / 7 }
}

/// A key the date card answers, from the presenter's key monitor (an
/// `NSEvent`, ahead of AppKit's menu equivalents and the key-view loop) or
/// from SwiftUI (`KeyPress`, where no presenter routes keys).
enum AtticDateCardKey: Equatable {
    case left, right, up, down, pick, tab(back: Bool), today, month(Int), year(Int), clear, delete, cancel, text(String)

    /// Draft C's keys (the Craft spec): the arrows move by day, Page Up and
    /// Page Down or ⇧ with an arrow turn the month, ⌥↑ ⌥↓ the year, ⌘⌫
    /// clears; ⌘[ ⌘] and ⌥T stay.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let shift = event.modifierFlags.contains(.shift)
        if (123...126).contains(event.keyCode) {
            switch (event.keyCode, flags, shift) {
            case (123, [], true), (126, [], true): self = .month(-1); return
            case (124, [], true), (125, [], true): self = .month(1); return
            case (126, [.option], false): self = .year(-1); return
            case (125, [.option], false): self = .year(1); return
            default: break
            }
            if shift || !flags.isEmpty { return nil }
        }
        switch (event.keyCode, flags) {
        case (51, [.command]): self = .clear
        case (123, []): self = .left
        case (124, []): self = .right
        case (126, []): self = .up
        case (125, []): self = .down
        case (36, []), (76, []): self = .pick
        case (48, []): self = .tab(back: event.modifierFlags.contains(.shift))
        case (17, [.option]): self = .today
        case (33, [.command]), (116, []): self = .month(-1)
        case (30, [.command]), (121, []): self = .month(1)
        case (51, []): self = .delete
        default:
            guard flags.isEmpty, let text = event.characters, Self.isTyping(text) else { return nil }
            self = .text(text)
        }
    }

    init?(_ press: KeyPress) {
        let flags = press.modifiers.intersection([.command, .option, .control])
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow where flags.isEmpty && shift, .upArrow where flags.isEmpty && shift: self = .month(-1)
        case .rightArrow where flags.isEmpty && shift, .downArrow where flags.isEmpty && shift: self = .month(1)
        case .upArrow where flags == .option: self = .year(-1)
        case .downArrow where flags == .option: self = .year(1)
        case .delete where flags == .command: self = .clear
        case .leftArrow where flags.isEmpty: self = .left
        case .rightArrow where flags.isEmpty: self = .right
        case .upArrow where flags.isEmpty: self = .up
        case .downArrow where flags.isEmpty: self = .down
        case .return where flags.isEmpty: self = .pick
        case .tab where flags.isEmpty: self = .tab(back: press.modifiers.contains(.shift))
        case .escape: self = .cancel
        case .pageUp: self = .month(-1)
        case .pageDown: self = .month(1)
        case .delete where flags.isEmpty: self = .delete
        default:
            if flags == .command, press.key.character == "[" { self = .month(-1); return }
            if flags == .command, press.key.character == "]" { self = .month(1); return }
            if flags == .option, press.key.character == "t" || press.characters == "†" { self = .today; return }
            if press.characters == "\u{19}" { self = .tab(back: true); return }
            guard flags.isEmpty, Self.isTyping(press.characters) else { return nil }
            self = .text(press.characters)
        }
    }

    /// Letters, digits, spaces and the date punctuation ("9/10", "+3").
    private static func isTyping(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || " /.-+,".unicodeScalars.contains(scalar)
        }
    }
}

/// The date card's one highlight and the day it is on (owner, 2026-10-05):
/// the arrows move it through the grid, the pointer moves the same one,
/// Tab reaches Today (and Remove date), Return picks what is lit. The month
/// shown is always the cursor's, so what Return picks is on screen. Pure:
/// tested directly.
struct AtticDateCardState: Equatable {
    enum Spot: Equatable {
        case day, today, remove
        case suggestion(Int)
    }

    /// What a key asks the card to do.
    enum Outcome: Equatable {
        case pick(Date), today, remove, suggestion(Int)
        /// Handled; nothing to pick.
        case nothing
    }

    /// The active day: the grid's highlight when `lit` is `.day`.
    private(set) var cursor: Date
    /// Nothing is lit as the card opens.
    private(set) var lit: Spot?

    init(start: Date) { cursor = start }

    func month(_ calendar: Calendar) -> AtticDateMonth { AtticDateMonth(containing: cursor, calendar: calendar) }

    /// Answers a navigation key (typing is the card's own); nil when the
    /// key is not the card's.
    mutating func apply(_ key: AtticDateCardKey, calendar: Calendar, suggestions: Int, typing: Bool, hasRemove: Bool) -> Outcome? {
        switch key {
        case .left: arrow(-1, calendar)
        case .right: arrow(1, calendar)
        case .up:
            if case let .suggestion(index)? = lit { lit = .suggestion(max(0, index - 1)) } else { arrow(-7, calendar) }
        case .down:
            if case let .suggestion(index)? = lit { lit = index + 1 < suggestions ? .suggestion(index + 1) : .day } else { arrow(7, calendar) }
        case let .month(step):
            cursor = calendar.date(byAdding: .month, value: step, to: cursor) ?? cursor
        case let .year(step):
            cursor = calendar.date(byAdding: .year, value: step, to: cursor) ?? cursor
        case .clear:
            return hasRemove ? .remove : Outcome.nothing
        case let .tab(back):
            var order: [Spot] = (0..<suggestions).map { .suggestion($0) } + [.day, .today]
            if hasRemove { order.append(.remove) }
            let at = order.firstIndex(of: lit ?? .day) ?? 0
            lit = order[(at + (back ? order.count - 1 : 1)) % order.count]
        case .today:
            return .today
        case .pick:
            switch lit {
            case .day?: return .pick(cursor)
            case .today?: return .today
            case .remove?: return .remove
            case let .suggestion(index)?: return .suggestion(index)
            case nil:
                if suggestions > 0 { return .suggestion(0) }
                return typing ? Outcome.nothing : .pick(cursor)
            }
        case .delete, .cancel, .text:
            return nil
        }
        return Outcome.nothing
    }

    /// An arrow lights the cursor where it is first, then moves it.
    private mutating func arrow(_ days: Int, _ calendar: Calendar) {
        if lit == .day {
            cursor = calendar.date(byAdding: .day, value: days, to: cursor) ?? cursor
        } else {
            lit = .day
        }
    }

    /// The pointer entered or left a day: the highlight follows it, as a
    /// menu's does.
    mutating func hoverDay(_ day: Date, inside: Bool, calendar: Calendar) {
        if inside {
            cursor = day
            lit = .day
        } else if lit == .day, calendar.isDate(cursor, inSameDayAs: day) {
            lit = nil
        }
    }

    /// The pointer entered or left Today, Remove date or a suggestion.
    mutating func hover(_ spot: Spot, inside: Bool) {
        if inside { lit = spot } else if lit == spot { lit = nil }
    }

    /// What was typed changed: its first suggestion takes the highlight and
    /// the month turns to it; with none, a suggestion's highlight goes.
    mutating func typed(suggestions: [AtticDateSuggestion]) {
        if let first = suggestions.first {
            cursor = first.date
            lit = .suggestion(0)
        } else if case .suggestion? = lit {
            lit = nil
        }
    }

    func isLit(_ day: Date, calendar: Calendar) -> Bool {
        lit == .day && calendar.isDate(cursor, inSameDayAs: day)
    }

    /// The day a lit suggestion would pick (U-18): the grid marks it with
    /// the highlight, so what Return inserts or sets is on screen in the
    /// month as well as in the list above it.
    func proposedDay(_ suggestions: [AtticDateSuggestion]) -> Date? {
        guard case let .suggestion(index)? = lit, suggestions.indices.contains(index) else { return nil }
        return suggestions[index].date
    }
}

/// The one date card (draft C, owner 2026-10-23, on the Craft spec): the
/// Date field at the top, where what is typed shows and up to four
/// suggestions follow it (Return applies the top one); a full-width rule;
/// the month title with ‹ ⦿ ›; two-letter weekdays; six weeks, other months'
/// and past days lighter; the chosen day a soft rounded square, today
/// ringed; then Clear Date, only when there is a date. Keys: the arrows
/// move the day, Page Up/Down or ⇧ with an arrow turn the month, ⌥↑ ⌥↓ the
/// year, Return picks, Tab or ⌥T reach Today (⦿), ⌘⌫ clears, Esc closes.
/// Typing goes to the field. Tasks (the add bar, a row) and Notes (`/date`)
/// use it alike.
struct AtticDateCard: View {
    let today: Date
    let selected: Date?
    /// With the locale's first weekday and the locale set.
    let calendar: Calendar
    @Binding var typed: String
    /// Reads typed text ("fri", "9 oct").
    var parse: (String) -> Date? = { _ in nil }
    /// "Clear Date" under the month (a task that has a date).
    var removeTitle: String?
    let onPick: (Date) -> Void
    var onRemove: () -> Void = {}
    /// Esc where no presenter closes the card (Notes).
    var onCancel: (() -> Void)?

    @State private var state: AtticDateCardState?
    /// ‹ (-1) or › (1) under the pointer.
    @State private var hoveredMonthStep: Int?
    /// The grid's day under the pointer.
    @State private var hoveredDay: Date?
    @FocusState private var focused: Bool
    @Environment(\.atticDesign) private var design
    @Environment(\.atticDropdownRegisterKeys) private var registerKeys

    private var current: AtticDateCardState { state ?? AtticDateCardState(start: calendar.startOfDay(for: selected ?? today)) }
    private var suggestions: [AtticDateSuggestion] { AtticDateSuggestions.make(typed, today: today, calendar: calendar, parse: parse) }

    var body: some View {
        let d = AtticDropdownMetrics.self
        let state = current
        let month = state.month(calendar)
        let typing = !typed.trimmingCharacters(in: .whitespaces).isEmpty
        let suggestions = typing ? self.suggestions : []
        let proposed = state.proposedDay(suggestions)
        let start = calendar.startOfDay(for: today)
        VStack(alignment: .leading, spacing: 0) {
            AtticDropdownFieldHeader { field }
            if typing {
                suggestionRows(suggestions, state: state)
                    .padding(.top, d.inset)
                AtticDropdownRule(header: true)
                    .padding(.top, d.inset)
            }
            VStack(alignment: .leading, spacing: 0) {
                header(month, state: state)
                HStack(spacing: 0) {
                    ForEach(Array(month.weekdays.enumerated()), id: \.offset) { _, symbol in
                        AtticText(verbatim: symbol, style: .dropdownWeekday, ink: .helper)
                            .frame(width: d.monthCellWidth, height: d.weekdayHeight)
                    }
                }
                .padding(.top, d.weekdayGap)
                .accessibilityHidden(true)
                VStack(spacing: 0) {
                    ForEach(0..<month.weeks, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let index = week * 7 + column
                                dayCell(month.cells[index], inMonth: month.inMonth[index], start: start, state: state, proposed: proposed)
                            }
                        }
                    }
                }
                // One pointer for the grid (menus fix 1): a press picks the
                // day under it and the pointer lights it, as 42 buttons with
                // a hover each did, at a third of the open's cost.
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    if let day = Self.day(at: point, in: month) { onPick(day) }
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case let .active(point):
                        guard AtticListHighlight.isPointerMove(NSApp.currentEvent), let day = Self.day(at: point, in: month) else { return }
                        if let hovered = hoveredDay, hovered != day { update { $0.hoverDay(hovered, inside: false, calendar: calendar) } }
                        hoveredDay = day
                        if !current.isLit(day, calendar: calendar) { update { $0.hoverDay(day, inside: true, calendar: calendar) } }
                    case .ended:
                        if let hovered = hoveredDay { update { $0.hoverDay(hovered, inside: false, calendar: calendar) } }
                        hoveredDay = nil
                    }
                }
                .preference(key: AtticDropdownHighlightKey.self,
                            value: state.lit == .day ? Self.dayID(calendar.startOfDay(for: state.cursor)) : nil)
                if let removeTitle {
                    clearRow(removeTitle, lit: state.lit == .remove)
                        .padding(.top, d.clearGap)
                }
            }
            .padding(.horizontal, d.dateBodyInset - d.inset)
            .padding(.top, d.dateBodyInset)
            .padding(.bottom, d.dateBodyInset - d.inset)
        }
        .frame(width: d.dateCardWidth - d.inset * 2)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .atticDropdownFocus($focused)
        .onKeyPress(phases: .down) { press in
            guard let key = AtticDateCardKey(press) else { return .ignored }
            return handle(key) ? .handled : .ignored
        }
        .onAppear { registerKeys { event in AtticDateCardKey(event).map { handle($0) } ?? false } }
        .onDisappear { registerKeys(nil) }
        .onChange(of: typed) { _, _ in
            let found = self.suggestions
            update { $0.typed(suggestions: found) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Choose a date"))
    }

    private func update(_ change: (inout AtticDateCardState) -> Void) {
        var next = current
        change(&next)
        if next != state { state = next }
    }

    /// Answers a key; false leaves it to the presenter (Esc) or the window.
    private func handle(_ key: AtticDateCardKey) -> Bool {
        switch key {
        case let .text(text):
            if typed.isEmpty, text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            typed += text
            return true
        case .delete:
            guard !typed.isEmpty else { return false }
            typed.removeLast()
            return true
        case .cancel:
            guard let onCancel else { return false }
            onCancel()
            return true
        default:
            let typing = !typed.trimmingCharacters(in: .whitespaces).isEmpty
            let suggestions = typing ? self.suggestions : []
            var next = current
            guard let outcome = next.apply(key, calendar: calendar, suggestions: suggestions.count, typing: typing,
                                           hasRemove: removeTitle != nil) else { return false }
            if next != state { state = next }
            switch outcome {
            case let .pick(day): onPick(day)
            case .today: onPick(calendar.startOfDay(for: today))
            case .remove: if removeTitle != nil { onRemove() }
            case let .suggestion(index): if suggestions.indices.contains(index) { onPick(suggestions[index].date) }
            case .nothing: break
            }
            return true
        }
    }

    /// The Date field (draft C): the magnifier, then what is typed (or the
    /// placeholder) with the caret while the card has the keyboard. The
    /// card's keys type into it, so the arrows keep moving the day.
    private var field: some View {
        let d = AtticDropdownMetrics.self
        let caret = Rectangle().fill(Color(nsColor: .textInsertionPointColor)).frame(width: 1.5, height: 16)
        return HStack(spacing: 0) {
            AtticIcon(systemName: "magnifyingglass", size: d.iconSize, ink: .helper)
                .frame(width: d.iconSlot)
                .padding(.trailing, d.fieldTextLeading - d.fieldIconLeading - d.iconSlot)
            if typed.isEmpty {
                if focused { caret }
                AtticText(verbatim: String(localized: "Date"), style: .dropdownRow, ink: .placeholder)
            } else {
                AtticText(verbatim: typed, style: .dropdownRow, ink: .body, truncates: true)
                if focused { caret }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, d.fieldIconLeading)
        .padding(.trailing, d.rowPadding)
        .frame(height: d.fieldHeight)
        .background(RoundedRectangle(cornerRadius: d.fieldRadius, style: .continuous).fill(design.tokens.dropdownHighlight.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Date"))
        .accessibilityValue(typed)
        .accessibilityAddTraits(.isSearchField)
        .accessibilityIdentifier("date-field")
    }

    @ViewBuilder
    private func suggestionRows(_ suggestions: [AtticDateSuggestion], state: AtticDateCardState) -> some View {
        if suggestions.isEmpty {
            AtticText(verbatim: String(localized: "No date matches"), style: .dropdownRow, ink: .helper)
                .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                .frame(height: AtticDropdownMetrics.rowHeight)
        } else {
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    AtticDropdownRow(title: suggestion.title, detail: suggestion.detail, match: suggestion.match,
                                     isHighlighted: state.lit == .suggestion(suggestion.id),
                                     onHover: { inside in update { $0.hover(.suggestion(suggestion.id), inside: inside) } },
                                     position: suggestion.id + 1, itemCount: suggestions.count,
                                     scrollID: "attic.date.suggestion.\(suggestion.id)") {
                        onPick(suggestion.date)
                    }
                    .accessibilityIdentifier("date-suggestion")
                }
            }
        }
    }

    private func header(_ month: AtticDateMonth, state: AtticDateCardState) -> some View {
        let d = AtticDropdownMetrics.self
        return HStack(spacing: 0) {
            AtticText(verbatim: AtticDateCardFormat.monthTitle(month.start, today: today, calendar: calendar),
                      style: .dropdownHeading, ink: .heading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityLabel(AtticDateCardFormat.monthTitle(month.start, calendar: calendar))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: d.monthNavWidth)
            monthButton(-1, systemName: "chevron.left", label: String(localized: "Previous month"))
            todayButton(lit: state.lit == .today)
            monthButton(1, systemName: "chevron.right", label: String(localized: "Next month"))
        }
        .padding(.leading, d.monthTitleLeading)
        .frame(height: d.monthHeaderHeight)
    }

    /// ⦿ (draft C): picks today, as Attic's Today did (⌥T).
    private func todayButton(lit: Bool) -> some View {
        let d = AtticDropdownMetrics.self
        return Button { onPick(calendar.startOfDay(for: today)) } label: {
            AtticIcon(systemName: "smallcircle.filled.circle", size: d.monthChevron + 1, weight: .regular, ink: .icon)
                .frame(width: d.monthNavWidth - 2, height: d.monthNavWidth - 2)
                .background { if lit { navMark } }
                .frame(width: d.monthNavWidth, height: d.monthHeaderHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusable(false)
        .focusEffectDisabled()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                if current.lit != .today { update { $0.hover(.today, inside: true) } }
            case .ended:
                update { $0.hover(.today, inside: false) }
            }
        }
        .help(String(localized: "Today (⌥T)"))
        .accessibilityLabel(String(localized: "Today"))
        .accessibilityValue(AtticDateCardFormat.spoken(today, calendar: calendar))
    }

    private var navMark: some View {
        // A whole superellipse on curve 1.4, as the days' marks.
        Squircle(cornerRadius: AtticDropdownMetrics.monthMarkRadius, exponent: AtticShape.controlExponent)
            .fill(design.tokens.dropdownHighlight.color)
    }

    /// ‹ or ›: lit under the pointer as a day is.
    private func monthButton(_ step: Int, systemName: String, label: String) -> some View {
        let d = AtticDropdownMetrics.self
        let lit = hoveredMonthStep == step
        return Button { update { _ = $0.apply(.month(step), calendar: calendar, suggestions: 0, typing: false, hasRemove: false) } } label: {
            AtticIcon(systemName: systemName, size: d.monthChevron, weight: .medium, ink: .icon)
                .frame(width: d.monthNavWidth - 2, height: d.monthNavWidth - 2)
                .background { if lit { navMark } }
                .frame(width: d.monthNavWidth, height: d.monthHeaderHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusable(false)
        .focusEffectDisabled()
        .onHover { inside in
            if inside { hoveredMonthStep = step } else if hoveredMonthStep == step { hoveredMonthStep = nil }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    /// Clear Date (draft C): a full-width soft row, 66 % ink at rest.
    private func clearRow(_ title: String, lit: Bool) -> some View {
        let d = AtticDropdownMetrics.self
        let tokens = design.tokens
        let rest = tokens.dropdownHighlight.withAlpha(tokens.dropdownHighlight.alpha / 2)
        return Button(action: onRemove) {
            AtticText(verbatim: title, style: .dropdownRow, ink: lit ? .body : .label)
                .padding(.horizontal, d.rowPadding)
                .frame(maxWidth: .infinity, minHeight: d.clearHeight, maxHeight: d.clearHeight, alignment: .leading)
                .background(Squircle(cornerRadius: d.clearRadius, exponent: AtticShape.surfaceExponent)
                    .fill((lit ? tokens.dropdownHighlight : rest).color))
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusable(false)
        .focusEffectDisabled()
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                if current.lit != .remove { update { $0.hover(.remove, inside: true) } }
            case .ended:
                update { $0.hover(.remove, inside: false) }
            }
        }
        .help(String(localized: "Clear Date (⌘⌫)"))
        // A menu item, as the rows of every Attic list are.
        .accessibilityRepresentation {
            AtticDropdownMenuItem(label: title, selected: lit, action: onRemove)
        }
        .accessibilityIdentifier("date-clear")
    }

    private func dayCell(_ day: Date, inMonth: Bool, start: Date, state: AtticDateCardState, proposed: Date?) -> some View {
        let d = AtticDropdownMetrics.self
        let tokens = design.tokens
        let isSelected = selected.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let lit = state.isLit(day, calendar: calendar)
        let isProposed = proposed.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        // Draft C: other months' days 25 %, past days 33 %.
        let quiet: Double = isSelected || isToday ? 1 : (!inMonth ? 0.25 : (day < start ? 0.33 : 1))
        let fill: AtticRGBA? = isSelected ? tokens.dropdownSelected : (lit || isProposed ? tokens.dropdownHighlight : nil)
        // Today keeps a ring of its own, so it reads apart from the choice.
        let ring: AtticRGBA? = isToday ? tokens.ink(.helper) : (isSelected ? tokens.dropdownRule : nil)
        let spokenState = [isToday ? String(localized: "today") : nil, isSelected ? String(localized: "chosen") : nil].compactMap { $0 }
        // A plain cell: the grid takes the pointer (`day(at:in:)`), and
        // VoiceOver presses the cell itself.
        return AtticText(verbatim: "\(calendar.component(.day, from: day))", style: isSelected || isToday ? .dropdownDaySelected : .dropdownDay,
                         ink: .body)
            .opacity(quiet)
            .frame(width: d.monthMarkWidth, height: d.monthMarkHeight)
            .background {
                if fill != nil || ring != nil {
                    AtticCalendarMark(radius: d.monthMarkRadius, fill: (fill ?? .clear).color, ring: (ring ?? .clear).color)
                }
            }
            .frame(width: d.monthCellWidth, height: d.monthCellHeight)
            .id(Self.dayID(day))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AtticDateCardFormat.spoken(day, calendar: calendar))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(spokenState.joined(separator: ", "))
            .accessibilityAction { onPick(day) }
    }

    /// The day at `point` in the grid (its own coordinates), if any.
    static func day(at point: CGPoint, in month: AtticDateMonth) -> Date? {
        let d = AtticDropdownMetrics.self
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / d.monthCellWidth), week = Int(point.y / d.monthCellHeight)
        guard column < 7, week < month.weeks else { return nil }
        return month.cells[week * 7 + column]
    }

    private static func dayID(_ day: Date) -> String { "attic.date.\(Int(day.timeIntervalSinceReferenceDate))" }
}

/// Calendar marks share one pixel-aligned outer contour; the inset ring
/// follows the same curve.
struct AtticCalendarMark: View {
    let radius: CGFloat
    let fill: Color
    let ring: Color
    @Environment(\.displayScale) private var scale

    /// A mark's outline in `rect`, drawn `inset` inside its edge: a
    /// control on curve 1.4 (Shapes, Accepted 2026-10-30), rounded by half
    /// its height, its ring concentric with it.
    static func outline(in rect: CGRect, radius: CGFloat, inset: CGFloat = 0) -> Path {
        Squircle(cornerRadius: radius, exponent: AtticShape.controlExponent).inset(by: inset).path(in: rect)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let rect = CGRect(x: (frame.minX * scale).rounded() / scale - frame.minX,
                              y: (frame.minY * scale).rounded() / scale - frame.minY,
                              width: (frame.width * scale).rounded() / scale,
                              height: (frame.height * scale).rounded() / scale)
            let width = max(1, (AtticPickerMetrics.todayRing * scale).rounded()) / scale
            let r = (radius * scale).rounded() / scale
            Self.outline(in: rect, radius: r).fill(fill)
            Self.outline(in: rect, radius: r, inset: width / 2).stroke(ring, lineWidth: width)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tag picker

/// The tag list (owner fix 5 C3/D2): "Find or add a tag", then the tags,
/// ticked when the task has them (part-ticked for a mixed selection). A
/// click adds or removes; typing filters, and Return adds what was typed
/// (a new tag when none matches).
struct AtticTagPicker: View {
    struct Tag: Identifiable {
        let name: String
        let state: AtticCheckState
        /// Quiet trailing text (Notes: how many notes carry the tag).
        var detail: String? = nil
        var id: String { name }
    }

    @Binding var query: String
    let tags: [Tag]
    /// "New tag “…”" when the query is not an existing tag.
    var create: String?
    /// The list's one highlight (index into `tags`, then the create row):
    /// the keyboard's, and the pointer moves it (`onHover`).
    var highlighted: Int?
    let onToggle: (String) -> Void
    let onCreate: (String) -> Void
    /// The field's and the list's one focus.
    var focus: FocusState<AtticDropdownFocusTarget?>.Binding
    /// The pointer entered (true) or left row `index`.
    var onHover: ((_ index: Int, _ inside: Bool) -> Void)? = nil
    /// The rows the list keeps room for (all the tags there are, as it
    /// opened); nil: the rows it shows now.
    var listRows: Int? = nil
    /// With a highlight to move, the rows are one keyboard stop
    /// (`atticDropdownList`): Tab from the field reaches them. Nil: the
    /// rows take no keyboard.
    var onListHighlight: Binding<Int?>? = nil

    /// The rows the list shows: the tags, then "New tag" when there is one.
    /// The one count the list's keyboard stop, Tab and the keys use.
    static func rowCount(tags: Int, create: String?) -> Int { tags + (create == nil ? 0 : 1) }

    /// One row at least (No tags yet, or New tag), seven at most
    /// (`tagListMaxHeight`).
    static func visibleRows(tagCount: Int) -> Int {
        let most = Int(AtticPickerMetrics.tagListMaxHeight / AtticDropdownMetrics.rowHeight)
        return max(1, min(tagCount, most))
    }

    @Environment(\.atticDropdownHeight) private var cardHeight
    @Environment(\.atticTagColouring) private var colouring

    /// Draft C's chrome around the list at rest, the card's insets
    /// excluded: the field's header and its rule, and "Tags". No foot at
    /// rest: you type in the field to add (Dropdown content: answers,
    /// owner, 2026-10-24, answer 3 A).
    static var chromeHeight: CGFloat {
        let m = AtticDropdownMetrics.self
        return (m.fieldHeaderHeight - m.inset) + m.headerRule + m.sectionHeaderHeight
    }

    /// What a typed new name adds below the list: the rule and the
    /// "New Tag “#…”" row.
    static var createHeight: CGFloat {
        AtticDropdownMetrics.separatorHeight + AtticDropdownMetrics.rowHeight
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        let shown = tags.count
        let room = Self.visibleRows(tagCount: listRows ?? shown)
        // A height that holds while typing filters the list, so the card
        // never jumps. Only a list longer than that scrolls: rows that fit
        // are plain rows (nothing to scroll, for the pointer, the keyboard
        // or the UI tests).
        let normalHeight = CGFloat(room) * m.rowHeight
        let chrome = Self.chromeHeight + (create == nil ? 0 : Self.createHeight)
        let listHeight = min(normalHeight, cardHeight.map { max(0, $0 - m.inset * 2 - chrome) } ?? normalHeight)
        let count = Self.rowCount(tags: tags.count, create: create)
        VStack(alignment: .leading, spacing: 0) {
            // Draft C: the field in its header, ruled off; "Tags"; the
            // tags with their dots and trailing ticks; then, for a typed
            // name no tag has, "New Tag “#…”" (answer 3 A: no foot at rest).
            AtticDropdownFieldHeader {
                AtticDropdownField(text: $query, placeholder: String(localized: "Tag"),
                                   systemName: "magnifyingglass", focus: focus, label: String(localized: "Find or add a tag"))
            }
            AtticDropdownSectionHeader(title: String(localized: "Tags"))
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if shown <= room && listHeight == normalHeight {
                        rows
                            .frame(height: normalHeight, alignment: .top)
                    } else {
                        AtticDropdownViewport(height: listHeight) { rows }
                    }
                }
                createRow(count: count)
            }
            .modifier(AtticOptionalDropdownList(focus: focus, highlighted: onListHighlight, count: count))
        }
        // In a card cut short the list keeps the field and shortens; the
        // card still measures its natural height: the list's full room.
        .atticDropdownHeightGivenUp(normalHeight - listHeight)
        // 224 pt, fixed (sheet 3): a longer name is cut short.
        .atticDropdownIdealWidth(Self.rowsWidth(tags: tags.map(\.name), create: create, details: tags.compactMap(\.detail)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                // Each tag's colour on its dot alone (O14-07, owner
                // 2026-10-14: in a dropdown the # and the name keep the text
                // ink; rows in the panel stay coloured), its tick after the
                // item (N-4's card).
                AtticDropdownRow(title: "#" + tag.name, check: tag.state, dot: colouring.hue(for: tag.name).ink, detail: tag.detail,
                                 isHighlighted: highlighted == index,
                                 onHover: hover(index), position: index + 1, itemCount: Self.rowCount(tags: tags.count, create: create)) {
                    onToggle(tag.name)
                }
                .id(index)
            }
            if tags.isEmpty {
                AtticText(verbatim: create == nil ? String(localized: "No tags yet") : String(localized: "No tag matches"), style: .dropdownRow, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .frame(height: AtticDropdownMetrics.rowHeight)
            }
        }
    }

    /// With a name typed that is no tag yet, "New Tag “#…”" under a rule,
    /// which adds it (the list's last keyboard row). Nothing at rest: you
    /// type in the field to add (Dropdown content: answers, owner,
    /// 2026-10-24, answer 3 A; Title Case, rule 5).
    @ViewBuilder
    private func createRow(count: Int) -> some View {
        if let create {
            AtticDropdownRule()
            // The + sits in the dots' column, so the name starts where the
            // tags' names do.
            AtticDropdownRow(title: Self.createTitle(create), check: .off, checkGlyph: "plus",
                             isHighlighted: highlighted == tags.count, onHover: hover(tags.count), position: tags.count + 1, itemCount: count) {
                onCreate(create)
            }
            .id(tags.count)
        }
    }

    /// The create row's name: "New Tag “#travel”".
    static func createTitle(_ name: String) -> String { String(localized: "New Tag “#\(name)”") }

    private func hover(_ index: Int) -> ((Bool) -> Void)? {
        onHover.map { report in { inside in report(index, inside) } }
    }

    /// The rows' width, the card's insets excluded: the card is 224 pt
    /// whatever the names (Dropdown content: answers, owner, 2026-10-24,
    /// sheet 3: "fixed at 224 pt"); a longer name is cut short.
    static func rowsWidth(tags: [String], create: String?, details: [String] = []) -> CGFloat {
        AtticDropdownMetrics.fieldCardWidth - AtticDropdownMetrics.inset * 2
    }
}

// MARK: - Tag picker card (Tasks and Notes)

/// The tag picker with its state: the query, the one highlight and the
/// keys (the E1 keyboard model). Typing filters and highlights only what
/// was typed: the tag with exactly that name, else "New tag" for it (never
/// another tag; an empty field highlights nothing, so Return does
/// nothing); ↑ ↓ move the highlight, the pointer moves it too; Return
/// presses it (a tag toggles, "New tag" adds); with Full Keyboard Access
/// the rows are one Tab stop and Space presses the highlight there; Esc is
/// the card's (it closes). The highlight is the row's identity, so it stays
/// on its tag when a toggle reorders the rows. The caller says which rows a
/// query shows: Tasks lists every tag; Notes lists its own tags first, with
/// their counts.
struct AtticTagPickerCard: View {
    /// The rows for what is typed, in order, and the name "New tag “#…”"
    /// would add (nil when the typed name is a tag already, or empty).
    let rows: (_ query: String) -> (tags: [AtticTagPicker.Tag], create: String?)
    /// The rows the list keeps room for (all there are, as it opened).
    let listRows: Int
    let onToggle: (String) -> Void
    /// Adds a new tag; false when it did not save, so what was typed stays.
    /// `completed` clears the field when a later Retry saves it.
    let onCreate: (_ name: String, _ completed: @escaping () -> Void) -> Bool
    /// The field has the keyboard as the card opens.
    var focusField = true

    @State private var query = ""
    @State private var highlight: AtticTagPickerHighlight?
    @FocusState private var focus: AtticDropdownFocusTarget?

    var body: some View {
        let shown = rows(query)
        let filtered = shown.tags
        let create = shown.create
        let count = AtticTagPicker.rowCount(tags: filtered.count, create: create)
        // The row the highlight is on now: found again by identity after
        // every change of the rows (a toggle moves the note's own tags up).
        let highlighted = highlight?.index(in: filtered, create: create)
        let highlightIndex = Binding<Int?>(
            get: { highlighted },
            set: { highlight = AtticTagPickerHighlight.at($0, in: filtered, create: create) })
        AtticTagPicker(
            query: $query,
            tags: filtered,
            create: create,
            highlighted: highlighted,
            onToggle: onToggle,
            onCreate: { name in
                let clear = { query = "" }
                if onCreate(name, clear) { clear() }
            },
            focus: $focus,
            onHover: { index, inside in
                let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                if next != highlighted { highlightIndex.wrappedValue = next }
            },
            listRows: listRows,
            onListHighlight: highlightIndex
        )
        .atticDropdownFocus($focus, when: focusField)
        .atticDropdownTabs(focus: $focus, count: count)
        // Typing highlights only what was typed (one rule for Tasks and
        // Notes): the exact tag, else "New tag" for the typed name. A
        // prefix never lights the first match ("launch" must not light
        // "launch-october", listed first in Notes), and an empty field (as
        // after a new tag saved) lights nothing, so another Return does
        // nothing rather than toggle a tag (round 5, F5).
        .onChange(of: query) { _, now in
            let typed = rows(now)
            highlight = AtticTagPickerHighlight.typed(now, in: typed.tags, create: typed.create)
        }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow:
                guard count > 0 else { return .ignored }
                highlightIndex.wrappedValue = min((highlighted ?? -1) + 1, count - 1)
                return .handled
            case .upArrow:
                guard count > 0 else { return .ignored }
                highlightIndex.wrappedValue = max((highlighted ?? count) - 1, 0)
                return .handled
            case .return, .space:
                // Space presses the highlighted row only while the rows have
                // the keyboard; in the field it types.
                if press.key == .space, focus != .list { return .ignored }
                if let highlighted, highlighted < filtered.count {
                    onToggle(filtered[highlighted].name)
                } else if let create {
                    let clear = { query = "" }
                    if onCreate(create, clear) { clear() }
                } else {
                    return .ignored
                }
                return .handled
            default:
                return .ignored
            }
        }
    }
}

extension AtticTagPickerCard {
    /// The row whose tag is exactly the typed name (`#` and case aside).
    nonisolated static func exactMatch(_ query: String, in tags: [AtticTagPicker.Tag]) -> Int? {
        guard let typed = AtticTag.normalize(query)?.lowercased() else { return nil }
        return tags.firstIndex { $0.name.lowercased() == typed }
    }
}

/// The tag picker's one highlight, kept as the row's identity (a tag's
/// name, or the "New tag" row) rather than its position: a toggle can
/// reorder the rows (Notes lists the note's own tags first), and Return or
/// Space must press the tag that was highlighted, never the one that slid
/// into its place (review P2, `bdadf46`).
enum AtticTagPickerHighlight: Hashable {
    case tag(String)
    case create

    /// Its row among `tags` (the "New tag" row follows them); nil when the
    /// rows no longer show it.
    func index(in tags: [AtticTagPicker.Tag], create: String?) -> Int? {
        switch self {
        case let .tag(name): tags.firstIndex { $0.name == name }
        case .create: create == nil ? nil : tags.count
        }
    }

    /// The row at `index` (the arrows, the pointer, the list's Tab stop).
    static func at(_ index: Int?, in tags: [AtticTagPicker.Tag], create: String?) -> Self? {
        guard let index, index >= 0 else { return nil }
        if index < tags.count { return .tag(tags[index].name) }
        return index == tags.count && create != nil ? .create : nil
    }

    /// What typing `query` highlights: the tag with exactly the typed name
    /// (`#` and case aside), else "New tag" for it; nothing for an empty
    /// field or a name that cannot be a tag. Never another tag, so Return
    /// acts only on what was typed or highlighted.
    static func typed(_ query: String, in tags: [AtticTagPicker.Tag], create: String?) -> Self? {
        if let exact = AtticTagPickerCard.exactMatch(query, in: tags) { return .tag(tags[exact].name) }
        return create == nil ? nil : .create
    }
}

// MARK: - Task picker

/// "Move to Task…" (control audit item 5): the tag picker's pattern for
/// tasks. The "Task" field, then the tasks it can go to under where they
/// are listed (Now, Later), each with a task's circle, 224 pt wide
/// (Dropdown content: answers, owner, 2026-10-24, sheet 3); typing filters,
/// the arrows move the one highlight, Return or a click chooses. Rows are built only as they
/// scroll into view, so a long list costs a screenful per keystroke.
struct AtticTaskPicker: View {
    struct Choice: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// A quiet trailing detail.
        var detail: String? = nil
        /// Where the task is listed ("Now", "Later"): the header it sits
        /// under. Choices come grouped.
        var group: String? = nil
    }

    /// Whether the choice at `index` opens a group (it gets its header).
    static func startsGroup(_ choices: [Choice], at index: Int) -> Bool {
        guard choices.indices.contains(index), choices[index].group != nil else { return false }
        return index == 0 || choices[index - 1].group != choices[index].group
    }

    @Binding var query: String
    let choices: [Choice]
    /// The list's one highlight (index into `choices`): the keyboard's, and
    /// the pointer moves it (`onHover`).
    var highlighted: Int?
    /// No task at all to choose (not a query with no match).
    var emptyText = String(localized: "No other tasks")
    let onChoose: (UUID) -> Void
    /// The field's and the list's one focus.
    var focus: FocusState<AtticDropdownFocusTarget?>.Binding
    var onHover: ((_ index: Int, _ inside: Bool) -> Void)? = nil
    /// With a highlight to move, the rows are one keyboard stop
    /// (`atticDropdownList`).
    var onListHighlight: Binding<Int?>? = nil

    var body: some View {
        let m = AtticDropdownMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            AtticDropdownFieldHeader {
                AtticDropdownField(text: $query, placeholder: String(localized: "Task"), systemName: "magnifyingglass", focus: focus)
            }
            AtticDropdownGap()
            if choices.isEmpty {
                AtticText(verbatim: query.trimmingCharacters(in: .whitespaces).isEmpty ? emptyText : String(localized: "No task matches"),
                          style: .dropdownRow, ink: .helper)
                    .padding(.horizontal, m.rowPadding)
                    .frame(height: m.rowHeight)
            } else {
                let headers = choices.indices.filter { Self.startsGroup(choices, at: $0) }.count
                let listHeight = CGFloat(choices.count) * m.rowHeight + CGFloat(headers) * m.sectionHeaderHeight
                AtticDropdownViewport(height: listHeight > AtticPickerMetrics.taskListMaxHeight
                                      ? AtticPickerMetrics.taskListMaxHeight : nil,
                                      highlighted: highlighted.flatMap { choices.indices.contains($0) ? choices[$0].id.uuidString : nil }) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            if Self.startsGroup(choices, at: index), let group = choice.group {
                                AtticDropdownSectionHeader(title: group)
                            }
                            AtticDropdownRow(title: choice.title, systemName: "circle", detail: choice.detail, isHighlighted: highlighted == index,
                                             onHover: hover(index), position: index + 1, itemCount: choices.count, scrollID: choice.id.uuidString) {
                                onChoose(choice.id)
                            }
                        }
                    }
                }
                .modifier(AtticOptionalDropdownList(focus: focus, highlighted: onListHighlight, count: choices.count))
            }
        }
        .frame(width: m.fieldCardWidth - m.inset * 2, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Move to Task"))
    }

    private func hover(_ index: Int) -> ((Bool) -> Void)? {
        onHover.map { report in { inside in report(index, inside) } }
    }
}

/// `atticDropdownList` when the picker's owner gives it a highlight to move.
private struct AtticOptionalDropdownList: ViewModifier {
    var focus: FocusState<AtticDropdownFocusTarget?>.Binding
    var highlighted: Binding<Int?>?
    let count: Int

    func body(content: Content) -> some View {
        if let highlighted {
            content.atticDropdownList(focus: focus, highlighted: highlighted, count: count)
        } else {
            content
        }
    }
}


// MARK: - Composer strip

/// What a page asks `AtticFocusRequests` for to give a strip button the
/// keyboard: the button's accessibility identifier (`composer-date`,
/// `composer-tag`, `composer-priority`).
struct AtticStripFocusID: Hashable {
    let identifier: String

    static let all = ["composer-date", "composer-tag", "composer-priority", "composer-files"].map(AtticStripFocusID.init)
}

/// The labelled buttons above the add bar (owner fix 5 A2, v17a): Date ·
/// Tag · Priority, 8 above the bar, the first icon on the circles'
/// line. The host shows it for a non-empty draft and keeps it while one of
/// its pickers is open.
///
/// Each button floats on its own glass, as the corner buttons, Aa and New
/// note do (owner B, 2026-10-22): with no bottom blur, rows scroll sharp
/// under the strip, and the glass keeps its labels readable over them.
/// One pill per button, never one capsule behind the row (it would read as
/// a second bar); the paperclip alone is a glass circle. 30 tall, the
/// floating controls' Medium height. Under Reduce Transparency, and
/// wherever the controls are not live glass, they take the same opaque
/// surface as the other raised controls.
///
/// Each button shows what the new task will get, typed or picked (owner
/// item 18, v19): its value on a filled pill (`Tomorrow`, `#home +1`,
/// `!!` in High's orange) with a clear ×; empty, its name. A button whose
/// picker is open takes the pressed fill. VoiceOver reads the button's
/// name and value and offers Clear.
struct AtticComposerStrip<DateContent: View, TagContent: View, PriorityContent: View>: View {
    typealias Value = AtticStripValue

    @Binding var datePresented: Bool
    @Binding var tagsPresented: Bool
    @Binding var priorityPresented: Bool
    var date: Value?
    var tags: Value?
    var priority: Value?
    let onClearDate: () -> Void
    let onClearTags: () -> Void
    let onClearPriority: () -> Void
    @ViewBuilder let datePicker: () -> DateContent
    @ViewBuilder let tagPicker: () -> TagContent
    @ViewBuilder let priorityPicker: () -> PriorityContent
    /// Attach (O17-06): the files waiting for the new task, the picker that
    /// adds more, and the × that removes them. nil: no Attach button.
    var files: Value? = nil
    var onAttach: (() -> Void)? = nil
    var onClearFiles: () -> Void = {}

    /// The width the strip may take (the bar's), as laid out.
    @State private var available: CGFloat = .infinity

    /// The buttons' names, and the values' words and styles, for the widths.
    private var faces: [(title: String, value: Value?)] {
        [(String(localized: "Date"), date), (String(localized: "Tag"), tags), (String(localized: "Priority"), priority)]
            + (onAttach == nil ? [] : [(String(localized: "Attach"), files)])
    }

    /// Attach is the strip's quiet extra: its paperclip alone until files
    /// wait (its name stays its tooltip and VoiceOver label).
    private var attachIconOnly: Set<Int> { onAttach != nil && files == nil ? [3] : [] }

    var body: some View {
        // Common values in full (deep review P3-01: "Tomorr…", "#q…"):
        // when the three buttons would not fit at their usual padding,
        // they close up their inner gaps before anything is cut short.
        // Before that, an unset button gives up its name (icon only; the
        // name stays its tooltip and VoiceOver label), Priority first, so a
        // value is never cut short beside an empty button's name (CU review
        // P3: "#cuqa" showed as "#c…" beside "Priority").
        let iconOnly = Self.iconOnlyButtons(faces, available: available, fixed: attachIconOnly)
        let compact = Self.needsCompactGaps(faces, available: available, iconOnly: iconOnly)
        // One glass container for the four pills (as the header's pair):
        // one backdrop, and their shapes never flow into each other.
        AtticControlGroup {
            HStack(spacing: AtticPickerMetrics.stripSpacing) {
                AtticStripButton(systemName: "calendar", title: String(localized: "Date"), value: date, isOpen: datePresented,
                                 identifier: "composer-date", compact: compact, showsTitle: !iconOnly.contains(0),
                                 keepsPrefix: 5, keptPrefixWidth: AtticPickerMetrics.stripDatePrefix,
                                 clearLabel: String(localized: "Clear date"), open: { datePresented = true }, clear: onClearDate)
                    // With all three set, a long date gives way after the tag
                    // (never below its first words).
                    .layoutPriority(-0.5)
                    .atticDropdown(isPresented: $datePresented, prefer: .above, label: String(localized: "Date")) {
                        datePicker()
                    }
                AtticStripButton(systemName: "tag", title: String(localized: "Tag"), value: tags, isOpen: tagsPresented,
                                 identifier: "composer-tag", compact: compact, showsTitle: !iconOnly.contains(1),
                                 keepsPrefix: 4, keptPrefixWidth: AtticPickerMetrics.stripTagPrefix,
                                 clearLabel: String(localized: "Clear tags"), open: { tagsPresented = true }, clear: onClearTags)
                    .layoutPriority(-1)
                    .atticDropdown(isPresented: $tagsPresented, prefer: .above, label: String(localized: "Tags")) {
                        tagPicker()
                    }
                AtticStripButton(systemName: "exclamationmark", title: String(localized: "Priority"), value: priority, isOpen: priorityPresented,
                                 identifier: "composer-priority", compact: compact, showsTitle: !iconOnly.contains(2),
                                 clearLabel: String(localized: "Clear priority"), open: { priorityPresented = true }, clear: onClearPriority)
                    .fixedSize(horizontal: true, vertical: false)
                    .atticDropdown(isPresented: $priorityPresented, prefer: .above, label: String(localized: "Priority"),
                                   contentHeight: AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4) {
                        priorityPicker()
                    }
                if let onAttach {
                    AtticStripButton(systemName: "paperclip", title: String(localized: "Attach"), value: files, isOpen: false,
                                     identifier: "composer-files", compact: compact, showsTitle: !iconOnly.contains(3),
                                     keepsPrefix: 4, keptPrefixWidth: AtticPickerMetrics.stripTagPrefix,
                                     clearLabel: String(localized: "Remove files"), open: onAttach, clear: onClearFiles)
                        // A long file name gives way first.
                        .layoutPriority(-1.5)
                }
            }
        }
        .frame(height: AtticPickerMetrics.stripHeight)
        // The room it has: the bar's width, whatever the buttons take.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - available) > 0.5 { available = width }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(onAttach == nil ? String(localized: "Date, tag and priority")
                            : String(localized: "Date, tag, priority and files"))
    }

    /// The width the three buttons take at their usual padding: each
    /// value's icon, words, × and gaps, or the empty button's name (or its
    /// icon alone, for the buttons in `iconOnly`).
    nonisolated static func usualWidth(_ faces: [(title: String, value: AtticStripValue?)], iconOnly: Set<Int> = []) -> CGFloat {
        let m = AtticSmallControlMetrics.self
        let buttons = faces.enumerated().map { index, face -> CGFloat in
            guard let value = face.value else {
                guard !iconOnly.contains(index) else { return AtticPickerMetrics.stripHeight }
                let name = AtticTextStyle.controlLabel.measuredWidth(face.title)
                return max(AtticControlSize.smallMinWidth, m.labelPadding * 2 + m.iconSize + m.iconLabelGap + name)
            }
            return m.labelPadding + m.iconSize + m.iconLabelGap + value.style.measuredWidth(value.text)
                + AtticPickerMetrics.stripClearGap + AtticPickerMetrics.stripClearSize + AtticPickerMetrics.stripValueTrailing
        }
        return buttons.reduce(0, +) + AtticPickerMetrics.stripSpacing * CGFloat(max(0, buttons.count - 1))
    }

    /// Whether the buttons close up their inner gaps to fit `available`.
    nonisolated static func needsCompactGaps(_ faces: [(title: String, value: AtticStripValue?)], available: CGFloat,
                                             iconOnly: Set<Int> = []) -> Bool {
        available.isFinite && usualWidth(faces, iconOnly: iconOnly) > available + 0.5
    }

    /// The unset buttons that show their icon alone so the strip fits
    /// `available`: none while it fits; then from the last (Priority)
    /// back, until it fits or every unset button is an icon. Only when a
    /// value is set: three empty buttons keep their names.
    nonisolated static func iconOnlyButtons(_ faces: [(title: String, value: AtticStripValue?)], available: CGFloat,
                                            fixed: Set<Int> = []) -> Set<Int> {
        guard available.isFinite, faces.contains(where: { $0.value != nil }) else { return fixed }
        var iconOnly = fixed
        for index in faces.indices.reversed() where faces[index].value == nil {
            if usualWidth(faces, iconOnly: iconOnly) <= available + 0.5 { break }
            iconOnly.insert(index)
        }
        return iconOnly
    }
}

/// A strip button's value: the words it shows, their ink and style, and
/// how VoiceOver says it.
struct AtticStripValue: Equatable {
    let text: String
    var ink: AtticInk = .heading
    var style: AtticTextStyle = .controlLabel
    let spoken: String
    /// The whole value for the tooltip ("#qatest #work"; "Tomorrow, Thu 3
    /// Oct"); nil shows `text`.
    var full: String? = nil
}

/// One strip button: the small button's face (icon, then its name) until
/// it has a value; then the value with a clear × at its end (v19: 9 pt
/// before the icon, 7 after the ×). Always on the raised material (live
/// glass, or its opaque stand-in): a set value adds the recessed fill
/// inside it, as before the glass, and an open picker the selected chip.
private struct AtticStripButton: View {
    let systemName: String
    let title: String
    let value: AtticStripValue?
    let isOpen: Bool
    /// For UI tests: the button's; its × adds "-clear".
    let identifier: String
    /// The strip is short of room: the value's inner gaps close up (its
    /// icon keeps its place on the circles' line).
    var compact = false
    /// An unset button shows its name; false: its icon alone (the strip
    /// is short of room and a value needs it).
    var showsTitle = true
    /// How many characters of a long value always stay (then "…"): a tag
    /// squeezed by a date and a priority still says what it is ("#laun…"),
    /// never a lone "#".
    var keepsPrefix = 0
    /// The room those characters and their "…" take (a token, not measured).
    var keptPrefixWidth: CGFloat = 0
    let clearLabel: String
    let open: () -> Void
    let clear: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var pressed = false
    @State private var clearHovered = false
    /// The button's own keyboard focus (a Tab stop while keyboard
    /// navigation is on), which a page's Tab order can ask for (A10).
    @FocusState private var focused: Bool

    /// The strip's glyphs at one visual density (D-21, icon audit A3-04):
    /// the calendar's filled header made it the heaviest, so it is drawn
    /// light; the tag a point smaller; Priority is the list's own "!"
    /// mark, not a flag.
    static func glyph(_ systemName: String, size: CGFloat) -> (size: CGFloat, weight: Font.Weight) {
        switch systemName {
        case "calendar": (13, .light)
        case "tag": (12, .regular)
        case "exclamationmark": (13, .regular)
        default: (size, .regular)
        }
    }

    /// The least the button keeps: its name's minimum; a value's icon and
    /// the first characters of a long one (then "…").
    private var labelFloor: CGFloat {
        let m = AtticSmallControlMetrics.self
        guard let value else { return iconOnly ? AtticPickerMetrics.stripHeight : AtticControlSize.smallMinWidth }
        // A short value (a tag like "#a33") is never squeezed: it keeps its
        // whole text, so a date or a long tag gives way first (A39 F12; it
        // showed as "#…" beside a date and a priority).
        guard value.text.count > keepsPrefix + 1 else {
            return m.labelPadding + m.iconSize + iconLabelGap + value.style.measuredWidth(value.text) + clearGap
        }
        return m.labelPadding + m.iconSize + iconLabelGap + keptPrefixWidth + clearGap
    }

    /// Unset and nameless: a glass circle around its icon.
    private var iconOnly: Bool { value == nil && !showsTitle }

    /// What the material shows: hover, press and the disabled ghost.
    private var state: AtticControlState {
        if !isEnabled { return .disabled }
        if pressed { return .pressed }
        return hovered ? .hover : .rest
    }

    private var iconLabelGap: CGFloat {
        compact && value != nil ? AtticPickerMetrics.stripCompactIconGap : AtticSmallControlMetrics.iconLabelGap
    }

    private var clearGap: CGFloat {
        compact ? AtticPickerMetrics.stripCompactClearGap : AtticPickerMetrics.stripClearGap
    }

    var body: some View {
        let m = AtticSmallControlMetrics.self
        let height = AtticPickerMetrics.stripHeight
        let radius = AtticRadius.control(height: height)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tokens = design.tokens
        // Inside the glass (whose own fill shows hover and press): an open
        // picker's selected chip; a set value's recessed fill, so it still
        // reads as set; nothing for an empty button.
        let fill: AtticRGBA? = isOpen ? tokens.chipSelected : (value == nil ? nil : tokens.recessed)
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: iconLabelGap) {
                    let glyph = Self.glyph(systemName, size: m.iconSize)
                    AtticIcon(systemName: systemName, size: glyph.size, weight: glyph.weight, ink: isEnabled ? .glyph : .disabledIcon)
                    if let value {
                        // A long tag gives way first (the strip keeps to the
                        // bar's width); the full value is the tooltip.
                        AtticText(verbatim: value.text, style: value.style, ink: isEnabled ? value.ink : .disabledText, truncates: true)
                    } else if showsTitle {
                        AtticText(verbatim: title, style: .rowMetaEmphasis, ink: isEnabled ? .heading : .disabledText)
                    }
                }
                .padding(.leading, iconOnly ? 0 : m.labelPadding)
                .padding(.trailing, iconOnly ? 0 : (value == nil ? m.labelPadding : clearGap))
                .frame(minWidth: labelFloor, maxWidth: iconOnly ? height : nil, minHeight: height, maxHeight: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(AtticPressReportingButtonStyle(isPressed: $pressed))
            .focused($focused)
            .atticFocusRequestTarget(AtticStripFocusID(identifier: identifier), focused: $focused)
            .focusEffectDisabled()
            .atticOwnFocusRing(.rounded(radius: radius, height: height))
            // The whole value, however short the button is.
            .help(value.map { "\(title): \($0.full ?? $0.text)" } ?? title)
            .accessibilityLabel(title)
            .accessibilityValue(value?.spoken ?? "")
            .accessibilityIdentifier(identifier)
            .accessibilityActions {
                if value != nil { Button(String(localized: "Clear"), action: clear) }
            }
            if value != nil {
                Button(action: clear) {
                    AtticIcon(systemName: "xmark", size: AtticPickerMetrics.stripClearGlyph, weight: .semibold,
                              ink: isEnabled ? .icon : .disabledIcon)
                        .frame(width: AtticPickerMetrics.stripClearSize, height: AtticPickerMetrics.stripClearSize)
                        .background(Circle().fill((clearHovered ? tokens.chipSelected : .clear).color))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .atticOwnFocusRing(.circle(diameter: AtticPickerMetrics.stripClearSize))
                .onHover { clearHovered = $0 }
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
                .accessibilityIdentifier(identifier + "-clear")
                .padding(.trailing, compact ? AtticPickerMetrics.stripCompactValueTrailing : AtticPickerMetrics.stripValueTrailing)
                .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: nil))
            }
        }
        .frame(height: height)
        .background { if let fill { shape.fill(fill.color) } }
        .atticRaisedMaterial(cornerRadius: radius, state: state, interactive: state != .disabled)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: value != nil), value: value)
    }
}

/// A plain button that tells its host when it is held down, so the host's
/// own surface (the strip pill's material) can show the press.
private struct AtticPressReportingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in isPressed = pressed }
    }
}

// MARK: - Suggestions

/// The suggestions over the add bar while typing (owner fix 5 B, v17b): a
/// raised list of choices. The keyboard stays in the field: ↑ ↓ move the
/// highlight, Tab or Return take it, Esc hides the list.
struct AtticSuggestionList: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        var systemName: String?
        var detail: String?
    }

    let items: [Item]
    let highlighted: Int
    /// The pointer moves the one highlight (a list always has one: Tab and
    /// Return take it).
    var onHover: ((Int) -> Void)? = nil
    let onChoose: (Int) -> Void

    /// The card's width for `items` before the width rule: its widest row
    /// (icon, name, detail) and the card's inset, measured without laying
    /// the list out, so a list whose rows change while it shows ("#cuqa",
    /// then "Create #cuqaz") is as wide as its rows (CU review P3: "Create
    /// #c…").
    static func idealWidth(_ items: [Item]) -> CGFloat {
        let m = AtticDropdownMetrics.self
        let widest = items.map { item -> CGFloat in
            (item.systemName == nil ? 0 : m.iconSlot + m.columnGap)
                + AtticTextStyle.dropdownRow.measuredWidth(item.title)
                + (item.detail.map { m.detailGap + AtticTextStyle.shortcut.measuredWidth($0) } ?? 0)
        }.max() ?? 0
        return m.inset * 2 + m.rowPadding * 2 + widest
    }

    var body: some View {
        AtticDropdownCard() {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AtticDropdownRow(title: item.title, systemName: item.systemName, detail: item.detail,
                               isHighlighted: index == highlighted,
                               onHover: onHover.map { report in { inside in if inside { report(index) } } },
                               position: index + 1, itemCount: items.count) { onChoose(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Suggestions"))
    }
}

// MARK: - Picker surface

/// A picker inside a native pop-over (which may reach past the panel): its
/// padding and Attic's opaque pop-over fill, so its text keeps its contrast
/// whatever the desktop behind the pop-over's glass (the see-through native
/// pop-over washed Dark's secondary text out over a light desktop).
private struct AtticPickerSurface: ViewModifier {
    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        content
            .padding(AtticPopoverMetrics.padding)
            .background(design.tokens.popoverFill.color)
    }
}

extension View {
    func atticPickerSurface() -> some View { modifier(AtticPickerSurface()) }

    /// Attic's pop-over: the native one, whose content owns every key while
    /// it has the keyboard. SwiftUI offers a key the pop-over's content
    /// leaves unhandled to the views it was presented from, so without this
    /// the date picker's Backspace or Space reached the row's Delete or
    /// Complete (round 5, the class of the owner's blocker).
    func atticPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            content().background(AtticPopoverWindowMarker(arrowEdge: arrowEdge))
        }
    }
}

/// Notes the pop-over's window with `AtticTextInput`, so no row or page
/// command answers a key while that window has the keyboard; and, when the
/// feel asks for it, springs the pop-over in from its arrow
/// (`AtticPopoverPop`).
struct AtticPopoverWindowMarker: NSViewRepresentable {
    var arrowEdge: Edge = .top

    final class Marker: NSView {
        var arrowEdge: Edge = .top

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AtticTextInput.notePopover(window)
            AtticPopoverPop.play(in: window, arrowEdge: arrowEdge)
        }
    }

    func makeNSView(context: Context) -> Marker {
        let marker = Marker(frame: .zero)
        marker.arrowEdge = arrowEdge
        return marker
    }

    func updateNSView(_ view: Marker, context: Context) { view.arrowEdge = arrowEdge }
}

/// The native pop-over's spring-in (the Motion Lab's experimental "native
/// pop-overs" switch, off in every feel): the system still fades the
/// pop-over in; this adds the feel's appear spring as a scale-up from the
/// feel's appear scale, anchored at the arrow (where the button is), on
/// the pop-over window's frame view. It is a Core Animation animation of
/// the layer's transform only (drawn by the render server, nothing laid
/// out), added once as the pop-over opens and gone when it ends; the
/// model transform is never changed. Leaving stays the system's.
@MainActor
enum AtticPopoverPop {
    static let key = "atticPopoverPop"

    static func play(in window: NSWindow, arrowEdge: Edge) {
        let tuning = AtticMotionTuning.current
        guard tuning.popsNativePopovers, !AtticMotionPreference.reducesMotion,
              let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer, CATransform3DIsIdentity(layer.transform) else { return }
        let bounds = layer.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let anchor = anchor(frame: window.frame, bounds: bounds, mouse: NSEvent.mouseLocation,
                            arrowEdge: arrowEdge, flipped: view.isFlipped)
        let spring = AtticMotionPreset.popover.spring(in: tuning)
        let animation = CASpringAnimation(perceptualDuration: spring.response, bounce: spring.bounce)
        animation.keyPath = "transform"
        animation.fromValue = NSValue(caTransform3D: transform(scale: CGFloat(tuning.appearScale), about: anchor, in: layer))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: key)
    }

    /// A scale about `point` (the layer's own coordinates).
    static func transform(scale: CGFloat, about point: CGPoint, in layer: CALayer) -> CATransform3D {
        // A layer's transform acts about its anchor point.
        let x = point.x - layer.bounds.minX - layer.anchorPoint.x * layer.bounds.width
        let y = point.y - layer.bounds.minY - layer.anchorPoint.y * layer.bounds.height
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
    }

    /// Where the arrow is: the edge that faces the button (from the
    /// pointer, which clicked it, when it is by the pop-over; else from
    /// `arrowEdge`, the button's edge the pop-over hangs from), at the
    /// pointer's x or the middle.
    static func anchor(frame: CGRect, bounds: CGRect, mouse: CGPoint, arrowEdge: Edge, flipped: Bool) -> CGPoint {
        var fromTop = arrowEdge == .bottom
        var x = bounds.midX
        switch arrowEdge {
        case .leading: return CGPoint(x: bounds.maxX, y: bounds.midY)
        case .trailing: return CGPoint(x: bounds.minX, y: bounds.midY)
        case .top, .bottom: break
        }
        if frame.width > 0, mouse.x >= frame.minX - 24, mouse.x <= frame.maxX + 24 {
            if mouse.y >= frame.maxY - 8, mouse.y <= frame.maxY + 120 {
                fromTop = true
            } else if mouse.y <= frame.minY + 8, mouse.y >= frame.minY - 120 {
                fromTop = false
            }
            x = bounds.minX + min(max(mouse.x - frame.minX, 16), max(bounds.width - 16, 16))
        }
        let top = flipped ? bounds.minY : bounds.maxY
        let bottom = flipped ? bounds.maxY : bounds.minY
        return CGPoint(x: x, y: fromTop ? top : bottom)
    }
}
