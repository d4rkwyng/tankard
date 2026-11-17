import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8: the status reads run side by side (the list first, sizes when they
// land), and the throttled background `brew update`.

/// Answers every brew read; any command can be held at a latch, and the
/// order of starts and ends is recorded ("start info --sizes", "end …").
final class GatedRunner: CommandRunning, @unchecked Sendable {
    let events = CallLog()
    private let lock = NSLock()
    private var gates: [[String]: Latch] = [:]
    private var _info: Data
    var sizesText = ""
    var info: Data {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }

    init(info: Data) { _info = info }

    /// Holds `arguments` until the returned latch is released.
    func hold(_ arguments: [String]) -> Latch {
        let l = Latch()
        lock.withLock { gates[arguments] = l }
        return l
    }

    func started(_ arguments: [String]) -> Bool { events.calls.contains(["start"] + arguments) }
    func ended(_ arguments: [String]) -> Bool { events.calls.contains(["end"] + arguments) }
    func count(_ arguments: [String]) -> Int { events.calls.filter { $0 == ["start"] + arguments }.count }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard executable.hasSuffix("brew") else { return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data()) }
        events.add(["start"] + arguments)
        if let gate = lock.withLock({ gates[arguments] }) { await gate.wait() }
        defer { events.add(["end"] + arguments) }
        switch arguments {
        case BrewClient.sizesArguments:
            return ProcessResult(exitCode: 0, stdout: Data(sizesText.utf8), stderr: Data())
        case BrewClient.greedyOutdatedArguments:
            return ProcessResult(exitCode: 0, stdout: Data(#"{"formulae":[],"casks":[]}"#.utf8), stderr: Data())
        case BrewClient.vulnsArguments:
            return ProcessResult(exitCode: 0, stdout: Data(#"{"findings":[],"skipped_formulae":[],"checked":0,"complete":true,"outdated_without_sbom":[],"unscanned_formulae":{}}"#.utf8), stderr: Data())
        default:
            return ProcessResult(exitCode: 0, stdout: info, stderr: Data())
        }
    }
}

let infoArguments = ["info", "--json=v2", "--installed"]

@MainActor
struct ParallelLoadTests {
    struct Rig {
        var store: AppStore
        var runner: GatedRunner
        var stream: CallLog
        var settings: AppSettings
        var dir: URL
    }

    func rig(info: Data = demoIntelInfo(), backgroundUpdates: Bool = false, now: @escaping @Sendable () -> Date = { Date() },
             stream: (@Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32)? = nil) async throws -> Rig {
        let dir = try tempDir()
        let runner = GatedRunner(info: info)
        // brew's sizes table for every formula in the fixture, 1 MB each.
        let names = try await makeClient(FakeInfoRunner(log: CallLog(), info: info)).status().packages
            .filter { $0.kind == .formula }.map(\.fullName)
        runner.sizesText = "==> Formulae sizes:\n" + names.map { "\($0) 1.0MB" }.joined(separator: "\n") + "\n"
        let client = makeClient(runner)
        let log = CallLog()
        let streamRunner = FakeStreamRunner(log: log, behaviour: stream ?? { _, out in out(Data("ok\n".utf8)); return 0 })
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: streamRunner, cache: nil,
                                         logURL: dir.appendingPathComponent("upgrade.log"), now: now)
        deps.backgroundUpdates = backgroundUpdates
        let settings = testSettings()
        return Rig(store: AppStore(deps: deps, settings: settings), runner: runner, stream: log, settings: settings, dir: dir)
    }

    @Test func sizesStartBesideInfoNotAfterIt() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let info = r.runner.hold(infoArguments)
        let start = Task { await r.store.start() }
        // brew info --sizes is already running (and done) while brew info is held.
        #expect(await waitUntil { r.runner.ended(BrewClient.sizesArguments) })
        #expect(!r.runner.ended(infoArguments))
        #expect(r.store.report == nil)
        info.release()
        await start.value
        await r.store.insights.waitForIdle()
        #expect(r.store.report != nil)
        // Sizes that arrived before the list are on it.
        #expect(r.store.packages.filter { $0.kind == .formula }.allSatisfy { $0.diskBytes == 1_000_000 })
        #expect(r.runner.count(BrewClient.sizesArguments) == 1)
        #expect(r.runner.count(infoArguments) == 1)
    }

    @Test func listShowsBeforeSizesAndSizesFillIn() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let sizes = r.runner.hold(BrewClient.sizesArguments)
        await r.store.start()
        // The list is on screen while sizes are still being measured:
        // every row has a placeholder size, the total says "measuring".
        #expect(r.store.packages.count == 20)
        #expect(r.store.insights.sizesState == .running)
        #expect(r.store.packages.allSatisfy { $0.diskBytes == nil })
        #expect(r.store.totalDiskBytes == nil)
        #expect(!r.store.isRefreshing)
        let ids = r.store.packages.map(\.id)
        sizes.release()
        await r.store.insights.waitForIdle()
        #expect(r.store.insights.sizesState == .idle)
        #expect(r.store.packages.filter { $0.kind == .formula }.allSatisfy { $0.diskBytes == 1_000_000 })
        // Same rows, same order: filling in sizes moves nothing.
        #expect(r.store.packages.map(\.id) == ids)
        #expect(r.runner.count(BrewClient.sizesArguments) == 1)
    }

    @Test func greedyCheckRunsBesideInfo() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.store.insights.settings.includeSelfUpdatingApps = true
        let info = r.runner.hold(infoArguments)
        let start = Task { await r.store.start() }
        #expect(await waitUntil { r.runner.ended(BrewClient.greedyOutdatedArguments) })
        #expect(!r.runner.ended(infoArguments))
        info.release()
        await start.value
        #expect(r.store.report != nil)
        #expect(r.runner.count(BrewClient.greedyOutdatedArguments) == 1)
    }

    @Test func failedReadStillKeepsTheSizesItStarted() async throws {
        // brew info fails; sizes ran anyway, and nothing on screen is lost.
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.runner.info = Data("not json".utf8)
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.store.report == nil)
        #expect(r.store.error != nil)
        #expect(r.runner.count(BrewClient.sizesArguments) == 1)
    }
}

// MARK: background brew update

struct BackgroundUpdatePolicyTests {
    let launched = Date(timeIntervalSince1970: 1_800_000_000)

    func decide(enabled: Bool = true, available: Bool = true, optOut: String? = nil, interval: TimeInterval = 6 * 3600,
                lastUpdate: Date? = nil, lastFailure: Date? = nil, at seconds: TimeInterval,
                busy: Bool = false) -> BackgroundUpdatePolicy.Decision {
        BackgroundUpdatePolicy.decide(enabled: enabled, available: available, optOut: optOut, interval: interval,
                                      lastUpdate: lastUpdate, lastFailure: lastFailure, launchedAt: launched,
                                      now: launched.addingTimeInterval(seconds), busy: busy)
    }

    @Test func offWhenUnavailableOrDisabled() {
        #expect(decide(available: false, at: 60) == .off)  // demo mode, tests
        #expect(decide(enabled: false, at: 60) == .off)
        #expect(decide(optOut: "~/.zprofile", at: 60) == .optedOut(source: "~/.zprofile"))
        // The setting off wins over the opt-out note.
        #expect(decide(enabled: false, optOut: "environment", at: 60) == .off)
    }

    @Test func waitsForTheLaunchDelayThenTheInterval() {
        #expect(decide(at: 1) == .notDue(next: launched.addingTimeInterval(BackgroundUpdatePolicy.launchDelay)))
        #expect(decide(at: 3) == .run)
        // Updated an hour ago (by Tankard or Terminal): not again for 5 hours.
        let lastHour = launched.addingTimeInterval(-3600)
        #expect(decide(lastUpdate: lastHour, at: 10) == .notDue(next: lastHour.addingTimeInterval(6 * 3600)))
        #expect(decide(lastUpdate: lastHour, at: 5 * 3600 - 1) != .run)
        #expect(decide(lastUpdate: lastHour, at: 5 * 3600) == .run)
        // Long ago: as soon as the launch delay allows.
        #expect(decide(lastUpdate: launched.addingTimeInterval(-86400), at: 3) == .run)
    }

    @Test func busyWaitsAndFailureBacksOff() {
        #expect(decide(at: 60, busy: true) == .waiting(retry: BackgroundUpdatePolicy.busyRetry))
        // Offline: one more try an hour later, not every tick.
        let failed = launched.addingTimeInterval(60)
        #expect(decide(lastFailure: failed, at: 600) == .notDue(next: failed.addingTimeInterval(3600)))
        #expect(decide(lastFailure: failed, at: 3660) == .run)
        // A 1-hour interval isn't stretched by the failure back-off.
        #expect(decide(interval: 1800, lastFailure: failed, at: 1860) == .run)
    }

    @Test func intervalHonoursALongerAutoUpdateSecs() {
        #expect(BackgroundUpdatePolicy.interval(hours: 6, autoUpdateSecs: nil) == 6 * 3600)
        #expect(BackgroundUpdatePolicy.interval(hours: 6, autoUpdateSecs: "86400") == 86400)
        #expect(BackgroundUpdatePolicy.interval(hours: 6, autoUpdateSecs: "300") == 6 * 3600)
        #expect(BackgroundUpdatePolicy.interval(hours: 6, autoUpdateSecs: "soon") == 6 * 3600)
        #expect(BackgroundUpdatePolicy.interval(hours: 0, autoUpdateSecs: nil) == 3600)  // clamped like the picker
    }

    @Test func optOutFollowsBrewsOwnRule() {
        func sources(_ v: String?) -> EnvironmentSources {
            EnvironmentSources(process: v.map { ["HOMEBREW_NO_AUTO_UPDATE": $0] } ?? [:])
        }
        #expect(BackgroundUpdatePolicy.optOut(sources(nil)) == nil)
        #expect(BackgroundUpdatePolicy.optOut(sources("")) == nil)  // empty is unset, as in auto-update.sh
        #expect(BackgroundUpdatePolicy.optOut(sources("1")) == "environment")
        #expect(BackgroundUpdatePolicy.optOut(nil) == nil)
    }
}

@MainActor
struct BackgroundUpdateStoreTests {
    let base = ParallelLoadTests()

    /// The fixture before brew update (4 upgrades) and after it (5: xz's appears).
    static let before = Demo.currentInfo(.intelbrew, base: Demo.fixtureInfo(.intelbrew), upgraded: ["xz"])

    @Test func demoAndDefaultDependenciesNeverUpdate() {
        #expect(!Demo.dependencies(.intelbrew).backgroundUpdates)
        #expect(!AppStore.Dependencies(makeClient: { throw BrewClientError.brewNotFound(searched: []) },
                                       streamRunner: StreamingProcessRunner(), cache: nil, logURL: nil).backgroundUpdates)
        #expect(AppStore.Dependencies.live(environment: [:]).backgroundUpdates)
        #expect(testSettings().backgroundUpdate)  // the setting itself defaults on
    }

    @Test func updateThenRereadKeepsSelectionFilterAndSearch() async throws {
        let r = try await base.rig(info: Self.before, backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let upgradesBefore = r.store.upgradable.count
        let p = try #require(r.store.packages.first { $0.kind == .formula })
        r.store.selection = p.id
        r.store.filter = .all
        r.store.search = String(p.name.prefix(2))
        let sizedBefore = r.runner.count(BrewClient.sizesArguments)

        r.runner.info = demoIntelInfo()
        let ok = await r.store.runBackgroundUpdate()
        #expect(ok)
        #expect(r.stream.count("update") == 1)
        #expect(r.runner.count(infoArguments) == 2)
        // An update installs nothing: sizes aren't measured again.
        #expect(r.runner.count(BrewClient.sizesArguments) == sizedBefore)
        #expect(r.store.upgradable.count > upgradesBefore)
        #expect(r.store.selection == p.id)
        #expect(r.store.search == String(p.name.prefix(2)))
        #expect(r.store.filter == .all)
        #expect(r.store.error == nil)
        #expect(r.settings.lastBrewUpdate != nil)
        #expect(!r.store.backgroundUpdating)
    }

    /// 0.6.1's drag lock came from writes the toolbar's filter picker saw.
    /// The background update writes none of filter, tab, selection or search.
    @Test func backgroundUpdateWritesNoFilterOrSelection() async throws {
        let r = try await base.rig(info: Self.before, backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.store.moreFilterSelection = .hasNotes
        r.store.selection = r.store.packages.first?.id
        let notified = Flag()
        withObservationTracking {
            _ = r.store.filter
            _ = r.store.tab
            _ = r.store.selection
            _ = r.store.search
            _ = r.store.moreFilterSelection
        } onChange: { notified.set() }
        r.runner.info = demoIntelInfo()
        #expect(await r.store.runBackgroundUpdate())
        #expect(!notified.value)
        #expect(r.store.filter == .hasNotes)
    }

    @Test func offlineFailureIsQuietAndBacksOff() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            out(Data("fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host: github.com\n".utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let ok = await r.store.runBackgroundUpdate()
        #expect(!ok)
        #expect(r.store.error == nil)  // nothing shown
        #expect(r.store.report != nil)  // the list stays
        #expect(r.runner.count(infoArguments) == 1)  // no re-read
        #expect(r.settings.lastBrewUpdate == nil)
        #expect(r.store.lastBackgroundUpdateFailure != nil)
        let log = try String(contentsOf: r.dir.appendingPathComponent("upgrade.log"), encoding: .utf8)
        #expect(log.contains("background brew update failed"))
        // And the next look waits (back-off), instead of retrying at once.
        if case .notDue = r.store.backgroundUpdateDecision(launchedAt: Date().addingTimeInterval(-3600), now: Date()) {} else {
            Issue.record("expected notDue after a failure")
        }
    }

    @Test func neverBesideAUserStartedCommand() async throws {
        // A user upgrade is running (held in the queue's runner).
        let gate = Latch()
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "upgrade" { await gate.wait() }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let target = try #require(r.store.upgradable.first)
        r.store.startUpgrade([target])
        #expect(await waitUntil { r.stream.count("upgrade") == 1 })
        #expect(r.store.isBusy)
        let launched = Date().addingTimeInterval(-3600)
        #expect(r.store.backgroundUpdateDecision(launchedAt: launched, now: Date()) == .waiting(retry: BackgroundUpdatePolicy.busyRetry))
        #expect(await r.store.runBackgroundUpdate() == false)
        #expect(r.stream.count("update") == 0)
        gate.release()
        #expect(await waitUntil { !r.store.isUpgrading })
        #expect(await waitUntil { !r.store.isRefreshing })
    }

    @Test func aUserCommandStartedDuringTheUpdateWaitsForIt() async throws {
        // The update is running; the user clicks Upgrade: brew's lock is
        // never contended, the queue runs the upgrade after the update.
        let gate = Latch()
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "update" { await gate.wait() }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let bg = Task { await r.store.runBackgroundUpdate() }
        #expect(await waitUntil { r.stream.count("update") == 1 })
        #expect(r.store.backgroundUpdating)
        let target = try #require(r.store.upgradable.first)
        r.store.startUpgrade([target])
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.stream.count("upgrade") == 0)  // queued behind the update
        gate.release()
        _ = await bg.value
        #expect(await waitUntil { r.stream.count("upgrade") == 1 })
        #expect(r.stream.calls.map { $0.first ?? "" }.firstIndex(of: "update")! < r.stream.calls.map { $0.first ?? "" }.firstIndex(of: "upgrade")!)
        #expect(await waitUntil { !r.store.isUpgrading })
    }

    @Test func manualRefreshCountsAsTheUpdate() async throws {
        let r = try await base.rig(backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        await r.store.refresh(manual: true)
        await r.store.insights.waitForIdle()
        #expect(r.settings.lastBrewUpdate != nil)
        let launched = Date().addingTimeInterval(-3600)
        if case .notDue = r.store.backgroundUpdateDecision(launchedAt: launched, now: Date()) {} else {
            Issue.record("a brew update just ran: the background one isn't due")
        }
    }

    @Test func checkerRunsItOnceThenThrottles() async throws {
        let r = try await base.rig(backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: nil, launchedAt: Date().addingTimeInterval(-60))
        let wait = await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(wait >= 5 * 3600)
        await checker.tick()
        #expect(r.stream.count("update") == 1)
        // Off: nothing.
        r.settings.backgroundUpdate = false
        r.settings.lastBrewUpdate = nil
        #expect(await checker.tick() == 300)
        #expect(r.stream.count("update") == 1)
    }

    @Test func notificationsShareTheUpdate() async throws {
        let r = try await base.rig(info: Self.before, backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.settings.notifyNewUpgrades = true
        r.settings.notifiedUpgrades = []  // a baseline with nothing in it
        let notifier = FakeNotifier()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: notifier, launchedAt: Date().addingTimeInterval(-3600))
        r.runner.info = demoIntelInfo()
        await checker.tick()
        // One brew update served both: the background one, then the notification.
        #expect(r.stream.count("update") == 1)
        #expect(notifier.posted.count == 1)
        #expect(r.settings.lastBackgroundCheck != nil)
    }

    @Test func notInDemoEvenWhenDue() async throws {
        let r = try await base.rig(backgroundUpdates: false)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        #expect(r.store.backgroundUpdateDecision(launchedAt: .distantPast, now: Date()) == .off)
    }
}
