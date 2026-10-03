import Foundation

enum CanvasCoreError: Error, Equatable {
    case invalidGeometry, invalidPayload, unsupportedVersion, admission, overflow, conflict
}

struct CanvasCoreID: Hashable, Codable, Sendable {
    let canvasID: UUID
    let objectID: UUID
}

enum CanvasCoreKind: String, Codable, CaseIterable, Sendable { case stroke, text, shape, image }

struct CanvasCoreBounds: Codable, Equatable, Sendable {
    var minX: Double; var minY: Double; var maxX: Double; var maxY: Double
    var valid: Bool {
        [minX, minY, maxX, maxY].allSatisfy { $0.isFinite && abs($0) <= 1e15 }
            && minX <= maxX && minY <= maxY
    }
    var area: Double { (maxX - minX) * (maxY - minY) }
    func intersects(_ b: Self) -> Bool {
        minX <= b.maxX && maxX >= b.minX && minY <= b.maxY && maxY >= b.minY
    }
    func union(_ b: Self) -> Self {
        .init(minX: min(minX, b.minX), minY: min(minY, b.minY), maxX: max(maxX, b.maxX), maxY: max(maxY, b.maxY))
    }
    func inflated(_ amount: Double) -> Self {
        .init(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }
}

struct CanvasCoreMetadata: Equatable, Sendable {
    let id: CanvasCoreID
    let kind: CanvasCoreKind
    var bounds: CanvasCoreBounds
    var rank: Int64
}

struct CanvasCoreSelection: Equatable {
    private(set) var ids: Set<CanvasCoreID> = []
    mutating func click(_ id: CanvasCoreID?, extending: Bool) {
        if extending, let id { if !ids.insert(id).inserted { ids.remove(id) } }
        else { ids = id.map { [$0] } ?? [] }
    }
    mutating func selectAll(_ metadata: [CanvasCoreMetadata]) { ids = Set(metadata.map(\.id)) }
    mutating func marquee(_ candidates: [CanvasCoreMetadata], extending: Bool,
                          exactIntersection: (CanvasCoreMetadata) -> Bool) {
        let hits = Set(candidates.filter(exactIntersection).map(\.id))
        ids = extending ? ids.union(hits) : hits
    }
    mutating func retain(_ live: Set<CanvasCoreID>) { ids.formIntersection(live) }
}

/// No UI route carries a separate enablement policy. Unimplemented commands
/// remain data and refuse execution until their slice installs an action.
enum CanvasCoreCommand: String, CaseIterable {
    case select, pen, eraser, text, shape, undo, redo, selectAll, delete, duplicate
    case cut, copy, paste, fit, zoomIn, zoomOut, bringFront, bringForward, sendBackward, sendBack
    case style, insertAtCentre, nudge, resize, newCanvas, rename, tags, deleteCanvas
    case exportPNG, copyAsImage, insertImage, saveImage, restoreImage, titleMenu
}
enum CanvasCoreRoute: CaseIterable { case toolbar, selectionBar, menu, shortcut, accessibility, external }
struct CanvasCoreCommandContext {
    var readOnly = false
    var nativeTyping = false
    var markedText = false
    var unresolvedSave = false
    var selectionKinds: Set<CanvasCoreKind> = []
    var selectionCount = 0
    var canUndo = false
    var canRedo = false
    var undoBarrier: String?
    var atFront = false
    var atBack = false
    var installed: Set<CanvasCoreCommand> = []
}
struct CanvasCoreCommandDecision: Equatable {
    let reason: String?
    let consumeShortcut: Bool
    var enabled: Bool { reason == nil }
}
enum CanvasCoreCommandCatalog {
    struct Entry {
        let id: CanvasCoreCommand
        let mutates: Bool
        let needsSelection: Bool
        let suspendedWhileTyping: Bool
    }
    static let entries: [Entry] = CanvasCoreCommand.allCases.map { id in
        Entry(id: id,
              mutates: ![.select, .pen, .eraser, .text, .shape, .selectAll, .copy, .fit, .zoomIn, .zoomOut, .exportPNG, .copyAsImage, .saveImage, .titleMenu].contains(id),
              needsSelection: [.delete, .duplicate, .cut, .copy, .style, .bringFront, .bringForward, .sendBackward, .sendBack, .resize].contains(id),
              suspendedWhileTyping: [.select, .pen, .eraser, .text, .shape, .fit, .zoomIn, .zoomOut, .insertAtCentre, .nudge, .resize, .selectAll, .delete].contains(id))
    }
    static func validate(_ id: CanvasCoreCommand, context c: CanvasCoreCommandContext,
                         route: CanvasCoreRoute) -> CanvasCoreCommandDecision {
        let entry = entries.first { $0.id == id }!
        let reason: String?
        if c.markedText { reason = "Finish text composition first" }
        else if c.nativeTyping && (entry.suspendedWhileTyping || [.undo, .redo, .cut, .copy, .paste].contains(id)) { reason = "Text editor owns this command" }
        else if c.unresolvedSave && entry.mutates { reason = "Resolve the unsaved edit first" }
        else if c.readOnly && (entry.mutates || [.pen, .eraser, .text, .shape, .insertImage].contains(id)) { reason = "This canvas is read-only" }
        else if entry.needsSelection && c.selectionCount == 0 { reason = "Select an object first" }
        else if id == .undo && !c.canUndo { reason = c.undoBarrier ?? "Nothing to undo" }
        else if id == .redo && !c.canRedo { reason = "Nothing to redo" }
        else if [.bringFront, .bringForward].contains(id) && c.atFront { reason = "Already at the front" }
        else if [.sendBack, .sendBackward].contains(id) && c.atBack { reason = "Already at the back" }
        else if id == .saveImage && (c.selectionCount != 1 || c.selectionKinds != [.image]) { reason = "Select one image" }
        else if id == .resize && (c.selectionCount != 1 || c.selectionKinds.contains(.stroke)) { reason = "Select one resizable object" }
        else if !c.installed.contains(id) { reason = "This command is not available yet" }
        else { reason = nil }
        return .init(reason: reason, consumeShortcut: route == .shortcut && !(c.nativeTyping || c.markedText))
    }
}
