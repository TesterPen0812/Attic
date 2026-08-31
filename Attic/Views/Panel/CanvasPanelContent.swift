import SwiftUI
import UniformTypeIdentifiers

struct CanvasPanelContent: View {
    @ObservedObject var session: CanvasSession
    let horizontalInset: CGFloat
    @Binding var isClearConfirmationPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var surfaceSize = CGSize(width: 240, height: 300)
    @State private var isCreateCanvasPresented = false
    @State private var isRenameCanvasPresented = false
    @State private var isDeleteCanvasPresented = false
    @State private var isImageImporterPresented = false
    @State private var isTextEntryPresented = false
    @State private var isStylePopoverPresented = false
    @State private var createCanvasName = ""
    @State private var renameCanvasName = ""
    @State private var textEntry = ""
    @FocusState private var isTextEntryFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                board(size: proxy.size)

                canvasStatus
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 10)
                    .padding(.leading, 10)

                if let pendingPlacement = session.pendingPlacement {
                    Text(pendingPlacement.instruction)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .atticClearGlassForegroundReadability()
                        .padding(.horizontal, 10)
                        .frame(height: 27)
                        .background(.thinMaterial, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
                        }
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding(.top, 41)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                        .accessibilityLabel(pendingPlacement.instruction)
                }

                if session.selectedImage != nil {
                    imageSelectionDock
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 60)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                bottomChrome(compact: proxy.size.width < 350)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .onAppear {
                surfaceSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                surfaceSize = newSize
            }
        }
        .padding(.horizontal, max(horizontalInset - 8, 8))
        .padding(.bottom, 4)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: session.selectedImageID
        )
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first else {
                return
            }
            Task {
                _ = await session.importImage(url: url, at: session.viewport.center)
            }
        }
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
            Text("This removes the canvas and its saved content from the canvas list.")
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

    private func board(size: CGSize) -> some View {
        CanvasSurface(session: session)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    private var canvasStatus: some View {
        HStack(spacing: 5) {
            Text(session.selectedCanvas.name)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .atticClearGlassForegroundReadability()
            Text("·")
                .foregroundStyle(.tertiary)
                .atticClearGlassForegroundReadability()
            Text(contentCountLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .atticClearGlassForegroundReadability()
                .contentTransition(.numericText())
                .accessibilityIdentifier("canvas-content-count")
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    private func bottomChrome(compact: Bool) -> some View {
        HStack(alignment: .bottom, spacing: compact ? 6 : 10) {
            addMenu(compact: compact)
            Spacer(minLength: 0)
            toolDock(compact: compact)
            Spacer(minLength: 0)
        }
        .atticGlassEffectContainer(spacing: compact ? 6 : 10)
    }

    private func addMenu(compact: Bool) -> some View {
        Menu {
            Button {
                isImageImporterPresented = true
            } label: {
                Label("Import Image…", systemImage: "photo.badge.plus")
            }

            Divider()

            Section("Canvases") {
                ForEach(session.canvases) { canvas in
                    Button {
                        _ = session.selectCanvas(canvas.id)
                    } label: {
                        Label(
                            canvas.name,
                            systemImage: canvas.id == session.selectedCanvasID
                                ? "checkmark"
                                : "square.on.square"
                        )
                    }
                }
            }

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

            Divider()

            Menu("View") {
                Button("Fit Content", systemImage: "arrow.up.left.and.arrow.down.right") {
                    session.fit(in: surfaceSize)
                }
                .keyboardShortcut("9", modifiers: .command)

                Button("Reset View", systemImage: "scope") {
                    session.resetView()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            Menu("Edit") {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    _ = session.undo()
                }
                .disabled(!session.canUndo)

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    _ = session.redo()
                }
                .disabled(!session.canRedo)

                Divider()

                Button("Clear Canvas", systemImage: "trash", role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(session.strokes.isEmpty && session.images.isEmpty)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .accessibilityIdentifier("canvas-clear")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: compact ? 15 : 17, weight: .medium))
                .atticClearGlassForegroundReadability()
                .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
        .atticGlassControl(in: Circle())
        .help("Add to Canvas")
        .accessibilityLabel("Canvas menu")
        .accessibilityValue(session.selectedCanvas.name)
        .accessibilityIdentifier("canvas-document-menu")
    }

    private func toolDock(compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : 2) {
            CanvasCommandButton(
                title: "Select",
                systemImage: "arrow.up.left",
                identifier: "canvas-tool-select",
                isSelected: session.pendingPlacement == nil && session.tool == .select
            ) {
                session.selectTool(.select)
            }
            .keyboardShortcut("v", modifiers: [])

            CanvasCommandButton(
                title: "Pen",
                systemImage: "pencil.tip",
                identifier: "canvas-tool-pen",
                isSelected: session.pendingPlacement == nil && session.tool == .pen
            ) {
                session.selectTool(.pen)
            }
            .keyboardShortcut("p", modifiers: [])

            CanvasCommandButton(
                title: "Eraser",
                systemImage: "eraser",
                identifier: "canvas-tool-eraser",
                isSelected: session.pendingPlacement == nil && session.tool == .eraser
            ) {
                session.selectTool(.eraser)
            }
            .keyboardShortcut("e", modifiers: [])

            CanvasCommandButton(
                title: "Add Text",
                systemImage: "textformat",
                identifier: "canvas-add-text",
                isSelected: isTextPlacementActive
            ) {
                if isTextPlacementActive {
                    session.cancelPendingPlacement()
                } else {
                    textEntry = ""
                    isTextEntryPresented = true
                }
            }
            .popover(isPresented: $isTextEntryPresented, arrowEdge: .bottom) {
                textPlacementPopover
            }

            shapeMenu

            CanvasCommandButton(
                title: "Ink and Width",
                systemImage: "circle.fill",
                identifier: "canvas-style",
                symbolColor: session.color.swiftUIColor
            ) {
                isStylePopoverPresented.toggle()
            }
            .popover(isPresented: $isStylePopoverPresented, arrowEdge: .bottom) {
                stylePopover
            }

            CanvasCommandButton(
                title: "Undo",
                systemImage: "arrow.uturn.backward",
                identifier: "canvas-undo",
                isDisabled: !session.canUndo
            ) {
                _ = session.undo()
            }

            if !compact {
                CanvasCommandButton(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward",
                    identifier: "canvas-redo",
                    isDisabled: !session.canRedo
                ) {
                    _ = session.redo()
                }
            }
        }
        .padding(.horizontal, compact ? 5 : 8)
        .frame(height: compact ? 36 : 42)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas tools")
    }

    private var shapeMenu: some View {
        Menu {
            ForEach(CanvasShapeKind.allCases) { shape in
                Button {
                    session.prepareShapePlacement(shape)
                } label: {
                    Label(shape.title, systemImage: shape.symbolName)
                }
            }
        } label: {
            Image(systemName: pendingShape?.symbolName ?? "square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pendingShape == nil ? Color.primary : Color.white)
                .atticClearGlassForegroundReadability()
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(pendingShape == nil ? Color.clear : Color.accentColor)
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add Shape")
        .accessibilityLabel("Add Shape")
        .accessibilityIdentifier("canvas-add-shape")
    }

    private var textPlacementPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add text")
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            TextField("Type something", text: $textEntry)
                .textFieldStyle(.roundedBorder)
                .focused($isTextEntryFocused)
                .onSubmit(beginTextPlacement)

            HStack(spacing: 8) {
                Text("Then click its position on the canvas.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Place", action: beginTextPlacement)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        textEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(12)
        .frame(width: 270)
        .onAppear {
            isTextEntryFocused = true
        }
    }

    private func beginTextPlacement() {
        guard session.prepareTextPlacement(
            textEntry,
            prefersDarkSurface: colorScheme == .dark
        ) else { return }
        textEntry = ""
        isTextEntryPresented = false
    }

    private var stylePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ink")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            CanvasPaletteControls(session: session)

            Divider()

            Text("Width")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            CanvasWidthControl(session: session)
                .frame(width: 190)
        }
        .padding(14)
    }

    private var imageSelectionDock: some View {
        HStack(spacing: 2) {
            CanvasCommandButton(
                title: "Send Image Backward",
                systemImage: "square.2.layers.3d.bottom.filled",
                identifier: "canvas-image-send-backward"
            ) {
                _ = session.sendSelectedImageBackward()
            }
            .disabled(!session.canSendSelectedImageBackward)
            .keyboardShortcut("[", modifiers: .command)

            CanvasCommandButton(
                title: "Bring Image Forward",
                systemImage: "square.2.layers.3d.top.filled",
                identifier: "canvas-image-bring-forward"
            ) {
                _ = session.bringSelectedImageForward()
            }
            .disabled(!session.canBringSelectedImageForward)
            .keyboardShortcut("]", modifiers: .command)

            CanvasCommandButton(
                title: "Delete Selected Image",
                systemImage: "trash",
                identifier: "canvas-image-delete"
            ) {
                _ = session.deleteSelectedImage()
            }

            if let selected = session.selectedImage {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)

                Text(
                    "\(canvasDimensionLabel(selected.width)) × \(canvasDimensionLabel(selected.height))"
                )
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .atticClearGlassForegroundReadability()
                .padding(.trailing, 8)
                .accessibilityLabel("Selected image size")
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 36)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected image actions")
    }

    private var contentCountLabel: String {
        let count = session.strokes.count + session.images.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var isTextPlacementActive: Bool {
        guard case .text? = session.pendingPlacement else { return false }
        return true
    }

    private var pendingShape: CanvasShapeKind? {
        guard case let .shape(shape)? = session.pendingPlacement else { return nil }
        return shape
    }

    private func canvasDimensionLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
