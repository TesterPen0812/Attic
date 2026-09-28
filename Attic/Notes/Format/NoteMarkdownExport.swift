import Foundation

/// Copy as Markdown (UX plan § 3.21): text serialisation, never file
/// transfer. The title is a level-one heading; paragraphs are separated by a
/// blank line and list lines by a single break; checklists read `- [ ]` and
/// `- [x]`; dates read as text ("Thu, 1 Oct 2026"); images as a readable
/// label (`[image: pricing-v2.png]`). Anything this build can't read stays
/// as a literal placeholder rather than disappearing. Markdown characters the
/// person typed are kept as typed.
enum NoteMarkdownExport {
    static func markdown(_ document: NoteDocument, calendar: Calendar = .current, locale: Locale = .current,
                         filename: (UUID) -> String? = { _ in nil }) -> String {
        var lines: [(text: String, isListItem: Bool)] = []
        for (index, block) in document.blocks.enumerated() {
            if index == 0, block.kind == .text {
                let title = inlineText(block, calendar: calendar, locale: locale).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { lines.append(("# " + title, false)) }
                continue
            }
            switch block.kind {
            case .text:
                let text = inlineText(block, calendar: calendar, locale: locale)
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                lines.append((text, false))
            case .checklist:
                lines.append(((block.checked ? "- [x] " : "- [ ] ") + inlineText(block, calendar: calendar, locale: locale), true))
            case .image:
                let name = block.attachmentID.flatMap(filename) ?? String(localized: "image")
                lines.append(("[image: \(name)]", false))
            case .opaque:
                lines.append((String(localized: "[content that needs a newer Attic]"), false))
            }
        }
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += line.isListItem && lines[index - 1].isListItem ? "\n" : "\n\n"
            }
            result += line.text
        }
        return result
    }

    /// A note still in the old format: its title and body as they are.
    static func markdown(title: String, body: String) -> String {
        let heading = title.trimmingCharacters(in: .whitespaces)
        let text = body.trimmingCharacters(in: .newlines)
        switch (heading.isEmpty, text.isEmpty) {
        case (true, _): return text
        case (false, true): return "# " + heading
        case (false, false): return "# " + heading + "\n\n" + text
        }
    }

    /// A date as the note shows it, with the year: "Thu, 1 Oct 2026".
    static func dateText(_ day: NoteDay, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar)
            .weekday(.abbreviated).day().month(.abbreviated).year()
        style.timeZone = calendar.timeZone
        return day.date(in: calendar).formatted(style)
    }

    private static func inlineText(_ block: NoteBlock, calendar: Calendar, locale: Locale) -> String {
        guard !block.inlines.isEmpty else { return block.text }
        var result = ""
        var index = 0
        for character in block.text {
            if character == NoteDocument.objectCharacter, index < block.inlines.count {
                switch block.inlines[index].kind {
                case let .date(day): result += dateText(day, calendar: calendar, locale: locale)
                case .opaque: result += String(localized: "[content that needs a newer Attic]")
                }
                index += 1
            } else {
                result.append(character)
            }
        }
        return result
    }
}
