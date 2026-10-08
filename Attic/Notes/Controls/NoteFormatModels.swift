import AppKit
import SwiftUI

/// What every format command is at the selection (enabled, on/off/mixed),
/// read once from the engine for the bar and the format row. Only the selected
/// paragraphs are inspected (`NoteEditorEngine.validate`).
struct NoteFormatSnapshot: Equatable {
    var paragraph: NoteParagraphStyle?
    var validations: [NoteFormatCommand: NoteCommandValidation] = [:]
    var disabledReason: String?
    /// The keyboard is in a table: Aa's row is the table's tools.
    var table: NoteTableToolsState?

    static let empty = NoteFormatSnapshot()

    /// The commands the bar and the format row show.
    static let shownCommands: [NoteFormatCommand] = {
        var seen = Set<NoteFormatCommand>()
        return (NoteCommandCatalog.styles + NoteCommandCatalog.marks + NoteCommandCatalog.inline
                + NoteCommandCatalog.lists + NoteCommandCatalog.indents).filter { seen.insert($0).inserted }
    }()

    @MainActor
    static func make(router: NoteCommandRouter, selection: NSRange) -> NoteFormatSnapshot {
        var validations: [NoteFormatCommand: NoteCommandValidation] = [:]
        for command in shownCommands { validations[command] = router.validation(command, selection: selection) }
        let engine = router.engine
        if engine.focusedTable != nil {
            // In a table: only the cell's marks apply (no block styles in cells).
            for command in shownCommands {
                if case let .mark(kind) = command, let state = engine.tableMarkState(kind) {
                    validations[command] = NoteCommandValidation(enabled: true, state: state)
                } else {
                    validations[command] = NoteCommandValidation(enabled: false, state: .off)
                }
            }
            return NoteFormatSnapshot(paragraph: nil, validations: validations, disabledReason: nil,
                                      table: engine.tableToolsState())
        }
        let styles = (NoteCommandCatalog.styles + NoteCommandCatalog.lists).filter { validations[$0]?.state == .on }
        let paragraph: NoteParagraphStyle? = if case let .paragraph(style)? = styles.first { style } else { nil }
        return NoteFormatSnapshot(paragraph: paragraph, validations: validations,
                                  disabledReason: router.disabledReason(selection: selection),
                                  table: router.engine.tableToolsState())
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
        + (NoteCommandCatalog.barMarks + NoteCommandCatalog.barInline).map { .command($0) }
}

/// The format row's controls in keyboard order (OD-14, p2-36 draft 1):
/// the style, the four cells (three lists and Table), outdent and indent,
/// then close. In a table (sheet 3, panel 2): Table ⌄, add a row, add a
/// column, delete the row, delete the column, then close.
enum NoteFormatRowItem: Hashable {
    case style
    case command(NoteFormatCommand)
    case tableMenu
    case tableTool(NoteTableTool)
    case close

    static let all: [NoteFormatRowItem] = [.style]
        + (NoteCommandCatalog.lists + NoteCommandCatalog.indents).map { .command($0) } + [.close]
    static let table: [NoteFormatRowItem] = [.tableMenu] + NoteTableTool.allCases.map { .tableTool($0) } + [.close]

    static func items(inTable: Bool) -> [NoteFormatRowItem] { inTable ? table : all }

    /// The index after `index`, `forward` or back, round the row.
    static func step(_ index: Int, forward: Bool, count: Int = all.count) -> Int {
        (index + (forward ? 1 : count - 1)) % count
    }
}

/// A table's state as Aa's row shows it.
struct NoteTableToolsState: Equatable {
    var headerRow: Bool
    var rows: Int
    var columns: Int
    /// Delete Row / Column delete the table when it has one left.
    var canDeleteRow: Bool { rows > 1 }
    var canDeleteColumn: Bool { columns > 1 }
}

/// The table tools in Aa's row (sheet 3, panel 2).
enum NoteTableTool: Hashable, CaseIterable {
    case addRow, addColumn, deleteRow, deleteColumn

    var title: String {
        switch self {
        case .addRow: String(localized: "Add Row")
        case .addColumn: String(localized: "Add Column")
        case .deleteRow: String(localized: "Delete Row")
        case .deleteColumn: String(localized: "Delete Column")
        }
    }

    var shortcut: String? {
        switch self {
        case .addRow: "⌥⌘↓"
        case .addColumn: "⌥⌘→"
        case .deleteRow, .deleteColumn: nil
        }
    }

    var glyph: AtticTableToolGlyph.Kind {
        switch self {
        case .addRow: .addRow
        case .addColumn: .addColumn
        case .deleteRow: .deleteRow
        case .deleteColumn: .deleteColumn
        }
    }
}

/// Table ⌄ (Aa's row in a table, and the grips' menus share its rows).
enum NoteTableMenuItem: Hashable, CaseIterable {
    case headerRow, distributeColumns, convertToText, copyAsMarkdown, deleteTable

    var title: String {
        switch self {
        case .headerRow: String(localized: "Header Row")
        case .distributeColumns: String(localized: "Distribute Columns")
        case .convertToText: String(localized: "Convert to Text")
        case .copyAsMarkdown: String(localized: "Copy as Markdown")
        case .deleteTable: String(localized: "Delete Table")
        }
    }
}

/// The state the selection bar and the format row draw. Published only when a value
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
    /// The keyboard's position in the format row (⌘T, ⌃Tab), or nil.
    @Published var rowKeyboardIndex: Int?
    /// The format row's style list is open.
    @Published var rowStyleListOpen = false
    /// The table menu (Table ⌄) is open.
    @Published var rowTableMenuOpen = false
    /// The note's highlight colour, for the highlight toggle's swatch.
    @Published var highlightSwatch: AtticRGBA = .clear

    weak var router: NoteCommandRouter?
    /// Before the link card opens (the bar's link toggle goes through the
    /// engine's link request).
    var willRequestLink: (() -> Void)?

    func setSnapshot(_ value: NoteFormatSnapshot) {
        if value != snapshot { snapshot = value }
        if value.table == nil, rowTableMenuOpen { rowTableMenuOpen = false }
    }

    func runTable(_ tool: NoteTableTool) {
        router?.runTable(tool, from: .formatBar)
    }

    func runTableMenu(_ item: NoteTableMenuItem) {
        rowTableMenuOpen = false
        router?.runTableMenu(item, from: .formatBar)
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

/// Whether Aa's format row is open (OD-14). Only the bottom row observes
/// it, so opening and closing never redraw the page or the note.
@MainActor
final class NoteFormatRowState: ObservableObject {
    @Published private(set) var isOpen = false
    /// ⌘T or a keyboard stop opened it: the ring shows at once.
    private(set) var openedByKeyboard = false
    /// Told after every change (open, opened from the keyboard).
    var onChange: ((_ open: Bool, _ keyboard: Bool) -> Void)?

    func open(keyboard: Bool) {
        openedByKeyboard = keyboard
        if !isOpen { isOpen = true }
        onChange?(true, keyboard)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        openedByKeyboard = false
        onChange?(false, false)
    }
}

/// The `/` list's rows and the keyboard's row.
@MainActor
final class NoteSlashListModel: ObservableObject {
    @Published private(set) var items: [NoteSlashItem] = []
    @Published var highlighted = 0
    @Published var shown = false
    /// Rows that fit beside the caret; more scroll.
    @Published var viewportHeight: CGFloat?
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
    @Published var viewportHeight: CGFloat?
    @Published var viewportWidth: CGFloat?
    /// The card opened above its text (no room below).
    @Published var above = false
    /// What was typed into the date card after `/date` (the card has no
    /// field: its suggestions show it).
    @Published var dateText = ""
    @Published var linkText = ""
    @Published var linkError: String?
    var today = Date()
    var calendar = Calendar.current

    var onCommitDate: ((Date) -> Void)?
    var onCommitLink: ((String) -> Bool)?
    var onRemoveLink: (() -> Void)?
    var onCancel: (() -> Void)?

    /// What Return inserts: the first suggestion for what was typed, or
    /// today when nothing is typed.
    var candidateDate: Date? {
        guard !dateText.trimmingCharacters(in: .whitespaces).isEmpty else { return calendar.startOfDay(for: today) }
        let today = today, calendar = calendar
        return AtticDateSuggestions.make(dateText, today: today, calendar: calendar) {
            NoteDateQuery.parse($0, today: today, calendar: calendar)
        }.first?.date
    }

    func openDate(fromSlash: Bool, today: Date) {
        self.today = today
        dateText = ""
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
