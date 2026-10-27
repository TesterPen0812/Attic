import AppKit
import SwiftUI

let args = Array(CommandLine.arguments.dropFirst())
func option(_ key: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of:key), i+1 < args.count else { return fallback }; return args[i+1]
}
guard args.contains("--allow-screen"), let outputIndex = args.firstIndex(of:"--output"), outputIndex+1 < args.count else {
    fputs("REFUSED: CanvasLab requires --allow-screen --output EXISTING_DIRECTORY; never launch in a headless run.\n",stderr); exit(3)
}
let mode = option("--mode","reference"), glass = option("--glass","off")
guard ["reference","c1","c2","c3"].contains(mode), ["off","100","35"].contains(glass),
      mode != "reference" || glass == "off" else { fatalError("Invalid mode/glass") }
let out = URL(fileURLWithPath:args[outputIndex+1],isDirectory:true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let previousCoalescing = NSEvent.isMouseCoalescingEnabled
NSEvent.isMouseCoalescingEnabled = false
final class Delegate: NSObject, NSApplicationDelegate {
    var coalescing = true
    func applicationWillTerminate(_ notification: Notification) { NSEvent.isMouseCoalescingEnabled = coalescing }
}
let delegate = Delegate(); delegate.coalescing = previousCoalescing; app.delegate = delegate
let screen = NSScreen.main!
let ink = try InkView(mode:mode,sync:args.contains("--sync-reproducer"),out:out,scale:screen.backingScaleFactor)
final class LabWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
let window = LabWindow(contentRect:CGRect(x:screen.visibleFrame.maxX-340,y:screen.visibleFrame.midY-260,width:320,height:520),
    styleMask:[.borderless],backing:.buffered,defer:false)
window.appearance = NSAppearance(named:.aqua)
window.title = "Canvas Lab \(mode)"; window.contentView = ink
window.isReleasedWhenClosed = false
// Native macOS 26 glass, compact 30 pt controls. No product code or stores linked.
struct LabControls: View {
    let glass: String
    var body: some View {
        HStack(spacing:8) {
            Button { NSApp.terminate(nil) } label: { Image(systemName:"xmark").frame(width:30,height:30) }
                .accessibilityLabel("Quit Canvas lab")
            Text("Canvas lab").font(.system(size:12,weight:.medium))
        }
        .buttonStyle(.plain).foregroundStyle(.black)
        .padding(4)
        .glassEffect(glass == "off" ? .identity : .regular, in:Capsule())
        .opacity(glass == "35" ? 0.35 : 1)
    }
}
if mode != "reference", glass != "off" {
    let controls = NSHostingView(rootView:LabControls(glass:glass)); controls.frame = CGRect(x:75,y:472,width:170,height:40)
    ink.addSubview(controls)
}
ink.ready = {
    let frame = window.frame
    let metadata: [String:Any] = ["mode":mode,"glass":glass,"sync":args.contains("--sync-reproducer"),
        "pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleIdentifier!,
        "scale":screen.backingScaleFactor,"advertised_max_hz":screen.maximumFramesPerSecond,
        "window_frame_appkit_pt":[frame.minX,frame.minY,frame.width,frame.height],
        "fixture_strokes":ink.fixture.strokes.count,"fixture_points":ink.fixture.strokes.reduce(0){$0+$1.count},
        "clock":"mach absolute seconds / CACurrentMediaTime / NSEvent.timestamp",
        "appearance":"aqua","coalescing":false,"display_link":false,"edge":false]
    try! JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("settings.json"))
    try! Data("ready\n".utf8).write(to:out.appendingPathComponent("app-ready.txt"))
}
window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); ink.start(); app.run()
