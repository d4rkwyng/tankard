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
/// /dev/null, and cancellation sends SIGTERM to the group, then SIGKILL
/// after `killGrace` seconds.
///
/// Output goes through one pipe (stdout and stderr both dup'd onto it), so
/// brew's interleaving of `==>` lines and errors is kept. A pty would make
/// brew draw its tty-only progress; pipes plus `LineAssembler` are the v1
/// choice (see the design notes).
public struct StreamingProcessRunner: StreamingCommandRunning {
    public var killGrace: Double

    public init(killGrace: Double = 2) {
        self.killGrace = killGrace
    }

    public func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                       output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        let pidBox = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        let grace = killGrace
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let c = try Self.spawnAndStream(executable, arguments, environment, output: output) { pid in
                            pidBox.withLock { $0 = pid }
                        }
                        continuation.resume(returning: c)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            guard let pid = pidBox.withLock({ $0 }) else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            }
        }
        if Task.isCancelled { throw ProcessRunnerError.cancelled }
        return code
    }

    static func spawnAndStream(_ executable: String, _ arguments: [String], _ environment: [String: String],
                               output: (Data) -> Void, started: (pid_t) -> Void) throws -> Int32 {
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
        let flags = Int16(POSIX_SPAWN_SETSID) | Int16(POSIX_SPAWN_SETSIGMASK) | Int16(POSIX_SPAWN_SETSIGDEF)
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

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let low = status & 0x7f
        return low == 0 ? (status >> 8) & 0xff : 128 + low
    }
}
