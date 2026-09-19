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

/// Whether the app's Edit menu shadows the standard Undo/Redo, and why those
/// items carry no disabled state.
///
/// The items claim ⌘Z and ⇧⌘Z, and AppKit stops at the first item matching a
/// shortcut: a *disabled* one consumes the event and neither it nor the
/// standard item behind it runs
/// (`testADisabledShortcutItemSwallowsItsKeyEquivalent`). Their availability
/// used to come from `CanvasEditCommandRoute.canUndo`, which reads the focused
/// responder's undo manager — state no publisher owns. The canvas republishes
/// its own editor through `editingAvailabilityToken`, but a *foreign* text view
/// (a pinned family panel's title field, a Settings field) changes nothing
/// SwiftUI observes here, so a cached disabled item survived while that field
/// filled up with undoable typing, and ⌘Z in it did nothing at all.
///
/// Enablement is not what decides which undo runs: the route re-reads the
/// first responder at invocation and forwards to the focused text view's own
/// undo manager, falling back to canvas history only when none is focused. So
/// dropping the disabled state changes no outcome where something could be
/// undone, and replaces a swallowed shortcut with a no-op where nothing could
/// — the same thing the standard disabled Undo does. Nothing is polled and no
/// responder is observed, because availability no longer depends on either.
///
/// The canvas toolbar's own Undo/Redo buttons keep their disabled state: they
/// hold no key equivalent, so a stale one cannot swallow anything, and while
/// the canvas is focused they read canvas history correctly.
enum CanvasEditCommandAvailability {
    /// Whether the shadowing items exist at all. Outside the Canvas section
    /// the standard Edit ▸ Undo/Redo is left alone.
    static func offersShadowingItems(section: PanelSection) -> Bool {
        section.isCanvas
    }

    /// Whether an offered item may be presented disabled. Always false: see
    /// the type's documentation.
    static let shadowingItemsMayBeDisabled = false
}
