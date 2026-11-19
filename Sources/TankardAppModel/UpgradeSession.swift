import AskpassSupport
import Foundation
import Observation
import TankardCore

/// What a sheet run does to its packages.
public enum SessionAction: String, Sendable {
    case upgrade, install, uninstall
    /// 0.3: `brew reinstall --force-bottle` of a source build.
    case replaceBottle
    /// 0.3: `brew cleanup` (one command, no packages).
    case cleanup
    /// 0.6: `brew autoremove` (one command, no packages).
    case autoremove
    /// 0.7: `brew tap` / `brew untap` (one command; the row is the tap).
    case tap, untap
    /// 0.7: a restore point's plan (reinstall, uninstall + link, pin).
    case restore
    /// 0.8: `brew install --cask --adopt` of an app already in /Applications.
    case adopt

    /// "Upgrade", "Install", "Uninstall", "Reinstall", "Cleanup"
    public var verb: String {
        switch self {
        case .upgrade: return String(localized: "Upgrade")
        case .install: return String(localized: "Install")
        case .uninstall: return String(localized: "Uninstall")
        case .replaceBottle: return String(localized: "Reinstall")
        case .cleanup: return String(localized: "Cleanup")
        case .autoremove: return String(localized: "Remove unused")
        case .tap: return String(localized: "Add tap")
        case .untap: return String(localized: "Remove tap")
        case .restore: return String(localized: "Restore")
        case .adopt: return String(localized: "Adopt")
        }
    }
    /// "Upgrading", "Installing", "Uninstalling", "Reinstalling", "Cleaning up"
    public var gerund: String {
        switch self {
        case .upgrade: return String(localized: "Upgrading")
        case .install: return String(localized: "Installing")
        case .uninstall: return String(localized: "Uninstalling")
        case .replaceBottle: return String(localized: "Reinstalling")
        case .cleanup: return String(localized: "Cleaning up")
        case .autoremove: return String(localized: "Removing unused dependencies")
        case .tap: return String(localized: "Adding tap")
        case .untap: return String(localized: "Removing tap")
        case .restore: return String(localized: "Restoring")
        case .adopt: return String(localized: "Adopting")
        }
    }
    /// "upgraded", "installed", "uninstalled", "reinstalled", "done": the
    /// finished line's word after a count ("5 upgraded", "1 upgraded"), so
    /// the same for one or many.
    public var past: String {
        switch self {
        case .upgrade: return String(localized: "upgraded")
        case .install: return String(localized: "installed")
        case .uninstall: return String(localized: "uninstalled")
        case .replaceBottle: return String(localized: "reinstalled")
        case .cleanup: return String(localized: "done")
        case .autoremove: return String(localized: "done")
        case .tap: return String(localized: "tapped")
        case .untap: return String(localized: "untapped")
        case .restore: return String(localized: "done")
        case .adopt: return String(localized: "adopted")
        }
    }
}

/// One run of the upgrade sheet: a queued `brew upgrade` per package, the
/// live log, and per-package state.
///
/// Events from the queue arrive on a background thread. They go through an
/// `AsyncStream` and one consumer task applies them on the main actor, so
/// they are handled in exactly the order they happened.
@Observable @MainActor
public final class UpgradeSession: Identifiable {
    public enum ItemState: Equatable, Sendable {
        case waiting, running, done, failed(Int32), cancelled
        /// 0.8: not run: a check right before it said it no longer should.
        case skipped

        public var isTerminal: Bool {
            switch self {
            case .waiting, .running: return false
            default: return true
            }
        }
    }

    public struct Item: Identifiable, Equatable {
        /// The queue's id for this command.
        public var id: UUID
        public var package: Package
        public var command: QueuedCommand
        public var state: ItemState
    }

    public let id = UUID()
    public private(set) var items: [Item]
    public private(set) var log = LineAssembler()
    /// Set when a step failed because it needed sudo: the command to run in
    /// Terminal instead.
    public private(set) var sudoCommand: String?
    /// 0.8.3: why that step didn't get administrator rights (the dialog
    /// was cancelled, the password was wrong, no dialog could ask).
    public private(set) var sudoOutcome: SudoOutcome?
    /// 0.3: cask steps macOS blocked (App Management), by item id.
    public private(set) var appManagementBlocked: [UUID] = []
    /// 0.6: recognised failures (brew's lock, network, disk, permissions), in order.
    public private(set) var failureKinds: [BrewFailureKind] = []
    /// 0.8.6 (L1): each failed step's recognised failure.
    public private(set) var failureKindByItem: [UUID: BrewFailureKind] = [:]
    /// 0.3: this run is the one retry after the App Management sheet.
    public var isRetry = false
    public private(set) var stopRequested = false
    /// 0.8.3: Stop Now was clicked: brew is being interrupted (it can take
    /// a few seconds to undo its unfinished step).
    public private(set) var stoppingNow = false
    /// 0.8.3: the running step waits for another brew to release brew's
    /// lock (the holder, "pid command", or "" when not known).
    public private(set) var lockWait: String?
    /// 0.8.3: the sheet's "Stop now?" confirmation is up.
    public var confirmingStop = false
    public private(set) var isFinished = false
    public let intelbrewMode: Bool
    public let action: SessionAction
    public let logURL: URL?
    /// 0.8: what the running command is downloading now (nil: nothing, or
    /// not known). Watched from brew's downloads folder, not its output.
    public private(set) var download: DownloadProgress?
    /// 0.8: how many times a download was seen (e2e checks, tests).
    public private(set) var downloadObservations = 0
    /// 0.8.5: when each step started (the build line's time so far).
    public private(set) var itemStartedAt: [UUID: Date] = [:]
    /// 0.8.5: steps the plan says build from source, and this Mac's
    /// estimate for each (BuildProgress.swift).
    public private(set) var compilingItems: Set<UUID> = []
    public private(set) var buildEstimates: [UUID: TimeInterval] = [:]
    /// 0.8.5: compile steps where brew poured a bottle after all.
    public private(set) var pouringItems: Set<UUID> = []
    /// The clock for `itemStartedAt` (tests set it).
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }

    func setBuildProgress(compiling: Set<UUID>, estimates: [UUID: TimeInterval]) {
        compilingItems = compiling
        buildEstimates = estimates
    }

    @ObservationIgnored private let queue: CommandQueue
    @ObservationIgnored private let logFile: LogFile?
    @ObservationIgnored private var onFinish: (@MainActor (UpgradeSession) -> Void)?
    /// Finished lines of the running command (for sudo detection).
    @ObservationIgnored private var commandLines: [String] = []
    /// 0.8.4: the running step's password note is in the log.
    @ObservationIgnored private var passwordNoted = false
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// 0.7: steps sharing a key run as a chain: when one fails, the rest of
    /// its chain still waiting is skipped (a restore's link after a failed
    /// uninstall).
    @ObservationIgnored private var chainKey: ((Package) -> String?)?
    @ObservationIgnored private let downloads: DownloadMonitor?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// 0.8.3: the `brew fetch` steps queued before the packages (Prefetch.swift).
    public let prefetch: [PrefetchStep]
    @ObservationIgnored private let prefetchIDs: [UUID]
    /// Per fetch step (by id): its state, and how many of its packages it finished.
    public private(set) var fetchStates: [UUID: ItemState] = [:]
    private var fetchFinished: [UUID: Int] = [:]
    /// 0.8.3: brew's sudo is showing Tankard's password dialog now (the
    /// helper process is running for this command). The sheet then keeps
    /// the Terminal route in view.
    public private(set) var awaitingPassword = false
    /// 0.8.3: finds the helper and hands it focus (AskpassFocus). nil: no
    /// watching (tests that don't ask, demo mode).
    @ObservationIgnored public var passwordFocus: AskpassFocus?
    /// 0.8.4: brew.env's own password helper, when the session started with
    /// one (ForeignAskpass): sudo-capable steps run without sudo or are
    /// refused, and the sheet says why with the Terminal command.
    @ObservationIgnored public var foreignAskpass: ForeignAskpass?
    @ObservationIgnored private var passwordTask: Task<Void, Never>?
    /// 0.8.4: an uninstall left versions installed (brew's "is still
    /// installed", or the check after the run): name → versions.
    public private(set) var stillInstalled: [String: [String]] = [:]
    /// 0.8.4: the run is over and what is still installed is being read
    /// again; the sheet doesn't say "complete" before that has answered.
    public private(set) var checkingInstalled = false
    /// 0.8.6 (VM test M1): reads the installed version of each package
    /// (id → version and linked keg) after an upgrade run with failed
    /// steps; nil: the read failed. brew exits 1 for the whole command
    /// when a later part fails (a dependent it upgrades next, refused over
    /// a pinned dependency), after it has upgraded the package asked for.
    @ObservationIgnored private let upgradeCheck: (@Sendable ([Package]) async -> [String: InstalledNow]?)?
    @ObservationIgnored private var upgradeChecked = false
    /// The read is running: the run isn't finished until it answers.
    public private(set) var checkingUpgraded = false
    /// Steps brew exited non-zero for although the package was upgraded.
    public private(set) var upgradedAnyway: Set<UUID> = []
    /// 0.8.6 (HK-47 review): those of them whose output names another
    /// package as what failed.
    public private(set) var upgradedOverAnotherPackage: Set<UUID> = []
    /// The output of each upgrade step brew exited non-zero for.
    @ObservationIgnored private var failedStepOutput: [UUID: [String]] = [:]

    init(packages: [Package], intelbrewMode: Bool, action: SessionAction = .upgrade, queue: CommandQueue,
         makeCommand: (Package) -> QueuedCommand, logURL: URL?,
         chainKey: ((Package) -> String?)? = nil,
         precondition: ((Package) -> (@Sendable () -> String?)?)? = nil,
         skipCheck: ((Package) -> CommandQueue.SkipCheck?)? = nil,
         downloads: DownloadMonitor? = nil,
         prefetch: [PrefetchStep] = [],
         lockWait: BrewLockWait? = nil,
         upgradeCheck: (@Sendable ([Package]) async -> [String: InstalledNow]?)? = nil,
         onFinish: @escaping @MainActor (UpgradeSession) -> Void) {
        self.chainKey = chainKey
        self.upgradeCheck = upgradeCheck
        self.prefetch = prefetch
        let prefetchIDs = prefetch.map { _ in UUID() }
        self.prefetchIDs = prefetchIDs
        self.downloads = DownloadMonitor.watches(action) ? downloads : nil
        self.intelbrewMode = intelbrewMode
        self.action = action
        self.queue = queue
        self.logURL = logURL
        self.logFile = logURL.map(LogFile.init)
        self.onFinish = onFinish
        self.items = packages.map { p in
            Item(id: UUID(), package: p, command: makeCommand(p), state: .waiting)
        }
        for id in prefetchIDs { fetchStates[id] = .waiting }

        let (stream, continuation) = AsyncStream.makeStream(of: (UUID, CommandEvent).self, bufferingPolicy: .unbounded)
        consumer = Task { @MainActor [weak self] in
            for await (itemID, event) in stream {
                self?.apply(event, to: itemID)
            }
        }
        // 0.7: for each step, the later steps of its chain. Cancelled from
        // the queue's own thread, before the queue takes its next job, so a
        // failed step's chain can never start.
        var chainRest: [UUID: [UUID]] = [:]
        if let chainKey {
            let keys = items.map { chainKey($0.package) }
            for (i, item) in items.enumerated() {
                guard let k = keys[i] else { continue }
                chainRest[item.id] = items.indices.filter { $0 > i && keys[$0] == k }.map { items[$0].id }
            }
        }
        // 0.8.3: the downloads first, all at once; then each package's step
        // pours from the cache. A failed fetch stops nothing: the steps run.
        for (i, step) in prefetch.enumerated() {
            let stepID = prefetchIDs[i]
            queue.enqueue(step.command, id: stepID) { event in
                continuation.yield((stepID, event))
            }
        }
        // Enqueued in package order; the queue runs them strictly in order.
        for item in items {
            let itemID = item.id
            let rest = chainRest[itemID] ?? []
            queue.enqueue(item.command, id: itemID, precondition: precondition?(item.package),
                          skipCheck: skipCheck?(item.package), lockWait: lockWait) { [queue] event in
                if !rest.isEmpty {
                    switch event {
                    case .finished(let code) where code != 0: queue.cancel(rest)
                    case .failed: queue.cancel(rest)
                    default: break
                    }
                }
                continuation.yield((itemID, event))
            }
        }
    }

    // MARK: derived state for the sheet

    public var total: Int { items.count }
    public var completedCount: Int { items.filter { $0.state.isTerminal }.count }
    /// 0.8.4: the packages, once each (an uninstall runs one step per
    /// installed version of a formula).
    public var packages: [Package] {
        var seen = Set<Package.ID>()
        return items.map(\.package).filter { seen.insert($0.id).inserted }
    }
    /// Finished with nothing wrong: no failed step and nothing left installed.
    public var hasProblems: Bool { !failedItems.isEmpty || !stillInstalled.isEmpty }
    public var succeededCount: Int { items.filter { $0.state == .done && !doneElsewhere.contains($0.id) }.count }
    /// 0.8.6 (M3): steps brew found already done ("already installed",
    /// exit 0): another Homebrew command, often in Terminal while Tankard
    /// waited for brew's lock, did the work. Not counted as Tankard's.
    public private(set) var doneElsewhere: Set<UUID> = []
    public var failedItems: [Item] { items.filter { if case .failed = $0.state { true } else { false } } }
    public var current: Item? { items.first { $0.state == .running } }

    /// 0.8.5 (test pass L3): an uninstall with one step per installed
    /// version of a formula: its count says versions, not packages.
    public var countsVersions: Bool { action == .uninstall && total > packages.count }

    /// 0.8.5: the version each uninstall step removed, from brew's
    /// "Uninstalling /opt/homebrew/Cellar/xz/5.8.3... (95 files, 1.9MB)".
    public private(set) var removedVersions: [UUID: String] = [:]

    /// 0.8.5 (test pass L3): a step's chip. A formula uninstalled version
    /// by version: "xz 5.8.3" once brew has said which one it removed;
    /// before that, the version the step expects (the linked one first,
    /// then newest first, as brew picks them), else "xz (1 of 2)".
    public func chipName(_ item: Item) -> String {
        let name = item.package.name
        guard action == .uninstall else { return name }
        let steps = items.filter { $0.package.id == item.package.id }
        guard steps.count > 1 else { return name }
        if let v = removedVersions[item.id] { return "\(name) \(v)" }
        // Until brew says which: the version the step expects to remove
        // (AppStore.uninstallSteps, bug hunt L9), when each step has its own.
        let expected = item.package.installedVersion
        if !expected.isEmpty, Set(steps.map(\.package.installedVersion)).count == steps.count { return "\(name) \(expected)" }
        let k = (steps.firstIndex { $0.id == item.id } ?? 0) + 1
        return String(localized: "\(name) (\(k) of \(steps.count))")
    }

    /// The version in brew's "Uninstalling <cellar>/<name>/<version>..."
    /// line, if `lines` have one for `name`.
    nonisolated static func removedVersion(_ lines: [String], name: String) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Uninstalling /"), let end = t.range(of: "...") else { continue }
            let path = t[t.index(t.startIndex, offsetBy: "Uninstalling ".count)..<end.lowerBound]
            let parts = path.split(separator: "/")
            guard parts.count >= 2, parts[parts.count - 2] == name else { continue }
            return String(parts[parts.count - 1])
        }
        return nil
    }
    /// The packages whose step macOS blocked.
    public var blockedPackages: [Package] { items.filter { appManagementBlocked.contains($0.id) }.map(\.package) }

    /// 0...1, counting finished packages (while prefetching, downloaded ones).
    public var fraction: Double {
        if isFetching { return fetchTotal == 0 ? 0 : Double(fetchedCount) / Double(fetchTotal) }
        return total == 0 ? 1 : Double(completedCount) / Double(total)
    }

    // MARK: prefetch (0.8.3)

    /// A `brew fetch` step is running.
    public var isFetching: Bool { fetchStates.values.contains(.running) }
    /// The packages the fetch steps download, and how many of them are done.
    public var fetchTotal: Int { prefetch.reduce(0) { $0 + $1.targets.count } }
    public var fetchedCount: Int {
        zip(prefetchIDs, prefetch).reduce(0) { $0 + min(fetchFinished[$1.0] ?? 0, $1.1.targets.count) }
    }
    /// The running fetch command (the sheet's command box).
    public var runningFetch: QueuedCommand? {
        zip(prefetchIDs, prefetch).first { fetchStates[$0.0] == .running }?.1.command
    }

    /// "Upgrading 5 packages" / "Installing xz"
    public var title: String {
        let verb = action.verb
        if isFinished {
            if stopRequested && items.contains(where: { $0.state == .cancelled }) { return String(localized: "\(verb) stopped") }
            if checkingInstalled { return String(localized: "Checking what is still installed…") }
            // 0.8.6 (UI M5): the same phrase as the progress window's title.
            if !failedItems.isEmpty { return String(localized: "\(verb) finished with problems") }
            if !stillInstalled.isEmpty { return String(localized: "Uninstall incomplete") }
            if !doneElsewhere.isEmpty, succeededCount == 0 { return String(localized: "Already up to date (done elsewhere)") }
            return String(localized: "\(verb) complete")
        }
        if action == .cleanup { return String(localized: "Cleaning up") }
        if action == .restore { return total == 1 ? String(localized: "Restoring (\(total) step)") : String(localized: "Restoring (\(total) steps)") }
        if action == .replaceBottle {
            return total == 1 ? String(localized: "Reinstalling \(items[0].package.name) from a bottle") : String(localized: "Reinstalling \(total) packages from bottles")
        }
        if action == .uninstall && packages.count == 1 { return String(localized: "\(action.gerund) \(items[0].package.name)") }
        if action != .upgrade && total == 1 { return String(localized: "\(action.gerund) \(items[0].package.name)") }
        // An uninstall counts packages, not its one-per-version steps: a
        // formula with two kegs and one dependency is 2 packages, not 3.
        let n = action == .uninstall ? packages.count : total
        return n == 1 ? String(localized: "\(action.gerund) \(n) package") : String(localized: "\(action.gerund) \(n) packages")
    }

    /// "4 bottles from Intelbrew · 1 build from source (rust)"
    public var subtitle: String {
        if action == .uninstall {
            // 0.8: more than one item is the package and its no-longer-needed dependencies.
            if packages.count > 1 { return String(localized: "With the dependencies nothing else needs") }
            // 0.8.4: one step per installed version.
            if total > 1 { return String(localized: "Every installed version, one brew uninstall each") }
            return String(localized: "Its dependencies stay installed (brew autoremove removes unused ones)")
        }
        if action == .cleanup {
            return String(localized: "Removes old versions, stale downloads and old logs")
        }
        if action == .restore {
            return String(localized: "Back to a restore point, one brew command at a time")
        }
        if action == .replaceBottle {
            let ib = items.filter { BottleReplacement.origin($0.package) == .intelbrew }.count
            let n = items.count
            return intelbrewMode && ib == n ? String(localized: "Swaps source builds for Intelbrew bottles")
                : (n == 1 ? String(localized: "Swaps source build for bottle") : String(localized: "Swaps source builds for bottles"))
        }
        // 0.8.5 (HK-47 review): Remove Unused whose keep step failed
        // removed nothing (the autoremove was skipped).
        if action == .autoremove, let kept = keepStepFailed {
            return String(localized: "Nothing was removed because keeping \(kept) failed.")
        }
        // 0.8.4: once finished with failures, what was actually done, not
        // the plan: a failed download said "1 build from source" although
        // nothing was built. Nothing done: why, when brew's output says.
        // 0.8.6 (M3): steps brew found already done aren't Tankard's work.
        var packages = items.filter { !doneElsewhere.contains($0.id) }.map(\.package)
        let already = items.filter { doneElsewhere.contains($0.id) }.count
        if isFinished && !failedItems.isEmpty {
            packages = items.filter { $0.state == .done && !doneElsewhere.contains($0.id) }.map(\.package)
            if packages.isEmpty {
                return failureKinds.last?.title ?? String(localized: "The log below shows what brew printed")
            }
        }
        // 0.8.6 (VM test L3): a tap formula's ready-made download isn't a build.
        let readyMade = packages.filter { $0.kind == .formula && $0.prebuiltDownload == true }.count
        let formulae = packages.filter { $0.kind == .formula && $0.prebuiltDownload != true }
        let bottles = formulae.filter { $0.upgradeHasBottle == true }
        let compiles = formulae.filter { $0.upgradeHasBottle != true }
        let casks = packages.filter { $0.kind == .cask }.count
        var parts: [String] = []
        if !bottles.isEmpty && action == .install && intelbrewMode {
            // Installs know whose bottle it is (from the catalogue).
            let ib = bottles.filter { $0.bottleOrigin == .intelbrew }.count
            if ib > 0 { parts.append(ib == 1 ? String(localized: "\(ib) bottle from Intelbrew") : String(localized: "\(ib) bottles from Intelbrew")) }
            let other = bottles.count - ib
            if other > 0 { parts.append(other == 1 ? String(localized: "\(other) Homebrew bottle") : String(localized: "\(other) Homebrew bottles")) }
        } else if !bottles.isEmpty {
            let from = intelbrewMode ? String(localized: " from Intelbrew") : ""
            parts.append((bottles.count == 1 ? String(localized: "\(bottles.count) bottle") : String(localized: "\(bottles.count) bottles")) + from)
        }
        if !compiles.isEmpty {
            let names = compiles.count <= 3 ? " (\(compiles.map(\.name).joined(separator: ", ")))" : ""
            parts.append((compiles.count == 1 ? String(localized: "\(compiles.count) build from source") : String(localized: "\(compiles.count) builds from source")) + names)
        }
        if readyMade > 0 {
            parts.append(readyMade == 1 ? String(localized: "\(readyMade) ready-made program") : String(localized: "\(readyMade) ready-made programs"))
        }
        if casks > 0 { parts.append(casks == 1 ? String(localized: "\(casks) cask") : String(localized: "\(casks) casks")) }
        if already > 0 { parts.append(String(localized: "\(already) already up to date")) }
        return parts.joined(separator: " · ")
    }

    /// "Upgrading python@3.15…" / "Done: 4 upgraded, 1 failed"
    public var statusLine: String { statusLine(behindBrewUpdate: false) }

    /// Nothing has started yet: the queue is still running something else.
    public var notStarted: Bool {
        !isFinished && items.allSatisfy { $0.state == .waiting } && fetchStates.values.allSatisfy { $0 == .waiting }
    }

    /// 0.8: `behindBrewUpdate` (AppStore.sessionWaitsForBrewUpdate): the
    /// first step is queued behind a background `brew update`, which can take
    /// a minute or two; say so instead of a bare "Waiting for brew…".
    public func statusLine(behindBrewUpdate: Bool) -> String {
        if behindBrewUpdate && notStarted { return String(localized: "Waiting for brew update to finish…") }
        if stoppingNow, let c = current { return String(localized: "Stopping \(c.package.name)…") }
        if lockWait != nil, current != nil { return String(localized: "Waiting for another Homebrew command to finish…") }
        if action == .cleanup, current != nil { return String(localized: "Running brew cleanup…") }
        if isFetching {
            // 0.8.3: "Downloading 4 of 9 · 120.0 of 410.0 MB (29%)"
            let head = String(localized: "Downloading \(fetchedCount) of \(fetchTotal)")
            return download.map { head + " · " + $0.detail } ?? head + "…"
        }
        if let c = current, let d = download {
            // 0.8: "Downloading font-inter… 12.3 of 33.7 MB (36%)"; a
            // dependency's bottle by its own name.
            return String(localized: "Downloading \(d.name ?? c.package.name)…") + " " + d.detail
        }
        if let c = current { return String(localized: "\(action.gerund) \(c.package.name)…") }
        if checkingUpgraded { return String(localized: "Checking what brew upgraded…") }
        if isFinished {
            // 0.8.4: an uninstall counts packages (all of its steps done), not steps.
            let succeeded = action == .uninstall
                ? packages.filter { p in items.allSatisfy { $0.package.id != p.id || $0.state == .done } && stillInstalled[p.name] == nil }.count
                : succeededCount
            // 0.8.5: with one step per version, both counts, in words.
            let versions = items.filter { $0.state == .done }.count
            var parts = [countsVersions ? (versions == 1 ? String(localized: "\(succeeded) uninstalled (\(versions) version)")
                                                        : String(localized: "\(succeeded) uninstalled (\(versions) versions)"))
                                        : String(localized: "\(succeeded) \(action.past)")]
            if !stillInstalled.isEmpty {
                parts.append(stillInstalled.keys.sorted().map { n in
                    String(localized: "\(n) \(stillInstalled[n, default: []].joined(separator: ", ")) still installed")
                }.joined(separator: ", "))
            }
            if !doneElsewhere.isEmpty { parts.append(String(localized: "\(doneElsewhere.count) already up to date")) }
            if !failedItems.isEmpty { parts.append(String(localized: "\(failedItems.count) failed")) }
            let skipped = items.filter { $0.state == .cancelled }.count
            if skipped > 0 { parts.append(String(localized: "\(skipped) stopped")) }
            let kept = items.filter { $0.state == .skipped }.count
            if kept > 0 { parts.append(String(localized: "\(kept) skipped")) }
            return parts.joined(separator: ", ")
        }
        return String(localized: "Waiting for brew…")
    }

    /// "2 of 5"
    public var countLine: String {
        let n = current.map { c in (items.firstIndex { $0.id == c.id } ?? 0) + 1 } ?? completedCount
        // 0.8.5: "3 of 4 versions" beside "2 uninstalled (4 versions)".
        if countsVersions { return String(localized: "\(n) of \(total) versions") }
        return String(localized: "\(n) of \(total)")
    }

    // MARK: controls

    /// Lets the running command finish, then skips the rest.
    public func stopAfterCurrent() {
        stopRequested = true
        queue.cancel(prefetchIDs.filter { fetchStates[$0] == .waiting })
        queue.cancel(items.filter { $0.state == .waiting }.map(\.id))
    }

    /// Stops the running command too (its whole process group).
    public func stopNow() {
        stopRequested = true
        queue.cancel(prefetchIDs.filter { fetchStates[$0]?.isTerminal == false })
        if current != nil { stoppingNow = true }
        queue.cancel(items.filter { !$0.state.isTerminal }.map(\.id))
    }

    // MARK: events

    private func apply(_ event: CommandEvent, to itemID: UUID) {
        if let s = prefetchIDs.firstIndex(of: itemID) { return applyFetch(event, step: s) }
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        // The running command ended: its downloads are over too. (A waiting
        // item's cancel must not stop the running one's watcher.)
        switch event {
        case .started, .output: break
        default:
            if items[i].state == .running {
                stopWatchingDownloads()
                stopWatchingPassword()
            }
        }
        switch event {
        case .started:
            items[i].state = .running
            itemStartedAt[itemID] = now()
            watchDownloads(of: items[i].package)
            if items[i].command.environment[Askpass.askpassKey] != nil { watchPassword() }
            commandLines = []
            let header = "$ \(items[i].command.display)"
            log.feed(header + "\n")
            logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: Date())) \(header)"])
            // 0.8.3: say up front that a password may be asked for, and how.
            if let f = foreignAskpass, AdminPassword.mayNeedSudo(items[i].command.arguments) {
                note("brew.env sets its own password helper (\(f.helper), in \(f.source)). Tankard won't use its password dialog, and tells brew not to run sudo for this step (HOMEBREW_NO_SUDO).")
            }
            // 0.8.4: only for a cask that needs it (the plan's and the
            // dialog's rule, AdminPassword.required); every cask step used to
            // get an orange "If brew needs sudo…" line. Any other step gets
            // the note only once brew says it runs sudo (below).
            passwordNoted = false
            if items[i].command.environment[Askpass.askpassKey] != nil, AdminPassword.required(items[i].package) {
                note("brew runs this installer with sudo: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS).")
                passwordNoted = true
            }
        case .output(let data):
            let lines = log.feed(data)
            commandLines += lines
            logFile?.append(lines)
            // 0.8.5: "==> Pouring xz--5.8.1…": a bottle after all, no build.
            if compilingItems.contains(itemID), !pouringItems.contains(itemID),
               lines.contains(where: { $0.hasPrefix("==> Pouring ") }) {
                pouringItems.insert(itemID)
            }
            if !passwordNoted, items[i].command.environment[Askpass.askpassKey] != nil, AdminPassword.announcesSudo(lines) {
                note("brew runs sudo for this step: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS).")
                passwordNoted = true
            }
        case .finished(let code):
            flush()
            lockWait = nil
            // 0.8: brew refuses a pinned package with exit 0; nothing changed.
            let refused = code == 0 && BrewRefusal.pinned(commandLines)
            items[i].state = code == 0 && !refused ? .done : .failed(code)
            if refused {
                note("brew didn't do it: \(items[i].package.name) is pinned (brew still exited 0). Unpin it first.")
            }
            if code == 0, !refused, action == .upgrade || action == .install, BrewRefusal.alreadyInstalled(commandLines) {
                doneElsewhere.insert(items[i].id)
                note("Already up to date: brew says \(items[i].package.name) is already installed, so another Homebrew command (in Terminal, perhaps) did it. Tankard changed nothing.")
            }
            if action == .uninstall, code == 0, !refused,
               let v = Self.removedVersion(commandLines, name: items[i].package.name) {
                removedVersions[items[i].id] = v
            }
            // 0.8.4: the package's last step and brew still has versions of it.
            if action == .uninstall, code == 0, !refused,
               !items.dropFirst(i + 1).contains(where: { $0.package.id == items[i].package.id }),
               let left = BrewRefusal.stillInstalled(commandLines, name: items[i].package.name) {
                markStillInstalled(items[i].package.name, versions: left)
            } else if action == .uninstall, code == 0, !refused,
                      BrewRefusal.stillInstalled(commandLines, name: items[i].package.name) != nil {
                note("The next step removes the next installed version (plain brew uninstall again, with its checks; not --force).")
            }
            if code != 0 {
                if SudoDetector.needsSudo(commandLines) {
                    sudoCommand = items[i].command.display
                    sudoOutcome = SudoOutcome.classify(commandLines) ?? .noPrompt
                    if let f = foreignAskpass, sudoOutcome == .sudoDisabled { sudoOutcome = .foreignHelper(f.helper) }
                    switch sudoOutcome {
                    case .cancelled: note("The password dialog was cancelled; sudo didn't run.")
                    case .wrongPassword: note("macOS didn't accept the password.")
                    default: break
                    }
                }
                // 0.8.1: every action that writes into /Applications (a
                // restore's cask reinstall too); the failure kind says why.
                if AppManagement.isCaskChange(action, items[i].package) || AppManagement.isCaskCommand(items[i].command.arguments),
                   AppManagement.isPermissionBlock(commandLines) {
                    appManagementBlocked.append(items[i].id)
                }
                // 0.6: say why in words when brew's output shows it; the raw log stays above.
                if let kind = BrewFailure.classify(commandLines) {
                    failureKinds.append(kind)
                    failureKindByItem[items[i].id] = kind
                    note("\(kind.title). \(kind.explanation)")
                }
                note("brew exited with status \(code)")
                if action == .upgrade { failedStepOutput[items[i].id] = commandLines }
                noteChainSkipped(after: i)
            }
        case .cancelled:
            let wasRunning = items[i].state == .running
            flush()
            if wasRunning { lockWait = nil }
            items[i].state = .cancelled
            if wasRunning { note("Stopped.") }
        case .skipped(let reason):
            flush()
            items[i].state = .skipped
            note(reason)
        case .lockWait(let holder):
            flush()
            commandLines = []
            if let holder {
                lockWait = holder
                note(holder.isEmpty ? "Another Homebrew command holds brew's lock. Waiting for it to finish, then running this again."
                     : "Another Homebrew command holds brew's lock (pid \(holder)). Waiting for it to finish, then running this again.")
            } else {
                lockWait = nil
                note("brew's lock is free: running it again.")
                log.feed("$ \(items[i].command.display)\n")
                watchDownloads(of: items[i].package)
            }
        case .failed(let message):
            flush()
            items[i].state = .failed(-1)
            // 0.8.4: refused before it started: brew.env's own password helper.
            if let f = foreignAskpass ?? Self.foreignHelper(in: message), message == f.message {
                sudoCommand = items[i].command.display
                sudoOutcome = .foreignHelper(f.helper)
            }
            note("Couldn't run brew: \(message)")
            noteChainSkipped(after: i)
        }
        finishIfDone()
    }

    // MARK: what an uninstall left (0.8.4)

    func markStillInstalled(_ name: String, versions: [String]) {
        guard stillInstalled[name] != versions else { return }
        stillInstalled[name] = versions
        note(versions.isEmpty ? "\(name) is still installed."
             : "\(name) \(versions.joined(separator: ", ")) still installed: the uninstall didn't remove every version.")
    }

    /// 0.8.6 (VM test M1): the steps brew exited non-zero for (it ran),
    /// read again before the run counts as finished. true: the read started.
    private func startUpgradeCheck() -> Bool {
        guard action == .upgrade, !upgradeChecked, !checkingUpgraded, let check = upgradeCheck else { return false }
        let failed = items.filter { if case .failed(let code) = $0.state { code > 0 } else { false } }
        guard !failed.isEmpty else { return false }
        checkingUpgraded = true
        let packages = failed.map(\.package)
        Task { @MainActor [weak self] in
            let found = await check(packages)
            self?.finishUpgradeCheck(found)
        }
        return true
    }

    /// 0.8.6 (HK-47 review): a step counts as upgraded only when the new
    /// version is installed and linked (keg-only formulae, and formulae that
    /// weren't linked before, need no link), and its output shows no link
    /// or post-install failure of this package (or one it doesn't tie to a
    /// package). "Over another package" only when brew's error names one.
    private func finishUpgradeCheck(_ found: [String: InstalledNow]?) {
        upgradeChecked = true
        checkingUpgraded = false
        if let found {
            for i in items.indices {
                let p = items[i].package
                guard case .failed(let code) = items[i].state, code > 0,
                      let now = found[p.id], !now.version.isEmpty else { continue }
                let before = p.installedVersion
                guard now.version != before,
                      before.isEmpty || PkgVersion(parsing: now.version) > PkgVersion(parsing: before) else { continue }
                let linkExpected = p.kind == .formula && !now.kegOnly && p.linked != false
                if linkExpected && now.linkedVersion != now.version { continue }
                let lines = failedStepOutput[items[i].id] ?? []
                let failedHere = UpgradeEvidence.linkOrPostInstallFailures(lines).contains { name in
                    name.map { UpgradeEvidence.names($0, p) } ?? true
                }
                if failedHere { continue }
                let other = UpgradeEvidence.namesAnotherPackage(lines, p)
                items[i].state = .done
                upgradedAnyway.insert(items[i].id)
                if other { upgradedOverAnotherPackage.insert(items[i].id) }
                failureKindByItem[items[i].id] = nil
                appManagementBlocked.removeAll { $0 == items[i].id }
                let state = !linkExpected ? "" : p.kind == .formula ? " and linked" : ""
                note(other
                     ? "\(p.name) is now \(now.version)\(state): brew upgraded it, then exited with status \(code) over another package (the log above says which)."
                     : "\(p.name) is now \(now.version)\(state): brew upgraded it, then exited with status \(code) (the log above says why).")
            }
            failureKinds = items.compactMap { failureKindByItem[$0.id] }
        } else {
            note("Couldn't read the installed versions again; the results above are brew's exit codes.")
        }
        finishIfDone()
    }

    /// Called from onFinish: the sheet waits for `finishInstalledCheck`.
    func beginInstalledCheck() { checkingInstalled = true }

    /// What a fresh read found still installed (name → versions) of this
    /// session's packages; nil: the read failed (said in the log).
    func finishInstalledCheck(_ found: [String: [String]]?, error: String? = nil) {
        if let found {
            for name in found.keys.sorted() { markStillInstalled(name, versions: found[name] ?? []) }
            if found.isEmpty && stillInstalled.isEmpty { note("Checked: nothing it uninstalled is still installed.") }
        } else {
            note("Couldn't check what is still installed: \(error ?? "the read failed").")
        }
        checkingInstalled = false
    }

    private func finishIfDone() {
        if !isFinished && items.allSatisfy({ $0.state.isTerminal }) && fetchStates.values.allSatisfy(\.isTerminal) {
            if startUpgradeCheck() { return }
            isFinished = true
            logFile?.close()
            let done = onFinish
            onFinish = nil
            done?(self)
        }
    }

    /// 0.8.3: a `brew fetch` step's events. Its output goes to the log like
    /// any step's; it never fails a package (each step downloads again what
    /// is missing, and fails with brew's own error if it still can't).
    private func applyFetch(_ event: CommandEvent, step s: Int) {
        let id = prefetchIDs[s]
        let n = prefetch[s].targets.count
        switch event {
        case .started:
            fetchStates[id] = .running
            fetchFinished[id] = 0
            watchDownloads(of: prefetch[s].targets)
            commandLines = []
            let header = "$ \(prefetch[s].command.display)"
            log.feed(header + "\n")
            logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: Date())) \(header)"])
        case .output(let data):
            let lines = log.feed(data)
            commandLines += lines
            logFile?.append(lines)
            fetchFinished[id] = FetchOutput.finished(commandLines)
        case .finished(let code):
            stopWatchingDownloads()
            flush()
            fetchStates[id] = code == 0 ? .done : .failed(code)
            fetchFinished[id] = code == 0 ? n : FetchOutput.finished(commandLines)
            if code != 0 {
                note("brew fetch exited with status \(code). Each package's own step downloads what's missing and shows brew's error if it fails again.")
            }
        case .cancelled:
            let wasRunning = fetchStates[id] == .running
            stopWatchingDownloads()
            flush()
            fetchStates[id] = .cancelled
            if wasRunning { note("Stopped.") }
        case .skipped(let reason):
            fetchStates[id] = .skipped
            note(reason)
        case .failed(let message):
            stopWatchingDownloads()
            flush()
            fetchStates[id] = .failed(-1)
            note("Couldn't run brew fetch: \(message). Each package's own step downloads it instead.")
        case .lockWait:
            // Fetch steps are enqueued without a lock wait; nothing to show.
            break
        }
        finishIfDone()
    }

    // MARK: download progress (0.8)

    /// Polls brew's downloads folder while this command runs. Stopped by
    /// the command's end (any of finished, cancelled, failed).
    /// 0.8.3: a fetch step's packages are watched together (their files summed).
    private func watchDownloads(of package: Package) { watchDownloads(of: [package]) }

    private func watchDownloads(of packages: [Package]) {
        stopWatchingDownloads()
        guard let m = downloads else { return }
        let since = m.now()
        downloadTask = Task { [weak self] in
            guard let dir = await m.directory(), !Task.isCancelled else { return }
            let watcher = DownloadWatcher(directory: dir, reader: m.reader, lengths: m.lengths, since: since)
            let hints = Task { await watcher.addURLs(await m.urlsFor(packages)) }
            defer { hints.cancel() }
            while !Task.isCancelled {
                let p = await watcher.poll()
                guard !Task.isCancelled, let self else { return }
                self.showDownload(p)
                try? await Task.sleep(for: m.interval)
            }
        }
    }

    private func showDownload(_ p: DownloadProgress?) {
        if p != nil { downloadObservations += 1 }
        if download != p { download = p }
    }

    /// 0.8.3: while a command that may run sudo is running, look for the
    /// password helper. When it appears: `awaitingPassword`, and Tankard
    /// yields focus to it (macOS 14+ activation is cooperative, so the
    /// helper can't take focus by itself). When it goes: not awaiting.
    private func watchPassword() {
        stopWatchingPassword()
        guard let focus = passwordFocus else { return }
        passwordTask = Task { @MainActor [weak self] in
            var yielded: pid_t?
            while !Task.isCancelled {
                // The process table walk happens off the main actor.
                let pid = await Task.detached(priority: .userInitiated) { focus.find() }.value
                guard !Task.isCancelled, let self else { return }
                if let pid {
                    if yielded != pid {
                        yielded = pid
                        focus.yield(pid)
                        self.note("The password dialog is open (process \(pid)); Tankard handed it the focus.")
                    }
                    if !self.awaitingPassword { self.awaitingPassword = true }
                } else if self.awaitingPassword {
                    self.awaitingPassword = false
                }
                try? await Task.sleep(for: focus.interval)
            }
        }
    }

    private func stopWatchingPassword() {
        passwordTask?.cancel()
        passwordTask = nil
        if awaitingPassword { awaitingPassword = false }
    }

    private func stopWatchingDownloads() {
        downloadTask?.cancel()
        downloadTask = nil
        download = nil
    }

    private func noteChainSkipped(after i: Int) {
        guard let key = chainKey?(items[i].package),
              items.dropFirst(i + 1).contains(where: { chainKey?($0.package) == key }) else { return }
        if action == .autoremove, let kept = items[i].package.autoremoveKeptNames {
            note("Nothing was removed because keeping \(kept.joined(separator: ", ")) failed")
            return
        }
        note("Skipped the next steps for this package")
    }

    /// 0.8.5 (HK-47 review): Remove Unused's keep step failed (or couldn't
    /// run): the formulae it was keeping ("python@3.14, libyaml"), else nil.
    var keepStepFailed: String? {
        guard isFinished, let keep = items.first(where: { $0.package.autoremoveKeptNames != nil }),
              failedItems.contains(where: { $0.id == keep.id }) else { return nil }
        return keep.package.autoremoveKeptNames?.joined(separator: ", ")
    }

    private func flush() {
        let rest = log.finish()
        commandLines += rest
        logFile?.append(rest)
    }

    /// The helper named in a refusal (a session that started before brew.env
    /// got it), or nil.
    nonisolated static func foreignHelper(in message: String) -> ForeignAskpass? {
        // 0.8.5: the sentence no longer names the helper (plain words; the
        // log's note does), so it is recognised whole.
        let plain = ForeignAskpass(helper: "", source: "", unstoppable: false)
        return message == plain.message ? plain : nil
    }

    private func note(_ s: String) {
        log.feed("tankard: \(s)\n")
        logFile?.append(["tankard: \(s)"])
    }
}

/// 0.8.6 (UI details M4): the plan's compile sentence, whole per count (the
/// translations used to get the English "has"/"have" in a placeholder).
public enum PlanText {
    public static func compiles(_ n: Int) -> String {
        n == 1 ? String(localized: "1 package has no bottle for this Mac and will compile from source, which can take a long time.")
               : String(localized: "\(n) packages have no bottle for this Mac and will compile from source, which can take a long time.")
    }
}
