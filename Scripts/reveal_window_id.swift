import AppKit
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
guard NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == "com.taha.Attic.preview.phasex" else { exit(1) }
if CGPreflightScreenCaptureAccess(),
   let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
    for window in owned {
        if let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let height = bounds["Height"] as? Double, height > 200,
           let id = window[kCGWindowNumber as String] as? Int { print(id); exit(0) }
    }
}
exit(1)
