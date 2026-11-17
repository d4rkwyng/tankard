import Foundation
import os

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var seconds: Double

    public init(exitCode: Int32, stdout: Data, stderr: Data, seconds: Double = 0) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.seconds = seconds
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case spawnFailed(String, Int32)
    case cancelled

    public var description: String {
        switch self {
        case .spawnFailed(let exe, let errno): let reason = String(cString: strerror(errno))
            return String(localized: "couldn't start \(exe): \(reason)")
        case .cancelled: return String(localized: "cancelled")
        }
    }
}

/// Runs a command. Injected into BrewClient so tests can return fixtures.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult
}

/// posix_spawn runner.
///
/// - argv is passed literally (no shell), and the environment is exactly
///   `environment`: nothing is inherited from this process.
/// - The child starts its own session (POSIX_SPAWN_SETSID), so it leads a
///   process group. Cancelling the Swift task sends SIGTERM to the whole
///   group (brew's Ruby, git, curl children), then SIGKILL after 2 seconds.
/// - stdin is /dev/null; stdout and stderr are drained on separate threads
///   so a large JSON payload can't fill a pipe and deadlock.
public struct ProcessRunner: CommandRunning {
    public var killGrace: Double

    public init(killGrace: Double = 2) {
        self.killGrace = killGrace
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        // The pid, and whether the task was cancelled before the child
        // existed: then the child is stopped as soon as it starts (0.6.1:
        // a Stop pressed right after Scan now left brew vulns running).
        let box = OSAllocatedUnfairLock<(pid: pid_t?, cancelled: Bool)>(initialState: (nil, false))
        let grace = killGrace
        let stop: @Sendable (pid_t) -> Void = { pid in
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                // Still alive (kill 0 succeeds)? Then force it.
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            }
        }
        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let r = try Self.spawnAndWait(executable, arguments, environment) { pid in
                            let cancelled = box.withLock { s -> Bool in
                                s.pid = pid
                                return s.cancelled
                            }
                            if cancelled { stop(pid) }
                        }
                        continuation.resume(returning: r)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let pid = box.withLock { s -> pid_t? in
                s.cancelled = true
                return s.pid
            }
            if let pid { stop(pid) }
        }
        if Task.isCancelled { throw ProcessRunnerError.cancelled }
        return result
    }

    static func spawnAndWait(_ executable: String, _ arguments: [String], _ environment: [String: String],
                             started: (pid_t) -> Void) throws -> ProcessResult {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw ProcessRunnerError.spawnFailed(executable, errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session => new process group led by the child. Also reset
        // signal mask/defaults so the child isn't affected by ours.
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

        let start = Date()
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ProcessRunnerError.spawnFailed(executable, rc)
        }
        started(pid)

        let errHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        let outHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let errData = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let d = errHandle.readDataToEndOfFile()
            errData.withLock { $0 = d }
            group.leave()
        }
        let outData = outHandle.readDataToEndOfFile()
        group.wait()

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift can't import.
        let low = status & 0x7f
        let exitCode: Int32 = low == 0 ? (status >> 8) & 0xff : 128 + low

        return ProcessResult(exitCode: exitCode, stdout: outData, stderr: errData.withLock { $0 },
                             seconds: Date().timeIntervalSince(start))
    }
}
