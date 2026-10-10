import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// F-03 audit of the caret in the fields the system draws (the token field's
/// TextKit 1 text view, SwiftUI `TextField`s, the native search input): the
/// caret sits against the text's glyph box within a point, so they are left
/// alone. The notes' TextKit 2 views are fitted (`PhaseXCaretTests`).
@MainActor
final class PhaseXCaretAuditTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws { windows.forEach { $0.close() }; windows.removeAll() }

    private func window(_ view: NSView, size: NSSize) -> NSWindow {
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        windows.append(host)
        return host
    }

    /// The caret box and glyph box of a TextKit 1 text view's first line, in the text view's top-down coordinates.
    @discardableResult
    private func measure(_ editor: NSTextView, name: String, font: NSFont) -> (taller: CGFloat, centreOff: CGFloat)? {
        guard let window = editor.window else { XCTFail("\(name): no window"); return nil }
        let caretScreen = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let caretWindow = window.convertFromScreen(caretScreen)
        var caret = editor.convert(caretWindow, from: nil)
        if !editor.isFlipped { caret.origin.y = editor.bounds.height - caret.maxY }
        var baseline: CGFloat?
        var kit = "TK2"
        if let lm = editor.layoutManager {
            kit = "TK1"
            lm.ensureLayout(for: editor.textContainer!)
            let rect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            baseline = rect.minY + lm.location(forGlyphAt: 0).y + editor.textContainerOrigin.y
        } else if let tlm = editor.textLayoutManager, let fragment = tlm.textLayoutFragment(for: tlm.documentRange.location),
                  let line = fragment.textLineFragments.first {
            baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y + editor.textContainerOrigin.y
        }
        guard let baseline else { XCTFail("\(name): no baseline"); return nil }
        let glyphTop = baseline - font.ascender, glyphBottom = baseline - font.descender
        print("CARETAUDIT", String(format: "%@ %@ | caret %.2f at %.2f | glyph box %.2f at %.2f | taller by %.2f, centre off by %.2f",
                                    name, kit, caret.height, caret.minY, glyphBottom - glyphTop, glyphTop,
                                    caret.height - (glyphBottom - glyphTop), caret.midY - (glyphTop + glyphBottom) / 2))
        let taller = caret.height - (glyphBottom - glyphTop), off = caret.midY - (glyphTop + glyphBottom) / 2
        // The system's line is whole points high (TextKit 1 rounds it up) and
        // centred on the glyphs: under a point taller, under half a point off.
        XCTAssertLessThan(taller, 1.0, name)
        XCTAssertLessThan(abs(off), 0.5, name)
        return (taller, off)
    }

    func testFields() throws {
        // The Tasks add bar and task rename: the token field (TextKit 1).
        for (name, style) in [("token field listBody", AtticTextStyle.listBody), ("token field rowTitle", AtticTextStyle.rowTitle)] {
            let field = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 240, height: AtticTokenFieldMetrics.height))
            let font = style.nsFont
            field.apply(style: AtticTokenFieldView.Style(font: font, text: .labelColor, piece: .secondaryLabelColor, high: .orange, caret: .labelColor))
            field.textView.string = "Hxg"
            let host = window(field, size: NSSize(width: 240, height: AtticTokenFieldMetrics.height))
            field.layoutSubtreeIfNeeded()
            host.makeFirstResponder(field.textView)
            field.textView.setSelectedRange(NSRange(location: 0, length: 0))
            measure(field.textView, name: name, font: font)
        }
        // Plain SwiftUI TextFields (a system field editor): search, rename fallback, dropdown filter, Settings search.
        for (name, style) in [("TextField listBody", AtticTextStyle.listBody), ("TextField rowTitle", AtticTextStyle.rowTitle),
                              ("TextField dropdownRow", AtticTextStyle.dropdownRow), ("TextField rowSingle", AtticTextStyle.rowSingle)] {
            struct Probe: View {
                @State var text = "Hxg"
                let style: AtticTextStyle
                var body: some View {
                    TextField("", text: $text).textFieldStyle(.plain).font(style.font).frame(width: 220, height: 24)
                }
            }
            let hosting = NSHostingView(rootView: Probe(style: style))
            let host = window(hosting, size: NSSize(width: 240, height: 40))
            hosting.layoutSubtreeIfNeeded()
            func find(_ v: NSView) -> NSTextField? { (v as? NSTextField) ?? v.subviews.compactMap(find).first }
            guard let textField = find(hosting) else { print("CARETAUDIT", name, "no NSTextField"); continue }
            host.makeFirstResponder(textField)
            guard let editor = host.fieldEditor(false, for: textField) as? NSTextView ?? textField.currentEditor() as? NSTextView else {
                print("CARETAUDIT", name, "no field editor"); continue
            }
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            measure(editor, name: name, font: style.nsFont)
        }
        // The native search input (Tasks search).
        let native = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 18))
        native.isBordered = false; native.isBezeled = false; native.drawsBackground = false
        native.font = AtticTextStyle.listBody.nsFont
        native.stringValue = "Hxg"
        let host = window(native, size: NSSize(width: 240, height: 40))
        host.makeFirstResponder(native)
        if let editor = native.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            measure(editor, name: "native search NSTextField", font: AtticTextStyle.listBody.nsFont)
        }
    }
}
