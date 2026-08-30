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

    var body: some View {
        ZStack {
            switch status {
            case .todo:
                Circle()
                    .stroke(priority.color, lineWidth: 1.5)
                    .frame(width: size, height: size)
            case .inProgress:
                Circle()
                    .stroke(priority.color, lineWidth: 1.5)
                    .frame(width: size, height: size)
                // Linear-style half pie: fills most of the ring, thin gap in between.
                Circle()
                    .trim(from: 0, to: 0.5)
                    .rotation(.degrees(90))
                    .fill(priority.color)
                    .frame(width: size * 0.7, height: size * 0.7)
            case .done:
                Circle()
                    .fill(priority.color)
                    .frame(width: size, height: size)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.47, weight: .bold))
                    .foregroundStyle(.white)
            case .backlog:
                Circle()
                    .stroke(
                        priority.color,
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.56)
                    : Color.white.opacity(0.62),
                radius: 0.7,
                y: 0.35
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
