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
    func makeItemStores(container: ModelContainer, performanceRoot: URL? = nil) throws -> (tasks: TaskStore, notes: NoteStore) {
        if let recovery = noteRecoveryURL {
            WorkspaceLegacyBridge.configureJournalDirectory(
                recovery.deletingLastPathComponent().appendingPathComponent("NoteDrafts"), for: container
            )
        }
        let workspace = try? WorkspaceLegacyBridge.coordinator(for: container)
        workspace?.beginLaunchRegistration()
        let tasks = TaskStore(
            container: container,
            taskImageFiles: performanceRoot.map {
                TaskImageFiles(rootURL: $0.appendingPathComponent("TaskImages", isDirectory: true))
            } ?? makeTaskImageFiles()
        )
        let attachmentFiles = performanceRoot.map {
            AttachmentFileStore(rootURL: $0.appendingPathComponent("NoteAttachments", isDirectory: true))
        } ?? makeAttachmentFileStore() ?? AttachmentFileStore()
        try OldNotesPurge.cleanup(in: container, recoveryURL: noteRecoveryURL, attachmentRoot: attachmentFiles.rootURL)
        let notes = NoteStore(container: container, attachmentFileStore: attachmentFiles)
        // Every launch path builds these stores, including noninteractive and
        // seed-only hosts. The main-actor task runs after synchronous launch
        // presentation construction, independent of start()'s early returns.
        Task { @MainActor in
            try? await workspace?.finishLaunch()
        }
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

private struct AppStartupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One store-open attempt, followed only by explicit retry. The failed
/// store is retained; constructing an empty replacement is never a fallback.
@MainActor
final class AppStartup<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var failureMessage: String?
    private let open: () throws -> Value

    init(open: @escaping () throws -> Value) {
        self.open = open
        retry()
    }

    func retry() {
        guard value == nil else { return }
        do {
            value = try open()
            failureMessage = nil
        } catch {
            failureMessage = "Attic could not open its local data. Try again. Your existing data is kept."
            NSLog("Attic startup could not open local data")
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    static let startup = AppStartup { try AppCoordinator() }
    static var shared: AppCoordinator? { startup.value }

    static func retryStartup() {
        startup.retry()
        shared?.start()
    }

    /// Read-only mirror of the global shortcut's registration, so UI can stop
    /// advertising a combination the system refused without being able to
    /// register, unregister or rebind it. Published because a refusal resolves
    /// during `start()`, which can land after a menu has already been built.
    @Published private(set) var globalShortcutRegistration: GlobalHotKeyRegistration = .notRegistered

    /// Whether the panel is pinned, mirrored for the menu bar's Open ▸ Pin
    /// Panel tick (the menu observes nothing else of the shell).
    @Published private(set) var isPanelPinned = false
    private var pinObservation: AnyCancellable?

    /// The combination that shortcut claims, for the menu that advertises it.
    var globalShortcutCombination: GlobalHotKeyCombination { newTaskHotKey.combination }

    /// The hot key itself, for Settings' recorder (it releases the claim
    /// while a new combination is typed).

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
    private let settingsWindowController: SettingsWindowController
    private let hoverMonitor: CornerHoverMonitor
    /// An agent's `show` over the real panel (the shell tools hold it weakly).
    private let agentPresenter: PanelAgentPresenter
    private let agentServer: AgentServer
    private let agentRunner: AgentRunEngine
    /// Trusted in-app runner seam. A run registers here before giving its
    /// private MCP bearer to the installed Claude Code or Codex process.
    var agentRunServer: AgentServer { agentServer }
    private let isUITesting: Bool
    private let isRunningTests: Bool
    private let shouldStartInteractiveShellServices: Bool
    private var menuNotificationTokens: [NSObjectProtocol] = []
    private var menuTrackingState = PanelMenuTrackingState()
    private var agentAccessObservation: AnyCancellable?
    private var globalShortcutObservation: AnyCancellable?
    private var quickCaptureObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var hasStarted = false
    private let newTaskHotKey: GlobalHotKey
    private let performanceRoot: URL?
    private let isPerformanceSeedOnly: Bool
    private var performanceSignalSource: (any DispatchSourceSignal)?
    #if DEBUG
    private var hideMotionBench: PanelHideMotionBench?
    private var pageSwitchBench: (any DispatchSourceSignal)?
    private var benchSources: [any DispatchSourceSignal] = []
    #endif
    private var performancePhaseIndex = 0

    init(runtime: AppRuntimeEnvironment = AppRuntimeEnvironment(),
         openStore: (() throws -> ModelContainer)? = nil) throws {
        PerformanceSignposts.beginLaunch()
        let environment = runtime.environment
        let isUITesting = runtime.isUITesting
        let isRunningTests = runtime.isRunningTests
        let externalPerformanceRoot = PerformanceProbe.validatedRoot(environment: environment)
        if environment["ATTIC_PERF_STORE_ROOT"] != nil && externalPerformanceRoot == nil {
            throw AppStartupError(message: "Performance store root is not an owned temporary directory")
        }
        let uiPerformanceRoot: URL?
        do {
            uiPerformanceRoot = try PerformanceProbe.uiTestRoot(environment: environment)
        } catch {
            throw error
        }
        let performanceUICleanup = environment["ATTIC_PERF_UI_CLEANUP"] == "1"
        if environment["ATTIC_PERF_UI_TEST"] == "1",
           uiPerformanceRoot == nil, !performanceUICleanup {
            throw AppStartupError(message: "Performance UI tests require their isolated preview bundle")
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
        if let openStore {
            container = try PerformanceSignposts.storeOpen(openStore)
        } else if let performanceRoot {
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
                throw error
            }
        } else if usesCanvasUITestPersistence {
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeCanvasUITestContainer(
                    reset: environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1"
                ) }
            } catch {
                throw error
            }
        } else {
            #if ATTIC_LOCAL_ONLY
            do {
                container = try PerformanceSignposts.storeOpen { try PersistenceController.makeContainer(
                    inMemory: inMemoryStore,
                    cloudSyncEnabled: false
                ) }
            } catch {
                throw error
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
                    throw error
                }
            }
            #endif
        }

        // While Draw has Canvas's place, the old Canvas rows in this store
        // are left untouched and unread for the whole run.
        if AtticDraw.isEnabled { AtticLegacyCanvas.markDormant(container) }
        #if DEBUG
        // Capture seam: the in-memory UI-test store holds the design mockup's
        // tasks (`TasksPagePreview.seedDemo`), never anything of the owner's.
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "demo" || environment["ATTIC_UI_TEST_SEED"] == "long" {
            try? TasksPagePreview.seedDemo(in: container, long: environment["ATTIC_UI_TEST_SEED"] == "long")
        }
        // The spec's sizes (round 11, on-screen measurement): 500 open, 500
        // in Later, 5,000 in the Done log.
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "scale" {
            try? TasksPagePreview.seedScale(in: container)
        }
        // The colour pass sheet's tasks (`phaseX/colour-final.md`).
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "colour" {
            try? TasksPagePreview.seedColour(in: container)
        }
        // Everything finished today: the caught-up Now page.
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "caughtup" {
            try? TasksPagePreview.seedCaughtUp(in: container)
        }
        // Phase 3 slice 0b: the task's-note fixtures (the preview's seeded
        // entry point; `ATTIC_UI_TEST_TASK_NOTE` opens one).
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "tasknote" {
            try? TaskNotePreviewSeed.seedAll(in: container)
        }
        // Phase 3 slice 1: "Attic Task Life"'s samples, for captures.
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "tasklife" {
            try? TaskNotePreviewSeed.seedOwnerPreview(in: container)
            try? TaskNoteLifecyclePreviewSeed.seed(in: container)
        }
        // Phase 3 slice 2: "Attic Task Files"'s samples, for captures.
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "taskfiles" {
            try? TaskNotePreviewSeed.seedOwnerPreview(in: container)
        }
        #endif
        let (store, noteStore) = try runtime.makeItemStores(container: container, performanceRoot: performanceRoot)
        // Attachments belong only to explicitly requested in-memory UI fixtures.
        if inMemoryStore, isUITesting, ["tasknote", "taskfiles"].contains(environment["ATTIC_UI_TEST_SEED"] ?? "") {
            Task { @MainActor in await TaskNotePreviewSeed.attachHeavyFiles(to: noteStore) }
        }
        if inMemoryStore, isUITesting, environment["ATTIC_UI_TEST_SEED"] == "taskfiles" {
            TaskFilesPreviewSeed.pending = Task { @MainActor in await TaskFilesPreviewSeed.seed(tasks: store) }
        }
        let canvasStore = CanvasStore(container: container)
        let canvasViewDefaults = runtime.isUnitTestHost ? nil : runtime.makeSettingsDefaults()
        if isUITesting,
           !usesCanvasUITestPersistence || environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1" {
            // The real UI host exercises restoration in its own bundle domain;
            // only the explicit start of a test scenario resets that state.
            canvasViewDefaults?.removeObject(forKey: CanvasViewStateArchive.defaultsKey)
        }
        if AtticDraw.isEnabled, !runtime.isUnitTestHost { DrawPageModel.install(container: container, resumeDefaults: isRunningTests ? nil : runtime.makeSettingsDefaults()) }
        let canvasSession = CanvasSession(
            store: canvasStore,
            viewStateDefaults: canvasViewDefaults
        )
        let noteDraft = NoteDraftController(
            noteStore: noteStore,
            sessionDefaults: isRunningTests ? nil : runtime.makeSettingsDefaults(),
            recoveryURL: runtime.noteRecoveryURL
        )
        let uiState = PanelUIState(resumeDefaults: isRunningTests ? nil : runtime.makeSettingsDefaults())
        noteDraft.pages.didFollowNoteLink = { [weak uiState] in uiState?.selectSection(.notes) }
        // The Tasks page's page and views across relaunch (L7), in the
        // identity's own defaults; a UI test starts from none.
        let tasksMemory = runtime.isUnitTestHost ? nil : TasksPageMemory(defaults: runtime.makeSettingsDefaults())
        if isUITesting, let tasksMemory {
            TasksPageMemory.removedKeys.forEach { tasksMemory.defaults.removeObject(forKey: $0) }
        }
        let loginItemService = LoginItemService()
        // Local-only disables cloud services, not authenticated loopback MCP.
        // Each bundle identity owns its credential; previews never reuse Daily's.
        // Both kinds of test host avoid Keychain. In normal use, credential
        // loading starts only after opt-in and runs away from the main thread.
        let library = AtticLibrary(tasks: store, notes: noteStore, canvases: canvasStore)
        // The Notes page records its library actions (pin, duplicate,
        // delete) on the app's one undo route.
        noteDraft.pages.attachUndoRoute(library.undo)
        noteDraft.pages.workspaceTaskStore = store
        let shellTools = AgentShellTools()
        let agentTools = AgentTaskTools(
            store: store, noteStore: noteStore, library: library,
            settingsTools: AgentSettingsTools(settings: settings, loginItemService: loginItemService, undo: library.undo)
        )
        // Slice 2: the workspace tools run through the app's task-note pages.
        agentTools.notesController = { [weak noteDraft] in noteDraft?.pages }
        let agentChat = uiState.agentChat
        let calendarSource = CalendarEventSources.makeDefault(environment: runtime)
        agentChat.weekDays = { [weak store, weak calendarSource] day in
            let week = AgentChatModel.emptyWeek(holding: day)
            let events: [CalendarEvent]
            if let calendarSource, calendarSource.accessState == .granted,
               let first = week.first?.day, let last = week.last?.day,
               let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: last) {
                events = calendarSource.events(in: DateInterval(start: first, end: end))
            } else { events = [] }
            return AgentChatModel.week(holding: day, dueDays: store?.tasks.compactMap(\.dueDay) ?? [],
                                       events: events)
        }
        let agentActions = AgentActions(
            tasks: agentTools,
            calendarSource: calendarSource,
            calendarWriter: try? CalendarEventWriters.makeDefault(undoRoute: library.undo, environment: runtime),
            draw: DrawLibraryHub.activeStore,
            openPage: { [weak uiState] page in
                guard let uiState else { return false }
                let section: PanelSection
                switch page {
                case .tasks: section = .tasks
                case .notes: section = .notes
                case .calendar: section = .calendar
                case .draw: section = .canvas
                }
                uiState.selectSection(section)
                return uiState.selectedSection == section
            }
        )
        let agentHandler = MCPRequestHandler(tools: agentTools, shellTools: shellTools, actions: agentActions)
        let agentServer: AgentServer
        if runtime.usesEphemeralAgentCredential {
            agentServer = AgentServer(port: settings.agentServerPort,
                                      bearerToken: (try? AgentAccessTokenStore.generateToken()) ?? "",
                                      handler: agentHandler)
        } else {
            agentServer = AgentServer(port: settings.agentServerPort, handler: agentHandler)
        }
        let agentRunner = AgentRunEngine(
            selectedBackend: { [weak settings] in settings?.inAppAgentBackend ?? .claude },
            tools: { AgentRunMCPServer.live(server: agentServer) },
            journalURL: runtime.usesEphemeralAgentCredential
                ? runtime.galleryScratchRoot.appendingPathComponent("AgentThread.json")
                : runtime.applicationSupportURL?.appendingPathComponent("AtticAgentThread.json"),
            undo: { id in
                let report = try await agentServer.undoFinishedAgentChangeSet(id: id)
                if !report.failures.isEmpty || report.remaining != nil {
                    throw AgentActionsError.invalid(
                        report.failures.isEmpty ? "Some changes could not be undone."
                            : report.failures.joined(separator: "; ")
                    )
                }
            }
        )
        agentChat.connect(agentRunner)
        #if DEBUG
        if isUITesting, let script = environment["ATTIC_UI_TEST_CHAT"] { agentChat.runUITestingScript(script) }
        #endif
        // Built before the window so Settings observes the same hot key it
        // reports on; its action is bound once `self` exists.
        // The combination Settings chose (round 10: the recorder).
        let newTaskHotKey = GlobalHotKey(combination: settings.quickCaptureShortcut)
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
            uiState: uiState,
            tasksMemory: tasksMemory
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
        // Phase 3: deleted tasks that own notes are purged through the
        // coordinated path, through any open task page (§ 2.7.2).
        // Weak: the library must never keep an unshown coordinator's stores
        // and editors alive.
        library.taskNotePurge = { [weak store, weak noteDraft] cutoff, confirmed, confirmedNotes in
            guard let store, let noteDraft else { return [] }
            return await TaskNotePurge.run(tasks: store, notes: noteDraft.pages, before: cutoff, confirmed: confirmed, confirmedNotes: confirmedNotes).removedTaskIDs
        }
        self.loginItemService = loginItemService
        self.settingsWindowController = settingsWindowController
        self.agentServer = agentServer
        self.agentRunner = agentRunner
        self.newTaskHotKey = newTaskHotKey
        cleanupService = DailyCleanupService(
            store: store,
            purgeRecentlyDeleted: { now, calendar in
                library.purgeExpired(now: now, calendar: calendar)
                // Draw's rows go after the same 30 days.
                _ = DrawRecentlyDeleted.purgeExpired(store: DrawLibraryHub.activeStore, now: now, calendar: calendar)
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
        // A timed hide or reveal about to happen: a Genie hide animation
        // prepares its snapshot ahead of it.
        hoverMonitor.onVisibilityChangeExpected = { [weak panelController] expected in
            panelController?.prepareForExpectedVisibilityChange(expected)
        }
        agentPresenter = PanelAgentPresenter(
            uiState: uiState, store: store, noteStore: noteStore,
            canvasSession: canvasSession, noteDraft: noteDraft,
            reveal: { [weak hoverMonitor] section in
                hoverMonitor?.revealProgrammatically(section: section, takesKeyboard: false) ?? .refused(.noScreen)
            }
        )
        newTaskHotKey.action = { [weak self] in self?.showNewTask() }
        shellTools.presenter = agentPresenter
        pinObservation = uiState.$isPanelPinned
            .removeDuplicates()
            .sink { [weak self] pinned in self?.isPanelPinned = pinned }
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
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_PINNED"] == "1" { uiState.isPanelPinned = true }
            // Capture seam: `ATTIC_UI_TEST_SKIP_FILE_MIGRATION=1` shows the
            // seeded rows as they were before the migration.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SEED"] == "taskfiles",
               ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SKIP_FILE_MIGRATION"] != "1" { runTaskFileMigration() }
            else if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SEED"] == "taskfiles" {
                Task { @MainActor [weak self] in await TaskFilesPreviewSeed.pending?.value; self?.store.refresh() }
            }
            // Phase 3 slice 0b's seeded entry point: a task's note over Notes.
            if let scenario = TaskNotePreviewSeed.requested(), let taskID = TaskNotePreviewSeed.seeded[scenario] {
                uiState.selectSection(.notes)
                uiState.openTaskNoteID = taskID
            }
            // LSUIElement apps do not necessarily become active when XCTest
            // launches them. Activate the real process before presenting the
            // key panel so AppKit, not a test-only model shortcut, owns mouse
            // and keyboard delivery through the installed UI hierarchy.
            // Key-window check seam: reveal the panel the way the corner
            // does (not key, app not activated). The UI test then brings
            // another app forward and clicks the panel, as a person would,
            // and reads the key state the panel exposes to UI tests.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_NONKEY_REVEAL"] == "1" {
                // Capture seams: the page to show (tasks, notes, canvas), and
                // a time after which the panel takes the keyboard as a click
                // would, for hands-off captures of both looks.
                let environment = ProcessInfo.processInfo.environment
                if let page = (environment["ATTIC_UI_TEST_PAGE"] ?? AtticDropdownCaptureSeam.current?.page)
                    .flatMap(PanelPage.init(rawValue:)) {
                    uiState.selectSection(page.section)
                }
                // AppKit makes a visible window key when launching finishes,
                // so the reveal waits until launch is over, as a corner reveal
                // always does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.hoverMonitor.keepVisibleForUITesting(makeKey: false)
                }
                #if DEBUG
                // Capture seam: every scrollable list or text in the panel
                // scrolled to its middle, so content sits under the controls.
                if let delay = environment["ATTIC_UI_TEST_SCROLL_MIDDLE"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        for window in NSApp.windows where window.isVisible {
                            AtticCaptureScroll.scrollToMiddle(in: window.contentView)
                        }
                    }
                }
                #endif
                if let delay = environment["ATTIC_UI_TEST_KEY_AFTER"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.panelController.makeKeyForCapture()
                    }
                }
                #if DEBUG
                // Capture seams for what Settings changes while a note is open
                // (A39 F08 and the appearance switch): `<seconds>:<width>` and
                // `<seconds>:<light|dark|system>`, set on the same `AppSettings`
                // properties the Settings controls write.
                for spec in (environment["ATTIC_UI_TEST_SET_WIDTH"] ?? "").split(separator: ",") {
                    let parts = spec.split(separator: ":")
                    guard parts.count == 2, let delay = Double(parts[0]), let width = Double(parts[1]) else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.settings.panelContentSize = width }
                }
                for spec in (environment["ATTIC_UI_TEST_SET_APPEARANCE"] ?? "").split(separator: ",") {
                    let parts = spec.split(separator: ":")
                    guard parts.count == 2, let delay = Double(parts[0]), let mode = AppearancePreference(rawValue: String(parts[1])) else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.settings.appearance = mode }
                }
                #endif
                return
            }
            NSApp.activate()
            if let performanceRoot,
               ProcessInfo.processInfo.environment["ATTIC_PERF_PROBE"] == "1" {
                // `--corner`: a probe on a Mac in use can move the reveal
                // away from the corner the person's pointer visits.
                if let corner = ProcessInfo.processInfo.environment["ATTIC_PERF_CORNER"].flatMap(ScreenCorner.init(rawValue:)) {
                    settings.corner = corner
                }
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
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["ATTIC_PERF_SMOOTH"] == "1",
                       Bundle.main.bundleIdentifier == "com.taha.Attic.preview.phasex" {
                        let probe = SmoothPerformanceProbe(root: performanceRoot, notes: noteStore,
                            tasks: store, pages: noteDraft.pages,
                            reveal: { [weak self] section in self?.hoverMonitor.revealForPerformanceProbe(section: section) },
                            hide: { [weak self] in
                                _ = self?.hoverMonitor.hideForPerformanceProbe { _ in }
                            })
                        signal(SIGUSR1, SIG_IGN)
                        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
                        source.setEventHandler { probe.advance() }
                        performanceSignalSource = source
                        source.resume()
                        PerformanceProbe.writePhase("smooth_ready", root: performanceRoot)
                        return
                    }
                    #endif
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
                        + (extra ? ["warm_open", "switches_done", "typing_done", "tasks_hidden", "tasks_warm_open", "scroll_done"] : [])
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
                        case 10:
                            // Round 3: scrolling the 500-task Now list, one
                            // 40 pt step at a time, each drawn before the next.
                            later(1) {
                                for duration in self.panelController.scrollForPerformanceProbe(steps: 120, step: 40) {
                                    PerformanceSignposts.recordProbeTiming("ListScrollStep", milliseconds: duration)
                                }
                                write("scroll_done")
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
            #if DEBUG
            // The hide-animation bench (debug builds of preview identities
            // only): signal-driven hides, reveals and swipes.
            if let mode = ProcessInfo.processInfo.environment["ATTIC_MOTION_BENCH_MODE"].flatMap(PanelHideAnimation.init(storedValue:)) {
                settings.hideAnimation = mode
            }
            // The page-switch bench (preview identities only): with
            // `ATTIC_PAGE_BENCH=1`, SIGINFO switches to the next page in
            // order as any route does, and prints when, for the frame
            // monitor's log (`ATTIC_FRAME_MONITOR`).
            if ProcessInfo.processInfo.environment["ATTIC_PAGE_BENCH"] == "1",
               Bundle.main.bundleIdentifier?.hasPrefix("com.taha.Attic.preview.") == true {
                // First SIGINFO reveals Tasks; then all directed page pairs,
                // returning to Tasks for another lap.
                // Opt-in only: the original sequential bench remains unchanged.
                let allPairs: [PanelPage] = [.notes, .tasks, .calendar, .tasks,
                                             .canvas, .notes, .calendar, .notes,
                                             .canvas, .calendar, .canvas, .tasks]
                let measuresPairs = ProcessInfo.processInfo.environment["ATTIC_PAGE_BENCH_ALL_PAIRS"] == "1"
                var pairIndex = 0
                signal(SIGINFO, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let pages = PanelPage.allCases
                        let index = pages.firstIndex(of: PanelPage(self.uiState.selectedSection)) ?? 0
                        let next: PanelPage
                        if measuresPairs {
                            // The first signal reveals Tasks. Every later
                            // signal switches to one of the twelve targets,
                            // including the next lap's Tasks -> Notes.
                            next = pairIndex == 0 ? .tasks : allPairs[(pairIndex - 1) % allPairs.count]
                            pairIndex += 1
                        } else {
                            next = pages[(index + 1) % pages.count]
                        }
                        print(String(format: "ATTIC_PAGE_SWITCH %.4f %@", CACurrentMediaTime(), next.rawValue))
                        if measuresPairs && self.panelController.isPanelVisible {
                            // The actual Tall-island click route, including
                            // Notes' leave checkpoint. The reveal probe below
                            // would refresh the store and show the panel on
                            // every switch, inflating the measured stall.
                            self.uiState.island.click(next)
                        } else {
                            self.hoverMonitor.revealForPerformanceProbe(section: next.section)
                        }
                    }
                }
                source.resume()
                // SIGWINCH wakes the island and lets it settle as when the
                // pointer leaves 1.2 s later; SIGPROF opens or folds the card.
                signal(SIGWINCH, SIG_IGN)
                let island = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
                island.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let model = self?.uiState.island else { return }
                        print(String(format: "ATTIC_ISLAND_WAKE %.4f", CACurrentMediaTime()))
                        model.wake()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            MainActor.assumeIsolated {
                                model.track(pointer: CGPoint(x: -100_000, y: -100_000), rest: .zero, awake: .zero)
                            }
                        }
                    }
                }
                island.resume()
                signal(SIGPROF, SIG_IGN)
                let card = DispatchSource.makeSignalSource(signal: SIGPROF, queue: .main)
                card.setEventHandler {
                    MainActor.assumeIsolated {
                        print(String(format: "ATTIC_CARD_TOGGLE %.4f", CACurrentMediaTime()))
                        NotificationCenter.default.post(name: .atticBenchToggleComposer, object: nil)
                    }
                }
                card.resume()
                pageSwitchBench = source
                benchSources = [island, card]
            }
            hideMotionBench = PanelHideMotionBench.installIfRequested(
                isVisible: { [weak self] in self?.panelController.isPanelVisible ?? false },
                hide: { [weak self] done in _ = self?.hoverMonitor.hideForPerformanceProbe { _ in done() } },
                reveal: { [weak self] in
                    guard let self else { return }
                    self.hoverMonitor.revealForPerformanceProbe(section: self.uiState.selectedSection)
                },
                mode: { [weak self] in self?.settings.hideAnimation.rawValue ?? "?" },
                prepare: { [weak self] hiding, delay in
                    self?.panelController.prepareForExpectedVisibilityChange((hiding, delay))
                }
            )
            hideMotionBench?.trace = { [weak self] in
                guard self?.settings.hideAnimation.usesGenieMesh == true else { return [:] }
                return [
                    "snapshot_ms": PanelHideMotionTrace.snapshotMilliseconds,
                    "mask_us": PanelHideMotionTrace.maskMicroseconds,
                    "material_layers": PanelHideMotionTrace.materialLayers,
                    "glass_standins": PanelHideMotionTrace.glassStandIns,
                    "glass_left_out": PanelHideMotionTrace.glassLeftOut
                ]
            }
            hideMotionBench?.acceptsInput = { [weak self] in self?.panelController.acceptsInputForProbe ?? false }
            hideMotionBench?.progress = { [weak self] in self?.panelController.displayedProgressForProbe ?? 0 }
            hideMotionBench?.swipeTrace = {
                defer { PanelSwipeTrace.events = []; PanelSwipeTrace.release = [:] }
                return ["updates": PanelSwipeTrace.events, "release": PanelSwipeTrace.release]
            }
            hideMotionBench?.beginCost = { [weak self] in self?.panelController.alternateBeginCostForProbe ?? 0 }
            #endif
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_HOVER_MONITOR"] == "1" {
                hoverMonitor.start()
                hoverMonitor.revealProgrammatically(openComposer: true, section: .tasks)
            } else {
                hoverMonitor.keepVisibleForUITesting()
            }
            // Capture seam: open Settings on the remembered section (pass
            // `-AtticSettings.selectedSection <section>`) for screenshots.
            if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.async { [weak self] in self?.openSettings() }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await WorkspaceLegacyBridge.coordinator(for: self.store.container).finishLaunchOfferingRecovery(
                    offers: { self.noteDraft.pages.recoverAtLaunch() },
                    sweep: {
                        // Only registered, reconciled persistent stores judge files.
                        if !self.isRunningTests { await self.store.sweepUnreferencedAttachmentStorage() }
                    })
            } catch { self.noteDraft.pages.recoveryStartupFailed(error) }
            if !self.isRunningTests { self.runTaskFileMigration() }
        }
        if settings.quickCaptureEnabled { newTaskHotKey.register() }
        // Settings › General › Quick Capture (round 10): a new combination
        // or the switch releases the old claim and makes the new one.
        quickCaptureObservation = settings.$quickCaptureShortcut
            .combineLatest(settings.$quickCaptureEnabled)
            .dropFirst()
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] combination, enabled in
                self?.newTaskHotKey.apply(combination, enabled: enabled)
            }
        hoverMonitor.start()
        if !isRunningTests {
            agentAccessObservation = settings.$isAgentAccessEnabled.sink { [weak self] isEnabled in
                guard let self else { return }
                agentServer.setExternalAccessEnabled(isEnabled)
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
        if AtticDraw.isEnabled { DrawPageModel.shared.finishLiveInput() } else { canvasSession.cancelActiveInteraction() }
        _ = noteDraft.flush()
        cleanupService.stop()
        hoverMonitor.stop()
        newTaskHotKey.unregister()
        appearanceObservation = nil
        agentAccessObservation = nil
        agentRunner.shutdown()
        agentServer.stop()
        menuNotificationTokens.forEach(NotificationCenter.default.removeObserver)
        menuNotificationTokens.removeAll()
        menuTrackingState = PanelMenuTrackingState()
        uiState.setInteractionLock(.menuTracking, isActive: false)
        hasStarted = false
    }

    func prepareForTerminationDurably() async -> Bool {
        let calendar = await CalendarDraftTerminationRegistry.shared.prepareForTerminationResult()
        if case let .refused(owner) = calendar {
            switch owner {
            case .floating:
                if !panelController.pullOut.bringForward(.calendar, switchesDocked: false) {
                    hoverMonitor.revealProgrammatically(section: .calendar)
                }
            case .docked:
                if panelController.pullOut.state.isOut(.calendar),
                   let floating = panelController.pullOut.panel(for: .calendar) {
                    _ = panelController.pullOut.bringForward(.calendar, switchesDocked: false)
                    floating.toasts.show(
                        String(localized: "The Calendar draft in the docked panel couldn't be saved. Dock Calendar to edit it."),
                        actionTitle: String(localized: "OK"), answersUndoKey: false, action: {})
                } else {
                    hoverMonitor.revealProgrammatically(section: .calendar)
                }
            }
            return false
        }
        guard await noteDraft.prepareToLeaveDurably(.quit) else {
            hoverMonitor.revealProgrammatically(section: .notes)
            return false
        }
        if AtticDraw.isEnabled {
            // Draw's pending edits settle first; a held one stops quit and
            // shows the page with its notice (the old Canvas is left alone).
            guard await DrawPageModel.shared.prepareToQuit() else {
                hoverMonitor.revealProgrammatically(section: .canvas)
                return false
            }
            return true
        }
        canvasSession.cancelActiveInteraction()
        canvasSession.flushViewState()
        return true
    }

    func prepareForTermination() -> Bool {
        let canTerminate = AppTerminationPreparation.prepare(
            flushNoteDraft: { noteDraft.prepareToLeave(.quit) },
            commitCanvasTermination: {
                if AtticDraw.isEnabled {
                    DrawPageModel.shared.finishLiveInput()
                    DrawPageModel.shared.flushViewportMemory()
                    return
                }
                canvasSession.cancelActiveInteraction()
                canvasSession.flushViewState()
            }
        )
        guard canTerminate else {
            hoverMonitor.revealProgrammatically(section: .notes)
            return false
        }
        if AtticDraw.isEnabled, DrawPageModel.shared.store.hasUnsettledEdits {
            DrawPageModel.shared.retrySave()
            if DrawPageModel.shared.store.hasUnsettledEdits {
                hoverMonitor.revealProgrammatically(section: .canvas)
                return false
            }
        }
        return true
    }

    func showPanel() {
        hoverMonitor.revealProgrammatically()
    }

    func showNewTask() {
        hoverMonitor.revealProgrammatically(openComposer: true, section: .tasks)
    }

    /// The menu bar's Open ▸ Tasks, Notes, Canvas (round 10): the panel on
    /// that page.
    func showPage(_ page: PanelPage) {
        hoverMonitor.revealProgrammatically(section: page.section)
    }

    /// The menu bar's Open ▸ Pin Panel: pinning shows the panel too (a
    /// pinned panel is one that stays open).
    func setPinned(_ pinned: Bool) {
        if uiState.isPanelPinned != pinned { uiState.isPanelPinned = pinned }
        if pinned { showPanel() }
    }

    func showNewNote() {
        hoverMonitor.revealProgrammatically(openComposer: true, section: .notes)
    }

    /// The menu-bar Search: the Tasks page's Done search, focused (⌘K
    /// search arrives with the command palette in a later phase).
    func showSearch() {
        // The panel takes the keyboard, but not for the add bar: a late add
        // bar focus request would take it back from the search field.
        guard hoverMonitor.revealProgrammatically(section: .tasks, focusesAddBar: false) == .shown else { return }
        uiState.requestSearch()
    }

    /// Phase 3 slice 2 (§ 13 "Safe running"): existing task attachments
    /// move into their task's note in the background, once launch recovery
    /// is done. A family whose note is open waits.
    private func runTaskFileMigration() {
        Task { @MainActor [weak self] in
            await TaskFilesPreviewSeed.pending?.value
            guard let self else { return }
            let pages = self.noteDraft.pages
            self.store.fileMigration.onNotesChanged = { [weak pages] in pages?.store.refresh() }
            guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: self.store.container) else { return }
            await self.store.fileMigration.runAtLaunch(tasks: self.store, recovering: pages, isBusy: { [weak pages] root in
                guard let pages else { return true }
                return TaskFilesState.noteIsOpen(root, notes: pages, coordinator: coordinator)
            })
            pages.store.refresh()
            // Capture seam (UI testing): open a seeded family's page
            // (`ATTIC_UI_TEST_TASK_FILES=homepage|venue|taxes|kitchen`).
            if self.isUITesting, let raw = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_TASK_FILES"],
               let sample = TaskFilesPreviewSeed.Sample(rawValue: raw), let id = TaskFilesPreviewSeed.seeded[sample] {
                self.uiState.selectSection(.notes)
                self.uiState.openTaskNoteID = id
            }
        }
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

#if DEBUG
/// The capture seam's scrolling (UI-test launches only).
@MainActor
enum AtticCaptureScroll {
    static func scrollToMiddle(in view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let room = document.frame.height - scroll.contentView.bounds.height
            if room > 40 {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: room * 0.45))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        view.subviews.forEach { scrollToMiddle(in: $0) }
    }
}
#endif
