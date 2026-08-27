import AppKit
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(
            title: "About",
            subtitle: "A quiet list, right around the corner.",
            accessibilityIdentifier: "settings-page-about"
        ) {
            SettingsGroup("Attic") {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attic")
                            .font(.system(size: 18, weight: .semibold))

                        Text(versionDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-app-version")

                        Text("Made by Emanuele Di Pietro")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 0)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsGroup("Source") {
                SettingsRow(
                    title: "Open source on GitHub",
                    description: "Read the source code, follow development, or report an issue.",
                    systemImage: "chevron.left.forwardslash.chevron.right"
                ) {
                    Link(destination: URL(string: "https://github.com/Emanuele-web04/Attic")!) {
                        Label("Open Repository", systemImage: "arrow.up.right")
                    }
                    .controlSize(.small)
                    .help("Open the Attic repository")
                    .accessibilityIdentifier("settings-open-repository")
                }
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
