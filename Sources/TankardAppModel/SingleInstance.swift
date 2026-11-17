import Foundation
import TankardCore

// 0.8.3: one Tankard at a time, and a self-upgrade relaunch that never
// leaves two. The AppKit side (NSRunningApplication, NSApp.terminate, the
// helper process) is in TankardApp.swift; the decisions are here, testable.

/// The launch-time guard: what to do about other running copies of Tankard
/// (same bundle id, not this process).
public enum SingleInstance {
    /// Another running Tankard, as NSRunningApplication describes it.
    public struct Other: Equatable, Sendable {
        public var pid: Int32
        /// nil when LaunchServices didn't record it.
        public var launchDate: Date?
        /// A demo, snapshot or script run (read from its environment):
        /// tests run those side by side on purpose, so they never count.
        public var isDevRun: Bool
        /// Runs from this app's own bundle path. Only those count: a build
        /// in another folder (a worktree's dist/, launch-check.sh's real-mode
        /// run) is a different copy, and brew replaces Tankard in place, so
        /// a stale old copy always has our path.
        public var samePath: Bool

        public init(pid: Int32, launchDate: Date?, isDevRun: Bool = false, samePath: Bool = true) {
            self.pid = pid
            self.launchDate = launchDate
            self.isDevRun = isDevRun
            self.samePath = samePath
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No other copy: carry on.
        case proceed
        /// The same build is already running (a second launch): bring that
        /// one forward and quit this one.
        case yield(to: Int32)
        /// Every other copy started before this app's executable was
        /// written: they run a bundle Homebrew has since replaced. Ask them
        /// to quit (politely, never force) and carry on as the new instance.
        case replaceStale([Int32])
    }

    /// `executableWritten`: when this app's executable reached this disk
    /// (see `writtenDate`). A copy launched before that runs the old build.
    /// One that launched after it runs this build, so this launch is the
    /// duplicate. Unknown dates count as the same build: when in doubt the
    /// copy that is already running keeps running.
    public static func decide(others: [Other], executableWritten: Date?) -> Decision {
        let real = others.filter { !$0.isDevRun && $0.samePath }
        guard !real.isEmpty else { return .proceed }
        var stale: [Int32] = []
        for o in real {
            if let launched = o.launchDate, let written = executableWritten, launched < written {
                stale.append(o.pid)
            } else {
                return .yield(to: o.pid)
            }
        }
        return .replaceStale(stale)
    }

    /// When a file reached this disk: the later of its modification and
    /// status-change times. The modification time alone isn't enough:
    /// unzip and Homebrew's move keep the build's mtime, which can be days
    /// before an old copy was launched; the status-change time is set when
    /// brew extracts and moves the new bundle, and can't be set back.
    public static func writtenDate(path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9) }
        return max(date(st.st_mtimespec), date(st.st_ctimespec))
    }

    /// When a process started, from the kernel (kinfo_proc). The fallback
    /// for NSRunningApplication.launchDate, which is nil for a process that
    /// wasn't started through LaunchServices (exec'd directly).
    public static func startDate(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        guard t.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }

    /// The same bundle, symlinks and `..` resolved.
    public static func samePath(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The variables that make a launch a dev run (LaunchOptions in
    /// TankardApp.swift reads the same ones). A script run that sets
    /// TANKARD_E2E_SELFUPDATE=1 behaves as the real app for the guard and
    /// the relaunch: the self-update e2e drives exactly that.
    public static func isDevRun(environment env: [String: String]) -> Bool {
        func set(_ k: String) -> Bool { !(env[k] ?? "").isEmpty }
        if env["TANKARD_E2E"] == "1" && set("TANKARD_SCRIPT") { return env["TANKARD_E2E_SELFUPDATE"] != "1" }
        if set("TANKARD_SNAPSHOT") { return true }
        if let d = env["TANKARD_DEMO"], Demo.Variant(environmentValue: d) != nil { return true }
        if let n = env["TANKARD_DEMO_NOBREW"]?.lowercased(), ["intel", "arm64", "applesilicon"].contains(n) { return true }
        return false
    }

    /// Another process's environment (same user only), from
    /// sysctl KERN_PROCARGS2. nil if it can't be read.
    public static func environment(pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// KERN_PROCARGS2's layout: argc (Int32), the executable path, NUL
    /// padding, argc arguments, then the environment as KEY=VALUE strings,
    /// each NUL-terminated, up to an empty string.
    public static func parseProcArgs(_ b: [UInt8]) -> [String: String]? {
        guard b.count >= 4 else { return nil }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 } // executable path
        while i < b.count, b[i] == 0 { i += 1 } // padding
        var seen = 0
        while i < b.count, seen < argc { // arguments
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
            seen += 1
        }
        guard seen == argc else { return nil }
        var env: [String: String] = [:]
        while i < b.count, b[i] != 0 {
            let start = i
            while i < b.count, b[i] != 0 { i += 1 }
            let s = String(decoding: b[start..<i], as: UTF8.self)
            if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
            i += 1
        }
        return env
    }

    /// The new instance's alert while a stale copy refuses to quit.
    public static let staleAlertMessage = String(localized: "An older copy of Tankard is still running. Quit it to finish updating.")
    public static let staleAlertButton = String(localized: "Show Older Copy")
    /// How long a stale copy gets to quit before the alert.
    public static let staleGrace: TimeInterval = 5
}

/// The self-upgrade (and App Management) relaunch, as steps the app
/// supplies. Order: start the helper (it only waits for this pid to exit,
/// then opens the bundle; after ~10 s it gives up and opens nothing), close
/// every sheet (AppKit refuses to terminate under a modal sheet: "App
/// termination blocked by modal sheet"), terminate. If this process is
/// still here after `retryAfter`, close sheets and terminate once more; if
/// it is still here after that, give up: say so, open nothing.
@MainActor
public struct RelaunchSequence {
    public var startHelper: () -> Bool
    public var closeSheets: () -> Void
    public var terminate: () -> Void
    /// Runs the closure after the delay on the main actor (tests: at once, in order).
    public var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    public var gaveUp: () -> Void
    public var retryAfter: TimeInterval = 1.5

    public init(startHelper: @escaping () -> Bool, closeSheets: @escaping () -> Void, terminate: @escaping () -> Void,
                after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void, gaveUp: @escaping () -> Void) {
        self.startHelper = startHelper
        self.closeSheets = closeSheets
        self.terminate = terminate
        self.after = after
        self.gaveUp = gaveUp
    }

    /// False: the helper didn't start, nothing else happened (Tankard keeps
    /// running). Never opens a second instance itself.
    public func run() -> Bool {
        guard startHelper() else { return false }
        closeSheets()
        // The next turn: the sheets' dismissal is processed first.
        after(0.2) { [self] in
            terminate()
            after(retryAfter) { [self] in
                closeSheets()
                terminate()
                after(retryAfter) { [self] in gaveUp() }
            }
        }
        return true
    }
}
