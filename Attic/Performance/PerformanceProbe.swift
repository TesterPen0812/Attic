import Darwin
import Foundation
import AppKit

/// Test-only control plane. Marker writes are event-driven and outside samples.
enum PerformanceProbe {
    /// XCTest's runner is sandboxed separately and cannot write the app's
    /// container. For the UI metrics lane, create the disposable root from
    /// inside the app, using only a validated identifier supplied by XCTest.
    static func uiTestRoot(environment: [String: String]) throws -> URL? {
        guard environment["ATTIC_UI_TESTING"] == "1",
              environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1",
              environment["ATTIC_PERF_UI_TEST"] == "1",
              let identifier = environment["ATTIC_PERF_UI_IDENTIFIER"],
              let uuid = UUID(uuidString: identifier),
              let bundleID = Bundle.main.bundleIdentifier,
              bundleID == "com.taha.Attic.perf.ui",
              let account = getpwuid(getuid()) else { return nil }
        let base = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/AtticPerformanceStores",
                                isDirectory: true)
        let root = base.appendingPathComponent("attic-perf-ui-\(uuid.uuidString)", isDirectory: true)
        if environment["ATTIC_PERF_UI_CLEANUP"] == "1" {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            return nil
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
            base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        ) else { throw CocoaError(.fileReadNoPermission) }
        try Data(identifier.utf8).write(to: root.appendingPathComponent(".attic-perf-owner"), options: .atomic)
        return root
    }

    static func validatedRoot(environment: [String: String]) -> URL? {
        guard environment["ATTIC_UI_TESTING"] == "1",
              environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1",
              let path = environment["ATTIC_PERF_STORE_ROOT"],
              let token = environment["ATTIC_PERF_OWNER_TOKEN"], !token.isEmpty else { return nil }
        guard let account = getpwuid(getuid()),
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let bundlePerformanceStores = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/AtticPerformanceStores",
                                isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(bundlePerformanceStores.path + "/"),
              root.lastPathComponent.hasPrefix("attic-perf-"),
              let data = try? Data(contentsOf: root.appendingPathComponent(".attic-perf-owner")),
              String(data: data, encoding: .utf8) == token else { return nil }
        return root
    }

    static func writePhase(_ phase: String, root: URL, details: [String: Int] = [:]) {
        var record: [String: Any] = [
            "phase": phase,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": Date().timeIntervalSince1970
        ]
        for (key, value) in details { record[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: root.appendingPathComponent("phase.json"), options: .atomic)
        let markers = root.appendingPathComponent("phase-markers", isDirectory: true)
        try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try? data.write(to: markers.appendingPathComponent("\(phase).json"), options: .atomic)
    }

    static func writeTiming(_ name: String, milliseconds: Double, root: URL) {
        let record: [String: Any] = [
            "name": name, "milliseconds": milliseconds,
            "timestamp": Date().timeIntervalSince1970
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        let url = root.appendingPathComponent("timings.ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

#if DEBUG
/// Finite, externally stepped diagnostic workload in an owned on-disk store.
/// Installed only by the phasex UI-test control plane. No synthetic editor:
/// every visit waits for the actual SwiftUI-hosted text view to appear.
@MainActor
final class SmoothPerformanceProbe {
    private let root: URL
    private let notes: NoteStore
    private let tasks: TaskStore
    private let pages: NotesPageController
    private let reveal: (PanelSection) -> Void
    private let hide: () -> Void
    private var step = 0
    private var busy = false
    private var ids: [UUID] = []
    private final class Weak {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }
    private var engines: [Weak] = []
    private var views: [Weak] = []
    private var layouts: [Weak] = []

    init(root: URL, notes: NoteStore, tasks: TaskStore, pages: NotesPageController,
         reveal: @escaping (PanelSection) -> Void, hide: @escaping () -> Void) {
        self.root = root; self.notes = notes; self.tasks = tasks; self.pages = pages
        self.reveal = reveal; self.hide = hide
    }

    func advance() {
        guard !busy, step <= 62 else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let phase: String
                switch step {
                case 0:
                    reveal(.tasks)
                    try await Task.sleep(for: .seconds(1))
                    phase = "smooth_tasks"
                case 1:
                    try seed()
                    await pages.startAndWait()
                    phase = "smooth_seeded"
                case 2...61:
                    try await visit(step - 2)
                    phase = "smooth_visit_\(step - 1)"
                default:
                    guard await pages.prepareToLeaveDurably(.quit) else { throw ProbeError.failed }
                    hide()
                    try await Task.sleep(for: .seconds(3))
                    phase = "smooth_hidden"
                }
                PerformanceProbe.writePhase(phase, root: root, details: [
                    "engines": engines.compactMap(\.value).count,
                    "views": views.compactMap(\.value).count,
                    "layouts": layouts.compactMap(\.value).count,
                    "tasks": tasks.tasks.count
                ])
                step += 1
            } catch {
                PerformanceProbe.writePhase("smooth_failed", root: root)
            }
        }
    }

    private enum ProbeError: Error { case failed }

    private func seed() throws {
        guard notes.notes.isEmpty else { throw ProbeError.failed }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        let data = bitmap.representation(using: .png, properties: [:])!
        for index in 0..<12 {
            let count = index == 0 && ProcessInfo.processInfo.environment["ATTIC_SMOOTH_LONG"] == "1" ? 5_000 : 200
            var blocks = (0..<count).map { NoteBlock.text("Smooth note \(index), line \($0)") }
            blocks.insert(.table(NoteTable(texts: [["Task", "Date"], ["Write", "Monday"]])), at: 10)
            let item = StagedNoteAttachment(id: UUID(), filename: "smooth.png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
            blocks.insert(.image(attachmentID: item.id, pixelWidth: 800, pixelHeight: 400), at: 5)
            guard case let .success((id, _)) = notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks), staged: [item]) else { throw ProbeError.failed }
            ids.append(id)
        }
    }

    private func visit(_ index: Int) async throws {
        reveal(.notes)
        guard await pages.openDurably(noteID: ids[index % ids.count]), let session = pages.active else { throw ProbeError.failed }
        let deadline = Date().addingTimeInterval(5)
        while session.engine.textView?.window == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let view = session.engine.textView, view.window != nil else { throw ProbeError.failed }
        // Let the page's keyboard-return frames finish before setting a
        // diagnostic caret. Typing during restoration measures a different
        // (first-use focus) path and can move the insertion into the title.
        try await Task.sleep(for: .milliseconds(250))
        guard view.window?.makeFirstResponder(view) == true else { throw ProbeError.failed }
        engines.append(Weak(session.engine)); views.append(Weak(view))
        if let layout = session.engine.layoutManager { layouts.append(Weak(layout)) }
        let before = session.engine.textStorage.string
        view.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
        for _ in 0..<40 {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            let start = DispatchTime.now().uptimeNanoseconds
            view.keyDown(with: event)
            PerformanceSignposts.recordProbeTiming("NoteKeyCall", milliseconds:
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            try await Task.sleep(for: .milliseconds(10))
        }
        guard session.engine.textStorage.string == before + String(repeating: "a", count: 40) else { throw ProbeError.failed }
        guard await pages.prepareToLeaveDurably(.openNote),
              let task = tasks.create(title: "Smooth visit \(index)"),
              tasks.update(task, title: "Renamed visit \(index)"), tasks.setStatus(.done, for: task) else { throw ProbeError.failed }
        try await Task.sleep(for: .milliseconds(250))
    }
}
#endif
