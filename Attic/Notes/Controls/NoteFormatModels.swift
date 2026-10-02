import AppKit
import SwiftUI

/// What every format command is at the selection (enabled, on/off/mixed),
/// read once from the engine for the bar and Aa. Only the selected
/// paragraphs are inspected (`NoteEditorEngine.validate`).
struct NoteFormatSnapshot: Equatable {
    var paragraph: NoteParagraphStyle?
    var validations: [NoteFormatCommand: NoteCommandValidation] = [:]
    var disabledReason: String?

    static let empty = NoteFormatSnapshot()

    /// The commands the bar and Aa show.
    static let shownCommands: [NoteFormatCommand] = {
        var seen = Set<NoteFormatCommand>()
        return (NoteCommandCatalog.styles + NoteCommandCatalog.marks + NoteCommandCatalog.inline
                + NoteCommandCatalog.lists + NoteCommandCatalog.indents).filter { seen.insert($0).inserted }
    }()

    @MainActor
    static func make(router: NoteCommandRouter, selection: NSRange) -> NoteFormatSnapshot {
        var validations: [NoteFormatCommand: NoteCommandValidation] = [:]
        for command in shownCommands { validations[command] = router.validation(command, selection: selection) }
        let styles = (NoteCommandCatalog.styles + NoteCommandCatalog.lists).filter { validations[$0]?.state == .on }
        let paragraph: NoteParagraphStyle? = if case let .paragraph(style)? = styles.first { style } else { nil }
        return NoteFormatSnapshot(paragraph: paragraph, validations: validations,
                                  disabledReason: router.disabledReason(selection: selection))
    }

    func isEnabled(_ command: NoteFormatCommand) -> Bool { validations[command]?.enabled ?? false }

    func value(_ command: NoteFormatCommand) -> AtticFormatValue {
        switch validations[command]?.state {
        case .on: .on
        case .mixed: .mixed
        default: .off
        }
    }

    /// Anything to offer at all (a title-only or read-only selection shows
    /// no bar).
    var hasEnabledCommand: Bool { validations.values.contains { $0.enabled } }
}

/// The bar's controls in keyboard order (← → move, Return or Space press).
enum NoteFormatBarItem: Hashable {
    case style
    case command(NoteFormatCommand)

    static let all: [NoteFormatBarItem] = [.style]
        + (NoteCommandCatalog.barMarks + NoteCommandCatalog.barInline + NoteCommandCatalog.barLists).map { .command($0) }
}

struct NoteGridIndex: Equatable {
    var row: Int
    var column: Int
}

/// Aa's controls, row by row (← → within and across rows, ↑ ↓ between).
enum NoteFormatPopoverGrid {
    static let rows: [[NoteFormatCommand]] = [
        NoteCommandCatalog.styles,
        NoteCommandCatalog.marks + NoteCommandCatalog.inline,
        NoteCommandCatalog.lists + NoteCommandCatalog.indents
    ]

    static func move(_ index: NoteGridIndex, by key: KeyEquivalent) -> NoteGridIndex {
        var row = index.row
        var column = index.column
        switch key {
        case .leftArrow:
            if column > 0 { column -= 1 } else if row > 0 { row -= 1; column = rows[row].count - 1 }
        case .rightArrow:
            if column < rows[row].count - 1 { column += 1 } else if row < rows.count - 1 { row += 1; column = 0 }
        case .upArrow:
            if row > 0 { row -= 1; column = min(column, rows[row].count - 1) }
        case .downArrow:
            if row < rows.count - 1 { row += 1; column = min(column, rows[row].count - 1) }
        default: break
        }
        return NoteGridIndex(row: row, column: column)
    }

    static func command(at index: NoteGridIndex) -> NoteFormatCommand? {
        guard rows.indices.contains(index.row), rows[index.row].indices.contains(index.column) else { return nil }
        return rows[index.row][index.column]
    }
}

/// The state the selection bar and Aa draw. Published only when a value
/// changes, and never while typing with nothing shown.
@MainActor
final class NoteFormatModel: ObservableObject {
    @Published private(set) var snapshot = NoteFormatSnapshot.empty
    /// The bar is on screen (it fades and rises in and out).
    @Published var barShown = false
    /// Under the selection (no room above): it rises from below.
    @Published var barBelow = false
    /// The keyboard's position in the bar (⌃Tab), or nil.
    @Published var barKeyboardIndex: Int?
    /// The keyboard's position in Aa, once an arrow key has moved it.
    @Published var popoverKeyboardIndex: NoteGridIndex?
    /// The note's highlight colour, for the highlight toggle's swatch.
    @Published var highlightSwatch: AtticRGBA = .clear

    weak var router: NoteCommandRouter?
    /// Opens the link card (the bar's and Aa's link toggle go through the
    /// engine's link request; this closes Aa first).
    var willRequestLink: (() -> Void)?

    func setSnapshot(_ value: NoteFormatSnapshot) {
        if value != snapshot { snapshot = value }
    }

    func run(_ command: NoteFormatCommand, from surface: NoteCommandSurface) {
        if command == .mark(.link) { willRequestLink?() }
        router?.run(command, from: surface)
    }

    /// The bar's style menu (Title … Mono, the current one checked).
    func styleMenu(from surface: NoteCommandSurface) -> [AtticMenuCommand] {
        NoteCommandCatalog.styles.map { command in
            AtticMenuCommand("\(command.title)", shortcut: NoteCommandCatalog.keyboardShortcut(command),
                             isDisabled: !snapshot.isEnabled(command),
                             isChecked: snapshot.value(command) == .on,
                             identifier: NoteCommandRouter.identifier(command)) { [weak self] in
                self?.router?.run(command, from: surface)
            }
        }
    }

    static func help(_ command: NoteFormatCommand) -> String {
        let title = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
        guard let shortcut = NoteCommandCatalog.shortcutLabel(command) else { return title }
        return "\(title) \(shortcut)"
    }
}

/// The `/` list's rows and the keyboard's row.
@MainActor
final class NoteSlashListModel: ObservableObject {
    @Published private(set) var items: [NoteSlashItem] = []
    @Published var highlighted = 0
    @Published var shown = false
    /// Rows that fit beside the caret; more scroll.
    @Published var maxVisibleRows = AtticNoteFormatMetrics.slashMaxVisibleRows
    /// The card's width (the width rule, from its names) and the typed
    /// filter, emboldened in the names.
    @Published var width: CGFloat = AtticDropdownMetrics.minWidth
    @Published var query = ""
    /// It opened above the caret (no room below).
    @Published var above = false
    var onPick: ((NoteSlashItem.Kind) -> Void)?

    func show(_ items: [NoteSlashItem]) {
        if items.map(\.kind) != self.items.map(\.kind) {
            self.items = items
            highlighted = 0
        }
        if !shown { shown = true }
    }

    func hide() {
        if shown { shown = false }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }

    var highlightedKind: NoteSlashItem.Kind? { items.indices.contains(highlighted) ? items[highlighted].kind : nil }
}

/// The date card and the link card (one at a time, anchored at the text).
@MainActor
final class NoteFormatCardModel: ObservableObject {
    enum Card: Equatable {
        /// From `/date` (the typed command is replaced) or Insert › Date….
        case date(fromSlash: Bool)
        case link(hasLink: Bool)
    }

    @Published var card: Card?
    /// The card opened above its text (no room below).
    @Published var above = false
    @Published var dateText = "" {
        didSet {
            if let parsed = parsedDate { dateMonth = parsed }
        }
    }
    @Published var dateMonth = Date()
    @Published var linkText = ""
    @Published var linkError: String?
    var today = Date()
    var calendar = Calendar.current

    var onCommitDate: ((Date) -> Void)?
    var onCommitLink: ((String) -> Bool)?
    var onRemoveLink: (() -> Void)?
    var onCancel: (() -> Void)?

    var parsedDate: Date? { NoteDateQuery.parse(dateText, today: today, calendar: calendar) }
    /// What Return inserts: the typed date, or today when nothing is typed.
    var candidateDate: Date? { dateText.trimmingCharacters(in: .whitespaces).isEmpty ? calendar.startOfDay(for: today) : parsedDate }

    func openDate(fromSlash: Bool, today: Date) {
        self.today = today
        dateText = ""
        dateMonth = today
        card = .date(fromSlash: fromSlash)
    }

    func openLink(url: String?) {
        linkText = url ?? ""
        linkError = nil
        card = .link(hasLink: url != nil)
    }

    func submitLink() {
        let url = Self.normalizedURL(linkText)
        if onCommitLink?(url) == true { return }
        linkError = String(localized: "Enter a web address, like example.com.")
    }

    /// "example.com" becomes "https://example.com"; a scheme is kept.
    static func normalizedURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        return "https://" + trimmed
    }
}
