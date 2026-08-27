import Combine
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
final class OpticalEnvironmentMonitor: ObservableObject {
    @Published private(set) var snapshot: OpticalEnvironmentSnapshot

    private let snapshotProvider: () -> OpticalEnvironmentSnapshot
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    init(
        snapshotProvider: @escaping () -> OpticalEnvironmentSnapshot = {
            OpticalEnvironmentSnapshot.current()
        }
    ) {
        self.snapshotProvider = snapshotProvider
        snapshot = snapshotProvider()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: ProcessInfo.powerStateDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        refresh()
    }

    func stop() {
        cancellables.removeAll()
        isStarted = false
    }

    func refresh() {
        snapshot = snapshotProvider()
    }
}
