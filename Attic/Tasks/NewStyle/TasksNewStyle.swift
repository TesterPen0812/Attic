import AppKit
import SwiftUI

// List Style: New (owner, 2026-10-26: "Main page direction: D2 'Choose your
// Now'" and its six detail picks). The council's spec is
// `phaseX/council-main-page/final/FINAL.md`; values come from its drafts
// (`council-lib.js`), built natively. Only drawn while Settings › Appearance
// › Lists › List Style is New.

// MARK: - Metrics

/// The New row's geometry, measured from the row's leading edge (the
/// panel's edge, as the replica's are). Draft values unless noted.
enum TasksNewMetrics {
    /// The fills sit 8 pt in from the list's edges, 2 pt in from the row's
    /// top and bottom (2 pt gaps between neighbours), radius 10 (§ 2.9).
    static let fillInsetX: CGFloat = 8
    static let fillInsetY: CGFloat = 2
    static let fillRadius: CGFloat = 10
    /// Keyboard focus: a 1.5 pt outline (§ 2.9).
    static let focusWidth: CGFloat = 1.5

    /// The ring: 18 pt, 1.5 pt stroke, a 24 pt hit area, its centre 26 pt
    /// in and 16 pt down (§ 2.7; the draft's 8 + 9 + 9).
    static let ringSize: CGFloat = 18
    static let ringStroke: CGFloat = 1.5
    static let ringHit: CGFloat = 24
    static let ringCentreX: CGFloat = 26
    static let ringCentreY: CGFloat = 16
    /// The in-progress centre dot (the draft's 0.18 of the ring's size as a
    /// radius).
    static let progressDot: CGFloat = 6.5

    /// The title: 13 pt SF Pro Regular, its box 46 pt in and 7 pt down,
    /// 18 pt a line (§ 2.2); a further line adds 16.
    static let titleSize: CGFloat = 13
    static let titleX: CGFloat = 46
    static let titleTop: CGFloat = 7
    static let titleLine: CGFloat = 18
    static let titleLinePitch: CGFloat = 16
    /// At most this many title lines; a longer title truncates before its
    /// priority marks (which never truncate).
    static let titleLineLimit = 3
    /// Priority marks 5 pt after the title, weight 700 (§ 2.3).
    static let marksGap: CGFloat = 5

    /// Line 2: 12 pt, 16 pt tall, its top 26 pt down; its pieces 9 pt
    /// apart (§ 2.1).
    static let detailsSize: CGFloat = 12
    static let detailsTop: CGFloat = 26
    static let detailsLine: CGFloat = 16
    static let detailsGap: CGFloat = 9
    /// The marks on line 2 (`doc.text`, `photo`, the subtask box): 11 pt.
    static let markSize: CGFloat = 11
    /// At most two tags, then "+N" (§ 2.6).
    static let tagLimit = 2

    /// The column that takes turns (D1): 72 pt, reserved on every row,
    /// ending 16 pt before the row's end, 5 pt down, 24 pt tall. Titles
    /// stop 8 pt before it.
    static let columnWidth: CGFloat = 72
    static let columnTrailing: CGFloat = 16
    static let columnTop: CGFloat = 5
    static let columnHeight: CGFloat = 24
    static let columnGap: CGFloat = 8
    /// Where the title and line 2 stop, from the row's end.
    static var textTrailing: CGFloat { columnTrailing + columnWidth + columnGap }

    /// The column's buttons: 22 pt squares, radius 7, 1 pt apart.
    static let slotButton: CGFloat = 22
    static let slotRadius: CGFloat = 7
    static let slotSpacing: CGFloat = 1
    static let slotGlyph: CGFloat = 13
    /// Undo: a 22 pt capsule, 9 pt padding, 12 pt semibold.
    static let undoHeight: CGFloat = 22
    static let undoPadding: CGFloat = 9

    /// Rows are 32 pt, or 48 with line 2 (§ 2.1); a wrapped title adds 16
    /// a line.
    static func rowHeight(titleLines: Int, hasDetails: Bool) -> CGFloat {
        let one: CGFloat = hasDetails ? 48 : 32
        return one + CGFloat(max(titleLines, 1) - 1) * titleLinePitch
    }

    /// A subtask under its open parent: 30 pt, a 16 pt ring (1.4 stroke)
    /// at the parent's title edge, the title 26 pt further in.
    static let childHeight: CGFloat = 30
    static let childRingSize: CGFloat = 16
    static let childRingStroke: CGFloat = 1.4
    static let childRingX: CGFloat = 46
    static let childTitleX: CGFloat = 72

    /// The one-line header (1A): 28 pt round controls, the list 10 pt
    /// under them (the draft's 14 + 28 + 10 = 52).
    static let headerControl: CGFloat = 28
    static let headerToList: CGFloat = 10
    static let headerSpacing: CGFloat = 8

    /// The add bar on the row grid (§ 2.11): the plus centred at x 26, the
    /// text at x 46, in the panel's coordinates.
    static let addPlusCentreX: CGFloat = 26
    static let addTextX: CGFloat = 46
}

// MARK: - Inks made for glass (§ 2.5)

/// Deeper inks for glass, light and dark. Blue only for actions.
enum TasksNewInk {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } == true ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let red = dynamic(light: rgb(0xA3160E), dark: rgb(0xFF6961))
    static let accent = dynamic(light: rgb(0x094CA6), dark: rgb(0x64A8FF))
    static let orange = dynamic(light: rgb(0xA33A00), dark: rgb(0xFF9F0A))
    static let secondary = dynamic(light: NSColor(white: 0, alpha: 0.56), dark: NSColor(white: 1, alpha: 0.60))
    static let tertiary = dynamic(light: NSColor(white: 0, alpha: 0.38), dark: NSColor(white: 1, alpha: 0.40))
    static let label = Color(nsColor: .labelColor)
    /// The ring: 42 % black, its dark equivalent 46 % white (the draft's).
    static let ring = dynamic(light: NSColor(white: 0, alpha: 0.42), dark: NSColor(white: 1, alpha: 0.46))
    /// A done ring's fill (the draft's accent fill).
    static let doneFill = dynamic(light: rgb(0x0A64D6), dark: rgb(0x0A84FF))
    /// Hover 40 % white (dark: 9 % white, the draft's).
    static let hover = dynamic(light: NSColor(white: 1, alpha: 0.40), dark: NSColor(white: 1, alpha: 0.09))
    /// Selection: a 15 % accent fill (dark 24 %), or 10 % grey when the
    /// list isn't focused.
    static let selection = dynamic(light: rgb(0x0A64D6, 0.15), dark: rgb(0x64A8FF, 0.24))
    static let selectionUnfocused = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.10))
    /// Keyboard focus outline.
    static let focus = dynamic(light: rgb(0x0A64D6, 0.75), dark: rgb(0x64A8FF, 0.85))
    /// The column's buttons' fill.
    static let slotFill = dynamic(light: NSColor(white: 0, alpha: 0.065), dark: NSColor(white: 1, alpha: 0.11))
    /// The pinned pin's tint.
    static let pinTint = dynamic(light: rgb(0x0A64D6, 0.18), dark: rgb(0x64A8FF, 0.28))
}

// MARK: - Row text (pure, tested)

enum TasksNewText {
    enum Tone: Equatable { case quiet, today, overdue }

    /// Short dates (§ 2.4): Yesterday, Today, Tomorrow; the weekday within
    /// the coming week; otherwise "3 Nov", the year only when it isn't
    /// this year; an older overdue date "Late 23 Oct". Overdue is red and
    /// semibold, Today semibold. Localised (en-GB in the drafts).
    static func shortDate(_ day: DueDay, today: DueDay, calendar: Calendar, locale: Locale) -> (text: String, tone: Tone) {
        let gregorian = DueDay.storageCalendar(matching: calendar)
        guard let start = day.startDate(in: gregorian), let now = today.startDate(in: gregorian),
              let offset = gregorian.dateComponents([.day], from: now, to: start).day else {
            return (day.rawValue, .quiet)
        }
        switch offset {
        case 0: return (String(localized: "Today"), .today)
        case 1: return (String(localized: "Tomorrow"), .quiet)
        case -1: return (String(localized: "Yesterday"), .overdue)
        case 2...6: return (format("EEE", start, gregorian, locale), .quiet)
        default:
            let sameYear = gregorian.component(.year, from: start) == gregorian.component(.year, from: now)
            let text = format(sameYear ? "dMMM" : "dMMMy", start, gregorian, locale)
            return offset < 0 ? (String(localized: "Late \(text)"), .overdue) : (text, .quiet)
        }
    }

    nonisolated(unsafe) private static let formatters = NSCache<NSString, DateFormatter>()

    private static func format(_ template: String, _ date: Date, _ calendar: Calendar, _ locale: Locale) -> String {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)" as NSString
        let formatter: DateFormatter
        if let cached = formatters.object(forKey: key) {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters.setObject(formatter, forKey: key)
        }
        return formatter.string(from: date)
    }

    /// `!` to `!!!` after the title (2A).
    static func priorityMarks(_ priority: AtticPriority) -> String? {
        switch priority {
        case .none: nil
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }

    /// At most two tags, then how many more (§ 2.6).
    static func tags(_ tags: [String]) -> (shown: [String], more: Int) {
        (Array(tags.prefix(TasksNewMetrics.tagLimit)), max(0, tags.count - TasksNewMetrics.tagLimit))
    }

    /// What VoiceOver reads for a New row: Attic's description, plus the
    /// flag, photos and progress the marks show (§ 2.16).
    static func accessibilityDescription(_ model: AtticTaskRowModel, date: String?) -> String {
        var parts = [model.title, model.state.spokenName]
        if let spoken = model.priority.spokenName { parts.append(spoken) }
        if let date { parts.append(String(localized: "due \(date)")) }
        if model.flagged { parts.append(String(localized: "flagged")) }
        if !model.tags.isEmpty { parts.append(String(localized: "tagged \(model.tags.joined(separator: ", "))")) }
        if let subtasks = model.subtasks { parts.append(String(localized: "\(subtasks.done) of \(subtasks.total) subtasks done")) }
        if model.hasPage { parts.append(String(localized: "has writing")) }
        if model.photos > 0 {
            parts.append(model.photos == 1 ? String(localized: "1 photo") : String(localized: "\(model.photos) photos"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The column that takes turns (D1, pick 4A)

/// What the 72 pt column shows. Paint only: its frame never changes.
enum TasksNewColumn: Equatable {
    case empty
    case date
    /// Date · Move · ⓘ.
    case actions
    /// Just ticked: Undo, until the panel closes or the list changes.
    case undo

    static func resolve(isDone: Bool, isKept: Bool, isHovered: Bool, isKeyboardSelected: Bool,
                        hasDate: Bool, actionsAvailable: Bool) -> Self {
        if isDone { return isKept ? .undo : .empty }
        if actionsAvailable, isHovered || isKeyboardSelected { return .actions }
        return hasDate ? .date : .empty
    }
}

// MARK: - The bottom of the page takes turns (§ 2.15, pick 6B)

enum TasksNewBottom: Equatable {
    case addBar
    /// Several tasks selected: the selection bar in the add bar's place.
    case selectionBar
    /// The list has the keyboard and one task is selected: the single
    /// keys are live, and their strip shows where the add bar was.
    case keyStrip

    static func resolve(selectionCount: Int, listHasKeyboard: Bool, addBarFocused: Bool, onDone: Bool) -> Self {
        guard !addBarFocused, !onDone else { return .addBar }
        if selectionCount > 1 { return .selectionBar }
        if selectionCount == 1, listHasKeyboard { return .keyStrip }
        return .addBar
    }
}

// MARK: - Single keys (6B)

/// Single keys on the selected task while the list has the keyboard:
/// Space completes, D dates, L moves (to Later, or Now from Later), 1–3
/// set the priority (the same key again clears it), T tags. Never while a
/// field types.
enum TasksNewKey: Equatable {
    case complete, date, move, priority(Int), tags

    static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
        if keyCode == 49 { return .complete }
        switch characters?.lowercased() {
        case "d": return .date
        case "l": return .move
        case "t": return .tags
        case "1": return .priority(1)
        case "2": return .priority(2)
        case "3": return .priority(3)
        default: break
        }
        // ANSI key codes for layouts whose characters differ.
        switch keyCode {
        case 2: return .date
        case 37: return .move
        case 17: return .tags
        case 18: return .priority(1)
        case 19: return .priority(2)
        case 20: return .priority(3)
        default: return nil
        }
    }

    /// The priority 1, 2 or 3 sets; pressing the current one clears it.
    static func priority(_ level: Int, current: TaskPriority) -> TaskPriority {
        let chosen: TaskPriority = switch level {
        case 1: .low
        case 2: .medium
        default: .high
        }
        return chosen == current ? .none : chosen
    }

    /// The strip's labels, in the draft's order.
    static let strip: [(key: String, label: String)] = [
        (String(localized: "Space"), String(localized: "Done")),
        ("D", String(localized: "Date")),
        ("L", String(localized: "Move")),
        ("1–3", String(localized: "Priority")),
        ("T", String(localized: "Tags")),
    ]
}
