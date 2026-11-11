import AppKit
import SwiftUI

/// The canvas menu's sizes: the working file's Draw menu (design px at 2×,
/// halved) on the app's menu rows and card (`AtticGlassMenuShape`,
/// `AtticDropdownMetrics`, `AtticMenuMetrics`).
enum DrawLibraryMetrics {
    /// The menus' wide width (224 pt; the drawing's card is 210 pt).
    static let width: CGFloat = AtticMenuMetrics.wideWidth
    /// The list scrolls past this unless the page gives the room it has
    /// (the drawing's 640 px).
    static let maxListHeight: CGFloat = 320
    /// The card's first row, the search field: 60 px tall, 18 px side
    /// padding, a 20 px magnifier 12 px from 22 px text; 6 px above the list.
    static let searchRowHeight: CGFloat = 30
    static let searchRowGap: CGFloat = 3
    static let searchPadding: CGFloat = 9
    static let searchIcon: CGFloat = 10
    static let searchIconGap: CGFloat = 6
    static let searchFont: CGFloat = 11
    /// The leading column: the canvas thumbnail (44 × 33 px), the "+" and
    /// the commands' icons share it.
    static let thumbnail = CGSize(width: 22, height: 16.5)
    static let thumbnailRadius: CGFloat = 4
    /// The thumbnail sits this far into the row's padding (the drawing's
    /// −6 px).
    static let thumbnailOutdent: CGFloat = 3

    static func height(of row: DrawLibraryMenuModel.Row) -> CGFloat {
        AtticDropdownMetrics.rowHeight + (row.startsSection ? AtticDropdownMetrics.separatorHeight : 0)
    }

    /// The list's natural height (known up front, so nothing is measured
    /// while the filter changes).
    static func listHeight(_ rows: [DrawLibraryMenuModel.Row]) -> CGFloat {
        rows.reduce(0) { $0 + height(of: $1) }
    }
}

/// The canvas menu: a card under the top row. On the page its first row is
/// the search field (the drawing's `dv.titleMenu`): typing filters, ↑ ↓
/// move, Return opens the first match (or New canvas “…”), Escape closes.
struct DrawLibraryMenu: View {
    @ObservedObject var model: DrawLibraryMenuModel
    /// The list's tallest, before it scrolls: the room under the card's search row.
    var maxListHeight: CGFloat = DrawLibraryMetrics.maxListHeight
    /// Escape in the search row; without it the card has no search row.
    var onSearchEscape: (() -> Void)?
    var isActive = true
    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelToasts) private var toasts

    init(model: DrawLibraryMenuModel, maxListHeight: CGFloat = DrawLibraryMetrics.maxListHeight,
         onSearchEscape: (() -> Void)? = nil, isActive: Bool = true) {
        self.model = model
        self.maxListHeight = maxListHeight
        self.onSearchEscape = onSearchEscape
        self.isActive = isActive
    }

    var body: some View {
        Group {
            switch model.mode {
            case .list:
                DrawLibraryCard(width: DrawLibraryMetrics.width) {
                    VStack(spacing: 0) {
                        if let onSearchEscape {
                            searchRow(onEscape: onSearchEscape)
                        }
                        DrawLibraryRows(model: model, rows: model.rows, maxHeight: maxListHeight)
                    }
                }
                .accessibilityLabel(String(localized: "Canvases"))
            case .tags:
                DrawCanvasTagEditor(model: model)
                    .frame(width: DrawLibraryMetrics.width)
            }
        }
        .onAppear { model.toasts = toasts }
        .onChange(of: toasts.map(ObjectIdentifier.init)) { _, _ in model.toasts = toasts }
        .accessibilityIdentifier("draw-library-menu")
    }

    /// The card's first row, edge to edge over the card's inset: a 10 pt
    /// magnifier 6 pt from 11 pt text, a hairline under it, 3 pt above the list.
    private func searchRow(onEscape: @escaping () -> Void) -> some View {
        let m = DrawLibraryMetrics.self
        let inset = AtticGlassMenuShape.inset
        return HStack(spacing: m.searchIconGap) {
            AtticIcon(systemName: "magnifyingglass", size: m.searchIcon, weight: AtticIconWeight.outline, ink: .helper)
            DrawTitleField(text: $model.filter, placeholder: String(localized: "Search"),
                           label: String(localized: "Find a canvas"), onReturn: model.openFirstMatch,
                           onMove: model.moveHighlight(by:), onEscape: onEscape, onEnd: nil,
                           alignment: .left, font: .systemFont(ofSize: m.searchFont),
                           identifier: "draw-library-search", requestsFocus: isActive)
                .accessibilityIdentifier("draw-library-search")
        }
        .padding(.horizontal, m.searchPadding)
        .frame(height: m.searchRowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(design.tokens.dropdownRule.color)
                .frame(height: AtticDropdownMetrics.headerRule)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, -inset)
        .padding(.top, -inset)
        .padding(.bottom, m.searchRowGap)
    }
}

/// A menu card on the command menus' material (`AtticGlassMenuSurface`:
/// glass, or the opaque card under Reduce Transparency and the solid
/// controls setting), with its rows `AtticGlassMenuShape.inset` in.
struct DrawLibraryCard<Content: View>: View {
    var width: CGFloat?
    @ViewBuilder let content: Content
    @Environment(\.atticDesign) private var design

    var body: some View {
        let style = AtticGlassMenuStyle(design: design)
        content
            .padding(AtticGlassMenuShape.inset)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(AtticGlassMenuSurface(style: style))
            .clipShape(Squircle(cornerRadius: AtticGlassMenuShape.radius))
            .accessibilityElement(children: .contain)
    }
}

/// The rows, scrolling past `maxListHeight`; the highlighted row stays in
/// view as ↑ ↓ move it.
struct DrawLibraryRows: View {
    let rows: [DrawLibraryMenuModel.Row]
    let litID: String?
    var scrollTarget: String?
    var maxHeight: CGFloat = DrawLibraryMetrics.maxListHeight
    let hover: (DrawLibraryMenuModel.Row, Bool) -> Void
    let choose: (DrawLibraryMenuModel.Row) -> Void
    /// The rows' canvases once they show (and again when they or the
    /// appearance change): the page re-renders thumbnails drawn for the
    /// other appearance. Runs after the list appears, never during layout.
    var thumbnailsShown: (([DrawCanvas]) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    init(rows: [DrawLibraryMenuModel.Row], litID: String?, scrollTarget: String? = nil,
         maxHeight: CGFloat = DrawLibraryMetrics.maxListHeight,
         hover: @escaping (DrawLibraryMenuModel.Row, Bool) -> Void, choose: @escaping (DrawLibraryMenuModel.Row) -> Void,
         thumbnailsShown: (([DrawCanvas]) -> Void)? = nil) {
        self.rows = rows
        self.litID = litID
        self.scrollTarget = scrollTarget
        self.maxHeight = maxHeight
        self.hover = hover
        self.choose = choose
        self.thumbnailsShown = thumbnailsShown
    }

    init(model: DrawLibraryMenuModel, rows: [DrawLibraryMenuModel.Row], maxHeight: CGFloat) {
        let actions = model.actions
        self.init(rows: rows, litID: model.litRowID(in: rows), scrollTarget: model.highlightedID, maxHeight: maxHeight,
                  hover: { model.hover($0, inside: $1) }, choose: { model.choose($0) },
                  thumbnailsShown: { actions.thumbnailsShown($0) })
    }

    /// What the shown thumbnails are: each canvas, its thumbnail and the
    /// appearance it was rendered for, and the current appearance.
    private var shownThumbnails: [String] {
        rows.compactMap { row in
            row.canvas.map { "\($0.id.uuidString) \($0.thumbnail?.hashValue ?? 0) \(String(describing: $0.thumbnailDark))" }
        } + [colorScheme == .dark ? "dark" : "light"]
    }

    var body: some View {
        let height = DrawLibraryMetrics.listHeight(rows)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.startsSection { AtticDropdownRule() }
                        DrawLibraryRowView(row: row, isLit: row.id == litID,
                                           onHover: { inside in hover(row, inside) }) {
                            choose(row)
                        }
                        .id(row.id)
                    }
                }
            }
            .scrollDisabled(height <= maxHeight)
            .frame(height: min(height, maxHeight))
            .task(id: shownThumbnails) {
                thumbnailsShown?(rows.compactMap(\.canvas))
            }
            .onChange(of: scrollTarget) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

/// One row, drawn as the glass menus draw theirs: the leading column
/// (thumbnail, "+" or icon), the title (semibold for the open canvas), the
/// date, and a tick on the open canvas. No row prints a key.
struct DrawLibraryRowView: View {
    let row: DrawLibraryMenuModel.Row
    let isLit: Bool
    var onHover: ((Bool) -> Void)?
    let action: () -> Void
    @Environment(\.atticDesign) private var design

    var body: some View {
        let style = AtticGlassMenuStyle(design: design)
        let m = AtticDropdownMetrics.self
        let ink: NSColor = !row.isEnabled ? style.disabled : (row.isDestructive ? style.destructive : style.title)
        let iconInk: NSColor = !row.isEnabled ? style.disabled : (row.isDestructive ? style.destructive : style.icon)
        Button(action: action) {
            HStack(spacing: m.columnGap) {
                leading(iconInk: iconInk)
                    .frame(width: DrawLibraryMetrics.thumbnail.width, height: m.rowHeight)
                    .padding(.leading, row.canvas == nil ? 0 : -DrawLibraryMetrics.thumbnailOutdent)
                    .padding(.trailing, row.canvas == nil ? 0 : DrawLibraryMetrics.thumbnailOutdent)
                Text(verbatim: row.title)
                    .font(Font(row.isOpen
                                ? NSFont.systemFont(ofSize: AtticGlassMenuStyle.titleFont.pointSize, weight: .semibold)
                                : AtticGlassMenuStyle.titleFont))
                    .foregroundStyle(Color(nsColor: ink))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(Font(AtticGlassMenuStyle.detailFont))
                        .foregroundStyle(Color(nsColor: style.detail))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, m.detailGap - m.columnGap)
                }
                if row.isOpen {
                    Image(systemName: "checkmark")
                        .font(.system(size: m.checkSize, weight: .semibold))
                        .foregroundStyle(Color(nsColor: ink))
                        .frame(width: m.checkSlot)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, m.rowPadding)
            .frame(height: m.rowHeight)
            .background {
                if isLit, row.isEnabled {
                    Squircle(cornerRadius: AtticGlassMenuShape.rowRadius).fill(Color(nsColor: style.highlight))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .onHover { onHover?($0) }
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityValue(Text(verbatim: row.detail ?? ""))
        .accessibilityAddTraits(row.isOpen ? .isSelected : [])
        .accessibilityIdentifier("draw-library-row-\(row.id)")
    }

    @ViewBuilder
    private func leading(iconInk: NSColor) -> some View {
        let m = AtticDropdownMetrics.self
        switch row.kind {
        case let .canvas(canvas):
            DrawCanvasThumbnail(canvas: canvas)
        case .newCanvas:
            Image(systemName: "plus")
                .font(.system(size: m.iconSize))
                .foregroundStyle(Color(nsColor: iconInk))
                .accessibilityHidden(true)
        case let .command(command):
            Image(systemName: command.systemImage)
                .font(.system(size: m.iconSize))
                .foregroundStyle(Color(nsColor: iconInk))
                .accessibilityHidden(true)
        case .noMatch:
            Color.clear
        }
    }
}

/// The store's thumbnail payload; an empty canvas (no thumbnail) keeps the
/// empty card in the board's colour with its hairline.
struct DrawCanvasThumbnail: View {
    let canvas: DrawCanvas
    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = Squircle(cornerRadius: DrawLibraryMetrics.thumbnailRadius)
        let size = DrawLibraryMetrics.thumbnail
        ZStack {
            shape.fill(design.tokens.contentCard.color)
            if let image = DrawThumbnailCache.image(for: canvas) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
            }
            shape.inset(by: AtticHairline.width / 2)
                .stroke(design.tokens.contentCardRim.color, lineWidth: AtticHairline.width)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// Decoded thumbnails, by canvas and its last change, so a row never decodes
/// while the list re-renders.
@MainActor
enum DrawThumbnailCache {
    private static var images: [String: NSImage] = [:]

    static func image(for canvas: DrawCanvas) -> NSImage? {
        guard let data = canvas.thumbnail, !data.isEmpty else { return nil }
        // A thumbnail write leaves the canvas's date alone, so the bytes key it.
        let key = "\(canvas.id.uuidString)-\(data.count)-\(data.hashValue)"
        if let cached = images[key] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        if images.count > 128 { images.removeAll() }
        images[key] = image
        return image
    }
}

/// Tags…: the app's tag picker (the solid E1 card Notes and Tasks use),
/// listing every canvas tag with its count, the open canvas's ticked.
struct DrawCanvasTagEditor: View {
    @ObservedObject var model: DrawLibraryMenuModel
    @State private var fieldClaim = AtticFieldClaim()

    var body: some View {
        let current = Set(model.currentCanvas?.tags ?? [])
        let counts = model.tagCounts
        AtticDropdownCard(width: DrawLibraryMetrics.width) {
            AtticTagPickerCard(rows: { query in
                let typed = AtticTag.normalize(query)
                let create: String? = typed.flatMap { counts[$0] == nil ? $0 : nil }
                return (Self.rows(counts, current: current, typed: typed), create)
            }, listRows: counts.count, onToggle: { name in
                model.setTag(name, on: !Set(model.currentCanvas?.tags ?? []).contains(name))
            }, onCreate: { name, _ in
                model.setTag(name, on: true)
                return true
            }, onEscape: model.closeTags)
        }
        .background(AtticFieldClaimProbe(claim: fieldClaim, placeholder: String(localized: "Tag"),
            wanted: { model.mode == .tags }).accessibilityHidden(true))
        .onAppear {
            // The inline card replaces the filter's live field. Claim its
            // own native field after attachment, once the old editor leaves.
            let request = fieldClaim.beginFocusRequest()
            DispatchQueue.main.async {
                guard model.mode == .tags, let window = fieldClaim.field?.window else { return }
                fieldClaim.takeKeyboard(request: request, in: window)
            }
        }
        .onDisappear { fieldClaim.cancelFocusRequest() }
        .onExitCommand { model.closeTags() }
        .accessibilityIdentifier("draw-library-tags")
    }

    /// The canvas's own tags first, then by how many canvases carry them.
    static func rows(_ counts: [String: Int], current: Set<String>, typed: String?) -> [AtticTagPicker.Tag] {
        counts.compactMap { name, count -> (String, Int, Bool)? in
            if let typed, !name.localizedStandardContains(typed) { return nil }
            return (name, count, current.contains(name))
        }
        .sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        .map { AtticTagPicker.Tag(name: $0.0, state: $0.2 ? .on : .off, detail: "\($0.1)") }
    }
}
