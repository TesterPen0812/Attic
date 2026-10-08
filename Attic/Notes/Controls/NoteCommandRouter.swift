import AppKit
import SwiftUI

/// The UI's single route into the engine's command layer. The selection bar,
/// Aa's format row, the `/` list, ⋯ › Insert and Format, the right-click menu, the menu
/// bar and the shortcuts all call `run(_:from:)` or `insert(_:from:)`; each
/// ends in `NoteEditorEngine.perform`, which validates, makes one history
/// step and keeps the selection. The router adds one presentation policy:
/// choosing a list or quote that is already on returns it to Body.
@MainActor
final class NoteCommandRouter {
    let engine: NoteEditorEngine
    /// Insert › Date… (the date card at the caret).
    var requestDate: (() -> Void)?
    /// Insert › Image or File… (the page's open panel).
    var requestFile: (() -> Void)?
    /// After any command: the bar and the format row re-read their states.
    var onChange: (() -> Void)?
    /// Every command that ran, with the surface it came from (tests).
    var onRun: ((NoteFormatCommand, NoteCommandSurface) -> Void)?
    var onInsert: ((NoteInsertAction, NoteCommandSurface) -> Void)?

    init(engine: NoteEditorEngine) {
        self.engine = engine
    }

    var selection: NSRange {
        engine.textView?.selectedRange() ?? NSRange(location: engine.textStorage.length, length: 0)
    }

    // MARK: State

    /// The range of the link around a caret (for Edit Link… on a caret).
    func linkRange(at location: Int) -> NSRange? {
        let storage = engine.textStorage
        guard storage.length > 0 else { return nil }
        for index in [location, location - 1] where index >= 0 && index < storage.length {
            var effective = NSRange()
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
            if storage.attribute(.noteMark(.link), at: index, longestEffectiveRange: &effective, in: paragraph) != nil {
                return effective
            }
        }
        return nil
    }

    /// Enabled and on/off/mixed for `command` at the current selection
    /// (the engine decides, including Link at a caret inside a link).
    func validation(_ command: NoteFormatCommand, selection: NSRange? = nil) -> NoteCommandValidation {
        if engine.focusedTable != nil {
            // In a table only the cell's marks apply (never the note's
            // text behind it); Table shows as on.
            if case let .mark(kind) = command, let state = engine.tableMarkState(kind) {
                return NoteCommandValidation(enabled: true, state: state)
            }
            return NoteCommandValidation(enabled: false, state: command == .table ? .on : .off)
        }
        return engine.validate(command, selection: selection ?? self.selection)
    }

    /// Why most commands are dimmed right now, for VoiceOver
    /// hints (nil when formatting is available).
    func disabledReason(selection: NSRange? = nil) -> String? {
        let selection = selection ?? self.selection
        if engine.isReadOnly { return String(localized: "This note is read only.") }
        if engine.activity != .idle { return String(localized: "Available after Writing Tools or typing finishes.") }
        if engine.formattableParagraphs(in: selection).isEmpty {
            return String(localized: "The title keeps its own style. Formatting starts on the next line.")
        }
        return nil
    }

    // MARK: Running

    /// Runs `command` from `surface`. Returns whether the engine applied it.
    @discardableResult
    func run(_ command: NoteFormatCommand, from surface: NoteCommandSurface, selection: NSRange? = nil) -> Bool {
        let selection = selection ?? self.selection
        var effective = command
        if NoteCommandCatalog.togglesOff(command), engine.validate(command, selection: selection).state == .on {
            effective = .paragraph(.body)
        }
        onRun?(command, surface)
        // In a table, marks go to the cell's text or the selected cells;
        // nothing else reaches the note's text behind it.
        if let table = engine.focusedTable {
            guard case let .mark(kind) = command else { return false }
            let applied = kind == .link ? engine.requestCellLink(in: table) : engine.applyCellMark(kind, in: table)
            onChange?()
            return applied
        }
        let applied = engine.perform(effective, selection: selection)
        onChange?()
        return applied
    }

    /// The link card's commit: the engine revalidates its captured target
    /// and refuses a stale one without editing.
    @discardableResult
    func commitLink(_ url: String, target: NoteLinkTarget, from surface: NoteCommandSurface) -> Bool {
        onRun?(.link(url), surface)
        let applied = engine.commitLink(url, target: target)
        onChange?()
        return applied
    }

    /// The cells' bar: copy, cut or clear the selected cells.
    @discardableResult
    func runCells(_ action: NoteCellAction, from surface: NoteCommandSurface) -> Bool {
        let applied = engine.perform(cellAction: action)
        onChange?()
        return applied
    }

    @discardableResult
    func alignCells(_ alignment: NoteTable.Alignment, from surface: NoteCommandSurface) -> Bool {
        guard let table = engine.focusedTable, let attachment = table.attachment,
              let range = table.cellSelection ?? table.activeCell.map({ NoteTableCellRange(anchor: $0, head: $0) }) else { return false }
        let applied = engine.setAlignment(alignment, of: attachment, columns: range.columns)
        onChange?()
        return applied
    }

    /// A table tool (Aa's row in a table) on the table the keyboard is in.
    @discardableResult
    func runTable(_ tool: NoteTableTool, from surface: NoteCommandSurface) -> Bool {
        let applied = engine.perform(tableTool: tool)
        onChange?()
        return applied
    }

    @discardableResult
    func runTableMenu(_ item: NoteTableMenuItem, from surface: NoteCommandSurface) -> Bool {
        let applied = engine.perform(tableMenu: item)
        onChange?()
        return applied
    }

    func insert(_ action: NoteInsertAction, from surface: NoteCommandSurface) {
        onInsert?(action, surface)
        switch action {
        case .divider: run(.divider, from: surface)
        case .table: run(.table, from: surface)
        case .date: requestDate?()
        case .imageOrFile: requestFile?()
        }
    }

    func canInsert(_ action: NoteInsertAction) -> Bool {
        switch action {
        case .divider: validation(.divider).enabled
        case .table: validation(.table).enabled && engine.focusedTable == nil
        case .date: engine.validate(.date(NoteDay(date: Date()))).enabled
        case .imageOrFile: !engine.isReadOnly && engine.activity == .idle
        }
    }

    // MARK: Menus (⋯, right-click, menu bar)

    /// Insert ▸ and Format ▸, as ⋯ shows them.
    func menuCommands(from surface: NoteCommandSurface) -> [AtticMenuCommand] {
        [
            AtticMenuCommand("Insert", identifier: "notes-menu-insert", submenu: insertMenuCommands(from: surface)),
            AtticMenuCommand("Format", identifier: "notes-menu-format", submenu: formatMenuCommands(from: surface))
        ]
    }

    func insertMenuCommands(from surface: NoteCommandSurface) -> [AtticMenuCommand] {
        NoteInsertAction.allCases.map { action in
            AtticMenuCommand("\(action.title)", systemImage: action.symbolName, isDisabled: !canInsert(action),
                             identifier: "notes-menu-insert-\(action.rawValue)") { [weak self] in
                self?.insert(action, from: surface)
            }
        }
    }

    func formatMenuCommands(from surface: NoteCommandSurface) -> [AtticMenuCommand] {
        let selection = self.selection
        var result: [AtticMenuCommand] = []
        for section in NoteCommandCatalog.formatSections {
            for (index, command) in section.enumerated() {
                let check = validation(command, selection: selection)
                let checked = check.state == .on && command != .removeLink
                result.append(AtticMenuCommand("\(NoteCommandCatalog.menuTitle(command))",
                                               systemImage: command.symbolName,
                                               shortcut: NoteCommandCatalog.keyboardShortcut(command),
                                               isDisabled: !check.enabled,
                                               startsSection: index == 0,
                                               isChecked: checked,
                                               identifier: Self.identifier(command)) { [weak self] in
                    self?.run(command, from: surface, selection: selection)
                })
            }
        }
        return result
    }

    static func identifier(_ command: NoteFormatCommand) -> String {
        let name: String = switch command {
        case let .paragraph(style):
            switch style {
            case .body: "body"
            case let .heading(level): "heading\(level)"
            case .bullet: "bullet"
            case .number: "number"
            case .checklist: "checklist"
            case .quote: "quote"
            case .mono: "mono"
            }
        case let .mark(kind): kind.rawValue
        case .link: "link-url"
        case .removeLink: "remove-link"
        case .indent: "indent"
        case .outdent: "outdent"
        case .divider: "divider"
        case .toggleChecklist: "toggle-checklist"
        case .moveUp: "move-up"
        case .moveDown: "move-down"
        case .date: "date"
        case .table: "table"
        }
        return "notes-format-\(name)"
    }
}
