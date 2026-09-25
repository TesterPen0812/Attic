import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Preview builds only: `--attic-gallery` opens the design-system
        // gallery instead of starting the panel (Release has no gallery).
        if AtticGalleryLaunch.startIfRequested() { return }
        #endif
        #if !ATTIC_LOCAL_ONLY
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        AppCoordinator.shared.start()
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
        AppCoordinator.shared.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.showPanel()
        return true
    }
}
