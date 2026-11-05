import AppKit
import Foundation

@MainActor
final class DailyCleanupService {
    private let store: TaskStore
    /// Removes what has been in Recently Deleted for 30 days. Runs at the
    /// same event-driven moments as the Done-log move, never on a poll.
    private let purgeRecentlyDeleted: (@MainActor (_ now: Date, _ calendar: Calendar) -> Void)?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var timer: Timer?
    private var generation: UUID?
    private(set) var queuedCleanupTask: Task<Void, Never>?
    private var cleanupDirty = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    init(
        store: TaskStore,
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        purgeRecentlyDeleted: (@MainActor (_ now: Date, _ calendar: Calendar) -> Void)? = nil
    ) {
        self.store = store
        self.purgeRecentlyDeleted = purgeRecentlyDeleted
        self.now = now
        self.calendar = calendar
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard generation == nil else { return }
        let generation = UUID()
        self.generation = generation

        let center = NotificationCenter.default
        let refreshNotifications: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
            NSApplication.didBecomeActiveNotification
        ]
        notificationTokens = refreshNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enqueueCleanup(for: generation) }
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enqueueCleanup(for: generation) }
            }
        ]

        cleanupAndReschedule(for: generation)
    }

    func stop() {
        generation = nil
        cleanupDirty = false
        queuedCleanupTask?.cancel()
        queuedCleanupTask = nil
        timer?.invalidate()
        timer = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspaceCenter.removeObserver)
        workspaceTokens.removeAll()
    }

    /// Moves tasks finished before the start of the current local day into
    /// the Done log (nothing is deleted) and returns how many moved, then
    /// removes Recently Deleted items older than 30 days. Both steps are
    /// idempotent, so running at every wake, day change and time-zone change
    /// can neither skip a day (everything older is caught up at once) nor
    /// repeat one (already-moved tasks are not candidates).
    @discardableResult
    func performCleanup(at date: Date? = nil) -> Int {
        let timestamp = date ?? now()
        let activeCalendar = calendar()
        let startOfToday = activeCalendar.startOfDay(for: timestamp)
        let moved = store.moveCompletedToDoneLog(before: startOfToday)
        purgeRecentlyDeleted?(timestamp, activeCalendar)
        return moved
    }

    private func enqueueCleanup(for generation: UUID) {
        guard self.generation == generation else { return }
        cleanupDirty = true
        guard queuedCleanupTask == nil else { return }
        queuedCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Notifications from wake, activation and a day change arrive on
            // separate main-queue turns. Give them a short shared window and
            // defer this synchronous maintenance past immediate activation.
            while !Task.isCancelled, self.generation == generation, self.cleanupDirty {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
                guard !Task.isCancelled, self.generation == generation else { break }
                self.cleanupDirty = false
                self.cleanupAndReschedule(for: generation)
            }
            // An old generation must never erase a new run's task handle.
            if self.generation == generation { self.queuedCleanupTask = nil }
        }
    }

    private func cleanupAndReschedule(for generation: UUID) {
        guard self.generation == generation else { return }
        IdleLatencyTrace.cleanupBegan()
        defer { IdleLatencyTrace.cleanupEnded() }
        let timestamp = now()
        // Foreground/wake refresh is a fallback for delayed or dropped
        // CloudKit remote-change pushes; a local-only build has no remote
        // writer, so the purge reads the store directly (predicated) instead
        // of reloading everything first.
        if RevealRefreshPolicy.current.refreshesOnReveal {
            store.refresh()
        }
        performCleanup(at: timestamp)
        scheduleNextMidnight(after: timestamp)
    }

    private func scheduleNextMidnight(after date: Date) {
        guard let generation else { return }
        timer?.invalidate()
        let activeCalendar = calendar()
        guard let nextDay = activeCalendar.date(byAdding: .day, value: 1, to: activeCalendar.startOfDay(for: date)) else {
            return
        }

        let nextTimer = Timer(fire: nextDay, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.enqueueCleanup(for: generation) }
        }
        nextTimer.tolerance = 1
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }
}
