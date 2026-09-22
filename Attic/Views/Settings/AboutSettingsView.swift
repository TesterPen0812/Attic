import AppKit
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(
            title: "About",
            subtitle: "A quiet workboard, right around the corner.",
            accessibilityIdentifier: "settings-page-about"
        ) {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attic")
                            .font(.system(size: 20, weight: .semibold))

                        Text(versionDescription)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-app-version")

                        Label("Local-first on this Mac", systemImage: "internaldrive.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section {
                SettingsRow(
                    title: "Attic on GitHub",
                    description: "Read the code, follow development or report an issue.",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    tint: .gray
                ) {
                    Link(destination: URL(string: "https://github.com/TesterPen0812/Attic")!) {
                        Label("Open Repository", systemImage: "arrow.up.right")
                    }
                    .help("Open the Attic repository")
                    .accessibilityIdentifier("settings-open-repository")
                }
            } header: {
                Text("Source")
            } footer: {
                SettingsFootnote("Your tasks, notes and canvases stay in this Mac's local store.")
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "—"
        return "Version \(version) (\(build))"
    }
}
