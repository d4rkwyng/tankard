import Foundation
import Observation
import os
import TankardCore

// v0.6 (part A): History. Every command that goes through the queue
// (install, upgrade, uninstall, reinstall, pin, services, cleanup,
// autoremove, brew update, and auto-update's runs) is recorded by the
// queue's observer: when, the command, the result and how long it took.
// Kept in Application Support as JSON, newest first, the last 500, in the
// same format as the Auto-update log (StatusReport's encoder, ISO dates).

/// One command Tankard ran.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled
        /// 0.8.6 (M3): exit 0, but brew had nothing to do ("already
        /// installed": another brew did it, e.g. in Terminal).
        case noChange
        /// brew couldn't be started at all.
        case notStarted
        /// 0.8.5: a value this build doesn't know (written by a newer
        /// Tankard, or edited by hand). Shown as "result unknown".
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .unknown
        }
    }

    public enum Origin: String, Codable, Sendable {
        case user, autoUpdate

        /// 0.8.5: an origin this build doesn't know reads as the user's.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Origin(rawValue: raw) ?? .user
        }
    }

    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    /// What the user sees and can copy (`QueuedCommand.display`).
    public var command: String
    /// brew's arguments, for Retry (the environment is rebuilt then).
    public var arguments: [String]
    public var outcome: Outcome
    public var exitCode: Int32?
    public var origin: Origin
    /// A recognised failure (`BrewFailureKind.rawValue`).
    public var failure: String?
    /// brew's last lines, for a failed command.
    public var outputTail: [String]
    /// 0.8.5: a scheduled check that couldn't finish for a reason that
    /// means "try later" (offline, brew busy, slept, timed out): shown as
    /// one quiet line, not a failure. Optional, so older files still load.
    public var quietReason: ScheduledQuietReason?
    /// 0.8.5: how many scheduled checks this quiet line stands for, and
    /// when the first of them was (nil: one).
    public var quietCount: Int?
    public var quietSince: Date?
    /// 0.8.5: this step built the formula from source (the plan said so
    /// and brew poured no bottle). The next build's estimate reads it.
    public var builtFromSource: Bool?
    /// 0.8.6 (VM test M1): brew exited non-zero (`exitCode`), but the
    /// package was upgraded: a later part of the command failed.
    public var upgradedDespiteExit: Bool?
    /// 0.8.6 (HK-47 review): and brew's error named another package.
    public var exitOverAnotherPackage: Bool?
    /// 0.8.8 (final gauntlet): brew found it already installed because an
    /// earlier step of the same Upgrade All upgraded it (as a dependency
    /// or dependent); the value is that step's package
    /// (UpgradeSession.doneByEarlierStep).
    public var upgradedEarlierBy: String?

    public init(id: UUID = UUID(), startedAt: Date, duration: TimeInterval, command: String, arguments: [String],
                outcome: Outcome, exitCode: Int32? = nil, origin: Origin = .user, failure: String? = nil,
                outputTail: [String] = []) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.command = command
        self.arguments = arguments
        self.outcome = outcome
        self.exitCode = exitCode
        self.origin = origin
        self.failure = failure
        self.outputTail = outputTail
    }

    enum CodingKeys: String, CodingKey {
        case id, startedAt, duration, command, arguments, outcome, exitCode, origin, failure, outputTail
        case quietReason, quietCount, quietSince, builtFromSource, upgradedDespiteExit, exitOverAnotherPackage
        case upgradedEarlierBy
    }

    /// 0.8.5 (M2): the fields this entry can't do without must be there;
    /// the rest are read leniently, so a value this build doesn't know
    /// doesn't cost the entry (and an entry never costs the file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = (try? c.decode(TimeInterval.self, forKey: .duration)) ?? 0
        command = try c.decode(String.self, forKey: .command)
        arguments = (try? c.decode([String].self, forKey: .arguments)) ?? []
        outcome = (try? c.decode(Outcome.self, forKey: .outcome)) ?? .unknown
        exitCode = try? c.decodeIfPresent(Int32.self, forKey: .exitCode)
        origin = (try? c.decode(Origin.self, forKey: .origin)) ?? .user
        failure = try? c.decodeIfPresent(String.self, forKey: .failure)
        outputTail = (try? c.decode([String].self, forKey: .outputTail)) ?? []
        quietReason = try? c.decodeIfPresent(ScheduledQuietReason.self, forKey: .quietReason)
        quietCount = try? c.decodeIfPresent(Int.self, forKey: .quietCount)
        quietSince = try? c.decodeIfPresent(Date.self, forKey: .quietSince)
        builtFromSource = try? c.decodeIfPresent(Bool.self, forKey: .builtFromSource)
        upgradedDespiteExit = try? c.decodeIfPresent(Bool.self, forKey: .upgradedDespiteExit)
        exitOverAnotherPackage = try? c.decodeIfPresent(Bool.self, forKey: .exitOverAnotherPackage)
        upgradedEarlierBy = try? c.decodeIfPresent(String.self, forKey: .upgradedEarlierBy)
    }

    public var category: HistoryCategory { HistoryCategory(arguments: arguments) }
    public var failureKind: BrewFailureKind? { failure.flatMap(BrewFailureKind.init(rawValue:)) }
    public var isFailure: Bool { quietReason == nil && (outcome == .failed || outcome == .notStarted) }

    /// Retry runs the same brew arguments again, through the queue.
    /// Retry is offered only where it goes back through the normal gated
    /// path (0.6 review): upgrade re-enters requestUpgrade (compile warning,
    /// pin/held rule, skip-this-version), and pin, services and update are
    /// re-run as is. Uninstall, clean up, autoremove, install and reinstall
    /// are never one click: they show `rerunHint` instead.
    public var canRetry: Bool {
        guard isFailure, !arguments.isEmpty else { return false }
        switch category {
        case .upgrade, .pin, .services, .update: return true
        default: return false
        }
    }

    /// Where to run a failed entry again when Retry isn't offered.
    public var rerunHint: String? {
        guard isFailure, !canRetry else { return nil }
        // 0.8.1: macOS blocked it: allow, relaunch, then run it again.
        if failureKind == .appManagement {
            return String(localized: "Allow Tankard in Privacy & Security → App Management and relaunch Tankard, then run it again.")
        }
        // 0.8: brew install --cask --adopt.
        if arguments.contains("--adopt") { return String(localized: "Adopt it again from Homebrew ▸ Adopt Apps…; it asks first.") }
        switch category {
        case .uninstall: return String(localized: "Uninstall again from the package's details; it asks first.")
        case .cleanup: return String(localized: "Run it again from the menu (Clean Up… or Remove Unused Dependencies…); it shows what it removes first.")
        case .install, .reinstall: return String(localized: "Install again from Discover or the package's details.")
        case .taps: return String(localized: "Run it again from Homebrew ▸ Taps…; it asks first.")
        default: return nil
        }
    }

    /// "succeeded", "failed (exit 1)", "stopped", "didn't start".
    public var resultText: String {
        if let quietReason {
            guard let n = quietCount, n > 1 else { return quietReason.text }
            return quietReason.text + " " + String(localized: "(\(n) times)")
        }
        if outcome == .succeeded, upgradedDespiteExit == true, let code = exitCode {
            return exitOverAnotherPackage == true
                ? String(localized: "upgraded (brew then exited \(code) over another package)")
                : String(localized: "upgraded (brew then exited \(code))")
        }
        // 0.8.8: as the run's log says ("Already upgraded by this run").
        if outcome == .noChange, upgradedEarlierBy != nil { return String(localized: "upgraded earlier in this run") }
        switch outcome {
        case .succeeded: return String(localized: "succeeded")
        case .noChange: return String(localized: "no change (already up to date)")
        case .failed: return exitCode.map { code in String(localized: "failed (exit \(code))") } ?? String(localized: "failed")
        case .cancelled: return String(localized: "stopped")
        case .notStarted: return String(localized: "didn't start")
        case .unknown: return String(localized: "result unknown")
        }
    }

    /// "0.4 s", "12 s", "3 min 5 s".
    public var durationText: String {
        if duration < 10 { return String(localized: "\(String(format: "%.1f", max(0, duration))) s") }
        let s = Int(duration.rounded())
        return s < 60 ? String(localized: "\(s) s") : String(localized: "\(s / 60) min \(s % 60) s")
    }
}

/// What a History entry did, from brew's first argument. The History
/// view's filter.
public enum HistoryCategory: String, CaseIterable, Identifiable, Sendable {
    case install, upgrade, uninstall, reinstall, pin, services, cleanup, update, other
    /// 0.7: tap, untap, trust, untrust.
    case taps
    public var id: String { rawValue }

    public init(arguments: [String]) {
        switch arguments.first {
        case "install": self = .install
        case "upgrade": self = .upgrade
        case "uninstall": self = .uninstall
        case "reinstall": self = .reinstall
        case "pin", "unpin": self = .pin
        case "services": self = .services
        case "cleanup", "autoremove": self = .cleanup
        case "update": self = .update
        case "tap", "untap", "trust", "untrust": self = .taps
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .install: return String(localized: "Install")
        case .upgrade: return String(localized: "Upgrade")
        case .uninstall: return String(localized: "Uninstall")
        case .reinstall: return String(localized: "Reinstall")
        case .pin: return String(localized: "Pin")
        case .services: return String(localized: "Services")
        case .cleanup: return String(localized: "Clean up")
        case .update: return String(localized: "Update")
        case .other: return String(localized: "Other")
        case .taps: return String(localized: "Taps")
        }
    }
}

/// The History view's filter.
public enum HistoryFilter: Hashable, Sendable, Identifiable {
    case all, failed, autoUpdate
    case category(HistoryCategory)

    public var id: String {
        switch self {
        case .all: return "all"
        case .failed: return "failed"
        case .autoUpdate: return "auto"
        case .category(let c): return c.rawValue
        }
    }

    public var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .failed: return String(localized: "Failed")
        case .autoUpdate: return String(localized: "Auto-update")
        case .category(let c): return c.title
        }
    }

    public static let menu: [HistoryFilter] = [.all, .failed, .autoUpdate]
        + [HistoryCategory.install, .upgrade, .uninstall, .reinstall, .pin, .services, .cleanup, .update, .taps].map { .category($0) }

    public func includes(_ e: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .failed: return e.isFailure
        case .autoUpdate: return e.origin == .autoUpdate
        case .category(let c): return e.category == c
        }
    }
}

/// The persistent list. `url` nil: memory only (tests, demo).
@Observable @MainActor
public final class HistoryLog {
    public nonisolated static let maxEntries = 500

    public private(set) var entries: [HistoryEntry]
    @ObservationIgnored public let url: URL?

    public nonisolated static var defaultURL: URL {
        AutoUpdateLog.defaultURL.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    public init(url: URL?) {
        self.url = url
        entries = url.flatMap(Self.load) ?? []
    }

    public func record(_ e: HistoryEntry) {
        var list = entries.filter { $0.id != e.id }
        list.insert(e, at: 0)
        list.sort { $0.startedAt > $1.startedAt }
        entries = Array(list.prefix(Self.maxEntries))
        save()
    }

    /// Demo: show these without saving.
    public func seed(_ list: [HistoryEntry]) {
        entries = Array(list.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxEntries))
    }

    /// 0.8.5: `entry` in place of the entries `ids` (markQuiet).
    func replace(removing ids: [UUID], with entry: HistoryEntry) {
        var list = entries.filter { !ids.contains($0.id) }
        list.append(entry)
        list.sort { $0.startedAt > $1.startedAt }
        entries = Array(list.prefix(Self.maxEntries))
        save()
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        save()
    }

    public func filtered(_ f: HistoryFilter, search: String = "") -> [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { f.includes($0) && (q.isEmpty || $0.command.lowercased().contains(q)) }
    }

    nonisolated static func load(_ url: URL) -> [HistoryEntry]? {
        SafeJSONList.load(HistoryEntry.self, from: url).map { Array($0.prefix(maxEntries)) }
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? StatusReport.jsonEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

/// 0.8.5 (bug hunt M2): History's and the Auto-update log's files, read
/// entry by entry. One entry Tankard can't read used to make the whole list
/// load as empty, and the next write then replaced the file (5,000 entries
/// became 2). Now an entry it can't read is skipped; the file as it was is
/// copied aside (`<name>.unreadable-<date>`) before anything is written over
/// it, and a file it can't read at all is moved aside and the list starts
/// empty.
enum SafeJSONList {
    /// Reads any one element, so the list can step past one it can't decode.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct Lossy<T: Decodable>: Decodable {
        var items: [T] = []
        var dropped = 0
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            while !c.isAtEnd {
                if let v = try? c.decode(T.self) {
                    items.append(v)
                    continue
                }
                dropped += 1
                // A failed decode doesn't move the container on.
                if (try? c.decode(Skip.self)) == nil {
                    dropped += max(0, (c.count ?? c.currentIndex) - c.currentIndex - 1)
                    break
                }
            }
        }
    }

    /// nil: no file. Otherwise the entries it could read.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, now: Date = Date()) -> [T]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let list = try? StatusReport.jsonDecoder().decode(Lossy<T>.self, from: data) else {
            setAside(url, now: now, move: true)
            return []
        }
        if list.dropped > 0 { setAside(url, now: now, move: false) }
        return list.items
    }

    /// `history.json.unreadable-20261118-142501`, beside the file.
    static func asideURL(for url: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var candidate = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + f.string(from: now))
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".unreadable-" + f.string(from: now) + "-\(n)")
            n += 1
        }
        return candidate
    }

    private static func setAside(_ url: URL, now: Date, move: Bool) {
        let dest = asideURL(for: url, now: now)
        let fm = FileManager.default
        if move {
            if (try? fm.moveItem(at: url, to: dest)) == nil {
                // Couldn't move it: at least don't lose it when it's replaced.
                try? fm.copyItem(at: url, to: dest)
            }
        } else {
            try? fm.copyItem(at: url, to: dest)
        }
    }
}

/// The queue's observer: follows each command from start to end on the
/// queue's threads and hands the finished entry to the main actor.
public final class HistoryRecorder: @unchecked Sendable {
    struct Running {
        var command: QueuedCommand
        var started: Date
        var output = Data()
    }

    /// Output kept per command for the failure tail (the end only).
    static let keepBytes = 16_384
    static let tailLines = 12

    private let lock = OSAllocatedUnfairLock(initialState: [UUID: Running]())
    private let sinkLock = OSAllocatedUnfairLock<(@MainActor @Sendable (HistoryEntry) -> Void)?>(initialState: nil)
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Where finished entries go (set once the store exists).
    public func setSink(_ sink: @escaping @MainActor @Sendable (HistoryEntry) -> Void) {
        sinkLock.withLock { $0 = sink }
    }

    public func observe(_ id: UUID, _ command: QueuedCommand, _ event: CommandEvent) {
        let now = clock()
        let finished: (Running, HistoryEntry.Outcome, Int32?)? = lock.withLock { map in
            switch event {
            case .started:
                map[id] = Running(command: command, started: now)
                return nil
            case .output(let d):
                guard var r = map[id] else { return nil }
                r.output.append(d)
                if r.output.count > Self.keepBytes { r.output = Data(r.output.suffix(Self.keepBytes)) }
                map[id] = r
                return nil
            case .finished(let code):
                let r = map.removeValue(forKey: id) ?? Running(command: command, started: now)
                return (r, code == 0 ? .succeeded : .failed, code)
            case .lockWait(let holder):
                // 0.8.3: running again once brew's lock is free: the entry
                // is about that run (its output, its result).
                if holder == nil, var r = map[id] {
                    r.output = Data()
                    map[id] = r
                }
                return nil
            case .skipped:
                // Never ran: not history (the session's log says why).
                map.removeValue(forKey: id)
                return nil
            case .cancelled:
                // A command cancelled before it started never ran: not history.
                guard let r = map.removeValue(forKey: id) else { return nil }
                return (r, .cancelled, nil)
            case .failed(let message):
                var r = map.removeValue(forKey: id) ?? Running(command: command, started: now)
                r.output.append(Data(String(localized: "Couldn't run brew: \(message)\n").utf8))
                return (r, .notStarted, nil)
            }
        }
        guard let (r, reported, code) = finished else { return }
        var assembler = LineAssembler()
        assembler.feed(r.output)
        assembler.finish()
        let lines = assembler.lines
        // 0.8: brew's "is pinned. You must unpin it to …" exits 0 but did nothing.
        var outcome: HistoryEntry.Outcome = reported == .succeeded && BrewRefusal.pinned(lines) ? .failed : reported
        // 0.8.6 (M3): an upgrade or install brew found already done.
        if outcome == .succeeded, ["upgrade", "install"].contains(r.command.arguments.first ?? ""),
           BrewRefusal.alreadyInstalled(lines) { outcome = .noChange }
        let failed = outcome == .failed || outcome == .notStarted
        let entry = HistoryEntry(id: id, startedAt: r.started, duration: now.timeIntervalSince(r.started),
                                 command: r.command.display, arguments: r.command.arguments, outcome: outcome,
                                 exitCode: code, failure: failed ? BrewFailure.classify(lines)?.rawValue : nil,
                                 outputTail: failed ? lines.suffix(Self.tailLines).map(ProxySettings.maskText) : [])
        guard let sink = sinkLock.withLock({ $0 }) else { return }
        Task { @MainActor in sink(entry) }
    }
}

public extension AppStore {
    /// A finished command from the queue: tagged with who started it, then kept.
    internal func historyRecorded(_ e: HistoryEntry) {
        var e = e
        if autoUpdate.isRunning { e.origin = .autoUpdate }
        history.record(e)
        // 0.8.5: a scheduled check that ended "try later" (it may finish
        // before this entry arrives from the queue's thread).
        if let reason = pendingQuiet.removeValue(forKey: e.id) { history.markQuiet(e.id, reason: reason) }
        if pendingBuilt.remove(e.id) != nil { history.markBuiltFromSource(e.id) }
        if let other = pendingUpgradedAnyway.removeValue(forKey: e.id) {
            history.markUpgradedAnyway(e.id, overAnotherPackage: other)
        }
        if let by = pendingUpgradedEarlier.removeValue(forKey: e.id) { history.markUpgradedEarlier(e.id, by: by) }
    }

    /// Runs a failed entry's brew arguments again through the queue (a
    /// fresh environment, as any action), then re-reads status.
    func retry(_ e: HistoryEntry) {
        guard e.canRetry else { return }
        let args = e.arguments
        if e.category == .upgrade {
            // Back through the Upgrade button's path: the compile plan, the
            // held rule and skip-this-version all apply again.
            let names = Set(args.filter { !$0.hasPrefix("-") }.dropFirst())
            let targets = packages.filter { p in
                names.contains(p.fullName) || names.contains(p.name)
                    || names.contains((p.tap.map { "\($0)/" } ?? "") + p.name)
            }
            if targets.isEmpty {
                error = StoreError(title: String(localized: "Nothing to retry"), detail: String(localized: "\(BrewCommands.display(args)) has nothing left to upgrade."))
                return
            }
            requestUpgrade(targets)
            return
        }
        Task {
            guard let r = await runQuick(args) else { return }
            await refresh(manual: false)
            if r.failed {
                error = Self.quickError(verb: String(localized: "Retry"), name: BrewCommands.display(args), args: args, result: r)
            }
        }
    }

    func openHistory() { toolSheet = .history }
}

public extension HistoryLog {
    /// 0.8.6 (VM test M1): the step upgraded its package although brew
    /// exited non-zero (UpgradeSession.upgradedAnyway). false: no such
    /// entry (yet).
    @discardableResult
    func markUpgradedAnyway(_ id: UUID, overAnotherPackage: Bool) -> Bool {
        guard var e = entries.first(where: { $0.id == id }) else { return false }
        e.outcome = .succeeded
        e.upgradedDespiteExit = true
        e.exitOverAnotherPackage = overAnotherPackage
        e.failure = nil
        replace(removing: [id], with: e)
        return true
    }

    /// 0.8.8 (final gauntlet): an Upgrade All step brew found already
    /// installed because the run's earlier step for `by` upgraded it.
    /// false: no such entry (yet).
    @discardableResult
    func markUpgradedEarlier(_ id: UUID, by: String) -> Bool {
        guard var e = entries.first(where: { $0.id == id }), e.outcome == .noChange else { return false }
        e.upgradedEarlierBy = by
        replace(removing: [id], with: e)
        return true
    }
}
