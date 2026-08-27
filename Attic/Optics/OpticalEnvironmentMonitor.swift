import Combine
import CoreFoundation
import Foundation
import IOKit.ps

struct OpticalEnvironmentSnapshot: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState
    let isOnBatteryPower: Bool

    static func current(processInfo: ProcessInfo = .processInfo) -> OpticalEnvironmentSnapshot {
        OpticalEnvironmentSnapshot(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState,
            isOnBatteryPower: currentPowerSourceIsBattery()
        )
    }

    private static func currentPowerSourceIsBattery() -> Bool {
        guard let powerSnapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSource = IOPSGetProvidingPowerSourceType(powerSnapshot)?.takeUnretainedValue() else {
            return false
        }
        return (powerSource as String) == (kIOPSBatteryPowerValue as String)
    }
}

@MainActor
protocol OpticalPowerSourceObserving: AnyObject {
    func start(onChange: @escaping () -> Void)
    func stop()
}

@MainActor
final class IOKitOpticalPowerSourceObserver: OpticalPowerSourceObserving {
    private var runLoopSource: CFRunLoopSource?
    private var changeHandler: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        stop()
        changeHandler = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<IOKitOpticalPowerSourceObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor [weak observer] in
                observer?.notifyChange()
            }
        }, context) else {
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            source,
            CFRunLoopMode.commonModes
        )
    }

    func stop() {
        guard let runLoopSource else {
            changeHandler = nil
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            runLoopSource,
            CFRunLoopMode.commonModes
        )
        CFRunLoopSourceInvalidate(runLoopSource)
        self.runLoopSource = nil
        changeHandler = nil
    }

    private func notifyChange() {
        changeHandler?()
    }
}

@MainActor
final class OpticalEnvironmentMonitor: ObservableObject {
    @Published private(set) var snapshot: OpticalEnvironmentSnapshot

    private let snapshotProvider: () -> OpticalEnvironmentSnapshot
    private let powerSourceObserver: OpticalPowerSourceObserving
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    init(
        snapshotProvider: @escaping () -> OpticalEnvironmentSnapshot = {
            OpticalEnvironmentSnapshot.current()
        },
        powerSourceObserver: OpticalPowerSourceObserving? = nil
    ) {
        self.snapshotProvider = snapshotProvider
        self.powerSourceObserver = powerSourceObserver ?? IOKitOpticalPowerSourceObserver()
        snapshot = snapshotProvider()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .merge(with: NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        powerSourceObserver.start { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        powerSourceObserver.stop()
        cancellables.removeAll()
        isStarted = false
    }

    func refresh() {
        snapshot = snapshotProvider()
    }
}
