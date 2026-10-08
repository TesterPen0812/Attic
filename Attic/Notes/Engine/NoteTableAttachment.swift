import AppKit

/// A table on its own line in the note's text (one U+FFFC).
///
/// Unlike the other objects, a table's grid changes in place while it is in
/// the text (typing in a cell must never re-make the attachment, or TextKit
/// would host a new view and the cell would lose the keyboard). Every
/// change goes through the engine (`NoteEditorEngine.changeTable`), which
/// records it as an Undo step holding the grid before and after, so an Undo
/// step that holds this attachment still restores exactly what it showed:
/// the grid only changes while the attachment is in the text, and only
/// through steps the history records in order.
///
/// In the editor the table is hosted as a view (`NoteTableView`, through
/// TextKit 2's attachment view provider): a drawn grid with one live cell
/// editor. Elsewhere (print) it is drawn as an image.
final class NoteTableAttachment: NoteObjectAttachment {
    /// The grid, changed only through the engine.
    var table: NoteTable {
        didSet {
            guard table != oldValue else { return }
            layoutCache = nil
            MainActor.assumeIsolated { hostedView?.modelDidChange() }
        }
    }
    let extras: [String: NoteJSON]
    /// The editor this table lives in (set by the engine when it renders
    /// the note's objects); nil in print and in copies on the pasteboard.
    weak var engine: NoteEditorEngine?
    /// The look its text is drawn in.
    var style = NoteTextStyle()

    init(objectID: UUID = UUID(), table: NoteTable, extras: [String: NoteJSON] = [:]) {
        self.table = table
        self.extras = extras
        super.init(objectID: objectID)
    }

    override var isBlockObject: Bool { true }

    override var accessibilityDescription: String {
        String(localized: "Table, \(table.columnCount) columns, \(table.rowCount) rows")
    }

    // MARK: Layout

    @MainActor let textCache = NoteTableTextCache()
    private var layoutCache: NoteTableLayout?

    /// The table's layout in a column `width` wide.
    @MainActor func layout(width: CGFloat) -> NoteTableLayout {
        if let layoutCache, abs(layoutCache.viewportWidth - max(AtticNoteTableMetrics.minColumnWidth, width)) < 0.5 {
            return layoutCache
        }
        let table = self.table
        let layout = NoteTableLayout.make(table, viewport: width, natural: { position in
            let header = table.headerRow && position.row == 0
            let cell = table[position]
            return textCache.natural(cell, header: header) { cellString(at: position) }
        }, minimum: { position in
            let header = table.headerRow && position.row == 0
            return textCache.minimum(table[position], header: header) { cellString(at: position) }
        }, height: { position, width in
            let header = table.headerRow && position.row == 0
            let cell = table[position]
            return textCache.height(cell, header: header, width: width) { cellString(at: position) }
        })
        layoutCache = layout
        return layout
    }

    /// Forgets the layout (a cell's live text changed its height, or the
    /// look changed).
    @MainActor func invalidateLayout(clearingText: Bool = false) {
        layoutCache = nil
        if clearingText { textCache.clear() }
    }

    /// A cell's text as drawn (dates prepared by the editor's renderer).
    @MainActor func cellString(at position: NoteTable.Position) -> NSMutableAttributedString {
        let header = table.headerRow && position.row == 0
        let align = table.columns.indices.contains(position.column) ? table.columns[position.column].align : .left
        return NoteTextCodec.cellString(table[position], attributes: style.tableCellAttributes(header: header, alignment: align),
                                        style: style, prepare: { [weak engine] object in engine?.prepareCellObject(object) })
    }

    private var columnWidth: CGFloat = 264

    /// The bounds TextKit asks the view provider for. (The attachment must
    /// not override `attachmentBounds(for:location:…)` itself: TextKit 2
    /// then never asks it for a view provider.)
    func providerBounds(for attributes: [NSAttributedString.Key: Any], textContainer: NSTextContainer?,
                        proposedLineFragment: CGRect) -> CGRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = max(AtticNoteTableMetrics.minColumnWidth, proposedLineFragment.width - padding * 2)
        return MainActor.assumeIsolated { bounds(columnWidth: width, attributes: attributes) }
    }

    /// The line the table occupies: the column's width, exactly the grid's
    /// height. The attachment sits on the baseline, so it is lowered by the
    /// font's descent: the line box is then the grid and nothing more.
    @MainActor func bounds(columnWidth width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGRect {
        columnWidth = width
        let font = (attributes[.font] as? NSFont) ?? style.bodyFont
        let height = layout(width: width).height
        return CGRect(x: 0, y: font.descender, width: width, height: height)
    }

    // MARK: The hosted view

    /// The view TextKit hosts. Kept for the attachment's lifetime, so a
    /// re-laid-out line gets the same view back (its live cell editor, its
    /// scroll position).
    @MainActor private(set) var hostedView: NoteTableView?

    @MainActor var tableView: NoteTableView {
        if let hostedView { return hostedView }
        let view = NoteTableView(attachment: self)
        hostedView = view
        return view
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        guard allowsTextAttachmentView else { return nil }
        let provider = NoteTableViewProvider(textAttachment: self, parentView: parentView,
                                             textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    /// Print and other non-editing uses: the grid drawn at `width`.
    @MainActor func renderImage(width: CGFloat, design: AtticDesignContext) -> NSImage {
        var layout = layout(width: width)
        if layout.scrolls {
            // Print has no sideways scrolling: the columns shrink in
            // proportion to the page and their text wraps again.
            let scale = width / layout.width
            layout = layout.withColumnWidths(layout.columnWidths.map { ($0 * scale).rounded(.down) },
                                             table: table, cache: textCache, string: cellString(at:))
        }
        let table = self.table
        let final = layout
        return NSImage(size: CGSize(width: width, height: final.height), flipped: true) { [self] _ in
            NoteTableDrawing.draw(table: table, layout: final, design: design, style: style,
                                  string: { cellString(at: $0) }, skipping: nil)
            return true
        }
    }
}

extension NoteTableLayout {
    /// The same rows re-measured at the given column widths.
    @MainActor func withColumnWidths(_ widths: [CGFloat], table: NoteTable, cache: NoteTableTextCache,
                                     string: (NoteTable.Position) -> NSAttributedString) -> NoteTableLayout {
        let lineHeight = AtticNoteType.body.lineHeight
        let heights: [CGFloat] = table.rows.indices.map { row in
            var tallest = lineHeight
            for column in table.columns.indices where column < widths.count {
                let position = NoteTable.Position(row: row, column: column)
                let width = max(1, widths[column] - 2 * M.cellPaddingH)
                tallest = max(tallest, cache.height(table[position], header: table.headerRow && row == 0, width: width) {
                    string(position)
                })
            }
            return ceil(tallest) + 2 * M.cellPaddingV
        }
        return NoteTableLayout(columnWidths: widths, rowHeights: heights, viewportWidth: viewportWidth)
    }
}

/// Hands TextKit the attachment's one view.
final class NoteTableViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let table = textAttachment as? NoteTableAttachment else { return super.loadView() }
        view = MainActor.assumeIsolated { table.tableView }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        guard let table = textAttachment as? NoteTableAttachment else {
            return super.attachmentBounds(for: attributes, location: location, textContainer: textContainer,
                                          proposedLineFragment: proposedLineFragment, position: position)
        }
        return table.providerBounds(for: attributes, textContainer: textContainer, proposedLineFragment: proposedLineFragment)
    }
}
