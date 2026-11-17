import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.5: automatic updates. Nothing here runs brew: the scheduler is pure,
// and the runs go through the demo's or the tests' fake runners.

/// UTC Gregorian, so slots don't move with the test Mac's time zone.
let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US")
    return c
}()

/// 2026-11-16 (a Monday) at hh:mm UTC, plus `days`.
func at(_ hh: Int, _ mm: Int = 0, days: Int = 0) -> Date {
    let base = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hh, minute: mm))!
    return base.addingTimeInterval(TimeInterval(days) * 86400)
}

/// A test package (built from the cleanup placeholder, then edited).
func pkg(_ name: String, kind: PackageKind = .formula, outdated: Bool = true, bottle: Bool = true, pinned: Bool = false,
         deps: [String] = [], apps: [String]? = nil, quit: [String]? = nil) -> Package {
    var p = Package.command(name)
    p.id = "\(kind.rawValue):homebrew/\(kind == .cask ? "cask" : "core")/\(name)"
    p.kind = kind
    p.name = name
    p.fullName = name
    p.tap = kind == .cask ? "homebrew/cask" : "homebrew/core"
    p.installedVersion = "1.0"
    p.installedVersions = ["1.0"]
    p.currentVersion = "1.1"
    p.upgradeAvailable = outdated
    p.upgradeHasBottle = kind == .formula && outdated ? bottle : nil
    p.pinned = pinned
    p.dependencies = deps
    p.status = kind == .cask ? .cask : .bottle
    if kind == .cask {
        p.appPaths = apps
        p.quitBundleIDs = quit
    }
    return p
}

// MARK: schedule and decision

struct AutoUpdateScheduleTests {
    @Test func dailySlots() {
        let s = AutoUpdateSchedule(frequency: .daily, hour: 3, minute: 30)
        #expect(s.latestSlot(atOrBefore: at(10), calendar: utc) == at(3, 30))
        #expect(s.latestSlot(atOrBefore: at(3, 30), calendar: utc) == at(3, 30))
        #expect(s.latestSlot(atOrBefore: at(2), calendar: utc) == at(3, 30, days: -1))
        #expect(s.nextSlot(after: at(10), calendar: utc) == at(3, 30, days: 1))
        #expect(s.nextSlot(after: at(3, 30), calendar: utc) == at(3, 30, days: 1))
        #expect(s.nextSlot(after: at(1), calendar: utc) == at(3, 30))
    }

    @Test func weeklySlots() {
        // 2026-11-16 is a Monday (weekday 2); Sunday is weekday 1.
        #expect(utc.component(.weekday, from: at(0)) == 2)
        let s = AutoUpdateSchedule(frequency: .weekly, hour: 3, weekday: 1)
        #expect(s.latestSlot(atOrBefore: at(10), calendar: utc) == at(3, days: -1))
        #expect(s.nextSlot(after: at(10), calendar: utc) == at(3, days: 6))
        let monday = AutoUpdateSchedule(frequency: .weekly, hour: 3, weekday: 2)
        #expect(monday.latestSlot(atOrBefore: at(2), calendar: utc) == at(3, days: -7))
        #expect(monday.latestSlot(atOrBefore: at(4), calendar: utc) == at(3))
        #expect(monday.text(calendar: utc) == "Every Monday at 03:00")
        #expect(AutoUpdateSchedule(hour: 23, minute: 5).text(calendar: utc) == "Every day at 23:05")
    }

    @Test func clamped() {
        let s = AutoUpdateSchedule(hour: 40, minute: -3, weekday: 9)
        #expect(s.hour == 23 && s.minute == 0 && s.weekday == 7)
    }
}

struct AutoUpdatePolicyTests {
    let daily = AutoUpdateSchedule(frequency: .daily, hour: 3)
    let launched = at(0, days: -1)
    let idle = AutoUpdatePolicy.idleThreshold

    func decide(now: Date, since: Date? = at(0, days: -10), lastRun: Date? = nil, ac: Bool? = true,
                idle: TimeInterval? = 3600, busy: Bool = false, enabled: Bool = true, launchedAt: Date? = nil) -> AutoUpdateDecision {
        AutoUpdatePolicy.decide(enabled: enabled, schedule: daily, since: since, lastRun: lastRun,
                                launchedAt: launchedAt ?? launched, now: now, onAC: ac, idle: idle, busy: busy, calendar: utc)
    }

    @Test func offByDefaultMeansOff() {
        #expect(decide(now: at(4), enabled: false) == .off)
    }

    @Test func dueRunsOnACAndIdle() {
        #expect(decide(now: at(3, 1)) == .run(slot: at(3)))
        #expect(decide(now: at(3, 1), lastRun: at(3, 5, days: -1)) == .run(slot: at(3)))
    }

    @Test func notDueAfterThisSlotRan() {
        #expect(decide(now: at(9), lastRun: at(3, 2)) == .notDue(next: at(3, days: 1)))
        // Before today's slot, yesterday's already ran.
        #expect(decide(now: at(2), lastRun: at(3, 2, days: -1)) == .notDue(next: at(3)))
    }

    @Test func turningItOnNeverRunsAPassedSlot() {
        // Turned on at 10:00: today's 03:00 doesn't count, tomorrow's does.
        #expect(decide(now: at(10, 1), since: at(10)) == .notDue(next: at(3, days: 1)))
        #expect(decide(now: at(3, 1, days: 1), since: at(10)) == .run(slot: at(3, days: 1)))
    }

    @Test func batteryWaits() {
        #expect(decide(now: at(3, 1), ac: false) == .waiting(.onBattery, retry: AutoUpdatePolicy.recheck))
        // Unknown power is treated as battery.
        #expect(decide(now: at(3, 1), ac: nil) == .waiting(.onBattery, retry: AutoUpdatePolicy.recheck))
    }

    @Test func idleThreshold() {
        #expect(idle == 600)
        guard case .waiting(.notIdle, let retry) = decide(now: at(3, 1), idle: idle - 60) else {
            Issue.record("expected notIdle"); return
        }
        #expect(retry == 60)
        #expect(decide(now: at(3, 1), idle: idle) == .run(slot: at(3)))
        // Unknown idle time: not idle.
        guard case .waiting(.notIdle, _) = decide(now: at(3, 1), idle: nil) else { Issue.record("expected notIdle"); return }
    }

    @Test func startupAndBusyWait() {
        #expect(decide(now: at(3, 1), launchedAt: at(3)) == .waiting(.startup, retry: 240))
        #expect(decide(now: at(3, 1), busy: true) == .waiting(.busy, retry: AutoUpdatePolicy.recheck))
    }

    @Test func missedWindowRunsOnceLater() {
        // The Mac slept through 03:00 (last run was yesterday's slot): it
        // runs at 14:00 when it is idle on AC…
        #expect(decide(now: at(14), lastRun: at(3, 4, days: -1)) == .run(slot: at(3)))
        // …and once that run started, not again until tomorrow's slot.
        #expect(decide(now: at(14, 30), lastRun: at(14)) == .notDue(next: at(3, days: 1)))
        #expect(decide(now: at(2, 59, days: 1), lastRun: at(14)) == .notDue(next: at(3, days: 1)))
        // Three missed days still make one run, not three.
        #expect(decide(now: at(9), lastRun: at(3, days: -3)) == .run(slot: at(3)))
        #expect(decide(now: at(9, 5), lastRun: at(9)) == .notDue(next: at(3, days: 1)))
    }

    @Test func weeklyMissedWindow() {
        let weekly = AutoUpdateSchedule(frequency: .weekly, hour: 3, weekday: 1) // Sundays
        let d = AutoUpdatePolicy.decide(enabled: true, schedule: weekly, since: at(0, days: -30), lastRun: at(3, days: -8),
                                        launchedAt: launched, now: at(12), onAC: true, idle: 3600, busy: false, calendar: utc)
        #expect(d == .run(slot: at(3, days: -1)))
        let after = AutoUpdatePolicy.decide(enabled: true, schedule: weekly, since: at(0, days: -30), lastRun: at(12),
                                            launchedAt: launched, now: at(13), onAC: true, idle: 3600, busy: false, calendar: utc)
        #expect(after == .notDue(next: at(3, days: 6)))
    }

    @Test func statusText() {
        #expect(AutoUpdateText.status(.notDue(next: at(3, days: 1)), now: at(10), calendar: utc) == "Next run: tomorrow 03:00")
        #expect(AutoUpdateText.when(at(3), now: at(10), calendar: utc) == "today 03:00")
        #expect(AutoUpdateText.when(at(3, days: -1), now: at(10), calendar: utc) == "yesterday 03:00")
        #expect(AutoUpdateText.status(.waiting(.onBattery, retry: 60), now: at(3)) == "Due: waiting for AC power")
    }
}

// MARK: safe mode

struct AutoUpdateSafeModeTests {
    let classifier = CompileClassifier()

    func plan(_ p: [Package], running: [RunningApp] = [], dontQuit: Bool = false) -> AutoUpdatePlan {
        AutoUpdateSafeMode.plan(p, classifier: classifier, running: running, dontQuitApps: dontQuit)
    }

    func reasons(_ plan: AutoUpdatePlan) -> [String: AutoUpdateSkip] {
        Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.package.name, $0.reason) })
    }

    @Test func compileNeededIsSkipped() {
        let r = plan([pkg("xz"), pkg("ruby", bottle: false), pkg("current", outdated: false)])
        #expect(r.run.map(\.name) == ["xz"])
        #expect(reasons(r) == ["ruby": .compiles])
    }

    @Test func compilingDependencyOrDependentIsSkipped() {
        // app needs lib; lib's upgrade compiles: app would pull it in.
        let r = plan([pkg("app", deps: ["lib"]), pkg("lib", bottle: false)])
        #expect(r.run.isEmpty)
        #expect(reasons(r) == ["lib": .compiles, "app": .dependencyCompiles("lib")])
        // lib2 is bottled but its outdated dependent tool compiles, and
        // brew's dependents check would upgrade tool too: lib2 runs with
        // that check off.
        let r2 = plan([pkg("lib2"), pkg("tool", bottle: false, deps: ["lib2"])])
        #expect(reasons(r2) == ["tool": .compiles])
        #expect(r2.run.map(\.name) == ["lib2"])
        #expect(r2.noDependentsCheck == ["formula:homebrew/core/lib2": "tool"])
        #expect(AutoUpdateSafeMode.environment(for: pkg("lib2"), noDependentsCheck: true)["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == "1")
        #expect(AutoUpdateSafeMode.environment(for: pkg("lib2"))["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == nil)
        // Further along the chain: lib4 → mid (outdated) → its dependent app4 compiles.
        let r4 = plan([pkg("lib4"), pkg("mid", deps: ["lib4"]), pkg("app4", bottle: false, deps: ["mid", "lib4"])])
        #expect(r4.run.map(\.name) == ["lib4", "mid"])
        #expect(r4.noDependentsCheck.count == 2)
        // A current (not outdated) compiling dependent doesn't matter.
        let r3 = plan([pkg("lib3"), pkg("tool3", outdated: false, bottle: false, deps: ["lib3"])])
        #expect(r3.run.map(\.name) == ["lib3"])
        #expect(r3.noDependentsCheck.isEmpty)
    }

    @Test func pinnedIsSkipped() {
        let r = plan([pkg("sqlite", pinned: true), pkg("python", deps: ["sqlite"]), pkg("xz")])
        #expect(r.run.map(\.name) == ["xz"])
        #expect(reasons(r) == ["sqlite": .pinned, "python": .dependencyPinned("sqlite")])
        // A pinned dependent is not upgraded by brew, so it doesn't block.
        let r2 = plan([pkg("lib"), pkg("held", bottle: false, pinned: true, deps: ["lib"])])
        #expect(r2.run.map(\.name) == ["lib"])
    }

    @Test func runningCaskIsSkipped() {
        let chrome = pkg("google-chrome", kind: .cask, apps: ["/Applications/Google Chrome.app"], quit: ["com.google.Chrome"])
        let code = pkg("visual-studio-code", kind: .cask, apps: ["/Applications/Visual Studio Code.app"], quit: [])
        let running = [RunningApp(path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")]
        let r = plan([chrome, code], running: running)
        #expect(r.run.map(\.name) == ["visual-studio-code"])
        #expect(reasons(r) == ["google-chrome": .appRunning("Google Chrome.app")])
        // Matched by the bundle id brew quits, when the path differs.
        let elsewhere = [RunningApp(path: "/Users/me/Applications/Google Chrome.app", bundleID: "com.google.Chrome")]
        #expect(reasons(plan([chrome], running: elsewhere)) == ["google-chrome": .appRunning("Google Chrome.app")])
        // Not running: upgraded.
        #expect(plan([chrome], running: [RunningApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari")]).run.count == 1)
    }

    @Test func dontQuitAppsSettingLetsRunningCasksUpgrade() {
        let chrome = pkg("google-chrome", kind: .cask, apps: ["/Applications/Google Chrome.app"])
        let running = [RunningApp(path: "/Applications/Google Chrome.app", bundleID: nil)]
        #expect(plan([chrome], running: running, dontQuit: true).run.map(\.name) == ["google-chrome"])
        // Apps unknown (an old report): skipped, unless brew won't quit anything anyway.
        let unknown = pkg("mystery", kind: .cask, apps: nil, quit: nil)
        #expect(reasons(plan([unknown])) == ["mystery": .appUnknown])
        #expect(plan([unknown], dontQuit: true).run.count == 1)
        // Casks never get quit by an automatic run: the variable is always set.
        #expect(AutoUpdateSafeMode.environment(for: chrome)[InsightSettings.noQuitKey] == "1")
        #expect(AutoUpdateSafeMode.environment(for: pkg("xz"))[InsightSettings.noQuitKey] == nil)
        #expect(AutoUpdateSafeMode.environment(for: pkg("xz"))["HOMEBREW_NO_ASK"] == "1")
    }

    @Test func tankardItselfStaysWithBrew() {
        let t = pkg("tankard", kind: .cask, apps: ["/Applications/Tankard.app"])
        #expect(reasons(plan([t], dontQuit: true)) == ["tankard": .tankardItself])
        #expect(MenuBarSummary.selfUpdateLine([t]) == "Tankard 1.1 available")
        #expect(MenuBarSummary.selfUpdateLine([pkg("tankard", kind: .cask, outdated: false)]) == nil)
        #expect(MenuBarSummary.selfUpdateLine([pkg("xz")]) == nil)
    }

    @Test func intelbrewDemoFixture() async throws {
        let packages = try await makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())).status().packages
        let r = plan(packages)
        #expect(r.run.map(\.name) == ["openssl@4", "python@3.15", "sqlite", "xz"])
        #expect(reasons(r) == ["ruby": .compiles])
    }
}

// MARK: settings

@MainActor
struct AutoUpdateSettingsTests {
    func fresh(now: Date = at(10)) -> (AutoUpdateSettings, UserDefaults) {
        let name = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (AutoUpdateSettings(defaults: d, now: { now }), d)
    }

    @Test func defaults() {
        let (s, _) = fresh()
        #expect(!s.enabled)
        #expect(s.schedule == AutoUpdateSchedule(frequency: .daily, hour: 3, minute: 0, weekday: 1))
        #expect(s.since == nil && s.lastRun == nil && !s.dryRun)
    }

    /// The 0.3.1 rule for every new setting: writing the value it already
    /// has notifies nothing and writes nothing.
    @Test func equalWritesDoNothing() {
        let (s, d) = fresh()
        func unchanged<T>(_ key: String, _ read: @escaping () -> T, _ write: () -> Void) {
            let notified = Flag()
            withObservationTracking { _ = read() } onChange: { notified.set() }
            write()
            #expect(!notified.value, "\(key) notified on an equal write")
            #expect(d.object(forKey: key) == nil, "\(key) was written on an equal write")
        }
        unchanged("autoUpdateEnabled", { s.enabled }) { s.enabled = false }
        unchanged("autoUpdateFrequency", { s.frequency }) { s.frequency = .daily }
        unchanged("autoUpdateHour", { s.hour }) { s.hour = 3 }
        unchanged("autoUpdateHour", { s.hour }) { s.hour = 3 }
        unchanged("autoUpdateMinute", { s.minute }) { s.minute = 0 }
        unchanged("autoUpdateWeekday", { s.weekday }) { s.weekday = 1 }
        unchanged("autoUpdateScheduleSince", { s.since }) { s.since = nil }
        unchanged("autoUpdateLastRun", { s.lastRun }) { s.lastRun = nil }
        unchanged("autoUpdateDryRun", { s.dryRun }) { s.dryRun = false }
        // Clamped writes that land on the current value count as equal too.
        unchanged("autoUpdateHour", { s.hour }) { s.hour = 3 }
        s.weekday = 7
        let notified = Flag()
        withObservationTracking { _ = s.weekday } onChange: { notified.set() }
        s.weekday = 12 // clamps to 7
        #expect(!notified.value)

        // Set values: an equal write still notifies nothing.
        s.enabled = true
        s.lastRun = at(3)
        for (key, read, write) in [
            ("enabled", { s.enabled as Any }, { s.enabled = true }),
            ("lastRun", { s.lastRun as Any }, { s.lastRun = at(3) }),
            ("since", { s.since as Any }, { s.since = at(10) }),
        ] as [(String, () -> Any, () -> Void)] {
            let n = Flag()
            withObservationTracking { _ = read() } onChange: { n.set() }
            write()
            #expect(!n.value, "\(key) notified on an equal write")
        }
    }

    @Test func realChangesPersistAndNotify() {
        let (s, d) = fresh()
        let notified = Flag()
        withObservationTracking { _ = s.hour } onChange: { notified.set() }
        s.hour = 5
        #expect(notified.value)
        s.frequency = .weekly
        s.weekday = 3
        s.minute = 45
        s.enabled = true
        let back = AutoUpdateSettings(defaults: d)
        #expect(back.enabled)
        #expect(back.schedule == AutoUpdateSchedule(frequency: .weekly, hour: 5, minute: 45, weekday: 3))
        #expect(back.since == at(10))
    }

    @Test func turningOnOrRescheduleSetsSince() {
        var clock = at(10)
        let name = "net.mindtricks.tankard.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let box = DateBox(clock)
        let s = AutoUpdateSettings(defaults: d, now: { box.value })
        s.hour = 4 // off: no since
        #expect(s.since == nil)
        s.enabled = true
        #expect(s.since == at(10))
        clock = at(11)
        box.value = clock
        s.minute = 30
        #expect(s.since == at(11))
        s.minute = 30 // equal: unchanged
        box.value = at(12)
        s.minute = 30
        #expect(s.since == at(11))
    }
}

final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ v: Date) { _value = v }
    var value: Date {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: log persistence

@MainActor
struct AutoUpdateLogTests {
    @Test func persistsAndReloads() throws {
        let url = try tempDir().appendingPathComponent("auto-update-log.json")
        let log = AutoUpdateLog(url: url)
        #expect(log.runs.isEmpty)
        let run = AutoUpdateRun(startedAt: at(3), finishedAt: at(3, 2),
                                upgraded: [.init(name: "xz", isCask: false, detail: "5.8.3 → 5.8.4")],
                                skipped: [.init(name: "ruby", isCask: false, detail: AutoUpdateSkip.compiles.text)],
                                failed: [.init(name: "iterm2", isCask: true, detail: "brew exited 1")])
        log.record(run)
        let again = AutoUpdateLog(url: url)
        #expect(again.runs == [run])
        #expect(again.latest?.summary == "1 upgraded · 1 skipped · 1 failed")
    }

    @Test func keepsTheLastRunsNewestFirst() throws {
        let url = try tempDir().appendingPathComponent("log.json")
        let log = AutoUpdateLog(url: url)
        for i in 0..<25 { log.record(AutoUpdateRun(startedAt: at(3, days: i))) }
        #expect(log.runs.count == AutoUpdateLog.maxRuns)
        #expect(log.latest?.startedAt == at(3, days: 24))
        #expect(AutoUpdateLog(url: url).runs.count == 20)
        #expect(AutoUpdateLog(url: url).runs.last?.startedAt == at(3, days: 5))
    }

    @Test func unreadableFileStartsEmpty() throws {
        let url = try tempDir().appendingPathComponent("log.json")
        try Data("not json".utf8).write(to: url)
        #expect(AutoUpdateLog(url: url).runs.isEmpty)
        #expect(AutoUpdateLog(url: nil).runs.isEmpty)
    }

    @Test func summariesAndNotification() {
        #expect(AutoUpdateRun(startedAt: at(3)).summary == "Nothing to upgrade")
        #expect(AutoUpdateRun(startedAt: at(3)).notification == nil)
        let skippedOnly = AutoUpdateRun(startedAt: at(3), skipped: [.init(name: "ruby", isCask: false, detail: "x")])
        #expect(skippedOnly.summary == "Nothing upgraded · 1 skipped")
        #expect(skippedOnly.notification == nil)
        let five = AutoUpdateRun(startedAt: at(3), upgraded: ["a", "b", "c", "d", "e"].map { .init(name: $0, isCask: false, detail: "") },
                                 skipped: [.init(name: "ruby", isCask: false, detail: "x")])
        #expect(five.notification?.title == "Tankard upgraded 5 packages")
        #expect(five.notification?.body == "a, b, c, d and 1 more\n1 skipped (see the Auto-update log)")
        let broken = AutoUpdateRun(startedAt: at(3), note: "brew update failed (exit 1)")
        #expect(broken.summary == "Didn't run")
        #expect(broken.notification?.title == "Auto-update didn't run")
        #expect(AutoUpdateRun(startedAt: at(3), upgraded: [.init(name: "a", isCask: false, detail: "")], dryRun: true).notification == nil)
        #expect(AutoUpdateText.lastLine(five, now: at(10), calendar: utc) == "Last auto-update: today 03:00 · 5 upgraded · 1 skipped")
        #expect(AutoUpdateText.lastLine(nil, now: at(10)) == nil)
    }
}

// MARK: runs (fake brew)

/// Records each queued command's arguments and environment.
final class EnvLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [([String], [String: String])] = []
    func add(_ a: [String], _ e: [String: String]) { lock.withLock { _calls.append((a, e)) } }
    var calls: [([String], [String: String])] { lock.withLock { _calls } }
}

struct RecordingRunner: StreamingCommandRunning {
    let inner: StreamingCommandRunning
    let log: EnvLog
    func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        log.add(arguments, environment)
        return try await inner.stream(executable, arguments, environment: environment, output: output)
    }
}

@MainActor
struct AutoUpdateRunTests {
    /// The Intelbrew demo (the fake brew that really "upgrades" its
    /// fixture), recording every queued command.
    func rig(pinned: Set<String> = [], fail: Set<String> = []) async -> (AppStore, EnvLog, FakeNotifier) {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: pinned)
        let envs = EnvLog()
        let demoRunner = deps.streamRunner
        let failing = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade", let last = args.last, fail.contains(where: { last.hasSuffix("/" + $0) }) {
                out(Data("Error: boom\n".utf8))
                return 1
            }
            return try await demoRunner.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        deps.streamRunner = RecordingRunner(inner: failing, log: envs)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.calendar = utc
        return (store, envs, FakeNotifier())
    }

    @Test func runUpgradesSafelyLogsAndNotifies() async throws {
        let (store, envs, notifier) = await rig()
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        let calls = envs.calls
        #expect(calls.first?.0 == ["update"])
        let upgrades = calls.filter { $0.0.first == "upgrade" }
        #expect(upgrades.map { $0.0.last ?? "" } == ["homebrew/core/openssl@4", "homebrew/core/python@3.15", "homebrew/core/sqlite", "homebrew/core/xz"])
        #expect(upgrades.allSatisfy { $0.1["HOMEBREW_NO_AUTO_UPDATE"] == "1" && $0.1["HOMEBREW_NO_ASK"] == "1" })
        // In this fixture ruby (no bottle) depends on the others, so brew's
        // dependents check would compile it: each runs with that check off.
        let noCheck = upgrades.filter { $0.1["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == "1" }.map { $0.0.last ?? "" }
        #expect(noCheck == upgrades.map { $0.0.last ?? "" })
        #expect(!calls.contains { $0.0.contains("homebrew/core/ruby") })
        #expect(run.upgraded.map(\.name) == ["openssl@4", "python@3.15", "sqlite", "xz"])
        #expect(run.upgraded.first { $0.name == "xz" }?.detail == "5.8.3 → 5.8.4 (brew's dependents check off: ruby has no bottle)")
        #expect(run.skipped.map(\.name) == ["ruby"])
        #expect(run.failed.isEmpty)
        #expect(run.finishedAt != nil)
        #expect(store.autoUpdate.log.latest == run)
        #expect(store.autoUpdate.settings.lastRun == run.startedAt)
        #expect(notifier.posted.map(\.title) == ["Tankard upgraded 4 packages"])
        #expect(store.upgradable.map(\.name) == ["ruby"]) // re-read after the run
        #expect(!store.autoUpdate.isRunning && store.autoUpdate.activity == nil)
        #expect(!store.showUpgradeSheet) // no sheet for an automatic run
    }

    @Test func pinnedAndFailuresAreLogged() async throws {
        let (store, _, notifier) = await rig(pinned: ["sqlite"], fail: ["xz"])
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(run.skipped.map(\.name).contains("sqlite"))
        #expect(run.skipped.first { $0.name == "sqlite" }?.detail == "pinned")
        #expect(run.failed.map(\.name) == ["xz"])
        #expect(run.failed.first?.detail.hasPrefix("brew exited 1") == true)
        #expect(notifier.posted.first?.body.contains("Failed: xz") == true)
    }

    @Test func dryRunRunsNoBrewCommand() async throws {
        let (store, envs, notifier) = await rig()
        store.autoUpdate.settings.enabled = true
        store.autoUpdate.settings.dryRun = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(envs.calls.isEmpty)
        #expect(run.dryRun)
        #expect(run.upgraded.count == 4)
        #expect(run.summary == "Dry run: 4 would upgrade · 1 skipped")
        #expect(notifier.posted.isEmpty)
    }

    @Test func brewUpdateFailureStopsTheRun() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let stream = FakeStreamRunner(log: log) { args, out in
            if args.first == "update" { out(Data("fatal: unable to access\n".utf8)); return 1 }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: stream, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        let notifier = FakeNotifier()
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(log.count("upgrade") == 0)
        #expect(run.note?.hasPrefix("brew update failed (exit 1)") == true)
        #expect(notifier.posted.map(\.title) == ["Auto-update didn't run"])
    }

    @Test func noDoubleRuns() async throws {
        let (store, envs, notifier) = await rig()
        store.autoUpdate.settings.enabled = true
        // Two at once: the second returns at once without running.
        async let a = store.autoUpdate.run(store: store, notifier: notifier)
        async let b = store.autoUpdate.run(store: store, notifier: notifier)
        let results = await [a, b]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(envs.calls.filter { $0.0.first == "update" }.count == 1)
        #expect(store.autoUpdate.log.runs.count == 1)
    }

    @Test func turnedOffMidRunStops() async throws {
        let (store, envs, notifier) = await rig()
        let settings = store.autoUpdate.settings
        settings.enabled = true
        // Turn it off while brew update runs.
        let task = Task { await store.autoUpdate.run(store: store, notifier: notifier) }
        #expect(await waitUntil { store.autoUpdate.activity == "Auto-update: brew update" })
        settings.enabled = false
        let run = try #require(await task.value)
        #expect(envs.calls.filter { $0.0.first == "upgrade" }.isEmpty)
        #expect(run.note == "Stopped: auto-update was turned off during the run")
    }
}

// MARK: the shared timer

@MainActor
struct AutoUpdateCheckerTests {
    @Test func tickRunsOnceWhenDueAndConditionsHold() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        let envs = EnvLog()
        deps.streamRunner = RecordingRunner(inner: deps.streamRunner, log: envs)
        let clock = DateBox(at(3, 30))
        deps.now = { clock.value }
        let settings = testSettings()
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        let updater = store.autoUpdate
        updater.calendar = utc
        let conditions = FixedConditions(ac: false, idle: 30)
        updater.conditions = conditions
        let checker = BackgroundChecker(store: store, settings: settings, notifier: FakeNotifier(),
                                        launchedAt: at(0), now: { clock.value })

        // Off by default: nothing, look again in 5 minutes.
        #expect(await checker.tick() == 300)
        // Turned on at 03:30: today's 03:00 has passed, so tomorrow's.
        updater.settings.enabled = true
        #expect(await checker.tick() == at(3, days: 1).timeIntervalSince(at(3, 30)))
        clock.value = at(3, 1, days: 1)
        // Due, on battery: waits.
        #expect(await checker.tick() == AutoUpdatePolicy.recheck)
        conditions.ac = true
        // On AC, not idle yet: waits until the threshold.
        #expect(await checker.tick() == AutoUpdatePolicy.idleThreshold - 30)
        #expect(envs.calls.isEmpty)
        conditions.idle = 900
        await checker.tick()
        #expect(envs.calls.filter { $0.0.first == "update" }.count == 1)
        #expect(envs.calls.filter { $0.0.first == "upgrade" }.count == 4)
        // Same slot, later ticks: no second run.
        clock.value = at(9, days: 1)
        let wait = await checker.tick()
        #expect(wait == at(3, days: 2).timeIntervalSince(at(9, days: 1)))
        #expect(envs.calls.filter { $0.0.first == "update" }.count == 1)
        #expect(updater.log.runs.count == 1)
    }

    @Test func notificationSettingStaysSeparate() async throws {
        let settings = testSettings()
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: settings)
        #expect(!settings.notifyNewUpgrades)
        #expect(!store.autoUpdate.settings.enabled)
        store.autoUpdate.settings.enabled = true
        #expect(!settings.notifyNewUpgrades)
        settings.notifyNewUpgrades = true
        store.autoUpdate.settings.enabled = false
        #expect(settings.notifyNewUpgrades)
    }
}
