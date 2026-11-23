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
    /// 0.8: not run because its skip check, made right before it would
    /// start, said so (the reason). Not a failure: a chain goes on.
    case skipped(String)
    /// 0.8.3: the command failed on brew's lock (another brew holds it) and
    /// waits for it (the holder, "pid command", or "" when not known); nil:
    /// the lock is free and the command runs again (its output starts over).
    case lockWait(String?)
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
    /// 0.6: sees every command's events (History), before its handler.
    public typealias Observer = @Sendable (UUID, QueuedCommand, CommandEvent) -> Void

    /// 0.7: checked right before a command would start; a non-nil result
    /// is why it must not run (it ends as `.failed` with that message).
    public typealias Precondition = @Sendable () -> String?
    /// 0.8: checked right before a command would start, after everything
    /// before it finished; a non-nil result skips it (`.skipped`, with
    /// that reason). For checks that read brew again (they may take a while).
    public typealias SkipCheck = @Sendable () async -> String?

    struct Job: Sendable {
        var id: UUID
        var command: QueuedCommand
        var precondition: Precondition?
        var skipCheck: SkipCheck?
        var lockWait: BrewLockWait?
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
    private let observer: Observer?

    public init(runner: StreamingCommandRunning, observer: Observer? = nil) {
        self.observer = observer
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
    public func enqueue(_ command: QueuedCommand, id: UUID = UUID(), precondition: Precondition? = nil,
                        skipCheck: SkipCheck? = nil, lockWait: BrewLockWait? = nil,
                        handler: @escaping Handler) -> UUID {
        var handler = handler
        if let observer {
            let inner = handler
            handler = { event in
                observer(id, command, event)
                inner(event)
            }
        }
        // Append and yield under the lock, so the stream order is exactly
        // the order of enqueue calls even from different threads.
        state.withLockUnchecked { s in
            s.pending.append(id)
            continuation.yield(Job(id: id, command: command, precondition: precondition, skipCheck: skipCheck,
                                   lockWait: lockWait, handler: handler))
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
                case .skipped: cont.resume(throwing: ProcessRunnerError.cancelled)
                case .lockWait: break
                }
            }
        }
    }

    /// Cancels one command: skipped if still waiting, its process group
    /// stopped if running. 0.8.6: also when it hasn't been enqueued yet: a
    /// chain's first step can fail (a precondition refusal is instant)
    /// while its later steps are still being enqueued, and that cancel
    /// must still skip them. An id that never arrives costs one set entry.
    public func cancel(_ id: UUID) {
        let task: Task<Int32, Error>? = state.withLockUnchecked { s in
            if s.running?.id != id { s.cancelled.insert(id) }
            return s.running?.id == id ? s.running?.task : nil
        }
        task?.cancel()
    }

    public func cancel(_ ids: some Sequence<UUID>) {
        for id in ids { cancel(id) }
    }

    /// 0.9.2: skips a command that hasn't started; one the queue is
    /// running already runs to the end. For Stop After Current, whose
    /// "waiting" comes from the main actor's copy of the states: the queue
    /// may have started that command before its `.started` arrived there.
    public func cancelIfWaiting(_ ids: some Sequence<UUID>) {
        state.withLockUnchecked { s in
            for id in ids where s.running?.id != id { s.cancelled.insert(id) }
        }
    }

    /// Ids waiting to run, in order (not including the running one).
    public var pendingIDs: [UUID] { state.withLockUnchecked { $0.pending } }
    public var runningID: UUID? { state.withLockUnchecked { $0.running?.id } }

    private static func execute(_ job: Job, runner: StreamingCommandRunning, state: OSAllocatedUnfairLock<State>) async {
        let handler = job.handler
        let command = job.command
        // Checked now, when everything before it in the queue has finished
        // (outside the lock: it may touch the disk).
        let refusal = job.precondition?()
        // A skip check only for a job still meant to run (it may run brew).
        let skip: String?
        if refusal == nil, let check = job.skipCheck, !state.withLockUnchecked({ $0.cancelled.contains(job.id) }) {
            skip = await check()
        } else {
            skip = nil
        }
        // Decide skip-or-start under one lock, so a cancel can't fall
        // between the check and the task being registered as running.
        var refused = false
        var skipped = false
        let task: Task<Int32, Error>? = state.withLockUnchecked { s in
            s.pending.removeAll { $0 == job.id }
            if s.cancelled.remove(job.id) != nil { return nil }
            if refusal != nil {
                refused = true
                return nil
            }
            if skip != nil {
                skipped = true
                return nil
            }
            let lockWait = job.lockWait
            let t = Task<Int32, Error> {
                // Sent from inside the task so it always precedes any output.
                handler(.started)
                guard let lockWait else {
                    return try await runner.stream(command.executable, command.arguments, environment: command.environment) { data in
                        handler(.output(data))
                    }
                }
                return try await Self.runWaitingForLock(command, runner: runner, wait: lockWait, handler: handler)
            }
            s.running = (job.id, t)
            return t
        }
        guard let task else {
            if refused, let refusal {
                handler(.failed(refusal))
            } else if skipped, let skip {
                handler(.skipped(skip))
            } else {
                handler(.cancelled)
            }
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

extension CommandQueue {
    /// 0.8.3: runs `command`; while it fails on brew's lock, waits for the
    /// lock to be free (cancellable: the wait is the running task's) and
    /// runs it again. The last run's exit code.
    static func runWaitingForLock(_ command: QueuedCommand, runner: StreamingCommandRunning, wait: BrewLockWait,
                                  handler: @escaping Handler) async throws -> Int32 {
        let start = ContinuousClock.now
        let prefix = BrewLock.prefix(ofBrew: command.executable)
        var attempts = 0
        while true {
            let tail = OutputTail()
            let code = try await runner.stream(command.executable, command.arguments, environment: command.environment) { data in
                tail.add(data)
                handler(.output(data))
            }
            guard code != 0, attempts < wait.maxAttempts else { return code }
            let lines = tail.lines
            guard BrewFailure.classify(lines) == .locked else { return code }
            attempts += 1
            let free = try await wait.waitUntilFree(BrewLock.lockFile(lines, prefix: prefix), since: start) { holder in
                handler(.lockWait(holder))
            }
            guard free else { return code }
            try Task.checkCancellation()
            handler(.lockWait(nil))
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
