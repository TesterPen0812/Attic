import AppKit
import Darwin

// Quit only the isolated lab bundle. The running app's real PID comes from Launch Services.
let bundleID = CommandLine.arguments.dropFirst() == ["--control"]
    ? "com.taha.renderlab.control"
    : "com.taha.Attic.preview.renderlab"
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
let approvedExecutable = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Projects/attic/attic-air/.build/render-dd/Build/Products/Local/AtticRenderLab.app/Contents/MacOS/AtticRenderLab")
    .standardizedFileURL.path
// A failed cleanup must never permit another -n launch to accumulate copies.
guard apps.allSatisfy({ app in
    app.bundleIdentifier == bundleID &&
    (bundleID == "com.taha.renderlab.control" || app.executableURL?.standardizedFileURL.path == approvedExecutable)
}) else { fputs("Unrecognized executable for lab identity; refusing\n", stderr); exit(3) }
if apps.count > 1 { fputs("Cleaning up \(apps.count) isolated lab copies\n", stderr) }
for app in apps {
    print("QUIT pid=\(app.processIdentifier) bundle=\(bundleID)")
    guard app.terminate() else { fputs("Could not request lab quit\n", stderr); exit(4) }
}
for app in apps {
    let pid = app.processIdentifier
    func gone() -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    func sameLabProcess() -> Bool {
        guard let current = NSRunningApplication(processIdentifier: pid),
              current.bundleIdentifier == bundleID else { return false }
        return bundleID == "com.taha.renderlab.control" ||
            current.executableURL?.standardizedFileURL.path == approvedExecutable
    }
    for _ in 0..<60 {
        // NSRunningApplication's cached termination state can lag when this
        // standalone CLI has no AppKit run loop. Check the exact PID instead.
        if gone() { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    // An isolated preview can sometimes ignore NSRunningApplication.terminate().
    // Terminate only the verified exact PID; do not let another `open -n`
    // accumulate windows that invalidate the capture experiment.
    if !gone() {
        guard sameLabProcess() else { fputs("PID no longer matches lab; refusing signal\n", stderr); exit(4) }
        _ = Darwin.kill(pid, SIGTERM)
        for _ in 0..<40 {
            if gone() { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    if !gone() {
        guard sameLabProcess() else { fputs("PID no longer matches lab; refusing force quit\n", stderr); exit(4) }
        _ = Darwin.kill(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.25)
    }
    if !gone() {
        fputs("Render lab pid \(pid) did not quit in time\n", stderr)
        exit(4)
    }
}
