import SwiftUI

struct MobileCanvasScreen: View {
    @ObservedObject var session: CanvasSession
    let iCloudAvailability: ICloudAvailability

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var surfaceSize = CGSize(width: 300, height: 420)
    @State private var isClearConfirmationPresented = false
    @State private var isCreatePresented = false
    @State private var isRenamePresented = false
    @State private var isDeletePresented = false
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            board
            footer
        }
        .background(Color(uiColor: .systemBackground))
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
            isPresented: $isDeletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Canvas", role: .destructive) {
                _ = session.deleteSelectedCanvas()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Canvas", isPresented: $isCreatePresented) {
            TextField("Canvas name", text: $draftName)
            Button("Create") {
                _ = session.createCanvas(name: draftName)
                draftName = ""
            }
            Button("Cancel", role: .cancel) { draftName = "" }
        }
        .alert("Rename Canvas", isPresented: $isRenamePresented) {
            TextField("Canvas name", text: $draftName)
            Button("Rename") {
                _ = session.renameSelectedCanvas(to: draftName)
                draftName = ""
            }
            Button("Cancel", role: .cancel) { draftName = "" }
        }
        .onDisappear {
            session.cancelActiveInteraction()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
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
                        draftName = ""
                        isCreatePresented = true
                    } label: {
                        Label("New Canvas", systemImage: "plus")
                    }
                    Button {
                        draftName = session.selectedCanvas.name
                        isRenamePresented = true
                    } label: {
                        Label("Rename Canvas", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isDeletePresented = true
                    } label: {
                        Label("Delete Canvas", systemImage: "trash")
                    }
                    .disabled(session.canvases.count <= 1)
                } label: {
                    HStack(spacing: 5) {
                        Text(session.selectedCanvas.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Canvas menu")
                .accessibilityValue(session.selectedCanvas.name)
                .accessibilityIdentifier("canvas-document-menu")

                Text(contentCountTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("canvas-content-count")
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var controls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                CanvasToolControls(session: session)

                Divider()
                    .frame(height: 22)

                CanvasCommandButton(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward",
                    identifier: "canvas-undo",
                    isDisabled: !session.canUndo
                ) {
                    _ = session.undo()
                }

                CanvasCommandButton(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward",
                    identifier: "canvas-redo",
                    isDisabled: !session.canRedo
                ) {
                    _ = session.redo()
                }

                Spacer(minLength: 3)

                CanvasCommandButton(
                    title: "Fit content",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    identifier: "canvas-fit"
                ) {
                    session.fit(in: surfaceSize)
                }

                CanvasCommandButton(
                    title: "Reset view",
                    systemImage: "scope",
                    identifier: "canvas-reset-view"
                ) {
                    session.resetView()
                }

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

            HStack(spacing: 8) {
                CanvasPaletteControls(session: session)
                Spacer(minLength: 2)
                CanvasWidthControl(session: session, compact: true)
                    .frame(minWidth: 82, idealWidth: 108, maxWidth: 132)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 9)
    }

    private var board: some View {
        GeometryReader { proxy in
            CanvasSurface(session: session)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.13), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .onAppear {
                    surfaceSize = proxy.size
                }
                .onChange(of: proxy.size) { _, newSize in
                    surfaceSize = newSize
                }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let message = session.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("canvas-error-message")
            }

            HStack(spacing: 5) {
                Image(systemName: syncSymbol)
                    .font(.system(size: 10, weight: .medium))
                Text(syncTitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var contentCountTitle: String {
        let count = session.strokes.count + session.images.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var syncSymbol: String {
        switch iCloudAvailability {
        case .available: "icloud"
        case .checking: "icloud"
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            "exclamationmark.icloud"
        }
    }

    private var syncTitle: String {
        iCloudAvailability.title
    }
}
