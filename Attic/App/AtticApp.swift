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
        #if ATTIC_GLASSMORPHISM_PREVIEW
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

@MainActor
enum CanvasEditCommandRoute {
    static func canUndo(session: CanvasSession, section: PanelSection) -> Bool {
        section.isCanvas && session.canUndo
    }

    static func canRedo(session: CanvasSession, section: PanelSection) -> Bool {
        section.isCanvas && session.canRedo
    }

    @discardableResult
    static func undo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        return session.undo()
    }

    @discardableResult
    static func redo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        return session.redo()
    }
}

private struct CanvasEditCommands: Commands {
    @ObservedObject var session: CanvasSession
    @ObservedObject var uiState: PanelUIState

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
                .disabled(!CanvasEditCommandRoute.canUndo(
                    session: session,
                    section: uiState.selectedSection
                ))

                Button("Redo Canvas Change") {
                    _ = CanvasEditCommandRoute.redo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!CanvasEditCommandRoute.canRedo(
                    session: session,
                    section: uiState.selectedSection
                ))
            }
        }
    }
}
