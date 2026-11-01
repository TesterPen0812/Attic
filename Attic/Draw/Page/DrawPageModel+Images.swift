import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image on its way to the board: its exact bytes and what ImageIO says
/// about them, read from the file's header (nothing is decoded).
struct DrawImageImport: Sendable {
    var image: DrawImage
    /// Its natural size in points: pixels at the file's resolution.
    var naturalSize: CGSize

    nonisolated static func inspect(_ data: Data) -> DrawImageImport? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        func dpi(_ key: CFString) -> Double {
            let value = (properties[key] as? NSNumber)?.doubleValue ?? 72
            return value > 0 ? value : 72
        }
        var natural = CGSize(width: Double(width) * 72 / dpi(kCGImagePropertyDPIWidth),
                             height: Double(height) * 72 / dpi(kCGImagePropertyDPIHeight))
        // EXIF orientations 5–8 turn the picture on its side.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            natural = CGSize(width: natural.height, height: natural.width)
        }
        return DrawImageImport(image: DrawImage(original: data, pixelWidth: width, pixelHeight: height, contentType: type),
                               naturalSize: natural)
    }
}

/// Where an import's bytes come from.
private enum DrawImageSource: Sendable {
    case data(Data)
    case file(URL)

    nonisolated func load() -> DrawImageImport? {
        switch self {
        case .data(let data): DrawImageImport.inspect(data)
        case .file(let url): (try? Data(contentsOf: url)).flatMap(DrawImageImport.inspect)
        }
    }
}

extension DrawPageModel {
    /// Image data the board takes from a drop or a paste.
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
    ]

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Image files or image data, and no Draw objects (those paste as objects).
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [NSPasteboard.PasteboardType(DrawStore.clipboardType)]) != nil { return false }
        return pasteboard.availableType(from: imagePasteboardTypes) != nil
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions)
    }

    /// The pasteboard holds an image (and no Draw objects).
    var pasteboardHasImage: Bool { Self.holdsImages(pasteboard) }

    /// Drops and ⌘V: reads and inspects the images away from the main
    /// thread, then places them, one Undo step. Nil when there is no image.
    @discardableResult
    func importImages(from pasteboard: NSPasteboard, at screen: CGPoint?) -> Task<Void, Never>? {
        guard let canvasID, Self.holdsImages(pasteboard) else { return nil }
        var sources: [DrawImageSource] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: Self.imageFileOptions) as? [URL], !urls.isEmpty {
            sources = urls.map(DrawImageSource.file)
        } else if let type = pasteboard.availableType(from: Self.imagePasteboardTypes), let data = pasteboard.data(forType: type) {
            sources = [.data(data)]
        }
        guard !sources.isEmpty else { return nil }
        let point = screen ?? CGPoint(x: clearRect.midX, y: clearRect.midY)
        let centre = viewport.world(point)
        let task = Task { @MainActor [weak self] in
            let imports = await Task.detached(priority: .userInitiated) { sources.compactMap { $0.load() } }.value
            self?.place(imports, around: centre, on: canvasID)
        }
        pendingImport = task
        return task
    }

    /// Natural size, scaled down to fit comfortably in the view, aspect
    /// kept, centred on the point; several cascade. One Undo step.
    private func place(_ imports: [DrawImageImport], around centre: CGPoint, on id: UUID) {
        guard !imports.isEmpty, canvasID == id else { return }
        let room = CGSize(width: clearRect.width * 0.8 / viewport.zoom, height: clearRect.height * 0.8 / viewport.zoom)
        let step = 12 / viewport.zoom
        var z = topZ
        let placed = imports.enumerated().map { index, item -> DrawObject in
            let size = item.naturalSize
            let scale = min(1, room.width / max(size.width, 0.001), room.height / max(size.height, 0.001))
            let width = size.width * scale, height = size.height * scale
            let shift = CGFloat(index) * step
            z += 1
            return DrawObject(frame: DrawFrame(x: centre.x - width / 2 + shift, y: centre.y - height / 2 + shift,
                                               width: width, height: height),
                              zIndex: z, content: .image(item.image))
        }
        perform(.put(placed))
    }
}

/// Save Image, Copy as Image and Export…: files and pasteboards for the
/// page (the page model's `DrawImageSeam`).
@MainActor
final class DrawImageActions: DrawImageSeam {
    weak var model: DrawPageModel?
    /// Where a save goes: the save panel, or a test's folder.
    var chooseDestination: @MainActor (_ name: String, _ types: [UTType]) -> URL? = DrawImageActions.savePanel
    #if DEBUG
    /// Tests only: the appearance exports and thumbnails render in.
    nonisolated(unsafe) static var darkOverride: Bool?
    #endif
    /// The latest file or pasteboard write, for tests to wait on.
    private(set) var lastTask: Task<Void, Never>?

    init(model: DrawPageModel?) { self.model = model }

    /// The board colour of the current appearance.
    static var isDark: Bool {
        #if DEBUG
        if let darkOverride { return darkOverride }
        #endif
        return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var canvasName: String {
        DrawLibraryMenuModel.displayName(model?.canvasName ?? "")
    }

    private func name(of id: UUID) -> String {
        guard let model else { return canvasName }
        if id == model.canvasID { return canvasName }
        return DrawLibraryMenuModel.displayName((try? model.store.open(id).canvas.name) ?? "")
    }

    private func objects(of id: UUID) -> [DrawObject] {
        guard let model else { return [] }
        if id == model.canvasID { return model.objects }
        return ((try? model.store.open(id).objects) ?? []).filter { $0.deletedAt == nil }
    }

    // MARK: Selection

    /// Save Image: the exact original bytes, in the original type.
    func saveImage(_ object: DrawObject) {
        guard case .image(let image) = object.content else { return }
        let type = UTType(image.contentType) ?? .png
        let name = canvasName + "." + (type.preferredFilenameExtension ?? "png")
        guard let url = chooseDestination(name, [type]) else { return }
        let bytes = image.original
        lastTask = Task.detached(priority: .userInitiated) { Self.write(bytes, to: url) }
    }

    /// The selection's ⋯ → Copy as Image: a PNG at 2× on the board colour;
    /// one image also puts its original data on the pasteboard.
    func copyAsImage(_ objects: [DrawObject]) {
        guard !objects.isEmpty else { return }
        var original: (Data, NSPasteboard.PasteboardType)?
        if objects.count == 1, case .image(let image) = objects[0].content {
            original = (image.original, NSPasteboard.PasteboardType(image.contentType))
        }
        copy(objects, original: original)
    }

    // MARK: Canvas menu

    /// Export…: PNG or PDF, named after the canvas.
    func exportCanvas(_ id: UUID) {
        let content = objects(of: id)
        guard !content.isEmpty, let url = chooseDestination(name(of: id), [.png, .pdf]) else { return }
        let format: DrawExportFormat = url.pathExtension.lowercased() == "pdf" ? .pdf : .png
        let dark = Self.isDark
        lastTask = Task.detached(priority: .userInitiated) {
            guard let data = DrawExport.render(content, format: format, dark: dark) else { return }
            Self.write(data, to: url)
        }
    }

    /// Copy as Image: the whole canvas.
    func copyCanvas(_ id: UUID) {
        let content = objects(of: id)
        guard !content.isEmpty else { return }
        copy(content, original: nil)
    }

    private func copy(_ objects: [DrawObject], original: (Data, NSPasteboard.PasteboardType)?) {
        let dark = Self.isDark
        lastTask = Task { @MainActor [weak self] in
            let png = await Task.detached(priority: .userInitiated) { DrawExport.render(objects, format: .png, dark: dark) }.value
            guard let png, let pasteboard = self?.model?.pasteboard else { return }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            if let original, original.1 != .png { pasteboard.setData(original.0, forType: original.1) }
        }
    }

    // MARK: Files

    /// A file already there goes to the Trash first (never deleted).
    nonisolated private static func write(_ data: Data, to url: URL) {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) { try? files.trashItem(at: url, resultingItemURL: nil) }
        try? data.write(to: url)
    }

    /// The standard save panel, with a format choice when there are several.
    static func savePanel(name: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = Array(types.prefix(1))
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.level = TaskAttachmentPickerSession.windowLevel
        var picker: DrawFormatPicker?
        if types.count > 1 {
            let made = DrawFormatPicker(panel: panel, types: types)
            panel.accessoryView = made.view
            picker = made
        }
        defer { _ = picker }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Export…'s format pop-up under the save panel.
@MainActor
private final class DrawFormatPicker: NSObject {
    let view: NSView
    private weak var panel: NSSavePanel?
    private let types: [UTType]

    init(panel: NSSavePanel, types: [UTType]) {
        self.panel = panel
        self.types = types
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: types.map { $0.preferredFilenameExtension?.uppercased() ?? $0.identifier })
        popUp.setAccessibilityLabel(String(localized: "Format"))
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popUp.target = self
        popUp.action = #selector(choose(_:))
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        guard types.indices.contains(sender.indexOfSelectedItem) else { return }
        panel?.allowedContentTypes = [types[sender.indexOfSelectedItem]]
    }
}
