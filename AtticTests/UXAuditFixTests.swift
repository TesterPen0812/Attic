import AppKit
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class UXAuditFixTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    func testAuditB2WidthStopsAtReadingWidthOnLoadAndEdit() throws {
        let suite = "AuditB2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1900.0, forKey: "panelContentSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(PanelContentSize.max, Double(PanelPageLayout.readingWidth))
        XCTAssertEqual(settings.panelContentSize, 600)
        settings.panelContentSize = 950
        XCTAssertEqual(settings.panelContentSize, 600)
        settings.panelContentSize = 420
        XCTAssertEqual(settings.panelContentSize, 420)
        XCTAssertEqual(AppSettings(defaults: defaults).panelContentSize, 420)
    }

    func testAuditB3EmptyTasksAndSettingsHaveNoInstructionalHelpers() throws {
        for tab in TasksTab.allCases {
            XCTAssertEqual(TasksPanelDesign.empty(tab: tab, query: "", filtered: false).body, "")
        }
        let suite = "AuditB3.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func words(_ root: AnyObject) -> String {
            var result: [String] = []
            func walk(_ node: AnyObject, depth: Int) {
                guard depth < 50 else { return }
                if let object = node as? NSObject {
                    for key in ["accessibilityLabel", "accessibilityValue", "accessibilityHelp"] {
                        let selector = NSSelectorFromString(key)
                        if object.responds(to: selector), let text = object.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
                    }
                }
                for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth: depth + 1) }
            }
            walk(root, depth: 0)
            return result.joined(separator: " ")
        }
        withHost(GeneralSettingsView(settings: settings, loginItemService: LoginItemService(),
            globalHotKey: GlobalHotKey(combination: .newTask)), size: CGSize(width: 400, height: 1600)) { host in
            let text = words(host)
            XCTAssertFalse(text.contains("light tap on the trackpad"))
            XCTAssertFalse(text.contains("Lively springs"))
        }
        withHost(PanelSettingsView(settings: settings), size: CGSize(width: 400, height: 1600)) { host in
            let text = words(host)
            XCTAssertFalse(text.contains("swipe two fingers"))
            XCTAssertFalse(text.contains("drag the panel's inward edge"))
        }
    }

    func testAuditB5RelaunchRestoresTheLastPageAndTaskScroll() throws {
        let suite = "AuditB5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PanelUIState(resumeDefaults: defaults)
        first.selectSection(.calendar)
        XCTAssertEqual(PanelUIState(resumeDefaults: defaults).selectedSection, .calendar)
        let memory = TasksPageMemory(defaults: defaults)
        let library = AtticLibrary(tasks: try makeTestStore())
        let tasks = TasksPageModel(library: library, memory: memory)
        tasks.scrollOffsets[.now] = 284
        tasks.scrollOffsets[.backlog] = 123
        let restored = TasksPageModel(library: library, memory: memory)
        XCTAssertEqual(restored.scrollOffsets[.now], 284)
        XCTAssertEqual(restored.scrollOffsets[.backlog], 123)
        // Explicit capture continues to override the resumed page.
        let reopened = PanelUIState(resumeDefaults: defaults)
        reopened.selectSection(.tasks)
        XCTAssertEqual(reopened.selectedSection, .tasks)
    }

    func testAuditB5DrawRestoresTheCanvasAndViewportAcrossModels() throws {
        let suite = "AuditB5Draw.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DrawInMemoryStore()
        let first = DrawPageModel(store: store, resumeDefaults: defaults)
        first.start()
        let wanted = try XCTUnwrap(first.canvasID)
        let viewport = DrawViewport(x: -120, y: 87, zoom: 1.75)
        first.setViewport(viewport, byUser: true)
        first.flushViewportMemory()
        _ = store.create(name: "Another canvas")
        let restored = DrawPageModel(store: store, resumeDefaults: defaults)
        restored.start()
        XCTAssertEqual(restored.canvasID, wanted)
        XCTAssertEqual(restored.viewport, viewport)
    }

    func testAuditB5NativeScrollMemoryRestoresAndClampsAfterRebuilding() throws {
        let suite = "AuditB5Scroll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func mount(height: CGFloat) -> (NSWindow, NSScrollView) {
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            let doc = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: height))
            scroll.documentView = doc
            doc.addSubview(PanelResumeScrollKeeper.KeeperView(defaults: defaults, key: "audit"))
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            scroll.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return (window, scroll)
        }
        let (first, scroll) = mount(height: 1200)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 284))
        scroll.reflectScrolledClipView(scroll.contentView)
        first.close()
        let (second, restored) = mount(height: 1200)
        XCTAssertEqual(restored.contentView.bounds.minY, 284, accuracy: 0.5)
        second.close()
        let (third, shorter) = mount(height: 300)
        XCTAssertLessThanOrEqual(shorter.contentView.bounds.minY, 100)
        third.close()
    }

    func testAuditB5PendingScrollWaitsForContentAndYieldsToNavigation() throws {
        let suite = "AuditB5Loading.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(700.0, forKey: "AtticPanel.scroll.audit")
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let doc = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        scroll.documentView = doc
        let keeper = PanelResumeScrollKeeper.KeeperView(defaults: defaults, key: "audit", ready: false, navigationID: "day1")
        doc.addSubview(keeper)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(defaults.double(forKey: "AtticPanel.scroll.audit"), 700)
        doc.setFrameSize(CGSize(width: 200, height: 1400))
        keeper.update(ready: true, navigationID: "day1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.minY, 700, accuracy: 0.5)
        // An explicit navigation cancels a pending restore before its layout turn.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 0))
        keeper.update(ready: false, navigationID: "day2")
        keeper.update(ready: true, navigationID: "day2")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    func testAuditB5CalendarResumesOnlyAValidDay() throws {
        let suite = "AuditB5Calendar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeTestStore()
        let wanted = try XCTUnwrap(DueDay(year: 2027, month: 4, day: 19))
        let first = CalendarPageModel(store: store, source: CalendarEventSourceStub(), resumeDefaults: defaults)
        first.select(wanted)
        XCTAssertEqual(CalendarPageModel(store: store, source: CalendarEventSourceStub(), resumeDefaults: defaults).snapshot.selected, wanted)
        for bad in [["year": Int.max, "month": 1, "day": 1], ["year": 2027, "month": 2, "day": 31]] {
            defaults.set(try JSONSerialization.data(withJSONObject: bad), forKey: "AtticCalendar.selectedDay")
            let restored = CalendarPageModel(store: store, source: CalendarEventSourceStub(), resumeDefaults: defaults)
            XCTAssertEqual(restored.snapshot.selected, restored.snapshot.today)
        }
    }

    func testAuditB5DrawDefersViewportSerializationUntilTheGestureSettles() throws {
        let suite = "AuditB5WriteBound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DrawPageModel(store: DrawInMemoryStore(), resumeDefaults: defaults)
        model.start()
        model.flushViewportMemory()
        let before = defaults.data(forKey: "AtticDraw.viewports")
        for i in 0..<400 { model.setViewport(DrawViewport(x: CGFloat(i), y: 0, zoom: 1.5), byUser: true) }
        XCTAssertEqual(defaults.data(forKey: "AtticDraw.viewports"), before)
        model.flushViewportMemory()
        XCTAssertNotEqual(defaults.data(forKey: "AtticDraw.viewports"), before)
    }

    func testAuditA11CanvasMenuIsPreparedWithoutTakingFocusOrAccessibility() throws {
        let model = DrawPageModel(store: DrawInMemoryStore())
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 460)
        let toasts = PanelToastCenter()
        try withHost(DrawPageHost(model: model, uiState: state,
            layout: PanelPageLayout(cornerSize: 52, panelSize: size)).environment(\.atticPanelToasts, toasts)) { host in
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            XCTAssertTrue(model.library.toasts === toasts, "the closed menu has mounted and prepared its hierarchy")
            XCTAssertNil(find("draw-library-menu", in: host), "the prepared menu is absent from VoiceOver until opened")
            model.openFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(fields(host).first { $0.accessibilityIdentifier() == "draw-title-filter" }?.isEnabled == true)
            XCTAssertNotNil(find("draw-library-menu", in: host))
        }
    }

    func testAuditA11TitleFilterRetainsPreparedInputWithoutTakingTheKeyboard() throws {
        let model = DrawPageModel(store: DrawInMemoryStore())
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 460)
        let wasActive = NSApp.isActive
        try withHost(DrawPageHost(model: model, uiState: state,
            layout: PanelPageLayout(cornerSize: 52, panelSize: size))) { host in
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let field = try XCTUnwrap(fields(host).first { $0.accessibilityIdentifier() == "draw-title-filter" })
            let window = try XCTUnwrap(host.window)
            let editor = try XCTUnwrap(window.fieldEditor(false, for: field))
            XCTAssertFalse(field.isEnabled)
            XCTAssertFalse(window.firstResponder === field || window.firstResponder === editor)
            XCTAssertEqual(NSApp.isActive, wasActive)
            XCTAssertNil(find("draw-title-filter", in: host))
            model.openFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(fields(host).first { $0.accessibilityIdentifier() == "draw-title-filter" } === field)
            XCTAssertTrue(field.isEnabled)
            XCTAssertTrue(window.fieldEditor(false, for: field) === editor)
            model.closeFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(fields(host).first { $0.accessibilityIdentifier() == "draw-title-filter" } === field)
            XCTAssertFalse(field.isEnabled)
            XCTAssertNil(find("draw-title-filter", in: host))
            model.newCanvas(name: "Another canvas")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(field.placeholderString, model.canvasName)
        }
    }

    func testAuditB7IdenticalHistoryCannotRestoreButDifferentWritingCan() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "AuditB7")))
        let id = UUID()
        let document = NoteDocument(blocks: [.text("Title"), .text("Writing")])
        let version = NoteVersion(noteID: id, createdAt: Date(), reason: .pause,
            content: try NoteContentCodec.encode(document), contentFormat: NoteDocument.currentFormat,
            title: "Title", body: "Writing", attachmentIDs: [], sourceRevisionID: nil)
        for identical in [true, false] {
            let current = identical ? document : NoteDocument(blocks: [.text("Title"), .text("Changed writing")])
            let browser = NoteHistoryBrowser(noteID: id, current: current, currentRevision: nil, entries: [NoteHistoryEntry(version)])
            try withHost(NoteHistoryPage(controller: controller, browser: browser,
                layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 320, height: 460)))) { host in
                let restore = try XCTUnwrap(find("notes-history-restore", in: host))
                XCTAssertEqual(restore.isAccessibilityEnabled?(), !identical)
            }
        }
    }

    func testAuditB7CalendarSearchLabelsADifferentYear() async throws {
        let calendar = CalendarMonthMath.calendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let then = try XCTUnwrap(calendar.date(from: DateComponents(year: 1992, month: 6, day: 17, hour: 12)))
        let event = CalendarEvent(id: "far", title: "Target event", start: then, end: then.addingTimeInterval(3600),
            isAllDay: false, location: nil, calendarTitle: "Test", colour: .init(red: 0.2, green: 0.4, blue: 0.8))
        let model = CalendarPageModel(store: try makeTestStore(), source: CalendarEventSourceStub(events: [event]), calendar: calendar, now: { now })
        model.setQuery("Target")
        try await Task.sleep(for: .milliseconds(200))
        await model.waitForEventReadsForTesting()
        XCTAssertEqual(model.snapshot.groups.first?.day.year, 1992)
        try withHost(CalendarPage(model: model, layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 320, height: 460)),
            taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }), onNewTask: { _ in })) { host in
            let year = try XCTUnwrap(find("calendar-search-year-1992", in: host))
            let object = try XCTUnwrap(year as? NSObject)
            let selector = NSSelectorFromString("accessibilityValue")
            XCTAssertTrue(object.responds(to: selector))
            XCTAssertEqual(object.perform(selector)?.takeUnretainedValue() as? String, "1992")
        }
    }

    func testAcceptedD4TheTitleCapsuleFiltersAndTheMenuHasNoSearchRow() throws {
        let model = DrawPageModel(store: DrawInMemoryStore())
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        try withHost(DrawPageHost(model: model, uiState: state, layout: layout)) { host in
            model.openFilter()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let native = fields(host)
            let title = try XCTUnwrap(native.first { $0.accessibilityIdentifier() == "draw-title-filter" })
            XCTAssertNil(native.first { $0.accessibilityIdentifier() == "draw-library-search" })
            let frame = title.convert(title.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(frame.minY, size.height - layout.headerBottom)
            XCTAssertLessThanOrEqual(frame.maxY, size.height)
            XCTAssertTrue(title.isEnabled)
        }
    }

    func testAcceptedShapesReviewTrackUsesItsSeventeenPointOuterCorner() {
        let control = NoteHistoryVersionSwitch(choices: [(false, "Current"), (true, "Proposed")], selection: .constant(false),
            trackHeight: AtticRadius.reviewBar * 2, trackInset: 7)
        let host = NSHostingView(rootView: control.atticDesign(AtticDesignContext(mode: .light)).frame(width: 280))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 34, accuracy: 0.5, "20 pt controls plus 7 pt padding on each side")
        XCTAssertEqual(AtticRadius.reviewBar - 7, AtticRadius.noteBlock)
    }

    func testAcceptedShapesPopoverHighlightHasTheControlCurve() throws {
        var design = AtticDesignContext(mode: .light)
        design.reduceMotion = true
        design.reduceTransparency = false
        let actual = try shapeBitmap(AtticPopoverRow(systemName: nil, title: "", isHighlighted: true, action: {})
            .frame(width: 120).atticDesign(design))
        let expected = try shapeBitmap(Squircle(cornerRadius: 14, exponent: AtticShape.controlExponent)
            .fill(design.tokens.selected.color).frame(width: 120, height: 28))
        assertCornerAlpha(actual, expected, extent: 14)
    }

    func testAcceptedShapesUnavailableImageHasTheSmallObjectContour() throws {
        var design = AtticDesignContext(mode: .light)
        design.reduceMotion = true
        design.reduceTransparency = false
        let actual = NSBitmapImageRep(data: try XCTUnwrap(NoteObjectRenderer(design: design, scale: 4)
            .placeholder(size: CGSize(width: 40, height: 28), text: "").tiffRepresentation))
        let expected = try shapeBitmap(Squircle(cornerRadius: 6, exponent: AtticShape.surfaceExponent)
            .fill(design.tokens.tagFill.color).frame(width: 40, height: 28))
        assertCornerAlpha(try XCTUnwrap(actual), expected, extent: 9)
    }

    func testAcceptedShapesNativeTableGripsHaveTheControlCurve() throws {
        for axis in [AtticNoteTableGripView.Axis.row, .column] {
            let grip = AtticNoteTableGripView(axis: axis)
            grip.design.reduceMotion = true
            grip.design.reduceTransparency = false
            grip.frame = CGRect(origin: .zero, size: grip.drawnSize)
            let scale: CGFloat = 8
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(grip.bounds.width * scale), pixelsHigh: Int(grip.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            grip.draw(grip.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let expected = try shapeBitmap(Squircle(cornerRadius: 2.5, exponent: AtticShape.controlExponent)
                .fill(grip.tokens.tableGripFill.color).frame(width: grip.bounds.width, height: grip.bounds.height), scale: scale)
            // Only the outermost corner: the three circular dots are document ink.
            assertCornerAlpha(bitmap, expected, extent: 0.75, scale: scale)
        }
    }

    func testAcceptedShapesNativeTableAddButtonsAreWholeControls() throws {
        let button = AtticNoteTableAddChipView(frame: .zero)
        button.design.reduceMotion = true
        button.design.reduceTransparency = false
        button.frame = CGRect(origin: .zero, size: button.drawnSize)
        let scale: CGFloat = 4
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(button.bounds.width * scale), pixelsHigh: Int(button.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        button.draw(button.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let expected = try shapeBitmap(Squircle(cornerRadius: button.bounds.height / 2, exponent: AtticShape.controlExponent)
            .fill(button.tokens.tableAddFill.color).frame(width: button.bounds.width, height: button.bounds.height))
        assertCornerAlpha(bitmap, expected, extent: 2.5)
    }

    func testAcceptedShapesDetailCountHoverKeepsItsIconContrast() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            var context = AtticDesignContext(mode: mode, surface: .solid)
            context.reduceMotion = true
            context.reduceTransparency = false
            let report = AtticAppearanceCheck.run(families: [.taskRows], contexts: [context], scale: 2)
            XCTAssertGreaterThan(report.glyphsMeasured, 0)
            let collector = AtticProbeCollector()
            XCTAssertNotNil(AtticAppearanceCheck.render(family: .taskRows, context: context,
                backdrop: .desktop(.midGrey), collector: collector, scale: 2))
            let icon = try XCTUnwrap(collector.all.first { probe in
                guard AtticAppearanceCheck.displayName(probe.specimen) == "Hover",
                      case let .icon(name) = probe.kind else { return false }
                return name == "checkmark.square"
            })
            let ink = try XCTUnwrap(icon.foreground)
            let tokens = context.tokens
            let hoveredBackground = tokens.chipHover.over(tokens.hover.over(TasksPanelDesign.reference(tokens)))
            XCTAssertGreaterThanOrEqual(ink.contrast(on: hoveredBackground), 3,
                "the drawn icon must keep its floor over both the row and its own hover fill")
            let problems = report.failures.filter { failure, _ in
                failure.family == AtticGalleryFamily.taskRows.title && failure.specimen == "Hover"
                    && failure.detail.hasPrefix("checkmark.square")
                    && (failure.kind == .contrast || failure.kind == .glyphContrast)
            }
            XCTAssertTrue(problems.isEmpty, problems.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        }
    }

    private func shapeBitmap<V: View>(_ view: V, scale: CGFloat = 4) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func assertCornerAlpha(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep,
                                   extent: CGFloat, scale: CGFloat = 4,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.pixelsWide, expected.pixelsWide, file: file, line: line)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh, file: file, line: line)
        var difference: CGFloat = 0
        let count = Int(extent * scale)
        for y in 0..<count {
            for x in 0..<count {
                difference += abs((actual.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                    - (expected.colorAt(x: x, y: y)?.alphaComponent ?? 0))
            }
        }
        XCTAssertLessThan(difference / CGFloat(count * count), 0.004,
            "visible contour must follow the accepted shape", file: file, line: line)
    }

    private func find(_ id: String, in element: AnyObject, depth: Int = 0) -> AnyObject? {
        guard depth < 50 else { return nil }
        if (element.accessibilityIdentifier?() ?? nil) == id { return element }
        for child in (element.accessibilityChildren?() ?? nil) ?? [] {
            if let found = find(id, in: child as AnyObject, depth: depth + 1) { return found }
        }
        return nil
    }

    func testAuditA8HistoryRestoreClearsTheSharedPlusAt320Points() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousAX, forAttribute: enhanced) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "AuditHistory")))
        await controller.startAndWait()
        let engine = try XCTUnwrap(controller.active?.engine)
        engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Title\nWriting"), name: "Typing")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        let browser = try XCTUnwrap(controller.historyBrowser)
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let host = NSHostingView(rootView: NoteHistoryPage(controller: controller, browser: browser, layout: layout)
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { controller.closeHistory(); window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let restore = try XCTUnwrap(find("notes-history-restore", in: host))
        let frame = restore.accessibilityFrame?() ?? .zero
        let plusLeft = window.convertToScreen(CGRect(x: size.width - PanelSharedBottomBar.plusInsets(layout: layout).trailing
            - AtticControlSize.panelButton.height, y: 0, width: 0, height: 0)).minX
        XCTAssertLessThanOrEqual(frame.maxX + 6, plusLeft, "Restore and the shared + have separate space")
    }

    func testAuditA3FailureNoticeFitsTheWholeMessage() {
        let message = "This item changed elsewhere. Your edit was not saved. Check the latest version before trying again."
        let host = NSHostingView(rootView: AtticNotice(message: message, actionTitle: "Retry", onAction: {}, onDismiss: {})
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: 260))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 60, "a narrow failure notice has room for the complete sentence")
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func testAuditA5SearchAndTagsTakeTheKeyboardFromTheBoard() throws {
        try requireKeyWindowTests()
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = nil }
        let store = DrawInMemoryStore()
        let model = DrawPageModel(store: store)
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let window = KeyPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DrawPageHost(model: model, uiState: state, layout: layout)
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        model.openSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let searchEditor = window.firstResponder as? NSTextView
        XCTAssertNotNil(searchEditor, "opening Search gives its field the keyboard")
        if let searchEditor {
            searchEditor.insertText("plan", replacementRange: searchEditor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(model.search.query, "plan")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
            window.sendEvent(escape)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertFalse(model.isSearching)
        }
        model.closeSearch()
        model.openFilter()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let titleEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let titleField = try XCTUnwrap(titleEditor.delegate as? NSTextField)
        XCTAssertEqual(titleField.accessibilityIdentifier(), "draw-title-filter")
        titleEditor.insertText("plan", replacementRange: titleEditor.selectedRange())
        XCTAssertEqual(model.library.filter, "plan")
        let filterEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        window.sendEvent(filterEscape)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(model.isFiltering)
        XCTAssertTrue(window.firstResponder is DrawBoardView)
        model.openFilter()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        model.library.perform(.tags)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let tagEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let field = try XCTUnwrap(tagEditor.delegate as? NSTextField)
        XCTAssertNotEqual(field.accessibilityIdentifier(), "draw-title-filter", "Tags takes over from the canvas filter")
        XCTAssertTrue(field.placeholderString?.localizedCaseInsensitiveContains("tag") == true)
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize = CGSize(width: 320, height: 460),
                                         check: (NSView) throws -> Void) rethrows {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let host = NSHostingView(rootView: content.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try check(host)
    }

    func testAuditA10NotesGroupCountsNotes() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        _ = try store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Audit note")])).get()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "AuditAXNotes")))
        let model = NotesLibraryModel(search: { _ in [] }, store: store)
        model.layout = .list
        let view = NotesLibraryView(model: model, controller: controller, store: store,
            layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 320, height: 460)), bottomClearance: 0,
            searchFocused: .constant(false), searchOpen: .constant(false), rowCommands: { _ in [] }, libraryCommands: { [] },
            onOpen: { _ in }, onDelete: { _ in }, onBack: {})
        try withHost(view) { host in
            let group = try XCTUnwrap(find("notes-library-group-today", in: host))
            let selector = NSSelectorFromString("accessibilityValue")
            let object = try XCTUnwrap(group as? NSObject)
            XCTAssertTrue(object.responds(to: selector))
            let value = object.perform(selector)?.takeUnretainedValue() as? String
            print("AUDIT_GROUP_AX", type(of: group), value ?? "nil")
            XCTAssertEqual(value, "1 note")
        }
    }

    func testAuditA10TableButtonsKeepTheirIndividualNames() throws {
        let model = NoteFormatModel()
        var snapshot = NoteFormatSnapshot()
        snapshot.table = NoteTableToolsState(headerRow: true, rows: 3, columns: 2)
        model.setSnapshot(snapshot)
        try withHost(NoteFormatRowView(model: model, onClose: {}), size: CGSize(width: 320, height: 40)) { host in
            for tool in NoteTableTool.allCases {
                let button = try XCTUnwrap(find("notes-format-row-table-\(tool)", in: host))
                XCTAssertEqual(button.accessibilityLabel?() ?? nil, tool.title)
            }
            let close = try XCTUnwrap(find("notes-format-row-close", in: host))
            XCTAssertEqual(close.accessibilityLabel?() ?? nil, "Close Format")
        }
    }

    func testAuditA10CalendarPlusNamesTheEventItCreates() {
        XCTAssertEqual(PanelBottomBarLook.calendarPlus.label, "New event")
    }
}
