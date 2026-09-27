import SwiftUI

// MARK: - Choice rows

/// A row's leading check column in a picker: ticked, part-ticked (a
/// multi-selection where only some tasks have it) or empty.
enum AtticCheckState: Equatable, Sendable {
    case off, on, mixed
}

/// One choice in a picker (the date picker's quick days, the tag list,
/// Priority, a suggestion): 28 tall, the pop-over row's shape, an optional
/// check column, a quiet trailing detail ("Thu 1 Oct"). The hovered row, or
/// the one the keyboard is on, takes the selection fill.
struct AtticChoiceRow: View {
    let title: String
    var systemName: String?
    var detail: String?
    /// nil: no check column.
    var check: AtticCheckState?
    var isHighlighted = false
    var titleInk: AtticInk = .body
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticPickerMetrics.self
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let fill: AtticRGBA = (hovered || isHighlighted) ? design.tokens.selected : .clear
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
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(check == .on || isHighlighted ? .isSelected : [])
        .accessibilityValue(check == .mixed ? String(localized: "some selected tasks") : "")
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
    /// The keyboard cursor's day (id), if the keyboard has moved.
    var cursor: String?
    /// "Remove date" (a row that has a date).
    var removeTitle: String?
    let onQuick: (String) -> Void
    let onDay: (String) -> Void
    let onMonth: (Int) -> Void
    var onRemove: () -> Void = {}

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticPickerMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            ForEach(quick) { item in
                AtticChoiceRow(title: item.title, detail: item.detail, check: showsChecks ? (item.isChecked ? .on : .off) : nil) {
                    onQuick(item.id)
                }
            }
            AtticPickerDivider()
            HStack {
                AtticText(verbatim: monthTitle, style: .controlLabel, ink: .heading)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                monthButton(-1, systemName: "chevron.left", label: String(localized: "Previous month"))
                monthButton(1, systemName: "chevron.right", label: String(localized: "Next month"))
            }
            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
            .frame(height: m.monthHeaderHeight)
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    AtticText(verbatim: symbol, style: .count, ink: .helper)
                        .frame(width: m.dayCell, height: m.weekdayHeight)
                }
            }
            .padding(.horizontal, m.gridInset)
            .accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.dayCell), spacing: 0), count: 7), spacing: 0) {
                ForEach(days) { day in
                    dayCell(day)
                }
            }
            .padding(.horizontal, m.gridInset)
            .padding(.bottom, m.gridBottom)
            if let removeTitle {
                AtticPickerDivider()
                AtticChoiceRow(title: removeTitle, check: showsChecks ? .off : nil, action: onRemove)
            }
        }
        .frame(width: m.dateWidth)
    }

    private func monthButton(_ step: Int, systemName: String, label: String) -> some View {
        Button { onMonth(step) } label: {
            AtticIcon(systemName: systemName, size: AtticPickerMetrics.chevronSize, weight: .semibold, ink: .icon)
                .frame(width: AtticPickerMetrics.monthButton, height: AtticPickerMetrics.monthButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Day) -> some View {
        let m = AtticPickerMetrics.self
        let tokens = design.tokens
        let ink: AtticInk = day.isSelected ? .onInverse : ((!day.inMonth || day.isPast) ? .helper : .body)
        return Button { onDay(day.id) } label: {
            ZStack {
                if day.isSelected {
                    Circle().fill(tokens.color(.inverseFill))
                } else if cursor == day.id {
                    Circle().fill(tokens.selected.color)
                }
                if day.isToday, !day.isSelected {
                    Circle().strokeBorder(tokens.color(.heading), lineWidth: m.todayRing)
                }
                AtticText(verbatim: day.number, style: day.isToday ? .rowMetaEmphasis : .rowMeta, ink: ink)
            }
            .frame(width: m.dayDisc, height: m.dayDisc)
            .frame(width: m.dayCell, height: m.dayRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
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
        var id: String { name }
    }

    @Binding var query: String
    let tags: [Tag]
    /// "New tag “…”" when the query is not an existing tag.
    var create: String?
    /// The keyboard highlight (index into `tags`, then the create row).
    var highlighted: Int?
    let onToggle: (String) -> Void
    let onCreate: (String) -> Void
    var fieldFocused: FocusState<Bool>.Binding

    var body: some View {
        let m = AtticPickerMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $query, prompt: Text(String(localized: "Find or add a tag")))
                .textFieldStyle(.plain)
                .font(AtticTextStyle.menuRow.font)
                .focused(fieldFocused)
                .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                .frame(height: AtticControlSize.smallHeight)
                .background(AtticPickerFieldBackground())
                .padding(.bottom, m.dividerGap)
                .accessibilityLabel(String(localized: "Find or add a tag"))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        AtticChoiceRow(title: "#" + tag.name, check: tag.state, isHighlighted: highlighted == index) {
                            onToggle(tag.name)
                        }
                    }
                    if let create {
                        AtticChoiceRow(title: String(localized: "New tag “#\(create)”"), systemName: "plus", check: .off,
                                       isHighlighted: highlighted == tags.count) {
                            onCreate(create)
                        }
                    }
                    if tags.isEmpty, create == nil {
                        AtticText(verbatim: String(localized: "No tags yet"), style: .menuRow, ink: .helper)
                            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                            .frame(height: AtticControlSize.smallHeight)
                    }
                }
            }
            .frame(maxHeight: m.tagListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: m.tagWidth)
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
/// Tag · Priority, the design system's small buttons, 28 tall, 8 above the
/// bar. The first icon sits on the circles' line. The host shows it for a
/// non-empty draft and keeps it while one of its pickers is open.
struct AtticComposerStrip<DateContent: View, PriorityContent: View>: View {
    @Binding var datePresented: Bool
    @Binding var priorityPresented: Bool
    let onTag: () -> Void
    @ViewBuilder let datePicker: () -> DateContent
    @ViewBuilder let priorityPicker: () -> PriorityContent

    var body: some View {
        HStack(spacing: AtticPickerMetrics.stripSpacing) {
            AtticSmallButton(systemName: "calendar", title: "Date", label: "Date") { datePresented = true }
                .popover(isPresented: $datePresented, arrowEdge: .top) {
                    datePicker().padding(AtticPopoverMetrics.padding)
                }
                .accessibilityIdentifier("composer-date")
            AtticSmallButton(systemName: "tag", title: "Tag", label: "Tag", action: onTag)
                .accessibilityIdentifier("composer-tag")
            AtticSmallButton(systemName: "flag", title: "Priority", label: "Priority") { priorityPresented = true }
                .popover(isPresented: $priorityPresented, arrowEdge: .top) {
                    priorityPicker().padding(AtticPopoverMetrics.padding)
                }
                .accessibilityIdentifier("composer-priority")
        }
        .frame(height: AtticControlSize.smallHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Date, tag and priority"))
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
    let onChoose: (Int) -> Void

    var body: some View {
        AtticPopover(width: AtticPickerMetrics.suggestionWidth) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AtticChoiceRow(title: item.title, systemName: item.systemName, detail: item.detail,
                               isHighlighted: index == highlighted) { onChoose(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Suggestions"))
    }
}
