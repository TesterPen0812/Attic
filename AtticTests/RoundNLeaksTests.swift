import AppKit
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class RoundNLeaksTests: XCTestCase {
    final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T? = nil) { self.value = value }
    }

    private func settle(_ seconds: TimeInterval = 0.15) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        } while Date() < end
    }

    private func awaitRelease(_ released: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !released(), Date() < end { settle(0.03) }
    }

    private func pauseForTrace(_ objects: [(String, AnyObject?)]) {
        guard ProcessInfo.processInfo.environment["ATTIC_LEAK_PROBE"] == "1" else { return }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("round-n-probe-\(ProcessInfo.processInfo.processIdentifier)-\(objects[0].0)")
        let lines = objects.map { name, object in
            "\(name)=\(object.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil")"
        }.joined(separator: "\n")
        try? lines.write(to: marker, atomically: true, encoding: .utf8)
        print("ROUND_N_PROBE \(marker.path) \(lines)")
        let end = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: marker.path + ".continue"), Date() < end { settle(0.1) }
    }

    func testL01RemovedNotesPageReleasesChromeAndLibrary() throws {
        let chrome = Weak<NotesPageChrome>(), library = Weak<NotesLibraryModel>()
        let hostProbe = Weak<NSView>(), windowProbe = Weak<NSWindow>()
        NotesEditorPage.lifetimeProbe = { chrome.value = $0; library.value = $1 }
        defer { NotesEditorPage.lifetimeProbe = nil }
        try autoreleasepool {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let draft = NoteDraftController(noteStore: store)
            let page = NotesEditorPage(controller: draft.pages, noteStore: store, noteDraft: draft,
                uiState: PanelUIState(), layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520)))
            let host = NSHostingView(rootView: AnyView(page))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            hostProbe.value = host; windowProbe.value = window
            host.layoutSubtreeIfNeeded(); settle()
            XCTAssertNotNil(chrome.value); XCTAssertNotNil(library.value)
            chrome.value?.captureToggleLibrary?(); settle()
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded(); settle()
            window.contentView = nil; window.close()
        }
        awaitRelease { chrome.value == nil && library.value == nil && hostProbe.value == nil && windowProbe.value == nil }
        pauseForTrace([("chrome", chrome.value), ("library", library.value)])
        XCTAssertNil(hostProbe.value); XCTAssertNil(windowProbe.value)
        XCTAssertNil(chrome.value); XCTAssertNil(library.value)
    }

    func testL05RemovedTasksHostReleasesBothHolds() throws {
        let edit = Weak<PanelEditHold>(), files = Weak<PanelEditHold>()
        try autoreleasepool {
            let store = try makeTestStore()
            let uiState = PanelUIState()
            let suite = "RoundN.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let editHold = PanelEditHold(), filesHold = PanelEditHold()
            edit.value = editHold; files.value = filesHold
            let host = TasksPageHost(store: store, uiState: uiState, settings: AppSettings(defaults: defaults), state: TasksPageState(),
                layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520)),
                chromeInteractionState: PanelChromeInteractionState(), primaryInputFocusRequest: 0,
                editHold: editHold, filesHold: filesHold)
            let chrome = host.pageChrome(editHold: editHold, filesHold: filesHold)
            chrome.editLock(true); chrome.filesLock(true)
            XCTAssertEqual(edit.value?.isHeld, true); XCTAssertEqual(files.value?.isHeld, true)
            chrome.editLock(false); chrome.filesLock(false)
            edit.value?.setSuspended(true); files.value?.setSuspended(true)
        }
        awaitRelease { edit.value == nil && files.value == nil }
        pauseForTrace([("editHold", edit.value), ("filesHold", files.value)])
        XCTAssertNil(edit.value); XCTAssertNil(files.value)
    }

    func testL03RetryableRowFailureDoesNotRetainThePageModel() throws {
        let probe = Weak<TasksPageModel>()
        try autoreleasepool {
            let gate = PersistenceGate()
            let store = try makeTestStore(persist: gate.save)
            let id = try XCTUnwrap(store.create(title: "Retry task")).id
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            probe.value = model
            let page = TasksPage(model: model, store: store,
                layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520)), addBarFocused: .constant(false))
            gate.shouldFail = true
            page.actions(for: id, in: .now).toggleDone()
            XCTAssertEqual(model.rowFailure?.canRetry, true)
        }
        awaitRelease { probe.value == nil }
        pauseForTrace([("rowModel", probe.value)])
        XCTAssertNil(probe.value)
    }

    func testL06PrintedTableReleasesItsAttachmentAndStillDraws() throws {
        let probe = Weak<NoteTableAttachment>()
        try autoreleasepool {
            let view = NotePrint.printView(document: NoteDocument(blocks: [.text("Table print"),
                .table(NoteTable(texts: [["Heading", "Value"], ["Kept", "Visible"]]))]))
            view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
                if let table = value as? NoteTableAttachment { probe.value = table }
            }
            let image = try XCTUnwrap(probe.value?.renderedImage)
            XCTAssertEqual(image.size.width, NotePrint.columnWidth, accuracy: 0.5)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            var darkPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       colour.alphaComponent > 0.5, colour.redComponent < 0.7 { darkPixels += 1 }
                }
            }
            XCTAssertGreaterThan(darkPixels, 50, "the print snapshot actually draws text and the grid")
        }
        awaitRelease { probe.value == nil }
        pauseForTrace([("printTable", probe.value)])
        XCTAssertNil(probe.value)
    }
    func testL04RemovedRowDropsOnlyItsOwnControlFrames() throws {
        let store = try makeTestStore()
        let id = try XCTUnwrap(store.create(title: "Departing row")).id
        let newerID = try XCTUnwrap(store.create(title: "Replaced owner")).id
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let session = TasksDragSession()
        let page = TasksPage(model: model, store: store,
            layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520)),
            addBarFocused: .constant(false), dragSession: session)
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { host.rootView = AnyView(EmptyView()); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); settle(0.4)
        let key = TasksRowID(tab: .now, id: id), newerKey = TasksRowID(tab: .now, id: newerID)
        XCTAssertNotNil(session.controlFrames[key])
        XCTAssertNotNil(session.controlFrames[newerKey])
        let newerOwner = TasksCellReports()
        let replacement = [CGRect(x: 100, y: 0, width: 20, height: 20)]
        session.setControlFrames(replacement, for: newerKey, from: newerOwner)
        XCTAssertTrue(model.delete([id, newerID]).isApplied)
        host.layoutSubtreeIfNeeded(); settle(0.6)
        XCTAssertNil(session.controlFrames[key], "departed rows keep no control frames")
        XCTAssertEqual(session.controlFrames[newerKey], replacement, "old teardown cannot erase a newer cell's report")
    }

    func testL01OldTeardownLeavesNewerCommandsInstalled() {
        let chrome = NotesPageChrome(), old = UUID(), current = UUID()
        chrome.claimPageCommands(owner: old, keyPressed: { _ in false })
        chrome.claimPageCommands(owner: current, keyPressed: { _ in false })
        var leaves = 0, toggles = 0
        chrome.menuCommands = { [AtticMenuCommand("Current") {}] }
        chrome.leaveEditor = { _ in leaves += 1 }
        chrome.captureToggleLibrary = { toggles += 1 }
        chrome.clearPageCommands(owner: old)
        XCTAssertEqual(chrome.menuCommands().map(\.title), ["Current"])
        chrome.leaveEditor?(true); chrome.captureToggleLibrary?()
        XCTAssertEqual(leaves, 1); XCTAssertEqual(toggles, 1)
        chrome.clearPageCommands(owner: current)
        XCTAssertTrue(chrome.menuCommands().isEmpty)
        XCTAssertNil(chrome.leaveEditor); XCTAssertNil(chrome.captureToggleLibrary); XCTAssertNil(chrome.captureImport)
        let keys = NotesLibraryKeys()
        keys.start(owner: old, handler: { _ in false })
        keys.start(owner: current, handler: { _ in true })
        keys.stop(owner: old)
        XCTAssertNotNil(keys.handler)
        keys.stop(owner: current)
        XCTAssertNil(keys.handler); XCTAssertNil(keys.window)
    }


    func testL03RetryKeepsTheOriginalTargetsAfterSelectionChanges() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let a = try XCTUnwrap(store.create(title: "A")).id
        let b = try XCTUnwrap(store.create(title: "B")).id
        let other = try XCTUnwrap(store.create(title: "Other")).id
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let page = TasksPage(model: model, store: store,
            layout: PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 320, height: 520)), addBarFocused: .constant(false))
        model.selectOnly(a); model.extendSelection(to: b, visible: [a, b, other], from: a)
        let command = try XCTUnwrap(page.taskCommands(a, tab: .now).first { $0.title == "Complete" })
        gate.shouldFail = true
        command.action()
        XCTAssertEqual(model.rowFailure?.canRetry, true)
        XCTAssertEqual(store.task(withID: a)?.status, .todo)
        XCTAssertEqual(store.task(withID: b)?.status, .todo)
        model.selectOnly(other)
        model.retryRowFailure()
        XCTAssertEqual(model.rowFailure?.canRetry, true)
        gate.shouldFail = false
        model.retryRowFailure()
        XCTAssertNil(model.rowFailure)
        XCTAssertEqual(store.task(withID: a)?.status, .done)
        XCTAssertEqual(store.task(withID: b)?.status, .done)
        XCTAssertEqual(store.task(withID: other)?.status, .todo)
    }


}
