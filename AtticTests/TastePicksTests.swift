import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The owner's taste picks (2026-10-15, drafts `mockups/px-t14-*`):
/// T-03 C, T-04 B, T-06 B, T-09 C, T-15 B and T-16 B.
@MainActor
final class TastePicksTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    // MARK: T-16 B: the Light secondary grey

    func testT16LightSecondaryGreyIs737373AndPassesFourPointFive() {
        let light = AtticDesignContext(mode: .light).tokens
        XCTAssertEqual(light.ink(.helper).hexString, "#737373")
        XCTAssertEqual(light.ink(.placeholder).hexString, "#737373")
        XCTAssertGreaterThanOrEqual(light.ink(.helper).contrast(on: AtticRGBA(0xFFFFFF)), 4.5)
        // Increase Contrast keeps its own, stronger grey; Dark is unchanged.
        XCTAssertEqual(Calm.secondary(dark: false, increaseContrast: true).hexString, "#626262")
        XCTAssertEqual(Calm.secondary(dark: true, increaseContrast: false).hexString, "#A4A4A4")
    }

    // MARK: T-06 B: done titles in the secondary grey

    func testT06DoneTitlesUseTheSecondaryGrey() {
        XCTAssertEqual(AtticTaskRow.titleInk(done: true, disabled: false), .helper)
        XCTAssertEqual(AtticTaskRow.titleInk(done: false, disabled: false), .heading)
        XCTAssertEqual(AtticTaskRow.titleInk(done: true, disabled: true), .disabledText)
        XCTAssertEqual(AtticSubtaskRow.titleInk(isDone: true), .helper)
        XCTAssertEqual(AtticSubtaskRow.titleInk(isDone: false), .body)
    }

    private func makeEditor(_ blocks: [NoteBlock], width: CGFloat = 400,
                            design: AtticDesignContext = .default) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks), design: design)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = scrollView
        windows.append(host)
        host.makeFirstResponder(textView)
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        return (engine, textView)
    }

    /// The foreground TextKit draws `text` in: the rendering attribute the
    /// fragment's validator sets, else the stored one.
    private func drawnInk(of text: String, engine: NoteEditorEngine, textView: NoteEditorTextView) throws -> NSColor? {
        let location = (engine.textStorage.string as NSString).range(of: text).location
        XCTAssertNotEqual(location, NSNotFound)
        let manager = try XCTUnwrap(textView.textLayoutManager)
        let range = try XCTUnwrap(engine.textRange(for: NSRange(location: location, length: 1)))
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: range.location))
        manager.renderingAttributesValidator?(manager, fragment)
        var found: NSColor?
        manager.enumerateRenderingAttributes(from: range.location, reverse: false) { _, attributes, attributeRange in
            if attributeRange.contains(range.location) { found = attributes[.foregroundColor] as? NSColor }
            return false
        }
        return found ?? engine.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func testT06CheckedChecklistLinesDrawInTheSecondaryGrey() throws {
        let (engine, textView) = makeEditor([.text("Title"), .checklist("Milk", checked: true), .checklist("Rice")])
        let helper = engine.style.tokens.ink(.helper).nsColor
        XCTAssertEqual(try drawnInk(of: "Milk", engine: engine, textView: textView), helper, "a ticked line is grey")
        XCTAssertNotEqual(try drawnInk(of: "Rice", engine: engine, textView: textView), helper, "an open line keeps its ink")
        // Ticking and unticking recolours the line; the note's text is unchanged.
        let rice = (engine.textStorage.string as NSString).range(of: "Rice").location
        engine.toggleCheckbox(atLineOf: rice)
        textView.layoutSubtreeIfNeeded()
        XCTAssertEqual(try drawnInk(of: "Rice", engine: engine, textView: textView), helper)
        let milk = (engine.textStorage.string as NSString).range(of: "Milk").location
        engine.toggleCheckbox(atLineOf: milk)
        textView.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(try drawnInk(of: "Milk", engine: engine, textView: textView), helper)
        XCTAssertNotEqual(engine.textStorage.attribute(.foregroundColor, at: rice, effectiveRange: nil) as? NSColor, helper,
                          "the grey is drawn, never stored")
    }

    // MARK: T-09 C: fold chevrons only when folded or hovered

    private func heading(_ text: String) -> NoteBlock { .text(text, style: "heading") }

    func testT09ChevronsShowOnlyWhenFoldedOrHovered() throws {
        let (engine, textView) = makeEditor([.text("Title"), heading("Alpha"), .text("Body a"), heading("Beta"), .text("Body b")])
        engine.updateHeadingControls()
        let string = engine.textStorage.string as NSString
        let alpha = string.range(of: "Alpha").location, beta = string.range(of: "Beta").location
        let alphaButton = try XCTUnwrap(engine.headingControls[alpha])
        let betaButton = try XCTUnwrap(engine.headingControls[beta])
        XCTAssertFalse(alphaButton.isRevealed, "at rest an open heading shows no chevron")
        XCTAssertEqual(alphaButton.alphaValue, 0, accuracy: 0.001)
        XCTAssertFalse(alphaButton.isHidden, "still there for VoiceOver and the click")

        // The pointer anywhere on the heading's line shows its chevron, only its.
        let line = try XCTUnwrap(engine.rect(for: NSRange(location: alpha, length: 1)))
        textView.updateHeadingHover(at: NSPoint(x: textView.bounds.width - 40, y: line.midY))
        XCTAssertTrue(alphaButton.isRevealed, "hovering the line's far end")
        XCTAssertFalse(betaButton.isRevealed)
        textView.updateHeadingHover(at: NSPoint(x: line.minX + 1, y: line.midY))
        XCTAssertTrue(alphaButton.isRevealed)
        // The chevron itself counts as the line.
        textView.updateHeadingHover(at: NSPoint(x: alphaButton.frame.midX, y: alphaButton.frame.midY))
        XCTAssertTrue(alphaButton.isRevealed)
        // A body line hides it again.
        let body = try XCTUnwrap(engine.rect(for: NSRange(location: string.range(of: "Body a").location, length: 1)))
        textView.updateHeadingHover(at: NSPoint(x: body.midX, y: body.midY))
        XCTAssertFalse(alphaButton.isRevealed)
        textView.updateHeadingHover(at: nil)

        // A folded heading always shows its chevron.
        let frameBefore = betaButton.frame
        XCTAssertTrue(engine.toggleHeadingFold(at: beta))
        engine.updateHeadingControls()
        let folded = try XCTUnwrap(engine.headingControls[beta])
        XCTAssertTrue(folded.isRevealed)
        XCTAssertEqual(folded.frame, frameBefore, "no layout shift")
        XCTAssertFalse(alphaButton.isRevealed)
    }

    // MARK: T-15 B: Light panels' faint hairline

    func testT15LightSolidAndFrostedPanelsGetAFaintHairline() {
        let hairline = AtticRGBA.black(0.14)
        for surface in [PanelSurfaceStyle.solid, .frosted] {
            XCTAssertEqual(AtticPanelRim.lightHairline(for: AtticDesignContext(mode: .light, surface: surface)), hairline, "\(surface)")
            XCTAssertEqual(AtticPanelRim.lightHairline(for: AtticDesignContext(mode: .light, surface: surface, tint: .subtle)), hairline,
                           "\(surface), Tint on")
            XCTAssertNil(AtticPanelRim.lightHairline(for: AtticDesignContext(mode: .dark, surface: surface)), "Dark is unchanged")
            XCTAssertNil(AtticPanelRim.lightHairline(for: AtticDesignContext(mode: .light, surface: surface, increaseContrast: true)),
                         "Increase Contrast keeps its stronger edge")
        }
        XCTAssertNil(AtticPanelRim.lightHairline(for: AtticDesignContext(mode: .light, surface: .glass)), "Glass keeps its own edge")
        XCTAssertEqual(AtticPanelRim.lightHairlineWidth, 0.5)
    }

    // MARK: T-03 C: a short fade of the content behind the controls on see-through panels

    func testT03SeeThroughContentIsGoneBehindTheControlsAndBackAShortFadePast() {
        let edges = AtticFloatingEdges(top: 80, bottom: 60)
        let height: CGFloat = 500
        let fade = AtticEdgeBlurMetrics.translucentFade
        let stops = edges.stops(height: height, translucent: true)
        func opacity(_ y: CGFloat) -> Double { AtticScrollUnderFade.opacity(stops, at: y, height: height) }
        for y in stride(from: CGFloat(0), through: 80, by: 2) {
            XCTAssertEqual(opacity(y), 0, accuracy: 0.001, "gone behind the header at \(y)")
        }
        for y in stride(from: height - 60, through: height, by: 2) {
            XCTAssertEqual(opacity(y), 0, accuracy: 0.001, "gone behind and between the bottom buttons at \(y)")
        }
        XCTAssertEqual(opacity(80 + fade), 1, accuracy: 0.001)
        XCTAssertEqual(opacity(height - 60 - fade), 1, accuracy: 0.001)
        let ramp = stride(from: CGFloat(80), through: 80 + fade, by: 1).map(opacity)
        XCTAssertEqual(ramp, ramp.sorted(), "it eases in, never back")
        // Opaque panels keep their surface fade: the content stays whole.
        let opaque = edges.stops(height: height, translucent: false)
        XCTAssertEqual(AtticScrollUnderFade.opacity(opaque, at: 40, height: height), 1, accuracy: 0.001)
    }

    func testT03TheFadeNeverReachesARestingLine() {
        let fade = AtticEdgeBlurMetrics.translucentFade
        // Notes: the title rests 16 below the header, the last line 12 above the bottom row.
        XCTAssertLessThanOrEqual(fade, AtticNoteMetrics.titleTopGap)
        XCTAssertLessThanOrEqual(fade, AtticSpacing.s12)
        // Tasks and All notes: the first row rests where the plain line's ramp ends.
        let tabsTop: CGFloat = 60, height: CGFloat = 600
        let stops = TasksViewport.maskStops(height: height, tabsTop: tabsTop, translucent: true)
        XCTAssertEqual(AtticScrollUnderFade.opacity(stops, at: TasksViewport.listTop(tabsTop: tabsTop), height: height), 1, accuracy: 0.001)
    }

    // MARK: T-04 B: the page button shows its icon and the page's name

    func testT04ThePageButtonKeepsOneWidthShutAndOpenForEveryPage() {
        let open = AtticPageButton<PanelPage>.width(open: true, count: PanelPage.allCases.count)
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count), open,
                       "the name fits the switcher's width: hovering never resizes it")
        for page in PanelPage.allCases {
            XCTAssertLessThanOrEqual(AtticPageButtonMetrics.labelledWidth(title: page.title), open, page.title)
        }
        XCTAssertEqual(PanelHeaderLayout.pageSwitchWidth, open)
    }

    func testT04HeaderTitleIsBalancedAndStillWhenTheSwitcherOpens() {
        let switcher = PanelHeaderLayout.pageSwitchWidth
        for panel: CGFloat in [280, 320, 420] {
            for title: CGFloat in [0, 40, 100, 160, 4000] {
                let shut = AtticHeaderTitleSlot.placement(titleWidth: title, panelWidth: panel, chromeInset: 16,
                                                          switcherWidth: switcher, switcherOpen: false)
                let open = AtticHeaderTitleSlot.placement(titleWidth: title, panelWidth: panel, chromeInset: 16,
                                                          switcherWidth: switcher, switcherOpen: true)
                XCTAssertEqual(shut, open, "panel \(panel) title \(title): no slide on hover")
                XCTAssertGreaterThanOrEqual(shut.x, 16 + AtticControlSize.headerControl + AtticHeaderTitleSlot.gap - 0.001)
                XCTAssertLessThanOrEqual(shut.maxX, panel - 16 - switcher - AtticHeaderTitleSlot.gap + 0.001)
            }
        }
        // A short title sits on the panel's centre at 320.
        let short = AtticHeaderTitleSlot.placement(titleWidth: 60, panelWidth: 320, chromeInset: 16,
                                                   switcherWidth: switcher, switcherOpen: false)
        XCTAssertEqual(short.x + short.width / 2, 160, accuracy: 0.001)
    }

    // MARK: T-10: the default highlight is yellow

    func testT10TheOneClickHighlightIsYellowWithoutAColourKey() throws {
        let (engine, _) = makeEditor([.text("Title"), .text("Two months free")])
        let words = (engine.textStorage.string as NSString).range(of: "months")
        XCTAssertTrue(engine.perform(.mark(.highlight), selection: words))
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow)
        XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(.highlight, offset: 4, length: 6)])
        XCTAssertTrue(engine.perform(.mark(.highlight), selection: words), "a second click takes it off")
        XCTAssertTrue(engine.document().blocks[1].marks.isEmpty)
        XCTAssertEqual(NoteHighlightColour.menuOrder.first, .yellow)
        XCTAssertEqual(Set(NoteHighlightColour.menuOrder), Set(NoteHighlightColour.allCases), "grey and every hue stay")
    }

    func testT10AnUnkeyedHighlightReadsYellowAndIsKeptAsStored() throws {
        var block = NoteBlock.text("Two months free")
        block.marks = [NoteMark(.highlight, offset: 4, length: 6)]
        let document = NoteDocument(blocks: [.text("Title"), block])
        let (engine, _) = makeEditor(document.blocks)
        let words = (engine.textStorage.string as NSString).range(of: "months")
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow)
        XCTAssertEqual(engine.textStorage.attribute(.backgroundColor, at: words.location, effectiveRange: nil) as? NSColor,
                       engine.style.tokens.highlightMarker.nsColor, "it looks as it did")
        XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(.highlight, offset: 4, length: 6)], "no colour key is added")
    }

    func testT10DarkYellowKeepsNoteTextReadable() {
        for surface in PanelSurfaceStyle.allCases {
            let tokens = AtticDesignContext(mode: .dark, surface: surface).tokens
            let yellow = tokens.highlightMarker(.yellow)
            for y in [AtticSurfaceModel.contentTop, 1] {
                let ground = yellow.over(tokens.panel.composite(.midGrey, at: y))
                for ink in [AtticInk.body, .heading] {
                    XCTAssertGreaterThanOrEqual(tokens.ink(ink).contrast(on: ground), 4.5, "\(surface) \(ink)")
                }
            }
        }
    }
}
