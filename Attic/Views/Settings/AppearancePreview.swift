import SwiftUI

/// What the live preview at the top of Appearance says to VoiceOver: the
/// look it shows, in words. Pure, so the copy is unit-testable.
enum AppearancePreviewDescription {
    static func accessibilityLabel(
        theme: AtticPanelTheme,
        surface: PanelSurfaceStyle,
        tint: PanelTintLevel,
        tintLength: Double = PanelTintLength.defaultValue,
        appearance: AtticPanelThemeAppearance,
        reduceTransparency: Bool
    ) -> String {
        let surfaceName = reduceTransparency ? "Solid (Reduce Transparency)" : surface.title
        let mode = appearance == .dark ? "Dark" : "Light"
        let length = tint == .off
            ? ""
            : " (" + AppearanceSettingsPresentation.tintLengthDescription(tintLength).lowercased() + ")"
        return "Panel preview: \(theme.title) palette, \(surfaceName) surface, "
            + "Tint \(tint.title)\(length), \(mode) appearance."
    }
}

/// The panel in miniature, drawn by the design system exactly as the
/// panel draws itself: its surface (palette, Surface, Tint and Tint length,
/// in the window's Light or Dark), the squircle at the chosen corner size,
/// the header's controls, the page tabs, the first rows, Completed today
/// and the add bar, on the live panel's lines (`PanelPageLayout`). It is a
/// picture: nothing in it can be clicked or focused, and it shows sample
/// tasks, never the person's own.
struct SettingsPanelMiniature: View {
    let cornerSize: CGFloat

    @Environment(\.atticDesign) private var design

    private static let pages: [AtticPageButton<Int>.Item] = [
        .init(page: 0, systemName: "checkmark.circle", title: String(localized: "Tasks"), shortcut: "⌘1"),
        .init(page: 1, systemName: "note.text", title: String(localized: "Notes"), shortcut: "⌘2"),
        .init(page: 2, systemName: "scribble.variable", title: String(localized: "Canvas"), shortcut: "⌘3")
    ]

    /// Sample tasks (the approved v4 mockup's).
    private static let rows: [AtticTaskRowModel] = [
        .init(title: String(localized: "Finalize launch checklist"), state: .inProgress, priority: .high,
              due: .init(text: String(localized: "Today"), tone: .today), tags: ["launch"], subtasks: (1, 3)),
        .init(title: String(localized: "Ship appearance PR"), state: .todo, priority: .high, subtasks: (2, 4)),
        .init(title: String(localized: "Email beta testers"), state: .todo, priority: .medium,
              due: .init(text: String(localized: "Fri"))),
        .init(title: String(localized: "Book dentist"), state: .todo,
              due: .init(text: String(localized: "Tomorrow")))
    ]

    private static let tabs: [AtticPageTabs<Int>.Item] = [
        .init(page: 0, title: String(localized: "Now")),
        .init(page: 1, title: String(localized: "Later")),
        .init(page: 2, title: String(localized: "Done"))
    ]

    private static let noActions = AtticTaskActions(
        toggleDone: {}, toggleWorking: {}, openPage: {}, moveToBacklog: {}, delete: {}
    )

    var body: some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        // The live panel's lines at this corner size: the controls' inset
        // grows with bigger corners, and the page follows it.
        let layout = PanelPageLayout(cornerSize: cornerSize, panelSize: AtticLayout.panelSize)
        let chrome = layout.chromeInsets.leading
        let pageInset = max(0, chrome - AtticSpacing.panelMargin)
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: layout.headerBottom + AtticLayout.pageTabsTop)
                AtticPageTabs(items: Self.tabs, selection: .constant(0))
                    .padding(.leading, AtticLayout.pageTabsX)
                    .padding(.bottom, AtticLayout.pageTabsToList)
                ForEach(Self.rows) { row in
                    AtticTaskRow(model: row, actions: Self.noActions, onToggleExpanded: {})
                }
                AtticCompletedLine(title: String(localized: "Completed today"), count: 1, isExpanded: false) {}
                    .padding(.top, AtticCompletedLineMetrics.top)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, pageInset)
            AtticControlGroup {
                HStack(spacing: 0) {
                    AtticRaisedButton(systemName: "pin", label: "Pin",
                                      glyphOffsetY: AtticRaisedButtonMetrics.pinGlyphOffsetY, emphasisedGlyph: true) {}
                    Spacer(minLength: AtticSpacing.betweenControls)
                    AtticPageButton(items: Self.pages, selection: .constant(0), pinnedOpen: false)
                }
            }
            .padding(chrome)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AtticAddBar(placeholder: "Add a task", text: .constant(""), onSubmit: {})
            }
            .padding(max(AtticSpacing.panelMargin, chrome))
        }
        .frame(width: AtticLayout.panelSize.width, height: AtticLayout.panelSize.height)
        .background(AtticSurfaceBackground(model: design.tokens.panel, shape: shape, tintHeight: AtticLayout.panelSize.height))
        .clipShape(shape)
        .overlay(AtticPanelRim(cornerSize: cornerSize))
        // A picture: every control rests, none takes a click or focus.
        .atticForcedState(.rest)
        .disabled(true)
        .accessibilityHidden(true)
    }
}
