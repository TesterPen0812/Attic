import AppKit
import Combine
import Darwin
import SwiftData

struct AppRuntimeEnvironment {
    static let testAttachmentRootOwnerMarkerName = ".attic-test-root-owner"

    let environment: [String: String]
    let processIdentifier: Int32
    let testRunIdentifier: String
    let arguments: [String]
    let bundleIdentifier: String?
    /// The Application Support directory the app's files live under; nil is
    /// this process's own (the sandbox container's). Injected by tests so a
    /// launch's file services can be checked against sentinel files.
    let applicationSupportURL: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        testRunIdentifier: String = UUID().uuidString,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        applicationSupportURL: URL? = nil
    ) {
        self.environment = environment
        self.processIdentifier = processIdentifier
        self.testRunIdentifier = testRunIdentifier
        self.arguments = arguments
        self.bundleIdentifier = bundleIdentifier
        self.applicationSupportURL = applicationSupportURL
    }

    var isUITesting: Bool {
        environment["ATTIC_UI_TESTING"] == "1"
    }

    // MARK: Design-system gallery

    static let galleryArgument = "--attic-gallery"
    static let officialBundleIdentifier = "com.taha.Attic"

    /// What a launch with `--attic-gallery` (preview builds only) may do.
    enum GalleryLaunch: Equatable {
        /// No gallery requested: the app starts normally.
        case none
        /// The gallery opens; the persistent store is never opened.
        case allowed
        /// Requested under an identity that could hold real data (the
        /// official bundle): refused, and still no store is opened.
        case refused
    }

    /// The gallery is allowed only under a preview identity
    /// (`com.taha.Attic.<preview>`) or in UI testing, never under the
    /// official `com.taha.Attic` identity that holds the owner's data.
    var galleryLaunch: GalleryLaunch {
        #if DEBUG
        guard arguments.contains(Self.galleryArgument) else { return .none }
        if isUITesting { return .allowed }
        if let bundleIdentifier, bundleIdentifier.hasPrefix(Self.officialBundleIdentifier + "."),
           bundleIdentifier.count > Self.officialBundleIdentifier.count + 1 {
            return .allowed
        }
        return .refused
        #else
        return .none
        #endif
    }

    /// Whether the app's SwiftData store lives in memory only: tests, and
    /// every gallery launch (allowed or refused), so the gallery never
    /// opens, migrates or writes a persistent store.
    var usesInMemoryStore: Bool {
        isUITesting || isRunningTests || galleryLaunch != .none
    }

    /// Any `--attic-gallery` launch, allowed or refused. The app's
    /// coordinator is still built (the SwiftUI scene holds it), so every
    /// service it builds that owns files is pointed away from the identity's
    /// real data: the store is in memory, attachment and task-file stores
    /// live under `galleryScratchRoot` (their launch reconciliation deletes
    /// files the empty store doesn't reference), note draft recovery is off,
    /// settings go to a scratch defaults suite, and the agent credential is
    /// ephemeral.
    var isGalleryLaunch: Bool { galleryLaunch != .none }

    /// A temporary directory this process owns, for the file services of a
    /// gallery launch. Nothing in it is ever the owner's data.
    var galleryScratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticGallery", isDirectory: true)
            .appendingPathComponent("\(processIdentifier)-\(testRunIdentifier)", isDirectory: true)
            .standardizedFileURL
    }

    static let galleryDefaultsSuiteName = "com.taha.Attic.gallery-scratch"

    private var resolvedApplicationSupportURL: URL? {
        applicationSupportURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The menu-bar item appears only when the real app runs.
    var showsMenuBarItem: Bool {
        galleryLaunch == .none
    }

    var isRunningTests: Bool {
        environment["ATTIC_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    var isUnitTestHost: Bool {
        isRunningTests && !isUITesting
    }

    var usesEphemeralAgentCredential: Bool { isUITesting || isRunningTests || isGalleryLaunch }

    var shouldStartInteractiveShellServices: Bool {
        !isUnitTestHost
    }

    var noteRecoveryURL: URL? {
        // The sandbox resolves this inside the running preview's own bundle
        // container. Test controllers inject their own temporary file instead.
        guard !isRunningTests, !isGalleryLaunch else { return nil }
        return resolvedApplicationSupportURL?.appendingPathComponent("Attic/Notes/draft-recovery.json")
    }

    func makeSettingsDefaults(
        standard: UserDefaults = .standard
    ) -> UserDefaults {
        if isGalleryLaunch {
            // Settings migrations write on launch; a gallery launch keeps
            // them away from the identity's real preferences.
            guard let scratch = UserDefaults(suiteName: Self.galleryDefaultsSuiteName) else {
                preconditionFailure("Unable to create the gallery's scratch defaults")
            }
            return scratch
        }
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

    /// The notes' attachment file store: a gallery launch's scratch root,
    /// a test host's owned temporary root, or the app's own directory
    /// (nil: `AttachmentFileStore`'s default, unless Application Support was
    /// injected).
    func makeAttachmentFileStore(
        fileManager: FileManager = .default
    ) -> AttachmentFileStore? {
        if isGalleryLaunch {
            return AttachmentFileStore(
                rootURL: galleryScratchRoot.appendingPathComponent("Attachments/v1", isDirectory: true),
                fileManager: fileManager
            )
        }
        guard isRunningTests else {
            return applicationSupportURL.map {
                AttachmentFileStore(
                    rootURL: $0.appendingPathComponent("Attic/Attachments/v1", isDirectory: true),
                    fileManager: fileManager
                )
            }
        }
        guard let rootURL = attachmentRootURL(fileManager: fileManager) else {
            preconditionFailure(
                "ATTIC_TEST_ATTACHMENT_ROOT was supplied without valid "
                    + "temporary containment and ownership proof"
            )
        }
        return AttachmentFileStore(rootURL: rootURL, fileManager: fileManager)
    }

    /// Task attachment files: a gallery launch's scratch root, or the app's
    /// own directory (`TaskImageFiles.shared` unless Application Support was
    /// injected).
    func makeTaskImageFiles() -> TaskImageFiles {
        if isGalleryLaunch {
            return TaskImageFiles(rootURL: galleryScratchRoot.appendingPathComponent("TaskImages", isDirectory: true))
        }
        if let applicationSupportURL {
            return TaskImageFiles(rootURL: applicationSupportURL.appendingPathComponent("Attic/TaskImages", isDirectory: true))
        }
        return .shared
    }

    /// The task and note stores, with the file services this launch may use
    /// (`makeTaskImageFiles`, `makeAttachmentFileStore`; a performance run
    /// uses its own root). Both reconcile their files against the store they
    /// are given, so a launch's store and its file roots must belong
    /// together: an in-memory gallery store never meets the real files.
    @MainActor
    func makeItemStores(container: ModelContainer, performanceRoot: URL? = nil) -> (tasks: TaskStore, notes: NoteStore) {
        let tasks = TaskStore(
            container: container,
            taskImageFiles: performanceRoot.map {
                TaskImageFiles(rootURL: $0.appendingPathComponent("TaskImages", isDirectory: true))
            } ?? makeTaskImageFiles()
        )
        let notes = NoteStore(
            container: container,
            attachmentFileStore: performanceRoot.map {
                AttachmentFileStore(rootURL: $0.appendingPathComponent("NoteAttachments", isDirectory: true))
            } ?? makeAttachmentFileStore()
        )
        return (tasks, notes)
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
    /// The store-level command layer (undo route, Recently Deleted, tags,
    /// links) shared by agents and, from phase 1, the UI.
    let library: AtticLibrary
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
    /// An agent's `show` over the real panel (the shell tools hold it weakly).
    private let agentPresenter: PanelAgentPresenter
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
    private var performanceSignalSource: (any DispatchSourceSignal)?
    private var performancePhaseIndex = 0

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
        let performanceUICleanup = environment["ATTIC_PERF_UI_CLEANUP"] == "1"
        if environment["ATTIC_PERF_UI_TEST"] == "1",
           uiPerformanceRoot == nil, !performanceUICleanup {
            fatalError("Performance UI tests require their isolated preview bundle")
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
            && !performanceUICleanup
            && runtime.galleryLaunch == .none
        let inMemoryStore = runtime.usesInMemoryStore

        let settings = AppSettings(defaults: runtime.makeSettingsDefaults())
        #if DEBUG && !ATTIC_LOCAL_ONLY
        if !inMemoryStore {
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
                    inMemory: inMemoryStore,
                    cloudSyncEnabled: false
                ) }
            } catch {
                fatalError("Unable to create the local-only SwiftData container: \(error)")
            }
            #else
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                    inMemory: inMemoryStore
                ) }
            } catch let cloudError {
                do {
                    container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                        inMemory: inMemoryStore,
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

        let (store, noteStore) = runtime.makeItemStores(container: container, performanceRoot: performanceRoot)
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
        let library = AtticLibrary(tasks: store, notes: noteStore, canvases: canvasStore)
        let shellTools = AgentShellTools()
        let agentHandler = MCPRequestHandler(
            tools: AgentTaskTools(
                store: store, noteStore: noteStore, library: library,
                settingsTools: AgentSettingsTools(settings: settings, loginItemService: loginItemService, undo: library.undo)
            ),
            shellTools: shellTools
        )
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
            library: library
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
        self.library = library
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.panelController = panelController
        self.loginItemService = loginItemService
        self.settingsWindowController = settingsWindowController
        self.agentServer = agentServer
        self.newTaskHotKey = newTaskHotKey
        cleanupService = DailyCleanupService(
            store: store,
            purgeRecentlyDeleted: { now, calendar in
                library.purgeExpired(now: now, calendar: calendar)
            }
        )
        let hoverMonitor = CornerHoverMonitor(
            settings: settings,
            panelController: panelController,
            uiState: uiState,
            store: store,
            noteStore: noteStore,
            canvasStore: canvasStore,
            noteDraft: noteDraft
        )
        self.hoverMonitor = hoverMonitor
        agentPresenter = PanelAgentPresenter(
            uiState: uiState, store: store, noteStore: noteStore,
            canvasSession: canvasSession, noteDraft: noteDraft,
            reveal: { [weak hoverMonitor] section in
                hoverMonitor?.revealProgrammatically(section: section, takesKeyboard: false) ?? .refused(.noScreen)
            }
        )
        newTaskHotKey.action = { [weak self] in self?.showNewTask() }
        shellTools.presenter = agentPresenter
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
        // Attic's chosen Light, Dark or System applies to the whole app, so
        // every window and every native menu (the menu-bar item's included)
        // follows it; the panel also sets it on its own window.
        AtticWindowAppearance.applyToApp(settings.appearance.designMode)
        appearanceObservation = settings.$appearance
            .removeDuplicates()
            .sink { preference in
                AtticWindowAppearance.applyToApp(preference.designMode)
            }

        observeMenuTracking()
        cleanupService.start()

        if isUITesting {
            // LSUIElement apps do not necessarily become active when XCTest
            // launches them. Activate the real process before presenting the
            // key panel so AppKit, not a test-only model shortcut, owns mouse
            // and keyboard delivery through the installed UI hierarchy.
            // Key-window check seam: reveal the panel the way the corner
            // does (not key, app not activated). The UI test then brings
            // another app forward and clicks the panel, as a person would,
            // and reads the key state the panel exposes to UI tests.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_NONKEY_REVEAL"] == "1" {
                hoverMonitor.keepVisibleForUITesting(makeKey: false)
                return
            }
            NSApp.activate()
            if let performanceRoot,
               ProcessInfo.processInfo.environment["ATTIC_PERF_PROBE"] == "1" {
                hoverMonitor.start()
                let window = Double(ProcessInfo.processInfo.environment["ATTIC_PERF_WINDOW_SECONDS"] ?? "10") ?? 10
                func write(_ phase: String) {
                    let pointer = NSEvent.mouseLocation
                    PerformanceProbe.writePhase(phase, root: performanceRoot, details: [
                        "panel_visible": panelController.isVisibleForPerformanceProbe ? 1 : 0,
                        "hover_hidden": hoverMonitor.isHiddenForPerformanceProbe ? 1 : 0,
                        "visibility_changes": panelController.performanceVisibilityChanges,
                        "visible_strokes": canvasSession.strokes.count,
                        "section_canvas": uiState.selectedSection == .canvas ? 1 : 0,
                        "pointer_x": Int(pointer.x.rounded()),
                        "pointer_y": Int(pointer.y.rounded())
                    ])
                }
                func later(_ seconds: Double, _ action: @escaping () -> Void) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
                }
                if ProcessInfo.processInfo.environment["ATTIC_PERF_EXTERNAL_CONTROL"] == "1" {
                    // A signal arrives only after the sampler finishes its
                    // window. End markers and the next phase cannot race a
                    // slow reveal, footprint call, or AppKit hide completion.
                    signal(SIGUSR1, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
                    // `--extra` adds phases the Phase 0 schedule lacks: a
                    // warm reveal, page switches between built pages, typing
                    // in the add bar, and a warm reveal of Tasks. Their
                    // timings are labelled, so the standard names and the
                    // five sampled phases stay exactly as Baselines A and B.
                    let extra = ProcessInfo.processInfo.environment["ATTIC_PERF_EXTRA"] == "1"
                    let phases = ["hidden_idle", "tasks_open", "canvas_open", "after_hide", "hidden_idle_final"]
                        + (extra ? ["warm_open", "switches_done", "typing_done", "tasks_hidden", "tasks_warm_open"] : [])
                    source.setEventHandler { [weak self] in
                        guard let self, self.performancePhaseIndex < phases.count else { return }
                        write(phases[self.performancePhaseIndex] + "_end")
                        self.performancePhaseIndex += 1
                        switch self.performancePhaseIndex {
                        case 5 where extra:
                            PerformanceSignposts.timingLabel = "warm"
                            self.hoverMonitor.revealForPerformanceProbe(section: self.uiState.selectedSection)
                            later(1) { PerformanceSignposts.timingLabel = nil; write("warm_open") }
                        case 6:
                            // Canvas → Tasks → Notes → Canvas → Tasks, one a second.
                            let route: [PanelSection] = [.tasks, .notes, .canvas, .tasks]
                            for (step, section) in route.enumerated() {
                                later(Double(step)) {
                                    PerformanceSignposts.timingLabel = "switch"
                                    self.hoverMonitor.revealForPerformanceProbe(section: section)
                                }
                            }
                            later(Double(route.count) + 0.5) { PerformanceSignposts.timingLabel = nil; write("switches_done") }
                        case 7:
                            self.uiState.requestPrimaryInputFocus()
                            later(1) {
                                PerformanceSignposts.timingLabel = "typing"
                                for duration in self.panelController.typeForPerformanceProbe("quiet probe keystrokes abc") {
                                    PerformanceSignposts.recordProbeTiming("AddBarKeystrokeToDisplay", milliseconds: duration)
                                }
                                PerformanceSignposts.timingLabel = nil
                                write("typing_done")
                            }
                        case 8:
                            let result = self.hoverMonitor.hideForPerformanceProbe { outcome in
                                write(outcome == .hidden ? "tasks_hidden" : "hide_failed")
                            }
                            if !result.isAccepted { write("hide_failed") }
                        case 9:
                            later(2) {
                                PerformanceSignposts.timingLabel = "warmTasks"
                                self.hoverMonitor.revealForPerformanceProbe(section: .tasks)
                                later(1) { PerformanceSignposts.timingLabel = nil; write("tasks_warm_open") }
                            }
                        case 1:
                            self.hoverMonitor.revealForPerformanceProbe(section: .tasks)
                            later(1) { write("tasks_open") }
                        case 2:
                            self.hoverMonitor.revealForPerformanceProbe(section: .canvas)
                            later(1) { write("canvas_open") }
                        case 3:
                            let result = self.hoverMonitor.hideForPerformanceProbe { outcome in
                                write(outcome == .hidden ? "after_hide" : "hide_failed")
                            }
                            if !result.isAccepted { write("hide_failed") }
                        case 4:
                            write("hidden_idle_final")
                        default:
                            break
                        }
                    }
                    performanceSignalSource = source
                    source.resume()
                    write("hidden_idle")
                    return
                }
                write("hidden_idle")
                later(30 + window + 8) { write("hidden_idle_end") }
                later(30 + window + 18) {
                    self.hoverMonitor.revealForPerformanceProbe(section: .tasks)
                    later(1) { write("tasks_open") }
                    later(window + 8) { write("tasks_open_end") }
                    later(window + 18) {
                        self.hoverMonitor.revealForPerformanceProbe(section: .canvas)
                        later(1) { write("canvas_open") }
                        later(window + 8) { write("canvas_open_end") }
                        later(window + 18) {
                            let result = self.hoverMonitor.hideForPerformanceProbe { outcome in
                                write(outcome == .hidden ? "after_hide" : "hide_failed")
                                guard outcome == .hidden else { return }
                                later(30 + window + 8) {
                                    write("after_hide_end")
                                    later(1) { write("hidden_idle_final") }
                                    later(window + 16) { write("hidden_idle_final_end") }
                                }
                            }
                            if !result.isAccepted { write("hide_failed") }
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
        performanceSignalSource?.cancel()
        performanceSignalSource = nil
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

    /// The menu-bar Search: the Tasks page's Done search, focused (⌘K
    /// search arrives with the command palette in a later phase).
    func showSearch() {
        guard hoverMonitor.revealProgrammatically(section: .tasks) == .shown else { return }
        uiState.requestSearch()
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
