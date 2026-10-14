import AppKit

struct NoteBlockDropPosition: Equatable {
    var location: Int
    var depth: Int
}

/// A block move replaces only the span between source and destination. Its
/// attributed paragraphs (including identities, unknown fields and marks)
/// are carried intact, with the separators kept in their original count.
@MainActor
enum NoteBlockMove {
    static func clearStart(in text: NSMutableAttributedString, paragraph: NSRange) {
        text.removeAttribute(.noteListStart, range: paragraph)
        var boxes: [(NSRange, NoteBlockExtras)] = []
        text.enumerateAttribute(.noteBlockExtras, in: paragraph) { value, range, _ in
            if let box = value as? NoteBlockExtras { boxes.append((range, box)) }
        }
        for (range, box) in boxes {
            var fields = box.fields; fields["start"] = nil
            text.addAttribute(.noteBlockExtras, value: NoteBlockExtras(fields), range: range)
        }
    }

    static func joined(_ chunks: [NSAttributedString], endsWithBreak: Bool) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, chunk) in chunks.filter({ $0.length > 0 }).enumerated() {
            let part = NSMutableAttributedString(attributedString: chunk)
            if part.string.hasSuffix("\n") { part.deleteCharacters(in: NSRange(location: part.length - 1, length: 1)) }
            if index > 0 {
                let attributes = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil) : [:]
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            result.append(part)
        }
        if endsWithBreak {
            let attributes = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil) : [:]
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return result
    }
}

@MainActor
extension NoteEditorEngine {
    func blockRange(at location: Int) -> NSRange {
        var range = paragraphRange(at: location)
        guard let format = paragraphStyle(at: location) else { return range }
        if case .heading = format, let section = headingSection(at: location),
           let id = section.id, foldedHeadingIDs.contains(id) {
            return NSUnionRange(section.heading, section.content)
        }
        let list = [.bullet, .number, .checklist].contains(format)
        if list {
            let depth = blockDepth(at: range.location)
            while NSMaxRange(range) < textStorage.length, blockIsList(at: NSMaxRange(range)), blockDepth(at: NSMaxRange(range)) > depth {
                let next = paragraphRange(at: NSMaxRange(range))
                guard next.length > 0 else { break }
                range = NSUnionRange(range, next)
            }
            return range
        }
        guard format.isCode || format.isCallout || format == .quote else { return range }
        func matches(_ at: Int) -> Bool {
            guard let other = paragraphStyle(at: at) else { return false }
            if format.isCode { return other.isCode }
            return other == format
        }
        while range.location > titleParagraphRange.length + 1, matches(range.location - 1) {
            range = NSUnionRange(paragraphRange(at: range.location - 1), range)
        }
        while NSMaxRange(range) < textStorage.length, matches(NSMaxRange(range)) {
            let next = paragraphRange(at: NSMaxRange(range))
            guard next.length > 0 else { break }
            range = NSUnionRange(range, next)
        }
        return range
    }

    private func blockDepth(at location: Int) -> Int {
        guard location >= 0, location < textStorage.length else { return 0 }
        return textStorage.attribute(.noteBlockIndent, at: paragraphRange(at: location).location, effectiveRange: nil) as? Int ?? 0
    }
    private func blockIsList(at location: Int) -> Bool { [.bullet, .number, .checklist].contains(paragraphStyle(at: location) ?? .body) }

    func blockDropPosition(at location: Int, after: Bool) -> NoteBlockDropPosition? {
        guard location >= 0, location <= textStorage.length else { return nil }
        let range = blockRange(at: location)
        guard range.location > 0 else { return nil }
        let position = after ? NSMaxRange(range) : range.location
        let depth = position > 0 && blockIsList(at: position - 1) ? blockDepth(at: position - 1) : 0
        return NoteBlockDropPosition(location: position, depth: depth)
    }

    @discardableResult func moveBlock(_ source: NSRange, to position: Int) -> Bool {
        guard !isReadOnly, source.location > titleParagraphRange.length,
              source.length > 0, source.location <= textStorage.length,
              source.length <= textStorage.length - source.location,
              source == blockRange(at: source.location), position > titleParagraphRange.length,
              position <= textStorage.length, position < source.location || position > NSMaxRange(source) else { return false }
        if position < textStorage.length {
            guard blockRange(at: position).location == position else { return false }
        }
        let first = min(source.location, position)
        var end = max(NSMaxRange(source), position)
        // Include one following paragraph so an existing run's first-item
        // start can transfer without creating another Undo step.
        if end < textStorage.length { end = NSMaxRange(paragraphRange(at: end)) }
        let span = NSRange(location: first, length: end - first)
        let original = textStorage.attributedSubstring(from: span)
        let working = NSMutableAttributedString(attributedString: original)
        let originalDepth = blockDepth(at: source.location)
        let list = blockIsList(at: source.location)
        let targetDepth = position > 0 && blockIsList(at: position - 1) ? blockDepth(at: position - 1) : 0
        let relativeSource = NSRange(location: source.location - first, length: source.length)
        let sourceFirst = (working.string as NSString).paragraphRange(for: NSRange(location: relativeSource.location, length: 0))
        if paragraphStyle(at: source.location) == .number {
            let start = textStorage.attribute(.noteListStart, at: source.location, effectiveRange: nil) as? Int
            let next = NSMaxRange(source)
            if let start, next < textStorage.length, paragraphStyle(at: next) == .number, blockDepth(at: next) == originalDepth {
                let successor = (working.string as NSString).paragraphRange(for: NSRange(location: next - first, length: 0))
                NoteBlockMove.clearStart(in: working, paragraph: sourceFirst)
                working.addAttribute(.noteListStart, value: start, range: successor)
            }
            if position < textStorage.length, paragraphStyle(at: position) == .number,
               blockDepth(at: position) == targetDepth {
                let target = (working.string as NSString).paragraphRange(for: NSRange(location: position - first, length: 0))
                let targetStart = working.attribute(.noteListStart, at: target.location, effectiveRange: nil) as? Int
                NoteBlockMove.clearStart(in: working, paragraph: sourceFirst)
                if let targetStart {
                    NoteBlockMove.clearStart(in: working, paragraph: target)
                    working.addAttribute(.noteListStart, value: targetStart, range: sourceFirst)
                }
            } else if position > 0, paragraphStyle(at: position - 1) == .number, blockDepth(at: position - 1) == targetDepth {
                NoteBlockMove.clearStart(in: working, paragraph: sourceFirst)
            }
        }
        let moved = NSMutableAttributedString(attributedString: working.attributedSubstring(from: relativeSource))
        if list {
            var paragraphs: [(NSRange, Int)] = [], maximumRelativeDepth = 0, at = 0
            let string = moved.string as NSString
            while at < moved.length {
                let range = string.paragraphRange(for: NSRange(location: at, length: 0))
                let depth = moved.attribute(.noteBlockIndent, at: at, effectiveRange: nil) as? Int ?? 0
                paragraphs.append((range, depth)); maximumRelativeDepth = max(maximumRelativeDepth, depth - originalDepth)
                at = NSMaxRange(range)
            }
            let depth = min(targetDepth, 2 - maximumRelativeDepth)
            for (range, old) in paragraphs {
                let value = max(0, old - originalDepth + depth)
                moved.removeAttribute(.noteBlockIndent, range: range)
                if value > 0 { moved.addAttribute(.noteBlockIndent, value: value, range: range) }
            }
        }
        let chunks: [NSAttributedString]
        let selectedLocation: Int
        if position < source.location {
            let between = working.attributedSubstring(from: NSRange(location: 0, length: source.location - position))
            let tail = working.attributedSubstring(from: NSRange(location: NSMaxRange(relativeSource), length: working.length - NSMaxRange(relativeSource)))
            chunks = [moved, between, tail]; selectedLocation = first
        } else {
            let between = working.attributedSubstring(from: NSRange(location: NSMaxRange(relativeSource), length: position - NSMaxRange(source)))
            let tail = working.attributedSubstring(from: NSRange(location: position - first, length: end - position))
            chunks = [between, moved, tail]; selectedLocation = first + between.length + (between.string.hasSuffix("\n") ? 0 : 1)
        }
        let replacement = NoteBlockMove.joined(chunks, endsWithBreak: original.string.hasSuffix("\n"))
        // A final source without a separator gains one before its new neighbour.
        let selectionLength = moved.length - (moved.string.hasSuffix("\n") ? 1 : 0)
        return performEdit(span, with: replacement, name: "Move Block", selection: NSRange(location: selectedLocation, length: selectionLength))
    }
}
