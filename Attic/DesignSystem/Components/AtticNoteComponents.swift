import AppKit
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

/// The tags under a note's title (UX plan § 2): 11.5 medium in each tag's
/// colour, 12 apart, wrapping to the column. Each tag is a button;
/// in the writing view a click edits the note's tags (owner decision 3).
struct AtticNoteTagLine: View {
    let tags: [String]
    let onSelect: (String) -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticWrapLayout(spacing: AtticNoteMetrics.tagSpacing, lineSpacing: AtticNoteMetrics.tagLineSpacing) {
            ForEach(tags, id: \.self) { tag in
                AtticNoteTagButton(name: tag) { onSelect(tag) }
                    // A new tag pops in with a small spring; a removed one fades.
                    .transition(design.reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading)),
                                      removal: .opacity))
            }
        }
        .animation(AtticMotionPreset.popover.springy(reduceMotion: design.reduceMotion), value: tags)
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
            // In the tag's colour (colour pass, owner 2026-10-10).
            AtticTagLabel(name: name, style: .tag, hovered: hover)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .atticTagColourMenu(name)
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
    var hasProposal = false
    let preview: String
    var checklist: (done: Int, total: Int)?
    var images = 0
    var files = 0
    /// VoiceOver's reading ("Pricing page, edited 09:40, not saved, 1 of 3 checked, 1 image").
    var spoken: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.time == rhs.time && lhs.needsAttention == rhs.needsAttention
            && lhs.hasProposal == rhs.hasProposal && lhs.preview == rhs.preview && lhs.checklist?.done == rhs.checklist?.done
            && lhs.checklist?.total == rhs.checklist?.total && lhs.images == rhs.images && lhs.files == rhs.files
    }
}

/// An All notes row: 48 pt (the two-line row), its highlight 44 and 8 in
/// from the list's edge; the text on the note column.
///
/// Its actions: a quiet ⋯ takes the time's place while the row is hovered,
/// highlighted (↑ ↓) or the ⋯ has keyboard focus, and opens the row's menu;
/// VoiceOver reads the same commands as the row's named actions. Both come
/// from the ONE command list the page builds for the row (`commands`), the
/// list the right-click menu and ⇧⌘I show.
struct AtticNoteRow: View {
    let model: AtticNoteRowModel
    var isSelected = false
    /// The list's keyboard selection (↑ ↓) is on this row.
    var isHighlighted = false
    /// The row's commands, read only when VoiceOver builds its actions.
    var commands: (() -> [AtticMenuCommand])?
    /// Where the row's ⋯ is, for the menu to open under.
    var anchors: AtticNoteRowAnchors?
    /// The ⋯ was pressed (nil: the row has no ⋯).
    var onShowActions: (() -> Void)?
    let onOpen: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @FocusState private var actionsFocused: Bool

    /// VoiceOver's named actions: every enabled command except Open (the
    /// row's own action) and submenus.
    static func spokenActions(_ commands: [AtticMenuCommand]) -> [AtticMenuCommand] {
        commands.filter { !$0.isDisabled && $0.children.isEmpty && $0.identifier != "notes-row-open" }
    }

    var body: some View {
        let tokens = design.tokens
        let hover = forced == .hover || hovered
        let fill: AtticRGBA? = isSelected || isHighlighted ? tokens.selected : (hover ? tokens.hover : nil)
        let showsActions = onShowActions != nil && (hover || isHighlighted || actionsFocused)
        ZStack(alignment: .topTrailing) {
            openButton(fill: fill, hidesTime: showsActions)
            if let onShowActions {
                actionsButton(action: onShowActions, shown: showsActions)
            }
        }
        .onHover { hovered = $0 }
    }

    private func actionsButton(action: @escaping () -> Void, shown: Bool) -> some View {
        let radius = AtticRadius.control(height: Self.actionsHeight)
        return Button(action: action) {
            AtticIcon(systemName: "ellipsis", size: AtticNoteMetrics.rowActionsGlyphSize, weight: .medium, ink: .icon)
                .frame(width: Self.actionsWidth, height: Self.actionsHeight)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .focused($actionsFocused)
        .atticOwnFocusRing(.rounded(radius: radius, height: Self.actionsHeight))
        .background {
            if let anchors { AtticNoteRowAnchor(id: model.id, anchors: anchors) }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .padding(.trailing, AtticNoteMetrics.rowTextX - 4)
        .padding(.top, AtticTaskRowMetrics.titleTop(twoLine: true)
            + (AtticTaskRowMetrics.titleLineHeight - Self.actionsHeight) / 2)
        .help(String(localized: "Note actions (⇧⌘I)"))
        .accessibilityLabel(String(localized: "Actions for \(model.title)"))
        .accessibilityIdentifier("notes-row-actions")
    }

    private static let actionsWidth: CGFloat = 26
    private static let actionsHeight: CGFloat = 20

    private func openButton(fill: AtticRGBA?, hidesTime: Bool) -> some View {
        let m = AtticNoteMetrics.self
        return Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                if let fill {
                    AtticHighlight(fill: fill)
                        .frame(height: AtticLayout.detailRowHighlightHeight)
                        .padding(.horizontal, AtticNoteMetrics.libraryHighlightInset)
                        .padding(.top, (AtticLayout.detailRowPitch - AtticLayout.detailRowHighlightHeight) / 2)
                }
                VStack(alignment: .leading, spacing: AtticTaskRowMetrics.titleToDetails) {
                    HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                        AtticText(verbatim: model.title, style: .noteRowTitle, ink: .heading, truncates: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: m.countGap + 1) {
                            if model.needsAttention {
                                AtticIcon(systemName: "exclamationmark.circle", size: AtticErrorLineMetrics.iconSize,
                                          weight: .medium, ink: .warningText)
                            } else if model.hasProposal {
                                AtticIcon(systemName: "sparkle", size: AtticErrorLineMetrics.iconSize,
                                          ink: .helper)
                            }
                            AtticText(verbatim: model.time, style: .noteRowMeta, ink: .helper)
                                .opacity(hidesTime ? 0 : 1)
                        }
                        .fixedSize()
                    }
                    .frame(height: AtticTaskRowMetrics.titleLineHeight)
                    HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                        AtticText(verbatim: model.preview, style: .noteRowMeta, ink: .helper, truncates: true)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if let commands {
                ForEach(Self.spokenActions(commands())) { command in
                    Button(command.title, action: command.action)
                }
            }
        }
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
        AtticText(verbatim: title, style: .noteRowMeta, ink: .helper)
            .frame(height: AtticTaskRowMetrics.titleLineHeight)
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticNoteMetrics.rowTextX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tag suggestions

/// One suggestion while a `#word` is typed in a note's title (p2-01 #3):
/// an existing tag with its count, or the typed word as a new tag.
struct AtticTagSuggestion: Equatable, Identifiable {
    let name: String
    let count: Int
    let isNew: Bool
    var id: String { (isNew ? "new:" : "") + name }

    /// Existing tags that start with the typed word first, then those that
    /// contain it (most used first), up to `limit`; then "New tag" when the
    /// typed word is not a tag yet. Tags the note already has are left out.
    static func make(typed: String, counts: [String: Int], excluding: Set<String>, limit: Int = 3) -> [AtticTagSuggestion] {
        guard !typed.isEmpty else { return [] }
        let candidates = counts.filter { !excluding.contains($0.key) }
        func ranked(_ keep: (String) -> Bool) -> [(String, Int)] {
            candidates.filter { keep($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        }
        let prefix = ranked { $0.hasPrefix(typed) }
        let inside = ranked { !$0.hasPrefix(typed) && $0.contains(typed) }
        var result = (prefix + inside).prefix(limit).map { AtticTagSuggestion(name: $0.0, count: $0.1, isNew: false) }
        if counts[typed] == nil, !excluding.contains(typed) {
            result.append(AtticTagSuggestion(name: typed, count: 0, isNew: true))
        }
        return result
    }
}

/// The suggestions under a title hashtag: the E1 card and its 32 pt rows with the keyboard's row highlighted. Space takes
/// the typed word; Return or Tab the highlighted row; Esc keeps the text.
struct AtticTagSuggestionList: View {
    let suggestions: [AtticTagSuggestion]
    let highlighted: Int
    let onPick: (Int) -> Void

    @Environment(\.atticTagColouring) private var colouring

    var body: some View {
        AtticDropdownCard() {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                AtticDropdownRow(title: suggestion.isNew ? String(localized: "New tag “#\(suggestion.name)”") : "#" + suggestion.name,
                                detail: suggestion.isNew ? nil : "\(suggestion.count)",
                                isHighlighted: index == highlighted,
                                titleInk: suggestion.isNew ? .body : colouring.hue(for: suggestion.name).ink,
                                position: index + 1, itemCount: suggestions.count) { onPick(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tag suggestions"))
    }
}

// MARK: - All notes' label line and its search

/// All notes' label line (owner feedback, 2026-09-28): "All notes" and, at
/// the line's end, a quiet magnifier. Searching turns the line into a
/// recessed field (the Tasks Done search's pattern, card B of v22) with a
/// springy take-over; Esc, or the "Esc" hint, gives the line back.
struct AtticNoteLibraryLine: View {
    let title: String
    let placeholder: String
    @Binding var query: String
    /// The search holds the line (focused, or a query is kept).
    let searchShown: Bool
    var fieldFocused: FocusState<Bool>.Binding
    let onBeginSearch: () -> Void
    let onEndSearch: () -> Void
    var onKeyPress: ((KeyPress) -> KeyPress.Result)?
    /// The tags after the title, as many as fit (the active one first and
    /// always shown). None: the title stands alone, as a heading.
    var tags: [String] = []
    /// The tag the list is filtered to (nil: every note).
    var activeTag: String?
    /// A tag (or the title, nil) was clicked.
    var onSelectTag: (String?) -> Void = { _ in }
    /// More tags…: whether its card is open, and the card.
    var moreTagsShown: Binding<Bool>?
    var moreTagsCard: (() -> AnyView)?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring
    @State private var moreHovered = false

    var body: some View {
        let height = AtticControlSize.smallHeight
        ZStack(alignment: .trailing) {
            if searchShown {
                field
                    .transition(design.reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .offset(x: 28)).combined(with: .scale(scale: 0.96, anchor: .trailing)),
                                      removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .trailing))))
            } else {
                HStack(spacing: 0) {
                    if tags.isEmpty {
                        AtticText(verbatim: title, style: .pageTabSelected, ink: .heading)
                            .padding(.leading, AtticLayout.pageTabsX)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("notes-library-label")
                    } else {
                        tagLine
                            .padding(.leading, AtticLayout.pageTabsX)
                    }
                    Spacer(minLength: 0)
                    AtticSmallButton(systemName: "magnifyingglass", label: "Search notes (⌘F)", quietIcon: true, action: onBeginSearch)
                        .accessibilityIdentifier("notes-library-search-button")
                        .padding(.trailing, max(0, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset
                            - (AtticControlSize.smallMinWidth - AtticSmallControlMetrics.iconSize) / 2))
                }
                .transition(.opacity)
            }
        }
        .frame(height: height)
        .animation(AtticMotionPreset.popover.springy(reduceMotion: design.reduceMotion), value: searchShown)
    }

    /// The longest tag name a tab spells out: the active tag is always shown,
    /// so a long one is shortened to leave room for More tags… and the
    /// magnifier in the narrowest panel (review S4-R3).
    static let tabTitleLimit = 16

    static func tabTitle(_ tag: String) -> String {
        tag.count > tabTitleLimit ? "#\(tag.prefix(tabTitleLimit - 1))…" : "#\(tag)"
    }

    /// The fewest tags the line shows: the active one is never dropped.
    private var minimumTags: Int { activeTag == nil ? 0 : 1 }

    /// "All notes", then as many tags as fit, then More tags…: the longest
    /// that fits is shown (the tags' order is the caller's).
    private var tagLine: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tags.count, through: minimumTags, by: -1)), id: \.self) { count in
                HStack(spacing: AtticPageTabsMetrics.spacing) {
                    tabs(Array(tags.prefix(count)))
                    moreTags
                }
                .fixedSize()
            }
        }
    }

    private func tabs(_ shown: [String]) -> some View {
        let items = [AtticPageTabs<String?>.Item(page: nil, title: title, accessibilityIdentifier: "notes-library-label")]
            + shown.map { AtticPageTabs<String?>.Item(page: $0, title: Self.tabTitle($0), accessibilityIdentifier: "notes-library-tag-\($0)",
                                                      ink: colouring.hue(for: $0).ink) }
        return AtticPageTabs(items: items, selection: Binding(get: { activeTag }, set: { onSelectTag($0) }),
                             groupLabel: String(localized: "Filter notes by tag"))
    }

    @ViewBuilder
    private var moreTags: some View {
        if let moreTagsShown, let moreTagsCard {
            Button { moreTagsShown.wrappedValue.toggle() } label: {
                AtticText(verbatim: String(localized: "More tags…"), style: .pageTab,
                          ink: moreHovered || moreTagsShown.wrappedValue ? .body : .helper)
                    .fixedSize()
                    .frame(height: AtticLayout.pageTabsHeight)
                    .contentShape(Rectangle().inset(by: -AtticPageTabsMetrics.hitOutset))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { moreHovered = $0 }
            .atticDropdown(isPresented: moreTagsShown, prefer: .below, label: String(localized: "More tags")) {
                moreTagsCard()
            }
            .help(String(localized: "Every tag, with a find field"))
            .accessibilityLabel(String(localized: "More tags"))
            .accessibilityIdentifier("notes-library-more-tags")
        }
    }

    private var field: some View {
        let tokens = design.tokens
        let height = AtticControlSize.smallHeight
        return HStack(spacing: 0) {
            AtticIcon(systemName: "magnifyingglass", size: AtticTabsSearchMetrics.iconSize,
                      weight: AtticIconWeight.outline, ink: .helper)
                .frame(width: AtticControlSize.statusCircle)
                .padding(.leading, AtticNoteMetrics.searchIconX - AtticNoteMetrics.libraryHighlightInset)
            TextField("", text: $query, prompt: Text(verbatim: placeholder).foregroundStyle(tokens.color(.helper)))
                .textFieldStyle(.plain)
                .font(AtticTextStyle.listBody.font)
                .foregroundStyle(tokens.color(.heading))
                .focused(fieldFocused)
                .onExitCommand(perform: onEndSearch)
                .onKeyPress(phases: .down) { press in onKeyPress?(press) ?? .ignored }
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier("notes-library-search")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, AtticNoteMetrics.searchTextX - AtticNoteMetrics.searchIconX - AtticControlSize.statusCircle)
            Button(action: onEndSearch) {
                AtticText(verbatim: String(localized: "Esc"), style: .shortcut, ink: .helper)
                    .padding(.horizontal, AtticNoteMetrics.searchHintPadding)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(String(localized: "End the search (Esc)"))
            .accessibilityLabel(String(localized: "End search"))
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: height), style: .continuous)
            .fill(tokens.recessed.color))
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused.wrappedValue = true }
        .padding(.horizontal, AtticNoteMetrics.libraryHighlightInset)
    }
}


// MARK: - Row anchors

/// Where each visible All notes row's ⋯ is, so a menu a key opens (⇧⌘I)
/// pops up under the highlighted row, as the ⋯ does when pressed. A row
/// that is not on screen has none (the caller falls back to the pointer).
/// Views are held weakly: a row that scrolled away drops out on its own.
@MainActor
final class AtticNoteRowAnchors {
    private struct Weak { weak var view: NSView? }
    private var views: [UUID: Weak] = [:]

    func view(for id: UUID) -> NSView? { views[id]?.view }
    func register(_ view: NSView, for id: UUID) { views[id] = Weak(view: view) }
}

/// A click-through view behind a row's ⋯ that registers itself.
struct AtticNoteRowAnchor: NSViewRepresentable {
    let id: UUID
    let anchors: AtticNoteRowAnchors

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchors.register(view, for: id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchors.register(view, for: id)
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
