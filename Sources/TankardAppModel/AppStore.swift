import Foundation
import Observation
import TankardCore

/// A problem to show without throwing away the data on screen.
public struct StoreError: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// When brew needed sudo (or the app can't do the step itself): the
    /// command for the user to run in Terminal.
    public var terminalCommand: String?

    public init(title: String, detail: String, terminalCommand: String? = nil) {
        self.title = title
        self.detail = detail
        self.terminalCommand = terminalCommand
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
        public var relaunch: (@MainActor @Sendable () -> Void)?
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
        /// 0.8: download progress in the sheet: builds the watcher for a
        /// session's brew (nil: none, as in demo mode). `live()` sets
        /// `DownloadMonitor.live`.
        public var downloadMonitor: (@Sendable (BrewClient, [String: String]) -> DownloadMonitor?)?

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
        /// local taps; otherwise formulae.brew.sh.
        public static let liveCatalog: @Sendable (BrewClient, IntelbrewDetection) -> CatalogProviding = { client, detection in
            if detection.detected || client.sources.effective(Intelbrew.noAPIKey) != nil {
                return TapCatalog(client: client, detection: detection)
            }
            return APICatalog(fetcher: APIFetcher(), platform: client.platform)
        }

        /// The real thing: brew from its standard locations (or
        /// TANKARD_BREW), posix_spawn, the user's cache and log paths.
        public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Dependencies {
            let override = environment["TANKARD_BREW"].flatMap { $0.isEmpty ? nil : $0 }
            var d = Dependencies(
                makeClient: { try BrewClient.locate(override: override) },
                streamRunner: StreamingProcessRunner(),
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
            let times = BuildTimeSource.live()
            d.buildTimes = times
            d.classifier = CompileClassifier(estimator: times)
            return d
        }
    }

    // MARK: state

    public internal(set) var report: StatusReport?
    /// Where `report` came from on screen: the disk cache or a live read.
    public private(set) var reportFromCache = false
    public private(set) var isRefreshing = false
    /// What a running refresh is doing ("Running brew update…").
    public private(set) var refreshPhase: String?
    public internal(set) var error: StoreError?
    public private(set) var upgrade: UpgradeSession?
    public var showUpgradeSheet = false
    /// Whether brew was found and runs (the welcome screen otherwise).
    public private(set) var homebrewState: HomebrewState = .checking
    /// The package the uninstall confirmation is open for.
    public var uninstallCandidate: Package?
    /// 0.8: the uninstall sheet's "Also remove these" (its no-longer-needed dependencies).
    public var uninstallRemovesOrphans = true
    /// Discover's store, made when Discover is first opened.
    public private(set) var discover: DiscoverStore?
    /// 0.3: the upgrade sheet's first page when something would compile.
    public private(set) var upgradePlan: UpgradePlan?
    /// 0.3: the App Management sheet (shown in the activity sheet).
    public private(set) var appManagementPrompt: AppManagementPrompt?
    /// 0.8.1: the "Run again" offer after a relaunch (waits for a click).
    public internal(set) var appManagementResume: AppManagementResume?
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

    public var tab: MainTab = .installed
    public var filter: PackageFilter = .all
    public var search = ""
    public var selection: Package.ID?

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
    @ObservationIgnored private var client: BrewClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(deps: Dependencies, settings: AppSettings? = nil) {
        self.deps = deps
        let recorder = HistoryRecorder()
        self.queue = CommandQueue(runner: deps.streamRunner, observer: { id, command, event in
            recorder.observe(id, command, event)
        })
        self.history = HistoryLog(url: deps.historyURL)
        self.settings = settings ?? AppSettings.ephemeral()
        self.restorePoints = RestorePointStore(directory: deps.restorePointsURL,
                                               settings: RollbackSettings(defaults: self.settings.defaults))
        self.insights = InsightsStore(settings: InsightSettings(defaults: self.settings.defaults),
                                      cache: deps.insightsCache, ttl: deps.ttl, now: deps.now)
        self.autoUpdate = AutoUpdater(settings: AutoUpdateSettings(defaults: self.settings.defaults, now: deps.now),
                                      log: AutoUpdateLog(url: deps.autoUpdateLogURL))
        wireInsights()
        recorder.setSink { [weak self] e in self?.historyRecorded(e) }
        wireUpgradeRules()
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
        let graph = f.needsGraph ? DependencyGraph(packages) : nil
        return packages.filter { f.includes($0, graph: graph) }.count
    }

    /// The rows for the table: filter, then search (name, full name, description).
    /// "deps:<name>" / "uses:<name>" (the context menu's Show Dependencies /
    /// Show What Uses It) list those packages instead.
    public var visiblePackages: [Package] {
        let graph = filter.needsGraph ? DependencyGraph(packages) : nil
        if let related = RelatedSearch(search), let rows = related.rows(in: packages, selected: selectedPackage) {
            return rows.filter { filter.includes($0, graph: graph) }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return packages.filter { p in
            filter.includes(p, graph: graph) && (q.isEmpty
                || p.name.lowercased().contains(q)
                || p.fullName.lowercased().contains(q)
                || (p.desc?.lowercased().contains(q) ?? false))
        }
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

    /// Shows the cached report at once (if any), then refreshes when there
    /// is none or it is older than the TTL. Returns when that is done.
    public func start() async {
        if report == nil, let cached = deps.cache?.load() {
            report = insights.decorate(cached)
            reportFromCache = true
            LaunchTiming.mark("list (cache)", once: true)
        }
        if isStale {
            await refresh(manual: false)
        } else {
            startInsights(force: false)
        }
    }

    /// Re-reads status if the data is older than the TTL (window became active).
    public func revalidateIfStale() {
        if homebrewState.needsWelcome, !isRefreshing {
            Task { await checkAgain() }
            return
        }
        guard isStale, !isRefreshing, !isUpgrading else { return }
        Task { await refresh(manual: false) }
    }

    /// The welcome screen's "Check again": look for brew afresh and read status.
    public func checkAgain() async {
        client = nil
        await refresh(manual: false)
    }

    /// `manual`: the refresh button. Runs `brew update` first.
    public func refresh(manual: Bool) async {
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
    }

    func refresh(_ kind: RefreshKind) async {
        if let running = refreshTask {
            await running.value
            if kind == .automatic { return }
        }
        let task = Task { await performRefresh(kind) }
        refreshTask = task
        await task.value
        refreshTask = nil
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
        }
        let client: BrewClient
        do {
            client = try resolvedClient()
        } catch {
            self.error = StoreError(title: String(localized: "Homebrew not found"), detail: String(describing: error))
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
            error = updateError
            homebrewState = .ready
            startInsights(force: kind != .afterUpdate, measureSizes: false)
            // 0.8.1: relaunched for App Management: the operation it was for.
            if settings.appManagementPendingRetry != nil {
                Task { @MainActor in self.resumeAppManagementRetry() }
            }
        } catch {
            // Keep what's on screen; say what went wrong.
            self.error = updateError ?? StoreError(title: String(localized: "Refresh failed"), detail: String(describing: error))
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
        let args = ["update"]
        let detection: IntelbrewDetection
        if let d = report?.intelbrew {
            detection = d
        } else {
            detection = await client.detectIntelbrew()
        }
        let cmd = QueuedCommand(executable: client.installation.brewPath, arguments: args,
                                environment: client.environment(for: detection, readOnly: false),
                                display: BrewCommands.display(args))
        let collector = OutputCollector()
        do {
            let code = try await queue.run(cmd) { collector.add($0) }
            guard code != 0 else {
                settings.lastBrewUpdate = deps.now()
                return nil
            }
            let lines = collector.lines()
            let tail = lines.suffix(6).joined(separator: "\n")
            if SudoDetector.needsSudo(lines) {
                return StoreError(title: String(localized: "brew update needs administrator rights"),
                                  detail: String(localized: "Run this in Terminal:"), terminalCommand: cmd.display)
            }
            if let kind = BrewFailure.classify(lines) {
                return StoreError(title: kind.title, detail: kind.explanation + "\n\n" + tail, terminalCommand: cmd.display)
            }
            return StoreError(title: String(localized: "brew update failed (exit \(code))"), detail: tail, terminalCommand: cmd.display)
        } catch {
            return StoreError(title: String(localized: "brew update did not run"), detail: String(describing: error))
        }
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

    public func dismissError() { error = nil }

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
    public nonisolated static func uninstallDisplay(_ p: Package, orphans: [Package] = []) -> String {
        ([p] + orphans).map {
            BrewCommands.display(BrewCommands.uninstallArguments(for: $0), environment: uninstallEnvironment(.uninstall))
        }.joined(separator: "\n")
    }

    /// Runs `brew uninstall` for a package nothing depends on. 0.8: not
    /// for a pinned one either (brew refuses it, and still exits 0); the
    /// sheet offers Unpin and Uninstall instead. With "Also remove these"
    /// on, its no-longer-needed dependencies follow, each by name (brew's
    /// autoremove stays off, so nothing else goes), and are skipped if an
    /// earlier step fails.
    public func startUninstall(_ p: Package) {
        uninstallCandidate = nil
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
        startSession(.uninstall, packages: [p] + orphans, skipCheck: skipCheck)
    }

    /// 0.8: reads the installed packages again (`brew info --json=v2
    /// --installed`) and re-checks one orphan against them. A failed read
    /// keeps the dependency.
    func orphanRecheck() -> (@Sendable (Package) async -> String?)? {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        let env = client.environment(for: detection)
        let classifier = StatusClassifier(platform: client.platform, intelbrewMode: detection.detected)
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
    public func startUpgrade(_ packages: [Package]? = nil) {
        startSession(.upgrade, packages: packages?.filter(\.isManualUpgradeTarget) ?? upgradable)
    }

    /// The Upgrade buttons (0.3): when any upgrade would compile, the sheet
    /// first shows the plan with the compile warnings and "Skip packages
    /// that would compile"; otherwise it starts at once, as before.
    public func requestUpgrade(_ packages: [Package]? = nil) {
        guard !isUpgrading else { return }
        let targets = packages?.filter(\.isManualUpgradeTarget) ?? upgradable
        guard !targets.isEmpty else { return }
        let plan = UpgradePlan(packages: targets, classifier: deps.classifier)
        if plan.hasCompiling {
            upgradePlan = plan
            showUpgradeSheet = true
        } else {
            startUpgrade(targets)
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
        startSession(.upgrade, packages: run)
    }

    public func cancelUpgradePlan() {
        upgradePlan = nil
        showUpgradeSheet = false
    }

    /// Upgrades with a bottle only (the Upgrades filter's "skip" button).
    public func startUpgradeSkippingCompiles() {
        let (bottled, _) = deps.classifier.partitionUpgrades(upgradable)
        startUpgrade(bottled)
    }

    // MARK: replace with bottle (0.3)

    /// Source builds whose installed version has a bottle here.
    public var bottleReplaceable: [Package] { packages.filter(BottleReplacement.isEligible) }

    /// `brew reinstall --force-bottle --formula <qualified>` for each
    /// eligible package, through the queue and the sheet.
    public func startReplaceWithBottle(_ targets: [Package]? = nil) {
        startSession(.replaceBottle, packages: (targets ?? bottleReplaceable).filter(BottleReplacement.isEligible))
    }

    // MARK: cleanup (0.3)

    /// Opens the Cleanup sheet and runs the dry run.
    public func openCleanup() {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        let c = CleanupStore(client: client, env: client.environment(for: detection))
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
        startSession(p.action, packages: p.packages, isRetry: p.reason == .blocked, skipGate: true)
    }

    /// 0.8.1: "Relaunch Tankard": keep the operation for the next launch
    /// (offered again then, `resumeAppManagementRetry`), then quit and start
    /// again. Not while brew is running. Only the cask targets that change
    /// apps are kept; for an uninstall only the package the user chose.
    public func appManagementRelaunch() {
        guard let p = appManagementPrompt, let relaunch = deps.relaunch, !isUpgrading, !autoUpdate.isRunning else { return }
        settings.appManagementExplained = true
        let classifier = deps.classifier
        settings.appManagementPendingRetry = p.canRetry
            ? AppManagementPendingRetry.make(action: p.action, targets: p.packages, root: p.packages.first, savedAt: deps.now(),
                                             compiles: { classifier.upgradeMethod($0).compiles })?.encoded()
            : nil
        appManagementPrompt = nil
        relaunch()
    }

    /// Whether "Relaunch Tankard" can be offered now.
    public var canRelaunch: Bool { deps.relaunch != nil && !isUpgrading && !autoUpdate.isRunning }

    /// 0.8.1: after a relaunch for App Management, the operation it was for
    /// (once: the saved one is cleared first), if it still applies to what
    /// brew now says and is less than 15 minutes old. Never run on its own:
    /// the activity sheet offers "Run again" and waits for a click.
    @discardableResult
    func resumeAppManagementRetry() -> Bool {
        guard let data = settings.appManagementPendingRetry else { return false }
        settings.appManagementPendingRetry = nil
        guard !isUpgrading, upgradePlan == nil, appManagementPrompt == nil,
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
            guard let p = r.packages.first else { return }
            Task { @MainActor in
                // The activity sheet closes first; the confirmation follows.
                try? await Task.sleep(for: .milliseconds(450))
                self.requestUninstall(p)
            }
        default:
            let run = r.packages.filter { !installedIDs.contains($0.id) }
            guard !run.isEmpty else { showUpgradeSheet = false; return }
            startSession(r.action, packages: run)
        }
    }

    /// Demo and screenshots: the offer as a relaunch would leave it.
    public func demoAppManagementResume(_ targets: [Package]) {
        settings.appManagementPendingRetry = AppManagementPendingRetry.make(
            action: .upgrade, targets: targets, root: nil, savedAt: deps.now(), compiles: { _ in false })?.encoded()
        resumeAppManagementRetry()
    }

    /// "Cancel" on the Run again offer.
    public func appManagementResumeCancel() {
        appManagementResume = nil
        if upgrade == nil || upgrade?.isFinished == true { showUpgradeSheet = false }
    }

    /// "Not now": first use still runs what the user asked for (it may
    /// already be allowed); after a block, just closes.
    public func appManagementNotNow() {
        guard let p = appManagementPrompt else { return }
        settings.appManagementExplained = true
        appManagementPrompt = nil
        if p.reason == .firstUse, p.canRetry {
            startSession(p.action, packages: p.packages, skipGate: true)
        } else if upgrade == nil {
            showUpgradeSheet = false
        }
    }

    /// Shows the explainer on its own (demo and screenshots).
    public func showAppManagementExplainer(packages: [Package] = [], reason: AppManagementPrompt.Reason = .firstUse) {
        appManagementPrompt = AppManagementPrompt(reason: reason, action: .upgrade, packages: packages)
        showUpgradeSheet = true
    }

    // MARK: sessions

    /// One sheet run of `action` over `targets`, each a queued command.
    func startSession(_ action: SessionAction, packages targets: [Package], isRetry: Bool = false, skipGate: Bool = false,
                      skipCheck: ((Package) -> CommandQueue.SkipCheck?)? = nil) {
        // 0.5: an automatic run has the queue; its commands go first.
        guard !isUpgrading, !autoUpdate.isRunning, let client = try? resolvedClient() else { return }
        guard !targets.isEmpty, let detection = report?.intelbrew else { return }
        if deps.appManagementGate, !skipGate, !isRetry, !settings.appManagementExplained,
           targets.contains(where: { AppManagement.modifiesApps(action, $0) }) {
            appManagementPrompt = AppManagementPrompt(reason: .firstUse, action: action, packages: targets)
            showUpgradeSheet = true
            return
        }
        // 0.7: a restore point before every upgrade session.
        if action == .upgrade { saveRestorePoint(.upgrade, upgrading: targets) }
        var env = client.environment(for: detection, readOnly: false)
        // Upgrade to exactly what the list shows; the refresh button is
        // where `brew update` runs.
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let brew = client.installation.brewPath
        upgrade = UpgradeSession(
            packages: targets, intelbrewMode: detection.detected, action: action, queue: queue,
            makeCommand: { [dontQuit = insights.settings.dontQuitAppsDuringUpgrade,
                            keep = restorePoints.settings.keepPreviousVersion] p in
                let args = BrewCommands.arguments(action, for: p)
                // 0.4: "Don't quit running apps" adds brew's own variable for cask upgrades.
                // 0.7: "Keep the previous version" adds HOMEBREW_NO_INSTALL_CLEANUP to every
                // upgrade, install and reinstall (any of them can run brew's periodic cleanup).
                let extra = InsightSettings.extraEnvironment(action, p, dontQuitApps: dontQuit)
                    .merging(RollbackSettings.extraEnvironment(action, p, keep: keep)) { $1 }
                    .merging(Self.uninstallEnvironment(action)) { $1 }
                return QueuedCommand(executable: brew, arguments: args, environment: env.merging(extra) { $1 },
                                     display: BrewCommands.display(args, environment: extra))
            },
            logURL: deps.logURL,
            // 0.8: an uninstall with its dependencies: if one step fails, the rest are skipped.
            chainKey: action == .uninstall && targets.count > 1 ? { _ in "uninstall" } : nil,
            skipCheck: skipCheck,
            downloads: deps.downloadMonitor?(client, env),
            onFinish: { [weak self] session in
                self?.sessionFinished(session)
            })
        upgrade?.isRetry = isRetry
        showUpgradeSheet = true
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
        guard !isUpgrading, !autoUpdate.isRunning, !rows.isEmpty else { return }
        upgrade = UpgradeSession(packages: rows, intelbrewMode: intelbrewMode, action: action, queue: queue,
                                 makeCommand: makeCommand, logURL: deps.logURL, chainKey: chainKey,
                                 precondition: precondition,
                                 downloads: downloadMonitorForCustomSession(),
                                 onFinish: { [weak self] session in self?.sessionFinished(session) })
        showUpgradeSheet = true
    }

    /// A restore's reinstalls download too.
    private func downloadMonitorForCustomSession() -> DownloadMonitor? {
        guard let make = deps.downloadMonitor, let client = try? resolvedClient(),
              let detection = report?.intelbrew else { return nil }
        return make(client, client.environment(for: detection, readOnly: false))
    }

    private func sessionFinished(_ session: UpgradeSession) {
        if session.action == .adopt { adoptSessionFinished(session) }
        // 0.8: an uninstalled cask's self-update choice goes with it.
        if session.action == .uninstall {
            for item in session.items where item.state == .done && item.package.kind == .cask {
                upgradeRules.setSelfUpdatePolicy(SelfUpdateRule.key(item.package), .automatic)
            }
        }
        // Reconcile: what brew now says, not what we assume. Then (0.4)
        // the caveats of what changed, once.
        Task {
            await self.refresh(manual: false)
            self.offerPostInstallNotes(for: session)
        }
        // A cask step macOS blocked: explain, offer one retry. 0.8.1: a
        // restore's blocked step (a command row) is explained too, without
        // a retry (Restore Points runs it again).
        if !session.isRetry, !session.blockedPackages.isEmpty {
            let retry = AppManagement.retryable(session.action) ? session.blockedPackages : []
            appManagementPrompt = AppManagementPrompt(reason: .blocked, action: session.action, packages: retry)
            showUpgradeSheet = true
        }
    }

    /// Clears a finished session (the sheet's Done button).
    public func closeUpgrade() {
        showUpgradeSheet = false
        if upgrade?.isFinished == true { upgrade = nil }
        insights.presentPending()
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
