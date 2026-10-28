import SwiftUI

/// A date group's header (the owner's panel design, 2026-10-27): 11 pt in
/// the label grey, the primary ink under the pointer. A click folds or
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
        Button(action: toggle) {
            HStack(spacing: TasksDesignMetrics.groupHeaderGap) {
                AtticText(verbatim: title, style: .groupHeader, ink: hovered ? .heading : .label)
                if folded {
                    AtticText(verbatim: "\(count)", style: .groupHeader, ink: .helper)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: TasksDesignMetrics.groupChevron, weight: .semibold))
                    .foregroundStyle(tokens.color(hovered ? .heading : .label))
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .opacity(folded || hovered ? 0.6 : 0)
            }
            .frame(height: TasksDesignMetrics.groupHeaderLine)
            .padding(.top, TasksDesignMetrics.groupHeaderTop)
            .padding(.bottom, TasksDesignMetrics.groupHeaderBottom)
            .padding(.leading, AtticLayout.circleX)
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

    // Group header: padding 18 18 6 18 px, 22 px text on a 28 px line, gap 8 px.
    static let groupHeaderTop: CGFloat = 9
    static let groupHeaderBottom: CGFloat = 3
    static let groupHeaderLine: CGFloat = 14
    static let groupHeaderGap: CGFloat = 4
    static let groupChevron: CGFloat = 6.5
    static let groupHeaderHeight: CGFloat = groupHeaderTop + groupHeaderLine + groupHeaderBottom

    // Row: radius 24 px, padding 14 × 18 px; ring 28 px, gap 20 px.
    static let rowRadius: CGFloat = 12
    static let rowPaddingY: CGFloat = 7
    static let rowPaddingX: CGFloat = 9
    static let ring: CGFloat = 14
    static let ringToTitle: CGFloat = 10
    /// A title or meta line (30 px).
    static let lineHeight: CGFloat = 15
    /// Meta line's margin-top (3 px).
    static let metaTop: CGFloat = 1.5
    /// Priority mark after the title (gap 9 px).
    static let priorityGap: CGFloat = 4.5
    /// Tag pill: 30 px tall, 0 18 px padding (9 px each side ÷ 2).
    static let tagHeight: CGFloat = 15
    static let tagPaddingX: CGFloat = 4.5
    static let tagRadius: CGFloat = 7.5
    /// Meta items 14 px apart.
    static let metaGap: CGFloat = 7
    /// Date capsule: 32 px tall, 0 11 px padding.
    static let dateHeight: CGFloat = 16
    static let datePaddingX: CGFloat = 5.5
    /// Attachment tiles: 56 px, radius 12 px, 8 px apart, 8 px above.
    static let tile: CGFloat = 28
    static let tileRadius: CGFloat = 6
    static let tileGap: CGFloat = 4
    static let tilesTop: CGFloat = 4
    static let tilesBottom: CGFloat = 1
    /// File tile 46 px wide.
    static let fileTileWidth: CGFloat = 23

    /// One-line and meta-line row heights (7 + 15 + 7; 7 + 15 + 1.5 + 15 + 7).
    static let rowHeight: CGFloat = rowPaddingY * 2 + lineHeight
    static let metaRowHeight: CGFloat = rowPaddingY * 2 + lineHeight * 2 + metaTop

    // Header: controls 54 px, radius 30 px, 6 px apart.
    static let headerControl: CGFloat = 27
    static let headerRadius: CGFloat = 15
    /// The design's inner controls (`rInner`, 28 px): the filter button,
    /// chips, tab thumb, tag pills, the date button, Clear filters. Each
    /// clamps to half its side, as CSS does.
    static let innerRadius: CGFloat = 14
    /// Every control's corner: `superellipse(1.4)` (`cornerSmoothing`).
    static var cornerExponent: CGFloat { AtticControlShape.designExponent }
    static let headerGap: CGFloat = 3
    /// The page switch: 72 px shut, 150 px open; 42 px segments.
    static let switchShut: CGFloat = 36
    static let switchOpen: CGFloat = 75
    static let switchSegment: CGFloat = 21
    /// The search starts 5 after the pin (10 px); its filter button is
    /// 21 (42 px).
    static let searchFromPin: CGFloat = 5
    static let filterButton: CGFloat = 21

    // Footer: padding 6 31 31 31 px, gap 10 px; tab cells 53 px in a 4 px
    // padded container (radius 32 px); the add field 61 px tall.
    static let footerTop: CGFloat = 3
    static let footerGap: CGFloat = 5
    static let tabCell: CGFloat = 26.5
    static let tabsPadding: CGFloat = 2
    static let tabsGap: CGFloat = 1
    static let footerRadius: CGFloat = 16
    static let addFieldHeight: CGFloat = 30.5
    static let addPlus: CGFloat = 14
    static let addPaddingX: CGFloat = 9
    static let addGap: CGFloat = 7.5

    // Chips: 12 px above, 8 px below, 42 px tall, 4 px apart, 20 px text.
    static let chipsTop: CGFloat = 6
    static let chipsBottom: CGFloat = 4
    static let chipHeight: CGFloat = 21
    static let chipGap: CGFloat = 2
    static let chipPaddingX: CGFloat = 8
    static let chipsRowHeight: CGFloat = chipsTop + chipHeight + chipsBottom
    /// The list starts 2 under the header (4 px).
    static let listTopGap: CGFloat = 2

    // List: inset 20 px from the sides, fading over its last 56 px.
    static let listInset: CGFloat = 10
    static let listFade: CGFloat = 28
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

/// A filter chip (the owner's panel design): 21 tall, 10 pt text; the
/// chosen one on the app's glass selector (owner, 2026-10-28: what would
/// be glass in the app is glass; the design's white pill is HTML's stand-in),
/// in the primary ink; the others plain, in the helper grey. A tag chip's
/// text takes its tag's colour, as the row's tag pill does.
struct TasksFilterChip: View {
    let title: String
    let selected: Bool
    var tag: String?
    /// Shared by a row's chips: the selector slides between them.
    var selector: Namespace.ID?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        let dark = design.mode == .dark
        let shape = Squircle(cornerRadius: TasksDesignMetrics.innerRadius, exponent: TasksDesignMetrics.cornerExponent)
        let ink = tag.map { TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: colouring.hue(for: $0)), dark: dark).text.color }
            ?? tokens.color(selected || hovered ? .heading : .helper)
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10))
                .foregroundStyle(ink)
                .padding(.horizontal, TasksDesignMetrics.chipPaddingX)
                .frame(height: TasksDesignMetrics.chipHeight)
                .background {
                    if selected {
                        if let selector {
                            Color.clear.atticRaisedMaterial(cornerRadius: TasksDesignMetrics.innerRadius, interactive: false)
                                .matchedGeometryEffect(id: "chip-selector", in: selector)
                        } else {
                            Color.clear.atticRaisedMaterial(cornerRadius: TasksDesignMetrics.innerRadius, interactive: false)
                        }
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Now · Later · Done as icon tabs at the footer's left (the owner's panel
/// design): three 26.5 pt cells (sun, clock, tick) in one glass container
/// with the design's corner; the page shown on a white cell in the primary ink, the
/// others quiet. ←/→ move between them; VoiceOver reads each by name.
struct TasksFooterTabs: View {
    @Binding var selection: TasksTab

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticKeyboardFocusVisible) private var keyboardFocusVisible
    @FocusState private var focused: Bool
    @State private var hovered: TasksTab?

    static func symbol(_ tab: TasksTab) -> String {
        switch tab {
        case .now: "sun.max"
        case .backlog: "clock"
        case .done: "checkmark"
        }
    }

    var body: some View {
        let m = TasksDesignMetrics.self
        let tokens = design.tokens
        let dark = design.mode == .dark
        let tabs = TasksTab.allCases
        let selected = tabs.firstIndex(of: selection) ?? 0
        HStack(spacing: m.tabsGap) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    AtticIcon(systemName: Self.symbol(tab), size: 11.5, weight: .medium,
                              ink: on || hovered == tab ? .heading : .icon)
                        .frame(width: m.tabCell, height: m.tabCell)
                        .background {
                            if on {
                                Image(nsImage: TasksThumbImage.image(diameter: m.tabCell, dark: dark))
                                    .frame(width: m.tabCell + TasksThumbImage.pad * 2, height: m.tabCell + TasksThumbImage.pad * 2)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Squircle(cornerRadius: m.innerRadius, exponent: m.cornerExponent))
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
        .padding(m.tabsPadding)
        // The glass behind the cells, never over them.
        .background(Color.clear.atticRaisedMaterial(cornerRadius: m.footerRadius, interactive: false))
        .atticFocusRing(capture == nil && focused && keyboardFocusVisible, cornerRadius: m.footerRadius)
        .animation(design.reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
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

/// The white thumb under the footer's current tab (the owner's panel
/// design): a white rounded square in the design's corner (`rInner`,
/// superellipse(1.4), clamped to half the side; 16 % white in dark), a 0.5 pt grey edge and the
/// soft grey shadow, drawn once into a bitmap. Drawn as SwiftUI shapes
/// over the glass each part was a masked layer, and the `.shadow` a layer
/// shadow without a path: offscreen passes every frame the footer was
/// composited, as the list scrolled under it (fix round 1, measured in the
/// panel census). The image is one plain layer.
enum TasksThumbImage {
    static let shadowRadius: CGFloat = 1.5
    static let shadowY: CGFloat = 1
    /// Room around the disc for the shadow.
    static let pad: CGFloat = 4

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(diameter: CGFloat, dark: Bool) -> NSImage {
        let key = "\(diameter)-\(dark)"
        if let cached = cache[key] { return cached }
        let side = diameter + pad * 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let disc = NSRect(x: pad, y: pad, width: diameter, height: diameter)
            func outline(_ rect: NSRect) -> NSBezierPath {
                NSBezierPath(cgPath: Squircle(cornerRadius: TasksDesignMetrics.innerRadius,
                                              exponent: TasksDesignMetrics.cornerExponent).path(in: rect).cgPath)
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0.5, alpha: 0.12)
            shadow.shadowBlurRadius = shadowRadius * 2
            // Flipped: a positive height moves the shadow down.
            shadow.shadowOffset = NSSize(width: 0, height: shadowY)
            shadow.set()
            (dark ? NSColor(white: 1, alpha: 0.16) : NSColor.white).setFill()
            outline(disc).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(red: 185 / 255, green: 189 / 255, blue: 191 / 255, alpha: dark ? 0.25 : 0.6).setStroke()
            let edge = outline(disc.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()
            return true
        }
        cache[key] = image
        return image
    }
}

/// The footer's tabs, folded away while the add field is used (the
/// design's turn): only this slot watches the draft, so a keystroke
/// never redraws the page.
struct TasksFooterTabsSlot: View {
    @ObservedObject var text: TasksAddBarState
    let addFocused: Bool
    @Binding var selection: TasksTab

    @Environment(\.atticDesign) private var design

    var body: some View {
        let hasDraft = !text.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let folded = TasksPanelDesign.footerFolded(addFocused: addFocused, hasDraft: hasDraft)
        TasksFooterTabs(selection: $selection)
            .fixedSize()
            .frame(width: folded ? 0 : nil, alignment: .leading)
            .opacity(folded ? 0 : 1)
            .padding(.trailing, folded ? 0 : TasksDesignMetrics.footerGap)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
            .animation(design.reduceMotion ? .easeOut(duration: 0.15) : TasksDesignMetrics.curve(0.26), value: folded)
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
