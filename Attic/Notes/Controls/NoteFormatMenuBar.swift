import AppKit

/// Insert and Format in the menu bar (for when Attic shows one: a note in
/// its own window, the Dock mode of phase 5). Built from the same router as
/// ⋯ and the right-click menu each time it opens, for the note that has the
/// keyboard. The menus list every shortcut but never answer keys
/// themselves: `NoteFormatControls` handles them, so a key never has two
/// routes and nothing is swallowed outside a note.
@MainActor
final class NoteFormatMenuBar: NSObject, NSMenuDelegate {
    static let insertIdentifier = NSUserInterfaceItemIdentifier("notes-menubar-insert")
    static let formatIdentifier = NSUserInterfaceItemIdentifier("notes-menubar-format")
    static let printIdentifier = NSUserInterfaceItemIdentifier("notes-menubar-print")
    private static let shared = NoteFormatMenuBar()

    /// Adds Insert and Format after Edit once (again if the app's menu was
    /// rebuilt without them).
    static func install(in menu: NSMenu? = nil) {
        guard let mainMenu = menu ?? NSApp?.mainMenu else { return }
        installPrint(in: mainMenu)
        guard mainMenu.items.first(where: { $0.identifier == formatIdentifier }) == nil else { return }
        let insertMenu = NSMenu(title: String(localized: "Insert"))
        let formatMenu = NSMenu(title: String(localized: "Format"))
        insertMenu.delegate = shared
        formatMenu.delegate = shared
        let insert = NSMenuItem(title: String(localized: "Insert"), action: nil, keyEquivalent: "")
        insert.identifier = insertIdentifier
        insert.submenu = insertMenu
        let format = NSMenuItem(title: String(localized: "Format"), action: nil, keyEquivalent: "")
        format.identifier = formatIdentifier
        format.submenu = formatMenu
        let edit = mainMenu.items.firstIndex { $0.submenu?.title == "Edit" || $0.title == "Edit" }
        let index = min((edit ?? max(0, mainMenu.items.count - 2)) + 1, mainMenu.items.count)
        mainMenu.insertItem(insert, at: index)
        mainMenu.insertItem(format, at: index + 1)
    }

    /// File › Print… (⌘P): sent to the note's text view, the only responder
    /// that answers `printNote(_:)`, so it is dimmed anywhere else and never
    /// prints another page's view. Added once, when the menu has a File menu.
    static func installPrint(in mainMenu: NSMenu) {
        guard let file = mainMenu.items.first(where: { $0.submenu?.title == "File" || $0.title == "File" })?.submenu,
              !file.items.contains(where: { $0.identifier == printIdentifier }) else { return }
        let item = NSMenuItem(title: String(localized: "Print…"),
                              action: #selector(NoteEditorTextView.printNote(_:)), keyEquivalent: "p")
        item.keyEquivalentModifierMask = .command
        item.identifier = printIdentifier
        if let index = file.items.firstIndex(where: { $0.action == #selector(NSView.printView(_:)) }) {
            // The system's own Print… would print the view that has the
            // keyboard: the note's takes its place.
            file.removeItem(at: index)
            file.insertItem(item, at: index)
        } else {
            file.addItem(.separator())
            file.addItem(item)
        }
    }

    /// The rows for `controls` (dimmed when no note has the keyboard).
    static func items(for menu: NSMenu, controls: NoteFormatControls?) -> [NSMenuItem] {
        let isInsert = menu.title == String(localized: "Insert")
        guard let router = controls?.router else {
            let placeholder = isInsert ? NoteInsertAction.allCases.map(\.title)
                : NoteCommandCatalog.allCommands.map(NoteCommandCatalog.menuTitle)
            return placeholder.map { title in
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
        }
        let commands = isInsert ? router.insertMenuCommands(from: .menuBar) : router.formatMenuCommands(from: .menuBar)
        let built = AtticNativeMenu.make(commands)
        let items = built.items
        built.removeAllItems()
        return items
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let controls = NoteFormatControls.active.flatMap { $0.hasKeyboard ? $0 : nil }
        menu.items = Self.items(for: menu, controls: controls)
    }

    /// Keys are the note's own (`NoteFormatControls.handleKey`).
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }
}
