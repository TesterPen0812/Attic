import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
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
        AppCoordinator.shared.start()
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
