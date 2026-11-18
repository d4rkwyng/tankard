import AskpassSupport
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
    public var title: String { self == .daily ? String(localized: "Every day") : String(localized: "Every week") }
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
        if frequency == .daily { return String(localized: "Every day at \(time)") }
        let names = calendar.weekdaySymbols
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : String(localized: "Sunday")
        return String(localized: "Every \(name) at \(time)")
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
    /// 0.8: the user chose "App updates itself" for this cask.
    case appUpdatesItself
    /// 0.8.3: a pkg (or sudo installer) cask: brew would ask for the
    /// administrator password, and an automatic run never asks.
    case needsPassword
    /// 0.8.4: another brew (Terminal's) held brew's lock longer than the
    /// lock wait allows. Not a failure: the next run tries again.
    case homebrewBusy
    /// 0.8.4: Tankard quit (through the quit guard) before this step ran or
    /// finished. The interrupted slot runs again at the next launch.
    case quit
    /// 0.8.4: brew.env sets a password helper that isn't Tankard's (the
    /// path), or clears HOMEBREW_NO_SUDO (nil: no foreign helper). Either
    /// one alone is enough: a sudo-capable cask step is skipped, never run
    /// unattended. Checked right before each such step; formulae are
    /// unaffected.
    case foreignAskpass(String?)
    /// 0.8.5: the step ran past auto-update's time limit and was stopped
    /// (brew undoes the unfinished step). The next run tries again.
    case timedOut
    /// 0.8.5: the Mac went to sleep during the step and it failed: not
    /// counted as a failure. The next run tries again.
    case slept

    public var text: String {
        switch self {
        case .pinned: return String(localized: "pinned")
        case .compiles: return String(localized: "no bottle, would compile from source")
        case .dependencyCompiles(let d): return String(localized: "its dependency \(d) would compile from source")
        case .dependencyPinned(let d): return String(localized: "its dependency \(d) is pinned")
        case .dependentCompiles(let p, let d): return String(localized: "upgrading \(p) would need \(d) rebuilt from source; upgrade by hand")
        case .appRunning(let a): return String(localized: "\(a) is running")
        case .appUnknown: return String(localized: "couldn't tell whether its app is running")
        case .tankardItself: return String(localized: "Tankard updates itself through brew")
        case .versionSkipped(let v): return String(localized: "you chose to skip \(v)")
        case .appUpdatesItself: return String(localized: "set to update itself")
        case .needsPassword: return String(localized: "needs your administrator password; upgrade it by hand")
        case .homebrewBusy: return String(localized: "Homebrew was busy")
        case .timedOut: return String(localized: "took too long and was stopped; the next automatic run tries again")
        case .slept: return String(localized: "interrupted by sleep; the next automatic run tries again")
        case .quit: return String(localized: "Tankard quit; the next automatic run upgrades it")
        case .foreignAskpass(let helper?): return String(localized: "brew.env sets its own password helper (\(helper)); upgrade it in Terminal")
        case .foreignAskpass(nil): return String(localized: "brew.env clears HOMEBREW_NO_SUDO, so brew could ask for a password; upgrade it in Terminal")
        case .bumpRule(let a, let b, let bump):
            if bump == VersionBump.unknown.title {
                return String(localized: "\(a) → \(b): versions can't be compared, so only \"All versions\" upgrades it; upgrade by hand")
            }
            return String(localized: "\(a) → \(b): \(bump) version; upgrade by hand")
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

    /// 0.8.3: an automatic run's environment: whatever brew.env or the
    /// caller set, no SUDO_ASKPASS and HOMEBREW_NO_SUDO=1.
    public static func unattended(_ env: [String: String]) -> [String: String] {
        var e = env.merging(AdminPassword.unattendedEnvironment) { $1 }
        e[Askpass.askpassKey] = nil
        e[Askpass.contextKey] = nil
        return e
    }

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
            // 0.8.3: its installer runs with sudo: nobody is there to type the password.
            if AdminPassword.required(p) { skipped.append((p, .needsPassword)); continue }
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
        String(localized: "Runs brew update first, then upgrades one package at a time through Tankard's queue."),
        String(localized: "Bottles only: a formula with no bottle, or one whose upgrade would also upgrade a dependency that has none, is skipped. So is a formula whose upgrade would make brew upgrade or rebuild an installed dependent that has none: it stays in Upgrades to upgrade by hand."),
        String(localized: "Pinned packages are skipped, and so are packages whose dependencies are pinned."),
        String(localized: "Never quits an app: a cask whose app is running is skipped, unless \"Don't quit running apps\" is on (then it upgrades and the new version opens next time)."),
        String(localized: "Self-updating apps are included only when \"Include self-updating apps\" is on, or when you chose \"Homebrew updates it\" for that app; never when you chose \"App updates itself\"."),
        String(localized: "Tankard itself is never upgraded automatically: use brew upgrade --cask tankard."),
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
        /// 0.8.5: skipped because the cask needs the administrator password
        /// (`AutoUpdateSkip.needsPassword`); the log offers Upgrade Now.
        /// nil otherwise and in logs from before 0.8.5.
        public var needsPassword: Bool?
        public init(name: String, isCask: Bool, detail: String, needsPassword: Bool? = nil) {
            self.name = name
            self.isCask = isCask
            self.detail = detail
            self.needsPassword = needsPassword
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
    /// 0.8.1: casks macOS's App Management permission blocked (nil in
    /// logs from before 0.8.1).
    public var appManagement: [String]?

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

    /// 0.8.5: the casks skipped for the administrator password.
    public var passwordSkipped: [String] { skipped.filter { $0.needsPassword == true }.map(\.name) }

    /// "3 upgraded · 1 skipped · 1 failed", "Nothing to upgrade",
    /// "Dry run: 3 would upgrade".
    public var summary: String {
        if dryRun { return String(localized: "Dry run: \(upgraded.count) would upgrade") + (skipped.isEmpty ? "" : " · " + String(localized: "\(skipped.count) skipped")) }
        if upgraded.isEmpty && skipped.isEmpty && failed.isEmpty { return note == nil ? String(localized: "Nothing to upgrade") : String(localized: "Didn't run") }
        var parts: [String] = []
        if !upgraded.isEmpty { parts.append(String(localized: "\(upgraded.count) upgraded")) }
        if !skipped.isEmpty { parts.append(String(localized: "\(skipped.count) skipped")) }
        if !failed.isEmpty { parts.append(String(localized: "\(failed.count) failed")) }
        if upgraded.isEmpty && failed.isEmpty { parts.insert(String(localized: "Nothing upgraded"), at: 0) }
        return parts.joined(separator: " · ")
    }

    /// The notification, or nil when there is nothing worth one (nothing
    /// upgraded or failed).
    public var notification: UpgradeNotificationDiff.Message? {
        guard !dryRun, !(upgraded.isEmpty && failed.isEmpty && note == nil) else { return nil }
        let n = upgraded.count
        let title = n > 0 ? (n == 1 ? String(localized: "Tankard upgraded \(n) package") : String(localized: "Tankard upgraded \(n) packages"))
            : (failed.isEmpty ? String(localized: "Auto-update didn't run") : String(localized: "Auto-update failed"))
        var lines: [String] = []
        if n > 0 {
            let names = upgraded.map(\.name)
            lines.append(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? String(localized: " and \(names.count - 4) more") : ""))
        }
        if !failed.isEmpty { lines.append(String(localized: "Failed: ") + failed.map(\.name).prefix(3).joined(separator: ", ")) }
        if !(appManagement ?? []).isEmpty {
            lines.append(String(localized: "macOS blocked changing apps: allow Tankard in Privacy & Security → App Management, then relaunch it."))
        }
        if !skipped.isEmpty { lines.append(String(localized: "\(skipped.count) skipped (see the Auto-update log)")) }
        if let note, n == 0, failed.isEmpty { lines.append(note) }
        return UpgradeNotificationDiff.Message(title: title, body: lines.joined(separator: "\n"),
                                               newKeys: ["auto-update@\(id.uuidString)"], kind: .autoUpdate)
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
        return String(localized: "Last auto-update: \(when(run.startedAt, now: now, calendar: calendar)) · \(run.summary)")
    }

    public static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let time = f.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today \(time)") }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return String(localized: "tomorrow \(time)") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return String(localized: "yesterday \(time)") }
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    /// The Settings line under the schedule.
    public static func status(_ d: AutoUpdateDecision, now: Date, calendar: Calendar = .current) -> String {
        switch d {
        case .off: return String(localized: "Off")
        case .snoozed(let until): return snoozed(until: until, now: now, calendar: calendar)
        case .notDue(let next): return String(localized: "Next run: \(when(next, now: now, calendar: calendar))")
        case .run: return String(localized: "Due now")
        case .waiting(let w, _):
            switch w {
            case .startup: return String(localized: "Due: waiting a few minutes after launch")
            case .busy: return String(localized: "Due: waiting for brew to finish")
            case .onBattery: return String(localized: "Due: waiting for AC power")
            case .notIdle: return String(localized: "Due: waiting until the Mac is idle")
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
    /// 0.8.4: the upgrade step the run is on (the quit guard's alert), nil
    /// outside the upgrade steps (brew update, the downloads, the re-read).
    public private(set) var step: AutoUpdateStep?
    /// 0.8.4: the quit guard stopped the run (QuitGuard.swift).
    @ObservationIgnored public private(set) var quitRequested = false
    /// The queued id of the running upgrade step (Quit Now cancels it).
    @ObservationIgnored private var stepCommand: UUID?
    /// 0.8.3: why automatic runs are paused (brew.env turns off brew's
    /// installed-dependents check), or nil. Updated by `checkPause` (each
    /// background tick and at the start of a run); Settings and the menu
    /// bar show it.
    public private(set) var pausedReason: String?
    /// The brew.env files to check, in bin/brew's order. Defaults to what
    /// the client read at launch (tests, demo); the app re-reads the real
    /// files each time, so an edit takes effect without a relaunch.
    @ObservationIgnored public var brewEnvFiles: @MainActor (BrewClient) -> [(String, [String: String])] = { $0.sources.brewEnvFiles }

    public init(settings: AutoUpdateSettings, log: AutoUpdateLog, conditions: AutoUpdateConditions = NeverConditions(),
                rules: UpgradeRulesSettings? = nil) {
        self.settings = settings
        self.rules = rules ?? UpgradeRulesSettings(defaults: settings.defaults)
        self.log = log
        self.conditions = conditions
    }

    /// 0.8.5: after a scheduled `brew update` that didn't finish (offline,
    /// brew busy, slept), the slot waits at least this long before trying again.
    public nonisolated static let quietRetry: TimeInterval = 15 * 60
    /// 0.8.5: the open slot doesn't run before this (memory only).
    @ObservationIgnored public internal(set) var retryNotBefore: Date?

    public func decide(store: AppStore, launchedAt: Date, now: Date) -> AutoUpdateDecision {
        if let r = retryNotBefore, r > now, settings.enabled, !rules.isSnoozed(now: now) {
            return .waiting(.busy, retry: r.timeIntervalSince(now))
        }
        return AutoUpdatePolicy.decide(enabled: settings.enabled, schedule: settings.schedule, since: settings.since,
                                lastRun: settings.lastRun, launchedAt: launchedAt, now: now,
                                onAC: conditions.onACPower(), idle: conditions.idleSeconds(),
                                busy: isRunning || store.isBusy || store.isRefreshing || store.homebrewState.needsWelcome,
                                snoozed: rules.isSnoozed(now: now), snoozeEnds: rules.snoozeEnds,
                                calendar: calendar)
    }

    /// 0.8.3: safe mode relies on brew's installed-dependents check (see
    /// `dependentThatCompiles`). brew.env beats the environment Tankard
    /// passes (bin/brew exports it over the top), so a
    /// HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK there would turn the check off
    /// for automatic runs too. Then every automatic run is skipped until it
    /// is gone. Manual upgrades are unaffected. Returns the setting.
    @discardableResult
    public func checkPause(store: AppStore) -> EnvSetting? {
        guard let client = try? store.resolvedClient() else { return nil }
        let s = Self.dependentsCheckOff(brewEnvFiles(client))
        let reason = s == nil ? nil : Self.pausedText
        if pausedReason != reason { pausedReason = reason }
        return s
    }

    /// 0.8.4: the skip for a sudo-capable cask step when brew.env sets a
    /// password helper that isn't Tankard's, or clears HOMEBREW_NO_SUDO
    /// (either alone; read now, with `brewEnvFiles`); nil when it may run.
    func foreignAskpassSkip(store: AppStore) -> AutoUpdateSkip? {
        guard let client = try? store.resolvedClient() else { return nil }
        let files = brewEnvFiles(client)
        if let f = ForeignAskpass.detect(brewEnvFiles: files, own: store.deps.askpassHelper) {
            return .foreignAskpass(f.helper)
        }
        if EnvironmentSources.brewEnvSetting(Askpass.noSudoKey, files: files)?.value.isEmpty == true {
            return .foreignAskpass(nil)
        }
        return nil
    }

    public nonisolated static let dependentsCheckKey = "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"
    public static var pausedText: String {
        String(localized: "brew.env turns off brew's dependents check; automatic updates paused.")
    }

    /// The brew.env setting that turns the check off, by brew's own rules
    /// (file precedence; `boolean: true`, so "0", "false", "no", "off",
    /// "nil" and blank leave it on). nil: the check is on.
    public nonisolated static func dependentsCheckOff(_ files: [(String, [String: String])]) -> EnvSetting? {
        guard let s = EnvironmentSources.brewEnvSetting(dependentsCheckKey, files: files),
              BrewBoolean.isSet(s.value) else { return nil }
        return s
    }

    /// One automatic run: `brew update` and a re-read (the store's manual
    /// refresh, through the queue), the safe-mode plan, one `brew upgrade`
    /// per package through the queue, a re-read, the log and the
    /// notification. Returns the run (nil if one was already running).
    @discardableResult
    public func run(store: AppStore, notifier: UpgradeNotifying?, now: @escaping () -> Date = { Date() }) async -> AutoUpdateRun? {
        guard !isRunning else { return nil }
        isRunning = true
        quitRequested = false
        defer {
            isRunning = false
            activity = nil
            step = nil
            stepCommand = nil
        }
        let started = now()
        // Recorded first, so a slot never runs twice, even if this one fails
        // (0.8.4: unless Tankard quits mid-run: see `stopForQuit`).
        let previousRun = settings.lastRun
        settings.lastRun = started
        var record = AutoUpdateRun(startedAt: started, dryRun: settings.dryRun)

        // 0.8.3: brew.env turned brew's dependents check off: skip the whole run.
        if let s = checkPause(store: store) {
            record.note = Self.pausedText
            let logFile = store.deps.logURL.map(LogFile.init)
            logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: started)) auto-update (safe mode): skipped: "
                             + "\(Self.dependentsCheckKey)=\(s.value) in \(s.source) turns off brew's installed-dependents check"])
            logFile?.close()
            return finish(record, store: store, notifier: notifier, now: now)
        }

        if !settings.dryRun {
            activity = String(localized: "Auto-update: brew update")
            // 0.8.5: a scheduled refresh (time limit, sleep, quiet failures).
            await store.refresh(.scheduled)
            if let quiet = store.lastScheduledUpdate?.quiet {
                // Offline, brew busy, slept or too slow: the slot stays open
                // and runs again once the wait below is over.
                record.note = quiet.text
                settings.lastRun = previousRun
                retryNotBefore = now().addingTimeInterval(max(quiet.retryAfter, Self.quietRetry))
                return finish(record, store: store, notifier: nil, now: now)
            }
            if let e = store.error {
                record.note = "\(e.title)" + (e.detail.isEmpty ? "" : ": \(e.detail.split(separator: "\n").last ?? "")")
                return finish(record, store: store, notifier: notifier, now: now)
            }
        }
        guard store.report != nil else {
            record.note = String(localized: "No Homebrew status to work from")
            return finish(record, store: store, notifier: notifier, now: now)
        }
        let plan = AutoUpdateSafeMode.plan(store.packages, classifier: store.deps.classifier,
                                           running: conditions.runningApps(),
                                           dontQuitApps: store.insights.settings.dontQuitAppsDuringUpgrade,
                                           only: settings.only, rules: rules.snapshot)
        record.skipped = plan.skipped.map {
            .init(name: $0.package.name, isCask: $0.package.kind == .cask, detail: $0.reason.text,
                  needsPassword: $0.reason == .needsPassword ? true : nil)
        }
        if settings.dryRun {
            record.upgraded = plan.run.map { .init(name: $0.name, isCask: $0.kind == .cask, detail: Self.versions($0)) }
            record.note = String(localized: "Dry run: no brew command ran")
            return finish(record, store: store, notifier: notifier, now: now)
        }

        let logFile = store.deps.logURL.map(LogFile.init)
        logFile?.append(["", "=== \(ISO8601DateFormatter().string(from: started)) auto-update (safe mode): "
                         + "\(plan.run.count) to upgrade, \(plan.skipped.count) skipped"])
        for s in plan.skipped { logFile?.append(["tankard: skipped \(s.package.name): \(s.reason.text)"]) }
        // 0.7: a restore point before the run upgrades anything.
        if !plan.run.isEmpty { store.saveRestorePoint(.autoUpdate, upgrading: plan.run) }
        // 0.8.3: the downloads first, in parallel (quietly: the log only).
        await prefetch(plan.run, store: store, logFile: logFile)
        // 0.8.4: a step that finds brew's lock held waits for it, as the
        // sheet's steps do; after one wait runs out, the rest don't wait again
        // (whatever holds it is long-running: one bounded wait per run).
        var lockWait = store.deps.lockWait
        for (n, p) in plan.run.enumerated() {
            guard settings.enabled else {
                record.note = String(localized: "Stopped: auto-update was turned off during the run")
                break
            }
            guard !quitRequested else { break }
            // 0.8.4: brew.env read again right before each sudo-capable cask
            // step: a foreign password helper, or HOMEBREW_NO_SUDO cleared
            // there, means the step is skipped, never run unattended.
            if AdminPassword.mayNeedSudo(BrewCommands.upgradeArguments(for: p)), let skip = foreignAskpassSkip(store: store) {
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: skip.text))
                logFile?.append(["tankard: skipped \(p.name): \(skip.text)"])
                continue
            }
            var item = AutoUpdateRun.Item(name: p.name, isCask: p.kind == .cask, detail: Self.versions(p))
            activity = String(localized: "Auto-update: upgrading \(p.name)")
            step = AutoUpdateStep(name: p.name, index: n + 1, total: plan.run.count)
            let result = await runUpgrade(p, store: store, logFile: logFile, lockWait: lockWait)
            let (code, lines) = (result.code, result.lines)
            if result.timedOut {
                logFile?.append(["tankard: stopped \(p.name): \(AutoUpdateSkip.timedOut.text)"])
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: AutoUpdateSkip.timedOut.text))
            } else if result.slept && code != 0 && !quitRequested {
                logFile?.append(["tankard: skipped \(p.name): \(AutoUpdateSkip.slept.text)"])
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: AutoUpdateSkip.slept.text))
            } else if result.cancelled {
                // Quit Now: brew stopped and undid the step (not a failure).
                logFile?.append(["tankard: stopped \(p.name): Tankard is quitting"])
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: AutoUpdateSkip.quit.text))
            } else if code == 0 {
                if result.waited { item.detail += " · " + String(localized: "waited for another Homebrew command") }
                record.upgraded.append(item)
            } else if BrewFailure.classify(lines) == .locked {
                // The lock wait ran out (or there was none): skipped, not failed.
                if result.waited { lockWait = nil }
                logFile?.append(["tankard: skipped \(p.name): \(AutoUpdateSkip.homebrewBusy.text)"])
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: AutoUpdateSkip.homebrewBusy.text))
            } else {
                // 0.8.4: brew's last line goes to the Auto-update log and the
                // notification: never with a URL's user:password.
                let tail = ProxySettings.maskText(lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
                var why = SudoDetector.needsSudo(lines) ? String(localized: "needs administrator rights") : String(localized: "brew exited \(Int(code))") + (tail.isEmpty ? "" : ": \(tail)")
                // 0.8.1: no sheet here to explain it: say so in the log and
                // the notification, and explain again before the next
                // cask change the user makes.
                if p.kind == .cask, AppManagement.isPermissionBlock(lines) {
                    why = BrewFailureKind.appManagement.title
                    record.appManagement = (record.appManagement ?? []) + [p.name]
                    store.settings.appManagementExplained = false
                }
                record.failed.append(.init(name: p.name, isCask: p.kind == .cask, detail: why))
            }
        }
        step = nil
        if quitRequested {
            // 0.8.4: quit mid-run. The steps not run are logged, the slot is
            // opened again (lastRun back to the run before), and the next
            // launch's scheduler runs it once its conditions hold, with a
            // fresh brew update and plan. No prompt at the next launch, no
            // re-read and no notification now: Tankard is quitting.
            let done = Set((record.upgraded + record.failed + record.skipped).map(\.name))
            for p in plan.run where !done.contains(p.name) {
                record.skipped.append(.init(name: p.name, isCask: p.kind == .cask, detail: AutoUpdateSkip.quit.text))
            }
            // Stop After Current on the last step left nothing undone: the slot ran.
            if record.skipped.contains(where: { $0.detail == AutoUpdateSkip.quit.text }) {
                record.note = String(localized: "Tankard quit during the run")
                logFile?.append(["tankard: Tankard quit during the run; the rest wait for the next automatic run"])
                settings.lastRun = previousRun
            }
            logFile?.close()
            return finish(record, store: store, notifier: nil, now: now)
        }
        logFile?.close()
        // Reconcile with what brew now says: an upgrade that "succeeded" but
        // is still outdated counts as failed.
        if !plan.run.isEmpty {
            await store.refresh(manual: false)
            let still = Set(store.packages.filter(\.upgradeAvailable).map(\.name))
            let notDone = record.upgraded.filter { still.contains($0.name) }
            record.upgraded.removeAll { still.contains($0.name) }
            record.failed += notDone.map { .init(name: $0.name, isCask: $0.isCask, detail: String(localized: "still outdated after brew upgrade")) }
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

    /// 0.8.3: one `brew fetch` per kind with two or more packages (Prefetch.swift),
    /// through the queue, with safe mode's environment. A failure is only
    /// logged: each upgrade downloads what's missing itself.
    private func prefetch(_ run: [Package], store: AppStore, logFile: LogFile?) async {
        guard let client = try? store.resolvedClient(), let detection = store.report?.intelbrew else { return }
        let concurrency = Prefetch.environment(store.brewSources)
        let env = client.environment(for: detection, readOnly: false)
            .merging(["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ASK": "1"]) { $1 }
            .merging(concurrency) { $1 }
        let steps = Prefetch.steps(.upgrade, run) { args in
            QueuedCommand(executable: client.installation.brewPath, arguments: args, environment: env,
                          display: BrewCommands.display(args, environment: concurrency))
        }
        for step in steps {
            guard settings.enabled else { return }
            activity = String(localized: "Auto-update: downloading \(step.targets.count) packages")
            logFile?.append(["$ \(step.command.display)"])
            let collector = OutputCollector()
            do {
                let code = try await store.queue.run(step.command) { collector.add($0) }
                logFile?.append(collector.lines())
                if code != 0 { logFile?.append(["tankard: brew fetch exited with status \(code); each upgrade downloads what's missing itself"]) }
            } catch {
                logFile?.append(collector.lines() + ["tankard: could not run brew fetch: \(error)"])
            }
        }
    }

    /// 0.8.4: the quit guard's choice for a running automatic run. After
    /// Current: no step starts after the running one. Now: the running step
    /// is stopped too (its process group, as the sheet's Stop Now).
    public func stopForQuit(_ choice: QuitChoice, queue: CommandQueue) {
        guard isRunning else { return }
        quitRequested = true
        if choice == .now, let id = stepCommand { queue.cancel(id) }
    }

    struct StepResult {
        var code: Int32
        var lines: [String]
        /// It waited for brew's lock at least once.
        var waited = false
        /// Stopped (Quit Now) or cancelled before it ran.
        var cancelled = false
        /// 0.8.5: stopped by the step time limit.
        var timedOut = false
        /// 0.8.5: the Mac slept while it ran.
        var slept = false
    }

    /// 0.8.5: an automatic upgrade step is stopped after this long (from
    /// when brew starts; safe mode never compiles, so a step this long is
    /// stuck, usually on a network that went away).
    public nonisolated static let stepTimeout: TimeInterval = 60 * 60
    /// Tests shorten it.
    @ObservationIgnored public var stepTimeoutOverride: TimeInterval?

    /// `brew upgrade` for one package through the queue (the same strict
    /// FIFO as every other brew command), with safe mode's environment.
    /// 0.8.4: with `lockWait`, a lock failure waits and runs again, as in
    /// the sheet; the wait goes to upgrade.log.
    private func runUpgrade(_ p: Package, store: AppStore, logFile: LogFile?, lockWait: BrewLockWait?) async -> StepResult {
        guard let client = try? store.resolvedClient(), let detection = store.report?.intelbrew else {
            return StepResult(code: -1, lines: ["brew not found"])
        }
        let args = BrewCommands.upgradeArguments(for: p)
        let keep = RollbackSettings.extraEnvironment(.upgrade, p, keep: store.restorePoints.settings.keepPreviousVersion)
        let extra = AutoUpdateSafeMode.environment(for: p).merging(keep) { $1 }
        // 0.8.3: never a password prompt unattended: no SUDO_ASKPASS, and
        // brew told not to run sudo at all (a SUDO_ASKPASS from brew.env
        // can't bring a dialog up either).
        let env = AutoUpdateSafeMode.unattended(client.environment(for: detection, readOnly: false).merging(extra) { $1 })
        let cmd = QueuedCommand(executable: client.installation.brewPath, arguments: args, environment: env,
                                display: BrewCommands.display(args, environment: extra.filter {
                                    $0.key == InsightSettings.noQuitKey || $0.key == RollbackSettings.noInstallCleanupKey
                                }))
        logFile?.append(["$ \(cmd.display)"])
        let capture = StepCapture()
        let id = UUID()
        stepCommand = id
        defer { stepCommand = nil }
        let name = p.name
        let flags = ScheduledRunFlags()
        let timeout = stepTimeoutOverride ?? Self.stepTimeout
        let queue = store.queue
        let sleeps = store.system.sleepCount
        let event: CommandEvent = await withCheckedContinuation { cont in
            store.queue.enqueue(cmd, id: id, lockWait: lockWait) { [weak self] event in
                switch event {
                case .started: flags.startTimer(timeout) { queue.cancel(id) }
                case .output(let d): capture.add(d)
                case .lockWait(let holder):
                    if let holder {
                        // The locked attempt's output, then the wait.
                        logFile?.append(capture.restart())
                        logFile?.append([holder.isEmpty ? "tankard: another Homebrew command holds brew's lock; waiting for it"
                                         : "tankard: another Homebrew command holds brew's lock (pid \(holder)); waiting for it"])
                        Task { @MainActor in self?.lockWaitChanged(waiting: true, for: name) }
                    } else {
                        logFile?.append(["tankard: brew's lock is free: running it again", "$ \(cmd.display)"])
                        Task { @MainActor in self?.lockWaitChanged(waiting: false, for: name) }
                    }
                case .finished, .cancelled, .failed, .skipped:
                    flags.finish()
                    cont.resume(returning: event)
                }
            }
        }
        let lines = capture.finish()
        logFile?.append(lines)
        var result: StepResult
        switch event {
        case .finished(let code):
            if code != 0 { logFile?.append(["tankard: brew exited with status \(code)"]) }
            result = StepResult(code: code, lines: lines)
        case .cancelled, .skipped:
            result = StepResult(code: -1, lines: lines, cancelled: true)
        case .failed(let message):
            logFile?.append(["tankard: could not run brew: \(message)"])
            result = StepResult(code: -1, lines: ["Couldn't run brew: \(message)"])
        default:
            result = StepResult(code: -1, lines: lines)
        }
        result.waited = capture.waited
        result.timedOut = flags.timedOut
        result.slept = store.system.sleepCount != sleeps
        // A wait that ran out: the last attempt's output was the locked one.
        if result.waited, !result.cancelled, result.code != 0, lines.isEmpty { result.lines = capture.lockedLines }
        return result
    }

    private func lockWaitChanged(waiting: Bool, for name: String) {
        guard isRunning, step?.name == name else { return }
        activity = waiting ? String(localized: "Waiting for another Homebrew command to finish…")
            : String(localized: "Auto-update: upgrading \(name)")
    }
}

/// 0.8.4: where an automatic run is: "xz, 3 of 7".
public struct AutoUpdateStep: Equatable, Sendable {
    public var name: String
    public var index: Int
    public var total: Int
}

/// One automatic step's output, attempt by attempt (fed from the queue's thread).
final class StepCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var collector = OutputCollector()
    private var _waited = false
    private var _locked: [String] = []

    func add(_ d: Data) { lock.withLock { collector }.add(d) }

    /// The attempt that found the lock: its lines (kept to classify a wait
    /// that runs out); the next attempt starts over.
    func restart() -> [String] {
        lock.withLock {
            let lines = collector.lines()
            collector = OutputCollector()
            _waited = true
            _locked = lines
            return lines
        }
    }

    func finish() -> [String] { lock.withLock { collector }.lines() }
    var waited: Bool { lock.withLock { _waited } }
    var lockedLines: [String] { lock.withLock { _locked } }
}
