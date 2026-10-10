import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Design review fixes D-05, D-07, D-10, D-12 (token side) and D-14
/// (`phaseX/design-review.md`), checked without showing a window.
@MainActor
final class PhaseXDesign1Tests: XCTestCase {
    // MARK: D-05 · notice headlines

    /// The two sentences the owner approved (commit bedb9323), word for word.
    static let approvedSentences = [
        "Proposals could not be read. Reopen Notes to try again. Your notes are kept.",
        "This attachment’s place in the note could not be read. Try again. Your note is kept."
    ]

    /// Every fixed notice sentence the page can raise (and the changing
    /// ones with a stand-in for their changing part).
    static let noticeSentences = approvedSentences + [
        "Saving recovery data…",
        "Recovery data is damaged: A.json.",
        "Recovery data is still being saved.",
        "Attachment data is still being read.",
        "Recovery data is still being saved. Try again when saving finishes.",
        "Damaged recovery was moved to quarantine. Its original data and files are preserved.",
        "Recovery copy saved as “Draft.attic-recovery”.",
        "Recovery copy saved to “Draft.attic-recovery”. 2 image(s) couldn’t be read and are listed in its README.",
        "The recovery copy couldn’t be saved: The file couldn’t be saved.",
        "An old recovery copy of this note couldn’t be cleared, so the note was not deleted. Try again.",
        "Your text was saved, but its old recovery copy is being kept until it can be checked.",
        "Saved, but an old recovery copy could not be cleared.",
        "Saved recovery is being kept because its bytes could not be handed off safely.",
        "Saved as a new note.",
        "Restored unsaved text.",
        "Pasted as a table.",
        "Finish Writing Tools first.",
        "Finish composing text before leaving this note.",
        "Finish Writing Tools or composing text before adding files.",
        "Finish Writing Tools or composing text before editing this note.",
        "Finish Writing Tools or composing text before deleting this note.",
        "Finish Writing Tools or composing text before duplicating this note.",
        "Writing Tools unavailable — couldn't save a safety copy.",
        "Writing Tools changed this note without a safety copy, so its rewrite was not kept.",
        "Writing Tools changed an image, checklist or date, so its rewrite was not kept.",
        "Images are still being added. Delete the note when they finish.",
        "Images are still being added. Duplicate the note when they finish.",
        "Finish the current file import before adding more files.",
        "An image is unavailable, so this draft remains in recovery until it can be restored.",
        "An image is unavailable, so the note was not duplicated.",
        "Couldn’t save a new note; your text is still in recovery.",
        "The latest text couldn’t be saved, so the note was not deleted.",
        "Keep this text as a new note before deleting it.",
        "Keep this text as a new note before duplicating it.",
        "This note can’t be duplicated here.",
        "The note couldn’t be duplicated: The store is busy.",
        "The note was deleted, so its file batch was not added.",
        "The note was deleted or is read only, so the files were not added.",
        "The files could not be added to this note.",
        "The file could not be added to this note.",
        "The file batch was cancelled.",
        "The batch could not be cancelled because recovery could not be updated.",
        "The batch could not be cancelled because its recovery copy could not be updated.",
        "The clipboard image could not be staged: The file couldn’t be opened.",
        "The current note must be saved before opening version history. Your text is kept.",
        "Version history could not be read. Try again. Your note is kept.",
        "Version history could not be read: The database is busy.",
        "The deletion proposal could not be restored.",
        "Attribution could not be acknowledged.",
        "A table can have at most 20 columns and 100 rows.",
        "That table is larger than 20 columns or 100 rows, so it was pasted as text.",
        "That paste would make the table larger than 20 columns by 100 rows, so nothing was pasted.",
        "An attachment couldn’t be read. Nothing was pasted.",
        "The note or selection changed. Paste again at the new selection.",
        "An error nobody planned for: it failed.",
        "Something happened."
    ]

    private func design(_ mode: AtticDesignContext.Mode = .light) -> AtticDesignContext {
        AtticDesignContext(mode: mode)
    }

    /// The status pill's width as laid out, for a given room.
    private func pillWidth(_ item: AtticStatusItem, more: Int = 0, closable: Bool, room: CGFloat) -> CGFloat {
        let pill = AtticStatusPill(item: item, more: more, inlineAction: nil, onCancel: closable ? {} : nil,
                                   maxWidth: room, onOpen: {})
            .atticDesign(design())
        return NSHostingView(rootView: AnyView(pill)).fittingSize.width
    }

    /// The default panel's room for the pill, beside Aa.
    private var slotAt320: CGFloat {
        AtticNoteMetrics.pillMaxWidth(panelWidth: 320, chromeInset: 16, showsFormat: true)
    }

    func testEveryNoticeHeadlineFitsTheSlotAt320() {
        XCTAssertEqual(slotAt320, 162)
        for headline in NoteStatusPresentation.allNoticeHeadlines {
            let item = AtticStatusItem(id: "notice", systemName: "info.circle", title: headline, tone: .normal)
            let pending = AtticStatusItem(id: "pending", systemName: nil, title: headline, tone: .quiet)
            // A notice has its ✕; a second state adds "+N"; progress has a spinner.
            for (name, width, natural) in [
                ("with ✕", pillWidth(item, closable: true, room: slotAt320), pillWidth(item, closable: true, room: 176)),
                ("with +1", pillWidth(item, more: 1, closable: false, room: slotAt320),
                 pillWidth(item, more: 1, closable: false, room: 176)),
                ("progress", pillWidth(pending, closable: false, room: slotAt320),
                 pillWidth(pending, closable: false, room: 176))
            ] {
                // Not cut: the pill is as wide at 162 as when it is given
                // every point the slot could ever have.
                XCTAssertEqual(width, natural, accuracy: 0.5, "“\(headline)” is cut \(name) at 320")
                XCTAssertLessThanOrEqual(width, slotAt320 + 0.5, "“\(headline)” is wider than the slot \(name)")
            }
        }
    }

    /// The test above is only worth something if it can fail.
    func testTheFitCheckSeesALongSentenceBeingCut() {
        let sentence = AtticStatusItem(id: "notice", systemName: "info.circle", title: Self.approvedSentences[0], tone: .normal)
        let cut = pillWidth(sentence, closable: true, room: slotAt320)
        let natural = pillWidth(sentence, closable: true, room: 4000)
        XCTAssertLessThan(cut, natural)
    }

    func testEveryKnownNoticeGetsAShortHeadlineAndKeepsItsSentenceForTheDetails() {
        let headlines = Set(NoteStatusPresentation.allNoticeHeadlines)
        for sentence in Self.noticeSentences {
            let headline = NoteStatusPresentation.headline(forNotice: sentence)
            XCTAssertTrue(headlines.contains(headline), "“\(headline)” is listed")
            XCTAssertLessThan(headline.count, sentence.count, sentence)
            XCTAssertLessThanOrEqual(headline.count, 16, headline)
            // The details say the sentence in full, unchanged.
            XCTAssertEqual(NoteStatusItem.notice(sentence).explanation, sentence)
            XCTAssertEqual(NoteStatusItem.notice(sentence).label, headline)
        }
        // Every rule is reached by a sentence the page can raise.
        let reached = Set(Self.noticeSentences.map(NoteStatusPresentation.headline(forNotice:)))
        for headline in NoteStatusPresentation.allNoticeHeadlines {
            XCTAssertTrue(reached.contains(headline), "no sentence in the list gets “\(headline)”")
        }
    }

    func testTheApprovedSentencesAreKeptWordForWordAndTheHeadlinesAreNew() {
        XCTAssertEqual(Self.approvedSentences, [
            "Proposals could not be read. Reopen Notes to try again. Your notes are kept.",
            "This attachment’s place in the note could not be read. Try again. Your note is kept."
        ])
        XCTAssertEqual(NoteStatusPresentation.headline(forNotice: Self.approvedSentences[0]), "Read failed")
        XCTAssertEqual(NoteStatusPresentation.headline(forNotice: Self.approvedSentences[1]), "Not readable")
        XCTAssertEqual(NoteStatusPresentation.headline(forNotice: "An image is unavailable, so the note was not duplicated."),
                       "Image gone")
        // A sentence nothing knows still gets a short headline.
        XCTAssertEqual(NoteStatusPresentation.headline(forNotice: "The disk exploded."), "Notice")
        XCTAssertEqual(NoteStatusPresentation.headline(forNotice: "That did not work because it failed."), "Didn’t work")
    }

    /// The other status words need no rewording: they fit the slot as they are.
    func testTheFixedStatusWordsFitTheSlotAt320() {
        for label in ["Only in memory", "Not saved", "Deleted elsewhere", "Adding files", "Read only"] {
            let item = AtticStatusItem(id: label, systemName: "lock", title: label, tone: .quiet)
            XCTAssertEqual(pillWidth(item, closable: false, room: slotAt320), pillWidth(item, closable: false, room: 176),
                           accuracy: 0.5, "“\(label)” is cut at 320")
        }
    }

    // MARK: D-07 · All notes on the shared column

    func testAllNotesTextHighlightAndEdgesSitOnTheSharedColumn() {
        for corner in PanelCornerSize.allCases.map(\.rawValue) {
            let layout = PanelPageLayout(cornerSize: corner, panelSize: CGSize(width: 320, height: 520))
            let chrome = layout.chromeInsets.leading
            let edge = AtticNoteMetrics.libraryPageEdge(chromeInset: chrome)
            // The column: the controls' line plus 12, as Tasks' circles and the note's text.
            let column = chrome + AtticLayout.contentFromChrome
            XCTAssertEqual(edge + AtticNoteMetrics.rowTextX, column, "row text, corner \(corner)")
            XCTAssertEqual(edge + AtticLayout.pageTabsX, column, "heading and labels, corner \(corner)")
            XCTAssertEqual(edge + AtticLayout.circleX, column, "Tasks' circles, corner \(corner)")
            // The highlight is on the controls' line, 12 clear of the text.
            XCTAssertEqual(edge + AtticNoteMetrics.libraryHighlightInset, chrome, "highlight, corner \(corner)")
            XCTAssertEqual(column - (edge + AtticNoteMetrics.libraryHighlightInset), 12)
            // Right edges mirror the left: the row text and the magnifier's glyph.
            XCTAssertEqual(edge + AtticNoteMetrics.rowTextX, column, "right text edge, corner \(corner)")
            let magnifierTrailing = max(0, AtticLayout.rowHighlightInset + AtticTaskRowMetrics.dateInset
                - (AtticControlSize.smallMinWidth - AtticSmallControlMetrics.iconSize) / 2)
            let glyphRight = edge + magnifierTrailing + (AtticControlSize.smallMinWidth - AtticSmallControlMetrics.iconSize) / 2
            XCTAssertEqual(glyphRight, column, accuracy: 0.001, "magnifier, corner \(corner)")
        }
        // The default corner: text at 28, highlight at 16 (320 pt panel).
        XCTAssertEqual(AtticNoteMetrics.libraryPageEdge(chromeInset: 16) + AtticNoteMetrics.rowTextX, 28)
        XCTAssertEqual(AtticNoteMetrics.libraryPageEdge(chromeInset: 16) + AtticNoteMetrics.libraryHighlightInset, 16)
    }

    // MARK: D-10 · quiet icons in the label tier

    func testTheTabsLineIconsAreNeverHeavierThanTheLabelsOnEverySurfaceAndPalette() throws {
        var checked = 0, labelTier = 0
        for context in AtticAppearanceCheck.allContexts() {
            let tokens = context.tokens
            let quiet = tokens.ink(tokens.quietIconInk), glyph = tokens.ink(.glyph), base = tokens.panel.base
            // Never heavier than the primary glyph, never under the icon floor.
            XCTAssertLessThanOrEqual(quiet.contrast(on: base), glyph.contrast(on: base) + 0.001, context.caption)
            XCTAssertGreaterThanOrEqual(quiet.contrast(on: base), AtticInk.Floor.nonText.ratio - 0.001, context.caption)
            if tokens.quietIconInk == .helper { labelTier += 1 }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 400)
        XCTAssertGreaterThan(labelTier, 0, "some surfaces take the secondary tier")
        // The default Solid panel: the same grey as the inactive page labels.
        XCTAssertEqual(design(.light).tokens.quietIconInk, .helper)
        XCTAssertEqual(design(.dark).tokens.quietIconInk, .helper)
        let light = design(.light).tokens.ink(.helper), dark = design(.dark).tokens.ink(.helper)
        func hex(_ c: AtticRGBA) -> [Int] { [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) } }
        XCTAssertEqual(hex(light), [0x7A, 0x7A, 0x7A], "Light: the inactive labels' ink")
        XCTAssertEqual(hex(dark), [0xA4, 0xA4, 0xA4], "Dark: the inactive labels' ink")
    }

    private func luminanceSpread(of button: AtticSmallButton, mode: AtticDesignContext.Mode) throws -> Double {
        let context = design(mode)
        let host = NSHostingView(rootView: AnyView(button.padding(8).background(context.tokens.panel.base.color).atticDesign(context)))
        host.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let background = context.tokens.panel.base
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        let backgroundLuma = luma(background.red, background.green, background.blue)
        var strongest = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                strongest = max(strongest, abs(luma(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) - backgroundLuma))
            }
        }
        return strongest
    }

    func testTheQuietIconIsDrawnLighterThanThePrimaryGlyph() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let primary = try luminanceSpread(of: AtticSmallButton(systemName: "magnifyingglass", label: "Find", action: {}), mode: mode)
            let quiet = try luminanceSpread(of: AtticSmallButton(systemName: "magnifyingglass", label: "Find", quietIcon: true, action: {}), mode: mode)
            XCTAssertGreaterThan(primary, 0.05, "the glyph is drawn (\(mode))")
            XCTAssertLessThan(quiet, primary, "the quiet icon is lighter than the primary glyph (\(mode))")
        }
    }

    // MARK: D-12 · the Copy chip inside the block

    func testTheCopyChipSitsSixInsideTheBlocksTopRightWithASmallRadius() {
        typealias T = AtticNoteType
        XCTAssertEqual([T.monoCopyInset, T.monoCopyTop], [6, 6])
        XCTAssertGreaterThanOrEqual(NoteMonoCopyButton.radius, 4)
        XCTAssertLessThanOrEqual(NoteMonoCopyButton.radius, 6)
    }

    // MARK: D-14 · no system items in Attic's own menus

    func testContextMenusTakeNoSystemPlugInItems() {
        let commands = [AtticMenuCommand("Copy Link", action: {}), AtticMenuCommand("Delete", action: {})]
        let menu = AtticNativeMenu.makeContextMenu(commands, appearance: nil)
        XCTAssertFalse(menu.allowsContextMenuPlugIns, "no AutoFill ›, no Services")
        XCTAssertEqual(menu.items.map(\.title), ["Copy Link", "Delete"])
        XCTAssertTrue(AtticNativeMenu.make(commands).allowsContextMenuPlugIns == true, "the plain menu is unchanged")
    }
}
