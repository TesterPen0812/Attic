import SwiftUI

struct CanvasToolControls: View {
    @ObservedObject var session: CanvasSession

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CanvasTool.allCases) { tool in
                CanvasToolButton(
                    tool: tool,
                    isSelected: session.tool == tool
                ) {
                    session.selectTool(tool)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas tools")
    }
}

struct CanvasPaletteControls: View {
    @ObservedObject var session: CanvasSession

    var body: some View {
        HStack(spacing: 5) {
            ForEach(CanvasInkColor.allCases) { color in
                CanvasColorButton(
                    color: color,
                    isSelected: session.color == color
                        && session.tool == .pen
                ) {
                    session.selectColor(color)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ink color")
    }
}

struct CanvasWidthControl: View {
    @ObservedObject var session: CanvasSession
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            Image(systemName: "lineweight")
                .font(.caption)
                .foregroundStyle(.secondary)
                .atticClearGlassForegroundReadability()
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { session.width },
                    set: { session.setWidth($0) }
                ),
                in: CanvasSession.minimumWidth...CanvasSession.maximumWidth
            )
            .accessibilityLabel("Pen width")
            .accessibilityValue(widthLabel)
            .accessibilityIdentifier("canvas-width")

            Text(widthLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .atticClearGlassForegroundReadability()
                .frame(width: compact ? 22 : 28, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var widthLabel: String {
        session.width.formatted(
            .number.precision(.fractionLength(session.width.rounded() == session.width ? 0 : 1))
        )
    }
}

struct CanvasCommandButton: View {
    let title: String
    let systemImage: String
    let identifier: String
    var isSelected = false
    var isDisabled = false
    var isDestructive = false
    var symbolColor: Color? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : symbolColor ?? Color.primary
                )
                .atticClearGlassForegroundReadability()
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(
                            isSelected
                                ? Color.accentColor
                                : Color.primary.opacity(isHovered ? 0.08 : 0)
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

struct CanvasStrokeCountLabel: View {
    let count: Int

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .atticClearGlassForegroundReadability()
            .contentTransition(.numericText())
            .accessibilityIdentifier("canvas-stroke-count")
    }

    private var label: String {
        count == 1 ? "1 stroke" : "\(count) strokes"
    }
}

private struct CanvasToolButton: View {
    let tool: CanvasTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        CanvasCommandButton(
            title: tool.title,
            systemImage: tool.symbolName,
            identifier: "canvas-tool-\(tool.rawValue)",
            isSelected: isSelected,
            action: action
        )
        .keyboardShortcut(shortcut, modifiers: [])
    }

    private var shortcut: KeyEquivalent {
        switch tool {
        case .select: "v"
        case .pen: "p"
        case .eraser: "e"
        }
    }
}

private struct CanvasColorButton: View {
    let color: CanvasInkColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.22), lineWidth: 0.75)
                    }
                    .padding(4)
                    .overlay {
                        Circle()
                            .stroke(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .atticClearGlassForegroundReadability()
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("canvas-color-\(color.rawValue)")
    }
}

extension CanvasInkColor {
    var swiftUIColor: Color {
        switch self {
        case .ink: .primary
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .orange: .orange
        }
    }
}
