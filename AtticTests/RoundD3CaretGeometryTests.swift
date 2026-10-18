import AppKit
import XCTest
@testable import Attic

/// D2's stock harness: genuinely native indicators in never-ordered windows.
/// Measurement only. No NoteCaretFitter or product editor is instantiated.
@MainActor
private final class D3UnshownWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Experimental public geometry override: can NSTextView consume a smaller
/// typographic band while the layout fragment retains its fixed-pitch tiling?
/// This never reads, inserts, or mutates an insertion indicator.
private final class D3Line: NSTextLineFragment {
    let source: NSTextLineFragment
    init(_ source: NSTextLineFragment) {
        self.source = source
        super.init(attributedString: source.attributedString, range: source.characterRange)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var typographicBounds: CGRect {
        guard source.attributedString.length > 0 else { return source.typographicBounds }
        guard let font = source.attributedString.attribute(.font, at: min(source.characterRange.location, source.attributedString.length - 1), effectiveRange: nil) as? NSFont else { return source.typographicBounds }
        let natural = font.ascender - font.descender + font.leading
        let baseline = source.typographicBounds.minY + source.glyphOrigin.y
        let centre = baseline + (-font.descender - font.capHeight) / 2
        return CGRect(x: source.typographicBounds.minX, y: centre - natural / 2, width: source.typographicBounds.width, height: natural)
    }
    override var glyphOrigin: CGPoint {
        CGPoint(x: source.glyphOrigin.x, y: source.typographicBounds.minY + source.glyphOrigin.y - typographicBounds.minY)
    }
    override func draw(at point: CGPoint, in context: CGContext) {
        source.draw(at: CGPoint(x: point.x, y: point.y + source.typographicBounds.minY - typographicBounds.minY), in: context)
    }
    override func locationForCharacter(at index: Int) -> CGPoint { source.locationForCharacter(at: index) }
    override func characterIndex(for point: CGPoint) -> Int { source.characterIndex(for: point) }
    override func fractionOfDistanceThroughGlyph(for point: CGPoint) -> CGFloat { source.fractionOfDistanceThroughGlyph(for: point) }
}

private final class D3Fragment: NSTextLayoutFragment {
    private var wrappers: [ObjectIdentifier: D3Line] = [:]
    private func wrap(_ line: NSTextLineFragment) -> D3Line {
        let key = ObjectIdentifier(line)
        if let old = wrappers[key] { return old }
        let new = D3Line(line); wrappers[key] = new; return new
    }
    override var textLineFragments: [NSTextLineFragment] { super.textLineFragments.map(wrap) }
    override func textLineFragment(for textLocation: any NSTextLocation, isUpstreamAffinity: Bool) -> NSTextLineFragment? {
        super.textLineFragment(for: textLocation, isUpstreamAffinity: isUpstreamAffinity).map(wrap)
    }
    override func textLineFragment(forVerticalOffset verticalOffset: CGFloat, requiresExactMatch: Bool) -> NSTextLineFragment? {
        super.textLineFragment(forVerticalOffset: verticalOffset, requiresExactMatch: requiresExactMatch).map(wrap)
    }
}

private final class D3LayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        D3Fragment(textElement: textElement, range: nil)
    }
}

private final class D3MarginFragment: NSTextLayoutFragment {
    var extraTop: CGFloat = 0
    override var topMargin: CGFloat { super.topMargin + extraTop }
    override var bottomMargin: CGFloat { super.bottomMargin - extraTop }
}
private final class D3MarginDelegate: NSObject, NSTextLayoutManagerDelegate {
    let extraTop: CGFloat
    init(extraTop: CGFloat) { self.extraTop = extraTop }
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = D3MarginFragment(textElement: textElement, range: nil)
        fragment.extraTop = extraTop
        return fragment
    }
}

@MainActor
final class RoundD3CaretGeometryTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try requireKeyWindowTests()
    }
    private var windows: [NSWindow] = []
    private var rows: [[String: Any]] = []
    private let fragmentDelegate = D3LayoutDelegate()
    private var marginDelegates: [D3MarginDelegate] = []
    private let variants = ["A-fixed", "B-spacing", "B-calibrated", "C-baseline", "D-multiple", "E-no-leading", "E-paragraph", "E-fixed-spacing", "E-typographic", "E-natural-baseline", "E-hybrid", "E-before", "E-shell", "F-default"]
    private var measuredDefaultHeight: CGFloat = 0

    private func roundedHeight(_ font: NSFont) -> CGFloat {
        // Probe F at each actual font before the matrix; do not infer AppKit's rounding.
        measuredDefaultHeight
    }

    private func closeWindows() {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        marginDelegates.removeAll()
    }

    override func tearDown() async throws {
        if !rows.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            a.name = "d3-measurements.json"; a.lifetime = .keepAlways; add(a)
            print("D3_MEASUREMENTS", String(decoding: data, as: UTF8.self))
        }
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
    }

    private func settle(_ text: NSTextView) {
        let lm = text.textLayoutManager!
        lm.ensureLayout(for: lm.documentRange)
        text.enclosingScrollView?.layoutSubtreeIfNeeded()
        text.layoutSubtreeIfNeeded()
        lm.textViewportLayoutController.layoutViewport()
        text.updateInsertionPointStateAndRestartTimer(true)
        text.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func stock(font: NSFont, pitch: CGFloat, variant: String, string: String) -> NSTextView {
        let p = NSMutableParagraphStyle()
        let natural = font.ascender - font.descender + font.leading
        var baseline: CGFloat = 0
        switch variant {
        case "A-fixed", "E-typographic": p.minimumLineHeight = pitch; p.maximumLineHeight = pitch
        case "B-spacing": p.lineSpacing = max(0, pitch - natural)
        case "B-calibrated", "E-shell": p.lineSpacing = max(0, pitch - roundedHeight(font))
        case "E-hybrid": p.lineSpacing = max(0, pitch - roundedHeight(font))
        case "E-before":
            p.lineSpacing = max(0, pitch - roundedHeight(font))
            p.paragraphSpacing = -p.lineSpacing; p.paragraphSpacingBefore = p.lineSpacing
        case "E-natural-baseline":
            p.lineSpacing = max(0, pitch - roundedHeight(font))
            baseline = (roundedHeight(font) - 2 * (-font.descender).rounded() - font.capHeight - font.descender) / 2
        case "E-fixed-spacing":
            p.minimumLineHeight = roundedHeight(font); p.maximumLineHeight = roundedHeight(font)
            p.lineSpacing = max(0, pitch - roundedHeight(font))
        case "C-baseline":
            p.minimumLineHeight = pitch; p.maximumLineHeight = pitch
            baseline = pitch - (-font.descender).rounded() - ((pitch - natural) / 2 + font.ascender)
        case "D-multiple": p.lineHeightMultiple = pitch / natural
        case "E-no-leading": p.lineSpacing = max(0, pitch - (font.ascender - font.descender))
        case "E-paragraph": p.paragraphSpacing = max(0, pitch - natural)
        default: break
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: p]
        if baseline != 0 { attributes[.baselineOffset] = baseline }
        let text = NSTextView(usingTextLayoutManager: true)
        text.frame = CGRect(x: 0, y: 0, width: 260, height: 240)
        text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainerInset = CGSize(width: 24, height: 16)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textLayoutManager?.usesFontLeading = variant != "E-no-leading"
        if variant == "E-typographic" { text.textLayoutManager?.delegate = fragmentDelegate }
        if variant == "E-shell" {
            let delegate = D3MarginDelegate(extraTop: p.lineSpacing)
            marginDelegates.append(delegate); text.textLayoutManager?.delegate = delegate
        }
        text.textStorage!.setAttributedString(NSAttributedString(string: string, attributes: attributes))
        text.typingAttributes = attributes
        if variant == "E-hybrid" || variant == "E-before" {
            // Empty stored paragraphs have no soft wraps. Move their leading
            // into paragraph spacing so it cannot inflate their native caret.
            let ns = string as NSString
            var start = 0
            while start < ns.length {
                let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
                if ns.substring(with: range).trimmingCharacters(in: .newlines).isEmpty {
                    let blank = p.mutableCopy() as! NSMutableParagraphStyle
                    blank.lineSpacing = 0; blank.paragraphSpacing = variant == "E-hybrid" ? p.lineSpacing : 0
                    text.textStorage!.addAttribute(.paragraphStyle, value: blank, range: range)
                }
                start = NSMaxRange(range)
            }
            // An extra line after a blank paragraph does not inherit its
            // paragraphSpacing; give the pending paragraph that space before.
            if string.hasSuffix("\n\n") || string == "\n" {
                let pending = p.mutableCopy() as! NSMutableParagraphStyle
                pending.lineSpacing = 0; pending.paragraphSpacingBefore = p.lineSpacing
                text.typingAttributes[.paragraphStyle] = pending
            }
        }
        text.insertionPointColor = .textInsertionPointColor
        text.drawsBackground = true; text.backgroundColor = NSColor(srgbRed: 0.24, green: 0.24, blue: 0.24, alpha: 1)
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text
        let window = D3UnshownWindow(contentRect: CGRect(x: -9000, y: -9000, width: 260, height: 240),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll; windows.append(window)
        window.makeFirstResponder(text)
        XCTAssertFalse(window.isVisible)
        settle(text)
        return text
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func rect(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height, "bottom": r.maxY]
    }
    private struct Line {
        let rect: CGRect
        let baseline: CGFloat
        let start: Int
        let length: Int
    }
    private func lines(_ text: NSTextView) -> [Line] {
        let lm = text.textLayoutManager!, content = lm.textContentManager!
        var result: [Line] = []
        lm.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { f in
            let start = content.offset(from: content.documentRange.location, to: f.rangeInElement.location)
            for l in f.textLineFragments {
                let r = l.typographicBounds.offsetBy(dx: f.layoutFragmentFrame.minX + text.textContainerOrigin.x,
                                                    dy: f.layoutFragmentFrame.minY + text.textContainerOrigin.y)
                result.append(Line(rect: r, baseline: r.minY + l.glyphOrigin.y, start: start + l.characterRange.location, length: l.characterRange.length))
            }
            return true
        }
        return result
    }

    private func segment(_ text: NSTextView, range: NSRange, type: NSTextLayoutManager.SegmentType) throws -> CGRect? {
        let lm = text.textLayoutManager!, content = lm.textContentManager!
        let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: range.location))
        let end = try XCTUnwrap(content.location(start, offsetBy: range.length))
        var result: CGRect?
        let textRange = try XCTUnwrap(NSTextRange(location: start, end: end))
        lm.enumerateTextSegments(in: textRange, type: type, options: [.rangeNotRequired]) { _, r, _, _ in
            result = r; return false
        }
        return result?.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    private func render(_ text: NSTextView, name: String) throws {
        let rep = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: text.bounds))
        text.effectiveAppearance.performAsCurrentDrawingAppearance { text.cacheDisplay(in: text.bounds, to: rep) }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        a.name = name + ".png"; a.lifetime = .keepAlways; add(a)
    }

    private func measure(_ text: NSTextView, font: NSFont, pitch: CGFloat, role: String, variant: String, fixture: String, index: Int) throws {
        let line = try XCTUnwrap(lines(text).dropFirst(index).first)
        let offset = line.start + (line.length > 1 ? 1 : 0)
        text.setSelectedRange(NSRange(location: offset, length: 0)); settle(text)
        let indicators = descendants(text).compactMap { $0 as? NSTextInsertionIndicator }
        XCTAssertEqual(indicators.count, 1, "Real AppKit indicator, never a stand-in")
        let indicator = try XCTUnwrap(indicators.first)
        let caret = text.convert(indicator.frame, from: indicator.superview)
        let baselineOffset = text.typingAttributes[.baselineOffset] as? CGFloat ?? 0
        let baseline = line.baseline - baselineOffset
        let inkTop = baseline - font.capHeight, inkBottom = baseline - font.descender
        let xTop = baseline - font.xHeight, xBottom = baseline
        let naturalTop = baseline - font.ascender, naturalBottom = baseline - font.descender + font.leading
        let all = lines(text)
        let actualPitch = all.count > index + 1 ? all[index + 1].baseline - all[index].baseline
            : (index > 0 ? all[index].baseline - all[index - 1].baseline : 0)
        let selection = try segment(text, range: NSRange(location: offset, length: min(1, text.string.utf16.count - offset)), type: .selection)
        let point = try segment(text, range: NSRange(location: offset, length: 0), type: .standard)
        if variant != "E-typographic" { XCTAssertNotNil(selection); XCTAssertNotNil(point) }
        rows.append(["role": role, "variant": variant, "fixture": fixture, "lineIndex": index,
                     "font": font.fontName, "size": font.pointSize, "ascender": font.ascender, "descender": font.descender,
                     "leading": font.leading, "capHeight": font.capHeight, "xHeight": font.xHeight,
                     "naturalHeight": font.ascender - font.descender + font.leading, "requestedPitch": pitch,
                     "actualPitch": actualPitch, "caret": rect(caret), "line": rect(line.rect),
                     "layoutBaseline": line.baseline, "inkBaseline": baseline, "baselineOffset": baselineOffset,
                     "capDescenderBand": ["top": inkTop, "bottom": inkBottom], "xHeightBand": ["top": xTop, "bottom": xBottom],
                     "heightExcess": caret.height - (font.ascender - font.descender + font.leading),
                     "inkRoomDifference": (inkTop - caret.minY) - (caret.maxY - inkBottom),
                     "xRoomDifference": (xTop - caret.minY) - (caret.maxY - xBottom),
                     "naturalRoomDifference": (naturalTop - caret.minY) - (caret.maxY - naturalBottom),
                     "pitchBefore": index > 0 ? all[index].baseline - all[index - 1].baseline : 0,
                     "pitchAfter": all.count > index + 1 ? all[index + 1].baseline - all[index].baseline : 0,
                     "indicatorClass": NSStringFromClass(type(of: indicator)), "indicatorCount": indicators.count,
                     "selection": selection.map(rect) as Any? ?? NSNull(), "standardPoint": point.map(rect) as Any? ?? NSNull(),
                     "allLines": all.map { ["rect": rect($0.rect), "baseline": $0.baseline, "start": $0.start, "length": $0.length] as [String: Any] }])
        try render(text, name: "d3-\(role)-\(variant)-\(fixture)")
        // A separate real range-selection render documents highlight geometry.
        if fixture == "wrapped-first" {
            text.setSelectedRange(NSRange(location: offset, length: min(8, line.length - 1))); settle(text)
            try render(text, name: "d3-\(role)-\(variant)-selection")
        }
    }

    func testParagraphGeometryMatrix() throws {
        let roles: [(String, AtticNoteType.Role)] = [("body", .init(size: 12.5, lineHeight: 18.5, weight: 400)),
            ("h1", AtticNoteType.titleStyle), ("h2", AtticNoteType.heading), ("h3", AtticNoteType.subheading)]
        for (name, role) in roles {
            let font = NoteTextStyle.font(for: role)
            let reference = stock(font: font, pitch: role.lineHeight, variant: "F-default", string: "Hxgj py")
            measuredDefaultHeight = try XCTUnwrap(lines(reference).first).rect.height
            closeWindows()
            for variant in variants {
                try autoreleasepool {
                    let typed = stock(font: font, pitch: role.lineHeight, variant: variant, string: "Hxgj py\nHxgj py\nHxgj py")
                    try measure(typed, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "typed", index: 0)
                    let empty = stock(font: font, pitch: role.lineHeight, variant: variant, string: "\n\n")
                    try measure(empty, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "empty", index: 1)
                    let isolated = stock(font: font, pitch: role.lineHeight, variant: variant, string: "")
                    try measure(isolated, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "isolated-empty", index: 0)
                    let trailing = stock(font: font, pitch: role.lineHeight, variant: variant, string: "Hxgj py\n")
                    try measure(trailing, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "trailing-empty", index: 1)
                    let wrapped = stock(font: font, pitch: role.lineHeight, variant: variant,
                                        string: String(repeating: "Hxgj py example words wrapping naturally across the column. ", count: 3))
                    XCTAssertGreaterThan(lines(wrapped).count, 3)
                    try measure(wrapped, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "wrapped-first", index: 0)
                    try measure(wrapped, font: font, pitch: role.lineHeight, role: name, variant: variant, fixture: "wrapped-middle", index: 2)
                    closeWindows()
                }
            }
        }
        // Lock causal observations, rather than claiming an unmet design is a
        // passing product regression. Experimental E-proxy failures are data.
        for row in rows {
            let variant = row["variant"] as! String, fixture = row["fixture"] as! String
            let caret = row["caret"] as! [String: Double]
            if variant == "A-fixed" { XCTAssertEqual(caret["height"]!, Double(row["requestedPitch"] as! CGFloat), accuracy: 0.001) }
            if variant == "B-calibrated", fixture.hasPrefix("wrapped") {
                XCTAssertEqual(row["actualPitch"] as! CGFloat, row["requestedPitch"] as! CGFloat, accuracy: 0.001)
            }
            if variant == "E-typographic", fixture == "typed" {
                XCTAssertNil(row["standardPoint"] as? [String: Double], "A proxy with attractive public bounds is not a usable layout")
                XCTAssertEqual(caret["height"]!, 0, accuracy: 0.001)
            }
        }
    }

    func testCompanionFontsForOffsetDesign() throws {
        let roles: [(String, NSFont, CGFloat)] = [
            ("title", NoteTextStyle.font(for: AtticNoteType.title), 22),
            ("h4-h6", NoteTextStyle.font(for: AtticNoteType.smallHeading), 18.5),
            ("mono", NoteTextStyle.font(for: AtticNoteType.mono), 16.5),
            ("table-header", NoteTextStyle().tableHeaderFont, 18.5)]
        for (name, font, pitch) in roles {
            let reference = stock(font: font, pitch: pitch, variant: "F-default", string: "Hxgj py")
            measuredDefaultHeight = try XCTUnwrap(lines(reference).first).rect.height
            closeWindows()
            for variant in ["A-fixed", "B-calibrated", "E-shell", "F-default"] {
                try autoreleasepool {
                    for (fixture, string, index) in [("typed", "Hxgj py\nHxgj py\nHxgj py", 0), ("empty", "\n\n", 1),
                                                     ("isolated-empty", "", 0), ("trailing-empty", "Hxgj py\n", 1)] {
                        let text = stock(font: font, pitch: pitch, variant: variant, string: string)
                        try measure(text, font: font, pitch: pitch, role: name, variant: variant, fixture: fixture, index: index)
                        closeWindows()
                    }
                    let text = stock(font: font, pitch: pitch, variant: variant,
                                     string: String(repeating: "Hxgj py example words wrapping naturally across the column. ", count: 3))
                    try measure(text, font: font, pitch: pitch, role: name, variant: variant, fixture: "wrapped-first", index: 0)
                    try measure(text, font: font, pitch: pitch, role: name, variant: variant, fixture: "wrapped-middle", index: 2)
                    closeWindows()
                }
            }
        }
    }
}
