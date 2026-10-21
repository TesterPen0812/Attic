import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Independent semantic oracle. UUIDs are clipboard identities, not content;
/// Markdown attachment labels are the existing explicit text-only contract.
@MainActor
final class RoundFX3Tests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % upper
        }
    }
    private let texts = ["abc", " hello ", "    body", "\tTabbed", "   ", "", "a\u{2028}b", "x <br> &amp; \\ | ` * ==", "👩🏽‍💻 e\u{301}"]

    private func generated(_ seed: Int) -> NoteDocument {
        var rng = RNG(state: UInt64(seed) &+ 0xF3F3)
        func marked(_ text: String) -> NoteBlock {
            var block = NoteBlock.text(text)
            let length = text.utf16.count
            if length > 0 {
                // ASCII selections for random overlaps; whole graphemes for Unicode.
                let ascii = text.unicodeScalars.allSatisfy { $0.isASCII }
                var used = Set<NoteMark.Kind>()
                for _ in 0..<(1 + rng.next(4)) {
                    let kind = NoteMark.Kind.allCases[rng.next(NoteMark.Kind.allCases.count)]
                    guard used.insert(kind).inserted else { continue }
                    let start = ascii ? rng.next(length) : 0
                    let count = ascii ? 1 + rng.next(length - start) : length
                    block.marks.append(NoteMark(kind, offset: start, length: count,
                        url: kind == .link ? "https://example.invalid/a_(b)?x=1&y=2" : nil,
                        colour: kind == .highlight && rng.next(2) == 0 ? "pink" : nil))
                }
            }
            return block
        }
        var heading = marked(texts[rng.next(texts.count)]); heading.style = "heading"; heading.level = seed % 6 + 1
        var quote = marked(texts[rng.next(texts.count)]); quote.style = "quote"
        if seed % 2 == 0 { quote.callout = ["", "💡", "⚠️", "🐝"][rng.next(4)]; quote.calloutStart = seed % 4 == 0 }
        var code = NoteBlock.text(texts[rng.next(texts.count)], style: "mono")
        let languages: [String?] = [nil, "swift", "javascript", "typescript", "json", "python", "shell", "html", "css", "sql", "yaml", "diff", "mermaid", "custom hint"]
        code.language = languages[rng.next(languages.count)]
        var list: [NoteBlock] = []
        for depth in [0, 1, 2, 1, 0] {
            var item = marked(texts[rng.next(texts.count)])
            switch rng.next(3) {
            case 0: item.style = "bullet"
            case 1: item.style = "number"; item.start = [nil, 7, 12, 1_000_000_000, Int.max][rng.next(5)]
            default: item.kind = .checklist; item.id = UUID(); item.checked = rng.next(2) == 0
            }
            item.indent = depth == 0 ? nil : depth
            list.append(item)
        }
        var table = NoteTable(texts: [["Header", ""], ["a\nb", "left | right"]], headerRow: seed % 2 == 0,
                              alignments: [.left, seed % 3 == 0 ? .right : .center])
        for row in table.rows.indices {
            for column in table.columns.indices {
                let cell = marked(texts[rng.next(texts.count)].replacingOccurrences(of: "\u{2028}", with: "\n"))
                table.rows[row].cells[column] = .init(cell.text, marks: cell.marks)
            }
        }
        let attachment: NoteBlock = seed % 2 == 0 ? .image(attachmentID: UUID(), widthFraction: 0.5, pixelWidth: 2, pixelHeight: 2)
            : .file(attachmentID: UUID(), filename: "notes.txt", contentTypeIdentifier: "public.plain-text", byteCount: 7)
        var blocks = [.text("Title"), marked(texts[rng.next(texts.count)]), heading, quote, code] + list + [.table(table), attachment, .divider(), marked(texts[rng.next(texts.count)])]
        if seed % 3 == 0 { blocks.insert(.table(table.withFreshIDs()), at: 5) }
        if seed % 17 == 0 {
            let chosen = blocks[1 + (seed / 17) % (blocks.count - 1)]
            blocks = [.text("Title"), chosen]
            if seed % 34 == 0 { blocks.insert(.text(""), at: 1); blocks.append(.text("")) }
        }
        return NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks)).document()
    }

    private func signature(_ document: NoteDocument) throws -> NoteJSON {
        func strip(_ value: NoteJSON) -> NoteJSON {
            switch value {
            case let .object(object): return .object(object.filter { !["id", "attachmentID", "requires"].contains($0.key) }.mapValues(strip))
            case let .array(values):
                let stripped = values.map(strip)
                if values.first?.objectValue?["kind"]?.stringValue.flatMap(NoteMark.Kind.init(rawValue:)) != nil,
                   values.first?.objectValue?["offset"] != nil {
                    return .array(stripped.sorted {
                        let a = $0.objectValue!, b = $1.objectValue!
                        if a["kind"] != b["kind"] { return a["kind"]!.stringValue! < b["kind"]!.stringValue! }
                        return (a["offset"]?.intValue ?? 0) < (b["offset"]?.intValue ?? 0)
                    })
                }
                return .array(stripped)
            default: return value
            }
        }
        do { return strip(try JSONDecoder().decode(NoteJSON.self, from: NoteContentCodec.encode(document))) }
        catch { print("FX3 INVALID \(document)"); throw error }
    }

    private func markdownProjection(_ source: NoteDocument) -> NoteDocument {
        var result = source
        result.blocks = source.blocks.map { block in
            switch block.kind {
            case .image: .text("[image: image]")
            case .file: .text("[file: " + (block.filename ?? "file") + "]")
            default: block
            }
        }
        return result
    }

    private func pastedMarkdown(_ document: NoteDocument) throws -> NoteDocument {
        let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
        // Real engine insertion into an empty note: the first pasted paragraph
        // becomes its title. A separate hunt guard covers the body clipboard route.
        let markdown = NoteMarkdownExport.markdown(document)
        let (_, view) = target.makeView()
        defer { target.detachView(); withExtendedLifetime(view) {} }
        XCTAssertTrue(target.pasteMarkdown(markdown, at: NSRange(location: 7, length: 0)))
        var result = target.document()
        result.blocks.removeFirst()
        result.blocks[0].style = nil; result.blocks[0].level = nil
        return result
    }

    private func mismatch(_ document: NoteDocument) throws -> Bool {
        try signature(pastedMarkdown(document)) != signature(markdownProjection(document))
    }

    /// Deterministic deletion + text/mark shrinker. Keep only valid documents,
    /// then reduce text by grapheme and remove marks with adjusted UTF-16 offsets.
    private func shrink(_ input: NoteDocument) throws -> NoteDocument {
        var minimal = input, changed = true
        while changed {
            changed = false
            if minimal.blocks.count > 2 {
                for index in 1..<minimal.blocks.count {
                    var candidate = minimal; candidate.blocks.remove(at: index)
                    if try mismatch(candidate) { minimal = candidate; changed = true; break }
                }
                if changed { continue }
            }
            for index in minimal.blocks.indices where minimal.blocks[index].table != nil {
                let table = minimal.blocks[index].table!
                if table.rowCount > 1 {
                    for row in table.rows.indices {
                        var candidate = minimal; candidate.blocks[index].table!.removeRow(at: row)
                        if try mismatch(candidate) { minimal = candidate; changed = true; break }
                    }
                }
                if changed { break }
                if table.columnCount > 1 {
                    for column in table.columns.indices {
                        var candidate = minimal; candidate.blocks[index].table!.removeColumn(at: column)
                        if try mismatch(candidate) { minimal = candidate; changed = true; break }
                    }
                }
                if changed { break }
                for row in table.rows.indices {
                    for column in table.columns.indices {
                        let cell = table.rows[row].cells[column]
                        for mark in cell.marks.indices {
                            var candidate = minimal; candidate.blocks[index].table!.rows[row].cells[column].marks.remove(at: mark)
                            if try mismatch(candidate) { minimal = candidate; changed = true; break }
                        }
                        if changed { break }
                        var offset = 0
                        for character in cell.text {
                            let length = String(character).utf16.count
                            var candidate = minimal, smaller = cell
                            smaller.text = (cell.text as NSString).replacingCharacters(in: NSRange(location: offset, length: length), with: "")
                            smaller.marks = cell.marks.compactMap { mark in
                                var copy = mark
                                let end = mark.offset + mark.length
                                copy.offset = mark.offset > offset ? max(offset, mark.offset - length) : mark.offset
                                let newEnd = end > offset ? max(offset, end - length) : end
                                copy.length = newEnd - copy.offset
                                return copy.length > 0 ? copy : nil
                            }
                            candidate.blocks[index].table!.rows[row].cells[column] = smaller
                            if try mismatch(candidate) { minimal = candidate; changed = true; break }
                            offset += length
                        }
                        if changed { break }
                    }
                    if changed { break }
                }
                if changed { break }
            }
            if changed { continue }
            for index in minimal.blocks.indices where index > 0 {
                for mark in minimal.blocks[index].marks.indices {
                    var candidate = minimal; candidate.blocks[index].marks.remove(at: mark)
                    if try mismatch(candidate) { minimal = candidate; changed = true; break }
                }
                if changed { break }
                let text = minimal.blocks[index].text
                var offset = 0
                for character in text {
                    let length = String(character).utf16.count
                    var candidate = minimal
                    candidate.blocks[index].text = (text as NSString).replacingCharacters(in: NSRange(location: offset, length: length), with: "")
                    candidate.blocks[index].marks = candidate.blocks[index].marks.compactMap { mark in
                        var copy = mark
                        let end = mark.offset + mark.length
                        copy.offset = mark.offset > offset ? max(offset, mark.offset - length) : mark.offset
                        let newEnd = end > offset ? max(offset, end - length) : end
                        copy.length = newEnd - copy.offset
                        return copy.length > 0 ? copy : nil
                    }
                    if try mismatch(candidate) { minimal = candidate; changed = true; break }
                    offset += length
                }
                if changed { break }
            }
        }
        return minimal
    }

    func testGeneratedMarkdownAndSaveReopen() throws {
        let seeds = Int(ProcessInfo.processInfo.environment["ATTIC_FX3_SEEDS"] ?? "2048") ?? 2048
        for seed in 0..<seeds {
            try autoreleasepool {
                let document = generated(seed)
                let bytes: Data
                do { bytes = try NoteContentCodec.encode(document) }
                catch { print("FX3 INVALID SOURCE seed=\(seed) \(document)"); throw error }
                guard case let .editable(reopened) = NoteContentCodec.decode(bytes) else { return XCTFail("seed=\(seed): decode") }
                XCTAssertEqual(try NoteContentCodec.encode(NoteEditorEngine(noteID: UUID(), document: reopened).document()), bytes, "seed=\(seed): reopen")
                if try mismatch(document) {
                    let minimal = try shrink(document)
                    print("FX3 SHRUNK seed=\(seed) source=\(String(decoding: try NoteContentCodec.encode(minimal), as: UTF8.self))")
                    print("FX3 MARKDOWN \(NoteMarkdownExport.markdown(minimal).debugDescription)")
                    print("FX3 ACTUAL \(String(decoding: try NoteContentCodec.encode(pastedMarkdown(minimal)), as: UTF8.self))")
                    XCTFail("seed=\(seed): Markdown semantic mismatch; minimized case in log")
                }
            }
            if !testRun!.hasSucceeded && testRun!.failureCount > 0 { return }
        }
        print("FX3 Markdown/save-reopen seeds=\(seeds)")
    }
}

@MainActor
extension RoundFX3Tests {
    private func nativeSource(_ seed: Int, document: NoteDocument? = nil, attachments: Bool, filePayloads: Bool = true) throws -> NSAttributedString {
        let document = document ?? generated(seed)
        let result = NSMutableAttributedString()
        let font = NSFont(name: "Helvetica", size: 13)!
        var lists: [NSTextList] = []
        func append(_ text: String, block: NoteBlock, paragraph: NSParagraphStyle) {
            let part = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
            for index in 0..<part.length {
                let marks = block.marks.filter { $0.offset <= index && index < $0.offset + $0.length }
                var activeFont = block.style == "mono" || marks.contains { $0.kind == .code } ? NSFont(name: "Menlo", size: 13)! : font
                if marks.contains(where: { $0.kind == .bold }) { activeFont = NSFontManager.shared.convert(activeFont, toHaveTrait: .boldFontMask) }
                if marks.contains(where: { $0.kind == .italic }) { activeFont = NSFontManager.shared.convert(activeFont, toHaveTrait: .italicFontMask) }
                let range = NSRange(location: index, length: 1)
                part.addAttribute(.font, value: activeFont, range: range)
                for mark in marks {
                    switch mark.kind {
                    case .underline: part.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    case .strikethrough: part.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    case .highlight: part.addAttribute(.backgroundColor, value: NoteTextStyle().highlightColor(for: mark.colour), range: range)
                    case .link: part.addAttribute(.link, value: URL(string: mark.url!)!, range: range)
                    default: break
                    }
                }
            }
            result.append(part)
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        for block in document.blocks.dropFirst(seed % 7 == 0 ? 0 : 1) {
            let paragraph = NSMutableParagraphStyle()
            if block.style == "heading" { paragraph.headerLevel = block.level ?? 2 }
            if block.style == "quote" { paragraph.headIndent = 24; paragraph.firstLineHeadIndent = 24 }
            if block.kind == .checklist || ["bullet", "number"].contains(block.style ?? "") {
                let depth = block.indent ?? 0
                let format: NSTextList.MarkerFormat = block.style == "number" ? .decimal : .disc
                if lists.count > depth { lists = Array(lists.prefix(depth)) }
                while lists.count <= depth {
                    let list = NSTextList(markerFormat: format, options: 0)
                    list.startingItemNumber = block.start ?? 1; lists.append(list)
                }
                paragraph.textLists = lists
            } else { lists = [] }
            switch block.kind {
            case .table:
                let source = block.table!, table = NSTextTable(); table.numberOfColumns = source.columnCount
                for row in source.rows.indices {
                    for column in source.columns.indices {
                        let p = NSMutableParagraphStyle()
                        p.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)]
                        p.alignment = source.columns[column].align == .center ? .center : (source.columns[column].align == .right ? .right : .left)
                        let cell = source.rows[row].cells[column]
                        // A cell's physical newlines are native line separators;
                        // its final newline terminates the native cell paragraph.
                        var b = cell.block; b.text = b.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                        append(b.text, block: b, paragraph: p)
                    }
                }
            case .image where attachments, .file where attachments && filePayloads:
                let bytes = block.kind == .image ? try png() : Data("payload".utf8)
                let wrapper = FileWrapper(regularFileWithContents: bytes)
                wrapper.preferredFilename = block.kind == .image ? "image.png" : "notes.txt"
                result.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            case .image: append("[image: image]", block: .text(""), paragraph: paragraph)
            case .file: append("[file: notes.txt]", block: .text(""), paragraph: paragraph)
            case .divider: append("---", block: .text(""), paragraph: paragraph)
            default:
                var visible = block
                let prefix = block.kind == .checklist ? (block.checked ? "[x] " : "[ ] ") : (block.callout.map { $0.isEmpty ? "" : $0 + " " } ?? "")
                visible.text = prefix + block.text
                for index in visible.marks.indices { visible.marks[index].offset += prefix.utf16.count }
                append(visible.text, block: visible, paragraph: paragraph)
            }
        }
        return result
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// Native attributes are an independent observable oracle. Paragraph
    /// separators and block-object boundaries are checked separately below.
    private func normalizedNative(_ source: NSAttributedString) -> NSAttributedString {
        let normalized = NSMutableAttributedString(attributedString: source)
        let original = source.string as NSString
        var removals: [NSRange] = [], location = 0
        while location < source.length {
            let range = original.paragraphRange(for: NSRange(location: location, length: 0))
            let lists = (source.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
            if !lists.isEmpty, original.substring(with: range).hasPrefix("\t") {
                let tail = NSRange(location: location + 1, length: range.length - 1)
                let tab = original.range(of: "\t", range: tail)
                if tab.location != NSNotFound { removals.append(NSRange(location: location, length: NSMaxRange(tab) - location)) }
            }
            location = NSMaxRange(range)
        }
        for range in removals.reversed() { normalized.deleteCharacters(in: range) }
        return normalized
    }

    private func nativeCharacters(_ original: NSAttributedString) -> [String] {
        let source = normalizedNative(original)
        let string = source.string as NSString
        return (0..<source.length).compactMap { index in
            let unit = string.character(at: index)
            guard unit != 10 && unit != 13 && unit != NoteDocument.objectUnit else { return nil }
            let attrs = source.attributes(at: index, effectiveRange: nil)
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var marks: [String] = []
            if traits.contains(.bold) { marks.append("bold") }
            if traits.contains(.italic) { marks.append("italic") }
            if traits.contains(.monoSpace) { marks.append("code") }
            if (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { marks.append("underline") }
            if (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { marks.append("strikethrough") }
            if let background = attrs[.backgroundColor] as? NSColor, background.alphaComponent > 0 { marks.append("highlight") }
            if let link = attrs[.link] { marks.append("link:" + ((link as? URL)?.absoluteString ?? String(describing: link))) }
            return "\(unit):" + marks.sorted().joined(separator: ",")
        }
    }

    private func documentCharacters(_ document: NoteDocument) -> [String] {
        document.blocks.flatMap { block -> [String] in
            if let table = block.table {
                return table.rows.flatMap { $0.cells.flatMap {
                    var block = $0.block; block.text = block.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    return documentCharacters(NoteDocument(blocks: [block]))
                } }
            }
            let text = block.text as NSString
            return (0..<text.length).compactMap { index in
                let unit = text.character(at: index)
                guard unit != 10 && unit != 13 else { return nil }
                let marks = block.marks.filter { $0.offset <= index && index < $0.offset + $0.length }.map {
                    $0.kind == .link ? "link:" + ($0.url ?? "") : $0.kind.rawValue
                }
                return "\(unit):" + marks.sorted().joined(separator: ",")
            }
        }
    }

    private func nativeFlow(_ original: NSAttributedString) -> [String] {
        let source = normalizedNative(original), string = source.string as NSString
        var result: [String] = [], tables = Set<ObjectIdentifier>(), at = 0
        while at < source.length {
            let range = string.paragraphRange(for: NSRange(location: at, length: 0))
            let paragraph = source.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            if let cell = paragraph?.textBlocks.last as? NSTextTableBlock {
                if tables.insert(ObjectIdentifier(cell.table)).inserted { result.append("table") }
            } else {
                var text = string.substring(with: range)
                if text.hasSuffix("\n") { text.removeLast() }
                var kind = "body"
                if let list = paragraph?.textLists.last {
                    kind = (list.markerFormat.rawValue.contains("decimal") ? "number" : "bullet") + String((paragraph?.textLists.count ?? 1) - 1)
                } else if let level = paragraph?.headerLevel, level > 0 { kind = "heading" + String(level) }
                else if (paragraph?.headIndent ?? 0) > 0 { kind = "quote" }
                result.append(text == String(NoteDocument.objectCharacter) ? "object" : kind + ":" + text)
            }
            at = NSMaxRange(range)
        }
        if source.string.hasSuffix("\n") { result.append("body:") }
        return result
    }

    private func documentFlow(_ document: NoteDocument) -> [String] {
        document.blocks.map { block in
            if block.kind == .table { return "table" }
            if block.kind == .image || block.kind == .file { return "object" }
            var kind = "body"
            if block.style == "heading" { kind = "heading" + String(block.level ?? 2) }
            else if ["number", "bullet"].contains(block.style ?? "") { kind = block.style! + String(block.indent ?? 0) }
            else if block.style == "quote" { kind = "quote" }
            return kind + ":" + block.text
        }
    }

    func testGeneratedNativeHTMLRTFAndRTFD() throws {
        let count = Int(ProcessInfo.processInfo.environment["ATTIC_FX3_SEEDS"] ?? "2048") ?? 2048
        for seed in 0..<count {
            let document = generated(seed)
            for type: NSAttributedString.DocumentType in [.html, .rtf, .rtfd] {
                try autoreleasepool {
                    let source = try nativeSource(seed, document: document, attachments: type != .rtf, filePayloads: type == .rtfd)
                    var bytes = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: type])
                    if type == .html {
                        // AppKit writes file:///image.png references. Package
                        // its owned PNG bytes inline for self-contained HTML;
                        // preserve all of the native writer's other markup.
                        let html = NSMutableString(string: String(decoding: bytes, as: UTF8.self))
                        let regex = try NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="([^"]*)"[^>]*>"#)
                        let matches = regex.matches(in: html as String, range: NSRange(location: 0, length: html.length))
                        XCTAssertEqual(matches.count, document.blocks.filter { $0.kind == .image }.count)
                        let address = "data:image/png;base64," + (try png()).base64EncodedString()
                        for match in matches.reversed() { html.replaceCharacters(in: match.range(at: 1), with: address) }
                        bytes = Data((html as String).utf8)
                    }
                    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                    let pasteType: NSPasteboard.PasteboardType = type == .html ? .html : (type == .rtf ? .rtf : .rtfd)
                    board.setData(bytes, forType: pasteType)
                    let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
                    let (_, view) = target.makeView(); defer { target.detachView() }
                    view.setSelectedRange(NSRange(location: 6, length: 0))
                    XCTAssertTrue(view.readSelection(from: board, type: pasteType))
                    var got = target.document(); got.blocks.removeFirst()
                    // The native writer can itself broaden decorations at a
                    // link boundary. Compare the encoded clipboard's native
                    // interpretation, independently of Attic's sanitizer.
                    let native: NSAttributedString
                    if type == .rtfd { native = try XCTUnwrap(NSAttributedString(rtfd: bytes, documentAttributes: nil)) }
                    else if type == .rtf { native = try XCTUnwrap(NSAttributedString(rtf: bytes, documentAttributes: nil)) }
                    else { native = try NSAttributedString(data: bytes, options: [.documentType: type], documentAttributes: nil) }
                    let expected = nativeCharacters(native), actual = documentCharacters(got)
                    if expected != actual {
                        print("FX3 RICH seed=\(seed) type=\(type.rawValue) expected=\(expected) actual=\(actual)")
                        if type == .html { print("FX3 HTML \(String(decoding: bytes, as: UTF8.self))") }
                        XCTFail("seed=\(seed) type=\(type): native content/mark loss")
                    }
                    XCTAssertEqual(documentFlow(got), nativeFlow(native), "seed=\(seed) type=\(type): ordered block boundaries and styles")
                    let tables = got.blocks.compactMap(\.table)
                    let tableCount = document.blocks.compactMap(\.table).count
                    XCTAssertEqual(tables.count, tableCount, "seed=\(seed) type=\(type): native table structure")
                    XCTAssertEqual(tables.map(\.rowCount), Array(repeating: 2, count: tableCount))
                    XCTAssertEqual(tables.map(\.columnCount), Array(repeating: 2, count: tableCount))
                    XCTAssertEqual(tables.map { $0.columns.map(\.align) }, document.blocks.compactMap(\.table).map { $0.columns.map(\.align) })
                    XCTAssertEqual(got.blocks.count, native.string.filter { $0 == "\n" }.count + 1 - 3 * tableCount,
                                   "seed=\(seed) type=\(type): paragraphs and empty paragraphs")
                    var headers = 0, lists = 0, at = 0
                    let nativeText = native.string as NSString
                    while at < native.length {
                        let p = native.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                        if (p?.headerLevel ?? 0) > 0 { headers += 1 }
                        if p?.textLists.isEmpty == false { lists += 1 }
                        at = NSMaxRange(nativeText.paragraphRange(for: NSRange(location: at, length: 0)))
                    }
                    XCTAssertEqual(got.blocks.filter { $0.style == "heading" }.count, headers)
                    XCTAssertEqual(got.blocks.filter { $0.style == "bullet" || $0.style == "number" }.count, lists)
                    if type == .rtfd || type == .html {
                        let expectedBytes = try document.blocks.filter { $0.kind == .image || ($0.kind == .file && type == .rtfd) }.map { block in
                            block.kind == .image ? try png() : Data("payload".utf8)
                        }
                        XCTAssertEqual(target.stagedAttachments(for: got).map(\.data), expectedBytes)
                    }
                }
                if testRun!.failureCount > 0 { return }
            }
            if seed % 512 == 0 { print("FX3 native progress seed=\(seed)") }
        }
        print("FX3 native HTML/RTF/RTFD seeds=\(count)")
    }
}

@MainActor
extension RoundFX3Tests {
    private func assertMarkdown(_ blocks: [NoteBlock], file: StaticString = #filePath, line: UInt = #line) throws {
        let document = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title")] + blocks)).document()
        XCTAssertEqual(try signature(pastedMarkdown(document)), try signature(markdownProjection(document)), file: file, line: line)
    }

    func testShrunkMixedHTMLTableCellSpans() throws {
        var table = NoteTable(texts: [["a\\|b", "a\nb"]], headerRow: false)
        table.rows[0].cells[0].marks = [NoteMark(.underline, offset: 0, length: 4)]
        table.rows[0].cells[1].marks = [NoteMark(.link, offset: 2, length: 1, url: "https://example.invalid/"), NoteMark(.underline, offset: 2, length: 1)]
        try assertMarkdown([.table(table)])
    }

    func testShrunkOrphanNestingChecklistChildrenAndRestarts() throws {
        for kind in ["bullet", "number", "checklist"] {
            for depth in [1, 2] {
                var parent = kind == "checklist" ? NoteBlock.checklist("", checked: true) : .text("", style: kind)
                parent.indent = depth
                if kind == "number" { parent.start = 7 }
                try assertMarkdown([parent])
                var child = NoteBlock.text("", style: "number"); child.start = 12; child.indent = min(2, depth + 1)
                try assertMarkdown([parent, child])
            }
        }
        var first = NoteBlock.text("first", style: "number"); first.start = 7
        var restart = NoteBlock.text("again", style: "number"); restart.start = 12
        try assertMarkdown([first, restart])
    }

    func testShrunkSoftBreakAtParagraphEdges() throws {
        for text in ["\u{2028}", "\u{2028}a", "a\u{2028}", "\u{2028}\u{2028}"] {
            try assertMarkdown([.text(text)])
        }
    }

    func testEveryMarkAloneAndEveryOverlappingPairInBodyAndCells() throws {
        for first in NoteMark.Kind.allCases {
            for second in NoteMark.Kind.allCases where first != second {
                var block = NoteBlock.text(" abc ")
                block.marks = [NoteMark(first, offset: 0, length: 3, url: first == .link ? "https://example.invalid/" : nil),
                               NoteMark(second, offset: 2, length: 3, url: second == .link ? "https://example.invalid/" : nil)]
                var table = NoteTable(texts: [[block.text]])
                table.rows[0].cells[0].marks = block.marks
                try assertMarkdown([block, .table(table)])
            }
            for text in ["word", " word ", "   ", "`x`", "<u>x</u> ==x== &amp;", "a\u{2028}b"] {
                var block = NoteBlock.text(text)
                block.marks = [NoteMark(first, offset: 0, length: text.utf16.count, url: first == .link ? "https://example.invalid/" : nil)]
                var table = NoteTable(texts: [[text]])
                table.rows[0].cells[0].marks = block.marks
                try assertMarkdown([block, .table(table)])
            }
        }
    }

    func testEscapedAndCodeExtensionsRemainLiteral() throws {
        for text in ["<u>x</u>", "==x==", "<mark>x</mark>", "<!-- attic:list indent=2 -->", "<br>", "<!-- attic:table headerRow=false -->"] {
            try assertMarkdown([.text(text)])
            var code = NoteBlock.text(text, style: "mono"); code.language = "swift"
            try assertMarkdown([code])
        }
    }

    func testOrdinaryMarkdownBytesStayIdentical() {
        var bold = NoteBlock.text("A bold word"); bold.marks = [NoteMark(.bold, offset: 2, length: 4)]
        var number = NoteBlock.text("Seven", style: "number"); number.start = 7
        var callout = NoteBlock.text("Text", style: "quote"); callout.callout = "💡"
        let document = NoteDocument(blocks: [.text("Title"), .text("one  two"), bold, number, .text("Eight", style: "number"),
            .text("Quote", style: "quote"), callout, .table(NoteTable(texts: [["A", "B"], ["C", "D"]])), .divider()])
        XCTAssertEqual(NoteMarkdownExport.markdown(document), "# Title\n\none  two\n\nA **bold** word\n\n7. Seven\n8. Eight\n\n> Quote\n\n> [!NOTE]\n> 💡 Text\n\n| A | B |\n| --- | --- |\n| C | D |\n\n---")
        XCTAssertEqual(NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("   "), .text("body")])), "body")
    }
}

@MainActor
extension RoundFX3Tests {
    func testGeneratedStoreSaveAndFreshContextReopen() throws {
        let count = Int(ProcessInfo.processInfo.environment["ATTIC_FX3_SEEDS"] ?? "2048") ?? 2048
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let image = try png()
        for seed in 0..<count {
            try autoreleasepool {
                let document = generated(seed), expected = try NoteContentCodec.encode(document), id = UUID()
                let staged = document.blocks.compactMap { block -> StagedNoteAttachment? in
                    guard let attachmentID = block.attachmentID else { return nil }
                    let bytes = block.kind == .image ? image : Data("payload".utf8)
                    return StagedNoteAttachment(id: attachmentID, filename: block.kind == .image ? "image.png" : "notes.txt",
                        contentTypeIdentifier: block.kind == .image ? "public.png" : "public.plain-text",
                        byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
                }
                guard case .success = store.createDocumentNote(id: id, document: document, staged: staged) else { return XCTFail("seed=\(seed): save") }
                let context = ModelContext(store.modelContext.container)
                let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                let saved = try XCTUnwrap(rows.first?.content)
                XCTAssertEqual(saved, expected, "seed=\(seed): stored bytes")
                guard case let .editable(reopened) = NoteContentCodec.decode(saved) else { return XCTFail("reopen") }
                XCTAssertEqual(try NoteContentCodec.encode(NoteEditorEngine(noteID: id, document: reopened).document()), expected,
                               "seed=\(seed): fresh context and engine")
            }
        }
        print("FX3 store/fresh-context seeds=\(count)")
    }

    func testShrunkStructuralMarkersAfterSoftBreakStayInvisible() throws {
        var callout = NoteBlock.text("", style: "quote"); callout.callout = "💡"; callout.calloutStart = true
        var task = NoteBlock.checklist("", checked: true); task.indent = 1
        var after = NoteBlock.text(" d"); after.marks = [NoteMark(.underline, offset: 1, length: 1)]
        try assertMarkdown([.text("a\u{2028}b"), callout, task, after])
    }
}

@MainActor
extension RoundFX3Tests {
    private func compatibilityDocument(_ seed: Int) -> NoteDocument {
        var bold = NoteBlock.text("A bold word \(seed)"); bold.marks = [NoteMark(.bold, offset: 2, length: 4)]
        var first = NoteBlock.text("First", style: "number"); first.start = 7
        var heading = NoteBlock.text("Heading \(seed)", style: "heading"); heading.level = seed % 6 + 1
        var callout = NoteBlock.text("Callout \(seed)", style: "quote"); callout.callout = "💡"; callout.calloutStart = seed % 2 == 0
        var continued = callout; continued.text = "Continued"; continued.calloutStart = false
        var code = NoteBlock.text("let n = \(seed)", style: "mono"); code.language = "swift"
        let table = NoteTable(texts: [["A", "B"], ["C\(seed)", "D"]], headerRow: seed % 2 == 0, alignments: [.left, .center])
        return NoteDocument(blocks: [.text("Title \(seed)"), .text("one  two & <literal> https://example.invalid/"), bold, heading,
            .text("Quote", style: "quote"), callout, continued, code, .text("One", style: "bullet"), .text("Two", style: "bullet"),
            first, .text("Next", style: "number"), .checklist("Task", checked: seed % 2 == 0), .table(table),
            .image(attachmentID: UUID()), .file(attachmentID: UUID(), filename: "notes.txt", contentTypeIdentifier: "public.plain-text", byteCount: 7), .divider()])
    }

    func testOrdinaryCorpusMatchesPreFX3Bytes() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/FX3MarkdownCompatibility.json")
        let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        XCTAssertEqual(expected.count, 128)
        for seed in expected.indices {
            XCTAssertEqual(NoteMarkdownExport.markdown(compatibilityDocument(seed), locale: Locale(identifier: "en_US_POSIX"), filename: { _ in "image" }), expected[seed], "seed=\(seed): legacy export bytes")
        }
    }

    func testShrunkLiteralEmojiInNoIconCalloutsWithEveryMark() throws {
        for kind in NoteMark.Kind.allCases {
            var block = NoteBlock.text("👩🏽‍💻", style: "quote"); block.callout = ""
            block.marks = [NoteMark(kind, offset: 0, length: block.text.utf16.count, url: kind == .link ? "https://example.invalid/" : nil)]
            try assertMarkdown([block])
        }
    }

    func testShrunkCodeCellBreakMarkupAndBackslashesRemainLiteral() throws {
        for value in ["<br>", "`x`", "a\\|b", "&amp;", "<u>x</u>"] {
            var table = NoteTable(texts: [[value]])
            table.rows[0].cells[0].marks = [NoteMark(.code, offset: 0, length: value.utf16.count)]
            let direct = try XCTUnwrap(NoteTableText.parseMarkdown(NoteTableText.markdown(table) { NoteMarkdownExport.inlineMarkdown($0.block) }))
            XCTAssertEqual(direct.rows[0].cells[0].text, value)
            XCTAssertEqual(direct.rows[0].cells[0].marks, table.rows[0].cells[0].marks)
            try assertMarkdown([.table(table)])
        }
    }

    func testShrunkPunctuationMarkAndHeadingSoftBreak() throws {
        var block = NoteBlock.text("<p", style: "heading"); block.level = 2; block.marks = [NoteMark(.bold, offset: 0, length: 1)]
        var heading = NoteBlock.text("a\u{2028}b", style: "heading"); heading.level = 2
        try assertMarkdown([block, heading])
    }

    func testShrunkLargeStartsAndDepthTransitions() throws {
        for start in [1_000_000_000, Int.max] {
            var a = NoteBlock.text("", style: "number"); a.start = start; a.indent = 1
            var b = NoteBlock.text("", style: "number"); b.start = 12
            try assertMarkdown([a, b, .text("continued", style: "number")])
        }
    }

    func testMalformedAndEscapedExtensionsNeverLeakTokens() throws {
        for source in ["<!-- attic:list indent=2 -->", "\\<br>", "\\<u>x</u>", "\\&#32;", "<u>broken", "`<mark>x</mark>`", "    <u>x</u>"] {
            let read = try NoteMarkdownImport.document(source)
            XCTAssertFalse(read.blocks.map(\.text).joined().contains("atticSpan"))
            XCTAssertFalse(read.blocks.map(\.text).joined().contains("atticList"))
        }
        XCTAssertEqual(try NoteMarkdownImport.document("\\<br>").blocks.map(\.text), ["<br>"])
        XCTAssertEqual(try NoteMarkdownImport.document("\\&#32;").blocks.map(\.text), ["&#32;"])
    }

    func testSingleHTMLTableKeepsMarksAndMixedFlavorCannotClaimPartialTable() throws {
        let html = "<table><tr><td><b>A</b><br><u>B</u></td><td>C</td></tr></table>"
        let table = try XCTUnwrap(NoteTablePaste.table(fromHTML: html))
        XCTAssertEqual(table.texts, [["A\nB", "C"]])
        let wrapped = try XCTUnwrap(NoteTablePaste.table(fromHTML: "<div>" + html + "</div>"))
        XCTAssertEqual(wrapped.texts, table.texts)
        XCTAssertEqual(wrapped.rows.map { $0.cells.map(\.marks) }, table.rows.map { $0.cells.map(\.marks) })
        XCTAssertEqual(table.rows[0].cells[0].marks, [NoteMark(.bold, offset: 0, length: 1), NoteMark(.underline, offset: 2, length: 1)])
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(html + "<p>After</p>", forType: .html)
        board.setString("A\tC\nB\tD", forType: .string)
        XCTAssertNil(NoteTablePaste.table(from: board))
        let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = target.makeView(); defer { target.detachView() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .html))
        XCTAssertTrue(target.plainText.contains("After"))
    }

    func testAllMarkSubsetsAcrossCrossingRanges() throws {
        for mask in 1..<(1 << NoteMark.Kind.allCases.count) {
            var block = NoteBlock.text(" abcdef ")
            for (index, kind) in NoteMark.Kind.allCases.enumerated() where mask & (1 << index) != 0 {
                block.marks.append(NoteMark(kind, offset: index % 3, length: 5, url: kind == .link ? "https://example.invalid/" : nil,
                    colour: kind == .highlight ? "purple" : nil))
            }
            var table = NoteTable(texts: [[block.text]]); table.rows[0].cells[0].marks = block.marks
            try assertMarkdown([block, .table(table)])
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testHTMLTableDoesNotEatEmptyOutsideParagraphs() throws {
        let html = "<p><br></p><table><tr><td>A</td><td>B</td></tr></table><p><br></p>"
        XCTAssertNil(NoteTablePaste.table(fromHTML: html))
        let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = target.makeView(); defer { target.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(html, forType: .html); view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .html))
        XCTAssertEqual(target.document().blocks.dropFirst().map(\.kind), [.text, .table, .text, .text])
    }

    func testMalformedPairedHTMLRemainsLiteralWithoutRescanning() throws {
        let text = String(repeating: "<u>", count: 4_000)
        let read = try NoteMarkdownImport.document(text)
        XCTAssertEqual(read.blocks.map(\.text).joined().trimmingCharacters(in: .newlines), text)
        for source in ["<a>word</a>", "<mark data-attic-colour=\"\">word</mark>"] {
            let target = NoteEditorEngine(noteID: UUID(), document: try NoteMarkdownImport.document(source))
            XCTAssertNoThrow(try NoteContentCodec.encode(target.document()))
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testNestedSameKindInlineHTMLProducesCanonicalEditableMarks() throws {
        for source in ["<strong><strong>x</strong></strong>", "**<strong>x</strong>**"] {
            let doc = try NoteMarkdownImport.document(source)
            XCTAssertEqual(doc.blocks.map(\.text), ["x"])
            XCTAssertEqual(doc.blocks[0].marks, [NoteMark(.bold, offset: 0, length: 1)])
            XCTAssertTrue(NoteContentCodec.decode(try NoteContentCodec.encode(doc)).isEditable)
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testTrailingEmptyPasteUndoRedoKeepsFullParagraphState() throws {
        for format: NoteParagraphStyle in [.body, .heading(1), .heading(2), .heading(3), .heading(4), .heading(5), .heading(6), .quote, .callout(icon: "💡"), .mono(language: "swift"), .bullet, .number, .checklist] {
            let source = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
            if format != .body { XCTAssertTrue(source.perform(.paragraph(format), selection: NSRange(location: 6, length: 0))) }
            let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
            let (_, view) = target.makeView(); defer { target.detachView() }
            view.setSelectedRange(NSRange(location: 7, length: 0))
            let before = try NoteContentCodec.encode(target.document())
            XCTAssertTrue(target.pasteMarkdown(NoteMarkdownExport.markdown(source.document()), at: view.selectedRange()))
            XCTAssertEqual(target.document().blocks.last?.style, source.document().blocks.last?.style)
            XCTAssertEqual(target.document().blocks.last?.level, source.document().blocks.last?.level)
            XCTAssertEqual(target.document().blocks.last?.kind, source.document().blocks.last?.kind)
            let after = try NoteContentCodec.encode(target.document())
            XCTAssertTrue(target.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(target.document()), before)
            XCTAssertTrue(target.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(target.document()), after)
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testShrunkRTFLeadingTabDoesNotBecomeAnUnstyledTable() throws {
        let source = NSAttributedString(string: "\tA", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let bytes = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(bytes, forType: .rtf)
        let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
        let (_, view) = target.makeView(); defer { target.detachView() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .rtf))
        XCTAssertEqual(target.document().blocks.dropFirst().map(\.kind), [.text])
        XCTAssertEqual(target.document().blocks.last?.text, "\tA")
        XCTAssertEqual(target.document().blocks.last?.marks, [NoteMark(.bold, offset: 0, length: 2)])
    }

    func testUnmatchedTableCodeFencesStayLiteral() throws {
        for text in ["``x`", "`x``", "```x``", "``<u>x</u>`"] {
            let cell = NoteTableText.inlineCell(text)
            // An unmatched opener is literal; valid inline markup after it
            // remains active because no code span was actually opened.
            XCTAssertEqual(cell.text, text.contains("<u>") ? "``x`" : text)
            XCTAssertEqual(cell.marks, text.contains("<u>") ? [NoteMark(.underline, offset: 2, length: 1)] : [])
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testReservedOnlyAndOversizedMarkdownNeverExposeParseAtoms() throws {
        let boundary = try NoteMarkdownImport.document("<!-- attic:callout-start -->")
        XCTAssertEqual(boundary.blocks.map(\.text), [""])
        let source = "| H |\n| --- |\n" + Array(repeating: "| <u>x</u> |", count: NoteTable.maxRows).joined(separator: "\n")
        let oversized = try NoteMarkdownImport.document(source)
        let text = oversized.blocks.map(\.text).joined(separator: "\n")
        for token in ["atticSpan", "atticTable", "atticList"] { XCTAssertFalse(text.contains(token)) }
        XCTAssertEqual(text.filter { $0 == "x" }.count, NoteTable.maxRows)
        XCTAssertTrue(oversized.blocks.allSatisfy { $0.kind == .text })
    }

    func testMinimizedNativeMonoFontAndEmptyHeadingSurviveHTML() throws {
        for empty in [false, true] {
            let paragraph = NSMutableParagraphStyle(); paragraph.headerLevel = empty ? 2 : 0
            let source = NSAttributedString(string: empty ? "\n" : "M", attributes: [
                .font: empty ? NSFont.systemFont(ofSize: 13) : NSFont(name: "Menlo", size: 13)!, .paragraphStyle: paragraph])
            let bytes = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
            let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
            XCTAssertTrue(target.pasteRichText(bytes, type: .html, at: NSRange(location: 6, length: 0)))
            let first = try XCTUnwrap(target.document().blocks.dropFirst().first)
            XCTAssertEqual(first.text, empty ? "" : "M")
            if empty { XCTAssertEqual(first.style, "heading"); XCTAssertEqual(first.level, 2) }
            else { XCTAssertEqual(first.marks, [NoteMark(.code, offset: 0, length: 1)]) }
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testNativeHTMLDistinguishesEmptyAndLiteralSoftBreakParagraphs() throws {
        for level in -1...6 {
            for value in ["", "\u{2028}", "\u{2028}\u{2028}", "a\u{2028}", "\u{2028}a"] {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headerLevel = max(0, level)
                if level == -1 { paragraph.headIndent = 24; paragraph.firstLineHeadIndent = 24 }
                let source = NSAttributedString(string: value + "\n", attributes: [.font: NSFont(name: "Helvetica", size: 13)!, .paragraphStyle: paragraph])
                let bytes = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
                let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]))
                XCTAssertTrue(target.pasteRichText(bytes, type: .html, at: NSRange(location: 6, length: 0)))
                let first = try XCTUnwrap(target.document().blocks.dropFirst().first)
                XCTAssertEqual(first.text, value, "level=\(level), \(value.debugDescription)")
                XCTAssertEqual(first.style, level > 0 ? "heading" : (level == -1 ? "quote" : nil))
                XCTAssertEqual(first.level, level > 0 ? level : nil)
            }
        }
    }
}

@MainActor
extension RoundFX3Tests {
    func testNativePaletteHighlightsRetainTheirColour() throws {
        let pairs: [(NoteTextStyle, NoteTextStyle)] = [
            (NoteTextStyle(), NoteTextStyle()),
            (NoteTextStyle(design: AtticDesignContext(mode: .light)), NoteTextStyle(design: AtticDesignContext(mode: .dark))),
            (NoteTextStyle(design: AtticDesignContext(mode: .dark)), NoteTextStyle(design: AtticDesignContext(mode: .light)))
        ]
        for (style, destination) in pairs {
            for colour in NoteHighlightColour.allCases {
                for type: NSAttributedString.DocumentType in [.html, .rtf, .rtfd] {
                    let source = NSAttributedString(string: "H", attributes: [.font: NSFont(name: "Helvetica", size: 13)!,
                        .backgroundColor: style.highlightColor(for: colour.rawValue)])
                    let bytes = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: type])
                    let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("")]), design: destination.design)
                    let pasteType: NSPasteboard.PasteboardType = type == .html ? .html : (type == .rtf ? .rtf : .rtfd)
                    XCTAssertTrue(target.pasteRichText(bytes, type: pasteType, at: NSRange(location: 6, length: 0)))
                    let mark = try XCTUnwrap(target.document().blocks.dropFirst().first?.marks.first { $0.kind == .highlight })
                    XCTAssertEqual(mark.colour, colour == .yellow ? nil : colour.rawValue, "\(type) \(colour)")
                }
            }
        }
    }
}

@MainActor
extension RoundFX3Tests {
    /// External Markdown has an independent content oracle: these inputs never
    /// pass through Attic's exporter before import. Each seed carries distinct
    /// payloads so a dropped/duplicated block or cell cannot hide in a count.
    func testGeneratedExternalMarkdownKeepsEveryPayloadWithoutMarkers() throws {
        let count = Int(ProcessInfo.processInfo.environment["ATTIC_FX3_SEEDS"] ?? "2048") ?? 2048
        for seed in 0..<count {
            try autoreleasepool {
                var rng = RNG(state: UInt64(seed) &+ 0x4D4431)
                let literal = ["<u>x\(seed)</u>", "&#65;", "<br>", "| literal\(seed) |", "<img src=\"https://example.invalid/never\(seed)\">"][rng.next(5)]
                let marker = ["-", "+", "*"][rng.next(3)]
                let tick = String(repeating: "`", count: 3 + rng.next(3))
                let checked = rng.next(2) == 0
                let breaks = 1 + rng.next(4)
                let before = "`before\(seed)", after = "`after\(seed)"
                let address = "www.a\(seed).co a\(seed)@b.co https://example.invalid/plain\(seed)"
                let html = "<section data-test=\"\(seed)\">\n<img src=\"https://example.invalid/image\(seed)\">\nraw &amp; **literal\(seed)**\n</section>"
                let hard = "hard\(seed)" + String(repeating: "\\\n", count: breaks) + "end\(seed)"
                let quoteGrid = rng.next(2) == 0
                let gridLines = [NoteTableText.headerOffComment, "| Nested\(seed) |", "| :---: |", "| \\|<u>Q\(seed)</u><br><code>&amp;</code> |"]
                let nested = quoteGrid ? gridLines.map { "> " + $0 }.joined(separator: "\n") : "- gridparent\(seed)\n\n" + gridLines.map { "  " + $0 }.joined(separator: "\n")
                let source = "# README \(seed)\n\n\(marker) \(tick)html\n  \(literal)\n  \(tick)\n\n\(before)\n| H\(seed) | R\(seed) |\n| :--- | ---: |\n| X\(seed)<br>Y\(seed) | `&amp;` |\n\(after)\n\n\(address)\n\n\(html)\n\n\(nested)\n\n- parent\(seed)\n  - child\(seed)\n    - [\(checked ? "x" : " ")] task\(seed)\n\n\(hard)\n\n<https://example.invalid/explicit\(seed)>"
                let target = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
                let (_, view) = target.makeView(); defer { target.detachView() }
                let initial = try NoteContentCodec.encode(target.document())
                XCTAssertTrue(target.pasteMarkdown(source, at: NSRange(location: 7, length: 0)), "seed=\(seed)")
                let doc = target.document()
                let tables = doc.blocks.compactMap(\.table)
                XCTAssertEqual(tables.count, 2, "seed=\(seed)")
                XCTAssertEqual(tables.first?.texts, [["H\(seed)", "R\(seed)"], ["X\(seed)\nY\(seed)", "&amp;"]], "seed=\(seed)")
                XCTAssertEqual(tables.first?.columns.map(\.align), [.left, .right])
                XCTAssertEqual(tables.first?.rows[1].cells[1].marks, [NoteMark(.code, offset: 0, length: 5)])
                let nestedTable = try XCTUnwrap(tables.last)
                XCTAssertEqual(nestedTable.texts, [["Nested\(seed)"], ["|Q\(seed)\n&"]])
                XCTAssertFalse(nestedTable.headerRow)
                XCTAssertEqual(nestedTable.columns.map(\.align), [.center])
                XCTAssertEqual(nestedTable.rows[1].cells[0].marks, [NoteMark(.code, offset: "Q\(seed)".utf16.count + 2, length: 1), NoteMark(.underline, offset: 1, length: "Q\(seed)".utf16.count)])

                let body = doc.blocks.dropFirst().filter { $0.kind != .table }
                let expected = ["README \(seed)", literal, before, after, address] + html.components(separatedBy: "\n") + (quoteGrid ? [] : ["gridparent\(seed)"]) + ["parent\(seed)", "child\(seed)", "task\(seed)", "hard\(seed)" + String(repeating: "\u{2028}", count: breaks) + "end\(seed)", "https://example.invalid/explicit\(seed)"]
                XCTAssertEqual(body.map(\.text), expected, "seed=\(seed)")
                XCTAssertEqual(body.first { $0.text == literal }?.style, "mono")
                XCTAssertEqual(body.first { $0.text == address }?.marks, [])
                XCTAssertEqual(body.first { $0.text == "child\(seed)" }?.indent, 1)
                XCTAssertEqual(body.first { $0.text == "task\(seed)" }?.kind, .checklist)
                XCTAssertEqual(body.first { $0.text == "task\(seed)" }?.checked, checked)
                XCTAssertEqual(body.last?.marks, [NoteMark(.link, offset: 0, length: expected.last!.utf16.count, url: expected.last!)])
                let bytes = try NoteContentCodec.encode(doc)
                for marker in ["atticTable", "atticSpan", "atticList", "atticEmpty"] {
                    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(marker), "seed=\(seed): \(marker)")
                }
                guard case let .editable(reopened) = NoteContentCodec.decode(bytes) else { return XCTFail("seed=\(seed): decode") }
                XCTAssertEqual(try NoteContentCodec.encode(reopened), bytes)
                XCTAssertTrue(target.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(target.document()), initial)
                XCTAssertTrue(target.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(target.document()), bytes)
            }
            if !testRun!.hasSucceeded && testRun!.failureCount > 0 { return }
        }
        print("MD1 external Markdown seeds=\(count)")
    }

    func testMD1RawHTMLIsInertAndCodeIsLiteral() throws {
        for source in ["<script src=\"https://example.invalid/x\">alert(1)</script>",
                       "<div>\n<u>literal</u> &amp;\n</div>", "<iframe src=\"file:///private/test\"></iframe>"] {
            let doc = try NoteMarkdownImport.document(source)
            XCTAssertEqual(doc.blocks.map(\.text).joined(separator: "\n"), source)
            XCTAssertTrue(doc.blocks.allSatisfy { $0.marks.isEmpty && $0.kind == .text })
        }
        for source in ["<span>literal</span>", "<u data-external=\"yes\">literal</u>"] {
            let doc = try NoteMarkdownImport.document(source)
            XCTAssertEqual(doc.blocks.map(\.text).joined(), source)
            XCTAssertTrue(doc.blocks.allSatisfy { $0.marks.isEmpty })
        }
        let doc = try NoteMarkdownImport.document("- ```html\n  <u>x</u>\n  &#65;\n  <br>\n  ```\n\n`<u>x</u> &#65; <br>`")
        XCTAssertEqual(doc.blocks.map(\.text), ["<u>x</u>", "&#65;", "<br>", "<u>x</u> &#65; <br>"])
        XCTAssertEqual(doc.blocks.last?.marks, [NoteMark(.code, offset: 0, length: 19)])
    }
}

@MainActor
extension RoundFX3Tests {
    func testMD1SourceRangesAndLegacyHighlightExtensions() throws {
        let lines = [NoteTableText.headerOffComment, "| H | R |", "| --- | --- |", "| A<br>B | <u>C</u> |"]
        let quote = lines.map { "> " + $0 }.joined(separator: "\n")
        for source in [quote, "> [!NOTE]\n>\n" + quote, "- parent\n\n" + lines.map { "  " + $0 }.joined(separator: "\n")] {
            let nested = try NoteMarkdownImport.document(source)
            let table = try XCTUnwrap(nested.blocks.compactMap(\.table).first)
            XCTAssertEqual(table.texts, [["H", "R"], ["A\nB", "C"]])
            XCTAssertFalse(table.headerRow)
            XCTAssertEqual(table.rows[1].cells[1].marks, [NoteMark(.underline, offset: 0, length: 1)])
            XCTAssertNoThrow(try NoteContentCodec.encode(NoteDocument(blocks: [.text("Title")] + nested.blocks)))
        }
        let spans = try NoteMarkdownImport.document("| H | R |\n| --- | --- |\n| A | B |\n| ^ | ^ |")
        XCTAssertEqual(spans.blocks.first?.table?.texts, [["H", "R"], ["A", "B"], ["^", "^"]], "GFM has no rowspan syntax; retain literal caret cells")
        let compact = try NoteMarkdownImport.document("|H|R|S|\n|-|-|-|\n|A||C|")
        XCTAssertEqual(compact.blocks.first?.table?.texts, [["H", "R", "S"], ["A", "", "C"]])
        var empty = NoteBlock.text("", style: "bullet"); empty.indent = 1
        try assertMarkdown([.text("parent", style: "bullet"), empty])
        let export = NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("Title"), .text("parent", style: "bullet"), empty]))
        XCTAssertEqual(export, "# Title\n\n- parent\n  - <!-- attic:empty-item -->")
        var child = empty; child.indent = 2
        try assertMarkdown([.checklist(""), empty, child])
        for literal in ["|=", " |", "a|b|c", "👩🏽‍💻|e\u{301}", "\\|<br>"] {
            for offset in 0..<literal.utf16.count where offset == 0 || literal.unicodeScalars.allSatisfy({ $0.isASCII }) {
                var cell = NoteBlock.text(literal)
                cell.marks = [NoteMark(.underline, offset: offset, length: literal.utf16.count - offset)]
                var table = NoteTable(texts: [[literal, literal], [literal, literal]])
                for row in table.rows.indices { for column in table.columns.indices { table.rows[row].cells[column] = .init(literal, marks: cell.marks) } }
                try assertMarkdown([.table(table)])
            }
        }
        for (source, expected) in [("==old==", "old"), ("==a &amp; b==", "a & b")] {
            let doc = try NoteMarkdownImport.document(source)
            XCTAssertEqual(doc.blocks.map(\.text), [expected])
            XCTAssertEqual(doc.blocks[0].marks, [NoteMark(.highlight, offset: 0, length: expected.utf16.count)])
        }
        for source in ["\\=\\=literal\\=\\=", "&#61;&#61;literal&#61;&#61;", "`==literal==`"] {
            let doc = try NoteMarkdownImport.document(source)
            XCTAssertEqual(doc.blocks.map(\.text), ["==literal=="])
            XCTAssertFalse(doc.blocks[0].marks.contains { $0.kind == .highlight })
        }
    }
}
