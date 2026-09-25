import SwiftUI

/// Recently Deleted (spec § Shared systems): every deleted task, note,
/// canvas and removed attachment, restorable for 30 days; search; Restore
/// puts an item back where it was, links included; Empty removes
/// everything here for good after a clear confirmation.
struct RecentlyDeletedSettingsView: View {
    @StateObject private var model: RecentlyDeletedModel
    @State private var emptyConfirmation: Date?
    @FocusState private var searchFocused: Bool

    init(library: AtticLibrary?) {
        _model = StateObject(wrappedValue: RecentlyDeletedModel(library: library))
    }

    var body: some View {
        SettingsPage(section: .recentlyDeleted) {
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
            ForEach(sections, id: \.kind) { section in
                SettingsGroup(title: section.kind.sectionTitle, identifier: "recently-deleted-\(section.kind.rawValue)") {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            AtticGroupDivider(leadingInset: AtticSettingsRowMetrics.iconTextInset)
                        }
                        AtticDeletedItemRow(
                            systemName: entry.kind.systemImage,
                            kind: entry.kind.noun,
                            title: entry.title,
                            detail: entry.detail,
                            restoreIdentifier: "recently-deleted-restore-\(entry.id)"
                        ) {
                            model.restore(entry)
                        }
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .background {
            // ⌘Z undoes the last restore, unless the search field is
            // editing (then it undoes typing, as everywhere).
            Button("Undo") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(searchFocused || !model.canUndo)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .alert(
            String(localized: "Empty Recently Deleted?"),
            isPresented: Binding(get: { emptyConfirmation != nil }, set: { if !$0 { emptyConfirmation = nil } }),
            presenting: emptyConfirmation
        ) { cutoff in
            Button(String(localized: "Empty"), role: .destructive) {
                model.empty(confirmedAt: cutoff)
            }
            .accessibilityIdentifier("recently-deleted-confirm-empty")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(RecentlyDeletedPresentation.emptyConfirmation(count: model.entries.count))
        }
    }

    /// How much is here, the rule, and Empty.
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
                    actionTitle: String(localized: "Empty…"),
                    actionIdentifier: "recently-deleted-empty",
                    actionHelp: String(localized: "Remove everything in Recently Deleted for good")
                ) {
                    emptyConfirmation = Date()
                }
            }
        }
    }
}
