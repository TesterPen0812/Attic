import Foundation

/// A small lexical tokenizer. Language differences are data; the scanner
/// visits only the supplied block and never touches the note or saved marks.
enum NoteSyntaxHighlighter {
    private struct Language {
        var keywords: Set<String> = []
        var literals: Set<String> = ["true", "false", "null", "nil", "None", "True", "False"]
        var builtins: Set<String> = []
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var strings: [String] = ["\"", "'"]
        var operators = "{}[]()=+-*/<>!&|:;,.?"
        var caseInsensitive = false
        var linePrefixes: [(String, NoteSyntaxToken)] = []
        init(_ words: String = "", builtins: String = "", line: [String] = [], block: [(String, String)] = [], strings: [String] = ["\"", "'"], insensitive: Bool = false, prefixes: [(String, NoteSyntaxToken)] = []) {
            keywords = Set(words.split(separator: " ").map(String.init))
            self.builtins = Set(builtins.split(separator: " ").map(String.init))
            lineComments = line; blockComments = block; self.strings = strings
            caseInsensitive = insensitive; linePrefixes = prefixes
        }
    }

    private static let languages: [String: Language] = [
        "javascript": Language("const let var function return if else for while do switch case break continue class extends new import export default from async await try catch finally throw typeof instanceof in of this super delete void yield", builtins: "console log Math JSON Array Object String Number Boolean Promise Date Map Set", line: ["//"], block: [("/*", "*/")], strings: ["`", "\"", "'"]),
        "typescript": Language("const let var function return if else for while do switch case break continue class extends new import export default from async await try catch finally throw typeof instanceof in of this super interface type enum namespace public private protected readonly as implements declare keyof infer never unknown any string number boolean", builtins: "console log Math JSON Array Object String Number Boolean Promise Date Map Set", line: ["//"], block: [("/*", "*/")], strings: ["`", "\"", "'"]),
        "json": Language(strings: ["\""]),
        "swift": Language("let var func return if else guard for while repeat switch case default break continue struct class enum protocol extension import public private internal fileprivate open static final override mutating nonmutating init deinit self Self super try catch throw throws rethrows async await actor isolated nonisolated some any in where as is defer associatedtype typealias", builtins: "String Int Double Float Bool Array Dictionary Set Optional print Task Date URL", line: ["//"], block: [("/*", "*/")], strings: ["\"\"\"", "\""]),
        "python": Language("def class return if elif else for while break continue import from as try except finally raise with yield async await lambda pass global nonlocal del assert and or not in is", builtins: "print len range str int float bool list dict set tuple object self super", line: ["#"], strings: ["\"\"\"", "'''", "\"", "'"]),
        "shell": Language("if then else elif fi for while do done case esac function in until select export local readonly return", builtins: "echo printf cd pwd read source exit test", line: ["#"], strings: ["\"", "'", "`"]),
        "html": Language("DOCTYPE html head body div span a p h1 h2 h3 script style link meta img input button table tr th td", block: [("<!--", "-->")]),
        "css": Language("important media supports keyframes import charset layer font-face from to", block: [("/*", "*/")]),
        "sql": Language("select from where insert into values update set delete create table alter drop join inner left right outer on as order by group having limit offset union all distinct case when then else end and or not in is like between exists null primary key foreign references index begin commit rollback", builtins: "count sum avg min max coalesce cast", line: ["--"], block: [("/*", "*/")], insensitive: true),
        "yaml": Language(line: ["#"]),
        "diff": Language(strings: [], prefixes: [("+++", .plain), ("---", .plain), ("@@", .keyword), ("+", .added), ("-", .removed)]),
        "mermaid": Language("flowchart graph subgraph end direction LR RL TB TD BT sequenceDiagram participant actor loop alt else opt par and rect note over left right classDiagram class stateDiagram state erDiagram gantt pie journey gitGraph", line: ["%%"])
    ]

    static func tokens(in text: String, language: String?) -> [(NSRange, NoteSyntaxToken)] {
        guard let language, let syntax = languages[language] else { return [] }
        let units = Array(text.utf16)
        var tokens: [(NSRange, NoteSyntaxToken)] = []
        var index = 0
        func matches(_ value: String, at offset: Int) -> Bool {
            let pattern = Array(value.utf16)
            guard offset + pattern.count <= units.count else { return false }
            return units[offset..<(offset + pattern.count)].elementsEqual(pattern)
        }
        func whitespace(_ value: UInt16) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
        func word(_ value: UInt16) -> Bool { (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 95 || value == 36 || value > 127 }
        func nextNonspace(_ at: Int) -> Int { var next = at; while next < units.count, whitespace(units[next]) { next += 1 }; return next }
        func append(_ start: Int, _ end: Int, _ kind: NoteSyntaxToken) {
            guard end > start else { return }
            tokens.append((NSRange(location: start, length: end - start), kind))
        }
        while index < units.count {
            let start = index
            if index == 0 || units[index - 1] == 10,
               let prefix = syntax.linePrefixes.first(where: { matches($0.0, at: index) }) {
                while index < units.count, units[index] != 10 { index += 1 }
                append(start, index, prefix.1); continue
            }
            if let comment = syntax.lineComments.first(where: { matches($0, at: index) }) {
                index += comment.utf16.count
                while index < units.count, units[index] != 10 { index += 1 }
                append(start, index, .comment); continue
            }
            if let comment = syntax.blockComments.first(where: { matches($0.0, at: index) }) {
                index += comment.0.utf16.count
                while index < units.count, !matches(comment.1, at: index) { index += 1 }
                index = min(units.count, index + comment.1.utf16.count)
                append(start, index, .comment); continue
            }
            if let delimiter = syntax.strings.first(where: { matches($0, at: index) }) {
                index += delimiter.utf16.count
                while index < units.count {
                    if units[index] == 92 { index = min(units.count, index + 2); continue }
                    if matches(delimiter, at: index) {
                        index += delimiter.utf16.count
                        // SQL's doubled quote is part of the same string.
                        if language == "sql", matches(delimiter, at: index) { index += delimiter.utf16.count; continue }
                        break
                    }
                    index += 1
                }
                let after = nextNonspace(index)
                append(start, index, after < units.count && units[after] == 58 ? .property : .string); continue
            }
            if (48...57).contains(units[index]) {
                index += 1
                while index < units.count {
                    let value = units[index]
                    if (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) || value == 46 || value == 120 || value == 88 || value == 95 { index += 1 }
                    else if (value == 43 || value == 45) && index > start && (units[index - 1] == 101 || units[index - 1] == 69) { index += 1 }
                    else { break }
                }
                append(start, index, .literal); continue
            }
            if word(units[index]) {
                index += 1
                while index < units.count, word(units[index]) || ((language == "css" || language == "yaml") && units[index] == 45) { index += 1 }
                var value = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                if syntax.caseInsensitive { value = value.lowercased() }
                let after = nextNonspace(index)
                let kind: NoteSyntaxToken
                if syntax.keywords.contains(value) { kind = .keyword }
                else if syntax.literals.contains(value) { kind = .literal }
                else if after < units.count, units[after] == 58 { kind = .property }
                else if syntax.builtins.contains(value) || (after < units.count && units[after] == 40) { kind = .function }
                else { kind = .plain }
                append(start, index, kind); continue
            }
            index += 1
            if syntax.operators.utf16.contains(units[start]) { append(start, index, language == "mermaid" ? .operator : .plain) }
        }
        return tokens
    }
}

/// Relative ranges remain warm when another paragraph shifts a block's
/// position. Bound both entries and retained bytes, keeping one large block
/// warm rather than re-tokenizing it on every frame.
struct NoteSyntaxCache {
    private struct Key: Hashable { var language: String?; var text: String }
    private struct Entry { var tokens: [(NSRange, NoteSyntaxToken)]; var use: UInt64; var bytes: Int }
    private var entries: [Key: Entry] = [:]
    private var retainedBytes = 0
    private var generation: UInt64 = 0

    mutating func tokens(in text: String, language: String?) -> (tokens: [(NSRange, NoteSyntaxToken)], scanned: Int) {
        generation &+= 1
        let key = Key(language: language, text: text)
        if var entry = entries[key] {
            entry.use = generation; entries[key] = entry
            return (entry.tokens, 0)
        }
        let tokens = NoteSyntaxHighlighter.tokens(in: text, language: language)
        let count = (text as NSString).length
        let bytes = count * 2 + tokens.count * MemoryLayout<(NSRange, NoteSyntaxToken)>.stride
        entries[key] = Entry(tokens: tokens, use: generation, bytes: bytes)
        retainedBytes += bytes
        while entries.count > 32 || (retainedBytes > 2 * 1024 * 1024 && entries.count > 1) {
            guard let oldest = entries.min(by: { $0.value.use < $1.value.use }) else { break }
            retainedBytes -= oldest.value.bytes; entries[oldest.key] = nil
        }
        return (tokens, count)
    }
}
