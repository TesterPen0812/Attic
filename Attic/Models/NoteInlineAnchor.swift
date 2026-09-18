import Foundation

/// One UTF-16 replacement, in the shape `NSTextStorage` reports an edit
/// (`editedRange` plus `changeInLength`).
///
/// Rebasing an anchor through a replacement is O(1). A changed body is an
/// *ordered list* of these replacements — either the real `NSTextStorage`
/// edits the editor records, or a list derived by diffing at paragraph
/// granularity. Applying the list in order keeps text that survives between
/// disjoint edits outside every replaced span, so a paragraph that was never
/// touched keeps its anchor. Deriving edits by diffing two whole bodies is
/// O(document), so the editor records the real edits and only falls back to
/// the derived list when no edit description is available.
struct NoteTextReplacement: Equatable {
    let location: Int
    let oldLength: Int
    let newLength: Int

    init(location: Int, oldLength: Int, newLength: Int) {
        self.location = max(0, location)
        self.oldLength = max(0, oldLength)
        self.newLength = max(0, newLength)
    }

    var delta: Int { newLength - oldLength }

    static func utf16Equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func validates(
        _ edits: [NoteTextReplacement],
        oldLength: Int,
        newLength: Int
    ) -> Bool {
        var length = oldLength
        for edit in edits {
            guard edit.location <= length,
                  edit.oldLength <= length - edit.location else { return false }
            length += edit.delta
        }
        return length == newLength
    }

    /// The same rule native typing and undo apply: text before the replacement
    /// keeps its offset, text after it shifts by the delta, and an anchor
    /// inside the replaced span collapses to the replacement's start.
    func rebasing(_ offset: Int) -> Int {
        if offset < location { return offset }
        if offset >= location + oldLength { return offset + delta }
        return location
    }

    /// The whole-document prefix/suffix diff — a single replacement covering
    /// the first through the last differing UTF-16 unit. Unchanged paragraphs
    /// inside that span are not preserved, so it is only the bounded fallback
    /// `edits(from:to:)` uses past `maxDiffedParagraphs`.
    static func diffing(_ oldText: String, _ newText: String) -> NoteTextReplacement {
        let old = Array(oldText.utf16), new = Array(newText.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return NoteTextReplacement(
            location: prefix,
            oldLength: old.count - suffix - prefix,
            newLength: new.count - suffix - prefix
        )
    }

    /// Above this many combined paragraphs `edits(from:to:)` falls back to a
    /// single `diffing` span, so a pathological document cannot make a save
    /// super-linear. Real notes sit far below the bound.
    static let maxDiffedParagraphs = 8192

    /// The ordered replacement list mapping `oldText` to `newText`. Applying
    /// the elements left to right transforms the old body into the new one,
    /// and every paragraph whose text survives verbatim stays outside the
    /// replaced spans — the exact property an inline anchor needs.
    ///
    /// The diff is computed over paragraphs rather than UTF-16 units: anchors
    /// are always snapped to paragraph boundaries, so a paragraph identical
    /// on both sides is precisely the region an anchor may stay bound to, and
    /// the paragraph count bounds the diff's cost regardless of document
    /// length.
    static func edits(from oldText: String, to newText: String) -> [NoteTextReplacement] {
        guard !utf16Equal(oldText, newText) else { return [] }
        let oldValue = oldText as NSString, newValue = newText as NSString
        let oldSpans = paragraphRanges(in: oldValue)
        let newSpans = paragraphRanges(in: newValue)
        guard oldSpans.count + newSpans.count <= maxDiffedParagraphs else {
            return [diffing(oldText, newText)]
        }
        // Swift String equality is canonical-equivalence based. Anchors and
        // NSTextStorage ranges are UTF-16 based, so paragraph identity must be
        // exact too (decomposed and precomposed text can have different lengths).
        let difference = newSpans.map { Array(newValue.substring(with: $0).utf16) }
            .difference(from: oldSpans.map { Array(oldValue.substring(with: $0).utf16) })
        let removals = difference.removals.map { change -> Int in
            guard case .remove(let offset, _, _) = change else { return -1 }
            return offset
        }.sorted()
        let insertions = difference.insertions.map { change -> Int in
            guard case .insert(let offset, _, _) = change else { return -1 }
            return offset
        }.sorted()

        // Walk removals (old-side paragraph indices) and insertions (new-side
        // paragraph indices) in parallel, coalescing adjacent changes into one
        // replacement. `start` is in old-paragraph indices; an insertion at
        // new index i belongs at old index i - paragraphDelta.
        var edits: [NoteTextReplacement] = []
        var removalIndex = 0, insertionIndex = 0
        var paragraphDelta = 0, utf16Delta = 0
        while removalIndex < removals.count || insertionIndex < insertions.count {
            let nextRemoval = removalIndex < removals.count ? removals[removalIndex] : Int.max
            let nextInsertion = insertionIndex < insertions.count
                ? insertions[insertionIndex] - paragraphDelta : Int.max
            let start = min(nextRemoval, nextInsertion)
            var removed = 0, inserted = 0
            while true {
                if removalIndex < removals.count, removals[removalIndex] == start + removed {
                    removalIndex += 1
                    removed += 1
                } else if insertionIndex < insertions.count,
                          insertions[insertionIndex] <= start + paragraphDelta + inserted {
                    insertionIndex += 1
                    inserted += 1
                } else {
                    break
                }
            }
            let oldStart = start < oldSpans.count ? oldSpans[start].location : oldValue.length
            let oldEnd = start + removed < oldSpans.count
                ? oldSpans[start + removed].location : oldValue.length
            let newFirst = start + paragraphDelta
            let newStart = newFirst < newSpans.count ? newSpans[newFirst].location : newValue.length
            let newEnd = newFirst + inserted < newSpans.count
                ? newSpans[newFirst + inserted].location : newValue.length
            edits.append(NoteTextReplacement(
                location: oldStart + utf16Delta,
                oldLength: oldEnd - oldStart,
                newLength: newEnd - newStart
            ))
            paragraphDelta += inserted - removed
            utf16Delta += (newEnd - newStart) - (oldEnd - oldStart)
        }
        return edits
    }

    /// Paragraph ranges in UTF-16 units, using the same `NSString` boundaries
    /// `NoteInlineAnchor.paragraphStart` snaps to.
    private static func paragraphRanges(in value: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < value.length {
            let range = value.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }
}

enum NoteInlineAnchor {
    static func paragraphStart(_ offset: Int, in text: String) -> Int {
        let value = text as NSString
        let position = min(max(0, offset), value.length)
        guard position < value.length else { return value.length }
        return value.paragraphRange(for: NSRange(location: position, length: 0)).location
    }

    /// Rebase a presentation anchor through the ordered edits describing the
    /// whole body change, recovered by a paragraph-granular diff.
    static func moved(_ offset: Int, from oldText: String, to newText: String) -> Int {
        guard !NoteTextReplacement.utf16Equal(oldText, newText) else {
            return paragraphStart(offset, in: newText)
        }
        return moved(offset, by: NoteTextReplacement.edits(from: oldText, to: newText), in: newText)
    }

    /// Rebase a presentation anchor through each ordered edit, then snap the
    /// result to its paragraph start.
    static func moved(_ offset: Int, by edits: [NoteTextReplacement], in newText: String) -> Int {
        paragraphStart(edits.reduce(offset) { $1.rebasing($0) }, in: newText)
    }
}

/// A body edit list tied to the exact UTF-16 source and destination that
/// produced it. The store rejects stale batches and falls back to deriving a
/// bounded paragraph diff rather than trusting length-only editor state.
struct NoteBodyEditBatch {
    let baseText: String
    let resultText: String
    let edits: [NoteTextReplacement]

    func validatedEdits(from oldText: String, to newText: String) -> [NoteTextReplacement]? {
        guard NoteTextReplacement.utf16Equal(baseText, oldText),
              NoteTextReplacement.utf16Equal(resultText, newText),
              NoteTextReplacement.validates(
                edits,
                oldLength: oldText.utf16.count,
                newLength: newText.utf16.count
              ) else { return nil }
        return edits
    }
}
