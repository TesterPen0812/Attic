import AppKit
import Combine
import ObjectiveC
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
    func testNativeChromeStartsWithBodyAndKeepsTopRowFixed() throws {
        let state = PanelUIState()
        state.loadPageContent()
        let width = state.panelSize.width
        let outgoing = PanelNativePageHostingView(rootView: AnyView(Text("Tasks page")))
        let incoming = PanelNativePageHostingView(rootView: AnyView(Text("Notes page")))
        outgoing.wantsLayer = true
        incoming.wantsLayer = true
        let window = slideTestWindow(outgoing, incoming, width: width)
        defer { window.contentView = nil; window.close() }
        let driver = state.nativePageSlide
        driver.register(outgoing, page: .tasks, selected: .tasks, width: width)
        driver.register(incoming, page: .notes, selected: .tasks, width: width)

        let outgoingTop = PanelNativeChromeHostingView(rootView: AnyView(Text("Tasks header")))
        let incomingTop = PanelNativeChromeHostingView(rootView: AnyView(Text("Notes header")))
        let outgoingBar = PanelNativeChromeHostingView(rootView: AnyView(Text("Tasks bar")))
        let incomingBar = PanelNativeChromeHostingView(rootView: AnyView(Text("Notes bar")))
        let chromeContainer = try XCTUnwrap(window.contentView)
        // A test must not add NSHostingView children directly to an
        // NSHostingView; production installs them with NSViewRepresentable.
        for (page, kind, host) in [
            (PanelPage.tasks, PanelNativePageSlide.ChromeKind.topRow, outgoingTop),
            (.notes, .topRow, incomingTop),
            (.tasks, .bottomBar, outgoingBar),
            (.notes, .bottomBar, incomingBar)
        ] {
            host.wantsLayer = true
            host.frame = CGRect(x: 0, y: 0, width: width, height: 42)
            chromeContainer.addSubview(host)
            driver.registerChrome(host, page: page, kind: kind, selected: .tasks)
        }

        let motion = PanelPageMotion.current(reduceMotion: false)
        state.switchPage(to: .notes, motion: motion)
        let body = try XCTUnwrap(outgoing.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        let incomingBody = try XCTUnwrap(incoming.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        let counter = try XCTUnwrap(outgoingTop.layer?.animation(forKey: "AtticNativeChromeCounterTravel") as? CAKeyframeAnimation)
        let arrives = try XCTUnwrap(incomingTop.layer?.animation(forKey: "AtticNativeChromeCounterTravel") as? CAKeyframeAnimation)
        let headerFade = try XCTUnwrap(incomingTop.layer?.animation(forKey: "AtticNativeChromeOpacity") as? CABasicAnimation)
        let oldBarFade = try XCTUnwrap(outgoingBar.layer?.animation(forKey: "AtticNativeChromeOpacity") as? CABasicAnimation)
        let newBarFade = try XCTUnwrap(incomingBar.layer?.animation(forKey: "AtticNativeChromeOpacity") as? CABasicAnimation)
        let travel = try XCTUnwrap(body.values as? [NSNumber]).map(\.doubleValue)
        let inverse = try XCTUnwrap(counter.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(travel.count, inverse.count)
        for (pageX, headerX) in zip(travel, inverse) {
            // The sampled SwiftUI spring can accumulate <0.01 pt floating
            // point error when its endpoints are inverted independently.
            // Even the allowed 0.02 pt is under one twentieth of a pixel.
            XCTAssertEqual(pageX + headerX, 0, accuracy: 0.02,
                           "The Tasks header must never travel under the pin")
        }
        let incomingTravel = try XCTUnwrap(incomingBody.values as? [NSNumber]).map(\.doubleValue)
        let incomingInverse = try XCTUnwrap(arrives.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(incomingTravel.count, incomingInverse.count)
        for (pageX, headerX) in zip(incomingTravel, incomingInverse) {
            XCTAssertEqual(pageX + headerX, 0, accuracy: 0.02,
                           "The arriving header must remain fixed through the native spring")
        }
        XCTAssertEqual(body.duration, counter.duration, accuracy: 0.000_001)
        XCTAssertEqual(headerFade.duration, PanelPageMotion.fadeIn, accuracy: 0.000_001)
        XCTAssertEqual(oldBarFade.duration, PanelPageMotion.fadeOut, accuracy: 0.000_001)
        XCTAssertEqual(newBarFade.duration, PanelPageMotion.fadeIn, accuracy: 0.000_001)
        XCTAssertEqual(outgoingTop.layer?.opacity, 0,
                       "The old header must be gone before body motion begins")
        XCTAssertEqual(incomingTop.layer?.opacity, 1,
                       "The new header must already be in place when motion begins")
        XCTAssertEqual(headerFade.beginTime + headerFade.duration,
                       arrives.beginTime, accuracy: 0.001,
                       "The header must complete its original fade before native motion")
        XCTAssertFalse(outgoingTop.acceptsPageInput)
        XCTAssertFalse(outgoingBar.acceptsPageInput)
        XCTAssertTrue(incomingTop.acceptsPageInput)
        XCTAssertTrue(incomingBar.acceptsPageInput)
        state.panelDidHide()
        XCTAssertNil(outgoingTop.layer?.animation(forKey: "AtticNativeChromeCounterTravel"))
        XCTAssertNil(incomingBar.layer?.animation(forKey: "AtticNativeChromeOpacity"))
    }

    func testNativeSlideStartsWithLayerAndTransfersInputBeforeViewUpdate() throws {
        let state = PanelUIState()
        state.loadPageContent()
        let outgoing = PanelNativePageHostingView(rootView: AnyView(Text("Tasks")))
        let incoming = PanelNativePageHostingView(rootView: AnyView(Text("Notes")))
        outgoing.wantsLayer = true
        incoming.wantsLayer = true
        let width = state.panelSize.width
        let window = slideTestWindow(outgoing, incoming, width: width)
        defer { window.contentView = nil; window.close() }
        state.nativePageSlide.register(outgoing, page: .tasks, selected: .tasks, width: width)
        state.nativePageSlide.register(incoming, page: .notes, selected: .tasks, width: width)

        state.switchPage(to: .notes, motion: PanelPageMotion.current(reduceMotion: false))
        // The model changes synchronously. The native layers must already
        // have their spring, before SwiftUI gets another render pass.
        XCTAssertEqual(state.selectedSection, .notes)
        let departing = try XCTUnwrap(outgoing.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        XCTAssertNotNil(incoming.layer?.animation(forKey: "AtticNativePageSlide"))
        // The native NSHostingView may re-layout its model layer while the
        // presentation animation is in flight. Assert its actual keyframes.
        XCTAssertEqual((departing.values?.first as? NSNumber)?.doubleValue ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual((departing.values?.last as? NSNumber)?.doubleValue ?? 0,
                       Double(-width), accuracy: 0.5)
        XCTAssertEqual(incoming.layer?.transform.m41 ?? -1, 0, accuracy: 0.5)
        XCTAssertFalse(outgoing.acceptsPageInput)
        XCTAssertTrue(incoming.acceptsPageInput)
        state.panelDidHide()
        XCTAssertNil(outgoing.layer?.animation(forKey: "AtticNativePageSlide"))
    }

    func testColdNativeSlideKeepsDepartingPageVisibleUntilDestinationIsHosted() throws {
        let state = PanelUIState()
        state.loadPageContent()
        let outgoing = PanelNativePageHostingView(rootView: AnyView(Text("Tasks")))
        outgoing.wantsLayer = true
        let width = state.panelSize.width
        let window = slideTestWindow(outgoing, width: width)
        defer { window.contentView = nil; window.close() }
        state.nativePageSlide.register(outgoing, page: .tasks, selected: .tasks, width: width)
        state.switchPage(to: .notes, motion: .current(reduceMotion: false))

        XCTAssertNil(outgoing.layer?.animation(forKey: "AtticNativePageSlide"),
                     "Without a drawn Notes host, moving Tasks would expose a blank panel")
        XCTAssertEqual(outgoing.layer?.transform.m41 ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(outgoing.layer?.opacity ?? 0, 1)
        XCTAssertFalse(outgoing.acceptsPageInput, "departing content immediately stops taking input")

        let incoming = PanelNativePageHostingView(rootView: AnyView(Text("Notes")))
        incoming.wantsLayer = true
        window.contentView?.addSubview(incoming)
        incoming.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        state.nativePageSlide.register(incoming, page: .notes, selected: .notes, width: width)
        XCTAssertNil(outgoing.layer?.animation(forKey: "AtticNativePageSlide"),
                     "Mounting the native host is earlier than the first hosted render pass")
        state.nativePageSlide.pageDidAppear(.notes)
        RunLoop.main.run(until: Date().addingTimeInterval(0.07))
        XCTAssertTrue(state.pageTransit.sliding,
                      "The outgoing Tasks page must keep drawing until the native flight settles")
        let departing = try XCTUnwrap(outgoing.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        let arriving = try XCTUnwrap(incoming.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        XCTAssertEqual((departing.values?.last as? NSNumber)?.doubleValue ?? .nan,
                       Double(-width), accuracy: 0.01)
        XCTAssertEqual((arriving.values?.first as? NSNumber)?.doubleValue ?? .nan,
                       Double(width), accuracy: 0.01)
        XCTAssertEqual((arriving.values?.last as? NSNumber)?.doubleValue ?? .nan,
                       0, accuracy: 0.01)
        XCTAssertTrue(incoming.acceptsPageInput)
        state.panelDidHide()
        XCTAssertNil(outgoing.layer?.animation(forKey: "AtticNativePageSlide"))
        XCTAssertNil(incoming.layer?.animation(forKey: "AtticNativePageSlide"))
    }

    func testNativeLayerPositionsMatchTheExistingSwiftUISpringWithinTwoPoints() throws {
        let motion = PanelPageMotion.current(reduceMotion: false)
        let spring = try XCTUnwrap(motion.spring)
        let swiftUI = Spring(duration: spring.response, bounce: spring.bounce)
        // Test both page directions: the native animation must follow the
        // same numeric oscillator as Animation.spring(duration:bounce:).
        for (from, to) in [(352.0, 0.0), (0.0, -352.0)] {
            let native = PanelNativePageSlide.swiftUISpringAnimation(spring: spring, from: from, to: to)
            let positions = try XCTUnwrap(native.values as? [NSNumber]).map(\.doubleValue)
            XCTAssertEqual(native.duration, swiftUI.settlingDuration, accuracy: 0.0001)
            for ms in [0.0, 16, 33, 50, 83, 120, 160, 250, 400] {
                let elapsed = min(ms / 1_000, native.duration)
                let i = elapsed / native.duration * Double(positions.count - 1)
                let lower = min(Int(i), positions.count - 1)
                let upper = min(lower + 1, positions.count - 1)
                let interpolation = i - Double(lower)
                let nativeX = positions[lower] + (positions[upper] - positions[lower]) * interpolation
                let swiftUIX = swiftUI.value(fromValue: from, toValue: to,
                                             initialVelocity: 0.0, time: elapsed)
                XCTAssertEqual(nativeX, swiftUIX, accuracy: 2.0, "\(ms) ms, \(from) → \(to)")
            }
        }
    }

    func testNativePageSwitchKeyframesMatchSwiftUIForThreeRoutesAndBothFeels() throws {
        let width = PanelUIState().panelSize.width
        var greatestKeyframeError: Double = 0
        var greatestCheckpointError: Double = 0
        let routes: [(from: PanelPage, to: PanelPage, direction: CGFloat)] = [
            (.tasks, .notes, 1), (.notes, .calendar, 1), (.calendar, .tasks, -1)
        ]
        for tuning in [AtticMotionTuning.lively, .subtle] {
            let motion = PanelPageMotion.current(reduceMotion: false, tuning: tuning)
            let source = AtticMotionPreset.pageSwitch.spring(in: tuning)
            let spring = try XCTUnwrap(motion.spring)
            XCTAssertEqual(spring.response, source.response * PanelPageMotion.speed, accuracy: 0.000_001)
            XCTAssertEqual(spring.bounce, source.bounce, accuracy: 0.000_001)
            let reference = Spring(duration: spring.response, bounce: spring.bounce)

            for (fromPage, toPage, direction) in routes {
                let switchModel = PanelPageSwitch(from: fromPage, to: toPage, motion: motion)
                XCTAssertEqual(toPage.side(from: fromPage), direction)
                XCTAssertEqual(switchModel.restingSide(of: toPage), direction)
                XCTAssertEqual(switchModel.restingSide(of: fromPage), -direction)

                for page in [fromPage, toPage] {
                    let oldOffset = page == fromPage
                        ? CGFloat.zero
                        : motion.restingOffset(side: switchModel.restingSide(of: page), width: width)
                    let newOffset = page == toPage
                        ? CGFloat.zero
                        : motion.restingOffset(side: switchModel.restingSide(of: page), width: width)
                    XCTAssertEqual(oldOffset, (page == fromPage ? 0 : direction * width))
                    XCTAssertEqual(newOffset, (page == toPage ? 0 : -direction * width))
                    let flight = PanelNativePageSlide.swiftUISpringAnimation(
                        spring: spring, from: Double(oldOffset), to: Double(newOffset))
                    let values = try XCTUnwrap(flight.values as? [NSNumber]).map(\.doubleValue)
                    let keyTimes = try XCTUnwrap(flight.keyTimes).map(\.doubleValue)
                    XCTAssertEqual(values.count, keyTimes.count)
                    XCTAssertGreaterThanOrEqual(values.count, Int(ceil(reference.settlingDuration * 240)) + 1)
                    XCTAssertEqual(flight.duration, motion.settleDuration, accuracy: 0.000_001)
                    XCTAssertEqual(values.first ?? .nan, Double(oldOffset), accuracy: 0.01)
                    XCTAssertEqual(values.last ?? .nan, Double(newOffset), accuracy: 0.01)

                    var worstError: Double = 0
                    for i in values.indices {
                        let t = flight.duration * keyTimes[i]
                        let expected = reference.value(fromValue: Double(oldOffset), toValue: Double(newOffset),
                                                       initialVelocity: 0, time: t)
                        worstError = max(worstError, abs(values[i] - expected))
                    }
                    greatestKeyframeError = max(greatestKeyframeError, worstError)
                    XCTAssertLessThan(worstError, 0.01,
                                      "\(fromPage)→\(toPage) \(page) max keyframe deviation \(worstError) pt")
                    for ms in [0.0, 16, 33, 50, 100, 160, 250] {
                        let elapsed = min(ms / 1_000, flight.duration)
                        let index = elapsed / flight.duration * Double(values.count - 1)
                        let lower = min(Int(index), values.count - 1)
                        let upper = min(lower + 1, values.count - 1)
                        let interpolated = values[lower] + (values[upper] - values[lower]) * (index - Double(lower))
                        let expected = reference.value(fromValue: Double(oldOffset), toValue: Double(newOffset),
                                                       initialVelocity: 0, time: elapsed)
                        greatestCheckpointError = max(greatestCheckpointError, abs(interpolated - expected))
                        XCTAssertEqual(interpolated, expected, accuracy: 0.1,
                                       "\(fromPage)→\(toPage) \(page) at \(ms) ms")
                    }
                }
            }
        }

        let reduced = PanelPageMotion.current(reduceMotion: true)
        XCTAssertFalse(reduced.travels)
        XCTAssertNil(reduced.spring)
        XCTAssertNil(reduced.animation)
        XCTAssertEqual(reduced.settleDuration, 0)
        XCTAssertEqual(reduced.restingOffset(side: 1, width: width), 0)
        let reducedDriver = PanelNativePageSlide()
        let fromHost = PanelNativePageHostingView(rootView: AnyView(Text("Tasks")))
        let toHost = PanelNativePageHostingView(rootView: AnyView(Text("Notes")))
        fromHost.wantsLayer = true
        toHost.wantsLayer = true
        let window = slideTestWindow(fromHost, toHost, width: width)
        defer { reducedDriver.cancel(); window.contentView = nil; window.close() }
        reducedDriver.register(fromHost, page: .tasks, selected: .tasks, width: width)
        reducedDriver.register(toHost, page: .notes, selected: .tasks, width: width)
        reducedDriver.begin(.init(from: .tasks, to: .notes, motion: reduced), width: width, onSettled: {})
        XCTAssertNil(fromHost.layer?.animation(forKey: "AtticNativePageSlide"))
        XCTAssertNil(toHost.layer?.animation(forKey: "AtticNativePageSlide"))
        XCTAssertFalse(fromHost.acceptsPageInput)
        XCTAssertTrue(toHost.acceptsPageInput)
        print("ATTIC_NATIVE_SLIDE_MAX_KEYFRAME_ERROR_PT \(greatestKeyframeError)")
        print("ATTIC_NATIVE_SLIDE_MAX_CHECKPOINT_ERROR_PT \(greatestCheckpointError)")
    }

    func testReturningToRetainedTasksWaitsForPagerPaintBeforeNativeSlide() throws {
        let state = PanelUIState()
        state.loadPageContent()
        state.switchPage(to: .calendar, motion: .instant)
        let outgoing = PanelNativePageHostingView(rootView: AnyView(Text("Calendar")))
        let incoming = PanelNativePageHostingView(rootView: AnyView(Text("Tasks")))
        outgoing.wantsLayer = true
        incoming.wantsLayer = true
        let width = state.panelSize.width
        let window = slideTestWindow(outgoing, incoming, width: width)
        defer { window.contentView = nil; window.close() }
        state.nativePageSlide.register(outgoing, page: .calendar, selected: .calendar, width: width)
        state.nativePageSlide.register(incoming, page: .tasks, selected: .calendar, width: width)

        state.switchPage(to: .tasks, motion: .current(reduceMotion: false))
        XCTAssertNil(outgoing.layer?.animation(forKey: "AtticNativePageSlide"))
        XCTAssertEqual(outgoing.layer?.transform.m41 ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(outgoing.layer?.opacity ?? 0, 1)
        XCTAssertTrue(state.pageTransit.sliding)
        state.nativePageSlide.pageDidBecomeCurrent(.tasks)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let departing = try XCTUnwrap(outgoing.layer?.animation(forKey: "AtticNativePageSlide") as? CAKeyframeAnimation)
        XCTAssertEqual((departing.values?.last as? NSNumber)?.doubleValue ?? .nan,
                       Double(width), accuracy: 0.01)
        XCTAssertNotNil(incoming.layer?.animation(forKey: "AtticNativePageSlide"))
        XCTAssertTrue(incoming.acceptsPageInput)
        state.panelDidHide()
    }

    private func slideTestWindow(_ hosts: PanelNativePageHostingView..., width: CGFloat) -> NSWindow {
        let offscreen = TestPresentationPolicy.offscreenFrame(
            CGRect(x: -6_000, y: -6_000, width: width, height: 400))
        let window = NSWindow(contentRect: offscreen, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        parent.wantsLayer = true
        window.contentView = parent
        for host in hosts {
            host.frame = parent.bounds
            parent.addSubview(host)
        }
        window.orderFront(nil)
        parent.layoutSubtreeIfNeeded()
        return window
    }

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

    private func makePanel() throws -> Panel {
        let suite = "PanelIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
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
}
