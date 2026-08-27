import SwiftUI

struct CanvasPanelContent: View {
    @ObservedObject var session: CanvasSession
    let horizontalInset: CGFloat
    @Binding var isClearConfirmationPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceSize = CGSize(width: 240, height: 300)

    var body: some View {
        VStack(spacing: 7) {
            commandRow
            styleRow
            board
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 12)
        .confirmationDialog(
            "Clear the entire canvas?",
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Confirm Clear Canvas", role: .destructive) {
                _ = session.clear()
            }
            .accessibilityIdentifier("Confirm Clear Canvas")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every visible stroke will be removed. You can undo this during the current session.")
        }
    }

    private var commandRow: some View {
        HStack(spacing: 5) {
            CanvasToolControls(session: session)

            Divider()
                .frame(height: 20)

            CanvasCommandButton(
                title: "Undo",
                systemImage: "arrow.uturn.backward",
                identifier: "canvas-undo",
                isDisabled: !session.canUndo
            ) {
                _ = session.undo()
            }
            .keyboardShortcut("z", modifiers: .command)

            CanvasCommandButton(
                title: "Redo",
                systemImage: "arrow.uturn.forward",
                identifier: "canvas-redo",
                isDisabled: !session.canRedo
            ) {
                _ = session.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer(minLength: 4)

            CanvasCommandButton(
                title: "Fit drawing",
                systemImage: "arrow.up.left.and.arrow.down.right",
                identifier: "canvas-fit"
            ) {
                session.fit(in: surfaceSize)
            }
            .keyboardShortcut("9", modifiers: .command)

            CanvasCommandButton(
                title: "Reset view",
                systemImage: "scope",
                identifier: "canvas-reset-view"
            ) {
                session.resetView()
            }
            .keyboardShortcut("0", modifiers: .command)

            CanvasCommandButton(
                title: "Clear canvas",
                systemImage: "trash",
                identifier: "canvas-clear",
                isDisabled: session.strokes.isEmpty,
                isDestructive: true
            ) {
                isClearConfirmationPresented = true
            }
        }
    }

    private var styleRow: some View {
        HStack(spacing: 8) {
            CanvasPaletteControls(session: session)
            Spacer(minLength: 2)
            CanvasWidthControl(session: session, compact: true)
                .frame(minWidth: 76, idealWidth: 96, maxWidth: 118)
        }
    }

    private var board: some View {
        GeometryReader { proxy in
            ZStack {
                CanvasSurface(session: session)

                if session.strokes.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 18, weight: .medium))
                        Text("Draw anywhere")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        Text("Space-drag, right-drag, or use the trackpad to move.")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .onAppear {
                surfaceSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                surfaceSize = newSize
            }
        }
        .overlay(alignment: .bottomTrailing) {
            CanvasStrokeCountLabel(count: session.strokes.count)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(7)
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }
}
