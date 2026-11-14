import SwiftUI

/// A date group's header (the owner's panel design, 2026-10-27): 11 pt in
/// the design's header grey, the primary ink under the pointer. A click folds or
/// unfolds the group; the count shows only while it is folded; the chevron
/// shows at 60 % under the pointer or while folded, turned −90° when folded.
struct TasksGroupHeader: View {
    enum Items: Equatable {
        case tasks, notes
        func count(_ count: Int) -> String {
            switch self {
            case .tasks: count == 1 ? String(localized: "1 task") : String(localized: "\(count) tasks")
            case .notes: count == 1 ? String(localized: "1 note") : String(localized: "\(count) notes")
            }
        }
        var showHint: String { self == .notes ? String(localized: "Shows the group's notes") : String(localized: "Shows the group's tasks") }
        var hideHint: String { self == .notes ? String(localized: "Hides the group's notes") : String(localized: "Hides the group's tasks") }
    }
    let title: String
    let count: Int
    let folded: Bool
    var overdue = false
    /// A row dragged on Now would land in this day (Adaptive picks): the
    /// header takes the title's ink, as under the pointer.
    var isDropTarget = false
    var items: Items = .tasks
    let toggle: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        let lit = hovered || isDropTarget
        // The design's header grey, a step under the titles on every
        // surface (Glass draws `.label` in the title's ink); the title's
        // ink under the pointer.
        let rest = TasksPanelDesign.toneInk(.groupHeader, tokens: tokens)
        Button(action: toggle) {
            HStack(spacing: TasksDesignMetrics.groupHeaderGap) {
                AtticText(verbatim: title, style: .groupHeader, ink: lit ? .heading : .helper)
                    .colour(lit ? nil : rest)
                if folded {
                    AtticText(verbatim: "\(count)", style: .groupHeader, ink: .helper)
                        .colour(TasksPanelDesign.toneInk(.meta, tokens: tokens))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: TasksDesignMetrics.groupChevron, weight: .semibold))
                    .foregroundStyle(hovered ? tokens.color(.heading) : rest.color)
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .opacity(folded || hovered ? 0.6 : 0)
            }
            .frame(height: TasksDesignMetrics.groupHeaderLine)
            .padding(.top, TasksDesignMetrics.groupHeaderTop)
            .padding(.bottom, TasksDesignMetrics.groupHeaderBottom)
            .padding(.leading, TasksDesignMetrics.groupHeaderX)
            .padding(.trailing, TasksDesignMetrics.rowPaddingX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(design.reduceMotion ? AtticMotionScale.reducedChange : TasksDesignMetrics.curve(0.2), value: folded)
        .animation(design.reduceMotion ? AtticMotionScale.reducedChange : .easeOut(duration: 0.15), value: lit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(folded ? String(localized: "Folded, \(items.count(count))") : items.count(count))
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint(folded ? items.showHint : items.hideHint)
    }
}

/// The design's sizes, in points (the drawing is at 2×: px ÷ 2).
enum TasksDesignMetrics {
    /// The design's ease, `cubic-bezier(0.3, 0.7, 0.2, 1)`.
    static func curve(_ duration: Double) -> Animation {
        AtticPanelChromeMetrics.curve(duration)
    }

    /// The bottom bar's fold, as the footer's tabs folded for the add
    /// field (pd-combined): the design's ease at 260 ms; Reduce Motion a
    /// 150 ms fade.
    static func fold(reduceMotion: Bool) -> Animation {
        AtticPanelChromeMetrics.fold(reduceMotion: reduceMotion)
    }

    // Group header: 22 px text on a 28 px line, gap 8 px. Its padding was
    // 18 18 6 18 px; Accepted 2026-11-05 ("Header spacing": less crowding)
    // gives it 22 above and 8 below.
    static let groupHeaderTop: CGFloat = 11
    static let groupHeaderBottom: CGFloat = 4
    static let groupHeaderLine: CGFloat = 14
    static let groupHeaderGap: CGFloat = 4
    static let groupChevron: CGFloat = 6.5
    static let groupHeaderHeight: CGFloat = groupHeaderTop + groupHeaderLine + groupHeaderBottom

    // Row: padding 14 × 18 px (`TasksRowDesign` holds the row's sizes);
    // the ring's 28 px column, then 20 px to the title.
    static let rowPaddingX: CGFloat = 9
    static let ringToTitle: CGFloat = AtticTaskRowLayout.ringToTitle
    /// The title column in the page (title at 43 from the panel's edge):
    /// after the circle's column, the design's 10 pt gap. The rest of the
    /// app keeps `AtticLayout.textX` (8 pt after the circle, spacing B).
    static let textX: CGFloat = AtticTaskRowLayout.textX
    /// A group header's text starts on the rows' padding: the row fill's
    /// inset, then the row's 18 px.
    static let groupHeaderX: CGFloat = AtticLayout.rowHighlightInset + rowPaddingX
    /// Attachment tiles: 56 px, radius 12 px, 8 px apart.
    static let tile: CGFloat = 28
    static let tileRadius: CGFloat = AtticRadius.small
    static let tileGap: CGFloat = 4
    /// File tile 46 px wide.
    static let fileTileWidth: CGFloat = 23

    // Top row: controls 54 px (`AtticControlSize.headerControl`), 10 px
    // apart (Accepted 2026-11-05, "Header spacing"; was 6 px).
    /// The design's inner controls (`rInner`, 28 px): the date button, tag
    /// pills, Clear filters. Each clamps to half its side, as CSS does.
    static let innerRadius: CGFloat = AtticTaskRowLayout.innerRadius
    /// Every control's corner: `superellipse(1.4)` (`cornerSmoothing`).
    static var cornerExponent: CGFloat { AtticControlShape.designExponent }
    static let headerGap: CGFloat = AtticPanelChromeMetrics.headerGap

    // Bottom bar: gap 10 px; its controls are the top row's 27 pt capsules.
    static let footerGap: CGFloat = AtticPanelChromeMetrics.footerGap
    static let footerRadius: CGFloat = AtticRadius.header

    /// The list starts 6 under the header (Accepted 2026-11-05, "Header
    /// spacing"; was 2).
    static let listTopGap: CGFloat = 6
}

/// A row's files as tiles (the owner's panel design): images at their own
/// shape (28 tall, 14 to 60 wide), other files a grey tile with a page
/// glyph and the extension. Thumbnails load once per file and are cached
/// by the files store; nothing runs on hover or per frame.
struct TasksFileTiles: View {
    let files: [TaskImageReference]

    var body: some View {
        // Every file is a tile (no cap, Accepted 2026-11-01 "Task rows: no
        // paperclip count"): more than fit scroll sideways with a trackpad
        // swipe, clipped where the strip starts, the row's text column. No
        // scroller bar, and no bounce while they all fit.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TasksDesignMetrics.tileGap) {
                ForEach(files) { file in
                    Group {
                        if file.isImage {
                            TasksImageTile(reference: file)
                        } else {
                            TasksFileTile(name: file.filename)
                        }
                    }
                    // Tiles are the only file surface left on a task row
                    // (Accepted 2026-11-01 "Task rows: no paperclip count").
                    // Keep their individual drag and VoiceOver targets.
                    .onDrag { TaskAttachmentDragItem(reference: file, files: .shared).itemProvider() }
                    .atticRowControl()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(file.filename)
                    .accessibilityIdentifier("task-attachment-tile-\(file.id.uuidString)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
    }
}

private struct TasksFileTile: View {
    let name: String
    @Environment(\.atticDesign) private var design

    var body: some View {
        let ink = design.tokens.color(.icon)
        VStack(spacing: 1.5) {
            Image(systemName: "doc")
                .font(.system(size: 8, weight: .regular))
            Text(verbatim: TasksPanelDesign.tileLabel(name))
                .font(.system(size: 5.5, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(ink)
        .frame(width: TasksDesignMetrics.fileTileWidth, height: TasksDesignMetrics.tile)
        .background(Squircle(cornerRadius: TasksDesignMetrics.tileRadius, exponent: TasksDesignMetrics.cornerExponent)
            .fill(design.tokens.ink(.heading).withAlpha(0.06).color))
        .help(name)
    }
}

private struct TasksImageTile: View {
    let reference: TaskImageReference
    @State private var image: NSImage?

    var body: some View {
        let size = image?.size ?? CGSize(width: 1, height: 1)
        let ratio = size.height > 0 ? size.width / size.height : 1
        let width = min(60, max(14, TasksDesignMetrics.tile * ratio))
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: width, height: TasksDesignMetrics.tile)
        .clipShape(Squircle(cornerRadius: TasksDesignMetrics.tileRadius, exponent: TasksDesignMetrics.cornerExponent))
        .task(id: reference.digest) {
            if let cached = TaskThumbnailMemory.image(for: reference.digest) { image = cached; return }
            let data = try? await TaskImageFiles.shared.thumbnail(reference, pixels: 120)
            guard !Task.isCancelled, let loaded = data.flatMap(NSImage.init(data:)) else { return }
            TaskThumbnailMemory.remember(loaded, for: reference.digest)
            image = loaded
        }
        .help(reference.filename)
    }
}

/// Now · Backlog · Done, the Tasks page's own switch on the top row
/// (Accepted 2026-10-29/30, "Top row and bottom bar"; 2026-11-05, "Compact
/// tab switch"): the top row's 27 pt glass capsule, 3 pt inset, 21 pt cells
/// 1 pt apart. Each tab shows its icon; the current tab opens to its name
/// too, on the flat grey marker (one selection marker), in the primary ink
/// and the others grey. The capsule keeps its right edge beside ••• and
/// opens to the left on the marker's spring, in a slot of its widest size,
/// so the row itself never lays out again. ←/→ move between them; VoiceOver
/// and the tooltips read each by name.
struct TasksTopTabs: View {
    @Binding var selection: TasksTab

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovered: TasksTab?

    typealias M = TasksTopTabsMetrics

    var body: some View {
        let tokens = design.tokens
        let tabs = TasksTab.allCases
        let selected = tabs.firstIndex(of: selection) ?? 0
        let chipRadius = AtticShape.controlRadius(height: M.cell.height)
        HStack(spacing: M.gap) {
            ForEach(tabs) { tab in
                let on = tab == selection
                let ink = on || hovered == tab ? tokens.ink(.heading) : TasksPanelDesign.toneInk(.meta, tokens: tokens)
                Button { selection = tab } label: {
                    HStack(spacing: 0) {
                        AtticIcon(systemName: tab.systemName, size: M.iconSize, weight: .medium, ink: .heading, colour: ink)
                            .frame(width: M.cell.width, height: M.cell.height)
                        Text(verbatim: tab.title)
                            .font(.system(size: M.fontSize, weight: .medium))
                            .tracking(M.tracking)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(ink.color)
                            .opacity(on ? 1 : 0)
                    }
                    // The name always keeps its size; the cell opens over it.
                    .frame(width: M.cellWidth(tab, selection: selection), height: M.cell.height, alignment: .leading)
                    .clipped()
                    .contentShape(AtticControlShape.shape(cornerRadius: chipRadius, exponent: AtticShape.controlExponent))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hovered = tab } else if hovered == tab { hovered = nil }
                }
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tasks-page-\(tab.identifier)")
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        // One marker and one hover chip under the cells, travelling
        // between them (Accepted 2026-11-05, "Animated selection").
        .background(alignment: .topLeading) {
            let current = M.cellFrame(selected, selection: selection)
            ZStack(alignment: .topLeading) {
                AtticSelectionMarker(cornerRadius: chipRadius)
                    .frame(width: current.width, height: current.height)
                    .offset(x: current.minX, y: current.minY)
                AtticHoverChip(frame: hovered.flatMap(tabs.firstIndex(of:)).map { M.cellFrame($0, selection: selection) },
                               shown: hovered != selection, cornerRadius: chipRadius)
            }
        }
        .padding(M.inset)
        .frame(height: AtticControlSize.headerControl)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false, edgeLight: true))
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: AtticRadius.header)
        // Marker, cells, name and capsule on the one spring.
        .animation(AtticSelectionMarker.travel(reduceMotion: design.reduceMotion), value: selection)
        .focusable(capture == nil)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let next = AtticPageArrows.next(from: selected, key: press.key, modifiers: press.modifiers, count: tabs.count)
            else { return .ignored }
            if next != selected { selection = tabs[next] }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .accessibilityIdentifier("tasks-page-tabs")
        .frame(width: M.slotWidth, alignment: .trailing)
    }
}

/// The switch's sizes (3 pt inset and 21 pt chips as every top-row control).
enum TasksTopTabsMetrics {
    static let inset: CGFloat = AtticPageButtonMetrics.inset
    /// A tab showing only its icon.
    static let cell = CGSize(width: AtticPageButtonMetrics.segment, height: AtticPageButtonMetrics.segment)
    static let gap: CGFloat = 1
    static let iconSize: CGFloat = AtticPageButtonMetrics.iconSize
    /// 21 px, weight 500, −0.1 px.
    static let fontSize: CGFloat = 10.5
    static let tracking: CGFloat = -0.05
    /// After the current tab's name, to the marker's end.
    static let nameTrailing: CGFloat = 7

    /// The labels and font are fixed. Measure each once rather than laying
    /// out attributed text again whenever selection redraws the top row.
    private static let measuredNameWidths: [TasksTab: CGFloat] = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return Dictionary(uniqueKeysWithValues: TasksTab.allCases.map { tab in
            (tab, ceil(NSAttributedString(string: tab.title, attributes: [.font: font, .kern: tracking]).size().width))
        })
    }()

    static func nameWidth(_ tab: TasksTab) -> CGFloat { measuredNameWidths[tab] ?? 0 }

    static func cellWidth(_ tab: TasksTab, selection: TasksTab) -> CGFloat {
        tab == selection ? cell.width + nameWidth(tab) + nameTrailing : cell.width
    }

    /// A cell in the row of cells (the capsule's inset not counted).
    static func cellFrame(_ index: Int, selection: TasksTab) -> CGRect {
        let tabs = TasksTab.allCases
        let x = tabs.prefix(index).reduce(0) { $0 + cellWidth($1, selection: selection) + gap }
        return CGRect(x: x, y: 0, width: cellWidth(tabs[index], selection: selection), height: cell.height)
    }

    /// The capsule's width with `selection` current.
    static func width(selection: TasksTab) -> CGFloat {
        let tabs = TasksTab.allCases
        return inset * 2 + tabs.reduce(0) { $0 + cellWidth($1, selection: selection) } + CGFloat(tabs.count - 1) * gap
    }

    /// The room the switch keeps on the row: the capsule at its widest.
    static let slotWidth: CGFloat = TasksTab.allCases.map { width(selection: $0) }.max() ?? 0
}


/// The Tasks bottom bar (Accepted 2026-10-29/30, "Top row and bottom bar"):
/// the page switch, then the tag bar (All and the coloured #tags, filtering
/// the list, as on Notes), then "+". "+" is the add field at rest: a click
/// gives the field the keyboard, and while it has it or keeps a draft the
/// switch and the tag bar fold away and the field takes the row (the
/// design's turn, as the tabs folded before). Only this view watches the
/// draft, so a keystroke never redraws the page.
struct TasksBottomBar<AddBar: View>: View {
    @ObservedObject var text: TasksAddBarState
    let addFocused: Bool
    let tab: TasksTab
    let tags: [String]
    let tagPicks: TagPicks
    let onSelectTag: (String?) -> Void
    var onTagMatch: (TagPicks.Match) -> Void = { _ in }
    let onPlus: () -> Void
    /// Two or more tasks selected (T2, Accepted 2026-11-01): the selection
    /// bar takes the tag bar's place, as wide as its own content, and "+"
    /// stays. The tag bar comes back as it was when the selection ends.
    var selectionBar: AnyView? = nil
    @ViewBuilder var addBar: () -> AddBar

    @Environment(\.atticDesign) private var design
    /// In the panel the shell draws the switch, the tag bar and "+" once
    /// for every page (owner, 2026-10-31): here they are clear stand-ins.
    /// There "+" opens the shell's card (Phase B), so the bar never folds
    /// into the add field; hosted on its own it still does.
    @Environment(\.panelSharedChrome) private var sharedChrome
    /// The page's Tab order, lent to the shared "+" (`TasksTabStop.plus`).
    @Environment(\.atticFocusRequests) private var focusRequests
    /// The tag bar's open state when the page draws its own bar.
    @StateObject private var ownTagBar = PanelTagBarState()

    var body: some View {
        let hasDraft = !text.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shared = sharedChrome != nil
        let folded = !shared && TasksPanelDesign.footerFolded(addFocused: addFocused, hasDraft: hasDraft)
        let side = AtticControlSize.headerControl
        // T6 (Accepted 2026-11-01): Done keeps the tag bar too. A
        // multi-selection's bar takes its turn in its place (T2).
        let selecting = selectionBar != nil
        let tagsShown = !selecting
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .leading) {
                if shared {
                    Color.clear.frame(height: side)
                } else {
                    // The page switch is the Tall island (Accepted
                    // 2026-10-31): the tag bar sits on the left.
                    PanelTagBar(tags: tags, picks: tagPicks, idPrefix: "tasks-tag-bar", state: ownTagBar, shown: tagsShown && !folded,
                                focusRequests: focusRequests, onSelect: onSelectTag, onMatch: onTagMatch)
                        .opacity(tagsShown ? 1 : 0)
                        .allowsHitTesting(tagsShown)
                        .accessibilityHidden(!tagsShown)
                }
                // Drawn by the page even in the panel (its pickers and
                // menus are the page's), over the shared tag bar's place
                // while that fades out.
                if let selectionBar {
                    selectionBar
                        .panelRowGivesWayToCard()
                        .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion, edge: nil))
                }
            }
            .frame(height: side)
            .frame(maxWidth: folded ? 0 : .infinity, alignment: .leading)
            .opacity(folded ? 0 : 1)
            .padding(.trailing, folded ? 0 : TasksDesignMetrics.footerGap)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
            ZStack(alignment: .bottomTrailing) {
                // Always built, so "+" (or ⌘N) can give it the keyboard;
                // the panel's card replaces it there.
                if !shared {
                    addBar()
                        .opacity(folded ? 1 : 0)
                        .allowsHitTesting(folded)
                        .accessibilityHidden(!folded)
                }
                if !folded, shared {
                    Color.clear.frame(width: side, height: side)
                } else if !folded {
                    AtticRaisedButton(systemName: "plus", label: "New task", size: CGSize(width: side, height: side),
                                      help: String(localized: "New task"), emphasisedGlyph: true,
                                      flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header,
                                      action: onPlus)
                        .atticDesignCorners()
                        .accessibilityIdentifier("tasks-new-task")
                        .transition(.opacity)
                }
            }
            .frame(width: folded ? nil : side, alignment: .trailing)
            .frame(maxWidth: folded ? .infinity : side, alignment: .trailing)
        }
        .animation(Self.foldAnimation(reduceMotion: design.reduceMotion), value: folded)
        .panelBottomBar(.tasks,
                        look: PanelBottomBarLook(middle: .tags(tags: tags, picks: tagPicks, idPrefix: "tasks-tag-bar",
                                                               shown: tagsShown),
                                                 plus: PanelBottomBarLook.tasksPlus, folded: folded),
                        actions: PanelBottomBarActions(selectTag: onSelectTag, setTagMatch: onTagMatch, plus: onPlus,
                                                       focusRequests: focusRequests))
    }

    /// "+" expanding into the field and back: the bar's fold token.
    static func foldAnimation(reduceMotion: Bool) -> Animation {
        TasksDesignMetrics.fold(reduceMotion: reduceMotion)
    }
}

/// An empty list (the owner's panel design): a centred title and sentence
/// 75 below the list's top, with Clear filters while a search or a filter
/// hides tasks, and an action of the page's own under it.
struct TasksEmptyState: View {
    let empty: TasksPanelDesign.Empty
    var clear: (() -> Void)? = nil
    var action: (title: String, run: () -> Void)? = nil
    /// T3 with no results on this tab (Accepted 2026-11-01): the other
    /// tabs' matches on the title's line, "No results · 2 in Backlog", each a
    /// link (the count line's look, keys and VoiceOver).
    var elsewhere: [TasksElsewhereCount] = []
    var follow: (TasksTab) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if empty.titleParts.isEmpty {
                    Text(verbatim: empty.title)
                        .font(.system(size: 11, weight: .semibold))
                        .modifier(TasksInk(.heading))
                } else {
                    // The filter by name, its tags in their colours (13 Nov).
                    PanelTagPhraseText(parts: empty.titleParts, size: 11, weight: .semibold)
                }
                TasksElsewhereLinks(elsewhere: elsewhere, follow: follow)
            }
            .lineLimit(1)
            if !empty.body.isEmpty {
                Group {
                    if empty.bodyParts.isEmpty {
                        Text(verbatim: empty.body)
                            .font(.system(size: 10))
                            .modifier(TasksInk(.helper))
                    } else {
                        PanelTagPhraseText(parts: empty.bodyParts, size: 10, weight: .regular, ink: .helper)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
                .padding(.top, 3)
            }
            if empty.canClear, let clear {
                AtticRaisedButton(systemName: nil, title: "Clear Filters", height: 22,
                                  cornerRadius: TasksDesignMetrics.innerRadius, action: clear)
                    .padding(.top, 11)
                    .accessibilityIdentifier("tasks-clear-filters")
            } else if let action {
                AtticQuietAction(systemName: nil, title: action.title, trailingChevron: true, emphasised: true, action: action.run)
                    .padding(.top, 8)
                    .accessibilityIdentifier("tasks-choose-from-later")
            }
        }
        .padding(.top, 75)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks-empty-line")
    }
}

private struct TasksInk: ViewModifier {
    let ink: AtticInk
    @Environment(\.atticDesign) private var design
    init(_ ink: AtticInk) { self.ink = ink }
    func body(content: Content) -> some View { content.foregroundStyle(design.tokens.color(ink)) }
}

/// A date group (or a Done day) folding or unfolding: its body closes like
/// the design's `overflow: hidden` body with a height transition. The rows
/// stay in the list while it closes; each takes only its part above the
/// fold line, so the content below rises with the body's edge and nothing
/// draws under or over the leaving rows (fix round 2: fix 1 cut the rows
/// in their own place while the list had already moved the next header
/// up, and the Air saw them fade behind it). Folding, the model folds once
/// the body has closed; unfolding, the rows come in closed and open.
struct TasksFoldTurn: Equatable {
    let tab: TasksTab
    let key: String
    /// Where it is going: closed (the model folds once it is) or open.
    let closing: Bool
    /// The header's state: folded while closing, and in the moment an
    /// unfolding group's rows come in closed.
    var headerFolded: Bool
    /// The body's openness, 1 open, 0 closed; animated.
    var progress: CGFloat
    let generation: Int

    func matches(_ tab: TasksTab, _ key: String) -> Bool { self.tab == tab && self.key == key }
}

/// Where a row of a turning group sits in it: its top in the group's rows,
/// and the height of all of them.
struct TasksFoldPlace: Equatable {
    let top: CGFloat
    let total: CGFloat
}

@MainActor
enum TasksFold {
    /// A header was clicked. `folded` is the model's state of the group;
    /// `toggle` flips a group in the model. A turn still under way for
    /// another group ends where it was going first. Under Reduce Motion
    /// (no animation) the group flips at once.
    static func turn(_ key: String, on tab: TasksTab, folded: Bool, animation: Animation?, generation: Int,
                     state: Binding<TasksFoldTurn?>, toggle: @escaping @MainActor @Sendable (String) -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        if let old = state.wrappedValue, !old.matches(tab, key) {
            withTransaction(quiet) {
                if old.closing { toggle(old.key) }
                state.wrappedValue = nil
            }
        }
        let current = state.wrappedValue
        guard let animation else {
            withTransaction(quiet) {
                // A closing turn has not folded the model yet.
                if current?.closing == true { state.wrappedValue = nil } else { state.wrappedValue = nil; toggle(key) }
            }
            return
        }
        let closing = current.map { !$0.closing } ?? !folded
        if closing {
            withAnimation(animation, completionCriteria: .removed) {
                state.wrappedValue = TasksFoldTurn(tab: tab, key: key, closing: true, headerFolded: true, progress: 0,
                                                   generation: generation)
            } completion: {
                guard state.wrappedValue?.generation == generation else { return }
                withTransaction(quiet) {
                    toggle(key)
                    state.wrappedValue = nil
                }
            }
        } else if current == nil {
            // The rows come in closed, then open on the next turn of the
            // run loop (they must be drawn closed first).
            withTransaction(quiet) {
                toggle(key)
                state.wrappedValue = TasksFoldTurn(tab: tab, key: key, closing: false, headerFolded: true, progress: 0,
                                                   generation: generation)
            }
            DispatchQueue.main.async {
                guard state.wrappedValue?.generation == generation else { return }
                open(tab, key, animation, generation: generation, state: state)
            }
        } else {
            // It was closing: it turns back (the model never folded).
            open(tab, key, animation, generation: generation, state: state)
        }
    }

    private static func open(_ tab: TasksTab, _ key: String, _ animation: Animation, generation: Int,
                             state: Binding<TasksFoldTurn?>) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withAnimation(animation, completionCriteria: .removed) {
            state.wrappedValue = TasksFoldTurn(tab: tab, key: key, closing: false, headerFolded: false, progress: 1,
                                               generation: generation)
        } completion: {
            guard state.wrappedValue?.generation == generation else { return }
            withTransaction(quiet) { state.wrappedValue = nil }
        }
    }

    /// Each row's place in its group, from the rows' heights.
    static func places(_ rows: [TasksListRow], height: (TasksListRow) -> CGFloat) -> [UUID: TasksFoldPlace] {
        var tops: [(UUID, CGFloat)] = []
        var top: CGFloat = 0
        for row in rows {
            tops.append((row.id, top))
            top += height(row)
        }
        return Dictionary(tops.map { ($0.0, TasksFoldPlace(top: $0.1, total: top)) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A row of a group: while its group turns, it takes (and draws) only its
/// part above the fold line, and fades with the body. Every group row
/// wears it (open: the whole row, unclipped), so a row keeps its identity
/// when its group starts or ends a turn.
struct TasksFoldBody: ViewModifier, Animatable {
    var progress: CGFloat
    let place: TasksFoldPlace?
    /// DEBUG hang probe only: names the row in the probe's ring.
    let probeKey: String

    init(progress: CGFloat, place: TasksFoldPlace?, probeKey: String = "") {
        self.progress = progress
        self.place = place
        self.probeKey = probeKey
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// How much of the row is drawn at `progress` (1 open, 0 closed): the
    /// rows above it take the group's shrunken height first.
    static func visibleHeight(progress: CGFloat, place: TasksFoldPlace) -> CGFloat {
        max(0, place.total * progress - place.top)
    }

    func body(content: Content) -> some View {
        let visible: CGFloat? = place.flatMap { progress >= 1 ? nil : Self.visibleHeight(progress: progress, place: $0) }
        TasksFoldLayout(visible: visible, probeKey: probeKey) { content }
            .clipShape(TasksFoldClip(visible: visible ?? TasksFoldClip.open))
            .opacity(visible == nil ? 1 : Double(min(1, max(0, progress))))
    }
}

/// Lays its row out at the row's own size and reports at most `visible`
/// points of height (the list moves what follows by that).
struct TasksFoldLayout: Layout {
    var visible: CGFloat?
    /// DEBUG hang probe only: names the row in the probe's ring.
    var probeKey: String = ""

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let size = row.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        #if DEBUG
        TasksFoldLayoutProbe.shared.measure(size.height)
        AtticHangProbe.note("fold.size", key: probeKey,
                            value: "proposal=\(proposal) child=\(size) visible=\(String(describing: visible))",
                            detail: "result-height=\(visible.map { min(size.height, max(0, $0)) } ?? size.height)")
        #endif
        guard let visible else { return size }
        return CGSize(width: size.width, height: min(size.height, max(0, visible)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        #if DEBUG
        TasksFoldLayoutProbe.shared.place()
        #endif
        let size = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        #if DEBUG
        AtticHangProbe.note("fold.place", key: probeKey,
                            value: "bounds=\(bounds) proposal=\(proposal) child=\(size)")
        #endif
        row.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

#if DEBUG
/// Opt-in counter for a live lazy list. The lock also covers SwiftUI's
/// off-main Layout calls; disabled unless a hosted hang regression enables it.
final class TasksFoldLayoutProbe: @unchecked Sendable {
    static let shared = TasksFoldLayoutProbe()
    private let lock = NSLock()
    private var enabled = false
    private var measures = 0
    private var placements = 0
    private var heights: [Int: Int] = [:]

    func start() {
        lock.withLock {
            enabled = true
            measures = 0
            placements = 0
            heights = [:]
        }
    }

    func stop() { lock.withLock { enabled = false } }

    func measure(_ height: CGFloat) {
        lock.withLock {
            guard enabled else { return }
            measures += 1
            if height.isFinite { heights[Int((height * 256).rounded()), default: 0] += 1 }
        }
    }

    func place() {
        lock.withLock {
            if enabled { placements += 1 }
        }
    }

    func snapshot() -> (measures: Int, placements: Int, heights: [Int: Int]) {
        lock.withLock { (measures, placements, heights) }
    }
}
#endif

/// Everything above `visible` points under the row's top (sideways and
/// upwards unbounded, so a ring or shadow at the row's edge is kept).
struct TasksFoldClip: Shape {
    static let open: CGFloat = 100_000
    var visible: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 1_000, y: rect.minY - 1_000, width: rect.width + 2_000, height: 1_000 + visible))
    }
}

/// Find's quiet count line (owner item 17), and since T3 (Accepted
/// 2026-11-01) "· 2 in Backlog · 5 in Done": each part a link to that tab
/// that keeps the query, a tab with no matches left out. The switch is
/// folded away while you search, so this is its route.
struct TasksFindCountLine: View {
    let text: String
    /// The count's own element: it reads "1 of N" to accessibility, and
    /// the links are elements of their own beside it.
    let countID: String
    let elsewhere: [TasksElsewhereCount]
    let follow: (TasksTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            AtticText(verbatim: text, style: .rowMeta, ink: .helper)
                .accessibilityIdentifier(countID)
            TasksElsewhereLinks(elsewhere: elsewhere, follow: follow)
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }
}

/// "· 2 in Backlog · 5 in Done" (T3): each part a link to that tab; the
/// count line and the No results line draw the same parts.
struct TasksElsewhereLinks: View {
    let elsewhere: [TasksElsewhereCount]
    let follow: (TasksTab) -> Void

    var body: some View {
        ForEach(elsewhere, id: \.tab) { part in
            AtticText(verbatim: " · ", style: .rowMeta, ink: .helper)
            TasksFindCountLink(title: String(localized: "\(part.count) in \(part.tab.title)")) { follow(part.tab) }
                .accessibilityIdentifier("tasks-find-count-\(part.tab.identifier)")
        }
    }
}

/// "2 in Backlog": the heading ink, underlined (the drafts' link), a little
/// lighter under the pointer.
private struct TasksFindCountLink: View {
    let title: String
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(AtticTextStyle.rowMeta.font)
                .underline()
                .foregroundStyle(design.tokens.color(hovered ? .body : .heading))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(.isLink)
    }
}
