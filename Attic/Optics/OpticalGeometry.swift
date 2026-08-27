import CoreGraphics
import Foundation

struct OpticalCaptureRegion: Equatable, Sendable {
    let sourceRect: CGRect
    let panelRectInCapturePoints: CGRect
    let outputPixelWidth: Int
    let outputPixelHeight: Int
    let overscanPoints: CGFloat
    let backingScale: Double
    let captureScale: Double
}

enum ScreenCaptureRegionMapper {
    private static let safetyMarginPixels = 4.0

    static func makeRegion(
        panelFrame: CGRect,
        displayFrame: CGRect,
        backingScale: Double,
        workload: OpticalWorkloadProfile,
        frostRadiusPixels: Double
    ) -> OpticalCaptureRegion {
        guard let result = makeRegionIfPossible(
            panelFrame: panelFrame,
            displayFrame: displayFrame,
            backingScale: backingScale,
            workload: workload,
            frostRadiusPixels: frostRadiusPixels
        ) else {
            preconditionFailure("Invalid optical capture geometry")
        }
        return result
    }

    static func makeRegionIfPossible(
        panelFrame: CGRect,
        displayFrame: CGRect,
        backingScale: Double,
        workload: OpticalWorkloadProfile,
        frostRadiusPixels: Double
    ) -> OpticalCaptureRegion? {
        guard workload.allowsLiveOptics,
              backingScale.isFinite,
              backingScale > 0,
              workload.captureScale.isFinite,
              workload.captureScale > 0,
              isFinite(panelFrame),
              isFinite(displayFrame),
              panelFrame.width > 0,
              panelFrame.height > 0,
              displayFrame.width > 0,
              displayFrame.height > 0 else {
            return nil
        }

        let frost = frostRadiusPixels.isFinite ? max(0, frostRadiusPixels) : 0
        let overscanPixels = workload.maximumDisplacementPixels
            + frost
            + safetyMarginPixels
        let overscanPoints = CGFloat(overscanPixels / backingScale)
        let expanded = panelFrame.insetBy(dx: -overscanPoints, dy: -overscanPoints)
        let clipped = expanded.intersection(displayFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        // AppKit global coordinates use a bottom-left origin. ScreenCaptureKit's
        // display-local source rectangle uses a top-left origin.
        let sourceRect = CGRect(
            x: clipped.minX - displayFrame.minX,
            y: displayFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        let panelRectInCapturePoints = CGRect(
            x: panelFrame.minX - clipped.minX,
            y: clipped.maxY - panelFrame.maxY,
            width: panelFrame.width,
            height: panelFrame.height
        )
        let outputScale = backingScale * workload.captureScale
        let outputPixelWidth = max(2, Int(ceil(Double(clipped.width) * outputScale)))
        let outputPixelHeight = max(2, Int(ceil(Double(clipped.height) * outputScale)))

        return OpticalCaptureRegion(
            sourceRect: sourceRect,
            panelRectInCapturePoints: panelRectInCapturePoints,
            outputPixelWidth: outputPixelWidth,
            outputPixelHeight: outputPixelHeight,
            overscanPoints: overscanPoints,
            backingScale: backingScale,
            captureScale: workload.captureScale
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}

struct OpticalCaptureConfiguration: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let region: OpticalCaptureRegion
    let workload: OpticalWorkloadProfile
    let generation: Int

    var maximumFramesPerSecond: Int { workload.maximumFramesPerSecond }
    var queueDepth: Int { workload.queueDepth }
    var outputPixelWidth: Int { region.outputPixelWidth }
    var outputPixelHeight: Int { region.outputPixelHeight }

    /// Stable within and across processes; generation is deliberately excluded
    /// so lifecycle code can distinguish a new run from a changed workload.
    var configurationFingerprint: Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: UInt64) {
            hash ^= value
            hash &*= 1_099_511_628_211
        }

        mix(UInt64(displayID))
        mix(Double(region.sourceRect.minX).bitPattern)
        mix(Double(region.sourceRect.minY).bitPattern)
        mix(Double(region.sourceRect.width).bitPattern)
        mix(Double(region.sourceRect.height).bitPattern)
        mix(UInt64(truncatingIfNeeded: region.outputPixelWidth))
        mix(UInt64(truncatingIfNeeded: region.outputPixelHeight))
        mix(Double(workload.captureScale).bitPattern)
        mix(UInt64(truncatingIfNeeded: workload.maximumFramesPerSecond))
        mix(UInt64(truncatingIfNeeded: workload.queueDepth))
        mix(UInt64(truncatingIfNeeded: workload.blurSampleCount))
        mix(UInt64(truncatingIfNeeded: workload.edgeEvaluationCount))
        return Int(truncatingIfNeeded: hash)
    }
}
