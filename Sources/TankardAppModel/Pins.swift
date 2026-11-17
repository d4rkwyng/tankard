import Foundation
import TankardCore

// v0.4 (part A): pin and unpin, dependency links, and the one-command
// runner that pin, unpin and the service actions share. Everything that
// changes Homebrew still goes through the strict FIFO queue.

/// `brew pin` / `brew unpin`, as literal argv.
public enum PinCommands {
    /// `brew pin --formula homebrew/core/xz` (or `unpin`, or `--cask`).
    /// brew 7.0.14 accepts both kinds (`brew pin --help`, on the arm64 Mac
    /// and the Intel VM).
    public static func arguments(pin: Bool, for p: Package) -> [String] {
        [pin ? "pin" : "unpin", p.kind == .cask ? "--cask" : "--formula", p.qualifiedName]
    }

    public static func display(pin: Bool, for p: Package) -> String {
        BrewCommands.display(arguments(pin: pin, for: p))
    }
}

/// What a queued one-off command (pin, unpin, a service action) did.
public struct QuickResult: Equatable, Sendable {
    public var exitCode: Int32
    public var lines: [String]
    public var failed: Bool { exitCode != 0 }

    public init(exitCode: Int32, lines: [String]) {
        self.exitCode = exitCode
        self.lines = lines
    }
}

public extension AppStore {
    /// A brew run is going: a sheet session, or a pin/service command.
    var isBusy: Bool { isUpgrading || quickAction != nil }

    /// Upgrades that Upgrade all leaves out because they are pinned.
    var pinnedUpgrades: [Package] { packages.filter { $0.upgradeAvailable && $0.pinned } }

    /// "1 pinned upgrade not included (sqlite)", or nil.
    var pinnedUpgradeNote: String? {
        let p = pinnedUpgrades
        guard !p.isEmpty else { return nil }
        let names = p.prefix(3).map(\.name).joined(separator: ", ") + (p.count > 3 ? " +\(p.count - 3)" : "")
        return "\(p.count) pinned upgrade\(p.count == 1 ? "" : "s") not included (\(names))"
    }

    /// The installed packages' dependency graph (built per call; cheap).
    var dependencyGraph: DependencyGraph { DependencyGraph(packages) }

    /// `brew pin` or `brew unpin` through the queue, then a re-read.
    func setPinned(_ p: Package, _ pinned: Bool) {
        guard p.pinned != pinned, p.kind == .formula || p.kind == .cask else { return }
        let args = PinCommands.arguments(pin: pinned, for: p)
        Task {
            let r = await runQuick(args)
            guard let r else { return }
            // Re-read first: a successful refresh clears `error`.
            await refresh(manual: false)
            if r.failed {
                error = Self.quickError(verb: pinned ? "Pin" : "Unpin", name: p.name, args: args, result: r)
            }
        }
    }

    /// Selects a package from a dependency link, clearing a filter or
    /// search that would hide it.
    func reveal(_ id: Package.ID) {
        guard let p = packages.first(where: { $0.id == id }) else { return }
        tab = .installed
        if !visiblePackages.contains(where: { $0.id == p.id }) {
            filter = .all
            search = ""
        }
        selection = p.id
    }

    /// Runs one mutating brew command through the queue (the same queue as
    /// upgrades, so it waits its turn). nil when it couldn't start: brew
    /// not found, no status yet, or something else is already running.
    func runQuick(_ args: [String]) async -> QuickResult? {
        guard !isBusy, let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        var env = client.environment(for: detection, readOnly: false)
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let cmd = QueuedCommand(executable: client.installation.brewPath, arguments: args,
                                environment: env, display: BrewCommands.display(args))
        quickAction = cmd.display
        defer { quickAction = nil }
        let collector = OutputCollector()
        do {
            let code = try await queue.run(cmd) { collector.add($0) }
            return QuickResult(exitCode: code, lines: collector.lines())
        } catch {
            return QuickResult(exitCode: -1, lines: ["Could not run brew: \(error)"])
        }
    }

    /// The banner for a failed one-off command: sudo gets the Terminal
    /// command; anything else gets brew's last lines.
    static func quickError(verb: String, name: String, args: [String], result: QuickResult, sudoCommand: String? = nil) -> StoreError {
        let display = BrewCommands.display(args)
        if SudoDetector.needsSudo(result.lines) || sudoCommand != nil {
            return StoreError(title: "\(verb) \(name) needs administrator rights",
                              detail: "Tankard never runs sudo. Run this in Terminal:",
                              terminalCommand: sudoCommand ?? "sudo " + display)
        }
        let tail = result.lines.suffix(6).joined(separator: "\n")
        return StoreError(title: "\(verb) \(name) failed (exit \(result.exitCode))", detail: tail, terminalCommand: display)
    }
}
