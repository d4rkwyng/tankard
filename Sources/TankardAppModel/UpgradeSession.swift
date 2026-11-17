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
    /// 0.3: cask steps macOS blocked (App Management), by item id.
    public private(set) var appManagementBlocked: [UUID] = []
    /// 0.6: recognised failures (brew's lock, network, disk, permissions), in order.
    public private(set) var failureKinds: [BrewFailureKind] = []
    /// 0.3: this run is the one retry after the App Management sheet.
    public var isRetry = false
    public private(set) var stopRequested = false
    public private(set) var isFinished = false
    public let intelbrewMode: Bool
    public let action: SessionAction
    public let logURL: URL?

    @ObservationIgnored private let queue: CommandQueue
    @ObservationIgnored private let logFile: LogFile?
    @ObservationIgnored private var onFinish: (@MainActor (UpgradeSession) -> Void)?
    /// Finished lines of the running command (for sudo detection).
    @ObservationIgnored private var commandLines: [String] = []
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// 0.7: steps sharing a key run as a chain: when one fails, the rest of
    /// its chain still waiting is skipped (a restore's link after a failed
    /// uninstall).
    @ObservationIgnored private var chainKey: ((Package) -> String?)?

    init(packages: [Package], intelbrewMode: Bool, action: SessionAction = .upgrade, queue: CommandQueue,
         makeCommand: (Package) -> QueuedCommand, logURL: URL?,
         chainKey: ((Package) -> String?)? = nil,
         precondition: ((Package) -> (@Sendable () -> String?)?)? = nil,
         onFinish: @escaping @MainActor (UpgradeSession) -> Void) {
        self.chainKey = chainKey
        self.intelbrewMode = intelbrewMode
        self.action = action
        self.queue = queue
        self.logURL = logURL
        self.logFile = logURL.map(LogFile.init)
        self.onFinish = onFinish
        self.items = packages.map { p in
            Item(id: UUID(), package: p, command: makeCommand(p), state: .waiting)
        }

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
        // Enqueued in package order; the queue runs them strictly in order.
        for item in items {
            let itemID = item.id
            let rest = chainRest[itemID] ?? []
            queue.enqueue(item.command, id: itemID, precondition: precondition?(item.package)) { [queue] event in
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
    public var succeededCount: Int { items.filter { $0.state == .done }.count }
    public var failedItems: [Item] { items.filter { if case .failed = $0.state { true } else { false } } }
    public var current: Item? { items.first { $0.state == .running } }
    /// The packages whose step macOS blocked.
    public var blockedPackages: [Package] { items.filter { appManagementBlocked.contains($0.id) }.map(\.package) }

    /// 0...1, counting finished packages.
    public var fraction: Double {
        total == 0 ? 1 : Double(completedCount) / Double(total)
    }

    /// "Upgrading 5 packages" / "Installing xz"
    public var title: String {
        let verb = action.verb
        if isFinished {
            if stopRequested && items.contains(where: { $0.state == .cancelled }) { return String(localized: "\(verb) stopped") }
            return failedItems.isEmpty ? String(localized: "\(verb) complete") : String(localized: "\(verb) finished with errors")
        }
        if action == .cleanup { return String(localized: "Cleaning up") }
        if action == .restore { return total == 1 ? String(localized: "Restoring (\(total) step)") : String(localized: "Restoring (\(total) steps)") }
        if action == .replaceBottle {
            return total == 1 ? String(localized: "Reinstalling \(items[0].package.name) from a bottle") : String(localized: "Reinstalling \(total) packages from bottles")
        }
        if action != .upgrade && total == 1 { return String(localized: "\(action.gerund) \(items[0].package.name)") }
        return total == 1 ? String(localized: "\(action.gerund) \(total) package") : String(localized: "\(action.gerund) \(total) packages")
    }

    /// "4 bottles from Intelbrew · 1 build from source (rust)"
    public var subtitle: String {
        if action == .uninstall {
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
        let formulae = items.map(\.package).filter { $0.kind == .formula }
        let bottles = formulae.filter { $0.upgradeHasBottle == true }
        let compiles = formulae.filter { $0.upgradeHasBottle != true }
        let casks = items.count - formulae.count
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
    public var statusLine: String {
        if action == .cleanup, current != nil { return String(localized: "Running brew cleanup…") }
        if let c = current { return String(localized: "\(action.gerund) \(c.package.name)…") }
        if isFinished {
            var parts = [String(localized: "\(succeededCount) \(action.past)")]
            if !failedItems.isEmpty { parts.append(String(localized: "\(failedItems.count) failed")) }
            let skipped = items.filter { $0.state == .cancelled }.count
            if skipped > 0 { parts.append(String(localized: "\(skipped) stopped")) }
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
        queue.cancel(items.filter { $0.state == .waiting }.map(\.id))
    }

    /// Stops the running command too (its whole process group).
    public func stopNow() {
        stopRequested = true
        queue.cancel(items.filter { !$0.state.isTerminal }.map(\.id))
    }

    // MARK: events

    private func apply(_ event: CommandEvent, to itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        switch event {
        case .started:
            items[i].state = .running
            commandLines = []
            let header = "$ \(items[i].command.display)"
            log.feed(header + "\n")
            logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: Date())) \(header)"])
        case .output(let data):
            let lines = log.feed(data)
            commandLines += lines
            logFile?.append(lines)
        case .finished(let code):
            flush()
            items[i].state = code == 0 ? .done : .failed(code)
            if code != 0 {
                if SudoDetector.needsSudo(commandLines) { sudoCommand = items[i].command.display }
                if AppManagement.modifiesApps(action, items[i].package), AppManagement.isPermissionBlock(commandLines) {
                    appManagementBlocked.append(items[i].id)
                    note("macOS blocked changing the app (App Management permission)")
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
            items[i].state = .cancelled
            if wasRunning { note("Stopped.") }
        case .failed(let message):
            flush()
            items[i].state = .failed(-1)
            note("Could not run brew: \(message)")
            noteChainSkipped(after: i)
        }
        if !isFinished && items.allSatisfy({ $0.state.isTerminal }) {
            isFinished = true
            logFile?.close()
            let done = onFinish
            onFinish = nil
            done?(self)
        }
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

    private func note(_ s: String) {
        log.feed("tankard: \(s)\n")
        logFile?.append(["tankard: \(s)"])
    }
}
