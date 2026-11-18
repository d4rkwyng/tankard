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

    init(packages: [Package], intelbrewMode: Bool, action: SessionAction = .upgrade, queue: CommandQueue,
         makeCommand: (Package) -> QueuedCommand, logURL: URL?,
         chainKey: ((Package) -> String?)? = nil,
         precondition: ((Package) -> (@Sendable () -> String?)?)? = nil,
         skipCheck: ((Package) -> CommandQueue.SkipCheck?)? = nil,
         downloads: DownloadMonitor? = nil,
         prefetch: [PrefetchStep] = [],
         lockWait: BrewLockWait? = nil,
         onFinish: @escaping @MainActor (UpgradeSession) -> Void) {
        self.chainKey = chainKey
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
    public var succeededCount: Int { items.filter { $0.state == .done }.count }
    public var failedItems: [Item] { items.filter { if case .failed = $0.state { true } else { false } } }
    public var current: Item? { items.first { $0.state == .running } }
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
            if !failedItems.isEmpty { return String(localized: "\(verb) finished with errors") }
            if !stillInstalled.isEmpty { return String(localized: "Uninstall incomplete") }
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
        // 0.8.4: once finished with failures, what was actually done, not
        // the plan: a failed download said "1 build from source" although
        // nothing was built. Nothing done: why, when brew's output says.
        var packages = items.map(\.package)
        if isFinished && !failedItems.isEmpty {
            packages = items.filter { $0.state == .done }.map(\.package)
            if packages.isEmpty {
                return failureKinds.last?.title ?? String(localized: "The log below shows what brew printed")
            }
        }
        let formulae = packages.filter { $0.kind == .formula }
        let bottles = formulae.filter { $0.upgradeHasBottle == true }
        let compiles = formulae.filter { $0.upgradeHasBottle != true }
        let casks = packages.count - formulae.count
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
        if casks > 0 { parts.append(casks == 1 ? String(localized: "\(casks) cask") : String(localized: "\(casks) casks")) }
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
        if isFinished {
            // 0.8.4: an uninstall counts packages (all of its steps done), not steps.
            let succeeded = action == .uninstall
                ? packages.filter { p in items.allSatisfy { $0.package.id != p.id || $0.state == .done } && stillInstalled[p.name] == nil }.count
                : succeededCount
            var parts = [String(localized: "\(succeeded) \(action.past)")]
            if !stillInstalled.isEmpty {
                parts.append(stillInstalled.keys.sorted().map { n in
                    String(localized: "\(n) \(stillInstalled[n, default: []].joined(separator: ", ")) still installed")
                }.joined(separator: ", "))
            }
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
                    case .wrongPassword: note("sudo didn't accept the password.")
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
                    note("\(kind.title). \(kind.explanation)")
                }
                note("brew exited with status \(code)")
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
        note("Skipped the next steps for this package")
    }

    private func flush() {
        let rest = log.finish()
        commandLines += rest
        logFile?.append(rest)
    }

    /// The helper named in a refusal (a session that started before brew.env
    /// got it), or nil.
    nonisolated static func foreignHelper(in message: String) -> ForeignAskpass? {
        let probe = ForeignAskpass(helper: "\u{1}", source: "", unstoppable: false).message
        guard let mark = probe.range(of: "\u{1}") else { return nil }
        let head = String(probe[..<mark.lowerBound]), tail = String(probe[mark.upperBound...])
        guard message.hasPrefix(head), message.hasSuffix(tail), message.count > head.count + tail.count else { return nil }
        let helper = String(message.dropFirst(head.count).dropLast(tail.count))
        return ForeignAskpass(helper: helper, source: "", unstoppable: false)
    }

    private func note(_ s: String) {
        log.feed("tankard: \(s)\n")
        logFile?.append(["tankard: \(s)"])
    }
}
