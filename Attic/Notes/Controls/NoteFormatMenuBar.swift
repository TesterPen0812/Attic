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
    private static let shared = NoteFormatMenuBar()

    /// Adds Insert and Format after Edit once (again if the app's menu was
    /// rebuilt without them).
    static func install(in menu: NSMenu? = nil) {
        guard let mainMenu = menu ?? NSApp?.mainMenu, mainMenu.items.first(where: { $0.identifier == formatIdentifier }) == nil else { return }
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
