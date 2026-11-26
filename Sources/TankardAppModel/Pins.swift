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

    /// 0.8.6 (VM test L2): Pin and Unpin are offered only for a package
    /// brew can read: for one it can't (an untrusted tap), `brew pin`
    /// fails with "Refusing to load formula…".
    public static func offered(for p: Package) -> Bool { !p.isUnreadable }
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

public extension Package {
    /// 0.4: held back from upgrades. A pinned package: `brew upgrade` skips
    /// it, so Tankard does too. The one rule every "upgrade everything"
    /// path uses (Upgrade all, the menu-bar count, upgrade notifications,
    /// Upgrade vulnerable packages through `InsightsStore.isHeld`).
    var isHeld: Bool { pinned }

    /// 0.4: an upgrade that Upgrade all, the menu-bar count and
    /// notifications include: one is waiting and it isn't held. With
    /// "Include self-updating apps" on, the casks `brew outdated --greedy`
    /// adds have `upgradeAvailable` set, so they count too, unless pinned.
    /// 0.8: a self-updating cask left to its own updater is out too.
    var isUpgradeTarget: Bool { upgradeAvailable && !isHeld && versionSkipped != true && selfUpdateHeld != true }

    /// 0.6: what a manual Upgrade of this one package takes: a skipped
    /// version still upgrades by hand.
    var isManualUpgradeTarget: Bool { upgradeAvailable && !isHeld }
}

public extension AppStore {
    /// A brew run is going: a sheet session, a pin/service command, or
    /// (0.5) an automatic update.
    var isBusy: Bool { isUpgrading || quickAction != nil || autoUpdate.isRunning || selfReplaced }

    /// 0.9.4 (bug hunt R1 review): startSession refuses a new run now (a
    /// run going, an automatic update, Tankard replaced on disk). The
    /// buttons that start one from a sheet (Retry, App Management's run
    /// buttons, Clean Up, Install) wait instead of doing nothing.
    var newRunBlocked: Bool { isUpgrading || autoUpdate.isRunning || selfReplaced }

    /// 0.9.4 (bug hunt R1 review): the menu-bar row's Upgrade is off while
    /// brew runs, an automatic update among them (as Upgrade All).
    var menuBarRowBusy: Bool { isUpgrading || autoUpdate.isRunning || isRefreshing }

    /// 0.8.4: a sheet is up in the main window (each `.sheet` ContentView,
    /// DiscoverView and selfUpdateSheets attach), so it is modal and a menu
    /// item that opens another sheet or starts brew must wait.
    var isSheetPresented: Bool {
        showUpgradeSheet || uninstallCandidate != nil || showCleanupSheet || managementSheet != nil
            || brewfile.isPresented || showAutoUpdateLog || restorePoints.isShowing || toolSheet != nil
            || insights.postInstallNotes != nil || showSelfUpdate || discover?.confirmInstall != nil
    }

    /// 0.8.4: the gate for the Homebrew and File menu items that start brew
    /// or open a sheet: off while a run is going (its sheet shown or
    /// hidden) or any sheet is up. The toolbar needs no such gate for
    /// sheets: AppKit disables a window's toolbar while a sheet is up.
    /// 0.8.5 (HK-47 review): and while the progress panel holds the
    /// activity (a hidden, failed run nobody has read among them).
    var menuActionsBlocked: Bool { isBusy || isSheetPresented || progressPanelHoldsActivity }

    /// Upgrades that Upgrade all leaves out because they are pinned.
    var pinnedUpgrades: [Package] { packages.filter { $0.upgradeAvailable && $0.isHeld } }

    /// "1 pinned upgrade not included (sqlite)", or nil.
    var pinnedUpgradeNote: String? {
        let p = pinnedUpgrades
        guard !p.isEmpty else { return nil }
        let names = p.prefix(3).map(\.name).joined(separator: ", ") + (p.count > 3 ? " +\(p.count - 3)" : "")
        return String(localized: "\(p.count) pinned upgrades not included (\(names))", bundle: L10n.bundle)
    }

    /// The installed packages' dependency graph (built per call; cheap).
    var dependencyGraph: DependencyGraph { DependencyGraph(packages) }

    /// `brew pin` or `brew unpin` through the queue, then a re-read.
    func setPinned(_ p: Package, _ pinned: Bool) {
        guard p.pinned != pinned, p.kind == .formula || p.kind == .cask, PinCommands.offered(for: p) else { return }
        let args = PinCommands.arguments(pin: pinned, for: p)
        Task {
            let r = await runQuick(args)
            guard let r else { return }
            // Re-read first: a successful refresh clears `error`.
            await refresh(manual: false)
            if r.failed {
                error = Self.quickError(verb: pinned ? String(localized: "Pin") : String(localized: "Unpin"), name: p.name, args: args, result: r)
            }
        }
    }

    /// 0.8: the uninstall sheet's "Unpin and Uninstall" for a pinned
    /// package: `brew unpin` through the queue, the re-read, then the
    /// normal uninstall of the now-unpinned package. Stops (with brew's
    /// error) if the unpin fails or brew still lists it as pinned.
    func unpinAndUninstall(_ p: Package) {
        uninstallCandidate = nil
        guard p.pinned, dependents(of: p).isEmpty else { return }
        let args = PinCommands.arguments(pin: false, for: p)
        Task {
            guard let r = await runQuick(args) else { return }
            await refresh(manual: false)
            if r.failed {
                error = Self.quickError(verb: String(localized: "Unpin"), name: p.name, args: args, result: r)
                return
            }
            guard let now = packages.first(where: { $0.id == p.id }), !now.pinned else { return }
            startUninstall(now)
        }
    }

    /// Selects a package from a dependency link, clearing a filter or
    /// search that would hide it (0.8.7: and scrolls to it; showInInstalled).
    func reveal(_ id: Package.ID) {
        guard packages.contains(where: { $0.id == id }) else { return }
        showInInstalled(id)
    }

    /// Runs one mutating brew command through the queue (the same queue as
    /// upgrades, so it waits its turn). nil when it couldn't start: brew
    /// not found, no status yet, or something else is already running;
    /// then `busyNotice` says so, so the click isn't silently lost.
    func runQuick(_ args: [String]) async -> QuickResult? {
        guard !isBusy, let client = try? resolvedClient(), let detection = report?.intelbrew else {
            showBusyNotice(Self.notStartedNotice(BrewCommands.display(args), running: quickAction, upgrading: isUpgrading))
            return nil
        }
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
            return QuickResult(exitCode: -1, lines: [String(localized: "Couldn't run brew: \(String(describing: error))")])
        }
    }

    /// "brew pin --formula homebrew/core/xz didn't start: brew services stop
    /// -- php is still running. Try again when it finishes."
    nonisolated static func notStartedNotice(_ command: String, running: String?, upgrading: Bool) -> String {
        if let running { return String(localized: "\(command) didn't start: \(running) is still running. Try again when it finishes.") }
        if upgrading { return String(localized: "\(command) didn't start: an upgrade is still running. Try again when it finishes.") }
        return String(localized: "\(command) didn't start: Homebrew isn't ready yet. Refresh, then try again.")
    }

    /// Shows `text` in the status bar, then clears it after `seconds`
    /// unless a newer notice replaced it.
    func showBusyNotice(_ text: String, seconds: Double = 6) {
        busyNotice = text
        busyNoticeToken += 1
        let token = busyNoticeToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.busyNoticeToken == token else { return }
            self.busyNotice = nil
        }
    }

    /// The banner for a failed one-off command: sudo gets the Terminal
    /// command; anything else gets brew's last lines.
    static func quickError(verb: String, name: String, args: [String], result: QuickResult, sudoCommand: String? = nil) -> StoreError {
        let display = BrewCommands.display(args)
        if SudoDetector.needsSudo(result.lines) || sudoCommand != nil {
            return StoreError(title: String(localized: "\(verb) \(name) needs administrator rights"),
                              detail: String(localized: "Tankard never runs sudo. Run this in Terminal:"),
                              terminalCommand: sudoCommand ?? "sudo " + display)
        }
        let tail = result.lines.suffix(6).joined(separator: "\n")
        // 0.6: brew's lock, no network, a full disk, permissions.
        if let kind = BrewFailure.classify(result.lines) {
            // 0.8.7: an untrusted tap: the command that fixes it, not the one that failed.
            let fix = kind == .untrustedTap ? UntrustedTapRefusal.parse(lines: result.lines)?.trustCommand : nil
            return StoreError(title: String(localized: "\(verb) \(name): \(kind.title)"), detail: kind.explanation + "\n\n" + tail,
                              terminalCommand: fix ?? display)
        }
        return StoreError(title: String(localized: "\(verb) \(name) failed (exit \(result.exitCode))"), detail: tail, terminalCommand: display)
    }
}
