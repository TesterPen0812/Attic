import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An image's or a file's commands (UX plan § 3.5), ONE list for its
/// right-click menu, the note's ⋯ and ⇧⌘I while it is selected, and the
/// failure actions drawn on it. Every row is `NoteObjectCommand` validated
/// by the engine; the menu only presents it.
@MainActor
enum NoteObjectMenu {
    static let identifierPrefix = "notes-object-"

    /// The commands for the object, in the plan's order.
    /// Ready image: Quick Look, Open With ▸, Copy Image, Export Copy…, Show in
    /// Finder, Size ▸, Delete Image. Ready file: the same with Copy File and
    /// Open in Size's place. A failure lists its own actions (§ 3.5).
    static func commands(for objectID: UUID, engine: NoteEditorEngine,
                         run: @escaping (NoteObjectCommand) -> Void,
                         chooseApplication: @escaping () -> Void) -> [AtticMenuCommand] {
        guard let (object, _) = engine.objectPlacement(objectID),
              object is NoteImageAttachment || object is NoteFileAttachment else { return [] }
        let state = engine.objectState(for: object)
        let isImage = object is NoteImageAttachment
        func command(_ title: String, _ value: NoteObjectCommand, id: String, shortcut: KeyboardShortcut? = nil,
                     destructive: Bool = false, section: Bool = false) -> AtticMenuCommand {
            var item = AtticMenuCommand(verbatim: title, shortcut: shortcut, isDestructive: destructive,
                                        isDisabled: !engine.validate(value, objectID: objectID).enabled,
                                        startsSection: section) { run(value) }
            item.identifier = identifierPrefix + id
            return item
        }
        let quickLook = command(String(localized: "Quick Look"), .quickLook, id: "quicklook",
                                shortcut: KeyboardShortcut(.space, modifiers: []))
        let export = command(String(localized: "Export Copy…"), .exportCopy(nil), id: "export")
        let remove = command(String(localized: "Remove"), .delete, id: "remove", destructive: true, section: true)
        switch state {
        case let .importFailed(reason):
            return [.header(reason),
                    command(String(localized: "Retry"), .retry, id: "retry", section: true),
                    remove]
        case .previewUnavailable:
            return [quickLook, export,
                    command(String(localized: "Retry Preview"), .retryPreview, id: "retry-preview"),
                    remove]
        case .originalMissing:
            return [command(String(localized: "Locate…"), .locate, id: "locate"), remove]
        case .ready:
            var list = [quickLook,
                        openWith(object, objectID: objectID, engine: engine, run: run, chooseApplication: chooseApplication)]
            if isImage {
                list.append(command(String(localized: "Copy Image"), .copyImage, id: "copy",
                                    shortcut: KeyboardShortcut("c", modifiers: .command), section: true))
            } else {
                list.append(command(String(localized: "Copy File"), .copyFile, id: "copy",
                                    shortcut: KeyboardShortcut("c", modifiers: .command), section: true))
            }
            list.append(export)
            list.append(command(String(localized: "Show in Finder"), .showInFinder, id: "finder"))
            if let image = object as? NoteImageAttachment {
                list.append(size(image, objectID: objectID, engine: engine, run: run))
            } else {
                list.append(command(String(localized: "Open"), .open, id: "open"))
            }
            list.append(command(isImage ? String(localized: "Delete Image") : String(localized: "Delete File"), .delete,
                                id: "delete", shortcut: KeyboardShortcut(.delete, modifiers: []),
                                destructive: true, section: true))
            return list
        }
    }

    /// The selected object's commands as one submenu for the note's ⋯
    /// ("Image ▸" or "File ▸"), so the keyboard reaches them with ⇧⌘I.
    static func selectedObjectSubmenu(engine: NoteEditorEngine, run: @escaping (UUID, NoteObjectCommand) -> Void,
                                      chooseApplication: @escaping (UUID) -> Void) -> AtticMenuCommand? {
        guard let (object, _) = selectedObject(in: engine) else { return nil }
        let id = object.objectID
        let children = commands(for: id, engine: engine, run: { run(id, $0) }, chooseApplication: { chooseApplication(id) })
        guard !children.isEmpty else { return nil }
        var submenu = AtticMenuCommand.submenu(object is NoteImageAttachment ? String(localized: "Image")
                                               : String(localized: "File"), children)
        submenu.identifier = identifierPrefix + "submenu"
        return submenu
    }

    /// An image or a file selected on its own (the caret's selection is
    /// exactly the object).
    static func selectedObject(in engine: NoteEditorEngine) -> (NoteObjectAttachment, NSRange)? {
        guard let selection = engine.textView?.selectedRange(), selection.length == 1,
              let object = engine.object(at: selection.location),
              object is NoteImageAttachment || object is NoteFileAttachment else { return nil }
        return (object, selection)
    }

    /// The type the object's bytes open as.
    static func contentType(of object: NoteObjectAttachment) -> UTType {
        if let file = object as? NoteFileAttachment { return UTType(file.contentTypeIdentifier) ?? .data }
        if let image = object as? NoteImageAttachment {
            return UTType(filenameExtension: (image.filename as NSString).pathExtension) ?? .image
        }
        return .data
    }

    /// Open With ▸: the default application first, then the others that
    /// open the type, then Other….
    private static func openWith(_ object: NoteObjectAttachment, objectID: UUID, engine: NoteEditorEngine,
                                 run: @escaping (NoteObjectCommand) -> Void,
                                 chooseApplication: @escaping () -> Void) -> AtticMenuCommand {
        let type = contentType(of: object)
        let enabled = engine.validate(.open, objectID: objectID).enabled
        var children: [AtticMenuCommand] = []
        if enabled {
            let workspace = NSWorkspace.shared
            let preferred = workspace.urlForApplication(toOpen: type)
            var others = workspace.urlsForApplications(toOpen: type).filter { $0 != preferred }
            others.sort { applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending }
            let apps = (preferred.map { [$0] } ?? []) + others.prefix(12)
            for (index, url) in apps.enumerated() {
                children.append(AtticMenuCommand(verbatim: applicationName(url),
                                                 startsSection: index == 1,
                                                 detail: index == 0 && preferred != nil ? String(localized: "Default") : nil) {
                    run(.openWith(url))
                })
            }
            children.append(AtticMenuCommand(verbatim: String(localized: "Other…"), startsSection: true, action: chooseApplication))
        }
        var submenu = AtticMenuCommand.submenu(String(localized: "Open With"), isDisabled: !enabled, children)
        submenu.identifier = identifierPrefix + "open-with"
        return submenu
    }

    /// Size ▸ Small, Medium, Full; the current one ticked.
    private static func size(_ image: NoteImageAttachment, objectID: UUID, engine: NoteEditorEngine,
                             run: @escaping (NoteObjectCommand) -> Void) -> AtticMenuCommand {
        let current = image.preferredWidthFraction
        let children = NoteImageSizePreset.allCases.map { preset in
            var item = AtticMenuCommand(verbatim: title(preset),
                                        isDisabled: !engine.validate(.sizePreset(preset), objectID: objectID).enabled,
                                        state: current.map { abs($0 - preset.fraction) < 0.005 } == true ? .on : .off) {
                run(.sizePreset(preset))
            }
            item.identifier = identifierPrefix + "size-" + preset.rawValue
            return item
        }
        var submenu = AtticMenuCommand.submenu(String(localized: "Size"),
                                               isDisabled: !engine.validate(.sizePreset(.full), objectID: objectID).enabled,
                                               children)
        submenu.identifier = identifierPrefix + "size"
        return submenu
    }

    static func title(_ preset: NoteImageSizePreset) -> String {
        switch preset {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .full: String(localized: "Full")
        }
    }

    private static func applicationName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
