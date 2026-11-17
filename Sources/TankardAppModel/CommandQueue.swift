import Foundation
import os
import TankardCore

/// A command for the queue: literal argv plus the exact environment.
public struct QueuedCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// What the user sees and can copy: `brew upgrade --formula homebrew/core/xz`.
    /// The environment Tankard always sets and internal flags are not part
    /// of it; a variable from a setting the user chose is (0.4:
    /// `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 brew upgrade --cask …`).
    public var display: String

    public init(executable: String, arguments: [String], environment: [String: String], display: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.display = display
    }
}

public enum CommandEvent: Sendable, Equatable {
    case started
    case output(Data)
    case finished(exitCode: Int32)
    /// Cancelled before it started, or stopped while running.
    case cancelled
    /// Could not be started (missing executable, ...).
    case failed(String)
}

/// A strict FIFO queue for brew commands that change things (update,
/// upgrade). Exactly one runs at a time, in the order `enqueue` was called.
///
/// Why not just an actor: an actor is re-entrant, so two `await`ing callers
/// can interleave at every suspension point and nothing stops a second brew
/// from starting while the first is still running. Here `enqueue` is
/// synchronous (its order is the call order), jobs go into an `AsyncStream`,
/// and a single worker task runs each one to completion before taking the
/// next.
///
/// Read-only queries (`brew info`, git) do not use the queue.
public final class CommandQueue: Sendable {
    public typealias Handler = @Sendable (CommandEvent) -> Void

    struct Job: Sendable {
        var id: UUID
        var command: QueuedCommand
        var handler: Handler
    }

    struct State {
        var pending: [UUID] = []
        var cancelled: Set<UUID> = []
        var running: (id: UUID, task: Task<Int32, Error>)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>

    public init(runner: StreamingCommandRunning) {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let state = self.state
        worker = Task.detached(priority: .userInitiated) {
            for await job in stream {
                await Self.execute(job, runner: runner, state: state)
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    /// Adds a command at the back of the queue and returns its id. Events
    /// for it arrive on `handler`, from a background thread.
    @discardableResult
    public func enqueue(_ command: QueuedCommand, id: UUID = UUID(), handler: @escaping Handler) -> UUID {
        // Append and yield under the lock, so the stream order is exactly
        // the order of enqueue calls even from different threads.
        state.withLockUnchecked { s in
            s.pending.append(id)
            continuation.yield(Job(id: id, command: command, handler: handler))
        }
        return id
    }

    /// Runs `command` through the queue and waits for it. The output
    /// arrives on `output`. Returns the exit code; throws on cancel or spawn
    /// failure.
    public func run(_ command: QueuedCommand, output: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            enqueue(command) { event in
                switch event {
                case .started: break
                case .output(let d): output(d)
                case .finished(let code): cont.resume(returning: code)
                case .cancelled: cont.resume(throwing: ProcessRunnerError.cancelled)
                case .failed(let message): cont.resume(throwing: CommandQueueError.failed(message))
                }
            }
        }
    }

    /// Cancels one command: skipped if still waiting, its process group
    /// stopped if running.
    public func cancel(_ id: UUID) {
        let task: Task<Int32, Error>? = state.withLockUnchecked { s in
            if s.pending.contains(id) { s.cancelled.insert(id) }
            return s.running?.id == id ? s.running?.task : nil
        }
        task?.cancel()
    }

    public func cancel(_ ids: some Sequence<UUID>) {
        for id in ids { cancel(id) }
    }

    /// Ids waiting to run, in order (not including the running one).
    public var pendingIDs: [UUID] { state.withLockUnchecked { $0.pending } }
    public var runningID: UUID? { state.withLockUnchecked { $0.running?.id } }

    private static func execute(_ job: Job, runner: StreamingCommandRunning, state: OSAllocatedUnfairLock<State>) async {
        let handler = job.handler
        let command = job.command
        // Decide skip-or-start under one lock, so a cancel can't fall
        // between the check and the task being registered as running.
        let task: Task<Int32, Error>? = state.withLockUnchecked { s in
            s.pending.removeAll { $0 == job.id }
            if s.cancelled.remove(job.id) != nil { return nil }
            let t = Task<Int32, Error> {
                // Sent from inside the task so it always precedes any output.
                handler(.started)
                return try await runner.stream(command.executable, command.arguments, environment: command.environment) { data in
                    handler(.output(data))
                }
            }
            s.running = (job.id, t)
            return t
        }
        guard let task else {
            handler(.cancelled)
            return
        }
        let result = await task.result
        state.withLockUnchecked { $0.running = nil }
        switch result {
        case .success(let code):
            handler(task.isCancelled ? .cancelled : .finished(exitCode: code))
        case .failure(let error):
            if task.isCancelled || error is CancellationError || (error as? ProcessRunnerError).map({ if case .cancelled = $0 { true } else { false } }) == true {
                handler(.cancelled)
            } else {
                handler(.failed(String(describing: error)))
            }
        }
    }
}

public enum CommandQueueError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self {
        case .failed(let m): return m
        }
    }
}
