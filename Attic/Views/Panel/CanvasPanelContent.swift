import SwiftUI
import UniformTypeIdentifiers

struct CanvasPanelContent: View {
    // 42 (add control) + 10 (gap) + 8 * 32 (tool slots) + 7 * 2 (gaps)
    // + 2 * 8 (dock padding) + 20 (ten-point insets on both toolbar sides).
    // Written precomputed: Xcode 26.2's type checker times out on the
    // literal arithmetic in this otherwise trivial declaration.
    static let fullChromeRequiredWidth: CGFloat = 358

    @ObservedObject var session: CanvasSession
    let horizontalInset: CGFloat
    @Binding var isClearConfirmationPresented: Bool
    var bottomOverlayInset: CGFloat = 0
    var topOverlayInset: CGFloat = 0
    var mainControlRects: [CGRect] = []
    @State private var controlRects: [CGRect] = []
    @State private var isShapeHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.atticPanelThemePalette) private var palette
    private var selectedShapeForeground: Color {
        #if os(macOS)
        palette.accent.contrastingForeground.swiftUIColor()
        #else
        .white
        #endif
    }
    // Undo/Redo availability is route-only, exactly like the app Edit commands:
    // a focused text editor owns them, and canvas history owns them otherwise.
    // Adding a session term here made these controls render enabled while the
    // route refused to act on them, disagreeing with the app Edit menu.
    // Reading the editing-availability token keeps SwiftUI re-evaluating while
    // typing, which deliberately never republishes canvas history.
    private var canUndoCanvasEdit: Bool {
        let _ = session.editingAvailabilityToken
        return CanvasEditCommandRoute.canUndo(session: session, section: .canvas)
    }
    private var canRedoCanvasEdit: Bool {
        let _ = session.editingAvailabilityToken
        return CanvasEditCommandRoute.canRedo(session: session, section: .canvas)
    }
    /// The deliberate "waiting to be placed" fill. It must not be read from
    /// the environment accent: quieting the glyph overrides that accent for
    /// this subtree, so `Color.accentColor` here repainted the circle in the
    /// glyph's own colour and hid the symbol on top of it. The panel palette's
    /// accent is also the colour `selectedShapeForeground` is chosen to
    /// contrast with, so the signal now reads on every theme.
    private var pendingShapeFill: Color {
        #if os(macOS)
        palette.accentColor
        #else
        Color.accentColor
        #endif
    }

    private var secondaryForeground: Color {
        #if os(macOS)
        palette.secondaryForegroundColor
        #else
        .secondary
        #endif
    }
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
    @State private var dismissedImageFailureIDs: Set<UUID> = []
    #if !os(macOS)
    @FocusState private var isTextEntryFocused: Bool
    #endif

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                board(size: proxy.size)

                canvasStatus
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, topOverlayInset + 8)
                    .padding(.leading, 10)

                if let progress = session.imageImportProgress {
                    importProgress(progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, topOverlayInset + 38)
                        .padding(.horizontal, 10)
                }

                if session.pendingPlacement == nil, !visibleImageFailureIDs.isEmpty {
                    imageRecoveryNotice
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding(.top, topOverlayInset + 38)
                        .padding(.leading, 10)
                }

                if let pendingPlacement = session.pendingPlacement {
                    Text(pendingPlacement.instruction)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryForeground)
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
                        .padding(.top, topOverlayInset + 38)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                        .accessibilityLabel(pendingPlacement.instruction)
                }

                if session.selectedImage != nil {
                    imageSelectionDock
                        .background(controlRegion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 106 + bottomOverlayInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #if os(macOS)
                if let object = session.selectedSemanticObject {
                    semanticSelectionDock(object)
                        .background(controlRegion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 106 + bottomOverlayInset)
                }
                #endif

                // Keep only one owner of the text/style popover bindings.
                // ViewThatFits can retain an unplaced second toolbar whose
                // presenter competes with the visible button's presenter.
                bottomChrome(compact: proxy.size.width < Self.fullChromeRequiredWidth)
                    .background(controlRegion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10 + bottomOverlayInset)
            }
            .coordinateSpace(name: "attic.canvas.surface")
            .onPreferenceChange(CanvasControlFramesKey.self) { controlRects = $0 }
            .onAppear {
                surfaceSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                surfaceSize = newSize
            }
            .onChange(of: session.failedImageIDs) { _, failures in
                // Keep the dismissal scoped to the failures the user saw, so a
                // new failure raises the notice again.
                dismissedImageFailureIDs.formIntersection(failures)
            }
        }
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

    private var controlRegion: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CanvasControlFramesKey.self,
                                   value: [proxy.frame(in: .named("attic.canvas.surface"))])
        }
    }

    private func board(size: CGSize) -> some View {
        CanvasSurface(
            session: session,
            excludedRects: controlRects + mainControlRects,
            onRequestImageExport: { presentExport(of: $0) }
        )
        .frame(width: size.width, height: size.height)
    }

    /// Recovery for images whose bytes are present but cannot be decoded
    /// (CANVAS-012). It appears only while a failure is live, states the
    /// problem in one line, and offers retry, selection for
    /// replace/export/remove, and dismissal.
    private var imageRecoveryNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryForeground)
            Text(failedImageLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .atticClearGlassForegroundReadability()
            Button("Retry") {
                _ = session.retryFailedImageDecodes()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .accessibilityIdentifier("canvas-image-recovery-retry")
            Button {
                dismissedImageFailureIDs = session.failedImageIDs
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryForeground)
            .accessibilityLabel("Dismiss image warning")
            .accessibilityIdentifier("canvas-image-recovery-dismiss")
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(failedImageLabel)
    }

    private var visibleImageFailureIDs: Set<UUID> {
        session.failedImageIDs.subtracting(dismissedImageFailureIDs)
    }

    private var failedImageLabel: String {
        let count = visibleImageFailureIDs.count
        return count == 1
            ? "1 image could not be displayed"
            : "\(count) images could not be displayed"
    }

    private func presentExport(of image: CanvasPlacedImage) {
        exportDocument = CanvasImageExportDocument(data: image.encodedData)
        exportType = UTType(image.contentType) ?? .data
        isImageExporterPresented = true
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
                .foregroundStyle(secondaryForeground)
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
        VStack(spacing: 6) {
            toolDock(compact: compact)
            HStack(spacing: 4) {
                addMenu(compact: true)
                CanvasCommandButton(title: "Undo", systemImage: "arrow.uturn.backward",
                    identifier: "canvas-undo", isDisabled: !canUndoCanvasEdit) {
                    _ = CanvasEditCommandRoute.undo(session: session, section: .canvas)
                }
                CanvasCommandButton(title: "Redo", systemImage: "arrow.uturn.forward",
                    identifier: "canvas-redo", isDisabled: !canRedoCanvasEdit) {
                    _ = CanvasEditCommandRoute.redo(session: session, section: .canvas)
                }
                Divider().frame(height: 16)
                CanvasCommandButton(title: "Fit Canvas", systemImage: "arrow.up.left.and.arrow.down.right",
                    identifier: "canvas-fit-view") { session.fit(in: surfaceSize, excluding: controlRects + mainControlRects) }
                Menu {
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom(by: 1.25) }
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(by: 0.8) }
                    Divider()
                    Button("Actual Size (100%)") { session.resetView() }
                        .accessibilityIdentifier("canvas-reset-view")
                } label: {
                    Text("\(Int((session.viewport.scale * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(width: 44, height: 36)
                        .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Zoom · pinch or use Command + / −")
                .accessibilityLabel("Zoom \(Int((session.viewport.scale * 100).rounded())) percent")
                .accessibilityIdentifier("canvas-zoom")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .atticGlassControl(in: Capsule(), interactive: false)
        }
        .fixedSize()
        .atticGlassEffectContainer(spacing: 6)
        .onHover { inside in
            #if os(macOS)
            if inside { NSCursor.arrow.set() }
            #endif
        }
    }

    private func zoom(by factor: Double) {
        session.interruptActiveInteraction()
        session.zoom(by: factor, anchoredAt: CGPoint(x: surfaceSize.width / 2, y: surfaceSize.height / 2), in: surfaceSize)
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
                        guard CanvasEditCommandRoute.finishTextEditing() else { return }
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
                guard CanvasEditCommandRoute.finishTextEditing() else { return }
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
                    session.fit(in: surfaceSize, excluding: controlRects + mainControlRects)
                }
                .keyboardShortcut("9", modifiers: .command)

                Button("Reset View", systemImage: "scope") {
                    session.resetView()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            Menu("Edit") {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    _ = CanvasEditCommandRoute.undo(session: session, section: .canvas)
                }
                .disabled(!canUndoCanvasEdit)

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    _ = CanvasEditCommandRoute.redo(session: session, section: .canvas)
                }
                .disabled(!canRedoCanvasEdit)

                Divider()

                Button("Clear Canvas", systemImage: "trash", role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(canvasIsEmpty)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .accessibilityIdentifier("canvas-clear")
            }
        } label: {
            Image(systemName: "square.stack")
                .font(.system(size: compact ? 15 : 17, weight: .medium))
                .atticClearGlassForegroundReadability()
                .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
        .atticQuietMenuGlyph(Color.primary)
        .atticGlassControl(in: Circle())
        .help("Canvas actions")
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
                .foregroundStyle(pendingShape == nil ? Color.primary : selectedShapeForeground)
                .atticClearGlassForegroundReadability()
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(pendingShape == nil ? Color.primary.opacity(isShapeHovered ? 0.08 : 0) : pendingShapeFill)
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        // At rest the pop-up button painted the square accent blue, which is
        // exactly the signal a pending shape uses. Quiet the idle glyph so the
        // deliberate accent fill below means "waiting to be placed" again.
        .atticQuietMenuGlyph(pendingShape == nil ? Color.primary : selectedShapeForeground)
        .onHover { isShapeHovered = $0 }
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
                        presentExport(of: image)
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
                // A failed image keeps its warning colour; everything else is
                // quiet chrome rather than system accent.
                .atticQuietMenuGlyph(session.failedImageIDs.contains(image.id) ? .orange : secondaryForeground)
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
                .foregroundStyle(secondaryForeground)
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
                .atticQuietMenuGlyph(secondaryForeground)
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

private struct CanvasControlFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
