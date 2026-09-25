import AppKit
import SwiftUI

// How the Settings pages are put together from the design system's
// Settings components (`AtticSettingsComponents`, `AtticSettingsPageComponents`):
// a page is a header on the traffic-light line over a scrolling body of
// sections, each an optional heading, a group card and an optional
// footnote. Nothing here draws a look of its own.

/// One page in the content card: the back button and the page title, then
/// the page's sections, which scroll and blur out at the bottom.
struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content

    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: section.title)
            AtticSettingsScrollPage(identifier: section.pageIdentifier) {
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
    }
}

/// The content card's top bar. The back button returns to the page shown
/// before (⌘[), and is a disabled ghost when there is none; the rest of the
/// bar moves the window, as a title bar does.
struct SettingsHeader: View {
    let title: String

    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            AtticSettingsHeader(title: title) {
                navigation.goBack()
            }
            .disabled(!navigation.canGoBack)
            .help(String(localized: "Back (⌘[)"))
            .accessibilityIdentifier("settings-back")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .background {
            // ⌘[ goes back wherever focus is in the window.
            Button("Back") { navigation.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!navigation.canGoBack)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// A section: an optional heading, a group card holding rows (the caller
/// puts `AtticGroupDivider`s between them), and an optional footnote.
/// Sections sit 34 pt apart (spec).
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footnote: String?
    var identifier: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                AtticSectionHeading(title: title)
                Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
            }
            AtticGroupCard {
                content
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title ?? "")
            .atticIdentifier(identifier)
            if let footnote {
                AtticGroupFootnote(footnote)
            }
        }
        .padding(.bottom, AtticSpacing.settingsBetweenSections)
    }
}

/// A heading with free content under it (tiles), 34 pt from the next
/// section.
struct SettingsTileSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AtticSectionHeading(title: title)
            Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
            content
            if let footnote {
                AtticGroupFootnote(footnote)
            }
        }
        .padding(.bottom, AtticSpacing.settingsBetweenSections)
    }
}

/// Point values are rendered from whatever the model currently holds, so the
/// formatting must be total over every `Double`. `Int(value.rounded())` traps
/// on any magnitude `Int` cannot represent, and a corrupt preference can carry
/// a finite value such as `1e30` past validation — reading Settings then
/// crashed the app rather than showing a number.
enum SettingsPointFormat {
    static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    static func points(_ value: Double) -> String {
        "\(rounded(value)) pt"
    }

    static func spokenPoints(_ value: Double) -> String {
        String(localized: "\(rounded(value)) points")
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func spokenSeconds(_ value: Double) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) seconds")
    }
}
