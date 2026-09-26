import SwiftUI

/// Recently Deleted (spec § Shared systems): every deleted task, note,
/// canvas and removed attachment, restorable for 30 days; search; Restore
/// puts an item back where it was, links included; Empty removes
/// everything here for good after a clear confirmation.
struct RecentlyDeletedSettingsView: View {
    @StateObject private var model: RecentlyDeletedModel
    @FocusState private var searchFocused: Bool
    @Environment(\.appearsActive) private var appearsActive

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
        // Follow the stores only while the page is on screen in the active
        // Settings window: a closed or background window reads nothing, and
        // catches up when it comes back.
        // Opening the page always lists what is there, even when Settings
        // opens behind another app (Attic has no Dock icon to activate).
        .onAppear { if appearsActive { model.start() } else { model.reload() } }
        .onDisappear { model.stop() }
        .onChange(of: appearsActive) { _, active in
            if active { model.start() } else { model.stop() }
        }
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
            isPresented: Binding(get: { model.emptyRequest != nil }, set: { if !$0 { model.cancelEmpty() } }),
            presenting: model.emptyRequest
        ) { _ in
            // Removes exactly the items this confirmation counted.
            Button(String(localized: "Empty"), role: .destructive) {
                model.confirmEmpty()
            }
            .accessibilityIdentifier("recently-deleted-confirm-empty")
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelEmpty() }
        } message: { request in
            Text(request.confirmationText)
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
                    model.requestEmpty()
                }
            }
        }
    }
}
