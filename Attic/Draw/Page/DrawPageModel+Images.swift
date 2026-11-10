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

    /// The file names, for tests that hold one import back.
    var names: [String] {
        if case .file(let url) = self { [url.lastPathComponent] } else { [] }
    }

    nonisolated func load() -> DrawImageImport? {
        switch self {
        case .data(let data): DrawImageImport.inspect(data)
        case .file(let url): (try? Data(contentsOf: url)).flatMap(DrawImageImport.inspect)
        }
    }
}

extension DrawPageModel {
    #if DEBUG
    /// Tests only: runs before an import's files are read, with their names.
    nonisolated(unsafe) static var importLoadHook: (@Sendable ([String]) async -> Void)?
    #endif

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

    /// The image type the writer put first: the pasteboard also offers
    /// conversions (a JPEG reads as TIFF too), and the store keeps the original.
    private static func originalImageType(on pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        let wanted = Set(imagePasteboardTypes)
        return pasteboard.types?.first(where: wanted.contains) ?? pasteboard.availableType(from: imagePasteboardTypes)
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
        } else if let type = Self.originalImageType(on: pasteboard), let data = pasteboard.data(forType: type) {
            sources = [.data(data)]
        }
        guard !sources.isEmpty else { return nil }
        let point = screen ?? CGPoint(x: clearRect.midX, y: clearRect.midY)
        // The view as it was at the drop: the images land there, on that
        // canvas, even if another one is open by the time they're read.
        let drop = DrawImageDrop(canvas: canvasID, centre: viewport.world(point),
                                 room: CGSize(width: clearRect.width * 0.8 / viewport.zoom, height: clearRect.height * 0.8 / viewport.zoom),
                                 step: 12 / viewport.zoom)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            #if DEBUG
            await Self.importLoadHook?(sources.flatMap(\.names))
            #endif
            let imports = await Task.detached(priority: .userInitiated) { sources.compactMap { $0.load() } }.value
            self?.place(imports, at: drop)
            self?.importFinished(token)
        }
        importStarted(token, task)
        return task
    }

    /// Natural size, scaled down to fit comfortably in the view, aspect
    /// kept, centred on the point; several cascade. One Undo step, on the
    /// canvas the images were dropped on.
    private func place(_ imports: [DrawImageImport], at drop: DrawImageDrop) {
        guard !imports.isEmpty else { return }
        let room = drop.room, step = drop.step, centre = drop.centre
        var z = drop.canvas == canvasID ? topZ : (try? store.open(drop.canvas).objects.map(\.zIndex).max()) ?? 0
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
        perform(.put(placed), on: drop.canvas)
        AtticSounds.play(.attached)
    }
}

/// Where an import lands: its canvas and that canvas's view at the drop.
private struct DrawImageDrop: Sendable {
    var canvas: UUID
    var centre: CGPoint
    var room: CGSize
    var step: CGFloat
}

/// How Save Image and Export… touch the disk (tests make a step fail).
struct DrawFileWriter: Sendable {
    /// Writes the new file's bytes.
    var write: @Sendable (_ data: Data, _ url: URL) throws -> Void = { try $0.write(to: $1) }
    /// Swaps the staged file in for the destination in one step, keeping
    /// the old file under the backup name next to it.
    var replace: @Sendable (_ destination: URL, _ staged: URL, _ backupName: String) throws -> Void = { destination, staged, backup in
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, backupItemName: backup,
                                                  options: [.withoutDeletingBackupItem])
    }
    /// Moves a file to the Trash (never deletes it).
    var trash: @Sendable (_ url: URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
}

/// Save Image, Copy as Image and Export…: files and pasteboards for the
/// page (the page model's `DrawImageSeam`).
@MainActor
final class DrawImageActions: DrawImageSeam {
    weak var model: DrawPageModel?
    /// Where a save goes: the save panel, or a test's folder.
    var chooseDestination: @MainActor (_ name: String, _ types: [UTType]) -> URL? = DrawImageActions.savePanel
    /// The disk steps of a save.
    var files = DrawFileWriter()
    #if DEBUG
    /// Tests only: the appearance exports and thumbnails render in.
    nonisolated(unsafe) static var darkOverride: Bool?
    #endif
    /// The latest file or pasteboard write, for tests to wait on.
    private(set) var lastTask: Task<Void, Never>?
    private var copyGeneration: UInt64 = 0
    var copyRenderer: @MainActor ([DrawObject], Bool) async -> Data? = { objects, dark in
        await Task.detached(priority: .userInitiated) { DrawExport.render(objects, format: .png, dark: dark) }.value
    }

    init(model: DrawPageModel?) { self.model = model }

    /// The board colour of the current appearance.
    static var isDark: Bool {
        #if DEBUG
        if let darkOverride { return darkOverride }
        #endif
        return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The canvas's name as the store has it now (a rename from the menu
    /// reaches the page a moment later).
    private func name(of id: UUID?) -> String {
        guard let model else { return DrawLibraryMenuModel.displayName("") }
        let stored = id.flatMap { try? model.store.open($0).canvas.name }
        // A file name can't hold a slash or a colon.
        return DrawLibraryMenuModel.displayName(stored ?? model.canvasName)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private var canvasName: String { name(of: model?.canvasID) }

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
        let bytes = image.original, files = files
        lastTask = Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { Self.write(bytes, to: url, files: files) }.value
            if let failure { self?.model?.report(failure) }
        }
    }

    /// The selection's ⋯ → Copy as Image: a PNG at 2× on the board colour.
    /// One image is the image itself: one pasteboard item with its original
    /// bytes in their own type, plus a PNG of it when it isn't one (for apps
    /// that only read PNG), and no board behind it.
    func copyAsImage(_ objects: [DrawObject]) {
        guard !objects.isEmpty else { return }
        AtticSounds.play(.copied)
        if objects.count == 1, case .image(let image) = objects[0].content {
            return copyOriginal(image)
        }
        copy(objects)
    }

    private func copyOriginal(_ image: DrawImage) {
        copyGeneration &+= 1
        let generation = copyGeneration
        let original = image.original, type = NSPasteboard.PasteboardType(image.contentType)
        lastTask = Task { @MainActor [weak self] in
            let png = type == .png ? nil : await Task.detached(priority: .userInitiated) { Self.png(of: original) }.value
            guard let self, self.copyGeneration == generation, let pasteboard = self.model?.pasteboard else { return }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(original, forType: type)
            if let png { item.setData(png, forType: .png) }
            pasteboard.writeObjects([item])
        }
    }

    /// A PNG of the image's own pixels (orientation and colour kept).
    nonisolated private static func png(of data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: Canvas menu

    /// Export…: PNG or PDF, named after the canvas.
    func exportCanvas(_ id: UUID) {
        let content = objects(of: id)
        guard !content.isEmpty, let url = chooseDestination(name(of: id), [.png, .pdf]) else { return }
        let format: DrawExportFormat = url.pathExtension.lowercased() == "pdf" ? .pdf : .png
        let dark = Self.isDark, files = files
        lastTask = Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = DrawExport.render(content, format: format, dark: dark) else {
                    return Self.failure(url, String(localized: "The canvas couldn’t be drawn."))
                }
                return Self.write(data, to: url, files: files)
            }.value
            if let failure { self?.model?.report(failure) }
        }
    }

    /// Copy as Image: the whole canvas.
    func copyCanvas(_ id: UUID) {
        let content = objects(of: id)
        guard !content.isEmpty else { return }
        copy(content)
    }

    private func copy(_ objects: [DrawObject]) {
        copyGeneration &+= 1
        let generation = copyGeneration
        let dark = Self.isDark
        lastTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let png = await self.copyRenderer(objects, dark)
            guard self.copyGeneration == generation, let png, let pasteboard = self.model?.pasteboard else { return }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
    }

    // MARK: Files

    /// The new file is written in full to a staging folder on the same
    /// volume, then swapped in for the destination in one step. Until then
    /// the file already there is untouched; once the new one is in place
    /// the old one goes to the Trash (never deleted). Nil, or what went
    /// wrong for the notice.
    nonisolated private static func write(_ data: Data, to url: URL, files: DrawFileWriter) -> String? {
        let manager = FileManager.default
        let staging: URL
        do {
            staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        } catch { return failure(url, error.localizedDescription) }
        // The staging folder goes only once it is empty: the old file is
        // never removed with it.
        defer {
            if (try? manager.contentsOfDirectory(atPath: staging.path))?.isEmpty == true { try? manager.removeItem(at: staging) }
        }
        let staged = staging.appendingPathComponent(url.lastPathComponent)
        do {
            try files.write(data, staged)
        } catch {
            try? manager.removeItem(at: staged) // our own partial file, never the user's
            return failure(url, error.localizedDescription)
        }
        guard manager.fileExists(atPath: url.path) else {
            do { try manager.moveItem(at: staged, to: url) } catch {
                try? manager.removeItem(at: staged)
                return failure(url, error.localizedDescription)
            }
            return nil
        }
        let backupName = ".\(UUID().uuidString)-\(url.lastPathComponent)"
        do {
            try files.replace(url, staged, backupName)
        } catch {
            try? manager.removeItem(at: staged)
            return failure(url, error.localizedDescription)
        }
        // The old file, under its own name, to the Trash. If that fails it
        // stays next to the new one (hidden), never deleted.
        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
        guard manager.fileExists(atPath: backup.path) else { return nil }
        let named = staging.appendingPathComponent(url.lastPathComponent)
        if (try? manager.moveItem(at: backup, to: named)) != nil {
            if (try? files.trash(named)) == nil { try? manager.moveItem(at: named, to: backup) }
        } else {
            try? files.trash(backup)
        }
        return nil
    }

    nonisolated private static func failure(_ url: URL, _ reason: String) -> String {
        String(localized: "“\(url.lastPathComponent)” couldn’t be saved: \(reason)")
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
