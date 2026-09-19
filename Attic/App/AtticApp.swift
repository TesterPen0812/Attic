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
                uiState: coordinator.uiState,
                focus: coordinator.canvasEditFocus
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
    @ObservedObject var focus: CanvasEditCommandFocusMonitor

    /// Enablement comes from `CanvasEditCommandAvailability`, which reads the
    /// same route the canvas toolbar's Undo/Redo buttons read, so the menu
    /// never offers an operation the toolbar shows as unavailable. It is
    /// sampled only when this body runs, so every boundary that can change the
    /// answer has to publish. Canvas history, undo, redo and the selected
    /// section publish themselves; the editing-availability token covers a
    /// focused canvas text editor, exactly as the toolbar does; and the focus
    /// monitor covers a text view outside the canvas taking or giving up focus,
    /// which moves nothing else the app observes.
    /// `CanvasEditCommandAvailability` documents the one case that stays
    /// enabled regardless — a disabled shortcut item swallows ⌘Z — and the
    /// route decides what each press acts on, at the moment it is pressed.
    private var canUndo: Bool {
        let _ = session.editingAvailabilityToken
        let _ = focus.foreignTextViewOwnsAvailability
        return CanvasEditCommandAvailability.undoIsEnabled(
            session: session,
            section: uiState.selectedSection
        )
    }

    private var canRedo: Bool {
        let _ = session.editingAvailabilityToken
        let _ = focus.foreignTextViewOwnsAvailability
        return CanvasEditCommandAvailability.redoIsEnabled(
            session: session,
            section: uiState.selectedSection
        )
    }

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
                .disabled(!canUndo)

                Button("Redo Canvas Change") {
                    _ = CanvasEditCommandRoute.redo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedo)
            }
        }
    }
}
