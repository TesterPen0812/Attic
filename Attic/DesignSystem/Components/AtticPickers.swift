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
struct AtticPickerDivider: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        Rectangle().fill(design.tokens.divider.color)
            .frame(height: AtticHairline.width)
            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
            .padding(.vertical, AtticPickerMetrics.dividerGap)
            .accessibilityHidden(true)
    }
}

// MARK: - Date picker

/// The one date picker (owner fix 5, v17 A3/C2): the quick days with the
/// day each resolves to, then the month. Weeks start on the locale's first
/// weekday; today is ringed, the chosen day filled; days before today are
/// quiet but can still be picked. ← → ↑ ↓ move a keyboard cursor through
/// the days, Page Up / Page Down change the month, Return picks, Esc
/// closes (the host returns the keyboard to where it came from).
struct AtticDatePicker: View {
    struct Quick: Identifiable {
        let id: String
        let title: String
        let detail: String
        var isChecked = false
    }

    struct Day: Identifiable, Equatable {
        let id: String
        let number: String
        let inMonth: Bool
        let isToday: Bool
        let isSelected: Bool
        let isPast: Bool
        /// Spoken: "Thursday 1 October".
        let spoken: String
    }

    let quick: [Quick]
    /// Shows a check column (the row's picker ticks the current day).
    var showsChecks = false
    let monthTitle: String
    let weekdays: [String]
    let days: [Day]
    /// The cursor's day (id) when it is the highlight (the keyboard moved
    /// it, or the pointer is on that day).
    var cursor: String?
    /// "Remove date" (a row that has a date).
    var removeTitle: String?
    /// The quick day's row (its id, or `removeID`) the pointer is on: the
    /// one highlight then, never with the cursor (round 5).
    var highlightedRow: String? = nil
    let onQuick: (String) -> Void
    let onDay: (String) -> Void
    let onMonth: (Int) -> Void
    var onRemove: () -> Void = {}
    /// The pointer entered (true) or left a row (a quick id, `removeID`).
    var onHoverRow: ((_ id: String, _ inside: Bool) -> Void)? = nil
    /// The pointer entered (true) or left a day (its id).
    var onHoverDay: ((_ id: String, _ inside: Bool) -> Void)? = nil

    /// "Remove date"'s row id for `highlightedRow` and `onHoverRow`.
    static let removeID = "attic.date.remove"

    @Environment(\.atticDesign) private var design

    var body: some View {
        let d = AtticDropdownMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(quick.enumerated()), id: \.element.id) { index, item in
                AtticDropdownRow(title: item.title, check: showsChecks ? (item.isChecked ? .on : .off) : nil,
                                 detail: item.detail, isHighlighted: highlightedRow == item.id, onHover: hoverRow(item.id),
                                 position: index + 1, itemCount: quick.count + (removeTitle == nil ? 0 : 1)) {
                    onQuick(item.id)
                }
            }
            AtticDropdownGap(height: d.fieldGap)
            HStack(spacing: 0) {
                AtticText(verbatim: monthTitle, style: .dropdownHeading, ink: .heading)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: d.detailGap)
                monthButton(-1, systemName: "chevron.left", label: String(localized: "Previous month"))
                monthButton(1, systemName: "chevron.right", label: String(localized: "Next month"))
            }
            .padding(.leading, d.rowPadding)
            .frame(height: d.monthHeaderHeight)
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    AtticText(verbatim: symbol, style: .tag, ink: .helper)
                        .frame(width: d.monthCellWidth, height: d.weekdayHeight)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(d.monthCellWidth), spacing: 0), count: 7), spacing: 0) {
                ForEach(days) { day in
                    dayCell(day)
                }
            }
            if let removeTitle {
                AtticDropdownGap(height: d.fieldGap)
                AtticDropdownRow(title: removeTitle, check: showsChecks ? .off : nil,
                                 isHighlighted: highlightedRow == Self.removeID, onHover: hoverRow(Self.removeID), position: quick.count + 1,
                                 itemCount: quick.count + 1, action: onRemove)
            }
        }
        .frame(width: d.monthCellWidth * 7)
    }

    private func hoverRow(_ id: String) -> ((Bool) -> Void)? {
        onHoverRow.map { report in { inside in report(id, inside) } }
    }

    private func monthButton(_ step: Int, systemName: String, label: String) -> some View {
        Button { onMonth(step) } label: {
            AtticIcon(systemName: systemName, size: AtticDropdownMetrics.monthChevron, weight: .semibold, ink: .icon)
                .frame(width: AtticDropdownMetrics.monthButton, height: AtticDropdownMetrics.monthButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.circle(diameter: AtticDropdownMetrics.monthButton))
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Day) -> some View {
        let m = AtticPickerMetrics.self
        let d = AtticDropdownMetrics.self
        let tokens = design.tokens
        let ink: AtticInk = day.isSelected ? .onInverse : ((!day.inMonth || day.isPast) ? .helper : .body)
        return Button { onDay(day.id) } label: {
            ZStack {
                if day.isSelected {
                    Circle().fill(tokens.color(.inverseFill))
                } else if cursor == day.id {
                    Circle().fill(tokens.dropdownHighlight.color)
                }
                if day.isToday, !day.isSelected {
                    Circle().strokeBorder(tokens.color(.heading), lineWidth: m.todayRing)
                }
                AtticText(verbatim: day.number, style: day.isToday ? .rowTitleActive : .listBody, ink: ink)
                    .monospacedDigit()
            }
            .frame(width: d.monthDisc, height: d.monthDisc)
            .frame(width: d.monthCellWidth, height: d.monthCellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticOwnFocusRing(.circle(diameter: d.monthDisc))
        .id(day.id)
        .preference(key: AtticDropdownHighlightKey.self, value: cursor == day.id ? day.id : nil)
        // The pointer moves the cursor, as it moves a menu's highlight.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                onHoverDay?(day.id, true)
            case .ended:
                onHoverDay?(day.id, false)
            }
        }
        .accessibilityLabel(day.spoken)
        .accessibilityAddTraits(day.isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(day.isToday ? String(localized: "today") : "")
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
    var fieldFocused: FocusState<Bool>.Binding
    /// The pointer entered (true) or left row `index`.
    var onHover: ((_ index: Int, _ inside: Bool) -> Void)? = nil
    /// The rows the list keeps room for (all the tags there are, as it
    /// opened); nil: the rows it shows now.
    var listRows: Int? = nil
    /// The rows as one keyboard stop (`atticDropdownList`): Tab from the
    /// field reaches them. Nil: the rows take no keyboard.
    var listFocus: FocusState<Bool>.Binding? = nil
    var onListHighlight: Binding<Int?>? = nil

    /// One row at least (No tags yet, or New tag), seven at most
    /// (`tagListMaxHeight`).
    static func visibleRows(tagCount: Int) -> Int {
        let most = Int(AtticPickerMetrics.tagListMaxHeight / AtticDropdownMetrics.rowHeight)
        return max(1, min(tagCount, most))
    }

    @Environment(\.atticDropdownHeight) private var cardHeight

    var body: some View {
        let m = AtticDropdownMetrics.self
        let shown = tags.count + (create == nil ? 0 : 1)
        let room = Self.visibleRows(tagCount: listRows ?? shown)
        // A height that holds while typing filters the list, so the card
        // never jumps. Only a list longer than that scrolls: rows that fit
        // are plain rows (nothing to scroll, for the pointer, the keyboard
        // or the UI tests).
        let normalHeight = CGFloat(room) * m.rowHeight
        let listHeight = min(normalHeight, cardHeight.map { max(0, $0 - m.inset * 2 - m.fieldHeight - m.fieldGap) } ?? normalHeight)
        VStack(alignment: .leading, spacing: 0) {
            AtticDropdownField(text: $query, placeholder: String(localized: "Find or add a tag"),
                               systemName: "magnifyingglass", focus: fieldFocused)
                .padding(.bottom, m.fieldGap)
            Group {
                if shown <= room && listHeight == normalHeight {
                    rows
                        .frame(height: normalHeight, alignment: .top)
                } else {
                    AtticDropdownViewport(height: listHeight) { rows }
                }
            }
            .modifier(AtticOptionalDropdownList(focus: listFocus, highlighted: onListHighlight, count: shown))
        }
        // In a card cut short the list keeps the field and shortens; the
        // card still measures its natural height: the list's full room.
        .atticDropdownHeightGivenUp(normalHeight - listHeight)
        // "New tag “#…”" appears as you type: the card widens for it.
        .atticDropdownIdealWidth(Self.rowsWidth(tags: tags.map(\.name), create: create, details: tags.compactMap(\.detail)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                AtticDropdownRow(title: "#" + tag.name, check: tag.state, detail: tag.detail, isHighlighted: highlighted == index,
                                 onHover: hover(index), position: index + 1, itemCount: tags.count + (create == nil ? 0 : 1)) {
                    onToggle(tag.name)
                }
                .id(index)
            }
            if let create {
                AtticDropdownRow(title: String(localized: "New tag “#\(create)”"), systemName: "plus", check: .off,
                                 isHighlighted: highlighted == tags.count, onHover: hover(tags.count), position: tags.count + 1, itemCount: tags.count + 1) {
                    onCreate(create)
                }
                .id(tags.count)
            }
            if tags.isEmpty, create == nil {
                AtticText(verbatim: String(localized: "No tags yet"), style: .dropdownRow, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .frame(height: AtticDropdownMetrics.rowHeight)
            }
        }
    }

    private func hover(_ index: Int) -> ((Bool) -> Void)? {
        onHover.map { report in { inside in report(index, inside) } }
    }

    /// The widest row's width (check column, the create row's icon, the
    /// name), the card's insets excluded: measured from the names, no
    /// layout pass.
    static func rowsWidth(tags: [String], create: String?, details: [String] = []) -> CGFloat {
        let m = AtticDropdownMetrics.self
        let style = AtticTextStyle.dropdownRow
        let widestDetail = details.map { AtticTextStyle.shortcut.measuredWidth($0) }.max().map { m.detailGap + $0 } ?? 0
        let widestTag = (tags.map { style.measuredWidth("#" + $0) }.max() ?? 0) + widestDetail
        let createRow = create.map { m.iconSlot + m.columnGap + style.measuredWidth(String(localized: "New tag “#\($0)”")) } ?? 0
        return ceil(m.rowPadding * 2 + m.checkSlot + m.columnGap + max(widestTag, createRow))
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
    @FocusState private var fieldFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        let shown = rows(query)
        let filtered = shown.tags
        let create = shown.create
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
            fieldFocused: $fieldFocused,
            onHover: { index, inside in
                let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                if next != highlighted { highlightIndex.wrappedValue = next }
            },
            listRows: listRows,
            listFocus: $listFocused,
            onListHighlight: highlightIndex
        )
        .atticDropdownFocus($fieldFocused, when: focusField)
        .atticDropdownTabs(field: $fieldFocused, list: $listFocused)
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
            let count = filtered.count + (create == nil ? 0 : 1)
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
                if press.key == .space, !listFocused { return .ignored }
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
/// tasks. "Find a task", then the tasks it can go to, each with where it
/// is listed ("Now", "Later"); typing filters, the arrows move the one
/// highlight, Return or a click chooses. Rows are built only as they
/// scroll into view, so a long list costs a screenful per keystroke.
struct AtticTaskPicker: View {
    struct Choice: Identifiable, Equatable {
        let id: UUID
        let title: String
        /// Where the task is listed ("Now", "Later").
        let detail: String?
    }

    @Binding var query: String
    let choices: [Choice]
    /// The list's one highlight (index into `choices`): the keyboard's, and
    /// the pointer moves it (`onHover`).
    var highlighted: Int?
    /// No task at all to choose (not a query with no match).
    var emptyText = String(localized: "No other tasks")
    let onChoose: (UUID) -> Void
    var fieldFocused: FocusState<Bool>.Binding
    var onHover: ((_ index: Int, _ inside: Bool) -> Void)? = nil
    /// The rows as one keyboard stop (`atticDropdownList`).
    var listFocus: FocusState<Bool>.Binding? = nil
    var onListHighlight: Binding<Int?>? = nil

    var body: some View {
        let m = AtticDropdownMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            AtticDropdownField(text: $query, placeholder: String(localized: "Find a task"), focus: fieldFocused)
                .padding(.bottom, m.fieldGap)
            if choices.isEmpty {
                AtticText(verbatim: query.trimmingCharacters(in: .whitespaces).isEmpty ? emptyText : String(localized: "No task matches"),
                          style: .dropdownRow, ink: .helper)
                    .padding(.horizontal, m.rowPadding)
                    .frame(height: m.rowHeight)
            } else {
                AtticDropdownViewport(height: CGFloat(choices.count) * m.rowHeight > AtticPickerMetrics.taskListMaxHeight
                                      ? AtticPickerMetrics.taskListMaxHeight : nil,
                                      highlighted: highlighted.flatMap { choices.indices.contains($0) ? choices[$0].id.uuidString : nil }) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            AtticDropdownRow(title: choice.title, detail: choice.detail, isHighlighted: highlighted == index,
                                             onHover: hover(index), position: index + 1, itemCount: choices.count, scrollID: choice.id.uuidString) {
                                onChoose(choice.id)
                            }
                        }
                    }
                }
                .modifier(AtticOptionalDropdownList(focus: listFocus, highlighted: onListHighlight, count: choices.count))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Move to Task"))
    }

    private func hover(_ index: Int) -> ((Bool) -> Void)? {
        onHover.map { report in { inside in report(index, inside) } }
    }
}

/// `atticDropdownList` when the picker's owner gives it a focus.
private struct AtticOptionalDropdownList: ViewModifier {
    var focus: FocusState<Bool>.Binding?
    var highlighted: Binding<Int?>?
    let count: Int

    func body(content: Content) -> some View {
        if let focus, let highlighted {
            content.atticDropdownList(focus: focus, highlighted: highlighted, count: count)
        } else {
            content
        }
    }
}

private struct AtticPickerFieldBackground: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        RoundedRectangle(cornerRadius: AtticRadius.control(height: AtticControlSize.smallHeight), style: .continuous)
            .fill(design.tokens.recessed.color)
    }
}

// MARK: - Composer strip

/// The labelled buttons above the add bar (owner fix 5 A2, v17a): Date ·
/// Tag · Priority, 28 tall, 8 above the bar, the first icon on the circles'
/// line. The host shows it for a non-empty draft and keeps it while one of
/// its pickers is open.
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

    /// The width the strip may take (the bar's), as laid out.
    @State private var available: CGFloat = .infinity

    /// The buttons' names, and the values' words and styles, for the widths.
    private var faces: [(title: String, value: Value?)] {
        [(String(localized: "Date"), date), (String(localized: "Tag"), tags), (String(localized: "Priority"), priority)]
    }

    var body: some View {
        // Common values in full (deep review P3-01: "Tomorr…", "#q…"):
        // when the three buttons would not fit at their usual padding,
        // they close up their inner gaps before anything is cut short.
        // Before that, an unset button gives up its name (icon only; the
        // name stays its tooltip and VoiceOver label), Priority first, so a
        // value is never cut short beside an empty button's name (CU review
        // P3: "#cuqa" showed as "#c…" beside "Priority").
        let iconOnly = Self.iconOnlyButtons(faces, available: available)
        let compact = Self.needsCompactGaps(faces, available: available, iconOnly: iconOnly)
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
            AtticStripButton(systemName: "flag", title: String(localized: "Priority"), value: priority, isOpen: priorityPresented,
                             identifier: "composer-priority", compact: compact, showsTitle: !iconOnly.contains(2),
                             clearLabel: String(localized: "Clear priority"), open: { priorityPresented = true }, clear: onClearPriority)
                .fixedSize(horizontal: true, vertical: false)
                .atticDropdown(isPresented: $priorityPresented, prefer: .above, label: String(localized: "Priority"),
                               contentHeight: AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4) {
                    priorityPicker()
                }
        }
        .frame(height: AtticControlSize.smallHeight)
        // The room it has: the bar's width, whatever the buttons take.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - available) > 0.5 { available = width }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Date, tag and priority"))
    }

    /// The width the three buttons take at their usual padding: each
    /// value's icon, words, × and gaps, or the empty button's name (or its
    /// icon alone, for the buttons in `iconOnly`).
    nonisolated static func usualWidth(_ faces: [(title: String, value: AtticStripValue?)], iconOnly: Set<Int> = []) -> CGFloat {
        let m = AtticSmallControlMetrics.self
        let buttons = faces.enumerated().map { index, face -> CGFloat in
            guard let value = face.value else {
                guard !iconOnly.contains(index) else { return max(AtticControlSize.smallMinWidth, m.labelPadding * 2 + m.iconSize) }
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
    nonisolated static func iconOnlyButtons(_ faces: [(title: String, value: AtticStripValue?)], available: CGFloat) -> Set<Int> {
        guard available.isFinite, faces.contains(where: { $0.value != nil }) else { return [] }
        var iconOnly: Set<Int> = []
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
/// it has a value; then the value on a filled pill, with a clear × at its
/// end (v19: 9 pt before the icon, 7 after the ×).
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
    @State private var clearHovered = false

    /// The least the button keeps: its name's minimum; a value's icon and
    /// the first characters of a long one (then "…").
    private var labelFloor: CGFloat {
        let m = AtticSmallControlMetrics.self
        guard let value else { return AtticControlSize.smallMinWidth }
        guard value.text.count > keepsPrefix + 1 else { return 0 }
        return m.labelPadding + m.iconSize + iconLabelGap + keptPrefixWidth + clearGap
    }

    private var iconLabelGap: CGFloat {
        compact && value != nil ? AtticPickerMetrics.stripCompactIconGap : AtticSmallControlMetrics.iconLabelGap
    }

    private var clearGap: CGFloat {
        compact ? AtticPickerMetrics.stripCompactClearGap : AtticPickerMetrics.stripClearGap
    }

    var body: some View {
        let m = AtticSmallControlMetrics.self
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tokens = design.tokens
        let fill: AtticRGBA = if isOpen {
            tokens.chipSelected
        } else if value != nil {
            hovered ? tokens.chipHover.over(tokens.recessed) : tokens.recessed
        } else {
            hovered ? tokens.chipHover : .clear
        }
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: iconLabelGap) {
                    AtticIcon(systemName: systemName, size: m.iconSize, weight: .regular, ink: isEnabled ? .glyph : .disabledIcon)
                    if let value {
                        // A long tag gives way first (the strip keeps to the
                        // bar's width); the full value is the tooltip.
                        AtticText(verbatim: value.text, style: value.style, ink: isEnabled ? value.ink : .disabledText, truncates: true)
                    } else if showsTitle {
                        AtticText(verbatim: title, style: .controlLabel, ink: isEnabled ? .heading : .disabledText)
                    }
                }
                .padding(.leading, m.labelPadding)
                .padding(.trailing, value == nil ? m.labelPadding : clearGap)
                .frame(minWidth: labelFloor, minHeight: height, maxHeight: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .background(shape.fill(fill.color))
        .contentShape(shape)
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: value != nil), value: value)
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
        guard tuning.popsNativePopovers, tuning.appear == .spring, !AtticMotionPreference.reducesMotion,
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
