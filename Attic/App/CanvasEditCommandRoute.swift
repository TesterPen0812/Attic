import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum CanvasEditCommandRoute {
    #if os(macOS)
    /// The responder that owns keyboard focus for canvas commands: a text view
    /// focused in the key window, otherwise a canvas text editor that still
    /// holds focus in its visible window. The canvas panel is non-activating,
    /// so it can stop being key while its editor stays open, and accessibility
    /// presses still reach its controls; with the key window alone, Undo and
    /// Redo then acted on canvas history and tool changes skipped the save
    /// veto. Tests inject a specific window's responder instead.
    static var focusedResponder: @MainActor () -> NSResponder? = {
        let keyResponder = NSApp.keyWindow?.firstResponder
        if keyResponder is NSTextView { return keyResponder }
        return CanvasSemanticTextEditor.focusedInVisibleWindow ?? keyResponder
    }
    #endif

    /// Toolbar/menu tool changes must honor the same failed-save veto as a
    /// native responder change, including an unsaved insertion point.
    static func finishTextEditing() -> Bool {
        #if os(macOS)
        if let editor = focusedResponder() as? CanvasSemanticTextEditor {
            let canvas = editor.superview
            let window = editor.window
            guard editor.onCommit?() != false else { return false }
            window?.makeFirstResponder(canvas)
        }
        #endif
        return true
    }

    /// Whether the answer `canUndo`/`canRedo` gives right now is owned by a
    /// text view this app cannot republish: a focused `NSTextView` that is not
    /// the canvas editor — a pinned family panel's title field, a Settings
    /// field. Its undo manager fills up while nothing SwiftUI observes here
    /// moves, so a *disabled* state derived from it could never be corrected.
    /// The canvas editor is deliberately excluded: focus, typing and its own
    /// undo all republish through `CanvasSession.editingAvailabilityToken`.
    static var availabilityIsUnobserved: Bool {
        #if os(macOS)
        guard let responder = focusedResponder() as? NSTextView else { return false }
        return !(responder is CanvasSemanticTextEditor)
        #else
        return false
        #endif
    }

    static func canUndo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView { return editor.undoManager?.canUndo ?? false }
        #endif
        return session.canUndo
    }

    static func canRedo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView { return editor.undoManager?.canRedo ?? false }
        #endif
        return session.canRedo
    }

    @discardableResult
    static func undo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView {
            guard editor.undoManager?.canUndo == true else { return false }
            editor.undoManager?.undo()
            return true
        }
        #endif
        return session.undo()
    }

    @discardableResult
    static func redo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView {
            guard editor.undoManager?.canRedo == true else { return false }
            editor.undoManager?.redo()
            return true
        }
        #endif
        return session.redo()
    }
}

/// Whether the app's Edit menu shadows the standard Undo/Redo, and when those
/// items are presented enabled.
///
/// Enablement reads `CanvasEditCommandRoute`, the same source the canvas
/// toolbar's Undo/Redo buttons read, so the menu never offers an operation the
/// toolbar shows as unavailable. Mutations, undo and redo republish it through
/// `CanvasSession.canUndo`/`canRedo`, a canvas text editor's focus, typing and
/// own undo republish it through `editingAvailabilityToken`, and leaving the
/// Canvas section republishes it through `PanelUIState.selectedSection`.
///
/// One case is exempt, and it is the reason enablement is not the bare route
/// answer. The items claim ⌘Z and ⇧⌘Z, and AppKit stops at the first item
/// matching a shortcut: a *disabled* one consumes the event and neither it nor
/// the standard item behind it runs
/// (`testADisabledShortcutItemSwallowsItsKeyEquivalent`). When the route's
/// answer comes from a *foreign* text view — a pinned family panel's title
/// field, a Settings field — nothing republishes it
/// (`CanvasEditCommandRoute.availabilityIsUnobserved`), so a disabled item
/// would survive that field filling up with undoable typing and ⌘Z in it would
/// do nothing at all. While such a view holds focus the items therefore stay
/// enabled, and the route — which re-reads the first responder when it runs —
/// forwards ⌘Z to that view's own undo manager.
///
/// Enablement is not what decides which undo runs. It only decides what the
/// menu claims, and an enabled item with nothing to undo is a no-op, the same
/// thing the standard disabled Undo does.
///
/// The canvas toolbar's own Undo/Redo buttons take the route answer directly:
/// they hold no key equivalent, so a stale one cannot swallow anything.
@MainActor
enum CanvasEditCommandAvailability {
    /// Whether the shadowing items exist at all. Outside the Canvas section
    /// the standard Edit ▸ Undo/Redo is left alone.
    static func offersShadowingItems(section: PanelSection) -> Bool {
        section.isCanvas
    }

    /// Whether the offered *Undo Canvas Change* item is presented enabled.
    static func undoIsEnabled(session: CanvasSession, section: PanelSection) -> Bool {
        isEnabled(CanvasEditCommandRoute.canUndo(session: session, section: section), section: section)
    }

    /// Whether the offered *Redo Canvas Change* item is presented enabled.
    static func redoIsEnabled(session: CanvasSession, section: PanelSection) -> Bool {
        isEnabled(CanvasEditCommandRoute.canRedo(session: session, section: section), section: section)
    }

    /// An offered item may only be presented disabled when the answer behind
    /// it is one this app republishes: see the type's documentation.
    private static func isEnabled(_ canPerform: Bool, section: PanelSection) -> Bool {
        guard offersShadowingItems(section: section) else { return false }
        return canPerform || CanvasEditCommandRoute.availabilityIsUnobserved
    }
}
