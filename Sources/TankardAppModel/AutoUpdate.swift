import Foundation
import Observation
import TankardCore

// v0.5: automatic package updates. Opt-in (off by default), on a daily or
// weekly schedule, only while Tankard runs, only on AC power and while the
// Mac is idle, and always in safe mode: bottles only, nothing pinned, no
// running app quit, Tankard itself left to brew. It runs from the same
// timer as the v0.3 update notifications (BackgroundChecker), never from a
// helper or launch agent.

// MARK: schedule

public enum AutoUpdateFrequency: String, CaseIterable, Identifiable, Sendable, Codable {
    case daily, weekly
    public var id: String { rawValue }
    public var title: String { self == .daily ? "Every day" : "Every week" }
}

/// The user's chosen slot: a time of day, and for weekly a weekday.
public struct AutoUpdateSchedule: Equatable, Sendable {
    public var frequency: AutoUpdateFrequency
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    public var weekday: Int

    public init(frequency: AutoUpdateFrequency = .daily, hour: Int = 3, minute: Int = 0, weekday: Int = 1) {
        self.frequency = frequency
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
    }

    /// The slot on the day of `day` (at hour:minute), or nil if the day
    /// doesn't match a weekly schedule's weekday.
    private func slot(onDayOf day: Date, calendar: Calendar) -> Date? {
        if frequency == .weekly, calendar.component(.weekday, from: day) != weekday { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// The most recent slot at or before `now`.
    public func latestSlot(atOrBefore now: Date, calendar: Calendar = .current) -> Date {
        for back in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now),
                  let s = slot(onDayOf: day, calendar: calendar), s <= now else { continue }
            return s
        }
        return now.addingTimeInterval(-8 * 86400)
    }

    /// The first slot strictly after `date`.
    public func nextSlot(after date: Date, calendar: Calendar = .current) -> Date {
        for ahead in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: date),
                  let s = slot(onDayOf: day, calendar: calendar), s > date else { continue }
            return s
        }
        return date.addingTimeInterval(8 * 86400)
    }

    /// "Every day at 03:00", "Every Sunday at 03:00".
    public func text(calendar: Calendar = .current) -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        if frequency == .daily { return "Every day at \(time)" }
        let names = calendar.weekdaySymbols
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : "Sunday"
        return "Every \(name) at \(time)"
    }
}

// MARK: conditions (power, idle, running apps)

/// An app that is running now (NSWorkspace in the app; a fake in tests).
public struct RunningApp: Equatable, Sendable {
    public var path: String?
    public var bundleID: String?
    public init(path: String?, bundleID: String?) {
        self.path = path
        self.bundleID = bundleID
    }
}

/// What auto-update asks the Mac before it runs. The app uses IOKit
/// (power source, HIDIdleTime) and NSWorkspace; tests inject fakes.
@MainActor
public protocol AutoUpdateConditions: AnyObject {
    /// true on AC power, false on battery or UPS, nil when unknown
    /// (treated as "not on AC": auto-update waits).
    func onACPower() -> Bool?
    /// Seconds since the last keyboard or mouse input; nil when unknown
    /// (treated as "not idle").
    func idleSeconds() -> TimeInterval?
    func runningApps() -> [RunningApp]
}

/// The default when nothing real is wired in (tests, demo): never on AC,
/// so nothing ever runs by accident.
@MainActor
public final class NeverConditions: AutoUpdateConditions {
    public init() {}
    public func onACPower() -> Bool? { nil }
    public func idleSeconds() -> TimeInterval? { nil }
    public func runningApps() -> [RunningApp] { [] }
}

/// Fixed answers (demo mode and tests).
@MainActor
public final class FixedConditions: AutoUpdateConditions {
    public var ac: Bool?
    public var idle: TimeInterval?
    public var apps: [RunningApp]
    public init(ac: Bool?, idle: TimeInterval?, apps: [RunningApp] = []) {
        self.ac = ac
        self.idle = idle
        self.apps = apps
    }
    public func onACPower() -> Bool? { ac }
    public func idleSeconds() -> TimeInterval? { idle }
    public func runningApps() -> [RunningApp] { apps }
}

// MARK: the decision

public enum AutoUpdateDecision: Equatable, Sendable {
    public enum Wait: Equatable, Sendable {
        /// Tankard just launched: let the window's own reads finish.
        case startup
        /// An upgrade, refresh or other brew command is running.
        case busy
        case onBattery
        case notIdle
    }

    case off
    /// 0.6: snoozed until this time (nil: until turned back on).
    case snoozed(until: Date?)
    /// This slot already ran (or the schedule started after it).
    case notDue(next: Date)
    /// Due, but a condition isn't met; look again after `retry` seconds.
    case waiting(Wait, retry: TimeInterval)
    /// Run now, for the slot at this time.
    case run(slot: Date)
}

public enum AutoUpdatePolicy {
    /// Idle for at least this long (no keyboard or mouse input).
    public static let idleThreshold: TimeInterval = 10 * 60
    /// Nothing runs sooner than this after launch.
    public static let startupDelay: TimeInterval = 5 * 60
    /// How often a due run that waits on power, idle or a busy queue looks again.
    public static let recheck: TimeInterval = 60

    /// Whether to run now. Pure: every input is passed in.
    ///
    /// - The slot is the schedule's most recent time at or before `now`.
    /// - A slot runs once: not when `lastRun` (the last run's start) is at
    ///   or after it, and not when the schedule was set (`since`) after it.
    /// - A slot missed while the Mac slept or Tankard wasn't running still
    ///   runs, as soon as the conditions allow, until the next slot
    ///   replaces it (it never runs twice to catch up).
    public static func decide(enabled: Bool, schedule: AutoUpdateSchedule, since: Date?, lastRun: Date?,
                              launchedAt: Date, now: Date, onAC: Bool?, idle: TimeInterval?, busy: Bool,
                              snoozed: Bool = false, snoozeEnds: Date? = nil,
                              calendar: Calendar = .current) -> AutoUpdateDecision {
        guard enabled else { return .off }
        if snoozed { return .snoozed(until: snoozeEnds) }
        let slot = schedule.latestSlot(atOrBefore: now, calendar: calendar)
        if let since, slot <= since { return .notDue(next: schedule.nextSlot(after: max(now, since), calendar: calendar)) }
        if let lastRun, slot <= lastRun { return .notDue(next: schedule.nextSlot(after: max(now, lastRun), calendar: calendar)) }
        let earliest = launchedAt.addingTimeInterval(startupDelay)
        if now < earliest { return .waiting(.startup, retry: earliest.timeIntervalSince(now)) }
        if busy { return .waiting(.busy, retry: recheck) }
        guard onAC == true else { return .waiting(.onBattery, retry: recheck) }
        guard let idle, idle >= idleThreshold else {
            return .waiting(.notIdle, retry: max(recheck / 2, idleThreshold - (idle ?? 0)))
        }
        return .run(slot: slot)
    }
}

// MARK: safe mode

/// Why safe mode leaves a package out.
public enum AutoUpdateSkip: Equatable, Sendable, Codable {
    case pinned
    /// No bottle: the upgrade would compile.
    case compiles
    /// A dependency it would upgrade too has no bottle.
    case dependencyCompiles(String)
    /// A dependency it needs is pinned and has an upgrade waiting.
    case dependencyPinned(String)
    /// brew's installed-dependents check would go on to upgrade (or
    /// rebuild) this dependent, and it has no bottle.
    case dependentCompiles(package: String, dependent: String)
    /// The cask's app is running (and "Don't quit running apps" is off).
    case appRunning(String)
    /// A cask whose apps brew didn't list, with "Don't quit running apps" off.
    case appUnknown
    /// Tankard's own cask: that update stays with brew.
    case tankardItself
    /// 0.6: the user skipped exactly this version.
    case versionSkipped(String)
    /// 0.6: the bump rule leaves it out ("major", or "unknown" when the
    /// versions can't be compared).
    case bumpRule(from: String, to: String, bump: String)

    public var text: String {
        switch self {
        case .pinned: return "pinned"
        case .compiles: return "no bottle, would compile from source"
        case .dependencyCompiles(let d): return "its dependency \(d) would compile from source"
        case .dependencyPinned(let d): return "its dependency \(d) is pinned"
        case .dependentCompiles(let p, let d): return "upgrading \(p) would need \(d) rebuilt from source; upgrade by hand"
        case .appRunning(let a): return "\(a) is running"
        case .appUnknown: return "couldn't tell whether its app is running"
        case .tankardItself: return "Tankard updates itself through brew"
        case .versionSkipped(let v): return "you chose to skip \(v)"
        case .bumpRule(let a, let b, let bump):
            if bump == VersionBump.unknown.title {
                return "\(a) → \(b): versions can't be compared, so only \"All versions\" upgrades it; upgrade by hand"
            }
            return "\(a) → \(b): \(bump) version; upgrade by hand"
        }
    }
}

public struct AutoUpdatePlan: Equatable, Sendable {
    public var run: [Package]
    public var skipped: [(package: Package, reason: AutoUpdateSkip)]

    public static func == (a: Self, b: Self) -> Bool {
        a.run == b.run && a.skipped.map(\.package) == b.skipped.map(\.package) && a.skipped.map(\.reason) == b.skipped.map(\.reason)
    }
}

/// Safe mode: what an automatic run upgrades and what it leaves out. Pure.
public enum AutoUpdateSafeMode {
    /// Tankard's own cask token.
    public static let tankardCask = "tankard"

    public static func isTankard(_ p: Package) -> Bool {
        p.kind == .cask && (p.name == tankardCask || p.fullName.hasSuffix("/" + tankardCask))
    }

    /// The running app of a cask, by installed path or by the bundle id its
    /// uninstall stanza quits. The app's file name ("Cursor.app") as text.
    public static func runningApp(_ p: Package, running: [RunningApp]) -> String? {
        let paths = Set((p.appPaths ?? []).map { ($0 as NSString).standardizingPath })
        let ids = Set(p.quitBundleIDs ?? [])
        for app in running {
            if let path = app.path.map({ ($0 as NSString).standardizingPath }), paths.contains(path) {
                return (path as NSString).lastPathComponent
            }
            if let id = app.bundleID, ids.contains(id) {
                return app.path.map { ($0 as NSString).lastPathComponent } ?? id
            }
        }
        return nil
    }

    /// Every package with an upgrade waiting, split into run and skipped.
    /// Upgrade targets are what Upgrade all uses (`isUpgradeTarget`: not
    /// pinned; self-updating casks only when that setting lists them); a
    /// pinned upgrade shows in `skipped` so the log says why.
    ///
    /// `only` (the hidden `autoUpdateOnly` test hook): when set, only
    /// packages named in it are considered; the rest are out of scope (not
    /// run, not listed as skipped). The dependency checks still see every
    /// installed package.
    public static func plan(_ packages: [Package], classifier: CompileClassifier, running: [RunningApp],
                            dontQuitApps: Bool, only: Set<String>? = nil,
                            rules: UpgradeRuleSnapshot = UpgradeRuleSnapshot()) -> AutoUpdatePlan {
        let graph = DependencyGraph(packages)
        var run: [Package] = []
        var skipped: [(Package, AutoUpdateSkip)] = []
        let outdated = packages.filter { p in p.upgradeAvailable && (only?.contains(p.name) ?? true) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func compiles(_ p: Package) -> Bool { classifier.upgradeMethod(p).compiles }
        for p in outdated {
            if p.isHeld { skipped.append((p, .pinned)); continue }
            if isTankard(p) { skipped.append((p, .tankardItself)); continue }
            // 0.6: skip this version, then the bump rule.
            if let reason = rules.skipReason(p) { skipped.append((p, reason)); continue }
            if p.kind == .formula {
                if compiles(p) { skipped.append((p, .compiles)); continue }
                if let reason = dependencyProblem(p, graph: graph, compiles: compiles) { skipped.append((p, reason)); continue }
                if let d = dependentThatCompiles(p, graph: graph, compiles: compiles) {
                    skipped.append((p, .dependentCompiles(package: p.name, dependent: d.name))); continue
                }
            } else if !dontQuitApps {
                if p.appPaths == nil && p.quitBundleIDs == nil { skipped.append((p, .appUnknown)); continue }
                if let app = runningApp(p, running: running) { skipped.append((p, .appRunning(app))); continue }
            }
            guard p.isManualUpgradeTarget else { continue }
            run.append(p)
        }
        return AutoUpdatePlan(run: run, skipped: skipped.map { (package: $0.0, reason: $0.1) })
    }

    /// `brew upgrade <p>` also upgrades p's outdated dependencies (the
    /// receipt's list is already recursive). One that would compile, or one
    /// that is pinned, keeps p out.
    static func dependencyProblem(_ p: Package, graph: DependencyGraph, compiles: (Package) -> Bool) -> AutoUpdateSkip? {
        let deps = graph.dependencies(of: p).filter { $0.kind == .formula && $0.upgradeAvailable }
        if let d = deps.first(where: compiles) { return .dependencyCompiles(d.name) }
        if let d = deps.first(where: \.isHeld) { return .dependencyPinned(d.name) }
        return nil
    }

    /// After an upgrade, brew's installed-dependents check upgrades the
    /// outdated dependents of what it upgraded (and their dependencies,
    /// and so on; pinned ones are left alone). The first one in that chain
    /// that would compile, or nil. When there is one, safe mode skips p:
    /// turning brew's check off instead (HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK)
    /// could leave that dependent linked against the removed old keg's
    /// library after a library bump, breaking it overnight. p stays in the
    /// Upgrades list to upgrade by hand.
    static func dependentThatCompiles(_ p: Package, graph: DependencyGraph, compiles: (Package) -> Bool) -> Package? {
        var seen: Set<String> = [p.id]
        var queue = [p]
        while !queue.isEmpty {
            let x = queue.removeFirst()
            let deps = graph.dependencies(of: x).filter { $0.kind == .formula && $0.upgradeAvailable && !$0.isHeld }
            let dependents = graph.dependents(of: x).filter { $0.kind == .formula && $0.upgradeAvailable && !$0.isHeld }
            for y in deps + dependents where seen.insert(y.id).inserted {
                if compiles(y) { return y }
                queue.append(y)
            }
        }
        return nil
    }

    /// The environment for an automatic run's commands, on top of brew's
    /// usual one. Never asks (no TTY anyway), no auto-update (the run did
    /// `brew update` first), and never quits an app: casks always get
    /// HOMEBREW_NO_UPGRADE_QUIT_CASKS=1, so an app opened after the plan was
    /// made keeps running too.
    /// brew's installed-dependents check always stays on.
    public static func environment(for p: Package) -> [String: String] {
        var env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ASK": "1"]
        if p.kind == .cask { env[InsightSettings.noQuitKey] = "1" }
        return env
    }

    /// The lines Settings shows: exactly what safe mode does.
    public static let rules: [String] = [
        "Runs brew update first, then upgrades one package at a time through Tankard's queue.",
        "Bottles only: a formula with no bottle, or one whose upgrade would also upgrade a dependency that has none, is skipped. So is a formula whose upgrade would make brew upgrade or rebuild an installed dependent that has none: it stays in Upgrades to upgrade by hand.",
        "Pinned packages are skipped, and so are packages whose dependencies are pinned.",
        "Never quits an app: a cask whose app is running is skipped, unless \"Don't quit running apps\" is on (then it upgrades and the new version opens next time).",
        "Self-updating apps are included only when \"Include self-updating apps\" is on.",
        "Tankard itself is never upgraded automatically: use brew upgrade --cask tankard.",
    ]
}

// MARK: settings

/// v0.5 settings, in the same UserDefaults as `AppSettings`. Every
/// setting ignores a write of the value it already has (no notification,
/// no defaults write), as 0.3.1 did for showMenuBarIcon: a Toggle, Picker
/// or DatePicker that writes back an unchanged value must not invalidate
/// anything.
@Observable @MainActor
public final class AutoUpdateSettings {
    enum Key {
        static let enabled = "autoUpdateEnabled"
        static let frequency = "autoUpdateFrequency"
        static let hour = "autoUpdateHour"
        static let minute = "autoUpdateMinute"
        static let weekday = "autoUpdateWeekday"
        static let since = "autoUpdateScheduleSince"
        static let lastRun = "autoUpdateLastRun"
        static let dryRun = "autoUpdateDryRun"
        static let only = "autoUpdateOnly"
    }

    @ObservationIgnored public let defaults: UserDefaults
    @ObservationIgnored let now: @Sendable () -> Date

    /// Off by default.
    public var enabled: Bool {
        get { access(keyPath: \.enabled); return _enabled }
        set {
            guard newValue != _enabled else { return }
            withMutation(keyPath: \.enabled) { _enabled = newValue }
            defaults.set(newValue, forKey: Key.enabled)
            // Turning it on never runs a slot that has already passed.
            if newValue { since = now() }
        }
    }
    @ObservationIgnored private var _enabled: Bool

    public var frequency: AutoUpdateFrequency {
        get { access(keyPath: \.frequency); return _frequency }
        set {
            guard newValue != _frequency else { return }
            withMutation(keyPath: \.frequency) { _frequency = newValue }
            defaults.set(newValue.rawValue, forKey: Key.frequency)
            scheduleChanged()
        }
    }
    @ObservationIgnored private var _frequency: AutoUpdateFrequency

    /// 0–23. Default 3 (03:00).
    public var hour: Int {
        get { access(keyPath: \.hour); return _hour }
        set {
            let v = min(max(newValue, 0), 23)
            guard v != _hour else { return }
            withMutation(keyPath: \.hour) { _hour = v }
            defaults.set(v, forKey: Key.hour)
            scheduleChanged()
        }
    }
    @ObservationIgnored private var _hour: Int

    public var minute: Int {
        get { access(keyPath: \.minute); return _minute }
        set {
            let v = min(max(newValue, 0), 59)
            guard v != _minute else { return }
            withMutation(keyPath: \.minute) { _minute = v }
            defaults.set(v, forKey: Key.minute)
            scheduleChanged()
        }
    }
    @ObservationIgnored private var _minute: Int

    /// 1 = Sunday … 7 = Saturday. Default 1.
    public var weekday: Int {
        get { access(keyPath: \.weekday); return _weekday }
        set {
            let v = min(max(newValue, 1), 7)
            guard v != _weekday else { return }
            withMutation(keyPath: \.weekday) { _weekday = v }
            defaults.set(v, forKey: Key.weekday)
            scheduleChanged()
        }
    }
    @ObservationIgnored private var _weekday: Int

    /// When the current schedule took effect: slots before it never run.
    public var since: Date? {
        get { access(keyPath: \.since); return _since }
        set {
            guard newValue != _since else { return }
            withMutation(keyPath: \.since) { _since = newValue }
            defaults.set(newValue, forKey: Key.since)
        }
    }
    @ObservationIgnored private var _since: Date?

    /// When the last automatic run started (one run per slot).
    public var lastRun: Date? {
        get { access(keyPath: \.lastRun); return _lastRun }
        set {
            guard newValue != _lastRun else { return }
            withMutation(keyPath: \.lastRun) { _lastRun = newValue }
            defaults.set(newValue, forKey: Key.lastRun)
        }
    }
    @ObservationIgnored private var _lastRun: Date?

    /// Hidden test hook (`defaults write net.mindtricks.tankard
    /// autoUpdateDryRun -bool true`): a due run plans and logs what it would
    /// do, and runs no brew command at all, not even `brew update`.
    public var dryRun: Bool {
        get { access(keyPath: \.dryRun); return _dryRun }
        set {
            guard newValue != _dryRun else { return }
            withMutation(keyPath: \.dryRun) { _dryRun = newValue }
            defaults.set(newValue, forKey: Key.dryRun)
        }
    }
    @ObservationIgnored private var _dryRun: Bool

    /// Hidden test hook (`defaults write net.mindtricks.tankard
    /// autoUpdateOnly -array xz`): when set, a run considers only the
    /// formulae and casks named here; everything else is out of scope.
    /// Read at each run, no UI.
    public var only: Set<String>? {
        guard let names = defaults.array(forKey: Key.only) as? [String] else { return nil }
        return Set(names)
    }

    public var schedule: AutoUpdateSchedule {
        AutoUpdateSchedule(frequency: frequency, hour: hour, minute: minute, weekday: weekday)
    }

    private func scheduleChanged() {
        if _enabled { since = now() }
    }

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        _enabled = defaults.bool(forKey: Key.enabled)
        _frequency = AutoUpdateFrequency(rawValue: defaults.string(forKey: Key.frequency) ?? "") ?? .daily
        let s = AutoUpdateSchedule(frequency: .daily,
                                   hour: defaults.object(forKey: Key.hour) as? Int ?? 3,
                                   minute: defaults.integer(forKey: Key.minute),
                                   weekday: defaults.object(forKey: Key.weekday) as? Int ?? 1)
        _hour = s.hour
        _minute = s.minute
        _weekday = s.weekday
        _since = defaults.object(forKey: Key.since) as? Date
        _lastRun = defaults.object(forKey: Key.lastRun) as? Date
        _dryRun = defaults.bool(forKey: Key.dryRun)
    }
}

// MARK: the log

/// One automatic run, as the Auto-update log shows it.
public struct AutoUpdateRun: Codable, Equatable, Identifiable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name + "|" + detail }
        public var name: String
        public var isCask: Bool
        /// "5.8.3 → 5.8.4", a skip reason, or a failure.
        public var detail: String
        public init(name: String, isCask: Bool, detail: String) {
            self.name = name
            self.isCask = isCask
            self.detail = detail
        }
    }

    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var upgraded: [Item]
    public var skipped: [Item]
    public var failed: [Item]
    /// A problem with the run as a whole ("brew update failed …").
    public var note: String?
    public var dryRun: Bool

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date? = nil, upgraded: [Item] = [], skipped: [Item] = [],
                failed: [Item] = [], note: String? = nil, dryRun: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.upgraded = upgraded
        self.skipped = skipped
        self.failed = failed
        self.note = note
        self.dryRun = dryRun
    }

    /// "3 upgraded · 1 skipped · 1 failed", "Nothing to upgrade",
    /// "Dry run: 3 would upgrade".
    public var summary: String {
        if dryRun { return "Dry run: \(upgraded.count) would upgrade" + (skipped.isEmpty ? "" : " · \(skipped.count) skipped") }
        if upgraded.isEmpty && skipped.isEmpty && failed.isEmpty { return note == nil ? "Nothing to upgrade" : "Didn't run" }
        var parts: [String] = []
        if !upgraded.isEmpty { parts.append("\(upgraded.count) upgraded") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if upgraded.isEmpty && failed.isEmpty { parts.insert("Nothing upgraded", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// The notification, or nil when there is nothing worth one (nothing
    /// upgraded or failed).
    public var notification: UpgradeNotificationDiff.Message? {
        guard !dryRun, !(upgraded.isEmpty && failed.isEmpty && note == nil) else { return nil }
        let n = upgraded.count
        let title = n > 0 ? "Tankard upgraded \(n) package\(n == 1 ? "" : "s")"
            : (failed.isEmpty ? "Auto-update didn't run" : "Auto-update failed")
        var lines: [String] = []
        if n > 0 {
            let names = upgraded.map(\.name)
            lines.append(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : ""))
        }
        if !failed.isEmpty { lines.append("Failed: " + failed.map(\.name).prefix(3).joined(separator: ", ")) }
        if !skipped.isEmpty { lines.append("\(skipped.count) skipped (see the Auto-update log)") }
        if let note, n == 0, failed.isEmpty { lines.append(note) }
        return UpgradeNotificationDiff.Message(title: title, body: lines.joined(separator: "\n"),
                                               newKeys: ["auto-update@\(id.uuidString)"])
    }
}

/// The last runs, newest first, kept in
/// ~/Library/Application Support/net.mindtricks.tankard/auto-update-log.json.
@Observable @MainActor
public final class AutoUpdateLog {
    public nonisolated static let maxRuns = 20

    public private(set) var runs: [AutoUpdateRun]
    @ObservationIgnored public let url: URL?

    public nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppPaths.bundleID, isDirectory: true).appendingPathComponent("auto-update-log.json")
    }

    /// `url` nil: memory only (tests, demo).
    public init(url: URL?) {
        self.url = url
        runs = url.flatMap(Self.load) ?? []
    }

    public var latest: AutoUpdateRun? { runs.first }

    public func record(_ run: AutoUpdateRun) {
        var list = runs.filter { $0.id != run.id }
        list.insert(run, at: 0)
        runs = Array(list.prefix(Self.maxRuns))
        save()
    }

    /// Demo: show these runs without saving.
    public func seed(_ list: [AutoUpdateRun]) {
        runs = Array(list.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxRuns))
    }

    public func clear() {
        guard !runs.isEmpty else { return }
        runs = []
        save()
    }

    nonisolated static func load(_ url: URL) -> [AutoUpdateRun]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? StatusReport.jsonDecoder().decode([AutoUpdateRun].self, from: data)).map { Array($0.prefix(maxRuns)) }
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? StatusReport.jsonEncoder().encode(runs).write(to: url, options: .atomic)
    }
}

/// "Last auto-update: today 03:12 · 4 upgraded".
public enum AutoUpdateText {
    public static func lastLine(_ run: AutoUpdateRun?, now: Date, calendar: Calendar = .current) -> String? {
        guard let run else { return nil }
        return "Last auto-update: \(when(run.startedAt, now: now, calendar: calendar)) · \(run.summary)"
    }

    public static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "tomorrow \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday \(time)" }
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// The Settings line under the schedule.
    public static func status(_ d: AutoUpdateDecision, now: Date, calendar: Calendar = .current) -> String {
        switch d {
        case .off: return "Off"
        case .snoozed(let until): return snoozed(until: until, now: now, calendar: calendar)
        case .notDue(let next): return "Next run: \(when(next, now: now, calendar: calendar))"
        case .run: return "Due now"
        case .waiting(let w, _):
            switch w {
            case .startup: return "Due: waiting a few minutes after launch"
            case .busy: return "Due: waiting for brew to finish"
            case .onBattery: return "Due: waiting for AC power"
            case .notIdle: return "Due: waiting until the Mac is idle"
            }
        }
    }
}

// MARK: running it

/// Owns auto-update's settings, log and conditions, and runs one automatic
/// update. BackgroundChecker's timer asks it each tick.
@Observable @MainActor
public final class AutoUpdater {
    @ObservationIgnored public let settings: AutoUpdateSettings
    /// 0.6: skip this version, snooze, bump rules.
    @ObservationIgnored public let rules: UpgradeRulesSettings
    public let log: AutoUpdateLog
    /// Set by the app (IOKit, NSWorkspace). Defaults to never-AC.
    @ObservationIgnored public var conditions: AutoUpdateConditions
    @ObservationIgnored public var calendar: Calendar = .current
    /// A run in progress (no second one starts while true).
    public private(set) var isRunning = false
    /// "Auto-update: brew upgrade --formula homebrew/core/xz" while it runs.
    public private(set) var activity: String?

    public init(settings: AutoUpdateSettings, log: AutoUpdateLog, conditions: AutoUpdateConditions = NeverConditions(),
                rules: UpgradeRulesSettings? = nil) {
        self.settings = settings
        self.rules = rules ?? UpgradeRulesSettings(defaults: settings.defaults)
        self.log = log
        self.conditions = conditions
    }

    public func decide(store: AppStore, launchedAt: Date, now: Date) -> AutoUpdateDecision {
        AutoUpdatePolicy.decide(enabled: settings.enabled, schedule: settings.schedule, since: settings.since,
                                lastRun: settings.lastRun, launchedAt: launchedAt, now: now,
                                onAC: conditions.onACPower(), idle: conditions.idleSeconds(),
                                busy: isRunning || store.isBusy || store.isRefreshing || store.homebrewState.needsWelcome,
                                snoozed: rules.isSnoozed(now: now), snoozeEnds: rules.snoozeEnds,
                                calendar: calendar)
    }

    /// One automatic run: `brew update` and a re-read (the store's manual
    /// refresh, through the queue), the safe-mode plan, one `brew upgrade`
    /// per package through the queue, a re-read, the log and the
    /// notification. Returns the run (nil if one was already running).
    @discardableResult
    public func run(store: AppStore, notifier: UpgradeNotifying?, now: @escaping () -> Date = { Date() }) async -> AutoUpdateRun? {
        guard !isRunning else { return nil }
        isRunning = true
        defer {
            isRunning = false
            activity = nil
        }
        let started = now()
        // Recorded first, so a slot never runs twice, even if this one fails.
        settings.lastRun = started
        var record = AutoUpdateRun(startedAt: started, dryRun: settings.dryRun)

        if !settings.dryRun {
            activity = "Auto-update: brew update"
            await store.refresh(manual: true)
            if let e = store.error {
                record.note = "\(e.title)" + (e.detail.isEmpty ? "" : ": \(e.detail.split(separator: "\n").last ?? "")")
                return finish(record, store: store, notifier: notifier, now: now)
            }
        }
        guard store.report != nil else {
            record.note = "No Homebrew status to work from"
            return finish(record, store: store, notifier: notifier, now: now)
        }
        let plan = AutoUpdateSafeMode.plan(store.packages, classifier: store.deps.classifier,
                                           running: conditions.runningApps(),
                                           dontQuitApps: store.insights.settings.dontQuitAppsDuringUpgrade,
                                           only: settings.only, rules: rules.snapshot)
        record.skipped = plan.skipped.map { .init(name: $0.package.name, isCask: $0.package.kind == .cask, detail: $0.reason.text) }
        if settings.dryRun {
            record.upgraded = plan.run.map { .init(name: $0.name, isCask: $0.kind == .cask, detail: Self.versions($0)) }
            record.note = "Dry run: no brew command ran"
            return finish(record, store: store, notifier: notifier, now: now)
        }

        let logFile = store.deps.logURL.map(LogFile.init)
        logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: started)) auto-update (safe mode): "
                         + "\(plan.run.count) to upgrade, \(plan.skipped.count) skipped"])
        for s in plan.skipped { logFile?.append(["tankard: skipped \(s.package.name): \(s.reason.text)"]) }
        // 0.7: a restore point before the run upgrades anything.
        if !plan.run.isEmpty { store.saveRestorePoint(.autoUpdate, upgrading: plan.run) }
        for p in plan.run {
            guard settings.enabled else {
                record.note = "Stopped: auto-update was turned off during the run"
                break
            }
            let item = AutoUpdateRun.Item(name: p.name, isCask: p.kind == .cask, detail: Self.versions(p))
            activity = "Auto-update: upgrading \(p.name)"
            let (code, lines) = await runUpgrade(p, store: store, logFile: logFile)
            if code == 0 {
                record.upgraded.append(item)
            } else {
                let tail = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                let why = SudoDetector.needsSudo(lines) ? "needs administrator rights" : "brew exited \(code)" + (tail.isEmpty ? "" : ": \(tail)")
                record.failed.append(.init(name: p.name, isCask: p.kind == .cask, detail: why))
            }
        }
        logFile?.close()
        // Reconcile with what brew now says: an upgrade that "succeeded" but
        // is still outdated counts as failed.
        if !plan.run.isEmpty {
            await store.refresh(manual: false)
            let still = Set(store.packages.filter(\.upgradeAvailable).map(\.name))
            let notDone = record.upgraded.filter { still.contains($0.name) }
            record.upgraded.removeAll { still.contains($0.name) }
            record.failed += notDone.map { .init(name: $0.name, isCask: $0.isCask, detail: "still outdated after brew upgrade") }
        }
        return finish(record, store: store, notifier: notifier, now: now)
    }

    private func finish(_ r: AutoUpdateRun, store: AppStore, notifier: UpgradeNotifying?, now: () -> Date) -> AutoUpdateRun {
        var r = r
        r.finishedAt = now()
        log.record(r)
        if let message = r.notification { notifier?.post(message) }
        return r
    }

    static func versions(_ p: Package) -> String { "\(p.installedVersion) → \(p.currentVersion ?? "?")" }

    /// `brew upgrade` for one package through the queue (the same strict
    /// FIFO as every other brew command), with safe mode's environment.
    private func runUpgrade(_ p: Package, store: AppStore, logFile: LogFile?) async -> (Int32, [String]) {
        guard let client = try? store.resolvedClient(), let detection = store.report?.intelbrew else {
            return (-1, ["brew not found"])
        }
        let args = BrewCommands.upgradeArguments(for: p)
        let keep = RollbackSettings.extraEnvironment(.upgrade, p, keep: store.restorePoints.settings.keepPreviousVersion)
        let extra = AutoUpdateSafeMode.environment(for: p).merging(keep) { $1 }
        let env = client.environment(for: detection, readOnly: false).merging(extra) { $1 }
        let cmd = QueuedCommand(executable: client.installation.brewPath, arguments: args, environment: env,
                                display: BrewCommands.display(args, environment: extra.filter {
                                    $0.key == InsightSettings.noQuitKey || $0.key == RollbackSettings.noInstallCleanupKey
                                }))
        logFile?.append(["$ \(cmd.display)"])
        let collector = OutputCollector()
        do {
            let code = try await store.queue.run(cmd) { data in
                collector.add(data)
            }
            let lines = collector.lines()
            logFile?.append(lines)
            if code != 0 { logFile?.append(["tankard: brew exited with status \(code)"]) }
            return (code, lines)
        } catch {
            logFile?.append(["tankard: could not run brew: \(error)"])
            return (-1, ["Could not run brew: \(error)"])
        }
    }
}
