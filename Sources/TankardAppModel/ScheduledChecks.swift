import Foundation
import TankardCore

// 0.8.5: scheduled checks and sleep. A laptop closed overnight used to log a
// stack of red History failures: a background `brew update` that hung for
// 93 minutes on a dead network across sleep, then "Another Homebrew command
// is running" a moment later, and again an hour on. Now:
// - nothing scheduled starts while the Mac sleeps or is going to sleep, or
//   while macOS says there is no network (NWPathMonitor, wired by the app);
// - after a wake, or the network coming back, the checks wait a short
//   settle delay; whatever is due then runs once (the policies already
//   never run a missed slot twice);
// - a scheduled `brew update` has a time limit, and is stopped when the Mac
//   goes to sleep; its failures that mean "try later" (offline, brew busy,
//   slept, timed out) go to History as one quiet entry, not red failures.
// User-initiated runs are unchanged.

/// Why a scheduled check can't start now.
public enum ScheduleGate: Equatable, Sendable {
    case open
    case asleep
    case offline
    /// Just woke, or the network just came back: wait until then.
    case settling(until: Date)
}

/// The Mac's sleep and network state, as the app reports it (NSWorkspace's
/// willSleep/didWake, NWPathMonitor). Tests drive it directly. Until the
/// app reports anything it is awake and online, so nothing changes for
/// tests, demo mode and script runs.
@MainActor
public final class ScheduleConditions {
    /// How long after a wake (or the network coming back) scheduled checks wait.
    public nonisolated static let settleDelay: TimeInterval = 30
    /// How often a gated check looks again.
    public nonisolated static let gatedRetry: TimeInterval = 60

    public private(set) var isAsleep = false
    /// nil: not known (no monitor): treated as online.
    public private(set) var isOnline: Bool?
    /// The last wake, or the last time the network came back.
    public private(set) var settleFrom: Date?
    /// Bumped on every willSleep: a run that sees it change slept mid-run.
    public private(set) var sleepCount = 0
    /// Called on willSleep (the store stops a scheduled `brew update`).
    public var onWillSleep: (() -> Void)?

    public init() {}

    public func willSleep() {
        isAsleep = true
        sleepCount += 1
        onWillSleep?()
    }

    public func didWake(at now: Date) {
        isAsleep = false
        settleFrom = now
    }

    public func network(satisfied: Bool, at now: Date) {
        let was = isOnline
        isOnline = satisfied
        if satisfied, was == false { settleFrom = now }
    }

    public func gate(now: Date) -> ScheduleGate {
        if isAsleep { return .asleep }
        if isOnline == false { return .offline }
        if let from = settleFrom {
            let until = from.addingTimeInterval(Self.settleDelay)
            if until > now { return .settling(until: until) }
        }
        return .open
    }

    /// Seconds until a gated check should look again.
    public func retry(now: Date) -> TimeInterval {
        if case .settling(let until) = gate(now: now) { return max(1, until.timeIntervalSince(now)) }
        return Self.gatedRetry
    }
}

/// A scheduled check's failure that means "try again later", shown in
/// History as one quiet line instead of a red failure.
public enum ScheduledQuietReason: String, Codable, Sendable, CaseIterable {
    case offline
    case busy
    case slept
    case timedOut

    /// From what happened: the Mac slept during the run, the time limit
    /// stopped it, or brew's output (offline, lock).
    public static func classify(slept: Bool, timedOut: Bool, failure: BrewFailureKind?) -> ScheduledQuietReason? {
        if slept { return .slept }
        if timedOut { return .timedOut }
        switch failure {
        case .network?: return .offline
        case .locked?: return .busy
        default: return nil
        }
    }

    /// History's result column.
    public var text: String {
        switch self {
        case .offline: return String(localized: "Scheduled check didn't run: offline. Will retry.")
        case .busy: return String(localized: "Scheduled check didn't run: another Homebrew command was running. Will retry.")
        case .slept: return String(localized: "Scheduled check interrupted by sleep. Will retry.")
        case .timedOut: return String(localized: "Scheduled check took too long and was stopped. Will retry.")
        }
    }

    /// How soon a background update tries again after this (the usual
    /// failure retry is an hour).
    public var retryAfter: TimeInterval {
        switch self {
        case .busy: return 10 * 60
        case .slept: return 0 // the wake's settle delay is the wait
        case .offline, .timedOut: return BackgroundUpdatePolicy.failureRetry
        }
    }
}

/// How a scheduled `brew update` went.
public struct ScheduledUpdateResult: Sendable {
    public var error: StoreError?
    public var quiet: ScheduledQuietReason?
    public init(error: StoreError? = nil, quiet: ScheduledQuietReason? = nil) {
        self.error = error
        self.quiet = quiet
    }
    public var succeeded: Bool { error == nil && quiet == nil }
}

public extension HistoryLog {
    /// Turns the entry `id` into a quiet scheduled-check line, merged with
    /// the last `brew update` entry when that one is quiet too (any reason):
    /// a night offline is one line ("3 times since 7:18 PM"), not a stack.
    /// false: no such entry (yet).
    @discardableResult
    func markQuiet(_ id: UUID, reason: ScheduledQuietReason) -> Bool {
        guard let e = entries.first(where: { $0.id == id }) else { return false }
        var merged = e
        merged.quietReason = reason
        let previous = entries.first { $0.id != id && $0.category == e.category && $0.startedAt <= e.startedAt }
        if let previous, previous.quietReason != nil, previous.command == e.command {
            merged.id = previous.id
            merged.quietCount = (previous.quietCount ?? 1) + 1
            merged.quietSince = previous.quietSince ?? previous.startedAt
            replace(removing: [id, previous.id], with: merged)
        } else {
            replace(removing: [id], with: merged)
        }
        return true
    }
}

/// The scheduled run's time limit, from the queue's thread.
final class ScheduledRunFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var _timedOut = false
    private var timer: Task<Void, Never>?

    /// Starts the limit (when brew starts, not while it waits in the queue).
    /// 0.8.5 (HK-47 review): on the suspending clock, which stops while the
    /// Mac sleeps: a night asleep mid-step no longer uses up the limit and
    /// stops a nearly finished brew on the wake.
    func startTimer(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        let t = Task {
            try? await Task.sleep(for: .seconds(seconds), tolerance: nil, clock: .suspending)
            guard !Task.isCancelled, self.markTimedOut() else { return }
            onTimeout()
        }
        lock.withLock { timer = t }
    }

    private func markTimedOut() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            _timedOut = true
            return true
        }
    }

    func finish() {
        let t: Task<Void, Never>? = lock.withLock {
            finished = true
            return timer
        }
        t?.cancel()
    }

    var timedOut: Bool { lock.withLock { _timedOut } }
}

extension AppStore {
    /// A scheduled `brew update` through the queue: stopped after
    /// `deps.scheduledUpdateTimeout` (the queue's stop: SIGINT to brew's
    /// process group, then SIGTERM, then SIGKILL, each after a grace
    /// period) or when the Mac goes to sleep. A failure that means "try
    /// later" comes back as `quiet` and marks its History entry quiet.
    func runScheduledUpdate(_ client: BrewClient) async -> ScheduledUpdateResult {
        let cmd = await updateCommand(client)
        let id = UUID()
        let sleeps = system.sleepCount
        let flags = ScheduledRunFlags()
        let collector = OutputCollector()
        let timeout = deps.scheduledUpdateTimeout
        let queue = self.queue
        scheduledUpdateCommand = id
        defer { if scheduledUpdateCommand == id { scheduledUpdateCommand = nil } }
        let event: CommandEvent = await withCheckedContinuation { cont in
            queue.enqueue(cmd, id: id) { event in
                switch event {
                case .started: flags.startTimer(timeout) { queue.cancel(id) }
                case .output(let d): collector.add(d)
                case .lockWait: break
                case .finished, .cancelled, .failed, .skipped:
                    flags.finish()
                    cont.resume(returning: event)
                }
            }
        }
        let lines = collector.lines()
        let slept = system.sleepCount != sleeps
        switch event {
        case .finished(let code):
            if code == 0 {
                settings.lastBrewUpdate = deps.now()
                return ScheduledUpdateResult()
            }
            if let q = ScheduledQuietReason.classify(slept: slept, timedOut: false, failure: BrewFailure.classify(lines)) {
                return quietUpdate(id, q)
            }
            return ScheduledUpdateResult(error: Self.updateError(code: code, lines: lines, display: cmd.display))
        case .cancelled, .skipped:
            if flags.timedOut { return quietUpdate(id, .timedOut) }
            if slept { return quietUpdate(id, .slept) }
            return ScheduledUpdateResult(error: StoreError(title: String(localized: "brew update didn't run"),
                                                           detail: String(localized: "It was stopped.")))
        case .failed(let message):
            return ScheduledUpdateResult(error: StoreError(title: String(localized: "brew update didn't run"), detail: message))
        default:
            return ScheduledUpdateResult(error: StoreError(title: String(localized: "brew update didn't run"), detail: ""))
        }
    }

    private func quietUpdate(_ id: UUID, _ reason: ScheduledQuietReason) -> ScheduledUpdateResult {
        if !history.markQuiet(id, reason: reason) { pendingQuiet[id] = reason }
        return ScheduledUpdateResult(quiet: reason)
    }

    /// The Mac is going to sleep: a scheduled `brew update` would only hang
    /// on a dead network until long after the wake. Stop it now.
    func stopScheduledUpdate() {
        if let id = scheduledUpdateCommand { queue.cancel(id) }
    }
}
