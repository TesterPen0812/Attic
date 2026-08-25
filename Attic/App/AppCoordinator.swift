import AppKit
import Combine
import SwiftData

@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let settings: AppSettings
    let store: TaskStore
    let noteStore: NoteStore
    let noteDraft: NoteDraftController
    let loginItemService: LoginItemService
    let uiState: PanelUIState

    private let cleanupService: DailyCleanupService
    private let panelController: AtticPanelController
    private let settingsWindowController: SettingsWindowController
    private let hoverMonitor: CornerHoverMonitor
    private let agentServer: AgentServer
    private let isUITesting: Bool
    private let isRunningTests: Bool
    private var menuNotificationTokens: [NSObjectProtocol] = []
    private var agentAccessObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var hasStarted = false
    private lazy var newTaskHotKey = GlobalHotKey { [weak self] in
        self?.showNewTask()
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        isUITesting = environment["ATTIC_UI_TESTING"] == "1"
        isRunningTests = environment["ATTIC_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil

        let settings = AppSettings()
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
        #if ATTIC_LOCAL_ONLY
        do {
            container = try PersistenceController.makeContainer(
                inMemory: isUITesting || isRunningTests,
                cloudSyncEnabled: false
            )
        } catch {
            fatalError("Unable to create the local-only SwiftData container: \(error)")
        }
        #else
        do {
            container = try PersistenceController.makeContainer(
                inMemory: isUITesting || isRunningTests
            )
        } catch let cloudError {
            do {
                container = try PersistenceController.makeContainer(
                    inMemory: isUITesting || isRunningTests,
                    cloudSyncEnabled: false
                )
                settings.reportCloudSyncStartupFailure(cloudError.localizedDescription)
            } catch {
                fatalError(
                    "Unable to create the SwiftData container with CloudKit "
                        + "(\(cloudError)) or local-only (\(error))"
                )
            }
        }
        #endif

        let store = TaskStore(container: container)
        let noteStore = NoteStore(container: container)
        let noteDraft = NoteDraftController(noteStore: noteStore)
        let uiState = PanelUIState()
        let loginItemService = LoginItemService()
        let agentAccessToken = AgentAccessTokenStore().loadOrCreate()
        let agentServer = AgentServer(
            port: settings.agentServerPort,
            bearerToken: agentAccessToken,
            handler: MCPRequestHandler(tools: AgentTaskTools(store: store, noteStore: noteStore))
        )
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            loginItemService: loginItemService,
            agentServer: agentServer,
            store: store,
            agentAccessToken: agentAccessToken
        )
        let panelController = AtticPanelController(
            store: store,
            noteStore: noteStore,
            noteDraft: noteDraft,
            settings: settings,
            uiState: uiState
        )

        self.settings = settings
        self.store = store
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.panelController = panelController
        self.loginItemService = loginItemService
        self.settingsWindowController = settingsWindowController
        self.agentServer = agentServer
        cleanupService = DailyCleanupService(store: store)
        hoverMonitor = CornerHoverMonitor(
            settings: settings,
            panelController: panelController,
            uiState: uiState,
            store: store,
            noteStore: noteStore,
            noteDraft: noteDraft
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        NSApp.appearance = settings.appearance.nsAppearance

        observeMenuTracking()
        cleanupService.start()

        if isUITesting {
            hoverMonitor.keepVisibleForUITesting()
            return
        }

        newTaskHotKey.register()
        hoverMonitor.start()
        appearanceObservation = settings.$appearance.sink { preference in
            NSApp.appearance = preference.nsAppearance
        }
        if !isRunningTests {
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
        _ = noteDraft.flush()
        cleanupService.stop()
        hoverMonitor.stop()
        newTaskHotKey.unregister()
        appearanceObservation = nil
        agentAccessObservation = nil
        agentServer.stop()
        menuNotificationTokens.forEach(NotificationCenter.default.removeObserver)
        menuNotificationTokens.removeAll()
        hasStarted = false
    }

    func prepareForTermination() -> Bool {
        guard noteDraft.flush() else {
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
                Task { @MainActor in self?.uiState.isMenuTracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.uiState.isMenuTracking = false }
            }
        ]
    }
}
