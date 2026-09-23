import AppKit
import SwiftUI

/// Shared metrics for the Settings window, pinned by
/// `SettingsPresentationTests` so the panes stay on one scale.
enum SettingsDesign {
    /// Pane title and subtitle, the first row of the scrolling form.
    static let titleSize: CGFloat = 22
    static let headerTopInset: CGFloat = 8
    static let headerBottomInset: CGFloat = 2
    /// The tinted symbol tile in front of a row label.
    static let iconSize: CGFloat = 24
    static let iconCornerRadius: CGFloat = 6
    static let iconSymbolSize: CGFloat = 11.5
    /// Selection ring around a chosen tile (palette, surface, tint, corner).
    static func selectionLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 2.5 : 2
    }
    static func tileBoundaryOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.42 : 0.14
    }
    static func tileBoundaryLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1.5 : 1
    }
    static let tileCornerRadius: CGFloat = 10
}

/// One pane: a title block and a grouped `Form`, the way System Settings
/// lays out a pane on macOS 26. Sections, rows, separators, focus rings and
/// the Light / Dark / Increased Contrast treatments all come from the native
/// form; only the controls inside are Attic's. The title scrolls with the
/// content, so the whole pane is one scrolling surface.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let accessibilityIdentifier: String
    private let content: Content

    init(
        title: String,
        subtitle: String,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: SettingsDesign.titleSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, SettingsDesign.headerTopInset)
                .padding(.bottom, SettingsDesign.headerBottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One container element for the pane, so the identifier lands on
        // it alone and not on every child the stack would otherwise expose.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// The tinted rounded-square symbol tile System Settings puts in front of a
/// row: a white symbol on a gradient of the row's colour.
struct SettingsIcon: View {
    let systemImage: String
    var tint: Color = .gray

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: SettingsDesign.iconSymbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: SettingsDesign.iconSize, height: SettingsDesign.iconSize)
            .background(
                tint.gradient,
                in: RoundedRectangle(cornerRadius: SettingsDesign.iconCornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// A labelled row: icon tile, title, optional one-line description, and the
/// control on the trailing side. `LabeledContent` gives the native grouped
/// alignment and wraps the control to its own line when the row is narrow.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let description: String?
    let systemImage: String
    let tint: Color
    /// Lets the description be selected and copied (an error to report).
    let selectableDescription: Bool
    private let trailing: Trailing

    init(
        title: String,
        description: String? = nil,
        systemImage: String,
        tint: Color = .gray,
        selectableDescription: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.tint = tint
        self.selectableDescription = selectableDescription
        self.trailing = trailing()
    }

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            SettingsRowLabel(title: title, description: description, systemImage: systemImage,
                             tint: tint, selectableDescription: selectableDescription)
        }
    }
}

struct SettingsRowLabel: View {
    let title: String
    let description: String?
    let systemImage: String
    var tint: Color = .gray
    var selectableDescription = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let description, !description.isEmpty {
                    let text = Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if selectableDescription {
                        text.textSelection(.enabled)
                    } else {
                        text
                    }
                }
            }
        } icon: {
            SettingsIcon(systemImage: systemImage, tint: tint)
        }
    }
}

/// A short status line inside a section: information, a warning, or an error.
struct SettingsMessage: View {
    enum Tone {
        case information
        case warning
        case error

        var color: Color {
            switch self {
            case .information: .secondary
            case .warning: .orange
            case .error: .red
            }
        }

        var systemImage: String {
            switch self {
            case .information: "info.circle"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.octagon.fill"
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: tone.systemImage)
        }
        .font(.callout)
        .foregroundStyle(tone.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section footer in the native secondary style.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The ring and boundary shared by every choosable tile in Settings.
struct SettingsTileSelection: ViewModifier {
    let isSelected: Bool
    let accent: Color
    let contrast: ColorSchemeContrast
    var cornerRadius: CGFloat = SettingsDesign.tileCornerRadius

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? accent
                            : Color.primary.opacity(SettingsDesign.tileBoundaryOpacity(for: contrast)),
                        lineWidth: isSelected
                            ? SettingsDesign.selectionLineWidth(for: contrast)
                            : SettingsDesign.tileBoundaryLineWidth(for: contrast)
                    )
            }
    }
}

extension View {
    func settingsTileSelection(
        isSelected: Bool,
        accent: Color,
        contrast: ColorSchemeContrast,
        cornerRadius: CGFloat = SettingsDesign.tileCornerRadius
    ) -> some View {
        modifier(SettingsTileSelection(
            isSelected: isSelected, accent: accent, contrast: contrast, cornerRadius: cornerRadius
        ))
    }
}
