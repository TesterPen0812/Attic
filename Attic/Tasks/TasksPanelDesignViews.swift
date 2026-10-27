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
        .background(RoundedRectangle(cornerRadius: TasksDesignMetrics.tileRadius, style: .continuous)
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
/// chosen one white with a hairline and a soft shadow, in the primary ink;
/// the others in the helper grey.
struct TasksFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let tokens = design.tokens
        let dark = design.mode == .dark
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10))
                .foregroundStyle(tokens.color(selected || hovered ? .heading : .helper))
                .padding(.horizontal, TasksDesignMetrics.chipPaddingX)
                .frame(height: TasksDesignMetrics.chipHeight)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(dark ? AtticRGBA(red: 1, green: 1, blue: 1, alpha: 0.16).color : Color.white)
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(AtticRGBA(red: 185 / 255, green: 189 / 255, blue: 191 / 255, alpha: dark ? 0.25 : 0.6).color,
                                              lineWidth: 0.5))
                            .shadow(color: AtticRGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.12).color, radius: 1.5, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Now · Later · Done as icon tabs at the footer's left (the owner's panel
/// design): three 26.5 pt cells (sun, clock, tick) in one round glass
/// container; the page shown on a white cell in the primary ink, the
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
                                Circle()
                                    .fill(dark ? AtticRGBA(red: 1, green: 1, blue: 1, alpha: 0.16).color : Color.white)
                                    .overlay(Circle().strokeBorder(
                                        AtticRGBA(red: 185 / 255, green: 189 / 255, blue: 191 / 255, alpha: dark ? 0.25 : 0.6).color,
                                        lineWidth: 0.5))
                                    .shadow(color: AtticRGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.12).color, radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Circle())
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
                AtticRaisedButton(systemName: nil, title: "Clear filters", height: 22, action: clear)
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
