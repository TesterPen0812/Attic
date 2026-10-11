import AppKit

/// A table's geometry in its own coordinates (flipped: y grows down).
///
/// Columns take their width from their content, 56–168 (a dragged column
/// keeps its set width). A table narrower than the text column stretches
/// every column in proportion to fill it, so a table never floats half
/// width; a wider one keeps its widths and scrolls sideways inside the
/// column. Each row is as tall as its tallest cell: the cell's wrapped text
/// plus 4 above and below.
struct NoteTableLayout: Equatable {
    typealias M = AtticNoteTableMetrics

    var columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    private let rowOrigins: [CGFloat]
    /// The column the table sits in (its viewport).
    var viewportWidth: CGFloat

    init(columnWidths: [CGFloat], rowHeights: [CGFloat], viewportWidth: CGFloat) {
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        self.viewportWidth = viewportWidth
        var origins: [CGFloat] = [0]
        origins.reserveCapacity(rowHeights.count + 1)
        var y: CGFloat = 0
        for height in rowHeights {
            y += height
            origins.append(y)
            #if DEBUG
            Self.rowOriginAdditionCount += 1
            #endif
        }
        rowOrigins = origins
    }

    var width: CGFloat { columnWidths.reduce(0, +) }
    var height: CGFloat { rowOrigins.last ?? 0 }
    var size: CGSize { CGSize(width: width, height: height) }
    /// Wider than the column: it scrolls sideways.
    var scrolls: Bool { width > viewportWidth + 0.5 }

    func columnX(_ column: Int) -> CGFloat { columnWidths.prefix(max(0, column)).reduce(0, +) }
    #if DEBUG
    nonisolated(unsafe) static var rowOriginAdditionCount = 0
    #endif
    func rowY(_ row: Int) -> CGFloat {
        rowOrigins[min(max(0, row), rowHeights.count)]
    }

    func cellRect(_ position: NoteTable.Position) -> CGRect {
        guard columnWidths.indices.contains(position.column), rowHeights.indices.contains(position.row) else { return .zero }
        return CGRect(x: columnX(position.column), y: rowY(position.row),
                      width: columnWidths[position.column], height: rowHeights[position.row])
    }

    /// Where a cell's text sits: inside the padding, raised by the body's
    /// baseline shift so its lines land where the draft (CSS) puts them.
    func textRect(_ position: NoteTable.Position) -> CGRect {
        let cell = cellRect(position)
        let shift = Self.baselineShift
        return CGRect(x: cell.minX + M.cellPaddingH, y: cell.minY + M.cellPaddingV - shift,
                      width: max(1, cell.width - 2 * M.cellPaddingH),
                      height: max(1, cell.height - 2 * M.cellPaddingV + shift))
    }

    /// The text width inside a column.
    func textWidth(column: Int) -> CGFloat {
        columnWidths.indices.contains(column) ? max(1, columnWidths[column] - 2 * M.cellPaddingH) : 1
    }

    /// The cell under `point` (clamped to the grid), or nil outside it.
    func position(at point: CGPoint, clamped: Bool = false) -> NoteTable.Position? {
        guard !columnWidths.isEmpty, !rowHeights.isEmpty else { return nil }
        if !clamped, point.x < 0 || point.y < 0 || point.x > width || point.y > height { return nil }
        var column = columnWidths.count - 1, x: CGFloat = 0
        for (index, value) in columnWidths.enumerated() {
            if point.x < x + value { column = index; break }
            x += value
        }
        var row = rowHeights.count - 1, y: CGFloat = 0
        for (index, value) in rowHeights.enumerated() {
            if point.y < y + value { row = index; break }
            y += value
        }
        return NoteTable.Position(row: point.y < 0 ? 0 : row, column: point.x < 0 ? 0 : column)
    }

    /// The vertical grid line near `x` (within the drag area), as the index
    /// of the column it ends.
    func columnEdge(near x: CGFloat) -> Int? {
        var edge: CGFloat = 0
        for (index, value) in columnWidths.enumerated() {
            edge += value
            if abs(x - edge) <= M.resizeHitWidth / 2 { return index }
        }
        return nil
    }

    static var baselineShift: CGFloat { NoteTextStyle.baselineShift(AtticNoteType.body) }

    /// The table's layout for `viewport`. `natural` is a cell's text width
    /// on one line (no wrapping); `minimum` its longest word's width;
    /// `height` its wrapped height at a width.
    ///
    /// When the columns' content widths come to more than the text column
    /// but their longest words would fit, the wider columns give up width
    /// (their text wraps) until the table fits: a table scrolls only when
    /// it can't fit without breaking words (or its widths were set by hand).
    static func make(_ table: NoteTable, viewport: CGFloat,
                     natural: (NoteTable.Position) -> CGFloat,
                     minimum: (NoteTable.Position) -> CGFloat = { _ in 0 },
                     height: (NoteTable.Position, CGFloat) -> CGFloat) -> NoteTableLayout {
        let viewport = max(M.minColumnWidth, viewport)
        var floors: [CGFloat] = []
        var widths: [CGFloat] = table.columns.enumerated().map { column, value in
            if let set = value.width {
                let width = max(M.minDraggedWidth, CGFloat(set))
                floors.append(width)
                return width
            }
            var widest: CGFloat = 0, longestWord: CGFloat = 0
            for row in table.rows.indices {
                let position = NoteTable.Position(row: row, column: column)
                widest = max(widest, natural(position))
                longestWord = max(longestWord, minimum(position))
            }
            let preferred = min(M.maxColumnWidth, max(M.minColumnWidth, ceil(widest + 2 * M.cellPaddingH)))
            floors.append(min(preferred, max(M.minColumnWidth, ceil(longestWord + 2 * M.cellPaddingH))))
            return preferred
        }
        var total = widths.reduce(0, +)
        let floor = floors.reduce(0, +)
        if total > viewport, floor <= viewport {
            // Shrink each column in proportion to the width it can give up.
            let slack = total - floor
            let excess = total - viewport
            widths = zip(widths, floors).map { width, low in (width - (width - low) * excess / slack).rounded(.down) }
            total = widths.reduce(0, +)
        }
        if total > 0, total < viewport {
            // Stretch in proportion to fill the column; whole points, the
            // last column takes what rounding leaves.
            let scale = viewport / total
            widths = widths.map { ($0 * scale).rounded(.down) }
            widths[widths.count - 1] += viewport - widths.reduce(0, +)
        }
        let lineHeight = AtticNoteType.body.lineHeight
        let heights: [CGFloat] = table.rows.indices.map { row in
            var tallest = lineHeight
            for column in table.columns.indices {
                let text = max(1, widths[column] - 2 * M.cellPaddingH)
                tallest = max(tallest, height(NoteTable.Position(row: row, column: column), text))
            }
            return ceil(tallest) + 2 * M.cellPaddingV
        }
        return NoteTableLayout(columnWidths: widths, rowHeights: heights, viewportWidth: viewport)
    }
}

/// Measures and draws cell text. Cells are laid out as the cell editor lays
/// them out: one paragraph, the body's 21 pt lines, wrapped at the column's
/// text width. Measuring caches by cell content and width.
@MainActor
final class NoteTableTextCache {
    /// Each metric can retain a complete maximum-sized table. Historical
    /// edits and widths must not grow a warm session without limit.
    nonisolated static let measurementLimit = NoteTable.maxRows * NoteTable.maxColumns

    private struct Key: Hashable {
        let cell: Int
        let header: Bool
        let width: Int
    }
    /// An LRU backed by slots, not one heap object per entry. Reads and
    /// evictions cost O(1); editing a full table evicts the obsolete cell,
    /// rather than its still-visible neighbours.
    private struct Measurements {
        private struct Entry {
            var key: Key
            var value: CGFloat
            var previous: Int?
            var next: Int?
        }
        private var slots: [Key: Int] = [:]
        private var entries: [Entry] = []
        private var oldest: Int?
        private var newest: Int?
        var count: Int { slots.count }

        subscript(key: Key) -> CGFloat? {
            mutating get {
                guard let slot = slots[key] else { return nil }
                touch(slot)
                return entries[slot].value
            }
            set {
                guard let newValue else { return }
                if let slot = slots[key] {
                    entries[slot].value = newValue
                    touch(slot)
                } else if entries.count == NoteTableTextCache.measurementLimit, let slot = oldest {
                    slots.removeValue(forKey: entries[slot].key)
                    entries[slot].key = key
                    entries[slot].value = newValue
                    slots[key] = slot
                    touch(slot)
                } else {
                    let slot = entries.count
                    entries.append(Entry(key: key, value: newValue, previous: newest, next: nil))
                    slots[key] = slot
                    if let newest { entries[newest].next = slot }
                    else { oldest = slot }
                    newest = slot
                }
            }
        }

        private mutating func touch(_ slot: Int) {
            guard newest != slot else { return }
            let previous = entries[slot].previous, next = entries[slot].next
            if let previous { entries[previous].next = next }
            else { oldest = next }
            if let next { entries[next].previous = previous }
            entries[slot].previous = newest
            entries[slot].next = nil
            if let newest { entries[newest].next = slot }
            newest = slot
        }

        mutating func removeAll() {
            slots.removeAll()
            entries.removeAll()
            oldest = nil
            newest = nil
        }
    }

    private var heights = Measurements()
    private var naturals = Measurements()
    var retainedMeasurementCount: Int { heights.count + naturals.count + minimums.count }

    func clear() {
        heights.removeAll()
        naturals.removeAll()
        minimums.removeAll()
    }

    private func key(_ cell: NoteTable.Cell, header: Bool, width: CGFloat) -> Key {
        var hasher = Hasher()
        hasher.combine(cell.text)
        hasher.combine(cell.marks.count)
        for mark in cell.marks {
            hasher.combine(mark.kind)
            hasher.combine(mark.offset)
            hasher.combine(mark.length)
        }
        hasher.combine(cell.inlines.count)
        return Key(cell: hasher.finalize(), header: header, width: Int((width * 2).rounded()))
    }

    func natural(_ cell: NoteTable.Cell, header: Bool, string: () -> NSAttributedString) -> CGFloat {
        let key = key(cell, header: header, width: 0)
        if let cached = naturals[key] { return cached }
        let text = string()
        var widest: CGFloat = 0
        // Each line of the cell, unwrapped.
        let lines = text.string.components(separatedBy: CharacterSet(charactersIn: "\u{2028}\n"))
        if lines.count <= 1 {
            widest = ceil(text.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
        } else {
            var location = 0
            for line in lines {
                let length = (line as NSString).length
                let part = text.attributedSubstring(from: NSRange(location: location, length: length))
                widest = max(widest, ceil(part.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width))
                location += length + 1
            }
        }
        naturals[key] = widest
        return widest
    }

    private var minimums = Measurements()

    /// The cell's longest word on one line (the narrowest its column can be
    /// without breaking a word).
    func minimum(_ cell: NoteTable.Cell, header: Bool, string: () -> NSAttributedString) -> CGFloat {
        let key = key(cell, header: header, width: -1)
        if let cached = minimums[key] { return cached }
        let text = string()
        let source = text.string as NSString
        var widest: CGFloat = 0
        var location = 0
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}"))
        while location < source.length {
            let rest = NSRange(location: location, length: source.length - location)
            let gap = source.rangeOfCharacter(from: separators, options: [], range: rest)
            let end = gap.location == NSNotFound ? source.length : gap.location
            if end > location {
                let word = text.attributedSubstring(from: NSRange(location: location, length: end - location))
                widest = max(widest, ceil(word.size().width))
            }
            location = end + max(1, gap.length)
        }
        minimums[key] = widest
        return widest
    }

    func height(_ cell: NoteTable.Cell, header: Bool, width: CGFloat, string: () -> NSAttributedString) -> CGFloat {
        let key = key(cell, header: header, width: width)
        if let cached = heights[key] { return cached }
        let value = Self.measure(string(), width: width)
        heights[key] = value
        return value
    }

    /// The wrapped height: whole 21 pt lines (an empty cell keeps one).
    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let lineHeight = AtticNoteType.body.lineHeight
        guard text.length > 0 else { return lineHeight }
        var measured = text
        if text.string.hasSuffix("\u{2028}") {
            // A trailing line break opens an empty last line.
            let copy = NSMutableAttributedString(attributedString: text)
            copy.append(NSAttributedString(string: "x", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            measured = copy
        }
        let rect = measured.boundingRect(with: CGSize(width: max(1, width), height: 100_000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(lineHeight, ((rect.height - 0.5) / lineHeight).rounded(.up) * lineHeight)
    }
}
