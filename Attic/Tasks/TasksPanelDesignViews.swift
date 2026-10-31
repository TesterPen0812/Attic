import SwiftUI

/// A date group's header (the owner's panel design, 2026-10-27): 11 pt in
/// the design's header grey, the primary ink under the pointer. A click folds or
/// unfolds the group; the count shows only while it is folded; the chevron
/// shows at 60 % under the pointer or while folded, turned −90° when folded.
struct TasksGroupHeader: View {
    let title: String
    let count: Int
    let folded: Bool
    var overdue = false
    let toggle: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        // The design's header grey, a step under the titles on every
        // surface (Glass draws `.label` in the title's ink); the title's
        // ink under the pointer.
        let rest = TasksPanelDesign.toneInk(.groupHeader, tokens: tokens)
        Button(action: toggle) {
            HStack(spacing: TasksDesignMetrics.groupHeaderGap) {
                AtticText(verbatim: title, style: .groupHeader, ink: hovered ? .heading : .helper)
                    .colour(hovered ? nil : rest)
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
        .animation(design.reduceMotion ? nil : TasksDesignMetrics.curve(0.2), value: folded)
        .animation(design.reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(folded ? String(localized: "Folded, \(count) tasks") : String(localized: "\(count) tasks"))
        .accessibilityAddTraits([.isHeader, .isButton])
        .accessibilityHint(folded ? String(localized: "Shows the group's tasks") : String(localized: "Hides the group's tasks"))
    }
}

/// The design's sizes, in points (the drawing is at 2×: px ÷ 2).
enum TasksDesignMetrics {
    /// The design's ease, `cubic-bezier(0.3, 0.7, 0.2, 1)`.
    static func curve(_ duration: Double) -> Animation {
        .timingCurve(0.3, 0.7, 0.2, 1, duration: duration)
    }

    /// The bottom bar's fold, as the footer's tabs folded for the add
    /// field (pd-combined): the design's ease at 260 ms; Reduce Motion a
    /// 150 ms fade.
    static func fold(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : curve(0.26)
    }

    // Group header: padding 18 18 6 18 px, 22 px text on a 28 px line, gap 8 px.
    static let groupHeaderTop: CGFloat = 9
    static let groupHeaderBottom: CGFloat = 3
    static let groupHeaderLine: CGFloat = 14
    static let groupHeaderGap: CGFloat = 4
    static let groupChevron: CGFloat = 6.5
    static let groupHeaderHeight: CGFloat = groupHeaderTop + groupHeaderLine + groupHeaderBottom

    // Row: padding 14 × 18 px (`TasksRowDesign` holds the row's sizes);
    // the ring's 28 px column, then 20 px to the title.
    static let rowPaddingX: CGFloat = 9
    static let ringToTitle: CGFloat = 10
    /// The title column in the page (title at 43 from the panel's edge):
    /// after the circle's column, the design's 10 pt gap. The rest of the
    /// app keeps `AtticLayout.textX` (8 pt after the circle, spacing B).
    static let textX: CGFloat = AtticLayout.circleX + AtticControlSize.statusCircle + ringToTitle
    /// A group header's text starts on the rows' padding: the row fill's
    /// inset, then the row's 18 px.
    static let groupHeaderX: CGFloat = AtticLayout.rowHighlightInset + rowPaddingX
    /// Attachment tiles: 56 px, radius 12 px, 8 px apart.
    static let tile: CGFloat = 28
    static let tileRadius: CGFloat = AtticRadius.small
    static let tileGap: CGFloat = 4
    /// File tile 46 px wide.
    static let fileTileWidth: CGFloat = 23

    // Top row: controls 54 px (`AtticControlSize.headerControl`), 6 px apart.
    /// The design's inner controls (`rInner`, 28 px): the date button, tag
    /// pills, Clear filters. Each clamps to half its side, as CSS does.
    static let innerRadius: CGFloat = 14
    /// Every control's corner: `superellipse(1.4)` (`cornerSmoothing`).
    static var cornerExponent: CGFloat { AtticControlShape.designExponent }
    static let headerGap: CGFloat = 3

    // Bottom bar: gap 10 px; its controls are the top row's 27 pt capsules.
    static let footerGap: CGFloat = 5
    static let footerRadius: CGFloat = AtticRadius.header

    /// The list starts 2 under the header (4 px).
    static let listTopGap: CGFloat = 2
}

/// A row's files as tiles (the owner's panel design): images at their own
/// shape (28 tall, 14 to 60 wide), other files a grey tile with a page
/// glyph and the extension. Thumbnails load once per file and are cached
/// by the files store; nothing runs on hover or per frame.
struct TasksFileTiles: View {
    let files: [TaskImageReference]

    var body: some View {
        HStack(spacing: TasksDesignMetrics.tileGap) {
            ForEach(files) { file in
                if file.isImage {
                    TasksImageTile(reference: file)
                } else {
                    TasksFileTile(name: file.filename)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(files.map(\.filename).joined(separator: ", "))
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
        .clipShape(RoundedRectangle(cornerRadius: TasksDesignMetrics.tileRadius, style: .continuous))
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

/// Now · Later · Done in words, the Tasks page's own switch on the top row
/// (Accepted 2026-10-29/30, "Top row and bottom bar"): the top row's 27 pt
/// glass capsule, 3 pt inset, 42 × 21 pt cells 1 pt apart, the current
/// tab on the flat grey marker (one selection marker), its word in the
/// primary ink and the others grey. ←/→ move between them; VoiceOver reads
/// each by name.
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
                Button { selection = tab } label: {
                    Text(verbatim: tab.title)
                        .font(.system(size: M.fontSize, weight: .medium))
                        .tracking(M.tracking)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on || hovered == tab ? tokens.ink(.heading).color
                                         : TasksPanelDesign.toneInk(.meta, tokens: tokens).color)
                        .frame(width: M.cell.width, height: M.cell.height)
                        // In the current cell, as the old thumb was: a
                        // change of tab crossfades it between the cells.
                        .background {
                            if on { AtticSelectionMarker(cornerRadius: chipRadius).transition(AtticSelectionMarker.transition) }
                        }
                        .contentShape(AtticControlShape.shape(cornerRadius: chipRadius, exponent: AtticShape.controlExponent))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hovered = tab } else if hovered == tab { hovered = nil }
                }
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tasks-page-\(tab.identifier)")
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(M.inset)
        .frame(height: AtticControlSize.headerControl)
        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false))
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: AtticRadius.header)
        .animation(AtticSelectionMarker.animation(reduceMotion: design.reduceMotion), value: selection)
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
    }
}

/// The words switch's sizes (the design's 84 px cells; 3 pt inset and 21 pt
/// chips as every top-row control).
enum TasksTopTabsMetrics {
    static let inset: CGFloat = AtticPageButtonMetrics.inset
    static let cell = CGSize(width: 42, height: AtticPageButtonMetrics.segment)
    static let gap: CGFloat = 1
    /// 21 px, weight 500, −0.1 px.
    static let fontSize: CGFloat = 10.5
    static let tracking: CGFloat = -0.05

    /// The whole switch's width.
    static var width: CGFloat {
        let count = CGFloat(TasksTab.allCases.count)
        return inset * 2 + count * cell.width + (count - 1) * gap
    }
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
    let tagSelection: String?
    let onSelectTag: (String?) -> Void
    let onPlus: () -> Void
    @ViewBuilder var addBar: () -> AddBar

    @Environment(\.atticDesign) private var design
    /// In the panel the shell draws the switch, the tag bar and "+" once
    /// for every page (owner, 2026-10-31): here they are clear stand-ins,
    /// and the add field folds out over them as before.
    @Environment(\.panelSharedChrome) private var sharedChrome

    var body: some View {
        let hasDraft = !text.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let folded = TasksPanelDesign.footerFolded(addFocused: addFocused, hasDraft: hasDraft)
        let side = AtticControlSize.headerControl
        // Done has no tag filter: its bar keeps its place, empty.
        let tagsShown = tab != .done
        let shared = sharedChrome != nil
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: TasksDesignMetrics.footerGap) {
                if shared {
                    Color.clear.frame(height: side)
                } else {
                    PanelPageSwitcher(page: .tasks)
                    PanelTagBar(tags: tags, selection: tagSelection, idPrefix: "tasks-tag-bar", onSelect: onSelectTag)
                        .opacity(tagsShown ? 1 : 0)
                        .allowsHitTesting(tagsShown)
                        .accessibilityHidden(!tagsShown)
                }
            }
            .frame(maxWidth: folded ? 0 : .infinity, alignment: .leading)
            .opacity(folded ? 0 : 1)
            .padding(.trailing, folded ? 0 : TasksDesignMetrics.footerGap)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
            ZStack(alignment: .bottomTrailing) {
                // Always built, so "+" (or ⌘N) can give it the keyboard.
                addBar()
                    .opacity(folded ? 1 : 0)
                    .allowsHitTesting(folded)
                    .accessibilityHidden(!folded)
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
                        look: PanelBottomBarLook(middle: .tags(tags: tags, selection: tagSelection, idPrefix: "tasks-tag-bar",
                                                               shown: tagsShown),
                                                 plus: PanelBottomBarLook.tasksPlus, folded: folded),
                        actions: PanelBottomBarActions(selectTag: onSelectTag, plus: onPlus))
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

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: empty.title)
                .font(.system(size: 11, weight: .semibold))
                .modifier(TasksInk(.heading))
            Text(verbatim: empty.body)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .modifier(TasksInk(.helper))
                .frame(maxWidth: 190)
                .padding(.top, 3)
            if empty.canClear, let clear {
                AtticRaisedButton(systemName: nil, title: "Clear filters", height: 22,
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
                     state: Binding<TasksFoldTurn?>, toggle: @escaping (String) -> Void) {
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

    init(progress: CGFloat, place: TasksFoldPlace?) {
        self.progress = progress
        self.place = place
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
        TasksFoldLayout(visible: visible) { content }
            .clipShape(TasksFoldClip(visible: visible ?? TasksFoldClip.open))
            .opacity(visible == nil ? 1 : Double(min(1, max(0, progress))))
    }
}

/// Lays its row out at the row's own size and reports at most `visible`
/// points of height (the list moves what follows by that).
struct TasksFoldLayout: Layout {
    var visible: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        let size = row.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard let visible else { return size }
        return CGSize(width: size.width, height: min(size.height, max(0, visible)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let row = subviews.first else { return }
        let size = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        row.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// Everything above `visible` points under the row's top (sideways and
/// upwards unbounded, so a ring or shadow at the row's edge is kept).
struct TasksFoldClip: Shape {
    static let open: CGFloat = 100_000
    var visible: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 1_000, y: rect.minY - 1_000, width: rect.width + 2_000, height: 1_000 + visible))
    }
}
