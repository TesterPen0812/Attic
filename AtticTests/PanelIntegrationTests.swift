import AppKit
import Combine
import ObjectiveC
import QuartzCore
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The Phase 1 integration round: the agent's `show` over the real panel
/// (monitor, controller, stores), click-through on a stationary reveal, the
/// retried page release, the key-state rule for older glass controls and
/// the Haptics seam.
@MainActor
final class PanelIntegrationTests: XCTestCase {

    #if !ATTIC_GENERATED_TESTS
    func testScreen9NotesLibraryEscapeLeavesTheOpenComposerInCharge() async throws {
        var keys: NotesLibraryKeys?
        NotesLibraryView.lifetimeProbe = { keys = $0 }
        defer { NotesLibraryView.lifetimeProbe = nil }

        let panel = try makePanel()
        guard case .success = panel.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Saved note")])) else {
            return XCTFail("seed a saved note so Notes opens its library")
        }
        await panel.noteDraft.pages.startAndWait()
        XCTAssertTrue(panel.noteDraft.pages.isLibraryPresented)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .notes, takesKeyboard: true), .shown)
        // SwiftUI only exposes the full nested control tree to hosted AX
        // queries after AppKit's enhanced-user-interface request. Other
        // panel AX tests use the same setting; restore it for sibling tests.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let root = try XCTUnwrap(panel.controller.panelForTesting.contentView)
        func descendants(_ view: AnyObject) -> [AnyObject] {
            [view] + ((view.accessibilityChildren?() ?? nil) ?? []).flatMap { descendants($0 as AnyObject) }
        }
        func element(_ id: String) -> AnyObject? {
            descendants(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        spin(until: { keys?.handler != nil && element("notes-new-note") != nil })
        XCTAssertTrue(try XCTUnwrap(element("notes-new-note")).accessibilityPerformPress?() ?? false)
        spin(until: { element("composer-title") != nil })
        XCTAssertNotNil(element("composer-title"), "Notes opens the shared + composer")

        // The creation Undo notice shares the window with this draft; it
        // must not give Notes' library permission to consume Escape.
        panel.controller.toasts.show("Added to Notes", answersUndoKey: false, action: {})
        XCTAssertEqual(panel.controller.toasts.current?.message, "Added to Notes")

        let window = panel.controller.panelForTesting
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertFalse(try XCTUnwrap(keys?.handler)(escape), "the library must let Escape reach the open composer")
        XCTAssertTrue(panel.noteDraft.pages.isLibraryPresented, "Escape must not open a ghost Title editor")
        window.onUnhandledEscape?()
        spin(until: { element("composer-title") == nil })
        XCTAssertNil(element("composer-title"), "Escape folds the composer")
    }

    func testScreen9OutgoingTasksStayDrawnUntilThePageSlideEnds() throws {
        let panel = try makePanel()
        let model = TasksPageModel(library: AtticLibrary(tasks: panel.store))
        let transit = PanelPageTransit()
        transit.departingPage = .tasks
        transit.sliding = true
        model.isPageShown = false // The outgoing page is no longer interactive.
        var pageVisible = false
        let pager = TasksPagerPages(
            span: model.pagerSwipe.span, model: model, store: panel.store,
            motion: model.pagerSwipe.motion, count: 3, shown: 0,
            size: CGSize(width: 300, height: 200),
            page: { index, drawn in
                Text(drawn ? "Drawing" : "Quiet")
                    .onAppear { if index == 0 { pageVisible = drawn } }
                    .onChange(of: drawn) { _, current in if index == 0 { pageVisible = current } }
                    .onDisappear { if index == 0 { pageVisible = false } }
            },
            token: { model.pageToken(TasksTab.allCases[$0]) }
        )
        let host = NSHostingView(rootView: pager.environment(\.panelPageTransit, transit))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.1)
        XCTAssertTrue(pageVisible, "outgoing Tasks rows must continue drawing while the page travels")
        transit.sliding = false
        spin(0.1)
        XCTAssertFalse(pageVisible, "after the slide, the retained Tasks page returns to its quiet state")
    }
    #endif

    func testR01UnrelatedSettingDoesNotReevaluateRetainedHosts() throws {
        #if ATTIC_LOCAL_ONLY
        var counts = [0, 0, 0]
        var relevantSettingChanges = 0
        PanelInvalidationProbe.shell = { counts[0] += 1 }
        PanelInvalidationProbe.tasksHost = { counts[1] += 1 }
        PanelInvalidationProbe.notesHost = { counts[2] += 1 }
        PanelInvalidationProbe.relevantSettings = { relevantSettingChanges += 1 }
        defer {
            PanelInvalidationProbe.shell = nil
            PanelInvalidationProbe.tasksHost = nil
            PanelInvalidationProbe.notesHost = nil
            PanelInvalidationProbe.relevantSettings = nil
        }
        let panel = try makePanel()
        var uiStateChanges = 0
        let uiStateSubscription = panel.uiState.objectWillChange.sink { _ in uiStateChanges += 1 }
        defer { uiStateSubscription.cancel() }
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.prepareBuiltPage(.notes)
        spin(0.6)
        let idleBefore = counts
        let stateBeforeIdle = uiStateChanges
        spin(0.25)
        let idleChanges = zip(counts, idleBefore).map { current, previous in current - previous }
        print("GAP_R01 idle_changes shell=\(idleChanges[0]) tasks=\(idleChanges[1]) notes=\(idleChanges[2]) ui_state=\(uiStateChanges - stateBeforeIdle)")
        let before = counts
        let stateBeforeToggle = uiStateChanges
        let settingsBeforeToggle = relevantSettingChanges
        panel.settings.quickCaptureEnabled.toggle()
        spin(0.25)
        let changes = zip(counts, before).map { current, previous in current - previous }
        print("GAP_R01 unrelated_setting_changes shell=\(changes[0]) tasks_host=\(changes[1]) notes_host=\(changes[2]) ui_state=\(uiStateChanges - stateBeforeToggle) relevant_settings=\(relevantSettingChanges - settingsBeforeToggle)")
        XCTAssertEqual(changes, [0, 0, 0], "Unrelated settings should leave the shell and retained page bodies alone")
        panel.settings.panelCornerSize += 1
        spin(0.25)
        XCTAssertGreaterThan(counts[0], before[0], "Panel geometry changes must still refresh the shell")
        XCTAssertGreaterThan(counts[1], before[1], "Panel geometry changes must reach Tasks")
        XCTAssertGreaterThan(counts[2], before[2], "Panel geometry changes must reach retained Notes")
        let beforeUnrelatedUIState = counts
        panel.uiState.isComposerAttachmentPickerPresented.toggle()
        spin(0.25)
        let unrelatedUIStateCounts = zip(counts, beforeUnrelatedUIState).map { current, previous in current - previous }
        print("GAP_R01 unrelated_ui_state_changes shell=\(unrelatedUIStateCounts[0]) tasks_host=\(unrelatedUIStateCounts[1]) notes_host=\(unrelatedUIStateCounts[2])")
        XCTAssertEqual(unrelatedUIStateCounts, [0, 0, 0], "A composer attachment picker flag should not redraw retained pages")
        #endif
    }

    /// Deliver an edge drag to the real AppKit hosting responder; the window
    /// frame, controller callback and retained SwiftUI pages all participate.
    /// The hidden page should keep its layout until the drag is released.
    func testLiveResizeUpdatesCurrentPageWithoutRebuildingRetainedNotesOnEachStep() throws {
        #if ATTIC_LOCAL_ONLY
        // Slides travel only without Reduce Motion, which the hosted CI runners
        // have on: state the motion this test is about.
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        var counts = [0, 0, 0]
        PanelInvalidationProbe.shell = { counts[0] += 1 }
        PanelInvalidationProbe.tasksHost = { counts[1] += 1 }
        PanelInvalidationProbe.notesHost = { counts[2] += 1 }
        defer {
            PanelInvalidationProbe.shell = nil
            PanelInvalidationProbe.tasksHost = nil
            PanelInvalidationProbe.notesHost = nil
        }
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.prepareBuiltPage(.notes)
        spin(0.6)
        let before = counts
        let window = panel.controller.panelForTesting
        let host = try XCTUnwrap((window.contentView as? AtticPanelContentContainer)?.hostingView)
        host.suppressCaptureWatchdogForSyntheticTests = true
        defer { host.suppressCaptureWatchdogForSyntheticTests = false }
        let initial = window.visibleContentFrame
        let pullsFromLeft = [.topRight, .bottomRight].contains(panel.controller.currentCorner)
        let grip = CGPoint(x: pullsFromLeft ? initial.minX + 2 : initial.maxX - 2,
                           y: initial.midY)
        let direction: CGFloat = pullsFromLeft ? -1 : 1
        func event(_ type: NSEvent.EventType, at point: CGPoint, timestamp: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        host.mouseDown(with: try event(.leftMouseDown, at: grip, timestamp: 1))
        XCTAssertTrue(panel.uiState.interactionLockReasons.contains(.windowResize))
        var stepTimesMs: [Double] = []
        for index in 1...60 {
            let location = CGPoint(x: grip.x + direction * CGFloat(index), y: grip.y)
            let dragged = try event(.leftMouseDragged, at: location, timestamp: 1 + Double(index) * 0.02)
            let began = CACurrentMediaTime()
            host.mouseDragged(with: dragged)
            host.layoutSubtreeIfNeeded()
            stepTimesMs.append((CACurrentMediaTime() - began) * 1_000)
            spin(0.015)
        }
        XCTAssertEqual(window.visibleContentFrame.width, initial.width + 60, accuracy: 1,
                       "The edge drag must actually change the native panel frame")
        let during = zip(counts, before).map { current, prior in current - prior }
        print("RESIZE_HOST_COUNTS steps=60 shell=\(during[0]) tasks=\(during[1]) retained_notes=\(during[2])")
        let ordered = stepTimesMs.sorted()
        print(String(format: "RESIZE_STEP_MAIN_THREAD steps=60 median_ms=%.3f p95_ms=%.3f worst_ms=%.3f",
                     ordered[ordered.count / 2], ordered[56], ordered.last ?? 0))
        // Retain numbers in xcresult even when -quiet hides XCTest stdout.
        XCTContext.runActivity(named: String(format:
            "RESIZE_MEASURE steps=60 shell=%d tasks=%d retained_notes=%d median_ms=%.3f p95_ms=%.3f worst_ms=%.3f",
            during[0], during[1], during[2], ordered[ordered.count / 2], ordered[56], ordered.last ?? 0
        )) { _ in }
        XCTAssertGreaterThan(during[0], 0, "The visible shell must follow the window size")
        XCTAssertGreaterThan(during[1], 0, "The current Tasks page must receive the new geometry")
        XCTAssertLessThanOrEqual(during[2], 3, "The hidden Notes page should not rebuild for intermediate resize sizes")
        let beforeEnd = counts[2]
        let release = CGPoint(x: grip.x + direction * 60, y: grip.y)
        host.mouseUp(with: try event(.leftMouseUp, at: release, timestamp: 2.3))
        spin(0.2)
        XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.windowResize))
        XCTAssertGreaterThan(counts[2], beforeEnd, "The retained page must receive the final geometry at release")
        XCTAssertEqual(panel.uiState.panelSize.width, initial.width + 60, accuracy: 1)
        #endif
    }

    /// Exercise a whole resize gesture repeatedly, including the exposed
    /// corner, while Tasks/Notes are both retained behind other pages. A
    /// synthetic AppKit event enters the production hosting responder and
    /// changes the native window frame at every intermediate step.
    func testLiveResizeRetainedPagesSurviveRepeatedEdgeAndCornerDragsOnEveryPage() throws {
        #if ATTIC_LOCAL_ONLY
        // Slides travel only without Reduce Motion, which the hosted CI runners
        // have on: state the motion this test is about.
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        var tasksUpdates = 0
        var notesUpdates = 0
        var calendarUpdates = 0
        var canvasUpdates = 0
        var lastPageSize: [PanelPage: CGSize] = [:]
        PanelInvalidationProbe.tasksHost = { tasksUpdates += 1 }
        PanelInvalidationProbe.notesHost = { notesUpdates += 1 }
        PanelInvalidationProbe.calendarHost = { calendarUpdates += 1 }
        PanelInvalidationProbe.canvasHost = { canvasUpdates += 1 }
        PanelInvalidationProbe.pageLayout = { page, size in lastPageSize[page] = size }
        defer {
            PanelInvalidationProbe.tasksHost = nil
            PanelInvalidationProbe.notesHost = nil
            PanelInvalidationProbe.calendarHost = nil
            PanelInvalidationProbe.canvasHost = nil
            PanelInvalidationProbe.pageLayout = nil
        }

        // 500 Now, 500 Later, 5,000 Done: exercise the native resize path
        // with the owner's heavy-data scenario, not just an empty panel.
        let panel = try makePanel(scaleSeed: true)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.prepareBuiltPage(.notes)
        panel.uiState.prepareBuiltPage(.calendar)
        panel.uiState.prepareBuiltPage(.canvas)
        spin(0.6)
        let window = panel.controller.panelForTesting
        let host = try XCTUnwrap((window.contentView as? AtticPanelContentContainer)?.hostingView)
        host.suppressCaptureWatchdogForSyntheticTests = true
        defer { host.suppressCaptureWatchdogForSyntheticTests = false }

        let docked = panel.controller.currentCorner
        let leftGrip = docked == .topRight || docked == .bottomRight
        let bottomGrip = docked == .topLeft || docked == .topRight
        let xDirection: CGFloat = leftGrip ? -1 : 1
        let yDirection: CGFloat = bottomGrip ? -1 : 1
        func event(_ type: NSEvent.EventType, at point: CGPoint, timestamp: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }

        // Setting enhanced UI uses the same AppKit seam as existing AX tests.
        // It exercises the AX-enabled layout path, without claiming an
        // external assistive-technology client is connected.
        let axAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let originalAX = NSApp.accessibilityAttributeValue(axAttribute)
        defer { NSApp.accessibilitySetValue(originalAX, forAttribute: axAttribute) }
        var drags = 0
        for page in PanelPage.allCases {
            panel.uiState.selectSection(page.section)
            spin(0.6)
            XCTAssertEqual(PanelPage(panel.uiState.selectedSection), page)
            for isCorner in [false, true] {
                var hiddenTasksDuringDrag = 0
                var hiddenNotesDuringDrag = 0
                var hiddenCalendarDuringDrag = 0
                var hiddenCanvasDuringDrag = 0
                var stepTimesMs: [[Double]] = [[], []]
                var handlerTimesMs: [[Double]] = [[], []]
                var layoutTimesMs: [[Double]] = [[], []]
                for repeatIndex in 0..<14 {
                    if repeatIndex == 0 || repeatIndex == 7 {
                        NSApp.accessibilitySetValue(repeatIndex == 7, forAttribute: axAttribute)
                        spin(0.1) // Do not count AX mode changes as resize work.
                    }
                    let frame = window.visibleContentFrame
                    let xInset: CGFloat = isCorner ? 12 : 2
                    let start = CGPoint(x: leftGrip ? frame.minX + xInset : frame.maxX - xInset,
                                        y: isCorner
                                            ? (bottomGrip ? frame.minY + 12 : frame.maxY - 12)
                                            : frame.midY)
                    let grow: CGFloat = repeatIndex.isMultiple(of: 2) ? 1 : -1
                    let begin = Double(drags * 10 + 1)
                    host.mouseDown(with: try event(.leftMouseDown, at: start, timestamp: begin))
                    XCTAssertTrue(panel.uiState.interactionLockReasons.contains(.windowResize),
                                  "\(page) \(isCorner ? "corner" : "edge") should capture the grip")
                    // Count every intermediate step, including the first:
                    // mouseDown's frozen-size handoff is now content-equivalent.
                    let beforeTasks = tasksUpdates
                    let beforeNotes = notesUpdates
                    let beforeCalendar = calendarUpdates
                    let beforeCanvas = canvasUpdates
                    for step in 1...3 {
                        let offset = CGFloat(step) * 2 * grow
                        let point = CGPoint(x: start.x + xDirection * offset,
                                            y: start.y + (isCorner ? yDirection * offset : 0))
                        let began = CACurrentMediaTime()
                        host.mouseDragged(with: try event(.leftMouseDragged, at: point,
                                                        timestamp: begin + Double(step) * 0.02))
                        let handled = CACurrentMediaTime()
                        host.layoutSubtreeIfNeeded()
                        let laidOut = CACurrentMediaTime()
                        let axIndex = repeatIndex >= 7 ? 1 : 0
                        handlerTimesMs[axIndex].append((handled - began) * 1_000)
                        layoutTimesMs[axIndex].append((laidOut - handled) * 1_000)
                        stepTimesMs[axIndex].append((laidOut - began) * 1_000)
                        spin(0.01)
                    }
                    if page != .tasks { hiddenTasksDuringDrag += tasksUpdates - beforeTasks }
                    if page != .notes { hiddenNotesDuringDrag += notesUpdates - beforeNotes }
                    if page != .calendar { hiddenCalendarDuringDrag += calendarUpdates - beforeCalendar }
                    if page != .canvas { hiddenCanvasDuringDrag += canvasUpdates - beforeCanvas }
                    let width = frame.width + 6 * grow
                    let height = frame.height + (isCorner ? 6 * grow : 0)
                    XCTAssertEqual(window.visibleContentFrame.width, width, accuracy: 1)
                    XCTAssertEqual(window.visibleContentFrame.height, height, accuracy: 1)
                    let end = CGPoint(x: start.x + xDirection * 6 * grow,
                                      y: start.y + (isCorner ? yDirection * 6 * grow : 0))
                    host.mouseUp(with: try event(.leftMouseUp, at: end, timestamp: begin + 0.1))
                    XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.windowResize))
                    spin(0.04)
                    for retained in PanelPage.allCases where panel.uiState.builtPages.contains(retained) {
                        let actual = try XCTUnwrap(lastPageSize[retained], "Missing retained \(retained) layout")
                        XCTAssertEqual(actual.width, panel.uiState.panelSize.width, accuracy: 1,
                                       "A retained \(retained) host must catch up to the final width")
                        XCTAssertEqual(actual.height, panel.uiState.panelSize.height, accuracy: 1,
                                       "A retained \(retained) host must catch up to the final height")
                    }
                    drags += 1
                }
                // Retained pages must avoid per-step work but receive the
                // actual clamped final window size at every release.
                XCTAssertLessThanOrEqual(hiddenNotesDuringDrag, 3,
                    "A retained Notes page must not rebuild on 42 intermediate \(page) resize steps")
                XCTAssertLessThanOrEqual(hiddenTasksDuringDrag, 3,
                    "A retained Tasks page must not rebuild on intermediate \(page) resize steps")
                XCTAssertLessThanOrEqual(hiddenCalendarDuringDrag, 3,
                    "A retained Calendar page must not rebuild on intermediate \(page) resize steps")
                XCTAssertLessThanOrEqual(hiddenCanvasDuringDrag, 3,
                    "A retained Draw page must not rebuild on intermediate \(page) resize steps")
                for (axIndex, timings) in stepTimesMs.enumerated() {
                    let sorted = timings.sorted()
                    let handlers = handlerTimesMs[axIndex].sorted()
                    let layouts = layoutTimesMs[axIndex].sorted()
                    XCTAssertEqual(sorted.count, 21)
                    XCTContext.runActivity(named: String(format:
                        "RESIZE_STRESS page=%@ grip=%@ enhanced_ax=%d drags=7 steps=%d median_ms=%.3f p95_ms=%.3f worst_ms=%.3f handler_median_ms=%.3f layout_median_ms=%.3f hidden_tasks=%d hidden_notes=%d hidden_calendar=%d hidden_canvas=%d",
                        page.rawValue, isCorner ? "corner" : "edge", axIndex, sorted.count,
                        sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last ?? 0,
                        handlers[handlers.count / 2], layouts[layouts.count / 2],
                        hiddenTasksDuringDrag, hiddenNotesDuringDrag, hiddenCalendarDuringDrag,
                        hiddenCanvasDuringDrag)) { _ in }
                }
            }
        }
        XCTAssertEqual(drags, 112)
        #endif
    }

    /// A page selected by a shortcut or agent during a held resize must enter
    /// from the live edge; the departing page must keep its live geometry
    /// until the slide has finished.
    func testLiveResizePageSwitchUsesLiveGeometryDuringTransition() throws {
        #if ATTIC_LOCAL_ONLY
        // The slide's travel is zero under Reduce Motion, which the hosted CI
        // runners have on: state the motion this test is about.
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        var layouts: [PanelPage: CGSize] = [:]
        var offsets: [PanelPage: CGFloat] = [:]
        PanelInvalidationProbe.pageLayout = { page, size in layouts[page] = size }
        PanelInvalidationProbe.pageRestingOffset = { page, offset in offsets[page] = offset }
        defer {
            PanelInvalidationProbe.pageLayout = nil
            PanelInvalidationProbe.pageRestingOffset = nil
        }
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.prepareBuiltPage(.notes)
        spin(0.5)
        let window = panel.controller.panelForTesting
        let host = try XCTUnwrap((window.contentView as? AtticPanelContentContainer)?.hostingView)
        host.suppressCaptureWatchdogForSyntheticTests = true
        defer { host.suppressCaptureWatchdogForSyntheticTests = false }
        let initial = window.visibleContentFrame
        let leftGrip = [.topRight, .bottomRight].contains(panel.controller.currentCorner)
        let sign: CGFloat = leftGrip ? -1 : 1
        let point = CGPoint(x: leftGrip ? initial.minX + 2 : initial.maxX - 2, y: initial.midY)
        func event(_ type: NSEvent.EventType, x: CGFloat, time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: CGPoint(x: x, y: point.y)),
                modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        host.mouseDown(with: try event(.leftMouseDown, x: point.x, time: 1))
        XCTAssertTrue(PerformanceSignposts.isPanelLiveResizeActive)
        host.mouseDragged(with: try event(.leftMouseDragged, x: point.x + sign * 24, time: 1.1))
        host.layoutSubtreeIfNeeded()
        spin(0.06)
        let liveWidth = window.visibleContentFrame.width
        XCTAssertGreaterThan(liveWidth, initial.width + 4)
        XCTAssertEqual(abs(try XCTUnwrap(offsets[.notes])), liveWidth, accuracy: 1,
                       "A hidden incoming page must rest outside the live panel width")

        panel.uiState.switchPage(to: .notes, motion: .current(reduceMotion: false))
        host.layoutSubtreeIfNeeded()
        spin(0.06)
        XCTAssertEqual(try XCTUnwrap(layouts[.tasks]).width, liveWidth, accuracy: 1,
                       "The departing Tasks page must use the live width while sliding")
        XCTAssertEqual(try XCTUnwrap(layouts[.notes]).width, liveWidth, accuracy: 1)
        host.mouseUp(with: try event(.leftMouseUp, x: point.x + sign * 24, time: 1.2))
        XCTAssertFalse(PerformanceSignposts.isPanelLiveResizeActive)
        spin(0.3)
        XCTAssertNil(panel.uiState.retainedPageSizeDuringLiveResize)
        XCTAssertEqual(try XCTUnwrap(layouts[.tasks]).width, panel.uiState.panelSize.width, accuracy: 1)
        #endif
    }

    /// Every exit path must release the retained-page snapshot and catch up to
    /// the true native frame. A programmatic resize has no drag snapshot.
    func testLiveResizeCancelHideScreenChangeAndProgrammaticSizeCatchUp() throws {
        #if ATTIC_LOCAL_ONLY
        // Slides travel only without Reduce Motion, which the hosted CI runners
        // have on: state the motion this test is about.
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        var layouts: [PanelPage: CGSize] = [:]
        PanelInvalidationProbe.pageLayout = { page, size in layouts[page] = size }
        defer { PanelInvalidationProbe.pageLayout = nil }
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.prepareBuiltPage(.notes)
        spin(0.5)
        let window = panel.controller.panelForTesting
        let host = try XCTUnwrap((window.contentView as? AtticPanelContentContainer)?.hostingView)
        host.suppressCaptureWatchdogForSyntheticTests = true
        defer { host.suppressCaptureWatchdogForSyntheticTests = false }
        let leftGrip = [.topRight, .bottomRight].contains(panel.controller.currentCorner)
        let sign: CGFloat = leftGrip ? -1 : 1
        func event(_ type: NSEvent.EventType, at point: CGPoint, time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        for (index, reason) in [PanelInteractionCancellationReason.escape,
                                .explicitHide, .screenChanged, .lostWindow].enumerated() {
            let initial = window.visibleContentFrame
            let grip = CGPoint(x: leftGrip ? initial.minX + 2 : initial.maxX - 2, y: initial.midY)
            host.mouseDown(with: try event(.leftMouseDown, at: grip, time: Double(index * 10 + 1)))
            XCTAssertTrue(PerformanceSignposts.isPanelLiveResizeActive)
            XCTAssertNotNil(panel.uiState.retainedPageSizeDuringLiveResize)
            let moved = CGPoint(x: grip.x + sign * 6, y: grip.y)
            host.mouseDragged(with: try event(.leftMouseDragged, at: moved, time: Double(index * 10 + 2)))
            host.layoutSubtreeIfNeeded()
            host.cancelActiveInteraction(reason: reason)
            XCTAssertFalse(PerformanceSignposts.isPanelLiveResizeActive)
            spin(0.12)
            XCTAssertNil(panel.uiState.retainedPageSizeDuringLiveResize, "Snapshot survived \(reason)")
            XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.windowResize))
            XCTAssertEqual(try XCTUnwrap(layouts[.notes]).width, panel.uiState.panelSize.width, accuracy: 1)
        }
        // Another controller can alter the native window while the grip is
        // captured (work-area recovery, screen bounds or a size preference).
        // The release must accept that authoritative final native size.
        let beforeProgrammaticDuringDrag = window.visibleContentFrame
        let heldGrip = CGPoint(x: leftGrip ? beforeProgrammaticDuringDrag.minX + 2
                                                : beforeProgrammaticDuringDrag.maxX - 2,
                               y: beforeProgrammaticDuringDrag.midY)
        host.mouseDown(with: try event(.leftMouseDown, at: heldGrip, time: 100))
        XCTAssertNotNil(panel.uiState.retainedPageSizeDuringLiveResize)
        let changedDuringDrag = CGRect(origin: beforeProgrammaticDuringDrag.origin,
                                       size: CGSize(width: beforeProgrammaticDuringDrag.width - 5,
                                                    height: beforeProgrammaticDuringDrag.height - 3))
        window.setVisibleContentFrame(changedDuringDrag, display: false)
        panel.uiState.updatePanelSize(window.visibleContentFrame.size)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(panel.uiState.retainedPageSizeDuringLiveResize)
        host.mouseUp(with: try event(.leftMouseUp, at: heldGrip, time: 101))
        spin(0.12)
        XCTAssertNil(panel.uiState.retainedPageSizeDuringLiveResize)
        XCTAssertEqual(try XCTUnwrap(layouts[.notes]).width, panel.uiState.panelSize.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(layouts[.notes]).height, panel.uiState.panelSize.height, accuracy: 1)
        let current = window.visibleContentFrame
        let requested = CGRect(origin: current.origin,
                               size: CGSize(width: current.width - 6, height: current.height - 4))
        window.setVisibleContentFrame(requested, display: false)
        panel.uiState.updatePanelSize(window.visibleContentFrame.size)
        host.layoutSubtreeIfNeeded()
        spin(0.15)
        XCTAssertNil(panel.uiState.retainedPageSizeDuringLiveResize)
        XCTAssertEqual(try XCTUnwrap(layouts[.notes]).width, panel.uiState.panelSize.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(layouts[.notes]).height, panel.uiState.panelSize.height, accuracy: 1)
        #endif
    }

    /// "Brighten glass over dark backgrounds" draws on the shell's surface,
    /// so switching it must redraw the panel, not only the island (owner,
    /// 2026-11-11: "only the island seems to change").
    func testBrightenGlassRedrawsTheShell() throws {
        #if ATTIC_LOCAL_ONLY
        var shell = 0
        PanelInvalidationProbe.shell = { shell += 1 }
        defer { PanelInvalidationProbe.shell = nil }
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        spin(0.6)
        for _ in 0..<2 {
            let before = shell
            panel.settings.brightenGlass.toggle()
            spin(0.25)
            XCTAssertGreaterThan(shell, before, "Brighten glass must redraw the panel's surface")
        }
        #endif
    }
    private struct Panel {
        let defaults: UserDefaults
        let suite: String
        let store: TaskStore
        let notes: NoteStore
        let canvasSession: CanvasSession
        let noteDraft: NoteDraftController
        let settings: AppSettings
        let uiState: PanelUIState
        let controller: AtticPanelController
        let monitor: CornerHoverMonitor
        let presenter: PanelAgentPresenter
        let gate: PersistenceGate
    }

    private var panels: [Panel] = []

    override func tearDown() async throws {
        for panel in panels {
            _ = panel.controller.requestHide { _ in }
            panel.defaults.removePersistentDomain(forName: panel.suite)
        }
        panels.removeAll()
        spin(0.4)
    }

    private func makePanel(scaleSeed: Bool = false) throws -> Panel {
        let suite = "PanelIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        if scaleSeed { try TasksPagePreview.seedScale(in: container) }
        let gate = PersistenceGate()
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, persist: gate.save, attachmentFileStore: makeTestAttachmentFileStore()))
        let canvasStore = CanvasStore(container: container)
        let canvasSession = CanvasSession(store: canvasStore)
        let noteDraft = NoteDraftController(noteStore: notes)
        let settings = AppSettings(defaults: defaults)
        let uiState = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: canvasSession,
            noteDraft: noteDraft, settings: settings, uiState: uiState
        )
        let monitor = CornerHoverMonitor(
            settings: settings, panelController: controller, uiState: uiState,
            store: store, noteStore: notes, canvasStore: canvasStore, noteDraft: noteDraft
        )
        let presenter = PanelAgentPresenter(
            uiState: uiState, store: store, noteStore: notes,
            canvasSession: canvasSession, noteDraft: noteDraft,
            reveal: { [weak monitor] section in
                monitor?.revealProgrammatically(section: section, takesKeyboard: false) ?? .refused(.noScreen)
            }
        )
        let panel = Panel(
            defaults: defaults, suite: suite, store: store, notes: notes, canvasSession: canvasSession,
            noteDraft: noteDraft, settings: settings, uiState: uiState, controller: controller,
            monitor: monitor, presenter: presenter, gate: gate
        )
        panels.append(panel)
        return panel
    }

    func testBugs3OpeningATaskPageClosesTheCardAndLeavesBackAvailable() throws {
        let panel = try makePanel()
        let task = try XCTUnwrap(panel.store.commit([TaskDraft(title: "Back target")])?.first)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let root = try XCTUnwrap(panel.controller.panelForTesting.contentView)
        func elements(_ object: AnyObject) -> [AnyObject] {
            [object] + ((object.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func element(_ id: String) -> AnyObject? {
            elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
        }
        spin(until: { element("tasks-new-task") != nil })
        XCTAssertTrue(try XCTUnwrap(element("tasks-new-task")).accessibilityPerformPress?() ?? false)
        spin(until: { element("composer-title") != nil })
        XCTAssertNotNil(element("composer-title"))
        panel.uiState.openTaskNote(task.id, from: .tasks, backTitle: "Back to Now")
        spin(until: { element("task-note-back") != nil })
        XCTAssertNil(element("composer-title"), "the card must give Back its row when a task page opens")
        XCTAssertNil(element("panel-more-button"), "only the task page's note menu is drawn while it covers the list")
        let back = try XCTUnwrap(element("task-note-back"))
        XCTAssertTrue(back.accessibilityPerformPress?() ?? false)
        spin(until: { panel.uiState.openTaskNoteID == nil })
        XCTAssertNil(panel.uiState.openTaskNoteID)
        XCTAssertEqual(panel.uiState.selectedSection, .tasks)
    }

    func testBugs4IdlePageBuildWaitsForTheActivePanelInteraction() throws {
        for reason in [PanelInteractionLockReason.panelSwipe, .menuTracking] {
            let panel = try makePanel()
            let delay = AtticPanelController.keptPagesBuildDelay
            AtticPanelController.keptPagesBuildDelay = 0.6
            defer { AtticPanelController.keptPagesBuildDelay = delay }
            XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
            // A reveal resets a previous swipe's lock. Start this interaction
            // after that boundary and before the idle-build deadline.
            spin(0.3)
            panel.uiState.setInteractionLock(reason, isActive: true)
            defer { panel.uiState.setInteractionLock(reason, isActive: false) }
            spin(0.4)
            XCTAssertEqual(panel.uiState.builtPages, [.tasks], "prewarming must not stall an active swipe or menu")
            panel.uiState.setInteractionLock(reason, isActive: false)
            spin(until: { panel.uiState.builtPages == Set(PanelPage.allCases) })
            XCTAssertEqual(panel.uiState.builtPages, Set(PanelPage.allCases), "warm-up resumes once the interaction ends")
        }
    }

    func testBugs4IdleRevealBuildsColdNotesWithoutTakingItsInput() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.keptPagesBuildDelay
        AtticPanelController.keptPagesBuildDelay = 0
        defer { AtticPanelController.keptPagesBuildDelay = delay }
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        spin(until: { panel.uiState.builtPages == Set(PanelPage.allCases)
            && panel.noteDraft.pages.active?.engine.textView != nil }, timeout: 3)
        XCTAssertEqual(panel.uiState.builtPages, Set(PanelPage.allCases), "first island click must only reveal a built page")
        let text = try XCTUnwrap(panel.noteDraft.pages.active?.engine.textView, "cold Notes has real content before its first click")
        XCTAssertTrue(text.isSuspended, "warming Notes cannot own native input")
        XCTAssertEqual(panel.uiState.selectedSection, .tasks)
        XCTAssertFalse(panel.uiState.isPanelKey)
    }

    func testBugs4ColdPrewarmRestoresSavedViewportWithoutTakingFocus() throws {
        let suite = "Bugs4Viewport.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        let document = NoteDocument(blocks: [.text("Kept viewport")] + (0..<100).map { .text("Paragraph \($0) with enough writing to scroll") })
        guard case .success = store.createDocumentNote(id: id, document: document) else { return XCTFail("seed note") }
        defaults.set(["location": 5, "length": 0, "scroll": 120.0], forKey: "notes.viewState.\(id.uuidString)")
        let controller = NotesPageController(store: store, journal: nil, defaults: defaults)
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertEqual(session.scrollOffset, 120)
        let chrome = NotesPageChrome()
        func root(current: Bool) -> AnyView {
            AnyView(NoteEditorRepresentable(session: session, chrome: chrome, columnInset: 20,
                topInset: 60, bottomInset: 60, headerBottom: 40, design: .default,
                tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] })
                .environment(\.atticPanelPageIsCurrent, current))
        }
        let host = NSHostingView(rootView: root(current: false))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 320, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        let editor = try XCTUnwrap(session.engine.textView)
        let scroll = try XCTUnwrap(session.engine.scrollView)
        XCTAssertTrue(editor.isSuspended)
        XCTAssertFalse(window.firstResponder === editor, "warming must not claim native focus")
        host.rootView = root(current: true)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertTrue(session.engine.textView === editor)
        XCTAssertTrue(session.engine.scrollView === scroll)
        XCTAssertEqual(scroll.contentView.bounds.minY, 120, accuracy: 1, "the one-shot presentation must retain the saved viewport when warmed hidden")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testBugs4NotesNativeScrollerDisappearsOnlyDuringPageSlide() async throws {
        let (panel, session, _) = try await followupNotes()
        let scroll = try XCTUnwrap(session.engine.scrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        panel.uiState.pageTransit.sliding = true
        spin(0.1)
        XCTAssertTrue(scroll.verticalScroller.map { $0.isHidden || $0.alphaValue == 0 } ?? true,
                      "AppKit must follow the same page transit as SwiftUI without removing its gutter")
        panel.uiState.pageTransit.sliding = false
        spin(0.1)
        XCTAssertTrue(scroll.hasVerticalScroller)
    }

    func testBugs4TaskNativeScrollerDisappearsOnlyDuringPageSlide() async throws {
        let panel = try makePanel()
        let task = try XCTUnwrap(panel.store.commit([TaskDraft(title: "Scroller target")])?.first)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown)
        panel.uiState.openTaskNote(task.id, from: .tasks, backTitle: "Back to Now")
        spin(until: { panel.noteDraft.pages.taskNotePresenter?.lease != nil })
        let scroll = try XCTUnwrap(panel.noteDraft.pages.taskNotePresenter?.host.scrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        panel.uiState.pageTransit.sliding = true
        spin(0.1)
        XCTAssertTrue(scroll.verticalScroller.map { $0.isHidden || $0.alphaValue == 0 } ?? true)
        panel.uiState.pageTransit.sliding = false
        spin(0.1)
        XCTAssertTrue(scroll.hasVerticalScroller)
    }

    // Retaining Notes must retain its native editor without retaining input ownership.
    private func followupNotes() async throws -> (Panel, NoteSession, NoteEditorTextView) {
        let panel = try makePanel()
        await panel.noteDraft.pages.startAndWait()
        panel.uiState.selectSection(.notes)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .notes, takesKeyboard: false), .shown)
        spin(until: { panel.noteDraft.pages.active?.engine.textView != nil })
        let session = try XCTUnwrap(panel.noteDraft.pages.active)
        let editor = try XCTUnwrap(session.engine.textView)
        return (panel, session, editor)
    }

    private func followupSwitch(_ panel: Panel, to section: PanelSection) {
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: section, takesKeyboard: false), .shown)
        spin(0.4)
    }

    func testFollowupKeptNotesSavesAnEditOnLeaving() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Durable on leave", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        let fresh = ModelContext(panel.notes.container)
        let rows = try fresh.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.first { $0.id == session.noteID }?.title, "Durable on leave")
        XCTAssertTrue(session.engine.textView === editor, "leaving must retain the built editor")
        followupSwitch(panel, to: .notes)
        XCTAssertTrue(session.engine.textView === editor, "returning must reuse the same native editor")
        XCTAssertFalse(editor.isSuspended)
    }

    func testFollowupKeptNotesReleasesInputAndAgentLocks() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Releasable", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes), "the page stays built")
        XCTAssertTrue(session.engine.textView === editor)
        XCTAssertTrue(editor.isSuspended, "a retained hidden editor must reject late input")
        XCTAssertFalse(editor.isEditable)
        let text = editor.string
        editor.insertText("stray", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, text)
        if case .direct = panel.notes.agentWriteDisposition(session.noteID) {} else {
            XCTFail("a clean hidden note must release the visible-editor write lock")
        }
        XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.notesEditorFocus))
        XCTAssertFalse(panel.uiState.interactionLockReasons.contains(.notesPopover))
    }

    func testFollowupKeptNotesRefreshesImportedContextBeforePresentation() async throws {
        let (panel, session, _) = try await followupNotes()
        XCTAssertTrue(session.engine.performEdit(NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "Before import"), name: "Type"))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes))
        let oldContext = panel.notes.modelContext
        let other = trackAttachmentReconciliation(of: NoteStore(container: panel.notes.container,
            attachmentFileStore: makeTestAttachmentFileStore()))
        let revision = try XCTUnwrap(other.note(withID: session.noteID)?.revisionID)
        _ = try other.saveDocument(noteID: session.noteID,
            document: NoteDocument(blocks: [.text("Imported writing")]), baseRevisionID: revision).get()
        panel.notes.refresh()
        XCTAssertFalse(panel.notes.modelContext === oldContext, "imports replace the context")
        followupSwitch(panel, to: .notes)
        XCTAssertEqual(panel.noteDraft.pages.active?.engine.plainText, "Imported writing")
        XCTAssertFalse(panel.noteDraft.pages.active?.engine === session.engine, "stale engine is replaced before showing")
    }

    func testFollowupKeptNotesFailedSaveRollsBackAndRefusesLeaving() async throws {
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Original", replacementRange: NSRange(location: 0, length: 0))
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes), "failure path also retains Notes")
        followupSwitch(panel, to: .notes)
        XCTAssertTrue(session.engine.textView === editor, "failure path uses the retained editor too")
        let live = try XCTUnwrap(session.engine.textView)
        live.insertText(" unsaved", replacementRange: NSRange(location: live.string.utf16.count, length: 0))
        panel.gate.shouldFail = true
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .refused(.unsavedNote))
        XCTAssertEqual(panel.uiState.selectedSection, .notes)
        XCTAssertEqual(session.engine.plainText, "Original unsaved", "the draft remains available for retry")
        let fresh = ModelContext(panel.notes.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<NoteItem>()).first { $0.id == session.noteID }?.title, "Original")
        XCTAssertFalse(panel.notes.modelContext.hasChanges, "failed save rolls back staging")
        panel.gate.shouldFail = false
        followupSwitch(panel, to: .tasks)
        XCTAssertEqual(panel.notes.note(withID: session.noteID)?.title, "Original unsaved")
    }

    func testFollowupHiddenNotesCannotConsumeFindEscapeOrReclaimFocus() async throws {
        var chrome: NotesPageChrome?
        NotesEditorPage.lifetimeProbe = { value, _ in chrome = value }
        defer { NotesEditorPage.lifetimeProbe = nil }
        let (panel, session, editor) = try await followupNotes()
        session.engine.find.show()
        XCTAssertTrue(session.engine.find.isShown)
        let controls = try XCTUnwrap(chrome?.controls)
        followupSwitch(panel, to: .tasks)
        XCTAssertFalse(session.engine.find.isShown, "Find releases its input without refocusing on leave")
        let window = try XCTUnwrap(editor.window)
        window.makeFirstResponder(nil)
        let responder = window.firstResponder
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertFalse(controls.handleKey(escape), "hidden controls cannot take another page's Escape")
        editor.restoreInputFocus()
        XCTAssertTrue(window.firstResponder === responder, "late focus restoration cannot focus hidden Notes")
    }

    func testFollowupHiddenNotesLibraryReleasesItsNativeKeyboardMonitor() async throws {
        var keys: NotesLibraryKeys?
        NotesLibraryView.lifetimeProbe = { keys = $0 }
        defer { NotesLibraryView.lifetimeProbe = nil }
        let (panel, _, _) = try await followupNotes()
        XCTAssertTrue(panel.noteDraft.pages.showLibrary()); spin(0.3)
        let libraryKeys = try XCTUnwrap(keys)
        XCTAssertNotNil(libraryKeys.handler)
        followupSwitch(panel, to: .tasks)
        XCTAssertNil(libraryKeys.handler, "the hidden library cannot handle typing, Return, delete or Undo")
        followupSwitch(panel, to: .notes)
        XCTAssertNotNil(libraryKeys.handler, "the same built library resumes its keys")
        XCTAssertNotNil(libraryKeys.window)
    }

    func testFollowupHiddenNotesRefusesLateTableInput() async throws {
        let panel = try makePanel()
        let (id, _) = try panel.notes.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Table"), .table(.blank()), .text("After")])).get()
        await panel.noteDraft.pages.startAndWait()
        XCTAssertTrue(panel.noteDraft.pages.open(noteID: id))
        panel.noteDraft.pages.dismissLibrary() // Match the library's actual open route.
        followupSwitch(panel, to: .notes)
        let session = try XCTUnwrap(panel.noteDraft.pages.active)
        let engine = session.engine
        let blockID = try XCTUnwrap(engine.document().blocks.first { $0.kind == .table }?.id)
        let attachment = try XCTUnwrap(engine.tableAttachment(id: blockID)?.0)
        engine.enterTable(attachment, at: .init(row: 2, column: 1), caret: .end)
        spin(0.2)
        let cell = attachment.tableView.editor
        followupSwitch(panel, to: .tasks)
        let before = engine.document()
        cell.insertText("late", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(engine.document(), before, "retaining the table cannot retain permission to edit it")
        XCTAssertFalse(engine.allowsTableCellEdit)
        let window = try XCTUnwrap(engine.textView?.window)
        window.makeFirstResponder(nil)
        let responder = window.firstResponder
        cell.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(engine.document(), before, "late Tab on the last cell must not append a row")
        attachment.tableView.activate(.init(row: 0, column: 0), caret: .start)
        XCTAssertTrue(window.firstResponder === responder, "a late table callback cannot reclaim hidden input")
    }

    func testFollowupHiddenNotesDismissesSlashAndRejectsItsLatePick() async throws {
        var chrome: NotesPageChrome?
        NotesEditorPage.lifetimeProbe = { value, _ in chrome = value }
        defer { NotesEditorPage.lifetimeProbe = nil }
        let (panel, session, editor) = try await followupNotes()
        editor.insertText("Title", replacementRange: NSRange(location: 0, length: 0))
        editor.insertNewline(nil)
        editor.insertText("/", replacementRange: editor.selectedRange())
        XCTAssertNotNil(session.engine.slashSession)
        let controls = try XCTUnwrap(chrome?.controls)
        followupSwitch(panel, to: .tasks)
        XCTAssertNil(session.engine.slashSession, "the overlay must stop taking clicks on another page")
        let before = session.engine.document()
        controls.pickSlash(.table)
        XCTAssertEqual(session.engine.document(), before, "a queued slash click cannot insert on hidden Notes")
    }

    func testFollowupNotesTaskRouteKeepsItsWarmOwnerButUnmountsNativeInput() async throws {
        let (panel, _, _) = try await followupNotes()
        let task = try XCTUnwrap(panel.store.commit([TaskDraft(title: "Task note")])?.first)
        panel.uiState.openTaskNote(task.id, from: .notes, backTitle: "Back to Notes")
        spin(until: { panel.noteDraft.pages.taskNotePresenter?.host.textView.window != nil })
        let presenter = try XCTUnwrap(panel.noteDraft.pages.taskNotePresenter)
        let editor = presenter.host.textView
        XCTAssertNotNil(editor.window)
        followupSwitch(panel, to: .tasks)
        XCTAssertTrue(panel.uiState.builtPages.contains(.notes))
        // The outgoing page's spring may retain its native hierarchy until it settles.
        spin(until: { editor.window == nil })
        XCTAssertNil(editor.window, "the task-note route retains its original native unmount boundary")
        XCTAssertNotNil(presenter.lease, "the pre-existing warm workspace owner stays retained")
        followupSwitch(panel, to: .notes)
        spin(until: { editor.window != nil })
        XCTAssertTrue(panel.noteDraft.pages.taskNotePresenter === presenter)
        XCTAssertTrue(presenter.host.textView === editor, "the composed task editor is already warm")
        XCTAssertNotNil(editor.window)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func hide(_ panel: Panel) {
        var hidden = false
        _ = panel.controller.requestHide { hidden = $0 == .hidden }
        spin(until: { hidden })
        XCTAssertTrue(hidden)
    }

    func testNativePanelAndIslandStayActiveWithoutChangingKeyboardOwnership() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let rig = try makePanel()
        XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
        spin(0.3)
        let panel = rig.controller.panelForTesting
        let island = rig.controller.islandWindowsForTesting.island
        func appearance(_ window: NSWindow) throws -> Bool {
            let selector = NSSelectorFromString("_hasActiveAppearance")
            let method = try XCTUnwrap(class_getInstanceMethod(type(of: window), selector))
            typealias Read = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Read.self)(window, selector)
        }
        // The released keyboard state still changes. Native appearance must
        // stay active through it without acquiring or moving the keyboard.
        let key = panel.isKeyWindow, islandKey = island.isKeyWindow
        let responder = panel.firstResponder
        let active = NSRunningApplication.current.isActive
        for releasedLook in [false, true, false] {
            rig.uiState.setPanelKey(releasedLook)
            XCTAssertTrue(try appearance(panel), "glass stays active before and after release")
            XCTAssertTrue(try appearance(island), "the island agrees independently of keyboard state")
            XCTAssertEqual(panel.isKeyWindow, key)
            XCTAssertEqual(island.isKeyWindow, islandKey)
            XCTAssertTrue(panel.firstResponder === responder)
            XCTAssertEqual(NSRunningApplication.current.isActive, active)
        }
    }

    func testBG61NewHideAfterRevealOwnsItsOwnCompletion() async throws {
        let rig = try makePanel()
        XCTAssertEqual(rig.monitor.revealProgrammatically(section: .calendar), .shown)
        spin(0.5)
        let writer = CalendarProHeldWriter(start: Date(timeIntervalSince1970: 1_793_361_600))
        let rows = CalendarEventRowState(makeWriter: { writer })
        await rows.toggle(writer.event)
        rows.title = "Save before hiding"
        writer.hold = true
        CalendarDraftTerminationRegistry.shared.register(rows, owner: .docked)
        var first: [PanelHideCompletion] = [], second: [PanelHideCompletion] = []
        XCTAssertTrue(rig.controller.requestHide { first.append($0) }.isAccepted)
        for _ in 0..<200 where writer.gate == nil { try await Task.sleep(for: .milliseconds(10)) }
        let gate = try XCTUnwrap(writer.gate)
        XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
        XCTAssertTrue(rig.controller.requestHide { second.append($0) }.isAccepted)
        gate.resume(); writer.gate = nil; writer.hold = false
        for _ in 0..<200 where second.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first, [.superseded], "the original save no longer owns a hide")
        XCTAssertEqual(second, [.hidden], "a later hide still completes exactly once")
        XCTAssertFalse(rig.controller.isPanelVisible)
        XCTAssertEqual(writer.editCalls, 1, "the new hide waits for the committed edit")
    }

    func testBG61RevealingDuringCalendarSaveSupersedesTheOldHide() async throws {
        for error: CalendarEventWriteError? in [nil, .eventChanged] {
            let rig = try makePanel()
            XCTAssertEqual(rig.monitor.revealProgrammatically(section: .calendar), .shown)
            spin(0.5)
            let writer = CalendarProHeldWriter(start: Date(timeIntervalSince1970: 1_793_361_600))
            let rows = CalendarEventRowState(makeWriter: { writer })
            await rows.toggle(writer.event)
            rows.title = "Changed while open"
            writer.hold = true
            writer.error = error
            CalendarDraftTerminationRegistry.shared.register(rows, owner: .docked)
            var outcome: PanelHideCompletion?
            XCTAssertTrue(rig.controller.requestHide { outcome = $0 }.isAccepted)
            for _ in 0..<200 where writer.gate == nil { try await Task.sleep(for: .milliseconds(10)) }
            let gate = try XCTUnwrap(writer.gate)
            // New presentation intent while the earlier durable write is held.
            XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
            gate.resume()
            writer.gate = nil
            writer.hold = false
            for _ in 0..<200 where rows.busy { try await Task.sleep(for: .milliseconds(10)) }
            spin(0.5)
            XCTAssertEqual(outcome, .superseded)
            XCTAssertTrue(rig.controller.isPanelVisible, "a completed old save cannot hide the explicit reveal")
            XCTAssertEqual(rig.uiState.selectedSection, .tasks, "an old failure cannot select Calendar over newer intent")
            // Keep the failed draft until explicit recovery, then let tearDown close.
            if error != nil {
                XCTAssertEqual(rows.title, "Changed while open")
                writer.error = nil
                _ = await rows.close()
            }
        }
    }

    func testActivationDuringAndAfterAHideNeverSupersedesTheHide() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        for pinned in [false, true] {
            let rig = try makePanel()
            XCTAssertEqual(rig.monitor.revealProgrammatically(section: .tasks), .shown)
            spin(0.8)
            rig.uiState.isPanelPinned = pinned
            var result: PanelHideCompletion?
            let hides = rig.uiState.hideCount
            _ = rig.controller.requestHide { result = $0 }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            spin(until: { result != nil })
            XCTAssertEqual(result, .hidden, "activation must not invalidate the accepted hide")
            XCTAssertFalse(rig.controller.isPanelVisible)
            XCTAssertEqual(rig.uiState.hideCount, hides + 1)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            spin(0.1)
            XCTAssertFalse(rig.controller.isPanelVisible, "late activation cannot restore hidden presentation")
            XCTAssertEqual(rig.uiState.hideCount, hides + 1)
        }
    }

    // MARK: Agent `show` over the real panel

    /// A canvas text editor sets no interaction lock; `show` must still see
    /// it and move nothing: not the page, not the board.
    func testShowNeverInterruptsAnActiveCanvasTextEditor() throws {
        let panel = try makePanel()
        let first = try XCTUnwrap(panel.canvasSession.createCanvas(name: "First"))
        let second = try XCTUnwrap(panel.canvasSession.createCanvas(name: "Second"))
        XCTAssertTrue(panel.canvasSession.selectCanvas(first.id))
        panel.uiState.selectSection(.canvas)
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .canvas), .shown)
        panel.uiState.setPanelKey(true)

        // A real canvas editor holding the keyboard in a visible window.
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = CanvasSemanticTextEditor(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        editor.onCommit = { true }
        window.contentView?.addSubview(editor)
        window.orderFrontRegardless()
        XCTAssertTrue(window.makeFirstResponder(editor))
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
        }
        XCTAssertNotNil(CanvasSemanticTextEditor.focusedInVisibleWindow)
        XCTAssertTrue(panel.presenter.isUserTypingInPanel)

        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        let reply = try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]])
        XCTAssertTrue(reply.hasPrefix("Not shown: the user is typing"), reply)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, first.id, "the board did not change under the editor")
        XCTAssertEqual(try tools.call(name: "show", arguments: ["page": "tasks"]).hasPrefix("Not shown"), true)
        XCTAssertEqual(panel.uiState.selectedSection, .canvas, "the page did not change under the editor")

        // Once the editor lets go, the same request shows the board.
        window.makeFirstResponder(nil)
        XCTAssertNil(CanvasSemanticTextEditor.focusedInVisibleWindow)
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]]),
                       "Shown: the canvas.")
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, second.id)
    }

    /// A Notes draft that cannot be saved refuses the page change. `show`
    /// reports that as a failure, and nothing moved: the page, the board
    /// (selected only after its page shows) and the draft are untouched.
    func testShowReportsARefusedNotesCloseAndChangesNothing() throws {
        let panel = try makePanel()
        let first = try XCTUnwrap(panel.canvasSession.createCanvas(name: "First"))
        let second = try XCTUnwrap(panel.canvasSession.createCanvas(name: "Second"))
        XCTAssertTrue(panel.canvasSession.selectCanvas(first.id))
        panel.uiState.selectSection(.notes)
        panel.noteDraft.pages.start()
        XCTAssertTrue(panel.noteDraft.pages.newNote())
        XCTAssertTrue(try XCTUnwrap(panel.noteDraft.pages.active).engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Keep this draft"), name: "Type"))
        panel.gate.shouldFail = true

        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        for arguments: [String: Any] in [["page": "tasks"], ["item": ["kind": "canvas", "id": second.id.uuidString]]] {
            XCTAssertThrowsError(try tools.call(name: "show", arguments: arguments)) { error in
                let message = (error as? AgentToolError)?.message ?? ""
                XCTAssertTrue(message.hasPrefix("Not shown: the note open in Attic could not be saved"), message)
            }
        }
        XCTAssertEqual(panel.uiState.selectedSection, .notes)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, first.id, "a refused reveal selects no board")
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "nothing was revealed")
        XCTAssertNotNil(panel.noteDraft.pages.active)
        XCTAssertEqual(panel.noteDraft.pages.active?.engine.plainText, "Keep this draft")

        // Saving works again: the same request shows the board.
        panel.gate.shouldFail = false
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "canvas", "id": second.id.uuidString]]),
                       "Shown: the canvas.")
        XCTAssertEqual(panel.uiState.selectedSection, .canvas)
        XCTAssertEqual(panel.canvasSession.selectedCanvasID, second.id)
        XCTAssertTrue(panel.controller.isVisibleForPerformanceProbe)
        XCTAssertFalse(panel.uiState.isPanelKey, "an agent's show never takes the keyboard")
    }

    func testShowOfATaskAsksTheTasksPageToSelectIt() throws {
        let panel = try makePanel()
        let task = try XCTUnwrap(panel.store.create(title: "Parked", status: .backlog))
        let tools = AgentShellTools()
        tools.presenter = panel.presenter
        XCTAssertEqual(try tools.call(name: "show", arguments: ["item": ["kind": "task", "id": task.id.uuidString]]),
                       "Shown: the task “Parked” on the Tasks page.")
        XCTAssertEqual(panel.uiState.selectedSection, .backlog)
        XCTAssertEqual(panel.uiState.shownItem, AtticItemRef(.task, task.id))
        XCTAssertThrowsError(try tools.call(name: "show", arguments: ["item": ["kind": "task", "id": UUID().uuidString]]))
    }

    // MARK: Click-through on a stationary reveal

    /// The pointer monitor starts before the panel is on screen; a pointer
    /// resting in the corner wedge sends no event. Ordering front resamples,
    /// so the wedge passes clicks through and blank surface keeps them.
    func testAStationaryRevealResamplesClickThrough() throws {
        let panel = try makePanel()
        let screen = try XCTUnwrap(NSScreen.main)
        // Where the panel docks: learned from one reveal, then hidden again.
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        let expected = panel.controller.visibleContentFrameForTesting
        hide(panel)
        // The docked corner's wedge: inside the window, outside the squircle.
        let wedge = CGPoint(x: expected.maxX - 2, y: expected.maxY - 2)
        let blank = CGPoint(x: expected.midX, y: expected.midY)
        panel.controller.pointerLocation = { wedge }
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        XCTAssertTrue(panel.controller.ignoresMouseEventsForTesting, "a click in the corner wedge reaches the app behind")
        spin(0.4)
        XCTAssertTrue(panel.controller.ignoresMouseEventsForTesting, "still after the reveal animation settles")

        hide(panel)
        panel.controller.pointerLocation = { blank }
        XCTAssertTrue(panel.controller.show(on: screen, corner: .topRight))
        XCTAssertFalse(panel.controller.ignoresMouseEventsForTesting, "a click on blank painted surface stays in Attic")
    }

    // MARK: Released when hidden, retried when work finishes

    func testASkippedReleaseIsRetriedWhenTheImportFinishes() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.uiState.selectSection(.canvas)
        panel.controller.show(on: screen, corner: .topRight)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)

        // An import is in flight when the panel hides and at the deadline.
        panel.uiState.setInteractionLock(.notesImport, isActive: true)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded, "the deadline skipped the release: an import is in flight")
        XCTAssertTrue(panel.controller.hasPendingPageReleaseRetryForTesting)

        // Its completion releases the pages, with no timer.
        panel.uiState.setInteractionLock(.notesImport, isActive: false)
        spin(until: { !panel.uiState.isPageContentLoaded })
        XCTAssertFalse(panel.uiState.isPageContentLoaded, "the release ran when the import finished")
        XCTAssertFalse(panel.controller.hasPendingPageReleaseRetryForTesting)
    }

    func testAReleaseWaitingOnAPlacementRetriesWhenItEndsAndARevealCancelsIt() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        let screen = try XCTUnwrap(NSScreen.main)
        panel.uiState.selectSection(.canvas)
        panel.controller.show(on: screen, corner: .topRight)
        panel.canvasSession.prepareShapePlacement(.rectangle)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        XCTAssertTrue(panel.controller.hasPendingPageReleaseRetryForTesting)

        // A reveal cancels the waiting release: a visible panel keeps its pages.
        panel.controller.show(on: screen, corner: .topRight)
        XCTAssertFalse(panel.controller.hasPendingPageReleaseRetryForTesting)
        panel.canvasSession.cancelPendingPlacement()
        spin(0.2)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)

        // Hidden again with the placement pending, then it ends.
        panel.canvasSession.prepareShapePlacement(.rectangle)
        hide(panel)
        spin(0.4)
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        panel.canvasSession.cancelPendingPlacement()
        spin(until: { !panel.uiState.isPageContentLoaded })
        XCTAssertFalse(panel.uiState.isPageContentLoaded)
    }

    // MARK: Pages kept built

    /// A page shown during this reveal stays built behind the current one,
    /// so switching back only shows it. Notes starts on its first real visit,
    /// then stays built too. The hidden release frees background pages.
    func testShownPagesStayBuiltBehindTheCurrentOneUntilTheHiddenRelease() throws {
        let panel = try makePanel()
        let delay = AtticPanelController.pageReleaseDelay
        AtticPanelController.pageReleaseDelay = 0.1
        defer { AtticPanelController.pageReleaseDelay = delay }
        panel.controller.show(on: try XCTUnwrap(NSScreen.main), corner: .topRight)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks])
        panel.uiState.selectSection(.canvas)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas])
        panel.uiState.selectSection(.notes)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas, .notes])
        panel.uiState.selectSection(.tasks)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas, .notes], "Notes stays built after its first real visit")
        panel.uiState.prepareBuiltPage(.notes)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks, .canvas, .notes])

        hide(panel)
        spin(until: { panel.uiState.builtPages == [.tasks] })
        XCTAssertEqual(panel.uiState.builtPages, [.tasks], "the hidden release frees the pages kept behind Tasks")
        XCTAssertTrue(panel.uiState.isPageContentLoaded, "Tasks stays built")
    }

    func testTheTasksPageIsBuiltOnceTheAppIsIdleAfterLaunch() throws {
        let panel = try makePanel()
        XCTAssertFalse(panel.uiState.isPageContentLoaded)
        panel.controller.buildTasksPageWhenIdle(after: 0)
        spin(until: { panel.uiState.isPageContentLoaded })
        XCTAssertTrue(panel.uiState.isPageContentLoaded)
        XCTAssertEqual(panel.uiState.builtPages, [.tasks])
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "built while hidden")

        let other = try makePanel()
        other.uiState.selectSection(.canvas)
        other.controller.buildTasksPageWhenIdle(after: 0)
        spin(0.2)
        XCTAssertFalse(other.uiState.isPageContentLoaded, "a heavy page is never built ahead")
    }

    // MARK: Key state, haptics

    /// The older glass controls (Notes, Canvas, subtask and attachment
    /// controls) keep real glass before a click, as the shell does;
    /// Reduce Transparency remains opaque either way.
    func testOlderGlassControlsStayGlassWithoutThePanelsKeyboard() {
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: true)), .nativeGlass)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(
            reduceTransparency: false, controls: PanelKeyTreatment.controls(isPanelKey: false)), .nativeGlass)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .liquidGlass), .opaque)
        XCTAssertEqual(AtticGlassControlTreatment.resolve(reduceTransparency: true, controls: .craft), .opaque)
    }

    /// Swipe to close works pinned too (owner, 2026-10-02): the pull's request
    /// hides the panel, tells the hover monitor (which then needs the pointer
    /// to leave the hotspot before a reveal: `CornerHoverStateMachineTests`'
    /// `testInteractiveForceHide...`), and leaves the pin as it was.
    func testAPinnedPanelClosesOnAPullAndStaysPinned() throws {
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks), .shown)
        spin(until: { panel.controller.isVisibleForPerformanceProbe })
        panel.uiState.isPanelPinned = true
        var completions = 0
        let original = panel.controller.onInteractiveHideCompleted
        panel.controller.onInteractiveHideCompleted = { completions += 1; original?() }

        panel.controller.panelForTesting.onTrackpadDismissRequest?()
        spin(until: { !panel.controller.isVisibleForPerformanceProbe })

        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "a pinned panel closes on a fresh pull")
        XCTAssertEqual(completions, 1, "the hover monitor is told, so it does not re-show the panel at once")
        XCTAssertTrue(panel.uiState.isPanelPinned, "closing by swipe does not change the pin")
        spin(0.6)
        XCTAssertFalse(panel.controller.isVisibleForPerformanceProbe, "and it stays hidden")
    }

    func testThePanelFollowsTheHapticsSetting() throws {
        let suite = "PanelIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.panelHapticsEnabled)
        settings.hapticsEnabled = false
        XCTAssertFalse(settings.panelHapticsEnabled)
    }

    /// A11y hunt: inspect the actual hosted AX tree after switching pages.
    /// Unnamed buttons and fields are unusable with VoiceOver even when the
    /// icon or placeholder makes their purpose clear to a sighted user.
    func testA11yInteractiveControlsAreNamedOnEveryPage() throws {
        let previousDraw = AtticDraw.enabledOverride
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = previousDraw }
        DrawPageModel.shared.closeFilter()
        let panel = try makePanel()
        _ = panel.store.create(title: "Accessible task")
        guard case .success = panel.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Accessible note")])) else {
            return XCTFail("seed a note")
        }
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: true), .shown)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
                                  "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXLink"]
        for page in PanelPage.allCases {
            panel.uiState.selectSection(page.section)
            spin(0.35)
            let root = try XCTUnwrap(panel.controller.panelForTesting.contentView)
            var visited = Set<ObjectIdentifier>()
            var missing: [String] = []
            var named = 0
            var exposedIDs = Set<String>()
            func walk(_ node: AnyObject) {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return }
                if let identifier = node.accessibilityIdentifier?(), !identifier.isEmpty {
                    exposedIDs.insert(identifier)
                }
                if let role = node.accessibilityRole?()?.rawValue, roles.contains(role) {
                    let label = node.accessibilityLabel?()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let identifier = node.accessibilityIdentifier?() ?? ""
                    if label.isEmpty { missing.append("\(role) id=\(identifier)") }
                    else { named += 1 }
                }
                for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject) }
            }
            walk(root)
            print("A11Y_TREE page=\(page.rawValue) named=\(named) missing=\(missing)")
            XCTAssertGreaterThan(named, 0, "the hosted \(page.title) tree contains reachable controls")
            XCTAssertTrue(missing.isEmpty, "\(page.title): unnamed AX controls: \(missing)")
            if page == .canvas {
                XCTAssertFalse(exposedIDs.contains("draw-title-filter"),
                               "the closed Draw menu's prepared native field must not be in VoiceOver's tree")
                DrawPageModel.shared.openFilter()
                spin(0.3)
                visited.removeAll()
                exposedIDs.removeAll()
                missing.removeAll()
                walk(root)
                XCTAssertTrue(exposedIDs.contains("draw-title-filter"),
                              "opening Draw's canvas menu exposes its native search field")
                XCTAssertTrue(missing.isEmpty, "the open Draw filter needs a spoken label: \(missing)")
                DrawPageModel.shared.closeFilter()
            }
        }
    }

    /// The island is a separate hosted window. Its resting dots are still
    /// labelled page buttons to VoiceOver, and page selection is spoken.
    func testA11yIslandControlsStayNamedAndExposeSelection() throws {
        let previousDraw = AtticDraw.enabledOverride
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = previousDraw }
        let panel = try makePanel()
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: true), .shown)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let island = try XCTUnwrap(panel.controller.islandWindowsForTesting.island.contentView)
        func elements(_ root: AnyObject, visited: inout Set<ObjectIdentifier>) -> [AnyObject] {
            guard visited.insert(ObjectIdentifier(root)).inserted else { return [] }
            var all: [AnyObject] = [root]
            for child in (root.accessibilityChildren?() ?? nil) ?? [] {
                all.append(contentsOf: elements(child as AnyObject, visited: &visited))
            }
            return all
        }
        func element(_ id: String) -> AnyObject? {
            var seen = Set<ObjectIdentifier>()
            return elements(island, visited: &seen).first { $0.accessibilityIdentifier?() == id }
        }
        func externalElement(_ identifier: String) -> AXUIElement? {
            func search(_ node: AXUIElement, depth: Int) -> AXUIElement? {
                guard depth < 28 else { return nil }
                var id: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXIdentifierAttribute as CFString, &id) == .success,
                   id as? String == identifier { return node }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success else {
                    return nil
                }
                for child in (children as? [AXUIElement]) ?? [] {
                    if let match = search(child, depth: depth + 1) { return match }
                }
                return nil
            }
            return search(AXUIElementCreateApplication(getpid()), depth: 0)
        }
        for page in PanelPage.allCases {
            panel.uiState.selectSection(page.section)
            spin(0.13)
            let choice = try XCTUnwrap(element(page.accessibilityIdentifier), "island must expose \(page.title)")
            XCTAssertEqual(choice.accessibilityRole?()?.rawValue, "AXButton")
            XCTAssertEqual(choice.accessibilityLabel?(), page.title)
            let exposedChoice = try XCTUnwrap(externalElement(page.accessibilityIdentifier),
                                              "island page is visible through the external AX client API")
            var rawSelected: CFTypeRef?
            let selectionError = AXUIElementCopyAttributeValue(exposedChoice, kAXSelectedAttribute as CFString, &rawSelected)
            let selectedAttribute = rawSelected as? Bool
            var rawValue: CFTypeRef?
            let valueError = AXUIElementCopyAttributeValue(exposedChoice, kAXValueAttribute as CFString, &rawValue)
            let value = rawValue as? String
            let selected = selectedAttribute == true || value == "Selected"
            print("A11Y_ISLAND page=\(page.rawValue) selected=\(selected) selectionError=\(selectionError.rawValue) valueError=\(valueError.rawValue) value=\(String(describing: value))")
            XCTAssertTrue(selected, "the current island page must announce selection")
        }
        let settings = try XCTUnwrap(element("panel-island-settings"), "Settings in island's AX tree")
        XCTAssertEqual(settings.accessibilityRole?()?.rawValue, "AXButton")
        XCTAssertEqual(settings.accessibilityLabel?(), "Settings")
    }

    /// A reproducible keyboard-only hunt through the hosted panel. Every
    /// generated action checks the current accessibility tree, including
    /// the retained pages while the current page changes. No system keyboard
    /// preferences are changed on the shared Air host.
    func testA11ySeededKeyboardNavigationKeepsVisibleControlsNamed() throws {
        struct Random {
            var state: UInt64
            mutating func next() -> UInt64 {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                return state
            }
        }
        let previousDraw = AtticDraw.enabledOverride
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = previousDraw }
        DrawPageModel.shared.closeFilter()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
                                  "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXLink"]
        let stepsPerSeed = 320
        for seed in [UInt64(0xA11E_1201), UInt64(0xA11E_1202)] {
            var random = Random(state: seed)
            let panel = try makePanel()
            _ = panel.store.create(title: "Keyboard task")
            guard case .success = panel.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Keyboard note")])) else {
                return XCTFail("seed the Notes library")
            }
            XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: true), .shown)
            let window = panel.controller.panelForTesting
            let root = try XCTUnwrap(window.contentView)
            func event(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                window.sendEvent(key)
            }
            func elements() -> [AnyObject] {
                var seen = Set<ObjectIdentifier>()
                func walk(_ node: AnyObject) -> [AnyObject] {
                    guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                    return [node] + ((node.accessibilityChildren?() ?? nil) ?? []).flatMap { walk($0 as AnyObject) }
                }
                return walk(root)
            }
            for step in 0..<stepsPerSeed {
                let action = Int(random.next() % 10)
                if !window.isVisible {
                    _ = panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: true)
                    spin(0.06)
                }
                switch action {
                case 0...3:
                    panel.uiState.selectSection(PanelPage.allCases[action].section)
                case 4: try event("\t", keyCode: 48)
                case 5: try event("\t", keyCode: 48, modifiers: .shift)
                case 6:
                    if panel.uiState.isComposerPresented { try event("\u{1b}", keyCode: 53) }
                    else { panel.uiState.selectSection(.tasks) }
                case 7: try event("\r", keyCode: 36)
                case 8:
                    let plus = panel.uiState.selectedSection == .tasks ? "tasks-new-task" :
                        panel.uiState.selectedSection == .notes ? "notes-new-note" : ""
                    if let button = elements().first(where: { $0.accessibilityIdentifier?() == plus }) {
                        _ = button.accessibilityPerformPress?()
                    }
                default:
                    let page = PanelPage.allCases[Int(random.next() % UInt64(PanelPage.allCases.count))]
                    panel.uiState.selectSection(page.section)
                }
                spin(0.04)
                guard window.isVisible else { continue }
                let current = panel.uiState.selectedSection
                let ax = elements()
                let interactive = ax.filter { roles.contains($0.accessibilityRole?()?.rawValue ?? "") }
                let missing = interactive.filter {
                    ($0.accessibilityLabel?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.map { "\($0.accessibilityRole?()?.rawValue ?? "?") \($0.accessibilityIdentifier?() ?? "")" }
                guard !interactive.isEmpty, missing.isEmpty else {
                    return XCTFail("seed=\(seed) step=\(step) action=\(action) page=\(current): interactive=\(interactive.count) missing=\(missing)")
                }
                let ids = Set(ax.compactMap { $0.accessibilityIdentifier?() })
                if current != .tasks, ids.contains("tasks-new-task") {
                    return XCTFail("seed=\(seed) step=\(step): a hidden Tasks page remains in AX")
                }
                if current != .notes, ids.contains("notes-new-note") {
                    return XCTFail("seed=\(seed) step=\(step): a hidden Notes page remains in AX")
                }
                if current == .canvas, !DrawPageModel.shared.isFiltering, ids.contains("draw-title-filter") {
                    return XCTFail("seed=\(seed) step=\(step): closed Draw filter remains in AX")
                }
                if let nativeFocus = (window.firstResponder as? NSTextView)?.delegate as? NSView
                    ?? window.firstResponder as? NSView,
                   nativeFocus.window === window,
                   nativeFocus.isHiddenOrHasHiddenAncestor {
                    return XCTFail("seed=\(seed) step=\(step): keyboard focus belongs to a hidden native view")
                }
            }
            print("A11Y_SEEDED seed=\(seed) steps=\(stepsPerSeed) keyboard=Tab,Shift-Tab,Escape,Return,AXPress")
        }
    }

    /// A native focused view can become hidden while handling a Tab key,
    /// such as when SwiftUI swaps a retained page during keyboard travel.
    /// The window must not leave that hidden view owning the next keystroke.
    func testKeyboardTraversalDoesNotKeepFocusInViewHiddenDuringKeyDispatch() throws {
        final class NativeEditor: NSTextView {
            weak var ownerView: NSView?
            var receivedTab = false
            override func keyDown(with event: NSEvent) {
                if event.keyCode == 48 {
                    receivedTab = true
                    // AppKit's field editor stays live when its SwiftUI
                    // delegate leaves the visible page.
                    ownerView?.isHidden = true
                } else { super.keyDown(with: event) }
            }
        }
        final class EditorOwner: NSView, NSTextViewDelegate {}
        let window = AtticPanel(contentRect: CGRect(x: -6_000, y: -6_000, width: 200, height: 100),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let owner = EditorOwner(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        let editor = NativeEditor(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        editor.ownerView = owner
        editor.delegate = owner
        root.addSubview(owner)
        root.addSubview(editor)
        window.contentView = root
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                        isARepeat: false, keyCode: 48))
        window.sendEvent(tab)
        XCTAssertTrue(editor.receivedTab, "Tab reached the active native control")
        XCTAssertTrue(owner.isHiddenOrHasHiddenAncestor, "the native editor's owner became hidden")
        let focusTarget = (window.firstResponder as? NSTextView)?.delegate as? NSView
            ?? window.firstResponder as? NSView
        XCTAssertFalse(focusTarget?.isHiddenOrHasHiddenAncestor == true,
                       "keyboard focus must leave a hidden native control")
    }
}
