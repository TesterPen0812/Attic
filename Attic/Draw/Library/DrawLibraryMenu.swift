import AppKit
import SwiftUI

/// The canvas menu's sizes: the working file's Draw menu (design px at 2×,
/// halved) on the app's menu rows and card (`AtticGlassMenuShape`,
/// `AtticDropdownMetrics`, `AtticMenuMetrics`).
enum DrawLibraryMetrics {
    /// The menus' wide width (224 pt; the drawing's card is 210 pt).
    static let width: CGFloat = AtticMenuMetrics.wideWidth
    /// The list scrolls past this (the drawing's 640 px).
    static let maxListHeight: CGFloat = 320
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

/// The menu that hangs under the title capsule. The page shows it while
/// the capsule is open as the filter (D4: the menu has no search row of its
/// own); keys come through the model.
struct DrawLibraryMenu: View {
    @ObservedObject var model: DrawLibraryMenuModel
    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelToasts) private var toasts

    init(model: DrawLibraryMenuModel) {
        self.model = model
    }

    var body: some View {
        Group {
            switch model.mode {
            case .list:
                DrawLibraryCard(width: DrawLibraryMetrics.width) {
                    DrawLibraryRows(model: model, rows: model.rows)
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

/// The rows, scrolling past `maxListHeight`.
struct DrawLibraryRows: View {
    @ObservedObject var model: DrawLibraryMenuModel
    let rows: [DrawLibraryMenuModel.Row]

    var body: some View {
        let lit = model.litRowID(in: rows)
        let height = DrawLibraryMetrics.listHeight(rows)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.startsSection { AtticDropdownRule() }
                        DrawLibraryRowView(row: row, isLit: row.id == lit,
                                           onHover: { inside in model.hover(inside ? row : nil) }) {
                            model.choose(row)
                        }
                        .id(row.id)
                    }
                }
            }
            .scrollDisabled(height <= DrawLibraryMetrics.maxListHeight)
            .scrollIndicators(.automatic)
            .frame(height: min(height, DrawLibraryMetrics.maxListHeight))
            .onChange(of: model.highlightedID) { _, id in
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

/// The store's thumbnail payload; until job 3 renders one, an empty card in
/// the board's colour with its hairline.
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
        let key = "\(canvas.id.uuidString)-\(canvas.updatedAt.timeIntervalSinceReferenceDate)-\(data.count)"
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
            })
        }
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
