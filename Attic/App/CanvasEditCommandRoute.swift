import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum CanvasEditCommandRoute {
    static func canUndo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canUndo ?? false }
        #endif
        return session.canUndo
    }

    static func canRedo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canRedo ?? false }
        #endif
        return session.canRedo
    }

    @discardableResult
    static func undo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
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
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            guard editor.undoManager?.canRedo == true else { return false }
            editor.undoManager?.redo()
            return true
        }
        #endif
        return session.redo()
    }
}
