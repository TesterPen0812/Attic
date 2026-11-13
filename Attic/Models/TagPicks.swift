import Foundation

/// The tags picked in a page's tag bar (Accepted 2026-11-13, "Tag bar
/// collapsed, several tags, status filters", 2B): clicks add and remove
/// tags, in the order they were picked. With two or more an Any · All
/// switch decides whether a task needs one of them or every one (Any by
/// default). None picked is All: nothing is filtered. Pure: tested directly.
struct TagPicks: Hashable, Sendable {
    enum Match: String, CaseIterable, Hashable, Sendable {
        case any, all
    }

    private(set) var tags: [String]
    /// Any or All; only meaningful with two or more tags (with fewer it is
    /// always Any, so the switch starts on Any each time it appears).
    private(set) var match: Match

    static let none = TagPicks()

    init(_ tags: [String] = [], match: Match = .any) {
        var unique: [String] = []
        for tag in tags where !unique.contains(tag) { unique.append(tag) }
        self.tags = unique
        self.match = unique.count >= 2 ? match : .any
    }

    var isEmpty: Bool { tags.isEmpty }
    var count: Int { tags.count }
    func contains(_ tag: String) -> Bool { tags.contains(tag) }

    /// The switch shows once two tags are picked.
    var showsMatch: Bool { tags.count >= 2 }

    /// Whether something carrying `itemTags` shows: always with none picked;
    /// any one of them (Any) or every one (All) otherwise.
    func matches<Tags: Sequence>(_ itemTags: Tags) -> Bool where Tags.Element == String {
        guard !tags.isEmpty else { return true }
        let carried = Set(itemTags)
        switch match {
        case .any: return tags.contains(where: carried.contains)
        case .all: return tags.allSatisfy(carried.contains)
        }
    }

    /// A click on a pill: All (nil) clears every pick; a picked tag leaves
    /// the pick; another tag joins it.
    func toggling(_ tag: String?) -> TagPicks {
        guard let tag else { return .none }
        if tags.contains(tag) { return TagPicks(tags.filter { $0 != tag }, match: match) }
        return TagPicks(tags + [tag], match: match)
    }

    func matching(_ match: Match) -> TagPicks { TagPicks(tags, match: match) }

    /// A rename or merge: every source becomes the target, once.
    func renaming(_ sources: Set<String>, to target: String) -> TagPicks {
        guard tags.contains(where: sources.contains) else { return self }
        return TagPicks(tags.map { sources.contains($0) ? target : $0 }, match: match)
    }

    /// Gone tags drop out of the pick one by one (today's rule, per tag);
    /// with none left the filter ends.
    func keeping(_ available: some Sequence<String>) -> TagPicks {
        let available = Set(available)
        guard !tags.allSatisfy(available.contains) else { return self }
        return TagPicks(tags.filter(available.contains), match: match)
    }

    /// The word between two tags: "or" for Any, "and" for All.
    var joiner: String {
        match == .any ? String(localized: "or", comment: "Between picked tags: a task with any of them shows")
            : String(localized: "and", comment: "Between picked tags: a task with every one of them shows")
    }

    /// "#work or #home" (or "and"); with more than two, "#a, #b or #c".
    var phrase: String { phrase(title: { "#" + $0 }) }

    /// What VoiceOver hears: the same words without the marks.
    var spokenPhrase: String { phrase(title: { $0 }) }

    private func phrase(title: (String) -> String) -> String {
        let words = tags.map(title)
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " \(joiner) " + words[words.count - 1]
    }

    /// The phrase as pieces, for drawing each tag in its own colour.
    var phraseParts: [TagPhrasePart] {
        var parts: [TagPhrasePart] = []
        for (index, tag) in tags.enumerated() {
            if index > 0 {
                parts.append(.text(index == tags.count - 1 ? " \(joiner) " : ", "))
            }
            parts.append(.tag(tag))
        }
        return parts
    }
}

/// A piece of a filter's words: plain text, or a tag drawn in its colour.
enum TagPhrasePart: Hashable, Sendable {
    case text(String)
    case tag(String)

    var plain: String {
        switch self {
        case let .text(text): text
        case let .tag(tag): "#" + tag
        }
    }
}
