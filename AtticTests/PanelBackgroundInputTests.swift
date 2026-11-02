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

    private let required: UInt64 = (1 << 42) | (1 << 5)

    private func clearPolicy(_ window: NSWindow) throws {
        typealias Connection = @convention(c) () -> Int32
        typealias Clear = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int) -> Int32
        let connection = unsafeBitCast(try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID")), to: Connection.self)
        let clear = unsafeBitCast(try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSClearWindowTags")), to: Clear.self)
        var mask = required
        XCTAssertEqual(clear(connection(), UInt32(window.windowNumber), &mask, 64), 0)
        let deadline = Date().addingTimeInterval(2)
        while try tags(of: window) & required != 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try tags(of: window) & required, 0, "prove the next reveal must actually reinstall the policy")
    }

    func testAFailedPolicyWriteIsReportedOnceAndStillReturnsFailure() throws {
        guard TestPresentationPolicy.isInvisible else { throw XCTSkip("Invisible host required") }
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        let oldInstall = AtticBackgroundInput.installTags, oldLog = AtticBackgroundInput.logFailure
        let oldLogged = AtticBackgroundInput.failureLogged
        defer {
            AtticBackgroundInput.installTags = oldInstall; AtticBackgroundInput.logFailure = oldLog
            AtticBackgroundInput.failureLogged = oldLogged
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var errors: [Int32] = []
        AtticBackgroundInput.failureLogged = false
        AtticBackgroundInput.logFailure = { errors.append($0) }
        AtticBackgroundInput.installTags = { _, _ in 1000 }
        XCTAssertFalse(AtticBackgroundInput.enable(in: window))
        XCTAssertFalse(AtticBackgroundInput.enable(in: window))
        XCTAssertEqual(errors, [1000], "an OS/SPI failure must be visible, without flooding the log")
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
                if reveal == 1 { window.orderFrontRegardless() }
                else { window.order(.above, relativeTo: 0) }
                // Window ordering/tags commit asynchronously. Poll the real
                // server value with a deadline, never infer it from the API's
                // success return or the window's cached properties.
                let required: UInt64 = (1 << 42) | (1 << 5)
                let deadline = Date().addingTimeInterval(2)
                var value = try tags(of: window)
                while value & required != required, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                    value = try tags(of: window)
                }
                print("BACKGROUND_INPUT \(surface) reveal=\(reveal) tags=\(String(value, radix: 16))")
                XCTAssertNotEqual(value & (UInt64(1) << 42), 0, "\(surface): WindowServer must route background gestures")
                XCTAssertNotEqual(value & (UInt64(1) << 5), 0, "\(surface): background cursor changes must be allowed")
                XCTAssertFalse(window.isKeyWindow)
                XCTAssertFalse(NSApp.isActive)
                // Test additivity while the window's other native state is
                // stable, rather than comparing different visibility states.
                try clearPolicy(window)
                let before = try tags(of: window)
                XCTAssertTrue(AtticBackgroundInput.enable(in: window))
                let deadline = Date().addingTimeInterval(2)
                while try tags(of: window) & required != required, Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                XCTAssertEqual(try tags(of: window), before | required, "unrelated native tag bits are unchanged")
                window.resetCursorRects()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                XCTAssertEqual(try tags(of: window) & required, required, "cursor-rect rebuilding preserves background input")
                window.orderOut(nil)
                try clearPolicy(window)
            }
        }
    }
}
