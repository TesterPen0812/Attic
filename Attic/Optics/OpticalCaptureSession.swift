import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct OpticalCaptureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let generation: Int
    let presentationTime: CMTime
    let captureLatencyMilliseconds: Double
}

enum OpticalCaptureSessionError: LocalizedError {
    case displayUnavailable(CGDirectDisplayID)
    case notRunning
    case displayChangeRequiresRestart

    var errorDescription: String? {
        switch self {
        case let .displayUnavailable(displayID):
            return "ScreenCaptureKit could not find display \(displayID)."
        case .notRunning:
            return "The optical capture stream is not running."
        case .displayChangeRequiresRestart:
            return "Changing displays requires a fresh optical capture stream."
        }
    }
}

@MainActor
protocol OpticalCaptureSessionProtocol: AnyObject {
    func start(
        configuration: OpticalCaptureConfiguration,
        frameHandler: @escaping @Sendable (OpticalCaptureFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) async throws

    func update(configuration: OpticalCaptureConfiguration) async throws
    func stop() async
}

@MainActor
final class OpticalCaptureSession: NSObject, OpticalCaptureSessionProtocol {
    private nonisolated let relay: OpticalCaptureFrameRelay
    private let outputQueue = DispatchQueue(
        label: "com.emanueledipietro.Attic.optical-capture-output",
        qos: .userInteractive
    )
    private var stream: SCStream?
    private var activeConfiguration: OpticalCaptureConfiguration?

    init(metrics: OpticalPerformanceMetrics) {
        relay = OpticalCaptureFrameRelay(metrics: metrics)
        super.init()
    }

    func start(
        configuration: OpticalCaptureConfiguration,
        frameHandler: @escaping @Sendable (OpticalCaptureFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        await stop()
        relay.configure(
            generation: configuration.generation,
            frameHandler: frameHandler,
            failureHandler: failureHandler
        )

        do {
            let content = try await loadShareableContent()
            guard let display = content.displays.first(where: {
                $0.displayID == configuration.displayID
            }) else {
                throw OpticalCaptureSessionError.displayUnavailable(configuration.displayID)
            }
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let ownApplications = content.applications.filter {
                $0.processID == currentPID
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let streamConfiguration = makeStreamConfiguration(from: configuration)
            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: self
            )
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
            self.stream = stream
            activeConfiguration = configuration
            try await startCapture(stream)
        } catch {
            await releaseFailedStart()
            throw error
        }
    }

    func update(configuration: OpticalCaptureConfiguration) async throws {
        guard let stream, let activeConfiguration else {
            throw OpticalCaptureSessionError.notRunning
        }
        guard activeConfiguration.displayID == configuration.displayID else {
            throw OpticalCaptureSessionError.displayChangeRequiresRestart
        }

        try await update(
            stream,
            configuration: makeStreamConfiguration(from: configuration)
        )
        self.activeConfiguration = configuration
        relay.updateGeneration(configuration.generation)
    }

    func stop() async {
        relay.deactivate()
        guard let stream else {
            activeConfiguration = nil
            return
        }
        self.stream = nil
        activeConfiguration = nil
        try? stream.removeStreamOutput(self, type: .screen)
        await stopCapture(stream)
    }

    private func releaseFailedStart() async {
        relay.deactivate()
        guard let stream else {
            activeConfiguration = nil
            return
        }
        self.stream = nil
        activeConfiguration = nil
        try? stream.removeStreamOutput(self, type: .screen)
        await stopCapture(stream)
    }

    private func makeStreamConfiguration(
        from configuration: OpticalCaptureConfiguration
    ) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = configuration.region.sourceRect
        streamConfiguration.width = configuration.outputPixelWidth
        streamConfiguration.height = configuration.outputPixelHeight
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, configuration.maximumFramesPerSecond))
        )
        streamConfiguration.queueDepth = min(max(1, configuration.queueDepth), 8)
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = false
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.streamName = "Attic Optical Backdrop"
        streamConfiguration.shouldBeOpaque = false
        return streamConfiguration
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SCShareableContent, Error>) in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(
                        throwing: OpticalCaptureSessionError.displayUnavailable(0)
                    )
                }
            }
        }
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func update(
        _ stream: SCStream,
        configuration: SCStreamConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stream.updateConfiguration(configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func stopCapture(_ stream: SCStream) async {
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }
    }
}

extension OpticalCaptureSession: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        relay.handle(sampleBuffer)
    }
}

extension OpticalCaptureSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        relay.fail(error.localizedDescription)
    }
}

private final class OpticalCaptureFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let metrics: OpticalPerformanceMetrics
    private var generation: Int?
    private var frameHandler: (@Sendable (OpticalCaptureFrame) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?

    init(metrics: OpticalPerformanceMetrics) {
        self.metrics = metrics
    }

    func configure(
        generation: Int,
        frameHandler: @escaping @Sendable (OpticalCaptureFrame) -> Void,
        failureHandler: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        self.generation = generation
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
        lock.unlock()
    }

    func updateGeneration(_ generation: Int) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        generation = nil
        frameHandler = nil
        failureHandler = nil
        lock.unlock()
    }

    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            metrics.recordIncompleteFrame()
            return
        }

        lock.lock()
        let activeGeneration = generation
        let activeHandler = frameHandler
        lock.unlock()
        guard let activeGeneration, let activeHandler else {
            metrics.recordDroppedFrame()
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(CMTimeSubtract(hostTime, presentationTime))
        let latencyMilliseconds = seconds.isFinite ? max(0, seconds * 1_000) : 0
        metrics.recordCapturedFrame(latencyMilliseconds: latencyMilliseconds)
        activeHandler(
            OpticalCaptureFrame(
                pixelBuffer: pixelBuffer,
                generation: activeGeneration,
                presentationTime: presentationTime,
                captureLatencyMilliseconds: latencyMilliseconds
            )
        )
    }

    func fail(_ message: String) {
        lock.lock()
        let handler = failureHandler
        lock.unlock()
        handler?(message)
    }
}
