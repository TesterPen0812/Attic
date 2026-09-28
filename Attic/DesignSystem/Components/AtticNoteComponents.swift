import SwiftUI

/// A date inside note text (Phase 2): the tag chip's recessed pill (18 tall,
/// radius 7.5, `tagFill`) with a small calendar glyph and the day in body
/// ink. The note editor renders it into an image for its text attachment,
/// so it draws exactly what the gallery shows.
struct AtticDateChip: View {
    let label: String

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let height = AtticControlSize.tagHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticDateChipMetrics.glyphGap) {
            AtticIcon(systemName: "calendar", size: AtticDateChipMetrics.glyphSize, weight: .medium, ink: .helper)
            AtticText(verbatim: label, style: .chipLabel, ink: .body)
        }
        .padding(.horizontal, AtticTagMetrics.horizontalPadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tokens.tagFill.color))
        .accessibilityHidden(true)
    }
}

enum AtticDateChipMetrics {
    static let glyphSize: CGFloat = 10
    static let glyphGap: CGFloat = 4
}

// MARK: - Writing view (Phase 2, slice 2)

/// The note's menu button: a quiet ⋯ at the end of the title's first line
/// (owner decision 5; UX plan § 3.11). A 28 pt target with the icon ink;
/// hover and press are fills, and while its menu is open it keeps the
/// pressed fill. It never hides while the title shows.
struct AtticNoteMenuButton: View {
    var isOpen = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let m = AtticNoteMetrics.self
        let radius = AtticRadius.control(height: m.menuButtonSize)
        let state = AtticStateResolver(forced: forced, isEnabled: true, isHovered: hovered, isPressed: isOpen, isFocused: isFocused).state
        let fill: AtticRGBA = switch state {
        case .pressed: design.tokens.chipSelected
        case .hover: design.tokens.chipHover
        default: .clear
        }
        Button(action: action) {
            AtticIcon(systemName: "ellipsis", size: m.menuGlyphSize, weight: .medium, ink: isOpen ? .glyph : .icon)
                .frame(width: m.menuButtonSize, height: m.menuButtonSize)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticFocusRing(state == .focused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .help(String(localized: "Note options (⇧⌘I)"))
        .accessibilityLabel(String(localized: "Note options"))
        .accessibilityHint(String(localized: "Opens the note’s menu"))
    }
}

/// The tags under a note's title (UX plan § 2): 11.5 medium in the
/// secondary grey, 12 apart, wrapping to the column. Each tag is a button;
/// in the writing view a click edits the note's tags (owner decision 3).
struct AtticNoteTagLine: View {
    let tags: [String]
    let onSelect: (String) -> Void

    var body: some View {
        AtticWrapLayout(spacing: AtticNoteMetrics.tagSpacing, lineSpacing: AtticNoteMetrics.tagLineSpacing) {
            ForEach(tags, id: \.self) { tag in
                AtticNoteTagButton(name: tag) { onSelect(tag) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
    }
}

private struct AtticNoteTagButton: View {
    let name: String
    let action: () -> Void

    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let hover = forced == .hover || hovered
        Button(action: action) {
            AtticText(verbatim: "#" + name, style: .tag, ink: hover ? .body : .helper)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(String(localized: "Edit tags"))
        .accessibilityLabel(String(localized: "Tag \(name)"))
        .accessibilityHint(String(localized: "Edits this note’s tags"))
    }
}

/// Views in lines, left to right, wrapping to the width given, with their
/// own gap between items and between lines (the tag line).
struct AtticWrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !line.indices.isEmpty, line.width + spacing + itemWidth > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? itemWidth : line.width + spacing + itemWidth
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// A title that scrolled away, back in the header between the pin and the
/// page button (UX plan § 3.11): a raised (Liquid Glass) control, 36 tall,
/// with the title in the heading style, truncated, and a small chevron. It
/// opens the note's menu. Its own backing keeps it readable over text
/// passing under the header.
struct AtticHeaderTitle: View {
    let title: String
    let action: () -> Void

    var body: some View {
        let height = AtticControlSize.headerControl
        Button(action: action) {
            HStack(spacing: AtticTitleMenuMetrics.gap) {
                AtticText(verbatim: title, style: .panelHeading, ink: .heading, truncates: true)
                AtticIcon(systemName: "chevron.down", size: AtticTitleMenuMetrics.chevronSize, weight: .semibold, ink: .chevron)
            }
            .padding(.horizontal, AtticNoteMetrics.headerTitlePadding)
            .frame(height: height)
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: AtticRadius.control(height: height)))
        .focusEffectDisabled()
        .help(String(localized: "Note options (⇧⌘I)"))
        .accessibilityLabel(title)
        .accessibilityHint(String(localized: "Opens the note’s menu"))
    }
}

// MARK: - All notes

/// What one All notes row shows (UX plan § 3.10): the title and edit time,
/// a status glyph beside the time (never instead of it), a one-line preview
/// and, at the right, only what is present (checklist progress, images,
/// files).
struct AtticNoteRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let time: String
    /// ⚠ not saved: the warning glyph beside the time.
    var needsAttention = false
    let preview: String
    var checklist: (done: Int, total: Int)?
    var images = 0
    var files = 0
    /// VoiceOver's reading ("Pricing page, edited 09:40, not saved, 1 of 3 checked, 1 image").
    var spoken: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.time == rhs.time && lhs.needsAttention == rhs.needsAttention
            && lhs.preview == rhs.preview && lhs.checklist?.done == rhs.checklist?.done
            && lhs.checklist?.total == rhs.checklist?.total && lhs.images == rhs.images && lhs.files == rhs.files
    }
}

/// An All notes row: 48 pt (the two-line row), its highlight 44 and 8 in
/// from the list's edge; the text on the note column.
struct AtticNoteRow: View {
    let model: AtticNoteRowModel
    var isSelected = false
    /// The list's keyboard selection (↑ ↓) is on this row.
    var isHighlighted = false
    let onOpen: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        let m = AtticNoteMetrics.self
        let hover = forced == .hover || hovered
        let fill: AtticRGBA? = isSelected || isHighlighted ? tokens.selected : (hover ? tokens.hover : nil)
        Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                if let fill {
                    AtticHighlight(fill: fill)
                        .frame(height: AtticLayout.detailRowHighlightHeight)
                        .padding(.horizontal, AtticLayout.rowHighlightInset)
                        .padding(.top, (AtticLayout.detailRowPitch - AtticLayout.detailRowHighlightHeight) / 2)
                }
                VStack(alignment: .leading, spacing: AtticTaskRowMetrics.titleToDetails) {
                    HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                        AtticText(verbatim: model.title, style: .rowTitle, ink: .heading, truncates: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: m.countGap + 1) {
                            if model.needsAttention {
                                AtticIcon(systemName: "exclamationmark.circle", size: AtticErrorLineMetrics.iconSize,
                                          weight: .medium, ink: .warningText)
                            }
                            AtticText(verbatim: model.time, style: .rowMeta, ink: .helper)
                        }
                        .fixedSize()
                    }
                    .frame(height: AtticTaskRowMetrics.titleLineHeight)
                    HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                        AtticText(verbatim: model.preview, style: .rowMeta, ink: .helper, truncates: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        counts.fixedSize()
                    }
                    .frame(height: AtticTaskRowMetrics.detailsLineHeight)
                }
                .padding(.leading, m.rowTextX)
                .padding(.trailing, m.rowTextX)
                .padding(.top, AtticTaskRowMetrics.titleTop(twoLine: true))
            }
            .frame(height: AtticLayout.detailRowPitch, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var counts: some View {
        let m = AtticNoteMetrics.self
        HStack(spacing: m.countsSpacing) {
            if let checklist = model.checklist {
                count("checkmark.square", "\(checklist.done)/\(checklist.total)")
            }
            if model.images > 0 { count("photo", "\(model.images)") }
            if model.files > 0 { count("paperclip", "\(model.files)") }
        }
    }

    private func count(_ systemName: String, _ text: String) -> some View {
        HStack(spacing: AtticNoteMetrics.countGap) {
            AtticIcon(systemName: systemName, size: AtticNoteMetrics.countIconSize, weight: .regular, ink: .helper)
            AtticText(verbatim: text, style: .count, ink: .helper)
        }
    }
}

/// A group's heading in All notes (Pinned, Today, This week, Earlier): one
/// row's pitch, its text on the rows' title line, like the Done log's days.
struct AtticNoteGroupHeading: View {
    let title: String

    var body: some View {
        AtticText(verbatim: title, style: .rowMeta, ink: .helper)
            .frame(height: AtticTaskRowMetrics.titleLineHeight)
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticNoteMetrics.rowTextX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tag editor

/// The note's tag editor (⋯ → Tags…, or a click on a tag): "Find or add a
/// tag", then every tag with its count, ticked when the note has it. A
/// click adds or removes; typing filters; Return adds what was typed (a new
/// tag when none matches). Follows Phase 1's tag list (to be unified with
/// `AtticTagPicker` when Phase 1's final round is merged).
struct AtticNoteTagList: View {
    struct Tag: Identifiable, Equatable {
        let name: String
        let count: Int
        let isOn: Bool
        var id: String { name }
    }

    @Binding var query: String
    let tags: [Tag]
    /// The typed tag when it is not an existing one ("New tag “#…”").
    var create: String?
    let onToggle: (String) -> Void
    let onCreate: (String) -> Void
    var fieldFocused: FocusState<Bool>.Binding

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $query, prompt: Text(String(localized: "Find or add a tag")))
                .textFieldStyle(.plain)
                .font(AtticTextStyle.menuRow.font)
                .focused(fieldFocused)
                .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                .frame(height: AtticControlSize.smallHeight)
                .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: AtticControlSize.smallHeight), style: .continuous)
                    .fill(design.tokens.recessed.color))
                .padding(.bottom, AtticPopoverMetrics.groupGap)
                .onSubmit {
                    if let create { onCreate(create) } else if let first = tags.first { onToggle(first.name) }
                }
                .accessibilityLabel(String(localized: "Find or add a tag"))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tags) { tag in
                        AtticNoteTagChoice(title: "#" + tag.name, detail: "\(tag.count)", isOn: tag.isOn) { onToggle(tag.name) }
                    }
                    if let create {
                        AtticNoteTagChoice(title: String(localized: "New tag “#\(create)”"), detail: nil, isOn: false,
                                           systemName: "plus") { onCreate(create) }
                    }
                    if tags.isEmpty, create == nil {
                        AtticText(verbatim: String(localized: "No tags yet"), style: .menuRow, ink: .helper)
                            .padding(.horizontal, AtticPopoverMetrics.rowPadding)
                            .frame(height: AtticControlSize.smallHeight)
                    }
                }
            }
            .frame(maxHeight: m.tagEditorMaxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.automatic)
        }
        .padding(AtticPopoverMetrics.padding)
        .frame(width: m.tagEditorWidth)
    }
}

private struct AtticNoteTagChoice: View {
    let title: String
    let detail: String?
    let isOn: Bool
    var systemName: String?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let m = AtticPopoverMetrics.self
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        Button(action: action) {
            HStack(spacing: m.rowGap) {
                AtticIcon(systemName: systemName ?? "checkmark", size: m.rowIconSize, weight: .medium, ink: .glyph)
                    .opacity(systemName != nil || isOn ? 1 : 0)
                    .frame(width: m.rowIconSlot)
                AtticText(verbatim: title, style: .menuRow, ink: .body, truncates: true)
                Spacer(minLength: m.trailingMinGap)
                if let detail {
                    AtticText(verbatim: detail, style: .shortcut, ink: .helper)
                }
            }
            .padding(.horizontal, m.rowPadding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill((hovered ? design.tokens.selected : .clear).color))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
