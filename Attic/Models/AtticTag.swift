import Foundation

/// Tag rules shared by every page and by agents. A tag is lowercase letters,
/// numbers and hyphens. Tags are stored on each item as one normalised string
/// (sorted, unique, space-separated), so there is no tag table to keep unique
/// across replicas: a tag exists while any item carries it.
enum AtticTag {
    static let maximumLength = 64
    private static let separator: Character = " "

    /// The canonical form of a tag, or nil when nothing usable remains.
    /// A leading `#` is dropped, letters are lowercased, runs of spaces,
    /// underscores and hyphens become one hyphen, anything else is removed.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.first == "#" { text.removeFirst() }
        var result = ""
        var pendingHyphen = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.append(character)
            } else if character == "-" || character == "_" || character.isWhitespace {
                pendingHyphen = true
            }
        }
        guard !result.isEmpty else { return nil }
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength))
            while result.last == "-" { result.removeLast() }
        }
        return result.isEmpty ? nil : result
    }

    /// Normalised, unique and sorted: the stored order never depends on the
    /// order tags were typed, so equal tag sets compare equal across replicas.
    static func normalizedSet<S: Sequence>(_ tags: S) -> [String] where S.Element == String {
        Array(Set(tags.compactMap(normalize))).sorted()
    }

    static func encode<S: Sequence>(_ tags: S) -> String where S.Element == String {
        normalizedSet(tags).joined(separator: String(separator))
    }

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: separator).map(String.init)
    }
}
