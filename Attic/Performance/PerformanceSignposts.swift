import Foundation
import os

/// One Instruments stream: subsystem `com.taha.Attic`, category `Performance`.
/// All intervals are omitted when signposting is disabled. The UI intervals
/// mark AppKit/SwiftUI readiness boundaries, not display scan-out latency.
@MainActor
enum PerformanceSignposts {
    private static let signposter = OSSignposter(subsystem: "com.taha.Attic", category: "Performance")
    private static var launch: OSSignpostIntervalState?
    private static var reveal: OSSignpostIntervalState?
    private static var pageSwitch: OSSignpostIntervalState?
    private static var noteKey: OSSignpostIntervalState?
    private static var canvasDrag: OSSignpostIntervalState?

    static func beginLaunch() {
        guard signposter.isEnabled else { return }
        launch = signposter.beginInterval("AppLaunchToMenuReady")
    }

    static func menuReady() {
        guard let launch else { return }
        signposter.endInterval("AppLaunchToMenuReady", launch)
        self.launch = nil
    }

    static func beginReveal() {
        guard signposter.isEnabled, reveal == nil else { return }
        reveal = signposter.beginInterval("PanelRevealToInteractive")
    }

    static func panelOrderedFront() {
        guard let reveal else { return }
        signposter.endInterval("PanelRevealToInteractive", reveal)
        self.reveal = nil
    }

    static func beginPageSwitch() {
        guard signposter.isEnabled, pageSwitch == nil else { return }
        pageSwitch = signposter.beginInterval("PageSwitch")
    }

    static func pageLaidOut() {
        guard let pageSwitch else { return }
        signposter.endInterval("PageSwitch", pageSwitch)
        self.pageSwitch = nil
    }

    static func beginNoteKey() {
        guard signposter.isEnabled, noteKey == nil else { return }
        noteKey = signposter.beginInterval("NoteKeystrokeToDraw")
    }

    static func noteDidDraw() {
        guard let noteKey else { return }
        signposter.endInterval("NoteKeystrokeToDraw", noteKey)
        self.noteKey = nil
    }

    static func beginCanvasDrag() {
        guard signposter.isEnabled, canvasDrag == nil else { return }
        canvasDrag = signposter.beginInterval("CanvasDragToDraw")
    }

    static func canvasDidDraw() {
        guard let canvasDrag else { return }
        signposter.endInterval("CanvasDragToDraw", canvasDrag)
        self.canvasDrag = nil
    }

    static func storeOpen<T>(_ operation: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try operation() }
        let state = signposter.beginInterval("StoreOpen")
        defer { signposter.endInterval("StoreOpen", state) }
        return try operation()
    }

    static func storeSave<T>(_ operation: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try operation() }
        let state = signposter.beginInterval("StoreSave")
        defer { signposter.endInterval("StoreSave", state) }
        return try operation()
    }
}
