import Foundation
import os

/// Runs a command and hands its output over as it arrives. Used for
/// mutating commands (`brew update`, `brew upgrade`) whose progress the app
/// shows live. Injected so tests and demo mode can script the output.
public protocol StreamingCommandRunning: Sendable {
    /// Runs `executable` with literal `arguments` and exactly `environment`.
    /// stdout and stderr are merged, in the order the child wrote them, and
    /// passed to `output` in chunks (not split on lines). Returns the exit
    /// code. Cancelling the calling task stops the child's whole process
    /// group and throws `ProcessRunnerError.cancelled`.
    func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32
}

/// posix_spawn streaming runner. Same rules as `ProcessRunner`: no shell,
/// no inherited environment, the child leads its own session, stdin is
/// /dev/null. 0.8.3: cancellation sends SIGINT to the group (what brew
/// treats as Ctrl-C: it finishes the step it can't leave half done, under
/// `Utils::Interrupts.ignore`, rolls back and exits 130), then SIGTERM after
/// `interruptGrace` seconds if anything is still running, then SIGKILL after
/// `killGrace` more. Before 0.8.3 it was SIGTERM, then SIGKILL after 2 s,
/// which can cut brew's own rollback short (Ruby doesn't defer SIGTERM).
///
/// Output goes through one pipe (stdout and stderr both dup'd onto it), so
/// brew's interleaving of `==>` lines and errors is kept. A pty would make
/// brew draw its tty-only progress; pipes plus `LineAssembler` are the v1
/// choice (see the design notes).
public struct StreamingProcessRunner: StreamingCommandRunning {
    /// Seconds between SIGTERM and SIGKILL.
    public var killGrace: Double
    /// 0.8.3: seconds between SIGINT and SIGTERM. A real `brew upgrade`
    /// interrupted mid-build took 11 s to roll back and exit.
    public var interruptGrace: Double
    /// 0.8.6: sends a signal, `kill(2)`-style (a negative pid is a process
    /// group). Injected so tests can see which signals Stop Now sends.
    public var sendSignal: @Sendable (pid_t, Int32) -> Void
    /// 0.8.8 (security review #3): called with the child's pid and
    /// environment right after it is spawned; what it returns is called once
    /// the child has exited. The app issues the password helper's ticket
    /// here (AskpassTicket) for a step that may need sudo.
    public var onSpawn: (@Sendable (pid_t, [String: String]) -> (@Sendable () -> Void)?)?

    public init(killGrace: Double = 15, interruptGrace: Double? = nil,
                sendSignal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = kill($0, $1) },
                onSpawn: (@Sendable (pid_t, [String: String]) -> (@Sendable () -> Void)?)? = nil) {
        self.killGrace = killGrace
        self.interruptGrace = interruptGrace ?? killGrace
        self.sendSignal = sendSignal
        self.onSpawn = onSpawn
    }

    /// The child's pid; whether the task was cancelled; whether the child
    /// has exited (set before it is reaped, under the same lock the stop's
    /// signals are sent under, so no signal is sent once its pid is free).
    struct RunState: Sendable {
        var pid: pid_t?
        var cancelled = false
        var exited = false
    }

    public func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                       output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        // The child's pid, and whether the task was cancelled. Whichever of
        // the two comes second starts the stop: a cancel that arrives before
        // posix_spawn has returned (Stop Now right after the step started)
        // used to find no pid and do nothing, and the child ran to the end.
        let state = OSAllocatedUnfairLock<RunState>(initialState: RunState())
        let grace = killGrace
        let interruptGrace = interruptGrace
        let send = sendSignal
        let onSpawn = onSpawn
        let afterExit = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let c = try Self.spawnAndStream(executable, arguments, environment, output: output, started: { pid in
                            if let cleanup = onSpawn?(pid, environment) { afterExit.withLock { $0 = cleanup } }
                            let stopNow = state.withLock { s -> Bool in
                                s.pid = pid
                                return s.cancelled
                            }
                            if stopNow { Self.stop(pid, state: state, interruptGrace: interruptGrace, killGrace: grace, send: send) }
                        }, exited: {
                            state.withLock { $0.exited = true }
                            afterExit.withLock { c -> (@Sendable () -> Void)? in defer { c = nil }; return c }?()
                        })
                        continuation.resume(returning: c)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let pid = state.withLock { s -> pid_t? in
                s.cancelled = true
                return s.pid
            }
            if let pid { Self.stop(pid, state: state, interruptGrace: interruptGrace, killGrace: grace, send: send) }
        }
        if Task.isCancelled { throw ProcessRunnerError.cancelled }
        return code
    }

    /// SIGINT to the group; SIGTERM after `interruptGrace` s if anything is
    /// still running; SIGKILL after `killGrace` more.
    ///
    /// 0.8.6 (walkthrough L6): and to the process groups of descendants that
    /// left the group. brew's sandboxed build runs in a session of its own
    /// (sandbox.rb: `Process.setsid` in the forked child, a PTY as its
    /// terminal), so the SIGINT missed the build; brew waited for it, and
    /// Stop Now took ~16 s and ended in SIGTERM, cutting brew's rollback.
    ///
    /// 0.8.6 (HK-47 review): those groups are found once, at the SIGINT
    /// (once brew has exited its build is launchd's child, and a later walk
    /// from brew's pid misses it), each with one member and that member's
    /// start time. Every later signal is sent under the run's lock and only
    /// while the child has not exited (after it is reaped its pid can be
    /// reused); an outside group is signalled only while its recorded member
    /// is still the same process, in that group.
    static func stop(_ pid: pid_t, state: OSAllocatedUnfairLock<RunState>,
                     interruptGrace: Double, killGrace: Double,
                     send: @escaping @Sendable (pid_t, Int32) -> Void) {
        let groups: [OutsideGroup]? = state.withLock { s in
            guard !s.exited else { return nil }
            let groups = outsideGroups(pid)
            send(-pid, SIGINT)
            for g in groups { send(-g.pgid, SIGINT) }
            return groups
        }
        guard let groups else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptGrace) {
            let going: Bool = state.withLock { s in
                guard !s.exited else { return false }
                let live = groups.filter { $0.isStillThere() }
                guard kill(-pid, 0) == 0 || !live.isEmpty else { return false }
                send(-pid, SIGTERM)
                for g in live { send(-g.pgid, SIGTERM) }
                return true
            }
            guard going else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                state.withLock { s in
                    guard !s.exited else { return }
                    send(-pid, SIGKILL)
                    for g in groups where g.isStillThere() { send(-g.pgid, SIGKILL) }
                }
            }
        }
    }

    /// A process group one of the child's descendants leads or belongs to,
    /// other than the child's own, with one member that identifies it later.
    struct OutsideGroup: Sendable, Equatable {
        var pgid: pid_t
        var member: pid_t
        var memberStart: ProcessStart

        /// The member is the same process (same start time) and still in
        /// the group: the group still exists, so its id has not been reused.
        func isStillThere() -> Bool {
            ProcessStart.of(member) == memberStart && getpgid(member) == pgid
        }
    }

    /// A process's start time (libproc `PROC_PIDTBSDINFO`), which tells a
    /// process from a later one given the same pid.
    struct ProcessStart: Sendable, Equatable {
        var sec: UInt64
        var usec: UInt64

        static func of(_ pid: pid_t) -> ProcessStart? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return ProcessStart(sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec)
        }
    }

    /// The process groups of `pid`'s descendants other than its own, each
    /// with a member (the leader, when it is one of the descendants).
    static func outsideGroups(_ pid: pid_t) -> [OutsideGroup] {
        var members: [pid_t: pid_t] = [:]
        var order: [pid_t] = []
        for d in descendants(of: pid) {
            let g = getpgid(d)
            guard g > 1, g != pid else { continue }
            if members[g] == nil { order.append(g) }
            if members[g] == nil || d == g { members[g] = d }
        }
        return order.compactMap { g in
            guard let m = members[g], let start = ProcessStart.of(m) else { return nil }
            return OutsideGroup(pgid: g, member: m, memberStart: start)
        }
    }

    /// Every descendant of `pid` (libproc, breadth first, at most 4096).
    static func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [pid]
        while let p = queue.first, out.count < 4096 {
            queue.removeFirst()
            var buffer = [pid_t](repeating: 0, count: 256)
            let n = buffer.withUnsafeMutableBytes { proc_listchildpids(p, $0.baseAddress, Int32($0.count)) }
            guard n > 0 else { continue }
            let kids = buffer.prefix(Int(n)).filter { $0 > 0 }
            out += kids
            queue += kids
        }
        return out
    }

    static func spawnAndStream(_ executable: String, _ arguments: [String], _ environment: [String: String],
                               output: (Data) -> Void, started: (pid_t) -> Void,
                               exited: () -> Void = {}) throws -> Int32 {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunnerError.spawnFailed(executable, errno) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 0.8: POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets only the descriptors
        // the file actions set up (stdin, stdout, stderr). Without it, a child
        // spawned while another thread's pipes were open inherited their write
        // ends, and that other read saw end-of-file only when this child
        // exited: concurrent reads finished together, as slow as the slowest
        // (`brew info` waited for `brew info --sizes`, git probes for brew).
        let flags = Int16(POSIX_SPAWN_SETSID) | Int16(POSIX_SPAWN_SETSIGMASK) | Int16(POSIX_SPAWN_SETSIGDEF)
            | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw ProcessRunnerError.spawnFailed(executable, rc)
        }
        started(pid)

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, $0.count) }
            if n > 0 {
                output(Data(buffer[0..<n]))
            } else if n == 0 || errno != EINTR {
                break
            }
        }
        close(fds[0])

        // 0.8.6: wait without reaping, mark the run exited (under the stop's
        // lock), then reap: a stop timer either signals before this, while
        // the pid is still the child's (a zombie keeps it), or not at all.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        exited()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let low = status & 0x7f
        return low == 0 ? (status >> 8) & 0xff : 128 + low
    }
}
