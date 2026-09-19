import SwiftUI

@main
struct AtticApp: App {
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
            CanvasEditCommands(
                session: coordinator.canvasSession,
                uiState: coordinator.uiState
            )
        }
    }

    private var menuBarTitle: String {
        #if ATTIC_DAILY
        "Attic Daily"
        #elseif ATTIC_GLASSMORPHISM_PREVIEW
        "Attic Glassmorphism"
        #elseif ATTIC_LOCAL_ONLY
        "Attic Notes Local"
        #else
        "Attic"
        #endif
    }

    private var menuBarSystemImage: String {
        #if ATTIC_GLASSMORPHISM_PREVIEW
        "circle.lefthalf.filled"
        #elseif ATTIC_LOCAL_ONLY
        "note.text"
        #else
        "eye"
        #endif
    }
}

private struct CanvasEditCommands: Commands {
    @ObservedObject var session: CanvasSession
    @ObservedObject var uiState: PanelUIState

    /// These items shadow the standard Edit ▸ Undo/Redo with the same key
    /// equivalent while the Canvas section is selected, and they carry no
    /// disabled state: a disabled shortcut item swallows ⌘Z, and availability
    /// read from the first responder cannot be kept fresh by anything SwiftUI
    /// observes here. `CanvasEditCommandAvailability` documents the whole rule;
    /// the route decides what each press acts on, at the moment it is pressed.
    var body: some Commands {
        CommandGroup(before: .undoRedo) {
            if CanvasEditCommandAvailability.offersShadowingItems(section: uiState.selectedSection) {
                Button("Undo Canvas Change") {
                    _ = CanvasEditCommandRoute.undo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo Canvas Change") {
                    _ = CanvasEditCommandRoute.redo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}
