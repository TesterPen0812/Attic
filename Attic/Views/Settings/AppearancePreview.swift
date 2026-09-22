import AppKit
import SwiftUI

/// Geometry of the Settings preview: a miniature of the real panel over a
/// small representative desktop. Pure values so the scale and the
/// accessibility description are unit-testable.
enum AppearancePreviewLayout {
    /// The miniature is the real panel at this fraction of its default size.
    static let scale: CGFloat = 0.46
    static let panelSize = CGSize(
        width: (PanelGeometry.defaultPanelSize.width * scale).rounded(),
        height: (PanelGeometry.defaultPanelSize.height * scale).rounded()
    )
    /// Tall enough for the miniature plus its outside shadow on both sides.
    static let cardHeight: CGFloat = 260
    static let cardCornerRadius: CGFloat = 14

    static func cornerRadius(forPanelCornerSize cornerSize: Double) -> CGFloat {
        guard cornerSize.isFinite else { return AtticStyle.panelCornerRadius * scale }
        return max(4, CGFloat(cornerSize) * scale)
    }

    /// What VoiceOver reads for the single preview element.
    static func accessibilityLabel(
        theme: AtticPanelTheme,
        surface: PanelSurfaceStyle,
        depth: Bool,
        tint: PanelTintLevel,
        appearance: AtticPanelThemeAppearance,
        reduceTransparency: Bool
    ) -> String {
        let surfaceName = reduceTransparency ? "Solid (Reduce Transparency)" : surface.title
        let mode = appearance == .dark ? "Dark" : "Light"
        return "Panel preview: \(theme.title) palette, \(surfaceName) surface, "
            + "Depth \(depth ? "on" : "off"), Tint \(tint.title), \(mode) appearance."
    }
}

/// The live preview: the actual `AtticPanelSurface` pipeline (surface, depth,
/// tint, edge, outside shadow and native-glass controls) drawn at a small
/// scale over a representative backdrop. It is never a picture: every
/// setting change re-renders the same modifier the panel uses, in the
/// effective appearance, and the crossfade obeys Reduce Motion because the
/// modifier does.
struct AppearancePreviewCard: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.colorScheme) private var windowColorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var effectiveColorScheme: ColorScheme {
        switch settings.appearance {
        case .light: .light
        case .dark: .dark
        case .system: windowColorScheme
        }
    }

    private var appearance: AtticPanelThemeAppearance {
        effectiveColorScheme == .dark ? .dark : .light
    }

    private var treatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: effectiveColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }

    private var palette: AtticPanelThemePalette {
        settings.panelTheme.palette(for: effectiveColorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        ZStack {
            AppearancePreviewBackdrop(appearance: appearance)
            AppearancePreviewPanel(
                treatment: treatment,
                palette: palette,
                usesSystemAccent: settings.panelTheme.usesSystemAccent,
                cornerRadius: AppearancePreviewLayout.cornerRadius(forPanelCornerSize: settings.panelCornerSize)
            )
            .frame(width: AppearancePreviewLayout.panelSize.width,
                   height: AppearancePreviewLayout.panelSize.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppearancePreviewLayout.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppearancePreviewLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppearancePreviewLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorSchemeContrast == .increased ? 0.28 : 0.10), lineWidth: 1)
        }
        // The miniature lives in the effective appearance, whatever the
        // Settings window itself is in, so a Dark panel previews as Dark.
        .environment(\.colorScheme, effectiveColorScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppearancePreviewLayout.accessibilityLabel(
            theme: settings.panelTheme,
            surface: settings.panelSurfaceStyle,
            depth: settings.panelDepthEnabled,
            tint: settings.panelTint,
            appearance: appearance,
            reduceTransparency: reduceTransparency
        ))
        .accessibilityIdentifier("setting-appearance-preview")
    }
}

/// A small desktop for the miniature to sit on: soft colour, a few window
/// shapes and lines of "text", so Glass and Frosted show what they transmit
/// and Solid shows that it does not. Deliberately quieter than the busy
/// capture backdrop; it is a stand-in, not a stress test.
private struct AppearancePreviewBackdrop: View {
    let appearance: AtticPanelThemeAppearance

    var body: some View {
        let dark = appearance == .dark
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.17, green: 0.19, blue: 0.27), Color(red: 0.09, green: 0.10, blue: 0.15)]
                    : [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.94, green: 0.93, blue: 0.90)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                Circle()
                    .fill(Color(red: 0.98, green: 0.62, blue: 0.36).opacity(dark ? 0.55 : 0.7))
                    .frame(width: height * 0.9)
                    .blur(radius: 26)
                    .position(x: width * 0.22, y: height * 0.28)
                Circle()
                    .fill(Color(red: 0.36, green: 0.62, blue: 0.98).opacity(dark ? 0.5 : 0.65))
                    .frame(width: height * 0.8)
                    .blur(radius: 26)
                    .position(x: width * 0.8, y: height * 0.7)
                Circle()
                    .fill(Color(red: 0.62, green: 0.86, blue: 0.5).opacity(dark ? 0.4 : 0.55))
                    .frame(width: height * 0.6)
                    .blur(radius: 24)
                    .position(x: width * 0.72, y: height * 0.18)
                // A window with lines of text, half under the panel.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.75))
                    .frame(width: width * 0.62, height: height * 0.58)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(0..<7, id: \.self) { index in
                                Capsule()
                                    .fill((dark ? Color.white : Color.black).opacity(index == 0 ? 0.55 : 0.28))
                                    .frame(width: width * (index == 0 ? 0.22 : [0.44, 0.38, 0.5, 0.3, 0.46, 0.36][index - 1]),
                                           height: index == 0 ? 7 : 5)
                            }
                        }
                        .padding(14)
                    }
                    .position(x: width * 0.36, y: height * 0.6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The miniature panel: the real surface modifier around a few real
/// controls, laid out in scaled points rather than under a transform, so
/// native glass and the shadow render at their true size.
private struct AppearancePreviewPanel: View {
    let treatment: AtticPanelSurfaceTreatment
    let palette: AtticPanelThemePalette
    let usesSystemAccent: Bool
    let cornerRadius: CGFloat

    private let scale = AppearancePreviewLayout.scale

    private var accent: Color {
        usesSystemAccent ? Color.accentColor : palette.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "pin")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 17, height: 17)
                    .atticGlassControl(in: Circle(), interactive: false)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    ForEach(["checklist", "note.text", "scribble.variable"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 6.5, weight: symbol == "checklist" ? .semibold : .regular))
                            .frame(width: 15, height: 15)
                            .background(symbol == "checklist" ? accent.opacity(palette.selectedFillOpacity) : .clear,
                                        in: Circle())
                    }
                }
                .padding(2)
                .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
            }
            .padding(.horizontal, 11)
            .padding(.top, 11)

            VStack(alignment: .leading, spacing: 7) {
                Text("In Progress")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .padding(.leading, 2)
                previewRow(title: "Plan the launch", status: .inProgress, priority: .high)
                Text("To do")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .padding(.leading, 2)
                    .padding(.top, 2)
                previewRow(title: "Write the announcement", status: .todo, priority: .none)
                previewRow(title: "Check the build", status: .todo, priority: .low)
            }
            .padding(.horizontal, 13)
            .padding(.top, 14)

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 6.5, weight: .medium))
                    Text("Add a task…")
                        .font(.system(size: 7))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.secondaryForegroundColor)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .frame(maxWidth: .infinity)
                .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
                Image(systemName: "arrow.up")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .frame(width: 17, height: 17)
                    .atticGlassControl(in: Circle(), interactive: false)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 11)
        }
        .foregroundStyle(palette.primaryForegroundColor, palette.secondaryForegroundColor)
        .environment(\.atticPanelThemePalette, palette)
        .environment(\.atticPanelUsesSystemAccent, usesSystemAccent)
        .environment(\.atticPanelUsesSystemOpaqueSurface, treatment.usesSystemOpaqueSurface)
        .tint(accent)
        .atticPanelSurface(
            treatment: treatment,
            cornerRadius: cornerRadius,
            showsElevation: true
        )
        .allowsHitTesting(false)
    }

    private func previewRow(title: String, status: TaskStatus, priority: TaskPriority) -> some View {
        HStack(spacing: 6) {
            TaskStatusMark(status: status, priority: priority, size: 8)
            Text(title)
                .font(.system(size: 7.5))
                .foregroundStyle(palette.primaryForegroundColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 15)
    }
}
