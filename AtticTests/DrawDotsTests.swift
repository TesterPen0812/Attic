import AppKit
import XCTest
@testable import Attic

/// The board's dots (Planning.md, Draw › the canvas page: "dots by default"):
/// the working file's 16 pt grid of 1.7 pt dots at rgba(0,0,0,0.13) on its
/// solid panel. On glass they read as those dots read there; on screen each
/// dot is one size at every zoom, and the grid thins rather than vanishes.
@MainActor
final class DrawDotsTests: XCTestCase {
    private let zooms: [CGFloat] = [0.1, 0.25, 0.5, 1, 4]

    // MARK: Size

    func testEachDotIsTheSameSizeOnScreenAtEveryZoom() throws {
        for zoom in zooms {
            let grid = try XCTUnwrap(DrawDots.grid(zoom: zoom), "no dots at \(zoom * 100) %")
            let image = DrawDots.tileImage(step: grid.step, diameter: DrawDots.dotDiameter(zoom: zoom),
                                           ink: DrawDots.ink(design: nil, dark: false))
            let measured = Self.measuredDiameter(image, inkAlpha: DrawDots.alpha)
            XCTAssertEqual(measured, 1.7, accuracy: 0.08, "dot diameter at \(zoom * 100) %")
        }
    }

    // MARK: Spacing

    func testSpacingFollowsTheZoomAndThinsByHalvesNeverVanishing() throws {
        var zoom = DrawViewport.minZoom
        while zoom <= DrawViewport.maxZoom + 0.0001 {
            let grid = try XCTUnwrap(DrawDots.grid(zoom: zoom), "no dots at \(zoom * 100) %")
            XCTAssertGreaterThanOrEqual(grid.step, DrawDots.minimumStep - 0.001, "crowded at \(zoom * 100) %")
            XCTAssertEqual(grid.every & (grid.every - 1), 0, "every \(grid.every): not a power of two")
            XCTAssertEqual(grid.step, DrawDots.spacing * zoom * CGFloat(grid.every), accuracy: 0.0001)
            if grid.every > 1 {
                XCTAssertLessThan(grid.step / 2, DrawDots.minimumStep, "thinned more than needed at \(zoom * 100) %")
            }
            zoom += 0.01
        }
        XCTAssertEqual(DrawDots.grid(zoom: 1)?.every, 1)
        XCTAssertEqual(DrawDots.grid(zoom: 0.5)?.every, 1)
        XCTAssertEqual(DrawDots.grid(zoom: 0.25)?.every, 2)
        XCTAssertEqual(DrawDots.grid(zoom: 0.125)?.every, 4)
        XCTAssertEqual(DrawDots.grid(zoom: 0.1)?.every, 8)
    }

    /// The dots left after thinning are grid points: the grid moves with the
    /// board, it only loses dots.
    func testThinnedDotsStayOnTheGridAsTheBoardPans() throws {
        for zoom in zooms {
            let grid = try XCTUnwrap(DrawDots.grid(zoom: zoom))
            let base = DrawDots.spacing * zoom
            for viewport in [DrawViewport(x: 0, y: 0, zoom: zoom), DrawViewport(x: 37.5, y: -213.25, zoom: zoom),
                             DrawViewport(x: -1003, y: 611, zoom: zoom)] {
                var dots = DrawDots()
                let layer = CALayer()
                layer.anchorPoint = .zero
                let size = CGSize(width: 320, height: 460)
                dots.place(in: layer, viewport: viewport, size: size, dark: false)
                let tile = layer.bounds.width - size.width
                XCTAssertEqual(tile / 2, grid.step, accuracy: 0.13)
                // A dot is in the middle of each tile; grid points sit half a
                // grid step in from the world origin.
                let dotX = layer.position.x + grid.step / 2
                let worldX = (dotX - viewport.x) / base - 0.5
                XCTAssertEqual(worldX, worldX.rounded(), accuracy: 0.02, "x off the grid at \(zoom * 100) %")
                XCTAssertEqual(Int(worldX.rounded()) % grid.every, 0, "x not a kept grid point at \(zoom * 100) %")
                let dotY = layer.position.y + grid.step / 2
                let worldY = (size.height - viewport.y - dotY) / base - 0.5
                XCTAssertEqual(worldY, worldY.rounded(), accuracy: 0.02, "y off the grid at \(zoom * 100) %")
                XCTAssertEqual(Int(worldY.rounded()) % grid.every, 0, "y not a kept grid point at \(zoom * 100) %")
            }
        }
    }

    // MARK: Ink

    func testSolidKeepsTheDrawingsInk() {
        XCTAssertEqual(DrawDots.ink(design: AtticDesignContext(mode: .light, surface: .solid), dark: false), .black(0.13))
        XCTAssertEqual(DrawDots.ink(design: AtticDesignContext(mode: .dark, surface: .solid), dark: true), .white(0.13))
        // Reduce Transparency makes the glass solid, and the dots with it.
        let reduced = AtticDesignContext(mode: .light, surface: .glass, reduceTransparency: true)
        XCTAssertEqual(DrawDots.ink(design: reduced, dark: false), .black(0.13))
    }

    /// On Glass and Frosted the dot is the panel's own ink made see-through,
    /// at the alpha that keeps, over every desktop the tokens judge glass on
    /// (black, mid grey, white), at least the contrast the drawing's dot has
    /// on the solid panel: the least of them is that contrast.
    func testGlassAndFrostedDotsReadAsTheDrawingsDotsReadOnSolid() {
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            for dark in [false, true] {
                let design = AtticDesignContext(mode: dark ? .dark : .light, surface: surface)
                let ink = DrawDots.ink(design: design, dark: dark)
                let tokens = design.tokens
                XCTAssertEqual(ink.withAlpha(1), tokens.ink(.heading).withAlpha(1), "\(design.caption): not the panel's ink")
                var solid = design
                solid.surface = .solid
                let solidPanel = solid.tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
                let drawn = (dark ? AtticRGBA.white(0.13) : .black(0.13)).contrast(on: solidPanel)
                let onGlass = AtticSurfaceModel.Desktop.allCases.map {
                    ink.contrast(on: tokens.panel.composite($0, at: AtticSurfaceModel.contentTop))
                }
                XCTAssertEqual(onGlass.min() ?? 0, drawn, accuracy: 0.005, "\(design.caption): \(onGlass)")
                XCTAssertGreaterThan(ink.alpha, 0.13, "\(design.caption): fainter than the drawing")
                XCTAssertLessThan(ink.alpha, 0.3, "\(design.caption): no longer a quiet texture")
            }
        }
    }

    func testInkFollowsAppearanceAndMaterialLive() {
        let lightGlass = AtticDesignContext(mode: .light, surface: .glass)
        XCTAssertNotEqual(DrawDots.ink(design: lightGlass, dark: false), DrawDots.ink(design: lightGlass, dark: true))
        XCTAssertNotEqual(DrawDots.ink(design: lightGlass, dark: false),
                          DrawDots.ink(design: AtticDesignContext(mode: .light, surface: .solid), dark: false))

        var dots = DrawDots()
        let layer = CALayer()
        let size = CGSize(width: 320, height: 460)
        let viewport = DrawViewport(x: 0, y: 0, zoom: 1)
        dots.design = AtticDesignContext(mode: .light, surface: .solid)
        dots.place(in: layer, viewport: viewport, size: size, dark: false)
        let solidTile = layer.backgroundColor
        XCTAssertEqual(dots.tilesRendered, 1)
        dots.design = lightGlass
        dots.place(in: layer, viewport: viewport, size: size, dark: false)
        XCTAssertEqual(dots.tilesRendered, 2, "a new material draws a new tile")
        XCTAssertFalse(layer.backgroundColor === solidTile)
        dots.place(in: layer, viewport: viewport, size: size, dark: true)
        XCTAssertEqual(dots.tilesRendered, 3, "a new appearance draws a new tile")
        dots.place(in: layer, viewport: viewport, size: size, dark: false)
        XCTAssertEqual(dots.tilesRendered, 3, "a tile seen before comes from the cache")
    }

    // MARK: Panning

    func testPanningNeverRendersATile() {
        for zoom in zooms {
            var dots = DrawDots()
            dots.design = AtticDesignContext(mode: .light, surface: .glass)
            let layer = CALayer()
            let size = CGSize(width: 320, height: 460)
            dots.place(in: layer, viewport: DrawViewport(x: 0, y: 0, zoom: zoom), size: size, dark: false)
            let rendered = dots.tilesRendered
            for i in 1...60 {
                let step = CGFloat(i)
                dots.place(in: layer, viewport: DrawViewport(x: step * 7.3, y: -step * 4.1, zoom: zoom), size: size, dark: false)
            }
            XCTAssertEqual(dots.tilesRendered, rendered, "panning drew at \(zoom * 100) %")
        }
    }

    // MARK: Helpers

    /// The diameter of the dot a tile draws, from its coverage at 8 px a point.
    private static func measuredDiameter(_ image: NSImage, inkAlpha: CGFloat) -> CGFloat {
        let scale = 8
        let side = Int((image.size.width * CGFloat(scale)).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return 0 }
        var alpha = 0.0
        for row in 0..<side {
            for column in 0..<side { alpha += Double(data[row * rep.bytesPerRow + column * 4 + 3]) / 255 }
        }
        let area = alpha / Double(inkAlpha) / Double(scale * scale)
        return CGFloat(2 * (area / .pi).squareRoot())
    }
}
