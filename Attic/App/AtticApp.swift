import SwiftUI

@main
struct AtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let coordinator = AppCoordinator.shared
    /// A gallery launch shows no menu-bar item (and never opens the store:
    /// `AppRuntimeEnvironment.usesInMemoryStore`).
    private let showsMenuBarItem = AppRuntimeEnvironment().showsMenuBarItem

    var body: some Scene {
        MenuBarExtra(menuBarTitle, systemImage: menuBarSystemImage, isInserted: .constant(showsMenuBarItem)) {
            MenuBarView(coordinator: coordinator)
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
    /// Publishing is only half of it: what this body produces reaches the live
    /// menu items when `CanvasEditCommandMenuDelivery` hands it to AppKit, and
    /// not merely because the body ran.
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
            let offersShadowingItems = CanvasEditCommandAvailability
                .offersShadowingItems(section: uiState.selectedSection)
            let undoIsEnabled = canUndo
            let redoIsEnabled = canRedo

            // Re-running this body is not the same as the menu changing.
            // SwiftUI writes what it produces here onto the live menu items
            // only when AppKit asks the menu to update, which AppKit does when
            // the menu is about to be tracked and at no other time — so a ⌘Z
            // pressed without opening the menu meets whatever the last
            // tracking pass left, and a disabled item swallows it. The render
            // is therefore delivered rather than waited on.
            let _ = CanvasEditCommandMenuDelivery.scheduleDelivery(
                CanvasEditCommandMenuDelivery.Render(
                    offersShadowingItems: offersShadowingItems,
                    undoIsEnabled: undoIsEnabled,
                    redoIsEnabled: redoIsEnabled
                )
            )

            if offersShadowingItems {
                Button("Undo Canvas Change") {
                    _ = CanvasEditCommandRoute.undo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!undoIsEnabled)

                Button("Redo Canvas Change") {
                    _ = CanvasEditCommandRoute.redo(
                        session: session,
                        section: uiState.selectedSection
                    )
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!redoIsEnabled)
            }
        }
    }
}
