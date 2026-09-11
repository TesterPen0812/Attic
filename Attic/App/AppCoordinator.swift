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

@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let settings: AppSettings
    let store: TaskStore
    let noteStore: NoteStore
    let canvasStore: CanvasStore
    let canvasSession: CanvasSession
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
    private let shouldStartInteractiveShellServices: Bool
    private var menuNotificationTokens: [NSObjectProtocol] = []
    private var menuTrackingState = PanelMenuTrackingState()
    private var agentAccessObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var hasStarted = false
    private lazy var newTaskHotKey = GlobalHotKey { [weak self] in
        self?.showNewTask()
    }

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let runtime = AppRuntimeEnvironment(environment: environment)
        isUITesting = runtime.isUITesting
        isRunningTests = runtime.isRunningTests
        shouldStartInteractiveShellServices = runtime.shouldStartInteractiveShellServices
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
        if usesCanvasUITestPersistence {
            do {
                container = try PersistenceController.makeCanvasUITestContainer(
                    reset: environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1"
                )
            } catch {
                fatalError("Unable to create the isolated Canvas UI test store: \(error)")
            }
        } else {
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
        }

        let store = TaskStore(container: container)
        let noteStore = NoteStore(
            container: container,
            attachmentFileStore: runtime.makeAttachmentFileStore()
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
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            loginItemService: loginItemService,
            agentServer: agentServer,
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
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard shouldStartInteractiveShellServices else { return }
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
            hoverMonitor.keepVisibleForUITesting()
            return
        }

        newTaskHotKey.register()
        hoverMonitor.start()
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
        if isRunningTests && !isUITesting {
            hasStarted = false
            return
        }
        canvasSession.cancelActiveInteraction()
        _ = noteDraft.flush()
        cleanupService.stop()
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
        canvasSession.cancelActiveInteraction()
        canvasSession.flushViewState()
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
