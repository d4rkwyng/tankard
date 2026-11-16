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

        public init(makeClient: @escaping @Sendable () throws -> BrewClient,
                    streamRunner: StreamingCommandRunning,
                    cache: StatusCache?,
                    logURL: URL?,
                    ttl: TimeInterval = 3600,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.makeClient = makeClient
            self.streamRunner = streamRunner
            self.cache = cache
            self.logURL = logURL
            self.ttl = ttl
            self.now = now
        }

        /// The real thing: brew from its standard locations (or
        /// TANKARD_BREW), posix_spawn, the user's cache and log paths.
        public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Dependencies {
            let override = environment["TANKARD_BREW"].flatMap { $0.isEmpty ? nil : $0 }
            return Dependencies(
                makeClient: { try BrewClient.locate(override: override) },
                streamRunner: StreamingProcessRunner(),
                cache: StatusCache(url: StatusCache.defaultURL),
                logURL: AppPaths.upgradeLog
            )
        }
    }

    // MARK: state

    public private(set) var report: StatusReport?
    /// Where `report` came from on screen: the disk cache or a live read.
    public private(set) var reportFromCache = false
    public private(set) var isRefreshing = false
    /// What a running refresh is doing ("Running brew update…").
    public private(set) var refreshPhase: String?
    public private(set) var error: StoreError?
    public private(set) var upgrade: UpgradeSession?
    public var showUpgradeSheet = false

    public var filter: PackageFilter = .all
    public var search = ""
    public var selection: Package.ID?

    @ObservationIgnored public let deps: Dependencies
    @ObservationIgnored public let queue: CommandQueue
    @ObservationIgnored private var client: BrewClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(deps: Dependencies) {
        self.deps = deps
        self.queue = CommandQueue(runner: deps.streamRunner)
    }

    // MARK: derived

    public var packages: [Package] { report?.packages ?? [] }
    public var intelbrewMode: Bool { report?.intelbrew.detected ?? false }
    public var lastUpdated: Date? { report?.generatedAt }

    public var isStale: Bool {
        guard let t = lastUpdated else { return true }
        return deps.now().timeIntervalSince(t) > deps.ttl
    }

    public func count(_ f: PackageFilter) -> Int { packages.filter(f.includes).count }

    /// The rows for the table: filter, then search (name, full name, description).
    public var visiblePackages: [Package] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return packages.filter { p in
            filter.includes(p) && (q.isEmpty
                || p.name.lowercased().contains(q)
                || p.fullName.lowercased().contains(q)
                || (p.desc?.lowercased().contains(q) ?? false))
        }
    }

    public var selectedPackage: Package? {
        guard let selection else { return nil }
        return packages.first { $0.id == selection }
    }

    public var upgradable: [Package] { packages.filter(\.upgradeAvailable) }
    public var isUpgrading: Bool { upgrade.map { !$0.isFinished } ?? false }

    // MARK: loading

    /// Shows the cached report at once (if any), then refreshes when there
    /// is none or it is older than the TTL. Returns when that is done.
    public func start() async {
        if report == nil, let cached = deps.cache?.load() {
            report = cached
            reportFromCache = true
        }
        if isStale {
            await refresh(manual: false)
        }
    }

    /// Re-reads status if the data is older than the TTL (window became active).
    public func revalidateIfStale() {
        guard isStale, !isRefreshing, !isUpgrading else { return }
        Task { await refresh(manual: false) }
    }

    /// `manual`: the refresh button. Runs `brew update` first.
    public func refresh(manual: Bool) async {
        if let running = refreshTask {
            await running.value
            if !manual { return }
        }
        let task = Task { await performRefresh(manual: manual) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func resolvedClient() throws -> BrewClient {
        if let client { return client }
        let c = try deps.makeClient()
        client = c
        return c
    }

    private func performRefresh(manual: Bool) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshPhase = nil
        }
        let client: BrewClient
        do {
            client = try resolvedClient()
        } catch {
            self.error = StoreError(title: "Homebrew not found", detail: String(describing: error))
            return
        }

        var updateError: StoreError?
        if manual {
            refreshPhase = "Running brew update…"
            updateError = await runUpdate(client)
        }

        refreshPhase = "Reading installed packages…"
        do {
            let fresh = try await client.status()
            report = fresh
            reportFromCache = false
            try? deps.cache?.save(fresh)
            error = updateError
        } catch {
            // Keep what's on screen; say what went wrong.
            self.error = updateError ?? StoreError(title: "Refresh failed", detail: String(describing: error))
        }
        if let s = selection, !packages.contains(where: { $0.id == s }) { selection = nil }
    }

    /// `brew update` through the queue. nil on success.
    private func runUpdate(_ client: BrewClient) async -> StoreError? {
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
            guard code != 0 else { return nil }
            let lines = collector.lines()
            let tail = lines.suffix(6).joined(separator: "\n")
            if SudoDetector.needsSudo(lines) {
                return StoreError(title: "brew update needs administrator rights",
                                  detail: "Run this in Terminal:", terminalCommand: cmd.display)
            }
            return StoreError(title: "brew update failed (exit \(code))", detail: tail, terminalCommand: cmd.display)
        } catch {
            return StoreError(title: "brew update did not run", detail: String(describing: error))
        }
    }

    public func dismissError() { error = nil }

    // MARK: upgrades

    /// Queues `brew upgrade` for each package, in order, and opens the sheet.
    public func startUpgrade(_ packages: [Package]? = nil) {
        guard !isUpgrading, let client = try? resolvedClient() else { return }
        let targets = (packages ?? upgradable).filter(\.upgradeAvailable)
        guard !targets.isEmpty, let detection = report?.intelbrew else { return }
        var env = client.environment(for: detection, readOnly: false)
        // Upgrade to exactly what the list shows; the refresh button is
        // where `brew update` runs.
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let brew = client.installation.brewPath
        upgrade = UpgradeSession(
            packages: targets, intelbrewMode: detection.detected, queue: queue,
            makeCommand: { p in
                let args = BrewCommands.upgradeArguments(for: p)
                return QueuedCommand(executable: brew, arguments: args, environment: env, display: BrewCommands.display(args))
            },
            logURL: deps.logURL,
            onFinish: { [weak self] _ in
                // Reconcile: what brew now says, not what we assume.
                Task { await self?.refresh(manual: false) }
            })
        showUpgradeSheet = true
    }

    /// Clears a finished session (the sheet's Done button).
    public func closeUpgrade() {
        showUpgradeSheet = false
        if upgrade?.isFinished == true { upgrade = nil }
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
