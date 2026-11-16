import Foundation
import Observation
import TankardCore

/// What a sheet run does to its packages.
public enum SessionAction: String, Sendable {
    case upgrade, install, uninstall

    /// "Upgrade", "Install", "Uninstall"
    public var verb: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// "Upgrading", "Installing", "Uninstalling"
    public var gerund: String {
        switch self {
        case .upgrade: return "Upgrading"
        case .install: return "Installing"
        case .uninstall: return "Uninstalling"
        }
    }
    /// "upgraded", "installed", "uninstalled"
    public var past: String { rawValue + "ed" }
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

    init(packages: [Package], intelbrewMode: Bool, action: SessionAction = .upgrade, queue: CommandQueue,
         makeCommand: (Package) -> QueuedCommand, logURL: URL?,
         onFinish: @escaping @MainActor (UpgradeSession) -> Void) {
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
        // Enqueued in package order; the queue runs them strictly in order.
        for item in items {
            let itemID = item.id
            queue.enqueue(item.command, id: itemID) { event in
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

    /// 0...1, counting finished packages.
    public var fraction: Double {
        total == 0 ? 1 : Double(completedCount) / Double(total)
    }

    /// "Upgrading 5 packages" / "Installing xz"
    public var title: String {
        let verb = action.verb
        if isFinished {
            if stopRequested && items.contains(where: { $0.state == .cancelled }) { return "\(verb) stopped" }
            return failedItems.isEmpty ? "\(verb) complete" : "\(verb) finished with errors"
        }
        if action != .upgrade && total == 1 { return "\(action.gerund) \(items[0].package.name)" }
        return "\(action.gerund) \(total) package\(total == 1 ? "" : "s")"
    }

    /// "4 bottles from Intelbrew · 1 build from source (rust)"
    public var subtitle: String {
        if action == .uninstall {
            return "Its dependencies stay installed (brew autoremove removes unused ones)"
        }
        let formulae = items.map(\.package).filter { $0.kind == .formula }
        let bottles = formulae.filter { $0.upgradeHasBottle == true }
        let compiles = formulae.filter { $0.upgradeHasBottle != true }
        let casks = items.count - formulae.count
        var parts: [String] = []
        if !bottles.isEmpty && action == .install && intelbrewMode {
            // Installs know whose bottle it is (from the catalogue).
            let ib = bottles.filter { $0.bottleOrigin == .intelbrew }.count
            if ib > 0 { parts.append("\(ib) bottle\(ib == 1 ? "" : "s") from Intelbrew") }
            let other = bottles.count - ib
            if other > 0 { parts.append("\(other) Homebrew bottle\(other == 1 ? "" : "s")") }
        } else if !bottles.isEmpty {
            let from = intelbrewMode ? " from Intelbrew" : ""
            parts.append("\(bottles.count) bottle\(bottles.count == 1 ? "" : "s")\(from)")
        }
        if !compiles.isEmpty {
            let names = compiles.count <= 3 ? " (\(compiles.map(\.name).joined(separator: ", ")))" : ""
            parts.append("\(compiles.count) build\(compiles.count == 1 ? "" : "s") from source\(names)")
        }
        if casks > 0 { parts.append("\(casks) cask\(casks == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// "Upgrading python@3.15…" / "Done: 4 upgraded, 1 failed"
    public var statusLine: String {
        if let c = current { return "\(action.gerund) \(c.package.name)…" }
        if isFinished {
            var parts = ["\(succeededCount) \(action.past)"]
            if !failedItems.isEmpty { parts.append("\(failedItems.count) failed") }
            let skipped = items.filter { $0.state == .cancelled }.count
            if skipped > 0 { parts.append("\(skipped) stopped") }
            return parts.joined(separator: ", ")
        }
        return "Waiting for brew…"
    }

    /// "2 of 5"
    public var countLine: String {
        let n = current.map { c in (items.firstIndex { $0.id == c.id } ?? 0) + 1 } ?? completedCount
        return "\(n) of \(total)"
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
                note("brew exited with status \(code)")
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
        }
        if !isFinished && items.allSatisfy({ $0.state.isTerminal }) {
            isFinished = true
            logFile?.close()
            let done = onFinish
            onFinish = nil
            done?(self)
        }
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
