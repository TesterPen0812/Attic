import SwiftUI

struct CanvasPanelContent: View {
    @ObservedObject var session: CanvasSession
    let horizontalInset: CGFloat
    @Binding var isClearConfirmationPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceSize = CGSize(width: 240, height: 300)
    @State private var isCreateCanvasPresented = false
    @State private var isRenameCanvasPresented = false
    @State private var isDeleteCanvasPresented = false
    @State private var createCanvasName = ""
    @State private var renameCanvasName = ""

    var body: some View {
        VStack(spacing: 7) {
            canvasPickerRow
            commandRow
            styleRow
            board
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 12)
        .confirmationDialog(
            "Clear \(session.selectedCanvas.name)?",
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Confirm Clear Canvas", role: .destructive) {
                _ = session.clear()
            }
            .accessibilityIdentifier("Confirm Clear Canvas")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every visible stroke and image will be removed. You can undo this during the current session.")
        }
        .confirmationDialog(
            "Delete \(session.selectedCanvas.name)?",
            isPresented: $isDeleteCanvasPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Canvas", role: .destructive) {
                _ = session.deleteSelectedCanvas()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the canvas and its synced content from the canvas list.")
        }
        .alert("New Canvas", isPresented: $isCreateCanvasPresented) {
            TextField("Canvas name", text: $createCanvasName)
            Button("Create") {
                _ = session.createCanvas(name: createCanvasName)
                createCanvasName = ""
            }
            Button("Cancel", role: .cancel) {
                createCanvasName = ""
            }
        } message: {
            Text("Create a separate autosaved drawing space.")
        }
        .alert("Rename Canvas", isPresented: $isRenameCanvasPresented) {
            TextField("Canvas name", text: $renameCanvasName)
            Button("Rename") {
                _ = session.renameSelectedCanvas(to: renameCanvasName)
                renameCanvasName = ""
            }
            Button("Cancel", role: .cancel) {
                renameCanvasName = ""
            }
        }
    }

    private var canvasPickerRow: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(session.canvases) { canvas in
                    Button {
                        _ = session.selectCanvas(canvas.id)
                    } label: {
                        Label(
                            canvas.name,
                            systemImage: canvas.id == session.selectedCanvasID
                                ? "checkmark"
                                : "rectangle.on.rectangle"
                        )
                    }
                }

                Divider()

                Button {
                    createCanvasName = ""
                    isCreateCanvasPresented = true
                } label: {
                    Label("New Canvas", systemImage: "plus")
                }

                Button {
                    renameCanvasName = session.selectedCanvas.name
                    isRenameCanvasPresented = true
                } label: {
                    Label("Rename Canvas", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    isDeleteCanvasPresented = true
                } label: {
                    Label("Delete Canvas", systemImage: "trash")
                }
                .disabled(session.canvases.count <= 1)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(session.selectedCanvas.name)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.11), lineWidth: 0.75)
                }
            }
            .menuStyle(.borderlessButton)
            .help("Switch or manage canvases")
            .accessibilityLabel("Canvas menu")
            .accessibilityValue(session.selectedCanvas.name)
            .accessibilityIdentifier("canvas-document-menu")

            Spacer(minLength: 4)

            Text(contentCountLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityIdentifier("canvas-content-count")
        }
        .frame(height: 24)
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
                title: "Fit content",
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
                isDisabled: session.strokes.isEmpty && session.images.isEmpty,
                isDestructive: true
            ) {
                isClearConfirmationPresented = true
            }
        }
    }

    @ViewBuilder
    private var styleRow: some View {
        if let selected = session.selectedImage {
            HStack(spacing: 6) {
                CanvasCommandButton(
                    title: "Send image backward",
                    systemImage: "square.2.layers.3d.bottom.filled",
                    identifier: "canvas-image-send-backward"
                ) {
                    _ = session.sendSelectedImageBackward()
                }
                .keyboardShortcut("[", modifiers: .command)

                CanvasCommandButton(
                    title: "Bring image forward",
                    systemImage: "square.2.layers.3d.top.filled",
                    identifier: "canvas-image-bring-forward"
                ) {
                    _ = session.bringSelectedImageForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                CanvasCommandButton(
                    title: "Delete selected image",
                    systemImage: "trash",
                    identifier: "canvas-image-delete",
                    isDestructive: true
                ) {
                    _ = session.deleteSelectedImage()
                }

                Spacer(minLength: 4)

                let sizeLabel = canvasDimensionLabel(selected.width)
                    + " × "
                    + canvasDimensionLabel(selected.height)
                Text(sizeLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(
                        "Selected image size, \(sizeLabel.replacingOccurrences(of: " × ", with: " by "))"
                    )
            }
        } else {
            HStack(spacing: 8) {
                CanvasPaletteControls(session: session)
                Spacer(minLength: 2)
                CanvasWidthControl(session: session, compact: true)
                    .frame(minWidth: 76, idealWidth: 96, maxWidth: 118)
            }
        }
    }

    private var board: some View {
        GeometryReader { proxy in
            CanvasSurface(session: session)
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
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    private var contentCountLabel: String {
        let count = session.strokes.count + session.images.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func canvasDimensionLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
