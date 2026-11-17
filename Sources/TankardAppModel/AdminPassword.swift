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

    /// The sentence the dialog shows for this step (one line).
    public static func context(_ p: Package?, display: String) -> String {
        guard let p, !p.isCommandRow else { return String(localized: "For this step: \(display)") }
        return required(p) ? String(localized: "To run the installer for \(p.name): \(display)")
            : String(localized: "For this step of \(p.name): \(display)")
    }

    /// The extra environment for one queued command: the helper and the
    /// dialog's context, only for a command that may run sudo and only
    /// when the helper exists. Not part of the command line shown or copied
    /// (the Terminal fallback must not pop Tankard's dialog).
    public static func environment(helper: String?, arguments: [String], package: Package?, display: String) -> [String: String] {
        guard mayNeedSudo(arguments) else { return [:] }
        return Askpass.environment(helper: helper, context: context(package, display: display))
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
        case .wrongPassword: return String(localized: "sudo didn't accept the password. To try again, run the step again, or run this in Terminal:")
        case .sudoDisabled, .noPrompt: return String(localized: "This step needs administrator rights, which Tankard can't ask for. Run this in Terminal:")
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
