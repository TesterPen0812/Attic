import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum CanvasEditCommandRoute {
    #if os(macOS)
    /// The responder that owns keyboard focus in the key window. Tests inject a
    /// specific window's responder because the unit-test host never becomes key.
    static var focusedResponder: @MainActor () -> NSResponder? = { NSApp.keyWindow?.firstResponder }
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
