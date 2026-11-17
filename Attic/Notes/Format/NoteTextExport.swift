import Foundation

/// Text forms of a note for search, the derived `body` column and agents.
enum NoteTextExport {
    /// Search and preview text: the title, then one line per block. Objects
    /// read as `[ ] text`, `[x] text`, `[Image]`; dates as ISO days.
    static func plainText(_ document: NoteDocument) -> String {
        document.blocks.map(plainLine).joined(separator: "\n")
    }

    /// Everything after the title, as plain text (the derived `body` column
    /// for a note stored in the new format, so older readers still show it).
    static func plainBody(_ document: NoteDocument) -> String {
        document.blocks.dropFirst().map(plainLine).joined(separator: "\n")
    }

    static func plainLine(_ block: NoteBlock) -> String {
        switch block.kind {
        case .text:
            if let icon = block.callout, block.style == "quote" {
                return (icon.isEmpty ? "" : icon + " ") + block.displayText
            }
            if block.style == "mono" { return block.displayText }
            let prefix: String = switch block.style {
            case "heading": String(repeating: "#", count: min(6, max(1, block.level ?? 2))) + " "
            case "bullet": "- "
            case "number": "1. "
            case "quote": "> "
            case "mono": "    "
            default: ""
            }
            return String(repeating: "  ", count: min(2, max(0, block.indent ?? 0))) + prefix + block.displayText
        case .checklist: return String(repeating: "  ", count: min(2, max(0, block.indent ?? 0))) + (block.checked ? "[x] " : "[ ] ") + block.displayText
        case .image: return "[Image]"
        case .file: return "[File: \(block.filename ?? "file")]"
        case .divider: return "---"
        case .table: return block.table.map(NoteTableText.tsv) ?? ""
        case .opaque: return "[Unsupported content]"
        }
    }

    // MARK: Agent text

    /// The body as an agent reads and writes it: Markdown-like lines where
    /// every object is addressable, so an agent can keep an image by keeping
    /// its line. Literal text is escaped by `NoteAgentText`'s one rule.
    ///
    /// - checklist: `- [ ] text` / `- [x] text`
    /// - image: `![image](attic://image/<placement id>)`
    /// - unsupported block: `[unsupported content](attic://block/<index>)`
    /// - inline date: `[date:2026-10-01]`
    static func agentBody(_ document: NoteDocument) -> String {
        document.blocks.enumerated().dropFirst().map { index, block in
            agentLine(block, index: index)
        }.joined(separator: "\n")
    }

    static func agentLine(_ block: NoteBlock, index: Int) -> String {
        line(block, index: index, place: .line)
    }

    /// The title line as the update tools default it and compare it: written
    /// as typed (dates as tokens, no escapes), since agents send `title` as
    /// its own field.
    static func agentTitle(_ document: NoteDocument) -> String {
        line(document.blocks.first ?? .text(""), index: 0, place: .typed)
    }

    private static func line(_ block: NoteBlock, index: Int, place: NoteAgentText.Place) -> String {
        switch block.kind {
        case .text:
            var plain = block
            plain.text = agentInlineText(block, in: place)
            plain.inlines = []
            return plainLine(plain)
        case .checklist: return (block.checked ? "- [x] " : "- [ ] ") + agentInlineText(block, in: place)
        case .image: return "![image](attic://image/\(block.id?.uuidString ?? ""))"
        case .file:
            let name = NoteAgentText.write([.text(block.filename ?? "file")], in: place)
            return "[file: \(name)](attic://file/\(block.id?.uuidString ?? ""))"
        case .divider: return "---"
        case .table: return agentTable(block)
        case .opaque: return "[unsupported content](attic://block/\(index))"
        }
    }

    /// A table as agents read and write it: an `attic:table` token line
    /// (its id, and `headerRow=false` when the header row is off), then a
    /// GFM pipe table whose first row is always GFM's header. Cells are
    /// written by `NoteAgentText` (a line break as `<br>`).
    static func agentTable(_ block: NoteBlock) -> String {
        guard let table = block.table else { return "" }
        var token = "<!-- attic:table id=\(block.id?.uuidString ?? "")"
        if !table.headerRow { token += " headerRow=false" }
        token += " -->"
        guard table.isRectangular, !table.rows.isEmpty else { return token + "\n" }
        func row(_ row: NoteTable.Row) -> String {
            "| " + row.cells.map { agentInlineText($0.block, in: .cell) }.joined(separator: " | ") + " |"
        }
        let delimiter = "|" + table.columns.map { column in
            switch column.align {
            case .left: " --- "
            case .center: " :---: "
            case .right: " ---: "
            }
        }.joined(separator: "|") + "|"
        return ([token, row(table.rows[0]), delimiter] + table.rows.dropFirst().map(row)).joined(separator: "\n")
    }

    /// A line's or a cell's text as agents read it: dates as
    /// `[date:YYYY-MM-DD]`, an object this build can't read as
    /// `[unsupported]`, literal text escaped for `place`.
    static func agentInlineText(_ block: NoteBlock, in place: NoteAgentText.Place = .field) -> String {
        NoteAgentText.write(NoteAgentText.pieces(block.text, inlines: block.inlines), in: place)
    }
}

/// The agent text's one escaping rule (spec § 4.6). A backslash before
/// `\`, `[`, `|`, `<`, `&` or white space (a space, a tab, a line break) makes
/// that character literal text; before anything else it is itself
/// (`C:\Users`). The export puts one before every literal `\ [ | <`, before an
/// `&` that would read as an entity, before a line's line break or carriage
/// return, and before a cell's edge white space. Real tokens are never
/// escaped: `[date:YYYY-MM-DD]`, `[unsupported]`, a table's pipes and `<br>`,
/// a checklist's `- [ ] ` and an object's line. Text sent without escapes
/// keeps its old meaning.
enum NoteAgentText {
    /// Literal text, a date, or an object this build can't read.
    enum Piece: Equatable {
        case text(String)
        case date(NoteDay)
        case unsupported
    }

    /// Where the text is written:
    /// - `line`: a body line; a line break continues the line (`\` at its end);
    /// - `cell`: a pipe-table cell; a line break is `<br>`, and `<br>` and
    ///   entities are read as they always were;
    /// - `field`: a cell in a JSON field (`tables`, `set_cell`);
    /// - `typed`: the title, and the composer's text as a person typed it:
    ///   dates only, no escapes.
    enum Place {
        case line, cell, field, typed
    }

    static func pieces(_ text: String, inlines: [NoteInline]) -> [Piece] {
        var result: [Piece] = []
        var literal = ""
        var index = 0
        for character in text {
            if character == NoteDocument.objectCharacter, index < inlines.count {
                if !literal.isEmpty { result.append(.text(literal)); literal = "" }
                switch inlines[index].kind {
                case let .date(day): result.append(.date(day))
                case .opaque: result.append(.unsupported)
                }
                index += 1
            } else {
                literal.append(character)
            }
        }
        if !literal.isEmpty { result.append(.text(literal)) }
        return result
    }

    static func write(_ pieces: [Piece], in place: Place) -> String {
        var output = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case let .date(day): output += "[date:\(day.isoString)]"
            case .unsupported: output += "[unsupported]"
            case let .text(text):
                guard place != .typed else { output += text; continue }
                let characters = Array(text)
                // A cell's edge white space would be trimmed as padding.
                let leading = place == .cell && index == 0 ? characters.prefix(while: isPadding).count : 0
                let trailing = place == .cell && index == pieces.count - 1
                    ? characters.count - characters.reversed().prefix(while: isPadding).count : characters.count
                for (offset, character) in characters.enumerated() {
                    switch character {
                    case "\\", "[", "|", "<": output += "\\" + String(character)
                    case "&" where entity(characters, at: offset) != nil: output += "\\&"
                    case "\n": output += place == .line ? "\\\n" : place == .cell ? "<br>" : "\n"
                    case "\r": output += place == .field ? "\r" : "\\\r"
                    case "\r\n": output += place == .line ? "\\\r\\\n" : place == .cell ? "\\\r<br>" : "\r\n"
                    default:
                        output += offset < leading || offset >= trailing ? "\\" + String(character) : String(character)
                    }
                }
            }
        }
        return output
    }

    /// The other way: escapes undone, tokens read. A literal U+FFFC is
    /// dropped (it would claim an object that isn't there).
    static func read(_ text: String, in place: Place) -> [Piece] {
        var result: [Piece] = []
        var literal = ""
        let characters = Array(text)
        func flush() { if !literal.isEmpty { result.append(.text(literal)); literal = "" } }
        func matches(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= characters.count && Array(characters[index..<(index + token.count)]) == token
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if place != .typed, character == "\\", index + 1 < characters.count, isEscapable(characters[index + 1]) {
                literal.append(characters[index + 1]); index += 2; continue
            }
            if character == NoteDocument.objectCharacter { index += 1; continue }
            if character == "[" {
                if matches("[date:", at: index), let close = characters[index...].firstIndex(of: "]"),
                   let day = NoteDay(isoString: String(characters[(index + 6)..<close])) {
                    flush(); result.append(.date(day)); index = close + 1; continue
                }
                if matches("[unsupported]", at: index) {
                    flush(); result.append(.unsupported); index += "[unsupported]".count; continue
                }
            }
            if place == .cell {
                if let lineBreak = ["<br>", "<br/>", "<br />"].first(where: { matches($0, at: index) }) {
                    literal.append("\n"); index += lineBreak.count; continue
                }
                if character == "&", let (value, length) = entity(characters, at: index) {
                    literal += value; index += length; continue
                }
            }
            literal.append(character)
            index += 1
        }
        flush()
        return result
    }

    static func isEscapable(_ character: Character) -> Bool {
        "\\[|<&".contains(character) || character.isWhitespace
    }

    /// White space a pipe table trims from a cell's edges.
    static func isPadding(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    /// The character an entity at `index` stands for, and its length, read
    /// as cells always read them (`&amp;`, `&lt;`, `&#124;`…).
    static func entity(_ characters: [Character], at index: Int) -> (String, Int)? {
        guard characters[index] == "&", let end = characters[index...].prefix(12).firstIndex(of: ";") else { return nil }
        let name = String(characters[(index + 1)..<end])
        let named = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&"]
        if let value = named[name] { return (value, end - index + 1) }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") {
            guard digits.count > 1, digits.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
            value = UInt32(digits)
        }
        return (value.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? "", end - index + 1)
    }

    /// An agent's body as lines: a line break after an escaping `\` stays in
    /// the line, and a carriage return before a line break is dropped unless
    /// escaped. As typed, every line break ends a line.
    static func lines(_ body: String, in place: Place) -> [String] {
        guard !body.isEmpty else { return [] }
        var result: [String] = []
        var continues = false
        for raw in body.components(separatedBy: "\n") {
            var line = raw
            if line.hasSuffix("\r"), place == .typed || !endsEscaping(line.dropLast()) { line.removeLast() }
            if continues, let last = result.popLast() { line = last + "\n" + line }
            result.append(line)
            continues = place != .typed && endsEscaping(Substring(line))
        }
        return result
    }

    /// The text ends in an odd run of backslashes: the next character is escaped.
    private static func endsEscaping(_ text: Substring) -> Bool {
        text.reversed().prefix { $0 == "\\" }.count % 2 == 1
    }
}

enum NoteAgentTextError: LocalizedError, Equatable {
    case unknownImage(String)
    case unknownFile(String)
    case unknownBlock(String)
    case lossyFormatting
    /// A text rewrite changed a table that carries formatting the text can't show.
    case formattedTable(String)
    case unsafeChecklist
    case raggedTable
    case tableTooLarge
    case unknownTable(String)
    case invalidTableEdit(String)

    var errorDescription: String? {
        switch self {
        case let .unknownImage(reference):
            "The image \(reference) is not in this note. Keep image lines exactly as get_note returned them."
        case let .unknownFile(reference):
            "The file \(reference) is not in this note. Keep file lines exactly as get_note returned them."
        case let .unknownBlock(reference):
            "The block \(reference) is not in this note. Keep unsupported-content lines exactly as returned."
        case .unsafeChecklist:
            "This edit would flatten, duplicate, reorder, or change an existing checklist item. Keep remaining checklist lines unchanged except for their checked states; add or remove complete checklist lines."
        case .lossyFormatting:
            "This note contains paragraph structure or inline marks that the agent text format cannot safely preserve during this edit. Keep styled blocks unchanged, change only plain text or checklist checked states, or edit the note in Attic."
        case let .formattedTable(id):
            "The table \(id) has formatting the text can't show (marks, dragged widths or extras). Leave its token line and pipe table unchanged in update_note, and change it with update_note_table by id (set a cell, insert, delete or move a row or column, or delete_table to delete it)."
        case .raggedTable:
            "Every row of a table must have as many cells as its header row."
        case .tableTooLarge:
            "A table can have at most \(NoteTable.maxColumns) columns and \(NoteTable.maxRows) rows."
        case let .unknownTable(reference):
            "The table \(reference) is not in this note. Keep each table's <!-- attic:table id=… --> line as list_notes returned it."
        case let .invalidTableEdit(reason):
            reason
        }
    }
}

/// The agent wire format has no mark offsets or complete paragraph metadata.
/// Surviving rich blocks retain their fields; plain text and checklist
/// checked states may change, and whole checklist lines may be added or removed.
enum NoteAgentTextSafety {
    /// A text rewrite's tables. A plain table may change, come or go. A table
    /// carrying anything the text can't show is a styled block: it must come
    /// back equal, under its own token; it changes by id (`update_note_table`).
    static func validateTables(base: NoteDocument, proposed: NoteDocument) throws {
        for table in base.blocks where NoteAgentTableText.carriesHidden(table) {
            guard proposed.blocks.contains(table) else { throw NoteAgentTextError.formattedTable(table.id?.uuidString ?? "") }
        }
    }

    static func validate(base: NoteDocument, proposed: NoteDocument) throws {
        // Whole checklist lines may be added or removed. Surviving base
        // items retain their identity and metadata exactly, in base order;
        // the wire format supports only their checked-state changes.
        let baseItems = base.blocks.filter { $0.kind == .checklist }
        let proposedItems = proposed.blocks.filter { $0.kind == .checklist }
        let baseIDs = Set(baseItems.compactMap(\.id))
        let remainingIDs = Set(proposedItems.compactMap(\.id))
        let unchecked: (NoteBlock) -> NoteBlock = { block in
            var item = block; item.checked = false; return item
        }
        let survivors = proposedItems.filter { $0.id.map(baseIDs.contains) == true }
        let expected = baseItems.filter { $0.id.map(remainingIDs.contains) == true }
        guard survivors.map(unchecked) == expected.map(unchecked) else { throw NoteAgentTextError.unsafeChecklist }
        let addedItems = proposedItems.filter { $0.id.map(baseIDs.contains) != true }
        for item in addedItems {
            // A second wire copy gets a fresh ID during parsing. That must
            // not disguise duplication of an existing checklist line.
            guard !baseItems.contains(where: {
                NoteTextExport.agentLine(unchecked($0), index: 1) == NoteTextExport.agentLine(unchecked(item), index: 1)
            }) else { throw NoteAgentTextError.unsafeChecklist }
        }
        for item in baseItems {
            guard !proposed.blocks.contains(where: { block in
                if let id = item.id, block.id == id, block.kind != .checklist { return true }
                return item.id.map(remainingIDs.contains) != true && !item.displayText.isEmpty
                    && block.kind == .text && block.displayText == item.displayText && !base.blocks.contains(block)
            }) else { throw NoteAgentTextError.unsafeChecklist }
        }
        // A wire rename becomes removal plus insertion because the text no
        // longer matches. Do not let that silently discard hidden checklist
        // metadata. Whole-item deletion remains allowed; replacements must
        // preserve the removed items' metadata once each.
        if !addedItems.isEmpty {
            var replacements = addedItems
            for item in baseItems where item.id.map(remainingIDs.contains) != true
                && (item.indent != nil || !item.marks.isEmpty || !item.extras.isEmpty) {
                guard let index = replacements.firstIndex(where: {
                    $0.indent == item.indent && $0.marks == item.marks && $0.extras == item.extras
                }) else { throw NoteAgentTextError.unsafeChecklist }
                replacements.remove(at: index)
            }
        }
        let rich = base.blocks.contains {
            $0.style != nil || $0.level != nil || $0.indent != nil || !$0.marks.isEmpty
                || $0.kind == .divider
        }
        if !rich {
            // Plain text may gain or lose paragraphs around file and image
            // placements. The complete placement objects must remain once
            // each, in order, with the same stored attachment identities.
            let attachments: (NoteDocument) -> [NoteBlock] = { document in
                document.blocks.filter { $0.kind == .file || $0.kind == .image }
            }
            guard attachments(base) == attachments(proposed) else { throw NoteAgentTextError.lossyFormatting }
            let dates: (NoteDocument) -> [NoteInline] = { document in
                document.blocks.filter { $0.kind != .checklist }.flatMap(\.inlines)
            }
            guard dates(base) == dates(proposed) else { throw NoteAgentTextError.lossyFormatting }
            return
        }
        // Tables: `validateTables` for a text rewrite; edits by id
        // (`update_note_table`) change them through this check too.
        let oldBlocks = base.blocks.filter { $0.kind != .checklist && $0.kind != .table }
        let newBlocks = proposed.blocks.filter { $0.kind != .checklist && $0.kind != .table }
        guard oldBlocks.count == newBlocks.count else { throw NoteAgentTextError.lossyFormatting }
        for (old, new) in zip(oldBlocks, newBlocks) {
            if old == new { continue }
            // An ordinary text block can change alongside rich blocks only
            // when every other field, including object IDs, survives.
            if old.kind == .text, old.style == nil, old.level == nil,
               old.indent == nil, old.marks.isEmpty {
                var textCopy = old
                textCopy.text = new.text
                if textCopy == new { continue }
            }
            throw NoteAgentTextError.lossyFormatting
        }
    }
}

/// Turns an agent's title and body back into a document, reusing the base
/// document's blocks wherever the agent kept them, so kept objects keep
/// their IDs (and images their attachments).
enum NoteAgentTextParser {
    /// `typed`: the body is text a person typed (the composer), read without
    /// escapes; otherwise it is agent text (`NoteAgentText`).
    static func document(title: String, body: String, base: NoteDocument, typed: Bool = false) throws -> NoteDocument {
        let place: NoteAgentText.Place = typed ? .typed : .line
        var used = Set<Int>()
        let baseLines = base.blocks.enumerated().map { index, block in
            (index, block, NoteTextExport.agentLine(block, index: index))
        }
        var blocks: [NoteBlock] = []
        // The title keeps the base title block (and its fields) when unchanged.
        if let first = base.blocks.first, first.kind == .text, NoteTextExport.agentTitle(base) == title {
            blocks.append(first)
            used.insert(0)
        } else {
            blocks.append(parseTextual(title, kind: .text, place: .typed))
        }

        var lines = NoteAgentText.lines(body, in: place)
        // An empty body is the base's one empty line, when that is its body.
        if lines.isEmpty, base.blocks.count == 2, NoteTextExport.agentLine(base.blocks[1], index: 1).isEmpty { lines = [""] }
        var usedTables = Set<UUID>()
        // Tables named by a token anywhere in the body are never matched by content.
        let tokenIDs = Set(lines.compactMap { NoteTableText.commentFields($0)?["id"].flatMap(UUID.init(uuidString:)) })
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            // 0. A table: its token line (if any) and its pipe rows.
            if let parsed = try NoteAgentTableText.parse(lines: lines, from: index - 1) {
                let block = try NoteAgentTableText.block(parsed, base: base, used: &usedTables, tokenIDs: tokenIDs)
                blocks.append(block)
                index = index - 1 + parsed.consumed
                continue
            }
            // 1. An unchanged line keeps its block exactly.
            if let match = baseLines.first(where: { !used.contains($0.0) && $0.0 > 0 && $0.2 == line }) {
                blocks.append(match.1)
                used.insert(match.0)
                continue
            }
            // 2. Images and unsupported blocks are referenced, never created.
            if let reference = reference(in: line, scheme: "attic://image/") {
                guard let match = baseLines.first(where: {
                    $0.1.kind == .image && $0.1.id?.uuidString.lowercased() == reference.lowercased()
                }) else { throw NoteAgentTextError.unknownImage(reference) }
                var block = match.1
                // A second copy of the same image is a new placement of the
                // same attachment: IDs stay unique within the note.
                if used.contains(match.0) { block.id = UUID() }
                blocks.append(block)
                used.insert(match.0)
                continue
            }
            if let reference = reference(in: line, scheme: "attic://file/") {
                guard let match = baseLines.first(where: {
                    $0.1.kind == .file && $0.1.id?.uuidString.lowercased() == reference.lowercased()
                }) else { throw NoteAgentTextError.unknownFile(reference) }
                var block = match.1
                if used.contains(match.0) { block.id = UUID() }
                blocks.append(block)
                used.insert(match.0)
                continue
            }
            if let reference = reference(in: line, scheme: "attic://block/") {
                guard let index = Int(reference), base.blocks.indices.contains(index),
                      base.blocks[index].kind == .opaque,
                      !used.contains(index) else { throw NoteAgentTextError.unknownBlock(reference) }
                blocks.append(base.blocks[index])
                used.insert(index)
                continue
            }
            // 3. A changed checklist line keeps the ID of a base line with
            //    the same text (ticking by an agent keeps the item).
            if let (checked, text) = checklistParts(line) {
                let pieces = NoteAgentText.read(text, in: place)
                let reusable = baseLines.first(where: {
                    !used.contains($0.0) && $0.1.kind == .checklist
                        && NoteAgentText.pieces($0.1.text, inlines: $0.1.inlines) == pieces
                })
                var block = if let reusable { reusable.1 } else {
                    parseTextual(text, kind: .checklist, place: place)
                }
                block.checked = checked
                if let reusable { used.insert(reusable.0) }
                blocks.append(block)
                continue
            }
            blocks.append(parseTextual(line, kind: .text, place: place))
        }
        var document = base
        document.blocks = blocks
        try NoteAgentTextSafety.validateTables(base: base, proposed: document)
        try NoteAgentTextSafety.validate(base: base, proposed: document)
        return document
    }

    private static func checklistParts(_ line: String) -> (Bool, String)? {
        for (prefix, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(prefix) {
            return (checked, String(line.dropFirst(prefix.count)))
        }
        for (prefix, checked) in [("- [ ]", false), ("- [x]", true), ("- [X]", true)] where line == prefix {
            return (checked, "")
        }
        return nil
    }

    /// `![…](scheme<id>)` or `[…](scheme<id>)`; an escaped `\[` is text. The
    /// last `(scheme` counts, since a file's name is free text.
    private static func reference(in line: String, scheme: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), trimmed.hasPrefix("![") || trimmed.hasPrefix("["),
              let open = trimmed.range(of: "(" + scheme, options: .backwards) else { return nil }
        return String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
    }

    /// A line's text: dates become inline dates (each a new one); an
    /// `[unsupported]` with no object behind it stays text.
    private static func parseTextual(_ line: String, kind: NoteBlockKind, place: NoteAgentText.Place) -> NoteBlock {
        var text = ""
        var inlines: [NoteInline] = []
        for piece in NoteAgentText.read(line, in: place) {
            switch piece {
            case let .text(literal): text += literal
            case .unsupported: text += "[unsupported]"
            case let .date(day):
                text.append(NoteDocument.objectCharacter)
                inlines.append(NoteInline(id: UUID(), kind: .date(day)))
            }
        }
        var block = NoteBlock(kind: kind, text: text, inlines: inlines)
        if kind == .checklist { block.id = UUID() }
        return block
    }
}
