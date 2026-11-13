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
        .background(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent).fill(tokens.tagFill.color))
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
    @State private var menuAnchor = AtticMenuAnchor.Holder()

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
                .background(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent).fill(fill.color))
                .contentShape(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .atticFocusRing(state == .focused, cornerRadius: radius)
        .background(AtticMenuAnchor(holder: menuAnchor).accessibilityHidden(true))
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
                    // A new tag grows in (M/S, the overlays' 0.96); a removed
                    // one fades (F/E). Reduced: the F/E fade.
                    .transition(design.reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .scale(scale: AtticMotionScale.overlayScale, anchor: .leading)),
                                      removal: .opacity.animation(AtticMotionScale.exit)))
            }
        }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion), value: tags)
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
    @State private var menuAnchor = AtticMenuAnchor.Holder()

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
        .background(AtticMenuAnchor(holder: menuAnchor).accessibilityHidden(true))
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
    /// An item in Tasks: its task's circle before the title (`p3-22` row
    /// 3; no "Task note" wording since C2). Nil: an ordinary note.
    var taskState: AtticTaskState? = nil
    /// A search result's visible occurrence, marked in either row layout.
    var searchMatch: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.time == rhs.time && lhs.needsAttention == rhs.needsAttention
            && lhs.hasProposal == rhs.hasProposal && lhs.preview == rhs.preview && lhs.checklist?.done == rhs.checklist?.done
            && lhs.checklist?.total == rhs.checklist?.total && lhs.images == rhs.images && lhs.files == rhs.files
            && lhs.taskState == rhs.taskState && lhs.searchMatch == rhs.searchMatch
    }
}

enum NoteSearchMark {
    static func text(_ value: String, matching match: String?) -> Text {
        guard let match, !match.isEmpty,
              let range = value.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(verbatim: value)
        }
        return Text(verbatim: String(value[..<range.lowerBound]))
            + Text(verbatim: String(value[range])).bold().underline()
            + Text(verbatim: String(value[range.upperBound...]))
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
        let highlight = tokens.rowHighlight(selected: isSelected || isHighlighted, hovered: hover)
        let showsActions = onShowActions != nil && (hover || isHighlighted || actionsFocused)
        ZStack(alignment: .topTrailing) {
            openButton(highlight: highlight, hidesTime: showsActions)
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
                .contentShape(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .focused($actionsFocused)
        .atticOwnFocusRing(.rounded(radius: radius, height: Self.actionsHeight))
        .background {
            if let anchors { AtticNoteRowAnchor(id: model.id, anchors: anchors, isMenuTrigger: shown) }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .padding(.trailing, AtticNoteMetrics.rowTextX - 4)
        .padding(.top, AtticTaskRowMetrics.centredBlockTop(twoLine: true)
            + (AtticTaskRowMetrics.titleLineHeight - Self.actionsHeight) / 2)
        .help(String(localized: "Note actions (⇧⌘I)"))
        .accessibilityLabel(String(localized: "Actions for \(model.title)"))
        .accessibilityIdentifier("notes-row-actions")
    }

    /// The task circle before a task note's title (the header's 12 pt).
    static let taskCircleSize: CGFloat = 12
    private static let actionsWidth: CGFloat = 26
    private static let actionsHeight: CGFloat = 20

    private func openButton(highlight: AtticRowHighlightStyle?, hidesTime: Bool) -> some View {
        let m = AtticNoteMetrics.self
        return Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                if let highlight {
                    AtticRowHighlight(style: highlight)
                        .frame(height: AtticLayout.detailRowHighlightHeight)
                        .padding(.horizontal, AtticNoteMetrics.libraryHighlightInset)
                        .padding(.top, (AtticLayout.detailRowPitch - AtticLayout.detailRowHighlightHeight) / 2)
                }
                VStack(alignment: .leading, spacing: AtticTaskRowMetrics.titleToDetails) {
                    HStack(spacing: AtticTaskRowMetrics.trailingMinGap) {
                        HStack(spacing: 6) {
                            if let state = model.taskState {
                                AtticStatusCircle(state: state)
                                    .scaleEffect(Self.taskCircleSize / AtticControlSize.statusCircle)
                                    .frame(width: Self.taskCircleSize, height: Self.taskCircleSize)
                                    .accessibilityHidden(true)
                            }
                            AtticText(verbatim: model.title, style: .noteRowTitle, ink: .heading, truncates: true)
                        }
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
                .padding(.top, AtticTaskRowMetrics.centredBlockTop(twoLine: true))
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
    @Environment(\.atticDesign) private var design

    /// The trailing count is secondary text, but Increase Contrast raises
    /// its floor to 4.5:1. The menu can sit over a black desktop, where the
    /// ordinary near-black helper misses that floor on the highlighted row.
    static func countColour(in design: AtticDesignContext) -> AtticRGBA? {
        guard design.increaseContrast else { return nil }
        return design.mode == .dark ? .white(1) : .black(1)
    }

    var body: some View {
        AtticDropdownCard() {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                AtticDropdownRow(title: suggestion.isNew ? AtticTagPicker.createTitle(suggestion.name) : "#" + suggestion.name,
                                dot: suggestion.isNew ? nil : colouring.hue(for: suggestion.name).ink,
                                checkGlyph: suggestion.isNew ? "plus" : nil,
                                detail: suggestion.isNew ? nil : "\(suggestion.count)",
                                detailInk: AtticDropdownSmallText.ink,
                                detailColour: Self.countColour(in: design),
                                isHighlighted: index == highlighted,
                                // O14-07: only the dot takes the tag's colour.
                                position: index + 1, itemCount: suggestions.count) { onPick(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tag suggestions"))
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
    var isMenuTrigger = true

    func makeNSView(context: Context) -> AtticMenuAnchor.AnchorView {
        let view = AtticMenuAnchor.AnchorView()
        view.isMenuTrigger = isMenuTrigger
        anchors.register(view, for: id)
        return view
    }

    func updateNSView(_ view: AtticMenuAnchor.AnchorView, context: Context) {
        view.isMenuTrigger = isMenuTrigger
        anchors.register(view, for: id)
    }
}
