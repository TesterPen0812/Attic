import AppKit
import SwiftUI

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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                content
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 8, y: 3)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let description: String
    let systemImage: String
    private let trailing: Trailing

    init(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 13) {
                rowLabel
                trailing
            }

            VStack(alignment: .leading, spacing: 11) {
                rowLabel
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var rowLabel: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.045), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 54)
    }
}

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
            case .warning: "exclamationmark.triangle"
            case .error: "exclamationmark.octagon"
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
        .font(.caption)
        .foregroundStyle(tone.color)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
