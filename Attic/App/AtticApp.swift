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
    /// equivalent while the Canvas section is selected, and AppKit stops at
    /// the first item matching a shortcut: a *disabled* one consumes ⌘Z and
    /// neither it nor the standard item behind it runs
    /// (`testADisabledShortcutItemSwallowsItsKeyEquivalent`). Availability is
    /// route-only, and the route reads the focused text editor's undo manager
    /// — state that canvas history never republishes. So the availability has
    /// to be read through the editing token, exactly as the canvas toolbar
    /// does: without it, typing on a board whose session history is empty left
    /// these cached as disabled and ⌘Z did nothing at all.
    private var canUndoCanvasEdit: Bool {
        let _ = session.editingAvailabilityToken
        return CanvasEditCommandRoute.canUndo(session: session, section: uiState.selectedSection)
    }

    private var canRedoCanvasEdit: Bool {
        let _ = session.editingAvailabilityToken
        return CanvasEditCommandRoute.canRedo(session: session, section: uiState.selectedSection)
    }

    var body: some Commands {
        CommandGroup(before: .undoRedo) {
            if uiState.selectedSection.isCanvas {
                Button("Undo Canvas Change") {
                    _ = CanvasEditCommandRoute.undo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canUndoCanvasEdit)

                Button("Redo Canvas Change") {
                    _ = CanvasEditCommandRoute.redo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedoCanvasEdit)
            }
        }
    }
}
