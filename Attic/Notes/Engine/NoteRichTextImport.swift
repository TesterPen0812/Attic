import AppKit

/// Shared semantic adapter for the already sanitized native clipboard text.
/// Whole-note paste and table-only paste must use the same mark/grid rules.
@MainActor
enum NoteRichTextImport {
    static func document(from imported: NSAttributedString, style: NoteTextStyle) -> NoteDocument {
        let source = NSMutableAttributedString(attributedString: imported)
        let result = NSMutableAttributedString(string: source.string, attributes: style.bodyAttributes)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment], attachment is NoteImageAttachment || attachment is NoteFileAttachment {
                result.addAttribute(.attachment, value: attachment, range: range)
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { result.addAttribute(.noteMark(.bold), value: true, range: range) }
                if traits.contains(.italic) { result.addAttribute(.noteMark(.italic), value: true, range: range) }
                if traits.contains(.monoSpace) { result.addAttribute(.noteMark(.code), value: true, range: range) }
            }
            if (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { result.addAttribute(.noteMark(.underline), value: true, range: range) }
            if (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { result.addAttribute(.noteMark(.strikethrough), value: true, range: range) }
            if let background = attributes[.backgroundColor] as? NSColor,
               let value = highlightValue(for: background, style: style) {
                result.addAttribute(.noteMark(.highlight), value: value, range: range)
            }
            if let url = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String {
                result.addAttribute(.noteMark(.link), value: url, range: range)
            }
        }
        // List identity is a paragraph property. A foreign list kind or an
        // unsupported depth stays readable as literal marker text.
        var paragraphs: [(range: NSRange, lists: [NSTextList])] = []
        let sourceString = source.string as NSString
        var start = 0
        while start < sourceString.length {
            let paragraph = sourceString.paragraphRange(for: NSRange(location: start, length: 0))
            let nativeStyle = source.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            let lists = nativeStyle?.textLists ?? []
            if let level = nativeStyle?.headerLevel, (1...6).contains(level) {
                result.addAttribute(.noteBlockStyle, value: "heading", range: paragraph)
                result.addAttribute(.noteBlockLevel, value: level, range: paragraph)
            } else if lists.isEmpty, nativeStyle?.textBlocks.isEmpty != false, (nativeStyle?.headIndent ?? 0) > 0 {
                result.addAttribute(.noteBlockStyle, value: "quote", range: paragraph)
            }
            paragraphs.append((paragraph, lists))
            start = NSMaxRange(paragraph)
        }
        var ordinals: [Int: Int] = [:]
        var listIdentities: [Int: ObjectIdentifier] = [:]
        var literals: [(Int, String)] = []
        func numbered(_ list: NSTextList) -> Bool {
            list.markerFormat == .decimal || list.markerFormat.rawValue == "{decimal}."
        }
        func supported(_ list: NSTextList) -> Bool {
            numbered(list) || [.disc, .circle, .square].contains(list.markerFormat) ||
                ["{disc}.", "{circle}.", "{square}."].contains(list.markerFormat.rawValue)
        }
        for entry in paragraphs {
            guard let list = entry.lists.last else { ordinals.removeAll(); listIdentities.removeAll(); continue }
            let depth = entry.lists.count - 1
            ordinals = ordinals.filter { $0.key <= depth }
            listIdentities = listIdentities.filter { $0.key <= depth }
            let first = listIdentities[depth] != ObjectIdentifier(list)
            let previous = ordinals[depth] ?? list.startingItemNumber
            let ordinal = first ? list.startingItemNumber : (previous < Int.max ? previous + 1 : previous)
            ordinals[depth] = ordinal
            listIdentities[depth] = ObjectIdentifier(list)
            if depth <= 2 && entry.lists.allSatisfy(supported) {
                result.addAttribute(.noteBlockStyle, value: numbered(list) ? "number" : "bullet", range: entry.range)
                if first, numbered(list), ordinal > 1 { result.addAttribute(.noteListStart, value: ordinal, range: entry.range) }
                if depth > 0 { result.addAttribute(.noteBlockIndent, value: depth, range: entry.range) }
            } else {
                literals.append((entry.range.location, String(repeating: "  ", count: max(0, depth)) + list.marker(forItemNumber: ordinal) + " "))
            }
        }
        for (at, marker) in literals.reversed() {
            let prefix = NSAttributedString(string: marker, attributes: style.bodyAttributes)
            result.insert(prefix, at: at)
            source.insert(prefix, at: at)
        }
        preserveNativeTables(from: source, in: result, style: style)
        return NoteTextCodec.document(from: result, firstBlockIsTitle: false)
    }

    /// Native interchange carries RGB, not Attic's colour keys. Retain the
    /// closest supported swatch; yellow remains the default one-click mark.
    private static func highlightValue(for color: NSColor, style: NoteTextStyle) -> Any? {
        guard let color = color.usingColorSpace(.sRGB) else { return true }
        guard color.alphaComponent > 0 else { return nil }
        var best = NoteHighlightColour.yellow, distance = CGFloat.infinity
        let appearances = [style, NoteTextStyle(design: AtticDesignContext(mode: .light)),
                           NoteTextStyle(design: AtticDesignContext(mode: .dark))]
        for candidate in NoteHighlightColour.allCases {
            for appearance in appearances {
                guard let swatch = appearance.highlightColor(for: candidate.rawValue).usingColorSpace(.sRGB) else { continue }
                let r = color.redComponent - swatch.redComponent
                let g = color.greenComponent - swatch.greenComponent
                let b = color.blueComponent - swatch.blueComponent
                let value = r * r + g * g + b * b
                if value < distance { distance = value; best = candidate }
            }
        }
        return best == .yellow ? true : best.rawValue
    }

    /// AppKit exposes native HTML/RTF tables as paragraph text blocks. Rebuild
    /// each complete grid in place, retaining cell marks and all surrounding
    /// paragraphs. Unsupported/nested/object-bearing grids remain readable
    /// rich text rather than claiming a partial table and discarding content.
    private static func preserveNativeTables(from source: NSAttributedString, in result: NSMutableAttributedString, style: NoteTextStyle) {
        struct Grid {
            var range: NSRange
            var entries: [(NSRange, NSTextTableBlock)]
        }
        var grids: [ObjectIdentifier: Grid] = [:]
        let string = source.string as NSString
        var start = 0
        while start < source.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let blocks = (source.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
            if blocks.count == 1, let cell = blocks.first as? NSTextTableBlock {
                let key = ObjectIdentifier(cell.table)
                var grid = grids[key] ?? Grid(range: range, entries: [])
                grid.range = NSUnionRange(grid.range, range); grid.entries.append((range, cell)); grids[key] = grid
            }
            start = NSMaxRange(range)
        }
        for grid in grids.values.sorted(by: { $0.range.location > $1.range.location }) {
            guard let native = grid.entries.first?.1.table else { continue }
            let rowEnds = grid.entries.map { $0.1.startingRow.addingReportingOverflow($0.1.rowSpan) }
            guard rowEnds.allSatisfy({ !$0.overflow }) else { continue }
            let rows = rowEnds.map(\.partialValue).max() ?? 0
            let columns = native.numberOfColumns
            guard rows > 0, rows <= NoteTable.maxRows, columns > 0, columns <= NoteTable.maxColumns,
                  !string.substring(with: grid.range).contains(NoteDocument.objectCharacter),
                  grid.entries.allSatisfy({ $0.1.rowSpan > 0 && $0.1.columnSpan > 0 && $0.1.startingRow >= 0 && $0.1.startingColumn >= 0 && $0.1.startingColumn < columns && $0.1.columnSpan <= columns - $0.1.startingColumn }),
                  grid.entries.reduce(0, { $0 + $1.0.length }) == grid.range.length else { continue }
            var table = NoteTable(texts: Array(repeating: Array(repeating: "", count: columns), count: rows))
            var occupied = Set<NoteTable.Position>()
            for (range, nativeCell) in grid.entries {
                let position = NoteTable.Position(row: nativeCell.startingRow, column: nativeCell.startingColumn)
                let length = range.length - (string.character(at: NSMaxRange(range) - 1) == 10 ? 1 : 0)
                let fragment = result.attributedSubstring(from: NSRange(location: range.location, length: length))
                let doc = NoteTextCodec.document(from: fragment, firstBlockIsTitle: false)
                var cell = table[position]
                if occupied.contains(position) { cell.text += "\n" }
                for (index, block) in doc.blocks.enumerated() {
                    if index > 0 { cell.text += "\n" }
                    let offset = cell.text.utf16.count
                    cell.text += block.text.replacingOccurrences(of: "\u{2028}", with: "\n")
                    cell.marks += block.marks.map { NoteMark($0.kind, offset: offset + $0.offset, length: $0.length, url: $0.url, colour: $0.colour) }
                }
                if nativeCell.startingRow == 0,
                   let paragraph = source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle {
                    table.columns[position.column].align = paragraph.alignment == .center ? .center : (paragraph.alignment == .right ? .right : .left)
                }
                table[position] = cell; occupied.insert(position)
            }
            let object = NoteTableAttachment(table: table)
            let replacement = NoteTextCodec.attachmentString(object, attributes: style.bodyAttributes)
            if NSMaxRange(grid.range) < result.length || string.character(at: NSMaxRange(grid.range) - 1) == 10 {
                replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            }
            result.replaceCharacters(in: grid.range, with: replacement)
        }
    }
}
