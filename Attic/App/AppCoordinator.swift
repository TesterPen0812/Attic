import AppKit
import Combine
import SwiftData

struct AppRuntimeEnvironment {
    static let testAttachmentRootOwnerMarkerName = ".attic-test-root-owner"

    let environment: [String: String]
    let processIdentifier: Int32
    let testRunIdentifier: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        testRunIdentifier: String = UUID().uuidString
    ) {
        self.environment = environment
        self.processIdentifier = processIdentifier
        self.testRunIdentifier = testRunIdentifier
    }

    var isUITesting: Bool {
        environment["ATTIC_UI_TESTING"] == "1"
    }

    var isRunningTests: Bool {
        environment["ATTIC_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    var isUnitTestHost: Bool {
        isRunningTests && !isUITesting
    }

    var usesEphemeralAgentCredential: Bool { isUITesting || isRunningTests }

    var shouldStartInteractiveShellServices: Bool {
        !isUnitTestHost
    }

    var noteRecoveryURL: URL? {
        // The sandbox resolves this inside the running preview's own bundle
        // container. Test controllers inject their own temporary file instead.
        guard !isRunningTests else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Attic/Notes/draft-recovery.json")
    }

    func makeSettingsDefaults(
        standard: UserDefaults = .standard
    ) -> UserDefaults {
        guard isUnitTestHost else { return standard }
        let suiteName = environment["ATTIC_TEST_DEFAULTS_SUITE"]
            ?? "com.taha.Attic.unit-tests.\(processIdentifier)"
        guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated test defaults: \(suiteName)")
        }
        return isolatedDefaults
    }

    func attachmentRootURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard isRunningTests else { return nil }
        let fallback = fileManager.temporaryDirectory
            .appendingPathComponent("AtticTestHosts", isDirectory: true)
            .appendingPathComponent(
                "\(processIdentifier)-\(testRunIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .standardizedFileURL
        if let explicitRoot = environment["ATTIC_TEST_ATTACHMENT_ROOT"],
           !explicitRoot.isEmpty {
            return validatedExplicitAttachmentRootURL(
                explicitRoot,
                fileManager: fileManager
            )
        }
        return fallback
    }

    private func validatedExplicitAttachmentRootURL(
        _ path: String,
        fileManager: FileManager
    ) -> URL? {
        guard let ownerToken = environment[
            "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN"
        ], !ownerToken.isEmpty else {
            return nil
        }
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path != temporaryRoot.path,
              candidate.path.hasPrefix(temporaryRoot.path + "/") else {
            return nil
        }
        let marker = candidate.appendingPathComponent(
            Self.testAttachmentRootOwnerMarkerName,
            isDirectory: false
        )
        guard let markerData = try? Data(contentsOf: marker),
              let markerValue = String(data: markerData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              markerValue == ownerToken else {
            return nil
        }
        return candidate
    }

    func makeAttachmentFileStore(
        fileManager: FileManager = .default
    ) -> AttachmentFileStore? {
        guard isRunningTests else { return nil }
        guard let rootURL = attachmentRootURL(fileManager: fileManager) else {
            preconditionFailure(
                "ATTIC_TEST_ATTACHMENT_ROOT was supplied without valid "
                    + "temporary containment and ownership proof"
            )
        }
        return AttachmentFileStore(rootURL: rootURL, fileManager: fileManager)
    }
}

struct PanelMenuTrackingState {
    private(set) var depth = 0

    var isTracking: Bool { depth > 0 }

    mutating func begin() {
        depth += 1
    }

    mutating func end() {
        depth = max(0, depth - 1)
    }
}

enum AppTerminationPreparation {
    static func prepare(
        flushNoteDraft: () -> Bool,
        commitCanvasTermination: () -> Void
    ) -> Bool {
        guard flushNoteDraft() else { return false }
        commitCanvasTermination()
        return true
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    /// Read-only mirror of the global shortcut's registration, so UI can stop
    /// advertising a combination the system refused without being able to
    /// register, unregister or rebind it. Published because a refusal resolves
    /// during `start()`, which can land after a menu has already been built.
    @Published private(set) var globalShortcutRegistration: GlobalHotKeyRegistration = .notRegistered

    /// The combination that shortcut claims, for the menu that advertises it.
    var globalShortcutCombination: GlobalHotKeyCombination { newTaskHotKey.combination }

    let settings: AppSettings
    let store: TaskStore
    let noteStore: NoteStore
    let canvasStore: CanvasStore
    let canvasSession: CanvasSession
    let noteDraft: NoteDraftController
    let loginItemService: LoginItemService
    let uiState: PanelUIState
    /// Renders the Edit menu's Undo/Redo enablement again when a text view
    /// outside the canvas takes or gives up focus. Nothing else in the app's
    /// model moves at that boundary, so without it the menu keeps the
    /// enablement of its last render; see `CanvasEditCommandFocusMonitor`.
    let canvasEditFocus = CanvasEditCommandFocusMonitor()

    private let cleanupService: DailyCleanupService
    private let panelController: AtticPanelController
    /// The auxiliary subtask surfaces (transient hover panel and the single
    /// pinned mini-window) owned by the panel controller.
    var subtaskPanels: SubtaskPanelController { panelController.subtaskPanels }

    /// Capture seam for the appearance harness: seeds one family into the
    /// in-memory UI-testing store and pins its checklist window, so the
    /// auxiliary surface can be photographed hands-off next to the panel.
    private func presentSampleSubtaskWindowsForUITesting() {
        guard let parent = store.create(title: "Plan the launch") else { return }
        _ = store.create(title: "Write the announcement", parentID: parent.id)
        _ = store.create(title: "Check the build", parentID: parent.id)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            subtaskPanels.pinFamily(parent.id)
            // Clear of the panel, on the main display, so the checklist is
            // photographed over the harness backdrop rather than the panel.
            if let screen = NSScreen.main?.visibleFrame {
                subtaskPanels.placePinnedWindowForUITesting(
                    parent.id,
                    visibleOrigin: CGPoint(x: screen.midX - SubtaskPanelLayout.panelWidth / 2,
                                           y: screen.midY - 120)
                )
            }
        }
    }
    private let settingsWindowController: SettingsWindowController
    private let hoverMonitor: CornerHoverMonitor
    private let agentServer: AgentServer
    private let isUITesting: Bool
    private let isRunningTests: Bool
    private let shouldStartInteractiveShellServices: Bool
    private var menuNotificationTokens: [NSObjectProtocol] = []
    private var menuTrackingState = PanelMenuTrackingState()
    private var agentAccessObservation: AnyCancellable?
    private var globalShortcutObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var hasStarted = false
    private let newTaskHotKey: GlobalHotKey
    private let performanceRoot: URL?
    private let isPerformanceSeedOnly: Bool

    private init() {
        PerformanceSignposts.beginLaunch()
        let environment = ProcessInfo.processInfo.environment
        let runtime = AppRuntimeEnvironment(environment: environment)
        let isUITesting = runtime.isUITesting
        let isRunningTests = runtime.isRunningTests
        let externalPerformanceRoot = PerformanceProbe.validatedRoot(environment: environment)
        if environment["ATTIC_PERF_STORE_ROOT"] != nil && externalPerformanceRoot == nil {
            fatalError("Performance store root is not an owned temporary directory")
        }
        let uiPerformanceRoot: URL?
        do {
            uiPerformanceRoot = try PerformanceProbe.uiTestRoot(environment: environment)
        } catch {
            fatalError("Unable to create the isolated performance UI test root: \(error)")
        }
        let performanceRoot = externalPerformanceRoot ?? uiPerformanceRoot
        let performanceSeedOnly = environment["ATTIC_PERF_SEED_ONLY"] == "1"
        self.isUITesting = isUITesting
        self.isRunningTests = isRunningTests
        shouldStartInteractiveShellServices = runtime.shouldStartInteractiveShellServices
        // A performance run must opt into the UI-test identity and prove it
        // owns a temporary root. It can never fall through to the normal store.
        self.performanceRoot = performanceRoot
        isPerformanceSeedOnly = performanceSeedOnly
        let usesCanvasUITestPersistence = (isUITesting || isRunningTests)
            && environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1"

        let settings = AppSettings(defaults: runtime.makeSettingsDefaults())
        #if DEBUG && !ATTIC_LOCAL_ONLY
        if !isUITesting && !isRunningTests {
            do {
                try PersistenceController.initializeCloudKitDevelopmentSchemaIfNeeded()
            } catch {
                let nsError = error as NSError
                let diagnostic = "\(nsError.domain) (\(nsError.code)): \(nsError.userInfo)"
                NSLog("CloudKit schema initialization failed: %@", diagnostic)
                settings.reportCloudSyncStartupFailure(diagnostic)
            }
        }
        #endif
        let container: ModelContainer
        if let performanceRoot {
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeCanvasUITestContainer(
                    reset: performanceSeedOnly, baseDirectory: performanceRoot
                ) }
                if performanceSeedOnly {
                    PerformanceProbe.writePhase("seeding", root: performanceRoot)
                    try PerformanceSeed.generate(
                        in: container, root: performanceRoot,
                        includeDoneHistory: environment["ATTIC_PERF_DONE_HISTORY"] == "1"
                    )
                    PerformanceProbe.writePhase("seed_complete", root: performanceRoot)
                }
            } catch {
                fatalError("Unable to create the isolated performance store: \(error)")
            }
        } else if usesCanvasUITestPersistence {
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeCanvasUITestContainer(
                    reset: environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1"
                ) }
            } catch {
                fatalError("Unable to create the isolated Canvas UI test store: \(error)")
            }
        } else {
            #if ATTIC_LOCAL_ONLY
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                    inMemory: isUITesting || isRunningTests,
                    cloudSyncEnabled: false
                ) }
            } catch {
                fatalError("Unable to create the local-only SwiftData container: \(error)")
            }
            #else
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                    inMemory: isUITesting || isRunningTests
                ) }
            } catch let cloudError {
                do {
                    container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                        inMemory: isUITesting || isRunningTests,
                        cloudSyncEnabled: false
                    ) }
                    settings.reportCloudSyncStartupFailure(cloudError.localizedDescription)
                } catch {
                    fatalError(
                        "Unable to create the SwiftData container with CloudKit "
                            + "(\(cloudError)) or local-only (\(error))"
                    )
                }
            }
            #endif
        }

        let store = TaskStore(
            container: container,
            taskImageFiles: performanceRoot.map {
                TaskImageFiles(rootURL: $0.appendingPathComponent("TaskImages", isDirectory: true))
            } ?? .shared
        )
        let noteStore = NoteStore(
            container: container,
            attachmentFileStore: performanceRoot.map {
                AttachmentFileStore(rootURL: $0.appendingPathComponent("NoteAttachments", isDirectory: true))
            } ?? runtime.makeAttachmentFileStore()
        )
        let canvasStore = CanvasStore(container: container)
        let canvasViewDefaults = runtime.isUnitTestHost ? nil : runtime.makeSettingsDefaults()
        if isUITesting,
           !usesCanvasUITestPersistence || environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1" {
            // The real UI host exercises restoration in its own bundle domain;
            // only the explicit start of a test scenario resets that state.
            canvasViewDefaults?.removeObject(forKey: CanvasViewStateArchive.defaultsKey)
        }
        let canvasSession = CanvasSession(
            store: canvasStore,
            viewStateDefaults: canvasViewDefaults
        )
        let noteDraft = NoteDraftController(
            noteStore: noteStore,
            sessionDefaults: isRunningTests ? nil : runtime.makeSettingsDefaults(),
            recoveryURL: runtime.noteRecoveryURL
        )
        let uiState = PanelUIState()
        let loginItemService = LoginItemService()
        // Local-only disables cloud services, not authenticated loopback MCP.
        // Each bundle identity owns its credential; previews never reuse Daily's.
        // Both kinds of test host avoid Keychain. In normal use, credential
        // loading starts only after opt-in and runs away from the main thread.
        let agentHandler = MCPRequestHandler(tools: AgentTaskTools(store: store, noteStore: noteStore))
        let agentServer: AgentServer
        if runtime.usesEphemeralAgentCredential {
            agentServer = AgentServer(port: settings.agentServerPort,
                                      bearerToken: (try? AgentAccessTokenStore.generateToken()) ?? "",
                                      handler: agentHandler)
        } else {
            agentServer = AgentServer(port: settings.agentServerPort, handler: agentHandler)
        }
        // Built before the window so Settings observes the same hot key it
        // reports on; its action is bound once `self` exists.
        let newTaskHotKey = GlobalHotKey()
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            loginItemService: loginItemService,
            agentServer: agentServer,
            globalHotKey: newTaskHotKey,
            store: store
        )
        let panelController = AtticPanelController(
            store: store,
            noteStore: noteStore,
            canvasSession: canvasSession,
            noteDraft: noteDraft,
            settings: settings,
            uiState: uiState
        )

        self.settings = settings
        self.store = store
        self.noteStore = noteStore
        self.canvasStore = canvasStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.panelController = panelController
        self.loginItemService = loginItemService
        self.settingsWindowController = settingsWindowController
        self.agentServer = agentServer
        self.newTaskHotKey = newTaskHotKey
        cleanupService = DailyCleanupService(store: store)
        hoverMonitor = CornerHoverMonitor(
            settings: settings,
            panelController: panelController,
            uiState: uiState,
            store: store,
            noteStore: noteStore,
            canvasStore: canvasStore,
            noteDraft: noteDraft
        )
        newTaskHotKey.action = { [weak self] in self?.showNewTask() }
        globalShortcutObservation = newTaskHotKey.$registration
            .sink { [weak self] registration in
                self?.globalShortcutRegistration = registration
            }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard shouldStartInteractiveShellServices else { return }
        if isPerformanceSeedOnly {
            return
        }
        NSApp.appearance = settings.appearance.nsAppearance
        appearanceObservation = settings.$appearance
            .removeDuplicates()
            .sink { preference in
                NSApp.appearance = preference.nsAppearance
            }

        observeMenuTracking()
        cleanupService.start()

        if isUITesting {
            // LSUIElement apps do not necessarily become active when XCTest
            // launches them. Activate the real process before presenting the
            // key panel so AppKit, not a test-only model shortcut, owns mouse
            // and keyboard delivery through the installed UI hierarchy.
            NSApp.activate()
            if let performanceRoot,
               ProcessInfo.processInfo.environment["ATTIC_PERF_PROBE"] == "1" {
                hoverMonitor.start()
                PerformanceProbe.writePhase(
                    "hidden_idle", root: performanceRoot,
                    details: ["panel_visible": panelController.isVisibleForPerformanceProbe ? 1 : 0]
                )
                let stages: [(Double, String, () -> Void)] = [
                    (20, "tasks_open", { [weak self] in self?.showPanel() }),
                    (40, "canvas_open", { [weak self] in
                        self?.hoverMonitor.revealProgrammatically(section: .canvas)
                    }),
                    (60, "after_hide", { [weak self] in
                        guard let self else { return }
                        _ = self.panelController.requestHide { outcome in
                            PerformanceProbe.writePhase(
                                outcome == .hidden ? "after_hide" : "hide_failed",
                                root: performanceRoot,
                                details: ["panel_visible": self.panelController.isVisibleForPerformanceProbe ? 1 : 0]
                            )
                        }
                    })
                ]
                for (delay, phase, action) in stages {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        action()
                        if phase != "after_hide" {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                let strokeCount = self.canvasSession.strokes.count
                                let valid = phase != "canvas_open"
                                    || (self.uiState.selectedSection == .canvas
                                        && strokeCount == 1_700)
                                PerformanceProbe.writePhase(
                                    valid ? phase : "canvas_failed", root: performanceRoot,
                                    details: [
                                        "visible_strokes": strokeCount,
                                        "panel_visible": self.panelController.isVisibleForPerformanceProbe ? 1 : 0
                                    ]
                                )
                            }
                        }
                    }
                }
                return
            }
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_HOVER_MONITOR"] == "1" {
                hoverMonitor.start()
                hoverMonitor.revealProgrammatically(openComposer: true, section: .tasks)
            } else {
                hoverMonitor.keepVisibleForUITesting()
            }
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_PRESENT_SUBTASKS"] == "1" {
                presentSampleSubtaskWindowsForUITesting()
            }
            // Capture seam: open Settings on the remembered section (pass
            // `-AtticSettings.selectedSection <section>`) for screenshots.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.async { [weak self] in self?.openSettings() }
            }
            return
        }

        newTaskHotKey.register()
        hoverMonitor.start()
        if !isRunningTests {
            // Once per launch, on the persistent store only (tests and UI
            // tests use an in-memory store, whose empty reference set must
            // never judge real files).
            let store = store
            Task { await store.sweepUnreferencedAttachmentStorage() }
            agentAccessObservation = settings.$isAgentAccessEnabled.sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled {
                    agentServer.start()
                } else {
                    agentServer.stop()
                }
            }
        }
        if !settings.hasShownWelcome {
            settings.markWelcomeShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func stop() {
        if isRunningTests && !isUITesting {
            hasStarted = false
            return
        }
        canvasSession.cancelActiveInteraction()
        _ = noteDraft.flush()
        cleanupService.stop()
        panelController.subtaskPanels.tearDown()
        hoverMonitor.stop()
        newTaskHotKey.unregister()
        appearanceObservation = nil
        agentAccessObservation = nil
        agentServer.stop()
        menuNotificationTokens.forEach(NotificationCenter.default.removeObserver)
        menuNotificationTokens.removeAll()
        menuTrackingState = PanelMenuTrackingState()
        uiState.setInteractionLock(.menuTracking, isActive: false)
        hasStarted = false
    }

    func prepareForTermination() -> Bool {
        let canTerminate = AppTerminationPreparation.prepare(
            flushNoteDraft: { noteDraft.flush() },
            commitCanvasTermination: {
                canvasSession.cancelActiveInteraction()
                canvasSession.flushViewState()
            }
        )
        guard canTerminate else {
            hoverMonitor.revealProgrammatically(section: .notes)
            return false
        }
        return true
    }

    func showPanel() {
        hoverMonitor.revealProgrammatically()
    }

    func showNewTask() {
        hoverMonitor.revealProgrammatically(openComposer: true, section: .tasks)
    }

    func showNewNote() {
        hoverMonitor.revealProgrammatically(openComposer: true, section: .notes)
    }

    func openSettings() {
        settingsWindowController.show()
    }

    private func observeMenuTracking() {
        let center = NotificationCenter.default
        menuNotificationTokens = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTrackingState.begin()
                    self?.uiState.setInteractionLock(.menuTracking, isActive: true)
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTrackingState.end()
                    self?.uiState.setInteractionLock(
                        .menuTracking,
                        isActive: self?.menuTrackingState.isTracking == true
                    )
                }
            }
        ]
    }
}
