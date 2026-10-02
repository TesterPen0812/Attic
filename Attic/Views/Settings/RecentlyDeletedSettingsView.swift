import SwiftUI

/// Recently Deleted (spec § Shared systems): every deleted task, note,
/// canvas and removed attachment, restorable for 30 days; search; Restore
/// puts an item back where it was, links included; Empty All removes
/// everything here for good after a clear confirmation.
///
/// Control audit item 11: entries can be selected (click, ⌘-click,
/// ⇧-click, ⌘A; ↑ ↓ and ⇧↑ ⇧↓ while the list has the keyboard), then restored together (⌘R, one Undo
/// step) or deleted permanently (⌘⌫, always after a confirmation that
/// counts them). A row's right-click menu and its VoiceOver actions offer
/// the same commands, counted when they act on the selection.
struct RecentlyDeletedSettingsView: View {
    @StateObject private var model: RecentlyDeletedModel
    @FocusState private var searchFocused: Bool
    /// The list has the keyboard: ↑ ↓ move the selection (not the
    /// sidebar's, and not the search field's caret).
    @FocusState private var listFocused: Bool
    /// Follows whether the keyboard is driving, so the list shows a ring
    /// when Tab reaches it and none after a click.
    @StateObject private var keyboard = AtticKeyboardFocusTracker()
    @Environment(\.appearsActive) private var appearsActive

    init(library: AtticLibrary?) {
        _model = StateObject(wrappedValue: RecentlyDeletedModel(library: library))
    }

    var body: some View {
        SettingsPage(section: .recentlyDeleted) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) { content }
                    // The keyboard's row stays in view as ↑ ↓ move it.
                    .onChange(of: model.cursor) { _, cursor in
                        if let cursor { proxy.scrollTo(cursor) }
                    }
            }
        }
        // Follow the stores only while the page is on screen in the active
        // Settings window: a closed or background window reads nothing, and
        // catches up when it comes back.
        // Opening the page always lists what is there, even when Settings
        // opens behind another app (Attic has no Dock icon to activate).
        .onAppear { if appearsActive { model.start() } else { model.reload() } }
        .onDisappear { model.stop() }
        .atticKeyboardFocusTracking(keyboard)
        .onChange(of: appearsActive) { _, active in
            if active { model.start() } else { model.stop() }
        }
        .background { keys }
        .alert(
            model.emptyRequest?.title ?? "",
            isPresented: Binding(get: { model.emptyRequest != nil }, set: { if !$0 { model.cancelEmpty() } }),
            presenting: model.emptyRequest
        ) { request in
            // Removes exactly the items this confirmation counted.
            Button(request.confirmTitle, role: .destructive) {
                model.confirmEmpty()
            }
            .accessibilityIdentifier("recently-deleted-confirm-empty")
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelEmpty() }
        } message: { request in
            Text(request.confirmationText)
        }
    }

    @ViewBuilder
    private var content: some View {
        summary
        if !model.entries.isEmpty {
            AtticSearchField(
                placeholder: String(localized: "Search Recently Deleted"),
                text: $model.query,
                identifier: "recently-deleted-search",
                focus: $searchFocused
            )
            .padding(.bottom, AtticSpacing.s20)
        }
        if let message = model.message {
            SettingsGroup {
                AtticGroupMessage(
                    text: message.text,
                    tone: message.tone,
                    actionTitle: String(localized: "OK"),
                    action: model.dismissMessage
                )
            }
            .accessibilityIdentifier("recently-deleted-message")
        }
        let sections = model.sections
        if sections.isEmpty, !model.entries.isEmpty {
            SettingsGroup {
                AtticGroupEmptyRow(text: String(localized: "Nothing here matches “\(model.query)”."))
            }
            .accessibilityIdentifier("recently-deleted-no-results")
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.kind) { section in
                SettingsGroup(title: section.kind.sectionTitle, identifier: "recently-deleted-\(section.kind.rawValue)") {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            AtticGroupDivider(leadingInset: AtticSettingsRowMetrics.iconTextInset)
                        }
                        row(entry)
                            .id(entry.id)
                    }
                }
            }
        }
        // One keyboard stop for the list (Tab reaches it; a click on a row
        // gives it the keyboard): ↑ ↓ move the selection, ⇧↑ ⇧↓ grow it.
        // Tab shows a ring around the list at once, before any arrow moves
        // the selection; a click shows none (the selection fill is enough).
        .focusable(!sections.isEmpty)
        .focused($listFocused)
        .focusEffectDisabled()
        .atticFocusRing(
            Self.showsListFocusRing(listFocused: listFocused, keyboardDriving: keyboard.isKeyboardDriving, hasRows: !sections.isEmpty),
            cornerRadius: AtticRadius.groupCard
        )
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            model.moveCursor(by: press.key == .upArrow ? -1 : 1, extending: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Deleted items"))
    }

    /// The list shows its focus ring while it has the keyboard and the
    /// keyboard is what got it there.
    static func showsListFocusRing(listFocused: Bool, keyboardDriving: Bool, hasRows: Bool) -> Bool {
        hasRows && listFocused && keyboardDriving
    }

    private func row(_ entry: RecentlyDeletedEntry) -> some View {
        AtticDeletedItemRow(
            systemName: entry.kind.systemImage,
            kind: entry.kind.noun,
            title: entry.title,
            detail: entry.detail,
            restoreIdentifier: "recently-deleted-restore-\(entry.id)",
            isSelected: model.selection.contains(entry.id),
            onSelect: { flags in
                model.click(entry, command: flags.contains(.command), shift: flags.contains(.shift))
                listFocused = true
            },
            commands: { commands(for: entry) },
            onToggleSelection: { model.toggleSelection(entry) }
        ) {
            model.restore(entry)
        }
        .accessibilityIdentifier("recently-deleted-row-\(entry.id)")
    }

    /// A row's commands: on the selection when the row is part of it,
    /// otherwise on the row alone.
    private func commands(for entry: RecentlyDeletedEntry) -> [AtticMenuCommand] {
        let targets = model.targets(for: entry)
        // ⌘R and ⌘⌫ act on the selection: shown when the menu does too.
        let onSelection = model.selection.contains(entry.id)
        return [
            AtticMenuCommand(verbatim: RecentlyDeletedPresentation.restoreTitle(count: targets.count),
                             shortcut: onSelection ? RecentlyDeletedKeys.restore : nil) {
                model.restore(targets)
            },
            AtticMenuCommand(verbatim: RecentlyDeletedPresentation.deleteTitle(count: targets.count),
                             shortcut: onSelection ? RecentlyDeletedKeys.delete : nil,
                             isDestructive: true, startsSection: true) {
                model.requestDelete(targets)
            },
            AtticMenuCommand(verbatim: String(localized: "Select All"), shortcut: RecentlyDeletedKeys.selectAll,
                             isDisabled: model.listedEntries.count < 2, startsSection: true) {
                model.selectAll()
            }
        ]
    }

    /// How much is here, the rule, and Empty All; with a selection, what is
    /// selected and what can be done with it.
    private var summary: some View {
        SettingsGroup(
            footnote: String(localized: "Deleted tasks, notes, canvases and attachments stay here for 30 days, then are removed for good.")
        ) {
            if model.entries.isEmpty {
                AtticGroupEmptyRow(text: String(localized: "Nothing has been deleted."))
                    .accessibilityIdentifier("recently-deleted-empty-state")
            } else {
                AtticActionRow(
                    title: RecentlyDeletedPresentation.countPhrase(model.entries.count),
                    actionTitle: String(localized: "Empty All…"),
                    actionIdentifier: "recently-deleted-empty",
                    actionHelp: String(localized: "Remove everything in Recently Deleted for good, searched for or not")
                ) {
                    model.requestEmpty()
                }
                let selected = model.selectedEntries
                if !selected.isEmpty {
                    AtticGroupDivider()
                    AtticActionRow(
                        title: RecentlyDeletedPresentation.selectedPhrase(selected.count),
                        actionTitle: String(localized: "Restore"),
                        actionIdentifier: "recently-deleted-restore-selected",
                        actionHelp: String(localized: "Put the selected items back (⌘R)"),
                        secondary: AtticRowAction(
                            title: String(localized: "Delete Permanently…"),
                            identifier: "recently-deleted-delete-selected",
                            help: String(localized: "Remove the selected items for good (⌘⌫)"),
                            action: { model.requestDeleteSelected() }
                        )
                    ) {
                        model.restoreSelected()
                    }
                    .accessibilityIdentifier("recently-deleted-selection")
                }
            }
        }
    }

    /// The page's keys. None answers while the search field is editing,
    /// so it keeps its own ⌘A, ⌘Z, arrows and Delete.
    private var keys: some View {
        let listed = !model.listedEntries.isEmpty
        let selected = !model.selection.isEmpty
        return ZStack {
            // ⌘Z undoes the last restore, unless the search field is
            // editing (then it undoes typing, as everywhere).
            hidden("Undo", RecentlyDeletedKeys.undo, enabled: !searchFocused && model.canUndo) { model.undo() }
            hidden("Select All", RecentlyDeletedKeys.selectAll, enabled: !searchFocused && listed) { model.selectAll() }
            hidden("Restore Selected", RecentlyDeletedKeys.restore, enabled: selected) { model.restoreSelected() }
            hidden("Delete Permanently", RecentlyDeletedKeys.delete, enabled: !searchFocused && selected) { model.requestDeleteSelected() }
        }
    }

    private func hidden(_ title: String, _ shortcut: KeyboardShortcut, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(shortcut)
            .disabled(!enabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Recently Deleted's keys (control audit item 11), shown in its menus.
enum RecentlyDeletedKeys {
    static let undo = KeyboardShortcut("z", modifiers: .command)
    static let selectAll = KeyboardShortcut("a", modifiers: .command)
    static let restore = KeyboardShortcut("r", modifiers: .command)
    static let delete = KeyboardShortcut(.delete, modifiers: .command)
}
