import AppKit

/// Only the unit-test-host target can enable this policy. Environment flags in
/// the shipping app (including previews and UI-test apps) have no effect.
@objc(AtticTestPresentationPolicy)
final class TestPresentationPolicy: NSObject {
    @objc static let isInvisible: Bool = {
        #if ATTIC_UNIT_TEST_HOST
        let environment = ProcessInfo.processInfo.environment
        return environment["ATTIC_KEY_WINDOW_TESTS"] != "1"
            && environment["ATTIC_VISIBLE_TESTS"] != "1"
        #else
        return false
        #endif
    }()

    /// A translated work area preserves corner/size geometry. The host's
    /// ordering boundary also protects plain AppKit and SwiftUI test windows.
    @objc static func placementFrame(_ frame: CGRect) -> CGRect {
        guard isInvisible else { return frame }
        let displays = NSScreen.screens.map(\.frame)
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return frame.offsetBy(dx: -1_000_000 - frame.maxX, dy: 0) }
        return frame.offsetBy(dx: union.minX - union.maxX - 1_000_000, dy: 0)
    }

    @objc static func offscreenFrame(_ frame: CGRect) -> CGRect {
        guard isInvisible else { return frame }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        // Empty windows acquire their size while being ordered. Move their
        // origin too, before AppKit creates a visible backing window.
        guard union.intersects(frame) || union.contains(frame.origin) else { return frame }
        var result = placementFrame(frame)
        let minimumX = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
        if result.maxX >= minimumX { result.origin.x = minimumX - result.width - 4096 }
        return result
    }
}
