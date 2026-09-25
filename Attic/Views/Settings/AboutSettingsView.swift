import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.openURL) private var openURL

    private static let repository = URL(string: "https://github.com/TesterPen0812/Attic")!

    var body: some View {
        SettingsPage(section: .about) {
            HStack(alignment: .center, spacing: AtticSpacing.s16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: AboutMetrics.iconSize, height: AboutMetrics.iconSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AtticSpacing.s4) {
                    AtticText(verbatim: "Attic", style: .pageTitle, ink: .heading)
                        .accessibilityAddTraits(.isHeader)
                    AtticText(verbatim: versionDescription, style: .settingsHelper, ink: .helper)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-app-version")
                    AtticText(verbatim: String(localized: "A quiet workboard, right around the corner."), style: .settingsHelper, ink: .helper)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, AtticLayout.groupedRowTextInset)
            .padding(.bottom, AtticSpacing.settingsBetweenSections)
            .accessibilityElement(children: .contain)

            SettingsGroup(
                title: String(localized: "Source"),
                footnote: String(localized: "Your tasks, notes and canvases stay in this Mac's local store.")
            ) {
                AtticActionRow(
                    title: String(localized: "Attic on GitHub"),
                    value: String(localized: "Read the code or report an issue"),
                    actionTitle: String(localized: "Open"),
                    actionSystemName: "arrow.up.right",
                    actionIdentifier: "settings-open-repository",
                    actionHelp: String(localized: "Open the Attic repository in your browser")
                ) {
                    openURL(Self.repository)
                }
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(localized: "Version \(version) (\(build))")
    }
}

enum AboutMetrics {
    /// The app icon beside the name: large enough to read as the icon,
    /// small enough to sit in the page's rhythm.
    static let iconSize: CGFloat = 64
}
