import Combine
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdating = false

    private let readStatus: @Sendable () -> SMAppService.Status
    private let changeRegistration: @Sendable (Bool) throws -> Void
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var changeTask: Task<Void, Never>?
    private var requestedEnabled: Bool?

    init(readStatus: (@Sendable () -> SMAppService.Status)? = nil,
         changeRegistration: (@Sendable (Bool) throws -> Void)? = nil) {
        // Resolve the worker's service where it is used; never transfer the
        // main actor's non-Sendable SMAppService into the status closure.
        self.readStatus = readStatus ?? { SMAppService.mainApp.status }
        self.changeRegistration = changeRegistration ?? { enabled in
            let service = SMAppService.mainApp
            if enabled { try service.register() } else { try service.unregister() }
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        requestedEnabled = enabled
        refreshGeneration &+= 1
        if changeTask == nil { beginChange() }
    }

    /// Serialise registration requests, then publish only the confirmed
    /// system status. Never transfer SMAppService across an actor boundary.
    private func beginChange() {
        guard let enabled = requestedEnabled else { return }
        requestedEnabled = nil
        isUpdating = true
        let change = changeRegistration
        changeTask = Task { [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do { try change(enabled); return nil }
                catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.changeTask = nil
            if self.requestedEnabled != nil { self.beginChange(); return }
            self.isUpdating = false
            self.errorMessage = failure
            self.refresh()
        }
    }

    func refresh() {
        refreshGeneration &+= 1
        guard changeTask == nil else { return }
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
            guard self.changeTask == nil else { return }
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
