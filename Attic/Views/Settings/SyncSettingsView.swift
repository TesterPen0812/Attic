import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: TaskStore

    var body: some View {
        SettingsPage(
            title: "Sync",
            subtitle: "See the latest iCloud activity for Attic's private database.",
            accessibilityIdentifier: "settings-page-sync"
        ) {
            SettingsGroup("iCloud") {
                VStack(alignment: .leading, spacing: 9) {
                    Label(store.cloudSyncStatus.title, systemImage: store.cloudSyncStatus.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(syncStatusColor)

                    if let lastSuccess = store.cloudSyncStatus.lastSuccessfulActivityAt {
                        Text("Last successful iCloud activity \(lastSuccess.formatted(date: .abbreviated, time: .standard)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Attic is waiting for its first completed iCloud import or export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = store.cloudSyncStatus.lastErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(error)
                            .accessibilityIdentifier("settings-sync-activity-error")
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-sync-status")
            }

            if SettingsVisibility.showsSyncStartupError(
                message: settings.cloudSyncStartupErrorMessage
            ), let message = settings.cloudSyncStartupErrorMessage {
                SettingsGroup("This launch") {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("iCloud sync unavailable", systemImage: "exclamationmark.icloud.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)

                        Text("Attic is using its local task store for this launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(message)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-sync-startup-error")
                }
            }

            Text("Sync runs automatically and remains event-driven. Attic does not need a manual refresh control.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .textSelection(.enabled)
        }
    }

    private var syncStatusColor: Color {
        if store.cloudSyncStatus.lastErrorMessage != nil { return .orange }
        if store.cloudSyncStatus.isSyncing { return .accentColor }
        if store.cloudSyncStatus.lastSuccessfulActivityAt != nil { return .green }
        return .secondary
    }
}
