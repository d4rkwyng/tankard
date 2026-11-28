import AskpassSupport
import Foundation
import Observation
import os
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
    /// 0.8.10: `brew install --cask --force`: Adopt Apps' Replace with
    /// Homebrew's Version, for an app older than the cask's.
    case replaceApp

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
        case .replaceApp: return String(localized: "Replace")
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
        case .replaceApp: return String(localized: "Replacing")
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
        case .replaceApp: return String(localized: "replaced")
        }
    }
}

/// A result note the sheet shows in full under the result line. `addNote`
/// records these (Replace: the recovery command, a kept copy, "Stop came
/// too late", "may be incomplete"). Running commentary stays in the log.
///
/// A command Copy should paste is stored beside the sentence. It is not
/// found by scanning `text` for backticks: an app name or a path can
/// contain one, and that would move the span.
public struct SessionNote: Equatable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    /// Nil: Copy reads paired `code` spans in `text` (a sentence written
    /// with those spans on purpose). Empty: nothing to copy, and a
    /// backtick in `text` is a character. Otherwise the commands Copy
    /// pastes, which are not found by scanning `text`.
    private let givenCommands: [String]?

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
        self.givenCommands = nil
    }

    /// `command` is what Copy pastes. A backtick in `text` cannot change it.
    public init(id: Int, text: String, command: String) {
        self.id = id
        self.text = text
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.givenCommands = []
        } else {
            self.givenCommands = [command]
        }
    }

    /// A sentence with no command. Backticks in it are characters.
    init(id: Int, literal text: String) {
        self.id = id
        self.text = text
        self.givenCommands = []
    }

    /// Commands Copy pastes, in order. Empty when there is nothing to copy.
    public var commands: [String] {
        if let givenCommands { return givenCommands }
        return NoticeText.codeSpans(text)
    }

    /// What Copy puts on the pasteboard: the commands, one per line.
    /// Nil when `commands` is empty.
    public var copyText: String? {
        let cmds = commands
        return cmds.isEmpty ? nil : cmds.joined(separator: "\n")
    }

    /// The sheet's text. A given command is styled where the sentence
    /// quotes it, and the rest is shown as typed. A literal note is not
    /// scanned, so a backtick in a name or a path is not a span.
    public var attributed: AttributedString {
        if let givenCommands {
            return Self.styling(text, commands: givenCommands) ?? AttributedString(text)
        }
        return NoticeText.attributed(text)
    }

    /// Styles each command where `` `command` `` sits in `text`. The
    /// surrounding characters are not scanned. Nil if a command is not
    /// there as its own span, so the caller shows the sentence as typed
    /// and Copy still has the command.
    private static func styling(_ text: String, commands: [String]) -> AttributedString? {
        var rest = Substring(text)
        var out = AttributedString()
        for command in commands {
            let wrapped = "`\(command)`"
            guard let range = rest.range(of: wrapped) else { return nil }
            out += AttributedString(String(rest[..<range.lowerBound]))
            var code = AttributedString(command)
            code.inlinePresentationIntent = .code
            out += code
            rest = rest[range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
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
    /// Result notes, in the order `addNote` recorded them. The sheet shows
    /// these in full under the result line. The log keeps the same words.
    public private(set) var sessionNotes: [SessionNote] = []
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
    /// 0.8.7: the last untrusted-tap refusal in a failed step's output
    /// (the tap the sheet offers to trust).
    public private(set) var untrustedTap: UntrustedTapRefusal?
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
    /// 0.10: the download's speed, fed by each poll with `now()`
    /// (UpgradeSession+Speed.swift).
    @ObservationIgnored var downloadSpeed = DownloadSpeed()

    func setBuildProgress(compiling: Set<UUID>, estimates: [UUID: TimeInterval]) {
        compilingItems = compiling
        buildEstimates = estimates
    }

    @ObservationIgnored private let queue: CommandQueue
    @ObservationIgnored private let logFile: LogFile?
    @ObservationIgnored private var onFinish: (@MainActor (UpgradeSession) -> Void)?
    /// Finished lines of the running command (for sudo detection).
    @ObservationIgnored private var commandLines: [String] = []
    /// 0.8.8: when the running step last printed a line or its download
    /// moved (`networkHint`).
    @ObservationIgnored public private(set) var lastActivityAt: Date?
    /// 0.8.4: the running step's password note is in the log.
    @ObservationIgnored private var passwordNoted = false
    /// 0.8.8 (gauntlet 3, B2): `AskpassCancels.count` when the step started.
    /// 0.8.9: as its `.started` event arrived (nil: no count then).
    @ObservationIgnored private var cancelsAtStart: Int?
    /// 0.8.8 (gauntlet 3, B2): steps brew finished (exit 0) although the
    /// password dialog was cancelled during them: brew skipped what needed
    /// sudo. The value: the launchctl services brew was removing (empty
    /// when its output named none).
    public private(set) var sudoSkipped: [UUID: [String]] = [:]
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
    @ObservationIgnored public var passwordFocus: AskpassFocus? {
        didSet {
            let count = passwordFocus?.cancelCount
            cancelCounter.withLock { $0 = count }
        }
    }
    /// 0.8.9 (confirm run on 15, MED): `passwordFocus.cancelCount`, read
    /// where the queue's events arrive (off the main actor) rather than
    /// where the main actor applies them. A step's `.started` and
    /// `.finished` each carry the count at that moment. Read when applied,
    /// both could see a Cancel made in between: while the main actor was
    /// held (the quit question's modal alert, 0.8.8), the steps' events
    /// waited in the stream, the step's brew exited with its dialog
    /// cancelled, and by the time `.started` was applied the count already
    /// held that Cancel, so the step ended as a plain ✓.
    private nonisolated let cancelCounter = OSAllocatedUnfairLock<(@Sendable () -> Int)?>(initialState: nil)
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
    /// 0.9.0: a Replace is reading the new app's signature, off the main
    /// actor. The run isn't finished until that answers.
    public private(set) var checkingNewApp = false
    /// Set by the store for a Replace. Runs before the session is finished,
    /// so the signature read can be awaited without blocking the main actor.
    @ObservationIgnored private var replaceCheck: (@MainActor (UpgradeSession) async -> Void)?
    private var replaceCheckStarted = false
    /// 0.8.6 (HK-47 review): called when that read starts. Every step has
    /// run by then and no quit prompt stops a ⌘Q, so the app settles the
    /// run journal here rather than only at the end.
    @ObservationIgnored var onUpgradeCheckStarted: (@MainActor (UpgradeSession) -> Void)?
    /// Steps brew exited non-zero for although the package was upgraded.
    public private(set) var upgradedAnyway: Set<UUID> = []
    /// 0.8.10: a Replace whose brew exited non-zero after the app at the
    /// path was already a whole bundle of the cask's version. Counted as
    /// replaced, with a warning. The failure kind is cleared.
    public private(set) var replacedDespiteError: Set<UUID> = []
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
         passwordFocus: AskpassFocus? = nil,
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

        // 0.8.9: each event with the password dialog's cancel count as it
        // arrived (`cancelCounter`).
        // 0.9.2 (CI run 45241315816): the cancel count is in place before
        // the first step is enqueued. Set by the caller after init, a step
        // the queue started in between sent `.started` with no count, and
        // a Cancel during it went unrecorded (a plain ✓).
        self.passwordFocus = passwordFocus
        cancelCounter.withLock { $0 = passwordFocus?.cancelCount }
        let (stream, continuation) = AsyncStream.makeStream(of: (UUID, CommandEvent, Int?).self, bufferingPolicy: .unbounded)
        let counter = cancelCounter
        let send: @Sendable (UUID, CommandEvent) -> Void = { id, event in
            let count: Int?
            switch event {
            case .started, .finished: count = counter.withLock { $0 }?()
            default: count = nil
            }
            continuation.yield((id, event, count))
        }
        consumer = Task { @MainActor [weak self] in
            for await (itemID, event, cancels) in stream {
                self?.apply(event, to: itemID, cancels: cancels)
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
                send(stepID, event)
            }
        }
        // Enqueued in package order; the queue runs them strictly in order.
        for item in items {
            let itemID = item.id
            let rest = chainRest[itemID] ?? []
            // 0.8.10: Replace does not wait and run brew again when the lock
            // is held. The retry would start with no new check that the app
            // is still closed, and brew --force can delete a running app.
            // A lock failure stops the run (CommandQueue skips
            // runWaitingForLock when lockWait is nil).
            let waitForLock = action == .replaceApp ? nil : lockWait
            queue.enqueue(item.command, id: itemID, precondition: precondition?(item.package),
                          skipCheck: skipCheck?(item.package), lockWait: waitForLock) { [queue] event in
                if !rest.isEmpty {
                    switch event {
                    case .finished(let code) where code != 0: queue.cancel(rest)
                    case .failed: queue.cancel(rest)
                    default: break
                    }
                }
                send(itemID, event)
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
    /// Finished with nothing wrong: no failed step, nothing left installed,
    /// and no replace that brew reported an error for after the app was replaced.
    public var hasProblems: Bool { !failedItems.isEmpty || !stillInstalled.isEmpty || !replacedDespiteError.isEmpty }
    public var succeededCount: Int { items.filter { $0.state == .done && !doneElsewhere.contains($0.id) }.count }
    /// 0.8.6 (M3): steps brew found already done ("already installed",
    /// exit 0): another Homebrew command, often in Terminal while Tankard
    /// waited for brew's lock, did the work. Not counted as Tankard's.
    public private(set) var doneElsewhere: Set<UUID> = []
    /// 0.8.8 (VM retest): steps brew found "already installed" because an
    /// earlier step of this same run upgraded them (as a dependency or a
    /// dependent of what it upgraded); the value is that step's package.
    /// Counted as upgraded by this run, not as done elsewhere.
    public private(set) var doneByEarlierStep: [UUID: String] = [:]
    /// What this run's finished steps upgraded or poured (brew's names),
    /// each with the step's package name.
    private var upgradedThisRun: [String: String] = [:]
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

    /// 0.8.8: the earlier step whose brew output upgraded `name`, if any.
    nonisolated static func earlierStep(_ upgraded: [String: String], name: String) -> String? {
        guard BrewRefusal.contains(Set(upgraded.keys), name) else { return nil }
        if let by = upgraded[name] { return by }
        let short = name.split(separator: "/").last.map(String.init) ?? name
        return upgraded.first { ($0.key.split(separator: "/").last.map(String.init) ?? $0.key) == short }?.value
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

    /// 0.8.8: finished, the only failure a cancelled password dialog, and
    /// no step done.
    public var passwordCancelledOnly: Bool {
        isFinished && sudoOutcome == .cancelled && failedItems.count == 1 && !items.contains { $0.state == .done }
    }

    /// "Upgrading 5 packages" / "Installing xz"
    public var title: String {
        let verb = action.verb
        if isFinished {
            if stopRequested && items.contains(where: { $0.state == .cancelled }) { return String(localized: "\(verb) stopped") }
            if checkingInstalled { return String(localized: "Checking what is still installed…") }
            // 0.8.8 (gauntlet 26, P6): the password dialog was cancelled and
            // nothing else was done: that is a cancel, not a problem.
            if passwordCancelledOnly { return String(localized: "\(verb) cancelled") }
            // 0.8.6 (UI M5): the same phrase as the progress window's title.
            if !failedItems.isEmpty { return String(localized: "\(verb) finished with problems") }
            // 0.8.10: the app is the cask's version; brew's exit is a warning.
            if !replacedDespiteError.isEmpty { return String(localized: "\(verb) finished with a warning") }
            if !stillInstalled.isEmpty { return String(localized: "Uninstall incomplete") }
            if !doneElsewhere.isEmpty, succeededCount == 0 { return String(localized: "Already up to date (done elsewhere)") }
            return String(localized: "\(verb) complete")
        }
        if action == .cleanup { return String(localized: "Cleaning up") }
        if action == .restore { return String(localized: "Restoring (\(total) steps)", bundle: L10n.bundle) }
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
                if passwordCancelledOnly { return String(localized: "The password dialog was cancelled, so brew didn't run the step that needed it.") }
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
            if ib > 0 { parts.append(String(localized: "\(ib) bottles from Intelbrew", bundle: L10n.bundle)) }
            let other = bottles.count - ib
            if other > 0 { parts.append(String(localized: "\(other) Homebrew bottles", bundle: L10n.bundle)) }
        } else if !bottles.isEmpty {
            let from = intelbrewMode ? String(localized: " from Intelbrew") : ""
            parts.append((String(localized: "\(bottles.count) bottles", bundle: L10n.bundle)) + from)
        }
        if !compiles.isEmpty {
            let names = compiles.count <= 3 ? " (\(compiles.map(\.name).joined(separator: ", ")))" : ""
            parts.append((String(localized: "\(compiles.count) builds from source", bundle: L10n.bundle)) + names)
        }
        if readyMade > 0 {
            parts.append(String(localized: "\(readyMade) ready-made programs", bundle: L10n.bundle))
        }
        if casks > 0 { parts.append(String(localized: "\(casks) casks", bundle: L10n.bundle)) }
        if already > 0 { parts.append(String(localized: "\(already) already up to date")) }
        let line = parts.joined(separator: " · ")
        // 0.8.8 (gauntlet 15): with failures, the line is what was done,
        // which read as the whole run ("1 cask" under a Brewfile install of
        // a cask and a formula). Say so.
        if isFinished && !failedItems.isEmpty && !line.isEmpty { return String(localized: "Done: \(line)") }
        return line
    }

    /// "Upgrading python@3.15…" / "Done: 4 upgraded, 1 failed"
    public var statusLine: String { statusLine(behindBrewUpdate: false) }

    public func statusLine(behindBrewUpdate: Bool) -> String { statusLine(behindBrewUpdate: behindBrewUpdate, at: now()) }

    /// Nothing has started yet: the queue is still running something else.
    public var notStarted: Bool {
        !isFinished && items.allSatisfy { $0.state == .waiting } && fetchStates.values.allSatisfy { $0 == .waiting }
    }

    /// 0.8: `behindBrewUpdate` (AppStore.sessionWaitsForBrewUpdate): the
    /// first step is queued behind a background `brew update`, which can take
    /// a minute or two; say so instead of a bare "Waiting for brew…".
    /// 0.10: `date` (the sheet's TimelineView) is when the download's speed
    /// and time left are read; a download that stops still updates.
    public func statusLine(behindBrewUpdate: Bool, at date: Date) -> String {
        if behindBrewUpdate && notStarted { return String(localized: "Waiting for brew update to finish…") }
        if stoppingNow, let c = current { return String(localized: "Stopping \(c.package.name)…") }
        if lockWait != nil, current != nil { return String(localized: "Waiting for another Homebrew command to finish…") }
        if action == .cleanup, current != nil { return String(localized: "Running brew cleanup…") }
        if isFetching {
            // 0.8.3: "Downloading 4 of 9 · 120.0 of 410.0 MB (29%)"
            let head = String(localized: "Downloading \(fetchedCount) of \(fetchTotal)")
            // 0.10: "… (29%) · 4.2 MB/s · about 1 min left"
            return download.map { head + " · " + $0.detail + rateSuffix(at: date) } ?? head + "…"
        }
        if let c = current, let d = download {
            // 0.8: "Downloading font-inter… 12.3 of 33.7 MB (36%)"; a
            // dependency's bottle by its own name.
            return String(localized: "Downloading \(d.name ?? c.package.name)…") + " " + d.detail + rateSuffix(at: date)
        }
        if let c = current { return String(localized: "\(action.gerund) \(c.package.name)…") }
        if checkingNewApp { return String(localized: "Checking the new app…") }
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

    /// 0.8.8 (gauntlet 15): offline, `brew install` sat at "Downloading
    /// bottle manifests" and 0% for about five minutes while brew retried,
    /// with nothing on screen saying why. After `networkHintAfter` seconds
    /// with no output and no download progress during a download, this
    /// says so; nil otherwise.
    public func networkHint(at date: Date) -> String? {
        guard !isFinished, current != nil, lockWait == nil, !stoppingNow,
              let last = lastActivityAt, date.timeIntervalSince(last) >= Self.networkHintAfter else { return nil }
        let line = commandLines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard download != nil || line.hasPrefix("==> Downloading") || line.hasPrefix("==> Fetching") else { return nil }
        return String(localized: "Can't reach the network yet: brew keeps retrying. Check the connection, or use Stop Now.")
    }

    /// Seconds without progress before `networkHint` speaks.
    public static let networkHintAfter: TimeInterval = 30

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
        // 0.9.2: only what the queue hasn't started. A step shown as
        // waiting may be running already (its `.started` not applied yet).
        queue.cancelIfWaiting(prefetchIDs.filter { fetchStates[$0] == .waiting })
        queue.cancelIfWaiting(items.filter { $0.state == .waiting }.map(\.id))
    }

    /// Stops the running command too (its whole process group).
    public func stopNow() {
        stopRequested = true
        queue.cancel(prefetchIDs.filter { fetchStates[$0]?.isTerminal == false })
        if current != nil { stoppingNow = true }
        queue.cancel(items.filter { !$0.state.isTerminal }.map(\.id))
    }

    // MARK: events

    /// `cancels`: the password dialog's cancel count when a `.started` or
    /// `.finished` event arrived (0.8.9); nil for other events.
    private func apply(_ event: CommandEvent, to itemID: UUID, cancels: Int? = nil) {
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
            lastActivityAt = now()
            watchDownloads(of: items[i].package)
            if items[i].command.environment[Askpass.askpassKey] != nil { watchPassword() }
            cancelsAtStart = cancels
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
                note(AdminPassword.onlyRemovalNeedsSudo(items[i].package)
                     ? "brew removes this cask's background service or system files with sudo: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS)."
                     : "brew runs this installer with sudo: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS).")
                passwordNoted = true
            }
        case .output(let data):
            let lines = log.feed(data)
            commandLines += lines
            logFile?.append(lines)
            lastActivityAt = now()
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
            // 0.8.8 (gauntlet 3, B2): done, but the password was cancelled on
            // the way: brew went on without what needed sudo (hiddenbar's
            // launchctl service stays). Not a plain ✓.
            if code == 0, !refused, items[i].command.environment[Askpass.askpassKey] != nil,
               let before = cancelsAtStart, let after = cancels, after > before {
                let services = Self.launchctlServices(commandLines)
                sudoSkipped[items[i].id] = services
                note(services.isEmpty
                     ? "The password dialog was cancelled, so brew skipped the part of this step that needed sudo."
                     : "The password dialog was cancelled, so brew couldn't remove the background service \(services.joined(separator: ", ")); it may still be installed.")
            }
            if code == 0, !refused, action == .upgrade || action == .install, BrewRefusal.alreadyInstalled(commandLines) {
                let name = items[i].package.name
                if let by = Self.earlierStep(upgradedThisRun, name: name) {
                    // 0.8.8: brew upgraded it a moment ago, for an earlier step.
                    doneByEarlierStep[items[i].id] = by
                    note("Already upgraded by this run: brew upgraded \(name) while upgrading \(by) (as a dependency or dependent), so this step had nothing left to do.")
                } else {
                    doneElsewhere.insert(items[i].id)
                    note("Already up to date: brew says \(name) is already installed, so another Homebrew command (in Terminal, perhaps) did it. Tankard changed nothing.")
                }
            }
            if action == .upgrade || action == .install {
                for n in BrewRefusal.upgradedNames(commandLines) where upgradedThisRun[n] == nil {
                    upgradedThisRun[n] = items[i].package.name
                }
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
                    // Replace writes this after finishLive. A run that left
                    // the cask's version is a warning and does not get it.
                    if action != .replaceApp {
                        note("\(kind.title). \(kind.explanation)")
                    }
                    if kind == .untrustedTap, let r = UntrustedTapRefusal.parse(lines: commandLines) {
                        untrustedTap = r
                        note(r.trustCommand)
                    }
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

    /// 0.8.8: "==> Removing launchctl service com.x.Helper" lines' service names.
    nonisolated static func launchctlServices(_ lines: [String]) -> [String] {
        let prefix = "==> Removing launchctl service "
        var out: [String] = []
        for line in lines where line.hasPrefix(prefix) {
            let name = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// 0.8.8 (gauntlet 3, B2): the sheet's line for a step brew finished
    /// without its sudo part; nil for any other step.
    public func sudoSkippedLine(_ item: Item) -> String? {
        guard let services = sudoSkipped[item.id] else { return nil }
        let name = item.package.name
        let verb: String
        switch action {
        case .uninstall: verb = String(localized: "\(name) uninstalled")
        case .install: verb = String(localized: "\(name) installed")
        default: verb = String(localized: "\(name) upgraded")
        }
        if services.isEmpty {
            return String(localized: "\(verb), but brew skipped a step that needed your password (the password dialog was cancelled).")
        }
        return String(localized: "\(verb), but brew couldn't remove its background service (\(services.joined(separator: ", "))) because the password dialog was cancelled.")
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
        onUpgradeCheckStarted?(self)
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

    /// The store's Replace bookkeeping (the copy, and the new app's
    /// signature). Called before the session is finished.
    func setReplaceCheck(_ check: @escaping @MainActor (UpgradeSession) async -> Void) {
        replaceCheck = check
    }

    /// Awaits the replace check before the sheet says the run is finished.
    /// While it runs, another pass through here must not finish the session
    /// out from under it. Returns true when the session should stay unfinished.
    private func startReplaceCheck() -> Bool {
        guard action == .replaceApp else { return false }
        if replaceCheckStarted { return checkingNewApp }
        guard let hook = replaceCheck else { return false }
        replaceCheckStarted = true
        replaceCheck = nil
        checkingNewApp = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await hook(self)
            self.checkingNewApp = false
            self.finishIfDone()
        }
        return true
    }

    private func finishIfDone() {
        if !isFinished && items.allSatisfy({ $0.state.isTerminal }) && fetchStates.values.allSatisfy(\.isTerminal) {
            if startUpgradeCheck() { return }
            if startReplaceCheck() { return }
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
        downloadSpeed.reset()
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
        // 0.10: every poll counts, also one with the same bytes (that is
        // how the speed falls and a stall shows). A count that went
        // backwards restarts the tracker by itself.
        if let p { downloadSpeed.record(bytes: p.bytes, at: now()) } else { downloadSpeed.reset() }
        if download != p {
            download = p
            lastActivityAt = now()
        }
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
        downloadSpeed.reset()
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

    /// 0.8.10: brew exited non-zero, but the app is a whole bundle of the
    /// cask's version. The step counts as replaced. The failure kind goes,
    /// so the sheet does not show brew's error title or the retry advice.
    /// 0.9.0: Stop Now can arrive after brew has already laid the app down.
    /// That item is `.cancelled`, not `.failed`, and counts the same way.
    /// The chip is the warning, and the title is not "Replace stopped".
    func markReplacedDespiteError(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state {
        case .failed, .cancelled: break
        default: return
        }
        items[i].state = .done
        replacedDespiteError.insert(id)
        failureKindByItem[id] = nil
        appManagementBlocked.removeAll { $0 == id }
        failureKinds = items.compactMap { failureKindByItem[$0.id] }
    }

    /// 0.8.10: a line from the store after the run (Replace with
    /// Homebrew's Version: whether the app was put back). Also one of
    /// `sessionNotes`, so the sheet can show it in full: the log draws
    /// each line on one row and cuts it off. The sentence is literal:
    /// a backtick in an app name or a path is not a command.
    func addNote(_ s: String) {
        note(s)
        sessionNotes.append(SessionNote(id: sessionNotes.count, literal: s))
    }

    /// Same as `addNote(_:)`, and `command` is what Copy pastes. Copy does
    /// not scan `s`, so a backtick in the sentence cannot retarget it.
    func addNote(_ s: String, command: String) {
        note(s)
        sessionNotes.append(SessionNote(id: sessionNotes.count, text: s, command: command))
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
        String(localized: "\(n) packages have no bottle for this Mac and will compile from source, which can take a long time.", bundle: L10n.bundle)
    }
}
