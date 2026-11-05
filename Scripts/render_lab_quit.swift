import AppKit
import Darwin

// Quit only the isolated lab bundle. The running app's real PID comes from Launch Services.
let bundleID = CommandLine.arguments.dropFirst() == ["--control"]
    ? "com.taha.renderlab.control"
    : "com.taha.Attic.preview.renderlab"
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
guard apps.count <= 1 else { fputs("Multiple render lab copies; refusing\n", stderr); exit(3) }
for app in apps {
    guard app.bundleIdentifier == bundleID else { exit(3) }
    print("QUIT pid=\(app.processIdentifier) bundle=\(bundleID)")
    guard app.terminate() else { fputs("Could not request lab quit\n", stderr); exit(4) }
    for _ in 0..<100 {
        // NSRunningApplication's cached termination state can lag when this
        // standalone CLI has no AppKit run loop. Check the exact PID instead.
        if kill(app.processIdentifier, 0) == -1 && errno == ESRCH { exit(0) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fputs("Render lab did not quit in time\n", stderr)
    exit(4)
}
