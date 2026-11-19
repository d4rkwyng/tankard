import AskpassSupport
import Foundation
import Observation
import TankardCore

/// A problem to show without throwing away the data on screen.
public struct StoreError: Equatable, Sendable, Codable {
    public var title: String
    public var detail: String
    /// When brew needed sudo (or the app can't do the step itself): the
    /// command for the user to run in Terminal.
    public var terminalCommand: String?
    /// 0.8.6 (VM test L2): reading brew's status failed (the status bar's
    /// "Last refresh failed", the banner's "Showing the last data Tankard
    /// read"); false for a failed action such as a pin.
    public var fromRefresh: Bool

    public init(title: String, detail: String, terminalCommand: String? = nil, fromRefresh: Bool = false) {
        self.title = title
        self.detail = detail
        self.terminalCommand = terminalCommand
        self.fromRefresh = fromRefresh
    }
}

/// The window's top-level switch.
public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case installed, discover
    /// 0.4: `brew services`.
    case services
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .installed: return String(localized: "Installed")
        case .discover: return String(localized: "Discover")
        case .services: return String(localized: "Services")
        }
    }
}

/// The app's state. One per window.
///
/// - Cache-first, stale-while-revalidate: `start()` shows the cached report
///   at once, then asks brew again if the cache is older than `ttl` (1 h).
/// - A refresh that fails keeps the current data and sets `error`.
/// - Manual refresh runs `brew update` first, through the command queue.
/// - Upgrades go through the same strict FIFO queue. After an upgrade run
///   the store re-reads status (no `brew update`) to reconcile.
/// - No network calls of its own and no telemetry: everything comes from
///   brew and git on this Mac.
@Observable @MainActor
public final class AppStore {
    public struct Dependencies: Sendable {
        /// Builds the brew client (locating brew). Called once, lazily.
        public var makeClient: @Sendable () throws -> BrewClient
        /// Runs queued commands (`brew update`, `brew upgrade`).
        public var streamRunner: StreamingCommandRunning
        public var cache: StatusCache?
        public var logURL: URL?
        public var ttl: TimeInterval
        public var now: @Sendable () -> Date
        /// Discover's data source for this brew. Called when Discover is
        /// first opened, never at launch.
        public var makeCatalog: @Sendable (BrewClient, IntelbrewDetection) -> CatalogProviding
        /// The Mac, for the welcome screen's install options.
        public var hardware: MacHardware
        /// 0.3: show the App Management explainer before the first cask
        /// upgrade or uninstall (the app and demo mode; tests opt in).
        public var appManagementGate: Bool = false
        /// 0.8.1: quits Tankard and starts it again (the app sets it, from
        /// a real bundle only). Nil: no "Relaunch Tankard" (tests, `swift run`).
        /// True when the relaunch helper started (Tankard quits right after).
        public var relaunch: (@MainActor @Sendable () -> Bool)?
        /// 0.8.1: the welcome sheet's App Management check (Onboarding.swift):
        /// the write test, and whether a candidate app exists. Demo fakes both.
        public var appManagementProbe: @Sendable (String) -> AppManagementProbe.Result = { AppManagementProbe.run(appPath: $0) }
        public var appManagementProbeExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        /// 0.3: bottle-or-compile, shared with Discover.
        public var classifier = CompileClassifier()
        /// 0.3: Intelbrew's build times (Intelbrew mode only). When set,
        /// `classifier` should use it as its estimator.
        public var buildTimes: BuildTimeSource?
        /// 0.4: where the vulnerability scan and sizes are cached (nil: memory only).
        public var insightsCache: InsightsCache?
        /// 0.5: the Auto-update log file (nil: memory only).
        public var autoUpdateLogURL: URL?
        /// 0.6: the History file (nil: memory only).
        public var historyURL: URL?
        /// 0.7: the restore points folder (nil: memory only).
        public var restorePointsURL: URL?
        /// 0.8: Adopt Apps' scan (nil: the real cask.json and disk).
        public var adoptLoader: AdoptLoader?
        /// 0.8: whether the background `brew update` may run at all. Only the
        /// real app (`live()`) turns it on: never demo mode, tests opt in.
        public var backgroundUpdates = false
        /// 0.8, e2e only: the background update's interval in seconds instead
        /// of Settings' hours (Scripts/e2e.sh's background scenario).
        public var backgroundUpdateInterval: TimeInterval?
        /// 0.8.5: a scheduled `brew update` (background update, the
        /// notification check, auto-update's) is stopped after this long.
        public var scheduledUpdateTimeout: TimeInterval = 15 * 60
        /// 0.8: download progress in the sheet: builds the watcher for a
        /// session's brew (nil: none, as in demo mode). `live()` sets
        /// `DownloadMonitor.live`.
        public var downloadMonitor: (@Sendable (BrewClient, [String: String]) -> DownloadMonitor?)?
        /// Check for Tankard Updates…: GitHub's latest release, fetched only
        /// when asked. nil: the item is disabled (demo mode, tests).
        public var updateFeed: UpdateFeed?
        /// 0.8.3: a sheet step that fails on brew's lock waits for it and
        /// runs again (nil: it fails, as before; `live()` sets `.live`).
        public var lockWait: BrewLockWait?
        /// The running app, to tell a cask install from a zip download.
        public var bundlePath: String = Bundle.main.bundlePath
        /// 0.8.3: the sudo password dialog (Tankard.app/Contents/MacOS/
        /// tankard-askpass), set as SUDO_ASKPASS for cask changes. nil: none
        /// (tests, `swift run`, demo mode); brew's sudo then fails as before
        /// and the sheet offers the Terminal command.
        public var askpassHelper: String?
        /// 0.8.3: finds the running helper and yields focus to it (the app
        /// sets it with AppKit; nil: no watching).
        public var askpassFocus: AskpassFocus?
        /// Screenshots only: act as if this cask installed the running app.
        public var selfCaskOverride: Package?
        /// 0.8.4: the brew.env files as brew reads them now (the live app
        /// re-reads them from disk; default: the client's, read at launch).
        /// Checked for a foreign SUDO_ASKPASS (ForeignAskpass) when a sheet
        /// starts and again right before each sudo-capable step.
        public var brewEnvFiles: @Sendable (BrewClient) -> [(String, [String: String])] = { $0.sources.brewEnvFiles }
        /// 0.8.3: whether brew's Caskroom has a tankard cask (path given).
        public var selfCaskroomExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        /// 0.8.5: the Mac Pro 6,1 Electron check (ElectronGPU.swift). Off
        /// (reads nothing) unless set: `live()`, or the demo's hook.
        public var electronGPU: ElectronGPUProbe = .disabled
        /// 0.8.6 (walkthrough M4): when brew last changed what is installed
        /// (the newest modification time of the Cellar, Caskroom, opt and
        /// var/homebrew/linked folders), for a re-read when that is newer
        /// than the report. nil (tests, demo): never.
        public var homebrewChangedAt: (@Sendable (BrewClient) -> Date?)?
        /// 0.8.5 (M3): a Brewfile's text, for its taps' URLs (demo: a fixed one).
        public var readBrewfile: @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }

        public init(makeClient: @escaping @Sendable () throws -> BrewClient,
                    streamRunner: StreamingCommandRunning,
                    cache: StatusCache?,
                    logURL: URL?,
                    ttl: TimeInterval = 3600,
                    now: @escaping @Sendable () -> Date = { Date() },
                    makeCatalog: (@Sendable (BrewClient, IntelbrewDetection) -> CatalogProviding)? = nil,
                    hardware: MacHardware = .current()) {
            self.makeClient = makeClient
            self.streamRunner = streamRunner
            self.cache = cache
            self.logURL = logURL
            self.ttl = ttl
            self.now = now
            self.makeCatalog = makeCatalog ?? Self.liveCatalog
            self.hardware = hardware
        }

        /// Intelbrew mode (or any brew told not to use the API) searches the
        /// local taps; otherwise formulae.brew.sh and the user's own taps.
        public static let liveCatalog: @Sendable (BrewClient, IntelbrewDetection) -> CatalogProviding = { client, detection in
            if detection.detected || client.sources.effective(Intelbrew.noAPIKey) != nil {
                return TapCatalog(client: client, detection: detection)
            }
            // 0.8.6 (H1): plus the user's own taps.
            return UserTapsCatalog(api: APICatalog(fetcher: APIFetcher(), platform: client.platform),
                                   client: client, detection: detection)
        }

        /// The real thing: brew from its standard locations (or
        /// TANKARD_BREW), posix_spawn, the user's cache and log paths.
        /// 0.8.8 (security review #1): the app runs only a standard brew. A
        /// TANKARD_BREW naming anything else (a dev build's test switch; a
        /// release never sees it, TestHooks) means "no brew found".
        public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Dependencies {
            let override = environment["TANKARD_BREW"].flatMap { $0.isEmpty ? nil : $0 }
            var d = Dependencies(
                makeClient: { try BrewClient.locate(override: override, standardOnly: true) },
                // 0.8.8 (security review #3): a step that may need sudo gets
                // the password helper's ticket for its brew process.
                streamRunner: StreamingProcessRunner(onSpawn: { pid, env in AskpassTicket.issue(pid: pid, environment: env) }),
                cache: StatusCache(url: StatusCache.defaultURL),
                logURL: AppPaths.upgradeLog
            )
            d.appManagementGate = true
            d.insightsCache = InsightsCache(url: InsightsCache.defaultURL)
            d.autoUpdateLogURL = AutoUpdateLog.defaultURL
            d.historyURL = HistoryLog.defaultURL
            d.restorePointsURL = RestorePointStore.defaultDirectory
            d.backgroundUpdates = true
            d.downloadMonitor = { client, env in DownloadMonitor.live(client: client, env: env) }
            d.askpassHelper = AdminPassword.liveHelper()
            d.brewEnvFiles = { EnvironmentSources.load(prefix: $0.installation.prefix, process: $0.sources.process).brewEnvFiles }
            d.updateFeed = .live()
            d.lockWait = .live
            d.electronGPU = .live
            d.homebrewChangedAt = { HomebrewChanges.latest(client: $0) }
            let times = BuildTimeSource.live()
            d.buildTimes = times
            d.classifier = CompileClassifier(estimator: times)
            return d
        }
    }

    // MARK: state

    public internal(set) var report: StatusReport? {
        // 0.8.5: a no-op unless the casks changed (and on an affected Mac).
        didSet { electron.update(packages: report?.packages ?? []) }
    }
    /// Where `report` came from on screen: the disk cache or a live read.
    public private(set) var reportFromCache = false
    public private(set) var isRefreshing = false
    /// How many status reads have ended (any outcome). Tests wait on it for
    /// the read a finished session starts (in a Task, so `isRefreshing` is
    /// still false right after `isFinished`).
    @ObservationIgnored private(set) var refreshesCompleted = 0
    /// What a running refresh is doing ("Running brew update…").
    public private(set) var refreshPhase: String?
    public internal(set) var error: StoreError?
    /// 0.8.8 (gauntlet 26, P3): the last `brew update` failure, until the
    /// next update (manual, scheduled or background) or Dismiss. A read
    /// that runs no update (window to the front, after an install) used to
    /// clear it, so the status bar said "Updated just now" alone while the
    /// catalog was still the old one.
    /// 0.8.8 (final gauntlet, bug 3): saved in the settings, so a relaunch
    /// keeps it too (`UpdateFailureRecord`).
    @ObservationIgnored var updateFailure: StoreError? {
        didSet { settings.lastUpdateFailure = updateFailure.flatMap { UpdateFailureRecord(error: $0, at: deps.now()).encoded() } }
    }
    public private(set) var upgrade: UpgradeSession?
    /// The activity (plan, session, App Management pages) is showing:
    /// the main window's sheet, or (0.8.5) the progress panel a menu-bar
    /// Upgrade opens (`activityPresentation`). Hiding it puts the next one
    /// back on the main window.
    /// 0.8.6 (UI details M2): the main window's content height, for
    /// sheets taller than a small window (`SheetHeight.fit`). nil before
    /// the window has laid out.
    public var sheetRoom: Double?
    /// 0.8.6 (UI details M8): the main window's content width (the detail
    /// pane narrows in a narrow window, `DetailPaneWidth`).
    public var windowWidth: Double?

    public var showUpgradeSheet = false {
        didSet {
            if !showUpgradeSheet, activityPresentation != .mainWindowSheet { activityPresentation = .mainWindowSheet }
            // The panel's notes page goes with it (Close, a relaunch).
            if !showUpgradeSheet, progressPanelNotes != nil { progressPanelNotes = nil }
        }
    }
    /// 0.8.5: where the activity shows (ProgressPanel.swift).
    public internal(set) var activityPresentation: ActivityPresentation = .mainWindowSheet
    /// 0.8.5: bumped when the model needs the main window open (a
    /// progress-panel run that upgraded Tankard itself: the relaunch
    /// question lives there). The app opens the window on each change.
    public internal(set) var mainWindowRequests = 0
    /// 0.8.5: how long a progress panel stays up after a clean finish.
    @ObservationIgnored public var progressPanelAutoClose: Duration = .seconds(2)
    /// 0.8.5 (review): bumped when the progress panel must come to the
    /// front even though it is already open (the menu-bar panel's Show
    /// Upgrade Progress, the panel may be behind other windows).
    public internal(set) var progressPanelFrontRequests = 0
    /// 0.8.5 (review): where the current session belongs: the progress
    /// panel (a menu-bar Upgrade) or the main window. Unlike
    /// `activityPresentation` it stays while the panel is hidden, so a
    /// hidden panel run still notifies, and keeps its notes, at the end.
    @ObservationIgnored var runHome: ActivityPresentation = .mainWindowSheet
    /// 0.8.5 (review): the post-install notes of a progress-panel run,
    /// shown as the panel's last page (never handed to a main window
    /// that may be closed or behind other apps).
    public internal(set) var progressPanelNotes: PostInstallNotes?
    /// 0.8.5 (review): the panel's close button mid-run asks once per
    /// launch whether to close it ("Closing this window doesn't stop the
    /// upgrade"). True while that question is up.
    public var progressPanelHideQuestion = false
    @ObservationIgnored var progressPanelHideExplained = false
    /// 0.8.3: an upgrade run a quit interrupted, offered at the next launch (QuitGuard.swift).
    public internal(set) var interruptedRun: InterruptedRunOffer?
    /// 0.8.3: the running session is ending because Tankard quits.
    var quittingMidRun = false
    /// Tankard ▸ Check for Tankard Updates…: the sheet and where the check stands.
    public var selfUpdate: SelfUpdateCheck?
    public var showSelfUpdate = false
    /// The running Tankard was just upgraded through brew: offer to relaunch.
    public var offerRelaunch = false
    /// 0.8.3: brew replaced this app's own bundle (the tankard cask
    /// upgraded). This process is the old build running from files that are
    /// gone, so from here on it does as little as possible: the relaunch
    /// offer and nothing else (no re-read, no background `brew update`, no
    /// new brew commands, no post-install notes).
    public internal(set) var selfReplaced = false
    /// Whether brew was found and runs (the welcome screen otherwise).
    public private(set) var homebrewState: HomebrewState = .checking
    /// The package the uninstall confirmation is open for.
    public var uninstallCandidate: Package?
    /// 0.8: the uninstall sheet's "Also remove these" (its no-longer-needed dependencies).
    public var uninstallRemovesOrphans = true
    /// Discover's store, made when Discover is first opened.
    public private(set) var discover: DiscoverStore?
    /// 0.3: the upgrade sheet's first page when something would compile.
    public internal(set) var upgradePlan: UpgradePlan?
    /// 0.3: the App Management sheet (shown in the activity sheet).
    public private(set) var appManagementPrompt: AppManagementPrompt?
    /// 0.8.1: the "Run again" offer after a relaunch (waits for a click).
    public internal(set) var appManagementResume: AppManagementResume?
    /// 0.8.3: "Relaunch Tankard" started the helper; this instance quits.
    @ObservationIgnored private(set) var relaunching = false
    /// 0.8.8: Tankard is quitting (`prepareForTermination`): no new sheet.
    @ObservationIgnored public private(set) var terminating = false
    /// 0.3: the Cleanup sheet's state.
    public private(set) var cleanup: CleanupStore?
    public var showCleanupSheet = false
    /// 0.3: bumped when build times arrive, so warnings re-render.
    public private(set) var buildTimesRevision = 0
    /// 0.4a: a pin, unpin or service command running through the queue
    /// (its display form). See Pins.swift and ServicesStore.swift.
    public internal(set) var quickAction: String?
    /// 0.4: why a click on Pin, Unpin, Start, Stop or Restart did nothing
    /// (brew was busy, or not ready). Shown in the status bar for a few
    /// seconds. See `runQuick`.
    public internal(set) var busyNotice: String?
    @ObservationIgnored var busyNoticeToken = 0
    /// 0.8.2: what the last Refresh / Check Now found ("3 new upgrades"),
    /// shown in the status bar for a few seconds. See UserCheckFeedback.swift.
    public internal(set) var checkNote: String?
    @ObservationIgnored var checkNoteToken = 0
    /// 0.8.2: posts a notification for a check the user started while the
    /// window wasn't in front (the app's SystemNotifier; nil in tests).
    @ObservationIgnored public var notifier: UpgradeNotifying?
    /// 0.4a: the Services tab's state, made when it is first opened.
    public internal(set) var services: ServicesStore?
    /// 0.4a: the Homebrew menu's sheet (revert to standard Homebrew, uninstall).
    public var managementSheet: HomebrewManagement.Kind?
    /// 0.5: the Auto-update log sheet on the main window.
    public var showAutoUpdateLog = false
    /// 0.6: Health, History or Remove Unused Dependencies (HealthStore.swift).
    public var toolSheet: ToolSheet?
    /// 0.8.1: the first-launch welcome's state, while it shows.
    public internal(set) var onboarding: OnboardingState?
    public internal(set) var health: HealthStore?
    public internal(set) var autoremove: AutoremoveStore?
    /// 0.8: a background `brew update` is queued or running (the status
    /// bar's "Checking for updates…"). See AppStore+BackgroundUpdate.swift.
    public internal(set) var backgroundUpdating = false
    /// 0.8: when the last background `brew update` failed (offline…), so the
    /// next try waits instead of failing every few seconds.
    @ObservationIgnored var lastBackgroundUpdateFailure: Date?
    /// 0.8: background `brew update`s this launch ran (the e2e harness counts them).
    @ObservationIgnored public internal(set) var backgroundUpdateRuns = 0
    /// 0.8.5: how long after `lastBackgroundUpdateFailure` the next try waits
    /// (ScheduledQuietReason.retryAfter; an hour for other failures).
    @ObservationIgnored var backgroundFailureRetry: TimeInterval = BackgroundUpdatePolicy.failureRetry
    /// 0.8.5: sleep and network, for scheduled checks (ScheduledChecks.swift).
    @ObservationIgnored public let system: ScheduleConditions
    /// 0.8.5: the queued id of the scheduled `brew update` running now.
    @ObservationIgnored var scheduledUpdateCommand: UUID?
    /// 0.8.5: History entries to mark quiet once they arrive from the queue.
    @ObservationIgnored var pendingQuiet: [UUID: ScheduledQuietReason] = [:]
    /// 0.8.5: History entries to mark as builds from source once they arrive.
    @ObservationIgnored var pendingBuilt: Set<UUID> = []
    /// 0.8.6 (VM test M1): History entries to mark as upgraded once they arrive.
    /// History entry id → whether brew's error named another package.
    @ObservationIgnored var pendingUpgradedAnyway: [UUID: Bool] = [:]
    /// 0.8.8: History entries to mark "upgraded earlier in this run" once
    /// they arrive (entry id → the earlier step's package).
    @ObservationIgnored var pendingUpgradedEarlier: [UUID: String] = [:]
    /// 0.8.6 (L7): the restore point saved before each upgrade session.
    @ObservationIgnored var sessionRestorePoints: [UUID: RestorePoint.ID] = [:]
    /// 0.8.5: how the last scheduled `brew update` went (auto-update reads it).
    @ObservationIgnored public internal(set) var lastScheduledUpdate: ScheduledUpdateResult?

    public var tab: MainTab = .installed
    public var filter: PackageFilter = .all
    public var search = ""
    public var selection: Package.ID?
    /// 0.8.3: bumped when something asks the Installed table to scroll its
    /// selection into view (a menu-bar package row; see MenuBarNavigation).
    public internal(set) var revealRequest = 0

    @ObservationIgnored public let deps: Dependencies
    @ObservationIgnored public let queue: CommandQueue
    /// 0.3 settings (menu bar, notifications, the App Management flag).
    @ObservationIgnored public let settings: AppSettings
    /// 0.4: vulnerabilities, sizes, caveats' notes, self-updating apps.
    @ObservationIgnored public let insights: InsightsStore
    /// 0.5: automatic updates (settings, log, the run itself).
    @ObservationIgnored public let autoUpdate: AutoUpdater
    /// 0.6: every queued command, recorded by the queue's observer.
    @ObservationIgnored public let history: HistoryLog
    /// 0.6: Brewfile export, check and restore.
    @ObservationIgnored public let brewfile = BrewfileStore()
    /// 0.7: the Taps sheet (TapsStore.swift).
    @ObservationIgnored public let taps = TapsStore()
    /// 0.8: the Adopt Apps sheet (AdoptStore.swift).
    @ObservationIgnored public let adopt = AdoptStore()
    /// 0.7: restore points and "Keep the previous version" (RestorePoints.swift).
    @ObservationIgnored public let restorePoints: RestorePointStore
    /// 0.8.5: Electron apps on a Mac Pro 6,1 (ElectronGPU.swift).
    @ObservationIgnored public let electron: ElectronGPUStore
    @ObservationIgnored private var client: BrewClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(deps: Dependencies, settings: AppSettings? = nil) {
        self.deps = deps
        let recorder = HistoryRecorder()
        self.queue = CommandQueue(runner: deps.streamRunner, observer: { id, command, event in
            recorder.observe(id, command, event)
        })
        self.history = HistoryLog(url: deps.historyURL)
        self.system = ScheduleConditions()
        self.electron = ElectronGPUStore(probe: deps.electronGPU)
        // No settings (tests only; the app always passes them): a private
        // suite per store. One shared suite let concurrent tests see each
        // other's run journal and App Management retry (an interrupted-run
        // offer opened the sheet in an unrelated test).
        self.settings = settings ?? AppSettings.ephemeral("net.mindtricks.tankard.ephemeral.\(UUID().uuidString)")
        self.restorePoints = RestorePointStore(directory: deps.restorePointsURL,
                                               settings: RollbackSettings(defaults: self.settings.defaults))
        self.insights = InsightsStore(settings: InsightSettings(defaults: self.settings.defaults),
                                      cache: deps.insightsCache, ttl: deps.ttl, now: deps.now)
        self.autoUpdate = AutoUpdater(settings: AutoUpdateSettings(defaults: self.settings.defaults, now: deps.now),
                                      log: AutoUpdateLog(url: deps.autoUpdateLogURL))
        // 0.8.8: the last brew update's failure, unless an update has
        // succeeded since (a background check's, outside this store).
        updateFailure = UpdateFailureRecord.load(self.settings)
        wireInsights()
        recorder.setSink { [weak self] e in self?.historyRecorded(e) }
        wireUpgradeRules()
        system.onWillSleep = { [weak self] in self?.stopScheduledUpdate() }
    }

    // MARK: derived

    public var packages: [Package] { report?.packages ?? [] }
    public var intelbrewMode: Bool { report?.intelbrew.detected ?? false }
    public var lastUpdated: Date? { report?.generatedAt }

    public var isStale: Bool {
        guard let t = lastUpdated else { return true }
        return deps.now().timeIntervalSince(t) > deps.ttl
    }

    public func count(_ f: PackageFilter) -> Int {
        packages.filter { f.includes($0) }.count
    }

    /// 0.8.2: the filter bar's segments (PackageFilter.visibleSegmented).
    public var visibleSegmentedFilters: [PackageFilter] {
        PackageFilter.visibleSegmented(selected: filter, count: count)
    }

    /// 0.8.2: the More menu's items with their counts.
    public var moreFilterItems: [PackageFilter.MenuItem] {
        PackageFilter.moreItems(selected: filter, count: count)
    }

    /// The rows for the table: filter, then search (name, full name, description).
    /// "deps:<name>" / "uses:<name>" (the context menu's Show Dependencies /
    /// Show What Uses It) list those packages instead.
    public var visiblePackages: [Package] {
        if let related = RelatedSearch(search), let rows = related.rows(in: packages, selected: selectedPackage) {
            return rows.filter { filter.includes($0) }
        }
        let q = searchTerm.lowercased()
        return packages.filter { p in filter.includes(p) && Self.matches(p, q) }
    }

    static func matches(_ p: Package, _ q: String) -> Bool {
        q.isEmpty
            || p.name.lowercased().contains(q)
            || p.fullName.lowercased().contains(q)
            || (p.desc?.lowercased().contains(q) ?? false)
    }

    /// 0.8.3: the Installed search finds nothing in any filter (not a
    /// "deps:"/"uses:" list): the empty list offers Discover instead.
    public var searchFindsNothingInstalled: Bool {
        let q = searchTerm.lowercased()
        guard !q.isEmpty, RelatedSearch(search) == nil else { return false }
        return !packages.contains { Self.matches($0, q) }
    }

    /// 0.8.3: what the Installed search looks for: the field's text, or
    /// the package part of a pasted "brew install x" (PastedCommand).
    public var searchTerm: String { PastedCommand.searchTerm(search) }

    /// 0.8.3: the Installed list's "Search Discover for 'x'": Discover with
    /// the same term. The caller loads the catalog (DiscoverStore.activate).
    @discardableResult
    public func searchDiscover(for term: String) -> DiscoverStore? {
        guard let d = openDiscover() else { return nil }
        d.query = term
        tab = .discover
        return d
    }

    public var selectedPackage: Package? {
        guard let selection else { return nil }
        return packages.first { $0.id == selection }
    }

    /// What Upgrade all runs: pinned packages are left out (0.4), as
    /// `brew upgrade` leaves them out.
    public var upgradable: [Package] { packages.filter(\.isUpgradeTarget) }
    /// Ids of everything installed (Discover's "installed" mark).
    public var installedIDs: Set<String> { Set(packages.map(\.id)) }
    public var hasBrew: Bool { client != nil }
    /// 0.8: the brew settings Tankard found (environment, brew.env, shell
    /// profiles), once brew was located.
    public var brewSources: EnvironmentSources? { client?.sources }
    /// 0.8: the brew repository's last fetch (see `BrewClient.lastFetch`).
    var brewLastFetch: Date? { client?.lastFetch() }
    public var isUpgrading: Bool { upgrade.map { !$0.isFinished } ?? false }

    // MARK: loading

    /// 0.8.7: start() has run, so the launch's cache-or-read decision is
    /// made (revalidateIfStale waits for it).
    @ObservationIgnored var launchStarted = false

    /// Shows the cached report at once (if any), then refreshes when there
    /// is none or it is older than the TTL. Returns when that is done.
    public func start() async {
        if report == nil, let cached = deps.cache?.load() {
            report = insights.decorate(cached)
            reportFromCache = true
            LaunchTiming.mark("list (cache)", once: true)
            // 0.8.8 (final gauntlet, bug 3): the saved list comes with the
            // failure saved with it, until the next update or Dismiss.
            if error == nil, let failure = updateFailure { error = Self.refreshFailure(failure) }
        }
        // 0.8.6 (M4): also when brew changed something since the cached
        // read (Terminal), or an interrupted run waits to be offered.
        launchStarted = true
        let stale = isStale, changed = homebrewChangedSinceRead, journal = settings.defaults.data(forKey: RunJournal.key) != nil
        // 0.8.8: also when a relaunch for App Management left its operation
        // (it is offered against what brew says now, not the saved list).
        let pendingRetry = settings.appManagementPendingRetry != nil
        if stale || changed || journal || pendingRetry {
            LaunchTiming.note("launch read: stale=\(stale) changed=\(changed) journal=\(journal) retry=\(pendingRetry)")
            await refresh(manual: false)
        } else {
            startInsights(force: false)
        }
        // 0.8.8: the "Run again" offer is this launch's only: shown now or
        // dropped, never attached to a later, unrelated run's read.
        if pendingRetry { resumeAppManagementRetry() }
    }

    /// 0.8.6 (M4): brew's folders changed after the report on screen was
    /// read (a few stat calls; nothing is run).
    public var homebrewChangedSinceRead: Bool {
        guard let probe = deps.homebrewChangedAt, let t = lastUpdated, let client = try? resolvedClient(),
              let changed = probe(client) else { return false }
        return changed > t
    }

    /// Re-reads status if the data is older than the TTL, or (0.8.6, M4)
    /// brew changed something since (window became active).
    public func revalidateIfStale() {
        // 0.8.7: not before start() has shown the cache. On macOS 26 the
        // window becomes key before the window's start task runs: with no
        // report yet, isStale was true, so every launch read brew live
        // (and, with the scan on refresh, scanned) behind the cache.
        guard launchStarted || report != nil else { return }
        if homebrewState.needsWelcome, !isRefreshing {
            Task { await checkAgain() }
            return
        }
        // 0.8.6 (VM test M3): a tap added or removed in Terminal (a few
        // stat calls; Discover reloads only when its taps changed).
        refreshDiscoverIfTapsChanged()
        guard !isRefreshing, !isUpgrading, !selfReplaced, isStale || homebrewChangedSinceRead else { return }
        Task { await refresh(manual: false) }
    }

    /// 0.8.6 (VM test M3): Discover, once opened, re-reads its taps when
    /// they changed outside Tankard (window activation, Refresh).
    func refreshDiscoverIfTapsChanged() {
        guard let d = discover, d.phase == .ready else { return }
        Task { await d.activate() }
    }

    /// The welcome screen's "Check again": look for brew afresh and read status.
    public func checkAgain() async {
        client = nil
        await refresh(manual: false)
    }

    /// `manual`: the refresh button. Runs `brew update` first.
    public func refresh(manual: Bool) async {
        if manual { refreshDiscoverIfTapsChanged() }
        await refresh(manual ? .manual : .automatic)
    }

    /// 0.8: what a refresh does besides reading status.
    enum RefreshKind {
        /// Re-read only; joins a refresh that is already running.
        case automatic
        /// `brew update` first, through the queue.
        case manual
        /// A background `brew update` just finished: re-read (always, even
        /// when another read is running, which may have started before the
        /// update), but don't measure sizes again: an update installs nothing.
        case afterUpdate
        /// 0.8.5: as `.manual`, for a scheduled check (the notification
        /// check, auto-update): its `brew update` has a time limit, stops
        /// when the Mac sleeps, and a "try later" failure (offline, brew
        /// busy) is quiet: no error on screen, one quiet History line.
        case scheduled
    }

    func refresh(_ kind: RefreshKind) async {
        // 0.8.5 (HK-47 review): a scheduled refresh's caller reads this
        // run's result, never the last one's (brew not found returns early).
        if kind == .scheduled { lastScheduledUpdate = nil }
        // 0.8.3: the bundle was replaced: the new instance reads status.
        if selfReplaced { return }
        if let running = refreshTask {
            await running.value
            if kind == .automatic { return }
        }
        let task = Task { await performRefresh(kind) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// 0.8.4: whether a path exists, through the client (demo mode's is
    /// a fake; this Mac's disk is never asked). The context menu's Show in
    /// Finder.
    public func pathExists(_ path: String) -> Bool {
        (try? resolvedClient())?.fileExists(path) ?? false
    }

    func resolvedClient() throws -> BrewClient {
        if let client { return client }
        let c = try deps.makeClient()
        client = c
        return c
    }

    private func performRefresh(_ kind: RefreshKind) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshPhase = nil
            refreshesCompleted += 1
        }
        let client: BrewClient
        do {
            client = try resolvedClient()
        } catch {
            self.error = StoreError(title: String(localized: "Homebrew not found"), detail: String(describing: error), fromRefresh: true)
            if case BrewClientError.brewNotFound(let searched) = error {
                homebrewState = .missing(searched: searched)
            } else {
                homebrewState = .missing(searched: BrewInstallation.candidates)
            }
            return
        }

        var updateError: StoreError?
        if kind == .manual {
            refreshPhase = String(localized: "Running brew update…")
            updateError = await runUpdate(client)
        } else if kind == .scheduled {
            refreshPhase = String(localized: "Running brew update…")
            let r = await runScheduledUpdate(client)
            lastScheduledUpdate = r
            updateError = r.error
        }
        switch kind {
        case .manual, .scheduled: updateFailure = updateError
        case .afterUpdate: updateFailure = nil
        case .automatic: break
        }

        refreshPhase = String(localized: "Reading installed packages…")
        // 0.8: detection first (it decides brew's environment), then
        // `brew info --installed`, `brew info --sizes` and (with "Include
        // self-updating apps") `brew outdated --greedy` all at once. The list
        // appears when `brew info` (and the greedy check, when on) answer;
        // sizes fill in when they land (the Size column shows "–" until then).
        let detection = await client.detectIntelbrew()
        let env = client.environment(for: detection)
        let measureSizes = kind != .afterUpdate
        if measureSizes { insights.measureSizes(client: client, env: env) }
        // 0.8: also when a cask is set to "Homebrew updates it" (Adopt).
        let wantsGreedy = insights.settings.includeSelfUpdatingApps || !upgradeRules.homebrewUpdatedTokens.isEmpty
        async let greedy = wantsGreedy ? Self.readGreedy(client, env: env) : nil
        do {
            let fresh = Self.markSelfUpdating(try await client.status(detection: detection), greedy: await greedy)
            report = insights.decorate(fresh)
            reportFromCache = false
            LaunchTiming.mark("list (brew)", once: true)
            LaunchTiming.note("status read " + fresh.timingsMs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            try? deps.cache?.save(fresh)
            error = updateFailure.map(Self.refreshFailure)
            homebrewState = .ready
            startInsights(force: kind != .afterUpdate, measureSizes: false)
            // 0.8.1: relaunched for App Management: the operation it was
            // for. 0.8.8: offered by the launch (start()) once its read has
            // ended; until then the interrupted-run offer waits too.
            if settings.appManagementPendingRetry == nil, settings.defaults.data(forKey: RunJournal.key) != nil {
                // 0.8.3: an upgrade run a quit or crash interrupted.
                Task { @MainActor in self.offerInterruptedRun() }
            }
        } catch {
            // Keep what's on screen; say what went wrong.
            self.error = Self.refreshFailure(updateError ?? StoreError(title: String(localized: "Refresh failed"), detail: String(describing: error)))
            if let broken = await Self.probeBroken(client) {
                homebrewState = broken
            } else if homebrewState != .ready {
                homebrewState = .ready
            }
        }
        if let s = selection, !packages.contains(where: { $0.id == s }) { selection = nil }
    }

    /// `brew update` through the queue. nil on success.
    func runUpdate(_ client: BrewClient) async -> StoreError? {
        let cmd = await updateCommand(client)
        let collector = OutputCollector()
        do {
            let code = try await queue.run(cmd) { collector.add($0) }
            guard code != 0 else {
                settings.lastBrewUpdate = deps.now()
                return nil
            }
            return Self.updateError(code: code, lines: collector.lines(), display: cmd.display)
        } catch {
            return StoreError(title: String(localized: "brew update didn't run"), detail: String(describing: error))
        }
    }

    func updateCommand(_ client: BrewClient) async -> QueuedCommand {
        let args = ["update"]
        let detection: IntelbrewDetection
        if let d = report?.intelbrew {
            detection = d
        } else {
            detection = await client.detectIntelbrew()
        }
        return QueuedCommand(executable: client.installation.brewPath, arguments: args,
                             environment: client.environment(for: detection, readOnly: false),
                             display: BrewCommands.display(args))
    }

    static func updateError(code: Int32, lines: [String], display: String) -> StoreError {
        let tail = BrewOutputTail.lines(lines, limit: 6).joined(separator: "\n")
        if SudoDetector.needsSudo(lines) {
            return StoreError(title: String(localized: "brew update needs administrator rights"),
                              detail: String(localized: "Run this in Terminal:"), terminalCommand: display)
        }
        if let kind = BrewFailure.classify(lines) {
            return StoreError(title: kind.title, detail: kind.explanation + "\n\n" + tail, terminalCommand: display)
        }
        return StoreError(title: String(localized: "brew update failed (exit \(code))"), detail: tail, terminalCommand: display)
    }

    /// After a failed status read: does `brew --version` run at all? A brew
    /// that can't start (missing Ruby, broken checkout) gets the welcome
    /// screen with what it printed; one that runs keeps the normal error.
    static func probeBroken(_ client: BrewClient) async -> HomebrewState? {
        let path = client.installation.brewPath
        do {
            let r = try await client.runner.run(path, ["--version"], environment: client.environment(for: await client.detectIntelbrew()))
            guard r.exitCode != 0 else { return nil }
            let text = (r.stderrString + "\n" + r.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = text.split(separator: "\n").suffix(8).joined(separator: "\n")
            return .broken(path: path, detail: tail.isEmpty ? String(localized: "brew --version exited \(r.exitCode)") : tail)
        } catch {
            return .broken(path: path, detail: String(describing: error))
        }
    }

    public func dismissError() {
        error = nil
        updateFailure = nil
    }

    /// 0.8.6 (VM test L2): an error from reading status (or its brew update).
    nonisolated static func refreshFailure(_ e: StoreError) -> StoreError {
        var e = e
        e.fromRefresh = true
        return e
    }

    // MARK: Discover

    /// Discover's store for this brew, made on first use. Loading the
    /// catalog is up to the caller (`DiscoverStore.activate()`), so nothing
    /// is fetched until Discover is opened.
    @discardableResult
    public func openDiscover() -> DiscoverStore? {
        if let discover { return discover }
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        let d = DiscoverStore(provider: deps.makeCatalog(client, detection), ttl: deps.ttl, now: deps.now, classifier: deps.classifier)
        discover = d
        return d
    }

    /// Installs one package from Discover through the queue and the sheet.
    public func startInstall(_ entry: CatalogEntry) {
        guard !installedIDs.contains(entry.id) else { return }
        startSession(.install, packages: [entry.asPackage()])
    }

    /// Installed packages that need `p` (uninstall is blocked while any do).
    public func dependents(of p: Package) -> [Package] {
        Dependents.of(p, among: packages)
    }

    /// The context menu's Show Dependencies: keeps `p` selected (its detail
    /// stays in the pane) and lists the installed packages it needs.
    public func showDependencies(of p: Package) {
        showRelated(.dependencies(of: p.fullName), selecting: p)
    }

    /// The context menu's Show What Uses It: the installed packages that need `p`.
    public func showDependents(of p: Package) {
        showRelated(.dependents(of: p.fullName), selecting: p)
    }

    private func showRelated(_ related: RelatedSearch, selecting p: Package) {
        tab = .installed
        filter = .all
        selection = p.id
        search = related.query
    }

    /// Opens the uninstall confirmation. "Also remove these" starts on,
    /// as brew's own uninstall would remove them (its autoremove).
    public func requestUninstall(_ p: Package) {
        // 0.8.5 (review): not while the progress panel holds the activity.
        guard !progressPanelHoldsActivity else { return }
        uninstallRemovesOrphans = true
        uninstallCandidate = p
    }

    /// 0.8: the dependencies nothing needs once `p` is gone (the sheet
    /// lists them, with "Also remove these"). Never the ones that were
    /// unused before: those stay for Remove Unused Dependencies.
    public func uninstallOrphans(of p: Package) -> [Package] {
        dependencyGraph.orphans(afterRemoving: [p])
    }

    /// The uninstall's command as the queue runs it (HOMEBREW_NO_AUTOREMOVE=1),
    /// then, with `orphans`, one line per no-longer-needed dependency: what
    /// the sheet shows and the detail pane's Uninstall button tooltip.
    /// 0.8.4: a formula with several installed versions shows its command
    /// once per version, as it runs.
    public nonisolated static func uninstallDisplay(_ p: Package, orphans: [Package] = []) -> String {
        uninstallSteps([p] + orphans).map {
            BrewCommands.display(BrewCommands.uninstallArguments(for: $0), environment: uninstallEnvironment(.uninstall))
        }.joined(separator: "\n")
    }

    /// The confirmation's line: "Removes xz 5.8.1." or, 0.8.4, with several
    /// installed versions, "Removes all installed versions of xz (5.6.3,
    /// 5.8.1)." `dependenciesStay`: adds "Its dependencies stay installed."
    public nonisolated static func uninstallSummary(_ p: Package, dependenciesStay: Bool) -> String {
        // 0.8.5 (newbie review M4): an app says what happens to the app
        // and to its settings; casks have no dependencies to mention.
        if p.kind == .cask {
            let apps = (p.appPaths ?? []).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            if apps.isEmpty {
                return String(localized: "Removes \(p.name) \(p.installedVersion). Your settings and data for it stay on this Mac.")
            }
            let list = ListFormatter.localizedString(byJoining: apps)
            return String(localized: "Deletes \(list) from Applications. Your settings and data for it stay on this Mac.")
        }
        let versions = Set(p.installedVersions).sorted { PkgVersion(parsing: $0) < PkgVersion(parsing: $1) }
        if p.kind == .formula && versions.count > 1 {
            let list = versions.joined(separator: ", ")
            return dependenciesStay
                ? String(localized: "Removes all installed versions of \(p.name) (\(list)). Its dependencies stay installed.")
                : String(localized: "Removes all installed versions of \(p.name) (\(list)).")
        }
        return dependenciesStay
            ? String(localized: "Removes \(p.name) \(p.installedVersion). Its dependencies stay installed.")
            : String(localized: "Removes \(p.name) \(p.installedVersion).")
    }

    /// Runs `brew uninstall` for a package nothing depends on. 0.8: not
    /// for a pinned one either (brew refuses it, and still exits 0); the
    /// sheet offers Unpin and Uninstall instead. With "Also remove these"
    /// on, its no-longer-needed dependencies follow, each by name (brew's
    /// autoremove stays off, so nothing else goes), and are skipped if an
    /// earlier step fails.
    public func startUninstall(_ p: Package) {
        uninstallCandidate = nil
        guard !progressPanelHoldsActivity else { return }
        guard dependents(of: p).isEmpty, !p.pinned else { return }
        let orphans = uninstallRemovesOrphans ? uninstallOrphans(of: p) : []
        // The list is from the last refresh: right before each dependency's
        // own uninstall, what is installed is read again, and one that is
        // now on request, pinned or needed stays (the log says why).
        let ids = Set(orphans.map(\.id))
        var skipCheck: ((Package) -> CommandQueue.SkipCheck?)?
        if let check = orphanRecheck() {
            skipCheck = { pkg in
                guard ids.contains(pkg.id) else { return nil }
                let skip: CommandQueue.SkipCheck = { await check(pkg) }
                return skip
            }
        }
        startSession(.uninstall, packages: Self.uninstallSteps([p] + orphans), skipCheck: skipCheck)
    }

    /// 0.8.4: plain `brew uninstall` removes one keg of a formula (the
    /// linked one, else the newest) and prints "… is still installed" for
    /// the rest. So a formula with several installed versions gets one step
    /// per version, chained: each keeps brew's own checks (pinned, keg
    /// lock, dependents), unlike `--force`, which skips the pin check and
    /// the keg lock (uninstall.rb). After the run the installed packages
    /// are read again (`checkUninstalled`).
    ///
    /// 0.8.5 (bug hunt L9): each step's `installedVersion` is the version it
    /// is expected to remove, so the sheet's chips read "bh-a 1.2", "bh-a
    /// 1.0", not "bh-a" twice: the one in use first (brew removes the
    /// linked keg first), then the rest, newest first (else the newest).
    public nonisolated static func uninstallSteps(_ packages: [Package]) -> [Package] {
        packages.flatMap { p -> [Package] in
            let versions = Set(p.installedVersions)
            guard p.kind == .formula, versions.count > 1 else { return [p] }
            let rest = versions.subtracting([p.installedVersion]).sorted { PkgVersion(parsing: $0) > PkgVersion(parsing: $1) }
            let order = (versions.contains(p.installedVersion) ? [p.installedVersion] : []) + rest
            return order.map { v in
                var step = p
                step.installedVersion = v
                return step
            }
        }
    }

    /// 0.8.4: after an uninstall, what of it is still installed: a fresh
    /// `brew info --json=v2 --installed`, for the packages whose every step
    /// succeeded (a failed one is still installed, and says so already).
    func checkUninstalled(_ session: UpgradeSession) {
        let ran = session.packages.filter { p in
            session.items.allSatisfy { $0.package.id != p.id || $0.state == .done }
        }
        guard !ran.isEmpty else { return }
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else {
            session.finishInstalledCheck(nil, error: "brew isn't available")
            return
        }
        session.beginInstalledCheck()
        let env = client.environment(for: detection)
        let classifier = StatusClassifier(platform: client.platform, intelbrewMode: detection.detected)
        Task {
            do {
                let live = classifier.classify(info: try await client.installedInfo(env: env))
                var left: [String: [String]] = [:]
                for p in ran {
                    if let now = live.first(where: { $0.id == p.id }) {
                        left[p.name] = now.installedVersions.isEmpty ? [now.installedVersion] : now.installedVersions
                    }
                }
                session.finishInstalledCheck(left)
            } catch {
                session.finishInstalledCheck(nil, error: String(describing: error))
            }
        }
    }

    /// 0.8.6 (VM test M1): after an upgrade run with failed steps, the
    /// installed version of each of those packages (a fresh `brew info
    /// --json=v2 --installed`), so a step brew upgraded before it failed
    /// over another package counts as upgraded. nil: the read failed.
    /// 0.8.6 (HK-47 review): with the linked keg (`linked_keg`) and keg-only.
    nonisolated func upgradedVersionsCheck(_ client: BrewClient, env: [String: String], intelbrewMode: Bool)
        -> @Sendable ([Package]) async -> [String: InstalledNow]? {
        let classifier = StatusClassifier(platform: client.platform, intelbrewMode: intelbrewMode,
                                          folderTime: client.caskFolderTime)
        return { packages in
            guard let info = try? await client.installedInfo(env: env) else { return nil }
            return Self.installedNow(info, classifier: classifier, ids: Set(packages.map(\.id)))
        }
    }

    /// 0.8.6 (HK-47 review): deletes the restore point saved before
    /// `session` only when a fresh `brew info --installed` read matches the
    /// point, whatever the run's result (a failed or stopped run that poured
    /// a dependency shows up in the read). A run that upgraded something
    /// keeps it without a read; a failed read keeps it.
    func dropRestorePointIfUnchanged(_ pointID: RestorePoint.ID, after session: UpgradeSession) {
        guard session.succeededCount == 0,
              let point = restorePoints.points.first(where: { $0.id == pointID }),
              let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        let env = client.environment(for: detection)
        let classifier = StatusClassifier(platform: client.platform, intelbrewMode: detection.detected,
                                          folderTime: client.caskFolderTime)
        Task { @MainActor [weak self] in
            guard let info = try? await client.installedInfo(env: env) else { return }
            guard RestoreDiff.between(point, classifier.classify(info: info)).isEmpty else { return }
            self?.restorePoints.delete(pointID)
        }
    }

    nonisolated static func installedNow(_ info: BrewInfoJSON, classifier: StatusClassifier, ids: Set<String>) -> [String: InstalledNow] {
        var found: [String: InstalledNow] = [:]
        for p in classifier.classify(info: info) where ids.contains(p.id) {
            if p.kind == .formula {
                let f = info.formulae.first { $0.fullName == p.fullName && $0.tap == p.tap }
                found[p.id] = InstalledNow(version: p.installedVersion, linkedVersion: f?.linkedKeg,
                                           kegOnly: f?.kegOnly ?? (p.kegOnly ?? false))
            } else {
                found[p.id] = InstalledNow(version: p.installedVersion, linkedVersion: p.installedVersion, kegOnly: false)
            }
        }
        return found
    }

    /// 0.8: reads the installed packages again (`brew info --json=v2
    /// --installed`) and re-checks one orphan against them. A failed read
    /// keeps the dependency.
    func orphanRecheck() -> (@Sendable (Package) async -> String?)? {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        let env = client.environment(for: detection)
        let classifier = StatusClassifier(platform: client.platform, intelbrewMode: detection.detected,
                                          folderTime: client.caskFolderTime)
        return { orphan in
            do {
                let live = classifier.classify(info: try await client.installedInfo(env: env))
                return DependencyGraph.recheckOrphan(orphan, live: live)
            } catch {
                return "Kept \(orphan.name): couldn't read what is installed now (\(error))."
            }
        }
    }

    // MARK: upgrades

    /// Queues `brew upgrade` for each package, in order, and opens the sheet.
    /// `fromActivity`: started from the activity itself (startSession).
    public func startUpgrade(_ packages: [Package]? = nil, fromActivity: Bool = false) {
        startSession(.upgrade, packages: packages?.filter(\.isManualUpgradeTarget) ?? upgradable, fromActivity: fromActivity)
    }

    /// The Upgrade buttons (0.3): when any upgrade would compile, the sheet
    /// first shows the plan with the compile warnings and "Skip packages
    /// that would compile"; otherwise it starts at once, as before.
    public func requestUpgrade(_ packages: [Package]? = nil) {
        // 0.8.5 (review): not over the progress panel's plan or result
        // (the window's buttons say why); its own Retry goes through
        // `requestUpgradeInActivity`.
        guard !progressPanelHoldsActivity else { return }
        requestUpgradeInActivity(packages)
    }

    /// `requestUpgrade`, from the activity itself (Retry): may replace the
    /// finished run it shows.
    /// `skipCompiling`: the plan starts with "Skip packages that would
    /// compile" ticked (the Upgrades filter's button).
    func requestUpgradeInActivity(_ packages: [Package]? = nil, skipCompiling: Bool = false) {
        guard !isUpgrading else { return }
        let targets = packages?.filter(\.isManualUpgradeTarget) ?? upgradable
        guard !targets.isEmpty else { return }
        var plan = UpgradePlan(packages: targets, classifier: deps.classifier)
        plan.skipCompiling = skipCompiling
        // 0.8.5: and when brew would close an app that is open now.
        plan.runningApps = runningCaskApps(targets)
        // 0.8.3: also when a cask's installer will ask for the password.
        if plan.needsConfirmation {
            upgradePlan = plan
            showUpgradeSheet = true
        } else {
            startUpgrade(targets, fromActivity: true)
        }
    }

    /// 0.8.5 (newbie review H2): the casks among `targets` whose app is
    /// running now, by installed path or the bundle id brew quits (the same
    /// check automatic updates' safe mode uses). None when "Don't quit
    /// running apps during upgrades" is on: brew then leaves them running.
    func runningCaskApps(_ targets: [Package]) -> [RunningCaskApp] {
        guard !insights.settings.dontQuitAppsDuringUpgrade else { return [] }
        let casks = targets.filter { $0.kind == .cask }
        guard !casks.isEmpty else { return [] }
        let running = autoUpdate.conditions.runningApps()
        guard !running.isEmpty else { return [] }
        return casks.compactMap { p in
            AutoUpdateSafeMode.runningApp(p, running: running).map {
                RunningCaskApp(packageID: p.id, name: $0.hasSuffix(".app") ? String($0.dropLast(4)) : p.name)
            }
        }
    }

    public func setPlanSkipCompiling(_ skip: Bool) {
        upgradePlan?.skipCompiling = skip
    }

    /// Start on the plan page.
    public func confirmUpgradePlan() {
        guard let plan = upgradePlan else { return }
        upgradePlan = nil
        let run = plan.toRun
        if run.isEmpty {
            showUpgradeSheet = false
            return
        }
        startSession(.upgrade, packages: run, fromActivity: true)
    }

    public func cancelUpgradePlan() {
        upgradePlan = nil
        showUpgradeSheet = false
    }

    /// The Upgrades filter's "Upgrade N without building from source":
    /// every upgrade except what would compile. 0.8.5 (final pass F1): it
    /// opens the plan like the other Upgrade buttons, with the compiling
    /// ones already skipped, so the open-apps note and the password lock
    /// and order show first; it no longer starts at once.
    public func startUpgradeSkippingCompiles() {
        guard !progressPanelBlocksNewRun() else { return }
        requestUpgradeInActivity(nil, skipCompiling: true)
    }

    /// The Upgrades filter's button: shown when some upgrades would
    /// compile and some wouldn't. `count` includes casks (they never
    /// compile), so the title doesn't say "bottles".
    public struct SkipCompilesButton: Equatable, Sendable {
        public var count: Int
        public var title: String
        public var help: String
    }

    public var skipCompilesButton: SkipCompilesButton? {
        let (rest, compiling) = deps.classifier.partitionUpgrades(upgradable)
        guard !rest.isEmpty, !compiling.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: compiling.map(\.name))
        return SkipCompilesButton(
            count: rest.count,
            title: String(localized: "Upgrade \(rest.count) without building from source"),
            help: String(localized: "Upgrade everything except what would build from source: \(names). Shows the plan first."))
    }

    // MARK: replace with bottle (0.3)

    /// Source builds whose installed version has a bottle here.
    public var bottleReplaceable: [Package] { packages.filter(BottleReplacement.isEligible) }

    /// `brew reinstall --force-bottle --formula <qualified>` for each
    /// eligible package, through the queue and the sheet.
    public func startReplaceWithBottle(_ targets: [Package]? = nil, fromActivity: Bool = false) {
        startSession(.replaceBottle, packages: (targets ?? bottleReplaceable).filter(BottleReplacement.isEligible),
                     fromActivity: fromActivity)
    }

    // MARK: cleanup (0.3)

    /// Opens the Cleanup sheet and runs the dry run.
    public func openCleanup() {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        // 0.8.5 (M1): the old versions kept for Restore Points stay.
        let keep = restorePoints.settings.keepPreviousVersion
        // 0.8.5 (HK-47 review): brew.env's own list wins over Tankard's.
        let brewEnvSets = EnvironmentSources.brewEnvSetting(CleanupKeep.key, files: deps.brewEnvFiles(client)) != nil
        let c = CleanupStore(client: client, env: client.environment(for: detection),
                             kept: CleanupKeep.keptFormulae(packages, keepPrevious: keep), keepPrevious: keep,
                             brewEnvSetsKeep: brewEnvSets)
        cleanup = c
        showCleanupSheet = true
        Task { await c.load() }
    }

    /// The real `brew cleanup`, through the queue and the live log.
    public func startCleanup() {
        showCleanupSheet = false
        startSession(.cleanup, packages: [Package.command("brew cleanup")])
    }

    // MARK: build times (0.3)

    /// A compile warning is on screen. In Intelbrew mode only, this is when
    /// Intelbrew's build-time JSON is fetched (once per 24 h; errors keep
    /// the cached copy). Normal mode never fetches it.
    public func compileWarningShown() {
        guard intelbrewMode, let times = deps.buildTimes else { return }
        Task {
            await times.refreshIfNeeded()
            buildTimesRevision += 1
        }
    }

    // MARK: App Management (0.3)

    /// "I've done this": remember the explainer was seen. 0.8.1: when
    /// Tankard can relaunch itself, the sheet turns to the relaunch offer
    /// (macOS applies the grant to a process started after it); otherwise
    /// run the pending operation (first use) or retry the blocked one once.
    public func appManagementDone() {
        guard var p = appManagementPrompt else { return }
        settings.appManagementExplained = true
        if deps.relaunch != nil, p.stage == .explain {
            p.stage = .relaunch
            appManagementPrompt = p
            return
        }
        appManagementContinue()
    }

    /// 0.8.1: carry on in this process ("Continue without relaunching"):
    /// first use runs what was asked for; a block is retried once.
    public func appManagementContinue() {
        guard let p = appManagementPrompt else { return }
        settings.appManagementExplained = true
        appManagementPrompt = nil
        guard p.canRetry else {
            if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
            return
        }
        startSession(p.action, packages: p.packages, isRetry: p.reason == .blocked, skipGate: true, fromActivity: true)
    }

    /// 0.8.1: "Relaunch Tankard": keep the operation for the next launch
    /// (offered again then, `resumeAppManagementRetry`), then quit and start
    /// again. Not while brew is running. Only the cask targets that change
    /// apps are kept; for an uninstall only the package the user chose.
    public func appManagementRelaunch() {
        guard let p = appManagementPrompt, let relaunch = deps.relaunch, !isUpgrading, !autoUpdate.isRunning else { return }
        settings.appManagementExplained = true
        let classifier = deps.classifier
        var pending = p.canRetry
            ? AppManagementPendingRetry.make(action: p.action, targets: p.packages, root: p.packages.first, savedAt: deps.now(),
                                             compiles: { classifier.upgradeMethod($0).compiles })
            : nil
        // An adopt's per-app self-update choices go with it.
        if p.action == .adopt, !adopt.policiesToSave.isEmpty {
            pending?.policies = adopt.policiesToSave.mapValues(\.rawValue)
        }
        appManagementPrompt = nil
        // Saved only once the helper has started; a failed start leaves
        // nothing behind to offer at the next launch.
        settings.appManagementPendingRetry = nil
        if relaunch() {
            relaunching = true
            settings.appManagementPendingRetry = pending?.encoded()
            // 0.8.8 (gauntlet, the relaunch wedge): the prompt is gone but
            // the activity sheet's own flag was still set, so SwiftUI put
            // the (now empty, zero-size) sheet back each time AppKit ended
            // it for the quit, and termination was refused under it.
            prepareForTermination()
        } else {
            error = StoreError(title: String(localized: "Couldn't relaunch Tankard"),
                               detail: String(localized: "Quit Tankard and open it again, then run it again."))
            if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
        }
    }

    /// 0.8.1: Esc on the relaunch page: close, run nothing. 0.8.6 (M2):
    /// also Cancel on the explainer, which then shows again next time.
    public func appManagementCancel() {
        guard let p = appManagementPrompt else { return }
        if p.stage == .relaunch || p.reason == .blocked { settings.appManagementExplained = true }
        appManagementPrompt = nil
        if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
    }

    /// 0.8.6 (M2): "Skip Apps": run only the targets that don't change
    /// apps (formulae, fonts…); with none, the same as Cancel. The
    /// explainer shows again before the next app change.
    public func appManagementSkipApps() {
        guard let p = appManagementPrompt, p.reason == .firstUse, p.canRetry else { return appManagementCancel() }
        let rest = p.others
        guard !rest.isEmpty else { return appManagementCancel() }
        appManagementPrompt = nil
        startSession(p.action, packages: rest, skipGate: true, fromActivity: true)
    }

    /// Whether "Relaunch Tankard" can be offered now.
    public var canRelaunch: Bool { deps.relaunch != nil && !isUpgrading && !autoUpdate.isRunning }

    /// 0.8.1: after a relaunch for App Management, the operation it was for
    /// (once: the saved one is cleared first), if it still applies to what
    /// brew now says and is less than 15 minutes old. Never run on its own:
    /// the activity sheet offers "Run again" and waits for a click.
    @discardableResult
    func resumeAppManagementRetry() -> Bool {
        // This instance is the one quitting for the relaunch: the saved
        // operation is the next instance's. (A status read still running
        // here when "Relaunch Tankard" was clicked used to end in the quit
        // delay, take the offer and clear it, so the new instance offered
        // nothing.)
        guard !relaunching, let data = settings.appManagementPendingRetry else { return false }
        settings.appManagementPendingRetry = nil
        // 0.8.8: against a fresh read only (a launch whose read failed
        // drops it rather than offering it against the saved list).
        guard !reportFromCache, !terminating, !isUpgrading, upgradePlan == nil, appManagementPrompt == nil,
              let pending = AppManagementPendingRetry.decode(data) else { return false }
        let classifier = deps.classifier
        guard let offer = pending.resolve(installed: packages, now: deps.now(),
                                          compiles: { classifier.upgradeMethod($0).compiles }) else { return false }
        appManagementResume = offer
        showUpgradeSheet = true
        return true
    }

    /// "Run again": through the normal path for the action, gates on: an
    /// upgrade through requestUpgrade (compile plan, pins, rules), an
    /// uninstall through its confirmation (which works out the unused
    /// dependencies again and rechecks each before it runs), an install or
    /// adopt through startSession's own checks.
    public func appManagementResumeConfirm() {
        guard let r = appManagementResume else { return }
        appManagementResume = nil
        switch r.action {
        case .upgrade:
            showUpgradeSheet = false
            requestUpgrade(r.packages)
        case .uninstall:
            showUpgradeSheet = false
            // Single root: the uninstall sheet takes one package today; a future multi-select uninstall would need a loop here.
            guard let p = r.packages.first else { return }
            Task { @MainActor in
                // The activity sheet closes first; the confirmation follows.
                try? await Task.sleep(for: .milliseconds(450))
                self.requestUninstall(p)
            }
        default:
            let run = r.packages.filter { !installedIDs.contains($0.id) }
            guard !run.isEmpty else { showUpgradeSheet = false; return }
            startSession(r.action, packages: run, fromActivity: true)
            if r.action == .adopt, isUpgrading || appManagementPrompt != nil {
                adopt.policiesToSave = r.policies.compactMapValues(SelfUpdatePolicy.init(rawValue:))
            }
        }
    }

    /// Demo and screenshots: the offer as a relaunch would leave it.
    public func demoAppManagementResume(_ targets: [Package]) {
        settings.appManagementPendingRetry = AppManagementPendingRetry.make(
            action: .upgrade, targets: targets, root: nil, savedAt: deps.now(), compiles: { _ in false })?.encoded()
        // (The demo's own launch never saves one: its settings are ephemeral.)
        resumeAppManagementRetry()
    }

    /// "Cancel" on the Run again offer.
    public func appManagementResumeCancel() {
        appManagementResume = nil
        if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
    }

    /// "Continue Without It" (0.8.5: "Not now"): first use still runs what
    /// the user asked for (it may already be allowed); after a block
    /// ("Close"), just closes.
    public func appManagementNotNow() {
        guard let p = appManagementPrompt else { return }
        settings.appManagementExplained = true
        appManagementPrompt = nil
        if p.reason == .firstUse, p.canRetry {
            startSession(p.action, packages: p.packages, skipGate: true, fromActivity: true)
        } else if upgrade == nil {
            showUpgradeSheet = false
        }
    }

    /// Shows the explainer on its own (demo and screenshots).
    public func showAppManagementExplainer(packages: [Package] = [], reason: AppManagementPrompt.Reason = .firstUse) {
        appManagementPrompt = AppManagementPrompt(reason: reason, action: .upgrade, packages: packages)
        showUpgradeSheet = true
    }

    // MARK: quitting (0.8.8)

    /// What Tankard ▸ Quit (⌘Q) and the menu-bar panel's Quit do now.
    /// AppKit refuses to terminate while a sheet is attached ("App
    /// termination blocked by modal sheet") before it asks the app
    /// delegate, so the quit guard's question has to be asked here, not in
    /// applicationShouldTerminate, whenever a sheet may be up.
    public enum QuitStep: Equatable, Sendable {
        /// brew is running: "Homebrew is still working… Quit anyway?" first.
        case ask(QuitPrompt)
        /// Nothing to ask about: close every sheet, then quit.
        case closeSheetsAndQuit
    }

    public var quitStep: QuitStep {
        if let prompt = quitPrompt { return .ask(prompt) }
        return .closeSheetsAndQuit
    }

    /// Tankard is about to terminate (Quit, or a relaunch): every sheet
    /// the store presents is closed in its own state, so SwiftUI doesn't
    /// put one back after AppKit ends it, and nothing new is offered
    /// (post-install notes, the Run again and interrupted-run offers)
    /// until `terminationCancelled`.
    public func prepareForTermination() {
        terminating = true
        dismissPresentations()
        // dismissPresentations keeps a running session's sheet; quitting
        // closes it too (the quit guard has already stopped brew, or the
        // user chose Quit Now and the stop ran out of time).
        showUpgradeSheet = false
        appManagementPrompt = nil
        appManagementResume = nil
        interruptedRun = nil
        upgradePlan = nil
        progressPanelNotes = nil
        progressPanelHideQuestion = false
        offerRelaunch = false
        insights.pendingNotes = nil
    }

    /// The quit didn't happen after all (AppKit still refused, or the
    /// relaunch gave up): offers may show again.
    public func terminationCancelled() {
        terminating = false
    }

    // MARK: sessions

    /// One sheet run of `action` over `targets`, each a queued command.
    /// `fromActivity`: started from the activity on screen (its plan, Retry,
    /// the App Management pages), which may replace the run it shows.
    func startSession(_ action: SessionAction, packages targets: [Package], isRetry: Bool = false, skipGate: Bool = false,
                      skipCheck: ((Package) -> CommandQueue.SkipCheck?)? = nil, fromActivity: Bool = false) {
        // 0.8.5 (HK-47 review): nothing else replaces the progress panel's
        // run (a hidden, failed one nobody has read among them): Clean Up,
        // Remove Unused, Taps, Brewfile, Adopt, Turn On Apps say why.
        guard fromActivity || !progressPanelBlocksNewRun() else { return }
        // 0.5: an automatic run has the queue; its commands go first.
        guard !isUpgrading, !autoUpdate.isRunning, !selfReplaced, let client = try? resolvedClient() else { return }
        guard !targets.isEmpty, let detection = report?.intelbrew else { return }
        if deps.appManagementGate, !skipGate, !isRetry, !settings.appManagementExplained,
           targets.contains(where: { AppManagement.modifiesApps(action, $0) }) {
            appManagementPrompt = AppManagementPrompt(reason: .firstUse, action: action, packages: targets)
            showUpgradeSheet = true
            return
        }
        // 0.7: a restore point before every upgrade session.
        let sessionPoint = action == .upgrade ? saveRestorePoint(.upgrade, upgrading: targets) : nil
        if action == .upgrade { saveRunJournal(targets) }
        var env = client.environment(for: detection, readOnly: false)
        // Upgrade to exactly what the list shows; the refresh button is
        // where `brew update` runs.
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let brew = client.installation.brewPath
        // 0.8.4: a password helper in brew.env that isn't Tankard's: no dialog.
        let foreign = foreignAskpass(client)
        // 0.8.5: an upgrade run asks for the password near the end, once.
        let ordered = action == .upgrade ? AdminPassword.passwordStepsLast(targets) : targets
        upgrade = UpgradeSession(
            packages: ordered, intelbrewMode: detection.detected, action: action, queue: queue,
            makeCommand: { [dontQuit = insights.settings.dontQuitAppsDuringUpgrade,
                            keep = restorePoints.settings.keepPreviousVersion,
                            askpass = deps.askpassHelper, foreign,
                            cleanupKeep = action == .cleanup ? (cleanup?.extraEnvironment ?? [:]) : [:]] p in
                let args = BrewCommands.arguments(action, for: p)
                // 0.4: "Don't quit running apps" adds brew's own variable for cask upgrades.
                // 0.7: "Keep the previous version" adds HOMEBREW_NO_INSTALL_CLEANUP to every
                // upgrade, install and reinstall (any of them can run brew's periodic cleanup).
                let extra = InsightSettings.extraEnvironment(action, p, dontQuitApps: dontQuit)
                    .merging(RollbackSettings.extraEnvironment(action, p, keep: keep)) { $1 }
                    .merging(Self.uninstallEnvironment(action)) { $1 }
                    .merging(cleanupKeep) { $1 }
                let display = BrewCommands.display(args, environment: extra)
                // 0.8.3: a cask change may run sudo: Tankard's password dialog
                // (not in the command shown or copied).
                let password = AdminPassword.environment(helper: askpass, arguments: args, display: display,
                                                         foreign: foreign)
                return QueuedCommand(executable: brew, arguments: args,
                                     environment: env.merging(extra) { $1 }.merging(password) { $1 },
                                     display: display)
            },
            logURL: deps.logURL,
            // 0.8: an uninstall with its dependencies: if one step fails, the rest are skipped.
            // 0.8.5 (HK-47 review): the same for Remove Unused: a failed keep
            // step skips the autoremove, which would remove what it kept.
            chainKey: (action == .uninstall || action == .autoremove) && targets.count > 1 ? { _ in action.rawValue } : nil,
            precondition: foreignAskpassPrecondition(client, action: action, foreignAtStart: foreign),
            skipCheck: skipCheck,
            downloads: deps.downloadMonitor?(client, env),
            // 0.8.3: several packages: one `brew fetch` downloads them all first, in parallel.
            prefetch: Prefetch.steps(action, targets) { [concurrency = Prefetch.environment(brewSources)] args in
                QueuedCommand(executable: brew, arguments: args, environment: env.merging(concurrency) { $1 },
                              display: BrewCommands.display(args, environment: concurrency))
            },
            lockWait: deps.lockWait,
            upgradeCheck: action == .upgrade ? upgradedVersionsCheck(client, env: env, intelbrewMode: detection.detected) : nil,
            onFinish: { [weak self] session in
                self?.sessionFinished(session)
            })
        upgrade?.isRetry = isRetry
        // 0.8.6 (HK-47 review): ⌘Q during "Checking what brew upgraded…"
        // quits without a prompt; the journal mustn't still list every target.
        upgrade?.onUpgradeCheckStarted = { [weak self] session in self?.runJournalSessionFinished(session) }
        // 0.8.6 (walkthrough L7): dropped again if the run changes nothing.
        if let u = upgrade, let point = sessionPoint { sessionRestorePoints[u.id] = point.id }
        upgrade?.passwordFocus = deps.askpassFocus
        upgrade?.foreignAskpass = foreign
        // 0.8.5: time so far and an estimate for builds from source.
        if let u = upgrade {
            u.now = deps.now
            configureBuildProgress(u)
        }
        // 0.8.5 (review): the panel's run stays the panel's while hidden.
        runHome = activityPresentation
        showUpgradeSheet = true
    }

    /// 0.8.4: brew.env's SUDO_ASKPASS, when it isn't Tankard's own helper
    /// (read from disk now in the app). nil without a client.
    public func foreignAskpass(_ client: BrewClient? = nil) -> ForeignAskpass? {
        guard let client = client ?? (try? resolvedClient()) else { return nil }
        return ForeignAskpass.detect(brewEnvFiles: deps.brewEnvFiles(client), own: deps.askpassHelper)
    }

    /// 0.8.4: each sudo-capable step re-reads brew.env right before it
    /// starts and is refused when a foreign helper could get the password
    /// (AdminPassword.refusal); the sheet then shows the Terminal command.
    nonisolated func foreignAskpassPrecondition(_ client: BrewClient, action: SessionAction, foreignAtStart: ForeignAskpass?)
        -> (Package) -> (@Sendable () -> String?)? {
        let files = deps.brewEnvFiles, own = deps.askpassHelper
        return { p in
            let args = BrewCommands.arguments(action, for: p)
            guard AdminPassword.mayNeedSudo(args) else { return nil }
            // What the step's command carries (makeCommand builds it the same way).
            let env = AdminPassword.environment(helper: own, arguments: args, display: "", foreign: foreignAtStart)
            return {
                let foreign = ForeignAskpass.detect(brewEnvFiles: files(client), own: own)
                return AdminPassword.refusal(arguments: args, package: p, environment: env, foreign: foreign)
            }
        }
    }

    /// 0.8: Uninstall removes only the package, as its confirmation says
    /// ("Its dependencies stay installed"). brew 7 runs `brew autoremove`
    /// after every uninstall unless HOMEBREW_NO_AUTOREMOVE is set
    /// (cmd/uninstall.rb), which also removes every other unused dependency
    /// on the Mac; Remove Unused Dependencies is the place for that.
    public nonisolated static func uninstallEnvironment(_ action: SessionAction) -> [String: String] {
        action == .uninstall ? [RestorePlan.noAutoremoveKey: "1"] : [:]
    }

    /// 0.7: a sheet run whose commands come from the caller (a restore).
    func startCustomSession(_ action: SessionAction, packages rows: [Package], intelbrewMode: Bool,
                            makeCommand: (Package) -> QueuedCommand, chainKey: ((Package) -> String?)?,
                            precondition: ((Package) -> (@Sendable () -> String?)?)? = nil) {
        guard !isUpgrading, !autoUpdate.isRunning, !rows.isEmpty, !progressPanelBlocksNewRun() else { return }
        upgrade = UpgradeSession(packages: rows, intelbrewMode: intelbrewMode, action: action, queue: queue,
                                 makeCommand: makeCommand, logURL: deps.logURL, chainKey: chainKey,
                                 precondition: precondition,
                                 downloads: downloadMonitorForCustomSession(),
                                 lockWait: deps.lockWait,
                                 onFinish: { [weak self] session in self?.sessionFinished(session) })
        upgrade?.passwordFocus = deps.askpassFocus
        showUpgradeSheet = true
    }

    /// A restore's reinstalls download too.
    private func downloadMonitorForCustomSession() -> DownloadMonitor? {
        guard let make = deps.downloadMonitor, let client = try? resolvedClient(),
              let detection = report?.intelbrew else { return nil }
        return make(client, client.environment(for: detection, readOnly: false))
    }

    private func sessionFinished(_ session: UpgradeSession) {
        // 0.8.5: after the rest (it may open the App Management page).
        defer { progressPanelSessionFinished(session) }
        if session.action == .adopt { adoptSessionFinished(session) }
        // 0.8.5: a tap added or removed (Enable Casks among them): Discover
        // lists what the taps now hold.
        if session.action == .tap || session.action == .untap, let d = discover {
            Task { await d.reload() }
        }
        // 0.8.6 (VM test M1): steps that upgraded although brew exited non-zero.
        for id in session.upgradedAnyway {
            let other = session.upgradedOverAnotherPackage.contains(id)
            if !history.markUpgradedAnyway(id, overAnotherPackage: other) { pendingUpgradedAnyway[id] = other }
        }
        // 0.8.8: steps an earlier step of the run had already upgraded.
        for (id, by) in session.doneByEarlierStep where !history.markUpgradedEarlier(id, by: by) {
            pendingUpgradedEarlier[id] = by
        }
        runJournalSessionFinished(session)
        recordBuilds(session)
        // 0.8.6 (walkthrough L7): a run that changed nothing keeps no
        // restore point: eight small runs left eight points, most identical.
        // HK-47 review: "upgraded nothing" isn't "changed nothing" (brew may
        // have poured dependencies before the package failed or was
        // stopped), so the point goes only when a fresh read matches it.
        if let pointID = sessionRestorePoints.removeValue(forKey: session.id) {
            dropRestorePointIfUnchanged(pointID, after: session)
        }
        selfUpgradeFinished(session)
        // 0.8.3: Tankard's own bundle was just replaced: only the relaunch
        // offer. The new instance reads status, shows notes and prompts.
        if selfReplaced { return }
        // 0.8: an uninstalled cask's self-update choice goes with it.
        if session.action == .uninstall {
            checkUninstalled(session)
            for item in session.items where item.state == .done && item.package.kind == .cask {
                upgradeRules.setSelfUpdatePolicy(SelfUpdateRule.key(item.package), .automatic)
            }
        }
        // Reconcile: what brew now says, not what we assume. Then (0.4)
        // the caveats of what changed, once.
        Task {
            await self.refresh(manual: false)
            self.offerPostInstallNotes(for: session)
            // 0.8.5 (review): a progress-panel run closes, or notifies,
            // only now that its notes are known.
            self.progressPanelRunSettled(session)
        }
        // A cask step macOS blocked: explain, offer one retry. 0.8.1: a
        // restore's blocked step (a command row) is explained too, without
        // a retry (Restore Points runs it again).
        if !session.isRetry, !session.blockedPackages.isEmpty, !terminating {
            let retry = AppManagement.retryable(session.action) ? session.blockedPackages : []
            appManagementPrompt = AppManagementPrompt(reason: .blocked, action: session.action, packages: retry)
            showUpgradeSheet = true
        }
    }

    /// Clears a finished session (the sheet's Done button).
    public func closeUpgrade() {
        // 0.8.5 (review): a progress-panel run's notes are the panel's
        // last page, not a sheet on a main window that may be closed or
        // behind other apps (whose sheet would also hold the menu gate).
        if runHome == .progressPanel, !selfReplaced, let notes = insights.pendingNotes {
            insights.pendingNotes = nil
            if upgrade?.isFinished == true { upgrade = nil }
            runHome = .mainWindowSheet
            let wasShowing = showsProgressPanel
            progressPanelNotes = notes
            activityPresentation = .progressPanel
            showUpgradeSheet = true
            if !wasShowing { progressPanelFrontRequests += 1 }
            return
        }
        showUpgradeSheet = false
        if upgrade?.isFinished == true {
            upgrade = nil
            runHome = .mainWindowSheet
        }
        if !selfReplaced { insights.presentPending() }
    }
}

/// Collects streamed output from a background thread.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = LineAssembler()

    func add(_ d: Data) { lock.withLock { _ = assembler.feed(d) } }

    func lines() -> [String] {
        lock.withLock {
            assembler.finish()
            return assembler.lines
        }
    }
}
