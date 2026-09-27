import Foundation

/// Text forms of a note for search, the legacy `body` column and agents.
enum NoteTextExport {
    /// Search and preview text: the title, then one line per block. Objects
    /// read as `[ ] text`, `[x] text`, `[Image]`; dates as ISO days.
    static func plainText(_ document: NoteDocument) -> String {
        document.blocks.map(plainLine).joined(separator: "\n")
    }

    /// Everything after the title, as plain text (the legacy `body` column
    /// for a note stored in the new format, so older readers still show it).
    static func plainBody(_ document: NoteDocument) -> String {
        document.blocks.dropFirst().map(plainLine).joined(separator: "\n")
    }

    static func plainLine(_ block: NoteBlock) -> String {
        switch block.kind {
        case .text: block.displayText
        case .checklist: (block.checked ? "[x] " : "[ ] ") + block.displayText
        case .image: "[Image]"
        case .opaque: "[Unsupported content]"
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
        case .text: agentInlineText(block)
        case .checklist: (block.checked ? "- [x] " : "- [ ] ") + agentInlineText(block)
        case .image: "![image](attic://image/\(block.id?.uuidString ?? ""))"
        case .opaque: "[unsupported content](attic://block/\(index))"
        }
    }

    private static func agentInlineText(_ block: NoteBlock) -> String {
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
    case unknownBlock(String)

    var errorDescription: String? {
        switch self {
        case let .unknownImage(reference):
            "The image \(reference) is not in this note. Keep image lines exactly as get_note returned them, or remove them."
        case let .unknownBlock(reference):
            "The block \(reference) is not in this note. Keep unsupported-content lines exactly as returned, or remove them."
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

        let lines = body.isEmpty ? [] : body.components(separatedBy: "\n")
        for (lineNumber, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
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
                var block = try parseTextual(text, kind: .checklist, reusing: reusable?.1)
                block.checked = checked
                if let reusable { used.insert(reusable.0) }
                blocks.append(block)
                continue
            }
            blocks.append(try parseTextual(line, kind: .text, reusing: nil))
        }
        var document = base
        document.blocks = blocks
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
