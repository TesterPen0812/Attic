// B-11 Air-only native input driver. Compile with -target arm64-apple-macos26.0.
// Requires the sweep screen lock and the com.taha.Attic.preview.sweep identity.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
guard ProcessInfo.processInfo.hostName.lowercased() == "tahas-macbook-air.local" else { fail("Air-only driver; no input sent") }
let lock = "/tmp/attic-air-screen.lockdir/owner"
guard (try? String(contentsOfFile: lock, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "sweep" else { fail("sweep does not own the Air lock") }
let bid = "com.taha.Attic.preview.sweep"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { fail("preview not running") }
let pid = app.processIdentifier
let root = AXUIElementCreateApplication(pid)
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, key as CFString, &value); return value
}
func textView(_ element: AXUIElement) -> AXUIElement? {
    if attribute(element, "AXIdentifier") as? String == "note-text" { return element }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] { if let found = textView(child) { return found } }
    return nil
}
guard let view = textView(root) else { fail("note editor unavailable") }
app.activate(options: []); usleep(400_000)
guard AXUIElementSetAttributeValue(view, "AXFocused" as CFString, kCFBooleanTrue) == .success else { fail("cannot focus editor") }
var suppressTimedAccessibilityReads = false
func checkFocus() {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bid else { fail("preview lost focus; no input sent") }
    if !suppressTimedAccessibilityReads {
        guard let focused = attribute(root, "AXFocusedUIElement"), CFEqual(focused, view) else { fail("editor lost focus; no input sent") }
    }
}
func key(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    checkFocus()
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        if let text { let units = Array(text.utf16); units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) } }
        event.postToPid(pid)
    }
}
func selectedOffset() -> Int {
    guard let value = attribute(view, "AXSelectedTextRange"), CFGetTypeID(value) == AXValueGetTypeID() else { fail("missing caret") }
    var range = CFRange(); AXValueGetValue(value as! AXValue, .cfRange, &range)
    return range.location
}
func caret(at offset: Int, length: Int = 0) -> CGRect {
    var range = CFRange(location: offset, length: length)
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(view, "AXBoundsForRange" as CFString, AXValueCreate(.cfRange, &range)!, &result) == .success,
          let result, CFGetTypeID(result) == AXValueGetTypeID() else { fail("missing caret bounds") }
    var bounds = CGRect.zero; AXValueGetValue(result as! AXValue, .cgRect, &bounds); return bounds
}

func reportWindows() {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
    for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == pid {
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("WINDOW id=\(window[kCGWindowNumber as String]!) layer=\(window[kCGWindowLayer as String]!) width=\(bounds["Width"] ?? 0) height=\(bounds["Height"] ?? 0)")
    }
}
if CommandLine.arguments.contains("--rich") {
    guard let value = attribute(view, "AXValue") as? String, value.contains("Formatting test page") else { fail("missing disposable rich fixture") }
    let firstBreak = (value as NSString).range(of: "\n")
    guard firstBreak.location != NSNotFound else { fail("missing fixture title") }
    var range = CFRange(location: CommandLine.arguments.contains("--tail") ? (value as NSString).length : NSMaxRange(firstBreak), length: 0)
    guard AXUIElementSetAttributeValue(view, "AXSelectedTextRange" as CFString, AXValueCreate(.cfRange, &range)!) == .success else { fail("cannot select body") }
    key(36); usleep(150_000)
    if CommandLine.arguments.contains("--tail") { range.location += 1 }
    guard AXUIElementSetAttributeValue(view, "AXSelectedTextRange" as CFString, AXValueCreate(.cfRange, &range)!) == .success else { fail("cannot select blank paragraph") }
    usleep(500_000)
} else {
    key(0, flags: .maskCommand); usleep(150_000)
    key(0, text: "Wrap fixture"); usleep(150_000); key(36); usleep(500_000)
}
let observe = CommandLine.arguments.contains("--observe") || CommandLine.arguments.contains("--repeat-wrap")
let words = CommandLine.arguments.contains("--words")
if words && !observe { fail("word diagnostics require --observe; posthoc wrap mapping is exact for unbroken text") }
let initialOffset = selectedOffset()
var last = caret(at: initialOffset)
let letters = Array(words ? "the quick brown fox jumps over the lazy dog " : "x")
var sentKeys: [(Int, Double)] = []
print("OBSERVATION \(observe ? "per-key" : "posthoc-glyphs-no-ax")")
suppressTimedAccessibilityReads = !observe
for i in 1...100 {
    let sent = Date().timeIntervalSince1970
    key(7, text: String(letters[(i - 1) % letters.count]))
    usleep(110_000)
    sentKeys.append((i, sent))
    if observe {
        let next = caret(at: selectedOffset())
        let wrapped = next.minY > last.minY + 1 || next.minX < last.minX - 1
        print("KEY index=\(i) start=\(String(format: "%.6f", sent)) wrap=\(wrapped ? 1 : 0)")
        fflush(stdout)
        if CommandLine.arguments.contains("--repeat-wrap"), wrapped {
            for _ in 0..<30 {
                key(51); usleep(110_000)
                key(7, text: String(letters[(i - 1) % letters.count])); usleep(110_000)
            }
            break
        }
        last = next
    }
}
suppressTimedAccessibilityReads = false
if !observe {
    checkFocus()
    guard selectedOffset() == initialOffset + 100 else { fail("timed input did not all reach the note") }
    // No accessibility calls occur between timed keys. With unbroken text,
    // final glyph positions identify the same exact wrap character.
    usleep(200_000)
    last = caret(at: initialOffset, length: 1)
    for (i, sent) in sentKeys {
        let next = caret(at: initialOffset + i - 1, length: 1)
        let wrapped = next.minY > last.minY + 1 || next.minX < last.minX - 1
        print("KEY index=\(i) start=\(String(format: "%.6f", sent)) wrap=\(wrapped ? 1 : 0)")
        last = next
    }
}
reportWindows()
