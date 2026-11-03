import SwiftUI

enum PhoneAppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The Mac's shipped choices and spatial spring recipe, without its AppKit
/// settings service or process-wide motion state.
enum PhoneAnimationLevel: String, CaseIterable, Identifiable {
    case lively, subtle, reduced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func effective(systemReduceMotion: Bool) -> Self {
        systemReduceMotion ? .reduced : self
    }

    var animation: Animation? {
        switch self {
        case .lively: .spring(duration: 0.28, bounce: 0.12)
        case .subtle: .spring(duration: 0.28, bounce: 0.04)
        case .reduced: nil
        }
    }

    func apply(to transaction: inout Transaction) {
        if self == .reduced {
            transaction.animation = nil
            transaction.disablesAnimations = true
        } else if transaction.animation != nil, !transaction.disablesAnimations {
            transaction.animation = animation
        }
    }
}

/// Only these device-local keys are read or written. No Mac settings migration,
/// ubiquitous defaults, library data, or singleton settings service is involved.
struct PhoneLocalPreferences: DynamicProperty {
    enum Key {
        static let appearance = "AtticMobile.local.appearance.v1"
        static let animations = "AtticMobile.local.animations.v1"
    }

    @AppStorage var appearance: PhoneAppearancePreference
    @AppStorage var animations: PhoneAnimationLevel

    init(defaults: UserDefaults = .standard) {
        _appearance = AppStorage(wrappedValue: .system, Key.appearance, store: defaults)
        _animations = AppStorage(wrappedValue: .lively, Key.animations, store: defaults)
    }
}

private struct PhoneAnimationLevelKey: EnvironmentKey {
    static let defaultValue: PhoneAnimationLevel = .lively
}

extension EnvironmentValues {
    /// Effective choice, including the system Reduce Motion override.
    var phoneAnimationLevel: PhoneAnimationLevel {
        get { self[PhoneAnimationLevelKey.self] }
        set { self[PhoneAnimationLevelKey.self] = newValue }
    }
}

private struct PhoneLocalPreferencesModifier: ViewModifier {
    private var preferences: PhoneLocalPreferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(defaults: UserDefaults) {
        preferences = PhoneLocalPreferences(defaults: defaults)
    }

    func body(content: Content) -> some View {
        let motion = preferences.animations.effective(systemReduceMotion: systemReduceMotion)
        content
            .preferredColorScheme(preferences.appearance.colorScheme)
            .environment(\.phoneAnimationLevel, motion)
            .transaction { motion.apply(to: &$0) }
    }
}

extension View {
    /// Apply once around the shell's NavigationStack and presentations so the
    /// choices remain active after Settings is dismissed. Settings also uses
    /// this locally to give immediate feedback before shell integration.
    func phoneLocalPreferences(defaults: UserDefaults = .standard) -> some View {
        modifier(PhoneLocalPreferencesModifier(defaults: defaults))
    }
}

/// Content for the shell's existing pushed-page chrome. The shell owns Back
/// and the navigation stack; this page owns only local preferences.
struct PhoneSettingsPage: View {
    private var preferences: PhoneLocalPreferences
    private let defaults: UserDefaults
    private let bundle: Bundle
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        preferences = PhoneLocalPreferences(defaults: defaults)
        self.defaults = defaults
        self.bundle = bundle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: titleSize, weight: .bold))
                    .tracking(-1)
                    .padding(.horizontal, 20)
                    .padding(.top, 13)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)

                group("General") {
                    LabeledContent("Appearance") {
                        Picker("Appearance", selection: preferences.$appearance) {
                            ForEach(PhoneAppearancePreference.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Appearance")
                        .accessibilityValue(preferences.appearance.title)
                        .accessibilityIdentifier("phone-setting-appearance")
                    }
                    .frame(minHeight: 46)
                    Divider()
                    LabeledContent("Animations") {
                        Picker("Animations", selection: preferences.$animations) {
                            ForEach(PhoneAnimationLevel.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel("Animations")
                        .accessibilityValue(preferences.animations.title)
                        .accessibilityIdentifier("phone-setting-animations")
                    }
                    .frame(minHeight: 46)
                }

                group("iCloud") {
                    // Status, not a setup control: this build has no cloud service.
                    LabeledContent("Sync", value: "Not set up")
                        .frame(minHeight: 46)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("phone-settings-sync-status")
                }

                group("About") {
                    LabeledContent("Attic", value: versionDescription)
                        .frame(minHeight: 46)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("phone-settings-version")
                    Divider()
                    Link(destination: Self.repository) {
                        HStack {
                            Text("Attic on GitHub")
                            Spacer(minLength: 12)
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("phone-settings-source")
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .phoneLocalPreferences(defaults: defaults)
        .accessibilityIdentifier("phone-settings-page")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 24)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 20)
    }

    private static let repository = URL(string: "https://github.com/TesterPen0812/Attic")!

    private var versionDescription: String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}

/// Actions belong to the current page. A handler is required; availability is
/// expressed by leaving the action out, rather than presenting an inert button.
struct PhonePageMenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isSelected = false
    var role: ButtonRole?
    let perform: () -> Void
}

struct PhonePageMenu {
    let pageTitle: String
    let actions: [PhonePageMenuAction]

    var accessibilityLabel: String { "\(pageTitle) options" }

    /// The gap sheet's Home menu. Edit Tags appears only when its editor exists.
    static func home(openSettings: @escaping () -> Void, editTags: (() -> Void)? = nil) -> Self {
        var actions = [PhonePageMenuAction(id: "settings", title: "Settings", systemImage: "gearshape",
                                          perform: openSettings)]
        if let editTags {
            actions.append(.init(id: "edit-tags", title: "Edit Tags", systemImage: "number",
                                 perform: editTags))
        }
        return Self(pageTitle: "Home", actions: actions)
    }
}

/// Use in place of the shell's generic navigation menu, supplying only this
/// page's live actions (tag filters, list/board and sort, calendar visibility).
/// Existing note and canvas editors can keep their richer, dedicated menus.
struct PhonePageActionsMenu: View {
    let menu: PhonePageMenu
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !menu.actions.isEmpty {
            Menu {
                ForEach(menu.actions) { action in
                    Button(role: action.role, action: action.perform) {
                        Label(action.title, systemImage: action.isSelected ? "checkmark" : action.systemImage)
                    }
                    .accessibilityAddTraits(action.isSelected ? .isSelected : [])
                    .accessibilityIdentifier("phone-page-action-\(action.id)")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background {
                        if reduceTransparency {
                            Circle().fill(Color(uiColor: .secondarySystemBackground))
                        } else {
                            Circle().fill(.regularMaterial)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(menu.accessibilityLabel)
            .accessibilityIdentifier("phone-page-actions-menu")
        }
    }
}
