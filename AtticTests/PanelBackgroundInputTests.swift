import AppKit
import Darwin
import XCTest
@testable import Attic

/// Reads the WindowServer's policy for the host's off-screen windows.
/// Does not post events or request key status/application activation.
@MainActor
final class PanelBackgroundInputTests: XCTestCase {
    private func tags(of window: NSWindow) throws -> UInt64 {
        typealias Connection = @convention(c) () -> Int32
        typealias ReadTags = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int) -> Int32
        let connectionSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"))
        let readSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSGetWindowTags"))
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let read = unsafeBitCast(readSymbol, to: ReadTags.self)
        XCTAssertGreaterThan(window.windowNumber, 0)
        var tags: UInt64 = 0
        XCTAssertEqual(read(connection(), UInt32(window.windowNumber), &tags, 64), 0)
        return tags
    }

    func testEveryPanelSurfaceReceivesBackgroundGesturesAndCanSetItsCursorAfterEachReveal() throws {
        guard TestPresentationPolicy.isInvisible else { throw XCTSkip("Invisible host required") }
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        for surface in ["docked", "island", "floating"] {
            let frame = CGRect(x: -4_000, y: -4_000, width: 200, height: 200)
            let window: NSPanel = surface == "island"
                ? PanelIslandWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                : AtticPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
            defer { window.close() }
            for reveal in 1...2 {
                window.orderFrontRegardless()
                let value = try tags(of: window)
                print("BACKGROUND_INPUT \(surface) reveal=\(reveal) tags=\(String(value, radix: 16))")
                XCTAssertNotEqual(value & (UInt64(1) << 42), 0, "\(surface): WindowServer must route background gestures")
                XCTAssertNotEqual(value & (UInt64(1) << 5), 0, "\(surface): background cursor changes must be allowed")
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertFalse(NSApp.isActive)
                window.orderOut(nil)
            }
        }
    }
}
