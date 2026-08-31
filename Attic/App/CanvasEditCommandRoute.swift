import Foundation

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
