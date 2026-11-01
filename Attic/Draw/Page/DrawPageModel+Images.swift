import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image on its way to the board: its exact bytes and what ImageIO says
/// about them, read from the file's header (nothing is decoded).
struct DrawImageImport: Sendable {
    var image: DrawImage
    /// Its natural size in points: pixels at the file's resolution.
    var naturalSize: CGSize

    nonisolated static func inspect(_ data: Data) -> DrawImageImport? { nil }
}

extension DrawPageModel {
    /// The pasteboard holds an image (and no Draw objects).
    var pasteboardHasImage: Bool { false }

    /// Drops and ⌘V: reads and inspects the images away from the main
    /// thread, then places them, one Undo step. Nil when there is no image.
    @discardableResult
    func importImages(from pasteboard: NSPasteboard, at screen: CGPoint?) -> Task<Void, Never>? { nil }
}

/// Save Image, Copy as Image and Export…: files and pasteboards for the
/// page (the page model's `DrawImageSeam`).
@MainActor
final class DrawImageActions: DrawImageSeam {
    weak var model: DrawPageModel?
    /// Where a save goes: the save panel, or a test's folder.
    var chooseDestination: @MainActor (_ name: String, _ types: [UTType]) -> URL? = { _, _ in nil }
    #if DEBUG
    /// Tests only: the appearance exports and thumbnails render in.
    nonisolated(unsafe) static var darkOverride: Bool?
    #endif
    /// The latest file or pasteboard write, for tests to wait on.
    private(set) var lastTask: Task<Void, Never>?

    init(model: DrawPageModel?) { self.model = model }

    func saveImage(_ object: DrawObject) {}
    func copyAsImage(_ objects: [DrawObject]) {}
    func exportCanvas(_ id: UUID) {}
    func copyCanvas(_ id: UUID) {}
}
