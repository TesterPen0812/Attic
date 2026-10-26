import AppKit
import SwiftUI

// The Reminders replica's detail panel (R2): what ⓘ, ⌘I and Show Info
// open instead of Attic's item page while the replica draws. Attic's own
// code on Attic's own data; every value carries its class and Evidence ID
// (`phaseX/reminders-study/replica-r2-values.md`). M = Measured, C =
// Confirmed (code or resource), E = Estimated (closest evidence).

// MARK: - Metrics

enum RemindersReplicaDetailMetrics {
    /// E: content cards 300 pt wide, 10 pt inside the pop-over's edge
    /// (R2-F04 "about 300" / "about 319"; capture px R2-08: cards at
    /// x 486–785).
    static let cardWidth: CGFloat = 300
    static let outerInset: CGFloat = 10
    static var panelWidth: CGFloat { cardWidth + outerInset * 2 }
    /// E: the expanded sampled height about 885 pt (R2-F04); taller
    /// content scrolls inside the panel (R2-F04, measured behaviour).
    static let maxHeight: CGFloat = 885
    /// E: card corners 10 pt and fill black 3 % (capture px R2-08: card
    /// 245 on a 253 surface, the corner meeting the edge ~10 pt down).
    static let cardRadius: CGFloat = 10
    static let cardFill = Color.black.opacity(0.03)
    /// E: 12 pt between adjacent cards (spec "about 12"; capture 11–15).
    static let cardGap: CGFloat = 12
    /// E: a heading's break: 32 pt from the card above to the next card,
    /// the heading's text in it (spec 24–32; capture 33).
    static let headingTop: CGFloat = 12
    static let headingBottom: CGFloat = 6
    static let headingSize: CGFloat = 11
    /// E: text 10 pt inside a card (spec "about 10").
    static let cardInset: CGFloat = 10
    /// E: a row's icon centred 21 pt in, its label 43 pt in (capture px).
    static let iconCentre: CGFloat = 21
    static let labelX: CGFloat = 43
    /// E: an ordinary row 37 pt (capture: two-row cards 73–75 pt; spec
    /// "about 38–40"); a date row with its subtitle 52 pt (capture 391–443).
    static let rowHeight: CGFloat = 37
    static let subtitledRowHeight: CGFloat = 52
    static let labelSize: CGFloat = 13
    static let subtitleSize: CGFloat = 11
    /// E: the title field 24 pt high with an 8 pt radius (capture 228–252).
    static let titleFieldHeight: CGFloat = 24
    static let titleFieldRadius: CGFloat = 8
    /// C: the detail's thumbnail box 29 × 29, cap 100 (N20); E: shown at
    /// that box, 4 pt radius (displayed frames unresolved, IMG-02..06).
    static let photoBox: CGFloat = 29
    static let photoRadius: CGFloat = 4
    /// E: the link chip about 109 × 28 pt (R2-F07).
    static let linkChipHeight: CGFloat = 28
}

// MARK: - Thumbnails

/// How Reminders sizes a generated thumbnail (C code, N08/N09/N20): fill
/// the box keeping the aspect, cap the longest edge, then truncate each
/// side to the scale's grid (a zero scale counts as 1). Generation sizes,
/// not view frames.
enum RemindersReplicaPhotoSizing {
    struct Box: Equatable {
        let width: CGFloat
        let height: CGFloat
        let cap: CGFloat
    }

    /// C: the list's 308 × 308 fill box, 1024 cap (N08/N09).
    static let list = Box(width: 308, height: 308, cap: 1024)
    /// C: the detail's 29 × 29 fill box, 100 cap (N20).
    static let detail = Box(width: 29, height: 29, cap: 100)

    /// The fill size before the grid (800 × 500 gives 46.4 × 29 in the
    /// detail box and 492.8 × 308 in the list's).
    static func fillSize(original: CGSize, box: Box) -> CGSize {
        guard original.width > 0, original.height > 0 else { return .zero }
        let factor = max(box.width / original.width, box.height / original.height)
        var size = CGSize(width: original.width * factor, height: original.height * factor)
        let longest = max(size.width, size.height)
        if longest > box.cap {
            let shrink = box.cap / longest
            size = CGSize(width: size.width * shrink, height: size.height * shrink)
        }
        return size
    }

    /// The generated size on a display of `scale`.
    static func generatedSize(original: CGSize, box: Box, scale: CGFloat) -> CGSize {
        let scale = scale > 0 ? scale : 1
        let fill = fillSize(original: original, box: box)
        return CGSize(width: (fill.width * scale).rounded(.down) / scale,
                      height: (fill.height * scale).rounded(.down) / scale)
    }

    /// The pixel size ImageIO is asked for (its longest edge).
    static func maxPixel(original: CGSize, box: Box, scale: CGFloat) -> Int {
        let size = generatedSize(original: original, box: box, scale: scale)
        return max(1, Int((max(size.width, size.height) * max(scale, 1)).rounded(.up)))
    }
}

/// A photo on the item: an image file in its note (or one of its Earlier
/// files), shown in the panel and opened in Quick Look.
struct RemindersReplicaPhoto: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// An image in the item's writing (the note's attachment id).
        case note(UUID)
        /// An Earlier file still on the task (its owner).
        case task(owner: UUID)
    }

    let id: UUID
    let filename: String
    let source: Source
}

// MARK: - Links in the writing

extension RemindersReplicaText {
    /// The web links in some writing (M: a URL typed in Notes becomes blue,
    /// underlined, clickable text, R2-F06/AXLink). Only http(s).
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: whole).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return (match.range, url)
        }
    }

    /// The writing with its links clickable (and underlined, M).
    static func linkedNotes(_ text: String) -> AttributedString {
        let attributed = NSMutableAttributedString(string: text)
        for link in links(in: text) {
            attributed.addAttribute(.link, value: link.url, range: link.range)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link.range)
        }
        return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(text)
    }
}

// MARK: - The panel's staged edits

/// What the panel edits, staged until it closes (M, R2-F05: a click
/// outside commits; Escape cancels and nothing is saved). Pure.
struct RemindersReplicaDetailDraft: Equatable {
    /// Attic's lists (M: Reminders' List popup, R2-08).
    enum List: String, CaseIterable, Equatable {
        case now, later

        var title: String { self == .now ? TasksTab.now.title : TasksTab.backlog.title }
    }

    var title: String
    var dueDay: DueDay?
    var priority: TaskPriority
    var list: List
    var tags: [String]
    /// M: the Flag switch (R2-08, its own card with Priority).
    var isFlagged: Bool
    /// M: the link field, a plain URL under Notes (R2-F07); blank clears.
    var url: String
    /// A finished task keeps its list (moving it would reopen it).
    var isDone = false

    init(title: String, dueDay: DueDay?, priority: TaskPriority, status: TaskStatus, tags: [String],
         isFlagged: Bool = false, url: String? = nil) {
        self.title = title
        self.dueDay = dueDay
        self.priority = priority
        self.list = status == .backlog ? .later : .now
        self.tags = tags
        self.isFlagged = isFlagged
        self.url = url ?? ""
        self.isDone = status == .done
    }

    init(task: TaskItem) {
        self.init(title: task.title, dueDay: task.dueDay, priority: task.priority, status: task.status, tags: task.tags,
                  isFlagged: task.isFlagged, url: task.url)
    }

    /// Why the typed link can't be saved (Attic's own refusal), or nil.
    @MainActor var urlProblem: String? {
        do { _ = try TaskStore.normalizedTaskURL(url); return nil } catch { return error.localizedDescription }
    }

    /// The link's host, for the chip (nil when blank or invalid).
    @MainActor var urlHost: String? {
        guard let normalised = try? TaskStore.normalizedTaskURL(url) else { return nil }
        return URL(string: normalised)?.host()
    }

    /// What one Edit Task step changes; nil when nothing does.
    struct Patch: Equatable {
        var title: String?
        var dueDay: DueDay??
        var priority: TaskPriority?
        var status: TaskStatus?
        var tags: [String]?
        var isFlagged: Bool?
        /// `.some(nil)` clears the link.
        var url: String??
    }

    @MainActor func patch(from original: Self) -> Patch? {
        var patch = Patch()
        let title = TaskDraftBuilder.collapsed(self.title)
        // An emptied title keeps the one it had (Attic never saves a blank).
        if !title.isEmpty, title != original.title { patch.title = title }
        if dueDay != original.dueDay { patch.dueDay = .some(dueDay) }
        if priority != original.priority { patch.priority = priority }
        if list != original.list, !isDone { patch.status = list == .later ? .backlog : .todo }
        let tags = AtticTag.normalizedSet(self.tags)
        if Set(tags.map { $0.lowercased() }) != Set(AtticTag.normalizedSet(original.tags).map { $0.lowercased() }) { patch.tags = tags }
        if isFlagged != original.isFlagged { patch.isFlagged = isFlagged }
        // A link Attic refuses is not saved; the rest is (the toast says why).
        let typed: String?? = { do { return .some(try TaskStore.normalizedTaskURL(url)) } catch { return nil } }()
        let before: String? = try? TaskStore.normalizedTaskURL(original.url)
        if let typed, typed != before { patch.url = .some(typed) }
        return patch == Patch() ? nil : patch
    }

    /// The Date switch (M, R2-08: off, or on with the long date under it).
    /// Turning it on picks today, as Reminders' does.
    mutating func setHasDate(_ on: Bool, today: DueDay) {
        if on { if dueDay == nil { dueDay = today } } else { dueDay = nil }
    }

    /// A tag typed in the Tags row: `#` dropped, normalised, kept once.
    @discardableResult
    mutating func addTag(_ raw: String) -> Bool {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.first == "#" || name.first == "＃" { name.removeFirst() }
        guard let normalised = AtticTag.normalize(name),
              !tags.contains(where: { $0.caseInsensitiveCompare(normalised) == .orderedSame }) else { return false }
        tags.append(normalised)
        return true
    }

    mutating func removeTag(_ name: String) {
        tags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// The open panel: the task, what it held when opened, the staged draft.
/// Only the panel observes it, so typing in it never redraws the list.
@MainActor
final class RemindersReplicaDetailState: ObservableObject, Identifiable {
    let taskID: UUID
    let original: RemindersReplicaDetailDraft
    @Published var draft: RemindersReplicaDetailDraft
    /// M: the Notes & URL expander starts collapsed (R2-08).
    @Published var notesExpanded = false
    /// Escape was pressed: closing saves nothing.
    private(set) var cancelled = false

    var id: UUID { taskID }

    init(taskID: UUID, draft: RemindersReplicaDetailDraft) {
        self.taskID = taskID
        self.original = draft
        self.draft = draft
    }

    func cancel() { cancelled = true }

    var patch: RemindersReplicaDetailDraft.Patch? { cancelled ? nil : draft.patch(from: original) }
}

// MARK: - Indenting

/// Tab and ⇧Tab while the replica draws (R2; Reminders' own Tab/⇧Tab
/// semantics are unresolved in the study, INT-02..12).
enum RemindersReplicaIndent: Equatable {
    case indent, outdent

    /// Tab (key code 48) alone, or with Shift.
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard keyCode == 48 else { return nil }
        let relevant = modifiers.intersection([.command, .shift, .option, .control])
        if relevant.isEmpty { return .indent }
        if relevant == .shift { return .outdent }
        return nil
    }
}
