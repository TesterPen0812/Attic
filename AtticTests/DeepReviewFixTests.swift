import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Phase 1's deep review, the UI fix round: Find from far down a list
/// (P2-01), Clean cut's fade over the control regions (A15 replaced D1)
/// (P2-02, owner A7: no native soft edges), one Open Files command for every route (P2-03), a visible
/// keyboard focus at every Tab stop (P2-04), the composer strip's values
/// in full (P3-01) and the pager's test-only settle (code review). Each is
/// driven the way a person drives it where the hosted page allows: real
/// key and mouse events through the app's queue, real menus.
@MainActor
final class DeepReviewFixTests: XCTestCase {
    private var savedEdge: AtticScrollEdgeStyle?

    override func tearDown() async throws {
        if let savedEdge { AtticScrollEdgeLab.shared.style = savedEdge }
        savedEdge = nil
        try await super.tearDown()
    }

    private func useCleanCut() {
        if savedEdge == nil { savedEdge = AtticScrollEdgeLab.shared.style }
        AtticScrollEdgeLab.shared.style = .cleanCut
    }

    private func layout(_ hosted: Hosted) -> PanelPageLayout {
        PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: hosted.height))
    }

    private func shownList(_ hosted: Hosted) throws -> NSScrollView {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        return try XCTUnwrap(hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        })
    }

    /// Scrolls the list to the end of what it holds.
    private func scrollToEnd(_ list: NSScrollView, _ hosted: Hosted) {
        list.layoutSubtreeIfNeeded()
        let clip = list.contentView
        let end = (list.documentView?.frame.height ?? 0) - clip.bounds.height + clip.contentInsets.bottom
        clip.scroll(to: CGPoint(x: 0, y: max(end, 0)))
        list.reflectScrolledClipView(clip)
        hosted.spin(0.5)
    }

    // MARK: - P2-01: Find from far down a list

    /// Far down the long list, a query matching a task near the top: the
    /// list goes back to its top, where the match is, and the match is in
    /// the part of the list nothing covers (it showed an empty viewport and
    /// no count). The same for a view that hides most of the list.
    func testAQueryTypedFarDownTheListShowsItsMatch() throws {
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        scrollToEnd(list, hosted)
        let deep = list.contentView.bounds.origin.y
        XCTAssertGreaterThan(deep, 200, "the long list is scrolled far down (\(deep))")

        let ship = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Ship appearance PR" }?.id)
        hosted.model.setSearchQuery("Ship", for: .now)
        hosted.spin(0.6)
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), [ship], "Find narrows the list to its match")
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5,
                       "the list is back at its top, where its first row (the match) rests under the tabs")
        XCTAssertLessThan(list.documentView?.frame.height ?? .infinity, list.contentView.bounds.height,
                          "the match and its count fit in the viewport")
        XCTAssertEqual(hosted.model.listSearchCount(for: .now)?.matches, 1, "and the count says so")

        // Changing the query keeps the list at its top, and clearing it too.
        hosted.model.setSearchQuery("Shi", for: .now)
        hosted.spin(0.4)
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5)
        hosted.model.setSearchQuery("", for: .now)
        hosted.spin(0.4)

        // A view that hides most of the list, from far down.
        scrollToEnd(list, hosted)
        XCTAssertGreaterThan(list.contentView.bounds.origin.y, 200)
        var view = hosted.model.viewOptions(for: .now)
        view.priority = .highOnly
        hosted.model.setViewOptions(view, for: .now)
        hosted.spin(0.6)
        XCTAssertEqual(list.contentView.bounds.origin.y, -list.contentView.contentInsets.top, accuracy: 0.5,
                       "a view that narrows the list starts it at its top")
        XCTAssertFalse(hosted.model.rows(for: .now).isEmpty)
    }

    // MARK: - Revised scroll-under: full ink under glass, faint at labels and edges

    func testTheViewportTracksFindTheStripSelectionAndPasteOffer() throws {
        useCleanCut()
        let hosted = try Hosted(height: 520, long: true, keyWindow: false)
        defer { hosted.close() }
        XCTAssertFalse(hosted.window.isKeyWindow)
        let list = try shownList(hosted)
        scrollToEnd(list, hosted)
        let layout = layout(hosted)
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let idle = TasksViewport.bottomMargin(bottomInset: bottomInset)
        func frame() -> CGRect {
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            return list.convert(list.bounds, to: hosted.window.contentView)
        }
        let resting = frame()
        XCTAssertEqual(resting.minY, 0, accuracy: 0.5)
        XCTAssertEqual(resting.maxY, hosted.height, accuracy: 0.5)
        XCTAssertEqual(list.contentInsets.top, TasksViewport.listTop(tabsTop: tabsTop), accuracy: 0.5)
        // Clean cut keeps a full viewport. Glass is unfaded; plain labels
        // and the outer edges have short fades. Compare two
        // actual scroll positions in each state, with visible body movement
        // as a positive control so an empty capture cannot pass.
        func assertClear(bottom: CGFloat, state: String, negativeControl: Bool = false) throws {
            let content = try XCTUnwrap(hosted.window.contentView)
            func capture(_ y: CGFloat) throws -> NSBitmapImageRep {
                list.contentView.scroll(to: CGPoint(x: 0, y: y))
                list.reflectScrolledClipView(list.contentView)
                hosted.spin(0.5)
                content.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: image)
                return image
            }
            // The long demo has only fourteen added errands. 1,300 scrolls
            // past its end and captures an empty list, hiding edge regressions.
            // These two positions keep real row ink through the viewport.
            var first = try capture(260), second = try capture(200)
            if state == "idle", ProcessInfo.processInfo.environment["ATTIC_A38_EDGE_OUTPUT"] != nil {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-a38-edges-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try first.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("edge-first.png"))
                try second.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("edge-second.png"))
                print("A38_EDGE_ARTIFACTS \(folder.path)")
            }
            let scale = CGFloat(first.pixelsWide) / content.bounds.width
            func difference(top: CGFloat, bottom: CGFloat, threshold: CGFloat = 0.03) -> Double {
                var changed = 0, total = 0
                for y in Int(top * scale)..<min(Int(bottom * scale), first.pixelsHigh, second.pixelsHigh) {
                    for x in 0..<first.pixelsWide {
                        guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let b = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        total += 1
                        // Over white: a near-transparent pixel whose colour
                        // flips (white at 0.4 % alpha against clear, seen in
                        // the add bar's band) is not ink.
                        let (p, q) = (a.alphaComponent, b.alphaComponent)
                        func over(_ c: CGFloat, _ alpha: CGFloat) -> CGFloat { c * alpha + 1 - alpha }
                        if max(abs(over(a.redComponent, p) - over(b.redComponent, q)), abs(over(a.greenComponent, p) - over(b.greenComponent, q)),
                               abs(over(a.blueComponent, p) - over(b.blueComponent, q))) > threshold { changed += 1 }
                    }
                }
                return total == 0 ? 1 : Double(changed) / Double(total)
            }
            let bodyTop = TasksViewport.listTop(tabsTop: tabsTop) + 30, bodyBottom = bottom - 30
            func bodyInk(_ image: NSBitmapImageRep) -> Double {
                var ink = 0, total = 0
                for y in Int(bodyTop * scale)..<Int(bodyBottom * scale) {
                    for x in 0..<image.pixelsWide {
                        guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        total += 1
                        if max(1 - c.redComponent, 1 - c.greenComponent, 1 - c.blueComponent) * c.alphaComponent > 0.35 { ink += 1 }
                    }
                }
                return total == 0 ? 0 : Double(ink) / Double(total)
            }
            for image in [first, second] {
                XCTAssertGreaterThan(bodyInk(image), 0.01, "\(state): each capture contains real body ink; neither may be past the list's end")
            }
            XCTAssertGreaterThan(difference(top: bodyTop, bottom: bodyBottom), 0.02,
                                 "\(state): rows actually moved between captures")
            // Owner revision, 2026-10-06: full ink under glass; only
            // the plain tabs line and the panel's own outer edges fade.
            let labelsBottom = tabsTop + AtticLayout.pageTabsHeight
            let glassTop = layout.scrollEdgeFadeTop
            let glassBottom = hosted.height - bottomInset - AtticControlSize.panelButton.height / 2
            XCTAssertGreaterThan(difference(top: glassTop, bottom: tabsTop - AtticScrollUnderFade.textRamp, threshold: 0.35), 0.002,
                                 "\(state): readable ink under header glass")
            XCTAssertGreaterThan(difference(top: bottom, bottom: glassBottom, threshold: 0.35), 0.002,
                                 "\(state): readable ink under bottom glass")
            XCTAssertGreaterThan(difference(top: tabsTop, bottom: labelsBottom), 0.0005,
                                 "\(state): ink remains faintly visible behind plain tabs")
            XCTAssertLessThan(difference(top: tabsTop, bottom: labelsBottom, threshold: 0.35), 0.002,
                              "\(state): no readable ink behind plain tabs")
            // A narrow edge can fall between glyph lines at a single scroll
            // position. Sweep a row pitch: at least one phase must show faint
            // moving ink, and none may show text-strength ink.
            let edgeBands = [(CGFloat(0), glassTop / 4),
                             (hosted.height - (hosted.height - glassBottom) / 4, hosted.height)]
            var faintEdges = [Double](repeating: 0, count: edgeBands.count)
            for phase in [CGFloat(0), AtticLayout.rowPitch / 3, AtticLayout.rowPitch * 2 / 3] {
                if phase > 0 { first = try capture(260 - phase); second = try capture(200 - phase) }
                for (index, band) in edgeBands.enumerated() {
                    faintEdges[index] = max(faintEdges[index], difference(top: band.0, bottom: band.1))
                    XCTAssertLessThan(difference(top: band.0, bottom: band.1, threshold: 0.35), 0.002,
                                      "\(state): edge \(index) dissolves ink at phase \(phase)")
                }
            }
            for (index, faint) in faintEdges.enumerated() {
                XCTAssertGreaterThan(faint, 0.0005, "\(state): faint moving ink survives at edge \(index), rather than clipping")
            }
            if negativeControl {
                // Negative control: the same bands clipped (covered by an
                // opaque view) fail both lower bounds, so they can fail.
                let covers = [(CGFloat(0), labelsBottom), (bottom, hosted.height)].map { band -> NSView in
                    let cover = OpaqueCover(frame: NSRect(x: 0, y: content.isFlipped ? band.0 : hosted.height - band.1,
                                                          width: content.bounds.width, height: band.1 - band.0))
                    content.addSubview(cover, positioned: .above, relativeTo: nil)
                    return cover
                }
                defer { covers.forEach { $0.removeFromSuperview() } }
                first = try capture(260)
                second = try capture(200)
                XCTAssertLessThan(difference(top: glassTop, bottom: tabsTop - AtticScrollUnderFade.textRamp, threshold: 0.35), 0.002, "\(state): clipping fails the readable-glass oracle")
                XCTAssertLessThan(difference(top: bottom, bottom: glassBottom, threshold: 0.35), 0.002, "\(state): clipping fails the readable-bottom oracle")
                XCTAssertLessThan(difference(top: tabsTop, bottom: labelsBottom), 0.0005, "\(state): clipping fails the faint-label oracle")
                XCTAssertLessThan(difference(top: 0, bottom: glassTop / 4), 0.0005, "\(state): clipping fails the faint-top-edge oracle")
                XCTAssertLessThan(difference(top: hosted.height - (hosted.height - glassBottom) / 4,
                                             bottom: hosted.height), 0.0005, "\(state): clipping fails the faint-bottom-edge oracle")
            }
            XCTAssertTrue(ScrollEdgeTests.pockets(in: list).isEmpty, "\(state): no native edge")
            XCTAssertEqual(frame(), resting, "\(state): controls change the mask, not the viewport")
        }
        try assertClear(bottom: hosted.height - idle, state: "idle", negativeControl: true)

        hosted.model.setSearchQuery(" ", for: .now)
        hosted.spin(0.8)
        XCTAssertTrue(hosted.searchFieldShown)
        try assertClear(bottom: hosted.height - idle, state: "Find")
        hosted.model.setSearchQuery("", for: .now)

        hosted.model.addBar = TaskAddBarText(text: "Pay rent tomorrow #home !!")
        hosted.spin(0.8)
        let strip = AtticPickerMetrics.stripToBar + AtticControlSize.smallHeight
        try assertClear(bottom: hosted.height - idle - strip, state: "metadata strip")
        hosted.model.addBarState.clearDraft()
        hosted.spin(0.8)
        try assertClear(bottom: hosted.height - idle, state: "strip cleared")

        let ids = hosted.model.rows(for: .now).prefix(2).map(\.id)
        hosted.model.selectOnly(ids[0])
        hosted.model.selectCopies(ids)
        hosted.spin(0.8)
        let bar = AtticSpacing.s8 + AtticControlSize.smallHeight + AtticControlSize.capsuleInset * 2
        try assertClear(bottom: hosted.height - idle - bar, state: "selection")
        hosted.model.clearSelection()
        hosted.spin(0.8)
        try assertClear(bottom: hosted.height - idle, state: "selection cleared")
        hosted.model.pasteOffer = TaskPasteOffer("Milk\nEggs\nBread")
        hosted.spin(0.8)
        try assertClear(bottom: hosted.height - idle - bar, state: "paste offer")
        hosted.model.dismissPasteOffer()
        hosted.spin(0.8)
        try assertClear(bottom: hosted.height - idle, state: "paste offer cleared")
        XCTAssertTrue(ScrollEdgeTests.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty)
    }

    // MARK: - P2-03: one Open Files command

    /// Open Files… from the row's right-click menu (the menu a secondary
    /// click on the row gets), from ⇧⌘I's menu (a real ⇧⌘I, the menu's own
    /// keys) and from ⌘Return: each opens the row's files, once.
    func testOpenFilesOpensFromTheRightClickMenuTheActionsMenuAndCommandReturn() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        var opened: [UUID] = []
        hosted.model.services.openPage = { opened.append($0) }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Book dentist" }?.id)
        // The right-click menu: the menu SwiftUI shows for a secondary click
        // on the row, its More › Open Files… chosen as AppKit chooses an
        // item. (Typing into a live context menu in the hosted window was
        // not dependable across macOS versions; `TasksPanelUITests` clicks
        // it in the real panel.)
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row)])
        let content = try XCTUnwrap(hosted.window.contentView)
        let point = CGPoint(x: frame.minX + 110, y: hosted.height - (frame.minY + 16))
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: hosted.window.windowNumber, context: nil,
                                                     eventNumber: 3, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(content.menu(for: press), "a secondary click on the row has the row's menu")
        menu.update()
        let more = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu, "with More")
        more.update()
        let open = try XCTUnwrap(more.items.firstIndex { $0.title.hasPrefix("Open Files") }, "holding Open Files…")
        more.performActionForItem(at: open)
        hosted.spin(0.5)
        XCTAssertEqual(opened, [row], "the right-click menu's Open Files… opens the row's files")

        // ⇧⌘I's menu: down to More (its eleventh item), into it, Return.
        opened = []
        try hosted.clickRow(row, tab: .now)
        let down: (characters: String, keyCode: UInt16) = ("\u{F701}", 125)
        let actionTimers = schedule(Array(repeating: down, count: 11) + [("\u{F703}", 124), ("\r", 36)], in: hosted)
        hosted.press("i", keyCode: 34, modifiers: [.command, .shift])
        hosted.spin(1)
        actionTimers.forEach { $0.invalidate() }
        XCTAssertEqual(opened, [row], "⇧⌘I's Open Files… opens them the same way")

        // ⌘Return on the selected row.
        opened = []
        try hosted.clickRow(row, tab: .now)
        hosted.press("\r", keyCode: 36, modifiers: .command)
        hosted.spin(0.3)
        XCTAssertEqual(opened, [row], "and ⌘Return")
        XCTAssertNil(hosted.model.editingTitleID, "⌘Return is not Return: no title is edited")
    }

    // MARK: - PR prep P2: a menu's choice is not a typing field's key

    private func keyEvent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                          type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                       characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: keyCode))
    }

    /// The rule: outside a menu choice, a key down while a field has the
    /// keyboard is the field's. A choice made in a menu is not, unless the
    /// key is that item's own key equivalent.
    func testOnlyAnItemsOwnKeyEquivalentBelongsToATypingField() throws {
        let plainReturn = try keyEvent("\r", keyCode: 36)
        let commandReturn = try keyEvent("\r", keyCode: 36, modifiers: .command)
        let openPage: KeyboardShortcut?? = .some(AtticTaskShortcut.openPage)
        XCTAssertTrue(AtticTextInput.owns(plainReturn, menuChoice: nil, hasKeyboard: { true }),
                      "a key outside any menu stays the typing field's")
        XCTAssertFalse(AtticTextInput.owns(plainReturn, menuChoice: openPage, hasKeyboard: { true }),
                       "the Return that chose Open Files… in its menu is the menu's")
        XCTAssertFalse(AtticTextInput.owns(commandReturn, menuChoice: .some(nil), hasKeyboard: { true }),
                       "an item without a key equivalent, chosen, is never a field's key")
        XCTAssertTrue(AtticTextInput.owns(commandReturn, menuChoice: openPage, hasKeyboard: { true }),
                      "the item's own ⌘Return while a field types stays the field's")
        XCTAssertFalse(AtticTextInput.owns(commandReturn, menuChoice: openPage, hasKeyboard: { false }))
        XCTAssertFalse(AtticTextInput.owns(try keyEvent("\r", keyCode: 36, type: .keyUp), menuChoice: nil, hasKeyboard: { true }))
        XCTAssertFalse(AtticTextInput.owns(nil, menuChoice: nil, hasKeyboard: { true }))
    }

    /// The on-screen failure (CU recheck 3): More › Open Files… chosen with
    /// Return in the right-click menu and in ⇧⌘I's menu, while something
    /// has the keyboard (on macOS 27 the context menu's own Ask Siri field;
    /// the composer under a menu), opened nothing, while ⌘Return did. Here
    /// the Return is the current event and an open pop-over has the
    /// keyboard; each menu's Open Files… must open the row's files, and a
    /// real ⌘Return key equivalent must still leave a typing field alone.
    func testOpenFilesChosenWithReturnOpensWhileSomethingHasTheKeyboard() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        var opened: [UUID] = []
        hosted.model.services.openPage = { opened.append($0) }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == "Book dentist" }?.id)

        let keyboardOwner = NSPanel(contentRect: CGRect(x: -6_000, y: -6_000, width: 40, height: 40),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        keyboardOwner.isReleasedWhenClosed = false
        keyboardOwner.orderFront(nil)
        AtticTextInput.notePopover(keyboardOwner)
        defer { keyboardOwner.orderOut(nil); keyboardOwner.close() }
        XCTAssertTrue(AtticTextInput.hasKeyboard, "an open pop-over has the keyboard")

        /// Makes `event` the app's current event without delivering it, as
        /// the key that chose a menu item is while the item's command runs.
        func makeCurrent(_ event: NSEvent) {
            NSApp.postEvent(event, atStart: true)
            _ = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
        }
        func chooseOpenFiles(in menu: NSMenu) throws {
            menu.update()
            let more = try XCTUnwrap(menu.items.first { $0.title == "More" }?.submenu, "with More")
            more.update()
            more.performActionForItem(at: try XCTUnwrap(more.items.firstIndex { $0.title.hasPrefix("Open Files") }))
            hosted.spin(0.3)
        }

        // The right-click menu.
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row)])
        let point = CGPoint(x: frame.minX + 110, y: hosted.height - (frame.minY + 16))
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: hosted.window.windowNumber, context: nil,
                                                     eventNumber: 3, clickCount: 1, pressure: 1))
        let contextMenu = try XCTUnwrap(hosted.window.contentView?.menu(for: press))
        makeCurrent(try keyEvent("\r", keyCode: 36))
        XCTAssertEqual(NSApp.currentEvent?.type, .keyDown, "the Return is the current event")
        try chooseOpenFiles(in: contextMenu)
        XCTAssertEqual(opened, [row], "the right-click menu's Open Files…, chosen with Return, opens the row's files")

        // ⇧⌘I's menu (the same commands as an NSMenu), on a Later row.
        opened = []
        hosted.go(to: .backlog)
        let later = try XCTUnwrap(hosted.model.rows(for: .backlog).first?.id, "Later lists a task")
        makeCurrent(try keyEvent("\r", keyCode: 36))
        try chooseOpenFiles(in: AtticNativeMenu.make(hosted.page.taskCommands(later, tab: .backlog)))
        XCTAssertEqual(opened, [later], "⇧⌘I's Open Files…, chosen with Return, opens them too")

        // The item's own ⌘Return while something types stays with it.
        opened = []
        makeCurrent(try keyEvent("\r", keyCode: 36, modifiers: .command))
        try chooseOpenFiles(in: AtticNativeMenu.make(hosted.page.taskCommands(later, tab: .backlog)))
        XCTAssertEqual(opened, [], "a typing field keeps its own ⌘Return")
    }

    func testOpenFilesPresentationWaitsForTheDefaultRunLoopMode() async throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first?.id)
        let command = try XCTUnwrap(AtticMenuCommand.command(for: AtticTaskShortcut.openPage,
                                                            in: hosted.page.taskCommands(row, tab: .now)))
        var openedMode: CFRunLoopMode?
        let opened = expectation(description: "Open Files is delivered")
        hosted.model.services.openPage = { _ in
            openedMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain())
            opened.fulfill()
        }
        // Enter the native tracking mode from a run-loop source, not from
        // a main-dispatch callback (which forbids nested queue servicing).
        let invoke = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                command.action()
                let endTracking = Timer(timeInterval: 0.1, repeats: false) { _ in CFRunLoopStop(CFRunLoopGetMain()) }
                RunLoop.main.add(endTracking, forMode: .eventTracking)
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(2))
                endTracking.invalidate()
            }
        }
        RunLoop.main.add(invoke, forMode: .default)
        await fulfillment(of: [opened], timeout: 3)
        invoke.invalidate()
        XCTAssertEqual(openedMode, CFRunLoopMode.defaultMode, "presentation belongs to the default loop, after native menu tracking")
    }

    /// Posts key presses while a menu tracks: each from a timer in the
    /// common modes (menu tracking is not the default mode), with an Esc at
    /// the end so a menu that ignores them cannot hang the run.
    private func schedule(_ keys: [(characters: String, keyCode: UInt16)], in hosted: Hosted) -> [Timer] {
        let window = hosted.window
        func post(_ characters: String, _ keyCode: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
            }
        }
        var when: TimeInterval = 0.8
        var timers: [Timer] = []
        for key in keys {
            let timer = Timer(timeInterval: when, repeats: false) { _ in MainActor.assumeIsolated { post(key.characters, key.keyCode) } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
            when += 0.2
        }
        let escape = Timer(timeInterval: when + 2, repeats: false) { _ in MainActor.assumeIsolated { post("\u{1B}", 53) } }
        RunLoop.main.add(escape, forMode: .common)
        timers.append(escape)
        return timers
    }

    // MARK: - P2-04: a visible keyboard focus at every Tab stop

    /// Tab through the page: every task row Tab reaches is drawn as the
    /// keyboard's row (its ring on the highlight's edge), and only rows of
    /// the page shown are reached. Neither held: a lazy list's cell read
    /// the page's focus state as it was when the list was built, so the row
    /// that had the keyboard drew no ring; and Tab went on into the rows of
    /// the pages kept built beside the shown one, which are hidden. (The
    /// window server draws the hosted list, which an in-process capture
    /// does not see change, so the cells' own record is read here; the
    /// pixels are `TasksPageUITests`'s.)
    ///
    /// A10: the page orders Tab itself (`TasksTabOrder`), so the order no
    /// longer passes through nothing before it wraps: after the add bar
    /// comes the first row again.
    func testEveryTabStopIsAVisibleRowOrAField() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        XCTAssertNotNil(hosted.model.pagerSwipe.span.warm, "the pages beside Now are kept built")
        let now = hosted.model.rows(for: .now).map(\.id)
        enum Stop: Equatable { case row(UUID), addBar, none }
        func stop() -> Stop {
            if let row = hosted.pointer.keyboardRow { return .row(row.id) }
            return hosted.focus.addBar ? .addBar : .none
        }
        func check(_ stop: Stop, _ stops: [Stop]) {
            guard case let .row(id) = stop else { return }
            XCTAssertEqual(hosted.pointer.keyboardRow?.tab, .now, "Tab stays on the page shown (\(stops))")
            XCTAssertEqual(hosted.pointer.drawnFocus.map(\.id), [id], "only the row Tab reached is drawn with the ring (\(stops))")
            XCTAssertTrue(hosted.model.selection.isEmpty, "Tab selects nothing: the ring alone shows the keyboard")
        }
        var forward: [Stop] = []
        for _ in 0..<(now.count + 3) {
            hosted.press("\t", keyCode: 48)
            hosted.spin(0.2)
            forward.append(stop())
            check(forward.last!, forward)
        }
        XCTAssertEqual(forward, now.map(Stop.row) + [.addBar, .row(now[0]), .row(now[1])],
                       "Tab: Now's rows, the add bar, then round again (\(forward))")

        var backward: [Stop] = []
        for _ in 0..<4 {
            hosted.press("\u{19}", keyCode: 48, modifiers: .shift)
            hosted.spin(0.2)
            backward.append(stop())
            check(backward.last!, backward)
        }
        XCTAssertEqual(backward, [.row(now[0]), .addBar, .row(now[now.count - 1]), .row(now[now.count - 2])],
                       "Shift-Tab retraces it, never into a hidden page (\(backward))")

        // Return edits the row that shows the keyboard.
        hosted.press("\r", keyCode: 36)
        XCTAssertEqual(hosted.model.editingTitleID, now[now.count - 2], "Return edits the row that shows the keyboard")
    }

    /// A8 P2-A8-1 (A10): in the combined app Tab reached rows out of view
    /// (`R12` while rows 1–7 showed), with no ring and no scroll, and a
    /// filtered list's cycle had blank stops and skipped Find. In a list
    /// taller than the viewport, and in a filtered one: every stop is Find,
    /// a row or the add bar, each row the keyboard reaches is drawn with
    /// its ring inside the part of the list nothing covers, and Tab goes
    /// round without a blank stop. Run on a panel whose key loop is
    /// AppKit's, as the combined app's is (the import freeze's fix).
    func testTabKeepsEveryRowItReachesInViewInALongAndAFilteredList() throws {
        let hosted = try Hosted(height: 520, addBarFocused: true, long: true)
        defer { hosted.close() }
        hosted.window.autorecalculatesKeyViewLoop = true
        hosted.spin(1)
        enum Stop: Equatable { case find, row(UUID), addBar, none }
        func stop() -> Stop {
            if let row = hosted.pointer.keyboardRow { return .row(row.id) }
            if hosted.focus.addBar { return .addBar }
            if AtticTextInput.hasKeyboard { return .find }
            return .none
        }
        // The add bar's top: a row below it is under the controls.
        let clearBottom = hosted.height - AtticControlSize.addBarHeight - AtticSpacing.panelMargin
        func checkInView(_ stop: Stop, _ trail: [Stop]) {
            guard case let .row(id) = stop else { return }
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosted.pointer.drawnFocus.map(\.id), [id], "the row Tab reached draws the ring (\(trail.count))")
            guard let frame = hosted.pointer.frames[TasksRowID(tab: .now, id: id)] else {
                return XCTFail("the row Tab reached is laid out (\(trail.count))")
            }
            XCTAssertGreaterThanOrEqual(frame.minY, 0, "row \(trail.count) is not above the viewport (\(frame))")
            XCTAssertLessThanOrEqual(frame.maxY, clearBottom + 1, "row \(trail.count) is not under the add bar (\(frame))")
        }
        func walk(_ count: Int, shift: Bool = false) -> [Stop] {
            var trail: [Stop] = []
            for _ in 0..<count {
                if shift { hosted.press("\u{19}", keyCode: 48, modifiers: .shift) } else { hosted.press("\t", keyCode: 48) }
                hosted.spin(0.3)
                trail.append(stop())
                checkInView(trail.last!, trail)
            }
            return trail
        }

        // The whole list, taller than the viewport, and round again.
        XCTAssertTrue(hosted.model.expanded.isEmpty, "no quick look open: rows only")
        let now = hosted.model.rows(for: .now).map(\.id)
        let last = try XCTUnwrap(now.last)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let lastFrame = hosted.pointer.frames[TasksRowID(tab: .now, id: last)]
        XCTAssertTrue(lastFrame.map { $0.minY > clearBottom } ?? true, "the list is taller than the viewport")
        let forward = walk(now.count + 2)
        XCTAssertEqual(forward, now.map(Stop.row) + [.addBar, .row(now[0])], "Tab: every row in order, the add bar, round again")
        let backward = walk(2, shift: true)
        XCTAssertEqual(backward, [.addBar, .row(last)], "Shift-Tab from the first row: the add bar, then the last row, in view")

        // Filtered: Find, the matches, the add bar, round again; no blank.
        hosted.model.setSearchQuery("Errand", for: .now)
        hosted.spin(0.8)
        let matches = hosted.model.rows(for: .now).map(\.id)
        XCTAssertGreaterThan(matches.count, 8, "enough matches to scroll")
        XCTAssertLessThan(matches.count, now.count)
        let cycle: [Stop] = [.find] + matches.map(Stop.row) + [.addBar]
        let filtered = walk(cycle.count + 2)
        XCTAssertFalse(filtered.contains(.none), "no blank stop (\(filtered))")
        // Wherever the keyboard was when the list narrowed, each Tab takes
        // the next stop of Find, the matches in order, the add bar.
        for (stop, next) in zip(filtered, filtered.dropFirst()) {
            guard let index = cycle.firstIndex(of: stop) else { XCTFail("\(stop) is not a stop of the filtered page"); continue }
            XCTAssertEqual(next, cycle[(index + 1) % cycle.count], "Tab after \(stop)")
        }
        XCTAssertTrue(filtered.contains(.find), "Find is on the way")
    }

    // MARK: - P3-01: the strip's values in full

    /// "Tomorrow", "#qatest" and "!!" together, in the strip of the review's
    /// panel (276 pt): at the usual padding they did not fit ("Tomorr…",
    /// "#q…"); with the inner gaps closed up they do. On the default panel
    /// (300 pt) the usual padding stays.
    func testTheStripClosesUpBeforeItCutsCommonValuesShort() {
        typealias Strip = AtticComposerStrip<EmptyView, EmptyView, EmptyView>
        let faces: [(title: String, value: AtticStripValue?)] = [
            ("Date", AtticStripValue(text: "Tomorrow", spoken: "Tomorrow")),
            ("Tag", TasksComposerValues.tags(["qatest"])),
            ("Priority", TasksComposerValues.priority(.high)),
        ]
        let usual = Strip.usualWidth(faces)
        let saved = 3 * (AtticSmallControlMetrics.iconLabelGap - AtticPickerMetrics.stripCompactIconGap
            + AtticPickerMetrics.stripClearGap - AtticPickerMetrics.stripCompactClearGap
            + AtticPickerMetrics.stripValueTrailing - AtticPickerMetrics.stripCompactValueTrailing)
        XCTAssertTrue(Strip.needsCompactGaps(faces, available: 276), "the review's strip is short of room (\(usual))")
        XCTAssertLessThanOrEqual(usual - saved, 276, "closed up, all three values fit in full")
        XCTAssertFalse(Strip.needsCompactGaps(faces, available: 300), "the default panel keeps the usual padding")
        XCTAssertFalse(Strip.needsCompactGaps(faces, available: .infinity), "before it is laid out")
        XCTAssertEqual(TasksComposerValues.tags(["qatest", "work"])?.full, "#qatest #work", "the tooltip names every tag")
    }

    /// CU review P3 (combined app): "Tomorrow" and a short tag with
    /// Priority unset. The empty Priority button gave up nothing, so the
    /// tag was cut to "#c…". Now an unset button shows its icon alone
    /// (Priority first) before any value is cut short or closed up, and it
    /// keeps its name whenever the strip fits.
    func testAnUnsetButtonGivesUpItsNameBeforeAValueIsCutShort() throws {
        typealias Strip = AtticComposerStrip<EmptyView, EmptyView, EmptyView>
        let tomorrow = AtticStripValue(text: "Tomorrow", spoken: "Tomorrow")
        for tag in ["cuqa", "qatest"] {
            let faces: [(title: String, value: AtticStripValue?)] = [
                ("Date", tomorrow), ("Tag", TasksComposerValues.tags([tag])), ("Priority", nil),
            ]
            for available: CGFloat in [276, 300] {
                let full = Strip.usualWidth(faces)
                let iconOnly = Strip.iconOnlyButtons(faces, available: available)
                if full > available {
                    XCTAssertEqual(iconOnly, [2], "#\(tag) at \(available): Priority shows its icon alone (\(full))")
                    XCTAssertLessThanOrEqual(Strip.usualWidth(faces, iconOnly: iconOnly), available,
                                             "#\(tag) at \(available): then the values fit in full")
                    XCTAssertFalse(Strip.needsCompactGaps(faces, available: available, iconOnly: iconOnly))
                } else {
                    XCTAssertEqual(iconOnly, [], "it fits: every name stays")
                }
            }
        }
        // The capture's case does need it at the review's width.
        let capture: [(title: String, value: AtticStripValue?)] = [("Date", tomorrow), ("Tag", TasksComposerValues.tags(["cuqa"])), ("Priority", nil)]
        XCTAssertGreaterThan(Strip.usualWidth(capture), 276, "the names did not fit")
        // Unset buttons only, and only with a value to make room for.
        let empty: [(title: String, value: AtticStripValue?)] = [("Date", nil), ("Tag", nil), ("Priority", nil)]
        XCTAssertEqual(Strip.iconOnlyButtons(empty, available: 100), [])
        let set: [(title: String, value: AtticStripValue?)] = [("Date", tomorrow), ("Tag", TasksComposerValues.tags(["a-much-longer-tag"])),
                                                               ("Priority", TasksComposerValues.priority(.high))]
        XCTAssertEqual(Strip.iconOnlyButtons(set, available: 200), [], "a set button keeps its value")
        // Short of room still, Tag's empty name goes next, never Date's value.
        let tagless: [(title: String, value: AtticStripValue?)] = [("Date", AtticStripValue(text: "Wednesday, 15 October", spoken: "")), ("Tag", nil), ("Priority", nil)]
        XCTAssertEqual(Strip.iconOnlyButtons(tagless, available: 200), [1, 2])
    }

    // MARK: - Code review: the pager's test-only settle

    func testThePagerSettleOverrideNeedsAUITestPreviewAndASaneDuration() {
        func resolve(_ value: String, testing: Bool = true, identity: String? = "com.taha.Attic.preview.glass") -> Double? {
            var environment = ["ATTIC_UI_TEST_PAGER_SETTLE": value]
            if testing { environment["ATTIC_UI_TESTING"] = "1" }
            return TasksPagerMotion.resolveSettleOverride(environment: environment, bundleIdentifier: identity)
        }
        XCTAssertEqual(resolve("1.5"), 1.5, "a UI-tested preview may slow the settle")
        XCTAssertNil(resolve("1.5", testing: false), "not without UI testing")
        for identity in ["com.taha.Attic", "com.taha.Attic.preview.", "com.taha.AtticTests", "com.taha.Attic.UnitTestHost"] {
            XCTAssertNil(resolve("1.5", identity: identity), "\(identity) ignores it")
        }
        XCTAssertNil(resolve("1.5", identity: nil))
        for bad in ["nan", "inf", "-1", "0", "0.01", "60", "fast", ""] {
            XCTAssertNil(resolve(bad), "\(bad) is not a supported duration")
        }
        XCTAssertEqual(resolve("0.05"), 0.05)
        XCTAssertEqual(resolve("10"), 10)
    }
}

/// A10: the Tasks page's own Tab order and Move to Task's focus return,
/// as data (the hosted walks are `DeepReviewFixTests`').
final class TasksTabOrderTests: XCTestCase {
    func testTheOrderIsFindRowsWithTheirOpenSubtasksTheAddBarThenTheStrip() {
        let (a, b, c, s1, s2) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let stops = TasksTabOrder.stops(find: true, rows: [(a, []), (b, [s1, s2]), (c, [])], strip: true)
        XCTAssertEqual(stops, [.find, .row(a), .row(b), .subtask(s1), .subtask(s2), .row(c), .addBar]
                       + AtticStripFocusID.all.map(TasksTabStop.strip))
        XCTAssertEqual(TasksTabOrder.stops(find: false, rows: [(a, [])], strip: false), [.row(a), .addBar],
                       "no Find while it is hidden, no strip without a draft or keyboard navigation")
        XCTAssertEqual(TasksTabOrder.next(after: nil, in: stops, forward: true), .find, "from nowhere: the first stop")
        XCTAssertEqual(TasksTabOrder.next(after: nil, in: stops, forward: false), stops.last)
        XCTAssertEqual(TasksTabOrder.next(after: .row(b), in: stops, forward: true), .subtask(s1))
        XCTAssertEqual(TasksTabOrder.next(after: stops.last, in: stops, forward: true), .find, "round the end")
        XCTAssertEqual(TasksTabOrder.next(after: .find, in: stops, forward: false), stops.last)
        XCTAssertEqual(TasksTabOrder.next(after: .row(UUID()), in: stops, forward: true), .find, "a stop no longer drawn: start again")
        XCTAssertNil(TasksTabOrder.next(after: nil, in: [], forward: true))
        XCTAssertEqual(TasksTabOrder.parent(of: s2, in: stops), b)
        XCTAssertTrue(TasksTabOrder.isListNeighbour(.row(a), of: .row(b), in: stops))
        XCTAssertFalse(TasksTabOrder.isListNeighbour(.addBar, of: .row(c), in: stops), "from a field the list goes to the row first")
        XCTAssertFalse(TasksTabOrder.isListNeighbour(.row(c), of: .row(a), in: stops), "nor round the end")
    }

    /// A8 P3-A8-1: Esc (or a click outside) closing Move to Task… gives
    /// the keyboard back to the subtask's line; other pickers keep theirs.
    func testClosingMoveToTaskGivesTheKeyboardBackToTheSubtask() {
        let (row, subtask) = (UUID(), UUID())
        let move = TasksMetaPopover(id: row, tab: .now, kind: .move, targets: [subtask])
        XCTAssertEqual(TasksPage.subtaskToRefocus(closed: move, now: nil), subtask)
        XCTAssertNil(TasksPage.subtaskToRefocus(closed: move, now: move), "still open")
        XCTAssertNil(TasksPage.subtaskToRefocus(closed: TasksMetaPopover(id: row, tab: .now, kind: .date, targets: [row]), now: nil))
        XCTAssertNil(TasksPage.subtaskToRefocus(closed: nil, now: nil))
    }
}

/// A white view that draws itself (a capture by `cacheDisplay` ignores a
/// layer's background), laid over a band to clip what is under it.
final class OpaqueCover: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}
