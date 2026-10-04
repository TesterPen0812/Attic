import SwiftUI

// MARK: - Format toggles

/// One command in Notes' format controls (the selection bar and Aa): a flat
/// 28 pt control whose fill says its state. Off is clear; on takes the
/// selected chip's fill and the primary glyph; mixed (a selection that is
/// partly bold) takes half of it. Hover and press are fills, disabled is the
/// ghost ink, and the 2 pt ring shows only for the keyboard.
enum AtticFormatValue: Equatable {
    case off, on, mixed

    var spoken: String { Self.spokenValue(self) }

    static func spokenValue(_ value: AtticFormatValue) -> String {
        switch value {
        case .off: String(localized: "off")
        case .on: String(localized: "on")
        case .mixed: String(localized: "mixed")
        }
    }
}

struct AtticFormatToggle<Face: View>: View {
    typealias Value = AtticFormatValue

    let value: Value
    let label: String
    /// The tooltip ("Bold ⌘B").
    var help: String?
    var width: CGFloat = AtticNoteFormatMetrics.barToggleWidth
    /// The keyboard's position in a bar or pop-over (a ring, no focus move).
    var isKeyboardFocused = false
    /// Said by VoiceOver while the control is dimmed.
    var disabledReason: String?
    let action: () -> Void
    @ViewBuilder let face: (AtticInk) -> Face

    @Environment(\.atticDesign) private var design
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            AtticFormatToggleFace(value: value, hovered: hovered, radius: radius, face: face)
                .frame(width: width, height: height)
                .contentShape(shape)
        }
        .buttonStyle(AtticFormatPressStyle())
        .focusEffectDisabled()
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityValue(value.spoken)
        .accessibilityHint(isEnabled ? "" : (disabledReason ?? ""))
        .accessibilityAddTraits(value == .on ? [.isButton, .isSelected] : .isButton)
    }

}

extension AtticFormatToggle where Face == AtticIcon {
    /// A glyph toggle (B, I, a list).
    init(systemName: String, value: Value, label: String, help: String? = nil,
         width: CGFloat = AtticNoteFormatMetrics.barToggleWidth, isKeyboardFocused: Bool = false,
         disabledReason: String? = nil, action: @escaping () -> Void) {
        self.init(value: value, label: label, help: help, width: width, isKeyboardFocused: isKeyboardFocused,
                  disabledReason: disabledReason, action: action) { ink in
            AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, weight: .regular, ink: ink)
        }
    }
}

private struct AtticFormatPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.atticIsPressed, configuration.isPressed)
    }
}

private struct AtticFormatToggleFace<Face: View>: View {
    let value: AtticFormatValue
    let hovered: Bool
    let radius: CGFloat
    let face: (AtticInk) -> Face

    @Environment(\.atticDesign) private var design
    @Environment(\.atticIsPressed) private var isPressed
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let tokens = design.tokens
        let selected = tokens.chipSelected
        let fill: AtticRGBA = if !isEnabled {
            value == .off ? .clear : selected.withAlpha(selected.alpha / 2)
        } else if isPressed {
            tokens.pressed
        } else {
            switch value {
            case .on: selected
            case .mixed: selected.withAlpha(selected.alpha / 2)
            case .off: hovered ? tokens.chipHover : .clear
            }
        }
        let ink: AtticInk = !isEnabled ? .disabledIcon : (value == .off ? .icon : .glyph)
        face(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
    }
}

/// The highlight toggle's face: an "A" on a swatch of the note's highlight.
struct AtticHighlightGlyph: View {
    let ink: AtticInk
    let swatch: AtticRGBA

    var body: some View {
        AtticText(verbatim: "A", style: .controlLabel, ink: ink)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(swatch.color))
            .accessibilityHidden(true)
    }
}

// MARK: - The selection bar

/// The raised capsule the selection bar's controls sit in: the pop-over
/// surface (menus, pop-overs and the selection bar are raised over
/// content), a 4 pt inset, groups 4 apart and never lines.
struct AtticFormatBarSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var probeID = UUID()

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let radius = AtticRadius.control(height: m.barHeight)
        HStack(spacing: m.barGroupGap) { content }
            .padding(AtticControlSize.capsuleInset)
            .frame(height: m.barHeight)
            // Raised over the text like a pop-over (its fill, rims and
            // shadow): glass over running text would let the words show
            // through the controls.
            .background(AtticPopoverBackground(cornerRadius: radius))
            .atticControlProbe("Format bar", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

/// A group of toggles inside the bar or Aa (touching, 0 apart).
struct AtticFormatGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { HStack(spacing: 0) { content } }
}

/// The bar's style control: the current style's name and a small chevron
/// ("Body ⌄"); it opens the styles' native menu.
struct AtticFormatStyleFace: View {
    let title: String
    var isKeyboardFocused = false
    var isEnabled = true

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: 4) {
            AtticText(verbatim: title, style: .controlLabel, ink: isEnabled ? .heading : .disabledText)
            AtticIcon(systemName: "chevron.down", size: m.barStyleChevron, weight: .semibold,
                      ink: isEnabled ? .chevron : .disabledIcon)
        }
        .padding(.horizontal, m.barStylePadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((hovered && isEnabled ? design.tokens.chipHover : .clear).color))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
    }
}

// MARK: - Aa

/// One of Aa's style chips (Title, Heading, Subheading, Body, Mono), each
/// written in a hint of its own style; the current one sits on the chip.
struct AtticFormatStyleChip: View {
    enum Kind { case title, heading, subheading, body, mono }

    let kind: Kind
    let title: String
    let isOn: Bool
    var isKeyboardFocused = false
    var disabledReason: String?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let fill: AtticRGBA = isOn ? design.tokens.chipSelected : (hovered && isEnabled ? design.tokens.chipHover : .clear)
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(design.tokens.ink(isEnabled ? .heading : .disabledText).color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, AtticNoteFormatMetrics.styleChipPadding)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? String(localized: "current style") : "")
        .accessibilityHint(isEnabled ? "" : (disabledReason ?? ""))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var font: Font {
        switch kind {
        case .title: .system(size: 13, weight: .bold, design: .rounded)
        case .heading: .system(size: 13, weight: .semibold, design: .rounded)
        case .subheading: .system(size: 12, weight: .semibold, design: .rounded)
        case .body: .system(size: 13, weight: .regular, design: .rounded)
        case .mono: .system(size: 12, weight: .regular, design: .monospaced)
        }
    }
}

// MARK: - Date card

/// The date card's month (p2-03 #3): weekday initials, the days of the
/// month in a 7-column grid (other months' days quiet), today ringed and
/// the chosen day filled.
struct AtticDateCalendar: View {
    let month: Date
    let today: Date
    let selected: Date?
    let calendar: Calendar
    let onPick: (Date) -> Void
    let onMonth: (Int) -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let d = AtticDropdownMetrics.self
        let days = Self.grid(for: month, calendar: calendar)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                AtticText(verbatim: month.formatted(.dateTime.month(.wide).year()), style: .dropdownHeading, ink: .heading)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: d.detailGap)
                monthButton(-1, systemName: "chevron.left", label: String(localized: "Previous month"))
                monthButton(1, systemName: "chevron.right", label: String(localized: "Next month"))
            }
            .padding(.leading, d.rowPadding)
            .frame(height: d.monthHeaderHeight)
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdaySymbols(calendar).enumerated()), id: \.offset) { _, symbol in
                    AtticText(verbatim: symbol, style: .tag, ink: .helper)
                        .frame(width: d.monthCellWidth, height: d.weekdayHeight)
                }
            }
            .accessibilityHidden(true)
            ForEach(0..<(days.count / 7), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        dayCell(days[row * 7 + column])
                    }
                }
            }
        }
        .frame(width: d.monthCellWidth * 7)
    }

    private func monthButton(_ step: Int, systemName: String, label: String) -> some View {
        let d = AtticDropdownMetrics.self
        return Button { onMonth(step) } label: {
            AtticIcon(systemName: systemName, size: d.monthChevron, weight: .semibold, ink: .icon)
                .frame(width: d.monthButton, height: d.monthButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticOwnFocusRing(.circle(diameter: d.monthButton))
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayCell(_ day: Date) -> some View {
        let d = AtticDropdownMetrics.self
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = selected.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let tokens = design.tokens
        return Button { onPick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(AtticTextStyle.listBody.font.weight(isToday && !isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle((isSelected ? tokens.ink(.onInverse) : tokens.ink(inMonth ? .body : .helper)).color)
                .frame(width: d.monthDisc, height: d.monthDisc)
                .background(Circle().fill((isSelected ? tokens.ink(.inverseFill) : .clear).color))
                .overlay(Circle().strokeBorder((isToday && !isSelected ? tokens.ink(.heading) : .clear).color,
                                               lineWidth: AtticPickerMetrics.todayRing))
                .frame(width: d.monthCellWidth, height: d.monthCellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Six weeks from the week holding the month's first day.
    static func grid(for month: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}
