import Foundation
import Observation
import TankardCore

// v0.4 (part B): vulnerabilities, caveats, disk usage and self-updating apps.
//
// The status report stays what `brew info` says. The extra reads (`brew
// vulns --json`, `brew info --sizes`) run in the background after a status
// read, are cached next to status.json, and are laid over the report's
// packages by `InsightsStore.decorate`, so the table can sort and filter on
// them like any other column.

/// v0.4 settings, in the same UserDefaults as `AppSettings`.
@Observable @MainActor
public final class InsightSettings {
    enum Key {
        static let includeSelfUpdating = "includeSelfUpdatingApps"
        static let dontQuitApps = "dontQuitAppsDuringUpgrade"
        static let scanOnRefresh = "scanVulnerabilitiesOnRefresh"
        static let notifyNewVulnerabilities = "notifyNewVulnerabilities"
        static let seenVulnerabilities = "seenVulnerabilities"
    }

    public enum Change: Sendable { case selfUpdating, notifyVulnerabilities, other }

    @ObservationIgnored public let defaults: UserDefaults
    /// Told after a change (the store re-reads or re-decorates).
    @ObservationIgnored public var onChange: ((Change) -> Void)?

    // Every setting below ignores a write of the value it already has: no
    // observer notification, no UserDefaults write, no onChange. The same
    // rule as AppSettings.showMenuBarIcon (0.3.1): a Toggle or binding that
    // writes back an unchanged value must not invalidate anything, whatever
    // the compiler's @Observable does with equal writes.

    /// `brew outdated --greedy` for casks: also list apps that update
    /// themselves (`auto_updates true`) or are `version :latest`. Default off.
    public var includeSelfUpdatingApps: Bool {
        get { access(keyPath: \.includeSelfUpdatingApps); return _includeSelfUpdatingApps }
        set {
            guard newValue != _includeSelfUpdatingApps else { return }
            withMutation(keyPath: \.includeSelfUpdatingApps) { _includeSelfUpdatingApps = newValue }
            defaults.set(newValue, forKey: Key.includeSelfUpdating)
            onChange?(.selfUpdating)
        }
    }
    @ObservationIgnored private var _includeSelfUpdatingApps: Bool
    /// HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 for cask upgrades. Default off
    /// (brew's default: it quits a running app, upgrades it and reopens it).
    public var dontQuitAppsDuringUpgrade: Bool {
        get { access(keyPath: \.dontQuitAppsDuringUpgrade); return _dontQuitAppsDuringUpgrade }
        set {
            guard newValue != _dontQuitAppsDuringUpgrade else { return }
            withMutation(keyPath: \.dontQuitAppsDuringUpgrade) { _dontQuitAppsDuringUpgrade = newValue }
            defaults.set(newValue, forKey: Key.dontQuitApps)
        }
    }
    @ObservationIgnored private var _dontQuitAppsDuringUpgrade: Bool
    /// Run `brew vulns` after each status read. Default off: brew sends the
    /// installed formula names and versions to OSV.dev, so that happens only
    /// once the user turns this on, or clicks Scan now.
    public var scanVulnerabilitiesOnRefresh: Bool {
        get { access(keyPath: \.scanVulnerabilitiesOnRefresh); return _scanVulnerabilitiesOnRefresh }
        set {
            guard newValue != _scanVulnerabilitiesOnRefresh else { return }
            withMutation(keyPath: \.scanVulnerabilitiesOnRefresh) { _scanVulnerabilitiesOnRefresh = newValue }
            defaults.set(newValue, forKey: Key.scanOnRefresh)
        }
    }
    @ObservationIgnored private var _scanVulnerabilitiesOnRefresh: Bool
    /// A notice in the menu-bar menu when a scan finds vulnerabilities that
    /// weren't there before. Default off.
    public var notifyNewVulnerabilities: Bool {
        get { access(keyPath: \.notifyNewVulnerabilities); return _notifyNewVulnerabilities }
        set {
            guard newValue != _notifyNewVulnerabilities else { return }
            withMutation(keyPath: \.notifyNewVulnerabilities) { _notifyNewVulnerabilities = newValue }
            defaults.set(newValue, forKey: Key.notifyNewVulnerabilities)
            onChange?(.notifyVulnerabilities)
        }
    }
    @ObservationIgnored private var _notifyNewVulnerabilities: Bool
    /// The vulnerability keys already seen (nil: no baseline yet).
    public var seenVulnerabilities: Set<String>? {
        get { access(keyPath: \.seenVulnerabilities); return _seenVulnerabilities }
        set {
            guard newValue != _seenVulnerabilities else { return }
            withMutation(keyPath: \.seenVulnerabilities) { _seenVulnerabilities = newValue }
            defaults.set(newValue.map { Array($0).sorted() }, forKey: Key.seenVulnerabilities)
        }
    }
    @ObservationIgnored private var _seenVulnerabilities: Set<String>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _includeSelfUpdatingApps = defaults.bool(forKey: Key.includeSelfUpdating)
        _dontQuitAppsDuringUpgrade = defaults.bool(forKey: Key.dontQuitApps)
        _scanVulnerabilitiesOnRefresh = defaults.bool(forKey: Key.scanOnRefresh)
        _notifyNewVulnerabilities = defaults.bool(forKey: Key.notifyNewVulnerabilities)
        _seenVulnerabilities = (defaults.array(forKey: Key.seenVulnerabilities) as? [String]).map(Set.init)
    }

    /// The environment brew gets for one step, on top of the usual one:
    /// HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 for a cask upgrade when "Don't
    /// quit running apps" is on (brew documents it in `man brew`).
    public nonisolated static func extraEnvironment(_ action: SessionAction, _ p: Package, dontQuitApps: Bool) -> [String: String] {
        guard dontQuitApps, action == .upgrade, p.kind == .cask else { return [:] }
        return [noQuitKey: "1"]
    }

    public nonisolated static let noQuitKey = "HOMEBREW_NO_UPGRADE_QUIT_CASKS"

    /// The line beside the scan toggle.
    public nonisolated static let scanPrivacyNote = "Sends your installed formula names and versions to OSV.dev (via brew vulns)."
}

public extension BrewCommands {
    /// The copyable command with any extra environment in front:
    /// `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 brew upgrade --cask homebrew/cask/iterm2`.
    static func display(_ arguments: [String], environment extra: [String: String]) -> String {
        let prefix = extra.keys.sorted().map { "\($0)=\(shellQuoted(extra[$0] ?? ""))" }
        return (prefix + [display(arguments)]).joined(separator: " ")
    }
}

/// The insights cache: ~/Library/Caches/net.mindtricks.tankard/insights.json.
public struct InsightsCache: Sendable {
    public var url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        StatusCache.defaultURL.deletingLastPathComponent().appendingPathComponent("insights.json")
    }

    public struct Contents: Codable, Sendable, Equatable {
        public var vulnerabilityScan: VulnerabilityScan?
        public var sizes: DiskSizes?
        public init(vulnerabilityScan: VulnerabilityScan? = nil, sizes: DiskSizes? = nil) {
            self.vulnerabilityScan = vulnerabilityScan
            self.sizes = sizes
        }
    }

    public func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StatusReport.jsonDecoder().decode(Contents.self, from: data)
    }

    public func save(_ c: Contents) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StatusReport.jsonEncoder().encode(c).write(to: url, options: .atomic)
    }
}

/// A background read's state, for the strip and Settings.
public enum InsightState: Equatable, Sendable {
    case idle, running
    case failed(String)
    /// brew has no such command (vulns before brew 7).
    case unsupported(String)
}

/// The menu-bar notice: vulnerabilities that weren't there at the last look.
public enum VulnerabilityNotice {
    /// One key per formula and advisory id.
    public static func keys(_ scan: VulnerabilityScan?) -> Set<String> {
        guard let scan else { return [] }
        return Set(scan.findings.flatMap { name, list in list.map { "\(name)#\($0.id)" } })
    }

    /// Formulae with a vulnerability not in `seen` (sorted). No baseline: none.
    public static func newFormulae(seen: Set<String>?, scan: VulnerabilityScan?) -> [String] {
        guard let seen else { return [] }
        let added = keys(scan).subtracting(seen)
        return Set(added.compactMap { $0.split(separator: "#").first.map(String.init) }).sorted()
    }
}

/// "Upgrade vulnerable packages".
public enum VulnerabilityUpgrades {
    /// Vulnerable packages with an upgrade waiting, minus held ones
    /// (`InsightsStore.isHeld`: pinned, the same rule as Upgrade all).
    public static func targets(_ packages: [Package], isHeld: (Package) -> Bool) -> [Package] {
        packages.filter { $0.isVulnerable && $0.upgradeAvailable && !isHeld($0) }
    }

    /// Vulnerable packages no upgrade fixes yet (brew's tap has nothing newer).
    public static func withoutUpgrade(_ packages: [Package]) -> [Package] {
        packages.filter { $0.isVulnerable && !$0.upgradeAvailable }
    }
}

public extension Package {
    var isVulnerable: Bool { !(vulnerabilities ?? []).isEmpty }
    /// The most severe open vulnerability.
    var worstSeverity: VulnerabilitySeverity? { vulnerabilities?.map(\.severity).max() }
    /// The Size column's sort key (unknown sizes sort first).
    var sizeSortKey: Int64 { diskBytes ?? -1 }
    var hasCaveats: Bool { caveats != nil }

    /// The table's warning badge: "⚠ High · 3".
    var vulnerabilityBadge: String? {
        guard let list = vulnerabilities, !list.isEmpty, let worst = worstSeverity else { return nil }
        let word = worst == .unknown ? "Vulnerable" : worst.label
        return list.count > 1 ? "\(word) · \(list.count)" : word
    }
}

/// Caveats as shown: brew writes the prefix as `$HOMEBREW_PREFIX`; the app
/// shows this Mac's prefix instead, so commands can be copied as they are.
public enum Caveats {
    public static func display(_ text: String, prefix: String?) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix, !prefix.isEmpty { t = t.replacingOccurrences(of: "$HOMEBREW_PREFIX", with: prefix) }
        return t
    }
}

/// The one-time "Post-install notes" sheet after an install or upgrade:
/// the caveats of what just changed.
public struct PostInstallNotes: Identifiable, Equatable, Sendable {
    public struct Note: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: String
        public var kind: PackageKind
        public var text: String
    }

    public var id = UUID()
    public var action: SessionAction
    public var notes: [Note]

    /// Notes for the packages that `action` changed, read from the status
    /// after the run (so the text is brew's for the new version). nil when
    /// none has caveats, or for other actions.
    public static func make(action: SessionAction, changedIDs: [String], packages: [Package], prefix: String?) -> PostInstallNotes? {
        guard action == .upgrade || action == .install else { return nil }
        let byID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let notes = changedIDs.compactMap { id -> Note? in
            guard let p = byID[id], let c = p.caveats else { return nil }
            return Note(id: p.id, name: p.name, version: p.installedVersion, kind: p.kind, text: Caveats.display(c, prefix: prefix))
        }
        return notes.isEmpty ? nil : PostInstallNotes(action: action, notes: notes)
    }

    /// "Notes from 2 upgraded packages".
    public var subtitle: String {
        "Notes from \(notes.count) \(action.past) package\(notes.count == 1 ? "" : "s")"
    }
}

/// The background reads and their results. One per AppStore.
@Observable @MainActor
public final class InsightsStore {
    public private(set) var vulnerabilityScan: VulnerabilityScan?
    public private(set) var scanState: InsightState = .idle
    public private(set) var sizes: DiskSizes?
    public private(set) var sizesState: InsightState = .idle
    /// 0.6.1: when the running scan started (nil when none runs).
    public private(set) var scanStartedAt: Date?
    /// 0.6.1: how many formulae the running scan checks ("Scanning N formulae…").
    public private(set) var scanFormulaCount = 0
    /// 0.6.1: how the last scan this session ended (nil: none yet, or it failed).
    public private(set) var scanOutcome: ScanOutcome?
    /// The post-install notes sheet.
    public var postInstallNotes: PostInstallNotes?
    /// Notes waiting for the activity sheet to close.
    @ObservationIgnored var pendingNotes: PostInstallNotes?

    public let settings: InsightSettings
    @ObservationIgnored let cache: InsightsCache?
    @ObservationIgnored let ttl: TimeInterval
    @ObservationIgnored let now: @Sendable () -> Date
    /// Called when a result arrives (the store re-decorates its report).
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Packages "Upgrade vulnerable packages" leaves alone: `Package.isHeld`
    /// (pinned), the rule Upgrade all, the menu-bar count and notifications
    /// use. A hook so tests can hold others.
    @ObservationIgnored public var isHeld: (Package) -> Bool = { $0.isHeld }
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// How long `brew vulns` may run before it is stopped (its whole
    /// process group, as for any cancelled brew call) and the scan reported
    /// as timed out. A setting so tests can shorten it.
    @ObservationIgnored public var scanTimeout: Duration = .seconds(60)
    public static let scanTimedOutMessage = "Scan timed out: brew vulns ran for more than a minute and was stopped. The last result, if any, is kept."
    @ObservationIgnored private var sizesTask: Task<Void, Never>?

    public init(settings: InsightSettings, cache: InsightsCache?, ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.settings = settings
        self.cache = cache
        self.ttl = ttl
        self.now = now
        if let c = cache?.load() {
            vulnerabilityScan = c.vulnerabilityScan
            sizes = c.sizes
        }
    }

    // MARK: decoration

    /// The report with this store's results laid over it: vulnerabilities,
    /// sizes, and self-updating casks unmarked when that setting is off.
    /// Idempotent: every field is set from scratch.
    public func decorate(_ report: StatusReport) -> StatusReport {
        var r = settings.includeSelfUpdatingApps ? report : SelfUpdatingCasks.unmark(report)
        for i in r.packages.indices {
            r.packages[i].vulnerabilities = vulnerabilityScan?.vulnerabilities(for: r.packages[i])
            r.packages[i].diskBytes = sizes?.bytes(for: r.packages[i])
        }
        return extraDecoration?(r) ?? r
    }

    /// 0.6: laid over after the insights (skipped versions).
    @ObservationIgnored public var extraDecoration: ((StatusReport) -> StatusReport)?

    /// Total bytes of the packages listed (nil before the first measurement).
    public func totalBytes(_ packages: [Package]) -> Int64? {
        guard sizes != nil else { return nil }
        return packages.reduce(0) { $0 + ($1.diskBytes ?? 0) }
    }

    public func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return now().timeIntervalSince(date) > ttl
    }

    // MARK: running

    /// After a status read. `force`: the status changed (manual refresh,
    /// reconcile after a run); otherwise only what is older than the TTL.
    public func refresh(client: BrewClient, env: [String: String], force: Bool, formulae: Int = 0) {
        if force || isStale(sizes?.measuredAt) { measureSizes(client: client, env: env) }
        if settings.scanVulnerabilitiesOnRefresh, force || isStale(vulnerabilityScan?.scannedAt) {
            scanVulnerabilities(client: client, env: env, formulae: formulae)
        }
    }

    /// Writes only a real change (0.6.1 state; no equal-write notifications).
    private func assign<T: Equatable>(_ kp: ReferenceWritableKeyPath<InsightsStore, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }

    /// The scan ended: not running any more, and how it ended.
    private func scanEnded(_ state: InsightState, outcome: ScanOutcome?) {
        assign(\.scanState, state)
        assign(\.scanStartedAt, nil)
        assign(\.scanOutcome, outcome)
    }

    /// 0.6.1: Stop. Cancels the running scan, which stops brew vulns' whole
    /// process group (as the timeout does); the last result is kept.
    /// Nothing runs: nothing changes.
    public func stopScan() {
        guard scanState == .running else { return }
        scanTask?.cancel()
        scanEnded(.idle, outcome: .stopped)
    }

    /// `brew vulns --json` in the background (a new request replaces a
    /// running one), stopped after `scanTimeout`.
    public func scanVulnerabilities(client: BrewClient, env: [String: String], formulae: Int = 0) {
        scanTask?.cancel()
        assign(\.scanState, .running)
        assign(\.scanStartedAt, now())
        assign(\.scanFormulaCount, formulae)
        assign(\.scanOutcome, nil)
        let now = self.now
        let timeout = scanTimeout
        scanTask = Task { [weak self] in
            do {
                // Race the scan against the clock. When the clock wins,
                // cancelling the scan's task makes ProcessRunner SIGTERM
                // (then SIGKILL) brew's process group.
                let result = try await withThrowingTaskGroup(of: VulnerabilityScan?.self) { group in
                    group.addTask { try await client.vulnerabilityScan(env: env, now: now()) }
                    group.addTask { try await Task.sleep(for: timeout); return nil }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                guard !Task.isCancelled else { return }
                guard let scan = result else {
                    self?.scanEnded(.failed(Self.scanTimedOutMessage), outcome: .timedOut)
                    return
                }
                self?.scanFinished(scan)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if case InsightError.unsupported(let s) = error {
                    self?.scanEnded(.unsupported(s), outcome: nil)
                } else {
                    // Keep the last result; say what went wrong.
                    self?.scanEnded(.failed(String(describing: error)), outcome: nil)
                }
            }
        }
    }

    /// `brew info --sizes` in the background.
    public func measureSizes(client: BrewClient, env: [String: String]) {
        sizesTask?.cancel()
        sizesState = .running
        let now = self.now
        sizesTask = Task { [weak self] in
            do {
                let s = try await client.diskSizes(env: env, now: now())
                guard !Task.isCancelled else { return }
                self?.sizesFinished(s)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.sizesState = .failed(String(describing: error))
            }
        }
    }

    /// Waits for running reads (tests, snapshots).
    public func waitForIdle() async {
        await scanTask?.value
        await sizesTask?.value
    }

    func scanFinished(_ scan: VulnerabilityScan) {
        vulnerabilityScan = scan
        scanEnded(.idle, outcome: .done(checked: scan.checked, found: scan.vulnerableCount, complete: scan.complete))
        if settings.notifyNewVulnerabilities, settings.seenVulnerabilities == nil {
            // First scan after turning the notice on: the baseline.
            settings.seenVulnerabilities = VulnerabilityNotice.keys(scan)
        }
        save()
        onUpdate?()
    }

    func sizesFinished(_ s: DiskSizes) {
        sizes = s
        sizesState = .idle
        save()
        onUpdate?()
    }

    private func save() {
        try? cache?.save(.init(vulnerabilityScan: vulnerabilityScan, sizes: sizes))
    }

    // MARK: the menu-bar notice

    /// Formulae with vulnerabilities found since the user last looked, when
    /// the notice is on.
    public var newVulnerableFormulae: [String] {
        guard settings.notifyNewVulnerabilities else { return [] }
        return VulnerabilityNotice.newFormulae(seen: settings.seenVulnerabilities, scan: vulnerabilityScan)
    }

    /// The user looked (opened the Vulnerable list from the notice).
    public func markVulnerabilitiesSeen() {
        settings.seenVulnerabilities = VulnerabilityNotice.keys(vulnerabilityScan)
    }

    /// The notice was turned on: start from what is known now.
    func noticeTurnedOn() {
        settings.seenVulnerabilities = vulnerabilityScan.map(VulnerabilityNotice.keys)
    }

    // MARK: post-install notes

    /// Shows the notes now, or when the activity sheet closes.
    func offer(_ notes: PostInstallNotes?, sheetOpen: Bool) {
        guard let notes else { return }
        if sheetOpen { pendingNotes = notes } else { postInstallNotes = notes }
    }

    /// The activity sheet closed: show notes that were waiting, once it
    /// has gone (one sheet replacing another in the same moment can be lost).
    func presentPending() {
        guard let n = pendingNotes else { return }
        pendingNotes = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            postInstallNotes = n
        }
    }

    /// The upgrade command as the detail pane shows it (with brew's
    /// variable in front when "Don't quit running apps" applies).
    public func upgradeDisplay(for p: Package) -> String {
        let args = BrewCommands.upgradeArguments(for: p)
        return BrewCommands.display(args, environment: InsightSettings.extraEnvironment(.upgrade, p, dontQuitApps: settings.dontQuitAppsDuringUpgrade))
    }
}
