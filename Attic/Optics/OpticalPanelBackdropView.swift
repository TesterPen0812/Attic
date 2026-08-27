import AppKit
import Combine
import QuartzCore

@MainActor
final class OpticalPanelBackdropView: NSView {
    private let materialView = NSVisualEffectView()
    private let opaqueView = NSView()
    private let maskLayer = CAShapeLayer()
    private let permissionController: OpticalPermissionController
    private let environmentMonitor: OpticalEnvironmentMonitor
    private let metrics = OpticalPerformanceMetrics(windowCapacity: 120)
    private lazy var captureSession: OpticalCaptureSessionProtocol = OpticalCaptureSession(metrics: metrics)
    private lazy var callbacks = OpticalPanelCaptureCallbacks(owner: self)

    private var renderer: OpticalMetalRenderer?
    private var cancellables: Set<AnyCancellable> = []
    private var captureLifecycle = OpticalCaptureLifecycle()
    private var adaptiveController = OpticalAdaptiveQualityController()
    private var captureOperationTask: Task<Void, Never>?
    private var interactionResetWorkItem: DispatchWorkItem?

    private var controls: OpticalGlassControls
    private var selectedPreset: OpticalPerformancePreset
    private var effectivePreset: OpticalPerformancePreset = .off
    private var cornerRadius: CGFloat
    private weak var targetScreen: NSScreen?
    private var targetPanelFrame: CGRect = .zero
    private var activeRegion: OpticalCaptureRegion?
    private var activeProfile: OpticalGlassProfile?
    private var activeWorkload: OpticalWorkloadProfile?
    private var isPanelVisible = false
    private var captureAvailable = true
    private var metalRuntimeAvailable = true
    private var interactionMultiplier = 1.0
    private var adaptiveFrameCounter = 0

    init(
        controls: OpticalGlassControls,
        preset: OpticalPerformancePreset,
        cornerRadius: CGFloat,
        permissionController: OpticalPermissionController,
        environmentMonitor: OpticalEnvironmentMonitor
    ) {
        self.controls = controls
        selectedPreset = preset
        self.cornerRadius = cornerRadius
        self.permissionController = permissionController
        self.environmentMonitor = environmentMonitor
        super.init(frame: .zero)
        configureViews()
        bindEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        opaqueView.frame = bounds
        renderer?.view.frame = bounds
        updateMask()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackAppearance()
    }

    func update(
        controls: OpticalGlassControls,
        preset: OpticalPerformancePreset,
        cornerRadius: CGFloat,
        screen: NSScreen?,
        panelFrame: CGRect
    ) {
        let geometryChanged = targetScreen !== screen
            || targetPanelFrame != panelFrame
            || self.cornerRadius != cornerRadius
        self.controls = controls
        selectedPreset = preset
        self.cornerRadius = cornerRadius
        targetScreen = screen
        targetPanelFrame = panelFrame
        if geometryChanged {
            captureAvailable = true
        }
        updateMask()
        reconcile()
    }

    func setVisible(_ visible: Bool) {
        guard isPanelVisible != visible else {
            if visible { reconcile() }
            return
        }
        isPanelVisible = visible
        if visible {
            captureAvailable = true
        }
        reconcile()
    }

    func stop() {
        isPanelVisible = false
        captureOperationTask?.cancel()
        captureOperationTask = nil
        interactionResetWorkItem?.cancel()
        interactionResetWorkItem = nil
        stopLiveResources()
        cancellables.removeAll()
    }

    func respondToInteraction() {
        guard isPanelVisible,
              let activeProfile,
              renderer != nil else {
            return
        }
        interactionResetWorkItem?.cancel()
        interactionMultiplier = activeProfile.interactionBoost
        refreshRenderStateOnly()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interactionMultiplier = 1
                self.refreshRenderStateOnly()
            }
        }
        interactionResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func configureViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.mask = maskLayer

        opaqueView.wantsLayer = true
        opaqueView.autoresizingMask = [.width, .height]
        addSubview(opaqueView)

        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.isEmphasized = false
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)

        updateFallbackAppearance()
        applyBackdropMode(.material(reason: .permissionNotRequested))
    }

    private func bindEnvironment() {
        permissionController.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &cancellables)

        environmentMonitor.$snapshot
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &cancellables)
    }

    private func reconcile() {
        updateFallbackAppearance()
        guard isPanelVisible else {
            effectivePreset = .off
            applyBackdropMode(
                NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                    ? .opaque(reason: .reduceTransparency)
                    : .material(reason: .performanceOff)
            )
            stopLiveResources()
            return
        }

        effectivePreset = resolveEffectivePreset()
        let workload = OpticalWorkloadProfile.workload(for: effectivePreset)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        var mode = OpticalBackdropMode.resolve(
            preset: effectivePreset,
            permission: permissionController.state,
            metalAvailable: metalRuntimeAvailable && OpticalMetalRenderer.isSupported,
            captureAvailable: captureAvailable,
            reduceTransparency: reduceTransparency
        )

        guard mode == .live,
              workload.allowsLiveOptics,
              let screen = targetScreen,
              let displayID = displayID(for: screen) else {
            applyBackdropMode(mode)
            stopLiveResources()
            return
        }

        let profile = OpticalGlassProfile.resolve(
            controls: controls,
            workload: workload,
            windowActivity: .inactive
        )
        guard let region = ScreenCaptureRegionMapper.makeRegionIfPossible(
            panelFrame: targetPanelFrame,
            displayFrame: screen.frame,
            backingScale: screen.backingScaleFactor,
            workload: workload,
            frostRadiusPixels: profile.frostRadius
        ) else {
            captureAvailable = false
            mode = .material(reason: .captureUnavailable)
            applyBackdropMode(mode)
            stopLiveResources()
            return
        }
        guard ensureRenderer() != nil else {
            metalRuntimeAvailable = false
            mode = .material(reason: .metalUnavailable)
            applyBackdropMode(mode)
            stopLiveResources()
            return
        }

        activeRegion = region
        activeProfile = profile
        activeWorkload = workload
        applyBackdropMode(.live)

        let provisional = OpticalCaptureConfiguration(
            displayID: displayID,
            region: region,
            workload: workload,
            generation: 0
        )
        let command = captureLifecycle.reconcile(
            shouldRun: true,
            configurationFingerprint: provisional.configurationFingerprint
        )
        switch command {
        case .none:
            refreshRenderStateOnly()
        case let .start(generation), let .restart(_, generation):
            startCapture(
                OpticalCaptureConfiguration(
                    displayID: displayID,
                    region: region,
                    workload: workload,
                    generation: generation
                )
            )
        case .stop:
            stopLiveResources()
        }
    }

    private func resolveEffectivePreset() -> OpticalPerformancePreset {
        guard selectedPreset == .adaptive else { return selectedPreset }
        let environment = environmentMonitor.snapshot
        let performance = metrics.snapshot()
        let hasPerformance = performance.capturedFrameCount > 0
            || performance.renderedFrameCount > 0
            || performance.droppedFrameCount > 0
        return adaptiveController.evaluate(
            inputs: OpticalAdaptiveInputs(
                isPanelVisible: isPanelVisible,
                isLowPowerModeEnabled: environment.isLowPowerModeEnabled,
                thermalState: environment.thermalState,
                isOnBatteryPower: environment.isOnBatteryPower,
                displayScale: Double(targetScreen?.backingScaleFactor ?? 1),
                performance: hasPerformance ? performance : nil
            ),
            now: CACurrentMediaTime()
        )
    }

    private func ensureRenderer() -> OpticalMetalRenderer? {
        if let renderer { return renderer }
        guard metalRuntimeAvailable,
              let renderer = OpticalMetalRenderer(metrics: metrics) else {
            return nil
        }
        renderer.view.frame = bounds
        renderer.view.autoresizingMask = [.width, .height]
        addSubview(renderer.view, positioned: .above, relativeTo: materialView)
        self.renderer = renderer
        return renderer
    }

    private func startCapture(_ configuration: OpticalCaptureConfiguration) {
        captureOperationTask?.cancel()
        let callbacks = callbacks
        captureOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await captureSession.start(
                    configuration: configuration,
                    frameHandler: { frame in callbacks.receive(frame) },
                    failureHandler: { generation, message in
                        callbacks.fail(generation: generation, message: message)
                    }
                )
            } catch is CancellationError {
                await captureSession.stop()
            } catch {
                handleCaptureFailure(
                    generation: configuration.generation,
                    message: error.localizedDescription
                )
            }
        }
    }

    fileprivate func receive(_ frame: OpticalCaptureFrame) {
        guard isPanelVisible,
              captureLifecycle.acceptsFrame(generation: frame.generation),
              let renderer,
              let state = makeRenderState() else {
            metrics.recordDroppedFrame()
            return
        }
        renderer.submit(frame: frame, state: state)

        guard selectedPreset == .adaptive else { return }
        adaptiveFrameCounter += 1
        let evaluationInterval = max(15, activeWorkload?.maximumFramesPerSecond ?? 30)
        guard adaptiveFrameCounter >= evaluationInterval else { return }
        adaptiveFrameCounter = 0
        let previous = effectivePreset
        let resolved = resolveEffectivePreset()
        if resolved != previous {
            effectivePreset = resolved
            reconcile()
        }
    }

    fileprivate func handleCaptureFailure(generation: Int, message: String) {
        guard isPanelVisible,
              captureLifecycle.acceptsFailure(generation: generation) else {
            return
        }
        captureAvailable = false
        NSLog("Attic optical capture unavailable: %@", message)
        applyBackdropMode(.material(reason: .captureUnavailable))
        stopLiveResources()
    }

    private func refreshRenderStateOnly() {
        // The next ScreenCaptureKit frame uses the new state. Rendering stale
        // captured pixels merely to animate a setting is deliberately avoided.
    }

    private func makeRenderState() -> OpticalMetalRenderState? {
        guard let activeRegion,
              let activeProfile,
              let activeWorkload,
              let screen = targetScreen else {
            return nil
        }
        return OpticalMetalRenderState(
            profile: activeProfile,
            workload: activeWorkload,
            region: activeRegion,
            panelSizePoints: targetPanelFrame.size,
            cornerRadiusPoints: cornerRadius,
            backingScale: screen.backingScaleFactor,
            tintColor: NSColor.controlAccentColor.opticalSIMDColor(),
            surfaceColor: NSColor.windowBackgroundColor.opticalSIMDColor(),
            interactionMultiplier: interactionMultiplier
        )
    }

    private func applyBackdropMode(_ mode: OpticalBackdropMode) {
        switch mode {
        case .live, .material:
            opaqueView.isHidden = true
            materialView.isHidden = false
        case .opaque:
            opaqueView.isHidden = false
            materialView.isHidden = true
        }
    }

    private func stopLiveResources() {
        captureOperationTask?.cancel()
        captureOperationTask = nil
        _ = captureLifecycle.reconcile(
            shouldRun: false,
            configurationFingerprint: 0
        )
        callbacks.deactivate()
        Task { @MainActor [captureSession] in
            await captureSession.stop()
        }
        renderer?.releaseResources()
        renderer?.view.removeFromSuperview()
        renderer = nil
        activeRegion = nil
        activeProfile = nil
        activeWorkload = nil
        interactionMultiplier = 1
        adaptiveFrameCounter = 0
    }

    private func updateMask() {
        maskLayer.frame = bounds
        maskLayer.path = SquircleGeometry.path(
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )
    }

    private func updateFallbackAppearance() {
        opaqueView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        materialView.alphaValue = 1
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

private final class OpticalPanelCaptureCallbacks: @unchecked Sendable {
    private weak var owner: OpticalPanelBackdropView?

    init(owner: OpticalPanelBackdropView) {
        self.owner = owner
    }

    func receive(_ frame: OpticalCaptureFrame) {
        Task { @MainActor [weak self] in
            self?.owner?.receive(frame)
        }
    }

    func fail(generation: Int, message: String) {
        Task { @MainActor [weak self] in
            self?.owner?.handleCaptureFailure(
                generation: generation,
                message: message
            )
        }
    }

    func deactivate() {
        // The owner's capture lifecycle rejects stale generations. Keeping the
        // weak reference allows a later authorized reveal to reuse callbacks.
    }
}
