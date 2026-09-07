import SwiftUI
import UniformTypeIdentifiers

struct CanvasPanelContent: View {
    // Add control + gap + eight tool slots + seven gaps + dock padding,
    // followed by the existing ten-point inset on each side of the toolbar.
    static let fullChromeRequiredWidth: CGFloat = 42 + 10 + 8 * 32 + 7 * 2 + 2 * 8 + 20

    @ObservedObject var session: CanvasSession
    let horizontalInset: CGFloat
    @Binding var isClearConfirmationPresented: Bool
    var bottomOverlayInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var surfaceSize = CGSize(width: 240, height: 300)
    @State private var isCreateCanvasPresented = false
    @State private var isRenameCanvasPresented = false
    @State private var isDeleteCanvasPresented = false
    @State private var isImageImporterPresented = false
    #if !os(macOS)
    @State private var isTextEntryPresented = false
    #endif
    @State private var isStylePopoverPresented = false
    @State private var createCanvasName = ""
    @State private var renameCanvasName = ""
    #if !os(macOS)
    @State private var textEntry = ""
    #endif
    @State private var replacementImageID: UUID?
    @State private var isReplacementImporterPresented = false
    @State private var isImageExporterPresented = false
    @State private var exportDocument: CanvasImageExportDocument?
    @State private var exportType = UTType.png
    @State private var exportError: String?
    #if !os(macOS)
    @FocusState private var isTextEntryFocused: Bool
    #endif

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                board(size: proxy.size)

                canvasStatus
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 10)
                    .padding(.leading, 10)

                if let progress = session.imageImportProgress {
                    importProgress(progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 42)
                        .padding(.horizontal, 10)
                }

                if let pendingPlacement = session.pendingPlacement {
                    Text(pendingPlacement.instruction)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .atticClearGlassForegroundReadability()
                        .padding(.horizontal, 10)
                        .frame(height: 27)
                        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
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
                        .padding(.bottom, 60 + bottomOverlayInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #if os(macOS)
                if let object = session.selectedSemanticObject {
                    semanticSelectionDock(object)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 60 + bottomOverlayInset)
                }
                #endif

                // Keep only one owner of the text/style popover bindings.
                // ViewThatFits can retain an unplaced second toolbar whose
                // presenter competes with the visible button's presenter.
                bottomChrome(compact: proxy.size.width < Self.fullChromeRequiredWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10 + bottomOverlayInset)
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
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            let target = session.captureImageImportTarget()
            let center = session.viewport.center
            let spacing = 18 / session.viewport.scale
            session.startImageImportBatch(CanvasImageImportBatch(
                target: target,
                items: urls.enumerated().map { index, url in
                    CanvasImageImportRequest(source: .file(url), center: CanvasPoint(
                        x: center.x + Double(index) * spacing,
                        y: center.y + Double(index) * spacing
                    ))
                }
            ))
        }
        .fileImporter(
            isPresented: $isReplacementImporterPresented,
            allowedContentTypes: [.image]
        ) { result in
            guard let id = replacementImageID, case let .success(url) = result else { return }
            Task { _ = await session.replaceImage(id, from: url) }
        }
        .fileExporter(
            isPresented: $isImageExporterPresented,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "Canvas image"
        ) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Image export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
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
            Text("Every visible canvas item will be removed. You can undo this during the current session.")
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
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
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
            toolDock(compact: compact)
        }
        .fixedSize(horizontal: true, vertical: false)
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
                .disabled(canvasIsEmpty)
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
                title: "Select Object",
                systemImage: "arrow.up.left",
                identifier: "canvas-tool-select",
                isSelected: session.pendingPlacement == nil && session.tool == .select
            ) {
                guard CanvasEditCommandRoute.finishTextEditing() else { return }
                session.selectTool(.select)
            }
            .keyboardShortcut("v", modifiers: [])

            CanvasCommandButton(
                title: "Pen",
                systemImage: "pencil.tip",
                identifier: "canvas-tool-pen",
                isSelected: session.pendingPlacement == nil && session.tool == .pen
            ) {
                guard CanvasEditCommandRoute.finishTextEditing() else { return }
                session.selectTool(.pen)
            }
            .keyboardShortcut("p", modifiers: [])

            CanvasCommandButton(
                title: "Eraser",
                systemImage: "eraser",
                identifier: "canvas-tool-eraser",
                isSelected: session.pendingPlacement == nil && session.tool == .eraser
            ) {
                guard CanvasEditCommandRoute.finishTextEditing() else { return }
                session.selectTool(.eraser)
            }
            .keyboardShortcut("e", modifiers: [])

            CanvasCommandButton(
                title: "Add Text",
                systemImage: "textformat",
                identifier: "canvas-add-text",
                isSelected: isTextPlacementActive
            ) {
                #if os(macOS)
                let wasActive = isTextPlacementActive
                guard CanvasEditCommandRoute.finishTextEditing() else { return }
                if wasActive { session.cancelPendingPlacement() } else { session.selectTextTool() }
                #else
                if isTextPlacementActive {
                    session.cancelPendingPlacement()
                } else {
                    textEntry = ""
                    isTextEntryPresented = true
                }
                #endif
            }
            #if !os(macOS)
            .popover(isPresented: $isTextEntryPresented, arrowEdge: .bottom) {
                textPlacementPopover
            }
            #endif

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
                    guard CanvasEditCommandRoute.finishTextEditing() else { return }
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
        .frame(width: 32, height: 32)
        .help("Add Shape")
        .accessibilityLabel("Add Shape")
        .accessibilityIdentifier("canvas-add-shape")
    }

    #if !os(macOS)
    private var textPlacementPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add text")
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            TextField("Type something", text: $textEntry)
                .textFieldStyle(.roundedBorder)
                .focused($isTextEntryFocused)
                .onSubmit(beginTextPlacement)

            HStack(spacing: 8) {
                Text("Click its position on the canvas. Double-click placed text to edit it.")
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
    #endif

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
            if let image = session.selectedImage {
                Menu {
                    if session.failedImageIDs.contains(image.id) {
                        Button("Retry Image", systemImage: "arrow.clockwise") {
                            session.retryImageDecode(image.id)
                        }
                    }
                    Button("Locate Replacement…", systemImage: "folder") {
                        replacementImageID = image.id
                        isReplacementImporterPresented = true
                    }
                    Button("Export Original…", systemImage: "square.and.arrow.up") {
                        exportDocument = CanvasImageExportDocument(data: image.encodedData)
                        exportType = UTType(image.contentType) ?? .data
                        isImageExporterPresented = true
                    }
                    Button("Remove Image", systemImage: "trash", role: .destructive) {
                        _ = session.deleteImage(image.id)
                    }
                } label: {
                    Image(systemName: session.failedImageIDs.contains(image.id)
                        ? "exclamationmark.triangle" : "ellipsis")
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Image recovery and export")
            }
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
        var count = session.strokes.count + session.images.count
        #if os(macOS)
        count += session.semanticObjects.count
        #endif
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var canvasIsEmpty: Bool {
        #if os(macOS)
        session.strokes.isEmpty && session.images.isEmpty && session.semanticObjects.isEmpty
        #else
        session.strokes.isEmpty && session.images.isEmpty
        #endif
    }

    #if os(macOS)
    private func semanticSelectionDock(_ object: CanvasSemanticObject) -> some View {
        HStack(spacing: 2) {
            if object.content?.text != nil {
                CanvasCommandButton(title: "Edit Text", systemImage: "text.cursor", identifier: "canvas-object-edit-text") {
                    session.requestSelectedSemanticTextEditing()
                }
            }
            if let content = object.content {
                Menu {
                    Menu("Color") {
                        ForEach(CanvasInkColor.allCases) { color in
                            Button(color.title) {
                                editSemanticStyle(object.id) { $0.color = color }
                            }
                        }
                    }
                    if content.text != nil {
                        Menu("Weight") {
                            ForEach(["regular", "semibold", "bold"], id: \.self) { weight in
                                Button(weight.capitalized) {
                                    editSemanticStyle(object.id) { $0.fontWeight = weight }
                                }
                            }
                        }
                        Menu("Alignment") {
                            ForEach(["left", "center", "right"], id: \.self) { alignment in
                                Button(alignment.capitalized) {
                                    editSemanticStyle(object.id) { $0.alignment = alignment }
                                }
                            }
                        }
                        Menu("Text Size") {
                            ForEach([12, 18, 24, 36, 48, 72], id: \.self) { size in
                                Button("\(size) pt") {
                                    editSemanticStyle(object.id) { $0.fontSize = Double(size) }
                                }
                            }
                        }
                    } else {
                        Menu("Shape") {
                            ForEach(CanvasShapeKind.allCases) { shape in
                                Button(shape.title) {
                                    editSemanticStyle(object.id) { $0.shape = shape }
                                }
                            }
                        }
                        Menu("Line Width") {
                            ForEach([1, 3, 6, 10, 16], id: \.self) { width in
                                Button("\(width) pt") {
                                    editSemanticStyle(object.id) { $0.strokeWidth = Double(width) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Selected object style")
            }
            CanvasCommandButton(title: "Send Object Backward", systemImage: "square.2.layers.3d.bottom.filled",
                identifier: "canvas-object-send-backward", isDisabled: !session.canSendSelectedSemanticBackward) {
                _ = session.moveSelectedSemanticLayer(forward: false)
            }
            CanvasCommandButton(title: "Bring Object Forward", systemImage: "square.2.layers.3d.top.filled",
                identifier: "canvas-object-bring-forward", isDisabled: !session.canBringSelectedSemanticForward) {
                _ = session.moveSelectedSemanticLayer(forward: true)
            }
            CanvasCommandButton(title: "Delete Selected Object", systemImage: "trash", identifier: "canvas-object-delete") {
                _ = session.deleteSemanticObject(object.id)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 36)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected object actions")
    }

    private func editSemanticStyle(_ id: UUID, change: (inout CanvasSemanticContent) -> Void) {
        // Ending inline editing may have saved newer characters after the menu
        // opened. Apply its style choice to that latest persisted content.
        guard var content = session.semanticObjects.first(where: { $0.id == id })?.content else { return }
        change(&content)
        _ = session.editSemanticObject(id, content: content)
    }
    #endif

    private func importProgress(_ progress: CanvasImageImportBatchProgress) -> some View {
        let finished = progress.completedCount == progress.items.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(finished ? "Import complete" : "Importing images")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(progress.completedCount)/\(progress.items.count)")
                    .font(.system(size: 10, design: .monospaced))
                Button {
                    if finished { session.dismissImageImportProgress() }
                    else { session.cancelAllImageImportBatches() }
                } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(finished ? "Dismiss import results" : "Cancel image import")
            }
            if !finished {
                ProgressView(value: Double(progress.completedCount), total: Double(max(progress.items.count, 1)))
            }
            let failures = progress.items.enumerated().compactMap { index, item -> String? in
                guard case let .finished(.failed(failure)) = item.state else { return nil }
                return "Image \(index + 1): \(failure.message)"
            }
            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxHeight: 72)
                if finished {
                    Button("Choose Failed Files Again…") { isImageImporterPresented = true }
                        .font(.system(size: 10))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 240)
        .atticGlassControl(in: RoundedRectangle(cornerRadius: 12), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image import progress")
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
