import AppKit
import SwiftUI

// The Reminders replica (owner, 2026-10-25: "Reminders replica first, then
// adapt"): a second look for Tasks' lists, behind Settings › Appearance ›
// Lists › List Style. Attic's own code on Attic's own data; every value
// below comes from the Reminders study (`~/Projects/reminders-study/docs`)
// and carries its class and Evidence ID. The values table is
// `phaseX/reminders-study/replica-r1-values.md`.

/// How Tasks' lists draw. Attic (the default) is unchanged; the replica
/// changes rows, adding, the row menu, a few keys and how a completed row
/// leaves.
enum TasksListStyle: String, CaseIterable, Identifiable, Sendable {
    case attic
    case reminders
    case new // TEMP-B: Build A owns this case; dropped before merging A.

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attic: String(localized: "Attic")
        case .reminders: String(localized: "Reminders (replica)")
        case .new: "New" // TEMP-B
        }
    }

    var isReplica: Bool { self == .reminders }
}

extension EnvironmentValues {
    /// The lists' style (Settings › Appearance › Lists).
    @Entry var atticTasksListStyle: TasksListStyle = .attic
}

// MARK: - Metrics

/// The replica row's geometry and type. M = Measured, C = Confirmed
/// (code or resource), E = Estimated (closest measured evidence).
enum RemindersReplicaMetrics {
    // Type (UI-ROW-02, RES-IB-002).
    /// M: title 13 pt SF Rounded Regular.
    static let titleSize: CGFloat = 13
    /// M: a parent with subtasks 13 pt Semibold (seen expanded; E for a
    /// collapsed parent).
    static let parentWeight: Font.Weight = .semibold
    /// M: notes 12 pt Rounded, secondary ink (C: `secondaryLabelColor`).
    static let notesSize: CGFloat = 12
    /// M: the date line 12 pt Rounded (UI-GEO-01).
    static let dateSize: CGFloat = 12

    // Vertical (UI-ROW-01/03).
    /// M: the title's top 7 pt below the row's top.
    static let titleTop: CGFloat = 7
    /// M: one title line's box 18 pt; two lines 34 pt, so each further
    /// line adds 16.
    static let titleFirstLine: CGFloat = 18
    static let titleLinePitch: CGFloat = 16
    /// M: the date line 17 pt, starting 1 pt inside the title's box (40 pt
    /// into a 64 pt row whose title box ends at 41).
    static let dateLineHeight: CGFloat = 17
    static let dateOverlap: CGFloat = 1
    /// M: 7 pt below the last line (32 = 7 + 18 + 7; 48 = 7 + 18 − 1 + 17 + 7).
    static let bottomInset: CGFloat = 7
    /// C: the notes field's minimum height 16 pt (RES-IB-002).
    static let notesMinHeight: CGFloat = 16
    /// M: the notes box is 15 pt a line plus 2, at least 18 (one line 18,
    /// two 32, four 62, five 77, eight 122: UI-GEO-01 rows 20, 12, 6, 21,
    /// 22); notes start 1 pt inside the title's box.
    static let notesFirstLine: CGFloat = 18
    static let notesLinePitch: CGFloat = 15
    /// E: at most eight notes lines (no cap established; the tallest
    /// measured notes box is 122 pt, about eight lines, UI-GEO-01 row 22).
    static let notesLineLimit = 8

    // Horizontal (UI-ROW-04, RES-IB-003).
    /// M: the title 45 pt in from the row's start (x 265 against x 220).
    static let titleX: CGFloat = 45
    /// C: the completion control's frame 15 × 15 pt (RES-IB-001).
    static let circleFrame: CGFloat = 15
    /// M (capture pixels, IMG-INITIAL and run2-16 at 1x): the ring 16.5 pt
    /// across its outer edge, its centre 25.25 pt from the row's start and
    /// 15.5 pt below its top; a completed circle's solid centre 11.5 pt
    /// across inside a 1 pt light gap. E: the ring's ink 1.25 pt (from its
    /// edge coverage; R2-F01 says 1–2 pt).
    static let circleDiameter: CGFloat = 16.5
    static let circleStroke: CGFloat = 1.25
    static let completedFill: CGFloat = 11.5
    static let circleCentreX: CGFloat = 25.25
    static let circleCentreY: CGFloat = 15.5
    /// C: 10 pt from the control's trailing edge to the text stack
    /// (RES-IB-003).
    static let circleToText: CGFloat = 10
    static var circleX: CGFloat { circleCentreX - circleFrame / 2 }
    /// M (capture pixels): the text's ink starts 1 pt inside its field
    /// (title, notes and date at 46 against the field's 45).
    static let textInset: CGFloat = 1
    /// M: a child's circle and title 30 pt further in (UI-ROW-04; the
    /// archive's 20 pt outline indent, RES-IB-004, is not the live offset).
    static let childIndent: CGFloat = 30
    /// C: 9 pt trailing spacing (RES-IB-003).
    static let trailingInset: CGFloat = 9
    /// M: the title stops 49 pt before the row's end (room for the info
    /// button), notes and the date line 14 pt before it; the info button's
    /// 22 pt region ends 14 pt before it (UI-GEO-01 rows 7–22).
    static let titleTrailing: CGFloat = 49
    static let notesTrailing: CGFloat = 14
    static let infoTrailing: CGFloat = 14
    static let infoRegion: CGFloat = 22
    /// M: a tag on the date line 6 pt after the date (UI-GEO-01 row 12).
    static let dateToTag: CGFloat = 6
    /// E: the gap from a priority mark to the title (one space).
    static let priorityGap = " "

    // Selection (RES-FS-003, Confirmed resource values, default
    // appearance): black at 8 % focused, 5 % unfocused, 5 % in a window
    // that is not key. Rounded (R2-F09, Measured); E: radius and inset.
    static let focusedSelection = AtticRGBA(red: 0, green: 0, blue: 0, alpha: 0.08)
    static let unfocusedSelection = AtticRGBA(red: 0, green: 0, blue: 0, alpha: 0.05)
    static let nonKeySelection = AtticRGBA(red: 0, green: 0, blue: 0, alpha: 0.05)
    static let selectionRadius: CGFloat = 6
    static let selectionInset: CGFloat = 8

    // Colours. C: list blue (0, 0.478, 1), the system blue (RES-FS-004);
    // C: the tag token (0.361, 0.482, 0.675) (RES-FS-004,
    // `hashtagTokenTextColor`).
    static let listBlue = Color(nsColor: .systemBlue)
    static let tagInk = Color(red: 0.361, green: 0.482, blue: 0.675)
    static let tagNSColor = NSColor(srgbRed: 0.361, green: 0.482, blue: 0.675, alpha: 1)
    /// E: the open ring's grey (only "grey ring" observed).
    static let openRing = Color(nsColor: .tertiaryLabelColor)
    /// E: the info button and disclosure (no isolated measurement).
    static let infoSize: CGFloat = 15
    static let disclosureSize: CGFloat = 11

    /// The row's height for its content (M: 32 plain, 48 with a date, 64
    /// with a wrapped title and a date; the rest grows by the same rule).
    static func rowHeight(titleLines: Int, notesLines: Int, hasDateLine: Bool) -> CGFloat {
        var height = titleTop + titleFirstLine + CGFloat(max(titleLines, 1) - 1) * titleLinePitch
        if notesLines > 0 {
            height += notesBox(lines: notesLines) - dateOverlap
        }
        if hasDateLine { height += dateLineHeight - dateOverlap }
        return height + bottomInset
    }

    static func notesBox(lines: Int) -> CGFloat {
        max(notesFirstLine, CGFloat(lines) * notesLinePitch + 2)
    }

    static var titleFont: NSFont { rounded(size: titleSize, weight: .regular) }
    static var parentTitleFont: NSFont { rounded(size: titleSize, weight: .semibold) }
    static var notesFont: NSFont { rounded(size: notesSize, weight: .regular) }

    static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}

// MARK: - Row text

/// What a replica row says, built from Attic's row model (pure, tested).
enum RemindersReplicaText {
    /// M: `!`, `!!`, `!!!` before the title for low, medium and high
    /// (UI-ROW-06, R2-12). Attic's four priorities map one to one.
    static func priorityMark(_ priority: AtticPriority) -> String? {
        switch priority {
        case .none: nil
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }

    enum DateTone: Equatable { case quiet, overdue }

    /// The date line's text. M: Today, Tomorrow and Yesterday in words,
    /// otherwise the numeric day/month/year (R2-01, R2-03's 30/10/2026);
    /// overdue in red, an all-day Today quiet (UI-ROW-06). Attic's dates
    /// are all-day, so there is never a time.
    static func dateLine(_ day: DueDay, today: DueDay, calendar: Calendar, locale: Locale) -> (text: String, tone: DateTone) {
        let gregorian = DueDay.storageCalendar(matching: calendar)
        guard let start = day.startDate(in: gregorian), let now = today.startDate(in: gregorian),
              let offset = gregorian.dateComponents([.day], from: now, to: start).day else {
            return (day.rawValue, .quiet)
        }
        switch offset {
        case 0: return (String(localized: "Today"), .quiet)
        case 1: return (String(localized: "Tomorrow"), .quiet)
        case -1: return (String(localized: "Yesterday"), .overdue)
        default:
            let formatter = DateFormatter()
            formatter.calendar = gregorian
            formatter.timeZone = gregorian.timeZone
            formatter.locale = locale
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return (formatter.string(from: start), offset < 0 ? .overdue : .quiet)
        }
    }

    /// The notes preview from an item's writing: its derived plain text
    /// without the first line (the title), blank lines dropped (one-item
    /// rules: the writing belongs to the item; the row only previews it).
    static func notesPreview(plainText: String) -> String? {
        var lines = plainText.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }
        lines.removeFirst()
        let kept = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        return kept.prefix(RemindersReplicaMetrics.notesLineLimit * 2).joined(separator: "\n")
    }
}

// MARK: - The new-reminder row's draft

/// The new-reminder row's text. Recognition and acceptance are separate
/// (C + M, R3-007/010, R2-02/03): a date in the words is highlighted and
/// offered; only accepting it sets the date and takes its words (and one
/// boundary space, C: U+0020) out of the title. Unaccepted words stay.
/// `#tag` becomes a real Attic tag on Return (M, R2-04); nothing about
/// tags is decided while an input method is composing (C, R3-036).
struct RemindersReplicaDraft: Equatable {
    var text = ""
    /// The date accepted from the suggestion.
    var acceptedDay: DueDay?
    /// An input method is composing (marked text): tags wait.
    var isComposing = false

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The first date in the words, while none has been accepted.
    func recognisedDate(parser: TaskTextParser) -> (range: NSRange, day: DueDay)? {
        guard acceptedDay == nil, !isComposing else { return nil }
        for token in parser.parse(text).tokens {
            if case let .dueDay(day) = token.value { return (token.utf16Range(in: text), day) }
        }
        return nil
    }

    /// The `#tag` pieces (empty while composing).
    func tagPieces(parser: TaskTextParser) -> [(range: NSRange, tag: String)] {
        guard !isComposing else { return [] }
        return parser.parse(text).tokens.compactMap { token in
            if case let .tag(tag) = token.value { (token.utf16Range(in: text), tag) } else { nil }
        }
    }

    /// The ranges drawn in blue: the offered date and the tags.
    func highlights(parser: TaskTextParser) -> [NSRange] {
        var ranges = tagPieces(parser: parser).map(\.range)
        if let date = recognisedDate(parser: parser) { ranges.append(date.range) }
        return ranges.sorted { $0.location < $1.location }
    }

    /// Accepts the offered date: the day is set and its words leave the
    /// title with one adjacent ASCII space. Returns the edit made, or nil.
    @discardableResult
    mutating func acceptDate(parser: TaskTextParser) -> (range: NSRange, day: DueDay)? {
        guard let found = recognisedDate(parser: parser) else { return nil }
        let ns = text as NSString
        var range = found.range
        let space: unichar = 0x20
        if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == space {
            range.length += 1
        } else if range.location > 0, ns.character(at: range.location - 1) == space {
            range.location -= 1
            range.length += 1
        }
        text = ns.replacingCharacters(in: range, with: "")
        acceptedDay = found.day
        return (range, found.day)
    }

    /// The task Return makes, or nil for a blank row (it is reused). The
    /// tags leave the title (Attic keeps tags beside the title; the row
    /// draws them as tokens after it); unaccepted date words stay.
    func taskDraft(parser: TaskTextParser, status: TaskStatus) -> TaskDraft? {
        guard !isBlank else { return nil }
        let pieces = tagPieces(parser: parser)
        let ns = NSMutableString(string: text)
        for piece in pieces.reversed() { ns.replaceCharacters(in: piece.range, with: "") }
        var title = TaskDraftBuilder.collapsed(ns as String)
        if title.isEmpty { title = TaskDraftBuilder.collapsed(text) }
        var tags: [String] = []
        for piece in pieces where !tags.contains(where: { $0.caseInsensitiveCompare(piece.tag) == .orderedSame }) {
            tags.append(piece.tag)
        }
        var draft = TaskDraft(title: title, tags: tags, dueDay: acceptedDay, priority: .none, status: status, parentID: nil)
        // M: a new reminder lands below the rows (CUA2-01/03).
        draft.placesAtEnd = true
        return draft
    }
}

// MARK: - Menu

/// The row's right-click menu in Reminders' measured single-leaf order
/// (M, CUA2-10, R2-07), each mapped to Attic's command or left out.
enum RemindersReplicaMenu {
    enum Measured: String, CaseIterable {
        case askSiri, markCompleted, deadline, markUrgent, indent, outdent, newSection, newSectionWithSelection,
             editSections, flag, priority, list, tags, cut, copy, paste, delete
    }

    /// Attic's commands, as the replica's menu offers them.
    enum Command: String, Equatable, CaseIterable {
        case showInfo, complete, date, flag, priority, list, tags, copy, removeFromTasks, delete
    }

    /// What each measured item becomes; nil: left out, with the reason.
    static func mapping(_ item: Measured) -> (command: Command?, leftOut: String?) {
        switch item {
        case .askSiri: (nil, "Siri suggestions field: no Attic equivalent")
        case .markCompleted: (.complete, nil)
        case .deadline: (.date, nil)
        case .markUrgent: (nil, "Urgent: Attic has no storage for it")
        case .indent: (nil, "Indent: Attic has no command that makes a task another's subtask (Tab says so)")
        case .outdent: (nil, "Outdent: disabled for a task in Reminders too; ⇧Tab makes a clicked subtask a task (Make Standalone Task)")
        case .newSection, .newSectionWithSelection, .editSections: (nil, "Sections: Attic has no storage for them")
        case .flag: (.flag, nil)
        case .priority: (.priority, nil)
        case .list: (.list, nil)
        case .tags: (.tags, nil)
        case .cut: (nil, "Cut: Attic's tasks have Copy and Duplicate, no Cut")
        case .copy: (.copy, nil)
        case .paste: (nil, "Paste: Attic pastes tasks into the add bar, not onto a row")
        case .delete: (.delete, nil)
        }
    }

    /// The replica's menu in order. Phase 3's Remove from Tasks goes just
    /// before Delete, where Attic's own menu keeps it.
    static func commands(removeFromTasks: Bool) -> [Command] {
        // R2: Show Info first (Reminders keeps it in its File menu, R2-05;
        // Attic has no menu bar).
        var list: [Command] = [.showInfo]
        for item in Measured.allCases {
            guard let command = mapping(item).command else { continue }
            if command == .delete, removeFromTasks { list.append(.removeFromTasks) }
            list.append(command)
        }
        return list
    }

    /// The measured items left out, with why.
    static var leftOut: [(Measured, String)] {
        Measured.allCases.compactMap { item in mapping(item).leftOut.map { (item, $0) } }
    }
}

// MARK: - Keys

/// The confirmed Reminders shortcuts (C resource, RES-IB-007/008,
/// R2-STATIC-01) and what the replica does with each. Only while the
/// replica is on; a key Attic already uses for something else stays
/// Attic's and is listed as a clash.
enum RemindersReplicaKeys {
    enum Command: Equatable { case newReminder, showInfo, complete, addTag }

    struct Entry {
        let keys: String
        let meaning: String
        let command: Command?
        /// Why it is not taken (a clash or no Attic equivalent).
        let note: String?
    }

    static let table: [Entry] = [
        Entry(keys: "⌘N", meaning: "New Reminder", command: .newReminder, note: nil),
        Entry(keys: "⌘I", meaning: "Show Info", command: .showInfo, note: nil),
        Entry(keys: "⇧⌘C", meaning: "Mark as Completed", command: .complete, note: nil),
        Entry(keys: "⇧⌘T", meaning: "Add Tag", command: .addTag, note: nil),
        Entry(keys: "⌘F", meaning: "Search", command: nil, note: "Already Attic's Find on Now and Later: kept"),
        Entry(keys: "⌘Z / ⇧⌘Z", meaning: "Undo / Redo", command: nil, note: "Already Attic's history: kept"),
        Entry(keys: "⌘A", meaning: "Select All", command: nil, note: "Already Attic's: kept"),
        Entry(keys: "⌘] / ⌘[", meaning: "Indent / Outdent", command: nil, note: "Left out: Tab and ⇧Tab do what Attic can (R2)"),
        Entry(keys: "⇧⌘F", meaning: "Flag", command: nil, note: "Clash: Attic's Search Done Tasks (kept); Flag is in the menu and the panel"),
        Entry(keys: "⇧⌘H", meaning: "Show Completed", command: nil, note: "Left out of R1 (lists are R4)"),
        Entry(keys: "⌥⌘N / ⌃⌘N", meaning: "New Section / with Selection", command: nil, note: "Left out: no sections"),
    ]

    /// The replica's command for a key press, or nil.
    static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        let relevant = modifiers.intersection([.command, .shift, .option, .control])
        let key = characters?.lowercased()
        // Letters by their character, with the ANSI key code as a fallback
        // for layouts whose ⌘-characters differ.
        func isKey(_ letter: String, _ code: UInt16) -> Bool { key == letter || keyCode == code }
        if relevant == .command {
            if isKey("n", 45) { return .newReminder }
            if isKey("i", 34) { return .showInfo }
        }
        if relevant == [.command, .shift] {
            if isKey("c", 8) { return .complete }
            if isKey("t", 17) { return .addTag }
        }
        return nil
    }
}
