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
            let prefix: String = switch block.style {
            case "heading": String(repeating: "#", count: max(1, block.level ?? 2)) + " "
            case "bullet": "- "
            case "number": "1. "
            case "quote": "> "
            case "mono": "    "
            default: ""
            }
            return String(repeating: "  ", count: block.indent ?? 0) + prefix + block.displayText
        case .checklist: return String(repeating: "  ", count: block.indent ?? 0) + (block.checked ? "[x] " : "[ ] ") + block.displayText
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
    /// its line.
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
        switch block.kind {
        case .text:
            var plain = block
            plain.text = agentInlineText(block)
            plain.inlines = []
            return plainLine(plain)
        case .checklist: return (block.checked ? "- [x] " : "- [ ] ") + agentInlineText(block)
        case .image: return "![image](attic://image/\(block.id?.uuidString ?? ""))"
        case .file: return "[file: \(block.filename ?? "file")](attic://file/\(block.id?.uuidString ?? ""))"
        case .divider: return "---"
        case .table: return agentTable(block)
        case .opaque: return "[unsupported content](attic://block/\(index))"
        }
    }

    /// A table as agents read and write it: an `attic:table` token line
    /// (its id, and `headerRow=false` when the header row is off), then a
    /// GFM pipe table. Dates in cells read `[date:YYYY-MM-DD]`.
    static func agentTable(_ block: NoteBlock) -> String {
        guard let table = block.table else { return "" }
        var token = "<!-- attic:table id=\(block.id?.uuidString ?? "")"
        if !table.headerRow { token += " headerRow=false" }
        token += " -->"
        var visible = table
        visible.headerRow = true
        let grid = NoteTableText.markdown(visible) { cell in NoteTableText.plainCellMarkdown(agentInlineText(cell.block)) }
        return token + "\n" + grid
    }

    static func agentInlineText(_ block: NoteBlock) -> String {
        guard !block.inlines.isEmpty else { return block.text }
        var result = ""
        var index = 0
        for character in block.text {
            if character == NoteDocument.objectCharacter, index < block.inlines.count {
                switch block.inlines[index].kind {
                case let .date(day): result += "[date:\(day.isoString)]"
                case .opaque: result += "[unsupported]"
                }
                index += 1
            } else {
                result.append(character)
            }
        }
        return result
    }
}

enum NoteAgentTextError: LocalizedError, Equatable {
    case unknownImage(String)
    case unknownFile(String)
    case unknownBlock(String)
    case lossyFormatting
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
        // Tables are matched by their own token and may change, come or go.
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
    static func document(title: String, body: String, base: NoteDocument) throws -> NoteDocument {
        var used = Set<Int>()
        let baseLines = base.blocks.enumerated().map { index, block in
            (index, block, NoteTextExport.agentLine(block, index: index))
        }
        var blocks: [NoteBlock] = []
        // The title keeps the base title block (and its fields) when unchanged.
        if let first = base.blocks.first, first.kind == .text, NoteTextExport.agentLine(first, index: 0) == title {
            blocks.append(first)
            used.insert(0)
        } else {
            blocks.append(try parseTextual(title, kind: .text, reusing: nil))
        }

        let lines = (body.isEmpty ? [] : body.components(separatedBy: "\n"))
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
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
                let reusable = baseLines.first(where: {
                    !used.contains($0.0) && $0.1.kind == .checklist && agentText(of: $0.1) == text
                })
                var block = if let reusable { reusable.1 } else {
                    try parseTextual(text, kind: .checklist, reusing: nil)
                }
                block.checked = checked
                if let reusable { used.insert(reusable.0) }
                blocks.append(block)
                continue
            }
            blocks.append(try parseTextual(line, kind: .text, reusing: nil))
        }
        var document = base
        document.blocks = blocks
        try NoteAgentTextSafety.validate(base: base, proposed: document)
        return document
    }

    private static func agentText(of block: NoteBlock) -> String {
        let line = NoteTextExport.agentLine(block, index: 1)
        return checklistParts(line)?.1 ?? line
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

    private static func reference(in line: String, scheme: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.range(of: "(" + scheme),
              trimmed.hasPrefix("!") || trimmed.hasPrefix("[") else { return nil }
        return String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
    }

    /// Parses `[date:YYYY-MM-DD]` tokens into inline dates. A literal U+FFFC
    /// in agent text is dropped (it would claim an object that isn't there).
    private static func parseTextual(_ line: String, kind: NoteBlockKind, reusing: NoteBlock?) throws -> NoteBlock {
        var text = ""
        var inlines: [NoteInline] = []
        var reusableDates = reusing?.inlines ?? []
        var remainder = Substring(line.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: ""))
        while let start = remainder.range(of: "[date:") {
            text += remainder[remainder.startIndex..<start.lowerBound]
            let afterPrefix = remainder[start.upperBound...]
            if let close = afterPrefix.firstIndex(of: "]"),
               let day = NoteDay(isoString: String(afterPrefix[afterPrefix.startIndex..<close])) {
                let id: UUID
                if let index = reusableDates.firstIndex(where: { $0.kind == .date(day) }) {
                    id = reusableDates.remove(at: index).id
                } else {
                    id = UUID()
                }
                text.append(NoteDocument.objectCharacter)
                inlines.append(NoteInline(id: id, kind: .date(day)))
                remainder = afterPrefix[afterPrefix.index(after: close)...]
            } else {
                text += "[date:"
                remainder = afterPrefix
            }
        }
        text += remainder
        var block = NoteBlock(kind: kind, text: text, inlines: inlines)
        if kind == .checklist { block.id = reusing?.id ?? UUID() }
        if let reusing, kind == reusing.kind { block.extras = reusing.extras }
        return block
    }
}
