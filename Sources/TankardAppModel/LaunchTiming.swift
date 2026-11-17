import Darwin
import Foundation

/// 0.8: launch timing for measurement, off unless asked for.
///
///   TANKARD_LOG_TIMING=1   print "timing: <event> <ms>" to stderr, in ms since
///                          the process started (the kernel's start time, so
///                          dyld and App.init are included)
///
/// Events: `list (cache)` (the cached report is on screen), `list (brew)`
/// (the first live `brew info` read is on screen), `sizes` (`brew info
/// --sizes` arrived), `brew update` / `re-read` (the background update).
public enum LaunchTiming {
    public static let isEnabled = ProcessInfo.processInfo.environment["TANKARD_LOG_TIMING"] == "1"

    /// When the kernel started this process (nil if sysctl fails).
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()

    /// Milliseconds since the process started.
    public static func sinceStart(_ now: Date = Date()) -> Int? {
        processStart.map { Int((now.timeIntervalSince($0) * 1000).rounded()) }
    }

    private static let seen = NSLock()
    nonisolated(unsafe) private static var logged: Set<String> = []

    /// Logs `event` (the first time only, with `once`).
    public static func mark(_ event: String, once: Bool = false) {
        guard isEnabled else { return }
        if once {
            let first = seen.withLock { logged.insert(event).inserted }
            guard first else { return }
        }
        let ms = sinceStart().map(String.init) ?? "?"
        FileHandle.standardError.write(Data("timing: \(event) \(ms) ms\n".utf8))
    }

    /// A free-form line ("timing: status read detect=0 git=12 …").
    public static func note(_ text: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("timing: \(text)\n".utf8))
    }
}
