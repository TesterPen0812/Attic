import SwiftUI

@main
struct PeekabooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra(menuBarTitle, systemImage: menuBarSystemImage) {
            MenuBarView(store: coordinator.store, coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    coordinator.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var menuBarTitle: String {
        #if PEEKABOO_LOCAL_ONLY
        "Peekaboo Notes Local"
        #else
        "Peekaboo"
        #endif
    }

    private var menuBarSystemImage: String {
        #if PEEKABOO_LOCAL_ONLY
        "note.text"
        #else
        "eye"
        #endif
    }
}
