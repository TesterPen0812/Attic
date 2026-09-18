import AppKit
import CoreGraphics
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Attic

@MainActor
private final class DrivenMagnificationGestureRecognizer:
    NSMagnificationGestureRecognizer {
    private var drivenState: NSGestureRecognizer.State = .possible

    override var state: NSGestureRecognizer.State {
        get { drivenState }
        set { drivenState = newValue }
    }

    func drive(
        _ state: NSGestureRecognizer.State,
        magnification: CGFloat
    ) {
        self.magnification = magnification
        self.state = state
    }
}

@MainActor
private final class CanvasTestFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let fileName: String

    init(fileName: String) {
        self.fileName = fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class CanvasAffordanceTruthTests: XCTestCase {
    func testLegacyObjectAffordancesNameTheActuallyEditableRepresentation() {
        XCTAssertEqual(CanvasTool.select.title, "Select Object")
        XCTAssertEqual(
            CanvasLegacyObjectAffordance.addTextTitle,
            "Add Text Image"
        )
        XCTAssertEqual(
            CanvasLegacyObjectAffordance.addShapeTitle,
            "Draw Shape as Ink"
        )
        XCTAssertTrue(
            CanvasPendingPlacement.text(CanvasTextPlacement(
                text: "Legacy",
                prefersDarkSurface: false
            )).instruction.contains("editable text")
        )
        XCTAssertTrue(
            CanvasPendingPlacement.shape(.rectangle).instruction.contains("place a rectangle")
        )
        XCTAssertTrue(
            CanvasLegacyObjectAffordance.textDisclosure.contains("not editable")
        )
    }
}

final class CanvasAccessibilityTests: XCTestCase {
    func testAccessibilityNumberTextKeepsIntegralAndFractionalFormatting() {
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: 12), "12")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: -3), "-3")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: 0), "0")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: 12.5), "12.5")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: -0.5), "-0.5")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: Double(Int.min)), "-9223372036854775808")
    }

    func testAccessibilityNumberTextDoesNotTrapOutsideIntRangeOrOnNonFiniteValues() {
        // Persisted geometry is validated as finite, not bounded. `Int(_:)`
        // traps on these values; the description must degrade instead.
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: Double(Int.max)), "9223372036854775808.0")
        XCTAssertEqual(CanvasAccessibilityNumberText.string(for: 18_446_744_073_709_551_616.0), "18446744073709551616.0")
        let huge = CanvasAccessibilityNumberText.string(for: 1e300)
        XCTAssertTrue(huge.hasPrefix("1"))
        XCTAssertTrue(huge.hasSuffix(".0"))
        XCTAssertTrue(CanvasAccessibilityNumberText.string(for: -1e300).hasPrefix("-1"))
        XCTAssertFalse(CanvasAccessibilityNumberText.string(for: .infinity).isEmpty)
        XCTAssertFalse(CanvasAccessibilityNumberText.string(for: -.infinity).isEmpty)
        XCTAssertFalse(CanvasAccessibilityNumberText.string(for: .nan).isEmpty)
    }

    @MainActor
    func testViewportKeysWorkAfterInlineCommitWithoutOpeningMenuAndRespectFocusAndSaveVeto() throws {
        let gate = PersistenceGate()
        let session = CanvasSession(store: try makeTestCanvasStore(persist: gate.save))
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 315, height: 383),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 315, height: 383))
        panel.contentView = view
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
                                               clearReadabilityEnabled: false)
        session.selectTextTool()
        bridge.configure(view)
        let draft = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 200))
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        var editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText("Editable canvas text", replacementRange: NSRange(location: 0, length: 0))
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        bridge.configure(view)
        view.beginSemanticTextEditing(try XCTUnwrap(session.selectedSemanticObject))
        editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" revised", replacementRange: editor.selectedRange())
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        bridge.configure(view)
        XCTAssertTrue(panel.firstResponder === view)
        XCTAssertNil(view.semanticTextEditor)
        let original = session.viewport
        let fit = try canvasKeyEvent(keyCode: 25, characters: "9", modifiers: .command)
        let reset = try canvasKeyEvent(keyCode: 29, characters: "0", modifiers: .command)
        XCTAssertTrue(view.performKeyEquivalent(with: fit))
        XCTAssertGreaterThan(abs(session.viewport.scale - original.scale), 0.01)
        XCTAssertTrue(view.performKeyEquivalent(with: reset))
        XCTAssertEqual(session.viewport, original)

        view.beginSemanticTextEditing(try XCTUnwrap(session.selectedSemanticObject))
        editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" unsaved", replacementRange: editor.selectedRange())
        gate.shouldFail = true
        XCTAssertTrue(view.performKeyEquivalent(with: fit))
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(view.semanticTextEditor === editor)
        XCTAssertEqual(session.viewport, original)
        gate.shouldFail = false
        XCTAssertTrue(view.performKeyEquivalent(with: fit))
        XCTAssertTrue(panel.firstResponder === view)
        XCTAssertTrue(session.selectedSemanticObject?.content?.text?.hasSuffix(" unsaved") == true)
        XCTAssertTrue(view.performKeyEquivalent(with: reset))
        let otherEditor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        view.addSubview(otherEditor)
        panel.makeFirstResponder(otherEditor)
        XCTAssertFalse(view.performKeyEquivalent(with: fit))
        XCTAssertTrue(panel.firstResponder === otherEditor)
        XCTAssertEqual(session.viewport, original)
        panel.makeFirstResponder(view)
        view.deactivateRepresentation()
        XCTAssertFalse(view.performKeyEquivalent(with: fit))
        XCTAssertEqual(session.viewport, original)
    }

    @MainActor
    func testViewportShortcutAfterSectionReplacementClaimsOnlyUnassignedWindowFocus() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectTextTool()
        var draft = try XCTUnwrap(session.makeTextInsertion(at: CanvasPoint(x: 20, y: 40), width: 160))
        draft = CanvasSemanticTextDraft(baseline: draft.baseline, text: "Keep viewport commands", isInsertion: true)
        XCTAssertTrue(session.commitSemanticText(draft))
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 315, height: 383),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let oldView = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 315, height: 383))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
                                               clearReadabilityEnabled: false)
        panel.contentView = oldView
        bridge.configure(oldView)
        panel.makeFirstResponder(oldView)
        oldView.deactivateRepresentation()
        panel.contentView = NSView(frame: oldView.frame)
        panel.makeFirstResponder(nil)
        let view = CanvasNSView(frame: oldView.frame)
        bridge.configure(view)
        panel.contentView = view
        panel.makeFirstResponder(nil)
        XCTAssertTrue(panel.firstResponder === panel)
        let fit = try canvasKeyEvent(keyCode: 25, characters: "9", modifiers: [.command, .capsLock])
        let reset = try canvasKeyEvent(keyCode: 82, characters: "0", modifiers: [.command, .numericPad])
        XCTAssertFalse(oldView.performKeyEquivalent(with: fit))
        XCTAssertTrue(view.performKeyEquivalent(with: fit))
        XCTAssertTrue(panel.firstResponder === view)
        XCTAssertNotEqual(session.viewport.scale, 1)
        XCTAssertTrue(view.performKeyEquivalent(with: reset))
        XCTAssertEqual(session.viewport, CanvasViewport())
        for modifier: NSEvent.ModifierFlags in [.shift, .option, .control] {
            XCTAssertFalse(view.performKeyEquivalent(with: try canvasKeyEvent(
                keyCode: 25, characters: "9", modifiers: [.command, modifier])))
            XCTAssertEqual(session.viewport, CanvasViewport())
        }
        panel.makeFirstResponder(nil)
        view.isHidden = true
        XCTAssertFalse(view.performKeyEquivalent(with: fit))
        XCTAssertTrue(panel.firstResponder === panel)
        XCTAssertEqual(session.viewport, CanvasViewport())
    }

    @MainActor
    func testClearReadabilityUsesOppositeResolvedInkAndPreservesInlineDraftSelection() throws {
        let whiteEdge = CanvasSemanticRenderer.readabilityEdgeColor(for: .black, increasedContrast: false)
        let blackEdge = CanvasSemanticRenderer.readabilityEdgeColor(for: .white, increasedContrast: true)
        XCTAssertEqual(whiteEdge.usingColorSpace(.deviceRGB)?.redComponent, 1)
        XCTAssertEqual(whiteEdge.alphaComponent, 0.90, accuracy: 0.001)
        XCTAssertEqual(blackEdge.usingColorSpace(.deviceRGB)?.redComponent, 0)
        XCTAssertEqual(blackEdge.alphaComponent, 1)

        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectTextTool()
        let draft = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 200))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
                                 clearReadabilityEnabled: false).configure(view)
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText("Keep this draft", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        let selection = editor.selectedRange()
        let frame = editor.frame
        let storage = try XCTUnwrap(editor.textStorage)
        view.clearReadabilityEnabled = true
        view.layoutSemanticTextEditor()
        let shadow = try XCTUnwrap(storage.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow)
        XCTAssertEqual(shadow.shadowOffset, .zero)
        XCTAssertEqual(shadow.shadowBlurRadius, AtticClearGlassReadabilityPolicy.edgeRadius)
        view.layoutSemanticTextEditor()
        XCTAssertTrue(storage.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow === shadow)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.frame, frame)
        XCTAssertEqual(editor.string, "Keep this draft")
        XCTAssertTrue(session.semanticObjects.isEmpty)
        editor.insertText("new", replacementRange: selection)
        XCTAssertNotNil(storage.attribute(.shadow, at: 5, effectiveRange: nil))
        let editedText = editor.string
        let editedSelection = editor.selectedRange()
        view.clearReadabilityEnabled = false
        view.layoutSemanticTextEditor()
        XCTAssertNil(storage.attribute(.shadow, at: 0, effectiveRange: nil))
        XCTAssertNil(editor.typingAttributes[.shadow])
        XCTAssertEqual(editor.string, editedText)
        XCTAssertEqual(editor.selectedRange(), editedSelection)
        XCTAssertTrue(view.finishSemanticTextEditing(commit: true))
        XCTAssertEqual(session.semanticObjects.first?.content?.text, editedText)
    }

    @MainActor
    func testClearReadabilityPaintsSemanticTextAndShapesWithoutLeakingOntoImagesOrCache() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let cache = CanvasSemanticRenderCache()
        let text = CanvasSemanticObject(textInsertionAt: CanvasPoint(x: 20, y: 20), canvasID: UUID(),
            generation: 0, content: CanvasSemanticContent(text: "Readable", color: .ink, strokeWidth: 2), width: 160)
        var shape = text
        shape.content = CanvasSemanticContent(shape: .rectangle, color: .ink, strokeWidth: 2)
        let image = makeAccessibilityImage(id: UUID(), center: CanvasPoint(x: 210, y: 210),
            width: 24, height: 24, zIndex: 1, createdAt: Date())
        let source = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(NSColor.red.withAlphaComponent(0.5).cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let decoded = try XCTUnwrap(source.makeImage())
        func pixels(_ object: CanvasSemanticObject, edge: Bool, imagePassOnly: Bool = false) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            appearance.performAsCurrentDrawingAppearance {
                CanvasSemanticRenderer.draw(object, in: context, cache: cache, clearReadabilityEnabled: edge)
            }
            // Erase only pixels, preserving graphics state. Any leaked shadow
            // will remain visible under this translucent image. Comparing the
            // entire image-only pass avoids flipped-bitmap sampling mistakes.
            if imagePassOnly { context.clear(CGRect(x: 0, y: 0, width: 256, height: 256)) }
            drawCanvasImage(image, decoded: decoded, in: context)
            let data = try XCTUnwrap(context.makeImage()?.dataProvider?.data)
            return Array(data as Data)
        }
        for object in [text, shape] {
            let plain = try pixels(object, edge: false)
            let edged = try pixels(object, edge: true)
            XCTAssertNotEqual(plain, edged)
            let plainImage = try pixels(object, edge: false, imagePassOnly: true)
            let edgedImage = try pixels(object, edge: true, imagePassOnly: true)
            XCTAssertTrue(plainImage == edgedImage, "Semantic edge must not change subsequent image pixels")
        }
        let content = try XCTUnwrap(text.content)
        var framesetterIdentity: ObjectIdentifier?
        appearance.performAsCurrentDrawingAppearance {
            framesetterIdentity = ObjectIdentifier(cache.framesetter(for: text, content: content))
        }
        _ = try pixels(text, edge: true)
        _ = try pixels(text, edge: false)
        appearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(ObjectIdentifier(cache.framesetter(for: text, content: content)), framesetterIdentity)
        }
        XCTAssertEqual(text.content, content)
    }

    @MainActor
    func testFailedInsertionOnVirtualFirstPageCannotBeStrandedByCreatingCanvas() throws {
        let gate = PersistenceGate()
        let store = try makeTestCanvasStore(persist: gate.save)
        let session = CanvasSession(store: store)
        let originalID = session.selectedCanvasID
        session.selectTextTool()
        let draft = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 160))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
                                 clearReadabilityEnabled: false).configure(view)
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        try XCTUnwrap(view.semanticTextEditor).insertText("Keep first draft", replacementRange: NSRange(location: 0, length: 0))
        gate.shouldFail = true
        XCTAssertFalse(view.finishSemanticTextEditing(commit: true))
        view.suspendSemanticTextEditing()
        gate.shouldFail = false
        XCTAssertNil(session.createCanvas(name: "Other page"))
        XCTAssertEqual(session.selectedCanvasID, originalID)
        XCTAssertEqual(session.canvases.map(\.id), [originalID])
        XCTAssertTrue(session.lastErrorMessage?.contains("unsaved canvas text is retained") == true)
        let retained = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 160))
        XCTAssertEqual(retained.text, "Keep first draft")
        XCTAssertTrue(session.commitSemanticText(retained))
        XCTAssertNotNil(session.createCanvas(name: "Other page"))
        XCTAssertTrue(session.selectCanvas(originalID))
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep first draft")
    }

    @MainActor
    func testLiveInsertionUsesNativeLayoutForLongTextTrailingLinesAndViewportResize() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectTextTool()
        let draft = try XCTUnwrap(session.makeTextInsertion(at: CanvasPoint(x: 10, y: 20), width: 180))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        XCTAssertTrue(container.widthTracksTextView)
        XCTAssertFalse(container.heightTracksTextView)
        let longText = String(repeating: "A long line wraps in this insertion.\n", count: 40)
        editor.insertText(longText, replacementRange: NSRange(location: 0, length: 0))
        let longHeight = editor.frame.height
        XCTAssertGreaterThan(longHeight, 1_000)
        XCTAssertGreaterThan(layout.extraLineFragmentRect.height, 0)
        XCTAssertGreaterThanOrEqual(editor.frame.height, layout.extraLineFragmentRect.maxY + 12)
        let selection = editor.selectedRange()

        view.setFrameSize(CGSize(width: 320, height: 520))
        view.layoutSemanticTextEditor()
        XCTAssertTrue(view.semanticTextEditor === editor)
        XCTAssertTrue(editor.layoutManager === layout)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, longText)

        session.zoom(by: 2, anchoredAt: CGPoint(x: 160, y: 260), in: view.bounds.size)
        bridge.configure(view)
        XCTAssertEqual(editor.frame.width, 360, accuracy: 0.001)
        XCTAssertEqual(editor.font?.pointSize ?? 0, 48, accuracy: 0.001)
        XCTAssertEqual(editor.textContainerInset.height, 8, accuracy: 0.001)
        // System-font optical sizing changes wrapping (on macOS 27 this text
        // has 120 lines at 24pt but 80 at 48pt), so height is not linear in zoom.
        // Compare against a fresh native layout to detect stale zoomed glyphs.
        let reference = NSTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 100_000))
        reference.font = .systemFont(ofSize: 48)
        reference.textContainerInset = CGSize(width: 8, height: 8)
        reference.textContainer?.lineFragmentPadding = 0
        reference.string = longText
        let referenceLayout = try XCTUnwrap(reference.layoutManager)
        let referenceContainer = try XCTUnwrap(reference.textContainer)
        referenceLayout.ensureLayout(for: referenceContainer)
        let expectedHeight = ceil(max(referenceLayout.usedRect(for: referenceContainer).maxY,
                                      referenceLayout.extraLineFragmentRect.maxY) + 24)
        XCTAssertEqual(editor.frame.height, expectedHeight, accuracy: 0.001)
        XCTAssertGreaterThan(editor.frame.height, longHeight)
        XCTAssertEqual(editor.selectedRange(), selection)

        editor.insertText("Short\n", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertLessThan(editor.frame.height, 200)
        XCTAssertGreaterThanOrEqual(editor.frame.height, layout.extraLineFragmentRect.maxY + 24)
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        let markedRange = editor.markedRange()
        view.layoutSemanticTextEditor()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertTrue(editor.layoutManager === layout)
        editor.unmarkText()
        let finalText = editor.string
        var content = try XCTUnwrap(draft.baseline.content)
        content.text = finalText
        let savedSize = CanvasSemanticRenderer.textSize(content, width: draft.baseline.transform.width)
        XCTAssertTrue(view.finishSemanticTextEditing(commit: true))
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, finalText)
        XCTAssertEqual(session.selectedSemanticObject?.transform.height, savedSize.height)
        XCTAssertEqual(session.selectedSemanticObject?.worldRect.origin, draft.baseline.worldRect.origin)
    }

    @MainActor
    func testDirectTextInsertionUsesClickedOriginAndOneDurableUndoableCommit() throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        session.zoom(by: 2, anchoredAt: CGPoint(x: 240, y: 180), in: CGSize(width: 480, height: 360))
        session.selectTextTool()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        panel.contentView = view
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        XCTAssertEqual(view.baseCursorRole, .textPlacement)
        let click = CGPoint(x: 80, y: 100)
        view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(click, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0.5
        )))
        let editor = try XCTUnwrap(view.semanticTextEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertEqual(editor.frame.minX + editor.textContainerInset.width, click.x, accuracy: 0.001)
        XCTAssertEqual(editor.frame.minY + editor.textContainerInset.height, click.y, accuracy: 0.001)
        XCTAssertTrue(store.semanticObjects.isEmpty)
        XCTAssertFalse(session.canUndo)
        editor.insertText("Direct text", replacementRange: NSRange(location: 0, length: 0))
        bridge.configure(view)
        XCTAssertTrue(view.semanticTextEditor === editor)
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertEqual(session.semanticObjects.count, 1)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, "Direct text")
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Direct text")
    }

    @MainActor
    func testUnsavedTextInsertionRetainsFailureAcrossRecreationAndFencesPageGeneration() throws {
        let gate = PersistenceGate()
        let store = try makeTestCanvasStore(persist: gate.save)
        let session = CanvasSession(store: store)
        // Persist both pages: the initial empty placeholder is not a stored
        // board and disappears when the first actual board is created.
        XCTAssertNotNil(session.createCanvas(name: "Draft page"))
        session.selectTextTool()
        let draft = try XCTUnwrap(session.makeTextInsertion(at: CanvasPoint(x: 12, y: 30), width: 160))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText("Retain me", replacementRange: NSRange(location: 0, length: 0))
        gate.shouldFail = true
        XCTAssertFalse(view.finishSemanticTextEditing(commit: true))
        XCTAssertTrue(view.semanticTextEditor === editor)
        XCTAssertTrue(store.semanticObjects.isEmpty)
        view.suspendSemanticTextEditing()
        let retained = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 280))
        XCTAssertEqual(retained.baseline.id, draft.baseline.id)
        XCTAssertEqual(retained.text, "Retain me")
        XCTAssertEqual(retained.baseline.worldRect.origin, CGPoint(x: 12, y: 30))
        gate.shouldFail = false
        XCTAssertNotNil(session.createCanvas(name: "Other page"))
        XCTAssertFalse(session.commitSemanticText(retained))
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertTrue(session.selectCanvas(retained.baseline.canvasID))
        XCTAssertTrue(store.clearBoard())
        XCTAssertFalse(session.commitSemanticText(retained))
        XCTAssertEqual(session.semanticTextDraft(retained.key)?.text, "Retain me")
    }

    @MainActor
    func testEmptyOrCancelledInsertionNeverCreatesPersistentObject() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        session.selectTextTool()
        let draft = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 120))
        XCTAssertTrue(session.commitSemanticText(draft))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        view.beginSemanticTextEditing(draft.baseline, insertion: draft)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText("Discard me", replacementRange: NSRange(location: 0, length: 0))
        editor.keyDown(with: try canvasKeyEvent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertNil(session.semanticTextDraft(draft.key))
        XCTAssertTrue(session.semanticObjects.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testHostedNativeMouseSequenceCompletesInkAfterFocusAndSelectionRefresh() throws {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        panel.contentView = view
        view.activateRepresentation()
        func configure() {
            view.configure(canvasID: CanvasBoardItem.logicalBoardID, strokes: [], images: [],
                           selectedImageID: nil, tool: .pen, color: .ink, width: 3,
                           viewport: CanvasViewport(), pendingPlacement: nil,
                           clearReadabilityEnabled: false)
        }
        configure()
        view.onSelectImage = { _ in configure() }
        view.onSelectSemanticObject = { _ in configure() }
        var completedPoints: [[CanvasPoint]] = []
        view.onCompleteStroke = { points, _, _ in completedPoints.append(points) }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0.5
            ))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 70, y: 84)))
        XCTAssertEqual(view.interaction.machine.state, .drawing)
        configure()
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 160, y: 120)))
        XCTAssertEqual(view.interaction.machine.state, .drawing)
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 250, y: 150)))
        XCTAssertEqual(completedPoints.count, 1)
        XCTAssertEqual(completedPoints.first?.count, 3)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testUntouchedSemanticEditorRefreshesExternalTextWithoutOverwritingIt() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let placed = await session.insertText("Original", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        let object = try XCTUnwrap(session.selectedSemanticObject)
        view.beginSemanticTextEditing(object)
        let external = ModelContext(store.container)
        let row = try XCTUnwrap(external.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first)
        var changed = try XCTUnwrap(object.content)
        changed.text = "Newer saved text"
        row.payload = try JSONEncoder().encode(changed)
        row.mutationVersion += 1
        try external.save()
        store.refresh()
        bridge.configure(view)
        XCTAssertEqual(view.semanticTextEditor?.string, "Newer saved text")
        XCTAssertTrue(view.finishSemanticTextEditing(commit: true))
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, "Newer saved text")
    }

    @MainActor
    func testDirtySemanticEditorFencesExternalAndUnsupportedPayloadChanges() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let placed = await session.insertText("Original", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        let object = try XCTUnwrap(session.selectedSemanticObject)
        view.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" local draft", replacementRange: NSRange(location: 8, length: 0))
        let draft = editor.string
        let external = ModelContext(store.container)
        let row = try XCTUnwrap(external.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first)
        var changed = try XCTUnwrap(object.content)
        changed.text = "External winner"
        row.payload = try JSONEncoder().encode(changed)
        row.mutationVersion += 1
        try external.save()
        store.refresh()
        // The session fence also protects the window before SwiftUI has called configure.
        XCTAssertFalse(view.finishSemanticTextEditing(commit: true))
        bridge.configure(view)
        XCTAssertEqual(editor.string, draft)
        XCTAssertEqual(session.semanticTextDraft(object.id), draft)
        XCTAssertTrue(session.lastErrorMessage?.contains("Escape") == true)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, "External winner")
        view.suspendSemanticTextEditing()
        view.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        XCTAssertEqual(view.semanticTextEditor?.string, draft)
        XCTAssertFalse(view.finishSemanticTextEditing(commit: true))
        let unsupported = ModelContext(store.container)
        let unknownRow = try XCTUnwrap(unsupported.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).first)
        unknownRow.kind = "future-object"
        unknownRow.payloadVersion = 99
        unknownRow.payload = Data([128, 255, 3])
        unknownRow.mutationVersion += 1
        try unsupported.save()
        store.refresh()
        bridge.configure(view)
        XCTAssertFalse(view.finishSemanticTextEditing(commit: true))
        XCTAssertEqual(session.semanticTextDraft(object.id), draft)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.payload, Data([128, 255, 3]))
        view.semanticTextEditor?.keyDown(with: try canvasKeyEvent(keyCode: 53, characters: "\u{1B}"))
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertNil(session.semanticTextDraft(object.id))
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.payloadVersion, 99)
    }

    @MainActor
    func testSemanticDraftKeysSeparateSameUUIDOnDifferentPages() throws {
        let store = try makeTestCanvasStore()
        let pageA = CanvasBoardItem.logicalBoardID
        let pageB = UUID()
        let objectID = UUID()
        let seed = ModelContext(store.container)
        seed.insert(CanvasBoardItem(id: pageA, name: "A"))
        seed.insert(CanvasBoardItem(id: pageB, name: "B", sortIndex: 1))
        for (page, text) in [(pageA, "Page A"), (pageB, "Page B")] {
            let row = CanvasSemanticObjectItem(id: objectID, canvasID: page)
            row.payload = try JSONEncoder().encode(CanvasSemanticContent(text: text, color: .ink, strokeWidth: 3))
            seed.insert(row)
        }
        try seed.save()
        store.refresh()
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.selectCanvas(pageA))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        view.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        view.semanticTextEditor?.insertText(" draft A", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(session.selectCanvas(pageB))
        bridge.configure(view)
        XCTAssertNil(session.semanticTextDraft(objectID))
        view.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        XCTAssertEqual(view.semanticTextEditor?.string, "Page B")
        view.semanticTextEditor?.insertText(" draft B", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(session.selectCanvas(pageA))
        bridge.configure(view)
        view.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        XCTAssertEqual(view.semanticTextEditor?.string, "Page A draft A")
        XCTAssertEqual(session.semanticTextDraft(CanvasReplicaKey(canvasID: pageB, id: objectID))?.text, "Page B draft B")
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, "Page A")
    }

    @MainActor
    func testUnifiedPlacedObjectOrderPreservesLegacyImageDateTieBreak() {
        let older = makeAccessibilityImage(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            center: .zero, width: 80, height: 60, zIndex: 0, createdAt: Date(timeIntervalSince1970: 1))
        let newer = makeAccessibilityImage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            center: .zero, width: 80, height: 60, zIndex: 0, createdAt: Date(timeIntervalSince1970: 2))
        let sorted = [CanvasPlacedRenderObject.image(newer), .image(older)].sorted(by: CanvasPlacedRenderObject.comesBefore)
        XCTAssertEqual(sorted.map(\.id), [older.id, newer.id])
        XCTAssertEqual(CanvasImagePlacement.topmostImage(at: .zero, images: [older, newer])?.id, sorted.last?.id)
    }

    @MainActor
    func testSemanticObjectKeyboardSelectionEditingAndFailedDraftSurviveRecreation() async throws {
        let gate = PersistenceGate()
        let store = try makeTestCanvasStore(persist: gate.save)
        let session = CanvasSession(store: store)
        let placed = await session.insertText("Original text", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        session.selectTool(.select)
        session.selectSemanticObject(nil)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        let id = try XCTUnwrap(session.semanticObjects.first?.id)
        XCTAssertEqual(view.focusNextCanvasObject(backward: false), id)
        XCTAssertEqual(session.selectedSemanticObjectID, id)
        let children = try XCTUnwrap(view.accessibilityChildren() as? [CanvasAccessibilityObjectElement])
        let element = try XCTUnwrap(children.first)
        XCTAssertTrue(element.availableActions.contains(.editText))
        XCTAssertTrue(element.perform(.moveRight))
        XCTAssertEqual(session.selectedSemanticObject?.transform.center.x, 1)
        bridge.configure(view)
        let beforeWidth = try XCTUnwrap(session.selectedSemanticObject?.transform.width)
        view.keyDown(with: try canvasKeyEvent(keyCode: 124, characters: "", modifiers: .option))
        XCTAssertEqual(try XCTUnwrap(session.selectedSemanticObject?.transform.width), beforeWidth * 1.1, accuracy: 0.001)
        bridge.configure(view)
        view.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r"))
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" unsaved 📝", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        let draft = editor.string
        XCTAssertTrue(draft.contains("unsaved 📝"))
        gate.shouldFail = true
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertTrue(view.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticTextDraft(id), draft)
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, "Original text")
        XCTAssertNotNil(session.lastErrorMessage)
        view.deactivateRepresentation()
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertEqual(session.semanticTextDraft(id), draft)
        let recreated = CanvasNSView(frame: view.frame)
        bridge.configure(recreated)
        recreated.beginSemanticTextEditing(try XCTUnwrap(session.selectedSemanticObject))
        XCTAssertEqual(recreated.semanticTextEditor?.string, draft)
        gate.shouldFail = false
        recreated.semanticTextEditor?.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(recreated.semanticTextEditor)
        XCTAssertNil(session.semanticTextDraft(id))
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, draft)
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.text, draft)
        XCTAssertTrue(CanvasEditCommandRoute.undo(session: session, section: .canvas))
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, "Original text")
        XCTAssertTrue(CanvasEditCommandRoute.redo(session: session, section: .canvas))
        XCTAssertEqual(session.selectedSemanticObject?.content?.text, draft)
    }

    @MainActor
    func testInlineEscapeCancelsDraftWithoutDeletingObjectAndNativeUndoStaysInEditor() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        let object = try XCTUnwrap(session.selectedSemanticObject)
        view.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.string, "Keep draft")
        XCTAssertNotNil(editor.undoManager)
        XCTAssertTrue(editor.performKeyEquivalent(with: try canvasKeyEvent(keyCode: 6, characters: "z", modifiers: .command)))
        XCTAssertEqual(editor.string, "Keep")
        XCTAssertEqual(session.semanticObjects.count, 1)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")
        editor.keyDown(with: try canvasKeyEvent(keyCode: 53, characters: "\u{1B}"))
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertNil(session.semanticTextDraft(object.id))
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.semanticObjects.isEmpty)
    }

    @MainActor
    func testTextEditorResignationCommitsWithoutKeyboardFocusCallback() throws {
        let editor = CanvasSemanticTextEditor(frame: .zero)
        var commits = 0
        var keyboardCommits = 0
        editor.onCommit = { commits += 1; return true }
        editor.onKeyboardCommit = { keyboardCommits += 1 }
        _ = editor.resignFirstResponder()
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(keyboardCommits, 0)
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(keyboardCommits, 1)
        editor.onCommit = { false }
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertEqual(keyboardCommits, 1)
    }

    @MainActor
    func testCanvasVendsDeterministicObjectChildrenWithMeaningfulState() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let olderStrokeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newerStrokeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let backImageID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let frontImageID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let baseDate = Date(timeIntervalSince1970: 100)
        let strokes = [
            CanvasStroke(
                id: newerStrokeID,
                color: .blue,
                width: 4,
                points: [CanvasPoint(x: 20, y: 30), CanvasPoint(x: 40, y: 50)],
                createdAt: baseDate.addingTimeInterval(1)
            ),
            CanvasStroke(
                id: olderStrokeID,
                color: .ink,
                width: 3,
                points: [CanvasPoint(x: -20, y: -10), CanvasPoint(x: 0, y: 10)],
                createdAt: baseDate
            )
        ]
        let images = [
            makeAccessibilityImage(
                id: frontImageID,
                center: CanvasPoint(x: 80, y: 70),
                width: 100,
                height: 50,
                zIndex: 9,
                createdAt: baseDate
            ),
            makeAccessibilityImage(
                id: backImageID,
                center: CanvasPoint(x: 0, y: 0),
                width: 60,
                height: 90,
                zIndex: 2,
                createdAt: baseDate
            )
        ]

        view.configure(
            canvasID: CanvasBoardItem.logicalBoardID,
            strokes: strokes,
            images: images,
            selectedImageID: frontImageID,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )

        let children = try XCTUnwrap(
            view.accessibilityChildren() as? [CanvasAccessibilityObjectElement]
        )
        XCTAssertEqual(
            children.map(\.objectID),
            [olderStrokeID, newerStrokeID, backImageID, frontImageID]
        )
        XCTAssertEqual(children.map(\.objectKind), [.stroke, .stroke, .image, .image])
        XCTAssertEqual(children[0].accessibilityLabel(), "Ink stroke 1 of 2")
        XCTAssertTrue(children[0].accessibilityValueDescription()?.contains("center") == true)
        XCTAssertEqual(children[2].accessibilityLabel(), "Image 1 of 2")
        XCTAssertFalse(children[2].isAccessibilitySelected())
        XCTAssertTrue(children[3].isAccessibilitySelected())
        XCTAssertTrue(children[3].accessibilityValueDescription()?.contains("100 by 50") == true)
        XCTAssertEqual(
            children[3].availableActionNames,
            [
                "Select", "Move left", "Move right", "Move up", "Move down",
                "Make smaller", "Make larger", "Send backward", "Delete"
            ]
        )
        XCTAssertTrue(children.allSatisfy {
            !$0.accessibilityFrameInParentSpace().isNull
        })
        // The off-center object is drawn below the view center. AX parent
        // coordinates must invert Y, or its screen frame points above it.
        XCTAssertEqual(
            children[3].accessibilityFrameInParentSpace(),
            CGRect(x: 190, y: 25, width: 100, height: 50)
        )
    }

    @MainActor
    func testAccessibilityTraversalAndActionsOperateOnTheOwnedObject() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let strokeID = UUID()
        let imageID = UUID()
        let frontImageID = UUID()
        let image = makeAccessibilityImage(
            id: imageID,
            center: CanvasPoint(x: 20, y: 30),
            width: 80,
            height: 60,
            zIndex: 3,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let frontImage = makeAccessibilityImage(
            id: frontImageID,
            center: CanvasPoint(x: 80, y: 80),
            width: 50,
            height: 50,
            zIndex: 4,
            createdAt: Date(timeIntervalSince1970: 201)
        )
        var selectedIDs: [UUID?] = []
        var erasedIDs: [Set<UUID>] = []
        var nudgeDeltas: [CGSize] = []
        var resizeFactors: [Double] = []
        var forwardCount = 0
        var deleteCount = 0
        view.onSelectImage = { selectedIDs.append($0) }
        view.onErase = { erasedIDs.append($0); return true }
        view.onNudgeSelectedImage = { nudgeDeltas.append($0); return true }
        view.onResizeSelectedImage = { resizeFactors.append($0); return true }
        view.onBringSelectedImageForward = { forwardCount += 1; return true }
        view.onDeleteSelectedImage = { deleteCount += 1; return true }
        view.configure(
            canvasID: CanvasBoardItem.logicalBoardID,
            strokes: [CanvasStroke(
                id: strokeID,
                color: .red,
                width: 5,
                points: [CanvasPoint(x: -10, y: -10), CanvasPoint(x: 10, y: 10)]
            )],
            images: [frontImage, image],
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )

        XCTAssertEqual(view.focusNextCanvasObject(backward: false), strokeID)
        XCTAssertEqual(view.focusNextCanvasObject(backward: false), imageID)
        XCTAssertEqual(selectedIDs.last!, imageID)
        XCTAssertEqual(view.focusNextCanvasObject(backward: false), frontImageID)
        XCTAssertNil(view.focusNextCanvasObject(backward: false))
        XCTAssertEqual(view.focusNextCanvasObject(backward: true), imageID)

        let children = try XCTUnwrap(
            view.accessibilityChildren() as? [CanvasAccessibilityObjectElement]
        )
        let stroke = try XCTUnwrap(children.first { $0.objectID == strokeID })
        let imageElement = try XCTUnwrap(children.first { $0.objectID == imageID })
        XCTAssertTrue(stroke.perform(.delete))
        XCTAssertEqual(erasedIDs, [[strokeID]])

        XCTAssertTrue(imageElement.perform(.moveRight))
        XCTAssertEqual(nudgeDeltas.last, CGSize(width: 1, height: 0))
        XCTAssertTrue(imageElement.perform(.makeLarger))
        XCTAssertEqual(try XCTUnwrap(resizeFactors.last), 1.1, accuracy: 0.001)
        XCTAssertTrue(imageElement.perform(.bringForward))
        XCTAssertEqual(forwardCount, 1)
        XCTAssertTrue(imageElement.accessibilityPerformDelete())
        XCTAssertEqual(selectedIDs.last!, imageID)
        XCTAssertEqual(deleteCount, 1)

        view.onNudgeSelectedImage = { _ in false }
        XCTAssertFalse(imageElement.perform(.moveRight))
        view.onDeleteSelectedImage = { false }
        XCTAssertFalse(imageElement.perform(.delete))
    }

    @MainActor
    func testCanvasKeyboardTraversalMovesResizesAndDeletesSelectedImage() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240)
        )
        let imageID = UUID()
        var selectedIDs: [UUID?] = []
        var nudgeDeltas: [CGSize] = []
        var resizeFactors: [Double] = []
        var deleteCount = 0
        view.onSelectImage = { selectedIDs.append($0) }
        view.onNudgeSelectedImage = { nudgeDeltas.append($0); return true }
        view.onResizeSelectedImage = { resizeFactors.append($0); return true }
        view.onDeleteSelectedImage = { deleteCount += 1; return true }
        view.configure(
            canvasID: CanvasBoardItem.logicalBoardID,
            strokes: [],
            images: [makeAccessibilityImage(
                id: imageID,
                center: .zero,
                width: 80,
                height: 60,
                zIndex: 0,
                createdAt: Date(timeIntervalSince1970: 300)
            )],
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )

        view.keyDown(with: try canvasKeyEvent(
            keyCode: 48,
            characters: "\t"
        ))
        XCTAssertEqual(selectedIDs.last!, imageID)

        view.keyDown(with: try canvasKeyEvent(
            keyCode: 124,
            characters: "\u{F703}"
        ))
        XCTAssertEqual(nudgeDeltas.last, CGSize(width: 1, height: 0))

        view.keyDown(with: try canvasKeyEvent(
            keyCode: 124,
            characters: "\u{F703}",
            modifiers: .option
        ))
        XCTAssertEqual(try XCTUnwrap(resizeFactors.last), 1.1, accuracy: 0.001)

        view.keyDown(with: try canvasKeyEvent(
            keyCode: 51,
            characters: "\u{8}"
        ))
        XCTAssertEqual(deleteCount, 1)
    }

    @MainActor
    func testHostedCanvasTabTraversalExitsInBothDirections() throws {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        let previous = CanvasFocusProbeView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let canvas = CanvasNSView(frame: CGRect(x: 20, y: 0, width: 320, height: 240))
        let next = CanvasFocusProbeView(frame: CGRect(x: 340, y: 0, width: 20, height: 20))
        container.addSubview(previous)
        container.addSubview(canvas)
        container.addSubview(next)
        panel.contentView = container
        previous.nextKeyView = canvas
        canvas.nextKeyView = next
        next.nextKeyView = previous

        let imageID = UUID()
        canvas.configure(
            canvasID: CanvasBoardItem.logicalBoardID,
            strokes: [],
            images: [makeAccessibilityImage(
                id: imageID,
                center: .zero,
                width: 80,
                height: 60,
                zIndex: 0,
                createdAt: Date(timeIntervalSince1970: 400)
            )],
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )

        XCTAssertTrue(panel.makeFirstResponder(canvas))
        canvas.keyDown(with: try canvasKeyEvent(keyCode: 48, characters: "\t"))
        XCTAssertEqual(canvas.accessibilityFocusedObjectKey?.id, imageID)
        XCTAssertTrue(panel.firstResponder === canvas)

        canvas.keyDown(with: try canvasKeyEvent(keyCode: 48, characters: "\t"))
        XCTAssertNil(canvas.accessibilityFocusedObjectKey)
        XCTAssertTrue(panel.firstResponder === next)

        XCTAssertTrue(panel.makeFirstResponder(canvas))
        canvas.keyDown(with: try canvasKeyEvent(
            keyCode: 48,
            characters: "\t",
            modifiers: .shift
        ))
        XCTAssertEqual(canvas.accessibilityFocusedObjectKey?.id, imageID)
        canvas.keyDown(with: try canvasKeyEvent(
            keyCode: 48,
            characters: "\t",
            modifiers: .shift
        ))
        XCTAssertNil(canvas.accessibilityFocusedObjectKey)
        XCTAssertTrue(panel.firstResponder === previous)
    }

    @MainActor
    private func makeAccessibilityImage(
        id: UUID,
        center: CanvasPoint,
        width: Double,
        height: Double,
        zIndex: Int64,
        createdAt: Date
    ) -> CanvasPlacedImage {
        CanvasPlacedImage(
            id: id,
            encodedData: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!,
            contentType: UTType.png.identifier,
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            transform: CanvasImageTransform(
                center: center,
                width: width,
                height: height,
                zIndex: zIndex
            ),
            createdAt: createdAt
        )
    }

    @MainActor
    func testRetryFailedImageDecodesRequeuesEveryVisibleFailure() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.importPreparedImage(corruptCanvasImage(1), at: CanvasPoint(x: -60, y: 0)))
        XCTAssertTrue(session.importPreparedImage(corruptCanvasImage(2), at: CanvasPoint(x: 60, y: 0)))
        let images = session.images
        let ids = Set(images.map(\.id))
        XCTAssertEqual(ids.count, 2)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        XCTAssertEqual(CanvasImageDecodeCandidatePolicy.candidates(
            in: view.images, viewport: session.viewport, viewportSize: view.bounds.size
        ).count, 2)
        let bothFailed = await waitForCanvasCondition { session.failedImageIDs == ids }
        XCTAssertTrue(bothFailed)

        XCTAssertTrue(session.retryFailedImageDecodes())
        bridge.configure(view)
        for image in images {
            XCTAssertNotEqual(view.imageCache.state(for: image), .failed)
        }
        bridge.configure(view)
        let bothRetriedAndFailedAgain = await waitForCanvasCondition {
            images.allSatisfy { view.imageCache.state(for: $0) == .failed } && session.failedImageIDs == ids
        }
        XCTAssertTrue(bothRetriedAndFailedAgain)

        // Negative control: no remembered failure means no retry request.
        let quiet = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertFalse(quiet.retryFailedImageDecodes())
        XCTAssertNil(quiet.imageDecodeRetryRequest)
    }

    @MainActor
    func testRetryFailedImageDecodesRequeuesOffScreenFailure() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.importPreparedImage(corruptCanvasImage(3), at: CanvasPoint(x: 0, y: 0)))
        XCTAssertTrue(session.importPreparedImage(corruptCanvasImage(4), at: CanvasPoint(x: 3_000, y: 0)))
        let onScreen = try XCTUnwrap(session.images.first { $0.transform.center.x == 0 })
        let offScreen = try XCTUnwrap(session.images.first { $0.transform.center.x == 3_000 })
        let ids: Set<UUID> = [onScreen.id, offScreen.id]
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)

        session.setViewport(CanvasViewport(center: CanvasPoint(x: 3_000, y: 0)))
        bridge.configure(view)
        let farFailed = await waitForCanvasCondition { view.imageCache.state(for: offScreen) == .failed }
        XCTAssertTrue(farFailed)
        session.setViewport(CanvasViewport(center: .zero))
        bridge.configure(view)
        let bothFailed = await waitForCanvasCondition { session.failedImageIDs == ids }
        XCTAssertTrue(bothFailed)
        XCTAssertEqual(CanvasImageDecodeCandidatePolicy.candidates(
            in: view.images, viewport: session.viewport, viewportSize: view.bounds.size
        ).map(\.id), [onScreen.id])

        XCTAssertTrue(session.retryFailedImageDecodes())
        bridge.configure(view)
        XCTAssertNotEqual(view.imageCache.state(for: onScreen), .failed)
        XCTAssertNotEqual(view.imageCache.state(for: offScreen), .failed)
        // A later draw/configure pass re-prepares the unchanged viewport.
        bridge.configure(view)
        XCTAssertNotEqual(view.imageCache.state(for: offScreen), .failed)
        let retriedOffScreen = await waitForCanvasCondition {
            view.imageCache.state(for: offScreen) == .failed
                && view.imageCache.state(for: onScreen) == .failed
                && session.failedImageIDs == ids
        }
        XCTAssertTrue(retriedOffScreen)
    }

    @MainActor
    func testToolbarUndoRedoFollowFocusedTextEditor() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        session.selectSemanticObject(nil)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 480, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: CanvasPanelContent(
            session: session, horizontalInset: 10, isClearConfirmationPresented: .constant(false)
        ))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 640)
        window.contentView = host
        // SwiftUI dispatches button events only for an ordered window; keep it
        // far outside every display and never make it key.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func settleLayout() {
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                // Availability now changes while editing, and the hosting view
                // only picks up a publish when the transaction is committed.
                CATransaction.flush()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        settleLayout()
        // The unit-test host cannot own a key window, so resolve focus in the
        // hosting window exactly as AppKit would in the key panel.
        let previousFocusedResponder = CanvasEditCommandRoute.focusedResponder
        CanvasEditCommandRoute.focusedResponder = { [weak window] in window?.firstResponder }
        defer { CanvasEditCommandRoute.focusedResponder = previousFocusedResponder }

        func click(_ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ) else { continue }
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        // Locate the rendered toolbar buttons by their effect with no editor
        // focused, where both the old and routed paths use canvas history.
        func locate(from start: CGPoint?, where effect: () -> Bool) -> CGPoint? {
            for y in stride(from: start?.y ?? 0, through: 72, by: 4) {
                for x in stride(from: start.map { $0.x + 4 } ?? 0, through: 480, by: 4) {
                    let point = CGPoint(x: x, y: y)
                    guard let hit = host.hitTest(point), !(hit is CanvasNSView) else { continue }
                    click(point)
                    if effect() { return point }
                }
                if start != nil { return nil }
            }
            return nil
        }
        let toolbarUndo = try XCTUnwrap(locate(from: nil) { session.strokes.isEmpty })
        let toolbarRedo = try XCTUnwrap(locate(from: toolbarUndo) { session.strokes.count == 1 })
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
        XCTAssertFalse(session.canRedo)
        // Give canvas history both an undo (the text insertion) and a redo (the
        // stroke) so either misrouted command is observable.
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)

        let canvas = try XCTUnwrap(firstCanvasView(in: host))
        canvas.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.string, "Keep draft")

        // Undo/Redo availability now follows the focused editor, so each command
        // needs the panel to re-render before the next one is issued, and no
        // point is clicked twice in a row. The Add ▸ Edit halves of this test
        // moved to testAddMenuUndoRoutesToFocusedTextEditor and
        // testAddMenuRedoRoutesToFocusedTextEditor: opening that popup in this
        // offline host freezes the rendered enabled states, so each menu command
        // needs its own panel and a single menu open.
        click(toolbarUndo)
        settleLayout()
        XCTAssertEqual(editor.string, "Keep", "toolbar Undo must undo typing in the focused editor")
        XCTAssertEqual(session.semanticObjects.count, 1, "toolbar Undo must not pop canvas history while editing")
        XCTAssertTrue(session.strokes.isEmpty)

        click(toolbarRedo)
        settleLayout()
        XCTAssertEqual(editor.string, "Keep draft", "toolbar Redo must redo typing in the focused editor")
        XCTAssertTrue(session.strokes.isEmpty, "toolbar Redo must not replay canvas history while editing")

        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")
    }

    /// Add ▸ Edit ▸ Undo must reach the focused editor's undo manager, not
    /// canvas history. It needs its own hosted panel because opening the popup
    /// freezes the rendered enabled states, so only the command that is live at
    /// the first open can be performed in one test.
    @MainActor
    func testAddMenuUndoRoutesToFocusedTextEditor() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        XCTAssertTrue(session.undo())
        // Canvas history holds an undo and a redo, so a misrouted command shows.
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(session.strokes.isEmpty)

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let object = try XCTUnwrap(session.semanticObjects.first)
        session.selectSemanticObject(object.id)
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.string, "Keep draft")
        chrome.settle()

        XCTAssertEqual(chrome.performEditMenuItem("Undo"), true,
                       "Undo must render enabled once the focused editor can undo")
        XCTAssertEqual(editor.string, "Keep", "menu Undo must undo typing in the focused editor")
        XCTAssertEqual(session.semanticObjects.count, 1, "menu Undo must not pop canvas history while editing")
        XCTAssertTrue(session.strokes.isEmpty, "menu Undo must not replay canvas history while editing")
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")
    }

    /// Add ▸ Edit ▸ Redo must reach the focused editor's undo manager, not
    /// canvas history. It needs its own hosted panel because opening the popup
    /// freezes the rendered enabled states, so only the command that is live at
    /// the first open can be performed in one test.
    @MainActor
    func testAddMenuRedoRoutesToFocusedTextEditor() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        XCTAssertTrue(session.undo())
        // Canvas history holds an undo and a redo, so a misrouted command shows.
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(session.strokes.isEmpty)

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let object = try XCTUnwrap(session.semanticObjects.first)
        session.selectSemanticObject(object.id)
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(editor.string, "Keep draft")
        // Undo the typing directly so the editor, and only the editor, has a
        // redo when the menu opens for the first and only time.
        editor.undoManager?.undo()
        chrome.settle()
        XCTAssertEqual(editor.string, "Keep")
        XCTAssertEqual(editor.undoManager?.canRedo, true)

        XCTAssertEqual(chrome.performEditMenuItem("Redo"), true,
                       "Redo must render enabled once the focused editor can redo")
        XCTAssertEqual(editor.string, "Keep draft", "menu Redo must redo typing in the focused editor")
        XCTAssertTrue(session.strokes.isEmpty, "menu Redo must not replay canvas history while editing")
        XCTAssertEqual(session.semanticObjects.count, 1, "menu Redo must not pop canvas history while editing")
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")
    }

    /// Focusing a text editor whose own undo manager is empty must disable
    /// Undo/Redo in the toolbar and the Add ▸ Edit menu even when canvas
    /// history is non-empty, so the panel agrees with the route-only app Edit
    /// menu. The composite `session.canX || route.canX` predicate rendered them
    /// enabled while the route refused to act on them.
    @MainActor
    func testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        session.selectSemanticObject(nil)

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        // Locate the rendered toolbar buttons by their effect with no editor
        // focused, where availability comes from canvas history either way.
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        let toolbarRedo = try XCTUnwrap(chrome.locateToolbarButton(from: toolbarUndo) { session.strokes.count == 1 })
        // Leave canvas history with both an undo (the text insertion) and a
        // redo (the stroke), so a session-sourced predicate reads enabled.
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)

        let object = try XCTUnwrap(session.semanticObjects.first)
        // Mirror a double-click: selection publishes, then the editor takes focus.
        session.selectSemanticObject(object.id)
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertEqual(editor.undoManager?.canUndo, false)
        XCTAssertEqual(editor.undoManager?.canRedo, false)
        chrome.settle()

        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas),
                       "the route must report the focused editor's empty undo manager")
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas),
                       "the route must report the focused editor's empty redo stack")
        // The toolbar and the Add ▸ Edit menu share `canUndoCanvasEdit`, so the
        // rendered menu item is the observable enabled state for both. The popup
        // freezes its items at the first open, and nothing below changes state
        // between these two reads, so both describe this instant.
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must not render enabled while the focused editor has nothing to undo")
        XCTAssertEqual(chrome.performEditMenuItem("Redo", perform: false), false,
                       "Redo must not render enabled while the focused editor has nothing to redo")

        // Whatever the chrome renders, neither click may reach canvas history.
        chrome.click(toolbarUndo)
        chrome.settle()
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertEqual(editor.string, "Keep")
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertTrue(session.canUndo, "canvas history must survive Undo clicks made while editing")
        XCTAssertTrue(session.canRedo, "canvas history must survive Redo clicks made while editing")
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
    }

    /// With empty canvas history, typing in a focused editor must make the
    /// rendered toolbar Undo live. The draft save path never republished the
    /// session, so `.disabled(!canUndoCanvasEdit)` was never re-evaluated and
    /// the click did nothing while Cmd-Z worked.
    @MainActor
    func testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        // A fresh board clears the history, leaving the focused editor as the
        // only possible undo target.
        XCTAssertNotNil(session.createCanvas(name: "Fresh"))
        chrome.settle()
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.semanticObjects.isEmpty)

        func textPlacementPending() -> Bool {
            if case .text? = session.pendingPlacement { return true }
            return false
        }
        // The locate sweep clicks the tool dock, so only arm the text tool when
        // it is not already armed.
        if !textPlacementPending() { session.selectTextTool() }
        XCTAssertTrue(textPlacementPending())
        let draft = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 200))
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(draft.baseline, insertion: draft)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        chrome.settle()
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas),
                       "nothing is undoable before the first keystroke")

        editor.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "abc")
        XCTAssertEqual(session.semanticTextDraft(draft.baseline.id), "abc",
                       "typing must reach the draft save path")
        XCTAssertEqual(editor.undoManager?.canUndo, true)
        chrome.settle()

        XCTAssertTrue(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        // The rendered toolbar button must be live: the stale disabled state
        // swallowed this click while Cmd-Z kept working.
        chrome.click(toolbarUndo)
        XCTAssertEqual(editor.string, "", "toolbar Undo must undo the typing through the focused editor")
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertFalse(session.canUndo, "an editor undo must not create canvas history")
        XCTAssertFalse(session.canRedo)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.semanticObjects.isEmpty)

        // The keyboard path still reaches the same editor undo manager.
        editor.insertText("xy", replacementRange: NSRange(location: 0, length: 0))
        chrome.settle()
        XCTAssertEqual(editor.string, "xy")
        XCTAssertTrue(editor.performKeyEquivalent(
            with: try canvasKeyEvent(keyCode: 6, characters: "z", modifiers: .command)
        ))
        XCTAssertEqual(editor.string, "")
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.semanticObjects.isEmpty)
    }

    /// Reopening committed text from the keyboard over non-empty canvas history
    /// must render Undo/Redo for the fresh editor: disabled until it has typing.
    /// Live, the toolbar and both Edit menus showed Undo enabled and the click
    /// changed nothing. Every editor borrowed the window's undo manager, so the
    /// committed editor's typing was still undoable from the new one, and Return
    /// focuses the editor without any publish, so chrome kept history's state.
    @MainActor
    func testKeyboardEditEntryAfterCommittedTypingRendersFreshEditorUndoRedo() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        let toolbarRedo = try XCTUnwrap(chrome.locateToolbarButton(from: toolbarUndo) { session.strokes.count == 1 })

        // Type and commit new text through a real insertion editor.
        func textPlacementPending() -> Bool {
            if case .text? = session.pendingPlacement { return true }
            return false
        }
        if !textPlacementPending() { session.selectTextTool() }
        let insertion = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 200))
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(insertion.baseline, insertion: insertion)
        let first = try XCTUnwrap(canvas.semanticTextEditor)
        first.insertText("gamma", replacementRange: NSRange(location: 0, length: 0))
        chrome.settle()
        XCTAssertEqual(first.undoManager?.canUndo, true)
        first.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(canvas.semanticTextEditor)
        let gamma = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["gamma"])
        // Give canvas history an undo and a redo, so stale chrome reads enabled.
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 150, y: 100), CanvasPoint(x: 160, y: 110)]))
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        // Select the text the way Tab or a click does, and let chrome render.
        session.selectSemanticObject(gamma.id)
        chrome.settle()

        // Return opens a fresh editor; nothing else publishes once it has focus.
        canvas.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r"))
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertFalse(editor === first)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "gamma")
        chrome.settle()

        XCTAssertEqual(editor.undoManager?.canUndo, false, "a fresh editor must not inherit a closed editor's typing")
        XCTAssertEqual(editor.undoManager?.canRedo, false)
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo), "the app's plain Undo must agree")
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainRedo), "the app's plain Redo must agree")
        // The toolbar and Add ▸ Edit share one predicate; this first menu open
        // shows what the panel rendered after focus moved.
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must not stay enabled from canvas history once the fresh editor has focus")
        XCTAssertEqual(chrome.performEditMenuItem("Redo", perform: false), false,
                       "Redo must not stay enabled from canvas history once the fresh editor has focus")

        // No click may reach the closed editor, the fresh one, or canvas history.
        chrome.click(toolbarUndo)
        chrome.settle()
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertEqual(editor.string, "gamma")
        XCTAssertEqual(first.string, "gamma", "Undo must not change the closed editor's text")
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["gamma"])

        // Typing makes Undo live for this editor, and only this editor.
        editor.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        chrome.settle()
        XCTAssertTrue(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertTrue(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo),
                      "the app's plain Undo must reach the focused editor")
        chrome.click(toolbarUndo)
        chrome.settle()
        XCTAssertEqual(editor.string, "gamma")
        XCTAssertEqual(editor.undoManager?.canUndo, false)
        XCTAssertEqual(first.string, "gamma")
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["gamma"])
    }

    /// A text-tool click on empty canvas opens an insertion editor without any
    /// publish. Chrome must still re-read Undo/Redo once that editor has focus,
    /// and the insertion draft must keep working.
    @MainActor
    func testTextToolInsertionSpawnRendersEditorUndoRedoOverCanvasHistory() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: 100), CanvasPoint(x: -140, y: 110)]))

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.count == 1 })
        let toolbarRedo = try XCTUnwrap(chrome.locateToolbarButton(from: toolbarUndo) { session.strokes.count == 2 })
        // Canvas history holds an undo and a redo, so stale chrome reads enabled.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        func textPlacementPending() -> Bool {
            if case .text? = session.pendingPlacement { return true }
            return false
        }
        if !textPlacementPending() { session.selectTextTool() }
        XCTAssertTrue(textPlacementPending())
        chrome.settle()

        let spawnPoint = CGPoint(x: 300, y: 420)
        XCTAssertTrue(chrome.host.hitTest(spawnPoint) is CanvasNSView)
        chrome.click(spawnPoint)
        let canvas = try XCTUnwrap(chrome.canvas)
        let editor = try XCTUnwrap(canvas.semanticTextEditor, "a text-tool click on empty canvas opens an insertion editor")
        XCTAssertTrue(canvas.editingSemanticIsInsertion)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        chrome.settle()

        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must not stay enabled from canvas history once the insertion editor has focus")
        XCTAssertEqual(chrome.performEditMenuItem("Redo", perform: false), false,
                       "Redo must not stay enabled from canvas history once the insertion editor has focus")
        chrome.click(toolbarUndo)
        chrome.settle()
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        XCTAssertTrue(session.semanticObjects.isEmpty)

        // The insertion draft is unchanged: typing is saved, undone and redone
        // in the editor, and one commit adds exactly one object.
        let baselineID = try XCTUnwrap(canvas.editingSemanticBaseline?.id)
        editor.insertText("new", replacementRange: NSRange(location: 0, length: 0))
        chrome.settle()
        XCTAssertEqual(session.semanticTextDraft(baselineID), "new")
        chrome.click(toolbarUndo)
        chrome.settle()
        XCTAssertEqual(editor.string, "")
        XCTAssertNil(session.semanticTextDraft(baselineID))
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertEqual(editor.string, "new")
        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertTrue(session.canRedo, "editor undo and redo must not touch canvas history")
        editor.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(canvas.semanticTextEditor)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["new"])
        XCTAssertNil(session.semanticTextDraft(baselineID))
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    /// Restyling the object being edited refreshes the untouched editor and
    /// empties its undo history. Neither step reports a text change, and the
    /// panel read the old history earlier in that update, so Undo stayed
    /// rendered enabled with nothing left to undo. (An external store change
    /// instead rebuilds the surface, closing the editor, and clears history.)
    @MainActor
    func testRestyleThatClearsEditorHistoryRerendersUndoRedo() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let placed = await session.insertText("Original", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        session.selectSemanticObject(nil)

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        XCTAssertTrue(session.canUndo)
        let object = try XCTUnwrap(session.semanticObjects.first)
        session.selectSemanticObject(object.id)
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        // Type and delete it again: the text matches the saved object, so a
        // content change may replace it, yet the editor can undo.
        editor.insertText(" x", replacementRange: NSRange(location: 8, length: 0))
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "Original")
        XCTAssertEqual(editor.undoManager?.canUndo, true)
        chrome.settle()
        XCTAssertTrue(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))

        // The selection dock's style menu saves this while the editor stays open.
        var restyled = try XCTUnwrap(object.content)
        restyled.color = try XCTUnwrap(CanvasInkColor.allCases.first { $0 != restyled.color })
        XCTAssertTrue(session.editSemanticObject(object.id, content: restyled))
        chrome.settle()
        XCTAssertTrue(canvas.semanticTextEditor === editor, "a local restyle keeps the editor open")
        XCTAssertEqual(editor.string, "Original")
        XCTAssertEqual(editor.undoManager?.canUndo, false)
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must re-render disabled once the restyle emptied the editor's history")
        XCTAssertEqual(chrome.performEditMenuItem("Redo", perform: false), false)
        chrome.click(toolbarUndo)
        chrome.settle()
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(editor.string, "Original")
        XCTAssertEqual(session.semanticObjects.first?.content?.color, restyled.color,
                       "canvas history must survive Undo clicks made while editing")
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(canvas.finishSemanticTextEditing(commit: true))
        XCTAssertEqual(CanvasStore(container: store.container).semanticObjects.first?.content?.color, restyled.color)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.semanticObjects.first?.content?.color, object.content?.color)
    }

    /// A text editor's typing history ends with the editor. In the window's
    /// undo manager it outlived commit, cancel and suspension, so the app's
    /// plain Edit ▸ Redo stayed enabled for a closed editor while canvas Redo
    /// was disabled, and a reopened draft claimed history it could not undo.
    @MainActor
    func testClosedTextEditorLeavesNoTypingHistoryForPlainEditMenu() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertFalse(session.canRedo)

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let canvas = try XCTUnwrap(chrome.canvas)
        let object = try XCTUnwrap(session.semanticObjects.first)
        session.selectSemanticObject(object.id)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        chrome.settle()

        // While editing, the app's plain Undo/Redo act on this editor only.
        XCTAssertTrue(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo))
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainRedo))
        XCTAssertTrue(chrome.performPlainEditItem(HostedCanvasChrome.plainUndo))
        XCTAssertEqual(editor.string, "Keep", "plain Undo must undo typing in the focused editor")
        XCTAssertEqual(session.semanticObjects.count, 1, "plain Undo must not pop canvas history")
        XCTAssertTrue(chrome.plainEditItemEnabled(HostedCanvasChrome.plainRedo))
        XCTAssertTrue(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))

        // Cancel: the editor's redo must not survive in the app menu.
        editor.keyDown(with: try canvasKeyEvent(keyCode: 53, characters: "\u{1B}"))
        XCTAssertNil(canvas.semanticTextEditor)
        chrome.settle()
        XCTAssertFalse(session.canRedo)
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainRedo),
                       "plain Redo must not stay enabled for a closed editor while canvas Redo is disabled")
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo))
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])

        // Commit: the saved edit belongs to canvas history, not the app's plain Undo.
        canvas.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        let committing = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertEqual(committing.undoManager?.canUndo, false)
        committing.insertText("!", replacementRange: NSRange(location: 4, length: 0))
        committing.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(canvas.semanticTextEditor)
        chrome.settle()
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep!"])
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo),
                       "plain Undo must not offer typing from a committed editor")
        XCTAssertTrue(CanvasEditCommandRoute.undo(session: session, section: .canvas))
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
        XCTAssertTrue(CanvasEditCommandRoute.redo(session: session, section: .canvas))
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep!"])

        // Suspension keeps the draft, but a reopened editor starts a new history.
        canvas.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        let suspended = try XCTUnwrap(canvas.semanticTextEditor)
        suspended.insertText(" kept", replacementRange: NSRange(location: 5, length: 0))
        canvas.suspendSemanticTextEditing()
        XCTAssertNil(canvas.semanticTextEditor)
        chrome.settle()
        XCTAssertEqual(session.semanticTextDraft(object.id), "Keep! kept")
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo))
        canvas.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        let reopened = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertEqual(reopened.string, "Keep! kept")
        chrome.settle()
        XCTAssertEqual(reopened.undoManager?.canUndo, false)
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertFalse(chrome.plainEditItemEnabled(HostedCanvasChrome.plainUndo))
        XCTAssertEqual(suspended.string, "Keep! kept")
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep!"])
    }

    /// The canvas panel is non-activating: it can stop being key while its text
    /// editor keeps focus, and accessibility presses still reach its toolbar.
    /// That editor must keep owning Undo, Redo and the commit veto. Resolved
    /// through the key window alone they fell through to canvas history, so
    /// toolbar Undo removed the text object being edited (seen live).
    @MainActor
    func testTextEditorInNonKeyPanelKeepsUndoRedoAndCommitVeto() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))
        session.selectSemanticObject(nil)

        // This host never has a key window, like a panel that stopped being key.
        let chrome = HostedCanvasChrome(session: session, resolvesFocusInHostWindow: false)
        defer { chrome.tearDown() }
        XCTAssertNil(NSApp.keyWindow)
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        let toolbarRedo = try XCTUnwrap(chrome.locateToolbarButton(from: toolbarUndo) { session.strokes.count == 1 })
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)
        let object = try XCTUnwrap(session.semanticObjects.first)
        session.selectSemanticObject(object.id)
        chrome.settle()

        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r"))
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === editor)
        XCTAssertFalse(chrome.window.isKeyWindow)
        chrome.settle()
        XCTAssertTrue(CanvasEditCommandRoute.focusedResponder() === editor)
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertFalse(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must follow the open editor, not canvas history")
        XCTAssertEqual(chrome.performEditMenuItem("Redo", perform: false), false,
                       "Redo must follow the open editor, not canvas history")
        chrome.click(toolbarUndo)
        chrome.settle()
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertTrue(canvas.semanticTextEditor === editor, "toolbar Undo must not remove the text being edited")
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.canRedo)

        // Typing is what toolbar Undo reverts.
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        chrome.settle()
        XCTAssertTrue(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        chrome.click(toolbarUndo)
        chrome.settle()
        XCTAssertEqual(editor.string, "Keep")
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
        XCTAssertTrue(session.strokes.isEmpty)

        // A tool change from the panel still saves the editor first.
        editor.insertText(" saved", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertTrue(CanvasEditCommandRoute.finishTextEditing())
        XCTAssertNil(canvas.semanticTextEditor)
        XCTAssertTrue(chrome.window.firstResponder === canvas)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep saved"])
        XCTAssertNil(CanvasEditCommandRoute.focusedResponder() as? NSTextView)
        XCTAssertTrue(CanvasEditCommandRoute.undo(session: session, section: .canvas))
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
    }

    /// An editor opened on existing text uses TextKit 2, which reports no text
    /// change for its own undo or redo, so nothing republished after Cmd-Z:
    /// Undo stayed enabled with nothing left to undo, Redo stayed disabled,
    /// and the saved draft kept the undone text.
    @MainActor
    func testKeyboardUndoInReopenedTextEditorRerendersUndoRedoAndDraft() throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: -150, y: -100), CanvasPoint(x: -140, y: -90)]))

        let chrome = HostedCanvasChrome(session: session)
        defer { chrome.tearDown() }
        let toolbarUndo = try XCTUnwrap(chrome.locateToolbarButton(from: nil) { session.strokes.isEmpty })
        let toolbarRedo = try XCTUnwrap(chrome.locateToolbarButton(from: toolbarUndo) { session.strokes.count == 1 })

        // Commit text through an insertion editor, then reopen it.
        func textPlacementPending() -> Bool {
            if case .text? = session.pendingPlacement { return true }
            return false
        }
        if !textPlacementPending() { session.selectTextTool() }
        let insertion = try XCTUnwrap(session.makeTextInsertion(at: .zero, width: 200))
        let canvas = try XCTUnwrap(chrome.canvas)
        canvas.beginSemanticTextEditing(insertion.baseline, insertion: insertion)
        let first = try XCTUnwrap(canvas.semanticTextEditor)
        first.insertText("Keep", replacementRange: NSRange(location: 0, length: 0))
        first.keyDown(with: try canvasKeyEvent(keyCode: 36, characters: "\r", modifiers: .command))
        XCTAssertNil(canvas.semanticTextEditor)
        let object = try XCTUnwrap(session.semanticObjects.first)
        canvas.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(canvas.semanticTextEditor)
        XCTAssertNotNil(editor.textLayoutManager, "an editor on existing text uses TextKit 2")
        editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
        chrome.settle()
        XCTAssertEqual(session.semanticTextDraft(object.id), "Keep draft")

        XCTAssertTrue(editor.performKeyEquivalent(
            with: try canvasKeyEvent(keyCode: 6, characters: "z", modifiers: .command)
        ))
        XCTAssertEqual(editor.string, "Keep")
        XCTAssertEqual(first.string, "Keep", "Cmd-Z must not change a closed editor's text")
        XCTAssertNil(session.semanticTextDraft(object.id), "the saved draft must follow the undo")
        chrome.settle()
        XCTAssertFalse(CanvasEditCommandRoute.canUndo(session: session, section: .canvas))
        XCTAssertTrue(CanvasEditCommandRoute.canRedo(session: session, section: .canvas))
        XCTAssertEqual(chrome.performEditMenuItem("Undo", perform: false), false,
                       "Undo must not stay enabled once the editor has nothing left to undo")
        chrome.click(toolbarRedo)
        chrome.settle()
        XCTAssertEqual(editor.string, "Keep draft", "toolbar Redo must be live after the keyboard undo")
        XCTAssertEqual(session.semanticTextDraft(object.id), "Keep draft")
        XCTAssertTrue(canvas.semanticTextEditor === editor)
        XCTAssertEqual(session.semanticObjects.map { $0.content?.text }, ["Keep"])
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testPointerNarrowingTextResizeGrowsHeightToFitCommittedText() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let placed = await session.insertText(
            "Dragging a handle inward must keep every wrapped word of this note visible",
            at: CanvasPoint(x: 0, y: -40),
            prefersDarkSurface: false
        )
        XCTAssertTrue(placed)
        session.selectTool(.select)
        let original = try XCTUnwrap(session.selectedSemanticObject)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        panel.contentView = view
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue, clearReadabilityEnabled: false)
        bridge.configure(view)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0.5
            ))
        }
        let rect = original.worldRect
        let handle = session.viewport.viewPoint(
            for: CanvasPoint(x: rect.maxX, y: rect.maxY), in: view.bounds.size
        )
        let target = CGPoint(x: handle.x - (rect.width - 96), y: handle.y)
        view.mouseDown(with: try event(.leftMouseDown, at: handle))
        view.mouseDragged(with: try event(.leftMouseDragged, at: target))
        view.mouseUp(with: try event(.leftMouseUp, at: target))

        let resized = try XCTUnwrap(session.semanticObjects.first)
        XCTAssertEqual(resized.transform.width, 96, accuracy: 0.001)
        XCTAssertEqual(resized.worldRect.minX, rect.minX, accuracy: 0.001)
        XCTAssertEqual(resized.worldRect.minY, rect.minY, accuracy: 0.001)
        XCTAssertGreaterThan(resized.transform.height, original.transform.height)
        XCTAssertTrue(canvasSemanticTextIsFullyVisible(resized))
        let persisted = try XCTUnwrap(CanvasStore(container: store.container).semanticObjects.first)
        XCTAssertEqual(persisted.transform, resized.transform)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.semanticObjects.first?.transform, original.transform)
    }

    @MainActor
    private func waitForCanvasCondition(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func corruptCanvasImage(_ seed: UInt8) -> CanvasPreparedImage {
        CanvasPreparedImage(encodedData: Data([seed, 2, 3]), contentType: "public.png", pixelWidth: 40, pixelHeight: 40)
    }

    @MainActor
    private func firstCanvasView(in view: NSView) -> CanvasNSView? {
        if let canvas = view as? CanvasNSView { return canvas }
        for subview in view.subviews {
            if let canvas = firstCanvasView(in: subview) { return canvas }
        }
        return nil
    }

    @MainActor
    private func canvasKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

@MainActor
private final class CanvasFocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Hosts the real `CanvasPanelContent` off-screen and exposes its rendered
/// toolbar and Add ▸ Edit menu, so availability tests observe the chrome a user
/// sees instead of re-deriving the predicate under test. Same harness as
/// `testToolbarAndMenuUndoRedoFollowFocusedTextEditor`.
@MainActor
private final class HostedCanvasChrome {
    let window: NSWindow
    let host: NSHostingView<CanvasPanelContent>
    private let previousFocusedResponder: @MainActor () -> NSResponder?

    /// `resolvesFocusInHostWindow: false` keeps the production responder
    /// lookup, where this never-key window stands in for a panel that is not key.
    init(session: CanvasSession, resolvesFocusInHostWindow: Bool = true) {
        let hostWindow = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 480, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window = hostWindow
        host = NSHostingView(rootView: CanvasPanelContent(
            session: session, horizontalInset: 10, isClearConfirmationPresented: .constant(false)
        ))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 640)
        hostWindow.contentView = host
        // SwiftUI dispatches button events only for an ordered window; keep it
        // far outside every display and never make it key.
        hostWindow.orderFrontRegardless()
        previousFocusedResponder = CanvasEditCommandRoute.focusedResponder
        // The unit-test host cannot own a key window, so resolve focus in the
        // hosting window exactly as AppKit would in the key panel.
        if resolvesFocusInHostWindow {
            CanvasEditCommandRoute.focusedResponder = { [weak hostWindow] in hostWindow?.firstResponder }
        }
        settle()
    }

    func tearDown() {
        CanvasEditCommandRoute.focusedResponder = previousFocusedResponder
        window.orderOut(nil)
    }

    func settle() {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            // The hosting view only picks up a publish once the transaction is
            // committed, which an off-screen host never does on its own.
            CATransaction.flush()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func click(_ point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// Finds a rendered toolbar button by the effect its click produces. The
    /// buttons carry no addressable geometry, so the sweep clicks the bottom
    /// chrome until `effect` observes the command landing.
    func locateToolbarButton(from start: CGPoint?, where effect: () -> Bool) -> CGPoint? {
        for y in stride(from: start?.y ?? 0, through: 72, by: 4) {
            for x in stride(from: start.map { $0.x + 4 } ?? 0, through: 480, by: 4) {
                let point = CGPoint(x: x, y: y)
                guard let hit = host.hitTest(point), !(hit is CanvasNSView) else { continue }
                click(point)
                if effect() { return point }
            }
            if start != nil { return nil }
        }
        return nil
    }

    /// The rendered enabled state of an Add ▸ Edit item, performing it when it
    /// is enabled and `perform` is true.
    func performEditMenuItem(_ title: String, perform: Bool = true) -> Bool? {
        var cells: [NSPopUpButtonCell] = []
        for subview in host.subviews {
            for child in subview.accessibilityChildren() ?? [] {
                if let cell = child as? NSPopUpButtonCell { cells.append(cell) }
            }
        }
        for cell in cells {
            guard let control = cell.controlView else { continue }
            var enabled: Bool?
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let menu = cell.menu else { return }
                    if let edit = menu.items.first(where: { $0.title == "Edit" })?.submenu,
                       let index = edit.items.firstIndex(where: { $0.title == title }) {
                        enabled = edit.items[index].isEnabled
                        if edit.items[index].isEnabled, perform { edit.performActionForItem(at: index) }
                    }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
            cell.performClick(withFrame: control.bounds, in: control)
            for _ in 0..<4 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            if let enabled { return enabled }
        }
        return nil
    }

    /// The app's plain Edit ▸ Undo/Redo items (not the canvas commands) send
    /// these through the key window's responder chain.
    static let plainUndo = NSSelectorFromString("undo:")
    static let plainRedo = NSSelectorFromString("redo:")

    /// Whether the app's plain Edit item for `action` would be enabled for this
    /// window: NSMenu validates the first responder-chain object handling it.
    func plainEditItemEnabled(_ action: Selector) -> Bool {
        guard let target = plainEditTarget(for: action) else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Performs the app's plain Edit item for `action` when it is enabled.
    func performPlainEditItem(_ action: Selector) -> Bool {
        guard plainEditItemEnabled(action), let target = plainEditTarget(for: action) else { return false }
        return target.tryToPerform(action, with: nil)
    }

    private func plainEditTarget(for action: Selector) -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        return responder
    }

    var canvas: CanvasNSView? { Self.firstCanvasView(in: host) }

    private static func firstCanvasView(in view: NSView) -> CanvasNSView? {
        if let canvas = view as? CanvasNSView { return canvas }
        for subview in view.subviews {
            if let canvas = firstCanvasView(in: subview) { return canvas }
        }
        return nil
    }
}

final class CanvasImageDropBatchTests: XCTestCase {
    @MainActor
    func testFileURLDropAdvertisesCopyAndImportsOnlySupportedImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticCanvasDropTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("image.png")
        let textURL = root.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        try Data("not an image".utf8).write(to: textURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textURL as NSURL]))
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertFalse(view.hasSupportedImagePayload(pasteboard))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textURL as NSURL, imageURL as NSURL]))
        XCTAssertTrue(view.hasSupportedImagePayload(pasteboard))
        let target = CanvasImportTarget(canvasID: UUID(), boardGeneration: 7)
        var deliveredBatch: CanvasImageImportBatch?
        view.onCaptureImageImportTarget = { target }
        view.onImportImageBatch = { deliveredBatch = $0 }

        XCTAssertTrue(view.importPasteboard(
            pasteboard,
            at: CGPoint(x: 150, y: 150)
        ))

        let batch = try XCTUnwrap(deliveredBatch)
        XCTAssertEqual(batch.target, target)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(batch.items.first?.source, .file(imageURL))
    }

    @MainActor
    func testPromisedFileTypeIsFilteredBeforeAdvertisingCopy() {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let textDelegate = CanvasTestFilePromiseDelegate(fileName: "notes.txt")
        let textPromise = NSFilePromiseProvider(
            fileType: UTType.plainText.identifier,
            delegate: textDelegate
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textPromise]))
        XCTAssertFalse(view.hasSupportedImagePayload(pasteboard))

        let imageDelegate = CanvasTestFilePromiseDelegate(fileName: "image.png")
        let imagePromise = NSFilePromiseProvider(
            fileType: UTType.png.identifier,
            delegate: imageDelegate
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imagePromise]))
        XCTAssertTrue(view.hasSupportedImagePayload(pasteboard))

        withExtendedLifetime([textDelegate, imageDelegate]) {}
    }

    @MainActor
    func testFilePromiseCoordinatorKeepsSlotOrderAndRejectsLateDelivery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticCanvasPromiseTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = firstRoot.appendingPathComponent("first.png")
        let lateURL = secondRoot.appendingPathComponent("late.png")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: lateURL)
        let target = CanvasImportTarget(canvasID: UUID(), boardGeneration: 4)
        let firstID = UUID()
        let secondID = UUID()
        let coordinator = CanvasFilePromiseBatchCoordinator(
            batchID: UUID(),
            target: target,
            slots: [
                .init(
                    requestID: firstID,
                    receiverIndex: 0,
                    center: .zero,
                    cleanupURL: firstRoot
                ),
                .init(
                    requestID: secondID,
                    receiverIndex: 1,
                    center: CanvasPoint(x: 12, y: 12),
                    cleanupURL: secondRoot
                )
            ]
        )

        XCTAssertEqual(
            coordinator.record(
                receiverIndex: 1,
                source: .deliveryFailure("Provider failed.")
            ),
            .waiting
        )
        let completion = coordinator.record(
            receiverIndex: 0,
            source: .file(firstURL)
        )
        guard case let .ready(batch) = completion else {
            return XCTFail("Expected the completed promise batch")
        }
        XCTAssertEqual(batch.target, target)
        XCTAssertEqual(batch.items.map(\.id), [firstID, secondID])
        XCTAssertEqual(
            batch.items.map(\.source),
            [.file(firstURL), .deliveryFailure("Provider failed.")]
        )
        XCTAssertEqual(
            coordinator.record(receiverIndex: 1, source: .file(lateURL)),
            .late
        )

        CanvasTemporaryImportCleanup.removeLateDelivery(
            at: lateURL,
            from: secondRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    }
}

final class CanvasDomainTests: XCTestCase {
    @MainActor
    func testFocusLossCancellationCannotCancelANewerViewportGesture() async throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        XCTAssertTrue(view.beginViewportGestureSequence(source: .magnification, mode: .zoom))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        // Synchronous ownership release is required before another physical
        // sequence begins; a queued cancellation would discard the new one.
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertTrue(view.beginViewportGestureSequence(source: .scroll, mode: .zoom))
        await Task.yield()
        XCTAssertEqual(view.activeViewportGesture?.source, .scroll)
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: true, phase: 2))
        XCTAssertGreaterThan(view.interaction.viewport.scale, 1)
    }

    @MainActor
    func testNewCommandScrollTakesOwnershipAfterMissingPinchTerminalEvent() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        XCTAssertTrue(view.beginViewportGestureSequence(source: .magnification, mode: .zoom))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: true, phase: 1))
        XCTAssertEqual(view.activeViewportGesture?.source, .scroll)
        XCTAssertGreaterThan(view.interaction.viewport.scale, 1)
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: true, phase: 4))
        XCTAssertNil(view.activeViewportGesture)
        view.deactivateRepresentation()
        let viewport = view.interaction.viewport
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: true))
        XCTAssertEqual(view.interaction.viewport, viewport)
    }

    func testStrokeCodecRoundTripsVersionedPlatformNeutralArchive() throws {
        let points = [
            CanvasPoint(x: -12.5, y: 8.25),
            CanvasPoint(x: 40, y: 64.5)
        ]

        let data = try CanvasStrokeCodec.encode(
            color: .blue,
            width: 3.75,
            points: points
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["version"] as? Int, CanvasStrokeCodec.currentVersion)
        XCTAssertEqual(object["color"] as? String, CanvasInkColor.blue.rawValue)
        XCTAssertEqual(object["width"] as? Double, 3.75)
        let decoded = try CanvasStrokeCodec.decode(
            data,
            expectedVersion: CanvasStrokeCodec.currentVersion
        )
        XCTAssertEqual(decoded.color, .blue)
        XCTAssertEqual(decoded.width, 3.75)
        XCTAssertEqual(decoded.points, points)
    }

    func testStrokeCodecRejectsUnsupportedArchiveVersion() {
        let data = Data(
            #"{"version":99,"color":"ink","width":3,"points":[{"x":0,"y":0}]}"#
                .utf8
        )

        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(data, expectedVersion: CanvasStrokeCodec.currentVersion)
        )
    }

    func testStrokeCodecRejectsEmptyOrInvalidGeometry() {
        let empty = Data(
            #"{"version":1,"color":"ink","width":3,"points":[]}"#.utf8
        )
        let invalidWidth = Data(
            #"{"version":1,"color":"ink","width":0,"points":[{"x":0,"y":0}]}"#
                .utf8
        )

        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(empty, expectedVersion: CanvasStrokeCodec.currentVersion)
        )
        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(
                invalidWidth,
                expectedVersion: CanvasStrokeCodec.currentVersion
            )
        )
    }

    func testCodecRejectsPointCountsAboveTheInteractiveBufferLimit() {
        let points = (0...CanvasInputStateMachine.maximumBufferedPointCount).map {
            CanvasPoint(x: Double($0), y: 0)
        }

        XCTAssertThrowsError(
            try CanvasStrokeCodec.encode(
                color: .ink,
                width: 3,
                points: points
            )
        ) { error in
            XCTAssertEqual(error as? CanvasStrokeCodecError, .tooManyPoints)
        }
    }

    func testViewportWorldViewRoundTripSurvivesResize() {
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 120, y: -40),
            scale: 2.5
        )
        let world = CanvasPoint(x: 152.25, y: 4.5)

        for size in [CGSize(width: 300, height: 380), CGSize(width: 380, height: 700)] {
            let view = viewport.viewPoint(for: world, in: size)
            let roundTrip = viewport.worldPoint(for: view, in: size)
            assertEqual(roundTrip, world)
        }
    }

    func testWorldPointRejectsInvalidViewportGeometry() {
        let viewport = CanvasViewport()

        XCTAssertFalse(viewport.worldPoint(
            for: CGPoint(x: 20, y: 20),
            in: CGSize(width: CGFloat.infinity, height: 100)
        ).isFinite)
        XCTAssertFalse(viewport.worldPoint(
            for: CGPoint(x: CGFloat.nan, y: 20),
            in: CGSize(width: 100, height: 100)
        ).isFinite)
    }

    func testAppendInkRejectsNonFiniteWorldPointWithoutPoisoningStroke() {
        let controller = CanvasInteractionController()

        XCTAssertTrue(controller.beginInk(
            at: CGPoint(x: 20, y: 20),
            in: CGSize(width: 100, height: 100)
        ))
        XCTAssertFalse(controller.appendInk(
            at: CGPoint(x: 25, y: 25),
            in: CGSize(width: CGFloat.infinity, height: 100)
        ))
        XCTAssertEqual(controller.machine.bufferedPointCount, 1)

        guard case let .stroke(points, _, _) = controller.finishInk() else {
            return XCTFail("Expected the valid starting point to remain finishable")
        }
        XCTAssertEqual(points.count, 1)
        XCTAssertTrue(points[0].isFinite)
    }

    func testZoomKeepsAnchorWorldPointStationaryAndClampsScale() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 1
        )
        let size = CGSize(width: 300, height: 380)
        let anchor = CGPoint(x: 62, y: 147)
        let anchoredWorldPoint = viewport.worldPoint(for: anchor, in: size)

        viewport.zoom(by: 3, anchoredAt: anchor, in: size)

        assertEqual(viewport.worldPoint(for: anchor, in: size), anchoredWorldPoint)
        XCTAssertEqual(viewport.scale, 3, accuracy: 0.000_001)

        viewport.zoom(by: 1_000, anchoredAt: anchor, in: size)
        XCTAssertEqual(viewport.scale, CanvasViewport.maximumScale)
        viewport.zoom(by: 0.000_001, anchoredAt: anchor, in: size)
        XCTAssertEqual(viewport.scale, CanvasViewport.minimumScale)
    }

    func testShapeGeometryUsesTheChosenDragInsteadOfViewportCentre() {
        let start = CanvasPoint(x: 70, y: 40)
        let end = CanvasPoint(x: -10, y: 130)

        XCTAssertEqual(
            CanvasShapeKind.rectangle.points(from: start, to: end),
            [
                CanvasPoint(x: -10, y: 40),
                CanvasPoint(x: 70, y: 40),
                CanvasPoint(x: 70, y: 130),
                CanvasPoint(x: -10, y: 130),
                CanvasPoint(x: -10, y: 40)
            ]
        )
        XCTAssertEqual(
            CanvasShapeKind.line.points(from: start, to: end),
            [start, end]
        )
        XCTAssertTrue(CanvasShapeKind.ellipse.points(
            from: start,
            to: end
        ).allSatisfy {
            (-10...70).contains($0.x) && (40...130).contains($0.y)
        })
    }

    func testArrowGeometryPreservesUserChosenDirection() throws {
        let start = CanvasPoint(x: 10, y: 15)
        let end = CanvasPoint(x: -40, y: -25)
        let points = CanvasShapeKind.arrow.points(from: start, to: end)

        XCTAssertEqual(points.first, start)
        XCTAssertEqual(points.dropFirst().first, end)
        XCTAssertEqual(points.count, 5)
        XCTAssertTrue(points.allSatisfy(\.isFinite))
    }

    func testShapeGeometryRejectsClickWithoutDrag() {
        let point = CanvasPoint(x: 4, y: 8)

        for shape in CanvasShapeKind.allCases {
            XCTAssertTrue(shape.points(from: point, to: point).isEmpty)
        }
    }

    @MainActor
    func testCanvasCursorRoleFollowsToolAndPlacementMode() {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))

        _ = view.interaction.configure(
            strokes: [],
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .arrow)

        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .pen)

        _ = view.interaction.configure(
            strokes: [],
            tool: .eraser,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .eraser)

        view.pendingPlacement = .text(CanvasTextPlacement(
            text: "Here",
            prefersDarkSurface: false
        ))
        XCTAssertEqual(view.baseCursorRole, .textPlacement)
        view.pendingPlacement = .shape(.ellipse)
        XCTAssertEqual(view.baseCursorRole, .shapePlacement)
    }

    func testZoomOverflowClampsToMaximumInsteadOfResettingToOne() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 2
        )

        viewport.zoom(
            by: Double.greatestFiniteMagnitude,
            anchoredAt: CGPoint(x: 150, y: 190),
            in: CGSize(width: 300, height: 380)
        )

        XCTAssertEqual(viewport.scale, CanvasViewport.maximumScale)
        XCTAssertTrue(viewport.center.isFinite)
    }

    func testZoomWithInvalidViewportRestoresScaleAndCenter() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 2
        )
        let original = viewport

        viewport.zoom(
            by: 2,
            anchoredAt: CGPoint(x: 150, y: 190),
            in: CGSize(width: CGFloat.infinity, height: 380)
        )

        XCTAssertEqual(viewport, original)
    }

    func testPanOverflowLeavesViewportUnchanged() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: Double.greatestFiniteMagnitude, y: 4),
            scale: 0.25
        )
        let original = viewport

        viewport.pan(byViewTranslation: CGSize(
            width: -CGFloat(Double.greatestFiniteMagnitude),
            height: 0
        ))

        XCTAssertEqual(viewport, original)
    }

    func testPanUsesViewTranslationWithoutMutatingWorldGeometry() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 10, y: 20),
            scale: 2
        )
        let strokePoint = CanvasPoint(x: 50, y: 80)

        viewport.pan(byViewTranslation: CGSize(width: 20, height: -10))

        assertEqual(viewport.center, CanvasPoint(x: 0, y: 25))
        XCTAssertEqual(strokePoint, CanvasPoint(x: 50, y: 80))
    }

    func testFitCentersBoundsAndUsesAvailableViewport() {
        var viewport = CanvasViewport()
        let bounds = CGRect(x: -50, y: -25, width: 100, height: 50)

        viewport.fit(
            bounds: bounds,
            in: CGSize(width: 300, height: 200),
            padding: 20
        )

        assertEqual(viewport.center, .zero)
        XCTAssertEqual(viewport.scale, 2.6, accuracy: 0.000_001)
    }

    func testWorldRectTracksZoomAndPanForRenderCulling() {
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 100, y: -50),
            scale: 2
        )

        let worldRect = viewport.worldRect(
            for: CGRect(x: 0, y: 0, width: 300, height: 200),
            in: CGSize(width: 300, height: 200)
        )

        XCTAssertEqual(worldRect.minX, 25, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.maxX, 175, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.minY, -100, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.maxY, 0, accuracy: 0.000_001)
    }

    func testHitTestingErasesWholeIntersectedStrokeOnly() {
        let hitID = UUID()
        let missID = UUID()
        let strokes = [
            CanvasStroke(
                id: hitID,
                color: .ink,
                width: 4,
                points: [
                    CanvasPoint(x: 0, y: 0),
                    CanvasPoint(x: 100, y: 0)
                ]
            ),
            CanvasStroke(
                id: missID,
                color: .red,
                width: 4,
                points: [
                    CanvasPoint(x: 0, y: 100),
                    CanvasPoint(x: 100, y: 100)
                ]
            )
        ]

        let hits = CanvasHitTesting.strokeIDs(
            hitBy: [
                CanvasPoint(x: 40, y: 6),
                CanvasPoint(x: 60, y: 6)
            ],
            radius: 8,
            strokes: strokes
        )

        XCTAssertEqual(hits, Set([hitID]))
    }

    func testPanTakeoverDiscardsInProgressInkAndNeverCompletesStroke() {
        var machine = CanvasInputStateMachine()

        XCTAssertTrue(machine.beginInk(tool: .pen, at: CanvasPoint(x: 1, y: 2)))
        machine.append(CanvasPoint(x: 3, y: 4))
        XCTAssertTrue(machine.beginPan())
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .panning)

        machine.finishPan()
        XCTAssertEqual(machine.state, .idle)
    }

    @MainActor
    func testTrackpadViewportDeltaCannotLeaveCanvasInputCaptured() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        XCTAssertTrue(view.beginViewportGestureSequence(
            source: .magnification,
            mode: .zoom
        ))
        view.applyViewportZoom(
            by: 1.2,
            anchoredAt: CGPoint(x: 120, y: 160),
            in: view.bounds.size
        )
        view.finishViewportGestureSequence(
            source: .magnification,
            at: CGPoint(x: 120, y: 160)
        )

        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 80, y: 90),
            in: view.bounds.size
        ))
    }

    @MainActor
    func testTrackpadDoesNotStealSpaceHeldPointerPan() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let viewPoint = CGPoint(x: 120, y: 160)
        defer { NSCursor.arrow.set() }

        view.spacePressed = true
        view.beginPan(at: viewPoint)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)

        XCTAssertFalse(view.beginViewportGestureSequence(
            source: .magnification,
            mode: .zoom
        ))

        XCTAssertEqual(view.interaction.machine.state, .panning)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testTrackpadDoesNotStealRightOrOtherPointerPan() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let viewPoint = CGPoint(x: 120, y: 160)
        defer { NSCursor.arrow.set() }
        _ = view.interaction.configure(
            strokes: [],
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )

        view.beginPan(at: viewPoint)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)

        XCTAssertFalse(view.beginViewportGestureSequence(
            source: .scroll,
            mode: .pan
        ))

        XCTAssertEqual(view.interaction.machine.state, .panning)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertEqual(view.cursorRole(at: viewPoint), .arrow)
    }

    @MainActor
    func testCanvasOwnsReentrantPinchRecognitionAcrossInteractionLifecycle() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let firstCanvasID = UUID()
        view.configure(
            canvasID: firstCanvasID,
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        let recognizer = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        XCTAssertTrue(recognizer.view === view)
        XCTAssertTrue(recognizer.target === view)
        XCTAssertTrue(recognizer.delaysMagnificationEvents)
        XCTAssertFalse(recognizer.delaysPrimaryMouseButtonEvents)

        func applyPinch(
            _ magnification: CGFloat,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let previousScale = view.interaction.viewport.scale
            recognizer.magnification = magnification
            let action = try XCTUnwrap(
                recognizer.action,
                file: file,
                line: line
            )
            XCTAssertTrue(
                NSApplication.shared.sendAction(
                    action,
                    to: recognizer.target,
                    from: recognizer
                ),
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                view.interaction.viewport.scale,
                previousScale,
                file: file,
                line: line
            )
            XCTAssertEqual(recognizer.magnification, 0, file: file, line: line)
            XCTAssertEqual(
                view.interaction.machine.state,
                .idle,
                file: file,
                line: line
            )
        }

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        XCTAssertTrue(view.interaction.appendInk(
            at: CGPoint(x: 80, y: 90),
            in: view.bounds.size
        ))
        XCTAssertNotNil(view.interaction.finishInk())
        try applyPinch(0.20)

        view.configure(
            canvasID: firstCanvasID,
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: view.interaction.viewport,
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        view.beginPan(at: CGPoint(x: 120, y: 160))
        view.continuePan(to: CGPoint(x: 135, y: 170))
        view.finishPointerInteraction(finalInkPoint: nil)
        try applyPinch(-0.10)

        view.cancelInteraction()
        view.setFrameSize(CGSize(width: 520, height: 640))
        view.configure(
            canvasID: UUID(),
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .eraser,
            color: .blue,
            width: 8,
            viewport: view.interaction.viewport,
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        try applyPinch(0.15)

        // Three pinch callbacks plus the explicit space-pan delta above.
        XCTAssertEqual(deliveredViewports.count, 4)
    }

    @MainActor
    func testCommandScrollUsesReentrantCanvasZoomPath() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveredViewport: CanvasViewport?
        view.onViewportChange = { deliveredViewport = $0 }
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))

        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 12,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = .maskCommand
        event.location = CGPoint(x: 120, y: 160)
        // A stroke owns the pointer: the zoom waits instead of discarding it
        // (CVD-05).
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
        XCTAssertNil(deliveredViewport)
        view.finishPointerInteraction(finalInkPoint: nil)

        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))

        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertGreaterThan(view.interaction.viewport.scale, 1)
        XCTAssertEqual(deliveredViewport, view.interaction.viewport)
    }

    @MainActor
    func testScrollSequenceLatchesModeThroughMomentumAndModifierChanges() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        let scaleAfterBegin = view.interaction.viewport.scale
        XCTAssertEqual(view.interaction.machine.state, .panning)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 6,
            command: false,
            phase: 2
        ))
        let scaleAfterChanged = view.interaction.viewport.scale
        XCTAssertGreaterThan(scaleAfterChanged, scaleAfterBegin)
        XCTAssertEqual(view.interaction.machine.state, .panning)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            phase: 4
        ))
        XCTAssertEqual(view.interaction.machine.state, .idle)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 4,
            command: false,
            momentumPhase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 3,
            command: true,
            momentumPhase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            momentumPhase: 3
        ))
        XCTAssertGreaterThan(view.interaction.viewport.scale, scaleAfterChanged)
        XCTAssertEqual(view.interaction.machine.state, .idle)

        let scaleBeforePan = view.interaction.viewport.scale
        let centerBeforePan = view.interaction.viewport.center
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 7,
            command: false,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: true,
            phase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: true,
            phase: 4
        ))

        XCTAssertEqual(view.interaction.viewport.scale, scaleBeforePan)
        XCTAssertNotEqual(view.interaction.viewport.center, centerBeforePan)
        XCTAssertEqual(deliveredViewports.count, 6)
    }

    @MainActor
    func testLateZeroAndMomentumTailCannotCancelNewInk() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            phase: 4
        ))
        XCTAssertEqual(deliveryCount, 1)

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: false,
            momentumPhase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            momentumPhase: 3
        ))

        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertNotNil(view.interaction.finishInk())
    }

    @MainActor
    func testInterruptedDirectScrollTailCannotReacquireNewInk() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        XCTAssertEqual(deliveryCount, 1)
        view.interruptViewportGestureForPointer()
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 6,
            command: false,
            phase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 4,
            command: false,
            phase: 4
        ))

        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertNotNil(view.interaction.finishInk())

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: true,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: true,
            phase: 4
        ))
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testInterruptedScrollMomentumCannotDiscardImagePointerPreview() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }
        let id = UUID()
        let original = CanvasImageTransform(
            center: CanvasPoint(x: 100, y: 100), width: 160, height: 90, zIndex: 1
        )
        let preview = CanvasImageTransform(
            center: CanvasPoint(x: 125, y: 115), width: 180, height: 101.25, zIndex: 1
        )

        for mode in [
            CanvasNSView.ImagePointerMode.moving(
                id: id, startWorldPoint: CanvasPoint(x: 90, y: 90), original: original
            ),
            .resizing(id: id, handle: .bottomRight, original: original)
        ] {
            view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: true, phase: 1))
            view.interruptViewportGestureForPointer()
            view.imagePointerMode = mode
            view.previewImageTransform = preview
            let countBeforeTail = deliveryCount

            view.scrollWheel(with: try canvasScrollEvent(deltaY: 4, command: false, phase: 4))
            view.scrollWheel(with: try canvasScrollEvent(deltaY: 6, command: false, momentumPhase: 1))

            XCTAssertEqual(view.previewImageTransform, preview)
            XCTAssertEqual(deliveryCount, countBeforeTail)
            if case .none = view.imagePointerMode { XCTFail("Image pointer preview was discarded") }

            view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, momentumPhase: 3))
            view.imagePointerMode = .none
            view.previewImageTransform = nil
        }

        let countBeforeFreshGesture = deliveryCount
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 5, command: true, phase: 1))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: true, phase: 4))
        XCTAssertEqual(deliveryCount, countBeforeFreshGesture + 1)
    }

    @MainActor
    func testInterruptedScrollMomentumCannotDiscardShapePointerPreview() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }
        let preview = CanvasStrokeGeometry(
            color: .blue,
            width: 3,
            points: [CanvasPoint(x: 20, y: 30), CanvasPoint(x: 90, y: 110)]
        )

        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: true, phase: 1))
        view.interruptViewportGestureForPointer()
        view.shapePointerMode = CanvasNSView.ShapePointerMode(
            kind: .rectangle,
            startViewPoint: CGPoint(x: 20, y: 30),
            startWorldPoint: CanvasPoint(x: 20, y: 30),
            endWorldPoint: CanvasPoint(x: 90, y: 110)
        )
        view.shapePreview = preview
        let countBeforeTail = deliveryCount

        view.scrollWheel(with: try canvasScrollEvent(deltaY: 4, command: false, phase: 4))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 6, command: false, momentumPhase: 1))

        XCTAssertNotNil(view.shapePointerMode)
        XCTAssertEqual(view.shapePreview, preview)
        XCTAssertEqual(deliveryCount, countBeforeTail)

        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, momentumPhase: 3))
        view.shapePointerMode = nil
        view.shapePreview = nil
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 5, command: true, phase: 1))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: true, phase: 4))
        XCTAssertEqual(deliveryCount, countBeforeTail + 1)
    }

    @MainActor
    func testNewPinchTakesOverScrollWithoutTerminalEventAndIgnoresMomentumTail() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        let installed = try XCTUnwrap(view.gestureRecognizers.compactMap {
            $0 as? NSMagnificationGestureRecognizer
        }.first)
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenMagnificationGestureRecognizer(target: view, action: action)
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)

        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        XCTAssertEqual(view.activeViewportGesture?.source, .scroll)
        // AppKit can begin magnification before scroll momentum finishes, or
        // after another responder consumed the scroll's terminal event.
        recognizer.drive(.began, magnification: 0)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
        recognizer.drive(.changed, magnification: 0.25)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
        XCTAssertEqual(view.interaction.viewport.scale, 1.25, accuracy: 0.001)
        let zoomed = view.interaction.viewport
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 12, command: false, momentumPhase: 1))
        XCTAssertEqual(view.interaction.viewport, zoomed)
        recognizer.drive(.ended, magnification: 0)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
        XCTAssertNil(view.activeViewportGesture)
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        XCTAssertNotEqual(view.interaction.viewport.center, zoomed.center)
    }

    @MainActor
    func testCancelledMagnificationTailCannotRestartUntilNewBegan() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let installed = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenMagnificationGestureRecognizer(
            target: installed.target,
            action: action
        )
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        func drive(
            _ state: NSGestureRecognizer.State,
            magnification: CGFloat
        ) {
            recognizer.drive(state, magnification: magnification)
            XCTAssertTrue(NSApplication.shared.sendAction(
                action,
                to: recognizer.target,
                from: recognizer
            ))
        }

        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.20)
        XCTAssertEqual(deliveredViewports.count, 1)
        let viewportBeforeCancellation = view.interaction.viewport

        view.cancelInteraction()
        drive(.changed, magnification: 0.15)
        drive(.ended, magnification: 0.10)
        XCTAssertEqual(view.interaction.viewport, viewportBeforeCancellation)
        XCTAssertEqual(deliveredViewports.count, 1)

        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: -0.10)
        drive(.ended, magnification: 0.05)
        XCTAssertEqual(deliveredViewports.count, 3)
        XCTAssertEqual(view.interaction.viewport.scale, viewportBeforeCancellation.scale * 0.9 * 1.05, accuracy: 0.0001)
        XCTAssertNotEqual(view.interaction.viewport, viewportBeforeCancellation)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testDetachedCanvasRecognizerCannotPublishViewportTail() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }
        let recognizer = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        let action = try XCTUnwrap(recognizer.action)

        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
        recognizer.magnification = 0.2
        XCTAssertTrue(NSApplication.shared.sendAction(
            action,
            to: recognizer.target,
            from: recognizer
        ))

        XCTAssertFalse(view.isRepresentationActive)
        XCTAssertFalse(recognizer.isEnabled)
        XCTAssertTrue(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
    }

    @MainActor
    func testIncidentalScrollCannotDiscardBufferedInk() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
        var deliveredViewports: [CanvasViewport] = []
        var completedStrokes: [[CanvasPoint]] = []
        view.onViewportChange = { deliveredViewports.append($0) }
        view.onCompleteStroke = { points, _, _ in completedStrokes.append(points) }

        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
        // Trackpad phases, a momentum tail, and a standalone wheel event.
        for event in [
            try canvasScrollEvent(deltaY: 8, command: false, phase: 1),
            try canvasScrollEvent(deltaY: 6, command: true, phase: 2),
            try canvasScrollEvent(deltaY: 0, command: false, phase: 4),
            try canvasScrollEvent(deltaY: 5, command: false, momentumPhase: 1),
            try canvasScrollEvent(deltaY: 4, command: false, momentumPhase: 2),
            try canvasScrollEvent(deltaY: 0, command: false, momentumPhase: 3),
            try canvasScrollEvent(deltaY: 7, command: false)
        ] {
            view.scrollWheel(with: event)
            XCTAssertEqual(view.interaction.machine.state, .drawing)
            XCTAssertNil(view.activeViewportGesture)
        }
        XCTAssertTrue(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())

        view.finishPointerInteraction(finalInkPoint: CGPoint(x: 80, y: 90))
        XCTAssertEqual(completedStrokes.count, 1)
        XCTAssertEqual(completedStrokes.first?.count, 3)
        XCTAssertEqual(view.interaction.machine.state, .idle)

        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, phase: 4))
        XCTAssertEqual(deliveredViewports.count, 1)
        XCTAssertNotEqual(view.interaction.viewport.center, CanvasViewport().center)
    }

    @MainActor
    func testIncidentalPinchCannotDiscardBufferedInk() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
        let installed = try XCTUnwrap(view.gestureRecognizers.compactMap {
            $0 as? NSMagnificationGestureRecognizer
        }.first)
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenMagnificationGestureRecognizer(target: view, action: action)
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)
        var deliveredViewports: [CanvasViewport] = []
        var completedStrokes: [[CanvasPoint]] = []
        view.onViewportChange = { deliveredViewports.append($0) }
        view.onCompleteStroke = { points, _, _ in completedStrokes.append(points) }

        func drive(_ state: NSGestureRecognizer.State, magnification: CGFloat) {
            recognizer.drive(state, magnification: magnification)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
        }

        // A short pinch that begins and ends while drawing.
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        drive(.began, magnification: 0)
        drive(.ended, magnification: 0.2)
        XCTAssertEqual(view.interaction.machine.state, .drawing)

        // A pinch that outlives the stroke stays ignored until a new began.
        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.25)
        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertNil(view.activeViewportGesture)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(completedStrokes.count, 1)
        XCTAssertEqual(completedStrokes.first?.count, 2)
        drive(.changed, magnification: 0.25)
        drive(.ended, magnification: 0.1)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
        XCTAssertTrue(deliveredViewports.isEmpty)

        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.25)
        drive(.ended, magnification: 0)
        XCTAssertEqual(view.interaction.viewport.scale, 1.25, accuracy: 0.001)
        XCTAssertFalse(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testCancellationKeepsIncidentalScrollTailSuppressedUntilItsSequenceEnds() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        // A scroll that began while ink owned the pointer stays dead after the
        // stroke is cancelled, through its direct and momentum tail.
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        view.cancelInteraction()
        XCTAssertEqual(view.interaction.machine.state, .idle)
        for event in [
            try canvasScrollEvent(deltaY: 6, command: false, phase: 2),
            try canvasScrollEvent(deltaY: 6, command: true, phase: 2),
            try canvasScrollEvent(deltaY: 0, command: false, phase: 4),
            try canvasScrollEvent(deltaY: 5, command: false, momentumPhase: 1),
            try canvasScrollEvent(deltaY: 4, command: false, momentumPhase: 2)
        ] {
            view.scrollWheel(with: event)
            XCTAssertNil(view.activeViewportGesture)
        }
        XCTAssertTrue(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, momentumPhase: 3))
        XCTAssertFalse(view.suppressesScrollSequence)

        // After its terminal event, a new scroll pans normally.
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, phase: 4))
        XCTAssertEqual(deliveredViewports.count, 1)
        let panned = view.interaction.viewport
        XCTAssertNotEqual(panned.center, CanvasViewport().center)

        // A transient interruption keeps the tail dead too; a new began that
        // arrives without the old terminal event still takes over.
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        view.interruptTransientInteraction()
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 6, command: false, phase: 2))
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.viewport, panned)
        XCTAssertEqual(deliveredViewports.count, 1)
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 8, command: false, phase: 1))
        view.scrollWheel(with: try canvasScrollEvent(deltaY: 0, command: false, phase: 4))
        XCTAssertEqual(deliveredViewports.count, 2)
        XCTAssertNotEqual(view.interaction.viewport.center, panned.center)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testCancellationKeepsIncidentalPinchTailSuppressedUntilANewPinch() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 380))
        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
        let installed = try XCTUnwrap(view.gestureRecognizers.compactMap {
            $0 as? NSMagnificationGestureRecognizer
        }.first)
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenMagnificationGestureRecognizer(target: view, action: action)
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        func drive(_ state: NSGestureRecognizer.State, magnification: CGFloat) {
            recognizer.drive(state, magnification: magnification)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: recognizer))
        }

        // A pinch that began while ink owned the pointer stays dead after the
        // stroke is cancelled, through its changed and ended tail.
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.25)
        view.cancelInteraction()
        XCTAssertEqual(view.interaction.machine.state, .idle)
        drive(.changed, magnification: 0.25)
        drive(.changed, magnification: 0.10)
        XCTAssertNil(view.activeViewportGesture)
        drive(.ended, magnification: 0.10)
        XCTAssertFalse(view.suppressesMagnification)
        XCTAssertTrue(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())

        // A new pinch zooms normally.
        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.25)
        drive(.ended, magnification: 0)
        XCTAssertEqual(view.interaction.viewport.scale, 1.25, accuracy: 0.001)
        let deliveredAfterZoom = deliveredViewports.count
        XCTAssertGreaterThan(deliveredAfterZoom, 0)

        // A transient interruption keeps the tail dead too; a new began that
        // arrives without the old terminal event still takes over.
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.20)
        view.interruptTransientInteraction()
        drive(.changed, magnification: 0.20)
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.viewport.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(deliveredViewports.count, deliveredAfterZoom)
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.20)
        drive(.ended, magnification: 0)
        XCTAssertEqual(view.interaction.viewport.scale, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(deliveredViewports.count, deliveredAfterZoom)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testTransientInterruptionReachesLiveSurfaceWithoutRebuildingIt() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let object = try XCTUnwrap(session.selectedSemanticObject)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let bridge = CanvasNSViewRepresentable(session: session, selectionAccentColor: .systemBlue,
                                               clearReadabilityEnabled: false)
        bridge.configure(view)
        let epoch = session.interactionCancellationEpoch

        // Zoom, hide, and section changes commit an open text editor.
        view.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" edited", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        session.interruptActiveInteraction()
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertEqual(session.semanticObjects.first { $0.id == object.id }?.content?.text, "Keep edited")

        // ...and discard unfinished ink on the same live surface.
        session.selectTool(.pen)
        bridge.configure(view)
        let strokeCount = session.strokes.count
        XCTAssertTrue(view.interaction.beginInk(at: CGPoint(x: 40, y: 50), in: view.bounds.size))
        XCTAssertTrue(view.interaction.appendInk(at: CGPoint(x: 60, y: 70), in: view.bounds.size))
        session.interruptActiveInteraction()
        XCTAssertEqual(view.interaction.machine.state, .idle)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(session.strokes.count, strokeCount)
        XCTAssertTrue(view.isRepresentationActive)
        XCTAssertEqual(session.interactionCancellationEpoch, epoch)

        // A dismantled surface stops observing; lifecycle still rebuilds.
        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.interactionInterruptionObservation)
        session.cancelActiveInteraction()
        XCTAssertEqual(session.interactionCancellationEpoch, epoch + 1)
    }

    @MainActor
    func testDismantleDefersDraftPublicationUntilAfterSwiftUIGraphTeardown() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let replacementSession = CanvasSession(store: try makeTestCanvasStore())
        let replacementPlaced = await replacementSession.insertText(
            "Other",
            at: .zero,
            prefersDarkSurface: false
        )
        XCTAssertTrue(replacementPlaced)
        let object = try XCTUnwrap(session.semanticObjects.first)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let bridge = CanvasNSViewRepresentable(
            session: session,
            selectionAccentColor: .systemBlue,
            clearReadabilityEnabled: false
        )
        bridge.configure(view)
        view.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" edited", replacementRange: NSRange(location: 4, length: 0))
        let availabilityBeforeDismantle = session.editingAvailabilityToken

        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())

        XCTAssertFalse(view.isRepresentationActive)
        XCTAssertEqual(session.editingAvailabilityToken, availabilityBeforeDismantle)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")

        view.activateRepresentation()
        CanvasNSViewRepresentable(
            session: replacementSession,
            selectionAccentColor: .systemBlue,
            clearReadabilityEnabled: false
        ).configure(view)
        XCTAssertTrue(view.isRepresentationActive)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep edited")
        XCTAssertGreaterThan(session.editingAvailabilityToken, availabilityBeforeDismantle)
        XCTAssertEqual(replacementSession.semanticObjects.first?.content?.text, "Other")
    }

    @MainActor
    func testPreparedDeactivationRetainsSessionUntilDeferredDraftCommit() async throws {
        let store = try makeTestCanvasStore()
        var session: CanvasSession? = CanvasSession(store: store)
        let placed = await session?.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed == true)
        let object = try XCTUnwrap(session?.semanticObjects.first)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        CanvasNSViewRepresentable(
            session: try XCTUnwrap(session),
            selectionAccentColor: .systemBlue,
            clearReadabilityEnabled: false
        ).configure(view)
        view.beginSemanticTextEditing(object)
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" edited", replacementRange: NSRange(location: 4, length: 0))

        var completion = view.prepareForDeferredDeactivation()
        weak let retainedSession = session
        session = nil

        XCTAssertNotNil(completion)
        XCTAssertNotNil(retainedSession)
        completion?()
        completion = nil
        XCTAssertNil(retainedSession)
        XCTAssertEqual(
            CanvasStore(container: store.container).semanticObjects.first?.content?.text,
            "Keep edited"
        )
    }

    @MainActor
    func testReentrantDismantleDoesNotDuplicateAnInProgressTextCommit() async throws {
        let session = CanvasSession(store: try makeTestCanvasStore())
        let placed = await session.insertText("Keep", at: .zero, prefersDarkSurface: false)
        XCTAssertTrue(placed)
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        CanvasNSViewRepresentable(
            session: session,
            selectionAccentColor: .systemBlue,
            clearReadabilityEnabled: false
        ).configure(view)
        view.beginSemanticTextEditing(try XCTUnwrap(session.semanticObjects.first))
        let editor = try XCTUnwrap(view.semanticTextEditor)
        editor.insertText(" edited", replacementRange: NSRange(location: 4, length: 0))
        editor.isFinishing = true
        let availabilityBeforeDismantle = session.editingAvailabilityToken

        let completion = view.prepareForDeferredDeactivation()
        completion?()

        XCTAssertTrue(view.semanticTextEditor === editor)
        XCTAssertEqual(session.editingAvailabilityToken, availabilityBeforeDismantle)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep")

        editor.isFinishing = false
        XCTAssertTrue(view.finishSemanticTextEditing(commit: true))
        XCTAssertNil(view.semanticTextEditor)
        XCTAssertEqual(session.semanticObjects.first?.content?.text, "Keep edited")
    }

    private func canvasScrollEvent(
        deltaX: Int32 = 0,
        deltaY: Int32,
        command: Bool,
        phase: Int64 = 0,
        momentumPhase: Int64 = 0
    ) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ))
        // CGEvent can inherit the process's current hardware modifier state.
        // Always assign flags so a non-Command phase cannot accidentally take
        // the zoom path when the user is physically holding Command.
        event.flags = command ? .maskCommand : []
        event.location = CGPoint(x: 120, y: 160)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: phase
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: momentumPhase
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testSelectToolNeverStartsAnInkOperation() {
        var machine = CanvasInputStateMachine()

        XCTAssertFalse(machine.beginInk(
            tool: .select,
            at: CanvasPoint(x: 1, y: 2)
        ))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.bufferedPointCount, 0)
        XCTAssertNil(machine.finishInk())
    }

    func testInterruptedEraseIsDiscardedDeterministically() {
        var machine = CanvasInputStateMachine()

        XCTAssertTrue(machine.beginInk(tool: .eraser, at: CanvasPoint(x: 1, y: 2)))
        machine.append(CanvasPoint(x: 3, y: 4))
        XCTAssertTrue(machine.cancel())
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .idle)
    }

    func testPointerUpCompletesExactlyOneBufferedOperation() {
        var machine = CanvasInputStateMachine()
        let points = [
            CanvasPoint(x: 1, y: 2),
            CanvasPoint(x: 3, y: 4),
            CanvasPoint(x: 5, y: 6)
        ]

        XCTAssertTrue(machine.beginInk(tool: .pen, at: points[0]))
        machine.append(points[1])
        machine.append(points[2])

        XCTAssertEqual(machine.finishInk(), .stroke(points))
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .idle)
    }

    func testLongGestureCompactsWithoutLosingItsEndpoints() throws {
        var machine = CanvasInputStateMachine()
        let first = CanvasPoint(x: 0, y: 0)
        XCTAssertTrue(machine.beginInk(tool: .pen, at: first))

        let finalIndex = CanvasInputStateMachine.maximumBufferedPointCount * 3
        for index in 1...finalIndex {
            machine.append(CanvasPoint(x: Double(index), y: Double(index % 13)))
        }

        guard case let .stroke(points) = try XCTUnwrap(machine.finishInk()) else {
            return XCTFail("Expected a completed stroke")
        }
        XCTAssertLessThanOrEqual(
            points.count,
            CanvasInputStateMachine.maximumBufferedPointCount
        )
        XCTAssertEqual(points.first, first)
        XCTAssertEqual(
            points.last,
            CanvasPoint(x: Double(finalIndex), y: Double(finalIndex % 13))
        )
    }

    @MainActor
    func testUnchangedRefreshReusesDecodedStrokeAndRenderToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var decodeCount = 0
        let store = CanvasStore(
            container: container,
            decodeStroke: { data, version in
                decodeCount += 1
                return try CanvasStrokeCodec.decode(
                    data,
                    expectedVersion: version
                )
            }
        )

        let first = try XCTUnwrap(store.addStroke(
            color: .blue,
            width: 4,
            points: [CanvasPoint(x: 1, y: 2)]
        ))
        XCTAssertEqual(decodeCount, 1)

        store.refresh()
        XCTAssertEqual(decodeCount, 1)
        XCTAssertEqual(store.strokes.first?.renderToken, first.renderToken)

        XCTAssertNotNil(store.addStroke(
            color: .red,
            width: 3,
            points: [CanvasPoint(x: 10, y: 20)]
        ))
        XCTAssertEqual(decodeCount, 2)
        XCTAssertEqual(
            store.strokes.first(where: { $0.id == first.id })?.renderToken,
            first.renderToken
        )
    }

    @MainActor
    func testChangedReplicaInvalidatesOnlyItsRenderToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var decodeCount = 0
        let store = CanvasStore(
            container: container,
            decodeStroke: { data, version in
                decodeCount += 1
                return try CanvasStrokeCodec.decode(
                    data,
                    expectedVersion: version
                )
            }
        )
        let original = try XCTUnwrap(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertEqual(decodeCount, 1)

        let externalContext = ModelContext(container)
        let row = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<CanvasStrokeItem>()).first
        )
        row.payload = try CanvasStrokeCodec.encode(
            color: .green,
            width: 5,
            points: [CanvasPoint(x: 8, y: 9)]
        )
        row.mutationVersion += 1
        row.updatedAt = row.updatedAt.addingTimeInterval(1)
        try externalContext.save()

        store.refresh()

        XCTAssertEqual(decodeCount, 2)
        let changed = try XCTUnwrap(store.strokes.first)
        XCTAssertNotEqual(changed.renderToken, original.renderToken)
        XCTAssertEqual(changed.color, .green)
    }

    private func assertEqual(
        _ lhs: CanvasPoint,
        _ rhs: CanvasPoint,
        accuracy: Double = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
    }
}
