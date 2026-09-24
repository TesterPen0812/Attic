import Foundation
import os

/// One Instruments stream: subsystem `com.taha.Attic`, category `Performance`.
/// All intervals are omitted when signposting is disabled. The UI intervals
/// mark AppKit/SwiftUI readiness boundaries, not display scan-out latency.
@MainActor
enum PerformanceSignposts {
    private static let signposter = OSSignposter(subsystem: "com.taha.Attic", category: "Performance")
    private static let captureRoot = PerformanceProbe.validatedRoot(
        environment: ProcessInfo.processInfo.environment
    )
    private static var launch: OSSignpostIntervalState?
    private static var reveal: OSSignpostIntervalState?
    private static var pageSwitch: OSSignpostIntervalState?
    private static var noteKey: OSSignpostIntervalState?
    private static var canvasDrag: OSSignpostIntervalState?
    private static var launchStart: UInt64?
    private static var revealStart: UInt64?
    private static var pageStart: UInt64?
    private static var noteStart: UInt64?
    private static var canvasStart: UInt64?
    static var hasPendingPageSwitch: Bool { pageSwitch != nil || pageStart != nil }

    private static func started() -> UInt64? {
        captureRoot == nil ? nil : DispatchTime.now().uptimeNanoseconds
    }

    private static func record(_ name: String, from start: UInt64?) {
        guard let start, let captureRoot else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        PerformanceProbe.writeTiming(name, milliseconds: elapsed, root: captureRoot)
    }

    static func beginLaunch() {
        launchStart = started()
        if signposter.isEnabled { launch = signposter.beginInterval("CoordinatorInitToMenuStarted") }
    }

    static func menuReady() {
        if let launch { signposter.endInterval("CoordinatorInitToMenuStarted", launch) }
        self.launch = nil
        record("CoordinatorInitToMenuStarted", from: launchStart)
        launchStart = nil
    }

    static func beginReveal() {
        guard reveal == nil, revealStart == nil else { return }
        revealStart = started()
        if signposter.isEnabled { reveal = signposter.beginInterval("PanelRevealToOrderedFront") }
    }

    static func panelOrderedFront() {
        if let reveal { signposter.endInterval("PanelRevealToOrderedFront", reveal) }
        self.reveal = nil
        record("PanelRevealToOrderedFront", from: revealStart)
        revealStart = nil
    }

    static func cancelReveal() {
        if let reveal { signposter.endInterval("PanelRevealToOrderedFront", reveal) }
        reveal = nil
        revealStart = nil
    }

    static func beginPageSwitch() {
        guard pageSwitch == nil, pageStart == nil else { return }
        pageStart = started()
        if signposter.isEnabled { pageSwitch = signposter.beginInterval("PageSwitch") }
    }

    static func pageLaidOut() {
        if let pageSwitch { signposter.endInterval("PageSwitch", pageSwitch) }
        self.pageSwitch = nil
        record("PageSwitch", from: pageStart)
        pageStart = nil
    }

    static func cancelPageSwitch() {
        if let pageSwitch { signposter.endInterval("PageSwitch", pageSwitch) }
        pageSwitch = nil
        pageStart = nil
    }

    static func beginNoteKey() {
        guard noteKey == nil, noteStart == nil else { return }
        noteStart = started()
        if signposter.isEnabled { noteKey = signposter.beginInterval("NoteKeystrokeToDraw") }
    }

    static func noteDidDraw() {
        if let noteKey { signposter.endInterval("NoteKeystrokeToDraw", noteKey) }
        self.noteKey = nil
        record("NoteKeystrokeToDraw", from: noteStart)
        noteStart = nil
    }

    static func cancelNoteKey() {
        if let noteKey { signposter.endInterval("NoteKeystrokeToDraw", noteKey) }
        noteKey = nil
        noteStart = nil
    }

    static func beginCanvasDrag() {
        guard canvasDrag == nil, canvasStart == nil else { return }
        canvasStart = started()
        if signposter.isEnabled { canvasDrag = signposter.beginInterval("CanvasDragToDraw") }
    }

    static func canvasDidDraw() {
        if let canvasDrag { signposter.endInterval("CanvasDragToDraw", canvasDrag) }
        self.canvasDrag = nil
        record("CanvasDragToDraw", from: canvasStart)
        canvasStart = nil
    }

    static func cancelCanvasDrag() {
        if let canvasDrag { signposter.endInterval("CanvasDragToDraw", canvasDrag) }
        canvasDrag = nil
        canvasStart = nil
    }

    static func storeOpen<T>(_ operation: () throws -> T) rethrows -> T {
        let state = signposter.isEnabled ? signposter.beginInterval("StoreOpen") : nil
        let start = started()
        defer {
            if let state { signposter.endInterval("StoreOpen", state) }
            record("StoreOpen", from: start)
        }
        return try operation()
    }

    static func storeSave<T>(_ operation: () throws -> T) rethrows -> T {
        let state = signposter.isEnabled ? signposter.beginInterval("StoreSave") : nil
        let start = started()
        defer {
            if let state { signposter.endInterval("StoreSave", state) }
            record("StoreSave", from: start)
        }
        return try operation()
    }
}
