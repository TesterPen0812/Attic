import Foundation

/// What the canvas menu and Search ask of the Draw page. The page owns
/// navigation (which canvas is open, the board, the capsule); the library
/// owns the store's library commands (rename, tags, duplicate, delete).
struct DrawLibraryActions {
    private let openCanvas: @MainActor (_ canvasID: UUID) -> Void
    private let makeCanvas: @MainActor (_ name: String?) -> Void
    private let revealObject: @MainActor (_ canvasID: UUID, _ objectID: UUID) -> Void
    private let closeMenu: @MainActor () -> Void
    /// Job 3: Export… and Copy as Image stay greyed while these are nil.
    let export: (@MainActor (_ canvasID: UUID) -> Void)?
    let copyAsImage: (@MainActor (_ canvasID: UUID) -> Void)?
    /// Whether a canvas has anything drawn (Export… and Copy as Image are
    /// greyed while it doesn't).
    let hasContent: @MainActor (_ canvasID: UUID) -> Bool
    /// These canvases' thumbnails are about to show (the menu, Search): the
    /// page re-renders any drawn for the other appearance.
    let thumbnailsShown: @MainActor (_ canvases: [DrawCanvas]) -> Void

    init(open: @escaping @MainActor (_ canvasID: UUID) -> Void,
         newCanvas: @escaping @MainActor (_ name: String?) -> Void,
         reveal: @escaping @MainActor (_ canvasID: UUID, _ objectID: UUID) -> Void,
         close: @escaping @MainActor () -> Void,
         export: (@MainActor (_ canvasID: UUID) -> Void)? = nil,
         copyAsImage: (@MainActor (_ canvasID: UUID) -> Void)? = nil,
         hasContent: @escaping @MainActor (_ canvasID: UUID) -> Bool = { _ in true },
         thumbnailsShown: @escaping @MainActor (_ canvases: [DrawCanvas]) -> Void = { _ in }) {
        openCanvas = open
        makeCanvas = newCanvas
        revealObject = reveal
        closeMenu = close
        self.export = export
        self.copyAsImage = copyAsImage
        self.hasContent = hasContent
        self.thumbnailsShown = thumbnailsShown
    }

    /// Shows this canvas on the board.
    @MainActor func open(_ canvasID: UUID) { openCanvas(canvasID) }
    /// Starts a new canvas (the store's draft), named when a name is given.
    @MainActor func newCanvas(name: String?) { makeCanvas(name) }
    /// Opens the canvas, scrolls the text box into view and selects it.
    @MainActor func reveal(_ canvasID: UUID, _ objectID: UUID) { revealObject(canvasID, objectID) }
    /// Closes the canvas menu (the capsule shows the name again).
    @MainActor func close() { closeMenu() }
}
