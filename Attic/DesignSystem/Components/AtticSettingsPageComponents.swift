import SwiftUI

// Phase 1 additions for the rebuilt Settings pages (logged in
// `Attic/DesignSystem/CHANGELOG.md`): the scrolling page body with its
// bottom blur-out, rows that carry an action, messages and footnotes around
// group cards, the Recently Deleted row and a search field. Each is built
// from the frozen tokens; none introduces a colour, radius or type style of
// its own.

extension View {
    /// Binds keyboard focus only when a binding is given.
    @ViewBuilder
    func atticFocused(_ binding: FocusState<Bool>.Binding?) -> some View {
        if let binding {
            focused(binding)
        } else {
            self
        }
    }

    /// Sets an accessibility identifier only when there is one.
    @ViewBuilder
    func atticIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

/// Row geometry inside a group card for rows that lead with an icon (the
/// Recently Deleted list, messages): the icon centred on the 14 pt text
/// inset's slot, the text column after it.
enum AtticSettingsRowMetrics {
    static let iconSize: CGFloat = 14
    static let iconSlot: CGFloat = 16
    static let iconGap: CGFloat = 10
    /// Where text starts in a row with an icon (14 + 16 + 10).
    static var iconTextInset: CGFloat { AtticLayout.groupedRowTextInset + iconSlot + iconGap }
    /// Trailing inset of a row's action button (the switch's inset).
    static let actionTrailing: CGFloat = AtticSettingsMetrics.switchTrailing
    /// Action buttons inside rows are small controls (28 tall, radius 12).
    static let actionHeight: CGFloat = AtticControlSize.smallHeight
    /// Vertical padding of a message line; it grows with wrapped text.
    static let messageVerticalPadding: CGFloat = 11
    /// A footnote under a group card.
    static let footnoteTop: CGFloat = 8
    /// The search field (a recessed control, 32 tall).
    static let searchHeight: CGFloat = 32
    static let searchIconSize: CGFloat = 12.5
    static let searchPadding: CGFloat = 10
}

// MARK: - Page body

/// A Settings page's scrolling body inside the content card, under the
/// fixed header: group cards inset 16, with the page blurring out over the
/// bottom 58 pt (spec § Settings: "the page blurs out at the bottom") and
/// easing in under the header, so no hard edge cuts the content. The edges
/// are masks on the scroll view (whatever the card colour behind), and the
/// last content scrolls clear of the bottom zone.
struct AtticSettingsScrollPage<Content: View>: View {
    var identifier: String?
    @ViewBuilder let content: Content

    @Environment(\.atticCapture) private var capture

    var body: some View {
        Group {
            if capture == nil {
                ScrollView {
                    column
                }
                .scrollIndicators(.automatic)
            } else {
                column.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .mask(AtticSettingsEdgeMask())
        .atticIdentifier(identifier)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.top, AtticSettingsPageMetrics.contentTop)
        .padding(.horizontal, AtticSpacing.settingsGroupInset)
        .padding(.bottom, AtticEdgeBlur.settingsBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AtticSettingsPageMetrics {
    /// Below the header: 52 pt from the back button's bottom (spec), less
    /// the 12 pt the header keeps under the button.
    static let contentTop: CGFloat = AtticSpacing.settingsBelowHeader - AtticSpacing.s12
    /// The short ease under the header, so scrolled content never meets a
    /// hard line.
    static let topFade: CGFloat = AtticSpacing.s12
}

/// The page's edge mask: fully visible in the middle; eased in over the
/// top 12 pt; faded along the veil's ramp (to 65 %) over the bottom 58 pt.
struct AtticSettingsEdgeMask: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: AtticSettingsPageMetrics.topFade)
            Color.black
            LinearGradient(
                stops: AtticEdgeBlur.veilStops.map { .init(color: .black.opacity(1 - $0.opacity), location: $0.location) },
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: AtticEdgeBlur.settingsBottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Rows with an action

/// A row that carries one action: a title (40 pt), or a label over a value
/// (57 pt), with a small raised button at the trailing end ("Open Login
/// Items", "Copy", "Retry").
struct AtticActionRow: View {
    let title: String
    var value: String?
    /// The value is user content (an endpoint): it may be selected.
    var valueIsSelectable = false
    var valueIdentifier: String?
    let actionTitle: String
    var actionSystemName: String?
    var actionIdentifier: String?
    var actionHelp: String?
    let action: () -> Void

    @State private var probeID = UUID()

    var body: some View {
        let m = AtticSettingsRowMetrics.self
        HStack(spacing: AtticSettingsMetrics.rowTrailingMinGap) {
            if let value {
                VStack(alignment: .leading, spacing: AtticSettingsMetrics.labelValueGap) {
                    AtticText(verbatim: title, style: .groupLabel, ink: .label)
                    valueText(value)
                }
            } else {
                AtticText(verbatim: title, style: .rowSingle, ink: .body)
            }
            Spacer(minLength: AtticSettingsMetrics.rowTrailingMinGap)
            AtticRaisedButton(systemName: actionSystemName, title: "\(actionTitle)", height: m.actionHeight, action: action)
                .help(actionHelp ?? actionTitle)
                .atticIdentifier(actionIdentifier)
                .fixedSize()
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, m.actionTrailing)
        .frame(height: value == nil ? AtticLayout.groupedRowSingle : AtticLayout.groupedRowTall)
        .accessibilityElement(children: .contain)
        .atticControlProbe(
            value == nil ? "Grouped row (single)" : "Grouped row", id: probeID,
            expectedSize: CGSize(width: 0, height: value == nil ? AtticLayout.groupedRowSingle : AtticLayout.groupedRowTall),
            radius: 0, expectedRadius: 0
        )
    }

    @ViewBuilder
    private func valueText(_ value: String) -> some View {
        let text = AtticText(verbatim: value, style: .groupValue, ink: .body, truncates: true)
            .atticIdentifier(valueIdentifier)
        if valueIsSelectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}

/// A single line inside a group card with no control: a state ("Listening
/// on this Mac only"), with an optional leading icon.
struct AtticStatusRow: View {
    let title: String
    var systemName: String?
    var ink: AtticInk = .body

    var body: some View {
        let m = AtticSettingsRowMetrics.self
        HStack(spacing: m.iconGap) {
            if let systemName {
                AtticIcon(systemName: systemName, size: m.iconSize, weight: .regular, ink: ink == .body ? .icon : ink)
                    .frame(width: m.iconSlot)
            }
            AtticText(verbatim: title, style: .rowSingle, ink: ink)
            Spacer(minLength: 0)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, m.actionTrailing)
        .frame(height: AtticLayout.groupedRowSingle)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Messages and footnotes

/// A message inside a group card: information, a warning or an error, in
/// helper text that may wrap (to three lines), with an optional action. A
/// problem is never hidden (spec § Minimalism).
struct AtticGroupMessage: View {
    enum Tone: Sendable { case information, warning, error }

    let text: String
    var tone: Tone = .information
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        let m = AtticSettingsRowMetrics.self
        HStack(alignment: .firstTextBaseline, spacing: m.iconGap) {
            AtticIcon(systemName: symbol, size: m.iconSize - 1, weight: .regular, ink: ink)
                .frame(width: m.iconSlot)
            AtticText(verbatim: text, style: .settingsHelper, ink: ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                AtticRaisedButton(systemName: nil, title: "\(actionTitle)", height: m.actionHeight, action: action)
                    .fixedSize()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, m.actionTrailing)
        .padding(.vertical, m.messageVerticalPadding)
        .frame(minHeight: AtticLayout.groupedRowSingle)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch tone {
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    private var ink: AtticInk {
        switch tone {
        case .information: .helper
        case .warning: .warningText
        case .error: .dueText
        }
    }
}

/// Helper text under a group card, on the rows' text column; it may wrap
/// (to three lines).
struct AtticGroupFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        AtticText(verbatim: text, style: .settingsHelper, ink: .helper)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, AtticLayout.groupedRowTextInset)
            .padding(.trailing, AtticLayout.groupedRowTextInset)
            .padding(.top, AtticSettingsRowMetrics.footnoteTop)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recently Deleted

/// One item in Recently Deleted: what it is (icon), its title over when it
/// was deleted (and what comes back with it), and Restore.
struct AtticDeletedItemRow: View {
    let systemName: String
    let kind: String
    let title: String
    let detail: String
    var restoreIdentifier: String?
    let onRestore: () -> Void

    @State private var probeID = UUID()

    var body: some View {
        let m = AtticSettingsRowMetrics.self
        HStack(spacing: m.iconGap) {
            AtticIcon(systemName: systemName, size: m.iconSize, weight: AtticIconWeight.outline, ink: .icon)
                .frame(width: m.iconSlot)
            VStack(alignment: .leading, spacing: AtticSettingsMetrics.labelValueGap) {
                AtticText(verbatim: title, style: .groupValue, ink: .body, truncates: true)
                AtticText(verbatim: detail, style: .groupLabel, ink: .helper, truncates: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind): \(title)")
            .accessibilityValue(detail)
            Spacer(minLength: AtticSettingsMetrics.rowTrailingMinGap)
            AtticRaisedButton(systemName: nil, title: "Restore", height: m.actionHeight, action: onRestore)
                .fixedSize()
                .help(String(localized: "Put it back where it was"))
                .accessibilityLabel(String(localized: "Restore \(title)"))
                .atticIdentifier(restoreIdentifier)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, m.actionTrailing)
        .frame(height: AtticLayout.groupedRowTall)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Restore")) { onRestore() }
        .atticControlProbe(
            "Grouped row", id: probeID,
            expectedSize: CGSize(width: 0, height: AtticLayout.groupedRowTall),
            radius: 0, expectedRadius: 0
        )
    }
}

/// A search field for a Settings page: a recessed, flat field (things
/// inside content are recessed) at the control height and corner rule,
/// with a clear button once there is text. Esc clears it.
struct AtticSearchField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String?
    /// The page's view of the field's keyboard focus (so ⌘Z can undo
    /// typing while it edits).
    var focus: FocusState<Bool>.Binding?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @State private var probeID = UUID()

    var body: some View {
        let m = AtticSettingsRowMetrics.self
        let tokens = design.tokens
        let radius = AtticRadius.control(height: m.searchHeight)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        HStack(spacing: AtticSpacing.s8) {
            AtticIcon(systemName: "magnifyingglass", size: m.searchIconSize, weight: .regular, ink: .icon)
            if capture == nil {
                TextField(text: $text, prompt: Text(placeholder).foregroundStyle(tokens.color(.placeholder))) {
                    Text(placeholder)
                }
                .textFieldStyle(.plain)
                .font(AtticTextStyle.rowSingle.font)
                .foregroundStyle(tokens.color(.body))
                .onExitCommand { text = "" }
                .atticFocused(focus)
                .atticIdentifier(identifier)
            } else {
                AtticText(verbatim: text.isEmpty ? placeholder : text, style: .rowSingle, ink: text.isEmpty ? .placeholder : .body)
                Spacer(minLength: 0)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    AtticIcon(systemName: "xmark.circle.fill", size: m.searchIconSize, weight: .regular, ink: .icon)
                        .frame(width: AtticControlSize.minimumHitTarget - 8, height: AtticControlSize.minimumHitTarget - 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear search"))
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, m.searchPadding)
        .frame(height: m.searchHeight)
        .background(shape.fill(tokens.groupCard.color))
        .overlay {
            if let border = tokens.groupCardBorder { shape.strokeBorder(border.color, lineWidth: AtticHairline.contrastBorder) }
        }
        .atticControlProbe("Search field", id: probeID, expectedSize: nil, radius: radius, expectedRadius: AtticRadius.control(height: m.searchHeight))
    }
}

/// The empty state inside a group card: one quiet italic line where the
/// first row would be (spec § Every state is designed).
struct AtticGroupEmptyRow: View {
    let text: String

    var body: some View {
        AtticText(verbatim: text, style: .settingsHint, ink: .helper)
            .padding(.horizontal, AtticLayout.groupedRowTextInset)
            .frame(maxWidth: .infinity, minHeight: AtticLayout.groupedRowSingle, alignment: .leading)
    }
}
