import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import Attic

/// The owner's floating controls (2026-10-01, B with softening): content
/// runs the panel's full height and passes clearly under the controls,
/// softened behind each control only (the content's own opacity, lowered in
/// a feathered mask of the control's footprint), and receding to about 35 %
/// at the panel's very edges.
@MainActor
final class FloatingControlsTests: XCTestCase {
    // MARK: - One value

    func testOneValueSetsTheDimAndTheBlur() {
        let strength = AtticEdgeBlur.softening
        let visible = AtticSoftening.visible(strength: strength, reduceTransparency: false)
        XCTAssertTrue((0.5...0.6).contains(visible), "about 50 to 60 % visible behind a control: \(visible)")
        XCTAssertTrue((4...6).contains(AtticSoftening.blur(strength: strength)), "a soft blur of about 4 to 6 pt")
        XCTAssertEqual(AtticSoftening.visible(strength: 0, reduceTransparency: false), 1, "strength 0: no softening")
        XCTAssertEqual(AtticSoftening.blur(strength: 0), 0)
        XCTAssertEqual(AtticEdgeBlur.edgeVisible, 0.35, "about 35 % at the panel's very edge")
    }

    /// A row is blurred by how deep it is in a control's line, and not at
    /// all clear of it.
    func testARowIsBlurredOnlyAsItPassesAControlsLine() {
        let band = AtticSofteningBand(top: 80, bottom: 106)
        XCTAssertEqual(band.depth(of: CGRect(x: 0, y: 200, width: 300, height: 34)), 0, "clear of the line")
        XCTAssertEqual(band.depth(of: CGRect(x: 0, y: 76, width: 300, height: 34)), 1, "the line all over the row's middle")
        XCTAssertEqual(band.depth(of: CGRect(x: 0, y: 93, width: 300, height: 34)), 0.5, accuracy: 0.001, "half in")
        XCTAssertEqual(band.depth(of: CGRect(x: 0, y: 106, width: 300, height: 34)), 0, "just past it")
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let bands = TasksPage.softeningBands(layout: layout, tabsTop: tabsTop, bottomInset: 12)
        XCTAssertEqual(bands.count, 2, "the tabs and the add bar (a row between the header's buttons stays sharp)")
        XCTAssertEqual(bands[0].top, tabsTop - TasksFloatingControls.tabsOutset)
        XCTAssertEqual(bands[1].bottom, 508)
        XCTAssertEqual(bands[1].bottom - bands[1].top, AtticControlSize.addBarHeight)
    }

    func testReduceTransparencyIsASolidBackingOfTheRealSurface() {
        XCTAssertEqual(AtticSoftening.visible(strength: AtticEdgeBlur.softening, reduceTransparency: true), 0,
                       "nothing shows behind a control: the surface itself is the backing")
        XCTAssertEqual(AtticSoftening.visible(strength: 0, reduceTransparency: true), 0)
    }

    // MARK: - The footprint's shape

    func testTheShapeIsTheControlsFeatheredWithNoEdge() {
        let feather: CGFloat = 10
        let size = CGSize(width: 120 + feather * 2, height: 36 + feather * 2)
        let alpha = { (x: CGFloat, y: CGFloat) in
            AtticSofteningShape.alpha(at: CGPoint(x: x, y: y), size: size, radius: 18, feather: feather)
        }
        XCTAssertEqual(alpha(size.width / 2, size.height / 2), 1, "full behind the control")
        XCTAssertEqual(alpha(feather + 1, size.height / 2), 1, "to its edge")
        XCTAssertEqual(alpha(0, size.height / 2), 0, accuracy: 0.001, "nothing a feather beyond it")
        XCTAssertEqual(alpha(1, 1), 0, accuracy: 0.001, "nor at a corner's diagonal")
        var last = alpha(feather, size.height / 2)
        for step in stride(from: feather, through: 0, by: -0.25) {
            let value = alpha(step, size.height / 2)
            XCTAssertLessThanOrEqual(value, last + 0.0001)
            XCTAssertLessThan(last - value, 0.05, "no step at \(step)")
            last = value
        }
    }

    func testTheNinePartShapeStretchesWithoutRedrawing() throws {
        let image = try XCTUnwrap(AtticSofteningShape.image(radius: 18, feather: 10, scale: 2))
        XCTAssertEqual(image.image.width, image.image.height)
        XCTAssertEqual(image.centre.width, 1 / 57, accuracy: 0.0001, "a one-point middle")
        XCTAssertTrue(AtticSofteningShape.image(radius: 18, feather: 10, scale: 2)?.image === image.image, "made once")
    }

    // MARK: - The softening is applied behind each control only

    /// The mask, rendered: the content keeps the chosen share at the core of
    /// a footprint, all of itself a feather away, and between two controls.
    func testTheMaskDimsOnlyBehindEachControl() throws {
        let footprints = [AtticControlFootprint(frame: CGRect(x: 20, y: 30, width: 100, height: 20), cornerRadius: 6),
                          AtticControlFootprint(frame: CGRect(x: 200, y: 30, width: 56, height: 28), cornerRadius: 14)]
        let mask = AtticSofteningMask(footprints: footprints, visible: 0.12)
            .frame(width: 300, height: 120)
            .coordinateSpace(AtticSoftening.space)
        let renderer = ImageRenderer(content: mask)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        func alpha(_ x: Int, _ y: Int) -> Double { Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1) }
        XCTAssertEqual(alpha(70, 40), 0.12, accuracy: 0.03, "behind the first control")
        XCTAssertEqual(alpha(228, 44), 0.12, accuracy: 0.03, "behind the second")
        XCTAssertEqual(alpha(160, 40), 1, accuracy: 0.01, "between them, the content is all there")
        XCTAssertEqual(alpha(70, 100), 1, accuracy: 0.01, "and below them")
        XCTAssertGreaterThan(alpha(70, 56), 0.12, "fading back in over the feather")
        XCTAssertLessThan(alpha(70, 56), 1)
    }

    /// The page reports its tab labels and add bar; the header's buttons and
    /// the tabs line's icons are fixed footprints from the layout.
    func testEveryFloatingControlOnTheTasksPageHasItsFootprint() throws {
        let height: CGFloat = 520
        let hosted = try Hosted(height: height)
        defer { hosted.close() }
        hosted.spin(1)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: height))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let reported = hosted.pointer.softening.controls.map(\.frame)
        XCTAssertTrue(reported.contains { abs($0.midY - (tabsTop + AtticLayout.pageTabsHeight / 2)) < 6 && $0.width > 100 },
                      "the tab labels: \(reported)")
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let bar = reported.first { abs($0.maxY - (height - bottomInset)) < 2 && abs($0.height - AtticControlSize.addBarHeight) < 2 }
        XCTAssertNotNil(bar, "the add bar: \(reported)")
        XCTAssertGreaterThan(bar?.width ?? 0, 250, "the add bar's whole capsule")

        let fixed = TasksPage.fixedFootprints(layout: layout, tabsTop: tabsTop, cornerInset: 0, lineEndInset: 8).map(\.frame)
        XCTAssertEqual(fixed.count, 3)
        XCTAssertEqual(fixed[0].origin, CGPoint(x: layout.chromeInsets.leading, y: layout.chromeInsets.top), "the pin")
        XCTAssertEqual(fixed[1].maxX, layout.panelSize.width - layout.chromeInsets.trailing, accuracy: 0.5, "the page button")
        XCTAssertEqual(fixed[2].midY, tabsTop + AtticLayout.pageTabsHeight / 2, accuracy: 0.5, "the icons, on the tabs line")
    }

    /// Typing's strip and the transient bars never re-mask the lists (one
    /// frame per keystroke): they report no footprint.
    func testTransientControlsDoNotReMaskTheLists() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        let before = hosted.pointer.softening.controls
        // A draft shows the strip (set directly: typed text would leave the
        // spell checker's correction panel up for a later test).
        hosted.model.addBar = TaskAddBarText(text: "Buy milk")
        hosted.spin(0.5)
        XCTAssertEqual(hosted.pointer.softening.controls, before, "the strip's appearance changed no footprint")
    }

    // MARK: - The controls stay legible

    /// The contrast model's coverage is measured, not assumed: a line of
    /// 13 pt semibold (the densest task text that passes under the tabs),
    /// blurred by the softening, covers no more than this.
    static let blurredTextCoverage = 0.3

    func testTheBlurredTextCoverageIsMeasured() throws {
        let scale: CGFloat = 2, width = 640, height = 120
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Finalize launch checklist WWW mmm" as NSString).draw(
            at: CGPoint(x: 10, y: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.current = nil
        let image = CIImage(cgImage: try XCTUnwrap(context.makeImage()))
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(AtticSoftening.blur(strength: AtticEdgeBlur.softening) * scale))
            .cropped(to: image.extent)
        let output = try XCTUnwrap(CIContext().createCGImage(blurred, from: image.extent))
        let bytes = try XCTUnwrap(output.dataProvider?.data.flatMap { CFDataGetBytePtr($0) })
        var peak = 0
        for index in stride(from: 3, to: width * height * 4, by: 4) { peak = max(peak, Int(bytes[index])) }
        XCTAssertLessThanOrEqual(Double(peak) / 255, Self.blurredTextCoverage + 0.01)
    }

    /// The labels on top keep their floors while the content shows through
    /// behind them: every pixel of a label's letters has the real surface
    /// behind it (the halo: the content gives way within 2.5 pt of each
    /// letter), so its contrast is exactly what the design system tunes;
    /// between and around the letters the content keeps its softened share.
    func testTheLabelsKeepTheirFloorsWhileContentShowsThrough() throws {
        let titles = TasksTab.allCases.map(\.title)
        let m = AtticPageTabsMetrics.self
        let origin = CGPoint(x: 12, y: 22)
        let visible = AtticSoftening.visible(strength: AtticEdgeBlur.softening, reduceTransparency: false)
        func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.frame(width: 260, height: 60, alignment: .topLeading)
                .coordinateSpace(AtticSoftening.space)
                .atticDesign(AtticDesignContext(mode: .light)))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let labels = try render(ZStack(alignment: .topLeading) {
            HStack(spacing: m.spacing) {
                ForEach(titles, id: \.self) { AtticText(verbatim: $0, style: .pageTabSelected, ink: .heading).fixedSize() }
            }
            .frame(height: AtticLayout.pageTabsHeight)
            .offset(x: origin.x, y: origin.y)
        })
        let footprint = AtticControlFootprint(frame: CGRect(x: origin.x - 5, y: origin.y - 5, width: 150, height: 26), cornerRadius: 11)
        let mask = try render(AtticSofteningMask(footprints: [footprint], visible: visible) {
            AtticLabelHalo(titles: titles, style: .pageTabSelected, spacing: m.spacing, lineHeight: AtticLayout.pageTabsHeight,
                           origin: origin, underline: (m.underlineGap, m.underlineHeight))
        })
        var glyphs = 0, exposed = 0, showing = 0
        for y in 0..<labels.pixelsHigh {
            for x in 0..<labels.pixelsWide {
                guard let ink = labels.colorAt(x: x, y: y)?.alphaComponent, let content = mask.colorAt(x: x, y: y)?.alphaComponent else { continue }
                if ink > 0.3 {
                    glyphs += 1
                    if content > 0.05 { exposed += 1 }
                } else if footprint.frame.insetBy(dx: 2, dy: 2).contains(CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2)),
                          abs(content - visible) < 0.08 {
                    showing += 1
                }
            }
        }
        XCTAssertGreaterThan(glyphs, 200, "the labels were drawn")
        XCTAssertEqual(exposed, 0, "no letter has content behind it")
        XCTAssertGreaterThan(showing, 400, "the content shows through at its softened share around the letters")
    }

    // MARK: - The live value (preview builds)

    func testTheOneValueIsTunedLiveInPreviewBuildsOnly() {
        XCTAssertEqual(AtticSofteningLab(defaults: nil).strength, AtticEdgeBlur.softening)
        #if DEBUG
        XCTAssertEqual(AtticSofteningLab(defaults: nil, environment: ["ATTIC_UI_TEST_SOFTENING_STRENGTH": "0"]).strength, 0)
        #endif
        let defaults = UserDefaults(suiteName: "AtticSofteningLabTest-\(UUID().uuidString)")!
        let lab = AtticSofteningLab(defaults: defaults)
        lab.strength = 0.5
        XCTAssertEqual(AtticSofteningLab(defaults: defaults).strength, 0.5, "a preview keeps the owner's value")
        lab.reset()
        XCTAssertEqual(lab.strength, AtticEdgeBlur.softening)
    }
}
