import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Round O1 (`phaseX/owner-feedback-1017.md`, O17-02 to O17-14): the Tasks
/// composer, subtasks and small visuals, checked without a window on screen
/// (hosted pages sit off screen) and without the general pasteboard.
@MainActor
final class RoundO1Tests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    private func tokenFields(in view: NSView) -> [AtticTokenFieldView] {
        (view as? AtticTokenFieldView).map { [$0] } ?? view.subviews.flatMap { tokenFields(in: $0) }
    }

    // MARK: - O17-02 · the toast sits one gap above the stack as drawn

    func testTheToastSitsOneGapAboveTheBottomStackWhateverItShows() {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: AtticLayout.panelSize)
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let contentBottom = layout.contentInsets.bottom
        let bar = AtticControlSize.addBarHeight
        let stacks = [
            ("bar alone", bar),
            ("date and tags row", bar + AtticPickerMetrics.stripToBar + AtticControlSize.smallHeight),
            ("a grown bar", bar + 3 * 16)
        ]
        for (name, stack) in stacks {
            let clearance = TasksNoticeClearance.clearance(stack: stack, bottomInset: bottomInset, contentBottom: contentBottom)
            // The shell sits its notices `contentBottom + clearance` above
            // the panel's bottom; the stack's top is `bottomInset + stack`.
            let gap = contentBottom + clearance - (bottomInset + stack)
            XCTAssertEqual(gap, AtticSpacing.s8, accuracy: 0.01, "\(name): one gap above what the stack shows")
        }
        // Before O1 the bar alone kept room for the row above it.
        let old = TasksPage.footerZone + contentBottom - (bottomInset + bar)
        XCTAssertGreaterThan(old, AtticSpacing.s8 + 4, "the old clearance left the toast far above a lone bar")
    }

    // MARK: - O17-03 · a double-click edits a subtask

    private func post(_ hosted: Hosted, at point: CGPoint, clickCount: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: hosted.height - point.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                                           context: nil, eventNumber: 7, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        Hosted.pumpEvents()
        spin(0.1)
    }

    func testADoubleClickOnASubtaskEditsItsTitleAndASingleClickOnlyGivesItTheKeyboard() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.setExpanded(parent.id, true)
        hosted.spin(0.5)
        let child = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }?.subtasks.first)
        let row = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: parent.id)])
        // The first subtask's line: the first point under the row where a
        // double-click edits it.
        var line: CGPoint?
        // (The row's frame holds its open quick look, under its title.)
        var y = row.minY + AtticLayout.rowPitch + 2
        while y < row.maxY, line == nil {
            let point = CGPoint(x: 150, y: y)
            post(hosted, at: point, clickCount: 1)
            post(hosted, at: point, clickCount: 2)
            if hosted.model.renamingSubtaskID == child.id { line = point }
            if line == nil { hosted.model.cancelEditing() }
            y += 4
        }
        let point = try XCTUnwrap(line, "a double-click on the subtask's line edits its title in place")
        XCTAssertEqual(hosted.model.subtaskRename, child.title)
        // A single click only gives the line the keyboard, as before.
        hosted.model.cancelSubtaskRename()
        hosted.spin(0.3)
        post(hosted, at: point, clickCount: 1)
        hosted.spin(0.3)
        XCTAssertNil(hosted.model.renamingSubtaskID, "a single click does not edit")
        XCTAssertEqual(hosted.model.focusedSubtaskID, child.id, "a single click gives the line the keyboard")
    }

    // MARK: - O17-04 · Return moves on to a new subtask

    private func returnKey(in field: NSTextField) {
        let editor = NSTextView()
        editor.string = field.stringValue
        _ = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    func testReturnInASubtaskSavesItAndMovesOnToANewOneUntilAnEmptyReturn() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.setExpanded(parent.id, true)
        let children = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }).subtasks
        let child = try XCTUnwrap(children.first)
        let content = try XCTUnwrap(hosted.window.contentView)

        // An existing subtask: Return saves it, then a new empty one opens.
        hosted.model.beginRenamingSubtask(child.id)
        hosted.model.subtaskRename = "Renamed first"
        hosted.spin(0.3)
        returnKey(in: try XCTUnwrap(fields(in: content).first { $0.isEditable && $0.accessibilityLabel() == "Rename subtask" }))
        hosted.spin(0.3)
        XCTAssertEqual(hosted.store.task(withID: child.id)?.title, "Renamed first")
        XCTAssertNil(hosted.model.renamingSubtaskID)
        XCTAssertEqual(hosted.model.newSubtaskParentID, parent.id, "Return moves on to a new subtask")

        // A new one: Return adds it and keeps an empty one for the next.
        hosted.model.newSubtaskTitle = "Second new"
        hosted.spin(0.3)
        returnKey(in: try XCTUnwrap(fields(in: content).first { $0.isEditable && $0.placeholderString == "Add subtask…" }))
        hosted.spin(0.3)
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count + 1)
        XCTAssertEqual(hosted.model.newSubtaskParentID, parent.id)
        XCTAssertEqual(hosted.model.newSubtaskTitle, "")

        // An empty Return ends the entry.
        returnKey(in: try XCTUnwrap(fields(in: content).first { $0.isEditable && $0.placeholderString == "Add subtask…" }))
        hosted.spin(0.3)
        XCTAssertNil(hosted.model.newSubtaskParentID, "an empty Return ends entry")
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count + 1)

        // One Undo step per subtask: the new one, then the rename.
        XCTAssertTrue(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count)
        XCTAssertEqual(hosted.store.task(withID: child.id)?.title, "Renamed first")
        XCTAssertTrue(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.store.task(withID: child.id)?.title, child.title)
    }

    func testReturnOnAnEmptiedSubtaskOnlyEndsTheRename() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.setExpanded(parent.id, true)
        let child = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }?.subtasks.first)
        hosted.model.beginRenamingSubtask(child.id)
        hosted.model.subtaskRename = "   "
        XCTAssertTrue(hosted.model.submitSubtaskRename())
        XCTAssertNil(hosted.model.renamingSubtaskID)
        XCTAssertNil(hosted.model.newSubtaskParentID)
        XCTAssertEqual(hosted.store.task(withID: child.id)?.title, child.title)
    }

    // MARK: - O17-05 · composers grow with their text

    func testTheGrowthHeightIsOneLineUpToTheMostLines() {
        let line: CGFloat = 16
        XCTAssertEqual(AtticTokenFieldGrowth.height(lines: 1, lineHeight: line, minHeight: 20, maxLines: 6), 20)
        XCTAssertEqual(AtticTokenFieldGrowth.height(lines: 3, lineHeight: line, minHeight: 20, maxLines: 6), 52)
        XCTAssertEqual(AtticTokenFieldGrowth.height(lines: 40, lineHeight: line, minHeight: 20, maxLines: 6), 100)
        XCTAssertEqual(AtticTokenFieldGrowth.height(lines: 0, lineHeight: line, minHeight: 20, maxLines: 6), 20)
    }

    func testTheAddBarGrowsWithItsTextUpToItsMostLinesAndShrinksWhenCleared() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        let content = try XCTUnwrap(hosted.window.contentView)
        let field = try XCTUnwrap(tokenFields(in: content).first { $0.textView.accessibilityLabel() == hosted.model.addPlaceholder })
        XCTAssertEqual(field.frame.height, AtticTokenFieldMetrics.height, accuracy: 0.5, "one line to start")
        let oneLine = field.frame.height

        hosted.model.addBarState.text.text = "Call the plumber about the kitchen sink and ask about the bathroom tap too"
        hosted.spin(0.6)
        XCTAssertGreaterThan(field.wrappedLineCount, 1, "long text wraps")
        XCTAssertGreaterThan(field.frame.height, oneLine + 8, "the field grows a line for each it wraps onto")

        hosted.model.addBarState.text.text = String(repeating: "A very long task title that keeps going ", count: 12)
        hosted.spin(0.6)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: AtticTextStyle.listBody.nsFont))
        XCTAssertGreaterThan(field.wrappedLineCount, AtticComposerMetrics.maxLines)
        XCTAssertEqual(field.frame.height, oneLine + CGFloat(AtticComposerMetrics.maxLines - 1) * line, accuracy: 1,
                       "past its most lines it scrolls inside")

        hosted.model.addBarState.clearDraft()
        hosted.spin(0.6)
        XCTAssertEqual(field.frame.height, oneLine, accuracy: 0.5, "cleared, it is one line again")
    }

    func testANewSubtaskEntryGrowsWithItsText() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.beginAddingSubtask(to: parent.id)
        hosted.spin(0.3)
        let content = try XCTUnwrap(hosted.window.contentView)
        let field = try XCTUnwrap(fields(in: content).first { $0.isEditable && $0.placeholderString == "Add subtask…" })
        let oneLine = field.frame.height
        XCTAssertEqual(oneLine, AtticTaskRowMetrics.titleLineHeight, accuracy: 0.5)
        hosted.model.newSubtaskTitle = "Ask the landlord about the boiler service and the gas safety certificate before Friday"
        hosted.spin(0.4)
        XCTAssertGreaterThan(field.frame.height, oneLine + 8, "the entry wraps and grows")
        hosted.model.newSubtaskTitle = ""
        hosted.spin(0.4)
        XCTAssertEqual(field.frame.height, oneLine, accuracy: 0.5)
    }

    // MARK: - V-12 · a grown composer shows whole lines only

    /// V-12: the add bar at its most lines shows exactly that many whole
    /// lines between its top and bottom room, scrolled to the insertion
    /// point by whole lines: never half a line at the bottom, nor a sliver
    /// of the line above at the top.
    func testV12TheAddBarShowsWholeLinesOnly() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true)
        defer { hosted.close() }
        let content = try XCTUnwrap(hosted.window.contentView)
        let field = try XCTUnwrap(tokenFields(in: content).first { $0.textView.accessibilityLabel() == hosted.model.addPlaceholder })
        let line = ceil(NSLayoutManager().defaultLineHeight(for: AtticTextStyle.listBody.nsFont))
        hosted.model.addBarState.text.text = String(repeating: "A very long task title that keeps going ", count: 12)
        hosted.spin(0.6)
        field.textView.setSelectedRange(NSRange(location: (field.textView.string as NSString).length, length: 0))
        field.textView.scrollRangeToVisible(field.textView.selectedRange())
        hosted.spin(0.2)
        let clip = field.textClip.bounds
        XCTAssertEqual(clip.height, CGFloat(AtticComposerMetrics.maxLines) * line, accuracy: 0.01, "whole lines, its room outside them")
        XCTAssertGreaterThan(clip.minY, 0, "scrolled to the insertion point")
        XCTAssertEqual(clip.minY.truncatingRemainder(dividingBy: line), 0, accuracy: 0.01, "scrolled by whole lines")
        let clipFrame = field.convert(field.textClip.bounds, from: field.textClip)
        XCTAssertEqual(clipFrame.minY, field.bounds.height - clipFrame.maxY, accuracy: 0.01, "the same room above and below")
        XCTAssertEqual(clipFrame.minY, (AtticTokenFieldMetrics.height - line) / 2, accuracy: 0.01)
        // A scroll that would stop mid-line stops on a line.
        field.textClip.scroll(to: NSPoint(x: 0, y: line * 1.4))
        XCTAssertEqual(field.textClip.bounds.minY.truncatingRemainder(dividingBy: line), 0, accuracy: 0.01)
    }

    /// V-12: a subtask's entry draws and edits its text in whole lines,
    /// with equal room above and below, at every height it grows to; its
    /// editor scrolls by whole lines.
    func testV12ASubtaskEntryShowsWholeLinesOnly() {
        let font = AtticTextStyle.rowTitle.nsFont
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let cell = AtticSubtaskTitleCell()
        cell.font = font
        for words in [1, 12, 30, 60, 200] {
            let text = Array(repeating: "word", count: words).joined(separator: " ")
            let height = AtticSubtaskTitleField.height(of: text, width: 220, font: font)
            let rect = cell.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 220, height: height))
            XCTAssertEqual(rect.height.truncatingRemainder(dividingBy: line), 0, accuracy: 0.01, "\(words) words: whole lines")
            XCTAssertEqual(rect.minY, height - rect.maxY, accuracy: 0.01, "\(words) words: the same room above and below")
            XCTAssertLessThanOrEqual(rect.height, CGFloat(AtticComposerMetrics.maxLines) * line + 0.01)
        }
        let editor = AtticSubtaskFieldEditor(frame: NSRect(x: 0, y: 0, width: 220, height: line * 12))
        editor.font = font
        let snapped = editor.adjustScroll(NSRect(x: 0, y: line * 2.6, width: 220, height: line * 6))
        XCTAssertEqual(snapped.minY, line * 3, accuracy: 0.01, "it scrolls by whole lines")
    }

    // MARK: - O17-06 · files in the composer

    private func makeFile(_ name: String, bytes: Int = 12) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attic-o1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func pngData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { spin(0.05) }
    }

    private func makeModel() throws -> (TaskStore, TasksPageModel) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        return (store, TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices()))
    }

    func testFilesAddedWhileComposingGoOntoTheNewTaskThroughTheTaskImport() throws {
        let (store, model) = try makeModel()
        let file = try makeFile("Lease.pdf")
        model.addComposerFiles(urls: [file])
        // A pasted image: staged at once into Attic's own drop folder.
        let image = NSItemProvider(item: try pngData() as NSData, typeIdentifier: UTType.png.identifier)
        image.suggestedName = "Pasted Image"
        model.addComposerFiles([image])
        waitUntil { model.addBarState.files.count == 2 }
        XCTAssertEqual(model.addBarState.files.count, 2)
        XCTAssertEqual(model.composerFilesValue?.text, "2 files")
        let staged = try XCTUnwrap(model.addBarState.files.last?.staging.urls.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "the pasted image is staged while the title is typed")

        model.addBarState.text.text = "Sign the lease"
        let id = try XCTUnwrap(model.submitAddBar())
        XCTAssertTrue(model.addBarState.files.isEmpty, "the bar's files went with the task")
        waitUntil { (store.task(withID: id)?.attachments.count ?? 0) == 2 }
        let names = store.task(withID: id)?.attachments.map(\.filename) ?? []
        XCTAssertEqual(names.count, 2, "both files are on the new task")
        XCTAssertTrue(names.contains("Lease.pdf"))
        XCTAssertTrue(names.contains { $0.hasPrefix("Pasted Image") })
        waitUntil { !FileManager.default.fileExists(atPath: staged.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Attic's staged copy is removed after the import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an original is never touched")
    }

    func testRemovingTheComposersFilesDiscardsOnlyAtticsCopies() throws {
        let (_, model) = try makeModel()
        let file = try makeFile("Notes.txt")
        model.addComposerFiles(urls: [file])
        model.addComposerFiles([NSItemProvider(item: try pngData() as NSData, typeIdentifier: UTType.png.identifier)])
        waitUntil { model.addBarState.files.count == 2 }
        let staged = try XCTUnwrap(model.addBarState.files.last?.staging.urls.first)
        model.clearComposerFiles()
        XCTAssertTrue(model.addBarState.files.isEmpty)
        XCTAssertNil(model.composerFilesValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAPasteHoldsFilesOrALoneImageAndOtherwiseText() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("attic-o1-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([try makeFile("Plan.pdf") as NSURL])
        XCTAssertEqual(AtticPastedFiles.providers(from: board).count, 1, "copied files")
        board.clearContents()
        board.setString("Buy milk", forType: .string)
        XCTAssertTrue(AtticPastedFiles.providers(from: board).isEmpty, "text pastes as text")
        board.clearContents()
        board.setData(try pngData(), forType: .png)
        XCTAssertEqual(AtticPastedFiles.providers(from: board).count, 1, "a lone image")
        board.clearContents()
        board.declareTypes([.png, .string], owner: nil)
        board.setData(try pngData(), forType: .png)
        board.setString("https://example.com/a.png", forType: .string)
        XCTAssertTrue(AtticPastedFiles.providers(from: board).isEmpty, "an image with text beside it pastes the text")
        XCTAssertEqual(AtticPastedFiles.providers(from: board, filesOnly: true).count, 1, "dragged, the image is the point")
    }

    func testTheStripOffersAttachAsAnIconUntilFilesWait() {
        let faces: [(title: String, value: AtticStripValue?)] = [("Date", nil), ("Tag", nil), ("Priority", nil), ("Attach", nil)]
        let iconOnly = AtticComposerStrip<EmptyView, EmptyView, EmptyView>.iconOnlyButtons(faces, available: 288, fixed: [3])
        XCTAssertEqual(iconOnly, [3], "an empty strip keeps its three names; Attach is its paperclip")
        XCTAssertLessThanOrEqual(AtticComposerStrip<EmptyView, EmptyView, EmptyView>.usualWidth(faces, iconOnly: iconOnly), 288,
                                 "the four fit the narrowest panel's bar")
        XCTAssertTrue(AtticStripFocusID.all.contains(AtticStripFocusID(identifier: "composer-files")), "Tab reaches Attach")
    }

    // MARK: - O17-10 · the actions button's dots read as one glyph

    /// Dots and gaps of a drawn ellipsis, in points (rendered at 8×).
    private func dots(_ view: some View, width: CGFloat = 40, height: CGFloat = 20) throws -> (dots: [CGFloat], gaps: [CGFloat]) {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 8
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var ink: [Bool] = []
        for x in 0..<rep.pixelsWide {
            var found = false
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.75 {
                found = true
                break
            }
            ink.append(found)
        }
        var runs: [(Int, Int)] = []
        var start: Int?
        for (x, on) in ink.enumerated() {
            if on, start == nil { start = x }
            if !on, let first = start { runs.append((first, x)); start = nil }
        }
        let dots = runs.map { CGFloat($0.1 - $0.0) / 8 }
        let gaps = zip(runs, runs.dropFirst()).map { CGFloat($1.0 - $0.1) / 8 }
        return (dots, gaps)
    }

    func testTheRowActionsDotsSitCloserThanTheyAreWideAsATypesetEllipsisDoes() throws {
        let m = AtticRowActionsMetrics.self
        let drawn = try dots(AtticIcon(systemName: "ellipsis", size: m.iconSize, weight: m.iconWeight, ink: .heading)
            .atticDesign(AtticDesignContext(mode: .light)))
        XCTAssertEqual(drawn.dots.count, 3)
        // The reference: the system's own typeset "…" in bold at the same
        // size, whose dots read as one glyph.
        let typeset = try dots(Text(verbatim: "…").font(.system(size: m.iconSize, weight: .bold)).foregroundStyle(.black))
        XCTAssertEqual(typeset.dots.count, 3)
        func ratio(_ d: (dots: [CGFloat], gaps: [CGFloat])) -> CGFloat {
            (d.gaps.reduce(0, +) / CGFloat(d.gaps.count)) / (d.dots.reduce(0, +) / CGFloat(d.dots.count))
        }
        print(String(format: "O1_ELLIPSIS drawn gap/dot %.2f (dots %@ gaps %@) typeset bold %.2f", ratio(drawn),
                     drawn.dots.description, drawn.gaps.description, ratio(typeset)))
        XCTAssertLessThanOrEqual(ratio(drawn), ratio(typeset) + 0.02, "the dots sit as close as a typeset ellipsis's")
    }

    // MARK: - O17-11 · no eye on a file line

    func testAFileLineUnderThePointerShowsRemoveAloneAndStillPreviewsByKeyboardAndVoiceOver() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let file = TaskImageReference(id: UUID(), filename: "Lease.pdf", digest: "d", contentTypeIdentifier: UTType.pdf.identifier, byteCount: 2048)
        let row = TasksFileRow(file: file, store: store, owner: UUID(), remove: {})
            .frame(width: 280)
            .padding(.horizontal, 12)
            .atticForcedState(.hover)
            .atticDesign(AtticDesignContext(mode: .light))
            .background(Color.white)
        let host = NSHostingView(rootView: AnyView(row))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Glyph clusters in the line's trailing 60 pt (where the size was).
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let from = Int((host.bounds.width - 12 - 60) * scale)
        var clusters = 0
        var inside = false
        for x in from..<Int((host.bounds.width - 12) * scale) {
            var on = false
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.7 {
                on = true
                break
            }
            if on, !inside { clusters += 1 }
            inside = on
        }
        XCTAssertEqual(clusters, 1, "Remove alone: a click on the line already previews it")
        // Keyboard and VoiceOver still preview: Space and the default
        // action (unchanged), and Quick Look by name among its actions.
        XCTAssertEqual(TasksFileRow.voiceOverActions(canOpen: true), [.quickLook, .open, .remove])
        XCTAssertEqual(TasksFileRow.voiceOverActions(canOpen: false), [.quickLook, .remove])
    }

    // MARK: - O17-14 · equal inner padding in a quiet action's hover

    func testAQuietActionsHoverHasTheSameRoomOnBothSides() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for (symbol, title) in [("plus", "Add subtask"), ("paperclip", "Attach file…"), ("chevron.down", "3 more…")] {
                let context = AtticDesignContext(mode: mode)
                let view = AtticQuietAction(systemName: symbol, title: title, action: {})
                    .padding(12)
                    .atticForcedState(.hover)
                    .atticDesign(context)
                    .background(context.tokens.panel.base.color)
                let host = NSHostingView(rootView: AnyView(view))
                host.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                // At 4× (a quarter point), so a point's difference shows.
                let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 4),
                                                         pixelsHigh: Int(host.bounds.height * 4), bitsPerSample: 8, samplesPerPixel: 4,
                                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = host.bounds.size
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / host.bounds.width
                let base = try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
                func distance(_ x: Int, _ y: Int) -> CGFloat {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
                    return abs(c.redComponent - base.redComponent) + abs(c.greenComponent - base.greenComponent) + abs(c.blueComponent - base.blueComponent)
                }
                // The fill: anything off the base (it holds the glyphs). The
                // ink: clearly off it.
                let columns = (0..<rep.pixelsWide).map { x in (0..<rep.pixelsHigh).map { distance(x, $0) }.max() ?? 0 }
                let fill = columns.indices.filter { columns[$0] > 0.02 }
                let ink = columns.indices.filter { columns[$0] > 0.3 }
                let fillLeft = try XCTUnwrap(fill.first), fillRight = try XCTUnwrap(fill.last)
                let inkLeft = try XCTUnwrap(ink.first), inkRight = try XCTUnwrap(ink.last)
                let left = CGFloat(inkLeft - fillLeft) / scale, right = CGFloat(fillRight - inkRight) / scale
                let rows = (0..<rep.pixelsHigh).map { y in (0..<rep.pixelsWide).map { distance($0, y) }.max() ?? 0 }
                let fillRows = rows.indices.filter { rows[$0] > 0.02 }, inkRows = rows.indices.filter { rows[$0] > 0.3 }
                print(String(format: "O1_QUIET_V %@ %@ top %.2f bottom %.2f", mode == .dark ? "dark" : "light", title,
                             CGFloat((inkRows.first ?? 0) - (fillRows.first ?? 0)) / scale,
                             CGFloat((fillRows.last ?? 0) - (inkRows.last ?? 0)) / scale))
                print(String(format: "O1_QUIET %@ %@ left %.2f right %.2f", mode == .dark ? "dark" : "light", title, left, right))
                // Layout snaps to the display's pixels: within half a
                // point on Retina, within one pixel on a 1× display (CI).
                let pixel = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
                XCTAssertEqual(left, right, accuracy: max(0.5, pixel), "\(title) (\(mode)): the same room on both sides")
            }
        }
    }
}
