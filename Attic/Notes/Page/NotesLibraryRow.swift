import SwiftUI

/// The design's row sizes, in points (Task Panel v11's Notes rows, drawn
/// at 2×: px ÷ 2).
enum NotesLibraryRowMetrics {
    /// Padding 12 × 16 px; a row's radius (Shapes: 24 px, squircle); rows
    /// 4 px apart, no dividers.
    static let paddingY: CGFloat = 6
    static let paddingX: CGFloat = 8
    static let radius: CGFloat = AtticRadius.row
    static let rowGap: CGFloat = 2
    /// The thumbnail, then 18 px to the text.
    static let thumbnailToText: CGFloat = 9
    /// Title 24 px (weight 510) on a 31 px line; the meta line 19 px on 26,
    /// 2 px under it, its parts 8 px apart.
    static let titleLine: CGFloat = 15.5
    static let lineGap: CGFloat = 1
    static let metaLine: CGFloat = 13
    static let metaSize: CGFloat = 9.5
    static let metaGap: CGFloat = 4
    /// The "•••": 44 × 31 px, radius 12 px, 12 px after the title, its
    /// right edge 8 px into the row's padding.
    static let actionsWidth: CGFloat = 22
    static let actionsHeight: CGFloat = 15.5
    static let actionsRadius: CGFloat = 6
    static let actionsGap: CGFloat = 6
    static let actionsOutset: CGFloat = 4

    static var height: CGFloat {
        paddingY * 2 + max(NoteThumbnailMetrics.size.height, titleLine + lineGap + metaLine)
    }
}

/// An All notes row (the owner's panel design, Notes rows option 4a): the
/// page thumbnail, the title, then time · first #tag · snippet. No
/// checkbox, ring or note icon, no task status. The row is its own
/// highlight: selected and hovered fills from the tokens (see-through on
/// glass). Hover (or the keyboard's row, or a focused •••) shows "•••" at
/// the end of the title line.
struct NotesLibraryRow: View {
    let details: NotesLibraryModel.RowDetails
    let thumbnails: NoteThumbnailCache
    var isSelected = false
    /// The list's keyboard selection (↑ ↓) is on this row.
    var isHighlighted = false
    /// The row's commands, read only when VoiceOver builds its actions.
    let commands: () -> [AtticMenuCommand]
    let anchors: AtticNoteRowAnchors
    let onShowActions: () -> Void
    let onOpen: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.atticTagColouring) private var colouring
    @State private var hovered = false
    @State private var actionsHovered = false
    @FocusState private var actionsFocused: Bool

    private typealias M = NotesLibraryRowMetrics

    var body: some View {
        let tokens = design.tokens
        let hover = forced == .hover || hovered
        let fill: AtticRGBA? = isSelected || isHighlighted ? tokens.selected : (hover ? tokens.hover : nil)
        let showsActions = hover || isHighlighted || actionsFocused
        ZStack(alignment: .topTrailing) {
            openButton(fill: fill, reservesActions: showsActions)
            actionsButton(shown: showsActions)
        }
        .frame(height: M.height)
        .onHover { hovered = $0 }
    }

    private var row: AtticNoteRowModel { details.row }

    private func openButton(fill: AtticRGBA?, reservesActions: Bool) -> some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: M.thumbnailToText) {
                NoteThumbnailView(id: row.id, content: details.thumbnail, cache: thumbnails)
                VStack(alignment: .leading, spacing: M.lineGap) {
                    AtticText(verbatim: row.title, style: .noteRowTitle, ink: .heading, truncates: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: M.titleLine)
                        .padding(.trailing, reservesActions ? M.actionsGap + M.actionsWidth - M.actionsOutset : 0)
                    metaLine
                        .frame(height: M.metaLine)
                }
            }
            .padding(.vertical, M.paddingY)
            .padding(.horizontal, M.paddingX)
            .frame(maxWidth: .infinity, minHeight: M.height, maxHeight: M.height, alignment: .leading)
            .background {
                if let fill {
                    AtticHighlight(fill: fill, cornerRadius: M.radius, run: .single, joinOverlap: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            ForEach(AtticNoteRow.spokenActions(commands())) { command in
                Button(command.title, action: command.action)
            }
        }
    }

    /// time · #tag · snippet, in the design's greys (see-through on glass)
    /// and the tag's own colour; a not-saved or proposal mark before the
    /// time.
    private var metaLine: some View {
        let tokens = design.tokens
        let timeInk = TasksPanelDesign.toneInk(.date, tokens: tokens).color
        let metaInk = TasksPanelDesign.toneInk(.meta, tokens: tokens).color
        return HStack(spacing: M.metaGap) {
            if row.needsAttention {
                AtticIcon(systemName: "exclamationmark.circle", size: M.metaSize, weight: .medium, ink: .warningText)
            } else if row.hasProposal {
                AtticIcon(systemName: "sparkle", size: M.metaSize, ink: .helper)
            }
            Text(verbatim: row.time)
                .foregroundStyle(timeInk)
                .fixedSize()
            if let tag = details.tag {
                separator(metaInk)
                Text(verbatim: "#" + tag)
                    .foregroundStyle(tagInk(tag, tokens: tokens))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if !row.preview.isEmpty {
                separator(metaInk)
                Text(verbatim: row.preview)
                    .foregroundStyle(metaInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: M.metaSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func separator(_ ink: Color) -> some View {
        Text(verbatim: "·").foregroundStyle(ink.opacity(0.55)).fixedSize()
    }

    private func tagInk(_ tag: String, tokens: AtticColorTokens) -> Color {
        let text = TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: colouring.hue(for: tag)),
                                               dark: design.mode == .dark).text
        return TasksPanelDesign.vivid(text, tokens: tokens).color
    }

    private func actionsButton(shown: Bool) -> some View {
        Button(action: onShowActions) {
            AtticIcon(systemName: "ellipsis", size: AtticNoteMetrics.rowActionsGlyphSize, weight: .medium, ink: .icon)
                .frame(width: M.actionsWidth, height: M.actionsHeight)
                .background {
                    if actionsHovered {
                        AtticHighlight(fill: design.tokens.hover, cornerRadius: M.actionsRadius, run: .single, joinOverlap: 0)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .focused($actionsFocused)
        .atticOwnFocusRing(.rounded(radius: M.actionsRadius, height: M.actionsHeight))
        .background { AtticNoteRowAnchor(id: row.id, anchors: anchors) }
        .onHover { actionsHovered = $0 }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .padding(.trailing, M.paddingX - M.actionsOutset)
        .padding(.top, M.paddingY + (M.titleLine - M.actionsHeight) / 2
            + (M.height - 2 * M.paddingY - (M.titleLine + M.lineGap + M.metaLine)) / 2)
        .help(String(localized: "Note actions (⇧⌘I)"))
        .accessibilityLabel(String(localized: "Actions for \(row.title)"))
        .accessibilityIdentifier("notes-row-actions")
    }
}
