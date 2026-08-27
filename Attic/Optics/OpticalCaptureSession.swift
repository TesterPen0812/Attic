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
        failureHandler: @escaping @Sendable (Int, String) -> Void
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
    private var operationGate = OpticalCaptureOperationGate()

    init(metrics: OpticalPerformanceMetrics) {
        relay = OpticalCaptureFrameRelay(metrics: metrics)
        super.init()
    }

    func start(
        configuration: OpticalCaptureConfiguration,
        frameHandler: @escaping @Sendable (OpticalCaptureFrame) -> Void,
        failureHandler: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        let operation = operationGate.begin()
        await stopCurrentStream()
        try ensureActive(operation)

        var candidateStream: SCStream?
        do {
            let content = try await loadShareableContent()
            try ensureActive(operation)
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
            let candidate = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: self
            )
            candidateStream = candidate
            try candidate.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
            try ensureActive(operation)

            stream = candidate
            activeConfiguration = configuration
            relay.configure(
                stream: candidate,
                generation: configuration.generation,
                frameHandler: frameHandler,
                failureHandler: failureHandler
            )
            try await startCapture(candidate)
            try ensureActive(operation)
        } catch {
            if let candidateStream {
                await release(candidateStream)
            }
            throw error
        }
    }

    func update(configuration: OpticalCaptureConfiguration) async throws {
        guard let stream, let activeConfiguration,
              let operation = operationGate.activeOperation else {
            throw OpticalCaptureSessionError.notRunning
        }
        guard activeConfiguration.displayID == configuration.displayID else {
            throw OpticalCaptureSessionError.displayChangeRequiresRestart
        }

        try await update(
            stream,
            configuration: makeStreamConfiguration(from: configuration)
        )
        try ensureActive(operation)
        guard self.stream === stream else {
            throw CancellationError()
        }
        self.activeConfiguration = configuration
        relay.updateGeneration(configuration.generation)
    }

    func stop() async {
        operationGate.stop()
        await stopCurrentStream()
    }

    private func ensureActive(_ operation: Int) throws {
        guard operationGate.accepts(operation), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func stopCurrentStream() async {
        guard let stream else {
            activeConfiguration = nil
            relay.deactivate()
            return
        }
        self.stream = nil
        activeConfiguration = nil
        relay.deactivate(stream: stream)
        try? stream.removeStreamOutput(self, type: .screen)
        await stopCapture(stream)
    }

    private func release(_ candidate: SCStream) async {
        relay.deactivate(stream: candidate)
        if stream === candidate {
            stream = nil
            activeConfiguration = nil
        }
        try? candidate.removeStreamOutput(self, type: .screen)
        await stopCapture(candidate)
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
        streamConfiguration.queueDepth = configuration.screenCaptureQueueDepth
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
        relay.handle(stream: stream, sampleBuffer: sampleBuffer)
    }
}

extension OpticalCaptureSession: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        relay.fail(stream: stream, message: error.localizedDescription)
    }
}

private final class OpticalCaptureFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let metrics: OpticalPerformanceMetrics
    private var streamIdentifier: ObjectIdentifier?
    private var generation: Int?
    private var frameHandler: (@Sendable (OpticalCaptureFrame) -> Void)?
    private var failureHandler: (@Sendable (Int, String) -> Void)?

    init(metrics: OpticalPerformanceMetrics) {
        self.metrics = metrics
    }

    func configure(
        stream: SCStream,
        generation: Int,
        frameHandler: @escaping @Sendable (OpticalCaptureFrame) -> Void,
        failureHandler: @escaping @Sendable (Int, String) -> Void
    ) {
        lock.lock()
        streamIdentifier = ObjectIdentifier(stream)
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
        streamIdentifier = nil
        generation = nil
        frameHandler = nil
        failureHandler = nil
        lock.unlock()
    }

    func deactivate(stream: SCStream) {
        lock.lock()
        if streamIdentifier == ObjectIdentifier(stream) {
            streamIdentifier = nil
            generation = nil
            frameHandler = nil
            failureHandler = nil
        }
        lock.unlock()
    }

    func handle(stream: SCStream, sampleBuffer: CMSampleBuffer) {
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
        let isActiveStream = streamIdentifier == ObjectIdentifier(stream)
        let activeGeneration = generation
        let activeHandler = frameHandler
        lock.unlock()
        guard isActiveStream, let activeGeneration, let activeHandler else {
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

    func fail(stream: SCStream, message: String) {
        lock.lock()
        let isActiveStream = streamIdentifier == ObjectIdentifier(stream)
        let activeGeneration = generation
        let handler = failureHandler
        lock.unlock()
        guard isActiveStream, let activeGeneration else { return }
        handler?(activeGeneration, message)
    }
}
