import Combine
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service: SMAppService
    private let readStatus: @Sendable () -> SMAppService.Status
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(readStatus: (@Sendable () -> SMAppService.Status)? = nil) {
        self.service = .mainApp
        // Resolve the worker's service where it is used; never transfer the
        // main actor's non-Sendable SMAppService into the status closure.
        self.readStatus = readStatus ?? { SMAppService.mainApp.status }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        refreshGeneration &+= 1
        if refreshTask == nil { beginRefresh() }
    }

    private func beginRefresh() {
        let generation = refreshGeneration
        let read = readStatus
        refreshTask = Task { [weak self] in
            // SMAppService.status waits synchronously for the login-item
            // daemon. Settings stays built while hidden and refreshes on
            // activation, so doing this on main stalls the first click.
            let status = await Task.detached(priority: .utility) { read() }.value
            guard let self else { return }
            self.refreshTask = nil
            guard generation == self.refreshGeneration else {
                // Coalesce notifications, but do not publish a status read
                // before a newer refresh or a register/unregister attempt.
                self.beginRefresh()
                return
            }
            self.isEnabled = status == .enabled
            self.requiresApproval = status == .requiresApproval
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
