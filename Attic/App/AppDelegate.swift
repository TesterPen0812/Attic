import AppKit

/// A second terminate() while AppKit is waiting for a terminateLater reply
/// can end the process without another delegate callback. Keep one Quit
/// request alive until the durability check accepts or refuses it.
@MainActor
final class AppQuitRequestGate {
    static let shared = AppQuitRequestGate()
    private var requestPending = false
    private var preparationPending = false

    func request(_ terminate: () -> Void) {
        guard !requestPending else { return }
        requestPending = true
        terminate()
    }

    func beginPreparation() -> Bool {
        guard !preparationPending else { return false }
        requestPending = true
        preparationPending = true
        return true
    }

    func finishPreparation(approved: Bool) {
        preparationPending = false
        if !approved { requestPending = false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        AtticFrameMonitor.startIfRequested()
        // Preview builds only: `--attic-gallery` opens the design-system
        // gallery instead of starting the panel (Release has no gallery).
        switch AppRuntimeEnvironment().galleryLaunch {
        case .allowed:
            if AtticGalleryLaunch.startIfRequested() { return }
        case .refused:
            // Never under the official identity: its store is the owner's
            // data. Use a preview identity (com.taha.Attic.<preview>).
            NSLog("Attic: --attic-gallery refused under %@; use a com.taha.Attic.<preview> identity", Bundle.main.bundleIdentifier ?? "?")
            print("Attic: --attic-gallery is refused under the official identity; use a com.taha.Attic.<preview> preview build.")
            NSApp.terminate(nil)
            return
        case .none:
            break
        }
        #endif
        #if !ATTIC_LOCAL_ONLY
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        AppCoordinator.shared?.start()
        PerformanceSignposts.menuReady()
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Remote notification registration failed: %@", error.localizedDescription)
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NSLog("Remote notification registration succeeded")
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let coordinator = AppCoordinator.shared else { return .terminateNow }
        guard AppQuitRequestGate.shared.beginPreparation() else { return .terminateLater }
        Task { @MainActor in
            let ready = await coordinator.prepareForTerminationDurably()
            AppQuitRequestGate.shared.finishPreparation(approved: ready)
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared?.showPanel()
        return true
    }
}
