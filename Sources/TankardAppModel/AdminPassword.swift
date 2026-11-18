import AskpassSupport
import Darwin
import Foundation
import TankardCore

/// 0.8.3: when brew's sudo may ask for the administrator password, and how
/// Tankard lets it.
///
/// Tankard itself never runs sudo. For a cask install, reinstall, upgrade
/// or uninstall (adopt is `brew install --cask --adopt`), it sets
/// `SUDO_ASKPASS` to its password dialog (`tankard-askpass`), so the sudo
/// that brew runs (a `.pkg` installer, `pkgutil --forget`, removing
/// root-owned files) asks in a dialog instead of failing for want of a
/// terminal. Never for formulae, read-only queries, `brew update`, cleanup,
/// taps, services, or automatic updates (those get `HOMEBREW_NO_SUDO`).
public enum AdminPassword {
    /// The commands that may run sudo: a cask install (adopt too),
    /// reinstall, upgrade or uninstall.
    public static func mayNeedSudo(_ arguments: [String]) -> Bool {
        AppManagement.isCaskCommand(arguments)
    }

    /// The cask runs an installer package (`pkg`) or an `installer` script
    /// with `sudo: true`: brew will ask for the password. Known from
    /// `brew info`'s artifacts; false when brew gave none.
    public static func required(_ p: Package) -> Bool {
        p.kind == .cask && (p.installsPkg == true || p.sudoInstaller == true)
    }

    /// 0.8.5: the row badge's tooltip.
    public static var badgeHelp: String { String(localized: "Needs your password to upgrade") }

    /// 0.8.5 (final pass L2): the password box's words. `plain` is what
    /// happens, without brew, sudo or Terminal; `details` (under Details)
    /// says how. `helper` false: this build can't show the dialog (`swift
    /// run`, demo), so the sheet will show the Terminal command.
    public static func noteText(helper: Bool, uninstall: Bool) -> (plain: String, details: String) {
        let plain = !helper ? String(localized: "Tankard can't ask for it here. Details says what to do instead.")
            : uninstall ? String(localized: "Tankard will ask for it in a dialog while removing it. It never stores it.")
            : String(localized: "Tankard will ask for it in a dialog when the upgrade gets there. It never stores it.")
        let details = (uninstall ? String(localized: "brew removes the installer's files with sudo.")
                       : String(localized: "brew runs the installer with sudo.")) + " "
            + (helper ? String(localized: "Tankard asks for the password in a dialog and passes it only to sudo; it never stores it. If you cancel, the sheet shows the command for Terminal.")
               : String(localized: "Tankard can't ask for it here, so the sheet will show the command for Terminal."))
        return (plain, details)
    }

    /// 0.8.5: an upgrade run's order with the password casks last, so the
    /// password dialogs come together at the end instead of in the middle
    /// of the run (each cask's sudo may still ask on its own). Otherwise the
    /// order is kept: the queue runs steps in list order and brew resolves
    /// each step's dependencies itself. A cask that depends on (`depends_on
    /// cask:`) one moved to the end moves to the end too, so no step is
    /// moved ahead of something it needs; the moved group keeps its own
    /// order. Formulae never depend on casks, so moving casks later can't
    /// put a formula before its dependency.
    public static func passwordStepsLast(_ packages: [Package]) -> [Package] {
        var last = Set(packages.filter(required).map(\.id))
        guard !last.isEmpty else { return packages }
        func names(_ p: Package) -> Set<String> { [p.name, p.fullName] }
        var changed = true
        while changed {
            changed = false
            let lastNames = packages.filter { last.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion(names($1)) }
            for p in packages where p.kind == .cask && !last.contains(p.id) {
                if (p.caskDependencies ?? []).contains(where: { lastNames.contains($0) || lastNames.contains(($0 as NSString).lastPathComponent) }) {
                    last.insert(p.id)
                    changed = true
                }
            }
        }
        return packages.filter { !last.contains($0.id) } + packages.filter { last.contains($0.id) }
    }

    /// 0.8.4: brew's output says it is about to run sudo: "Running
    /// installer for x with `sudo` (which may request your password)", or
    /// a `/usr/bin/sudo` command line (uninstall's pkgutil, launchctl, rm).
    public static func announcesSudo<S: Sequence>(_ lines: S) -> Bool where S.Element == String {
        lines.contains { $0.contains("with `sudo`") || $0.contains("/usr/bin/sudo ") || $0.contains("which may request your password") }
    }

    /// The extra environment for one queued command: the helper and the
    /// dialog's context, only for a command that may run sudo and only
    /// when the helper exists. Not part of the command line shown or copied
    /// (the Terminal fallback must not pop Tankard's dialog). 0.8.4: the
    /// context is the command as displayed; the dialog derives its words
    /// ("To upgrade windows-app.") from it and shows it under Details.
    ///
    /// 0.8.4: with a `foreign` helper in brew.env, never Tankard's own (brew.env
    /// would replace it anyway): `HOMEBREW_NO_SUDO=1` instead, so brew fails
    /// before running `sudo -A` with that helper. See `ForeignAskpass`.
    public static func environment(helper: String?, arguments: [String], display: String,
                                   foreign: ForeignAskpass? = nil) -> [String: String] {
        guard mayNeedSudo(arguments) else { return [:] }
        if foreign != nil { return unattendedEnvironment }
        return Askpass.environment(helper: helper, context: display)
    }

    /// 0.8.4: why a sudo-capable step must not run from Tankard, checked
    /// right before it starts (the queue's precondition) with brew.env read
    /// again then; nil: it may run. Refused when brew.env has a foreign
    /// helper and brew could still run `sudo -A` with it: the step's
    /// environment doesn't carry HOMEBREW_NO_SUDO=1 (it was built before the
    /// helper appeared, or with Tankard's helper), brew.env clears
    /// HOMEBREW_NO_SUDO itself, or the cask is known to run its installer
    /// with sudo (it would only fail).
    public static func refusal(arguments: [String], package: Package?, environment: [String: String],
                               foreign: ForeignAskpass?) -> String? {
        guard mayNeedSudo(arguments), let foreign else { return nil }
        if foreign.unstoppable || environment[Askpass.noSudoKey] != "1" || environment[Askpass.askpassKey] != nil
            || package.map(required) == true {
            return foreign.message
        }
        return nil
    }

    /// Automatic updates never ask: brew is told not to run sudo at all
    /// (`HOMEBREW_NO_SUDO=1`; a pkg cask then fails before downloading:
    /// "The pkg artifact requires sudo, but HOMEBREW_NO_SUDO is set").
    public static let unattendedEnvironment: [String: String] = [Askpass.noSudoKey: "1"]

    /// The helper in the running app bundle, or nil (`swift run`, tests).
    public static func liveHelper(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        Askpass.helperPath(appBundle: bundleURL)
    }
}

/// 0.8.4: a `SUDO_ASKPASS` in brew.env that isn't Tankard's own helper.
///
/// bin/brew reads `SUDO_ASKPASS=` lines from brew.env and exports them over
/// the environment Tankard passes, and brew 7.0.14 then runs every sudo as
/// `/usr/bin/sudo -A -E -- ...` (system_command.rb: `-A` whenever
/// SUDO_ASKPASS is set), so sudo runs that helper. Checked with a throwaway
/// XDG brew.env and a helper that only records the call and exits 1:
/// Tankard's own SUDO_ASKPASS in the environment loses to the brew.env one,
/// and the helper runs; with HOMEBREW_NO_SUDO=1 in the environment brew
/// stops with "sudo is disabled by HOMEBREW_NO_SUDO." and the helper never
/// runs, unless brew.env also sets `HOMEBREW_NO_SUDO=` (empty: bin/brew
/// drops it), and then the helper runs again.
///
/// So Tankard never offers its password dialog for such a step (another
/// program's dialog would appear where Tankard said its own would), runs it
/// with HOMEBREW_NO_SUDO=1, and refuses it outright when that can't hold
/// (`AdminPassword.refusal`). The step's command is shown for Terminal.
public struct ForeignAskpass: Equatable, Sendable {
    /// The value as brew.env sets it (bin/brew exports it literally).
    public var helper: String
    /// The brew.env file it comes from.
    public var source: String
    /// brew.env also sets HOMEBREW_NO_SUDO empty, so Tankard can't stop
    /// brew from running sudo with the helper.
    public var unstoppable: Bool

    public init(helper: String, source: String, unstoppable: Bool) {
        self.helper = helper
        self.source = source
        self.unstoppable = unstoppable
    }

    /// The sheet's and the plan's sentence, above the Terminal command.
    public var message: String {
        String(localized: "Your Homebrew settings use a different password program, so Tankard can't ask for your password here. Run this step in Terminal:")
    }

    /// The brew.env SUDO_ASKPASS brew will use (bin/brew's precedence), when
    /// it isn't `own` (compared after resolving symlinks); nil when unset,
    /// empty (bin/brew drops empty values) or Tankard's own helper.
    public static func detect(brewEnvFiles: [(String, [String: String])], own: String?,
                              resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        -> ForeignAskpass? {
        guard let s = EnvironmentSources.brewEnvSetting(Askpass.askpassKey, files: brewEnvFiles), !s.value.isEmpty else {
            return nil
        }
        if let own, !own.isEmpty, resolve(s.value) == resolve(own) { return nil }
        let noSudo = EnvironmentSources.brewEnvSetting(Askpass.noSudoKey, files: brewEnvFiles)
        return ForeignAskpass(helper: s.value, source: s.source, unstoppable: noSudo?.value.isEmpty == true)
    }
}

/// How a step that ran sudo through the dialog ended, from brew's output.
public enum SudoOutcome: Equatable, Sendable {
    /// The dialog was cancelled (or timed out): "sudo: no password was provided".
    case cancelled
    /// Wrong password every time sudo asked: "sudo: 3 incorrect password attempts".
    case wrongPassword
    /// brew was told not to run sudo (automatic updates).
    case sudoDisabled
    /// Needed sudo and no dialog could ask (no helper: the old message).
    case noPrompt
    /// 0.8.4: brew.env sets another password helper (its path): Tankard
    /// refused the step, or ran it without sudo and it needed sudo.
    case foreignHelper(String)

    /// sudo 1.9's messages (verified on macOS 27 with `sudo -A`: a helper
    /// that exits 1 prints "no password was provided" then "a password is
    /// required"; three wrong answers print "3 incorrect password attempts";
    /// Cancel after one wrong answer prints "no password was provided" and
    /// "1 incorrect password attempt", which counts as cancelled: that was
    /// the last thing the user did).
    public static func classify(_ lines: some Sequence<String>) -> SudoOutcome? {
        let lower = lines.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("sudo: no password was provided") }) { return .cancelled }
        if lower.contains(where: { $0.contains("incorrect password attempt") }) { return .wrongPassword }
        if lower.contains(where: { $0.contains("homebrew_no_sudo") }) { return .sudoDisabled }
        if SudoDetector.needsSudo(lower) { return .noPrompt }
        return nil
    }

    /// The sheet's sentence above the Terminal command.
    public var message: String {
        switch self {
        case .cancelled: return String(localized: "The password dialog was cancelled, so this step didn't run. To run it yourself, use Terminal:")
        case .wrongPassword: return String(localized: "macOS didn't accept the password. To try again, run the step again, or run this in Terminal:")
        case .sudoDisabled, .noPrompt: return String(localized: "This step needs administrator rights, which Tankard can't ask for. Run this in Terminal:")
        case .foreignHelper(let helper):
            return ForeignAskpass(helper: helper, source: "", unstoppable: false).message
        }
    }
}

extension AppStore {
    /// Demo and screenshots only (TANKARD_DEMO_PASSWORD): treat this cask
    /// as one whose installer brew runs with sudo.
    public func demoRequirePassword(_ name: String) {
        guard var r = report else { return }
        for i in r.packages.indices where r.packages[i].name == name && r.packages[i].kind == .cask {
            r.packages[i].installsPkg = true
        }
        report = r
    }
}

/// 0.8.3: how a session finds Tankard's password helper and gives it focus.
/// The app sets `yield` to `NSApp.yieldActivation(to:)` (AppKit); tests
/// inject both closures.
public struct AskpassFocus: Sendable {
    /// The helper's pid when it is running under this Tankard, else nil.
    /// Called off the main actor.
    public var find: @Sendable () -> pid_t?
    /// Called on the main actor, once per helper process.
    public var yield: @MainActor @Sendable (pid_t) -> Void
    public var interval: Duration

    public init(find: @escaping @Sendable () -> pid_t?, yield: @escaping @MainActor @Sendable (pid_t) -> Void,
                interval: Duration = .milliseconds(400)) {
        self.find = find
        self.yield = yield
        self.interval = interval
    }

    /// The real lookup: a process running exactly `helper` (kernel path)
    /// whose ancestors include this Tankard process. Reads only the process
    /// table (proc_listallpids, proc_pidpath, sysctl).
    public static func liveFind(helper: String, tankard: pid_t = getpid()) -> @Sendable () -> pid_t? {
        { AskpassProcess.find(helperPath: helper, below: tankard) }
    }
}

public enum AskpassProcess {
    public static func find(helperPath: String, below ancestor: pid_t, maxDepth: Int = 12) -> pid_t? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        for pid in pids.prefix(Int(count)) where pid > 1 && path(pid) == helperPath {
            if descends(pid, from: ancestor, maxDepth: maxDepth) { return pid }
        }
        return nil
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func descends(_ pid: pid_t, from ancestor: pid_t, maxDepth: Int) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            guard let p = parent(current), p > 1 else { return false }
            if p == ancestor { return true }
            current = p
        }
        return false
    }
}

// MARK: 0.8.5: Upgrade Now for casks an automatic run skipped

public extension AppStore {
    /// The casks `run` skipped for the administrator password that still
    /// have an upgrade Upgrade would run now (in the list's order).
    func passwordSkippedUpgrades(_ run: AutoUpdateRun) -> [Package] {
        let names = Set(run.passwordSkipped)
        guard !names.isEmpty else { return [] }
        return packages.filter { $0.kind == .cask && names.contains($0.name) && $0.isManualUpgradeTarget }
    }

    /// The Auto-update log's Upgrade Now: a normal upgrade of those casks
    /// (the plan, which says the password will be asked, then the run).
    /// `closeLog` closes the sheet the log is in first.
    func upgradePasswordSkipped(_ run: AutoUpdateRun, closeLog: (() -> Void)? = nil) {
        let targets = passwordSkippedUpgrades(run)
        guard !targets.isEmpty, !isUpgrading, !autoUpdate.isRunning else { return }
        closeLog?()
        showAutoUpdateLog = false
        Task { @MainActor in
            // The log's sheet goes first; the plan opens once it has gone.
            try? await Task.sleep(for: .milliseconds(450))
            self.requestUpgrade(targets)
        }
    }
}
