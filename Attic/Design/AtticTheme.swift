import SwiftUI

// Cross-platform design atoms shared by the macOS panel and the iOS app.

enum AtticMotion {
    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.84)
    static let quick = Animation.easeOut(duration: 0.14)
    static let modeDock = Animation.spring(response: 0.24, dampingFraction: 0.90)
    static let background = Animation.easeInOut(duration: 0.22)
}

extension TaskPriority {
    var color: Color {
        switch self {
        case .none: Color.secondary.opacity(0.5)
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }
}

struct TaskStatusMark: View {
    let status: TaskStatus
    let priority: TaskPriority
    var size: CGFloat = 15
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var clearReadabilityEnabled

    private var indicatorColor: Color {
        priority == .none && clearReadabilityEnabled
            ? Color.primary.opacity(0.78) : priority.color
    }

    var body: some View {
        ZStack {
            switch status {
            case .todo:
                Circle()
                    .stroke(indicatorColor, lineWidth: 1.5)
                    .frame(width: size, height: size)
            case .inProgress:
                Circle()
                    .stroke(indicatorColor, lineWidth: 1.5)
                    .frame(width: size, height: size)
                // Linear-style half pie: fills most of the ring, thin gap in between.
                Circle()
                    .trim(from: 0, to: 0.5)
                    .rotation(.degrees(90))
                    .fill(indicatorColor)
                    .frame(width: size * 0.7, height: size * 0.7)
            case .done:
                Circle()
                    .fill(indicatorColor)
                    .frame(width: size, height: size)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.47, weight: .bold))
                    .foregroundStyle(.white)
            case .backlog:
                Circle()
                    .stroke(
                        indicatorColor,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.2, 2.2])
                    )
                    .frame(width: size, height: size)
            }
        }
        .atticClearGlassForegroundReadability()
    }
}

/// Keeps small foreground details legible when Clear glass transmits a
/// similarly coloured desktop underneath. The treatment is deliberately
/// local to the rendered foreground: it does not add a fill, scrim, material,
/// or any background sampling work to the panel surface.
private struct ClearGlassForegroundReadabilityEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var atticClearGlassForegroundReadabilityEnabled: Bool {
        get { self[ClearGlassForegroundReadabilityEnabledKey.self] }
        set { self[ClearGlassForegroundReadabilityEnabledKey.self] = newValue }
    }
}

enum AtticClearGlassReadabilityPolicy {
    // A tight, centred opposite-tone edge survives both light and dark
    // transmitted content without the old offset glow or a surface scrim.
    static let edgeRadius: CGFloat = 0.45

    static func edgeOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 1 : 0.90
    }

    static func isEnabled(
        isTranslucent: Bool,
        isClearStyle: Bool,
        reduceTransparency: Bool
    ) -> Bool {
        isTranslucent && isClearStyle && !reduceTransparency
    }
}

private struct ClearGlassForegroundReadabilityModifier: ViewModifier {
    @Environment(\.atticClearGlassForegroundReadabilityEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(AtticClearGlassReadabilityPolicy.edgeOpacity(increasedContrast: contrast == .increased))
                    : Color.white.opacity(AtticClearGlassReadabilityPolicy.edgeOpacity(increasedContrast: contrast == .increased)),
                radius: AtticClearGlassReadabilityPolicy.edgeRadius
            )
        } else {
            content
        }
    }
}

extension View {
    func atticClearGlassForegroundReadability() -> some View {
        modifier(ClearGlassForegroundReadabilityModifier())
    }
}
