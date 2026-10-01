import AppKit
import CoreImage
import Metal
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

/// The owner's floating controls (2026-10-01, B with softening): content
/// runs the panel's full height and passes clearly under the controls,
/// softened (a soft blur and a slight dim) behind each control only, and
/// receding to about 35 % at the panel's very edges.
@MainActor
final class FloatingControlsTests: XCTestCase {
    // MARK: - One value

    func testOneValueSetsTheBlurAndTheDim() {
        XCTAssertEqual(AtticEdgeBlur.softeningBlur(), 6 * CGFloat(AtticEdgeBlur.softening), accuracy: 0.001)
        XCTAssertTrue((4...6).contains(AtticEdgeBlur.softeningBlur()), "a soft blur, about 4 to 6 pt")
        XCTAssertTrue((0.5...0.6).contains(AtticEdgeBlur.softeningVisible()), "about 50 to 60 % visible behind a control")
        XCTAssertEqual(AtticEdgeBlur.softeningBlur(strength: 0), 0)
        XCTAssertEqual(AtticEdgeBlur.softeningVisible(strength: 0), 1)
        XCTAssertEqual(AtticEdgeBlur.edgeVisible, 0.35, "about 35 % at the panel's very edge")
    }

    // MARK: - Reduce Transparency

    func testReduceTransparencyDrawsASolidBackingBehindControls() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for surface in PanelSurfaceStyle.allCases {
                var design = AtticDesignContext(mode: mode)
                design.surface = surface
                let live = AtticControlBackdrop.configuration(design: design, cornerRadius: 18, location: 0.1)
                XCTAssertGreaterThan(live.blur, 3, "\(mode) \(surface): blurred")
                XCTAssertLessThan(live.veil.alpha, 1, "\(mode) \(surface): a slight dim, not a backing")
                design.reduceTransparency = true
                let solid = AtticControlBackdrop.configuration(design: design, cornerRadius: 18, location: 0.1)
                XCTAssertEqual(solid.blur, 0, "\(mode) \(surface): no blur under Reduce Transparency")
                XCTAssertEqual(solid.veil.alpha, 1, "\(mode) \(surface): a solid backing")
                XCTAssertEqual(solid.veil, AtticControlBackdrop.surface(design: design, location: 0.1).withAlpha(1),
                               "\(mode) \(surface): in the surface's own colour")
            }
        }
    }

    /// On Solid the veil is the surface itself at the dim: over nothing it
    /// shows nothing, over content it leaves the chosen share visible.
    func testOnSolidTheVeilLeavesTheChosenShareVisible() {
        let design = AtticDesignContext(mode: .light)
        let configuration = AtticControlBackdrop.configuration(design: design, cornerRadius: 18, location: 0.5)
        XCTAssertEqual(configuration.veil.alpha, 1 - AtticEdgeBlur.softeningVisible(), accuracy: 0.0001)
        let surface = AtticControlBackdrop.surface(design: design, location: 0.5)
        XCTAssertEqual(configuration.veil.withAlpha(1), surface, "the surface's own colour: no box shows over empty space")
    }

    // MARK: - The footprint

    func testTheMaskIsTheControlsShapeFeatheredWithNoEdge() {
        let feather: CGFloat = 10
        let size = CGSize(width: 120 + feather * 2, height: 36 + feather * 2)
        let alpha = { (x: CGFloat, y: CGFloat) in
            AtticControlBackdropView.alpha(at: CGPoint(x: x, y: y), size: size, radius: 18, feather: feather)
        }
        XCTAssertEqual(alpha(size.width / 2, size.height / 2), 1, "full behind the control")
        XCTAssertEqual(alpha(feather + 1, size.height / 2), 1, "to its edge")
        XCTAssertEqual(alpha(0, size.height / 2), 0, accuracy: 0.001, "nothing a feather beyond it")
        XCTAssertEqual(alpha(1, 1), 0, accuracy: 0.001, "nor at a corner's diagonal")
        // Falling smoothly outward: no visible line anywhere.
        var last = alpha(feather, size.height / 2)
        for step in stride(from: feather, through: 0, by: -0.25) {
            let value = alpha(step, size.height / 2)
            XCTAssertLessThanOrEqual(value, last + 0.0001)
            XCTAssertLessThan(last - value, 0.05, "no step at \(step)")
            last = value
        }
    }

    func testTheNinePartMaskStretchesWithoutRedrawing() throws {
        let image = try XCTUnwrap(AtticControlBackdropView.maskImage(radius: 18, feather: 10, scale: 2))
        XCTAssertEqual(image.image.width, image.image.height)
        XCTAssertEqual(image.centre.width, 1 / 57, accuracy: 0.0001, "a one-point middle")
        XCTAssertEqual(image.centre.minX, 28.0 / 57, accuracy: 0.0001)
    }

    // MARK: - The softening is applied behind the control only

    /// Rendered by Core Animation itself: stripes under a backdrop come out
    /// blurred and dimmed inside the control's footprint and untouched a
    /// feather beyond it.
    func testTheBackdropSoftensOnlyWhatIsBehindTheControl() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let width = 240, height = 120
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])

        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.backgroundColor = CGColor(gray: 1, alpha: 1)
        for x in stride(from: 0, to: width, by: 4) {
            let stripe = CALayer()
            stripe.frame = CGRect(x: x, y: 0, width: 2, height: height)
            stripe.backgroundColor = CGColor(gray: 0, alpha: 1)
            root.addSublayer(stripe)
        }
        let backdrop = AtticControlBackdropView(frame: CGRect(x: 100, y: 20, width: 120, height: 80))
        backdrop.configuration = .init(blur: AtticEdgeBlur.softeningBlur(), veil: AtticRGBA(0xFFFFFF).withAlpha(0.43),
                                       cornerRadius: 12, feather: 10)
        backdrop.layout()
        let viewLayer = try XCTUnwrap(backdrop.layer)
        XCTAssertEqual(backdrop.blurRadius, AtticEdgeBlur.softeningBlur(), accuracy: 0.001)
        // The view's own layer configuration, on a layer of the test's tree.
        let layer = CALayer()
        layer.frame = backdrop.frame
        layer.backgroundFilters = viewLayer.backgroundFilters
        layer.backgroundColor = viewLayer.backgroundColor
        let mask = try XCTUnwrap(viewLayer.mask)
        viewLayer.mask = nil
        layer.mask = mask
        root.addSublayer(layer)
        CATransaction.flush()
        renderer.layer = root
        CATransaction.flush()
        renderer.bounds = root.frame
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // CARenderer's Metal work completes on its queue.
        Thread.sleep(forTimeInterval: 0.3)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        func spread(x: Int, y: Int) -> (min: Int, max: Int) {
            let values = (x..<x + 8).map { Int(pixels[(y * width + $0) * 4]) }
            return (values.min() ?? 0, values.max() ?? 0)
        }
        let outside = spread(x: 20, y: 60)
        XCTAssertLessThan(outside.min, 20, "crisp beyond the footprint")
        XCTAssertGreaterThan(outside.max, 235)
        let inside = spread(x: 156, y: 60)
        XCTAssertLessThan(inside.max - inside.min, 40, "blurred behind the control: \(inside)")
        XCTAssertGreaterThan(inside.min, 120, "and dimmed toward the surface: \(inside)")
    }

    /// The contrast model's coverage is measured, not assumed: a line of
    /// 13 pt semibold (the densest task text that passes under the tabs),
    /// blurred by the softening, covers no more than it says.
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
            .applyingGaussianBlur(sigma: Double(AtticEdgeBlur.softeningBlur() * scale))
            .cropped(to: image.extent)
        let output = try XCTUnwrap(CIContext().createCGImage(blurred, from: image.extent))
        let bytes = try XCTUnwrap(output.dataProvider?.data.flatMap { CFDataGetBytePtr($0) })
        var peak = 0
        for index in stride(from: 3, to: width * height * 4, by: 4) { peak = max(peak, Int(bytes[index])) }
        XCTAssertLessThanOrEqual(Double(peak) / 255, AtticEdgeBlur.blurredTextCoverage + 0.01)
    }

    // MARK: - Every floating control has its softening

    func testEveryFloatingControlOnTheTasksPageHasItsSoftening() throws {
        let height: CGFloat = 520
        let hosted = try Hosted(height: height)
        defer { hosted.close() }
        hosted.spin(1)
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        let feather = AtticEdgeBlur.softeningFeather
        let footprints = backdrops(in: content).map { view -> CGRect in
            let frame = view.convert(view.bounds, to: content)
            // Top-left origin, as the page lays out.
            let flipped = CGRect(x: frame.minX, y: content.isFlipped ? frame.minY : content.bounds.height - frame.maxY,
                                 width: frame.width, height: frame.height)
            return flipped.insetBy(dx: feather, dy: feather)
        }
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: height))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let tabsLine = footprints.filter { abs($0.midY - (tabsTop + AtticLayout.pageTabsHeight / 2)) < 6 }
        XCTAssertTrue(tabsLine.contains { $0.width > 100 }, "the tab labels: \(tabsLine)")
        XCTAssertGreaterThanOrEqual(tabsLine.filter { $0.width < 40 }.count, 2, "Find and View Options: \(tabsLine)")
        let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
        let bar = footprints.first { abs($0.maxY - (height - bottomInset)) < 2 && abs($0.height - AtticControlSize.addBarHeight) < 2 }
        XCTAssertNotNil(bar, "the add bar: \(footprints)")
        XCTAssertGreaterThan(bar?.width ?? 0, 250, "the add bar's whole capsule")
    }

    func testTheHeadersButtonsHaveTheirSoftening() throws {
        let header = PanelHeader(isPinned: false, page: .tasks, onTogglePin: {}, onSelectPage: { _ in })
            .frame(width: 320)
            .atticDesign(AtticDesignContext(mode: .light))
        let host = NSHostingView(rootView: header)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: PanelHeaderLayout.height)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 320, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let feather = AtticEdgeBlur.softeningFeather
        let inner = backdrops(in: host).map { $0.frame.insetBy(dx: feather, dy: feather) }
        XCTAssertEqual(inner.count, 2, "the pin and the page button")
        for frame in inner {
            XCTAssertEqual(frame.height, PanelHeaderLayout.height, accuracy: 1)
            XCTAssertEqual(frame.width, PanelHeaderLayout.pinSize.width, accuracy: 1)
        }
    }

    // MARK: - Hit-testing and VoiceOver are unchanged

    func testTheSofteningTakesNoClickAndIsNotRead() {
        let view = AtticControlBackdropView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertNil(view.hitTest(CGPoint(x: 50, y: 25)), "clicks reach the control or the row")
        XCTAssertFalse(view.isAccessibilityElement(), "VoiceOver never reads it")
    }

    // MARK: - The controls stay legible

    /// The labels on top keep their floors (titles 4.5 : 1, the quiet tabs
    /// 3 : 1, everything 4.5 : 1 with Increase Contrast) over the densest
    /// softened text that can pass behind them, in Light and Dark, on
    /// Solid, Glass and Frosted, over every desktop. The halo only helps
    /// further and is not counted.
    func testTheControlsStayLegibleOverSoftenedContent() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for surface in PanelSurfaceStyle.allCases {
                for contrast in [false, true] {
                    var design = AtticDesignContext(mode: mode)
                    design.surface = surface
                    design.increaseContrast = contrast
                    let tokens = design.tokens
                    let model = tokens.panel
                    let configuration = AtticControlBackdrop.configuration(design: design, cornerRadius: 8,
                                                                           location: AtticSurfaceModel.contentTop)
                    let passing = tokens.ink(.heading)
                    for desktop in model.desktops {
                        let surfaceColour = model.composite(desktop, at: AtticSurfaceModel.contentTop)
                        let behind = passing.withAlpha(passing.alpha * AtticEdgeBlur.blurredTextCoverage).over(surfaceColour)
                        let background = configuration.veil.over(behind)
                        for ink in [AtticInk.heading, .helper] {
                            let ratio = tokens.ink(ink).contrast(on: background)
                            XCTAssertGreaterThanOrEqual(ratio, model.floor(for: ink),
                                                        "\(mode) \(surface) contrast \(contrast) \(desktop) \(ink): \(ratio)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func backdrops(in view: NSView) -> [AtticControlBackdropView] {
        if let backdrop = view as? AtticControlBackdropView { return [backdrop] }
        return view.subviews.flatMap { backdrops(in: $0) }
    }
}
