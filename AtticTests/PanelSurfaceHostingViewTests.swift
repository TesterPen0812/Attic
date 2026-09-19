import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class PanelSurfaceHostingViewTests: XCTestCase {
    private struct HitOwningContent: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private enum MenuGlyphTreatment {
        case untreated
        case foregroundStyleOnly
        case quiet
    }

    private enum MenuGlyphLabel {
        /// The row and toolbar menus.
        case symbol
        /// The canvas zoom readout, which is a `Text` label.
        case text
    }

    /// The panel supplies its own accent (`AtticPanelView` sets `.tint` and
    /// `.accentColor`), so the probe supplies one too: `ambient`. Nothing here
    /// reads the user's system accent, which is why this test says the same
    /// thing on every machine — previously a red or orange accent would have
    /// made the untreated case look like the requested colour.
    private struct MenuGlyphProbe: View {
        static let ambient = Color.blue
        static let requested = Color.red

        let treatment: MenuGlyphTreatment
        let label: MenuGlyphLabel

        var body: some View {
            let menu = Menu {
                Button("Action") {}
            } label: {
                switch label {
                case .symbol:
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 36)
                case .text:
                    Text("100%")
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(width: 44, height: 36)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            return Group {
                switch treatment {
                case .untreated: menu
                case .foregroundStyleOnly: menu.foregroundStyle(Self.requested)
                case .quiet: menu.atticQuietMenuGlyph(Self.requested)
                }
            }
            .frame(width: 70, height: 60)
            .background(Color.white)
            .tint(Self.ambient)
            .accentColor(Self.ambient)
        }
    }

    private struct MenuGlyphPixels {
        /// Pixels painted in the colour the probe asked for.
        let requested: Int
        /// Pixels painted in the ambient accent the probe supplied.
        let ambient: Int
    }

    private func renderedProbePixels(_ treatment: MenuGlyphTreatment,
                                     label: MenuGlyphLabel) -> MenuGlyphPixels {
        let host = NSHostingView(rootView: MenuGlyphProbe(treatment: treatment, label: label))
        host.frame = NSRect(x: 0, y: 0, width: 70, height: 60)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 70, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return MenuGlyphPixels(requested: 0, ambient: 0)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        var requested = 0, ambient = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = pixel.redComponent, g = pixel.greenComponent, b = pixel.blueComponent
                if r > g + 0.15 && r > b + 0.15 { requested += 1 }
                if b > r + 0.15 && b > g + 0.15 { ambient += 1 }
            }
        }
        return MenuGlyphPixels(requested: requested, ambient: ambient)
    }

    /// A `.borderlessButton` `Menu` renders its label through an AppKit pop-up
    /// button that paints it in the inherited tint and ignores the label's own
    /// `foregroundStyle`. That is why every such menu outside the task rows
    /// rested on the panel accent, and it is true of a `Text` label as well as
    /// a symbol — which is what the canvas zoom readout is.
    ///
    /// This pins the treatment that actually reaches the cell: it fails if
    /// `atticQuietMenuGlyph` is ever reduced to `foregroundStyle` alone, and it
    /// fails if a label stops being given a colour of its own.
    ///
    /// It asserts colour reach only. Whether the resting glyph looks right on
    /// each real surface is native UAT, as the audit's own verification says.
    func testQuietMenuGlyphIsWhatActuallyColoursABorderlessMenuLabel() {
        for label in [MenuGlyphLabel.symbol, .text] {
            let untreated = renderedProbePixels(.untreated, label: label)
            XCTAssertGreaterThan(untreated.ambient, 0,
                                 "\(label) is painted in the inherited tint when nothing claims it")
            XCTAssertEqual(untreated.requested, 0, "and never in a colour nobody asked for")

            let foregroundOnly = renderedProbePixels(.foregroundStyleOnly, label: label)
            XCTAssertEqual(foregroundOnly.requested, 0,
                           "foregroundStyle alone never reaches the pop-up button's \(label)")
            XCTAssertGreaterThan(foregroundOnly.ambient, 0,
                                 "\(label) still rests on the inherited tint")

            let quiet = renderedProbePixels(.quiet, label: label)
            XCTAssertGreaterThan(quiet.requested, 0,
                                 "atticQuietMenuGlyph must colour the \(label) itself")
            XCTAssertEqual(quiet.ambient, 0, "and must leave none of the tint behind")
        }
    }

    /// Rows dimmed under the drawer's or the panel's fixed chrome have to be
    /// inert as well: the mask only changes how they look. The shield is the
    /// one piece that makes them unclickable, and it is sized from the same
    /// band and fade the mask uses.
    func testPointerShieldsOwnTheBandsTheMaskDims() {
        let child = NSView()
        let size = CGSize(width: 272, height: 420)
        let shield = SavedNotesDrawerLayout.shieldHeight
        let host = NSHostingView(rootView: ZStack {
            HitOwningContent(view: child).frame(width: size.width, height: size.height)
            AtticPointerShield(height: shield)
                .frame(maxHeight: .infinity, alignment: .top)
            AtticPointerShield(height: shield)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000,
                                                  width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        func hit(atDistanceFromTop distance: CGFloat) -> NSView? {
            let point = CGPoint(x: size.width / 2,
                                y: host.isFlipped ? distance : size.height - distance)
            return host.hitTest(host.convert(point, to: host.superview))
        }

        // Every point a button occupies, and every point the fade covers, is
        // held by the shield rather than by a row underneath it.
        for distance in stride(from: CGFloat(2), through: shield - 2, by: 8) {
            XCTAssertFalse(hit(atDistanceFromTop: distance) === child,
                           "a row is reachable \(distance)pt under the top chrome")
            XCTAssertFalse(hit(atDistanceFromTop: size.height - distance) === child,
                           "a row is reachable \(distance)pt under the bottom chrome")
        }
        // And the workspace between them still belongs to the rows.
        for distance in stride(from: shield + 4, through: size.height - shield - 4, by: 24) {
            XCTAssertTrue(hit(atDistanceFromTop: distance) === child,
                          "a resting row lost its press at \(distance)pt")
        }
        // A degenerate measured height collapses the shield instead of making
        // the whole list inert.
        XCTAssertEqual(AtticPointerShield.shieldedHeight(shield), shield)
        XCTAssertEqual(AtticPointerShield.shieldedHeight(.nan), 0)
        XCTAssertEqual(AtticPointerShield.shieldedHeight(.infinity), 0)
        XCTAssertEqual(AtticPointerShield.shieldedHeight(-40), 0)
    }

    func testEveryHeaderPointExceptControlsRoutesToTheHost() {
        let child = NSView()
        let host = PanelSurfaceHostingView(rootView: HitOwningContent(view: child).frame(width: 272, height: 220))
        let panel = PanelSurfaceWindow(contentView: host, initialSize: CGSize(width: 272, height: 220))
        defer { panel.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let control = CGRect(x: 188, y: 16, width: 64, height: 30)
        host.dragGeometry = PanelSurfaceDragGeometry(
            headerFrame: CGRect(x: 0, y: 0, width: 272, height: 64),
            controlFrames: [control]
        )
        // A child that takes the entire surface reproduces the fragmented
        // header: routing must precede the child's native hit test.
        for y in stride(from: 4.0, through: 60.0, by: 8) {
            for x in stride(from: 4.0, through: 268.0, by: 8) {
                let point = CGPoint(x: x, y: y)
                guard Squircle.contains(point, in: host.bounds, cornerRadius: host.surfaceCornerSize,
                                        exponent: AtticStyle.panelSquircleExponent) else { continue }
                let native = host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.maxY - point.y)
                if control.contains(point) {
                    XCTAssertTrue(host.hitTest(host.convert(native, to: host.superview)) === child, "Control lost its press at \(point)")
                } else {
                    XCTAssertTrue(host.hitTest(host.convert(native, to: host.superview)) === host, "Header lost its drag at \(point)")
                }
            }
        }
        XCTAssertTrue(host.hitTest(host.convert(CGPoint(x: 120, y: 150), to: host.superview)) === child,
                      "Body controls must retain their own clicks")
    }

    func testEmptySurfaceOwnsEveryPaintedPointAcrossCornerSizes() {
        let host = PanelSurfaceHostingView(rootView: Color.clear.frame(width: 272, height: 220).allowsHitTesting(false))
        let panel = PanelSurfaceWindow(contentView: host, initialSize: CGSize(width: 272, height: 220))
        defer { panel.contentView = nil }
        host.layoutSubtreeIfNeeded()
        for radius in [CGFloat(0), 20, 60, 100] {
            host.surfaceCornerSize = radius
            for y in stride(from: 1.0, through: 219.0, by: 9) {
                for x in stride(from: 1.0, through: 271.0, by: 9) {
                    let point = CGPoint(x: x, y: y)
                    let inside = Squircle.contains(point, in: host.bounds, cornerRadius: radius,
                                                   exponent: AtticStyle.panelSquircleExponent)
                    XCTAssertEqual(host.hitTest(host.convert(point, to: host.superview)) != nil, inside,
                                   "Surface ownership disagrees with paint at \(point), radius \(radius)")
                }
            }
        }
    }

    func testUnmeasuredHeaderLeavesControlsInteractive() {
        let child = NSView()
        let host = PanelSurfaceHostingView(rootView: HitOwningContent(view: child).frame(width: 272, height: 220))
        let panel = PanelSurfaceWindow(contentView: host, initialSize: CGSize(width: 272, height: 220))
        defer { panel.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.hitTest(host.convert(CGPoint(x: 220, y: 30), to: host.superview)) === child)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
    }

    // MARK: - No task-subpanel swipe: every scroll event stays with content

    /// Records the events the window hands to AppKit; the content itself is
    /// layer-backed so a stray transform or fade would be observable.
    private struct ScrollFixture {
        let window: PanelSurfaceWindow
        let content: NSView
        let forwarded: () -> [NSEvent]
    }

    private func makeScrollFixture() -> ScrollFixture {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 272, height: 220))
        content.wantsLayer = true
        let window = PanelSurfaceWindow(contentView: content, initialSize: CGSize(width: 272, height: 220))
        addTeardownBlock { window.contentView = nil }
        var forwarded: [NSEvent] = []
        window.eventForwardingForTesting = { forwarded.append($0) }
        return ScrollFixture(window: window, content: content, forwarded: { forwarded })
    }

    private var eventTime: TimeInterval = 100

    private func scroll(_ phase: CGScrollPhase?, dx: Int32 = 0, dy: Int32 = 0,
                        momentum: CGMomentumScrollPhase = .none, precise: Bool = true,
                        flags: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: dy, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        event.flags = flags
        eventTime += 0.05
        event.timestamp = CGEventTimestamp(eventTime * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func assertSurfaceUntouched(_ fixture: ScrollFixture,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(fixture.window.contentView === fixture.content,
                      "the surface presents its content directly — no motion layer remains to transform it",
                      file: file, line: line)
        if let layer = fixture.content.layer {
            XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity),
                          "no dismissal transform remains", file: file, line: line)
            XCTAssertEqual(layer.opacity, 1, "no dismissal fade remains", file: file, line: line)
        }
    }

    /// The sequence a dismissal gesture used to be — a two-finger horizontal
    /// pan through began→changed→ended, in either direction — now scrolls the
    /// content like any other sample and leaves the surface unmoved, unfaded
    /// and presented.
    func testSwipeShapedScrollStaysWithTheContentAndNeverDismisses() throws {
        let fixture = makeScrollFixture()
        let frame = fixture.window.frame
        var sent = 0
        for direction in [Int32(20), -20] {
            fixture.window.sendEvent(try scroll(.began))
            sent += 1
            for _ in 0..<6 {
                fixture.window.sendEvent(try scroll(.changed, dx: direction))
                sent += 1
            }
            fixture.window.sendEvent(try scroll(.ended))
            sent += 1
            XCTAssertEqual(fixture.forwarded().count, sent, "every sample reaches the content")
            assertSurfaceUntouched(fixture)
            XCTAssertEqual(fixture.window.frame, frame, "the surface does not move")
        }
        // A sequence the system cancels is just more scrolling.
        fixture.window.sendEvent(try scroll(.began))
        fixture.window.sendEvent(try scroll(.changed, dx: 20))
        fixture.window.sendEvent(try scroll(.cancelled))
        XCTAssertEqual(fixture.forwarded().count, sent + 3)
        assertSurfaceUntouched(fixture)
    }

    /// Ordinary vertical scrolling, mouse-wheel notches, momentum tails and
    /// modifier-bearing samples all pass through 1:1 — the window keeps no
    /// gesture state that could swallow or reinterpret them.
    func testEveryScrollFlavourReachesTheContentUnconsumed() throws {
        let fixture = makeScrollFixture()
        var sent = 0
        func deliver(_ event: NSEvent) {
            fixture.window.sendEvent(event)
            sent += 1
        }
        deliver(try scroll(.began, dy: -12))
        for _ in 0..<10 { deliver(try scroll(.changed, dy: -12)) }
        deliver(try scroll(.ended))
        deliver(try scroll(nil, dy: -24, precise: false))
        deliver(try scroll(nil, dx: 30, momentum: .continuous))
        deliver(try scroll(.changed, dx: 20, flags: .maskShift))
        XCTAssertEqual(fixture.forwarded().count, sent)
        assertSurfaceUntouched(fixture)
    }

    /// A sequence abandoned mid-way — a button press, a modifier change, a
    /// fresh began — leaves nothing behind: later events still reach the
    /// content, and key loss or orderOut have no gesture state to restore.
    func testInterruptedSequencesLeaveNoGestureStateBehind() throws {
        let fixture = makeScrollFixture()
        fixture.window.sendEvent(try scroll(.began))
        fixture.window.sendEvent(try scroll(.changed, dx: 30))
        let mouseDown = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                              mouseCursorPosition: .zero, mouseButton: .left))
        fixture.window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: mouseDown)))
        fixture.window.sendEvent(try scroll(.began))
        fixture.window.sendEvent(try scroll(.changed, dx: 30))
        fixture.window.resignKey()
        fixture.window.orderOut(nil)
        fixture.window.sendEvent(try scroll(.changed, dx: 30))
        XCTAssertEqual(fixture.forwarded().count, 6, "no event is ever consumed or replayed")
        assertSurfaceUntouched(fixture)
    }

    /// Escape remains the surface's deliberate close.
    func testEscapeKeyStillRoutesToTheOwner() throws {
        let fixture = makeScrollFixture()
        var escapes = 0
        fixture.window.onEscape = { escapes += 1 }
        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        fixture.window.keyDown(with: try XCTUnwrap(NSEvent(cgEvent: escape)))
        XCTAssertEqual(escapes, 1)
    }
}
